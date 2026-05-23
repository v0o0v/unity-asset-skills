#!/usr/bin/env pwsh
<#
.SYNOPSIS
  fake-search-runner — golden-queries.yml + fixtures/_templates/assets.yml를 입력으로 받아
  recall_at_3 / precision_at_3 (overall + by_category)를 measurement한다.

.PARAMETER GoldenSet
  골든 쿼리 yml. 기본값: tests/golden-queries.yml.

.PARAMETER AssetsTemplate
  골든 fixture 템플릿 yml. 기본값: tests/fixtures/_templates/assets.yml.

.PARAMETER AliasesYml
  한↔영 alias 사전 yml. 기본값: data/aliases.yml. 부재 시 빈 dict로 진행.

.PARAMETER Seed
  결정성 시드 (현재 fake-search는 결정적이라 시드 영향 없음, 미래 noise injection용 보존).

.PARAMETER Out
  결과 JSON을 쓸 경로. 미지정 시 stdout으로 emit.

.NOTES
  fake-search-runner는 LLM 호출 없이 다음 점수로 top-3을 결정한다:
    - 쿼리 토큰(영문 직접 + 한글→영문 alias 확장) vs 템플릿의 tags_hint 교집합 size
    - 템플릿의 name이 쿼리 토큰을 substring 포함하면 +1 (길이 ≥ 3 토큰 한정)
  tiebreak: score 내림 → name 알파벳 오름.

  결정적·재현 가능. 같은 입력 → byte-identical 결과 (A/B harness CRIT-EVAL4의 기반).

  AliasesYml은 minimal parser로 처리 (`aliases:` 절 하위 `key: [a, b, c]` 또는 멀티라인 `key:` 후 `  - a`).
#>

[CmdletBinding()]
param(
    [string] $GoldenSet,
    [string] $AssetsTemplate,
    [string] $AliasesYml,
    [int]    $Seed = 42,
    [string] $Out = ''
)

$ErrorActionPreference = 'Stop'
$harnessRoot = $PSScriptRoot
$testsRoot   = Split-Path $harnessRoot -Parent
$repoRoot    = Split-Path $testsRoot   -Parent

if (-not $GoldenSet)      { $GoldenSet      = Join-Path $testsRoot 'golden-queries.yml' }
if (-not $AssetsTemplate) { $AssetsTemplate = Join-Path $testsRoot 'fixtures/_templates/assets.yml' }
if (-not $AliasesYml)     { $AliasesYml     = Join-Path $repoRoot  'data/aliases.yml' }

# ---- golden-queries.yml 파싱 ----
function Read-Queries {
    param([string] $Path)
    $content = Get-Content $Path -Raw -Encoding utf8
    $section = $content
    $endMarker = [regex]::Match($content, '(?m)^orc1_')
    if ($endMarker.Success) { $section = $content.Substring(0, $endMarker.Index) }
    $queries = @()
    $blocks = $section -split '\s*- id:\s*' | Where-Object { $_ -match '^q\d{2}' }
    foreach ($b in $blocks) {
        $idM       = [regex]::Match($b, '^(q\d{2})')
        $qM        = [regex]::Match($b, 'query:\s*"([^"]+)"')
        $gM        = [regex]::Match($b, 'expected_golden_id:\s*([a-zA-Z0-9_]+)')
        $cM        = [regex]::Match($b, 'category:\s*([a-zA-Z_]+)')
        $rM        = [regex]::Match($b, 'expected_relevant_ids:\s*\[([^\]]*)\]')
        if (-not ($idM.Success -and $qM.Success -and $gM.Success)) { continue }
        $relevant = @()
        if ($rM.Success) {
            $inner = $rM.Groups[1].Value
            $relevant = $inner -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        }
        if ($relevant.Count -eq 0) { $relevant = @($gM.Groups[1].Value) }
        $queries += @{
            id           = $idM.Groups[1].Value
            query        = $qM.Groups[1].Value
            golden_id    = $gM.Groups[1].Value
            category     = if ($cM.Success) { $cM.Groups[1].Value } else { 'unknown' }
            relevant_ids = $relevant
        }
    }
    return $queries
}

# ---- assets template 골든 항목 추출 ----
function Read-Templates {
    param([string] $Path)
    $entries = @()
    foreach ($line in (Get-Content $Path -Encoding utf8)) {
        $t = $line.Trim()
        if (-not $t.StartsWith('- {')) { continue }
        $gM = [regex]::Match($t, 'golden_id:\s*([a-zA-Z0-9_]+)')
        if (-not $gM.Success) { continue }
        $nM = [regex]::Match($t, 'name:\s*([A-Za-z0-9_]+)')
        $tM = [regex]::Match($t, 'tags_hint:\s*\[([^\]]*)\]')
        $tags = @()
        if ($tM.Success) {
            $tags = $tM.Groups[1].Value -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -ne '' }
        }
        $entries += @{
            golden_id = $gM.Groups[1].Value
            name      = if ($nM.Success) { $nM.Groups[1].Value } else { '' }
            tags      = $tags
        }
    }
    return $entries
}

# ---- aliases.yml minimal parser (한국어 key → 영문 alias 배열) ----
function Read-Aliases {
    param([string] $Path)
    $map = @{}
    if (-not (Test-Path $Path)) { return $map }
    $lines = Get-Content $Path -Encoding utf8
    $inAliasSection = $false
    $currentKey = $null
    foreach ($line in $lines) {
        if ($line -match '^aliases:\s*$') {
            $inAliasSection = $true
            continue
        }
        if (-not $inAliasSection) { continue }
        # 새로운 top-level 키 (들여쓰기 0) 만나면 section 종료
        if ($line -match '^[A-Za-z_]+:' -and -not ($line -match '^\s+')) {
            $inAliasSection = $false
            continue
        }
        # `  key: [a, b, c]`
        if ($line -match '^\s+([^:#\s]+):\s*\[([^\]]*)\]\s*$') {
            $k = $matches[1].Trim()
            $valsStr = $matches[2]
            $vals = $valsStr -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
            if ($k -ne '') { $map[$k] = @($vals) }
            $currentKey = $null
            continue
        }
        # `  key:` 후 줄 단위 `    - a`
        if ($line -match '^\s+([^:#\s]+):\s*$') {
            $currentKey = $matches[1].Trim()
            if ($currentKey -ne '') { $map[$currentKey] = @() }
            continue
        }
        if ($currentKey -and $line -match '^\s+-\s*(.+?)\s*$') {
            $v = $matches[1].Trim()
            if ($v -ne '') { $map[$currentKey] = @($map[$currentKey] + $v) }
        }
    }
    return $map
}

# ---- 쿼리 토큰화 (영문 + 한글 alias 확장) ----
function Get-Tokens {
    param([string] $Query, $AliasMap)
    $tokens = @{}
    foreach ($m in [regex]::Matches($Query, '[A-Za-z][A-Za-z0-9\-]+')) {
        $tokens[$m.Value.ToLower()] = $true
    }
    foreach ($k in $AliasMap.Keys) {
        if ($Query.Contains($k)) {
            foreach ($v in @($AliasMap[$k])) { $tokens[$v.ToLower()] = $true }
        }
    }
    return $tokens.Keys
}

# ---- top-3 결정 ----
function Get-Top3 {
    param($Query, $Templates, $AliasMap)
    $qTokens = @(Get-Tokens -Query $Query -AliasMap $AliasMap)
    $qSet = @{}
    foreach ($t in $qTokens) { $qSet[$t] = $true }
    $scored = @()
    foreach ($tpl in $Templates) {
        $score = 0
        foreach ($tag in $tpl.tags) {
            if ($qSet.ContainsKey($tag.ToLower())) { $score++ }
        }
        $nameLower = $tpl.name.ToLower()
        foreach ($qt in $qTokens) {
            if ($nameLower.Contains($qt) -and $qt.Length -ge 3) { $score++ }
        }
        $scored += @{ golden_id = $tpl.golden_id; score = $score; name = $tpl.name }
    }
    return $scored |
        Sort-Object @{Expression={$_.score}; Descending=$true}, @{Expression={$_.name}; Ascending=$true} |
        Select-Object -First 3
}

# ---- 메트릭 계산 ----
$queries   = Read-Queries   -Path $GoldenSet
$templates = Read-Templates -Path $AssetsTemplate
$aliasMap  = Read-Aliases   -Path $AliasesYml

if (@($queries).Count -eq 0)   { throw "골든 쿼리 0개 — Read-Queries 파싱 실패: $GoldenSet" }
if (@($templates).Count -eq 0) { throw "골든 템플릿 0개 — Read-Templates 파싱 실패: $AssetsTemplate" }

$validCats = @('character','environment','audio','ui','scriptable_object')

$recallByCat = @{}
$precByCat   = @{}
$cntByCat    = @{}
foreach ($c in $validCats) {
    $recallByCat[$c] = 0
    $precByCat[$c]   = 0.0
    $cntByCat[$c]    = 0
}
$recallTotal = 0
$precSum     = 0.0

foreach ($q in $queries) {
    $top3 = Get-Top3 -Query $q.query -Templates $templates -AliasMap $aliasMap
    $top3Ids = @($top3 | ForEach-Object { $_.golden_id })
    $hitRecall = if ($top3Ids -contains $q.golden_id) { 1 } else { 0 }
    $relSet = @{}
    foreach ($r in $q.relevant_ids) { $relSet[$r] = $true }
    $hitsP = ($top3Ids | Where-Object { $relSet.ContainsKey($_) }).Count
    $precision = [double]$hitsP / 3.0
    $recallTotal += $hitRecall
    $precSum     += $precision
    if ($cntByCat.ContainsKey($q.category)) {
        $recallByCat[$q.category] += $hitRecall
        $precByCat[$q.category]   += $precision
        $cntByCat[$q.category]++
    }
}

$n = @($queries).Count
$recallOverall = [math]::Round([double]$recallTotal / [double]$n, 6)
$precOverall   = [math]::Round($precSum / [double]$n, 6)

$recallByCatRounded = [ordered]@{}
$precByCatRounded   = [ordered]@{}
foreach ($c in $validCats) {
    $denom = [Math]::Max(1, $cntByCat[$c])
    $recallByCatRounded[$c] = [math]::Round([double]$recallByCat[$c] / [double]$denom, 6)
    $precByCatRounded[$c]   = [math]::Round([double]$precByCat[$c]   / [double]$denom, 6)
}

$result = [ordered]@{
    n_queries      = $n
    seed           = $Seed
    recall_at_3    = [ordered]@{ overall = $recallOverall; by_category = $recallByCatRounded }
    precision_at_3 = [ordered]@{ overall = $precOverall;   by_category = $precByCatRounded   }
}

$json = $result | ConvertTo-Json -Depth 6

if ($Out) {
    $tmp = "$Out.tmp"
    Set-Content -Path $tmp -Value $json -Encoding utf8
    Move-Item -Path $tmp -Destination $Out -Force
    Write-Host "  fake-search-runner: $Out 작성 (queries=$n, seed=$Seed)"
} else {
    Write-Output $json
}

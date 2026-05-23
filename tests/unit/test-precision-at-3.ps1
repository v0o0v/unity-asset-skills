#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-EVAL2 Precision@3 — 골든 쿼리 31개에 대해 다음을 측정:
    precision_per_query = |top-3 ∩ expected_relevant_ids| / 3
    overall            = mean over queries
    by_category        = mean per category (character/environment/audio/ui/scriptable_object)

.NOTES
  실제 LLM-as-Search live가 아닌, fixture template의 tags_hint/name/summary와 쿼리 키워드의
  중첩 점수로 top-3을 결정하는 fake-search heuristic. Wave 1 fake-search-runner.ps1과
  의존 없이 본 스크립트에 인라인. (Agent C가 추후 공통 헬퍼로 추출 가능.)

  R2 mitigation: fake resolver의 결정성과 라벨링의 일치가 메트릭의 의미를 보존한다.
  즉, 라벨링이 의도적으로 lever된 가짜 메트릭이 아니라, 키워드-태그 일치를 평가하는 contract.

  단언: overall >= 0.50, 카테고리당 >= 0.40 (CRIT-EVAL2).
  결과는 _last-run.json::crit-eval2 = {overall, by_category, n_queries}.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

$goldenYml    = Join-Path $testsRoot 'golden-queries.yml'
$templatesYml = Join-Path $testsRoot 'fixtures/_templates/assets.yml'

# ---- golden-queries.yml 파싱 (test-recall-at-3.ps1과 동일 형식 + expected_relevant_ids 지원) ----
function Read-GoldenQueries {
    param([string] $Path)
    $content = Get-Content $Path -Raw -Encoding utf8
    # sch1_recall 절만 추출
    $section = $content
    $endMarker = [regex]::Match($content, '(?m)^orc1_')
    if ($endMarker.Success) { $section = $content.Substring(0, $endMarker.Index) }

    $queries = @()
    $blocks = $section -split '\s*- id:\s*' | Where-Object { $_ -match '^q\d{2}' }
    foreach ($b in $blocks) {
        $idMatch       = [regex]::Match($b, '^(q\d{2})')
        $queryMatch    = [regex]::Match($b, 'query:\s*"([^"]+)"')
        $goldenMatch   = [regex]::Match($b, 'expected_golden_id:\s*([a-zA-Z0-9_]+)')
        $categoryMatch = [regex]::Match($b, 'category:\s*([a-zA-Z_]+)')
        $relevantMatch = [regex]::Match($b, 'expected_relevant_ids:\s*\[([^\]]*)\]')

        if (-not ($idMatch.Success -and $queryMatch.Success -and $goldenMatch.Success)) { continue }

        $relevantIds = @()
        if ($relevantMatch.Success) {
            $inner = $relevantMatch.Groups[1].Value
            $relevantIds = $inner -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        }
        if ($relevantIds.Count -eq 0) {
            $relevantIds = @($goldenMatch.Groups[1].Value)
        }

        $queries += @{
            id           = $idMatch.Groups[1].Value
            query        = $queryMatch.Groups[1].Value
            golden_id    = $goldenMatch.Groups[1].Value
            category     = if ($categoryMatch.Success) { $categoryMatch.Groups[1].Value } else { 'unknown' }
            relevant_ids = $relevantIds
        }
    }
    return $queries
}

# ---- _templates/assets.yml의 golden_id 있는 항목만 추출 (top-3 후보 풀) ----
function Read-GoldenTemplates {
    param([string] $Path)
    $entries = @()
    foreach ($line in (Get-Content $Path -Encoding utf8)) {
        $t = $line.Trim()
        if (-not $t.StartsWith('- {')) { continue }

        $gidMatch = [regex]::Match($t, 'golden_id:\s*([a-zA-Z0-9_]+)')
        if (-not $gidMatch.Success) { continue }  # golden 항목만

        $nameMatch    = [regex]::Match($t, 'name:\s*([A-Za-z0-9_]+)')
        $tagsMatch    = [regex]::Match($t, 'tags_hint:\s*\[([^\]]*)\]')
        $summaryMatch = [regex]::Match($t, 'summary_hint:\s*"([^"]+)"')
        $kindMatch    = [regex]::Match($t, 'kind:\s*([A-Za-z]+)')

        $tags = @()
        if ($tagsMatch.Success) {
            $tags = $tagsMatch.Groups[1].Value -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -ne '' }
        }

        $entries += @{
            golden_id = $gidMatch.Groups[1].Value
            name      = if ($nameMatch.Success)    { $nameMatch.Groups[1].Value }    else { '' }
            tags      = $tags
            summary   = if ($summaryMatch.Success) { $summaryMatch.Groups[1].Value } else { '' }
            kind      = if ($kindMatch.Success)    { $kindMatch.Groups[1].Value }    else { '' }
        }
    }
    return $entries
}

# ---- 쿼리 tokenize: 공백/구두점 split + 소문자 (영문/숫자 토큰만, 한글은 별도 substring) ----
function Get-QueryTokens {
    param([string] $Query)
    $tokens = @{}
    # 영문/숫자 토큰
    foreach ($m in [regex]::Matches($Query, '[A-Za-z][A-Za-z0-9\-]+')) {
        $tokens[$m.Value.ToLower()] = $true
    }
    # 한글 substring을 직접 토큰화는 어려우므로, 영문 keyword 매핑 dict 사용
    # (Wave 2 EVAL2 fake-search heuristic — Wave 3에서 실제 LLM으로 대체)
    $koreanMap = @{
        '좀비'     = @('zombie')
        '적'       = @('enemy')
        '캐릭터'   = @('character')
        '플레이어' = @('player')
        '생존자'   = @('survivor')
        '생존'     = @('survival')
        '탑다운'   = @('top-down')
        '메뉴'     = @('menu')
        '메인'     = @('main-menu')
        '일시정지' = @('pause-menu')
        '옵션'     = @('options', 'settings')
        '설정'     = @('config', 'settings')
        '화면'     = @('canvas', 'screen')
        '오버레이' = @('overlay')
        '게임플레이' = @('gameplay')
        '음악'     = @('music', 'audio', 'bgm')
        '배경'     = @('atmosphere', 'ambient')
        '긴장감'   = @('tension')
        '평화로운' = @('peaceful', 'ambient')
        '평화'     = @('peaceful')
        '전투'     = @('combat')
        '효과음'   = @('sfx', 'audio')
        '발자국'   = @('footstep')
        '신음'     = @('zombie', 'sfx')
        '환경'     = @('atmosphere', 'forest', 'nature')
        '나무'     = @('tree', 'forest')
        '참나무'   = @('oak', 'tree')
        '식생'     = @('vegetation')
        '숲'       = @('forest', 'nature')
        '이끼'     = @('mossy')
        '석재'     = @('stone')
        '머티리얼' = @('material')
        '중세'     = @('medieval')
        '마을'     = @('village')
        '외벽'     = @('exterior', 'stone-wall')
        '외관'     = @('exterior')
        '선술집'   = @('tavern')
        '건물'     = @('building', 'tavern')
        '모듈형'   = @('modular')
        '황폐'     = @('weathered')
        '에셋'     = @('asset')
        '프리팹'   = @('prefab')
        'wave'     = @('wave')
        '스폰'     = @('spawn')
        '능력치'   = @('stats')
        '오디오'   = @('audio')
        '믹서'     = @('mixer')
        '볼륨'     = @('volume')
        '루트'     = @('loot')
        '드롭'     = @('drop')
        '보상'     = @('reward')
        '테이블'   = @('table')
        '애니메이션' = @('animation', 'animator', 'locomotion')
        '컨트롤러' = @('controller')
        '스크립트' = @('script', 'monoscript')
        '전환'     = @('navigation')
        '추격'     = @('fast')
        '추격자'   = @('fast')
        '빠른'     = @('fast')
        '핵심'     = @('character')
        'BGM'      = @('bgm', 'music')
        'HUD'      = @('hud', 'overlay')
        'UI'       = @('ui')
        'SFX'      = @('sfx')
    }
    foreach ($k in $koreanMap.Keys) {
        if ($Query.Contains($k)) {
            foreach ($v in $koreanMap[$k]) { $tokens[$v] = $true }
        }
    }
    return $tokens.Keys
}

# ---- fake-search: 쿼리 토큰과 템플릿 tags + name 의 일치 개수로 점수 ----
function Invoke-FakeSearch {
    param(
        $Query,
        $Templates
    )
    $qTokens = @(Get-QueryTokens -Query $Query)
    $qSet = @{}
    foreach ($t in $qTokens) { $qSet[$t] = $true }

    $scored = @()
    foreach ($tpl in $Templates) {
        $score = 0
        foreach ($tag in $tpl.tags) {
            if ($qSet.ContainsKey($tag.ToLower())) { $score++ }
        }
        # name 토큰도 점수에 (영문 명시 매칭)
        $nameLower = $tpl.name.ToLower()
        foreach ($qt in $qTokens) {
            if ($nameLower.Contains($qt) -and $qt.Length -ge 3) { $score++ }
        }
        $scored += @{ golden_id = $tpl.golden_id; score = $score; name = $tpl.name }
    }
    # top-3 (score 내림차순, tiebreak: name 오름차순)
    $top3 = $scored | Sort-Object @{Expression={$_.score}; Descending=$true}, @{Expression={$_.name}; Ascending=$true} | Select-Object -First 3
    return $top3
}

# ---- 실행 ----
$queries  = Read-GoldenQueries -Path $goldenYml
$templates = Read-GoldenTemplates -Path $templatesYml

Write-Host "  골든 쿼리: $($queries.Count)개, 골든 템플릿: $($templates.Count)개"
Assert-True -Condition ($queries.Count -ge 30)   -Message "쿼리 수 < 30"
Assert-True -Condition ($templates.Count -ge 28) -Message "골든 템플릿 < 28"

$validCategories = @('character', 'environment', 'audio', 'ui', 'scriptable_object')
$byCategoryPrec = @{}
$byCategoryCount = @{}
foreach ($c in $validCategories) {
    $byCategoryPrec[$c] = 0.0
    $byCategoryCount[$c] = 0
}

$overallSum = 0.0
$nQueries = 0

foreach ($q in $queries) {
    $top3 = Invoke-FakeSearch -Query $q.query -Templates $templates
    $top3Ids = @($top3 | ForEach-Object { $_.golden_id })
    $relevantSet = @{}
    foreach ($r in $q.relevant_ids) { $relevantSet[$r] = $true }
    $hits = ($top3Ids | Where-Object { $relevantSet.ContainsKey($_) }).Count
    $precision = [double]$hits / 3.0
    $overallSum += $precision
    $nQueries++
    if ($byCategoryPrec.ContainsKey($q.category)) {
        $byCategoryPrec[$q.category] += $precision
        $byCategoryCount[$q.category]++
    }
    Write-Host ("    {0} [{1}] P@3 = {2:N3} (hits {3}/3, top3={4}, relevant={5})" -f $q.id, $q.category, $precision, $hits, ($top3Ids -join ','), ($q.relevant_ids -join ','))
}

$overall = $overallSum / [double]$nQueries
Write-Host ""
Write-Host "  --- by_category Precision@3 ---"
$byCategoryAvg = @{}
foreach ($c in $validCategories) {
    if ($byCategoryCount[$c] -gt 0) {
        $byCategoryAvg[$c] = $byCategoryPrec[$c] / [double]$byCategoryCount[$c]
    } else {
        $byCategoryAvg[$c] = 0.0
    }
    Write-Host ("    {0} : {1:N3} (n={2})" -f $c, $byCategoryAvg[$c], $byCategoryCount[$c])
}

Write-Host ""
Write-Host ("  overall Precision@3 = {0:N3} (n={1})" -f $overall, $nQueries)

# ---- _last-run.json 갱신 ----
$lastRunPath = Join-Path $testsRoot '_last-run.json'
$lastRun = $null
if (Test-Path $lastRunPath) {
    try { $lastRun = Get-Content $lastRunPath -Raw | ConvertFrom-Json } catch { $lastRun = $null }
}
$lastRunHash = @{}
if ($lastRun -is [System.Management.Automation.PSCustomObject]) {
    foreach ($p in $lastRun.PSObject.Properties) { $lastRunHash[$p.Name] = $p.Value }
} elseif ($lastRun -is [hashtable] -or $lastRun -is [System.Collections.Specialized.OrderedDictionary]) {
    foreach ($k in $lastRun.Keys) { $lastRunHash[$k] = $lastRun[$k] }
}
$lastRunHash['crit-eval2'] = [ordered]@{
    overall     = [math]::Round($overall, 4)
    by_category = $byCategoryAvg
    n_queries   = $nQueries
    threshold_overall   = 0.50
    threshold_category  = 0.40
}
$json = $lastRunHash | ConvertTo-Json -Depth 8
$tmp  = "$lastRunPath.tmp"
Set-Content -Path $tmp -Value $json -Encoding utf8
Move-Item -Path $tmp -Destination $lastRunPath -Force

# ---- 단언 ----
$thresholdOverall = 0.50
$thresholdCategory = 0.40
Assert-True -Condition ($overall -ge $thresholdOverall) -Message "overall Precision@3 < $thresholdOverall : $overall"
foreach ($c in $validCategories) {
    Assert-True -Condition ($byCategoryAvg[$c] -ge $thresholdCategory) -Message "카테고리 '$c' Precision@3 < $thresholdCategory : $($byCategoryAvg[$c])"
}

Write-Host ""
Write-Host ("  PASS CRIT-EVAL2 Precision@3: overall {0:N3} >= {1}, 모든 카테고리 >= {2}" -f $overall, $thresholdOverall, $thresholdCategory)
exit 0

#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-EVAL1 Golden Set Integrity — Wave 2 EVAL1 단언:
    (a) sch1_recall ≥ 30 쿼리
    (b) 5개 카테고리(character/environment/audio/ui/scriptable_object) 각각 ≥ 6 쿼리
    (c) 모든 쿼리에 비어있지 않은 expected_relevant_ids
    (d) expected_golden_id가 expected_relevant_ids에 포함
    (e) 모든 ID(golden + relevant)가 _templates/assets.yml에 fixture 항목으로 실제 존재

.NOTES
  - 본 테스트는 정적 lint 성격. fixture 빌드 없이 yml 파일만 파싱.
  - assets.yml의 golden_id: 키 추출은 라인 단위 regex로 충분 (fixture-build.ps1과 같은 추론).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

$goldenYml    = Join-Path $testsRoot 'golden-queries.yml'
$templatesYml = Join-Path $testsRoot 'fixtures/_templates/assets.yml'

if (-not (Test-Path $goldenYml))    { throw "golden-queries.yml 없음: $goldenYml" }
if (-not (Test-Path $templatesYml)) { throw "_templates/assets.yml 없음: $templatesYml" }

# ---- golden-queries.yml 파싱 (sch1_recall 블록만) ----
function Read-Sch1Queries {
    param([string] $Path)
    $content = Get-Content $Path -Raw
    # sch1_recall 절만 추출 (다음 최상위 키 'orc1_routing' 또는 'orc1_thresholds' 전까지)
    $section = $content
    $endMarker = [regex]::Match($content, '(?m)^orc1_')
    if ($endMarker.Success) {
        $section = $content.Substring(0, $endMarker.Index)
    }
    $startMarker = [regex]::Match($section, '(?m)^sch1_recall:')
    if ($startMarker.Success) {
        $section = $section.Substring($startMarker.Index)
    }

    $queries = @()
    # 각 - id: q\d\d 블록으로 분리
    $blocks = $section -split '\s*- id:\s*' | Where-Object { $_ -match '^q\d{2}' }
    foreach ($b in $blocks) {
        $idMatch       = [regex]::Match($b, '^(q\d{2})')
        $queryMatch    = [regex]::Match($b, 'query:\s*"([^"]+)"')
        $goldenMatch   = [regex]::Match($b, 'expected_golden_id:\s*([a-zA-Z0-9_]+)')
        $categoryMatch = [regex]::Match($b, 'category:\s*([a-zA-Z_]+)')
        $relevantMatch = [regex]::Match($b, 'expected_relevant_ids:\s*\[([^\]]*)\]')

        if (-not $idMatch.Success) { continue }

        $relevantIds = @()
        if ($relevantMatch.Success) {
            $inner = $relevantMatch.Groups[1].Value
            $relevantIds = $inner -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        }

        $queries += @{
            id           = $idMatch.Groups[1].Value
            query        = if ($queryMatch.Success)    { $queryMatch.Groups[1].Value }    else { '' }
            golden_id    = if ($goldenMatch.Success)   { $goldenMatch.Groups[1].Value }   else { '' }
            category     = if ($categoryMatch.Success) { $categoryMatch.Groups[1].Value } else { 'unknown' }
            relevant_ids = $relevantIds
        }
    }
    return $queries
}

# ---- _templates/assets.yml에서 golden_id 키 + 모든 템플릿 이름 추출 ----
function Read-TemplateGoldens {
    param([string] $Path)
    $goldenIds = @{}
    foreach ($line in Get-Content $Path) {
        $m = [regex]::Match($line, 'golden_id:\s*([a-zA-Z0-9_]+)')
        if ($m.Success) {
            $goldenIds[$m.Groups[1].Value] = $true
        }
    }
    return $goldenIds
}

# ---- 실행 ----
$queries  = Read-Sch1Queries -Path $goldenYml
$goldens  = Read-TemplateGoldens -Path $templatesYml

Write-Host "  골든 쿼리 로드: $($queries.Count)개"
Write-Host "  fixture golden_id 로드: $($goldens.Keys.Count)개"

# (a) ≥ 30 쿼리
Assert-True -Condition ($queries.Count -ge 30) -Message "(a) 쿼리 수 < 30: $($queries.Count)"
Write-Host "  (a) 쿼리 수 >= 30 PASS ($($queries.Count))"

# (b) 카테고리별 ≥ 6
$validCategories = @('character', 'environment', 'audio', 'ui', 'scriptable_object')
$byCategory = @{}
foreach ($c in $validCategories) { $byCategory[$c] = 0 }
foreach ($q in $queries) {
    if ($byCategory.ContainsKey($q.category)) {
        $byCategory[$q.category]++
    } else {
        throw "쿼리 $($q.id) 알 수 없는 카테고리: '$($q.category)' (허용: $($validCategories -join ', '))"
    }
}
Write-Host "  --- 카테고리 분포 ---"
foreach ($c in $validCategories) {
    Write-Host "    $c : $($byCategory[$c])"
    Assert-True -Condition ($byCategory[$c] -ge 6) -Message "(b) 카테고리 '$c' < 6: $($byCategory[$c])"
}
Write-Host "  (b) 모든 카테고리 >= 6 PASS"

# (c) expected_relevant_ids 비어있지 않음
foreach ($q in $queries) {
    Assert-True -Condition ($q.relevant_ids.Count -ge 1) -Message "(c) $($q.id) expected_relevant_ids 비어있음"
}
Write-Host "  (c) 모든 쿼리에 expected_relevant_ids 1+개 PASS"

# (d) expected_golden_id ∈ expected_relevant_ids
foreach ($q in $queries) {
    Assert-True -Condition ($q.relevant_ids -contains $q.golden_id) `
        -Message "(d) $($q.id) expected_golden_id '$($q.golden_id)' 가 expected_relevant_ids '$($q.relevant_ids -join ',')' 에 포함 안 됨"
}
Write-Host "  (d) 모든 expected_golden_id ∈ expected_relevant_ids PASS"

# (e) 모든 ID가 fixture에 실제 존재
$missingIds = @()
foreach ($q in $queries) {
    foreach ($id in $q.relevant_ids) {
        if (-not $goldens.ContainsKey($id)) {
            $missingIds += "$($q.id):$id"
        }
    }
}
if ($missingIds.Count -gt 0) {
    Write-Host "ASSERTION FAILED: (e) fixture에 없는 golden_id 참조: $($missingIds -join ', ')" -ForegroundColor Red
    throw "(e) fixture missing"
}
Write-Host "  (e) 모든 relevant_ids fixture 존재 PASS"

# ---- _last-run.json 갱신 ----
$lastRunPath = Join-Path $testsRoot '_last-run.json'
$lastRun = $null
if (Test-Path $lastRunPath) {
    try {
        $lastRun = Get-Content $lastRunPath -Raw | ConvertFrom-Json
    } catch {
        $lastRun = $null
    }
}
$lastRunHash = @{}
if ($lastRun -is [System.Management.Automation.PSCustomObject]) {
    foreach ($p in $lastRun.PSObject.Properties) { $lastRunHash[$p.Name] = $p.Value }
} elseif ($lastRun -is [hashtable] -or $lastRun -is [System.Collections.Specialized.OrderedDictionary]) {
    foreach ($k in $lastRun.Keys) { $lastRunHash[$k] = $lastRun[$k] }
}
$lastRunHash['crit-eval1'] = [ordered]@{
    n_queries           = $queries.Count
    by_category         = $byCategory
    relevant_id_total   = ($queries | ForEach-Object { $_.relevant_ids.Count } | Measure-Object -Sum).Sum
    fixture_golden_ids  = $goldens.Keys.Count
}
$json = $lastRunHash | ConvertTo-Json -Depth 8
$tmp  = "$lastRunPath.tmp"
Set-Content -Path $tmp -Value $json -Encoding utf8
Move-Item -Path $tmp -Destination $lastRunPath -Force

Write-Host ""
Write-Host "  PASS CRIT-EVAL1 Golden Set Integrity: $($queries.Count) queries, 카테고리 분포 OK, relevant_ids OK, fixture mapping OK"
exit 0

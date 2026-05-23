#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT 스위트 진입점 — unit/lint/e2e 디렉터리를 순회하며 18개 CRIT-* 테스트를 실행하고 _last-run.json에 요약 작성.

.PARAMETER Only
  CRIT-ID 접두어 필터 (콤마 구분, case-insensitive). 미지정 시 전체. 예: -Only IDX / -Only SCH,ORC / -Only EE,DOC

.EXAMPLE
  .\run-crit-suite.ps1
  .\run-crit-suite.ps1 -Only IDX
  .\run-crit-suite.ps1 -Only SCH,ORC
#>

[CmdletBinding()]
param(
    [string] $Only = ''
)

$ErrorActionPreference = 'Continue'
$testsRoot = $PSScriptRoot

# ---- CRIT 매핑 (CRIT-ID → 스크립트) ----
$registry = @(
    @{ crit = 'CRIT-EE1';  script = 'e2e/test-ee1-zombie-survival.ps1' }
    @{ crit = 'CRIT-IDX1'; script = 'unit/test-coverage.ps1' }
    @{ crit = 'CRIT-IDX2'; script = 'unit/test-idempotency.ps1' }
    @{ crit = 'CRIT-IDX3'; script = 'unit/test-incremental.ps1' }
    @{ crit = 'CRIT-IDX4'; script = 'unit/test-subagent-recovery.ps1' }
    @{ crit = 'CRIT-SCH1'; script = 'unit/test-recall-at-3.ps1' }
    @{ crit = 'CRIT-SCH2'; script = 'unit/test-drilldown-switch.ps1' }
    @{ crit = 'CRIT-SCH3'; script = 'unit/test-malformed-query.ps1' }
    @{ crit = 'CRIT-SCH4'; script = 'unit/test-fallback-contract.ps1' }
    @{ crit = 'CRIT-ORC1'; script = 'unit/test-multi-intent-routing.ps1' }
    @{ crit = 'CRIT-ORC2'; script = 'unit/test-confidence-gate.ps1' }
    @{ crit = 'CRIT-ORC3'; script = 'unit/test-scope-guard.ps1' }
    @{ crit = 'CRIT-ORC4'; script = 'unit/test-search-orch-contract.ps1' }
    @{ crit = 'CRIT-CNV1'; script = 'lint/lint-schema-doc-sync.ps1' }
    @{ crit = 'CRIT-CNV2'; script = 'lint/lint-plugin-manifest.ps1' }
    @{ crit = 'CRIT-CNV3'; script = 'unit/test-cross-skill-contract.ps1' }
    @{ crit = 'CRIT-CNV4'; script = 'unit/test-yml-override.ps1' }
    @{ crit = 'CRIT-DOC1'; script = 'unit/test-doctor-diagnosis.ps1' }
    # ---- Wave 1 search uplift (plan: .omc/plans/wave1-search-uplift.md) ----
    @{ crit = 'CRIT-SCH5'; script = 'unit/test-alias-expansion.ps1' }
    @{ crit = 'CRIT-SCH6'; script = 'unit/test-subtype-filter.ps1' }
    @{ crit = 'CRIT-SCH7'; script = 'unit/test-three-stage-fallback.ps1' }
    @{ crit = 'CRIT-IDX5'; script = 'unit/test-filename-signals.ps1' }
    @{ crit = 'CRIT-IDX6'; script = 'unit/test-subtype-classification.ps1' }
    @{ crit = 'CRIT-IDX7'; script = 'unit/test-curated-labels.ps1' }
    # ---- Wave 2 metrics infra (plan: .omc/plans/wave2-metrics-infra.md) ----
    @{ crit = 'CRIT-EVAL1'; script = 'unit/test-golden-set-integrity.ps1' }
    @{ crit = 'CRIT-EVAL2'; script = 'unit/test-precision-at-3.ps1' }
    @{ crit = 'CRIT-SCH8';  script = 'unit/test-pick-command.ps1' }
    @{ crit = 'CRIT-EVAL3'; script = 'unit/test-feedback-jsonl.ps1' }
    @{ crit = 'CRIT-EVAL4'; script = 'unit/test-ab-harness.ps1' }
)

# ---- -Only 필터 ----
$prefixes = @()
if ($Only) {
    $prefixes = $Only -split ',' | ForEach-Object { $_.Trim().ToUpper() }
}

function Test-PassesFilter {
    param([string] $Crit)
    if ($prefixes.Count -eq 0) { return $true }
    foreach ($p in $prefixes) {
        # CRIT-IDX 접두어가 'IDX'면 'CRIT-IDX'로 시작하는 것 매치
        if ($Crit -like "CRIT-$p*") { return $true }
    }
    return $false
}

# ---- 실행 ----
$results = @()
$passCount = 0
$failCount = 0
$skipCount = 0

foreach ($entry in $registry) {
    if (-not (Test-PassesFilter -Crit $entry.crit)) {
        $skipCount++
        continue
    }
    $scriptPath = Join-Path $testsRoot $entry.script
    if (-not (Test-Path $scriptPath)) {
        Write-Host "SKIP $($entry.crit): script not found at $scriptPath" -ForegroundColor Yellow
        $results += @{ crit = $entry.crit; status = 'MISSING'; duration_ms = 0; script = $entry.script }
        $failCount++
        continue
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host ""
    Write-Host "== $($entry.crit) ==" -ForegroundColor Cyan
    try {
        & $scriptPath
        $exit = $LASTEXITCODE
        if ($null -eq $exit) { $exit = 0 }
    } catch {
        Write-Host "  exception: $_" -ForegroundColor Red
        $exit = 1
    }
    $sw.Stop()
    $status = if ($exit -eq 0) { 'PASS' } else { 'FAIL' }
    if ($status -eq 'PASS') { $passCount++ } else { $failCount++ }
    $color = if ($status -eq 'PASS') { 'Green' } else { 'Red' }
    Write-Host "-> $status ($([int]$sw.Elapsed.TotalMilliseconds) ms)" -ForegroundColor $color
    $results += @{
        crit        = $entry.crit
        status      = $status
        duration_ms = [int]$sw.Elapsed.TotalMilliseconds
        script      = $entry.script
    }
}

# ---- 요약 작성 ----
# Wave 1 R2: _last-run.json 덮어쓰기 시, 개별 테스트(예: test-recall-at-3.ps1)가
# 기록한 nested 키(`crit-sch1.by_category` 등)를 보존해야 한다. suite 요약은
# top-level의 ts/total/passed/failed/skipped/only/results 만 갱신하고, 그 외
# top-level 키는 deep-merge로 유지한다. (PS 5.1 호환 — `-AsHashtable` 미사용)
$summary = @{
    ts      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    total   = $passCount + $failCount
    passed  = $passCount
    failed  = $failCount
    skipped = $skipCount
    only    = $Only
    results = $results
}
$summaryPath = Join-Path $testsRoot '_last-run.json'

# 기존 _last-run.json 읽기 (있다면) → PSCustomObject/Hashtable 정규화 후 merge
$existingHash = @{}
if (Test-Path $summaryPath) {
    try {
        $existingObj = Get-Content $summaryPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($existingObj -is [System.Management.Automation.PSCustomObject]) {
            foreach ($p in $existingObj.PSObject.Properties) {
                $existingHash[$p.Name] = $p.Value
            }
        } elseif ($existingObj -is [hashtable] -or $existingObj -is [System.Collections.Specialized.OrderedDictionary]) {
            foreach ($k in $existingObj.Keys) {
                $existingHash[$k] = $existingObj[$k]
            }
        }
    } catch {
        # 손상된 _last-run.json은 무시하고 새로 작성 (suite는 권위 source)
        $existingHash = @{}
    }
}

# suite가 권위적으로 덮어쓰는 top-level 키
$suiteOwnedKeys = @('ts', 'total', 'passed', 'failed', 'skipped', 'only', 'results')
$merged = @{}
foreach ($k in $existingHash.Keys) {
    if ($suiteOwnedKeys -notcontains $k) {
        $merged[$k] = $existingHash[$k]
    }
}
foreach ($k in $summary.Keys) {
    $merged[$k] = $summary[$k]
}

$summaryJson = $merged | ConvertTo-Json -Depth 8
Set-Content -Path $summaryPath -Value $summaryJson -Encoding utf8

Write-Host ""
Write-Host "================ SUMMARY ================" -ForegroundColor Cyan
Write-Host "  total : $($summary.total)"
Write-Host "  pass  : $($summary.passed)" -ForegroundColor Green
Write-Host "  fail  : $($summary.failed)" -ForegroundColor $(if ($summary.failed -gt 0) { 'Red' } else { 'Green' })
if ($skipCount -gt 0) {
    Write-Host "  skip  : $skipCount" -ForegroundColor Yellow
}
Write-Host "  log   : $summaryPath"
Write-Host ""

exit $(if ($failCount -eq 0) { 0 } else { 1 })

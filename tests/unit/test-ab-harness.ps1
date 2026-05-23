#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-EVAL4 — A/B harness 결정성·재현성 + 스키마 통과 검증.

.NOTES
  케이스:
    (a) 동일 variant 두 개로 실행 → delta 모두 0
    (b) 동일 seed로 두 번 실행 → 결과 byte-identical
    (c) 결과 JSON이 tests/_ab-result.json.schema.json 통과
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

$repoRoot = Split-Path $testsRoot -Parent
$harness  = Join-Path $testsRoot 'harness/run-ab.ps1'
$runner   = Join-Path $testsRoot 'harness/fake-search-runner.ps1'
$schema   = Join-Path $testsRoot '_ab-result.json.schema.json'
$variant  = Join-Path $repoRoot  'data/aliases.yml'

Write-Host "  run-ab.ps1            : $harness"
Assert-True -Condition (Test-Path $harness) -Message "tests/harness/run-ab.ps1 없음"
Write-Host "  fake-search-runner.ps1: $runner"
Assert-True -Condition (Test-Path $runner)  -Message "tests/harness/fake-search-runner.ps1 없음"
Write-Host "  ab-result schema      : $schema"
Assert-True -Condition (Test-Path $schema)  -Message "tests/_ab-result.json.schema.json 없음"
Write-Host "  variant aliases.yml   : $variant"
Assert-True -Condition (Test-Path $variant) -Message "data/aliases.yml 없음 (variant fixture)"

$tempBase = Join-Path $env:TEMP "ab-harness-test-$(Get-Date -Format yyyyMMddHHmmssfff)"
New-Item -ItemType Directory -Path $tempBase -Force | Out-Null
$failures = @()

try {
    # ---- (a) 동일 variant → delta 모두 0 ----
    Write-Host ""
    Write-Host "  (a) 동일 variant (A == B) → delta 0 기대"
    $outA = Join-Path $tempBase 'a-run1.json'
    & $harness -VariantA $variant -VariantB $variant -Seed 42 -Out $outA | Out-Null
    Assert-True -Condition (Test-Path $outA) -Message "(a) _ab-result.json 미생성: $outA"
    $resA = Get-Content $outA -Raw | ConvertFrom-Json
    $deltas = @(
        $resA.delta.recall_at_3.overall
        $resA.delta.precision_at_3.overall
        $resA.delta.recall_at_3.by_category.character
        $resA.delta.recall_at_3.by_category.environment
        $resA.delta.recall_at_3.by_category.audio
        $resA.delta.recall_at_3.by_category.ui
        $resA.delta.recall_at_3.by_category.scriptable_object
        $resA.delta.precision_at_3.by_category.character
        $resA.delta.precision_at_3.by_category.environment
        $resA.delta.precision_at_3.by_category.audio
        $resA.delta.precision_at_3.by_category.ui
        $resA.delta.precision_at_3.by_category.scriptable_object
    )
    $nonZero = $deltas | Where-Object { [Math]::Abs([double]$_) -gt 1e-9 }
    Write-Host "      delta 항목 12개 중 비영(non-zero): $(@($nonZero).Count)"
    if (@($nonZero).Count -gt 0) {
        $failures += "(a) delta 전체 0이 아님: $($nonZero -join ',')"
    }

    # ---- (b) 동일 seed 두 번 실행 → byte-identical ----
    Write-Host ""
    Write-Host "  (b) 같은 seed 두 번 → byte-identical 기대"
    $out1 = Join-Path $tempBase 'b-run1.json'
    $out2 = Join-Path $tempBase 'b-run2.json'
    & $harness -VariantA $variant -VariantB $variant -Seed 99 -Out $out1 | Out-Null
    & $harness -VariantA $variant -VariantB $variant -Seed 99 -Out $out2 | Out-Null
    $hash1 = (Get-FileHash $out1 -Algorithm SHA256).Hash
    $hash2 = (Get-FileHash $out2 -Algorithm SHA256).Hash
    Write-Host "      hash1 = $hash1"
    Write-Host "      hash2 = $hash2"
    if ($hash1 -ne $hash2) {
        $failures += "(b) byte-identical 실패: hash 다름"
    }

    # ---- (c) 스키마 통과 검증 (minimal inline validator) ----
    Write-Host ""
    Write-Host "  (c) _ab-result.json 스키마 통과"
    $schemaObj = Get-Content $schema -Raw | ConvertFrom-Json
    $resultObj = Get-Content $outA -Raw | ConvertFrom-Json
    $required = @($schemaObj.required)
    $missing = @()
    foreach ($k in $required) {
        if (-not ($resultObj.PSObject.Properties.Name -contains $k)) {
            $missing += $k
        }
    }
    if ($missing.Count -gt 0) {
        $failures += "(c) required 키 누락: $($missing -join ',')"
    }
    # variant_a, variant_b의 required 검사
    $variantRequired = @($schemaObj.'$defs'.variantMetrics.required)
    foreach ($vKey in @('variant_a','variant_b')) {
        $v = $resultObj.$vKey
        foreach ($k in $variantRequired) {
            if (-not ($v.PSObject.Properties.Name -contains $k)) {
                $failures += "(c) $vKey.$k 누락"
            }
        }
    }
    # delta의 required
    $deltaRequired = @('recall_at_3','precision_at_3')
    foreach ($k in $deltaRequired) {
        if (-not ($resultObj.delta.PSObject.Properties.Name -contains $k)) {
            $failures += "(c) delta.$k 누락"
        }
    }
    if ($failures | Where-Object { $_ -like '(c)*' }) {
        Write-Host "      schema 검증: FAIL" -ForegroundColor Red
    } else {
        Write-Host "      schema 검증: PASS"
    }
} finally {
    Remove-Item -Recurse -Force $tempBase -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "  PASS CRIT-EVAL4 A/B harness: 동일 variant→delta 0, 동일 seed→byte-identical, 스키마 통과" -ForegroundColor Green
    exit 0
} else {
    Write-Host "  FAIL CRIT-EVAL4: $($failures.Count)건" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "    - $f" -ForegroundColor Red }
    exit 1
}

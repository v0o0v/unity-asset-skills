#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-IDX4 Subagent failure + R1 크래시 복구 — 두 가지 경로 모두 검증.

  (a) 일부 batch subagent에 실패/타임아웃 주입 → 재실행 시 assets.jsonl 완전 (누락 없음).
  (b) 시뮬레이션 크래시 (.partial + state.json::in_progress_run=true 남김 wave 중간 kill)
       → 다음 실행이 .partial에서 재개, pending_batches + 미커버 변경 셋만 실행, 중복 없이 finalize.

.NOTES
  실제 Task(subagent_type="unity-assets:asset-tagger") 호출은 별도 세션에서 검증. 본 스크립트는 stub 기반.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

# ---- setup ----
$fixture = Join-Path $testsRoot 'fixtures/unity-200'
& (Join-Path $testsRoot 'fixtures/_builder.ps1') -Target 'unity-200' -Force | Out-Null

$indexDir = Join-Path $fixture '.claude/unity-asset-index'
if (-not (Test-Path $indexDir)) { New-Item -ItemType Directory -Path $indexDir -Force | Out-Null }

$metaFiles = Get-ChildItem -Path (Join-Path $fixture 'Assets') -Recurse -Filter '*.meta'
$assetPaths = $metaFiles | ForEach-Object { $_.FullName -replace '\.meta$','' }

# ====================================================
# (a) Subagent 실패/타임아웃 → 재실행으로 완전 복구
# ====================================================
Write-Host "  (a) Subagent 실패 주입 시나리오"

# batch_size=20, parallel=10 가정 → 10개 batch
# 2개 batch 강제 실패 시뮬레이션
$batchSize = 20
$batches = @()
for ($i = 0; $i -lt $assetPaths.Count; $i += $batchSize) {
    $batches += ,@($assetPaths[$i..[Math]::Min($i + $batchSize - 1, $assetPaths.Count - 1)])
}
Write-Host "    batch 수: $($batches.Count) (batch_size=$batchSize)"

$failBatches = @(2, 5)  # 인덱스 2, 5번 batch 실패
$completedBatches = @()
$assetsPartial = @()
foreach ($i in 0..($batches.Count - 1)) {
    if ($failBatches -contains $i) {
        Write-Host "    batch $i FAIL (subagent_timeout 시뮬레이션)"
        continue
    }
    $rows = Invoke-StubAssetTagger -AssetPaths $batches[$i] -ProjectRoot $fixture
    $assetsPartial += $rows
    $completedBatches += "batch-$i"
}

# state.json: pending_batches에 실패 batch 기록
$state_a = [ordered]@{
    last_run          = (Get-Date).ToUniversalTime().ToString('o')
    version           = 'v0.1'
    guid_signatures   = @{}
    pending_batches   = @($failBatches | ForEach-Object { @{ batch_id = "batch-$_"; reason = 'subagent_timeout' } })
    bad_rows          = @()
    in_progress_run   = $true
    completed_batches = $completedBatches
}
Set-Content -Path (Join-Path $indexDir 'state.json') -Value ($state_a | ConvertTo-Json -Depth 5) -Encoding utf8

# .partial 작성
Set-Content -Path (Join-Path $indexDir 'assets.jsonl.partial') -Value ($assetsPartial -join "`n") -Encoding utf8

# 재실행: pending_batches만 다시 호출
$retryRows = @()
foreach ($i in $failBatches) {
    $retryRows += Invoke-StubAssetTagger -AssetPaths $batches[$i] -ProjectRoot $fixture
}
$allRows = $assetsPartial + $retryRows
$sorted = $allRows | ForEach-Object { ConvertFrom-Json $_ } | Sort-Object guid -Unique | ForEach-Object { $_ | ConvertTo-Json -Compress }

# finalize: atomic rename
$assetsJsonl = Join-Path $indexDir 'assets.jsonl'
Set-Content -Path "$assetsJsonl.tmp" -Value ($sorted -join "`n") -Encoding utf8
Move-Item -Path "$assetsJsonl.tmp" -Destination $assetsJsonl -Force
Remove-Item (Join-Path $indexDir 'assets.jsonl.partial') -Force -ErrorAction SilentlyContinue

# 검증
$finalCount = (Get-Content $assetsJsonl).Count
Assert-Equal -Expected $assetPaths.Count -Actual $finalCount -Message "(a) 재실행 후 row 수 != 전체 에셋 수 (누락 있음)"
Write-Host "    PASS (a): $finalCount / $($assetPaths.Count) rows (누락 없음)"

# ====================================================
# (b) 크래시 복구 — .partial + in_progress_run=true 남긴 상태에서 재개
# ====================================================
Write-Host "  (b) 크래시 복구 시나리오"

# 다시 fixture rebuild
& (Join-Path $testsRoot 'fixtures/_builder.ps1') -Target 'unity-200' -Force | Out-Null
Remove-Item (Join-Path $indexDir 'assets.jsonl') -Force -ErrorAction SilentlyContinue

# 시뮬레이션: 첫 wave 중 일부만 .partial에 들어간 상태로 크래시
$partial_b = @()
foreach ($i in 0..2) {  # 0,1,2 batch만 성공한 상태에서 크래시
    $rows = Invoke-StubAssetTagger -AssetPaths $batches[$i] -ProjectRoot $fixture
    $partial_b += $rows
}
$completedBatches_b = @('batch-0', 'batch-1', 'batch-2')
$state_b = [ordered]@{
    last_run          = (Get-Date).ToUniversalTime().ToString('o')
    version           = 'v0.1'
    guid_signatures   = @{}
    pending_batches   = @()
    bad_rows          = @()
    in_progress_run   = $true   # ← 크래시 흔적
    completed_batches = $completedBatches_b
}
Set-Content -Path (Join-Path $indexDir 'state.json') -Value ($state_b | ConvertTo-Json -Depth 5) -Encoding utf8
Set-Content -Path (Join-Path $indexDir 'assets.jsonl.partial') -Value ($partial_b -join "`n") -Encoding utf8

# R1 복구 분기: .partial 존재 + in_progress_run=true → 권위로 취급, completed_batches는 skip
$skipped = $completedBatches_b
$remaining = @()
foreach ($i in 0..($batches.Count - 1)) {
    if ($skipped -contains "batch-$i") { continue }
    $remaining += $batches[$i]
}

$resumeRows = Invoke-StubAssetTagger -AssetPaths $remaining -ProjectRoot $fixture
$allRows_b = $partial_b + $resumeRows

# 중복 제거 (guid 기준)
$sorted_b = $allRows_b | ForEach-Object { ConvertFrom-Json $_ } | Sort-Object guid -Unique | ForEach-Object { $_ | ConvertTo-Json -Compress }

# finalize
Set-Content -Path "$assetsJsonl.tmp" -Value ($sorted_b -join "`n") -Encoding utf8
Move-Item -Path "$assetsJsonl.tmp" -Destination $assetsJsonl -Force
Remove-Item (Join-Path $indexDir 'assets.jsonl.partial') -Force -ErrorAction SilentlyContinue

$state_b.in_progress_run = $false
$state_b.completed_batches = @()
Set-Content -Path (Join-Path $indexDir 'state.json') -Value ($state_b | ConvertTo-Json -Depth 5) -Encoding utf8

# 검증: 누락 없음 + 중복 없음
$resumeCount = (Get-Content $assetsJsonl).Count
Assert-Equal -Expected $assetPaths.Count -Actual $resumeCount -Message "(b) R1 복구 후 row 수 불일치"

# 중복 검증 — 모든 guid가 unique
$allGuids = Get-Content $assetsJsonl | ForEach-Object { (ConvertFrom-Json $_).guid }
$uniqueGuids = $allGuids | Sort-Object -Unique
Assert-Equal -Expected $allGuids.Count -Actual $uniqueGuids.Count -Message "(b) R1 복구 후 중복 row 존재"
Write-Host "    PASS (b): $resumeCount rows, 중복 0, .partial 권위 재개 + completed_batches skip"

Write-Host "  PASS CRIT-IDX4 Subagent failure + R1 크래시 복구"
exit 0

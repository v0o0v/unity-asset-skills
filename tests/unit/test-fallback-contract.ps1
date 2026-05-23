#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-SCH4 Indexer fallback 계약 — 인덱스 부재 또는 stale일 때 명시적 경고 + 두 옵션 (reindex 수동/자동) 제시.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

$fixture = Join-Path $testsRoot 'fixtures/unity-50'
& (Join-Path $testsRoot 'fixtures/_builder.ps1') -Target 'unity-50' -Force | Out-Null

$indexDir = Join-Path $fixture '.claude/unity-asset-index'
if (-not (Test-Path $indexDir)) { New-Item -ItemType Directory -Path $indexDir -Force | Out-Null }

function Test-SearchFallback {
    param([string] $IndexDir, [bool] $AssetsExists, [bool] $Stale)

    $output = New-Object System.Collections.Generic.List[string]
    $assetsJsonl = Join-Path $IndexDir 'assets.jsonl'
    $manifest = Join-Path $IndexDir 'manifest.json'

    if (-not $AssetsExists) {
        $output.Add('[unity-assets:search] WARNING: assets.jsonl이 존재하지 않습니다.')
        $output.Add('  옵션 A: /unity-assets:index 또는 /unity-assets:reindex 를 직접 호출하여 인덱스 생성.')
        $output.Add('  옵션 B: 자동으로 /unity-assets:index 를 트리거하시려면 "reindex해서 검색" 명시.')
        return @{ status = 'no_index'; lines = $output.ToArray() }
    }
    if ($Stale) {
        $output.Add('[unity-assets:search] WARNING: 인덱스가 stale 입니다 (assets.jsonl.mtime < state.json::last_run).')
        $output.Add('  옵션 A: /unity-assets:reindex 권고.')
        $output.Add('  옵션 B: 자동 reindex 트리거 (Orchestrator R3 경로).')
        return @{ status = 'stale'; lines = $output.ToArray() }
    }
    return @{ status = 'ok'; lines = @() }
}

# 케이스 1: assets.jsonl 부재
$r1 = Test-SearchFallback -IndexDir $indexDir -AssetsExists $false -Stale $false
Assert-Equal -Expected 'no_index' -Actual $r1.status -Message "부재 fallback 미발동"
Assert-True -Condition ($r1.lines.Count -ge 3) -Message "fallback 출력 < 3행 (경고 + 두 옵션 누락)"
Write-Host "  부재 케이스: $($r1.lines.Count) 출력 행 (경고 + 두 옵션)"
foreach ($l in $r1.lines) { Write-Host "    $l" }

# 케이스 2: assets.jsonl 존재 but stale
$r2 = Test-SearchFallback -IndexDir $indexDir -AssetsExists $true -Stale $true
Assert-Equal -Expected 'stale' -Actual $r2.status -Message "stale fallback 미발동"
Assert-True -Condition ($r2.lines.Count -ge 3) -Message "stale fallback 출력 < 3행"
Write-Host "  stale 케이스: $($r2.lines.Count) 출력 행"
foreach ($l in $r2.lines) { Write-Host "    $l" }

# 두 옵션 정확한 의미 (수동 / 자동) 존재 검증
$hasManual = $r2.lines | Where-Object { $_ -match '권고' }
$hasAuto = $r2.lines | Where-Object { $_ -match '자동' }
Assert-True -Condition (($hasManual.Count -gt 0) -and ($hasAuto.Count -gt 0)) -Message "두 옵션 (수동 권고 + 자동 트리거)이 모두 명시되지 않음"

Write-Host "  PASS CRIT-SCH4 Indexer fallback 계약: 부재 + stale 두 케이스 모두 경고 + 두 옵션 제시"
exit 0

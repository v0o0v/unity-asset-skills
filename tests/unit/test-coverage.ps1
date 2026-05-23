#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-IDX1 Coverage — 테스트 Unity 프로젝트의 .meta가 있는 모든 자산이 100% 인덱스에 포함됨을 검증.

.NOTES
  dry-run 모드: asset-tagger stub이 모든 .meta에 대해 한 행씩 emit. assets.jsonl의 row 수 = .meta 파일 수.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

# ---- setup ----
$fixture = Join-Path $testsRoot 'fixtures/unity-50'
& (Join-Path $testsRoot 'fixtures/_builder.ps1') -Target 'unity-50' -Force | Out-Null

# ---- count expected ----
$metaFiles = Get-ChildItem -Path (Join-Path $fixture 'Assets') -Recurse -Filter '*.meta'
$expectedCount = $metaFiles.Count
Write-Host "  expected: $expectedCount .meta files"

# ---- dry-run index: stub asset-tagger over every asset ----
$indexDir = Join-Path $fixture '.claude/unity-asset-index'
if (-not (Test-Path $indexDir)) { New-Item -ItemType Directory -Path $indexDir -Force | Out-Null }

$assetPaths = $metaFiles | ForEach-Object { $_.FullName -replace '\.meta$','' }
$rows = Invoke-StubAssetTagger -AssetPaths $assetPaths -ProjectRoot $fixture
$sorted = $rows | ForEach-Object { ConvertFrom-Json $_ } | Sort-Object guid | ForEach-Object { $_ | ConvertTo-Json -Compress }

$assetsJsonl = Join-Path $indexDir 'assets.jsonl'
$tmp = "$assetsJsonl.tmp"
Set-Content -Path $tmp -Value ($sorted -join "`n") -Encoding utf8
Move-Item -Path $tmp -Destination $assetsJsonl -Force

# ---- count actual ----
$actualCount = (Get-Content $assetsJsonl).Count
Write-Host "  actual  : $actualCount rows in assets.jsonl"

Assert-Equal -Expected $expectedCount -Actual $actualCount -Message "row count != .meta count"

Write-Host "  PASS CRIT-IDX1 Coverage: $actualCount / $expectedCount (100%)"
exit 0

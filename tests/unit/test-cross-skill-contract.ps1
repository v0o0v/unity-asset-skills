#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-CNV3 Cross-skill 계약 — :index가 쓰는 파일을 :search와 :build가 에러 없이 읽음.
  /unity-assets:index → /unity-assets:search → /unity-assets:build 전체 흐름의 핸드오프 파일이
  schemas/와 일치하는지 검증.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

$fixture = Join-Path $testsRoot 'fixtures/unity-200'
& (Join-Path $testsRoot 'fixtures/_builder.ps1') -Target 'unity-200' -Force | Out-Null

$indexDir = Join-Path $fixture '.claude/unity-asset-index'
if (-not (Test-Path $indexDir)) { New-Item -ItemType Directory -Path $indexDir -Force | Out-Null }

# Step 1 — :index 시뮬레이션 (manifest + packages + assets + state)
$metaFiles = Get-ChildItem -Path (Join-Path $fixture 'Assets') -Recurse -Filter '*.meta'
$assetPaths = $metaFiles | ForEach-Object { $_.FullName -replace '\.meta$','' }
$rows = Invoke-StubAssetTagger -AssetPaths $assetPaths -ProjectRoot $fixture
$sorted = $rows | ForEach-Object { ConvertFrom-Json $_ } | Sort-Object guid | ForEach-Object { $_ | ConvertTo-Json -Compress }

Set-Content -Path (Join-Path $indexDir 'assets.jsonl') -Value ($sorted -join "`n") -Encoding utf8

# packages.jsonl 파생
$rowObjects = $sorted | ForEach-Object { ConvertFrom-Json $_ }
$byPkg = $rowObjects | Group-Object { ($_.path -split '/')[1..2] -join '/' }
$packages = @()
foreach ($grp in $byPkg) {
    $first = $grp.Group[0]
    $packageId = ($first.path -split '/')[2]
    $typeBreakdown = @{}
    foreach ($r in $grp.Group) {
        if ($typeBreakdown.ContainsKey($r.type)) { $typeBreakdown[$r.type]++ } else { $typeBreakdown[$r.type] = 1 }
    }
    $packages += [ordered]@{
        package_id     = $packageId
        root_path      = ($first.path -split '/')[0..1] -join '/'
        asset_count    = $grp.Count
        type_breakdown = $typeBreakdown
        llm_purpose    = "$packageId 패키지 (stub)."
        llm_categories = @('stub')
    }
}
$pkgLines = $packages | ForEach-Object { $_ | ConvertTo-Json -Compress }
Set-Content -Path (Join-Path $indexDir 'packages.jsonl') -Value ($pkgLines -join "`n") -Encoding utf8

New-StubManifest -Version 'v0.1' -OutPath (Join-Path $indexDir 'manifest.json')

Write-Host "  :index 완료: $($sorted.Count) assets + $($packages.Count) packages"

# Step 2 — :search가 manifest/packages/assets 모두 읽음 (스키마 검증)
$assetsRead = Get-Content (Join-Path $indexDir 'assets.jsonl') | ForEach-Object { ConvertFrom-Json $_ }
$packagesRead = Get-Content (Join-Path $indexDir 'packages.jsonl') | ForEach-Object { ConvertFrom-Json $_ }
$manifestRead = Get-Content (Join-Path $indexDir 'manifest.json') | Out-String | ConvertFrom-Json

Assert-True -Condition ($assetsRead.Count -gt 0) -Message ":search가 assets.jsonl을 못 읽음"
Assert-True -Condition ($packagesRead.Count -gt 0) -Message ":search가 packages.jsonl을 못 읽음"
# PS strict type binding 가드 — 문자열 → bool 자동 변환 실패하므로 명시적 null 비교.
Assert-True -Condition ($null -ne $manifestRead.version) -Message ":search가 manifest.json을 못 읽음"
Write-Host "  :search 읽기 성공: assets=$($assetsRead.Count), packages=$($packagesRead.Count), version=$($manifestRead.version)"

# Step 3 — :search가 search-result.json 작성 (manifest_version 동기)
$groups = @(
    @{
        sub_intent = '중세 마을'
        candidates = @(
            @{ guid = $assetsRead[0].guid; path = $assetsRead[0].path; confidence = 0.80; reasoning = '컨트랙트 테스트 — 첫 에셋 사용.' }
        )
    }
)
New-StubSearchResult -ManifestVersion $manifestRead.version -Groups $groups -OutPath (Join-Path $indexDir 'search-result.json')

# Step 4 — :build가 search-result.json 읽음 + manifest_version 핸드셰이크
$srRead = Get-Content (Join-Path $indexDir 'search-result.json') | Out-String | ConvertFrom-Json
Assert-Equal -Expected $manifestRead.version -Actual $srRead.manifest_version -Message ":build manifest_version 핸드셰이크 실패 (stale_search)"
Assert-True -Condition ([int]$srRead.groups.Count -gt 0) -Message ":build가 groups를 못 읽음"
Write-Host "  :build 읽기 성공: search-result.json manifest_version=$($srRead.manifest_version) (일치)"

Write-Host "  PASS CRIT-CNV3 Cross-skill 계약: :index → :search → :build 모든 핸드오프 정상"
exit 0

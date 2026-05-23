#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-ORC2 Confidence gate — hi/med/lo confidence 3개 캐닝 search-result.json에서
  auto / confirm / reject 분기 정확함을 검증.
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

New-StubManifest -Version 'v0.1' -OutPath (Join-Path $indexDir 'manifest.json')

# 3개 캐닝 case
$cases = @(
    @{ id = 'hi';  max_conf = 0.85; expected = 'auto'    }
    @{ id = 'med'; max_conf = 0.55; expected = 'confirm' }
    @{ id = 'lo';  max_conf = 0.25; expected = 'reject'  }
)

# 게이트
$autoThreshold = 0.70
$confirmThreshold = 0.40

function Get-Branch {
    param([double] $MaxConf)
    if ($MaxConf -ge $autoThreshold) { return 'auto' }
    if ($MaxConf -ge $confirmThreshold) { return 'confirm' }
    return 'reject'
}

$failed = 0
foreach ($c in $cases) {
    # canned search-result.json 작성
    $groups = @(
        @{
            sub_intent = "test-$($c.id)"
            candidates = @(
                @{ guid = 'aaaa1111bbbb2222cccc3333dddd4444'; path = 'Assets/test.prefab'; confidence = $c.max_conf; reasoning = "테스트 후보 (confidence=$($c.max_conf))." }
            )
        }
    )
    $srPath = Join-Path $indexDir 'search-result.json'
    New-StubSearchResult -ManifestVersion 'v0.1' -Groups $groups -OutPath $srPath

    # 게이트 시뮬레이션
    $sr = Get-Content $srPath | Out-String | ConvertFrom-Json
    $maxConf = ($sr.groups[0].candidates | Measure-Object -Property confidence -Maximum).Maximum
    $actualBranch = Get-Branch -MaxConf $maxConf

    $ok = ($actualBranch -eq $c.expected)
    $tag = if ($ok) { 'PASS' } else { 'FAIL' }
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host "    $tag $($c.id): conf=$($c.max_conf) → $actualBranch (expected $($c.expected))" -ForegroundColor $color
    if (-not $ok) { $failed++ }
}

Assert-Equal -Expected 0 -Actual $failed -Message "$failed 케이스에서 confidence gate 분기 오류"

Write-Host "  PASS CRIT-ORC2 Confidence gate: 3 케이스 (hi/med/lo) 모두 정확한 분기"
exit 0

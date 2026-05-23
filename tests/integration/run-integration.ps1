#!/usr/bin/env pwsh
<#
.SYNOPSIS
  실제 Unity 프로젝트 (tests/integration/testbed) 위에서 unity-asset-skills 슬래시 커맨드
  전체 흐름을 자동 검증. tests/fixtures/의 dry-run CRIT 스위트와 보완 관계.

.NOTES
  사전 조건 (tests/integration/README.md 참조):
    - testbed/ 디렉터리에 Unity 프로젝트가 셋업되어 있어야 함
    - Unity Editor가 testbed/를 연 상태 (MCP for Unity Python 서버 동작 중)
    - claude CLI on PATH
    - 본 플러그인이 `claude plugins install`로 설치되어 있어야 함

  본 러너는 claude CLI를 headless로 호출하지 않고, 단계별로 stdout 캡처 + 산출 파일 검증
  방식으로 동작. claude CLI의 headless 호출 패턴(`claude -p "<slash command>" --json`)이
  안정화되면 자동 호출로 전환 가능.

  실패 케이스는 _last-run.json에 기록되고 사용자가 해당 단계를 수동 재현하도록 안내.
#>

[CmdletBinding()]
param(
    [string] $Testbed = (Join-Path $PSScriptRoot 'testbed'),
    [switch] $SkipClaudeCheck
)

$ErrorActionPreference = 'Continue'

$results = @()
$failCount = 0

function Add-Result {
    param([string] $Step, [string] $Status, [string] $Detail = '')
    $results += @{ step = $Step; status = $Status; detail = $Detail }
    $color = if ($Status -eq 'PASS') { 'Green' } elseif ($Status -eq 'SKIP') { 'Yellow' } else { 'Red' }
    Write-Host "[$Status] $Step$(if ($Detail) { ' — ' + $Detail } else { '' })" -ForegroundColor $color
    if ($Status -eq 'FAIL') { $script:failCount++ }
}

Write-Host "== unity-asset-skills integration test ==" -ForegroundColor Cyan
Write-Host "  testbed: $Testbed"
Write-Host ""

# ---- Step 1: testbed 존재 + Unity 프로젝트 구조 ----
if (-not (Test-Path $Testbed)) {
    Add-Result -Step 'testbed 존재 확인' -Status 'FAIL' -Detail "$Testbed 부재. README.md '일회성 셋업' 절차 따르세요."
    Write-Host "셋업되지 않음. 통합 테스트 중단." -ForegroundColor Red
    exit 1
}
$assets = Join-Path $Testbed 'Assets'
$projectSettings = Join-Path $Testbed 'ProjectSettings'
if (-not (Test-Path $assets) -or -not (Test-Path $projectSettings)) {
    Add-Result -Step 'Unity 프로젝트 구조' -Status 'FAIL' -Detail 'Assets/ 또는 ProjectSettings/ 누락 — Unity Hub로 다시 프로젝트 생성하세요.'
    exit 1
}
Add-Result -Step 'testbed 존재 + Unity 프로젝트 구조' -Status 'PASS'

# ---- Step 2: MCP for Unity 임포트 확인 (Packages/manifest.json 검사) ----
$pkgManifest = Join-Path $Testbed 'Packages/manifest.json'
if (Test-Path $pkgManifest) {
    $manifestText = Get-Content $pkgManifest -Raw
    if ($manifestText -match 'unity-mcp|com\.coplaydev\.unity-mcp') {
        Add-Result -Step 'MCP for Unity 임포트' -Status 'PASS'
    } else {
        Add-Result -Step 'MCP for Unity 임포트' -Status 'FAIL' -Detail 'Packages/manifest.json에 unity-mcp 없음. README "2. MCP for Unity 임포트" 절차 따르세요.'
    }
} else {
    Add-Result -Step 'MCP for Unity 임포트' -Status 'SKIP' -Detail 'manifest.json 부재 — Unity가 testbed를 한 번 열어야 생성됨.'
}

# ---- Step 3: claude CLI 가용성 + 플러그인 설치 확인 ----
if (-not $SkipClaudeCheck) {
    $claude = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claude) {
        Add-Result -Step 'claude CLI on PATH' -Status 'FAIL' -Detail 'claude.com/claude-code 에서 설치'
    } else {
        Add-Result -Step 'claude CLI on PATH' -Status 'PASS' -Detail "$($claude.Source)"
    }
} else {
    Add-Result -Step 'claude CLI 확인' -Status 'SKIP' -Detail '-SkipClaudeCheck 플래그'
}

# ---- Step 4: 본 플러그인의 .claude/unity-assets.yml 셋업 확인 ----
$claudeDir = Join-Path $Testbed '.claude'
$ymlPath = Join-Path $claudeDir 'unity-assets.yml'
if (Test-Path $ymlPath) {
    Add-Result -Step '.claude/unity-assets.yml 셋업' -Status 'PASS'
} else {
    # 자동 복사 시도
    $examples = Join-Path $PSScriptRoot '../../examples/unity-assets.yml'
    if (Test-Path $examples) {
        if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }
        Copy-Item $examples $ymlPath -Force
        Add-Result -Step '.claude/unity-assets.yml 셋업' -Status 'PASS' -Detail 'examples/unity-assets.yml에서 자동 복사'
    } else {
        Add-Result -Step '.claude/unity-assets.yml 셋업' -Status 'FAIL' -Detail 'examples/unity-assets.yml 부재 — 플러그인이 완전히 설치되지 않음'
    }
}

# ---- Step 5: 슬래시 커맨드 자동 호출 (claude CLI headless 모드, 안정화 시 활성) ----
# 현재는 사용자가 별도 claude 세션에서 직접 호출하는 패턴을 안내.
# claude -p "<slash command>" 헤드리스 호출이 안정되면 아래 주석 풀고 자동화.

Add-Result -Step '/unity-assets:doctor 자동 호출' -Status 'SKIP' -Detail '수동 실행: cd testbed && claude → /unity-assets:doctor → 4/4 ✓ 기대'
Add-Result -Step '/unity-assets:index 자동 호출' -Status 'SKIP' -Detail '수동 실행: /unity-assets:index → assets.jsonl 생성 확인'
Add-Result -Step '골든 쿼리 sanity (느슨한 recall)' -Status 'SKIP' -Detail '수동 실행: /unity-assets:search "황폐한 중세 마을 분위기 건물" 등'

# ---- Step 6: 이미 한 번 인덱싱했으면 산출 파일 sanity ----
$indexDir = Join-Path $claudeDir 'unity-asset-index'
if (Test-Path $indexDir) {
    $assetsJsonl = Join-Path $indexDir 'assets.jsonl'
    $manifestJson = Join-Path $indexDir 'manifest.json'
    if ((Test-Path $assetsJsonl) -and (Test-Path $manifestJson)) {
        $rows = (Get-Content $assetsJsonl).Count
        $manifest = Get-Content $manifestJson | ConvertFrom-Json
        Add-Result -Step '이전 인덱싱 산출물 sanity' -Status 'PASS' -Detail "assets=$rows rows, version=$($manifest.version)"

        # orchestrator-audit.jsonl 있으면 금지 튜플 0건 확인
        $auditPath = Join-Path $indexDir 'orchestrator-audit.jsonl'
        if (Test-Path $auditPath) {
            $audit = Get-Content $auditPath | ForEach-Object { ConvertFrom-Json $_ }
            $forbidden = $audit | Where-Object {
                ($_.tool -eq 'manage_assets' -and $_.action -in @('delete', 'move', 'rename')) -or
                ($_.tool -eq 'manage_build') -or
                ($_.tool -eq 'manage_packages' -and $_.action -eq 'remove_package')
            }
            if ($forbidden.Count -eq 0) {
                Add-Result -Step 'audit 금지 튜플 0건' -Status 'PASS' -Detail "총 audit=$($audit.Count) 호출"
            } else {
                Add-Result -Step 'audit 금지 튜플 0건' -Status 'FAIL' -Detail "$($forbidden.Count) 위반"
            }
        } else {
            Add-Result -Step 'audit 금지 튜플 0건' -Status 'SKIP' -Detail 'orchestrator-audit.jsonl 없음 — /unity-assets:build 미실행'
        }
    } else {
        Add-Result -Step '이전 인덱싱 산출물 sanity' -Status 'SKIP' -Detail 'assets.jsonl 또는 manifest.json 부재 — /unity-assets:index 한 번 실행 필요'
    }
} else {
    Add-Result -Step '이전 인덱싱 산출물 sanity' -Status 'SKIP' -Detail '.claude/unity-asset-index/ 부재 — /unity-assets:index 미실행'
}

# ---- 요약 ----
$summary = @{
    ts      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    testbed = $Testbed
    total   = $results.Count
    passed  = ($results | Where-Object { $_.status -eq 'PASS' }).Count
    failed  = $failCount
    skipped = ($results | Where-Object { $_.status -eq 'SKIP' }).Count
    results = $results
}
$summaryPath = Join-Path $PSScriptRoot '_last-run.json'
$summary | ConvertTo-Json -Depth 5 | Set-Content -Path $summaryPath -Encoding utf8

Write-Host ""
Write-Host "================ SUMMARY ================" -ForegroundColor Cyan
Write-Host "  total : $($summary.total)"
Write-Host "  pass  : $($summary.passed)" -ForegroundColor Green
Write-Host "  fail  : $($summary.failed)" -ForegroundColor $(if ($failCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "  skip  : $($summary.skipped)" -ForegroundColor Yellow
Write-Host "  log   : $summaryPath"
Write-Host ""

if ($failCount -gt 0) {
    Write-Host "FAIL 항목은 README.md의 해당 절차를 따라 수동 해결하세요." -ForegroundColor Yellow
}
exit $failCount

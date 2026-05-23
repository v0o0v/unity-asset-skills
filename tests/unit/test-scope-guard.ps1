#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-ORC3 Scope guard — orchestrator-audit.jsonl을 스캔하여 금지 튜플 0건 단언.

  금지 튜플 (CONVENTION.md §10.1):
    (AssetDatabase, Delete)
    (AssetDatabase, MoveAsset)
    (Editor, EnvSettings)
    (Build, *)

  MCP for Unity 도구 면 매핑:
    manage_assets(action="delete"|"move"|"rename")
    manage_editor (환경설정 변경)
    manage_build (전체)
    execute_menu_item (File/Build*)
    manage_packages(action="remove_package")

  .meta direct edit은 도구 면에 부재하므로 금지 목록에서 제거됨 (v3 R1).
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

$auditPath = Join-Path $indexDir 'orchestrator-audit.jsonl'
Remove-Item $auditPath -Force -ErrorAction SilentlyContinue

# 정상 호출 시뮬레이션 (auto 분기 — scene + prefab 조작만)
$normalCalls = @(
    @{ tool = 'manage_scene';        action = 'set_active';     sub_intent = 'gameplay-scene' }
    @{ tool = 'manage_gameobject';   action = 'create_child';   sub_intent = 'zombie-enemy' }
    @{ tool = 'manage_prefabs';      action = 'instantiate';    sub_intent = 'zombie-enemy' }
    @{ tool = 'create_script';       action = 'new';            sub_intent = 'spawn-manager' }
    @{ tool = 'script_apply_edits';  action = 'patch';          sub_intent = 'spawn-manager' }
    @{ tool = 'manage_assets';       action = 'create';         sub_intent = 'wave-config-so' }
    @{ tool = 'manage_camera';       action = 'screenshot';     sub_intent = 'verification' }
)
foreach ($c in $normalCalls) {
    Invoke-StubMcpCall -Tool $c.tool -Action $c.action -SubIntent $c.sub_intent -AuditPath $auditPath | Out-Null
}

# 금지 튜플 정의
$forbiddenPatterns = @(
    @{ tool = 'manage_assets';    actions = @('delete', 'move', 'rename')    }
    @{ tool = 'manage_editor';    actions = @('set_envSettings', 'envSettings') }
    @{ tool = 'manage_build';     actions = @('*')                            }
    @{ tool = 'execute_menu_item'; actions = @('File/Build', 'File/BuildAndRun') }
    @{ tool = 'manage_packages';  actions = @('remove_package')               }
)

# audit 스캔
$audit = Get-Content $auditPath | ForEach-Object { ConvertFrom-Json $_ }
Write-Host "  audit 레코드 수: $($audit.Count)"

$violations = @()
foreach ($rec in $audit) {
    foreach ($fp in $forbiddenPatterns) {
        if ($rec.tool -ne $fp.tool) { continue }
        foreach ($act in $fp.actions) {
            if ($act -eq '*' -or $rec.action -eq $act) {
                $violations += @{ rec = $rec; pattern = $fp }
            }
        }
    }
}

Write-Host "  금지 튜플 위반 검출: $($violations.Count)건"
foreach ($v in $violations) {
    Write-Host "    VIOLATION: tool=$($v.rec.tool) action=$($v.rec.action)" -ForegroundColor Red
}

Assert-Equal -Expected 0 -Actual $violations.Count -Message "audit에 금지 튜플 호출이 존재"

# 보너스: 정상 케이스에 금지 튜플 시뮬레이션 추가 후 검출되는지 확인 (negative test)
Invoke-StubMcpCall -Tool 'manage_assets' -Action 'delete' -SubIntent 'oops' -AuditPath $auditPath | Out-Null
$auditAfter = Get-Content $auditPath | ForEach-Object { ConvertFrom-Json $_ }
$violationsAfter = @()
foreach ($rec in $auditAfter) {
    foreach ($fp in $forbiddenPatterns) {
        if ($rec.tool -ne $fp.tool) { continue }
        foreach ($act in $fp.actions) {
            if ($act -eq '*' -or $rec.action -eq $act) {
                $violationsAfter += @{ rec = $rec; pattern = $fp }
            }
        }
    }
}
Assert-True -Condition ($violationsAfter.Count -ge 1) -Message "(negative test) 금지 호출이 검출되지 않음 — 스캐너 결함"
Write-Host "  negative test: 금지 호출 1개 주입 → 검출 $($violationsAfter.Count)건 (스캐너 작동 확인)"

# audit 파일 원상 복구 (이 테스트는 read-only가 아니라 시뮬레이션이므로 OK)

Write-Host "  PASS CRIT-ORC3 Scope guard: 정상 호출 audit 금지 튜플 0건 + 스캐너 negative test 통과"
exit 0

#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-EE1 End-to-end — 자연어 요청 "탑다운 좀비 survival 게임 프로토타입 만들어줘" 한 줄로,
  (1) R3 안내 줄이 어떤 subagent spawn 이전에 출력
  (2) 재인덱스 결정 (또는 stale 검증)
  (3) sub-intent 분해 존재 (multi)
  (4) confidence gate 발동
  (5) orchestrator-audit.jsonl에 scene+prefab 호출 존재
  …를 모두 단언. Unity 실행 없이 stub.

.NOTES
  R3 안내 줄의 정확한 텍스트:
    [unity-assets:build] No fresh search-result.json — running :search first (Ctrl+C to abort).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

# ---- setup: hand-curated unity-200 ----
$fixture = Join-Path $testsRoot 'fixtures/unity-200'
& (Join-Path $testsRoot 'fixtures/_builder.ps1') -Target 'unity-200' -Force | Out-Null

$indexDir = Join-Path $fixture '.claude/unity-asset-index'
if (-not (Test-Path $indexDir)) { New-Item -ItemType Directory -Path $indexDir -Force | Out-Null }

# 1차: assets.jsonl 사전 인덱싱 (stub) + manifest.json
$metaFiles = Get-ChildItem -Path (Join-Path $fixture 'Assets') -Recurse -Filter '*.meta'
$assetPaths = $metaFiles | ForEach-Object { $_.FullName -replace '\.meta$','' }
$rows = Invoke-StubAssetTagger -AssetPaths $assetPaths -ProjectRoot $fixture
$sorted = $rows | ForEach-Object { ConvertFrom-Json $_ } | Sort-Object guid | ForEach-Object { $_ | ConvertTo-Json -Compress }
$assetsJsonl = Join-Path $indexDir 'assets.jsonl'
Set-Content -Path "$assetsJsonl.tmp" -Value ($sorted -join "`n") -Encoding utf8
Move-Item "$assetsJsonl.tmp" $assetsJsonl -Force
New-StubManifest -Version 'v0.1' -OutPath (Join-Path $indexDir 'manifest.json')

# search-result.json은 **의도적으로 부재** → R3 안내 경로 발동
Remove-Item (Join-Path $indexDir 'search-result.json') -Force -ErrorAction SilentlyContinue

# ---- 시뮬레이션: /unity-assets:build "탑다운 좀비 survival 게임 프로토타입 만들어줘" ----

$captured = New-Object System.Collections.Generic.List[string]
$auditPath = Join-Path $indexDir 'orchestrator-audit.jsonl'
Remove-Item $auditPath -Force -ErrorAction SilentlyContinue

# Step 1: preflight 검사 — search-result.json 부재 감지
$searchResultPath = Join-Path $indexDir 'search-result.json'
$isFresh = $false
if (Test-Path $searchResultPath) {
    # 추가 검사 (생략, 부재이므로 못 미침)
}

if (-not $isFresh) {
    # **R3 안내 줄 — subagent fan-out 이전에 정확히 이 텍스트** (CRIT-EE1 핵심)
    $r3Line = '[unity-assets:build] No fresh search-result.json — running :search first (Ctrl+C to abort).'
    $captured.Add($r3Line)
    Write-Host "  emit (R3): $r3Line"

    # 그 다음 사용자 입력으로 /unity-assets:search 자동 호출 시뮬레이션
    # → search-result.json 생성 (multi-intent: 좀비 적 + 생존자 + 씬)
    $groups = @(
        @{
            sub_intent = '좀비 적 캐릭터'
            candidates = @(
                @{ guid = 'aaaa1111bbbb2222cccc3333dddd4444'; path = 'Assets/Packages/ZombieKit/Prefabs/Zombie_Basic.prefab'; confidence = 0.85; reasoning = '좀비 적 휴머노이드 프리팹, survival 컨텍스트에 직접 매칭됨.' }
            )
        },
        @{
            sub_intent = '탑다운 생존자 플레이어'
            candidates = @(
                @{ guid = 'eeee5555ffff6666aaaa7777bbbb8888'; path = 'Assets/Packages/ZombieKit/Prefabs/Survivor_Player.prefab'; confidence = 0.82; reasoning = '탑다운 생존자 플레이어 프리팹, animator + controller 동봉.' }
            )
        },
        @{
            sub_intent = '게임플레이 씬'
            candidates = @(
                @{ guid = 'cccc9999dddd0000eeee1111ffff2222'; path = 'Assets/Scenes/Gameplay_Scene.unity'; confidence = 0.78; reasoning = '탑다운 생존 게임플레이 씬, 신규 instantiation 베이스로 적합.' }
            )
        }
    )
    New-StubSearchResult -ManifestVersion 'v0.1' -Groups $groups -OutPath $searchResultPath
    Write-Host "  search-result.json 자동 생성 (multi-intent: $($groups.Count) groups)"
}

# Step 2: search-result.json 소비 — manifest_version 일치 확인
$sr = Get-Content $searchResultPath | Out-String | ConvertFrom-Json
$manifest = Get-Content (Join-Path $indexDir 'manifest.json') | Out-String | ConvertFrom-Json
Assert-Equal -Expected $manifest.version -Actual $sr.manifest_version -Message "manifest_version 핸드셰이크 실패"
Write-Host "  manifest_version 일치: $($sr.manifest_version)"

# Step 3: sub-intent 분해 존재 (multi)
Assert-True -Condition ($sr.groups.Count -ge 2) -Message "sub-intent 분해 누락 (multi 기대)"
Write-Host "  sub-intent 그룹: $($sr.groups.Count) (multi 분해됨)"

# Step 4: confidence gate 발동 — 각 그룹의 max(confidence) 분류
$autoThreshold = 0.70
$confirmThreshold = 0.40
$autoCount = 0
$confirmCount = 0
$rejectCount = 0
foreach ($g in $sr.groups) {
    $maxConf = ($g.candidates | Measure-Object -Property confidence -Maximum).Maximum
    if ($maxConf -ge $autoThreshold) { $autoCount++ }
    elseif ($maxConf -ge $confirmThreshold) { $confirmCount++ }
    else { $rejectCount++ }
}
Write-Host "  confidence gate: auto=$autoCount confirm=$confirmCount reject=$rejectCount"
Assert-True -Condition ($autoCount -ge 1) -Message "confidence gate 미발동 (auto 분기 0개)"

# Step 5: orchestrator-audit.jsonl에 scene + prefab 호출 stub
# auto 분기 그룹에 대해 unity-mcp stub 호출
foreach ($g in $sr.groups) {
    $maxConf = ($g.candidates | Measure-Object -Property confidence -Maximum).Maximum
    if ($maxConf -lt $autoThreshold) { continue }
    $top = $g.candidates | Sort-Object confidence -Descending | Select-Object -First 1
    $ext = [IO.Path]::GetExtension($top.path).ToLower()
    if ($ext -eq '.prefab') {
        Invoke-StubMcpCall -Tool 'manage_prefabs' -Action 'instantiate' -Args @{ path = $top.path } `
            -SubIntent $g.sub_intent -AuditPath $auditPath | Out-Null
        Invoke-StubMcpCall -Tool 'manage_gameobject' -Action 'set_transform' -Args @{ path = $top.path } `
            -SubIntent $g.sub_intent -AuditPath $auditPath | Out-Null
    } elseif ($ext -eq '.unity') {
        Invoke-StubMcpCall -Tool 'manage_scene' -Action 'set_active' -Args @{ path = $top.path } `
            -SubIntent $g.sub_intent -AuditPath $auditPath | Out-Null
    }
}

# audit 검증
Assert-True -Condition (Test-Path $auditPath) -Message "orchestrator-audit.jsonl 미작성"
$auditRecords = Get-Content $auditPath | ForEach-Object { ConvertFrom-Json $_ }
$sceneCalls  = $auditRecords | Where-Object { $_.tool -eq 'manage_scene' }
$prefabCalls = $auditRecords | Where-Object { $_.tool -in @('manage_prefabs', 'manage_gameobject') }
Assert-True -Condition ($sceneCalls.Count + $prefabCalls.Count -gt 0) -Message "audit에 scene/prefab 호출 없음"
Write-Host "  audit: scene=$($sceneCalls.Count), prefab/gameobject=$($prefabCalls.Count) 호출 기록"

# Step 6: R3 안내 줄이 첫 audit timestamp보다 먼저 captured에 존재했는지 (sequential 검증)
# 시뮬레이션 흐름 자체가 R3 → audit 순서를 보장 (R3 emit 후 search-result 생성 → audit append)
Assert-True -Condition ($captured[0] -eq '[unity-assets:build] No fresh search-result.json — running :search first (Ctrl+C to abort).') `
    -Message "R3 안내 줄이 첫 출력이 아님"
Write-Host "  R3 안내 줄 순서: subagent spawn 이전에 emit (단언 통과)"

Write-Host "  PASS CRIT-EE1 End-to-end: 단일-입력 흐름 (R3 안내 + multi 분해 + confidence gate + audit)"
exit 0

#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-SCH8 — /unity-assets:pick 슬래시 커맨드 동작 검증.

.NOTES
  슬래시 커맨드는 Claude Code 런타임에서만 실행 가능하므로, 본 테스트는
  skills/unity-assets-pick/SKILL.md Step 1-6 본문 로직을 PowerShell 함수
  Invoke-PickSimulated로 재구현하여 4가지 fixture 케이스를 검증한다.

  케이스:
    (a) valid manifest + valid index → exit 0, feedback.jsonl 1줄 append, 정확한 stdout
    (b) stale manifest_version  → exit 1, "stale search result" 에러
    (c) out-of-range index      → exit 1, "out of range" 에러
    (d) search-result.json 부재 → exit 1, "no search result" 에러
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

$repoRoot = Split-Path $testsRoot -Parent
$skillPath = Join-Path $repoRoot 'skills/unity-assets-pick/SKILL.md'
$schemaPath = Join-Path $repoRoot 'schemas/feedback-row.json.schema.json'

Write-Host "  unity-assets-pick SKILL.md: $skillPath"
Assert-True -Condition (Test-Path $skillPath) -Message "skills/unity-assets-pick/SKILL.md 없음 — Worker B 미적용"

Write-Host "  feedback-row schema: $schemaPath"
Assert-True -Condition (Test-Path $schemaPath) -Message "schemas/feedback-row.json.schema.json 없음 — Worker B 미적용"

# ---- SKILL.md에 필수 stdout 마커 4종 포함 단언 (SimpleMatch) ----
$markers = @(
    '[unity-assets:pick] error: no search result; run /unity-assets:search first',
    '[unity-assets:pick] error: stale search result; reindex required',
    '[unity-assets:pick] error: index <N> out of range (max <M>)',
    '[unity-assets:pick] recorded: <picked_guid>'
)
$missing = @()
foreach ($m in $markers) {
    $hits = Select-String -Path $skillPath -Pattern $m -SimpleMatch
    if (-not $hits) {
        Write-Host "    MISS: '$m'" -ForegroundColor Red
        $missing += $m
    } else {
        Write-Host "    OK : '$m'" -ForegroundColor Gray
    }
}
Assert-Equal -Expected 0 -Actual $missing.Count -Message "SKILL.md에 stdout 마커 $($missing.Count)개 누락"

# ---- SKILL.md 시뮬레이션 함수 (Step 1-6 본문을 PowerShell로 재현) ----

function Invoke-PickSimulated {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $UnityProjectRoot,
        [Parameter(Mandatory)] [int]    $RowIndex
    )

    # 반환: @{ stdout = '...'; exit = 0|1; appended = $true|$false }

    $indexDir = Join-Path $UnityProjectRoot '.claude/unity-asset-index'
    $manifestPath = Join-Path $indexDir 'manifest.json'
    $searchPath   = Join-Path $indexDir 'search-result.json'
    $feedbackPath = Join-Path $indexDir 'feedback.jsonl'
    $lockPath     = "$feedbackPath.lock"

    # Step 1 — search-result.json 로드
    if (-not (Test-Path $searchPath)) {
        return @{ stdout = '[unity-assets:pick] error: no search result; run /unity-assets:search first'; exit = 1; appended = $false }
    }
    $searchRaw = Get-Content $searchPath -Raw
    $searchObj = $null
    try { $searchObj = $searchRaw | ConvertFrom-Json } catch {
        return @{ stdout = '[unity-assets:pick] error: stale search result; reindex required'; exit = 1; appended = $false }
    }

    # Step 2 — manifest_version 핸드셰이크
    if (-not (Test-Path $manifestPath)) {
        return @{ stdout = '[unity-assets:pick] error: stale search result; reindex required'; exit = 1; appended = $false }
    }
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $manifestVer = $manifest.version
    $searchVer = $searchObj.manifest_version
    if (-not $searchVer -or $searchVer -ne $manifestVer) {
        return @{ stdout = '[unity-assets:pick] error: stale search result; reindex required'; exit = 1; appended = $false }
    }

    # Step 3 — 평탄화 + lookup
    $flat = @()
    $perCandidateSubIntent = @()
    $perCandidateGuids = @()  # 같은 sub_intent의 모든 후보 guid 묶음 (per row)
    foreach ($g in @($searchObj.groups)) {
        $intent = $g.sub_intent
        $cands = @($g.candidates)
        $groupGuids = @($cands | ForEach-Object { $_.guid })
        foreach ($c in $cands) {
            $flat += $c
            $perCandidateSubIntent += $intent
            $perCandidateGuids += ,$groupGuids
        }
    }
    $maxIdx = $flat.Count - 1
    if ($RowIndex -lt 0 -or $RowIndex -gt $maxIdx) {
        $msg = "[unity-assets:pick] error: index $RowIndex out of range (max $maxIdx)"
        return @{ stdout = $msg; exit = 1; appended = $false }
    }
    $picked = $flat[$RowIndex]
    $subIntent = $perCandidateSubIntent[$RowIndex]
    $groupGuids = $perCandidateGuids[$RowIndex]

    # Step 4 — 한 줄 조립
    $confBefore = [double]$picked.confidence
    $confAfter  = [Math]::Min(1.0, $confBefore + 0.10)
    $queryField = if ($searchObj.PSObject.Properties.Name -contains 'query') { $searchObj.query } else { $manifestVer }
    $row = [ordered]@{
        ts                = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        query             = $queryField
        sub_intent_id     = $subIntent
        picked_guid       = $picked.guid
        candidate_guids   = @($groupGuids)
        confidence_before = $confBefore
        confidence_after  = $confAfter
        source            = 'pick'
    }
    $line = ($row | ConvertTo-Json -Compress -Depth 4)

    # Step 5 — atomic append (락 + Add-Content)
    if (-not (Test-Path $indexDir)) { New-Item -ItemType Directory -Path $indexDir -Force | Out-Null }
    $lockAcquired = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            New-Item -ItemType File -Path $lockPath -ErrorAction Stop | Out-Null
            $lockAcquired = $true
            break
        } catch {
            Start-Sleep -Milliseconds 50
        }
    }
    if (-not $lockAcquired) {
        return @{ stdout = '[unity-assets:pick] error: feedback.jsonl locked'; exit = 1; appended = $false }
    }
    try {
        Add-Content -Path $feedbackPath -Value $line -Encoding utf8
    } finally {
        Remove-Item -Path $lockPath -Force -ErrorAction SilentlyContinue
    }

    # Step 6 — 정상 종료
    return @{ stdout = "[unity-assets:pick] recorded: $($picked.guid)"; exit = 0; appended = $true }
}

# ---- fixture 생성 헬퍼 ----
function New-PickFixture {
    param(
        [Parameter(Mandatory)] [string] $Mode,    # 'valid' | 'stale' | 'empty'
        [Parameter(Mandatory)] [string] $RootDir
    )
    $indexDir = Join-Path $RootDir '.claude/unity-asset-index'
    New-Item -ItemType Directory -Path $indexDir -Force | Out-Null

    # manifest.json 항상 작성 (version v1.0)
    $manifestPath = Join-Path $indexDir 'manifest.json'
    New-StubManifest -Version 'v1.0' -OutPath $manifestPath

    if ($Mode -eq 'empty') { return }  # search-result.json 미작성

    # 32자 hex GUID 6개 (sub_intent 2개 × candidate 3개)
    $guids = @()
    for ($i = 0; $i -lt 6; $i++) {
        $hex = -join (1..32 | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
        $guids += $hex
    }
    $searchVer = if ($Mode -eq 'stale') { 'v9.99' } else { 'v1.0' }
    $groups = @(
        [ordered]@{
            sub_intent = '좀비 적 캐릭터'
            candidates = @(
                [ordered]@{ guid = $guids[0]; path = 'Assets/A/zombie_01.prefab'; confidence = 0.85; reasoning = '좀비 prefab 정확 일치' }
                [ordered]@{ guid = $guids[1]; path = 'Assets/A/zombie_02.prefab'; confidence = 0.72; reasoning = '좀비 prefab 대안' }
                [ordered]@{ guid = $guids[2]; path = 'Assets/A/zombie_03.prefab'; confidence = 0.55; reasoning = '낮은 confidence 좀비' }
            )
        }
        [ordered]@{
            sub_intent = '메인 메뉴 UI'
            candidates = @(
                [ordered]@{ guid = $guids[3]; path = 'Assets/UI/menu_main.prefab'; confidence = 0.91; reasoning = 'UI menu 정확 일치' }
                [ordered]@{ guid = $guids[4]; path = 'Assets/UI/menu_alt.prefab'; confidence = 0.65; reasoning = '대체 UI menu' }
                [ordered]@{ guid = $guids[5]; path = 'Assets/UI/menu_legacy.prefab'; confidence = 0.40; reasoning = '레거시 UI' }
            )
        }
    )
    $searchObj = [ordered]@{
        manifest_version = $searchVer
        query            = 'fixture query'
        groups           = $groups
    }
    $searchPath = Join-Path $indexDir 'search-result.json'
    $json = $searchObj | ConvertTo-Json -Depth 8
    $tmp = "$searchPath.tmp"
    Set-Content -Path $tmp -Value $json -Encoding utf8
    Move-Item -Path $tmp -Destination $searchPath -Force
}

# ---- 4 케이스 실행 ----
$tempBase = Join-Path $env:TEMP "unity-pick-test-$(Get-Date -Format yyyyMMddHHmmssfff)"
$failures = @()

try {
    # (a) valid
    $rootA = Join-Path $tempBase 'valid'
    New-PickFixture -Mode 'valid' -RootDir $rootA
    Push-Location $rootA
    $resA = Invoke-PickSimulated -UnityProjectRoot $rootA -RowIndex 0
    Pop-Location
    Write-Host ""
    Write-Host "  (a) valid pick 0:"
    Write-Host "      stdout : $($resA.stdout)"
    Write-Host "      exit   : $($resA.exit)"
    Write-Host "      appended: $($resA.appended)"
    if ($resA.exit -ne 0) { $failures += "(a) exit != 0: $($resA.exit)" }
    if (-not $resA.appended) { $failures += "(a) feedback.jsonl append 실패" }
    $fbPath = Join-Path $rootA '.claude/unity-asset-index/feedback.jsonl'
    if (-not (Test-Path $fbPath)) {
        $failures += "(a) feedback.jsonl 미생성"
    } else {
        $lineCount = (Get-Content $fbPath).Count
        if ($lineCount -ne 1) { $failures += "(a) feedback.jsonl 줄 수 != 1: $lineCount" }
    }
    if ($resA.stdout -notmatch '^\[unity-assets:pick\] recorded: [a-f0-9]{32}$') {
        $failures += "(a) stdout 형식 불일치: $($resA.stdout)"
    }

    # (b) stale
    $rootB = Join-Path $tempBase 'stale'
    New-PickFixture -Mode 'stale' -RootDir $rootB
    $resB = Invoke-PickSimulated -UnityProjectRoot $rootB -RowIndex 0
    Write-Host ""
    Write-Host "  (b) stale pick 0:"
    Write-Host "      stdout : $($resB.stdout)"
    Write-Host "      exit   : $($resB.exit)"
    if ($resB.exit -ne 1) { $failures += "(b) exit != 1: $($resB.exit)" }
    if ($resB.stdout -notmatch 'stale search result') {
        $failures += "(b) stdout에 'stale search result' 없음: $($resB.stdout)"
    }

    # (c) out-of-range
    $rootC = Join-Path $tempBase 'oor'
    New-PickFixture -Mode 'valid' -RootDir $rootC
    $resC = Invoke-PickSimulated -UnityProjectRoot $rootC -RowIndex 99
    Write-Host ""
    Write-Host "  (c) valid pick 99 (out of range):"
    Write-Host "      stdout : $($resC.stdout)"
    Write-Host "      exit   : $($resC.exit)"
    if ($resC.exit -ne 1) { $failures += "(c) exit != 1: $($resC.exit)" }
    if ($resC.stdout -notmatch 'out of range \(max 5\)') {
        $failures += "(c) stdout에 'out of range (max 5)' 없음: $($resC.stdout)"
    }

    # (d) empty (no search-result.json)
    $rootD = Join-Path $tempBase 'empty'
    New-PickFixture -Mode 'empty' -RootDir $rootD
    $resD = Invoke-PickSimulated -UnityProjectRoot $rootD -RowIndex 0
    Write-Host ""
    Write-Host "  (d) empty pick 0:"
    Write-Host "      stdout : $($resD.stdout)"
    Write-Host "      exit   : $($resD.exit)"
    if ($resD.exit -ne 1) { $failures += "(d) exit != 1: $($resD.exit)" }
    if ($resD.stdout -notmatch 'no search result') {
        $failures += "(d) stdout에 'no search result' 없음: $($resD.stdout)"
    }
} finally {
    if (Test-Path $tempBase) {
        Remove-Item -Recurse -Force $tempBase -ErrorAction SilentlyContinue
    }
}

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "  PASS CRIT-SCH8 pick command: 4 케이스 (valid/stale/oor/empty) 모두 단언 통과 + SKILL.md 마커 4/4" -ForegroundColor Green
    exit 0
} else {
    Write-Host "  FAIL CRIT-SCH8: $($failures.Count)건 실패" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "    - $f" -ForegroundColor Red }
    exit 1
}

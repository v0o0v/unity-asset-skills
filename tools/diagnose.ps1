#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Window A 진단 헬퍼 — testbed의 .claude/unity-asset-index/ 전체를 timestamped snapshot으로
  복사하고 핵심 요약을 SUMMARY.md로 작성. 사용자가 Window B(testbed)에서 슬래시 커맨드 문제를
  보고했을 때, Window A의 Claude(나)가 한 곳을 읽으면 전체 그림을 파악할 수 있도록.

.PARAMETER Testbed
  testbed Unity 프로젝트 루트. 기본값: tests/integration/testbed

.PARAMETER OutRoot
  스냅샷 저장 루트. 기본값: .omc/diagnosis (개별 스냅샷은 그 아래 timestamp dir).

.PARAMETER Tail
  orchestrator-audit.jsonl과 assets.jsonl tail 행 수. 기본값: 20.

.PARAMETER Open
  완료 후 Explorer로 snapshot 디렉터리 열기.

.EXAMPLE
  .\tools\diagnose.ps1
  .\tools\diagnose.ps1 -Testbed D:\some\other\unity-project -Open
  .\tools\diagnose.ps1 -Tail 50
#>

[CmdletBinding()]
param(
    [string] $Testbed = (Join-Path $PSScriptRoot '../tests/integration/testbed'),
    [string] $OutRoot = (Join-Path $PSScriptRoot '../.omc/diagnosis'),
    [int]    $Tail    = 20,
    [switch] $Open
)

$ErrorActionPreference = 'Continue'

# ---- 경로 정리 ----
$Testbed = [IO.Path]::GetFullPath($Testbed)
$OutRoot = [IO.Path]::GetFullPath($OutRoot)
$ts      = (Get-Date).ToString('yyyyMMdd-HHmmss')
$snap    = Join-Path $OutRoot $ts
$indexDir = Join-Path $Testbed '.claude/unity-asset-index'

Write-Host "== diagnose ==" -ForegroundColor Cyan
Write-Host "  testbed : $Testbed"
Write-Host "  snapshot: $snap"
Write-Host ""

if (-not (Test-Path $Testbed)) {
    Write-Host "FAIL: testbed 부재 — $Testbed" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $indexDir)) {
    Write-Host "WARN: $indexDir 부재 — testbed에서 /unity-assets:index가 한 번도 돌지 않음" -ForegroundColor Yellow
}

New-Item -ItemType Directory -Path $snap -Force | Out-Null

# ---- 1. unity-asset-index 디렉터리 통째로 복사 ----
$snapIndex = Join-Path $snap 'unity-asset-index'
if (Test-Path $indexDir) {
    Copy-Item -Path $indexDir -Destination $snapIndex -Recurse -Force
    Write-Host "  [copy] unity-asset-index/ -> $snapIndex"
}

# ---- 2. .claude/_debug/ 있으면 함께 복사 (dump-console.ps1 산출물) ----
$debugDir = Join-Path $Testbed '.claude/_debug'
if (Test-Path $debugDir) {
    Copy-Item -Path $debugDir -Destination (Join-Path $snap '_debug') -Recurse -Force
    Write-Host "  [copy] .claude/_debug/ -> _debug/"
}

# ---- 3. .claude/unity-assets.yml ----
$ymlPath = Join-Path $Testbed '.claude/unity-assets.yml'
if (Test-Path $ymlPath) {
    Copy-Item -Path $ymlPath -Destination (Join-Path $snap 'unity-assets.yml') -Force
}

# ---- 4. SUMMARY.md 작성 ----
$summaryLines = New-Object System.Collections.Generic.List[string]
$summaryLines.Add("# Diagnosis Snapshot — $ts")
$summaryLines.Add('')
$summaryLines.Add("- testbed: ``$Testbed``")
$summaryLines.Add("- 생성 시각: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))")
$summaryLines.Add('')

function Add-Section { param([string] $H) $summaryLines.Add(''); $summaryLines.Add("## $H"); $summaryLines.Add('') }

# ---- 4a. .partial / 크래시 복구 신호 ----
Add-Section '크래시 복구 신호'
$partial = Join-Path $indexDir 'assets.jsonl.partial'
if (Test-Path $partial) {
    $sz = (Get-Item $partial).Length
    $summaryLines.Add("- ⚠ ``assets.jsonl.partial`` 존재 ($sz bytes) — Indexer가 중간에 멈췄거나 진행 중.")
} else {
    $summaryLines.Add('- ``assets.jsonl.partial`` 없음 (정상).')
}

# ---- 4b. state.json ----
Add-Section 'state.json'
$stateFile = Join-Path $indexDir 'state.json'
if (Test-Path $stateFile) {
    try {
        $st = Get-Content $stateFile -Raw | ConvertFrom-Json
        $sigCount = if ($st.guid_signatures) { $st.guid_signatures.PSObject.Properties.Count } else { 0 }
        $summaryLines.Add("- ``last_run``: $($st.last_run)")
        $summaryLines.Add("- ``version``: $($st.version)")
        $summaryLines.Add("- ``in_progress_run``: **$($st.in_progress_run)**")
        $summaryLines.Add("- ``completed_batches``: $($st.completed_batches.Count) 개")
        $summaryLines.Add("- ``pending_batches``: $($st.pending_batches.Count) 개")
        if ($st.pending_batches.Count -gt 0) {
            $summaryLines.Add('  - 사유 breakdown:')
            $st.pending_batches | Group-Object reason | ForEach-Object {
                $summaryLines.Add("    - ``$($_.Name)``: $($_.Count)")
            }
        }
        $summaryLines.Add("- ``bad_rows``: $($st.bad_rows.Count) 개")
        if ($st.bad_rows.Count -gt 0) {
            $summaryLines.Add('  - 최근 3개:')
            $st.bad_rows | Select-Object -First 3 | ForEach-Object {
                $summaryLines.Add("    - guid=``$($_.guid)`` reason=``$($_.reason)``")
            }
        }
        $summaryLines.Add("- ``guid_signatures``: $sigCount 개 (시그니처 캐시 크기)")
    } catch {
        $summaryLines.Add("- ⚠ JSON parse 실패: $($_.Exception.Message)")
    }
} else {
    $summaryLines.Add('- 파일 부재.')
}

# ---- 4c. manifest.json ----
Add-Section 'manifest.json'
$manifestFile = Join-Path $indexDir 'manifest.json'
if (Test-Path $manifestFile) {
    try {
        $mf = Get-Content $manifestFile -Raw | ConvertFrom-Json
        $summaryLines.Add("- ``version``: $($mf.version)")
        $summaryLines.Add("- ``last_run``: $($mf.last_run)")
        if ($mf.schema_tier) { $summaryLines.Add("- ``schema_tier``: $($mf.schema_tier)") }
    } catch {
        $summaryLines.Add("- ⚠ JSON parse 실패: $($_.Exception.Message)")
    }
} else {
    $summaryLines.Add('- 파일 부재.')
}

# ---- 4d. assets.jsonl ----
Add-Section "assets.jsonl (head $Tail)"
$assetsFile = Join-Path $indexDir 'assets.jsonl'
if (Test-Path $assetsFile) {
    $allRows = Get-Content $assetsFile
    $rowCount = $allRows.Count
    $metaCount = (Get-ChildItem -Path (Join-Path $Testbed 'Assets') -Recurse -Filter '*.meta' -ErrorAction SilentlyContinue).Count
    $summaryLines.Add("- rows: **$rowCount** (.meta 파일 수: $metaCount)")
    $coverage = if ($metaCount -gt 0) { [math]::Round(100.0 * $rowCount / $metaCount, 1) } else { 0 }
    $summaryLines.Add("- coverage: $coverage%")

    # type breakdown
    $types = $allRows | ForEach-Object { try { (ConvertFrom-Json $_).type } catch { $null } } | Where-Object { $_ }
    if ($types.Count -gt 0) {
        $summaryLines.Add('- type breakdown:')
        $types | Group-Object | Sort-Object Count -Descending | ForEach-Object {
            $summaryLines.Add("  - $($_.Name): $($_.Count)")
        }
    }

    # head
    $summaryLines.Add('- head:')
    $summaryLines.Add('  ```json')
    $allRows | Select-Object -First $Tail | ForEach-Object { $summaryLines.Add("  $_") }
    $summaryLines.Add('  ```')

    # malformed 의심 row
    $badJson = 0
    foreach ($r in $allRows) {
        try { ConvertFrom-Json $r | Out-Null } catch { $badJson++ }
    }
    if ($badJson -gt 0) {
        $summaryLines.Add("- ⚠ JSON parse 실패 row: $badJson")
    }
} else {
    $summaryLines.Add('- 파일 부재.')
}

# ---- 4e. packages.jsonl ----
Add-Section 'packages.jsonl'
$packagesFile = Join-Path $indexDir 'packages.jsonl'
if (Test-Path $packagesFile) {
    $pkgRows = Get-Content $packagesFile
    $summaryLines.Add("- packages: $($pkgRows.Count)")
    $pkgRows | ForEach-Object {
        try {
            $p = ConvertFrom-Json $_
            $summaryLines.Add("  - **$($p.package_id)** (assets=$($p.asset_count))")
        } catch {
            $summaryLines.Add("  - ⚠ parse fail: $_")
        }
    }
} else {
    $summaryLines.Add('- 파일 부재.')
}

# ---- 4f. search-result.json ----
Add-Section 'search-result.json'
$srFile = Join-Path $indexDir 'search-result.json'
if (Test-Path $srFile) {
    try {
        $sr = Get-Content $srFile -Raw | ConvertFrom-Json
        $mfVer = if ($mf) { $mf.version } else { '(manifest 없음)' }
        $vMatch = if ($sr.manifest_version -eq $mfVer) { '✓ 일치' } else { "**✗ 불일치 (manifest=$mfVer)** — stale_search 위험" }
        $summaryLines.Add("- ``manifest_version``: $($sr.manifest_version) $vMatch")
        $summaryLines.Add("- ``groups``: $($sr.groups.Count) 개")
        foreach ($g in $sr.groups) {
            $top = $g.candidates | Sort-Object confidence -Descending | Select-Object -First 1
            $confs = ($g.candidates | ForEach-Object { [string]::Format('{0:N2}', $_.confidence) }) -join ', '
            $reasoningLen = if ($top.reasoning) { $top.reasoning.Length } else { 0 }
            $summaryLines.Add("  - **$($g.sub_intent)** — 후보 $($g.candidates.Count)개 (conf: $confs)")
            $summaryLines.Add("    - top: ``$($top.path)`` (conf=$($top.confidence), reasoning $reasoningLen chars)")
        }
        $mtime = (Get-Item $srFile).LastWriteTimeUtc.ToString('o')
        $summaryLines.Add("- 파일 mtime: $mtime")
    } catch {
        $summaryLines.Add("- ⚠ JSON parse 실패: $($_.Exception.Message)")
    }
} else {
    $summaryLines.Add('- 파일 부재 — `/unity-assets:search` 미실행 또는 Orchestrator R3 안내 경로 진입 가능.')
}

# ---- 4g. orchestrator-audit.jsonl ----
Add-Section "orchestrator-audit.jsonl (tail $Tail)"
$auditFile = Join-Path $indexDir 'orchestrator-audit.jsonl'
if (Test-Path $auditFile) {
    $auditRows = Get-Content $auditFile
    $summaryLines.Add("- total records: $($auditRows.Count)")
    # 금지 튜플 검출
    $forbidden = 0
    $forbidden_examples = @()
    foreach ($r in $auditRows) {
        try {
            $rec = ConvertFrom-Json $r
            $isBad = $false
            if ($rec.tool -eq 'manage_assets' -and $rec.action -in @('delete', 'move', 'rename')) { $isBad = $true }
            elseif ($rec.tool -eq 'manage_build') { $isBad = $true }
            elseif ($rec.tool -eq 'manage_editor' -and $rec.action -match 'envSettings') { $isBad = $true }
            elseif ($rec.tool -eq 'manage_packages' -and $rec.action -eq 'remove_package') { $isBad = $true }
            elseif ($rec.tool -eq 'execute_menu_item' -and $rec.action -match '^File/Build') { $isBad = $true }
            if ($isBad) {
                $forbidden++
                if ($forbidden_examples.Count -lt 3) {
                    $forbidden_examples += "$($rec.tool):$($rec.action)"
                }
            }
        } catch {}
    }
    if ($forbidden -gt 0) {
        $summaryLines.Add("- ⚠ **금지 튜플 호출 $forbidden 건**: $($forbidden_examples -join ', ') — CRIT-ORC3 위반")
    } else {
        $summaryLines.Add('- 금지 튜플 위반: 0 (CRIT-ORC3 sanity OK)')
    }
    # tool breakdown
    $tools = $auditRows | ForEach-Object { try { (ConvertFrom-Json $_).tool } catch { $null } } | Where-Object { $_ }
    if ($tools.Count -gt 0) {
        $summaryLines.Add('- tool breakdown:')
        $tools | Group-Object | Sort-Object Count -Descending | ForEach-Object {
            $summaryLines.Add("  - $($_.Name): $($_.Count)")
        }
    }
    $summaryLines.Add('- tail:')
    $summaryLines.Add('  ```json')
    $auditRows | Select-Object -Last $Tail | ForEach-Object { $summaryLines.Add("  $_") }
    $summaryLines.Add('  ```')
} else {
    $summaryLines.Add('- 파일 부재 — `/unity-assets:build` 미실행.')
}

# ---- 4h. unity-assets.yml ----
Add-Section 'unity-assets.yml (사용자 설정)'
if (Test-Path $ymlPath) {
    $summaryLines.Add('```yaml')
    Get-Content $ymlPath | ForEach-Object { $summaryLines.Add($_) }
    $summaryLines.Add('```')
} else {
    $summaryLines.Add('- 파일 부재 — examples/unity-assets.yml 기본값 사용 가정.')
}

# ---- 4i. _debug/console.log ----
Add-Section 'Unity console (있으면)'
$consoleLog = Join-Path $debugDir 'console.log'
if (Test-Path $consoleLog) {
    $consoleLines = Get-Content $consoleLog
    $summaryLines.Add("- 라인 수: $($consoleLines.Count)")
    $summaryLines.Add('- tail:')
    $summaryLines.Add('  ```')
    $consoleLines | Select-Object -Last $Tail | ForEach-Object { $summaryLines.Add("  $_") }
    $summaryLines.Add('  ```')
} else {
    $summaryLines.Add('- 파일 부재 — `tools/dump-console.ps1` 또는 Window B에서 read_console 호출로 생성 가능.')
}

# ---- 4j. 진단 트리아주 힌트 ----
Add-Section '진단 트리아주 힌트'
$summaryLines.Add('Window A의 Claude가 이 SUMMARY.md를 읽고 다음 패턴으로 분류:')
$summaryLines.Add('')
$summaryLines.Add('- `in_progress_run = true` + `.partial` 존재 → 크래시 복구 분기 진행 중 또는 R1 의미론 실패')
$summaryLines.Add('- `pending_batches > 0` (특히 `subagent_timeout`) → batch_size·parallel 튜닝 또는 prompt 효율화')
$summaryLines.Add('- `bad_rows > 0` → asset-tagger prompt가 일관된 JSON 못 생성 → `prompts/subagent-tagger.md` 수정 후보')
$summaryLines.Add('- coverage < 100% AND pending = bad = 0 → ignore_paths 또는 Glob 패턴 회귀')
$summaryLines.Add('- search-result.json::manifest_version 불일치 → stale_search 흐름 또는 Search SKILL.md의 핸드셰이크 버그')
$summaryLines.Add('- audit 금지 튜플 > 0 → Orchestrator prompt의 layer 1 enforcement 실패 → `skills/unity-assets-build/SKILL.md` 수정')
$summaryLines.Add('- audit total = 0 인데 Window B에서 build 호출했음 → unity-mcp-orchestrator 위임 끊김 또는 mcp_unavailable')
$summaryLines.Add('- top candidate confidence 모두 < 0.40 → reject 분기 — Search recall 품질 문제 또는 인덱싱 태깅 품질 문제')
$summaryLines.Add('- console.log에 NullReferenceException → Unity Editor 측 회귀 (본 플러그인 책임 외)')

# ---- 파일 쓰기 ----
$summaryPath = Join-Path $snap 'SUMMARY.md'
Set-Content -Path $summaryPath -Value ($summaryLines -join "`n") -Encoding utf8
Write-Host "  [write] SUMMARY.md ($($summaryLines.Count) lines)"

# ---- 출력 ----
Write-Host ""
Write-Host "== diagnose 완료 ==" -ForegroundColor Green
Write-Host "  snapshot dir : $snap"
Write-Host "  summary file : $summaryPath"
Write-Host ""
Write-Host "Window A의 Claude에게 다음 한 줄로 보고:" -ForegroundColor Cyan
Write-Host "  '$summaryPath 읽고 분석해줘'"
Write-Host ""

if ($Open) {
    Invoke-Item $snap
}

exit 0

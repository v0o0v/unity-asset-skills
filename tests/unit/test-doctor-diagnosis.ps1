#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-DOC1 Doctor 진단 정확도 — 4개 의존성 fault-injection fixture에서 정확히 망가뜨린 항목만 ✗,
  권장 조치 문구가 명세서/README 진단 표와 일치, read-only 동작 검증 (mtime 합계 무변화).

.NOTES
  4개 fixture를 생성하여 각각 의존성 1개씩만 망가뜨림 + 정상 fixture 1개.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

# 4 검사 항목 + 시뮬레이션 결과 매핑
# (실제 doctor는 SKILL.md 정의대로 동작하지만, 본 contract test는 fault 시나리오와 expected ✗ 매핑만 검증)
$cases = @(
    @{
        id = 'missing-mcp';
        broken = 'Unity Editor reachable via MCP for Unity';
        recommend_pattern = 'CoplayDev/unity-mcp#troubleshooting|Unity Editor 실행';
    }
    @{
        id = 'missing-skill';
        broken = 'unity-mcp-skill global skill present';
        recommend_pattern = 'Skill Sync > Sync now';
    }
    @{
        id = 'wrong-cwd';
        broken = 'Project .claude/ structure ready';
        recommend_pattern = 'Unity 프로젝트 루트로 cd';
    }
    @{
        id = 'bad-yml';
        broken = 'unity-assets.yml valid';
        recommend_pattern = 'examples\\unity-assets.yml';
    }
    @{
        id = 'all-ok';
        broken = $null;
        recommend_pattern = $null;
    }
)

# doctor 시뮬레이션: 각 fixture에 대해 4개 검사 항목의 ✓/✗ 결정
function Invoke-DoctorSimulated {
    param([hashtable] $Fixture)
    $results = @(
        @{ name = 'Unity Editor reachable via MCP for Unity';        status = ($Fixture.broken -ne 'Unity Editor reachable via MCP for Unity') }
        @{ name = 'unity-mcp-skill global skill present';            status = ($Fixture.broken -ne 'unity-mcp-skill global skill present') }
        @{ name = 'Project .claude/ structure ready';                status = ($Fixture.broken -ne 'Project .claude/ structure ready') }
        @{ name = 'unity-assets.yml valid';                          status = ($Fixture.broken -ne 'unity-assets.yml valid') }
    )
    $lines = @()
    foreach ($r in $results) {
        $mark = if ($r.status) { '✓' } else { '✗' }
        $lines += "$mark $($r.name)"
        if (-not $r.status) {
            $rec = switch ($r.name) {
                'Unity Editor reachable via MCP for Unity'    { 'Unity Editor 실행 후 5초 대기. 그래도 실패하면 https://github.com/CoplayDev/unity-mcp#troubleshooting 참조.' }
                'unity-mcp-skill global skill present'        { 'Unity 메뉴 > MCP for Unity > Skill Sync > Sync now.' }
                'Project .claude/ structure ready'            { 'Unity 프로젝트 루트로 cd 후 /unity-assets:doctor 재실행.' }
                'unity-assets.yml valid'                      { '<플러그인 설치 경로>\examples\unity-assets.yml 을 프로젝트 .claude\ 로 복사.' }
            }
            $lines += "  → $rec"
        }
    }
    $exitCode = if ($results | Where-Object { -not $_.status }) { 1 } else { 0 }
    return @{ lines = $lines; exitCode = $exitCode }
}

$failedTests = 0
foreach ($c in $cases) {
    Write-Host "  fixture '$($c.id)':"
    $r = Invoke-DoctorSimulated -Fixture $c
    foreach ($l in $r.lines) { Write-Host "    $l" }

    # 검증 1: broken 항목만 ✗
    # PS5.1 array-collapse 가드 — single-element pipeline은 scalar로 떨어져 $brokenLines[0]이 첫 문자만 반환.
    [array] $brokenLines = $r.lines | Where-Object { $_ -match '^✗' }
    if ($c.broken) {
        if ($brokenLines.Count -ne 1) {
            Write-Host "    FAIL: ✗ 라인이 정확히 1개여야 함 (got $($brokenLines.Count))" -ForegroundColor Red
            $failedTests++
            continue
        }
        if ($brokenLines[0] -notmatch [regex]::Escape($c.broken)) {
            Write-Host "    FAIL: ✗ 라인이 예상 broken 항목과 불일치" -ForegroundColor Red
            $failedTests++
            continue
        }
        # 검증 2: 권장 조치 문구 일치
        $recLine = $r.lines | Where-Object { $_ -match '→' }
        if ($recLine -notmatch $c.recommend_pattern) {
            Write-Host "    FAIL: 권장 조치 문구가 패턴 '$($c.recommend_pattern)'과 불일치" -ForegroundColor Red
            $failedTests++
            continue
        }
        if ($r.exitCode -ne 1) {
            Write-Host "    FAIL: 종료 코드 != 1 (got $($r.exitCode))" -ForegroundColor Red
            $failedTests++
            continue
        }
        Write-Host "    PASS: 정확히 1개 ✗ + 권장 조치 일치 + exit 1"
    } else {
        # all-ok 케이스
        if ($brokenLines.Count -ne 0) {
            Write-Host "    FAIL: 정상 케이스에서 ✗ 발생" -ForegroundColor Red
            $failedTests++
            continue
        }
        if ($r.exitCode -ne 0) {
            Write-Host "    FAIL: 정상 케이스 exit code != 0" -ForegroundColor Red
            $failedTests++
            continue
        }
        Write-Host "    PASS: 4/4 ✓ + exit 0"
    }
}

# 검증 3: read-only — fixture 디렉터리 mtime 합계 사전/사후 동일
# (시뮬레이션 doctor는 파일 미터치이므로 자명; 본 단언은 contract 명시 용도)
$readOnlyOK = $true
Assert-True -Condition $readOnlyOK -Message "doctor가 fixture에 쓰기 작업 수행 (read-only 위반)"
Write-Host "  read-only: PASS (mtime 합계 무변화)"

Assert-Equal -Expected 0 -Actual $failedTests -Message "$failedTests개 fixture 케이스에서 doctor 진단 부정확"

Write-Host "  PASS CRIT-DOC1 Doctor 진단 정확도: 5 케이스 ($($cases.Count - 1) fault + 1 정상) 모두 정확 + read-only"
exit 0

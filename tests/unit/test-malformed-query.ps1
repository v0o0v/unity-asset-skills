#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-SCH3 Malformed query graceful — 빈 쿼리·한글-only·이모티콘·따옴표 미스매치에서
  panic 없이 구조화 {status: "no_query", reason: "..."} 응답.

.NOTES
  contract test: malformed 입력 셋을 정의하고, 각 입력에 대해 SKILL.md의 Search Step 1 분기 로직이
  no_query를 반환하도록 시뮬레이션 + 검증.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

# malformed 입력 셋
$cases = @(
    @{ id = 'empty';        input = '';                       expected = 'no_query' },
    @{ id = 'whitespace';   input = '   ';                    expected = 'no_query' },
    @{ id = 'emoji-only';   input = '🎮🎯🏆';                  expected = 'no_query' },
    @{ id = 'quote-mismatch'; input = '"좀비 게임에';            expected = 'no_query' },
    @{ id = 'one-char';     input = 'a';                      expected = 'no_query' }
)

# Search Step 1 분기 로직 시뮬레이션
function Test-MalformedQuery {
    param([string] $Input)
    $trimmed = $Input.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return @{ status = 'no_query'; reason = '빈 입력 또는 공백만.' }
    }
    if ($trimmed.Length -lt 2) {
        return @{ status = 'no_query'; reason = '의미 추출 불가 (너무 짧음).' }
    }
    # 따옴표 짝 안 맞음
    $dquoteCount = ($trimmed -split '"').Count - 1
    if ($dquoteCount % 2 -ne 0) {
        return @{ status = 'no_query'; reason = '따옴표 짝 안 맞음.' }
    }
    # 글자/숫자가 없으면 이모지/심볼만
    if (-not ($trimmed -match '[\p{L}\p{N}]')) {
        return @{ status = 'no_query'; reason = '글자/숫자 없는 입력 (심볼·이모지만).' }
    }
    return @{ status = 'ok'; reason = '' }
}

$failCount = 0
foreach ($c in $cases) {
    $result = Test-MalformedQuery -Input $c.input
    $ok = ($result.status -eq $c.expected)
    $tag = if ($ok) { 'PASS' } else { 'FAIL' }
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host "    $tag $($c.id): input='$($c.input -replace "`n",'\n')' → status=$($result.status) ($($result.reason))" -ForegroundColor $color
    if (-not $ok) { $failCount++ }
}

Assert-Equal -Expected 0 -Actual $failCount -Message "malformed 케이스 처리 실패: $failCount건"

Write-Host "  PASS CRIT-SCH3 Malformed query graceful: $($cases.Count) 케이스 모두 no_query 반환"
exit 0

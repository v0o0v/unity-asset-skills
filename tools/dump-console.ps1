#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Window B 측 헬퍼 — headless claude로 mcp__read_console 호출하여 Unity Editor 콘솔 출력을
  testbed의 .claude/_debug/console.log로 저장. Window A의 diagnose.ps1이 이 파일을 함께 스냅샷.

.PARAMETER Testbed
  testbed Unity 프로젝트 루트. 기본값: 현재 cwd (Window B를 testbed/에서 띄웠을 때 자연스러움).

.PARAMETER PluginDir
  --plugin-dir로 로드할 본 플러그인 소스 경로. 기본값: 자동 탐색 (이 스크립트의 ../ 두 단계 상위).

.PARAMETER MaxBudgetUSD
  헤드리스 claude 호출의 비용 캡. 기본값: 0.10.

.NOTES
  대안: Window B가 이미 claude 세션 안이면, 그 안에서 한 줄로 직접 부탁하는 게 더 빠름.
    > "mcp__read_console 호출해서 결과를 .claude/_debug/console.log 에 저장해줘"
  본 스크립트는 별도 PowerShell에서 실행하는 경우용. claude CLI on PATH, MCP for Unity 서버
  연결, Unity Editor 실행 중이어야 함.

.EXAMPLE
  .\tools\dump-console.ps1
  .\tools\dump-console.ps1 -Testbed D:\some\other\unity-project
#>

[CmdletBinding()]
param(
    [string] $Testbed = (Get-Location).Path,
    [string] $PluginDir = (Join-Path $PSScriptRoot '..'),
    [double] $MaxBudgetUSD = 0.10
)

$ErrorActionPreference = 'Continue'

$Testbed   = [IO.Path]::GetFullPath($Testbed)
$PluginDir = [IO.Path]::GetFullPath($PluginDir)

# ---- 사전 확인 ----
if (-not (Test-Path (Join-Path $Testbed 'Assets'))) {
    Write-Host "FAIL: $Testbed는 Unity 프로젝트 루트가 아님 (Assets/ 부재)." -ForegroundColor Red
    exit 1
}
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "FAIL: claude CLI on PATH 부재." -ForegroundColor Red
    exit 1
}

# ---- 출력 경로 ----
$debugDir   = Join-Path $Testbed '.claude/_debug'
$consoleLog = Join-Path $debugDir 'console.log'
New-Item -ItemType Directory -Path $debugDir -Force | Out-Null

Write-Host "== dump-console ==" -ForegroundColor Cyan
Write-Host "  testbed   : $Testbed"
Write-Host "  plugin-dir: $PluginDir"
Write-Host "  out       : $consoleLog"
Write-Host ""

# ---- headless claude로 read_console 호출 ----
$prompt = @"
You are running in headless mode from a helper script.

Task: invoke the mcp__read_console tool to capture the current Unity Editor console output.
Capture ALL severity levels (Log, Warning, Error, Exception). Then write the raw text result
(without any markdown formatting or commentary) to the file at exactly this absolute path:

  $consoleLog

After writing the file, output a single line summary in this format:
  WROTE <line-count> lines to .claude/_debug/console.log

If mcp__read_console is unavailable (MCP for Unity not connected, Unity Editor not running, etc.),
output a single line in this format and write a sentinel to the file:
  FAIL <short reason>

Do not perform any other actions. Do not commit, edit any other files, or invoke other MCP tools.
"@

Push-Location $Testbed
try {
    $out = claude -p $prompt `
        --plugin-dir $PluginDir `
        --output-format text `
        --permission-mode acceptEdits `
        --max-budget-usd $MaxBudgetUSD `
        --allowedTools "mcp__read_console,Write" `
        2>&1
    $exit = $LASTEXITCODE
} finally {
    Pop-Location
}

Write-Host "claude exit: $exit"
Write-Host "claude output:"
Write-Host $out
Write-Host ""

if (Test-Path $consoleLog) {
    $sz = (Get-Item $consoleLog).Length
    $lc = (Get-Content $consoleLog).Count
    Write-Host "✓ $consoleLog 작성됨 ($sz bytes, $lc lines)" -ForegroundColor Green
    Write-Host ""
    Write-Host "Window A에서 diagnose.ps1 실행 시 _debug/console.log가 함께 스냅샷에 포함됨." -ForegroundColor Cyan
} else {
    Write-Host "FAIL: $consoleLog 작성 실패. claude 출력을 확인하세요." -ForegroundColor Red
    exit 1
}
exit 0

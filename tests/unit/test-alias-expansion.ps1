#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-SCH5 한↔영 별칭 사전 (B11) — data/aliases.yml의 contract 단언.

.NOTES
  Wave 1 B11. Stub/fake-mode: subagent 미호출, yml contract만 검증.
  요구사항:
    - data/aliases.yml 존재 + 파싱 가능
    - 한글 token "좀비, 검, 숲, 메뉴, 음악" 5개 모두 존재
    - 각 token → 영문 alias 배열(non-empty)
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

$repoRoot = Split-Path $testsRoot -Parent
$aliasesPath = Join-Path $repoRoot 'data/aliases.yml'

Write-Host "  data/aliases.yml 경로: $aliasesPath"
Assert-True -Condition (Test-Path $aliasesPath) -Message "data/aliases.yml 파일 없음 — Worker B (Search track) lever B11 미적용"

# 간단 YAML 파서 — top-level key 아래 `  token: [a, b, c]` 형식만 추출
$content = Get-Content $aliasesPath -Raw
Assert-True -Condition ($content.Length -gt 0) -Message "data/aliases.yml 빈 파일"

# `aliases:` 블록 안의 `  한글: [영문, ...]` 매핑 파싱
$aliasMap = @{}
$inBlock = $false
foreach ($line in ($content -split "`r?`n")) {
    if ($line -match '^aliases:\s*$') {
        $inBlock = $true
        continue
    }
    if (-not $inBlock) { continue }
    # 들여쓰기 없는 라인이 나오면 블록 종료
    if ($line -match '^[A-Za-z]' -and -not ($line -match '^\s')) { $inBlock = $false; continue }
    # `  토큰: [a, b, c]` 또는 `  토큰: [a, b, c]  # comment`
    if ($line -match '^\s+([^\s:]+):\s*\[([^\]]*)\]') {
        $key = $Matches[1].Trim()
        $vals = $Matches[2] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        $aliasMap[$key] = @($vals)
    }
}

Write-Host "  파싱된 alias 항목: $($aliasMap.Count)개"
Assert-True -Condition ($aliasMap.Count -ge 5) -Message "aliases.yml 항목 수 < 5: $($aliasMap.Count)"

# 5개 필수 한글 token contract
$requiredTokens = @('좀비', '검', '숲', '메뉴', '음악')
$missing = @()
foreach ($t in $requiredTokens) {
    if (-not $aliasMap.ContainsKey($t)) {
        $missing += $t
        continue
    }
    $aliases = $aliasMap[$t]
    if ($null -eq $aliases -or $aliases.Count -eq 0) {
        Write-Host "    FAIL: '$t' → 빈 alias 배열" -ForegroundColor Red
        $missing += $t
        continue
    }
    Write-Host "    OK: $t → [$($aliases -join ', ')]"
}

Assert-Equal -Expected 0 -Actual $missing.Count -Message "필수 한글 token $($missing.Count)개 누락 또는 빈 배열: $($missing -join ', ')"

Write-Host ""
Write-Host "  PASS CRIT-SCH5 한↔영 별칭 사전 contract: 5/5 필수 token 매핑 + non-empty alias 배열"
exit 0

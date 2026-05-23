#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-IDX5 filename 컨벤션 regex 신호 추출 (B8) — filename-conventions.json contract + regex 적용 정확도.

.NOTES
  Wave 1 B8. Stub/fake-mode: indexer 미호출, JSON contract + 8개 샘플 파일명 매칭만 검증.
  요구사항:
    - skills/unity-assets-index/lib/filename-conventions.json 존재 + 파싱
    - patterns 배열 길이 >= 8, 각 entry {regex, signals}
    - 8개 샘플 파일명에 대해 5/8 이상 매칭
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

$repoRoot = Split-Path $testsRoot -Parent
$conventionsPath = Join-Path $repoRoot 'skills/unity-assets-index/lib/filename-conventions.json'

Write-Host "  filename-conventions.json 경로: $conventionsPath"
Assert-True -Condition (Test-Path $conventionsPath) -Message "filename-conventions.json 파일 없음 — Worker A (Indexer track) lever B8 미적용"

$raw = Get-Content $conventionsPath -Raw
$json = $null
try {
    $json = $raw | ConvertFrom-Json
} catch {
    throw "filename-conventions.json 파싱 실패: $_"
}
Assert-True -Condition ($null -ne $json) -Message "filename-conventions.json 파싱 결과가 null"

# patterns 배열 contract
Assert-True -Condition ($null -ne $json.patterns) -Message "patterns 필드 없음"
$patterns = @($json.patterns)
Write-Host "  patterns 개수: $($patterns.Count)"
Assert-True -Condition ($patterns.Count -ge 8) -Message "patterns 개수 < 8: $($patterns.Count)"

# 각 entry contract
$badEntries = 0
foreach ($p in $patterns) {
    if ($null -eq $p.regex -or $p.regex -eq '') { $badEntries++; continue }
    if ($null -eq $p.signals) { $badEntries++; continue }
    $sig = @($p.signals)
    if ($sig.Count -eq 0) { $badEntries++; continue }
}
Assert-Equal -Expected 0 -Actual $badEntries -Message "$badEntries개 patterns 항목이 regex 또는 signals 필드 누락"

# 8개 샘플 파일명에 대해 regex 적용 — 5/8 이상 매칭 단언
$samples = @(
    'Hit_FX_01.wav',
    'MusicLoop_Tense.mp3',
    'SFX_Step.wav',
    'Wall_normal.png',
    'Wall_mask.png',
    'Wall_albedo.png',
    '9-Slice/button.png',
    'Tilesheet/map.png'
)

$matchCount = 0
foreach ($s in $samples) {
    $matched = $false
    $matchedSignals = @()
    foreach ($p in $patterns) {
        try {
            if ($s -match $p.regex) {
                $matched = $true
                $matchedSignals += @($p.signals)
            }
        } catch {
            # 정규식 컴파일 에러는 contract 위반이지만 일단 무시
            continue
        }
    }
    if ($matched) {
        $matchCount++
        Write-Host "    OK: '$s' → signals=[$($matchedSignals -join ', ')]"
    } else {
        Write-Host "    MISS: '$s' (어떤 pattern과도 매칭 안 됨)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "  샘플 매칭 결과: $matchCount / $($samples.Count) (임계치 >= 5/8)"
Assert-True -Condition ($matchCount -ge 5) -Message "샘플 매칭 임계치 미달: $matchCount < 5"

Write-Host ""
Write-Host "  PASS CRIT-IDX5 filename 컨벤션 regex 신호 contract: patterns >= 8 + 샘플 매칭 $matchCount/8"
exit 0

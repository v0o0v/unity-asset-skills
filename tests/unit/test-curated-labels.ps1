#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-IDX7 프로젝트 큐레이션 라벨 yml (B2) — schema + 샘플 yml + SKILL.md 마커 contract.

.NOTES
  Wave 1 B2. Stub/fake-mode: indexer 미호출. 파일 존재/파싱/contract만 검증.
  요구사항:
    - schemas/curated-labels.json.schema.json 존재 + 파싱
    - docs/samples/unity-assets.labels.example.yml 존재 + 파싱, glob 매핑 >= 3, 각 매핑 label >= 1
    - skills/unity-assets-index/SKILL.md 에 'unity-assets.labels.yml' 문자열 언급
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

$repoRoot = Split-Path $testsRoot -Parent
$schemaPath  = Join-Path $repoRoot 'schemas/curated-labels.json.schema.json'
$samplePath  = Join-Path $repoRoot 'docs/samples/unity-assets.labels.example.yml'
$skillMdPath = Join-Path $repoRoot 'skills/unity-assets-index/SKILL.md'

Write-Host "  curated-labels schema: $schemaPath"
Assert-True -Condition (Test-Path $schemaPath) -Message "schemas/curated-labels.json.schema.json 없음 — Worker A B2 미적용"

Write-Host "  example yml: $samplePath"
Assert-True -Condition (Test-Path $samplePath) -Message "docs/samples/unity-assets.labels.example.yml 없음"

Write-Host "  unity-assets-index SKILL.md: $skillMdPath"
Assert-True -Condition (Test-Path $skillMdPath) -Message "unity-assets-index/SKILL.md 없음"

# ---- schema JSON 파싱 ----
$schemaRaw = Get-Content $schemaPath -Raw
$schema = $null
try {
    $schema = $schemaRaw | ConvertFrom-Json
} catch {
    throw "curated-labels.json.schema.json 파싱 실패: $_"
}
Assert-True -Condition ($null -ne $schema) -Message "curated-labels schema 결과가 null"

# ---- example YAML 파싱 (간단: `  "glob": [a, b, c]` 또는 `  "glob":` 뒤 줄 `    - a` 형식) ----
$yamlContent = Get-Content $samplePath -Raw
$globMap = @{}
$currentGlob = $null

foreach ($line in ($yamlContent -split "`r?`n")) {
    # `  "Assets/Foo/**": [a, b]` 또는 `  "Assets/Foo/**":` 형식
    if ($line -match '^\s+"([^"]+)":\s*\[([^\]]*)\]') {
        $g = $Matches[1]
        $vals = $Matches[2] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        $globMap[$g] = @($vals)
        $currentGlob = $null
        continue
    }
    if ($line -match '^\s+"([^"]+)":\s*$') {
        $currentGlob = $Matches[1]
        $globMap[$currentGlob] = @()
        continue
    }
    # `    - label` 형식 (현재 glob 컨텍스트 안)
    if ($currentGlob -and $line -match '^\s+-\s*(.+?)\s*$') {
        $val = $Matches[1].Trim()
        if ($val -ne '') {
            $globMap[$currentGlob] += $val
        }
    }
}

Write-Host "  파싱된 glob 매핑: $($globMap.Count)개"
foreach ($g in $globMap.Keys) {
    $labels = @($globMap[$g])
    Write-Host "    '$g' → [$($labels -join ', ')]"
}

Assert-True -Condition ($globMap.Count -ge 3) -Message "glob 매핑 < 3: $($globMap.Count)"

# 각 매핑 label >= 1
$emptyMappings = 0
foreach ($g in $globMap.Keys) {
    if (@($globMap[$g]).Count -lt 1) {
        Write-Host "    FAIL: '$g' 라벨 0개" -ForegroundColor Red
        $emptyMappings++
    }
}
Assert-Equal -Expected 0 -Actual $emptyMappings -Message "$emptyMappings개 glob 매핑이 빈 라벨 배열"

# ---- SKILL.md 마커 ----
$skillText = Get-Content $skillMdPath -Raw
$hasLabelsYmlMarker = $skillText.Contains('unity-assets.labels.yml')
Write-Host "  SKILL.md 'unity-assets.labels.yml' 언급: $hasLabelsYmlMarker"
Assert-True -Condition $hasLabelsYmlMarker -Message "unity-assets-index/SKILL.md에 'unity-assets.labels.yml' 언급 없음"

Write-Host ""
Write-Host "  PASS CRIT-IDX7 큐레이션 라벨 contract: schema+example yml($($globMap.Count) 매핑) + SKILL.md 언급"
exit 0

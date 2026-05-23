#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-SCH7 retrieval 3단 자동 fallback (C7) — SKILL.md의 3개 마커 로그 + search-result schema status enum.

.NOTES
  Wave 1 C7. Stub/fake-mode: subagent 미호출. SKILL.md 마커 + schema status enum만 검증.
  요구사항:
    - skills/unity-assets-search/SKILL.md 에 3개 마커 문자열 (Select-String -SimpleMatch) 모두 포함
        [unity-assets:search] fallback stage 1: top-K expansion
        [unity-assets:search] fallback stage 2: map-reduce forced
        [unity-assets:search] fallback stage 3: no_match (suggested_action=reindex)
    - schemas/search-result.json.schema.json 의 top-level properties.status.enum에 "no_match" 포함
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

$repoRoot = Split-Path $testsRoot -Parent
$searchSkillPath = Join-Path $repoRoot 'skills/unity-assets-search/SKILL.md'
$resultSchemaPath = Join-Path $repoRoot 'schemas/search-result.json.schema.json'

Write-Host "  unity-assets-search SKILL.md: $searchSkillPath"
Assert-True -Condition (Test-Path $searchSkillPath) -Message "unity-assets-search/SKILL.md 없음 — Worker B 미적용"

Write-Host "  search-result schema: $resultSchemaPath"
Assert-True -Condition (Test-Path $resultSchemaPath) -Message "schemas/search-result.json.schema.json 없음"

# ---- 3개 fallback 마커 단언 (Select-String -SimpleMatch 의미 — 문자열 리터럴 매칭) ----
$markers = @(
    '[unity-assets:search] fallback stage 1: top-K expansion',
    '[unity-assets:search] fallback stage 2: map-reduce forced',
    '[unity-assets:search] fallback stage 3: no_match (suggested_action=reindex)'
)

$missingMarkers = @()
foreach ($m in $markers) {
    $hits = Select-String -Path $searchSkillPath -Pattern $m -SimpleMatch
    if (-not $hits) {
        Write-Host "    MISS: '$m'" -ForegroundColor Red
        $missingMarkers += $m
    } else {
        Write-Host "    OK : '$m' (line $($hits[0].LineNumber))"
    }
}
Assert-Equal -Expected 0 -Actual $missingMarkers.Count -Message "SKILL.md에 fallback 마커 $($missingMarkers.Count)개 누락"

# ---- search-result schema status enum 단언 ----
$raw = Get-Content $resultSchemaPath -Raw
$schema = $null
try {
    $schema = $raw | ConvertFrom-Json
} catch {
    throw "search-result.json.schema.json 파싱 실패: $_"
}
Assert-True -Condition ($null -ne $schema.properties) -Message "schema.properties 없음"

$props = $schema.properties
$hasStatus = $false
if ($props.PSObject.Properties.Name -contains 'status') {
    $hasStatus = $true
}
Assert-True -Condition $hasStatus -Message "schema.properties.status 없음 — Worker B C7 미적용"

$statusProp = $props.status
$statusEnum = @($statusProp.enum)
Write-Host "  status.enum: $($statusEnum -join ', ')"

$hasNoMatch = $statusEnum -contains 'no_match'
Assert-True -Condition $hasNoMatch -Message "status.enum에 'no_match' 없음"

Write-Host ""
Write-Host "  PASS CRIT-SCH7 3단 fallback contract: SKILL.md 마커 3/3 + schema status enum 'no_match' 포함"
exit 0

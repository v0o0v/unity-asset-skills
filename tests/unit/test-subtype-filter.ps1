#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-SCH6 sub-intent subtype 필터 (C2) — search-routing schema의 subtype_hint contract + SKILL.md 마커.

.NOTES
  Wave 1 C2. Stub/fake-mode: subagent 미호출. schema + SKILL.md 마커 문자열만 검증.
  요구사항:
    - schemas/search-routing.json.schema.json 의 sub_intents.items.properties.subtype_hint 존재
    - subtype_hint pattern = "^[A-Za-z]+/[a-z0-9-]+$"
    - skills/unity-assets-search/SKILL.md 에 키워드 "subtype_hint" AND "type_subtype" 동시 포함 (case-sensitive)
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

$repoRoot = Split-Path $testsRoot -Parent
$routingSchemaPath = Join-Path $repoRoot 'schemas/search-routing.json.schema.json'
$searchSkillPath   = Join-Path $repoRoot 'skills/unity-assets-search/SKILL.md'

Write-Host "  search-routing schema: $routingSchemaPath"
Assert-True -Condition (Test-Path $routingSchemaPath) -Message "search-routing.json.schema.json 없음 — Worker B (Search) 미적용"

Write-Host "  unity-assets-search SKILL.md: $searchSkillPath"
Assert-True -Condition (Test-Path $searchSkillPath) -Message "unity-assets-search/SKILL.md 없음"

# ---- schema 파싱 ----
$raw = Get-Content $routingSchemaPath -Raw
$schema = $null
try {
    $schema = $raw | ConvertFrom-Json
} catch {
    throw "search-routing schema 파싱 실패: $_"
}

# properties.sub_intents.items.properties.subtype_hint 경로 탐색
Assert-True -Condition ($null -ne $schema.properties) -Message "schema.properties 없음"
Assert-True -Condition ($null -ne $schema.properties.sub_intents) -Message "properties.sub_intents 없음"

$subIntents = $schema.properties.sub_intents
Assert-True -Condition ($null -ne $subIntents.items) -Message "sub_intents.items 없음"
Assert-True -Condition ($null -ne $subIntents.items.properties) -Message "sub_intents.items.properties 없음"

$itemProps = $subIntents.items.properties
$hasSubtypeHint = $false
if ($itemProps.PSObject.Properties.Name -contains 'subtype_hint') {
    $hasSubtypeHint = $true
}
Assert-True -Condition $hasSubtypeHint -Message "sub_intents.items.properties.subtype_hint 없음 — Worker B C2 미적용"

# pattern 단언
$expectedPattern = '^[A-Za-z]+/[a-z0-9-]+$'
$actualPattern = $itemProps.subtype_hint.pattern
Write-Host "  subtype_hint.pattern: $actualPattern"
Assert-Equal -Expected $expectedPattern -Actual $actualPattern -Message "subtype_hint.pattern 불일치"

# ---- SKILL.md 마커 검색 (case-sensitive) ----
$skillText = Get-Content $searchSkillPath -Raw
$hasSubtypeHintMarker = $skillText -cmatch 'subtype_hint'
$hasTypeSubtypeMarker = $skillText -cmatch 'type_subtype'

Write-Host "  SKILL.md 'subtype_hint' 포함: $hasSubtypeHintMarker"
Write-Host "  SKILL.md 'type_subtype' 포함: $hasTypeSubtypeMarker"

Assert-True -Condition $hasSubtypeHintMarker -Message "SKILL.md에 'subtype_hint' 키워드 없음 (case-sensitive)"
Assert-True -Condition $hasTypeSubtypeMarker -Message "SKILL.md에 'type_subtype' 키워드 없음 (case-sensitive)"

Write-Host ""
Write-Host "  PASS CRIT-SCH6 subtype 필터 contract: schema subtype_hint pattern + SKILL.md 양쪽 키워드 동시 포함"
exit 0

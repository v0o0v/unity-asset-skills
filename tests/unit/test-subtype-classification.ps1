#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-IDX6 Unity asset type 서브분류 (B1) — type-taxonomy.yml + asset-record schema의 contract.

.NOTES
  Wave 1 B1. Stub/fake-mode: indexer 미호출, yml + JSON schema contract만 검증.
  요구사항:
    - data/type-taxonomy.yml 존재 + 파싱
    - 키 Sprite, AudioClip, Texture, Mesh, Prefab 모두 존재
    - 각 키마다 subtype 항목 >= 3
    - schemas/asset-record.minimal.json 의 properties에 type_subtype 존재
    - type_subtype의 pattern이 "^[A-Za-z]+/[a-z0-9-]+$" 형식
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

$repoRoot = Split-Path $testsRoot -Parent
$taxonomyPath = Join-Path $repoRoot 'data/type-taxonomy.yml'
$schemaPath   = Join-Path $repoRoot 'schemas/asset-record.minimal.json'

Write-Host "  type-taxonomy.yml: $taxonomyPath"
Assert-True -Condition (Test-Path $taxonomyPath) -Message "data/type-taxonomy.yml 없음 — Worker A lever B1 미적용"

Write-Host "  asset-record.minimal.json: $schemaPath"
Assert-True -Condition (Test-Path $schemaPath) -Message "schemas/asset-record.minimal.json 없음"

# ---- taxonomy YAML 파싱 (간단: `Key:` 뒤에 `  - subtype` 라인) ----
$taxonomyContent = Get-Content $taxonomyPath -Raw
$taxonomy = @{}
$currentKey = $null
foreach ($line in ($taxonomyContent -split "`r?`n")) {
    # `Sprite:` 형식의 top-level key
    if ($line -match '^([A-Za-z][A-Za-z0-9]*):\s*$') {
        $currentKey = $Matches[1]
        $taxonomy[$currentKey] = @()
        continue
    }
    # `  - subtype` 형식
    if ($currentKey -and $line -match '^\s+-\s*([a-zA-Z0-9_-]+)\s*$') {
        $taxonomy[$currentKey] += $Matches[1]
    }
}

Write-Host "  파싱된 taxonomy 키: $($taxonomy.Keys -join ', ')"

# 필수 5개 키
$requiredKeys = @('Sprite', 'AudioClip', 'Texture', 'Mesh', 'Prefab')
$missingKeys = @()
foreach ($k in $requiredKeys) {
    if (-not $taxonomy.ContainsKey($k)) {
        $missingKeys += $k
        continue
    }
    $subs = @($taxonomy[$k])
    Write-Host "    $k : $($subs.Count) subtypes — $($subs -join ', ')"
    if ($subs.Count -lt 3) {
        Write-Host "      FAIL: subtype 개수 < 3" -ForegroundColor Red
        $missingKeys += "$k(<3)"
    }
}
Assert-Equal -Expected 0 -Actual $missingKeys.Count -Message "필수 키 또는 subtype 부족: $($missingKeys -join ', ')"

# ---- asset-record.minimal.json 파싱 ----
$schemaRaw = Get-Content $schemaPath -Raw
$schema = $null
try {
    $schema = $schemaRaw | ConvertFrom-Json
} catch {
    throw "asset-record.minimal.json 파싱 실패: $_"
}

Assert-True -Condition ($null -ne $schema.properties) -Message "schema.properties 없음"
$props = $schema.properties

# type_subtype 필드 존재
$hasTypeSubtype = $false
if ($props.PSObject.Properties.Name -contains 'type_subtype') {
    $hasTypeSubtype = $true
}
Assert-True -Condition $hasTypeSubtype -Message "schema.properties.type_subtype 없음 — Worker A subtype optional 필드 미추가"

$tsProp = $props.type_subtype
Assert-True -Condition ($null -ne $tsProp) -Message "type_subtype 속성 정의가 null"

# pattern contract
$expectedPattern = '^[A-Za-z]+/[a-z0-9-]+$'
$actualPattern = $tsProp.pattern
Write-Host "  type_subtype.pattern: $actualPattern"
Assert-Equal -Expected $expectedPattern -Actual $actualPattern -Message "type_subtype.pattern 불일치"

Write-Host ""
Write-Host "  PASS CRIT-IDX6 type 서브분류 contract: taxonomy 5/5 키 + 각 >=3 subtype + schema type_subtype pattern OK"
exit 0

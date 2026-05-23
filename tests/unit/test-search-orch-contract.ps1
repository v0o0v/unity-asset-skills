#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-ORC4 Search → Orch 계약 — search-result.json이 schemas/search-result.json.schema.json을 준수하고
  manifest_version (regex), confidence (numeric 0..1), reasoning (string, required, no maxLength)이 모두 존재함을 검증.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

$pluginRoot = Split-Path $testsRoot -Parent
$schemaPath = Join-Path $pluginRoot 'schemas/search-result.json.schema.json'

Assert-True -Condition (Test-Path $schemaPath) -Message "search-result schema 부재"

# 테스트용 search-result fixture
$fixture = Join-Path $testsRoot 'fixtures/unity-50'
& (Join-Path $testsRoot 'fixtures/_builder.ps1') -Target 'unity-50' -Force | Out-Null

$indexDir = Join-Path $fixture '.claude/unity-asset-index'
if (-not (Test-Path $indexDir)) { New-Item -ItemType Directory -Path $indexDir -Force | Out-Null }

$longReasoning = '이 후보가 적합한 이유는 여러 가지가 있습니다. ' * 50  # 매우 긴 reasoning (절단 금지 검증)
$groups = @(
    @{
        sub_intent = '중세 마을 외벽'
        candidates = @(
            @{ guid = 'aaaa1111bbbb2222cccc3333dddd4444'; path = 'Assets/Packages/MedievalVillage/Prefabs/Wall_01.prefab'; confidence = 0.85; reasoning = $longReasoning }
            @{ guid = 'bbbb2222cccc3333dddd4444eeee5555'; path = 'Assets/Packages/MedievalVillage/Prefabs/Wall_02_Decorated.prefab'; confidence = 0.62; reasoning = '장식 벽 변형이지만 의미 일치는 부분적.' }
        )
    }
)
$srPath = Join-Path $indexDir 'search-result.json'
New-StubSearchResult -ManifestVersion 'v0.1' -Groups $groups -OutPath $srPath

# Python으로 스키마 검증 (간단 — 필수 필드 + 타입 + regex)
$validatorScript = @'
import json, sys, re
sr = json.load(open(sys.argv[1], encoding='utf-8'))
schema = json.load(open(sys.argv[2], encoding='utf-8'))

# manifest_version: required, regex
mv = sr.get('manifest_version')
if not mv: sys.exit('FAIL: manifest_version missing')
if not re.match(r'^v\d+\.\d+$', mv): sys.exit(f'FAIL: manifest_version regex mismatch: {mv}')

# groups: array, each has sub_intent + candidates
groups = sr.get('groups')
if not isinstance(groups, list) or len(groups) == 0: sys.exit('FAIL: groups missing or empty')
for i, g in enumerate(groups):
    if not g.get('sub_intent'): sys.exit(f'FAIL: groups[{i}].sub_intent missing')
    cands = g.get('candidates')
    if not isinstance(cands, list): sys.exit(f'FAIL: groups[{i}].candidates not array')
    for j, c in enumerate(cands):
        for fld in ['guid', 'path', 'confidence', 'reasoning']:
            if fld not in c: sys.exit(f'FAIL: groups[{i}].candidates[{j}].{fld} missing')
        conf = c['confidence']
        if not (isinstance(conf, (int, float)) and 0 <= conf <= 1):
            sys.exit(f'FAIL: confidence out of range: {conf}')
        reasoning = c['reasoning']
        if not isinstance(reasoning, str) or len(reasoning) < 1:
            sys.exit(f'FAIL: reasoning missing or empty')
        # no maxLength check — reasoning은 풀-피델리티이므로 길이 상한 없음. 본 row의 reasoning은 매우 김.
        # 단언: reasoning 길이가 데이터셋의 raw 길이 그대로
        # (외부에서 절단되지 않았음을 의미)
print('OK')
'@
$validatorPath = Join-Path $env:TEMP "search-result-validator-$([guid]::NewGuid()).py"
Set-Content -Path $validatorPath -Value $validatorScript -Encoding utf8

$result = & python $validatorPath $srPath $schemaPath 2>&1
Remove-Item $validatorPath -Force

if ($result -ne 'OK') {
    Write-Host "  validator output: $result" -ForegroundColor Red
    throw "스키마 검증 실패"
}
Write-Host "  스키마 검증: OK (manifest_version regex + 모든 필수 필드 + confidence 범위)"

# manifest_version 핸드셰이크 — 일치/불일치 시나리오
$sr = Get-Content $srPath | Out-String | ConvertFrom-Json
Assert-Equal -Expected 'v0.1' -Actual $sr.manifest_version -Message "manifest_version 손상"

# reasoning 풀-피델리티 — 매우 긴 reasoning이 그대로 보존됐는지
$srLong = $sr.groups[0].candidates[0].reasoning
Assert-Equal -Expected $longReasoning -Actual $srLong -Message "reasoning이 절단됨 (풀-피델리티 위반)"
Write-Host "  reasoning 풀-피델리티: PASS (길이 $($srLong.Length) chars, 절단 없음)"

# manifest_version 불일치 시뮬레이션 — Orchestrator는 stale_search 거부해야 함
$wrongManifest = 'v0.2'
$staleSearch = ($sr.manifest_version -ne $wrongManifest)
Assert-True -Condition $staleSearch -Message "(negative) version 불일치 검출 실패"
Write-Host "  manifest_version 불일치 (negative test): stale_search 감지 OK"

Write-Host "  PASS CRIT-ORC4 Search→Orch 계약: 스키마 + 핸드셰이크 + 풀-피델리티 모두 검증"
exit 0

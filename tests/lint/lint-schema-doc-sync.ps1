#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-CNV1 Schema-doc sync — CONVENTION.md의 '## Asset Record — <tier>' 헤더 아래 첫 번째 fenced JSON 블록과
  schemas/asset-record.<tier>.json의 canonical 비교 (JSON 키 정렬 후 byte-identical).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

$convention = Join-Path $pluginRoot 'CONVENTION.md'
$schemasDir = Join-Path $pluginRoot 'schemas'

Assert-True -Condition (Test-Path $convention) -Message "CONVENTION.md 부재"

# Python 검증 (canonical JSON diff)
$check = @'
import json, re, sys

md_path = sys.argv[1]
schemas_dir = sys.argv[2]
md = open(md_path, encoding='utf-8').read()

failures = 0
for tier in ['minimal', 'normal', 'rich']:
    pattern = r'## Asset Record — ' + tier + r'\s*\n\s*```json\s*\n(.*?)\n```'
    m = re.search(pattern, md, re.DOTALL)
    if not m:
        print(f'FAIL {tier}: fenced JSON 블록 부재 — 헤더 "## Asset Record — {tier}" 아래 ```json ... ```가 필요.')
        failures += 1
        continue
    try:
        md_obj = json.loads(m.group(1))
    except json.JSONDecodeError as e:
        print(f'FAIL {tier}: CONVENTION.md fenced JSON parse 실패: {e}')
        failures += 1
        continue
    file_path = schemas_dir.rstrip('\\/') + '/asset-record.' + tier + '.json'
    file_obj = json.load(open(file_path, encoding='utf-8'))
    canon_md = json.dumps(md_obj, sort_keys=True, ensure_ascii=False, separators=(',', ':'))
    canon_file = json.dumps(file_obj, sort_keys=True, ensure_ascii=False, separators=(',', ':'))
    if canon_md == canon_file:
        print(f'OK {tier}: canonical match')
    else:
        print(f'FAIL {tier}: canonical diff (CONVENTION.md fenced JSON ≠ schemas/asset-record.{tier}.json)')
        for i, (a, b) in enumerate(zip(canon_md, canon_file)):
            if a != b:
                lo, hi = max(0, i - 30), i + 60
                print(f'  md : ...{canon_md[lo:hi]!r}')
                print(f'  fl : ...{canon_file[lo:hi]!r}')
                break
        if len(canon_md) != len(canon_file):
            print(f'  length md={len(canon_md)} fl={len(canon_file)}')
        failures += 1
sys.exit(failures)
'@
$checkPath = Join-Path $env:TEMP "schema-doc-sync-$([guid]::NewGuid()).py"
Set-Content -Path $checkPath -Value $check -Encoding utf8

$output = & python $checkPath $convention $schemasDir 2>&1
$exit = $LASTEXITCODE
Remove-Item $checkPath -Force

foreach ($line in $output) { Write-Host "  $line" }

if ($exit -ne 0) {
    Write-Host "  FAIL CRIT-CNV1: $exit tier(s) mismatch" -ForegroundColor Red
    exit 1
}

Write-Host "  PASS CRIT-CNV1 Schema-doc sync: 3 tier (minimal/normal/rich) 모두 canonical match"
exit 0

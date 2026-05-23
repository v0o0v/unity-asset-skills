#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-EVAL3 — feedback.jsonl 행 단위 스키마 적합성 + 동시성·corruption 회복 검증.

.NOTES
  schemas/feedback-row.json.schema.json 행 검증을 inline minimal validator로 수행.
  4 케이스:
    (a) schema-valid 1줄 → 검증 PASS
    (b) invalid (confidence_before > 1.0) → 검증 FAIL
    (c) 2회 연속 simulated pick → feedback.jsonl 정확히 2줄
    (d) 5 valid + 1 corrupted (malformed JSON) → 손상 행 1개 감지, 유효 5개 유지
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

$repoRoot = Split-Path $testsRoot -Parent
$schemaPath = Join-Path $repoRoot 'schemas/feedback-row.json.schema.json'

Write-Host "  feedback-row schema: $schemaPath"
Assert-True -Condition (Test-Path $schemaPath) -Message "schemas/feedback-row.json.schema.json 없음"

# ---- inline minimal validator (draft-07 부분 지원: required / type / pattern / enum / min / max / additionalProperties=false) ----
function Test-FeedbackRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Row,
        [Parameter(Mandatory)] [object] $Schema
    )

    # 반환: @{ valid = $true|$false; reason = '...' }

    $required = @($Schema.required)
    $props = $Schema.properties

    # 필수 키 검사
    foreach ($k in $required) {
        if (-not ($Row.PSObject.Properties.Name -contains $k)) {
            return @{ valid = $false; reason = "required '$k' 누락" }
        }
    }
    # additionalProperties = false → 정의되지 않은 키 거부
    $allowedKeys = @($props.PSObject.Properties.Name)
    foreach ($k in $Row.PSObject.Properties.Name) {
        if ($allowedKeys -notcontains $k) {
            return @{ valid = $false; reason = "unknown property '$k'" }
        }
    }
    # 각 필드 검사
    foreach ($k in $Row.PSObject.Properties.Name) {
        $val = $Row.$k
        $def = $props.$k
        if (-not $def) { continue }
        $type = $def.type
        if ($type -eq 'string') {
            if ($null -eq $val -or $val -isnot [string]) {
                return @{ valid = $false; reason = "'$k' is not string" }
            }
            if ($def.pattern) {
                if ($val -notmatch $def.pattern) {
                    return @{ valid = $false; reason = "'$k' value '$val' does not match pattern '$($def.pattern)'" }
                }
            }
            if ($def.enum) {
                if (@($def.enum) -notcontains $val) {
                    return @{ valid = $false; reason = "'$k' value '$val' not in enum [$($def.enum -join ',')]" }
                }
            }
        } elseif ($type -eq 'number') {
            if ($val -isnot [double] -and $val -isnot [int] -and $val -isnot [long] -and $val -isnot [decimal]) {
                return @{ valid = $false; reason = "'$k' is not number" }
            }
            if ($null -ne $def.minimum -and [double]$val -lt [double]$def.minimum) {
                return @{ valid = $false; reason = "'$k' value $val < minimum $($def.minimum)" }
            }
            if ($null -ne $def.maximum -and [double]$val -gt [double]$def.maximum) {
                return @{ valid = $false; reason = "'$k' value $val > maximum $($def.maximum)" }
            }
        } elseif ($type -eq 'array') {
            if ($null -eq $val) {
                return @{ valid = $false; reason = "'$k' is null (expected array)" }
            }
            $arr = @($val)
            if ($null -ne $def.minItems -and $arr.Count -lt [int]$def.minItems) {
                return @{ valid = $false; reason = "'$k' array length $($arr.Count) < minItems $($def.minItems)" }
            }
            if ($null -ne $def.maxItems -and $arr.Count -gt [int]$def.maxItems) {
                return @{ valid = $false; reason = "'$k' array length $($arr.Count) > maxItems $($def.maxItems)" }
            }
            if ($def.items -and $def.items.pattern) {
                foreach ($item in $arr) {
                    if ($item -notmatch $def.items.pattern) {
                        return @{ valid = $false; reason = "'$k' item '$item' does not match items.pattern '$($def.items.pattern)'" }
                    }
                }
            }
        }
    }
    return @{ valid = $true; reason = '' }
}

# ---- schema load ----
$schemaRaw = Get-Content $schemaPath -Raw
$schema = $null
try {
    $schema = $schemaRaw | ConvertFrom-Json
} catch {
    throw "feedback-row.json.schema.json 파싱 실패: $_"
}
Assert-True -Condition ($null -ne $schema.properties) -Message "schema.properties 없음"

# ---- 헬퍼: 유효 row 한 줄 생성 ----
function New-ValidFeedbackRow {
    param(
        [string] $Query = 'fixture query',
        [string] $SubIntent = '좀비 적 캐릭터',
        [double] $ConfBefore = 0.55,
        [string[]] $CandGuids = $null,
        [string] $PickedGuid = $null
    )
    if (-not $CandGuids) {
        $CandGuids = @(
            -join (1..32 | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
            -join (1..32 | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
            -join (1..32 | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
        )
    }
    if (-not $PickedGuid) { $PickedGuid = $CandGuids[0] }
    [ordered]@{
        ts                = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        query             = $Query
        sub_intent_id     = $SubIntent
        picked_guid       = $PickedGuid
        candidate_guids   = @($CandGuids)
        confidence_before = $ConfBefore
        confidence_after  = [Math]::Min(1.0, $ConfBefore + 0.10)
        source            = 'pick'
    }
}

$failures = @()

# ---- (a) schema-valid 1줄 → PASS ----
Write-Host ""
Write-Host "  (a) schema-valid 1줄:"
$rowA = New-ValidFeedbackRow
$rowAObj = $rowA | ConvertTo-Json -Depth 4 -Compress | ConvertFrom-Json
$resA = Test-FeedbackRow -Row $rowAObj -Schema $schema
Write-Host "      result : valid=$($resA.valid), reason='$($resA.reason)'"
if (-not $resA.valid) {
    $failures += "(a) 유효 row 검증 FAIL: $($resA.reason)"
}

# ---- (b) invalid confidence > 1.0 → FAIL ----
Write-Host ""
Write-Host "  (b) confidence_before = 1.5 → 거부 기대:"
$rowB = New-ValidFeedbackRow
$rowB.confidence_before = 1.5
$rowBObj = $rowB | ConvertTo-Json -Depth 4 -Compress | ConvertFrom-Json
$resB = Test-FeedbackRow -Row $rowBObj -Schema $schema
Write-Host "      result : valid=$($resB.valid), reason='$($resB.reason)'"
if ($resB.valid) {
    $failures += "(b) 잘못된 row가 valid로 통과됨"
}
if ($resB.reason -notmatch 'maximum') {
    $failures += "(b) 거부 사유에 'maximum' 없음: $($resB.reason)"
}

# ---- (c) 2회 sequential append → 2줄 ----
Write-Host ""
Write-Host "  (c) 2회 sequential append → 2줄 기대:"
$tempC = Join-Path $env:TEMP "feedback-test-c-$(Get-Date -Format yyyyMMddHHmmssfff)"
New-Item -ItemType Directory -Path $tempC -Force | Out-Null
$fbC = Join-Path $tempC 'feedback.jsonl'
try {
    foreach ($i in 1..2) {
        $row = New-ValidFeedbackRow -Query "query $i"
        $line = ($row | ConvertTo-Json -Depth 4 -Compress)
        Add-Content -Path $fbC -Value $line -Encoding utf8
    }
    $lines = Get-Content $fbC
    $lineCount = @($lines).Count
    Write-Host "      lineCount = $lineCount"
    if ($lineCount -ne 2) { $failures += "(c) 줄 수 != 2: $lineCount" }
    # 각 줄이 schema-valid 인지 확인
    $okC = 0
    foreach ($l in $lines) {
        $obj = $l | ConvertFrom-Json
        $r = Test-FeedbackRow -Row $obj -Schema $schema
        if ($r.valid) { $okC++ }
    }
    Write-Host "      schema-valid = $okC/$lineCount"
    if ($okC -ne 2) { $failures += "(c) 2줄 모두 valid 아님: $okC/2" }
} finally {
    Remove-Item -Recurse -Force $tempC -ErrorAction SilentlyContinue
}

# ---- (d) mix 5 valid + 1 corrupted → reader가 5 유지, 손상 1 감지 ----
Write-Host ""
Write-Host "  (d) 5 valid + 1 corrupted → reader skip 1, 유효 5:"
$tempD = Join-Path $env:TEMP "feedback-test-d-$(Get-Date -Format yyyyMMddHHmmssfff)"
New-Item -ItemType Directory -Path $tempD -Force | Out-Null
$fbD = Join-Path $tempD 'feedback.jsonl'
try {
    foreach ($i in 1..5) {
        $row = New-ValidFeedbackRow -Query "query $i"
        $line = ($row | ConvertTo-Json -Depth 4 -Compress)
        Add-Content -Path $fbD -Value $line -Encoding utf8
    }
    # 6번째 줄: 의도적 malformed (closing brace 누락)
    Add-Content -Path $fbD -Value '{"ts":"2026-05-24T00:00:00Z","query":"corrupted","sub_intent_id":"x",' -Encoding utf8

    # search SKILL.md Step 4.0.5 reader 로직 시뮬레이션:
    # - 각 줄 ConvertFrom-Json 시도, 실패하면 skip + 한 줄 로그 emit
    # - 마지막 N=20 줄만 유지 (본 테스트는 6줄이라 N filter 무영향)
    $allLines = Get-Content $fbD
    $tailN = [Math]::Min(20, @($allLines).Count)
    $tailLines = @($allLines)[(-1 * $tailN)..-1]
    $validCount = 0
    $skipLogs = @()
    $lineNumber = 0
    foreach ($l in $tailLines) {
        $lineNumber++
        $obj = $null
        try {
            $obj = $l | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $skipLogs += "[unity-assets:search] feedback row skipped: line $lineNumber"
            continue
        }
        $r = Test-FeedbackRow -Row $obj -Schema $schema
        if ($r.valid) {
            $validCount++
        } else {
            $skipLogs += "[unity-assets:search] feedback row skipped: line $lineNumber"
        }
    }
    Write-Host "      validCount = $validCount, skipLogs.Count = $($skipLogs.Count)"
    foreach ($sl in $skipLogs) { Write-Host "        $sl" }
    if ($validCount -ne 5) { $failures += "(d) 유효 줄 수 != 5: $validCount" }
    if ($skipLogs.Count -ne 1) { $failures += "(d) skip 로그 수 != 1: $($skipLogs.Count)" }
    if ($skipLogs.Count -ge 1 -and $skipLogs[0] -notmatch 'feedback row skipped: line 6$') {
        $failures += "(d) skip 로그가 line 6를 가리키지 않음: $($skipLogs[0])"
    }
} finally {
    Remove-Item -Recurse -Force $tempD -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "  PASS CRIT-EVAL3 feedback.jsonl: schema 검증 (valid/invalid) + 2줄 append + corruption skip 로그" -ForegroundColor Green
    exit 0
} else {
    Write-Host "  FAIL CRIT-EVAL3: $($failures.Count)건 실패" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "    - $f" -ForegroundColor Red }
    exit 1
}

#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-CNV1 Schema-doc sync — CONVENTION.md의 '## Asset Record — <tier>' 헤더 아래 첫 번째 fenced JSON 블록과
  schemas/asset-record.<tier>.json의 canonical (sorted-keys) 비교.

.NOTES
  순수 PowerShell 구현. Python 의존 제거 (사전 조건 표에서 transitive dep 제외).
  3 tier(minimal/normal/rich) 모두 canonical match일 때만 PASS.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

$pluginRoot = Split-Path $testsRoot -Parent
$convention = Join-Path $pluginRoot 'CONVENTION.md'
$schemasDir = Join-Path $pluginRoot 'schemas'

Assert-True -Condition (Test-Path $convention) -Message "CONVENTION.md 부재"

# UTF-8(BOM 무관) 명시 — Windows PS 5.1 ANSI 디폴트 회피
function Read-Utf8Text {
    param([Parameter(Mandatory)] [string] $Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

# 재귀 canonical JSON serializer — key 알파벳 정렬, separators=(',', ':'), non-ASCII 그대로.
function ConvertTo-CanonicalJson {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool])    { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string])  {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append('"')
        foreach ($ch in $Value.ToCharArray()) {
            switch ($ch) {
                '"'  { [void]$sb.Append('\"');  break }
                '\'  { [void]$sb.Append('\\');  break }
                "`b" { [void]$sb.Append('\b');  break }
                "`f" { [void]$sb.Append('\f');  break }
                "`n" { [void]$sb.Append('\n');  break }
                "`r" { [void]$sb.Append('\r');  break }
                "`t" { [void]$sb.Append('\t');  break }
                default {
                    $code = [int]$ch
                    if ($code -lt 0x20) {
                        [void]$sb.Append(('\u{0:x4}' -f $code))
                    } else {
                        [void]$sb.Append($ch)
                    }
                }
            }
        }
        [void]$sb.Append('"')
        return $sb.ToString()
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [byte] -or $Value -is [int16]) {
        return [string]$Value
    }
    if ($Value -is [double] -or $Value -is [float] -or $Value -is [decimal]) {
        # int로 표현 가능한 경우 int처럼 (json.dumps와 동일하게 1.0 → "1.0" 유지, 단 PS는 정수가 들어오므로 큰 영향 없음)
        $d = [double]$Value
        if ([Math]::Floor($d) -eq $d -and [Math]::Abs($d) -lt 1e15) {
            # JSON 호환 — 정수형 표기
            return [string]([long]$d)
        }
        return ([string]$Value)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = @()
        foreach ($k in ($Value.Keys | Sort-Object { [string]$_ })) {
            $kJson = ConvertTo-CanonicalJson ([string]$k)
            $vJson = ConvertTo-CanonicalJson $Value[$k]
            $parts += "$kJson`:$vJson"
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $parts = @()
        $names = $Value.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object
        foreach ($n in $names) {
            $kJson = ConvertTo-CanonicalJson ([string]$n)
            $vJson = ConvertTo-CanonicalJson $Value.$n
            $parts += "$kJson`:$vJson"
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = @()
        foreach ($item in $Value) { $parts += (ConvertTo-CanonicalJson $item) }
        return '[' + ($parts -join ',') + ']'
    }
    # fallback
    return (ConvertTo-CanonicalJson ([string]$Value))
}

$md = Read-Utf8Text -Path $convention
$failures = 0

foreach ($tier in @('minimal','normal','rich')) {
    $pattern = "(?s)## Asset Record — $tier\s*\n\s*``````json\s*\n(.*?)\n``````"
    $m = [regex]::Match($md, $pattern)
    if (-not $m.Success) {
        Write-Host "  FAIL $tier`: fenced JSON 블록 부재 — 헤더 '## Asset Record — $tier' 아래 ``````json ... `````` 가 필요." -ForegroundColor Red
        $failures++
        continue
    }
    try {
        $mdObj = $m.Groups[1].Value | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Host "  FAIL $tier`: CONVENTION.md fenced JSON parse 실패: $_" -ForegroundColor Red
        $failures++
        continue
    }
    $filePath = Join-Path $schemasDir "asset-record.$tier.json"
    if (-not (Test-Path $filePath)) {
        Write-Host "  FAIL $tier`: schemas/asset-record.$tier.json 부재" -ForegroundColor Red
        $failures++
        continue
    }
    try {
        $fileObj = (Read-Utf8Text -Path $filePath) | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Host "  FAIL $tier`: schemas/asset-record.$tier.json parse 실패: $_" -ForegroundColor Red
        $failures++
        continue
    }

    $canonMd   = ConvertTo-CanonicalJson $mdObj
    $canonFile = ConvertTo-CanonicalJson $fileObj
    if ($canonMd -ceq $canonFile) {
        Write-Host "  OK $tier`: canonical match"
        continue
    }
    Write-Host "  FAIL $tier`: canonical diff (CONVENTION.md fenced JSON != schemas/asset-record.$tier.json)" -ForegroundColor Red
    $min = [Math]::Min($canonMd.Length, $canonFile.Length)
    for ($i = 0; $i -lt $min; $i++) {
        if ($canonMd[$i] -cne $canonFile[$i]) {
            $lo = [Math]::Max(0, $i - 30)
            $hi = [Math]::Min($min, $i + 60)
            Write-Host ("    md : ...{0}" -f $canonMd.Substring($lo, $hi - $lo))
            Write-Host ("    fl : ...{0}" -f $canonFile.Substring($lo, $hi - $lo))
            break
        }
    }
    if ($canonMd.Length -ne $canonFile.Length) {
        Write-Host ("    length md={0} fl={1}" -f $canonMd.Length, $canonFile.Length)
    }
    $failures++
}

if ($failures -ne 0) {
    Write-Host "  FAIL CRIT-CNV1: $failures tier(s) mismatch" -ForegroundColor Red
    exit 1
}
Write-Host "  PASS CRIT-CNV1 Schema-doc sync: 3 tier (minimal/normal/rich) 모두 canonical match"
exit 0

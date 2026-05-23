#!/usr/bin/env pwsh
<#
.SYNOPSIS
  A/B harness — 두 variant aliases.yml(또는 동등 파일)을 동일 골든셋에 적용하고
  recall_at_3 / precision_at_3의 delta(B - A)를 산출한다.

.PARAMETER VariantA
  변형 A의 aliases.yml 경로 (또는 fake-search-runner가 읽는 yml 변형).

.PARAMETER VariantB
  변형 B의 aliases.yml 경로.

.PARAMETER GoldenSet
  골든 쿼리 yml. 기본값: tests/golden-queries.yml.

.PARAMETER AssetsTemplate
  골든 fixture 템플릿 yml. 기본값: tests/fixtures/_templates/assets.yml.

.PARAMETER Seed
  결정성 시드. 동일 seed로 두 번 실행 시 byte-identical 결과를 보장.

.PARAMETER Out
  결과 경로. 기본값: tests/_ab-result.json. atomic rename(.tmp → 최종)으로 작성.

.NOTES
  결과는 schemas/_ab-result.json.schema.json (tests/_ab-result.json.schema.json) 통과해야 한다.
  CRIT-EVAL4가 본 harness의 결정성·재현성을 단언한다.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $VariantA,
    [Parameter(Mandatory)] [string] $VariantB,
    [string] $GoldenSet,
    [string] $AssetsTemplate,
    [int]    $Seed = 42,
    [string] $Out
)

$ErrorActionPreference = 'Stop'
$harnessRoot = $PSScriptRoot
$testsRoot   = Split-Path $harnessRoot -Parent
$repoRoot    = Split-Path $testsRoot   -Parent

if (-not $GoldenSet)      { $GoldenSet      = Join-Path $testsRoot 'golden-queries.yml' }
if (-not $AssetsTemplate) { $AssetsTemplate = Join-Path $testsRoot 'fixtures/_templates/assets.yml' }
if (-not $Out)            { $Out            = Join-Path $testsRoot '_ab-result.json' }

if (-not (Test-Path $VariantA)) { throw "VariantA 경로 부재: $VariantA" }
if (-not (Test-Path $VariantB)) { throw "VariantB 경로 부재: $VariantB" }

$runner = Join-Path $harnessRoot 'fake-search-runner.ps1'
if (-not (Test-Path $runner)) { throw "fake-search-runner.ps1 부재: $runner" }

function Invoke-Runner {
    param([string] $AliasesYml)
    $jsonText = & $runner -GoldenSet $GoldenSet -AssetsTemplate $AssetsTemplate -AliasesYml $AliasesYml -Seed $Seed
    $jsonStr = ($jsonText -join "`n")
    return $jsonStr | ConvertFrom-Json
}

Write-Host "  variant_a: $VariantA"
$resA = Invoke-Runner -AliasesYml $VariantA

Write-Host "  variant_b: $VariantB"
$resB = Invoke-Runner -AliasesYml $VariantB

# ---- delta 계산 (B - A) ----
function To-Hashtable {
    param($obj)
    $h = @{}
    foreach ($p in $obj.PSObject.Properties) {
        $h[$p.Name] = $p.Value
    }
    return $h
}

$catKeys = @('character','environment','audio','ui','scriptable_object')
$recallByCatA = To-Hashtable $resA.recall_at_3.by_category
$recallByCatB = To-Hashtable $resB.recall_at_3.by_category
$precByCatA   = To-Hashtable $resA.precision_at_3.by_category
$precByCatB   = To-Hashtable $resB.precision_at_3.by_category

$deltaRecallByCat = [ordered]@{}
$deltaPrecByCat   = [ordered]@{}
foreach ($c in $catKeys) {
    $deltaRecallByCat[$c] = [math]::Round([double]$recallByCatB[$c] - [double]$recallByCatA[$c], 6)
    $deltaPrecByCat[$c]   = [math]::Round([double]$precByCatB[$c]   - [double]$precByCatA[$c],   6)
}

$result = [ordered]@{
    seed = $Seed
    variant_a = [ordered]@{
        label          = $VariantA
        recall_at_3    = [ordered]@{
            overall     = [double]$resA.recall_at_3.overall
            by_category = $recallByCatA
        }
        precision_at_3 = [ordered]@{
            overall     = [double]$resA.precision_at_3.overall
            by_category = $precByCatA
        }
        n_queries      = [int]$resA.n_queries
    }
    variant_b = [ordered]@{
        label          = $VariantB
        recall_at_3    = [ordered]@{
            overall     = [double]$resB.recall_at_3.overall
            by_category = $recallByCatB
        }
        precision_at_3 = [ordered]@{
            overall     = [double]$resB.precision_at_3.overall
            by_category = $precByCatB
        }
        n_queries      = [int]$resB.n_queries
    }
    delta = [ordered]@{
        recall_at_3 = [ordered]@{
            overall     = [math]::Round([double]$resB.recall_at_3.overall - [double]$resA.recall_at_3.overall, 6)
            by_category = $deltaRecallByCat
        }
        precision_at_3 = [ordered]@{
            overall     = [math]::Round([double]$resB.precision_at_3.overall - [double]$resA.precision_at_3.overall, 6)
            by_category = $deltaPrecByCat
        }
    }
}

$json = $result | ConvertTo-Json -Depth 8
$tmp = "$Out.tmp"
Set-Content -Path $tmp -Value $json -Encoding utf8
Move-Item -Path $tmp -Destination $Out -Force

Write-Host ""
Write-Host "  A/B harness 완료: $Out"
Write-Host ("    variant_a recall@3 = {0:N4}, precision@3 = {1:N4}" -f $resA.recall_at_3.overall, $resA.precision_at_3.overall)
Write-Host ("    variant_b recall@3 = {0:N4}, precision@3 = {1:N4}" -f $resB.recall_at_3.overall, $resB.precision_at_3.overall)
Write-Host ("    delta     recall@3 = {0:N4}, precision@3 = {1:N4}" -f $result.delta.recall_at_3.overall, $result.delta.precision_at_3.overall)

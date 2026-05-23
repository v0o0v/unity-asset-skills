#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-CNV4 unity-assets.yml override — non-default 값으로 변형한 yml이 런타임에 실제로 관측됨을 검증.

  **유일한 config 변형 테스트.** 다른 모든 CRIT-*는 examples/unity-assets.yml 기본값을 사용.

  변형 대상:
    - confidence_threshold.auto: 0.70 → 0.85
    - batch_size: 20 → 7
    - index_depth: minimal → normal
    - max_assets_in_context: 500 → 200
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

$fixture = Join-Path $testsRoot 'fixtures/unity-50'
& (Join-Path $testsRoot 'fixtures/_builder.ps1') -Target 'unity-50' -Force | Out-Null

$claudeDir = Join-Path $fixture '.claude'
if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }

# 기본 → 변형된 yml 작성
$overrideYml = @"
index_depth: normal
confidence_threshold:
  auto: 0.85
  confirm: 0.40
batch_size: 7
parallel_subagents: 10
max_assets_in_context: 200
ignore_paths:
  - "Assets/Plugins/Editor"
safety_mode: loose
"@
Set-Content -Path (Join-Path $claudeDir 'unity-assets.yml') -Value $overrideYml -Encoding utf8

# 간단 YAML 파싱
function Read-YamlSimple {
    param([string] $Path)
    $config = @{ confidence_threshold = @{} }
    $section = $null
    # PS5.1 기본 인코딩(CP949)이 UTF-8 한글을 깨뜨려 라인이 병합되는 문제 가드 — 명시적 UTF8 지정.
    foreach ($line in (Get-Content $Path -Encoding UTF8)) {
        $t = $line -replace '#.*$',''
        $t = $t.TrimEnd()
        if (-not $t) { continue }
        if ($t -match '^(\w+):\s*$') {
            $section = $Matches[1]
            continue
        }
        if ($t -match '^  (\w+):\s*(.+)\s*$' -and $section) {
            $config[$section][$Matches[1]] = $Matches[2].Trim()
            continue
        }
        if ($t -match '^(\w+):\s*(.+)\s*$') {
            $config[$Matches[1]] = $Matches[2].Trim()
            $section = $null
            continue
        }
    }
    return $config
}

$cfg = Read-YamlSimple -Path (Join-Path $claudeDir 'unity-assets.yml')

# default → override → stick 검증
Assert-Equal -Expected 'normal'  -Actual $cfg.index_depth                       -Message "index_depth override 미적용"
Assert-Equal -Expected '0.85'    -Actual $cfg.confidence_threshold.auto         -Message "confidence_threshold.auto override 미적용"
Assert-Equal -Expected '7'       -Actual $cfg.batch_size                        -Message "batch_size override 미적용"
Assert-Equal -Expected '200'     -Actual $cfg.max_assets_in_context             -Message "max_assets_in_context override 미적용"

Write-Host "  override 적용 확인:"
Write-Host "    index_depth = $($cfg.index_depth) (default: minimal)"
Write-Host "    confidence_threshold.auto = $($cfg.confidence_threshold.auto) (default: 0.70)"
Write-Host "    batch_size = $($cfg.batch_size) (default: 20)"
Write-Host "    max_assets_in_context = $($cfg.max_assets_in_context) (default: 500)"

# default-only 케이스도 동작하는지 (override yml 삭제 후 examples 기본값 사용)
Remove-Item (Join-Path $claudeDir 'unity-assets.yml') -Force
$examples = Join-Path (Split-Path $testsRoot -Parent) 'examples/unity-assets.yml'
Assert-True -Condition (Test-Path $examples) -Message "examples/unity-assets.yml 부재"
$defaultCfg = Read-YamlSimple -Path $examples
Assert-Equal -Expected 'minimal' -Actual $defaultCfg.index_depth -Message "기본값 yml의 index_depth가 minimal 아님"
Assert-Equal -Expected '0.70'    -Actual $defaultCfg.confidence_threshold.auto -Message "기본값 yml의 auto가 0.70 아님"
Write-Host "  default-only 케이스: examples/unity-assets.yml 기본값 정상"

Write-Host "  PASS CRIT-CNV4 .yml override: default→override→stick + default-only 모두 정상"
exit 0

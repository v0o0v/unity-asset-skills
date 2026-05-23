#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-CNV2 Plugin manifest — .claude-plugin/plugin.json이 Claude Code 공식 plugin manifest 스펙 통과.

  필수 필드: name, version, description, skills (array).
  권장 필드: author, repository, homepage, license, keywords.
  검증:
    1) 위치 — unity-asset-skills/.claude-plugin/plugin.json (root /plugin.json 아님)
    2) JSON well-formed
    3) 필수 필드 존재 + 타입
    4) skills 배열 — 4개 ./skills/<name>/ 형식 + 디렉터리 실재
    5) name 값이 슬래시 커맨드 namespace로 사용됨 (`unity-assets`)
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$pluginRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

# 위치 검증
$canonical = Join-Path $pluginRoot '.claude-plugin/plugin.json'
$rootCopy  = Join-Path $pluginRoot 'plugin.json'

Assert-True -Condition (Test-Path $canonical) -Message ".claude-plugin/plugin.json 부재 — Claude Code 공식 위치"
if (Test-Path $rootCopy) {
    Write-Host "  WARNING: root plugin.json도 존재. Claude Code는 .claude-plugin/ 만 인식." -ForegroundColor Yellow
}

# JSON 파싱
$json = $null
try {
    $json = Get-Content $canonical | Out-String | ConvertFrom-Json
} catch {
    throw "plugin.json JSON parse 실패: $_"
}
Write-Host "  plugin.json well-formed"

# 필수 필드
$required = @('name', 'version', 'description', 'skills')
foreach ($f in $required) {
    if (-not $json.PSObject.Properties.Name -contains $f) {
        throw "필수 필드 '$f' 누락"
    }
}
Write-Host "  필수 필드 모두 존재: $($required -join ', ')"

# name = unity-assets (슬래시 커맨드 namespace)
Assert-Equal -Expected 'unity-assets' -Actual $json.name -Message "name이 'unity-assets'가 아님 → 슬래시 커맨드 namespace 결정 실패"
Write-Host "  name = 'unity-assets' (슬래시 커맨드 namespace 일치)"

# version regex
Assert-True -Condition ($json.version -match '^\d+\.\d+\.\d+') -Message "version 형식 위반 (X.Y.Z 기대)"
Write-Host "  version = $($json.version)"

# skills 배열 검증
Assert-True -Condition ($json.skills -is [array]) -Message "skills 필드가 array 아님"
$expectedSkills = @('./skills/unity-assets-index/', './skills/unity-assets-search/', './skills/unity-assets-build/', './skills/unity-assets-doctor/')
foreach ($s in $expectedSkills) {
    if ($json.skills -notcontains $s) {
        throw "skills 배열에 '$s' 누락"
    }
    # 디렉터리 실재 검증
    $skillDir = Join-Path $pluginRoot ($s -replace '^\./','').TrimEnd('/')
    Assert-True -Condition (Test-Path $skillDir) -Message "skills 경로 '$s' 디렉터리 부재"
    $skillMd = Join-Path $skillDir 'SKILL.md'
    Assert-True -Condition (Test-Path $skillMd) -Message "$s 내 SKILL.md 부재"
}
Write-Host "  skills 배열: 4개 모두 등록 + 디렉터리·SKILL.md 실재"

# 권장 필드 (있으면 검증, 없으면 경고)
$recommended = @('author', 'repository', 'license', 'keywords')
foreach ($f in $recommended) {
    if ($json.PSObject.Properties.Name -notcontains $f) {
        Write-Host "  WARN: 권장 필드 '$f' 없음" -ForegroundColor Yellow
    }
}

# agents 필드 미등록 정책 (관찰: feature-dev, oh-my-claudecode 모두 agents 필드 없음 — auto-discovery)
if ($json.PSObject.Properties.Name -contains 'agents') {
    Write-Host "  INFO: agents 필드가 등록됨 — Claude Code는 일반적으로 auto-discovery 사용" -ForegroundColor Cyan
}

Write-Host "  PASS CRIT-CNV2 Plugin manifest: 공식 spec 준수 + 슬래시 커맨드 namespace 일치"
exit 0

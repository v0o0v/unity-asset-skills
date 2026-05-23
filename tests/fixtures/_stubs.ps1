#!/usr/bin/env pwsh
<#
.SYNOPSIS
  unity-mcp 및 asset-tagger subagent stub 헬퍼. 모든 CRIT 테스트가 dot-source로 가져온다.

.NOTES
  실제 Unity Editor 없이 dry-run 모드로 동작. orchestrator-audit.jsonl에는 stub 호출이 그대로 기록되어
  CRIT-ORC3 (scope guard) 검증이 가능하다.
#>

# ---- stub mode 설정 (환경 변수 + 글로벌) ----
function Set-StubMode {
    param(
        [ValidateSet('off','dry-run','recording')] [string] $Mode = 'dry-run',
        [string] $RecordingPath = $null
    )
    $env:UNITY_ASSET_SKILLS_STUB_MODE = $Mode
    if ($RecordingPath) {
        $env:UNITY_ASSET_SKILLS_STUB_RECORDING = $RecordingPath
    }
}

# ---- unity-mcp 호출 stub: 모든 mcp__* 호출을 audit 로그에만 기록 ----
function Invoke-StubMcpCall {
    param(
        [Parameter(Mandatory)] [string] $Tool,
        [string] $Action = '',
        [hashtable] $Args = @{},
        [string] $SubIntent = '',
        [string] $AuditPath = $null
    )

    if (-not $AuditPath) {
        $AuditPath = "$pwd\.claude\unity-asset-index\orchestrator-audit.jsonl"
    }
    $auditDir = Split-Path $AuditPath -Parent
    if (-not (Test-Path $auditDir)) { New-Item -ItemType Directory -Path $auditDir -Force | Out-Null }

    $argsJson  = $Args | ConvertTo-Json -Compress
    $digest    = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new(
                  [System.Text.Encoding]::UTF8.GetBytes($argsJson))) -Algorithm SHA256).Hash.ToLower()
    $record = [ordered]@{
        ts          = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        sub_intent  = $SubIntent
        tool        = $Tool
        action      = $Action
        args_digest = "sha256:$digest"
    } | ConvertTo-Json -Compress
    Add-Content -Path $AuditPath -Value $record -Encoding utf8

    # stub 응답 — 호출자가 적당히 처리하도록 success 리턴
    return @{ ok = $true; tool = $Tool; action = $Action }
}

# ---- asset-tagger stub: 입력 ASSETS 항목에 대해 minimal Asset Record JSONL row 생성 ----
function Invoke-StubAssetTagger {
    param(
        [Parameter(Mandatory)] [string[]] $AssetPaths,
        [Parameter(Mandatory)] [string]   $ProjectRoot
    )

    $rows = @()
    foreach ($abs in $AssetPaths) {
        $metaPath = "$abs.meta"
        if (-not (Test-Path $metaPath)) { continue }
        $metaLines = Get-Content $metaPath
        $guid = ($metaLines | Where-Object { $_ -match '^guid:' } | Select-Object -First 1) -replace '^guid:\s*',''
        $labelsLine = ($metaLines | Where-Object { $_ -match '^labels:' } | Select-Object -First 1)
        $labels = @()
        if ($labelsLine -match 'labels:\s*\[(.*)\]') {
            $inner = $Matches[1]
            if ($inner.Trim()) {
                $labels = $inner -split ',' | ForEach-Object { $_.Trim() }
            }
        }
        $rel = $abs.Substring($ProjectRoot.Length).TrimStart('\','/') -replace '\\','/'
        $name = [IO.Path]::GetFileNameWithoutExtension($abs)
        $ext  = [IO.Path]::GetExtension($abs).ToLower()
        $type = switch ($ext) {
            '.prefab'     { 'Prefab' }
            '.mat'        { 'Material' }
            '.png'        { 'Texture' }
            '.jpg'        { 'Texture' }
            '.tga'        { 'Texture' }
            '.controller' { 'AnimatorController' }
            '.cs'         { 'MonoScript' }
            '.unity'      { 'Scene' }
            '.asset'      { 'ScriptableObject' }
            '.fbx'        { 'Mesh' }
            '.wav'        { 'AudioClip' }
            default       { 'Unknown' }
        }
        # stub: tags = path-segment 파생 + 'stub'
        $segments = $rel -split '/' | Where-Object { $_ -and $_ -ne 'Assets' }
        $tags = @($segments[0..([Math]::Min(3, $segments.Count - 1))] | ForEach-Object { ($_ -replace '[^a-zA-Z0-9]','-').ToLower() })
        if ($tags.Count -eq 0) { $tags = @('stub') }
        $row = [ordered]@{
            guid        = $guid
            path        = $rel
            name        = $name
            type        = $type
            labels      = @($labels)
            llm_tags    = $tags
            llm_summary = "stub 요약 ($type, $name)."
        } | ConvertTo-Json -Compress
        $rows += $row
    }
    return $rows
}

# ---- search-result.json fixture 생성 헬퍼 ----
function New-StubSearchResult {
    param(
        [Parameter(Mandatory)] [string] $ManifestVersion,
        [Parameter(Mandatory)] [object[]] $Groups,   # [{sub_intent, candidates: [{guid, path, confidence, reasoning}, ...]}]
        [Parameter(Mandatory)] [string] $OutPath
    )
    $obj = [ordered]@{
        manifest_version = $ManifestVersion
        groups           = $Groups
    }
    $json = $obj | ConvertTo-Json -Depth 10
    $tmp = "$OutPath.tmp"
    Set-Content -Path $tmp -Value $json -Encoding utf8
    Move-Item -Path $tmp -Destination $OutPath -Force
}

# ---- manifest.json stub ----
function New-StubManifest {
    param(
        [Parameter(Mandatory)] [string] $Version,
        [Parameter(Mandatory)] [string] $OutPath
    )
    $obj = [ordered]@{
        version     = $Version
        last_run    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        schema_tier = 'minimal'
    }
    $json = $obj | ConvertTo-Json
    $tmp = "$OutPath.tmp"
    Set-Content -Path $tmp -Value $json -Encoding utf8
    Move-Item -Path $tmp -Destination $OutPath -Force
}

# ---- common assertion ----
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) {
        Write-Host "ASSERTION FAILED: $Message" -ForegroundColor Red
        throw $Message
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ($Expected -ne $Actual) {
        Write-Host "ASSERTION FAILED: $Message — expected '$Expected', got '$Actual'" -ForegroundColor Red
        throw $Message
    }
}

# Export-ModuleMember는 모듈 컨텍스트(.psm1 또는 Import-Module)에서만 호출 가능.
# `. ./_stubs.ps1`로 dot-source되는 경우 PS는 PermissionDenied 예외를 던지므로 가드 필수.
if ($MyInvocation.MyCommand.ScriptBlock.Module) {
    Export-ModuleMember -Function *
}

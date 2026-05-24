#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Unity fixture builder — _templates/assets.yml을 읽어 unity-50/200/1200 fixture를 deterministic하게 생성.

.PARAMETER Target
  생성할 fixture 디렉터리 이름. unity-50 / unity-200 / unity-1200.

.PARAMETER Size
  생성할 에셋 수. 미지정 시 Target에서 추론 (unity-50→50, unity-200→200, unity-1200→1200).

.PARAMETER Synthetic
  unity-1200 전용. 합성 prefab/material/texture만 생성 (recall 측정 안 함).

.PARAMETER Force
  기존 fixture 삭제 후 재생성.

.EXAMPLE
  .\_builder.ps1 -Target unity-50
  .\_builder.ps1 -Target unity-200 -Force
  .\_builder.ps1 -Target unity-1200 -Synthetic
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Target,
    [int] $Size = 0,
    [switch] $Synthetic,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

# ---- 입력 추론 ----
if ($Size -eq 0) {
    $Size = switch ($Target) {
        'unity-50'   { 50 }
        'unity-200'  { 200 }
        'unity-1200' { 1200 }
        default { throw "Size 미지정 + Target 알 수 없음: $Target" }
    }
}

if ($Target -eq 'unity-1200' -and -not $Synthetic) {
    $Synthetic = $true  # unity-1200은 항상 synthetic
}

$fixturesRoot = $PSScriptRoot
$targetRoot   = Join-Path $fixturesRoot $Target
$assetsRoot   = Join-Path $targetRoot 'Assets'
$templatesYml = Join-Path $fixturesRoot '_templates/assets.yml'

if ($Force -and (Test-Path $targetRoot)) {
    Remove-Item $targetRoot -Recurse -Force
}

if (-not (Test-Path $assetsRoot)) {
    New-Item -ItemType Directory -Path $assetsRoot -Force | Out-Null
}

# ---- deterministic GUID 생성 (입력 문자열에서 16-byte hex) ----
function New-DeterministicGuid {
    param([string] $Seed)
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($Seed)
    $hash   = $hasher.ComputeHash($bytes)
    $hasher.Dispose()
    return -join ($hash[0..15] | ForEach-Object { $_.ToString('x2') })
}

# ---- template 로드 (간단 YAML 파서: 본 fixture는 한 줄당 한 entry 가정) ----
function Read-Templates {
    param([string] $Path)
    $entries = @()
    foreach ($line in Get-Content $Path) {
        $t = $line.Trim()
        if (-not $t.StartsWith('- {')) { continue }
        # parse key:value pairs inside { ... }
        $inner = $t.Substring(3, $t.Length - 4).Trim()  # strip '- {' and '}'
        $entry = @{}
        $bracket = 0
        $buf = ''
        $pairs = @()
        foreach ($c in $inner.ToCharArray()) {
            if ($c -eq '[') { $bracket++ }
            if ($c -eq ']') { $bracket-- }
            if ($c -eq ',' -and $bracket -eq 0) {
                $pairs += $buf.Trim()
                $buf = ''
            } else {
                $buf += $c
            }
        }
        if ($buf.Trim()) { $pairs += $buf.Trim() }
        foreach ($p in $pairs) {
            $colon = $p.IndexOf(':')
            if ($colon -lt 0) { continue }
            $k = $p.Substring(0, $colon).Trim()
            $v = $p.Substring($colon + 1).Trim()
            if ($v.StartsWith('[') -and $v.EndsWith(']')) {
                $items = $v.Substring(1, $v.Length - 2) -split ',' | ForEach-Object { $_.Trim() }
                $entry[$k] = @($items | Where-Object { $_ -ne '' })
            } elseif ($v.StartsWith('"') -and $v.EndsWith('"')) {
                $entry[$k] = $v.Substring(1, $v.Length - 2)
            } else {
                $entry[$k] = $v
            }
        }
        if ($entry.Count -gt 0) { $entries += ,$entry }
    }
    return $entries
}

$templates = Read-Templates -Path $templatesYml
Write-Host "[builder] templates loaded: $($templates.Count) entries"

# ---- decoy invariant 검증 (CRIT-SCH1 hand-curated rule) ----
function Test-DecoyInvariant {
    param($Templates)
    $goldens = $Templates | Where-Object { $_.ContainsKey('golden_id') -and $_.golden_id }
    foreach ($g in $goldens) {
        $gtags = @($g.tags_hint)
        $hasOverlap = $false
        foreach ($d in $Templates) {
            if ($d.name -eq $g.name) { continue }
            if (-not $d.tags_hint) { continue }
            $overlap = $gtags | Where-Object { $d.tags_hint -contains $_ }
            if ($overlap.Count -gt 0) {
                $hasOverlap = $true
                break
            }
        }
        if (-not $hasOverlap) {
            throw "[builder] decoy invariant 위반: golden '$($g.name)' (golden_id=$($g.golden_id))의 tags_hint와 겹치는 decoy 없음. _templates/assets.yml 수정 필요."
        }
    }
    Write-Host "[builder] decoy invariant PASS for $($goldens.Count) golden entries"
}

if (-not $Synthetic) {
    Test-DecoyInvariant -Templates $templates
}

# ---- 에셋 stub + .meta 작성 헬퍼 ----
function Write-AssetStub {
    param([hashtable] $Entry, [string] $RootDir, [int] $Index = 0)

    $name = $Entry.name
    if ($Index -gt 0) { $name = "${name}_$($Index.ToString('D4'))" }

    $dir = Join-Path $RootDir $Entry.dir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $assetPath = Join-Path $dir "$name$($Entry.ext)"
    $metaPath  = "$assetPath.meta"
    $guid      = New-DeterministicGuid -Seed "$($Entry.dir)/$name$($Entry.ext)"

    # 에셋 stub
    $binaryExts = @('.png','.jpg','.tga','.psd','.fbx','.wav','.mp3','.ogg','.blend')
    if ($binaryExts -contains $Entry.ext.ToLower()) {
        # 0바이트 빈 파일
        [System.IO.File]::WriteAllBytes($assetPath, @())
    } elseif ($Entry.ext -eq '.cs') {
        Set-Content -Path $assetPath -Value "// stub: $($Entry.kind) — $($Entry.summary_hint)" -Encoding utf8
    } else {
        # YAML 더미
        Set-Content -Path $assetPath -Value "%YAML 1.1`n%TAG !u! tag:unity3d.com,2011:`n--- !u!1 &1`n# stub: $($Entry.kind) — $($Entry.summary_hint)" -Encoding utf8
    }

    # .meta
    $labelsLine = ''
    if ($Entry.labels -and $Entry.labels.Count -gt 0) {
        $labelsLine = "labels: [$($Entry.labels -join ', ')]"
    } else {
        $labelsLine = 'labels: []'
    }
    $importer = switch ($Entry.kind) {
        'Prefab'              { 'PrefabImporter' }
        'Material'            { 'NativeFormatImporter' }
        'Texture'             { 'TextureImporter' }
        'AnimatorController'  { 'NativeFormatImporter' }
        'ScriptableObject'    { 'NativeFormatImporter' }
        'MonoScript'          { 'MonoImporter' }
        'Scene'               { 'DefaultImporter' }
        default               { 'NativeFormatImporter' }
    }
    $metaContent = @"
fileFormatVersion: 2
guid: $guid
$labelsLine
${importer}:
  externalObjects: {}
  userData:
  assetBundleName:
  assetBundleVariant:
"@
    Set-Content -Path $metaPath -Value $metaContent -Encoding utf8

    return @{ guid = $guid; path = $assetPath; meta = $metaPath }
}

# ---- 생성 루프 ----
if ($Synthetic) {
    # 자동 생성: 단일 패키지 안에 SynthAsset_NNNN.prefab/mat/png 사이클
    $kinds = @(
        @{ kind='Prefab';   ext='.prefab'; tags_hint=@('synth','prefab','test'); summary_hint='Synthetic prefab stub.' },
        @{ kind='Material'; ext='.mat';    tags_hint=@('synth','material','test'); summary_hint='Synthetic material stub.' },
        @{ kind='Texture';  ext='.png';    tags_hint=@('synth','texture','test'); summary_hint='Synthetic texture stub.' }
    )
    for ($i = 1; $i -le $Size; $i++) {
        $k = $kinds[($i - 1) % $kinds.Count]
        $entry = @{
            kind         = $k.kind
            name         = 'SynthAsset'
            dir          = 'Assets/Synth'
            ext          = $k.ext
            labels       = @()
            tags_hint    = $k.tags_hint
            summary_hint = $k.summary_hint
        }
        Write-AssetStub -Entry $entry -RootDir $targetRoot -Index $i | Out-Null
        if ($i % 100 -eq 0) { Write-Host "  ... $i / $Size" }
    }
} else {
    # hand-curated: templates 순회 + 부족하면 사이클 (인덱스 suffix로 unique)
    $created = 0
    $tCount = $templates.Count
    for ($i = 0; $i -lt $Size; $i++) {
        $tpl = $templates[$i % $tCount]
        $cycle = [Math]::Floor($i / $tCount)
        $idx = if ($cycle -eq 0) { 0 } else { $cycle }  # 0=원본 이름, 1+ 사이클은 suffix
        Write-AssetStub -Entry $tpl -RootDir $targetRoot -Index $idx | Out-Null
        $created++
    }
    Write-Host "[builder] hand-curated assets written: $created"
}

# ---- .claude/ 부트스트랩 ----
$claudeDir = Join-Path $targetRoot '.claude'
if (-not (Test-Path $claudeDir)) {
    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
}
# CRIT-CNV4 외 모든 테스트가 examples/unity-assets.yml 기본값 사용
$examplesYml = Join-Path $fixturesRoot '..\..\examples\unity-assets.yml'
$targetYml   = Join-Path $claudeDir 'unity-assets.yml'
if ((Test-Path $examplesYml) -and -not (Test-Path $targetYml)) {
    Copy-Item $examplesYml $targetYml
}

Write-Host "[builder] $Target ready at $targetRoot ($Size assets)"
exit 0

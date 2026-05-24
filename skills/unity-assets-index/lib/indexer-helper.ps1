# skills/unity-assets-index/lib/indexer-helper.ps1
# V0.1.0+4 — deterministic helper for indexer LLM.
#
# 본 스크립트는 SKILL.md(index)가 명시 호출하는 deterministic helper다. LLM 자가 우회가 아니라
# 인덱서 절차의 일부로 CONVENTION.md §2.6 예외에 해당한다. batch 분할·wall-clock·wave_timings·
# partial append·finalize 등 LLM이 자가 추정으로 fictitious 값을 만들거나 PowerShell command line
# limit(ENAMETOOLONG)에 막히는 영역을 PowerShell deterministic 호출로 대체하여 사용자 reindex
# 시간을 단축한다.
#
# Commands:
#   -Cmd GetMetaList -Project <path> [-IgnorePaths <list>]
#     → JSONL stdout: {abs, rel, mtime, size}
#   -Cmd PlanBatches -Project <path> -MetaList <path> -BatchSize 20
#     → _batches/batch-NNN.txt 생성, stdout에 batch 목록 JSON
#   -Cmd NowIso
#     → "yyyy-MM-ddTHH:mm:ss.fffZ" UTC stdout
#   -Cmd InitWaveTiming -Project <path> -Wave N -TotalWaves T -Subagents K
#     → state.json::wave_timings에 entry append (start = NowIso, end=null)
#   -Cmd AppendPartial -Project <path> -BatchId <id> -InputFile <jsonl path>          [V0.1.0+4]
#     → JSONL row 7-field 검증 + assets.jsonl.partial concurrent-safe append.
#       stdout JSON: {batch_id, ok_rows, bad_rows, bad_details: [{guid?, reason}]}
#       transcription overhead 회피 (LLM은 subagent stdout을 InputFile로 dump 후 본 명령 1회 호출).
#   -Cmd CompleteWaveTiming -Project <path> -Wave N -OkRows X -BadRows Y [-TimeoutBatches list]
#     → wave_timings 마지막 entry 갱신 (end = NowIso, elapsed_sec 계산)
#   -Cmd CleanupBatches -Project <path>
#     → _batches/ 폐기 (responses/ 하위 포함)
#   -Cmd Finalize -Project <path>
#     → assets.jsonl.partial sort + atomic rename + packages.jsonl 파생 + state.json
#       (V0.1.0+4: .meta 파일 stat을 guid_signatures 진실원으로 사용 — minimal-tier row의 size 필드
#       부재로 인한 size=0 bug 해결) + manifest.json 갱신.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('GetMetaList','PlanBatches','NowIso','InitWaveTiming','AppendPartial','CompleteWaveTiming','CleanupBatches','Finalize')]
    [string]$Cmd,
    [string]$Project,
    [string]$MetaList,
    [string]$BatchId,
    [string]$InputFile,
    [int]$BatchSize = 20,
    [int]$Wave,
    [int]$TotalWaves,
    [int]$Subagents,
    [int]$OkRows = 0,
    [int]$BadRows = 0,
    [string[]]$TimeoutBatches = @(),
    [string[]]$IgnorePaths = @('Assets/Plugins/Editor')
)

$ErrorActionPreference = 'Stop'

function Get-IdxDir($proj) { Join-Path $proj '.claude\unity-asset-index' }
function Get-BatchDir($proj) { Join-Path (Get-IdxDir $proj) '_batches' }
function Get-StateJson($proj) { Join-Path (Get-IdxDir $proj) 'state.json' }
function Get-NowIso() { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }

function Write-AtomicJson($path, $obj) {
    $tmp = "$path.tmp"
    $obj | ConvertTo-Json -Depth 20 -Compress | Set-Content -Path $tmp -Encoding utf8
    Move-Item -Force $tmp $path
}

function Set-StateProperty([object]$obj, [string]$name, $value) {
    # PSCustomObject (ConvertFrom-Json 결과)에 property 신규 추가 시 직접 set이 실패하는 PS5.1
    # 동작 회피. 존재하면 갱신, 없으면 Add-Member.
    if ($obj.PSObject.Properties.Name -contains $name) {
        $obj.$name = $value
    } else {
        $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
    }
}

function Cmd-GetMetaList {
    if (-not $Project) { throw '-Project required' }
    $assetsDir = Join-Path $Project 'Assets'
    if (-not (Test-Path $assetsDir)) { throw "Assets/ not found under $Project" }
    $metas = Get-ChildItem -Path $assetsDir -Recurse -File -Filter '*.meta'
    foreach ($m in $metas) {
        $rel = $m.FullName.Substring($Project.Length + 1) -replace '\\','/'
        $skip = $false
        foreach ($ig in $IgnorePaths) {
            if ($rel.StartsWith($ig)) { $skip = $true; break }
        }
        if ($skip) { continue }
        $obj = [ordered]@{
            abs = $m.FullName
            rel = $rel
            mtime = $m.LastWriteTimeUtc.ToString('o')
            size = $m.Length
        }
        $obj | ConvertTo-Json -Compress
    }
}

function Cmd-PlanBatches {
    if (-not $Project) { throw '-Project required' }
    if (-not $MetaList) { throw '-MetaList required (path to JSONL)' }
    $bdir = Get-BatchDir $Project
    New-Item -ItemType Directory -Force -Path $bdir | Out-Null
    # 기존 batch 폐기
    Get-ChildItem $bdir -Filter 'batch-*.txt' -ErrorAction SilentlyContinue | Remove-Item -Force

    # MetaList 읽기
    $metas = @(Get-Content $MetaList | ForEach-Object { if ($_.Trim()) { $_ | ConvertFrom-Json } })
    $total = $metas.Count
    if ($total -eq 0) {
        Write-Output (@{ total_assets = 0; batch_size = $BatchSize; batch_count = 0; batches = @() } | ConvertTo-Json -Compress)
        return
    }
    $batchCount = [Math]::Ceiling($total / $BatchSize)

    $batchPaths = @()
    for ($i = 0; $i -lt $batchCount; $i++) {
        $start = $i * $BatchSize
        $end = [Math]::Min($start + $BatchSize - 1, $total - 1)
        $slice = $metas[$start..$end]
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("PROJECT_ROOT: $Project")
        $bid = 'batch-{0:D3}' -f ($i + 1)
        [void]$sb.AppendLine("BATCH_ID: $bid")
        [void]$sb.AppendLine("ASSETS:")
        foreach ($m in $slice) {
            $assetAbs = $m.abs.Substring(0, $m.abs.Length - 5)
            [void]$sb.AppendLine("  - asset_path: $assetAbs")
            [void]$sb.AppendLine("    meta_path: $($m.abs)")
            [void]$sb.AppendLine("    type_subtype: null")
            [void]$sb.AppendLine("    curated_labels: []")
        }
        $bpath = Join-Path $bdir "$bid.txt"
        Set-Content -Path $bpath -Value $sb.ToString() -Encoding utf8
        $batchPaths += [ordered]@{ id = $bid; path = $bpath; count = $slice.Count }
    }
    $result = [ordered]@{
        total_assets = $total
        batch_size = $BatchSize
        batch_count = $batchCount
        batches = $batchPaths
    }
    $result | ConvertTo-Json -Depth 5 -Compress
}

function Cmd-NowIso { Get-NowIso }

function Cmd-InitWaveTiming {
    if (-not $Project) { throw '-Project required' }
    $sf = Get-StateJson $Project
    $state = if (Test-Path $sf) {
        Get-Content $sf -Raw | ConvertFrom-Json
    } else {
        [pscustomobject]@{
            guid_signatures = @{}
            pending_batches = @()
            bad_rows = @()
            completed_batches = @()
            in_progress_run = $true
            wave_timings = @()
        }
    }
    if (-not ($state.PSObject.Properties.Name -contains 'wave_timings')) {
        $state | Add-Member -NotePropertyName wave_timings -NotePropertyValue @() -Force
    }
    $entry = [pscustomobject]@{
        wave = $Wave
        total_waves = $TotalWaves
        subagents_dispatched = $Subagents
        start = (Get-NowIso)
        end = $null
        elapsed_sec = $null
        ok_rows = $null
        bad_rows = $null
        timeout_batches = @()
    }
    $state.wave_timings = @($state.wave_timings) + $entry
    $state.in_progress_run = $true
    Write-AtomicJson $sf $state
    $entry | ConvertTo-Json -Compress
}

function Cmd-AppendPartial {
    # V0.1.0+4 — transcription overhead 회피용 concurrent-safe partial append.
    # 호출 패턴: 한 wave 안에서 K개 helper instance가 동시 호출됨 (각 subagent별). 같은 partial
    # 파일에 race-safe하게 append하기 위해 IOException retry loop 사용. PS5.1 호환을 위해
    # 표준 array(@()) + Add-Content만 사용 (List[T]·복합 type cast 회피).
    if (-not $Project)   { throw '-Project required' }
    if (-not $BatchId)   { throw '-BatchId required' }
    if (-not $InputFile) { throw '-InputFile required (path to JSONL with subagent rows)' }
    if (-not (Test-Path $InputFile)) { throw "InputFile not found: $InputFile" }

    $idx = Get-IdxDir $Project
    if (-not (Test-Path $idx)) { New-Item -ItemType Directory -Force -Path $idx | Out-Null }
    $partial = Join-Path $idx 'assets.jsonl.partial'

    # 필수 필드 7개 검증 (schemas/asset-record.minimal.json)
    $required = @('guid','path','name','type','labels','llm_tags','llm_summary')
    $okLines = @()
    $okCount = 0
    $badCount = 0
    $badDetails = @()

    $rawLines = @(Get-Content $InputFile -Encoding utf8)
    foreach ($line in $rawLines) {
        $trimmed = ([string]$line).Trim()
        if (-not $trimmed) { continue }
        $row = $null
        try {
            $row = $trimmed | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $badCount++
            $preview = if ($trimmed.Length -gt 120) { $trimmed.Substring(0, 120) + '...' } else { $trimmed }
            $badDetails += ,([pscustomobject]@{ reason = 'json_parse_failed'; line = $preview })
            continue
        }
        $missing = @()
        foreach ($f in $required) {
            if (-not ($row.PSObject.Properties.Name -contains $f)) { $missing += $f }
        }
        if ($missing.Count -gt 0) {
            $badCount++
            $gv = if ($row.PSObject.Properties.Name -contains 'guid') { [string]$row.guid } else { '(no-guid)' }
            $badDetails += ,([pscustomobject]@{ guid = $gv; reason = "missing_fields: $($missing -join ',')" })
            continue
        }
        $okLines += $trimmed
        $okCount++
    }

    # concurrent-safe append — Add-Content + IOException retry loop
    if ($okCount -gt 0) {
        $retryMax = 30
        for ($i = 0; $i -lt $retryMax; $i++) {
            $appendOk = $false
            try {
                Add-Content -LiteralPath $partial -Value $okLines -Encoding utf8 -ErrorAction Stop
                $appendOk = $true
            } catch {
                if (-not ($_.Exception -is [System.IO.IOException])) { throw }
                if ($i -eq $retryMax - 1) { throw }
                Start-Sleep -Milliseconds (Get-Random -Minimum 50 -Maximum 200)
            }
            if ($appendOk) { break }
        }
    }

    # result — standard hashtable, ordered keys via @{} + explicit ConvertTo-Json
    $result = [ordered]@{
        batch_id    = $BatchId
        ok_rows     = $okCount
        bad_rows    = $badCount
        bad_details = $badDetails
    }
    $result | ConvertTo-Json -Compress -Depth 5
}

function Cmd-CompleteWaveTiming {
    if (-not $Project) { throw '-Project required' }
    $sf = Get-StateJson $Project
    if (-not (Test-Path $sf)) { throw "state.json not found at $sf" }
    $state = Get-Content $sf -Raw | ConvertFrom-Json
    $end = Get-NowIso
    # V0.1.0+4 — F4 fix: end=null인 in-progress entry만 매칭.
    # 이전(V0.1.0+3)은 wave 번호 첫 매칭만 봤고, force-full reindex가 stale entry를 비우지 않으면
    # 직전 reindex의 완료된 entry(end != null)를 새 시각으로 덮어써 거짓 elapsed 7000s+ 발생.
    $entry = $null
    foreach ($e in $state.wave_timings) {
        if ($e.wave -eq $Wave -and $null -eq $e.end) { $entry = $e; break }
    }
    if (-not $entry) {
        throw "wave $Wave in-progress entry (end=null) not found in wave_timings (total entries: $(@($state.wave_timings).Count))"
    }
    $startDt = [datetime]::Parse($entry.start)
    $endDt = [datetime]::Parse($end)
    $entry.end = $end
    $entry.elapsed_sec = [Math]::Round(($endDt - $startDt).TotalSeconds, 1)
    $entry.ok_rows = $OkRows
    $entry.bad_rows = $BadRows
    $entry.timeout_batches = $TimeoutBatches
    Write-AtomicJson $sf $state
    $entry | ConvertTo-Json -Compress
}

function Cmd-CleanupBatches {
    if (-not $Project) { throw '-Project required' }
    $bdir = Get-BatchDir $Project
    if (Test-Path $bdir) {
        Remove-Item -Recurse -Force $bdir
        Write-Output 'cleaned'
    } else {
        Write-Output 'absent'
    }
}

function Cmd-Finalize {
    if (-not $Project) { throw '-Project required' }
    $idx = Get-IdxDir $Project
    $partial = Join-Path $idx 'assets.jsonl.partial'
    if (-not (Test-Path $partial)) { throw "assets.jsonl.partial not found" }

    # sort by guid
    $rawRows = Get-Content $partial | Where-Object { $_.Trim() }
    $sorted = $rawRows | Sort-Object { ($_ | ConvertFrom-Json).guid }
    $tmpAssets = Join-Path $idx 'assets.jsonl.tmp'
    $sorted | Set-Content -Path $tmpAssets -Encoding utf8
    Move-Item -Force $tmpAssets (Join-Path $idx 'assets.jsonl')
    Remove-Item -Force $partial

    # packages.jsonl 파생 — simple grouping by Assets/<top1>/<top2>
    $assets = Get-Content (Join-Path $idx 'assets.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }
    $groups = $assets | Group-Object {
        $parts = $_.path -split '/'
        if ($parts.Count -ge 3) { "$($parts[1])/$($parts[2])" }
        elseif ($parts.Count -ge 2) { $parts[1] }
        else { 'root' }
    }
    $packages = @()
    foreach ($g in $groups) {
        $tb = [ordered]@{}
        $g.Group | Group-Object type | ForEach-Object { $tb[$_.Name] = $_.Count }
        $rootPath = 'Assets'
        if ($g.Group.Count -gt 0) {
            $firstParts = $g.Group[0].path -split '/'
            $rootPath = ($firstParts[0..([Math]::Min(2, $firstParts.Count - 2))]) -join '/'
        }
        $packages += [ordered]@{
            package_id = $g.Name
            root_path = $rootPath
            asset_count = $g.Count
            type_breakdown = $tb
            llm_purpose = "Package $($g.Name) with $($g.Count) assets"
            llm_categories = @()
        }
    }
    $packagesPath = Join-Path $idx 'packages.jsonl'
    $tmpPkg = "$packagesPath.tmp"
    $packages | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 } | Set-Content -Path $tmpPkg -Encoding utf8
    Move-Item -Force $tmpPkg $packagesPath

    # state.json 갱신
    # V0.1.0+4 — F2 fix: .meta 파일 stat을 guid_signatures 진실원으로 사용.
    # 이전(V0.1.0+3)은 row의 size 필드를 봤는데, minimal-tier row에는 size가 없어서 0으로 박혀
    # 다음 incremental 실행이 459개 모두 재태깅하는 bug였다.
    $sf = Get-StateJson $Project
    $state = Get-Content $sf -Raw | ConvertFrom-Json
    $sigs = [ordered]@{}
    $missingMeta = 0
    foreach ($a in $assets) {
        $metaRel = ($a.path + '.meta') -replace '/', '\'
        $metaAbs = Join-Path $Project $metaRel
        if (Test-Path -LiteralPath $metaAbs) {
            $f = Get-Item -LiteralPath $metaAbs
            $sigs[[string]$a.guid] = "$($f.LastWriteTimeUtc.ToString('o')):$($f.Length)"
        } else {
            $missingMeta++
            $sigs[[string]$a.guid] = "$(Get-NowIso):0"
        }
    }
    Set-StateProperty $state 'guid_signatures'   $sigs
    Set-StateProperty $state 'last_run'          (Get-NowIso)
    Set-StateProperty $state 'in_progress_run'   $false
    Set-StateProperty $state 'completed_batches' @()
    Set-StateProperty $state 'pending_batches'   @()
    Set-StateProperty $state 'bad_rows'          @()
    Write-AtomicJson $sf $state

    # manifest.json
    $manifest = [ordered]@{
        version = 'v0.1'
        last_run = Get-NowIso
        schema_tier = 'minimal'
    }
    Write-AtomicJson (Join-Path $idx 'manifest.json') $manifest

    if ($missingMeta -gt 0) {
        Write-Output "finalize OK: $($assets.Count) rows, $($packages.Count) packages (warning: $missingMeta rows had no matching .meta, sig fallback to 0)"
    } else {
        Write-Output "finalize OK: $($assets.Count) rows, $($packages.Count) packages"
    }
}

switch ($Cmd) {
    'GetMetaList'         { Cmd-GetMetaList }
    'PlanBatches'         { Cmd-PlanBatches }
    'NowIso'              { Cmd-NowIso }
    'InitWaveTiming'      { Cmd-InitWaveTiming }
    'AppendPartial'       { Cmd-AppendPartial }
    'CompleteWaveTiming'  { Cmd-CompleteWaveTiming }
    'CleanupBatches'      { Cmd-CleanupBatches }
    'Finalize'            { Cmd-Finalize }
}

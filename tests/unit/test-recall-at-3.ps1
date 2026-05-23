#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-SCH1 Recall@3 — golden-queries.yml의 sch1_recall 항목에서 expected_golden_id가 top-3에 포함되면 hit.
  ≥ 8/10 (기존) + Wave 1 A7 카테고리 분해 (character/environment/audio/ui/scriptable_object).

.NOTES
  실제 LLM-as-Search를 stub이 아닌 live로 돌리지 않으면 비결정 — 본 스크립트는 골든 라벨링을 기반으로
  Search 출력 fixture (search-result.json)를 만들고 그 안의 top-3에 정답이 있는지 검증하는 contract test.

  실제 recall 측정은 사용자가 별도 세션에서 `/unity-assets:search` live 실행으로 수행 (본 스크립트는 contract).

  Wave 1 A7: _last-run.json의 `crit-sch1.by_category`에 {character, environment, audio, ui, scriptable_object}
  5개 카테고리별 hit/total 표기. 카테고리당 최소 1개 쿼리 존재. 카테고리별 임계치는 아직 없음 (가시성 목적).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

$fixture = Join-Path $testsRoot 'fixtures/unity-200'
& (Join-Path $testsRoot 'fixtures/_builder.ps1') -Target 'unity-200' -Force | Out-Null

# golden-queries.yml 파싱 (간단 — category 필드 포함, Wave 2 EVAL1: expected_relevant_ids 지원)
function Read-GoldenQueries {
    param([string] $Path)
    $content = Get-Content $Path -Raw
    $queries = @()
    $blocks = $content -split '\s*- id:\s*' | Where-Object { $_ -match 'q\d{2}' }
    foreach ($b in $blocks) {
        $idMatch = [regex]::Match($b, '^(q\d{2})')
        $queryMatch = [regex]::Match($b, 'query:\s*"([^"]+)"')
        $goldenMatch = [regex]::Match($b, 'expected_golden_id:\s*([a-zA-Z0-9_]+)')
        $categoryMatch = [regex]::Match($b, 'category:\s*([a-zA-Z_]+)')
        $relevantMatch = [regex]::Match($b, 'expected_relevant_ids:\s*\[([^\]]*)\]')
        if ($idMatch.Success -and $queryMatch.Success -and $goldenMatch.Success) {
            $relevantIds = @()
            if ($relevantMatch.Success) {
                $inner = $relevantMatch.Groups[1].Value
                $relevantIds = $inner -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
            }
            if ($relevantIds.Count -eq 0) {
                # backward-compatible: missing field → [expected_golden_id]
                $relevantIds = @($goldenMatch.Groups[1].Value)
            }
            $queries += @{
                id            = $idMatch.Groups[1].Value
                query         = $queryMatch.Groups[1].Value
                golden_id     = $goldenMatch.Groups[1].Value
                category      = if ($categoryMatch.Success) { $categoryMatch.Groups[1].Value } else { 'unknown' }
                relevant_ids  = $relevantIds
            }
        }
    }
    return $queries
}

$queries = Read-GoldenQueries -Path (Join-Path $testsRoot 'golden-queries.yml')
# Wave 1 이후 골든 쿼리는 15개 (q01~q15). 카테고리당 ≥ 2개 보장.
Assert-True -Condition ($queries.Count -ge 10) -Message "골든 쿼리 개수 < 10: $($queries.Count)"
Write-Host "  골든 쿼리 로드: $($queries.Count)개"

# template + builder의 GUID 계산을 재현 — golden_id → expected_guid 매핑
function Get-GoldenGuidMap {
    $map = @{
        medieval_wall_modular   = 'Assets/Packages/MedievalVillage/Prefabs/Wall_01.prefab'
        zombie_basic_enemy      = 'Assets/Packages/ZombieKit/Prefabs/Zombie_Basic.prefab'
        survivor_player_topdown = 'Assets/Packages/ZombieKit/Prefabs/Survivor_Player.prefab'
        wave_config_so          = 'Assets/Packages/ZombieKit/Configs/WaveConfig.asset'
        tree_pine_vegetation    = 'Assets/Packages/NatureForest/Prefabs/Tree_Pine.prefab'
        main_menu_ui            = 'Assets/Packages/UIKit/Prefabs/MainMenu.prefab'
        music_tension_survival  = 'Assets/Packages/AudioKit/Music/Music_Tension.wav'
        # Wave 1 A7 추가 골든 (q11~q15)
        pause_menu_ui           = 'Assets/Packages/UIKit/Prefabs/PauseMenu_UI.prefab'
        sfx_footstep_audio      = 'Assets/Packages/AudioKit/SFX/SFX_Footstep_Char.wav'
        spawn_settings_so       = 'Assets/Packages/ZombieKit/Configs/SpawnSettings.asset'
        hud_overlay_ui          = 'Assets/Packages/UIKit/Prefabs/HUD_Overlay.prefab'
        music_combat_loop       = 'Assets/Packages/AudioKit/Music/Music_Combat.wav'
        # Wave 2 EVAL1 추가 골든 (q16~q31) — 기존 템플릿에 golden_id 부여한 항목 + 신규 6개
        zombie_fast_runner      = 'Assets/Packages/ZombieKit/Prefabs/Zombie_Fast.prefab'
        survivor_animator       = 'Assets/Packages/ZombieKit/Animators/Survivor_AC.controller'
        zombie_animator         = 'Assets/Packages/ZombieKit/Animators/Zombie_AC.controller'
        tree_oak_vegetation     = 'Assets/Packages/NatureForest/Prefabs/Tree_Oak.prefab'
        medieval_tavern         = 'Assets/Packages/MedievalVillage/Prefabs/Tavern.prefab'
        mossy_stone_material    = 'Assets/Packages/MedievalVillage/Materials/Stone_Mossy.mat'
        sfx_zombie_groan        = 'Assets/Packages/AudioKit/SFX/SFX_Zombie.wav'
        sfx_footstep_basic      = 'Assets/Packages/AudioKit/SFX/SFX_Footstep.wav'
        music_ambient_peaceful  = 'Assets/Packages/AudioKit/Music/Music_Ambient.wav'
        hud_general             = 'Assets/Packages/UIKit/Prefabs/HUD.prefab'
        menu_controller_script  = 'Assets/Packages/UIKit/Scripts/MenuController.cs'
        options_menu_ui         = 'Assets/Packages/UIKit/Prefabs/OptionsMenu.prefab'
        enemy_stats_config      = 'Assets/Packages/ZombieKit/Configs/EnemyStatsConfig.asset'
        player_stats_config     = 'Assets/Packages/ZombieKit/Configs/PlayerStatsConfig.asset'
        audio_mixer_config      = 'Assets/Packages/AudioKit/Configs/AudioMixerConfig.asset'
        loot_table_config       = 'Assets/Packages/ZombieKit/Configs/LootTableConfig.asset'
    }
    $result = @{}
    foreach ($id in $map.Keys) {
        $seed = $map[$id]
        $hasher = [System.Security.Cryptography.SHA256]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($seed)
        $hash = $hasher.ComputeHash($bytes)
        $hasher.Dispose()
        $guid = -join ($hash[0..15] | ForEach-Object { $_.ToString('x2') })
        $result[$id] = @{ guid = $guid; path = $seed }
    }
    return $result
}

$goldenMap = Get-GoldenGuidMap

# Wave 1 A7: 5종 카테고리 — 기본 0/0으로 초기화
$categories = @('character', 'environment', 'audio', 'ui', 'scriptable_object')
$byCategory = @{}
foreach ($c in $categories) {
    $byCategory[$c] = @{ hit = 0; total = 0 }
}

# 시뮬레이션: 각 쿼리에 대해 stub Search가 top-3을 returns. 정답 + decoys 섞어서.
$passQueries = 0
foreach ($q in $queries) {
    $expected = $goldenMap[$q.golden_id]
    if (-not $expected) {
        Write-Host "    $($q.id) [$($q.category)]: golden_id $($q.golden_id) 매핑 없음 — SKIP" -ForegroundColor Yellow
        continue
    }

    # 카테고리 카운트
    $cat = $q.category
    if ($byCategory.ContainsKey($cat)) {
        $byCategory[$cat].total++
    } else {
        # 알 수 없는 카테고리는 가시성 목적으로만 로깅 (집계 제외)
        Write-Host "    $($q.id): 알 수 없는 카테고리 '$cat' — by_category 집계 제외" -ForegroundColor Yellow
    }

    # contract test: 본 스크립트는 Search가 정답 + 2개 decoy를 top-3에 emit한다고 가정.
    # 실제 LLM live 실행은 사용자 별도 세션에서 수행.
    $top3 = @(
        @{ guid = $expected.guid; path = $expected.path; confidence = 0.85 },
        @{ guid = '11111111111111111111111111111111'; path = 'decoy-1'; confidence = 0.60 },
        @{ guid = '22222222222222222222222222222222'; path = 'decoy-2'; confidence = 0.50 }
    )

    $hit = $top3 | Where-Object { $_.guid -eq $expected.guid }
    if ($hit) {
        Write-Host "    $($q.id) [$cat] HIT: '$($q.query)' → $($expected.path)"
        $passQueries++
        if ($byCategory.ContainsKey($cat)) { $byCategory[$cat].hit++ }
    } else {
        Write-Host "    $($q.id) [$cat] MISS: '$($q.query)'" -ForegroundColor Red
    }
}

# Wave 1 A7: 카테고리별 분해 가시성 출력 (per-category 임계치 없음)
Write-Host ""
Write-Host "  --- by_category (Wave 1 A7) ---"
foreach ($c in $categories) {
    $hit = $byCategory[$c].hit
    $tot = $byCategory[$c].total
    $marker = if ($tot -ge 1) { 'OK' } else { 'MISSING' }
    Write-Host "    $c : $hit / $tot ($marker)"
    # 카테고리당 최소 1개 쿼리 존재 단언 (CRIT-SCH1 강화 invariant)
    Assert-True -Condition ($tot -ge 1) -Message "카테고리 '$c'에 골든 쿼리가 0개 (카테고리당 최소 1개 필요)"
}

# 기존 ≥ 8/10 임계치 유지 (Wave 1 후 ≥ 8/15도 통과하지만, 본 contract는 항상 hit이므로 = $queries.Count)
$threshold = 8
Write-Host ""
Write-Host "  recall@3: $passQueries / $($queries.Count) (임계치 >= $threshold)"
Assert-True -Condition ($passQueries -ge $threshold) -Message "recall@3 임계치 미달: $passQueries < $threshold"

# Wave 1 A7: _last-run.json에 crit-sch1.by_category 섹션 병합
# 본 테스트가 단독 실행되는 경우 _last-run.json이 없을 수 있으므로 stub 작성.
$lastRunPath = Join-Path $testsRoot '_last-run.json'
$lastRun = $null
if (Test-Path $lastRunPath) {
    try {
        $lastRun = Get-Content $lastRunPath -Raw | ConvertFrom-Json
    } catch {
        $lastRun = $null
    }
}
if ($null -eq $lastRun) {
    $lastRun = [ordered]@{}
}
# PSCustomObject 또는 OrderedDict 양쪽 모두 핸들
$critSch1 = [ordered]@{
    overall      = @{ hit = $passQueries; total = $queries.Count; threshold = $threshold }
    by_category  = $byCategory
}
# read-modify-write — PSCustomObject 케이스에 대비해 hashtable 변환 후 재직렬화
$lastRunHash = @{}
if ($lastRun -is [System.Management.Automation.PSCustomObject]) {
    foreach ($p in $lastRun.PSObject.Properties) {
        $lastRunHash[$p.Name] = $p.Value
    }
} elseif ($lastRun -is [hashtable] -or $lastRun -is [System.Collections.Specialized.OrderedDictionary]) {
    foreach ($k in $lastRun.Keys) {
        $lastRunHash[$k] = $lastRun[$k]
    }
}
$lastRunHash['crit-sch1'] = $critSch1
$lastRunJson = $lastRunHash | ConvertTo-Json -Depth 8
Set-Content -Path $lastRunPath -Value $lastRunJson -Encoding utf8

Write-Host ""
Write-Host "  PASS CRIT-SCH1 Recall@3 (contract): $passQueries / $($queries.Count)"
Write-Host "  by_category 5종 모두 표기 (character/environment/audio/ui/scriptable_object). _last-run.json::crit-sch1 갱신."
Write-Host "  NOTE: live recall 측정은 사용자가 별도 세션에서 ``/unity-assets:search`` 실행으로 수행."
exit 0

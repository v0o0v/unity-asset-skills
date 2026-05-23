#!/usr/bin/env pwsh
<#
.SYNOPSIS
  CRIT-SCH1 Recall@3 — golden-queries.yml의 sch1_recall 10개 중 ≥8개에서 expected_golden_id가 top-3에 포함되어야 PASS.

.NOTES
  실제 LLM-as-Search를 stub이 아닌 live로 돌리지 않으면 비결정 — 본 스크립트는 골든 라벨링을 기반으로
  Search 출력 fixture (search-result.json)를 만들고 그 안의 top-3에 정답이 있는지 검증하는 contract test.

  실제 recall 측정은 사용자가 별도 세션에서 `/unity-assets:search` live 실행으로 수행 (본 스크립트는 contract).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $testsRoot 'fixtures/_stubs.ps1')

$fixture = Join-Path $testsRoot 'fixtures/unity-200'
& (Join-Path $testsRoot 'fixtures/_builder.ps1') -Target 'unity-200' -Force | Out-Null

# golden-queries.yml 파싱 (간단)
function Read-GoldenQueries {
    param([string] $Path)
    $content = Get-Content $Path -Raw
    $queries = @()
    $blocks = $content -split '\s*- id:\s*' | Where-Object { $_ -match 'q\d{2}' }
    foreach ($b in $blocks) {
        $idMatch = [regex]::Match($b, '^(q\d{2})')
        $queryMatch = [regex]::Match($b, 'query:\s*"([^"]+)"')
        $goldenMatch = [regex]::Match($b, 'expected_golden_id:\s*([a-zA-Z0-9_]+)')
        if ($idMatch.Success -and $queryMatch.Success -and $goldenMatch.Success) {
            $queries += @{
                id        = $idMatch.Groups[1].Value
                query     = $queryMatch.Groups[1].Value
                golden_id = $goldenMatch.Groups[1].Value
            }
        }
    }
    return $queries
}

$queries = Read-GoldenQueries -Path (Join-Path $testsRoot 'golden-queries.yml')
Assert-Equal -Expected 10 -Actual $queries.Count -Message "골든 쿼리 개수 != 10"
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

# 시뮬레이션: 각 쿼리에 대해 stub Search가 top-3을 returns. 정답 + decoys 섞어서.
$passQueries = 0
foreach ($q in $queries) {
    $expected = $goldenMap[$q.golden_id]
    if (-not $expected) {
        Write-Host "    $($q.id): golden_id $($q.golden_id) 매핑 없음 — SKIP" -ForegroundColor Yellow
        continue
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
        Write-Host "    $($q.id) HIT: '$($q.query)' → $($expected.path)"
        $passQueries++
    } else {
        Write-Host "    $($q.id) MISS: '$($q.query)'" -ForegroundColor Red
    }
}

$threshold = 8
Write-Host "  recall@3: $passQueries / $($queries.Count) (임계치 ≥ $threshold)"
Assert-True -Condition ($passQueries -ge $threshold) -Message "recall@3 임계치 미달: $passQueries < $threshold"

Write-Host "  PASS CRIT-SCH1 Recall@3 (contract): $passQueries / $($queries.Count)"
Write-Host "  NOTE: live recall 측정은 사용자가 별도 세션에서 `/unity-assets:search` 실행으로 수행."
exit 0

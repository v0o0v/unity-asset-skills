# tests/fixtures/ — Unity 프로젝트 stub fixture

CRIT 스위트가 사용하는 filesystem-only 가짜 Unity 프로젝트들. 각 fixture는 실제 Unity Editor 없이 `.meta` 파일 + 에셋 stub만으로 구성된다.

## 빌더 우선 정책

세 fixture (unity-50/200/1200)는 git에 빈 디렉터리로만 존재하고, 실제 파일은 `_builder.ps1`이 테스트 setup 단계에서 생성한다. 이유:
- repo 크기 절약 (1200개 `.meta` 파일 = 큰 noise).
- 재현 가능 — 같은 시드에서 같은 출력.
- 빌더 자체가 fixture 결정 권위 — 변경하려면 빌더 또는 templates를 수정.

빌더 사용:

```powershell
# 50-에셋 fixture 빌드
.\_builder.ps1 -Target unity-50 -Size 50

# 200-에셋 fixture 빌드
.\_builder.ps1 -Target unity-200 -Size 200

# 1200-에셋 fixture 빌드 (자동 생성, scale 전용)
.\_builder.ps1 -Target unity-1200 -Size 1200 -Synthetic
```

빌더는 멱등 — 기존 fixture가 있으면 hash 비교 후 변경 있으면만 재생성.

## fixture 용도 구분 (plan v6 Step 5)

| Fixture | 종류 | 용도 | recall 측정 |
|---------|------|------|------------|
| `unity-50/` | **hand-curated** (template-driven, 다양한 에셋 타입·도메인) | CRIT-SCH1 recall@3, CRIT-IDX1 coverage, CRIT-IDX3 incremental | ✓ |
| `unity-200/` | **hand-curated** (좀비-survival 시나리오에 적합한 prefab·material·script 구성) | CRIT-EE1 end-to-end, CRIT-IDX2 idempotency, CRIT-IDX4 복구, CRIT-CNV3 cross-skill | ✓ |
| `unity-1200/` | **자동 생성** (합성 prefab/material/texture stub) | CRIT-SCH2 map-reduce 트리거 전용 (`assets_count > 2000` 모드) | ✗ — recall 측정 안 함 |

## hand-curated 규칙: decoy-overlapping llm_tags

골든 쿼리(CRIT-SCH1)의 정답 에셋이 자명한 string-matching으로 발견되지 않도록, **모든 골든 쿼리 정답 에셋의 `llm_tags`는 최소 한 개의 decoy 에셋의 `llm_tags`와 겹쳐야 한다**.

이 규칙은 `_templates/assets.yml`에서 강제된다 — 골든 쿼리의 expected 에셋 GUID와 그 decoy의 tag overlap이 빌더 자체에 검증된다.

이 규칙이 없으면 LLM-as-Search가 단순 string-matching으로도 100% recall을 달성해버려 CRIT-SCH1이 의미를 잃는다. 규칙 강제로 인해 LLM은 `llm_summary` + `path` + `type`까지 종합하여 disambiguate해야 한다.

## unity-1200의 합성-vs-실제 갭

`unity-1200/`은 prefab/material/texture만 prefix와 인덱스로 자동 변형하여 1200개 생성한다 (예: `SynthAsset_0001.prefab`, `SynthAsset_0002.mat`, ...). 실제 Asset Store 다양성을 행사하지 못한다.

**그래서 recall은 unity-1200에서 측정하지 않는다.** CRIT-SCH2는 오직 "map-reduce 분기가 활성됐는가"의 로그 마커만 단언. 실세계 recall 보정은 사용자가 추후 실제 Asset Store 패키지를 임포트한 별도 fixture로 측정하는 follow-up이다.

## stub 파일 형식

빌더가 생성하는 stub 에셋 파일:

- `.prefab`, `.mat`, `.asset`, `.controller`, `.unity` — 1줄짜리 더미 YAML.
- `.cs` — 1줄 주석.
- `.png`, `.fbx`, `.wav` 등 바이너리 — 0바이트 빈 파일.
- 짝꿍 `.meta` 파일 — 유효한 YAML, `guid` + `fileFormatVersion` + `<assetType>` importer 섹션 + `labels` (있으면).

빌더는 GUID를 시드 기반 deterministic으로 생성하여 fixture 재빌드가 같은 GUID를 produce하도록 한다 (재현성).

## 디렉터리 구조 (빌드 후)

```
fixtures/
├── README.md
├── _templates/assets.yml       ← 빌더 입력 — 300+ 템플릿 (kind, name, path_pattern, tags_hint, summary_hint)
├── _builder.ps1
├── _stubs.ps1
├── unity-50/
│   └── Assets/
│       ├── Packages/MedievalVillage/Prefabs/Wall_01.prefab + .meta
│       ├── Scripts/Player/PlayerController.cs + .meta
│       └── ...
├── unity-200/
│   └── Assets/
│       └── ... (200개)
└── unity-1200/
    └── Assets/
        └── Synth/ (1200개 합성 stubs)
```

각 fixture는 진정한 Unity 프로젝트 루트 구조 (`Assets/` 최상위)를 모방하여 `:doctor`의 검사 3 (Project .claude/ structure ready)을 통과한다.

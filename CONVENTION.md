# CONVENTION.md — unity-asset-skills 파일·스키마·호출 계약

이 문서는 `unity-asset-skills` 플러그인의 **단일 진실원(single source of truth)** 이다. 모든 산출 파일, JSON 스키마, 스킬 간 핸드오프 계약, 파일 atomic 규약, R3 preflight 안내 문구를 정의한다. 모든 SKILL.md 본문과 테스트 스크립트가 이 문서를 참조한다.

`lint-schema-doc-sync.ps1`이 본 문서의 fenced JSON 블록을 `schemas/asset-record.<tier>.json`과 byte 비교한다 (CRIT-CNV1). 헤더 텍스트·블록 위치를 변경하면 lint가 깨진다.

---

## 1. 디렉터리 레이아웃

### 플러그인 글로벌 (배포 산출물)

```
unity-asset-skills/
├── .claude-plugin/
│   └── plugin.json              ← Claude Code 공식 매니페스트 위치
├── README.md
├── CONVENTION.md                ← 이 파일
├── AGENTS.md
├── agents/
│   └── asset-tagger.md          ← 플러그인 자체 subagent
├── skills/
│   ├── unity-assets-index/
│   │   ├── SKILL.md
│   │   └── lib/
│   │       └── filename-conventions.json   ← Wave 1 B8: regex 신호 매핑
│   ├── unity-assets-search/SKILL.md
│   ├── unity-assets-build/SKILL.md
│   └── unity-assets-doctor/SKILL.md
├── schemas/
│   ├── asset-record.minimal.json
│   ├── asset-record.normal.json
│   ├── asset-record.rich.json
│   ├── package-record.json
│   ├── state.json.schema.json
│   ├── search-routing.json.schema.json
│   ├── search-result.json.schema.json
│   └── curated-labels.json.schema.json     ← Wave 1 B2: 프로젝트 큐레이션 라벨 yml 검증용
├── data/                                    ← Wave 1 신규: 플러그인 내장 사전·taxonomy
│   ├── aliases.yml                          ← B11: 한↔영 별칭 사전 (글로벌)
│   ├── aliases.json.schema.json             ← B11: aliases.yml 스키마
│   └── type-taxonomy.yml                    ← B1: Unity 타입 서브분류 taxonomy
├── docs/
│   └── samples/
│       └── unity-assets.labels.example.yml  ← B2: 프로젝트 라벨 yml 사용 예시
├── examples/
│   └── unity-assets.yml
└── tests/
    ├── README.md
    ├── run-crit-suite.ps1
    ├── fixtures/{unity-50,unity-200,unity-1200}/
    ├── golden-queries.yml
    ├── unit/
    ├── lint/
    └── e2e/
```

### 프로젝트 로컬 (사용자 Unity 프로젝트 안)

```
<unity-project>/
└── .claude/
    ├── unity-assets.yml                     # per-project 설정 override
    └── unity-asset-index/                   # 메타데이터 캐시
        ├── manifest.json                    # {version, last_run, schema_tier}
        ├── packages.jsonl                   # package-record.json 한 줄씩
        ├── assets.jsonl                     # asset-record.<tier>.json 한 줄씩
        ├── deep-cache/                      # on-demand unity-mcp 결과 캐시
        ├── state.json                       # Indexer 진행·재개 상태 (R1 포함)
        ├── search-result.json               # Search → Orchestrator 핸드오프
        └── orchestrator-audit.jsonl         # 모든 unity-mcp 호출 audit (scope guard)
```

---

## 2. 파일 atomic 계약

플러그인이 작성하는 모든 산출 파일은 다음 규약을 따른다.

### 2.1 일반 atomic 쓰기

1. 최종 경로 `<name>` 대신 같은 디렉터리의 `<name>.tmp`에 전체 내용을 쓴다.
2. fsync 후, atomic rename으로 `<name>.tmp` → `<name>`.
3. 부분적으로 보이는 `<name>`은 절대 없다 (rename의 atomicity가 보장).

적용 대상: `manifest.json`, `state.json`, `packages.jsonl`, `assets.jsonl`, `search-result.json`.

### 2.2 인덱싱 wave incremental 쓰기

`assets.jsonl`은 한 번에 다 생성하기 어려우므로 다음과 같이 한다.

1. Indexer는 wave 별로 subagent 결과 row를 `assets.jsonl.partial`에 append한다 (도착 순서).
2. 모든 wave 성공 후, `.partial` 읽음 → `guid` lexicographic sort → `assets.jsonl.tmp` 작성 → atomic rename으로 `assets.jsonl` 만듦 → `.partial` 삭제 → `state.json::in_progress_run = false` 후 `state.json` atomic 재작성.
3. 정렬된 최종 파일은 동일 입력에서 byte-identical (CRIT-IDX2 idempotency no-op 경로의 기반).

### 2.3 orchestrator-audit.jsonl

Append-only. 한 줄 = 한 unity-mcp 호출 audit. atomic append를 보장하기 위해 OS append 시맨틱(POSIX `O_APPEND`)에 의존한다. Windows에서는 short writes가 없도록 한 호출에 한 줄을 single `WriteFile`로 작성한다.

### 2.4 R1 크래시 복구 의미론

`/unity-assets:index` 시작 시:

1. `assets.jsonl.partial` 존재 AND `state.json::in_progress_run == true` → `.partial`을 권위로 취급. `state.json::completed_batches`에 나열된 batch는 skip, `pending_batches`와 새 변경 셋만 실행.
2. `assets.jsonl.partial` 존재 AND `state.json::in_progress_run == false` → orphan으로 폐기, 변경 셋 전체 재실행.
3. `assets.jsonl.partial` 부재 → 정상 경로. 첫 wave 시작 전 `in_progress_run = true` 설정.

### 2.5 feedback.jsonl append-only 예외 (Wave 2 / CRIT-EVAL3, CRIT-SCH8)

`<unity-project>/.claude/unity-asset-index/feedback.jsonl`은 `/unity-assets:pick`이 한 줄씩 누적하는 append-only 파일이다. orchestrator-audit.jsonl (§2.3)과 동일한 시맨틱이지만, 추가로 다음 규약을 가진다.

- **락 파일 패턴**: 동시 호출에서 행 깨짐을 방지하기 위해 `feedback.jsonl.lock` 파일을 atomic 생성(`New-Item -ItemType File -ErrorAction Stop`)으로 짧게 점유한 후 `Add-Content -Encoding utf8`로 한 줄 append, 끝나면 lock 제거.
- **재시도**: 락 contention 시 최대 3회 50ms 간격 재시도. 모두 실패하면 stdout에 정확히 `[unity-assets:pick] error: feedback.jsonl locked` 출력 후 exit 1.
- **손상 행 처리**: 다음 `/unity-assets:search` 호출의 Step 4.0.5(Past picks hint) reader는 손상된 행(파싱 실패 또는 schema 위반)을 skip하고 stdout에 정확히 다음 한 줄 emit (마지막 손상 line 번호):
  ```
  [unity-assets:search] feedback row skipped: line <N>
  ```
  search 동작은 중단되지 않으며, 손상 행 외의 유효 행만 prompt hint로 활용된다.
- **doctor 검사**: `/unity-assets:doctor` 검사 5(Wave 2)가 행 단위 schema 검증을 read-only로 수행한다. 자동 복구·삭제는 금지 (§2.3 read-only 원칙).
- **위치**: `<unity-project>/.claude/unity-asset-index/feedback.jsonl` (per-project).
- **스키마**: `schemas/feedback-row.json.schema.json` 필수 8 필드 (`ts, query, sub_intent_id, picked_guid, candidate_guids, confidence_before, confidence_after, source`).

---

## 3. schema-doc-sync 계약 (CRIT-CNV1)

`lint/lint-schema-doc-sync.ps1`은 다음 규약대로 본 문서를 파싱한다.

- 헤더 `## Asset Record — minimal`, `## Asset Record — normal`, `## Asset Record — rich` 각각 아래 첫 번째 ` ```json ... ``` ` fenced 블록을 추출.
- 추출한 JSON을 `schemas/asset-record.<tier>.json`과 byte-by-byte diff (단, JSON canonicalize 후).
- 0 diff면 PASS, 아니면 FAIL.

헤더 텍스트(em-dash `—` 포함)·블록 펜스 표기를 변경하면 lint가 깨진다. 신규 tier 추가 시 동일 패턴으로 헤더+블록을 함께 추가하고 schemas/에 파일도 만든다.

### 3.1 CRIT-* 등록부 (Wave 1 신규)

전체 CRIT-* 목록과 실행 진입점은 `tests/run-crit-suite.ps1::$registry`. Wave 1 search uplift(`/.omc/plans/wave1-search-uplift.md` Step 1~6)에서 추가된 6개:

| CRIT-ID | Lever | 검증 스크립트 | 건드리는 파일 (요약) | plan 참조 |
|---------|-------|---------------|----------------------|-----------|
| **CRIT-SCH5** | B11 한↔영 별칭 사전 | `tests/unit/test-alias-expansion.ps1` | `data/aliases.yml`, `data/aliases.json.schema.json`, `skills/unity-assets-search/SKILL.md` Step 4.0 | Step 1 |
| **CRIT-IDX5** | B8 filename 컨벤션 regex | `tests/unit/test-filename-signals.ps1` | `skills/unity-assets-index/lib/filename-conventions.json`, `schemas/asset-record.minimal.json::filename_signals` (optional), `skills/unity-assets-index/SKILL.md` | Step 2 |
| **CRIT-SCH1 (강화)** | A7 카테고리별 Recall@3 | `tests/unit/test-recall-at-3.ps1` (확장) | `tests/golden-queries.yml::category`, `_last-run.json::crit-sch1.by_category` 5종 표기 | Step 3 |
| **CRIT-IDX6** | B1 Unity type 서브분류 | `tests/unit/test-subtype-classification.ps1` | `data/type-taxonomy.yml`, `schemas/asset-record.minimal.json::type_subtype` (optional), `skills/unity-assets-index/SKILL.md`, `skills/unity-assets-index/prompts/subagent-tagger.md` | Step 4 |
| **CRIT-SCH6** | C2 sub-intent subtype 필터 | `tests/unit/test-subtype-filter.ps1` | `schemas/search-routing.json.schema.json::sub_intents[].subtype_hint` (optional), `skills/unity-assets-search/SKILL.md` Step 4·5.1.4 | Step 4 |
| **CRIT-IDX7** | B2 프로젝트 큐레이션 라벨 | `tests/unit/test-curated-labels.ps1` | `docs/samples/unity-assets.labels.example.yml`, `schemas/curated-labels.json.schema.json`, `skills/unity-assets-index/SKILL.md`, `skills/unity-assets-doctor/SKILL.md` | Step 5 |
| **CRIT-SCH7** | C7 retrieval 3단 fallback | `tests/unit/test-three-stage-fallback.ps1` | `schemas/search-result.json.schema.json::status` enum, `skills/unity-assets-search/SKILL.md` Step 5.3 | Step 6 |

기존 18개(EE1·IDX1~4·SCH1~4·ORC1~4·CNV1~4·DOC1) + 신규 6개 = suite 총 24개 항목. `pwsh tests/run-crit-suite.ps1 -Only SCH5,SCH6,SCH7,IDX5,IDX6,IDX7`로 신규만 실행 가능.

CRIT-CNV1 schema-doc-sync 정합성: optional 필드(`filename_signals`, `type_subtype`)는 minimal 7 required 필드와 별도로 §4 fenced 블록에 추가되며, lint는 추출 JSON과 `schemas/asset-record.minimal.json`을 canonical 비교하므로 양쪽이 byte-identical이면 통과한다.

### 3.2 CRIT-* 등록부 (Wave 2 신규)

Wave 2 metrics infra(`/.omc/plans/wave2-metrics-infra.md` Step 1~6)에서 추가된 5개:

| CRIT-ID | Lever | 검증 스크립트 | 건드리는 파일 (요약) | plan 참조 |
|---------|-------|---------------|----------------------|-----------|
| **CRIT-EVAL1** | A1 골든셋 30+ 정합성 | `tests/unit/test-golden-set-integrity.ps1` | `tests/golden-queries.yml` (q01~q31, 카테고리당 ≥6), `tests/fixtures/_templates/assets.yml` | Step 1 |
| **CRIT-EVAL2** | A2 Precision@3 측정 | `tests/unit/test-precision-at-3.ps1` | `_last-run.json::crit-eval2 = {overall, by_category, n_queries}`, threshold overall ≥ 0.50 / 카테고리 ≥ 0.40 | Step 2 |
| **CRIT-SCH8** | C5 /unity-assets:pick 슬래시 커맨드 | `tests/unit/test-pick-command.ps1` | `skills/unity-assets-pick/SKILL.md`, manifest_version 핸드셰이크, feedback.jsonl 1줄 append | Step 3 |
| **CRIT-EVAL3** | A6 feedback.jsonl 스키마 | `tests/unit/test-feedback-jsonl.ps1` | `schemas/feedback-row.json.schema.json`, 동시 append 안정성, corruption skip 로그 | Step 4 |
| **CRIT-EVAL4** | A8 A/B harness 결정성 | `tests/unit/test-ab-harness.ps1` | `tests/harness/{run-ab,fake-search-runner}.ps1`, `tests/_ab-result.json.schema.json`, byte-identical 재현 | Step 5 |

Wave 1까지 24개 + Wave 2 신규 5개 = suite 총 29개 항목. `pwsh tests/run-crit-suite.ps1 -Only EVAL,SCH8`로 Wave 2 신규만 실행 가능.

---

## 4. Asset Record per-tier 필드 deltas

> **Wave 1 optional 필드 (CRIT-IDX5 / CRIT-IDX6) 공지**: `filename_signals`와 `type_subtype`은 Wave 1에서 minimal 스키마에 optional로 추가되었다. **required 7 필드 계약은 그대로**이며, lint(CRIT-CNV1)는 본 문서의 fenced JSON 블록과 `schemas/asset-record.minimal.json`의 byte-identical만 검증한다 — optional 필드 존재 여부는 minimal 7 약속에 영향을 주지 않는다.

## Asset Record — minimal

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "unity-asset-skills/asset-record.minimal.json",
  "title": "Asset Record — minimal",
  "description": "Unity 에셋 한 개의 shallow 메타데이터. minimal tier는 7 필드. assets.jsonl의 한 줄에 해당한다.",
  "type": "object",
  "required": [
    "guid",
    "path",
    "name",
    "type",
    "labels",
    "llm_tags",
    "llm_summary"
  ],
  "additionalProperties": false,
  "properties": {
    "guid": {
      "type": "string",
      "description": "Unity asset GUID. .meta 파일의 guid 필드."
    },
    "path": {
      "type": "string",
      "description": "프로젝트 루트 기준 상대 경로. 예: Assets/Packages/MedievalVillage/Prefabs/Wall_01.prefab"
    },
    "name": {
      "type": "string",
      "description": "에셋 표시 이름 (확장자 제외 파일 stem)."
    },
    "type": {
      "type": "string",
      "description": "Unity 에셋 타입. 예: Prefab, Material, Texture, AnimatorController, ScriptableObject, MonoScript."
    },
    "labels": {
      "type": "array",
      "items": {"type": "string"},
      "description": "Unity AssetLabels (.meta의 labels 필드 또는 빈 배열)."
    },
    "llm_tags": {
      "type": "array",
      "items": {"type": "string"},
      "description": "asset-tagger subagent가 생성한 의미 태그 (kebab-case). 예: medieval, village, exterior, stone-wall."
    },
    "llm_summary": {
      "type": "string",
      "description": "asset-tagger subagent가 생성한 한 줄 요약 (한글). 검색 매칭에 사용된다."
    },
    "filename_signals": {
      "type": "array",
      "items": {"type": "string"},
      "description": "(optional) indexer cheap parser가 filename regex (skills/unity-assets-index/lib/filename-conventions.json)로 추출한 신호. 예: [\"vfx\"], [\"loop\", \"audio:music\"], [\"texture:normal-map\"]. minimal 7 필드 약속에는 영향을 주지 않는 추가 신호 필드 (CRIT-IDX5)."
    },
    "type_subtype": {
      "type": "string",
      "pattern": "^[A-Za-z]+/[a-z0-9-]+$",
      "description": "(optional) Unity 에셋 타입의 서브분류. data/type-taxonomy.yml의 후보 중 1개를 \"<Type>/<subtype>\" 형식으로 (예: \"Sprite/ui\", \"AudioClip/music\"). .meta + 파일 헤더 sniff + filename_signals를 종합하여 indexer가 결정. 결정 불가시 필드 자체 생략 (CRIT-IDX6)."
    }
  }
}
```

## Asset Record — normal

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "unity-asset-skills/asset-record.normal.json",
  "title": "Asset Record — normal",
  "description": "normal tier = minimal 7 필드 + 5 필드 (size, dependencies, package_id, last_modified, llm_use_cases). unity-assets.yml::index_depth=normal 일 때 사용.",
  "type": "object",
  "required": [
    "guid",
    "path",
    "name",
    "type",
    "labels",
    "llm_tags",
    "llm_summary",
    "size",
    "dependencies",
    "package_id",
    "last_modified",
    "llm_use_cases"
  ],
  "additionalProperties": false,
  "properties": {
    "guid": {"type": "string", "description": "Unity asset GUID."},
    "path": {"type": "string", "description": "프로젝트 루트 기준 상대 경로."},
    "name": {"type": "string", "description": "에셋 표시 이름."},
    "type": {"type": "string", "description": "Unity 에셋 타입."},
    "labels": {"type": "array", "items": {"type": "string"}, "description": "Unity AssetLabels."},
    "llm_tags": {"type": "array", "items": {"type": "string"}, "description": "asset-tagger 의미 태그."},
    "llm_summary": {"type": "string", "description": "asset-tagger 한 줄 요약 (한글)."},
    "size": {
      "type": "integer",
      "minimum": 0,
      "description": "에셋 파일 크기 (bytes)."
    },
    "dependencies": {
      "type": "array",
      "items": {"type": "string"},
      "description": "이 에셋이 참조하는 다른 에셋의 GUID 목록. .meta 파일 또는 직렬화된 YAML에서 추출."
    },
    "package_id": {
      "type": "string",
      "description": "이 에셋이 속한 패키지 ID (packages.jsonl의 package_id와 join)."
    },
    "last_modified": {
      "type": "string",
      "format": "date-time",
      "description": "ISO-8601 타임스탬프 (파일 mtime)."
    },
    "llm_use_cases": {
      "type": "array",
      "items": {"type": "string"},
      "description": "asset-tagger가 추론한 대표 사용 케이스 (한글 문장)."
    }
  }
}
```

## Asset Record — rich

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "unity-asset-skills/asset-record.rich.json",
  "title": "Asset Record — rich",
  "description": "rich tier = normal 12 필드 + 타입-discriminated extras. Prefab/Material/Animator 등 자주 쓰는 타입에 한해 신규 필드를 정의하며, 그 외 타입은 free-form `extras` 객체를 허용한다. type discriminator로 검증한다. unity-assets.yml::index_depth=rich 일 때 사용. 비-완전(non-exhaustive) 스키마 — 새 타입 추가 시 oneOf branch를 늘린다.",
  "type": "object",
  "required": [
    "guid",
    "path",
    "name",
    "type",
    "labels",
    "llm_tags",
    "llm_summary",
    "size",
    "dependencies",
    "package_id",
    "last_modified",
    "llm_use_cases"
  ],
  "properties": {
    "guid": {"type": "string"},
    "path": {"type": "string"},
    "name": {"type": "string"},
    "type": {"type": "string"},
    "labels": {"type": "array", "items": {"type": "string"}},
    "llm_tags": {"type": "array", "items": {"type": "string"}},
    "llm_summary": {"type": "string"},
    "size": {"type": "integer", "minimum": 0},
    "dependencies": {"type": "array", "items": {"type": "string"}},
    "package_id": {"type": "string"},
    "last_modified": {"type": "string", "format": "date-time"},
    "llm_use_cases": {"type": "array", "items": {"type": "string"}},
    "component_types": {
      "type": "array",
      "items": {"type": "string"},
      "description": "Prefab 한정: 루트 GameObject가 가진 Component 타입 이름 목록. 예: [\"Transform\", \"MeshRenderer\", \"BoxCollider\"]"
    },
    "shader_props": {
      "type": "object",
      "additionalProperties": true,
      "description": "Material 한정: shader property key → value 매핑 (free-form). 텍스처 참조·색·float 등."
    },
    "animator_states": {
      "type": "array",
      "items": {"type": "string"},
      "description": "Animator / AnimatorController 한정: 상태 이름 목록."
    },
    "extras": {
      "type": "object",
      "additionalProperties": true,
      "description": "그 외 타입의 free-form 확장 필드. 신규 필수 키 추가 금지 (스키마 안정성)."
    }
  },
  "allOf": [
    {
      "if": {"properties": {"type": {"const": "Prefab"}}},
      "then": {"required": ["component_types"]}
    },
    {
      "if": {"properties": {"type": {"const": "Material"}}},
      "then": {"required": ["shader_props"]}
    },
    {
      "if": {"properties": {"type": {"const": "Animator"}}},
      "then": {"required": ["animator_states"]}
    },
    {
      "if": {"properties": {"type": {"const": "AnimatorController"}}},
      "then": {"required": ["animator_states"]}
    }
  ]
}
```

---

## 5. `unity-assets.yml` 키 및 기본값

`examples/unity-assets.yml`을 대상 프로젝트의 `.claude/unity-assets.yml`로 복사하여 사용한다. 모든 키는 선택 — 미지정 시 기본값.

| 키 | 타입 | 기본값 | 설명 |
|-----|------|--------|------|
| `index_depth` | enum | `minimal` | `minimal` / `normal` / `rich` 중 하나. 스키마 tier 선택. |
| `confidence_threshold.auto` | number 0..1 | `0.70` | `max(confidence) >= auto` → Orchestrator 자동 적용. |
| `confidence_threshold.confirm` | number 0..1 | `0.40` | `max(confidence) >= confirm` → 사용자 확인 분기. |
| `batch_size` | integer | `20` | asset-tagger subagent 한 개가 받는 에셋 수. |
| `parallel_subagents` | integer | `10` | 한 wave에 동시 띄울 subagent 수. |
| `max_assets_in_context` | integer | `500` | Search 단일 호출이 컨텍스트에 받아들이는 최대 row 수. |
| `ignore_paths` | string[] | `["Assets/Plugins/Editor"]` | Indexer가 스킵할 디렉터리 prefix. |
| `safety_mode` | enum | `loose` | `loose` / `balanced` / `strict`. V1에서는 `loose`만 의미 있음. |

---

## 6. cross-skill 파일 계약

| 파일 | 쓰는 스킬 | 읽는 스킬 | 비고 |
|------|----------|-----------|------|
| `manifest.json` | `:index` | `:index`, `:search`, `:build`, `:doctor` | `{version, last_run, schema_tier}`. version은 `^v\d+\.\d+$` regex. |
| `packages.jsonl` | `:index` (파생) | `:search` | package-first drill-down 1단계 입력. |
| `assets.jsonl` | `:index` | `:search` | tier에 따라 schemas/asset-record.<tier>.json 준수. |
| `state.json` | `:index` | `:index`, `:search` (mtime/version 비교) | R1 in_progress_run / completed_batches 포함. |
| `search-result.json` | `:search` | `:build` | manifest_version 필드 (regex `^v\d+\.\d+$`) 포함. |
| `orchestrator-audit.jsonl` | `:build` (append) | `:build` post-run 검증, `tests/unit/test-scope-guard.ps1` | append-only, 한 줄당 한 호출. |
| `feedback.jsonl` | `:pick` (append) | `:search` Step 4.0.5 (Past picks hint), `:doctor` 검사 5 | append-only, 락 + Add-Content. 행 스키마 `schemas/feedback-row.json.schema.json`. §2.5 예외 규약. Wave 2 신규. |
| `<unity-project>/.claude/unity-assets.yml` | 사용자 | 모든 스킬 | 선택 — 미지정 시 examples/unity-assets.yml의 기본값. |

### 6.1 manifest_version 핸드셰이크

- `search-result.json::manifest_version`은 Search 작성 시점의 `manifest.json::version`을 그대로 복사한다.
- Orchestrator 소비 시:
  - `manifest.json::version != search-result.json::manifest_version` → 거부 사유 `stale_search`. Search 자동 재실행 후에도 불일치면 사용자에게 안내 후 중단.
  - 파일 부재 또는 `manifest_version` 누락 → `stale_search`와 동일하게 취급.

### 6.2 labels 우선순위 (Wave 1 B2, CRIT-IDX7)

`assets.jsonl` 한 행의 `labels` 필드는 세 source의 union이다. 충돌 시 다음 우선순위로 보존한다.

```
unity-assets.labels.yml  >  .meta labels  >  llm_tags
```

- **1순위 — `<unity-project>/.claude/unity-assets.labels.yml`** (CRIT-IDX7): 프로젝트 큐레이터가 작성한 glob → 라벨 매핑. 스키마는 `schemas/curated-labels.json.schema.json` 준수. 예시는 `docs/samples/unity-assets.labels.example.yml`. indexer는 asset path를 정의 순서대로 첫 매칭만 적용.
- **2순위 — `.meta` AssetLabels**: Unity Editor가 부여한 표준 라벨.
- **3순위 — asset-tagger `llm_tags`**: subagent가 생성한 의미 태그. 단, `unity-assets.labels.yml`이나 `.meta`와 동일 키 충돌 시 1·2순위 라벨이 보존되며 llm_tags는 union에 흡수만 된다 (덮어쓰기 금지).

**Brownfield 공시**: 사용자가 기존 인덱스 위에 `unity-assets.labels.yml`을 신규 추가하면, 다음 `/unity-assets:index` 실행에서 해당 glob 매칭 행의 `assets.jsonl::labels`가 union 결과로 shift한다. indexer는 union 적용 전·후의 labels differential을 stdout에 로그하여 brownfield breaking change 가시성을 확보한다 (Risk R5 mitigation).

---

## 7. Search reasoning 풀-피델리티 규칙

`search-result.json::groups[].candidates[].reasoning`은:

- `required: true`, `type: string`, `minLength: 1`.
- **maxLength 없음**. Search subagent가 생성한 추론 텍스트를 1바이트도 절단하지 말고 그대로 직렬화.
- 요약·재작성 금지. 후속 retrieval·debugging·Orchestrator UX(사용자 확인 분기에서 화면에 표시)에서 필요하다.

CRIT-ORC4 (Search → Orch 계약)가 본 규칙을 검증한다.

### 7.1 Search routing 보강 (Wave 1)

`/unity-assets:search` 1차 라우팅 단계(`skills/unity-assets-search/SKILL.md` Step 4)는 다음 세 추가 규약을 따른다 — plan v6 Wave 1 search uplift 산출물.

- **Alias hint workflow (CRIT-SCH5, Step 4.0)**: raw 사용자 쿼리에서 한글 token을 추출하여 `data/aliases.yml`을 lookup. 매칭된 한↔영 alias 쌍을 routing prompt에 `--- Aliases hint ---` 섹션으로 첨부하고, 라우팅 출력의 `sub_intents[].category_hint`에 alias 매칭 결과를 반영한다.
- **`subtype_hint` 필터 메커닉 (CRIT-SCH6)**: `schemas/search-routing.json.schema.json::sub_intents[].subtype_hint`는 `type_subtype`과 동일한 정규식 패턴(`^[A-Za-z]+/[a-z0-9-]+$`, 예 `Sprite/ui`). Step 5.1.4 retrieval은 `subtype_hint`가 주어지면 `assets.jsonl` 행의 `type_subtype`이 정확히 일치하는 후보만 1차 고려하고, 일치 후보가 K 미만이면 같은 `type`의 다른 subtype을 차순위로 보강한다.
- **3-stage fallback 마커 (CRIT-SCH7, Step 5.3)**: Step 5.1 또는 5.2 완료 후 max confidence < 0.40이면 (1) top-K 확장 → (2) map-reduce 강제 → (3) `search-result.json::status = "no_match"` + `suggested_action = "reindex"` 순으로 진입. 각 단계 진입 시 stdout에 정해진 마커 로그 1회 emit (`fallback stage 1 / 2 / 3`). 단계 1·2에서 confidence ≥ 0.40 후보가 발견되면 즉시 정상 결과로 종료.

---

## 8. unity-mcp-skill 위임 규칙

본 플러그인은 Unity Editor와 직접 통신하지 않는다. 두 외부 의존성을 통해 호출한다.

- **MCP for Unity** (https://github.com/CoplayDev/unity-mcp): 실제 MCP 서버. 도구 surface (`manage_scene`, `manage_gameobject`, `manage_prefabs`, `manage_assets`, `create_script`, `script_apply_edits`, `read_console`, `manage_camera` 등)를 제공.
- **`unity-mcp-skill`** (글로벌 Claude Code skill): MCP 도구 사용 가이드.
  - 디스크 폴더: `~/.claude/skills/unity-mcp-skill/`
  - SKILL.md의 `name:` 값: `unity-mcp-orchestrator`
  - 본 문서 텍스트는 폴더명 `unity-mcp-skill`로 참조하고, 런타임 호출은 `Skill(skill="unity-mcp-orchestrator", ...)` 형식.

Indexer deep-fetch, Orchestrator scene/prefab 조작은 모두 `unity-mcp-orchestrator` 스킬에 위임한다. 직접 MCP 도구 호출 금지 (가이드를 우회하면 안전 규칙 미적용).

---

## 9. Orchestrator preflight + R3 안내

`/unity-assets:build`가 호출되면 Orchestrator는 다음 preflight를 수행한다.

1. `<unity-project>/.claude/unity-asset-index/search-result.json` 존재 확인.
2. 존재 시 `manifest_version`을 `manifest.json::version`과 비교.
3. 파일 mtime을 `state.json::last_run`과 비교.

다음 중 하나라도 해당하면 **신선하지 않음**으로 판단:
- 파일 부재
- `manifest_version` 누락 또는 불일치
- mtime이 `state.json::last_run`보다 오래됨

신선하지 않은 경우, Orchestrator는 **subagent fan-out 전에** stdout에 정확히 다음 한 줄을 출력한 후 사용자 원본 자연어 입력으로 `/unity-assets:search`를 자동 호출한다.

```
[unity-assets:build] No fresh search-result.json — running :search first (Ctrl+C to abort).
```

이 한 줄이 사용자에게 abort 창을 보장하며 CRIT-EE1을 진정한 "1명의 입력으로 성공"하는 단일-입력 흐름으로 만든다. 이 줄의 정확한 텍스트(괄호·점·하이픈 포함)는 `tests/e2e/test-ee1-zombie-survival.ps1`이 string match로 단언하므로 변경 금지.

재-Search 후에도 `manifest_version` 불일치가 감지되면 사유 코드 `stale_search`로 거부하고 사용자에게 `/unity-assets:reindex` 권고를 출력한다.

---

## 10. Orchestrator scope enforcement (이중 layer)

Orchestrator는 다음 두 layer를 모두 적용한다.

### 10.1 Layer 1 — prompt-level 금지 튜플

Orchestrator subagent prompt에 다음 금지 튜플 목록을 명시적으로 임베드한다:

- `(AssetDatabase, Delete)`
- `(AssetDatabase, MoveAsset)`
- `(Editor, EnvSettings)`
- `(Build, *)` — 모든 build/player 설정

subagent는 위 튜플 중 하나를 만드는 계획 단계를 거부하고 `scope_violation`을 emit한다.

명세서 350~356행의 MCP for Unity 도구 면 매핑:
- `manage_assets(action="delete")`, `manage_assets(action="move")`, `manage_assets(action="rename")`
- `manage_editor` 의 환경설정 변경 액션
- `manage_build` 전체
- `execute_menu_item` 중 `File/Build*` 등 위험 메뉴
- `manage_packages(action="remove_package")`

### 10.2 Layer 2 — audit-level

모든 unity-mcp 호출은 한 줄 JSON으로 `orchestrator-audit.jsonl`에 append된다. 행 스키마(권장):

```json
{"ts":"2026-05-23T10:11:12Z","sub_intent":"...","tool":"manage_scene","action":"set_active","args_digest":"sha256:..."}
```

`tests/unit/test-scope-guard.ps1`이 실행 후 audit 로그를 스캔하여 금지 튜플 0건을 단언한다. 두 layer는 보완 관계 — prompt가 우회되어도 audit이 캡처한다.

`.meta direct edit`는 MCP for Unity 도구 면에 부재하므로 금지 튜플에서 **제거**되었다 (v3 R1, Architect iteration 1 findings).

---

## 11. 평가 지표 (Wave 2 metrics infra)

Wave 2 metrics infra(plan `/.omc/plans/wave2-metrics-infra.md`)가 추가한 평가 인프라.

### 11.1 측정 지표

- **Recall@3** (CRIT-SCH1, Wave 1 강화): 골든 쿼리(`tests/golden-queries.yml::sch1_recall`, 31개)에서 `expected_golden_id`가 fake-search top-3에 있는지의 비율. by_category(`character/environment/audio/ui/scriptable_object` 5종) 분해 포함. `_last-run.json::crit-sch1.by_category` 기록.
- **Precision@3** (CRIT-EVAL2, Wave 2 신규): 같은 쿼리에서 `top-3 ∩ expected_relevant_ids` 크기를 3으로 나눈 평균. by_category 분해 포함. `_last-run.json::crit-eval2` 기록. 임계치 overall ≥ 0.50, 카테고리 ≥ 0.40.
- **누적 사용자 선택**: `<unity-project>/.claude/unity-asset-index/feedback.jsonl` (CRIT-EVAL3, §2.5). `/unity-assets:pick`이 1줄씩 append. 다음 `/unity-assets:search`의 routing prompt가 "Past picks hint" 블록으로 활용.

### 11.2 골든셋 카테고리 분포 규약

`tests/golden-queries.yml::sch1_recall`은 5개 카테고리 각각 ≥ 6 쿼리 보유. `expected_relevant_ids` 다중 라벨링(1~5개)으로 Precision@3 측정. `docs/golden-set-labeling.md` 라벨링 가이드 참조.

### 11.3 A/B harness 사용

```powershell
.\tests\harness\run-ab.ps1 `
  -VariantA <path-to-aliases-A.yml> `
  -VariantB <path-to-aliases-B.yml> `
  -Seed 42 `
  -Out tests\_ab-result.json
```

`tests/harness/fake-search-runner.ps1`이 결정적이라 동일 seed → byte-identical 재현 가능 (CRIT-EVAL4). 결과는 `tests/_ab-result.json.schema.json` 준수. 변형 가능 차원은 aliases.yml(현재 지원). taxonomy / SKILL.md routing prompt / filename conventions는 향후 fake-search-runner가 추가로 읽도록 확장 가능.

---

## 12. 변경 통제

- 본 문서는 v0.1.0 lock 상태이며, plan v6 + Wave 1/2 plan과 동기화한다.
- per-tier 필드 deltas (섹션 4) 변경 시 `schemas/asset-record.<tier>.json` 동시 수정 필수 (CRIT-CNV1 lint가 PASS여야 함).
- R3 안내 문구(섹션 9)는 `tests/e2e/test-ee1-zombie-survival.ps1`이 string match로 검증하므로 한 글자도 변경하지 않는다.
- 금지 튜플(섹션 10.1) 변경 시 `tests/unit/test-scope-guard.ps1`의 단언 목록도 동시 수정.
- §2.5(feedback.jsonl) 또는 §11(평가 지표) 규약 변경 시 `tests/unit/test-pick-command.ps1`, `tests/unit/test-feedback-jsonl.ps1`, `tests/unit/test-precision-at-3.ps1`, `tests/unit/test-ab-harness.ps1` 단언이 동시에 통과해야 한다.

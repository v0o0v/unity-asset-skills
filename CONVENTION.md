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
│   ├── unity-assets-index/SKILL.md
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
│   └── search-result.json.schema.json
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

---

## 3. schema-doc-sync 계약 (CRIT-CNV1)

`lint/lint-schema-doc-sync.ps1`은 다음 규약대로 본 문서를 파싱한다.

- 헤더 `## Asset Record — minimal`, `## Asset Record — normal`, `## Asset Record — rich` 각각 아래 첫 번째 ` ```json ... ``` ` fenced 블록을 추출.
- 추출한 JSON을 `schemas/asset-record.<tier>.json`과 byte-by-byte diff (단, JSON canonicalize 후).
- 0 diff면 PASS, 아니면 FAIL.

헤더 텍스트(em-dash `—` 포함)·블록 펜스 표기를 변경하면 lint가 깨진다. 신규 tier 추가 시 동일 패턴으로 헤더+블록을 함께 추가하고 schemas/에 파일도 만든다.

---

## 4. Asset Record per-tier 필드 deltas

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
| `<unity-project>/.claude/unity-assets.yml` | 사용자 | 모든 스킬 | 선택 — 미지정 시 examples/unity-assets.yml의 기본값. |

### 6.1 manifest_version 핸드셰이크

- `search-result.json::manifest_version`은 Search 작성 시점의 `manifest.json::version`을 그대로 복사한다.
- Orchestrator 소비 시:
  - `manifest.json::version != search-result.json::manifest_version` → 거부 사유 `stale_search`. Search 자동 재실행 후에도 불일치면 사용자에게 안내 후 중단.
  - 파일 부재 또는 `manifest_version` 누락 → `stale_search`와 동일하게 취급.

---

## 7. Search reasoning 풀-피델리티 규칙

`search-result.json::groups[].candidates[].reasoning`은:

- `required: true`, `type: string`, `minLength: 1`.
- **maxLength 없음**. Search subagent가 생성한 추론 텍스트를 1바이트도 절단하지 말고 그대로 직렬화.
- 요약·재작성 금지. 후속 retrieval·debugging·Orchestrator UX(사용자 확인 분기에서 화면에 표시)에서 필요하다.

CRIT-ORC4 (Search → Orch 계약)가 본 규칙을 검증한다.

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

## 11. 변경 통제

- 본 문서는 v0.1.0 lock 상태이며, plan v6와 1:1 동기화한다.
- per-tier 필드 deltas (섹션 4) 변경 시 `schemas/asset-record.<tier>.json` 동시 수정 필수 (CRIT-CNV1 lint가 PASS여야 함).
- R3 안내 문구(섹션 9)는 `tests/e2e/test-ee1-zombie-survival.ps1`이 string match로 검증하므로 한 글자도 변경하지 않는다.
- 금지 튜플(섹션 10.1) 변경 시 `tests/unit/test-scope-guard.ps1`의 단언 목록도 동시 수정.

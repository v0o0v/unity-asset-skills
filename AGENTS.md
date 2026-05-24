# AGENTS.md — 내부 개발자 가이드

본 문서는 `unity-asset-skills` 플러그인의 내부 컨벤션·환경 가정·subagent 호출 형식을 정리한다. 사용자용 안내는 [README.md](./README.md), 파일·스키마 계약은 [CONVENTION.md](./CONVENTION.md)를 참조한다.

---

## 1. 개요

`unity-asset-skills`는 Unity 프로젝트의 기설치 에셋을 Claude Code 세션 안에서 인덱싱하고 자연어로 검색·조립하는 글로벌 Claude Code 플러그인이다. **6개 슬래시 커맨드** (Wave 2에서 `:pick`을 별도 스킬로 분리, 후속에서 `:reindex`를 alias 스킬로 분리)를 제공한다.

| 커맨드 | 역할 |
|--------|------|
| `/unity-assets:index` | 증분 인덱싱. `state.json::guid_signatures` 비교로 변경 셋만 재태깅. asset-tagger subagent fan-out. |
| `/unity-assets:reindex` | 강제 full 재인덱싱. `state.json` 무시, 모든 `.meta` 재태깅. index와 동일 절차 + Step 2 force 분기 (alias 스킬). |
| `/unity-assets:search` | LLM-as-Search dual-call (라우팅 → sub-intent별 retrieval). Wave 2 Step 4.0.5 "Past picks hint" 활용. |
| `/unity-assets:pick <row-index>` (Wave 2 신규) | Search 결과 1개 선택, `feedback.jsonl`에 한 줄 append. 학습 데이터 누적. |
| `/unity-assets:build` | Confidence-gated Orchestrator. R3 preflight + 이중 scope enforcement. |
| `/unity-assets:doctor` | 6개 항목 read-only 헬스체크 (Wave 2에서 feedback.jsonl 행 스키마 검사 추가, 후속에서 stale `_tmp/` 감지 검사 6 추가). |

---

## 2. 파일 트리 (배포 산출물)

```
unity-asset-skills/
├── .claude-plugin/plugin.json         # Claude Code 공식 매니페스트 위치 (Step 0 확인 결과 반영)
├── README.md
├── CONVENTION.md
├── AGENTS.md
├── agents/asset-tagger.md
├── skills/{unity-assets-index,unity-assets-search,unity-assets-pick,unity-assets-build,unity-assets-doctor}/SKILL.md
├── skills/unity-assets-index/prompts/subagent-tagger.md
├── schemas/{asset-record.minimal,asset-record.normal,asset-record.rich,package-record,state.json.schema,search-routing.json.schema,search-result.json.schema,curated-labels.json.schema,feedback-row.json.schema}.json
├── data/{aliases.yml, aliases.json.schema.json, type-taxonomy.yml}
├── docs/{dev-loop.md, golden-set-labeling.md, samples/}
├── examples/unity-assets.yml
└── tests/{README.md, run-crit-suite.ps1, _ab-result.json.schema.json, fixtures/, golden-queries.yml, unit/, harness/{run-ab,fake-search-runner}.ps1, lint/, e2e/}
```

---

## 3. 의존성 및 호출 컨벤션 (Step 0 환경 확인 결과)

### 3.1 Claude Code plugin-defined subagent 등록 메커니즘

**확인 결과 (2026-05-23, 본 구현 환경)**: Claude Code 공식 플러그인 (`~/.claude/plugins/marketplaces/claude-plugins-official/plugins/feature-dev/agents/code-architect.md` 등)이 다음 YAML frontmatter 형식으로 `agents/<name>.md` 파일을 등록한다:

```yaml
---
name: <subagent-name>
description: <short description>
tools: Glob, Grep, LS, Read, NotebookRead, WebFetch, TodoWrite, WebSearch, KillShell, BashOutput
model: sonnet
color: green
---

<system prompt body>
```

본 플러그인의 `agents/asset-tagger.md`는 이 형식을 따른다. `tools` 항목은 Read만 지정 (pure analyzer 제약).

**plugin.json의 agents 필드**: 관찰한 플러그인들(feature-dev, plugin-dev, oh-my-claudecode)의 `.claude-plugin/plugin.json`은 `agents` 필드를 명시 등록하지 않는다 — `agents/` 디렉터리가 자동 탐색되는 것으로 추정. 본 플러그인의 `plugin.json`도 동일하게 `agents` 필드를 생략한다.

**plugin.json 매니페스트 위치 (plan v6 vs Claude Code 실제 spec)**: plan v6의 Repository Layout은 `unity-asset-skills/plugin.json`(루트)으로 표기했으나, Claude Code 기설치 플러그인(claude-plugins-official/*, oh-my-claudecode)은 예외 없이 `unity-asset-skills/.claude-plugin/plugin.json` 위치를 사용한다. 그 위치에 두지 않으면 Claude Code가 매니페스트를 발견하지 못한다. 본 플러그인은 실제 spec을 따라 `.claude-plugin/plugin.json`에 배치했다 (핸드오프 브리프 "단순 typo·번역 오류 인라인 수정 OK" + Step 0 환경 확인 결과 적용).

**plugin.json::name vs 슬래시 커맨드 namespace**: 동일하게 관찰한 결과, Claude Code의 슬래시 커맨드 prefix는 `plugin.json::name` 필드를 그대로 사용한다 (예: `name: "oh-my-claudecode"` → `/oh-my-claudecode:*`). plan v6의 슬래시 커맨드 사양은 `/unity-assets:*`이므로 plugin.json의 `name`을 `unity-assets`로 설정했다. 디렉터리·repo 이름은 plan에 따라 `unity-asset-skills` 유지 (디스크·git 경로와 슬래시 namespace는 다를 수 있음). 이 결정은 CRIT-CNV2 lint가 슬래시 커맨드 등록 가능성을 검증할 때 핵심.

**Fallback 채택 여부**: plugin-defined agent 등록 자체는 다른 플러그인에서 발견되므로 **fallback을 사용하지 않는다**. 즉 Indexer는 `Task(subagent_type="unity-asset-skills:asset-tagger", model="haiku")` 형식으로 호출한다. 만약 런타임에 등록이 동작하지 않으면 `prompts/subagent-tagger.md` 본문을 그대로 `general-purpose` subagent에 prompt로 전달하는 fallback을 적용한다 (asset-tagger.md 본문의 "Fallback 표기" 참조).

### 3.2 외부 의존성 disambiguation

본 플러그인이 동작하려면 다음 두 가지가 사용자 환경에 사전 설치되어 있어야 한다.

| 항목 | 종류 | 디스크 위치 | 호출명 | 역할 |
|------|------|------------|--------|------|
| **MCP for Unity** | Unity 패키지 + Python MCP 서버 | Unity 프로젝트의 `Packages/manifest.json` 의존 + Python `uv` 환경 | MCP 도구 prefix `mcp__manage_scene` 등 | Unity Editor와의 실제 통신 |
| **unity-mcp-skill** | Claude Code 글로벌 skill | `~/.claude/skills/unity-mcp-skill/SKILL.md` | `Skill(skill="unity-mcp-orchestrator", ...)` | 위 MCP 도구 사용 가이드 (best practice·툴 스키마·워크플로 패턴) |

**확인 결과 (2026-05-23)**: `~/.claude/skills/unity-mcp-skill/SKILL.md`의 YAML frontmatter `name:` 필드 값은 `unity-mcp-orchestrator`. 본 플러그인 모든 문서는 폴더명 `unity-mcp-skill`로 표기하고 호출 시 `unity-mcp-orchestrator`를 사용한다. 둘은 동일 의존성을 가리킨다 (혼동 방지).

본 작업에서 두 의존성 어느 쪽도 설치 시도하지 않는다. README의 사전 조건 섹션이 사용자 설치를 안내한다. `/unity-assets:doctor`가 런타임에 두 의존성의 가용성을 read-only로 검사한다.

---

## 4. subagent 호출 형식

### 4.1 1급 형식 (plugin-defined agent 사용)

```
Task(
  subagent_type="unity-asset-skills:asset-tagger",
  model="haiku",
  prompt="<batch input — 프로젝트 루트, 에셋 경로 목록, batch_id, .meta 경로>"
)
```

Indexer (`skills/unity-assets-index/SKILL.md`), Indexer의 재시도 로직, `tests/unit/test-subagent-recovery.ps1`이 모두 이 형식을 사용한다.

### 4.2 Fallback 형식 (등록 미동작 시)

```
Task(
  subagent_type="general-purpose",
  model="haiku",
  prompt="<prompts/subagent-tagger.md 본문 전체 + batch 입력>"
)
```

Fallback 채택 시 AGENTS.md 섹션 3.1을 갱신하여 그 사실을 기록한다.

### 4.3 Search/Orchestrator 라우팅 subagent

Search 1차 라우팅·Orchestrator 계획 단계는 asset-tagger가 아닌 일반 분석 subagent를 사용한다. 본 플러그인은 자체 등록하지 않고 Claude Code 내장 `general-purpose` (또는 호출 컨텍스트가 그 시점에 다른 적합한 agent를 제공하면 그것)에 위임한다. SKILL.md 본문이 정확한 instructions를 prompt로 전달한다.

---

## 5. 외부 의존성 호출 매핑

본 플러그인이 사용하는 MCP for Unity 도구 (CoplayDev/unity-mcp v9.6.x 시점):

| 사용 시점 | MCP 도구 |
|-----------|----------|
| Indexer deep-fetch (메타데이터 보강) | `manage_assets` (조회 액션), `find_gameobjects`, `unity_reflect` |
| Orchestrator scene 조작 | `manage_scene`, `manage_gameobject`, `find_gameobjects` |
| Orchestrator prefab 생성·인스턴스화 | `manage_prefabs`, `manage_gameobject` |
| Orchestrator ScriptableObject·스크립트 생성 | `create_script`, `script_apply_edits`, `validate_script`, `manage_assets`(create) |
| Orchestrator 머티리얼·셰이더 적용 | `manage_assets`, `manage_graphics` |
| 검증·확인 | `read_console`, `manage_camera`(screenshot) |
| Doctor 헬스체크 (read-only) | `manage_scene` 또는 동등 read 액션 (한 번 호출하여 응답 받음 여부 검사) |

호출은 항상 `unity-mcp-orchestrator` 스킬을 경유한다. 직접 MCP 도구 호출 금지.

---

## 6. 한글 본문 규칙

모든 산출 문서(README.md, CONVENTION.md, AGENTS.md, SKILL.md 본문, tests/README.md, fixtures/README.md)는 **한글 본문**으로 작성한다.

번역하지 않는 항목:
- 코드 식별자·심볼 (`subagent_type`, `manifest_version`, `in_progress_run`, `batch_id`)
- 명령어·파일 경로 (`Task(subagent_type=...)`, `/unity-assets:index`, `assets.jsonl`)
- 라이브러리·기술명 (Unity, prefab, ScriptableObject, MCP, Claude Code, OpenUPM, UPM)
- 라벨·코드 ID (CRIT-EE1, OQ#1, R1/R2/R3, ADR-*)
- 검증 시 정확히 매칭돼야 하는 stdout 문자열·테스트 fixture 안의 영문 문자열 (특히 R3 안내 줄)

---

## 7. Windows-only 규약

- 모든 PowerShell 스크립트는 `.ps1` 단일 형식. `.sh` 미러 생성 금지.
- 경로 표기는 `C:\...`, `D:\...`, `~\.claude\...` 형식 사용 (forward slash는 코드 식별자·URL·JSON에 한정).
- 사용자 안내는 PowerShell 블록으로 작성 (bash 블록 0).
- macOS / Linux 분기 코드 0. 추후 V2에서 OS 추상화 검토.

---

## 8. 후속 worker (Wave 2)가 알아야 할 것들

다음 worker는 본 디렉터리의 다음 파일을 진실원으로 참조한다.

| 자료 | 위치 | 용도 |
|------|------|------|
| Asset Record 스키마 (3 tier) | `schemas/asset-record.{minimal,normal,rich}.json` | 인덱싱 출력 검증, CONVENTION.md 동기 (CRIT-CNV1) |
| Package Record 스키마 | `schemas/package-record.json` | packages.jsonl 행 검증 |
| state.json 스키마 (R1 포함) | `schemas/state.json.schema.json` | Indexer 진행·재개 상태 검증 |
| Search 출력 스키마 (라우팅 + 결과) | `schemas/search-routing.json.schema.json`, `schemas/search-result.json.schema.json` | Search dual-call 계약, CRIT-ORC4 |
| 파일 atomic 계약 | `CONVENTION.md` §2 | 모든 산출 파일 |
| schema-doc-sync 규약 | `CONVENTION.md` §3 | CRIT-CNV1 lint 파서 |
| manifest_version 핸드셰이크 | `CONVENTION.md` §6.1 | Orchestrator stale_search |
| R3 안내 문구 (정확한 텍스트) | `CONVENTION.md` §9 | CRIT-EE1 string match |
| 금지 튜플 목록 | `CONVENTION.md` §10.1 | CRIT-ORC3 prompt + audit |
| 기본값 잠금 | `examples/unity-assets.yml` | CRIT-CNV4 외 모든 CRIT-* fixture에 복사 |

Wave 2의 4개 worker는 각자 자기 범위만 작성하고, 본 디렉터리의 schemas·CONVENTION을 변경하지 않는다. 발견된 수정 사항은 변경 제안을 명시하고 메인 orchestrator(이 세션의 lead)가 통합 처리한다.

---

## 9. 진전된 CRIT-*

Wave 1이 진전시킨 CRIT-*:

- **CRIT-CNV1 (Schema-doc sync)**: schemas/ 7 파일 + CONVENTION.md fenced JSON 블록 3종 작성. lint 스크립트 `tests/lint/lint-schema-doc-sync.ps1` 실재.
- **CRIT-CNV2 (Plugin manifest)**: `.claude-plugin/plugin.json` 작성 (CLI 공식 플러그인 형식 준수). lint 스크립트 `tests/lint/lint-plugin-manifest.ps1` 실재. Wave 2에서 5개 스킬로 확장 갱신.
- **CRIT-CNV3 (Cross-skill 계약)**: schemas/ + CONVENTION.md §6에서 누가-무엇을-쓰고-읽는지 명시. e2e 검증 `tests/unit/test-cross-skill-contract.ps1` 실재.
- **CRIT-CNV4 (.yml override)**: examples/unity-assets.yml 기본값 잠금. 변형 테스트 `tests/unit/test-yml-override.ps1` 실재.
- **CRIT-DOC1 (Doctor 진단)**: doctor 4개 검사 항목 명세 (README 진단 표). SKILL.md + fixture + test 모두 실재. Wave 2에서 5번째 검사(feedback.jsonl) 추가됨.
- **OQ#1, OQ#6, OQ#8 해결**: per-tier 필드 deltas / state.json 스키마 R1 / plugin.json 필드 셋.

Wave 2가 진전시킨 CRIT-* (plan: `.omc/plans/wave2-metrics-infra.md`):

- **CRIT-EVAL1 (Golden set integrity)**: 골든 쿼리 31개 (카테고리당 ≥6), 모든 쿼리에 `expected_relevant_ids` 다중 라벨링 추가. `tests/unit/test-golden-set-integrity.ps1`.
- **CRIT-EVAL2 (Precision@3)**: `top-3 ∩ expected_relevant_ids / 3` 평균 측정. `_last-run.json::crit-eval2 = {overall, by_category, n_queries}`. 임계 overall ≥ 0.50, 카테고리 ≥ 0.40. `tests/unit/test-precision-at-3.ps1`.
- **CRIT-SCH8 (/unity-assets:pick 동작)**: row-index lookup + manifest_version 핸드셰이크 + feedback.jsonl atomic append (락 + Add-Content). 정확한 stdout 4종(에러 3 + 성공 1). 새 스킬 `skills/unity-assets-pick/SKILL.md`. `tests/unit/test-pick-command.ps1`.
- **CRIT-EVAL3 (feedback.jsonl 행 스키마)**: `schemas/feedback-row.json.schema.json` 8 필수 필드 (`ts, query, sub_intent_id, picked_guid, candidate_guids, confidence_before, confidence_after, source`). search SKILL.md Step 4.0.5 reader가 corruption 행 skip + 로그 emit. `tests/unit/test-feedback-jsonl.ps1`.
- **CRIT-EVAL4 (A/B harness 결정성)**: `tests/harness/run-ab.ps1`이 두 variant aliases.yml 비교 → `tests/_ab-result.json` 산출. 동일 seed → byte-identical (재현성), 동일 variant → delta 0. `tests/unit/test-ab-harness.ps1`.

CRIT 총계: 기존 18개 + Wave 1 신규 6개 + Wave 2 신규 5개 = **29개** (`pwsh tests/run-crit-suite.ps1`로 일괄 실행).

후속 (Wave 2.5 후보, 별도 plan 권장): 본 표의 "Wave 2D"로 미뤄둔 항목들은 Wave 1·2가 진행되며 자연스럽게 해소되었거나(CNV1/CNV2/CNV3/CNV4 lint 모두 실재) DOC1이 5번째 검사로 자체 확장됨. Wave 2.5는 fault-injection fixture 보강과 실제 Unity Editor 연동 e2e 정도로 좁혀짐.

---

## 10. 양방향 dev loop 워크플로

실제 Unity 프로젝트(`tests/integration/testbed/`)에서 슬래시 커맨드를 시험하면서 동시에 플러그인 자체를 수정·즉시 반영하는 흐름. 두 개의 Claude Code 세션을 동시에 띄운다.

| 윈도우 | cwd | 시작 명령 | 역할 |
|--------|-----|-----------|------|
| **Window A** (plugin dev) | `D:\…\unitySkills` | `claude` (보통 세션) | 소스 편집 (SKILL.md·스키마), testbed 산출물 진단, git commit/push |
| **Window B** (plugin user) | `D:\…\testbed` | `claude --plugin-dir D:\…\unitySkills` | `/unity-assets:*` 시험, 문제 발견 시 A로 보고 |

`--plugin-dir`로 시작하면 본 소스 트리가 그대로 등록되어 **재설치 없이 SKILL.md 수정이 다음 슬래시 호출에 즉시 반영**된다. Window A의 Claude는 testbed의 `.claude/unity-asset-index/` 산출물을 filesystem 공유로 직접 Read하여 진단한다.

진단·디버깅 도구:
- **`tools/diagnose.ps1`** (Window A): testbed의 `.claude/unity-asset-index/` 전체를 `.omc/diagnosis/<ts>/`로 timestamped 스냅샷 + `SUMMARY.md`에 핵심 행 요약 (state·manifest·assets head·packages·search-result 핸드셰이크·audit 금지 튜플·console tail). Claude는 SUMMARY.md 하나만 읽으면 됨.
- **`tools/dump-console.ps1`** (Window B 측 PS): headless `claude -p`로 `mcp__read_console` 호출 → `testbed/.claude/_debug/console.log` 저장. 대안으로 Window B 안에서 한 줄 부탁 ("`mcp__read_console` 호출해서 console.log에 저장해줘").

전체 가이드 + 진단 트리아주 룩업 표 (증상 → 의심 위치 → 수정 후보 12개 항목) + troubleshooting: [docs/dev-loop.md](./docs/dev-loop.md).

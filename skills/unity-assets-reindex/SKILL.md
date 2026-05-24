---
name: reindex
description: Unity 에셋 인덱스를 강제 full mode로 재생성한다. state.json::guid_signatures를 무시하고 모든 .meta를 다시 태깅. /unity-assets:reindex로 호출. 변경 셋·subagent fan-out·atomic 산출·종료 신호 출력 계약은 /unity-assets:index와 동일하며 본 SKILL은 Step 2 force 분기만 강제하는 alias 스킬이다.
---

# /unity-assets:reindex — 강제 full 재인덱싱

## 책임 범위

[skills/unity-assets-index/SKILL.md](../unity-assets-index/SKILL.md)의 절차를 그대로 수행하되, **Step 2 (변경 셋 계산)의 증분 모드 분기를 건너뛰고 full mode를 강제**한다. 다른 모든 단계(Step 1, 1.5, 1.6, 3, 4, 5)는 index SKILL.md와 동일하며 본 SKILL은 단일 alias 역할.

자가 검출 게이트(Step 1.6)·자가 우회 금지(CONVENTION.md §2.6)·종료 신호 출력 계약은 모두 동일하게 적용된다. 본 SKILL이 별도로 정의하는 신규 동작은 Step 2 force 분기 단 하나뿐.

## 호출 패턴

- `/unity-assets:reindex` — 인자 없음. 무조건 full mode.

증분이 필요하면 `/unity-assets:index`를 호출한다. 본 SKILL을 호출했다면 사용자가 명시적으로 전체 재태깅을 요청한 것이므로 R1 복구 분기 또한 건너뛴다 (아래 Step 2 force 참조).

## 사전 조건

`/unity-assets:index`와 동일.

1. cwd가 Unity 프로젝트 루트 (`Assets/` 디렉터리 존재).
2. `.claude/unity-asset-index/` 디렉터리가 없으면 생성.
3. `.claude/unity-assets.yml` 존재하면 로드, 없으면 `examples/unity-assets.yml` 기본값 사용.

## 실행 흐름

### Step 1 — 설정 로드 + state 확인

[index SKILL.md Step 1](../unity-assets-index/SKILL.md)과 동일하게 `unity-assets.yml`·`state.json`을 로드한다. 단 **R1 크래시 복구 분기를 무시**한다 — `assets.jsonl.partial`이 존재해도 orphan으로 폐기하고 정상 경로 진입. (force full 모드의 의미상 이전 진행 상태를 신뢰하지 않음.)

### Step 1.5 — stale 우회 파일 정리

[index SKILL.md Step 1.5](../unity-assets-index/SKILL.md)와 동일. `_tmp/` 디렉터리가 있으면 무조건 폐기.

### Step 1.6 — 자가 검출 게이트 (CRITICAL)

[index SKILL.md Step 1.6](../unity-assets-index/SKILL.md)과 동일하게 적용된다. 모든 도구 호출 직전 화이트리스트/금지 패턴 자가 검사 → 위반 시 즉시 self-abort + `state.json::last_error` 기록 + stdout `error: bypass_attempted at Step <N>` emit.

### Step 2 — 변경 셋 계산 (**force full**)

본 SKILL의 유일한 분기점이다.

1. cwd 하위에서 `.meta` 파일을 모두 Glob (`unity-assets.yml::ignore_paths` prefix 제외). chunked Glob 절차는 index SKILL.md Step 2와 동일.
2. **`state.json::guid_signatures` 비교를 건너뛴다**. 모든 발견된 에셋이 변경 셋.
3. **no-op 경로 진입 금지**. 변경 셋이 0이라도 (이론상 .meta 0개일 때만) 정상 종료하되 stdout은 `no-op: total=0 changed=0` 그대로 emit.
4. **`state.json::pending_batches`도 비운다** — full mode이므로 이전 실패 batch 추적 의미 없음.

증분 모드(`state.json::guid_signatures[guid] != current_signature` 비교)는 본 SKILL에서 절대 적용되지 않는다.

### Step 3~5 — wave 계획 / 실행 / finalize (V0.1.0+3: helper 위임)

[index SKILL.md Step 3, 4, 4.0, 4.0.1, 4.5, 5](../unity-assets-index/SKILL.md)와 byte-identical. 변경 없음.

특히 다음 강제 계약이 본 SKILL에서도 동일하게 enforced:
- **V0.1.0+3 helper 호출**: Step 2 (`GetMetaList`), Step 3 (`PlanBatches`), Step 4.0/4.0.1 (`InitWaveTiming`/`CompleteWaveTiming`), Step 5 (`Finalize`/`CleanupBatches`). batch 분할·wall-clock·wave_timings·finalize 모두 `indexer-helper.ps1`이 deterministic 수행.
- Step 4의 **Task() 직접 호출 강제** + 한 응답 메시지에 K개 tool_use 동시 emit (병렬 위반 자가 검출 시 `warning: wave serialized` stdout).
- Step 4.0/4.0.1의 **wave 시작·끝 stdout 마커** + `state.json::wave_timings` 동기 기록 (helper 호출이 wall-clock 단일 진실원).
- `batch_size = 20`, `parallel_subagents = 10` 기본값 (한 wave 최대 200 에셋).
- PowerShell/Bash 자동화 우회 금지 — `_tmp/setup-batches.ps1`·`_tmp/meta-list.json` 등은 자가 검출 게이트(Step 1.6)가 차단. 단 `indexer-helper.ps1` 호출은 §2.6 예외로 허용.

사용자가 `/unity-assets:reindex`로 호출했더라도 LLM은 `Task()` 병렬 fan-out을 한 응답 메시지에 emit해야 하며, 분할 발행 시 wave가 직렬화되어 시간이 K배가 된다 (실측: 직렬 ~30~46분, helper+병렬 ~6~10분).

## 종료 신호 출력 계약

[index SKILL.md § 종료 신호 출력 계약](../unity-assets-index/SKILL.md)과 동일 5가지 메시지 형태 (성공/no-op/r1-resume/partial/error). 단:

- **r1-resume은 emit하지 않는다** — 본 SKILL은 force full이라 R1 복구 분기를 무시.
- **성공 시 `changed == total`**: full 재태깅이라 변경 셋이 전체와 동일. 사용자가 stdout으로 force 동작을 사후 검증 가능.
- **실패 reason 카탈로그**: index와 동일 7종 (`config_parse_failed` / `glob_failed` / `bypass_attempted` / `subagent_all_timeout` / `wave_zero_progress` / `atomic_rename_failed` / `internal_error`).

## 산출 파일

`/unity-assets:index`와 동일 (CONVENTION.md §1):

- `<unity-project>/.claude/unity-asset-index/manifest.json`
- `<unity-project>/.claude/unity-asset-index/packages.jsonl`
- `<unity-project>/.claude/unity-asset-index/assets.jsonl`
- `<unity-project>/.claude/unity-asset-index/state.json`

CONVENTION.md §2.6 (비공식 임시 파일 금지)의 §1 산출 5종 외 어떤 파일도 작성 금지. `_tmp/`·`meta-list.json`·`setup-batches.ps1`·`batches/` 등 자가 우회 패턴은 본 SKILL에서도 Step 1.6 게이트로 차단된다.

## 사용 시나리오

- 새로 추가된 인덱스 필드(예: `type_subtype`·`filename_signals`)를 기존 assets.jsonl에 채우려 할 때.
- 인덱스 출력 언어 정책 변경(예: 한글 → 영어 llm_summary 일괄 재생성).
- subagent prompt나 taxonomy(`data/type-taxonomy.yml`·`filename-conventions.json`) 변경 후 모든 에셋을 새 규칙으로 재태깅.
- `state.json::guid_signatures`가 손상되어 증분이 신뢰성 없을 때.

## 진전된 CRIT-*

본 SKILL은 별도 CRIT-* 없음. `/unity-assets:index`의 CRIT-IDX1~7과 동일 계약을 force full 경로에서 검증한다.

- **CRIT-IDX1 (Coverage)** — 모든 `.meta`가 assets.jsonl 포함.
- **CRIT-IDX2 (Idempotency)** — force full은 idempotency no-op 경로를 타지 않음. byte-identity 단언은 본 SKILL에 적용되지 않음.
- **CRIT-IDX3 (Incremental accuracy)** — 본 SKILL은 increment 아님이라 단언 제외.
- **CRIT-IDX4 (Subagent + 크래시 복구)** — 60s 타임아웃 동일. R1 복구는 본 SKILL에서 비활성이라 단언 부분 적용.
- **CRIT-IDX5, IDX6, IDX7** — index와 동일하게 적용.

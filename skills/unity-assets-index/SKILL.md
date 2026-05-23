---
name: index
description: Unity 프로젝트의 에셋을 filesystem 1차 스캔 + asset-tagger subagent fan-out으로 2-layer (package + asset) 메타데이터 인덱스로 수집한다. /unity-assets:index (증분) 또는 /unity-assets:reindex (강제 full). 결과는 <unity-project>/.claude/unity-asset-index/ 하위에 atomic 저장. R1 크래시 복구·subagent 60s 타임아웃·wave incremental partial 지원.
---

# /unity-assets:index — Unity 에셋 인덱서

## 책임 범위

Unity 프로젝트 cwd 하위의 `.meta` 파일을 모두 발견하고, `asset-tagger` subagent fan-out으로 의미 태그·요약을 생성하여 `<unity-project>/.claude/unity-asset-index/`에 2-layer 인덱스(packages + assets)를 작성한다. 파일 atomic 계약·R1 크래시 복구·증분 갱신을 모두 준수한다.

CONVENTION.md를 모든 계약(파일 atomic, schema-doc-sync, state.json 스키마)의 진실원으로 참조한다.

## 호출 패턴

- `/unity-assets:index` — 증분. `state.json::guid_signatures` 비교로 변경 셋만 재태깅.
- `/unity-assets:reindex` — 강제 full. `state.json`을 무시하고 모든 에셋을 다시 태깅.

## 사전 조건

1. cwd가 Unity 프로젝트 루트 (`Assets/` 디렉터리 존재).
2. `.claude/unity-asset-index/` 디렉터리가 없으면 생성.
3. `.claude/unity-assets.yml` 존재하면 로드, 없으면 `examples/unity-assets.yml` 기본값 사용.

## 실행 흐름

### Step 1 — 설정 로드 + state 확인

1. `.claude/unity-assets.yml` 로드 (없으면 기본값).
2. `.claude/unity-asset-index/state.json` 읽기 (없으면 빈 state로 시작).
3. **R1 크래시 복구 분기** (CONVENTION.md §2.4):
   - `assets.jsonl.partial` 존재 AND `state.json::in_progress_run == true` → 권위 partial로 재개. `state.json::completed_batches`에 나열된 batch는 skip.
   - `assets.jsonl.partial` 존재 AND `state.json::in_progress_run == false` → orphan으로 폐기, 전체 재실행.
   - `assets.jsonl.partial` 부재 → 정상 경로.

### Step 2 — 변경 셋 계산

1. cwd 하위에서 `.meta` 파일을 모두 Glob (`unity-assets.yml::ignore_paths` prefix 제외).
2. 각 에셋의 시그니처 = `<mtime>:<size>` 계산.
3. **증분 모드** (`/unity-assets:index`):
   - `state.json::guid_signatures[guid] != current_signature` 인 에셋만 변경 셋.
   - `state.json::pending_batches`의 batch도 변경 셋에 합류.
   - 빈 변경 셋이면 **no-op 경로** (CRIT-IDX2): `assets.jsonl`을 byte-for-byte 재사용, `state.json::last_run`만 갱신.
4. **Full 모드** (`/unity-assets:reindex`): 모든 에셋이 변경 셋.

### Step 3 — wave 계획

- N = `len(변경 셋)`, `batch_size = config.batch_size` (기본 20), `parallel_subagents = config.parallel_subagents` (기본 10).
- wave 수 = `ceil(N / (batch_size * parallel_subagents))`.
- 한 wave 안에서 `parallel_subagents` 개의 subagent를 동시 호출, 각각 `batch_size` 개 에셋 처리.

### Step 4 — wave 실행

각 wave 시작 시 `state.json::in_progress_run = true`로 설정 후 atomic rename으로 `state.json` 갱신.

한 wave 안의 subagent 호출 형식 (병렬):

```
Task(
  subagent_type="unity-assets:asset-tagger",
  model="haiku",
  prompt="<batch input — 프로젝트 루트 절대 경로, 처리할 에셋 절대 경로 목록 (batch_size 개), 각 에셋의 .meta 절대 경로, batch_id>"
)
```

**60초 wall-clock 타임아웃**. 타임아웃 시 해당 batch는 `state.json::pending_batches`에 `{batch_id, reason: "subagent_timeout"}`로 기록되고 wave는 살아남은 subagent 결과로 계속 진행 (stall 방지).

각 subagent 반환 JSONL row 처리:
1. `schemas/asset-record.<tier>.json`으로 검증.
2. 검증 통과 row → `assets.jsonl.partial`에 append.
3. 검증 실패 row → `state.json::bad_rows`에 `{guid, reason}` 기록 → 다음 batch에서 재시도.
4. batch 전체 성공 → `state.json::completed_batches`에 `batch_id` 추가.

**Fallback subagent 형식** (AGENTS.md §3.1에서 plugin-defined agent 미동작 시):

```
Task(
  subagent_type="general-purpose",
  model="haiku",
  prompt="<prompts/subagent-tagger.md 본문 전체 + batch input>"
)
```

### Step 5 — finalize

모든 wave 성공 종료 후:
1. `assets.jsonl.partial` 읽기 → `guid` lexicographic sort.
2. 정렬된 내용을 `assets.jsonl.tmp`에 쓰기 → atomic rename으로 `assets.jsonl` 만듦.
3. `assets.jsonl.partial` 삭제.
4. `packages.jsonl` 파생: `assets.jsonl`을 `package_id`별로 group → `schemas/package-record.json` 형식으로 작성 (atomic).
5. `state.json` 갱신:
   - `last_run = now()` (ISO-8601)
   - `version` 갱신 (manifest.json::version과 동기)
   - `guid_signatures` 전체 갱신
   - `in_progress_run = false`
   - `completed_batches = []` (다음 실행을 위해 reset)
   - `pending_batches`에서 이번 실행이 성공한 batch 제거
6. `manifest.json` 갱신: `{version, last_run, schema_tier}` (atomic).

### Step 6 — Idempotency 보장 (CRIT-IDX2)

no-op 경로(변경 셋이 빈 경우)는 다음을 단언:
- `assets.jsonl`은 디스크에서 그대로 유지 (재작성 없음, byte-identical).
- subagent 호출 0회.
- `state.json::last_run`만 갱신.

이는 "byte-identity-after-no-op-rerun"이지 "byte-identity-after-retag"가 아님 (LLM 결정론 없음).

## 산출 파일

CONVENTION.md §1 참조. 핵심:
- `<unity-project>/.claude/unity-asset-index/manifest.json`
- `<unity-project>/.claude/unity-asset-index/packages.jsonl`
- `<unity-project>/.claude/unity-asset-index/assets.jsonl`
- `<unity-project>/.claude/unity-asset-index/state.json`

## 실패 모델

- subagent batch 실패 → `state.json::pending_batches` 기록 → 다음 실행이 자동 재시도.
- subagent malformed JSON → `state.json::bad_rows` 기록 → 다음 batch에서 재처리.
- 크래시 → `in_progress_run = true`가 남음 → 다음 실행이 R1 복구 분기로 재개.
- Unity Editor 미실행 → filesystem 1차 수집까지는 동작 (unity-mcp deep-fetch는 fallback `mcp_unavailable`로 skip).

## 진전된 CRIT-*

- **CRIT-IDX1 (Coverage)**: 모든 `.meta` 파일이 assets.jsonl에 포함.
- **CRIT-IDX2 (Idempotency)**: no-op 경로 byte-identity.
- **CRIT-IDX3 (Incremental accuracy)**: K개 파일 수정 → 정확히 K개 row만 변경.
- **CRIT-IDX4 (Subagent + 크래시 복구)**: 60s 타임아웃 + R1 복구 분기.

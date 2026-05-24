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

### Step 1.5 — stale 우회 파일 정리 (자가 복구)

`<unity-project>/.claude/unity-asset-index/_tmp/` 디렉토리가 존재하면 **무조건 폐기**한다 (`Remove-Item -Recurse -Force`). 본 디렉토리는 CONVENTION.md §1의 산출 5종에 포함되지 않으며 §2.4의 R1 복구 분기도 인식하지 않는 비공식 임시 파일(LLM 자가 우회의 잔재)이다.

**이 SKILL을 실행하는 LLM 인덱서는 본 인덱싱 turn 도중에도 `_tmp/` 디렉토리·`meta-list.json`·`setup-batches.ps1`·`batches/` 등 어떤 비공식 staging 파일도 새로 만들지 않는다**. 작성하는 즉시 자기 자신이 §2.6 위반이며, 같은 fail mode(자기가 쓴 파일을 못 읽거나, 자동화 스크립트가 권한 prompt에서 막힘)를 반복 유발한다. 폐기는 본 Step 1.5의 1회 정리만 수행하고, 이후로는 산출 5종(`manifest.json`, `packages.jsonl`, `assets.jsonl`, `assets.jsonl.partial`, `state.json`) 외 어떤 파일도 인덱스 디렉토리 하위에 쓰지 않는다.

### Step 1.6 — 자가 검출 게이트 (CRITICAL — 다른 모든 Step보다 우선)

텍스트 규칙(Step 1.5/2/4의 "금지" 문구)만으로는 LLM의 작업 회피 패턴(특히 Task() 병렬 fan-out을 회피하기 위한 PowerShell/Bash 자동화 우회)을 막지 못한다는 실측 증거가 있다. 본 게이트는 **모든 도구 호출 직전에 LLM 자신이 수행하는 자가 검사**이며, 위반 시 즉시 self-abort + stdout emit + state.json::last_error 기록을 강제한다.

#### 1.6.1 게이트 절차

매 도구 호출 직전:

1. **Write / Edit / NotebookEdit** → 대상 경로가 `.claude/unity-asset-index/` 하위라면 다음 화이트리스트에 포함돼야 한다:
   - `manifest.json`, `manifest.json.tmp`
   - `packages.jsonl`, `packages.jsonl.tmp`
   - `assets.jsonl`, `assets.jsonl.tmp`, `assets.jsonl.partial`
   - `state.json`, `state.json.tmp`
   - (deep-fetch 캐시 사용 시) `deep-cache/<guid>.json`
   - **V0.1.0+3 helper 화이트리스트**: `_batches/batch-*.txt` (단 LLM이 직접 Write/Edit하면 안 되고 `indexer-helper.ps1`만 작성 권한)
   - **V0.1.0+4 helper-bridge 화이트리스트**: `_batches/responses/<batch_id>.jsonl` (LLM이 subagent stdout을 받아 직접 Write 가능. `indexer-helper.ps1 -Cmd AppendPartial`이 본 파일을 읽어 partial로 합친다. `CleanupBatches`가 `_batches/` 전체 폐기 시 자동 정리.)
   화이트리스트 외 경로 → **즉시 self-abort**.

2. **Bash / PowerShell** → 명령 문자열에 다음 금지 패턴이 하나라도 포함되면 **즉시 self-abort**:
   - `_tmp\\`, `_tmp/`, `\_tmp`, `/_tmp` (자가 우회 디렉토리)
   - `meta-list`, `setup-batches`, `merge-wave`, `finalize.ps1`, `rebuild.ps1` (자가 우회 자동화 스크립트명)
   - `_tmp\\batches\\batch-`, `_tmp/batches/batch-` (자가 우회 batch staging — V0.1.0+3에서 `_batches/`로 분리되어 helper만 허용)
   - `wave1-responses`, `wave2-responses`, `wave3-responses` (자가 우회 응답 staging)
   - **예외 1**: Step 1.5의 `Remove-Item -Recurse -Force ...\_tmp` 1회 폐기 명령.
   - **예외 2 (V0.1.0+3)**: PowerShell 명령에 `indexer-helper.ps1` 또는 `skills/unity-assets-index/lib/indexer-helper.ps1`이 포함되면 helper 호출이라 통과 (CONVENTION.md §2.6 예외).

3. **Task** → 정상 진행 (subagent fan-out은 게이트 통과).

4. **Glob / Read / Grep** → 정상 진행.

#### 1.6.2 Self-abort 동작

위반 감지 시 LLM은 다음을 순서대로 수행하고 즉시 응답을 종료:

1. **위반 도구 호출 자체를 발행하지 않는다**. 작성하려던 파일은 만들지 않는다.
2. `state.json`에 `last_error` 기록 (atomic write):
   ```json
   {
     "last_error": {
       "reason": "bypass_attempted",
       "step": "Step <현재 단계>",
       "at": "<ISO-8601>",
       "detail": "tried <Tool>(<path 또는 명령 요약, 80자 이내>)"
     },
     "in_progress_run": false
   }
   ```
3. stdout 정확히 1줄 emit (종료 신호 출력 계약과 동일):
   ```
   [unity-assets:index] error: bypass_attempted at Step <N> (target=<path 또는 명령>)
   ```
4. 응답 종료. 사용자에게 재호출 안내는 별도 텍스트로 출력 가능하지만 SKILL 실행 자체는 본 게이트 통과 실패로 중단.

#### 1.6.3 게이트의 우선순위

본 게이트는 Step 2 (변경 셋 계산), Step 4 (wave 실행), Step 5 (finalize)보다 우선한다. 즉, "wave 실행 중에 batch 명세를 staging해서 빠르게 끝내려는" 시도조차 1.6.1의 Bash/PowerShell 금지 패턴에 걸려 self-abort한다. 작업 회피의 모든 경로를 본 게이트 하나로 닫는다.

silent stall(stdout emit 없이 응답 종료)도 본 게이트 위반과 동일하게 doctor 검사 6에서 사후 감지된다.

### Step 2 — 변경 셋 계산 (V0.1.0+3: helper로 위임)

**deterministic helper 호출**: `pwsh skills/unity-assets-index/lib/indexer-helper.ps1 -Cmd GetMetaList -Project <unity-project>`로 `.meta` 목록 JSONL을 받는다. helper가 Glob + `ignore_paths` 적용을 deterministic하게 수행하므로 LLM thinking 부담 0. 직전 probe 측정 결과 helper 호출은 459 .meta 기준 ~50ms로 완결되었다.

helper 출력 (한 줄당 한 entry):
```json
{"abs":"<absolute>","rel":"<relative forward-slash>","mtime":"<ISO-8601>","size":<bytes>}
```

LLM은 이 JSONL을 Bash redirect로 임시 파일에 저장:
```
pwsh ...indexer-helper.ps1 -Cmd GetMetaList -Project <project> > <임시 meta-list path>
```

권장 임시 위치: `<project>/.claude/unity-asset-index/_meta-list.jsonl` — 단 산출 5종 외이므로 본문 처리 후 즉시 폐기. 또는 메모리에 직접 capture (Bash command substitution).

**변경 셋 계산**:

1. **증분 모드** (`/unity-assets:index`):
   - 메타 목록을 한 줄씩 읽으며 `state.json::guid_signatures[guid]` 비교. helper의 `mtime`+`size`로 시그니처 `<mtime>:<size>` 구성.
   - 시그니처 불일치 GUID만 변경 셋. `state.json::pending_batches`의 batch도 합류.
   - 빈 변경 셋 → **no-op 경로** (CRIT-IDX2): `assets.jsonl` byte-for-byte 재사용, `state.json::last_run`만 갱신.
2. **Full 모드** (`/unity-assets:reindex`): 모든 entry가 변경 셋. `state.json::guid_signatures` 비교 건너뛰기.

이전 V0.1.0+1까지 LLM이 직접 수행하던 chunked Glob/시그니처 비교 부담이 helper로 이관되어 시간 부하가 사라진다.

### Step 3 — wave 계획

**V0.1.0+3 helper 호출**: `pwsh skills/unity-assets-index/lib/indexer-helper.ps1 -Cmd PlanBatches -Project <project> -MetaList <meta-list path> -BatchSize 20`을 호출하면 helper가 `_batches/batch-NNN.txt`를 deterministic하게 생성하고 stdout에 batch 목록 JSON을 반환한다:

```json
{"total_assets":459,"batch_size":20,"batch_count":23,"batches":[{"id":"batch-001","path":".../_batches/batch-001.txt","count":20},...]}
```

LLM은 이 JSON에서 다음을 추출:
- N = `total_assets`, batch 수 = `batch_count`.
- wave 수 = `ceil(batch_count / parallel_subagents)`, `parallel_subagents = config.parallel_subagents` (기본 10).
- 한 wave 안에서 parallel_subagents 개의 subagent를 동시 호출 (각 batch txt 1개씩 처리).
- wave 시작·끝 stdout 마커는 **강제 emit** (§ 종료 신호 출력 계약 wave 마커 섹션 참조). helper의 `InitWaveTiming`/`CompleteWaveTiming` 호출이 wall-clock 단일 진실원.

**batch_size 기본값 변경 이력**: V0.1.0 = 20 → V0.1.0+1 = 50 (wave 수 감소 시도) → V0.1.0+2 = **20 원복** (probe 결과 50은 fallback general-purpose subagent의 200K context cap에 4/10 batch "Prompt too long" 실패 + 일부 fictitious row 발생) → V0.1.0+3 = **20 유지 + helper 위임으로 wave당 부담은 줄지 않지만 메인 LLM의 batch 분할 부담 제거**. plugin-defined `unity-assets:asset-tagger` (system prompt 자동 적용, prompt prepend 불필요) 사용 시 더 큰 batch_size 가능 — 새 세션에서 plugin이 정상 로드되었는지 doctor로 확인 후 단계적 상향.

### Step 4 — wave 실행

**Task() 직접 호출 강제**: subagent fan-out은 반드시 `Task()` 도구 호출로만 수행한다. PowerShell/Bash 스크립트를 작성하여 batch 명세를 디스크에 dump하고 그 스크립트로 fan-out을 자동화하려는 우회는 금지 — CONVENTION.md §2.6 위반이며 권한 prompt에서 막히거나 사용자 환경에서 실행 실패한다.

**한 wave의 K subagent는 반드시 하나의 응답 메시지에 K개의 tool_use 블록으로 동시 emit**한다. K개를 K개의 별도 메시지로 분할 발행하면 wave가 직렬화되어 실제 시간이 K배가 된다 (실측 사례: 23 batch 직렬 → 약 30~42분, 병렬 → 약 1~3분). 호출 횟수 회피를 이유로 우회를 만들지 않는다.

**병렬 위반 자가 검출**: wave 시작 후 첫 응답 메시지에 K개 미만의 Task() tool_use만 emit한 경우(예: 1개씩 분할 발행), LLM은 stdout에 다음 warning을 1회 emit한다:

```
[unity-assets:index] warning: wave serialized (wave=<W>/<T>, expected_parallel=<K>, actual_in_message=<M>)
```

이 warning은 종료 메시지 contract에 영향을 주지 않지만 사용자 가시성으로 직렬 fan-out을 즉시 식별할 수 있다.

#### 4.0 wave 시작 마커 (V0.1.0+3: helper InitWaveTiming)

각 wave 시작 시 다음을 순서대로 수행:

1. **helper deterministic 호출**: `pwsh skills/unity-assets-index/lib/indexer-helper.ps1 -Cmd InitWaveTiming -Project <project> -Wave <W> -TotalWaves <T> -Subagents <K>` — helper가 단일 호출로 다음을 처리:
   - `state.json::in_progress_run = true` 설정 + atomic write
   - `Get-NowIso` 호출하여 wall-clock 측정
   - `state.json::wave_timings` 배열에 새 entry append (`start = 외부 wall-clock`, `end=null`)
   - 갱신된 entry를 stdout JSON으로 반환
   
   **LLM 자가 추정 ISO 사용 금지** — 본 helper 호출이 wall-clock 단일 진실원. 이전 V0.1.0+2까지 LLM이 직접 `Get-Date`를 호출해야 했지만 일부 세션이 이를 무시하고 자가 추정 ISO를 적은 사례가 측정되어 helper로 이관.
2. stdout 1줄 emit (강제, ISO는 step 1 helper 출력의 `start` 값):
   ```
   [unity-assets:index] wave <W>/<T>: dispatching <K> subagents @ <helper wall-clock ISO>
   ```
3. 같은 메시지(같은 응답)에서 K개의 `Task()` tool_use 블록을 동시 발행. 각 prompt에 `BATCH_SPEC_FILE: <Step 3 helper PlanBatches 출력의 batches[i].path>` 전달.

한 wave 안의 subagent 호출 형식 (병렬):

```
Task(
  subagent_type="unity-assets:asset-tagger",
  model="haiku",
  prompt="<batch input — 프로젝트 루트 절대 경로, 처리할 에셋 절대 경로 목록 (batch_size 개), 각 에셋의 .meta 절대 경로, batch_id>"
)
```

**60초 wall-clock 타임아웃**. 타임아웃 시 해당 batch는 `state.json::pending_batches`에 `{batch_id, reason: "subagent_timeout"}`로 기록되고 wave는 살아남은 subagent 결과로 계속 진행 (stall 방지).

**각 subagent 반환 JSONL row 처리 (V0.1.0+4 — helper AppendPartial 위임)**:

이전(V0.1.0+3) reindex 측정에서 메인 LLM이 200-row를 PowerShell here-string으로 한 번에 partial에 넘기다 `ENAMETOOLONG`에 막혀 시스템 TEMP에 wave별 임시 파일을 만들어 우회하는 패턴이 관찰되었고, wave 1 wall의 약 60%(700s+)가 이 transcription overhead로 소비되었다. V0.1.0+4는 이 흐름을 helper deterministic 호출로 위임한다.

각 subagent 응답을 받자마자 다음을 순서대로 수행 (메모리 누적 금지 — wave 끝에 한꺼번에 처리하면 ENAMETOOLONG 재발):

1. subagent stdout의 JSONL 본문을 **Write 도구로** `<unity-project>/.claude/unity-asset-index/_batches/responses/<batch_id>.jsonl`**에 그대로 저장**. 행 사이 개행 보존, 추가 가공 0. 인덱스 디렉토리 하위라 Step 1.6.1 화이트리스트(V0.1.0+4 helper-bridge)로 통과한다.
2. helper 호출: `pwsh skills/unity-assets-index/lib/indexer-helper.ps1 -Cmd AppendPartial -Project <unity-project> -BatchId <batch_id> -InputFile <위 responses 경로>`. helper가 다음을 deterministic 수행:
   - 필수 7 필드(`guid, path, name, type, labels, llm_tags, llm_summary`) 검증.
   - 통과 row → `assets.jsonl.partial`에 concurrent-safe atomic append (IOException 30회 retry로 같은 wave의 K개 helper 동시 호출 race 흡수).
   - 실패 row는 stdout `bad_details` 배열로만 반환 (state.json write 없음 — race-free).
3. helper stdout JSON `{batch_id, ok_rows, bad_rows, bad_details}` 받아:
   - `ok_rows`/`bad_rows` 수치를 wave 누적치에 합산 (Step 4.0.1 `CompleteWaveTiming` 호출에 전달).
   - `bad_details` 배열은 메모리에 모았다가 wave 끝 마커 emit 직전 1회로 `state.json::bad_rows`에 통합 (atomic). 다음 batch가 재시도 라우팅에 사용.
   - `bad_rows == 0`이면 `state.json::completed_batches`에 `batch_id` 추가.

K개의 helper 호출은 Task() 호출처럼 한 응답 메시지의 K개 Bash tool_use 블록으로 동시 emit할 필요는 없다(직렬이어도 한 호출 당 milliseconds 단위라 wave wall에 영향이 작음). 단 helper는 동시 호출에 race-safe하게 설계되어 있으므로 LLM이 wave 안에서 subagent 응답을 받는 즉시 발행하는 패턴이 권장된다.

#### 4.0.1 wave 끝 마커 (V0.1.0+3: helper CompleteWaveTiming)

wave 안의 모든 batch 처리(타임아웃·실패 포함)가 종료되면:

1. **helper deterministic 호출**: `pwsh skills/unity-assets-index/lib/indexer-helper.ps1 -Cmd CompleteWaveTiming -Project <project> -Wave <W> -OkRows <X> -BadRows <Y> -TimeoutBatches <list>` — helper가 단일 호출로 다음을 처리:
   - `Get-NowIso` 호출하여 wall-clock 측정 (end)
   - 4.0의 start와 end의 차이를 deterministic 산술로 `elapsed_sec` 계산
   - `state.json::wave_timings`의 wave=<W> entry를 갱신 (end, elapsed_sec, ok_rows, bad_rows, timeout_batches) + atomic write
   - 갱신된 entry를 stdout JSON으로 반환
   
   **LLM 자가 추정 ISO 사용 금지** — Step 4.0과 동일 이유. ISO 산술도 helper가 deterministic으로 수행.
2. stdout 1줄 emit (강제, ISO는 step 1 helper 출력의 `end` 값):
   ```
   [unity-assets:index] wave <W>/<T>: completed <K> subagents, ok=<X> bad=<Y> elapsed=<sec>s @ <helper wall-clock ISO>
   ```
3. 다음 wave가 있으면 4.0으로 돌아간다. 마지막 wave면 Step 4.5 → Step 5로 진행.

본 마커가 누락되거나 `elapsed_sec`이 wave당 60s를 크게 초과 (예: 600s+)하면 직렬 fan-out 의심. helper 호출이 wall-clock 신뢰성의 핵심이며, 다음 reindex의 병목 진단 인프라.

**Fallback subagent 형식** (AGENTS.md §3.1에서 plugin-defined agent 미동작 시):

```
Task(
  subagent_type="general-purpose",
  model="haiku",
  prompt="<prompts/subagent-tagger.md 본문 전체 + batch input>"
)
```

### Step 4.5 — minimal-tier record 보강 (subagent로 이관, CRIT-IDX5/6/7)

**V0.1.0+2 변경**: 이전 indexer-local cheap parser는 메인 LLM의 row-by-row 부하(probe 측정 459 row × Step 4.5 처리 ≒ 46분)가 reindex 총 시간의 90%를 차지한다는 진단 결과에 따라 **subagent로 이관**되었다. asset-tagger subagent가 row emit 시 다음 3개 신호를 직접 채워 반환한다. 메인 indexer는 검증·append만 수행.

#### 4.5.1 — filename regex 신호 추출 (CRIT-IDX5)

- **이관 전 (deprecated)**: indexer가 매 row regex 매칭 → filename_signals 채움.
- **이관 후**: indexer가 wave dispatch 시 `skills/unity-assets-index/lib/filename-conventions.json` 본문을 batch prompt에 prepend (1회 cache). subagent가 각 asset filename에 regex 매칭 → row emit 시 `filename_signals` 배열 채움. 매칭 0개면 필드 생략. subagent prompt 추가 비용: ~1KB (8 regex 패턴, 작음).

#### 4.5.2 — type_subtype 결정 (CRIT-IDX6)

- **이관 전 (deprecated)**: indexer가 매 row .meta 헤더 sniff + filename_signals + 경로 컨텍스트로 결정.
- **이관 후**:
  1. indexer가 wave dispatch 직전에 각 asset의 `.meta` 헤더 sniff를 PowerShell/Python deterministic cheap parse 1회 호출 (메인 LLM thinking 부하 0) → input의 `ASSETS[].type_subtype`에 pre-decision으로 전달 (이미 INPUT 스키마에 존재).
  2. .meta sniff로 결정 불가하면 input `type_subtype = null` 전달.
  3. subagent는 input type_subtype을 우선 passthrough. null이면 filename_signals (Step 4.5.1 결과) + 경로 컨텍스트(`Assets/UI/...` → ui 등)로 fallback 추론 → row emit 시 채움.
- taxonomy 후보 (data/type-taxonomy.yml: Sprite, AudioClip, Texture, Mesh, Prefab) 외 type은 결정 단계 건너뛰고 필드 생략.
- Unity Editor 미실행 환경에서는 importer 정보 결손으로 결정률이 떨어진다 (Risks §R2 참조).

#### 4.5.3 — curated labels yml 병합 (CRIT-IDX7)

- **이관 전 (deprecated)**: indexer가 매 row glob 매칭 + labels union (메인 LLM 부하).
- **이관 후**:
  1. indexer가 Step 1에서 `<unity-project>/.claude/unity-assets.labels.yml`을 1회 glob + parse + schema 검증.
  2. 각 batch dispatch 직전, batch에 포함된 에셋들의 path에 매칭되는 yml 라벨 entry만 추출 (정의 순서로 첫 매칭 적용) → batch prompt의 `ASSETS[].curated_labels` (string[]) 필드로 전달.
  3. subagent는 row emit 시 input `curated_labels` + `.meta labels` + `llm_tags` 토큰을 union하여 final `labels` emit. 우선순위 **yml > .meta > llm_tags** (충돌 시 yml 보존).
  4. **차분 로그 (선택)**: union 적용 전후 labels가 다른 row에 대해 subagent가 stdout에 `[asset-tagger] curated-labels override <path>: <before> -> <after>` 1줄 emit (brownfield 가시화, Risks §R5). 메인 indexer가 subagent stdout을 passthrough.

**trade-off (이관 전체)**: subagent prompt가 약간 무거워짐 — filename-conventions.json ~1KB + curated_labels per-asset(보통 0~3개 라벨 × 50 byte = ~150 byte). 그러나 메인 LLM의 row-by-row 부하 (probe 측정 46분)가 subagent 병렬로 분산되어 net 시간 대폭 단축 예상. batch_size 20으로 fallback subagent의 200K context cap 안전 한계 유지.

### Step 5 — finalize (V0.1.0+3: helper Finalize + CleanupBatches)

모든 wave 성공 종료 후 helper 2회 호출:

1. **`pwsh skills/unity-assets-index/lib/indexer-helper.ps1 -Cmd Finalize -Project <project>`** — helper가 deterministic하게 다음을 모두 수행:
   - `assets.jsonl.partial` 읽기 → `guid` lexicographic sort → `assets.jsonl.tmp` 작성 → atomic rename으로 `assets.jsonl` 만듦
   - `assets.jsonl.partial` 삭제
   - `packages.jsonl` 파생 (path top-2 segment grouping) + atomic write
   - `state.json` 갱신 (`guid_signatures` 전체 갱신, `last_run = NowIso`, `in_progress_run = false`, `completed_batches = []`, `pending_batches = []`) + atomic write
   - `manifest.json` 갱신 (`{version, last_run, schema_tier}`) + atomic write
   - stdout: `finalize OK: <N> rows, <P> packages`
2. **`pwsh skills/unity-assets-index/lib/indexer-helper.ps1 -Cmd CleanupBatches -Project <project>`** — `_batches/` 디렉토리 폐기. stdout: `cleaned` 또는 `absent`.

helper 출력을 그대로 stdout passthrough. 이전 V0.1.0+2까지 LLM이 sort + 다중 atomic write + grouping을 수행하던 부담이 helper로 이관되어 finalize 시간이 ~1초 미만으로 단축된다.

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

## 종료 신호 출력 계약

**모든 `/unity-assets:index` 실행은 종료 시 stdout에 정확히 1줄을 emit해야 한다**. 사용자/상위 orchestrator가 "진행 중 vs 정지"를 즉시 식별할 수 있도록 강제하는 contract이다. 1줄도 emit하지 않은 채 LLM이 응답을 종료하면 본 계약 위반(silent stall) — `/unity-assets:doctor`의 stale `_tmp/` 검사와 함께 이 silent stall이 가장 흔한 사용자 혼란 원인이다.

종료 메시지는 다음 5가지 중 하나:

| 형태 | stdout 1줄 | 의미 |
|------|-----------|------|
| 성공 | `[unity-assets:index] success: total=<N> changed=<K> waves=<W>` | 모든 wave 완료, finalize 성공 |
| no-op | `[unity-assets:index] no-op: total=<N> changed=0 (assets.jsonl reused)` | 변경 셋 빈 — CRIT-IDX2 경로 |
| R1 복구 | `[unity-assets:index] r1-resume: partial=<P> completed_batches=<C>` | `assets.jsonl.partial` 권위로 재개 |
| 부분 완료 | `[unity-assets:index] partial: total=<N> ok=<X> pending=<Y> bad=<Z>` | 일부 wave 실패, 다음 실행에서 재시도 |
| 실패 | `[unity-assets:index] error: <reason> at <step>` | 진행 불가 — `<step>` 직전 상태로 종료 |

**실패 reason 카탈로그** (테스트가 string match로 단언):

- `config_parse_failed` (Step 1) — `.claude/unity-assets.yml` 또는 `state.json` 파싱 실패
- `glob_failed` (Step 2) — `.meta` Glob 실패 또는 `Assets/` 부재
- `bypass_attempted` (모든 Step) — LLM이 `_tmp/`·`meta-list.json`·`setup-batches.ps1` 같은 비공식 우회를 작성하려 시도 → 자가 abort
- `subagent_all_timeout` (Step 4) — 한 wave의 모든 subagent가 60s 타임아웃
- `wave_zero_progress` (Step 4) — wave가 `ok=0`으로 끝남
- `atomic_rename_failed` (Step 5) — 산출 파일 atomic 작성 실패
- `internal_error` — 위 카탈로그에 없는 예외 (메시지에 짧은 detail 1줄 첨부)

**state.json::last_error 동기 기록** (실패/부분 종료 시):

```json
{
  "last_error": {
    "reason": "<카탈로그 값>",
    "step": "Step <N>",
    "at": "<ISO-8601>",
    "detail": "<100자 이내>"
  }
}
```

성공/no-op 종료 시에는 기존 `last_error` 키를 제거한다.

**Wave 마커 (강제)**: Step 4.0/4.0.1에 정의된 wave 시작·끝 마커는 강제 emit이며 wave 단위 진단·측정 인프라다. 종료 메시지 contract와 별개로 wave마다 emit한다.

```
[unity-assets:index] wave <W>/<T>: dispatching <K> subagents @ <ISO-8601>
[unity-assets:index] wave <W>/<T>: completed <K> subagents, ok=<X> bad=<Y> elapsed=<sec>s @ <ISO-8601>
[unity-assets:index] warning: wave serialized (wave=<W>/<T>, expected_parallel=<K>, actual_in_message=<M>)
```

각 wave마다 시작·끝 마커 2줄 + (Step 4의 병렬 위반 자가 검출 시) warning 1줄. 종료 메시지 1줄(성공/실패/no-op/r1-resume/partial)은 별개로 마지막에 emit. `state.json::wave_timings` 배열에 동기 기록되어 사후 진단 가능.

**stdout 미emit 검출**: 본 SKILL을 호출한 turn이 종료 메시지 없이 끝나면 silent stall로 간주. 사용자/`/unity-assets:doctor` 검사 6이 stale `_tmp/`로 사후 감지하지만, 사전적으로 LLM 자신이 모든 종료 경로에서 1줄 emit을 보장해야 한다.

## 실패 모델

각 실패 모드는 § 종료 신호 출력 계약에 따라 stdout 1줄을 emit한다.

- subagent batch 실패 → `state.json::pending_batches` 기록 → 다음 실행이 자동 재시도. stdout: `partial: ...`
- subagent malformed JSON → `state.json::bad_rows` 기록 → 다음 batch에서 재처리. stdout: `partial: ...`
- 한 wave 모든 subagent 타임아웃 → stdout: `error: subagent_all_timeout at Step 4`, `state.json::last_error` 기록.
- 크래시 (LLM context 종료, 사용자 Ctrl+C) → `in_progress_run = true`가 남음 → 다음 실행이 R1 복구 분기로 재개. 크래시 자체는 stdout emit 못 함 — Step 1.5/2.4가 다음 실행에서 복구.
- **자가 우회 시도** (`_tmp/`·자동화 스크립트 작성) → 즉시 self-abort. stdout: `error: bypass_attempted at Step <N>`, 작성 시도한 파일 폐기.
- Unity Editor 미실행 → filesystem 1차 수집까지는 동작 (unity-mcp deep-fetch는 fallback `mcp_unavailable`로 skip). 종료 메시지는 성공/partial 정상 경로.

## 진전된 CRIT-*

- **CRIT-IDX1 (Coverage)**: 모든 `.meta` 파일이 assets.jsonl에 포함.
- **CRIT-IDX2 (Idempotency)**: no-op 경로 byte-identity.
- **CRIT-IDX3 (Incremental accuracy)**: K개 파일 수정 → 정확히 K개 row만 변경.
- **CRIT-IDX4 (Subagent + 크래시 복구)**: 60s 타임아웃 + R1 복구 분기.
- **CRIT-IDX5 (filename 신호)**: Step 4.5.1 — `filename-conventions.json`의 8개 regex로 파일명에서 신호 추출 → `filename_signals` 필드. 픽스처 8종에서 5/8 이상.
- **CRIT-IDX6 (서브타입 분류)**: Step 4.5.2 — `.meta` + 헤더 sniff + filename_signals 결합으로 `type_subtype` 결정. 픽스처 20 에셋 중 18/20 (Editor 실행 시) 또는 14/20 (Editor 미실행 시).
- **CRIT-IDX7 (큐레이션 라벨)**: Step 4.5.3 — `unity-assets.labels.yml`의 glob 매핑이 `labels` 필드에 union 반영, 우선순위 yml > .meta > llm_tags. 픽스처 5개 glob 매핑에서 5/5.

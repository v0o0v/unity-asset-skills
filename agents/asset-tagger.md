---
name: asset-tagger
description: Unity 에셋 파일 경로 목록을 받아 의미 태그(llm_tags)와 한 줄 요약(llm_summary)을 생성하는 pure analyzer subagent. Read 전용 — 파일 시스템 변경 금지. Indexer가 wave 별 batch fan-out으로 호출. 출력은 minimal Asset Record 7 필드 JSONL.
tools: Read
model: haiku
color: yellow
---

# unity-asset-skills: asset-tagger

`unity-asset-skills` 플러그인의 자체 subagent. Indexer(`/unity-assets:index`)가 한 wave 당 최대 `parallel_subagents` (기본 10) 개를 병렬로 띄워, 각 인스턴스가 `batch_size` (기본 20) 개의 에셋을 처리한다.

## 책임 범위

- **입력**: 분석할 에셋 파일 절대 경로 목록 (`batch_size` 개).
- **출력**: stdout으로 에셋당 한 줄, 총 N줄의 JSONL. 각 줄은 `schemas/asset-record.minimal.json` 7 필드를 준수.
- **도구**: Read만 사용. Edit/Write/Bash/Task/MCP 호출 **모두 금지**. 분석 외 부작용 0.

## 입력 형식

부모(Indexer)는 다음 정보를 prompt로 전달한다:

```
- 프로젝트 루트 절대 경로
- 처리할 에셋 절대 경로 목록 (batch_size 개)
- batch_id (재시도·재개 추적용 식별자)
- 각 에셋의 .meta 파일 경로 (guid·labels 추출용)
```

## 출력 형식 (행 단위 엄격 JSONL)

각 에셋마다 다음 7 필드만 가진 JSON 객체 한 줄 (개행 포함). 다른 필드 추가 금지.

```json
{"guid":"abc123...","path":"Assets/Packages/MedievalVillage/Prefabs/Wall_01.prefab","name":"Wall_01","type":"Prefab","labels":["medieval","wall"],"llm_tags":["medieval","village","exterior","stone-wall"],"llm_summary":"Medieval European village exterior wall, modular stone wall prefab."}
```

필드 의미:
- `guid` — 짝꿍 `.meta` 파일의 `guid:` 필드 값.
- `path` — 프로젝트 루트 기준 상대 경로 (forward slash, 확장자 포함).
- `name` — 파일 stem (확장자 제외).
- `type` — Unity 에셋 타입 (`Prefab`, `Material`, `Texture`, `AnimatorController`, `ScriptableObject`, `MonoScript`, `Scene` 등). `.meta`의 importer 타입 또는 확장자로 판정.
- `labels` — `.meta`의 `labels:` 필드 값. 없으면 빈 배열 `[]`.
- `llm_tags` — 의미 태그. kebab-case 영문. 4~8개. 카테고리 + 분위기 + 형태/스타일을 골고루.
- `llm_summary` — **English one-line summary (영어 한 줄)**. 검색 매칭에 사용되므로 구체적 어휘 사용. 마침표로 끝.

## 분석 가이드

1. 먼저 `.meta` 파일을 Read하여 `guid`, `labels`, importer 타입 추출.
2. 에셋 본문(.prefab, .mat, .asset 등은 YAML; .cs는 텍스트; 바이너리는 메타 의존)을 Read하여 의미 정보 수집.
3. 큰 바이너리(.fbx, .png, .wav 등)는 Read 생략하고 파일명·경로·labels·확장자만으로 추론.
4. 패키지 컨텍스트(`Assets/Packages/<이름>/...` 경로)를 활용하여 도메인 추론.

## 출력 제약

- 한 batch 안에서 **모든** 입력 에셋에 대해 정확히 한 줄씩 emit. 빠뜨리지 않음.
- 분석 실패한 에셋도 자기 행은 emit하되 `llm_tags: []`, `llm_summary: "(분석 실패)"`로 표시. Indexer가 `state.json::bad_rows`로 재시도 라우팅한다.
- JSON 외 출력 금지. 설명·markdown·prose 0줄.
- 60초 wall-clock 예산. 초과 시 부모가 batch를 `pending_batches`로 재큐잉.

## 금지 사항

- Edit / Write / Bash / Task / MCP 호출
- 새 파일 생성 (분석 노트·로그 포함)
- 사용자에게 질문 (batch 입력이 진실원)
- 한글로 `llm_summary` 작성 (영어 필수). 한국어가 들어가면 토큰 효율과 BM25/임베딩 정렬에 손해이므로 모든 요약은 영어 한 문장.
- 7개 외 신규 필드 추가 (스키마 위반은 `bad_rows` 행이 됨)

## Fallback 표기

`AGENTS.md`의 "## 의존성 및 호출 컨벤션" 섹션이 plugin-defined agent 등록을 사용하지 못한다고 명시한 경우, Indexer는 `Task(subagent_type="general-purpose", model="haiku", prompt=<이 SKILL.md 본문 + batch 입력>)` 형식으로 호출한다. 그 경우에도 본 가이드의 출력 형식·금지 사항은 동일하게 적용된다.

## V0.1.0+2 — Step 4.5 보강 이관 (CRIT-IDX5/6/7)

이전에 indexer-local cheap parser로 처리되던 3개 신호가 subagent로 이관되었다. probe 측정 결과 메인 LLM의 row-by-row 보강이 reindex 총 시간의 90% (459 row × 약 46분)를 차지했기 때문이다.

### 확장된 INPUT (indexer가 prompt에 추가 전달)

각 ASSETS entry에 다음 필드가 추가된다:
- `type_subtype`: indexer가 .meta 헤더 sniff로 결정한 pre-decision (`<Type>/<subtype>` 또는 `null`).
- `curated_labels`: indexer가 `.claude/unity-assets.labels.yml` glob 매칭으로 추출한 배열 (없으면 `[]`).

prompt 앞부분에 추가로 전달:
- `FILENAME_CONVENTIONS`: `skills/unity-assets-index/lib/filename-conventions.json` 본문 (8 regex × signals 매핑, ~1KB).

### 확장된 OUTPUT row schema (필드 추가 — V0.1.0+4 emit 의무화)

```json
{"guid":"...","path":"...","name":"...","type":"...","labels":["..."],"llm_tags":["..."],"llm_summary":"<English>","filename_signals":["..."],"type_subtype":"<Type>/<subtype>"}
```

V0.1.0+4 이전에는 `filename_signals`와 `type_subtype`을 매칭/결정 0개일 때 키 자체를 생략하도록 했고, 그 결과 V0.1.0+3 reindex(459 row)에서 두 필드 모두 0/459(0%) emit되어 CRIT-IDX5/6 검증이 모두 실패했다. V0.1.0+4부터는 다음을 강제한다:

- **`filename_signals` — 모든 row에 emit MUST** (schema에서는 여전히 optional이지만 본 agent 행위 규약은 의무). FILENAME_CONVENTIONS 8개 regex를 asset filename에 매칭하여 union을 만들고, 매칭 0개여도 빈 배열 `[]`을 그대로 emit. 키 자체를 생략하지 않는다.
- **`type_subtype` — 모든 row에 emit MUST**. 결정 분기:
  - input `type_subtype`이 non-null이면 그대로 passthrough.
  - input이 null이면 filename_signals + 경로 컨텍스트(`Assets/UI/...` → ui 등) + `data/type-taxonomy.yml` 후보로 fallback 추론하여 best-effort 결정. 정말 결정 불가 시 **`null`을 명시 emit** (`"type_subtype": null`). 키 자체를 생략하지 않는다.

`labels` 처리 갱신: input `curated_labels` + `.meta labels` + `llm_tags`의 라벨형 토큰 union. **우선순위 curated > meta > llm_tags** (충돌 시 curated 보존).

차분 로그 (선택): yml union 적용 전후 labels가 다른 row면 stdout에 `[asset-tagger] curated-labels override <path>: <before> -> <after>` 1줄 emit.

### V0.1.0+4 self-check (row emit 직전)

각 row를 stdout에 보내기 전에 자가 검사:
1. 7 필수 필드 (`guid, path, name, type, labels, llm_tags, llm_summary`)가 모두 present 인가?
2. **`filename_signals` 키가 present 인가?** (값이 `[]`라도 키는 있어야 함.)
3. **`type_subtype` 키가 present 인가?** (값이 `null`이라도 키는 있어야 함.)

3개 모두 yes일 때만 emit. self-check 실패 시 같은 row를 한 번 더 재구성하고 fail 시에만 `llm_tags:[]`, `llm_summary:"(분석 실패)"`, `filename_signals:[]`, `type_subtype:null`로 fallback emit (Indexer가 bad_rows로 라우팅).

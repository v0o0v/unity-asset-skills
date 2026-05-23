---
name: search
description: 자연어 의도로 Unity 에셋 인덱스를 검색한다. LLM-as-Search dual-call (1차 multi-category 라우팅 + sub-intent 분해 → 2차 sub-intent별 retrieval). 기본 package-first drill-down, 2000+ 에셋 또는 index_depth=rich 시 map-reduce sliding chunks 자동 전환. 결과는 schemas/search-result.json.schema.json 형식으로 .claude/unity-asset-index/search-result.json에 atomic 저장. /unity-assets:pick으로 대화형 narrowing.
---

# /unity-assets:search — Unity 에셋 LLM-as-Search

## 책임 범위

자연어 의도를 받아 `<unity-project>/.claude/unity-asset-index/`의 인덱스를 직접 LLM에게 보여주고 후보 에셋을 confidence 점수와 함께 식별한다. embedding·벡터 DB 없이 dual-call 방식으로 multi-intent도 처리한다. 결과는 `search-result.json`으로 직렬화하여 `/unity-assets:build`(Orchestrator)가 소비한다.

CONVENTION.md를 계약 진실원으로 참조한다.

## 호출 패턴

- `/unity-assets:search "<자연어 의도>"` — 1회성 검색.
- `/unity-assets:pick` — 직전 검색 결과에서 대화형 narrowing (사용자가 sub-intent 또는 후보를 선택).

## 사전 조건

1. cwd가 Unity 프로젝트 루트.
2. `.claude/unity-asset-index/{manifest.json, packages.jsonl, assets.jsonl}` 존재.
3. 부재 또는 stale(mtime이 `state.json::last_run`보다 오래됨) 시 CRIT-SCH4 fallback 경로.

## 실행 흐름

### Step 1 — 입력 검증 + malformed 핸들링 (CRIT-SCH3)

- 입력이 빈 문자열, 따옴표 미스매치, 또는 의미를 추출할 수 없는 한글-only / 이모티콘-only 인 경우 panic 없이 구조화 응답:
  ```json
  {"status": "no_query", "reason": "<짧은 한글 사유>"}
  ```
- 정상 입력이면 다음 Step으로.

### Step 2 — 인덱스 신선도 확인 (CRIT-SCH4)

- `manifest.json`, `assets.jsonl` 존재 확인.
- 부재 또는 `assets.jsonl.mtime < state.json::last_run` (조건상 부등호는 stale을 의미하지 않음 — 정확히는 둘이 일치해야 함; 불일치 시 stale)이면:
  - stdout에 구조화 경고 출력: 인덱스가 신선하지 않음, 두 옵션 제시.
  - 옵션 A: `/unity-assets:reindex` 사용자 직접 호출 권고.
  - 옵션 B: 자동 트리거 (사용자가 prompt에서 "재인덱스해서 검색" 명시했거나 Orchestrator의 R3 안내 경로로 호출된 경우).
- 신선하면 다음 Step.

### Step 3 — 설정 로드

`.claude/unity-assets.yml` 또는 기본값. 주요 키:
- `max_assets_in_context` (기본 500) — 단일 LLM 호출에 받는 최대 row 수.
- `index_depth` (기본 minimal) — `rich`이면 map-reduce 강제 전환.

### Step 4 — 1차 호출 (라우팅)

단일 subagent 호출:

```
Task(
  subagent_type="general-purpose",
  model="sonnet",
  prompt="<라우팅 instructions + 사용자 쿼리>"
)
```

라우팅 instructions는 subagent에게 다음을 emit하도록 지시:

```json
{"multi_category": <bool>, "sub_intents": [{"intent": "<자연어>", "category_hint": "<영문 또는 null>"}, ...]}
```

`schemas/search-routing.json.schema.json` 형식 준수. 출력은 검증 후 다음 Step의 입력.

### Step 5 — 2차 호출 (sub-intent별 retrieval)

각 sub-intent에 대해 별도의 subagent 호출:

#### 5.1 기본 경로 — package-first drill-down

1. `packages.jsonl`을 모두 읽음 (보통 수십~수백 개로 컨텍스트 friendly).
2. subagent에게 `packages.jsonl` rows + sub-intent + `category_hint` 전달, top-K (보통 K=3~5) 패키지 선택 + 각 패키지의 `confidence` (0~1) 출력 요청.
3. 선택된 패키지의 `package_id`에 해당하는 `assets.jsonl` rows만 읽음. row 수가 `max_assets_in_context` 초과면 5.2로 fallback.
4. subagent에게 해당 rows + sub-intent 전달, 후보 에셋들의 `{guid, path, confidence (0..1), reasoning (한글 풀-피델리티)}` 출력 요청.

#### 5.2 자동 전환 — map-reduce sliding chunks

- 트리거: `total_assets > 2000` OR `index_depth == rich` OR 단일 패키지 hit이 너무 많아서 5.1.3에서 `max_assets_in_context` 초과.
- `assets.jsonl`을 `max_assets_in_context` 단위로 chunk.
- 각 chunk마다 subagent 호출: chunk + sub-intent 전달, 후보 +confidence + reasoning emit.
- 모든 chunk의 후보를 모아서 confidence-descending sort, top-K (보통 K=10) 선택.
- 5.2 경로 진입 시 로그 마커 emit: `[unity-assets:search] map-reduce 분기 활성 (assets=<N>, chunks=<M>)` — CRIT-SCH2가 이 마커를 단언.

### Step 6 — 결과 직렬화

모든 sub-intent의 후보를 `schemas/search-result.json.schema.json` 형식으로 묶음:

```json
{
  "manifest_version": "<manifest.json::version 그대로 복사>",
  "groups": [
    {
      "sub_intent": "<라우팅 출력의 intent와 동일>",
      "candidates": [
        {"guid": "...", "path": "...", "confidence": 0.83, "reasoning": "<한글 풀-피델리티>"},
        ...
      ]
    },
    ...
  ]
}
```

**reasoning 필드는 풀-피델리티** (CONVENTION.md §7) — subagent가 생성한 추론 텍스트를 1바이트도 절단·요약하지 말고 그대로 직렬화. maxLength 없음.

`<.claude/unity-asset-index/search-result.json.tmp>` 작성 → atomic rename으로 `search-result.json` 만듦.

### Step 7 — 사용자 응답

stdout에 다음을 emit:
- 발견된 sub-intent 수와 각 그룹의 top-3 후보 (path + confidence + reasoning 한 줄 요약).
- 다음 행동 제안: `/unity-assets:pick`으로 선택, 또는 `/unity-assets:build "..."`로 바로 진행.

## `/unity-assets:pick` (대화형 narrowing)

이전 `search-result.json` 읽음 → 사용자에게 sub-intent 목록과 그 안의 후보를 번호로 제시 → 사용자 선택 → 선택을 반영한 새 `search-result.json`을 작성 (`groups` 필드를 사용자가 좁힌 후보만 남도록 수정, `manifest_version`은 그대로 유지).

## 산출 파일

- `<unity-project>/.claude/unity-asset-index/search-result.json`

## 실패 모델

- malformed query → `{status: "no_query"}` (CRIT-SCH3).
- 인덱스 부재/stale → 경고 + reindex 옵션 (CRIT-SCH4).
- subagent malformed routing 출력 → 한 번 재시도 후 fallback (single-intent로 전체 쿼리 처리).
- `max_assets_in_context` 초과 → 자동 map-reduce 전환 (CRIT-SCH2).

## 진전된 CRIT-*

- **CRIT-SCH1 (Recall@3)**: 골든 쿼리 10개 중 8개 이상에서 정답이 top-3.
- **CRIT-SCH2 (Drill-down 자동 전환)**: 2000+ 에셋에서 map-reduce 경로 활성 + 로그 마커.
- **CRIT-SCH3 (Malformed query)**: 구조화 `{status: "no_query"}` 응답.
- **CRIT-SCH4 (Indexer fallback 계약)**: 경고 + 두 reindex 옵션 제시.

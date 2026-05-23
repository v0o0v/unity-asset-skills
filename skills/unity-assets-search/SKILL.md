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

#### 4.0 한↔영 alias hint 조립 (CRIT-SCH5)

1차 라우팅 prompt 조립 직전, 다음을 수행한다:

1. 사용자 raw 쿼리에서 한글 token을 추출 (공백/구두점으로 split, 한글이 1자 이상 포함된 token만 채택).
2. 각 한글 token을 [data/aliases.yml](../../data/aliases.yml)의 `aliases` 매핑에서 lookup. 정확 일치 + 부분 일치(token이 alias key를 포함하거나 그 반대) 모두 시도.
3. 매칭된 (한글 token → 영문 alias 배열) 쌍을 모아 routing prompt 본문 앞에 다음 형식의 hint 블록으로 첨부:

```
--- Aliases hint ---
좀비: [zombie, undead, ghoul, enemy]
메뉴: [menu, ui, hud]
음악: [music, audio, bgm]
---
```

4. 매칭 결과가 0건이면 hint 블록 자체를 생략 (빈 블록 첨부 금지).
5. `aliases.yml` 부재·파싱 실패 시 fail-fast 하지 않고 경고 로그 1회 emit 후 hint 블록 생략하고 진행.

이 hint는 routing subagent가 `category_hint` 및 `subtype_hint` 결정 시 한글 도메인 어휘를 영문 카테고리로 연결하는 데 사용된다.

#### 4.1 라우팅 호출

단일 subagent 호출:

```
Task(
  subagent_type="general-purpose",
  model="sonnet",
  prompt="<Aliases hint (있다면) + 라우팅 instructions + 사용자 쿼리>"
)
```

라우팅 instructions는 subagent에게 다음을 emit하도록 지시:

```json
{"multi_category": <bool>, "sub_intents": [{"intent": "<자연어>", "category_hint": "<영문 또는 null>", "subtype_hint": "<Type/subtype 또는 null>"}, ...]}
```

`schemas/search-routing.json.schema.json` 형식 준수. 출력은 검증 후 다음 Step의 입력.

#### 4.2 subtype 매핑 지시 (CRIT-SCH6)

라우팅 instructions에는 다음 subtype 매핑 가이드를 추가한다:

- 쿼리에 `메뉴` / `HUD` / `UI` / `canvas` → `subtype_hint = "Sprite/ui"` 또는 `"Prefab/ui"`.
- 쿼리에 `배경 음악` / `BGM` / `music` → `subtype_hint = "AudioClip/music"`.
- 쿼리에 `효과음` / `SFX` / `sound-effect` → `subtype_hint = "AudioClip/sfx"`.
- 쿼리에 `앰비언스` / `ambience` / `환경 음향` → `subtype_hint = "AudioClip/ambience"`.
- 쿼리에 `노멀맵` / `normal map` / `_normal` → `subtype_hint = "Texture/normal-map"`.
- 쿼리에 `아이콘` / `icon` → `subtype_hint = "Texture/icon"` 또는 `"Sprite/ui"`.
- 쿼리에 `스프라이트시트` / `타일시트` → `subtype_hint = "Sprite/spritesheet"`.
- 쿼리에 `좀비 캐릭터` / `적 프리팹` / `humanoid` → `subtype_hint = "Prefab/character"`.
- 쿼리에 `나무` / `바위` / `식생` / `환경 prop` → `subtype_hint = "Prefab/environment"`.
- 쿼리에 `wave config` / `spawn 설정` / `ScriptableObject` → `subtype_hint` 생략 (ScriptableObject는 taxonomy 밖).

매핑이 모호하면 `subtype_hint = null` 또는 생략. emit된 값은 [data/type-taxonomy.yml](../../data/type-taxonomy.yml) 기반 `^[A-Za-z]+/[a-z0-9-]+$` 패턴(asset-record.minimal.json의 `type_subtype`과 동일)을 준수해야 한다.

### Step 5 — 2차 호출 (sub-intent별 retrieval)

각 sub-intent에 대해 별도의 subagent 호출:

#### 5.1 기본 경로 — package-first drill-down

1. `packages.jsonl`을 모두 읽음 (보통 수십~수백 개로 컨텍스트 friendly).
2. subagent에게 `packages.jsonl` rows + sub-intent + `category_hint` 전달, top-K (보통 K=3~5) 패키지 선택 + 각 패키지의 `confidence` (0~1) 출력 요청.
3. 선택된 패키지의 `package_id`에 해당하는 `assets.jsonl` rows만 읽음. row 수가 `max_assets_in_context` 초과면 5.2로 fallback.
4. subagent에게 해당 rows + sub-intent + (있다면) `subtype_hint` 전달, 후보 에셋들의 `{guid, path, confidence (0..1), reasoning (한글 풀-피델리티)}` 출력 요청.

   **subtype 필터 (CRIT-SCH6):** `subtype_hint`가 sub-intent에 주어진 경우 subagent instructions에 다음을 추가한다:
   - `type_subtype`이 `subtype_hint`와 정확히 일치하는 후보만 우선 고려한다.
   - 일치 후보가 K(보통 K=3) 미만이면 같은 `type` (예: `Sprite/ui`의 `Sprite`)의 다른 subtype 후보를 차순위로 보충한다.
   - 같은 `type` 후보도 K 미만이면 마지막으로 type-무관 후보를 채워 K개를 채운다.
   - subagent는 우선순위(정확 일치 > 같은 type > 무관) 정보를 `reasoning`에 명시한다 (예: "subtype 정확 일치", "같은 Sprite type 내 차순위").

#### 5.2 자동 전환 — map-reduce sliding chunks

- 트리거: `total_assets > 2000` OR `index_depth == rich` OR 단일 패키지 hit이 너무 많아서 5.1.3에서 `max_assets_in_context` 초과.
- `assets.jsonl`을 `max_assets_in_context` 단위로 chunk.
- 각 chunk마다 subagent 호출: chunk + sub-intent 전달, 후보 +confidence + reasoning emit.
- 모든 chunk의 후보를 모아서 confidence-descending sort, top-K (보통 K=10) 선택.
- 5.2 경로 진입 시 로그 마커 emit: `[unity-assets:search] map-reduce 분기 활성 (assets=<N>, chunks=<M>)` — CRIT-SCH2가 이 마커를 단언.

#### 5.3 자동 fallback (CRIT-SCH7)

Step 5.1 또는 5.2 완료 후 모든 sub-intent의 candidates 중 max confidence가 0.40 미만이면 다음 3단계를 순서대로 시도한다. 각 단계 진입 시 정확한 로그 마커를 stdout에 1회 emit한다 (문자열 그대로 복사·변형 금지 — CRIT-SCH7 테스트가 정확히 매칭).

1. **단계 1 — top-K 확장**: 5.1의 패키지 top-K를 3 → 5 → 8로 단계적으로 확장하며 retrieval 재시도. K 증분마다 5.1.2~5.1.4를 다시 호출. stdout 로그 마커 (K=현재 K 값을 정수로 치환):

   ```
   [unity-assets:search] fallback stage 1: top-K expansion (K=<N>)
   ```

   K=5 또는 K=8에서 confidence ≥ 0.40 후보가 1개 이상 발견되면 즉시 정상 결과로 종료한다. K=8까지 모두 < 0.40이면 단계 2로.

2. **단계 2 — map-reduce 강제**: 5.2 sliding chunks 분기를 강제 트리거 (트리거 조건 무시). stdout 로그 마커 (M=실제 chunk 개수를 정수로 치환):

   ```
   [unity-assets:search] fallback stage 2: map-reduce forced (chunks=<M>)
   ```

   map-reduce 결과의 max confidence ≥ 0.40이면 즉시 정상 결과로 종료. 여전히 < 0.40이면 단계 3으로.

3. **단계 3 — no_match 출력**: search-result.json에 다음을 작성하고 stdout 로그 마커 emit:

   ```json
   {
     "manifest_version": "<현재 manifest.json::version>",
     "status": "no_match",
     "suggested_action": "reindex",
     "groups": []
   }
   ```

   stdout 로그 마커:

   ```
   [unity-assets:search] fallback stage 3: no_match (suggested_action=reindex)
   ```

**계약 요약:**
- 각 단계 진입 시 마커 로그 1회만 emit (재시도 시 중복 emit 금지).
- 단계 1·2에서 confidence ≥ 0.40 후보가 발견되면 그 시점에서 즉시 정상 종료 (Step 6으로 진행), 후속 단계 진입 금지.
- `.claude/unity-assets.yml::fallback.max_stage` (기본 3, 옵션 2)로 단계 2까지만 시도하도록 옵션 제공 (단계 2에서도 실패 시 즉시 단계 3 no_match로 점프, 단계 3 마커는 그대로 emit).
- 단계 3 출력 시 `groups: []`는 schemas/search-result.json.schema.json의 `status="no_match"` 분기에서 허용됨.

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
- **CRIT-SCH5 (한↔영 alias 사전)**: Step 4.0의 한글 token → `data/aliases.yml` lookup → routing prompt에 `--- Aliases hint ---` 블록 첨부. 골든 쿼리의 한글 키워드(`좀비/검/숲/메뉴/음악` 등) 100% 커버.
- **CRIT-SCH6 (subtype 필터)**: Step 4.2의 subtype 매핑 지시 + Step 5.1.4의 `subtype_hint` 우선 순위 필터. `search-routing.json.schema.json`의 `subtype_hint` 필드(`^[A-Za-z]+/[a-z0-9-]+$`)를 통해 1차→2차 라우팅 정보 전달.
- **CRIT-SCH7 (3단 자동 fallback)**: Step 5.3의 (a) top-K 확장 → (b) map-reduce 강제 → (c) `{status:"no_match", suggested_action:"reindex"}` 출력. 각 단계의 stdout 로그 마커 정확 일치 단언.

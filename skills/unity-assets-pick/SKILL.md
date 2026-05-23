---
name: pick
description: 직전 /unity-assets:search 결과에서 row-index로 후보 1개를 선택하고, 그 선택을 .claude/unity-asset-index/feedback.jsonl에 한 줄 atomic append하여 다음 search의 routing prompt hint(Past picks hint)로 활용한다. confidence boost는 본 단계에서 prompt hint 수준이며 본격 calibration은 Wave 3에서 처리. read-only가 아닌 append-only 스킬 — search-result.json은 수정하지 않으며 feedback.jsonl만 늘린다.
---

# /unity-assets:pick — 후보 선택 + 학습 데이터 누적

## 책임 범위

`/unity-assets:search` 결과 `search-result.json::groups[*].candidates`를 0-based row-index로 평탄화한 후, 사용자가 지정한 인덱스의 후보 1개를 선택한다. 선택 결과는 `<unity-project>/.claude/unity-asset-index/feedback.jsonl`에 `schemas/feedback-row.json.schema.json` 모양의 한 줄로 atomic append된다.

이 데이터는 다음 `/unity-assets:search` 호출의 routing prompt가 Step 4.0.5 "Past picks hint" 블록으로 활용한다 (CRIT-EVAL3 연계). 본 스킬 자체는 confidence를 변경하지 않으며, `confidence_after`는 `min(1.0, confidence_before + 0.10)` 산식으로 **기록만** 한다 — 실제 confidence boost가 적용되는 것은 다음 검색 routing 시 prompt hint를 통해서다.

CONVENTION.md를 계약 진실원으로 참조한다. 특히 §6.1 manifest_version 핸드셰이크와 §2 atomic 계약(feedback.jsonl은 append-only 예외)을 준수한다.

## 호출 패턴

- `/unity-assets:pick <row-index>` — 0-based 정수. `search-result.json::groups[*].candidates`를 그룹 순서대로 평탄화한 글로벌 index. 예: groups[0]에 후보 3개, groups[1]에 후보 2개면 인덱스 0~4가 유효.

## 사전 조건

1. cwd가 Unity 프로젝트 루트.
2. `<unity-project>/.claude/unity-asset-index/search-result.json` 존재 (직전 `/unity-assets:search` 결과). 부재 → 에러 + exit 1.
3. `<unity-project>/.claude/unity-asset-index/manifest.json` 존재. `search-result.json::manifest_version`이 `manifest.json::version`과 일치 (CONVENTION.md §6.1 핸드셰이크). 불일치 → stale로 거부, exit 1.

## 실행 흐름

### Step 1 — `search-result.json` 로드

- `<unity-project>/.claude/unity-asset-index/search-result.json` 부재 시 stdout에 정확히 다음 한 줄 출력 후 exit 1:

  ```
  [unity-assets:pick] error: no search result; run /unity-assets:search first
  ```

### Step 2 — manifest_version 핸드셰이크

- `manifest.json::version`을 읽고, `search-result.json::manifest_version`과 비교한다. 불일치(또는 `manifest.json` 부재, `manifest_version` 필드 누락) 시 stdout에 정확히:

  ```
  [unity-assets:pick] error: stale search result; reindex required
  ```

  후 exit 1.

### Step 3 — 평탄화 및 row-index lookup

- `search-result.json::groups`를 인덱스 순서대로 순회, 각 group의 `candidates`를 그 순서대로 이어 붙여 평탄화된 후보 배열을 만든다 (글로벌 0-based).
- 동시에 각 후보에 대해 `(sub_intent, candidate_index_in_group, group_index_in_groups)` 추적.
- `<row-index>` 인자가 정수가 아니거나, 0 미만 또는 평탄화 배열 크기 이상이면:

  ```
  [unity-assets:pick] error: index <N> out of range (max <M>)
  ```

  M = 평탄화 배열의 마지막 유효 인덱스(`length - 1`). exit 1.

### Step 4 — feedback.jsonl 한 줄 조립

선택된 후보의 정보로 다음 객체를 만든다 (`schemas/feedback-row.json.schema.json` 통과 필요).

```json
{
  "ts": "<현재 ISO-8601 UTC, 예: 2026-05-24T13:45:01Z>",
  "query": "<search-result.json::query 또는 .meta::query 등 search 입력 원본>",
  "sub_intent_id": "<선택된 후보가 속한 group의 sub_intent 문자열>",
  "picked_guid": "<선택된 후보의 guid>",
  "candidate_guids": ["<같은 sub_intent의 모든 top-K 후보 guid>"],
  "confidence_before": <선택된 후보의 confidence (0..1)>,
  "confidence_after": <min(1.0, confidence_before + 0.10)>,
  "source": "pick"
}
```

**`query` 필드 소스**: `search-result.json`에 `query` top-level 필드가 있으면 그 값을 사용. 없으면 `manifest_version`을 fallback으로 사용 (스키마 통과 위한 비공식 보장 — 실제 query 복원이 어려울 때 분석 가능한 임의 문자열).

**`sub_intent_id` 필드**: 본 스킬은 선택된 후보가 속한 group의 `sub_intent` 문자열을 그대로 사용 (search-routing.json의 sub_intents[i].intent와 동일).

### Step 5 — atomic append (락 + Add-Content)

- 대상 경로: `<unity-project>/.claude/unity-asset-index/feedback.jsonl`.
- 디렉터리 부재 시 `New-Item -ItemType Directory -Force`로 생성.
- 락 파일 패턴(CONVENTION.md §2.5 예외):
  1. 락 파일 `<feedback.jsonl>.lock`을 atomic 생성 시도: `New-Item -ItemType File -ErrorAction Stop`. 이미 존재(다른 호출 중)면 50ms `Start-Sleep -Milliseconds` 후 최대 3회 재시도.
  2. 3회 모두 실패 시:
     ```
     [unity-assets:pick] error: feedback.jsonl locked
     ```
     exit 1.
  3. 락 획득 시: 한 줄 JSON(개행 1자) 을 `Add-Content -Path <feedback.jsonl> -Value <line> -Encoding utf8`로 append.
  4. finally 블록에서 락 파일 제거 (`Remove-Item <lock> -Force -ErrorAction SilentlyContinue`).
- `Add-Content`는 OS append 시맨틱을 활용하므로 짧은 동시 호출에서도 한 줄 단위 atomicity가 보장된다 (Windows는 `WriteFile` 단일 호출에 매핑).

### Step 6 — 정상 종료

stdout에 정확히:

```
[unity-assets:pick] recorded: <picked_guid>
```

후 exit 0.

## 산출 파일

- `<unity-project>/.claude/unity-asset-index/feedback.jsonl` — append only, 한 줄당 한 pick.
- (선택) 동작 중 짧게 존재: `<feedback.jsonl>.lock`. 정상 종료 시 즉시 제거.

본 스킬은 `search-result.json`을 **수정하지 않는다**. 후속 narrowing은 `feedback.jsonl`을 통해 다음 검색에 prompt hint로 전달될 뿐, 현재 search-result는 그대로 유지된다.

## 실패 모델

| 사유 | stdout 한 줄 | exit |
|------|--------------|------|
| `search-result.json` 부재 | `[unity-assets:pick] error: no search result; run /unity-assets:search first` | 1 |
| `manifest_version` 불일치 또는 `manifest.json` 부재 | `[unity-assets:pick] error: stale search result; reindex required` | 1 |
| row-index 범위 밖·비정수 | `[unity-assets:pick] error: index <N> out of range (max <M>)` | 1 |
| 락 contention 3회 실패 | `[unity-assets:pick] error: feedback.jsonl locked` | 1 |
| 정상 | `[unity-assets:pick] recorded: <guid>` | 0 |

## 진전된 CRIT-*

- **CRIT-SCH8 (Pick command 동작)**: row-index lookup + manifest_version 핸드셰이크 + feedback.jsonl 한 줄 append + 정확한 stdout 메시지 4종(에러 3 + 성공 1). `tests/unit/test-pick-command.ps1`이 fixture 3종(valid / stale / empty)에서 단언.
- **CRIT-EVAL3 (feedback.jsonl 스키마)** 부분 진전: 본 스킬이 schema-valid 행을 생성한다. 행 단위 스키마 검증 정확도는 `tests/unit/test-feedback-jsonl.ps1`이 별도로 단언한다.

## 연계 문서

- 행 스키마: `schemas/feedback-row.json.schema.json` (Wave 2 신규).
- 다음 검색의 prompt hint 활용: `skills/unity-assets-search/SKILL.md` Step 4.0.5 "Past picks hint".
- feedback.jsonl 손상 감지: `skills/unity-assets-doctor/SKILL.md` 검사 5.
- atomic append 예외 규약: CONVENTION.md §2.5 "feedback.jsonl append-only 예외".
- manifest_version 핸드셰이크: CONVENTION.md §6.1.

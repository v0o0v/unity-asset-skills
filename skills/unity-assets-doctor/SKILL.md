---
name: doctor
description: unity-asset-skills 설치·환경 read-only 헬스체크. 5개 의존성 (Unity Editor reachable via MCP / unity-mcp-skill 글로벌 skill 존재 / 프로젝트 .claude/ 구조 / unity-assets.yml valid / feedback.jsonl 행 스키마)을 검사하고 ✓/✗ + 권장 조치 출력. 어떤 파일도 수정·생성·삭제하지 않는다. 자동 fix는 V1 범위 외.
---

# /unity-assets:doctor — 설치·환경 헬스체크

## 책임 범위

`unity-asset-skills` 사용 전에 환경이 5가지 의존성 모두 만족하는지 read-only로 검사한다. 실패 시 어떤 항목이 문제인지 그리고 어떻게 고칠 수 있는지 권장 조치를 출력한다. 자동 fix·자동 설치·자동 디렉터리 생성은 모두 V1 범위 외. 검사 5(feedback.jsonl)는 Wave 2 신규이며 파일 부재 시 PASS로 처리(선택적 데이터)되어 기존 CRIT-DOC1 4개 검사 계약을 깨지 않는다.

## 호출 패턴

- `/unity-assets:doctor` — 인자 없음. cwd 기준 검사.

## 사전 조건

cwd가 Unity 프로젝트 루트일 것이라 **추정**한다. 추정이 틀리면 검사 3번에서 ✗가 나온다 (정상 동작).

## 검사 항목 (5가지)

각 항목은 PASS / FAIL 두 결과만 가진다. 출력은 5행 체크리스트(검사 5는 Wave 2 신규).

### 검사 1 — Unity Editor reachable via MCP for Unity

- **방법**: `unity-mcp-orchestrator` 스킬을 경유하여 MCP for Unity의 비-파괴 read 도구 한 번 호출. 후보: `mcp__manage_scene` (조회 액션) 또는 `mcp__read_console`.
- **PASS**: 도구 호출이 1번에 성공하고 응답을 받음.
- **FAIL**: 도구 미발견 또는 호출 실패 또는 5초 타임아웃.
- **권장 조치 (FAIL 시 한 줄)**: `Unity Editor 실행 후 5초 대기. 그래도 실패하면 https://github.com/CoplayDev/unity-mcp#troubleshooting 참조.`

### 검사 2 — unity-mcp-skill global skill present

- **방법**:
  1. `~\.claude\skills\unity-mcp-skill\SKILL.md` 파일 존재 확인 (Read).
  2. YAML frontmatter의 `name:` 필드 추출.
  3. `name: unity-mcp-orchestrator`이어야 함 (CONVENTION.md §8의 disambiguation 규칙).
- **PASS**: 파일 존재 AND name 값 일치.
- **FAIL**: 파일 부재 또는 name 불일치 (다른 이름이면 사용자에게 무엇이 발견됐는지 표시).
- **권장 조치**: `Unity 메뉴 > MCP for Unity > Skill Sync > Sync now. 동기화 후 ~\.claude\skills\unity-mcp-skill\ 에 SKILL.md (name: unity-mcp-orchestrator)가 생성됨.`

### 검사 3 — Project .claude/ structure ready

- **방법**:
  1. cwd에 `Assets/` 디렉터리 존재 확인 (Unity 프로젝트 루트인지).
  2. cwd에 `.claude/` 디렉터리 존재 확인 (없어도 PASS — `/unity-assets:index` 첫 실행이 자동 생성하므로).
- **PASS**: `Assets/` 존재 (그리고 선택적으로 `.claude/`).
- **FAIL**: `Assets/` 부재 — 현재 cwd가 Unity 프로젝트 루트가 아님.
- **권장 조치**: `Unity 프로젝트 루트로 cd 후 /unity-assets:doctor 재실행. 그 다음 /unity-assets:index 한 번 실행하면 .claude/unity-asset-index/ 디렉터리가 자동 생성됨.`

### 검사 4 — unity-assets.yml valid (+ unity-assets.labels.yml 옵션)

- **방법**:
  1. `.claude/unity-assets.yml` 파일 존재 확인. 부재 → "사용자 override 없음, 기본값 사용 예정"으로 PASS (선택적 설정).
  2. 존재하면 YAML parse 시도. parse 실패 → FAIL.
  3. parse 성공하면 키 셋 검증: `examples/unity-assets.yml`의 인정 키 (`index_depth`, `confidence_threshold.auto`, `confidence_threshold.confirm`, `batch_size`, `parallel_subagents`, `max_assets_in_context`, `ignore_paths`, `safety_mode`) 외에 모르는 최상위 키가 있으면 경고로 보고하되 PASS (forward compatibility).
  4. 알려진 키의 값 타입 검증 (예: `batch_size`가 integer인지). 타입 불일치 → FAIL.
  5. **부가 점검 — curated labels yml (Wave 1 / CRIT-IDX7)**: `.claude/unity-assets.labels.yml` 파일 존재 확인. 부재 → 본 부가 점검을 skip (PASS에 영향 없음, 선택적 설정).
  6. 존재하면 YAML parse 시도. parse 실패 → FAIL (검사 4 전체가 FAIL로 강등).
  7. parse 성공하면 `schemas/curated-labels.json.schema.json`으로 스키마 검증 (`version == 1`, `labels`는 glob → string[] 매핑). 스키마 불일치 → FAIL.
- **PASS**: (unity-assets.yml 부재 또는 valid) AND (unity-assets.labels.yml 부재 또는 스키마 검증 통과).
- **FAIL**: unity-assets.yml parse/타입 실패, 또는 unity-assets.labels.yml parse 실패, 또는 unity-assets.labels.yml 스키마 검증 실패.
- **권장 조치**: `<플러그인 설치 경로>\examples\unity-assets.yml 을 프로젝트 .claude\ 로 복사 후 필요한 키만 수정. 또는 .claude/unity-assets.yml 을 삭제하면 기본값 사용. unity-assets.labels.yml 검증 실패 시 docs/samples/unity-assets.labels.example.yml 참고 후 schemas/curated-labels.json.schema.json에 맞춰 수정.`

### 검사 5 — feedback.jsonl 행 스키마 (Wave 2 신규, CRIT-EVAL3 연계)

- **방법**:
  1. `<unity-project>/.claude/unity-asset-index/feedback.jsonl` 파일 존재 확인. 부재 → "아직 누적된 사용자 pick 없음 — `/unity-assets:pick`이 첫 호출 시 자동 생성"로 PASS (선택적 데이터, CRIT-DOC1 backward-compatible 핵심).
  2. 존재하면 한 줄씩 파싱. 각 행은 JSON 객체여야 하고 `schemas/feedback-row.json.schema.json`을 통과해야 함 (required 필드 8개·pattern·enum 검증).
  3. 검증 결과를 `<ok-lines>/<total>` 와 `<corrupted>` 카운트로 집계.
- **PASS**: 파일 부재 OR (총 N행 중 ok-lines >= 1 AND corrupted = 0).
- **FAIL**: 파일 존재 AND (ok-lines = 0 OR corrupted >= 1).
- **권장 조치 (FAIL 시)**: `feedback.jsonl이 손상된 행을 포함하고 있음. 손상 행은 search hint에서 자동 skip되지만, 누적 학습이 약화됨. 백업 후 .claude/unity-asset-index/feedback.jsonl을 삭제하면 다음 /unity-assets:pick 호출이 빈 파일로 새로 시작.`
- **stdout 라인 형식** (양호 시):
  ```
  ✓ feedback.jsonl: 18/18 rows valid, 0 corrupted
  ```
  파일 부재 시:
  ```
  ✓ feedback.jsonl: not yet present (OK)
  ```
- **계약**: 본 검사는 어떤 파일도 수정·삭제하지 않는다 (read-only enforcement).

## 출력 형식

stdout에 정확히 5행:

```
✓ Unity Editor reachable via MCP for Unity
✓ unity-mcp-skill global skill present (name: unity-mcp-orchestrator)
✓ Project .claude/ structure ready
✓ unity-assets.yml valid (또는: 파일 없음 — 기본값 사용)
✓ feedback.jsonl: <ok>/<total> rows valid, <corrupted> corrupted (또는: not yet present)
```

또는 한 줄 이상이 ✗인 경우:

```
✓ Unity Editor reachable via MCP for Unity
✗ unity-mcp-skill global skill present
  → Unity 메뉴 > MCP for Unity > Skill Sync > Sync now.
✓ Project .claude/ structure ready
✓ unity-assets.yml valid
✓ feedback.jsonl: not yet present (OK)
```

종료 코드:
- 5/5 ✓ → 0
- 하나라도 ✗ → 1

## 안전선 (read-only)

doctor는 **어떤 파일도 수정·생성·삭제하지 않는다**. 검사 4에서 `.claude/unity-assets.yml`이 손상되었어도 doctor가 자동 복구하지 않으며, 사용자에게 권장 조치만 알린다. 검사 5에서 `feedback.jsonl`이 손상되었어도 doctor는 행 카운트만 보고하고 파일을 건드리지 않는다. CRIT-DOC1이 이 read-only 속성을 fixture 디렉터리 mtime 합계 변화 없음으로 검증한다.

## 진전된 CRIT-*

- **CRIT-DOC1 (Doctor 진단 정확도)**: 4개 의존성 fault-injection fixture에서 정확히 망가뜨린 항목만 ✗로 식별, 권장 조치 문구가 명세서 진단 표와 일치, read-only 동작 (mtime 합계 무변화). Wave 2의 5번째 검사(feedback.jsonl)는 기존 4개 검사 계약을 깨지 않도록 파일 부재 시 PASS로 처리한다.
- **CRIT-EVAL3 (feedback.jsonl 스키마)** 부분 진전: 본 스킬 검사 5가 `schemas/feedback-row.json.schema.json` 행 단위 검증을 수행한다. test-feedback-jsonl.ps1이 schema 검증 정확도를 별도로 단언.

## 연계 문서

- 권장 조치 문구는 README.md "설치 단계가 실패할 때 진단" 표 4행과 1:1 동기.
- 검사 2의 `name: unity-mcp-orchestrator`는 CONVENTION.md §8의 disambiguation에서 정의.
- 검사 5의 행 스키마는 `schemas/feedback-row.json.schema.json` (Wave 2 신규).

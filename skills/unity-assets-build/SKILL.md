---
name: build
description: Confidence-gated Orchestrator — search-result.json 기반으로 sub-intent별 auto / confirm / reject 분기. 신선한 search-result.json 없으면 R3 안내 한 줄 출력 후 /unity-assets:search 자동 호출. scene/prefab/ScriptableObject/script 생성까지 허용, AssetDatabase 삭제·이동·Build 설정 금지 (이중 prompt + audit enforcement). unity-mcp-orchestrator 스킬에 위임. 모든 MCP 호출은 orchestrator-audit.jsonl에 append.
---

# /unity-assets:build — Confidence-gated Orchestrator

## 책임 범위

Search가 작성한 `search-result.json`을 읽고, sub-intent별 confidence에 따라 자동 적용 / 사용자 확인 / 거부 분기를 수행한다. 자동 분기는 `unity-mcp-orchestrator` 스킬을 경유하여 scene·prefab·ScriptableObject·script를 생성한다. 파괴적 작업은 prompt + audit 이중 layer로 차단한다.

CONVENTION.md §6.1 (manifest_version 핸드셰이크), §9 (R3 preflight), §10 (이중 scope enforcement)를 진실원으로 참조한다.

## 호출 패턴

- `/unity-assets:build "<자연어 요청>"` — 단일-입력 흐름. 내부에서 필요 시 `/unity-assets:search`를 자동 호출.

## 사전 조건

1. cwd가 Unity 프로젝트 루트.
2. `/unity-assets:doctor` 4/4 ✓ (사용자가 직접 사전 확인 권장).
3. MCP for Unity와 `unity-mcp-orchestrator` 스킬이 가용.

## 실행 흐름

### Step 1 — preflight + R3 안내 (CRIT-EE1의 단일-입력 흐름 핵심)

`<unity-project>/.claude/unity-asset-index/search-result.json`을 확인.

다음 중 하나라도 해당하면 **신선하지 않음**:
- 파일 부재.
- `search-result.json::manifest_version` 누락.
- `search-result.json::manifest_version != manifest.json::version`.
- `search-result.json.mtime < state.json::last_run` (인덱스가 그 사이 갱신됨).

신선하지 않으면 **subagent fan-out 전에** stdout에 정확히 다음 한 줄 출력:

```
[unity-assets:build] No fresh search-result.json — running :search first (Ctrl+C to abort).
```

이 한 글자도 변경 금지 (`tests/e2e/test-ee1-zombie-survival.ps1`가 string match로 단언). 출력 후 사용자 원본 자연어 입력으로 `/unity-assets:search`를 자동 호출.

재-Search 후에도 소비 시점 `manifest_version` 불일치가 감지되면 사유 코드 `stale_search`로 거부하고 `/unity-assets:reindex` 권고 출력 후 중단.

### Step 2 — 설정 로드

`.claude/unity-assets.yml` 또는 기본값:
- `confidence_threshold.auto` (기본 0.70)
- `confidence_threshold.confirm` (기본 0.40)

### Step 3 — 각 sub-intent group 처리

`search-result.json::groups`를 순회. 각 그룹에 대해:

1. `max_confidence = max(group.candidates[].confidence)`.
2. 분기:
   - `max_confidence >= auto` → **auto 분기** (Step 4).
   - `max_confidence >= confirm` → **confirm 분기** (Step 5).
   - else → **reject 분기** (Step 6).

### Step 4 — auto 분기

1. 그룹의 top candidate (confidence 가장 높은 것)를 선택.
2. sub-intent + 선택된 에셋 정보 + CONVENTION.md §10.1의 금지 튜플 목록을 prompt에 임베드한 subagent 호출:
   ```
   Task(
     subagent_type="general-purpose",
     model="sonnet",
     prompt="<Orchestrator 계획 instructions + 금지 튜플 + sub-intent + 에셋 정보>"
   )
   ```
3. subagent는 `unity-mcp-orchestrator` 스킬을 호출하여 MCP for Unity 도구 (`manage_scene`, `manage_gameobject`, `manage_prefabs`, `create_script` 등)로 실제 작업 수행.
4. 모든 MCP 호출은 한 줄 JSON으로 `<unity-project>/.claude/unity-asset-index/orchestrator-audit.jsonl`에 append (CONVENTION.md §10.2):
   ```json
   {"ts":"2026-05-23T10:11:12Z","sub_intent":"...","tool":"manage_scene","action":"set_active","args_digest":"sha256:..."}
   ```
5. subagent가 `scope_violation`을 emit하면 즉시 중단하고 사용자에게 사유 보고.

### Step 5 — confirm 분기

1. 후보 dialog를 사용자에게 stdout으로 제시:
   - 각 후보의 path, confidence, reasoning (풀-피델리티).
   - 사용자 입력 대기 (선택 번호 또는 abort).
2. 사용자가 선택하면 Step 4의 auto 분기와 동일한 흐름.

### Step 6 — reject 분기

1. "이 sub-intent에 대해 적합 후보 없음" stdout 보고.
2. 가장 가까운 후보 1~3개를 reasoning과 함께 제시 (사용자가 의도를 재정의할 수 있도록).
3. 사용자에게 다음 행동 제안: 쿼리 수정 → `/unity-assets:search` 재실행, 또는 `/unity-assets:reindex`.

### Step 7 — 실행 종료 요약

모든 sub-intent 처리 완료 후 stdout에 한 줄 요약:
- sub-intent별 verdict (`auto applied` / `user confirmed and applied` / `user rejected` / `no fit`).
- audit 로그 라인 수.
- 다음 행동 제안 (예: "씬에 추가된 에셋 확인 후 git diff로 검토하세요").

## 이중 scope enforcement (CONVENTION.md §10)

### Layer 1 — prompt-level 금지 튜플

Orchestrator subagent prompt에 다음 금지 튜플 목록을 명시:

- `(AssetDatabase, Delete)`
- `(AssetDatabase, MoveAsset)`
- `(Editor, EnvSettings)`
- `(Build, *)`

MCP for Unity 도구 면에서의 매핑:
- `manage_assets(action="delete"|"move"|"rename")`
- `manage_editor` 환경설정 변경
- `manage_build` 전체
- `execute_menu_item` 중 `File/Build*`
- `manage_packages(action="remove_package")`

subagent는 이들 중 하나를 만드는 계획 단계를 거부하고 `scope_violation` emit.

### Layer 2 — audit-level

모든 unity-mcp 호출은 `orchestrator-audit.jsonl`에 append. 실행 종료 후 (또는 `tests/unit/test-scope-guard.ps1` 실행 시) audit 로그를 스캔하여 금지 튜플 0건 단언. 두 layer는 보완 관계.

## manifest_version 핸드셰이크 (CONVENTION.md §6.1)

- 입력 시점: `search-result.json::manifest_version == manifest.json::version` 확인.
- 소비 중 인덱스 갱신으로 불일치 발생 가능성 매우 낮음 (사용자 단일 세션 가정), 그러나 R3 안내 후 재-Search한 결과도 다시 확인.
- 불일치 → 사유 코드 `stale_search`로 거부 + 사용자에게 `/unity-assets:reindex` 권고 + 종료.

## 외부 의존성 호출 실패 (`mcp_unavailable`)

- `unity-mcp-orchestrator` 스킬 미존재 또는 MCP for Unity 도구 호출 실패 → 즉시 중단, 사유 코드 `mcp_unavailable` + 사용자에게 사전 조건 설치 안내 (README + [CoplayDev/unity-mcp](https://github.com/CoplayDev/unity-mcp) 링크).

## 산출 파일

- `<unity-project>/.claude/unity-asset-index/orchestrator-audit.jsonl` (append-only)
- Unity 프로젝트 안의 신규 scene·prefab·SO·script 파일 (unity-mcp가 작성)

## 진전된 CRIT-*

- **CRIT-EE1 (End-to-end)**: 단일-입력 흐름 (Search 자동 호출 + sub-intent 분해 + confidence 분기 + scene/prefab 생성).
- **CRIT-ORC1 (라우팅 정확도)**: Search 출력의 sub-intent 처리 (R2 복합 임계치는 테스트 단계).
- **CRIT-ORC2 (Confidence gate)**: auto / confirm / reject 분기 정확.
- **CRIT-ORC3 (Scope guard)**: 이중 prompt + audit, 금지 튜플 0건.
- **CRIT-ORC4 (Search→Orch 계약)**: `confidence` + `reasoning` (풀-피델리티) + `manifest_version` 모두 검증.

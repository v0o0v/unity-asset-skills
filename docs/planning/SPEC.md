# Deep Interview 명세서: Unity 에셋 인지형 Claude Code 스킬 세트

## 메타데이터
- 인터뷰 ID: di-unity-asset-skills-2026-05-23
- 라운드 수: 21 (Round 0 토폴로지 + 20 본 라운드)
- 최종 모호도: **9%** (전역 가중 평균) / **12%** (최약 컴포넌트 — Convention)
- 유형: greenfield (기설치된 글로벌 `unity-mcp-skill`에 의존)
- 생성 일자: 2026-05-23
- 임계치: 0.20 (20%) — 사용자가 인터뷰 중 10%로 강화 요청
- 임계치 출처: default (`settings.json`에 override 없음, 인터뷰 중 구두 강화)
- 초기 컨텍스트 요약 여부: no
- 상태: PASSED (전역 모호도 9% < 사용자가 강화한 목표 10%)

## 명료도 분해
| 차원 | 점수 | 가중치 | 가중 점수 |
|------|------|--------|-----------|
| 목표 명료도 | 0.92 | 0.40 | 0.368 |
| 제약 명료도 | 0.89 | 0.30 | 0.267 |
| 합격 기준 | 0.93 | 0.30 | 0.279 |
| **총 명료도** | | | **0.914** |
| **모호도** | | | **0.086** |

## 토폴로지

| 컴포넌트 | 상태 | 설명 | 커버리지 / 보류 사유 |
|----------|------|------|----------------------|
| Asset Indexer | active | Unity 프로젝트의 에셋을 filesystem 스캔으로 2-layer (package summary + asset detail) shallow 인덱스 생성. 의미 태그·요약은 **Claude Code 내부 batch subagent**가 N개씩 묶어 M개 병렬로 추출 (외부 API 없음). unity-mcp는 on-demand deep-fetch로 보조. | 4개 합격 기준 (coverage, idempotency, incremental accuracy, subagent failure recovery) |
| Asset Search | active | LLM-as-Search가 shallow 인덱스를 직접 읽어 후보 선택. 1차 라우팅(multi-category 판단) → 필요 시 sub-intent 분해 → 2차 retrieval. Package-first drill-down이 기본, 2000+ 에셋 또는 `index_depth=rich`이면 map-reduce chunking 자동 전환. | 4개 합격 기준 (recall@3 골든셋, drill-down 정확도, malformed query graceful, Indexer fallback 계약) |
| Game Build Orchestrator | active | Confidence-gated hybrid 분기 (auto ≥ 0.70 / confirm ≥ 0.40 / reject < 0.40). Round 9 scope C 범위: scene/prefab/script/ScriptableObject 생성까지 자동 허용. | 4개 합격 기준 (multi-intent 라우팅, confidence gate 분기, unity-mcp 호출 범위 준수, Search→Orch 계약) |
| Skill Set Convention | active | 글로벌 Claude Code 플러그인 (`plugin.json` + `skills/` + `agents/` + `AGENTS.md`) + 프로젝트 로컬 메타데이터 `.claude/unity-asset-index/` + 프로젝트 `.yml` override `unity-assets.yml`. 단계적 스키마 (minimal/normal/rich). 4개 스킬 (`:index`, `:search`, `:build`, **`:doctor`** — 설치·환경 진단) + 1개 자체 subagent + CONVENTION.md 문서 구성. OMC 등 외부 오케스트레이션 레이어에 의존하지 않음. Windows 지원 우선 (다른 OS는 V1 범위 외). | 4개 합격 기준 (schema-doc sync lint, plugin manifest 검증, cross-skill 계약 테스트, .yml override 테스트) |

## 목표

unity-mcp 위에 얹는 **재사용 가능한 Claude Code 플러그인** 한 개를 만든다 (OMC 등 외부 오케스트레이션 레이어에 의존하지 않음). 플러그인은 Unity 프로젝트의 기설치 에셋(Asset Store 패키지 포함)을 사전 인덱싱하여 의미 태그가 부여된 shallow 메타데이터 DB로 보관한다. 의미 태그 생성은 외부 API가 아닌 **Claude Code 세션 내부의 배치 subagent**가 처리하므로 별도 API 비용·키 관리가 발생하지 않는다. 사용자가 Claude Code에 자연어 요청을 했을 때, 플러그인은 해당 인덱스를 LLM-as-Search로 활용해 다중 카테고리 의도를 자동 분해하고 적합한 에셋 후보를 confidence 점수와 함께 식별한 뒤, Orchestrator가 confidence 임계치에 따라 자동 적용(scene/prefab/script 생성 포함) 또는 사용자 확인 분기로 실제 게임 제작 단계에 통합한다.

## 제약

### 실행 모델 (Round 15 정정)
- **분석 매체**: 모든 의미 분석·태깅·검색은 **Claude Code 세션 내부에서 수행**. 외부 Anthropic API 호출이나 별도 API 키는 불필요. 사용자의 Claude Code 구독 내에서 동작.
- **Batch Subagent 패턴**: Indexer는 `Task(subagent_type=...)`로 N개의 자식 subagent를 띄워 병렬 처리. 기본값 `batch_size=20, parallel_subagents=10` → 한 wave 당 최대 200 에셋 처리. 200 미만이면 1 wave, 그 이상이면 다중 wave.
- **컨텍스트 보존**: 메인 에이전트의 컨텍스트는 subagent 결과(요약된 메타데이터)만 회수. raw 파일 내용은 subagent 안에서만 다루고 메인에는 올라오지 않음.

### 인덱싱
- **1차 수집**: filesystem 직접 파싱 (`.meta` + 주요 에셋 파일). Editor가 항상 떠 있을 필요 없음.
- **2차 수집**: on-demand로 unity-mcp 호출하여 deep-fetch (preview, dependency graph 등). Search가 후보를 좁힌 시점에만 발동.
- **재인덱스 트리거**: 수동 명령 우선 + 파일 시그니처(GUID/mtime) 비교 기반 증분 자동 감지. CI/file watcher는 V1 범위 외.
- **프로젝트 규모 가정**: 평균 200개 / 최대 1000개 1차 대상. 1000개 초과는 `index_depth=minimal` + chunking으로 대응.
- **실패 모델**: subagent 단위 checkpoint. 각 batch subagent의 결과는 완료 시점에 `state.json`에 commit. 도중 실패 시 다음 실행이 미완료 batch만 재시도.

### 검색
- **매커니즘**: LLM-as-Search (embedding / 벡터 DB / BM25 인프라 없음). Claude 컨텍스트에 인덱스 요약 테이블을 전달하고 직접 선택.
- **Multi-intent**: Search가 1차로 "다중 카테고리 요청인가" 판단 → yes면 sub-intent 분해 후 카테고리별 retrieval → no면 단일 검색. Orchestrator는 Search의 결과 모양만 보고 동작.
- **Sharding (큰 인덱스)**: 기본은 package-first hierarchical drill-down (Package summary → 후보 패키지의 Asset만). `index_depth=rich` 또는 `assets_count > 2000`이면 map-reduce sliding chunks로 자동 전환.
- **컨텍스트 윈도우 보호**: Search 단일 호출이 컨텍스트에 받아들이는 최대 row 수를 `max_assets_in_context`로 제한 (기본 500).

### 자동화
- **Action scope**: scene 조작 + 새 prefab/ScriptableObject/세팅 스크립트 생성까지 허용 (Round 9 C 수위). AssetDatabase 삭제·`.meta` 직접 수정 등은 금지.
- **Confidence 임계치 기본값**: `auto ≥ 0.70` / `confirm ≥ 0.40` / `reject < 0.40`.
- **안전망**: 사용자 책임. 스킬은 별도 git 스냅샷·dry-run 강제 없음. README에 "git으로 관리하세요" 명시. (Round 10 D, 의도된 단순화)

### 레이아웃 / 재사용
- **스킬 로직**: 글로벌 (Claude Code 플러그인). 4개 슬래시 커맨드 제공: `/unity-assets:index`, `/unity-assets:search`, `/unity-assets:build`, `/unity-assets:doctor`.
- **메타데이터 캐시 + per-project 설정**: 프로젝트 로컬 `.claude/unity-asset-index/` + `.claude/unity-assets.yml`.
- **스키마**: 기본 minimal (7 필드), `.yml`의 `index_depth: minimal|normal|rich`로 프로젝트별 normal/rich 확장.

### 지원 플랫폼
- **Windows 우선 (V1 범위)**: 모든 검증·문서·테스트 스크립트는 PowerShell 기준. 경로 표기는 `C:\...` / `D:\...` 또는 `~\.claude\...`.
- macOS / Linux: V1 범위 외. 파이프라인 로직 자체는 OS-중립이라 추후 확장 가능하지만 V1 보장 없음.

### 의존성

본 플러그인이 동작하려면 사용자 환경에 다음 두 가지가 사전 설치되어 있어야 한다. 둘은 별개이며 역할이 다르다.

1. **MCP for Unity** ([CoplayDev/unity-mcp](https://github.com/CoplayDev/unity-mcp), MIT) — Unity Editor와 LLM(Claude 등) 사이의 **실제 MCP 브릿지**. 두 부분으로 구성:
   - **Unity 패키지** (UPM): Unity 프로젝트에 설치. Package Manager에서 git URL `https://github.com/CoplayDev/unity-mcp.git?path=/MCPForUnity#main` 추가 또는 Asset Store / OpenUPM(`com.coplaydev.unity-mcp`).
   - **Python MCP 서버**: Python 3.10+ + `uv`로 실행. AI 클라이언트(Claude Code)가 MCP 프로토콜로 이 서버에 연결.
   - 요구 사양: Unity 2021.3 LTS+, Python 3.10+, uv 패키지 매니저.
   - 제공 도구: `manage_gameobject`, `manage_scene`, `manage_assets`, `manage_prefabs`, `manage_camera`, `manage_packages`, `manage_physics`, `manage_animation`, `manage_graphics`, `manage_build`, `manage_editor`, `create_script`, `script_apply_edits`, `validate_script`, `delete_script`, `apply_text_edits`, `get_sha`, `find_gameobjects`, `read_console`, `execute_menu_item`, `batch_execute`, `unity_reflect`, `unity_docs` 등 (v9.6.x 시점). 이 도구들이 Orchestrator(`:build`)가 실제로 호출하는 surface.
2. **`unity-mcp-skill`** — 위 MCP for Unity 도구들을 안전하게 쓰기 위한 **Claude Code 글로벌 skill (오퍼레이터 가이드)**. 위치: `~/.claude/skills/unity-mcp-skill/` (SKILL.md의 YAML `name:`은 `unity-mcp-orchestrator`). MCP 통신 자체를 하지 않으며 도구 스키마·워크플로 패턴·best practice만 제공. 본 플러그인의 subagent는 이 guide를 참조하여 MCP for Unity 도구를 호출.

본 플러그인 자체는 Unity 바인딩이나 MCP 통신을 재구현하지 않는다. 위 두 의존성이 누락된 환경에서는 Indexer의 filesystem 1차 수집까지는 동작하지만 unity-mcp deep-fetch와 Orchestrator의 scene/prefab 조작은 실패한다 (CRIT-SCH4의 fallback 경로로 사용자에게 명확한 안내 출력).

전제: 위 두 의존성은 본 플러그인의 패키지 스코프 밖이며 사용자가 README의 사전 조건 절차에 따라 직접 설치한다. CRIT-* 자동 검증은 `unity-mcp-skill` 호출을 stub하므로 Unity Editor 미실행 상태에서도 통과한다.

## 비목표 (Non-Goals)

- 외부 API (Anthropic 등) 직접 호출 — 모든 분석은 Claude Code 내부
- 벡터 임베딩 / 외부 벡터 DB
- File watcher / 자동 재인덱스 데몬
- 자동 rollback / git 자동 커밋 / dry-run 강제 (사용자 책임)
- Asset Store API 연동 (downloaded 로컬 파일만 처리)
- 에셋 라이선스 검증
- Multi-project 동시 인덱싱
- 인덱스 비용 사전 견적 dialog

## 합격 기준 (Acceptance Criteria)

### CRIT-EE (End-to-end, Round 8 A)
- [ ] **CRIT-EE1**: 50~200 에셋 테스트 Unity 프로젝트에서 자연어 요청 "top-down 좀비 survival 게임 프로토타입 만들어줘" 한 줄로, 스킬이 (1) 재인덱스 필요성 판정 → (2) Search 라우팅·sub-intent 분해 → (3) confidence 분기 → (4) 실제 씬 prefab 배치까지 1명의 수행자 입력으로 성공.

### CRIT-IDX (Asset Indexer, Round 18)
- [ ] **CRIT-IDX1 — Coverage**: 테스트 Unity 프로젝트의 `.meta`가 있는 모든 자산이 100% 인덱스에 포함.
- [ ] **CRIT-IDX2 — Idempotency**: 동일 프로젝트에서 두 번 인덱싱 → 결과 파일이 시그니처(JSON normalize 후 hash) 동일.
- [ ] **CRIT-IDX3 — Incremental accuracy**: K개 파일 수정 → incremental 실행 후 정확히 K개 메타데이터만 byte 변화, 나머지 0.
- [ ] **CRIT-IDX4 — Subagent failure recovery**: 일부 batch subagent에 의도적 실패 주입 후 재실행 → 최종 `assets.jsonl` 완전 (누락 없음).

### CRIT-SCH (Asset Search, Round 8 C + 20)
- [ ] **CRIT-SCH1 — Recall@3**: 사전 라벨링된 골든 쿼리 10개 중 8개 이상에서 정답 에셋이 top-3 안에 포함.
- [ ] **CRIT-SCH2 — Drill-down 자동 전환**: 1000+ 에셋 더미 프로젝트에서 map-reduce 자동 전환이 일어나고, 그 상황에서도 골든 recall 품질 유지.
- [ ] **CRIT-SCH3 — Malformed query graceful**: 빈 쿼리·한글·이모티콘·따옴표 미스매치 시 panic 없이 명확한 사유 메시지 반환.
- [ ] **CRIT-SCH4 — Indexer fallback 계약**: 인덱스 없음·stale일 때 명시적 경고 + 사용자 옵션(reindex 권고 / 자동 호출) 제시.

### CRIT-ORC (Game Build Orchestrator, Round 19)
- [ ] **CRIT-ORC1 — 라우팅 정확도 (multi-intent)**: 사전 라벨링된 5개 쿼리 셋 (3 multi + 2 single) 중 최소 4개에서 multi/single 라우팅이 올바름.
- [ ] **CRIT-ORC2 — Confidence gate**: 고/중/저 confidence 테스트 셋 3건 모두에서 auto·confirm·reject 분기가 올바른 포지션 진입.
- [ ] **CRIT-ORC3 — unity-mcp 호출 범위 준수**: Round 9 C 범위(scene/prefab/script 생성)를 벗어나는 호출 시도 없음. AssetDatabase 삭제·`.meta` 직접 수정 호출 0회.
- [ ] **CRIT-ORC4 — Search→Orch 계약**: Search의 결과 스키마(asset+confidence+reasoning)를 Orch가 압축·소실 없이 읽음. 항상 `confidence` 필드 존재 검증.

### CRIT-DOC (Doctor 헬스체크, v6 신규)
- [ ] **CRIT-DOC1**: 4개 의존성 (Unity Editor reachable / `unity-mcp-skill` 존재 / Project `.claude/` 구조 / `unity-assets.yml` valid)을 하나씩 의도적으로 망가뜨린 fixture 4개에서, `/unity-assets:doctor`가 해당 항목만 정확히 ✗로 식별하고 권장 조치 문구를 정확히 출력. read-only 동작 검증 (실행 후 어떤 파일 변경도 발생하지 않음).

### CRIT-CNV (Skill Set Convention, Round 17)
- [ ] **CRIT-CNV1 — Schema-doc sync**: CONVENTION.md의 스키마 설명·필드 목록이 실제 생성되는 `assets.jsonl`/`packages.jsonl`과 100% 일치 (자동 린트).
- [ ] **CRIT-CNV2 — Plugin manifest**: `plugin.json`이 Claude Code 공식 plugin manifest 스펙 통과, 다른 Unity 프로젝트에 시수 설치 가능.
- [ ] **CRIT-CNV3 — Cross-skill 계약**: `:index`가 쓰는 파일을 `:search`·`:build`가 에러 없이 읽음 (동일 테스트 프로젝트에서).
- [ ] **CRIT-CNV4 — .yml override**: `unity-assets.yml`의 모든 설정(`confidence_threshold`, `batch_size`, `index_depth` 등)이 실제로 적용됨 (default→override→stick 테스트).

## 노출 및 해결된 가정

| 가정 | 도전 시점 | 해결 |
|------|-----------|------|
| "에셋 = 개별 파일" | Round 1 | 2-layer 인덱스 (package summary + asset detail) |
| "인덱싱은 filesystem만" | Round 2 | Hybrid: filesystem 1차 + unity-mcp 온디맨드 deep-fetch |
| "embedding/벡터DB가 의미 검색에 필수" | Round 3 | LLM-as-Search 채택 (추가 인프라 없음) |
| "자동화 = suggest 후 확인" | Round 4 | Confidence-gated hybrid |
| "글로벌 vs 프로젝트 로컬 이분법" | Round 5 | 로직=글로벌 / 데이터=프로젝트 로컬 / 설정=`.yml` override |
| "shallow 메타데이터로 의미 매칭 충분" (Contrarian) | Round 6 | LLM-tagging 파이프라인 추가 (처음엔 외부 Haiku로 오해) |
| "재인덱스는 매번 전체" | Round 7 | 증분 + 수동 풀빌드. 파일 시그니처 기반 변경 감지 |
| "성능·정확도 모두 acceptance" (Simplifier) | Round 8 | End-to-end + Search recall 우선, 이후 라운드에서 컴포넌트별로 확장 |
| "자동화는 씬 조작 수준에서 멈춤" | Round 9 | Full automation: script/ScriptableObject 생성까지 |
| "안전망은 자동화에 빌트인 필수" | Round 10 | 사용자 책임 (git). 의도된 단순화 |
| "스키마는 한 가지로 고정" | Round 11 | minimal/normal/rich 3단계, `.yml`로 선택 |
| "여러 스킬"의 분할 단위 | Round 12 | 3 skill + CONVENTION.md + 플러그인 wrapper |
| "단일 의도 쿼리만 처리" | Round 13 | Search가 dual-call: multi-category 라우팅 후 sub-intent 분해 |
| "인덱스 전체가 컨텍스트에 들어감" | Round 14 | Package-first drill-down 기본 + 2000+ 또는 rich 시 map-reduce 자동 전환 |
| **"태깅은 외부 Haiku API 호출"** | **Round 15 (사용자 정정)** | **Claude Code 내부 batch subagent (외부 API 없음)** |
| "기본 수치는 구현 단계에서 결정" | Round 16 | Balanced 세트 락 (`auto≥0.70` / `confirm≥0.40` / `batch=20` / `parallel=10`) |
| "Convention은 검증 어려운 doc layer" | Round 17 | 4개 검증 항목 명시 (sync lint, plugin valid, cross-skill, yml override) |
| "Indexer의 자체 검증 없음" | Round 18 | 4개 검증 항목 (coverage, idempotency, incremental accuracy, subagent recovery) |
| "Orchestrator 분기 정확도는 end-to-end로 간접 검증" | Round 19 | 4개 명시 검증 (routing, gate, scope, contract) |
| "Search는 recall만 보면 됨" | Round 20 | 4개 검증으로 확장 (recall 10개셋, drill-down 자동 전환, malformed graceful, fallback) |

## 설치 (사용자 사전 조건 + Quick Start)

V1은 **Windows 전용**. 다른 OS는 V1 범위 외 (파이프라인 자체는 OS-중립이라 확장 가능하나 V1 검증 없음).

### 사전 조건 (사용자가 일회성으로 직접 설치)

| 항목 | 버전 | 출처 |
|------|------|------|
| Unity Editor | 2021.3 LTS 이상 | [unity.com/download](https://unity.com/download) (Unity Hub 통해) |
| Python | 3.10 이상 | [python.org/downloads](https://www.python.org/downloads/) |
| uv (Python 패키지 매니저) | 최신 | [docs.astral.sh/uv](https://docs.astral.sh/uv/getting-started/installation/) |
| Claude Code | 최신 | [claude.com/claude-code](https://claude.com/claude-code) |

### Quick Start (5분 레시피)

목표: 신규 사용자가 처음부터 `/unity-assets:build "..."`까지 5분 안에 도달.

```powershell
# [1] MCP for Unity 의 Unity 패키지 설치
#     a. Unity Hub 에서 대상 프로젝트 열기
#     b. Unity 메뉴: Window > Package Manager > + > "Add package from git URL..."
#     c. 다음 URL 붙여넣기 후 Add:
#        https://github.com/CoplayDev/unity-mcp.git?path=/MCPForUnity#main
#     d. 임포트 완료 후, Unity 가 자동으로 Python MCP 서버를 부팅하고
#        "Skill Sync" 창을 띄움 (v9.4.8+). Skill Sync 의 "Sync now" 버튼으로
#        ~\.claude\skills\unity-mcp-skill\ 가 자동 설치됨.

# [2] Claude Code 의 MCP 설정에 unity-mcp 서버가 등록됐는지 확인
#     (보통 Unity 패키지가 자동 등록. 누락 시 CoplayDev/unity-mcp 의 README 참조)
#     검증: Claude Code 세션에서 mcp__manage_scene 같은 도구가 호출 가능해야 함.

# [3] unity-asset-skills (본 플러그인) 설치
claude plugins install https://github.com/<owner>/unity-asset-skills

# [4] 대상 Unity 프로젝트 루트에서 Claude Code 실행
cd D:\path\to\your\unity-project
claude

# [5] 헬스체크 — 모든 의존성이 OK 한지 확인
/unity-assets:doctor
# 기대 결과: 4개 항목 모두 ✓
#   ✓ Unity Editor reachable via MCP for Unity (mcp__manage_scene 호출 성공)
#   ✓ unity-mcp-skill global skill present (~/.claude/skills/unity-mcp-skill/SKILL.md)
#   ✓ Project .claude/ structure ready (또는 자동 생성 안내)
#   ✓ unity-assets.yml valid (없으면 examples/ 에서 복사 안내)

# [6] 첫 인덱싱
/unity-assets:index
# 200 에셋 기준 약 30초~2분 (subagent 10개 병렬, batch 20개씩)

# [7] 사용
/unity-assets:search "황폐한 중세 마을 분위기 건물"
/unity-assets:build "탑다운 좀비 survival 게임 프로토타입 만들어줘"
```

### 설치 단계가 실패할 때 진단

`/unity-assets:doctor` 가 알려주는 실패 패턴별 권장 조치:

| Doctor 출력 | 의미 | 권장 조치 |
|-------------|------|-----------|
| ✗ Unity Editor reachable via MCP | Unity Editor 미실행 또는 MCP for Unity Python 서버 미구동 | Unity Editor 열고 5초 대기 후 재시도. 그래도 실패하면 [CoplayDev/unity-mcp 트러블슈팅](https://github.com/CoplayDev/unity-mcp#troubleshooting) |
| ✗ unity-mcp-skill global skill present | `~\.claude\skills\unity-mcp-skill\` 부재 | Unity 메뉴 > MCP for Unity > Skill Sync > Sync now |
| ✗ Project .claude/ structure ready | 현재 cwd 가 Unity 프로젝트 루트가 아님 | Unity 프로젝트 루트로 이동 후 `/unity-assets:index` 한 번 실행 (`.claude/unity-asset-index/` 자동 생성) |
| ✗ unity-assets.yml valid | `.claude/unity-assets.yml` 부재 또는 손상 | `<plugin-install-path>\examples\unity-assets.yml` 을 프로젝트 `.claude/` 로 복사 |

### 비-목표 (설치 관련)

- macOS / Linux 1급 지원
- 마켓플레이스 등록 (`extraKnownMarketplaces` 사용)
- 수동 clone 경로 (`~/.claude/plugins/` 직접 git clone) 의 1급 문서화 — README 부록에 한 줄 정도만
- Unity Asset Store 경로 안내 — README 부록의 "Other install options" 로 빠짐
- 자동 사전 조건 인스톨러 (Python·uv·Unity 등 우리가 깔아주지 않음)
- 비-Windows 경로 표기 / Bash 스크립트 미러

## 기술 컨텍스트

### 전제: 두 외부 의존성 (위 의존성 섹션 상세 참조)
- **MCP for Unity** ([CoplayDev/unity-mcp](https://github.com/CoplayDev/unity-mcp)): Unity Editor와 통신하는 실제 MCP 서버. 도구 surface(`manage_gameobject`, `manage_scene`, `create_script` 등)를 제공.
- **`unity-mcp-skill`** (글로벌 Claude Code skill): 위 MCP 도구들의 사용법 가이드. 본 플러그인의 subagent가 참조.
- 본 플러그인은 두 의존성 위의 "**도메인 어휘 + 메타데이터 + 의도 매칭**" 레이어 — Unity 바인딩이나 MCP 통신을 재구현하지 않음.

### 산출물 구조

```
unity-asset-skills/                           # 새 Claude Code 플러그인 (글로벌 배포)
├── plugin.json                              # 마켓플레이스 manifest
├── README.md                                # 사용자 가이드 + git 책임 명시
├── CONVENTION.md                            # 메타데이터 스키마, 파일 경로, 명령·계약 규약
├── AGENTS.md                                # 내부 개발자용 계층형 문서
├── tests/                                   # 검증 스위트 (CRIT-* 자동화)
│   ├── fixtures/                            # 더미 Unity 프로젝트 (50, 200, 1200 에셋)
│   ├── golden-queries.yml                   # CRIT-SCH1·CRIT-ORC1 골든셋
│   └── lint/                                # CRIT-CNV1 doc-schema 린트
└── skills/
    ├── unity-assets-index/SKILL.md          # /unity-assets:index, :reindex
    ├── unity-assets-search/SKILL.md         # /unity-assets:search, :pick
    └── unity-assets-build/SKILL.md          # /unity-assets:build (Orchestrator)
```

프로젝트 로컬 (per Unity project):
```
<unity-project>/
└── .claude/
    ├── unity-assets.yml                     # per-project config override
    └── unity-asset-index/                   # 메타데이터 캐시
        ├── manifest.json                    # 인덱스 버전, 최종 실행 timestamp
        ├── packages.jsonl                   # package-level summary
        ├── assets.jsonl                     # asset-level shallow records
        ├── deep-cache/                      # on-demand unity-mcp 결과 캐시
        └── state.json                       # GUID→signature, batch progress
```

### Shallow Asset Record (minimal — 기본)
```json
{
  "guid": "abc123...",
  "path": "Assets/Packages/MedievalVillage/Prefabs/Wall_01.prefab",
  "name": "Wall_01",
  "type": "Prefab",
  "labels": ["medieval", "wall"],
  "llm_tags": ["medieval", "village", "exterior", "stone-wall"],
  "llm_summary": "중세 유럽 마을 외벽, 모듈형 석조 벽 프리팹."
}
```

### Package Record (파생)
```json
{
  "package_id": "MedievalVillage_v2.3",
  "root_path": "Assets/Packages/MedievalVillage",
  "asset_count": 87,
  "type_breakdown": {"Prefab": 42, "Material": 28, "Texture": 17},
  "llm_purpose": "모듈형 중세 유럽 마을 에셋 팩 — 외부, 벽, 소품.",
  "llm_categories": ["medieval", "environment", "exterior", "modular-architecture"]
}
```

### Indexer 흐름 (Round 15 정정 반영)

```
사용자: /unity-assets:index
  ↓
[index 스킬] state.json 읽음 → 변경된 자산 후보 N개 산출
  ↓
N ≤ batch_size? → 단일 wave
이외       → ceil(N / batch_size) wave
  ↓
각 wave: parallel_subagents개의 Task(subagent_type="oh-my-claudecode:executor", model="haiku") 병렬 호출
  └─ 각 subagent: 자기 batch (batch_size개) 파일을 filesystem으로 읽고 llm_tags + llm_summary 생성, JSONL row 반환
  ↓
메인 에이전트: subagent 결과를 누적해 assets.jsonl 작성, state.json 업데이트
  ↓
실패 batch는 다음 호출 시 자동 재시도 (state.json의 미완료 마커 기준)
```

### Search 흐름 (Round 13 + 14)

```
사용자 자연어 의도 → /unity-assets:search "..."
  ↓
[1차 라우팅] LLM: "이 요청은 multi-category? sub_intents = ?"
  ↓
multi → for each sub-intent → 2차 retrieval
single → 2차 retrieval 1회
  ↓
[2차 retrieval]
  ├─ 기본: packages.jsonl 읽음 → 관련 패키지 top-K → 해당 패키지의 assets만 읽음
  └─ index_depth=rich 또는 total_assets>2000: sliding chunks map-reduce
  ↓
출력: [{asset, confidence, reasoning}, ...] (sub-intent별 grouped)
```

### Orchestrator 흐름 (Round 4 + 9 + 16)

```
Search 결과 (sub-intent별) → 각 그룹에 대해:
  max(confidence) ≥ 0.70  → unity-mcp 통해 자동 적용 (scene 조작 / prefab·SO·script 생성)
  max(confidence) ≥ 0.40  → 후보 선택 dialog 제시, 사용자 확인 시 적용
  max(confidence) <  0.40  → "적합 후보 없음" 보고 + 최근접 후보 + 사용자에게 의도 재정의 요청
  ↓
모든 sub-intent 처리 끝나면 한 줄 요약 + 사용자 다음 행동 제안
```

### MCP for Unity 도구 호출 (실제로 거는 것)

본 플러그인이 사용할 MCP for Unity 도구 (각 도구는 unity-mcp Python 서버가 노출, `unity-mcp-skill`가이드 따라 호출):

| 사용 시점 | MCP 도구 (CoplayDev/unity-mcp) |
|-----------|-------------------------------|
| Indexer deep-fetch (메타데이터 보강) | `manage_assets` (조회 액션), `find_gameobjects`, `unity_reflect` |
| Orchestrator scene 조작 | `manage_scene`, `manage_gameobject`, `find_gameobjects` |
| Orchestrator prefab 생성·인스턴스화 | `manage_prefabs`, `manage_gameobject` |
| Orchestrator ScriptableObject·스크립트 생성 | `create_script`, `script_apply_edits`, `validate_script`, `manage_assets`(create) |
| Orchestrator 머티리얼·셰이더 적용 | `manage_assets`, `manage_graphics` |
| 검증·확인 | `read_console`, `manage_camera`(screenshot) |

명시적 비허용 (CRIT-ORC3 금지 튜플):
- `manage_assets(action="delete")` / `manage_assets(action="move")` / `manage_assets(action="rename")` — 파괴적
- `manage_editor` 의 환경설정 변경 액션
- `manage_build` 전체 — Build / Player 설정 변경
- `execute_menu_item` 중 `File/Build*` 등 위험 메뉴
- `manage_packages(action="remove_package")` — 패키지 제거

(`.meta` 직접 쓰기 도구는 unity-mcp 표면에 존재하지 않으므로 금지 목록에서 제거 — Architect iteration 1 findings 확인.)

### `unity-assets.yml` 기본 키 (Round 16 + 17 D)
```yaml
index_depth: minimal           # minimal | normal | rich
confidence_threshold:
  auto: 0.70
  confirm: 0.40
batch_size: 20                 # subagent 당 에셋 수
parallel_subagents: 10         # 동시 띄울 subagent 수
max_assets_in_context: 500     # Search가 한 LLM 호출에 받는 최대 row
ignore_paths:                  # 인덱스 제외 경로 (예: Plugins/Editor 등 사용자 정의)
  - "Assets/Plugins/Editor"
safety_mode: loose             # loose | balanced | strict (V1에선 loose만 의미 있음)
```

## 온톨로지 (핵심 엔티티)

| 엔티티 | 유형 | 필드 | 관계 |
|--------|------|------|------|
| AssetPackage | 핵심 도메인 | package_id, root_path, asset_count, type_breakdown, llm_purpose, llm_categories | 여러 Asset을 포함 |
| Asset | 핵심 도메인 | guid, path, name, type, labels, llm_tags, llm_summary | 하나의 AssetPackage에 속함 |
| Metadata | 핵심 도메인 | shallow vs deep tier, schema_version, index_depth | Asset을 기술 |
| ShallowIndex | 핵심 도메인 | 경로 `.claude/unity-asset-index/assets.jsonl` | Asset 메타데이터를 집계 |
| DeepFetch | 보조 | unity-mcp 통해 on-demand 캐시 | 선택된 Asset을 보강 |
| IntentQuery | 핵심 도메인 | 자연어 텍스트 | Search 구동 |
| RequirementBreakdown | 핵심 도메인 | Search 1차 라우팅으로 추출한 sub-intent | IntentQuery 단위 |
| ConfidenceScore | 보조 | 0.0–1.0, 임계치 게이트 적용 | SearchResult 단위 |
| SemanticTag | 보조 | 내부 subagent가 생성한 문자열 태그 | Asset의 속성 |
| IndexBudget | 외부 제약 | 세션 컨텍스트 비용 상한 | Indexer 제약 |
| IndexState | 보조 | GUID → 파일 시그니처 매핑, batch 진행 상태 | 증분 갱신 구동 |
| ActionScope | 보조 | "C-level" (파일 쓰기 허용) | Orchestrator 제약 |
| IndexDepthTier | 보조 | minimal / normal / rich | 메타데이터 스키마 결정 |
| SkillModule | 보조 | 3 skill 파일 + 1 convention 문서 + 플러그인 shell | 조합 단위 |
| BatchSubagent | 핵심 도메인 | size=N 에셋, fan-out=M 병렬 | Indexer 실행 단위 |

## 온톨로지 수렴

| 라운드 | 엔티티 수 | 신규 | 변경 | 안정 | 안정도 |
|--------|-----------|------|------|------|--------|
| 1 | 3 | 3 | 0 | 0 | N/A |
| 2 | 5 | 2 | 0 | 3 | 60% |
| 3 | 6 | 1 | 0 | 5 | 83% |
| 4 | 7 | 1 | 0 | 6 | 86% |
| 5 | 7 | 0 | 0 | 7 | 100% |
| 6 | 9 | 2 | 0 | 7 | 78% |
| 7 | 10 | 1 | 0 | 9 | 90% |
| 8 | 10 | 0 | 0 | 10 | 100% |
| 9 | 11 | 1 | 0 | 10 | 91% |
| 10 | 11 | 0 | 0 | 11 | 100% |
| 11 | 12 | 1 | 0 | 11 | 92% |
| 12 | 13 | 1 | 0 | 12 | 92% |
| 13 | 14 | 1 | 0 | 13 | 93% |
| 14 | 14 | 0 | 0 | 14 | 100% |
| 15 | 15 | 1 | 0 | 14 | 93% |
| 16 | 15 | 0 | 0 | 15 | 100% |
| 17 | 15 | 0 | 0 | 15 | 100% |
| 18 | 15 | 0 | 0 | 15 | 100% |
| 19 | 15 | 0 | 0 | 15 | 100% |
| 20 | 15 | 0 | 0 | 15 | 100% |

Round 15 이후 도메인 엔티티 추가 없음 (실행 모델 정정 후 안정 수렴).

## 인터뷰 트랜스크립트

<details>
<summary>전체 Q&A (Round 0 + 20 본 라운드)</summary>

### Round 0 (Topology)
**Q:** 4개 컴포넌트(Indexer / Search / Orchestrator / Convention) 토폴로지 OK?
**A:** "이대로 4개 컴포넌트로 진행"

### Round 1 — Indexer / Goal
**Q:** "이미 설치된 에셋"의 범위는?
**A:** "레이어 구조로 둘 다" → 2-layer (package + asset)
**모호도:** 100% → 83%

### Round 2 — Indexer / Goal
**Q:** 수집 매체 (filesystem / Editor / hybrid)?
**A:** "Hybrid: Filesystem 1차 + unity-mcp 온디맨드 deep-fetch"
**모호도:** 83% → 74%

### Round 3 — Search / Goal
**Q:** 매칭 메커니즘?
**A:** "LLM-as-Search"
**모호도:** 74% → 70%

### Round 4 — Orchestrator / Goal
**Q:** 자동화 수위?
**A:** "Confidence-gated hybrid"
**모호도:** 70% → 68%

### Round 5 — Convention / Goal
**Q:** 스킬·메타데이터 위치?
**A:** "Hybrid: 글로벌 스킬 + 프로젝트 로컬 metadata + `.yml` override"
**모호도:** 68% → 64%

### Round 6 — Contrarian (Search Constraints)
**Q:** 500+ 에셋 + 추상적 의도 대응?
**A:** "Indexer에 LLM-tagging 파이프라인 추가" (→ Round 15 정정 대상)
**모호도:** 64% → 59%

### Round 7 — Indexer / Constraints
**Q:** 재인덱스 트리거 + 규모 가정?
**A:** "증분 갱신 + 수동 전체재빌"
**모호도:** 59% → 51%

### Round 8 — Simplifier (Criteria)
**Q:** MVP 합격 기준 (A/B/C/D)?
**A:** "A + C"
**모호도:** 51% → 34%

### Round 9 — Orchestrator / Goal+Constraints
**Q:** 자동 행동 범위?
**A:** "C. 스크립트·씬 애셋 생성까지 자동"
**모호도:** 34% → 29%

### Round 10 — Orchestrator / Constraints
**Q:** Rollback 안전망?
**A:** "D. 사용자 책임 (문서화만)"
**모호도:** 29% → 24%

### Round 11 — Convention / Goal
**Q:** Asset-level 스키마?
**A:** "D. 단계적 (minimal default, `.yml`로 normal/rich)"
**모호도:** 24% → 23%

### Round 12 — Convention / Goal
**Q:** 스킬 패키징?
**A:** "D. 플러그인 스타일 (당시 OMC 플러그인 컨벤션을 모범 예시로 참조; v4에서 Claude Code 표준 플러그인 형식으로 정정, OMC 의존성 0)"
**모호도:** 23% → 22%

### Round 13 — Search+Orch / Goal
**Q:** Multi-intent 처리?
**A:** "D. 이중 호출 (Search 1차 라우팅 → sub-intent 분해)"
**모호도:** 22% → 19%

### Round 14 — Indexer+Search / Constraints
**Q:** 컨텍스트 윈도우 초과 시?
**A:** "D. 하이브리드 (Package-first drill-down 기본 + 2000+ / rich 자동 전환 map-reduce)"
**모호도:** 19% → 17%

### Round 15 — Indexer / Goal (사용자 정정)
**사용자 정정:** "분석은 클로드 코드 내부적으로 다 해야해" → 외부 Haiku API 가정 폐기
**Q (재질문):** Claude Code 내부에서 어떤 방식으로?
**A:** "C. 배치 subagent (N개씩 그룹, M개 parallel)"
**모호도:** 17% → 17% (도메인 정정 라운드, 측정값 변동 없음)

### Round 16 — Orch+Conv / Constraints
**Q:** 기본 수치 세트?
**A:** "B. 균형 세트 (auto≥0.70 / confirm≥0.40 / batch=20 / parallel=10)"
**모호도:** 17% → ~16%

### Round 17 — Convention / Criteria
**Q:** Convention 검증 항목?
**A:** "A + B + C + D" (모두 채택)
**모호도:** ~16% → 13%

### Round 18 — Indexer / Criteria
**Q:** Indexer 검증 항목?
**A:** "A + B + C + D" (모두 채택)
**모호도:** 13% → 10.5%

### Round 19 — Orchestrator / Criteria
**Q:** Orchestrator 검증 항목?
**A:** "A + B + C + D" (모두 채택)
**모호도:** 10.5% → 10%

### Round 20 — Search / Criteria + Constraints
**Q:** Search 수락 기준 확장?
**A:** "A + B + C + D" (모두 채택)
**모호도:** 10% → **9%** ✓

</details>

## 미해결 항목 (구현 단계에서 결정)

설계 방향은 바꾸지 않지만 V1 구현 진입 시 마저 정해야 하는 디테일들.

1. CONVENTION.md 안의 스키마 JSON 정확한 정의 (minimal/normal/rich 각각의 필드 목록 finalize)
2. `golden-queries.yml`의 초기 10개 쿼리·정답 라벨 (CRIT-SCH1)
3. CRIT-EE1 검증용 테스트 Unity 프로젝트의 정확한 에셋 구성 (50~200 에셋 어떻게 구성할지)
4. 1000+ 에셋 더미 프로젝트 (CRIT-SCH2 용) 자동 생성 스크립트
5. subagent prompt 정확한 wording (각 에셋 파일을 받아 `llm_tags` + `llm_summary` JSON으로 응답하도록)
6. `state.json`의 정확한 스키마 (batch progress 추적용)
7. unity-mcp 호출 범위 준수 (CRIT-ORC3)를 어떤 방식으로 강제할지 — 호출 wrapper로 막을지, 사후 audit으로 잡을지
8. `plugin.json`의 정확한 manifest 필드 (Claude Code 공식 plugin manifest 스펙 확인 필요)

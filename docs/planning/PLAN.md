# 구현 계획서: `unity-asset-skills` Claude Code 플러그인 (Consensus Plan v6, 승인 대기)

- 원본 명세서: `D:\ClaudeCowork\unitySkills\.omc\specs\deep-interview-unity-asset-skills.md`
- 핸드오프 시점 모호도: **9%** (PASSED, 사용자가 강화한 10% 목표 충족)
- 작업 디렉터리: `D:\ClaudeCowork\unitySkills\` (greenfield)
- 산출물: Claude Code 플러그인 `unity-asset-skills/` 한 개 — **3개 스킬 (`:index`, `:search`, `:build`) + 1개 자체 subagent (`agents/asset-tagger.md`) + CONVENTION.md + plugin.json + AGENTS.md + tests/**. OMC 미설치 환경에서도 동작 (v3→v4에서 OMC 의존성 제거).
- 상태: **승인 대기 (pending approval)** — Planner/Architect/Critic 2-iteration 합의 도달. 사용자가 실행 스킬(autopilot / ralph / team)을 명시적으로 선택하기 전에는 실행하지 않음.
- 합의 이력: v1 (Planner) → v2 (Architect+Critic 16개 수정) → v3 (R1/R2/R3 3개 정밀화) → Critic APPROVED → v4 (OMC 의존성 제거: 자체 subagent 도입) → v5 (외부 MCP 의존성 명시: CoplayDev/unity-mcp + unity-mcp-skill 두 가지를 분리 명시) → v6 (설치 워크플로 결정 반영: Git URL 단일 배포, README 5분 Quick Start, `/unity-assets:doctor` 4번째 스킬 추가, Windows-only 범위 명시).

---

## OUTPUT 1 — RALPLAN-DR 요약

### 원칙 (Principles)
1. **LLM 분석은 내부 한정.** 모든 의미 단계(태깅·요약·Search 라우팅·sub-intent 분해·confidence 판단)는 `Task(subagent_type=...)` 통해 Claude Code subagent로 수행. 외부 API 호출 0, API 키 처리 0. (명세서 39~41, 71행)
2. **메인 컨텍스트 절약, subagent fan-out 우선.** Indexer는 raw 에셋을 메인 스레드에 절대 올리지 않음 — `parallel_subagents=10` 워커가 각각 `batch_size=20` 에셋을 소화하고 정규화된 JSONL row만 회수. 메인 컨텍스트는 항상 bounded. (명세서 40~41, 200~212행)
3. **로직은 글로벌, 데이터는 프로젝트 로컬, 설정은 사용자 override 가능.** 스킬 파일은 글로벌 Claude Code 플러그인에. 메타데이터 캐시와 per-project 설정은 `<unity-project>/.claude/unity-asset-index/` + `<unity-project>/.claude/unity-assets.yml`에. (명세서 61~64, 158~170행)
4. **Chunking 전에 drill.** Search는 기본적으로 package-first 계층 drill-down (`packages.jsonl` 읽고 top-K 패키지 선택 후 해당 패키지의 에셋만 읽음). Map-reduce sliding chunks는 **오직** `assets_count > 2000` 또는 `index_depth=rich`일 때만 발동. (명세서 52~54, 218~228행)
5. **Rollback은 사용자 책임.** Git 자동화·dry-run 게이팅·`.meta` 쓰기·`AssetDatabase.Delete` 없음. Orchestrator의 action scope는 C 수위 (scene/prefab/SO/script 생성) — 파괴적 행위는 명시적으로 금지되며 prompt + audit 이중 enforcement로 감시. (명세서 57, 73~74, 99~100, 249~253행)

### 의사결정 동인 (Decision Drivers)
1. **17개 CRIT-*는 라이브 Unity Editor 없이 테스트 가능해야 함** — fixture는 filesystem-only (`.meta` + 에셋 stub)이어야 CRIT 스위트가 CI/local에서 Editor 미실행 상태로 돌아감. Deep-fetch 테스트는 `unity-mcp-skill` 경계를 stub.
2. **컨텍스트 윈도우 경제성** — 메인 에이전트는 raw 에셋 byte를 절대 보지 않음. 모든 트래픽이 `assets.jsonl` row 또는 subagent return payload를 통과. 2-layer 인덱스 설계와 `max_assets_in_context=500` 캡의 근거.
3. **Claude Code 플러그인 manifest 적합성** — `plugin.json`은 Claude Code 공식 plugin manifest 스펙(CRIT-CNV2) 통과해야 하고, 3개 스킬 파일은 임의의 Unity 워크스페이스에서 `/unity-assets:index|search|build`로 호출 가능해야 함.

### 실현 가능 옵션 (가장 결정적 구조 선택: **Search와 Orchestrator가 상태를 어떻게 공유하는가**)

| 옵션 | 장점 | 단점 |
|------|------|------|
| **A. JSONL 파일 핸드오프** (Search가 `.claude/unity-asset-index/`에 `search-result.json` 작성, Orchestrator가 호출 시 읽음) | 결합도 낮음; 세션 재시작에서 살아남음; 테스트 용이 (CRIT-ORC4가 단순 파일 스키마 비교로 환원); 인덱스에 이미 채택한 "filesystem cache" 철학과 일치. | 파일 I/O 왕복 한 번 추가; `:search`가 두 번 동시에 돌면 일시적 race (저위험: 동일 프로젝트·단일 사용자). |
| **B. 세션 내 메시지 패싱** (Orchestrator가 Search의 연속으로 호출, 결과 객체는 메인 에이전트 메모리에 유지) | 디스크 쓰기 없음; 지연 시간 낮음; 호출부 단순. | 검사 어려움 (CRIT-ORC4가 로그 캡처에 의존해야 함); 세션 재시작 후 Orchestrator 재개 불가; 명세서가 암시하는 것보다 스킬 결합도 높음. |

**선택: A (JSONL 핸드오프).** 명세서의 "메타데이터 캐시 + per-project 설정" 철학과 정렬됨 (명세서 63행), Search→Orch 계약을 구체 파일 스키마로 만들어 CRIT-ORC4를 단순 JSON diff로 검증 가능, 명세서 요구대로 각 스킬이 독립 호출 가능함(`/unity-assets:search`와 `/unity-assets:build`를 분리 호출 가능) 유지. 옵션 B의 지연 시간 이점은 사람 주도 워크플로에서 무의미.

---

## OUTPUT 2 — ADR (Architecture Decision Record)

**Decision (결정):** `unity-asset-skills`를 Claude Code 플러그인 한 개로 구축한다. 3개 스킬 파일, Search↔Orchestrator 간 JSONL 파일 핸드오프, 모든 LLM 분석은 Claude Code 내부 batch subagent로, 계층형 2-layer 인덱스 + package-first drill-down + map-reduce 자동 전환, 이중(prompt + audit) scope enforcement, Unity Editor 미실행 상태로 돌아가는 17-CRIT 합격 스위트.

**Drivers (동인):** (i) subagent fan-out + LLM 내부 한정에 대한 명세서 잠금 결정, (ii) Unity Editor 없는 테스트 가능성, (iii) 메인 스레드 컨텍스트 경제성, (iv) Claude Code 플러그인 마켓플레이스 적합성.

**Alternatives considered (고려된 대안):** 옵션 B (세션 내 메시지 패싱)는 테스트 가능성 + 재개 가능성 측면에서 거부; embedding/vector DB 접근은 spec round 3에서 거부 (LLM-as-Search 채택); 단일 스킬 모놀리식은 spec round 12에서 거부 (3-skill + CONVENTION.md 유지보수성 우선); 코드 인터포저 scope guard는 iteration 1에서 거부 (단일 MCP 엔트리 포인트 부재 — prompt+audit 이중 enforcement로 교체).

**Why chosen (선택 이유):** 잠긴 명세서 결정들과 정렬되며, 모든 계약 면을 구체 파일 스키마 diff (테스트 가능)로 만들고, 스킬 독립성을 유지하며, 신규 인프라 도입 없이 Claude Code 내장 `Task` + `Skill` + 자체 plugin-defined subagent primitive에 깔끔히 매핑됨.

**Consequences (결과):** 파일 단위 wave I/O 오버헤드 존재 (작음); `.partial` + atomic rename 프로토콜로 인해 크래시 복구 로직 필요 (R1에서 처리); scope guard는 코드 강제가 아닌 "prompt + audit" (사용자 책임 rollback 원칙에 부합); recall 측정은 hand-curated fixture에 한정 (합성 1200-에셋 fixture는 scale 트리거 전용).

**Follow-ups (후속):** (i) Unity Editor가 가용해지면 실제 Asset Store 팩을 fixture 프로젝트로 임포트하는 일회성 스크립트 추가 (주기적 실세계 recall 보정용); (ii) 초기 테스트 실행에서 class-masking 패턴이 보이면 CRIT-ORC1의 per-class 하한을 더 조일지 검토; (iii) 사용자 피드백상 loose safety mode가 너무 관대하면 자동 rollback (git snapshot) 정책 재검토.

---

## OUTPUT 3 — 구현 계획

### 요구사항 요약
1. Claude Code 플러그인 `unity-asset-skills/` 한 개 — 3개 스킬 파일 (`:index`, `:search`, `:build`), `CONVENTION.md`, `plugin.json`, `AGENTS.md`, `tests/` 하위 트리. (명세서 142~156행)
2. Indexer는 **filesystem 스캔** + **배치 subagent fan-out** (`Task(subagent_type="unity-asset-skills:asset-tagger", model="haiku")`) 으로 LLM 태깅. 기본값 `batch_size=20`, `parallel_subagents=10` 잠금. `state.json` (GUID→signature + batch 진행 + `in_progress_run` 플래그)으로 재개 가능. wave 별로 `assets.jsonl.partial`에 append; 모든 wave 성공 후 `guid` 정렬 끝나면 atomic rename으로 `assets.jsonl`로 commit. (명세서 40~48, 200~212행)
3. 2-layer 인덱스: `packages.jsonl` (package summary, 파생) + `assets.jsonl` (shallow asset record). 스키마는 `unity-assets.yml` 통해 minimal (기본 7 필드) / normal / rich로 단계화. per-tier 필드 deltas는 Step 1에서 명시적 정의 (명세서 OQ#1 해결). (명세서 64, 172~194행)
4. Search는 **이중 호출** 수행: 1차 = multi-category 라우팅 + sub-intent 분해 (`search-routing.json.schema.json` 모양으로 emit), 2차 = sub-intent별 retrieval. 기본 package-first drill-down; `assets_count > 2000` 또는 `index_depth=rich`이면 map-reduce sliding chunks로 자동 전환. `max_assets_in_context=500` 캡. Search는 `reasoning`을 LLM 풀-피델리티로 전파해야 함 (요약 금지). (명세서 50~54, 216~228행)
5. Orchestrator는 sub-intent별 confidence 게이트 적용: `auto≥0.70` / `confirm≥0.40` / `reject<0.40`. Action scope C: scene 조작 + prefab/SO/script 생성 허용; **AssetDatabase delete/move, build/player 설정 금지**. Enforcement는 이중: (i) Orchestrator subagent prompt 안에 prompt-level 금지 튜플 목록, (ii) audit-level `orchestrator-audit.jsonl`을 `test-scope-guard.ps1`이 스캔하여 금지 튜플 0건 단언. (명세서 56~58, 232~253행)
6. 모든 Unity Editor 호출은 두 외부 의존성 사슬을 통해 수행한다 — 본 플러그인은 어느 쪽도 재구현하지 않음:
   - **MCP for Unity** ([CoplayDev/unity-mcp](https://github.com/CoplayDev/unity-mcp), MIT): Unity Editor와 통신하는 실제 MCP 서버 (Unity UPM 패키지 + Python 3.10+ MCP 서버). 도구 surface(`manage_scene`, `manage_gameobject`, `manage_prefabs`, `manage_assets`, `create_script`, `script_apply_edits`, `read_console`, `manage_camera` 등) 제공. 사전 설치 필요 (`Window > Package Manager > + > Add package from git URL` 또는 Asset Store / OpenUPM `com.coplaydev.unity-mcp`).
   - **`unity-mcp-skill`**: Claude Code 글로벌 skill, `~/.claude/skills/unity-mcp-skill/` (SKILL.md `name:` `unity-mcp-orchestrator`). 위 MCP 도구들의 안전한 사용 가이드·도구 스키마·워크플로 패턴 제공. 본 플러그인의 subagent가 이 가이드를 따라 MCP 도구 호출. (명세서 66, 136~138행; 폴더명 vs YAML `name:`은 Step 0에서 disambiguate.)
   - 두 의존성이 누락되면 Indexer의 filesystem 1차 수집까지는 동작하지만 unity-mcp deep-fetch와 Orchestrator의 scene/prefab 조작은 실패 → CRIT-SCH4 fallback 경로로 사용자에게 안내.
7. 프로젝트 로컬 데이터 레이아웃: `<unity-project>/.claude/unity-asset-index/{manifest.json, packages.jsonl, assets.jsonl, deep-cache/, state.json, orchestrator-audit.jsonl}` + `<unity-project>/.claude/unity-assets.yml`. (명세서 158~170행)
8. 17개 CRIT-*는 각각 `unity-asset-skills/tests/`에서 실행 가능한 구체 fixture + 검증 명령으로 매핑되어야 함. (명세서 82~107행)

### 저장소 레이아웃 (생성할 파일 / 디렉터리)

```
D:\ClaudeCowork\unitySkills\
└── unity-asset-skills\                       # 플러그인 루트 (단일 산출물)
    ├── plugin.json                           # Claude Code 플러그인 manifest (CRIT-CNV2)
    ├── README.md                             # 사용자 가이드 + "git이 안전망" 안내
    ├── CONVENTION.md                         # 스키마 + 경로 + cross-skill 계약 사양
    ├── AGENTS.md                             # 내부 개발자 문서, 계층형
    ├── agents\
    │   └── asset-tagger.md                   # 플러그인 자체 subagent 정의 (v4 신규, OMC 의존성 제거)
    ├── skills\
    │   ├── unity-assets-index\
    │   │   ├── SKILL.md                      # /unity-assets:index, :reindex
    │   │   └── prompts\
    │   │       └── subagent-tagger.md        # subagent에 전달할 정확한 instructions (명세서 OQ#5)
    │   ├── unity-assets-search\
    │   │   └── SKILL.md                      # /unity-assets:search, :pick
    │   ├── unity-assets-build\
    │   │   └── SKILL.md                      # /unity-assets:build (Orchestrator)
    │   └── unity-assets-doctor\
    │       └── SKILL.md                      # /unity-assets:doctor (설치·환경 헬스체크, v6 신규)
    ├── schemas\
    │   ├── asset-record.minimal.json         # 7 필드 (명세서 172~182행)
    │   ├── asset-record.normal.json          # minimal + 5 필드
    │   ├── asset-record.rich.json            # normal + 타입-discriminated extras
    │   ├── package-record.json               # packages.jsonl row 스키마
    │   ├── state.json.schema.json            # state.json batch-progress + in_progress_run (R1)
    │   ├── search-routing.json.schema.json   # 1차 라우팅 출력
    │   └── search-result.json.schema.json    # Search→Orch 핸드오프 스키마 (CRIT-ORC4)
    ├── tests\
    │   ├── README.md                         # 전체 CRIT 스위트 실행법 + flag 계약
    │   ├── run-crit-suite.ps1                # 일회성 CRIT 러너 (Windows-only, v6에서 POSIX 미러 제거)
    │   ├── fixtures\
    │   │   ├── unity-50\                     # hand-curated (~50 에셋) — recall 테스트
    │   │   ├── unity-200\                    # hand-curated (~200 에셋) — CRIT-EE1 대상
    │   │   ├── unity-1200\                   # 자동 생성 (~1200 에셋) — scale 전용
    │   │   └── README.md                     # 용도 구분 문서
    │   ├── golden-queries.yml                # CRIT-SCH1 10개 + CRIT-ORC1 10개 (6 multi / 4 single)
    │   ├── unit\
    │   │   ├── test-coverage.ps1             # CRIT-IDX1
    │   │   ├── test-idempotency.ps1          # CRIT-IDX2 (no-op 경로)
    │   │   ├── test-incremental.ps1          # CRIT-IDX3
    │   │   ├── test-subagent-recovery.ps1    # CRIT-IDX4 (R1 크래시 복구 포함)
    │   │   ├── test-recall-at-3.ps1          # CRIT-SCH1
    │   │   ├── test-drilldown-switch.ps1     # CRIT-SCH2
    │   │   ├── test-malformed-query.ps1      # CRIT-SCH3
    │   │   ├── test-fallback-contract.ps1    # CRIT-SCH4
    │   │   ├── test-multi-intent-routing.ps1 # CRIT-ORC1 (R2 복합 임계치)
    │   │   ├── test-confidence-gate.ps1      # CRIT-ORC2
    │   │   ├── test-scope-guard.ps1          # CRIT-ORC3
    │   │   ├── test-search-orch-contract.ps1 # CRIT-ORC4
    │   │   ├── test-cross-skill-contract.ps1 # CRIT-CNV3
    │   │   ├── test-yml-override.ps1         # CRIT-CNV4
    │   │   └── test-doctor-diagnosis.ps1     # CRIT-DOC1 (v6 신규)
    │   ├── lint\
    │   │   ├── lint-schema-doc-sync.ps1      # CRIT-CNV1 (CONVENTION.md fenced JSON 파싱)
    │   │   └── lint-plugin-manifest.ps1      # CRIT-CNV2 (plugin.json 검증)
    │   └── e2e\
    │       └── test-ee1-zombie-survival.ps1  # CRIT-EE1 (R3 announcement 포함 단일-입력 흐름)
    └── examples\
        └── unity-assets.yml                  # 기준 per-project 설정 (기본값 잠금)
```

### 구현 단계

각 단계는 생성/편집 파일과 진전시키는 CRIT-*를 명시.

**Step 0 — 환경 사전 점검.** *(모든 subagent 의존 단계의 선결 조건; v4에서 OMC 의존성 제거 후 재작성)*
- **Claude Code 플러그인의 자체 subagent 등록 메커니즘 확인.** 본 플러그인은 OMC의 `oh-my-claudecode:executor` 같은 외부 subagent에 의존하지 않고, 플러그인 내부에 정의한 `unity-asset-skills:asset-tagger`를 사용한다. 다음을 확인:
  - Claude Code가 `unity-asset-skills/agents/<name>.md` (또는 동등) 경로의 markdown 파일을 plugin-defined subagent로 자동 등록하는지 확인 (구체 메커니즘은 Claude Code plugin 공식 문서, 또는 기설치된 다른 플러그인의 agent 정의 예제로 검증).
  - 검증 방법: 최소한의 시험용 agent 정의 파일을 만들어 `Task(subagent_type="unity-asset-skills:asset-tagger", ...)` 호출이 성공하는지 확인.
  - **plugin-defined subagent 등록이 지원되지 않는 경우 fallback**: Claude Code 내장 `general-purpose` subagent 사용 + 매 호출마다 태깅 전용 instructions를 prompt로 직접 전달. 이 경우 Step 1에서 `agents/asset-tagger.md` 대신 `prompts/asset-tagger-system.md`만 생성하고 Step 2의 subagent 호출 형식을 `Task(subagent_type="general-purpose", model="haiku", prompt=<instructions+batch>)`로 조정.
- 모든 subagent 호출은 네임스페이스 형식 `Task(subagent_type="unity-asset-skills:asset-tagger", model="haiku")` 사용 (또는 위 fallback 형식). 이 네임스페이싱은 Step 2 (Indexer), Step 6 (테스트 스크립트), `prompts/subagent-tagger.md` 예시, `tests/unit/test-subagent-recovery.ps1`에 적용.
- **두 외부 의존성 확인 + 이름 disambiguate:**
  - **(1) MCP for Unity** ([CoplayDev/unity-mcp](https://github.com/CoplayDev/unity-mcp)): Unity Editor와 통신하는 실제 MCP 서버. Unity 2021.3 LTS+ / Python 3.10+ / uv 필요. 설치 경로:
    - Unity 측: UPM에 git URL `https://github.com/CoplayDev/unity-mcp.git?path=/MCPForUnity#main` 추가 또는 Asset Store / OpenUPM (`com.coplaydev.unity-mcp`).
    - Python 측: `uv` 통해 MCP 서버 실행.
    - Claude Code MCP 설정에서 unity-mcp 서버 연결 (구체 설정은 CoplayDev/unity-mcp README 참조).
    - 검증: `mcp__manage_scene`, `mcp__manage_gameobject` 등 MCP 도구가 `Task` / 일반 호출에서 가용한지 확인.
  - **(2) `unity-mcp-skill`** (Claude Code 글로벌 skill):
    - 디스크 폴더: `~/.claude/skills/unity-mcp-skill/`
    - 해당 SKILL.md의 YAML frontmatter `name:`: `unity-mcp-orchestrator`
    - 본 계획서 텍스트는 폴더명 `unity-mcp-skill`로 참조하고, 런타임 호출은 `Skill(skill="unity-mcp-orchestrator", ...)`. 둘 다 실제로 존재하며 같은 의존성을 가리킴.
    - 이 skill은 (1)의 MCP 도구 사용 가이드일 뿐 통신 자체는 하지 않음 — (1)이 빠지면 가이드는 읽혀도 실제 호출은 실패.
- 위 두 사실을 `AGENTS.md`의 "의존성 및 호출 컨벤션" 섹션에 기록 — Step 2/4/6 구현자가 제3의 이름을 발명하지 않도록.
- Step 0은 `AGENTS.md` stub 항목 외에는 파일을 *생성하지 않음*; Step 2/4/6의 개념적 게이트.

**Step 1 — 플러그인 골격 + Convention + 스키마.** *(CRIT-CNV1, CRIT-CNV2, CRIT-CNV3 기반 마련; 명세서 OQ#1, #8 해결)*
- `unity-asset-skills/plugin.json` 생성. **정본 manifest 출처:** Claude Code 공식 plugin manifest 스펙. 구현 시 검증용 참조 예시: 기설치된 모든 플러그인의 `.claude-plugin/plugin.json` (예: `~/.claude/plugins/marketplaces/`의 임의 플러그인). 일반적으로 인정되는 필드 셋: `name / version / description / author / repository / homepage / license / keywords / skills / agents / mcpServers / commands`. 필수 필드는 모두 채우고, 적용 불가한 선택 필드는 생략. CRIT-CNV2는 Claude Code의 plugin manifest 스펙 기준 검증 (특정 마켓플레이스 종속 아님).
- `unity-asset-skills/agents/asset-tagger.md` 생성 (v4 신규). 플러그인 자체 subagent 정의. 입력: 에셋 파일 경로 목록. 출력: 에셋당 한 줄의 JSONL (`guid`, `path`, `name`, `type`, `labels`, `llm_tags`, `llm_summary`). 도구 제한: Read만 사용 (Edit/Write/Bash 호출 안 함 — pure analyzer). YAML frontmatter는 Step 0에서 확인한 Claude Code plugin agent 스펙을 따른다.
- `unity-asset-skills/README.md` 생성 — 명세서의 "설치 (사용자 사전 조건 + Quick Start)" 섹션을 1:1 미러링한 **5분 Quick Start 단일 레시피**. 구성:
  - (1) 사전 조건 표 (Unity 2021.3 LTS+, Python 3.10+, uv, Claude Code).
  - (2) Quick Start 7단계 PowerShell 블록: UPM git URL 임포트 → Skill Sync → MCP 서버 연결 확인 → `claude plugins install` → cwd 이동 → `/unity-assets:doctor` → `/unity-assets:index` → 사용.
  - (3) `doctor` 출력 진단 표 (4개 실패 패턴별 권장 조치).
  - (4) "git이 안전망" 한 줄 안내 (명세서 59행).
  - (5) 한 줄짜리 "Other install options" 부록 — Asset Store / OpenUPM / 수동 clone 경로는 명시적으로 비-1급으로 표시.
  - Windows 외 OS 안내 0 (V1 범위 외; 명세서 "지원 플랫폼" 섹션 인용으로 끝).
- `unity-asset-skills/CONVENTION.md` 생성 — 다음을 문서화:
  - 디렉터리 레이아웃 (명세서 158~170행),
  - **파일 atomic 계약:** 모든 스킬 산출 파일 (`assets.jsonl`, `packages.jsonl`, `state.json`, `manifest.json`, `search-result.json`, `orchestrator-audit.jsonl`)은 `<name>.tmp`로 쓰고 atomic rename; 인덱싱 중 부분 쓰기는 `<name>.partial`,
  - **schema-doc-sync 계약:** 각 tier의 스키마는 ` ```json … ``` ` fenced JSON 블록으로 `## Asset Record — <tier>` 헤더 아래에 등장. 린트 파서 (`lint-schema-doc-sync.ps1`)가 헤더로 블록 추출 후 `schemas/asset-record.<tier>.json`과 diff. CRIT-CNV1이 기대하는 포맷,
  - **per-tier 필드 deltas (명세서 OQ#1 해결):**
    - **minimal (7 필드):** `guid` (string), `path` (string), `name` (string), `type` (string), `labels` (string[]), `llm_tags` (string[]), `llm_summary` (string). (명세서 172~182행.)
    - **normal (minimal + 5):** `size` (int, bytes), `dependencies` (string[] of GUIDs), `package_id` (string), `last_modified` (ISO-8601 string), `llm_use_cases` (string[]).
    - **rich (normal + 타입-discriminated extras):**
      - `Prefab` → `component_types` (string[])
      - `Material` → `shader_props` (object<string, any>)
      - `Animator` / `AnimatorController` → `animator_states` (string[])
      - 그 외 타입은 `extras` (free-form object) 가능하나 신규 필수 키 없음; rich 스키마는 비-완전(non-exhaustive)이지만 검증을 위해 `type` discriminator 사용,
  - `unity-assets.yml` 키들 (명세서 256~267행 기본값 잠금),
  - cross-skill 파일 계약 (누가 무엇을 쓰고 누가 읽는지) — **manifest_version 핸드셰이크 포함:** `search-result.json`은 최상위 필수 필드 `manifest_version` (string, regex `^v\d+\.\d+$`)을 포함; `search-result.json::manifest_version != manifest.json::version`이면 Orchestrator는 사유 코드 `stale_search`로 거부,
  - `unity-mcp-skill` 위임 규칙 (Step 0의 폴더명 vs 호출명 구분),
  - **Orchestrator preflight + R3 안내:** `/unity-assets:build`가 신선한 `search-result.json` 없이 호출된 경우 (파일 부재, 또는 `manifest_version` 불일치, 또는 `state.json::last_run`보다 오래된 경우), Orchestrator는 먼저 사용자에게 보이는 한 줄을 stdout에 출력 — 정확히: `[unity-assets:build] No fresh search-result.json — running :search first (Ctrl+C to abort).` — 그 다음 사용자의 자연어 입력으로 `/unity-assets:search`를 자동 호출. subagent fan-out 전에 사용자 abort 창을 보장하며 CRIT-EE1을 진정한 단일-입력 흐름으로 만듦.
- `unity-asset-skills/AGENTS.md` 생성 (내부 계층형 문서; SKILL.md 파일 참조; Step 0의 의존성 disambiguation 수록).
- `unity-asset-skills/examples/unity-assets.yml` 생성 — 명세서 256~267행 기본값 그대로 복사.
- `unity-asset-skills/schemas/` 아래 7개 파일 생성:
  - `asset-record.minimal.json`, `asset-record.normal.json`, `asset-record.rich.json` (위의 per-tier 필드 deltas 사용),
  - `package-record.json` (명세서 184~194행 기준),
  - **`state.json.schema.json` (명세서 OQ#6 + R1):** 필수 필드:
    - `last_run` (ISO-8601 string)
    - `version` (string, `manifest.json::version`과 일치)
    - `guid_signatures` (object<guid, signature-string>) — 증분 변경 감지용
    - `pending_batches` (array<{batch_id, reason}>) — 재시도 대기 중인 실패 batch
    - `bad_rows` (array<{guid, reason}>) — 재시도 대기 중인 malformed subagent 출력
    - **`in_progress_run` (boolean, default false, R1)** — 첫 wave 시작 시 `true`, `assets.jsonl` atomic rename 완료 후 `false`로 클리어. Step 2 크래시 복구 로직 구동.
    - `completed_batches` (array<batch_id>) — 이미 `assets.jsonl.partial`에 행이 들어간 batch들; 재개 시 중복 작업 회피용.
  - **`search-routing.json.schema.json`:** 모양 `{multi_category: boolean (required), sub_intents: [{intent: string (required), category_hint: string|null}]}`. Step 3에서 참조.
  - **`search-result.json.schema.json`:** 최상위 필수 필드:
    - `manifest_version` (string, required, regex `^v\d+\.\d+$`)
    - `groups` (sub-intent 그룹의 array): 각 그룹은 `sub_intent` (string, required), `candidates` (`{guid, path, confidence (number 0..1), reasoning (string, REQUIRED, NO maxLength)}`의 array)
    - CONVENTION.md 명시: Search는 `reasoning`을 풀-피델리티로 전파해야 함 (요약 금지, 절단 금지).
- 이 스키마들이 **단일 진실원** — CONVENTION.md와 스킬 문서가 참조; lint pass는 CONVENTION.md의 fenced JSON 블록을 스키마 파일과 diff해서 CRIT-CNV1 충족.

**Step 2 — Indexer 스킬 + subagent 태깅 계약 + atomicity + 크래시 복구.** *(CRIT-IDX1~4 진전)*
- `unity-asset-skills/skills/unity-assets-index/SKILL.md` 생성 — 다음 정의:
  - `/unity-assets:index` (`state.json` 기준 full 또는 incremental).
  - `/unity-assets:reindex` (강제 full).
  - 흐름은 명세서 200~212행: `state.json` 읽음 → 변경된 셋 N 계산 → wave 계획 (`ceil(N/batch_size)` 개 wave, 각각 최대 `parallel_subagents` 워커) → batch마다 `Task(subagent_type="unity-asset-skills:asset-tagger", model="haiku")` 호출 → JSONL row 누적 → `assets.jsonl` 작성, `packages.jsonl` 파생, `state.json` 갱신.
  - **wave 별 incremental 쓰기 + atomic finalize:** 각 wave는 자기 subagent들의 반환 row를 `assets.jsonl.partial`에 subagent 도착 순서로 append. 모든 wave 성공 완료 후, Indexer가 (i) `assets.jsonl.partial` 읽음, (ii) `guid` lexicographic 기준 재정렬, (iii) 정렬된 내용을 `assets.jsonl.tmp`로 쓰기, (iv) `assets.jsonl.tmp` → `assets.jsonl` atomic rename, (v) `assets.jsonl.partial` 삭제, (vi) `state.json::in_progress_run = false`로 설정 후 `state.json` atomic 재작성. `packages.jsonl`과 `state.json`도 같은 `.tmp` → 최종 rename 컨벤션 준수.
  - **subagent 당 60s 타임아웃:** 각 `Task(...)` 호출은 60초 wall-clock 예산. 타임아웃 시 해당 batch는 `state.json::pending_batches`에 사유 `subagent_timeout`으로 기록되고 wave는 **stall하지 않음** — 살아남은 subagent들의 출력으로 wave 진행; 실패 batch는 다음 `/unity-assets:index` 실행이 가져감 (CRIT-IDX4 복구와 같은 코드 경로).
  - **크래시 복구 의미론 (R1):** `/unity-assets:index` 시작 시, 새 wave 계획 전에:
    1. `assets.jsonl.partial`이 존재하고 AND `state.json::in_progress_run == true`이면: `assets.jsonl.partial`을 `state.json::completed_batches`에 나열된 batch에 대해 권위 있는 것으로 취급; `state.json::pending_batches`의 batch와 아직 추적되지 않은 새로 감지된 변경 셋 batch만 재실행. 재개를 idempotent하게 만듦.
    2. `assets.jsonl.partial`이 존재하고 AND `state.json::in_progress_run == false`이면: `.partial`은 orphan (이전 크래시로 상태가 corrupt); 삭제 후 변경 셋 전체 재실행.
    3. `assets.jsonl.partial`이 존재하지 않으면: 정상 경로. 첫 wave 시작 전에 `state.json::in_progress_run = true` 설정, 각 subagent의 row가 `.partial`에 append된 후 `batch_id`를 `state.json::completed_batches`에 추가.
    4. 복구 흐름은 `tests/unit/test-subagent-recovery.ps1`에 문서화 — CRIT-IDX4가 타임아웃/실패와 크래시 복구 경로 모두 커버.
  - 실패 모델: 각 batch는 실패 시 `state.json::pending_batches`에 commit; 미완료 마커는 다음 실행에서 자동 재시도 트리거 (CRIT-IDX4).
  - **Idempotency 규칙 (CRIT-IDX2):** sort-by-guid 후 atomic rename 끝나면 두 연속 *no-op* 실행은 byte-identical `assets.jsonl` 산출. byte-identity 주장은 오직 no-op 경로에만 적용 (합격 기준 매핑의 CRIT-IDX2 워딩 참조).
- `unity-asset-skills/skills/unity-assets-index/prompts/subagent-tagger.md` 생성 — 각 batch subagent가 받을 정확한 prompt (입력: 에셋 filesystem 경로 목록; 출력: `llm_tags` + `llm_summary` 포함 JSONL row). 내부 예시 호출은 `Task(subagent_type="unity-asset-skills:asset-tagger", model="haiku")` 사용. 명세서 OQ#5 해결.
- `unity-assets.yml::ignore_paths` (명세서 264행) 기반 ignore-path 핸들링 정의.

**Step 3 — Search 스킬: dual-call 라우팅 + drill-down/map-reduce.** *(CRIT-SCH1~4 진전)*
- `unity-asset-skills/skills/unity-assets-search/SKILL.md` 생성 — 다음 정의:
  - **1차 (라우팅):** 단일 subagent 호출이 사용자 쿼리를 읽고 `schemas/search-routing.json.schema.json` 검증 통과하는 JSON 객체 emit — `{multi_category: bool, sub_intents: [{intent: string, category_hint: string|null}]}`.
  - **2차 (sub-intent별 retrieval):** 기본은 `packages.jsonl` 읽음 → top-K 패키지 → 해당 패키지의 row만 `assets.jsonl`에서 읽음 (`max_assets_in_context=500` 캡).
  - 자동 전환: `total_assets > 2000` 또는 `unity-assets.yml::index_depth == rich`이면 → `assets.jsonl` 위로 sliding chunks map-reduce (chunk 크기는 `max_assets_in_context`에서 파생).
  - **출력 스키마:** `search-result.json`을 (`<name>.tmp` 후 atomic rename으로) 작성 — `schemas/search-result.json.schema.json` 준수. 파일은 `manifest.json::version`을 그대로 복사한 `manifest_version` 포함. 각 후보의 `reasoning` 필드는 required, string, 풀 LLM-피델리티 (요약 금지, 절단 금지, no maxLength). CRIT-ORC4의 계약 면.
  - Fallback 계약: `assets.jsonl` 부재 / stale (mtime이 `state.json::last_run`보다 오래됨) 시 Search는 구조화 경고를 emit하고 (a) `/unity-assets:reindex` 권고, (b) reindex 자동 트리거 — CRIT-SCH4 커버.
  - Malformed 쿼리 핸들링: 빈/한글/이모티콘/따옴표 미스매치 입력은 crash 대신 `{status: "no_query", reason: "..."}` 반환 (CRIT-SCH3).
- 대화형 narrowing을 위한 `/unity-assets:pick` 서브커맨드 추가.

**Step 4 — Orchestrator 스킬: confidence 게이트 + 이중 scope enforcement + preflight 안내.** *(CRIT-ORC1~4 및 CRIT-EE1 진전)*
- `unity-asset-skills/skills/unity-assets-build/SKILL.md` 생성 — 다음 정의:
  - **입력 + preflight (R3 안내 포함):** `search-result.json` 읽음 (CRIT-ORC4 계약). 호출 시:
    - `search-result.json` 부재 또는 `manifest_version`이 `manifest.json::version`과 다름 또는 파일 mtime이 `state.json::last_run`보다 오래됨 → **먼저 stdout에 사용자가 볼 한 줄 `[unity-assets:build] No fresh search-result.json — running :search first (Ctrl+C to abort).` 출력 (R3, subagent fan-out 전에 사용자 abort 창 보장)**, 그 다음 원본 자연어 입력으로 `/unity-assets:search` 자동 호출. CRIT-EE1의 "1명의 수행자 입력으로 성공" 충족 — 단일-입력 흐름.
    - 재-Search 후에도 소비 시점 `manifest_version` 불일치가 감지되면 사유 코드 `stale_search`로 거부.
  - sub-intent별: `max(confidence)` 계산 → 게이트 (`0.70`/`0.40`/`<0.40`)에 따라 `auto`/`confirm`/`reject` 분기 — 명세서 232~238행.
  - **이중 scope enforcement:**
    - **Layer 1 — prompt-level 금지 튜플 목록:** Orchestrator subagent prompt에 명시적 "금지 작업" 튜플 목록 임베드. 금지 튜플 (명세서 249~253행):
      - `(AssetDatabase, Delete)`
      - `(AssetDatabase, MoveAsset)`
      - `(Editor, EnvSettings)`
      - `(Build, *)` (임의의 build/player 설정)
      Prompt는 subagent에게 이 튜플 중 하나를 만드는 계획 단계 거부하고 `scope_violation`을 emit하도록 지시.
    - **Layer 2 — audit-level enforcement:** 모든 `unity-mcp` 호출은 구조화된 줄을 `<unity-project>/.claude/unity-asset-index/orchestrator-audit.jsonl`에 append (`.tmp` + rename, OS에 따라 atomic append). Orchestrator 실행 완료 후, `test-scope-guard.ps1` (및 런타임 audit)이 audit 로그를 스캔하여 **금지 튜플 0건** 단언. 참고: `.meta direct edit`는 금지 튜플에서 제거 — `unity-mcp-skill`에 해당 API 면이 없어 우발적으로도 호출 불가.
  - **Subagent 호출 형식:** 모든 Orchestrator subagent 호출은 task 복잡도에 따라 `Task(subagent_type="unity-asset-skills:asset-tagger", model="haiku" | "sonnet" | "opus")` 사용.
  - 실행 종료 요약: sub-intent별 verdict + 제안 후속 행동 출력.
- 이 스킬이 CRIT-EE1을 닫음: 단일 자연어 요청이 (안내 → 필요 시 자동 Search) → Search → Orchestrator를 통해 `tests/fixtures/unity-200/`의 실제 씬 변형으로 이어짐.

**Step 5 — 테스트 인프라: fixture + 골든셋 + CRIT 러너.** *(모든 CRIT-* 진전)*
- `tests/fixtures/unity-50/`, `tests/fixtures/unity-200/`, `tests/fixtures/unity-1200/` 빌드 — 각각 filesystem-only Unity 프로젝트 구조 (`Assets/`, `.meta` 파일, stub 에셋 파일).
  - **`tests/fixtures/README.md`에 fixture 용도 구분:**
    - `unity-50/`과 `unity-200/`: **hand-curated.** 진정한 의미 recall을 지원하기 위해 실제 다양한 에셋 설명을 의도적으로 작성 (CRIT-SCH1, CRIT-EE1). 골든 쿼리 정답의 `llm_tags`는 쿼리 키워드 위의 unique-superset이어서는 **안 됨** — 안 그러면 CRIT-SCH1이 자명한 string-matching으로 붕괴. 구체적으로: 모든 골든 쿼리 정답 에셋의 `llm_tags`는 최소 한 개의 decoy 에셋의 `llm_tags`와 겹쳐야 함 → LLM-as-Search가 `llm_summary` + `path` + `type`을 disambiguation에 사용하도록 강제.
    - `unity-1200/`: **자동 생성** — 합성 prefab/material/texture stub을 emit하는 fixture-builder 스크립트로. `assets_count > 2000` map-reduce 분기 트리거 **전용** (CRIT-SCH2). recall 측정에는 사용 안 함. 합성-vs-실제 갭은 명시적으로 문서화.
- `tests/golden-queries.yml` 빌드:
  - **CRIT-SCH1 쿼리 10개** (recall@3) — 각각 쿼리 문자열과 `unity-200/`의 라벨링된 정답 GUID(들).
  - **CRIT-ORC1 라우팅 쿼리 10개:** 6 multi-intent + 4 single-intent 라벨링된 쿼리.
  - **CRIT-ORC1 복합 합격 임계치 (R2):** 다음 세 조건이 모두 충족될 때만 테스트 PASS:
    1. ≥ 8/10 종합 라우팅 분류 정확,
    2. ≥ 4/6 multi-intent 쿼리가 multi-intent로 올바르게 분류,
    3. ≥ 3/4 single-intent 쿼리가 single-intent로 올바르게 분류.
    이는 all-multi 또는 all-single 분류기가 종합 임계치를 통과하면서도 한 클래스에서 망가져 있는 class-masking을 방지. 범위 내 정밀화 (명세서 99행은 "5 중 4"였으나; 테스트 안정성을 위해 더 엄격하게).
- `tests/run-crit-suite.ps1` (와 `.sh` 미러) 빌드 — `unit/`, `lint/`, `e2e/`를 순회하며 CRIT 별 pass/fail emit.
  - **`-Only` 플래그 계약:** `run-crit-suite.ps1 -Only IDX,SCH,ORC`는 CRIT-ID 접두어로 테스트 필터 (콤마 구분, case-insensitive). 각 접두어는 해당 접두어로 시작하는 CRIT-ID 테스트와 매치 (예: `-Only IDX`는 CRIT-IDX1..4; `-Only SCH,ORC`는 CRIT-SCH1..4 + CRIT-ORC1..4). `tests/README.md`에 문서화.
- **CRIT 기본값 정책:** CRIT-CNV4를 제외한 모든 CRIT-* 테스트는 `examples/unity-assets.yml` 기본값을 그대로 적용해서 실행 (테스트 하네스가 setup 시 예시 파일을 fixture의 `.claude/unity-assets.yml`로 복사). **CRIT-CNV4가 유일한 config 변형 테스트** — 의도적으로 yml을 non-default 값으로 변형하고 그것이 전파됨을 검증. `tests/README.md`에 문서화.

**Step 6 — CRIT 별 테스트 스크립트.** *(각 CRIT-* 직접 검증)*
- `tests/unit/test-*.ps1`, `tests/lint/lint-*.ps1`, `tests/e2e/test-ee1-zombie-survival.ps1` 각각 작성 — 아래 매핑 표 기준. 테스트는 `unity-mcp-skill`을 stub하는 dry-run 래퍼로 스킬 호출 (Editor 불필요); stub은 모든 호출을 기록 → CRIT-ORC3의 audit-기반 단언 작동.
- 자체적으로 subagent를 spawn하는 모든 테스트 스크립트는 `Task(subagent_type="unity-asset-skills:asset-tagger", ...)` 형식 사용 (v4 OMC 의존성 제거 반영). 특히 `tests/unit/test-subagent-recovery.ps1` (CRIT-IDX4)는 네임스페이스 형식 미사용 시 첫 spawn에서 실패.
- **CRIT-IDX2 idempotency 정의는 no-op 경로:** `test-idempotency.ps1`는 변경되지 않은 fixture에서 두 번째 `/unity-assets:index` 실행이 (a) `state.json` 읽음, (b) guid-signature 비교로 빈 변경 셋 확인, (c) 모든 subagent 태깅 호출 skip, (d) 이전 `assets.jsonl`을 byte-for-byte 복사 (재정렬 불필요, 재작성 불필요; 이전 실행의 정렬된 파일 재사용)함을 검증. byte-identity-after-retag가 **아님** (결정론적 LLM seeding 필요 → 불가능).
- **CRIT-IDX4는 R1 크래시 복구 경로 포함:** `test-subagent-recovery.ps1`는 (a) wave 중 타임아웃/실패와 (b) 시뮬레이션 크래시 (`.partial`과 `state.json::in_progress_run = true`를 남기고 wave 중간에 kill)를 모두 행사 → 다음 실행이 인덱스를 올바르게 완료 (row 중복도 누락도 없음)함을 단언.
- **CRIT-ORC1 복합 단언 (R2):** `test-multi-intent-routing.ps1`는 세 게이트 (종합, multi-class, single-class) 복합 임계치를 동시 단언. 셋 중 어느 하나라도 실패하면 테스트 실패.
- **CRIT-EE1 e2e는 R3 안내 단언 포함:** `test-ee1-zombie-survival.ps1`는 단일-입력 실행 동안 stdout을 캡처하고, 안내 줄 `[unity-assets:build] No fresh search-result.json — running :search first (Ctrl+C to abort).`이 어떤 subagent spawn보다 먼저 나타남을 단언 (`orchestrator-audit.jsonl` 타임스탬프와 정렬해 검증 가능). 그런 다음 (1) 재인덱스 결정, (2) sub-intent 분해 존재, (3) confidence 게이트가 올바르게 발동, (4) audit 로그에 scene/prefab 생성 호출 존재 단언 — 모두 Unity 실행 없이.

**Step 7 — Doctor 스킬 (`/unity-assets:doctor`, v6 신규).** *(설치·환경 헬스체크. 새 합격 기준 CRIT-DOC1 진전.)*
- `unity-asset-skills/skills/unity-assets-doctor/SKILL.md` 생성. 4번째 슬래시 커맨드 `/unity-assets:doctor` 제공.
- 검사 항목 4가지 (명세서 "설치 단계가 실패할 때 진단" 표와 1:1 미러):
  1. **Unity Editor reachable via MCP for Unity** — `mcp__manage_scene` (또는 동등 비-파괴 read 도구) 호출 한 번 시도하여 응답 받음 여부. 실패 시 권장 조치: Unity Editor 실행, CoplayDev/unity-mcp 트러블슈팅 링크.
  2. **`unity-mcp-skill` global skill present** — `~\.claude\skills\unity-mcp-skill\SKILL.md` 파일 존재 + YAML frontmatter `name:` 값 확인. 실패 시 권장: Unity MCP for Unity > Skill Sync > Sync now.
  3. **Project `.claude/` structure ready** — cwd가 Unity 프로젝트 루트 (`Assets/` 존재) + `.claude/` 디렉터리 존재. 실패 시 권장: 올바른 디렉터리로 이동 후 `/unity-assets:index` 한 번 실행.
  4. **`unity-assets.yml` valid** — `.claude/unity-assets.yml` 존재 + 키 셋이 examples/unity-assets.yml과 호환 (모르는 키나 잘못된 값 타입 보고). 실패 시 권장: 플러그인 설치 경로의 `examples/unity-assets.yml`을 프로젝트 `.claude/`로 복사.
- 출력 형식: 4행 ✓/✗ 체크리스트 + 각 ✗ 항목별 한 줄 권장 조치 + 종료 코드 (4/4 통과 시 0, 하나라도 실패 시 1).
- 부수 안전선: doctor 자체는 **read-only** — 어떤 파일도 수정·생성·삭제하지 않음. 자동 fix 옵션은 V1 범위 외.
- 새 합격 기준 **CRIT-DOC1** 추가 (요건: 4개 의존성을 의도적으로 하나씩 망가뜨린 fixture에서 doctor가 정확히 어느 항목을 ✗로 식별하고 권장 조치를 올바르게 보여줘야 함).

### 합격 기준 매핑

| CRIT-ID | Fixture / Artifact | 검증 |
|---------|--------------------|------|
| **CRIT-EE1** End-to-end | `tests/fixtures/unity-200/` (hand-curated) + 캐닝된 prompt "top-down 좀비 survival 게임 프로토타입 만들어줘" | `tests/e2e/test-ee1-zombie-survival.ps1`: stdout이 R3 안내 줄을 임의의 subagent spawn 이전에 포함; 이후 재인덱스 결정 → sub-intent 분해 → confidence 분기 → audit 로그에 scene+prefab 호출; 단일-입력 흐름 (신선한 `search-result.json` 없으면 Orchestrator가 Search 자동 호출) 단언 |
| **CRIT-IDX1** Coverage | `tests/fixtures/unity-50/` | `tests/unit/test-coverage.ps1`: fixture의 `.meta` 파일 수 카운트, `assets.jsonl`의 row 수와 비교; 100% 기대 |
| **CRIT-IDX2** Idempotency | `tests/fixtures/unity-200/` (hand-curated) | `tests/unit/test-idempotency.ps1`: no-op 경로 검증 — 2회차 실행이 `state.json`의 빈 변경 셋 확인, 모든 subagent 호출 skip, `assets.jsonl`이 1회차 출력(1회차에서 sort-by-guid 끝남)을 디스크에서 재사용한 byte-for-byte 동일 |
| **CRIT-IDX3** Incremental accuracy | `tests/fixtures/unity-200/` | `tests/unit/test-incremental.ps1`: K개 파일 touch → 재실행 → `assets.jsonl` row hash diff; 정확히 K개 변경 기대 |
| **CRIT-IDX4** Subagent + 크래시 복구 (R1) | `tests/fixtures/unity-200/` + 실패 주입 플래그 | `tests/unit/test-subagent-recovery.ps1`: (a) 2개 batch 강제 실패/타임아웃 (60s) → 재실행 → `assets.jsonl` 완전 단언; (b) `assets.jsonl.partial` + `state.json::in_progress_run = true` 남긴 wave 중간 크래시 시뮬레이션 → 다음 실행이 `.partial`에서 재개, `pending_batches`와 미커버 변경 셋만 실행, 중복 없이 finalize. `Task(subagent_type="oh-my-claudecode:executor", ...)` 사용. |
| **CRIT-SCH1** Recall@3 | `tests/golden-queries.yml` (10개, decoy-overlapping `llm_tags`) + `unity-200/` | `tests/unit/test-recall-at-3.ps1`: 각 쿼리 실행, 정답 guid가 top-3에 있는지 확인; ≥8/10 기대 |
| **CRIT-SCH2** Drill-down 자동 전환 | `tests/fixtures/unity-1200/` (자동 생성, scale 전용) — duplicate-package 모드로 `assets_count > 2000` 강제 OR `index_depth=rich` 설정 | `tests/unit/test-drilldown-switch.ps1`: map-reduce 경로 실행됨 단언 (로그 마커). recall은 여기서 측정하지 않음. |
| **CRIT-SCH3** Malformed query | n/a (합성 입력) | `tests/unit/test-malformed-query.ps1`: 빈, 한글-only, 이모티콘, 따옴표 미스매치 문자열 입력; 구조화 `{status:"no_query"}` 응답 단언, 예외 없음 |
| **CRIT-SCH4** Indexer fallback | `tests/fixtures/unity-50/`에서 `assets.jsonl` 삭제 또는 `mtime` 사전 처리 | `tests/unit/test-fallback-contract.ps1`: 경고 emit + 두 reindex 옵션 제공 단언 |
| **CRIT-ORC1** 라우팅 정확도 (R2 복합) | `tests/golden-queries.yml` (10개 라우팅 라벨: 6 multi + 4 single) | `tests/unit/test-multi-intent-routing.ps1`: 세 게이트 동시 단언 — ≥ 8/10 종합 AND ≥ 4/6 multi-intent 정답 AND ≥ 3/4 single-intent 정답. 어떤 단일 게이트라도 실패하면 테스트 실패. |
| **CRIT-ORC2** Confidence gate | 3개 캐닝된 `search-result.json` 파일 (hi/med/lo confidence), 각각 `manifest_version`이 테스트 하네스와 일치 | `tests/unit/test-confidence-gate.ps1`: 각 feed → 올바른 분기 (`auto`/`confirm`/`reject`) 단언 |
| **CRIT-ORC3** Scope guard | 모든 Orchestrator 테스트 + 금지 작업 호출 시도 스크립트 | `tests/unit/test-scope-guard.ps1`이 `orchestrator-audit.jsonl` 파싱하고 금지 튜플 `(AssetDatabase, Delete)`, `(AssetDatabase, MoveAsset)`, `(Editor, EnvSettings)`, `(Build, *)` 0건 단언. 이중 enforcement (prompt + audit). `.meta direct edit` 제거 (해당 API 면 없음). |
| **CRIT-ORC4** Search→Orch 계약 | `schemas/search-result.json.schema.json` | `tests/unit/test-search-orch-contract.ps1`: Search 테스트가 생성한 모든 `search-result.json`을 스키마 검증; 모든 그룹에 `confidence` (numeric), `reasoning` (string, required, 풀-피델리티), `manifest_version` (regex `^v\d+\.\d+$`, `manifest.json::version`과 일치) 존재 단언 |
| **CRIT-CNV1** Schema-doc sync | `CONVENTION.md` fenced JSON 블록 + `schemas/*.json` | `tests/lint/lint-schema-doc-sync.ps1`: `## Asset Record — <tier>` 헤더 아래 fenced JSON 블록 파싱, `schemas/asset-record.<tier>.json`과 diff; 0 diff 기대 |
| **CRIT-CNV2** Plugin manifest | `plugin.json` | `tests/lint/lint-plugin-manifest.ps1`: Claude Code 공식 plugin manifest 스펙으로 검증 (기설치 플러그인의 `.claude-plugin/plugin.json` 예제 참조); 일회용 두 번째 Unity 워크스페이스에 sanity 설치 |
| **CRIT-CNV3** Cross-skill 계약 | 3개 스킬 모두 + `unity-200/` | `tests/unit/test-cross-skill-contract.ps1`: `unity-200/`에서 `:index` → `:search` → `:build` end-to-end 실행; 모든 핸드오프에서 스키마 에러 없음 단언; `examples/unity-assets.yml` 기본값 사용 |
| **CRIT-CNV4** .yml override (유일한 config 변형 테스트) | `examples/unity-assets.yml` + 변형된 override 파일 | `tests/unit/test-yml-override.ps1`: `confidence_threshold.auto`, `batch_size`, `index_depth`에 non-default 값 설정 → 런타임에 각각 관측됨 단언 (default→override→stick) |
| **CRIT-DOC1** Doctor 진단 정확도 (v6 신규) | 4개 fault-injection fixture (각각 4개 의존성 중 하나만 누락) + 정상 fixture 1개 | `tests/unit/test-doctor-diagnosis.ps1`: 각 fixture에서 `/unity-assets:doctor` 실행 → ✓/✗ 패턴이 망가뜨린 의존성과 정확히 매칭, 권장 조치 문구가 명세서 진단 표와 일치. 정상 fixture는 4/4 ✓ + 종료 코드 0. 모든 실행 후 fixture 디렉터리의 mtime 합계가 실행 전과 동일 (read-only 검증) |

### 리스크 및 완화

1. **리스크:** Claude Code `plugin.json` 스키마가 버전 간 갈라질 수 있음. **완화:** Step 1은 manifest 스키마를 Claude Code 공식 plugin 문서에서 가져옴. 검증용 참조 예시는 기설치 플러그인의 `.claude-plugin/plugin.json` (예: `~/.claude/plugins/marketplaces/`의 임의 플러그인). 일반적으로 인정되는 필드 셋: `name / version / description / author / repository / homepage / license / keywords / skills / agents / mcpServers / commands`. CRIT-CNV2가 그 스키마 대비 검증.
2. **리스크:** Subagent prompt가 일관되지 않은 JSON 생성 (malformed JSONL row가 Indexer 깨뜨림). **완화:** `prompts/subagent-tagger.md`의 subagent-tagger prompt가 row 단위 검증되는 엄격 JSON-line 스키마로 출력 제약; bad row는 `state.json::bad_rows` 목록에 들어가 retry batch로 라우팅 (CRIT-IDX4도 행사).
3. **리스크:** Scope-guard 우회 — Orchestrator subagent가 prompt-injection 통해 금지 `unity-mcp` op 요청 가능. **완화:** 이중 enforcement, "hard-coded allowlist dispatch wrapper" 없음: (i) Orchestrator subagent prompt가 명시적 금지 튜플 목록 임베드하고 `scope_violation`으로 거부; (ii) `orchestrator-audit.jsonl`이 모든 `unity-mcp` 호출 캡처하고 `test-scope-guard.ps1`이 모든 Orchestrator 실행 후 금지 튜플 스캔 (0건 단언). `.meta direct edit`는 해당 API 면 부재로 CRIT-ORC3 금지 목록에서 제거.
4. **리스크:** `unity-1200` 합성 fixture가 실제 Unity 에셋 다양성을 행사하지 못해 CRIT-SCH2를 약화 (recall을 거기서 측정한다면). **완화:** `unity-1200/`는 **오직** 자동 전환 분기 트리거용; recall 측정은 hand-curated `unity-50/` + `unity-200/` fixture에 제한. 합성-vs-실제 갭은 `tests/fixtures/README.md`에 명시적 문서화.
5. **리스크:** `Task(subagent_type="unity-asset-skills:asset-tagger", model="haiku")` fan-out 비용이 1200-에셋 재인덱스에서 폭증. **완화:** 기본값 (`batch_size=20`, `parallel_subagents=10`)이 동시성 캡; subagent 당 60s 타임아웃으로 stall 방지; `unity-assets.yml::ignore_paths`로 태깅 불필요 벤더 패키지 제외 가능; CRIT-IDX1 coverage 테스트는 1200-에셋 fixture가 아닌 `unity-50/`에서 실행 → 일상 CRIT 실행 저비용. `README.md`에 trade-off 문서화.
6. **리스크:** 한 wave의 stall된 subagent가 wave 전체를 블록, 부분 `assets.jsonl.partial`을 무한정 남김; OR 하드 크래시가 wave 중간 발생해 partial 파일을 orphan으로 남김. **완화:** subagent 당 60s 타임아웃과 "fail-the-batch" 의미론 — 타임아웃된 batch는 `state.json::pending_batches`에 사유 `subagent_timeout`으로 기록, wave는 살아남은 subagent 결과로 완료, 실패 batch는 다음 `/unity-assets:index` 실행에서 재시도. **크래시 복구 (R1):** `state.json::in_progress_run` 플래그 + `state.json::completed_batches` 배열로 "크래시에서 남은 stale `.partial`" vs "실행 중 세션의 live `.partial`" 구분 → 권위 batch에서 재개 또는 폐기 후 full-rerun. CRIT-IDX4가 두 경로 모두 행사.
7. **리스크:** Search→Orch가 오래된 인덱스에 대해 생성된 `search-result.json` 소비 → 삭제/이름 변경된 에셋 참조. **완화:** `manifest_version` 핸드셰이크 — `search-result.json`이 작성 시점 인덱스 버전과 일치하는 `manifest_version` 가짐; 불일치 시 Orchestrator가 `stale_search` 사유로 거부. 자동-Search-before-Build preflight (R3 안내 포함)와 결합 → 사용자는 stale 없는 단일-입력 흐름 획득.
8. **리스크:** 외부 의존성 두 가지 — **MCP for Unity** ([CoplayDev/unity-mcp](https://github.com/CoplayDev/unity-mcp))의 Unity UPM 패키지·Python 서버 미설치, 또는 글로벌 `unity-mcp-skill` 미설치 — 가 발생 시 Orchestrator의 scene/prefab 조작이 silent하게 실패할 수 있음. 또한 CoplayDev/unity-mcp의 도구 surface가 버전 업그레이드로 바뀌어(예: `manage_assets` action signature 변경, 신규 `manage_physics`·`manage_animation` 등 추가) 우리 금지 튜플 목록과 어긋날 수 있음. **완화:** (i) Step 0 환경 사전 점검에 두 의존성 가용성 검사 명시; (ii) Indexer는 의존성 없이도 filesystem 1차 수집까지는 동작하도록 격리 (deep-fetch만 실패); (iii) Orchestrator는 `Skill(skill="unity-mcp-orchestrator", ...)` 또는 직접 MCP 도구 호출 실패 시 `mcp_unavailable` 사유로 명시적 중단 + 사용자에게 사전 조건 설치 안내 ([CoplayDev/unity-mcp README](https://github.com/CoplayDev/unity-mcp) 링크 포함); (iv) 금지 튜플 목록은 CONVENTION.md에 명시적으로 적고 unity-mcp 업그레이드 시 수동 재검토 (CRIT-ORC3 review item); (v) `README.md`의 사전 조건 섹션이 세 가지(MCP 서버, unity-mcp-skill, MCP 설정)를 모두 명시.

### 검증 단계 (전체 CRIT 스위트 로컬 실행)

`D:\ClaudeCowork\unitySkills\unity-asset-skills\tests\`에서:

```powershell
# 전체 실행
.\run-crit-suite.ps1

# 또는 특정 부분만 실행 (-Only는 CRIT-ID 접두어 필터, 콤마 구분)
.\run-crit-suite.ps1 -Only IDX        # CRIT-IDX1..4만
.\run-crit-suite.ps1 -Only SCH,ORC    # Search + Orchestrator (CRIT-SCH1..4, CRIT-ORC1..4)
.\lint\lint-schema-doc-sync.ps1       # CRIT-CNV1 단독 (CONVENTION.md의 '## Asset Record — <tier>' 헤더 아래 fenced JSON 파싱, schemas/와 diff)
.\e2e\test-ee1-zombie-survival.ps1    # CRIT-EE1 단독 (R3 안내 포함 단일-입력 흐름; 라이브 Unity Editor 없음)
```

CRIT-CNV4를 제외한 모든 CRIT-* 테스트는 `examples/unity-assets.yml` 기본값 적용해서 실행. CRIT-CNV4가 유일한 config 변형 테스트.

러너는 CRIT 별 pass/fail을 stdout에 emit하고 `tests/_last-run.json`에 요약 작성. 17개 CRIT-* 모두 통과 시에만 종료 코드 0.

---

## 부록 — 명세서 미해결 항목 해결 현황

명세서 432~439행의 8개 미해결 항목을 본 계획서의 해결 위치로 매핑.

| OQ# | 상태 | 해결 위치 | 비고 |
|-----|------|-----------|------|
| 1 — CONVENTION.md 스키마 JSON 정확한 필드 목록 (minimal/normal/rich) | **해결됨** | Step 1 (per-tier 필드 deltas 섹션); `schemas/asset-record.<tier>.json`; CONVENTION.md fenced JSON 블록 | minimal=7 필드 (명세서 172~182행), normal +5 (size, dependencies, package_id, last_modified, llm_use_cases), rich +타입-discriminated extras (component_types, shader_props, animator_states). |
| 2 — `golden-queries.yml` 초기 10개 쿼리 + 라벨 (CRIT-SCH1) | **해결됨 (개수 잠금; 내용은 Step 5에서 작성)** | Step 5 (`tests/golden-queries.yml`) | CRIT-SCH1 쿼리 10개 + CRIT-ORC1 라우팅 쿼리 10개 (6 multi + 4 single). 실제 쿼리 문자열은 Step 5에서 작성; 제약: 골든 쿼리 정답의 `llm_tags`는 decoy와 겹쳐야 함. |
| 3 — CRIT-EE1 테스트 Unity 프로젝트 에셋 구성 (50~200 에셋) | **해결됨 (구조 잠금; 구체 에셋은 Step 5에서 작성)** | Step 5 (`tests/fixtures/unity-200/` hand-curated) | CRIT-EE1 좀비-survival prompt를 지원할 만큼 다양한 Prefab/Material/Texture/Script/ScriptableObject 타입의 hand-curated `.meta` + 에셋 stub. |
| 4 — 1000+ 에셋 더미 프로젝트 자동 생성 스크립트 (CRIT-SCH2) | **해결됨** | Step 5 (`tests/fixtures/unity-1200/` 자동 생성; `tests/fixtures/README.md`의 fixture-builder 스크립트 표기) | 합성 stub만; map-reduce 분기 트리거용; recall 측정에는 사용 안 함. |
| 5 — Subagent prompt 정확한 wording (Indexer tagger) | **해결됨 (파일 위치 잠금; wording은 Step 2에서 작성)** | Step 2 (`skills/unity-assets-index/prompts/subagent-tagger.md`) | row 별 엄격 JSONL 출력 계약; 네임스페이스 `Task(subagent_type="oh-my-claudecode:executor", ...)`. |
| 6 — `state.json` 스키마 (batch 진행) | **해결됨** | Step 1 (`schemas/state.json.schema.json`) | 필드: `last_run` (ISO-8601), `version` (string), `guid_signatures` (map), `pending_batches` (array), `bad_rows` (array), **`in_progress_run` (boolean, R1), `completed_batches` (array<batch_id>, R1)**. |
| 7 — Scope-guard enforcement 메커니즘 (CRIT-ORC3): wrapper vs audit | **해결됨** | Step 4, 리스크 #3 (이중) | Orchestrator subagent prompt 안에 prompt-level 금지 튜플 목록 (Layer 1) + 실행 후 `test-scope-guard.ps1`이 스캔하는 `orchestrator-audit.jsonl` (Layer 2). Dispatch-wrapper allowlist 없음. |
| 8 — `plugin.json` 정확한 manifest 필드 (Claude Code plugin spec) | **해결됨** | Step 1, 리스크 #1 | 정본 출처: Claude Code 공식 plugin 문서. 검증용 참조 예시: 기설치 플러그인의 `.claude-plugin/plugin.json`. 필드 셋: `name / version / description / author / repository / homepage / license / keywords / skills / agents / mcpServers / commands`. |

---

## 변경 이력

### v1 → v2 (iteration-1 Architect + Critic의 16개 수정)
- **A1**: `schemas/search-result.json.schema.json`의 `reasoning` 필드 required, no maxLength; `manifest_version` required; CONVENTION.md에 풀-피델리티 규칙.
- **A2**: Indexer wave-incremental append to `.partial`, sort-by-guid 후 atomic rename finalize, subagent 당 60s 타임아웃 + fail-the-batch 의미론.
- **A3**: NEW `schemas/search-routing.json.schema.json` (1차 라우팅 출력).
- **A4**: 이중 scope enforcement (prompt + audit); `.meta direct edit` 제거 (API 면 없음).
- **A5**: CONVENTION.md에 파일 atomic 계약 + `manifest_version` 핸드셰이크.
- **A6**: 신선한 `search-result.json` 없을 때 Orchestrator가 Search 자동 호출.
- **A7**: NEW Step 0 환경 사전 점검.
- **A8**: Fixture 용도 구분; 골든 쿼리 decoy 오버랩 규칙.
- **A9**: CRIT-CNV4 제외 모든 CRIT-*가 `examples/unity-assets.yml` 기본값 사용.
- **C1**: 폴더 `unity-mcp-skill` vs YAML `name: unity-mcp-orchestrator` disambiguation.
- **C2**: `subagent_type="oh-my-claudecode:executor"` 네임스페이스 일관 적용.
- **C3**: byte-identity를 위한 atomic rename 시 sort-by-guid.
- **C4**: CRIT-IDX2는 no-op 경로 검증 (signature-skip, 이전 `assets.jsonl`의 byte-identical 복사).
- **C5**: 라우팅 라벨링 셋 5 → 10 (6 multi + 4 single), 임계치 상향.
- **C6**: `manifest_version` regex `^v\d+\.\d+$` + `stale_search` 거부.
- **C7**: 명세서 OQ#1 해결 — per-tier 필드 deltas 열거.
- **C8**: 정본 OMC manifest 출처 경로 인용.
- **C9**: `-Only` 필터 계약 + `lint-schema-doc-sync.ps1` 파서 포맷 명시.
- **C10**: 미해결 항목 해결 부록 추가.

### v5 → v6 (사용자 요청: 설치 워크플로 결정 반영)
- **Distribution 잠금**: `claude plugins install https://github.com/<owner>/unity-asset-skills` 단일 경로. 마켓플레이스 등록·수동 clone은 README "Other install options" 부록으로 격하.
- **README 스타일 잠금**: 5분 Quick Start 단일 레시피. 7단계 PowerShell 블록 + 4개 doctor 실패 패턴 진단 표 포함. Step 1의 README 생성 항목 재작성.
- **신규 스킬 `/unity-assets:doctor`**: 4번째 슬래시 커맨드, read-only 헬스체크. Repository Layout에 `unity-assets-doctor/SKILL.md` 추가. Step 7 신설로 구현 단계 정의. 새 합격 기준 **CRIT-DOC1** 추가.
- **Windows-only 범위**: `tests/run-crit-suite.sh` POSIX 미러 제거. 모든 명령·경로·예시는 PowerShell. 명세서에 신규 "지원 플랫폼" 섹션 추가, 비-Windows OS는 V1 범위 외로 명시.
- **명세서 신규 섹션 "설치 (사용자 사전 조건 + Quick Start)"**: 사전 조건 표, Quick Start 7단계, doctor 진단 표, 설치 비-목표를 명세서 본문에 추가. README는 이 섹션의 1:1 미러.
- **OMC 잔재 정리**: Step 6의 한 줄에 남아 있던 `Task(subagent_type="oh-my-claudecode:executor", ...)` 표기를 `Task(subagent_type="unity-asset-skills:asset-tagger", ...)`로 정정 (v4 누락분 회수).

### v4 → v5 (사용자 요청: 외부 MCP 의존성 명시)
- **의존성 명시**: 요구사항 요약 항목 6과 spec의 의존성 섹션에 [CoplayDev/unity-mcp](https://github.com/CoplayDev/unity-mcp) (MIT, Unity UPM 패키지 + Python MCP 서버)와 글로벌 `unity-mcp-skill`(오퍼레이터 가이드) 두 가지를 명확히 분리해서 추가. Unity 2021.3 LTS+ / Python 3.10+ / uv 요구 조건도 명시.
- **Step 0 보강**: "두 외부 의존성 확인 + 이름 disambiguate" 섹션으로 재구성. MCP for Unity 설치 경로(UPM git URL, Asset Store, OpenUPM)와 검증 방법(`mcp__manage_scene` 등 도구 가용성 확인) 추가.
- **MCP 도구 호출 표** (spec): 어떤 시점에 어떤 MCP for Unity 도구(`manage_gameobject`, `manage_scene`, `manage_prefabs`, `create_script`, `script_apply_edits`, `manage_camera` 등)를 거는지 매핑 표 추가.
- **금지 튜플 갱신** (spec): MCP for Unity의 실제 surface에 맞춰 `manage_assets(action="delete"|"move"|"rename")`, `manage_editor` 환경설정, `manage_build` 전체, `execute_menu_item` 위험 메뉴, `manage_packages(action="remove_package")`로 enumerable하게 정리.
- **README 사전 조건 섹션** (plan Step 1): MCP for Unity Unity 패키지·Python 서버·MCP 클라이언트 설정, unity-mcp-skill 글로벌 skill — 셋 모두 사용자 사전 설치 책임이며 누락 시 어떤 기능이 어떻게 실패하는지 명시.
- **신규 Risk #8**: 외부 MCP 의존성 누락 + 도구 surface 버전 변동 리스크와 5단 완화 (사전 점검·격리·명시적 중단·금지 튜플 수동 재검토·README 안내).

### v3 → v4 (사용자 요청: OMC 의존성 제거)
- **Subagent 교체**: 모든 `Task(subagent_type="oh-my-claudecode:executor", ...)` 호출을 자체 정의 `Task(subagent_type="unity-asset-skills:asset-tagger", ...)`로 교체. 플러그인이 OMC 미설치 환경에서도 동작하도록 자기-완결화.
- **신규 파일**: `unity-asset-skills/agents/asset-tagger.md` — 플러그인 자체 subagent 정의. Repository Layout과 Step 1에 추가.
- **plugin.json 정본 출처 변경**: OMC 마켓플레이스 (`~/.claude/plugins/marketplaces/omc/.claude-plugin/plugin.json`) → Claude Code 공식 plugin manifest 스펙. 필드 셋에 `agents/` 추가.
- **Step 0 재작성**: OMC `Task` 도구 스펙 확인 → Claude Code의 plugin-defined subagent 등록 메커니즘 확인. Fallback (general-purpose subagent) 경로 명시.
- **CRIT-CNV2 / Risk #1 / OQ#8 표현**: OMC 마켓플레이스 → Claude Code 공식 spec.
- **문서 컨벤션 (RALPLAN-DR, ADR, CRIT-*, OQ#)은 그대로 유지** — 도구 종속 아닌 일반적 계획 문서 구조화 패턴.

### v2 → v3 (iteration-2 Architect + Critic의 3개 정밀화, ACCEPT verdict)
- **R1 — `assets.jsonl.partial` 크래시 복구 의미론.** `schemas/state.json.schema.json`에 신규 `in_progress_run` (boolean), `completed_batches` (array<batch_id>) 필드 추가. Step 2 명시: `/unity-assets:index` 시작 시 `.partial`이 존재하고 `in_progress_run==true`이면 `.partial`에서 재개 (`completed_batches` row를 권위로 취급, `pending_batches`와 신규 변경 셋 batch만 재실행); 아니면 `.partial`을 orphan으로 폐기. 리스크 #6과 CRIT-IDX4 row에 문서화.
- **R2 — CRIT-ORC1 복합 임계치.** CRIT-ORC1은 이제 세 게이트 동시 충족 요구: ≥ 8/10 종합 AND ≥ 4/6 multi-intent 정답 AND ≥ 3/4 single-intent 정답. Class-masking 방지. Step 5, CRIT-ORC1 row, Step 6에 문서화.
- **R3 — 자동 Search 전 Orchestrator preflight 안내.** Orchestrator는 Search 자동 호출 시 어떤 subagent spawn보다 먼저 정확한 stdout 줄 `[unity-assets:build] No fresh search-result.json — running :search first (Ctrl+C to abort).` 출력 필수. 사용자 abort 창 보장. CONVENTION.md cross-skill 섹션, Step 4 입력+preflight 항목, CRIT-EE1 e2e 테스트 단언에 문서화.

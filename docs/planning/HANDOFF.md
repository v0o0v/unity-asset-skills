# Team 실행 핸드오프 브리프 — unity-asset-skills

> 이 문서는 **다음 Claude Code 세션**이 `/oh-my-claudecode:team`으로 본 계획서를 실행할 때 읽고 따를 지침입니다. 인터뷰·계획 단계는 이미 끝났고 합의된 결과만 실행합니다.

## 상태 (2026-05-23 기준)

| 항목 | 상태 | 위치 |
|------|------|------|
| Spec | **locked** (모호도 9%, 사용자 강화 목표 10% 충족) | `.omc/specs/deep-interview-unity-asset-skills.md` |
| Plan | **locked v6** (Planner→Architect→Critic 2회 합의 + 사용자 정정 2회) | `.omc/plans/unity-asset-skills-plan.md` |
| 실행 채널 | **team** (사용자 선택) | — |
| 작업 디렉터리 | greenfield, 새 파일은 `unity-asset-skills/` 하위에 작성 | `D:\ClaudeCowork\unitySkills\` |
| 외부 의존성 | 본 작업에서는 설치·실행하지 않음 (코드 생성만) | — |

## 호출 방법

다음 세션 시작 시 사용자가 입력할 명령:

```
/oh-my-claudecode:team .omc/plans/unity-asset-skills-plan.md
```

team 스킬이 묻는 파라미터(에이전트 수, 모델 등)는 다음 권장값 사용:
- **에이전트 수**: 3~5 (작업 분해 절 참조)
- **모델**: 표준 작업은 sonnet, doctor 진단·합격 기준 매핑 작성은 opus 권장
- **공유 plan 파일**: `.omc/plans/unity-asset-skills-plan.md`

## 입력

team이 반드시 읽어야 할 두 파일:
1. **계획서 (작업 진실원)**: `.omc/plans/unity-asset-skills-plan.md` — 405 lines, v6, Step 0~7 + 합격 기준 매핑 + 리스크 + 부록.
2. **명세서 (참고용 grounding)**: `.omc/specs/deep-interview-unity-asset-skills.md` — 543 lines, v6 반영, 토폴로지·합격 기준·설치 섹션 포함.

선택적으로 읽을 수 있는 audit trail:
- `.omc/drafts/unity-asset-skills-plan-v1.md` (Planner 초안)
- `.omc/drafts/unity-asset-skills-plan-v2.md` (Architect+Critic 16개 수정 반영)

## DO (반드시 따를 것)

- **계획을 그대로 구현**: Step 0 → Step 1 → ... → Step 7 순서. 각 단계가 명시한 파일·경로·라인을 그대로 따른다.
- **18개 CRIT-* 모두 검증 가능하게**: CRIT-EE1, CRIT-IDX1-4, CRIT-SCH1-4, CRIT-ORC1-4, CRIT-CNV1-4, CRIT-DOC1. 매 파일 작성 후 어떤 CRIT-*가 진전됐는지 commit 메시지 또는 진행 로그에 명시.
- **모든 산출 문서는 한글**: README.md, CONVENTION.md, AGENTS.md, SKILL.md 본문은 한글. 단 코드 식별자·파일 경로·CRIT 라벨·JSON 키는 영문 유지 (전역 CLAUDE.md "사용자 전역 환경설정" 규칙 참조).
- **Windows-only**: PowerShell 명령·경로(`C:\...`, `~\.claude\...`)만 사용. `.sh` 미러 생성 금지.
- **자체 subagent 호출 형식**: `Task(subagent_type="unity-asset-skills:asset-tagger", model="haiku")` (Indexer batch tagging). OMC `oh-my-claudecode:executor`는 사용하지 않음.
- **이중 scope enforcement 표기**: Orchestrator는 prompt-level 금지 튜플 + audit log 두 층 모두 구현. 금지 튜플 정확한 목록은 plan Step 4 참조.
- **파일 atomicity**: 모든 산출 파일은 `<name>.tmp` 작성 후 atomic rename. partial 인덱싱은 `.partial` 사용. 자세한 규약은 CONVENTION.md "파일 atomic 계약" 섹션.
- **agents/asset-tagger.md 등록 방식**: Step 0에서 Claude Code plugin-defined agent 등록 메커니즘 확인 후 따른다. 만약 직접 등록이 동작하지 않으면 fallback (`subagent_type="general-purpose"` + prompt 직접 전달)으로 전환하고 그 사실을 AGENTS.md에 기록.
- **CRIT 검증은 Unity 실행 없이**: 모든 테스트는 `unity-mcp-skill`/MCP for Unity 호출을 stub하는 dry-run 래퍼로 진행. Unity Editor 실제 실행 불필요.

## DO NOT (절대 하지 말 것)

- ❌ **재-인터뷰**: 사용자에게 요구사항 질문 금지. spec이 잠겨 있음 (모호도 9%).
- ❌ **재-계획**: plan v6 구조·결정 변경 금지. 단순 typo·번역 오류는 인라인 수정 OK.
- ❌ **외부 의존성 설치 시도**: MCP for Unity, unity-mcp-skill, Unity Editor 설치 시도하지 않음. README의 사전 조건 안내만 작성.
- ❌ **OMC 의존**: `oh-my-claudecode:executor` 같은 OMC subagent 직접 호출 금지 (v4 결정).
- ❌ **마켓플레이스 등록**: 본 플러그인을 OMC 또는 다른 마켓플레이스에 등록·publish 시도 금지 (v6 결정). 배포는 git URL 단독.
- ❌ **macOS/Linux 지원 코드**: V1 범위 외 (v6 결정).
- ❌ **자동 rollback / git 자동 커밋**: 본 플러그인 자체는 사용자 작업물에 자동 git 작업 안 함. 사용자 책임 원칙 (v3 round 10).
- ❌ **`.meta` 직접 쓰기 표기**: API surface 부재. CRIT-ORC3에서 제거됨 (v3 R1).

## 권장 병렬 작업 분해 (team이 N=3~5일 때)

### 3-agent 분해 (최소)
- **Agent A — Foundation & Convention**: Step 0 (검증·문서화), Step 1 (plugin.json, CONVENTION.md, AGENTS.md, README.md, examples/, schemas/ 7종).
- **Agent B — 3개 행위 스킬**: Step 2 (Indexer + agents/asset-tagger.md + prompts/), Step 3 (Search), Step 4 (Orchestrator).
- **Agent C — Test infra + Doctor**: Step 5 (fixtures, golden-queries.yml, run-crit-suite.ps1), Step 6 (테스트 18개), Step 7 (Doctor 스킬 + test-doctor-diagnosis.ps1).

### 5-agent 분해 (선호)
- **Agent A — Foundation**: Step 0, Step 1 (스키마·CONVENTION.md·plugin.json·README.md·AGENTS.md·examples).
- **Agent B — Indexer**: Step 2 + `agents/asset-tagger.md`.
- **Agent C — Search**: Step 3.
- **Agent D — Orchestrator + Doctor**: Step 4, Step 7.
- **Agent E — Test infra**: Step 5, Step 6 (모든 CRIT-* 테스트).

각 분해에서 Step 1이 다른 모든 단계의 *입력 의존성*. Step 1 schemas/ 파일이 락된 다음에야 Step 2-4-7이 본격 진행 가능. team의 sequencing/coordination이 이를 처리.

## 종료 조건

team이 "완료"로 표시하려면 다음 모두 충족:

1. `unity-asset-skills/` 디렉터리에 plan Repository Layout의 모든 파일·디렉터리 존재 (단, fixture 하위의 실제 .meta·prefab 파일 내용은 Agent E가 채움).
2. 18개 CRIT-* 각각에 대해 fixture + 테스트 스크립트가 만들어졌고 `run-crit-suite.ps1`로 호출 가능.
3. **자동 검증 실행은 별도 세션에서 수동으로**: team 안에서 CRIT 스위트를 실제로 돌리지 않음 (그건 사용자 검증 단계). team은 테스트 스크립트·fixture 작성까지만.
4. `plan.md`에 표시된 모든 Open Question 8개가 plan 부록 또는 산출 파일에서 해결됨.
5. `AGENTS.md`에 Step 0의 환경 확인 결과 (실제 plugin-defined agent 등록 메커니즘 동작 여부 등) 기록됨.

## 핵심 결정의 근거 (재논의 금지 — 참고용)

| 결정 | 근거 위치 | 비고 |
|------|-----------|------|
| 2-layer 인덱스 | spec Round 1 | package summary + asset detail |
| Hybrid 수집 (filesystem + 온디맨드 unity-mcp) | spec Round 2 | Editor 상시 실행 불요 |
| LLM-as-Search (embedding 없음) | spec Round 3 | 인프라 0 |
| Confidence-gated hybrid 자동화 | spec Round 4, 16 | auto≥0.70 / confirm≥0.40 |
| 글로벌 스킬 + 프로젝트 로컬 데이터 | spec Round 5 | 재사용성 |
| LLM-tagging은 내부 batch subagent | spec Round 6, 15 | 외부 API 0 |
| 증분 + 수동 풀빌드 | spec Round 7 | 수동 명령 우선 |
| Action scope C (script 생성까지) | spec Round 9 | full automation |
| 사용자 책임 rollback | spec Round 10 | 의도된 단순화 |
| Schema 단계화 (minimal/normal/rich) | spec Round 11 | `.yml`로 조절 |
| OMC 의존성 제거 (v4) | plan Changelog v3→v4 | 자기-완결적 플러그인 |
| 외부 MCP 의존성 명시 (v5) | plan Changelog v4→v5 | CoplayDev/unity-mcp + unity-mcp-skill |
| Git URL 단일 배포 + Quick Start + Doctor + Windows-only (v6) | plan Changelog v5→v6 | 설치 워크플로 |

이 결정들 중 하나라도 흔들리려는 충동이 든다면, **반드시 사용자에게 명시적으로 확인** 후에만 변경. 임의 재결정 금지.

## 진행 로그

team은 작업 중 진행 상황을 `.omc/logs/team-execution.log`에 append할 것 (선택). 디렉터리가 없으면 생성. 각 줄에 timestamp + agent ID + 행위 한 줄 기록.

## 종료 후 사용자가 할 일

team이 끝나면 사용자가 별도 세션에서 수동 검증:

```powershell
cd D:\ClaudeCowork\unitySkills\unity-asset-skills\tests
.\run-crit-suite.ps1
# 18개 CRIT-* 모두 PASS인지 확인
```

추후 실사용 검증 (선택, Unity Editor 필요):
1. MCP for Unity 설치된 별도 Unity 프로젝트 준비
2. `claude plugins install <local-path-or-git-url>`
3. `/unity-assets:doctor` → 4/4 ✓
4. `/unity-assets:index` 후 검색·빌드 시도

---

**핸드오프 완료**. 다음 세션이 이 브리프 + plan + spec 셋을 읽고 team을 호출하면 즉시 실행 가능.

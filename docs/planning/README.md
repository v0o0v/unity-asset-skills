# docs/planning — 설계·계획·실행 기록

이 디렉터리는 `unity-asset-skills` v0.1.0이 만들어진 과정 그 자체다. **이 플러그인은 21라운드 deep-interview → planner·architect·critic 6-iteration 합의 → team 채널 실행** 으로 만들어졌고, 그 산출물 4종을 여기에 모았다. "왜 이런 결정을 내렸는가"가 궁금한 컨트리뷰터·사용자를 위한 보존 기록.

| 파일 | 내용 | 페이지 |
|------|------|------|
| [SPEC.md](./SPEC.md) | Deep-interview 명세서. 21라운드 인터뷰 끝에 도달한 모호도 9% (사용자 강화 임계치 10% 충족) 상태. 토폴로지·목표·제약·합격 기준 18개 (CRIT-EE1·IDX1~4·SCH1~4·ORC1~4·CNV1~4·DOC1)·온톨로지·설치 Quick Start 포함. | ~543 lines |
| [PLAN.md](./PLAN.md) | Consensus Plan v6. RALPLAN-DR + ADR + 8 Step 구현 계획 + 합격 기준 매핑 + 리스크 + v1→v6 변경 이력. plan v6는 사용자 정정 2회 + Critic APPROVED를 거쳐 잠금. | ~405 lines |
| [HANDOFF.md](./HANDOFF.md) | Team 실행 핸드오프 브리프. 다음 세션이 `/oh-my-claudecode:team`을 호출할 때 따를 DO/DO NOT, 권장 5-agent 분해, 종료 조건. | ~130 lines |
| [EXECUTION_LOG.md](./EXECUTION_LOG.md) | 실제 실행 timestamp 트레일. wave 1 (Foundation) → wave 2 (4 SKILL.md) → wave 2D (18 CRIT 테스트) 진행, 발견된 결정 사항 (plugin.json 위치 정정, name 필드 → `unity-assets`). | ~20 lines |

## 결정 흐름 요약

1. **Round 0~14**: 토폴로지 4 컴포넌트 (Indexer / Search / Orchestrator / Convention) 합의 → 매 라운드 모호도 측정.
2. **Round 15 (사용자 정정)**: "분석은 클로드 코드 내부적으로 다 해야해" → 외부 Haiku API 가정 폐기 → batch subagent fan-out으로 전환. 결정적 전환점.
3. **Round 16~20**: 합격 기준 18개 (4 컴포넌트 × 4 + EE + DOC) 모두 채택. 모호도 9% 도달.
4. **Plan v1→v6**: Architect+Critic의 16개 수정 (v2) → R1/R2/R3 3개 정밀화 (v3) → OMC 의존성 제거 (v4) → 외부 MCP 의존성 분리 (v5) → 설치 워크플로 + Doctor 스킬 + Windows-only (v6).
5. **Team 실행**: handoff brief 따라 main-loop 단일 author 실행 (subagent fan-out은 1M-컨텍스트 크레딧 이슈로 미사용). 43 파일 작성, 18 CRIT 매핑 검증.

## 재현 가능성

본 산출물을 fork/clone하여 동일한 접근(deep-interview → plan → CRIT-driven implementation)을 다른 도메인에 적용하고 싶다면:

- `oh-my-claudecode` 플러그인의 `deep-interview` + `plan` + `team` 스킬 사용.
- HANDOFF.md의 DO/DO NOT 패턴 차용.
- CRIT 18개 모델 (4 컴포넌트 × 4 + EE + DOC): 각 컴포넌트별 검증 가능한 합격 기준을 명시하고 dry-run 가능하게 stub.

## 라이선스

본 디렉터리의 모든 문서는 플러그인 본체와 동일 라이선스 (MIT).

# unity-asset-skills

Unity 에셋 인지형 Claude Code 플러그인. 자연어 한 줄로 프로젝트의 이미 설치된 에셋을 검색하고, 씬·프리팹·ScriptableObject·스크립트 생성까지 자동화한다.

- **4개 슬래시 커맨드**: `/unity-assets:index`, `/unity-assets:search`, `/unity-assets:build`, `/unity-assets:doctor`
- **외부 API 0**: 모든 의미 분석은 Claude Code 세션 내부 batch subagent. 별도 API 키 불필요.
- **인프라 0**: embedding·벡터 DB 없음. LLM-as-Search.
- **지원 플랫폼**: V1은 **Windows 전용**. macOS / Linux는 V1 범위 외.

> git이 안전망. 본 플러그인은 자동 rollback·git 커밋·dry-run 게이팅을 하지 않는다. 작업 전에 `git status`로 깨끗한 트리를 확인하고, 잘못 적용된 변경은 `git restore`로 되돌린다.

---

## 사전 조건 (사용자가 일회성으로 직접 설치)

| 항목 | 버전 | 출처 |
|------|------|------|
| Unity Editor | 2021.3 LTS 이상 | [unity.com/download](https://unity.com/download) (Unity Hub 통해) |
| Claude Code | 최신 | [claude.com/claude-code](https://claude.com/claude-code) |

본 플러그인은 두 외부 의존성 위에 동작한다. **둘 다 사용자가 직접 설치한다.**

1. **MCP for Unity** ([CoplayDev/unity-mcp](https://github.com/CoplayDev/unity-mcp), MIT) — Unity Editor와 통신하는 MCP 서버. Unity UPM 패키지 + Python MCP 서버 두 부분으로 구성되며, **Python 3.10+와 `uv`가 필요하다 (MCP for Unity 설치 절차에서 함께 셋업)**. 본 플러그인 자체는 Python을 사용하지 않으며, 단지 이 MCP 서버를 경유해 Unity Editor 도구를 호출한다.
2. **`unity-mcp-skill`** — 위 MCP 도구들의 사용 가이드인 글로벌 Claude Code skill. 디스크 폴더는 `~/.claude/skills/unity-mcp-skill/`, SKILL.md의 `name:` 값은 `unity-mcp-orchestrator`.

본 플러그인 자체는 Unity 바인딩이나 MCP 통신을 재구현하지 않는다.

---

## Quick Start (5분 레시피)

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
claude plugins install https://github.com/v0o0v/unity-asset-skills

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

---

## 설치 단계가 실패할 때 진단

`/unity-assets:doctor`가 알려주는 실패 패턴별 권장 조치:

| Doctor 출력 | 의미 | 권장 조치 |
|-------------|------|-----------|
| ✗ Unity Editor reachable via MCP | Unity Editor 미실행 또는 MCP for Unity Python 서버 미구동 | Unity Editor 열고 5초 대기 후 재시도. 그래도 실패하면 [CoplayDev/unity-mcp 트러블슈팅](https://github.com/CoplayDev/unity-mcp#troubleshooting) |
| ✗ unity-mcp-skill global skill present | `~\.claude\skills\unity-mcp-skill\` 부재 | Unity 메뉴 > MCP for Unity > Skill Sync > Sync now |
| ✗ Project .claude/ structure ready | 현재 cwd가 Unity 프로젝트 루트가 아님 | Unity 프로젝트 루트로 이동 후 `/unity-assets:index` 한 번 실행 (`.claude/unity-asset-index/` 자동 생성) |
| ✗ unity-assets.yml valid | `.claude/unity-assets.yml` 부재 또는 손상 | `<plugin-install-path>\examples\unity-assets.yml`을 프로젝트 `.claude\`로 복사 |

doctor는 read-only — 어떤 파일도 수정·생성·삭제하지 않는다. 자동 fix 옵션은 V1 범위 외.

---

## 4개 슬래시 커맨드

| 커맨드 | 책임 | 산출 파일 |
|--------|------|-----------|
| `/unity-assets:index` | 프로젝트 에셋을 2-layer 인덱스로 수집 (filesystem 1차 + unity-mcp 온디맨드 deep-fetch). asset-tagger subagent fan-out으로 의미 태그 부여. 증분 + R1 크래시 복구. | `<unity-project>/.claude/unity-asset-index/{manifest.json, packages.jsonl, assets.jsonl, state.json}` |
| `/unity-assets:search "..."` | 자연어 의도 → multi-category 라우팅 → sub-intent별 retrieval (package-first drill-down 기본, 2000+ 또는 rich 시 map-reduce). | `<unity-project>/.claude/unity-asset-index/search-result.json` |
| `/unity-assets:build "..."` | search-result.json 기반 confidence-gated Orchestrator. 신선한 search-result.json 없으면 자동 Search 호출 (R3 안내). 씬/프리팹/스크립트 생성까지 자동, 파괴적 작업 금지. | scene 변경 + `orchestrator-audit.jsonl` append |
| `/unity-assets:doctor` | 4개 의존성 read-only 헬스체크 (Unity Editor, unity-mcp-skill, .claude/ 구조, unity-assets.yml). | stdout 4행 ✓/✗ + 종료 코드 |

자세한 호출 흐름·계약은 [CONVENTION.md](./CONVENTION.md), 내부 개발자 가이드는 [AGENTS.md](./AGENTS.md), 플러그인을 실제 Unity 프로젝트에서 시험하며 동시에 개발하는 워크플로는 [docs/dev-loop.md](./docs/dev-loop.md).

---

## 비-목표

- 외부 Anthropic API 직접 호출 (모든 분석은 Claude Code 내부)
- 벡터 임베딩 / 외부 벡터 DB
- File watcher / 자동 재인덱스 데몬
- 자동 rollback / git 자동 커밋 / dry-run 강제
- Asset Store API 연동 (downloaded 로컬 파일만 처리)
- Multi-project 동시 인덱싱
- 비-Windows OS 1급 지원 (V1 범위 외)
- 마켓플레이스 등록 (`extraKnownMarketplaces` 사용 — 부록 참조)

---

## Other install options (비-1급)

다음은 명시적으로 비-1급 설치 경로이며 README 본문에서 안내하지 않는다.

- **수동 git clone**: `~/.claude/plugins/`에 직접 clone 후 Claude Code 재시작. 권장하지 않음 (업데이트 트래킹 부담).
- **Unity Asset Store / OpenUPM**: 본 플러그인은 Asset Store에 등록되지 않으며, OpenUPM에서 배포되는 것은 의존성인 MCP for Unity(`com.coplaydev.unity-mcp`)일 뿐 본 플러그인이 아니다.
- **마켓플레이스 등록**: 본 플러그인은 1급 배포 경로로 `claude plugins install <git URL>`만 지원한다.

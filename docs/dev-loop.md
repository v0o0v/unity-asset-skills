# dev-loop — 양방향 개발 워크플로

`unity-asset-skills`를 실제 Unity 프로젝트에서 사용하면서 동시에 플러그인 자체를 개발하는 워크플로. 두 개의 Claude Code 세션을 동시에 띄워, 한쪽에서 슬래시 커맨드를 시험하고 다른 한쪽에서 회귀를 진단·수정하며 **재설치 없이 즉시 반영**한다.

## 큰 그림

```
┌─────────────────────────────────┐        ┌─────────────────────────────────┐
│ Window A — plugin dev           │        │ Window B — plugin user           │
│ cwd = D:\…\unitySkills          │        │ cwd = D:\…\testbed               │
│                                 │        │                                  │
│ claude                          │        │ claude --plugin-dir D:\…\unity… │
│                                 │        │                                  │
│ 역할:                            │        │ 역할:                             │
│  - 소스 편집 (SKILL.md / 스키마) │        │  - /unity-assets:doctor          │
│  - testbed 산출물 진단            │        │  - /unity-assets:index           │
│  - git commit / push             │        │  - /unity-assets:search "..."    │
│                                 │        │  - /unity-assets:build "..."     │
│                                 │        │  - 문제 발생 시 A로 보고          │
└────────────────┬────────────────┘        └─────────────────┬────────────────┘
                 │                                            │
                 │           filesystem 공유                    │
                 └───────── testbed/.claude/… 산출물 ──────────┘
                              + .claude/_debug/console.log
```

## 사전 조건

[tests/integration/README.md](../tests/integration/README.md)의 testbed 셋업을 완료해 둔 상태.

- testbed = `D:\ClaudeCowork\unitySkills\tests\integration\testbed\`
- Unity Editor가 testbed 프로젝트를 연 상태 (MCP for Unity Python 서버 동작)
- 무료 Asset Store 패키지 몇 개 임포트 (recall 다양성용)
- 본 플러그인 git clone = `D:\ClaudeCowork\unitySkills\`

## 두 윈도우 시작

### Window A (plugin dev — 지금 사용 중인 이 세션)

별도 동작 없음. 이미 `D:\ClaudeCowork\unitySkills\` 에서 띄운 claude 세션이 그대로 Window A 역할.

### Window B (plugin user — 새로 띄움)

새 PowerShell:

```powershell
# 기존 설치본이 있으면 한 번만 제거 (이후 --plugin-dir만으로 사용)
claude plugins uninstall unity-assets   # 에러 무시 OK (설치 안 했으면)

# Window B 시작 — 본 소스 트리를 plugin으로 직접 로드
cd D:\ClaudeCowork\unitySkills\tests\integration\testbed
claude --plugin-dir D:\ClaudeCowork\unitySkills
```

`--plugin-dir`로 시작하면 본 소스 디렉터리의 `.claude-plugin/plugin.json`이 그대로 등록되어 `/unity-assets:*` 슬래시 커맨드가 사용 가능해진다.

**핵심**: Window A에서 `skills/unity-assets-index/SKILL.md`를 저장한 직후 Window B에서 `/unity-assets:index`를 호출하면, **새 SKILL.md 내용이 그대로 반영**된다. 별도 재설치·재시작 불필요. (Claude Code skill은 호출 시점에 정의 파일을 새로 읽는다.)

> 이미 실행 중인 슬래시 커맨드에는 적용 안 됨 — 다음 호출부터 반영.

### `--plugin-dir` vs `claude plugins install` 우선순위

- 두 경로가 같은 plugin name (`unity-assets`)을 등록하려 하면 `--plugin-dir` 쪽이 우선.
- 충돌이 의심되면 한 번 `claude plugins uninstall unity-assets` 후 항상 `--plugin-dir`만 사용.
- "방금 수정했는데 반영 안 되는 것 같다" → Window B를 종료 후 재시작 (`Ctrl+C` 후 `claude --plugin-dir ...`).

## 양방향 흐름

### 시나리오 1 — Window B에서 문제 발견

Window B에서 사용자가 슬래시 호출:

```
> /unity-assets:index
[unity-assets:index] error: subagent batch 3 returned malformed JSON
```

→ Window B는 그대로 두고 (보고용으로 메시지 확인 가능), Window A로 이동.

### 시나리오 2 — Window A에서 진단

**옵션 a — 한 줄로 즉시 진단 요청** (가장 빠름):

```
> /unity-assets:index가 batch 3에서 malformed JSON 에러로 멈춤. 진단해줘.
```

저(Window A의 Claude)가 testbed의 `.claude/unity-asset-index/state.json`·`assets.jsonl.partial`·`assets.jsonl`을 직접 Read하여 `bad_rows`·`pending_batches`를 확인하고 원인을 분류한다.

**옵션 b — diagnose.ps1로 한 번에 스냅샷** (포렌식 또는 여러 산출물 한꺼번에 보고 싶을 때):

```powershell
# Window A의 별도 PowerShell (또는 Window A 세션에 Bash로 호출해도 OK)
.\tools\diagnose.ps1
```

산출: `.omc/diagnosis/<timestamp>/{unity-asset-index/, _debug/, unity-assets.yml, SUMMARY.md}`.
SUMMARY.md에 다음이 한 페이지로 정리됨:
- `.partial` / `in_progress_run` 크래시 신호
- `state.json`: pending/bad 사유 breakdown
- `manifest.json`: 버전·last_run
- `assets.jsonl`: coverage, type breakdown, head N행, parse 실패 행 수
- `packages.jsonl`: 패키지 목록
- `search-result.json`: manifest_version 핸드셰이크, groups·top candidate·reasoning 길이
- `orchestrator-audit.jsonl`: 금지 튜플 위반, tool breakdown, tail N행
- `unity-assets.yml` 사용자 override 내용
- (있으면) Unity console tail

그 다음 한 줄:

```
> .omc/diagnosis/<timestamp>/SUMMARY.md 읽고 분석해줘
```

저는 그 한 파일을 읽어 진단·트리아주·수정 위치를 결정한다.

### 시나리오 3 — Window A에서 수정 → Window B에서 재시도

저(Window A)가 진단 결과로 예컨대 `skills/unity-assets-index/prompts/subagent-tagger.md`의 출력 제약 문구를 강화한 뒤:

- 변경 사항 한 줄 보고 + (필요 시) commit 제안.
- Window B로 가서 `/unity-assets:index`를 다시 호출하면 즉시 반영된 새 prompt로 동작.

```
[Window B]
> /unity-assets:index
[unity-assets:index] OK — 677 assets indexed, 0 bad_rows, 0 pending_batches
```

### 시나리오 4 — Unity Editor 자체 에러

Unity 측 NullReferenceException 등은 `read_console` MCP 도구를 거쳐야 가져옴.

**옵션 a — Window B 안에서 한 줄 부탁** (자연스럽고 권장):

```
[Window B]
> mcp__read_console 호출해서 결과를 .claude/_debug/console.log에 저장해줘
```

→ Window B의 Claude가 read_console + Write로 처리. 그 다음 Window A에서 진단 시 자동 포함.

**옵션 b — 별도 PowerShell에서 헬퍼 호출**:

```powershell
cd D:\ClaudeCowork\unitySkills\tests\integration\testbed
..\..\..\tools\dump-console.ps1
```

`dump-console.ps1`은 headless `claude -p`로 read_console 한 번 호출 + 파일 저장. `--max-budget-usd 0.10`으로 캡.

## 진단 트리아주 룩업 표

Window A의 저(또는 사용자 직접)가 SUMMARY.md를 보고 다음 패턴으로 분류:

| 증상 | 의심 위치 | 수정 후보 |
|------|-----------|-----------|
| `in_progress_run = true` AND `.partial` 존재 | 크래시 복구 분기 | `skills/unity-assets-index/SKILL.md` R1 의미론, `schemas/state.json.schema.json` |
| `pending_batches > 0`, 사유 = `subagent_timeout` | subagent 60s 초과 | `prompts/subagent-tagger.md` 입력 batch 크기 줄이기 OR `unity-assets.yml::batch_size` 튜닝 |
| `bad_rows > 0` | asset-tagger가 JSON 외 출력 | `prompts/subagent-tagger.md`의 "JSON 외 출력 금지" 강화, 예시 추가 |
| coverage < 100% AND `pending = bad = 0` | Glob 패턴 또는 ignore_paths 누락 | `skills/unity-assets-index/SKILL.md` Step 2, `examples/unity-assets.yml::ignore_paths` |
| `assets.jsonl` row의 `llm_summary`가 영문 | tagger prompt가 한글 강제 미적용 | `prompts/subagent-tagger.md`의 "한글 필수" 강조 |
| `assets.jsonl` row의 `type` = `Unknown` 다수 | tagger가 일부 확장자 미인식 | `prompts/subagent-tagger.md`의 type 판정 가이드 보강 |
| `search-result.json::manifest_version` 불일치 | stale_search 흐름 또는 핸드셰이크 버그 | `skills/unity-assets-search/SKILL.md` Step 6, `skills/unity-assets-build/SKILL.md` Step 1 |
| `search-result.json` 부재인데 Window B에서 build 호출 → R3 안내 + 자동 search | (정상 동작) | — |
| `audit` 금지 튜플 > 0 | Orchestrator prompt layer 1 enforcement 실패 | `skills/unity-assets-build/SKILL.md` Step 4의 금지 튜플 임베드 강화 |
| `audit` total = 0 인데 build 호출 후 | unity-mcp-orchestrator 위임 끊김 또는 mcp_unavailable | `tools/dump-console.ps1`로 console 확인, MCP for Unity 재연결 확인 |
| top candidate confidence 모두 < 0.40 → reject | Search recall 품질 또는 인덱싱 태깅 품질 | `prompts/subagent-tagger.md` (태깅 강화), `skills/unity-assets-search/SKILL.md` (라우팅·드릴다운 로직) |
| `:doctor`가 ✗ | 해당 항목 검사 로직 또는 외부 의존성 | `skills/unity-assets-doctor/SKILL.md` 또는 실제 환경 (사전 조건 README) |
| console.log에 Unity 측 Exception | Unity Editor / MCP for Unity / 사용자 에셋 측 회귀 | 본 플러그인 책임 외 — CoplayDev/unity-mcp 또는 사용자 에셋 점검 |

## 보안·안전

- `--plugin-dir`는 신뢰하는 디렉터리에만 사용. Window B를 testbed에서 띄울 때 그 testbed는 본인 머신.
- `dump-console.ps1`은 `--allowedTools "mcp__read_console,Write"`로 read_console + 파일 쓰기만 허용.
- `diagnose.ps1`은 testbed → `.omc/diagnosis/`로 복사만. testbed 자체 수정 없음.
- `.omc/diagnosis/`는 `.gitignored` — 개인 머신 진단 스냅샷은 commit 안 됨.

## 한계

- **Window B의 Claude 세션 stdout/stderr 자체는 Window A가 못 봄**. 사용자가 "이런 에러 떴어요" 한 줄로 알려주거나, copy-paste 또는 screenshot으로 전달.
- **이미 실행 중인 슬래시 커맨드에는 SKILL.md 변경 즉시 반영 안 됨** — 다음 호출부터 반영.
- **Unity Editor 측 에러는 read_console 거쳐야** 가져옴. MCP for Unity 연결이 끊겼으면 console.log를 사용자가 Unity Editor의 Console 탭에서 직접 복사.
- **LLM jitter**: tagger·search·orchestrator 모두 LLM 호출이라 같은 입력에 같은 출력 보장 안 됨. 회귀가 의심돼도 1회 재시도 후 판단.
- **plugin.json 변경**은 Window B 재시작 필요할 수 있음 — Claude Code가 manifest를 세션 시작 시점에 한 번 읽는 것으로 보임.

## Troubleshooting

| 증상 | 시도 |
|------|------|
| Window B에서 `/unity-assets:*`가 안 보임 | `claude --plugin-dir <절대경로>` 절대 경로로 다시 시작. `claude plugins list`로 등록 확인. |
| SKILL.md 수정 후 반영 안 됨 | Window B의 슬래시 커맨드 호출이 새 호출인지 확인 (실행 중인 호출은 안 됨). 그래도 안 되면 Window B 재시작. |
| `claude plugins install`로 설치한 것과 충돌 의심 | `claude plugins uninstall unity-assets` 후 항상 `--plugin-dir`만 사용. |
| `diagnose.ps1`이 testbed 못 찾음 | `-Testbed <절대경로>`로 명시. |
| `dump-console.ps1`이 FAIL — `mcp__read_console` 미인식 | Unity Editor 실행 + MCP for Unity Python 서버 동작 확인. 보통 Unity 메뉴 > MCP for Unity > Server Status. |
| `dump-console.ps1`이 비용 캡 초과 | `-MaxBudgetUSD 0.50` 같이 늘리거나, Window B 안에서 한 줄로 직접 부탁 (옵션 a). |

## 워크플로 한 줄 요약

> Window B에서 시험, Window A에서 진단·수정, **재설치 없이 즉시 반영**. testbed 산출물은 filesystem 공유로 Window A가 직접 읽음, Unity console은 read_console MCP로 파일 덤프.

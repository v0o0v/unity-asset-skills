# tests/ — CRIT 스위트

`unity-asset-skills`의 18개 합격 기준(CRIT-EE1·CRIT-IDX1~4·CRIT-SCH1~4·CRIT-ORC1~4·CRIT-CNV1~4·CRIT-DOC1)을 검증하는 자동화 테스트.

## 사전 조건

- Windows + PowerShell 5.1 이상.
- `claude` CLI on PATH (Claude Code).
- 본 플러그인이 설치되어 슬래시 커맨드 `/unity-assets:*`가 등록된 상태.
- Python 3.10+ on PATH (lint 스크립트가 JSON canonicalize에 사용).
- **Unity Editor 미실행 상태에서도 모두 PASS** — 모든 unity-mcp 호출은 stub된다.

## 전체 실행

```powershell
cd D:\ClaudeCowork\unitySkills\unity-asset-skills\tests
.\run-crit-suite.ps1
```

종료 코드 0 = 18개 모두 PASS. 1 = 하나 이상 FAIL.

## 부분 실행 (`-Only` 플래그)

`-Only`는 CRIT-ID 접두어 필터. 콤마 구분, case-insensitive. 각 접두어는 해당 접두어로 시작하는 모든 CRIT-ID 테스트와 매치.

```powershell
.\run-crit-suite.ps1 -Only IDX          # CRIT-IDX1..4
.\run-crit-suite.ps1 -Only SCH,ORC      # CRIT-SCH1..4 + CRIT-ORC1..4
.\run-crit-suite.ps1 -Only CNV,DOC      # CRIT-CNV1..4 + CRIT-DOC1
.\run-crit-suite.ps1 -Only EE           # CRIT-EE1 단독
```

지원 접두어: `EE`, `IDX`, `SCH`, `ORC`, `CNV`, `DOC`.

## 단독 실행 (스크립트 직접)

```powershell
.\lint\lint-schema-doc-sync.ps1         # CRIT-CNV1 단독
.\e2e\test-ee1-zombie-survival.ps1      # CRIT-EE1 단독
.\unit\test-coverage.ps1                # CRIT-IDX1 단독
```

각 스크립트는 단독으로도 실행 가능하며, 종료 코드 0 = PASS / 1 = FAIL을 emit한다.

## 결과 요약 파일

전체 실행 후 `tests/_last-run.json`에 요약 작성:

```json
{
  "ts": "2026-05-23T10:00:00Z",
  "total": 18,
  "passed": 18,
  "failed": 0,
  "results": [
    {"crit": "CRIT-EE1", "status": "PASS", "duration_ms": 12340, "script": "e2e/test-ee1-zombie-survival.ps1"},
    ...
  ]
}
```

## 설정 변형 정책

- **CRIT-CNV4 외 모든 테스트**는 `examples/unity-assets.yml`의 잠긴 기본값으로 실행. 테스트 setup이 fixture의 `.claude/unity-assets.yml`에 기본 파일을 복사.
- **CRIT-CNV4 (test-yml-override.ps1)** 만 유일하게 의도적으로 yml을 non-default 값으로 변형하여 전파됨을 검증.

## CRIT ↔ 스크립트 매핑

| CRIT-ID | 스크립트 | 시나리오 요약 |
|---------|----------|---------------|
| CRIT-EE1 | `e2e/test-ee1-zombie-survival.ps1` | 단일-입력 흐름 + R3 안내 줄 단언 |
| CRIT-IDX1 | `unit/test-coverage.ps1` | `.meta` 100% 인덱스 |
| CRIT-IDX2 | `unit/test-idempotency.ps1` | no-op 경로 byte-identity |
| CRIT-IDX3 | `unit/test-incremental.ps1` | K 파일 수정 → K row 변경 |
| CRIT-IDX4 | `unit/test-subagent-recovery.ps1` | 60s 타임아웃 + R1 크래시 복구 |
| CRIT-SCH1 | `unit/test-recall-at-3.ps1` | 10개 골든 쿼리 중 ≥8개 top-3 |
| CRIT-SCH2 | `unit/test-drilldown-switch.ps1` | 2000+ 에셋 map-reduce 활성 로그 |
| CRIT-SCH3 | `unit/test-malformed-query.ps1` | 빈/한글/이모티콘/따옴표 — no_query 응답 |
| CRIT-SCH4 | `unit/test-fallback-contract.ps1` | 인덱스 부재/stale → 경고 + 옵션 |
| CRIT-ORC1 | `unit/test-multi-intent-routing.ps1` | R2 복합 임계치 (종합 + multi + single) |
| CRIT-ORC2 | `unit/test-confidence-gate.ps1` | hi/med/lo 3건 분기 |
| CRIT-ORC3 | `unit/test-scope-guard.ps1` | audit 금지 튜플 0건 |
| CRIT-ORC4 | `unit/test-search-orch-contract.ps1` | search-result.json 스키마 + manifest_version |
| CRIT-CNV1 | `lint/lint-schema-doc-sync.ps1` | CONVENTION.md fenced JSON ↔ schemas/ |
| CRIT-CNV2 | `lint/lint-plugin-manifest.ps1` | plugin.json 공식 spec 준수 |
| CRIT-CNV3 | `unit/test-cross-skill-contract.ps1` | `:index` → `:search` → `:build` e2e |
| CRIT-CNV4 | `unit/test-yml-override.ps1` | non-default 설정 전파 |
| CRIT-DOC1 | `unit/test-doctor-diagnosis.ps1` | 4 fault-injection fixture + read-only |

## Stub 정책

`unit/` `e2e/` 테스트는 다음을 stub한다:
- `unity-mcp-orchestrator` 스킬 호출 → 미리 캐닝한 응답 (json fixture).
- MCP for Unity `mcp__*` 도구 → stub wrapper가 호출만 기록하고 응답은 정적 fixture에서 제공.
- asset-tagger subagent → 옵션. 일부 테스트(CRIT-IDX4 크래시 복구)는 실제 subagent를 띄워 행동 검증, 일부는 fake `assets.jsonl`을 직접 작성.

Stub 메커니즘은 환경 변수 + PowerShell wrapper로 구현 — 각 테스트 스크립트 머리에서 `Set-StubMode`를 호출한다.

## 디렉터리

```
tests/
├── README.md                          ← 이 파일
├── run-crit-suite.ps1                 ← 진입 PowerShell 러너 (-Only, _last-run.json)
├── fixtures/
│   ├── README.md                      ← fixture 용도 구분 (hand-curated vs 자동)
│   ├── _templates/assets.yml          ← 빌더 입력 (300+ 템플릿)
│   ├── _builder.ps1                   ← unity-50/200/1200 모두 생성
│   ├── _stubs.ps1                     ← unity-mcp stub 헬퍼
│   ├── unity-50/                      ← 빌더 산출 (테스트 setup이 생성)
│   ├── unity-200/                     ← 빌더 산출
│   └── unity-1200/                    ← 빌더 산출 (자동 생성, scale 전용)
├── golden-queries.yml                 ← CRIT-SCH1 10개 + CRIT-ORC1 10개
├── unit/                              ← 15개 unit + integration 테스트
├── lint/                              ← 2개 정적 lint
└── e2e/                               ← 1개 end-to-end
```

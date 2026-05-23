# tests/integration/ — 실제 Unity 프로젝트 통합 테스트

`tests/fixtures/`의 stub fixture(unity-50/200/1200)는 filesystem-only로 Unity Editor 없이 CRIT 18개를 검증한다. 그 위에 한 층 — **실제 Unity Editor + MCP for Unity가 살아있는 환경**에서 슬래시 커맨드 전체 흐름을 자동으로 검증하는 통합 테스트.

plan v6 ADR Follow-ups의 "Unity Editor가 가용해지면 실제 Asset Store 팩을 fixture 프로젝트로 임포트" 항목을 구현.

## 디렉터리 구조

```
tests/integration/
├── README.md                    ← 이 파일
├── run-integration.ps1          ← 통합 테스트 러너
└── testbed/                     ← .gitignored. 사용자가 직접 셋업
    ├── Assets/
    │   └── Packages/            ← Asset Store에서 임포트한 무료 패키지들
    ├── Packages/                ← UPM manifest (MCP for Unity 포함)
    ├── ProjectSettings/
    └── .claude/
        ├── unity-assets.yml     ← examples/unity-assets.yml 복사
        └── unity-asset-index/   ← /unity-assets:index가 생성
```

`testbed/` 자체는 git에 추적되지 않는다 (각 개발자 머신의 Unity 설치·라이브러리 상태가 달라서). 동일한 testbed를 재현하려면 본 README의 셋업 가이드를 따른다.

## 일회성 셋업 (각 개발자 머신마다 한 번)

### 1. Unity Hub로 빈 프로젝트 생성

- Unity Hub → New Project
- 템플릿: Universal 2D 또는 3D (둘 다 OK, 본 테스트는 에셋 메타데이터 중심이라 렌더링 파이프라인 무관)
- Project name: `testbed`
- Location: `D:\ClaudeCowork\unitySkills\tests\integration` (이 README의 부모 디렉터리)
- Add Sample Scene: 기본값 OK

### 2. MCP for Unity 임포트

`testbed/`를 Unity Editor로 연 상태에서:

- Window > Package Manager > + > Add package from git URL...
- URL: `https://github.com/CoplayDev/unity-mcp.git?path=/MCPForUnity#main`
- 임포트 완료 후 자동으로 뜨는 Skill Sync 창에서 "Sync now" 클릭

### 3. 무료 Asset Store 패키지 임포트 (recall 다양성 확보)

다음 키워드 중 2~3개 골라서 Unity Asset Store에서 무료 패키지 임포트:
- `medieval village` (CRIT-SCH1 q01 시나리오)
- `top down zombie` (CRIT-EE1 시나리오)
- `low poly nature` (CRIT-SCH1 q05 시나리오)
- `simple UI kit` (CRIT-SCH1 q06 시나리오)

각 패키지는 `Assets/Packages/<패키지명>/` 또는 유사한 vendor 폴더에 임포트된다.

### 4. 본 플러그인 설치 + 헬스체크

PowerShell 새 세션:

```powershell
# 플러그인 한 번만 설치 (이미 했으면 skip)
claude plugins install https://github.com/v0o0v/unity-asset-skills

# testbed/로 이동 후 claude 세션 시작
cd D:\ClaudeCowork\unitySkills\tests\integration\testbed
claude
```

claude 세션 안에서:

```
/unity-assets:doctor       ← 4/4 ✓ 확인. 하나라도 ✗면 권장 조치 따름.
```

### 5. 첫 인덱싱 + 검증

```
/unity-assets:index        ← 임포트한 에셋 수에 따라 30초~5분
/unity-assets:search "황폐한 중세 마을 분위기 건물"
```

검색 결과가 합리적으로 나오면 셋업 완료.

## 자동 통합 테스트 실행

```powershell
cd D:\ClaudeCowork\unitySkills\tests\integration
.\run-integration.ps1
```

러너가 수행:
1. `testbed/` 존재 + Unity 프로젝트 구조 검증
2. claude CLI로 `/unity-assets:doctor` 호출 → 4/4 ✓ 확인
3. `/unity-assets:index` 실행 → assets.jsonl 생성 + 크기 검증 (>= 50 rows 기대)
4. 골든 쿼리 3개 실행 → top-3 안에 합리적 후보 존재 확인 (느슨한 검증)
5. `/unity-assets:build` 호출 (read-only verification 시나리오) → orchestrator-audit.jsonl 생성 + 금지 튜플 0건 확인
6. `_last-run.json`에 결과 작성

`tests/fixtures/`의 CRIT 스위트는 dry-run / contract test (Unity 없이 통과 가능), 이쪽 integration은 진짜 환경에서의 sanity test (Unity 있어야 통과). 둘은 보완 관계.

## 비-목표

- 본 통합 테스트는 정확한 recall 수치 측정이 아닌 **흐름이 깨지지 않음** 검증.
- CI/CD에서 자동 실행 안 함 (Unity Editor + 라이선스 + Asset Store 패키지가 필요해서). 로컬 sanity check 용도.
- testbed/가 사용자마다 다르므로 결과 byte-identity는 보장 안 됨.

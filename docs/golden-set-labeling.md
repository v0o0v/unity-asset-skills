# 골든셋 라벨링 가이드 (Wave 2)

본 문서는 `tests/golden-queries.yml`의 `expected_golden_id` + `expected_relevant_ids` 다중 라벨링 방침을 설명한다. CRIT-EVAL1(정합성) · CRIT-EVAL2(Precision@3) 단언의 기반.

## 1. 두 라벨 필드의 차이

각 골든 쿼리는 두 개의 라벨 필드를 가진다.

| 필드 | 의미 | Recall@3 영향 | Precision@3 영향 |
|------|------|---------------|------------------|
| `expected_golden_id` (단일) | 사용자가 "원하던 바로 그 1개" — 가장 정확한 정답. | top-3에 포함되면 1점 hit (CRIT-SCH1). | top-3 ∩ relevant_ids 분자에 자동 포함. |
| `expected_relevant_ids` (배열, 1~5개) | "이 쿼리에 대한 응답으로 합리적인 모든 후보" — golden_id 포함. | (미사용) | top-3 ∩ relevant_ids 의 분자. |

CRIT-SCH1(Recall@3) 정의는 Wave 1 시점 그대로 유지된다 — 단일 정답이 top-3에 있는지의 hit/miss. Wave 2가 추가한 Precision@3은 다중 정답을 인정하여 보다 풍부한 의도(예: "메인 메뉴 UI"에 main_menu와 pause_menu 모두 정답으로 인정)를 반영한다.

## 2. 라벨링 원칙 — **보수적**으로

`expected_relevant_ids`는 적게 두는 편이 안전하다. 라벨을 부풀리면 Precision@3 분자가 과대 평가되어 메트릭이 의미를 잃는다 (R2 mitigation, plan §위험).

다음 기준을 따른다.

### 2.1 포함 기준 (relevant_ids에 추가 OK)

- 골든_id와 **동일 의도 클래스**의 다른 후보. 예: "좀비 적 캐릭터" 쿼리 → `zombie_basic_enemy` (golden) + `zombie_fast_runner` (다른 좀비 prefab도 합리적).
- 사용자가 "이것도 같이 보여 주면 좋겠다"고 말할 수 있는 후보 (보충재).

### 2.2 제외 기준 (relevant_ids에 추가 금지)

- 동일 type/카테고리지만 의도가 다른 것. 예: "메인 메뉴 UI" → `pause_menu_ui`는 의도가 다름(메인 vs 일시정지). 포함하지 않음.
- LLM이 골든 fixture의 tags나 name과 약하게 일치할 만한 모든 후보를 다 포함하면 Precision이 항상 1이 됨 → 의미 없음.

### 2.3 라벨 수의 가이드라인

- **단일 라벨 (1개)**: 쿼리가 매우 구체적이고 정답이 유일. 예: "wave config 설정 ScriptableObject" → `wave_config_so` 단독.
- **2개 라벨**: 가장 흔한 케이스. 골든 + 1개 합리적 대안.
- **3개 라벨**: 명백한 보충재가 2개 이상 존재. 예: "좀비 적 캐릭터" 같은 광의 쿼리.
- **4~5개 라벨**: 거의 사용하지 않음. 4개를 넘긴 라벨링은 한 번 더 검토 권장.

## 3. CRIT-EVAL2 임계치의 의미

Precision@3 ≥ 0.50 / 카테고리당 ≥ 0.40 임계치는 다음 의미를 가진다.

- **0.50 의미**: top-3 중 1.5개가 relevant_ids에 평균적으로 포함. 라벨링이 보수적이면 이 임계는 fake-search-runner의 keyword-overlap heuristic 한계 근처를 측정한다.
- **0.40 (카테고리)**: 카테고리당 6 쿼리 × 평균 0.40 = 카테고리당 약 7.2 hits / 18 top-3 슬롯. 1개 카테고리가 보호된 최저선.
- 임계치가 너무 낮으면 (예: 0.30) 모든 라벨링이 패스 — 의미 없음.
- 임계치가 너무 높으면 (예: 0.70) fake-search 한계로 통과 불가 — fixture 라벨링을 부풀려야 하는 압력 발생, R2 위험.
- 0.50 / 0.40은 fixture와 fake-search-runner의 현재 능력을 균형 있게 측정하는 값으로 채택됨 (실제 LLM 라우팅으로 측정하는 Wave 3에서는 임계 재조정 예정).

## 4. 라벨링 검증

라벨이 정합성 조건을 위반하면 `tests/unit/test-golden-set-integrity.ps1`(CRIT-EVAL1)이 즉시 실패한다.

- 모든 쿼리에 비어있지 않은 `expected_relevant_ids` 필수.
- `expected_golden_id`는 반드시 `expected_relevant_ids` 안에 포함.
- 모든 ID는 `tests/fixtures/_templates/assets.yml`의 골든 entry에 실재해야 함.
- 카테고리당 ≥ 6 쿼리 보장.

## 5. Wave 3 후속

본 가이드는 Wave 2 시점의 fake-search 결정성 가정 위에 작성됨. Wave 3에서 실제 LLM 라우팅으로 측정 전환 시:

- 임계치 재조정 (실LLM은 fake보다 도메인 이해도가 높을 가능성).
- `expected_relevant_ids`의 다중 라벨 폭을 약간 넓힐 여지.
- `feedback.jsonl`에서 수집된 실제 사용자 pick 데이터를 보조 신호로 활용 (CRIT-EVAL3 누적).

## 6. 새 쿼리 추가 절차

새 쿼리 q32 이상을 추가하려면 다음 순서를 따른다.

1. `tests/golden-queries.yml::sch1_recall`에 새 entry 추가. `id`, `query`, `expected_golden_id`, `expected_relevant_ids`, `category` 모두 필수.
2. `tests/fixtures/_templates/assets.yml`에 모든 `expected_relevant_ids`가 실재 fixture entry로 존재하는지 확인. 없다면 fixture 추가.
3. `pwsh tests/unit/test-golden-set-integrity.ps1` 실행 → PASS 확인.
4. `pwsh tests/unit/test-precision-at-3.ps1` 실행 → 임계 통과 확인. 떨어지면 라벨링 또는 fixture tags 재검토.
5. `pwsh tests/run-crit-suite.ps1 -Only SCH1,EVAL` → 회귀 없음 확인.

쿼리 추가는 부수적으로 Recall@3 분모를 키운다. CRIT-SCH1 임계는 "≥ 8" 같은 절대 수치이므로 분모가 커져도 영향 없지만, by_category 균형(카테고리당 ≥ 6)은 새 쿼리 추가 시에도 유지되어야 한다.

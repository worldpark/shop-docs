# 007. shop-core k6 order-create 다중 variant 분산 — 측정 현실화 + 단일 vs 분산 재측정

> 출처: `docs/backlog/performance/001-shop-core-order-create-throughput-improvements.md` §0순위(측정 현실화 — 무위험·최대 효과). 현재 ~100~200rps 한계가 **단일 variant 자기경합이라는 측정 방식의 산물**임을 분산 측정으로 분리한다.
> 참고 측정 방법론: `docs/report/performance/001-virtual-thread-ab-measurement.md`(A/B 측정 프레이밍·CPU 공유 주의·다회 비중첩 확정·서버측 메트릭).
> 관련: order-create 하니스(Task 001~003), `shop-core/perf/k6/{lib,scenarios,profiles,baselines}`.

## 계승하는 결정 (재논의 금지)
- **도구/타겟/게이트/환경/출력**: 로드맵 §2 + Task 001~003 그대로(k6 / 외부 앱 타겟 `BASE_URL` / 머지 게이트 제외·온디맨드 / docker-compose 실 스택 / summary+JSON, `SUMMARY_EXPORT_PATH`로 토큰 제외 export).
- **하니스 재사용·블랙박스 한정**: `lib`(config·auth·seed) + `scenarios/order-create.js` + `profiles/{load,stress}.js`를 재사용한다. 본 Task는 **시드의 variant 개수와 시나리오의 variant 선택만** 바꾸고 흐름·앱 코드·빌드는 건드리지 않는다.
- **앱/빌드 코드 무변경**: Java·Thymeleaf·Gradle 미수정. **k6 자산(JS)만** 변경 + 재측정. (락 창 단축·풀 상향·아키텍처는 backlog 1·3·4순위 별도 Task.)

## 배경 (코드 확인)
- `lib/seed.js`의 `setupSeed()`는 `createVariant`를 **1회만** 호출 → **단일 `variantId`** 반환. `scenarios/order-create.js`는 `default()`에서 **모든 VU가 `data.variantId` 하나**를 cart add → order(`order-create.js:141`).
- 그 결과 모든 주문이 같은 `VariantStock` 행의 `PESSIMISTIC_WRITE`(`SELECT ... FOR UPDATE`)에 직렬화된다. `lib/config.js` 주석: *"단일 variant PESSIMISTIC_WRITE 직렬화"*, 앱 처리 상한 ≈ 90~100 orders/s. 200rps에서 dropped/지연 급증은 이 **자기유발 경합**이 원인(backlog §배경·§측정함정).
- 즉 현재 베이스라인은 **"모두가 같은 SKU 하나를 동시에 사는"** 최악 경합이다. 현실 트래픽은 주문이 여러 SKU로 분산돼 행 락이 한 행에 몰리지 않으므로, 운영 처리량은 이보다 높을 개연이 크다 — 이를 **데이터로 분리**하는 것이 본 Task.

## Target
- `lib/seed.js`: `setupSeed()`가 **N개 variant**를 시드하고 식별자 목록을 반환(`variantIds[]`). (catalog-read의 다상품 시드 `setupCatalogSeed` 패턴 차용 — 단일 상품에 variant N개 또는 상품 N개×variant 1개 중 plan에서 확정.)
- `lib/config.js`: `SEED.ORDER_VARIANT_COUNT`(기본 1 — **하위호환**, 분산 측정 시 env로 상향) + 분산 선택 파라미터.
- `scenarios/order-create.js`: cart add의 variant를 **반복(iteration) 단위로 분산 선택**(`__VU`/`__ITER` 기반 결정적 분배 — random 불요).
- `baselines/`: 단일 vs 분산 비교 산출물.

## Goal
order-create 부하를 **다중 variant로 분산**해 재측정하고, **단일 variant(현 베이스라인) vs 분산**을 동일 머신·동일 프로파일에서 A/B로 비교한다. 이로써:
1. 현재 ~100~200rps 천장이 **행 락 자기경합 산물**임을 입증(분산 시 천장 상향 여부).
2. 분산 시 **진짜 병목**(DB 행 락이 아니라 커넥션 풀/CPU)이 어디인지 서버측 메트릭으로 식별.
3. backlog 1순위(락 창 단축) 착수가 **실제로 필요한지** 판단할 근거 확보(이 Task가 게이팅 결정).

## 범위 (Scope)
### 1. 시드 — 다중 variant (`lib/seed.js` + `lib/config.js`)
- `SEED.ORDER_VARIANT_COUNT`(기본 1) 추가 + `__ENV.ORDER_VARIANT_COUNT` 오버라이드. 분산 측정 시작 후보값은 plan에서(예 50 — catalog 시드 선례).
- `setupSeed(buyerCount)`가 variant를 N개 생성하고 `{ variantIds: number[], buyers }` 반환. **하위호환**: 단일 `variantId`(`= variantIds[0]`)도 유지하거나, 시나리오를 `variantIds`로 일괄 전환(plan에서 택1 — 기존 단일 베이스라인 재현 경로를 깨지 않을 것).
- variant당 재고(`SEED.VARIANT_STOCK=1,000,000`)는 분산이라 행당 부하가 줄어 충분(점검만).
- 시드 단계 실패는 기존대로 즉시 throw(조용한 0 RPS 방지).

### 2. 시나리오 — variant 분산 선택 (`scenarios/order-create.js`)
- cart add(`order-create.js:141`)의 `variantId`를 **결정적 분배**로 선택: 예 `data.variantIds[(__VU - 1 + __ITER) % data.variantIds.length]`(VU·iteration이 variant들에 고르게 퍼지도록). **random 미사용**(재현성).
- 흐름(cart add → order)·메트릭(order_created/conflict/5xx)·handleSummary(토큰 제외)는 **무변경**.
- `ORDER_VARIANT_COUNT=1`이면 기존 단일 variant 동작과 동일(분배가 단일 원소로 수렴) → **기존 베이스라인 재현 보장**.

### 3. 재측정 + 단일 vs 분산 비교 (산출물)
- 동일 프로파일(우선 `load`, 필요 시 `stress`로 분산 천장 탐색)에서 **단일(N=1) vs 분산(N=50 등)** 각각 측정.
- **측정 방법론(report 001 준수)**:
  - 깨끗한 DB(측정 전 테스트 주문/장바구니 TRUNCATE — 누적 열화 배제, [[k6-perf-baseline-needs-clean-db]]).
  - **notification log 모드**(부하가 환영메일 등 실 SMTP를 난타하지 않게, [[perf-test-notification-must-be-log-mode]]) + mail health off.
  - **다회(3런+) 측정으로 분포 비중첩 확인**(단일 런 p95/p99는 ±10~30% 변동 — report 001 §7).
  - **CPU 공유 주의**: k6·앱·PG 동거면 절대수치 비대표적이나, **단일 vs 분산은 동일 머신·동일 조건이라 상대 비교 유효**(report 001 ★).
  - **서버측 메트릭(ADR-010)**으로 분산 시 진짜 병목 식별: `hikaricp_connections`(풀 포화?), `jvm_threads`(스레드 포화?), CPU. 분산으로 행 락이 풀리면 천장이 풀/CPU로 이동하는지 확인.
- 산출물: `baselines/order-create-load-multivariant.json`(+필요 시 stress) + 단일 vs 분산 비교표(throughput·p95·p99·dropped·order_5xx·서버측 병목 지표)를 **결과 리포트**로 정리(`docs/report/performance/` 또는 backlog 갱신 — plan에서 위치 확정).

## Non-goals (별도 Task)
- **락 창 단축**(Hibernate JDBC 배칭, 락-후 재조회 쿼리 정리) — backlog 1순위, **앱 코드 변경**이라 별개 Task. 본 Task 측정이 "필요"라고 가리킬 때 착수.
- **커넥션 풀 상향**(backlog 3순위) — 분산 측정이 풀 병목을 가리킬 때 별개 Task.
- 조건부 UPDATE 전환(2순위)·아키텍처 변경(4순위·Redis/샤딩) — 비범위.
- 가상스레드 — report 001에서 "throughput 지렛대 아님" 확정. 본 Task와 무관(재론 금지).
- nightly 자동 비교·TSDB·전용 perf 환경 — 보류(로드맵 §15).

## 예외/오류 처리 전략
- **분배 비균등**: `__VU`/`__ITER` 분배가 특정 variant에 쏠리지 않는지(예 maxVUs와 N의 공약수) plan에서 점검 — 쏠리면 분산 효과가 희석돼 측정 오염.
- **시드 시간 증가**: N개 variant 생성으로 setup이 길어질 수 있음(catalog 50개 선례 내). 과도하면 N 조정.
- **재고/주문번호**: 분산이라 행당 부하↓로 재고 고갈·번호 충돌 위험 감소(기존 가드 유지).

## 검증 방법
- **하위호환**: `ORDER_VARIANT_COUNT=1`(기본)로 `load` 실행이 기존 `order-create-load.json` 베이스라인과 정합(단일 variant 동작 불변).
- **분산 실행 통과**: `ORDER_VARIANT_COUNT=50`(예) `load`/`stress`가 비정상 종료 없이 완료, `order_5xx`==0(락 붕괴 없음), summary의 variant 분배가 고름.
- **A/B 결론 산출**: 단일 vs 분산 비교표에서 분산 throughput이 단일을 유의하게 상회(또는 동등)하는지 **3런 분포로** 판정. 천장이 행 락→풀/CPU로 이동했는지 서버측 메트릭으로 뒷받침.
- **JSON 아티팩트**: `baselines/order-create-load-multivariant.json` 보관(`build/`는 gitignore → baselines 복사, Task 001 선례).
- **재현 절차**: README에 분산 측정(시드 N·env·비교) 절차 추가.
- Java 빌드 무관 — `./gradlew test` 게이트 대상 아님(k6 자산만).

## 트레이드오프
- **분배 방식(결정적 vs random)**: 결정적(`__VU`/`__ITER`) 채택 — 재현성·균등성 확보, random 회피(변동·디버깅 난이도).
- **상품 N개 vs 단일 상품 variant N개**: plan에서 확정. 단일 상품+variant N개가 시드 단순(상품 1회 게시), 다만 같은 product row 갱신 경합이 없는지 확인. 상품 N개는 catalog 시드 재사용 용이.
- **절대수치 비대표성**: 개발 머신 단일 환경이라 절대 throughput은 SLA 아님. **단일 vs 분산 상대 비교**가 본 Task의 결론(report 001 동일 프레이밍).

## 참고
- backlog 분석: `docs/backlog/performance/001-shop-core-order-create-throughput-improvements.md`(§0순위, §측정함정, §핫패스).
- 측정 방법론: `docs/report/performance/001-virtual-thread-ab-measurement.md`(§2 방법, ★CPU 공유 주의, §7 운영 메모 — 다회·gradle 데몬·서버측 메트릭).
- 하니스: `shop-core/perf/k6/lib/{config.js,seed.js}`(시드·상수), `scenarios/order-create.js`(`:141` cart variant), `profiles/{load,stress}.js`, `baselines/order-create-{load,stress}.json`.
- 핫패스(측정 대상, 무수정): `shop-core/.../order/service/OrderService.java`(createOrderTx), `inventory/service/InventoryStockPortImpl.java`(decrease).
- 시드 패턴 차용: `lib/seed.js` `setupCatalogSeed`(다상품 시드 — catalog-read).
- 구현 담당: `k6-implementor`(메인 오케스트레이션은 메인 에이전트).

## 후속 (본 Task 결과가 게이팅)
- 분산에서도 천장이 낮고 락 창이 원인이면 → backlog 1순위(Hibernate 배칭 + 락-후 쿼리 정리) Task 착수.
- 천장이 풀/CPU면 → backlog 3순위(풀 상향) + 전용 perf 환경 재측정.
- 단일 SKU 초고동시가 실제 요구로 확인되면 → backlog 4순위(아키텍처) 검토.

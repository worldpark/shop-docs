# Plan 007. order-create 다중 variant 분산 — 측정 현실화

> 대상 Task: `docs/tasks/performance/007-performance-shop-core-k6-order-create-multi-variant-distribution.md`
> 범위: k6 자산(JS)만 — `lib/config.js`·`lib/seed.js`·`scenarios/order-create.js`·README. 앱/빌드 무변경. 시드 variant 개수 + 시나리오 variant 분배만 추가. 측정 실행은 별도 온디맨드 스텝.
> 순서: k6-implementor(코드 + README) → reviewer → (온디맨드) 단일 vs 분산 측정·비교 리포트(라이브 스택 필요 — 코드 게이트 밖).

## 0. 확정 사실 (코드 검증됨)
- `lib/seed.js` `setupSeed(buyerCount)`: admin→seller 승격→상품 1개 DRAFT 등록→ON_SALE 게시→**`createVariant` 1회**→buyer N명. 반환 `{ variantId, buyers }`. variant는 `optionValueIds:[]`(옵션 없음).
- `lib/seed.js` `setupCatalogSeed(count)`: 상품 N개 각각 등록→게시→variant 1개 생성 루프. 반환 `{ productIds, sellerToken }`. **상품 N개×variant 1개 패턴이 이미 검증됨**(차용 대상).
- `lib/seed.js` `setupCouponSeed`: 내부에서 `setupSeed` 호출 후 `seed.variantId` 사용 → **`variantId` 반환 필드 유지 필수**(호환).
- **`setupSeed` 소비자 전수(3곳, 모두 `data.variantId` 단수만 사용 → `variantId` 보존 시 N 무관 불변)**: `scenarios/order-create.js:141`(본 Task가 분배로 교체), `scenarios/payment-confirm.js:167`(setupSeed 직접 호출·variantId 단수), `scenarios/coupon-apply.js:175`(setupCouponSeed 경유·variantId 단수). → order-create만 `variantIds` 분배를 쓰고, 나머지 둘은 `variantId(=[0])`로 기존과 동일.
- `scenarios/order-create.js`: `setup()`이 `setupSeed(p.maxVUs||p.vus)` 호출, `default()`이 `data.variantId` 하나로 cart add(`:141`)→order. buyer는 `(__VU-1)%buyers.length` 매핑.
- `lib/config.js` `SEED`: 상수 묶음(VARIANT_STOCK=1,000,000, PRODUCT_NAME_PREFIX, SKU_PREFIX 등). `CATALOG_PRODUCT_COUNT=50` 선례 존재.
- 측정 대상 핫패스(무수정): `OrderService.createOrderTx`가 variant 행에 `PESSIMISTIC_WRITE` → 단일 variant면 전 주문 직렬화(= 현 천장 원인).

## 1. 시드 방식 결정 (트레이드오프 확정)
- **상품 N개 × variant 1개**(catalog 패턴)로 확정. 이유: `setupSeed`의 variant는 `optionValueIds:[]`(옵션 없음)이라, **단일 상품에 옵션 없는 variant를 N개** 만들면 "옵션 조합 없음" 중복으로 제약 위반 위험. 상품마다 variant 1개는 기존 `setupSeed`/`setupCatalogSeed`가 이미 안전하게 하는 방식 → 위험 0.
- order-create의 락은 **variant 행** 단위라, variant들이 서로 다른 상품에 속해도 분산 효과는 동일(행이 다르면 경합 없음).

## 2. `lib/config.js`
- `SEED.ORDER_VARIANT_COUNT` 추가. 값 결정: `__ENV.ORDER_VARIANT_COUNT ? Number(...) : 1`(기본 1 — **하위호환**). 분산 측정 시작 후보 50(catalog 선례, 측정 시 env로 지정).
- 주석으로 "1=단일 variant(기존 베이스라인 재현), >1=분산" 명시.

## 3. `lib/seed.js` — `setupSeed` 다중 variant
- `setupSeed(buyerCount)`를 variant 개수 N(`SEED.ORDER_VARIANT_COUNT`)만큼 **상품+variant**를 생성하도록 확장:
  - 기존 1~4단계(admin/seller 승격/재로그인)는 그대로.
  - 5~7단계(상품 등록→게시→variant)를 **N회 루프**(`setupCatalogSeed`의 루프 로직 차용, prefix에 `-i` 부여해 네임스페이스 분리). 각 회차 variantId 수집 → `variantIds: number[]`.
  - buyer 8단계 그대로.
- 반환: `{ variantId: variantIds[0], variantIds, buyers }`.
  - **`variantId` 유지**(= `variantIds[0]`) → `setupCouponSeed` 등 기존 소비자 무파손(호환 불변식).
  - `variantIds` 신규 추가 → order-create 시나리오가 분배에 사용.
- N=1이면 루프 1회 → 기존과 동일(상품 1·variant 1). **기존 단일 베이스라인 재현 보장**.
- 시드 실패는 기존대로 즉시 throw. 시드 시간 증가는 N=50에서 catalog(50개) 선례 내 — 과도하면 N 하향.

## 4. `scenarios/order-create.js` — variant 분배
- `default(data)`에서 cart add variant를 **결정적 분배**로 선택:
  - `const variantId = data.variantIds[(__VU - 1 + __ITER) % data.variantIds.length];`
  - cart add body의 `data.variantId` → 위 `variantId`로 교체(`:141`).
- 흐름·메트릭(order_created/conflict/5xx)·handleSummary(토큰 제외)·buyer 매핑은 **무변경**.
- 방어: `data.variantIds`가 없을 경우(이론상 없음 — setup이 항상 반환) `[data.variantId]`로 폴백할지 plan 검토 → setup이 항상 variantIds를 반환하므로 **폴백 불필요**(단순 유지). N=1이면 분배가 `variantIds[0]`로 수렴 → 기존 동작.
- **분배 균등성**: `(__VU-1+__ITER)`는 VU·iteration 진행에 따라 variant 공간을 훑어 고르게 분산. maxVUs와 N의 공약수로 인한 쏠림은 `+__ITER` 항이 완화. README에 "균등 분배" 근거 1줄.

## 5. 측정 (온디맨드 — 코드 게이트 밖, 라이브 스택 필요)
> k6-implementor는 코드+README까지. 실제 측정은 docker-compose 실 스택 + 앱 기동 상태에서 메인/수동 실행(라이브 앱 없이는 불가).
- **절차(README에 기재)**:
  1. 깨끗한 DB(테스트 주문/장바구니 TRUNCATE — [[k6-perf-baseline-needs-clean-db]]).
  2. **notification log 모드**(`NOTIFICATION_MAIL_MODE=log`) + mail health off — 실 SMTP 난타 방지([[perf-test-notification-must-be-log-mode]]).
  3. 단일: `ORDER_VARIANT_COUNT=1 -e PROFILE=load` ×3런. 분산: `ORDER_VARIANT_COUNT=50 -e PROFILE=load` ×3런(필요 시 stress로 분산 천장 탐색).
     - **README 주의 1줄**: `ORDER_VARIANT_COUNT`는 **order-create 측정 전용**이다. payment-confirm/coupon-apply도 같은 env로 setupSeed를 타므로(variant N개 시드하지만 variant[0]만 사용 → 결과 동일·setup만 느려짐), 그 시나리오 실행 시엔 env를 지정하지 말 것(기본 1).
  4. 각 런 `SUMMARY_EXPORT_PATH`로 JSON(토큰 제외) export.
  5. 서버측 메트릭(ADR-010) 수집: `hikaricp_connections`(풀 포화), `jvm_threads`(스레드), CPU — 분산 시 천장이 행 락→풀/CPU로 이동하는지.
- **CPU 공유 주의**: 절대수치 비대표적, **단일 vs 분산 상대 비교만** 결론(report 001 ★).
- 산출물: `baselines/order-create-load-multivariant.json` + 비교표(throughput/p95/p99/dropped/order_5xx/서버측 병목). 결과 리포트 위치: `docs/report/performance/002-...`(신규) — 측정 완료 후 작성.

## 6. 순서 / 검증 게이트
1. k6-implementor: config(ORDER_VARIANT_COUNT) → seed(다중 variant + variantIds, variantId 호환 유지) → scenario(분배) → README(분산 측정 절차) 작성.
2. reviewer: 호환 불변식(variantId 유지·N=1 재현)·분배 균등·random 미사용·흐름/메트릭 무변경·앱 코드 무변경 확인.
3. **정적 검증(라이브 불가 시)**: k6 스크립트 문법(`k6 inspect` 또는 `--paused` 드라이 실행이 가능하면), N=1 분배가 단일로 수렴하는 로직 확인. **Java `./gradlew test` 게이트 대상 아님**(k6 자산만).
4. (온디맨드) 라이브 스택에서 단일 vs 분산 측정·비교 리포트 — 코드 머지 후 별도 스텝.

## 7. 리뷰 관점
- **호환 불변식**: `setupSeed` 반환에 `variantId`(=variantIds[0]) 유지 → `setupCouponSeed`·기존 소비자 무파손. N=1이면 상품1·variant1로 기존 베이스라인 재현.
- **분배 정확성**: `(__VU-1+__ITER)%len` 결정적·균등, random 미사용(재현성). N=1 수렴.
- **블랙박스·무변경**: 앱/Java/빌드 미수정, 흐름·메트릭·handleSummary 불변. k6 자산 한정.
- **측정 위생**: README가 깨끗한 DB·notification log 모드·다회·상대비교·서버측 메트릭을 명시(측정 오염/실 SMTP 사고 방지).
- **시드 안전**: 상품 N개×variant 1개(옵션 없음 중복 위험 회피), 시드 실패 즉시 throw.

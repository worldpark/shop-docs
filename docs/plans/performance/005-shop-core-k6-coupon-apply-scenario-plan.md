# Plan 005. shop-core k6 coupon-apply 시나리오 (쿠폰 사용 동시성)

> 대상 Task: `docs/tasks/performance/005-performance-shop-core-k6-coupon-apply-scenario.md`
> 선행: Task 001 하니스(완료). 002~004와 독립.
> 구현 담당: `k6-implementor` (메인: 오케스트레이션·파괴적 DB 정리·notification 안전 게이트·라이브 측정)

## 0. 운영 안전 게이트 (구현·측정 전 필수)
- **notification 정지(또는 log).** 시드 signup→환영메일, PENDING 주문 만료 자동취소→취소메일 발생. 메인이 측정 직전 notification 정지(no active members) 확인 후에만 라이브 실행. **k6-implementor는 라이브 실행 금지(static `k6 archive`만)** — 측정은 메인이 안전 게이트 보장 후 수행(004 선례).
- **깨끗한 DB**(측정 전 TRUNCATE, 메인).

## 1. 목표
쿠폰 사용 동시성(중복 사용 방지) 경로를 가압해 **경합이 조건부 UPDATE로 정상 직렬화되는가(붕괴 아님)**를 블랙박스로 확인하고 thresholds를 확정한다: `coupon_5xx==0`, **정확히 1회 사용(no double-spend)**, 충돌은 409로만.

## 2. 가압 대상 REST 계약 (코드 실사 확정)
| 단계 | 메서드·경로 | 요청 | 추출 | status | 권한 |
|---|---|---|---|---|---|
| 쿠폰 생성(시드) | `POST /api/v1/admin/coupons` | `{code, name, discountType:"fixed", value:"1000", minOrderAmount:"0", startsAt, endsAt, usageLimit:null, isActive:true}` | `code`(또는 id) | 201 | ADMIN |
| 쿠폰 발급(시드) | `POST /api/v1/coupons` | `{code}` | **`userCouponId`** | 201 | CONSUMER |
| 쿠폰 적용 주문 | `POST /api/v1/orders` | `{recipient,phone,postcode,address1, userCouponId}` | `orderId`, `discountAmount`(>0) | 201 | CONSUMER(소유) |

- **동시성 메커니즘**: 주문 tx에서 `computeDiscount`(이미 사용 시 409) + `markUsedIfUnused`(usedAt IS NULL일 때만 1행) 조건부 UPDATE. 영향행 0 → **409 `CouponConflictException`**. (한도형은 `incrementUsedCountIfWithinLimit`.)
- **1인1매**: UNIQUE(user_id, coupon_id) — 재발급 409. 사용 시각/유효기간: startsAt 과거~endsAt 미래로 시드(예 2000-01-01~2099-12-31).

## 3. 시나리오 설계 (확정: 단일사용 직렬화 경합)
**소비성 전제**: userCoupon은 1회 사용하면 끝(이후 409). 지속 "성공 부하"는 비현실적이므로, 본 Task는 **중복 사용 방지 경로를 반복 가압**해 "충돌이 깨끗한 409로 직렬화되고 5xx·이중사용이 없는가"를 본다.
- **setup**: admin이 무제한 쿠폰 1개 생성 → 각 buyer가 그 쿠폰을 1회 발급(`userCouponId` 보유). `setupSeed`에 쿠폰 생성+발급 보강(buyer 객체에 `userCouponId` 추가). 기존 seller/상품/variant/buyer 흐름 유지.
- **VU 흐름**: buyer = `data.buyers[(__VU-1)%N]`; `getValidToken` → cart add(200) → `POST /orders {userCouponId}`.
  - 첫 사용(미사용 쿠폰) → **201 + discountAmount>0** → `coupon_applied++`.
  - 이후(이미 사용) → **409** → `coupon_conflict++`(정상 — 중복 사용 차단됨).
- **가압 의미**: 같은 userCoupon에 반복 주문이 들어가 `markUsedIfUnused` 경합/멱등 경로를 부하로 때린다. **정확히 1회만 성공(coupon_applied 총합 == buyerCount)** 이면 이중 차감 없음(블랙박스 정합 신호). 5xx 0이면 락/제약 붕괴 없음.

## 4. 변경 대상 파일
- `shop-core/perf/k6/scenarios/coupon-apply.js` — **신규**. lib·buildOptions·handleSummary 재사용.
- `shop-core/perf/k6/lib/seed.js` — setup에 쿠폰 생성+buyer 발급 보강(buyer에 `userCouponId`). **order-create·payment-confirm 시드 흐름 무영향**(추가만).
- `shop-core/perf/k6/lib/config.js` — `COUPON_THRESHOLDS` + SEED에 쿠폰 상수.
- `shop-core/perf/k6/README.md` — coupon-apply 실행·안전 게이트·소비성/충돌 해석.
- 산출: `baselines/coupon-apply-load.json`.

## 5. 충돌(409) 처리 — http_req_failed 오탐 방지 (핵심)
k6 기본 `http_req_failed`는 4xx를 실패로 센다. 쿠폰 충돌(409)은 **정상 비즈니스 흐름**이므로 임계에서 빼야 한다.
- **`http.setResponseCallback(http.expectedStatuses(200, 201, 409))`** 를 시나리오 init에 설정 → 409가 http_req_failed에 안 잡힘(진짜 오류 5xx/타임아웃만).
- 충돌은 별도 `Counter coupon_conflict`로 가시화.

## 6. 계측 / thresholds
- 커스텀: `Counter coupon_applied`(201 & discountAmount>0), `Counter coupon_conflict`(409), `Counter coupon_5xx`(>=500), `Trend coupon_order_duration`(쿠폰적용 주문 POST 지연).
- **COUPON_THRESHOLDS(형태, 실측 후 확정)**: `http_req_failed: rate<0.01`(409 제외됨), `coupon_5xx: count==0`(직렬화 붕괴=비정상), `coupon_order_duration` p95/p99(측정 후). `coupon_conflict` 임계 없음(가시화).
- **포화점 측정 금지**(002 교훈): load 60rps로 구동. cart→order 종단이라 order-create 변수 락(~90~100/s) 상한 공유 — 60rps는 안전.

## 7. 측정 절차 (메인)
1. notification 정지 확인 + 깨끗한 DB(TRUNCATE).
2. `-e PROFILE=load`(60rps) 실행 → **coupon_5xx(==0)·coupon_applied(==buyerCount? 이중사용 0)·coupon_conflict·coupon_order_duration p95/p99·http_req_failed(409 제외 후 ~0)** 기록.
3. 관측 p95/p99로 COUPON_THRESHOLDS 확정(×2.5~3, 선례 일관). `baselines/coupon-apply-load.json`(handleSummary, 토큰 제외, p99 포함).
4. order-create/payment-confirm/프로파일 회귀 0(시나리오·시드 추가가 기존 무영향) — seed 보강이 기존 시나리오 setup에 영향 없는지 확인(쿠폰 생성/발급은 coupon-apply에서만 호출되도록 분리, 또는 setupSeed 옵션 인자).

## 8. 검증
- 실행 완료(비정상 종료 없음) + 확정 thresholds 만족. `coupon_5xx==0`, 충돌 409로만.
- **이중사용 0 신호**: coupon_applied 총합이 buyerCount를 넘지 않음(각 쿠폰 정확히 1회) — 블랙박스 no-double-spend.
- baseline 토큰 제외·p99 포함, 깨끗한 DB. notification 정지·Kafka up.
- order-create.js·payment-confirm.js·앱·빌드 무변경(coupon-apply.js 신규 + seed/config 보강 + README).

## 9. Non-goals
- 한도형(B) 경계 경합 단독 시나리오 — 본 Task는 단일사용(A) 직렬화 중심(한도형은 후속 옵션, plan에 메커니즘만 기록).
- 지속 성공-경로 throughput(쿠폰 풀 대량 시드) — 소비성 한계로 후속 옵션.
- 정밀 정합(중복 사용 0 DB 단언) — Testcontainers `CouponConcurrencyIntegrationTest` 책임(블랙박스 한정).
- stress 프로파일·앱/빌드 변경.

## 10. 리뷰 관점
- 쿠폰 생성/발급 계약 정확(빈/필수 필드, 201, userCouponId 추출), 유효기간 시드가 now 포함.
- `http.expectedStatuses(200,201,409)`로 409가 http_req_failed에서 제외되는가(오탐 방지).
- coupon_5xx==0 유지, coupon_conflict 임계 없음, 실측 thresholds(포화점 회피).
- 단일사용 경합이 의도대로(coupon_applied==buyerCount, 나머지 409) 나오고 5xx 0인가.
- seed 보강이 기존 시나리오(order-create/payment-confirm) setup에 무영향인가. baseline 토큰 제외.

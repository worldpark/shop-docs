# 005. shop-core k6 부하 테스트 3차-c — coupon-apply 시나리오 (쿠폰 사용 동시성)

> 출처: 로드맵 `docs/tasks/performance/performance-shop-core-k6-load-test-roadmap.md` §6 3순위·§15, Task 002 "후속 Task" 3차. 새 핫패스(쿠폰 적용)를 가압하는 **새 시나리오**를 추가하는 단일 기능 Task다("한 Task = 한 기능").
>
> **선행: Task 001(하니스, 완료).** load(002)·stress(003)·payment(004)와 **독립** — 쿠폰 시나리오는 1차 하니스(lib·order-create 흐름)만 있으면 작성·구현 가능하다(부하 프로파일은 smoke/load로 구동).

## 계승하는 결정 (재논의 금지)
- 도구/타겟 A/게이트 제외/실 스택/summary+JSON — 로드맵 §2.
- **하니스 재사용**: `lib`(config·auth·seed) 공유 + order-create 흐름 재사용(쿠폰을 적용한 주문 생성). 중복 제거 우선.
- **블랙박스 한정**: "쿠폰 사용 동시성이 부하에서 SLO를 지키고 중복 사용을 막나"의 응답 수준 pass/fail까지. 정밀 정합(중복 사용 0)은 Testcontainers 책임.

## 배경
- 쿠폰 적용/주문 할인은 **쿠폰 사용 한도·단일 사용(userCoupon) 직렬화**가 걸리는 경로다(로드맵 §6 3순위). 부하 하에서 **중복 사용 방지 경로의 경합(락/조건부 update)**이 본 시나리오의 관측 대상이다.
- 주문 생성 요청이 `userCouponId`(선택)를 받는다(Task 001 계약 실사). 따라서 쿠폰 적용은 **order-create에 쿠폰을 실어** 일어난다.
- **동시성 메커니즘(실사)**: 비관적 락이 아니라 **조건부 UPDATE**다 — 단일 사용은 `markUsedIfUnused`(`usedAt IS NULL`일 때만 1행), 한도는 `incrementUsedCountIfWithinLimit`(`used_count < usage_limit`일 때만 1행). 영향행 0 → 패자 → **409 `CouponConflictException`**. 이게 "중복 사용 방지 직렬화"의 실체다.
- **쿠폰은 소비성(중요)**: userCoupon은 한 번 사용하면 `usedAt`이 박혀 재사용 불가(이후 409). 1인1매(UNIQUE(user_id,coupon_id))라 한 buyer는 한 쿠폰을 1회만 발급. 따라서 **지속 부하로 "성공 경로"를 반복 가압하기 어렵다** → 본 Task는 *경합/충돌 직렬화의 블랙박스 정상성*(409 깨끗·5xx 0·정확히 1회 사용)에 초점을 둔다(아래 Scope·plan).

## 운영 안전 전제 (필수 — 2026-06-16 세션 사고 교훈)
- **notification은 `log` 모드이거나 정지여야 한다(실 SMTP 금지).** 시드 signup → 환영 메일, PENDING 주문 만료 자동취소 → 취소 메일이 발생한다(002/003에서 order-cancelled 6,705건 누적 사례). smtp + 실 Gmail이면 대량발송 차단 사고 재현. `NOTIFICATION_MAIL_MODE=log`(현재 기본 log) + actuator mail health off 확인. (메모리 "perf 테스트 시 notification은 log 모드")
- **베이스라인은 깨끗한 DB에서 측정**(누적 주문 열화 방지). 측정 전 테스트 주문/장바구니 TRUNCATE(메인 수행).

## Target
`shop-core/perf/k6/scenarios/coupon-apply.js`(신규) + `lib/seed.js`에 쿠폰/발급 시드 보강. **앱 코드·빌드 무변경**(기존 admin/coupon API만 호출).

## Goal
쿠폰 사용 동시성 경로를 가압해 **경합 하의 p95/throughput·에러율**과 **중복 사용 충돌의 응답 양상(429/409)**을 측정하고 thresholds(형태)를 확정한다. 목적은 추세 회귀 감시 + "경합이 락으로 정상 직렬화되는가(붕괴 아님)"의 블랙박스 확인.

## 범위 (Scope)
- **시드 보강(`lib/seed.js`)**: setup이 (1) admin으로 쿠폰 생성(사용 한도 있는 쿠폰), (2) buyer들에게 userCoupon 발급. 정확한 경로·스키마(쿠폰 생성 `/api/v1/admin/coupons`, 발급/조회 `/api/v1/coupons/**`)는 plan에서 코드 대조로 확정(Task 001 선례처럼 Explore 계약 실사).
- **경합 시나리오 설계(plan 확정)**: 두 경합 형태 중 본 Task가 가압할 대상을 plan에서 택1·명시:
  - (A) **단일 사용 userCoupon에 동시 주문**: 같은 userCoupon을 소수가 동시에 써서 "한 번만 사용" 직렬화를 가압(중복 사용 시 충돌).
  - (B) **한도 있는 쿠폰의 동시 발급/사용**: 한정 수량 쿠폰에 다수 동시 신청/사용 → 한도 경계 경합.
- **VU 흐름**: buyer가 `POST /api/v1/cart/items` → `POST /api/v1/orders {userCouponId}`(쿠폰 적용). 충돌 응답(409/429)을 정상 비즈니스 흐름으로 카운트.
- **계측**: `Counter coupon_applied`(할인 적용 성공), `Counter coupon_conflict`(중복/한도 초과 충돌 — 정상, 가시화), `Counter coupon_5xx`(락 붕괴=비정상), 선택 `Trend coupon_order_duration`.
- **프로파일 구동**: 기존 smoke/load로 구동. 새 프로파일 미추가.
- **thresholds(형태)**: `http_req_failed`는 충돌(409/429)을 실패로 셀 수 있어 주의 — **비즈니스 충돌은 check/Counter로 분리**하고 http_req_failed에는 진짜 오류만 잡히게 한다(plan에서 4xx 처리 정책 확정). `coupon_5xx` count==0.

## Non-goals
- stress·payment 시나리오 — 별 Task(003/004).
- 중복 사용 0의 정밀 정합 검증 — Testcontainers 책임(블랙박스 한정).
- 쿠폰 발급(issue) 단독 부하 — 본 Task는 "적용(주문 할인)" 경합 중심. 발급 한도 경합(B)을 택하면 포함.
- 앱/빌드 변경 — 없음.

## 검증 방법
- **실행 통과**: `k6 run -e PROFILE=smoke|load shop-core/perf/k6/scenarios/coupon-apply.js`가 완료, 확정 thresholds 만족.
- **경합 정상 직렬화**: `coupon_5xx`==0, 충돌은 409/429로만 나타남(락 붕괴·중복 사용 5xx 부재). 충돌률이 시나리오 설계(A/B)와 정합.
- **JSON 아티팩트**: `baselines/coupon-apply-smoke.json`(또는 load) 산출.
- `./gradlew test` 게이트 무관.

## 트레이드오프
- **충돌 응답의 http_req_failed 처리**: 쿠폰 충돌(409/429)은 정상인데 기본 `http_req_failed`가 4xx를 실패로 셀 수 있다 → 비즈니스 충돌을 Counter/check로 분리하고 임계에서 제외. 이 분리를 plan에서 명시(과잉 실패율로 오탐 방지).

## 참고
- 로드맵 §6(3순위)·§9, Task 001/002, 가압 대상: order-create `userCouponId` 경로 + 쿠폰 API(`/api/v1/admin/coupons`, `/api/v1/coupons/**`), 쿠폰 도메인 Task 031
- 구현 담당: `k6-implementor` (계약 실사는 메인이 Explore로 선행)

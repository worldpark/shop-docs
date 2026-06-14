# 031. shop-core 쿠폰 발급·조회·적용 + 주문 할인 계산 (서비스/REST)

> 출처: `docs/backlog/backend/remaining-tasks-roadmap.md` §5(기타 도메인 확장) "쿠폰/할인(주문 금액 계산·동시성)" 승격. DB 스키마(`coupons`/`user_coupons`)는 **V1에 이미 정의**되어 있으나(코드 미구현) 비즈니스 로직·REST·주문 연동이 전무하다. 본 Task가 그 공백을 채운다.

## Target
shop-core (coupon 도메인 + order·payment 연동)

> **백엔드/REST 서비스 기능에 한정**한다(서비스·도메인·REST API·동시성·주문 라이프사이클 연동). **Thymeleaf 화면(쿠폰함 화면·체크아웃 쿠폰 선택 UI)은 별도 후속 Task로 분리**(범위 밖). 신규 이벤트·notification 발송 없음(쿠폰 사용은 내부 상태 — `OrderCompletedEvent.totalAmount`가 이미 최종 할인액).

---

## Goal
로그인 사용자가 **쿠폰 코드로 발급(claim)** 받아 **쿠폰함을 조회**하고, **주문 생성 시 보유 쿠폰을 적용**하면 서버가 **할인액을 계산**해 `Order.discountAmount`/`finalAmount`에 반영한다. 결제·환불은 이미 `finalAmount` 기준으로 흐르므로(016/017/018) 할인이 자동 전파된다. 쿠폰은 **1인 1매·1회용·총 한도** 제약을 동시성 안전하게 보장하고, 주문 취소(018)/만료(022) 시 **복원**된다. ADMIN이 쿠폰 정의를 생성하는 최소 경로를 포함한다.

## Context
- **DB 스키마는 V1에 존재(무변경 우선)**: `coupons`(정의: `code`/`name`/`discount_type`(fixed|percent)/`value`/`min_order_amount`/`max_discount`/`starts_at`/`ends_at`/`usage_limit`/`used_count`/`is_active`, UNIQUE(code), CHECK(ends_at>starts_at)), `user_coupons`(발급·사용: `user_id`/`coupon_id`/`order_id`/`issued_at`/`used_at`, UNIQUE(user_id, coupon_id)). **두 테이블 모두 `created_at`/`updated_at` 컬럼·트리거가 없다** → Entity는 `BaseEntity`를 상속하지 않고 V1 컬럼만 매핑한다(ddl-auto=validate 정합, ADR-007). 정본: `docs/entity/database_design.md` §4.5.
- **주문 금액 계산 훅(이미 자리 있음)**: `Order.discountAmount`(현재 `BigDecimal.ZERO` 고정), `finalAmount = itemsAmount - discountAmount + shippingFee`. 계산 지점 `order/service/OrderService.createOrderTx`(itemsAmount 산정 직후 → `Order.create` 호출 전). `Order.create` 시그니처에 discountAmount 주입(현재 내부 ZERO 고정 제거).
- **결제/환불 자동 전파**: `Payment.amount = Order.finalAmount`(016/017), 환불액 = `Payment.amount`(018). 할인된 finalAmount가 PG·환불로 그대로 흐르므로 **결제/환불 로직 변경 불필요**. **중요: 환불은 `Payment.amount`(=할인 후 실제 결제액)를 돌려주며 `itemsAmount`(쿠폰 미적용 판매가)로 환불하지 않는다** — Constraints의 "판매가 환불 금지" 불변식 참조.
- **이벤트 무변경**: `OrderCompletedEvent.totalAmount`는 `Order.finalAmount`의 long 변환(이미 할인 반영). `OrderCancelledEvent.refundedAmount`도 실 결제액 기준. **`event-catalog.md`/§5 무변경, notification 무관**(029와 동일하게 이벤트/알림 없음).
- **회원 식별**: `user_coupons.user_id`(스칼라 FK). REST는 principal=userId(JWT), 소유권은 principal 본인 한정(타 회원 쿠폰 접근 불가).
- **장바구니 금액 출처**: `CartCheckoutReader.getCheckoutCart`(주문 생성·미리보기 공용). 적용 가능 쿠폰·예상 할인 미리보기는 이 장바구니 금액 기준.
- **동시성 선례(분산락 불요 — 단일 DB)**: 재고는 `UPDATE ... WHERE stock>=:qty`(조건부)/비관락. 쿠폰도 동일 — backlog 007(분산락) 미도입. `database_design.md` §6 패턴 계승.
- **모듈 배치(plan 확정 — 아래 §plan 결정)**: package-structure-rule은 도메인 6개 고정. 쿠폰을 `order` 모듈에 둘지 신규 `coupon` 모듈로 분리할지 plan에서 확정한다.

## plan 확정 필요 (설계 결정 — 본 Task가 plan에 위임)
1. **모듈 배치**: (권장) `order` 모듈 내 `coupon` 하위 패키지/서비스로 두어 7번째 도메인 모듈 신설을 피한다(할인은 order의 가격 책임, `user_coupons.order_id`가 order에 결합). 대안: 신규 `coupon` 도메인 모듈(2 테이블·독립 라이프사이클이 정당 사유 — package-structure-rule). 신규 모듈 시 `@NamedInterface`·ModularityTests 갱신 필요. **둘 중 하나로 확정.**
2. **쿠폰 사용(used_at) 확정 시점**: **주문 생성(createOrderTx) 시 소비로 확정**(재고 차감 선례와 동일 트랜잭션·동일 시점 일치) + 취소(018)/만료(022) 시 복원. 결제 확정(paid) 시 소비는 **대안으로만 기록**(채택 안 함 — 재고와 라이프사이클을 일치시켜 생성 시 차감→취소/만료 시 복원으로 통일). 본 문서의 Requirements·Acceptance·Test는 이 확정안(생성 시 소비) 기준으로 기술한다.
3. **usage_limit(총 한도) 증가 시점**: 사용(used_at 기록) 시 `used_count++`(조건부 UPDATE), 복원 시 `used_count--`. (발급 시점이 아니라 사용 시점 — 권장. plan 확정.)
4. **발급(claim) 방식**: (권장) **사용자 코드 발급**(`code` 입력 → user_coupons 행 생성). 대안/추가: ADMIN이 특정 회원에게 직접 발급. 본 Task는 코드 발급을 기본으로 하고 admin 직접 발급은 범위 밖(후속).
5. **할인액 절사 처리(percent)**: `floor(itemsAmount * value / 100)`(원 단위 내림) + `max_discount` 상한. 반올림 규칙·통화 정밀도(numeric(12,2)) plan 확정.
6. **min_order_amount 미달/유효기간 외/비활성 쿠폰 적용 시도**: 거부(400, 사유 메시지). 미리보기 응답에서는 "적용 불가 사유" 표기. 정확한 에러 코드/메시지 plan 확정.

## API Authorization
> `docs/rules/api-authorization-rule.md` 준수. 쿠폰함·발급·적용은 **principal 본인** 한정(IDOR 차단 — 경로/바디로 타 회원 id 받지 않음). 쿠폰 정의 생성은 ADMIN.

| API | 공개 여부 | 최소 권한 | 소유권/증명 | 비고 |
|---|---|---|---|---|
| `POST /api/v1/coupons` | authenticated | `CONSUMER` | principal 본인 | 코드로 쿠폰 발급(claim) — 발급 |
| `GET /api/v1/coupons` | authenticated | `CONSUMER` | principal 본인 | 내 쿠폰함 조회(미사용/사용 구분) — 조회 |
| `GET /api/v1/coupons/applicable` | authenticated | `CONSUMER` | principal 본인 | 현재 장바구니에 적용 가능한 보유 쿠폰 + 예상 할인액 — 적용 미리보기/할인계산 |
| `POST /api/v1/orders` (확장) | authenticated | `CONSUMER` | principal 본인 | 주문 생성 시 `userCouponId`(선택) 적용 — 적용 + 할인 계산 |
| `POST /api/v1/admin/coupons` | authenticated | `ADMIN` | — | 쿠폰 정의 생성(최소) — 발급 대상 정의 |

> `/api/v1/coupons/**`·주문 경로는 SecurityConfig에서 `hasRole("CONSUMER")`, admin 경로는 기존 `/api/v1/admin/**` `hasRole("ADMIN")`가 이미 커버(의도 명시 가능). 모든 소유권은 **principal userId에서만 도출**(바디/경로로 user_coupon 소유자 변경 불가).

## Requirements
- **쿠폰 정의 생성(ADMIN, `POST /api/v1/admin/coupons` — 최소)**
  - 입력: `code`/`name`/`discountType`(fixed|percent)/`value`/`minOrderAmount`/`maxDiscount`(percent 한정)/`startsAt`/`endsAt`/`usageLimit`(nullable)/`isActive`. CHECK(value>0, ends_at>starts_at) 도메인 검증. `code` 중복 → 409.
  - 본 Task는 **생성만** 최소 제공(수정·비활성·목록 등 admin 쿠폰 관리 UI/CRUD는 범위 밖 — 후속).
- **발급(claim, `POST /api/v1/coupons`)**
  - 입력: `code`. 활성·유효기간 내 쿠폰만 발급. `user_coupons(user_id, coupon_id)` **UNIQUE로 1인 1매** 보장(중복 발급 → 409/이미 보유). `issued_at=now()`, `order_id`/`used_at`=null. **발급은 `used_count`를 증가시키지 않는다**(총 한도는 사용 시점에 소진 — plan 결정 3).
- **조회(`GET /api/v1/coupons`)**
  - principal 본인의 `user_coupons` 목록 + 조인한 `coupons` 정의(코드/이름/할인/유효기간) 반환. **미사용(used_at null)/사용됨** 구분. 만료 여부 계산 표기. Entity 직접 반환 금지(DTO).
- **적용 미리보기(`GET /api/v1/coupons/applicable`)**
  - 현재 장바구니 금액(`CartCheckoutReader`) 기준으로 **보유 미사용 쿠폰별 적용 가능 여부 + 예상 할인액**을 계산해 반환(읽기 전용, 상태 변경 없음). 적용 불가 쿠폰은 사유(유효기간/최소주문금액 미달/비활성) 표기.
- **적용 + 주문 할인 계산(`POST /api/v1/orders`에 `userCouponId` 선택 적용)**
  - `OrderService.createOrderTx`에서 `userCouponId`가 있으면 **같은 트랜잭션 안에서**:
    1. user_coupon 소유권(principal)·미사용(`used_at IS NULL`)·쿠폰 활성/유효기간/`min_order_amount`(itemsAmount 기준) 검증. 위반 → 400(거부, 주문 롤백).
    2. 할인액 계산: `fixed` → `min(value, itemsAmount)`, `percent` → `min(floor(itemsAmount*value/100), max_discount)`(상한 NULL이면 미적용). 음수/초과 방지(discount ≤ itemsAmount).
    3. `Order.discountAmount` 설정, `finalAmount = itemsAmount - discountAmount`(shippingFee=0 현행).
    4. **쿠폰 소비(1회용)**: `UPDATE user_coupons SET used_at=now(), order_id=:orderId WHERE id=:id AND used_at IS NULL`(조건부 — 영향행 0이면 동시 사용 충돌 → 거부/롤백). **총 한도**: `UPDATE coupons SET used_count=used_count+1 WHERE id=:couponId AND (usage_limit IS NULL OR used_count<usage_limit)`(영향행 0이면 한도 소진 → 거부/롤백).
  - `userCouponId` 없으면 기존 흐름(discount=0) 그대로(회귀 없음).
- **복원(주문 취소 018 / 만료 022 연동)**
  - 쿠폰이 적용된 주문이 취소/만료되면 같은 트랜잭션에서 **쿠폰 복원**: `UPDATE user_coupons SET used_at=NULL, order_id=NULL WHERE order_id=:orderId AND used_at IS NOT NULL` + `UPDATE coupons SET used_count=used_count-1 WHERE id=:couponId AND used_count>0`. 재고 복원과 동일한 취소/만료 경로에 hook. (멱등: 이미 복원된 경우 영향행 0.)

## Constraints
- **본인 한정(IDOR 차단)**: 발급/조회/적용 모든 동작은 principal 본인 user_coupon만 대상. 경로/바디로 타 회원·타 소유 user_coupon id를 신뢰하지 않는다(소유권 = principal userId로 검증).
- **동시성(분산락 불요·단일 DB)**: 1인 1매=UNIQUE(user_id, coupon_id), 1회용=`used_at` 조건부 UPDATE, 총 한도=`used_count` 조건부 UPDATE. 조건부 UPDATE 영향행 수로 경합 패자를 거부(재고 차감 선례). 동시 주문에서 같은 쿠폰 이중 사용 불가.
- **금액 정합**: `numeric(12,2)`/`BigDecimal`. discount ≤ itemsAmount(음수 finalAmount 금지). percent 할인은 원 단위 내림(절사) + max_discount 상한. 할인 후 `finalAmount`가 결제/환불의 단일 출처.
- **DB 스키마 변경 최소**: `coupons`/`user_coupons`는 V1 사용(무변경). 신규 컬럼 불필요. **미사용 쿠폰 조회 부분 인덱스**(`(user_id) WHERE used_at IS NULL`, database_design §인덱스)만 성능상 필요 시 **V7로 추가**(선택 — plan 확정). Entity는 V1 컬럼만 매핑(`BaseEntity` 미상속 — created_at/updated_at 부재).
- **이벤트/notification 무변경**: 쿠폰 사용은 내부 상태. `OrderCompletedEvent`/`OrderCancelledEvent`는 이미 최종 금액 기준 → 계약·notification 무변경(`event-catalog.md`/§5 불변).
- **레이어 규칙**: REST `@RestController→ServiceResponse→Service→Repository`. 컨트롤러 비즈니스 로직 금지. 주문 생성 시 쿠폰 검증·할인 계산은 서비스 경계(`OrderService`/쿠폰 서비스). 모듈 경계 통신은 spi/published port(쿠폰이 별도 모듈일 경우).
- **결제/환불 금액 로직 무변경 보장(가산 hook은 예외)**: 환불 **금액 계산·PG 환불 로직**은 손대지 않는다 — 할인은 `Order.finalAmount`로 자동 전파되므로 환불액 산정식(`refundedAmount = Payment.amount`) 불변. 단 취소(018)/만료(022) 트랜잭션에 **쿠폰 복원 호출(가산)** 은 추가한다(금액 로직 변경 아님 — `PaymentService.cancel`/만료 경로에 복원 1콜 삽입). 결제 승인·금액 검증 로직(016/017)은 무변경. 회귀 금지.
- **환불액 = 실제 결제액(할인 후) 보장 — 판매가 환불 금지**: 쿠폰 적용 주문 환불은 반드시 **사용자가 실제 결제한 금액**(`Payment.amount` = 할인 후 `Order.finalAmount`)을 돌려준다. **쿠폰 미적용 판매가(`itemsAmount`)나 정의상 금액으로 환불하지 않는다.** 현 코드가 `Payment.amount` 기준 환불(018)이라 정합하나, 본 Task로 할인이 도입되면 이 불변식을 테스트로 명시 고정한다(환불액 ≠ itemsAmount 단언).
- **화면 범위 밖**: 쿠폰함·체크아웃 쿠폰 선택 Thymeleaf 화면은 후속 Task(본 Task는 REST/서비스).

## Files
> 정확 경로/모듈 배치는 plan 확정(§plan 결정 1). 아래는 `order` 모듈 배치 가정 예시.
- (신규) `order/domain/Coupon.java` — `coupons` 매핑 Entity(BaseEntity 미상속), 할인 계산 도메인 메서드(`calculateDiscount(itemsAmount)`), 유효성(`isClaimable(now)`/`isApplicable(now, itemsAmount)`).
- (신규) `order/domain/UserCoupon.java` — `user_coupons` 매핑 Entity(BaseEntity 미상속), `markUsed(orderId)`/`restore()` 도메인 메서드.
- (신규) `order/repository/CouponRepository.java` — `findByCode`(활성), `incrementUsedCountIfWithinLimit`(조건부 UPDATE), `decrementUsedCount`(복원).
- (신규) `order/repository/UserCouponRepository.java` — `findByUserId`(+coupon fetch), `findByIdAndUserId`, `markUsedIfUnused`(조건부 UPDATE), `restoreByOrderId`.
- (신규) `order/service/CouponService.java`(+ `CouponServiceResponse`) — claim/조회/applicable 미리보기/적용 검증·계산/복원. (모듈 분리 시 spi facade 포함.)
- (신규) `order/dto/**` — `CouponClaimRequest`(code), `UserCouponResponse`, `ApplicableCouponResponse`(coupon+예상할인+적용가능사유), `AdminCouponCreateRequest`.
- (신규) `order/controller/CouponRestController.java` — `/api/v1/coupons`(claim), `GET /api/v1/coupons`, `GET /api/v1/coupons/applicable`.
- (신규) `order/controller/AdminCouponRestController.java`(또는 기존 admin 컨트롤러 확장) — `POST /api/v1/admin/coupons`(최소 생성).
- (수정) `order/service/OrderService.java` — `createOrderTx`에 `userCouponId` 검증·할인 계산·쿠폰 소비 통합. `Order.create` 시그니처에 discountAmount 주입.
- (수정) `order/domain/Order.java` — `Order.create`가 discountAmount를 받아 finalAmount 산정(ZERO 고정 제거). **시그니처 변경 → 기존 모든 호출부·테스트·픽스처를 discount=ZERO로 갱신(가산 diff도 회귀 유발 — verification-gate-rule). 호환 위해 오버로드(기존 시그니처는 discount=ZERO 위임) 추가도 대안 — plan 확정.** 취소/만료 복원 연동 지점.
- (수정) `order/dto/**`(주문 생성 요청/응답) — `userCouponId`(요청, 선택) + `discountAmount`(응답, 기존 필드 채움).
- (수정) `payment/service/PaymentService.cancel`(018) 또는 취소 서비스 — 쿠폰 복원 hook(취소 트랜잭션 내).
- (수정) 미결제 만료 스케줄러 경로(022) — 만료 취소 시 쿠폰 복원 hook.
- (수정) `security/SecurityConfig.java` — `/api/v1/coupons/**` `hasRole("CONSUMER")`(admin 경로는 기존 `/api/v1/admin/**` 커버, 의도 명시 가능).
- (신규, 선택) `src/main/resources/db/migration/V7__user_coupons_unused_index.sql` — 미사용 쿠폰 부분 인덱스(성능, plan 확정 시).
- (수정, 선택) `docs/entity/database_design.md` — 쿠폰 사용/복원 라이프사이클·인덱스 반영(스키마 의도 갱신).
- (재사용·무변경) `CartCheckoutReader`, `MemberRepository`/principal 해석, `RestExceptionHandler`(BusinessException), `event-catalog.md`/§5, notification 전부.

## Acceptance Criteria
- 사용자가 유효한 **코드로 쿠폰을 발급**받으면 `user_coupons` 행이 생성되고, **같은 쿠폰 재발급은 거부**된다(1인 1매).
- **쿠폰함 조회** 시 본인 보유 쿠폰이 미사용/사용 구분·만료 표기와 함께 반환되고, 타 회원 쿠폰은 보이지 않는다.
- **적용 미리보기**가 현재 장바구니 기준 적용 가능 쿠폰과 예상 할인액(fixed/percent, min_order_amount·max_discount 반영)을 반환하고, 적용 불가 쿠폰은 사유를 표기한다.
- **주문 생성 시 쿠폰 적용**하면 `Order.discountAmount`/`finalAmount`가 정확히 계산되고(`finalAmount = itemsAmount - discount`, 음수 불가), 결제 금액·환불 금액이 할인된 `finalAmount`를 따른다(결제/환불 코드 무변경).
- 쿠폰은 **1회만 사용**되고(동시 주문에서 이중 사용 거부), **총 한도(usage_limit) 초과 사용이 거부**된다(조건부 UPDATE 경합 안전).
- **쿠폰 적용 주문이 취소(018)/만료(022)되면 쿠폰이 복원**된다(used_at/order_id 초기화 + used_count 감소, 멱등).
- 유효기간 외·비활성·최소주문금액 미달 쿠폰 적용은 거부(400)되고 주문이 롤백된다.
- `coupons`/`user_coupons` V1 스키마·기존 이벤트·notification·결제/환불이 무변경이다(쿠폰 미적용 주문은 기존 흐름과 동일, 회귀 없음).

## Test
- **단위(Mockito)**: 할인 계산 — fixed(value/itemsAmount 미만·초과), percent(floor·max_discount 상한·상한 null), min_order_amount 미달 거부, discount≤itemsAmount 보장. 발급 — 신규/중복(1인1매) 분기. 적용 — 미사용/이미사용/유효기간/비활성/소유권 위반 분기. `Order.create`가 discountAmount로 finalAmount 산정.
- **통합(Testcontainers + Redis 불요)**: 발급 UNIQUE(user_id, coupon_id) 위반 거부. 주문 생성 시 쿠폰 소비(used_at/order_id 기록) + `coupons.used_count` 증가. **동시 주문 2건이 같은 쿠폰 적용 → 1건만 성공**(used_at 조건부 UPDATE 경합). **usage_limit=N 한도 초과 동시 사용 → N건만 성공**(used_count 조건부 UPDATE). 취소/만료 시 복원(used_at/order_id null·used_count 감소, 멱등 재호출 무영향).
- **Security/REST(MockMvc)**: `/api/v1/coupons/**` 비로그인 401, 타 회원 user_coupon 접근 불가(본인만), admin 생성은 ADMIN만(CONSUMER 403). 주문 생성에 본인 미보유/이미사용 `userCouponId` → 400.
- **금액 전파 통합**: 쿠폰 적용 주문의 `Payment.amount == Order.finalAmount`(할인 반영). **취소 시 환불액 == 할인 후 실제 결제액(`Payment.amount`)이며 `itemsAmount`(판매가)와 다름을 명시 단언**(할인 > 0 케이스로 환불액 < itemsAmount 확인 — 판매가 환불 회귀 차단). `OrderCompletedEvent.totalAmount`가 할인 반영 값.
- **회귀**: 쿠폰 미적용 주문 생성·결제·취소·만료(015/016/017/018/022) 그린 유지. 결제/환불 로직 무변경 확인. `./gradlew test` 풀 그린.

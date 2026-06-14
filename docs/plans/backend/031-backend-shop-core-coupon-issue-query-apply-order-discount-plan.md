# Task 031 — shop-core 쿠폰 발급·조회·적용 + 주문 할인 계산 (백엔드/REST) plan

> 범위 SSOT: docs/tasks/backend/031-backend-shop-core-coupon-issue-query-apply-order-discount.md
> 대상: shop-core. 구현자: backend-implementor 단독(view-implementor 단계 없음).
> 본 plan은 Task가 위임한 6개 설계 결정을 코드 대조로 확정한다. 화면(Thymeleaf)·admin 쿠폰 관리 CRUD·admin 직접 발급·분산락은 범위 밖.
> 패키지 루트는 `com.shop.shop`(코드 대조 확인 — `com.shop` 아님).

## 구현 목표
로그인 사용자가 코드로 쿠폰을 발급(claim)받아 쿠폰함을 조회하고, 주문 생성 시 보유 쿠폰을 적용하면 서버가 할인액을 계산해 `Order.discountAmount`/`finalAmount`에 반영한다. 결제·환불은 기존대로 `finalAmount` 기준으로 흐르므로 할인이 자동 전파된다. 쿠폰은 1인 1매·1회용·총 한도를 동시성 안전하게 보장하고, 주문 취소(018)/만료(022) 시 복원된다. ADMIN이 쿠폰 정의를 생성하는 최소 경로를 포함한다.

## 영향 범위

### 신규 파일
- `order/domain/Coupon.java`
- `order/domain/UserCoupon.java`
- `order/repository/CouponRepository.java`
- `order/repository/UserCouponRepository.java`
- `order/service/CouponService.java` (내부 결과 record 포함)
- `order/service/CouponServiceResponse.java`
- `order/service/CouponDtoMapper.java`
- `order/controller/CouponRestController.java`
- `order/controller/AdminCouponRestController.java`
- `order/dto/CouponClaimRequest.java`
- `order/dto/UserCouponResponse.java`
- `order/dto/ApplicableCouponResponse.java`
- `order/dto/AdminCouponCreateRequest.java`
- `order/dto/AdminCouponResponse.java`
- `common/exception/CouponNotFoundException.java` (404)
- `common/exception/CouponNotClaimableException.java` (400 — 발급 불가: 비활성/유효기간 외)
- `common/exception/CouponAlreadyOwnedException.java` (409 — 1인 1매 중복 발급)
- `common/exception/CouponNotApplicableException.java` (400 — 적용 불가: 최소주문금액 미달/유효기간 외/비활성)
- `common/exception/CouponConflictException.java` (409 — 동시 사용/한도 소진 경합 패자)
- `common/exception/DuplicateCouponCodeException.java` (409 — admin 코드 중복)
- (테스트) 아래 §5 검증 방법에 열거한 단위/통합/Security/금액전파 테스트 클래스

### 수정 파일
- `order/domain/Order.java` — `create`에 discountAmount/finalAmount 주입하는 **신규 오버로드 추가**(기존 8-arg 시그니처는 discount=ZERO 위임으로 유지). 도메인 불변식(`finalAmount = itemsAmount - discountAmount ≥ 0`) 검증.
- `order/service/OrderService.java` — `createOrderTx`에 `userCouponId`(요청 필드) 검증·할인 계산·소비 통합. `CouponService` 주입.
- `order/dto/OrderCreateRequest.java` — `userCouponId`(Long, 선택) 6번째 필드 추가.
- `order/service/OrderDtoMapper.java` — 무변경(이미 `discountAmount`를 OrderResponse에 매핑 중 — 코드 대조 확인). `OrderResponse.discountAmount`/`OrderDetail.discountAmount`는 이미 존재.
- `order/service/OrderCancellationImpl.java` — `doCancel` 코어에 쿠폰 복원 hook 1콜 추가(취소·만료 공용 경로). `CouponService.restoreByOrder(orderId)` 호출.
- `web/order/OrderViewController.java` — `OrderCreateRequest` 생성부에 6번째 인자 `null`(View 쿠폰 선택 UI 범위 밖) 추가(컴파일 정합).
- `security/SecurityConfig.java` — REST 체인에 `/api/v1/coupons/**` `hasRole("CONSUMER")` matcher 추가(admin은 기존 `/api/v1/admin/**`가 커버).
- `docs/entity/database_design.md` — 쿠폰 사용/복원 라이프사이클 의도 보강(스키마 무변경).

### 무변경(재사용)
`payment/service/PaymentService.java`(cancel/expirePendingOrder — 금액·PG 로직 무변경, 복원 hook은 `OrderCancellationImpl.doCancel` 내부에만 삽입), `order/spi/OrderCancellation`(시그니처), `order/service/OrderServiceResponse.java`(`createOrder` 시그니처 무변경 — userCouponId가 request 필드라 통과만), `order/service/OrderService.placeOrder`(시그니처 무변경), `cart/spi/CartCheckoutReader`, `event-catalog.md` 전체, notification 전부, V1~V6 마이그레이션(**V7 만들지 않음**).

---

## 1. 설계 방식 및 이유

> 기존 초안 §1.1~1.6은 코드 대조가 정확하다. 아래에서 **검증 결과를 반영하고**, 초안이 과하게 잡았던 변경 범위를 **정정·축소**한다.

### 1.1 모듈 배치 — order 모듈에 호스팅 (결정 1 확정 = order 모듈, 신규 모듈 신설 안 함)
쿠폰을 신규 도메인 모듈로 만들지 않고 order 모듈 내부 패키지(`order/domain`, `order/repository`, `order/service`, `order/controller`, `order/dto`)에 둔다.

근거(코드 대조):
- 인식 모듈은 정확히 6개 도메인(member/product/cart/order/payment/inventory) + common/security/web/platform이다. package-structure-rule이 도메인을 6개로 고정한다. 신규 coupon 모듈은 7번째 도메인이 되어 규칙·`@NamedInterface`·구조 테스트에 파급된다.
- 할인은 order의 가격 책임이다. `OrderService.createOrderTx`가 `itemsAmount`를 산정(line 186~191)하고 `Order.create`로 `finalAmount`를 확정하는 단일 지점이다. 쿠폰 소비·할인 계산은 이 트랜잭션과 같은 경계에 있어야 원자성·복원 멱등이 보장된다.
- `user_coupons.order_id`가 `orders(id)`를 FK로 직접 참조한다(V1 line 373, `ON DELETE SET NULL`). 쿠폰 사용 라이프사이클이 order에 결합돼 있다.
- 취소/만료 복원이 들어갈 자리는 `OrderCancellationImpl.doCancel`(재고 복원과 같은 코어, line 116~194). 이 코어가 order 모듈 내부이므로 쿠폰 repository를 같은 모듈에서 직접 호출하면 spi 경유가 불필요하다.
- **ArchUnit 영향 0 확인**: `OrderModuleStructureTest`의 규칙 1~13은 "order가 타 모듈 내부를 참조하지 않음"을 검증한다. 쿠폰 컴포넌트는 전부 `com.shop.shop.order..` 내부이고 신규 cross-module 의존이 없으므로 모든 규칙이 그린 유지된다(allowEmptyShould(true) 무관). Spring Modulith ModularityTests도 신규 모듈이 없어 무변경.

결론: order 모듈 내부 호스팅이 응집도·트랜잭션 경계·규칙 준수에서 우월하다. 쿠폰 컴포넌트는 order 모듈 internal(domain/repository/service/dto)에 두며 다른 모듈에 노출하지 않는다.

대안(채택 안 함): 신규 coupon 도메인 모듈. order와 강결합(order_id FK, 같은 트랜잭션 소비/복원)·6모듈 고정 규칙 때문에 비용이 이득을 초과한다.

### 1.2 Entity는 BaseEntity 미상속 (코드 정정 반영)
`coupons`/`user_coupons` 두 테이블은 `created_at`/`updated_at` 컬럼·트리거가 없다(V1 line 343~378 확인). 따라서 `Coupon`/`UserCoupon`은 `BaseEntity`를 상속하지 않고 V1 컬럼만 매핑한다(ddl-auto=validate 정합, ADR-007). 참고로 `Order`는 `orders`에 created_at/updated_at이 있어 `BaseEntity`를 상속한다(Order.java line 34) — 쿠폰 Entity와 상반되므로 혼동 금지.

### 1.3 동시성 — 조건부 UPDATE + UNIQUE (분산락 불요, 단일 DB)
`database_design.md` §6이 쿠폰 총 한도용 조건부 UPDATE를 명시한다(line 525~535: `UPDATE coupons SET used_count=used_count+1 WHERE id=:id AND (usage_limit IS NULL OR used_count < usage_limit)`). 본 plan은 이를 그대로 채택한다.
- **1인 1매**: `user_coupons` UNIQUE(user_id, coupon_id) — 발급 시 중복 INSERT는 `DataIntegrityViolationException`으로 드러나 `CouponAlreadyOwnedException`(409)으로 변환.
- **1회용**: `UPDATE user_coupons SET used_at=now(), order_id=:orderId WHERE id=:id AND user_id=:userId AND used_at IS NULL` — 영향행 0이면 동시 사용/이미 사용 → 거부·롤백.
- **총 한도**: `UPDATE coupons SET used_count=used_count+1 WHERE id=:couponId AND is_active=true AND (usage_limit IS NULL OR used_count < usage_limit)` — 영향행 0이면 한도 소진/비활성 → 거부·롤백.
- **복원**: `UPDATE user_coupons SET used_at=NULL, order_id=NULL WHERE order_id=:orderId AND used_at IS NOT NULL`(멱등) + `UPDATE coupons SET used_count=used_count-1 WHERE id=:couponId AND used_count > 0`(멱등 하한).

재고 선례(`InventoryStockPortImpl`)는 비관락+dirty checking을 쓰지만(line 46~76), 쿠폰은 §6이 조건부 UPDATE를 직접 규정하고 단순 카운터 증감이라 조건부 UPDATE(JPQL `@Modifying`)가 더 적합하다. 분산락(backlog 007)은 도입하지 않는다(ADR-005 단일 DB 단계).

> 트랜잭션 경계: 위 모든 사용/복원 UPDATE는 `createOrderTx`(@Transactional) 또는 `doCancel`(클래스 @Transactional)의 **호출자 트랜잭션 안**에서 실행된다. `CouponService`의 해당 메서드는 자체 `@Transactional`을 열지 않거나 `Propagation.MANDATORY`/기본 전파로 호출자 경계에 합류한다(재고 `InventoryStockPort.decrease` 선례와 동일 — 호출자 경계 합류).

### 1.4 소비 시점 — 주문 생성 시 확정 (결정 2)
재고 차감과 동일 트랜잭션·동일 시점(`createOrderTx`)에서 쿠폰을 소비한다. 취소(018)/만료(022) 시 복원한다. 결제 확정(paid) 시 소비는 대안으로만 기록하고 채택하지 않는다(재고와 라이프사이클 일치 — 생성 시 차감, 취소/만료 시 복원).

### 1.5 발급 방식 — 코드 claim 기본 (결정 4)
사용자가 `code`를 입력하면 활성·유효기간 내 쿠폰에 대해 `user_coupons` 행을 생성한다. admin 직접 발급은 범위 밖(후속). **발급은 `used_count`를 증가시키지 않는다**(총 한도는 사용 시점 소진 — 결정 3).

### 1.6 마이그레이션 불필요 (V7 만들지 않음 — 코드 정정)
Task와 `database_design` §인덱스가 미사용 쿠폰 부분 인덱스를 V7 후보로 거론하나, 해당 인덱스가 이미 V1에 존재한다: `CREATE INDEX idx_user_coupons_user_unused ON user_coupons (user_id) WHERE used_at IS NULL`(V1 line 382). 따라서 V7 마이그레이션을 생성하지 않는다. 쿠폰 스키마는 V1을 그대로 재사용(무변경)한다. 현재 최신 마이그레이션은 V6.

### 1.7 `Order.create` 오버로드 (결정 — 무파급안 확정, 초안 보강)
`Order.create` 호출부는 운영 1곳(`OrderService.createOrderTx`)과 테스트 다수(`Order*Test`, `OrderCancellationExpiryTest`, `OrderConfirmationImplTest` 등 — grep 확인)에 존재한다. 기존 8-arg 시그니처를 깨면 모든 호출부·픽스처가 회귀한다(verification-gate-rule §4). 따라서:
- **신규 9-arg 오버로드** `create(userId, orderNumber, itemsAmount, discountAmount, recipient, phone, postcode, address1, address2)` 추가 — `finalAmount = itemsAmount.subtract(discountAmount)`, `discountAmount ≥ 0 && finalAmount ≥ 0` 불변식 검증(위반 시 `IllegalStateException`, 방어적 — 서비스가 사전 보장).
- **기존 8-arg `create`는 신규 오버로드에 `discountAmount=BigDecimal.ZERO`로 위임**. 모든 기존 호출부·테스트 무변경(가산만) → 회귀 0.
- `createOrderTx`는 `userCouponId`가 있을 때만 9-arg 오버로드를 쓰고, 없으면 기존 8-arg(=discount ZERO)를 그대로 호출한다 → 쿠폰 미적용 주문은 바이트 단위로 기존 흐름 유지.

### 1.8 `userCouponId`는 `OrderCreateRequest` 필드 (초안 정정 — placeOrder/ServiceResponse 시그니처 무변경)
초안은 `OrderService.placeOrder` 시그니처와 `OrderServiceResponse`에 `userCouponId`를 별도 전달한다고 적었으나, **`OrderCreateRequest`에 선택 필드로 넣으면 `placeOrder(userId, request)`·`OrderServiceResponse.createOrder(auth, request)` 시그니처가 모두 무변경**으로 통과한다(request만 흘려보냄). 변경 표면이 줄고 재시도 루프(`placeOrder`의 orderNumber 충돌 재시도)에서 같은 request가 그대로 재사용돼 안전하다.
- 단, `OrderCreateRequest`는 REST와 View가 공유하고 View는 `OrderViewController`가 **명시 생성자**로 만든다(line 118~124). 6번째 필드 추가 시 이 생성부에 `null`을 추가해야 컴파일된다(View 쿠폰 선택은 범위 밖이므로 `null` 고정).

### 1.9 percent 절사·상한 (결정 5 확정)
- `fixed`: `discount = min(value, itemsAmount)`.
- `percent`: `raw = itemsAmount.multiply(value).divide(100)`; `floored = raw.setScale(0, RoundingMode.FLOOR)`(원 단위 내림); `capped = (max_discount != null) ? min(floored, max_discount) : floored`; `discount = min(capped, itemsAmount)`.
- 통화 정밀도: 계산은 `BigDecimal`로 하고 결과 `discountAmount`는 `numeric(12,2)` 정합을 위해 `setScale(2)`로 정규화(KRW 소수부 .00). `finalAmount = itemsAmount - discountAmount ≥ 0` 보장(음수 금지).
- 계산 도메인 메서드는 `Coupon.calculateDiscount(BigDecimal itemsAmount)`에 둔다(단위 테스트 용이).

### 1.10 거부 사유·에러 코드 (결정 6 확정 — §4에서 상세)
- 발급 거부: 미존재 코드 → 404, 비활성/유효기간 외 → 400(`CouponNotClaimableException`), 1인 1매 중복 → 409(`CouponAlreadyOwnedException`).
- 적용 거부: 미보유/타인 소유 → 404(`CouponNotFoundException`, 존재 은닉), 이미 사용 → 409(`CouponConflictException`), 비활성/유효기간 외/최소주문금액 미달 → 400(`CouponNotApplicableException`, 사유 메시지), 동시 사용·한도 경합 패자 → 409(`CouponConflictException`). 모두 주문 트랜잭션 롤백.
- 미리보기(`GET /applicable`)는 거부하지 않고 `applicable=false` + `reason` 문자열로 표기(상태 변경 없음).

---

## 2. 구성 요소

### 2.1 도메인 (order/domain)

**`Coupon.java`** — `coupons` 매핑 Entity(BaseEntity 미상속).
- 필드: `id, code, name, discountType(String "fixed"|"percent"), value(BigDecimal), minOrderAmount(BigDecimal), maxDiscount(BigDecimal nullable), startsAt(Instant), endsAt(Instant), usageLimit(Integer nullable), usedCount(int), isActive(boolean)`.
- 정적 팩토리 `create(...)` — admin 생성용. CHECK 도메인 검증(`value > 0`, `endsAt > startsAt`)을 자바 레벨에서 선검증(위반 시 `BusinessException` 400) — DB CHECK는 최종 방어선.
- `boolean isClaimable(Instant now)` — `isActive && startsAt ≤ now < endsAt`.
- `boolean isWithinPeriod(Instant now)` / `boolean meetsMinOrder(BigDecimal itemsAmount)`.
- `BigDecimal calculateDiscount(BigDecimal itemsAmount)` — §1.9 규칙(절사+상한+음수 방지).
- Setter 금지. 카운터 증감은 repository 조건부 UPDATE로만(엔티티 메서드 미제공 — 경합 안전 위해 DB 단일 출처).

**`UserCoupon.java`** — `user_coupons` 매핑 Entity(BaseEntity 미상속).
- 필드: `id, userId(Long 스칼라), couponId(Long 스칼라), orderId(Long nullable), issuedAt(Instant), usedAt(Instant nullable)`.
- 모듈 경계 준수 위해 member/order Entity 직접 참조 금지 — `userId`/`orderId` Long 스칼라 보유(Order.userId 선례와 동일).
- 정적 팩토리 `issue(userId, couponId, now)` — `usedAt=null, orderId=null, issuedAt=now`.
- `boolean isUsed()` = `usedAt != null`. (사용/복원 상태 변경은 repository 조건부 UPDATE로만 수행 — 경합 안전.)

### 2.2 리포지토리 (order/repository)

**`CouponRepository extends JpaRepository<Coupon, Long>`**
- `Optional<Coupon> findByCode(String code)` — 발급/미리보기 조회.
- `@Modifying @Query("UPDATE Coupon c SET c.usedCount = c.usedCount + 1 WHERE c.id = :id AND c.isActive = true AND (c.usageLimit IS NULL OR c.usedCount < c.usageLimit)") int incrementUsedCountIfWithinLimit(@Param("id") long id)` — 영향행 반환.
- `@Modifying @Query("UPDATE Coupon c SET c.usedCount = c.usedCount - 1 WHERE c.id = :id AND c.usedCount > 0") int decrementUsedCount(@Param("id") long id)`.

**`UserCouponRepository extends JpaRepository<UserCoupon, Long>`**
- `List<UserCoupon> findByUserIdOrderByIssuedAtDesc(long userId)` — 쿠폰함(조회는 `Coupon`을 별도 `findAllById`로 배치 조인 또는 `@Query` fetch projection).
- `Optional<UserCoupon> findByIdAndUserId(long id, long userId)` — 적용 소유권(미존재/타인 → 404).
- `List<UserCoupon> findByUserIdAndUsedAtIsNull(long userId)` — 미리보기(미사용만, 부분 인덱스 활용).
- `@Modifying @Query("UPDATE UserCoupon uc SET uc.usedAt = :now, uc.orderId = :orderId WHERE uc.id = :id AND uc.userId = :userId AND uc.usedAt IS NULL") int markUsedIfUnused(@Param("id") long id, @Param("userId") long userId, @Param("orderId") long orderId, @Param("now") Instant now)`.
- `@Modifying @Query("UPDATE UserCoupon uc SET uc.usedAt = NULL, uc.orderId = NULL WHERE uc.orderId = :orderId AND uc.usedAt IS NOT NULL") int restoreByOrderId(@Param("orderId") long orderId)`.
- 복원 시 감소 대상 couponId 확보용: `Optional<UserCoupon> findByOrderId(long orderId)`(주문당 user_coupon 최대 1매 — 요청 필드 `userCouponId` 단수 — 이므로 단건 조회로 충분).

> `@Modifying` 쿼리 사용 시 영속성 컨텍스트 stale 주의: 같은 트랜잭션에서 UPDATE 후 동일 엔티티를 다시 읽지 않는다(소비는 createOrderTx 종료 직전, 복원은 doCancel 종료 직전 — 재조회 없음). 필요 시 `clearAutomatically`는 부작용 우려로 사용하지 않는다.

### 2.3 서비스 (order/service)

**`CouponService`** (@Service) — claim/조회/applicable/적용/복원의 도메인 로직.
- `UserCouponResult claim(long userId, String code)`:
  - `findByCode` → 없으면 `CouponNotFoundException`(404).
  - `isClaimable(now)` 위반 → `CouponNotClaimableException`(400).
  - `UserCoupon.issue` 저장 → UNIQUE 위반 `DataIntegrityViolationException` → `CouponAlreadyOwnedException`(409).
- `List<UserCouponView> getMyCoupons(long userId)` — user_coupons + coupon 정의 조인, 미사용/사용/만료 표기.
- `List<ApplicableCouponView> getApplicable(long userId)` — 내부에서 장바구니 itemsAmount 산정(아래) 후 미사용 보유 쿠폰별 `applicable`/`expectedDiscount`/`reason` 계산(읽기 전용).
- `AppliedDiscount` 적용은 2단계로 분할:
  - `computeDiscount(long userId, long userCouponId, BigDecimal itemsAmount)` — 검증+할인액 산정(order 생성 전). 반환: `discountAmount`, `couponId`.
  - `consume(long userCouponId, long userId, long couponId, long orderId, Instant now)` — 조건부 UPDATE 2건(order 저장 후).
- `void restoreByOrder(long orderId)` — 복원: `findByOrderId`로 couponId 확보 → `restoreByOrderId`(user_coupon) → `decrementUsedCount`(coupon). 멱등(영향행 0이면 no-op). `doCancel`에서 호출.
- `CouponDefResult createDefinition(AdminCouponCreateRequest req)` — admin 생성. code 중복 → `DuplicateCouponCodeException`(409).
- 내부 결과 record: `UserCouponResult`, `UserCouponView`, `ApplicableCouponView`, `AppliedDiscount(discountAmount, couponId)`, `CouponDefResult`. Entity 미노출.

**`CouponServiceResponse`** (@Service) — REST 응답 조합 전용(architecture-rule: REST에서만).
- `UserCouponResponse claim(Authentication auth, CouponClaimRequest req)` — `(long) auth.getPrincipal()` → `CouponService.claim` → DTO.
- `List<UserCouponResponse> getMyCoupons(Authentication auth)`.
- `List<ApplicableCouponResponse> getApplicable(Authentication auth)` — `CouponService.getApplicable(userId)` 위임.
- `AdminCouponResponse createDefinition(AdminCouponCreateRequest req)`.

> `GET /applicable`의 장바구니 itemsAmount 산정 책임은 **`CouponService` 내부**에 둔다 — order 모듈은 이미 `CartCheckoutReader`/`ProductOrderCatalog`를 의존하므로 신규 cross-module 의존이 0이다(모듈 경계상 단일안).

**`CouponDtoMapper`** (@Component, package-private) — 내부 결과 record → DTO 변환(OrderDtoMapper 선례).

### 2.4 컨트롤러 (order/controller)

**`CouponRestController`** (`@RestController @RequestMapping("/api/v1/coupons")`):
- `POST /api/v1/coupons` → 201, body `@Valid CouponClaimRequest` → `UserCouponResponse`.
- `GET /api/v1/coupons` → 200, `List<UserCouponResponse>`.
- `GET /api/v1/coupons/applicable` → 200, `List<ApplicableCouponResponse>`.
- 비즈니스 로직 없음 — `CouponServiceResponse` 위임.

**`AdminCouponRestController`** (`@RestController @RequestMapping("/api/v1/admin/coupons")`):
- `POST /api/v1/admin/coupons` → 201, body `@Valid AdminCouponCreateRequest` → `AdminCouponResponse`.
- 인가는 SecurityConfig `/api/v1/admin/**` `hasRole("ADMIN")`가 커버(AdminSellerApplicationRestController 선례 — 컨트롤러에 권한 분기 없음).

### 2.5 DTO (order/dto)
- `CouponClaimRequest(@NotBlank String code)`.
- `UserCouponResponse(Long userCouponId, Long couponId, String code, String name, String discountType, BigDecimal value, BigDecimal minOrderAmount, BigDecimal maxDiscount, Instant startsAt, Instant endsAt, boolean used, Instant usedAt, boolean expired)` — Entity 미노출.
- `ApplicableCouponResponse(Long userCouponId, Long couponId, String code, String name, boolean applicable, BigDecimal expectedDiscount, String reason)`.
- `AdminCouponCreateRequest(@NotBlank code, @NotBlank name, @NotNull discountType, @NotNull @Positive value, BigDecimal minOrderAmount, BigDecimal maxDiscount, @NotNull startsAt, @NotNull endsAt, Integer usageLimit, Boolean isActive)` — `discountType ∈ {fixed,percent}` 검증.
- `AdminCouponResponse(Long id, String code, String name, String discountType, BigDecimal value, BigDecimal minOrderAmount, BigDecimal maxDiscount, Instant startsAt, Instant endsAt, Integer usageLimit, int usedCount, boolean isActive)`.

### 2.6 예외 (common/exception) — 모두 `BusinessException` 상속
| 예외 | HTTP | 기본 메시지 |
|---|---|---|
| `CouponNotFoundException` | 404 | "쿠폰을 찾을 수 없습니다." |
| `CouponNotClaimableException` | 400 | "발급할 수 없는 쿠폰입니다." (+사유) |
| `CouponAlreadyOwnedException` | 409 | "이미 보유 중인 쿠폰입니다." |
| `CouponNotApplicableException` | 400 | 사유별 메시지(최소주문금액 미달/유효기간 외/비활성) |
| `CouponConflictException` | 409 | "쿠폰을 사용할 수 없습니다." (이미 사용/한도 소진) |
| `DuplicateCouponCodeException` | 409 | "이미 존재하는 쿠폰 코드입니다." |

### 2.7 수정 컴포넌트
- `Order.java`: §1.7 오버로드.
- `OrderService.createOrderTx`: §3.4 통합(`CouponService` 주입).
- `OrderCreateRequest`: `Long userCouponId` 6번째 필드(선택, 검증 어노테이션 없음).
- `OrderViewController`: `OrderCreateRequest` 생성부 6번째 인자 `null`.
- `OrderCancellationImpl.doCancel`: 재고 복원 직후 `couponService.restoreByOrder(orderId)` 1콜(§3.5).
- `SecurityConfig.restChain`: `/api/v1/cart/**` matcher 인접 위치에 `.requestMatchers("/api/v1/coupons/**").hasRole("CONSUMER")` 추가(anyRequest 앞, admin은 기존 `/api/v1/admin/**`가 선매칭).

---

## 3. 데이터 흐름

### 3.1 발급(claim) — `POST /api/v1/coupons`
1. JWT 필터 → SecurityConfig `/api/v1/coupons/**` `hasRole("CONSUMER")` 통과(비로그인 401, 비CONSUMER 403).
2. `CouponRestController.claim` → `CouponServiceResponse.claim(auth, req)` → `userId = (long) auth.getPrincipal()`.
3. `CouponService.claim(userId, code)`:
   - `couponRepository.findByCode(code)` → 없으면 `CouponNotFoundException`(404).
   - `coupon.isClaimable(now)` false → `CouponNotClaimableException`(400, 사유).
   - `userCouponRepository.save(UserCoupon.issue(userId, coupon.getId(), now))` → UNIQUE 위반 → `CouponAlreadyOwnedException`(409). **used_count 미증가**.
4. `UserCouponResponse` 201 반환.

### 3.2 조회 — `GET /api/v1/coupons`
1. 인가 통과 → `CouponServiceResponse.getMyCoupons(auth)`.
2. `CouponService.getMyCoupons(userId)`: `findByUserIdOrderByIssuedAtDesc` → couponId 집합으로 `couponRepository.findAllById` 배치 조회 → 각 행에 `used = usedAt != null`, `expired = now ≥ endsAt` 계산.
3. `List<UserCouponResponse>` 200. **타인 쿠폰은 userId 조건으로 원천 차단**(IDOR).

### 3.3 적용 미리보기 — `GET /api/v1/coupons/applicable`
1. 인가 통과 → `CouponServiceResponse.getApplicable(auth)`.
2. `CouponService.getApplicable(userId)`:
   - `cartCheckoutReader.getCheckoutCart(userId)` → 항목 variantIds → `productOrderCatalog.getOrderableSnapshots` → `itemsAmount = Σ price×qty`(createOrderTx와 동일 산식, 단 락 없음·읽기 전용).
   - 빈 장바구니면 `itemsAmount = 0`(모든 쿠폰 `applicable=false`, reason="장바구니가 비어 있습니다").
   - `findByUserIdAndUsedAtIsNull(userId)` → 각 보유 미사용 쿠폰 정의 조회 → 판정:
     - 비활성/유효기간 외/`!meetsMinOrder` → `applicable=false` + reason.
     - else → `applicable=true`, `expectedDiscount = coupon.calculateDiscount(itemsAmount)`.
3. `List<ApplicableCouponResponse>` 200. **상태 변경 없음**(@Transactional(readOnly=true)).

### 3.4 주문 적용 + 할인 계산 — `POST /api/v1/orders` (`userCouponId` 선택)
`OrderService.createOrderTx`(@Transactional, 기존 단계) 안에서:
1. 기존 1~5단계(장바구니/사전검증/락+재고차감/권위검증/`itemsAmount` 산정) **무변경**.
2. **(신규, itemsAmount 확정 직후, Order.create 전)** `request.userCouponId() != null`이면:
   - `userCoupon = userCouponRepository.findByIdAndUserId(userCouponId, userId)` → 없으면 `CouponNotFoundException`(404, 미보유/타인 존재 은닉).
   - `userCoupon.isUsed()` true → `CouponConflictException`(409, 이미 사용).
   - `coupon = couponRepository.findById(userCoupon.getCouponId())` → 비활성/유효기간 외 → `CouponNotApplicableException`(400) / `!meetsMinOrder(itemsAmount)` → `CouponNotApplicableException`(400, "최소 주문금액 미달").
   - `discountAmount = coupon.calculateDiscount(itemsAmount)`(§1.9).
   - else `discountAmount = ZERO`.
3. `Order.create`: discount>0이면 9-arg 오버로드(§1.7)로 `finalAmount = itemsAmount - discountAmount`; discount=0이면 기존 8-arg.
4. 기존 order/items 저장 → `savedOrder.getId()` 확보.
5. **(신규, order 저장 후)** discount 적용 시 **소비 조건부 UPDATE 2건**:
   - `markUsedIfUnused(userCouponId, userId, savedOrder.getId(), now)` → 영향행 0이면 동시 사용 경합 패자 → `CouponConflictException`(409) → **트랜잭션 롤백**(재고·주문 원복).
   - `incrementUsedCountIfWithinLimit(coupon.getId())` → 영향행 0이면 한도 소진/비활성 → `CouponConflictException`(409) → **롤백**.
6. 기존 `clearCart` → 커밋.
7. `userCouponId` 없으면 2/5단계 skip → 기존 흐름 완전 동일(회귀 0).

> 응답: `OrderResponse.discountAmount`/`finalAmount`는 이미 매핑됨(OrderDtoMapper). discount가 반영된 값이 그대로 노출된다.

### 3.5 취소·만료 복원 — `OrderCancellationImpl.doCancel`
1. 진입: 사용자 취소(`PaymentService.cancel` → `OrderCancellation.cancel`) 또는 만료(`PaymentService.expirePendingOrder` → `OrderCancellation.cancelByExpiry`) — **둘 다 `doCancel` 코어로 수렴**(코드 대조 확인).
2. 기존: status 분기(이미 종결 → 멱등 return / 이행단계 → REJECTED) → 종결 전이 → 재고 복원 → 이벤트 발행.
3. **(신규, 재고 복원 직후 / 이벤트 발행 전)** `couponService.restoreByOrder(orderId)`:
   - `findByOrderId(orderId)`로 사용된 user_coupon(있으면) couponId 확보.
   - `restoreByOrderId(orderId)`(user_coupon used_at/order_id NULL) + `decrementUsedCount(couponId)`(coupon used_count--).
   - **멱등**: 이미 복원되었거나 쿠폰 미적용 주문이면 영향행 0 → no-op. (status 분기에서 이미 종결이면 doCancel이 먼저 return하므로 이중 복원 없음 — 이중 방어로 조건부 UPDATE가 한 번 더 멱등 보장.)
4. PaymentService의 금액·PG refund 로직은 **무변경**(복원 hook은 doCancel 내부에만 삽입). 환불액 = `Payment.amount`(=할인 후 finalAmount) 불변.

---

## 4. 예외 처리 전략

error-response-rule 준수: 모든 예외는 `BusinessException` 상속 → `RestExceptionHandler`가 `ErrorResponse` JSON(status/error/message/path/timestamp)으로 단일 변환. Controller/Service에서 ErrorResponse 직접 조립 금지. 메시지에 내부 정보(SQL/스택/정확 수치) 비노출.

| 분기 | 경로 | 예외 | HTTP | 메시지(노출) |
|---|---|---|---|---|
| 비로그인 | 모든 `/api/v1/coupons/**` | (Security) RestAuthenticationEntryPoint | 401 | (공통 401 JSON) |
| 비CONSUMER가 coupons 접근 | `/api/v1/coupons/**` | (Security) RestAccessDeniedHandler | 403 | (공통 403 JSON) |
| CONSUMER가 admin 생성 시도 | `/api/v1/admin/coupons` | (Security) `/api/v1/admin/**` | 403 | (공통 403 JSON) |
| 발급: 코드 미존재 | claim | `CouponNotFoundException` | 404 | "쿠폰을 찾을 수 없습니다." |
| 발급: 비활성/유효기간 외 | claim | `CouponNotClaimableException` | 400 | "발급 기간이 아니거나 비활성 쿠폰입니다." |
| 발급: 1인 1매 중복 | claim | `CouponAlreadyOwnedException` | 409 | "이미 보유 중인 쿠폰입니다." |
| 적용: 미보유/타인 소유 user_coupon | createOrder | `CouponNotFoundException` | 404 | "쿠폰을 찾을 수 없습니다." (존재 은닉) |
| 적용: 이미 사용된 쿠폰 | createOrder | `CouponConflictException` | 409 | "이미 사용된 쿠폰입니다." |
| 적용: 비활성/유효기간 외 | createOrder | `CouponNotApplicableException` | 400 | "사용 기간이 아니거나 비활성 쿠폰입니다." |
| 적용: 최소주문금액 미달 | createOrder | `CouponNotApplicableException` | 400 | "최소 주문금액을 충족하지 않습니다." |
| 적용: 동시 사용 경합 패자(used_at) | createOrder | `CouponConflictException` | 409 | "쿠폰을 사용할 수 없습니다." (롤백) |
| 적용: 총 한도 소진(used_count) | createOrder | `CouponConflictException` | 409 | "쿠폰 사용 한도가 마감되었습니다." (롤백) |
| admin: 코드 중복 | createDefinition | `DuplicateCouponCodeException` | 409 | "이미 존재하는 쿠폰 코드입니다." |
| admin: value≤0 / endsAt≤startsAt / discountType 오류 | createDefinition | `@Valid` 실패→MethodArgumentNotValid 또는 `BusinessException` | 400 | 필드 메시지 |
| 미리보기: 적용 불가 쿠폰 | applicable | (예외 아님) | 200 | `applicable=false` + `reason` |
| 복원: 이미 복원/미적용 | doCancel | (예외 아님, 멱등) | — | no-op |

> 적용 단계 예외는 모두 `createOrderTx` 트랜잭션 안에서 발생 → **주문·재고·쿠폰 소비 전체 롤백**. 401/403은 Security 필터가 컨트롤러 도달 전 처리(기존 RestAuthenticationEntryPoint/RestAccessDeniedHandler 재사용).

---

## 5. 검증 방법

> verification-gate-rule: reviewer PASS(정적) ≠ 빌드 그린. 메인이 `./gradlew test` 전체 그린을 별도 확인. **신규 Repository 빈(`CouponRepository`/`UserCouponRepository`)·`CouponService`가 추가되므로, `OrderService`/`OrderCancellationImpl`를 협력자로 쓰는 단위 테스트는 신규 의존을 `@Mock`/`@MockitoBean`으로 스텁해야 컨텍스트·생성자가 깨지지 않는다(verification-gate-rule §4). 구현자는 이 파급(기존 테스트 갱신)을 책임 범위로 본다.**

### 5.1 단위 (JUnit5 + Mockito)
- **`CouponDiscountTest`**(Coupon.calculateDiscount): fixed(value < itemsAmount → value), fixed(value > itemsAmount → itemsAmount), percent(floor 검증 — 예: 33% of 1000 = 330.00, 절사), percent + max_discount 상한 적용, percent max_discount null → 상한 없음, discount ≤ itemsAmount 보장(percent 100% 초과 방지), `setScale(2)` 정규화.
- **`CouponClaimableTest`**: isClaimable 경계(startsAt 포함/endsAt 배타/비활성 false).
- **`CouponServiceClaimTest`**: 신규 발급 성공, 코드 미존재 → 404, 비활성/기간외 → 400, UNIQUE 위반(DataIntegrityViolation mock) → 409.
- **`CouponServiceApplyTest`**: 미사용/이미사용/유효기간/비활성/최소주문금액/소유권 위반 각 분기, 경합 패자(markUsedIfUnused=0 → 409, increment=0 → 409). `computeDiscount`가 올바른 discountAmount 산정.
- **`OrderCreateDiscountTest`**(Order 도메인): 9-arg 오버로드가 `finalAmount = itemsAmount - discount` 산정, 8-arg 오버로드가 discount=ZERO 위임(기존 테스트 그린), discount > itemsAmount 방어(IllegalStateException).
- **`OrderServiceCouponTest`**: createOrderTx에서 userCouponId 있음/없음 분기(Mockito로 CouponService stub) — 없으면 CouponService 미호출(회귀), 있으면 computeDiscount→Order 9-arg→consume 순서.

### 5.2 통합 (@DataJpaTest / @SpringBootTest + Testcontainers PostgreSQL)
- **`UserCouponUniqueIntegrationTest`**: 같은 (user_id, coupon_id) 2회 INSERT → 2번째 DataIntegrityViolation(1인 1매).
- **`CouponConsumeIntegrationTest`**: 주문 생성 시 markUsedIfUnused → used_at/order_id 기록, incrementUsedCountIfWithinLimit → used_count++. 복원 → used_at/order_id NULL·used_count--, **멱등 재호출 무영향**.
- **`CouponConcurrencyIntegrationTest`**: 동시 주문 2건이 같은 user_coupon 적용 → markUsedIfUnused 조건부 UPDATE로 **1건만 성공**, 패자 409·롤백. usage_limit=N 한도에서 동시 N+1건 사용 → incrementUsedCountIfWithinLimit로 **N건만 성공**(used_count ≤ usage_limit 단언). (OrderCreationConcurrencyIntegrationTest 선례 패턴 — ExecutorService/CountDownLatch.)
- **`CouponRestoreOnCancelIntegrationTest`**: 쿠폰 적용 주문 취소(018)/만료(022) → restoreByOrder로 복원(used_at NULL, used_count 감소), 멱등.

### 5.3 Security/REST (MockMvc)
- **`CouponRestControllerSecurityTest`**: `/api/v1/coupons/**` 비로그인 401, CONSUMER 200/201, (역할 계층) SELLER/ADMIN 통과. admin `POST /api/v1/admin/coupons`: ADMIN 201, CONSUMER 403, 비로그인 401. (OrderRestControllerSecurityTest/AdminSellerApplicationRestControllerSecurityTest 선례.)
- 주문 생성에 본인 미보유/이미사용 `userCouponId` → 404/409. 타 회원 user_coupon id → 404(존재 은닉).

### 5.4 금액 전파 통합
- **`CouponOrderPaymentPropagationIntegrationTest`**: 쿠폰 적용 주문의 `Payment.amount == Order.finalAmount`(할인 반영). **취소 시 환불액 == `Payment.amount`(할인 후 실 결제액)이며 `itemsAmount`(판매가)와 다름을 명시 단언**(discount > 0 케이스로 환불액 < itemsAmount → 판매가 환불 회귀 차단). `OrderCompletedEvent.totalAmount`가 할인 반영 long 값.

### 5.5 회귀 (verification-gate)
- 쿠폰 미적용 주문 생성·결제·취소·만료(015/016/017/018/022) 전 스위트 그린 유지. `Order.create` 8-arg 위임으로 기존 `Order*Test` 무변경 통과.
- 신규 의존 추가에 따른 기존 단위/풀컨텍스트 테스트 컨텍스트 로드 회귀 점검 — 필요한 기존 테스트에 `@Mock`/`@MockitoBean CouponService`(또는 Repository) 추가.
- `OrderModuleStructureTest`(ArchUnit) 규칙 1~13 그린(신규 cross-module 의존 0).
- 메인 에이전트가 `./gradlew test` 전체 `BUILD SUCCESSFUL` 자기 눈으로 확인. 동시성 통합은 flaky 가능(memory: OrderCancellationConcurrency flaky 선례) — 단일 실패는 재실행으로 판별, 회귀 오인 금지.

---

## 6. 트레이드오프

| 결정 | 채택안 | 대안 | 비용/이득 |
|---|---|---|---|
| 모듈 배치 | order 모듈 내부 | 신규 coupon 모듈 | 채택: 트랜잭션 경계·order_id FK 응집, ArchUnit/Modulith 무변경. 대안: 독립 라이프사이클이나 6모듈 고정 위반·spi 보일러플레이트·강결합 비용 과다. |
| 소비 시점 | 주문 생성 시(createOrderTx) | 결제 확정(paid) 시 | 채택: 재고와 라이프사이클 일치(생성 차감/취소·만료 복원), 복원 hook 1개로 통일. 대안: pending 만료 시 쿠폰만 별도 복원 로직 필요 → 경로 분기 증가. |
| used_count 증가 시점 | 사용 시 | 발급 시 | 채택: 발급은 한도 미소진(쿠폰함만 채움) → 실수요 반영. 대안: 발급 폭주가 한도를 조기 소진. |
| 동시성 | 조건부 UPDATE + UNIQUE | 비관락(재고 선례) | 채택: §6이 직접 규정, 단순 카운터엔 락 경합·데드락 위험 낮음. 대안: 비관락은 SELECT FOR UPDATE 추가 라운드트립·락 순서 관리 필요. |
| Order.create 변경 | 오버로드(8-arg 위임) | 시그니처 교체 | 채택: 기존 호출부·테스트 회귀 0(가산만). 대안: 전 픽스처 일괄 수정 → diff 폭증·회귀 위험(verification-gate §4). |
| userCouponId 전달 | OrderCreateRequest 필드 | placeOrder/ServiceResponse 시그니처 인자 | 채택: 변경 표면 최소(시그니처 무변경), 재시도 루프 안전. 대안: 시그니처 다수 변경·View 경로 파급. |
| applicable 미달 처리 | 200 + applicable=false/reason | 거부(에러) | 채택: 미리보기는 읽기 전용 — 적용 가능/불가를 한 응답에 표기해 UX 명확. 적용 단계에서만 거부(400/409). |
| 미사용 인덱스 | V1 기존 부분 인덱스 재사용 | V7 신규 | 채택: V1에 이미 존재(line 382) → 스키마 무변경. 대안: 중복 인덱스 생성. |

---

## 완료 조건
- [ ] 유효 코드 발급 시 user_coupons 행 생성, 재발급 거부(1인 1매 409).
- [ ] 쿠폰함 조회가 본인 쿠폰을 미사용/사용/만료 표기로 반환, 타인 쿠폰 비노출.
- [ ] 미리보기가 장바구니 기준 적용 가능 쿠폰+예상 할인액 반환, 불가 쿠폰 사유 표기.
- [ ] 주문 생성 시 쿠폰 적용 → discountAmount/finalAmount 정확(음수 불가), 결제·환불이 할인된 finalAmount 추종(결제/환불 코드 무변경).
- [ ] 1회용·총 한도 동시성 안전(조건부 UPDATE 경합 패자 거부·롤백).
- [ ] 취소(018)/만료(022) 시 쿠폰 복원(멱등).
- [ ] 유효기간 외·비활성·최소주문금액 미달 적용 거부(400)·주문 롤백.
- [ ] V1 스키마·기존 이벤트·notification·결제/환불 무변경, 쿠폰 미적용 주문 회귀 0.
- [ ] `./gradlew test` 풀 그린(메인 확인) + ArchUnit/Modulith 그린.

# 016. shop-core 모의 결제 승인 + 주문 확정 + OrderCompletedEvent 발행

## Target
shop-core

---

## Goal
`shop-core`에서 로그인한 사용자가 자기 `pending` 주문을 모의 PG로 결제하고, **승인 시** 주문을 `paid`로 확정하면서 `OrderCompletedEvent`를 Transactional Outbox로 발행하도록 구현한다. 결제 결과는 `payments` row 스냅샷으로 저장하고, 주문 상세 화면과 REST API에서 결제 상태를 조회할 수 있게 한다.

> 이 Task는 **결제 승인(happy path)**만 다룬다. 결제 거절 처리와 `PaymentFailedEvent` 발행은 후속 `017`에서 구현한다.

---

## Context
- `015`에서 장바구니 기반 주문 생성을 구현했다. 주문은 `pending` 상태로 생성되고 재고는 주문 생성 트랜잭션에서 이미 차감된다
- `015`는 결제 승인·결제 실패·`OrderCompletedEvent`·`PaymentFailedEvent`를 후속 Task로 명시적으로 미뤘다(`015` task line 19~21, 149~152)
- 결제 흐름은 두 Task로 분리한다
  - **`016`(이 Task)**: 모의 결제 승인 + 주문 확정 + `OrderCompletedEvent`
  - **`017`**: 결제 거절 처리 + `PaymentFailedEvent`
- `payments` 스키마는 V1에 이미 존재한다(`uq_payments_order_id`로 주문당 결제 1건)
  - `method`: `card`/`bank_transfer`/`virtual_account`/`mock`
  - `status`: `ready`/`paid`/`failed`/`cancelled`/`refunded`
  - `amount`, `pg_transaction_id`, `paid_at`, `created_at`, `updated_at`
- `orders.status` CHECK는 `pending`/`paid`/... 를 허용한다. 이 Task는 `pending` → `paid` 전이만 다룬다
- `OrderCompletedEvent`(topic `order-completed`) 페이로드 스키마는 `docs/event-catalog.md`에 이미 정의되어 있다. **이 Task에서 이벤트 계약을 추가·변경하지 않는다**
- 이벤트 발행은 `004`에서 구성한 Spring Modulith Event Publication Registry(Transactional Outbox) + `@Externalized` Kafka 외부화 경로를 사용한다
- 패키지 구조 규칙(`package-structure-rule`)상 **`OrderCompletedEvent`는 `order` 모듈이 발행 소유**한다
- 결제 처리(모의 PG 호출·`payments` 기록)는 `payment` 모듈 책임이다. 주문 확정(`pending`→`paid` 전이·`OrderCompletedEvent` 발행)은 `order` 모듈 책임이다. payment는 order published port로 주문 확정을 위임한다
- 실제 PG 연동은 하지 않는다. 교체 가능한 `PaymentGatewayPort`(모의 구현)를 두고, 이후 실 PG 어댑터로 교체할 수 있게 한다(static asset의 ObjectStorage 추상화와 동일한 철학)
  - 이 Task의 모의 구현은 **항상 승인**한다. 거절 분기는 `017`에서 추가한다. 단, 포트 시그니처는 승인/거절을 모두 표현할 수 있게 설계해 `017`에서 인터페이스를 바꾸지 않도록 한다
- 결제는 자기 주문만 가능하다. View 흐름(form-login)은 principal=email, REST 흐름(JWT)은 principal=userId(long)로 경로가 다르다. payment/order facade는 `member.spi.MemberDirectory`로 email→userId 변환을 수행한다
- 이벤트 페이로드는 자족적이어야 한다(`event-contract-rule`). 알림 수신자 정보(`memberEmail`, `memberName`)는 `member.spi`로, 항목별 `productId`는 `product.spi`로 조회해 페이로드에 채운다. notification이 shop-core를 역조회하지 않는다
- API 추가 시 `docs/rules/api-authorization-rule.md`를 따른다

## API Authorization

| API | 공개 여부 | 최소 권한 | 상위 권한 허용 | 소유권 검사 | 비고 |
|---|---|---|---|---|---|
| `POST /api/v1/orders/{orderId}/payment` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 자기 주문 모의 결제 요청(승인 경로) |
| `GET /api/v1/orders/{orderId}/payment` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 자기 주문 결제 상태 조회 |
| `POST /orders/{orderId}/payment` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 주문 상세 화면 결제 폼 제출 |

- 결제 실패/환불 관리(ADMIN)는 이 Task 범위 밖이다(`api-authorization-rule` payment 도메인 기준)
- 다른 사용자의 주문에 대한 결제 요청·조회는 404 존재 은닉으로 통일한다(`015`의 주문 상세 접근 정책과 동일)

## Requirements
- `Payment` Entity/Repository/Service를 `payment` 모듈에 구현한다
  - `orderId` 스칼라(order Entity 직접 참조 금지)
  - `method`(이 Task 기본값 `mock`)
  - `status`(이 Task에서는 `ready`/`paid` — `failed`는 `017`에서)
  - `amount`(주문 `finalAmount`와 일치해야 한다)
  - `pgTransactionId`(승인 시 모의 PG 거래번호)
  - `paidAt`(승인 시각)
  - `createdAt`, `updatedAt`(DB 트리거 소유 → BaseEntity 읽기전용 매핑)
  - Setter 금지. 정적 팩토리 + 의도 메서드(`markPaid`)로 상태를 전이한다(`markFailed`는 `017`)
- 결제 요청은 현재 로그인 사용자의 자기 주문 1건을 대상으로 한다
- 결제 처리 단계 순서를 고정한다(원자성 + 멱등성 + 실 PG 전환 안전성)
  1. 결제 준비용 주문 스냅샷을 order published port(`OrderPaymentReader`)로 조회한다(락 없음)
     - 입력 `requesterUserId`로 소유권을 검증한다(자기 주문이 아니면 404 존재 은닉). payment는 order repository/domain을 직접 조회하지 않는다
     - 반환 스냅샷: `orderId`, `orderNumber`, `userId`(=memberId), `status`, `finalAmount`, `currency`
     - 이 단계에서 **이벤트 발행 완결성을 사전 검증**한다: 주문 전 항목의 `productId` 해석(`product.spi`)과 member 연락처(`member.spi` email/name)가 모두 가능해야 한다. 하나라도 해석 불가(예: variant 삭제로 `productId` 없음)면 **PG 호출 전에 `409`로 실패**한다(P2 정책 — 아래 "items[].productId 해석 정책")
  2. 주문 status로 멱등/충돌을 판정한다
     - 이미 `paid`이고 `payments`가 `paid`면 **재발행 없이** 기존 결제 결과를 그대로 반환한다(멱등)
     - `pending`이 아닌 그 외 상태 전이는 `409` 상태 충돌로 응답한다
  3. 금액을 검증한다: 클라이언트가 금액을 전달했다면 스냅샷 `finalAmount`와 일치해야 한다(불일치 `400`)
  4. 모의 PG(`PaymentGatewayPort`)에 승인 요청한다(주문번호·금액·통화 전달) — 이 Task에서는 항상 승인
     - **이 단계 이후로는 이벤트 페이로드 구성에 필요한 외부 조회가 남아 있지 않다**(1단계에서 완결성을 보장). 실 PG 전환 시 "승인 후 주문 확정 실패"를 원천 차단한다
  5. `payments`를 `paid`로 기록한다(`pgTransactionId`, `paidAt`)
  6. order published port(`OrderConfirmation.confirmPaid(orderId, requesterUserId, paidAmount)`)로 주문 확정을 위임한다
     - confirmPaid는 **대상 주문 row를 `@Lock(PESSIMISTIC_WRITE)`로 잠그고** 소유권·`status==pending`·금액(`finalAmount==paidAmount`)을 **권위 재검증**한 뒤 `pending`→`paid`로 전이하고 `OrderCompletedEvent`를 발행한다
     - 락 후 재검증 결과를 confirmPaid 내부에서 일관 처리한다(이미 `paid` → 재발행 없이 멱등 결과 반환 / 상태 변경 충돌 → `409` 후 전체 롤백)
     - 주문 row 락은 order 모듈이 소유한다. payment는 order row를 직접 잠그지 않는다
  7. 커밋
- 결제는 주문당 1건이다(`uq_payments_order_id`)
  - 동일 주문에 대한 동시 결제 요청은 confirmPaid의 주문 row 비관적 락(6단계)으로 직렬화된다. 둘 중 하나만 `pending`→`paid` 전이에 성공하고 나머지는 락 후 재검증에서 멱등 반환 또는 `409`로 처리된다
  - `payments` 더블 생성은 `uq_payments_order_id`가, 더블 확정·이벤트 재발행은 락 후 status 재검증이 막는다
  - 이미 `paid`인 주문에 대한 재요청은 더블 결제·이벤트 재발행을 하지 않는다(멱등)
- 결제 금액은 서버 권위 값으로 검증한다
  - 클라이언트가 보낸 금액을 신뢰하지 않는다. `payments.amount`는 주문 `finalAmount`로 채운다
  - 클라이언트가 금액을 전달하고 주문 `finalAmount`와 다르면 `400`(입력 검증 실패)로 응답한다(전달하지 않는 설계도 허용)
- `order.spi`에 결제용 published port **2개**를 추가한다(payment가 order 내부를 직접 참조하지 않도록 — `architecture-rule` 모듈 경계)
  - **읽기/준비 포트** `OrderPaymentReader`
    - `OrderPaymentView getPayableOrder(long orderId, long requesterUserId)`
    - 소유권 검증(타 사용자 주문은 404 존재 은닉), 스칼라 DTO 반환(`orderId`, `orderNumber`, `userId`, `status`, `finalAmount`, `currency`). order/member/product Entity 노출 금지
    - 이벤트 발행 완결성(전 항목 `productId` 해석 가능 + member 연락처 존재)을 사전 검증해 불가 시 `409`
    - 락을 잡지 않는다(준비/멱등 판정용 읽기)
  - **확정 포트** `OrderConfirmation`
    - `OrderConfirmationResult confirmPaid(long orderId, long requesterUserId, BigDecimal paidAmount)`
    - 주문 row를 `@Lock(PESSIMISTIC_WRITE)`로 잠그고 소유권·`status==pending`·금액 일치를 권위 재검증한 뒤 `pending`→`paid` 전이 + `OrderCompletedEvent` 발행
    - 이미 `paid`면 재발행 없이 멱등 결과를 반환, 그 외 충돌은 `409`
- 주문 확정(`pending`→`paid`)과 `OrderCompletedEvent` 발행은 `order` 모듈이 소유한다
  - 두 포트 구현 모두 `order` 내부 `service`에 두고, 주문 상태를 `paid`로 전이한 뒤 `OrderCompletedEvent`를 `ApplicationEventPublisher`로 발행한다(같은 트랜잭션 = Outbox 저장)
  - 페이로드는 `docs/event-catalog.md`의 `OrderCompletedEvent` 스키마를 그대로 따른다
    - `orderId`, `orderNumber`, `memberId`(=주문 `userId`), `memberEmail`, `memberName`, `items[]`(`productId`, `productName`, `quantity`, `unitPrice`), `totalAmount`(=주문 `finalAmount`), `currency`(`KRW`), `orderedAt`(확정 시각), 공통 봉투(`eventId`, `occurredAt`)
    - `productName`/`quantity`/`unitPrice`는 주문 시점 스냅샷(`order_items`)에서 가져온다
    - `memberEmail`/`memberName`은 `member.spi`로 `userId`→연락처를 조회해 채운다
  - `OrderCompletedEvent`는 `order/event`에 `@Externalized("order-completed")`로 정의한다
- **items[].productId 해석 정책(P2 고정)**
  - `OrderCompletedEvent.items[].productId`는 이벤트 계약상 **필수**다(`docs/event-catalog.md` line 32). `order_items`에는 `productId` 스냅샷이 없으므로 `product.spi`로 `variantId`→`productId`를 해석해 채운다
  - **PG 승인 호출(4단계) 이전(1단계)에** 주문 전 항목의 `productId` 해석을 완료한다. 해석 불가(variant 삭제로 `variantId` null 또는 매핑 없음)면 **PG 호출 전에 `409`(상태 충돌)로 실패**한다
  - 즉 "결제 승인 후 주문 확정 단계에서 `productId` 누락으로 실패"하는 흐름을 만들지 않는다(실 PG 전환 시 결제만 승인되고 주문은 확정 못 하는 위험 차단). fallback(임의 productId 추정/생략)은 두지 않는다 — 해석 불가는 명확히 `409`로 거절한다
- **금액 타입 변환 규칙(P3 고정, numeric(12,2) → long)**
  - DB `orders.final_amount`/`payments.amount`는 `numeric(12,2)`(BigDecimal)이고, `OrderCompletedEvent.totalAmount`/`items[].unitPrice`는 `long`이다(`event-catalog` line 32 — KRW 최소 단위=원)
  - KRW는 소수 단위가 없으므로 금액 BigDecimal의 소수부는 0이어야 한다(`.00`만 허용)
  - 변환은 `BigDecimal.longValueExact()`로 수행한다. 소수부가 있거나 long 범위를 벗어나면 시스템 불변식 위반으로 보고 도메인 예외로 변환해 명확히 실패한다(`ArithmeticException` → `BusinessException`, 정상 사용자 입력 오류가 아니므로 `400` 아님)
  - `Payment.amount`는 BigDecimal로 보유하고, 이벤트 페이로드 직렬화 시점에만 long으로 변환한다(저장 정밀도와 계약 타입을 분리)
- 주문 상태 전이 메서드를 `Order` Entity에 추가한다(예: `markPaid()`), `pending`이 아닐 때 전이 시도는 도메인 예외로 막는다
- `member.spi.MemberDirectory`(또는 신규 member published port)에 `userId`→연락처(`email`, `name`) 조회를 추가한다
  - 기존 `findUserIdByEmail`는 유지한다
  - 이벤트 페이로드 구성에 사용한다. member Entity를 노출하지 않고 scalar/DTO만 반환한다
- `product.spi`에 `variantId`→`productId` 조회 수단을 제공한다(기존 `ProductOrderCatalog` 재사용 또는 경량 메서드 추가). product Entity를 노출하지 않는다
- `PaymentGatewayPort`(모의 PG)를 둔다
  - 입력: 주문번호, 금액, 통화, method
  - 출력: 승인 결과 + `pgTransactionId`. 거절 표현(failureCode/failureReason)도 시그니처에 포함하되 이 Task의 모의 구현은 항상 승인을 반환한다(`017`에서 거절 분기 활성)
  - 실 PG 교체가 가능하도록 인터페이스를 `payment` 모듈 안에 두고, 모의 구현을 분리한다
  - 락 구간(주문/결제 row 락 보유) 안에서 외부 I/O를 최소화한다. 모의 PG는 in-process이므로 외부 호출은 없으나, 실 PG 교체 시 락 보유 구간 밖에서 호출하도록 단계 경계를 주석으로 명시한다
- REST Controller는 `RestController -> ServiceResponse -> Service -> Repository` 레이어를 따른다
- ViewController는 `web` 모듈(`web/order` 또는 `web/payment`)에 두고 `ViewController(@Controller) -> spi facade -> Service -> Repository` 레이어를 따른다
- `SecurityConfig`에 결제 경로 최소 권한을 명시적으로 추가한다
  - REST 체인(`/api/v1/**`): `/api/v1/orders/*/payment` `hasRole("CONSUMER")`
  - View 체인: `/orders/*/payment` `hasRole("CONSUMER")`
  - `015`에서 이미 `/api/v1/orders/**`, `/orders/**`가 `hasRole("CONSUMER")`로 덮여 있다면, 결제 하위 경로가 같은 정책에 포함되는지 확인하고 누락 시 명시적으로 추가한다
- Entity를 API 응답이나 View 모델에 직접 전달하지 않는다
- 관련 단위 테스트, 통합(Outbox 발행) 테스트, REST/Security 테스트, View 렌더링 테스트, 구조 테스트를 작성한다

## Constraints
- 이번 Task에서 **결제 거절 처리·`PaymentFailedEvent` 발행·`payments failed` 기록**을 구현하지 않는다(`017`에서 구현). 모의 PG는 항상 승인한다
- 이번 Task에서 결제 취소·환불·부분환불을 구현하지 않는다
- 이번 Task에서 배송 시작/배송 완료/주문 취소를 구현하지 않으며 `ShippingStartedEvent`를 발행하지 않는다
- 이번 Task에서 실제 PG 연동을 하지 않는다(모의 PG만)
- 이번 Task에서 Kafka 이벤트 계약(`docs/event-catalog.md`, `docs/architecture.md` 섹션 5)을 변경하지 않는다. 기존 `OrderCompletedEvent` 스키마를 그대로 사용한다
- 이번 Task에서 쿠폰·포인트·프로모션·배송비 계산을 구현하지 않는다(`discountAmount=0`, `shippingFee=0` 유지)
- 기존 migration을 수정하지 않는다. `payments` 스키마가 충분하면 신규 migration을 추가하지 않는다
- 결제 처리/`payments` 기록/주문 확정/이벤트 발행은 하나의 트랜잭션에서 처리한다. 실패 시 부분 반영이 없어야 한다
- 멱등성: 같은 주문에 결제가 이미 `paid`면 더블 결제·`OrderCompletedEvent` 재발행을 하지 않는다
- Controller에서 비즈니스 로직을 작성하지 않는다
- DTO와 Entity를 분리한다
- `payment` 모듈은 order/member/product 내부 `domain`, `repository`, 비공개 `service` 패키지를 직접 참조하지 않고 published API 또는 scalar만 사용한다
- `order` 모듈은 member/product published API 또는 scalar만 사용한다
- `notification` 코드나 DB를 참조하지 않는다

## Files
- `shop-core/src/main/java/com/shop/shop/payment/controller/**`
- `shop-core/src/main/java/com/shop/shop/payment/service/**`
- `shop-core/src/main/java/com/shop/shop/payment/repository/**`
- `shop-core/src/main/java/com/shop/shop/payment/domain/**`
- `shop-core/src/main/java/com/shop/shop/payment/dto/**`
- `shop-core/src/main/java/com/shop/shop/payment/spi/**`
- `shop-core/src/main/java/com/shop/shop/order/spi/**`
- `shop-core/src/main/java/com/shop/shop/order/service/**`
- `shop-core/src/main/java/com/shop/shop/order/domain/**`
- `shop-core/src/main/java/com/shop/shop/order/event/**`
- `shop-core/src/main/java/com/shop/shop/member/spi/**`
- `shop-core/src/main/java/com/shop/shop/member/service/**`
- `shop-core/src/main/java/com/shop/shop/member/adapter/**`
- `shop-core/src/main/java/com/shop/shop/product/spi/**`
- `shop-core/src/main/java/com/shop/shop/product/service/**`
- `shop-core/src/main/java/com/shop/shop/common/exception/**`
- `shop-core/src/main/java/com/shop/shop/security/**`
- `shop-core/src/main/java/com/shop/shop/web/order/**`
- `shop-core/src/main/java/com/shop/shop/web/payment/**`
- `shop-core/src/main/resources/templates/order/detail.html`
- `shop-core/src/main/resources/templates/payment/**`
- `shop-core/src/test/java/com/shop/shop/payment/**`
- `shop-core/src/test/java/com/shop/shop/order/**`
- `shop-core/src/test/java/com/shop/shop/web/**`
- `shop-core/src/test/java/com/shop/shop/view/**`
- `shop-core/src/test/java/com/shop/shop/security/**`

## Module Boundary Contract

| 항목 | 위치 | 규칙 |
|---|---|---|
| Payment REST Controller | `payment/controller` | `/api/v1/orders/{orderId}/payment`, `ServiceResponse` 사용 |
| Payment ViewController | `web/payment` 또는 `web/order` | Thymeleaf SSR, spi facade만 의존 |
| Payment Service | `payment/service` | 모의 PG 호출·`payments` 기록, order 확정 위임 |
| Payment Entity | `payment/domain` | `orderId` scalar 사용, order Entity 직접 참조 금지 |
| Payment gateway port | `payment/spi` | `PaymentGatewayPort`(모의 PG 추상화), 실 PG 교체 가능 |
| Order payment read port | `order/spi` | `OrderPaymentReader` — payment가 호출하는 결제 준비용 주문 스냅샷 조회(소유권·status·finalAmount·currency + 이벤트 완결성 사전검증, 불가 시 409). 락 없음 |
| Order confirmation port | `order/spi` | `OrderConfirmation.confirmPaid` — 주문 row 비관적 락 + 소유권·status·금액 권위 재검증 + `pending`→`paid` 확정 + `OrderCompletedEvent` 발행 |
| Order confirmation impl | `order/service` | 두 포트 구현, 주문 상태 전이, member/product spi로 페이로드 구성, Outbox 발행. payment는 order domain/repository 직접 참조 금지 |
| OrderCompletedEvent | `order/event` | `order` 모듈 발행 소유, `@Externalized("order-completed")` |
| Member contact port | `member/spi` | `userId`→`email`/`name` 조회(이벤트 페이로드용), Entity 노출 금지 |
| Product id resolver | `product/spi` | `variantId`→`productId` 조회, Entity 노출 금지 |
| View model/Form/DTO | `payment/dto` 또는 `web/**` | Entity 직접 노출 금지 |

## Backend - View Contract

| 항목 | 값 |
|---|---|
| 결제 폼 위치 | 주문 상세 화면(`order/detail`)의 `pending` 주문 결제 영역 |
| 결제 폼 action | `POST /orders/{orderId}/payment` |
| 결제 성공 리다이렉트 | `/orders/{orderId}` (결제 완료 상태 + flash success) |
| 결제 상태 표시 | 주문 상세에 결제 status(`결제 대기`/`결제 완료`)와 금액 표시 |
| 결제하기 버튼 노출 조건 | 주문 status가 `pending`이고 결제가 `paid`가 아닐 때 |

> 결제 실패 화면 처리(flashError)는 `017`에서 추가한다.

## API Response Contract

권장 DTO:

- `PaymentRequest`
  - `method`(선택, 기본 `mock`)
  - `amount`(선택 — 전달 시 주문 `finalAmount`와 일치 검증)
- `PaymentResponse`
  - `paymentId`
  - `orderId`
  - `orderNumber`
  - `status`(`paid`/`ready`, lowercase)
  - `method`
  - `amount`
  - `pgTransactionId`(승인 시)
  - `paidAt`(승인 시)

주의:

- `ownerId`, member/order/product/variant Entity, 로컬 파일 경로는 응답에 포함하지 않는다
- `status`는 DB 값과 정렬해 lowercase 문자열로 응답한다
- 멱등 재요청(이미 `paid`)은 기존 결제 결과를 `200`으로 반환한다

## Acceptance Criteria
- 비인증 사용자의 결제 REST 요청은 401 JSON을 반환한다
- ROLE 없는 인증 토큰의 결제 REST 요청은 403 JSON을 반환한다
- `CONSUMER`는 자기 `pending` 주문을 결제할 수 있고, `SELLER`/`ADMIN`도 권한 계층에 따라 자기 주문을 결제할 수 있다
- 다른 사용자의 주문에 대한 결제 요청·조회는 404(존재 은닉)로 실패한다
- 모의 PG 승인 시 `payments`에 `paid` row(금액=주문 `finalAmount`, `pgTransactionId`, `paidAt`)가 저장된다
- 모의 PG 승인 시 주문 status가 `pending`→`paid`로 전이된다
- 모의 PG 승인 시 `OrderCompletedEvent`가 같은 트랜잭션의 Outbox(`event_publication`)에 저장되고, 페이로드가 `event-catalog`의 `OrderCompletedEvent` 스키마(`memberEmail`/`memberName`/`items[].productId` 포함)를 만족한다
- 이미 `paid`인 주문에 대한 결제 재요청은 더블 결제·`OrderCompletedEvent` 재발행을 하지 않고 기존 결과를 멱등 반환한다
- 동일 주문에 대한 동시 결제 요청 중 하나만 확정하고 나머지는 멱등/충돌로 처리되어 `payments` row가 1건을 유지한다
- 클라이언트 전달 금액이 주문 `finalAmount`와 다르면 400으로 실패한다
- 주문 항목의 `productId`를 해석할 수 없으면(variant 삭제 등) **PG 승인 호출 전에** 409로 실패하고, `payments` row·이벤트가 생성되지 않는다(P2)
- payment 모듈은 order 스냅샷·주문 확정을 `order.spi`의 `OrderPaymentReader`/`OrderConfirmation`으로만 수행하고 `order.domain`/`order.repository`를 직접 참조하지 않는다(P1)
- 주문 row 락은 `OrderConfirmation.confirmPaid`(order 모듈) 안에서 획득되며 payment는 order row를 직접 잠그지 않는다(P1)
- 금액은 `numeric(12,2)` BigDecimal로 저장되고 이벤트 직렬화 시 `longValueExact()`로 long 변환되며, 소수부가 0이 아니면 도메인 예외로 실패한다(P3)
- 결제 처리 실패(시스템 오류) 시 `payments`·주문 상태·이벤트가 부분 반영되지 않는다
- 사용자는 자기 주문 상세에서 결제 상태를 조회할 수 있다
- 주문 상세 화면에서 `pending` 주문은 결제 폼(CSRF 포함)이 노출되고, 결제 성공 시 `/orders/{orderId}`로 redirect되며 결제 완료 상태가 표시된다
- `SecurityConfig`에서 결제 경로(REST `/api/v1/orders/*/payment`, View `/orders/*/payment`)에 최소 권한 `ROLE_CONSUMER`가 명시적으로 적용된다
- `payment` 모듈은 order/member/product 내부 구현을 직접 참조하지 않고 published API 또는 scalar만 사용한다
- `OrderCompletedEvent`는 `order` 모듈이 발행한다
- `docs/event-catalog.md`와 `docs/architecture.md` 섹션 5(이벤트 계약)는 무변경이다
- `ModularityTests.verify()`를 포함한 관련 테스트가 통과한다

## Test
- `./gradlew test`
- 권장 단위 테스트(payment)
  - 모의 PG 승인 시 결제 `paid` 기록 + order 확정 port 호출
  - 이미 `paid`인 주문 재요청 시 멱등 반환(더블 결제·이벤트 재발행 없음)
  - `pending`이 아닌(비정상) 주문 결제 시 409
  - 다른 사용자 주문 결제 시 404 존재 은닉
  - 클라이언트 금액 불일치 시 400
- 권장 단위 테스트(order 확정/준비)
  - `OrderPaymentReader.getPayableOrder`가 자기 주문 스냅샷(scalar) 반환, 타 사용자 주문 404 존재 은닉
  - `OrderPaymentReader`가 `productId` 해석 불가 주문에 대해 `409`(PG 호출 전 사전검증)
  - `OrderConfirmation.confirmPaid`가 주문을 `pending`→`paid`로 전이, 금액 불일치 시 `409`
  - `pending`이 아닌 주문 확정 시 멱등 반환(이미 paid) 또는 `409`(기타 상태)
  - `OrderCompletedEvent` 페이로드 필드 매핑(memberEmail/memberName/items[].productId/totalAmount/currency) 검증
  - `Order.markPaid()`가 `pending`에서만 허용됨
  - 금액 변환: `.00` BigDecimal은 `longValueExact()`로 변환 성공, 소수부가 있으면 도메인 예외(P3)
- 권장 SPI 테스트
  - `member.spi` `userId`→`email`/`name` 조회가 Entity 노출 없이 scalar/DTO 반환
  - `product.spi` `variantId`→`productId` 조회가 Entity 노출 없이 동작, variant 삭제(null/매핑 없음) 시 해석 실패가 식별됨(상위에서 409로 매핑)
- 권장 통합 테스트(Outbox 발행, Testcontainers PostgreSQL + Modulith)
  - 승인 결제 커밋 시 `event_publication`에 `OrderCompletedEvent`가 1건 저장되고 payload가 스키마를 만족한다(`004` 외부화 경로와 동일 프로파일 전략)
  - 동일 주문 동시 결제 2건 중 1건만 `paid`로 확정되고 `payments` row가 1건을 유지한다(`@Lock(PESSIMISTIC_WRITE)` 직렬화)
  - 시스템 오류 트랜잭션은 `payments`/주문 상태/`event_publication`이 모두 롤백된다
  - 테스트 기본 프로파일의 자동설정 제외와 충돌하지 않게 별도 통합 프로파일에서 실행한다
- 권장 REST/Security 테스트
  - `POST /api/v1/orders/{orderId}/payment` CONSUMER 승인 200, 비인증 401, ROLE 없는 인증 403, SELLER/ADMIN 200
  - `POST /api/v1/orders/{orderId}/payment` 금액 불일치 400
  - `POST /api/v1/orders/{orderId}/payment` productId 해석 불가(variant 삭제) 409, `payments`/이벤트 미생성
  - `POST /api/v1/orders/{orderId}/payment` 타 사용자 주문 404
  - `GET /api/v1/orders/{orderId}/payment` 자기 주문 결제 상태 200, 타 사용자 404
  - 응답에 ownerId, member/order/product/variant Entity, 로컬 절대 경로 미포함
- 권장 View 테스트
  - `pending` 주문 상세에 결제 폼(CSRF 포함) 렌더링
  - 결제 성공 redirect `/orders/{orderId}` + 결제 완료 상태 표시
  - 비인증 사용자의 `POST /orders/{orderId}/payment`는 `/login` redirect
- 권장 구조 테스트
  - `payment` 모듈이 `order.domain`/`order.repository`/`order.service`를 직접 참조하지 않음
  - `payment` 모듈이 `member`/`product` 내부 구현을 직접 참조하지 않음
  - `payment` 모듈은 order/member/product published API 또는 scalar만 사용
  - `web.payment`/`web.order`가 도메인 내부(domain/repository/service)를 직접 참조하지 않음
  - `OrderCompletedEvent`가 `order` 모듈에 위치
  - `ModularityTests.verify()` 통과

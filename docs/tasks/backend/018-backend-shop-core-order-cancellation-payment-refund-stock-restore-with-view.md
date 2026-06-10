# 018. shop-core 주문 취소 + 결제 환불 + 재고 복원 (with View)

## Target
shop-core

---

## Goal
`015`(주문 생성)·`016`(결제 승인)·`017`(결제 거절) 위에 **주문 취소(cancel)** 흐름을 추가한다. 소비자가 자신의 주문을 취소하면:
- **미결제 주문**(`pending` + 결제 row 없음/`ready`/`failed`) → 주문 `cancelled` + **재고 복원** + 결제 row가 있으면 `cancelled`로 전이. PG 환불 없음(청구된 적 없음).
- **결제 완료 주문**(`paid`) → **모의 PG 환불** + 결제 `refunded` + 주문 `cancelled` + **재고 복원** + `OrderCancelledEvent` 발행.

이미 이행 단계에 들어간 주문(`preparing`/`shipping`/`delivered`)과 종결 상태(`cancelled`/`refunded`)는 취소를 거부한다(409). REST·View에서 취소 결과를 일관되게 응답·표시한다.

> 이 Task는 **전체 주문 단위 취소**만 다룬다. 부분 취소(item 단위)·반품/교환(배송 후)·실 PG 환불은 범위 밖이다.

---

## Context
- **선행(구현 완료 전제)**
  - `015`: 주문 생성. **재고 차감은 주문 생성 시점**에 `inventory.spi.InventoryStockPort.decrease(variantId, quantity)`(비관적 락 `VariantStock`)로 수행된다. → **취소 시 재고 복원도 inventory 포트로 한다.** 재고는 결제가 아니라 **주문 생성에 묶여 차감**되므로, **미결제 주문 취소도 재고를 복원해야 한다.**
  - `016`: 결제 승인 + `OrderConfirmation.confirmPaid`(orders `pending→paid` + `OrderCompletedEvent`). **payment 모듈이 order.spi를 통해 주문 상태 전이를 위임**하는 패턴 확립.
  - `017`: 결제 거절 + `PaymentFailedEvent`. `Payment.markFailed`, `markPaid`(`ready/failed→paid`, Ma1), `uq_payments_order_id` 직렬화, C1(거절은 정상 커밋·HTTP 표현 분리).
- **상태값(신규 migration 불필요)**
  - `orders.status` CHECK = `pending/paid/preparing/shipping/delivered/cancelled/refunded` — `cancelled`/`refunded` **이미 허용**.
  - `payments.status` CHECK = `ready/paid/failed/cancelled/refunded` — `cancelled`/`refunded` **이미 허용**.
- **포트 현황(이 Task에서 확장)**
  - `inventory.spi.InventoryStockPort`: 현재 `decrease(variantId, quantity)`만 존재 → **`increase(variantId, quantity)` 추가**(복원).
  - `payment.spi.PaymentGatewayPort`: 현재 `authorize`만 존재 → **`refund(...)` 추가**(모의 환불).
  - `order_items.variant_id`는 nullable(`ON DELETE SET NULL`) — 변형이 삭제된 항목은 **복원 불가**하므로 건너뛰고 로깅한다(재고 복원은 best-effort, 삭제된 variant는 대상 아님).
- **이벤트 계약(코드보다 문서 먼저 — event-contract-rule)**
  - `docs/event-catalog.md`에 현재 `OrderCompletedEvent`·`PaymentFailedEvent`·`ShippingStartedEvent`만 정의됨. **취소/환불 이벤트는 없다.**
  - 이 Task는 **`OrderCancelledEvent`(topic `order-cancelled`)를 신규 정의**한다 → `docs/event-catalog.md`와 `docs/architecture.md` §5 토픽 표를 **코드보다 먼저** 갱신한다.
  - 환불 정보(`refunded`/`refundedAmount`/`currency`)는 **`OrderCancelledEvent` 페이로드에 포함**해 자족화한다. 별도 `PaymentRefundedEvent` 토픽은 본 Task에서 도입하지 않는다(후속 분리 가능).
- **모듈 의존 방향(순환 금지 — 중요)**
  - 현재 `payment → order.spi`(OrderConfirmation/OrderPaymentReader), `order → inventory.spi`이다. **`order → payment.spi`를 새로 만들면 `payment ↔ order` 순환**이 되어 `ModularityTests`가 깨진다.
  - 따라서 **취소 오케스트레이션은 payment 모듈이 소유**한다(016 대칭). payment가 환불을 수행하고 `order.spi`의 **신규 취소 포트**로 주문 상태 전이·재고 복원·이벤트 발행을 위임한다. **새 의존은 `payment → order.spi`(기존 방향)뿐**이다.

## API Authorization
> `api-authorization-rule` 준수 — 최소 권한 + 소유권 검사. 신규 엔드포인트 1쌍.

| API | 공개 여부 | 최소 권한 | 상위 권한 허용 | 소유권 검사 | 비고 |
|---|---|---|---|---|---|
| `POST /api/v1/orders/{orderId}/cancel` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 본인 주문만 취소. 타인/미존재 → 404 존재 은닉 |
| `POST /orders/{orderId}/cancel` (View) | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 취소 성공 flashSuccess / 불가 flashError |

- 타인 주문 취소 시도는 **404 존재 은닉**으로 통일(016/017과 동일).
- `SecurityConfig`에 `/api/v1/orders/*/cancel`·`/orders/*/cancel` 권한 라인을 추가한다(016 결제 라인 선례).

## Requirements
- **재고 복원 포트 추가** — `inventory.spi.InventoryStockPort.increase(long variantId, int quantity)`
  - `VariantStock` row를 `PESSIMISTIC_WRITE` 잠금 후 `stock += quantity`(JPA dirty checking). `decrease`와 동형의 비관적 락.
  - row 미존재(변형 삭제됨) → 복원 대상 아님(호출자가 건너뜀). `isActive`는 검사하지 않는다(비활성 변형도 재고는 복원).
  - 다중 variant는 호출자가 **variantId 오름차순** 순차 호출(데드락 완화, `decrease`와 동일 규약).
- **모의 PG 환불 포트 추가** — `payment.spi.PaymentGatewayPort.refund(...)`
  - 입력: `pgTransactionId`·`amount`·`currency`·`idempotencyKey`(= paymentId/orderNumber). 결과: `refunded`(bool) + `pgRefundId`(성공 시) + 실패 코드/사유(시그니처는 환불 성공/실패를 모두 표현).
  - 모의 구현은 **결정적**(무작위 금지). 데모는 **항상 성공**(`refunded=true`, `pgRefundId="MOCK-REFUND-"+UUID`). 실 PG 환불은 후속.
- **Entity 상태 전이(Setter 금지·의도 메서드)**
  - `Payment.markCancelled()`: `ready`/`failed`→`cancelled`(미결제 취소). `paid`→`cancelled` 금지(환불을 거쳐야 함).
  - `Payment.markRefunded(pgRefundId)`: `paid`→`refunded`(환불 완료). 그 외 상태에서 호출 시 `IllegalStateException`.
  - `Order.markCancelled()`: `pending`/`paid`→`cancelled`. `preparing`/`shipping`/`delivered`/`cancelled`/`refunded`에서 호출 금지(상위에서 차단; 방어적으로 도메인 예외).
  - 멱등: 이미 종결 상태면 전이 메서드가 멱등 처리하거나 상위에서 멱등 분기.
- **취소 오케스트레이션(payment 모듈 소유)** — 예: `PaymentService.cancel(userId, orderId)`(`@Transactional`)
  1. 주문 스냅샷 조회·**소유권 검증(404 존재 은닉)** — `order.spi`(`getOrderSnapshot` 재사용 또는 취소 전용 reader). orders row를 **비관락**해 동시 결제와 직렬화한다.
  2. 상태 판정:
     - `paid` → ④ 환불 경로. `pending` → ⑤ 미결제 취소 경로. 그 외(`preparing`/`shipping`/`delivered`) → `OrderCancellationConflictException`(409). 이미 `cancelled`/`refunded` → **멱등 반환**(중복 환불·중복 복원 금지).
  3. (paid) `PaymentGatewayPort.refund(...)` 호출 → 성공 시 `Payment.markRefunded`. (pending) 결제 row가 있으면 `Payment.markCancelled`, 없으면 결제 처리 없음.
  4. `order.spi` **신규 취소 포트**로 위임: 주문 `markCancelled` + **재고 복원**(각 order_item variant를 오름차순 `inventory.increase`, 삭제된 variant는 skip+log) + **`OrderCancelledEvent` 발행**(order 트랜잭션 = Outbox). 환불 정보를 페이로드에 포함.
  5. **취소·환불을 정상 커밋**하고 도메인 결과를 반환한다(C1 패턴). HTTP 표현(200/실패 매핑)은 커밋 후 ServiceResponse/Facade 계층에서 수행한다.
- **신규 order.spi 포트** — 예: `OrderCancellation.cancel(long orderId, long requesterUserId, RefundInfo refundInfo)`
  - orders row 비관락 + 소유권 재검증(404) + 상태 재검증(409) + `Order.markCancelled` + 재고 복원(inventory.spi) + `OrderCancelledEvent` 구성·발행. `OrderConfirmation`과 대칭. 반환은 scalar record(Entity 미노출).
  - 결과 타입은 `017` revision에서 도입한 `Outcome` 패턴을 따라 `CANCELLED`/`ALREADY_CANCELLED`/`REJECTED`를 값으로 표현하는 것을 권장(미래 분리 대비 이음매 일관성).
- **`OrderCancelledEvent` 정의·발행(order 모듈 소유)** — `order/event`에 `@Externalized("order-cancelled")` record
  - 페이로드(event-catalog SSOT 신규): 공통 봉투(`eventId`, `occurredAt`) + `orderId`/`orderNumber`/`memberId`/`memberEmail`/`memberName`/`items[]`(productId·productName·quantity)/`refunded`(bool)/`refundedAmount`(long, 환불 시)/`currency`/`cancelledAt`.
  - `memberEmail`/`memberName`은 `member.spi`로 해석(자족 페이로드). `amount` long 변환은 `016`(P3, `longValueExact`) 규칙 동일.
  - 발행은 order 트랜잭션 안에서 `ApplicationEventPublisher`로(같은 트랜잭션 = Outbox 저장 → 004 외부화).
- **재고 복원 일관성·멱등**
  - 취소는 주문당 1회만 재고를 복원한다(이미 `cancelled`/`refunded`면 멱등 반환으로 **이중 복원 금지**). orders row 비관락으로 동시 취소·결제와 직렬화.
  - 삭제된 variant(order_item.variant_id == null)는 복원 대상에서 제외하고 로깅(재고 복원 best-effort, 데이터 무결성 유지).
- **View**
  - 주문 상세(`templates/order/detail.html`)에 **"주문 취소" 버튼/폼**을 취소 가능 상태(`pending`/`paid`)에서만 노출. 취소 후 상태 표시(`취소됨`/`환불됨`) 추가.
  - `OrderViewController`에 `POST /orders/{orderId}/cancel` 핸들러 추가(성공 flashSuccess, `BusinessException`(409 등) catch → flashError + redirect — 016/017 패턴 재사용).

## Constraints
- **신규 migration 없이** 처리한다(상태값 `cancelled`/`refunded`는 기존 CHECK에 포함, `VariantStock`/`Order`/`Payment` 컬럼 추가 없음). 환불 사유/이력 영속이 필요하면 후속 Task(`V_` migration).
- **모듈 순환 의존 금지**: `order → payment.spi`를 만들지 않는다. 취소 오케스트레이션은 payment가 소유하고 `payment → order.spi`(기존 방향)만 추가한다. `ModularityTests`·구조 테스트 그린 유지.
- **이벤트 계약 변경은 문서 먼저**: `OrderCancelledEvent`를 `docs/event-catalog.md` + `docs/architecture.md` §5에 먼저 추가한 뒤 코드 작성(event-contract-rule).
- **취소·환불은 트랜잭션 정상 커밋(C1 패턴)**: 도메인 결과로 반환하고 HTTP 표현은 커밋 후 매핑. 트랜잭션 안에서 상태코드용 예외를 던져 재고 복원/환불/이벤트를 롤백시키지 않는다.
- **모의 환불은 결정적·항상 성공**(무작위 금지). 실 PG 환불(부분 환불·환불 실패 재시도)은 범위 밖.
- **전체 주문 취소만**: 부분 취소(item 단위), 반품/교환(배송 후 return), 환불 정산/수수료는 범위 밖.
- `preparing`/`shipping`/`delivered` 취소(배송 중단·회수)는 범위 밖(409로 거부). 이행 단계 전이는 별도 배송 Task에서 다룬다.
- 환불·재고 복원은 **각각 1회만**(멱등). 이미 `cancelled`/`refunded` 주문 재취소는 부작용 없이 멱등 반환.
- 비밀/민감정보 이벤트 페이로드 금지(016/017 제약 계승).

## Files
> 정확한 경로는 plan에서 확정. 아래는 신규/수정 범위 가이드.
- (신규) `payment/spi/PaymentGatewayPort.refund(...)` + `payment/service/MockPaymentGateway`(refund 구현)
- (신규) `inventory/spi/InventoryStockPort.increase(...)` + `inventory` 구현체(VariantStock 비관락 증가)
- (신규) `order/spi/OrderCancellation`(+ Result/Outcome) + `order/service/OrderCancellationImpl`
- (신규) `order/event/OrderCancelledEvent`(`@Externalized("order-cancelled")`)
- (신규) `common/exception/OrderCancellationConflictException`(409) — 필요 시
- (수정) `payment/domain/Payment`(markCancelled/markRefunded), `order/domain/Order`(markCancelled)
- (수정) `payment/service/PaymentService`(cancel 오케스트레이션) + ServiceResponse/Facade(취소 결과 → 200/예외 매핑)
- (수정) `payment/controller` 또는 `order/controller`(`POST /api/v1/orders/{orderId}/cancel`) — web→domain.spi 단방향 유지
- (수정) `web/order/OrderViewController`(`POST /orders/{orderId}/cancel`) + `templates/order/detail.html`(취소 버튼/상태)
- (수정) `security/SecurityConfig`(cancel 엔드포인트 권한)
- (문서) `docs/event-catalog.md`(OrderCancelledEvent) + `docs/architecture.md` §5 토픽 표

## Module Boundary Contract
- `payment → order.spi`(OrderCancellation, 기존 OrderPaymentReader/getOrderSnapshot) — **기존 방향, 순환 없음.**
- `order → inventory.spi`(increase) — 기존 방향.
- `order → member.spi`(연락처) / `order → product.spi`(productId 해석) — 기존.
- `OrderCancelledEvent`는 **order 모듈 발행 소유**(`OrderCompletedEvent`와 동일 위치 철학).
- payment·order는 서로의 내부(domain/repository/service)를 직접 참조하지 않는다(published port만). `ModularityTests` 통과.

## Backend - View Contract
- 취소 facade(예: `PaymentFacade.cancel(email, orderId)` 또는 신규): 성공 시 결과 반환, 불가 시 `BusinessException`(409 등)로 던진다. View 핸들러가 `catch (BusinessException) → flashError` (016/017 패턴).
- 취소 후 주문 상세는 `cancelled`/`refunded` 상태 표시 + 결제/취소 폼 미노출.

## API Response Contract
- 성공: `200` + 취소 결과(주문 상태·환불 여부/금액). 멱등 재취소도 `200`(동일 결과).
- 취소 불가 상태(이행 단계): `409` + `ErrorResponse`(error-response-rule, 내부정보 비노출).
- 타인/미존재 주문: `404` 존재 은닉.
- 환불 실패(실 PG 도입 시): 본 Task 모의는 항상 성공이라 해당 없음(후속).

## Acceptance Criteria
- 미결제 주문(`pending`, 결제 row 없음/`ready`/`failed`) 취소 → 주문 `cancelled` + **재고 복원** + (결제 row 있으면) `cancelled`. PG 환불 호출 없음.
- 결제 완료 주문(`paid`) 취소 → 모의 환불 성공 + 결제 `refunded` + 주문 `cancelled` + **재고 복원** + `OrderCancelledEvent`(환불정보 포함) Outbox 저장.
- `preparing`/`shipping`/`delivered` 취소 시도 → `409`, 상태·재고 불변, 이벤트 미발행.
- 이미 `cancelled`/`refunded` 주문 재취소 → **멱등 200**, **재고 이중 복원 없음**, 환불 이중 호출 없음.
- 타인 주문 취소 → `404` 존재 은닉.
- 취소 트랜잭션은 예외 롤백 없이 정상 커밋(C1): 재고 복원·환불·이벤트가 부분 반영 없이 원자 커밋. 시스템 오류 시 전체 롤백.
- 삭제된 variant(order_item.variant_id null) 포함 주문 취소 → 해당 항목은 복원 skip+log, 나머지 정상 복원, 취소 성공.
- `OrderCancelledEvent` 페이로드 자족(memberEmail/memberName/items/refunded/refundedAmount/currency/cancelledAt) — notification 역조회 불필요.
- View: 취소 가능 주문에 취소 버튼 노출, 취소 후 `cancelled`/`refunded` 표시·폼 미노출. 취소 불가 시 flashError.
- `order-cancelled` 토픽이 `docs/event-catalog.md`·`docs/architecture.md` §5에 정의됨(코드보다 문서 먼저).
- `ModularityTests`/구조 테스트 통과(payment↔order 순환 없음). `015`/`016`/`017` 회귀 없음.

## Test
- 단위: `Payment.markCancelled/markRefunded`·`Order.markCancelled` 전이(허용/금지/멱등). `MockPaymentGateway.refund` 결정성(항상 성공). `InventoryStock` increase 비관락.
- 단위(Mockito): `PaymentService.cancel` 분기 — paid→환불+refunded, pending→cancelled, 이행단계→409, 멱등 재취소(복원·환불 1회), 소유권 404.
- 통합(Testcontainers): 취소 커밋 시 `OrderCancelledEvent` `event_publication` 1건 + payload 스키마 + 재고 복원(stock 증가) + 주문/결제 상태 전이 원자성. 멱등 재취소 시 재고 불변·이벤트 추가 없음. 시스템 오류 강제 시 부분 반영 없음.
- 동시성(Testcontainers): 동시 취소 2건 → 1건만 복원/환불, row 정합(멱등). 취소 vs 결제 동시 → orders row 락으로 직렬화, 모순 상태 없음.
- REST/Security: `POST /api/v1/orders/{id}/cancel` 200/409/404, 내부정보 비노출, ROLE_CONSUMER 권한.
- View: 취소 버튼 노출/취소 후 상태 표시/취소 불가 flashError + redirect.
- 구조: `OrderCancelledEvent` order 모듈 위치, payment↔order 순환 없음, `ModularityTests`.

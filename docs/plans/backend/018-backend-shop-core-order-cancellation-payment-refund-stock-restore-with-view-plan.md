# 018. shop-core 주문 취소 + 결제 환불 + 재고 복원 — 구현 계획(plan, with View)

> Task SSOT: docs/tasks/backend/018-backend-shop-core-order-cancellation-payment-refund-stock-restore-with-view.md — **설계 모순 5건이 수정 반영된 최신본.** 본 plan은 그 결정(#1~#5)을 그대로 따른다.
> 선행 Task(구현 완료): 015(주문 생성·재고 차감)·016(결제 승인·OrderConfirmation·OrderCompletedEvent)·017(결제 거절·PaymentFailedEvent·Outcome 이음매). 016/017의 승인·거절 경로는 **본 Task에서 변경하지 않는다**(취소 분기만 추가).
> 선례 plan(구조·톤·레이어·테스트 패턴 기준): docs/plans/backend/016-...-plan.md, docs/plans/backend/017-...-plan.md + docs/plans/revisions/backend/017-...-revision-1.md(C1/Outcome 이음매/모듈경계 결정 맥락).
> 이벤트 계약 SSOT: docs/event-catalog.md + docs/architecture.md §5 — **본 Task는 `OrderCancelledEvent`(topic `order-cancelled`)를 코드보다 먼저 추가**한다(event-contract-rule).
> 영역: backend(payment 취소 오케스트레이션 + order 취소 포트·이벤트 + inventory 복원 포트 + PG refund 포트 + REST + 문서) + view(detail.html 취소 폼·상태표시 + OrderViewController cancel 핸들러)
> 대상 프로젝트: shop-core (Spring Modulith 모듈러 모놀리스)
> 작성일: 2026-06-10
> 상태: plan only (코드 변경 없음 — 구현은 backend-implementor / view-implementor가 수행)
> 담당: backend-implementor(도메인/서비스/포트/이벤트/REST/문서 + 백엔드·통합·동시성 테스트) → view-implementor(detail.html 취소 폼·상태표시 + OrderViewController cancel 핸들러 + View 렌더링 테스트)
> 진행: backend-implementor → view-implementor → reviewer → fixer 사이클(최대 3회)
> 적용 결정(Task SSOT 반영): **#1**(REST 취소 = payment 모듈 PaymentRestController, order/controller 금지=순환), **#2**(017식 C1 비적용 — 성공은 원자 커밋+200, 거부는 부작용 전 판정해 throw), **#3**(결제완료 취소→주문 `refunded` / 미결제 취소→주문 `cancelled`), **#4**(취소 전용 locked reader = orders row PESSIMISTIC_WRITE로 환불 결정 전 잠금), **#5**(실 PG 환불 비가역성은 범위 밖, 주의만).

---

## 0. 작업 구분 요약 (백엔드 vs 화면)

### 0.1 담당 분담표

| 구분 | 항목 | 담당 |
|---|---|---|
| 문서 | `OrderCancelledEvent`(topic `order-cancelled`)를 `docs/event-catalog.md` + `docs/architecture.md` §5에 **코드보다 먼저** 추가 | backend-implementor |
| 백엔드 | `inventory/spi/InventoryStockPort.increase(long variantId, int quantity)` 추가 + `InventoryStockPortImpl`·`VariantStock.increase(int)` 구현(비관락) | backend-implementor |
| 백엔드 | `payment/spi/PaymentGatewayPort.refund(...)` 추가 + `MockPaymentGateway.refund` 결정적 구현(항상 성공) | backend-implementor |
| 백엔드 | `payment/domain/Payment.markCancelled()`(ready/failed→cancelled)·`markRefunded(pgRefundId)`(paid→refunded) | backend-implementor |
| 백엔드 | `order/domain/Order.markCancelled()`(pending→cancelled)·`markRefunded()`(paid→refunded) | backend-implementor |
| 백엔드 | `order/spi` **취소 전용 locked reader**(orders row PESSIMISTIC_WRITE, #4) + `order/spi/OrderCancellation`(+ Outcome/Result/RefundInfo) + `order/service/OrderCancellationImpl`(권위 재검증 + 종결 전이 + 재고 복원 + OrderCancelledEvent 발행) | backend-implementor |
| 백엔드 | `order/event/OrderCancelledEvent`(`@Externalized("order-cancelled")`) — order 모듈 발행 소유 | backend-implementor |
| 백엔드 | `payment/service/PaymentService.cancel(userId, orderId)` 취소 오케스트레이션(@Transactional) + `CancelResult`(내부 타입) | backend-implementor |
| 백엔드 | `payment/service/PaymentServiceResponse.cancel`(REST) + `payment/spi/PaymentFacade.cancel` + `PaymentFacadeImpl.cancel`(View) | backend-implementor |
| 백엔드 | **신규 `payment/controller/PaymentCancellationRestController`** — 클래스/메서드 매핑을 `/api/v1/orders/{orderId}/cancel`로 분리(#1, payment 모듈에 배치). 기존 `PaymentRestController`는 클래스 매핑이 `/payment`라 메서드 경로가 **결합되어 깨지므로** 별도 컨트롤러로 둔다 | backend-implementor |
| 백엔드 | `security/SecurityConfig` — `/api/v1/orders/*/cancel`·`/orders/*/cancel` hasRole("CONSUMER") 명시 추가 | backend-implementor |
| 백엔드 | 단위·Mockito·통합(Outbox)·동시성·REST/Security·구조 테스트 | backend-implementor |
| 화면 | `templates/order/detail.html` — 취소 폼(`pending`/`paid`에서만 노출, `POST /orders/{orderId}/cancel`) + 취소 후 상태 표시(`취소됨`/`환불됨`) | view-implementor |
| 화면 | `web/order/OrderViewController.cancel` 핸들러(`POST /orders/{orderId}/cancel`, 성공 flashSuccess / `BusinessException` catch → flashError + redirect) | view-implementor |
| 화면 | View 렌더링 테스트(취소 버튼 노출/취소 후 상태/취소 불가 flashError) | view-implementor |

> 호출 순서: **백엔드 → 화면.** `PaymentFacade.cancel` 시그니처·`CancelResult`·`OrderCancellationConflictException`(409)·취소 후 주문 상태(`cancelled`/`refunded`) 계약이 먼저 고정되어야 View가 취소 폼 노출 조건·flashError 경로를 안정적으로 검증한다.

### 0.2 양 영역 인터페이스 접점 (어긋남 방지)

| 항목 | 값 (계약) |
|---|---|
| View 취소 facade 시그니처 | `PaymentFacade.cancel(String email, long orderId) → OrderCancelResponse`. 성공 시 취소/환불 결과 반환, 불가 시 `OrderCancellationConflictException`(409, `BusinessException`)로 던진다 |
| View 취소 핸들러 | `OrderViewController.cancel`(`POST /orders/{orderId}/cancel`) **신규**. `try { paymentFacade.cancel(email, orderId) → flashSuccess } catch (BusinessException e) { flashError(e.getMessage()) + redirect:/orders/{orderId} }`(016/017 pay 핸들러 패턴 재사용) |
| 취소 후 주문 상태 표시 | `cancelled`(미결제 취소) / `refunded`(결제완료 취소). detail.html `order.status` 뱃지가 그대로 표시 |
| 취소 폼 노출 조건 | 취소 가능 상태에서만 노출. `order.status`가 `pending`/`paid`일 때만 취소 버튼 노출, 그 외(`preparing`/`shipping`/`delivered`/`cancelled`/`refunded`)는 미노출 |
| REST 취소 응답 | 성공 200 + 취소 결과(주문 상태·환불 여부/금액). 멱등 재취소 200(동일 결과). 이행단계 409 + ErrorResponse. 타인/미존재 404 |

---

## 1. 설계 방식 및 이유

### 1.1 사전 확정 사실 (016/017 실제 구현 코드 점검 완료 — 가정 아님)

아래는 실제 소스 점검 결과다. plan의 모든 경로/패키지는 이에 근거한다.

- **상태값 신규 migration 불필요(코드 확인)**: `Order.java` javadoc이 `orders.status = 'pending','paid','preparing','shipping','delivered','cancelled','refunded'`를 명시 — `cancelled`/`refunded` 이미 허용. `Payment.java` javadoc이 `payments.status = ready/paid/failed/cancelled/refunded`를 명시 — `cancelled`/`refunded` 이미 허용. `VariantStock`/`Order`/`Payment` 컬럼 추가 없음. → **신규 migration 0건.**
- **`InventoryStockPort`**(`inventory/spi/InventoryStockPort.java`): `decrease(long variantId, int quantity)`만 존재. 구현체 `InventoryStockPortImpl`(`inventory/service`, package-private, `@Service @Transactional`)이 `inventoryStockRepository.findByIdForUpdate(variantId)`(PESSIMISTIC_WRITE = `SELECT ... FOR UPDATE`)로 잠근 뒤 `VariantStock.decrease(int)`(dirty checking)로 차감. `VariantStock`(`inventory/domain`)은 `id/stock/isActive`만 매핑(`@Getter`, Setter 금지, 의도 메서드 `decrease(int)`). → **`increase(long, int)` 포트 + `VariantStock.increase(int)` 의도 메서드를 `decrease`와 동형으로 추가**(비관락 재사용).
- **`PaymentGatewayPort`**(`payment/spi/PaymentGatewayPort.java`): `authorize(PaymentAuthorizationRequest) → PaymentAuthorizationResult`만 존재. `PaymentAuthorizationResult`에 정적 팩토리 `approved`/`declined`. 모의 구현 `MockPaymentGateway`(`payment/service`, package-private)는 `method == "virtual_account"`면 거절, 그 외 승인(결정적). → **`refund(PaymentRefundRequest) → PaymentRefundResult` 포트 + `MockPaymentGateway.refund`(항상 성공, 결정적)를 추가.**
- **`Payment` Entity**(`payment/domain/Payment.java`): `id/orderId(unique)/method/status/amount(precision12,scale2)/pgTransactionId(nullable)/paidAt(nullable)` + BaseEntity. 정적 팩토리 `create`(status="ready"), 의도 메서드 `markPaid(pgTransactionId, paidAt)`(ready/failed→paid + paid 멱등, Ma1)·`markFailed(failureCode, failureReason)`(ready→failed/failed→failed no-op, paid→failed 금지). **Setter 없음.** → **`markCancelled()`·`markRefunded(pgRefundId)` 의도 메서드 추가**(`pgRefundId`는 옵션 A로 미영속 가능 — 1.9 참조).
- **`Order` Entity**(`order/domain/Order.java`): `status` 문자열, 의도 메서드 `markPaid()`(pending→paid, 그 외 `IllegalStateException`). **Setter 없음.** → **`markCancelled()`(pending→cancelled)·`markRefunded()`(paid→refunded) 의도 메서드 추가.**
- **`OrderConfirmation`**(`order/spi`): `confirmPaid(orderId, requesterUserId, paidAmount) → OrderConfirmationResult(orderId, orderNumber, Outcome{CONFIRMED,ALREADY_CONFIRMED,REJECTED}, eventPublished, orderedAt, rejectedReason)`. 구현체 `OrderConfirmationImpl`(`order/service`, package-private, `@Transactional`)이 **`orderRepository.findByIdForUpdate(orderId)`(orders row PESSIMISTIC_WRITE)** + 소유권 404 재검증 + status 분기(paid→ALREADY_CONFIRMED, 비-pending→REJECTED, 금액 불일치→REJECTED) + `Order.markPaid()` + `OrderCompletedEvent` 발행(같은 트랜잭션 Outbox). **`OrderCancellation`은 이 클래스의 대칭으로 설계한다**(같은 락 패턴·404 재검증·Outcome 값).
- **`OrderPaymentReader`**(`order/spi`): `getPayableOrder`(완결성 409 포함)·`getOrderSnapshot`(상태조회 전용) — **둘 다 무락**. #4에 따라 취소 경로는 이 무락 reader를 환불 결정용으로 재사용하지 **않는다** → 별도 **locked reader**가 필요.
- **`OrderRepository`**(`order/repository`): `findByIdForUpdate(id)`(PESSIMISTIC_WRITE, items fetch 없음)·`findWithItemsOnlyByIdAndUserId(id, userId)`(items fetch, 무락) 존재. → 취소 locked reader는 **orders row를 PESSIMISTIC_WRITE로 잠그고 같은 트랜잭션 안에서 items를 로딩**해야 한다(재고 복원에 variant 목록 필요). 구현은 `findByIdForUpdate`로 락 획득 후 같은 영속성 컨텍스트에서 `order.getItems()` lazy 접근(OrderConfirmationImpl가 같은 방식으로 items 접근) 또는 락 fetch 쿼리 1개 추가.
- **`PaymentService`**(`payment/service`, `@Service`, public): `pay`(8단계, `acquireOrResolveReadyRow`, `handleDeclined`)·`getPaymentStatus`. 의존: `OrderPaymentReader`·`OrderConfirmation`·`PaymentGatewayPort`·`PaymentRepository`·`MemberDirectory`·`ApplicationEventPublisher`. 내부 결과 record `PaymentResult`/`PaymentStatusResult`/커맨드 `PaymentCommand`. → **`cancel(userId, orderId)` 오케스트레이션 + 내부 `CancelResult` record를 추가**(pay와 동일 트랜잭션·위임 패턴).
- **`PaymentServiceResponse`**(REST, public)·**`PaymentFacade`/`PaymentFacadeImpl`**(View): `pay`가 거절 시 `PaymentDeclinedException`(402)을 트랜잭션 밖에서 throw하는 패턴. 취소는 #2(C1 비적용)이라 ServiceResponse/Facade는 단순 위임(거부는 PaymentService가 트랜잭션 안에서 던짐).
- **`PaymentRestController`**(`payment/controller`, **클래스 레벨 `@RequestMapping("/api/v1/orders/{orderId}/payment")`**): `pay`(POST)·`getPaymentStatus`(GET). → **중요**: Spring MVC는 메서드 매핑을 클래스 매핑과 **결합**하므로, 이 컨트롤러에 `@PostMapping("/.../cancel")`을 추가하면 `.../payment/.../cancel`로 **경로가 깨진다**(절대경로 메서드 매핑 개념 없음). 따라서 취소는 **신규 `PaymentCancellationRestController`**(클래스 매핑 `/api/v1/orders/{orderId}/cancel`)에 둔다 — payment 모듈에 배치(#1 — order/controller에 두면 `order → payment` 순환). 기존 PaymentRestController는 무변경.
- **`SecurityConfig`**: REST 체인에 `/api/v1/orders/*/payment` hasRole("CONSUMER") + `/api/v1/orders/**` hasRole("CONSUMER"), View 체인에 `/orders/*/payment`·`/checkout, /orders, /orders/**` hasRole("CONSUMER"). → **`/api/v1/orders/*/cancel`·`/orders/*/cancel` 전용 matcher를 016 결제 라인 선례대로 명시 추가**(이미 `/**`가 덮지만 의도 명시·회귀 방지).
- **`MemberDirectory`**(`member/spi`): `findUserIdByEmail`·`findContactByUserId(userId) → MemberContact(email, name)`. → OrderCancellation이 자족 페이로드(memberEmail/memberName)를 위해 사용(OrderCompletedEvent와 동일).
- **`ProductOrderCatalog`**(`product/spi`): `getOrderableSnapshots(variantIds) → OrderableVariantSnapshot(variantId, productId, ...)`. → OrderCancellation의 `items[].productId` 해석에 사용(OrderCompletedEvent와 동일).
- **테스트 프로파일 제약(016/017과 동일)**: `src/test/resources/application.yml`이 DataSource/JPA/Kafka/Flyway/외부화 자동설정 제외 → Outbox·동시성은 016/017의 Testcontainers 별도 프로파일(`@AutoConfigureTestDatabase(NONE)` + `@Testcontainers`(postgres:16.4-alpine + `@ServiceConnection`) + `@TestPropertySource`(`spring.autoconfigure.exclude=` 리셋 + `spring.flyway.enabled=true` + `ddl-auto=validate`) + 외부화 `enabled=false`로 `event_publication` 저장만 검증) 패턴을 **그대로 재사용**.

### 1.2 payment가 취소 오케스트레이션 소유 (순환 회피 — 016/017 대칭)

핵심 설계는 "취소·환불의 오케스트레이션을 payment 모듈이 소유한다"이다.

- 현재 의존 방향: `payment → order.spi`(OrderConfirmation/OrderPaymentReader), `order → inventory.spi`. **`order → payment.spi`를 새로 만들면 `payment ↔ order` 순환**이 되어 `ModularityTests`가 깨진다.
- 따라서 **`PaymentService.cancel`이 취소를 오케스트레이션**한다: ① 취소 전용 locked reader(order.spi) 호출 → ② 상태 판정 → ③ (paid) PG refund 수행 + `Payment.markRefunded` / (pending) `Payment.markCancelled` → ④ `order.spi` 신규 취소 포트(`OrderCancellation`)로 주문 종결 전이 + 재고 복원 + `OrderCancelledEvent` 발행을 위임. **새 의존은 `payment → order.spi`(기존 방향)뿐이다.**
- 016의 `pay`가 `OrderConfirmation.confirmPaid`로 주문 확정을 위임한 것과 정확히 대칭이다(payment가 환불을 책임지고, 주문 상태/재고/이벤트는 order에 위임).

### 1.3 취소 전용 locked reader로 환불 전 직렬화 (#4)

- 취소 전용 **locked reader**(신규 `order.spi` 메서드)는 orders row를 `PESSIMISTIC_WRITE`로 잠그고 소유권을 검증(404 존재 은닉)한 뒤 스냅샷을 반환한다. **이 호출을 환불 결정(②③) 전에** 수행해 동시 결제(`OrderConfirmation.confirmPaid`도 같은 orders row를 PESSIMISTIC_WRITE로 잠금)와 직렬화한다.
- **무락 `getOrderSnapshot` 재사용 금지(#4)**: 무락 스냅샷으로 상태를 판정하면 "취소 판정(pending) → 그 사이 다른 트랜잭션이 confirmPaid로 paid 전이 → 취소가 미결제 경로로 잘못 진행(환불 없이 cancelled)" 같은 환불/확정 race가 발생한다. orders row 락을 환불 결정 전에 잡으면 confirmPaid와 cancel이 같은 row 락을 두고 직렬화되어, 한쪽이 끝난 뒤 다른 쪽이 **권위 상태**를 본다.
- 이 락은 같은 트랜잭션의 ④(OrderCancellation 위임)까지 유지된다. 단 **OrderCancellation도 자기 `@Transactional` 안에서 orders row를 다시 잠그거나(같은 트랜잭션이면 재진입) 락된 row를 권위 재검증**한다(OrderConfirmationImpl가 confirmPaid 진입 시 `findByIdForUpdate` + 소유권 재검증을 하는 것과 동형). 즉 locked reader(판정용)와 OrderCancellation(전이용)이 같은 트랜잭션·같은 orders row를 공유한다.

### 1.4 order 종결 상태 규칙 — cancelled / refunded (#3)

- **결제완료 취소(`paid`) → 주문 `refunded`**: 환불을 동반하므로 주문도 `refunded`로 종결(payment `refunded`와 정렬). `Order.markRefunded()`(paid→refunded).
- **미결제 취소(`pending`) → 주문 `cancelled`**: 청구된 적 없으므로 `cancelled`(payment row 있으면 `cancelled`, 없으면 결제 처리 없음). `Order.markCancelled()`(pending→cancelled).
- 이 규칙은 payment 상태(`cancelled`/`refunded`)와 의미가 1:1 정렬되어, 주문/결제 상태가 어긋나지 않는다. `Outcome.CANCELLED`(아래)는 두 종결을 포괄하고, 재무 구분은 `refunded` 플래그·주문 상태로 표현한다.

### 1.5 OrderCancellation에 Outcome 패턴 (017 revision 이음매 일관성)

- `OrderCancellation`은 `OrderConfirmation`과 동일하게 **`Outcome { CANCELLED, ALREADY_CANCELLED, REJECTED }` 값 타입**을 채택한다(017 revision의 forward-compat 이음매 일관성).
  - `CANCELLED` — 정상 취소(주문 종결 `cancelled` 또는 `refunded` 양쪽 포괄, `OrderCancelledEvent` 발행 완료).
  - `ALREADY_CANCELLED` — 이미 `cancelled`/`refunded`(멱등 경로, 재고 이중 복원·이벤트 재발행 없음).
  - `REJECTED` — 이행단계(`preparing`/`shipping`/`delivered`) 등 취소 불가(rejectedReason 포함).
- **거부 판정의 권위는 PaymentService 2단계(locked reader 스냅샷, PG refund 전)에 있다(#3 정합)**: 이행단계(`preparing`/`shipping`/`delivered`)·이미 종결 상태는 PaymentService가 **환불 전에** `OrderCancellationConflictException`(409)/멱등으로 처리한다(부작용 없음). `OrderCancellation.cancel`은 **같은 트랜잭션·같은 orders row 락**에서 호출되므로 2단계 이후 상태가 변하지 않는다 → 정상 흐름에서 `OrderCancellation`의 `REJECTED`는 **발생하지 않는다.** 만약 발생하면 락 불변식 위반(방어 경로)이므로 PaymentService가 `IllegalStateException`(500, 전체 롤백)으로 취급한다 — **"환불 후 정상 REJECTED→409" 경로는 없다.** Outcome 값 모델링은 forward-compat 이음매(OrderConfirmation 대칭·방어 재검증) 일관성 위해 유지한다.

### 1.6 OrderCancelledEvent = order 모듈 발행 소유, 자족 페이로드 (event-contract-rule)

- `OrderCancelledEvent`를 **`order/event`**에 `@Externalized("order-cancelled")` record로 정의하고, **order 모듈(`OrderCancellationImpl`)이 `ApplicationEventPublisher`로 발행**한다(OrderCompletedEvent와 동일 위치 철학 — 주문 종결 사건은 order 소유).
- 페이로드(event-catalog SSOT 신규): 공통 봉투(`eventId`, `occurredAt`) + `orderId`/`orderNumber`/`memberId`/`memberEmail`/`memberName`/`items[]`(productId·productName·quantity)/`refunded`(bool)/`refundedAmount`(long, 환불 시·미결제 취소는 0)/`currency`/`cancelledAt`.
  - `memberEmail`/`memberName`은 `member.spi.findContactByUserId`로 해석(자족 — notification 역조회 불필요).
  - `items[].productId`는 `product.spi.getOrderableSnapshots`로 variantId→productId 해석(OrderCompletedEvent와 동일). 삭제된 variant(variantId null)는 productId 해석 불가 — **이벤트 items에서 제외하고 로깅**(자족성 유지, 재고 복원도 같은 항목 skip — 1.8).
  - `refundedAmount` long 변환은 016/017 P3(`longValueExact`, 소수부 0만 허용, 위반 `AmountConversionException` 500) 규칙 동일.
- 발행은 order 트랜잭션 안에서 `publishEvent` → `event_publication`(INCOMPLETE) Outbox 저장 → 커밋 후 `spring-modulith-events-kafka`가 외부화. 004 메커니즘 재사용(build.gradle/application.yml 무변경).
- **문서 먼저(event-contract-rule)**: `docs/event-catalog.md`에 `OrderCancelledEvent` 섹션 + `docs/architecture.md` §5 토픽 표에 `order-cancelled | OrderCancelledEvent | 주문 취소 | order | notification` 행을 **코드 작성 전에** 추가한다.

### 1.7 C1 비적용 — 성공은 원자 커밋+200, 거부는 부작용 전 판정 (#2)

- 017의 C1("거절을 트랜잭션 안에서 던지지 않고 정상 커밋 후 402 매핑")은 "**failed 기록 + 이벤트를 영속해야 하는데 에러 상태(402)로 응답**"이라는 영속+에러상태 충돌 때문이었다.
- 018은 이 충돌이 **없다**:
  - **성공(취소/환불)** = 재고 복원·환불·종결 전이·`OrderCancelledEvent`가 **한 트랜잭션으로 원자 커밋**되고 `200`. 영속과 성공 상태(200)가 충돌하지 않으므로 C1식 "결과 반환 후 커밋 후 매핑" 간접화가 불필요.
  - **거부(이행단계 409)** = **PaymentService 2단계**(locked reader 스냅샷으로 상태 판정, **PG refund 전**)에서 `OrderCancellationConflictException`(409)을 **트랜잭션 안에서 던진다** — 환불·복원·이벤트가 아직 수행 전이라 롤백할 부작용이 없다. (`OrderCancellation`의 `REJECTED`는 같은 락 하에서 정상 흐름엔 발생하지 않고, 발생 시 불변식 위반 500 — 1.5 참조.)
- 따라서 018은 C1식 간접화(거절 결과 → 커밋 → 트랜잭션 밖 예외 변환)를 **적용하지 않는다.** ServiceResponse/Facade는 PaymentService가 던진 예외를 그대로 전파하고, 성공 결과는 그대로 200으로 매핑한다.

### 1.8 재고 복원 멱등·best-effort

- 취소는 주문당 **1회만** 재고를 복원한다. locked reader가 잡은 orders row 락 + OrderCancellation의 권위 재검증(이미 `cancelled`/`refunded`면 `ALREADY_CANCELLED` 멱등 반환)으로 **이중 복원·이중 환불을 차단**한다(#4).
- 재고 복원은 각 order_item의 variantId를 **오름차순으로 `inventory.increase`** 순차 호출(데드락 완화, `decrease`와 동일 규약). `VariantStock.increase`는 row 미존재(변형 삭제됨) 시 복원 대상 아님 → **호출자(OrderCancellation)가 variantId null 항목을 skip+log**, increase 자체는 row 존재 가정. `isActive`는 검사하지 않는다(비활성 변형도 재고 복원).
- 삭제된 variant(`order_item.variant_id == null`)는 복원·이벤트 items 모두에서 제외하고 로깅(best-effort, 데이터 무결성 유지) — 나머지 항목은 정상 복원, 취소 성공.

### 1.9 mock refund = 결정적·항상 성공, 환불 사유 영속 정책 (옵션 A — 신규 migration 없음)

- `MockPaymentGateway.refund`는 **결정적**(무작위 금지)·**항상 성공**(`refunded=true`, `pgRefundId="MOCK-REFUND-"+request.idempotencyKey()` — **UUID 미사용**, 같은 입력 → 같은 pgRefundId로 진짜 결정성 보장·재환불 멱등). 입력: `pgTransactionId`·`amount`·`currency`·`idempotencyKey`(= paymentId 또는 orderNumber). 부작용 없음(in-process 동기).
- `Payment.markRefunded(pgRefundId)`의 `pgRefundId`는 **옵션 A로 영속하지 않을 수 있다**(payments에 `pg_refund_id` 컬럼 없음, 신규 migration 회피). 017 `markFailed`의 옵션 A와 동형 — 인자는 받되 본문 미사용(또는 기존 `pgTransactionId`를 덮어쓰지 않고 status만 `refunded` 전이), 옵션 B(환불 ID/사유 영속) 대비 시그니처만 고정. javadoc에 "pgRefundId 현재 미영속(옵션 A) — 옵션 B 대비" 명시. (환불 ID는 `OrderCancelledEvent`/응답에 싣지 않아도 Task Acceptance 충족 — 환불 여부/금액만 필요.)
- **실 PG 환불 비가역성은 범위 밖(#5)**: mock refund는 트랜잭션 안에서 호출해도 부작용이 없어 무해하나, 실 PG 환불은 "환불 성공 후 커밋 전 롤백 = 실제 환불 비가역"이라 016 `authorize`와 동일한 분산 문제를 가진다 → 실 PG 도입 시 멱등키 + 정산이 필요(분리/실 PG Task). **본 plan은 주의만 명시하고 구현하지 않는다.**

### 1.10 신규 migration 없음 (Constraint)

- `cancelled`/`refunded` 상태값은 기존 CHECK 포함, `VariantStock.increase`는 기존 `stock` 컬럼 UPDATE, `markRefunded`는 옵션 A로 컬럼 무추가. → **신규 `V_` migration 0건.** 환불 사유/이력 영속이 필요하면 후속 Task(옵션 B).

---

## 2. 구성 요소 (신규/수정 파일 — 정확한 패키지 경로)

> 2.1 = backend-implementor, 2.2 = view-implementor. (B)=backend, (V)=view.

### 2.1 backend-implementor 담당 범위

#### (B) 문서 — 코드보다 먼저 (event-contract-rule)
- `docs/event-catalog.md` — `## OrderCancelledEvent (topic: \`order-cancelled\`)` 섹션 추가: 공통 봉투 + `orderId`/`orderNumber`/`memberId`/`memberEmail`/`memberName`/`items[](productId·productName·quantity)`/`refunded`(bool)/`refundedAmount`(long)/`currency`/`cancelledAt` + 예시 JSON(기존 이벤트 표 형식 그대로).
- `docs/architecture.md` §5 토픽 표 — `| \`order-cancelled\` | \`OrderCancelledEvent\` | 주문 취소 | order | notification |` 행 추가.

#### (B) 수정 — inventory (재고 복원 포트)
- `shop-core/src/main/java/com/shop/shop/inventory/spi/InventoryStockPort.java` — `void increase(long variantId, int quantity)` 추가. javadoc: "취소/환불 시 재고 복원. VariantStock row PESSIMISTIC_WRITE 잠금 후 stock += quantity. row 미존재(변형 삭제) → 호출자가 skip(이 메서드는 row 존재 가정 또는 미존재 시 no-op+log). isActive 미검사(비활성도 복원). 다중 variant는 호출자가 variantId 오름차순 순차 호출."
- `shop-core/src/main/java/com/shop/shop/inventory/service/InventoryStockPortImpl.java` — `increase(long, int)` 구현: `findByIdForUpdate(variantId)`로 잠금 → `VariantStock.increase(quantity)`. row 미존재 시 복원 skip+log(InsufficientStockException 던지지 않음 — 복원은 best-effort).
- `shop-core/src/main/java/com/shop/shop/inventory/domain/VariantStock.java` — 의도 메서드 `increase(int quantity)`(`this.stock += quantity`) 추가(`decrease`와 동형).

#### (B) 수정 — payment/spi (모의 환불 포트)
- `shop-core/src/main/java/com/shop/shop/payment/spi/PaymentGatewayPort.java` — `PaymentRefundResult refund(PaymentRefundRequest request)` 추가.
  - `record PaymentRefundRequest(String pgTransactionId, BigDecimal amount, String currency, String idempotencyKey)`.
  - `record PaymentRefundResult(boolean refunded, String pgRefundId, String failureCode, String failureReason)` + 정적 팩토리 `refunded(pgRefundId)` / `failed(failureCode, failureReason)`(실패는 시그니처상 표현만, 본 Task mock은 항상 성공).
  - javadoc: 실 PG 환불 비가역성 주의(#5) — refund 성공 후 커밋 전 롤백은 실 PG에서 비가역.

#### (B) 수정 — payment/service
- `shop-core/src/main/java/com/shop/shop/payment/service/MockPaymentGateway.java` — `refund` 구현: 항상 `PaymentRefundResult.refunded("MOCK-REFUND-" + request.idempotencyKey())`(결정적·항상 성공·**무작위 금지 — UUID 사용 안 함**). 같은 idempotencyKey → 같은 pgRefundId(재환불 멱등·테스트 재현성).
- `shop-core/src/main/java/com/shop/shop/payment/service/PaymentService.java` — `cancel(long userId, long orderId)` 오케스트레이션(`@Transactional`) 추가. 의존 추가: 취소 전용 locked reader(order.spi)·`OrderCancellation`(order.spi). 흐름:
  1. **취소 전용 locked reader**로 orders row PESSIMISTIC_WRITE 잠금 + 소유권 404 + 스냅샷 획득(#4).
  2. 상태 판정(**권위·환불 전, #3**): `paid`→환불 경로 / `pending`→미결제 경로 / 이행단계(`preparing`/`shipping`/`delivered`)→`OrderCancellationConflictException`(409, **PG refund 호출 전 throw** — 부작용 없음) / 이미 `cancelled`/`refunded`→멱등 반환(`CancelResult` already, 환불·복원·위임 없음).
  3. (paid) `paymentRepository.findByOrderId` → `PaymentGatewayPort.refund(...)`(pgTransactionId·finalAmount·currency·idempotencyKey) → 성공 시 `Payment.markRefunded`. (pending) 결제 row 있으면 `Payment.markCancelled`, 없으면 결제 처리 없음.
  4. `OrderCancellation.cancel(orderId, userId, RefundInfo)`(RefundInfo = refunded 여부 + refundedAmount + currency)로 위임 → 종결 전이(refund 동반=markRefunded→refunded / 미결제=markCancelled→cancelled, #3) + 재고 복원 + `OrderCancelledEvent` 발행 → `CANCELLED`. **Outcome 검사(방어, #3)**: 2단계에서 이미 이행단계·종결을 걸렀으므로 같은 락 하에서 여기서 `REJECTED`/`ALREADY_CANCELLED`가 나오면 **락 불변식 위반** → `IllegalStateException`(500, 전체 롤백). (정상 흐름은 항상 `CANCELLED`.)
  5. 성공 시 `CancelResult` 반환(한 트랜잭션 원자 커밋 — #2).
  - 내부 record `CancelResult(long orderId, String orderNumber, String orderStatus, boolean refunded, long refundedAmount, String currency, boolean alreadyCancelled)` + 정적 팩토리 `cancelled(...)` / `refunded(...)` / `already(...)`.
- `shop-core/src/main/java/com/shop/shop/payment/service/PaymentServiceResponse.java` — `cancel(Authentication auth, long orderId) → OrderCancelResponse` 추가(REST). `userId=(long)auth.getPrincipal()` → `paymentService.cancel(userId, orderId)` → `CancelResult` → DTO 변환(200). 거부 예외(409/404)는 PaymentService가 트랜잭션 안에서 던지므로 그대로 전파(C1 비적용 — #2).
- `shop-core/src/main/java/com/shop/shop/payment/service/PaymentFacadeImpl.java` — `cancel(String email, long orderId)` 추가(View). `findUserIdByEmail(email)` → `paymentService.cancel` → 취소 결과 DTO. 거부 예외는 그대로 전파(View 핸들러가 `BusinessException` catch).
- `shop-core/src/main/java/com/shop/shop/payment/service/PaymentDtoMapper.java` — `CancelResult` → `OrderCancelResponse` 매핑 추가(필요 시).

#### (B) 수정 — payment/spi (View facade 계약)
- `shop-core/src/main/java/com/shop/shop/payment/spi/PaymentFacade.java` — `OrderCancelResponse cancel(String email, long orderId)` 시그니처 추가. javadoc: 성공 시 취소 결과 반환, 취소 불가 시 `OrderCancellationConflictException`(409, BusinessException) 전파.

#### (B) 수정 — payment/dto
- `shop-core/src/main/java/com/shop/shop/payment/dto/OrderCancelResponse.java` — 신규 record `OrderCancelResponse(long orderId, String orderNumber, String orderStatus, boolean refunded, long refundedAmount, String currency)`. REST 200 본문·View facade 반환 타입.

#### (B) 신규 — payment/controller (#1 — payment 모듈에 별도 컨트롤러)
- `shop-core/src/main/java/com/shop/shop/payment/controller/PaymentCancellationRestController.java`(**신규**) — **클래스 레벨 `@RestController @RequestMapping("/api/v1/orders/{orderId}/cancel")`** + `@PostMapping` 메서드 `cancel(@PathVariable long orderId, Authentication auth) → ResponseEntity<OrderCancelResponse>(200)`(`paymentServiceResponse.cancel` 위임).
  - **별도 컨트롤러로 두는 이유**: 기존 `PaymentRestController`의 클래스 매핑이 `/api/v1/orders/{orderId}/payment`라, 거기에 cancel 메서드를 추가하면 Spring이 클래스+메서드를 **결합**해 `.../payment/...`로 경로가 깨진다(절대경로 메서드 매핑 불가). 신규 컨트롤러로 클래스 매핑 자체를 `/cancel`로 분리한다. **기존 PaymentRestController 무변경(회귀 0).**
  - **order/controller에 두지 않는다**(#1 — `order → payment` 순환).

#### (B) 수정 — payment/domain
- `shop-core/src/main/java/com/shop/shop/payment/domain/Payment.java` — 의도 메서드 추가:
  - `markCancelled()`: `ready`/`failed`→`cancelled`. `paid`→`cancelled` 금지(`IllegalStateException` — 환불을 거쳐야 함). 이미 `cancelled`→멱등 no-op. `refunded`에서 호출 금지(IllegalStateException).
  - `markRefunded(String pgRefundId)`: `paid`→`refunded`. 이미 `refunded`→멱등 no-op. 그 외(`ready`/`failed`/`cancelled`)→`IllegalStateException`. pgRefundId 옵션 A 미영속(javadoc 명시, 옵션 B 대비).
  - javadoc 갱신: status 전이표에 `ready/failed→cancelled`(markCancelled), `paid→refunded`(markRefunded), `paid→cancelled` 금지 추가.

#### (B) 수정 — order/domain
- `shop-core/src/main/java/com/shop/shop/order/domain/Order.java` — 의도 메서드 추가:
  - `markCancelled()`: `pending`→`cancelled`. 이미 `cancelled`→멱등 no-op. 그 외(`paid`/이행단계/`refunded`)→`IllegalStateException`(상위에서 차단되므로 방어적).
  - `markRefunded()`: `paid`→`refunded`(#3). 이미 `refunded`→멱등 no-op. 그 외→`IllegalStateException`.
  - javadoc 갱신: markCancelled/markRefunded 전이 명시.

#### (B) 신규 — order/spi (취소 전용 locked reader + OrderCancellation)
- `shop-core/src/main/java/com/shop/shop/order/spi/OrderPaymentReader.java`(수정) — 취소 전용 locked 메서드 `OrderSnapshotView getOrderForCancel(long orderId, long requesterUserId)` 추가(orders row PESSIMISTIC_WRITE 잠금 + 소유권 404 + 스냅샷). javadoc: "취소 전용 — 환불 결정 전 호출(#4). 무락 getOrderSnapshot과 달리 orders row를 잠가 confirmPaid와 직렬화." 구현체 `OrderPaymentReaderImpl`에서 `orderRepository.findByIdForUpdate(orderId)` + 소유권 검증으로 구현(PaymentService.cancel의 쓰기 트랜잭션 안에서 호출 — 같은 트랜잭션 전파로 락 유효).
- `shop-core/src/main/java/com/shop/shop/order/spi/OrderCancellation.java`(신규) — published port:
  - `OrderCancellationResult cancel(long orderId, long requesterUserId, RefundInfo refundInfo)`.
  - `record RefundInfo(boolean refunded, long refundedAmount, String currency)`(payment가 환불 결정 후 전달).
  - `record OrderCancellationResult(long orderId, String orderNumber, Outcome outcome, String orderStatus, boolean eventPublished, Instant cancelledAt, String rejectedReason)`.
  - `enum Outcome { CANCELLED, ALREADY_CANCELLED, REJECTED }`(017 OrderConfirmation.Outcome 대칭).
  - javadoc: OrderConfirmation 대칭 — orders row(이미 locked reader가 잠금, 같은 트랜잭션) 권위 재검증(404/409) + 종결 전이(markCancelled/markRefunded, #3) + 재고 복원(inventory.spi.increase, variantId 오름차순, null skip+log) + OrderCancelledEvent 구성·발행. Entity 미노출(scalar record).

#### (B) 신규 — order/service
- `shop-core/src/main/java/com/shop/shop/order/service/OrderCancellationImpl.java`(신규, package-private, `@Service @Transactional @RequiredArgsConstructor`) — `OrderConfirmationImpl` 대칭:
  1. `orderRepository.findByIdForUpdate(orderId)` 권위 잠금(같은 트랜잭션이면 locked reader가 이미 잡은 락 재진입) + 소유권 404 재검증.
  2. status 분기: 이미 `cancelled`/`refunded`→`ALREADY_CANCELLED` 멱등 반환(재고 복원·이벤트 없음). 이행단계→`REJECTED`(rejectedReason). `pending`/`paid`→진행.
  3. 종결 전이: `refundInfo.refunded()`면 `Order.markRefunded()`(→refunded), 아니면 `Order.markCancelled()`(→cancelled) — #3.
  4. 재고 복원: `order.getItems()`에서 variantId 오름차순 정렬, null skip+log, 각 `inventoryStockPort.increase(variantId, quantity)`.
  5. `OrderCancelledEvent` 구성(member.spi 연락처 + product.spi productId 해석, refunded/refundedAmount/currency 포함, null variant 항목은 items 제외+log) → `publishEvent`(같은 트랜잭션 Outbox).
  6. `CANCELLED` 반환.
  - 의존: `OrderRepository`·`InventoryStockPort`·`MemberDirectory`·`ProductOrderCatalog`·`ApplicationEventPublisher`. amount long 변환 헬퍼(P3, OrderConfirmationImpl `toLong`과 동일).

#### (B) 신규 — order/event
- `shop-core/src/main/java/com/shop/shop/order/event/OrderCancelledEvent.java`(신규) — `@Externalized("order-cancelled")` record. 필드: `UUID eventId`, `Instant occurredAt`, `long orderId`, `String orderNumber`, `long memberId`, `String memberEmail`, `String memberName`, `List<Item> items`, `boolean refunded`, `long refundedAmount`, `String currency`, `Instant cancelledAt`. `record Item(long productId, String productName, int quantity)`. `public static final String TOPIC = "order-cancelled";`(OrderCompletedEvent 선례). event-catalog 스키마 그대로.

#### (B) 신규 — common/exception
- `shop-core/src/main/java/com/shop/shop/common/exception/OrderCancellationConflictException.java`(신규) — `extends BusinessException`, `super(message, HttpStatus.CONFLICT)`(409). javadoc: "이행단계(preparing/shipping/delivered) 취소 불가 — **부작용(환불·복원·이벤트) 발생 전 판정해 던진다**(#2, C1 비적용). 롤백할 부작용 없음." (기존 `OrderConfirmationConflictException` 재사용도 가능하나 의미 분리 위해 신규 — 메시지 명확화.)

#### (B) 수정 — security
- `shop-core/src/main/java/com/shop/shop/security/SecurityConfig.java` — REST 체인에 `.requestMatchers("/api/v1/orders/*/cancel").hasRole("CONSUMER")`(기존 `/payment` 라인 인접), View 체인에 `.requestMatchers("/orders/*/cancel").hasRole("CONSUMER")` 추가(016 결제 라인 선례 — `/**`가 이미 덮지만 의도 명시·회귀 방지).

#### (B) 무변경(확인만)
- `OrderConfirmation`/`OrderConfirmationImpl`(승인 경로) — 취소는 confirmPaid 미호출. 시그니처 무변경.
- `RestExceptionHandler`/`ViewExceptionHandler` — `BusinessException`(409/404) 기존 매핑 재사용, 신규 핸들러 불필요.
- 016/017 pay 경로(`pay`/`handleDeclined`/`acquireOrResolveReadyRow`) 무변경.

#### (B) 신규 — 테스트 (5절 매핑)
- `payment/domain/PaymentTest.java`(보강) — markCancelled/markRefunded 전이.
- `order/domain/OrderTest.java`(보강 또는 신규) — markCancelled/markRefunded 전이(#3).
- `payment/service/MockPaymentGatewayTest.java`(보강) — refund 결정성(항상 성공).
- `inventory/...`(보강) — VariantStock increase / InventoryStockPort.increase 비관락.
- `payment/service/PaymentServiceCancelTest.java`(신규, Mockito) — cancel 분기.
- `order/service/OrderCancellationImplTest.java`(신규) — 종결 전이·재고 복원·이벤트·멱등·REJECTED.
- `payment/service/OrderCancellationOutboxIntegrationTest.java`(신규, Testcontainers) — Outbox·재고 복원·원자성.
- `payment/service/OrderCancellationConcurrencyIntegrationTest.java`(신규, Testcontainers) — 동시 취소·취소vs결제.
- `payment/controller/PaymentRestControllerCancelSecurityTest.java`(신규) — 200/409/404·권한.
- `payment/PaymentModuleStructureTest`·`order` 구조 테스트(보강) — OrderCancelledEvent order 위치, payment↔order 순환 없음.

### 2.2 view-implementor 담당 범위

#### (V) 수정 — templates/order/detail.html
- `shop-core/src/main/resources/templates/order/detail.html` — 결제 영역 아래(또는 별도 취소 영역)에:
  - **취소 폼**: 취소 가능 상태(`pending`/`paid`)에서만 노출(`th:if`). `<form th:action="@{/orders/{orderId}/cancel(orderId=${order.orderId})}" method="post">` + "주문 취소" 버튼. 노출 조건은 `order.status in (pending,paid)` 직접 판정 또는 PaymentStatusView 기반(view-implementor가 명확한 쪽 채택).
  - **취소 후 상태 표시**: `order.status` 뱃지가 `cancelled`(취소됨)/`refunded`(환불됨)를 표시(기존 상태 뱃지 재사용, 필요 시 한글 라벨 매핑). 종결 상태(`cancelled`/`refunded`)·이행단계에서는 결제 폼·취소 폼 모두 미노출.

#### (V) 수정 — web/order
- `shop-core/src/main/java/com/shop/shop/web/order/OrderViewController.java` — `@PostMapping("/orders/{orderId}/cancel")` 핸들러 `cancel` 신규:
  - `try { var actor = currentActorResolver.resolve(auth); paymentFacade.cancel(actor.email(), orderId); redirectAttributes.addFlashAttribute("flashSuccess", "주문이 취소되었습니다."); } catch (BusinessException e) { redirectAttributes.addFlashAttribute("flashError", e.getMessage()); } return "redirect:/orders/" + orderId;`(pay 핸들러 패턴 재사용, web→payment.spi 단방향).

#### (V) 신규 — 테스트 (5절 매핑)
- `shop-core/src/test/java/com/shop/shop/view/OrderCancelViewRenderingTest.java`(신규, @SpringBootTest+MockMvc, @MockitoBean PaymentFacade/OrderFacade): 취소 버튼 노출(pending/paid)·미노출(cancelled/refunded/이행단계)·취소 성공 flashSuccess + `/orders/{id}` redirect·취소 불가(`OrderCancellationConflictException` 409) flashError + redirect.

---

## 3. 데이터 흐름

### 3.1 미결제 주문 취소 — REST (POST /api/v1/orders/{orderId}/cancel)
1. Security REST 체인 `/api/v1/orders/*/cancel` hasRole(CONSUMER). 비인증 401 JSON / ROLE 없음 403 JSON.
2. `PaymentCancellationRestController.cancel`(클래스 매핑 `/api/v1/orders/{orderId}/cancel`) → `PaymentServiceResponse.cancel(auth, orderId)` → `userId=(long)auth.getPrincipal()` → `PaymentService.cancel(userId, orderId)`(@Transactional).
3. ① **취소 전용 locked reader**(`getOrderForCancel`)로 orders row PESSIMISTIC_WRITE 잠금 + 소유권 404(#4) → 스냅샷 status=`pending`.
4. ② 상태 판정: `pending` → 미결제 경로.
5. ③ `paymentRepository.findByOrderId` → 결제 row 있으면 `Payment.markCancelled()`(ready/failed→cancelled), 없으면 결제 처리 없음. **PG refund 미호출.**
6. ④ `OrderCancellation.cancel(orderId, userId, RefundInfo(refunded=false, 0, "KRW"))` → 권위 재검증 → `Order.markCancelled()`(→cancelled) → 재고 복원(variantId 오름차순 increase, null skip+log) → `OrderCancelledEvent`(refunded=false, refundedAmount=0) 발행(Outbox) → `CANCELLED`.
7. ⑤ 원자 커밋(orders cancelled + payments cancelled? + product_variants stock 증가 + event_publication 1행). `CancelResult` 반환 → REST 200 + `OrderCancelResponse`.

### 3.2 결제완료 주문 취소 — REST
1~3. 3.1과 동일하나 locked reader 스냅샷 status=`paid`.
4. ② 상태 판정: `paid` → 환불 경로.
5. ③ `paymentRepository.findByOrderId` → `PaymentGatewayPort.refund(pgTransactionId, finalAmount, currency, idempotencyKey)` → 성공(mock 항상 성공, pgRefundId) → `Payment.markRefunded(pgRefundId)`(paid→refunded).
6. ④ `OrderCancellation.cancel(orderId, userId, RefundInfo(refunded=true, refundedAmount=longValueExact(finalAmount), "KRW"))` → `Order.markRefunded()`(→refunded, #3) → 재고 복원 → `OrderCancelledEvent`(refunded=true, refundedAmount) 발행 → `CANCELLED`.
7. ⑤ 원자 커밋(orders refunded + payments refunded + stock 증가 + event_publication 1행). REST 200.

### 3.3 주문 취소 — View (POST /orders/{orderId}/cancel)
1. Security View 체인 `/orders/*/cancel` hasRole(CONSUMER). 비인증 302/login.
2. `OrderViewController.cancel` → `currentActorResolver.resolve(auth).email()` → `PaymentFacade.cancel(email, orderId)`.
3. `PaymentFacadeImpl.cancel`: `findUserIdByEmail` → `PaymentService.cancel`(3.1/3.2 도메인 로직, **커밋**) → 성공 결과 반환 또는 거부 예외 전파.
4. 핸들러: 성공 → `flashSuccess("주문이 취소되었습니다.")` + `redirect:/orders/{orderId}`. `catch (BusinessException e)`(409 등) → `flashError(e.getMessage())` + redirect. 취소 후 상세는 `cancelled`/`refunded` 표시 + 폼 미노출.

### 3.4 멱등 재취소
1. 이미 `cancelled`/`refunded` 주문 재취소 → ① locked reader 스냅샷 status=`cancelled`/`refunded` → ② 멱등 분기(또는 ④ OrderCancellation이 `ALREADY_CANCELLED` 반환) → **PG refund 미호출, 재고 이중 복원 없음, 이벤트 추가 없음** → `CancelResult.already(...)` → REST/View 200(동일 결과).

### 3.5 동시 취소·취소 vs 결제 (orders row 락 직렬화 — #4)
- **동시 취소 2건**: 승자가 ① locked reader로 orders row 잠금 → 환불·복원·전이 → 커밋. 패자는 같은 orders row 락 대기 → 승자 커밋 후 status=`cancelled`/`refunded` 권위 관찰 → ② 멱등 분기(`ALREADY_CANCELLED`) → **1건만 복원/환불.** row 정합 유지.
- **취소 vs 결제 동시**: cancel의 locked reader(`findByIdForUpdate`)와 pay의 `OrderConfirmation.confirmPaid`(`findByIdForUpdate`)가 **같은 orders row PESSIMISTIC_WRITE를 두고 직렬화.** 한쪽이 끝난 뒤 다른 쪽이 권위 상태를 본다:
  - 결제 먼저 커밋 → 취소가 `paid` 관찰 → 환불 경로(정상).
  - 취소 먼저 커밋 → 결제(confirmPaid)가 `cancelled`/`refunded` 관찰 → `OrderConfirmation.Outcome.REJECTED`(비-pending) → PaymentService가 `OrderConfirmationConflictException`(409) 되던짐(결제 롤백). 모순 상태 없음.

### 3.6 OrderCancelledEvent 발행 경로 (Outbox, 004 메커니즘)
- `OrderCancellationImpl`(order 모듈)이 `ApplicationEventPublisher.publishEvent(orderCancelledEvent)`를 PaymentService.cancel의 트랜잭션 안에서 호출 → Modulith Registry가 `event_publication` INCOMPLETE 저장(Outbox) → 커밋 후 `spring-modulith-events-kafka`가 `@Externalized("order-cancelled")`로 Kafka 발행 → COMPLETED. 페이로드 자족(memberEmail/memberName/items/refunded/refundedAmount/currency/cancelledAt) — notification 역조회 불필요.

---

## 4. 예외 처리 전략 (error-response-rule 준수)

| 상황 | 발생 지점 | 예외/결과 | REST 매핑 | View 매핑 |
|---|---|---|---|---|
| **이행단계 취소 시도**(preparing/shipping/delivered) | PaymentService.cancel ②(locked reader 스냅샷, **PG refund 전**) | `OrderCancellationConflictException`(409) — **환불·복원·이벤트 발생 전 throw**(#2/#3) | 409 + ErrorResponse(상태·재고 불변, 환불·이벤트 없음) | flashError + `/orders/{id}` redirect |
| 타인/미존재 주문 | locked reader 소유권(404 존재 은닉) | `OrderNotFoundException`(404) | 404 존재 은닉 | error 뷰(404) |
| 이미 cancelled/refunded 재취소 | PaymentService.cancel ② 또는 OrderCancellation ALREADY_CANCELLED | **예외 아님** — 멱등 반환(복원·환불·이벤트 없음) | 200(동일 결과) | flashSuccess(또는 정보성) + redirect |
| 비정상 상태 전이(paid→cancelled 등) / **OrderCancellation이 2단계 선판정 후 REJECTED·ALREADY 반환(락 불변식 위반 — 정상 흐름 미발생, #3)** | Payment/Order.markCancelled/markRefunded · OrderCancellation 위임 | `IllegalStateException`(도메인/락 불변식) | 500 + 전체 롤백 | 500/error 뷰 |
| refundedAmount long 변환 위반(.00 아님/범위) | OrderCancellation 이벤트 변환(P3) | `AmountConversionException`(500) | 500 + 전체 롤백 | 500/error 뷰 |
| 환불 실패(실 PG) | PG refund | 본 Task mock 항상 성공 → 해당 없음(후속) | (후속) | (후속) |
| 시스템 오류(저장/발행/락) | 트랜잭션 내 임의 단계 | RuntimeException | 500 + **전체 롤백**(환불·복원·전이·이벤트 부분 반영 없음) | 500/error 뷰 |

핵심 규칙:
- **성공 = 원자 커밋 + 200(#2).** 환불·재고 복원·종결 전이·`OrderCancelledEvent`가 한 트랜잭션으로 부분 반영 없이 커밋된다.
- **거부(이행단계 409) = PaymentService 2단계(locked reader 스냅샷, PG refund 전)에서 throw(#2/#3, C1 비적용).** 환불·복원·이벤트가 아직 수행 전이라 트랜잭션 안에서 던져도 롤백할 부작용이 없다. OrderCancellation의 REJECTED는 같은 락 하 정상 흐름엔 발생하지 않고, 발생 시 불변식 위반 500이다. 017식 "결과 반환 후 커밋 후 매핑" 간접화를 적용하지 않는다.
- **타인 주문 = 404 존재 은닉**(016/017 통일).
- **멱등 재취소 = 200**(재고 이중 복원·환불 이중 호출·이벤트 추가 없음).
- **시스템 오류 = 500 전체 롤백**(부분 반영 없음).
- 응답·로그에 내부 PG 원문·스택트레이스 비노출(error-response-rule).
- 신규 예외 최대 1종(`OrderCancellationConflictException` 409, 또는 기존 `OrderConfirmationConflictException` 재사용). 404/500은 기존 재사용.

---

## 5. 검증 방법 (테스트 클래스 매핑 + Acceptance 매핑)

> 테스트 프로파일·Outbox 검증 방식은 016/017과 동일 — Testcontainers 별도 프로파일에서 `event_publication` 저장만 검증(외부화 `enabled=false`, 실 Kafka 라운드트립 범위 밖). PG refund 주입은 `PaymentGatewayPort` 모킹.

### 단위(자동) — PaymentTest / OrderTest
- `Payment.markCancelled`: `ready→cancelled`·`failed→cancelled` 허용 / `paid→cancelled` `IllegalStateException`(역전이 금지) / `cancelled→cancelled` 멱등.
- `Payment.markRefunded`: `paid→refunded` 허용 / `ready`·`failed`·`cancelled`에서 `IllegalStateException` / `refunded→refunded` 멱등.
- `Order.markCancelled`(#3): `pending→cancelled` 허용 / 그 외 `IllegalStateException` / 멱등.
- `Order.markRefunded`(#3): `paid→refunded` 허용 / 그 외 `IllegalStateException` / 멱등.
- 016/017 회귀: `markPaid`/`markFailed` 기존 전이 그린 유지.

### 단위(자동) — MockPaymentGatewayTest
- `refund` 결정성: 동일 입력(idempotencyKey) → 항상 `refunded=true` + **동일 `pgRefundId`**(`"MOCK-REFUND-"+idempotencyKey`). **같은 입력 2회 호출 시 pgRefundId 일치 단언**(UUID 미사용 — 무작위 아님).

### 단위(자동) — PaymentServiceCancelTest (Mockito)
- `paid` → `PaymentGatewayPort.refund` 호출(ArgumentCaptor) + `Payment.markRefunded` + `OrderCancellation.cancel(RefundInfo(refunded=true,...))` 위임 + 주문 refunded(#3).
- `pending` → refund **미호출** + (결제 row 있으면)`markCancelled` + `OrderCancellation.cancel(RefundInfo(refunded=false,0,...))` + 주문 cancelled.
- 이행단계(preparing/shipping/delivered) → 2단계에서 `OrderCancellationConflictException`(409), **refund·복원·이벤트·OrderCancellation 위임 미수행**(부작용 전 throw 검증).
- 멱등 재취소(cancelled/refunded) → 2단계 멱등 분기, refund·복원·이벤트 0회, `CancelResult.already`.
- 소유권 404(locked reader).
- (방어) `OrderCancellation.cancel`이 주입으로 `REJECTED` 반환 시 → `IllegalStateException`(500, 불변식 위반)으로 매핑(정상 흐름 미발생, #3).
- **#4 순서 검증**: 취소 전용 locked reader(`getOrderForCancel`)가 `PaymentGatewayPort.refund`보다 **먼저** 호출되는지(InOrder).

### 단위(자동) — OrderCancellationImplTest (Mockito 또는 통합)
- 종결 전이: refunded=true→`Order.markRefunded`, false→`Order.markCancelled`.
- 재고 복원: `inventoryStockPort.increase`가 variantId 오름차순·항목별 quantity로 호출. variantId null 항목 skip+log(복원·이벤트 items 모두 제외).
- `OrderCancelledEvent` 전 필드 매핑(memberEmail/memberName=member.spi, items.productId=product.spi, refunded/refundedAmount/currency/cancelledAt).
- 멱등(`ALREADY_CANCELLED`)·REJECTED(이행단계) Outcome.

### 통합 — Outbox·원자성 (Testcontainers, 별도 프로파일)
- `OrderCancellationOutboxIntegrationTest`:
  - 결제완료 취소 커밋 시 `event_publication`에 `OrderCancelledEvent` 1건 + payload 스키마(refunded=true/refundedAmount/currency/items) + `orders.status=refunded` + `payments.status=refunded` + **재고 복원(stock 증가)** 원자성.
  - 미결제 취소: `orders.status=cancelled` + (payments)`cancelled` + 재고 복원 + 이벤트(refunded=false).
  - 멱등 재취소: 재고 불변·이벤트 추가 없음.
  - 시스템 오류(강제 예외) 시 부분 반영 없음(orders/payments/stock/event_publication 원자 롤백).
  - 삭제된 variant(variant_id null) 포함 주문: 해당 항목 복원 skip, 나머지 정상 복원, 취소 성공, 이벤트 items에서 제외.

### 동시성 — (Testcontainers)
- `OrderCancellationConcurrencyIntegrationTest`:
  - 동시 취소 2건 → 1건만 복원/환불, `OrderCancelledEvent` 1건, 멱등(#4).
  - 취소 vs 결제 동시 → orders row 락 직렬화, 모순 상태 없음(둘 중 하나만 종결 반영, 다른 쪽은 권위 상태 관찰).

### REST/Security(자동) — PaymentRestControllerCancelSecurityTest (@SpringBootTest, MockMvc, @MockitoBean PaymentServiceResponse)
- `POST /api/v1/orders/{id}/cancel`: 성공 200 + `OrderCancelResponse`(주문 상태·환불 여부/금액). 이행단계 409 + ErrorResponse(내부정보 `jsonPath doesNotExist`). 타인/미존재 404. 멱등 재취소 200. ROLE_CONSUMER 권한(비인증 401/ROLE 없음 403).

### View(자동) — OrderCancelViewRenderingTest (@MockitoBean PaymentFacade/OrderFacade)
- `POST /orders/{id}/cancel` 성공 → flashSuccess + `/orders/{id}` redirect. 취소 불가(`OrderCancellationConflictException` 409) → flashError + redirect.
- detail.html: pending/paid에서 취소 버튼 노출, cancelled/refunded/이행단계에서 미노출. 취소 후 상태 표시(취소됨/환불됨).

### 구조(자동) — ModularityTests / Module 구조 테스트
- `OrderCancelledEvent`가 order 모듈(`com.shop.shop.order..`) 위치(발행 소유).
- payment↔order 순환 없음(payment→order.spi[OrderCancellation/locked reader]만, order→inventory.spi[increase]만). REST 취소 컨트롤러가 payment 모듈(#1).
- `ModularityTests.verify()` 통과. 015/016/017 회귀 없음.

### 실행 / 수동 확인
- `./gradlew test` 전체 통과(통합 Testcontainers 자동).
- (보조 수동) docker-compose 기동 후: 미결제 주문 취소 → orders `cancelled`·재고 복원·Kafka `order-cancelled`(refunded=false) 1건. 결제완료 주문 취소 → orders `refunded`·payments `refunded`·재고 복원·Kafka `order-cancelled`(refunded=true, refundedAmount) 1건. 이행단계 취소 → 409·상태/재고 불변. 확인/미확인 항목 작업 보고에 기록.

### Acceptance Criteria 매핑 표

| Acceptance(Task) | 검증 수단 |
|---|---|
| 미결제 취소 → cancelled + 재고 복원 + (결제 row)cancelled, refund 미호출 | PaymentServiceCancelTest·OrderCancellationOutboxIntegrationTest |
| 결제완료 취소 → 환불 성공 + payments refunded + 주문 refunded(#3) + 재고 복원 + OrderCancelledEvent Outbox | PaymentServiceCancelTest·OrderCancellationOutboxIntegrationTest |
| 이행단계 취소 → 409, 상태·재고 불변, 이벤트 미발행 | PaymentServiceCancelTest·PaymentRestControllerCancelSecurityTest·OrderCancellationOutboxIntegrationTest |
| 멱등 재취소 → 200, 재고 이중 복원 없음, 환불 이중 호출 없음 | PaymentServiceCancelTest·OrderCancellationOutboxIntegrationTest·OrderCancellationConcurrencyIntegrationTest |
| 타인 주문 → 404 존재 은닉 | PaymentServiceCancelTest·PaymentRestControllerCancelSecurityTest |
| 성공 원자 커밋 200 / 거부 부작용 전 409 / 시스템오류 전체 롤백(#2) | OrderCancellationOutboxIntegrationTest·PaymentRestControllerCancelSecurityTest |
| 삭제된 variant(null) 포함 취소 → skip+log, 나머지 복원, 성공 | OrderCancellationImplTest·OrderCancellationOutboxIntegrationTest |
| OrderCancelledEvent 페이로드 자족 | OrderCancellationImplTest·OrderCancellationOutboxIntegrationTest |
| locked reader가 환불보다 먼저(#4) + 동시 직렬화 | PaymentServiceCancelTest(InOrder)·OrderCancellationConcurrencyIntegrationTest |
| View 취소 버튼 노출/취소 후 상태/취소 불가 flashError | OrderCancelViewRenderingTest |
| order-cancelled가 event-catalog·architecture §5에 정의(문서 먼저) | 문서 diff 확인 |
| ModularityTests 통과(payment↔order 순환 없음), 015/016/017 회귀 없음 | ModularityTests·기존 테스트 전체 통과 |

---

## 6. 트레이드오프

- **payment 취소 오케스트레이션 소유(동기·단일 트랜잭션) vs 이벤트 기반 비동기 취소**: payment가 환불 후 order.spi로 위임하면 `payment → order.spi`(기존 방향)만 추가되어 순환이 없고(016/017 대칭) 환불·복원·전이·이벤트가 한 트랜잭션으로 원자 커밋된다. 비동기(이벤트로 취소 전파)는 약일관성·사가가 필요해 현 강일관성 대비 회귀 → 분리 시점까지 미룬다. 순환 회피 + 원자성 우선.
- **취소 전용 locked reader 추가(#4) vs 무락 getOrderSnapshot 재사용**: orders row PESSIMISTIC_WRITE 메서드(reader)가 하나 늘고 락 비용이 추가되지만, 환불 결정 전 직렬화로 "취소 vs 결제(confirmPaid) race"(환불/확정 모순)를 원천 차단한다. 무락 스냅샷 재사용은 판정과 전이 사이 상태가 바뀌어 환불 누락/이중 처리를 유발. 정합성 > 미세 락 비용.
- **order refunded 상태 채택(#3) vs 결제완료 취소도 cancelled 단일화**: 환불 동반 취소를 `refunded`로 종결하면 payment(`refunded`)와 의미가 정렬되고 재무 이력이 상태로 드러난다. `cancelled` 단일화는 미결제/환불 취소를 구분 못해 알림·정산에서 모호. 상태 정렬 우선(신규 컬럼 없이 기존 CHECK 값 사용).
- **C1 비적용(#2) vs 017식 간접화 답습**: 018은 성공=원자 커밋+200, 거부=부작용 전 판정이라 "영속+에러상태" 충돌이 없다. 017식 "결과 반환 후 커밋 후 트랜잭션 밖 매핑"을 그대로 답습하면 불필요한 간접화 한 겹이 늘 뿐이다 → 적용하지 않고, 거부는 트랜잭션 안에서 바로 던진다(롤백할 부작용 없음). 단순성 우선. 단 Outcome 값 모델링은 forward-compat 이음매 일관성 위해 유지.
- **mock refund 동기·항상 성공 vs 실 PG/실패 시뮬레이션**: 결정적(무작위 금지)·항상 성공으로 단위 테스트 재현성을 확보하고, 부작용 없어 트랜잭션 안 호출이 무해하다. 실 PG 환불(부분 환불·실패 재시도·비가역성 #5)은 멱등키+정산이 필요해 범위 밖 — 포트만 추가해 실 PG 어댑터로 교체 가능하게 둔다(포트 무변경).
- **markRefunded(pgRefundId) 옵션 A 미영속 vs 컬럼 추가(옵션 B)**: 신규 migration을 피하고 환불 ID/사유를 `OrderCancelledEvent`·응답에 싣는 것으로 Acceptance 충족(DB 재조회 요구 없음). 환불 이력 영속이 필요하면 후속 Task 옵션 B(`V_` migration). migration 무증가 우선(017 옵션 A 동형).
- **Outbox 통합은 event_publication 저장만 검증(실 Kafka 제외)**: 테스트 프로파일이 Kafka 자동설정 exclude(004 트레이드오프) → 실 브로커 외부화는 범위 밖. Outbox 원자성·payload 스키마는 Testcontainers 자동 검증, 실 Kafka E2E는 별도 Task/E2E.
- **부분취소·반품/교환·실 PG·TTL/만료·분산락·환불 사유 영속(신규 migration) 미구현**: Task Constraint 준수. 018은 **전체 주문 취소 + 모의 환불 + 재고 복원 + OrderCancelledEvent + View**까지. 이행단계(preparing/shipping/delivered) 취소(배송 중단·회수)는 409로 거부하고 배송 Task에서 다룬다.

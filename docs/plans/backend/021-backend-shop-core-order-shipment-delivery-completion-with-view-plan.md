# 021 — shop-core 주문 이행: 배송 완료(delivered) + 주문 rollup (with View) plan

> 대상: shop-core / Java 21 / Spring Boot 3.5.x / Spring Modulith / Thymeleaf / PostgreSQL
> 선행: 019(Shipment 모델 + `preparing` 생성), 020(`shipping` 전이 + `ShippingStartedEvent` + 소비자 배송 목록 합성), 018(취소·주문 row 락)
> 근거 문서: `docs/tasks/backend/021-backend-shop-core-order-shipment-delivery-completion-with-view.md`, 선행 plan `docs/plans/backend/020-...-plan.md`, revision `docs/plans/revisions/backend/021-...-revision-1.md`(정합1~5), `docs/plans/revisions/backend/021-...-revision-2.md`(정합6 — deliver 상태 재검증 순서: 멱등 delivered 우선)
> **본 plan은 구매확정·반품/교환·배송완료 알림 이벤트·신규 migration·라인 수량 분할을 다루지 않는다(범위 밖).**

---

## 0. 코드 대조 결과 / 확인 필요 항목

실제 코드를 읽어 확정한 사실과, Task 서술 대비 현재 코드 상태를 먼저 명시한다(추정 금지 원칙). 본 Task는 신규 파일이 적고 대부분 020 구조의 평행 확장이다.

| # | 확인 사실(코드 대조) | plan 반영 |
|---|---|---|
| C1 | `OrderFulfillmentService`(public, `@Transactional`, `@Service`)의 의존은 `OrderRepository`·`ShipmentRepository`·`MemberDirectory`·`ProductOrderCatalog`·`ApplicationEventPublisher` **5개**. `ship`(020)가 이 5개를 모두 쓴다. | `deliver`는 이벤트·member.spi·product.spi가 **불필요**(배송완료 이벤트 범위 밖, 연락처·productId 해석 불요). **신규 의존 주입 0** — 기존 `OrderRepository`·`ShipmentRepository`만 사용(Task Constraint: 불필요 의존 주입 금지). |
| C2 | `Shipment` 엔티티에 `deliveredAt`(`@Column(name="delivered_at")`, `Instant`, nullable) 컬럼·게터 **이미 존재**(019 선반영). `markShipping`만 있고 `markDelivered`는 주석으로 "021 소관" 표기, 미구현. | **신규 migration 불요**(Task Constraint 일치). `Shipment.markDelivered(Instant)` 추가만. |
| C3 | `Order`에 `markShipping`/`markPreparing`/`markPaid`/`markCancelled`/`markRefunded`는 있으나 `markDelivered`는 **없다**. `markShipping`은 단일 전이(`preparing→shipping`만, 그 외 `IllegalStateException`) 패턴. | `Order.markDelivered()`(`shipping→delivered`만, 그 외 `IllegalStateException`)를 `markShipping`과 **동형**으로 추가(정합4 — 멱등 아님). |
| C4 | `ShipmentResponse = {shipmentId, orderId, status, carrier, trackingNumber, shippedAt, items}` — **`deliveredAt` 없음**(020에서 shippedAt까지만). 생성 지점 **4곳**: `OrderFulfillmentService.createShipment`(L189) / `OrderFulfillmentService.toShipmentResponseWithDetails`(L251) / `OrderFulfillmentService.buildShipmentResponse`(L484, 020 ship 결과용) / `AdminOrderFulfillmentFacadeImpl.toShipmentResponseWithItems`(L159). | 정합3 — `deliveredAt`(nullable `Instant`) **1필드 추가** 후 **4곳 전부** 새 8-필드 시그니처로 갱신(`delivered`가 아니면 `shipment.getDeliveredAt()`이 null이므로 동일 게터 전달로 충분). |
| C5 | `ShipmentRepository`에 `findOrderIdById`(projection, 020 추가)·`findByOrderId`·`findAssignedOrderItemIds`·`findByOrderIdIn`·`findAssignedOrderItemIdsByOrderIdIn` 존재. `OrderRepository.findByIdForUpdate`(PESSIMISTIC_WRITE) 존재. | rollup 판정에 `findAssignedOrderItemIds(orderId)`(미배정 0 판정)·`findByOrderId(orderId)`(전 배송 delivered 판정) **재사용**. 신규 쿼리/Repository **추가 금지**(과설계 방지, Task Constraint). |
| C6 | `AdminShipmentRestController`(020 신설, package-private `@RestController`, 클래스 레벨 `@RequestMapping` **없음**)에 `POST /api/v1/admin/shipments/{shipmentId}/ship` 1개. | 정합2 — 같은 컨트롤러에 `POST /api/v1/admin/shipments/{shipmentId}/deliver` 추가(절대경로 `@PostMapping`, base path 일치). |
| C7 | `AdminShipViewController`(020 신설, `@Controller`, 클래스 레벨 매핑 **없음**)에 `POST /admin/shipments/{shipmentId}/ship` 1개. `@RequestParam` + `try/catch BusinessException` → flashSuccess/flashError + `redirect:/admin/orders` PRG. | 정합2/C3 — 같은 컨트롤러에 `POST /admin/shipments/{shipmentId}/deliver` 추가(deliver는 **입력 파라미터 없음** — `@RequestParam` 불요). |
| C8 | `AdminOrderFulfillmentFacade`(spi)에 `ship(long, String, String)` 존재, impl(`AdminOrderFulfillmentFacadeImpl`)이 서비스 위임. | `deliver(long shipmentId)`를 facade 인터페이스 + impl에 추가(서비스 위임, `BusinessException` 전파). **View 응답 모델은 `DeliverResponse`** (정합5). |
| C9 | `SecurityConfig`: restChain `/api/v1/admin/**`→`hasRole("ADMIN")`(L78), viewChain `/admin/**`→`hasRole("ADMIN")`(L126) **catch-all 존재**. | `/api/v1/admin/shipments/*/deliver`·`/admin/shipments/**` **자동 포함 → 신규 보안 규칙 불요**. plan은 "무변경 확인"만 명시(019/020 선례). |
| C10 | 소비자 상세 경로: `OrderViewController.orderDetail` → `OrderFacadeImpl.getMyOrder`(L145) → `orderService.getMyOrder`(소유권 검증, 타인/미존재 404) → `orderFulfillmentService.getShipments(orderId)`(L149) 합성 → `dtoMapper.toOrderResponse(detail, shipments)`(L150) → `OrderResponse.shipments`. **020에서 이미 배선 완료.** | 소비자 배송완료 표시는 **신규 합성 배선 불요**. `ShipmentResponse.deliveredAt`만 추가되면 `getShipments`가 자동 반영. 템플릿 표시만 추가. |
| C11 | **템플릿 현황**: `order/list.html`·`order/detail.html`·`admin/orders.html` 모두 status 라벨 매핑에 **`delivered → '배송 완료'`가 이미 존재**(019/020에서 선반영). `detail.html`은 `shipment.status == 'shipping'`일 때만 추적 블록 노출, `delivered`엔 `deliveredAt` 표시 블록 **없음**. `admin/orders.html`은 `s.status == 'preparing'`에만 ship 폼 노출, `delivered`엔 배송완료시각·완료 폼 표시 없음. | View 변경은 **최소**: ① `detail.html`에 `delivered` 배송완료시각 표시 블록 추가, ② `admin/orders.html`에 `s.status == 'shipping'`일 때 **배송 완료 폼** 추가 + `delivered`에 배송완료시각 표시, ③ `list.html`·status 라벨은 **무변경**(이미 `배송 완료` 매핑). |
| C12 | `OrderFulfillmentConflictException`(409, `BusinessException`)·`ShipmentNotFoundException`(404, `BusinessException`, 020 신설) 존재 → `RestExceptionHandler` 자동 매핑. | 잘못된 전이/취소·환불·비-shipping 주문 → `OrderFulfillmentConflictException`(409) **재사용**. 미존재 배송 → `ShipmentNotFoundException`(404) **재사용**. **신규 예외 클래스 0**. |

---

## 1. 설계 방식 및 이유

### 1.1 배송 완료 전이를 order 모듈에 두는 이유
- 배송(Shipment)은 019에서 `order` 모듈 소유로 정의됐다(`order/domain/Shipment`). 배송 완료는 배송 상태 전이 + 주문 rollup이므로 **order 모듈 책임**이다. 새 cross-module 의존을 만들지 않으며, **deliver는 020 `ship`보다 의존이 더 단순**하다(이벤트·member.spi·product.spi 없음 — C1).
- 이행 오케스트레이션은 019/020의 `OrderFulfillmentService`(public, `order/service`)에 `deliver` 메서드를 추가해 **020 `ship`의 락·서비스 구조를 그대로 재사용**한다. 신규 추상화·포트·Outcome enum을 도입하지 않는다(Task Constraint, 모순2 계승).

### 1.2 정합1 — stale read 차단(동시 `deliver` 핵심 설계, 020 계승)
- **문제**: 엔드포인트가 `/shipments/{shipmentId}/deliver`라 orderId를 모른다. shipment를 먼저 읽어야 주문 락을 걸 수 있는데, 락 대상(order)과 판정 대상(shipment)이 **다른 엔티티**다. shipment를 락 전에 **엔티티로** 적재하면, 멀티 배송 동시 `deliver` 시 두 번째 트랜잭션이 직렬화되더라도 **JPA 1차 캐시의 stale `shipping`** 으로 rollup·멱등 판정을 그르친다(직렬화는 "B가 A 이후 실행"만 보장, "B가 A 결과를 본다"는 보장하지 않음).
- **채택(020 `ship`과 동일 패턴)**:
  1. **orderId는 스칼라 projection으로만 조회** — `ShipmentRepository.findOrderIdById(shipmentId)` 재사용(`Optional<Long>`). `findById(...).getOrderId()` **금지**(엔티티가 락 전에 적재됨).
  2. 그 orderId로 **주문 row `PESSIMISTIC_WRITE` 잠금**(`OrderRepository.findByIdForUpdate` — 018 취소·동시 이행과 직렬화).
  3. **주문 락 보유 상태에서 비로소 shipment 엔티티 최초 적재**(`shipmentRepository.findById`)해 상태를 권위 재검증. 락 이전엔 어떤 경로로도 shipment를 엔티티로 로드하지 않았으므로 **항상 fresh**. rollup 판정 시 `findByOrderId(orderId)`로 같은 트랜잭션에서 재조회하면 방금 `markDelivered`한 shipment의 새 상태(managed 엔티티)가 반영된다.
- **경계 단서**: 컨트롤러/facade는 같은 트랜잭션에서 shipment를 미리 엔티티로 적재하지 않는다(REST 컨트롤러는 `shipmentId`만 path로 전달, 서비스가 전 과정 소유). 이 흐름이 정합1의 핵심 — 동시성 테스트가 "락 전 엔티티 적재 흐름이면 실패하도록" 설계된다(§5).

### 1.3 멱등 책임을 서비스가 소유 / 도메인 메서드는 단일 전이만(정합4)
- **도메인 메서드 `Shipment.markDelivered`는 `shipping→delivered`만 허용**, 그 외 상태(`preparing`/`delivered` 재호출/역방향)는 도메인 예외(`IllegalStateException` — `markShipping` 선례 동형). 메서드 자체는 멱등이 아니다.
- **멱등은 서비스가 단독 소유**: 서비스는 shipment가 `shipping`일 때만 `markDelivered`를 호출하고, **이미 `delivered`이면 호출 전에 현재 `DeliverResponse`를 `200`으로 반환**(상태 불변). `Order.markDelivered()`도 동일 — 서비스가 rollup 조건 충족 시에만 호출(이미 `delivered`면 호출되지 않음).
- **멱등 판정 키는 shipment 상태(`delivered`)뿐**: 이미 `delivered`인 배송에 재요청해도 상태·deliveredAt 변경 없이 현재 응답을 반환한다.
- **020과의 비대칭 — 멱등 체크를 방어 가드보다 앞에 두는 이유(revision-2 정합6 — 상태 재검증 순서 확정)**: 020 `ship`에선 멱등 상태(shipment=`shipping`)가 **항상** 주문 `shipping`과 일치해 방어 가드 뒤에 멱등 체크를 둬도 무방했다. 그러나 021 `deliver`에선 멱등 상태(shipment=`delivered`)가 단일 배송/마지막 배송 rollup으로 **주문 `delivered`와 일치할 수 있다**. 방어 가드(`order.status != "shipping"` → 409)를 멱등 체크보다 먼저 두면, 이미 `delivered`로 rollup된 주문의 배송을 재-deliver할 때 가드가 먼저 409를 던져 멱등 200에 도달하지 못한다. 따라서 **멱등 `delivered` 체크를 방어 가드보다 먼저** 둔다(§3.1 step 2 순서, Acceptance Criteria "같은 배송 deliver 중복 → 멱등 200, 상태 불변"과 정합. revision-2가 task line 47·revision-1 §6의 옛 "방어 가드 → 멱등" 순서를 이 순서로 supersede).

### 1.4 rollup 판정 정확성(기존 쿼리 재사용)
- **단조 전진 종착점**: 주문 `shipping → delivered`는 **(a) 모든 order_items가 배송에 배정 && (b) 모든 배송이 `delivered`** 두 조건을 동시 충족할 때만. 아니면 주문 status 불변(`shipping` 유지 — 부분 배송 완료는 `shipping`에 접힘, 새 상태값 없음).
- **(a) 미배정 항목 0 판정**: `order.getItems()`(전 항목 id 집합) − `ShipmentRepository.findAssignedOrderItemIds(orderId)`(배정된 order_item_id 집합)에 차집합이 비면 전 항목 배정. 미배정 항목이 하나라도 있으면 주문은 아직 `delivered`가 아니다(일부 항목이 배송 생성조차 안 됨).
- **(b) 전 배송 delivered 판정**: `ShipmentRepository.findByOrderId(orderId)`로 그 주문의 모든 배송을 같은 트랜잭션에서 재조회 → 전부 status가 `delivered`인지. 방금 `markDelivered`한 shipment는 managed 엔티티라 재조회 결과에 새 `delivered` 상태로 반영된다(정확).
- **신규 쿼리/Repository 추가 금지**: 위 두 쿼리는 019/createShipment에서 이미 쓰는 기존 메서드다. `OrderItemRepository`도 불요(`order.getItems()` 사용 — C5).

### 1.5 거부 = 직접 throw, 멱등 = 200, Outcome 미채택(모순2 계승)
- 잘못된 전이(`preparing`/역방향)·취소·환불·비-shipping 주문은 부작용 전 `OrderFulfillmentConflictException`(409) **직접 throw**. 미존재 배송은 `ShipmentNotFoundException`(404). **이미 `delivered`(멱등)은 현재 상태를 `200`으로 반환**. 018 Outcome 값-매핑은 payment→order.spi cross-module 경계 때문이었고, 이행 서비스는 order 모듈 **내부 직접 호출**이라 indirection을 두지 않는다.

### 1.6 정합5 — 주문 종착 여부는 deliver 전용 응답 래퍼로 분리(공유 DTO 오염 금지)
- 주문이 `delivered`로 종착했는지는 **`DeliverResponse(ShipmentResponse shipment, boolean orderDelivered)`** 라는 **deliver 엔드포인트 전용 래퍼**로 표현한다. 공유 DTO인 `ShipmentResponse`(ship 응답·소비자 `OrderResponse.shipments`·admin facade 공용 — 생성 지점 4곳)에 **주문 단위 일시 플래그를 넣지 않는다**. 소비자 배송 목록 각 항목에 `orderDelivered`가 붙으면 `order.status`와 중복되고 의미가 어색하다.
- `orderDelivered`는 **전이 발생 여부가 아니라 현재 주문 status가 `delivered`인지**로 계산(`"delivered".equals(order.getStatus())`). 멱등 재완료(이미 delivered)도 일관되게 `true`를 반환한다. 거부 분류용 Outcome enum이 아니라 성공 응답의 스칼라 플래그(Entity 미노출 record)다.

### 1.7 deliver는 이벤트·member.spi·product.spi 의존 없음
- 배송완료 이벤트는 범위 밖(카탈로그 미정의)이라 `ApplicationEventPublisher`/연락처 해석/productId 해석(P2)이 모두 불필요하다. deliver는 020 `ship`보다 서비스 의존이 단순하다(`OrderRepository`·`ShipmentRepository`만 사용 — 새 의존 주입 0, C1).

---

## 2. 구성 요소 (레이어별 신규/수정 + 정확한 경로/시그니처)

### domain (수정, backend-implementor)
- **`order/domain/Shipment.java`** — 메서드 추가(`markShipping` 바로 아래, L141 주석 자리):
  ```java
  /** shipping → delivered 만 허용. 그 외 상태는 IllegalStateException(멱등 책임은 서비스 소유, 정합4). */
  public void markDelivered(Instant deliveredAt) {
      if (!"shipping".equals(this.status)) {
          throw new IllegalStateException(
                  "배송 상태가 shipping이 아니어서 delivered로 전이할 수 없습니다. 현재 상태: " + this.status);
      }
      this.status = "delivered";
      this.deliveredAt = deliveredAt;
  }
  ```
  > `deliveredAt` 컬럼·게터는 이미 존재(C2). Setter 금지·의도 메서드 패턴 준수.
- **`order/domain/Order.java`** — 메서드 추가(`markShipping` 옆):
  ```java
  /** rollup shipping → delivered 만 허용. 그 외(이미 delivered 포함)는 IllegalStateException.
   *  서비스가 rollup 조건 충족 && 주문이 shipping일 때만 호출(정합4 — 멱등 아님). */
  public void markDelivered() {
      if (!"shipping".equals(this.status)) {
          throw new IllegalStateException(
                  "주문 상태가 shipping이 아니어서 delivered로 전이할 수 없습니다. 현재 상태: " + this.status);
      }
      this.status = "delivered";
  }
  ```
  > `markShipping`(C3)과 동형. 멱등 no-op 아님 — 서비스가 "주문이 `shipping`이고 rollup 조건 충족"일 때만 호출, 이미 `delivered`면 멱등 경로에서 호출 자체 생략.

### dto (신규/수정, backend-implementor)
- **`order/dto/DeliverResponse.java`**(신규, 정합5):
  ```java
  /**
   * 배송 완료(deliver) 전용 응답 래퍼.
   * shipment: 갱신된 배송(status=delivered, deliveredAt 채워짐).
   * orderDelivered: 현재 주문 status가 delivered인지(전이 발생 여부 아님 — 멱등 재완료도 일관).
   * 공유 DTO ShipmentResponse에 주문 단위 플래그를 넣지 않기 위해 분리(공유 DTO 오염 금지).
   */
  public record DeliverResponse(ShipmentResponse shipment, boolean orderDelivered) {}
  ```
- **`order/dto/ShipmentResponse.java`**(수정, 정합3) — `deliveredAt` 1필드 추가(`shippedAt` 다음):
  ```java
  public record ShipmentResponse(
          long shipmentId, long orderId, String status,
          String carrier, String trackingNumber, Instant shippedAt,
          Instant deliveredAt,                         // 신규(정합3, nullable — delivered 아니면 null)
          List<ShipmentItemResponse> items) {}
  ```
  > **생성 지점 4곳 전수 갱신**(C4, 컴파일 완결성): ① `OrderFulfillmentService.createShipment`(L189, preparing → `null`) ② `OrderFulfillmentService.toShipmentResponseWithDetails`(L251, `shipment.getDeliveredAt()`) ③ `OrderFulfillmentService.buildShipmentResponse`(L484, `shipment.getDeliveredAt()`) ④ `AdminOrderFulfillmentFacadeImpl.toShipmentResponseWithItems`(L159, `shipment.getDeliveredAt()`). 게터가 이미 존재하므로 ②③④는 `shipment.getDeliveredAt()` 인자만 끼우면 된다(`delivered` 아니면 자동 null).

### service (수정, backend-implementor)
- **`order/service/OrderFulfillmentService.java`** — **의존 변경 없음**(기존 5개 그대로, deliver는 `OrderRepository`·`ShipmentRepository`만 사용 — C1):
  - 메서드 추가: `public DeliverResponse deliver(long shipmentId)`(`@Transactional` 클래스 레벨 적용됨). 흐름은 §3.1.
  - private 헬퍼: 기존 `buildShipmentResponse(Shipment, Order)`(L469) **재사용**(deliveredAt 추가 후 자동 반영). rollup 판정 헬퍼는 인라인 또는 `private boolean isOrderFullyDelivered(Order order, long orderId)` 1개 추가(가독성 — `order.getItems()` − `findAssignedOrderItemIds` && `findByOrderId` 전부 delivered).
  - `createShipment`·`toShipmentResponseWithDetails`·`buildShipmentResponse`의 `new ShipmentResponse(...)` 호출 **3곳**을 새 8-필드 시그니처로 갱신(C4).
- **`order/service/AdminOrderFulfillmentFacadeImpl.java`** — `toShipmentResponseWithItems`의 `new ShipmentResponse(...)`(L159) 1곳 갱신(C4) + `deliver(long shipmentId)` 오버라이드 추가(서비스 `deliver` 위임, `@Transactional`, `BusinessException` 전파). **반환 타입 `DeliverResponse`**.
  - **정합7(revision-3 — E2E 발견 결함)**: `FULFILLABLE_STATUSES`에 `"shipping"` 추가(`["paid","preparing","shipping"]`). 배송을 ship하면 020 rollup으로 주문이 `shipping`이 되는데, 옛 `["paid","preparing"]`은 그 주문을 `/admin/orders` 목록에서 제외해 **배송 완료 버튼이 렌더되지 않는다(도달 불가)**. 이행 목록은 미종결 주문 전체(`paid`/`preparing`/`shipping`)를 표시해야 한다. 상세는 `docs/plans/revisions/backend/021-...-revision-3.md`.

### controller (수정, backend-implementor)
- **`order/controller/AdminShipmentRestController.java`**(수정, 정합2 — 020 신설 컨트롤러에 추가):
  ```java
  /** 배송 완료. POST /api/v1/admin/shipments/{shipmentId}/deliver
   *  shipping → delivered 전이 + deliveredAt 기록 + 주문 rollup 판정.
   *  이미 delivered면 멱등 200(상태 불변). 입력 본문 없음. */
  @PostMapping("/api/v1/admin/shipments/{shipmentId}/deliver")
  ResponseEntity<DeliverResponse> deliver(@PathVariable long shipmentId) {
      return ResponseEntity.ok(orderFulfillmentService.deliver(shipmentId));
  }
  ```
  > base path가 `ship`과 동일(`/api/v1/admin/shipments/...`)이라 **같은 컨트롤러에 추가**(정합2). 비즈니스 로직 없음. `@RequestBody` 없음(deliver는 입력 없음).

### spi / facade (수정, backend-implementor — View 계약)
- **`order/spi/AdminOrderFulfillmentFacade.java`**(수정) — 메서드 추가:
  ```java
  /** 배송 완료 위임(021). OrderFulfillmentService.deliver에 위임.
   *  성공/멱등 시 DeliverResponse 반환, 거부 시 BusinessException(404/409) 전파. */
  DeliverResponse deliver(long shipmentId);
  ```
- **`order/service/AdminOrderFulfillmentFacadeImpl.java`** — 구현 추가(위 service 항목에 포함).

### repository (변경 없음 — 확인만, backend-implementor)
- **`order/repository/ShipmentRepository.java`** — `findOrderIdById`·`findByOrderId`·`findAssignedOrderItemIds` **기존 메서드로 충분**. **신규 쿼리/Repository 추가 금지**(과설계 방지, C5).

### web / template (view-implementor)
- **`web/order/AdminShipViewController.java`**(수정, 정합2/C3 — 020 신설 컨트롤러에 추가):
  ```java
  /** 배송 완료 폼 제출. POST /admin/shipments/{shipmentId}/deliver
   *  성공 → flashSuccess + redirect:/admin/orders. BusinessException catch → flashError + redirect. */
  @PostMapping("/admin/shipments/{shipmentId}/deliver")
  public String deliver(@PathVariable long shipmentId, RedirectAttributes ra) {
      try {
          adminOrderFulfillmentFacade.deliver(shipmentId);
          ra.addFlashAttribute("flashSuccess", "배송이 완료 처리되었습니다.");
      } catch (BusinessException e) {
          log.warn("배송 완료 실패: shipmentId={}, reason={}", shipmentId, e.getMessage());
          ra.addFlashAttribute("flashError", e.getMessage());
      }
      return "redirect:/admin/orders";
  }
  ```
  > deliver는 입력 파라미터 없음 → `@RequestParam` 불요(ship과 차이). `AdminOrderViewController`(`@RequestMapping("/admin/orders")`)는 클래스 매핑 결합 문제로 사용 불가 → 클래스 매핑 없는 `AdminShipViewController`에 추가(C3). `ship` 핸들러 PRG·flash 패턴 복제.
- **`templates/admin/orders.html`**(수정) — 배송 현황 블록 내부:
  - `s.status == 'shipping'` 추적 블록(현재 carrier/trackingNumber/shippedAt 표시) 하단에 **배송 완료 폼** 추가: `th:if="${s.status == 'shipping'}"`, `POST /admin/shipments/{shipmentId}/deliver`(절대경로, `th:action` 자동 CSRF), 입력 없는 단일 버튼("배송 완료").
  - `s.status == 'delivered'`일 때 **배송완료시각 표시 블록** 추가(`s.deliveredAt != null` → Asia/Seoul 포맷, 읽기 전용). status 라벨(`배송 완료`)은 이미 존재(C11) — 무변경.
- **`templates/order/detail.html`**(수정) — 배송 목록 블록(L211~)에서 `shipment.status == 'shipping'` 추적 블록 옆에 `shipment.status == 'delivered'` 분기 추가: **배송완료시각**(`shipment.deliveredAt != null` → Asia/Seoul 포맷) 표시. status 라벨(`배송 완료`)은 이미 존재(C11). 소비자 응답에 `seller_id`/`ownerId`/내부정보 미노출.
- **`templates/order/list.html`**(무변경 확인) — rollup `배송 완료` 라벨은 status 매핑에 **이미 존재**(C11). 변경 불요.

### security (무변경 확인, C9 — backend-implementor)
- `SecurityConfig` L78/L126 catch-all이 `/api/v1/admin/shipments/*/deliver`·`/admin/shipments/**`를 자동 포함 → **신규 규칙 불요**. plan/PR 설명에 "catch-all로 커버됨" 1줄 명시.

### docs (변경 없음)
- 배송완료 이벤트가 없으므로 `event-catalog.md`·`architecture.md §5` 변경 불요.

---

## 3. 데이터 흐름

### 3.1 REST/Facade `deliver` 핵심 흐름 (`OrderFulfillmentService.deliver(shipmentId)`)
1. **(정합1 락 순서)** ① `shipmentRepository.findOrderIdById(shipmentId)` — 스칼라 projection. empty → `ShipmentNotFoundException`(404). ② `orderRepository.findByIdForUpdate(orderId)` — **주문 row 잠금**(empty → `OrderNotFoundException` 방어). ③ **락 후** `shipmentRepository.findById(shipmentId)` — shipment 엔티티 **최초 적재**(fresh 재검증).
2. **상태 재검증(락 보유) — 멱등 체크가 방어 가드보다 반드시 앞(revision-2 정합6 확정 순서)**:
   1. 주문이 `cancelled`/`refunded` → `OrderFulfillmentConflictException`(409, 취소·환불 주문).
   2. **shipment가 이미 `delivered` → 멱등 200**: `markDelivered` 호출 없이 현재 상태로 `DeliverResponse` 반환(`orderDelivered = "delivered".equals(order.getStatus())`). **order 상태와 무관하게 멱등 우선** — 방어 가드보다 **앞**에 둔다(단일/마지막 배송 rollup으로 주문이 이미 `delivered`인 배송을 재-deliver해도 멱등 200에 도달해야 하므로, §1.3 멱등 판정 키=shipment 상태뿐과 일치).
   3. **방어 가드(020 계승)**: 정상 흐름에서 (delivered가 아닌) 배송이 `shipping`이면 주문도 `shipping`이어야 하므로, `order.status != "shipping"`이면 `409`(불변식 위반 조기 차단). 이 지점 도달 시 shipment는 `delivered`가 아님(2에서 걸러짐).
   4. shipment가 `shipping`이 아님(`preparing`/역방향) → `409`.
   5. shipment가 `shipping`이면 진행.
3. **시각 1회 캡처**: `Instant now = Instant.now()`(deliveredAt). `shipment.markDelivered(now)`.
4. **rollup 판정(기존 쿼리 재사용)**:
   - (a) `order.getItems()`의 id 집합 − `shipmentRepository.findAssignedOrderItemIds(orderId)` → 미배정 0인지.
   - (b) `shipmentRepository.findByOrderId(orderId)` → 전 배송 status가 `delivered`인지(방금 markDelivered한 managed 엔티티 반영).
   - (a) && (b) 충족이고 `order.status == "shipping"`이면 `order.markDelivered()`. 아니면 주문 status 불변(`shipping` 유지 — 부분 배송 완료).
5. **응답 구성**: `orderDelivered = "delivered".equals(order.getStatus())`(전이 후 현재 status). `new DeliverResponse(buildShipmentResponse(shipment, order), orderDelivered)`.
6. 커밋(전이+rollup 원자) → 컨트롤러가 `200` + `DeliverResponse` 반환.

### 3.2 REST `deliver` 흐름 (`POST /api/v1/admin/shipments/{shipmentId}/deliver`)
1. SecurityConfig restChain `/api/v1/admin/**` → `hasRole("ADMIN")`(비인증 401, 비ADMIN 403).
2. `AdminShipmentRestController.deliver(shipmentId)` — 입력 본문 없음. 서비스 위임.
3. §3.1 → `200` + `DeliverResponse`. 거부 시 `BusinessException` → `RestExceptionHandler` → `ErrorResponse`(409/404).

### 3.3 View admin 폼 흐름 (`POST /admin/shipments/{shipmentId}/deliver`)
1. SecurityConfig viewChain `/admin/**` → `hasRole("ADMIN")`(비인증 `/login` 302, 비ADMIN 403). CSRF 폼 토큰(`th:action`).
2. `AdminShipViewController.deliver` → `adminOrderFulfillmentFacade.deliver(shipmentId)` → 서비스(§3.1).
3. 성공 → flashSuccess + `redirect:/admin/orders`. `BusinessException`(409/404) catch → flashError + redirect(부작용 없음).

### 3.4 소비자 detail 표시 흐름 (`GET /orders/{orderId}`) — 신규 배선 없음(C10)
1. `OrderViewController.orderDetail` → `OrderFacadeImpl.getMyOrder(email, orderId)` → 소유권 검증(타인/미존재 404) → `orderFulfillmentService.getShipments(orderId)` 합성(020 기존) → `OrderResponse.shipments`.
2. `getShipments`는 `toShipmentResponseWithDetails`로 변환 — `deliveredAt` 추가 후 자동 반영(C4).
3. `detail.html`이 `delivered` 배송에 배송완료시각 표시. 주문이 `delivered`면 헤더 status 라벨 `배송 완료`(이미 존재). 내부정보 미노출.

### 3.5 DeliverResponse payload 출처

| 필드 | 출처 |
|---|---|
| `shipment.status` | `delivered`(전이 후) 또는 멱등 시 기존 `delivered` |
| `shipment.deliveredAt` | 캡처한 `now`(전이 시) 또는 멱등 시 기존 값 |
| `shipment.carrier/trackingNumber/shippedAt` | 020에서 기록된 기존 값(deliver는 변경 안 함) |
| `orderDelivered` | `"delivered".equals(order.getStatus())` — **현재 status**(전이 발생 여부 아님, 멱등 일관) |

---

## 4. 예외 처리 전략

| 상황 | HTTP | 메커니즘 | 비고 |
|---|---|---|---|
| 미존재 배송 | `404` | `findOrderIdById` empty → `ShipmentNotFoundException`(재사용, C12) | 관리자 경로 — 존재 은닉 불요 |
| 잘못된 전이(`preparing`/역방향) | `409` | shipment status가 `shipping`/`delivered`가 아니면 직접 throw `OrderFulfillmentConflictException`(재사용) | 부작용 전 판정 |
| 취소·환불 주문의 deliver | `409` | 락 후 `order.status ∈ {cancelled, refunded}` 재검증 → `OrderFulfillmentConflictException` | 018 상호작용·모순 방지 |
| 이미 `delivered`(멱등) | `200` | **예외 아님** — `markDelivered` 미호출, 현재 `DeliverResponse` 반환(상태 불변) | 멱등 키=shipment 상태뿐(정합4). **방어 가드보다 우선** — shipment가 `delivered`면 주문이 `delivered`여도 멱등 200(가드 409 아님) |
| 비-shipping 주문(방어 가드) | `409` | shipment가 `delivered`가 아닌데도 `order.status != "shipping"` → `OrderFulfillmentConflictException` | 불변식 위반 조기 차단(020 계승). **멱등 `delivered` 체크 이후** 평가(§3.1 step 2 순서) |
| 성공 | `200` | 전이+rollup 원자 커밋 + `DeliverResponse` | |
| 시스템 오류 | `500` 롤백 | 정상 흐름 미발생, 전체 롤백(상태) | 부분 반영 없음 |

- **직접 throw vs 멱등 200 기준(모순2/정합4)**: 잘못된 전이·취소/환불·비-shipping = **직접 throw 409**(부작용 전). 이미 `delivered` = **멱등 200**. 입력 본문이 없으므로 400 케이스 없음. **평가 순서상 멱등 `delivered` 200이 방어 가드 409보다 먼저** — 단일/마지막 배송 rollup으로 주문이 `delivered`인 배송의 재-deliver도 멱등 200으로 귀결(§1.3 비대칭, §3.1 step 2).
- **Outcome 미채택(정합5)**: 거부 분류용 Outcome enum을 두지 않는다 — order 모듈 내부 직접 호출이라 indirection 불요. `orderDelivered`는 성공 응답의 스칼라 플래그(거부 분류 아님).
- **View**: `AdminShipViewController.deliver`는 `BusinessException` catch → flashError + redirect(부작용 없음, JSON 미반환 — error-response-rule).
- **REST**: 모든 예외는 `BusinessException` 계층 → `RestExceptionHandler` 자동 매핑. 응답에 Entity·ownerId·로컬경로 미포함, `status` lowercase.

---

## 5. 검증 방법 (testing-rule / verification-gate-rule)

### 단위 (JUnit5 + Mockito)
- **`ShipmentTest`**: `markDelivered` — `shipping→delivered` 허용(deliveredAt 기록), `shipping` 외(`preparing`/`delivered` 재호출/역방향) `IllegalStateException`(정합4 — 멱등 아님).
- **`OrderTest`**: `markDelivered()` — `shipping→delivered` 허용, 그 외(`paid`/`preparing`/`delivered`/`cancelled` 등) `IllegalStateException`.
- **`OrderFulfillmentServiceTest`**(Mockito):
  - `deliver` `shipping→delivered` + **rollup 판정**: 단일 배송 완료 시 주문 `delivered` / 멀티 배송 일부 완료 시 `shipping` 유지 / 미배정 항목 있으면 `shipping` 유지 / 마지막 배송 완료 시 `delivered`.
  - 잘못된 전이(`preparing`/역방향) → 409, **취소/환불·비-shipping 주문** → 409(방어 가드).
  - 멱등 재호출: 이미 `delivered` → `markDelivered` **미호출**·상태 불변, 동일 `DeliverResponse` 200.
  - **단일 배송 주문 재-deliver(주문이 이미 `delivered`로 rollup된 상태) → 멱등 200, `markDelivered` 미호출, 방어 가드 409 아님**(멱등 체크가 방어 가드보다 먼저 — §1.3 비대칭/§3.1 step 2 순서 검증). `orderDelivered=true`.
  - **정합1 락 순서**: `InOrder`로 `findOrderIdById` → `findByIdForUpdate` → `findById(shipment)` 호출 **순서** 단언(shipment 엔티티 적재가 주문 락보다 **뒤**). "락 전 shipment 적재" 흐름이면 실패하도록.
  - `DeliverResponse.orderDelivered`가 **현재 주문 status** 반영(전이 시 true, 부분 완료 시 false, 멱등 재완료 시 true).
  - 미존재 배송 → `ShipmentNotFoundException`(404). **이벤트/member/product 미호출**(deliver는 의존 안 씀).

### 통합 (Testcontainers + Modulith)
- deliver 커밋 시 shipment·주문 status 전이 **원자성**. 멀티 배송 마지막 완료가 주문 `delivered` 트리거. 미배정 항목 시 `shipping` 유지. 멱등 재호출 상태 불변. **단일 배송 주문이 `delivered`로 rollup된 뒤 같은 배송 재-deliver → 멱등 200, 주문·shipment 불변(방어 가드 409 아님)**.
- **이벤트 미발행**: 이 단계는 `event_publication` **무변화**(배송완료 이벤트 없음 — 020 회귀 확인).
- 시스템 오류 시 부분 반영 없음(상태 전체 롤백).

### 동시성 (Testcontainers)
- 멀티 배송 마지막 2건 동시 `deliver` → 주문 row 락 직렬화 + **락 후 shipment fresh 재조회(정합1)** 로 주문 rollup **한 번만** `delivered`로 전이(stale `shipping`으로 인한 중복 rollup·오판 없음).
- 배송 완료 vs `018` 취소 동시 → 주문 row 락 직렬화, 모순 없음.

### REST/Security (MockMvc 슬라이스)
- deliver 200(`DeliverResponse`) / 잘못된 전이 409 / 미존재 404. ADMIN 200·비인증 401·비ADMIN 403. 응답 내부정보(Entity/ownerId/seller_id) 비노출, `status` lowercase.

### View (MockMvc / Thymeleaf 렌더)
- admin 배송 완료 폼(CSRF) 렌더링(`shipping` 배송), 성공 redirect+flashSuccess, 불가 flashError. `delivered` 배송 배송완료시각 표시.
- 소비자 상세 `delivered` 배송완료시각 표시, 목록 `배송 완료` 라벨(주문 delivered). 비인증 admin `/login` redirect. 타인 주문 404.

### 구조 (ArchUnit / Modulith)
- 배송 완료 코드 order 모듈 위치, payment.spi/payment 미의존, `web.order` 도메인 내부 직접 참조 안 함, `ModularityTests.verify()` 통과.

### 실행 커맨드 / 게이트 (verification-gate-rule)
- `./gradlew :shop-core:compileJava` — `ShipmentResponse` 8필드 변경의 **4개 생성 지점** 컴파일 그린 확인.
- `./gradlew :shop-core:test`(전체) — 016/018/019/020 회귀 0 확인.
- 모든 테스트 그린 + `ModularityTests` 그린이 머지 게이트.

---

## 6. 트레이드오프

- **정합1: orderId projection + 락 후 적재 채택**(020 동일) vs `EntityManager.refresh()` vs shipment 행 직접 `FOR UPDATE`. projection 방식이 **구조적 정확성**("락 전엔 shipment 엔티티 적재 불가")으로 가장 견고하고, 020과 동일 패턴이라 학습·테스트 자산을 재사용한다.
- **`ShipmentResponse` 단일 DTO 재사용 + `deliveredAt` 1필드 추가** vs `delivered` 전용 DTO 분리. 단일 재사용은 생성 지점 4곳 컴파일 파급이 있으나 DTO 종류·매핑 분기를 늘리지 않고, `delivered`가 아닌 배송은 null로 충분. 분리는 매핑이 배가되어 과설계 → 미채택(정합3).
- **정합5: `DeliverResponse` 전용 래퍼로 `orderDelivered` 표현** vs 공유 `ShipmentResponse`에 플래그 추가. 공유 DTO에 주문 단위 플래그를 넣으면 소비자 배송 목록 각 항목에서 `order.status`와 중복·의미 모호. deliver 응답에만 필요한 스칼라이므로 전용 래퍼가 응집도 높음. `orderDelivered`를 **현재 status**로 계산해 멱등 재완료도 일관(전이 플래그였다면 멱등 재호출 시 false가 되어 혼란).
- **rollup 판정 = 기존 2쿼리 재사용** vs 신규 집계 쿼리. 기존 `findAssignedOrderItemIds`·`findByOrderId`로 충분하고 신규 쿼리는 과설계 → Task Constraint 준수. 멀티 배송 수가 작아 메모리 판정 비용 무시 가능.
- **deliver 의존 단순화**(이벤트·member·product 0) vs ship 대칭성 유지. 배송완료 이벤트가 범위 밖이라 의존을 추가하면 죽은 코드·불필요 결합. 의존 0이 forbidden-rule(불필요 의존 주입 금지)·과설계 금지에 부합 → 채택.

---

## 7. 작업 분할 (implementor 라우팅)

### backend-implementor 담당 파일
- (수정) `order/domain/Shipment.java` — `markDelivered(Instant)`.
- (수정) `order/domain/Order.java` — `markDelivered()`(rollup).
- (수정) `order/service/OrderFulfillmentService.java` — `deliver(long)` + rollup 판정(`findAssignedOrderItemIds`·`findByOrderId` 재사용) + `ShipmentResponse` 생성 지점 3곳 갱신. **신규 의존 주입 없음.**
- (수정) `order/service/AdminOrderFulfillmentFacadeImpl.java` — `deliver` 위임 + `toShipmentResponseWithItems` 생성 지점 1곳 갱신.
- (신규) `order/dto/DeliverResponse.java` — `record(ShipmentResponse, boolean orderDelivered)`.
- (수정) `order/dto/ShipmentResponse.java` — `deliveredAt` 추가.
- (수정) `order/controller/AdminShipmentRestController.java` — `POST /api/v1/admin/shipments/{shipmentId}/deliver`.
- (수정) `order/spi/AdminOrderFulfillmentFacade.java` — `deliver(long)`.
- (변경 없음·확인) `order/repository/ShipmentRepository.java`(기존 쿼리 재사용), `security/SecurityConfig.java`(catch-all 커버), `common/exception/*`(기존 예외 재사용 — 신규 0).
- 테스트: 단위(Shipment/Order/Service)·통합(이벤트 무변화 포함)·동시성·REST·Security·구조 전부.

### view-implementor 담당 파일
- (수정) `web/order/AdminShipViewController.java` — `POST /admin/shipments/{shipmentId}/deliver` 핸들러(입력 없음, PRG·flash).
- (수정) `templates/admin/orders.html` — `s.status == 'shipping'`에 배송 완료 폼(CSRF) + `delivered`에 배송완료시각.
- (수정) `templates/order/detail.html` — `shipment.status == 'delivered'`에 배송완료시각 표시 블록.
- (무변경 확인) `templates/order/list.html` — `배송 완료` 라벨 이미 존재.
- View 렌더링 테스트(admin 완료 폼 CSRF·소비자 상세 배송완료시각·라벨).

### 의존 관계 / 병렬 가능 여부
- **view는 backend 계약에 의존**: `ShipmentResponse.deliveredAt`·`AdminOrderFulfillmentFacade.deliver`·`DeliverResponse`. 권장 순서: **backend(domain/service/dto/facade) → view**. 병렬 시 §2의 `ShipmentResponse`(8필드)·`AdminOrderFulfillmentFacade.deliver`·`DeliverResponse` 시그니처를 **고정 계약**으로 선합의하면 동시 진행 가능.
- 소비자 상세 합성 배선은 020에서 완료(C10)되어 추가 backend-view 결합 없음 — view는 `deliveredAt` 게터/템플릿만 추가.

## 완료 조건
- [ ] `shipping` 배송 `deliver` → 배송 `delivered` + deliveredAt 기록, `200` + `DeliverResponse`.
- [ ] 단일 배송 주문: 전 항목 배정 && 전 배송 delivered → 주문 rollup `shipping→delivered`, `orderDelivered=true`.
- [ ] 멀티 배송: 일부만 delivered면 주문 `shipping` 유지(`orderDelivered=false`), 마지막 완료 시 `delivered`.
- [ ] 미배정 항목 남은 주문: 생성된 배송 전부 delivered여도 주문 `shipping` 유지.
- [ ] 같은 배송 `deliver` 중복 → 멱등 200, 상태·deliveredAt 불변.
- [ ] `preparing`/역방향/취소·환불·비-shipping 주문 → 409, 미존재 404. ADMIN 200·비인증 401·비ADMIN 403.
- [ ] 동시 deliver 1번만 rollup(정합1 — 락 후 fresh 재조회, 락 전 적재 흐름이면 동시성 테스트 실패).
- [ ] 소비자 상세 배송완료시각·`배송 완료` 라벨 표시, 타인 주문 404, 내부정보 비노출.
- [ ] **이벤트 미발행**(event_publication 무변화), 신규 migration 없음, `ModularityTests`/구조 테스트 통과, 016/018/019/020 회귀 0, `./gradlew :shop-core:test` 그린.

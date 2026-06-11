# 020 — shop-core 주문 이행: 배송 시작(shipping) + ShippingStartedEvent 발행 (with View) plan

> 대상: shop-core / Java 21 / Spring Boot 3.5.x / Spring Modulith / Thymeleaf / PostgreSQL / Kafka
> 선행: 019(Shipment 모델 + `preparing` 생성), 016(이벤트 발행·P2 사전검증·member.spi/product.spi), 018(취소·주문 row 락)
> 근거 문서: `docs/tasks/backend/020-...with-view.md`, `docs/plans/revisions/backend/020-...revision-1.md`(정합1~6)
> **본 plan은 배송 완료(`delivered`)·판매자 범위 이행·라인 수량 분할·배송정보 수정·신규 migration을 다루지 않는다(범위 밖).**

---

## 0. 코드 대조 결과 / 확인 필요 항목

실제 코드를 읽어 확정한 사실과, Task 서술과 현재 코드가 갈라지는 지점을 먼저 명시한다(추정 금지 원칙).

| # | 확인 사실 | plan 반영 |
|---|---|---|
| C1 | `OrderFulfillmentService`는 **public** 클래스, `@Transactional`, 의존은 `OrderRepository`·`ShipmentRepository` **2개뿐**. 이벤트/member/product 의존 0. | `ship` 추가 시 `MemberDirectory`·`ProductOrderCatalog`·`ApplicationEventPublisher` **3개 의존 신규 주입**. (016 `OrderConfirmationImpl`과 동형) |
| C2 | 기존 REST 컨트롤러 `AdminOrderFulfillmentRestController`는 `@RequestMapping("/api/v1/admin/orders/{orderId}/shipments")`. Task의 ship 엔드포인트는 `POST /api/v1/admin/shipments/{shipmentId}/ship`로 **base path가 다르다**. | **확인 필요 → 결정**: 기존 컨트롤러의 클래스 레벨 `@RequestMapping` 하위로는 `/shipments/{id}/ship`를 표현할 수 없다. `@PostMapping`에 **절대경로**(`/api/v1/admin/shipments/{shipmentId}/ship`)를 직접 지정하거나 **별도 컨트롤러 분리**. 본 plan은 의미 단위가 다르므로 **신규 컨트롤러 `AdminShipmentRestController`(order/controller)** 로 분리한다(아래 §2). |
| C3 | 기존 admin View 컨트롤러 `AdminOrderViewController`는 `@RequestMapping("/admin/orders")`. ship 폼은 `POST /admin/shipments/{shipmentId}/ship`로 **base가 다르다**. | **최종 결정(구현 중 교정)**: Spring MVC는 클래스 레벨(`/admin/orders`) + 메서드 레벨 매핑을 **항상 결합**하므로, 같은 컨트롤러에 절대경로 `@PostMapping("/admin/shipments/...")`를 넣어도 `/admin/orders/admin/shipments/...`가 되어 **표현 불가**. 따라서 클래스 레벨 매핑이 없는 **별도 `web/order/AdminShipViewController`로 분리**해 `POST /admin/shipments/{shipmentId}/ship`을 정확히 매핑한다. ⚠️ **021(배송 완료) 동일 주의**: `/admin/shipments/{id}/deliver` View 핸들러도 같은 이유로 별도/무클래스매핑 컨트롤러에 둔다. |
| C4 | `ShipmentResponse = {shipmentId, orderId, status, items}` — 추적정보 필드 부재(정합2). 생성 지점 **3곳**: `OrderFulfillmentService.createShipment`, `OrderFulfillmentService.toShipmentResponseWithDetails`, `AdminOrderFulfillmentFacadeImpl.toShipmentResponseWithItems`. | 3필드 추가 후 **3곳 전부** 새 시그니처로 갱신(`preparing` 배송은 3필드 null). |
| C5 | 소비자 상세 흐름: `OrderViewController.orderDetail` → `OrderFacade.getMyOrder` → `OrderFacadeImpl` → `OrderService.getMyOrder`(`OrderDetail` 내부 record, **Order 엔티티만으로 구성, 배송 정보 없음**) → `OrderDtoMapper.toOrderResponse` → `OrderResponse`. | `OrderResponse.shipments` 추가(정합4). **배송 목록은 `Order`에 없으므로** `OrderFacadeImpl.getMyOrder`에서 `OrderFulfillmentService.getShipments(orderId)`를 호출해 합성한다(아래 §3 — `OrderService.OrderDetail` 내부 record는 변경하지 않고 facade에서 합성). |
| C6 | `SecurityConfig` line 78 `/api/v1/admin/**`→`hasRole("ADMIN")`, line 126 `/admin/**`→`hasRole("ADMIN")` **catch-all 존재**. | `/api/v1/admin/shipments/*/ship`·`/admin/shipments/**` **자동 포함 → 신규 보안 규칙 불요**(정합: 019 선례). plan은 "무변경 확인"만 명시. |
| C7 | `Shipment` 엔티티에 `carrier`/`trackingNumber`/`shippedAt`/`deliveredAt` 컬럼·게터 **이미 존재**(019에서 nullable 선반영). `markShipping`/`markDelivered`만 미구현. | **신규 migration 불요**(Task Constraint 일치). `Shipment.markShipping` 추가만. |
| C8 | `OrderItem.variantId`는 `@Column(name="variant_id")` **nullable**(FK SET NULL). `ProductOrderCatalog.getOrderableSnapshots(Collection)`는 존재 variantId만 반환 + `active`/`purchasable`/`stock` 동반. | P2 해석 불가 = `variantId==null` **또는** 스냅샷 부재만(정합5). 비활성·품절은 통과. |
| C9 | `MemberDirectory.findContactByUserId(long)` → `MemberContact(email, name)` 존재. `Order.getUserId()` 존재. | 연락처 해석 재사용(016 동형). |
| C10 | `OrderFulfillmentConflictException(409)`·`InvalidShipmentItemException(400)` 존재, 둘 다 `BusinessException` 계층 → RestExceptionHandler 자동 매핑. | 잘못된 전이/취소·환불 주문/P2 해석 불가 → `OrderFulfillmentConflictException`(409) 재사용. 입력 누락(400)은 `@Valid` Bean Validation으로 처리(아래 §4). |

---

## 1. 설계 방식 및 이유

### 1.1 배송 시작 전이를 order 모듈에 두는 이유
- 배송(Shipment)은 019에서 `order` 모듈 소유로 정의됐다(`order/domain/Shipment`). 배송 시작은 배송 상태 전이이므로 **order 모듈 책임**이다. 새 cross-module 의존을 만들지 않고, 기존 단방향 의존(`order → member.spi`, `order → product.spi`)만 재사용한다. `ShippingStartedEvent`도 `order/event` 소유(`OrderCompletedEvent` 선례 동형).
- 이행 오케스트레이션은 019의 `OrderFulfillmentService`(public, order/service)에 `ship` 메서드를 추가해 **019 락·서비스 구조를 재사용**한다. 신규 추상화·포트·Outcome enum을 도입하지 않는다(Task Constraint, 모순2).

### 1.2 정합1 — stale read 차단(동시 `ship` 핵심 설계)
- **문제**: 엔드포인트가 `/shipments/{shipmentId}/ship`라 orderId를 모른다. shipment를 먼저 읽어야 주문 락을 걸 수 있다. 그런데 락 대상(order)과 판정 대상(shipment)이 **다른 엔티티**다. shipment를 락 전에 **엔티티로** 적재하면, 동시 `ship` 시 두 번째 트랜잭션이 직렬화되더라도 **JPA 1차 캐시의 stale `preparing`** 으로 멱등 가드를 통과해 이벤트를 중복 발행한다(직렬화는 "B가 A 이후 실행"만 보장, "B가 A 결과를 본다"는 보장하지 않음).
- **채택(option 2 — 구조적 정확성)**:
  1. **orderId는 스칼라 projection으로만 조회** — `ShipmentRepository.findOrderIdById(shipmentId)` 신규(`@Query("select s.orderId from Shipment s where s.id = :id")` → `Optional<Long>`). `findById(...).getOrderId()` **금지**(엔티티가 락 전에 적재됨).
  2. 그 orderId로 **주문 row `PESSIMISTIC_WRITE` 잠금**(`OrderRepository.findByIdForUpdate` 재사용 — 018 취소·동시 이행과 직렬화).
  3. **주문 락 보유 상태에서 비로소 shipment 엔티티 최초 적재**(`shipmentRepository.findById`)해 상태를 권위 재검증. 락 이전엔 어떤 경로로도 shipment를 엔티티로 로드하지 않았으므로 **항상 fresh**.
- **경계 단서**: 컨트롤러/facade는 같은 트랜잭션에서 shipment를 미리 엔티티로 적재하지 않는다(REST 컨트롤러는 `shipmentId`만 path로 전달, 서비스가 전 과정 소유). 이 흐름이 정합1의 핵심 — 동시성 테스트가 "락 전 엔티티 적재 흐름이면 실패하도록" 설계된다(§5).
- 대안 비교는 §6 트레이드오프 참조.

### 1.3 이벤트 발행 = ApplicationEventPublisher Outbox(004) 재사용
- `ShippingStartedEvent`를 `@Externalized("shipping-started")`로 신설하고, 서비스가 `ApplicationEventPublisher.publishEvent(event)`를 `@Transactional` 안에서 호출 → Spring Modulith Event Publication Registry가 `event_publication`에 INCOMPLETE 저장(Outbox) → 커밋 후 Kafka 외부화. 016 `OrderConfirmationImpl` 패턴 그대로. 전이+이벤트가 **한 트랜잭션 원자 커밋**.

### 1.4 P2 사전검증 채택 이유(정합5)
- 020은 외부 PG 호출이 없어 트랜잭션이 원자 롤백된다. 따라서 P2의 목적은 016식 "비가역 부작용(결제 승인) 방지"가 **아니라**, productId 해석 불가 시 `500`(NPE) 대신 **명확한 `409`로 응답**하는 것이다.
- **해석 불가 정의(한정)**: 이 배송 항목의 `OrderItem.variantId`가 `null`(FK SET NULL — variant 행 삭제) **또는** `getOrderableSnapshots`가 그 variantId를 반환하지 않음(행 삭제)인 경우만. **variant가 단지 비활성(`active=false`)·품절(`purchasable=false`/`stock=0`)인 것은 거부하지 않는다**(이미 결제·생성된 배송이므로 productId 해석만 가능하면 진행). fallback(임의 productId 추정/항목 생략) 없음.

### 1.5 멱등 책임을 서비스가 소유(정합3) / 멱등 키 = 상태뿐(정합4)
- **도메인 메서드 `Shipment.markShipping`은 `preparing→shipping`만 허용**, 그 외 상태는 도메인 예외(`IllegalStateException` — `Order.markPaid` 선례 동형). 메서드 자체는 멱등이 아니다.
- **멱등은 서비스가 단독 소유**: 서비스는 shipment가 `preparing`일 때만 `markShipping`을 호출하고, **이미 `shipping`이면 호출 전에 현재 `ShipmentResponse`를 `200`으로 반환**(상태 불변, `ShippingStartedEvent` 재발행 금지).
- **멱등 판정 키는 shipment 상태(`shipping`)뿐**: 이미 `shipping`인 배송에 다른 carrier/trackingNumber로 재요청해도 본문과 **무관하게** 기존 추적정보를 변경 없이 반환(배송정보 수정은 범위 밖이라 본문 불일치도 오류가 아님, 덮어쓰지 않음).

### 1.6 거부 = 직접 throw, 멱등 = 200(모순2)
- 잘못된 전이(이미 `delivered`/역방향/취소·환불된 주문)·P2 해석 불가는 부작용 전 `OrderFulfillmentConflictException`(409) **직접 throw**. 입력 누락은 `400`. 018 Outcome 값-매핑은 payment→order.spi cross-module 경계 때문이었고, 이행 서비스는 order 모듈 **내부 직접 호출**이라 indirection을 두지 않는다.

---

## 2. 구성 요소 (레이어별 신규/수정 + 메서드 시그니처)

### domain (수정)
- **`order/domain/Shipment.java`** — 메서드 추가:
  ```java
  /** preparing → shipping 만 허용. 그 외 상태는 IllegalStateException(멱등 책임은 서비스 소유). */
  public void markShipping(String carrier, String trackingNumber, Instant shippedAt) {
      if (!"preparing".equals(this.status)) {
          throw new IllegalStateException("배송 상태가 preparing이 아니어서 shipping으로 전이할 수 없습니다. 현재 상태: " + this.status);
      }
      this.status = "shipping";
      this.carrier = carrier;
      this.trackingNumber = trackingNumber;
      this.shippedAt = shippedAt;
  }
  ```
- **`order/domain/Order.java`** — 메서드 추가:
  ```java
  /** rollup preparing → shipping. preparing 외(shipping 재호출 포함)는 IllegalStateException.
   *  단, 멀티 배송 둘째 ship 시 이미 shipping이면 서비스가 호출 자체를 생략한다. */
  public void markShipping() {
      if (!"preparing".equals(this.status)) {
          throw new IllegalStateException("주문 상태가 preparing이 아니어서 shipping으로 전이할 수 없습니다. 현재 상태: " + this.status);
      }
      this.status = "shipping";
  }
  ```
  > 결정: `markPreparing`은 멱등 no-op이었으나, `markShipping`은 **멀티 배송 둘째 ship 시 서비스가 "주문이 preparing일 때만" 호출**하므로 도메인은 단일 전이만 허용(정합3 일관). 이미 shipping이면 서비스가 호출 생략.

### event (신규)
- **`order/event/ShippingStartedEvent.java`** — `@Externalized("shipping-started")`, 배송 단위 개정 페이로드:
  ```java
  @Externalized("shipping-started")
  public record ShippingStartedEvent(
      UUID eventId, Instant occurredAt,
      long orderId, String orderNumber,
      long shipmentId,                 // 신규(배송 단위)
      long memberId, String memberEmail, String memberName,
      String carrier, String trackingNumber,
      List<Item> items,                // 신규(이 배송분만)
      Instant shippedAt
  ) {
      public static final String TOPIC = "shipping-started";
      public record Item(long productId, String productName, int quantity) {}
  }
  ```
  > `OrderCompletedEvent` 구조·주석 패턴 복제. `Item`은 productId·productName·quantity만(unitPrice 없음 — 배송 이벤트 계약).

### repository (수정)
- **`order/repository/ShipmentRepository.java`** — 메서드 추가:
  ```java
  /** 정합1: orderId 스칼라 projection만 반환(엔티티 적재 금지). 락 전 orderId 획득용. */
  @Query("select s.orderId from Shipment s where s.id = :id")
  Optional<Long> findOrderIdById(@Param("id") long id);
  ```
  > shipment 엔티티 최초 적재는 락 후 기존 `findById(shipmentId)` 재사용(신규 메서드 불요).

### service (수정)
- **`order/service/OrderFulfillmentService.java`**:
  - 의존 추가: `MemberDirectory memberDirectory`, `ProductOrderCatalog productOrderCatalog`, `ApplicationEventPublisher eventPublisher`(C1).
  - 메서드 추가: `public ShipmentResponse ship(long shipmentId, String carrier, String trackingNumber)` (`@Transactional` — 클래스 레벨 적용됨). 흐름은 §3.
  - private 헬퍼: `buildShippingStartedEvent(Order order, Shipment shipment, Map<Long,OrderItem> orderItemMap, Map<Long,Long> variantToProductId)` — **P2 단계에서 만든 `variantToProductId` 맵을 그대로 받아 재사용**(개선1 — `ProductOrderCatalog` 재호출 금지). 연락처(member.spi)·items[](이 배송분: productId=맵, productName/quantity=orderItem 스냅샷) 구성. (016 `buildOrderCompletedEvent` 동형, 단 금액 변환 없음).
    > **개선1**: P2 사전검증이 `getOrderableSnapshots(variantIds)`로 이미 `variantId→productId` 맵을 만든다. 이벤트 빌더는 이 맵을 인자로 받아 **단일 조회 결과를 재사용**한다(이중 조회 방지).
  - `createShipment`·`toShipmentResponseWithDetails` 의 `new ShipmentResponse(...)` 호출 **2곳**을 새 7-필드 시그니처로 갱신(C4, `preparing`은 carrier/tracking/shippedAt = null).
- **`order/service/AdminOrderFulfillmentFacadeImpl.java`** — `toShipmentResponseWithItems`의 `new ShipmentResponse(...)` 1곳 갱신(C4).
- **`order/service/OrderFacadeImpl.java`** — `getMyOrder(email, orderId)`에서 `orderFulfillmentService.getShipments(orderId)` 호출 후 `OrderResponse`에 `shipments` 합성(C5, 아래 §3.3). `createOrder` 응답에도 빈 목록/배송 목록 합성(생성 직후 배송 0건 → 빈 목록).
  > `OrderDtoMapper.toOrderResponse`는 `OrderDetail`만으로 `shipments`를 모르므로, **facade에서 합성 후 `OrderResponse`를 재조립**하거나 `toOrderResponse(detail, shipments)` 오버로드를 추가한다. 본 plan은 **`OrderDtoMapper.toOrderResponse(OrderDetail, List<ShipmentResponse>)` 오버로드 추가**로 결정(매퍼에 변환 집중 원칙 유지).

### controller (신규)
- **`order/controller/AdminShipmentRestController.java`**(신규, C2) — `POST /api/v1/admin/shipments/{shipmentId}/ship`:
  ```java
  @RestController
  @RequiredArgsConstructor
  class AdminShipmentRestController {
      private final OrderFulfillmentService orderFulfillmentService;
      @PostMapping("/api/v1/admin/shipments/{shipmentId}/ship")
      ResponseEntity<ShipmentResponse> ship(@PathVariable long shipmentId,
                                            @Valid @RequestBody ShipRequest req) {
          return ResponseEntity.ok(orderFulfillmentService.ship(shipmentId, req.carrier(), req.trackingNumber()));
      }
  }
  ```
  > 비즈니스 로직 없음. **미존재 배송 404 = 신규 `ShipmentNotFoundException`(BusinessException·404)으로 확정**(개선3). `OrderNotFoundException` 재사용은 "*배송*이 없는데 주문 없음"으로 로그·메시지가 오도되므로 채택하지 않는다. 단순 예외 클래스 1개 추가는 기존 `BusinessException` 패턴 답습이라 과설계가 아니다(새 포트/enum 아님). `common/exception/ShipmentNotFoundException` 신설.

### dto (신규/수정)
- **`order/dto/ShipRequest.java`**(신규) — `record ShipRequest(@NotBlank String carrier, @NotBlank String trackingNumber)`. (400은 Bean Validation, §4)
- **`order/dto/ShipmentResponse.java`**(수정, 정합2) — 3필드 추가:
  ```java
  public record ShipmentResponse(long shipmentId, long orderId, String status,
                                 String carrier, String trackingNumber, Instant shippedAt,
                                 List<ShipmentItemResponse> items) {}
  ```
  > **생성 지점 갱신 목록**(C4): ① `OrderFulfillmentService.createShipment` ② `OrderFulfillmentService.toShipmentResponseWithDetails` ③ `AdminOrderFulfillmentFacadeImpl.toShipmentResponseWithItems`. `preparing` 배송은 carrier/trackingNumber/shippedAt = null.
- **`order/dto/OrderResponse.java`**(수정, 정합4) — `List<ShipmentResponse> shipments` 필드 추가(맨 끝).
  > **개선2(컴파일 완결성)**: `OrderResponse`에 필드를 추가하면 ShipmentResponse와 동일하게 **모든 생성 지점이 컴파일 깨짐**. 갱신 목록을 명시한다 — ① `OrderDtoMapper.toOrderResponse`를 `toOrderResponse(OrderDetail, List<ShipmentResponse>)`로 변경(기존 단일 인자 시그니처는 **제거**하거나 `List.of()` 위임). ② `OrderFacadeImpl.createOrder` 경로 = 생성 직후 배송 0건이므로 `List.of()` 전달. ③ `OrderFacadeImpl.getMyOrder` 경로 = `getShipments(orderId)` 합성 전달. 단일 인자 잔존 경로가 없도록 전수 확인.

### web / template (view-implementor)
- **`web/order/AdminOrderViewController.java`**(수정, C3) — 핸들러 추가 `@PostMapping("/admin/shipments/{shipmentId}/ship")`(절대경로): `adminOrderFulfillmentFacade.ship(...)` 위임 → 성공 flashSuccess + `redirect:/admin/orders`, `BusinessException` catch → flashError + redirect. (createShipment 핸들러 PRG 패턴 복제)
- **`order/spi/AdminOrderFulfillmentFacade.java` + `AdminOrderFulfillmentFacadeImpl`**(수정) — `ShipmentResponse ship(long shipmentId, String carrier, String trackingNumber)` 추가(서비스 위임, BusinessException 전파). View가 service 직접 참조 안 하도록 facade 경유(web → order.spi 단방향).
- **`templates/admin/orders.html`**(수정) — 배송 현황 블록에 **배송 시작 폼** 추가: `s.status == 'preparing'`인 배송에만 노출, `POST /admin/shipments/{shipmentId}/ship`, carrier/trackingNumber 입력 + CSRF(th:action 자동 주입). `shipping` 배송은 carrier/trackingNumber/shippedAt 표시.
- **`templates/order/detail.html`**(수정, 정합4) — 소비자 **배송 목록 블록 신설**: `order.shipments` 반복, 배송별 status·포함 항목, `shipping` 배송엔 택배사·운송장·배송시작시각(읽기 전용). status 라벨(`배송 중`)은 기존 매핑 재사용.
- **`templates/order/list.html`** — rollup `배송 중` 라벨은 기존으로 충분(무변경, 확인만).

### security (무변경 확인, C6)
- `SecurityConfig` line 78/126 catch-all이 `/api/v1/admin/shipments/*/ship`·`/admin/shipments/**`를 자동 포함 → **신규 규칙 불요**. plan/PR 설명에 "catch-all로 커버됨" 1줄 명시.

### docs (수정)
- **`docs/event-catalog.md`**(코드보다 먼저) — `ShippingStartedEvent` 표·예시 JSON을 배송 단위로 개정: `shipmentId`(long) 추가, `items[]`(productId·productName·quantity) 추가. topic `shipping-started`·발행 모듈 `order`·소비자 `notification` 유지.
- **`docs/architecture.md` §5 무변경**(정합6 — 필드 상세 부재, event-catalog가 SSOT). 필요 시 "배송 단위 개정은 event-catalog 참조" 주석 1줄만 허용.

---

## 3. 데이터 흐름

### 3.1 REST `ship` 흐름 (`POST /api/v1/admin/shipments/{shipmentId}/ship`)
1. SecurityConfig restChain `/api/v1/admin/**` → `hasRole("ADMIN")`(비인증 401, 비ADMIN 403).
2. `AdminShipmentRestController.ship` — `@Valid ShipRequest`(carrier/trackingNumber `@NotBlank`, 누락 시 400). 서비스 위임.
3. `OrderFulfillmentService.ship(shipmentId, carrier, trackingNumber)`(`@Transactional`):
   - **(정합1 락 순서)** ① `shipmentRepository.findOrderIdById(shipmentId)` — 스칼라 projection. empty → `404`(미존재 배송). ② `orderRepository.findByIdForUpdate(orderId)` — **주문 row 잠금**. ③ **락 후** `shipmentRepository.findById(shipmentId)` — shipment 엔티티 **최초 적재**(fresh 재검증).
   - **상태 재검증**: 주문이 `cancelled`/`refunded` → `409`(취소·환불 주문). **방어 가드(개선5)**: 정상적으로 shipment 존재 시 주문은 `preparing`/`shipping`만 가능하나, `order.status ∉ {preparing, shipping}`이면 불변식 위반으로 `409`(조기 차단). shipment가 이미 `shipping` → **멱등 200**(현재 `ShipmentResponse` 반환, 이벤트 재발행 없음). `delivered`/역방향 → `409`. `preparing`이면 진행.
   - **시각 캡처(개선4)**: 진행 확정 시 `Instant now = Instant.now()`를 **한 번 캡처**해 `markShipping`의 `shippedAt`·이벤트 `shippedAt`·`occurredAt`에 동일 값 재사용(미세 불일치 방지).
   - **P2 사전검증**: 이 배송의 `shipment.getItems()` → 각 `ShipmentItem.orderItemId` → `Order.getItems()`에서 `OrderItem` 매핑 → `variantId` 수집. `variantId==null`이 하나라도 있으면 `409`. 나머지 variantId로 `productOrderCatalog.getOrderableSnapshots(variantIds)` → `variantId→productId` 맵 구성. 매핑 누락(행 삭제)이 하나라도 있으면 `409`. (비활성·품절은 통과 — 정합5)
   - **전이**: `shipment.markShipping(carrier, trackingNumber, Instant.now())` + **rollup: 주문이 `preparing`이면 `order.markShipping()`**(이미 `shipping`이면 호출 생략 — 멀티 배송).
   - **이벤트 구성·발행**: `buildShippingStartedEvent(...)` → `eventPublisher.publishEvent(event)`(Outbox 저장).
   - 커밋 → `200` + 갱신 `ShipmentResponse`(status `shipping`·carrier·trackingNumber·shippedAt·items).

### 3.2 View admin 폼 흐름 (`POST /admin/shipments/{shipmentId}/ship`)
1. SecurityConfig viewChain `/admin/**` → `hasRole("ADMIN")`(비인증 `/login` 302, 비ADMIN 403). CSRF 폼 토큰.
2. `AdminOrderViewController.ship` → `adminOrderFulfillmentFacade.ship(shipmentId, carrier, trackingNumber)` → 서비스(3.1과 동일 경로).
3. 성공 → flashSuccess + `redirect:/admin/orders`. `BusinessException`(409 등) catch → flashError + redirect(부작용 없음). 입력 누락은 폼 검증/서비스 400 → flashError.

### 3.3 소비자 detail 표시 흐름 (`GET /orders/{orderId}`)
1. `OrderViewController.orderDetail` → `OrderFacade.getMyOrder(email, orderId)`.
2. `OrderFacadeImpl.getMyOrder`: email→userId → `orderService.getMyOrder(userId, orderId)`(소유권 검증, 타인/미존재 404) → `OrderDetail` → **추가**: `orderFulfillmentService.getShipments(orderId)` → `OrderDtoMapper.toOrderResponse(detail, shipments)` → `OrderResponse(shipments 포함)`.
3. `detail.html`이 `order.shipments` 렌더(배송별 status·항목, `shipping` 배송 추적정보 읽기 전용). 소비자 응답에 `seller_id`/`ownerId`/내부정보 미노출.

### 3.4 ShippingStartedEvent payload 출처

| 필드 | 출처 |
|---|---|
| `eventId` | `UUID.randomUUID()` |
| `occurredAt` | 캡처한 `now`(개선4 — `shippedAt`와 동일 값) |
| `orderId` | 잠근 `Order.getId()` |
| `orderNumber` | `Order.getOrderNumber()` |
| `shipmentId` | `Shipment.getId()` |
| `memberId` | `Order.getUserId()` |
| `memberEmail`/`memberName` | `member.spi MemberDirectory.findContactByUserId(userId)` → `MemberContact` |
| `items[].productId` | `product.spi ProductOrderCatalog.getOrderableSnapshots(variantIds)` → variantId→productId |
| `items[].productName`/`quantity` | `order_items` 스냅샷(`OrderItem.getProductName()`/`getQuantity()`) — 이 배송(shipment_items↔order_items)분만 |
| `carrier`/`trackingNumber` | 요청 입력 |
| `shippedAt` | 캡처한 `now`(개선4, = `Shipment.shippedAt`) |

> `items[]`는 **이 배송에 포함된 항목만**(주문 전체 아님). notification 역조회 금지(자족).

---

## 4. 예외 처리 전략

| 상황 | HTTP | 메커니즘 | 비고 |
|---|---|---|---|
| carrier/trackingNumber 누락 | `400` | `ShipRequest @NotBlank` Bean Validation → `MethodArgumentNotValidException` → RestExceptionHandler. View는 facade/서비스 400 `BusinessException`을 catch → flashError | 부작용 전, 상태 불변·이벤트 미발행 |
| 미존재 배송 | `404` | 서비스: `findOrderIdById` empty → **`ShipmentNotFoundException`(404, 신규 — 개선3)** | 관리자 경로 — 존재 은닉 불요 |
| 잘못된 전이(`delivered`/역방향) | `409` | 서비스 직접 throw `OrderFulfillmentConflictException`(재사용) | 부작용 전 판정 |
| 취소·환불 주문의 배송 ship | `409` | 락 후 `order.status ∈ {cancelled, refunded}` 재검증 → `OrderFulfillmentConflictException` | 018 상호작용·모순 방지 |
| P2 productId 해석 불가 | `409` | `variantId==null` 또는 스냅샷 부재 → `OrderFulfillmentConflictException`(메시지: 상품 해석 불가) | 비활성·품절은 거부 안 함(정합5). 전이·발행 전 |
| 이미 `shipping`(멱등) | `200` | **예외 아님** — `markShipping` 호출 없이 현재 `ShipmentResponse` 반환, 이벤트 재발행 없음 | 멱등 키=상태뿐, 본문 불일치도 200(정합4) |
| 성공 | `200` | 전이+rollup+이벤트 원자 커밋 | |
| 시스템 오류(P2 통과 후 productId null 등) | `500` 롤백 | 016식 `PaymentEventResolutionException` 유사 방어 throw(정상 흐름 미발생) | 전체 롤백(상태·이벤트) |

- **직접 throw vs 멱등 200 기준(모순2/정합3·4)**: 잘못된 전이·취소/환불·P2 = **직접 throw 409**(부작용 전). 이미 `shipping` = **멱등 200**(이벤트 재발행만 내부 if 차단). 입력 누락 = 400(Bean Validation).
- **예외 클래스**: `OrderFulfillmentConflictException`(409)을 잘못된 전이·취소/환불·P2에 재사용한다. 미존재 배송 404는 **`ShipmentNotFoundException`(BusinessException·404) 신설로 확정**(개선3 — `OrderNotFoundException` 재사용 시 의미 오도). 그 외 신규 포트/enum/Outcome은 추가하지 않는다.
- **View**: `AdminOrderViewController.ship`은 `BusinessException` catch → flashError + redirect(부작용 없음, JSON 미반환 — error-response-rule).
- **REST**: 모든 예외는 `BusinessException` 계층 → RestExceptionHandler가 `ErrorResponse`로 자동 매핑(error-response-rule). 응답에 Entity·ownerId·로컬경로·member 내부정보 미포함, status lowercase.

---

## 5. 검증 방법 (testing-rule / verification-gate-rule)

### 단위 (JUnit5 + Mockito)
- **`ShipmentTest`**: `markShipping` — `preparing→shipping` 허용(carrier/trackingNumber/shippedAt 기록), `shipping`/`delivered`/역방향 호출 시 `IllegalStateException`.
- **`OrderTest`**: `markShipping()` — `preparing→shipping` 허용, 그 외(`paid`/`shipping`/`cancelled` 등) `IllegalStateException`.
- **`OrderFulfillmentServiceTest`**(Mockito):
  - `ship` preparing→shipping + rollup `preparing→shipping` + `ShippingStartedEvent` 1건 발행(publisher verify).
  - 멀티 배송 둘째 ship: 주문 이미 `shipping` → `order.markShipping()` **미호출**(status 불변), 이벤트는 해당 배송분만 1건.
  - P2 해석 불가: `variantId==null` → 409, 스냅샷 부재 → 409. **비활성·품절(active=false/purchasable=false/stock=0)은 통과**(정합5).
  - 입력 누락 → 400(서비스/컨트롤러 경계 — Bean Validation은 REST 슬라이스에서).
  - 멱등 재호출: 이미 `shipping` → `markShipping`·publisher 미호출, 동일 `ShipmentResponse` 200. **다른 carrier/trackingNumber 본문도 기존 값 유지**(정합4).
  - **정합1 락 순서 검증**: `InOrder`로 `findOrderIdById` → `findByIdForUpdate` → `findById(shipment)` 호출 **순서** 단언(shipment 엔티티 적재가 주문 락보다 **뒤**). "락 전 shipment 엔티티 적재" 흐름이면 실패하도록.
  - `ShippingStartedEvent` 매핑: items[]/shipmentId/연락처(해당 배송분만).

### 통합 (Testcontainers + Modulith — `@ApplicationModuleTest` 또는 통합 슬라이스)
- ship 커밋 시 `event_publication`에 `ShippingStartedEvent` 1건 + 개정 payload 스키마(shipmentId·items[]·carrier·trackingNumber·연락처·shippedAt) 검증.
- 멀티 배송: 각 ship마다 이벤트 1건(해당 항목만). 멱등 ship 재호출 시 이벤트 추가 없음.
- 시스템 오류 시 부분 반영 없음(상태·이벤트 전체 롤백).

### 동시성 (Testcontainers)
- **동일 배송 동시 ship → 1건만 전이/발행, `event_publication` 1건만**(정합1 — 락 후 fresh 재조회로 두 번째가 stale `preparing`을 보지 않음). row 정합.
- **배송 시작 vs 018 취소 동시** → 주문 row 락 직렬화, 모순(취소된 주문 배송 시작) 없음.

### REST/Security (MockMvc 슬라이스)
- ship 200 / 잘못된 전이 409 / 입력 누락 400 / P2 409 / 미존재 404.
- ADMIN 200·비인증 401·비ADMIN 403. 응답 내부정보(Entity/ownerId/seller_id) 비노출.

### View (MockMvc / Thymeleaf 렌더)
- admin 배송 시작 폼(CSRF) 렌더링(preparing 배송), 성공 redirect+flashSuccess, 불가/누락 flashError.
- 소비자 상세 `shipping` 추적정보·배송 목록 표시, list `배송 중` 라벨. 비인증 admin `/login` redirect. 타인 주문 404.

### 구조 (ArchUnit / Modulith)
- `ShippingStartedEvent` order 모듈 위치. 이행 코드 payment.spi/payment 미의존. `web.order` 도메인 내부 직접 참조 안 함. `ModularityTests.verify()` 통과.

### 실행 커맨드 / 게이트 (verification-gate-rule)
- `./gradlew :shop-core:test`(전체) — 019/016/018 회귀 0 확인.
- `./gradlew :shop-core:compileJava`로 `ShipmentResponse` 시그니처 변경의 3개 생성 지점·`OrderResponse` 파급 컴파일 그린 확인.
- 모든 테스트 그린 + `ModularityTests` 그린이 머지 게이트.

---

## 6. 트레이드오프

- **정합1: option2(orderId projection + 락 후 적재) 채택** vs option1(`EntityManager.refresh()`) vs option3(shipment 행 직접 `FOR UPDATE`).
  - option1: 정확성이 **절차적**(refresh 호출을 기억해야 맞음), `EntityManager` 의존 추가, 불필요한 2회 SELECT → 취약.
  - option3: order 락(018 직렬화)과 shipment 락 2개를 잡아 **락 순서 문제** 발생.
  - option2: **구조적 정확성**("락 전엔 shipment 엔티티 적재 불가") — 단서(진짜 projection·업스트림 선적재 금지)만 지키면 가장 견고. **채택**.
- **`ShipmentResponse` 단일 DTO 재사용** vs 분리(`ShipmentResponse`/`ShipmentTrackingResponse`).
  - 단일 재사용: 3필드 추가로 3개 생성 지점 컴파일 파급이 있으나 DTO 종류·매핑 분기를 늘리지 않음. `preparing`은 null로 충분. **채택**(정합2). 분리는 admin/consumer/REST 응답 매핑이 3배로 늘어 과설계.
- **P2 사전검증 비용 대비 이점**: 외부 PG가 없어 롤백은 보장되나, 사전검증으로 해석 불가를 `500`(NPE) 대신 **명확한 `409`**로 응답 → 클라이언트 대응성·로그 가독성 향상. 비활성·품절을 거부하지 않아(정합5) 이미 결제·생성된 배송이 품절 사유로 막히지 않음.
- **이벤트 계약 배송 단위 개정의 호환성**: 현재 `shipping-started` 토픽 **구독 컨슈머 0**(notification 미구현) → `shipmentId`+`items[]` 추가가 **안전한 적기**. 발행처를 처음 구현하는 지금 개정. event-catalog(SSOT)를 코드보다 먼저 갱신, architecture §5 무변경(정합6).
- **소비자 배송 목록 합성 위치(facade) vs OrderDetail 내부 record 확장**: `OrderService.OrderDetail`은 `Order` 엔티티만으로 구성되고 배송 조회를 모른다. facade에서 `getShipments`를 합성하면 `OrderService`/`OrderDetail` 내부 타입을 건드리지 않아 결제·주문 핵심 경로 회귀 위험이 낮다. **facade 합성 채택**(C5).

---

## 7. 작업 분할 (implementor 라우팅)

### backend-implementor
- domain: `Shipment.markShipping`, `Order.markShipping`.
- service: `OrderFulfillmentService.ship`(+P2 사전검증 + 이벤트 발행 + rollup), `buildShippingStartedEvent`, `ShipmentResponse` 3개 생성 지점 갱신.
- repository: `ShipmentRepository.findOrderIdById`(projection).
- event: `ShippingStartedEvent`(`@Externalized`).
- controller: `AdminShipmentRestController`(`POST /api/v1/admin/shipments/{shipmentId}/ship`).
- exception: `common/exception/ShipmentNotFoundException`(404, 신규 — 개선3).
- dto: `ShipRequest`(신규), `ShipmentResponse`(3필드 확장 + 생성 지점 3곳), `OrderResponse.shipments`(필드 추가 + 생성 지점 전수 갱신 — 개선2).
- spi/facade: `AdminOrderFulfillmentFacade.ship` + impl, `OrderFacadeImpl.getMyOrder` 배송 합성, `OrderDtoMapper.toOrderResponse` 오버로드.
- security: `SecurityConfig` 무변경 확인(catch-all 커버).
- docs: `docs/event-catalog.md` 배송 단위 개정(코드보다 먼저).
- 테스트: 단위/통합(Outbox)/동시성/REST·Security/구조 전부.

### view-implementor
- `templates/admin/orders.html`: `preparing` 배송에 배송 시작 폼(carrier/trackingNumber + CSRF), `shipping` 배송 추적정보 표시.
- `templates/order/detail.html`: 소비자 배송 목록 블록 + `shipping` 추적정보(읽기 전용).
- `web/order/AdminOrderViewController`: `POST /admin/shipments/{shipmentId}/ship` 핸들러(절대경로) + flash/redirect.
- View 렌더링 테스트(admin 폼·소비자 상세·라벨).

### 의존 관계 / 병렬 가능 여부
- **view는 backend의 계약에 의존**: `ShipmentResponse`(carrier/trackingNumber/shippedAt)·`OrderResponse.shipments`·`AdminOrderFulfillmentFacade.ship`. 따라서 **backend-implementor가 DTO/facade 시그니처를 먼저 확정**(또는 병렬 착수 시 §2의 시그니처를 계약으로 합의)해야 view가 템플릿 바인딩을 깨지 않는다.
- 권장 순서: **backend(domain/service/dto/event/facade) → view**. 병렬 시 §2의 `ShipmentResponse`/`OrderResponse`/`AdminOrderFulfillmentFacade.ship` 시그니처를 **고정 계약**으로 선합의하면 동시 진행 가능. event-catalog 개정은 backend가 코드보다 먼저 수행.

## 완료 조건
- [ ] `preparing` 배송 ship → `shipping` 전이 + carrier/trackingNumber/shippedAt 기록 + 주문 rollup `preparing→shipping` + `ShippingStartedEvent` 1건 Outbox 저장(개정 payload).
- [ ] `items[]`는 해당 배송분만, 멀티 배송 각 ship마다 1건(둘째는 주문 status 불변).
- [ ] 멱등 재호출 200·이벤트 재발행 0(본문 불일치도 기존 값 유지).
- [ ] 동시 ship 1건만 전이/발행(정합1 — 락 후 fresh 재조회, 락 전 엔티티 적재 흐름이면 동시성 테스트 실패).
- [ ] 입력 누락 400 / 잘못된 전이·취소·환불·P2 409 / 미존재 404, ADMIN 200·비인증 401·비ADMIN 403.
- [ ] 소비자 상세 배송 추적정보 표시, 타인 주문 404, 내부정보 비노출.
- [ ] `docs/event-catalog.md` 배송 단위 개정(코드보다 먼저), architecture §5 무변경.
- [ ] `ModularityTests`/구조 테스트 통과, 019/016/018 회귀 0, `./gradlew :shop-core:test` 그린.

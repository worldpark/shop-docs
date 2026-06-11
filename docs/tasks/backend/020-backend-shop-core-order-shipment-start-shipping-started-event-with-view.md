# 020. shop-core 주문 이행 — 배송 시작(shipping) + ShippingStartedEvent 발행 (with View)

## Target
shop-core

---

## Goal
`019`(Shipment 모델 + 배송 생성 `preparing`) 위에 **배송 시작** 전이를 추가한다. 관리자가 `preparing` 배송에 **운송장 정보(택배사·운송장번호)** 를 기록하며 배송을 시작하면:
- 배송 `preparing → shipping`, `carrier`/`trackingNumber`/`shippedAt` 기록.
- 주문 rollup: 배송 중 하나라도 `shipping`이면 주문 `preparing → shipping`.
- **`ShippingStartedEvent`(topic `shipping-started`)를 Transactional Outbox로 발행**(같은 트랜잭션).

소비자는 자기 주문 상세의 배송 목록에서 **배송 추적정보**(택배사·운송장·배송시작시각)를 읽기 전용으로 확인한다.

> **이벤트 계약 개정**: 현재 `docs/event-catalog.md`의 `ShippingStartedEvent`는 **주문 단위(단일 carrier/trackingNumber, items 없음)** 다. 배송이 Shipment 단위(019)가 되었으므로 이를 **배송 단위로 개정**한다 — `shipmentId` + **`items[]`(이 배송 항목: productId·productName·quantity) 추가**. **현재 이 토픽을 구독하는 notification 컨슈머가 없어 개정이 안전**하며, 발행처를 처음 구현하는 지금이 변경 적기다. event-contract-rule에 따라 **`docs/event-catalog.md`(필드 SSOT)를 코드보다 먼저** 개정한다. **`docs/architecture.md` §5는 토픽·발행/소비 모듈 행만 있고 필드 상세가 없어(필드는 event-catalog 참조) 변경하지 않는다(정합6).**

> **분할**: 019(모델+생성) → **020(본 Task: 시작+이벤트)** → 021(완료). 본 Task는 **배송 완료(`delivered`) 전이를 구현하지 않는다**(021).

> **범위 한정**: 전이 주체는 **관리자(`ROLE_ADMIN`)**. 판매자 범위 이행·라인 수량 분할은 범위 밖.

---

## Context
- **선행(구현 완료 전제)**
  - `019`: `shipments`/`shipment_items` 스키마(status CHECK에 `shipping` 이미 포함), `Shipment`(`preparing` 생성), `OrderFulfillmentService.createShipment`, 주문 rollup `paid→preparing`, 주문 row 비관락 직렬화, admin 배송 생성 View, 소비자 배송 목록 조회.
  - `016`: **이벤트 발행 완결성 사전검증(items[].productId 해석, P2)** — PG 호출 전 사전검증 패턴. **금액/스칼라 변환·`member.spi` 연락처 해석·`ApplicationEventPublisher` Outbox 발행** 패턴.
  - `product.spi.ProductOrderCatalog`: `variantId→productId` 해석(기존). `member.spi`: `userId→email/name`(기존, 016에서 도입).
- **이벤트 계약(코드보다 문서 먼저 — event-contract-rule)**
  - `ShippingStartedEvent`(topic `shipping-started`)를 **배송 단위로 개정**한다. 개정 페이로드(SSOT): 공통 봉투(`eventId`,`occurredAt`) + `orderId`/`orderNumber`/**`shipmentId`(신규)**/`memberId`(=주문 userId)/`memberEmail`/`memberName`/`carrier`/`trackingNumber`/**`items[]`(productId·productName·quantity, 신규)**/`shippedAt`.
  - `docs/event-catalog.md`의 필드표·예시 JSON을 **코드보다 먼저** 갱신한다(topic `shipping-started`·발행 모듈 `order`·소비자 `notification` 유지). **`docs/architecture.md` §5는 무변경**(정합6 — §5는 토픽 표만 있고 필드 상세 부재, event-catalog가 SSOT). 필요 시 배송 단위 개정을 가리키는 주석 1줄만 허용.
- **모듈 소유**: `ShippingStartedEvent`·배송 시작 서비스·전이는 `order` 모듈(배송 = order 책임). 페이로드 연락처는 `order → member.spi`, 항목 productId는 `order → product.spi`(기존 방향). 새 cross-module 의존 없음.
- **권한**: 배송 시작은 `ROLE_ADMIN`(019와 동일). 소비자는 자기 주문 추적정보 읽기 전용.

## API Authorization

| API | 공개 여부 | 최소 권한 | 소유권 검사 | 비고 |
|---|---|---|---|---|
| `POST /api/v1/admin/shipments/{shipmentId}/ship` | authenticated | `ROLE_ADMIN` | 불필요(관리자) | `preparing → shipping` + `ShippingStartedEvent`. body: `carrier`,`trackingNumber` |
| `POST /admin/shipments/{shipmentId}/ship` (View) | authenticated | `ROLE_ADMIN` | 불필요(관리자) | 배송 시작 폼, 성공 flashSuccess / 불가 flashError |
| `GET /orders/{orderId}` (기존, View) | authenticated | `ROLE_CONSUMER`(+상위) | 필요 | 본인 주문 배송 추적정보 읽기(표시 확장) |

- 관리자 경로는 `/api/v1/admin/**`·`/admin/**`(`hasRole("ADMIN")`)에 포함 — 확인 후 필요 시 명시(019/016/018 선례). `/api/v1/admin/shipments/**`·`/admin/shipments/**` 포함 여부 확인.

## Requirements
- **도메인(order 모듈, Setter 금지·의도 메서드)**
  - `Shipment.markShipping(String carrier, String trackingNumber, Instant shippedAt)`: **`preparing → shipping`만 허용**하고 carrier/trackingNumber/shippedAt 기록. **`preparing`이 아닌 상태(이미 `shipping`/`delivered`/역방향)에서 호출하면 도메인 예외**(전이 불가). **메서드 자체는 멱등이 아니다 — 멱등 처리 책임은 서비스가 소유**(정합3): 서비스는 shipment가 `preparing`일 때만 `markShipping`을 호출하고, 이미 `shipping`이면 호출 전에 현재 `ShipmentResponse`를 `200`으로 반환한다(아래 이행 오케스트레이션). "상위 분기 또는 메서드 멱등" 이중 명세를 제거한다.
  - `Order.markShipping()`: rollup `preparing → shipping`. 그 외 상태 호출은 도메인 예외.
- **이행 오케스트레이션(order 모듈)** — 예: `OrderFulfillmentService.ship(shipmentId, carrier, trackingNumber)`(`@Transactional`)
  1. **shipment의 `orderId`만 스칼라 projection으로 조회**(`ShipmentRepository.findOrderIdById` 등 — 엔티티 적재 금지, `findById(...).getOrderId()` 사용 금지) → **해당 주문 row `PESSIMISTIC_WRITE` 잠금**(`findByIdForUpdate`) — 동시 이행·`018` 취소와 직렬화. **이 시점까지 shipment 엔티티를 영속성 컨텍스트에 적재하지 않는다**(정합1 — stale read 방지).
  2. **주문 락 보유 상태에서 shipment 엔티티를 비로소 최초 적재**(`findById`)해 상태를 권위 재검증한다(락 이전엔 어떤 경로로도 shipment 엔티티를 로드하지 않았으므로 항상 fresh — 정합1). `preparing`이면 진행. **이미 `shipping`이면 `markShipping` 호출 없이 현재 `ShipmentResponse`를 `200`으로 멱등 반환**(상태 불변, **`ShippingStartedEvent` 재발행 금지**). `delivered`/역방향 또는 주문이 취소·환불 → `409`. `carrier`/`trackingNumber` 누락 → `400`.
     - **정합1(동시성 stale read 방지)**: 락(order)과 판정 대상(shipment)이 다른 엔티티라, shipment를 락 전에 엔티티로 읽으면 동시 `ship` 시 직렬화되더라도 두 번째 트랜잭션이 **JPA 1차 캐시의 stale `preparing`** 으로 판정해 이벤트를 중복 발행한다. 따라서 **① orderId는 스칼라 projection으로만, ② shipment 엔티티 최초 적재는 반드시 주문 락 획득 이후**로 강제한다. (컨트롤러/facade가 같은 트랜잭션에서 shipment를 미리 엔티티로 로드하지 않도록 경계 유지.)
  3. **이벤트 발행 완결성 사전검증(P2)**: 이 배송 항목들의 `productId`를 `ProductOrderCatalog`로 해석한다. **해석 불가의 정의(정합5)** = `OrderItem.variantId`가 `null`(variant 삭제로 FK `SET NULL`) **또는** `getOrderableSnapshots`가 그 variantId를 반환하지 않음(행 삭제)인 경우에 **한한다**. **variant가 단지 비활성·품절(`active=false`/`purchasable=false`/`stock=0`)인 것은 거부하지 않는다** — 이미 결제·생성된 배송이므로 productId 해석만 가능하면 진행한다. 하나라도 해석 불가면 **전이·발행 전에 `409`**. 연락처(`memberEmail`/`memberName`)도 `member.spi`로 해석.
     - **P2 목적 정정(정합5)**: 020은 외부 PG 호출이 없어 트랜잭션이 원자 롤백되므로, 본 사전검증의 목적은 016식 "비가역 부작용(결제 승인) 방지"가 **아니라** 해석 불가 시 `500`(NPE 등) 대신 **명확한 `409`로 응답**하는 것이다. fallback(임의 productId 추정/항목 생략)은 두지 않는다.
  4. `Shipment.markShipping(...)` + **rollup: 주문이 `preparing`이면 `Order.markShipping()`**(이미 `shipping`이면 주문 status 불변 — 멀티 배송).
  5. **`ShippingStartedEvent` 구성·발행** — `ApplicationEventPublisher`(같은 트랜잭션 = Outbox 저장, 004 외부화). 페이로드는 개정 스키마(shipmentId·items[]·carrier·trackingNumber·연락처·shippedAt).
  6. 커밋 → `200` + 갱신 ShipmentResponse.
  - **거부는 직접 throw, 멱등은 200 반환, Outcome 값 패턴 미채택(모순2)**: 잘못된 전이(이미 delivered/역방향/취소된 주문)는 `OrderFulfillmentConflictException`(409)을 **직접 throw**(부작용 전 판정), 입력 누락은 `400`. **이미 `shipping`(멱등)은 예외가 아니라 현재 `ShipmentResponse`를 `200`으로 반환**(이벤트 재발행만 내부 if로 차단). **멱등 판정 키는 shipment 상태(`shipping`)뿐(정합4)** — 이미 `shipping`인 배송에 대한 재요청은 본문 `carrier`/`trackingNumber` 값과 **무관하게** 기존 추적정보를 변경 없이 반환한다(배송정보 수정은 범위 밖이므로 본문 불일치도 오류가 아니며, 기존 값을 덮어쓰지 않는다). 018 Outcome은 payment→order.spi cross-module 경계 때문이었고, 이행 서비스는 order 모듈 내부 직접 호출이라 값-매핑 indirection을 두지 않는다. 성공/멱등 모두 `ShipmentResponse`(Entity 미노출 scalar record) 반환.
- **이벤트 페이로드 구성**
  - `productId`는 `ProductOrderCatalog`(variantId→productId), `productName`/`quantity`는 `order_items`(또는 shipment_items↔order_items) 스냅샷, 연락처는 `member.spi`. 자족 — notification 역조회 금지.
  - `items[]`는 **이 배송(shipment)에 포함된 항목만** 담는다(주문 전체가 아니라 해당 배송분).
- **멱등·동시성**: 같은 배송 `ship` 중복은 부작용 없이 멱등 반환(이벤트 재발행 없음). 주문 row 락이 동시 이행·취소와 직렬화한다.
- **`018` 취소와의 상호작용**: 주문이 `preparing`/`shipping`이면 `018` 취소 가드가 취소를 차단(409). 본 Task는 그 역(취소/환불된 주문의 shipment를 `ship` 시도)도 주문 row 락 후 재검증으로 `409` 처리한다(모순 방지).
- **`ShipmentResponse` DTO 확장(정합2 — 019 DTO 수정)** — 현재 `ShipmentResponse`는 `{shipmentId, orderId, status, items}`로 추적정보 필드가 없다. `shipping` 응답·소비자 상세에 carrier·trackingNumber·shippedAt이 필요하므로 **`carrier`(nullable)·`trackingNumber`(nullable)·`shippedAt`(nullable `Instant`) 3개 필드를 추가**한다. **레코드 시그니처가 바뀌므로 기존 모든 생성 지점**(`OrderFulfillmentService.createShipment`, `getShipments`→`toShipmentResponseWithDetails`, admin facade 변환)을 새 시그니처로 갱신한다(`preparing` 배송은 3필드 null). `seller_id` 등 내부 필드는 계속 노출 금지.
- **REST Controller**(`order/controller`, 019의 컨트롤러 확장) — `POST /api/v1/admin/shipments/{shipmentId}/ship`. `carrier`/`trackingNumber` 필수 검증.
- **Admin ViewController**(`web/order`, 019 확장) — `POST /admin/shipments/{shipmentId}/ship`(carrier/trackingNumber 입력 폼, 노출 조건: shipment=`preparing`). 성공 flashSuccess, `BusinessException` catch → flashError + redirect.
- **소비자 View 신설(정합4 — 019에서 이연)** — 019가 미룬 **소비자 배송 목록 표시를 본 Task에서 도입**한다: `OrderResponse`에 `List<ShipmentResponse> shipments` 필드 추가 + `OrderDtoMapper`(또는 `OrderFacadeImpl`)에서 주문의 배송 목록 매핑 + `templates/order/detail.html`에 배송 목록 블록(배송별 status·포함 항목, `shipping` 배송엔 택배사·운송장·배송시작시각). 목록 화면은 기존 rollup status 라벨(`배송 중`)로 충분. 소비자 응답에 `seller_id` 등 내부 필드 노출 금지.
- **`SecurityConfig`** — `/api/v1/admin/shipments/*/ship`·`/admin/shipments/**`가 `ROLE_ADMIN` 정책에 포함되는지 확인 후 필요 시 명시.
- Entity를 응답·View 모델에 직접 전달하지 않는다. 단위·통합(Outbox)·REST/Security·View·구조 테스트 작성.

## Constraints
- **이벤트 계약 개정은 문서 먼저**: `ShippingStartedEvent`를 배송 단위(`shipmentId`+`items[]`)로 개정하되 `docs/event-catalog.md`를 **코드보다 먼저** 갱신. **`docs/architecture.md` §5는 필드 상세가 없어 무변경(정합6).** topic·발행 모듈·소비자 유지(구독 컨슈머 없음 — 안전한 개정 적기).
- **본 Task는 배송 완료(`delivered`)를 구현하지 않는다**(021). `Shipment.markShipping`/`Order.markShipping`까지만.
- **배송 단위 모델**: 추적정보는 `shipments` 소유. `orders`에 주문단위 배송 컬럼 추가 금지. rollup `→shipping`은 단조 전진, 부분 배송도 `shipping`(새 상태값 없음).
- **모듈 순환 의존 금지**: 이벤트·서비스·전이를 `order` 모듈에. 새 cross-module 의존 금지(기존 `order → member.spi`/`order → product.spi`만). `ModularityTests` 그린.
- **신규 migration 없음**: 019의 `shipments`/`shipment_items`(status CHECK에 `shipping` 포함)로 충분. 컬럼 추가 불필요.
- **성공은 원자 커밋, 거부는 부작용 전 판정, 멱등**: 전이+이벤트는 한 트랜잭션 원자 커밋(`200`). 잘못된 전이/누락은 부작용 전 `409`/`400`. `ship` 중복은 이벤트 재발행 없음. P2 해석 불가는 부작용 없이 `409`.
- **관리자 단일 주체**: 판매자 범위 이행은 범위 밖. 소유권 검사는 소비자 읽기 경로에만.
- 비밀/민감정보·Entity·로컬 경로·`ownerId` 페이로드/응답 노출 금지. `notification` 미참조. Controller 비즈니스 로직 금지, DTO/Entity 분리.

## Files
> 정확한 경로는 plan에서 확정.
- (신규) `order/event/ShippingStartedEvent`(`@Externalized("shipping-started")`, 배송 단위 개정 페이로드)
- (수정) `order/domain/Shipment`(`markShipping`), `order/domain/Order`(rollup `markShipping`)
- (수정) `order/service/OrderFulfillmentService`(`ship` 추가, P2 사전검증, 이벤트 발행)
- (수정) `order/controller/AdminOrderFulfillmentRestController`(`POST /api/v1/admin/shipments/{shipmentId}/ship`) + `order/dto`(신규 ShipRequest: carrier/trackingNumber)
- (수정) `order/dto/ShipmentResponse`(정합2 — `carrier`/`trackingNumber`/`shippedAt` 3필드 추가) + 모든 생성 지점(`OrderFulfillmentService.createShipment`·`getShipments`·admin facade) 시그니처 갱신
- (수정) `order/repository/ShipmentRepository`(정합1 — `findOrderIdById` 스칼라 projection + 락-뒤 shipment 최초 적재 경로)
- (수정) `web/order/AdminOrderViewController`(`POST /admin/shipments/{shipmentId}/ship`) + `templates/admin/orders.html`(배송 시작 폼)
- (수정) `order/spi/OrderFacade`의 `OrderResponse`에 `List<ShipmentResponse> shipments` 추가(정합4 — 019 이연) + `OrderFacadeImpl`/`OrderDtoMapper` 매핑
- (수정) `templates/order/detail.html`(소비자 배송 목록 블록 + `shipping` 추적정보 신설), `templates/order/list.html`(`배송 중` 라벨 — 기존 라벨로 충분)
- (수정) `security/SecurityConfig`(배송 시작 경로 권한 확인/명시)
- (문서) `docs/event-catalog.md`(ShippingStartedEvent 배송 단위 개정). **`docs/architecture.md` §5는 무변경**(정합6 — 필드 상세 부재, event-catalog 참조)

## Module Boundary Contract

| 항목 | 위치 | 규칙 |
|---|---|---|
| ShippingStartedEvent | `order/event` | `order` 발행 소유, `@Externalized("shipping-started")`, 배송 단위(shipmentId+items[]) |
| 배송 시작 Service | `order/service` | 주문 row 비관락 + 상태 재검증 + 전이 + rollup + 이벤트 발행 |
| 배송 시작 REST | `order/controller` | `/api/v1/admin/shipments/{id}/ship`, `ServiceResponse`. order 모듈(순환 없음) |
| Admin ViewController | `web/order` | Thymeleaf SSR, order spi facade만 의존 |
| 연락처 해석 | `member/spi` | `userId`→`email`/`name`(기존 재사용), Entity 노출 금지 |
| productId 해석 | `product/spi` | `ProductOrderCatalog` variantId→productId(기존 재사용), Entity 노출 금지 |

- 새 cross-module 의존을 만들지 않는다. `ModularityTests` 통과.

## Backend - View Contract

| 항목 | 값 |
|---|---|
| 배송 시작 폼 | `POST /admin/shipments/{shipmentId}/ship`(carrier/trackingNumber 입력, 노출 조건: shipment=`preparing`) |
| 시작 성공 | flashSuccess + redirect(`/admin/orders` 또는 주문 상세) |
| 시작 불가(409 등)/입력 누락(400) | `BusinessException`/검증 실패 catch → flashError + redirect(부작용 없음) |
| 소비자 상세 표시 | `order/detail` 배송 목록에서 `shipping` 배송에 택배사·운송장·배송시작시각 |
| 소비자 목록 표시 | `order/list` rollup `배송 중` 라벨 |

> 폼은 CSRF 토큰 포함. 비인증 admin `/login` redirect, ROLE 부족 403.

## API Response Contract
- 배송 시작: `200` + `ShipmentResponse`(status `shipping`·carrier·trackingNumber·shippedAt·포함 항목). 멱등 재시작도 동일 결과 `200` — **이미 `shipping`인 배송은 본문 carrier/trackingNumber와 무관하게 기존 추적정보를 변경 없이 반환(정합4)**.
- 잘못된 전이(이미 delivered/역방향/취소된 주문): `409` + `ErrorResponse`. `carrier`/`trackingNumber` 누락: `400`. productId 해석 불가(P2): `409`.
- 미존재 배송: `404`. 비인증 `401`(REST)/`/login`(View), 권한 부족 `403`.
- 응답에 Entity·`ownerId`·로컬 경로·member 내부정보 미포함. `status` lowercase.

## Acceptance Criteria
- `preparing` 배송 `ship`(carrier/trackingNumber) → 배송 `shipping` + carrier/tracking/shippedAt 기록 + **주문 rollup `preparing→shipping`** + **`ShippingStartedEvent` 1건 Outbox(`event_publication`) 저장**, 페이로드가 개정 스키마(shipmentId·items[]·carrier·trackingNumber·memberEmail/Name·shippedAt) 만족.
- `items[]`는 해당 배송에 포함된 항목만 담는다(주문 전체 아님).
- 멀티 배송: 한 주문에 배송 2건이 있을 때 각 `ship`마다 해당 배송 항목만 담은 `ShippingStartedEvent` 1건씩 발행. 첫 배송 `ship` 시 주문 `→shipping`, 둘째 배송 `ship` 시 주문 status 불변(`shipping`).
- 같은 배송 `ship` 중복 호출 → **멱등 200**, 상태 불변, **이벤트 재발행 없음**(다른 carrier/trackingNumber로 재호출해도 기존 값 유지 — 정합4).
- **동시 `ship`(동일 배송)**: 주문 row 락으로 직렬화되며, 두 번째 트랜잭션은 **락 획득 후 fresh 재조회한 shipment 상태(`shipping`)** 로 멱등 판정해 이벤트를 중복 발행하지 않는다(정합1 — 락 전 엔티티 적재 금지, stale read 차단).
- `carrier`/`trackingNumber` 누락 → `400`, 상태 불변·이벤트 미발행.
- productId 해석 불가(`variantId` null/행 삭제) 항목 포함 배송 `ship` → **전이·발행 전 `409`**(P2), 이벤트 미생성. **variant가 단지 비활성·품절인 항목은 거부하지 않고 정상 진행(정합5)**.
- 이미 `delivered`/취소·환불된 주문의 배송 `ship` 시도 → `409`, 상태 불변, 이벤트 미발행.
- 배송 시작은 **`ROLE_ADMIN`만** — 비인증 401, 비ADMIN 403.
- 소비자는 자기 주문 상세 배송 목록에서 `shipping` 추적정보를 조회(타인 주문 404).
- 전이+이벤트는 부분 반영 없이 원자 커밋. 시스템 오류 시 전체 롤백(상태·이벤트).
- `018` 상호작용: 배송 시작 vs 취소 동시 → 주문 row 락 직렬화, 모순(취소된 주문 배송 시작) 없음.
- View: admin 배송 시작 폼(CSRF) 노출(preparing), 성공 flashSuccess·불가/누락 flashError. 소비자 상세 추적정보·목록 `배송 중` 라벨.
- `docs/event-catalog.md`의 `ShippingStartedEvent`가 배송 단위로 개정됨(코드보다 문서 먼저). `docs/architecture.md` §5는 무변경(정합6 — 필드 상세 부재).
- `ModularityTests`/구조 테스트 통과. `019`/`016`/`018` 회귀 없음.

## Test
- 단위: `Shipment.markShipping`(허용 `preparing`/금지/멱등, carrier·tracking·shippedAt 기록). `Order.markShipping()` 허용(`preparing`)·금지.
- 단위(Mockito): `OrderFulfillmentService.ship` — preparing→shipping + 이벤트 구성 + rollup, 멀티 배송 시 둘째는 주문 status 불변, P2 productId 해석 불가 409(`variantId` null/스냅샷 부재만 — **비활성·품절 variant는 통과, 정합5**), 입력 누락 400, 멱등 재호출 이벤트 1회(**다른 carrier/tracking 본문도 기존 값 유지, 정합4**), **orderId 스칼라 projection→주문 락→shipment 최초 적재 순서**(정합1 — 락이 shipment 엔티티 적재보다 먼저). `ShippingStartedEvent` items[]/shipmentId/연락처 매핑(해당 배송분만).
- 통합(Testcontainers + Modulith): ship 커밋 시 `event_publication`에 `ShippingStartedEvent` 1건 + 개정 payload 스키마. 멀티 배송 각 ship마다 이벤트 1건(해당 항목만). 멱등 ship 재호출 이벤트 추가 없음. 시스템 오류 시 부분 반영 없음.
- 동시성(Testcontainers): 동일 배송 동시 ship → **1건만 전이/발행, 이벤트 1건만**(정합1 — 락 후 fresh 재조회로 두 번째가 stale `preparing`을 보지 않음. 락 전 shipment 엔티티 적재 흐름이면 이 테스트가 실패하도록 설계). row 정합. 배송 시작 vs `018` 취소 동시 → 직렬화, 모순 없음.
- REST/Security: ship 200 / 잘못된 전이 409 / 입력 누락 400 / P2 409 / 미존재 404, ADMIN 200·비인증 401·비ADMIN 403, 응답 내부정보 비노출.
- View: admin 배송 시작 폼(CSRF) 렌더링, 성공 redirect+flashSuccess, 불가/누락 flashError. 소비자 상세 추적정보·목록 라벨. 비인증 admin `/login` redirect.
- 구조: `ShippingStartedEvent` order 모듈 위치, 이행 코드 payment.spi/payment 미의존, `web.order` 도메인 내부 직접 참조 안 함, `ModularityTests.verify()` 통과.

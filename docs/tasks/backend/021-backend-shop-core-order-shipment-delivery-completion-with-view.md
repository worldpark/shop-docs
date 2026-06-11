# 021. shop-core 주문 이행 — 배송 완료(delivered) (with View)

## Target
shop-core

---

## Goal
`019`(Shipment 모델 + 생성 `preparing`)·`020`(배송 시작 `shipping` + ShippingStartedEvent) 위에 **배송 완료** 전이를 추가해 배송 라이프사이클을 마무리한다. 관리자가 `shipping` 배송을 완료 처리하면:
- 배송 `shipping → delivered`, `deliveredAt` 기록.
- 주문 rollup: **모든 order_items가 배송에 배정되고 모든 배송이 `delivered`면** 주문 `shipping → delivered`. 아니면 주문 status 불변(`shipping` 유지 — 부분 배송 완료).

소비자는 자기 주문 상세 배송 목록에서 `delivered` 상태·배송완료시각을 읽기 전용으로 확인한다.

> **분할**: 019(모델+생성) → 020(시작+이벤트) → **021(본 Task: 완료)**. 본 Task는 배송 라이프사이클의 종착점이다.

> **범위 한정**: 전이 주체는 **관리자(`ROLE_ADMIN`)**. 소비자 구매확정(자동/수동 `delivered` 확정), 반품/교환(`delivered` 이후), **배송완료 알림 이벤트**는 범위 밖이다(배송완료 이벤트는 카탈로그 미정의 — 필요 시 후속에서 문서 먼저 추가).

---

## Context
- **선행(구현 완료 전제)**
  - `019`: `shipments`/`shipment_items` 스키마(status CHECK에 `delivered` 이미 포함, `delivered_at` 컬럼 존재), `Shipment`(`preparing` 생성), 주문 row 비관락 직렬화, admin 배송 관리 View, 소비자 배송 목록.
  - `020`: `Shipment.markShipping`, `Order.markShipping` rollup, `OrderFulfillmentService.ship`, `ShippingStartedEvent`(배송 단위). 소비자 추적정보 표시.
  - `018`: 취소 가드(orders.status가 이행단계/종결이면 취소 409) — `delivered`도 취소 불가 상태. 주문 row 락 직렬화.
- **상태값**: `orders.status` CHECK에 `delivered` 포함(V1). `shipments.status` CHECK에 `delivered` 포함(019). 신규 migration 불필요(`delivered_at`은 019에서 이미 추가).
- **모듈 소유**: 배송 완료 전이는 `order` 모듈(배송 = order 책임). 외부계·이벤트 없음 → 새 의존 없음. payment/payment.spi 무관.
- **권한**: 배송 완료는 `ROLE_ADMIN`(019/020과 동일). 소비자는 자기 주문 읽기 전용.

## API Authorization

| API | 공개 여부 | 최소 권한 | 소유권 검사 | 비고 |
|---|---|---|---|---|
| `POST /api/v1/admin/shipments/{shipmentId}/deliver` | authenticated | `ROLE_ADMIN` | 불필요(관리자) | `shipping → delivered` |
| `POST /admin/shipments/{shipmentId}/deliver` (View) | authenticated | `ROLE_ADMIN` | 불필요(관리자) | 배송 완료 폼, 성공 flashSuccess / 불가 flashError |
| `GET /orders/{orderId}` (기존, View) | authenticated | `ROLE_CONSUMER`(+상위) | 필요 | 본인 주문 배송완료 상태 읽기(표시 확장) |

- 관리자 경로는 `/api/v1/admin/shipments/**`·`/admin/shipments/**`(`hasRole("ADMIN")`)에 포함 — 020에서 이미 명시됐다면 그대로, 누락 시 명시.

## Requirements
- **도메인(order 모듈, Setter 금지·의도 메서드)**
  - `Shipment.markDelivered(Instant deliveredAt)`: **`shipping → delivered`만 허용**하고 deliveredAt 기록. **`shipping`이 아닌 상태(이미 `delivered`/`preparing`/역방향)에서 호출하면 도메인 예외**(메서드 자체는 멱등이 아니다 — 정합4, 020 `markShipping`과 동일 패턴). **멱등 처리 책임은 서비스가 소유**: 서비스는 shipment가 `shipping`일 때만 `markDelivered`를 호출하고, 이미 `delivered`이면 호출 전에 현재 응답을 `200`으로 멱등 반환한다.
  - `Order.markDelivered()`: rollup `shipping → delivered`만 허용. 그 외 상태 호출은 도메인 예외(메서드 멱등 아님 — 서비스가 rollup 조건 충족 시에만 호출, 주문이 이미 `delivered`면 멱등 경로에서 호출되지 않음).
- **이행 오케스트레이션(order 모듈)** — 예: `OrderFulfillmentService.deliver(shipmentId)`(`@Transactional`)
  1. **shipment의 `orderId`만 스칼라 projection으로 조회**(`ShipmentRepository.findOrderIdById` — 020에서 추가됨, 엔티티 적재 금지) → **해당 주문 row `PESSIMISTIC_WRITE` 잠금**(`findByIdForUpdate`) → **락 후 shipment 엔티티 최초 적재**(`findById`)해 fresh 재검증 — 동시 이행·`018` 취소와 직렬화.
     - **정합1(020 계승, stale read 차단)**: 락 대상(order)과 판정 대상(shipment)이 다른 엔티티라, shipment를 락 전에 엔티티로 읽으면 멀티 배송 동시 `deliver` 시 JPA 1차 캐시의 stale `shipping`으로 rollup·멱등 판정을 그르친다. `deliver`는 020 `ship`과 **구조가 동일**하므로 동일 패턴을 적용한다(`findOrderIdById` 재사용).
  2. 상태 권위 재검증(락 보유): 주문이 `cancelled`/`refunded` → `409`. **방어 가드(020 계승)**: 정상 흐름에서 배송이 `shipping`이면 주문도 `shipping`이어야 하므로 주문이 `shipping`이 아니면 `409`. shipment가 `shipping`이면 진행. **이미 `delivered`이면 `markDelivered` 호출 없이 현재 응답을 `200`으로 멱등 반환**(상태 불변). 그 외(`preparing`/역방향) → `409`.
  3. **시각 1회 캡처** `Instant now`(deliveredAt). `Shipment.markDelivered(now)`.
  4. **rollup 판정(기존 쿼리 재사용 — 신규 Repository/쿼리 금지)**: `order.getItems()`(전 항목) − `ShipmentRepository.findAssignedOrderItemIds(orderId)`(배정 항목)로 **미배정 항목 0** 판정 **&&** `ShipmentRepository.findByOrderId(orderId)`로 **전 배송 `delivered`** 판정(방금 `markDelivered`한 shipment의 새 상태를 포함해야 정확 — 같은 트랜잭션 재조회가 managed `delivered`를 반영). 둘 다 충족이면 `Order.markDelivered()`. 아니면 주문 status 불변(`shipping` 유지 — 부분 배송 완료는 `shipping`에 접힘).
  5. 커밋 → `200` + **`DeliverResponse`**(갱신 `ShipmentResponse` + 주문 종착 여부 `orderDelivered` — 정합5).
  - **거부는 직접 throw, 멱등은 200 반환, Outcome 값 패턴 미채택(모순2)**: 잘못된 전이(`preparing`/역방향/종결 주문)는 `OrderFulfillmentConflictException`(409)을 **직접 throw**(부작용 전 판정). **이미 `delivered`(멱등)은 현재 상태를 `200`으로 반환**. 018 Outcome은 cross-module 경계 때문이었고, 이행 서비스는 order 모듈 내부 직접 호출이라 indirection을 두지 않는다.
  - **정합5 — 주문 종착 여부는 deliver 전용 응답 래퍼로 분리(공유 DTO 오염 금지)**: 주문이 `delivered`로 종착했는지는 **`DeliverResponse(ShipmentResponse shipment, boolean orderDelivered)`** 같은 **deliver 엔드포인트 전용 래퍼**로 표현한다. 공유 DTO인 `ShipmentResponse`(ship 응답·소비자 `OrderResponse.shipments`·admin facade 공용)에 **주문 단위 일시 플래그를 넣지 않는다** — 소비자 배송 목록 각 항목에 `orderDelivered`가 붙으면 `order.status`와 중복되고 의미가 어색하다. `orderDelivered`는 **전이 발생 여부가 아니라 현재 주문 status가 `delivered`인지**로 계산(멱등 재완료도 일관). 거부 분류용 Outcome enum이 아니라 성공 응답의 스칼라 플래그다. Entity 미노출 scalar record.
  - **deliver는 이벤트·member.spi·product.spi 의존 없음**: 배송완료 이벤트는 범위 밖(카탈로그 미정의)이라 `ApplicationEventPublisher`/P2 사전검증/연락처 해석이 불필요하다. 020 `ship`보다 서비스 의존이 단순하다(`OrderRepository`·`ShipmentRepository`만 — 불필요 의존 주입 금지).
- **rollup 판정 정확성**
  - "모든 항목 배정"은 `order_items` 중 `shipment_items`에 없는 항목이 0인지로 판정한다(미배정 항목이 있으면 주문은 아직 `delivered`가 아니다 — 일부 항목이 배송 생성조차 안 됨).
  - 단조 전진: 한 번 `delivered`가 된 주문은 되돌리지 않는다.
- **멱등·동시성**: 같은 배송 `deliver` 중복은 부작용 없이 멱등 반환. 주문 row 락이 동시 이행·취소와 직렬화. 멀티 배송에서 마지막 배송 완료가 주문 `delivered`를 트리거한다(동시 완료 시 락으로 직렬화되어 rollup 한 번만 전이).
- **`ShipmentResponse` DTO 확장(정합3 — deliveredAt 추가)** — 현재 `ShipmentResponse`는 `{shipmentId, orderId, status, carrier, trackingNumber, shippedAt, items}`로 **`deliveredAt`이 없다**(020에서 carrier/trackingNumber/shippedAt까지만 추가). `delivered` 응답·소비자 상세에 배송완료시각이 필요하므로 **`deliveredAt`(nullable `Instant`) 1필드 추가**한다. 레코드 시그니처가 바뀌므로 **기존 모든 생성 지점**(`OrderFulfillmentService.buildShipmentResponse`·`createShipment`·`toShipmentResponseWithDetails`, `AdminOrderFulfillmentFacadeImpl`)을 새 시그니처로 갱신한다(`delivered`가 아니면 null).
- **REST Controller**(`order/controller`, **020이 신설한 `AdminShipmentRestController` 확장 — 정합2**) — `POST /api/v1/admin/shipments/{shipmentId}/deliver`. base path가 `/api/v1/admin/shipments/...`라 `AdminOrderFulfillmentRestController`(=`/api/v1/admin/orders/...`)가 **아니라** `AdminShipmentRestController`에 추가한다.
- **Admin ViewController**(`web/order`, **020이 신설한 `AdminShipViewController` 확장 — 정합2/C3**) — `POST /admin/shipments/{shipmentId}/deliver`(노출 조건: shipment=`shipping`). 성공 flashSuccess, `BusinessException` catch → flashError + redirect. `AdminOrderViewController`는 `@RequestMapping("/admin/orders")` 클래스 매핑이라 Spring MVC가 경로를 결합(`/admin/orders/admin/shipments/...`)해 사용 불가 — 020이 분리한 클래스 매핑 없는 `AdminShipViewController`에 핸들러를 추가한다. View는 `AdminOrderFulfillmentFacade.deliver`(신규) 경유(web→order.spi 단방향).
- **소비자 View 확장**(기존 핸들러) — 배송 목록에서 `delivered` 배송에 배송완료시각 표시. 주문이 `delivered`면 목록 rollup 라벨(`배송 완료`).
- **`SecurityConfig`** — `/api/v1/admin/shipments/*/deliver`·`/admin/shipments/**` `ROLE_ADMIN` 포함 확인(020에서 대부분 커버).
- Entity를 응답·View 모델에 직접 전달하지 않는다. 단위·통합·REST/Security·View·구조 테스트 작성.

## Constraints
- **본 Task는 배송 라이프사이클의 완료만 다룬다**: `Shipment.markDelivered`/`Order.markDelivered` rollup. 배송완료 이벤트·구매확정·반품/교환은 범위 밖.
- **신규 migration 없음**: 019의 스키마(`shipments.status` CHECK `delivered`, `delivered_at`)로 충분.
- **rollup 단조 전진**: `delivered`는 전 항목 배정 && 전 배송 delivered일 때만. 부분 배송 완료는 `shipping` 유지(새 상태값 없음). 되돌림 없음.
- **모듈 순환 의존 금지**: 전이를 `order` 모듈에. 새 cross-module 의존 금지. `ModularityTests` 그린.
- **성공은 원자 커밋, 거부는 부작용 전 판정, 멱등**: 전이+rollup은 한 트랜잭션 원자 커밋(`200`). 잘못된 전이는 부작용 전 `409`. `deliver` 중복은 멱등.
- **관리자 단일 주체**: 소유권 검사는 소비자 읽기 경로에만. `notification` 미참조. Entity·로컬 경로 노출 금지. Controller 비즈니스 로직 금지, DTO/Entity 분리.

## Files
> 정확한 경로는 plan에서 확정. 본 Task는 신규 파일이 적고 대부분 019/020 확장.
- (수정) `order/domain/Shipment`(`markDelivered` — shipping→delivered만, 그 외 도메인 예외), `order/domain/Order`(rollup `markDelivered`)
- (수정) `order/service/OrderFulfillmentService`(`deliver` + rollup 판정. **정합1 락 순서** `findOrderIdById`→락→`findById`. rollup은 **기존 쿼리 재사용**)
- (신규) `order/dto/DeliverResponse`(정합5 — `ShipmentResponse shipment` + `boolean orderDelivered`)
- (수정) `order/dto/ShipmentResponse`(정합3 — `deliveredAt` 추가) + 모든 생성 지점(`buildShipmentResponse`·`createShipment`·`toShipmentResponseWithDetails`·`AdminOrderFulfillmentFacadeImpl`) 시그니처 갱신
- (변경 없음) `order/repository/ShipmentRepository` — `findOrderIdById`·`findAssignedOrderItemIds`·`findByOrderId` **기존 메서드로 충분, 신규 쿼리/Repository 추가 금지**(과설계 방지). `OrderItemRepository` 불요(`order.getItems()` 사용).
- (수정) `order/spi/AdminOrderFulfillmentFacade`(`deliver` 추가) + `order/service/AdminOrderFulfillmentFacadeImpl`(서비스 위임) — View가 service 직접 참조 안 하도록(web→spi 단방향)
- (수정) `order/controller/AdminShipmentRestController`(정합2 — 020 신설 컨트롤러에 `POST /api/v1/admin/shipments/{shipmentId}/deliver` 추가)
- (수정) `web/order/AdminShipViewController`(정합2/C3 — 020 신설 컨트롤러에 `POST /admin/shipments/{shipmentId}/deliver` 추가) + `templates/admin/orders.html`(배송 완료 폼)
- (수정) `templates/order/detail.html`(배송완료시각 표시), `templates/order/list.html`(`배송 완료` 라벨)
- (수정) `security/SecurityConfig`(배송 완료 경로 권한 확인)

## Module Boundary Contract

| 항목 | 위치 | 규칙 |
|---|---|---|
| 배송 완료 전이 | `order/domain` | `Shipment.markDelivered`/`Order.markDelivered`, setter 금지 |
| 배송 완료 Service | `order/service` | 주문 row 비관락 + 상태 재검증 + 전이 + rollup 판정 |
| 배송 완료 REST | `order/controller` | `/api/v1/admin/shipments/{id}/deliver`, `ServiceResponse`. order 모듈(순환 없음) |
| Admin ViewController | `web/order` | Thymeleaf SSR, order spi facade만 의존 |

- 새 cross-module 의존을 만들지 않는다. `ModularityTests` 통과.

## Backend - View Contract

| 항목 | 값 |
|---|---|
| 배송 완료 폼 | `POST /admin/shipments/{shipmentId}/deliver`(노출 조건: shipment=`shipping`) |
| 완료 성공 | flashSuccess + redirect(`/admin/orders` 또는 주문 상세) |
| 완료 불가(409 등) | `BusinessException` catch → flashError + redirect(부작용 없음) |
| 소비자 상세 표시 | `order/detail` 배송 목록에서 `delivered` 배송에 배송완료시각 |
| 소비자 목록 표시 | 주문 rollup `delivered`면 `배송 완료` 라벨 |

> 폼은 CSRF 토큰 포함. 비인증 admin `/login` redirect, ROLE 부족 403.

## API Response Contract
- 배송 완료: `200` + **`DeliverResponse`**(`ShipmentResponse`(status `delivered`·deliveredAt) + `orderDelivered` boolean). `orderDelivered`는 **현재 주문 status가 `delivered`인지**(전이 발생 여부가 아니라 — 멱등 재완료도 일관). 멱등 재완료도 동일 결과 `200`.
- 잘못된 전이(`preparing`/역방향/이미 종결 주문): `409` + `ErrorResponse`.
- 미존재 배송: `404`. 비인증 `401`(REST)/`/login`(View), 권한 부족 `403`.
- 응답에 Entity·`ownerId`·로컬 경로 미포함. `status` lowercase.

## Acceptance Criteria
- `shipping` 배송 `deliver` → 배송 `delivered` + deliveredAt 기록, `200`.
- 단일 배송 주문: 그 배송 `deliver` → **모든 항목 배정 && 모든 배송 delivered** 충족 → 주문 rollup `shipping→delivered`.
- 멀티 배송 주문: 일부 배송만 `delivered`이면 주문 status `shipping` 유지(부분 배송). **마지막 배송 완료** 시 주문 `delivered`로 전이.
- 미배정 항목이 남은 주문: 모든 생성된 배송이 `delivered`여도 주문은 `delivered`로 전이하지 않는다(`shipping` 유지).
- 같은 배송 `deliver` 중복 → **멱등 200**, 상태 불변.
- `preparing`/역방향/이미 종결(취소·환불) 주문의 배송 `deliver` 시도 → `409`, 상태 불변.
- 배송 완료는 **`ROLE_ADMIN`만** — 비인증 401, 비ADMIN 403.
- 소비자는 자기 주문 상세에서 `delivered` 배송완료시각·rollup 상태를 조회(타인 주문 404).
- 전이+rollup은 부분 반영 없이 원자 커밋. 시스템 오류 시 전체 롤백.
- 동시성: 멀티 배송 마지막 2건 동시 `deliver` → 주문 row 락 직렬화 + **락 후 shipment fresh 재조회(정합1)** 로 주문 rollup 한 번만 `delivered`로 전이(stale `shipping`으로 인한 중복 rollup·오판 없음). 배송 완료 vs `018` 취소 동시 → 직렬화.
- 신규 migration 없음(019 스키마로 충분). `ModularityTests`/구조 테스트 통과. `019`/`020`/`016`/`018` 회귀 없음.

## Test
- 단위: `Shipment.markDelivered`(허용 `shipping`/그 외 도메인 예외 — 메서드 멱등 아님(정합4), deliveredAt 기록). `Order.markDelivered()` 허용(`shipping`)·그 외 예외.
- 단위(Mockito): `OrderFulfillmentService.deliver` — shipping→delivered, rollup 판정(단일 배송 완료 시 주문 delivered / 멀티 배송 일부 완료 시 shipping 유지 / 미배정 항목 있으면 shipping 유지 / 마지막 배송 완료 시 delivered), 잘못된 전이 409, **취소/환불·비-shipping 주문 409**(방어 가드), 멱등 재호출(`markDelivered` 미호출·상태 불변), **`findOrderIdById` projection→주문 락→`findById(shipment)` 적재 순서**(정합1 — 락이 shipment 엔티티 적재보다 먼저), `DeliverResponse.orderDelivered`가 현재 주문 status 반영.
- 통합(Testcontainers): deliver 커밋 시 shipment·주문 status 전이 원자성. 멀티 배송 마지막 완료가 주문 delivered 트리거. 미배정 항목 시 shipping 유지. 멱등 재호출 상태 불변. **이벤트 미발행**(이 단계는 event_publication 무변화). 시스템 오류 시 부분 반영 없음.
- 동시성(Testcontainers): 멀티 배송 마지막 2건 동시 deliver → 주문 row 락 직렬화, rollup 한 번만 delivered. 배송 완료 vs `018` 취소 동시 → 직렬화, 모순 없음.
- REST/Security: deliver 200 / 잘못된 전이 409 / 미존재 404, ADMIN 200·비인증 401·비ADMIN 403, 응답 내부정보 비노출.
- View: admin 배송 완료 폼(CSRF) 렌더링(shipping), 성공 redirect+flashSuccess, 불가 flashError. 소비자 상세 배송완료시각·목록 `배송 완료` 라벨. 비인증 admin `/login` redirect.
- 구조: 배송 완료 코드 order 모듈 위치, payment.spi/payment 미의존, `web.order` 도메인 내부 직접 참조 안 함, `ModularityTests.verify()` 통과.

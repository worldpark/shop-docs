# 021 — 배송 완료(delivered) task 설계 정합 5건 수정 (Revision 1)

- 대상 Task: `docs/tasks/backend/021-backend-shop-core-order-shipment-delivery-completion-with-view.md`
- 대상 Plan: 미작성(plan 분해 전, "착수" 상태)
- 선행 Revision: `docs/plans/revisions/backend/020-...-revision-1.md`(정합1~6) — 그 §7이 "정합1·2·3·C2·C3가 021에 파급된다"고 이미 예고함
- 결정 일자: 2026-06-11
- 결정자: 사용자(021 배송 완료 task 설계 모순 점검 지시)
- 목적: 021 task를 **이미 구현·머지된 019/020 산출물**(`OrderFulfillmentService.ship`, `ShipmentRepository.findOrderIdById`, `ShipmentResponse`(7필드), `AdminShipmentRestController`, `AdminShipViewController`, `Order`/`Shipment` 의도 메서드)과 대조해 발견한 **설계 정합/결함 5건**의 수정 이유와 기준을 기록한다. 5건 모두 **020에서 확정한 교훈을 021 task가 계승하지 못하고 옛 서술을 반복**한 데서 비롯한다.

---

## 결정 요약

| # | 항목 | 초기 task 서술 | 변경 결정 | 심각도 | 020 대응 |
|---|---|---|---|---|---|
| 정합1 | 동시 `deliver` stale read | 1단계 "shipment 조회 + 주문 row 잠금" → shipment를 **락 전 엔티티로 적재**하는 옛 서술 | `findOrderIdById`(스칼라 projection, 020 추가) → 주문 락 → **락 후** `findById(shipment)` fresh 적재. `deliver`는 `ship`과 동일 구조 | **BLOCKER**(실버그) | 020 정합1 |
| 정합2 | deliver 컨트롤러 위치 | REST=`AdminOrderFulfillmentRestController`, View=`AdminOrderViewController` 확장으로 지정 | REST=**`AdminShipmentRestController`**, View=**`AdminShipViewController`**(020 신설) 확장으로 정정 | **BLOCKER**(잘못된 경로/매핑) | 020 C2·C3 |
| 정합3 | `ShipmentResponse.deliveredAt` 누락 | 응답·소비자 상세가 `deliveredAt`을 요구하나 Files에 DTO 수정 누락 | `ShipmentResponse`에 `deliveredAt`(nullable) 추가 + **생성 지점 전수 갱신** 명시 | **BLOCKER**(컴파일 파급) | 020 정합2 |
| 정합4 | `markDelivered` 멱등 책임 | 도메인 메서드가 "이미 delivered이면 멱등"(메서드 멱등) | 도메인은 `shipping→delivered`만(그 외 예외), **멱등은 서비스 소유** | MAJOR | 020 정합3 |
| 정합5 | 주문 종착 플래그 위치 | 공유 DTO `ShipmentResponse`에 플래그 시사 | **deliver 전용 `DeliverResponse(ShipmentResponse, boolean orderDelivered)`** 로 분리(공유 DTO 오염 금지) | MAJOR | 신규 |

> 검증 사실(코드 대조): `OrderFulfillmentService.ship`(line 296~)이 `findOrderIdById`→`findByIdForUpdate`→락 후 `findById` 순서로 정합1을 이미 구현. `ShipmentRepository`에 `findOrderIdById`·`findAssignedOrderItemIds`·`findByOrderId` 존재(rollup 재사용 가능, 신규 쿼리 불요). `ShipmentResponse`=`{shipmentId, orderId, status, carrier, trackingNumber, shippedAt, items}`(deliveredAt 없음). `AdminShipmentRestController`(`/api/v1/admin/shipments/{id}/ship`)·`AdminShipViewController`(`/admin/shipments/{id}/ship`, 클래스 매핑 없음)가 020에서 신설됨. `Order.markShipping`/`markPaid`는 단일 전이만(그 외 `IllegalStateException`), 멱등은 서비스 소유. `SecurityConfig` catch-all이 배송 경로 커버(020 확인) → 신규 보안 규칙 불요.

---

## 1. 정합1 — 동시 `deliver` stale read 차단 (BLOCKER, 020 계승)

- 결함: 초기 021의 이행 1단계 "shipment 조회 + 주문 row 잠금"은 **020이 stale-read 버그로 폐기한 바로 그 서술**이다. `deliver`는 `ship`과 구조가 동일하다 — 엔드포인트가 `/shipments/{id}/deliver`라 orderId를 모르므로 shipment를 먼저 읽어야 락을 걸 수 있고, 락 대상(order)과 판정 대상(shipment)이 다른 엔티티다.
- 영향: shipment를 락 전에 **엔티티로** 적재하면, 멀티 배송 동시 `deliver` 시 두 번째 트랜잭션이 직렬화되더라도 **JPA 1차 캐시의 stale `shipping`** 을 보고 멱등/rollup 판정을 그르친다(예: 이미 delivered인데 다시 전이 시도, 또는 rollup 중복 트리거).
- 결정(020과 동일 — option2):
  1. **orderId는 스칼라 projection으로만**(`ShipmentRepository.findOrderIdById` — 020에서 추가됨, 재사용. `findById(...).getOrderId()` 금지).
  2. 그 orderId로 주문 row `PESSIMISTIC_WRITE` 잠금.
  3. **락 후** `shipmentRepository.findById(shipmentId)`로 shipment 엔티티 최초 적재(항상 fresh).
- 적용: 021 Requirements 이행 1단계, Acceptance 동시성, Test(단위 락 순서).

## 2. 정합2 — deliver 컨트롤러를 020 신설 컨트롤러로 정정 (BLOCKER, 020 C2·C3 계승)

- 결함: 초기 021은 deliver 핸들러를 잘못된 클래스에 지정했다.
  - REST: `AdminOrderFulfillmentRestController`(=`/api/v1/admin/orders/{orderId}/shipments`)에 `/api/v1/admin/shipments/{id}/deliver` 추가 → base path 불일치.
  - View: `AdminOrderViewController`(=`@RequestMapping("/admin/orders")`)에 `/admin/shipments/{id}/deliver` 추가 → Spring MVC가 클래스+메서드 매핑을 **항상 결합**해 `/admin/orders/admin/shipments/...`가 됨(020 C3에서 확인).
- 결정: 020이 신설한 컨트롤러를 확장한다.
  - REST: **`AdminShipmentRestController`**(`/api/v1/admin/shipments/{id}/...`)에 deliver 추가.
  - View: **`AdminShipViewController`**(클래스 매핑 없음)에 deliver 핸들러 추가. View는 `AdminOrderFulfillmentFacade.deliver`(신규) 경유(web→order.spi 단방향).
- 적용: 021 Requirements REST/View Controller, Files.

## 3. 정합3 — `ShipmentResponse.deliveredAt` 추가 (BLOCKER, 020 정합2 계승)

- 검증: 현재 `ShipmentResponse`는 020에서 carrier/trackingNumber/shippedAt까지 추가됐고 **`deliveredAt`은 없다**. 021 API Response·소비자 상세(`delivered` 배송 배송완료시각)가 이를 요구한다.
- 결함: 초기 021 Files에 `ShipmentResponse` 수정이 누락(020 정합2와 동일). 레코드 필드 추가는 생성 지점(`buildShipmentResponse`·`createShipment`·`toShipmentResponseWithDetails`·`AdminOrderFulfillmentFacadeImpl`)을 전부 컴파일 깨뜨린다.
- 결정: `ShipmentResponse`에 `deliveredAt`(nullable `Instant`) 추가 + **모든 생성 지점 시그니처 갱신**(`delivered`가 아니면 null).
- 적용: 021 Requirements(신규 DTO 확장 bullet), Files.

## 4. 정합4 — `markDelivered` 멱등 책임 단일화 (MAJOR, 020 정합3 계승)

- 모순: 초기 021은 `Shipment.markDelivered`가 "이미 `delivered`이면 멱등"이라 적어 **도메인 메서드 멱등**을 시사했다. 그러나 020 정합3은 "도메인은 단일 전이만(그 외 throw), 멱등은 서비스 소유"로 확정했고 실제 `Shipment.markShipping`·`Order.markShipping`이 그렇게 구현돼 있다.
- 결정:
  - **`Shipment.markDelivered`는 `shipping→delivered`만 허용**, 그 외(이미 `delivered`/`preparing`/역방향)는 도메인 예외(메서드 멱등 아님).
  - **멱등은 서비스 소유**: 서비스는 shipment가 `shipping`일 때만 `markDelivered`를 호출하고, 이미 `delivered`이면 호출 전에 현재 응답을 `200`으로 멱등 반환.
  - `Order.markDelivered`도 `shipping→delivered`만(그 외 예외). 서비스가 rollup 조건 충족 시에만 호출.
- 적용: 021 Requirements 도메인·오케스트레이션, Test.

## 5. 정합5 — 주문 종착 여부는 deliver 전용 래퍼로 분리 (MAJOR, 신규)

- 모순: 초기 021은 "주문이 `delivered`로 전이됐는지를 성공 응답의 스칼라 플래그로 표현"이라 적어 **공유 DTO `ShipmentResponse`에 `orderDelivered` 추가**를 시사했다. 그러나 `ShipmentResponse`는 ship 응답·소비자 `OrderResponse.shipments`·admin facade가 공용하는 DTO다 — **배송 단위 DTO에 주문 단위 일시 플래그**를 넣으면 소비자 배송 목록 각 항목에 `orderDelivered`가 붙어 `order.status`와 중복되고 의미가 어색하다(관심사 오염).
- 결정:
  - `ShipmentResponse`는 `deliveredAt`(배송 속성, 정합3)만 추가.
  - 주문 종착 여부는 **deliver 엔드포인트 전용 래퍼 `DeliverResponse(ShipmentResponse shipment, boolean orderDelivered)`** 로 표현한다.
  - `orderDelivered`는 **전이 발생 여부가 아니라 현재 주문 status가 `delivered`인지**로 계산(멱등 재완료도 일관). Outcome enum이 아닌 성공 응답의 스칼라.
- 적용: 021 Requirements(거부/멱등 단락), API Response Contract, Files(신규 `DeliverResponse`).

---

## 6. 추가 명확화 (차단 아님 — task에 반영)

- **rollup 판정은 기존 쿼리 재사용 — 신규 Repository/쿼리 금지(과설계 방지)**: "전 항목 배정 && 전 배송 delivered"는 `order.getItems()` + `ShipmentRepository.findAssignedOrderItemIds(orderId)` + `findByOrderId(orderId)`로 계산 가능. 초기 task의 "필요 시 OrderItemRepository 조회"·"신규 쿼리"는 불필요.
- **rollup 시 방금 delivered된 shipment 상태 포함**: "전 배송 delivered" 판정은 같은 트랜잭션의 `findByOrderId` 재조회가 managed `delivered`를 반영해야 정확(task에 명시).
- **방어 가드(020 계승)**: 주문 `cancelled`/`refunded` → 409 + 주문이 `shipping`이 아니면 409(배송이 `shipping`이면 주문도 `shipping`이어야 함). 018 상호작용 정합.
- **deliver는 이벤트·member.spi·product.spi 의존 없음**: 배송완료 이벤트는 범위 밖(카탈로그 미정의)이라 `ApplicationEventPublisher`/P2/연락처가 불필요. 020 `ship`보다 서비스 의존이 단순(`OrderRepository`·`ShipmentRepository`만).

## 7. 파급 정리

| 정합 | 후속 영향 |
|---|---|
| 정합1~5 | 021로 마무리. 배송 라이프사이클(019 생성→020 시작→021 완료) 종착. 추가 후속(구매확정·반품/교환·배송완료 알림 이벤트)은 별도 task, 이벤트는 카탈로그 문서 먼저. |

- **019/020 정합(보안 catch-all·락·도메인 의도 메서드·DTO 파급)** 은 코드 대조에서 확인됨 — 021은 그 패턴을 계승만 하면 된다.
- 본 revision 반영 후 021은 plan 분해(planner → plan-reviewer ⇄ plan-fixer → 사용자 확인 → implementor)로 진행한다.

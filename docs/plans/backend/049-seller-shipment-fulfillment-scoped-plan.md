# Plan 049. 판매자 배송 Phase 2 — 판매자 배송 생성·시작·완료 (소유권 스코핑)

> 대상 Task: `docs/tasks/backend/049-backend-shop-core-seller-shipment-fulfillment-scoped.md`
> 범위: 판매자가 `/seller/orders`에서 **자기 owner_id 항목만**으로 배송 생성→시작→완료. `Shipment.seller_id` 스탬프 + 소유권 검사. admin 경로·기존 전이/이벤트/롤업은 **재사용·불변**. 마이그레이션 없음(owner_id=V10, seller_id 컬럼 기존).
> 선행: **Task 048 완료(커밋됨)** — order_item.owner_id 스냅샷 + SellerOrderFacade + /seller/orders 읽기.
> 순서: backend-implementor(SellerFulfillmentFacade + 서비스 스코핑/스탬프 + REST) → reviewer → view-implementor(/seller/orders 배송 폼) → reviewer → Modulith verify+풀 게이트 → e2e-runner.

## 0. 확정 사실 (코드 검증됨)
- `OrderFulfillmentService`(order.service, public): `createShipment(long orderId, List<Long> orderItemIds)`·`ship(long shipmentId, String carrier, String trackingNumber)`·`deliver(long shipmentId)`·`getShipments(orderId)`. 주문 행 PESSIMISTIC_WRITE 락·상태검증·UNIQUE 경합·**멀티배송 롤업(ship 멱등 preparing→shipping, deliver-when-all)**·`ShippingStartedEvent` Outbox 발행 전부 구현됨.
- `createShipment`은 `Shipment.preparing(orderId)`로 생성 — **seller_id 미설정**(컬럼은 존재, "backlog 002 준비용 미사용" 주석). Phase 2가 활성화.
- `Shipment.seller_id`: nullable Long 컬럼 기존. setter 금지(정적 팩토리/의도 메서드).
- 소유권 스냅샷: `order_item.owner_id`(V10, Phase 1). 판매자=owner_id=userId.
- admin facade(`AdminOrderFulfillmentFacade`): createShipment/ship/deliver를 OrderFulfillmentService에 **직접 위임**(actor 없음 — 전체 권한).
- 권한: `/api/v1/seller/**`·`/seller/**` 모두 `hasRole("SELLER")` 기존.
- seam 선례(048): `SellerOrderFacade.listSellerOrders(String actorEmail,...)` — facade가 member.spi로 email→sellerId 내부 해석, web은 email만. **본 Task 동일 패턴.**

## 1. 백엔드 (backend-implementor)
### 1.1 판매자 배송 생성 — 소유권 스코핑 + seller_id 스탬프
- `OrderFulfillmentService`에 **판매자 전용 생성** 추가: `createShipmentForSeller(long orderId, List<Long> orderItemIds, long sellerId)`:
  - **공통 로직은 "대상 항목 List를 주입받는" private 메서드로 추출**(락·상태검증·UNIQUE·rollup). admin/seller 둘 다 이 private에 **이미 산출된 targetOrderItemIds**를 넘긴다. **`createShipment(orderId, null)` 내부 위임 금지**(null이면 owner 무관 전 미발송을 잡아 타 판매자 항목까지 한 배송에 묶이는 IDOR — `OrderFulfillmentService.java:116-121`).
  - seller 경로 차이:
    - 대상 항목을 **owner_id == sellerId 인 미발송 order_item으로 스스로 계산**해 전달. 요청 orderItemIds에 **타 판매자(또는 미존재) 항목이 섞이면 404**(존재 은닉 — 아래 §1.5 상태코드 정책). admin 경로는 기존 동작(전 미발송) 유지·불변.
    - orderItemIds 생략 시: **그 주문의 그 판매자 소유 미발송 항목 전부**(admin은 전체 미발송 — 차이 명확).
    - 생성 Shipment에 **seller_id = sellerId 스탬프**: `Shipment.preparing(orderId, sellerId)` 오버로드 또는 의도 메서드 추가(**setter 금지** — Shipment.java 규약).
  - 대상 0건 → 409(만들 배송 없음 — 상태 충돌, 소유권 위반과 구분).
### 1.2 판매자 시작/완료 — 소유권 검사 후 재사용 (★stale-read 금지)
- ship/deliver는 **소유권 검사 후 기존 `OrderFulfillmentService.ship`/`deliver`에 위임**(전이·이벤트·롤업 재사용, 재구현 금지).
- **★ BLOCKER 반영 — 락 전 Shipment 엔티티 선적재 절대 금지**: `findById(shipmentId)`로 엔티티를 먼저 적재하면 JPA L1 캐시에 stale 상태가 남아 동시 ship 시 `ShippingStartedEvent` **중복 발행**(`ShipmentRepository.java:25-32` 정합1, ship/deliver가 `findOrderIdById` 스칼라→락→fresh findById 순서로 의도적으로 방지). 따라서 소유권 검사는 **스칼라 projection으로만**:
  - `ShipmentRepository`에 `@Query("select s.sellerId from Shipment s where s.id=:id") Optional<Long> findSellerIdById(long id)` 추가.
  - facade가 위임 전 이 스칼라만 읽어 `sellerId` 비교. 미존재/불일치/`null`(admin 생성) → **404**(§1.5). 엔티티 선적재 없음.
  - 통과 시 `ship(shipmentId, carrier, trackingNumber)`/`deliver(shipmentId)` 위임(내부에서 락 후 fresh 적재 — 기존 stale-read 가드 보존).

### 1.5 소유권 위반 상태코드 정책 (확정: 404 존재 은닉)
- 코드베이스 컨벤션 = **404 존재 은닉**(`ProductAccessDeniedException`: "소유자 아닌 SELLER는 없는 것처럼 404") + Phase 1 읽기(`SellerOrderFacadeImpl`)는 타 판매자 항목을 **조용히 필터**(존재 비노출). 403은 "존재함+권한없음"을 노출해 타 판매자 shipmentId/order를 probe 가능 → 비일관.
- → **소유권 위반은 404로 통일**: 시작/완료의 미존재·타 판매자·null shipment → **`ShipmentNotFoundException`(404) 재사용**. 생성 시 타 판매자/미존재 orderItem 지정 → 404 계열(`ShipmentNotFoundException` 재사용 또는 동형 404 — error-response-rule). **409(`OrderFulfillmentConflictException`)는 소유권 위반에 사용 금지**(409는 "만들 배송 없음" 등 상태 충돌 전용).
- task 검증 "소유권 매트릭스"의 403 표기도 **404로 갱신**(task와 정합 — 본 plan이 SSOT 기준).
### 1.3 published facade (order.spi)
- `order.spi.SellerFulfillmentFacade`(named interface): `actorEmail` 받아 facade 내부 member.spi로 sellerId 해석(048 패턴):
  - `ShipmentResponse createShipment(String actorEmail, long orderId, List<Long> orderItemIds)`
  - `ShipmentResponse ship(String actorEmail, long shipmentId, String carrier, String trackingNumber)`
  - `DeliverResponse deliver(String actorEmail, long shipmentId)`
  - 구현체(order.service, package-private): email→sellerId 해석 → OrderFulfillmentService 스코핑 메서드 호출. **web→member.spi 신설 금지**(facade 내부 해석).
### 1.4 REST (/api/v1/seller/**, SELLER)
- `SellerOrderFulfillmentRestController`: `POST /api/v1/seller/orders/{orderId}/shipments`(생성, body optional orderItemIds). `SellerShipmentRestController`: `POST /api/v1/seller/shipments/{shipmentId}/ship`(carrier·trackingNumber 필수), `/deliver`. principal email → facade. (admin REST 미러, 스코핑은 facade.)

## 2. 화면 (view-implementor) — `/seller/orders`에 배송 폼 추가
- Phase 1 읽기 화면(`templates/seller/orders.html`)에 **배송 생성/시작/완료 폼** 추가(admin/orders.html 미러, 단 **자기 항목만**):
  - **배송 생성 폼**: order가 paid/preparing + 그 판매자 **미발송 owned 항목 ≥1**일 때 노출. `POST /seller/orders/{orderId}/shipments`.
  - **배송 시작 폼**(택배사·운송장): 그 판매자 소유 shipment가 preparing일 때. `POST /seller/shipments/{id}/ship`.
  - **배송 완료 버튼**: 그 판매자 소유 shipment가 shipping일 때. `POST /seller/shipments/{id}/deliver`.
  - CSRF 자동(_csrf 수동 금지). PRG+flash. 인라인 스크립트는 `<main>` 내부.
- **뷰 컨트롤러 POST 핸들러**(web/order, `SellerOrderViewController` 확장 또는 신규): `actor.email()`을 SellerFulfillmentFacade에 전달, BusinessException→flashError, 성공 flashSuccess + `redirect:/seller/orders`.
- **★ MAJOR 반영 — 048 읽기 DTO 확장(확정, "필요시"가 아님)**: 폼 노출엔 `shipmentId`(ship/deliver POST 대상)와 shipment 그루핑이 **반드시** 필요한데 현재 `SellerOrderView`엔 `shipmentId`가 없고 항목별 status 문자열만 있다(`SellerOrderFacadeImpl`가 `findShipmentStatusByOrderItemIdIn`에서 status만 조립, shipmentId 버림). 따라서:
  - `findShipmentStatusByOrderItemIdIn` 쿼리를 **shipmentId 포함**으로 확장(`orderItemId, shipmentId, status`).
  - `SellerOrderView`에 admin 미러 구조 추가 — **그 판매자 소유 shipment 목록**(`SellerShipmentView(shipmentId, status, 소속 orderItemId들)`) + **미발송 owned 항목 목록**(배송 생성 폼 노출용). (admin `AdminOrderFulfillmentView`의 `List<ShipmentResponse>` + unshippedItems 참조.)
  - **이 048 DTO/쿼리 변경은 `SellerOrderFacadeIntegrationTest`(048) 파급** → 회귀 갱신 필수(§5 검증에 포함).

## 3. Non-goals (Phase 3 = 050)
- admin↔seller 동시 조작 정합·레거시 seller_id 백필·판매자 알림·멀티셀러 롤업 회귀 — **Phase 3(050)**.
- 멀티배송 주문 상태 롤업 재구현 — 이미 구현, 재사용만.
- 배송 모델/이벤트 변경. 새 마이그레이션(seller_id·owner_id 기존).

## 4. 순서 / 게이트
1. backend-implementor: OrderFulfillmentService 스코핑 생성(+seller_id 스탬프)·ship/deliver 소유권 검사 → SellerFulfillmentFacade(+impl, email 해석) → seller REST → 타깃 테스트.
2. reviewer: 소유권 매트릭스·seller_id 스탬프·기존 전이/이벤트/롤업 재사용(재구현 없음)·admin 경로 불변.
3. view-implementor: /seller/orders 배송 폼 + POST 핸들러 → reviewer.
4. 메인: Modulith verify(web→order.spi/member.spi 단방향) + 풀 `./gradlew test`.
5. e2e-runner: SELLER 로그인 → /seller/orders → 자기 항목 배송 생성→시작(택배사·운송장)→완료. 타 판매자 항목/배송 조작 불가, 멀티셀러 부분 배송.

## 5. 테스트
- **소유권 매트릭스(핵심)**: 판매자A는 자기 owner_id 항목만 생성/시작/완료. **타 판매자/미존재 항목 지정→404, 타 판매자(또는 seller_id=null admin) shipment ship/deliver→404(존재 은닉, §1.5)**. 비SELLER→401/403(권한). ADMIN은 기존 전체 경로 유지(불변). (409는 "만들 배송 없음" 상태충돌 전용.)
- **seller_id 스탬프**: 판매자 생성 shipment.seller_id == sellerId. 미지정 생성 시 그 판매자 미발송 owned 항목만 묶임.
- **멀티셀러 주문**: A·B 섞인 주문에서 각자 자기 항목 배송 1건씩(seller_id 각자), 간섭 없음. A·B 모두 deliver해야 order delivered(기존 deliver-when-all 재사용 — 통합).
- **이벤트 재사용**: 판매자 ship → ShippingStartedEvent 발행(기존 경로).
- **브라우저 E2E**: 위 게이트 5. 048 E2E 회귀(읽기 화면 + 새 폼 공존).

## 6. 리뷰 관점
- **소유권/IDOR**: 생성=owned 항목만(타 항목 섞이면 404 존재은닉), 시작/완료=seller_id 일치 shipment만(불일치/null→404). web은 email만(facade 내부 해석, web→member.spi 없음). ADMIN 특례 없음(판매자 본인).
- **재사용**: ship/deliver/롤업/이벤트는 OrderFulfillmentService 그대로 위임(재구현·중복 금지). 공통 생성 로직 추출 시 admin 경로 동작 불변(seller_id=null 유지).
- **공존**: admin 생성 shipment(seller_id null)은 판매자 비조작. admin은 전체 가능(감독). 깊은 공존/백필은 050.
- **DTO/레이어**: SellerFulfillmentFacade published port, ServiceResponse 미사용(view 경로는 facade·flash). `<main>` 스크립트·예약 모델명·CSRF 자동.
- **facade 분리 trade-off**: 읽기 `SellerOrderFacade`(048, @Transactional readOnly) + 쓰기 `SellerFulfillmentFacade`(049, 쓰기 tx)로 **분리 채택**. admin은 `AdminOrderFulfillmentFacade` 하나로 읽기+쓰기 통합한 선례와 비대칭이나, **readOnly 트랜잭션 경계 분리·책임 단일화** 이점으로 분리가 합리적(SellerOrderViewController가 두 facade 주입).
- **상태코드 일관성(§1.5)**: 소유권 위반=404 존재은닉(product 패턴·048 조용한 필터와 정합), 409는 상태충돌 전용. task 매트릭스 403→404 갱신.
- **stale-read(§1.2)**: 소유권 검사가 엔티티 선적재 없이 스칼라 projection으로 — 동시 ship 이벤트 중복 발행 가드 보존.

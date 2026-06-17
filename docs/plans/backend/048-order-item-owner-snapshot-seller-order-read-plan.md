# Plan 048. 판매자 배송 Phase 1 — order_item 판매자 스냅샷 + 판매자 주문 조회(읽기)

> 대상 Task: `docs/tasks/backend/048-backend-shop-core-order-item-owner-snapshot-seller-order-read.md`
> 범위: `order_items.owner_id` 스냅샷(V10 + 백필 + 주문생성 적재) + 판매자 `/seller/orders` **읽기 전용** 조회(소유권 스코핑). 기존 admin 배송·주문 생성 동작 불변. 배송 쓰기(생성/시작/완료)는 Phase 2(049).
> 순서: backend-implementor(V10 + 스냅샷 적재 + SellerOrderFacade + repo) → reviewer → view-implementor(/seller/orders 읽기 화면) → reviewer → 스키마매핑 선행 + Modulith verify + 풀 게이트 → e2e-runner.

## 0. 확정 사실 (코드 검증됨)
- 최신 마이그레이션 **V9** → 신규 **V10**.
- `products.owner_id`(V3, users.id 스칼라) 존재. `OrderItem`은 owner 없음(variantId·productName·optionLabel·unitPrice·quantity·lineAmount 스냅샷, `create(variantId, productName, ...)`).
- `ProductOrderCatalog.OrderableVariantSnapshot`(record) 필드: variantId·productId·productName·optionLabel·optionValues·price·active·stock·productStatus·purchasable — **ownerId 없음**(추가 필요). 구현체 `product/service/ProductOrderCatalogImpl`.
- `OrderService.createOrderTx`가 락-후 authorizedSnapshot으로 `OrderItem.create(...)` 호출.
- order.spi 기존: AdminOrderFulfillmentFacade, AdminOrderStatsFacade, SellerSalesStatsPort 등. **판매자 주문 목록 facade 없음**(신설).
- 판매자 스코핑 선례: `product.spi.SellerProductFacade`(actorEmail→ownerId, 본인만, ADMIN 특례 없음), `order.spi.SellerSalesStatsPort`(order는 소유권 모름 — web이 variantId 넘김).

## 1. 소유권 해석 방식 — owner_id 스냅샷(A) 채택 근거 (리뷰 선제)
- 선례 `SellerSalesStatsPort`(B안)는 **web이 판매자 variantId 집합을 product에서 받아 order에 넘기고 order는 `variant_id IN (...)` 집계**. 이는 **stats(요청당 한정된 variant 집합)** 엔 적합.
- 그러나 **판매자 주문 목록(Phase 1)** 은 "판매자 소유 항목이 든 주문을 최신순 **서버 페이지네이션**"이 필요. B안은 판매자 카탈로그 전체 variantId(시간이 갈수록 무한 증가)를 IN으로 넘겨 페이지네이션해야 해 **비효율·비확장**.
- → **order_items에 owner_id 스칼라 스냅샷(A)**: `WHERE owner_id = :sellerId` 인덱스 페이지네이션이 깔끔·확장적. owner_id는 **스칼라 스냅샷**(기존 variantId 스칼라·products.owner_id 스칼라와 동형 — architecture-rule 모듈경계 위반 아님, Entity 교차참조 없음). order는 product/member Entity를 참조하지 않고 자기 컬럼만 필터.
- 즉 **listing=A(스냅샷), aggregation=B(SellerSalesStatsPort 유지)** 로 목적별 분리. SellerSalesStatsPort는 무변경.

## 2. V10 마이그레이션 + 스냅샷 적재 (backend-implementor)
### 2.1 V10
- `order_items.owner_id BIGINT NULL` 추가(+ 조회용 인덱스 `idx_order_items_owner_id` — 페이지네이션 대비).
- **백필**: `UPDATE order_items oi SET owner_id = p.owner_id FROM product_variants pv JOIN products p ON pv.product_id = p.id WHERE oi.variant_id = pv.id`(variant SET NULL된 행은 owner_id NULL 잔존 — 스냅샷 손실 허용·명시).
### 2.2 스냅샷 경로
- `OrderableVariantSnapshot`에 `Long ownerId` 필드 추가 + `ProductOrderCatalogImpl` 조회에 `products.owner_id` select 추가(기존 스냅샷 쿼리에 컬럼 1개).
- `OrderItem`에 `ownerId`(**`Long` — nullable 컬럼**: 주문 생성 경로에선 항상 채워지나 백필 variant-NULL 행 때문에 컬럼은 NULL 허용) + `create(...)`에 ownerId 파라미터 추가(위치: variantId 인접 권장). 유일 호출처 `OrderService.createOrderTx`(`OrderService.java:227`)가 `authorizedSnapshot.ownerId()`로 채움(락-후 권위 스냅샷 재사용 — 신규 조회 없음). **`OrderItem.create` 시그니처 변경은 테스트에 광범위 파급(확정)** — `OrderDetailFetchIntegrationTest`·`OrderPaymentReaderImplTest`·`OrderFulfillmentService(Ship/Deliver)Test`·`OrderCancellationImpl(Expiry)Test`·`OrderConfirmationImplTest` 등 **~9개 파일·~14 콜사이트 전수 갱신 필수**(컴파일 차단 방지). variant_id를 reflection으로 null 세팅하는 선례(`OrderCancellationImplTest:371`)가 있으니 ownerId nullable 테스트도 동일 패턴 참고.
### 2.3 스키마 매핑 정합
- V10 + 엔티티 매핑은 schema-mapping-validation-rule 준수 — **스키마 매핑 전용 테스트 단독 선행**(ddl-auto=validate가 불일치 시 entityManagerFactory 붕괴 → 무관 테스트 연쇄 실패 방지 [[smallint-column-jdbctypecode-validate]]). owner_id는 BIGINT↔Long 단순.

## 3. 판매자 주문 조회 facade + repo (read-only)
### 3.1 seam — 옵션 A 확정 (OrderFacade 선례, MAJOR1 반영)
- `order.spi.SellerOrderFacade`(신규, named interface): **`Page<SellerOrderView> listSellerOrders(String actorEmail, Pageable)`**. **email→sellerId(=userId=owner_id) 해석은 facade 구현체 내부에서 `member.spi.MemberDirectory`로 수행**(`OrderFacade.getMyOrders(email,...)` 선례와 동일 — order→member.spi 단방향). **web은 actor.email()만 넘긴다**(SellerProductStatsViewController 선례) — **web→member.spi 신설 금지**(MemberDirectory 허용 방향=cart/order/payment→member.spi, web 아님).
- (SellerSalesStatsPort의 "web이 ownership 해석" 패턴은 stats 전용으로 유지 — listing은 OrderFacade 패턴 채택. order 모듈 두 선례 중 listing엔 후자가 일관·안전.)
### 3.2 repo 쿼리
- `OrderRepository`: 신규 — `SELECT DISTINCT o FROM Order o JOIN o.items i WHERE i.ownerId = :sellerId ORDER BY o.createdAt DESC, o.id DESC`(페이지네이션). 항목 fetch N+1은 페이지 확정 후 별도 로드(또는 entity graph) — 구현체 결정.
### 3.3 배송 상태 read 모델 (MAJOR2 반영 — 단순 조인 아님)
- 도메인 구조: `Shipment`↔`OrderItem` 직접 연관 **없음**. 경로는 `order_items.id → shipment_items.order_item_id(UNIQUE) → shipments.status`(Shipment는 orderId·sellerId 스칼라만, ShipmentItem은 shipment ManyToOne + orderItemId 스칼라).
- **배치 조회로 N+1 회피**: 페이지의 **orderItemId 집합**으로 `shipment_items JOIN shipments`를 **IN 1회** 조회 → `Map<Long orderItemId, String shipmentStatus>` 구성(미존재 = "미생성"/null). DTO 조립 시 항목별로 매핑.
- 이 조회/조립은 **order.service(SellerOrderFacade 구현체) 소유**(컨트롤러·repo 노출 아님). 배송 상태 문자열은 **DB lowercase**(preparing/shipping/delivered — `Shipment.status`).
### 3.4 DTO
- **`SellerOrderView`**(order.spi.dto, record/scalar — Entity 미노출): 주문 요약(orderNumber·status·createdAt·finalAmount 등) + **그 판매자 소유 항목만**(productName·optionLabel·qty·unitPrice + **항목별 배송상태**). 타 판매자 항목 제외(소유권 노출 차단).
- 구현체 패턴은 `AdminOrderFulfillmentFacadeImpl`/`SellerSalesStatsService`(order.service) 류 재사용.

## 4. 판매자 화면 (view-implementor) — `/seller/orders` 읽기 전용
- 뷰 컨트롤러(web): `@GetMapping("/seller/orders")` — **principal email을 그대로 `SellerOrderFacade.listSellerOrders(actor.email(), pageable)`에 전달**(web은 email→id 해석 안 함 — `SellerProductStatsViewController` 선례, facade 내부가 member.spi로 해석). 결과를 모델에. `/seller/**`는 SELLER 권한(SecurityConfig). **web→member.spi 신설 없음.**
- 템플릿 `templates/seller/orders.html`: 주문 목록 + 자기 항목 + 항목별 배송 상태 표시. **이 단계는 읽기만**(배송 생성/시작/완료 버튼 없음 — Phase 2). 빈 목록 메시지. 인라인 스크립트 쓰면 `<main>` 내부([[inline-script-must-be-inside-main-layout-fragment]]).
- 모델 키 예약명 회피(application/session/param/request 금지). Entity 직접 전달 금지(DTO만).

## 5. 순서 / 게이트
1. backend-implementor: V10(+백필) → OrderableVariantSnapshot.ownerId + ProductOrderCatalogImpl → OrderItem.ownerId + create + OrderService 적재 → SellerOrderFacade + repo + DTO → 타깃 테스트. **스키마 매핑 테스트 단독 선행 실행.**
2. reviewer: 스냅샷 적재 정확·owner_id 스칼라(모듈경계)·SellerOrderFacade 소유권 스코핑(web 책임)·listing A vs stats B 분리 정당·기존 흐름 불변.
3. view-implementor: /seller/orders 읽기 화면(스코핑·읽기전용) → reviewer.
4. 메인: 스키마 매핑 → Modulith verify(web→order.spi/member.spi 단방향·사이클 없음) → 풀 `./gradlew test`. 핵심 서비스(OrderService) owner 추가가 풀 컨텍스트 영향 없는지([[full-context-test-repo-mock-shared-annotation]]).
5. e2e-runner: SELLER 로그인 → /seller/orders → 자기 상품 포함 주문만·자기 항목만·배송 상태 표시. 타 판매자 항목 비노출, 비SELLER 차단.

## 6. 테스트
- **마이그레이션/매핑**: V10 적용 후 매핑 테스트 통과. 백필 통합(Testcontainers): variant 존재 행 owner_id 채워짐, variant NULL 행 owner_id NULL.
- **스냅샷**: 신규 주문 order_item.owner_id == 상품 owner_id(통합). variant 삭제 케이스 스냅샷 보존.
- **SellerOrderFacade 스코핑**: 판매자A는 자기 owner_id 항목 든 주문만, 응답에 타 판매자 항목 미포함. 빈 결과·페이지네이션. 멀티셀러 주문에서 A 응답엔 A 항목만.
- **배선**: SellerOrderFacade named interface 노출, 신규 repo 의존이 풀 컨텍스트 깨지 않는지.
- E2E(필수): §5-5.

## 7. 리뷰 관점
- **owner_id 스칼라 스냅샷이 모듈경계 위반 아님**(Entity 미참조, 기존 variantId/products.owner_id 스칼라와 동형). listing은 A, aggregation(SellerSalesStatsPort)은 B로 목적 분리 정당.
- **소유권 책임 위치**: web이 actorEmail→sellerId 해석(IDOR 방지), order.spi는 주어진 sellerId로 자기 테이블만(SellerSalesStatsPort 원칙 일관). ADMIN 특례 없음(판매자 본인만).
- **읽기 전용 경계**: Phase 1은 배송 쓰기 없음(버튼·POST 없음). 기존 admin 배송·주문 생성 불변.
- **스냅샷 정합**: 주문 생성 시 owner_id 적재가 락-후 권위 스냅샷 재사용(신규 쿼리 없음). 백필 한계(variant NULL) 명시.
- **N+1**: 판매자 주문 목록의 항목·배송 상태 조인 전략 점검.
- DTO/Entity 분리, 예약 모델명 회피, `<main>` 스크립트 규칙.
- **ADMIN 접근(MINOR)**: `/seller/**`는 RoleHierarchy상 ADMIN>SELLER이라 ADMIN도 `/seller/orders` 진입 가능. facade는 ADMIN 특례 없이 본인 owner_id 기준 조회(ADMIN은 대개 0건 → 빈 화면). **의도된 동작 — admin 감독 화면 아님**(SellerProductFacade "ADMIN 특례 없음" 선례 동일). 코드 변경 불요, E2E 혼동 방지용 명시.

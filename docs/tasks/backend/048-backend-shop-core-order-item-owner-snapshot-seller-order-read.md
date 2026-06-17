# 048. 판매자 배송 Phase 1 — order_item 판매자 스냅샷 + 판매자 주문 조회(읽기)

> 출처: 사용자 논의 — "배송 상태 변경은 판매자가 해야 하는 것 아닌가". 현재 배송은 ADMIN 전용(Task 019~021). 멀티셀러 마켓(상품에 `owner_id` 존재)에서 판매자 배송을 단계적으로 도입하는 **1단계(데이터 토대 + 읽기 전용)**.
> 관련 후속: Phase 2 `049`(판매자 배송 쓰기), Phase 3 `050`(정합·하드닝). api-authorization-rule(최소 권한·소유권 검사) 준수.

## 배경 (코드 확인)
- `products.owner_id`(V3) — 판매자/소유자(users.id 스칼라). 상품→판매자 식별 가능.
- **`order_items`는 판매자 정보를 안 들고 있다** — variantId·productName·unitPrice 스냅샷만(`order/domain/OrderItem.java`). 주문 항목의 판매자를 알려면 variantId→product_variant→product.owner_id 조인이 필요(런타임 크로스모듈) — 비효율·결합↑.
- 판매자 컨트롤러는 상품·이미지·통계만 있고 **주문 조회/배송 화면이 없다**(`web/product/Seller*`). 판매자는 자기 상품이 팔린 주문을 볼 수 없다.
- 소유권 스코핑 선례: `product.spi.SellerProductFacade`(actorEmail→ownerId 해석 후 본인 것만, IDOR 방지, ADMIN 특례 없음) — 동일 패턴 차용.

## Target / Goal
주문 항목에 **판매자(owner) 스냅샷**을 영속화해 이후 단계의 판매자별 그루핑·스코핑을 단순화하고, 판매자가 **자기 상품이 포함된 주문·배송 현황을 읽기 전용으로 조회**할 수 있게 한다. **기존 admin 배송 흐름·주문 생성 동작은 불변**(비파괴, 점진 도입).

## 범위 (Scope)
### 1. order_item 판매자 스냅샷 (backend-implementor)
- **Flyway 마이그레이션 V10**: `order_items.owner_id BIGINT NULL` 컬럼 추가. (스칼라 — order→member/product Entity 직접 참조 금지, architecture-rule 모듈 경계.)
- **기존 행 백필**: 같은 마이그레이션(또는 후속 SQL)에서 `order_items.owner_id`를 `variant_id → product_variants → products.owner_id` 조인으로 채운다. variant가 SET NULL된 행은 owner_id NULL 잔존 허용(스냅샷 보존 원칙 — 사후 보정 불가 케이스 명시).
- **주문 생성 시 스냅샷 적재**: `OrderService.createOrderTx`가 OrderItem 생성 시 owner_id를 함께 저장. owner는 **이미 락 후 조회하는 권위 스냅샷 경로**에서 얻는다 — `ProductOrderCatalog.OrderableVariantSnapshot`에 **ownerId 필드 추가**(현재 미노출) 또는 동등 조회. (변경 최소: 기존 스냅샷 조회에 owner 한 칼럼 추가.)
  - `OrderItem.create(...)` 시그니처에 ownerId 추가(스냅샷 필드 일관).
- **JPA↔Flyway 정합**: 신규 컬럼은 schema-mapping-validation-rule 준수 — 매핑 전용 테스트 단독 선행 실행([[smallint-column-jdbctypecode-validate]] 류 ddl-auto=validate 연쇄 실패 방지).

### 2. 판매자 주문 조회 (읽기 전용)
- **published 포트 + 판매자 화면**: 판매자가 **자기 owner_id 항목이 포함된 주문 목록·상세(자기 항목만 + 그 배송 현황)** 를 본다. 소유권 스코핑은 `SellerProductFacade` 패턴(actorEmail→ownerId, 본인 것만, ADMIN 특례 없음).
- **뷰**: `/seller/orders`(목록) + 상세 — 자기 상품 라인 + 해당 배송 상태(준비/배송중/완료) 표시. **이 단계는 읽기만**(배송 생성/시작/완료 버튼은 Phase 2). 인라인 스크립트 쓰면 `<main>` 내부([[inline-script-must-be-inside-main-layout-fragment]]).
- web→order/product seam은 기존 published 포트(`*.spi`) 경유(plan에서 확정 — order.spi에 판매자 주문조회 facade 신설 또는 기존 확장).

## Non-goals (후속 Phase)
- **판매자 배송 생성/시작/완료** — Phase 2(`049`). 본 Phase는 읽기 전용.
- **판매자별 배송 그루핑·seller_id 스탬프** — Phase 2.
- admin 배송 흐름 변경 — 불변(감독용 유지).
- 다중 배송 주문 상태 롤업 — **이미 구현됨**(deliver-when-all, ship 멱등 — `OrderFulfillmentService`), 본 작업 무관.
- owner_id 런타임 포트 해석 방식 — 스냅샷 채택으로 비범위(결합·반복조회 회피).

## 검증
- **마이그레이션·매핑**: V10 적용 후 스키마 매핑 테스트 단독 통과(entityManagerFactory 정상). 백필 후 기존 order_items.owner_id가 변형 존재 행에 채워짐(통합, Testcontainers).
- **주문 생성 스냅샷**: 신규 주문의 order_item.owner_id == 해당 상품 owner_id(통합). variant 삭제 케이스 스냅샷 보존.
- **판매자 조회 스코핑**: 판매자A는 **자기 상품 포함 주문만**, 타 판매자 상품 라인 비노출(IDOR). 비SELLER 접근 차단. **브라우저 E2E**(목록·자기항목 가시성 — [[verify-admin-list-page-features-with-e2e]]).
- 메인: Modulith verify + 풀 스위트 그린. 핵심 서비스(OrderService)에 owner 조회 추가가 풀 컨텍스트에 영향 없는지([[full-context-test-repo-mock-shared-annotation]]).

## 참고
- 소유: `product/domain/Product.java`(owner_id), `product/spi/SellerProductFacade.java`(스코핑 패턴), `product/spi/ProductOrderCatalog.java`(스냅샷 — ownerId 추가 지점).
- 주문: `order/domain/OrderItem.java`(스냅샷 필드), `order/service/OrderService.java`(createOrderTx — OrderItem 생성), `order/repository`.
- 배송 현황(읽기 참조): `order/domain/{Shipment,ShipmentItem}.java`, `order/service/OrderFulfillmentService.java`(getShipments).
- 스키마: V1·V3 + 신규 V10. 규칙: schema-mapping-validation-rule, api-authorization-rule.

# 040. 판매자 상품 현황 페이지 (재고 + 판매량·매출)

> 출처: 사용자 요청 — 판매자 메뉴에서 자기 판매 상품의 재고·판매량 등 현황을 보는 페이지.
> 범위 확정(사용자 선택): **재고 + 판매수량·매출** / 판매 인정 = **결제완료 이상(취소·환불 제외)** / **별도 현황 페이지**.

## Target / Goal
판매자가 `/seller/products/stats`에서 **자기 소유 상품별로 ① 총재고 ② 누적 판매수량 ③ 매출**을 한눈에 본다. 기존 상품 목록(`/seller/products`)에서 "판매 현황" 링크로 진입. 소유권 검사로 타 판매자 데이터 노출 금지.

## 범위 (Scope)
### 표시 지표 (상품 1행)
- **상품명 / 상태(ProductStatus: DRAFT·ON_SALE·SOLD_OUT·HIDDEN)**
- **총재고**: 해당 상품 모든 variant `stock` 합계(`SUM(product_variants.stock)`).
- **판매수량**: 완료 주문의 `order_items.quantity` 합계.
- **매출**: 완료 주문의 `order_items.line_amount` 합계.
- 페이지네이션(기존 목록과 동일 패턴), 최신순 등 정렬은 plan에서.

### 판매 인정 기준 (확정)
- 주문 `status IN ('paid','preparing','shipping','delivered')` 합산. **`cancelled`·`refunded` 제외**.
- (참고: order status CHECK = pending|paid|preparing|shipping|delivered|cancelled|refunded.)

## 아키텍처 제약 / 방향 (Modulith — 설계 결정적)
- **product 모듈은 order 모듈을 직접 import 못 함**(역방향 금지). 현재 의존은 `order → product.spi` 단방향. product↔order 양방향은 사이클 위반.
- **권장 seam(플랜에서 확정)**:
  1. **order 모듈**: 소유권을 모른 채 `order_items`만 집계하는 SPI 제공 — 예 `SellerSalesStatsPort.aggregateByVariantIds(Collection<Long> variantIds)` → variantId별(또는 합산) `(salesQty, revenue)`, 위 status 필터 적용. order는 자기 테이블(orders/order_items)만 조회(크로스모듈 JOIN 없음, 소유권 무지).
  2. **product 모듈**: 판매자 소유 상품과 그 **variantId 집합**을 제공(기존 `SellerProductFacade`/owner_id 소유권 패턴 재사용) + 상품별 총재고 집계(`SUM(stock)`, product 모듈 내).
  3. **web 계층**(신규 `SellerProductStatsViewController` 또는 기존 seller 뷰 컨트롤러): product 결과(상품·variantIds·재고)와 order SPI 결과(variant별 판매)를 **productId 기준으로 병합**해 모델 구성. web은 두 모듈 SPI에 forward 의존만 하므로 사이클 없음.
- **대안**(plan에서 비교): order→product 단방향 유지하며 order가 판매자별 통계를 직접 계산(owner_id 필요 → product 데이터 접근 필요라 부적합), 또는 이벤트 소싱 read 모델(OrderCompletedEvent 구독해 product측 통계 테이블 유지 — 인프라 큼). 1안(variantId 기반 SPI)이 가장 경계 친화적·저비용.

## 알려진 한계 (문서화 필수)
- **삭제된 variant의 판매 누락**: `order_items.variant_id`는 variant 삭제 시 `ON DELETE SET NULL`. variantId가 NULL인 주문항목은 어느 상품에도 귀속 못 해 **판매수량·매출 집계에서 제외**된다. 화면/문서에 "삭제된 옵션의 과거 판매분은 제외" 주석. (스냅샷 product_name은 있으나 owner 귀속 불가.)
- 재고는 현재값(시점 스냅샷). 판매량·매출은 누적(기간 필터는 본 task 비범위 — 후속).

## Non-goals
- 기간 필터(from/to), 주문건수, 환불액 차감, 차트/그래프 — 본 task 비범위(후속 가능).
- 가격/주문/결제 로직 변경. 통계는 **읽기 전용 집계**만.
- order 도메인 모델 변경(SPI read 메서드 추가만).

## 검증
- 백엔드: order SPI 집계(상태 필터 정확 — cancelled/refunded 제외, paid 이상 포함), product 재고 합계, web 병합 정확성(상품별 매핑, variant 없는 상품=판매 0). 소유권(타 판매자 productId/variantId 차단 — IDOR). 타깃 테스트(order 집계 repository/SPI, product 재고, web 컨트롤러).
- **Modulith 구조 테스트**: product가 order를 직접 의존하지 않고 web만 양쪽 SPI를 조합하는지 `ApplicationModules` verify로 보장(사이클 없음).
- **브라우저 E2E**(목록/조건부 UI는 E2E 필수): 판매자 로그인 → 현황 페이지 → 자기 상품의 재고·판매수량·매출이 맞게 표기(시드한 완료 주문 기준), 취소·환불 주문은 매출에 불포함, 타 판매자 상품 비노출.

## 참고 (실사: 본 task 작성 시)
- 주문: `order/domain/Order.java`(status, itemsAmount/finalAmount), `order/domain/OrderItem.java`(variantId nullable, quantity, unitPrice, lineAmount), 스키마 `V1__init_schema.sql:242-291`. status CHECK V1:248.
- 재고: `product/domain/ProductVariant.java:56`(stock), `product/repository/ProductVariantRepository`.
- 기존 판매자 목록: `web/product/SellerProductViewController.java:82`(GET /seller/products), `product/spi/SellerProductFacade.java`(getMyProducts→SellerProductSummaryView), 소유권 actorEmail→ownerId 변환.
- 상태: `product/domain/ProductStatus.java`(DRAFT·ON_SALE·SOLD_OUT·HIDDEN).
- 모듈 경계: `order/package-info.java`, `product/package-info.java`(직접 의존 금지), `order/spi`·`product/spi`.
- 집계 쿼리 패턴 참고: `product/repository/ProductRepository.java:44-75`(GROUP BY/COALESCE).

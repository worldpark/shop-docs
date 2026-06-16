# Plan 040. 판매자 상품 현황 페이지 (재고 + 판매량·매출)

> 대상 Task: `docs/tasks/backend/040-backend-shop-core-seller-product-stats-page.md`
> 범위: 별도 페이지 `/seller/products/stats` — 상품별 총재고 + 판매수량 + 매출. 판매=결제완료 이상(취소·환불 제외).
> 구현 순서: order 집계 SPI(backend-implementor) → product 재고/variantId 조회(backend-implementor) → web 조합·컨트롤러(backend-implementor) → reviewer → view(view-implementor) → reviewer → Modulith 구조 테스트 + 풀 게이트 → e2e-runner.

## 0. 선행 확인 (코드로 확정된 사실 — plan-reviewer 검증 완료)
- **`Order.status`는 enum이 아니라 lowercase `String` 스칼라**(`Order.java:55-56`, `@Column String status`). 값: `pending|paid|preparing|shipping|delivered|cancelled|refunded`. (OrderStatus enum 없음.) → 집계 status 집합은 **lowercase 문자열**로 작성.
- **`OrderItem.order`는 `@ManyToOne @JoinColumn(name="order_id") Order order` 확정**(`OrderItem.java:43-45`) → JPQL `JOIN oi.order o` 유효. 필드: `variantId`(nullable Long), `quantity`(int), `lineAmount`(BigDecimal scale 2).
- `SellerProductFacade.getMyProducts(actorEmail, Pageable)` 시그니처·반환(`Page<SellerProductSummaryView>`)과 ownerId 변환 위치(IDOR 패턴).
- `web` 패키지가 `order.spi`에 forward 의존 가능한지(현재 `product.spi` 의존 중). Modulith 모듈 경계상 web=adapter/application 계층인지 `package-info`/`ModuleStructureTest`로 확인.
- ProductVariant↔Product 매핑, `ProductVariantRepository`에 productId IN 조회 메서드 유무.

## 1. order 모듈 — 판매 집계 SPI (소유권 무지, order_items만)
order는 **소유권을 모른 채** 주어진 variantId 집합의 완료 판매를 집계한다(크로스모듈 JOIN·owner 접근 없음).
- **SPI 인터페이스** `order/spi/SellerSalesStatsPort.java`:
  - `List<VariantSalesAggregate> aggregateByVariantIds(Collection<Long> variantIds)` — variantIds 비면 빈 리스트 즉시 반환.
- **DTO** `order/spi/dto/VariantSalesAggregate.java`(record): `long variantId, long salesQty, BigDecimal revenue`.
- **구현** `order/service/SellerSalesStatsService.java`(또는 적절한 service)에서 repository 위임. `@Transactional(readOnly=true)`.
- **Repository 쿼리** `order/repository/OrderItemRepository`(또는 신규)에 JPQL:
  ```
  SELECT new com.shop.shop.order.spi.dto.VariantSalesAggregate(
      oi.variantId, COALESCE(SUM(oi.quantity),0), COALESCE(SUM(oi.lineAmount),0))
  FROM OrderItem oi JOIN oi.order o
  WHERE oi.variantId IN :variantIds
    AND o.status IN :countedStatuses
  GROUP BY oi.variantId
  ```
  - `:countedStatuses` = **lowercase 문자열 집합** `{"paid","preparing","shipping","delivered"}`. `"cancelled"`·`"refunded"`·`"pending"` 제외. (`o.status`가 String이라 `IN :countedStatuses` 그대로 유효.)
  - `oi.variantId`가 NULL인 행(삭제된 variant)은 `IN :variantIds`에 안 걸려 자동 제외(task 한계대로).
  - `oi.order` 연관 확정(ManyToOne, order_id) — JPQL `JOIN oi.order o` 그대로 사용.
- **모듈 경계**: 이 SPI는 order의 published API(`order.spi`). order는 product/web을 import하지 않음(기존 단방향 유지). variantId는 단순 Long이라 product 타입 의존 없음.

## 2. product 모듈 — 소유 상품 variantId + 총재고
판매자 소유 상품의 variantId 집합과 상품별 재고 합계를 product 내부에서 제공(owner 소유권은 product가 책임 → order엔 소유 variantId만 전달돼 IDOR 차단).
- **재고 합계**: `ProductVariantRepository`에 JPQL —
  ```
  SELECT pv.product.id AS productId, COALESCE(SUM(pv.stock),0) AS totalStock
  FROM ProductVariant pv WHERE pv.product.id IN :productIds GROUP BY pv.product.id
  ```
  projection(`ProductStockSum(productId, totalStock)`)로 반환.
- **variantId 매핑**: 같은 productIds로 `findByProductIdIn` → variantId↔productId 매핑 확보(이미 있으면 재사용, 없으면 추가). 또는 위 재고 쿼리와 별도로 `SELECT pv.id, pv.product.id ...`.
- **소유 상품 페이지**: 기존 `SellerProductFacade.getMyProducts(actorEmail, Pageable)`(→ productId/name/status) 재사용. **새 facade 메서드 추가 옵션**: `SellerProductFacade.getMyProductStockMap(actorEmail, productIds)` 등으로 캡슐화(컨트롤러가 ownerId·repository 직접 만지지 않게). plan 권장: product.spi에 **소유 검증 포함** 헬퍼를 두어 web이 productId 집합만 받게.
- 결제·주문 무관. 재고는 현재값.

## 3. web 계층 — 조합 + 컨트롤러 (composition root)
web만 두 모듈 SPI를 forward 의존해 조합(사이클 없음).
- **컨트롤러** `web/product/SellerProductStatsViewController.java`:
  - `@GetMapping("/seller/products/stats")` (SELLER 인가는 SecurityConfig `/seller/**` 기존 정책).
  - 절차: ① `SellerProductFacade`로 소유 상품 페이지(productId/name/status) + variantId·총재고 맵 조회(소유 검증된 것만). ② 모든 variantId 모아 `SellerSalesStatsPort.aggregateByVariantIds(variantIds)` 호출. ③ variantId별 집계를 variantId→productId 매핑으로 **상품별 합산**. ④ 행 DTO 리스트 구성 후 model에 담아 `seller/product-stats` 렌더.
  - **조합 로직 위치**: 컨트롤러가 비대해지면 web 패키지 component `SellerProductStatsAssembler`로 추출(두 SPI 주입). product/order 모듈에 두지 말 것(경계).
- **뷰 모델 DTO** `web/product/dto/SellerProductStatsRow.java`(또는 web dto 위치 관례): `long productId, String name, String status, long totalStock, long salesQty, BigDecimal revenue`. **status는 String**(web 모듈은 도메인 enum `ProductStatus` 직접 참조 금지 — `web/package-info.java`. `getMyProducts`가 반환하는 `SellerProductSummaryView.status`(이미 String)를 그대로 전달).
- 페이지네이션: 기존 목록 패턴(Pageable, page 파라미터) 따름. 정렬은 소유 상품 기준(최신순) — 판매량 정렬은 후속.
- **소유권/IDOR**: variantId 집합은 항상 "소유 검증된 상품"에서만 파생 → order SPI에 타인 variantId가 안 감. 컨트롤러에서 productId를 외부 입력으로 받지 않음(전체 소유 목록).

## 4. 화면 (view-implementor) — `templates/seller/product-stats.html`
- 레이아웃 `layout/base :: layout(...)`, **인라인 script 쓰면 반드시 `<main>` 내부**([[inline-script-must-be-inside-main-layout-fragment]]). 본 화면은 정적 표라 script 불필요할 수 있음.
- 표 컬럼: 상품명 / 상태 / 총재고 / 판매수량 / 매출. 빈 목록 메시지. 페이지네이션 컨트롤(기존 목록 재사용).
- 매출/판매수량 헤더 또는 푸터에 **"삭제된 옵션의 과거 판매분은 제외됩니다."** 주석(task 한계).
- 기존 판매자 목록(`product-list` 등)에 **"판매 현황" 링크** 추가(네비/버튼). 기존 목록 화면 파일 확인 후 링크만 삽입.
- 금액 표기: BigDecimal 그대로(scale 2). 통화 포맷은 기존 화면 관례 따름.

## 5. 순서 / 검증 게이트
1. backend-implementor: §1(order SPI) + §2(product 재고/variantId) + §3(web 조합·컨트롤러·DTO) + 타깃 테스트 → reviewer.
2. view-implementor: §4(현황 템플릿 + 목록 링크) → reviewer.
3. 메인: **Modulith 구조 테스트**(product가 order 미의존, web만 양쪽 SPI 조합 — `ApplicationModules.of(...).verify()` 통과) + 풀 스위트 그린.
4. e2e-runner: 앱 기동(JWT secret + Hikari 풀 10) → 판매자 로그인 → 현황 페이지에서 시드한 완료 주문 기준 재고·판매수량·매출 검증, 취소·환불 주문 매출 불포함, 타 판매자 상품 비노출.

## 6. 테스트 (타깃)
- order: SPI/Repository 집계 — status 필터(paid/preparing/shipping/delivered 포함, cancelled/refunded/pending 제외), variantId NULL 제외, 빈 variantIds 빈 결과, 여러 variant 합산. Testcontainers 통합 또는 슬라이스.
- product: 재고 합계 쿼리(variant 없는 상품=0), variantId 매핑, 소유 검증(타인 productId 차단).
- web: 컨트롤러 조합(상품별 병합 정확, variant 없는 상품 판매 0), 인가(SELLER 200 / CONSUMER 403 / 비인증 리다이렉트), IDOR(타 판매자 상품 미포함).
- 풀 스위트 금지(타깃만), Testcontainers 동시 실행 금지.

## 7. 리뷰 관점
- **모듈 경계**: order가 product/web 미import, product가 order 미import, 조합은 web에만. variantId(Long) 외 타입 누설 없음. Modulith verify 통과.
- 집계 정확성: status 집합이 lowercase 문자열 `{"paid","preparing","shipping","delivered"}`와 일치(취소·환불·pending 제외), COALESCE로 NULL→0, GROUP BY 정확. lineAmount 합이 매출(할인 후 라인금액 의미 확인).
- IDOR: order SPI 입력 variantId가 항상 소유 검증된 상품에서 파생되는가. 컨트롤러가 외부 productId/variantId를 신뢰 입력으로 받지 않는가.
- 삭제 variant 누락 한계가 화면·문서에 명시됐는가.
- 읽기 전용(@Transactional readOnly), 주문·결제·가격 로직 무변경.
- 인라인 script(있으면) `<main>` 내부. 신규 CSS 최소.

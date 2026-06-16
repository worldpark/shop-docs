# Plan 043. 관리자 통계 대시보드 (유저 이용률·상품 판매율·환불율)

> 대상 Task: `docs/tasks/backend/043-backend-shop-core-admin-statistics-dashboard.md`
> 선행: Task 042(`users.last_login_at`) 완료 후. 지표 정의 확정(환불율=건수, 기간=최근 30일, 판매율 DRAFT/HIDDEN 제외, 환불율 분모=전체 주문).
> 순서: 3모듈 카운트 read(backend-implementor) → reviewer → web 조합·컨트롤러(backend-implementor) → reviewer → 화면(view-implementor) → reviewer → Modulith verify+풀 게이트 → e2e-runner.

## 0. 확정 사실 (코드 검증됨)
- member: `member.spi.AdminMemberFacade`(searchMembers/changeRole). `MemberRepository.countByRole(Role)` 선례. `MemberStatus`(ACTIVE/WITHDRAWN). `last_login_at`(Task 042, Instant).
- order: `order.spi`(AdminOrderFulfillmentFacade, SellerSalesStatsPort). `Order.status` lowercase String, `Order.createdAt`. `OrderItem.variantId`(nullable Long, ON DELETE SET NULL), `oi.order` ManyToOne.
- product: `ProductStatus`(DRAFT/ON_SALE/SOLD_OUT/HIDDEN). `ProductVariant.product` ManyToOne. Task 040 `OrderItemSalesRepository`(variantId 집계 선례).
- web 조합 선례: Task 040 `SellerProductStatsViewController`/`Assembler`가 order.spi+product.spi 조합(Modulith 사이클 없음). `web/package-info`에 order.spi·product.spi·member.spi 허용.
- **Clock 빈 의존 금지**(042 BLOCKER): 기간 임계시각은 `Instant.now()` 직접(절대시각, 30일 윈도우에 KST 변환 불필요).

## 지표 정의 (확정)
- **① 유저 이용률** = `최근30일 접속 활성회원 / 전체 활성회원`. num: `status=ACTIVE AND last_login_at >= (now−30d)`, den: `status=ACTIVE`. (역할 전체 — "전체적인 유저".)
- **② 상품 판매율** = `최근30일 판매된 게시 상품(distinct) / 전체 게시 상품`. den: `status NOT IN (DRAFT,HIDDEN)`. num: 최근30일(`o.createdAt>=now−30d`) 완료판매(status ∈ {paid,preparing,shipping,delivered}) variantId→**게시 상품** distinct. 삭제 variant(NULL) 제외.
- **③ 환불율** = `최근30일 refunded 주문수 / 최근30일 전체 주문수`(분모 pending·cancelled 포함). 기간 `o.createdAt>=now−30d`.

## 1. 백엔드 — 3모듈 카운트 read (backend-implementor)
### 1.1 member (이용률)
- `MemberRepository`: `long countByStatus(MemberStatus status)`, `long countByStatusAndLastLoginAtAfter(MemberStatus status, Instant threshold)`(파생 쿼리).
- `member.spi.AdminMemberFacade`에 추가(또는 신규 `AdminMemberStatsFacade` — plan 권장: AdminMemberFacade 확장, admin 회원 read로 응집): `long countActiveMembers()`, `long countActiveMembersLoggedInSince(Instant threshold)`. 구현체에서 위 repo 위임.

### 1.2 order (환불율 + 판매율용 variantId)
- `OrderRepository`(기존): `long countByCreatedAtAfter(Instant threshold)`(전체 주문, 상태 무관), `long countByStatusAndCreatedAtAfter(String status, Instant threshold)`(refunded용) — 파생 쿼리 추가.
- 판매 variantId distinct: **기존 `OrderItemSalesRepository`에 메서드 추가**(신규 repo 금지 — 신규 repo는 `@MockSharedRepositories` 미등록으로 풀 컨텍스트 붕괴. `OrderItemSalesRepository`는 040에서 이미 `@MockSharedRepositories.types`에 포함). JPQL: `SELECT DISTINCT oi.variantId FROM OrderItem oi JOIN oi.order o WHERE o.createdAt >= :threshold AND o.status IN :statuses AND oi.variantId IS NOT NULL`(040 `aggregateSalesByVariantIds`와 동형).
- `order.spi.AdminOrderStatsFacade`(신규 interface): `long countOrdersSince(Instant threshold)`, `long countRefundedSince(Instant threshold)`, `List<Long> distinctSoldVariantIdsSince(Instant threshold)`. 구현체 `@Transactional(readOnly=true)`, **완료상태 집합은 자체 `private static final Set.of("paid","preparing","shipping","delivered")` 상수로 정의**(040 `SellerSalesStatsService.COUNTED_STATUSES`는 private이라 문자 그대로 재사용 불가 — 값만 동일). order는 product/web 미import(variantId=Long). **신규 repository 빈 없음 → @MockSharedRepositories 갱신 불요.**

### 1.3 product (판매율 분자·분모)
- `ProductRepository`(기존): `long countByStatusIn(Collection<ProductStatus> statuses)`(게시={ON_SALE,SOLD_OUT}) **또는** `countByStatusNotIn({DRAFT,HIDDEN})` — 파생 쿼리 추가.
- 판매 게시상품 distinct: **기존 `ProductVariantRepository`에 메서드 추가**(신규 repo 금지) — JPQL `SELECT COUNT(DISTINCT pv.product.id) FROM ProductVariant pv WHERE pv.id IN :variantIds AND pv.product.status IN :publishedStatuses`. **variantIds 비면 쿼리 미실행하고 0 반환**(빈 컬렉션 가드 — facade impl에서).
- `product.spi.AdminProductStatsFacade`(신규): `long countPublishedProducts()`, `long countPublishedProductsWithSales(Collection<Long> soldVariantIds)`. 구현체 readOnly, 위 두 기존 repo 위임. (소유권 무관 — 전체 통계, admin 전용.) **신규 repository 빈 없음(기존 ProductRepository/ProductVariantRepository에 메서드만 추가) → @MockSharedRepositories 갱신 불요.**

### 1.4 백엔드 테스트(타깃)
- member: countByStatus(ACTIVE), countByStatusAndLastLoginAtAfter(경계 — 30일 직전/직후) — Testcontainers.
- order: countByCreatedAtAfter, refunded 카운트(상태 필터), distinctSoldVariantIds(완료상태만·NULL 제외·30일 윈도우).
- product: countPublished(DRAFT/HIDDEN 제외), countPublishedProductsWithSales(빈 set=0, 미게시 상품 제외, distinct).

## 2. web 조합 + 컨트롤러 (backend-implementor)
- `web/.../AdminDashboardAssembler`(@Component): member/order/product 3 facade 주입. `build()`:
  1. `Instant threshold = Instant.now().minus(30, ChronoUnit.DAYS)`(web에서 계산, Clock 빈 미사용).
  2. 이용률: `countActiveMembersLoggedInSince(threshold)` / `countActiveMembers()`.
  3. 판매율: `soldVids = order.distinctSoldVariantIdsSince(threshold)`; `product.countPublishedProductsWithSales(soldVids)` / `product.countPublishedProducts()`.
  4. 환불율: `order.countRefundedSince(threshold)` / `order.countOrdersSince(threshold)`.
  5. 각 비율 = `den==0 ? null(또는 0) : num*100/den`(BigDecimal scale 1, HALF_UP). **분모 0 가드**.
- 뷰 DTO `web/.../dto/AdminDashboardView`(record): 지표 3개 각 `{ratioPercent(BigDecimal, nullable), numerator(long), denominator(long)}` + 기준기간 표기용(예 "최근 30일").
- `web/.../AdminDashboardViewController` `@GetMapping("/admin/dashboard")`: assembler.build() → 모델 `dashboard` → 뷰 `admin/dashboard`. SELLER/CONSUMER 차단은 SecurityConfig `/admin/**` ADMIN(컨트롤러 문자열 검사 금지).
- **모듈 경계**: web만 3 spi 조합(forward, 사이클 없음). order는 variantId(Long)만 노출. 비율 계산은 web(조합 지점). `web/package-info` 허용에 신규 facade가 속한 spi 패키지 포함 확인(이미 member.spi/order.spi/product.spi 허용).

## 3. 화면 (view-implementor) — `templates/admin/dashboard.html`
- 기존 admin 레이아웃(`layout/base :: layout`). 3개 카드/표: 각 지표명 + **비율 %**(null이면 "데이터 없음"/"N/A") + 원시 "num / den". 인라인 script 쓰면 `<main>` 내부(쓸 일 없을 것).
- **정의·한계 주석**(각 지표):
  - 이용률: "최근 30일 접속 회원 / 전체 활성 회원. **집계 시작(배포) 이후 접속분만 반영**되어 점진적으로 정확해집니다."
  - 판매율: "최근 30일 완료 판매 기준, **게시 상품(판매중·품절)만**. 삭제된 옵션의 과거 판매분은 제외."
  - 환불율: "최근 30일 **주문 건수 기준**(전체 주문 분모). **전체환불만 반영**(부분환불 미집계)."
- nav(`fragments/nav.html`)에 ADMIN "대시보드"(`/admin/dashboard`) 링크 + `NavActiveControllerAdvice`에 `/admin/dashboard`→`admin-dashboard` 분기 추가(다른 admin 메뉴와 일관, [[카테고리 때 동일 보강]]).

## 4. 순서 / 검증 게이트
1. backend-implementor §1(3모듈 read) → reviewer.
2. backend-implementor §2(web 조합·컨트롤러·DTO + 타깃 테스트) → reviewer.
3. view-implementor §3(대시보드 화면 + nav) → reviewer.
4. 메인: **Modulith verify**(web→3 spi, 사이클 없음) + 풀 스위트 그린.
5. e2e-runner: ADMIN 로그인 → /admin/dashboard → 시드(활성회원+30일내 로그인 / 완료주문·환불주문·게시·DRAFT 상품)로 3비율이 기대값과 일치, 비ADMIN 차단.
   - **시드 주의**: 이용률은 `last_login_at` 필요 — E2E에서 직접 JDBC로 `users.last_login_at` 세팅하거나 실제 로그인으로 채움. 30일 경계는 now 기준 상대 시드.

## 5. 리뷰 관점
- 각 카운트 쿼리 정확(상태·기간·게시상품 필터, 30일 경계, distinct, variantId NULL/빈 set 가드). 분모 0 가드(NPE/division by zero 없음).
- **모듈 경계**: order가 product/web 미import(variantId Long), product가 order 미import, 조합·비율은 web에만. Modulith verify 통과. 신규 facade가 각 모듈 spi named interface로 노출.
- 지표 정의 정합: 이용률(ACTIVE·30일 last_login), 판매율(완료상태·게시상품·삭제variant 제외), 환불율(건수·전체주문 분모·refunded). 화면 한계 주석이 사실과 일치.
- Clock 빈 미사용(Instant.now()), 읽기 전용(@Transactional readOnly), 주문·결제·가격·회원 변경 로직 무변경.
- admin 인가 SecurityConfig 의존, 컨트롤러 문자열 권한검사 없음. nav active 분기 보강.

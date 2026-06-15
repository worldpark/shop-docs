# 판매자 본인 상품 목록 페이지 신설 — 구현 Plan

> 경로: docs/plans/backend/seller-product-list-page-plan.md
> 대상: shop-core. GET /seller/products (View, SSR). 수정/등록/이미지/옵션 화면은 이미 존재 — 신설 금지. 목록만.

## 구현 목표
판매자가 자기(ownerId) 상품만 페이지네이션으로 보는 목록 화면(GET /seller/products)을 신설하고, 각 행에서 기존 수정/이미지/옵션 화면으로 링크한다. IDOR 방지를 위해 목록은 항상 본인 ownerId로 필터한다(타 판매자 상품 비노출).

---

## 1. 설계 방식 · 이유

### 1.1 레이어 / 진입 경로 (architecture-rule View 규칙 준수)
~~~
SellerProductViewController(@Controller, web 모듈)
  -> SellerProductFacade(product.spi published port)        # web은 이 인터페이스만 의존
    -> SellerProductFacadeImpl(product.service, 비공개 구현)
      -> ProductService(소유 한정 목록 조회, 트랜잭션·소유권 단일 소유)
        -> ProductRepository.findByOwnerId...(ownerId, pageable)  # 신규 owner 기준 쿼리
  -> Thymeleaf: seller/product-list.html
~~~
- 결정 A — 기존 SellerProductFacade를 확장한다(신규 facade 신설 안 함). 이유: 같은 web 컨트롤러(SellerProductViewController)가 이미 이 facade를 경유하며 등록/수정/카테고리/상태목록을 모두 받고 있다. 목록 조회도 동일 판매자 상품 관리 View 책임에 속하므로 facade 1개로 응집. 신규 facade는 과도한 설계(제약: 과도한 설계 금지).
- 결정 — web->facade 규칙 준수. ViewController는 ProductService/Repository/Entity/ProductStatus enum을 직접 참조하지 않는다(기존 등록/수정과 동일). facade가 actorEmail->actorId(UserDirectory), Entity->DTO, enum->String 변환을 전담한다.
- principal 해석: 기존과 동일하게 CurrentActorResolver.resolve(auth) -> CurrentActor.email()을 facade에 전달. facade 내부에서 UserDirectory.findUserIdByEmail(email)로 ownerId 확정. (web은 userId를 알지 못함 — 기존 흐름 유지.)

### 1.2 소유 한정(IDOR) 설계 — 핵심
- 목록은 권한(ROLE_SELLER)만으로 불충분하고 소유권 필터가 필수다(api-authorization-rule 소유권 검사 기준). 타 판매자 상품 비노출은 쿼리 자체가 ownerId = actorId로 필터하여 구조적으로 보장한다(상태 무관 — DRAFT/HIDDEN 포함 본인 전부).
- 결정 — ADMIN 분기 없음(목록은 항상 본인 ownerId). 수정/단건(getForEdit)은 actorIsAdmin로 소유권 검사를 스킵하지만, 목록은 내 상품 목록 화면이므로 ADMIN이라도 자기 ownerId 것만 보여준다(전체 상품 관리 화면은 본 task 범위 밖). 따라서 facade 목록 메서드는 actorIsAdmin을 받지 않는다 — 과도설계 회피 + IDOR 단순화.
- 행의 수정/이미지/옵션 링크 진입 자체도 기존 컨트롤러들이 getOwnedProduct(소유권 검사, 타인 -> 404)로 막고 있으므로, 목록에서 링크를 걸어도 IDOR이 열리지 않는다(이중 방어).

### 1.3 표시 필드 / 가격 노출 (결정 C)
- 가격은 basePrice를 그대로 노출한다. 이유: 판매자 본인 화면이므로 등록가(basePrice) 노출이 자연스럽고, 수정 화면(ProductFormView.basePrice)과 일관. 공개 목록의 displayPrice(= COALESCE(MIN 활성 variant price, basePrice)) 집계는 쓰지 않는다. PublicProductSummaryResponse(공개·집계·구매가능 variant 노출용)와 명확히 구분되는 별도 DTO를 둔다.
- 표시 필드: 상품명, 상태(배지), basePrice, 등록일(createdAt). variant/이미지 집계는 목록 범위 밖(과도설계 회피) — variant 개수 등은 표시하지 않는다.
- status는 String으로 노출한다(web이 ProductStatus enum 비참조 — 기존 productStatusNames()와 동일 원칙). 템플릿이 String 값(DRAFT/ON_SALE/SOLD_OUT/HIDDEN)으로 배지 라벨을 매핑한다.

### 1.4 정렬 / 페이지네이션
- 최신순 고정(createdAt DESC, id DESC) — OrderService.getMyOrders 선례와 동일 톤. 정렬 옵션 UI는 범위 밖.
- 컨트롤러는 @PageableDefault(size = 10, sort = createdAt, direction = DESC) 사용(OrderViewController 선례와 동일). 단 Pageable의 sort를 그대로 신뢰하지 않고 리포지토리 메서드가 정렬을 쿼리에 고정한다(아래 1.5). 페이지 크기/번호만 Pageable에서 취한다.

### 1.5 리포지토리 쿼리 (결정)
- Spring Data 파생 쿼리 사용: Page<Product> findByOwnerIdOrderByCreatedAtDescIdDesc(Long ownerId, Pageable pageable).
  - 공개 목록(findPublicProducts*)은 variant 집계(GROUP BY + COALESCE)가 필요해 @Query였지만, 판매자 목록은 집계가 없으므로 파생 쿼리로 충분(과도설계 회피). ORDER BY를 메서드명에 고정해 Pageable sort 주입에 의존하지 않는다.
  - createdAt은 BaseEntity 상속 필드 — 파생 쿼리에서 정렬 가능.
  - 반환은 Page<Product>(Entity Page). 단 Entity는 facade 경계를 넘지 않는다 — facade가 Page.map(...)으로 즉시 DTO로 변환(아래 2.4). Repository->Service->facade까지는 같은 product 모듈 내부이므로 Entity 전달 허용(architecture-rule: Entity를 모듈 밖으로 노출 금지 — 여기선 facade 반환에서 변환).

---

## 2. 구성요소

### 영향 범위
- 신규 파일
  - product/dto/SellerProductSummaryView.java — 판매자 목록 행 View DTO (record)
  - templates/seller/product-list.html — 목록 화면
  - 단위 테스트: SellerProductFacadeImplTest에 목록 케이스 추가(기존 파일), ProductServiceTest에 소유 한정 목록 케이스 추가(기존 파일)
  - 통합 테스트: ProductRepository 슬라이스 테스트(@DataJpaTest + Testcontainers) — 신규 또는 기존 product 리포 슬라이스에 추가
  - (선택) SellerProductViewControllerTest 목록 핸들러 MockMvc 슬라이스 + Security 테스트
- 수정 파일
  - product/spi/SellerProductFacade.java — getMyProducts(...) 메서드 추가
  - product/service/SellerProductFacadeImpl.java — 구현 추가
  - product/service/ProductService.java — getMyProducts(long ownerId, Pageable) 추가
  - product/repository/ProductRepository.java — findByOwnerIdOrderByCreatedAtDescIdDesc 추가
  - web/product/SellerProductViewController.java — GET /seller/products 핸들러 추가
  - web/support/NavActiveControllerAdvice.java — active 키 목록/등록 구분
  - templates/fragments/nav.html — SELLER 내 상품 링크 추가
- DB/이벤트/notification: 변경 없음(products.owner_id 기존 사용, ddl-auto=validate 무영향 — 신규 컬럼 없음).

### 2.1 web/product/SellerProductViewController (수정)
- 역할: GET /seller/products 핸들러 추가. 기존 클래스에 메서드만 추가(@RequestMapping(/seller/products) 하에 @GetMapping 루트 매핑).
- 메서드 시그니처:
~~~
@GetMapping
String list(Authentication auth,
            @PageableDefault(size = 10, sort = createdAt, direction = DESC) Pageable pageable,
            Model model)
~~~
- 로직:
  1. CurrentActor actor = currentActorResolver.resolve(auth)
  2. Page<SellerProductSummaryView> sellerProducts = sellerProductFacade.getMyProducts(actor.email(), pageable)
  3. model.addAttribute(sellerProducts, sellerProducts) — 모델 키 sellerProducts (Thymeleaf 예약어 회피: application/session/param/request 금지 — MEMORY 규칙 준수. products는 공개목록 nav active와 혼동되므로 도메인 접두사 seller.)
  4. return seller/product-list
- View name 상수 SELLER_PRODUCT_LIST_VIEW = seller/product-list 추가.
- GetMapping 우선순위 주의: @GetMapping(루트, /seller/products)과 기존 @GetMapping(/new)는 경로가 달라 충돌 없음. /{id}/edit 등과도 무충돌.

### 2.2 product/spi/SellerProductFacade (수정)
- 추가 메서드:
~~~
// 판매자 본인 상품 목록 (최신순 페이지네이션). actorEmail->ownerId 해석 후 본인 ownerId로만 조회.
Page<SellerProductSummaryView> getMyProducts(String actorEmail, Pageable pageable);
~~~
- 파라미터/반환 타입은 product 모듈 소유 타입(또는 Spring Data 공용 타입)만 사용(architecture-rule: 포트는 web 타입 비참조). Pageable/Page는 Spring 공용, SellerProductSummaryView는 product.dto 소유 -> 규칙 충족.
- Javadoc에 본인 ownerId 한정(IDOR 방지), ADMIN 특례 없음 명시.

### 2.3 product/service/ProductService (수정)
- 추가 메서드:
~~~
@Transactional(readOnly = true)
Page<Product> getMyProducts(long ownerId, Pageable pageable)
~~~
- 로직: productRepository.findByOwnerIdOrderByCreatedAtDescIdDesc(ownerId, pageable) 호출 후 그대로 반환(소유 필터는 쿼리가 보장 — 별도 소유권 예외 없음, 빈 결과는 정상).
- 순수 도메인 유지(member/UserDirectory 비의존) — ownerId(long)만 받는다(기존 register/update와 동일 원칙).

### 2.4 product/service/SellerProductFacadeImpl (수정)
- 추가 구현:
~~~
@Override
public Page<SellerProductSummaryView> getMyProducts(String actorEmail, Pageable pageable) {
    long ownerId = userDirectory.findUserIdByEmail(actorEmail);
    return productService.getMyProducts(ownerId, pageable)
            .map(SellerProductSummaryView::from);   // Entity Page -> DTO Page (모듈 경계에서 변환)
}
~~~
- Entity는 여기서 즉시 DTO로 변환 — facade 반환 타입은 DTO Page. web으로 Entity가 새지 않는다.

### 2.5 product/dto/SellerProductSummaryView (신규)
- record, from(Product) 정적 팩토리만으로 생성(Entity 직접 노출 금지 — ProductFormView 패턴 동일).
- 필드:
~~~
long productId
String name
String status            // ProductStatus.name() — web이 enum 비참조
BigDecimal basePrice     // 판매자 본인 등록가 (공개 displayPrice와 구분)
Instant createdAt        // 표현만 KST(템플릿에서 변환, ADR-009) — 저장/전달은 Instant
~~~
- from: product.getStatus().name(), product.getCreatedAt()(BaseEntity getter), product.getId(), product.getName(), product.getBasePrice().
- PublicProductSummaryResponse와의 구분 명시(Javadoc): 이 DTO는 소유자 전용·basePrice·전체 status(DRAFT/HIDDEN 포함) 노출. 공개 DTO는 집계 displayPrice·구매가능 variant·공개 status만 — 혼용 금지.

### 2.6 product/repository/ProductRepository (수정)
- 추가:
~~~
// 판매자 본인 상품 목록 — 최신순(createdAt DESC, id DESC). ownerId 필터로 IDOR 차단.
Page<Product> findByOwnerIdOrderByCreatedAtDescIdDesc(Long ownerId, Pageable pageable);
~~~
- 파생 쿼리(집계 불필요). 기존 @Query 3종과 별개.

### 2.7 web/support/NavActiveControllerAdvice (수정) — active 키 구분 (결정 B)
- 현재: uri.startsWith(/seller/products) -> seller-product-new (목록/등록 미구분).
- 결정 B — prefix 우선순위로 등록(/seller/products/new)과 목록(그 외 /seller/products*)을 구분한다.
~~~
if (uri.startsWith(/seller/products/new)) return seller-product-new;   // 등록(더 구체적, 먼저)
if (uri.startsWith(/seller/products))     return seller-products;      // 목록(+수정/이미지/옵션 등)
~~~
  - 등록 폼만 상품 등록 메뉴 활성, 목록/수정/이미지/옵션 화면은 내 상품 메뉴 활성. (수정/이미지/옵션은 목록의 하위 작업이므로 내 상품 활성이 자연스럽다.)
  - 순서 주의: 더 구체적인 /seller/products/new를 먼저 검사(startsWith는 prefix라 순서 의존).
- 신규 active 키 seller-products 도입, 기존 seller-product-new는 등록 전용으로 유지.

### 2.8 templates/fragments/nav.html (수정)
- 기존 상품 등록(/seller/products/new, seller-product-new) 링크 옆에 SELLER용 내 상품 링크 추가. 정확한 Thymeleaf 표기는 기존 nav.html의 다른 SELLER 항목(상품 등록)과 동일 패턴으로 view-implementor가 복제한다:
  - li 에 sec:authorize hasRole SELLER
  - a 의 th:href = @{/seller/products}
  - a 의 th:classappend = active == seller-products 비교로 nav-link-active 부여
  - 링크 텍스트: 내 상품
- 기존 상품 등록 링크는 유지(삭제·이동 금지).

### 2.9 templates/seller/product-list.html (신규) — view-implementor
- 레이아웃: layout/base :: layout(title, content) (order/list.html 동일).
- 모델 키: sellerProducts (Page<SellerProductSummaryView>).
- 주문 목록 톤 재사용: order-table / badge-order-status 클래스 톤 재사용 — 표 구조·페이지네이션 마크업을 order/list.html에서 차용(테이블 래퍼, 빈 상태, 페이지네이션 3블록). 상태 배지는 product status 라벨 매핑을 자체 적용(아래).
- 컬럼: 상품명 / 상태(배지) / 가격(basePrice, numbers.formatDecimal COMMA + 원) / 등록일(temporals.format(createdAt.atZone(Asia/Seoul), yyyy-MM-dd HH:mm), ADR-009) / 관리(수정·이미지·옵션 링크).
- 상태 배지 라벨 매핑(String): DRAFT->임시저장, ON_SALE->판매중, SOLD_OUT->품절, HIDDEN->숨김 (그 외 원문).
- 행 링크(상대경로 path variable, IDOR은 대상 컨트롤러가 재검증):
  - 수정: @{/seller/products/{id}/edit(id=${p.productId})} (이미 존재 — 링크만)
  - 이미지: @{/seller/products/{id}/images(id=${p.productId})}
  - 옵션/variant: @{/seller/products/{id}/variants(id=${p.productId})}
- 빈 상태(sellerProducts.content.isEmpty()): 등록한 상품이 없습니다. + @{/seller/products/new}(상품 등록) 버튼.
- 페이지네이션: sellerProducts.number/totalPages/totalElements/size, 링크 base @{/seller/products(page=..., size=...)}.
- Entity·ownerId·로컬 절대경로 미표시(order/list 보존 계약 동일).

---

## 3. 데이터 흐름
~~~
[GET /seller/products?page=&size=]
  Security: /seller/** -> hasRole SELLER  (미인증 302 /login, 비SELLER 403)  # 기존 SecurityConfig, 변경 없음
  -> SellerProductViewController.list(auth, pageable, model)
      actor = CurrentActorResolver.resolve(auth)             // email, admin
      -> SellerProductFacade.getMyProducts(actor.email(), pageable)
          ownerId = UserDirectory.findUserIdByEmail(email)   // email->userId
          -> ProductService.getMyProducts(ownerId, pageable)  // @Transactional(readOnly)
              -> ProductRepository.findByOwnerIdOrderByCreatedAtDescIdDesc(ownerId, pageable)  // ownerId 필터 = IDOR 차단
            <- Page<Product>
          <- .map(SellerProductSummaryView::from)             // Entity->DTO (모듈 경계 변환)
        <- Page<SellerProductSummaryView>
      model[sellerProducts] = page
  -> render seller/product-list.html
~~~

## 4. 예외 처리
- 소유 한정: 별도 예외 없이 쿼리 필터로 비노출(타인 상품은 결과 집합에 미포함). 목록은 존재하지만 권한 없음을 던질 대상이 없다(애초에 본인 것만 조회).
- 빈 목록: 정상 흐름. Page.empty(content 비어있음) -> 템플릿 빈 상태 렌더(예외 아님).
- 미인증/비권한: Security 필터가 처리(컨트롤러 도달 전). 미인증 302 /login, 비SELLER 403. 컨트롤러 분기 없음.
- 행 링크 진입(수정/이미지/옵션): 대상 컨트롤러가 getOwnedProduct 소유권 검사 -> 타인/미존재 ProductAccessDeniedException/ProductNotFoundException(404) -> ViewExceptionHandler error/error. 목록 컨트롤러 책임 아님.
- View 예외 포맷: REST JSON 포맷(error-response-rule) 미적용 — View는 에러 페이지(error-response-rule 적용 범위). 본 화면은 정상 경로만이라 추가 핸들러 불필요.
- UserDirectory.findUserIdByEmail 실패(이론상 세션 유효한데 user 없음) 시 던지는 기존 예외를 그대로 전파(기존 등록/수정과 동일 — 별도 처리 추가 안 함).

## 5. 검증 방법

### 5.1 단위 (JUnit5 + Mockito)
- ProductServiceTest (추가):
  - getMyProducts(ownerId, pageable) -> productRepository.findByOwnerIdOrderByCreatedAtDescIdDesc(ownerId, pageable) 호출·인자(ownerId·pageable) 전달, 반환 Page 그대로 전달 검증.
- SellerProductFacadeImplTest (추가):
  - getMyProducts(email, pageable): userDirectory.findUserIdByEmail(email) 호출 -> 그 ownerId로 productService.getMyProducts 호출(ArgumentCaptor로 ownerId 일치) 검증.
  - Page<Product> -> Page<SellerProductSummaryView> 매핑(name/status(name())/basePrice/createdAt/productId) 검증.
  - Entity 미노출 단언: 반환 Page content 원소 타입이 SellerProductSummaryView인지 단언.

### 5.2 DB 통합 (@DataJpaTest + Testcontainers PostgreSQL — testing-rule DB 통합)
- ProductRepository.findByOwnerIdOrderByCreatedAtDescIdDesc:
  - 두 판매자(owner A, owner B) 상품을 섞어 저장.
  - owner A로 조회 시 A 상품만 반환(타 판매자 B 상품 0건 포함 단언) — 핵심 IDOR 단언.
  - 정렬: createdAt DESC, 동일 createdAt 시 id DESC 보조정렬 확인.
  - DRAFT/HIDDEN 포함 모든 status가 반환(본인은 전체 노출) 확인.
  - 페이지네이션: size 경계(첫/마지막 페이지 totalElements·content 크기) 확인. PostgreSQL 고유 동작 회귀(파생 쿼리 파라미터 타입) 격리.

### 5.3 View / Security 슬라이스 (@WebMvcTest 또는 @SpringBootTest + MockMvc)
- SellerProductViewController.list:
  - facade를 @MockitoBean으로 stub(testing-rule 테스트 더블 — @MockBean 금지) -> 모델 키 sellerProducts 존재, view name seller/product-list 단언.
  - Security(api-authorization-rule 테스트 기준):
    - SELLER -> 200(접근 가능)
    - ADMIN -> 200(상위 권한 함의)
    - CONSUMER -> 403(하위 권한)
    - 미인증 -> 302 /login
  - facade 호출 시 전달 email이 인증 principal과 일치(소유 한정 인자 전달) 검증.

### 5.4 브라우저 E2E (Playwright for Java — testing-rule, MEMORY: 목록 페이지 조건부 가시성)
- MEMORY 규칙(verify-admin-list-page-features-with-e2e): 목록 페이지의 조건부 버튼/링크·행 렌더는 MockMvc·통합이 쿼리<->템플릿 가시성 공백을 놓치므로 실제 브라우저 E2E로 검증한다.
  - 판매자 로그인 -> /seller/products -> 본인 상품 행이 보이고 타 판매자 상품명이 DOM에 부재 단언(IDOR 가시성).
  - 수정/이미지/옵션 링크가 올바른 {id} 경로로 렌더되는지, 클릭 시 해당 화면 진입.
  - 빈 상태 메시지, 페이지네이션 표시.
  - nav 내 상품 링크가 SELLER에 보이고 active 표시(seller-products)가 목록에서만, /new에서는 상품 등록 활성인지.
  - 실행은 별도 e2eTest 태스크(check/test 미포함) — e2e-runner/CI 담당(testing-rule 검증 실행).

### 5.5 동적 게이트 (verification-gate-rule 2,4 — 메인 에이전트 책임)
- 구현/수정 단계 후 메인이 직접 ./gradlew test 전체 그린 확인(서브에이전트 보고 신뢰 금지).
- 컴포넌트 스캔 파급: 신규 @Repository 메서드는 신규 빈이 아님(기존 ProductRepository에 메서드 추가) -> 풀컨텍스트 @SpringBootTest 구성 변화 없음(신규 빈 무). 신규 @Service/@Component/@Bean 추가 없음(facade impl·service 기존 빈에 메서드만 추가, DTO는 빈 아님). 따라서 기존 풀컨텍스트 테스트의 @MockitoBean 추가 파급 불필요로 판단 — 단, 메인이 전체 그린으로 실증 확인.
- 스키마 매핑 변경 없음(신규 Entity/컬럼/마이그레이션 무) -> schema-mapping 전용 단독 실행 불요. ddl-auto=validate 무영향.
- pre-existing 실패 주장 시 baseline(git stash) 대조.

## 6. 트레이드오프
- facade 확장 vs 신규 facade: 확장 선택(응집·중복 회피). 비용: SellerProductFacade가 등록/수정/목록을 모두 노출해 다소 비대 — 그러나 모두 판매자 상품 관리 View 단일 책임 내라 허용.
- 파생 쿼리 vs @Query: 파생 선택(집계 불필요·단순). 비용: 향후 variant 개수/이미지 썸네일 등 목록 표시 요구가 생기면 @Query 집계로 승격 필요 — 현 범위(상품명/상태/가격/등록일)에선 불필요(과도설계 회피).
- basePrice 노출 vs displayPrice 집계: basePrice 선택(소유자 화면·수정 화면 일관·쿼리 단순). 비용: 공개 노출가(variant 최저가)와 다를 수 있으나 판매자 본인 화면이라 의도된 차이.
- 목록 ADMIN 특례 없음: 목록은 항상 본인 ownerId. 비용: ADMIN의 전체 상품 관리 화면은 본 task로 제공 안 됨(범위 밖 — 별 task). 이점: IDOR 단순·예측 가능.
- active 키 prefix 순서 의존: /seller/products/new를 먼저 검사하는 순서에 의존. 비용: 순서 실수 시 등록이 내 상품 활성으로 오표시 — 테스트(E2E nav active)로 가드.

---

## 완료 조건
- [ ] GET /seller/products가 본인(ownerId) 상품만 최신순 페이지네이션으로 렌더한다.
- [ ] 타 판매자 상품이 결과/DOM에 노출되지 않는다(리포 통합 + E2E 단언).
- [ ] web->SellerProductFacade->ProductService->ProductRepository 경유, web이 Entity/ProductStatus/Repository 직접 참조 없음.
- [ ] 모델 키 sellerProducts(예약어 회피), 모델에 Entity 미포함(DTO만).
- [ ] 각 행에 수정(/{id}/edit)·이미지(/{id}/images)·옵션(/{id}/variants) 링크, 빈 상태, 페이지네이션.
- [ ] nav SELLER 내 상품(/seller/products) 링크 추가, active 키 목록(seller-products)/등록(seller-product-new) 구분.
- [ ] Security: SELLER/ADMIN 200, CONSUMER 403, 미인증 302.
- [ ] DB 스키마·이벤트·notification 무변경.
- [ ] 단위/DB통합/Security 슬라이스 작성, ./gradlew test 전체 그린(메인 직접 확인), E2E 가시성 검증(e2e-runner).

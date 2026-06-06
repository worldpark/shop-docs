# 013. shop-core 공개 상품 목록 + 상세 화면 — 구현 계획(plan)

> Task SSOT: docs/tasks/backend/013-backend-shop-core-public-product-catalog-with-view.md
> 본 문서는 구현 위임용 plan이다. 코드 작성은 backend-implementor / view-implementor가 수행한다.
> 진행: backend-implementor → view-implementor → reviewer → fixer 사이클(최대 3회).
> 선례 코드(009 category 공개조회 / 010 variant / 012 image+facade 스택)의 네이밍·레이어·예외·테스트 패턴을 그대로 따른다.

---

## 0. 사전 확정 사실 (실제 코드 점검 완료)

- Entity 필드(확정)
  - Product: id, @ManyToOne(LAZY) Category category(nullable), Long ownerId(스칼라), name, description, BigDecimal basePrice, @Enumerated(STRING) ProductStatus status. status ∈ {DRAFT, ON_SALE, SOLD_OUT, HIDDEN}.
  - ProductVariant: id, @ManyToOne(LAZY) Product product, sku, BigDecimal price, int stock, boolean isActive(컬럼 is_active), @ManyToMany(LAZY) Set<OptionValue> optionValues(조인 variant_values). updated_at 없음 → BaseEntity 미상속.
  - ProductImage: id, @ManyToOne(LAZY) Product product, storageKey, int sortOrder, boolean isPrimary(컬럼 is_primary). partial unique index uq_product_images_primary(product_id WHERE is_primary).
  - ProductOption: id, product, name. OptionValue: id, @ManyToOne option, value.
  - Category: id, parent(self), name, slug, sortOrder.
- Repository 패턴: Spring Data JPA만 사용. QueryDSL 미도입(build.gradle 확인). 집계 쿼리는 JPQL @Query + 생성자 projection으로 구현한다.
- 공개 카테고리 조회 기존 존재: GET /api/v1/categories → CategoryRestController → CategoryServiceResponse → CategoryService.list() → CategoryRepository.findAllByOrderBySortOrderAscIdAsc(). View 필터용 카테고리도 이 경로(facade 경유)를 재사용한다.
- AssetUrlResolver / StorageProperties / StaticResourceConfig 기존 존재(012): AssetUrlResolver.toUrl(storageKey)가 URL 합성 단일 지점. publicPrefix=/assets. 신규 추가 불요 — 재사용만 한다.
- spi facade + impl 패턴 확정(012): 인터페이스는 product/spi(@NamedInterface("spi")), 구현체는 product/service에 package-private(class ...FacadeImpl implements ...). web은 facade 인터페이스만 의존. View 진입점은 web/product ViewController → facade. CurrentActorResolver/CurrentActor는 인증 화면용이며 공개 화면은 인증 불필요라 사용하지 않는다.
- REST principal: JWT 필터 후 (long) auth.getPrincipal(). 단, 공개 API는 비인증 호출이므로 actorId를 쓰지 않는다(소유권 검사 없음).
- SecurityConfig: REST 체인(@Order(1), /api/v1/**)·View 체인(@Order(2)) 분리. 현재 공개 REST: POST login/refresh/signup, GET /api/v1/categories. 공개 View: GET login, css/js/images/assets/favicon/error, signup. 상품 공개 경로는 둘 다 미등록 → anyRequest().authenticated()로 보호됨 → 추가 필요.
- 예외: 모든 도메인 예외는 BusinessException(message, HttpStatus) 상속. ProductNotFoundException(long) → 404 존재. REST는 RestExceptionHandler(@RestControllerAdvice), View는 ViewExceptionHandler(@ControllerAdvice(annotations=Controller)) → error/error 뷰(status/message 모델). 신규 예외 불요(404는 기존 ProductNotFoundException 재사용).
- 테스트 프로파일 제약(중요): src/test/resources/application.yml이 DataSource·HibernateJpa·Flyway 자동설정을 제외한다. 따라서 @DataJpaTest 슬라이스가 이 프로젝트에서 동작하지 않는다(ProductVariantRepository javadoc도 명시). → repository JPQL 집계/페이징 쿼리의 실 DB 동작은 docker-compose 수동 확인 항목으로 남기고, 자동 테스트는 Service(Mockito)·REST/View(@MockitoBean facade)·구조 테스트로 커버한다.
- PageResponse 공통 record 존재(common/dto): PageResponse.of(Page)로 REST 페이지 래핑.
- 구조 테스트: WebModuleStructureTest(ArchUnit)가 web→product.domain/repository/service 직접참조 금지, product→web 역참조 금지를 이미 검증. ModularityTests.verify()로 Modulith 경계 검증.

---

## 1. 설계 방식 및 이유

### 1.1 전체 구조 — 공개 읽기 전용 스택을 기존 레이어로 신설
관리자/판매자 쓰기 스택과 분리된 공개 읽기 전용 스택을 신설한다(소유권 검사 없음, status 화이트리스트만 적용).

- REST: PublicProductRestController → PublicProductServiceResponse → PublicProductService → repository(들)
- View: PublicProductViewController(web/product) → PublicProductFacade(product.spi) → PublicProductService → repository(들)
- facade 구현체 PublicProductFacadeImpl은 product 내부 service 패키지에 package-private으로 두고, PublicProductService 위임 + Entity→DTO 변환 + AssetUrlResolver URL 합성을 담당한다.

이유: 컨벤션 일관성(012 패턴 미러링), 모듈 경계(web→product.spi 단방향) 자동 준수, 공개/비공개 책임 분리로 status 노출 규칙 누락 위험 감소.

### 1.2 status 가시성 규칙을 Service에 단일 집중
공개 노출 = ON_SALE ∪ SOLD_OUT, DRAFT/HIDDEN 제외 를 PublicProductService(및 repository 쿼리의 WHERE) 한 곳에서만 판정한다. Controller/Facade/View는 이 규칙을 재구현하지 않는다.
- 목록: repository 쿼리 WHERE status IN ('ON_SALE','SOLD_OUT').
- 상세: 단건 조회 후 status가 화이트리스트 밖(DRAFT/HIDDEN) 또는 미존재 → ProductNotFoundException(404). 존재 은닉(DRAFT/HIDDEN을 403이 아닌 404로) 처리.

### 1.3 displayPrice·정렬을 page 쿼리 단계 GROUP BY 집계로 수행 (메모리 정렬 금지)
가격 정렬과 displayPrice를 DB 쿼리 projection에서 계산한다(Task 핵심 요구).

- 집계 키: 상품별 활성 variant min(price). 활성 variant가 없으면 basePrice 폴백.
- JPQL 표현: Product p LEFT JOIN ProductVariant v ON v.product = p AND v.isActive = true 후 GROUP BY p.id 하고 정렬/표시 가격을 COALESCE(MIN(v.price), p.basePrice)로 계산.
- 페이징: Pageable(page/size) + 별도 countQuery로 totalElements 산출(GROUP BY 페이징은 countQuery 분리 필수). content projection은 displayPrice까지 포함한 요약 projection DTO(productId, name, displayPrice, categoryId, categoryName, status, soldOut 판정용 재고존재 플래그)로 받는다.
- 정렬:
  - 최신순(default): ORDER BY p.createdAt DESC, p.id DESC.
  - 낮은 가격순: ORDER BY displayPrice ASC, p.id ASC.
  - 높은 가격순: ORDER BY displayPrice DESC, p.id ASC.
  - 정렬 키는 sort 파라미터(enum/String)로 받아 Service에서 분기하여 정해진 JPQL/Sort를 선택한다(클라이언트 임의 정렬 필드 주입 차단).

### 1.4 N+1 회피 — 대표 이미지만 productId IN (...) 배치 조회
요약 projection은 이미지 join을 하지 않는다(이미지가 여러 장이면 GROUP BY 카디널리티 오염). 대신:
1. page 쿼리로 현재 페이지의 productId 목록 확보.
2. ProductImageRepository.findByProductIdInAndIsPrimaryTrue(List<Long> productIds)(신규)로 대표 이미지만 1쿼리 IN 배치 조회 → Map<productId, ProductImage> 구성.
3. 요약 DTO 조립 시 map lookup으로 primaryImageUrl 채움(없으면 null → View placeholder). URL은 AssetUrlResolver.toUrl로 합성.

이유: Task 명시(displayPrice는 page projection, 대표 이미지는 IN 배치). variant 집계 + 이미지 IN 조회 = 페이지당 2~3쿼리 고정(N+1 제거).

### 1.5 soldOut(상품 단위) 판정 규칙
soldOut = !(status == ON_SALE && 재고>0인 활성 variant가 1개 이상 존재).
- 목록: page 쿼리 projection에 purchasable 집계를 함께 계산한다 — 같은 LEFT JOIN(활성 variant)에서 SUM(CASE WHEN v.isActive AND v.stock > 0 THEN 1 ELSE 0 END) > 0 형태로 구매가능 활성variant 존재 여부 플래그를 산출하고, Service/DTO에서 soldOut = !(status==ON_SALE && hasPurchasableVariant)로 확정. (status==SOLD_OUT이면 무조건 soldOut=true.)
- 상세: 활성 variant 목록을 로드하므로 메모리에서 동일 규칙 판정 가능. 일관성을 위해 상세도 같은 식 soldOut = !(status==ON_SALE && anyActiveVariant.stock>0)로 계산.

### 1.6 상세 조립 — 활성 variant만, 정렬 이미지, 옵션/옵션값
상세는 단건이므로 N+1 부담이 작다. PublicProductService.getDetail(productId)에서:
1. ProductRepository로 상품 단건 로드(없거나 DRAFT/HIDDEN → 404).
2. 이미지: findByProductIdOrderBySortOrderAscIdAsc(기존) — 정렬 순서 유지, primary 플래그 포함.
3. 옵션/옵션값: findByProductIdOrderById(기존) + 옵션별 findByOptionIdOrderById(기존). 옵션값 id 목록을 variant 매핑에 사용.
4. variant: 활성만 — ProductVariantRepository.findByProductIdAndIsActiveTrue(productId)(신규, @EntityGraph(optionValues)로 LazyInit 회피). 비활성 variant는 절대 노출 금지.
5. variant available = (product.status==ON_SALE && v.stock>0). SOLD_OUT 상품 variant는 재고가 있어도 available=false.
6. displayPrice = 활성 variant min(price), 활성 없으면 basePrice 폴백(메모리 계산 — 상세는 단건).
7. DTO(PublicProductDetailResponse) 조립. sku / stock 수치 / basePrice / ownerId / storageKey / 절대경로는 노출 금지(available boolean, displayPrice, imageUrl만).

### 1.7 공개 응답 비노출 필드 강제
요약·상세 DTO에 basePrice, ownerId, storageKey, sku, 로컬 절대경로, Entity 객체를 두지 않는다. 공개 가격은 displayPrice 단일 필드. 이미지 경로는 imageUrl(AssetUrlResolver 합성)만. REST/Security 테스트에서 응답 본문에 이 필드들이 없음을 명시 단언한다.

---

## 2. 구성 요소 (신규/수정 파일 — 정확한 패키지 경로)

### 2.1 backend-implementor 담당 범위

#### 신규 — product/dto (공개 응답 DTO)
- product/dto/PublicProductSummaryResponse.java — record(long productId, String name, BigDecimal displayPrice, Long categoryId, String categoryName, String primaryImageUrl, boolean soldOut). Entity·basePrice·ownerId·storageKey 미노출.
- product/dto/PublicProductDetailResponse.java — record(long productId, String name, String description, BigDecimal displayPrice, boolean soldOut, PublicCategoryResponse category, List<PublicProductImageResponse> images, List<PublicProductOptionResponse> options, List<PublicProductVariantResponse> variants).
- product/dto/PublicProductImageResponse.java — record(long imageId, String imageUrl, int sortOrder, boolean primary). storageKey 미노출. from(ProductImage, AssetUrlResolver).
- product/dto/PublicProductOptionResponse.java — record(long optionId, String name, List<PublicOptionValueResponse> values).
- product/dto/PublicOptionValueResponse.java — record(long optionValueId, String value).
- product/dto/PublicProductVariantResponse.java — record(long variantId, BigDecimal price, List<Long> optionValueIds, boolean available). sku·stock 수치 미노출.
- product/dto/PublicCategoryResponse.java — record(Long categoryId, String name). 상세 category용(공개 최소 필드만). 필터용 목록은 기존 facade 경유 CategoryResponse 재사용 가능.
- product/dto/ProductSummaryProjection.java(내부 projection record) — repository JPQL 생성자 projection 대상. 필드: long productId, String name, BigDecimal displayPrice, Long categoryId, String categoryName, ProductStatus status, boolean hasPurchasableVariant. SummaryResponse와 분리된 내부 projection(엔티티 미노출).

projection record는 JPQL new ...ProductSummaryProjection(...) 생성자 표현식에 매핑한다. boolean 집계는 DB가 boolean을 직접 못 주면 COUNT/SUM 정수로 받고 record 보조 팩토리에서 0 초과 변환(구현 디테일은 backend-implementor 재량, 메모리 정렬 금지 원칙 유지).

#### 수정 — product/repository
- product/repository/ProductRepository.java — 목록 page 쿼리(JPQL @Query) 추가. SELECT 생성자 projection으로 displayPrice = COALESCE(MIN(활성 v.price), p.basePrice) 계산. Product p LEFT JOIN p.category c LEFT JOIN ProductVariant v ON v.product=p, WHERE status IN :statuses, keyword(:keyword IS NULL OR lower(p.name) LIKE ...), categoryId(:categoryId IS NULL OR c.id=:categoryId), GROUP BY p.id 등. countQuery는 GROUP BY 페이징 대응으로 분리 작성(SELECT COUNT(p) ... 동일 WHERE). 정렬은 ORDER BY 파라미터화 불가(JPQL 정적) → 정렬별 메서드 3종(latest/priceAsc/priceDesc)으로 분리, Service가 sort로 선택. 페이징은 Pageable.
- product/repository/ProductImageRepository.java — findByProductIdInAndIsPrimaryTrue(List<Long> productIds) 추가(대표 이미지 IN 배치 조회). 빈 리스트 방어는 Service에서.
- product/repository/ProductVariantRepository.java — @EntityGraph(attributePaths="optionValues") findByProductIdAndIsActiveTrue(long productId) 추가(상세 활성 variant 로드, LazyInit 회피).

신규 인덱스·migration 추가 금지(Constraint). 기존 인덱스 활용. 성능 개선은 후속 Task.

#### 신규 — product/service
- product/service/PublicProductService.java — @Service @Transactional(readOnly=true). 도메인 읽기 로직 단일 소유. 책임:
  - findPublicProducts(keyword, categoryId, PublicProductSort sort, Pageable) → Page<ProductSummaryProjection>. status 화이트리스트 [ON_SALE, SOLD_OUT] 적용 + 정렬별 repository 메서드 선택.
  - findPrimaryImages(List<Long> productIds) → Map<Long, ProductImage>. IN 배치 조회(빈 리스트면 빈 맵, 쿼리 생략).
  - getPublicProductDetail(long productId) → 내부 aggregate. 화이트리스트 검사 후 상품/이미지/옵션/옵션값/활성variant 로드(미존재·DRAFT·HIDDEN → ProductNotFoundException 404). 엔티티는 모듈 밖으로 미노출(facade/ServiceResponse가 DTO 변환).
  - soldOut/available/displayPrice 판정 헬퍼.
- product/service/PublicProductSort.java — enum(LATEST, PRICE_ASC, PRICE_DESC). product 내부. web에는 String만 전달되도록 facade가 변환.
- product/service/PublicProductServiceResponse.java — @Service. REST 전용 조립. 비즈니스 로직 없음. AssetUrlResolver 주입.
  - list(keyword, categoryId, sort, page, size) → PageResponse<PublicProductSummaryResponse>. Service 호출 + 대표이미지 IN 배치 + DTO 조립(soldOut/primaryImageUrl) + PageResponse.of.
  - detail(productId) → PublicProductDetailResponse.
- product/service/PublicProductFacadeImpl.java — PublicProductFacade 구현(package-private class). PublicProductService + AssetUrlResolver + (필터용) CategoryService 위임. Entity→View DTO 변환. sort String→enum 변환.

#### 신규 — product/spi
- product/spi/PublicProductFacade.java — published port(@NamedInterface "spi" 패키지). 시그니처는 6절 참조. web이 도메인 enum을 참조하지 않도록 sort는 String으로 받는다.

#### 신규 — product/controller
- product/controller/PublicProductRestController.java — @RestController @RequestMapping("/api/v1/products"). GET 목록(@RequestParam keyword/categoryId/sort/page/size, 기본값) → PageResponse<PublicProductSummaryResponse>. GET /{productId} 상세 → PublicProductDetailResponse. 비즈니스 로직 없음 — PublicProductServiceResponse 위임. 인증/principal 미사용(공개).

#### 수정 — security
- security/SecurityConfig.java:
  - REST 체인: anyRequest().authenticated() 앞에 GET /api/v1/products, /api/v1/products/* permitAll 추가.
  - View 체인: anyRequest().authenticated() 앞에 GET /products, /products/* permitAll 추가.

#### 신규 — 테스트 (backend) → 5절 매핑
- product/service/PublicProductServiceTest.java (단위, Mockito, repository mock)
- product/service/PublicProductServiceResponseTest.java (단위: DTO 조립·대표이미지 배치·displayPrice/soldOut·basePrice 미노출)
- product/service/PublicProductFacadeImplTest.java (단위: 위임·DTO 변환·sort String 변환)
- product/controller/PublicProductRestControllerSecurityTest.java (@SpringBootTest+MockMvc+@MockitoBean serviceResponse: 비인증/role 200, 404, 검색·필터·정렬·페이징 응답 구조, 비노출 필드 단언)

repository JPQL 집계/페이징은 테스트 프로파일이 JPA 자동설정을 제외하므로 자동 검증 불가 → docker-compose 수동 확인 항목으로 보고에 남긴다. Service 단위 테스트는 repository를 mock하여 정렬별 올바른 repository 메서드 선택 / status 화이트리스트 전달 / 대표이미지 IN 호출 / soldOut·displayPrice·available 판정을 검증한다.

#### 구조 테스트(기존 통과 확인)
- WebModuleStructureTest(기존) — 신규 web/product/PublicProductViewController도 자동으로 규칙 대상. 추가 변경 불요.
- ModularityTests.verify()(기존) — 신규 spi/controller/service가 경계 위반 없이 통과 확인.

### 2.2 view-implementor 담당 범위

#### 신규 — web/product
- web/product/PublicProductViewController.java — @Controller. GET /products 목록(@RequestParam keyword/categoryId/sort/page/size) → PublicProductFacade 위임 → 모델 products(facade 반환 페이지 뷰), searchCondition, categories → view product/list. GET /products/{productId} 상세 → 모델 product → view product/detail. 미존재/비공개는 facade가 ProductNotFoundException(404) → ViewExceptionHandler → error/error. 인증 미사용.
- web/product/ProductSearchCondition.java — 조건 객체(String keyword, Long categoryId, String sort, int page, int size). 모델 키 searchCondition. 검색 폼·정렬 셀렉트·페이징 링크에 사용.

ViewController가 다룰 페이지 메타(totalPages 등)는 facade가 반환하는 View 전용 페이지 DTO로 전달한다(Entity·Page 직접 노출 금지). 모델에는 DTO만.

#### 신규 — templates
- templates/product/list.html — layout/base + fragments(header/nav/footer/messages). 검색 폼, 카테고리 필터 셀렉트(categories), 정렬 컨트롤(최신/낮은가격/높은가격), 상품 카드 그리드(products): 대표 이미지(primaryImageUrl, 없으면 placeholder), 상품명, displayPrice, soldOut 품절 표시. pagination UI(page/totalPages). 이미지 url은 DTO primaryImageUrl 그대로.
- templates/product/detail.html — 이미지 갤러리(정렬된 product.images), 상품명·설명·displayPrice, soldOut 표시, 옵션/옵션값(product.options), 활성 variant 목록(product.variants: price·available). 장바구니 버튼은 비활성/준비중 안내. sku/stock/basePrice/ownerId/storageKey 미표시.

#### 수정 — templates
- templates/fragments/nav.html — 공개 상품 목록 링크 /products 추가(비인증 포함 노출, sec:authorize 없이). active 키 예: products.

#### 신규 — 테스트 (view) → 5절 매핑
- view/PublicProductListRenderingTest.java (@SpringBootTest+MockMvc, PublicProductFacade @MockitoBean): 비인증 200, 검색 폼/카테고리 필터/sort 컨트롤, 상품 카드(이미지/이름/가격/품절), 대표이미지 없는 카드 placeholder, pagination.
- view/PublicProductDetailRenderingTest.java: 비인증 200, 이미지 갤러리, 옵션/variant, soldOut 표시, 비공개/미존재 → error 뷰 또는 404.
- view/LayoutRenderingTest(기존 보강) 또는 신규 nav 검증: nav에 /products 링크 노출.
- web/product/PublicProductViewControllerTest.java (컨트롤러 단위, facade mock): 모델 키 주입, view name, 검색 파라미터 전달, 404 처리.

---

## 3. 데이터 흐름

### 3.1 목록 — REST (GET /api/v1/products)
1. 비인증 허용(Security REST 체인 permitAll). principal 미사용.
2. Controller → PublicProductServiceResponse.list(keyword, categoryId, sort, page, size).
3. ServiceResponse → PublicProductService.findPublicProducts(...):
   - status 화이트리스트 [ON_SALE, SOLD_OUT] 적용.
   - sort(String→enum)별 repository JPQL 메서드 선택(latest/priceAsc/priceDesc).
   - JPQL: Product LEFT JOIN 활성 variant, GROUP BY p.id, displayPrice = COALESCE(MIN(활성 v.price), p.basePrice), 구매가능 활성variant 존재 플래그 집계. keyword(lower LIKE)·categoryId 필터. countQuery 분리 페이징. → Page<ProductSummaryProjection>.
4. ServiceResponse: 현재 페이지 productId 목록 → PublicProductService.findPrimaryImages(ids)(findByProductIdInAndIsPrimaryTrue 1쿼리) → Map<id, ProductImage>.
5. projection + 대표이미지 map → PublicProductSummaryResponse(soldOut = !(status==ON_SALE && hasPurchasable), primaryImageUrl = AssetUrlResolver.toUrl 또는 null) → PageResponse.of.
6. 200 JSON. 메모리 정렬 없음(정렬은 3단계 쿼리에서 종료).

### 3.2 목록 — View (GET /products)
1~5. 동일 로직을 PublicProductFacade.listProducts(keyword, categoryId, sort, page, size)가 수행(내부에서 PublicProductService + 대표이미지 배치 + DTO 변환). web은 facade만 호출.
6. 모델 products(View 페이지 DTO), searchCondition, categories → product/list 렌더.

### 3.3 상세 — REST (GET /api/v1/products/{productId})
1. 비인증 허용. principal 미사용.
2. Controller → PublicProductServiceResponse.detail(productId) → PublicProductService.getPublicProductDetail(productId).
3. Service: 상품 단건 로드. 미존재 또는 status ∈ {DRAFT, HIDDEN} → ProductNotFoundException(404). ON_SALE/SOLD_OUT만 통과.
4. 이미지(정렬), 옵션/옵션값, 활성 variant만(findByProductIdAndIsActiveTrue, EntityGraph) 로드.
5. displayPrice = 활성 variant min(price) 또는 basePrice 폴백. soldOut = !(ON_SALE && 재고>0 활성 variant 존재). variant.available = (ON_SALE && stock>0).
6. PublicProductDetailResponse 조립(imageUrl 합성, sku/stock/basePrice/ownerId/storageKey 미포함). 200 JSON.

### 3.4 상세 — View (GET /products/{productId})
1~5. PublicProductFacade.getProductDetail(productId)가 동일 로직 수행 + DTO 변환.
6. 모델 product(상세 DTO, images/options/variants 포함) → product/detail 렌더. 비공개/미존재 → ProductNotFoundException → ViewExceptionHandler → error/error(404).

### 3.5 카테고리 필터 목록
- View 필터 셀렉트용 카테고리는 PublicProductFacade.listCategories()가 기존 CategoryService.list() 위임 → DTO 변환(CategoryResponse 재사용). 모델 키 categories.

### 3.6 이미지 공개 서빙
- 대표/상세 이미지 URL은 AssetUrlResolver.toUrl(storageKey) = assetBaseUrl + /assets + / + storageKey. 실제 파일은 기존 StaticResourceConfig가 /assets/** → 저장 root 매핑, SecurityConfig View 체인 /assets/** permitAll(기존)로 비인증 200.

---

## 4. 예외 처리 전략 (error-response-rule 준수)

| 상황 | 발생 지점 | REST 매핑 | View 매핑 |
|---|---|---|---|
| 미존재 상품 상세 | PublicProductService | 404 ProductNotFoundException(기존) → RestExceptionHandler ErrorResponse JSON | ViewExceptionHandler → error/error(status=404) |
| DRAFT/HIDDEN 상세 | PublicProductService(화이트리스트) | 404 ProductNotFoundException(존재 은닉 — 403 아님) | 동일 404 error 뷰 |
| 목록 정상 | — | 200 PageResponse(빈 결과면 content=[]) | 200 빈 목록 렌더(없음 표시) |
| 비인증 목록/상세 | Security permitAll | 정상 200(인증 불필요) | 정상 200 |
| 잘못된 sort 값 | PublicProductService | 정의 외 sort는 기본(LATEST)로 폴백 | 동일 폴백 |
| page/size 음수·과대 | Controller/Service | size 상한 클램프(예: 1~100), page>=0 보정 | 동일 |

핵심 규칙:
- 공개 비노출 규칙은 404 존재 은닉으로 통일(DRAFT/HIDDEN/미존재 모두 404). 권한 부족(403) 아님 — 공개 API라 권한 개념 없음.
- 신규 예외 클래스 불요(기존 ProductNotFoundException 재사용).
- REST는 JSON ErrorResponse, View는 HTML error 뷰 — 핸들러 분리 기존 구조 그대로.
- 내부정보(sku/storageKey/절대경로/스택트레이스) 응답 미노출.

---

## 5. 검증 방법 (테스트 클래스 매핑)

### 단위 — PublicProductServiceTest (Mockito, repository mock)
- 공개 목록 조회 성공(화이트리스트 statuses 전달 검증).
- sort별 올바른 repository 메서드 선택(LATEST/PRICE_ASC/PRICE_DESC) — 쿼리 단계 정렬, 메모리 정렬 아님(서비스가 결과를 재정렬하지 않음).
- keyword/categoryId 필터 파라미터 전달.
- 대표이미지 findByProductIdInAndIsPrimaryTrue 호출(IN 배치) 검증.
- displayPrice 폴백(활성 variant 없으면 basePrice) — projection 기반.
- soldOut 판정: SOLD_OUT / ON_SALE+재고없음 / 활성 variant 없음 → soldOut=true; 재고>0 ON_SALE → false.
- 상세: ON_SALE/SOLD_OUT 성공, DRAFT/HIDDEN/미존재 → ProductNotFoundException(404).
- 상세 활성 variant만 포함(findByProductIdAndIsActiveTrue 사용 — 비활성 제외).
- variant available: SOLD_OUT 상품 variant는 재고>0이어도 available=false.
- 상세 이미지 정렬 유지(findBy...OrderBySortOrderAscIdAsc).
- 옵션/옵션값 변환.

### 단위 — PublicProductServiceResponseTest / PublicProductFacadeImplTest
- projection + 대표이미지 map → SummaryResponse 조립, primaryImageUrl 합성(AssetUrlResolver) / 대표 없으면 null.
- 공개 응답(요약·상세)에 basePrice/ownerId/storageKey/sku 미노출 단언.
- detail DTO 조립(images/options/variants), displayPrice/soldOut/available 값.
- facade: sort String→enum 변환, 위임, Entity→DTO 변환, listCategories 위임.

### REST/Security — PublicProductRestControllerSecurityTest (@SpringBootTest, MockMvc, @MockitoBean)
- GET /api/v1/products 비인증 200 / CONSUMER·SELLER·ADMIN 200.
- GET /api/v1/products/{id} 비인증 200(ON_SALE/SOLD_OUT) / DRAFT·HIDDEN·미존재 404.
- 목록 검색·필터·정렬·pagination 응답 구조(content/page/size/totalElements/totalPages).
- 상세 응답에 images/options/variants 포함.
- 응답 본문에 ownerId/storageKey/basePrice/sku/로컬 절대경로 미포함(jsonPath doesNotExist).

### View — PublicProductListRenderingTest / PublicProductDetailRenderingTest / nav (@MockitoBean facade)
- GET /products 비인증 렌더 / 검색 폼·카테고리 필터·sort 컨트롤 / 상품 카드(이미지·이름·가격·품절) / 대표이미지 없는 카드 placeholder / pagination.
- GET /products/{id} 비인증 렌더 / 이미지 갤러리 / 옵션·variant / soldOut 표시 / 비공개·미존재 → error 뷰(404).
- nav에 /products 링크 노출(비인증 포함).

### 구조 — WebModuleStructureTest / ModularityTests (기존)
- web.product가 product.domain/repository/service 미참조(신규 ViewController 포함).
- product가 web 미참조.
- 공개 ViewController가 facade(spi)만 의존.
- ModularityTests.verify() 통과.

### 실행 / 수동 확인
- ./gradlew test 전체 통과.
- docker-compose 수동 확인(테스트 프로파일 JPA 제외로 자동 불가): 목록 GROUP BY 집계 정렬(낮은/높은 가격순)·displayPrice·countQuery 페이징·대표이미지 IN 배치·상세 활성 variant EntityGraph 로딩이 실 PostgreSQL에서 동작하는지. 확인/미확인 항목을 작업 보고에 남긴다.

---

## 6. 양 영역 인터페이스 접점 (어긋남 방지)

### PublicProductFacade (product.spi) 시그니처(안)

    PublicProductPage listProducts(String keyword, Long categoryId, String sort, int page, int size);
    PublicProductDetailView getProductDetail(long productId);
    List<CategoryResponse> listCategories();   // 필터 셀렉트용 (기존 CategoryResponse 재사용)

PublicProductPage(content=List<PublicProductSummaryView> + page/size/totalElements/totalPages), PublicProductSummaryView/PublicProductDetailView는 View 전용 DTO(product/dto). web은 sort/keyword를 String/Long/int로만 전달(도메인 enum 비참조). facade 내부에서 sort String→PublicProductSort 변환, displayPrice/soldOut/imageUrl 확정.

### REST 응답 DTO (product/dto)
- PublicProductSummaryResponse(productId, name, displayPrice, categoryId, categoryName, primaryImageUrl, soldOut)
- PublicProductDetailResponse(productId, name, description, displayPrice, soldOut, category, images, options, variants)
- PublicProductImageResponse(imageId, imageUrl, sortOrder, primary)
- PublicProductOptionResponse(optionId, name, values) / PublicOptionValueResponse(optionValueId, value)
- PublicProductVariantResponse(variantId, price, optionValueIds, available)

### 모델 키 (View — Task Backend-View Contract 준수)
- 목록: products, searchCondition, categories → view product/list
- 상세: product (→ product.images, product.options, product.variants) → view product/detail
- 검색 파라미터: keyword, categoryId, sort, page, size
- nav 링크: /products

### 경로
- REST: GET /api/v1/products, GET /api/v1/products/{productId}
- View: GET /products, GET /products/{productId}

### sort 파라미터 값(확정 — 양측 합의)
- latest(기본), priceAsc(낮은 가격순), priceDesc(높은 가격순). 정의 외 값은 latest 폴백.

---

## 7. 트레이드오프

- GROUP BY 집계 + countQuery 분리 페이징(메모리 정렬 금지): Task 핵심 요구. JPQL 정렬은 ORDER BY 파라미터화가 불가해 정렬별 메서드/분기를 3종 두는 비용이 있으나, 임의 정렬 필드 주입 차단·쿼리 단계 정렬 보장이라는 정확성 이득이 크다.
- 대표 이미지 IN 배치(2~3쿼리/페이지): 이미지를 page 쿼리에 join하지 않아 GROUP BY 카디널리티 오염을 피하고 N+1을 제거한다. 페이지당 추가 1쿼리는 수용.
- 테스트 프로파일 JPA 제외 → repository 쿼리 자동검증 불가: Service/REST/View는 Mockito·@MockitoBean으로 충분히 커버하나, 집계/정렬/페이징의 실 SQL 정확성은 docker-compose 수동 확인에 의존한다(프로젝트 기존 제약과 동일, 010/012 선례 동일 정책).
- 404 존재 은닉(DRAFT/HIDDEN→404): 비공개 상품 존재를 숨겨 정보 노출을 줄인다. 공개 API라 403 권한 개념이 없어 404가 적절.
- 공개 DTO 신규 분리(기존 SellerProductRef/ProductResponse 재사용 안 함): basePrice/sku/ownerId 등 비노출 필드를 구조적으로 차단하기 위해 공개 전용 DTO를 둔다. DTO 클래스 수는 늘지만 노출 사고 위험을 컴파일 단계에서 제거.
- 장바구니/주문/검색엔진 미구현: Task Constraint 준수. 상세의 장바구니 버튼은 비활성/준비중 안내로만 둔다.

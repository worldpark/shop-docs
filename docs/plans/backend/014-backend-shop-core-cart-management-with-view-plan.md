# 014. shop-core 장바구니 담기 + 조회 + 수량 변경 화면 — 구현 계획(plan)

> Task SSOT: docs/tasks/backend/014-backend-shop-core-cart-management-with-view.md
> 본 문서는 구현 위임용 plan이다. 코드 작성은 backend-implementor / view-implementor가 수행한다.
> 진행: backend-implementor → view-implementor → reviewer → fixer 사이클(최대 3회).
> 선례 코드(009 UserDirectory 의존역전 / 010 variant 쓰기·소유권 / 012 facade+impl / 013 공개 카탈로그 스택)의 네이밍·레이어·예외·테스트 패턴을 그대로 따른다.

---

## 0. 사전 확정 사실 (실제 코드 점검 완료)

- **carts / cart_items 스키마는 V1에 이미 존재한다 — 신규 migration 불필요(확정).**
  - `carts(id, user_id, created_at, updated_at)`, `CONSTRAINT uq_carts_user_id UNIQUE (user_id)`, `trg_carts_set_updated_at` 트리거 보유. updated_at 컬럼 존재 → Cart Entity는 BaseEntity 상속 또는 created_at/updated_at 매핑 가능.
  - `cart_items(id, cart_id, variant_id, quantity, added_at)`, `CHECK (quantity > 0)`, `CONSTRAINT uq_cart_items_cart_variant UNIQUE (cart_id, variant_id)`. updated_at 컬럼 **없음** → CartItem은 BaseEntity 미상속(ProductVariant 선례와 동일), added_at은 DB default now() 읽기전용 매핑(insertable=false 권장) 또는 생성 시 1회 세팅.
  - 두 unique 제약(`uq_carts_user_id`, `uq_cart_items_cart_variant`)은 동시성 경합 복구의 기반이다. 신규 인덱스 추가 금지(Constraint) — 기존 제약만 사용.
- **cart 모듈은 현재 골격(package-info만)뿐이다.** controller/domain/dto/repository/service/event/messaging 패키지 package-info 존재. 이번 Task는 controller/domain/dto/repository/service + 신규 spi 패키지를 채운다(event/messaging은 이번 범위 외).
- **product.spi 기존**: `PublicProductFacade`(013, View 카탈로그), `SellerProductFacade/ImageFacade/VariantFacade`(010/012), `UserDirectory`(009 — product 소유 포트). cart는 신규 `ProductPurchaseCatalog`를 추가한다. **`UserDirectory`는 product 소유 포트이므로 cart가 재사용 금지(Task 명시).**
- **member.spi 기존**: `MemberSignupFacade`, `AdminMemberFacade` 만 존재. **email→userId 조회 포트는 member.spi에 없다.** 현재 email→userId 변환은 `product.spi.UserDirectory` ← `member.adapter.MemberUserDirectoryAdapter`(member가 product 포트를 구현하는 의존역전)로만 제공된다. cart용으로는 **member가 소유하는 신규 `member.spi.MemberDirectory` 포트**를 추가하고 구현을 member/service에 둔다(소유=조회 주체 모듈). `member.spi/package-info.java`는 이미 `@NamedInterface("spi")` 선언됨 → 인터페이스만 추가하면 published.
- **member 조회 메서드 존재 확정**: `MemberRepository.findByEmail(String)`(citext 대소문자 무시), `MemberService.getByEmail(String)`→User(없으면 MemberNotFoundException). `MemberDirectory` 구현은 `MemberService.getByEmail(email).getId()`에 위임 + MemberNotFoundException→IllegalStateException 변환(인증 세션-디렉터리 불일치, `MemberUserDirectoryAdapter` 선례 톤 동일).
- **product variant 조회 재사용 가능 메서드**: `ProductVariantRepository.findByProductIdAndIsActiveTrue`(013, @EntityGraph optionValues). 단건/IN 구매조회는 cart 전용 신규 메서드가 필요(아래 2.1). `ProductVariant` Entity 필드 확정: id, @ManyToOne(LAZY) Product product, sku, BigDecimal price, int stock, boolean isActive, Set<OptionValue> optionValues. Product.status ∈ {DRAFT, ON_SALE, SOLD_OUT, HIDDEN}.
- **web.support**: `CurrentActor(email, admin)`, `CurrentActorResolver(Authentication→CurrentActor)`. View 진입은 form-login principal=email(`auth.getName()`). cart View facade는 email을 받아 내부에서 `MemberDirectory`로 userId 변환.
- **REST principal**: JWT 필터 후 `(long) authentication.getPrincipal()`(MemberServiceResponse.me 선례). cart REST ServiceResponse도 동일하게 userId 추출. 즉 **principal 이중경로(REST=userId, View=email)는 cart facade 진입 계층에서 userId로 통일**한다(아래 3절).
- **SecurityConfig**: REST 체인(@Order(1), `/api/v1/**`, CSRF disable, STATELESS, JWT, 401=RestAuthenticationEntryPoint/403=RestAccessDeniedHandler) + View 체인(@Order(2), formLogin /login, CSRF 활성, 미인증 302→/login). 현재 cart 경로는 둘 다 미등록 → `anyRequest().authenticated()`로만 보호(최소권한 ROLE_CONSUMER 미강제). RoleHierarchy = ROLE_ADMIN>ROLE_SELLER>ROLE_CONSUMER(SELLER/ADMIN이 CONSUMER 함의). → cart 경로 명시 추가 필요.
- **예외 컨벤션**: 모든 도메인 예외는 `BusinessException(message, HttpStatus)` 상속. 기본 생성자(message만)는 400. `ProductAccessDeniedException(long)`=404(존재 은닉, 403 미사용). REST=`RestExceptionHandler`(@RestControllerAdvice, BusinessException→status 매핑, MethodArgumentNotValid→400), View=`ViewExceptionHandler`(@ControllerAdvice(annotations=Controller)→error/error). **검증 실패는 400, 타인/미존재 cartItem은 404 존재 은닉으로 통일(Task 명시, 409 분기 금지).**
- **DataIntegrityViolationException 처리 선례**: `MemberService.signup`이 import 후 unique 위반 복구/변환 처리. cart 생성 경합도 동일하게 catch 후 재조회.
- **ServiceResponse 레이어**: REST 전용(View/Scheduler/EventListener 미사용, architecture-rule). 비즈니스 로직 없음, Entity→DTO 변환만. PageResponse 공통 record는 cart에 불필요(장바구니는 페이징 없는 단건 집계).
- **테스트 프로파일 제약(중요, 013 0절과 동일)**: `src/test/resources/application.yml`이 DataSource·HibernateJpa·Flyway 자동설정을 제외 → **@DataJpaTest 슬라이스 동작 불가.** 따라서 atomic UPDATE WHERE 합산검증·unique 경합 복구·added_at 보존 등 **실 DB·실 동시성 자동 검증 불가** → docker-compose 수동 확인 항목으로 남기고, 자동 테스트는 Service(Mockito)·REST/View(@MockitoBean facade)·구조 테스트로 커버한다(5절에서 자동/수동 명확히 구분).
- **구조 테스트**: `WebModuleStructureTest`(ArchUnit)가 web→{member,product,cart,...}.domain/repository/service 직접참조 금지 + 도메인→web 역참조 금지를 이미 검증(cart.* 포함). `ModularityTests.verify()`로 Modulith 경계 검증. cart→product/member 내부참조 금지 및 cart→UserDirectory 미참조는 신규 ArchUnit 규칙으로 추가한다.

---

## 1. 설계 방식 및 이유

### 1.1 전체 구조 — 013 facade 스택 미러링 + 모듈경계 3중 분리
013(공개 카탈로그)의 `RestController→ServiceResponse→Service→Repository` / `ViewController(web)→Facade(spi)→Service→Repository` 2갈래를 그대로 cart에 적용한다. 추가로 모듈 경계를 위해 두 개의 신규 published port를 둔다.

- REST: `CartRestController(/api/v1/cart)` → `CartServiceResponse` → `CartService` → `CartRepository/CartItemRepository`
- View: `CartViewController(web/cart)` → `CartFacade(cart.spi)` → `CartService` → repository(들)
- 모듈 경계:
  - cart → product: **신규 `product.spi.ProductPurchaseCatalog`** (구현 `product/service`)로 variant 구매가능성·표시정보·stock(scalar) 조회. cart는 product 내부 Entity/Repository/Service를 직접 참조하지 않는다.
  - cart → member: **신규 `member.spi.MemberDirectory`**(email→userId, 구현 `member/service`)로 View 진입 email을 userId로 변환. **product.spi.UserDirectory 재사용 금지**(소유 모듈 분리 — member가 자기 디렉터리 포트를 소유).
  - web → cart: `cart.spi.CartFacade`만 의존.

**이유**: 컨벤션 일관성, web→cart.spi / cart→product.spi / cart→member.spi 단방향 의존이 구조 테스트로 자동 강제됨. principal 이중경로 통일과 stock 비노출을 cart 내부 단일 계층에 가둔다.

### 1.2 principal 이중경로를 CartService 진입에서 userId로 통일
REST(userId)·View(email)의 차이를 facade/ServiceResponse 경계에서 흡수해 **CartService의 모든 메서드는 첫 인자로 `long userId`만 받는다.**

- REST: `CartServiceResponse`가 `(long) authentication.getPrincipal()`로 userId 추출 후 CartService 호출(MemberServiceResponse.me 선례).
- View: `CartFacade`(impl in cart/service)가 `MemberDirectory.findUserIdByEmail(email)`로 변환 후 CartService 호출(SellerProductVariantFacadeImpl이 UserDirectory로 변환하던 선례와 동형, 단 포트는 member.spi).
- 효과: 소유권 검사·"없으면 생성"·atomic 증가 등 도메인 로직이 userId 단일 기준으로 한 곳(CartService)에 모인다. CartItem 소유권은 항상 `cartItem.cart.userId == userId`로 검사.

### 1.3 "없으면 생성"과 동시성 — 생성 경합/증가 경합 분리 처리(Task 핵심)
임시 장바구니에 **비관적 락을 쓰지 않는다.** 대신:

- **cart 생성 경합** (`uq_carts_user_id`): `findByUserId` 없으면 `insert` 시도 → `DataIntegrityViolationException`(동시 최초 생성) catch → `findByUserId` 재조회로 복구(요청 실패로 노출하지 않음). MemberService.signup의 unique 복구 톤과 동일.
- **cartItem 첫 동시 담기 경합** (`uq_cart_items_cart_variant`): 신규 insert 시도 → `DataIntegrityViolationException` catch → 기존 row 재조회 후 **atomic 증가 UPDATE**로 합산(아래 1.4)로 흡수.
- **재담기 증가 경합 / 합산 stock 초과**: read-modify-write 금지. 아래 1.4 atomic UPDATE 단일 수단으로 처리.

### 1.4 재담기 증가 = stock 검증 포함 atomic UPDATE (lost update + 합산 초과 동시 차단)
같은 variant 재담기는 조회 후 계산 후 저장(read-modify-write)을 **하지 않고**, WHERE 절에 합산 stock 조건을 포함한 원자 UPDATE로 처리한다.

```sql
UPDATE cart_items
SET quantity = quantity + :delta
WHERE cart_id = :cartId
  AND variant_id = :variantId
  AND quantity + :delta <= :stock
```

- `:stock`은 `ProductPurchaseCatalog`로 조회한 scalar 값을 파라미터로 넘긴다(cart가 product_variants를 직접 join하지 않음).
- **affected row == 0** → 합산이 stock 초과(또는 row 부재) → 증가 거부 → `400`(CartItemStockExceededException, message-only=400). 증가분 유실 없음.
- `addedAt`은 UPDATE 대상에서 제외 → 최초 담은 시점 유지(Task 요구).
- 비관적 락·별도 선행 SELECT 검증 금지 — 동시 재담기 각 요청이 `:delta<=stock`만 통과한 뒤 합산이 stock을 넘는 race를 WHERE 원자검증으로 차단.

### 1.5 stock 검증 기준을 연산별로 분리(Task 핵심)
- **신규 담기**: 요청 `quantity ≤ stock` (Service에서 ProductPurchaseCatalog stock과 비교).
- **재담기**: `기존 quantity + 추가 quantity ≤ stock` (1.4 atomic UPDATE WHERE 절로 원자 검증).
- **수량 변경(PATCH/폼)**: 변경 후 `quantity(절대값) ≤ stock`. last-write-wins, 락 없음.
- 모든 검증 실패는 **400 일괄**(stock 초과를 409로 분기하지 않음 — Task 명시).
- quantity는 1 이상(요청 quantity<1 → 400).
- variant 구매가능성: 상품 status==ON_SALE && variant.isActive (ProductPurchaseCatalog가 `purchasable` boolean으로 산출). 불가능 variant 담기/수량변경 → 400.

### 1.6 stock 수치 비노출 — cart 내부 판정용으로만 사용
ProductPurchaseCatalog가 cart에 전달하는 `stock`(정확한 수치)은 **CartService 내부 stockEnough 판정과 atomic UPDATE 파라미터로만** 쓴다. `CartItemResponse`·View 모델에는 **stock 수치를 노출하지 않고 `stockEnough` boolean으로만** 표현(공개 API 비노출 규칙, 013 정렬). `ownerId`·Entity·storageKey·로컬 절대경로도 응답/모델 미노출.

### 1.7 장바구니 조회 = 현재 product/variant 상태 반영, 자동삭제 금지
조회는 cart_items를 로드한 뒤 variantId 목록으로 `ProductPurchaseCatalog.getPurchasableVariants(ids)`를 **IN 배치 1회**(N+1 회피, 013 대표이미지 IN 배치와 동형) 호출해 현재 상태를 합성한다.

- `available` = 현재 purchasable(상품 ON_SALE && variant active). variant가 삭제/비공개/비활성화 → available=false.
- `stockEnough` = 현재 quantity ≤ 현재 stock. 재고 부족 → stockEnough=false.
- 상태가 unavailable이어도 **자동 삭제하지 않는다**(Task). `hasUnavailableItem` = items 중 available=false 또는 stockEnough=false가 1개 이상.
- `unitPrice` = 현재 variant 가격(가격 미저장, 조회 시점 현재가). `lineAmount` = unitPrice × quantity. `totalQuantity`/`totalAmount` 집계. **available=false 항목의 합계 포함 여부**: lineAmount는 항목별로 계산하되 totalAmount는 구매가능(available && stockEnough) 항목만 합산(주문 가능 금액 기준). — 구현 디테일은 backend-implementor 재량이되, View/REST 양측 동일 규칙 적용(6절 합의).
- ProductPurchaseCatalog 응답에 없는 variantId(=variant 물리 삭제됨): available=false, optionLabel/imageUrl/unitPrice는 안전 폴백(null/0). cart_item은 보존.

### 1.8 ProductPurchaseCatalog — 구매 단위 표시·검증 단일 포트
product가 소유·구현하는 published port. Entity 노출 금지, DTO(record)만 반환.

- `PurchasableVariant getPurchasableVariant(long variantId)` — 단건(담기/수량변경 검증용).
- `List<PurchasableVariant> getPurchasableVariants(Collection<Long> variantIds)` — IN 배치(조회 합성용).
- DTO 필드: `variantId, productId, productName, productStatus, optionLabel, imageUrl, price, active, stock, purchasable`.
  - `optionLabel`: variant의 optionValues를 "옵션값 / 옵션값" 형태로 합성(예: "빨강 / L"). product 내부에서 조립.
  - `imageUrl`: 상품 대표 이미지 URL(AssetUrlResolver.toUrl, 012 재사용). 없으면 null.
  - `productStatus`: enum 노출 회피 위해 String로 — purchasable에 이미 status 반영하므로 cart는 purchasable/active/stock만 실제 사용. status는 표시 보조용 String 권장.
  - `purchasable` = (productStatus==ON_SALE && active). cart는 이 boolean과 stock(수치)만 판정에 사용.
- 단건 조회 시 미존재 variantId 처리: cart 담기/수량변경 경로에서 미존재·비purchasable이면 cart가 400(VariantNotPurchasableException). 배치 조회는 존재하는 것만 반환(cart가 누락 variantId를 available=false로 처리).

**이유**: product가 "구매 단위 표시·검증" 책임을 소유하고 cart는 scalar/DTO만 받아 stock 노출·Entity 노출을 구조적으로 차단. 013 PublicProduct 스택과 분리된 "구매 판정 전용" 얇은 포트.

---

## 2. 구성 요소 (신규/수정 파일 — 정확한 패키지 경로)

> 작업 분담 원칙: 2.1 backend-implementor = 도메인/REST/SPI/Security/예외/백엔드 테스트. 2.2 view-implementor = web/cart ViewController·Form, web/product 담기폼 연결, templates, View 렌더링 테스트. 두 영역은 6절 인터페이스 접점(facade 시그니처·모델 키·폼 필드·경로)으로 정합한다.

### 2.1 backend-implementor 담당 범위

#### 신규 — cart/domain (Entity)
- cart/domain/Cart.java — @Entity @Table(name="carts"). 필드: id, Long userId(스칼라, member Entity 직접참조 금지), created_at/updated_at(트리거 보유 → BaseEntity 상속 또는 매핑). 정적 팩토리 create(long userId). Setter 금지(ProductVariant 선례).
- cart/domain/CartItem.java — @Entity @Table(name="cart_items"). 필드: id, @ManyToOne(LAZY) Cart cart, Long variantId(스칼라, product variant Entity 직접참조 금지), int quantity, Instant addedAt(DB default now() — created_at류, insertable=false 또는 생성 시 세팅). updated_at 없음 → BaseEntity 미상속. 정적 팩토리 create(Cart cart, long variantId, int quantity), 수량 절대값 변경 의도 메서드 changeQuantity(int quantity)(수량변경 last-write-wins용; 재담기 증가는 Entity 메서드가 아니라 atomic UPDATE 쿼리로 처리).

#### 신규 — cart/repository
- cart/repository/CartRepository.java — JpaRepository<Cart, Long>. Optional<Cart> findByUserId(long userId).
- cart/repository/CartItemRepository.java — JpaRepository<CartItem, Long>.
  - List<CartItem> findByCartId(long cartId) (조회용; cart 단건 로드 후 항목 로드).
  - Optional<CartItem> findByCartIdAndVariantId(long cartId, long variantId) (재담기/생성 경합 재조회용).
  - @Modifying @Query atomic 증가 UPDATE (1.4): int increaseQuantityWithinStock(@Param cartId, @Param variantId, @Param delta, @Param stock) — JPQL: update CartItem ci set ci.quantity = ci.quantity + :delta where ci.cart.id = :cartId and ci.variantId = :variantId and (ci.quantity + :delta) <= :stock. 반환 affected row(int). 0이면 stock 초과 거부. (addedAt 미변경.)
  - 소유권 검사용 별도 메서드 불필요 — Service가 findById 후 cartItem.getCart().getUserId()==userId 비교(타인/미존재 모두 404 존재은닉으로 통일). cart_item.cart는 LAZY지만 동일 트랜잭션 내 getUserId 접근 가능.

#### 신규 — cart/dto (REST/응답 DTO + 요청 DTO)
- cart/dto/CartResponse.java — record(long cartId, List<CartItemResponse> items, int totalQuantity, BigDecimal totalAmount, boolean hasUnavailableItem).
- cart/dto/CartItemResponse.java — record(long cartItemId, long variantId, long productId, String productName, String optionLabel, String imageUrl, BigDecimal unitPrice, int quantity, BigDecimal lineAmount, boolean available, boolean stockEnough). stock 수치·ownerId·Entity·storageKey 미포함.
- cart/dto/CartItemAddRequest.java — record(@NotNull Long variantId, @Min(1) int quantity)(REST 본문, jakarta validation). 폼 바인딩은 web/cart Form 별도(2.2).
- cart/dto/CartItemQuantityUpdateRequest.java — record(@Min(1) int quantity).

#### 신규 — cart/service
- cart/service/CartService.java — @Service @Transactional(쓰기 기본; 조회 메서드 @Transactional(readOnly=true)). 모든 메서드 첫 인자 long userId. 도메인 로직 단일 소유:
  - Cart getOrCreateCart(long userId) — findByUserId 없으면 insert, DataIntegrityViolationException catch 후 재조회(생성 경합 복구, 1.3).
  - CartView getCart(long userId) — getOrCreateCart 후 항목 로드 → variantId 목록으로 ProductPurchaseCatalog.getPurchasableVariants(ids) IN 배치 합성 → available/stockEnough/unitPrice/lineAmount/total 계산한 내부 집계 결과(CartView aggregate, Entity 미노출) 반환.
  - void addItem(long userId, long variantId, int quantity) — quantity<1 → 400. ProductPurchaseCatalog.getPurchasableVariant(variantId)로 purchasable·stock 확인(미존재/비purchasable → 400). cart 확보. 기존 항목 있으면 atomic 증가 UPDATE(affected 0 → 400), 없으면 신규 insert → unique 경합 시 catch 후 재조회+atomic 증가. 신규 담기 stock 검증=요청 quantity≤stock.
  - void updateItemQuantity(long userId, long cartItemId, int quantity) — quantity<1 → 400. cartItem findById+소유권(타인/미존재 → 404). purchasable·변경후 절대값 stock 검증(변경후 quantity>stock → 400). changeQuantity 절대값 set(last-write-wins, 락 없음).
  - void removeItem(long userId, long cartItemId) — 소유권 검사(타인/미존재 → 404) 후 delete.
  - 재고 차감 호출 없음(inventory/variant stock 변경 절대 금지 — 검증만).
- cart/service/CartFacadeImpl.java — cart.spi.CartFacade 구현(package-private class implements CartFacade, PublicProductFacadeImpl 선례). MemberDirectory로 email→userId 변환 후 CartService 위임 + 내부 CartView→CartResponse/CartItemResponse DTO 변환. View facade는 cart.spi에 인터페이스만, 구현은 cart/service.
- cart/service/CartServiceResponse.java — @Service. REST 전용. (long) authentication.getPrincipal()로 userId 추출 후 CartService 위임 + DTO 변환. 비즈니스 로직 없음(MemberServiceResponse 선례). 메서드: getCart(auth)→CartResponse, addItem(auth, CartItemAddRequest), updateQuantity(auth, cartItemId, CartItemQuantityUpdateRequest), removeItem(auth, cartItemId).
  - 참고: CartView→DTO 변환 로직은 CartServiceResponse·CartFacadeImpl 양쪽에서 필요 → 공용 매퍼(cart/service/CartDtoMapper, package-private, 013 PublicProductDtoMapper 선례)로 추출 권장.

#### 신규 — cart/spi
- cart/spi/package-info.java — @org.springframework.modulith.NamedInterface("spi")(member.spi/package-info 선례).
- cart/spi/CartFacade.java — published port. 시그니처 6절. View가 도메인 Entity/enum을 참조하지 않도록 DTO(cart.dto.CartResponse)만 노출. email을 인자로 받아 내부 userId 변환(REST는 이 facade 미사용 — ServiceResponse 경유).

#### 신규 — cart/controller
- cart/controller/CartRestController.java — @RestController @RequestMapping("/api/v1/cart"). 비즈니스 로직 없음, CartServiceResponse 위임.
  - GET /api/v1/cart → CartResponse (200).
  - POST /api/v1/cart/items @Valid @RequestBody CartItemAddRequest → 200/201 + CartResponse. 검증 실패 400.
  - PATCH /api/v1/cart/items/{cartItemId} @Valid @RequestBody CartItemQuantityUpdateRequest → CartResponse. 타인/미존재 404.
  - DELETE /api/v1/cart/items/{cartItemId} → 200/204. 타인/미존재 404.
  - 모든 메서드 Authentication 주입(principal=userId).

#### 신규 — product/spi (cart→product 경계)
- product/spi/ProductPurchaseCatalog.java — published port(@NamedInterface "spi"). 1.8 시그니처. 내부 record PurchasableVariant(variantId, productId, productName, productStatus(String), optionLabel, imageUrl, price, active, stock, purchasable). Entity 노출 금지.

#### 신규 — product/service (ProductPurchaseCatalog 구현)
- product/service/ProductPurchaseCatalogImpl.java — @Service @Transactional(readOnly=true) package-private implements ProductPurchaseCatalog. product 내부 repository(ProductVariantRepository + 이미지/옵션 조회)로 variant·product·optionLabel·대표이미지(AssetUrlResolver) 조립 → PurchasableVariant 변환. purchasable=(status==ON_SALE && variant.isActive). 단건/IN 배치 두 메서드.
  - variant 단건/IN 로딩 신규 repository 메서드 필요(아래).

#### 수정 — product/repository
- product/repository/ProductVariantRepository.java — cart 구매조회용 메서드 추가:
  - Optional<ProductVariant> findWithProductById(long variantId) 또는 @EntityGraph 단건 로드(product LAZY 회피 — productName/status 접근).
  - List<ProductVariant> findByIdIn(Collection<Long> ids) (+ @EntityGraph(optionValues, product) — optionLabel·status 조립, IN 배치).
  - optionLabel 조립에 optionValues 필요 → @EntityGraph attributePaths={"product","optionValues"} 권장.
- (대표이미지는 기존 ProductImageRepository.findByProductIdInAndIsPrimaryTrue/findByProductIdOrderBy... 재사용 — 신규 불요. 신규 인덱스·migration 추가 금지.)

#### 신규 — member/spi (cart→member 경계)
- member/spi/MemberDirectory.java — published port(member.spi 패키지는 이미 @NamedInterface). long findUserIdByEmail(String email). product.spi.UserDirectory와 별개(member 소유). javadoc에 "cart의 View facade가 form-login email→userId 해석용, member Entity 미노출(scalar userId만)" 명시.

#### 신규 — member/service (MemberDirectory 구현)
- member/service/MemberDirectoryImpl.java — @Service(또는 @Component) package-private implements MemberDirectory. MemberService.getByEmail(email).getId() 위임, MemberNotFoundException→IllegalStateException(인증 세션-디렉터리 불일치, MemberUserDirectoryAdapter 선례 톤). member Entity 미반환.

#### 신규 — common/exception (필요 시 최소 추가)
- common/exception/CartItemNotFoundException.java — extends BusinessException, super(message, HttpStatus.NOT_FOUND). 타인/미존재 cartItem 통일 404(ProductAccessDeniedException 선례 — 존재 은닉). 소유권 위반과 미존재를 동일 예외/동일 메시지로 던져 존재 구분 불가하게.
- common/exception/VariantNotPurchasableException.java — extends BusinessException(기본 400). 비purchasable/미존재 variant 담기·수량변경.
- common/exception/CartItemStockExceededException.java — extends BusinessException(400). 신규/재담기/수량변경 stock 초과 일괄 400.
- (quantity<1은 @Min REST 검증 400 + Service 방어 BusinessException 400. 신규 예외 최소화 — 위 3종 외 추가 자제.)

#### 수정 — security
- security/SecurityConfig.java:
  - REST 체인: anyRequest 앞에 requestMatchers("/api/v1/cart/**").hasRole("CONSUMER") 추가(SELLER/ADMIN은 RoleHierarchy 함의). admin/seller 매처와 겹침 없음.
  - View 체인: anyRequest 앞에 requestMatchers("/cart", "/cart/**").hasRole("CONSUMER") 추가. 미인증은 formLogin이 302→/login.

#### 신규 — 테스트 (backend) → 5절 매핑
- cart/service/CartServiceTest.java (단위, Mockito: CartRepository/CartItemRepository/ProductPurchaseCatalog mock)
- cart/service/CartServiceResponseTest.java (단위: principal userId 추출·DTO 변환·stock/ownerId 미노출)
- cart/service/CartFacadeImplTest.java (단위: MemberDirectory email→userId 위임·DTO 변환)
- product/service/ProductPurchaseCatalogImplTest.java (단위: purchasable 판정·DRAFT/HIDDEN/SOLD_OUT 불가·비활성 불가·재고0 불가·Entity 미노출)
- member/service/MemberDirectoryImplTest.java (단위: email→userId·Entity 미노출·미존재 IllegalStateException)
- cart/controller/CartRestControllerSecurityTest.java (@SpringBootTest+MockMvc, @MockitoBean CartServiceResponse: 401/200/400/404·role 매핑·비노출 필드)

#### 수정/확인 — 구조 테스트
- WebModuleStructureTest.java(기존) — 신규 web/cart도 자동 대상(cart.* 패키지 이미 규칙 포함). 변경 불요. 단, cart→product/member 내부참조 금지 + cart→UserDirectory 미참조 규칙은 신규 추가:
  - 신규 CartModuleStructureTest.java(또는 기존에 규칙 추가, ArchUnit plain JUnit): (a) com.shop.shop.cart..가 product.domain/repository/service·member.domain/repository/service 미참조, (b) cart가 product.spi/member.spi(+scalar)만 사용, (c) cart가 com.shop.shop.product.spi.UserDirectory 미참조(member.spi.MemberDirectory만).
- ModularityTests.verify()(기존) — 신규 spi/controller/service 경계 위반 없이 통과 확인.

### 2.2 view-implementor 담당 범위

#### 신규 — web/cart
- web/cart/CartViewController.java — @Controller @RequestMapping. CartFacade(cart.spi) + CurrentActorResolver만 의존(도메인 내부 미참조).
  - GET /cart → CartFacade.getCart(actor.email()) → 모델 cart(CartResponse) → view cart/index.
  - POST /cart/items (@ModelAttribute CartItemAddForm + BindingResult + RedirectAttributes) → 검증 실패 시 flashError + redirect(원래 화면 또는 /cart); 성공 시 CartFacade.addItem(email, variantId, quantity) → redirect:/cart(PRG).
  - POST /cart/items/{cartItemId} (수량변경 Form) → CartFacade.updateQuantity(email, cartItemId, quantity) → redirect:/cart. 실패 flashError.
  - POST /cart/items/{cartItemId}/delete → CartFacade.removeItem(email, cartItemId) → redirect:/cart.
  - 미인증은 SecurityConfig View 체인이 302→/login(컨트롤러 도달 전). 404(타인/미존재)는 facade→BusinessException→ViewExceptionHandler error/error. flashError는 RedirectAttributes.addFlashAttribute("flashError", ...)로 messages.html 표시.
- web/cart/CartItemAddForm.java — 폼 백킹(Long variantId, int quantity). 상세화면 담기 폼.
- web/cart/CartItemQuantityForm.java — 폼 백킹(int quantity). 수량변경 폼.

#### 신규 — templates
- templates/cart/index.html — layout/base + fragments(header/nav/footer/messages). 모델 cart(CartResponse). 항목 목록(cart.items): 상품명, 대표 이미지(imageUrl, 없으면 placeholder), 옵션 라벨(optionLabel), 단가(unitPrice), 수량, 합계(lineAmount). unavailable/재고부족 표시(available=false/stockEnough=false 배지). 수량 변경 폼(action POST /cart/items/{cartItemId}, 필드 quantity, CSRF 자동). 삭제 폼(action POST /cart/items/{cartItemId}/delete, CSRF). totalQuantity/totalAmount/hasUnavailableItem 표시. 주문하기 버튼은 비활성/준비중(후속 Task) — 동작 미구현. stock 수치·ownerId 미표시.

#### 수정 — templates
- templates/product/detail.html — 현재 "장바구니 담기 (준비 중)" 비활성 버튼(라인 136~147)을 실제 담기 폼으로 교체: variant 선택(라디오/셀렉트, variantId) + 수량 입력 → POST /cart/items(필드 variantId, quantity, CSRF 자동). available=false variant는 선택 불가/비활성 표시. 비인증 사용자는 폼 제출이 SecurityConfig로 막히므로(POST /cart/items는 ROLE_CONSUMER) — 비인증일 때는 폼 대신 "로그인 후 담기 가능" + /login 링크 노출(sec:authorize). soldOut/variants empty면 폼 숨김.
- templates/fragments/nav.html — 장바구니 링크 /cart 추가. CONSUMER 이상만 노출(sec:authorize="hasRole('CONSUMER')") 권장. active 키 예: cart.

#### 신규 — 테스트 (view) → 5절 매핑
- view/CartViewRenderingTest.java (@SpringBootTest+MockMvc, CartFacade @MockitoBean): GET /cart 인증 렌더(@WithMockUser ROLE_CONSUMER)·비인증 302→/login·항목 목록·수량/삭제 폼 CSRF·unavailable 표시·총합·주문버튼 비활성.
- view/ProductDetailAddToCartRenderingTest.java (또는 013 detail 렌더 테스트 보강, PublicProductFacade @MockitoBean): 상세에 담기 폼(variantId/quantity/action) 렌더·비인증 시 로그인 안내.
- view/NavRenderingTest(기존 보강) 또는 신규: nav에 /cart 링크(CONSUMER 노출).
- web/cart/CartViewControllerTest.java (컨트롤러 단위, CartFacade+CurrentActorResolver mock): 모델 키·view name·redirect·flashError·email 전달.

---

## 3. 데이터 흐름

### 3.1 담기 — REST (POST /api/v1/cart/items)
1. Security REST 체인 /api/v1/cart/** hasRole(CONSUMER). 비인증 → 401 JSON(RestAuthenticationEntryPoint). 권한없음 → 403.
2. JWT 필터로 principal=userId 설정. Controller → CartServiceResponse.addItem(auth, request).
3. ServiceResponse: userId=(long)auth.getPrincipal() → CartService.addItem(userId, variantId, quantity).
4. CartService: quantity<1 → 400. ProductPurchaseCatalog.getPurchasableVariant(variantId) → purchasable=false/미존재 → 400(VariantNotPurchasable). 신규 담기 quantity>stock → 400.
5. getOrCreateCart(userId)(생성 경합 시 unique catch+재조회). 기존 항목 존재 → increaseQuantityWithinStock(cartId, variantId, delta=quantity, stock); affected 0 → 400(StockExceeded). 미존재 → insert; DataIntegrityViolationException(첫 동시 담기) catch → 재조회 후 atomic 증가(affected 0 → 400).
6. ServiceResponse가 갱신 후 CartResponse 조립(또는 200) 반환. stock/ownerId 미노출.

### 3.2 담기 — View (POST /cart/items, 상세화면 폼)
1. Security View 체인 /cart/** hasRole(CONSUMER). 비인증 → 302/login(상세화면 폼은 비인증에 로그인 안내 노출).
2. CartViewController.addItem(CartItemAddForm, BindingResult, auth, RedirectAttributes). 검증 실패 → flashError + redirect(상세 또는 /cart).
3. CurrentActorResolver.resolve(auth).email() → CartFacade.addItem(email, variantId, quantity).
4. CartFacadeImpl: MemberDirectory.findUserIdByEmail(email) → CartService.addItem(userId, ...)(3.1의 4~5 동일 도메인 로직).
5. 성공 → redirect:/cart(PRG). 실패(400/404) → BusinessException → ViewExceptionHandler error/error 또는 flashError 후 redirect(컨트롤러가 try/catch로 flashError 처리 시).

### 3.3 조회 — REST (GET /api/v1/cart) / View (GET /cart)
1. (REST) auth→userId / (View) auth→email→userId(facade).
2. CartService.getCart(userId): getOrCreateCart → findByCartId 항목 로드 → variantId 목록 → ProductPurchaseCatalog.getPurchasableVariants(ids) IN 배치 1회 → Map<variantId, PurchasableVariant>.
3. 항목별 available=purchasable, stockEnough=(quantity≤stock), unitPrice=현재 price, lineAmount=unitPrice×quantity. 누락 variantId(삭제됨)→available=false 폴백. total 집계(구매가능 항목 기준), hasUnavailableItem.
4. (REST) CartResponse 200 JSON / (View) 모델 cart → cart/index 렌더. 자동삭제 없음.

### 3.4 수량 변경 — REST (PATCH /api/v1/cart/items/{id}) / View (POST /cart/items/{id})
1. auth→userId(REST) / email→userId(View facade).
2. CartService.updateItemQuantity(userId, cartItemId, quantity): quantity<1 → 400. cartItem findById 없거나 cart.userId!=userId → 404(CartItemNotFound, 존재 은닉). ProductPurchaseCatalog.getPurchasableVariant로 purchasable·stock 확인; 변경후 절대값 quantity>stock → 400. changeQuantity(quantity) 절대값 set(락 없음, last-write-wins).
3. (REST) CartResponse / (View) redirect:/cart(실패 flashError 또는 error/error).

### 3.5 삭제 — REST (DELETE /api/v1/cart/items/{id}) / View (POST /cart/items/{id}/delete)
1. auth→userId.
2. CartService.removeItem(userId, cartItemId): findById+소유권(타인/미존재 → 404 존재은닉) → delete.
3. (REST) 204/200 / (View) redirect:/cart.

### 3.6 principal 이중경로 통일 지점(명확화)
- REST: CartServiceResponse에서 (long)auth.getPrincipal()로 통일.
- View: CartFacadeImpl에서 MemberDirectory.findUserIdByEmail(email)로 통일.
- 통일 이후 CartService는 userId만 다룬다(소유권·도메인 로직 단일 기준). product 경계는 ProductPurchaseCatalog(scalar/DTO), member 경계는 MemberDirectory(scalar)로만.

---

## 4. 예외 처리 전략 (error-response-rule 준수)

| 상황 | 발생 지점 | 예외 | REST 매핑 | View 매핑 |
|---|---|---|---|---|
| 미인증 REST | Security REST 체인 | — | 401 JSON(RestAuthenticationEntryPoint) | — |
| 미인증 View | Security View 체인 | — | — | 302 → /login |
| 권한 부족(ROLE 없는 인증) | Security | — | 403 JSON(RestAccessDeniedHandler) | 403 |
| quantity<1 | @Min 검증/CartService | MethodArgumentNotValid / BusinessException(400) | 400 ErrorResponse | flashError/error 뷰 |
| 비purchasable·미존재 variant 담기/변경 | CartService | VariantNotPurchasableException(400) | 400 | flashError/error 뷰 |
| stock 초과(신규/재담기/수량변경) | CartService/atomic UPDATE affected 0 | CartItemStockExceededException(400) | 400(409 아님) | flashError/error 뷰 |
| 타인/미존재 cartItem(변경·삭제) | CartService 소유권 | CartItemNotFoundException(404) | 404 존재 은닉(403 아님) | error 뷰(404) |
| 인증 세션-디렉터리 불일치 | MemberDirectoryImpl | IllegalStateException(시스템 불변식) | 500(운영 이상) | 500 |
| 동시 생성/담기 경합 | CartService(unique catch) | — | 정상 복구(실패 노출 안 함) | 정상 복구 |

핵심 규칙:
- 타인 + 미존재 cartItem = 동일 예외·동일 메시지 404(존재 구분 불가 — 존재 은닉, ProductAccessDeniedException 선례 정렬, 403 미사용).
- 모든 검증/stock 초과 = 400 일괄(409 분기 금지 — Task 명시).
- REST는 JSON ErrorResponse(RestExceptionHandler), View는 error/error 뷰(ViewExceptionHandler) 또는 flashError redirect. 핸들러 분리 기존 구조 그대로.
- 응답/모델에 stock 수치·ownerId·storageKey·Entity·스택트레이스·SQL 미노출.
- 신규 예외 3종(CartItemNotFound 404, VariantNotPurchasable 400, CartItemStockExceeded 400)만 추가, 나머지는 기존 재사용/@Min.

---

## 5. 검증 방법 (테스트 클래스 매핑 + 자동/수동 구분)

> 테스트 프로파일 제약(0절): @DataJpaTest 불가 → repository 실 SQL(atomic UPDATE WHERE 합산, unique 경합 복구, added_at 보존, IN 배치)·실 동시성은 자동검증 불가 → docker-compose 수동 확인. Service/REST/View는 Mockito·@MockitoBean으로 커버.

### 단위(자동) — CartServiceTest (Mockito)
- 장바구니 최초 조회 시 생성(getOrCreateCart: findByUserId empty → save 호출).
- 담기 성공(신규 insert 호출).
- 같은 variant 재담기 시 increaseQuantityWithinStock(atomic UPDATE) 호출 — read-modify-write 아님(quantity getter 후 setter 저장 경로 미사용을 mock 상호작용으로 단언).
- quantity 0/음수 → 400.
- 비purchasable variant(purchasable=false) 담기 → 400.
- 신규 담기 요청 quantity>stock → 400.
- 재담기 atomic UPDATE affected 0(=합산 stock 초과) → 400(증가분 유실 없음 — UPDATE 1회만, 사후 보정 저장 없음을 단언).
- 수량 변경 성공(changeQuantity 절대값).
- 수량 변경 시 비관적 락 미사용(findById는 일반 조회, lock 메서드 미호출).
- 수량 변경 절대값 stock 초과 → 400.
- 항목 삭제 성공(소유 cartItem delete).
- 타인 cartItem 수량변경/삭제 → 404(CartItemNotFound).
- 조회 시 ProductPurchaseCatalog.getPurchasableVariants IN 배치 1회 호출·available/stockEnough/unitPrice/lineAmount/total 조립.
- unavailable item 표시(purchasable=false → available=false; quantity>stock → stockEnough=false; hasUnavailableItem).
- totalQuantity/totalAmount 계산.
- 재고 차감 호출 없음(variant/inventory stock 변경 mock 미호출).
- 생성 경합 복구(save가 DataIntegrityViolation throw → findByUserId 재조회 폴백).
- 첫 동시 담기 경합 복구(insert DataIntegrityViolation → findByCartIdAndVariantId 재조회 + atomic 증가).

### 단위(자동) — CartServiceResponseTest / CartFacadeImplTest
- ServiceResponse: (long)auth.getPrincipal() userId 추출·CartService 위임·CartResponse 변환·stock/ownerId/Entity 미노출.
- FacadeImpl: MemberDirectory.findUserIdByEmail(email) 위임·CartService 호출·DTO 변환.

### 단위(자동) — ProductPurchaseCatalogImplTest / MemberDirectoryImplTest
- purchasable 조회 성공 / DRAFT·HIDDEN·SOLD_OUT 상품 variant 불가 / 비활성 variant 불가 / 재고0 variant(purchasable엔 active 반영, stock=0은 cart측 stockEnough/신규담기 quantity>0>stock=0 → 400) / Entity 미노출(record만).
- MemberDirectory: email→userId·member Entity 미노출(scalar)·미존재 IllegalStateException.

### REST/Security(자동) — CartRestControllerSecurityTest (@SpringBootTest, MockMvc, @MockitoBean CartServiceResponse)
- GET /api/v1/cart: CONSUMER 200, 비인증 401, ROLE 없는 인증 403, SELLER/ADMIN 200(RoleHierarchy 함의).
- POST /api/v1/cart/items: 성공 200/201, 검증 실패(quantity<1/variantId null) 400.
- PATCH /api/v1/cart/items/{id}: 성공, 타인/미존재 404(존재 은닉).
- DELETE /api/v1/cart/items/{id}: 성공, 타인/미존재 404.
- 응답 본문에 stock 수치·ownerId·product/variant Entity·로컬 절대경로 미포함(jsonPath doesNotExist).

### View(자동) — CartViewRenderingTest / ProductDetailAddToCartRenderingTest / Nav (@MockitoBean facade)
- GET /cart: @WithMockUser(CONSUMER) 렌더, 비인증 302→/login.
- 항목 목록·상품명·이미지·옵션라벨·단가·수량·합계 렌더.
- 수량 변경 폼/삭제 폼 CSRF 토큰 포함(POST 폼).
- unavailable item 표시.
- 주문하기 버튼 비활성(준비중).
- 상세화면 담기 폼(variantId/quantity/action POST /cart/items) 렌더, 비인증 시 로그인 안내.
- 담기 성공 redirect:/cart, 실패 시 flashError 표시.
- nav에 /cart 링크(CONSUMER).

### 구조(자동) — WebModuleStructureTest / CartModuleStructureTest / ModularityTests
- web.cart가 cart.domain/repository/service 미참조(기존 규칙 cart.* 포함).
- cart가 product.domain/repository/service·member.domain/repository/service 미참조(신규 규칙).
- cart가 product.spi/member.spi(+scalar)만 사용.
- cart가 product.spi.UserDirectory 미참조(member.spi.MemberDirectory만 — 신규 규칙).
- ModularityTests.verify() 통과.

### 실행 / docker-compose 수동 확인(자동 불가 항목)
- ./gradlew test 전체 통과.
- docker-compose 수동 확인(테스트 프로파일 JPA 제외로 자동 불가):
  1. 재담기 atomic 증가 UPDATE가 실 PostgreSQL에서 quantity = quantity + delta로 동작하고 addedAt이 보존되는지.
  2. atomic UPDATE WHERE 합산 stock(quantity + delta <= stock) 검증 — 합산 초과 시 affected row 0 → 400, 증가분 유실 없음(동시 재담기 2요청 시 한쪽만 반영/합산이 stock 이내).
  3. cart 최초 생성 unique 경합(uq_carts_user_id) — 동시 최초 담기 시 DataIntegrityViolation 후 재조회 복구로 단일 cart.
  4. 같은 variant 동시 담기 unique 경합(uq_cart_items_cart_variant) — 재조회 후 atomic 증가로 합산(중복 row 없음).
  5. 수량 변경 last-write-wins(동시 PATCH 시 마지막 처리 quantity가 최종, 락/대기 없음).
  6. IN 배치 조회(getPurchasableVariants)·소유권 cart_item.cart.userId 비교가 실 DB에서 정상.
  7. variant stock/inventory가 담기·수량변경으로 차감되지 않음(재고 불변).
- 확인/미확인 항목을 작업 완료 보고에 남긴다(013 정책 동일).

---

## 6. 양 영역 인터페이스 접점 (어긋남 방지)

### CartFacade (cart.spi) 시그니처(안) — View 전용

    CartResponse getCart(String email);
    void addItem(String email, long variantId, int quantity);
    void updateQuantity(String email, long cartItemId, int quantity);
    void removeItem(String email, long cartItemId);

- email은 form-login principal(auth.getName()). 내부에서 MemberDirectory로 userId 변환. 반환은 cart.dto.CartResponse(View가 Entity/enum 미참조).
- REST는 CartFacade 미사용 — CartServiceResponse(auth) 경유.

### ProductPurchaseCatalog (product.spi) 시그니처(안) — cart 전용

    PurchasableVariant getPurchasableVariant(long variantId);
    List<PurchasableVariant> getPurchasableVariants(Collection<Long> variantIds);
    record PurchasableVariant(long variantId, long productId, String productName, String productStatus,
                              String optionLabel, String imageUrl, BigDecimal price,
                              boolean active, int stock, boolean purchasable) {}

- purchasable=(productStatus==ON_SALE && active). cart는 purchasable/stock(판정)·price/productName/optionLabel/imageUrl(표시)만 사용. stock은 cart 내부 판정·atomic UPDATE 파라미터 전용, 외부 미노출.

### MemberDirectory (member.spi) 시그니처(안)

    long findUserIdByEmail(String email);   // product.spi.UserDirectory와 별개(member 소유)

### REST 응답/요청 DTO (cart.dto)
- CartResponse(cartId, items, totalQuantity, totalAmount, hasUnavailableItem)
- CartItemResponse(cartItemId, variantId, productId, productName, optionLabel, imageUrl, unitPrice, quantity, lineAmount, available, stockEnough) — stock 수치/ownerId 미포함
- CartItemAddRequest(variantId, quantity) / CartItemQuantityUpdateRequest(quantity)

### 모델 키 / 폼 (View — Task Backend-View Contract 준수)
- 장바구니: 모델 키 cart(CartResponse), 항목 cart.items → view cart/index
- 담기 폼(상세화면): action POST /cart/items, 필드 variantId, quantity
- 수량 변경 폼: action POST /cart/items/{cartItemId}, 필드 quantity
- 삭제 폼: action POST /cart/items/{cartItemId}/delete
- 성공 redirect: /cart(PRG). 실패: flashError(flashError 키, messages.html) 후 redirect 또는 error/error
- nav 링크: /cart(CONSUMER)

### 경로 / 권한
- REST: GET /api/v1/cart, POST /api/v1/cart/items, PATCH /api/v1/cart/items/{cartItemId}, DELETE /api/v1/cart/items/{cartItemId} — 전부 hasRole("CONSUMER")
- View: GET /cart, POST /cart/items, POST /cart/items/{cartItemId}, POST /cart/items/{cartItemId}/delete — hasRole("CONSUMER")

---

## 7. 트레이드오프

- atomic UPDATE WHERE 합산 검증(read-modify-write·비관락 금지): Task 핵심. lost update + 합산 stock 초과를 단일 쿼리로 동시 차단. 비용은 affected row 0 → 400 변환 로직과, 실 동작이 테스트 프로파일에서 자동검증 불가(docker-compose 수동). 정확성(동시 재담기 안전) 이득이 크다.
- 생성 경합 = unique + DataIntegrityViolation 복구, 증가 경합 = atomic UPDATE 분리: row 부재 구간은 락으로 직렬화 불가하므로 unique 제약에 위임하고 복구. 증가 구간은 원자 UPDATE. 두 메커니즘 분리로 비관적 락 없이 정합성 확보(임시 데이터 특성에 부합).
- 수량 변경 last-write-wins(락 없음): 임시 장바구니라 동시 수정 충돌을 허용. 재고 정합성은 주문 단계에서 보장(Task). 락 비용·교착 위험 제거.
- 신규 published port 2종(ProductPurchaseCatalog, MemberDirectory) + UserDirectory 미재사용: 포트 수가 늘지만 소유권(member가 자기 디렉터리 소유)·책임 분리(product가 구매 판정 소유)가 명확해지고 cart→내부참조를 구조 테스트로 차단. UserDirectory는 product 소유라 cart가 끌어쓰면 모듈 소유 경계가 흐려짐 → 분리.
- stock 수치 비노출(stockEnough boolean만): 정확 재고 노출 사고를 구조적으로 차단(013 정렬). cart가 stock 수치를 내부 판정에만 쓰고 DTO에서 제거.
- CartView aggregate(Entity) → DTO 변환을 ServiceResponse·FacadeImpl 양쪽: 중복 변환 위험은 공용 CartDtoMapper 추출로 완화(013 PublicProductDtoMapper 선례).
- 테스트 프로파일 JPA 제외 → 동시성/실 SQL 자동검증 불가: Service/REST/View는 Mockito·@MockitoBean으로 충분히 커버하나, 동시성·atomic UPDATE·unique 복구의 실 동작은 docker-compose 수동 확인에 의존(프로젝트 기존 제약, 010/012/013 동일 정책).
- 주문/결제/재고차감/쿠폰/비회원/Redis 미구현: Task Constraint 준수. 주문하기 버튼은 비활성/준비중으로만 둔다.

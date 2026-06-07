# 015. shop-core 장바구니 기반 주문 생성 + 주문 조회 화면 — 구현 계획(plan)

> Task SSOT: docs/tasks/backend/015-backend-shop-core-order-creation-from-cart-with-view.md
> Revision SSOT: docs/plans/revisions/backend/015-backend-shop-core-order-creation-from-cart-with-view-revision-1.md (비관적 락 + 보정 노트)
> 본 문서는 구현 위임용 plan이다. 코드 작성은 backend-implementor / view-implementor가 수행한다.
> 진행: backend-implementor → view-implementor → reviewer → fixer 사이클(최대 3회).
> 선례 코드(009 의존역전 / 010 variant 쓰기·소유권 / 012 facade+impl / 013 공개 카탈로그 스택 / 014 cart 스택)의 네이밍·레이어·예외·테스트 패턴을 그대로 따른다.

---

## 0. 사전 확정 사실 (실제 코드 점검 완료 — 가정 아님)

- **orders / order_items / order_item_option_values / product_variants 스키마는 V1에 이미 존재 — 신규 migration 불필요(확정).** `V1__init_schema.sql`:
  - `orders`(line 242~265): `id`, `user_id`(FK users, ON DELETE RESTRICT), `order_number`, `status varchar(20) CHECK IN ('pending','paid','preparing','shipping','delivered','cancelled','refunded')`, `items_amount`/`discount_amount`(default 0)/`shipping_fee`(default 0)/`final_amount` numeric(12,2) CHECK ≥0, 배송지 스냅샷 `ship_recipient/ship_phone/ship_postcode/ship_address1/ship_address2`(전부 nullable text), `created_at`/`updated_at`, `CONSTRAINT uq_orders_order_number UNIQUE(order_number)`, `trg_orders_set_updated_at` 트리거 → Order Entity는 BaseEntity 상속 또는 created/updated 매핑 가능. **status는 DB가 lowercase 문자열**(enum이 아닌 varchar+CHECK)이므로 Order Entity는 lowercase 문자열을 저장한다.
  - `order_items`(line 278~291): `id`, `order_id`(FK orders, CASCADE), `variant_id`(FK product_variants, **ON DELETE SET NULL → nullable**), `product_name`(NOT NULL), `option_label`(nullable), `unit_price`/`quantity`(CHECK>0)/`line_amount`(CHECK≥0). updated_at 없음 → BaseEntity 미상속.
  - `order_item_option_values`(line 299~306): `id`, `order_item_id`(FK CASCADE), `option_name`(NOT NULL), `option_value`(NOT NULL), `sort_order`(default 0).
  - `product_variants`(line 169~182): `id`, `product_id`, `sku`, `price numeric(12,2)`, `stock int CHECK(stock>=0)`, `is_active boolean default true`, `created_at`. **신규 인덱스·migration·트리거 추가 금지(Constraint).**
- **order 모듈은 현재 골격(package-info만)뿐이다.** `order/{controller,domain,dto,repository,service,event,messaging}` 전부 package-info만 존재. **`order/spi` 패키지 없음 → 신규 생성 필요**(@NamedInterface("spi")).
- **inventory 모듈은 현재 골격(package-info만)뿐이다.** `inventory/{controller,domain,dto,repository,service,event,messaging}` package-info만 존재. **`inventory/spi` 패키지 없음 → 신규 생성 필요.**
- **cart 모듈(014)은 완전히 구현됨.** `CartService`(getOrCreateCart/getCart/addItem/updateItemQuantity/removeItem, 모든 메서드 첫 인자 `long userId`), `CartFacade`(View 전용 email 인자), `CartFacadeImpl`, `CartServiceResponse`, `CartDtoMapper`, `CartRestController(/api/v1/cart)`, `Cart`/`CartItem` Entity, `CartRepository.findByUserId(long)`, `CartItemRepository.findByCartId(long)` 존재. **장바구니 비우기(clearCart)·체크아웃 전용 조회는 cart에 아직 없음 → 신규 SPI + cart/service 구현 추가.**
- **product.spi 기존**: `ProductPurchaseCatalog`(014, cart용 — `getPurchasableVariant`/`getPurchasableVariants`, record `PurchasableVariant(variantId, productId, productName, productStatus(String), optionLabel, imageUrl, price, active, stock, purchasable)`; **optionName/optionValue/sortOrder 옵션값 목록은 미제공** — optionLabel만 제공). 구현 `ProductPurchaseCatalogImpl`(package-private, `productVariantRepository.findWithProductById`/`findByIdIn` 사용, optionLabel은 optionValues를 OptionValue.getId 정렬 후 " / " join). → 주문은 **신규 `product.spi.ProductOrderCatalog`** 가 필요(옵션값 목록 추가 제공). 단 productName/price/active/stock/purchasable/optionLabel 산출 로직은 `ProductPurchaseCatalogImpl`와 중복 구현하지 않도록 product 내부 공통 조립을 재사용한다.
- **member.spi 기존**: `MemberDirectory.findUserIdByEmail(String)→long`(014, member 소유, `@NamedInterface("spi")` 선언됨, 미존재 시 IllegalStateException). order View facade가 그대로 재사용한다(신규 포트 불필요).
- **product/repository**: `ProductVariantRepository.findWithProductById(long)`(@EntityGraph {product, optionValues}), `findByIdIn(Collection)`(@EntityGraph {product, optionValues}) 존재 → `ProductOrderCatalog`가 옵션값(OptionValue.optionName/value/sortOrder) 조립에 재사용 가능. `ProductVariant` 필드: id, @ManyToOne(LAZY) product, sku, BigDecimal price, int stock, boolean isActive, Set<OptionValue> optionValues. `ProductStatus ∈ {DRAFT, ON_SALE, SOLD_OUT, HIDDEN}`.
- **OptionValue Entity**: optionLabel 조립에서 `OptionValue::getValue`/`getId` 사용 중(ProductPurchaseCatalogImpl line 128~131). optionName/sortOrder 접근 필드 유무는 backend-implementor가 `product/domain/OptionValue.java`·`Option.java`에서 직접 확인해 매핑한다(옵션명=Option.name, 옵션값=OptionValue.value, 정렬=Option/OptionValue의 sortOrder). **product 내부에서 조립하고 DTO(scalar)로만 반환** — order는 OptionValue/Option Entity를 참조하지 않는다.
- **SecurityConfig**: REST 체인 `@Order(1)`/`securityMatcher("/api/v1/**")`/CSRF disable/STATELESS/JWT/401=RestAuthenticationEntryPoint·403=RestAccessDeniedHandler. View 체인 `@Order(2)`/formLogin(/login)/CSRF 활성/미인증 302→/login. 선례: `requestMatchers("/api/v1/cart/**").hasRole("CONSUMER")`(REST), `requestMatchers("/cart","/cart/**").hasRole("CONSUMER")`(View) 이미 존재 → **order/checkout 경로도 동일 패턴으로 `anyRequest` 앞에 추가**. RoleHierarchy = ROLE_ADMIN>ROLE_SELLER>ROLE_CONSUMER(SELLER/ADMIN이 CONSUMER 함의).
- **REST principal**: JWT 필터 후 `(long) authentication.getPrincipal()`(CartServiceResponse line 35·48·64 선례). **View principal**: form-login `auth.getName()`=email, `CurrentActorResolver.resolve(auth).email()`(CartViewController 선례). → **principal 이중경로(REST=userId, View=email)는 OrderServiceResponse(REST)·OrderFacadeImpl(View) 진입 계층에서 userId로 통일** 후 OrderService는 userId만 다룬다.
- **예외 컨벤션**: `BusinessException(message)`=400, `BusinessException(message, HttpStatus)`. `ProductAccessDeniedException(long)`=404(존재 은닉, 403 미사용, "상품을 찾을 수 없습니다. id="). REST=`RestExceptionHandler`(@RestControllerAdvice(annotations=RestController), BusinessException→getStatus() 매핑, MethodArgumentNotValid→400, 그 외 Exception→500). View=`ViewExceptionHandler`(error/error). 기존 예외 다수 존재(CartItemNotFoundException(404), VariantNotPurchasableException(400) 등). **InsufficientStockException(409)·OrderNotFoundException(404)는 미존재 → 신규 추가.**
- **테스트 프로파일 제약(중요)**: `src/test/resources/application.yml`이 DataSource·HibernateJpa·DataSourceTransactionManager·Kafka·Flyway 자동설정을 제외 → 기본 컨텍스트에서 **JPA 슬라이스/실 DB 동작 불가.** 단, **회피 패턴 확립됨**: `@DataJpaTest` + `@AutoConfigureTestDatabase(replace=NONE)` + `@Testcontainers`(postgres:16.4-alpine) + `@TestPropertySource(properties={"spring.autoconfigure.exclude=", "spring.flyway.enabled=true", "spring.jpa.hibernate.ddl-auto=validate"})`로 **자동설정 제외를 리셋하고 Flyway로 V1 스키마를 컨테이너에 적용**한다(`ProductRepositoryIntegrationTest`·`CartServiceIntegrationTest` 선례). **동시성 비관적 락 통합 테스트는 이 프로파일 위에서 작성**한다(testcontainers 의존성 build.gradle에 이미 존재). `ddl-auto=validate`이므로 **VariantStock Entity는 `product_variants` 기존 컬럼만 매핑(insert 금지)** 해야 validate 통과.
- **구조 테스트**: `ModularityTests.verify()`(Modulith 경계), `WebModuleStructureTest`(ArchUnit — web→{member,product,cart,order,payment,inventory}.domain/repository/service 직접참조 금지 규칙에 **order/inventory 이미 포함**, 변경 불요), `CartModuleStructureTest`(cart→product/member 내부참조 금지 ArchUnit). → **신규 `OrderModuleStructureTest`(order→cart/product/inventory/member 내부참조 금지) + inventory→product 내부참조 금지 규칙 추가.**

---

## 1. 설계 방식 및 이유

### 1.1 전체 구조 — 014 facade 스택 미러링 + 4개 모듈 경계 분리
014(cart)의 2갈래 레이어를 order에 그대로 적용한다.

- REST: `OrderRestController(/api/v1/orders)` → `OrderServiceResponse` → `OrderService` → `OrderRepository` 등
- View: `OrderViewController(web/order)` → `OrderFacade(order.spi)` → `OrderService` → repository(들)
- 모듈 경계(전부 published port/scalar만):
  - order → cart: **신규 `cart.spi.CartCheckoutReader`**(getCheckoutCart(userId)/clearCart(userId), 구현 `cart/service`).
  - order → product: **신규 `product.spi.ProductOrderCatalog`**(주문 스냅샷 + 옵션값 목록, 구현 `product/service`).
  - order → inventory: **신규 `inventory.spi.InventoryStockPort`**(비관적 락 재고 차감, 구현 `inventory/{service,domain,repository}`).
  - order → member: **기존 `member.spi.MemberDirectory`** 재사용(View email→userId).
  - web → order: `order.spi.OrderFacade`만 의존.

**이유**: 014와 동일 컨벤션 → 의존방향(web→order.spi / order→{cart,product,inventory,member}.spi)이 구조 테스트로 자동 강제. order Entity 비노출·principal 통일·재고 락 캡슐화를 각 경계에 가둔다.

### 1.2 principal 이중경로를 OrderService 진입에서 userId로 통일
**OrderService의 모든 메서드는 첫 인자로 `long userId`만 받는다.**

- REST: `OrderServiceResponse`가 `(long) authentication.getPrincipal()`로 userId 추출 후 OrderService 호출(CartServiceResponse 선례).
- View: `OrderFacadeImpl`(impl in order/service)이 `MemberDirectory.findUserIdByEmail(email)`로 변환 후 OrderService 호출(CartFacadeImpl 선례).
- 효과: 소유권 검사(`order.userId == userId`)·주문 생성·조회가 userId 단일 기준으로 OrderService 한 곳에 모인다.

### 1.3 주문 생성 트랜잭션 단계 순서 고정 (Task·Revision 핵심 — 락 보유 최소화 + 락 구간 외부 I/O 금지)
`OrderService.createOrder(userId, OrderCreateCommand)`는 **단일 `@Transactional`** 안에서 아래 순서를 고정한다.

1. **장바구니 조회**: `CartCheckoutReader.getCheckoutCart(userId)`. **빈 장바구니면 즉시 실패**(`EmptyCartException` 400 — 입력 상태 문제이나 재고/구매가능 충돌이 아니므로 400).
2. **사전검증 스냅샷 조회(락 없음)**: cart item의 variantId 목록으로 `ProductOrderCatalog.getOrderableSnapshots(variantIds)` IN 배치 1회. **구매 불가(purchasable=false/누락 variant) → 409**(구매가능 충돌 → `ProductNotPurchasableForOrderException` 409, 아래 1.6), **사전 재고 부족(quantity>snapshot.stock) → 409**(`InsufficientStockException`). 이 단계 값은 전부 **advisory**(저장에 쓰지 않음 — 사전검증 전용).
3. **variantId 오름차순 비관적 락 획득**: `InventoryStockPort.decrease(...)` 호출(아래 1.4)을 variantId 오름차순으로 수행. 데드락 표면 축소.
4. **권위 검증(lock 직렬화) + 저장용 스냅샷 재조회**(아래 1.4a):
   - **권위 검증**: variant.active·stock는 `VariantStock`의 잠근 row에서 재확인(완전 직렬화). stock < quantity 또는 inactive → 409 + 전체 롤백.
   - **저장용 스냅샷**: 락 후 `ProductOrderCatalog.getOrderableSnapshots`를 **다시 호출**해 저장용 값을 얻는다(2단계 사전검증 값과 분리). `price`는 `product_variants` row가 락으로 직렬화되므로 **락 후 값이 권위 있음**. `productName`/`optionLabel`/`optionValues`/`product.status`는 별도 테이블이라 **락 후 최신 재조회 + pending 단계 방어적 검증**(권위 아님, micro-window 수용). status≠ON_SALE/누락이면 409 + 전체 롤백.
5. **재고 차감**: `InventoryStockPort.decrease`가 락 구간 안에서 stock UPDATE(권위 검증과 동일 호출로 묶음, 아래 1.4).
6. **order/order_items/order_item_option_values 저장**: **4단계의 저장용 스냅샷(락 시점 값)** 으로 productName/optionLabel/optionValues/unitPrice(=락 후 price)/lineAmount/금액을 저장한다(주문 시점 = 락 시점 고정). cascade로 items/optionValues 저장. orderNumber는 1.5(트랜잭션 밖 재시도).
7. **장바구니 비우기**: `CartCheckoutReader.clearCart(userId)`.
8. **커밋**.

- **사전검증 스냅샷(2) ≠ 저장용 스냅샷(4)**: 2는 빈/구매불가/사전 재고 판정 전용 advisory, 6에 저장되는 값은 반드시 4의 락 후 재조회 값. unitPrice는 락 후 price를 쓴다(락 직전 가격 변경 반영).
- **락 구간(3~7) 안에서 외부 I/O·Kafka·결제 호출 금지**(Task). 이번 Task는 어차피 Kafka/결제 없음. 4의 `ProductOrderCatalog` 재조회는 같은 DB 읽기(외부 I/O 아님).
- 어느 단계 실패든 트랜잭션 전체 롤백 → 주문/항목/재고/장바구니 부분 반영 없음.

> **1.4a 용어 주의(구현자 혼선 방지)**: "권위 검증(authoritative)"은 lock으로 직렬화되는 **variant.active·stock**에만 해당한다. **product.status·productName·option**은 별도 테이블이라 lock 직렬화가 아니며 "락 후 최신 재조회 + pending 단계 방어적 검증"일 뿐이다(잔여 micro-window는 결제/확정 Task에서 재검증). price는 product_variants 컬럼이라 lock 직렬화 대상 → 락 후 값이 권위 있음.

### 1.4 재고 락 = A안: inventory 소유 `VariantStock` Entity + `@Lock(PESSIMISTIC_WRITE)` (Revision 확정)
inventory가 `product_variants` 테이블을 매핑하는 **자기 소유 JPA Entity `VariantStock`** 을 두고, 그 row만 잠가 검증·차감한다.

- `VariantStock` 매핑 컬럼: **`id`(=variant id), `stock`, `is_active`만 매핑**. price/sku/product_id/created_at은 매핑하지 않는다(inventory 책임 범위 밖). `ddl-auto=validate` 통과를 위해 기존 컬럼 부분 매핑(누락 컬럼은 validate 대상 아님).
- **insert 절대 금지** — 기존 row의 `stock` UPDATE 전용. 스키마는 Flyway 소유.
- `InventoryStockRepository extends JpaRepository<VariantStock, Long>`에 `@Lock(LockModeType.PESSIMISTIC_WRITE)` + `@Query("select vs from VariantStock vs where vs.id = :id")` `findByIdForUpdate(long id)` → PostgreSQL `SELECT ... FOR UPDATE`.
- `InventoryStockPort.decrease(long variantId, int quantity)`: 락 조회 → `isActive==false면 InsufficientStockException`(또는 전용 비활성 충돌, 둘 다 409) → `stock < quantity면 InsufficientStockException(409)` → `vs.decrease(quantity)`(Entity 의도 메서드, dirty checking으로 stock UPDATE). stock 음수 불가(검증 후 차감).
- **product `ProductVariant`를 같은 트랜잭션에서 로드/수정하지 않는다** — stock write 주체는 `VariantStock` 하나로 한정. inventory는 product Entity/Repository/Service 직접 참조 금지(같은 물리 테이블을 다른 Entity로 매핑).
- 다중 variant: order가 variantId 오름차순으로 `decrease`를 순차 호출하거나, port가 `decreaseAll(SortedMap/List)`로 내부 정렬 후 호출. **호출 순서를 variantId 오름차순으로 고정**해 데드락 완화(Task).

**이유**: Revision 1 — 주문/결제/정산 확장에 비관적 락이 적합. 같은 row 락으로 variant 동시 주문이 직렬화되고 isActive까지 같은 락으로 권위 검증된다.

### 1.5 orderNumber 생성 = 고엔트로피 + 트랜잭션 밖 재시도 (in-tx save 재시도 금지)
- 형식: `ORD-` + `yyyyMMdd-HHmmss`(생성 시각, 시스템 시계) + `-` + **충분한 엔트로피 랜덤**(예: 대문자/숫자 8자 이상 또는 UUID 일부) → 충돌 확률을 실질적으로 0에 가깝게.
- **같은 @Transactional 안에서 save 재시도 금지(중요)**: flush 중 `uq_orders_order_number` 위반이 나면 Hibernate Session이 오염되고 트랜잭션이 rollback-only가 되어 같은 EntityManager로 안전한 재시도가 불가능하다. 게다가 이 시점은 이미 재고 락·차감 이후라 in-tx 재시도는 흐름을 더 위험하게 만든다.
- **충돌 시 = 트랜잭션 전체 롤백 후 트랜잭션 밖 bounded 재시도**: `createOrder`의 @Transactional 메서드는 `DataIntegrityViolationException`을 잡지 않고 전파 → 트랜잭션 롤백(재고/주문/장바구니 원복). 그 **바깥의 non-transactional 메서드**(예: `OrderService.placeOrder` → 내부 `@Transactional createOrderTx`를 호출)가 `DataIntegrityViolationException`(orderNumber 충돌 식별)을 잡아 **새 트랜잭션으로 최대 3회 재호출**(시도마다 fresh persistence context). 롤백으로 stock이 원복되므로 전체 흐름 재실행이 안전하다.
- 3회 초과 → 명확히 실패(`OrderNumberGenerationException`). **무한 재시도 금지.**
- 구현 주의: 트랜잭션 경계와 재시도 경계를 분리하려면 `placeOrder`(no-tx, 재시도 루프)와 `createOrderTx`(@Transactional, 실제 1.3 흐름)를 **다른 빈 또는 self-injection**으로 분리해 Spring AOP 트랜잭션 프록시가 매 시도마다 새 트랜잭션을 열게 한다(같은 빈 내부 호출은 프록시 미적용 주의).
- (대안: 고엔트로피로 충돌이 천문학적으로 드물어 "충돌 시 즉시 명확히 실패"만 해도 Task의 "명확히 실패 처리"를 충족한다. 본 plan은 UX 위해 트랜잭션 밖 bounded 재시도를 기본으로 둔다 — 7절 트레이드오프.)

### 1.6 재고/구매가능 충돌 = 409, 배송지 입력 검증 = 400 (error-response-rule line 58 근거)
- **재고 부족**(사전 2단계·락 후 4단계 모두) → `InsufficientStockException`(409, "상태 충돌").
- **구매 불가**(product.status≠ON_SALE / variant inactive / variant 삭제로 catalog 누락) → 409. variant inactive는 `InsufficientStockException`(락 row isActive 재검증)로, product status/누락은 **신규 `ProductNotPurchasableForOrderException`(409)** 로 표현(둘 다 409, error-response-rule line 58 "상태 충돌").
- **배송지 필수값 누락/형식 오류** → 400(`OrderCreateRequest` jakarta validation + MethodArgumentNotValid). recipient/phone/postcode/address1 필수, address2 선택.
- **빈 장바구니** → 400(`EmptyCartException` — 주문 가능한 상태가 아니라는 입력 단계 실패; 재고·구매가능 충돌과 구분. Task line 333은 "실패"만 규정, 409로 분류하지 않음).
- 422/기타 분기 금지 — 위 매핑만 사용.

### 1.7 주문 조회 = 자기 주문만, 스냅샷 그대로, 타인 404 존재 은닉
- 목록: `OrderRepository.findByUserId(userId, Pageable)` 최신순(`created_at DESC`, 타이브레이크 id DESC). 페이지네이션(`PageResponse` 또는 Spring Page → DTO). 각 항목 대표상품명/항목수/finalAmount/status/orderNumber/createdAt 요약(`OrderSummaryResponse`).
- 상세: `OrderRepository.findByIdAndUserId(orderId, userId)` 또는 findById 후 `order.userId==userId` 검사. **불일치/미존재 모두 `OrderNotFoundException`(404, 동일 메시지) → 존재 은닉**(ProductAccessDeniedException 선례, 403 미사용).
- 응답/모델은 **주문 시점 스냅샷**(order_items.product_name/option_label/unit_price/line_amount, option_values, ship_* , 금액). 현재 product/variant 변경이 기존 주문에 영향 없음(snapshot 컬럼만 읽음). `ownerId`(userId), Entity, 로컬 경로 미노출.

### 1.8 모듈 경계 포트 — 4종 (Entity 비노출, DTO/scalar만)
- `cart.spi.CartCheckoutReader`(cart 소유): `CartCheckout getCheckoutCart(long userId)` / `void clearCart(long userId)`. **cartId 인자 없음** — cart는 `uq_carts_user_id`로 user당 1개, userId로만 식별·소유권(불일치 위험 제거, Task line 217). `CartCheckout(cartId, List<CartCheckoutItem>)`, `CartCheckoutItem(cartItemId, variantId, quantity)`. cart Entity 미노출. cart가 없는 userId의 clearCart는 조용한 no-op이 아니라 정의된 동작(예외 또는 명시적 무효 — 구현은 "cart 없으면 비울 것 없음"을 명시 처리, 테스트로 고정).
- `product.spi.ProductOrderCatalog`(product 소유): `List<OrderableVariantSnapshot> getOrderableSnapshots(Collection<Long> variantIds)`. record `OrderableVariantSnapshot(variantId, productId, productName, optionLabel, List<OrderOptionValue> optionValues, BigDecimal price, boolean active, int stock, String productStatus, boolean purchasable)`, `OrderOptionValue(optionName, optionValue, sortOrder)`. **동일 포트를 락 후 재호출**해 (a) product.status 최신 재검증, (b) 저장용 스냅샷(price=락 후 값, productName/optionLabel/optionValues 최신)을 동시에 얻는다(1.3 4단계). productName/price/optionLabel/active/stock/purchasable 산출은 `ProductPurchaseCatalogImpl`와 **공통 조립을 재사용**(중복 구현 금지) — product 내부 private 헬퍼/공통 컴포넌트로 추출. Entity 미노출.
- `inventory.spi.InventoryStockPort`(inventory 소유): `void decrease(long variantId, int quantity)`(+ 선택 `decreaseAll(...)`). 내부 `VariantStock` 비관적 락 + isActive·stock 검증 + 차감. 재고 부족·비활성 → `InsufficientStockException`(409). product Entity 직접 참조 금지.
- `member.spi.MemberDirectory`(기존): `long findUserIdByEmail(String email)` — order View facade가 재사용.

---

## 2. 구성 요소 (신규/수정 파일 — 정확한 패키지 경로)

> 작업 분담: 2.1 backend-implementor = order 도메인/REST/SPI 3종/inventory/Security/예외/백엔드·통합 테스트. 2.2 view-implementor = web/order ViewController·Form, templates(checkout/list/detail), cart index 주문하기 버튼, nav 링크, View 렌더링 테스트. 두 영역은 6절 인터페이스 접점으로 정합한다.

### 2.1 backend-implementor 담당 범위

#### 신규 — order/domain (Entity)
- `order/domain/Order.java` — `@Entity @Table(name="orders")`. 필드: id, `Long userId`(scalar, member Entity 직접참조 금지), `String orderNumber`, `String status`(lowercase 문자열, 생성 시 `"pending"`), `BigDecimal itemsAmount/discountAmount/shippingFee/finalAmount`, 배송지 스냅샷 `shipRecipient/shipPhone/shipPostcode/shipAddress1/shipAddress2`, created/updated(트리거 보유 → BaseEntity 상속 또는 매핑). `@OneToMany(cascade=ALL, orphanRemoval) List<OrderItem> items`. 정적 팩토리 `create(long userId, String orderNumber, BigDecimal itemsAmount, ..., 배송지...)` — discountAmount=0/shippingFee=0/finalAmount=itemsAmount-0+0. Setter 금지(ProductVariant/Cart 선례). 항목 추가 의도 메서드 `addItem(OrderItem)`.
- `order/domain/OrderItem.java` — `@Entity @Table(name="order_items")`. 필드: id, `@ManyToOne(LAZY) Order order`, `Long variantId`(scalar nullable — FK SET NULL), `String productName`, `String optionLabel`(nullable), `BigDecimal unitPrice`, `int quantity`, `BigDecimal lineAmount`, `@OneToMany(cascade=ALL) List<OrderItemOptionValue> optionValues`. updated_at 없음 → BaseEntity 미상속. 정적 팩토리 `create(long variantId, productName, optionLabel, unitPrice, quantity)` — lineAmount=unitPrice×quantity 내부 계산. `addOptionValue(...)`.
- `order/domain/OrderItemOptionValue.java` — `@Entity @Table(name="order_item_option_values")`. 필드: id, `@ManyToOne(LAZY) OrderItem orderItem`, `String optionName`, `String optionValue`, `int sortOrder`. BaseEntity 미상속. 정적 팩토리 `create(optionName, optionValue, sortOrder)`.

#### 신규 — order/repository
- `order/repository/OrderRepository.java` — `JpaRepository<Order, Long>`. `Page<Order> findByUserIdOrderByCreatedAtDescIdDesc(long userId, Pageable)`(목록 최신순), `Optional<Order> findByIdAndUserId(long id, long userId)`(상세 소유권), 상세 N+1 회피용 `@EntityGraph(attributePaths={"items","items.optionValues"}) Optional<Order> findWithItemsByIdAndUserId(long id, long userId)`. (items/optionValues는 cascade 저장이라 별도 repository 불요. 필요 시 OrderItemRepository 추가는 backend-implementor 재량이되 cascade 우선.)

#### 신규 — order/dto (REST/응답 + 요청 + 내부 command)
- `order/dto/OrderCreateRequest.java` — record(`@NotBlank String recipient`, `@NotBlank String phone`, `@NotBlank String postcode`, `@NotBlank String address1`, `String address2`)(jakarta validation, 400).
- `order/dto/OrderResponse.java` — record(orderId, orderNumber, status, List<OrderItemResponse> items, itemsAmount, discountAmount, shippingFee, finalAmount, ShippingAddressResponse shippingAddress, Instant createdAt). ownerId/Entity 미포함.
- `order/dto/OrderItemResponse.java` — record(orderItemId, Long variantId, productName, optionLabel, List<OrderItemOptionValueResponse> optionValues, unitPrice, quantity, lineAmount).
- `order/dto/OrderItemOptionValueResponse.java` — record(optionName, optionValue, sortOrder).
- `order/dto/ShippingAddressResponse.java` — record(recipient, phone, postcode, address1, address2).
- `order/dto/OrderSummaryResponse.java` — record(orderId, orderNumber, status, representativeItemName, itemCount, finalAmount, Instant createdAt).
- (목록 페이지: 기존 공통 `PageResponse` 존재 시 재사용, 없으면 `Page<OrderSummaryResponse>` 또는 간단 래퍼 — backend-implementor가 product 목록 응답 선례 확인 후 정렬.)

#### 신규 — order/service
- `order/service/OrderService.java` — `@Service`. 모든 메서드 첫 인자 `long userId`. 도메인 로직 단일 소유:
  - `OrderResult placeOrder(long userId, OrderCreateCommand cmd)` — **non-transactional**. orderNumber 충돌 시 트랜잭션 밖 bounded 재시도 루프(최대 3회, 1.5). 매 시도 `createOrderTx`를 새 트랜잭션으로 호출(트랜잭션 프록시 적용되도록 빈 분리/self-injection). 3회 초과 → `OrderNumberGenerationException`.
  - `OrderResult createOrderTx(long userId, OrderCreateCommand cmd, String orderNumber)` — `@Transactional`. 1.3 8단계 고정 흐름. CartCheckoutReader → ProductOrderCatalog 사전검증 → variantId 오름차순 InventoryStockPort.decrease(권위 검증) → **ProductOrderCatalog 락 후 재조회(저장용 스냅샷, price=락 후 값)** → order/items/optionValues 저장(전달받은 orderNumber) → clearCart. `DataIntegrityViolationException`을 잡지 않고 전파(상위 재시도). 반환 내부 결과(orderId, Entity 미노출).
  - `Page<OrderSummary> getMyOrders(long userId, Pageable)` — readOnly. 최신순. 내부 집계 타입(대표상품명=첫 항목 productName, itemCount=items.size 또는 sum quantity — 6절 합의값 고정).
  - `OrderDetail getMyOrder(long userId, long orderId)` — readOnly. `findWithItemsByIdAndUserId` 없으면 `OrderNotFoundException`(404 존재 은닉). Entity→내부 detail 타입.
  - 재고 차감은 `InventoryStockPort`로만(직접 stock write 금지). 락 구간 내 외부 I/O 없음.
- `order/service/OrderServiceResponse.java` — `@Service`. REST 전용. `(long) authentication.getPrincipal()` 추출 후 OrderService 위임 + DTO 변환. 비즈니스 로직 없음(CartServiceResponse 선례). 메서드: `createOrder(auth, OrderCreateRequest)→OrderResponse`(또는 생성 후 상세), `getMyOrders(auth, Pageable)→Page<OrderSummaryResponse>`, `getMyOrder(auth, orderId)→OrderResponse`.
- `order/service/OrderFacadeImpl.java` — `order.spi.OrderFacade` 구현(package-private, CartFacadeImpl 선례). `MemberDirectory.findUserIdByEmail(email)` 변환 후 OrderService 위임 + DTO 변환. View 4기능(주문서 조회·생성·목록·상세).
- `order/service/OrderDtoMapper.java` — package-private `@Component`. 내부 결과→OrderResponse/OrderSummaryResponse 변환. ServiceResponse·FacadeImpl 공유(CartDtoMapper 선례). ownerId/Entity 미노출 변환 한 곳에 집중.

#### 신규 — order/spi (신규 패키지)
- `order/spi/package-info.java` — `@org.springframework.modulith.NamedInterface("spi")`(cart.spi/member.spi 선례 동일 톤).
- `order/spi/OrderFacade.java` — View 전용 published port. 시그니처 6절. email 인자 + DTO만 노출. 주문서 조회(체크아웃 cart 기반 합성)/주문 생성/내 목록/내 상세.

#### 신규 — order/controller
- `order/controller/OrderRestController.java` — `@RestController @RequestMapping("/api/v1/orders")`. 비즈니스 로직 없음, OrderServiceResponse 위임. Authentication 주입(principal=userId).
  - `POST /api/v1/orders` `@Valid @RequestBody OrderCreateRequest` → 201 + OrderResponse(생성된 주문 상세). 검증 400, 재고/구매가능 409, 빈 장바구니 400.
  - `GET /api/v1/orders` (Pageable) → 200 + 목록(최신순).
  - `GET /api/v1/orders/{orderId}` → 200 + OrderResponse. 타인/미존재 404.

#### 신규 — cart/spi + cart/service (order→cart 경계)
- `cart/spi/CartCheckoutReader.java` — published port(cart 소유, 기존 cart.spi 패키지에 추가 — package-info 이미 @NamedInterface). 1.8 시그니처 + record `CartCheckout`/`CartCheckoutItem`.
- `cart/service/CartCheckoutReaderImpl.java` — `@Service` package-private implements CartCheckoutReader. 기존 `CartRepository.findByUserId`/`CartItemRepository.findByCartId` 재사용. `getCheckoutCart`: cart 없거나 항목 없으면 빈 CartCheckout(items=[]) — order가 빈 장바구니 판정. `clearCart`: cart의 항목 일괄 삭제(`cartItemRepository.deleteByCartId` 신규 메서드 또는 findByCartId 후 deleteAll). cart Entity/CartItem Entity 미노출.
- (수정) `cart/repository/CartItemRepository.java` — 필요 시 `void deleteByCartId(long cartId)`(@Modifying) 추가. **신규 인덱스/migration 금지.**

#### 신규 — product/spi + product/service (order→product 경계)
- `product/spi/ProductOrderCatalog.java` — published port(product 소유, 기존 product.spi 패키지에 추가). 1.8 시그니처 + record `OrderableVariantSnapshot`/`OrderOptionValue`. `ProductPurchaseCatalog`와 **별개 포트**(옵션값 목록 추가 제공).
- `product/service/ProductOrderCatalogImpl.java` — `@Service @Transactional(readOnly=true)` package-private implements ProductOrderCatalog. `ProductVariantRepository.findByIdIn`(@EntityGraph product,optionValues) 재사용. purchasable=(status==ON_SALE && isActive), optionLabel/productName/price 산출은 **`ProductPurchaseCatalogImpl`와 공통 조립 재사용**(product 내부 공통 헬퍼/컴포넌트로 추출 — 중복 구현 금지). 추가로 optionValues를 `OrderOptionValue(optionName, optionValue, sortOrder)`로 조립(Option.name/OptionValue.value/sortOrder, sortOrder 기준 정렬). Entity 미노출.

#### 신규 — inventory/spi + inventory/domain + inventory/repository + inventory/service (order→inventory 경계, A안)
- `inventory/spi/package-info.java` — `@NamedInterface("spi")`(신규 패키지).
- `inventory/spi/InventoryStockPort.java` — published port(inventory 소유). `void decrease(long variantId, int quantity)`(+ 선택 batch). javadoc에 "비관적 락 + isActive·stock 검증, product Entity 미참조" 명시.
- `inventory/domain/VariantStock.java` — `@Entity @Table(name="product_variants")`. **`id`/`stock`/`isActive`(is_active)만 매핑**(price/sku/product_id/created_at 미매핑). insert 금지, stock UPDATE 전용. 의도 메서드 `decrease(int quantity)`(stock -= quantity, 음수 방지는 호출 전 검증), getter stock/isActive. `@NoArgsConstructor(PROTECTED)`, 정적 팩토리 불요(조회만).
- `inventory/repository/InventoryStockRepository.java` — `JpaRepository<VariantStock, Long>`. `@Lock(LockModeType.PESSIMISTIC_WRITE) @Query("select vs from VariantStock vs where vs.id = :id") Optional<VariantStock> findByIdForUpdate(@Param("id") long id)`.
- `inventory/service/InventoryStockPortImpl.java` — `@Service @Transactional` package-private implements InventoryStockPort. `findByIdForUpdate` → 미존재 → `InsufficientStockException`(409, variant 삭제/미존재도 상태 충돌) → `!isActive` → `InsufficientStockException`(409) → `stock<quantity` → `InsufficientStockException`(409) → `vs.decrease(quantity)`. 호출자(order)가 variantId 오름차순 호출(또는 batch에서 내부 정렬). **product Entity/Repository/Service 미참조.**

#### 신규 — common/exception (최소 추가)
- `common/exception/InsufficientStockException.java` — extends BusinessException, `super(message, HttpStatus.CONFLICT)`(409). 재고 부족·variant 비활성·variant 미존재(주문 시점) 일괄 409(error-response-rule line 58). 메시지는 재고 수치 비노출("재고가 부족합니다." 수준).
- `common/exception/ProductNotPurchasableForOrderException.java` — extends BusinessException(409). product.status≠ON_SALE / catalog 누락(구매 불가 상태 충돌). (variant inactive는 락 row 재검증이라 InsufficientStock으로 통일 가능 — backend-implementor가 둘 중 하나로 일관 적용하되 **둘 다 409**.)
- `common/exception/EmptyCartException.java` — extends BusinessException(기본 400). 빈 장바구니 주문 시도.
- `common/exception/OrderNotFoundException.java` — extends BusinessException, `super(message, HttpStatus.NOT_FOUND)`(404). 타인/미존재 주문 동일 메시지(존재 은닉, ProductAccessDeniedException 선례).
- `common/exception/OrderNumberGenerationException.java` — extends BusinessException(500 또는 운영 이상). orderNumber 3회 재시도 초과(무한 재시도 금지). (신규 예외 5종 외 추가 자제.)

#### 수정 — security
- `security/SecurityConfig.java`:
  - REST 체인: `anyRequest` 앞에 `requestMatchers("/api/v1/orders/**").hasRole("CONSUMER")` 추가(SELLER/ADMIN RoleHierarchy 함의).
  - View 체인: `anyRequest` 앞에 `requestMatchers("/checkout", "/orders", "/orders/**").hasRole("CONSUMER")` 추가. 미인증은 formLogin 302→/login.

#### 신규 — 테스트 (backend) → 5절 매핑
- `order/service/OrderServiceTest.java`(단위, Mockito: CartCheckoutReader/ProductOrderCatalog/InventoryStockPort/OrderRepository mock)
- `order/service/OrderServiceResponseTest.java`(단위: principal userId 추출·DTO 변환·ownerId/Entity 미노출)
- `order/service/OrderFacadeImplTest.java`(단위: MemberDirectory email→userId 위임·DTO 변환)
- `product/service/ProductOrderCatalogImplTest.java`(단위: 스냅샷 조립·DRAFT/HIDDEN/SOLD_OUT/비활성 purchasable=false·optionName/value/sortOrder 제공·Entity 미노출) — 실 DB 의존 부분은 통합으로.
- `inventory/service/InventoryStockPortImplTest.java`(단위: 부족/비활성/미존재 → InsufficientStockException(409 매핑)·차감 호출·product 미참조)
- `cart/service/CartCheckoutReaderImplTest.java`(단위 또는 통합: scalar DTO만·clearCart userId 격리·cart 없는 userId 동작)
- `order/controller/OrderRestControllerSecurityTest.java`(@SpringBootTest+MockMvc, @MockitoBean OrderServiceResponse: 401/403/201/400/409/404·role 매핑·비노출 필드)
- **통합(Testcontainers)**: `order/service/OrderCreationConcurrencyIntegrationTest.java`(아래 5절 — 비관적 락 직렬화·409·롤백·variant 비활성 직렬화) + `inventory/repository/InventoryStockRepositoryIntegrationTest.java`(FOR UPDATE 락·VariantStock validate 매핑).

#### 신규/수정 — 구조 테스트
- `order/OrderModuleStructureTest.java`(신규, ArchUnit plain JUnit): (a) `com.shop.shop.order..`가 cart/product/inventory/member의 domain/repository/service 미참조, (b) order가 각 모듈 spi(+scalar)만 사용, (c) inventory가 product domain/repository/service 미참조(별도 규칙 또는 동일 클래스에). CartModuleStructureTest 패턴 복제.
- `WebModuleStructureTest`(기존) — order/inventory 이미 규칙 포함, **변경 불요**(web/order도 자동 대상).
- `ModularityTests.verify()`(기존) — 신규 order.spi/inventory.spi/controller/service 경계 위반 없이 통과 확인.

### 2.2 view-implementor 담당 범위

#### 신규 — web/order
- `web/order/OrderViewController.java` — `@Controller`. `OrderFacade`(order.spi) + `CurrentActorResolver`만 의존(도메인 내부 미참조, CartViewController 선례).
  - `GET /checkout` → `OrderFacade.getCheckout(actor.email())` → 모델 `checkout` → view `order/checkout`. (체크아웃 = 현재 장바구니 주문 가능 항목 + 합계 합성, 주문서 폼 표시.)
  - `POST /orders` (`@Valid @ModelAttribute OrderCreateForm` + BindingResult + RedirectAttributes) → 검증 실패 flashError + redirect:/checkout; 성공 `OrderFacade.createOrder(email, form)` → `redirect:/orders/{orderId}`(PRG). 도메인 예외(409/400) → flashError 후 redirect:/checkout(또는 ViewExceptionHandler error/error).
  - `GET /orders` (Pageable) → `OrderFacade.getMyOrders(email, pageable)` → 모델 `orders` → view `order/list`(최신순).
  - `GET /orders/{orderId}` → `OrderFacade.getMyOrder(email, orderId)` → 모델 `order` → view `order/detail`. 타인/미존재 404 → ViewExceptionHandler error/error.
  - 미인증은 SecurityConfig View 체인이 302→/login(컨트롤러 도달 전).
- `web/order/OrderCreateForm.java` — 폼 백킹(recipient, phone, postcode, address1, address2 + jakarta @NotBlank). 주문서 배송지 폼.

#### 신규 — templates
- `templates/order/checkout.html` — layout/base + fragments(header/nav/footer/messages). 모델 `checkout`. 장바구니 주문 가능 항목(상품명/옵션라벨/단가/수량/lineAmount) + itemsAmount/discountAmount(0)/shippingFee(0)/finalAmount. 배송지 폼(action `POST /orders`, 필드 recipient/phone/postcode/address1/address2, CSRF 자동). 빈 장바구니/구매불가 항목 안내. stock 수치 미표시.
- `templates/order/list.html` — 모델 `orders`(페이지). 주문 행: orderNumber, status(lowercase 표시), 대표상품명, 항목수, finalAmount, createdAt, 상세 링크 `/orders/{orderId}`. 최신순. 페이지네이션 UI.
- `templates/order/detail.html` — 모델 `order`(OrderResponse). 헤더(orderNumber/status/createdAt/금액 스냅샷), 항목 목록(productName/optionLabel/optionValues/unitPrice/quantity/lineAmount), 배송지 스냅샷(recipient/phone/postcode/address1/address2). 스냅샷 그대로 표시(현재가 아님).

#### 수정 — templates
- `templates/cart/index.html` — 현재 비활성/준비중 "주문하기" 버튼을 실제 `/checkout` 이동(링크 또는 form)으로 교체. `hasUnavailableItem`이면 안내/비활성. CONSUMER 노출.
- `templates/fragments/nav.html` — 주문 링크 `/orders` 추가(`sec:authorize="hasRole('CONSUMER')"`, active 키 `orders`). 기존 `/cart` 링크 패턴 동일.

#### 신규 — 테스트 (view) → 5절 매핑
- `view/OrderViewRenderingTest.java`(@SpringBootTest+MockMvc, OrderFacade @MockitoBean): `GET /checkout` 인증 렌더(@WithMockUser CONSUMER)·비인증 302→/login·주문 가능 항목/금액·배송지 폼 CSRF·주문 성공 redirect /orders/{id}·실패 flashError·`GET /orders` 목록·`GET /orders/{id}` 상세.
- `web/order/OrderViewControllerTest.java`(컨트롤러 단위, OrderFacade+CurrentActorResolver mock): 모델 키(checkout/orders/order)·view name·redirect·flashError·email 전달.
- `view/CartCheckoutLinkRenderingTest`(또는 014 cart 렌더 테스트 보강): cart index 주문하기 버튼 `/checkout` 이동·nav `/orders` 링크.

---

## 3. 데이터 흐름

### 3.1 주문 생성 — REST (POST /api/v1/orders)
1. Security REST 체인 `/api/v1/orders/**` hasRole(CONSUMER). 비인증 → 401 JSON. 권한없음(ROLE 없는 인증) → 403 JSON.
2. JWT 필터 principal=userId. Controller → `OrderServiceResponse.createOrder(auth, OrderCreateRequest)`. 배송지 @Valid 실패 → 400(MethodArgumentNotValid).
3. ServiceResponse: userId=(long)auth.getPrincipal() → `OrderService.createOrder(userId, command)`.
4. OrderService(1.3): non-tx `placeOrder`가 `createOrderTx`를 호출(orderNumber 충돌 시 트랜잭션 밖 최대 3회 재시도). `createOrderTx` 8단계: ①getCheckoutCart 빈 → 400(EmptyCart) ②사전검증 스냅샷(advisory, 구매불가/사전 재고부족 → 409) ③variantId 오름차순 InventoryStockPort.decrease 락 ④권위 검증(isActive/stock) + **저장용 스냅샷 락 후 재조회**(price 권위, status 방어적 재검증, 충돌 409+롤백) ⑤재고 차감 ⑥저장용 스냅샷으로 order/items/optionValues 저장 ⑦clearCart(userId) ⑧커밋.
5. ServiceResponse가 생성 주문 상세 → OrderResponse(201). ownerId/Entity 미노출.

### 3.2 주문 생성 — View (POST /orders, 주문서 폼)
1. Security View 체인 `/orders` hasRole(CONSUMER). 비인증 → 302/login.
2. OrderViewController.createOrder(OrderCreateForm, BindingResult, auth, RedirectAttributes). 검증 실패 → flashError + redirect:/checkout.
3. CurrentActorResolver.resolve(auth).email() → `OrderFacade.createOrder(email, form)`.
4. OrderFacadeImpl: MemberDirectory.findUserIdByEmail(email) → OrderService.createOrder(userId, command)(3.1의 4단계 동일 도메인 로직).
5. 성공 → redirect:/orders/{orderId}(PRG). 실패(400/409) → flashError 후 redirect:/checkout(또는 ViewExceptionHandler error/error).

### 3.3 주문 목록 — REST (GET /api/v1/orders) / View (GET /orders)
1. (REST) auth→userId / (View) auth→email→userId(facade).
2. OrderService.getMyOrders(userId, pageable): OrderRepository.findByUserIdOrderByCreatedAtDescIdDesc → 요약 집계(대표상품명/항목수/finalAmount).
3. (REST) Page<OrderSummaryResponse> 200 / (View) 모델 orders → order/list 렌더.

### 3.4 주문 상세 — REST (GET /api/v1/orders/{orderId}) / View (GET /orders/{orderId})
1. auth→userId(REST) / email→userId(View facade).
2. OrderService.getMyOrder(userId, orderId): findWithItemsByIdAndUserId 없으면 404(OrderNotFound 존재 은닉). 스냅샷(items/optionValues/배송지/금액) 조립.
3. (REST) OrderResponse 200 / (View) 모델 order → order/detail.

### 3.5 principal 이중경로 통일 지점 (명확화)
- REST: `OrderServiceResponse`에서 `(long)auth.getPrincipal()`로 통일.
- View: `OrderFacadeImpl`에서 `MemberDirectory.findUserIdByEmail(email)`로 통일.
- 통일 이후 `OrderService`는 userId만 다룬다(소유권·생성·조회 단일 기준). cart 경계=CartCheckoutReader(scalar DTO), product 경계=ProductOrderCatalog(scalar DTO), inventory 경계=InventoryStockPort(scalar), member 경계=MemberDirectory(scalar).

---

## 4. 예외 처리 전략 (error-response-rule 준수)

| 상황 | 발생 지점 | 예외 | REST 매핑 | View 매핑 |
|---|---|---|---|---|
| 미인증 REST | Security REST 체인 | — | 401 JSON(RestAuthenticationEntryPoint) | — |
| 미인증 View | Security View 체인 | — | — | 302 → /login |
| 권한 부족(ROLE 없는 인증) | Security | — | 403 JSON(RestAccessDeniedHandler) | 403 |
| 배송지 필수값 누락/형식 오류 | @Valid/Service | MethodArgumentNotValid / BusinessException(400) | **400** ErrorResponse | flashError → /checkout |
| 빈 장바구니 주문 | OrderService ① | EmptyCartException(400) | **400** | flashError → /checkout |
| 사전 재고 부족 | OrderService ② | InsufficientStockException(409) | **409** | flashError → /checkout |
| 구매 불가(status≠ON_SALE / catalog 누락) | OrderService ②④ | ProductNotPurchasableForOrderException(409) | **409** | flashError → /checkout |
| 락 후 재고 부족(동시성) | OrderService ④ / InventoryStockPort | InsufficientStockException(409) | **409** + 전체 롤백 | flashError → /checkout |
| 락 후 variant 비활성(직렬화) | InventoryStockPort(isActive) | InsufficientStockException(409) | **409** + 롤백 | flashError → /checkout |
| 타인/미존재 주문 상세 | OrderService 소유권 | OrderNotFoundException(404) | **404 존재 은닉**(403 아님) | error 뷰(404) |
| orderNumber 3회 재시도 초과 | OrderService.placeOrder(트랜잭션 밖 재시도 루프, uq 충돌 catch) | OrderNumberGenerationException(500/운영이상) | 500 | 500 |
| 인증 세션-디렉터리 불일치 | MemberDirectoryImpl(기존) | IllegalStateException | 500 | 500 |

핵심 규칙:
- **재고 부족·variant 비활성·구매 불가 = 409**(상태 충돌, error-response-rule line 58). **배송지 검증·빈 장바구니 = 400.** (재고를 400으로 내리지 않는다 — Revision 보정 1.)
- 타인 + 미존재 주문 = 동일 예외·동일 메시지 404(존재 구분 불가, ProductAccessDeniedException 선례, 403 미사용).
- REST는 JSON ErrorResponse(RestExceptionHandler — BusinessException.getStatus() 자동 매핑), View는 error/error 또는 flashError redirect.
- 응답/모델에 재고 수치·ownerId(userId)·Entity·스택트레이스·SQL 미노출. 재고 부족 메시지에 정확 stock 수치 미노출.
- 신규 예외 5종(InsufficientStock 409, ProductNotPurchasableForOrder 409, EmptyCart 400, OrderNotFound 404, OrderNumberGeneration 500)만 추가, 나머지 기존 재사용/@Valid.

---

## 5. 검증 방법 (테스트 클래스 매핑 + 자동/수동 구분)

> 테스트 프로파일 제약(0절): 기본 `application.yml`이 DataSource·HibernateJpa·DataSourceTransactionManager·Kafka·Flyway 자동설정을 제외 → 기본 컨텍스트는 JPA/실 DB 동작 불가. **동시성·실 락은 Testcontainers 통합 프로파일에서 검증**(아래 통합 절차). Service/REST/View 로직은 Mockito·@MockitoBean으로 커버.

### 단위(자동) — OrderServiceTest (Mockito)
- 장바구니 기반 주문 생성 성공(8단계 순서 호출: getCheckoutCart → getOrderableSnapshots → InventoryStockPort.decrease(variantId 오름차순) → order 저장 → clearCart).
- 빈 장바구니 → EmptyCartException(400). InventoryStockPort/저장/clearCart 미호출.
- 구매 불가 항목 포함(snapshot.purchasable=false) → 409. decrease/저장/clearCart 미호출.
- 사전 stock 부족(quantity>snapshot.stock) → 409.
- 락 후 stock 부족(InventoryStockPort.decrease가 InsufficientStockException throw) → 409 전파 + 저장/clearCart 미호출(롤백 의도).
- 락 후 purchasable 재검증 실패(락 후 status 재조회가 HIDDEN/SOLD_OUT) → 409.
- 주문 생성 실패 시 clearCart 호출 없음 / order·orderItem 저장 없음(mock 상호작용 단언).
- 성공 시 status="pending" / 상품명·옵션·단가·배송지 스냅샷 저장 / itemsAmount=Σline, discount=0, shipping=0, final=items / inventory decrease 호출 / clearCart 호출.
- **저장용 스냅샷은 락 후 재조회 값 사용**: ProductOrderCatalog가 사전검증(2단계)과 락 후(4단계)에 서로 다른 price를 반환하도록 mock → 저장된 unitPrice/lineAmount가 **락 후 price**인지 단언(2단계 값 아님). ProductOrderCatalog가 최소 2회 호출됨(ArgumentCaptor/verify times(2)).
- orderNumber 충돌 재시도(트랜잭션 밖): `createOrderTx`가 1~2회 DataIntegrityViolation throw 후 성공하면 `placeOrder`가 새 번호로 재호출해 최종 성공 / 3회 초과 → OrderNumberGenerationException. **in-tx에서 save를 다시 호출하지 않음**(같은 트랜잭션 재시도 부재 단언).
- 자기 주문 목록 최신순 / 자기 주문 상세 / 다른 사용자 주문 상세 → OrderNotFoundException(404 존재 은닉).
- decrease 호출이 variantId 오름차순(다중 variant, ArgumentCaptor 순서 단언).

### 단위(자동) — OrderServiceResponseTest / OrderFacadeImplTest
- ServiceResponse: (long)auth.getPrincipal() 추출·OrderService 위임·OrderResponse 변환·ownerId/Entity 미노출.
- FacadeImpl: MemberDirectory.findUserIdByEmail 위임·DTO 변환·email→userId.

### 단위(자동) — ProductOrderCatalogImplTest / InventoryStockPortImplTest / CartCheckoutReaderImplTest
- ProductOrderCatalog: 스냅샷 조립·DRAFT/HIDDEN/SOLD_OUT/비활성 purchasable=false·optionName/optionValue/sortOrder 제공·Entity 미노출(record만).
- InventoryStockPort: stock 충분 차감 성공·부족 InsufficientStockException·비활성 InsufficientStockException·미존재 InsufficientStockException·product 미참조·음수 불가.
- CartCheckoutReader: scalar DTO만 반환(cart/CartItem Entity 미노출)·clearCart(userId) 해당 user만·cart 없는 userId 정의된 동작.

### REST/Security(자동) — OrderRestControllerSecurityTest (@SpringBootTest, MockMvc, @MockitoBean OrderServiceResponse)
- `POST /api/v1/orders`: CONSUMER 201, 비인증 401, ROLE 없는 인증 403, SELLER/ADMIN 201(RoleHierarchy).
- `POST /api/v1/orders`: 배송지 검증 실패 400 / 재고 부족 409 / 구매 불가 409.
- `GET /api/v1/orders`: 자기 목록 200. `GET /api/v1/orders/{id}`: 자기 상세 200, 타인 404.
- 응답 본문에 ownerId, member/product/variant/cart Entity, 로컬 절대경로 미포함(jsonPath doesNotExist).

### View(자동) — OrderViewRenderingTest / OrderViewControllerTest (@MockitoBean OrderFacade)
- `GET /checkout` CONSUMER 렌더 / 비인증 302→/login / 주문 가능 항목·금액 렌더 / 배송지 폼 CSRF.
- 주문 생성 성공 redirect /orders/{id} / 실패 flashError.
- `GET /orders` 목록 렌더 / `GET /orders/{id}` 상세 렌더(스냅샷).
- cart index 주문하기 → /checkout / nav /orders 링크.

### 통합 — 동시성·실 락 (Testcontainers PostgreSQL, 자동, 별도 프로파일)
> 통합 프로파일 구성(선례 `ProductRepositoryIntegrationTest`/`CartServiceIntegrationTest`): `@DataJpaTest`(또는 락 트랜잭션 경계 검증엔 `@SpringBootTest`) + `@AutoConfigureTestDatabase(replace=NONE)` + `@Testcontainers`(postgres:16.4-alpine + `@ServiceConnection`) + `@TestPropertySource(properties={"spring.autoconfigure.exclude=", "spring.flyway.enabled=true", "spring.jpa.hibernate.ddl-auto=validate"})`로 **기본 application.yml의 자동설정 제외를 리셋하고 Flyway로 V1 스키마 적용**. 필요한 Service/Port만 `@Import`. `VariantStock`는 `product_variants` 기존 컬럼만 매핑하므로 `ddl-auto=validate` 통과.

- `InventoryStockRepositoryIntegrationTest`: `findByIdForUpdate`가 실 `SELECT ... FOR UPDATE` 발행·VariantStock validate 매핑·stock 차감 반영·is_active 읽기.
- `OrderCreationConcurrencyIntegrationTest`(@SpringBootTest 권장 — 두 트랜잭션 직렬화):
  - 같은 variant stock=1일 때 동일 variant 동시 주문 2개 → **하나만 성공, 나머지 409(InsufficientStockException)**.
  - 비관적 락으로 동일 variant 주문 직렬화 → stock 음수 불가.
  - 사전 검증 통과 후 락 직전 variant 비활성화 커밋 → 락 후 isActive 재검증 409(variant.active 직렬화).
  - 실패 트랜잭션은 order/order_items/재고/장바구니 모두 롤백.
  - 실 PostgreSQL row-level lock 동작을 Mockito가 아닌 실 DB로 검증.

### 구조(자동) — OrderModuleStructureTest / WebModuleStructureTest / CartModuleStructureTest / ModularityTests
- web.order가 order.domain/repository/service 미참조(기존 WebModuleStructureTest, order 이미 포함).
- order가 cart/product/inventory/member 내부(domain/repository/service) 미참조(신규 OrderModuleStructureTest).
- order가 각 모듈 spi(+scalar)만 사용.
- inventory가 product domain/repository/service 미참조(신규 규칙).
- ModularityTests.verify() 통과(신규 order.spi/inventory.spi 경계 포함).

### 실행 / docker-compose 수동 확인
- `./gradlew test` 전체 통과(통합 테스트 포함 — Testcontainers 자동).
- docker-compose 수동 확인(보조): 실제 동시 주문 부하 시 stock 음수 미발생·orderNumber 중복 미발생·락 대기 동작. 확인/미확인 항목을 작업 완료 보고에 남긴다(013/014 정책 동일).

---

## 6. 양 영역 인터페이스 접점 (어긋남 방지)

### OrderFacade (order.spi) 시그니처(안) — View 전용

    OrderCheckoutResponse getCheckout(String email);              // 주문서(현재 장바구니 주문가능 항목+합계)
    OrderResponse createOrder(String email, OrderCreateRequest request);  // 생성 후 상세
    Page<OrderSummaryResponse> getMyOrders(String email, Pageable pageable);
    OrderResponse getMyOrder(String email, long orderId);

- email은 form-login principal(auth.getName()). 내부 MemberDirectory로 userId 변환. 반환은 order.dto DTO(View가 Entity/문자열 status만 참조). REST는 OrderFacade 미사용 — OrderServiceResponse(auth) 경유.

### CartCheckoutReader (cart.spi) 시그니처(안) — order 전용

    CartCheckout getCheckoutCart(long userId);   // 빈 장바구니면 items=[]
    void clearCart(long userId);                 // cartId 인자 없음(userId로 식별)
    record CartCheckout(long cartId, List<CartCheckoutItem> items) {}
    record CartCheckoutItem(long cartItemId, long variantId, int quantity) {}

### ProductOrderCatalog (product.spi) 시그니처(안) — order 전용

    List<OrderableVariantSnapshot> getOrderableSnapshots(Collection<Long> variantIds);
    record OrderableVariantSnapshot(long variantId, long productId, String productName,
                                    String optionLabel, List<OrderOptionValue> optionValues,
                                    BigDecimal price, boolean active, int stock,
                                    String productStatus, boolean purchasable) {}
    record OrderOptionValue(String optionName, String optionValue, int sortOrder) {}

- purchasable=(productStatus==ON_SALE && active). 2단계 호출 값은 **advisory**(사전검증 전용). **저장용 값은 락 후 재호출 결과**를 쓴다(price=락 직렬화 권위, name/option/status=락 후 최신). ProductPurchaseCatalog(014)와 별개 포트(옵션값 목록 추가).

### InventoryStockPort (inventory.spi) 시그니처(안) — order 전용

    void decrease(long variantId, int quantity);   // 비관적 락 + isActive·stock 검증 + 차감, 부족/비활성/미존재 → InsufficientStockException(409)
    // (선택) void decreaseAll(List<StockDecrease> decreases);  // 내부 variantId 오름차순 정렬 후 락

### MemberDirectory (member.spi) 시그니처 — 기존 재사용

    long findUserIdByEmail(String email);   // 014 기존 포트, 신규 추가 없음

### REST 응답/요청 DTO (order.dto)
- OrderCreateRequest(recipient, phone, postcode, address1, address2) — @NotBlank 4종 + address2 선택
- OrderResponse(orderId, orderNumber, status(lowercase), items, itemsAmount, discountAmount, shippingFee, finalAmount, shippingAddress, createdAt)
- OrderItemResponse(orderItemId, variantId, productName, optionLabel, optionValues, unitPrice, quantity, lineAmount)
- OrderItemOptionValueResponse(optionName, optionValue, sortOrder)
- ShippingAddressResponse(recipient, phone, postcode, address1, address2)
- OrderSummaryResponse(orderId, orderNumber, status, representativeItemName, itemCount, finalAmount, createdAt)
- **합의값**: representativeItemName=주문 첫 항목 productName, itemCount=주문 항목(라인) 수. status는 DB lowercase 문자열 그대로. ownerId/Entity/로컬 경로 미노출.

### 모델 키 / 폼 (View — Backend-View Contract 준수)
- 주문서: 모델 키 `checkout` → view `order/checkout`. 폼 action `POST /orders`, 필드 recipient/phone/postcode/address1/address2(CSRF 자동).
- 주문 목록: 모델 키 `orders` → view `order/list`. 상세 링크 `/orders/{orderId}`.
- 주문 상세: 모델 키 `order` → view `order/detail`.
- 성공 redirect: `/orders/{orderId}`(PRG). 실패: flashError(flashError 키, messages.html) 후 redirect:/checkout.
- cart index 주문하기: `/checkout` 이동. nav 링크: `/orders`(CONSUMER).

### 경로 / 권한
- REST: `POST /api/v1/orders`, `GET /api/v1/orders`, `GET /api/v1/orders/{orderId}` — 전부 hasRole("CONSUMER").
- View: `GET /checkout`, `POST /orders`, `GET /orders`, `GET /orders/{orderId}` — hasRole("CONSUMER"). 미인증 302→/login.

---

## 7. 트레이드오프

- **비관적 락(VariantStock FOR UPDATE) vs 조건부 atomic UPDATE**(Revision 1 확정): 단순 카운터 차감엔 atomic UPDATE가 락 보유 최소·단문장 이점이 있으나, 015는 주문/결제/정산 흐름의 시작점이라 "잠근 상태를 읽고 stock·isActive·status를 순차 검증"하는 명시성을 택한다. 비용은 락 보유 구간·데드락 표면(다중 variant) — variantId 오름차순 락 + 락 구간 외부 I/O 금지로 완화.
- **A안(inventory 소유 VariantStock가 product_variants 매핑) vs product가 재고 차감**: 같은 물리 테이블을 두 Entity가 매핑하는 부담이 있으나, 모듈 경계(order→inventory.spi, inventory↛product 내부)를 구조 테스트로 강제하고 stock write 주체를 하나로 한정한다. insert 금지·부분 컬럼 매핑으로 product 소유 스키마와 충돌하지 않게 한다.
- **purchasable 권위 검증 범위 비대칭**(variant.active 완전 직렬화 / product.status micro-window 수용): products row까지 FOR UPDATE로 잠그면 테이블 2개 락 순서·데드락 표면이 늘고 상품 상태 관리 범위를 벗어난다. pending 단계라 잔여 micro-window를 수용하고 결제/확정 Task에서 재검증(defense in depth).
- **재고 부족 409 통일**(사전·락 후 모두): error-response-rule line 58 직접 근거. 400(배송지 입력)과 의미 분리. 사전검증 통과 후 락 후 409 가능성을 클라이언트가 재시도로 처리.
- **저장용 스냅샷을 락 후 재조회**(사전검증 스냅샷과 분리): ProductOrderCatalog를 2회(사전/락 후) 호출하는 비용이 있으나, "주문 시점 스냅샷"의 시점을 lock 직렬화 순간으로 못박는다. price는 product_variants 컬럼이라 락으로 권위 보장, name/option/status는 락 후 최신(잔여 micro-window 수용). 2단계 값을 저장하면 락 직전 가격 변경을 놓치는 정확성 결함이 생긴다.
- **orderNumber 트랜잭션 밖 bounded 재시도**(in-tx save 재시도 금지): flush 중 unique 위반은 Hibernate Session을 오염시켜 같은 트랜잭션 재시도가 불가능하다. 충돌 시 전체 롤백(stock 원복) 후 새 트랜잭션으로 재시도하면 전체 흐름을 다시 타는 비용이 있으나, 고엔트로피로 충돌이 거의 없어 재시도 경로는 사실상 미발생. placeOrder(no-tx)/createOrderTx(@Transactional) 빈 분리로 매 시도 새 트랜잭션을 보장(프록시 미적용 함정 회피).
- **신규 published port 3종(CartCheckoutReader·ProductOrderCatalog·InventoryStockPort) + 기존 MemberDirectory 재사용**: 포트 수가 늘지만 order→내부참조를 구조 테스트로 차단하고 각 모듈 소유권을 분리. ProductOrderCatalog는 ProductPurchaseCatalog와 별개(옵션값 목록)지만 산출 로직은 product 내부 공통 조립 재사용으로 중복 최소화.
- **clearCart에 cartId 미전달**(userId만): uq_carts_user_id로 user당 cart 1개라 cartId 동반 시 불일치 위험만 증가. userId 단일 식별로 소유권·격리 단순화(Task line 217).
- **테스트 프로파일 JPA 제외 → 동시성 통합은 Testcontainers 별도 프로파일**: 기본 컨텍스트로는 실 락 검증 불가하나, 014/013에서 확립한 자동설정 리셋+Flyway 패턴으로 실 PostgreSQL 비관적 락을 자동 검증(Mockito로는 락 직렬화를 검증할 수 없으므로 통합 필수).
- **결제/이벤트/payment row/쿠폰/배송비/주소록/비회원/배송 상태 전이 미구현**: Task Constraint 준수. 금액은 discount=0/shipping=0 고정, 주문 status는 pending까지만.

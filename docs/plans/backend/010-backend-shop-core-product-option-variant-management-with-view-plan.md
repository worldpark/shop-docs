# 010. shop-core 상품 옵션 + Variant 관리 + 화면 — Plan

> 범위: 판매자가 상품의 **옵션 / 옵션값 / variant(구매 단위 SKU)**를 관리하는 REST API + Thymeleaf SSR 화면. 도메인 Entity/Repository/Service, 검증 불변식, View 전용 facade(`product.spi`), web ViewController(`web/product`), 관리 화면 템플릿, 단위·REST/Security·View 테스트.
> 범위 밖(Constraints): 상품 이미지 업로드, 공개 상품 목록/상세, 장바구니, 주문 재고 차감/복원·분산락·조건부 차감, 옵션/옵션값/variant **삭제**, 이벤트 계약 변경.
> 과도 설계 금지 원칙 적용.

---

## 구현 목표
판매자(자기 상품) / ADMIN(전 상품)이 옵션→옵션값→variant 구조를 생성·조회·수정할 수 있는 REST API와 관리 화면을 제공한다. variant는 SKU·가격·재고·활성상태와 옵션값 조합을 가지며, 조합·소유권·하위 리소스·중복·범위 불변식을 서비스 계층에서 강제한다. web은 `product.spi`의 View 전용 facade만 의존한다.

---

## 사전 확정 사실 (재조사로 확인됨)

### 스키마 — 신규 마이그레이션 불필요 ★
- `product_options`, `option_values`, `product_variants`, `variant_values` 4개 테이블이 **V1__init_schema.sql에 이미 완전 정의되어 있다**(컬럼·PK·UNIQUE·CHECK·FK·인덱스 포함). 따라서 **이번 Task에서 Flyway 마이그레이션을 추가하지 않는다.** (Constraint "Flyway V1 적용 시 신규 migration 추가"는 *변경이 필요할 때*만 적용되며, 본 Task는 스키마 변경이 없다.)
  - `product_options`: id(IDENTITY), product_id(FK→products CASCADE, NOT NULL), name(NOT NULL), `UNIQUE(product_id, name)`.
  - `option_values`: id, option_id(FK→product_options CASCADE, NOT NULL), value(NOT NULL), `UNIQUE(option_id, value)`.
  - `product_variants`: id, product_id(FK→products CASCADE), sku(NOT NULL `UNIQUE`), price(numeric(12,2) CHECK≥0), stock(int DEFAULT 0 CHECK≥0), is_active(boolean DEFAULT true), created_at(timestamptz DEFAULT now()) — **updated_at 없음**, `idx_product_variants_product_id`.
  - `variant_values`: (variant_id, option_value_id) 복합 PK, 양쪽 FK CASCADE — **조인 테이블**.
- `ddl-auto: validate` — Entity는 스키마와 정확히 일치해야 한다.
  - `ProductVariant`는 created_at만 있고 updated_at이 없으므로 **`BaseEntity`를 상속하지 않는다.** created_at은 `@Column(name="created_at", insertable=false, updatable=false) Instant createdAt`로 DB 소유 읽기전용 매핑(BaseEntity.createdAt 매핑 방식 계승).
  - `ProductOption`/`OptionValue`는 시간 컬럼이 없으므로 BaseEntity 비상속 일반 Entity.

### variant_values 매핑 결정
- `database_design.md` §4.2가 명시: "variant_values는 JPA에서 **@ManyToMany의 조인 테이블**". 이 SSOT를 따라 `ProductVariant`가 `@ManyToMany Set<OptionValue>`를 `@JoinTable(name="variant_values", joinColumns=variant_id, inverseJoinColumns=option_value_id)`로 소유한다. 별도 `VariantValue @Entity`(@EmbeddedId)를 만들지 않는다(과도 설계 회피). 이 매핑이 곧 요구사항의 "VariantValue 복합키 매핑"을 충족한다.

### 보안 — SecurityConfig 변경 불필요
- REST 체인이 `/api/v1/seller/**`→`hasRole("SELLER")`, View 체인이 `/seller/**`→`hasRole("SELLER")`를 이미 커버한다(ADMIN 함의는 RoleHierarchy). 신규 엔드포인트가 모두 이 prefix 하위라 **SecurityConfig 수정 없음**. 소유권/하위리소스 검증은 Service 계층 책임.

### 기존 패턴(준수 대상)
- REST: `RestController → ServiceResponse → Service → Repository`. REST principal=userId(long): `(long) auth.getPrincipal()`, isAdmin=`ROLE_ADMIN` authority 직접 보유.
- View: `@Controller(web/product) → product.spi facade → Service → Repository`. View principal=email(`auth.getName()`) → facade가 `UserDirectory`로 userId 변환.
- 예외: `BusinessException(message, HttpStatus)` 상속 커스텀 예외. REST는 `RestExceptionHandler`가 status JSON, View는 `ViewExceptionHandler`가 error 뷰. Duplicate류 409 컨벤션(`DuplicateEmailException`/`DuplicateSlugException`).
- DTO: Request=record+검증 어노테이션, Response=record+`from(Entity)` 정적 팩토리, Entity 직접 노출 금지. 목록은 `List<T>` 또는 `PageResponse<T>`.
- 소유권: `ProductService.checkOwnership`(ADMIN 스킵, 비소유 → `ProductAccessDeniedException` 404=존재 은닉).
- 테스트 프로파일: DataSource/JPA/Flyway/Kafka 자동설정 제외 → **DB 없이 부팅**, repository는 `@MockBean`/`@Mock`. (∴ 신규 검증의 실제 SQL은 통합 검증 대상이 아니며, 서비스 단위 테스트에서 mock으로 불변식 로직을 검증한다 — 기존 프로젝트 자세 계승.)

---

## 핵심 설계 결정

### 결정 1 — ProductService에 소유권 로딩 메서드 추출(단일 출처)
옵션/variant 서비스가 모두 "상품 로드 + 소유권 검사"를 필요로 한다. 중복을 막기 위해 `ProductService`에 public `Product getOwnedProduct(long actorId, boolean actorIsAdmin, long productId)`를 추가하고(기존 `getForEdit`의 load+checkOwnership 로직을 이 메서드로 추출, `getForEdit`는 이를 위임 — **동작 불변**), 옵션/variant 서비스가 이를 호출한다. 소유권 불변식이 ProductService 한 곳에 유지된다.

### 결정 2 — 옵션/variant 서비스를 product 도메인 순수 서비스로 분리
`ProductOptionService`(옵션·옵션값), `ProductVariantService`(variant)를 신설한다. 두 서비스는 actorId(long)/actorIsAdmin(boolean)을 인자로만 받고 principal 변환을 하지 않는다(ProductService와 동일 자세). 모든 불변식(중복·하위리소스·조합·범위)을 여기서 강제한다.

### 결정 3 — View facade와 Form 위치
- `SellerProductVariantFacade`(`product.spi`, `@NamedInterface("spi")`): 관리화면 조회 + 옵션/옵션값/variant 생성·수정. **primitive 파라미터만** 받고(actorEmail/isAdmin/productId/이름·값·sku·price·stock·active·optionValueIds) **응답 DTO만** 반환 → web이 도메인 타입을 컴파일타임에 참조하지 않음. 구현체 `SellerProductVariantFacadeImpl`은 `product.service`(비공개)에 두고 `UserDirectory`로 email→userId 변환 후 두 서비스에 위임, Entity→DTO 변환.
- **Form은 `web/product`에 둔다**(`OptionForm`/`OptionValueForm`/`VariantForm`). 신규 폼은 도메인 enum 의존이 없고(필드: String/BigDecimal/int/boolean/List<Long>) web 전용 입력 객체이므로 web 소유가 깔끔하다(Module Boundary Contract가 `product/dto` 또는 `web/product` 허용). facade는 폼이 아니라 primitive를 받으므로 폼을 product에 노출할 필요가 없다.
- **응답/뷰 DTO는 `product/dto`**(`@NamedInterface("dto")`)에 둔다(web이 모델로 읽음).

### 결정 4 — 검증 실패 처리(View)
- **Bean Validation(@Valid) 실패** → `seller/product-variants` **재렌더링**(관리 모델 재조립 + 실패 폼 유지). (task "검증 실패 시 재렌더링" 충족)
- **도메인 BusinessException(중복명/중복값/SKU중복/조합중복/범위·하위리소스 위반)** → `flashError` + PRG `redirect:/seller/products/{productId}/variants` (AdminMember changeRole 패턴 계승). 성공도 `flashSuccess` + 동일 redirect.
- 소유권/미존재(`ProductAccessDeniedException`/`ProductNotFoundException` 404 등)는 `ViewExceptionHandler`가 error 뷰 처리(기존과 동일).

---

## 검증 불변식 (서비스 계층, task Requirements/Acceptance 매핑)

| # | 불변식 | 위반 예외 (HTTP) | 위치 |
|---|---|---|---|
| V1 | 상품 내 옵션명 중복 금지 | `DuplicateOptionNameException` (409) | ProductOptionService.createOption |
| V2 | 옵션 내 옵션값 중복 금지 | `DuplicateOptionValueException` (409) | ProductOptionService.createOptionValue |
| V3 | SKU 전역 중복 금지(수정 시 자기 제외) | `DuplicateSkuException` (409) | ProductVariantService.create/update |
| V4 | price ≥ 0 | `BusinessException` (400) | ProductVariantService |
| V5 | stock ≥ 0 | `BusinessException` (400) | ProductVariantService |
| V6 | 모든 optionValueId가 해당 productId 소속 | `BusinessException` (400) | ProductVariantService |
| V7 | 한 옵션당 최대 1개 optionValue 선택 | `BusinessException` (400) | ProductVariantService |
| V8 | 상품에 옵션이 있으면 각 옵션마다 1개씩 선택(전부 커버) | `BusinessException` (400) | ProductVariantService |
| V9 | 동일 option value 조합 variant 중복 금지(수정 시 자기 제외) | `BusinessException` (409, 상태충돌) | ProductVariantService |
| V10 | optionId가 productId 하위 리소스 | `OptionNotFoundException` (404) | ProductOptionService.createOptionValue |
| V11 | variantId가 productId 하위 리소스 | `VariantNotFoundException` (404) | ProductVariantService.update |
| V12 | 소유권(비소유·비ADMIN) | `ProductAccessDeniedException` (404) | ProductService.getOwnedProduct |
| V13 | 상품 미존재 | `ProductNotFoundException` (404) | ProductService.getOwnedProduct |

> V6 구현: `optionValueRepository.findByOption_ProductId(productId)`로 상품 소속 옵션값 id 집합을 만들고 요청 ids가 부분집합인지 검사. V7: 선택 옵션값들을 optionId로 그룹핑해 중복 옵션 검출. V8: 상품 옵션 id 집합 == 선택 옵션값의 optionId 집합(각 1개) 검사. V9: 상품의 기존 variant 옵션값 id-집합들과 신규 조합 집합 동등성 비교(수정 시 자기 variantId 제외).

---

## 신규 예외 (common/exception) — 5종
| 예외 | HTTP | 메시지 | 비고 |
|---|---|---|---|
| `DuplicateOptionNameException(long productId, String name)` | 409 | 이미 사용 중인 옵션명입니다. | V1 |
| `DuplicateOptionValueException(long optionId, String value)` | 409 | 이미 사용 중인 옵션값입니다. | V2 |
| `DuplicateSkuException(String sku)` | 409 | 이미 사용 중인 SKU입니다. | V3 |
| `OptionNotFoundException(long id)` | 404 | 옵션을 찾을 수 없습니다. | V10 |
| `VariantNotFoundException(long id)` | 404 | variant를 찾을 수 없습니다. | V11 |

> 조합/범위/한옵션초과(V6~V9)는 도메인 메시지를 가진 `BusinessException`(400/409)으로 던진다(전용 예외 신설 없이 — 과도 설계 회피, 메시지로 구분).

---

## 도메인 Entity (product/domain) — 3종

- **ProductOption**: `id`, `@ManyToOne(LAZY) Product product`, `name`. 정적 팩토리 `create(Product, String name)`. setter 금지. BaseEntity 비상속.
- **OptionValue**: `id`, `@ManyToOne(LAZY) ProductOption option`, `value`. 정적 팩토리 `create(ProductOption, String value)`.
- **ProductVariant**: `id`, `@ManyToOne(LAZY) Product product`, `sku`, `price`(BigDecimal), `stock`(int), `isActive`(boolean), `createdAt`(읽기전용), `@ManyToMany Set<OptionValue> optionValues`(@JoinTable variant_values). 정적 팩토리 `create(Product, sku, price, stock, isActive, Set<OptionValue>)` + 의도 메서드 `update(sku, price, stock, isActive, Set<OptionValue>)`(dirty checking). BaseEntity 비상속(updated_at 컬럼 없음).

> product_id/option_id는 같은 product 모듈 내부라 Entity `@ManyToOne` 직접 참조 허용(Product.ownerId의 member 스칼라 회피와는 다른 사안 — 모듈 내부 관계).

## Repository (product/repository) — 3종
- `ProductOptionRepository`: `existsByProductIdAndName`, `findByProductIdOrderById`, `List<ProductOption> findByProductId`.
- `OptionValueRepository`: `existsByOptionIdAndValue`, `List<OptionValue> findByOption_ProductId`, `List<OptionValue> findByOptionIdOrderById`(옵션별 값 목록).
- `ProductVariantRepository`: `existsBySku`, `existsBySkuAndIdNot`, `List<ProductVariant> findByProductId`(조합 중복·목록).

## Service (product/service)
- `ProductService`에 `getOwnedProduct(actorId, actorIsAdmin, productId)` 추가(결정 1).
- `ProductOptionService`: `createOption(actorId, isAdmin, productId, name)`, `createOptionValue(actorId, isAdmin, productId, optionId, value)`, 조회 `List<ProductOption> listOptions(actorId, isAdmin, productId)`(값 포함). 불변식 V1·V2·V10·V12·V13.
- `ProductVariantService`: `createVariant(...)`, `updateVariant(...)`, `List<ProductVariant> listVariants(actorId, isAdmin, productId)`. 불변식 V3~V13.

## DTO (product/dto)
- 응답: `ProductOptionResponse(long optionId, String name, List<OptionValueResponse> values)` `from(ProductOption)`; `OptionValueResponse(long optionValueId, long optionId, String value)` `from(OptionValue)`; `ProductVariantResponse(long variantId, String sku, BigDecimal price, int stock, boolean active, List<Long> optionValueIds, List<String> optionValueLabels)` `from(ProductVariant)`.
- 화면 집계: `VariantManagementView(SellerProductRef product, List<ProductOptionResponse> options, List<ProductVariantResponse> variants)`; `SellerProductRef(long productId, String name)`.
- REST 요청: `ProductOptionCreateRequest(@NotBlank String name)`; `OptionValueCreateRequest(@NotBlank String value)`; `ProductVariantCreateRequest(@NotBlank String sku, @NotNull @DecimalMin("0.0") BigDecimal price, @NotNull @Min(0) Integer stock, boolean active, List<Long> optionValueIds)`; `ProductVariantUpdateRequest(동일 필드)`.

## Form (web/product) — Thymeleaf 바인딩(가변 class, getter/setter)
- `OptionForm{ @NotBlank name }`
- `OptionValueForm{ @NotBlank value }`
- `VariantForm{ @NotBlank sku; @NotNull @DecimalMin("0.0") BigDecimal price; @NotNull @Min(0) Integer stock; boolean active; List<Long> optionValueIds }`

## View facade (product/spi)
```java
public interface SellerProductVariantFacade {
    VariantManagementView getManagementView(String actorEmail, boolean actorIsAdmin, long productId);
    void createOption(String actorEmail, boolean actorIsAdmin, long productId, String name);
    void createOptionValue(String actorEmail, boolean actorIsAdmin, long productId, long optionId, String value);
    void createVariant(String actorEmail, boolean actorIsAdmin, long productId,
                       String sku, BigDecimal price, int stock, boolean active, List<Long> optionValueIds);
    void updateVariant(String actorEmail, boolean actorIsAdmin, long productId, long variantId,
                       String sku, BigDecimal price, int stock, boolean active, List<Long> optionValueIds);
}
```
구현 `SellerProductVariantFacadeImpl`(product/service, 비공개): `UserDirectory.findUserIdByEmail` → 두 서비스 위임 → Entity→DTO.

## REST (product/controller) + ServiceResponse(product/service)
- `SellerProductOptionRestController` (`/api/v1/seller/products/{productId}/options`): `GET`(→`List<ProductOptionResponse>`), `POST`(옵션 생성→`ProductOptionResponse`), `POST /{optionId}/values`(옵션값 생성→`OptionValueResponse`). 위임 `ProductOptionServiceResponse`.
- `SellerProductVariantRestController` (`/api/v1/seller/products/{productId}/variants`): `GET`(→`List<ProductVariantResponse>`), `POST`(생성→`ProductVariantResponse`), `PATCH /{variantId}`(수정→`ProductVariantResponse`). 위임 `ProductVariantServiceResponse`.
- ServiceResponse는 `(long)auth.getPrincipal()` + isAdmin 추출 후 서비스 위임, Entity→DTO 변환(비즈니스 로직 없음).

## ViewController (web/product)
- `SellerProductVariantViewController` (`/seller/products/{productId}/variants`):
  - `GET` → 모델 `product`/`options`/`variants`(facade.getManagementView 분해) + 빈 `optionForm`/`optionValueForm`/`variantForm` → 뷰 `seller/product-variants`.
  - `POST /options`, `POST /options/{optionId}/values`, `POST /variants`, `POST /variants/{variantId}`: @Valid 폼 바인딩 → (a)Bean검증 실패 시 관리모델 재조립 + 실패폼 유지하여 `seller/product-variants` 재렌더, (b)성공 시 facade 호출 → `flashSuccess` + redirect, (c)`BusinessException` catch → `flashError` + redirect. `isAdmin(auth)` 헬퍼 web 잔존. facade primitive 호출(폼에서 추출).

## 템플릿/정적 (resources)
- 신규 `templates/seller/product-variants.html`: `layout/base :: layout` 사용. 섹션: ①상품명(`product.name`) 헤딩, ②옵션 목록(각 옵션+옵션값들)·옵션 생성 폼(action `POST /seller/products/{productId}/options`, 필드 `name`)·옵션값 생성 폼(action `.../options/{optionId}/values`, 필드 `value`), ③variant 목록 테이블(sku/price/stock/active/옵션라벨)·variant 생성 폼(action `.../variants`, 필드 `sku,price,stock,active,optionValueIds[]` — optionValueIds는 옵션값 체크박스/멀티선택), ④`fragments/messages`(flash). CSRF는 `th:action`로 자동. 에러 echo(`#fields.hasErrors`). 수정 폼 action `.../variants/{variantId}`.
- `templates/seller/product-form.html`(수정 화면, productId 존재 시)에 "옵션/Variant 관리" 링크(`/seller/products/{id}/variants`) 추가(사용성, 최소 변경). nav 전역 링크는 productId가 없어 추가하지 않음.
- 필요 시 `static/css/app.css`에 variants 표/폼 최소 스타일 추가(선택).

---

## 영향 범위 — 신규/수정 파일

### backend-implementor 담당
| 파일 | 종류 |
|---|---|
| `common/exception/{DuplicateOptionNameException,DuplicateOptionValueException,DuplicateSkuException,OptionNotFoundException,VariantNotFoundException}.java` | 신규 |
| `product/domain/{ProductOption,OptionValue,ProductVariant}.java` | 신규 |
| `product/repository/{ProductOptionRepository,OptionValueRepository,ProductVariantRepository}.java` | 신규 |
| `product/service/{ProductOptionService,ProductVariantService}.java` | 신규 |
| `product/service/{ProductOptionServiceResponse,ProductVariantServiceResponse}.java` | 신규 |
| `product/service/SellerProductVariantFacadeImpl.java` | 신규(비공개) |
| `product/service/ProductService.java` | 수정(`getOwnedProduct` 추출, getForEdit 위임) |
| `product/spi/SellerProductVariantFacade.java` | 신규(@NamedInterface 기존 spi) |
| `product/dto/{ProductOptionResponse,OptionValueResponse,ProductVariantResponse,VariantManagementView,SellerProductRef,ProductOptionCreateRequest,OptionValueCreateRequest,ProductVariantCreateRequest,ProductVariantUpdateRequest}.java` | 신규 |
| `product/controller/{SellerProductOptionRestController,SellerProductVariantRestController}.java` | 신규 |
| 테스트: `product/service/{ProductOptionServiceTest,ProductVariantServiceTest}`, `product/service/SellerProductVariantFacadeImplTest`, `product/controller/{SellerProductOptionRestControllerSecurityTest,SellerProductVariantRestControllerSecurityTest}` | 신규 |

### view-implementor 담당
| 파일 | 종류 |
|---|---|
| `web/product/SellerProductVariantViewController.java` | 신규 |
| `web/product/{OptionForm,OptionValueForm,VariantForm}.java` | 신규 |
| `templates/seller/product-variants.html` | 신규 |
| `templates/seller/product-form.html` | 수정(관리 링크) |
| `static/css/app.css` | 수정(선택) |
| 테스트: `web/product/SellerProductVariantViewControllerTest`, `view/SellerProductVariantsRenderingTest` | 신규 |

> SecurityConfig·Flyway·ModularityTests·WebModuleStructureTest **수정 불필요**(경로 prefix 기존 커버, 신규 코드가 기존 모듈 경계 규칙 자동 충족). 구조 테스트는 그대로 통과해야 하며, 통과 여부를 검증 단계에서 확인한다.

---

## 권한/소유권 (api-authorization-rule 준수)
- 경로 인가: REST `/api/v1/seller/**`·View `/seller/**` = `hasRole("SELLER")`(ADMIN 함의) — SecurityConfig 기존.
- 소유권+하위리소스: 모든 명령/조회가 `getOwnedProduct`(V12/V13) 후 optionId/variantId/optionValueId의 productId 소속(V6/V10/V11)을 검증. ADMIN은 소유권 스킵(전 상품 관리). 타 판매자 → 404.
- Entity 비노출: REST 응답·View 모델 모두 DTO만. variant 응답에 Entity 직접 노출 금지(Acceptance).

---

## 테스트 계획 (task Test 매핑)
### 단위(서비스, Mockito @Mock repo)
- ProductOptionServiceTest: 옵션 생성 성공 / 옵션명 중복(V1) / 옵션값 생성 성공 / 옵션값 중복(V2) / optionId가 productId 하위 아님(V10) / 소유권 실패(V12) / ADMIN 성공.
- ProductVariantServiceTest: variant 생성 성공 / SKU 중복(V3) / price 음수(V4) / stock 음수(V5) / 타 상품 optionValueId(V6) / 한 옵션 2값(V7) / 필수옵션 누락(V8) / 동일 조합 중복(V9) / variantId가 productId 하위 아님(V11) / 소유권 실패(V12) / ADMIN 전체 성공.
### facade 단위
- SellerProductVariantFacadeImplTest: email→userId 위임, 두 서비스 위임, Entity→DTO 매핑, isAdmin 전달.
### REST/Security(@SpringBootTest+MockMvc+JWT 토큰)
- 조회 SELLER 200 / ADMIN 200 / CONSUMER 403 / 비인증 401.
- 옵션 생성 성공·중복 409, 옵션값 생성 성공·중복 409, variant 생성 성공·검증 실패(400/409), 타 판매자 상품 접근 404, 하위리소스 불일치 404, Entity 미노출 단언.
### View(@SpringBootTest+MockMvc+@WithMockUser+facade @MockBean)
- `GET /seller/products/{productId}/variants` SELLER 렌더(뷰명/모델키 product·options·variants·optionForm·optionValueForm·variantForm) / CONSUMER 403 / 비인증 redirect / ADMIN 200.
- 폼 CSRF 포함, 옵션·옵션값·variant 생성 성공 redirect, @Valid 검증 실패 시 `seller/product-variants` 재렌더, BusinessException flashError redirect.

> 한계 명시: 테스트 프로파일이 DB를 제외하므로 새 Repository 쿼리(findByOption_ProductId 등)의 실제 SQL은 통합 검증되지 않는다(서비스 단위는 mock). 기존 프로젝트 자세와 동일하며, 실 DB 동작은 로컬 docker-compose 수동 확인 항목으로 보고한다.

---

## 작업 순서 (subagent-rule: backend → view)
1. **backend-implementor**: 예외 → Entity → Repository → Service(+ProductService.getOwnedProduct) → DTO → facade(interface/impl) → ServiceResponse → REST Controller → (단위/facade/REST 테스트). `./gradlew test`로 백엔드 범위 컴파일·통과 확인. **확정한 facade 시그니처·DTO 형태·model 키·form 필드명을 산출 보고**(view 계약).
2. **view-implementor**: Form(web/product) → ViewController(web/product) → 템플릿(product-variants.html + product-form 링크) → View 테스트. `./gradlew test` 전체 통과.
3. **reviewer → fixer** (최대 3회): plan 기준 스타일/보안/버그/모듈경계 리뷰.
4. 검증: `cd shop-core && ./gradlew test` 전체 통과(ModularityTests/WebModuleStructureTest 포함). 미확인(실 DB) 항목 보고.

---

## 인터페이스 계약 (backend ↔ view 정합 — 메인 확정)
- facade: 위 `SellerProductVariantFacade` 시그니처.
- 모델 키: `product`(SellerProductRef), `options`(List<ProductOptionResponse>), `variants`(List<ProductVariantResponse>), `optionForm`, `optionValueForm`, `variantForm`.
- 폼 필드: 옵션=`name`, 옵션값=`value`, variant=`sku,price,stock,active,optionValueIds`.
- URL/뷰: 화면 `GET /seller/products/{productId}/variants` → `seller/product-variants`; 폼 action 4종(옵션/옵션값/variant생성/variant수정); 성공/실패 redirect `/seller/products/{productId}/variants`.

---

## 리스크/주의
- **마이그레이션 추가 금지**(스키마 이미 존재) — 추가하면 V1과 충돌/중복.
- ProductVariant는 BaseEntity 비상속(updated_at 없음) — validate 모드에서 컬럼 불일치 방지.
- @ManyToMany 조인 테이블 소유측은 ProductVariant. 조합 비교(V9)는 optionValueId Set 동등성으로(순서 무관).
- 검증 우선순위: 소유권/하위리소스(404)를 중복/범위(400/409)보다 먼저 검사(존재 은닉·정보 노출 최소화).
- 다중 폼 한 화면: @Valid 실패 재렌더 시 세 폼 모두 모델에 존재해야 템플릿 NPE 없음(실패 폼만 에러 보유).
- web은 `product.spi`/`product.dto`/common(OPEN)/프레임워크만 의존(도메인 `domain`/`repository`/`service`·enum 직접 참조 금지) — WebModuleStructureTest로 보증.

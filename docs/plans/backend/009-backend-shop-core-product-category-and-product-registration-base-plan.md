# 009. shop-core 상품 카테고리 + 상품 등록 기반 — 구현 Plan

> 영역: backend + view (카테고리 조회/관리 REST API + 상품 등록/수정 REST API + 상품 등록/수정 Thymeleaf 화면 + product 도메인 첫 구현(Category·Product Entity/Repository/Service) + SELLER 이상 인가 + 상품 소유권 검사 + V3 마이그레이션 + 테스트)
> 대상 프로젝트: shop-core (product 모듈 신규 + security 인가 + 템플릿). notification 무관, 이벤트 계약 변경 없음.
> 작성일: 2026-06-04
> 상태: plan only (코드 변경 없음)
> revision: 포트-어댑터로 View principal 의존 역전(2026-06-04) — product가 `member`를 직접 참조하지 않도록 `product.spi.UserDirectory` 포트(@NamedInterface) 신설 + `member.adapter.MemberUserDirectoryAdapter` 어댑터로 의존 역전. product 모듈의 장차 외부 서비스 분리 의도 반영.
> 선행: Task 006(JWT 로그인 + Role hierarchy + REST/View 체인 분리), Task 008(`/api/v1/admin/**`·`/admin/**` hasRole ADMIN 인가, `common.dto.PageResponse`, View principal=email→userId 통일 패턴) 산출물 위에 **자립적으로** 구축한다. product 모듈은 현재 `package-info.java`만 존재(미구현)하므로 member 모듈을 패턴 레퍼런스로 삼는다.

---

## 구현 목표

`shop-core` `product` 모듈을 처음 구현한다. 카테고리(자기참조 트리)와 상품 기본 정보까지를 범위로 하며, 이후 상품 옵션·이미지·variant·재고·공개 목록/상세로 확장할 토대를 만든다.

- **카테고리**: 공개 조회 API(`GET /api/v1/categories`, flat 목록 + parentId 노출), ADMIN 전용 생성/수정 API(`POST`/`PATCH /api/v1/admin/categories[/{id}]`). slug 중복·parent 존재 검증은 `CategoryService` 도메인 로직 단일 소유.
- **상품**: SELLER 이상 등록/수정 REST API(`POST`/`PATCH /api/v1/seller/products[/{id}]`)와 Thymeleaf 등록/수정 화면(`GET /seller/products/new`, `GET /seller/products/{id}/edit`, `POST /seller/products[/{id}]`, view name `seller/product-form`). 기본 status `DRAFT`, `basePrice ≥ 0`, category 존재 검증.
- **소유권**: "판매자는 자기 상품만, ADMIN은 전체 수정"을 `ProductService` 도메인 규칙으로 검증(Controller에서 Repository 직접 조회 금지). 인가는 Spring Security 필터체인 path 기반(`/seller/**`, `/api/v1/seller/**` → `hasRole("SELLER")`, ADMIN은 RoleHierarchy로 함의)으로 처리한다.
- REST는 `RestController → ServiceResponse → Service → Repository`, View는 `ViewController → Service → Repository`로 레이어를 분리하고, 도메인 로직은 Service에 단일 소유한다. Entity는 응답·뷰모델에 직접 노출하지 않는다(DTO 분리).
- **모듈 분리 대비(포트-어댑터)**: View(form-login) 진입점이 principal(email)→userId 변환을 위해 `member`를 직접 호출하면 `product → member` 도메인 직접 의존이 생겨 product의 장차 외부 서비스 분리를 저해한다. 이를 **의존 역전**으로 끊는다 — product가 `com.shop.shop.product.spi.UserDirectory` 포트(@NamedInterface published port)를 소유하고, `member`가 `com.shop.shop.member.adapter.MemberUserDirectoryAdapter`로 구현한다. 의존 방향은 **member → product.spi** 단방향이며 **product는 member를 전혀 참조하지 않는다**. 분리 시 이 포트의 어댑터만 REST 호출 구현으로 교체하면 된다. (REST 진입점은 principal=userId(long)라 애초에 member 의존이 없다 — 결합은 오직 View에서만 발생했다.)

---

## 영향 범위

### 신규 파일 (main — Java)

**product.domain**
- `shop-core/src/main/java/com/shop/shop/product/domain/Category.java` — Category Entity(`@Entity @Table("categories")`, `id`/`parent`(자기참조 `@ManyToOne` nullable)/`name`/`slug`/`sortOrder`. **시간컬럼 없음** — V1 `categories`에 `created_at/updated_at` 없음, `BaseEntity` 미상속. Setter 금지·정적 팩토리·의도 노출 메서드)
- `shop-core/src/main/java/com/shop/shop/product/domain/Product.java` — Product Entity(`@Entity @Table("products")`, `BaseEntity` 상속(시간컬럼 읽기전용), `id`/`category`(`@ManyToOne` nullable)/`ownerId`(long, `owner_id` 컬럼 — V3 신규)/`name`/`description`/`basePrice`(BigDecimal)/`status`(`@Enumerated(STRING)`). Setter 금지·정적 팩토리·`update(...)`/`changeStatus(...)` 의도 노출 메서드)
- `shop-core/src/main/java/com/shop/shop/product/domain/ProductStatus.java` — 상품 상태 enum(`DRAFT, ON_SALE, SOLD_OUT, HIDDEN`. DB 저장값 = 상수명 대문자, V3 CHECK와 1:1)

**product.repository**
- `shop-core/src/main/java/com/shop/shop/product/repository/CategoryRepository.java` — `JpaRepository<Category, Long>` + `existsBySlug(String)` + `findAllByOrderBySortOrderAscIdAsc()`(flat 목록 정렬 조회)
- `shop-core/src/main/java/com/shop/shop/product/repository/ProductRepository.java` — `JpaRepository<Product, Long>`(기본 `findById`/`save` 활용, 별도 쿼리 불요)

**product.service**
- `shop-core/src/main/java/com/shop/shop/product/service/CategoryService.java` — `@Service @Transactional` 카테고리 도메인 로직(목록 조회·생성·수정, slug 중복·parent 존재 검증) 단일 소유
- `shop-core/src/main/java/com/shop/shop/product/service/ProductService.java` — `@Service @Transactional` 상품 도메인 로직(등록·수정, category 존재 검증·소유권 검사) 단일 소유. **순수 도메인 — `actorId(long)`/`actorIsAdmin(boolean)`을 인자로만 받으며 `member`/`UserDirectory` 포트조차 의존하지 않는다**(principal→userId 변환은 진입점 책임)
- `shop-core/src/main/java/com/shop/shop/product/service/CategoryServiceResponse.java` — REST 응답 조합 전용(ServiceResponse 레이어) — 목록/생성/수정
- `shop-core/src/main/java/com/shop/shop/product/service/ProductServiceResponse.java` — REST 응답 조합 전용 — 등록/수정(REST principal=userId(long) 추출)

**product.controller**
- `shop-core/src/main/java/com/shop/shop/product/controller/CategoryRestController.java` — `@RestController` `/api/v1/categories`(공개 조회 GET)
- `shop-core/src/main/java/com/shop/shop/product/controller/AdminCategoryRestController.java` — `@RestController` `/api/v1/admin/categories`(ADMIN 생성 POST·수정 PATCH)
- `shop-core/src/main/java/com/shop/shop/product/controller/SellerProductRestController.java` — `@RestController` `/api/v1/seller/products`(SELLER 등록 POST·수정 PATCH)
- `shop-core/src/main/java/com/shop/shop/product/controller/SellerProductViewController.java` — `@Controller` `/seller/products`(등록/수정 화면·폼 제출). **`UserDirectory` 포트를 주입**해 `findUserIdByEmail(auth.getName())`로 actorId 획득(member 직접 호출 없음) — **backend-implementor 작성**

**product.spi (신규 — published port / @NamedInterface)**
- `shop-core/src/main/java/com/shop/shop/product/spi/UserDirectory.java` — product가 소유하는 **포트(SPI) 인터페이스**. 시그니처 `long findUserIdByEmail(String email)`. product가 "사용자 디렉터리 조회"를 자기 포트로 추상화한다. Spring Modulith에서 `member`가 참조할 수 있도록 **@NamedInterface로 노출**(product의 published port). product 어느 클래스도 member를 참조하지 않는다. (해당 `spi` 패키지의 `package-info.java`에 `@org.springframework.modulith.NamedInterface("spi")` 적용 — 아래 §2/패키지 정합 참조.)
- `shop-core/src/main/java/com/shop/shop/product/spi/package-info.java` — `@NamedInterface("spi")` 선언(named interface 노출용). product 모듈의 published port 경계.

**member.adapter (신규 — member 모듈 소유, 의존 역전 어댑터)**
- `shop-core/src/main/java/com/shop/shop/member/adapter/MemberUserDirectoryAdapter.java` — **member 모듈이 소유하는 어댑터**. `implements com.shop.shop.product.spi.UserDirectory`, `@Component`(또는 `@Service`) 빈. 내부에서 `MemberService.getByEmail(email).getId()`에 위임. 의존 방향은 **member → product.spi(named interface)** 단방향이며, product는 member를 전혀 참조하지 않는다. (member 모듈 파일이 1개 추가됨 — member 모듈 소유로 분류.)

**product.dto**
- `shop-core/src/main/java/com/shop/shop/product/dto/CategoryResponse.java` — 카테고리 조회 항목 DTO(`record`, `from(Category)`, `categoryId`/`parentId`(nullable)/`name`/`slug`/`sortOrder` — flat 목록, Entity 미노출)
- `shop-core/src/main/java/com/shop/shop/product/dto/CategoryCreateRequest.java` — REST 생성 바디(`record`, `@NotBlank name`/`@NotBlank slug`/`Long parentId`(nullable)/`int sortOrder`)
- `shop-core/src/main/java/com/shop/shop/product/dto/CategoryUpdateRequest.java` — REST 수정 바디(`record`, `@NotBlank name`/`@NotBlank slug`/`Long parentId`/`int sortOrder`)
- `shop-core/src/main/java/com/shop/shop/product/dto/ProductCreateRequest.java` — REST 등록 바디(`record`, `Long categoryId`(nullable)/`@NotBlank name`/`String description`/`@NotNull @DecimalMin("0.0") BigDecimal basePrice`. status는 미수신 — 등록 시 항상 DRAFT)
- `shop-core/src/main/java/com/shop/shop/product/dto/ProductUpdateRequest.java` — REST 수정 바디(`record`, `Long categoryId`/`@NotBlank name`/`String description`/`@NotNull @DecimalMin("0.0") BigDecimal basePrice`/`@NotNull ProductStatus status`)
- `shop-core/src/main/java/com/shop/shop/product/dto/ProductResponse.java` — 상품 등록/수정 응답 DTO(`record`, `from(Product)`, `productId`/`categoryId`/`ownerId`/`name`/`description`/`basePrice`/`status`/`createdAt`/`updatedAt`, Entity 미노출)
- `shop-core/src/main/java/com/shop/shop/product/dto/ProductForm.java` — View 등록/수정 폼 백킹 객체(가변 class, `@Getter @Setter @NoArgsConstructor`, `Long categoryId`/`@NotBlank name`/`String description`/`@NotNull @DecimalMin("0.0") BigDecimal basePrice`/`ProductStatus status`. SignupForm 패턴 계승 — 검증 실패 재렌더 echo)

**common.exception (신규)**
- `shop-core/src/main/java/com/shop/shop/common/exception/CategoryNotFoundException.java` — 카테고리 없음(404), `BusinessException` 상속
- `shop-core/src/main/java/com/shop/shop/common/exception/DuplicateSlugException.java` — slug 중복(409), `BusinessException` 상속
- `shop-core/src/main/java/com/shop/shop/common/exception/ProductNotFoundException.java` — 상품 없음(404), `BusinessException` 상속
- `shop-core/src/main/java/com/shop/shop/common/exception/ProductAccessDeniedException.java` — 타인 상품 수정 시도(404 — §1.4 정보 노출 결정), `BusinessException` 상속

### 신규 파일 (main — 템플릿)
- `shop-core/src/main/resources/templates/seller/product-form.html` — 상품 등록/수정 화면(view name `seller/product-form`, `layout/base` 적용) — **view-implementor 작성**

### 신규 파일 (test)
- `shop-core/src/test/java/com/shop/shop/product/service/CategoryServiceTest.java` — 목록 조회, 생성 성공, slug 중복 실패, parent 미존재 실패, 수정 성공(단위, Mockito)
- `shop-core/src/test/java/com/shop/shop/product/service/ProductServiceTest.java` — 등록 성공(기본 DRAFT), category 미존재 실패, basePrice 음수 실패(서비스/Bean Validation 경계), 수정 성공, **소유권 검증 실패(타 판매자)**, ADMIN 전체 수정 성공(단위, Mockito)
- `shop-core/src/test/java/com/shop/shop/product/service/ProductServiceResponseTest.java` — REST principal(long) 추출 후 `ProductService` 위임, `ProductResponse` 매핑(Entity 미노출 단언)
- `shop-core/src/test/java/com/shop/shop/product/service/CategoryServiceResponseTest.java` — 목록→`List<CategoryResponse>` 매핑, 생성/수정 위임
- `shop-core/src/test/java/com/shop/shop/product/controller/CategoryRestControllerSecurityTest.java` — `GET /api/v1/categories` public 200, `POST/PATCH /api/v1/admin/categories` ADMIN 성공·SELLER/CONSUMER 403·비인증 401, slug 중복 409, parent 미존재 404
- `shop-core/src/test/java/com/shop/shop/product/controller/SellerProductRestControllerSecurityTest.java` — `POST /api/v1/seller/products` SELLER 성공·ADMIN 성공·CONSUMER 403·비인증 401, `PATCH /api/v1/seller/products/{id}` 소유자 성공·타 판매자 404·ADMIN 성공·미존재 404·basePrice 음수 400
- `shop-core/src/test/java/com/shop/shop/product/controller/SellerProductViewControllerTest.java` — `GET /seller/products/new` SELLER 렌더(view `seller/product-form`, model `productForm`/`categories`/`statuses`)·CONSUMER 403·비인증 /login redirect, 등록 폼 CSRF 포함, POST 성공 redirect, 검증 실패 시 `seller/product-form` 재렌더
- `shop-core/src/test/java/com/shop/shop/product/ProductWiringTest.java` — 운영 배선 회귀(신규 진입 빈 등록 단언, P1/testing-rule)

### 수정 파일
- `shop-core/src/main/java/com/shop/shop/security/SecurityConfig.java` — REST 체인 `/api/v1/seller/**` `hasRole("SELLER")`(`/api/v1/admin/**` hasRole ADMIN은 008 기존 유지, `/api/v1/categories` GET permitAll), View 체인 `/seller/**` `hasRole("SELLER")` 추가(`anyRequest()` 앞, 008 비파괴·가산적)
- `shop-core/src/main/resources/templates/fragments/nav.html` — `sec:authorize="hasRole('SELLER')"` 상품 등록 링크 추가('홈' 마커·`nav(active)` 시그니처·기존 ADMIN 링크 비파괴) — **view-implementor**
- `shop-core/src/main/resources/db/migration/V3__product_status_and_owner.sql` — **신규 마이그레이션**(아래 마이그레이션 절)
- `docs/entity/database_design.md` — §4.2 `products` 표에 `owner_id` 컬럼 추가 메모 + status CHECK 대문자 정합(V3) 메모(§1.5)

### 마이그레이션 — **V3 신규 (`V3__product_status_and_owner.sql`)**
- **사유 1 (status CHECK 대문자 정합)**: V1 `products.status` CHECK는 `('draft','on_sale','sold_out','hidden')`(소문자)다. Java enum `ProductStatus{DRAFT,ON_SALE,SOLD_OUT,HIDDEN}` + `@Enumerated(STRING)`은 **대문자 상수명**을 저장하므로 불일치한다. V2가 `users.role`을 소문자→대문자로 교체한 것과 **동일 패턴**으로 V3가 `products.status` CHECK·DEFAULT를 대문자로 교체한다(V1 불변·checksum 보호 준수).
- **사유 2 (owner_id 추가)**: V1 `products`에는 판매자/소유자 컬럼이 없다. Task의 "생성자 기록"·"판매자는 자기 상품만 수정"을 위해 `owner_id bigint REFERENCES users(id)` 컬럼을 V3에서 추가한다.
- **V3 DDL 스케치**:
  ```sql
  -- V3__product_status_and_owner.sql — products.status 대문자 정합 + owner_id 추가
  -- [V1/V2 불변] V1·V2는 checksum 보호. 변경은 이 V3로만.

  -- 1) status CHECK 대문자 교체 (V2 users.role 패턴 계승)
  ALTER TABLE products DROP CONSTRAINT IF EXISTS products_status_check;
  UPDATE products SET status = upper(status);   -- 기존 행(소문자) → 대문자
  ALTER TABLE products
      ADD CONSTRAINT products_status_check
      CHECK (status IN ('DRAFT', 'ON_SALE', 'SOLD_OUT', 'HIDDEN'));
  -- DEFAULT: V1엔 status DEFAULT 없음 → 등록 기본 DRAFT는 애플리케이션(ProductService)이 강제

  -- 2) owner_id 추가 (판매자/소유자 식별 — users.id 참조)
  ALTER TABLE products
      ADD COLUMN owner_id bigint REFERENCES users (id) ON DELETE RESTRICT;
  CREATE INDEX idx_products_owner_id ON products (owner_id);
  ```
- **owner_id nullable 결정**: V3에서 NULL 허용으로 추가한다. 근거: V1에 데이터가 있다면 NOT NULL 추가가 깨지고, 본 Task는 백필 시드가 없다(008과 동일하게 ADMIN/상품 시드 부재). **애플리케이션 레벨에서 등록 시 항상 ownerId를 채움**(ProductService가 강제)으로 실질 NOT NULL을 보장하고, DB NOT NULL 강제는 데이터·시드 정비 후 후속 마이그레이션으로 검토한다(과설계·마이그레이션 실패 회피).
- **category_id**: V1에서 이미 `category_id bigint REFERENCES categories(id) ON DELETE SET NULL`(nullable)로 존재 → V3 변경 불요. Entity는 nullable `@ManyToOne`으로 매핑.
- **시간컬럼/트리거**: `products`는 V1에 `created_at/updated_at` + `trg_products_set_updated_at` 트리거가 이미 존재 → V3 추가 불요. `categories`는 시간컬럼이 없으므로 Category Entity는 BaseEntity 미상속.

### 범위 밖 (명시적 제외 — YAGNI / Task Constraints)
- 상품 이미지 업로드/저장(`product_images`·`ObjectStorage`), 상품 옵션·option value·variant·재고(`product_options`/`option_values`/`product_variants`/`variant_values`)
- 공개 상품 목록/상세 화면(후속 Task)
- 카테고리 삭제, 상품 삭제(Constraint)
- 상품 status 워크플로(승인·강제 변경 등 ADMIN 전용 상태 전이 규칙) — 본 Task는 SELLER가 status 필드를 직접 수정하는 범위까지만
- 시드 SELLER/카테고리/상품 데이터 생성 코드(로컬 수동 검증은 docker PG 직접 INSERT로 대체, §5.6)
- `products` 검색/필터/페이지네이션 REST(공개 목록 후속), 판매자 본인 상품 목록 화면

### 패키지 규칙 정합 + 후속 보강 제안 (범위 메모)
- `product.spi`(포트)·`member.adapter`(어댑터)는 `package-structure-rule.md`의 표준 모듈 패키지 목록(controller/service/repository/domain/dto/event/messaging)에 **없다**. 다음 두 근거로 정당화한다.
  - **(a) architecture-rule 정합**: architecture-rule "동기 조회가 꼭 필요하면 각 모듈이 노출한 **published API(named interface/port)**를 통해서만 호출한다. 비공개 구현에는 접근하지 않는다."를 그대로 구현한 것이다. `product.spi.UserDirectory`는 product의 published port(@NamedInterface)이고, `member.adapter`는 그 포트의 구현(어댑터)으로 의존 역전을 실현한다. 모듈 경계 데이터는 스칼라(`String email`/`long userId`)라 Entity 모듈 밖 노출 0.
  - **(b) package-structure-rule 보강 제안(후속 — 이번 plan에서 규칙 파일 자체를 수정하지는 않는다)**: `package-structure-rule.md` "모듈별 반복" 목록에 다음 한 줄을 보강할 것을 후속 제안으로 남긴다 — **"모듈 published port = `{module}/spi`(@NamedInterface), 외부 모듈이 그 포트를 구현하는 어댑터 = `{module}/adapter`."** (규칙 파일 수정은 별도 task에서 처리.)

---

## API Authorization (Task 표 반영)

| API | 공개 여부 | 최소 권한 | 상위 권한 허용 | 소유권 검사 | 인가 위치 |
|---|---|---|---|---|---|
| `GET /api/v1/categories` | public | 없음 | — | 불필요 | SecurityConfig REST 체인 permitAll |
| `POST /api/v1/admin/categories` | authenticated | `ROLE_ADMIN` | 없음 | 불필요 | REST 체인 `/api/v1/admin/**` hasRole ADMIN(008 기존) |
| `PATCH /api/v1/admin/categories/{id}` | authenticated | `ROLE_ADMIN` | 없음 | 불필요 | 동상 |
| `POST /api/v1/seller/products` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 생성자 기록 | REST 체인 `/api/v1/seller/**` hasRole SELLER(V3 신규 매처) |
| `PATCH /api/v1/seller/products/{id}` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요(Service) | 동상 + ProductService 소유권 |
| `GET /seller/products/new` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 불필요 | View 체인 `/seller/**` hasRole SELLER |
| `POST /seller/products` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 생성자 기록 | 동상 |
| `GET /seller/products/{id}/edit` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요(Service) | 동상 + ProductService 소유권 |
| `POST /seller/products/{id}` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요(Service) | 동상 + ProductService 소유권 |

- `hasRole("SELLER")` + 006 `RoleHierarchy`(ROLE_ADMIN > ROLE_SELLER > ROLE_CONSUMER) 결합으로 **SELLER·ADMIN 통과, CONSUMER 차단**(상위만 하위 함의 — api-authorization-rule).
- 권한 판단을 Controller 비즈니스 로직(문자열 비교)으로 처리하지 않는다 — Security 설정 + Service 소유권 규칙에 위임.

---

## 1. 설계 방식 및 이유

### 1.1 인가 적용 방식 — 필터체인 path 기반(`hasRole`), 008 매처에 가산적
- **결정**: 008의 두 체인 `authorizeHttpRequests`에 매처를 `anyRequest()` **앞에** 가산 추가한다.
  - REST 체인(@Order(1), `/api/v1/**`):
    - `.requestMatchers(HttpMethod.GET, "/api/v1/categories").permitAll()`(공개 조회)
    - `.requestMatchers("/api/v1/seller/**").hasRole("SELLER")`(상품 등록/수정 — ADMIN 함의)
    - `/api/v1/admin/**` hasRole ADMIN은 **008 기존 매처 그대로**(카테고리 관리가 `/api/v1/admin/categories`로 그 아래 포함 — 신규 매처 불요).
  - View 체인(@Order(2)): `.requestMatchers("/seller/**").hasRole("SELLER")`(상품 화면 — ADMIN 함의).
- **충돌·중복 점검(Task 요구)**: `/api/v1/admin/**`(008)와 신규 `/api/v1/seller/**`·`/api/v1/categories`는 **경로 prefix가 서로 배타적**이라 매처 충돌이 없다. `permitAll`(GET categories)은 `authenticated`/`hasRole`보다 **먼저** 선언해 우선 매칭되게 둔다(매처는 선언 순서대로 평가). 008 `SecurityConfigTest`·`AuthRestControllerSecurityTest`·`AdminMemberRestControllerSecurityTest`는 admin/auth 경로만 검증하므로 가산 매처에 비파괴.
- **실패 표현은 체인별로 분리**(006/008 계승): REST 비인증→401 `RestAuthenticationEntryPoint`(JSON), 권한부족→403 `RestAccessDeniedHandler`(JSON). View 비인증→`/login` redirect, 권한부족→403(View 체인 기본).
- **`@PreAuthorize` 미채택(기본)**: 엔드포인트 단위 권한이 단순(카테고리=ADMIN, 상품=SELLER)하므로 path 기반으로 충분(008 일관, YAGNI). 단 **소유권**은 path 매처로 표현 불가하므로 §1.4 Service 규칙으로 분리한다.

### 1.2 Category 도메인 — flat 목록 응답 결정 + 생성/수정 불변식
- **응답 형태 결정 — flat 목록(택1, Task Requirement)**: `GET /api/v1/categories`는 **flat `List<CategoryResponse>`**(각 항목에 `parentId` 노출)로 응답한다. 트리(중첩 children) 대신 flat을 채택.
  - 근거: (1) 본 Task의 1차 소비처는 **상품 폼의 카테고리 셀렉트**(View `categories` 모델)로 평면 목록이면 충분하다. (2) 트리 조립은 N+1/재귀 직렬화·깊이 제어 등 표면이 늘어 과설계(YAGNI). (3) flat + `parentId`면 클라이언트가 필요 시 트리를 조립할 수 있어 정보 손실이 없다. (4) 정렬은 `sortOrder ASC, id ASC`로 안정 정렬.
  - **응답 DTO 명시**: `CategoryResponse(long categoryId, Long parentId, String name, String slug, int sortOrder)`. `parentId`는 root 카테고리에서 null. Entity(`Category.parent`) 직접 노출 금지 — `from(Category)`에서 `c.getParent()==null ? null : c.getParent().getId()`로 변환.
- **`CategoryService` 불변식**(`@Transactional` 쓰기, REST/View 공유, Controller 로직 금지):
  - `createCategory(name, slug, parentId, sortOrder)`:
    1. **slug 중복 검증**: `categoryRepository.existsBySlug(slug)` → 있으면 `DuplicateSlugException`(409).
    2. **parent 존재 검증**: `parentId != null`이면 `categoryRepository.findById(parentId)` → 없으면 `CategoryNotFoundException`(404). null이면 root.
    3. 저장: `Category.of(name, slug, parent, sortOrder)`.
  - `updateCategory(categoryId, name, slug, parentId, sortOrder)`:
    1. 대상 존재: `findById(categoryId)` → 없으면 `CategoryNotFoundException`(404).
    2. slug 변경 시 중복 검증: **자기 자신 제외**(`existsBySlugAndIdNot(slug, categoryId)` 또는 조회 후 비교) — 동일 slug 유지는 통과.
    3. parent 존재 검증(있으면). **자기참조 사이클 방지**(parent==self 금지)는 본 Task에서 직접 부모만 차단(깊은 사이클 탐지는 범위 밖·YAGNI — 메모).
    4. `category.update(name, slug, parent, sortOrder)`(의도 노출 메서드, dirty checking).
  - `listCategories()`(`@Transactional(readOnly=true)`): `findAllByOrderBySortOrderAscIdAsc()` → `List<Category>`(Service는 Entity 반환, DTO 변환은 ServiceResponse/ViewController가 수행 — member 패턴 계승).

### 1.3 Product 도메인 — 등록/수정 + category 검증
- **Entity 필드 결정**:
  - `category`: **nullable `@ManyToOne`**(V1 `category_id` nullable·`ON DELETE SET NULL`과 정합). 미분류 상품 허용. category 지정 시 존재 검증.
  - `ownerId`: **`long` 스칼라**(`@Column("owner_id")`)로 보유한다. `User`를 `@ManyToOne`으로 잡지 않는 이유: product→member **모듈 경계**를 넘는 Entity 직접 참조를 피하고(architecture-rule "Entity를 모듈 밖으로 노출하지 않는다"), 소유권은 `ownerId == actorId` 비교로 충분하기 때문. FK 무결성은 DB(`REFERENCES users(id)`)가 보장.
  - `name`(NOT NULL), `description`(nullable text), `basePrice`(`BigDecimal`, `numeric(12,2)`, ≥0), `status`(`@Enumerated(STRING) ProductStatus`, 기본 DRAFT).
- **`ProductService` 메서드**(`@Transactional` 쓰기):
  - `register(long ownerId, Long categoryId, String name, String description, BigDecimal basePrice)`:
    1. `basePrice` 음수 방어(Bean Validation이 1차, Service가 2차 — `basePrice.signum() < 0` → `BusinessException`(400)).
    2. category 존재 검증: `categoryId != null`이면 `categoryRepository.findById` → 없으면 `CategoryNotFoundException`(404).
    3. 저장: `Product.create(ownerId, category, name, description, basePrice)` — **status는 항상 `DRAFT` 강제**(요청에서 status 미수신).
  - `update(long actorId, boolean actorIsAdmin, long productId, Long categoryId, String name, String description, BigDecimal basePrice, ProductStatus status)`:
    1. 대상 존재: `findById(productId)` → 없으면 `ProductNotFoundException`(404).
    2. **소유권 검사(§1.4)**: `!actorIsAdmin && product.getOwnerId() != actorId` → `ProductAccessDeniedException`(404).
    3. category 존재 검증(있으면).
    4. basePrice 음수 방어.
    5. `product.update(category, name, description, basePrice, status)`(의도 노출 메서드, dirty checking).
  - `getForEdit(long actorId, boolean actorIsAdmin, long productId)`(`@Transactional(readOnly=true)`): 수정 화면용 단건 조회 + 소유권 검사(타인 상품 edit 화면 차단). → `Product`(DTO/Form 변환은 호출측).
- **status 직접 수정 허용 범위**: 본 Task는 SELLER가 `ProductUpdateRequest.status`로 DRAFT/ON_SALE/SOLD_OUT/HIDDEN을 자유 전이하는 범위까지(상태 전이 규칙·ADMIN 승인 워크플로는 범위 밖, §범위 밖). enum 미정의 값은 역직렬화 400.

### 1.4 소유권 검사 — Service 단일 소유 + 타인 리소스 404 결정
- **위치**: 소유권은 `ProductService.update`/`getForEdit`에 **도메인 규칙**으로 단일 소유한다. Controller/ViewController는 Repository를 직접 조회해 소유권을 판단하지 않는다(api-authorization-rule 금지·forbidden-rule). `actorIsAdmin`은 진입점(SecurityContext authority)에서 판정해 Service로 전달 — Service는 인증 인프라를 모른 채 boolean 플래그로 분기.
- **타인 상품 접근 시 403 vs 404 — 404 결정**: 소유자가 아닌 SELLER가 타인 상품을 수정/조회하면 **404 `ProductAccessDeniedException`**(`HttpStatus.NOT_FOUND`)로 응답한다.
  - 근거(정보 노출 관점): 403은 "그 ID의 상품이 존재한다"는 사실을 노출해 리소스 열거(enumeration)에 악용될 수 있다. **존재하지만 소유하지 않은 리소스를 "없는 것처럼"** 다루면 존재 여부 자체를 숨겨 더 보수적이다. 미존재(`ProductNotFoundException`)와 타인 소유 모두 404로 통일해 두 경우를 외부에서 구분 불가하게 한다.
  - api-authorization-rule "다른 사용자의 리소스 접근은 403 또는 404"를 충족(택1). Acceptance "403 또는 404로 실패한다"와 정합.
  - ADMIN은 함의로 전체 접근 가능하므로 404를 받지 않는다(`actorIsAdmin=true`면 소유권 분기 스킵).
- **principal 통일(REST vs View — 008 §1.3 계승, View는 포트-어댑터로 의존 역전)**:
  - **REST**(JWT 필터): principal = userId(long). `ProductServiceResponse`가 `(long) authentication.getPrincipal()`로 `ownerId`/`actorId` 추출(008 `AuthServiceResponse.me`·`AdminMemberServiceResponse` 동일 규약). **member 의존 없음**(principal에 이미 userId가 있어 디렉터리 조회 불요 — 포트도 쓰지 않는다). `actorIsAdmin`은 `auth.getAuthorities()`에 `ROLE_ADMIN` 포함 여부로 판정(RoleHierarchy로 ADMIN은 ROLE_SELLER도 보유하나 **원본 ROLE_ADMIN** 직접 보유 확인).
  - **View**(form login 세션): principal = `UserDetails`(username=email). `SellerProductViewController`가 `auth.getName()` → **`userDirectory.findUserIdByEmail(email)`**(product 소유 포트)로 `actorId` 통일. 어댑터(`member.adapter.MemberUserDirectoryAdapter`)가 내부에서 `memberService.getByEmail(email).getId()`에 위임하므로 **View 컨트롤러는 member를 직접 참조하지 않는다**(의존 역전 — product는 member 미참조, member→product.spi 단방향). 인증된 세션의 email은 항상 존재하는 사용자이므로 미존재는 발생하지 않는 가정이며, 방어적으로 미존재 시 어댑터가 **`IllegalStateException`**(인증 세션과 회원 디렉터리 불일치 = 시스템 불변식 위반, 클라이언트 입력 오류가 아님)을 던진다. `actorIsAdmin`은 동일하게 authority(`ROLE_ADMIN` 직접 보유)로 판정.
  - 이 REST/View principal 차이(REST=userId 직접, View=포트로 email→userId 변환)를 §8 계약·주석에 명시한다.

### 1.5 DTO/응답 — Entity 미노출, 금액 BigDecimal
- `CategoryResponse`/`ProductResponse`는 `record` + `from(Entity)` 정적 팩토리. `Category.parent`/`Product.category`를 직접 노출하지 않고 **id로 평탄화**(`parentId`/`categoryId`). `Product.ownerId`는 응답에 포함(소유자 확인용, 민감정보 아님).
- 금액 `basePrice`는 전 구간 `BigDecimal`(요청 DTO·Entity·응답). 부동소수점 금지(database_design §5.9). 검증: `@NotNull @DecimalMin(value="0.0") BigDecimal basePrice`(요청/폼) + Service 2차 `signum()` 방어.
- `ProductStatus`는 응답·폼에 **enum** 그대로(직렬화 시 상수명 문자열). 폼 셀렉트 옵션 목록은 `statuses` 모델 키로 `ProductStatus.values()` 전달.
- `createdAt`/`updatedAt`은 `Product` `BaseEntity` getter 타입(`Instant`)에 정합(006/008 DB 소유 읽기전용).
- Entity를 API 응답·View 모델에 직접 전달 금지(architecture-rule/forbidden-rule) — 항상 DTO 변환.

### 1.6 레이어 분리 (REST vs View, 도메인 로직 단일 소유)
- **공통 도메인 로직**: `CategoryService`(목록/생성/수정 + slug·parent 불변식), `ProductService`(등록/수정 + category 검증·소유권)에 단일 소유. Repository는 여기서만 호출.
- **REST 레이어**: `*RestController(@RestController)` → `*ServiceResponse`(ServiceResponse, REST 전용) → `*Service` → `*Repository`.
  - `CategoryRestController.list()`(GET `/api/v1/categories`) → `categoryServiceResponse.list()` → `List<CategoryResponse>`(200).
  - `AdminCategoryRestController.create()`(POST `/api/v1/admin/categories`, `@Valid @RequestBody CategoryCreateRequest`) → `categoryServiceResponse.create(req)` → 200 `CategoryResponse`. (생성도 200 OK — 기존 008 컨벤션 일관, 승인 결정)
  - `AdminCategoryRestController.update()`(PATCH `/{id}`, `@Valid @RequestBody CategoryUpdateRequest`) → `categoryServiceResponse.update(id, req)` → 200.
  - `SellerProductRestController.register()`(POST `/api/v1/seller/products`, `@Valid @RequestBody ProductCreateRequest`, `Authentication`) → `productServiceResponse.register(auth, req)` → 200 `ProductResponse`.
  - `SellerProductRestController.update()`(PATCH `/{id}`, `@Valid @RequestBody ProductUpdateRequest`, `Authentication`) → `productServiceResponse.update(auth, id, req)` → 200. Controller 비즈니스 로직 금지.
- **View 레이어**: `SellerProductViewController(@Controller)` → `ProductService`/`CategoryService` 직접(ServiceResponse 미사용 — architecture-rule) + `UserDirectory` 포트(email→actorId). 모델엔 DTO/ViewModel·enum·폼 객체만(Entity 금지).
  - `GET /seller/products/new`: 빈 `ProductForm` + `categories`(`List<CategoryResponse>`) + `statuses`(`ProductStatus.values()`) → view `seller/product-form`.
  - `POST /seller/products`: `@Valid @ModelAttribute("productForm") ProductForm form`, `BindingResult`, `Authentication`, `RedirectAttributes`:
    - 검증 실패 → `categories`/`statuses` 재주입 → `seller/product-form` 재렌더(입력값·메시지 유지, SignupForm 패턴).
    - 성공 → `actorId = userDirectory.findUserIdByEmail(auth.getName())`(포트 — member 직접 호출 0) → `productService.register(...)` → `redirect:/seller/products/{id}/edit`(Backend-View Contract 성공 redirect).
  - `GET /seller/products/{id}/edit`: `productService.getForEdit(actorId, isAdmin, id)`(소유권 검사) → `ProductForm`(Entity→Form 변환) + `categories` + `statuses` → view `seller/product-form`. 타인/미존재 → 404(ViewExceptionHandler `error/error`).
  - `POST /seller/products/{id}`: `@Valid ProductForm` + `BindingResult` + `Authentication` → 검증 실패 재렌더 / 성공 시 `productService.update(...)` → `redirect:/seller/products/{id}/edit`.

---

## 2. 구성 요소

### main — product.domain (신규)

**`Category`** (`@Entity @Table("categories")`, BaseEntity 미상속 — 시간컬럼 없음)
```java
@Entity @Table(name = "categories") @Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
public class Category {
    @Id @GeneratedValue(strategy = GenerationType.IDENTITY) private Long id;
    @ManyToOne(fetch = FetchType.LAZY) @JoinColumn(name = "parent_id") private Category parent; // nullable
    @Column(nullable = false) private String name;
    @Column(nullable = false, unique = true) private String slug;
    @Column(name = "sort_order", nullable = false) private int sortOrder;

    public static Category of(String name, String slug, Category parent, int sortOrder) { ... }
    public void update(String name, String slug, Category parent, int sortOrder) { ... } // setter 금지
}
```

**`Product`** (`@Entity @Table("products")`, BaseEntity 상속)
```java
@Entity @Table(name = "products") @Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
public class Product extends BaseEntity {
    @Id @GeneratedValue(strategy = GenerationType.IDENTITY) private Long id;
    @ManyToOne(fetch = FetchType.LAZY) @JoinColumn(name = "category_id") private Category category; // nullable
    @Column(name = "owner_id") private Long ownerId;  // V3 신규, users.id 참조(스칼라 — 모듈 경계)
    @Column(nullable = false) private String name;
    @Column private String description;
    @Column(name = "base_price", nullable = false) private BigDecimal basePrice;
    @Enumerated(EnumType.STRING) @Column(nullable = false, length = 20) private ProductStatus status;

    public static Product create(long ownerId, Category category, String name, String description, BigDecimal basePrice) {
        // status = DRAFT 강제
    }
    public void update(Category category, String name, String description, BigDecimal basePrice, ProductStatus status) { ... }
}
```

**`ProductStatus`** enum: `DRAFT, ON_SALE, SOLD_OUT, HIDDEN`(상수명 = DB 저장값, V3 CHECK 1:1).

### main — product.repository (신규)
- `CategoryRepository extends JpaRepository<Category, Long>`: `boolean existsBySlug(String slug)`, `boolean existsBySlugAndIdNot(String slug, Long id)`(수정 시 자기 제외), `List<Category> findAllByOrderBySortOrderAscIdAsc()`.
- `ProductRepository extends JpaRepository<Product, Long>`: 기본 `findById`/`save` 활용(추가 쿼리 불요).

### main — product.service (신규)
- **`CategoryService`**(`@Service @RequiredArgsConstructor @Transactional`): `list()`/`createCategory(...)`/`updateCategory(...)` — §1.2 불변식 단일 소유. `CategoryRepository`만 의존.
- **`ProductService`**(`@Service @RequiredArgsConstructor @Transactional`): `register(...)`/`update(...)`/`getForEdit(...)` — §1.3/§1.4 단일 소유. `ProductRepository`·`CategoryRepository`만 의존(category 존재 검증). **순수 도메인 — `actorId`/`actorIsAdmin`은 인자로만 받으며 `member`도, `UserDirectory` 포트도 의존하지 않는다**(principal→userId 변환은 진입점=ViewController·ServiceResponse 책임).
- **`CategoryServiceResponse`**(`@Service`, REST 전용): `List<CategoryResponse> list()` / `CategoryResponse create(CategoryCreateRequest)` / `CategoryResponse update(long id, CategoryUpdateRequest)` — `CategoryService` 위임 + DTO 변환.
- **`ProductServiceResponse`**(`@Service`, REST 전용): `register(Authentication auth, ProductCreateRequest req)` → `(long)principal`·isAdmin 추출 → `ProductService.register` → `ProductResponse`. `update(Authentication auth, long id, ProductUpdateRequest req)` 동일.

### main — product.controller (신규)
- `CategoryRestController(@RestController @RequestMapping("/api/v1/categories"))`: `GET ""` → 200 `List<CategoryResponse>`.
- `AdminCategoryRestController(@RestController @RequestMapping("/api/v1/admin/categories"))`: `POST ""`(@Valid body) → 200; `PATCH "/{categoryId}"`(@Valid body) → 200.
- `SellerProductRestController(@RestController @RequestMapping("/api/v1/seller/products"))`: `POST ""`(@Valid body, Authentication) → 200; `PATCH "/{productId}"`(@Valid body, Authentication) → 200. 비즈니스 로직 없음.
- `SellerProductViewController(@Controller @RequestMapping("/seller/products"))` — backend-implementor: `GET /new`, `POST ""`, `GET /{id}/edit`, `POST /{id}`(§1.6). 모델 키 `productForm`/`categories`/`statuses`, view `seller/product-form`, redirect `/seller/products/{id}/edit`, flash 불요(검증 실패는 재렌더, PRG 성공은 edit 화면 진입). **의존: `ProductService`·`CategoryService`·`UserDirectory`(포트)** — `userDirectory.findUserIdByEmail(auth.getName())`로 actorId 통일(member 직접 호출 없음). 포트 사용처는 product 내에서 이 컨트롤러뿐.

### main — product.spi (신규 — published port / @NamedInterface)
- **`UserDirectory`**(인터페이스, product 소유): `long findUserIdByEmail(String email)`. product가 "사용자 디렉터리 조회"를 추상화한 포트. 구현은 product 밖(member 어댑터)에 있고, product는 이 인터페이스만 의존한다. Spring Modulith named interface로 노출돼 member가 참조 가능.
  ```java
  // com.shop.shop.product.spi.UserDirectory  (포트 — product 소유)
  public interface UserDirectory {
      /** 인증된 세션의 email로 userId 조회. 인증 세션의 email은 항상 존재 가정;
       *  미존재 시 구현이 IllegalStateException(시스템 불변식 위반). */
      long findUserIdByEmail(String email);
  }
  ```
- **`product/spi/package-info.java`**: `@NamedInterface("spi")`로 포트 패키지를 published named interface로 노출.
  ```java
  @org.springframework.modulith.NamedInterface("spi")
  package com.shop.shop.product.spi;
  ```

### main — member.adapter (신규 — member 모듈 소유, 의존 역전 어댑터)
- **`MemberUserDirectoryAdapter`**(`@Component`, member 소유) `implements com.shop.shop.product.spi.UserDirectory`: `findUserIdByEmail(email)` → `memberService.getByEmail(email).getId()` 위임. 의존 방향 **member → product.spi**(named interface). product는 member를 전혀 참조하지 않는다.
  ```java
  // com.shop.shop.member.adapter.MemberUserDirectoryAdapter  (어댑터 — member 소유)
  @Component @RequiredArgsConstructor
  public class MemberUserDirectoryAdapter implements UserDirectory {
      private final MemberService memberService;
      @Override public long findUserIdByEmail(String email) {
          return memberService.getByEmail(email).getId(); // 미존재 시 도메인 예외(IllegalStateException 가정)
      }
  }
  ```

### main — product.dto (신규)
- `CategoryResponse`(record, `categoryId`/`parentId`/`name`/`slug`/`sortOrder`, `from(Category)`).
- `CategoryCreateRequest`/`CategoryUpdateRequest`(record, `@NotBlank name`/`@NotBlank slug`/`Long parentId`/`int sortOrder`).
- `ProductCreateRequest`(record, `Long categoryId`/`@NotBlank name`/`String description`/`@NotNull @DecimalMin("0.0") BigDecimal basePrice`).
- `ProductUpdateRequest`(record, 위 + `@NotNull ProductStatus status`).
- `ProductResponse`(record, `productId`/`categoryId`/`ownerId`/`name`/`description`/`basePrice`/`status`/`createdAt`/`updatedAt`, `from(Product)`).
- `ProductForm`(가변 class, `@Getter @Setter @NoArgsConstructor`, `categoryId`/`name`/`description`/`basePrice`/`status` + Bean Validation — SignupForm 패턴).

### main — common.exception (신규)
- `CategoryNotFoundException extends BusinessException` — `super("카테고리를 찾을 수 없습니다. id="+id, HttpStatus.NOT_FOUND)`(404).
- `DuplicateSlugException extends BusinessException` — `super("이미 사용 중인 slug입니다.", HttpStatus.CONFLICT)`(409).
- `ProductNotFoundException extends BusinessException` — `super("상품을 찾을 수 없습니다. id="+id, HttpStatus.NOT_FOUND)`(404).
- `ProductAccessDeniedException extends BusinessException` — `super("상품을 찾을 수 없습니다. id="+id, HttpStatus.NOT_FOUND)`(404 — §1.4 정보 노출 결정. 메시지는 NotFound와 동일 톤으로 존재 은닉).

### main — security (수정)
**`SecurityConfig`**
- REST 체인 `authorizeHttpRequests`(`anyRequest().authenticated()` 앞, admin 매처 부근): `.requestMatchers(HttpMethod.GET, "/api/v1/categories").permitAll()` → `.requestMatchers("/api/v1/seller/**").hasRole("SELLER")` 추가. `/api/v1/admin/**` hasRole ADMIN은 008 그대로(카테고리 관리 포함).
- View 체인: `.requestMatchers("/seller/**").hasRole("SELLER")` 추가(`/admin/**` ADMIN 008 그대로).
- RoleHierarchy/엔트리포인트/denied/JWT/formLogin/CSRF는 006·008 그대로(비파괴).

### main — 템플릿 (view-implementor 작성)
**`templates/seller/product-form.html`**(신규)
- 레이아웃: **`layout/base`**(인증 화면, nav 포함). 기존 base `layout(title, content)` 시그니처 준수.
- 폼: `<form method="post" th:action="@{...}" th:object="${productForm}">`. **등록/수정 action 분기**: 등록은 `@{/seller/products}`, 수정은 `@{/seller/products/{id}(id=...)}`. `th:action` 사용으로 `_csrf` 히든 자동 주입(View 체인 CSRF 활성 — 수동 추가 금지).
- 필드(폼 필드명 계약): `categoryId`(셀렉트, `categories` 반복 + "미분류" 빈 옵션), `name`(text), `description`(textarea), `basePrice`(number step), `status`(셀렉트, `statuses` 반복 — **등록 화면은 status 입력 숨김/무시**, 수정 화면만 노출). 각 필드 `th:errors`로 검증 메시지 echo, `th:field`로 입력값 유지.
- 메시지: 검증 실패는 필드별 `#fields.hasErrors` echo(SignupForm 패턴). flash 불요(성공은 edit redirect).
- 민감정보 미표시.

**`templates/fragments/nav.html`**(수정 — view-implementor)
- 기존 '홈' 링크·ADMIN '회원 관리' 링크 **보존** + `<li sec:authorize="hasRole('SELLER')"><a th:href="@{/seller/products/new}">상품 등록</a></li>` 추가(RoleHierarchy로 SELLER·ADMIN 노출). `nav(active)` 시그니처·기존 마커 비파괴(LayoutRenderingTest).

### test — §5

---

## 3. 데이터 흐름

### 3.1 공개 카테고리 조회 (REST)
```
GET /api/v1/categories            (인증 불요)
  → REST 체인: /api/v1/categories GET permitAll 통과
  → CategoryRestController.list → CategoryServiceResponse.list
       → CategoryService.list() → findAllByOrderBySortOrderAscIdAsc() → List<Category>
       → map(CategoryResponse::from)  (Entity → DTO, parentId 평탄화)
  → 200 List<CategoryResponse>[{categoryId,parentId,name,slug,sortOrder}, ...]
```

### 3.2 ADMIN 카테고리 생성/수정 (REST)
```
POST /api/v1/admin/categories  {name,slug,parentId?,sortOrder}  Bearer{ROLE_ADMIN}
  → /api/v1/admin/** hasRole ADMIN 통과(008)
  → AdminCategoryRestController.create → CategoryServiceResponse.create
       → CategoryService.createCategory: existsBySlug? (있으면 409 DuplicateSlug)
            → parentId 존재 검증(없으면 404 CategoryNotFound)
            → save(Category.of(...))
  → 200 CategoryResponse
비ADMIN(SELLER/CONSUMER) → 403, 비인증 → 401, slug 중복 → 409, parent 미존재 → 404
```

### 3.3 SELLER 상품 등록 (REST)
```
POST /api/v1/seller/products  {categoryId?,name,description?,basePrice}  Bearer{ROLE_SELLER}
  → /api/v1/seller/** hasRole SELLER 통과(ADMIN 함의)
  → SellerProductRestController.register → ProductServiceResponse.register(auth, req)
       → ownerId = (long) auth.getPrincipal()
       → ProductService.register(ownerId, categoryId, name, description, basePrice)
            → basePrice ≥ 0 방어 → categoryId 존재 검증(있으면)
            → save(Product.create(...))  // status = DRAFT 강제
  → 200 ProductResponse{status:"DRAFT", ownerId}
CONSUMER → 403, 비인증 → 401, basePrice 음수 → 400, category 미존재 → 404
```

### 3.4 상품 수정 + 소유권 (REST, 성공/타인 404/ADMIN 성공)
```
PATCH /api/v1/seller/products/42  {...,status}  Bearer{ROLE_SELLER, userId=7}
  → 인가 통과 → ProductServiceResponse.update(auth, 42, req)
       → actorId=7, actorIsAdmin=(authorities contains ROLE_ADMIN)
       → ProductService.update(7, false, 42, ...)
            → findById(42) (없으면 404 ProductNotFound)
            → product.ownerId != 7 && !isAdmin → 404 ProductAccessDenied(존재 은닉)
            → category 검증 → basePrice 방어 → product.update(...)
  → 200 ProductResponse
소유자(ownerId=7) → 200,  타 판매자(ownerId=9, actor=7) → 404,  ADMIN(actorIsAdmin) → 200
```

### 3.5 상품 등록 화면/제출 (View)
```
GET /seller/products/new   (form session, ROLE_SELLER)
  → View 체인 /seller/** hasRole SELLER 통과
  → SellerProductViewController.newForm
       → model: productForm(빈), categories(List<CategoryResponse>), statuses(ProductStatus.values())
  → view "seller/product-form" (CSRF 히든 포함)

POST /seller/products  (CSRF, @Valid ProductForm)
  → 검증 실패: categories/statuses 재주입 → "seller/product-form" 재렌더(입력값·메시지 유지)
  → 성공: actorId = userDirectory.findUserIdByEmail(auth.getName())   // product.spi 포트 — 어댑터가 member에 위임
        → productService.register(actorId, form...) → product
        → "redirect:/seller/products/{id}/edit"
CONSUMER → 403, 비인증 → /login redirect
```

### 3.6 상품 수정 화면 + 소유권 (View)
```
GET /seller/products/42/edit  (ROLE_SELLER, userId=7 via email)
  → actorId(7) = userDirectory.findUserIdByEmail(auth.getName())   // product.spi 포트
  → productService.getForEdit(7, isAdmin, 42)  (소유권 검사)
       → 타인/미존재 → ProductNotFound/ProductAccessDenied(404) → ViewExceptionHandler "error/error"
       → 성공 → Product → ProductForm 변환 + categories + statuses
  → view "seller/product-form"
POST /seller/products/42  → @Valid 재렌더 / 성공 update → redirect:/seller/products/42/edit
```

---

## 4. 예외 처리 전략

| 상황 | 예외/처리 | HTTP | 반환(REST) | 반환(View) |
|---|---|---|---|---|
| 비인증 접근 | filter 미설정 → EntryPoint | 401 | `RestAuthenticationEntryPoint` JSON | formLogin redirect `/login` |
| 권한 부족(CONSUMER) | `AccessDeniedException` | 403 | `RestAccessDeniedHandler` JSON | 403(View 기본) |
| 카테고리 없음(parent/대상) | `CategoryNotFoundException` | 404 | `RestExceptionHandler` ErrorResponse | `ViewExceptionHandler` `error/error` |
| slug 중복 | `DuplicateSlugException` | 409 | ErrorResponse | (관리 화면은 본 Task 범위 밖 — REST만) |
| 상품 없음 | `ProductNotFoundException` | 404 | ErrorResponse | `error/error` |
| 타인 상품 수정/조회 | `ProductAccessDeniedException` | 404 | ErrorResponse(존재 은닉) | `error/error` |
| basePrice 음수(@DecimalMin/서비스) | `MethodArgumentNotValid` / `BusinessException` | 400 | ErrorResponse | 폼 재렌더(`th:errors`) |
| 필드 검증 실패(@Valid name/basePrice) | `MethodArgumentNotValidException` | 400 | ErrorResponse | 폼 재렌더 |
| status 미정의 값(역직렬화) | `HttpMessageNotReadableException` | 400 | ErrorResponse | 폼 바인딩 에러 재렌더 |

- 모든 예외는 `BusinessException` 계열(`RuntimeException` 상속) — 내부 정보(스택트레이스·SQL·hash) 미노출(error-response-rule).
- **REST 에러 JSON ↔ View 에러뷰/재렌더 엄격 분리**(error-response-rule: JSON은 `/api/v1/**`만). View 실패는 JSON 반환 안 함(006/008 체인 분리 유지).

---

## 5. 검증 방법

> 실행 위치: `shop-core/`. 명령: `./gradlew test`. `@SpringBootTest` 류는 008 컨벤션(`@Import(FakeRefreshTokenStore.class)` + `@MockBean` JPA/DB 의존)을 계승해 실 DB·Redis 없이 test profile 기동.

### 5.1 단위 테스트 (Mockito)
- `CategoryServiceTest`: list 위임, create 성공(save 인자), **slug 중복 → DuplicateSlugException(409)**, **parent 미존재 → CategoryNotFoundException(404)**, update 성공(자기 slug 유지 통과).
- `ProductServiceTest`: register 성공(**status==DRAFT** 단언), **category 미존재 → 404**, **basePrice 음수 → 400**(서비스 방어), update 성공, **타 판매자 수정 → ProductAccessDeniedException(404)**(미변경), **ADMIN(isAdmin=true) 전체 수정 성공**, 미존재 → ProductNotFound(404).
- `ProductServiceResponseTest`/`CategoryServiceResponseTest`: principal(long) 추출·isAdmin 판정 후 Service 위임, DTO 매핑(응답에 Entity 부재·민감필드 부재 단언).

### 5.2 Security/REST MockMvc
- `CategoryRestControllerSecurityTest`: `GET /api/v1/categories` **비인증 200**(public); `POST/PATCH /api/v1/admin/categories` **ADMIN 성공·SELLER 403·CONSUMER 403·비인증 401**, slug 중복 409, parent 404.
- `SellerProductRestControllerSecurityTest`: `POST /api/v1/seller/products` **SELLER 200·ADMIN 200·CONSUMER 403·비인증 401**, basePrice 음수 400; `PATCH /{id}` **소유자 200·타 판매자 404·ADMIN 200·미존재 404**. 응답 jsonPath에 민감/Entity 필드 부재 단언. `ProductRepository`/`CategoryRepository` `@MockBean` stub, REST principal=userId(long) 규약으로 소유권 케이스 구성.

### 5.3 View MockMvc (`SellerProductViewControllerTest`)
- `GET /seller/products/new`(@WithMockUser(roles="SELLER")) → 200, view `seller/product-form`, model `productForm`/`categories`/`statuses` 존재, **CSRF 히든 마커 렌더**.
- `POST /seller/products`(`with(csrf())`, 유효 폼) → 302 `redirect:/seller/products/{id}/edit`, `productService.register` 호출(actorId 통일 — **`UserDirectory`를 `@MockBean`/fake로 주입해 `findUserIdByEmail(email)`→고정 userId stub**으로 격리. member 의존 없이 View 단독 검증).
- `POST /seller/products`(검증 실패 — name 누락/basePrice 음수) → 200 view `seller/product-form` 재렌더 + `categories`/`statuses` 재주입(입력값·메시지 유지).
- `GET /seller/products/{id}/edit`: 소유자 200 / 타인·미존재 → 404(`error/error`).
- **권한 차단**: CONSUMER `GET /seller/products/new` → 403; 비인증 → `/login` redirect(302). ADMIN → 200(함의).

### 5.4 운영 배선 회귀 (`ProductWiringTest`, P1/testing-rule)
- `@SpringBootTest`(test profile, `@Import(FakeRefreshTokenStore.class)` + `@MockBean ProductRepository, CategoryRepository, MemberRepository`)로 컨텍스트 기동 후 신규 진입 빈(`CategoryRestController`, `AdminCategoryRestController`, `SellerProductRestController`, `SellerProductViewController`, `CategoryServiceResponse`, `ProductServiceResponse`, `CategoryService`, `ProductService`) 등록 단언. fake가 신규 배선을 가리지 않음 확인(008 `AdminMemberWiringTest` 패턴 계승).
- **포트-어댑터 운영 배선 단언(추가)**: `MemberUserDirectoryAdapter`가 `UserDirectory` 빈으로 등록되고, 컨텍스트에서 `UserDirectory` 타입이 어댑터로 **단일 운영 배선**됨을 단언(`SellerProductViewController`의 `UserDirectory` 주입이 운영에서 해결됨 확인). 어댑터가 `MemberService`에 의존하므로 **`MemberService`(및 그 추이 의존)가 운영 빈으로 살아있어야** 한다 — 따라서 `@MockBean` 목록에서 `MemberUserDetailsService`는 제외하지 않되, **`MemberService`/어댑터 자체는 mock하지 않는다**(운영 배선 점검 목적). `MemberRepository`는 DB 절단을 위해 `@MockBean` 유지(어댑터→MemberService→MemberRepository 경로는 빈 존재만 확인, 실제 조회 불요).

### 5.5 기존 테스트 비파괴
- `SecurityConfigTest`(006/008): `/api/v1/seller/**`·`/seller/**`·`/api/v1/categories` 매처는 가산적 — 기존 공개/auth/admin 경로 동작 비파괴.
- `AuthRestControllerSecurityTest`·`AdminMemberRestControllerSecurityTest`(008): admin/auth 경로 영향 없음(별도 prefix).
- `LayoutRenderingTest`: `nav.html` 수정이 '홈'·ADMIN 링크·`nav(active)` 시그니처 보존(SELLER 링크 추가만).
- `ModularityTests`(Modulith): product 모듈 신규 등장 — **product는 `member`를 참조하지 않는다**(포트 의존 역전). product→common(BaseEntity/예외) 의존만 두고, 사용자 디렉터리 조회는 product 소유 포트 `product.spi.UserDirectory`(@NamedInterface)로 추상화한다. 허용 의존은 **member → product.spi(named interface)** 단방향뿐이며, member 어댑터가 그 포트를 구현한다(architecture-rule "published API(named interface/port)로만"). `ownerId`는 스칼라 long이라 member Entity 미노출. 모듈 경계 위반 0 확인 + **product 패키지에서 `com.shop.shop.member.*` 참조 0** 단언.
- `ShopCoreApplicationTests.contextLoads`: 신규 빈 의존 운영 해결.

### 5.6 수동/docker 검증 (CI 외, 구현자)
- SELLER/ADMIN 계정·카테고리·상품 시드 부재 → **docker PG 직접 INSERT**(users role='SELLER'/'ADMIN', categories) 후 로그인 e2e: ADMIN 카테고리 생성 → `GET /api/v1/categories` 노출 → SELLER 상품 등록(status DRAFT) → 수정 → 타 SELLER 수정 404. **V3 적용 검증**: `flyway migrate` 후 `products.status` CHECK 대문자·`owner_id` 컬럼·`idx_products_owner_id` 확인, `ddl-auto=validate`로 Product/Category Entity 정합(V1+V3 기준).

### 5.7 Acceptance Criteria 대 검증 매핑
| Acceptance | 검증 |
|---|---|
| ADMIN 카테고리 생성/수정 | 5.1 create/update 성공 + 5.2 POST/PATCH 200 |
| SELLER/CONSUMER 카테고리 관리 차단 | 5.2 SELLER/CONSUMER 403 |
| 공개 카테고리 조회 동작 | 5.2 GET public 200 + 5.1 list |
| SELLER 상품 등록 화면 접근 | 5.3 GET /new 200 |
| CONSUMER/비인증 화면 차단 | 5.3 CONSUMER 403·비인증 redirect |
| SELLER 상품 등록 | 5.1 register + 5.2 POST 200 + 5.3 POST redirect |
| 등록 상품 기본 DRAFT | 5.1 status==DRAFT 단언 |
| SELLER 자기 상품만 수정 | 5.1 타인 404 + 5.2 PATCH 타인 404 |
| ADMIN 전체 상품 수정 | 5.1 isAdmin 성공 + 5.2 PATCH ADMIN 200 |
| 타 판매자 수정 403/404 실패 | 5.1/5.2 404(§1.4 결정) |
| 화면 공통 레이아웃/프래그먼트 | 5.3 view seller/product-form(layout/base) |
| 폼 CSRF 렌더 | 5.3 CSRF 히든 마커 |
| 검증 실패 입력값/메시지 유지 | 5.3 재렌더 + th:errors echo |
| 응답·모델 Entity 미노출 | 5.2 jsonPath 부재 + 5.1 DTO 매핑 |
| 관련 테스트 통과 | `./gradlew test` 그린 |

---

## 6. 트레이드오프
- **카테고리 응답: flat(채택) vs 트리(중첩 children)** — 채택 flat: (장) 폼 셀렉트에 충분, 직렬화 단순, `parentId`로 트리 조립 가능(무손실), YAGNI. (단) 클라이언트가 트리 필요 시 조립. 미채택 트리: 재귀 직렬화·깊이 제어·N+1 표면 — 본 Task 과설계.
- **타인 리소스: 404(채택) vs 403** — 채택 404: (장) 리소스 존재 은닉(열거 방지), 미존재와 통일해 외부 구분 불가. (단) 소유자에게도 "권한 없음" 대신 "없음"으로 보여 디버깅 모호. 미채택 403: 존재 사실 노출. (api-authorization-rule "403 또는 404" 충족 — 정보 노출 관점으로 404 선택.)
- **owner_id: 스칼라 long(채택) vs `@ManyToOne User`** — 채택 스칼라: (장) product→member Entity 직접 참조 회피(모듈 경계·architecture-rule), 소유권 비교에 충분, FK는 DB가 보장. (단) User 객체 접근 시 별도 조회. 미채택 ManyToOne: 모듈 경계 넘는 Entity 결합·Modulith 위반 위험.
- **소유권 위치: ProductService(채택) vs Controller/ServiceResponse** — 채택 Service: (장) REST/View 공유, 규칙 한곳, Controller 로직 0(Constraint), Repository 직접 조회 금지 충족. (단) actorId/isAdmin 인자 전파. 미채택 분산: 중복·일관성 저하·규칙 위반.
- **status DEFAULT: 애플리케이션 강제(채택) vs DB DEFAULT 'DRAFT'** — 채택 앱 강제(`Product.create`): (장) 등록 진입점 단일(REST/View 공유), V1에 status DEFAULT 부재와 정합, 의도 명시. (단) DB INSERT 직접 시 누락 가능(본 Task는 앱 경유만). 미채택 DB DEFAULT: V3에서 추가 가능하나 앱이 항상 채우므로 불요(YAGNI).
- **V3 status 정합: CHECK 교체(채택, V2 패턴) vs Entity를 소문자 매핑** — 채택 대문자 교체: (장) `@Enumerated(STRING)` 표준·users.role(V2)과 일관·enum 상수명 그대로. (단) 마이그레이션 1개. 미채택 소문자 매핑: enum과 DB 불일치·`@Enumerated` 우회 필요 — 컨벤션 이탈.
- **인가: path 기반 hasRole(채택) vs @PreAuthorize** — 채택 path: (장) 엔드포인트 권한 단순·008 일관·한곳 추적. (단) 메서드 세분화 불가(소유권은 Service로 분리 보완). 미채택 @PreAuthorize: 본 Task 과설계.
- **View principal 통일: 포트-어댑터(채택) vs MemberService 직접 의존 vs 인증 principal에 userId 격리** — 채택 **포트-어댑터(의존 역전)**: product가 `product.spi.UserDirectory`(@NamedInterface) 포트를 소유하고 member가 `MemberUserDirectoryAdapter`로 구현. (장) product가 member를 **전혀 참조하지 않아** 장차 외부 서비스 분리 시 포트 어댑터만 REST 구현으로 교체하면 됨(분리 의도 직접 충족), 의존 방향 member→product.spi 단방향, architecture-rule "published API(named interface/port)" 정합, 모듈 경계 데이터 스칼라(email/userId)로 Entity 미노출. (단) 인터페이스 1개·어댑터 1개·named interface 선언 추가(경미). 미채택 **MemberService 직접 의존**: View가 `MemberService.getByEmail`을 직접 호출 — product→member 도메인 직접 의존을 만들어 모듈 결합·분리 저해(분리 의도와 정면 충돌). 미채택 **인증 principal에 userId 격리**(form-login도 principal=userId(long)로 통일): View에서 디렉터리 조회 자체를 제거할 수 있어 가장 깔끔하나, 006/008의 form-login `UserDetails`(username=email) 인증 구조를 바꿔야 해 **회귀 범위가 큼**(`MemberUserDetailsService`·세션·기존 View 컨트롤러 전반) → 본 Task 범위를 넘는 **별도 task**로 분리.

---

## Spring Boot 컨벤션
- 패키지: `com.shop.shop.product.{controller|service|repository|domain|dto}`(product 모듈 — package-structure-rule 6개 도메인에 이미 존재), `com.shop.shop.product.spi`(**published port — @NamedInterface**), `com.shop.shop.member.adapter`(**의존 역전 어댑터 — member 소유**), `com.shop.shop.common.exception`(횡단), `com.shop.shop.security`(인가). 새 **도메인** 모듈 추가 없음. `spi`/`adapter`는 표준 패키지 목록 밖이나 architecture-rule "published API(named interface/port)" 조항으로 정당화하며, package-structure-rule 보강은 후속 제안으로 남긴다(§범위 메모).
- 어노테이션: `@RestController`/`@Controller`/`@RequestMapping`/`@GetMapping`/`@PostMapping`/`@PatchMapping`/`@PathVariable`/`@RequestBody`/`@ModelAttribute`/`@Valid`, `@Service`/`@RequiredArgsConstructor`/`@Transactional`/`@Slf4j`, `@Entity`/`@Table`/`@ManyToOne`/`@JoinColumn`/`@Enumerated(EnumType.STRING)`, Bean Validation(`@NotBlank`/`@NotNull`/`@DecimalMin`), Lombok `@Getter`/`@Setter`/`@NoArgsConstructor`. REST DTO·응답은 `record`, View 폼은 가변 class.
- Entity: Setter 금지·정적 팩토리·의도 노출 메서드(`create`/`update`/`changeStatus`)·BaseEntity 상속(Product, 시간컬럼 읽기전용)·Category는 시간컬럼 없어 미상속. 금액 `BigDecimal`.
- 레이어: REST `RestController → ServiceResponse → Service → Repository`(Controller 로직 금지). View `ViewController → Service → Repository`(ServiceResponse 미사용, 모델 DTO/Entity 금지). 도메인 로직 단일 소유(Category/ProductService). 소유권 Service 검증(Controller Repository 직접 조회 금지).
- 보안/데이터: 카테고리 관리 ADMIN, 상품 등록/수정 SELLER(ADMIN 함의), 카테고리 조회 public. 소유권(타인 상품 404). Entity 응답/모델 미노출. notification 미참조, 이벤트 계약 변경 0. 마이그레이션 V3만 추가(V1/V2 불변).

## 완료 조건 체크리스트
- [ ] `Category`(자기참조 parent nullable·slug unique·sortOrder, BaseEntity 미상속)·`Product`(category nullable·ownerId 스칼라·basePrice BigDecimal·status enum 기본 DRAFT, BaseEntity 상속)·`ProductStatus` enum
- [ ] `CategoryRepository`(existsBySlug/existsBySlugAndIdNot/findAllByOrderBySortOrderAscIdAsc)·`ProductRepository`(기본)
- [ ] `CategoryService`(list·createCategory·updateCategory + slug 중복/parent 존재 불변식)·`ProductService`(register 기본 DRAFT·update·getForEdit + category 검증·소유권(타인 404))
- [ ] `CategoryServiceResponse`·`ProductServiceResponse`(REST principal=userId·isAdmin 추출, DTO 변환) — REST 전용
- [ ] `CategoryRestController`(GET public)·`AdminCategoryRestController`(POST/PATCH ADMIN)·`SellerProductRestController`(POST/PATCH SELLER) — Controller 로직 0
- [ ] `SellerProductViewController`(GET new·POST·GET edit·POST {id}, 모델 productForm/categories/statuses, 소유권, **`UserDirectory` 포트로 email→actorId 통일(member 직접 호출 0)**, 검증 실패 재렌더·성공 edit redirect) — backend-implementor
- [ ] `product.spi.UserDirectory`(포트, `long findUserIdByEmail(String)`, `spi/package-info.java` `@NamedInterface("spi")`)·`member.adapter.MemberUserDirectoryAdapter`(어댑터, `@Component implements UserDirectory` → `MemberService.getByEmail().getId()`, member→product.spi 단방향) — **product는 member 미참조(ModularityTests 통과)**
- [ ] `CategoryResponse`/`ProductResponse`(record, from, Entity 미노출, parentId/categoryId 평탄화)·`Category/ProductCreate/UpdateRequest`(record, Bean Validation)·`ProductForm`(가변 class)
- [ ] `CategoryNotFound`(404)·`DuplicateSlug`(409)·`ProductNotFound`(404)·`ProductAccessDenied`(404) 예외
- [ ] `SecurityConfig`: REST `/api/v1/categories` GET permitAll·`/api/v1/seller/**` hasRole SELLER(admin 008 유지), View `/seller/**` hasRole SELLER(anyRequest 앞, 008 비파괴)
- [ ] `V3__product_status_and_owner.sql`(status CHECK 대문자 교체·owner_id 추가·idx_products_owner_id, V1/V2 불변)
- [ ] `templates/seller/product-form.html`(layout/base, th:object productForm, categoryId/name/description/basePrice/status, CSRF 자동, 검증 echo)·`fragments/nav.html` SELLER 링크 추가('홈'·ADMIN 마커 비파괴) — view-implementor
- [ ] 단위(카테고리 생성/수정·slug 중복·parent 미존재·상품 등록 DRAFT·수정·소유권 실패·basePrice 음수) + REST/Security(categories public·admin categories ADMIN/403/401·seller products SELLER/CONSUMER 403/401·PATCH 소유자/타인 404/ADMIN) + View(GET new SELLER 렌더·CSRF·POST redirect·검증 실패 재렌더) + 배선 회귀(ProductWiringTest)
- [ ] 기존 비파괴: SecurityConfigTest·AdminMemberRestControllerSecurityTest·LayoutRenderingTest(nav 마커)·ModularityTests(**product→member 참조 0**, member→product.spi(@NamedInterface) 단방향만 허용)·contextLoads
- [ ] Entity 응답/모델 노출 0, Controller 비즈니스 로직 0, 소유권 Service 검증(Controller Repository 직접 조회 0), 금액 BigDecimal, 이미지/옵션/variant/재고/삭제/공개목록 미구현, notification 참조 0, 이벤트 계약 변경 0, V1/V2 수정 0(V3만)
- [ ] `./gradlew test` 전체 통과(+구현자 docker: V3 migrate·status 대문자·owner_id·SELLER/ADMIN INSERT e2e·소유권 404·validate)

## 에이전트 분담 (backend → view 순서)

**호출 순서**: backend-implementor 먼저(Entity·Repository·Service·ServiceResponse·DTO·예외·SecurityConfig·V3 마이그레이션·REST 컨트롤러·`SellerProductViewController`·테스트), 그다음 view-implementor(`seller/product-form.html`·`nav.html`·View 렌더링 단언). 근거: 모델 키(`productForm`/`categories`/`statuses`)·`ProductForm` 필드명·view name·폼 action·redirect·`CategoryResponse` 필드가 먼저 고정돼야 템플릿이 안정 바인딩(CLAUDE.md 백→화 순).

**같은 `.java` 동시편집 회피**: `SellerProductViewController.java`(폼 처리·email→actorId 통일·소유권 호출·검증 재렌더·redirect)는 **backend-implementor 단독** 작성. 템플릿(`seller/product-form.html`·`nav.html`)·정적·View 렌더링 단언 텍스트는 **view-implementor**.

| 항목 | 값 | 담당 정합 |
|---|---|---|
| 등록/수정 view name | `seller/product-form` | backend(컨트롤러 반환) ↔ view(템플릿 경로) |
| 템플릿 경로 | `templates/seller/product-form.html` | view |
| 레이아웃 | `layout/base`(full, nav 포함) | view |
| 폼 백킹 모델 키 | `productForm` | backend(@ModelAttribute) ↔ view(`th:object`) |
| 카테고리 목록 모델 키 | `categories`(List<CategoryResponse>) | backend(model) ↔ view(셀렉트 `th:each`) |
| 상태 목록 모델 키 | `statuses`(ProductStatus.values()) | backend(model) ↔ view(셀렉트) |
| 폼 필드명 | `categoryId`/`name`/`description`/`basePrice`/`status` | backend(ProductForm) ↔ view(`th:field`) |
| 등록 폼 action | `POST @{/seller/products}` | view ↔ backend(매핑) |
| 수정 폼 action | `POST @{/seller/products/{id}}` | view ↔ backend(매핑) |
| 성공 redirect | `redirect:/seller/products/{id}/edit` | backend |
| 실패 렌더 | `seller/product-form` 재렌더(입력값·메시지 유지) | backend(재렌더) ↔ view(th:errors echo) |
| nav SELLER 링크 | `sec:authorize hasRole('SELLER')` → `@{/seller/products/new}` | view(nav.html), backend(인가 매처) |
| nav 보존 계약 | '홈'·ADMIN '회원 관리' 링크·`nav(active)` 시그니처(LayoutRenderingTest) | view(비파괴) |
| `CategoryService` 시그니처 | `List<Category> list()` / `Category createCategory(name,slug,parentId,sortOrder)` / `Category updateCategory(id,...)` | backend |
| `ProductService` 시그니처 | `Product register(long ownerId, Long categoryId, String name, String description, BigDecimal basePrice)` / `Product update(long actorId, boolean actorIsAdmin, long productId, ...)` / `Product getForEdit(long actorId, boolean actorIsAdmin, long productId)` — member·포트 비의존(actorId 인자) | backend |
| `UserDirectory` 포트(product 소유, @NamedInterface) | `long findUserIdByEmail(String email)` (`com.shop.shop.product.spi`, `spi/package-info.java`에 `@NamedInterface("spi")`) | backend-implementor |
| `MemberUserDirectoryAdapter` 어댑터(member 소유) | `@Component implements UserDirectory` → `memberService.getByEmail(email).getId()` (`com.shop.shop.member.adapter`, member→product.spi 단방향) | backend-implementor |
| View actorId 획득 | `SellerProductViewController`가 `UserDirectory` **포트 주입** → `findUserIdByEmail(auth.getName())`(member 직접 호출 0) | backend(컨트롤러 포트 주입) |
| `CategoryResponse` 필드 | categoryId/parentId/name/slug/sortOrder | backend |
| `ProductResponse` 필드 | productId/categoryId/ownerId/name/description/basePrice/status/createdAt/updatedAt | backend |
| REST 카테고리 조회 | `GET /api/v1/categories` → 200 List<CategoryResponse>(flat) | backend |
| REST 카테고리 관리 | `POST/PATCH /api/v1/admin/categories[/{id}]` → 200 | backend |
| REST 상품 등록/수정 | `POST/PATCH /api/v1/seller/products[/{id}]` → 200 | backend |
| 인가 매처 | REST `/api/v1/categories` GET permitAll·`/api/v1/seller/**` hasRole SELLER, View `/seller/**` hasRole SELLER | backend |
| V3 마이그레이션 | status CHECK 대문자 + owner_id 추가 | backend |

**구현 시 확인(메인 에이전트 취합)**:
1. **카테고리 응답 형태 = flat**: `GET /api/v1/categories`는 `List<CategoryResponse>`(parentId 노출). 트리 미사용 — 폼 셀렉트·무손실 조립.
2. **상품 status 기본 DRAFT**: 등록 요청에서 status 미수신, `Product.create`가 DRAFT 강제. 수정만 status 입력.
3. **타인 상품 404**: SELLER가 타인 상품 수정/조회 시 `ProductAccessDeniedException`(404, 존재 은닉). ADMIN은 함의로 전체 접근.
4. **principal 통일(포트-어댑터)**: REST=`(long)auth.getPrincipal()`(member·포트 비의존), View=`userDirectory.findUserIdByEmail(auth.getName())`(product 소유 `UserDirectory` 포트 → 어댑터가 member에 위임). **View 컨트롤러는 member를 직접 참조하지 않는다**(의존 역전, member→product.spi 단방향). `actorIsAdmin`은 authority `ROLE_ADMIN` 직접 보유로 판정(두 경로 동일 `ProductService.update` 호출). `ProductService`는 포트조차 의존하지 않음(actorId 인자).
5. **V3 status 대문자**: V1 소문자 CHECK → V3에서 대문자 교체(V2 users.role 패턴). `@Enumerated(STRING)` 상수명과 정합. 기존 행 `upper(status)` 변환.
6. **owner_id nullable + 앱 강제**: V3는 nullable 추가, 등록 시 ProductService가 항상 채움(시드 없어 DB NOT NULL 보류). FK는 `REFERENCES users(id)`.
7. **모듈 의존 방향(의존 역전)**: **product는 member를 전혀 참조하지 않는다.** View principal 통일은 product 소유 포트 `product.spi.UserDirectory`(@NamedInterface)로 추상화하고, `member.adapter.MemberUserDirectoryAdapter`가 이를 구현(내부에서 `MemberService.getByEmail` 위임). 허용 의존은 **member → product.spi** 단방향뿐. member Entity 모듈 밖 미노출(ownerId·email·userId 모두 스칼라) — ModularityTests로 product의 member 참조 0 확인.
8. **basePrice BigDecimal**: 요청 DTO·폼·Entity·응답 전 구간 BigDecimal. `@DecimalMin("0.0")` + 서비스 `signum()` 2차 방어.

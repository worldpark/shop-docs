# Plan 041. 관리자 카테고리 관리 화면 + 삭제 기능

> 대상 Task: `docs/tasks/backend/041-backend-shop-core-admin-category-management.md`
> 범위: 삭제(service~REST) 신규 + `/admin/categories` 관리 화면(목록·등록·삭제). 등록은 기존 service 재사용. 삭제 시 상품 미분류(DB SET NULL).
> 순서: 삭제 백엔드 + admin facade(backend-implementor) → reviewer → admin 화면(view-implementor) → reviewer → Modulith verify+풀 게이트 → e2e-runner.

## 0. 확정 사실 (코드 검증됨)
- `CategoryService`(product.service, 비공개): `list(): List<Category>`, `createCategory(name, slug, parentId, sortOrder)`, `updateCategory(...)` 존재. **deleteCategory 없음**. not-found는 `common.exception.CategoryNotFoundException(id)`, slug 중복은 `DuplicateSlugException`.
- `CategoryRepository`: `findAllByOrderBySortOrderAscIdAsc()`, `existsBySlug`, `existsBySlugAndIdNot`. delete는 JpaRepository 기본.
- `CategoryResponse`(product.dto, **web 노출됨** — `web/package-info` named interface): `(long categoryId, Long parentId, String name, String slug, int sortOrder)` — **첫 필드는 `categoryId`(long), 접근자 `categoryId()`. `id`/`getId()` 없음**. `CategoryResponse.from(category)`가 `category.getId()`로 채움. → 목록 DTO 재사용(신규 DTO 불필요). **화면·맵에서 식별자는 전부 `categoryId`로 참조**.
- REST: `AdminCategoryRestController`(POST/PATCH, `/api/v1/admin/categories`, ADMIN), `CategoryServiceResponse`(list/create/update). 권한 `/api/v1/admin/**`·`/admin/**` hasRole(ADMIN) 존재.
- **web→모듈 seam 패턴 확정**: admin 뷰 컨트롤러는 모듈 `*.spi` published facade 주입(`AdminMemberFacade`=member.spi, `AdminOrderFulfillmentFacade`=order.spi). product.spi엔 **카테고리 admin facade 없음 → 신설**.
- FK: `products.category_id`·`categories.parent_id` 모두 ON DELETE SET NULL(삭제 시 상품 미분류·자식 root 승격, 추가 처리 불필요).

## 1. 백엔드 (backend-implementor)
### 1.1 삭제 service
- `CategoryService.deleteCategory(long categoryId)`: `categoryRepository.findById(categoryId).orElseThrow(() -> new CategoryNotFoundException(categoryId))` → `categoryRepository.delete(category)`. 클래스 `@Transactional`(쓰기) 적용 확인. **DB SET NULL이 상품·자식 정리 — cascade/orphanRemoval 신설 금지, 사전검증 없음**(미분류 전환 확정).

### 1.2 삭제 REST
- `CategoryServiceResponse.delete(long id)`(product.service): service 위임(기존 create/update와 동일 스타일).
- `AdminCategoryRestController` `@DeleteMapping("/{categoryId}")` → `ResponseEntity<Void>` 204(noContent). 기존 POST/PATCH와 동일 매핑 스타일.

### 1.3 admin facade (web seam — 신규, 기존 AdminXxxFacade 패턴)
- `product/spi/AdminCategoryFacade.java`(interface, named interface 노출):
  - `List<CategoryResponse> list()`
  - `void create(String name, String slug, Long parentId, int sortOrder)`
  - `void delete(long categoryId)`
- `product/service/AdminCategoryFacadeImpl.java`: `CategoryService` 주입 → list는 `categoryService.list().stream().map(CategoryResponse::from).toList()`, create/delete 위임. `@Transactional` 경계는 CategoryService에 위임(facade는 얇게).
  - **ServiceResponse 재사용 금지 이유**: `CategoryServiceResponse.list()`도 동일 매핑을 하지만 ServiceResponse는 **REST 전용**(architecture-rule상 View 경로 미사용)이라 facade가 직접 `CategoryService`(Entity)→`CategoryResponse` 매핑한다.
- `product/spi/package-info.java`에 named interface 노출 확인(기존 facade들과 동일).

### 1.4 백엔드 테스트 (타깃, 풀 스위트 금지)
- REST 보안: `AdminCategoryRestControllerSecurityTest`(있으면 확장, 없으면 기존 패턴으로) DELETE — **ADMIN 204 / SELLER 403 / CONSUMER 403 / 비인증 401 / 존재X 404**.
- service: `deleteCategory` 존재X→CategoryNotFoundException, 정상 삭제 시 repository.delete 호출.
- 통합(Testcontainers, 1케이스): 카테고리에 상품·자식 매단 뒤 삭제 → 상품 `category_id=NULL`·자식 `parent_id=NULL` 검증(SET NULL 동작 확인).
- 실행: `./gradlew test --tests "*AdminCategory*" --tests "*CategoryService*"` 등 타깃.
- **풀 컨텍스트 테스트 주의**: 신규 `AdminCategoryFacadeImpl`(=CategoryService 의존)이 새 빈이지만 CategoryService는 기존 빈이라 신규 repository 의존 추가는 없음 → `@MockSharedRepositories`/수동 mock 목록 갱신 불요 예상. 단 풀 게이트로 최종 확인([[full-context-test-repo-mock-shared-annotation]]).

## 2. 화면 (view-implementor) — `/admin/categories`
### 2.1 뷰 컨트롤러 `web/.../AdminCategoryViewController.java`
- `AdminCategoryFacade` 주입(web→product.spi forward — `AdminMemberViewController`와 동일 구조, 사이클 없음).
- `@GetMapping("/admin/categories")`: `facade.list()` → 모델 `categories`(List<CategoryResponse>) + 부모명 표기용 `Map<Long,String> categoryNames`(`list.stream().collect(toMap(CategoryResponse::categoryId, CategoryResponse::name))` — 키는 categoryId의 Long 박싱, parentId(Long) 조회와 정합) + 등록 폼 객체(`categoryForm`). 뷰 `admin/categories`.
- `@PostMapping("/admin/categories")`: `@Valid` 등록 폼(name 필수, slug 필수, sortOrder, parentId 선택) → `facade.create(...)`. 성공 flashSuccess "카테고리가 등록되었습니다." → redirect. 검증 실패 시 목록 재조회+폼 에러 재렌더(폼 객체 echo, [[inline-script-must-be-inside-main-layout-fragment]] 무관 — 정적). slug 중복(DuplicateSlugException)·부모 없음은 flashError 또는 폼 에러로.
- `@PostMapping("/admin/categories/{categoryId}/delete")`: `facade.delete(categoryId)` try/catch(BusinessException→flashError) → flashSuccess "카테고리가 삭제되었습니다. 해당 상품은 미분류로 전환됩니다." → redirect.
- 모델 키 예약명 회피(`categories`/`categoryForm`/`categoryNames`).

### 2.2 템플릿 `templates/admin/categories.html`
- 기존 `admin/*.html`(members/orders/seller-applications) 레이아웃·톤 재사용(`layout/base :: layout(...)`).
- **목록 표**: 이름 / slug / 정렬순서 / 부모(없으면 "최상위", 있으면 `${categoryNames.get(c.parentId)}`). 행 변수 `c`는 `CategoryResponse` — **식별자는 `c.categoryId`**(`c.id` 아님). 행마다 **삭제 폼**: `<form method="post" th:action="@{/admin/categories/{id}/delete(id=${c.categoryId})}" onsubmit="return confirm('이 카테고리를 삭제하면 해당 상품은 미분류로 전환되고, 하위 카테고리는 최상위로 올라갑니다. 계속할까요?')">` + `btn btn-danger btn-sm`. CSRF 자동(_csrf 수동 금지).
- **등록 폼**: 이름(text), slug(text), 정렬순서(number), 부모 선택(`<select>` — 없음(최상위)+기존 카테고리들 option, `categories` 재사용). `th:object="${categoryForm}"`, 필드 에러 `th:errors`.
- 빈 목록 메시지. 인라인 `<script>` 쓰면 `<main>` 내부(쓸 일 없을 것).

### 2.3 admin 네비 링크
- 기존 admin 화면들(members/orders/seller-applications)에 공용 네비 프래그먼트가 있으면 거기에 "카테고리 관리"(`/admin/categories`) 링크 추가. 없으면 각 admin 페이지 상단/또는 최소 members 페이지에 링크 추가(view-implementor가 현행 확인 후 일관 위치).

## 3. 순서 / 검증 게이트
1. backend-implementor(삭제 service+REST + AdminCategoryFacade + 타깃 테스트) → reviewer.
2. view-implementor(AdminCategoryViewController + admin/categories.html + 네비 링크) → reviewer.
3. 메인: **Modulith verify**(web→product.spi 추가가 사이클 없음) + 풀 스위트 그린.
4. e2e-runner: 앱 기동(JWT secret + Hikari 풀 10) → **ADMIN 계정**으로 /admin/categories → 등록(목록 반영) → 삭제(목록에서 사라짐) → (선택) 상품 미분류 전환 확인. 비ADMIN 접근 차단.
   - E2E ADMIN 계정 부트스트랩: 기존 E2E가 ADMIN을 어떻게 얻는지 확인(DB role 승격 패턴 재사용, [[perf-seed-needs-admin-bootstrap-and-onsale-publish]] 참고).

## 4. 리뷰 관점
- 삭제 service가 존재검증(CategoryNotFoundException 재사용)만 하고 cascade/사전차단 없이 DB SET NULL에 위임하는가. JPA delete 1회.
- REST DELETE 권한 매트릭스(ADMIN 204 / SELLER·CONSUMER 403 / 비인증 401 / 존재X 404).
- **모듈 경계**: 새 seam이 web→`product.spi.AdminCategoryFacade`(forward)만이고 web이 product.service/domain·repository에 직접 닿지 않는가. AdminCategoryFacade가 named interface로 노출됐는가. CategoryResponse 재사용(신규 DTO 과설계 없음).
- 화면: 삭제 폼 CSRF 자동·confirm(미분류 안내), 등록 폼 검증·부모 드롭다운, 예약 모델명 회피. admin 인가(/admin/** ADMIN)에 의존.
- 삭제 부수효과(상품 미분류·자식 root) 화면 안내가 사실과 일치.
- 읽기/쓰기 트랜잭션 경계 적절, 도메인 불필요 연관 추가 없음.

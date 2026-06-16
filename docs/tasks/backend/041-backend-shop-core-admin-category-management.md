# 041. 관리자 카테고리 관리 화면 + 삭제 기능

> 출처: 사용자 요청 — "상품 카테고리 등록/삭제 기능이 필요". 실사 결과 등록·수정 REST(ADMIN)는 있으나 **삭제 미구현 + 관리 화면 자체가 없음**.
> 범위 확정(사용자 선택): **관리 화면(목록+등록+삭제) 풀세트** / 삭제 시 상품은 **미분류(category_id NULL) 전환**(DB ON DELETE SET NULL 그대로).

## 현황 / 갭 (실사 확정)
| 기능 | 상태 |
|---|---|
| Category 엔티티·스키마 | ✅ 계층형(parent_id 자기참조 nullable), `categories`(name, slug unique, sort_order) — `Category.java`, V1 스키마 |
| 등록 REST(ADMIN) | ✅ `POST /api/v1/admin/categories` (`AdminCategoryRestController`) |
| 수정 REST(ADMIN) | ✅ `PATCH /api/v1/admin/categories/{id}` |
| 조회 REST(공개) | ✅ `GET /api/v1/categories` |
| **삭제** | ❌ service~REST 전부 없음 |
| **관리 화면(UI)** | ❌ 없음 — 상품 폼이 목록만 소비, 등록·삭제할 화면 부재 |
| 권한 | ✅ `/api/v1/admin/**`·`/admin/**` → hasRole(ADMIN) 정책 존재 |

## 삭제 안전성 (실사 — 제약 없음)
- `products.category_id` → `categories(id)` **ON DELETE SET NULL**: 카테고리 삭제 시 매달린 상품은 **미분류(category_id NULL)** 로 전환, 상품 데이터 보존.
- `categories.parent_id` → `categories(id)` **ON DELETE SET NULL**: 부모 삭제 시 자식은 **root로 승격**(parent_id NULL).
- 즉 삭제 차단/사전검증 불필요 — JPA `delete` 1회 + DB가 정리(확정 선택: 미분류 전환).

## Target / Goal
관리자가 `/admin/categories` 화면에서 카테고리를 **목록 조회·등록·삭제**한다. 삭제 백엔드(service~REST)를 등록/수정과 동일 패턴으로 추가하고, admin 뷰(목록+등록 폼+삭제 버튼)를 신설한다. 등록은 기존 service 재사용.

## 범위 (Scope)
### 백엔드 (backend-implementor) — 삭제
- `CategoryService.deleteCategory(long categoryId)`: 존재 검증(`findById(...).orElseThrow(CategoryNotFoundException)` — 기존 예외 재사용, 없으면 기존 패턴 확인) → `categoryRepository.delete(category)`. DB SET NULL이 상품·자식 정리(추가 처리·연관 cascade 신설 금지).
- `CategoryServiceResponse.delete(...)`(REST 응답 레이어, 기존 create/update와 동일 스타일).
- `AdminCategoryRestController` `@DeleteMapping("/{categoryId}")` → 204(noContent).
- **수정(PATCH)은 신규 작업 없음**(이미 있음). 등록도 service 재사용.

### 화면 (view-implementor) — `/admin/categories` 관리 페이지
- **뷰 컨트롤러**(web 계층, admin 뷰 체인): `GET /admin/categories`(목록 렌더) + `POST /admin/categories`(등록) + `POST /admin/categories/{id}/delete`(삭제). 폼 POST→service→flash+redirect 패턴(기존 seller 뷰 컨트롤러 방식과 동일). 인라인 `<script>` 쓰면 반드시 `<main>` 내부([[inline-script-must-be-inside-main-layout-fragment]]).
  - web→product 서비스 접근 seam은 **plan에서 확정**(기존 admin 뷰 컨트롤러가 product 서비스에 어떻게 닿는지 대조 — 필요 시 product.spi에 카테고리 admin facade 추가, 아니면 기존 published port 재사용).
- **템플릿** `templates/admin/categories.html`(기존 `admin/*.html` 톤): 카테고리 목록 표(이름·slug·정렬·부모), 행마다 삭제 폼(confirm), 상단/하단 등록 폼(이름·slug·정렬순서·부모 선택 드롭다운(계층)). 빈 목록 메시지. CSRF 자동(_csrf 수동 금지).
- **계층**: 등록 시 부모 카테고리 선택(선택값, root 가능). 목록은 sort_order 정렬 + 부모명 표기(트리 들여쓰기까지는 비범위 — 평면 목록 + 부모 컬럼).
- admin 네비/메뉴에 "카테고리 관리" 링크 추가(기존 admin 메뉴 위치 확인 후).

## Non-goals
- 카테고리 수정(PATCH) 화면 — 이번 범위 제외(요청은 등록·삭제). REST는 이미 있음. 필요 시 후속.
- 트리 드래그·다단계 깊이 제한·정렬 재배치 UI — 비범위.
- 삭제 차단/경고(상품 매달림) — 미분류 전환으로 확정(차단 안 함). 단 화면 confirm에 "이 카테고리 상품은 미분류로 전환됩니다" 안내.
- 도메인 cascade/orphanRemoval 추가 — DB SET NULL로 충분.

## 검증
- 백엔드: 삭제 REST 권한(ADMIN 204 / SELLER·CONSUMER 403 / 비인증 401), 존재X 404. 삭제 후 매달린 상품 category_id=NULL·자식 parent_id=NULL 검증(통합). 타깃 테스트(`*AdminCategory*`/`*Category*`).
- **브라우저 E2E 필수**(목록·조건부 폼·삭제는 E2E로): ADMIN 로그인 → /admin/categories → 등록(목록 반영) → 삭제(목록에서 사라짐, 상품 미분류 확인). 비ADMIN 접근 차단.
- 메인 최종: Modulith verify(새 web→product seam 사이클 없음) + 풀 스위트 그린.

## 참고 (실사)
- 엔티티/스키마: `product/domain/Category.java`, `V1__init_schema.sql`(categories 93-101, products.category_id FK 108).
- service/repo: `product/service/CategoryService.java`(list/create/update — delete 없음), `CategoryServiceResponse`, `product/repository/CategoryRepository.java`(findAllByOrderBySortOrderAscIdAsc, existsBySlug…).
- REST: `product/controller/AdminCategoryRestController.java`(POST/PATCH), `CategoryRestController`(공개 GET).
- 권한: `security/SecurityConfig.java`(REST `/api/v1/admin/**` ADMIN line 120, View `/admin/**` ADMIN line 185), 기존 admin 뷰: `templates/admin/members.html`·`orders.html`·`seller-applications.html`.
- 사용처: 상품 폼 categoryId 드롭다운(GET /api/v1/categories), 공개 카탈로그 `?categoryId=` 필터.

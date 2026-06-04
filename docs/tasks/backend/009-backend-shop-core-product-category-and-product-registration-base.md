# 009. shop-core 상품 카테고리 + 상품 등록 기반

## Target
shop-core

---

## Goal
`shop-core`에서 상품 도메인의 첫 구현으로 카테고리 관리와 상품 기본 등록/수정 기반을 만들고, 이후 상품 옵션·이미지·variant·공개 목록/상세 화면으로 확장할 수 있는 토대를 마련한다.

---

## Context
- `product` 모듈은 상품 등록/수정(관리자·판매자), 목록·상세를 담당한다
- API 추가 시 `docs/rules/api-authorization-rule.md`를 따른다
- 권한 계층은 `ADMIN > SELLER > CONSUMER`다
- 상품 등록/수정은 `SELLER` 이상 권한이 필요하다
- 판매자는 자기 상품만 수정할 수 있어야 한다
- 상품 목록/상세 공개 화면은 후속 Task에서 구현한다
- 이번 Task는 카테고리와 상품 기본 정보까지만 다룬다
- 상품 이미지, 옵션, option value, variant, 재고 차감은 후속 Task 범위다

## API Authorization

| API | 공개 여부 | 최소 권한 | 상위 권한 허용 | 소유권 검사 | 비고 |
|---|---|---|---|---|---|
| `GET /seller/products/new` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 불필요 | 상품 등록 화면 |
| `POST /seller/products` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 생성자 기록 | 상품 등록 폼 제출 |
| `GET /seller/products/{productId}/edit` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | 판매자는 자기 상품만 수정 |
| `POST /seller/products/{productId}` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | 상품 수정 폼 제출 |
| `GET /api/v1/categories` | public | 없음 | 해당 없음 | 불필요 | 카테고리 조회 |
| `POST /api/v1/admin/categories` | authenticated | `ROLE_ADMIN` | 없음 | 불필요 | 카테고리 생성 |
| `PATCH /api/v1/admin/categories/{categoryId}` | authenticated | `ROLE_ADMIN` | 없음 | 불필요 | 카테고리 수정 |
| `POST /api/v1/seller/products` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 생성자 기록 | 상품 등록 API |
| `PATCH /api/v1/seller/products/{productId}` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | 판매자는 자기 상품만 수정 |

## Requirements
- Category Entity/Repository/Service 구현
  - parent category 자기참조
  - name
  - slug
  - sortOrder
- 카테고리 조회 API 구현
  - 트리 또는 flat 목록 중 구현 방식을 선택하고 문서/응답 DTO에 명시
- 관리자 카테고리 생성/수정 API 구현
  - slug 중복 검증
  - parent category 존재 검증
- Product Entity/Repository/Service 구현
  - category
  - seller 또는 owner 식별자
  - name
  - description
  - basePrice
  - status
- 상품 status는 `DRAFT`, `ON_SALE`, `SOLD_OUT`, `HIDDEN` 중 하나로 둔다
- 상품 등록 API 구현
  - 기본 status는 `DRAFT`
  - `basePrice`는 0 이상
  - category가 있으면 존재하는 category여야 한다
- 상품 수정 API 구현
  - 판매자는 자기 상품만 수정 가능
  - ADMIN은 전체 상품 수정 가능
  - category/name/description/basePrice/status 수정
- 상품 등록/수정 Thymeleaf 화면 구현
  - 카테고리 선택
  - name/description/basePrice/status 입력
  - 검증 실패 시 입력값과 메시지 유지
- ViewController는 `ViewController(@Controller) -> Service -> Repository` 레이어를 따른다
- REST Controller는 `RestController -> ServiceResponse -> Service -> Repository` 레이어를 따른다
- DB 소유 시간 컬럼은 Entity에서 읽기 전용 매핑한다
- 관련 단위 테스트, REST 테스트, View 렌더링 테스트를 작성한다

## Constraints
- 이번 Task에서 상품 이미지 업로드/저장 구현을 하지 않는다
- 이번 Task에서 상품 옵션, option value, variant, 재고를 구현하지 않는다
- 이번 Task에서 공개 상품 목록/상세 화면을 구현하지 않는다
- 카테고리 삭제는 구현하지 않는다
- 상품 삭제는 구현하지 않는다
- 판매자가 다른 판매자의 상품을 수정할 수 없다
- Controller에서 비즈니스 로직을 작성하지 않는다
- Entity를 API 응답이나 View 모델에 직접 전달하지 않는다
- DTO와 Entity를 분리한다
- 금액은 `BigDecimal`로 다룬다
- `notification` 코드나 DB를 참조하지 않는다
- 이벤트 계약은 변경하지 않는다
- Flyway V1이 이미 적용된 경우 기존 migration을 수정하지 않고 필요한 변경은 V2+로 추가한다

## Files
- `shop-core/src/main/java/com/shop/shop/product/controller/**`
- `shop-core/src/main/java/com/shop/shop/product/service/**`
- `shop-core/src/main/java/com/shop/shop/product/repository/**`
- `shop-core/src/main/java/com/shop/shop/product/domain/**`
- `shop-core/src/main/java/com/shop/shop/product/dto/**`
- `shop-core/src/main/java/com/shop/shop/common/exception/**`
- `shop-core/src/main/java/com/shop/shop/security/**`
- `shop-core/src/main/resources/templates/seller/product-form.html`
- `shop-core/src/main/resources/templates/fragments/**`
- `shop-core/src/main/resources/static/**`
- `shop-core/src/main/resources/db/migration/**`
- `shop-core/src/test/java/com/shop/shop/product/**`
- `shop-core/src/test/java/com/shop/shop/security/**`

## Backend - View Contract

| 항목 | 값 |
|---|---|
| 상품 등록 화면 경로 | `GET /seller/products/new` |
| 상품 수정 화면 경로 | `GET /seller/products/{productId}/edit` |
| 상품 등록/수정 View name | `seller/product-form` |
| 상품 등록 폼 action | `POST /seller/products` |
| 상품 수정 폼 action | `POST /seller/products/{productId}` |
| 폼 필드명 | `categoryId`, `name`, `description`, `basePrice`, `status` |
| 상품 폼 모델 키 | `productForm` |
| 카테고리 목록 모델 키 | `categories` |
| 상태 목록 모델 키 | `statuses` |
| 성공 리다이렉트 | `/seller/products/{productId}/edit` 또는 후속 목록 경로 |
| 실패 렌더링 | `seller/product-form` |

## Acceptance Criteria
- `ADMIN`은 카테고리를 생성/수정할 수 있다
- `SELLER`와 `CONSUMER`는 카테고리 생성/수정 API에 접근할 수 없다
- 공개 카테고리 조회 API가 동작한다
- `SELLER`는 상품 등록 화면에 접근할 수 있다
- `CONSUMER`와 비인증 사용자는 상품 등록 화면에 접근할 수 없다
- `SELLER`는 상품 기본 정보를 등록할 수 있다
- 등록된 상품은 기본 status `DRAFT`를 가진다
- `SELLER`는 자기 상품만 수정할 수 있다
- `ADMIN`은 전체 상품을 수정할 수 있다
- 다른 판매자의 상품 수정 시 403 또는 404로 실패한다
- 상품 등록/수정 화면은 공통 레이아웃/프래그먼트를 사용한다
- 상품 등록/수정 폼은 CSRF 토큰과 함께 렌더링된다
- 검증 실패 시 입력값과 메시지가 유지된다
- API 응답과 View 모델에 Entity가 직접 노출되지 않는다
- 관련 테스트가 통과한다

## Test
- `./gradlew test`
- 권장 단위 테스트
  - 카테고리 생성/수정 성공
  - slug 중복 실패
  - parent category 미존재 실패
  - 상품 등록 성공
  - 상품 수정 성공
  - 판매자 소유권 검증 실패
  - basePrice 음수 실패
- 권장 REST/Security 테스트
  - `GET /api/v1/categories` public 성공
  - `POST /api/v1/admin/categories` ADMIN 성공, SELLER/CONSUMER 403
  - `POST /api/v1/seller/products` SELLER 성공, CONSUMER 403, 비인증 401
  - `PATCH /api/v1/seller/products/{productId}` 소유자 성공, 타 판매자 실패, ADMIN 성공
- 권장 View 테스트
  - `GET /seller/products/new` SELLER 렌더링
  - 상품 등록 폼 CSRF 포함
  - 상품 등록 폼 제출 성공 redirect
  - 상품 등록 폼 제출 실패 시 `seller/product-form` 재렌더링

# 010. shop-core 상품 옵션 + Variant 관리 + 화면

## Target
shop-core

---

## Goal
`shop-core`에서 판매자가 상품의 옵션, 옵션값, 구매 단위인 variant를 관리할 수 있는 REST API와 Thymeleaf 화면을 구현해 장바구니·주문으로 이어지는 상품 구매 단위 기반을 마련한다.

---

## Context
- `009`에서 카테고리와 상품 기본 등록/수정 기반을 구현한다
- `database_design.md` 기준 구매 단위는 `product_variants`다
- 상품 옵션 구조는 `product_options` → `option_values` → `product_variants` + `variant_values`다
- variant는 SKU, 판매가, 초기 재고, 활성 상태를 가진다
- 재고 차감/복원은 `inventory` 또는 주문 Task에서 다룬다
- 이번 Task에서 다루는 stock은 판매자가 variant를 만들 때 입력하는 초기/관리 재고 값이다
- 상품 이미지 업로드, 공개 상품 목록/상세 화면, 장바구니 담기는 후속 Task 범위다
- API 추가 시 `docs/rules/api-authorization-rule.md`를 따른다

## API Authorization

| API | 공개 여부 | 최소 권한 | 상위 권한 허용 | 소유권 검사 | 비고 |
|---|---|---|---|---|---|
| `GET /seller/products/{productId}/variants` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | 옵션/variant 관리 화면 |
| `POST /seller/products/{productId}/options` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | 옵션 생성 폼 제출 |
| `POST /seller/products/{productId}/options/{optionId}/values` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | 옵션값 생성 폼 제출 |
| `POST /seller/products/{productId}/variants` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | variant 생성 폼 제출 |
| `POST /seller/products/{productId}/variants/{variantId}` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | variant 수정 폼 제출 |
| `GET /api/v1/seller/products/{productId}/options` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | 옵션/옵션값 조회 API |
| `POST /api/v1/seller/products/{productId}/options` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | 옵션 생성 API |
| `POST /api/v1/seller/products/{productId}/options/{optionId}/values` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | 옵션값 생성 API |
| `GET /api/v1/seller/products/{productId}/variants` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | variant 조회 API |
| `POST /api/v1/seller/products/{productId}/variants` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | variant 생성 API |
| `PATCH /api/v1/seller/products/{productId}/variants/{variantId}` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | variant 수정 API |

## Requirements
- ProductOption Entity/Repository/Service 구현
  - product
  - name
  - 상품 내 옵션명 중복 방지
- OptionValue Entity/Repository/Service 구현
  - productOption
  - value
  - 옵션 내 값 중복 방지
- ProductVariant Entity/Repository/Service 구현
  - product
  - sku
  - price
  - stock
  - isActive
  - 연결된 option values
- VariantValue 매핑 구현
  - `variant_values` 복합키 매핑
  - variant와 option value의 연결을 표현
- 옵션/옵션값 조회 API 구현
- variant 목록 조회 API 구현
- 옵션 생성 API와 화면 폼 구현
- 옵션값 생성 API와 화면 폼 구현
- variant 생성/수정 API와 화면 폼 구현
- variant 생성 시 선택한 option value 조합을 저장한다
- SKU 중복 검증
- price는 0 이상
- stock은 0 이상
- isActive로 variant 활성/비활성 상태를 관리한다
- 판매자는 자기 상품의 옵션/variant만 관리할 수 있다
- ADMIN은 모든 상품의 옵션/variant를 관리할 수 있다
- REST Controller는 `RestController -> ServiceResponse -> Service -> Repository` 레이어를 따른다
- ViewController는 `ViewController(@Controller) -> Service -> Repository` 레이어를 따른다
- Entity를 API 응답이나 View 모델에 직접 전달하지 않는다
- 관련 단위 테스트, REST/Security 테스트, View 렌더링 테스트를 작성한다

## Constraints
- 이번 Task에서 상품 이미지 업로드/저장 구현을 하지 않는다
- 이번 Task에서 공개 상품 목록/상세 화면을 구현하지 않는다
- 이번 Task에서 장바구니 담기 기능을 구현하지 않는다
- 이번 Task에서 주문 재고 차감/복원, 분산락, 조건부 재고 차감 로직을 구현하지 않는다
- 옵션/옵션값/variant 삭제는 구현하지 않는다
- variant의 stock 변경은 판매자 관리 입력값 저장까지만 다룬다
- 판매자가 다른 판매자의 상품 옵션/variant를 관리할 수 없다
- Product를 외부 모듈로 분리할 수 있게 product 모듈은 member 내부 구현이나 Entity를 직접 참조하지 않는다
- Controller에서 비즈니스 로직을 작성하지 않는다
- DTO와 Entity를 분리한다
- 금액은 `BigDecimal`로 다룬다
- 재고 수량은 음수가 될 수 없다
- `notification` 코드나 DB를 참조하지 않는다
- 이벤트 계약은 변경하지 않는다
- Flyway V1이 이미 적용된 경우 기존 migration을 수정하지 않는다

## Files
- `shop-core/src/main/java/com/shop/shop/product/controller/**`
- `shop-core/src/main/java/com/shop/shop/product/service/**`
- `shop-core/src/main/java/com/shop/shop/product/repository/**`
- `shop-core/src/main/java/com/shop/shop/product/domain/**`
- `shop-core/src/main/java/com/shop/shop/product/dto/**`
- `shop-core/src/main/java/com/shop/shop/product/spi/**`
- `shop-core/src/main/java/com/shop/shop/common/exception/**`
- `shop-core/src/main/java/com/shop/shop/security/**`
- `shop-core/src/main/resources/templates/seller/product-variants.html`
- `shop-core/src/main/resources/templates/fragments/**`
- `shop-core/src/main/resources/static/**`
- `shop-core/src/test/java/com/shop/shop/product/**`
- `shop-core/src/test/java/com/shop/shop/security/**`

## Backend - View Contract

| 항목 | 값 |
|---|---|
| 옵션/variant 관리 화면 경로 | `GET /seller/products/{productId}/variants` |
| 옵션/variant 관리 View name | `seller/product-variants` |
| 템플릿 경로 | `templates/seller/product-variants.html` |
| 옵션 생성 폼 action | `POST /seller/products/{productId}/options` |
| 옵션값 생성 폼 action | `POST /seller/products/{productId}/options/{optionId}/values` |
| variant 생성 폼 action | `POST /seller/products/{productId}/variants` |
| variant 수정 폼 action | `POST /seller/products/{productId}/variants/{variantId}` |
| 옵션 폼 필드 | `name` |
| 옵션값 폼 필드 | `value` |
| variant 폼 필드 | `sku`, `price`, `stock`, `active`, `optionValueIds` |
| 상품 모델 키 | `product` |
| 옵션 목록 모델 키 | `options` |
| variant 목록 모델 키 | `variants` |
| 옵션 폼 모델 키 | `optionForm` |
| 옵션값 폼 모델 키 | `optionValueForm` |
| variant 폼 모델 키 | `variantForm` |
| 성공 리다이렉트 | `/seller/products/{productId}/variants` |
| 실패 렌더링 | `seller/product-variants` |

## Acceptance Criteria
- `SELLER`는 자기 상품의 옵션/variant 관리 화면에 접근할 수 있다
- `ADMIN`은 모든 상품의 옵션/variant 관리 화면에 접근할 수 있다
- `CONSUMER`와 비인증 사용자는 옵션/variant 관리 화면에 접근할 수 없다
- 다른 판매자의 상품 옵션/variant 관리 접근은 403 또는 404로 실패한다
- 판매자는 상품 옵션을 생성할 수 있다
- 같은 상품 안에서 같은 옵션명은 중복 생성할 수 없다
- 판매자는 옵션값을 생성할 수 있다
- 같은 옵션 안에서 같은 옵션값은 중복 생성할 수 없다
- 판매자는 SKU, 가격, 재고, 옵션값 조합으로 variant를 생성할 수 있다
- SKU는 중복될 수 없다
- price와 stock은 음수가 될 수 없다
- variant는 활성/비활성 상태를 가진다
- variant 목록 응답과 View 모델에 Entity가 직접 노출되지 않는다
- 상품 이미지, 공개 목록/상세, 장바구니 기능은 구현되지 않는다
- 관련 테스트가 통과한다

## Test
- `./gradlew test`
- 권장 단위 테스트
  - 옵션 생성 성공
  - 옵션명 중복 실패
  - 옵션값 생성 성공
  - 옵션값 중복 실패
  - variant 생성 성공
  - SKU 중복 실패
  - price 음수 실패
  - stock 음수 실패
  - 판매자 소유권 검증 실패
  - ADMIN 전체 상품 관리 성공
- 권장 REST/Security 테스트
  - 옵션/variant 조회 SELLER 성공, ADMIN 성공, CONSUMER 403, 비인증 401
  - 옵션 생성 성공/중복 실패
  - 옵션값 생성 성공/중복 실패
  - variant 생성 성공/검증 실패
  - 타 판매자 상품 접근 실패
- 권장 View 테스트
  - `GET /seller/products/{productId}/variants` SELLER 렌더링
  - 옵션/옵션값/variant 폼 CSRF 포함
  - 옵션 생성 폼 제출 성공 redirect
  - 옵션값 생성 폼 제출 성공 redirect
  - variant 생성 폼 제출 성공 redirect
  - 검증 실패 시 `seller/product-variants` 재렌더링

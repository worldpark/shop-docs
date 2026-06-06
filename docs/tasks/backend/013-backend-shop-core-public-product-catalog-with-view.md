# 013. shop-core 공개 상품 목록 + 상세 화면

> **backend-implementor 완료 (2026-06-06)**
> **view-implementor 완료 (2026-06-06)**
> 신규/수정 파일 목록·테스트 결과·facade 시그니처·docker-compose 수동 확인 항목은 이 문서 최하단 "구현 완료 보고" 절 참고.

## Target
shop-core

---

## Goal
`shop-core`에서 고객과 비인증 사용자가 판매 중인 상품을 탐색할 수 있도록 공개 상품 목록/상세 REST API와 Thymeleaf 화면을 구현해 장바구니와 주문으로 이어지는 쇼핑 흐름의 진입점을 만든다.

---

## Context
- `009`에서 카테고리와 상품 기본 등록/수정 기반을 구현했다
- `010`에서 상품 옵션, 옵션값, variant 관리 기반을 구현했다
- `012`에서 상품 이미지 업로드, 대표 이미지, 정렬 관리 기반을 구현했다
- 공개 상품 조회는 `docs/rules/api-authorization-rule.md` 기준 public API다
- 공개 목록/상세에는 `ON_SALE`과 `SOLD_OUT` 상품을 노출하고, `SOLD_OUT`은 품절(구매 불가)로 표시한다. `DRAFT`/`HIDDEN`은 노출하지 않는다
- 상품 status는 `DRAFT`, `ON_SALE`, `SOLD_OUT`, `HIDDEN` 중 하나다
- 전문 검색/Elasticsearch는 후속 도입 예정이며, 이번 Task는 DB 쿼리 기반 keyword 검색만 신규 구현한다(상품명 부분 일치, 대소문자 구분 없음)
- 구매 단위는 `product_variants`이며, 고객은 상세 화면에서 활성 variant와 옵션 정보를 확인해야 한다
- 상품 이미지는 DB의 `storage_key`를 기반으로 `AssetUrlResolver` 같은 단일 컴포넌트에서 URL을 합성한다
- 이번 Task는 장바구니 담기 직전의 카탈로그 탐색 기능까지만 다룬다
- API 추가 시 `docs/rules/api-authorization-rule.md`를 따른다
- 이미지 URL 합성은 `docs/rules/static-asset-rule.md`를 따른다

## API Authorization

| API | 공개 여부 | 최소 권한 | 상위 권한 허용 | 소유권 검사 | 비고 |
|---|---|---|---|---|---|
| `GET /products` | public | 없음 | 해당 없음 | 불필요 | 공개 상품 목록 화면 |
| `GET /products/{productId}` | public | 없음 | 해당 없음 | 불필요 | 공개 상품 상세 화면 |
| `GET /api/v1/products` | public | 없음 | 해당 없음 | 불필요 | 공개 상품 목록 API |
| `GET /api/v1/products/{productId}` | public | 없음 | 해당 없음 | 불필요 | 공개 상품 상세 API |
| `GET /api/v1/categories` | public | 없음 | 해당 없음 | 불필요 | 기존 공개 카테고리 조회 API |
| `GET /assets/**` 또는 설정된 정적 자산 경로 | public | 없음 | 해당 없음 | 불필요 | 상품 이미지 조회 |

## Requirements
- 공개 상품 목록 API를 구현한다
  - `GET /api/v1/products`
  - page, size pagination
  - keyword 검색: 상품명 부분 일치, 대소문자 구분 없음
  - categoryId 필터
  - sort: 최신순(createdAt), 낮은 가격순, 높은 가격순. **가격 정렬은 page 쿼리 단계에서 활성 variant `min(price)`(없으면 `basePrice`) 집계를 정렬 키로 수행**(= `displayPrice`를 쿼리에서 계산, 메모리 정렬 금지)
  - `ON_SALE`과 `SOLD_OUT`을 노출하고, 구매 불가 상품은 `soldOut=true`로 표시(정의는 API Response Contract). `DRAFT`/`HIDDEN` 제외
  - 대표 이미지 URL 포함
  - `displayPrice` 포함 = 활성 variant의 최소 price, 활성 variant가 없으면 `basePrice` 폴백
  - **`displayPrice`는 page 쿼리의 projection에서 가져오고, 대표 이미지만 `productId IN (...)` 배치 조회로 N+1을 회피한다**
- 공개 상품 상세 API를 구현한다
  - `GET /api/v1/products/{productId}`
  - `ON_SALE`과 `SOLD_OUT` 상품만 조회 가능 (`SOLD_OUT`은 `soldOut=true`·구매 불가 표시). `DRAFT`/`HIDDEN`/미존재는 404
  - 상품 기본 정보, 카테고리, 이미지 목록, 옵션/옵션값, 활성 variant 목록, `displayPrice` 포함
  - 비활성 variant는 고객에게 노출하지 않는다
  - 대표 이미지와 이미지 목록은 정렬 순서대로 노출한다
- 공개 상품 목록 화면을 구현한다
  - `GET /products`
  - 검색어, 카테고리 필터, 정렬, pagination UI
  - 상품 카드: 대표 이미지, 상품명, 표시 가격, 품절 또는 구매 가능 상태 표시
- 공개 상품 상세 화면을 구현한다
  - `GET /products/{productId}`
  - 이미지 갤러리
  - 상품명, 설명, `displayPrice`와 선택 가능한 variant 가격
  - 옵션/variant 선택에 필요한 정보 표시
  - 장바구니 버튼은 이번 Task에서 동작 구현하지 않으며, 필요하면 비활성 또는 후속 안내 상태로 둔다
- `ProductPublicService` 또는 기존 product service에 공개 조회 전용 메서드를 구현한다
- REST Controller는 `RestController -> ServiceResponse -> Service -> Repository` 레이어를 따른다
- ViewController는 `web` 모듈에 두고 `ViewController(@Controller) -> product.spi View facade -> Service -> Repository` 레이어를 따른다
- `web` 모듈은 product 내부 `domain`, `repository`, 비공개 `service` 패키지를 직접 참조하지 않는다
- 공개 상품 화면용 product facade를 `product.spi` named interface로 노출한다
- `SecurityConfig`에 공개 경로를 명시적으로 추가한다 (현재 두 경로 모두 `anyRequest().authenticated()`로 보호됨)
  - REST 체인(`/api/v1/**`): `GET /api/v1/products`, `GET /api/v1/products/{productId}` permitAll
  - View 체인: `GET /products`, `GET /products/{productId}` permitAll
- DTO와 Entity를 분리한다
- Entity를 API 응답이나 View 모델에 직접 전달하지 않는다
- 목록/상세 응답에 판매자 ownerId, 내부 storage root, 로컬 파일 시스템 절대 경로를 노출하지 않는다
- 관련 단위 테스트, REST/Security 테스트, View 렌더링 테스트, 구조 테스트를 작성한다

## Constraints
- 이번 Task에서 장바구니 담기 기능을 구현하지 않는다
- 이번 Task에서 주문 생성, 결제, 재고 차감/복원 기능을 구현하지 않는다
- 이번 Task에서 상품 리뷰, 찜, 추천, 최근 본 상품 기능을 구현하지 않는다
- 이번 Task에서 상품 검색 엔진, 전문 검색, Elasticsearch를 도입하지 않는다
- 이번 Task에서 관리자/판매자 상품 관리 기능을 변경하지 않는다
- 공개 목록/상세에 `DRAFT`, `HIDDEN` 상품을 노출하지 않는다
- 비활성 variant를 공개 상세에 노출하지 않는다
- DB에 저장된 `storage_key`를 절대 URL로 변경하지 않는다
- Controller에서 비즈니스 로직을 작성하지 않는다
- `notification` 코드나 DB를 참조하지 않는다
- 이벤트 계약은 변경하지 않는다
- 기존 migration을 수정하지 않는다
- 필요한 조회 성능 개선이 있더라도 신규 인덱스는 실제 병목이 확인된 후 후속 Task로 분리한다

## Files
- `shop-core/src/main/java/com/shop/shop/product/controller/**`
- `shop-core/src/main/java/com/shop/shop/product/service/**`
- `shop-core/src/main/java/com/shop/shop/product/repository/**`
- `shop-core/src/main/java/com/shop/shop/product/dto/**`
- `shop-core/src/main/java/com/shop/shop/product/spi/**`
- `shop-core/src/main/java/com/shop/shop/web/product/**`
- `shop-core/src/main/java/com/shop/shop/common/dto/**`
- `shop-core/src/main/java/com/shop/shop/common/exception/**`
- `shop-core/src/main/java/com/shop/shop/common/storage/**`
- `shop-core/src/main/java/com/shop/shop/security/**`
- `shop-core/src/main/resources/templates/product/list.html`
- `shop-core/src/main/resources/templates/product/detail.html`
- `shop-core/src/main/resources/templates/fragments/nav.html`
- `shop-core/src/main/resources/static/**`
- `shop-core/src/test/java/com/shop/shop/product/**`
- `shop-core/src/test/java/com/shop/shop/web/product/**`
- `shop-core/src/test/java/com/shop/shop/view/**`
- `shop-core/src/test/java/com/shop/shop/security/**`

## Module Boundary Contract

| 항목 | 위치 | 규칙 |
|---|---|---|
| Public REST Controller | `product/controller` | `/api/v1/products/**`, `ServiceResponse` 사용 |
| Public ViewController | `web/product` | Thymeleaf SSR, product facade만 의존 |
| Public View facade interface | `product/spi` | `@NamedInterface("spi")` published API |
| Public View facade implementation | `product/service` | product service/repository 위임, Entity -> DTO 변환 |
| URL resolver | `common/storage` 또는 기존 위치 | storageKey -> public image URL 합성 단일 책임 |
| View model/Form/DTO | `product/dto` 또는 `web/product` | Entity 직접 노출 금지 |

권장 facade:

- `PublicProductFacade`
  - 공개 상품 목록 조회
  - 공개 상품 상세 조회
  - 카테고리 필터용 카테고리 목록 조회
  - storageKey -> imageUrl 변환은 DTO 조립 과정에서 단일 resolver 사용

## Backend - View Contract

| 항목 | 값 |
|---|---|
| 공개 상품 목록 경로 | `GET /products` |
| 공개 상품 목록 View name | `product/list` |
| 공개 상품 목록 템플릿 | `templates/product/list.html` |
| 공개 상품 상세 경로 | `GET /products/{productId}` |
| 공개 상품 상세 View name | `product/detail` |
| 공개 상품 상세 템플릿 | `templates/product/detail.html` |
| 목록 검색 파라미터 | `keyword`, `categoryId`, `sort`, `page`, `size` |
| 상품 목록 모델 키 | `products` |
| 검색 조건 모델 키 | `searchCondition` |
| 카테고리 목록 모델 키 | `categories` |
| 상품 상세 모델 키 | `product` |
| 상세 이미지 목록 모델 키 | `product.images` |
| 상세 옵션 목록 모델 키 | `product.options` |
| 상세 variant 목록 모델 키 | `product.variants` |
| nav 공개 상품 링크 | `/products` |

## API Response Contract

권장 DTO:

- `PublicProductSummaryResponse`
  - `productId`
  - `name`
  - `displayPrice`
  - `categoryId`
  - `categoryName`
  - `primaryImageUrl`
  - `soldOut`
- `PublicProductDetailResponse`
  - `productId`
  - `name`
  - `description`
  - `displayPrice`
  - `soldOut`
  - `category`
  - `images`
  - `options`
  - `variants`
- `PublicProductImageResponse`
  - `imageId`
  - `imageUrl`
  - `sortOrder`
  - `primary`
- `PublicProductOptionResponse`
  - `optionId`
  - `name`
  - `values`
- `PublicProductVariantResponse`
  - `variantId`
  - `price`
  - `optionValueIds`
  - `available`  (구매 가능 여부 = `product.status == ON_SALE && variant.stock > 0`)

주의:

- `soldOut`(상품 단위)은 **구매 가능 여부를 status와 variant 재고로 함께 판정**한다: `soldOut = !(status == ON_SALE && 재고>0인 활성 variant가 1개 이상 존재)`. 따라서 `SOLD_OUT` 상품, `ON_SALE`이지만 구매 가능 variant가 없는 상품, 활성 variant가 아예 없는 상품은 모두 `soldOut=true`다. 목록·상세 모두 `ON_SALE`/`SOLD_OUT`만 포함하고 `DRAFT`/`HIDDEN`은 제외한다
- `available`(variant 단위)은 `available = (product.status == ON_SALE && variant.stock > 0)`로 판정한다. `SOLD_OUT` 상품의 variant는 재고가 남아 있어도 `available=false`(구매 불가)다
- `displayPrice`는 활성 variant의 최소 `price`이며, 활성 variant가 없으면 `basePrice`로 폴백한다. **가격 정렬은 page 쿼리 단계에서 활성 variant `min(price)`(없으면 `basePrice`) 집계 기준으로 수행한다** — DTO 조립 후 메모리 정렬이 아니다(GROUP BY 집계 + countQuery로 페이징)
- `basePrice`는 **내부/관리용 가격**이며 공개 응답(요약·상세)에 필드로 노출하지 않는다. 공개 가격은 `displayPrice` 단일 필드로만 제공한다(`basePrice`는 displayPrice 폴백·정렬 계산에만 내부적으로 사용)
- `sku`는 공개 응답에서 제외한다(내부 운영 식별자). variant 재고는 정확한 수량 대신 `available`(boolean)로만 노출한다. 상세에는 활성 variant만 포함하므로 `active` 필드는 두지 않는다
- `ownerId`, `storageKey`, 로컬 절대 경로, Entity 객체는 공개 응답에 포함하지 않는다

## Acceptance Criteria
- 비인증 사용자는 공개 상품 목록 화면에 접근할 수 있다
- `CONSUMER`, `SELLER`, `ADMIN`도 공개 상품 목록 화면에 접근할 수 있다
- 비인증 사용자는 공개 상품 상세 화면에 접근할 수 있다
- 공개 상품 목록 API는 인증 없이 호출할 수 있다
- 공개 상품 상세 API는 인증 없이 호출할 수 있다
- 목록에는 `ON_SALE`과 `SOLD_OUT` 상품이 노출되고, 구매 불가 상품(`SOLD_OUT`, 또는 `ON_SALE`이지만 구매 가능 variant 없음)은 `soldOut=true`로 표시된다
- 목록에는 `DRAFT`, `HIDDEN` 상품이 노출되지 않는다
- 목록은 keyword로 상품명을 검색할 수 있다 (부분 일치, 대소문자 구분 없음)
- 목록은 categoryId로 필터링할 수 있다
- 목록은 최신순, 그리고 활성 variant `min(price)`(없으면 `basePrice`) 집계를 정렬 키로 한 낮은/높은 가격순으로 정렬된다(쿼리 단계 정렬)
- 목록은 pagination 메타데이터를 제공한다
- 상품 카드에는 대표 이미지 URL, 상품명, `displayPrice`, 품절 여부가 노출된다
- `displayPrice`는 활성 variant 최소가이며, 활성 variant가 없으면 `basePrice`로 폴백한다
- 공개 응답(요약·상세)에는 `basePrice`가 노출되지 않고, 공개 가격은 `displayPrice`로만 제공된다
- variant `available`은 `product.status == ON_SALE && stock > 0`이며, `SOLD_OUT` 상품의 variant는 재고가 있어도 `available=false`다
- 활성 variant가 없는 상품은 품절(`soldOut=true`)로 표시된다
- 대표 이미지가 없는 상품도 목록에서 깨지지 않고 placeholder 또는 이미지 없음 상태로 표시된다
- 상세는 `ON_SALE`과 `SOLD_OUT` 상품을 조회할 수 있고, `SOLD_OUT`은 품절·구매 불가로 표시된다
- `DRAFT`, `HIDDEN`, 미존재 상품 상세 요청은 404로 실패한다
- 상세에는 정렬된 이미지 목록이 노출된다
- 상세에는 옵션과 옵션값이 노출된다
- 상세에는 활성 variant만 노출된다
- 비활성 variant는 상세 API와 화면에 노출되지 않는다
- 모든 이미지 URL은 `storageKey`와 설정 기반 base URL로 합성된다
- 공개 응답과 View 모델에 ownerId, 로컬 파일 시스템 절대 경로, Entity가 노출되지 않는다
- 장바구니 담기, 주문, 결제, 재고 차감은 구현되지 않는다
- ViewController는 `web/product`에 위치하고 product 내부 구현에 직접 의존하지 않는다
- 관련 테스트가 통과한다

## Test
- `./gradlew test`
- 권장 단위 테스트
  - 공개 목록 조회 성공
  - 목록에서 `ON_SALE`·`SOLD_OUT` 조회, `DRAFT`/`HIDDEN` 제외
  - soldOut 판정: `SOLD_OUT` 상품 / `ON_SALE`+재고 없음 / 활성 variant 없음 → 모두 `soldOut=true`, 재고 있는 `ON_SALE` → `soldOut=false`
  - keyword 검색 조건 적용 (대소문자 무시 — 대소문자 다른 입력으로 동일 결과)
  - categoryId 필터 적용
  - 활성 variant `min(price)` 집계 기준 가격 정렬(쿼리 단계, 메모리 정렬 아님) — 활성 variant 없는 상품은 `basePrice`로 정렬
  - `displayPrice` 산출 = 활성 variant 최소가 / 활성 variant 없으면 `basePrice` 폴백
  - variant `available` 판정: `SOLD_OUT` 상품 variant는 재고>0이어도 `available=false`
  - 공개 응답(요약·상세)에 `basePrice` 미노출 단언
  - `displayPrice`는 page 쿼리 projection에서 제공, 대표 이미지는 `productId IN (...)` 배치 조회로 N+1 회피
  - 대표 이미지 URL 합성
  - 대표 이미지 없는 상품 DTO 변환
  - 공개 상세 조회 성공 (`ON_SALE`/`SOLD_OUT`)
  - `DRAFT`/`HIDDEN` 상세 조회 실패(404)
  - 미존재 상품 상세 조회 실패(404)
  - 상세 이미지 정렬 유지
  - 상세 옵션/옵션값 DTO 변환
  - 활성 variant만 상세에 포함
  - 비활성 variant 제외
- 권장 REST/Security 테스트
  - `GET /api/v1/products` 비인증 200
  - `GET /api/v1/products` CONSUMER/SELLER/ADMIN 200
  - `GET /api/v1/products/{productId}` 비인증 200 (`ON_SALE`/`SOLD_OUT`)
  - `GET /api/v1/products/{productId}` `DRAFT`/`HIDDEN`/미존재 404
  - 목록 검색/필터/정렬/pagination 응답 구조
  - 상세 응답에 이미지/옵션/variant 포함
  - 응답에 ownerId, storageKey, basePrice 또는 로컬 절대 경로 미포함
- 권장 View 테스트
  - `GET /products` 비인증 렌더링
  - `GET /products` 검색 폼, 카테고리 필터, sort 컨트롤 렌더링
  - `GET /products` 상품 카드 렌더링
  - `GET /products/{productId}` 비인증 렌더링
  - 상세 이미지 갤러리 렌더링
  - 상세 옵션/variant 정보 렌더링
  - 비공개 상품 상세 요청은 error view 또는 404 처리
  - nav에 공개 상품 목록 링크 포함
- 권장 구조 테스트
  - `web.product`가 `product.domain`, `product.repository`, `product.service`를 직접 참조하지 않음
  - `product` 모듈이 `web` 모듈을 참조하지 않음
  - 공개 ViewController가 product facade만 의존
  - `ModularityTests.verify()` 통과

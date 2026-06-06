# 012. shop-core 상품 이미지 업로드 + 대표 이미지 관리 + 화면

## Target
shop-core

---

## Goal
`shop-core`에서 판매자가 자기 상품의 이미지를 업로드하고, 정렬 순서와 대표 이미지를 관리할 수 있는 REST API와 Thymeleaf 화면을 구현해 공개 상품 목록/상세와 장바구니로 이어지는 카탈로그 기반을 강화한다.

---

## Context
- `009`에서 카테고리와 상품 기본 등록/수정 기반을 구현했다
- `010`에서 상품 옵션, 옵션값, variant 관리 기반을 구현했다
- `product_images` 테이블은 V1 스키마에 이미 존재한다
- `product_images`는 `product_id`, `storage_key`, `sort_order`, `is_primary`를 가진다
- 대표 이미지는 상품당 1개만 허용된다
- 현재 정적 자산은 shop-core 로컬 파일 시스템에 저장한다
- 현재 프로젝트에는 정적 리소스 핸들러(`WebMvcConfigurer.addResourceHandlers`)와 multipart 설정이 없으므로 이번 Task에서 신규로 추가한다
- 현재 `SecurityConfig` View 체인은 `/css/**`, `/js/**`, `/images/**`만 `permitAll`이며 `/assets/**` 공개 경로가 없으므로 추가한다
- 이후 Cloudflare R2 + CDN으로 이관할 수 있어야 하므로 도메인 코드는 `ObjectStorage` 인터페이스에만 의존한다
- DB에는 host를 포함하지 않은 `storage_key`만 저장한다
- URL 합성은 설정값과 View/API 응답 조립 한 곳에서 처리한다
- 공개 상품 목록/상세 화면은 후속 Task 범위다
- API 추가 시 `docs/rules/api-authorization-rule.md`를 따른다
- 정적 자산/이미지 저장은 `docs/rules/static-asset-rule.md`를 따른다

## API Authorization

| API | 공개 여부 | 최소 권한 | 상위 권한 허용 | 소유권 검사 | 비고 |
|---|---|---|---|---|---|
| `GET /seller/products/{productId}/images` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | 상품 이미지 관리 화면 |
| `POST /seller/products/{productId}/images` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | 이미지 업로드 폼 제출 |
| `POST /seller/products/{productId}/images/{imageId}/primary` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | 대표 이미지 지정 폼 제출 |
| `POST /seller/products/{productId}/images/{imageId}/order` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | 이미지 정렬 순서 변경 폼 제출 |
| `POST /seller/products/{productId}/images/{imageId}/delete` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | 이미지 삭제 폼 제출 |
| `GET /api/v1/seller/products/{productId}/images` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | 상품 이미지 목록 API |
| `POST /api/v1/seller/products/{productId}/images` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | 이미지 업로드 API |
| `PATCH /api/v1/seller/products/{productId}/images/{imageId}/primary` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | 대표 이미지 지정 API |
| `PATCH /api/v1/seller/products/{productId}/images/{imageId}/order` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | 정렬 순서 변경 API |
| `DELETE /api/v1/seller/products/{productId}/images/{imageId}` | authenticated | `ROLE_SELLER` | `ROLE_ADMIN` | 필요 | 이미지 삭제 API |
| `GET /assets/**` 또는 설정된 정적 자산 경로 | public | 없음 | 해당 없음 | 불필요 | 업로드된 공개 상품 이미지 조회 |

## Requirements
- `ObjectStorage` 인터페이스를 구현한다
  - `String put(String keyPrefix, String originalFilename, String contentType, InputStream inputStream)`
  - 필요 시 `void delete(String storageKey)`
  - 구현 시그니처는 코드 스타일에 맞게 조정 가능하되 도메인 서비스가 구현체에 직접 의존하지 않게 한다
- `LocalObjectStorage`를 구현한다
  - 저장 root는 설정값으로 주입한다
  - 저장 key는 `products/{productId}/{uuid}.{ext}` 형태를 권장한다
  - 동일 key를 덮어쓰지 않는다
  - 경로 traversal을 방지한다
- 업로드된 이미지를 public static resource로 서빙한다
  - URL은 `assetBaseUrl + storageKey` 형태로 합성한다
  - `assetBaseUrl`과 저장 root는 `application.yml` 설정값으로 주입한다
  - `WebMvcConfigurer.addResourceHandlers`로 저장 root를 공개 URL prefix(`/assets/**`)에 매핑한다 (신규)
  - `SecurityConfig` View 체인에 `/assets/**`를 `permitAll`로 추가한다
  - Controller, Service, Template에 base URL을 하드코딩하지 않는다
- `ProductImage` Entity/Repository/Service를 구현한다
  - product
  - storageKey
  - sortOrder
  - isPrimary
- `ProductImageRepository`는 상품별 이미지 목록을 `sortOrder ASC, id ASC`로 조회할 수 있어야 한다
- 이미지 업로드 API와 화면 폼을 구현한다
- 이미지 목록 조회 API를 구현한다
- 대표 이미지 지정 API와 화면 폼을 구현한다
- 정렬 순서 변경 API와 화면 폼을 구현한다
- 잘못 업로드했거나 중복 등록했거나 상품 정보와 맞지 않는 이미지를 정리할 수 있도록 이미지 삭제 API와 화면 폼을 구현한다
- 첫 번째 이미지 업로드 시 자동으로 대표 이미지로 지정한다
- 대표 이미지 지정 시 같은 상품의 기존 대표 이미지는 해제한다
  - `uq_product_images_primary`(partial unique index, `WHERE is_primary`)가 V1에 이미 존재하므로, 기존 대표 해제를 먼저 반영(flush)한 뒤 새 대표를 지정해 동일 트랜잭션 내 제약 위반을 피한다
- 이미지 삭제 시 해당 이미지가 대표 이미지였고 다른 이미지가 남아 있으면 가장 앞 순서 이미지를 대표 이미지로 지정한다
- imageId는 path의 productId 하위 리소스인지 검증한다
- 판매자는 자기 상품 이미지만 관리할 수 있다
- ADMIN은 모든 상품 이미지를 관리할 수 있다
- 업로드 파일은 이미지 MIME type만 허용한다
  - 판정 기준은 요청 Content-Type과 확장자 화이트리스트(jpg/jpeg/png/gif/webp)로 한다 (매직바이트 검사는 이번 범위 밖)
- 허용 확장자와 최대 파일 크기를 설정 또는 상수로 추적 가능하게 둔다
  - `application.yml`에 `spring.servlet.multipart.max-file-size` / `max-request-size`를 설정한다 (현재 multipart 설정 없음)
  - 크기 초과 시 발생하는 `MaxUploadSizeExceededException`을 REST는 400 `ErrorResponse`, View는 flashError로 매핑한다 (현재 generic 핸들러로 빠져 500이 되므로 전용 핸들러를 추가한다)
- 상품당 이미지 개수 상한을 둔다
  - 기본값 상품당 10장. 설정값(`shop.storage.max-images-per-product`)으로 추적 가능하게 둔다(하드코딩 금지)
  - 상한 도달 상태에서 추가 업로드는 storage.put **이전**에 거부한다(파일 저장 후 거부 금지). 거부 시 400으로 응답한다
- 업로드 실패 시 DB 저장이 남지 않아야 한다
- DB 저장 실패 시 가능하면 방금 저장한 파일을 삭제하는 보상 처리를 수행한다
- REST Controller는 `RestController -> ServiceResponse -> Service -> Repository` 레이어를 따른다
- ViewController는 `web` 모듈에 두고 `ViewController(@Controller) -> product.spi View facade -> Service -> Repository` 레이어를 따른다
- `web` 모듈은 product 내부 `domain`, `repository`, 비공개 `service` 패키지를 직접 참조하지 않는다
- 상품 이미지 화면용 product facade를 `product.spi` named interface로 노출한다
- Entity를 API 응답이나 View 모델에 직접 전달하지 않는다
- 관련 단위 테스트, REST/Security 테스트, View 렌더링 테스트, storage 테스트를 작성한다

## Constraints
- 이번 Task에서 공개 상품 목록/상세 화면을 구현하지 않는다
- 이번 Task에서 장바구니 담기 기능을 구현하지 않는다
- 이번 Task에서 이미지 리사이징, 썸네일 생성, WebP 변환을 구현하지 않는다
- 이번 Task에서 Cloudflare R2 연동을 구현하지 않는다
- 이번 Task에서 비공개 객체나 presigned URL을 구현하지 않는다
- DB에 절대 URL이나 host를 저장하지 않는다
- 동일 storage key를 덮어쓰지 않는다
- Controller에서 파일 저장 세부 구현을 직접 처리하지 않는다
- Controller에서 비즈니스 로직을 작성하지 않는다
- DTO와 Entity를 분리한다
- `notification` 코드나 DB를 참조하지 않는다
- 이벤트 계약은 변경하지 않는다
- Flyway V1이 이미 적용된 경우 기존 migration을 수정하지 않는다
- `product_images` 스키마가 이미 충분하면 신규 migration을 추가하지 않는다

## Files
- `shop-core/src/main/java/com/shop/shop/product/controller/**`
- `shop-core/src/main/java/com/shop/shop/product/service/**`
- `shop-core/src/main/java/com/shop/shop/product/repository/**`
- `shop-core/src/main/java/com/shop/shop/product/domain/**`
- `shop-core/src/main/java/com/shop/shop/product/dto/**`
- `shop-core/src/main/java/com/shop/shop/product/spi/**`
- `shop-core/src/main/java/com/shop/shop/web/product/**`
- `shop-core/src/main/java/com/shop/shop/common/storage/**`
- `shop-core/src/main/java/com/shop/shop/common/web/**`
- `shop-core/src/main/java/com/shop/shop/common/exception/**`
- `shop-core/src/main/java/com/shop/shop/security/**`
- `shop-core/src/main/resources/application.yml`
- `shop-core/src/test/resources/application.yml`
- `shop-core/src/main/resources/templates/seller/product-images.html`
- `shop-core/src/main/resources/templates/seller/product-form.html`
- `shop-core/src/main/resources/templates/seller/product-variants.html`
- `shop-core/src/main/resources/templates/fragments/**`
- `shop-core/src/main/resources/static/**`
- `shop-core/src/test/java/com/shop/shop/product/**`
- `shop-core/src/test/java/com/shop/shop/web/product/**`
- `shop-core/src/test/java/com/shop/shop/common/storage/**`
- `shop-core/src/test/java/com/shop/shop/view/**`

## Module Boundary Contract

| 항목 | 위치 | 규칙 |
|---|---|---|
| Storage interface | `common/storage` | product service가 의존하는 교체 가능 포트 |
| Local storage implementation | `common/storage` 또는 `common/storage/local` | 설정 기반 로컬 파일 저장 |
| Asset URL resolver | `common/storage` | `assetBaseUrl + storageKey` 합성 단일 지점 |
| Static resource handler | `common/web` | 저장 root를 `/assets/**` 공개 URL로 매핑하는 `WebMvcConfigurer` (신규) |
| REST Controller | `product/controller` | `/api/v1/**`, `ServiceResponse` 사용 |
| ViewController | `web/product` | Thymeleaf SSR, product facade만 의존 |
| View facade interface | `product/spi` | `@NamedInterface("spi")` published API |
| View facade implementation | `product/service` | product service/storage/repository 위임, Entity -> DTO 변환 |
| View model/Form/DTO | `product/dto` 또는 `web/product` | Entity 직접 노출 금지 |

권장 facade:

- `SellerProductImageFacade`
  - 이미지 관리 화면 조회
  - 이미지 업로드
  - 대표 이미지 지정
  - 정렬 순서 변경
  - 이미지 삭제
  - actorEmail -> actorId 변환과 ADMIN 여부 전달
  - productId/imageId 소유권 및 하위 리소스 검증 위임

## Backend - View Contract

| 항목 | 값 |
|---|---|
| 이미지 관리 화면 경로 | `GET /seller/products/{productId}/images` |
| 이미지 관리 View name | `seller/product-images` |
| 템플릿 경로 | `templates/seller/product-images.html` |
| 이미지 업로드 폼 action | `POST /seller/products/{productId}/images` |
| 대표 이미지 지정 폼 action | `POST /seller/products/{productId}/images/{imageId}/primary` |
| 정렬 순서 변경 폼 action | `POST /seller/products/{productId}/images/{imageId}/order` |
| 이미지 삭제 폼 action | `POST /seller/products/{productId}/images/{imageId}/delete` |
| 업로드 폼 필드 | `file` |
| 정렬 폼 필드 | `sortOrder` |
| 상품 모델 키 | `product` |
| 이미지 목록 모델 키 | `images` |
| 업로드 폼 모델 키 | `imageUploadForm` |
| 성공 리다이렉트 | `/seller/products/{productId}/images` |
| 실패 렌더링 | `seller/product-images` 또는 flashError redirect |
| `seller/product-form` 화면에서의 이미지 관리 링크 | `/seller/products/{productId}/images` |
| `seller/product-variants` 화면에서의 이미지 관리 링크 | `/seller/products/{productId}/images` |

## API Response Contract

권장 응답 DTO:

- `ProductImageResponse`
  - `imageId`
  - `productId`
  - `storageKey`
  - `imageUrl`
  - `sortOrder`
  - `primary`

주의:

- `imageUrl`은 응답 조립 시 `AssetUrlResolver` 같은 단일 컴포넌트에서 합성한다
- Entity와 절대 파일 시스템 경로는 응답에 포함하지 않는다
- DB에는 `storageKey`만 저장한다

## Acceptance Criteria
- `SELLER`는 자기 상품 이미지 관리 화면에 접근할 수 있다
- `ADMIN`은 모든 상품 이미지 관리 화면에 접근할 수 있다
- `CONSUMER`와 비인증 사용자는 상품 이미지 관리 화면에 접근할 수 없다
- 다른 판매자의 상품 이미지 관리 접근은 403 또는 404로 실패한다
- 판매자는 자기 상품에 이미지를 업로드할 수 있다
- 첫 이미지 업로드 시 해당 이미지가 대표 이미지가 된다
- 추가 이미지 업로드 시 기존 대표 이미지는 유지된다
- 대표 이미지 지정 시 같은 상품의 다른 대표 이미지는 해제된다
- 이미지 정렬 순서를 변경할 수 있다
- 판매자는 잘못 업로드했거나 중복 등록했거나 더 이상 상품 정보와 맞지 않는 자기 상품 이미지를 삭제할 수 있다
- 대표 이미지를 삭제한 경우 다른 이미지가 남아 있으면 가장 앞 정렬 순서의 이미지가 새 대표 이미지로 자동 지정된다
- 마지막 남은 이미지를 삭제한 경우 해당 상품은 대표 이미지가 없는 상태가 된다
- imageId가 path의 productId 하위 리소스가 아니면 요청은 실패한다
- 이미지가 아닌 파일 업로드는 실패한다
- 허용 크기를 초과한 파일 업로드는 실패한다
- 상품당 이미지 개수 상한(기본 10장)에 도달하면 추가 업로드는 400으로 실패하고, 파일이 저장되지 않는다
- DB에는 host 없는 storage key만 저장된다
- API 응답과 View 모델에는 Entity와 로컬 파일 시스템 절대 경로가 노출되지 않는다
- 저장된 이미지는 public URL로 조회할 수 있다
- ViewController는 `web/product`에 위치하고 product 내부 구현에 직접 의존하지 않는다
- 공개 상품 목록/상세, 장바구니 기능은 구현되지 않는다
- 관련 테스트가 통과한다

## Test
- `./gradlew test`
- 권장 단위 테스트
  - 이미지 업로드 성공
  - 첫 이미지 업로드 시 대표 이미지 자동 지정
  - 추가 이미지 업로드 시 기존 대표 유지
  - 대표 이미지 지정 성공
  - 대표 이미지 지정 시 기존 대표 해제
  - 정렬 순서 변경 성공
  - 잘못 업로드했거나 중복 등록한 이미지 삭제 성공
  - 대표 이미지 삭제 시 가장 앞 정렬 순서 이미지가 후속 대표 이미지로 지정
  - 마지막 이미지 삭제 시 대표 이미지 없음 상태 허용
  - imageId가 productId 하위 리소스가 아니면 실패
  - 판매자 소유권 검증 실패
  - ADMIN 전체 상품 이미지 관리 성공
  - 이미지 MIME type이 아니면 실패
  - 파일 크기 초과 실패
  - 상품당 이미지 개수 상한 도달 시 추가 업로드 실패(400) + storage.put 미호출
  - storage put 실패 시 DB 저장 미수행
  - DB 저장 실패 시 storage delete 보상 호출
- 권장 Storage 테스트
  - `LocalObjectStorage`가 설정 root 아래에만 저장
  - storage key가 `products/{productId}/...` 형태
  - 동일 파일명 업로드도 서로 다른 key 생성
  - path traversal 입력이 저장 root 밖으로 나가지 않음
  - `AssetUrlResolver`가 baseUrl과 storageKey를 한 곳에서 합성
  - 업로드된 이미지가 `/assets/**` 공개 URL로 인증 없이 200 조회됨 (ResourceHandler + SecurityConfig permitAll 검증)
- 권장 REST/Security 테스트
  - 이미지 목록 SELLER 성공, ADMIN 성공, CONSUMER 403, 비인증 401
  - 이미지 업로드 multipart 성공
  - 이미지 업로드 검증 실패 400
  - 이미지가 아닌 MIME/확장자 업로드 400
  - 최대 크기 초과 업로드가 `MaxUploadSizeExceededException` → 400 `ErrorResponse`로 매핑됨
  - 대표 이미지 지정 성공
  - 정렬 순서 변경 성공
  - 잘못 업로드했거나 중복 등록한 이미지 삭제 성공
  - 타 판매자 상품 접근 실패
  - 응답에 로컬 절대 경로 미포함
- 권장 View 테스트
  - `GET /seller/products/{productId}/images` SELLER 렌더링
  - 이미지 업로드 폼 CSRF 포함
  - 대표 이미지 지정 폼 CSRF 포함
  - 정렬 순서 변경 폼 CSRF 포함
  - 이미지 삭제 폼 CSRF 포함
  - 업로드 성공 redirect
  - 검증 실패 시 `seller/product-images` 재렌더링 또는 flashError 표시
  - 상품 수정 화면 또는 variant 관리 화면에서 이미지 관리 링크 노출
- 권장 구조 테스트
  - `web.product`가 `product.domain`, `product.repository`, `product.service`를 직접 참조하지 않음
  - `product` 모듈이 `web` 모듈을 참조하지 않음
  - product service가 `LocalObjectStorage` 구현체가 아니라 `ObjectStorage` 인터페이스에 의존
  - `ModularityTests.verify()` 통과

# 012. shop-core 상품 이미지 업로드 + 대표 이미지 관리 + 화면 — 구현 계획(plan)

> Task SSOT: docs/tasks/backend/012-backend-shop-core-product-image-management-with-view.md
> 본 문서는 구현 위임용 plan이다. 코드 작성은 backend-implementor / view-implementor가 수행한다.
> 선례 코드(010 variant 관리 스택)의 네이밍·레이어·예외 패턴을 그대로 따른다.

---

## 0. 사전 확정 사실 (점검 완료)

- product_images 테이블은 V1에 이미 존재한다 (product_id, storage_key text NOT NULL, sort_order int NOT NULL DEFAULT 0, is_primary boolean NOT NULL DEFAULT false). 신규 Flyway migration 금지 (Constraint 준수).
- partial unique index uq_product_images_primary ON product_images(product_id) WHERE is_primary 존재. 대표 재지정 시 기존 대표 unset 먼저 flush한 뒤 새 대표 set 순서가 강제된다 (동일 트랜잭션 제약 위반 회피).
- 보조 인덱스 idx_product_images_product_id 존재.
- 현재 프로젝트에 WebMvcConfigurer / addResourceHandlers가 전혀 없다 -> common/web에 신규 추가.
- 현재 application.yml에 multipart 설정이 없다 -> spring.servlet.multipart.* 신규 추가.
- 현재 RestExceptionHandler에 MaxUploadSizeExceededException 전용 핸들러가 없어 generic Exception 핸들러로 빠져 500이 된다 -> REST 400 / View flashError 전용 핸들러 추가 필요.
- 현재 SecurityConfig View 체인 permitAll: /css/**, /js/**, /images/**, /favicon.ico, /error, GET /login, GET·POST /signup. /assets/** 없음 -> 추가 필요.
- 소유권 위반은 기존 ProductService.getOwnedProduct() -> ProductAccessDeniedException(404) 패턴 재사용. RoleHierarchy(ADMIN>SELLER>CONSUMER)로 ADMIN이 hasRole(SELLER) 자동 통과.
- REST principal=userId(long), View principal=email(form login). REST는 (long)auth.getPrincipal(), View는 CurrentActorResolver -> UserDirectory.findUserIdByEmail.

---

## 1. 설계 방식 및 이유

### 1.1 전체 구조 — 010 variant 스택 미러링
이미지 관리 스택을 기존 variant 관리 스택과 동일한 레이어 형태로 구성한다.

- REST: SellerProductImageRestController -> ProductImageServiceResponse -> ProductImageService -> ProductImageRepository
- View: SellerProductImageViewController(web/product) -> SellerProductImageFacade(product.spi) -> ProductImageService -> Repository
- facade 구현체 SellerProductImageFacadeImpl은 product 내부 service 패키지에 두고 UserDirectory로 email->userId 변환 + Entity->DTO 변환을 담당한다.

이유: 컨벤션 일관성, 리뷰 비용 최소화, 모듈 경계(web->product.spi 단방향) 자동 준수.

### 1.2 Storage 포트 분리 (R2 이관 대비)
- common/storage에 ObjectStorage 포트 인터페이스를 둔다. 도메인 서비스(ProductImageService)는 이 인터페이스에만 의존한다.
- 운영 구현체 LocalObjectStorage는 @Component로 등록하되 도메인은 인터페이스만 주입받는다 -> 추후 R2ObjectStorage로 무중단 교체 가능.
- URL 합성은 AssetUrlResolver 단일 컴포넌트에서만 수행(assetBaseUrl + storageKey). Controller/Service/Template에 base URL 하드코딩 금지. DB에는 storageKey만 저장(host·절대경로 금지).

이유: static-asset-rule / architecture.md 7절 준수, 저장소 교체 가능성 확보.

### 1.3 대표 이미지 불변식을 도메인 서비스에 집중
대표 이미지 1개 제약, 첫 업로드 자동 대표, 대표 재지정 시 기존 해제, 대표 삭제 시 승계 규칙을 전부 ProductImageService에 둔다. Controller/Facade는 위임만 한다(비즈니스 로직 금지). partial unique index 충돌은 unset -> flush(saveAndFlush) -> set 순서로 회피한다.

### 1.4 소유권/하위리소스 검증 재사용
- 소유권: ProductService.getOwnedProduct(actorId, actorIsAdmin, productId) 호출(타인 상품 -> ProductAccessDeniedException 404, 미존재 -> ProductNotFoundException 404). 비SELLER는 Security 단에서 403/401로 차단.
- 하위 리소스: imageId가 path productId 소속인지 검사. variant의 VariantNotFoundException(404) 패턴을 본떠 ImageNotFoundException(404)를 신규로 둔다(메시지 톤·404 동일).

### 1.5 업로드 트랜잭션 경계 / 보상
- multipart 수신은 Controller에서, ObjectStorage.put() 호출은 Service에서(static-asset-rule).
- 순서: storage.put 먼저 -> DB 저장. put 실패 시 DB 저장이 일어나지 않는다.
- DB 저장 실패(예외) 시 방금 put한 파일을 ObjectStorage.delete(storageKey)로 보상 삭제. 보상은 try/catch로 감싸 보상 실패가 원본 예외를 가리지 않게 한다.

### 1.6 파일 검증 규칙 (확장자/MIME) — 단일 스펙
업로드된 파일은 아래 두 조건을 **모두** 통과해야 한다. 위반 시 `InvalidImageFileException`(400). 검증 위치는 `ProductImageService.upload()`(storage.put 호출 **이전**) 단일 지점이며, Controller·Facade는 검증하지 않는다.

1. **확장자 화이트리스트** (대소문자 무시): `jpg`, `jpeg`, `png`, `gif`, `webp` 만 허용.
   - `svg`는 `<script>` 내장 → same-origin 서빙 시 stored XSS 위험이 있어 **의도적으로 제외**한다.
   - 확장자는 `originalFilename`의 마지막 `.` 이후 토큰으로 추출하고, 저장 key(`{uuid}.{ext}`)의 `{ext}`로 그대로 사용한다.
2. **Content-Type 검증**: 요청 `contentType`이 `image/` 로 시작해야 한다. (헤더는 위조 가능하므로 확장자 화이트리스트와 **병행** — 둘 중 하나라도 실패하면 거부.)

- 허용 확장자 목록은 `StorageProperties.allowedExtensions`(설정값, `application.yml`의 `shop.storage.allowed-extensions`)로 추적 가능하게 둔다. 코드/템플릿에 하드코딩 금지.
- 매직바이트(파일 시그니처) 검사는 Task 명시 범위 밖 → 구현하지 않는다(7절 트레이드오프 참조).
- 확장자가 없거나 화이트리스트 밖이면 거부(예: `evil.html`, `evil.svg`, 확장자 없는 파일).

### 1.7 상품당 이미지 개수 상한
- 상품당 이미지 개수 상한을 둔다(기본 10장). `StorageProperties.maxImagesPerProduct`(설정값 `shop.storage.max-images-per-product`)로 추적. 하드코딩 금지.
- 검사 위치: `ProductImageService.upload()`에서 **storage.put 이전** (파일 저장 후 거부 금지). 현재 이미지 수를 `ProductImageRepository.countByProductId(productId)`로 조회(엔티티 전량 로드 대신 count 쿼리).
- 상한 도달 시 `ImageLimitExceededException`(신규, extends BusinessException, 400)을 던진다(메시지에 상한값 포함). 예외명/톤은 기존 Image 예외(ImageNotFoundException/InvalidImageFileException) 컨벤션을 따른다.

---

## 2. 구성 요소 (신규/수정 파일)

### 2.1 backend-implementor 담당

#### 신규 — common/storage
- common/storage/ObjectStorage.java — 포트 인터페이스.
  - String put(String keyPrefix, String originalFilename, String contentType, InputStream inputStream)
  - void delete(String storageKey)
- common/storage/LocalObjectStorage.java — @Component 운영 구현체. 저장 root는 설정 주입. key={keyPrefix}/{uuid}.{ext}. 동일 key 덮어쓰기 금지(CREATE_NEW/exists 체크). path traversal 방지(정규화 후 root 하위 검증).
- common/storage/AssetUrlResolver.java — @Component. toUrl(storageKey) = assetBaseUrl + 슬래시 + storageKey 합성 단일 지점.
- common/storage/StorageProperties.java — @ConfigurationProperties(prefix=shop.storage). root(저장 경로), assetBaseUrl, 허용 확장자 화이트리스트, public URL prefix.

> Storage 클래스 패키지는 common/storage 단일 패키지로 둔다(Module Boundary Contract 허용 범위). common은 Modulith OPEN 모듈이라 추가 named interface 선언 불필요.

#### 신규 — common/web
- common/web/StaticResourceConfig.java — WebMvcConfigurer 구현. addResourceHandlers로 publicPrefix(/assets/**) -> file 저장 root 매핑. StorageProperties 주입.

#### 신규 — common/exception
- common/exception/ImageNotFoundException.java — extends BusinessException, 404. 메시지 톤은 VariantNotFoundException 따름.
- common/exception/InvalidImageFileException.java — extends BusinessException, 400. 비이미지 MIME/확장자 거부용. (또는 BusinessException(message, BAD_REQUEST) 직접 사용 — 명시적 예외 권장)

#### 수정 — common/exception
- common/exception/RestExceptionHandler.java — @ExceptionHandler(MaxUploadSizeExceededException.class) 추가 -> 400 ErrorResponse. generic Exception 핸들러보다 우선 매칭.
- common/exception/ViewExceptionHandler.java — @ExceptionHandler(MaxUploadSizeExceededException.class) 추가 -> flashError 처리. redirect 대상 확보가 어려우면 error/error 뷰(400)로 폴백. ViewController 차원 처리와 핸들러 폴백 중 하나로 통일하고 View 테스트로 고정.

#### 신규 — product/domain
- product/domain/ProductImage.java — @Entity @Table(name=product_images). 필드: id, @ManyToOne(LAZY) product, storageKey, sortOrder, @Column(name=is_primary) isPrimary. 테이블에 created_at/updated_at 컬럼이 없으므로 시간 컬럼 매핑 없음(BaseEntity 미상속). 정적 팩토리 create + 의도 메서드(markPrimary, unmarkPrimary, changeSortOrder). Setter 금지.

#### 신규 — product/repository
- product/repository/ProductImageRepository.java — JpaRepository<ProductImage, Long>.
  - findByProductIdOrderBySortOrderAscIdAsc(long productId)
  - findByProductIdAndIsPrimaryTrue(long productId) (대표 조회/해제용)
  - 하위리소스 검증은 service에서 image.getProduct().getId() == productId 비교.

#### 신규 — product/service
- product/service/ProductImageService.java — @Service @Transactional. 도메인 로직 단일 소유. actorId/actorIsAdmin 시그니처, ProductService 위임:
  - listImages(actorId, actorIsAdmin, productId)
  - upload(actorId, actorIsAdmin, productId, originalFilename, contentType, InputStream) — MIME/확장자 검증 -> storage.put -> DB 저장 -> 첫 이미지면 isPrimary=true. sortOrder는 max+1 또는 count 기반.
  - setPrimary(actorId, actorIsAdmin, productId, imageId) — 하위리소스 검증 -> 기존 대표 unset+saveAndFlush -> 대상 set.
  - changeOrder(actorId, actorIsAdmin, productId, imageId, sortOrder) — 하위리소스 검증 -> sortOrder 변경.
  - delete(actorId, actorIsAdmin, productId, imageId) — 하위리소스 검증 -> DB 삭제 -> 대표였고 잔여 존재 시 가장 앞(sortOrder ASC, id ASC) 승계(saveAndFlush 순서 주의) -> storage.delete 보상.
- product/service/ProductImageServiceResponse.java — @Service. REST 전용. auth.getPrincipal() long + isAdmin 추출 -> ProductImageService 위임 -> ProductImageResponse.from(entity, assetUrlResolver) 변환.
- product/service/SellerProductImageFacadeImpl.java — SellerProductImageFacade 구현(package-private). UserDirectory로 email->userId 변환, ProductImageService 위임, Entity->DTO 변환.

#### 신규 — product/spi
- product/spi/SellerProductImageFacade.java — published port 인터페이스(@NamedInterface spi 패키지). 시그니처는 6절 참조.

#### 신규 — product/dto
- product/dto/ProductImageResponse.java — record(long imageId, long productId, String storageKey, String imageUrl, int sortOrder, boolean primary). 정적 팩토리 from(ProductImage, AssetUrlResolver). Entity·절대경로 미노출.
- product/dto/ProductImageManagementView.java — record(SellerProductRef product, List<ProductImageResponse> images). facade 화면 조회 반환 타입(VariantManagementView 미러링).

#### 수정 — security
- security/SecurityConfig.java — View 체인 permitAll에 /assets/** 추가. REST 체인은 변경 없음(/api/v1/seller/** = hasRole(SELLER) 이미 적용).

#### 수정 — resources
- shop-core/src/main/resources/application.yml — spring.servlet.multipart.max-file-size/max-request-size 추가, shop.storage.{root, asset-base-url, allowed-extensions, public-prefix} 추가.
- shop-core/src/test/resources/application.yml — 테스트용 shop.storage 임시 디렉터리, multipart 한도(작게) 추가. multipart 자동설정이 test 프로파일에서 제외되지 않았는지 확인.

#### 신규 — 테스트 (backend)
- product/service/ProductImageServiceTest.java — 단위(Mockito): 업로드 성공, 첫 업로드 자동 대표, 추가 업로드 기존 대표 유지, 대표 지정 성공, 대표 지정 시 기존 해제(unset->flush->set 순서 검증), 정렬 변경, 삭제 성공, 대표 삭제 시 가장 앞 승계, 마지막 삭제 시 대표 없음, imageId 하위리소스 불일치 실패(404), 소유권 실패(404), ADMIN 전체 관리 성공, 비이미지 MIME/확장자 실패(400), storage.put 실패 시 DB 미저장(save 미호출 verify), DB 저장 실패 시 storage.delete 보상 호출(verify).
- product/service/ProductImageServiceResponseTest.java — auth principal/admin 추출 + DTO 변환 + imageUrl 합성 위임 검증.
- product/service/SellerProductImageFacadeImplTest.java — email->userId 변환·위임·DTO 변환 검증.
- common/storage/LocalObjectStorageTest.java — root 하위 저장, key=products/{productId}/ 형태, 동일 파일명도 서로 다른 key, path traversal 입력이 root 밖으로 안 나감, 동일 key 미덮어쓰기.
- common/storage/AssetUrlResolverTest.java — baseUrl+storageKey 단일 합성.
- product/controller/SellerProductImageRestControllerSecurityTest.java — @SpringBootTest @AutoConfigureMockMvc @ActiveProfiles(test), 010 패턴: 목록 SELLER 200/ADMIN 200/CONSUMER 403/비인증 401; multipart 업로드 성공; 검증 실패 400; 비이미지 MIME/확장자 400; MaxUploadSizeExceededException -> 400 ErrorResponse; PATCH primary 성공; PATCH order 성공; DELETE 성공; 타 판매자 404; 응답에 로컬 절대경로 미포함 단언.
- assets 공개 조회 테스트: 업로드된 이미지가 /assets/**로 인증 없이 200(ResourceHandler + permitAll 검증).

#### 구조 테스트
- ModularityTests는 그대로 verify() 통과(신규 모듈 추가 없음). web->product 내부 직접 참조 부재는 Modulith가 검증. 필요 시 web.product가 product.domain/repository/service 미참조, product가 web 미참조, service가 ObjectStorage 인터페이스 의존(LocalObjectStorage 미참조)을 추가 검증.

### 2.2 view-implementor 담당

#### 신규 — web/product
- web/product/SellerProductImageViewController.java — @Controller @RequestMapping(/seller/products/{productId}/images). SellerProductVariantViewController 패턴. GET 관리 화면, POST 업로드, POST /{imageId}/primary, POST /{imageId}/order, POST /{imageId}/delete. CurrentActorResolver로 actor 추출, SellerProductImageFacade 위임. 성공 flashSuccess + PRG redirect, BusinessException flashError + redirect. 업로드 검증 실패 시 재렌더 또는 flashError(3·4절 정책).
- web/product/ImageUploadForm.java — 폼 객체. 필드 MultipartFile file(@NotNull). model key imageUploadForm.
- 정렬은 단일 필드 sortOrder만 받으므로 @RequestParam int sortOrder로 대체 가능(Backend-View Contract의 sortOrder 필드명 유지).

#### 신규 — templates
- templates/seller/product-images.html — 이미지 관리 화면. 모델: product(SellerProductRef), images(List<ProductImageResponse>), imageUploadForm. 업로드 폼(enctype=multipart/form-data, field file), 각 이미지 행에 대표지정·정렬변경(field sortOrder)·삭제 폼(각 CSRF 자동). 이미지 미리보기는 imageUrl 사용(base URL 하드코딩 금지). flashSuccess/flashError 영역(fragments/messages.html 재사용).

#### 수정 — templates
- templates/seller/product-form.html — 이미지 관리 링크 추가(/seller/products/{productId}/images).
- templates/seller/product-variants.html — 이미지 관리 링크 추가(/seller/products/{productId}/images).
- (필요 시) templates/fragments/* — 공통 메시지/네비 재사용 확인.

#### 신규 — 테스트 (view)
- view/SellerProductImagesRenderingTest.java — @SpringBootTest @AutoConfigureMockMvc, SellerProductImageFacade @MockitoBean, @WithMockUser(roles=SELLER): GET 렌더링, 업로드 폼 CSRF + multipart enctype, 대표지정 폼 CSRF, 정렬 폼 CSRF + sortOrder 필드, 삭제 폼 CSRF, 업로드 성공 redirect, 검증 실패 재렌더/flashError, 이미지 목록 imageUrl 노출.
- web/product/SellerProductImageViewControllerTest.java — 컨트롤러 단위(facade mock): 모델 키(product/images/imageUploadForm) 주입, redirect 경로, flash 처리.
- 링크 노출 검증: product-form/product-variants 렌더링 테스트에 이미지 관리 링크 노출 케이스 추가(기존 SellerProductFormRenderingTest/SellerProductVariantsRenderingTest 보강).

---

## 3. 데이터 흐름

### 3.1 업로드 (POST images)
1. 요청: REST POST /api/v1/seller/products/{productId}/images(multipart, part file) 또는 View POST /seller/products/{productId}/images(form file).
2. 인증/권한: Security 체인이 hasRole(SELLER) 검사(ADMIN 함의). 미인증 401(REST)/redirect(View), CONSUMER 403.
3. principal 해석: REST auth.getPrincipal() long + isAdmin / View CurrentActorResolver -> facade에서 UserDirectory.findUserIdByEmail.
4. 소유권: ProductService.getOwnedProduct(actorId, isAdmin, productId) (타인/미존재 404).
5. 파일 검증: contentType이 image 타입인지 + 확장자 화이트리스트(jpg/jpeg/png/gif/webp). 위반 -> InvalidImageFileException(400). (매직바이트 검사 제외)
6. storage.put: ObjectStorage.put(products/{productId}, originalFilename, contentType, inputStream) -> storageKey 반환.
7. DB 저장: ProductImage.create(product, storageKey, sortOrder, isPrimary). sortOrder=기존 max+1. 첫 이미지면 isPrimary=true, 아니면 false(기존 대표 유지).
8. 응답: REST 200 ProductImageResponse(imageUrl=AssetUrlResolver 합성) / View flashSuccess + redirect /seller/products/{productId}/images.
9. 보상: 7에서 예외 시 ObjectStorage.delete(storageKey) 호출(파일 정리). put 실패(6) 시 7 미실행 -> DB 잔여 없음.

### 3.2 대표 지정 (PATCH primary / POST .../primary)
1~4. 업로드와 동일(소유권 검사).
5. 하위리소스: imageId 로드 후 image.product.id == productId 검증(불일치/미존재 -> ImageNotFoundException 404).
6. 기존 대표 해제: findByProductIdAndIsPrimaryTrue(productId) -> 존재 시 unmarkPrimary() -> saveAndFlush(partial unique index 충돌 회피 — 기존 대표를 먼저 DB에 반영).
7. 대상 대표 지정: image.markPrimary().
8. 응답: REST 200 ProductImageResponse / View flashSuccess + redirect.

### 3.3 정렬 변경 (PATCH order / POST .../order)
1~5. 소유권 + 하위리소스 검증.
6. image.changeSortOrder(sortOrder) (dirty checking).
7. 응답: REST 200 / View flashSuccess + redirect.

### 3.4 삭제 (DELETE / POST .../delete)
1~5. 소유권 + 하위리소스 검증.
6. 대표 여부·storageKey 보관 후 DB에서 이미지 삭제.
7. 승계: 삭제 대상이 대표였고 잔여 이미지 존재 시 findByProductIdOrderBySortOrderAscIdAsc(productId)의 첫 행을 markPrimary() (삭제 flush 후 승계 set으로 unique index 충돌 회피). 잔여 없으면 대표 없음 상태 허용.
8. storage 보상: ObjectStorage.delete(storageKey)로 실제 파일 제거(try/catch — 파일 정리 실패가 트랜잭션을 깨지 않게 로그만).
9. 응답: REST 204/200 / View flashSuccess + redirect.

### 3.5 목록 / 관리 화면
- REST GET .../images: 소유권 검사 -> findByProductIdOrderBySortOrderAscIdAsc -> ProductImageResponse 리스트(imageUrl 합성).
- View GET .../images: facade getManagementView(product ref + images) -> 모델 product/images/imageUploadForm.

### 3.6 공개 조회
- 업로드 파일은 LocalObjectStorage root 하위에 저장 -> StaticResourceConfig가 /assets/** -> 저장 root 파일 서빙 -> SecurityConfig View 체인 permitAll -> 인증 없이 200. URL은 AssetUrlResolver가 합성.

---

## 4. 예외 처리 전략

| 상황 | 발생 지점 | 매핑 | 비고 |
|---|---|---|---|
| 비인증 | Security | REST 401 JSON / View redirect /login | 기존 EntryPoint·formLogin |
| 권한 부족(CONSUMER) | Security | REST 403 JSON / View 403 | hasRole(SELLER) |
| 상품 미존재 | ProductService | 404 ProductNotFoundException | 기존 |
| 타 판매자 상품 | ProductService | 404 ProductAccessDeniedException | 존재 은닉(403/404 AC 충족) |
| imageId 하위리소스 불일치/미존재 | ProductImageService | 404 ImageNotFoundException(신규) | variant 패턴 |
| 비이미지 MIME/확장자 | ProductImageService | 400 InvalidImageFileException(신규) | 확장자 화이트리스트 |
| 상품당 이미지 개수 상한 초과 | ProductImageService(put 이전) | 400 ImageLimitExceededException(신규) | countByProductId >= max, storage.put 미호출 |
| 파일 크기 초과 | multipart resolver | MaxUploadSizeExceededException -> REST 400 / View flashError | 신규 핸들러(현재 generic->500) |
| @Valid 폼 검증 실패 | Controller | REST 400(MethodArgumentNotValid 기존) / View 재렌더 또는 flashError | |
| storage.put 실패 | ObjectStorage | 예외 전파 -> DB 저장 미실행 | 순서: put->DB |
| DB 저장 실패 | Repository | storage.delete 보상 호출 후 예외 전파 | try/catch로 보상 실패 격리 |
| unique index 충돌(대표) | DB | 사전 회피: unset->saveAndFlush->set | 동일 트랜잭션 위반 방지 |

핵심 규칙:
- put 먼저, DB 나중 -> put 실패 시 DB 잔여 없음.
- DB 실패 시 방금 put한 key를 보상 삭제.
- 대표 전이는 항상 기존 대표 해제 flush 후 새 대표 지정.

---

## 5. 검증 방법 (테스트 매핑)

### 단위 (ProductImageServiceTest)
- 업로드 성공 / 첫 업로드 자동 대표 / 추가 업로드 기존 대표 유지
- 대표 지정 성공 / 대표 지정 시 기존 해제(unset saveAndFlush 호출 순서 verify)
- 정렬 변경 성공
- 삭제 성공 / 대표 삭제 시 가장 앞 승계 / 마지막 삭제 시 대표 없음
- imageId 하위리소스 불일치 404 / 소유권 실패 404 / ADMIN 전체 성공
- 비이미지 MIME 400 / 화이트리스트 밖 확장자(.html, .svg, 확장자 없음) 400 / 허용 확장자(jpg·png 등) 성공
- 상품당 개수 상한 도달 시 추가 업로드 400(ImageLimitExceededException) + storage.put 미호출 verify
- storage.put 실패 시 repository.save 미호출 verify
- DB save 실패 시 storage.delete(storageKey) 호출 verify

### Storage (LocalObjectStorageTest / AssetUrlResolverTest)
- root 하위에만 저장 / key=products/{productId}/ / 동일 파일명 다른 key / path traversal root 밖 차단 / 동일 key 미덮어쓰기
- AssetUrlResolver baseUrl+storageKey 단일 합성
- /assets/** 인증 없이 200 (ResourceHandler+permitAll)

### REST/Security (SellerProductImageRestControllerSecurityTest)
- 목록 SELLER 200 / ADMIN 200 / CONSUMER 403 / 비인증 401
- multipart 업로드 성공 / 검증 실패 400 / 비이미지 400 / MaxUploadSizeExceeded -> 400 ErrorResponse
- 대표 지정 성공 / 정렬 변경 성공 / 삭제 성공
- 타 판매자 404 / 응답에 로컬 절대경로 미포함 단언

### View (SellerProductImagesRenderingTest / SellerProductImageViewControllerTest)
- GET SELLER 렌더링 / 업로드·대표·정렬·삭제 폼 CSRF 포함 / 업로드 multipart enctype
- 업로드 성공 redirect / 검증 실패 재렌더 또는 flashError
- product-form·product-variants 이미지 관리 링크 노출

### 구조
- web.product가 product.domain/repository/service 미참조
- product가 web 미참조
- ProductImageService가 ObjectStorage(인터페이스) 의존(LocalObjectStorage 미참조)
- ModularityTests.verify() 통과

실행: ./gradlew test 전체 통과. 로컬 파일 저장 실동작은 LocalObjectStorageTest로 검증(임시 디렉터리).

---

## 6. 양 영역 인터페이스 접점 (어긋남 방지)

### SellerProductImageFacade (product.spi) 시그니처

    ProductImageManagementView getManagementView(String actorEmail, boolean actorIsAdmin, long productId);
    ProductImageResponse upload(String actorEmail, boolean actorIsAdmin, long productId,
                                String originalFilename, String contentType, java.io.InputStream inputStream);
    ProductImageResponse setPrimary(String actorEmail, boolean actorIsAdmin, long productId, long imageId);
    ProductImageResponse changeOrder(String actorEmail, boolean actorIsAdmin, long productId, long imageId, int sortOrder);
    void delete(String actorEmail, boolean actorIsAdmin, long productId, long imageId);

> ViewController는 MultipartFile에서 getOriginalFilename()/getContentType()/getInputStream()을 꺼내 facade에 primitive/String/InputStream으로 전달한다(web이 도메인 타입 비참조, facade가 MultipartFile에 의존하지 않게). 확정: InputStream + 메타데이터 3종 전달로 통일(SellerProductVariantFacade의 primitive 전달 원칙 유지). 스트림은 ViewController가 try-with-resources로 열어 facade 호출을 그 안에서 수행한다.

### 모델 키 (View)
- product -> SellerProductRef
- images -> List<ProductImageResponse>
- imageUploadForm -> ImageUploadForm
- flash: flashSuccess / flashError

### 폼 필드 / 경로 (Backend-View Contract)
- 업로드 폼 필드: file / action POST /seller/products/{productId}/images / enctype=multipart/form-data
- 대표 지정: POST /seller/products/{productId}/images/{imageId}/primary
- 정렬: 필드 sortOrder / POST /seller/products/{productId}/images/{imageId}/order
- 삭제: POST /seller/products/{productId}/images/{imageId}/delete
- 성공 redirect: redirect:/seller/products/{productId}/images
- View name: seller/product-images

### REST 경로
- GET /api/v1/seller/products/{productId}/images
- POST /api/v1/seller/products/{productId}/images (multipart, part file)
- PATCH /api/v1/seller/products/{productId}/images/{imageId}/primary
- PATCH /api/v1/seller/products/{productId}/images/{imageId}/order (body sortOrder)
- DELETE /api/v1/seller/products/{productId}/images/{imageId}

### ProductImageResponse 필드
imageId, productId, storageKey, imageUrl, sortOrder, primary (record). from(ProductImage, AssetUrlResolver).

### 설정 키 (application.yml)
- spring.servlet.multipart.max-file-size, max-request-size
- shop.storage.root, shop.storage.asset-base-url, shop.storage.public-prefix(/assets), shop.storage.allowed-extensions

---

## 7. 트레이드오프

- put->DB 순서 + 보상 삭제: 분산 트랜잭션 대신 best-effort 보상. DB 실패 후 보상 삭제까지 실패하면 고아 파일이 남을 수 있으나(로컬 디스크, 캐시 무효화 비용 없음) 단순성·정합성 우선. 향후 R2 전환 시 동일 패턴 재사용 가능.
- 확장자/Content-Type 화이트리스트만(매직바이트 미검사): Task 명시 범위. 위장 파일 업로드 가능성은 남으나 이번 범위 밖. 비공개 객체·presigned도 제외.
- 대표 전이 saveAndFlush: partial unique index 회피 위해 추가 flush 비용 발생. 정합성·DB 제약 준수가 우선.
- InputStream 전달 facade: web이 MultipartFile에 의존하지 않아 경계는 깨끗하나, 스트림 수명 관리 주의 필요. ViewController에서 try-with-resources로 stream을 열고 facade 호출을 그 안에서 수행하도록 구현 가이드.
- 이미지 리사이징/썸네일/WebP 변환·공개 목록/상세·장바구니 미구현: Task Constraint 준수. 카탈로그 기반만 확보.
- common/storage 단일 패키지(local 하위 패키지 미분리): 구현체 1개뿐이라 과분리 회피. R2 추가 시 분리 재고.

# 044. 정적 자산 저장소 R2 이관 (LocalObjectStorage → R2ObjectStorage)

> 출처: 사용자 요청 — "Cloudflare R2를 구독했다. 이관에 필요한 작업". CLAUDE.md 예고("정적 자산: 로컬 파일 시스템 → 이후 Cloudflare R2 + CDN 이관 예정") 및 `docs/rules/static-asset-rule.md` 실현.
> 범위 확정: 기존 `ObjectStorage` 포트는 그대로 두고 **R2 구현체 신설 + 프로파일/프로퍼티 토글**. 로컬은 dev/test 기본값으로 유지(무중단 교체 가능 구조 보존). 도메인 코드(ProductImageService 등) 무수정.

## 사용자 제공 R2 자격/설정 (콘솔 셋업 완료)
| 항목 | 값 | 용도 |
|---|---|---|
| 버킷 이름 | `shop-assets` | `shop.storage.r2.bucket` |
| Endpoint | `https://410f95d2a733c88f5eede0b1d1d6da7e.r2.cloudflarestorage.com` | S3 client endpointOverride |
| Account ID | `410f95d2a733c88f5eede0b1d1d6da7e` | (endpoint에 포함) |
| 공개 도메인 | `https://pub-11275ec7614d4295b763327d7a5c9f9b.r2.dev` | `shop.storage.asset-base-url`(R2 프로파일) |
| Access Key ID / Secret | **env 전용**(커밋·문서 기재 금지) | `shop.storage.r2.access-key` / `secret-key` |

## 현황 / 갭 (실사 확정)
| 구성요소 | 상태 | 위치 |
|---|---|---|
| `ObjectStorage`(포트: put/delete) | ✅ 추상화 완료 | `common/storage/ObjectStorage.java` |
| `LocalObjectStorage` | ✅ 로컬 구현, **무조건 `@Component`** | `common/storage/LocalObjectStorage.java` |
| `AssetUrlResolver`(URL 합성 단일 지점) | ✅ `assetBaseUrl + publicPrefix + "/" + key` | `common/storage/AssetUrlResolver.java` |
| `StorageProperties` | ✅ root/asset-base-url/public-prefix/allowed-extensions/max | `common/storage/StorageProperties.java` |
| `StaticResourceConfig`(로컬 파일 서빙) | ✅ `prefix + "/**"` ResourceHandler, `@ConditionalOnBean(StorageProperties)` | `common/web/StaticResourceConfig.java` |
| DB 저장값 | ✅ **storageKey만**(`products/{id}/{uuid}.ext`), 절대 URL·host 없음 | `ProductImage.storageKey` 등 |
| 도메인 사용처 | ✅ `ProductImageService`가 `ObjectStorage`/`AssetUrlResolver`에만 의존 | 무수정 대상 |
| **R2 구현체** | ❌ 없음 | 신설 |
| **AWS SDK v2(S3) 의존성** | ❌ 없음 | build.gradle 추가 |
| **저장소 토글(local/r2)** | ❌ 없음(Local 무조건 등록) | `shop.storage.type` 신설 |

## Target / Goal
운영(prod) 프로파일에서 정적 자산을 **Cloudflare R2(S3 호환 API)** 에 저장·서빙하고, 공개 URL은 R2 공개 도메인을 가리킨다. 로컬/테스트는 종전 `LocalObjectStorage`를 그대로 사용(인프라 비의존 테스트 원칙·dev 편의 유지). 전환은 **설정(프로퍼티)만으로** 이뤄지며 도메인 코드는 건드리지 않는다.

## 범위 (Scope) — backend-implementor
### 1. 의존성
- AWS SDK for Java v2 S3(`software.amazon.awssdk:s3`) 추가. 버전은 `software.amazon.awssdk:bom`(최신 안정 2.x)을 `dependencyManagement.imports`로 관리(jjwt·modulith BOM 선례와 동일 스타일).
- 테스트: S3 호환 라운드트립 검증용 `org.testcontainers:minio`(testImplementation). 버전은 testcontainers-bom(Spring Boot BOM) 관리.

### 2. 프로퍼티 (`StorageProperties` 확장)
- `type`: `local`(기본, matchIfMissing) | `r2` — 구현체 토글 키.
- 중첩 `r2`: `endpoint`, `bucket`, `region`(기본 `auto`), `access-key`, `secret-key`. **access-key/secret-key는 env 주입 전용**(application.yml에 평문 금지, `${SHOP_STORAGE_R2_ACCESS_KEY:}` 형태).

### 3. R2 구현체 + S3 client 빈
- `common/storage/R2ObjectStorage implements ObjectStorage`:
  - `put`: 기존 키 규칙(`{keyPrefix}/{uuid}.{ext}`) 유지 → `PutObjectRequest`(bucket, key, contentType) + body. **InputStream 길이 미상** → 이미지 페이로드 한정으로 바이트 버퍼링 후 `RequestBody.fromBytes`(허용 — 멀티파트 상한이 버퍼 크기를 제한, 아래 검증). 실패 시 `StorageException`.
  - `delete`: `DeleteObjectRequest` — S3 delete는 키 부재에도 성공(멱등성, 포트 계약과 일치). 실패 시 `StorageException`.
- `common/storage/R2StorageConfig`(@Configuration, `type=r2`): `S3Client` 빈 — `endpointOverride`, `Region.of("auto")`, `StaticCredentialsProvider`, **path-style access 활성화**(account-id 엔드포인트 호환). credentials는 StorageProperties.r2에서.

### 4. 빈 토글 (`@ConditionalOnProperty`)
- `LocalObjectStorage`: `@ConditionalOnProperty(prefix="shop.storage", name="type", havingValue="local", matchIfMissing=true)`.
- `R2ObjectStorage`/`S3Client`/`R2StorageConfig`: `havingValue="r2"`.
- `StaticResourceConfig`: **local 일 때만 등록**(`havingValue="local", matchIfMissing=true`). 이유 ↓ Non-goals 위 "핵심 주의".

### 5. 설정 파일
- `application.yml`: `shop.storage.type`(기본 local), `shop.storage.r2.*`(env 플레이스홀더, 시크릿 평문 금지).
- 운영 프로파일(예 `application-prod.yml` 신설 또는 기존 prod 설정): `type=r2`, `asset-base-url=https://pub-...r2.dev`, `public-prefix=""`(R2 공개 도메인은 버킷 루트가 곧 도메인 루트 → AssetUrlResolver가 `base + "" + "/" + key`로 정상 합성), r2.endpoint/bucket 지정.

## 핵심 주의 (리뷰 필수 체크)
- **빈 publicPrefix × StaticResourceConfig 충돌**: R2 프로파일에서 `public-prefix=""`면 `StaticResourceConfig`가 `"" + "/**"` = `/**` ResourceHandler를 등록해 **전체 라우팅을 가로챈다**. 따라서 R2 프로파일에선 `StaticResourceConfig`를 반드시 비활성(type=local 조건). SecurityConfig의 `/assets/**` permitAll은 R2에서 무해하므로 유지.
- **AssetUrlResolver는 무수정**: 빈 prefix(`base + "" + "/" + key`)로 R2 공개 URL이 정확히 합성됨을 테스트로 고정.
- **시크릿 비노출**: access-key/secret-key는 env로만. 코드·yml·문서·로그에 평문 금지(로깅 시 마스킹).
- **버퍼링 안전성**: `RequestBody.fromBytes` 사용 시 `spring.servlet.multipart.max-file-size` 등 업로드 상한이 메모리 버퍼를 제한하는지 확인(미설정이면 R2 범위에서 합리적 상한 명시).

## Non-goals
- 도메인 코드(`ProductImageService`·컨트롤러·Entity·DTO·템플릿) 수정 — 포트 시그니처 불변, 전부 무수정.
- 기존 로컬 `./uploads` 파일의 R2 일괄 이전(rclone/`aws s3 sync`) — **운영 절차(코드 아님)**. storageKey 경로가 동일하면 데이터 변경 불필요. 본 task는 코드/설정 한정, 마이그레이션은 별도 운영 단계로 안내만.
- CDN 커스텀 도메인 전환(`cdn.*`) — 지금은 `pub-*.r2.dev` 공개 URL 사용. 도메인 준비 시 `asset-base-url`만 교체(코드 무변경).
- 멀티파트(분할) 업로드·서명 URL·presigned 다운로드 — 비범위(이미지 직접 PUT/공개 GET으로 충분).
- `ObjectStorage` 포트 시그니처 변경(contentLength 추가 등) — 버퍼링으로 회피, 포트 안정 유지.

## 검증
- **단위**: `R2ObjectStorage` — S3Client mock으로 put 시 PutObjectRequest(bucket/key 규칙/contentType) 정확 구성, key가 `{prefix}/{uuid}.{ext}`, delete가 키 부재에도 예외 없음(멱등) 검증.
- **통합(MinIO Testcontainers, S3 호환)**: 실 라운드트립 — put→객체 존재/내용 일치→delete→부재 확인. R2 실서버·과금 없이 wire 동작 고정([[testing-rule]] 실인프라 충실성 원칙).
- **빈 배선/조건부 토글**([[testing-rule]] §조건부 빈 true 경로 + 운영 배선 검증):
  - `type=r2` 컨텍스트: `context.getBean(ObjectStorage.class) instanceof R2ObjectStorage`, `StaticResourceConfig` 빈 부재(=/** 미등록).
  - 기본(type 미지정) 컨텍스트: `instanceof LocalObjectStorage`, `StaticResourceConfig` 등록.
  - 이 토글 테스트는 **조건 누락 시 RED**(예: Local이 무조건 등록되어 R2와 충돌)임을 실제로 확인.
- `AssetUrlResolver`: publicPrefix="" + R2 base → `https://pub-...r2.dev/products/10/uuid.jpg` 정합 단위 테스트.
- 메인 최종: Modulith verify(common 내부 신규 빈, 모듈 경계 영향 없음 확인) + 풀 스위트 그린. 신규 repo 의존 추가 없음 → `@MockSharedRepositories` 영향 없음 예상이나 풀 게이트로 확인([[full-context-test-repo-mock-shared-annotation]]).
- 수동(선택, 운영 검증): prod 프로파일 기동 → 이미지 업로드 → R2 콘솔 객체 생성 확인 → 공개 URL 200. 확인/미확인 보고에 기록.

## 참고 (실사)
- 포트/구현/합성: `common/storage/{ObjectStorage,LocalObjectStorage,AssetUrlResolver,StorageProperties}.java`, `common/web/StaticResourceConfig.java`.
- 사용처(무수정 확인용): `product/service/ProductImageService.java`(put/delete + 보상 삭제 패턴), 이미지 URL 노출 DTO·템플릿(`product/detail.html`, `list.html`).
- 보안 공개 경로: `security/SecurityConfig.java` line 165 `/assets/**` permitAll(R2에서 무해, 유지).
- 빌드: `shop-core/build.gradle`(BOM imports 스타일 33-58, testcontainers 92-94).
- 설정: `application.yml`(shop.storage 129-, multipart 상한 확인), `application-local.yml`(storage 26-).

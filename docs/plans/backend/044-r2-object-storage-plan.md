# Plan 044. 정적 자산 저장소 R2 이관 (LocalObjectStorage → R2ObjectStorage)

> 대상 Task: `docs/tasks/backend/044-backend-shop-core-r2-object-storage.md`
> 범위: `ObjectStorage` 포트 유지 + R2 구현체/S3 client/프로퍼티 토글 신설. 로컬은 dev/test 기본 유지. 도메인 코드 무수정. 전환은 설정만으로.
> 순서: backend-implementor(의존성+프로퍼티+R2 구현+토글+테스트) → reviewer → 메인 Modulith verify+풀 게이트. (화면/REST 변경 없음 → view-implementor·e2e 불요. 운영 검증은 수동 선택.)

## 0. 확정 사실 (코드 검증됨)
- `ObjectStorage`(common.storage): `String put(keyPrefix, originalFilename, contentType, InputStream)`, `void delete(storageKey)`. 도메인은 이 포트에만 의존(`ProductImageService` 생성자 주입). **시그니처 불변** — Local·R2가 동일 계약 구현.
- `LocalObjectStorage`: 현재 `@Component`(무조건 등록). key 규칙 `{keyPrefix}/{uuid}.{ext}`, 동일 키 존재 시 `StorageException`, delete는 `deleteIfExists`(멱등). `StorageException`(common.storage)이 실패 표준.
- `AssetUrlResolver.toUrl`: `stripTrailingSlash(assetBaseUrl) + publicPrefix + "/" + storageKey`. **publicPrefix=""**면 `base + "" + "/" + key` → R2 공개 URL 정확 합성. **무수정**.
- `StorageProperties`(@ConfigurationProperties "shop.storage"): root, assetBaseUrl, publicPrefix, allowedExtensions, maxImagesPerProduct. `@Getter/@Setter`.
- `StaticResourceConfig`(common.web, `@ConditionalOnBean(StorageProperties)`, WebMvcConfigurer): `registry.addResourceHandler(prefix + "/**").addResourceLocations(file:root)`. **prefix=""면 `/**` 등록 → 전 라우팅 가로챔. R2에선 비활성 필수.**
- `SecurityConfig` line 165: `/assets/**` permitAll(View 체인). R2에선 해당 요청 없음 → 무해, 유지.
- DB는 storageKey만 저장(절대 URL 금지) — 저장소 교체 시 DB·도메인 무영향.
- build.gradle: BOM은 `dependencyManagement.imports`로 관리(modulith). jjwt/redisson은 버전 직접 명시. Testcontainers는 BOM 위임(postgresql만 현재).

## 1. 의존성 (build.gradle)
### 1.1 AWS SDK v2 S3
- `dependencyManagement.imports`에 `mavenBom "software.amazon.awssdk:bom:<최신 안정 2.x>"` 추가(예 2.31.x 계열 — 빌드 시 해석되는 최신 패치로 핀).
- `dependencies`에 `implementation 'software.amazon.awssdk:s3'`(버전은 BOM). apache-client 등 별도 HTTP 클라이언트 미지정 시 SDK 기본(URLConnection/apache) 사용 — 기본으로 충분, 추가 의존 금지(최소 의존).
### 1.2 테스트
- `testImplementation 'org.testcontainers:minio'`(버전 testcontainers-bom 위임). MinIO = S3 호환 → R2 라운드트립 대용. docker 필요(기존 PostgreSQL Testcontainers와 동일 전제).

## 2. 프로퍼티 (`StorageProperties` 확장)
- 필드 추가:
  - `private String type = "local";` — 토글 키(`local`|`r2`).
  - 중첩 정적 클래스 `R2`(getter/setter): `endpoint`, `bucket`, `region = "auto"`, `accessKey`, `secretKey`. 필드 `private R2 r2 = new R2();`.
- Javadoc에 type/r2 설명 + **secret은 env 주입 전용** 명시.
- `application.yml`(공통): 
  ```
  shop.storage.type: ${SHOP_STORAGE_TYPE:local}
  shop.storage.r2.endpoint: ${SHOP_STORAGE_R2_ENDPOINT:}
  shop.storage.r2.bucket: ${SHOP_STORAGE_R2_BUCKET:}
  shop.storage.r2.region: ${SHOP_STORAGE_R2_REGION:auto}
  shop.storage.r2.access-key: ${SHOP_STORAGE_R2_ACCESS_KEY:}
  shop.storage.r2.secret-key: ${SHOP_STORAGE_R2_SECRET_KEY:}
  ```
  (시크릿 평문 금지 — 빈 기본값 + env 오버라이드.)
- 운영 활성화는 `application-prod.yml`(신설) 또는 배포 env로: `SHOP_STORAGE_TYPE=r2`, `SHOP_STORAGE_ASSET_BASE_URL=https://pub-11275ec7614d4295b763327d7a5c9f9b.r2.dev`, `SHOP_STORAGE_PUBLIC_PREFIX=`(빈), `SHOP_STORAGE_R2_ENDPOINT=https://410f95d2a733c88f5eede0b1d1d6da7e.r2.cloudflarestorage.com`, `SHOP_STORAGE_R2_BUCKET=shop-assets`, 키 2개. **prod yml 신설 시에도 access/secret은 env로만, 평문 금지.**

## 3. R2 구현체 + S3 client 빈 (common.storage)
### 3.1 `R2StorageConfig` (@Configuration)
- `@ConditionalOnProperty(prefix="shop.storage", name="type", havingValue="r2")`.
- `@Bean S3Client s3Client(StorageProperties p)`:
  ```
  S3Client.builder()
      .endpointOverride(URI.create(p.getR2().getEndpoint()))
      .region(Region.of(p.getR2().getRegion()))      // "auto"
      .credentialsProvider(StaticCredentialsProvider.create(
          AwsBasicCredentials.create(p.getR2().getAccessKey(), p.getR2().getSecretKey())))
      .serviceConfiguration(S3Configuration.builder().pathStyleAccessEnabled(true).build())
      .build()
  ```
  - path-style: account-id 엔드포인트(`<acct>.r2.cloudflarestorage.com`)에서 버킷명을 path로 — 가상호스트 DNS 의존 회피, R2 호환.
- S3Client는 closeable이나 싱글톤 빈으로 컨테이너 수명과 일치(명시 close 불요).

### 3.2 `R2ObjectStorage implements ObjectStorage`
- `@Component @ConditionalOnProperty(prefix="shop.storage", name="type", havingValue="r2")`, 생성자 주입 `S3Client`, `StorageProperties`.
- `put(keyPrefix, originalFilename, contentType, in)`:
  1. ext 추출(LocalObjectStorage와 동일 규칙 — **결정: 작은 헬퍼 로직 복제로 확정**(YAGNI, 공용화 보류). 모호성 제거용 확정 지시).
  2. `storageKey = keyPrefix + "/" + UUID.randomUUID() + "." + ext`.
  3. `byte[] bytes = in.readAllBytes();`(이미지 한정 버퍼링 — Non-goals/주의 참조).
  4. `s3.putObject(PutObjectRequest.builder().bucket(bucket).key(storageKey).contentType(contentType).build(), RequestBody.fromBytes(bytes));`
  5. 예외 → `throw new StorageException("R2 업로드 실패: " + storageKey, e)`. 동일 키 충돌 검사는 UUID 키라 사실상 불필요(Local의 exists 체크는 R2에서 비용↑·불요 — 생략, key 유일성에 의존).
  6. `return storageKey;`
- `delete(storageKey)`:
  - `s3.deleteObject(DeleteObjectRequest.builder().bucket(bucket).key(storageKey).build());` — S3는 부재 키도 성공(멱등, 포트 계약 충족). 예외 → `StorageException`.
- 로깅: storageKey만(키·시크릿 평문 금지). debug 수준은 Local과 톤 일치.

## 4. 빈 토글 정리
| 빈 | 조건 |
|---|---|
| `LocalObjectStorage` | `@ConditionalOnProperty(prefix="shop.storage", name="type", havingValue="local", matchIfMissing=true)` |
| `R2ObjectStorage` | `havingValue="r2"` |
| `R2StorageConfig`(S3Client) | `havingValue="r2"` |
| `StaticResourceConfig` | `havingValue="local", matchIfMissing=true`(기존 `@ConditionalOnBean(StorageProperties)`에 **추가** — R2의 `/**` 가로챔 차단) |

- 두 ObjectStorage가 동시에 뜨지 않음(상호배타) → `ObjectStorage` 주입 단일성 보장. 기존 Local 테스트들은 type 미지정 → matchIfMissing=true로 종전대로 Local 사용(무영향).

## 5. 테스트 (타깃, 풀 스위트는 마지막 1회)
### 5.1 단위 — `R2ObjectStorageTest`
- S3Client `@Mock`. put: `verify(s3).putObject(captor, any())` → 캡처한 PutObjectRequest의 bucket·contentType 일치, key가 `^products/10/[uuid]\.jpg$` 패턴(prefix·ext 규칙). StorageProperties는 bucket 세팅한 인스턴스 직접 `new`.
- delete: deleteObject 1회 위임, S3Client가 던지지 않으면 정상 반환. (멱등 의미는 통합에서 실검증.)
- put 시 S3Client가 예외 → `StorageException` 변환 단언.
### 5.2 통합 — `R2ObjectStorageMinioIntegrationTest`(Testcontainers MinIO)
- `@Testcontainers` + MinIOContainer. 컨테이너 endpoint/creds로 S3Client 직접 구성(또는 R2StorageConfig 재사용), 버킷 생성.
- 라운드트립: `put(...)` → 반환 key로 `getObject` 내용 일치 → `delete(key)` → 재조회 404/부재. **부재 키 delete가 예외 없이 통과**(멱등) 단언.
- `test` 인프라 비의존 원칙과 충돌하지 않음(PostgreSQL Testcontainers 선례와 동일 — docker 가용 시 실행).
### 5.3 배선/조건부 토글 — `ObjectStorageWiringTest`
- `@SpringBootTest` 2 변형(`@ActiveProfiles`/`@TestPropertySource`로 type 주입):
  - **type=r2**: `getBean(ObjectStorage.class) instanceof R2ObjectStorage`; `S3Client` 빈 존재; `StaticResourceConfig` 빈 **부재**(`assertThatThrownBy getBean` 또는 `getBeanNamesForType.length==0`). r2 프로퍼티는 더미 endpoint/creds + S3Client는 실연결 안 함(빈 생성만 — lazy/no eager call). 필요한 공유 repo는 `@MockSharedRepositories`.
    - **⚠️ NPE 회피(필수)**: test-resources `application.yml`엔 `shop.storage.r2.*`가 없다. `R2StorageConfig`의 `URI.create(p.getR2().getEndpoint())`는 endpoint=null이면 **빈 생성 단계 NPE**. 따라서 `@TestPropertySource`로 `shop.storage.type=r2` + `shop.storage.r2.endpoint=http://localhost:1`(더미) + `shop.storage.r2.access-key`/`secret-key`(더미 비-null)를 **반드시 주입**한다.
  - **type 미지정(기본)**: `instanceof LocalObjectStorage`; `StaticResourceConfig` 빈 존재.
- **RED 확인 의무**([[testing-rule]]): Local의 `matchIfMissing`/R2 조건을 일부러 빼면 두 빈 충돌(NoUniqueBeanDefinition) 또는 StaticResourceConfig가 r2에서 `/**` 등록됨을 실제로 토글해 실패 확인.
- **기존 `StaticResourcePublicAccessTest` 회귀 명시 체크**: 이 테스트는 `@ActiveProfiles("test")` + `public-prefix=/assets` + type 미지정 → `matchIfMissing=true`로 종전대로 통과해야 한다. 토글 추가가 이 기존 배선 테스트를 깨지 않는지 타깃 실행으로 확인(`--tests "*StaticResourcePublicAccess*"`).
### 5.4 URL 합성 — `AssetUrlResolverTest` 확장
- publicPrefix="" + assetBaseUrl="https://pub-x.r2.dev" + key="products/10/u.jpg" → `https://pub-x.r2.dev/products/10/u.jpg`(이중슬래시·prefix 누락 없음). 기존 `/assets` 케이스도 유지.
### 5.5 실행
- 타깃: `./gradlew test --tests "*R2ObjectStorage*" --tests "*ObjectStorageWiring*" --tests "*AssetUrlResolver*"`.
- 신규 repo 의존 없음 → `@MockSharedRepositories` types 갱신 불요 예상. 단 배선 테스트가 풀 컨텍스트라 누락 repo 발생 시 그때 추가.

## 6. 순서 / 검증 게이트
1. backend-implementor: build.gradle(BOM+s3+minio) → StorageProperties 확장 → R2StorageConfig/R2ObjectStorage → 토글 애너테이션(Local/Static 포함) → application.yml env 플레이스홀더 → 5절 테스트 → 타깃 그린.
2. reviewer: 4절 토글 정합·시크릿 비노출·StaticResourceConfig 차단·포트 계약 충실(멱등 delete)·과설계 여부.
3. 메인: **Modulith verify**(common 신규 빈, 모듈 사이클 무영향) + **풀 `./gradlew test` 그린**(토글 조건 누락이 풀 컨텍스트에서만 드러날 수 있음 — [[full-context-test-repo-mock-shared-annotation]]).
4. (선택, 운영) 수동: SHOP_STORAGE_TYPE=r2 + 키 env로 prod 기동 → 이미지 업로드 → R2 콘솔 객체 확인 → 공개 URL(`pub-*.r2.dev/...`) 200. 보고에 확인/미확인 기록. **이건 코드 게이트 아님(자격증명 필요).**

## 7. 리뷰 관점
- **포트 계약 충실**: R2 put이 동일 key 규칙 반환, delete가 부재 키에도 멱등(통합으로 실검증). 도메인(`ProductImageService`)의 보상 삭제(put 후 DB 실패→delete) 흐름이 R2에서도 그대로 성립.
- **토글 상호배타·기본 무영향**: Local matchIfMissing으로 기존 모든 테스트·dev가 Local 유지. r2/local 동시 등록 불가. ObjectStorage 주입 모호성 없음.
- **StaticResourceConfig 차단**: R2(publicPrefix="")에서 `/**` 핸들러 미등록(배선 테스트로 고정). SecurityConfig `/assets/**`는 유지(무해).
- **시크릿 위생**: access/secret 평문 부재(코드·yml·문서·로그), env 플레이스홀더만. path-style·region=auto·endpointOverride 정확.
- **의존 최소**: AWS SDK BOM 위임(버전 직접 남발 금지), 불필요한 http-client/transfer-manager/sts 미추가. 버퍼링(readAllBytes)은 이미지 상한 내 의식적 트레이드오프로 문서화.
- **모듈 경계**: 신규 빈 전부 common.storage/common.web 내부 — 도메인 모듈 무수정, Modulith 경계 불변.

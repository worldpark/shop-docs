# Plan 045. R2 정적 자산 회복성 강화 — 업로드 타임아웃 + 읽기 캐시/fallback

> 대상 Task: `docs/tasks/backend/045-backend-shop-core-r2-resilience-hardening.md`
> 범위(이번 패스): §1 업로드 타임아웃(필수) + §3 Cache-Control(PutObject) + §3 fallback 이미지(view). 커스텀 도메인은 ops 문서화. **§2 서킷브레이커·§3 CDN 퍼지는 이번 패스 제외**(task가 측정/민감경로 조건부로 명시 — 선반영은 과설계).
> 순서: backend-implementor(타임아웃 + Cache-Control + 프로퍼티 + 테스트) → reviewer → view-implementor(fallback 이미지) → reviewer → 메인 Modulith verify + 풀 게이트.

## 0. 확정 사실 (코드 검증됨 — 044 산출물 기준. 패키지 `com.shop.shop.common.storage`, 식별자로 탐색 — 라인은 근사)
- `R2StorageConfig.s3Client`(`common/storage/R2StorageConfig.java`, ~:42-50): `S3Client.builder().endpointOverride/region/credentials/serviceConfiguration(path-style).build()` — **overrideConfiguration 없음 = apiCallTimeout 미설정**. type=r2일 때만 생성.
- `R2ObjectStorage.put`(`R2ObjectStorage.java`, PutObjectRequest ~:70-75): `in.readAllBytes()` → `PutObjectRequest.builder().bucket().key().contentType().build()` + `RequestBody.fromBytes(bytes)`. **cacheControl 미지정**. delete는 `deleteObject`(S3 멱등). **put·delete 모두 `catch (S3Exception)`만** → 타임아웃(SdkClientException 계열) 미포섭(§1.3).
- `StorageProperties.R2`(`StorageProperties.java`, ~:58-83): endpoint/bucket/region/accessKey/secretKey. **타임아웃·cacheControl 필드 없음**.
- `spring.servlet.multipart.max-file-size: 10MB`(`application.yml`) → 버퍼/업로드 페이로드 상한.
- `StaticResourceConfig`(local 서빙): `addResourceHandler(prefix+"/**").addResourceLocations(...)` — **cachePeriod/cacheControl 미설정**(local↔r2 캐시 비대칭 근거).
- `ProductImageService`는 `ObjectStorage` 포트에만 의존 → S3Client 타임아웃은 put/delete에 자동 적용, **도메인 무수정**.
- 빌드: `software.amazon.awssdk:s3`만 의존(044). 동기 S3Client 기본 HTTP 클라이언트는 apache-client(transitive).

## 1. 업로드 타임아웃 (backend — 1순위·필수)
### 1.1 S3Client overrideConfiguration
- `R2StorageConfig.s3Client`에 `.overrideConfiguration(ClientOverrideConfiguration.builder().apiCallTimeout(...).apiCallAttemptTimeout(...).build())` 추가.
- **apiCallTimeout(전체) / apiCallAttemptTimeout(시도당)을 1순위로 사용**(HTTP 클라이언트 무관, 신규 의존 없음 — "thread 무한 매달림" 위험을 이 둘이 완전 커버).
- `connectionTimeout`/`socketTimeout`(http-client 레벨)은 **선택**: 필요 시 기본 ApacheHttpClient builder로 connectionTimeout만 짧게(연결 실패 빠른 감지). apiCall* 와 중복도가 있어 과설정 지양 — 우선 apiCall* 만으로 시작하고 reviewer가 connection 추가 여부 판단.
### 1.2 타임아웃 값 산정 (task §1 관계 불변식 준수)
- 값은 전부 `StorageProperties.R2` 프로퍼티로 노출 + `application.yml` env 플레이스홀더(`${SHOP_STORAGE_R2_API_CALL_TIMEOUT_MS:...}` 등). **하드코딩 금지.**
- 기본값은 "측정 전 시작값"으로 다음 부등식·페이로드 기준을 만족하게 잡는다(주석으로 근거 명시):
  - `apiCallAttemptTimeout` ≥ (10MB ÷ 보수적 최저 대역폭)에 여유. 예 시작값 15s.
  - `apiCallTimeout` ≥ 재시도횟수 × `apiCallAttemptTimeout`(SDK 기본 standard ≈ 최대 3시도). 예 시작값 45s.
  - `connectionTimeout`(쓰면) 짧게. 예 2s.
- **재시도**: SDK 기본(standard) 유지하되, 위 부등식과 일관. 횟수 하향이 필요하면 `retryStrategy`로 조정(과한 폭주 방지). 기본 유지 시에도 apiCallTimeout이 전체 상한이라 안전.
### 1.3 예외 변환 (확정 작업 — 조건부 아님)
- **코드 사실(검증됨)**: `R2ObjectStorage.put`/`delete`는 현재 **`catch (S3Exception e)`만** 잡는다(+put은 `readAllBytes`의 IOException). 타임아웃 예외 `ApiCallTimeoutException`/`ApiCallAttemptTimeoutException`은 **`SdkClientException → SdkException`** 계열로 `S3Exception`(→AwsServiceException)의 **형제(sibling)** 다. → **현재 catch에 안 잡혀 raw SDK 예외가 그대로 전파**되어 `StorageException` 변환 계약이 깨진다.
- **확정 수정**: `put`·`delete` **둘 다** catch를 넓혀 타임아웃을 `StorageException`으로 변환한다. 방식: `catch (SdkException e)`(S3Exception·SdkClientException 공통 상위)로 일원화하거나, `catch (S3Exception e)`에 더해 `catch (SdkException e)`를 추가(순서: 구체→상위). 메시지는 기존 불변식대로 **storageKey만**(시크릿/키 평문 금지).
- 이 변환 누락이 테스트로 잡히도록 §5.1 (b)의 단언을 "**`StorageException` 인스턴스**(cause=timeout 계열)로 실패"까지 포함한다(아래 §5.1).

## 2. Cache-Control on PutObject (backend — §3 중 쓰기경로 코드)
- `StorageProperties.R2`에 `cacheControl` 필드 추가(기본 `public, max-age=31536000, immutable` — UUID 키라 키 단위 불변). env 오버라이드 가능(`${SHOP_STORAGE_R2_CACHE_CONTROL:...}`).
- `R2ObjectStorage.put`의 `PutObjectRequest.builder()`에 `.cacheControl(storageProperties.getR2().getCacheControl())` 추가.
- **삭제 반영 지연은 이번 패스 코드 변경 없음**(CDN 퍼지=후속). task §3 caveat는 문서로만 보존.
- local↔r2 비대칭: 이번 패스에선 r2만 cacheControl 설정. `StaticResourceConfig` 정렬은 비범위(필요 시 후속) — plan에 인지 항목으로만.

## 3. Fallback 이미지 (view-implementor — §3 읽기경로 UI)
- 상품 이미지를 렌더하는 템플릿(`templates/product/detail.html`, `list.html` 및 이미지 `<img th:src>` 사용처) 실사 후, 각 `<img>`에 **인라인 `onerror` 속성**으로 placeholder 대체:
  - 예 `onerror="this.onerror=null;this.src='/images/placeholder.png'"`(무한 루프 방지 `onerror=null`).
  - **인라인 `onerror` 속성 사용**(별도 `<script>` 아님) → `<main>` 밖 스크립트 드롭 함정([[inline-script-must-be-inside-main-layout-fragment]]) 무관.
- placeholder 정적 자산 `src/main/resources/static/images/placeholder.png`(또는 기존 자산 재사용) 추가 — `/images/**`는 SecurityConfig permitAll(확인됨).
- 404/로드 실패가 레이아웃을 깨지 않음을 보장. 브라우저는 실패 `<img>`를 무한 재시도하지 않으므로 앱측 회복성 불필요.

## 4. Ops 문서화만 (코드 아님)
- 커스텀 도메인 전환: prod env `SHOP_STORAGE_ASSET_BASE_URL`을 `pub-*.r2.dev` → 커스텀 도메인으로 교체(코드 무변경 — `AssetUrlResolver`). 이번 패스는 코드 미포함, task/배포 문서에 절차만.

## 5. 테스트 (타깃, 풀 스위트는 마지막 1회)
### 5.1 타임아웃 — 두 축 분리(unroutable 단일 갈음 금지)
- **테스트용 S3Client는 직접 new로 구성**(044 `R2ObjectStorageMinioIntegrationTest`의 `@BeforeEach` 직접 new 패턴 재사용 — 빈 토글 무관). overrideConfiguration의 `apiCallTimeout`/`apiCallAttemptTimeout`을 **ms 단위로 작게** + **retry를 1~2회로 좁혀** 구성한다(기본 standard 3시도 누적으로 테스트가 느려지거나 의도가 흐려지는 것 방지).
- **(a) 연결 타임아웃**: 연결 거부/도달불가 주소(예 `http://127.0.0.1:<닫힌 포트>` 또는 라우팅 불가 IP)로 → put이 시간 내 실패하고 **`StorageException` 인스턴스**로 변환됨을 단언. **신규 의존 없음.**
- **(b) 응답 지연 타임아웃(핵심)**: **연결은 accept하되 read하지 않는 경량 서버**(테스트 내 `ServerSocket`을 열어 accept 후 소켓을 read하지 않고 블로킹 — 별도 스레드에서 accept만, 신규 의존 없이 socket-read 정체 재현)로 S3Client 구성 →
  - 단언 1: put이 `apiCallTimeout`/`apiCallAttemptTimeout` 내 실패(테스트 자체 안전 타임아웃으로 행 감지 — 무한 매달림 없음).
  - 단언 2: 실패 예외가 **`StorageException`이며 cause가 timeout 계열**(`ApiCallTimeoutException`/`ApiCallAttemptTimeoutException`) — §1.3 변환 확정 작업의 RED 가드.
  - (a)로 (b)를 대체하지 않음을 주석(연결 성공+무응답은 unroutable로 재현 불가).
### 5.2 Cache-Control — MinIO 통합
- 044 MinIO 통합 패턴 재사용: put 후 `headObject`(또는 getObject 메타)에서 `cacheControl`이 설정값과 일치.
### 5.3 빈 토글 회귀
- `type=local`(기본)에서 R2/타임아웃/cacheControl 빈 미생성 — 044 `ObjectStorageWiringTest` 그대로 그린(타임아웃은 R2 S3Client 한정이라 local 무영향). 신규 케이스 불요, 회귀만 확인.
### 5.4 fallback (view)
- E2E 또는 수동: 깨진 이미지 URL → placeholder 대체, 레이아웃 무파손.
### 5.5 실행
- 타깃: `./gradlew test --tests "*R2ObjectStorage*" --tests "*ObjectStorageWiring*"` (+ 신규 타임아웃 테스트 클래스명). 신규 repo 의존 없음 → `@MockSharedRepositories` 갱신 불요 예상.

## 6. 순서 / 검증 게이트
1. backend-implementor: StorageProperties(timeout+cacheControl) → R2StorageConfig(overrideConfiguration) → R2ObjectStorage(cacheControl) → application.yml env → 5.1/5.2/5.3 테스트 → 타깃 그린.
2. reviewer: 타임아웃 부등식·시크릿 위생·예외 변환·과설정 여부, cacheControl 정합.
3. view-implementor: placeholder 자산 + 템플릿 onerror.
4. reviewer(view): onerror 무한루프 방지, `<main>` 무관(인라인 속성), permitAll 경로.
5. 메인: Modulith verify + 풀 `./gradlew test` 그린.
6. (ops, 코드 외) 커스텀 도메인 전환·CDN 퍼지(후속 패스)는 본 plan 비범위 — task에 보존.

## 7. 리뷰 관점
- **타임아웃이 "무한 매달림"을 실제로 끊는가**: 응답지연(b) 테스트가 핵심 — 연결성공+무응답에서 시간 내 실패. apiCallTimeout ≥ 재시도×attempt 부등식 준수.
- **시크릿 위생**: 타임아웃/캐시 프로퍼티 추가가 기존 access/secret 평문 비노출 불변식을 깨지 않음. 로깅 storageKey 한정 유지.
- **과설정 회피**: apiCall* 우선, connection/socket은 중복 시 생략. 신규 의존 없음(테스트도 ServerSocket으로 무의존).
- **포트/도메인 불변**: ObjectStorage 시그니처·ProductImageService 무수정. cacheControl은 R2 impl 한정(local 비대칭은 인지 항목).
- **토글 회귀**: type=local에서 R2 측 변경 무영향(044 배선 테스트 그린).
- **view**: onerror 인라인 속성(스크립트 아님), `onerror=null` 무한루프 차단, placeholder permitAll.

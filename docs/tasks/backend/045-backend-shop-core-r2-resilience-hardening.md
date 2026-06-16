# 045. R2 정적 자산 회복성 강화 (업로드 타임아웃 + 읽기 경로 CDN/fallback)

> 상태: 예정 (Task 044 R2 이관 후속)
> 영역: shop-core (backend / common.storage S3Client + 화면 이미지 렌더링)
> 출처: 사용자 질문 — "CDN 이미지 요청도 SMTP처럼 외부 의존 장애 시 난타/블로킹 케이스가 날 수 있는데 대응은?". 실사 결과 Task 044의 `R2StorageConfig` S3Client에 **타임아웃 미설정**(AWS SDK 기본값, apiCallTimeout 사실상 무한정) 확인.
> 관련: `docs/backlog/backend/011-backend-notification-resilience4j-actuator-metrics-health.md`(회복성/메트릭 선례), notification SMTP CircuitBreaker(외부 의존 보호 패턴 참고).

## 배경 — 두 경로의 위험이 다르다 (실사)
"CDN 이미지"는 성격이 다른 두 경로가 섞여 있고, 대응 수단도 다르다.

| 경로 | 앱이 외부 호출? | 위험 | 적정 대응 |
|---|---|---|---|
| **A. 읽기**: 브라우저 → R2 공개 URL(`pub-*.r2.dev`) | ✗ (브라우저 직결, 앱 미개입) | R2/이미지 장애 시 페이지 깨짐, origin 난타 | CDN 캐싱(커스텀 도메인) + 프론트 fallback + Cache-Control |
| **B. 쓰기**: 앱 → R2 S3 API(`R2ObjectStorage.put/delete`) | ✓ (동기 요청 스레드 블로킹) | R2 지연/장애 시 **요청 스레드 무한 매달림** | **타임아웃(필수)** > 재시도 제한 > 서킷(선택) |

- 경로 B가 notification SMTP와 같은 구조(앱→외부 블로킹). 단 SMTP는 비동기 Kafka(재시도/DLQ)인 반면 B는 **동기 사용자 업로드**라 즉시 에러 반환 + 폭발 반경 제한이 핵심.
- 경로 A는 앱이 루프에 없으므로 서킷 브레이커가 적용될 자리가 아니다 — 캐싱/fallback이 정답.

## 현황 / 갭 (실사 확정)
| 항목 | 상태 | 위치 |
|---|---|---|
| R2 S3Client 타임아웃 | ❌ 미설정 (SDK 기본 — apiCallTimeout 무제한) | `common/storage/R2StorageConfig.java:42-50` |
| SDK 재시도 | ✅ 기본 standard(~3회) 동작 | (SDK 기본) |
| 업로드 실패 보상 | ✅ put→DB, DB 실패 시 delete 보상 | `product/service/ProductImageService.java:101-118` |
| 공개 도메인 | ⚠️ `pub-*.r2.dev` (Cloudflare 프로덕션 비권장 — 캐시 약함·rate limit) | application.yml(prod) / AssetUrlResolver |
| 프론트 이미지 fallback | ❓ 확인 필요 (없으면 404 시 페이지 깨짐/깨진 이미지) | `templates/product/{detail,list}.html` 등 |
| Cache-Control 헤더 | ❌ R2 PutObject에 미지정 | `R2ObjectStorage.put` |

## 범위 (Scope)

### 1. 경로 B — 업로드 타임아웃 (backend, 1순위·필수)
- `R2StorageConfig`의 S3Client에 타임아웃 추가:
  - `ClientOverrideConfiguration`: `apiCallTimeout`(전체, 예 10s), `apiCallAttemptTimeout`(시도당, 예 5s).
  - HTTP 클라이언트(`connectionTimeout`/`socketTimeout`) 명시.
  - 값은 `StorageProperties.R2`에 프로퍼티로 노출(`${SHOP_STORAGE_R2_*_TIMEOUT_MS:...}` 기본값) — 운영 튜닝 가능.
- 타임아웃 초과 시 SDK 예외 → `R2ObjectStorage`에서 `StorageException` 변환(기존 catch 경로 재사용 확인).
- **재시도 제한 검토**: 동기 업로드 경로이므로 과한 재시도 폭주 방지(기본 standard 유지 또는 횟수 하향 결정).

### 2. 경로 B — 서킷 브레이커 (backend, 선택·조건부)
- **기본은 비범위.** 업로드는 저volume 사용자 행동이라 타임아웃으로 폭발 반경이 이미 제한됨.
- R2 장기 장애 + 업로드 동시성이 높아 타임아웃 대기 스레드가 쌓이는 것이 **측정으로 확인될 때만** 도입.
- 도입 시 notification SMTP 패턴 재사용(resilience4j core): R2 인증/권한(403) 등 영구 오류는 record 제외, 일시 장애만 카운트. 동기 경로이므로 OPEN 시 사용자에게 즉시 503/안내.

### 3. 경로 A — 읽기 회복성 (read path)
- **커스텀 도메인 + CDN 캐싱**: `pub-*.r2.dev` → 커스텀 도메인 연결(Cloudflare CDN 자동 캐싱). `asset-base-url`만 교체(코드 무변경 — AssetUrlResolver). origin 난타를 캐시가 흡수.
- **Cache-Control**: `R2ObjectStorage.put`의 PutObjectRequest에 `cacheControl`(예 `public, max-age=31536000, immutable` — UUID 키라 불변) 지정 → CDN/브라우저 적극 캐시.
- **프론트 fallback 이미지**: 이미지 `onerror` → placeholder 대체(현행 템플릿 확인 후 누락 시 추가). 404가 페이지를 깨지 않게. (브라우저는 실패 `<img>`를 무한 재시도하지 않으므로 앱 CB 불필요)

## Non-goals
- 경로 A에 서킷 브레이커/회복성 라이브러리 적용 — 앱이 루프에 없으므로 부적합. 캐싱·fallback이 정답.
- R2 업로드 비동기화(큐잉) — 현 동기 모델 유지. 동시성 문제 측정 전 과설계.
- 기본 서킷 브레이커 도입(2번) — 측정으로 필요 확인 전 비범위.
- presigned URL / 이미지 변환(리사이즈) — 별도 후속.

## 검증
- 타임아웃: R2 엔드포인트를 응답 지연/블랙홀로 모사(예 더미 unroutable endpoint)했을 때 업로드가 설정 시간 내 `StorageException`으로 실패하고 요청 스레드가 무한 매달리지 않음(단위/통합).
- Cache-Control: MinIO 통합 테스트에서 PutObject 후 객체 메타데이터에 cacheControl이 반영됨 확인.
- 빈 토글 불변식 유지: `type=local`(기본)에서 R2/타임아웃 빈 미생성(044 ObjectStorageWiringTest 회귀).
- 읽기 fallback: E2E 또는 수동 — 깨진 이미지 URL이 placeholder로 대체되는지.
- 메인 게이트: Modulith verify + 풀 스위트 그린.

## 참고 (실사)
- S3Client: `shop-core/.../common/storage/R2StorageConfig.java`(타임아웃 추가 지점 42-50), `R2ObjectStorage.java`(put/delete + StorageException 변환), `StorageProperties.java`(R2 중첩 — 타임아웃 프로퍼티 추가 지점).
- 업로드 보상: `product/service/ProductImageService.java`.
- 읽기 합성/렌더: `common/storage/AssetUrlResolver.java`, `templates/product/{detail,list}.html`.
- 회복성 선례(패턴 참고): notification `common/config/ResilienceConfig.java`·`service/ResilientEmailSender.java`, `docs/backlog/backend/011-...`.
- 044 산출물: `docs/tasks/backend/044-backend-shop-core-r2-object-storage.md`, `docs/plans/backend/044-r2-object-storage-plan.md`.

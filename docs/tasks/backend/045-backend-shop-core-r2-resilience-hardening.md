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
  - `ClientOverrideConfiguration`: `apiCallTimeout`(전체), `apiCallAttemptTimeout`(시도당).
  - HTTP 클라이언트(`connectionTimeout`/`socketTimeout`) 명시.
  - 값은 `StorageProperties.R2`에 프로퍼티로 노출(`${SHOP_STORAGE_R2_*_TIMEOUT_MS:...}` 기본값) — 운영 튜닝 가능.
- **타임아웃 값 산정 (축이 서로 다름 — 단일 상수 금지)**:
  - 구체 수치는 **플레이스홀더**이며 측정 후 확정한다(예시값 직접 사용 금지).
  - `connectionTimeout`(연결 수립)은 **짧게**(예 1~2s) — 외부 불통을 빨리 감지.
  - 전송 타임아웃(`socketTimeout`/`apiCallAttemptTimeout`)은 **페이로드 크기에 비례해 넉넉히**: 044가 `readAllBytes()`로 최대 **10MB**(`spring.servlet.multipart.max-file-size`)를 한 번에 PUT하므로, **max-file-size ÷ 보수적 최저 대역폭** 으로 산정해야 정상 대용량 업로드가 헛되이 끊기지 않는다.
  - **관계 불변식**: SDK 재시도가 켜져 있으면 `apiCallTimeout(전체) ≥ 재시도횟수 × apiCallAttemptTimeout(시도당)` 이어야 재시도가 전체 타임아웃에 잘리지 않는다. 두 값을 독립으로 정하지 말고 이 부등식을 만족하도록 함께 정한다.
- 타임아웃 초과 시 SDK 예외 → `R2ObjectStorage`에서 `StorageException` 변환(기존 catch 경로 재사용 확인).
- **재시도 제한 검토**: 동기 업로드 경로이므로 과한 재시도 폭주 방지(기본 standard 유지 또는 횟수 하향 결정). 위 관계 불변식과 일관되게.

### 2. 경로 B — 서킷 브레이커 (backend, 선택·조건부)
- **기본은 비범위.** 업로드는 저volume 사용자 행동이라 타임아웃으로 폭발 반경이 이미 제한됨.
- R2 장기 장애 + 업로드 동시성이 높아 타임아웃 대기 스레드가 쌓이는 것이 **측정으로 확인될 때만** 도입.
- 도입 시 notification SMTP에서 **CircuitBreaker 설정·예외 분류 규칙만 차용**(resilience4j core): R2 인증/권한(403) 등 영구 오류는 record 제외, 일시 장애만 카운트.
  - **단, 예외 처리 흐름은 SMTP와 정반대다**: SMTP는 `CallNotPermittedException`→retryable 변환→Kafka 재시도/DLQ 합류 구조지만, 업로드는 **동기 경로라 DLQ가 없다.** OPEN 시 재시도용 예외로 둔갑시키지 말고 **사용자에게 즉시 503/안내로 반환**한다. 즉 CB config는 재사용하되 데코레이터의 예외 변환은 동기 경로 전용으로 새로 작성.

### 3. 경로 A — 읽기 회복성 (read path)
- **커스텀 도메인 + CDN 캐싱**: `pub-*.r2.dev` → 커스텀 도메인 연결(Cloudflare CDN 자동 캐싱). `asset-base-url`만 교체(코드 무변경 — AssetUrlResolver). origin 난타를 캐시가 흡수.
- **Cache-Control** (※ 실제로는 **쓰기 경로 코드 변경** — `R2ObjectStorage.put`의 PutObjectRequest에 `cacheControl` 지정. 효과만 읽기 캐싱이라 본 절에 배치): 예 `public, max-age=31536000, immutable`(UUID 키라 키 단위 불변).
  - **삭제 반영 지연 caveat + 대응(택: CDN 퍼지)**: 키는 불변이라 *내용 불일치(stale content)* 는 없으나, `ProductImageService.delete`로 R2 객체를 지워도 **CDN/브라우저 캐시가 max-age 동안 삭제본을 계속 서빙**한다("삭제 즉시 비공개" 미보장). → **민감/규정 삭제 시 CDN 캐시 퍼지(invalidate) 절차를 둔다**(Cloudflare 캐시 무효화 API로 해당 키 URL 퍼지). 일반 삭제는 미참조 URL이라 수용, 민감 삭제 경로만 퍼지 호출을 연계.
  - **local↔r2 캐시 비대칭 인지**: `StaticResourceConfig`(local 서빙)는 캐시 헤더를 명시 설정하지 않음(확인됨) → r2만 immutable 1년이면 두 백엔드 캐시 동작이 다르다. 필요 시 `StaticResourceConfig.setCachePeriod`로 정렬(또는 비대칭을 의도로 문서화).
- **프론트 fallback 이미지**: 이미지 `onerror` → placeholder 대체(현행 템플릿 확인 후 누락 시 추가). 404가 페이지를 깨지 않게. (브라우저는 실패 `<img>`를 무한 재시도하지 않으므로 앱 CB 불필요)

## Non-goals
- 경로 A에 서킷 브레이커/회복성 라이브러리 적용 — 앱이 루프에 없으므로 부적합. 캐싱·fallback이 정답.
- R2 업로드 비동기화(큐잉) — 현 동기 모델 유지. 동시성 문제 측정 전 과설계.
- 기본 서킷 브레이커 도입(2번) — 측정으로 필요 확인 전 비범위.
- presigned URL / 이미지 변환(리사이즈) — 별도 후속.

## 검증
- 타임아웃 — **두 축을 분리 검증**(unroutable 하나로 갈음 금지):
  - (a) **연결 타임아웃**: refused/unroutable 주소(예 라우팅 불가 IP)로 연결 자체가 안 될 때 `connectionTimeout` 내 `StorageException` 실패.
  - (b) **응답 지연 타임아웃(핵심)**: 연결은 되지만 응답이 느린 서버(예 지연 응답 MockWebServer, 또는 MinIO + toxiproxy 지연 주입)로 `apiCallTimeout`/`socketTimeout` 내 실패 → **요청 스레드가 무한 매달리지 않음**을 단언. (a)는 (b)를 대체하지 못함을 명시.
- Cache-Control: MinIO 통합 테스트에서 PutObject 후 객체 메타데이터에 cacheControl이 반영됨 확인.
- CDN 퍼지(민감 삭제 경로 한정): 퍼지 호출이 삭제 경로에서 트리거되는지 단위 검증(외부 Cloudflare API는 mock). 실제 무효화 반영은 운영 수동 확인(코드 게이트 외).
- 빈 토글 불변식 유지: `type=local`(기본)에서 R2/타임아웃 빈 미생성(044 ObjectStorageWiringTest 회귀).
- 읽기 fallback: E2E 또는 수동 — 깨진 이미지 URL이 placeholder로 대체되는지.
- 메인 게이트: Modulith verify + 풀 스위트 그린.

## 참고 (실사)
- S3Client: `shop-core/.../common/storage/R2StorageConfig.java`(타임아웃 추가 지점 42-50), `R2ObjectStorage.java`(put/delete + StorageException 변환), `StorageProperties.java`(R2 중첩 — 타임아웃 프로퍼티 추가 지점).
- 업로드 보상: `product/service/ProductImageService.java`.
- 읽기 합성/렌더: `common/storage/AssetUrlResolver.java`, `templates/product/{detail,list}.html`.
- 회복성 선례(패턴 참고): notification `common/config/ResilienceConfig.java`·`service/ResilientEmailSender.java`, `docs/backlog/backend/011-...`.
- 044 산출물: `docs/tasks/backend/044-backend-shop-core-r2-object-storage.md`, `docs/plans/backend/044-r2-object-storage-plan.md`.

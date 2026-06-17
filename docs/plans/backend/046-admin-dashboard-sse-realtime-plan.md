# Plan 046. 관리자 통계 대시보드 실시간 표출 (SSE 푸시)

> 대상 Task: `docs/tasks/backend/046-backend-shop-core-admin-dashboard-sse-realtime.md`
> 범위: View 체인 SSE 엔드포인트(SseEmitter) + emitter 레지스트리 + 스케줄 broadcaster(backend) + 대시보드 템플릿 EventSource JS(view). 기존 SSR 1회 바인딩은 초기값으로 유지(점진 향상). 신규 repo 의존 없음.
> 순서: backend-implementor(SSE 엔드포인트+레지스트리+스케줄 broadcaster) → reviewer → view-implementor(span id + EventSource JS) → reviewer → Modulith verify+풀 게이트 → e2e-runner.

## 0. 확정 사실 (코드 검증됨)
- `/admin/dashboard`: `AdminDashboardViewController`(web/admin) → `AdminDashboardAssembler.build()` → 모델 `dashboard`(`AdminDashboardView`) 1회 SSR. 뷰 `admin/dashboard`.
- `AdminDashboardView`(record): `memberActivity`·`productSales`·`refundRate`(각 `Metric{ratioPercent:BigDecimal, numerator:long, denominator:long}`) + `periodLabel`.
- **인증**: View 체인(@Order2) formLogin+**세션 쿠키**, `/admin/**` hasRole(ADMIN). → `/admin/...` SSE 엔드포인트는 **EventSource가 세션 쿠키로 인증**(Bearer 헤더 불요). REST 체인(`/api/v1/**` Bearer)엔 두지 않는다.
- **Spring MVC(서블릿)** → `SseEmitter`(WebFlux 아님).
- **`@EnableScheduling`은 무조건 활성이 아니다(정정)**: 코드베이스 유일한 `@EnableScheduling`은 `payment/service/OrderExpirySchedulingConfig`인데 **`@ConditionalOnProperty(shop.order.pending-expiry.enabled=true)`로 가드**된다(application.yml 기본 true, `SHOP_ORDER_EXPIRY_ENABLED`). → 운영자가 주문 만료를 끄면 스케줄링 자체가 죽어 **SSE 푸시도 무음으로 죽는 비자명한 결합**. 본 plan은 이에 **의존하지 않고 전용 `@EnableScheduling`을 신설**한다(§2.3 결정).
- **test 스케줄 미발화의 실제 기전**: test에선 `test/resources/application.yml`의 `shop.order.pending-expiry.enabled=false`로 위 config가 로드 안 돼 스케줄링이 꺼진다(verification-gate §4와 무관 — 이전 인용 오류 정정). 본 plan은 SSE 스케줄도 **자체 프로퍼티 가드 + test 비활성**으로 동일하게 test 비발화를 보장한다(§2.3).
- 멀티노드 가드 `SchedulerLeaderGuard` 존재 — **단, 본 push는 노드별 자기 emitter(노드 로컬 상태)에 보내야 하므로 리더 게이트 미적용**(리더만 push하면 비리더 노드 admin은 갱신 못 받음). 트레이드오프: 멀티노드 시 노드마다 독립 `assembler.build()` → **집계 쿼리 노드 수배**. admin 동시접속 극소수 + interval 제한 + 활성0 skip으로 수용 가능.
- 템플릿: 통계 값은 `th:text="${dashboard.memberActivity.ratioPercent}+'%'"` 등 — **현재 span에 id 없음** → JS 갱신 위해 id/data 속성 추가 필요(view).

## 1. 트리거 결정 — 스케줄 푸시 (확정)
- **`@Scheduled(fixedDelayString="${shop.admin.dashboard.sse.interval:PT10S}")` 스케줄 푸시 채택.** 이유: 통계는 DB 집계라 이벤트마다 재집계는 비싸다(주문 폭주 시 폭주). 스케줄은 **부하 예측가능·구현 단순·디바운스 불요**. near-real-time(기본 10s)로 대시보드 충분.
- 이벤트 드리븐(Modulith 리스너)은 **비채택**(task Non-goal 정합) — 즉시성 요구가 명확해지면 후속.
- **빈 연결 최적화**: 활성 emitter가 0이면 `assembler.build()` 재집계를 **건너뛴다**(아무도 안 볼 때 무의미한 집계 쿼리 방지).

## 2. 백엔드 (backend-implementor) — web/admin
### 2.1 SSE 엔드포인트
- `@GetMapping(value="/admin/dashboard/stream", produces=MediaType.TEXT_EVENT_STREAM_VALUE)` → `SseEmitter` 반환.
  - **★ `@ResponseBody` 필수**: `AdminDashboardViewController`는 순수 `@Controller`라 핸들러 반환을 view name(String)으로 해석한다. `SseEmitter`를 본문으로 흘리려면 **stream 핸들러에 `@ResponseBody`를 붙이거나, `AdminDashboardSseController`를 `@RestController`로 분리**한다(권장: 별도 `@RestController` 분리 — view name 핸들러와 혼선 제거). 경로가 `/admin/**`(view 체인·세션 쿠키)이라 `@ResponseBody`여도 REST 체인 아님(architecture-rule §View 위반 아님, ServiceResponse 미사용).
  - emitter 생성(타임아웃 설정, 예 `${...sse.timeout:PT30M}`) → **레지스트리 등록** → **연결 직후 현재 스냅샷 1건 전송**(초기 동기화, `event=stats data=JSON`).
  - `onCompletion`/`onTimeout`/`onError` 콜백에서 **레지스트리 제거**(누수 방지). 컨트롤러는 view 계층(REST ServiceResponse 아님 — architecture-rule).
  - GET이라 CSRF 무관. 인가는 `/admin/**` ADMIN 규칙에 위임(컨트롤러 문자열 권한 검사 금지).
### 2.2 emitter 레지스트리 (web/admin 컴포넌트)
- 스레드 안전 보관(`CopyOnWriteArrayList<SseEmitter>` 또는 `Set`). add/remove/`broadcast(AdminDashboardView)`. **`ThreadLocal` 직접 사용 금지**(가상스레드 대비 — CLAUDE.md).
- **노드 로컬 인메모리**(Redis 등 공유 금지) — emitter는 그 노드에 연결된 admin만 보유. 멀티노드 push가 노드별 독립인 이유(§0).
- `broadcast`: 각 emitter에 `event("stats").data(view, APPLICATION_JSON)` 전송, 실패(IOException)한 emitter는 completeWithError+레지스트리 제거(죽은 연결 정리).
### 2.3 스케줄 broadcaster + 전용 @EnableScheduling (결정)
- **전용 `@EnableScheduling` 신설**(order-expiry 결합 제거): web/admin(또는 common)에 `AdminDashboardSseSchedulingConfig`(@Configuration + `@EnableScheduling`)를 두되, **`@ConditionalOnProperty(prefix="shop.admin.dashboard.sse", name="enabled", havingValue="true", matchIfMissing=true)`**로 가드(기본 on, env로 off 가능 — order-expiry 패턴 미러).
  - `@EnableScheduling`은 컨테이너에 복수여도 무해하나, 본 기능 소유의 활성 지점을 둬 **order-expiry on/off와 독립**시킨다.
- **test 비발화 보장**: `test/resources/application.yml`에 `shop.admin.dashboard.sse.enabled=false` 추가 → 위 config 미로드 → 스케줄 미발화. **broadcast 메서드는 직접 호출로 검증**(스케줄 발화 의존 안 함).
- `@Scheduled(fixedDelayString="${shop.admin.dashboard.sse.interval:PT10S}")` 메서드: 활성 emitter 있으면 `assembler.build()` → `registry.broadcast(view)`. 없으면 skip.
- 하트비트: broadcast 자체가 주기 신호 역할(별도 comment 핑은 선택). 프록시 타임아웃 < interval 이면 comment 핑 추가 검토.

## 3. 화면 (view-implementor) — templates/admin/dashboard.html
- 통계 값 span에 **식별자 부여**: `id`(예 `member-activity-ratio`, `member-activity-num`, `member-activity-den`, productSales·refundRate 동일) 또는 `data-metric` 속성. 기존 `th:text`(SSR 초기값) **유지**(SSE 미연결 시 그대로 보임).
- **EventSource JS**(반드시 `<main>` 내부 — 레이아웃 `content=~{::main}`로 main만 렌더, 밖이면 드롭 [[inline-script-must-be-inside-main-layout-fragment]]):
  - `const es = new EventSource('/admin/dashboard/stream');`
  - `es.addEventListener('stats', e => { const d=JSON.parse(e.data); /* span 갱신: ratioPercent+'%', numerator, denominator, NA 처리(ratioPercent null이면 'N/A') */ });`
  - `es.onerror` graceful(EventSource 기본 자동 재연결 — 로깅만, 무한 alert 금지).
- ratioPercent가 null(분모 0)인 NA 케이스 표시 로직을 SSR(th:if)과 동일하게 JS에도 반영(일관).
- **포맷 일치**: `ratioPercent`는 `BigDecimal`(scale 1, 예 `50.0`)이라 SSR은 `"50.0%"`로 표시된다. JSON으로는 number(`50.0`)로 와도 JS가 같은 표기(소수 1자리 + `%`)가 되도록 포맷 통일(SSR↔SSE 표시 깜빡임 방지). numerator/denominator는 long.

## 4. 순서 / 게이트
1. backend-implementor: SSE 엔드포인트 + 레지스트리 + 스케줄 broadcaster + 백엔드 테스트(타깃) → reviewer.
2. view-implementor: span id + EventSource JS → reviewer.
3. 메인: Modulith verify(web/admin 내부 신규 빈, 모듈 경계 영향 없음) + 풀 `./gradlew test` 그린.
4. e2e-runner: ADMIN 로그인 → /admin/dashboard → SSE 연결(text/event-stream) → 데이터 변화가 새로고침 없이 DOM 반영(스케줄 push). `<main>` 밖 스크립트 드롭 함정 회피 확인.

## 5. 테스트
- **권한/엔드포인트**: `/admin/dashboard/stream` — ADMIN GET 시 200 + `text/event-stream`(MockMvc async 또는 통합), 비ADMIN 403/redirect, 비인증 redirect.
- **레지스트리/broadcast**: add 후 broadcast가 emitter에 데이터 전송, onCompletion/onTimeout 시 제거(단위). 죽은 emitter IOException → 제거.
- **broadcaster**: 활성 emitter 0이면 assembler.build() 미호출(skip), 있으면 호출+broadcast(단위 — assembler mock).
- **스케줄 비발화(test)**: `test/resources/application.yml`의 `shop.admin.dashboard.sse.enabled=false`로 `AdminDashboardSseSchedulingConfig`(전용 @EnableScheduling) 미로드 → 스케줄 미발화 확인(order-expiry의 `pending-expiry.enabled=false` 기전과 동일 — verification-gate §4 무관). 로직은 broadcast 메서드 직접 호출로 검증.
- **E2E**(필수, SSE는 브라우저로만): 위 게이트 4.
- 신규 repo 의존 없음(assembler 재사용) → `@MockSharedRepositories` 영향 없음 예상([[full-context-test-repo-mock-shared-annotation]]).

## 6. 리뷰 관점
- **인증 경로**: SSE가 `/admin/**`(세션 쿠키) 아래라 EventSource 인증됨. `/api/v1`에 두지 않음. ADMIN 인가 위임(컨트롤러 권한검사 금지).
- **emitter 누수**: onCompletion/onTimeout/onError 전부 레지스트리 제거. 타임아웃 설정. broadcast 실패 emitter 정리.
- **집계 비용**: 활성 0이면 skip, interval로 제한. assembler 재사용(신규 집계 금지).
- **스레드/가상스레드**: ThreadLocal 미사용, 스케줄 스레드에서 집계+push(블로킹 경계). 멀티노드는 노드별 자기 emitter push(리더 게이트 불요 — 잘못 적용하면 일부 노드 admin이 갱신 못 받음).
- **점진 향상**: SSR 초기값 유지, SSE 실패해도 화면 정상. JS는 `<main>` 내부.
- **레이어**: SSE 컨트롤러=View 계층, ServiceResponse 미사용.

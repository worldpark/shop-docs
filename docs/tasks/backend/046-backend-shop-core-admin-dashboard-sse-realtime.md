# 046. 관리자 통계 대시보드 실시간 표출 (SSE 푸시)

> 출처: 사용자 요청 — "admin 대시보드 데이터를 SSE로 보내 표출". Task 043(관리자 통계 대시보드, 서버사이드 렌더 1회) 후속으로 **실시간 갱신** 추가.
> 관련: `docs/architecture.md`(View 진입점), `docs/rules/api-authorization-rule.md`(ADMIN 최소권한), [[inline-script-must-be-inside-main-layout-fragment]].

## 배경 (코드 확인)
- 현재 `/admin/dashboard`는 `AdminDashboardViewController`가 `AdminDashboardAssembler.build()`로 **유저 이용률·상품 판매율·환불율**을 조합해 모델 `dashboard`(`AdminDashboardView`)에 바인딩 후 **1회 SSR**. 갱신하려면 새로고침 필요.
- **인증 구조(SSE 가능성의 핵심)**: SecurityConfig는 두 체인 — REST(`/api/v1/**`, @Order1)는 STATELESS+**JWT Bearer 헤더**, View(나머지·`/admin/**`, @Order2)는 **formLogin+세션 쿠키**. 브라우저 `EventSource`는 커스텀 헤더를 못 보내지만 **쿠키는 자동 전송** → **SSE 엔드포인트를 `/api/v1`이 아닌 `/admin/...`(View 체인)에 두면 기존 세션 쿠키로 인증 + `/admin/** hasRole(ADMIN)`로 보호**가 그대로 적용된다.
- 이 앱은 **Spring MVC(서블릿)** — WebFlux 아님 → SSE는 `SseEmitter`로 구현.

## Target / Goal
관리자가 `/admin/dashboard` 화면을 열어둔 채 **새로고침 없이 통계가 실시간(또는 near-real-time)으로 갱신**되게 한다. 기존 SSR 1회 바인딩은 **초기 표시로 유지**(SSE 미연결/실패 시에도 화면은 정상), 그 위에 SSE로 갱신을 얹는다(점진적 향상 — progressive enhancement).

## 범위 (Scope)
### 백엔드 (backend-implementor)
- **SSE 스트리밍 엔드포인트**: View 컨트롤러(web/admin)에 `@GetMapping(value="/admin/dashboard/stream", produces=MediaType.TEXT_EVENT_STREAM_VALUE)` → `SseEmitter` 반환. **`/api/v1` 아님**(세션 쿠키 인증·`/admin/**` ADMIN 규칙 유지). GET이라 CSRF 무관.
  - 연결 직후 현재 스냅샷 1건 전송(초기 동기화), 이후 갱신 push.
  - emitter 타임아웃 설정 + 하트비트(주석 이벤트)로 프록시 idle 끊김 방지.
- **emitter 레지스트리**(스레드 안전, 예 `CopyOnWriteArrayList<SseEmitter>` 또는 Map): 활성 연결 보관, `onCompletion`/`onTimeout`/`onError`에서 제거(누수 방지). 직접 `ThreadLocal` 사용 금지(가상스레드 대비 — CLAUDE.md).
- **푸시 트리거** — plan에서 택1 확정:
  - **(a) 스케줄 푸시(기본 권장)**: `@Scheduled(fixedDelay=N초)`로 `assembler.build()` 재집계 → 활성 emitter에 broadcast. 부하 예측가능·구현 단순. N은 설정값.
  - **(b) 이벤트 드리븐**: Modulith 내부 이벤트(주문 완료/취소·환불 등 `@ApplicationModuleListener`) 수신 시 재집계 push. 즉시성↑이나 **집계 쿼리가 비싸므로 스로틀/디바운스 필수**(이벤트 폭주 시 재집계 폭주 방지). 단독 모듈 경계 준수(다른 모듈 비공개 참조 금지 — published 이벤트만 구독).
- **재집계 비용 가드**: 통계는 DB 집계 쿼리 → 푸시 주기/스로틀로 부하 제한. `AdminDashboardAssembler` 재사용(신규 집계 로직 신설 금지).

### 화면 (view-implementor)
- `templates/admin/dashboard.html`에 **클라이언트 EventSource JS** 추가: `new EventSource('/admin/dashboard/stream')` + `onmessage`로 수신 JSON을 DOM(통계 영역)에 반영. `onerror`로 graceful(자동 재연결은 EventSource 기본).
  - ⚠️ **이 `<script>`는 반드시 `<main>` 내부**에 둘 것 — 레이아웃이 `content=~{::main}`로 main만 렌더해 main 밖 스크립트는 드롭됨([[inline-script-must-be-inside-main-layout-fragment]]). E2E로 실제 동작 검증.
- SSE 미지원/실패 시 기존 SSR 초기값이 그대로 보이게(점진 향상). 표시 영역 식별자(id) 정리.

## Non-goals
- **폴링 방식**(JS setInterval / htmx) — 사용자가 SSE 선택. 단 plan에서 "정말 SSE가 필요한 실시간성인가"를 1줄 확인(30초 지연 허용이면 폴링이 더 단순하다는 트레이드오프 기록만, 구현은 SSE).
- **WebSocket** — 양방향 불필요, 과설계.
- 서브초(sub-second) 실시간·대규모 동시 admin — admin 동시접속 극소수 전제(emitter thread-per-connection 비용 무시 가능). 대규모 팬아웃·메시지 브로커 경유 푸시 비범위.
- 신규 통계 지표 추가 — 기존 `AdminDashboardView` 3지표 그대로 실시간화만.
- REST(`/api/v1`)로 SSE 노출 — Bearer 헤더 인증이라 EventSource 부적합, 안 함.

## 검증
- **백엔드**: `/admin/dashboard/stream` 권한(ADMIN 200·text/event-stream / 비ADMIN 403 또는 /login redirect / 비인증 redirect). emitter 등록·해제(완료/타임아웃 시 레지스트리에서 제거)·푸시 broadcast 단위/통합 테스트. 스케줄(또는 이벤트) 트리거가 재집계+push 호출하는지.
- **브라우저 E2E 필수**(SSE는 실제 브라우저로만 검증): ADMIN 로그인 → /admin/dashboard → SSE 연결 수립 → (스케줄/이벤트로) 통계 갱신이 새로고침 없이 DOM 반영. `<main>` 밖 스크립트 드롭 함정 회피 확인([[verify-admin-list-page-features-with-e2e]]).
- 메인 최종: Modulith verify(이벤트 드리븐 선택 시 모듈 경계·사이클 없음) + 풀 스위트 그린. 신규 repo 의존 없으면 `@MockSharedRepositories` 영향 없음 예상([[full-context-test-repo-mock-shared-annotation]]).

## 참고 (실사)
- 현 대시보드: `web/admin/AdminDashboardViewController.java`(`/admin/dashboard`), `web/admin/AdminDashboardAssembler.java`(`build()`), `web/admin/dto/AdminDashboardView.java`, `templates/admin/dashboard.html`.
- 인증: `security/SecurityConfig.java`(View 체인 @Order2 formLogin+세션, `/admin/**` hasRole(ADMIN); REST @Order1 STATELESS+Bearer), `JwtAuthenticationFilter`(Bearer 헤더 — REST 전용).
- 이벤트 드리븐(선택) 후보: `order/event/{OrderCompletedEvent,OrderCancelledEvent}.java` 등 published 이벤트(`@ApplicationModuleListener`).
- 레이어 규칙: View 진입점 `ViewController → Service/Assembler`, ServiceResponse는 REST 전용(architecture-rule). SSE 컨트롤러는 View 계층.

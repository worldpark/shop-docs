# 051. 판매자 판매 현황 실시간(SSE) 푸시 — per-seller 스코프

> 출처: 사용자 요청 — admin 대시보드 SSE(Task 046)처럼 판매자 판매 현황도 SSE로 실시간 데이터 수신.
> 선행: Task 046(admin 대시보드 SSE 패턴), 판매자 상품 현황 화면(`SellerProductStatsViewController` @ `/seller/products/stats`, `seller/product-stats.html`, `SellerSalesStatsPort`).
> 성격: 046 SSE 패턴 재사용 확장. **결정적 차이는 per-seller 데이터 스코핑**.

## 배경
- 현재 판매 현황(`/seller/products/stats`)은 **페이지 진입 시 1회 집계**만 한다. 주문이 유입돼도 새로고침 전까지 수치가 갱신되지 않는다.
- Task 046은 admin 대시보드를 SSE로 실시간화했다: `AdminDashboardSseController`(@RestController, `GET /admin/dashboard/stream`, text/event-stream) + `AdminDashboardSseRegistry`(노드 로컬 인메모리) + `AdminDashboardSseBroadcaster`(@Scheduled, 연결 0이면 skip) + `AdminDashboardSseSchedulingConfig`(전용 @EnableScheduling, config flag) + assembler.
- **그러나 admin SSE는 전 연결에 "동일한 전역 payload"를 브로드캐스트**한다. 판매 현황은 **판매자마다 자기 owner_id 데이터만** 받아야 하므로 registry·broadcaster 설계가 다르다.

## Target / Goal
판매자가 판매 현황 화면을 열어두면, 자기 소유 상품의 판매 수량·매출이 주문 유입에 따라 실시간으로 갱신된다. 데이터는 **요청 판매자 본인 것만** 스트리밍되며 타 판매자 데이터는 절대 누출되지 않는다.

## 범위 (Scope)
### 1. SSE 엔드포인트 (web/product 또는 web/seller)
- `@RestController`, `GET /seller/products/stats/stream`, `produces=text/event-stream`. 046 `AdminDashboardSseController` 패턴 복제(별도 @RestController로 @Controller view 해석과 분리).
- **principal → sellerId 도출**: `CurrentActorResolver.resolve(auth).email()` → email로 스코프(기존 화면과 동일 방식). **경로/쿼리로 sellerId·productId를 외부 입력받지 않는다(IDOR 방지)**.
- 연결 시 **그 판매자의 소유 variantId 세트를 1회 해석**(소유 검증 포함)해 registry에 함께 보관(③-a, 아래 §2). 그 세트로 초기 스냅샷(productId 맵, §4) 1건 전송 → `registry.add(email, emitter, mapping)`(키=email, §2). onCompletion/onTimeout/onError에서 `registry.remove(email, emitter)`(누수 방지, 마지막 emitter 제거 시 매핑도 정리). build 실패는 add 이전 전파(dead emitter 차단 — 046 선례).
- **staleness(③-a 결정)**: variantId 세트는 연결 시점 스냅샷이다. 연결 유지 중 **신규 등록 상품은 reconnect(새로고침) 전까지 스트림에 안 나타난다** — 판매 현황은 기존 상품 수치 추적이 주목적이므로 허용. task·코드 주석에 명시.

### 2. per-seller registry (노드 로컬) — 키 = principal email
> ★ 키는 **`String email`**(plan-review 확정): `CurrentActor`는 email·admin만 노출(sellerId 없음)하고, broadcaster(@Scheduled)는 인증 컨텍스트가 없어 email→sellerId 재해석 불가 → 연결 시 컨트롤러가 쥔 email을 키로 쓴다. email은 판매자별 유일이라 격리 키로 충분.
- 두 가지를 email로 키잉해 보관:
  - `Map<String email, List<SseEmitter>>`(email별 CopyOnWriteArrayList) — 연결.
  - `Map<String email, Map<Long,Long> variantToProduct>` — 그 판매자 소유 variant→product 매핑(②의 tick당 1 배치 쿼리·payload 조립에 필요, ③-a 연결 시점 캐시).
- API: `add(email, emitter, mapping)`(원자적) / `remove(email, emitter)`(마지막 emitter 제거 시 매핑도 제거) / `sendTo(email, payload)` / `connectedEmails()` / `variantToProductOf(email)` 또는 전 연결 variantId 합집합 제공.
- 노드 로컬 보관(Redis 미사용) — SSE emitter는 그 노드에 연결된 브라우저와 1:1(046 근거 동일).

### 3. scoped broadcaster (@Scheduled) — tick당 1 배치 쿼리 (②)
- 연결 0이면 skip. 아니면:
  1. 연결된 전 판매자의 캐시 variantId 세트를 **합집합**으로 모아 `SellerSalesStatsPort.aggregateByVariantIds(union)`를 **tick당 1회** 호출(포트가 `Collection` 입력 지원 — `SellerSalesStatsService:44`). 판매자 수에 비례한 N 쿼리 금지.
  2. 결과(variant별 집계)를 **variantId→sellerId 역맵**으로 판매자별 분배 → 각 판매자의 `productId → {판매수량, 매출}` 맵(§4) 조립.
  3. `registry.sendTo(sellerId, 그 맵)`로 본인 emitter에만 전송.
- 전용 @EnableScheduling(`SellerSalesStatsSseSchedulingConfig`), config flag `shop.seller.sales.sse.{enabled,interval,timeout}`(enabled matchIfMissing=true, test=false — 046 동일). interval 기본 PT10S.

### 4. payload 형태 + assembler 공통 집계 추출 (①④)
- **SSE payload = `productId → {판매수량, 매출}` 맵**(페이지 무관). 페이지네이션과 디커플 — 클라이언트가 현재 렌더된 행만 productId로 매칭해 패치(§5).
- `SellerProductStatsAssembler`에 **스코프 집계를 productId 맵으로 반환하는 공통 메서드를 추출**한다(예: `aggregateSalesByProduct(ownedVariantIds) → Map<Long productId, SalesCell>`). 기존 페이지 행 조립(`Page<SellerProductStatsRow>`)과 SSE 맵이 **이 공통 집계를 공유**해 화면·SSE 수치 발산을 방지.
- 초기 스냅샷·broadcast payload는 동일 **수치**(productId 행 매칭) — "동일 형태" 요구 아님(페이지 vs 맵).

### 5. 뷰 (seller/product-stats.html)
- `EventSource('/seller/products/stats/stream')` 구독 → 수신 payload(productId 맵)의 **productId로 현재 렌더된 표 행을 매칭**해 수치(판매수량·매출)만 갱신(페이지 무관, 맵에 없는 행은 불변). 인라인 `<script>`는 레이아웃 `<main>` 프래그먼트 안에 배치([[inline-script-must-be-inside-main-layout-fragment]] — 밖이면 드롭).
- SSE 미지원/비활성 시에도 기존 서버 렌더 수치가 그대로 보이도록(점진적 향상).

### 6. 인증 / 스코핑
- `/seller/**` → `hasRole("SELLER")`(SecurityConfig View 체인). GET이라 CSRF 무관, 세션 쿠키 인증(046 동일). 데이터 스코프는 오직 principal의 sellerId.

## Non-goals
- 구매자/admin용 추가 SSE, 판매자 대상 신규 "알림"(주문 들어옴 등 — 별개), WebSocket 전환.
- **Redis 공유 registry**(노드 로컬 유지 — 멀티 인스턴스에서도 노드별 독립이 올바름).
- 판매 현황 페이지네이션/집계 모델 재설계(기존 재사용).

## 멀티 인스턴스 정합
- registry는 노드 로컬. 판매자가 한 노드에 핀되면 그 노드 broadcaster가 자기 연결 판매자에게 DB 조회 결과를 push → 멀티 인스턴스에서도 정합(046 근거 동일, 무상태 앱 원칙).

## 검증
- **per-seller 격리(최우선)**: 판매자 A 스트림에 B 데이터가 절대 안 섞임 — 통합(registry.sendTo 스코프) + **브라우저 E2E**(A·B 동시 접속, A 상품 주문 시 A 스트림만 갱신·B 불변). [[verify-admin-list-page-features-with-e2e]] — 실시간 표기는 E2E 필수.
- **종단**: 주문 생성/결제 → 다음 tick에 해당 판매자 스트림 수치 갱신.
- **빈 연결 최적화**: 연결 0이면 집계 쿼리 skip.
- **권한**: 비SELLER가 `/stream` 접근 → 403, 비인증 → 로그인 redirect.
- **초기 스냅샷 = 화면 수치 일치**: 연결 직후 payload(productId 맵)의 각 productId 수치가 서버 렌더 행 수치와 동일(형태가 아닌 productId 매칭 수치 기준).
- **배치 쿼리 1회**: 판매자 N명 동시 연결 시 tick당 집계 쿼리가 N회가 아니라 **1회**(합집합)임을 확인(②).
- **스케줄 비발화(test)**: `shop.seller.sales.sse.enabled=false`면 @Scheduled 미발화(046 선례).
- 메인: Modulith verify + 풀 스위트 그린.

## 참고
- 046 컴포넌트: `web/admin/AdminDashboardSse{Controller,Registry,Broadcaster,SchedulingConfig}.java`, `AdminDashboardAssembler`.
- 기존 화면: `web/product/SellerProductStatsViewController.java`(@ `/seller/products/stats`, model key `statsPage`), `SellerProductStatsAssembler`, `web/product/dto/SellerProductStatsRow.java`.
- 집계 포트: `order/spi/SellerSalesStatsPort`(aggregateByVariantIds — 소유권 무관, 호출자 스코핑), `order/service/SellerSalesStatsService`(판매 인정 상태 paid/preparing/shipping/delivered).
- 규칙: api-authorization-rule(소유권·IDOR), architecture-rule(SSE는 View 계층), `CurrentActorResolver`, 가상스레드 대비 ThreadLocal 금지(CLAUDE.md).

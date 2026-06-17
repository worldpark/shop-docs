# 051 Plan — 판매자 판매 현황 실시간(SSE) 푸시, per-seller 스코프

> Task: `docs/tasks/backend/051-backend-shop-core-seller-sales-stats-sse.md`
> 선행 패턴: Task 046 admin 대시보드 SSE(`web/admin/AdminDashboardSse{Controller,Registry,Broadcaster,SchedulingConfig}`).
> 핵심 차이: admin은 전 연결에 동일 payload 브로드캐스트. 본 Task는 **판매자별 자기 데이터만**(owner 스코프) 푸시.

## 0. 코드 대조 (현재 상태)
- 판매 현황 화면: `web/product/SellerProductStatsViewController` @ `GET /seller/products/stats`(@Controller, view `seller/product-stats`, model key `statsPage`), `CurrentActorResolver.resolve(auth).email()` 스코프.
- 조합: `SellerProductStatsAssembler.assemble(email, pageable)` — `SellerProductFacade.getMyProductStatsData(email, pageable)`(소유 검증·**페이지 스코프** products+variantMappings+stock+totalElements) → `SellerSalesStatsPort.aggregateByVariantIds(variantIds)`(소유 무관 집계, 호출자 스코핑) → variant→product 병합 → `Page<SellerProductStatsRow>`(productId,name,status,totalStock,salesQty,revenue).
- 집계 포트 `SellerSalesStatsPort.aggregateByVariantIds(Collection)` 는 이미 `Collection` 입력 → **배치 1회 호출 가능(②)**. 신규 SPI 메서드 불요.
- 권한: `/seller/**` → `hasRole("SELLER")`(SecurityConfig View 체인). `/seller/products/stats/stream`(GET)도 이 매칭에 포함 — 신규 권한 설정 불요.
- 046 config 가드 패턴: `@ConditionalOnProperty(prefix, name=enabled, havingValue=true, matchIfMissing=true)` + 전용 `@EnableScheduling`, test resources에서 `enabled:false`.

## 1. payload 형태 + 공통 집계 추출 (결정 ①④)
- **payload = `Map<Long productId, SalesCell>`**(`SalesCell(long salesQty, BigDecimal revenue)`), 페이지 무관. SSE DTO `SellerSalesSnapshot`(record, 직렬화 가능)로 감싸 전송(046처럼 JSON).
- `SellerProductStatsAssembler`에서 **순수 병합 메서드 추출**: `mergeSalesByProduct(Map<Long,Long> productIdByVariantId, List<VariantSalesAggregate> aggregates) → Map<Long, SalesCell>`(현 `assemble` 73-83행 로직). 페이지 `assemble()`과 SSE가 **이 메서드를 공유** → 수치 발산 방지(④).
- 클라이언트는 이 맵의 productId로 **현재 렌더된 행만 매칭 패치**(페이지네이션 디커플 ①).

## 2. 전체 소유 variant 매핑 확보 (결정 ③-a — 비페이지·연결시 캐시)
- SSE는 페이지가 아니라 **판매자 전체 소유 상품**을 스코프로 한다(연결 중 페이지 이동에 reconnect 불요, 클라가 보이는 행만 패치).
- 기존 `getMyProductStatsData`는 페이지 스코프뿐 → **`SellerProductFacade`에 전체 소유 variant→product 매핑 조회 메서드 추가**: `getMyOwnedVariantMappings(email) → List<VariantProductMapping>`(email 스코프·소유 검증, 외부 id 미신뢰 — IDOR 안전). product 모듈 published port의 동일 데이터 확장이라 정당(과설계 아님). variant 없는 상품/삭제 variant는 자연 제외(기존 한계 동일).
- **★ 신규 repository 쿼리 필요(MAJOR — 비페이지 owner 경로 부재)**: 현존 owner-scoped 쿼리는 `ProductRepository.findByOwnerIdOrderByCreatedAtDescIdDesc(ownerId, pageable)`(페이지 전용)뿐이고, variant 매핑은 `ProductVariantRepository.findVariantProductMappingsByProductIdIn(productIds)`(productId 선행 필요)뿐. 따라서 **`ProductVariantRepository`에 owner 기준 매핑 쿼리 1개 신설**: `SELECT new ...VariantProductMapping(pv.id, pv.product.id) FROM ProductVariant pv WHERE pv.product.ownerId = :ownerId`(N+1 없이 1쿼리). facade 구현(`SellerProductFacadeImpl`)이 `userDirectory.findUserIdByEmail(email)`로 ownerId 해석 후 이 쿼리 호출.
- **연결 시점 1회** 이 매핑을 해석해 registry에 캐시(③-a). 연결 중 신규 상품은 reconnect 전까지 미반영(task 명시 staleness).

## 3. 컴포넌트 (web/product — 기존 화면이 web/product이므로 일관. 046이 web/admin인 것과 대칭)
### 3.1 `SellerSalesStatsSseController` (@RestController, GET /seller/products/stats/stream, text/event-stream)
- `CurrentActorResolver.resolve(auth).email()` → email. (컨트롤러는 외부 id 미수신, IDOR 안전.)
- **★ registry 키 = `String email`로 확정(BLOCKER)**: `CurrentActor`는 `email`·`admin` 두 필드만 노출(userId/sellerId 없음). 게다가 broadcaster는 `@Scheduled`라 **인증 컨텍스트가 없어** tick 시점에 email→ownerId 재해석 불가 → 키는 "연결 시 컨트롤러가 넣은 값=email"이어야 한다. email은 principal username이라 판매자별 유일 → 격리 키로 충분(ownerId 키는 불필요, YAGNI).
- 연결 시(초기 스냅샷 — broadcaster union 경유 금지): `getMyOwnedVariantMappings(email)`로 variant→product 매핑 해석(1쿼리, +email→ownerId 1쿼리) → 그 variantId 집합으로 **`aggregateByVariantIds(그 판매자 variantId)` 직접 1회** 호출해 초기 productId 맵 build → `registry.add(email, emitter, mapping)` → onCompletion/onTimeout/onError에서 remove(마지막 emitter 제거 시 매핑도 정리). build 실패는 add 이전 전파(dead emitter 차단 — 046 선례). **연결당 초기 ~3쿼리(ownerId 해석·매핑·집계) — 허용.**
- **★ registry.add 원자성**: emitter 등록과 매핑 등록을 **단일 호출에서 함께**(부분 등록 불가). emitter만 들어가고 매핑이 누락되면 broadcaster가 그 키를 빈 매핑으로 분배해 그 판매자가 영구 빈 스트림이 된다.
- `@Value` SSE timeout(`shop.seller.sales.sse.timeout:PT30M`).

### 3.2 `SellerSalesStatsSseRegistry` (노드 로컬, 키 = email)
- `Map<String email, List<SseEmitter>>`(email별 CopyOnWriteArrayList) + `Map<String email, Map<Long,Long>> variantToProductByEmail`(연결 시 캐시 매핑, ②③).
- `add(email, emitter, variantToProduct)`(원자적 — emitter+매핑 동시) / `remove(email, emitter)`(마지막 제거 시 매핑 제거) / `sendTo(email, snapshot)` / `connectedEmails()` / `variantToProductOf(email)` / 전 연결 variantId 합집합 제공.
- **멀티탭(같은 판매자 N emitter)**: 동일 email 키에 emitter가 쌓이고 **매핑은 키별 1개(최초 연결 스냅샷) 공유** — 탭별 재해석 안 함(③-a staleness 정책 일관). 한 탭 닫힘 시 remove, 남은 emitter 있으면 매핑 유지.
- 노드 로컬(Redis 미사용) — 046 근거 동일(멀티 인스턴스 정합: 노드별 자기 연결에 push).

### 3.3 `SellerSalesStatsSseBroadcaster` (@Scheduled — tick당 1 배치 쿼리 ②)
- `connectedKeys()` 0이면 skip.
- 아니면: 전 연결 캐시 매핑의 **variantId 합집합** → `sellerSalesStatsPort.aggregateByVariantIds(union)` **1회** → `Map<variantId, VariantSalesAggregate>` 조립 → 키별로 그 키의 캐시 매핑+해당 variant 집계를 `assembler.mergeSalesByProduct(...)`에 넣어 productId 맵 build → `registry.sendTo(key, snapshot)`. **판매자 수에 비례한 N쿼리 금지.**
- 레이어: Scheduler → assembler(web 조합) + order.spi(집계) — ServiceResponse 미사용.

### 3.4 `SellerSalesStatsSseSchedulingConfig`
- 전용 `@EnableScheduling` + `@ConditionalOnProperty(prefix="shop.seller.sales.sse", name="enabled", havingValue="true", matchIfMissing=true)`. 046과 동일 구조(order-expiry·admin SSE 스케줄과 독립).

### 3.5 config (application.yml)
- `shop.seller.sales.sse.{enabled(기본 on), interval(PT10S), timeout(PT30M)}`. `src/test/resources/application.yml`에 `shop.seller.sales.sse.enabled: false`(테스트 컨텍스트 @Scheduled 비발화 — 046 선례).

### 3.6 View (`seller/product-stats.html` — view-implementor)
- `<main>` 안에 인라인 `<script>`로 `EventSource('/seller/products/stats/stream')` 구독 → `event: stats` 수신(JSON productId 맵) → **현재 표 각 행을 productId(data-product-id 등)로 매칭해 판매수량·매출 셀만 갱신**(맵에 없는 행 불변). 행에 productId 식별 속성 부여 필요(템플릿 보강). 인라인 script는 반드시 main 프래그먼트 내부([[inline-script-must-be-inside-main-layout-fragment]]).
- 점진적 향상: SSE 미동작 시 서버 렌더 수치 유지.

## 4. 보안 / 규칙
- IDOR: 컨트롤러·broadcaster 모두 **외부 productId/variantId 미수신**. 데이터는 principal email→소유 검증 매핑에서만 파생(기존 `getMyProductStatsData` IDOR 원칙 계승).
- `/seller/**` hasRole(SELLER), GET이라 CSRF 무관, 세션 쿠키 인증(046 동일). 비SELLER 403.
- architecture-rule: SSE는 View 계층(ServiceResponse 미사용). 가상스레드 대비 ThreadLocal 직접 사용 금지.

## 5. 멀티 인스턴스 정합
- registry 노드 로컬 — 판매자가 한 노드에 핀, 각 노드 broadcaster가 자기 연결 판매자에 DB조회 push(046 근거 동일). 멀티 인스턴스 안전(감사 리포트 001 SSE 항목과 일관).

## 6. Non-goals
- 구매자/admin 추가 SSE, 판매자 대상 신규 알림, WebSocket, Redis 공유 registry, 페이지네이션/집계 모델 재설계, `SellerSalesStatsPort` 시그니처 변경.

## 7. 검증
- **per-seller 격리(최우선)**: 판매자 A 스트림에 B 데이터 0 — 통합(registry.sendTo 키 스코프 + broadcaster 분배) + **E2E**(A·B 동시 접속, A 상품 주문 시 A만 갱신, B 불변). [[verify-admin-list-page-features-with-e2e]].
- **배치 1쿼리**: N명 연결 시 tick당 `aggregateByVariantIds` **1회**(합집합)임을 Hibernate Statistics 또는 mock 호출 횟수로 단언(②).
- **연결당 초기 쿼리**: 연결 1회당 초기 스냅샷이 broadcaster union을 거치지 않고 직접 build됨(ownerId 해석·매핑·집계 ~3쿼리, tick 경로와 분리) 확인.
- **멀티탭**: 같은 판매자 2 emitter(2탭) → 둘 다 갱신, 키별 매핑 1개 공유. 한 탭 닫아도 나머지 정상.
- **종단**: 주문 결제 → 다음 tick에 해당 판매자 스트림 수치 갱신.
- **빈 연결 skip**: 연결 0이면 집계 미호출.
- **초기 스냅샷 = 화면 수치 일치**(productId 매칭).
- **권한**: 비SELLER `/stream` 403, 비인증 redirect.
- **@Scheduled test 비발화**(enabled=false).
- **공통 메서드**: 페이지 `assemble()`와 SSE가 동일 `mergeSalesByProduct` 사용(수치 일치 회귀).
- 메인 게이트: Modulith verify + 풀 스위트 그린.

## 8. 구현 순서 (오케스트레이션)
1. backend-implementor: `SellerProductFacade.getMyOwnedVariantMappings` + 구현, `SellerProductStatsAssembler` 공통 `mergeSalesByProduct` 추출 + SSE 스냅샷 build, SSE 4종 컴포넌트, payload DTO, config, 통합테스트(격리·배치1쿼리·빈연결·권한·@Scheduled off).
2. view-implementor: `seller/product-stats.html` 행 productId 식별 속성 + EventSource 패치 스크립트(main 내부).
3. reviewer → (FAIL 시) fixer → 재리뷰.
4. 메인 게이트: Modulith verify + 풀 스위트.
5. e2e-runner: per-seller 격리 E2E(A·B 동시, 실시간 갱신).

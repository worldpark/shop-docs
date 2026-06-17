# shop-core 멀티 인스턴스 준비 상태 감사

> 작성일: 2026-06-17 · 대상: shop-core 전체
> 목적: "단일 인스턴스로 운영하되 멀티 인스턴스(공유 PG·Kafka·Redis, 2+ 노드) 가능하게 개발" 목표 대비, 단일 인스턴스 가정으로 멀티에서 깨질 코드를 전수 감사.
> 방법: 6개 카테고리(@Scheduled 중복실행 / 인메모리 정합 상태 / SSE 레지스트리 / 로컬 파일 직접접근 / in-JVM 락 / 싱글톤·세션스코프) 코드 근거 기반 점검.

---

## 결론

**BREAKS-correctness 등급 위반: 0건.** 코드베이스는 이미 멀티 인스턴스를 강하게 의식해 설계돼 있다. 멀티 전환 시 손볼 곳은 **단 1개(폼 로그인 세션, UX 등급)** + **환경변수 토글 1개(정적 자산)** + **운영 사이징 1개(풀×노드)** 뿐이다.

| 우선순위 | 항목 | 등급 | 조치 |
|---|---|---|---|
| 1 | Thymeleaf 폼 로그인 **HttpSession 인메모리** | DEGRADES-UX | Spring Session Redis 외부화 |
| 2 | 정적 자산 로컬 디스크(`local` 프로파일) | 환경 의존 | `SHOP_STORAGE_TYPE=r2` 토글(코드 무수정) |
| 3 | Hikari 풀 × 노드 수 ≤ PG `max_connections` | 운영 사이징 | 노드 수 기준 풀 검토(report 004) |

---

## 위반 / 조치 항목 (3건)

### 1. [DEGRADES-UX] 폼 로그인 세션이 인메모리
- 근거: `security/SecurityConfig.java:154-224`(formLogin + 기본 세션, STATELESS 미지정), `:237`(`HttpSessionRequestCache`). `build.gradle` — `spring-session-*` 의존 없음.
- 문제: 브라우저 `JSESSIONID`가 톰캣 인메모리 저장. 멀티 노드 + LB에서 스티키 세션 없으면 노드 전환 시 세션 분실 → 재로그인. 로그인 후 복귀 URL(SavedRequest)도 노드 로컬.
- **완화**: REST API는 완전 STATELESS(JWT) + refresh/blacklist 토큰 Redis 공유(`RedisRefreshTokenStore`)라 **API 트래픽은 무영향**. 영향은 Thymeleaf 폼 로그인 사용자 한정.
- **권장**: `spring-session-data-redis` + `@EnableRedisHttpSession`. Redis 인프라가 이미 있어 저비용. (단기 회피: LB 스티키 세션 — 비권장)

### 2. [환경 의존] 정적 자산 로컬 디스크 직접 접근 (`local` 프로파일 한정)
- 근거: `common/storage/LocalObjectStorage.java:56-75`(`Files.copy`/`deleteIfExists`), `common/web/StaticResourceConfig.java:42-43`(`file:` 핸들러 서빙).
- 문제: `SHOP_STORAGE_TYPE=local`(기본)일 때 업로드 이미지가 그 노드 `./uploads`에만 존재 → 타 노드 서빙 불가.
- **판정**: 이미 인지된 설계. `@ConditionalOnProperty(type=local)` 가드 + `R2ObjectStorage`(S3 SDK) 구현 완료. `ObjectStorage` 포트 추상화로 우회 직접 접근 없음.
- **권장**: 멀티 운영 시 `SHOP_STORAGE_TYPE=r2` 토글 — **코드 수정 불요**.

### 3. [운영 사이징] Hikari 풀 × 노드 수
- 근거: `application.yml:14` `maximum-pool-size:30`(노드별 풀). PG `max_connections` 기본 100.
- 권장: 노드 수 × 30 ≤ 100 검토(3노드=90). report 004의 풀 결정과 정합. 코드 위반 아님.

---

## 안전 확인 목록 (이미 멀티 인스턴스 안전)

- **@Scheduled 단일 실행 보장**: 미결제 만료 `UnpaidOrderExpiryScheduler.java:63-69`가 `SchedulerLeaderGuard.runIfLeader(...)`로 게이트 — `RedissonSchedulerLeaderGuard`(Redisson `tryLock(0,...)` 비대기 + watchdog + `isHeldByCurrentThread`)로 정석 분산락(Task 035). 최종 방어선은 `PaymentService.expirePendingOrder`의 `findByIdForUpdate` 행 락(멱등).
- **SSE broadcaster 노드 로컬 발화가 정답**: `AdminDashboardSseBroadcaster.java:35`는 리더 게이트 미적용이 올바름 — 각 노드가 자기 연결 emitter에만 push(노드별 emitter 집합 disjoint, 중복 작업 아님). `AdminDashboardSseRegistry`(노드 로컬 `CopyOnWriteArrayList`)도 의도된 노드 로컬.
- **도메인 동시성 = DB 비관락 + UNIQUE**(단일 PG가 노드 간 직렬화): 재고(`@Lock(PESSIMISTIC_WRITE)` `findByIdForUpdate`), 주문/결제/취소/배송 행 락, `uq_payments_order_id`, `uq_shipment_items_order_item`(배송 이중배정 차단), `uq_user_coupons_user_coupon`, `uq_reviews_order_item_id`.
- **토큰/세션 상태 Redis 공유**: refresh/blacklist(`RedisRefreshTokenStore`), 비밀번호 재설정(`RedisPasswordResetTokenStore`). 로그인 활동은 DB(`last_login_at`).
- **이벤트 = Transactional Outbox(Modulith Event Publication, DB 영속) + Kafka 컨슈머 그룹 + 멱등 소비** — 노드 공유·단방향.
- **인메모리 정합 위험 없음**: `@Cacheable`/Caffeine/cache starter 미사용, 로그인 시도·잠금·레이트리밋 인메모리 카운터 없음, cross-request `synchronized`/`ReentrantLock`/`volatile` 없음, `@SessionScope`/`@ApplicationScope` 빈 없음. (`ProductOrderCatalogImpl.java:77` `AtomicInteger`는 요청-로컬 스트림 카운터 — 공유 아님.)

---

## 멀티 인스턴스 검증 방법 (솔로 가능)
실 클러스터 없이 **한 머신에서 앱 2개(포트 8080/8081)를 같은 PG·Kafka·Redis에 붙여** 기동하면 위 항목(특히 #1 세션)을 그대로 검증할 수 있다. #1을 Redis 세션으로 고치면 2-노드에서 세션 유지가 확인된다.

## 참고
- ADR-005(DB-우선 동시성, 다중 노드 Redisson), Task 035(분산락), report 004(Hikari 풀 사이징), ADR-006(ObjectStorage 키·로컬 우선).

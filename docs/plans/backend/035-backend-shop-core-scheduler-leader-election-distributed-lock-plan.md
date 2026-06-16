# 035. shop-core 스케줄러 리더 선출(분산락 — Redisson) — 구현 계획(plan)

> Task SSOT: docs/tasks/backend/035-backend-shop-core-scheduler-leader-election-distributed-lock.md
> 선행 결정(전제): ADR-005(docs/adr/005-database-first-concurrency-redisson-later.md) — 사용자 결정으로 "다중 노드 배포 채택" 확정. 본 plan은 ADR-005를 "보류 → 채택(스케줄러 리더=Redisson, 적용=스케줄러 리더 실행 한정)" 상태로 갱신하는 작업을 포함한다(2.6).
> 선례 plan(구조·톤·레이어·테스트 패턴): docs/plans/backend/022-...-plan.md(만료 스케줄러·@ConditionalOnProperty 가드·verification-gate §4), docs/plans/infra/005-...-plan.md(Redis 의존성·RedisProperties·테스트 비파괴·Redisson 보류 결정 — 본 Task가 그 "후속 분산락 Task").
> 적용 규칙(작업 전 필독·반영): docs/architecture.md, architecture-rule.md(스케줄러 진입점 = Scheduler -> Service -> Repository), package-structure-rule.md(common=횡단 공통 모듈, OPEN), task-rule.md(1 Task=1 기능·테스트 없이 추가 금지), testing-rule.md(테스트 더블·운영 배선 검증·자동설정 제외 함정·Testcontainers RED→GREEN 비용), forbidden-rule.md(Scheduler에서 Repository 직접 호출 금지), verification-gate-rule.md(정적 PASS ≠ 빌드 그린·컴포넌트 스캔 파급·@ConditionalOnProperty 조건 충족 경로 검증), workspace-rule.md.
> 영역: backend 전용(횡단 인프라 — Redisson 클라이언트 + 공통 concurrency guard + 스케줄러 게이트). REST/View 엔드포인트 없음 → view-implementor 작업 없음.
> 대상 프로젝트: shop-core (Spring Modulith 모듈러 모놀리스)
> 작성일: 2026-06-16
> 상태: plan only (코드 변경 없음 — 구현은 backend-implementor가 수행)
> 담당: backend-implementor 단독(Redisson 빈/설정 + 공통 락 guard + 스케줄러 게이트 + 단위·Testcontainers 통합·구조 테스트 + ADR-005 갱신). view-implementor 작업 없음.

---

## 0. 코드 대조 결과 (실제 소스 점검 — 추측 아님)

> plan의 모든 경로/시그니처/배선은 아래 실측에 근거한다. C1~C9.

| # | 대조 대상 | 실측 결과 | 본 Task 영향 |
|---|---|---|---|
| C1 | payment/service/UnpaidOrderExpiryScheduler.expireUnpaidOrders() | 이미 존재(Task 022). @Component @ConditionalOnProperty(prefix="shop.order.pending-expiry", name="enabled", havingValue="true"), @Scheduled(fixedDelayString="${shop.order.pending-expiry.interval:PT1M}"). 루프 비-@Transactional, 후보 id마다 paymentService.expirePendingOrder(id)를 try/catch 격리 위임. | 1차 락 게이트 대상. expireUnpaidOrders() 본문을 공통 guard로 감싼다(스케줄러 1개 파일만 수정, 위임 로직 불변). |
| C2 | payment/service/OrderExpirySchedulingConfig | 이미 존재. @Configuration @ConditionalOnProperty(...enabled=true) @EnableConfigurationProperties(OrderExpiryProperties.class) @EnableScheduling + @Bean Clock systemClock(). | 무변경. 락 게이트는 같은 활성 조건과 정합(빈 자체가 enabled=true에서만 뜨므로 자동 정합 — 별도 가드 불필요, 1.4). |
| C3 | common/config/RedisProperties.java (Lock record, 76~93행) | 이미 존재. record Lock(String prefix, Duration ttl) — 기본값 prefix="shopcore:lock:", ttl=PT10S. javadoc "실제 락 획득/해제 구현과 Redisson 도입 여부는 분산락 Task에서 결정". | 재사용·정리. 새 properties 신설 금지. Redisson watchdog 사용으로 ttl(고정 lease)은 락 게이트에 쓰지 않음 → javadoc/주석을 "watchdog 자동 갱신, ttl은 게이트에 미사용(레거시 stub)"로 정정(2.2). prefix는 락 키 조립에 사용. |
| C4 | application.yml (shop.redis.lock, 116~119행) | 이미 존재. lock.prefix=${SHOP_REDIS_LOCK_PREFIX:shopcore:lock:}, lock.ttl=${SHOP_REDIS_LOCK_TTL:PT10S} + "분산락 — 키는 {resource}" 주석. | 재사용·주석 정정. stub 주석을 "스케줄러 리더 게이트에서 사용. watchdog 자동 갱신이라 ttl 미사용"으로 갱신. 새 키 추가는 스케줄러 리소스 이름뿐(2.2). |
| C5 | 기존 Redis 배선 — RedisConfig(common, @EnableConfigurationProperties(RedisProperties.class)만), RedisRefreshTokenStore/RedisPasswordResetTokenStore가 자동설정 StringRedisTemplate 사용 | 이미 존재(Task 005/030). RedisConfig는 StringRedisTemplate 빈을 명시 정의하지 않고 Spring Boot RedisAutoConfiguration(Lettuce) 자동 제공에 의존. | 건드리지 않는다. Redisson은 별도 RedissonClient 빈으로 추가. Lettuce 연결팩토리·StringRedisTemplate·자동설정 무변경(Task 기술제약 1). |
| C6 | 테스트 프로파일 src/test/resources/application.yml | spring.autoconfigure.exclude에 RedisAutoConfiguration을 넣지 않는다. 대신 Lettuce 지연 연결(첫 명령 시 연결)로 브로커 없이 컨텍스트 로드 통과. shop.order.pending-expiry.enabled: false(스케줄러 비활성). RefreshTokenStoreWiringTest javadoc이 이 특성 명문화. | 이 특성을 보존해야 한다. redisson-spring-boot-starter는 RedisConnectionFactory를 교체해 이 "지연 연결 → 무브로커 컨텍스트 로드 통과"를 깨므로 금지. plain org.redisson:redisson만 추가하고 RedissonClient를 lazy/지연 연결로 등록(1.2, 2.1). 테스트 컨텍스트에서 enabled=false라 스케줄러·guard는 안 뜨지만, RedissonClient 빈 자체는 풀컨텍스트에서 뜨므로 무브로커 로드 통과를 반드시 보존(5 컨텍스트 회귀 가드). |
| C7 | Testcontainers Redis 패턴 | PasswordResetRedisIntegrationTest가 추가 의존 없이 GenericContainer(DockerImageName.parse("redis:7-alpine")).withExposedPorts(6379) + @DynamicPropertySource로 spring.data.redis.host/port 주입. PostgreSQL은 @ServiceConnection. | 그대로 답습. 035 통합 테스트는 Redis Testcontainer 1개 + Redisson 클라이언트 2개로 검증(5). 새 Testcontainers 의존 불필요(org.testcontainers:junit-jupiter 보유). |
| C8 | build.gradle | spring-boot-starter-data-redis(Lettuce) 보유. Redisson 의존 없음. | 추가: implementation 'org.redisson:redisson:<ver>'(plain, starter 아님). Spring Boot BOM이 Redisson 버전을 관리하지 않으므로 버전 명시(jjwt 선례와 동일 — 2.1). |
| C9 | 모듈 구조 — common(OPEN, 횡단 공통: RedisConfig·BaseEntity·예외), PaymentModuleStructureTest/OrderModuleStructureTest/ModularityTests | common은 @ApplicationModule(type=OPEN). 모든 도메인 모듈이 의존 가능. 스케줄러는 payment 모듈 소유(022). | Redisson 빈·공통 락 guard는 횡단 인프라 → common.config/common.concurrency에 둔다(특정 도메인 소유 아님 — ADR-005 "공통 concurrency guard로 격리"). payment 스케줄러가 common guard에 의존(OPEN 모듈이라 Modulith 위반 아님). |

핵심 결론: 신규 migration 0, 신규 이벤트/토픽 0, 도메인 로직·도메인 행 락 변경 0. 추가되는 것은 Redisson 의존 1 + RedissonClient 빈/설정 1 + 공통 락 guard(인터페이스+구현) 1쌍 + UnpaidOrderExpiryScheduler 본문을 guard로 감싸는 수정 + 기존 RedisProperties.Lock/yml stub 주석 정정 + ADR-005 갱신뿐이다. 기존 Lettuce/StringRedisTemplate·결제/주문/재고 경로는 무변경.

---

## 1. 설계 방식 및 이유

### 1.1 무엇을(중복 실행) 왜(다중 노드) — 목적은 strict 단일 실행이 아니라 중복 작업 축소
- 코드베이스의 비관적 락은 전부 DB 행 락(@Lock(PESSIMISTIC_WRITE) → SELECT ... FOR UPDATE)이며, 단일 PostgreSQL을 공유하는 한 다중 노드에서도 이미 전역 직렬화된다(정합 = 도메인 행 락이 보장, 멱등). 따라서 도메인 행 락에는 Redisson을 덧씌우지 않는다(이중 락·데드락 위험 — Task Non-goal).
- 다중 노드의 실제 빈틈은 인메모리 @Scheduled가 모든 노드에서 동시 발화하는 것이다. UnpaidOrderExpiryScheduler.expireUnpaidOrders()가 N개 노드에서 동시에 같은 만료 후보를 조회·처리하면 정합은 깨지지 않으나(주문 행 락) 경합·중복 작업이 발생한다.
- 본 Task의 목적은 다중 노드 중복 작업 축소다. strict 단일 실행은 목표가 아니며 TTL 분산락으로 보장 불가(작업 overrun·watchdog 갱신 실패·GC pause 시 일시적 2-노드 동시 실행이 이론상 가능). 그 한계가 안전한 이유: 정합은 도메인 행 락=멱등이 이미 보장하므로, 락은 "대부분의 경우 1노드만 돌게 해 낭비를 줄이는" best-effort 게이트다(6 트레이드오프).

### 1.2 Redisson 도입 방식 — plain 의존 + 별도 RedissonClient 빈(starter 금지, Lettuce 무영향)
- redisson-spring-boot-starter 금지(Task 기술제약 1). starter는 RedisConnectionFactory를 Redisson 기반으로 교체해 (a) 기존 Lettuce StringRedisTemplate(RefreshToken·PasswordReset) 동작과 (b) "지연 연결 덕에 브로커 없이 테스트 컨텍스트 로드 통과"(C6 — RefreshTokenStoreWiringTest가 의존하는 특성)를 깨뜨린다.
- plain org.redisson:redisson만 추가하고 별도 RedissonClient 빈을 등록한다(2.1). 동일 Redis host/port·DB index 0(spring.data.redis.* 재사용). 기존 Lettuce 연결팩토리·StringRedisTemplate·RedisAutoConfiguration은 건드리지 않는다.
- 무브로커 컨텍스트 로드 보존: Redisson Config를 지연 연결 기본 동작에 맡긴다. 만약 Redisson이 빈 생성 시 즉시 연결을 시도해 무브로커 풀컨텍스트 로드가 깨지면, 테스트 프로파일에서 RedissonClient를 가드/Mock·no-op으로 대체하는 보강을 적용한다(구현 시 5에서 RED→GREEN 실측 후 택1 — 이론 추론 금지, testing-rule "RED는 경험으로 확인").

### 1.3 공통 concurrency guard로 락 API 격리 (ADR-005 결과 항목과 정합)
- ADR-005 "결과/부정적 결과와 대응"이 "Service 내부에 락 API를 직접 흩뿌리지 않고 공통 concurrency guard 형태로 격리한다"고 명시. 이를 그대로 따른다.
- 공통 guard 인터페이스 1개 + Redisson 구현 1개를 common(횡단 OPEN 모듈, C9)에 둔다. 스케줄러는 guard의 단일 메서드(runIfLeader(resource, task))만 호출하고 Redisson RLock·tryLock 호출을 직접 알지 못한다.
- 효과: (a) 락 메커니즘(Redisson)을 한 곳에 가두어 도메인/스케줄러 코드에 락 호출이 흩뿌려지지 않음, (b) 단위 테스트에서 guard를 fake로 대체해 스케줄러 로직을 격리 검증 가능, (c) 후속 스케줄러(1.6 Modulith 재발행 등)가 동일 guard를 재사용.

### 1.4 락 게이트는 스케줄러 활성 조건과 자동 정합 (@ConditionalOnProperty)
- UnpaidOrderExpiryScheduler는 @ConditionalOnProperty(shop.order.pending-expiry.enabled=true)로 가드되어(C1) 빈 자체가 enabled=true에서만 생성된다. 락 게이트를 이 스케줄러 본문 안에 두므로 별도 활성 조건 없이 자동 정합한다(스케줄러 빈이 없으면 락 호출도 없음 — Task 기술제약 4). 테스트 프로파일(enabled=false)에서는 스케줄러·guard 호출 경로가 아예 안 뜬다.
- guard 빈 자체(common)는 enabled와 무관하게 풀컨텍스트에 뜰 수 있다. 그래도 무해: guard는 호출되지 않으면 락을 잡지 않고, RedissonClient는 지연 연결이라 브로커 없이도 빈 생성만 된다(1.2, 5).

### 1.5 tryLock(0, ...) 비대기 + leaseTime 미지정(watchdog) + finally 가드 해제 (Task 기술제약 3)
- 게이트 진입 시 RLock.tryLock(0, TimeUnit.SECONDS)(waitTime=0 비대기). 획득 실패 노드는 즉시 skip(대기하지 않음 — 다른 노드가 이미 리더). 획득 성공 노드만 작업 수행.
- leaseTime을 지정하지 않는다 → Redisson watchdog이 보유 프로세스 생존 동안 락을 자동 갱신(기본 30s lease를 10s마다 갱신). 고정 leaseTime 금지: 작업이 lease보다 길어지면(overrun) 실행 중 만료돼 다른 노드가 동시에 획득 = 중복 실행 재오픈(Task 기술제약 3 명시).
- 해제는 finally에서 isHeldByCurrentThread()일 때만 unlock(). (a) 획득 실패 시 unlock하지 않음(타 노드 락 침범 방지), (b) watchdog lease 만료 후 타 노드가 이미 재획득한 상태에서 잘못 unlock하는 것 방지(isHeldByCurrentThread 가드).

### 1.6 적용 범위 = 스케줄러 리더 실행 한정 (도메인 행 락 무덧씌움)
- 1차 적용: UnpaidOrderExpiryScheduler.expireUnpaidOrders()만. 도메인 행 락(VariantStock/Order SELECT FOR UPDATE)에는 Redisson을 덧씌우지 않는다(이미 단일 PG로 노드 간 직렬화 — 이중 락·데드락 위험, Task Non-goal).
- (Non-goal/후속) Modulith 미완료 이벤트 재발행 스케줄러(현재 application.yml에 republish-on-restart/resubmission 미설정 → 비활성)는 본 Task 비대상. 켜지면 모든 노드가 같은 INCOMPLETE 이벤트를 재발행해 중복이 증폭되므로, 동일 guard(runIfLeader)로 게이트하라는 가이드만 본 plan에 명시(2.5). 새 기능 1개=1 Task 원칙 유지 — 재발행 게이트는 그 스케줄러를 켜는 별도 Task에서 수행.

### 1.7 신규 migration·이벤트·도메인 전이 0
- Redisson은 Redis 키(shopcore:lock:{resource})만 사용 → DB 스키마 무관, 신규 V_ migration 0. 이벤트/토픽 무변경(event-catalog.md/architecture.md §5 무변경). 도메인 로직·행 락·expirePendingOrder 오케스트레이션(022) 무변경.

---

## 2. 구성 요소 (신규/수정 — 정확한 패키지 경로)

> 전부 backend-implementor 담당. view-implementor 작업 없음. 신규/수정 구분 명시.

### 2.1 (수정) build.gradle + (신규) Redisson 설정 — RedissonClient 별도 빈
- (수정) shop-core/build.gradle — Redisson 의존 추가:
  - implementation 'org.redisson:redisson:<latest-3.x>' (plain, starter 금지, 버전 명시 — Spring Boot BOM 미관리, jjwt 선례).
  - 버전 핀: Spring Boot 3.5.x / Lettuce 공존 호환 3.x 라인을 구현 시점에 확정하고 build.gradle에 명시적 버전 핀으로 박는다(jjwt 선례와 동일 방식 — `<latest-3.x>`를 실제 고정 버전 문자열로 치환, 추적 가능). Spring Boot BOM이 Redisson 버전을 관리하지 않으므로 버전 생략·동적 버전 금지.
  - redisson-spring-boot-starter 절대 추가 금지(C6·Task 기술제약 1).
- (신규) shop-core/src/main/java/com/shop/shop/common/config/RedissonConfig.java(@Configuration):
  - @Bean(destroyMethod = "shutdown") RedissonClient redissonClient(...) — spring.data.redis.host/port/database를 주입(@Value 또는 Spring RedisProperties)받아 단일 서버 모드 Config로 구성. DB index 0(기존 Lettuce와 동일 — 락 키는 prefix로 구분).
  - 기존 RedisConfig(common, @EnableConfigurationProperties(RedisProperties.class))는 무변경. Redisson은 별도 @Configuration으로 분리해 Lettuce 자동설정과 독립.
  - 무브로커 컨텍스트 로드 보존(1.2): Redisson 기본 lazy 연결에 맡기되, 5 컨텍스트 회귀 가드로 무브로커 풀컨텍스트 로드가 통과하는지 실측. 깨지면 테스트 프로파일에서 RedissonClient를 가드/no-op 대체(구현 시 5 실측 후 택1).
  - javadoc: "plain Redisson 별도 빈(starter 금지 이유)·DB index 0·Lettuce 무영향·watchdog 사용으로 lease 미지정" 명시.

### 2.2 (수정) RedisProperties.Lock + application.yml stub — 재사용·주석 정정 (새로 만들지 않음, Task 기술제약 2)
- (수정) shop-core/src/main/java/com/shop/shop/common/config/RedisProperties.java(C3, Lock record 76~93행) — 신설 금지, 기존 재사용:
  - prefix(shopcore:lock:)는 락 키 조립에 사용(prefix + "scheduler:unpaid-order-expiry").
  - ttl(PT10S)는 watchdog 사용으로 게이트에 쓰지 않음 → javadoc을 "스케줄러 리더 게이트는 leaseTime 미지정(watchdog 자동 갱신). ttl은 고정 lease가 필요한 다른 용도용 레거시 stub이며 리더 게이트에 미사용"으로 정정. (필드 제거는 하지 않음 — 기존 바인딩/테스트 보존, 의미만 명확화.)
- (수정) shop-core/src/main/resources/application.yml(C4, 116~119행) — shop.redis.lock 블록 주석 정정:
  - 기존 "분산락 — 키는 {resource}, 실제 락 획득/해제는 분산락 Task에서 구현" → "스케줄러 리더 게이트에서 사용(Task 035). 키 = {prefix}scheduler:{name}. watchdog 자동 갱신이라 ttl(고정 lease)은 리더 게이트에 미사용".
  - lock.prefix/lock.ttl 값·환경변수는 유지(stub 재사용). 새 properties/yml 블록 신설 0.
- (신규 키 상수) 스케줄러 리소스 이름은 guard 호출부(스케줄러) 또는 guard 구현 내 상수로 둔다(예: "scheduler:unpaid-order-expiry"). 매직 문자열 산재 방지.

### 2.3 (신규) 공통 concurrency guard — 인터페이스 + Redisson 구현 (common, ADR-005 결과 항목)
- (신규) shop-core/src/main/java/com/shop/shop/common/concurrency/SchedulerLeaderGuard.java(인터페이스):
  - 단일 메서드(확정 시그니처 — 구현 추정 여지 없음): boolean runIfLeader(String resource, Runnable task)
    - 리더 락을 비대기 획득하면 task 실행 후 true 반환, 획득 실패면 실행 없이 false 반환(호출부가 skip 로깅).
    - 이 시그니처는 확정이다(테스트 5.2 SchedulerLeaderGuardUnitTest·5.3 UnpaidOrderExpirySchedulerTest가 이미 boolean runIfLeader(String, Runnable)을 전제하므로 implementor가 변형하지 않는다).
  - javadoc: "스케줄러 다중 노드 중복 실행 축소용 best-effort 리더 게이트. strict 단일 실행 아님(정합은 도메인 행 락=멱등 보장). 비대기·watchdog·finally 해제 규약을 구현이 보장."
  - 패키지 common.concurrency(횡단 — 특정 도메인 소유 아님, C9 OPEN 모듈).
- (신규) shop-core/src/main/java/com/shop/shop/common/concurrency/RedissonSchedulerLeaderGuard.java(@Component, implements SchedulerLeaderGuard):
  - 의존: RedissonClient, RedisProperties(락 prefix 출처 — C3).
  - 구현 골자(Task 기술제약 3·5, 1.5):
    - lockKey = redisProperties.lock().prefix() + resource;
    - RLock lock = redissonClient.getLock(lockKey);
    - acquired = lock.tryLock(0, TimeUnit.SECONDS); — 비대기·leaseTime 미지정(watchdog).
    - 획득 실패 → debug 로깅 후 return false(task 미실행).
    - 획득 성공 → task.run(); return true;
    - catch (InterruptedException) → Thread.currentThread().interrupt();(인터럽트 복원) + warn + return false(미실행).
    - finally → if (acquired && lock.isHeldByCurrentThread()) lock.unlock();(가드 해제).
  - Redis 연결 실패(RedisException 등)는 4 정책대로 catch → false(폴백 skip).

### 2.4 (수정) UnpaidOrderExpiryScheduler — 본문을 guard로 게이트 (C1)
- (수정) shop-core/src/main/java/com/shop/shop/payment/service/UnpaidOrderExpiryScheduler.java:
  - 의존에 SchedulerLeaderGuard 추가(common.concurrency — OPEN 모듈이라 payment→common 의존 허용, Modulith 위반 아님).
  - @Scheduled 메서드 expireUnpaidOrders()를 guard로 감싼다: leaderGuard.runIfLeader(SCHEDULER_RESOURCE, this::doExpireUnpaidOrders) → false면 "타 노드 리더, skip" 로깅.
  - 기존 위임 로직(022 본문 — threshold 계산·조회·위임·로깅)을 private void doExpireUnpaidOrders()로 이동만(동작 불변). 락 게이트는 진입부만 추가.
  - SCHEDULER_RESOURCE = "scheduler:unpaid-order-expiry" 상수.
  - 활성 조건 정합(1.4): 이 빈은 @ConditionalOnProperty(enabled=true)라 락 게이트도 자동으로 같은 조건에서만 동작. 별도 가드 불필요.

### 2.5 (Non-goal/후속 가이드 — 코드 변경 없음) Modulith 재발행 스케줄러
- 본 plan은 코드를 추가하지 않고, 가이드만 명시: Modulith 미완료 이벤트 재발행(republish-on-restart/resubmission)을 켜는 후속 Task에서 그 스케줄러도 leaderGuard.runIfLeader("scheduler:event-republish", ...)로 게이트한다. 정합은 컨슈머 멱등이 보장하므로 목적은 중복 재발행 축소. (1 Task=1 기능 — 본 Task에선 미구현.)
- 새로 추가되는 재고/주문 배치도 동일 guard 규약을 따르도록 SchedulerLeaderGuard javadoc·plan에 기록.

### 2.6 (수정) ADR-005 — 보류 → 채택 기록 (선행 결정 명문화)
- (수정) docs/adr/005-database-first-concurrency-redisson-later.md:
  - "결정"/"결과"에 "2026-06-16 갱신: 사용자 결정으로 다중 노드 배포 채택. 이에 따라 분산락=Redisson을 도입하되 적용 범위는 스케줄러 리더 실행에 한정(Task 035). 도메인 행 락(단일 PG로 노드 간 직렬화)에는 Redisson을 덧씌우지 않는다. 목적은 strict 단일 실행이 아니라 다중 노드 중복 작업 축소(정합은 도메인 행 락=멱등이 보장)." 추가.
  - "Redisson 도입 후보" 목록 중 "다중 노드에서 같은 자원을 동시에 처리하는 scheduler"가 본 Task로 실현됨을 명기. ADR 상태는 Accepted 유지(세부 갱신 노트 추가 방식 — 기존 ADR 톤 보존).
- (검토) docs/architecture.md(ADR-005 링크부, 111행)·docs/backlog/backend/007-...-distributed-lock.md가 본 Task로 소화됨을 1줄 참조 추가(있으면). event-catalog/event 계약은 무변경.

### 2.7 (신규) 테스트 (5절 매핑)
- common/concurrency/RedissonSchedulerLeaderGuardTest.java(신규, Testcontainers Redis + Redisson 2 클라이언트) — 동시 tryLock 정확히 1개 획득 / 해제 후 타 클라이언트 획득 / 비대기 skip / finally 해제.
- common/concurrency/SchedulerLeaderGuardUnitTest.java(신규, Mockito) — InterruptedException·획득 실패 skip·isHeldByCurrentThread 가드 해제·leaseTime 미지정 호출 단언(InOrder/argument).
- payment/service/UnpaidOrderExpirySchedulerTest.java(보강, 기존 022 단위) — guard fake로 (a) 리더면 위임 실행, (b) 비리더면 위임 0회.
- 무브로커 컨텍스트 로드 회귀 가드(예: RefreshTokenStoreWiringTest 계열 또는 신규 RedissonClientContextLoadTest) — Redisson 추가 후에도 무브로커 풀컨텍스트 로드 통과(C6 보존).
- 구조: PaymentModuleStructureTest/ModularityTests — 스케줄러→common.concurrency 의존 허용(OPEN), payment가 락 라이브러리를 직접 흩뿌리지 않고 guard만 의존함을 확인.

---

## 3. 데이터 흐름 (스케줄러 발화 → tryLock → 실행/skip → finally unlock)

### 3.1 리더 노드 (락 획득 성공)
1. @Scheduled(fixedDelay) → UnpaidOrderExpiryScheduler.expireUnpaidOrders()(노드 A).
2. leaderGuard.runIfLeader("scheduler:unpaid-order-expiry", this::doExpireUnpaidOrders).
3. guard: lockKey = "shopcore:lock:scheduler:unpaid-order-expiry", RLock.tryLock(0, SECONDS) → 획득(leaseTime 미지정 → watchdog 30s lease, 10s마다 자동 갱신).
4. task.run() = doExpireUnpaidOrders(): threshold 계산 → findExpiredPendingOrderIds → 각 주문 paymentService.expirePendingOrder(id)(독립 트랜잭션, 022) → 로깅. (작업 길어져도 watchdog가 lease 갱신.)
5. finally: acquired && isHeldByCurrentThread() → unlock(). 락 해제로 다음 주기/타 노드가 획득 가능.
6. guard true 반환 → 스케줄러 정상 종료.

### 3.2 비리더 노드 (락 획득 실패 → 즉시 skip)
1. 동시에 노드 B의 @Scheduled 발화 → runIfLeader(...).
2. guard: tryLock(0, SECONDS) → 실패(노드 A가 보유). 비대기라 즉시 반환.
3. task.run() 미실행 → finally에서 acquired=false라 unlock 안 함(타 노드 락 침범 0).
4. guard false 반환 → 스케줄러가 "타 노드 리더, skip" 로깅 후 종료. 중복 작업 0.

### 3.3 watchdog 페일오버 (리더 노드 사망)
1. 노드 A가 작업 중 사망(JVM 종료/네트워크 단절) → watchdog 갱신 중단.
2. ~lease(기본 30s) 후 Redis에서 락 자동 만료.
3. 이후 주기에 살아있는 노드가 tryLock(0) → 획득 → 리더 인계. (이 페일오버는 타이밍 의존 — 5에서 통합/수동 한정.)

### 3.4 락 키 / 격리
- 다중 노드 → Redis DB 0 / shopcore:lock:scheduler:unpaid-order-expiry (RLock).
- tryLock(0) 비대기: 1노드만 task 실행, 나머지 즉시 skip.
- 정합은 task 내부 도메인 행 락(orders FOR UPDATE)=멱등이 별도 보장(락 실패해도 중복≠불일치).

---

## 4. 예외 처리 전략 (tryLock·Redis 연결 실패·unlock 가드)

> 스케줄러는 동기 응답 표면 없음 → REST 에러 포맷 비대상. 예외는 로깅 + skip/격리로 처리하며, 락 인프라 장애가 도메인 흐름을 막지 않게 한다(락은 보조 게이트).

| 상황 | 발생 지점 | 처리 |
|---|---|---|
| tryLock InterruptedException | guard lock.tryLock(0, ...) | Thread.currentThread().interrupt()(인터럽트 상태 복원) + warn 로깅 + 작업 미실행 skip(false 반환). 비대기(waitTime=0)라 실제 인터럽트는 드물지만 규약상 반드시 복원·미실행. |
| Redis 연결 실패(브로커 다운·타임아웃) — RedisException/RedisTimeoutException 등 | guard getLock/tryLock | 정책: 폴백 skip(이번 주기 실행 안 함) — 본 Task 기본 채택. 락 인프라 장애 시 "어느 노드가 리더인지" 판정 불가 → 안전하게 이번 주기 skip(warn 로깅)하고 다음 주기 재시도. 만료 작업은 다음 주기에 처리돼도 정합 무손상(TTL 만료는 시간 여유 있음). 대안(중복 위험 감수하고 실행)은 채택 안 함 — 다중 노드에서 전 노드가 락 없이 실행하면 중복이 증폭되기 때문. (guard가 Redisson 런타임 예외를 catch해 false 반환 + warn.) |
| unlock 시 락 미보유(watchdog 만료 후 타 노드 재획득) | guard finally | isHeldByCurrentThread() 가드로 보유 시에만 unlock(). 미보유면 unlock 호출 안 함(타 노드 락 침범·IllegalMonitorStateException 방지). |
| task(doExpireUnpaidOrders) 내부 예외 | guard task.run() | task 내부는 기존 022 격리 유지(주문별 try/catch). guard는 finally에서 반드시 unlock(락 누수 방지)하고 task 예외는 전파해 @Scheduled 기본 로깅에 남긴다. 스케줄러는 다음 주기 재시도. |
| 락 인프라 정상이나 비리더 | guard tryLock false | 정상 흐름(예외 아님). skip 로깅 후 종료. |

핵심 규칙:
- 락은 보조 게이트 — 락 인프라 장애가 시스템을 멈추지 않게 한다(연결 실패 = 이번 주기 skip + 다음 주기 재시도). 정합은 도메인 행 락=멱등이 최종 방어선(ADR-005 "Redisson은 직렬화 수단이지 최종 정합성 근거가 아니다").
- finally 해제는 항상 isHeldByCurrentThread 가드. 신규 커스텀 예외 0(스케줄러 경로 — 락 실패는 예외 변환 대신 skip+로깅).

---

## 5. 검증 방법 (Testcontainers Redis + Redisson 2 클라이언트, forbidden/verification-gate 준수)

> Testcontainers Redis 패턴은 PasswordResetRedisIntegrationTest(C7) 답습 — 추가 의존 없이 GenericContainer(redis:7-alpine) + @DynamicPropertySource. 클록/타이밍 의존 시나리오는 통합/수동 한정 명시.

### 5.1 통합(Testcontainers) — RedissonSchedulerLeaderGuardTest (결정적)
- Redis Testcontainer 1개 + Redisson 클라이언트 2개(또는 2 스레드)로:
  - (a) 동시 tryLock 정확히 1개 획득: 두 클라이언트가 같은 lockKey에 비대기 tryLock(0) → 정확히 1개만 true, 나머지 false. 리더만 task 실행(카운터 1).
  - (b) 해제 후 타 클라이언트 획득: 리더가 unlock(또는 클라이언트 종료) 후 다른 클라이언트가 tryLock(0) → true. 리더 인계.
  - (c) 비대기 즉시 skip: 보유 중 타 클라이언트 tryLock(0)이 대기 없이 즉시 false.
  - (d) finally 가드 해제: 획득 실패 클라이언트는 unlock하지 않음(보유자 락 유지 확인). 이 통합 단언은 결과(보유자 락 유지)를 확인하고, 해제 호출 자체의 정확성은 5.2 단위 테스트가 isHeldByCurrentThread 분기별 unlock 호출 여부/횟수를 직접 단언한다(획득 성공·보유 시 unlock 정확히 1회 / 획득 실패 시 unlock 0회 — 5.2 참조).
- runIfLeader(resource, task) 단위로 검증: 리더는 task 실행·true, 비리더는 task 미실행·false.

### 5.2 단위(Mockito) — SchedulerLeaderGuardUnitTest
- RedissonClient.getLock mock → RLock.tryLock(0, SECONDS) stub.
- leaseTime 미지정 호출 단언: tryLock(0, TimeUnit.SECONDS)(2-인자, leaseTime 없는 오버로드)가 호출됨(고정 lease 미사용 — Task 기술제약 3).
- InterruptedException 주입 → 인터럽트 복원·task 미실행·false.
- 획득 실패(tryLock false) → task 미실행·false·unlock 0회.
- finally 해제(5.1(d)가 참조하는 단위 단언): isHeldByCurrentThread 분기별 unlock 호출 여부/횟수를 직접 단언 — 획득 성공·isHeldByCurrentThread true → unlock 정확히 1회(verify times(1)); 획득 실패 또는 isHeldByCurrentThread false → unlock 0회(verify never()).
- Redis 연결 실패(RedisException 주입) → false + task 미실행(폴백 skip, 4).

### 5.3 단위 — UnpaidOrderExpirySchedulerTest(022 보강)
- guard를 fake/mock로: 리더(runIfLeader가 task 실행) → 기존 위임(expirePendingOrder) 호출. 비리더(task 미실행) → 위임 0회. 스케줄러 위임 로직(022) 회귀 0.

### 5.4 무브로커 컨텍스트 로드 회귀 가드 (C6 보존 — verification-gate §1·§4 핵심)
- Redisson 빈 추가 후에도 브로커 없이 풀컨텍스트 @SpringBootTest가 로드되는지 확인(기존 RefreshTokenStoreWiringTest 등 @SpringBootTest @ActiveProfiles("test") 계열 그린 유지). starter 회피·지연 연결이 실제로 무브로커 로드를 보존하는지 RED→GREEN 실측(testing-rule "RED는 경험으로 확인" — 이론 추론 금지).
- 만약 Redisson 빈 생성이 즉시 연결을 시도해 무브로커 로드가 깨지면, 테스트 프로파일에서 RedissonClient 가드/no-op 대체 보강을 적용하고 그 RED→GREEN을 기록(2.1).
- 컴포넌트 스캔 파급(verification-gate §4): RedissonSchedulerLeaderGuard(@Component, common)·RedissonConfig(RedissonClient 빈)는 새 Repository 의존이 아니므로 @MockSharedRepositories 파급은 없으나, 새 빈이 풀컨텍스트 그래프에 들어오므로 전체 스위트로 영향 확인(메인 에이전트 동적 게이트).

### 5.5 watchdog 페일오버 — 통합/수동 한정 (명시)
- 진짜 node-death watchdog 페일오버(리더 사망 → ~30s 후 lease 만료 → 타 노드 획득)는 타이밍 의존이라 단위로 결정적 단언이 어렵다. 통합/수동 검증으로 한정: docker-compose Redis + 앱 2 인스턴스 기동 → 1 인스턴스만 스케줄 로그, 그 인스턴스 강제 종료 → ~30s 후 다른 인스턴스가 리더 로그. 작업 보고에 확인/미확인 명시(testing-rule §검증 실행).

### 5.6 실행 / 동적 게이트 (verification-gate)
- shop-core/에서 ./gradlew test 전체 그린을 메인 에이전트가 직접 확인(정적 PASS ≠ 빌드 그린). Redisson 빈 추가가 풀컨텍스트 로드를 깨지 않는지 baseline 대조(5.4). 느린 Testcontainers 반복은 타깃 테스트만, 전체는 마지막 1회(MEMORY: Testcontainers RED→GREEN 비용).
- forbidden-rule: 스케줄러는 Repository 직접 호출 0(기존 022대로 reader SPI 경유). 락은 guard 경유 — Redisson 호출이 스케줄러/도메인에 흩뿌려지지 않음(ADR-005 격리).

### Acceptance ↔ 검증 매핑
| Acceptance(Task) | 검증 수단 |
|---|---|
| 동시 tryLock 정확히 1개 획득 | RedissonSchedulerLeaderGuardTest (a) |
| 해제 후 타 클라이언트 획득 | RedissonSchedulerLeaderGuardTest (b) |
| 비대기 skip·finally 가드 해제·leaseTime 미지정(watchdog) | RedissonSchedulerLeaderGuardTest (c)(d)·SchedulerLeaderGuardUnitTest |
| InterruptedException·Redis 연결 실패 skip | SchedulerLeaderGuardUnitTest |
| 스케줄러 게이트(리더만 위임)·022 회귀 0 | UnpaidOrderExpirySchedulerTest |
| starter 미사용·Lettuce 무영향·무브로커 컨텍스트 로드 보존 | build.gradle 확인·무브로커 컨텍스트 로드 가드·전체 스위트 |
| 도메인 행 락 무변경·신규 migration/이벤트 0·ModularityTests 통과 | 문서/스키마 무변경 확인·ModularityTests·전체 테스트 |
| watchdog 페일오버 | 통합/수동(5.5) |
| ADR-005 보류→채택 기록 | docs/adr/005 갱신 확인 |

---

## 6. 트레이드오프

- TTL 분산락(watchdog) vs strict 단일 실행 — 채택: best-effort 리더 게이트. (장) 다중 노드 중복 작업을 대부분 제거, 구현 단순(tryLock(0)+watchdog). (단) overrun·watchdog 갱신 실패·GC pause 시 일시적 2-노드 동시 실행 가능 → strict 단일 실행 불가. 안전한 이유: 정합은 도메인 행 락=멱등이 보장(락 실패해도 중복≠불일치). Task 목적이 "중복 작업 축소"라 best-effort로 충분.
- leaseTime 미지정(watchdog) vs 고정 leaseTime — 채택: watchdog. (장) 작업이 길어져도 lease 자동 갱신으로 실행 중 만료·중복 재오픈을 막음. (단) watchdog 스레드·갱신 트래픽 의존, 리더 사망 시 lease(기본 30s)만큼 페일오버 지연. 고정 lease는 overrun 시 실행 중 만료 = 중복 재오픈이라 금지(Task 기술제약 3).
- plain redisson 별도 빈 vs redisson-spring-boot-starter — 채택: plain 별도 빈. (장) RedisConnectionFactory 무교체 → 기존 Lettuce/StringRedisTemplate·무브로커 컨텍스트 로드(C6) 보존. (단) RedissonClient 빈/Config를 수동 구성, Lettuce·Redisson 두 클라이언트 공존(연결 풀·메모리 약간 증가). 공존 비용 < 기존 자산 보존 가치.
- 공통 guard 격리 vs 스케줄러에 직접 RLock — 채택: 공통 guard(ADR-005 결과 항목). (장) 락 메커니즘 한 곳에 격리, 후속 스케줄러 재사용, 단위 테스트에서 fake 대체 용이. (단) 인터페이스+구현 1쌍 추가. 응집/테스트성 우선.
- Redis 연결 실패 시 skip vs 락 없이 실행 — 채택: skip(이번 주기) + 다음 주기 재시도. (장) 락 인프라 장애 시 다중 노드 동시 실행(중복 증폭)을 막음, 만료는 시간 여유. (단) Redis 장애 동안 만료 처리 지연. 정합 무손상(TTL 여유·멱등)이라 지연 허용.
- 스케줄러 리더 한정 vs 도메인 행 락에도 Redisson — 채택: 스케줄러 한정. (장) 단일 PG가 이미 행 락을 노드 간 직렬화 → 도메인에 Redisson 불필요, 이중 락·데드락 회피. (단) DB 밖 임계구역이 생기면 별도 검토. Task Non-goal 준수.
- DB index 0 공유(Lettuce와 동일) vs 락 전용 분리 — 채택: DB 0 공유. (장) 설정 단순, 락 키는 shopcore:lock: prefix로 keyspace 구분. (단) 동일 인스턴스/DB 공유. prefix 분리로 충돌 없음, 운영 인스턴스 분리는 host 환경변수화로 후속 가능.

---

## 구현 분담

view-implementor 작업 없음 — REST/View 표면 없는 횡단 인프라 + 백그라운드 스케줄러 게이트.

backend-implementor 단독 담당 파일:
- (수정) shop-core/build.gradle — plain org.redisson:redisson 의존 추가(starter 금지, 버전 명시)
- (신규) common/config/RedissonConfig.java — RedissonClient 별도 빈(DB 0, Lettuce 무영향, lazy)
- (신규) common/concurrency/SchedulerLeaderGuard.java + RedissonSchedulerLeaderGuard.java — 공통 락 guard(비대기·watchdog·finally 가드 해제·InterruptedException·연결 실패 skip)
- (수정) payment/service/UnpaidOrderExpiryScheduler.java — expireUnpaidOrders()를 guard로 게이트(위임 로직 doExpireUnpaidOrders로 이동, 동작 불변)
- (수정) common/config/RedisProperties.java(Lock javadoc 정정 — watchdog로 ttl 미사용) + application.yml(shop.redis.lock 주석 정정) — stub 재사용, 신설 0
- (수정) docs/adr/005-database-first-concurrency-redisson-later.md — 보류→채택(스케줄러 리더=Redisson) 갱신 + (검토) docs/architecture.md 참조 1줄
- (신규/보강) 테스트: RedissonSchedulerLeaderGuardTest(Testcontainers Redis + Redisson 2 클라이언트)·SchedulerLeaderGuardUnitTest·UnpaidOrderExpirySchedulerTest(보강)·무브로커 컨텍스트 로드 회귀 가드·구조 테스트
- (재사용·무변경) Lettuce RedisConfig/StringRedisTemplate·RefreshToken/PasswordReset·expirePendingOrder(022)·도메인 행 락·이벤트/토픽·migration

## 완료 조건 체크리스트
- [ ] build.gradle에 plain org.redisson:redisson(버전 명시), redisson-spring-boot-starter 미추가
- [ ] RedissonConfig로 RedissonClient 별도 빈(DB 0), 기존 Lettuce/StringRedisTemplate/RedisAutoConfiguration 무변경
- [ ] SchedulerLeaderGuard(인터페이스) + RedissonSchedulerLeaderGuard(tryLock(0) 비대기·leaseTime 미지정 watchdog·finally+isHeldByCurrentThread 해제·InterruptedException 복원·Redis 실패 skip)
- [ ] UnpaidOrderExpiryScheduler.expireUnpaidOrders()가 guard로 게이트(위임 로직 불변, @ConditionalOnProperty 활성 조건과 정합)
- [ ] RedisProperties.Lock/application.yml lock stub 재사용·주석 정정(watchdog로 ttl 미사용·키 규약 명시), 신설 0
- [ ] Testcontainers Redis + Redisson 2 클라이언트로 (a) 동시 1개 획득 (b) 해제 후 타 클라이언트 획득 (c) 비대기 skip (d) 가드 해제 검증
- [ ] 단위로 InterruptedException·Redis 연결 실패 skip·leaseTime 미지정 호출·스케줄러 게이트 검증
- [ ] 무브로커 풀컨텍스트 로드 보존(C6) RED→GREEN 실측 + ./gradlew test 전체 그린(메인 동적 게이트)
- [ ] watchdog 페일오버는 통합/수동 한정 명시·보고
- [ ] ADR-005 보류→채택(스케줄러 리더=Redisson) 갱신, 도메인 행 락·이벤트/토픽·migration 무변경, ModularityTests 통과

# Plan 064. shop-core 이벤트 발행 회복(2) — 미완료 발행 스케줄 재제출 + 리더 게이트

> 대상 Task: `docs/tasks/backend/064-backend-shop-core-modulith-scheduled-resubmit-incomplete-publications.md`
> 선행 결정: ADR-002(Transactional Outbox with Spring Modulith)의 "회복 자동화" 중 **상시(steady-state) 회복**을 채운다. Task 035(스케줄러 리더 선출·Redisson 분산락) 인프라 재사용.
> 구현 담당: `backend-implementor` (메인 오케스트레이션은 메인 에이전트).
> 화면 변경: **없음** → `view-implementor` 불필요. 도메인 로직·REST·뷰·스키마·이벤트 계약 무변경.
> 전제(상호보완): **Task 063(재기동 회복)은 이미 구현·머지됨**(`application.yml`의 `republish-outstanding-events-on-restart=true` + `OutboxRepublishOnRestartIntegrationTest`). 063=재기동 1회 회복(저비용), 064=상시 주기 회복(스케줄·리더 1노드). 둘 다 ON이 기본이며 대상 집합(INCOMPLETE)·멱등이 동일해 동시 활성 무해.
> 경계(범위 밖): 미완료 건수/재제출 횟수 **메트릭은 Task 065**가 담당한다 — 본 Task에서 Micrometer 카운터/게이지를 추가하면 범위 위반이다(아래 §7·§9에서 065로 명시 위임). **신규 분산락 인프라 금지** — 기존 `SchedulerLeaderGuard` 재사용. `event_publication` 아카이빙/재시도 상한(독성 메시지 격리)도 범위 밖(후속).

---

## 1. 목표

shop-core가 **정상 가동 중 주기적으로(기본 1분 간격)** `event_publication`의 **일정 시간 이상(기본 2분 초과) 미완료(INCOMPLETE, `completion_date IS NULL`)인 발행을 재제출**해 Kafka로 재외부화한다. 재기동을 기다리지 않고 영구 실패한 발행을 상시 회복한다. 다중 노드에서는 **리더 1노드만**(`SchedulerLeaderGuard.runIfLeader`) 실행해 중복 외부화를 축소한다. 선례 스케줄러(`UnpaidOrderExpiryScheduler` + `OrderExpirySchedulingConfig`) 패턴을 그대로 계승하고, **신규 분산락·신규 도메인 모듈을 만들지 않는다.** 풀컨텍스트 `./gradlew test` + ModularityTests/ArchUnit 그린 유지.

핵심은 **스케줄러 빈 1개 + 게이팅 Config 1개 + ConfigurationProperties 1개 + application.yml `shop.events.republish` 블록 + 단위/통합 테스트**다. 재제출 메커니즘 자체는 Modulith가 제공하는 `IncompleteEventPublications.resubmitIncompletePublicationsOlderThan(Duration)`(아래 §3·라이브러리 실측)을 호출하기만 한다.

---

## 2. 변경 대상 파일 (정확 경로/패키지)

배치 패키지 결정: **`common/events`**(신규 서브패키지). 근거 — `event_publication`은 특정 도메인(member/product/order/payment…)에 속하지 않는 **Modulith 인프라**다. `package-structure-rule.md`에서 `common`은 "공통 예외·BaseEntity·공통 설정·횡단 공통 모듈"이며 `common/concurrency`(`SchedulerLeaderGuard`)도 이미 거기 있다. 도메인 스케줄러(`UnpaidOrderExpiryScheduler`)는 자기 도메인(`payment`)에 두지만, 이 재제출은 **횡단 인프라**이므로 `common` 계열이 모듈 경계(ModularityTests/ArchUnit) 위반 없이 적합하다(`platform`은 "Outbox/Kafka **스모크** 검증 — 한시적 검증 모듈"이라 운영 스케줄러 상주처로 부적합). `common/events`는 아직 없으므로 신설하되 `common` 모듈 내부라 새 Modulith 모듈이 생기지 않는다.

- **신규(main) 1개 — 스케줄러**: `shop-core/src/main/java/com/shop/shop/common/events/IncompletePublicationResubmitScheduler.java`
  - `@Scheduled(fixedDelayString)` 진입점 + `leaderGuard.runIfLeader("scheduler:event-republish", this::doResubmit)` 위임. package-private(선례 `UnpaidOrderExpiryScheduler` 동일).
- **신규(main) 1개 — 게이팅 Config**: `shop-core/src/main/java/com/shop/shop/common/events/EventRepublishSchedulingConfig.java`
  - `@Configuration @ConditionalOnProperty(prefix="shop.events.republish", name="enabled", havingValue="true") @EnableConfigurationProperties(EventRepublishProperties.class) @EnableScheduling`(D2 — 064 단독 ON 보장).
- **신규(main) 1개 — Properties**: `shop-core/src/main/java/com/shop/shop/common/events/EventRepublishProperties.java`
  - `@ConfigurationProperties(prefix="shop.events.republish")` record(`enabled`, `interval`, `olderThan`) + compact constructor 기본값(선례 `OrderExpiryProperties` 패턴).
- **수정(main) 1개 — application.yml**: `shop-core/src/main/resources/application.yml`
  - `shop:` 블록에 `events.republish` 추가(§5). 기존 `spring.modulith.events`(38~54행, 063 플래그)는 **무변경**.
- **수정(test) 1개 — 테스트 yml 게이팅**: `shop-core/src/test/resources/application.yml`
  - `shop.events.republish.enabled=false` 추가(테스트 컨텍스트에서 스케줄러 빈 비생성 — `pending-expiry.enabled=false`·`sse.enabled=false` 선례 동일). 064 통합 테스트만 `@TestPropertySource`로 국소 ON.
- **신규(test) 1개 — 단위**: `shop-core/src/test/java/com/shop/shop/common/events/IncompletePublicationResubmitSchedulerTest.java`
  - Mockito. 리더/비리더 위임 + `olderThan` 전달 단언(선례 `UnpaidOrderExpirySchedulerTest` guard-fake 패턴 계승).
- **신규(test) 1개 — 통합**: `shop-core/src/test/java/com/shop/shop/platform/event/OutboxScheduledResubmitIntegrationTest.java`
  - Testcontainers PG + `@EmbeddedKafka`. **063의 `OutboxRepublishOnRestartIntegrationTest` 배선을 그대로 계승**(같은 `platform/event` 패키지·같은 Dummy 픽스처). `older-than` 경계까지 단언(§8).
- **build.gradle 변경: 없음.** 필요한 의존(`spring-modulith-events-api`/`-core` 1.3.1, Redisson, Testcontainers PG, `spring-kafka-test`)은 이미 존재.
- **기존 main 픽스처 재사용(신규 아님)**: `DummyEventPublishService`·`DummyOutboxSmokeEvent`(`platform`). 063과 동일하게 재사용.

---

## 3. 스케줄러 구현 (선례 스니펫 대조)

`UnpaidOrderExpiryScheduler`(진입점이 `leaderGuard.runIfLeader(SCHEDULER_RESOURCE, this::doWork)` 위임 + `doWork` private) 구조를 **그대로** 따른다.

```java
package com.shop.shop.common.events;

import com.shop.shop.common.concurrency.SchedulerLeaderGuard;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.modulith.events.IncompleteEventPublications;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.Duration;

@Slf4j
@Component
@ConditionalOnProperty(prefix = "shop.events.republish", name = "enabled", havingValue = "true")
@RequiredArgsConstructor
class IncompletePublicationResubmitScheduler {

    /** 분산락 리소스 식별자 — 실제 락 키: shopcore:lock:scheduler:event-republish */
    private static final String SCHEDULER_RESOURCE = "scheduler:event-republish";

    private final IncompleteEventPublications incompleteEventPublications; // Modulith 멀티캐스터 빈
    private final EventRepublishProperties properties;
    private final SchedulerLeaderGuard leaderGuard;

    @Scheduled(fixedDelayString = "${shop.events.republish.interval:PT1M}")
    public void resubmitIncomplete() {
        boolean isLeader = leaderGuard.runIfLeader(SCHEDULER_RESOURCE, this::doResubmit);
        if (!isLeader) {
            log.debug("미완료 발행 재제출 스케줄 — 타 노드가 리더 또는 락 장애, 이번 주기 skip. resource={}", SCHEDULER_RESOURCE);
        }
    }

    /** 리더 노드에서만 실행 — older-than 초과 미완료 발행만 재제출(프로듀서 재시도 중인 건 제외). */
    private void doResubmit() {
        Duration olderThan = properties.olderThan();
        log.debug("미완료 발행 재제출 시작: olderThan={}", olderThan);
        incompleteEventPublications.resubmitIncompletePublicationsOlderThan(olderThan);
        log.info("미완료 발행 재제출 트리거 완료: olderThan={}", olderThan);
    }
}
```

대조 포인트(선례와 1:1):
- `@Scheduled(fixedDelayString = "${...interval:PT1M}")` 진입점 + `@ConditionalOnProperty(...enabled, havingValue="true")` — `UnpaidOrderExpiryScheduler` 동일.
- 진입점이 `runIfLeader(SCHEDULER_RESOURCE, this::doResubmit)` 위임, false면 debug 로깅 — 동일.
- `doResubmit`는 package-private 클래스의 private 메서드, `@Transactional` 미부착 — `resubmitIncompletePublicationsOlderThan`은 Modulith가 내부에서 DB 재조회·외부화 재시도를 자체 트랜잭션 경계로 수행하므로 호출부에 트랜잭션을 두지 않는다(선례 `doExpireUnpaidOrders`도 비트랜잭션 루프).
- **빈 주입 확정**: `IncompleteEventPublications`는 `PersistentApplicationEventMulticaster`가 구현해 컨텍스트에 빈으로 노출된다(063 통합 테스트가 `@Autowired IncompleteEventPublications`로 이미 주입·검증 — 실존 확인). 시그니처 `void resubmitIncompletePublicationsOlderThan(Duration)`은 `spring-modulith-events-api-1.3.1` 소스 실측(§4).

---

## 4. 스케줄 활성 게이팅 (OrderExpiry 선례 그대로 + `@EnableScheduling`)

게이팅은 **`@Profile` 미사용**(메모리 선례 `shop-core-tests-no-active-profile-gating` — shop-core 풀 `@SpringBootTest`는 active profile 없이 돌아 `@Profile` 게이트가 오히려 활성화되어 컨텍스트를 깬다). 대신 **`@ConditionalOnProperty`로 빈 등록 자체를 차단**한다(선례 `OrderExpirySchedulingConfig`/`UnpaidOrderExpiryScheduler` 동일).

```java
package com.shop.shop.common.events;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.annotation.EnableScheduling;

@Configuration
@ConditionalOnProperty(prefix = "shop.events.republish", name = "enabled", havingValue = "true")
@EnableConfigurationProperties(EventRepublishProperties.class)
@EnableScheduling
public class EventRepublishSchedulingConfig {
    // 게이팅 + Properties 바인딩 + 스케줄링 활성 전용. @Bean 없음
    // (선례 OrderExpiry는 Clock 빈을 뒀으나 064는 Clock 불필요 — older-than은 publication_date 기준을 Modulith가 내부 계산).
}
```

**`@EnableScheduling` 결정(D2 — 코드 실측 근거)**:
- `OrderExpirySchedulingConfig`가 **코드베이스 최초 `@EnableScheduling` 도입처**(주석 "C10")이나, 그 Config 자체가 `@ConditionalOnProperty(shop.order.pending-expiry.enabled)`로 게이팅된다 → **order pending-expiry가 OFF면 그 Config의 `@EnableScheduling`도 함께 빠진다.**
- 두 스케줄러의 활성 조건은 **독립**(order=`shop.order.pending-expiry.enabled`, republish=`shop.events.republish.enabled`)이다. 따라서 "order OFF + republish ON" 컨텍스트에서 064가 발화하려면 064 Config가 `@EnableScheduling`을 **자체 보유**해야 한다.
- Spring `@EnableScheduling` 다중 선언은 단일 `ScheduledAnnotationBeanPostProcessor`로 수렴(idempotent)하므로 OrderExpiry와 공존해도 무해. → **064 Config가 `@EnableScheduling`을 보유한다(확정).**
- 게이팅 정합: 064 스케줄러 빈은 `@ConditionalOnProperty(shop.events.republish.enabled=true)`로 **빈 등록 자체가 막히면 `@Scheduled` 메서드도 스캔되지 않아 발화 0**. 즉 enabled=false → 064 스케줄러 부재 → 064 발화 0.

테스트 격리: `src/test/resources/application.yml`에 `shop.events.republish.enabled=false`를 추가 → 풀 `@SpringBootTest`에서 064 스케줄러·Config 빈이 생성되지 않아 백그라운드 발화 없음(verification-gate §4). 064 통합 테스트만 `@TestPropertySource`로 국소 ON.

---

## 5. 설정 프로퍼티 (`shop.events.republish`)

```yaml
# application.yml — shop: 블록 내, order/admin 인접에 추가
  # [Task 064] 미완료(INCOMPLETE) 발행 상시 회복 스케줄러 — 주기적으로 일정 시간 이상 미완료인 발행을 재제출.
  #   리더 1노드만 실행(SchedulerLeaderGuard, Task 035). 063(재기동 회복)과 상호보완·동시 ON 무해.
  events:
    republish:
      enabled: ${SHOP_EVENTS_REPUBLISH_ENABLED:true}        # 상시 회복 스케줄러 활성 (테스트는 false로 명시 비활성)
      interval: ${SHOP_EVENTS_REPUBLISH_INTERVAL:PT1M}      # 스케줄 fixed-delay 주기 (기본 1분)
      # older-than: 이 시간 초과로 미완료인 발행만 재제출 대상. 반드시 프로듀서 delivery.timeout.ms(기본 120000ms=2분)보다 커야 한다.
      #   근거: 그보다 짧으면 프로듀서가 아직 자동 재시도 중인(곧 완료될 수 있는) 발행을 스케줄러가 중복 재제출한다.
      #   delivery.timeout.ms 명시 오버라이드 없음 → Kafka 기본 120000ms 적용 확인. 안전 마진 포함 기본 PT2M(=경계), 운영은 PT5M 권장.
      older-than: ${SHOP_EVENTS_REPUBLISH_OLDER_THAN:PT2M}
```

`EventRepublishProperties`(record, 선례 `OrderExpiryProperties` 패턴):

```java
@ConfigurationProperties(prefix = "shop.events.republish")
public record EventRepublishProperties(boolean enabled, Duration interval, Duration olderThan) {
    public EventRepublishProperties {
        if (interval == null)  interval  = Duration.ofMinutes(1);  // PT1M
        if (olderThan == null) olderThan = Duration.ofMinutes(2);  // PT2M — delivery.timeout(120000ms) 경계
    }
}
```

`older-than ≥ delivery.timeout` 근거(코드 실측): `application.yml`의 `spring.kafka.producer`에 `delivery.timeout.ms` **명시 오버라이드 없음** → Kafka 클라이언트 기본 `120000ms`(2분) 적용. 따라서 `older-than` 기본을 `PT2M`(=경계)로 두되, 운영에서 안전 마진을 위해 `PT5M`로 올릴 수 있게 환경변수 노출. **`older-than` 기반(`resubmitIncompletePublicationsOlderThan`)이 063의 predicate 기반(`resubmitIncompletePublications(p->true)`)보다 상시 회복에 적합한 이유**: 상시 스케줄러는 "방금 발행돼 아직 프로듀서가 재시도 중"인 미완료 건을 건드리면 안 된다. 063(재기동 1회)은 기동 시점이라 "재시도 중" 건이 사실상 없어 predicate 전건이 안전했지만, 064(매분 발화)는 발행 직후 윈도우와 겹치므로 **나이(원 발행일 경과) 필터가 필수**다(라이브러리 javadoc: "exceed a certain age regarding their original publication date").

> 환경변수 오버라이드: `SHOP_EVENTS_REPUBLISH_ENABLED`/`_INTERVAL`/`_OLDER_THAN`. 로컬/운영 공통 ON 기본.

---

## 6. 데이터 흐름 (주기 발화 → 리더 게이트 → older-than 미완료 재조회 → 재외부화 → completion)

```
[정상 발행]  도메인 변경 + publishEvent(...) ── 같은 @Transactional ──┐ 커밋
  → Modulith Registry가 event_publication INCOMPLETE 저장              │
  → 커밋 후 DelegatingEventExternalizer → KafkaTemplate 외부화 성공      │
  → completion_date 기록 (완료)  ──────────────────────────────────────┘

[장기 다운으로 영구 실패]
  → 외부화 시도, Kafka가 delivery.timeout(120000ms) 초과 다운 → 프로듀서 전송 영구 실패
  → completion_date 미기록 → event_publication 에 INCOMPLETE 잔존 (유실 없음)

[Task 064 — 상시 주기 회복]
  → @Scheduled(fixedDelay=interval, 기본 1분) 발화
  → leaderGuard.runIfLeader("scheduler:event-republish", doResubmit)
       ├─ 리더 획득 실패(타 노드 리더/락 장애) → 즉시 skip(이번 주기 no-op, debug 로그)
       └─ 리더 획득 → doResubmit:
            → IncompleteEventPublications.resubmitIncompletePublicationsOlderThan(olderThan=PT2M)
            → Modulith가 DB에서 "publication_date < now - olderThan AND completion_date IS NULL" 재조회
              (older-than 미달 건 = 프로듀서 재시도 중일 수 있는 건은 제외)
            → 대상 발행의 외부화 리스너 재호출 → DelegatingEventExternalizer 재외부화 → Kafka 재도착
            → 성공 시 completion_date 기록 (회복 완료)
```

---

## 7. 예외 처리 / 멱등

- **at-least-once → 컨슈머 멱등**: 재제출은 중복 전달을 유발할 수 있다(063과 동일). 새 멱등 위반을 만들지 않음 — 시스템이 이미 멱등 컨슈머 보유:
  - shop-core indexer: `ProductSearchIndexChangedEvent`를 `eventId` 멱등 키 + ES external version으로 upsert → 중복·순서 역전 흡수.
  - notification: idempotency + retry/DLQ(Task 005).
- **리더 게이트 = 다중 노드 중복 외부화 축소**: `runIfLeader`로 리더 1노드만 재제출. best-effort(strict 단일 보장 아님 — `SchedulerLeaderGuard` javadoc). 비리더는 즉시 skip. **락 인프라(Redis) 장애 시 false 반환 → skip 폴백**(락 장애가 흐름을 막지 않게 — 선례 동일). 락 장애로 어느 노드도 리더가 못 되면 그 주기는 회복이 지연될 뿐, 다음 주기에 재시도(at-least-once 보존).
- **재제출 실패 처리**: 재외부화가 또 실패하면 해당 건은 다시 INCOMPLETE로 남아 **다음 주기에 재시도**(유실 없음).
- **독성 메시지(poison) 주의**: 외부화가 구조적으로 계속 실패하는 발행은 매 주기 재시도되어 잡음·부하가 될 수 있다. 재시도 상한/격리는 **본 Task 범위 밖(후속)**. **가시화(미완료 건수·재제출 메트릭)는 Task 065** — 본 Task에서 Micrometer 카운터/게이지를 추가하지 않는다(범위 분리).
- **이벤트 계약 무변경**(`event-contract-rule.md`): 토픽·페이로드·`@Externalized` 미수정. `docs/event-catalog.md` 갱신 불필요.
- **API 인가**: 신규 엔드포인트·외부 트리거 없음 → SecurityConfig·인가 표면 무변경(api-authorization-rule 해당 없음).

---

## 8. 검증 / 테스트 (선례 배선 계승)

> 타깃 테스트만 먼저 RED→GREEN 반복(Testcontainers 비용 절감 — 메모리 선례), 풀 `./gradlew test`(~19분)는 마지막 1회.

### 8.1 단위 (Mockito) — `IncompletePublicationResubmitSchedulerTest`

`UnpaidOrderExpirySchedulerTest`의 **guard-fake 패턴 그대로 계승**(`leaderGuardFake`=task 실행+true, `nonLeaderGuardFake`=미실행+false). `IncompleteEventPublications`는 `@Mock`.

- **(a) 리더**: `resubmitIncomplete()` 호출 시 `incompleteEventPublications.resubmitIncompletePublicationsOlderThan(properties.olderThan())` **정확히 1회** 호출(`verify(...).resubmitIncompletePublicationsOlderThan(eq(olderThan))`).
- **(b) 비리더**: `verifyNoInteractions(incompleteEventPublications)`(skip).
- **(c) 락 장애**: guard-fake가 false 반환(=Redis 장애 시뮬레이트) → 위임 0회.
- **(d) 프로퍼티 바인딩**: `EventRepublishProperties(true, PT1M, PT5M)` 주입 시 `olderThan=PT5M`가 그대로 전달됨(compact constructor 기본값 폴백 — null 입력 시 PT2M).

### 8.2 통합 (Testcontainers PG + EmbeddedKafka) — `OutboxScheduledResubmitIntegrationTest`

**063의 `OutboxRepublishOnRestartIntegrationTest` 배선을 그대로 계승**: `@SpringBootTest` + `@AutoConfigureTestDatabase(NONE)` + `@Testcontainers`(`PostgreSQLContainer("postgres:16.4-alpine")` + `@ServiceConnection`) + `@EmbeddedKafka(topics=DummyOutboxSmokeEvent.TOPIC)` + `@TestPropertySource` 국소 리셋(`autoconfigure.exclude=`, `externalization.enabled=true`, `bootstrap-servers=${spring.embedded.kafka.brokers}`, `ByteArraySerializer`, `flyway.enabled=true`, `ddl-auto=validate`). 주입: `DummyEventPublishService`, `IncompleteEventPublications`, `JdbcTemplate`, `EmbeddedKafkaBroker` + raw String 컨슈머. 비-`@Transactional`(시드 UPDATE 자동커밋 → resubmit가 DB 재조회로 봐야 함 — 063 §7.3 인과 계승).

**리더 가드 처리(선례 대조 결정)**: 통합 테스트는 **`incompleteEventPublications.resubmitIncompletePublicationsOlderThan(olderThan)`를 직접 호출**해 재제출 결과를 검증한다(063이 `resubmitIncompletePublications(p->true)`를 직접 호출한 것과 동형). 즉 리더 가드(`runIfLeader`)·`@Scheduled` 발화는 **단위 테스트(§8.1)에서 위임을 단언**하고, 통합은 "재제출 → Kafka 재도착 + completion + older-than 경계"의 실제 동작을 단언한다. 이유: (i) `SchedulerLeaderGuard`는 Redisson 분산락이라 통합 컨텍스트에서 단일 노드 리더 획득이 환경(EmbeddedKafka+PG, Redis 미기동) 의존이라 flaky, (ii) 063·`UnpaidOrderExpiry` 통합 선례 모두 스케줄링/락 발화를 통합에서 구동하지 않고 **로직 경로를 직접 호출**해 결정성을 확보. → `runIfLeader`의 게이트는 단위로, 재제출 효과는 통합으로 분리(testing-rule 충족 + over-engineering 회피).

시드·단언(063 §7.3 idiom 계승 + **older-than 경계 추가**):
1. **older-than 초과 미완료 시드**: `DummyEventPublishService.publish("aged-incomplete")` → 완료 대기 → PK 캡처 → `UPDATE event_publication SET completion_date=NULL, publication_date = now() - interval '10 minutes' WHERE id=?::uuid`(자동커밋). **`publication_date`를 older-than(PT2M) 이전으로 과거화**해 재제출 대상으로 만든다.
2. **older-than 미달 미완료 시드(경계 가드)**: 별도 발행 → 완료 → PK 캡처 → `UPDATE ... SET completion_date=NULL WHERE id=?`(`publication_date`는 현재 그대로 = 경과 미달). 이 건은 **재제출 대상이 아니어야** 한다.
3. **완료분 불변 가드**: 또 다른 발행은 완료 상태(completion_date 채워짐) 그대로 둔다.
4. 컨슈머 버퍼 비움 → **`resubmitIncompletePublicationsOlderThan(Duration.ofMinutes(2))` 직접 호출**.
5. 단언:
   - **(a) 경과 초과 건 재도착**: Kafka에 1단계 `eventId` 재도착(Awaitility + wire 파싱 — 063 idiom).
   - **(b) completion 기록**: 1단계 PK의 `completion_date IS NOT NULL`.
   - **(c) older-than 미달 건 미대상**: 2단계 `eventId`는 Kafka 재도착 0건 + 2단계 PK `completion_date`는 여전히 NULL(경계 단언 — 064 고유).
   - **(d) 완료분 불변**: 3단계 `eventId` 재도착 0건.

### 8.3 게이트

- 단위·통합 타깃 RED→GREEN 반복 후 **풀컨텍스트 `./gradlew test` + ModularityTests/ArchUnit 그린**(verification-gate-rule §2, 메인 최종 동적 게이트). 064 스케줄러가 `common/events`에 들어가 모듈 경계·컨텍스트를 깨지 않음 확인.
- 회귀: 정상 발행 흐름 불변. `shop.events.republish.enabled=false`(테스트 yml) 시 064 스케줄러 빈 비생성·발화 0.

---

## 9. 트레이드오프

- **상시 회복(064) vs 재기동 회복(063)**: 063은 기동 1회 훅(신규 빈 0)이라 최저 비용이나 "장기 다운 중 재기동이 없으면" 회복 지연. 064는 매분 발화로 상시 회복하지만 스케줄러 빈·리더 가드·older-than 튜닝 비용이 든다. 상호보완 — 둘 다 ON 기본(멱등이라 무해, 대상 동일 INCOMPLETE).
- **`older-than` 값**: 작을수록 회복 빠르나 프로듀서 재시도 중 건 중복 재제출 위험. 클수록 안전하나 회복 지연. 기본 `PT2M`(=delivery.timeout 경계), 운영 `PT5M` 권장(마진).
- **독성 메시지**: 구조적 영구 실패 건은 매 주기 재시도되어 부하·잡음. 재시도 상한/격리는 범위 밖, 가시화는 065.
- **리더 가드 비용 vs 중복 외부화**: 다중 노드에서 매분 리더 락(Redisson) 경합 비용 발생. 그러나 컨슈머 멱등이 있어도 리더 1노드 제한이 중복 외부화·부하를 크게 줄여 가치 있음. 락 장애 시 skip 폴백으로 안전.
- **테스트 깊이**: 리더 가드 발화를 통합에서 실제 구동(고비용·flaky) vs 단위에서 위임 단언 + 통합에서 재제출 효과 직접 구동(결정적). 후자 채택(§8.2).

---

## 10. plan 확정 결정 (구현 전 고정)

- **D1 — 배치 패키지/리소스 키**: 스케줄러·Config·Properties를 **`common/events`**(신규 서브패키지, `common` 모듈 내부)에 둔다. 리소스 키 `"scheduler:event-republish"`(실제 락 키 `shopcore:lock:scheduler:event-republish`). 모듈 경계 위반 없음(ModularityTests로 검증).
- **D2 — `@EnableScheduling`**: 064 `EventRepublishSchedulingConfig`에 **`@EnableScheduling`을 자체 보유**한다(order pending-expiry가 OFF인데 republish만 ON인 컨텍스트에서도 발화 보장). Spring `@EnableScheduling` 다중 선언은 단일 BPP로 수렴(idempotent) — OrderExpiry와 공존 무해.
- **D3 — 게이팅**: `@ConditionalOnProperty(shop.events.republish.enabled=true)`(스케줄러+Config 둘 다). `@Profile` 미사용(메모리 선례). 테스트 yml에 `enabled=false` 추가.
- **D4 — API 선택**: `IncompleteEventPublications.resubmitIncompletePublicationsOlderThan(Duration)`(시그니처 `void`, `spring-modulith-events-api-1.3.1` 소스 실측 — §4). predicate 기반(063) 대신 older-than 기반(상시 회복은 재시도 중 건 제외 필수).
- **D5 — 설정값**: `interval` 기본 `PT1M`, `older-than` 기본 `PT2M`(delivery.timeout 120000ms 경계 — `delivery.timeout.ms` 명시 오버라이드 없음 실측), `enabled` 기본 ON. 환경변수 노출.
- **D6 — 메트릭**: **본 Task에서 메트릭 추가 안 함 → Task 065로 위임**(미완료 건수/재제출 횟수 가시화). 범위 분리.
- **D7 — 063 동시 활성**: 둘 다 ON 기본(재기동+상시 이중 안전, 멱등 무해).
- **D8 — 테스트**: 단위(guard-fake로 리더/비리더/락장애 위임 + olderThan 전달) + 통합(063 배선 계승, older-than 초과/미달/완료분 3분기 경계 단언, resubmit 직접 호출로 리더가드 우회).

---

## 11. 리뷰 관점 (reviewer 체크리스트)

- **범위 준수**: 신규는 스케줄러+게이팅 Config+Properties+yml+테스트뿐인가. **메트릭(Micrometer)·신규 분산락·아카이빙·재시도 상한이 없는가**(있으면 065/후속 범위 침범 → FAIL). 기존 `SchedulerLeaderGuard` 재사용(신규 락 인프라 0).
- **선례 패턴 계승**: 스케줄러가 `UnpaidOrderExpiryScheduler` 구조(진입점 `runIfLeader(resource, this::doResubmit)` 위임 + private doResubmit + `@ConditionalOnProperty` + `@Scheduled(fixedDelayString)`)를 따랐는가. 게이팅이 `OrderExpirySchedulingConfig` 형태(`@ConditionalOnProperty`+`@EnableConfigurationProperties`)인가. `@Profile` 미사용인가(메모리 선례).
- **API 정확성**: `resubmitIncompletePublicationsOlderThan(Duration)` 호출인가(`-OlderThan` — predicate 오버로드 아님). 반환 void. `IncompleteEventPublications` 빈 주입.
- **older-than ≥ delivery.timeout 근거**: 기본 `older-than`(PT2M)이 프로듀서 `delivery.timeout.ms`(120000ms, 기본 — 오버라이드 없음) 이상인가. yml 주석에 근거 명문화됐는가.
- **패키지/모듈 경계**: `common/events` 배치가 ModularityTests/ArchUnit를 깨지 않는가. `common` 내부라 새 Modulith 도메인 모듈이 생기지 않는가.
- **게이팅 격리**: `src/test/resources/application.yml`에 `shop.events.republish.enabled=false` 추가로 풀 `@SpringBootTest`에서 스케줄러 발화 0인가. 064 Config의 `@EnableScheduling`이 OrderExpiry와 공존해 풀컨텍스트를 깨지 않는가.
- **테스트 충실도**: 단위가 리더/비리더/락장애 위임 + olderThan 전달을 단언하는가. 통합이 (a)초과 재도착·(b)completion·**(c)older-than 미달 미대상**·(d)완료분 불변 4분기를 단언하는가. 063 배선(`@TestPropertySource` 국소 리셋, 비-`@Transactional`, Dummy 픽스처 재사용)을 따랐는가. 새 컨텍스트 전략을 발명하지 않았는가.
- **계약/도메인 불변**: `@Externalized` 토픽·페이로드·`docs/event-catalog.md` 무변경. REST/뷰/스키마/SecurityConfig 무변경. `spring.modulith.events`(063 블록) 무변경.

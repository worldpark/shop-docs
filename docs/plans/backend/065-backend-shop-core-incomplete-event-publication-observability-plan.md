# Plan 065. shop-core 미완료 발행 관측 — Micrometer 게이지

> 대상 Task: `docs/tasks/backend/065-backend-shop-core-incomplete-event-publication-observability.md`
> 구현 담당: `backend-implementor` (메인 오케스트레이션은 메인 에이전트)
> 화면/REST/뷰/스키마/이벤트 계약/인가 **무변경** — Micrometer 메트릭 1개(+선택 1개) 추가만.
> 전제: Task 036(Actuator+Micrometer Prometheus, `/actuator/prometheus` 노출·공통 태그 `application=shop-core`) 머지됨. Task 063(재기동 재발행)·064(스케줄 재제출, `common/events`) 머지됨. 본 Task는 그 회복들의 "측정 축"으로, INCOMPLETE 적체를 게이지로 노출한다.

## 1. 목표

shop-core가 **현재 미완료(INCOMPLETE, `completion_date IS NULL`) 이벤트 발행 건수**를 Micrometer 게이지로 기존 `/actuator/prometheus`에 노출한다. 이를 통해 회복 메커니즘(063·064)이 적체를 비우는지, 독성 메시지가 무한 적체되는지를 그래프·알람 토대로 관측한다. 도메인/REST/뷰/스키마/이벤트 계약 무변경, 풀컨텍스트 `./gradlew test` 그린 유지.

## 2. 변경 대상 파일

- **신규** `shop-core/src/main/java/com/shop/shop/common/events/IncompleteEventPublicationMetrics.java`
  - 계측 빈. `common/events` 배치(064 스케줄러·`EventRepublishProperties`와 인접 — 같은 "이벤트 발행 회복" 관심사). `common`은 OPEN 모듈(`common/package-info.java` 확인)이라 Modulith SPI 빈 주입에 모듈 경계 위반 없음. §4 패키지 결정 참조.
- **신규(테스트)** `shop-core/src/test/java/com/shop/shop/platform/event/IncompleteEventPublicationMetricsIntegrationTest.java`
  - 063/064 통합 테스트(`platform/event`, `OutboxScheduledResubmitIntegrationTest`)의 시드·배선 패턴 계승. §8 참조.
- **main `application.yml` 변경: `shop.events.metrics.enabled` 키 1줄 추가 필요.** 메트릭 빈을 064 스케줄러와 동일하게 `havingValue="true"`(matchIfMissing 없음)로 게이팅하므로(§4), 운영에서 빈을 켜려면 명시 키가 있어야 한다. `shop:` 블록의 064 `shop.events.republish` 인접에 `shop.events.metrics.enabled: ${SHOP_EVENTS_METRICS_ENABLED:true}` 1줄(+간단 주석)을 추가한다. **테스트 yml(`src/test/resources/application.yml`)에는 이 키를 넣지 않는다 → 풀컨텍스트 테스트에서 빈 미생성**(§4·§8 게이팅 회피 메커니즘). 노출·management 관련은 무변경: `management.endpoints.web.exposure.include`에 이미 `prometheus` 포함(L222), `metrics.tags.application: shop-core` 공통 태그 존재(L233), `MeterRegistry`·`/actuator/prometheus` 노출은 036에서 완료. 게이지는 `MeterRegistry`에 등록되는 즉시 자동 노출된다. **노출 목록·`management` 블록·SecurityConfig·build.gradle 무변경.**

## 3. 미완료 건수 산출 — 확정 방법 (jar·소스로 검증)

후보 3종을 `spring-modulith-events-core/jpa:1.3.1` 소스로 대조한 결과:

| 후보 | 검증 결과 | 채택 |
|---|---|---|
| (a) `IncompleteEventPublications` 빈 | `resubmitIncompletePublications(Predicate)` / `resubmitIncompletePublicationsOlderThan(Duration)` **2개뿐 — count/조회 메서드 없음**(소스 직접 확인). 064가 쓰는 그 인터페이스. | ❌ |
| (b) `EventPublicationRepository`(SPI 빈) `findIncompletePublications()` | `List<TargetEventPublication>` 반환 — `.size()` 가능. 단 **모든 미완료 행의 `serialized_event`를 역직렬화**(JpaEventPublicationRepository L247~, `@Transactional(readOnly=true)`)해 무겁다. `JpaEventPublicationRepository`는 `@Repository` 빈(SPI `EventPublicationRepository`로 주입 가능). **native count 메서드 없음.** | △(경량성 미흡) |
| **(c) `JdbcTemplate` `SELECT count(*) FROM event_publication WHERE completion_date IS NULL`** | 프로젝트는 `spring-modulith-starter-jpa` 사용(테이블 `event_publication`, 컬럼 `completion_date` — V1 마이그레이션·063/064 테스트로 확정). 역직렬화 없이 DB가 카운트만 반환 — **가장 경량·단순.** `JdbcTemplate`은 기존 빈(063/064 테스트에서 주입 사용). | ✅ **채택** |

**확정: (c) JdbcTemplate count 쿼리.** 근거 — 미완료 건수만 필요한데 (b)는 전 행 페이로드를 역직렬화(스크레이프마다 적체 행 수만큼 deserialization)해 게이지 평가 비용이 적체에 비례 악화된다. (c)는 DB 단의 `count(*)`로 페이로드를 만지지 않아 PII·`serialized_event` 노출 위험도 원천 차단(§7). 쿼리 결과는 스칼라 `long` 1개.

> **CompletionMode 확정**: application.yml에 `spring.modulith.events.completion-mode` 미설정 → 기본 `UPDATE` 모드(완료 행은 `completion_date` 채워 보존, 삭제·아카이브 안 함, JpaEventPublicationRepository 확인). 따라서 `completion_date IS NULL` 필터가 정확히 미완료만 집계한다(완료 행은 NOT NULL로 제외). 모드를 바꾸지 않는다(범위 밖).

## 4. 게이지 등록 — Micrometer 패턴 (선례 계승)

선례: `product/search/EsProductSearchAdapter`가 `MeterRegistry` 주입 + `Timer/Counter.builder(...).register(meterRegistry)` 사용(per-meter 재태깅 없이 yml 공통 태그 `application=shop-core` 상속). 본 게이지도 동일 컨벤션을 따른다.

**평가 방식: lazy 콜백(스크레이프 시 평가).** `Gauge.builder(name, stateObj, valueFn)`는 Prometheus 스크레이프 시점에 `valueFn`을 호출한다 — 주기 캐시 스레드 불필요(추가 스케줄러·캐시 무효화 로직 없음 = 단순·결합 최소). count 쿼리는 인덱스 미스에도 통상 소량 테이블이라 충분히 가볍다(§7·§9 트레이드오프).

```java
package com.shop.shop.common.events;

import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/**
 * 미완료 이벤트 발행 관측 메트릭 (Task 065).
 *
 * <p>{@code event_publication}의 미완료(completion_date IS NULL) 건수를 Micrometer 게이지로 노출한다.
 * 063(재기동 회복)·064(스케줄 재제출)가 적체를 비우는지, 독성 메시지가 무한 적체되는지의 측정 축.
 *
 * <p>평가는 lazy — Prometheus 스크레이프 시점에 count 쿼리를 1회 실행한다(주기 캐시 없음).
 * 공통 태그 application=shop-core는 management.metrics.tags(application.yml)에서 전역 상속.
 *
 * <p>게이팅: 메모리(shop-core-tests-no-active-profile-gating)에 따라 @Profile 금지.
 * @ConditionalOnProperty(havingValue="true")로 운영 yml에서 명시 ON, 키 미설정 테스트
 * 컨텍스트에선 빈 미생성(064 IncompletePublicationResubmitScheduler와 동일 대칭).
 */
@Slf4j
@Component
@ConditionalOnProperty(prefix = "shop.events.metrics", name = "enabled",
        havingValue = "true")
public class IncompleteEventPublicationMetrics {

    /** 미완료 발행 건수 게이지 명 (Micrometer dot 표기 → prometheus는 shop_events_publication_incomplete). */
    static final String GAUGE_INCOMPLETE = "shop.events.publication.incomplete";

    private static final String COUNT_INCOMPLETE_SQL =
            "SELECT count(*) FROM event_publication WHERE completion_date IS NULL";

    private final JdbcTemplate jdbcTemplate;

    public IncompleteEventPublicationMetrics(JdbcTemplate jdbcTemplate, MeterRegistry registry) {
        this.jdbcTemplate = jdbcTemplate;
        Gauge.builder(GAUGE_INCOMPLETE, this, IncompleteEventPublicationMetrics::incompleteCount)
                .description("Number of incomplete (completion_date IS NULL) event publications in the outbox")
                .baseUnit("publications")
                .register(registry);
    }

    /** 스크레이프 시점 호출 — 미완료 건수. 쿼리 실패 시 -1(게이지가 앱을 죽이지 않게, §7). */
    double incompleteCount() {
        try {
            Long n = jdbcTemplate.queryForObject(COUNT_INCOMPLETE_SQL, Long.class);
            return n == null ? 0d : n.doubleValue();
        } catch (Exception e) {
            log.warn("[EventMetrics] incomplete publication count 조회 실패 — 게이지 -1 보고. reason={}",
                    e.getClass().getSimpleName());
            return -1d;
        }
    }
}
```

- **메트릭 명/단위/태그 확정**: `shop.events.publication.incomplete`(prometheus 노출명 `shop_events_publication_incomplete`), baseUnit `publications`, 태그는 전역 `application=shop-core`만(per-meter 추가 태그 없음 — 노드 식별은 Prometheus가 `instance` 라벨로 부여, §9 다중 노드 해석).
- **게이팅**: 메모리 `shop-core-tests-no-active-profile-gating` 준수 — `@Profile` 금지. `@ConditionalOnProperty(prefix="shop.events.metrics", name="enabled", havingValue="true")` — **`matchIfMissing` 없음**(064 `IncompletePublicationResubmitScheduler`와 정확히 동일 대칭). 운영 main `application.yml`에 `shop.events.metrics.enabled: ${SHOP_EVENTS_METRICS_ENABLED:true}` 키를 명시해 ON(§2), **키 미설정 테스트 컨텍스트(`src/test/resources/application.yml`)에선 빈 미생성**. 이로써 JdbcTemplate 의존이 DB-less 풀컨텍스트 테스트에서 평가되지 않아 `UnsatisfiedDependency`가 발생하지 않는다(§8). 통합 테스트는 `shop.events.metrics.enabled=true`를 명시해 빈을 켠다.
- **strong reference 주의**: `Gauge.builder(name, this, fn)`는 state 객체(this)를 weak ref로 잡는다. 빈은 컨테이너가 강참조를 유지하므로 GC로 게이지가 NaN화되지 않는다(스프링 빈 등록 표준 안전).

## 5. 노출 / 인가 (무변경)

- 게이지는 `MeterRegistry` 등록 즉시 `/actuator/prometheus`에 자동 포함. **엔드포인트 노출 목록(`health,info,prometheus`)·`management` 설정·SecurityConfig(036의 `@Order(0)` actuator 체인) 전부 무변경.** (단, main `application.yml`의 `shop:` 블록에 게이팅용 `shop.events.metrics.enabled` 1줄 추가는 불가피 — §2. management/노출/SecurityConfig는 그대로다.)
- 인가: 신규 비즈니스 API 없음. api-authorization-rule(민감정보 비노출) 충족 — 노출값은 **미완료 건수 스칼라 1개뿐**, `serialized_event`/페이로드/PII는 count 쿼리가 애초에 읽지 않는다(§3에서 (b) 대신 (c)를 택한 추가 근거).

## 6. 데이터 흐름

```
Prometheus 스크레이프 → GET /actuator/prometheus (036 actuator 체인, permitAll)
  → Micrometer registry가 등록된 게이지 평가
    → IncompleteEventPublicationMetrics.incompleteCount() (lazy 콜백)
      → JdbcTemplate: SELECT count(*) FROM event_publication WHERE completion_date IS NULL
      → long → double
  → shop_events_publication_incomplete{application="shop-core",instance=...} <N> 텍스트 노출
```
063/064가 미완료를 재제출·완료 처리하면 `completion_date`가 채워져 다음 스크레이프에서 게이지가 자동 감소(별도 갱신 로직 불필요).

## 7. 예외 / 안전

- **쿼리 실패 시 게이지 영향**: `incompleteCount()`가 예외를 흡수하고 `-1` 반환(로그 warn 1줄). DB 일시 장애가 스크레이프(=actuator) 응답을 500으로 만들거나 앱을 죽이지 않게 한다. `-1`은 "측정 불가" 센티넬 — 정상 0 이상과 구분되어 알람에서 식별 가능.
- **평가 비용**: lazy 콜백이라 스크레이프 빈도(보통 15~60s)만큼만 count 쿼리 발생. `event_publication`은 통상 소량(미완료 + UPDATE 모드 보존 완료 행). **인덱스 부재**(V1 마이그레이션 확인: PK(`id`)만, `completion_date` 인덱스 없음)로 seq scan이나, 테이블 규모상 무시 가능. 캐시 도입은 과설계(§9). 인덱스 추가는 스키마 변경이라 범위 밖(§9 보류 근거).
- **PII 비노출**: count 쿼리는 페이로드 컬럼을 SELECT하지 않음 → 본질적으로 PII·페이로드 누출 경로 없음.
- **트랜잭션**: 단순 read count로 별도 `@Transactional` 불필요(JdbcTemplate 자동커밋 read).

## 8. 검증 / 테스트

**통합 테스트(Testcontainers PostgreSQL + EmbeddedKafka)** — `OutboxScheduledResubmitIntegrationTest`(064)의 시드·배선을 그대로 계승:

- 배선: `@SpringBootTest` + `@AutoConfigureTestDatabase(replace=NONE)` + `@Testcontainers`(postgres:16.4-alpine `@ServiceConnection`) + `@EmbeddedKafka` + `@TestPropertySource`(`flyway.enabled=true`, `ddl-auto=validate`, `shop.order.pending-expiry.enabled=false`, `shop.events.republish.enabled=false`로 스케줄러 잡음 차단, **`shop.events.metrics.enabled=true`로 게이지 빈 ON**). 이 `@TestPropertySource`의 `shop.events.metrics.enabled=true`가 본 통합 테스트에서만 메트릭 빈을 켜는 유일한 지점이며, 이로써 JdbcTemplate(Testcontainers 실DB)가 실재해 게이지 빈 생성자가 충족된다.
- 주입: `DummyEventPublishService`, `JdbcTemplate`, **`MeterRegistry`**(게이지 직접 조회).
- 시드(064 패턴): `dummyEventPublishService.publish(...)` → Awaitility로 `completion_date` 채워질 때까지 대기 → PK 캡처 → `UPDATE event_publication SET completion_date = NULL WHERE id = ?::uuid`(자동커밋, 비-`@Transactional`)로 N건을 미완료로 강제.
- 단언:
  - (a) 미완료 N건 시드 후 `registry.get("shop.events.publication.incomplete").gauge().value()` == N. (게이지 lazy 평가이므로 시드 커밋 후 조회.)
  - (b) `IncompleteEventPublications.resubmitIncompletePublicationsOlderThan(...)` 또는 직접 `UPDATE ... SET completion_date = now()`로 완료 처리 후 게이지 == 0.
  - (옵션) `/actuator/prometheus` 텍스트에 `shop_events_publication_incomplete` 라인 존재(MockMvc/스크레이프) — registry 직접 조회로 충분하면 생략 가능(과설계 경계).
- **풀컨텍스트 `./gradlew test` 그린**(메인 최종 동적 게이트): 게이지 빈 추가가 기존 컨텍스트·036 표준 메트릭 노출을 깨지 않음. **회피 메커니즘**: 메트릭 빈은 `@ConditionalOnProperty(havingValue="true")`(matchIfMissing 없음, §4)이고 테스트 yml(`src/test/resources/application.yml`)에 `shop.events.metrics.enabled` 키를 두지 않으므로, **DB-less 풀컨텍스트 `@SpringBootTest`에서 메트릭 빈 자체가 생성되지 않아 JdbcTemplate 의존이 평가되지 않는다.** 따라서 DataSource/JPA autoconfigure를 제외한 테스트 컨텍스트(JdbcTemplate 빈 부재)에서도 `UnsatisfiedDependency`가 발생하지 않는다 — 064 스케줄러가 같은 대칭으로 회피한 것과 동일. `JdbcTemplate`가 실재하는 건 **신규 통합 테스트(Testcontainers + `shop.events.metrics.enabled=true` 명시)뿐**이며, 거기서만 게이지 빈이 켜진다. 메모리(`full-context-test-repo-mock-shared-annotation`) — `@MockSharedRepositories`/`@MockitoBean`은 JPA Repository 타입만 mock하고 JdbcTemplate는 mock하지 않으므로, 빈을 켜는 대신 **게이팅으로 빈 미생성**해야 전수 붕괴를 피한다(신규 mock 전략 발명 금지).
- 회귀: 036 표준 메트릭(`jvm_`/`http_server_requests_`/`hikaricp_`/`kafka_`) 노출 불변, actuator 노출 목록·인가 불변.

## 9. 트레이드오프

- **lazy 콜백 vs 주기 캐시**: lazy 채택. 캐시는 갱신 스레드·무효화·신선도 트레이드오프를 더하나 본 테이블 규모에선 이득 없음(과설계). 적체가 비정상적으로 커져 count가 무거워지는 상황 자체가 알람 신호이므로 lazy로 충분.
- **부가 메트릭 채택/보류 결정**:
  - (a) **가장 오래된 미완료 age 게이지** — **보류.** 추가 가치(노후도)는 있으나 별도 쿼리(`SELECT min(publication_date)` → now-diff)와 게이지 1개가 더 붙어 범위가 넓어진다. task가 "필수=건수 게이지, 부가=선택"으로 명시했고, 적체 노후는 건수 게이지 + Prometheus 측 관측으로 1차 충분. **건수 게이지 안정화 후 후속 Task로 분리**(reviewer over-engineering FAIL 회피).
  - (b) **재제출 횟수 카운터** — **보류.** 채택 시 **064의 `IncompletePublicationResubmitScheduler`(package-private)를 수정**해 `incrementCounter`를 끼워야 한다(머지된 회복 코드에 결합 발생). 게다가 `resubmitIncompletePublicationsOlderThan`은 **반환값이 void**(소스 확인) — 실제 재제출 건수를 알 수 없어 "호출 횟수"만 셀 수 있고, 이는 적체 측정과 가치가 약하다. 결합 비용 > 관측 이득. **본 Task는 064 코드를 건드리지 않는다.**
  - **확정: 필수 게이지 1개만 구현. (a)(b) 모두 보류**(근거 위).
- **인덱스 추가 여부**: 보류. `completion_date` 부분 인덱스가 count를 빠르게 하나 스키마 변경(신규 Flyway 마이그레이션)은 본 Task 범위(메트릭만)를 넘고, 테이블 소량 전제상 불필요. 적체가 상시 대량인 운영 신호가 잡히면 후속에서 재평가.
- **다중 노드 해석**: 게이지는 각 노드가 동일 전역 `event_publication`을 보므로 인스턴스별 동일값을 보고한다. Prometheus에서 **합산(sum)이 아니라 `max`/`avg`로 봐야 한다**(예: `max(shop_events_publication_incomplete) by (application)`). 빈 javadoc·이 plan에 해석 가이드 명시(알람 룰 자체는 비범위).

## 10. plan 확정 결정 (구현 전 고정)

1. 산출 = **JdbcTemplate `count(*) WHERE completion_date IS NULL`**(역직렬화·PII 회피, 최경량). `IncompleteEventPublications`엔 count 없음·`EventPublicationRepository.findIncompletePublications()`는 전 행 역직렬화라 미채택.
2. 평가 = **lazy 게이지 콜백**(주기 캐시 없음).
3. 메트릭 = **`shop.events.publication.incomplete` 게이지 1개만**(unit `publications`, 태그 전역 `application=shop-core`). age 게이지·재제출 카운터 **보류**.
4. 배치 = **`common/events`**(064 인접, 같은 이벤트 회복 관심사; OPEN 모듈이라 SPI/JdbcTemplate 주입 경계 위반 없음).
5. 게이팅 = **`@ConditionalOnProperty(prefix="shop.events.metrics", name="enabled", havingValue="true")`**(`matchIfMissing` 없음 — 064 `IncompletePublicationResubmitScheduler`와 동일 대칭; `@Profile` 금지 — 메모리 준수). **main `application.yml`에 `shop.events.metrics.enabled: ${SHOP_EVENTS_METRICS_ENABLED:true}` 1줄만 추가**(운영 ON, 테스트 yml 미설정 → 빈 미생성). `management`/노출 목록·SecurityConfig·build.gradle **무변경**.
6. 064 의존 = **건드리지 않음**(재제출 카운터 보류).

## 11. 리뷰 관점 (reviewer 체크리스트)

- 미완료 건수 산출이 **JdbcTemplate count**인가(전 행 역직렬화·페이로드 SELECT 없음 → PII/serialized_event 비노출).
- 게이지가 **lazy 콜백**이고 쿼리 실패를 흡수(`-1` 센티넬)해 스크레이프·앱 안정성을 해치지 않는가.
- 메트릭이 **1개(건수 게이지)**로 한정되고 age/카운터 등 **부가 메트릭을 추가하지 않았는가**(과설계 금지). 064 스케줄러 코드 **무변경**인가.
- 게이팅이 **`@ConditionalOnProperty(havingValue="true")` — `matchIfMissing` 없음**(064 스케줄러와 동일 대칭)이고 `@Profile`을 쓰지 않는가(메모리 `shop-core-tests-no-active-profile-gating`). 테스트 yml에 `shop.events.metrics.enabled` 키가 없어 DB-less 풀컨텍스트 테스트에서 빈이 생성되지 않는가(JdbcTemplate 의존 미평가 → `UnsatisfiedDependency` 회피).
- **main `application.yml`에 `shop.events.metrics.enabled` 1줄만 추가**하고 그 외(`management`/노출 목록·SecurityConfig)·build.gradle·스키마·이벤트 계약·도메인/REST/뷰는 **무변경**인가(메트릭만 추가).
- 빈 배치가 `common/events`이고 모듈 경계(OPEN common) 위반이 없는가.
- 테스트가 **064 시드 패턴 계승**(publish→완료대기→`completion_date=NULL` UPDATE)으로 N건 게이지 == N, 완료 후 0을 단언하고, 새 mock 전략을 발명하지 않는가.
- 공통 태그 `application=shop-core`가 전역 상속되고 per-meter 중복 태깅이 없는가.

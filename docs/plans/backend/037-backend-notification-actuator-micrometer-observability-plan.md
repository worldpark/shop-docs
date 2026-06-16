# Plan 037. notification 관측성 기반 — Actuator + Micrometer(Prometheus) + CircuitBreaker 메트릭

> 대상 Task: `docs/tasks/backend/037-backend-notification-actuator-micrometer-observability.md`
> 선행 결정: ADR-010(관측성 도입, **r4j 코어 유지** — 스타터 미전환). 레지스트리 = **Prometheus**(사용자 확정).
> 구현 담당: `backend-implementor` (메인 오케스트레이션은 메인 에이전트)

## 1. 목표
Kafka 컨슈머 notification이 Actuator health + Prometheus 메트릭(JVM·Kafka 컨슈머·DataSource)과 **CircuitBreaker 메트릭**을 노출한다. plan 025의 데코레이터·전용 네임스페이스·풀 `test` 오염 가드를 보존한다(스타터 전환 안 함). 풀컨텍스트 테스트 그린 유지.

## 2. 변경 대상 파일
- `notification/build.gradle` — 의존 4개 추가(actuator, micrometer-prometheus, web, resilience4j-micrometer).
- `notification/src/main/resources/application.yml` — `server.port`(8080 충돌 회피) + `management` 섹션.
- `notification/src/main/java/com/shop/notification/common/config/ResilienceConfig.java` — **CB 메트릭 바인더 빈 추가**(같은 config의 기존 가드 계승).
- (테스트) actuator 노출 + CB 메트릭 등록 검증 1개 신규.

## 3. 의존 추가 (build.gradle)
```gradle
// Observability (ADR-010) — Actuator + Micrometer Prometheus.
implementation 'org.springframework.boot:spring-boot-starter-actuator'
implementation 'io.micrometer:micrometer-registry-prometheus'
// Actuator HTTP 노출용 웹 서버(현재 notification엔 web 스타터 없음 — 컨슈머).
implementation 'org.springframework.boot:spring-boot-starter-web'
// resilience4j CB 메트릭 바인더(코어 부속 — 스타터 전환 아님). 버전은 resilience4j-bom(2.3.0) 관리.
implementation 'io.github.resilience4j:resilience4j-micrometer'
```
- web/micrometer/actuator 버전 = Spring Boot BOM, resilience4j-micrometer 버전 = 기존 resilience4j-bom 위임.

## 4. application.yml (포트 + management)
notification은 업무 HTTP API가 없고, 로컬에서 shop-core가 8080을 점유하므로 **별도 포트**를 쓴다.
```yaml
server:
  port: ${NOTIFICATION_PORT:8090}        # shop-core(8080)와 충돌 회피. 업무 API는 없음 — actuator 노출용.

management:
  # 관리 포트 분리가 필요하면 management.server.port 사용(기본: server.port 동거 — 컨슈머라 단순화).
  endpoints:
    web:
      exposure:
        include: ${NOTIFICATION_MGMT_ENDPOINTS:health,info,prometheus}   # 와일드카드 금지
  endpoint:
    health:
      show-details: when_authorized
  metrics:
    tags:
      application: notification           # 036(shop-core)과 구분
  prometheus:
    metrics:
      export:
        enabled: true
```
- **결정**: 전용 관리 포트(`management.server.port`)는 두지 않고 `server.port=8090` 단일 포트에 actuator를 노출한다(notification은 업무 엔드포인트가 없어 분리 실익이 낮음). 운영 격리가 필요하면 후속에 `management.server.port` 추가. notification엔 spring-security가 없어 해당 포트는 기본 open — 운영은 네트워크 격리로 보호(§7 경고).

## 5. CircuitBreaker 메트릭 바인더 (ResilienceConfig)
`ResilienceConfig`는 `@Profile("kafkatest | !test")` + `@ConditionalOnProperty(notification.mail.mode=smtp)`로 가드된다. **바인더를 같은 config 안에 두면** 이 가드를 그대로 계승해 **풀 `test` 프로파일에선 생성되지 않는다**(오염 0). 기존 수동 `circuitBreakerRegistry` 빈을 재사용한다.

```java
// import io.github.resilience4j.micrometer.tagged.TaggedCircuitBreakerMetrics;
// import io.micrometer.core.instrument.MeterRegistry;

/**
 * CircuitBreaker 메트릭 바인더(ADR-010): 수동 Registry를 Micrometer에 노출.
 * resilience4j-spring-boot3 스타터 미사용 — 코어 부속 바인더만 기존 Registry에 물린다.
 * 가드는 ResilienceConfig(@Profile + @ConditionalOnProperty)를 계승 → 풀 test에선 미생성.
 */
@Bean
public TaggedCircuitBreakerMetrics smtpCircuitBreakerMetrics(
        CircuitBreakerRegistry registry, MeterRegistry meterRegistry) {
    TaggedCircuitBreakerMetrics metrics = TaggedCircuitBreakerMetrics.ofCircuitBreakerRegistry(registry);
    metrics.bindTo(meterRegistry);   // resilience4j_circuitbreaker_state/_calls/_failure_rate ... 노출
    return metrics;
}
```
- `MeterRegistry`는 actuator+micrometer 자동설정이 제공(runtime: Prometheus). 바인더가 ResilienceConfig 안에 있으므로 **registry·meterRegistry가 함께 존재하는 컨텍스트(smtp·non-test 또는 kafkatest)에서만** 동작.
- 단위 `ResilientEmailSenderTest`는 레지스트리를 `new`로 직접 조립 → 스프링 바인더와 무관(영향 0). 이 격리가 깨지지 않음을 검증.

## 6. 자동/추가 노출 메트릭
- 자동(코드 0줄): `jvm_*`, `kafka_consumer_*`(lag·records·fetch), `hikaricp_*`, `process_*`.
- 바인더(§5): `resilience4j_circuitbreaker_state`, `_calls`(success/failure/not_permitted), `_failure_rate`, `_buffered_calls`, `_slow_calls`.

## 7. 검증
- 앱 기동(smtp 모드) 후:
  - `GET http://localhost:8090/actuator/health` → **200 UP**.
  - `GET http://localhost:8090/actuator/prometheus` → `jvm_`, `kafka_consumer_`, **`resilience4j_circuitbreaker_`** 노출.
- **CB 메트릭 동작**: 기존 `ResilientEmailSenderTest` 실패주입 패턴을 활용한 통합/슬라이스에서 상태 전이 시 `resilience4j_circuitbreaker_state` 게이지가 갱신되는지 단언(또는 바인더 등록 후 meter 존재 단언).
- **풀컨텍스트 `./gradlew test` 그린** — actuator/web/바인더 도입이 005/023/024 및 CB **단위 테스트 회귀 0**. 특히:
  - 풀 `test` 프로파일: ResilienceConfig+바인더 미생성(가드) → 컨텍스트 오염 없음 확인.
  - `kafkatest` 프로파일 컨텍스트 로드 정상(이 프로파일은 ResilienceConfig 포함 → MeterRegistry 존재 시 바인더 정상).
- web 서버 추가로 메인 컨텍스트가 정상 기동하고 8090에 바인딩되는지(8080 미점유) 확인.

## 8. plan 확정 결정 (구현 전 고정)
1. 레지스트리 = Prometheus(확정), 노출 = `health,info,prometheus`.
2. 포트 = `server.port=8090` 단일(전용 management 포트 미사용). 운영 격리는 후속.
3. CB 바인더 위치 = `ResilienceConfig` 내부(가드 계승) — 신규 ObservabilityConfig로 분리하지 않음(가드 중복 회피).

## 9. 리뷰 관점 (reviewer 체크리스트)
- **r4j 스타터 미도입** 확인: `resilience4j-spring-boot3`·`@CircuitBreaker` AOP·`resilience4j.*` yml 자동바인딩이 **없고**, `resilience4j-micrometer` 바인더만 추가됐는가(ADR-010).
- 바인더가 **기존 `circuitBreakerRegistry` 빈을 재사용**하고 새 레지스트리를 만들지 않는가.
- 바인더가 `ResilienceConfig` 가드(@Profile + @ConditionalOnProperty)를 계승해 **풀 test에서 미생성**인가(오염 0).
- `notification.resilience.smtp.*` 전용 네임스페이스·데코레이터(`ResilientEmailSender`)가 **무변경**인가.
- 포트가 8080과 충돌하지 않고 노출 목록에 와일드카드가 없는가.
- 기존 CB 단위 테스트(`new`로 레지스트리 조립)와 충돌 없는가.
- 도메인 발송/Kafka 컨슈머 계약 무변경.

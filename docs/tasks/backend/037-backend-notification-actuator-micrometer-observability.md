# 037. notification 관측성 기반 — Actuator + Micrometer + CircuitBreaker 메트릭

> 출처: ADR-010(Actuator + Micrometer 관측성 도입, resilience4j 코어 유지). shop-core 쪽은 별 Task(036)로 분리("한 Task = 한 기능", 독립 레포·빌드). 본 Task는 notification 전용이며 **CircuitBreaker 메트릭**이 추가로 들어간다는 점이 036과 다르다.

## 선행 결정 (ADR-010, Accepted) — 재논의 금지
- 두 앱에 `spring-boot-starter-actuator` + Micrometer 도입. TSDB(Grafana/InfluxDB)는 계속 보류.
- **resilience4j는 코어를 유지하고 spring-boot3 자동설정 스타터로 전환하지 않는다.** CB 메트릭은 코어 부속 `resilience4j-micrometer` 바인더를 **기존 수동 `CircuitBreakerRegistry`** 에 물려 익스포트한다. plan 025의 데코레이터(`ResilientEmailSender`)·전용 네임스페이스(`notification.resilience.smtp.*`)·풀 `test` 오염 가드는 그대로 보존한다.
- CB의 Actuator health contributor·yml 자동바인딩은 도입하지 않는다(필요 시 커스텀 `HealthIndicator` 한정).

## 배경
- notification은 **Kafka 컨슈머**다. `build.gradle`에 **`spring-boot-starter-web`이 없다**(data-jpa·kafka·redis·mail·validation·resilience4j-circuitbreaker 코어만). 즉 **내장 웹 서버가 없어** Actuator HTTP 엔드포인트를 그대로는 노출할 수 없다(JMX만 가능).
- CB는 `common/config/ResilienceConfig.java`의 `circuitBreakerRegistry(ResilienceProperties)` 빈 + `smtpCircuitBreaker(registry)` 빈으로 **수동 구성**돼 있고, 상태 전이/ open fail-fast를 **로그로만** 남긴다(plan 025 §6 관측성 범위). 이를 메트릭으로 가시화한다.

## 기술 선택
- **레지스트리: `micrometer-registry-prometheus`**(036과 동일 — pull 스크레이프, TSDB 불필요).
- **웹 서버 도입(핵심 결정)**: Actuator HTTP 노출을 위해 **`spring-boot-starter-web`** 을 추가하고, **`management.server.port`로 전용 관리 포트**(예: 8081)에 endpoint를 분리한다. 근거: notification엔 애플리케이션 HTTP API가 없으므로, 웹 서버는 **오직 health/metrics 노출용**으로 한정하고 메인 포트에 업무 API를 열지 않는다. (대안: WebFlux — 컨슈머에 리액티브 스택 신규 도입은 과함. servlet 채택.)
- 버전: actuator·micrometer·web 모두 Spring Boot BOM 관리(버전 명시 불필요). `resilience4j-micrometer`는 **기존 resilience4j-bom(2.3.0)** 관리.

## Target
notification 빌드 의존성 + `application.yml` management 설정 + `ResilienceConfig`(또는 신규 `ObservabilityConfig`)의 CB 메트릭 바인더. **도메인 발송 로직·CB 데코레이터·Kafka 컨슈머 계약은 변경하지 않는다.**

## Goal
notification이 표준 메트릭(JVM·Kafka 컨슈머 lag/처리·DataSource·메일)과 **CircuitBreaker 메트릭**을 Micrometer/Prometheus로 노출하고, 전용 관리 포트로 health/scrape를 제공한다. 풀컨텍스트 `test`는 그린을 유지한다(자동설정·바인더가 기존 CB 테스트·컨텍스트를 오염시키지 않음).

## 범위 (Scope)
- **의존 추가**: `spring-boot-starter-actuator`, `micrometer-registry-prometheus`, `spring-boot-starter-web`(관리 포트 노출용), `io.github.resilience4j:resilience4j-micrometer`(버전 BOM 위임).
- **`application.yml` management 설정**:
  - `management.server.port`: 전용 관리 포트(예: `${NOTIFICATION_MANAGEMENT_PORT:8081}`). 메인 서버 포트와 분리.
  - `management.endpoints.web.exposure.include`: `health`, `info`, `prometheus`(필요 시 `metrics`). 와일드카드 금지.
  - `management.metrics.tags.application: notification`(036의 `shop-core`와 대응 — 두 앱 메트릭 구분).
- **CB 메트릭 바인더**: `ResilienceConfig`(또는 신규 `ObservabilityConfig`)에서
  `TaggedCircuitBreakerMetrics.ofCircuitBreakerRegistry(circuitBreakerRegistry).bindTo(meterRegistry)` 를 등록(빈 초기화 시 1회). **기존 `circuitBreakerRegistry` 빈을 재사용**하고 새 레지스트리를 만들지 않는다.
  - 노출 메트릭: `resilience4j_circuitbreaker_state`, `_calls`, `_failure_rate`, `_buffered_calls` 등.
- **테스트 오염 가드 정합**: 바인더는 `MeterRegistry` + `CircuitBreakerRegistry` 빈이 모두 존재할 때만 동작하도록 둔다(기존 `@Profile`/`@ConditionalOnProperty` 가드 철학 계승). 단위 `ResilientEmailSenderTest`는 레지스트리를 `new`로 직접 조립하므로 스프링 바인더와 무관(영향 없음) — 이 격리가 깨지지 않는지 확인.

## Non-goals
- **resilience4j-spring-boot3 스타터 전환·`@CircuitBreaker` AOP·yml 자동바인딩** — ADR-010이 배제(하지 않음).
- CB의 `/actuator/health` 통합(health contributor) — 도입하지 않음(필요 시 후속 커스텀 HealthIndicator).
- TSDB/대시보드/트레이싱 — 보류.
- 메인 포트에 업무 HTTP API 신설 — 없음(웹 서버는 관리 포트 전용).
- notification은 HTTP가 아니므로 k6 직접 가압 대상 아님(로드맵 Non-goals) — 변경 없음.

## 검증 방법
- 앱 기동 후 `GET http://localhost:8081/actuator/health` → **200 UP**(전용 관리 포트).
- `GET http://localhost:8081/actuator/prometheus` → `jvm_*`, `kafka_consumer_*`, `resilience4j_circuitbreaker_*` 메트릭 노출 확인.
- **CB 메트릭 동작**: SMTP 실패 주입 시나리오(기존 `ResilientEmailSenderTest` 패턴 활용)에서 `resilience4j_circuitbreaker_state`/`_failure_rate`가 갱신되는지 통합 수준에서 확인.
- **풀컨텍스트 `./gradlew test` 그린** — actuator/web/바인더 도입이 005/023/024 및 CB 단위 테스트를 깨지 않음(메인 최종 동적 게이트). 특히 **기존 CB 단위 테스트 회귀 0**.
- 테스트 추가: 바인더 등록·메트릭 노출에 대한 슬라이스/통합 검증(testing-rule).

## plan에서 확정할 결정
1. 관리 포트 번호·노출 목록 최종값, 메인 서버 포트와의 관계(notification이 메인 포트를 아예 안 열지 여부 — `spring.main.web-application-type` 또는 포트 정책).
2. CB 바인더를 `ResilienceConfig`에 둘지 신규 `ObservabilityConfig`로 분리할지.
3. notification엔 spring-security가 없어 관리 포트가 기본 open — 로컬은 무방, 운영 노출 정책(네트워크 격리/인가) 명시.

## 참고
- ADR-010, plan `docs/plans/backend/025-...resilience4j-plan.md`(코어 채택·전환 조건), 036(shop-core 대응 Task)
- CB 구성: `notification/.../common/config/ResilienceConfig.java`(`circuitBreakerRegistry`·`smtpCircuitBreaker` 빈)
- 데코레이터: `ResilientEmailSender`, 프로퍼티: `ResilienceProperties`(`notification.resilience.smtp.*`)

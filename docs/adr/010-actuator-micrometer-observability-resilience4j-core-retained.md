# ADR-010 — Actuator + Micrometer 관측성 도입, resilience4j는 코어 유지(자동설정 스타터 미전환)

- 작성일: 2026-06-16
- 상태: Accepted
- 범위: shop-core · notification 두 애플리케이션의 관측성(메트릭/헬스) 기반

## 맥락

이 프로젝트는 그동안 **관측성(메트릭/트레이싱/구조화 로그)을 의도적으로 보류**해 왔다. 여러 결정 문서가 "관측성 도입 이후"를 명시적 단서로 남겼다.

- k6 부하 테스트 로드맵(`docs/tasks/performance/performance-shop-core-k6-load-test-roadmap.md` §2): k6는 당분간 "p95/에러율이 SLO를 지키나"의 **블랙박스 판정**까지만 하고, "왜 느린가(락 대기 vs Kafka vs GC)"의 서버측 원인 규명은 **관측성 도입 이후로 미룬다**.
- notification CircuitBreaker(plan `docs/plans/backend/025-...resilience4j-plan.md`): resilience4j를 **코어만** 채택하고 spring-boot3 스타터(자동설정·AOP)를 배제했다. 포기한 것 중 하나가 **Actuator 헬스 통합·CB 메트릭 익스포트**이며, 명시적으로 *"향후 메트릭/헬스 노출이 필요하면 그때 spring-boot3로 전환(YAGNI)"* 라는 전환 조건을 달았다.

이제 그 전환 트리거가 켜졌다. (1) k6 부하 구간의 원인 규명을 위해 서버측 메트릭이 필요하고, (2) CircuitBreaker 상태 전이/ open fail-fast를 로그가 아닌 메트릭으로 가시화할 동기가 생겼다.

현재 상태(코드 실사):
- 두 레포 모두 `spring-boot-starter-actuator`·Micrometer 의존이 **없다**.
- notification은 `io.github.resilience4j:resilience4j-circuitbreaker` **코어만** 사용하고, 자동설정 회피를 위해 **데코레이터(`ResilientEmailSender`) + 수동 `CircuitBreakerRegistry` 빈 + 전용 네임스페이스 `notification.resilience.smtp.*`**(표준 `resilience4j.circuitbreaker.instances.smtp.*`를 일부러 안 씀) + `@Profile`/`@ConditionalOnProperty` 가드로 **풀컨텍스트 `test` 오염을 차단**하는 설계다. 자동설정 회피가 이 설계의 뼈대다.

핵심 분리: **"Actuator + Micrometer 관측성 도입"** 과 **"resilience4j를 spring-boot3 자동설정 스타터로 전환"** 은 별개의 결정이며, 전자는 후자 없이 가능하다.

검토한 대안:

| 대안 | 장점 | 단점 |
|---|---|---|
| (1) 관측성 보류 연장 | 변경 없음·단순 | 부하/장애 원인 규명 불가, k6 블랙박스 한계 지속, CB 상태 로그로만 |
| (2) Actuator+Micrometer 도입 **+ r4j를 spring-boot3 스타터로 전환** | CB health contributor·CB 메트릭·yml 자동바인딩을 자동으로 얻음 | 025가 막은 **자동설정 재도입** → test 오염 가드·전용 네임스페이스·수동 Registry 설계 붕괴, 네임스페이스 마이그레이션 + Task 005/023/024 회귀 재검증 비용 |
| (3) Actuator+Micrometer 도입 **+ r4j는 코어 유지 + `resilience4j-micrometer` 바인더** | 관측성 확보하면서 데코레이터 설계·오염 가드를 **그대로 보존**, CB 메트릭도 익스포트 | CB health contributor·yml 자동바인딩은 자동으로 안 옴(필요 시 커스텀으로 보완) |

## 결정

**대안 (3)을 채택한다.**

1. **shop-core·notification 두 레포에 `spring-boot-starter-actuator` + Micrometer 레지스트리를 도입한다.** JVM·HTTP·Kafka·DataSource/커넥션풀·(shop-core) 등 표준 메트릭과 health 엔드포인트를 확보한다.
2. **notification의 resilience4j는 코어를 유지한다.** spring-boot3 자동설정 스타터로 **전환하지 않는다**. CircuitBreaker 메트릭은 코어 부속 모듈 **`resilience4j-micrometer`** 를 추가해 **기존 수동 `CircuitBreakerRegistry`** 에 `TaggedCircuitBreakerMetrics.ofCircuitBreakerRegistry(registry).bindTo(meterRegistry)` 바인더만 물려 익스포트한다. 데코레이터(`ResilientEmailSender`)·전용 네임스페이스(`notification.resilience.smtp.*`)·테스트 오염 가드는 plan 025 그대로 보존한다.
3. **CB의 Actuator health contributor·yml 자동바인딩은 도입하지 않는다.** CB 상태를 `/actuator/health`에 띄울 필요가 실제로 생기면 작은 커스텀 `HealthIndicator`로 한정 도입한다(스타터 전체 채택의 사유로 삼지 않는다).
4. **구현 세부(메트릭 레지스트리 종류, management 엔드포인트 노출 범위, 시큐리티 허용 규칙)는 본 ADR이 고정하지 않고 후속 Task/plan에 위임한다.** 단 방향만 못박는다: TSDB 파이프라인(Grafana/InfluxDB)은 로드맵대로 계속 보류(YAGNI)하며, 레지스트리는 TSDB 미기동 상태에서 저커밋으로 시작한다(예: Prometheus 스크레이프 엔드포인트 또는 actuator 내장 metrics).

이 결정은 plan 025 line 186의 전환 조건("메트릭/헬스 노출이 필요하면")을 **충족하되, 그 충족 방법으로 '스타터 전환' 대신 '코어 + 바인더'를 택한 것**이다. 025의 자동설정 회피 의도와 모순되지 않는다.

## 결과

긍정적 결과:

- 관측성 보류가 풀리면서 k6 부하 구간과 서버측 메트릭의 **상관 분석 경로가 열린다**(로드맵 §15 "왜 느린가" 후속 과제의 전제 충족).
- CircuitBreaker 상태/호출/실패율이 Micrometer 메트릭으로 노출되어 SMTP 장애 시 로그 grep 대신 메트릭으로 추적 가능해진다.
- plan 025의 데코레이터 설계·전용 네임스페이스·풀 `test` 오염 가드가 **그대로 유지**되어, 회귀 표면(Task 005/023/024)을 건드리지 않는다.

부정적 결과와 대응:

- CB health contributor·yml 자동바인딩 같은 스타터 편의를 자동으로 얻지 못한다.
  - 실제 필요가 확인되면 커스텀 `HealthIndicator` 또는 그 시점의 별도 ADR로 한정 도입한다(현재는 YAGNI).
- Actuator 엔드포인트가 두 앱의 보안 경계 뒤에 깔린다(특히 shop-core는 시큐리티 체인이 미매핑 경로를 로그인으로 리다이렉트). 노출/인가 정책을 명시하지 않으면 헬스 체크·스크레이프가 막힌다.
  - 후속 Task/plan에서 `management.endpoints.web.exposure.include`와 시큐리티 허용 규칙을 명시적으로 결정한다.
- 메트릭 카디널리티·엔드포인트 노출이 과해지면 운영 부담이 된다.
  - 저커밋 출발점(필요 메트릭만 노출, TSDB 보류)을 유지하고 확장은 점진적으로 한다.

## 관련 문서

- `docs/tasks/performance/performance-shop-core-k6-load-test-roadmap.md` (§2 관측성 보류, §15 원인 규명 후속)
- `docs/plans/backend/025-backend-notification-smtp-circuitbreaker-resilience4j-plan.md` (코어 채택·전환 조건)
- `docs/architecture.md`
- (후속) Actuator + Micrometer 도입 Task/plan

# notification resilience4j — spring-boot3 자동설정 스타터 비채택 결정 (Revision 1)

- 대상: 관측성 도입(Actuator + Micrometer) 시 notification CircuitBreaker의 메트릭/헬스 노출 방식
- 관련 Task: `docs/tasks/backend/037-backend-notification-actuator-micrometer-observability.md`, `docs/tasks/backend/036-...shop-core-actuator-micrometer...md`
- 관련 plan: `docs/plans/backend/037-...-plan.md`, 선례 `docs/plans/backend/025-...resilience4j-plan.md`
- 관련 ADR: `docs/adr/010-actuator-micrometer-observability-resilience4j-core-retained.md`
- 결정 일자: 2026-06-16
- 결정자: 사용자(방향 승인) + 설계 합의
- 목적: 관측성을 도입하면서 resilience4j를 **spring-boot3 자동설정 스타터로 전환하지 않고 코어를 유지**하기로 한 이유를 기록한다. plan 025가 전환 조건("메트릭/헬스 노출이 필요하면 그때 전환")을 달아둔 만큼, 그 조건이 켜진 지금 **왜 전환이 아니라 '코어 + `resilience4j-micrometer` 바인더'를 택했는지**를 남긴다.

---

## 결정 요약

1. 관측성 도입의 트리거(CB 상태 메트릭화·k6 원인 규명 기반)는 **충족됐다**. 그러나 그 충족 방법으로 **`io.github.resilience4j:resilience4j-spring-boot3` 자동설정 스타터로 전환하지 않는다.**
2. **코어(`resilience4j-circuitbreaker`)를 유지**하고, 코어 부속 모듈 **`resilience4j-micrometer`** 를 추가해 **기존 수동 `CircuitBreakerRegistry` 빈**에 `TaggedCircuitBreakerMetrics.ofCircuitBreakerRegistry(registry).bindTo(meterRegistry)` 바인더만 물린다. → CB 메트릭은 노출하되 자동설정은 들이지 않는다.
3. CB의 **Actuator health contributor·`resilience4j.*` yml 자동바인딩·`@CircuitBreaker` AOP**는 도입하지 않는다. 실제 필요가 확인되면 health는 작은 커스텀 `HealthIndicator`로 한정 도입한다.
4. 이 결정은 plan 025의 전환 조건을 **기각이 아니라 "더 작은 수단으로 충족"** 한 것이며, ADR-010 결정 2·3의 상세 근거다.

---

## 근거

### 전제 — plan 025 설계의 존재 이유가 "자동설정 회피"다
notification CB는 처음부터 **자동설정을 피하려고** 다음을 의도적으로 조립했다(plan 025):
- **데코레이터** `ResilientEmailSender implements EmailSender` (애너테이션 `@CircuitBreaker` + fallback 함정 회피),
- **수동 `CircuitBreakerRegistry` 빈** (`ResilienceConfig`),
- **전용 네임스페이스** `notification.resilience.smtp.*` (표준 `resilience4j.circuitbreaker.instances.smtp.*`를 **일부러 안 씀**),
- **가드** `@Profile("kafkatest | !test")` + `@ConditionalOnProperty(notification.mail.mode=smtp)` → 풀컨텍스트 `test`에서 CB 빈이 아예 생성되지 않음(불변식 ⑤, **풀 `test` 오염 0**).

즉 "스타터를 안 쓴다"가 이 설계의 부수효과가 아니라 **목적**이다. 지금 스타터로 전환하면 그 목적을 스스로 무너뜨린다.

### 스타터로 전환하면 되살아나는 비용
1. **자동설정 재유입 → test 오염 재개방.** `resilience4j-spring-boot3`는 `CircuitBreakerAutoConfiguration`을 켜고, 이는 풀컨텍스트 `@SpringBootTest`에서 활성화된다. plan 025가 `@Profile`/`@ConditionalOnProperty` 가드로 닫은 "프로파일/조건 밖 CB 빈 누수"를 다시 연다.
2. **빈 모호성.** 기존 수동 `circuitBreakerRegistry` 빈과 스타터가 자동 구성하는 레지스트리가 공존해 충돌·우선순위 문제가 생긴다.
3. **네임스페이스 강제 마이그레이션.** 스타터의 yml 자동바인딩은 `resilience4j.circuitbreaker.instances.smtp.*`를 기대한다. 현재 전용 키 `notification.resilience.smtp.*`(+ `NOTIFICATION_RESILIENCE_SMTP_*` 환경변수)는 **무시**되므로, 키·환경변수 전면 개명 + 운영 설정 변경이 따라온다.
4. **회귀 표면 확대.** 위 변경은 plan 025가 검증한 **Task 005/023/024 + CB 단위 테스트**를 재검증 대상으로 만든다. 단일 CB 하나의 편의를 위해 회귀 비용이 과하다.

### 지금 실제로 필요한 것은 "메트릭"뿐 — 스타터 없이 얻는다
- 이번 트리거의 본질은 **CB 상태/호출/실패율을 Micrometer로 노출**하는 것이다.
- 그건 코어 부속 **`resilience4j-micrometer`** 바인더를 **기존 레지스트리**에 물리면 끝난다(새 레지스트리·자동설정 불필요). 노출 메트릭: `resilience4j_circuitbreaker_state`/`_calls`/`_failure_rate`/`_buffered_calls`/`_slow_calls`.
- 바인더를 **`ResilienceConfig` 안**에 두면 동일 가드(`@Profile` + `@ConditionalOnProperty`)를 계승해 **풀 `test`에선 바인더도 미생성** → 오염 0이 그대로 유지된다.
- 스타터가 추가로 주는 것(health contributor·yml 자동바인딩·AOP)은 **지금 필요 없다(YAGNI)**. health가 정말 필요해지면 커스텀 `HealthIndicator` 한 개가 스타터 전체 채택보다 싸다.

### 비교
| 관점 | 스타터 전환(비채택) | 코어 + `resilience4j-micrometer` 바인더(채택) |
|---|---|---|
| CB 메트릭 노출 | O (자동) | **O (바인더 1개)** |
| CB Actuator health | O (자동) | △ (필요 시 커스텀 HealthIndicator) |
| yml 자동바인딩 | O (`resilience4j.*`) | X (전용 네임스페이스 유지 — 의도) |
| `@CircuitBreaker` AOP | O | X (데코레이터 유지 — 의도) |
| 풀 `test` 오염 | **재개방 위험** | **0 유지(가드 계승)** |
| 네임스페이스/환경변수 | **전면 개명 필요** | **무변경** |
| 005/023/024 회귀 | **재검증 필요** | **표면 없음** |

→ 스타터의 한계효용(health/AOP/yml)은 현재 불필요(YAGNI)인데, 한계비용(오염·개명·회귀)은 크다. **코어 + 바인더가 비용 대비 우월.**

---

## 결과

| 항목 | 조치 |
|---|---|
| resilience4j 의존 | `resilience4j-circuitbreaker` 코어 **유지** + `resilience4j-micrometer` **추가**(버전 resilience4j-bom 2.3.0 위임) |
| `resilience4j-spring-boot3` 스타터 | **미도입** |
| CB 메트릭 | `ResilienceConfig`에 `TaggedCircuitBreakerMetrics` 바인더 빈 추가(기존 registry 재사용, 가드 계승) |
| CB health contributor | **미도입**(필요 시 후속 커스텀 HealthIndicator) |
| `notification.resilience.smtp.*` 네임스페이스·데코레이터 | **무변경** |

---

## 보존되는 사실 / 되돌릴 조건

- plan 025 전환 조건("메트릭/헬스 노출이 필요하면 그때 spring-boot3로 전환")은 **충족됐으나, 더 작은 수단(코어+바인더)으로 충족**했다. ADR-010이 이 방향을 SSOT로 고정한다.
- **스타터를 재검토할 신호**: CB 인스턴스가 단일 `smtp`에서 다수로 늘고, per-instance yml 동적 설정·AOP 선언적 적용·표준 health 통합이 **동시에** 요구될 때. 그 시점엔 네임스페이스 마이그레이션·test 가드 재설계 비용을 감수하는 별도 Task/ADR로 승격한다(지금은 그 신호가 없다).
- 정합/장애 흡수의 권위는 여전히 데코레이터 + 수동 registry + 도메인 예외 분류(record/ignore)다. 바인더는 **관측만** 더하고 동작을 바꾸지 않는다.

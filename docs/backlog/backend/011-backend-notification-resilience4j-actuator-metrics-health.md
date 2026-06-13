# (backlog) notification SMTP CircuitBreaker 메트릭/헬스 노출 (resilience4j-spring-boot3 + Actuator)

> 상태: backlog (미착수)
> 영역: notification (backend / observability)
> 출처: Task 025(SMTP CircuitBreaker) plan §1(b)·§6 트레이드오프 — **코어 라이브러리 + 수동 `CircuitBreakerRegistry`** 채택으로 Actuator 헬스/메트릭 통합을 의도적으로 보류(YAGNI). `docs/plans/backend/025-backend-notification-smtp-circuitbreaker-resilience4j-plan.md`

## 배경 / 동기
- Task 025는 SMTP `CircuitBreaker`를 **`resilience4j-circuitbreaker` 코어 + 데코레이터 + 수동 Registry**로 구현했다. `resilience4j-spring-boot3` 자동설정을 **회피**한 이유는 (1) 풀컨텍스트 `test`(Kafka/JPA 자동설정 제외 최소 컨텍스트, log 모드) 오염 방지, (2) 의존 최소화였다.
- 그 귀결로 **CircuitBreaker 상태/메트릭이 로그로만** 관측된다(상태 전이·open fail-fast 마커 로그). Actuator `health`/`metrics`(Micrometer) 익스포트, `resilience4j.*` 표준 yml 바인딩, `@CircuitBreaker` AOP 편의는 없다.
- 단일 노드·단일 브로커 현 배포(architecture §8)에선 로그로 충분하나, **운영 가시성 요구(대시보드/알람/SLO)** 가 생기면 메트릭/헬스 노출이 필요해진다.

## 범위 (할 것 — 도입 시점에)
- `resilience4j-spring-boot3`(+ `micrometer` / `spring-boot-starter-actuator`) 도입, `CircuitBreakerRegistry`를 자동설정 + `resilience4j.circuitbreaker.instances.smtp.*` 표준 바인딩으로 전환(또는 수동 Registry에 `TaggedCircuitBreakerMetrics` 바인딩만 추가).
- Actuator `circuitbreakers` health indicator + `/actuator/metrics`(resilience4j_circuitbreaker_*) 노출. 필요 시 대시보드/알람 연계.
- **회귀 보호**: Task 025의 5개 불변식(특히 ⑤ "풀컨텍스트 `test` CB 무관여")이 자동설정 도입으로 깨지지 않도록 — 자동설정이 전 프로파일에서 빈을 생성하므로, log 모드/풀test에서 외부 SMTP 미접속·기동 무오염을 재검증(testing-rule §컨텍스트 배선). `notification.resilience.smtp.*` 자체 네임스페이스 ↔ `resilience4j.*` 표준 네임스페이스 전환 정합.
- 네임스페이스/설정 키 이관 시 환경변수 오버라이드 호환 유지.

## 범위 밖 / 주의
- CircuitBreaker **동작/임계 로직 변경 없음**(025가 소유) — 본 항목은 **관측성 노출**만. 변환·record/ignore·빈 유일성 불변식 보존.
- 메트릭 백엔드(Prometheus 등)·대시보드 구축은 별도(인프라).

## 선행 의존
- Task 025(SMTP CircuitBreaker) 완료. 관측성 요구가 실제로 생긴 시점에 착수(선측정·후도입 — YAGNI).

## 참고
- `docs/plans/backend/025-backend-notification-smtp-circuitbreaker-resilience4j-plan.md` §1(b)/§6, `docs/rules/testing-rule.md`(자동설정 전 프로파일 빈 생성 주의), `docs/architecture.md` §8

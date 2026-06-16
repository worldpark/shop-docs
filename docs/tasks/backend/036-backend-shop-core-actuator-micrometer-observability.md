# 036. shop-core 관측성 기반 — Actuator + Micrometer 도입

> 출처: ADR-010(Actuator + Micrometer 관측성 도입, resilience4j 코어 유지). 그동안 보류였던 관측성을 도입하는 횡단 인프라 작업. notification 쪽은 별 Task(037)로 분리한다("한 Task = 한 기능", 독립 레포·빌드).

## 선행 결정 (ADR-010, Accepted)
- 관측성 보류 해제. 두 앱에 `spring-boot-starter-actuator` + Micrometer 레지스트리 도입.
- TSDB 파이프라인(Grafana/InfluxDB)은 **계속 보류**(YAGNI). 레지스트리는 TSDB 미기동 상태에서 저커밋으로 시작.
- 이 결정들은 재논의하지 않고 계승한다.

## 배경
- shop-core는 `spring-boot-starter-web` + 시큐리티 체인을 갖췄으나 **actuator·micrometer 의존이 없다**. 현재 `/actuator/**`는 어떤 핸들러에도 매핑되지 않아 **view 시큐리티 체인(@Order(2), formLogin)이 가로채 `/login`으로 302 리다이렉트**한다(REST 체인 @Order(1)은 `/api/v1/**`만 매칭).
- k6 부하 로드맵 §2/§15가 "관측성 도입 후 원인 규명"을 단서로 남겼다. 본 Task가 그 전제를 채운다(부하 구간 ↔ JVM/HTTP/락 대기/커넥션풀 메트릭 상관의 기반).

## 기술 선택
- **레지스트리: `micrometer-registry-prometheus`** (권장 기본 — 사용자 확정 필요 시 조정). 근거: pull 방식 `/actuator/prometheus` 스크레이프 엔드포인트만 노출하면 되고 **TSDB를 아직 안 띄워도** 동작하며, 추후 Grafana 도입 시 그대로 연결된다. (대안: actuator 내장 `/actuator/metrics`만 — 표준 노출 규약이 약해 후순위.)
- 버전: Spring Boot BOM이 actuator·micrometer를 관리하므로 **버전 명시 불필요**.

## Target
shop-core 빌드 의존성 + `application.yml` management 설정 + 시큐리티 노출 규칙. **도메인 로직·REST API·뷰는 변경하지 않는다.**

## Goal
shop-core가 표준 메트릭(JVM·HTTP 서버·Kafka 클라이언트·DataSource/HikariCP·로깅)과 health를 Actuator로 노출하고, Prometheus 스크레이프 엔드포인트를 제공한다. 풀컨텍스트 테스트는 그린을 유지한다(관측성 도입이 기존 컨텍스트를 오염시키지 않음).

## 범위 (Scope)
- **의존 추가**: `org.springframework.boot:spring-boot-starter-actuator`, `io.micrometer:micrometer-registry-prometheus`.
- **`application.yml` management 설정**:
  - `management.endpoints.web.exposure.include`: 최소 노출 — `health`, `info`, `prometheus`(필요 시 `metrics`). 와일드카드(`*`) 금지(과다 노출 방지).
  - `management.endpoint.health.show-details`: `when-authorized`(또는 보안 결정에 맞춰). liveness/readiness probe는 단일 노드 단계에선 선택.
  - `management.metrics.tags.application: shop-core`(공통 태그로 두 앱 메트릭 구분).
  - 환경변수 오버라이드 가능하게(노출 목록·포트).
- **시큐리티 노출 규칙(핵심)**: actuator 엔드포인트가 시큐리티 뒤에 깔리므로 명시적 허용을 추가한다.
  - `/actuator/health`(+ liveness/readiness): 외부 헬스 체크·k6 사전 점검용으로 **permitAll**.
  - `/actuator/prometheus`(+ 민감 가능 엔드포인트): 로컬/개발은 permit, 운영 노출 정책은 plan에서 결정(예: 관리 포트 분리 또는 인가 제한). **민감 정보 과다 노출 금지**(api-authorization-rule 정합).
  - 어느 시큐리티 체인(@Order(1) REST vs @Order(2) view)에 규칙을 둘지는 plan에서 코드 대조 후 확정(`/actuator/**`는 현재 view 체인에 걸림).
- **검증 후 README/문서 보강**: k6 README의 사전 점검(`GET /actuator/health`)이 이제 실제로 200을 주도록 정합.

## Non-goals
- TSDB(Grafana/InfluxDB)·대시보드·알람 — 보류(ADR-010, 로드맵 §13).
- 분산 트레이싱(Micrometer Tracing/OTel) — 본 Task 범위 밖(후속 ADR 후보).
- 커스텀 비즈니스 메트릭(주문 수·결제 실패율 등) 추가 — 본 Task는 **표준 메트릭 노출 기반**까지. 커스텀 계측은 후속.
- resilience4j 관련 — shop-core엔 r4j가 없으므로 무관(037 notification 전용).

## 검증 방법
- 앱 기동 후 `GET /actuator/health` → **200 `{"status":"UP"}`**(이전 302 리다이렉트 해소 확인).
- `GET /actuator/prometheus` → Prometheus 텍스트 포맷 메트릭 반환(`jvm_*`, `http_server_requests_*`, `hikaricp_*`, `kafka_*` 노출 확인).
- **풀컨텍스트 `./gradlew test` 그린** — actuator/micrometer 도입이 기존 컨텍스트 로드·슬라이스 테스트를 깨지 않음(메인 최종 동적 게이트, verification-gate-rule §2).
- 시큐리티: 미인증 상태에서 `/actuator/health`는 200, 민감 엔드포인트는 정책대로 차단/허용됨을 확인.
- 테스트 추가: 노출/인가 규칙에 대한 슬라이스 또는 통합 검증(testing-rule — "테스트 없이 기능 추가 금지").

## plan에서 확정할 결정
1. Micrometer 레지스트리 최종 선택(Prometheus 권장) 확인.
2. actuator 엔드포인트 노출 목록·`show-details` 수준.
3. 시큐리티 허용 규칙을 둘 체인과 경로 범위, 운영 시 관리 포트 분리 여부.

## 참고
- ADR-010, k6 로드맵 §2·§15, `docs/rules/api-authorization-rule.md`, `docs/rules/error-response-rule.md`
- 현재 시큐리티 체인: `shop-core/.../security/SecurityConfig.java`(REST @Order(1) `/api/v1/**`, view @Order(2))

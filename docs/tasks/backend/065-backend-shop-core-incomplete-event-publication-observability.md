# 065. shop-core 이벤트 발행 회복(3) — 미완료 발행 관측(Micrometer 게이지 + 알람 기반)

> 출처: 이벤트 발행(프로듀서) 실패 회복 갭 분석의 관측 축. Task 063(재기동 재발행)·064(스케줄 재제출)가 **회복 동작**을 담당한다면, 본 Task는 **"지금 회복이 필요한 발행이 얼마나 쌓여 있는가"를 가시화**한다. 회복 메커니즘이 동작하는지, 독성(poison) 메시지가 무한 적체되는지를 메트릭으로 드러내 알람·대시보드의 토대를 만든다.
> 본 Task만 문서화 단계에서 작성한다(구현은 후속 결정). 063·064가 회복을 켜고, 065가 그 효과·잔존을 측정한다 — 회복 3종 세트의 관측 축.

## 배경 (현재 상태 — 코드 확인됨)
- 발행 경로: `event_publication`(Spring Modulith Outbox) — INCOMPLETE(`completion_date IS NULL`) 저장 후 Kafka 외부화 성공 시 완료 기록.
- 현재 미완료 발행을 **노출하는 메트릭이 없다**. 적체 여부는 DB를 직접 쿼리해야만 알 수 있다(운영 사각).
- 관측 인프라(이미 존재, Task 036): `spring-boot-starter-actuator` + `micrometer-registry-prometheus`. `/actuator/prometheus` 스크레이프 노출. 공통 태그 `application=shop-core`. **본 Task는 이 위에 커스텀 비즈니스 메트릭을 얹는다**(Task 036이 표준 메트릭까지, 커스텀은 후속이라 명시한 그 후속에 해당).
- Modulith API: `IncompleteEventPublications`(빈) 또는 `event_publication` 직접 카운트 쿼리로 미완료 건수 산출 가능.

## 선행 결정
- ADR-010(Actuator + Micrometer 관측성) 계승 — 표준 메트릭 위에 도메인 메트릭(미완료 발행)을 추가하는 첫 커스텀 계측 사례.
- ADR-002(Outbox) 계승 — "발행 실패·재시도 상태 추적"의 관측 표면.

## Target
shop-core에 미완료 이벤트 발행 관측 메트릭(Micrometer) 추가 + 노출. **도메인 로직·REST·뷰·스키마·이벤트 계약·인가 무변경.**

## Goal
shop-core가 **현재 미완료(INCOMPLETE) 이벤트 발행 건수**(및 가능하면 가장 오래된 미완료의 경과시간·재제출 횟수)를 Micrometer 게이지로 `/actuator/prometheus`에 노출한다. 이를 통해 (a) 회복 메커니즘(063·064)이 적체를 실제로 비우는지, (b) 독성 메시지가 무한 적체되는지를 그래프·알람으로 관측할 수 있다. 풀컨텍스트 그린 유지.

## 범위 (Scope)
- **게이지 메트릭(필수)**: `shop.events.publication.incomplete`(또는 동등 명명) — 현재 INCOMPLETE 발행 건수. Micrometer `Gauge`로 등록(주기 평가 — `IncompleteEventPublications` 또는 `event_publication` count 쿼리 기반, 경량).
- **부가 메트릭(선택, plan 확정)**:
  - 가장 오래된 미완료의 age(초) — 적체 노후도(독성/장애 신호).
  - 재제출 횟수 카운터(064 스케줄러가 재제출한 누계) — 회복 활동량. (064 미머지 시 생략 가능.)
- **노출**: 기존 actuator Prometheus 노출에 자동 포함(엔드포인트 노출 목록 변경 불필요 — 메트릭만 추가). 공통 태그 `application=shop-core` 상속.
- **알람은 "기반"까지**: TSDB/Grafana/알람 룰 자체는 ADR-010대로 **계속 보류**. 본 Task는 알람이 걸 수 있는 **메트릭 노출**까지. (예: `incomplete > 0 지속 N분` 룰은 운영 도입 시.)
- **테스트**: 미완료 발행 존재/부재 시 게이지 값이 반영되는지(슬라이스/통합).

## Non-goals
- 회복 동작(재기동 재발행·스케줄 재제출) — Task 063·064.
- TSDB·Grafana 대시보드·알람 룰 배포 — 보류(ADR-010, 로드맵 §13). 본 Task는 메트릭 노출만.
- 분산 트레이싱·로그 적재 파이프라인 — 범위 밖.
- `event_publication` 정리/아카이빙 — 후속.
- 독성 메시지 자동 격리/재시도 상한 — 064 비범위와 동일하게 후속(본 Task는 그 신호를 **측정만**).

## 주의 / 트레이드오프 (plan에서 명문화)
- **게이지 평가 비용**: 미완료 건수 산출이 매 스크레이프마다 무거운 쿼리가 되지 않게 한다(인덱스된 `completion_date IS NULL` count 또는 주기 캐싱). plan에서 평가 방식(Micrometer Gauge lazy 평가 vs 주기 갱신 캐시) 확정.
- **다중 노드 합산 주의**: 게이지는 노드별로 같은 전역 `event_publication`을 보므로, 여러 노드가 동일 값을 보고하면 Prometheus에서 인스턴스별 동일값이 된다(합산 아닌 max/avg로 봐야 함). 태그/해석 가이드는 plan/주석에 명시.
- **064 의존성**: 재제출 횟수 카운터는 064 스케줄러가 있어야 의미. 064 미머지면 건수 게이지(필수)만 내고 재제출 카운터는 생략(plan에서 선행 상태로 결정).

## API Authorization
> 신규 비즈니스 API 없음. 메트릭은 기존 `/actuator/prometheus`(Task 036에서 노출 정책 확정)로 나간다 — actuator 노출/인가 정책 무변경. SecurityConfig 무변경. (api-authorization-rule: 민감 정보 비노출 — 건수/age 스칼라만, 페이로드·PII 미노출.)

## 검증 방법 (plan에서 테스트 형태 확정)
- **통합(Testcontainers PostgreSQL)**: INCOMPLETE 발행 N건 시드 → `/actuator/prometheus`(또는 MeterRegistry 직접 조회)에서 게이지 = N. 완료 처리 후 0으로 감소. (Micrometer `Gauge` 평가 시점 주의.)
- **풀컨텍스트 `./gradlew test` 그린**(메인 최종 게이트): 계측 추가가 기존 컨텍스트·메트릭을 깨지 않음.
- 회귀: 표준 메트릭(jvm/http/hikari/kafka, Task 036) 노출 불변. 메트릭 추가가 actuator 노출 목록·인가를 바꾸지 않음.

## plan에서 확정할 결정
1. 메트릭 명명·단위·태그(`shop.events.publication.incomplete` gauge, age 초 단위 게이지 여부, 재제출 카운터 포함 여부 — 064 선행 상태에 종속).
2. 미완료 건수 평가 방식(Micrometer Gauge lazy 콜백 + `IncompleteEventPublications`/count 쿼리 vs 주기 갱신 캐시) — 스크레이프 부하·정확도 트레이드오프.
3. 계측 빈 배치 패키지(`common/events` 또는 `common/config` — 036 관측 설정·064 스케줄러 인접) 및 모듈 경계.
4. 다중 노드 게이지 해석 가이드(인스턴스별 동일값 — Prometheus 쿼리에서 max) 문서화 수준.
5. 064(재제출 카운터) 의존 처리 — 064 머지 전이면 건수 게이지만, 후면 카운터 추가.

## 참고
- ADR-010(Actuator + Micrometer 관측성), ADR-002(Outbox), Task 036(shop-core actuator/micrometer 표준 메트릭 — 본 Task의 토대), Task 063·064(회복 동작 — 본 Task가 측정)
- `docs/rules/api-authorization-rule.md`(민감정보 비노출), `docs/rules/verification-gate-rule.md`, `docs/rules/testing-rule.md`
- 인프라: `/actuator/prometheus`(Task 036), `IncompleteEventPublications`/`event_publication`(Modulith), 공통 태그 `application=shop-core`

# 064. shop-core 이벤트 발행 회복(2) — 미완료 발행 스케줄 재제출 + 리더 게이트

> 출처: 이벤트 발행(프로듀서) 실패 회복 갭 분석. Task 063(재기동 시 재발행)이 "재기동 시점" 회복을 켰다면, 본 Task는 **정상 가동 중(steady-state) 주기적 자동 재제출**로 회복을 상시화한다. 재기동을 기다리지 않고, 영구 실패해 INCOMPLETE로 남은 발행을 주기적으로 다시 외부화한다.
> 063과 상호 보완: 063=재기동 회복(저비용·단순), 064=상시 회복(스케줄·다중노드 안전). 둘 다 켜도 무해(대상은 동일 INCOMPLETE 집합, 멱등).

## 배경 (현재 상태 — 코드 확인됨)
- 발행 경로: `eventPublisher.publishEvent(...)`(같은 `@Transactional`) → `event_publication` INCOMPLETE 저장 → 커밋 후 `DelegatingEventExternalizer`가 Kafka 외부화 → 성공 시 `completion_date`.
- 갭(063과 동일): `delivery.timeout`(프로듀서 기본 ~2분) 초과 장기 다운으로 영구 실패한 발행은 INCOMPLETE로 잔존. **상시 자동 재제출 없음**(`@Scheduled`·`IncompleteEventPublications` 호출 grep 0건).
- **재사용 인프라(이미 존재)**: `SchedulerLeaderGuard.runIfLeader(resource, task)`(Task 035, Redisson 분산락 리더 게이트). 이 인터페이스 javadoc이 **"신규 스케줄러(재고/주문 배치·Modulith 재발행 등)는 동일 `runIfLeader` 규약을 따른다"** 고 본 Task를 명시적으로 예견한다. `@EnableScheduling`은 `OrderExpirySchedulingConfig`로 이미 활성. 선례 스케줄러: `UnpaidOrderExpiryScheduler`(`@Scheduled(fixedDelayString=...)` + `leaderGuard.runIfLeader(SCHEDULER_RESOURCE, this::doWork)`).
- Modulith API: `org.springframework.modulith.events.IncompleteEventPublications`(빈) — `resubmitIncompletePublicationsOlderThan(Duration)` / `resubmitIncompletePublications(Predicate)`. BOM 1.3.1.

## 선행 결정
- ADR-002(Transactional Outbox) 계승. Task 035(스케줄러 리더 선출·분산락) 인프라 재사용. Task 063과 동일 회복 목표의 상시화.
- 컨슈머 측 회복(retry+DLQ)은 이미 구성 — 범위 밖.

## Target
shop-core에 미완료 발행 재제출 스케줄러(신규) + 리더 게이트 결합 + 설정. **도메인 로직·REST·뷰·스키마·이벤트 계약 무변경.**

## Goal
shop-core가 가동 중 **주기적으로(예: 1분 간격) `event_publication`의 일정 시간 이상 미완료(INCOMPLETE)인 발행을 재제출**하여 Kafka로 재외부화한다. 다중 노드에서는 **리더 1노드만** 실행한다(`SchedulerLeaderGuard`). 풀컨텍스트·ModularityTests·ArchUnit 그린 유지.

## 범위 (Scope)
- **신규 스케줄러 빈**: `@Scheduled(fixedDelayString=...)` 진입점 → `leaderGuard.runIfLeader("scheduler:event-republish", this::doResubmit)` → `IncompleteEventPublications.resubmitIncompletePublicationsOlderThan(olderThan)` 위임. 선례(`UnpaidOrderExpiryScheduler`) 패턴·패키지 관례 준수.
- **설정 프로퍼티**: 실행 간격(`shop.events.republish.interval`, 예 `PT1M`) + 재제출 대상 최소 경과시간(`shop.events.republish.older-than`, 예 `PT2M`) + on/off 토글(`shop.events.republish.enabled`). 환경변수 오버라이드.
- **스케줄 활성 게이팅**: 선례(`OrderExpirySchedulingConfig`/SSE SchedulingConfig)처럼 **설정 로드 시에만 `@Scheduled` 발화**하도록 분리(테스트·프로파일 격리). 메모리 선례 `shop-core-tests-no-active-profile-gating` 준수 — `@Profile` 대신 `@ConditionalOnProperty`.
- **테스트**: 리더일 때만 재제출 위임(비리더 skip), 일정 경과 미완료분만 대상, 멱등(완료분 미대상) 검증.

## Non-goals
- 재기동 시 재발행 — Task 063(`republish-outstanding-events-on-restart`).
- 프로듀서 acks/retries 튜닝 — 기본값 유지.
- 컨슈머 retry/DLQ — 이미 구성.
- `event_publication` 아카이빙/정리·무한 재시도 상한(영구 독성 메시지 격리) — 후속 후보(아래 주의에 한정 언급).
- 신규 분산락 인프라 — 기존 `SchedulerLeaderGuard` 재사용(신규 금지).

## 주의 / 트레이드오프 (plan에서 명문화)
- **`older-than` 하한 = 프로듀서 delivery.timeout 초과**: 재제출 대상의 최소 경과시간은 Kafka 프로듀서 `delivery.timeout.ms`(기본 120000ms=2분)보다 **커야** 한다. 그렇지 않으면 프로듀서가 아직 자동 재시도 중인 발행을 스케줄러가 중복 재제출한다. 기본 `older-than ≥ PT2M` 권장(plan 확정).
- **at-least-once → 컨슈머 멱등**: 재제출은 중복 전달 유발 가능. indexer(`eventId`+ES external version)·notification(idempotency/DLQ, Task 005) 멱등 보유 — plan 대조.
- **리더 게이트 필수(다중노드)**: `runIfLeader`로 리더 1노드만 재제출(중복 외부화 최소화). 락 인프라 장애 시 skip(폴백) — 선례 동일.
- **독성 메시지(poison) 영구 미완료**: 외부화가 구조적으로 계속 실패하는 발행은 매 주기 재시도되어 잡음·부하가 될 수 있다. 재시도 상한/격리는 본 Task 범위 밖(후속) — 단, 관측(Task 065)으로 가시화한다.

## API Authorization
> 신규 API·엔드포인트 없음. SecurityConfig·인가 표면 무변경. (api-authorization-rule 해당 없음 — 스케줄러/배치 작업, 외부 트리거 없음)

## 검증 방법 (plan에서 테스트 형태 확정)
- **단위(Mockito)**: 스케줄 진입점이 `leaderGuard.runIfLeader(resource, task)`로 위임하고, 리더일 때만 `IncompleteEventPublications.resubmitIncompletePublicationsOlderThan(olderThan)`를 호출(비리더/락 장애 시 skip)함을 검증. `older-than`·간격 프로퍼티 바인딩.
- **통합(Testcontainers Kafka + PostgreSQL)**: 일정 시간 이상 INCOMPLETE인 발행을 시드 → 스케줄 1회 트리거 → Kafka 토픽 재도착 + `completion_date` 채워짐. 최근(경과 미달) 미완료분은 미대상. 완료분 불변.
- **풀컨텍스트 `./gradlew test` + ModularityTests/ArchUnit 그린**(메인 최종 게이트). 스케줄러 도입이 모듈 경계·컨텍스트를 깨지 않음.
- 회귀: 정상 발행 흐름 불변. 비활성(`enabled=false`) 시 스케줄 미발화.

## plan에서 확정할 결정
1. 스케줄러 배치 패키지(예: `common/events` 또는 인접 — `SchedulerLeaderGuard`·`UnpaidOrderExpiryScheduler` 선례 대조)와 리소스 키(`scheduler:event-republish`). 모듈 경계 위반 없게.
2. `IncompleteEventPublications` API 선택(`resubmitIncompletePublicationsOlderThan(Duration)` 권장) + `older-than` 기본값(≥ delivery.timeout, 예 PT2M·PT5M) + 간격(예 PT1M).
3. 스케줄 활성 게이팅 형태(`@ConditionalOnProperty(shop.events.republish.enabled)` + SchedulingConfig 분리) — 테스트·다중 인스턴스 안전. `@Profile` 미사용(메모리 선례).
4. 관측 훅 — 미완료 건수/재제출 횟수 메트릭을 본 Task에서 낼지 Task 065로 넘길지(권장: 메트릭은 065, 본 Task는 재제출 로직만 — 범위 분리).
5. 063과의 동시 활성 정책(둘 다 ON 권장 — 재기동+상시 이중 안전, 멱등이라 무해).

## 참고
- ADR-002, Task 004(event-publication-registry), Task 035(스케줄러 리더 선출·Redisson 분산락), Task 063(재기동 재발행), Task 065(미완료 발행 관측)
- 인프라 재사용: `SchedulerLeaderGuard`/`RedissonSchedulerLeaderGuard`(javadoc이 "Modulith 재발행"을 예견), 선례 `UnpaidOrderExpiryScheduler`+`OrderExpirySchedulingConfig`(@EnableScheduling 도입처)
- `docs/rules/event-contract-rule.md`, `docs/rules/verification-gate-rule.md`, `docs/rules/testing-rule.md`, `docs/rules/package-structure-rule.md`
- 메모리: `shop-core-tests-no-active-profile-gating`(게이팅은 @ConditionalOnProperty)

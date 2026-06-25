# 063. shop-core 이벤트 발행 회복(1) — Modulith 미완료 발행 재기동 시 재발행

> 출처: 이벤트 발행(프로듀서) 실패 회복 갭 분석. 현재 Transactional Outbox(`event_publication`)는 발행 실패 시 이벤트를 INCOMPLETE로 보존(유실 방지)하지만, **영구 실패(Kafka 브로커가 프로듀서 delivery.timeout(기본 ~2분)을 넘겨 다운)한 미완료 발행을 자동으로 다시 보내는 장치가 없다.** 본 Task는 그중 **재기동 시점 회복**을 1급으로 켠다.
> 후속 분리: 정상 가동 중(steady-state) 주기적 재제출은 Task 064(스케줄 재제출 + 리더 가드)로 분리한다("한 Task = 한 기능"). 063은 재기동 회복, 064는 상시 회복 — 상호 보완.

## 배경 (현재 상태 — 코드 확인됨)
- 발행 경로: 도메인 변경 + `eventPublisher.publishEvent(...)`를 같은 `@Transactional` 안에서 호출 → Spring Modulith Event Publication Registry가 `event_publication`에 **INCOMPLETE**로 저장(커밋과 원자적) → 커밋 후 `DelegatingEventExternalizer`가 `KafkaTemplate`로 외부화 → 성공 시 `completion_date` 기록.
- 의존: `spring-modulith-starter-jpa`(event_publication 테이블) + `spring-modulith-events-kafka`. 버전 BOM `spring-modulith-bom:1.3.1`.
- Kafka 프로듀서: 명시 acks/retries 미설정 → kafka-clients 3.8 기본값(`enable.idempotence=true` → acks=all, retries 사실상 무한, `delivery.timeout.ms=120000`). **일시적(~2분 이내) 브로커 불가는 프로듀서가 자동 재시도**해 흡수한다.
- **갭**: `delivery.timeout`을 초과하는 장기 다운으로 영구 실패한 발행은 `event_publication`에 INCOMPLETE(`completion_date IS NULL`)로 잔존하나, 이를 **다시 외부화하는 자동 회복이 없다**. 현재 설정에 `spring.modulith.events.republish-outstanding-events-on-restart`가 **미지정 → 기본 false**(재기동해도 자동 재발행 안 함). 스케줄 재처리·`IncompleteEventPublications` 호출도 없음(grep 0건).
- 현재 운영상 사고는 없음(`event_publication` INCOMPLETE 0건 / 완료 299건 — 그동안 Kafka 가동). 본 Task는 **유실 없는 at-least-once의 회복 자동화** 보강이다.

## 선행 결정
- ADR-002(Transactional Outbox with Spring Modulith) 계승 — "이벤트 발행 실패와 재시도 상태를 추적할 수 있다"는 결정의 **회복 자동화** 부분을 채운다.
- 컨슈머 측 회복(retry 3 + DLQ, `SearchIndexKafkaConsumerConfig`, `*.DLQ` 토픽)은 **이미 구성됨 — 본 Task 범위 밖**(발행/프로듀서 측만 다룬다).

## Target
shop-core `application.yml`의 Spring Modulith 이벤트 설정 + 회복 동작 검증 테스트. **도메인 로직·REST·뷰·스키마·이벤트 계약은 변경하지 않는다.**

## Goal
shop-core가 기동 시 `event_publication`의 **미완료(INCOMPLETE) 발행을 자동으로 재제출**(원 리스너 재호출 → 외부화 리스너가 Kafka로 재발행)하도록 한다. 즉 발행 시점에 Kafka가 장기 다운이어서 외부화에 실패했더라도, **다음 기동에서 자동 복구**된다. 풀컨텍스트 테스트 그린 유지.

## 범위 (Scope)
- **`application.yml` 한 줄**: `spring.modulith.events.republish-outstanding-events-on-restart: true` 추가(환경변수 오버라이드 가능하게). 기존 `spring.modulith.events.externalization.enabled=true`와 같은 블록.
- **회복 검증 테스트**: 미완료 발행이 재기동(새 컨텍스트) 시 재외부화되는지 확인하는 통합 테스트. 정확한 테스트 형태는 plan 확정(아래 "plan 확정 결정").
- **문서/주석**: 설정 의도(at-least-once 회복·재기동 트리거·다중노드 주의)를 yml 주석으로 명시.

## Non-goals
- 정상 가동 중 주기적 재제출(스케줄러) — Task 064.
- Kafka 프로듀서 acks/retries/idempotence 튜닝 — 기본값 유지(이미 멱등·acks=all). 본 Task 불변.
- 컨슈머 retry/DLQ — 이미 구성됨, 무관.
- `event_publication` 보존기간·아카이빙·정리 정책 — 후속 후보.
- 분산락/리더 선출 — 064 영역(재기동 재발행은 노드별 독립 동작이라 리더 게이트 비대상, 아래 주의 참조).

## 주의 / 트레이드오프 (plan에서 명문화)
- **at-least-once → 컨슈머 멱등 필수**: 재발행은 중복 전달을 유발할 수 있다. shop-core indexer 컨슈머는 `eventId` 멱등 키 + ES external version(occurredAt epoch)으로 순서 역전·중복을 흡수(확인됨). notification 컨슈머도 idempotency/DLQ 보유(Task 005). 재발행이 새 멱등 위반을 만들지 않음을 plan에서 대조.
- **다중 노드 재기동 시 중복 외부화**: 여러 노드가 동시에 기동하면 각 노드가 미완료분을 재발행 → Kafka에 동일 이벤트 N회 게시 가능. 컨슈머 멱등으로 무해하나, "상시 회복은 리더 1노드만"이 필요하면 그건 Task 064(리더 가드)가 담당한다. 본 Task는 재기동 회복의 단순·저비용 1급화에 한정.
- **재발행 대상**: 현재 INCOMPLETE 가능한 비동기 리스너는 외부화 리스너뿐(event_publication 299건 전부 `DelegatingEventExternalizer`). 따라서 재기동 재발행 = Kafka 재외부화로 귀결(in-process 부수효과 없음).

## API Authorization
> 본 Task는 신규 API·엔드포인트를 추가하지 않는다. SecurityConfig 무변경, 인가 표면 변화 없음. (api-authorization-rule 해당 없음 — 설정/배치 작업)

## 검증 방법 (plan에서 테스트 형태 확정)
- **통합(Testcontainers Kafka + PostgreSQL)**: (a) 발행 시 Kafka 외부화가 실패해 `event_publication`에 INCOMPLETE가 남는 상황을 유도 → (b) 컨텍스트 재기동(또는 Modulith 재발행 트리거) + republish 플래그 ON → (c) Kafka 토픽에 해당 이벤트가 도착(재외부화)하고 `completion_date`가 채워짐을 단언. (실현 난이도에 따라 plan이 경량 대안 — 예: 미완료 publication 시드 후 재발행 경로 단언 — 으로 조정 가능. testing-rule "테스트 없이 기능 추가 금지" 준수.)
- **풀컨텍스트 `./gradlew test` 그린**(메인 최종 동적 게이트, verification-gate-rule §2): 설정 추가가 기존 컨텍스트·외부화 동작을 깨지 않음.
- 회귀: 정상 발행(완료) 흐름 불변 — 기동마다 이미 완료된 발행은 재제출되지 않음(INCOMPLETE만 대상).

## plan에서 확정할 결정
1. 프로퍼티 키·환경변수 오버라이드 형태(`spring.modulith.events.republish-outstanding-events-on-restart: ${...:true}`), 기본값 노출 정책(로컬/운영 동일 ON 권장).
2. 회복 검증 테스트의 구체 형태(완전 재기동 시뮬레이션 vs 미완료 publication 시드 후 재발행 경로 단언). Modulith 테스트 지원(`spring-modulith-starter-test`)·Testcontainers Kafka 활용.
3. 다중 노드 중복 외부화 주의의 문서화 수준(yml 주석 + plan 트레이드오프 절). 064와의 경계 명시.

## 참고
- ADR-002, Task 004(event-publication-registry), Task 005(notification 컨슈머 idempotency·DLQ), Task 024-1(Modulith Kafka 외부화 serializer fix)
- `docs/rules/event-contract-rule.md`, `docs/rules/verification-gate-rule.md`, `docs/rules/testing-rule.md`
- 현재 설정: `shop-core/src/main/resources/application.yml`(`spring.modulith.events.externalization.enabled=true`), 외부화: `DelegatingEventExternalizer`, 컨슈머 회복(범위 밖): `SearchIndexKafkaConsumerConfig` + `product-search-index-changed.DLQ`
- 후속: Task 064(스케줄 재제출 + `SchedulerLeaderGuard` 리더 게이트 + 미완료 건수 관측)

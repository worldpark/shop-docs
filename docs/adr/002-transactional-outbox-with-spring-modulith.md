# ADR-002 — Spring Modulith Event Publication Registry 기반 Transactional Outbox

- 작성일: 2026-06-10
- 상태: Accepted
- 범위: shop-core 이벤트 발행

## 맥락

`shop-core`는 주문 확정, 결제 실패, 주문 취소, 배송 시작 같은 도메인 이벤트를 Kafka로 발행한다. 이 이벤트들은 `notification`의 입력 계약이므로, 도메인 상태 변경과 이벤트 발행 사이의 불일치를 줄여야 한다.

문제는 DB 트랜잭션과 Kafka 발행이 서로 다른 자원이라는 점이다.

- DB 커밋 후 Kafka 발행에 실패하면 상태는 바뀌었지만 이벤트가 누락된다.
- Kafka 발행 후 DB 커밋이 실패하면 존재하지 않는 상태를 외부에 알릴 수 있다.
- Kafka 발행을 서비스 로직 곳곳에서 직접 처리하면 재시도와 관측 지점이 흩어진다.

검토한 대안은 다음과 같다.

| 대안 | 장점 | 단점 |
|---|---|---|
| 서비스에서 KafkaTemplate 직접 발행 | 단순하고 명시적 | DB 커밋과 발행 원자성 확보 어려움, 재시도 분산 |
| Kafka transaction과 DB transaction 조합 | 강한 일관성에 가까움 | 설정·운영 복잡도 증가, 현재 범위 대비 과함 |
| Transactional Outbox | DB 커밋과 이벤트 저장을 같은 트랜잭션에 묶음 | 외부화 지연과 outbox 관리 필요 |

## 결정

`shop-core`는 Spring Modulith Event Publication Registry를 Transactional Outbox로 사용한다.

- 도메인 상태 변경 트랜잭션 안에서 Spring application event를 발행한다.
- Spring Modulith가 이벤트 publication을 DB에 저장한다.
- 커밋 후 외부화 경로가 Kafka topic으로 이벤트를 발행한다.
- Kafka topic 이름과 payload 계약은 `docs/event-catalog.md`를 따른다.

## 결과

긍정적 결과:

- 도메인 상태 변경과 outbox 저장이 같은 DB 트랜잭션으로 묶인다.
- Kafka 일시 장애가 곧바로 도메인 트랜잭션 실패로 번지지 않는다.
- 이벤트 발행 실패와 재시도 상태를 추적할 수 있다.
- 발행 방식이 서비스 구현에 흩어지지 않는다.

부정적 결과와 대응:

- 이벤트는 커밋 직후 즉시 Kafka에 도달하지 않을 수 있다.
  - 시스템은 최종 일관성을 전제로 설계한다.
- outbox 테이블과 externalization 설정이 운영 대상이 된다.
  - 통합 테스트는 Kafka round-trip보다 event publication 저장과 payload 계약을 우선 검증한다.
- 내부 Spring Modulith 이벤트와 외부 Kafka 이벤트를 혼동할 수 있다.
  - 문서와 패키지에서 shop-core 내부 모듈 이벤트와 프로젝트 간 Kafka 이벤트를 구분한다.

## 관련 문서

- `docs/architecture.md`
- `docs/event-catalog.md`
- `docs/rules/event-contract-rule.md`
- `docs/tasks/backend/004-backend-shop-core-event-publication-registry.md`

# ADR-001 — Kafka 단방향 비동기 통합

- 작성일: 2026-06-10
- 상태: Accepted
- 범위: shop-core, notification

## 맥락

시스템은 독립 배포되는 두 Spring Boot 프로젝트로 구성된다.

- `shop-core`: 회원, 상품, 장바구니, 주문, 결제, 재고를 소유하는 핵심 거래 시스템
- `notification`: 알림 발송과 발송 이력을 소유하는 알림 시스템

두 프로젝트는 서로 다른 책임과 데이터 저장소를 가진다. 알림 실패가 주문·결제 흐름에 영향을 주면 안 되며, notification이 shop-core의 내부 데이터 모델이나 DB 스키마에 결합되어서도 안 된다.

Kafka를 선택하는 주된 이유는 두 가지다.

1. 주문·결제 이후 발생한 알림 이벤트의 유실 위험을 줄인다.
2. 향후 다중 노드 환경에서 producer와 consumer를 독립적으로 수평 확장할 수 있게 한다.

단, 이벤트 유실 위험 감소는 Kafka 단독으로 완성되지 않는다. `shop-core`의 DB 트랜잭션과 이벤트 저장을 함께 묶는 Transactional Outbox가 있어야, 도메인 상태 변경과 이벤트 발행 사이의 간극을 줄일 수 있다.

검토한 대안은 다음과 같다.

| 대안 | 장점 | 단점 |
|---|---|---|
| REST 동기 호출 | 구현이 직관적이고 즉시 결과 확인 가능 | 알림 장애가 주문 흐름에 전파됨, 재시도/타임아웃/장애 격리 부담 증가 |
| 공유 DB 조회 | 초기 구현이 빠름 | 데이터 소유권 붕괴, 스키마 결합, 서비스 경계 훼손 |
| Kafka 비동기 이벤트 | 이벤트 보존, consumer group 기반 수평 확장, 장애 격리, 명확한 계약 기반 통합 | 최종 일관성, 멱등 소비, DLQ 등 운영 규칙 필요 |

## 결정

`shop-core`와 `notification`은 Kafka 이벤트로만, 단방향·비동기로 통합한다.

- `shop-core`는 Kafka producer 역할만 수행한다.
- `notification`은 Kafka consumer 역할만 수행한다.
- `notification`은 consumer group으로 수평 확장할 수 있어야 한다.
- `notification`에서 `shop-core`로 REST 호출하거나 DB를 직접 조회하지 않는다.
- 두 프로젝트는 DB를 공유하지 않는다.
- 프로젝트 간 공유 인터페이스는 이벤트 계약뿐이다.

## 결과

긍정적 결과:

- 알림 장애가 주문·결제 트랜잭션에 직접 영향을 주지 않는다.
- 프로젝트 간 결합 지점이 이벤트 계약으로 제한된다.
- notification은 독립적으로 재시도, DLQ, 발송 이력을 관리할 수 있다.
- notification 다운타임이나 일시 장애가 있어도 Kafka에 남은 이벤트를 기준으로 재처리할 수 있다.
- shop-core와 notification을 각각 독립적으로 다중 노드 확장할 수 있다.
- 포트폴리오 목적상 서비스 경계와 이벤트 드리븐 통합을 명확하게 보여준다.

부정적 결과와 대응:

- 이벤트 발행과 소비는 최종 일관성 모델이다.
  - 사용자는 주문 성공 직후 알림 발송 완료를 동기적으로 보장받지 않는다.
- 컨슈머는 중복 이벤트와 재처리에 대비해야 한다.
  - notification은 eventId 기반 멱등 처리, 재시도, DLQ를 구현한다.
- 이벤트 페이로드가 부족하면 notification이 재조회하고 싶어질 수 있다.
  - 이벤트는 알림 발송에 필요한 데이터를 자족적으로 포함한다.

## 관련 문서

- `docs/architecture.md`
- `docs/event-catalog.md`
- `docs/rules/event-contract-rule.md`
- `docs/rules/forbidden-rule.md`

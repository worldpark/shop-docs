# 005. notification Kafka Consumer 골격 + 멱등 체크 테이블 + DLQ

## Target
notification

---

## Goal
`notification`에서 shop-core 공개 이벤트를 구독하는 Kafka Consumer 골격을 만들고, 이벤트 `eventId` 기반 멱등 처리 이력 테이블과 재시도/DLQ 경로를 구성해 소비 신뢰성의 최소 동작을 검증한다.

---

## Context
- `notification`은 Kafka 컨슈머이며 `shop-core` 이벤트를 구독해 알림 발송을 담당한다
- 두 프로젝트는 Kafka 이벤트로만 단방향·비동기 연결된다
- `notification`은 `shop-core`를 동기 호출하거나 `shop-core` DB를 조회하지 않는다
- 모든 공개 이벤트는 `eventId`와 `occurredAt`을 포함한다
- Consumer는 재시도와 DLQ를 고려해 멱등하게 이벤트를 처리해야 한다
- 현재 알림 채널별 실제 발송(이메일/SMS/푸시)은 후속 Task 범위다

## Requirements
- `docs/event-catalog.md` 기준 공개 이벤트 DTO 정의
  - `OrderCompletedEvent`
  - `PaymentFailedEvent`
  - `ShippingStartedEvent`
- Kafka Consumer 골격 구현
  - topic: `order-completed`, `payment-failed`, `shipping-started`
  - group-id: `notification`
  - 각 Consumer는 Service로 처리를 위임
- Consumer 공통 설정 구현 또는 보강
  - JSON 역직렬화 설정
  - 재시도/backoff 설정
  - DLQ 전송 설정
- DLQ 토픽 규칙 정의
  - 기본: 원본 토픽명 + `.DLQ`
  - 예: `order-completed.DLQ`
- 멱등 처리 이력 Entity/Repository/Service 구현
  - 원본 `eventId`를 유니크 키로 저장
  - 처리 상태를 저장한다
  - 동일 `eventId` 재수신 시 중복 처리하지 않는다
- Consumer는 Repository를 직접 호출하지 않고 Service를 통해 처리한다
- 알림 실제 발송 대신 스텁/로그 기반 처리 Service를 둔다
- 처리 성공/중복/실패/DLQ 이동이 추적 가능하도록 로그를 남긴다
- 관련 단위 테스트와 컨텍스트 테스트를 작성한다

## Constraints
- 공개 이벤트 계약(`docs/event-catalog.md`)을 변경하지 않는다
- `notification`은 `shop-core` 코드, DB, REST API를 참조하지 않는다
- Consumer에서 Repository를 직접 호출하지 않는다
- 실제 알림 발송 구현은 하지 않는다
- REST Controller와 `ServiceResponse`를 만들지 않는다
- Entity를 외부 응답으로 노출하지 않는다
- 실패 처리는 `NotificationException` 등 `RuntimeException` 상속 커스텀 예외 기반을 사용한다
- 재시도 후에도 실패한 메시지는 원본 페이로드와 추적 가능한 헤더를 보존해 DLQ로 보낸다
- 멱등 체크 저장과 처리 상태 변경은 트랜잭션 경계를 명확히 한다

## Files
- `notification/src/main/java/com/shop/notification/consumer/**`
- `notification/src/main/java/com/shop/notification/service/**`
- `notification/src/main/java/com/shop/notification/repository/**`
- `notification/src/main/java/com/shop/notification/domain/**`
- `notification/src/main/java/com/shop/notification/dto/**`
- `notification/src/main/java/com/shop/notification/common/**`
- `notification/src/main/resources/application.yml`
- `notification/src/test/java/com/shop/notification/**`
- `notification/src/test/resources/application.yml`

## Acceptance Criteria
- 애플리케이션 컨텍스트가 Kafka Consumer 설정과 함께 로드된다
- 세 공개 토픽을 구독하는 Consumer 메서드가 존재한다
- Consumer는 Service 계층으로 처리를 위임한다
- 공개 이벤트 DTO가 `docs/event-catalog.md`의 필수 필드를 반영한다
- 멱등 처리 이력 테이블용 Entity가 존재하고 `eventId` 유니크 제약이 있다
- 동일 `eventId` 이벤트를 두 번 처리해도 알림 처리 로직은 한 번만 실행된다
- 정상 처리 시 처리 이력이 성공 상태로 저장된다
- 처리 실패 시 재시도 설정이 적용된다
- 재시도 소진 후 메시지가 원본 토픽별 DLQ 토픽으로 라우팅된다
- Consumer/Service/Repository 레이어 규칙을 위반하지 않는다
- 관련 테스트가 통과한다

## Test
- `./gradlew test`
- 권장 단위 테스트
  - 이벤트 DTO 역직렬화 테스트
  - 멱등 Service 중복 처리 테스트
  - Consumer가 Service를 호출하는 위임 테스트
  - 실패 예외가 retryable/non-retryable 힌트를 보존하는 테스트
- 권장 통합 테스트
  - `spring-kafka-test`의 EmbeddedKafka로 정상 소비, 중복 소비, DLQ 라우팅 검증
  - 테스트 DB가 준비되지 않은 경우 JPA/Kafka 자동설정 제외 정책과 충돌하지 않도록 별도 test profile 또는 슬라이스 테스트로 분리

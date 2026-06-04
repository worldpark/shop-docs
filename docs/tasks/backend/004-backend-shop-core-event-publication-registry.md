# 004. shop-core Event Publication Registry + 더미 이벤트 발행

## Target
shop-core

---

## Goal
`shop-core`에서 Spring Modulith Event Publication Registry 기반의 Transactional Outbox 발행 경로를 구성하고, 도메인 기능 구현 전에 더미 이벤트 발행 엔드포인트로 Kafka 외부화 경로를 조기 검증한다.

---

## Context
- `shop-core`는 Kafka 이벤트 프로듀서다
- 프로젝트 간 통신은 Kafka 이벤트로만 단방향 비동기 처리한다
- `shop-core`는 Transactional Outbox(Spring Modulith Event Publication Registry)로 이벤트를 발행한다
- Phase 1 목적은 실제 도메인 기능 전에 Kafka + Outbox 흐름을 빈 이벤트로 검증하는 것이다
- 더미 이벤트는 스모크 테스트용 내부 이벤트이며 `docs/architecture.md`의 공개 이벤트 계약을 대체하지 않는다

## Requirements
- Spring Modulith Event Publication Registry 설정
- 이벤트 외부화 설정 추가
- Kafka producer 설정 확인 및 보강
- 더미 이벤트 DTO 또는 record 정의
- 더미 이벤트 발행 Service 구현
- 더미 이벤트 발행 REST 엔드포인트 구현
- 이벤트 발행은 트랜잭션 안에서 수행
- 더미 이벤트에 `eventId`와 발생 시각 포함
- 더미 이벤트 발행 성공/실패 로그 추가
- Event Publication Registry 테이블 생성 경로 확인
- 관련 단위 테스트와 컨텍스트 테스트 작성

## Constraints
- 공개 이벤트 계약(`OrderCompletedEvent`, `PaymentFailedEvent`, `ShippingStartedEvent`)은 변경하지 않는다
- 더미 이벤트는 이후 도메인 이벤트와 혼동되지 않도록 명확한 이름과 패키지에 둔다
- Controller에는 비즈니스 로직을 작성하지 않는다
- REST 진입점은 `RestController -> ServiceResponse -> Service -> Repository` 레이어 원칙을 따른다
- Entity를 API 응답으로 직접 반환하지 않는다
- `notification` 코드를 참조하거나 동기 호출하지 않는다
- DB 공유나 notification DB 접근을 만들지 않는다
- 실패한 이벤트 발행이 실제 도메인 기능을 가장하지 않도록 스모크 검증 범위로 제한한다

## Files
- `shop-core/src/main/java/com/shop/shop/**/event/**`
- `shop-core/src/main/java/com/shop/shop/**/controller/**`
- `shop-core/src/main/java/com/shop/shop/**/service/**`
- `shop-core/src/main/java/com/shop/shop/**/dto/**`
- `shop-core/src/main/resources/application.yml`
- `shop-core/src/test/java/com/shop/shop/**`

## Acceptance Criteria
- 애플리케이션 컨텍스트가 Event Publication Registry 설정과 함께 로드된다
- 더미 이벤트 발행 REST 엔드포인트가 Service를 통해 이벤트를 발행한다
- 발행 이벤트에는 `eventId`와 발생 시각이 포함된다
- 이벤트 발행이 트랜잭션 안에서 수행된다
- Kafka producer 설정과 이벤트 외부화 설정이 추적 가능하다
- 공개 이벤트 계약 문서는 변경되지 않는다
- 관련 테스트가 통과한다

## Test
- `./gradlew test`
- 필요 시 로컬 Kafka 기동 후 더미 이벤트 발행 엔드포인트 호출

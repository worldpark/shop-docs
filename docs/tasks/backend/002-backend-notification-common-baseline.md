# 002. notification 공통 기반 클래스

## Target
notification

---

## Goal
`notification`에서 Kafka Consumer, Service, Repository 계층이 재사용할 JPA 공통 엔티티 기반과 내부 오류 모델을 구현한다.

---

## Context
- 이벤트 진입점은 `Consumer -> Service -> Repository` 레이어를 따른다
- REST API가 없으면 Controller와 `ServiceResponse`를 두지 않는다
- 알림 실패는 주문/결제 흐름에 영향을 주지 않는다
- Consumer는 재시도와 DLQ를 고려해 멱등하게 처리해야 한다

## Requirements
- `BaseEntity` 구현
- `ErrorResponse` 또는 내부 오류 추적 모델 구현
- Consumer/Service 계층에서 사용할 커스텀 예외 기반 구현
- JPA auditing 설정이 필요하면 함께 구성
- 공통 엔티티 기반 테스트 작성
- 커스텀 예외 동작 테스트 작성

## Constraints
- `notification`은 `shop-core`를 동기 호출하지 않는다
- `notification`은 `shop-core` DB를 조회하지 않는다
- REST API가 없는 상태에서 Controller를 만들지 않는다
- Consumer에서 Repository를 직접 호출하지 않는다
- 모든 예외는 `RuntimeException` 상속 커스텀 예외로 변환하는 방향을 따른다

## Files
- `notification/src/main/java/com/shop/notification/common/**`
- `notification/src/main/java/com/shop/notification/**/consumer/**`
- `notification/src/main/java/com/shop/notification/**/service/**`
- `notification/src/test/java/com/shop/notification/**`

## Acceptance Criteria
- `BaseEntity`가 알림 도메인 Entity에서 재사용 가능하다
- Consumer/Service에서 사용할 커스텀 예외 기반이 준비된다
- REST Controller 없이도 내부 오류 모델이 테스트 가능하다
- 관련 테스트가 통과한다

## Test
- `./gradlew test`

# 001. shop-core 공통 기반 클래스

## Target
shop-core

---

## Goal
REST와 Thymeleaf View를 함께 가진 `shop-core`에서 재사용할 JPA 공통 엔티티 기반과 예외 응답 기반을 구현한다.

---

## Context
- REST 진입점은 `RestController -> ServiceResponse -> Service -> Repository` 레이어를 따른다
- View 진입점은 `ViewController(@Controller) -> Service -> Repository` 레이어를 따른다
- `ServiceResponse`는 REST 응답 조합 전용이며 View에서는 사용하지 않는다
- ViewController는 Entity를 모델에 직접 담지 않는다

## Requirements
- `BaseEntity` 구현
- `ErrorResponse` 구현
- REST용 `GlobalExceptionHandler` 구현
- View용 예외 처리 분리
- 공통 커스텀 예외 베이스 방향 정리
- JPA auditing 설정이 필요하면 함께 구성
- REST 예외 응답 테스트 작성
- View 예외 분기 테스트 작성

## Constraints
- Entity를 API 응답으로 직접 반환하지 않는다
- View 모델에 Entity를 직접 전달하지 않는다
- 모든 예외는 `RuntimeException` 상속 커스텀 예외로 변환하는 방향을 따른다
- 에러 응답 공통 포맷은 REST API에만 적용한다
- Controller에서 비즈니스 로직을 작성하지 않는다

## Files
- `shop-core/src/main/java/com/shop/shop/common/**`
- `shop-core/src/main/java/com/shop/shop/**/controller/**`
- `shop-core/src/test/java/com/shop/shop/**`

## Acceptance Criteria
- REST 요청 예외 시 공통 JSON 포맷이 반환된다
- View 요청 예외 시 JSON 응답이 아니라 에러 뷰 또는 View 전용 처리로 분기된다
- `BaseEntity`가 도메인 Entity에서 재사용 가능하다
- 관련 테스트가 통과한다

## Test
- `./gradlew test`

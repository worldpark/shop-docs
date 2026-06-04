# 002. notification 의존성 베이스라인

## Target
notification

---

## Goal
`notification`이 Kafka 이벤트를 소비하고 자기 PostgreSQL에 알림 이력과 멱등 처리 데이터를 저장할 수 있도록 Gradle 의존성과 기본 설정을 구성한다.

---

## Context
- Java 21
- Spring Boot 3.5.15-SNAPSHOT
- 독립 Gradle 프로젝트
- `notification`은 shop-core 이벤트를 구독하는 비동기 알림 서비스다
- REST API가 없으면 Controller와 `ServiceResponse`를 두지 않는다

## Requirements
- JPA 의존성 추가
- PostgreSQL 드라이버 추가
- Spring Kafka 의존성 추가
- Validation 의존성 추가
- 테스트 의존성 정리
- 현재 `web` 의존성 유지 필요 여부 검토
- 필요 시 기본 `application.yml` 생성

## Constraints
- 상위 워크스페이스 루트 `shop/`에서 하네스를 실행한다
- 실제 빌드/테스트는 `notification/`에서 수행한다
- `notification`은 `shop-core`를 동기 호출하지 않는다
- `notification`은 `shop-core` DB를 조회하지 않는다
- 이벤트 계약 변경은 하지 않는다
- 테스트 없이 의존성 변경을 완료 처리하지 않는다

## Files
- `notification/build.gradle`
- `notification/src/main/resources/application.yml`
- `notification/src/test/java/**`

## Acceptance Criteria
- Gradle 의존성 해석이 성공한다
- 애플리케이션 컨텍스트가 로드된다
- 기본 테스트가 통과한다
- 이벤트 소비와 JPA 개발에 필요한 의존성이 준비된다

## Test
- `./gradlew test`

# 001. shop-core 의존성 베이스라인

## Target
shop-core

---

## Goal
`shop-core`가 회원, 상품, 장바구니, 주문, 결제, 재고 도메인 개발과 Thymeleaf SSR 화면 개발을 시작할 수 있도록 Gradle 의존성과 기본 설정을 구성한다.

---

## Context
- Java 21
- Spring Boot 3.5.15-SNAPSHOT
- 독립 Gradle 프로젝트
- `shop-core`는 쇼핑몰 핵심 도메인과 Thymeleaf SSR 화면을 함께 호스팅한다
- 이후 backend/frontend Phase 0 작업의 선행 조건이다

## Requirements
- JPA 의존성 추가
- PostgreSQL 드라이버 추가
- Validation 의존성 추가
- Thymeleaf 의존성 추가
- Spring Security 의존성 추가
- Spring Modulith 의존성 추가
- Spring Kafka 의존성 추가
- 테스트 의존성 정리
- 필요 시 기본 `application.yml` 생성

## Constraints
- 상위 워크스페이스 루트 `shop/`에서 하네스를 실행한다
- 실제 빌드/테스트는 `shop-core/`에서 수행한다
- `shop-core`는 `notification` 코드나 DB에 의존하지 않는다
- 이벤트 계약 변경은 하지 않는다
- 테스트 없이 의존성 변경을 완료 처리하지 않는다

## Files
- `shop-core/build.gradle`
- `shop-core/src/main/resources/application.yml`
- `shop-core/src/test/java/**`

## Acceptance Criteria
- Gradle 의존성 해석이 성공한다
- 애플리케이션 컨텍스트가 로드된다
- 기본 테스트가 통과한다
- 의존성 충돌이나 누락된 starter가 없다

## Test
- `./gradlew test`

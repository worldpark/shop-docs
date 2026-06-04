# 005. Redis 의존성 + 로컬 인프라 구성

## Target
workspace

---

## Goal
`shop-core`와 `notification`에 Redis 의존성과 기본 설정을 추가하고, 로컬 Docker Compose에서 Redis를 기동해 각 프로젝트가 자기 용도에 맞게 Redis를 사용할 수 있는 기반을 구성한다.

---

## Context
- 두 프로젝트는 독립 배포되는 Spring Boot 프로젝트다
- 프로젝트 간 통신은 Kafka 이벤트로만 단방향·비동기 처리한다
- Redis는 프로젝트 간 동기 통신 채널이 아니라 각 프로젝트의 보조 저장소/캐시로 사용한다
- `shop-core` 로그인 방식은 JWT다
- `shop-core`는 Redis를 로그인 정보 저장과 분산락 처리에 사용한다
- `notification`은 Redis를 알림 중복 발생 방지에 사용한다
- 실제 로그인 구현, JWT 발급/검증 구현, 알림 발송 구현은 후속 Task 범위다

## Requirements
- `shop-core`에 Redis 의존성 추가
  - Spring Data Redis starter
  - 필요 시 Redisson 또는 분산락 라이브러리 검토 후 추가
- `notification`에 Redis 의존성 추가
  - Spring Data Redis starter
- 두 프로젝트의 `application.yml`에 Redis 접속 설정 추가
- 로컬 Docker Compose에 Redis 컨테이너 추가
  - 파일 위치: `docker/shop/docker-compose.yml`
  - 컨테이너 이름은 `shop-redis` 규칙을 따른다
  - 기본 포트는 `6379`
  - 로컬 개발용임을 명확히 한다
- `shop-core` Redis key namespace 설계
  - 로그인 정보/JWT 상태 저장용 key prefix
  - refresh token 또는 로그인 세션 상태 저장 방향
  - access token blacklist가 필요하면 key prefix와 TTL 정책 정의
  - 분산락 key prefix와 TTL 정책 정의
- `notification` Redis key namespace 설계
  - 알림 중복 방지용 key prefix
  - 원본 이벤트 `eventId` 또는 알림 중복 판단 키 기준 정의
  - TTL 정책 정의
- Redis 연결 설정 Bean 또는 설정 클래스를 프로젝트별 패키지 구조에 맞게 추가
- RedisTemplate 또는 StringRedisTemplate 사용 방식을 결정한다
- 관련 컨텍스트 테스트와 설정 테스트를 작성한다

## Constraints
- Redis를 `shop-core`와 `notification` 사이의 직접 통신 수단으로 사용하지 않는다
- `notification`이 Redis를 통해 `shop-core` 로그인 정보나 도메인 데이터를 읽지 않는다
- `shop-core`와 `notification`은 Redis key namespace를 분리한다
- JWT 로그인 구현 자체는 이 Task에서 하지 않는다
- 분산락 적용 대상 도메인 로직은 이 Task에서 구현하지 않는다
- 알림 실제 발송과 Consumer 처리 로직 변경은 이 Task에서 하지 않는다
- Redis 장애가 주문/결제 흐름 전체를 가장하지 않도록, 실제 사용 Task에서 fallback/예외 정책을 별도로 정의한다
- 운영용 Redis 보안/클러스터 구성을 가장하지 않고 로컬 개발용 단일 Redis로 둔다
- 테스트 없이 의존성 변경을 완료 처리하지 않는다

## Files
- `docker/shop/docker-compose.yml`
- `shop-core/build.gradle`
- `shop-core/src/main/resources/application.yml`
- `shop-core/src/test/resources/application.yml`
- `shop-core/src/main/java/com/shop/shop/common/**`
- `shop-core/src/test/java/com/shop/shop/**`
- `notification/build.gradle`
- `notification/src/main/resources/application.yml`
- `notification/src/test/resources/application.yml`
- `notification/src/main/java/com/shop/notification/common/**`
- `notification/src/test/java/com/shop/notification/**`

## Acceptance Criteria
- 로컬 Docker Compose에 `shop-redis` 컨테이너가 추가된다
- `docker compose -f docker/shop/docker-compose.yml config`가 성공한다
- `shop-core`와 `notification` 모두 Redis 의존성을 가진다
- 두 프로젝트 모두 Redis 접속 설정이 `application.yml`에서 추적 가능하다
- `shop-core`의 Redis 용도가 JWT 로그인 정보 저장과 분산락 처리로 문서/설정에서 구분된다
- `notification`의 Redis 용도가 알림 중복 발생 방지로 문서/설정에서 구분된다
- Redis key prefix가 프로젝트별로 충돌하지 않는다
- 테스트 프로파일에서 Redis 자동설정 처리 방식이 명확하다
- 두 프로젝트의 애플리케이션 컨텍스트 테스트가 통과한다
- 기존 Kafka 이벤트 계약과 DB 스키마 계약을 변경하지 않는다

## Test
- `docker compose -f docker/shop/docker-compose.yml config`
- `docker compose -f docker/shop/docker-compose.yml up -d`
- Redis 컨테이너 확인
  - `docker exec -it shop-redis redis-cli ping`
  - 기대 결과: `PONG`
- `./gradlew test` (`shop-core/`)
- `./gradlew test` (`notification/`)
- 권장 설정 테스트
  - `shop-core` Redis properties 바인딩 테스트
  - `notification` Redis properties 바인딩 테스트
  - key prefix/TTL 설정 값 검증 테스트

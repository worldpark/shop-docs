# 006. shop-core JWT 로그인 + Redis 로그인 상태 + 계층형 권한

## Target
shop-core

---

## Goal
`shop-core`의 사용자 로그인 처리를 JWT 방식으로 구현하고, 로그인 상태와 토큰 관리를 Redis에 저장하며, `ADMIN > SELLER > CONSUMER` 계층형 권한 모델을 구성한다.

---

## Context
- `shop-core`는 회원·상품·장바구니·주문·결제·재고를 담당한다
- 회원 로그인은 `member` 도메인 책임이다
- 보안 필터, JWT 검증, 권한 계층 설정은 `security` 지원 모듈 책임이다
- 기존 보안 골격은 Thymeleaf 폼 로그인 + 개발용 InMemoryUserDetailsManager 기반이다
- 이번 Task에서는 REST 로그인 API 기반 JWT 인증으로 전환한다
- Redis는 로그인 정보 저장, refresh token 상태 관리, logout/blacklist 처리에 사용한다
- 권한은 `ADMIN > SELLER > CONSUMER` 계층으로 설계한다
- 회원가입, 비밀번호 재설정, OAuth2, 실제 관리자/판매자 가입 심사는 후속 Task 범위다

## Requirements
- JWT 관련 의존성 추가
  - Spring Security JWT 지원 또는 별도 JWT 라이브러리 선택
  - 선택 이유를 작업 문서 또는 주석에 남긴다
- `member` 도메인에 로그인 대상 사용자 Entity/Repository/Service 구현
  - 이메일 또는 username 기반 로그인 식별자
  - BCrypt 기반 password hash 검증
  - 권한 필드: `ADMIN`, `SELLER`, `CONSUMER`
- 기존 InMemoryUserDetailsManager 기반 개발용 로그인은 제거하거나 test/dev 전용으로 격리
- REST 로그인 API 구현
  - `POST /api/v1/auth/login`
  - `POST /api/v1/auth/refresh`
  - `POST /api/v1/auth/logout`
  - 필요 시 `GET /api/v1/auth/me`
- Login/Refresh/Logout 요청·응답 DTO 구현
- JWT access token 발급 구현
- refresh token 발급 및 Redis 저장 구현
- Redis에 로그인 정보 저장
  - 사용자별 refresh token 또는 token family 저장
  - 로그인 세션 상태 저장
  - logout 시 refresh token 제거
  - 필요 시 access token blacklist 저장
- JWT 인증 필터 구현
  - `Authorization: Bearer {token}` 검증
  - 유효한 토큰이면 SecurityContext에 인증 정보 설정
  - 만료/위조/형식 오류는 401 처리
- Spring Security 설정 전환
  - REST API는 JWT 기반 stateless 인증
  - `/api/v1/auth/login`, `/api/v1/auth/refresh`는 공개
  - 보호 REST 경로는 인증 필요
  - Thymeleaf View 경로 정책은 유지하거나 별도 후속 Task로 분리하되 충돌 없이 처리
- Role hierarchy 설정
  - `ROLE_ADMIN > ROLE_SELLER`
  - `ROLE_SELLER > ROLE_CONSUMER`
- 권한 체크 테스트 작성
  - ADMIN은 SELLER/CONSUMER 권한 리소스 접근 가능
  - SELLER는 CONSUMER 권한 리소스 접근 가능
  - CONSUMER는 상위 권한 리소스 접근 불가
- Redis key namespace와 TTL 정책 구현
  - 예: `shop-core:auth:refresh:{userId}`
  - 예: `shop-core:auth:blacklist:{jti}`
  - access token TTL과 refresh token TTL 분리
- 인증 실패/권한 없음은 REST 에러 응답 규칙에 맞게 처리
- 관련 단위 테스트, Security MockMvc 테스트, 컨텍스트 테스트 작성

## Constraints
- `notification` 코드나 DB를 참조하지 않는다
- Redis를 프로젝트 간 통신 수단으로 사용하지 않는다
- JWT secret/key를 코드에 하드코딩하지 않는다
- 비밀번호 원문을 저장하거나 로그로 남기지 않는다
- refresh token 원문 저장 여부는 보안 관점에서 검토하고, 가능하면 hash 저장을 우선한다
- Controller에서 비즈니스 로직을 작성하지 않는다
- REST 진입점은 `RestController -> ServiceResponse -> Service -> Repository` 레이어를 따른다
- DTO와 Entity를 분리한다
- Entity를 API 응답으로 직접 반환하지 않는다
- 모든 예외는 `RuntimeException` 상속 커스텀 예외로 변환한다
- REST 인증/인가 실패는 View 로그인 리다이렉트와 섞지 않는다
- DB role CHECK 제약 또는 Flyway 마이그레이션이 기존 `database_design.md`와 다르면 이유를 작업 문서에 남긴다

## Files
- `shop-core/build.gradle`
- `shop-core/src/main/resources/application.yml`
- `shop-core/src/test/resources/application.yml`
- `shop-core/src/main/java/com/shop/shop/security/**`
- `shop-core/src/main/java/com/shop/shop/member/controller/**`
- `shop-core/src/main/java/com/shop/shop/member/service/**`
- `shop-core/src/main/java/com/shop/shop/member/repository/**`
- `shop-core/src/main/java/com/shop/shop/member/domain/**`
- `shop-core/src/main/java/com/shop/shop/member/dto/**`
- `shop-core/src/main/java/com/shop/shop/common/exception/**`
- `shop-core/src/main/resources/db/migration/**`
- `shop-core/src/test/java/com/shop/shop/security/**`
- `shop-core/src/test/java/com/shop/shop/member/**`

## Acceptance Criteria
- `POST /api/v1/auth/login`이 유효한 사용자 자격증명으로 access token과 refresh token을 발급한다
- 로그인 성공 시 Redis에 로그인 상태 또는 refresh token 상태가 저장된다
- 잘못된 비밀번호로 로그인하면 401 응답을 반환한다
- `Authorization: Bearer {accessToken}`으로 보호 API 접근 시 인증이 설정된다
- 만료/위조/형식 오류 JWT는 401 응답을 반환한다
- `POST /api/v1/auth/refresh`가 Redis에 저장된 유효한 refresh token으로 새 access token을 발급한다
- `POST /api/v1/auth/logout`이 Redis의 로그인 정보를 제거하거나 토큰을 무효화한다
- logout 이후 동일 refresh token으로 재발급할 수 없다
- Role hierarchy가 `ADMIN > SELLER > CONSUMER` 순서로 동작한다
- 하위 권한은 상위 권한 리소스에 접근할 수 없다
- JWT secret/key, token TTL, Redis key prefix가 설정으로 추적 가능하다
- 기존 Thymeleaf View 보안 흐름과 REST JWT 흐름이 충돌하지 않는다
- 관련 테스트가 통과한다

## Test
- `./gradlew test`
- 권장 단위 테스트
  - JWT 발급/검증/만료 테스트
  - Redis refresh token 저장/조회/삭제 테스트
  - 로그인 Service 성공/실패 테스트
  - logout 후 refresh token 재사용 실패 테스트
  - Role hierarchy 매핑 테스트
- 권장 MockMvc 테스트
  - `POST /api/v1/auth/login` 성공/실패
  - Bearer token 인증 성공
  - 토큰 없음/잘못된 토큰 401
  - 권한별 접근 허용/차단
- 권장 Redis 검증
  - 로컬 실행 시 `docker exec -it shop-redis redis-cli keys "shop-core:auth:*"`로 key namespace 확인
  - 테스트에서는 embedded Redis 대신 Redis 관련 컴포넌트를 mock/fake로 격리하거나 Testcontainers 도입 여부를 별도 판단

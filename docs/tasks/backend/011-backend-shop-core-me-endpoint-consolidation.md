# 011. shop-core /me 엔드포인트 중복 정리

## Target
shop-core

---

## Goal
`shop-core`의 내 정보 조회 API를 `GET /api/v1/members/me`로 일원화하고, 중복 구현인 `GET /api/v1/auth/me`를 제거해 회원 도메인 API 표면과 테스트를 정리한다.

---

## Context
- `006`에서 JWT 로그인 구현과 함께 `GET /api/v1/auth/me`가 추가되었다
- `007`에서 회원 도메인 API로 `GET /api/v1/members/me`가 추가되며 동일 응답과 동일 principal 추출 로직이 중복되었다
- 현재 두 엔드포인트는 모두 `MeResponse.from(User)`를 반환한다
- 현재 두 엔드포인트는 모두 JWT 인증 후 `Authentication.getPrincipal()`의 `userId(long)`로 회원을 조회한다
- 도메인 의미상 내 회원 정보 조회는 `member` API인 `GET /api/v1/members/me`를 canonical API로 유지한다
- 인증 도메인(`auth`)은 로그인, 토큰 재발급, 로그아웃 책임에 집중한다
- API 변경이므로 `docs/rules/api-authorization-rule.md`를 따른다

## API Authorization

| API | 공개 여부 | 최소 권한 | 상위 권한 허용 | 소유권 검사 | 비고 |
|---|---|---|---|---|---|
| `GET /api/v1/members/me` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | principal userId 기준 본인 정보 조회 |
| `GET /api/v1/auth/me` | 제거 | - | - | - | 중복 API 제거 대상 |

## Requirements
- `GET /api/v1/members/me`를 내 정보 조회 canonical API로 유지한다
- `GET /api/v1/auth/me` 매핑을 제거한다
- `AuthRestController`에서 `/me` handler를 제거한다
- `AuthServiceResponse`에서 `me(Authentication)` 중복 메서드를 제거한다
- `AuthServiceResponse`는 로그인, refresh, logout 응답 조합 책임만 가진다
- `MemberRestController`의 `/me` handler는 유지한다
- `MemberServiceResponse.me(Authentication)`는 유지한다
- `MeResponse` 응답 필드와 의미는 변경하지 않는다
- principal 규약은 기존대로 `userId(long)`를 사용한다
- JWT 발급, refresh, logout 로직은 변경하지 않는다
- REST 에러 응답은 기존 `ErrorResponse` 포맷을 유지한다
- 제거된 `/api/v1/auth/me`를 검증하던 테스트를 삭제하거나 canonical API 기준으로 정리한다
- `GET /api/v1/members/me` 권한/인증 테스트를 보강한다
- API 응답에 Entity를 직접 노출하지 않는다
- Controller에서 비즈니스 로직을 작성하지 않는다

## Constraints
- 회원가입, 로그인, refresh, logout 동작을 변경하지 않는다
- JWT 토큰 claim, principal 타입, RoleHierarchy를 변경하지 않는다
- `MeResponse` 구조를 변경하지 않는다
- 새 API를 추가하지 않는다
- View/Thymeleaf 화면은 변경하지 않는다
- DB schema와 Flyway migration을 변경하지 않는다
- `notification` 코드나 DB를 참조하지 않는다
- 이벤트 계약은 변경하지 않는다
- `/api/v1/auth/me` 호환 alias를 남기지 않는다

## Files
- `shop-core/src/main/java/com/shop/shop/member/controller/AuthRestController.java`
- `shop-core/src/main/java/com/shop/shop/member/controller/MemberRestController.java`
- `shop-core/src/main/java/com/shop/shop/member/service/AuthServiceResponse.java`
- `shop-core/src/main/java/com/shop/shop/member/service/MemberServiceResponse.java`
- `shop-core/src/main/java/com/shop/shop/member/dto/MeResponse.java`
- `shop-core/src/test/java/com/shop/shop/security/AuthRestControllerSecurityTest.java`
- `shop-core/src/test/java/com/shop/shop/member/controller/MemberRestControllerTest.java`
- `shop-core/src/test/java/com/shop/shop/member/service/AuthServiceResponseTest.java`
- `shop-core/src/test/java/com/shop/shop/member/service/MemberServiceResponseTest.java`

## Acceptance Criteria
- `GET /api/v1/members/me`는 유효한 Bearer access token으로 200과 `MeResponse`를 반환한다
- `GET /api/v1/members/me`는 `CONSUMER`, `SELLER`, `ADMIN` 모두 접근할 수 있다
- `GET /api/v1/members/me`는 비인증 요청에 401 JSON을 반환한다
- `GET /api/v1/members/me`는 위조되었거나 만료되었거나 blacklist된 access token에 401 JSON을 반환한다
- `GET /api/v1/auth/me`는 더 이상 `MeResponse`를 반환하지 않는다
- `AuthRestController`는 login, refresh, logout 엔드포인트만 가진다
- `AuthServiceResponse`는 `me(Authentication)` 중복 메서드를 가지지 않는다
- `MemberServiceResponse.me(Authentication)`가 principal userId로 `MemberService.getById`를 호출한다
- login, refresh, logout 기존 테스트는 통과한다
- 회원가입 기존 테스트는 통과한다
- 응답에 password/passwordHash/password_hash가 포함되지 않는다
- 관련 테스트가 통과한다

## Test
- `./gradlew test`
- 권장 단위 테스트
  - `MemberServiceResponse.me`가 principal userId를 추출해 `MemberService.getById`에 위임한다
  - `MemberServiceResponse.me`가 `MeResponse`로 변환하고 password 관련 필드를 노출하지 않는다
  - `AuthServiceResponseTest`에서 제거된 `me` 테스트를 삭제하고 login/refresh/logout 테스트만 유지한다
- 권장 REST/Security 테스트
  - `GET /api/v1/members/me` CONSUMER 200
  - `GET /api/v1/members/me` SELLER 200
  - `GET /api/v1/members/me` ADMIN 200
  - `GET /api/v1/members/me` 비인증 401 JSON
  - `GET /api/v1/members/me` 위조 토큰 401 JSON
  - `GET /api/v1/members/me` logout 후 blacklist access token 401
  - `GET /api/v1/auth/me`가 더 이상 200 `MeResponse`를 반환하지 않음
  - `POST /api/v1/auth/login` 성공/실패 기존 동작 유지
  - `POST /api/v1/auth/refresh` 기존 동작 유지
  - `POST /api/v1/auth/logout` 기존 동작 유지
- 권장 회귀 테스트
  - `POST /api/v1/members/signup` public 201 유지
  - `POST /api/v1/members/signup` 검증 실패 400 유지
  - `POST /api/v1/members/signup` 중복 이메일 409 유지

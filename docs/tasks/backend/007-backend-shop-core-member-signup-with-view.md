# 007. shop-core 회원가입 + 회원가입 화면

## Target
shop-core

---

## Goal
`shop-core`에서 일반 사용자(`CONSUMER`) 회원가입 API와 Thymeleaf 회원가입 화면을 구현해, 사용자가 화면에서 가입하고 JWT 로그인으로 이어질 수 있는 회원 도메인 기본 흐름을 완성한다.

---

## Context
- `member` 모듈은 회원 가입·로그인·마이페이지를 담당한다
- API 추가 시 `docs/rules/api-authorization-rule.md`를 참고해야 한다
- 회원가입 API는 public API다
- 권한 계층은 `ADMIN > SELLER > CONSUMER`다
- 일반 회원가입으로 생성되는 기본 권한은 `CONSUMER`다
- `SELLER`와 `ADMIN` 생성/권한 변경은 후속 관리자 Task 범위다
- 로그인/JWT/Redis 로그인 상태 관리는 `006-backend-shop-core-jwt-login-redis-role-hierarchy.md`에서 진행 중이다
- Kakao OAuth2 로그인은 후속 확장 범위다. 이번 Task는 이메일/비밀번호 기반 일반 회원가입만 구현한다
- 이번 Task는 화면까지 포함한다

## API Authorization

| API | 공개 여부 | 최소 권한 | 상위 권한 허용 | 소유권 검사 | 비고 |
|---|---|---|---|---|---|
| `GET /signup` | public | 없음 | 해당 없음 | 불필요 | 회원가입 화면 |
| `POST /signup` | public | 없음 | 해당 없음 | 불필요 | View 폼 제출 |
| `POST /api/v1/members/signup` | public | 없음 | 해당 없음 | 불필요 | REST 회원가입 |
| `GET /api/v1/members/me` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 본인 정보만 조회 |

## Requirements
- 회원 Entity/Repository/Service 구현 또는 `006`에서 구현된 사용자 모델과 정합성 유지
- 회원가입 요청 DTO 구현
  - email
  - password
  - passwordConfirm
  - name
  - phone(optional)
- 회원가입 응답 DTO 구현
  - memberId
  - email
  - name
  - role
- 비밀번호는 BCrypt로 hash 저장
- 회원가입 기본 role은 `CONSUMER`
- 이메일 중복 검증
- 이메일 형식 검증
- 비밀번호 정책 검증
  - 최소 길이
  - password/passwordConfirm 일치
  - 정책 세부값은 구현 시 상수 또는 설정으로 추적 가능하게 둔다
- View 회원가입 화면 구현
  - `GET /signup`
  - `POST /signup`
  - 성공 시 로그인 화면 또는 로그인 완료 흐름으로 이동
  - 실패 시 입력값과 검증 메시지를 회원가입 화면에 표시
- REST 회원가입 API 구현
  - `POST /api/v1/members/signup`
  - JSON 요청/응답
  - 성공 시 201 Created
- 내 정보 조회 API 구현
  - `GET /api/v1/members/me`
  - JWT 인증 사용자 기준 조회
  - Entity 직접 반환 금지
- ViewController는 view name 또는 `ModelAndView`를 반환하고 모델에는 DTO/ViewModel만 담는다
- REST Controller는 ServiceResponse를 통해 응답 DTO를 반환한다
- 회원가입 성공/실패 로그는 민감 정보 없이 남긴다
- 관련 단위 테스트, MVC 테스트, 템플릿 렌더링 테스트를 작성한다

## Constraints
- `SELLER`, `ADMIN` 가입을 public으로 열지 않는다
- Kakao OAuth2 로그인, 소셜 계정 연동, 비밀번호 없는 계정 처리는 구현하지 않는다
- 회원 식별자와 인증 방식 모델은 Kakao OAuth2 확장을 과도하게 막지 않도록 이름과 책임을 분리한다
- 비밀번호 원문을 DB, 로그, 응답, View 모델에 남기지 않는다
- Controller에서 비즈니스 로직을 작성하지 않는다
- DTO와 Entity를 분리한다
- Entity를 API 응답이나 View 모델에 직접 전달하지 않는다
- REST 에러 응답은 `docs/rules/error-response-rule.md`를 따른다
- View 실패 응답은 REST JSON이 아니라 Thymeleaf 화면으로 렌더링한다
- `notification` 코드나 DB를 참조하지 않는다
- 이벤트 계약은 변경하지 않는다
- DB role CHECK 제약이 `ADMIN/SELLER/CONSUMER`와 맞지 않으면 Flyway 마이그레이션 또는 문서 정합성을 함께 맞춘다
- DB 소유 시간 컬럼(`created_at`, `updated_at`)은 Entity에서 읽기 전용 매핑한다

## Files
- `shop-core/src/main/java/com/shop/shop/member/controller/**`
- `shop-core/src/main/java/com/shop/shop/member/service/**`
- `shop-core/src/main/java/com/shop/shop/member/repository/**`
- `shop-core/src/main/java/com/shop/shop/member/domain/**`
- `shop-core/src/main/java/com/shop/shop/member/dto/**`
- `shop-core/src/main/java/com/shop/shop/common/exception/**`
- `shop-core/src/main/java/com/shop/shop/security/**`
- `shop-core/src/main/resources/templates/member/signup.html`
- `shop-core/src/main/resources/templates/auth/login.html`
- `shop-core/src/main/resources/templates/fragments/**`
- `shop-core/src/main/resources/static/**`
- `shop-core/src/main/resources/db/migration/**`
- `shop-core/src/test/java/com/shop/shop/member/**`
- `shop-core/src/test/java/com/shop/shop/security/**`

## Backend - View Contract

| 항목 | 값 |
|---|---|
| 회원가입 화면 경로 | `GET /signup` |
| 회원가입 View name | `member/signup` |
| 회원가입 템플릿 | `templates/member/signup.html` |
| 회원가입 폼 action | `POST /signup` |
| 폼 필드명 | `email`, `password`, `passwordConfirm`, `name`, `phone` |
| 성공 리다이렉트 | `/login?signup` |
| 실패 렌더링 | `member/signup` |
| 실패 모델 키 | `signupForm`, `errors` 또는 Spring BindingResult |
| REST signup API | `POST /api/v1/members/signup` |
| 내 정보 API | `GET /api/v1/members/me` |

## Acceptance Criteria
- `GET /signup`이 회원가입 화면을 렌더링한다
- 회원가입 화면은 공통 레이아웃/프래그먼트를 사용한다
- 회원가입 폼은 CSRF 토큰과 함께 렌더링된다
- 유효한 폼 제출 시 `CONSUMER` 권한 회원이 생성되고 `/login?signup`으로 이동한다
- 유효하지 않은 폼 제출 시 회원가입 화면에 검증 메시지가 표시된다
- `POST /api/v1/members/signup`이 유효한 JSON 요청으로 회원을 생성하고 201 응답을 반환한다
- 중복 이메일 가입 요청은 실패한다
- 저장된 비밀번호는 BCrypt hash다
- 회원가입 응답에 password/passwordHash가 포함되지 않는다
- `GET /api/v1/members/me`는 인증된 사용자 본인 정보를 반환한다
- 비인증 사용자의 `GET /api/v1/members/me` 요청은 401이다
- 기존 JWT 로그인 Task와 사용자 모델/권한 모델이 충돌하지 않는다
- 관련 테스트가 통과한다

## Test
- `./gradlew test`
- 권장 단위 테스트
  - 회원가입 성공
  - 이메일 중복 실패
  - 비밀번호 불일치 실패
  - 비밀번호 hash 저장 검증
  - 기본 role `CONSUMER` 검증
- 권장 REST 테스트
  - `POST /api/v1/members/signup` 성공 201
  - 검증 실패 400
  - 중복 이메일 409
  - `GET /api/v1/members/me` 인증 성공/비인증 401
- 권장 View 테스트
  - `GET /signup` 렌더링
  - CSRF 포함 확인
  - 폼 제출 성공 redirect
  - 폼 제출 실패 시 `member/signup` 재렌더링
  - login 화면에 회원가입 링크 또는 성공 메시지 표시

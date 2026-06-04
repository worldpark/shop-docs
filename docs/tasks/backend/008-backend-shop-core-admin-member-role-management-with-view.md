# 008. shop-core 관리자 회원 권한 관리 + 화면

## Target
shop-core

---

## Goal
`shop-core`에서 `ADMIN` 사용자가 회원 목록을 조회하고 회원 권한을 `CONSUMER` 또는 `SELLER`로 변경할 수 있는 REST API와 Thymeleaf 관리자 화면을 구현한다.

---

## Context
- 권한 계층은 `ADMIN > SELLER > CONSUMER`다
- 일반 회원가입은 `CONSUMER`만 생성한다
- `SELLER` 권한은 public 가입으로 열지 않고 관리자 권한 관리로 부여한다
- 상품 등록/수정 기능은 `SELLER` 이상 권한이 필요하므로, 상품 Task 전에 판매자 권한 부여 흐름이 필요하다
- API 추가 시 `docs/rules/api-authorization-rule.md`를 따른다
- 회원 도메인 내부 기능이므로 `member` 모듈에 둔다
- 이번 Task는 관리자 화면까지 포함한다

## API Authorization

| API | 공개 여부 | 최소 권한 | 상위 권한 허용 | 소유권 검사 | 비고 |
|---|---|---|---|---|---|
| `GET /admin/members` | authenticated | `ROLE_ADMIN` | 없음 | 불필요 | 관리자 회원 목록 화면 |
| `POST /admin/members/{memberId}/role` | authenticated | `ROLE_ADMIN` | 없음 | 불필요 | View 권한 변경 폼 제출 |
| `GET /api/v1/admin/members` | authenticated | `ROLE_ADMIN` | 없음 | 불필요 | 관리자 회원 목록 API |
| `PATCH /api/v1/admin/members/{memberId}/role` | authenticated | `ROLE_ADMIN` | 없음 | 불필요 | 회원 권한 변경 API |

## Requirements
- 관리자 회원 목록 API 구현
  - 검색 조건: email 또는 name
  - role 필터: `ADMIN`, `SELLER`, `CONSUMER`
  - 페이지네이션
- 관리자 회원 권한 변경 API 구현
  - 변경 가능 role: `SELLER`, `CONSUMER`
  - `ADMIN` 승격/강등은 이번 Task에서 제외하거나 별도 명시적 정책으로 막는다
- 관리자 회원 목록 화면 구현
  - `GET /admin/members`
  - 회원 목록, 이메일, 이름, 현재 권한, 가입일 표시
  - 검색/필터 UI
  - 권한 변경 폼
- 권한 변경 폼 제출 구현
  - `POST /admin/members/{memberId}/role`
  - 성공 시 목록 화면으로 redirect
  - 실패 시 오류 메시지 표시
- REST Controller는 `RestController -> ServiceResponse -> Service -> Repository` 레이어를 따른다
- ViewController는 `ViewController(@Controller) -> Service -> Repository` 레이어를 따른다
- 권한 변경은 트랜잭션 안에서 수행한다
- 권한 변경 성공/실패 로그를 남긴다
- 권한 변경 후 기존 JWT/Redis 로그인 상태 처리 정책을 정한다
  - 권한 변경 즉시 반영이 필요하면 해당 사용자의 refresh/login state를 무효화한다
  - 즉시 반영하지 않으면 access token 만료 후 반영됨을 작업 문서에 명시한다
- 관련 단위 테스트, Security 테스트, View 렌더링 테스트를 작성한다

## Constraints
- `ADMIN` API는 `ADMIN`만 접근 가능하다
- `SELLER`, `CONSUMER`는 관리자 회원 API와 화면에 접근할 수 없다
- public API로 role 변경을 열지 않는다
- 자기 자신의 `ADMIN` 권한 제거는 막는다
- 마지막 `ADMIN` 계정의 권한 제거를 막는다
- 비밀번호 hash, refresh token, Redis 로그인 상태 등 민감 정보를 목록/API/View에 노출하지 않는다
- Entity를 API 응답이나 View 모델에 직접 전달하지 않는다
- Controller에서 비즈니스 로직을 작성하지 않는다
- `notification` 코드나 DB를 참조하지 않는다
- 이벤트 계약은 변경하지 않는다
- `COMPANY` 권한은 도입하지 않는다

## Files
- `shop-core/src/main/java/com/shop/shop/member/controller/**`
- `shop-core/src/main/java/com/shop/shop/member/service/**`
- `shop-core/src/main/java/com/shop/shop/member/repository/**`
- `shop-core/src/main/java/com/shop/shop/member/domain/**`
- `shop-core/src/main/java/com/shop/shop/member/dto/**`
- `shop-core/src/main/java/com/shop/shop/security/**`
- `shop-core/src/main/java/com/shop/shop/common/exception/**`
- `shop-core/src/main/resources/templates/admin/members.html`
- `shop-core/src/main/resources/templates/fragments/**`
- `shop-core/src/main/resources/static/**`
- `shop-core/src/test/java/com/shop/shop/member/**`
- `shop-core/src/test/java/com/shop/shop/security/**`

## Backend - View Contract

| 항목 | 값 |
|---|---|
| 관리자 회원 목록 경로 | `GET /admin/members` |
| 관리자 회원 목록 View name | `admin/members` |
| 관리자 회원 목록 템플릿 | `templates/admin/members.html` |
| 검색 파라미터 | `keyword`, `role`, `page`, `size` |
| 권한 변경 폼 action | `POST /admin/members/{memberId}/role` |
| 권한 변경 필드명 | `role` |
| 변경 가능 role 옵션 | `SELLER`, `CONSUMER` |
| 성공 리다이렉트 | `/admin/members` |
| 회원 목록 모델 키 | `members` |
| 검색 조건 모델 키 | `searchCondition` |
| 메시지 모델 키 | 기존 flash/message fragment 규칙 사용 |

## Acceptance Criteria
- `ADMIN` 사용자는 관리자 회원 목록 화면에 접근할 수 있다
- `SELLER`, `CONSUMER`, 비인증 사용자는 관리자 회원 목록 화면에 접근할 수 없다
- 관리자 회원 목록 화면에서 회원 email/name/role/createdAt을 확인할 수 있다
- 관리자 회원 목록 화면에서 검색과 role 필터를 사용할 수 있다
- `ADMIN` 사용자는 회원 role을 `SELLER` 또는 `CONSUMER`로 변경할 수 있다
- 권한 변경 후 DB의 role 값이 변경된다
- 자기 자신의 `ADMIN` 권한 제거는 실패한다
- 마지막 `ADMIN` 권한 제거는 실패한다
- 관리자 회원 REST API는 `ADMIN`만 접근 가능하다
- 응답과 화면에 비밀번호 hash, token, 민감 정보가 노출되지 않는다
- 권한 변경 후 JWT/Redis 로그인 상태 처리 정책이 구현 또는 명시된다
- 관련 테스트가 통과한다

## Test
- `./gradlew test`
- 권장 단위 테스트
  - 회원 목록 검색/필터 조건 테스트
  - role 변경 성공
  - 자기 자신 ADMIN 강등 실패
  - 마지막 ADMIN 강등 실패
  - 변경 불가 role 요청 실패
- 권장 Security/REST 테스트
  - `GET /api/v1/admin/members` ADMIN 성공
  - SELLER/CONSUMER 403
  - 비인증 401
  - `PATCH /api/v1/admin/members/{memberId}/role` 성공/실패
- 권장 View 테스트
  - `GET /admin/members` ADMIN 렌더링
  - 회원 목록/검색 폼/권한 변경 폼 렌더링
  - 권한 변경 폼 제출 성공 redirect
  - 권한 없는 사용자 접근 차단

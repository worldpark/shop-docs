# 029. shop-core 계정 관리 self-service — 비밀번호 변경 · 정보 수정 · 탈퇴 (with View)

> 출처: backlog `docs/backlog/backend/004-backend-shop-core-account-management.md` 승격(범위 A — **로그인 상태 self-service**). backlog 004의 "비밀번호 **재설정**(비로그인·이메일 토큰)"은 신규 이벤트 계약 + notification 발송이 얽혀 **Task 030으로 분리**한다. 본 Task는 이벤트/알림이 없는 로그인 사용자 계정 라이프사이클만 다룬다.

## Target
shop-core (member + web)

> 신규 이벤트·notification 무관(이메일 발송 없음). 단일 레포·단일 도메인(member).

---

## Goal
로그인한 사용자가 본인 계정을 **self-service**로 관리한다: ① **비밀번호 변경**(현재 비밀번호 확인 + 신규 비밀번호 정책 검증), ② **회원 정보 수정**(name/phone), ③ **회원 탈퇴**(소프트 삭제). REST API + Thymeleaf 화면 제공. 모든 동작은 **본인(principal) 한정**이며 타인 계정에 접근할 수 없다. 비밀번호는 BCrypt 유지, 원문 저장/로그/응답 금지(007 제약 계승).

## Context
- **인증 주체(006/007)**: REST는 JWT `principal == userId(long)`(`JwtAuthenticationFilter`가 설정), View formLogin은 `principal == email(String)`(`auth.getName()`). 따라서 REST는 userId로, View는 email→userId 해석(facade)으로 본인을 식별한다.
- **비밀번호(007)**: `BCryptPasswordEncoder`(`SecurityConfig` 빈) 공용. 현재 비밀번호 확인은 `passwordEncoder.matches(raw, user.getPasswordHash())`. 신규 비밀번호 정책 검증은 007 가입의 길이 규칙(`MemberPasswordPolicy.MIN_LENGTH`)을 재사용·계승. **confirm 일치 검증은 `@PasswordMatches`를 그대로 쓰지 못한다**: 현 `PasswordMatchesValidator`는 필드명 `password`/`passwordConfirm`을 하드코딩해 비번 변경 DTO의 `newPassword`/`newPasswordConfirm`을 못 찾고 **조용히 통과(검증 무력화)**한다. → `@PasswordMatches(field=, confirmField=)` 속성을 추가해 validator를 일반화하고(기존 SignupRequest/Form은 default `password`/`passwordConfirm`로 무변경), 비번 변경 DTO에는 `@PasswordMatches(field="newPassword", confirmField="newPasswordConfirm")`를 적용한다.
- **권한 변경 후 로그인 상태 정책(006/008 선례)**: `MemberService.changeRole`은 권한 변경 후 `refreshTokenStore.deleteRefresh(userId)`를 호출한다. 호출 위치는 **동기화 활성 시 `afterCommit()`(Redis 비트랜잭셔널 — DB 커밋 후), 동기화 비활성 시(비트랜잭션 컨텍스트/일부 테스트) 직접 호출**의 이중 분기다. **비밀번호 변경/탈퇴도 이 이중 분기 패턴을 그대로 재사용한다**(afterCommit만 쓰면 비트랜잭션 테스트에서 refresh 삭제 누락).
- **세션 무효화 범위는 인증 클래스별로 다름**(이 시스템은 인증 경로가 둘이다): REST(`/api/v1/**`)는 stateless JWT — `deleteRefresh(userId)`로 **refresh 재발급을 차단**(이후 재로그인 유도)하나, 이미 발급된 access는 잔여 TTL(≤30분)까지 유효(per-user jti 추적 없음 — changeRole 선례 그대로). View(formLogin)는 **HTTP 세션** 기반이고 refresh token을 발급받지 않으므로 `deleteRefresh`는 View 세션에 무영향이다. View 다기기 HTTP 세션 강제 만료는 `SessionRegistry` 미도입으로 **범위 밖**(현재 세션 종료는 `/logout`로만).
- **Redis(006)**: `RedisRefreshTokenStore`(`shopcore:auth:refresh:{userId}` = SHA-256(refresh), `shopcore:auth:blacklist:{jti}`). 네임스페이스는 `RedisProperties.Auth`. 본 Task는 새 namespace를 추가하지 않는다(refresh 삭제만 재사용).
- **User 엔티티(007)**: `id, email(citext unique), passwordHash, name, phone, role` + `BaseEntity`(createdAt/updatedAt). Setter 금지·정적 팩토리·도메인 메서드(`changeRole`) 패턴. 정보 수정/탈퇴/비번 변경도 **도메인 메서드**로 표현.
- **탈퇴 = 소프트 삭제**: 물리 삭제 시 주문(`orders.member_id`)·배송 등 FK 연관과 감사 추적이 깨진다 → **소프트 삭제**(`users`에 상태/시각 컬럼 추가, **V6 Flyway**). 탈퇴 사용자는 인증 차단(로그인·기존 토큰 무효). 연관 데이터(주문·리뷰 등) **보존**(익명화는 범위 밖).
- **마이그레이션**: 현 V1~V5. 신규 `V6__users_account_lifecycle.sql`. Flyway 소유·Hibernate `validate`(ADR-007). V1~V5 수정 금지.

## API Authorization
> `docs/rules/api-authorization-rule.md` 준수 — 최소 권한 + 소유권(본인) 검사. **모든 대상이 principal 본인**이므로 경로에 다른 사용자 id를 받지 않는다(`/me` 셀프 경로).

| API | 공개 여부 | 보안 계층 최소 권한 | 소유권 검사 | 비고 |
|---|---|---|---|---|
| `PATCH /api/v1/members/me/password` | authenticated | authenticated | principal 본인(경로에 타 id 없음) | 비밀번호 변경(현재 비번 확인) |
| `PATCH /api/v1/members/me` | authenticated | authenticated | principal 본인 | 정보 수정(name/phone) |
| `DELETE /api/v1/members/me` | authenticated | authenticated | principal 본인 | 탈퇴(소프트 삭제) |
| `GET /account` | authenticated | authenticated | principal 본인 | 계정 설정 화면 |
| `POST /account/password` | authenticated | authenticated | principal 본인 | 비밀번호 변경 폼 제출(View) |
| `POST /account/profile` | authenticated | authenticated | principal 본인 | 정보 수정 폼 제출(View) |
| `POST /account/withdraw` | authenticated | authenticated | principal 본인 | 탈퇴 폼 제출(View) → 로그아웃 |

> **소유권 = principal 자기 자신**: 경로/바디로 대상 회원 id를 받지 않고 **인증 주체에서만** 대상 userId를 도출한다. 타인 계정 변경 벡터를 원천 차단(IDOR 불가). `/me` 셀프 경로는 `authenticated`만으로 충분(별도 role 불요 — CONSUMER/SELLER/ADMIN 모두 본인 계정 관리 가능).

## Requirements
- **비밀번호 변경(PATCH `/api/v1/members/me/password`, View `POST /account/password`)**
  - 요청: `currentPassword`, `newPassword`, `newPasswordConfirm`. 서비스에서 `passwordEncoder.matches(currentPassword, hash)` 실패 시 거부(400/유효성 에러 — 현재 비번 불일치). `newPassword`는 007 정책(길이·confirm 일치) 재사용 검증. 통과 시 `passwordEncoder.encode(newPassword)`로 재인코딩 후 `user.changePassword(newHash)`(도메인 메서드, dirty checking UPDATE).
  - 변경 성공 시 **`refreshTokenStore.deleteRefresh(userId)`** 호출(changeRole의 afterCommit + 비동기화 직접호출 **이중 분기** 그대로 재사용). 효과는 인증 클래스별로 다름: REST는 refresh 재발급 차단(재로그인 유도, access는 잔여 TTL ≤30분 후 만료 — 즉시 무효화는 과설계로 보류), View(formLogin)는 refresh 미발급이라 무영향(현재 세션은 유지). access 토큰 blacklist는 추가하지 않는다(changeRole 선례).
- **정보 수정(PATCH `/api/v1/members/me`, View `POST /account/profile`)**
  - 요청: `name`, `phone`(검증 — 007 규칙 계승). `user.updateProfile(name, phone)`(도메인 메서드). **email/role/password는 본 경로로 변경 불가**(email 변경은 인증 재확인 필요 → 범위 밖, role은 008, password는 위 경로).
- **탈퇴(DELETE `/api/v1/members/me`, View `POST /account/withdraw`)**
  - **소프트 삭제**: `user.withdraw()`로 상태 전이(예: `status=WITHDRAWN` + `deletedAt=now()` — 정확 표현은 plan 확정). 물리 삭제 금지.
  - 탈퇴 후 **신규 진입 차단**: 차단 지점은 경로별로 독립이므로 각각 가드를 둔다(`UserDetails.enabled=false` 단일 수단으로 전 경로를 덮지 못함에 유의 — `enabled`는 formLogin 로그인 시점에만 작동하고, REST 로그인 `MemberService.authenticate`와 stateless `JwtAuthenticationFilter`에는 무효).
    - **View 로그인**(`MemberUserDetailsService.loadUserByUsername`): 탈퇴 사용자 거부 — `enabled=false` 설정 또는 활성 전용 조회(`findActiveByEmail`).
    - **REST 로그인**(`MemberService.authenticate`): `UserDetailsService`를 경유하지 않으므로 **별도 status 가드**를 직접 추가(`enabled=false` 무효).
    - **refresh 재발급**(`/api/v1/auth/refresh`): 탈퇴 사용자 거부. 탈퇴 시 `deleteRefresh(userId)`로 저장 hash가 사라져 `matchesRefresh`가 자연 실패하므로 사실상 차단되나, 의도를 명시한다.
    - **기존 access 토큰/HTTP 세션**: 즉시 무효화는 **범위 밖**(JWT는 잔여 TTL ≤30분 후 만료, View HTTP 세션은 `SessionRegistry` 미도입 — changeRole 선례와 동일 한계). `JwtAuthenticationFilter`에 per-request DB status 조회나 jti 블랙리스트는 추가하지 않는다.
  - `refreshTokenStore.deleteRefresh(userId)`는 changeRole의 이중 분기(afterCommit + 비동기화 직접호출) 그대로 호출해 refresh 재발급을 차단한다.
  - **email 재사용 정책**(plan 확정): citext unique 제약을 탈퇴 행이 점유하므로, 동일 이메일 재가입 허용 여부 결정 — 권장: **재사용 불가(unique 유지, 탈퇴 행 보존)**. 재사용 허용이 필요하면 부분 유니크 인덱스(`WHERE status<>'WITHDRAWN'`) + email 마스킹/이전 정책을 plan에서 설계. 과도한 익명화·데이터 이전은 범위 밖.
  - 연관 데이터(주문·배송 등) **보존**(FK 유지). 탈퇴 시 진행 중 주문 처리 정책은 해당 도메인 Task 범위(여기선 보존).
- **화면(with View — `web` 레이어, spi facade 경유)**
  - `GET /account`: 계정 설정 페이지(현재 name/phone/email 표시 — 비밀번호/해시 비노출, 비번 변경·정보 수정·탈퇴 폼). web은 member Entity/Service를 직접 참조하지 않고 **`AccountFacade`(member.spi)** 가 표시용 DTO(scalar)와 처리 메서드를 제공(007/008 facade 패턴 계승).
  - 폼 제출(`POST /account/password|profile|withdraw`)은 PRG(redirect) + flash 메시지. 비밀번호 echo 금지(검증 실패 시 비번 필드 clear — 007 가입 폼 선례).
- **도메인 메서드**: `User`에 `changePassword(newHash)`, `updateProfile(name, phone)`, `withdraw()` 추가(Setter 금지 유지). 상태 표현(WITHDRAWN)은 enum 또는 nullable `deletedAt` — plan 확정.
- **로그**: 비밀번호 변경/정보 수정/탈퇴를 `userId`와 함께 로깅(비밀번호 원문/해시·민감값 로그 금지).

## Constraints
- **본인 한정(IDOR 차단)**: 모든 동작은 principal 자기 자신만 대상. 경로/바디로 타 회원 id를 받지 않는다. 타인 계정 변경 경로 없음.
- **비밀번호 보호(007 계승)**: 원문 저장/로그/응답 금지, BCrypt 유지. 현재 비밀번호 확인 없는 변경 금지. 응답/View에 해시·토큰·Redis 상태 비노출.
- **email/role 불변(본 경로)**: 정보 수정은 name/phone만. email 변경(인증 재확인 필요)·role 변경(008)은 범위 밖.
- **탈퇴는 소프트 삭제**: 물리 삭제 금지. 탈퇴 후 로그인·기존 토큰 무효. 연관 데이터 보존(익명화/데이터 이전 범위 밖).
- **로그인 상태 정책 재사용**: 비밀번호 변경/탈퇴 시 refresh 무효화는 008 `changeRole`의 **이중 분기 패턴**(동기화 활성 시 `afterCommit()`, 비활성 시 직접 호출) 그대로 재사용(새 정책 설계 금지). 세션 무효화 효과는 인증 클래스별로 다름(REST=refresh 재발급 차단/access는 TTL 후 만료, View=현재 세션 `/logout`만, 타 기기 HTTP 세션은 범위 밖).
- **마이그레이션**: 신규 `V6`만 추가(V1~V5 수정 금지), Entity와 `validate` 정합.
- **이벤트 계약·notification 무변경**: 본 Task는 이메일을 보내지 않는다. `event-catalog.md`/§5 불변, notification 코드·DB 미참조. (비밀번호 재설정 메일은 Task 030.)
- **레이어 규칙**: Controller 비즈니스 로직 금지(REST는 `@RestController→ServiceResponse→Service→Repository`, View는 `@Controller(web)→spi facade→Service`). web이 member Entity/Service/`Role` enum 직접 참조 금지.

## Files
> shop-core 단일 레포. member 모듈 + web 레이어. 정확 경로/필드는 plan 확정.
- (수정) `member/domain/User.java` — `changePassword(newHash)`·`updateProfile(name, phone)`·`withdraw()` 도메인 메서드 + 상태 필드(WITHDRAWN/deletedAt)
- (신규) `member/domain/MemberStatus.java`(상태 enum 채택 시) 또는 `deletedAt` 컬럼 매핑(plan 확정)
- (수정) `member/service/MemberService.java`(또는 신규 `AccountService`) — `changePassword`/`updateProfile`/`withdraw` + `ServiceResponse`, 본인 userId 기준, refresh 무효화 `afterCommit()`
- (수정) `member/repository/MemberRepository.java` — 활성 사용자 전용 조회 `findActiveByEmail` **신설**(인증 가드용). 기존 `findByEmail`은 admin 검색·기타 경로가 공유하므로 **무변경**(시그니처 변경으로 인한 회귀 차단).
- (수정) `member/dto/validation/PasswordMatchesValidator.java` + `PasswordMatches.java` — `field()`/`confirmField()` 속성 추가로 비교 필드명 일반화. default = `password`/`passwordConfirm`(기존 SignupRequest/SignupForm 무변경).
- (신규) `member/dto/**` — `PasswordChangeRequest`/`PasswordChangeForm`, `ProfileUpdateRequest`/`ProfileUpdateForm`, (탈퇴 확인용 폼)
- (신규/수정) `member/controller/MemberRestController.java`(확장) 또는 `MemberAccountRestController.java` — `/me/password`(PATCH), `/me`(PATCH), `/me`(DELETE)
- (신규) `member/spi/AccountFacade.java` + 구현체(`member/service`) — web용 표시 DTO(scalar) + 처리(email→userId 해석)
- (신규) `web/member/AccountViewController.java` — `GET /account`, `POST /account/password|profile|withdraw`
- (신규) `src/main/resources/templates/member/account.html`(+ 기존 layout/fragment·messages 재사용)
- (신규) `src/main/resources/db/migration/V6__users_account_lifecycle.sql` — `users` 상태/`deleted_at` 컬럼(+ 필요 시 부분 유니크/인덱스)
- (수정) `security/**` + `member/service/**` — `/account/**`·`/api/v1/members/me/**` `authenticated`. 탈퇴 사용자 신규 진입 차단은 경로별 독립 가드: View 로그인(`MemberUserDetailsService`), REST 로그인(`MemberService.authenticate`), refresh 재발급(refresh 검증). `JwtAuthenticationFilter`는 무변경(stateless 유지).
- (재사용·무변경) `RedisRefreshTokenStore`/`RedisProperties`(refresh 삭제만), `BCryptPasswordEncoder`, `MemberPasswordPolicy`, `common/exception/BusinessException`
- (변경 없음) `event-catalog.md`/§5, notification 전부, V1~V5

## Backend - View Contract
| 항목 | 값 |
|---|---|
| 계정 설정 화면 | `GET /account` → view `member/account` |
| 비밀번호 변경 제출 | `POST /account/password` → 성공 redirect `/account?password` (실패 재렌더, 비번 echo 금지) |
| 정보 수정 제출 | `POST /account/profile` → 성공 redirect `/account?profile` |
| 탈퇴 제출 | `POST /account/withdraw` → 로그아웃 + redirect `/` |
| 모델 키 | 계정 정보 `accountInfo`(주의: `account`/`request` 등 Thymeleaf 암묵 scope 예약어 회피 — 도메인 접두사), 폼 백킹 `passwordForm`/`profileForm`, 메시지 기존 flash/message fragment |

## Acceptance Criteria
- 로그인 사용자는 **현재 비밀번호를 정확히 입력해야** 비밀번호를 변경할 수 있고, 불일치 시 거부된다. 변경 후 BCrypt 해시가 갱신되고 기존 refresh 토큰이 무효화된다.
- 로그인 사용자는 name/phone을 수정할 수 있으며, 이 경로로 email/role/password는 변경되지 않는다.
- 탈퇴 시 사용자가 **소프트 삭제**(WITHDRAWN/deletedAt)되고, 이후 **신규 로그인(View/REST)과 refresh 재발급이 차단**된다. 이미 발급된 access 토큰은 잔여 TTL(≤30분) 후 만료되고, 진행 중 View HTTP 세션은 `/logout` 외 강제 만료하지 않는다(즉시 무효화는 범위 밖 — changeRole 선례 한계 동일). 연관 데이터(주문 등)는 물리 삭제되지 않는다.
- 모든 동작은 **principal 본인만** 대상이며, 타 회원 계정을 변경할 수 있는 경로가 없다(인증 401, 본인 외 접근 불가).
- 응답/View에 비밀번호 해시·토큰·Redis 상태가 노출되지 않는다.
- `V6`가 V1~V5 수정 없이 `users` 계정 라이프사이클 컬럼을 추가하고 Entity와 `validate` 정합한다.
- 이벤트 계약/notification은 무변경(이메일 발송 없음).

## Test
- **단위(Mockito)**: 비밀번호 변경 — 현재 비번 불일치 거부, 일치 시 `encode(newPassword)`로 재인코딩 + `user.changePassword` + refresh 삭제 검증(동기화 비활성 컨텍스트에서 직접 호출 분기 동작 포함); 정보 수정 — name/phone만 반영(email/role 불변); 탈퇴 — 상태 WITHDRAWN 전이 + refresh 삭제, 물리 delete 호출 없음. `User` 도메인 메서드 단언. **`@PasswordMatches(field="newPassword", confirmField="newPasswordConfirm")` 검증** — confirm 불일치가 실제로 `newPasswordConfirm` 필드 위반으로 보고되는지(일반화 후 무음 통과 회귀 차단).
- **슬라이스/통합(@DataJpaTest 또는 Testcontainers)**: `V6` 적용 + `validate` 정합. 소프트 삭제 후 활성 조회/인증 가드 동작. (email 재사용 정책 채택 시 제약/인덱스 검증.)
- **Security/REST(MockMvc)**: `PATCH /api/v1/members/me/password`·`PATCH /api/v1/members/me`·`DELETE /api/v1/members/me` — 인증 사용자 본인 성공, 비인증 401; **탈퇴 후 재로그인(REST `authenticate`)·refresh 재발급 차단**(기존 access 토큰의 즉시 차단은 비요구 — TTL 만료 위임); 타 회원 id를 받는 경로 부재(셀프 경로만) 확인.
- **View 렌더링**: `GET /account` 렌더(비번/해시 비노출), 비번/정보/탈퇴 폼 제출 성공 redirect + flash, 비번 검증 실패 재렌더 시 비밀번호 echo 금지. (조건부 가시성은 testing-rule상 필요 시 E2E.)
- **회귀**: 006 로그인/로그아웃·007 가입·008 admin role 테스트 그린. `./gradlew test` 풀 그린.

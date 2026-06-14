# 029 — 계정 self-service Task 설계 모순 정정 (Revision 1)

- 대상 Task: `docs/tasks/backend/029-backend-shop-core-account-self-service-management-with-view.md`
- 대상 Plan: (미작성 — 본 정정은 plan 착수 **전** Task 명세 단계에서 수행)
- 결정 일자: 2026-06-14
- 결정자: 사용자(Task 설계 점검 피드백)
- 목적: Task 029 초기 명세가 **인증 경로가 둘(REST=stateless JWT / View=formLogin HTTP 세션)** 인 현 시스템을 단일 "refresh 삭제 + `enabled=false`" 수단으로 덮을 수 있다고 전제해 발생한 모순 4건(+경미 2건)을 코드 대조로 확인하고, 정정 방향과 구현 기준을 기록한다.

---

## 대조한 코드 근거

| 파일 | 확인 사실 |
|---|---|
| `security/JwtAuthenticationFilter.java` | JWT claims만으로 인증 구성. **DB·`UserDetailsService` 미조회** → `enabled=false` 무효. blacklist(jti)만 조회. |
| `security/SecurityConfig.java` | 이중 체인 — REST(`/api/v1/**`) STATELESS, View(나머지) formLogin **HTTP 세션**. `SessionRegistry`/`maximumSessions` 미설정. |
| `member/service/MemberService.java` | `authenticate()`는 `findByEmail`+`matches`를 **직접** 수행(`UserDetailsService` 미경유). `changeRole`은 refresh 삭제를 **afterCommit + 비동기화 직접호출 이중 분기**로 호출. access 즉시 무효화는 "과설계 — 보류" 명시. |
| `member/service/MemberUserDetailsService.java` | View formLogin 전용. `enabled` 미설정(추가 시 formLogin에만 효과). |
| `security/RefreshTokenStore.java` | refresh는 `/api/v1/auth/login`(REST)에서만 발급·저장. View는 refresh 미발급. |
| `member/dto/validation/PasswordMatchesValidator.java` | 비교 필드명 `password`/`passwordConfirm` **하드코딩**. 다른 필드명 DTO는 두 값이 null → `return true`(**무음 통과**). |

---

## 결정 요약

| # | 항목 | 초기 명세 | 변경 결정 | 근거 |
|---|---|---|---|---|
| A | 탈퇴 즉시 차단 | "`JwtAuthenticationFilter` 경유 요청도 탈퇴면 거부", "기존 토큰 무효화" | **JwtAuthenticationFilter 언급 제거**(stateless 유지). Acceptance를 "신규 로그인·refresh 재발급 차단, 기존 access는 TTL ≤30분 후 만료"로 하향 | 필터가 DB/UserDetails 미조회 → `enabled=false` 무효. access 즉시 무효화는 changeRole이 이미 "보류"로 결정 |
| B | "타 기기 세션 강제 만료" | refresh 삭제로 전 경로 세션 만료 | **인증 클래스별 분리 기술**: REST=refresh 재발급 차단(access는 TTL 후 만료), View=현재 세션 `/logout`만(타 기기 HTTP 세션은 `SessionRegistry` 미도입 — 범위 밖) | View는 refresh 미발급 → `deleteRefresh`가 View 세션에 무영향 |
| C | 탈퇴 차단 수단 | "`enabled=false` 또는 서비스 가드"(단일 수단) | **경로별 독립 가드로 분해**: View 로그인(`MemberUserDetailsService` enabled/활성조회) · REST 로그인(`MemberService.authenticate` 별도 status 가드) · refresh 재발급(거부) · 기존 토큰/세션(범위 밖) | `authenticate`는 UserDetails 미경유 → `enabled=false` 무효. 두 로그인 경로가 독립 |
| D | confirm 검증 재사용 | "`@PasswordMatches` 재사용" + DTO 필드 `newPassword`/`newPasswordConfirm` | **validator 일반화** — `@PasswordMatches(field=, confirmField=)` 속성 추가. default=`password`/`passwordConfirm`(기존 무변경), 변경 DTO는 `field="newPassword", confirmField="newPasswordConfirm"` | 현 validator는 하드코딩 필드명만 탐색 → 다른 이름 DTO는 **검증 무음 통과**(보안 결함) |
| 경미1 | refresh 무효화 호출 | "`afterCommit()`" | changeRole의 **이중 분기(afterCommit + 비동기화 직접호출)** 전체 재사용 | afterCommit만 쓰면 비트랜잭션 테스트에서 refresh 삭제 누락 |
| 경미2 | 활성 조회 | "`findByEmail` 등으로 활성 조회" | **`findActiveByEmail` 신설**, 기존 `findByEmail` 무변경 | `findByEmail`은 admin 검색 등 공유 — 시그니처 변경 시 회귀 위험 |

---

## A. 탈퇴 즉시 차단 — JwtAuthenticationFilter 언급 제거 + Acceptance 하향

- 초기 명세는 탈퇴 사용자의 access 토큰을 `JwtAuthenticationFilter`에서 거부하고(`enabled=false`), "기존 토큰이 무효화된다"고 단언했다.
- 코드상 필터는 JWT claims만으로 인증을 만들고 DB도 `UserDetailsService`도 보지 않으므로 `enabled=false`는 JWT 경로에 **효과가 없다.** 또한 changeRole 선례가 "access jti 전수 추적/per-user token-version 부재 → 즉시 무효화는 과설계, 보류"를 이미 명문화했다.
- 정정:
  - Requirements 탈퇴 절에서 `JwtAuthenticationFilter` 거부 문구 삭제. "기존 access 토큰/HTTP 세션 즉시 무효화는 범위 밖(JWT는 잔여 TTL ≤30분, View 세션은 SessionRegistry 미도입)"으로 명시. 필터·jti 블랙리스트·per-request DB 조회는 **추가하지 않음**.
  - Acceptance: "이후 로그인이 차단되며 기존 토큰이 무효화된다" → "**신규 로그인(View/REST)과 refresh 재발급이 차단**된다. 기존 access는 TTL 후 만료, 진행 중 View 세션은 `/logout` 외 강제 만료 안 함."

## B. 세션 무효화 범위 — 인증 클래스별 분리

- View(formLogin) 사용자는 refresh token을 발급받지 않으므로 `deleteRefresh(userId)`는 View 세션에 무영향이다. "다른 기기 세션 강제 만료"는 REST에만(그나마 access는 TTL 잔존) 부분 적용된다.
- 정정: Context·Requirements·Constraints에서 효과를 분리 기술 — **REST**=refresh 재발급 차단(재로그인 유도), **View**=현재 세션 `/logout`만(탈퇴 View 흐름은 기존대로 로그아웃+redirect). 타 기기 HTTP 세션 강제 만료가 필요하면 Spring Session + `SessionRegistry` 도입을 **별도 결정/Task**로 분리(현 "새 정책 설계 금지" 제약과 충돌하므로 본 Task 범위에서 제외).

## C. 탈퇴 차단 지점 분해

- 로그인 진입이 두 갈래로 독립: View=`MemberUserDetailsService.loadUserByUsername`, REST=`MemberService.authenticate`(UserDetails 미경유). `enabled=false`는 전자에만 작동한다.
- 정정: Requirements 탈퇴 절을 4지점으로 분해.
  1. **View 로그인**: `MemberUserDetailsService`에 `enabled=false` 또는 활성 전용 조회(`findActiveByEmail`).
  2. **REST 로그인**: `MemberService.authenticate`에 **별도 status 가드** 직접 추가(`enabled` 무효).
  3. **refresh 재발급**(`/api/v1/auth/refresh`): 탈퇴 거부. `deleteRefresh`로 hash 부재 → `matchesRefresh` 자연 실패하나 의도 명시.
  4. **기존 access/HTTP 세션**: 범위 밖(A 항과 동일).

## D. `@PasswordMatches` validator 일반화

- 초기 명세는 `@PasswordMatches`를 그대로 재사용한다 했으나, validator가 필드명 `password`/`passwordConfirm`을 하드코딩한다. 변경 DTO 필드명(`newPassword`/`newPasswordConfirm`)에는 두 추출값이 모두 null이 되어 **검증이 조용히 통과**(confirm 불일치 미검출)하는 보안 결함이 된다.
- 정정: `@PasswordMatches`에 `field()`/`confirmField()` 속성을 추가하고 validator가 이를 읽어 비교하도록 일반화한다. default 값은 `password`/`passwordConfirm`로 두어 **기존 SignupRequest/SignupForm은 무변경**. 비번 변경 DTO에는 `@PasswordMatches(field="newPassword", confirmField="newPasswordConfirm")`를 적용한다.
- Files 섹션에서 `@PasswordMatches`를 "재사용·무변경"에서 빼고 "(수정)"으로 이동. 위반 보고 노드(`addPropertyNode`)도 `confirmField` 값을 사용하도록 한다.
- 테스트: 단위 테스트에 "confirm 불일치가 `newPasswordConfirm` 필드 위반으로 보고됨"을 추가해 무음 통과 회귀를 차단.

## 경미1. refresh 무효화 이중 분기 재사용

- `changeRole`은 `TransactionSynchronizationManager.isSynchronizationActive()`로 분기해 활성 시 `afterCommit()`, 비활성 시 직접 호출한다. Task는 "afterCommit()"만 적어 비트랜잭션 컨텍스트(일부 테스트)에서 삭제 누락 위험이 있었다.
- 정정: Context·Requirements·Constraints에서 "이중 분기 전체 재사용"으로 명시.

## 경미2. `findActiveByEmail` 신설

- 활성 사용자 조회를 `findByEmail` 변경으로 처리하면 admin 검색·기타 호출자에 회귀가 번진다.
- 정정: `findActiveByEmail`(활성 전용, 인증 가드용) **신설**, 기존 `findByEmail` **무변경**. 계정 화면의 email→userId 해석(AccountFacade)은 로그인 직후 본인 조회이므로 활성 조회를 사용.

---

## rule 반영 결과

- 본 정정은 **Task 029 명세에 한정**한다. rule 승격은 보류:
  - A/B/C(인증 클래스별 세션·차단 한계)는 006/008 보안 설계에 이미 암묵 존재하는 사실의 **재확인**이라 rule 신설 대신 Task 명세로 충분.
  - D(validator 일반화)는 member 모듈 내부 검증 유틸 변경이라 rule화 불요.
- 재발 방지 관찰: "인증 수단이 둘일 때 세션/토큰 무효화 보장은 수단별로 분리해 기술"은 향후 동종 Task(예: 030 비번 재설정)에서 재점검 대상으로 남긴다.

---

## 영향 범위

- 신규 namespace·이벤트·notification 변경 없음(초기 Task 제약 유지).
- access 토큰 blacklist 미추가, `JwtAuthenticationFilter`·`SessionRegistry` 미도입 — stateless/세션 설계 비파괴.
- 회귀 대상: 006 로그인/refresh, 007 가입(`@PasswordMatches` default 동작 유지), 008 admin role(이중 분기 패턴 동일).

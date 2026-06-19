# 056. 최초 ADMIN 부트스트랩 — ADMIN 부재 시 로그인 대신 관리자 생성 화면

> 출처: 사용자 요청. `users.role = ADMIN` 행이 하나도 없으면(시스템 최초 기동 상태) 로그인 화면 대신 **최초 관리자 계정 생성 화면**을 노출한다.
> 현재 최초 ADMIN은 `AdminAccountSeedTest`(수동 실행) 또는 SQL 직접 실행으로만 생성된다 — 운영 부트스트랩 경로가 화면에 없다.

## 배경
- `MemberService.signup()`은 항상 `Role.CONSUMER`를 강제하고, `MemberService.changeRole()`은 **ADMIN 승격을 금지**한다(`forbiddenPromotion`). 즉 화면을 통한 ADMIN 생성 경로가 전혀 없다.
- `MemberRepository.countByRole(Role.ADMIN)`이 이미 존재한다(마지막 ADMIN 강등 방지에 사용 중) → ADMIN 존재 여부 판단에 그대로 재사용한다.
- `users.role` 컬럼은 V2 마이그레이션에서 이미 `ADMIN/SELLER/CONSUMER`를 허용한다 → **Flyway 마이그레이션 불필요**.

## 범위
1. **ADMIN 존재 여부 게이트**: `GET /login` 진입 시 ADMIN이 0명이면 `GET /setup/admin`으로 redirect한다.
2. **최초 관리자 생성 화면**: `GET /setup/admin` — ADMIN이 이미 있으면 `/login`으로 redirect(권한 상승 차단), 없으면 생성 폼 렌더.
3. **최초 관리자 생성 처리**: `POST /setup/admin` — 트랜잭션 내에서 ADMIN 0명을 재확인한 뒤 `Role.ADMIN` 계정 생성. 검증 실패는 폼 재렌더, ADMIN이 이미 존재하면 `/login`으로 redirect. 성공 시 `/login?adminCreated`로 redirect(사용자가 방금 만든 계정으로 직접 로그인).
4. **보안 설정**: `/setup/admin`(GET·POST) `permitAll` + 기존 CSRF(쿠키 저장소) 보호 적용. 경로는 `/admin/**`(hasRole ADMIN)와 겹치지 않도록 `/setup/admin`을 사용한다.

## 리스크 / 결정
- **[결정] 생성 후 동작**: 자동 로그인하지 않고 `/login?adminCreated`로 이동한다(인증 흐름 일관성 — 부트스트랩 경로에 토큰 발급 로직을 추가하지 않음).
- **[결정] 이벤트 발행**: 최초 ADMIN 생성은 `MemberRegisteredEvent`를 **발행하지 않는다**(시스템 부트스트랩 행위 — 환영 이메일/notification 대상 아님). 일반 `signup`과 분리된 별도 도메인 메서드를 둔다.
- **[결정·핵심 보안] 엔드포인트 폐쇄**: ADMIN이 1명이라도 존재하면 `GET`·`POST /setup/admin` 모두 차단된다(GET→redirect, POST→service 가드 예외→redirect). 이로써 공개 엔드포인트가 권한 상승 통로가 되지 않는다.
- **[리스크] 동시 부트스트랩 경합**: ADMIN 0명일 때 두 POST가 동시에 게이트를 통과해 ADMIN 2개가 생성될 수 있다. 트랜잭션 내 `countByRole(ADMIN)==0` 재확인으로 창을 좁힌다. 최초 1회 부트스트랩 한정 + 아직 보호할 기존 ADMIN이 없는 시점이라 권한 상승 위험은 아니므로 advisory lock은 비범위(필요 시 후속 하드닝).

## Non-goals
- 다중 ADMIN 생성/관리 UI(기존 admin 회원관리 화면 책임). `AdminAccountSeedTest` 제거(개발 시드 경로로 유지). 자동 로그인. 토큰/세션 변경. API(`/api/v1/**`) 엔드포인트 추가.

## 검증
- **단위(Mockito)**: ADMIN 0명 → `Role.ADMIN` 생성 + 비밀번호 BCrypt 인코딩 + **이벤트 미발행**. ADMIN ≥1 → 생성 거부 예외. 이메일 중복 처리.
- **슬라이스(MockMvc)**: `GET /login` ADMIN 부재 시 `/setup/admin` redirect. `GET /setup/admin` ADMIN 존재 시 `/login` redirect. `POST /setup/admin` 검증 실패 재렌더.
- **통합(Testcontainers)**: 실 DB — 게이트 + 생성 → `users.role=ADMIN` 영속 확인.
- **E2E(Playwright, 핵심)**: ADMIN 없는 DB → `/login` 접근 시 `/setup/admin`으로 이동 → 폼 제출 → ADMIN 생성 → `/login?adminCreated` → 생성한 계정으로 로그인 성공 → 재접근 시 `/setup/admin`이 `/login`으로 닫힘(조건부 redirect는 MockMvc가 쿠키↔템플릿 가시성 공백을 놓침).
- **메인 게이트**: Modulith verify + 풀 스위트 그린.

## 참고
- `security/SecurityConfig.java`: View 체인 `:163-247`(authorize 매처에 `/setup/admin` permitAll 추가), `/admin/**`=hasRole ADMIN(`:197`)와 경로 충돌 회피.
- `web/member/LoginViewController.java`(`:16-19` GET /login 게이트 추가), `web/member/MemberSignupViewController.java`(폼 컨트롤러 패턴 선례), `web/auth/CookieLoginViewController.java`(web→member.spi facade 경유 선례).
- `member/service/MemberService.java`(`signup` `:140-163`·`changeRole` ADMIN 승격 금지 — 신규 `bootstrapFirstAdmin`/`adminExists` 추가), `member/repository/MemberRepository.java`(`countByRole` `:69` 재사용).
- `member/spi/MemberSignupFacade.java`·`ViewAuthFacade.java`(published port 패턴 — 신규 facade 선례), `member/dto/SignupForm.java`(폼 검증 선례).
- `templates/auth/login.html`(layout/blank 화면 선례). `db/migration/V2__users_role_hierarchy.sql`(role ADMIN 허용 — 마이그레이션 불요).
- 규칙: api-authorization-rule(ADMIN 권한·공개 API 기준), error-response-rule(View=redirect+재렌더), architecture-rule·package-structure-rule(web→member.spi 단방향), task-rule(테스트 필수).

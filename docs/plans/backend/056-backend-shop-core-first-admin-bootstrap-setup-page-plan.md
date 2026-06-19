# 056 Plan — 최초 ADMIN 부트스트랩: ADMIN 부재 시 로그인 대신 관리자 생성 화면

> Task: `docs/tasks/backend/056-backend-shop-core-first-admin-bootstrap-setup-page.md`
> 전략: `users.role=ADMIN` 행이 0개인 **최초 기동 상태**에서만 열리는 1회성 관리자 부트스트랩 화면을 추가한다. ADMIN이 1명이라도 생기면 GET·POST 양쪽이 영구히 닫힌다(공개 엔드포인트가 권한 상승 통로가 되지 않게 하는 것이 핵심 보안 불변식). 토큰/세션/이벤트/마이그레이션 변경 없음 — 기존 회원·인증 구조 재사용.
> 확정 결정(사용자): (1) 생성 성공 후 **자동 로그인하지 않고 `/login?adminCreated`로 이동**. (2) 최초 ADMIN 생성 시 **`MemberRegisteredEvent` 미발행**.

---

## 0. 코드 대조 (현재 상태 — 작업 트리 실측)

- **`member/service/MemberService.java`** — Repository를 호출하는 유일 지점.
  - `signup(email, rawPassword, name, phone)`(`:140-163`): `existsByEmail` 사전 체크 → BCrypt `passwordEncoder.encode` → `User.of(..., Role.CONSUMER)` 저장 → `MemberRegisteredEvent` 발행 → `DataIntegrityViolationException`→`DuplicateEmailException` 흡수. **role=CONSUMER 강제, 이벤트 발행** — 부트스트랩과 정책이 달라 그대로 재사용 불가.
  - `changeRole(...)`(`:213-264`): **`newRole==ADMIN`이면 `forbiddenPromotion()`(400) — 화면을 통한 ADMIN 승격이 전면 금지**. 즉 현 시스템에서 ADMIN을 만드는 화면 경로가 없다. `countByRole(Role.ADMIN)`을 "마지막 ADMIN" 불변식(`:236`)에서 이미 사용.
  - `normalizePhone`(`:169-171`): 빈 문자열→null.
- **`member/repository/MemberRepository.java`** — `long countByRole(Role role)`(`:69`, ADMIN 강등 방지에 사용 중 — **재사용**), `boolean existsByEmail(String)`(`:78`), `save`. 비즈니스 로직 없음, MemberService에서만 호출.
- **`member/domain/User.java`** — `User.of(email, passwordHash, name, phone, Role)` 정적 팩토리. `name`/`phone`은 `EncryptedStringConverter`로 **저장 시 자동 암호화**(별도 암호화 호출 불필요). `role`은 `@Enumerated(STRING)` `varchar(20)`.
- **`member/domain/Role.java`** — `CONSUMER/SELLER/ADMIN`, `authority()`=`"ROLE_"+name()`.
- **`security/SecurityConfig.java`** — 3체인. **View 체인 `viewChain` `@Order(2)`(`:163-247`)**:
  - authorize 매처(`:173-212`): `GET /login`·`POST /login`·`POST /logout`·정적·`GET/POST /signup`·`/password-reset/**` permitAll. **`/admin/**` → `hasRole("ADMIN")`(`:197`)**, 그 외 `anyRequest().authenticated()`(`:211`).
  - STATELESS, `viewJwtAuthenticationFilter`(access_token 쿠키, principal getName()=email), `silentRefreshFilter`, 미인증 EntryPoint=`loginRedirectEntryPoint`(302 `/login`), CSRF=`CookieCsrfTokenRepository`(쿠키 저장 — 052), `logout().disable()`.
  - → **`/setup/admin`은 어떤 매처에도 안 걸려 `anyRequest().authenticated()`에 빠진다 → permitAll 명시 필요.** `/admin/**`가 hasRole(ADMIN)이므로 경로를 `/admin/...`로 두면 안 됨 — `/setup/admin` 채택(충돌 없음).
- **`web/member/LoginViewController.java`**(`:13-20`) — `@GetMapping("/login")` → `"auth/login"` 뷰명만 반환(로직 없음). **게이트 삽입 지점**.
- **`web/member/MemberSignupViewController.java`** — 폼 컨트롤러 선례: `@Controller`+`@RequiredArgsConstructor`, `member.spi` facade 주입, `GET`은 빈 폼 모델 + 뷰명, `POST`는 `@Valid @ModelAttribute` + `BindingResult`(폼 바로 뒤) → 검증 실패 시 비번 clear 후 재렌더, 성공 시 `redirect:/login?...`. **이 패턴을 그대로 따른다.**
- **`web/auth/CookieLoginViewController.java`** — **web→member.spi facade 경유 + 서블릿 I/O는 web** 패턴의 권위 선례. 설계 노트: `WebModuleStructureTest`·`ModularityTests`가 **web→member.service 직접 의존 금지**, facade는 서블릿 타입 비노출을 강제. → 신규 컨트롤러도 **반드시 facade 경유**.
- **`member/spi/MemberSignupFacade.java`·`ViewAuthFacade.java`** — published port(인터페이스) in `member.spi`(`@NamedInterface("spi")`), 구현체는 `member.service`의 `*FacadeImpl`. scalar/값 객체만 노출(서블릿 타입 금지).
- **`member/dto/SignupForm.java`** — 가변 POJO(`@Getter/@Setter/@NoArgsConstructor`), `@PasswordMatches`(클래스 레벨 교차검증), `@Email`/`@NotBlank`/`@Size(min=MemberPasswordPolicy.MIN_LENGTH)`. **부트스트랩 폼이 미러링할 검증 선례**(phone 제외).
- **`templates/auth/login.html`** — `layout/blank :: blank(title, content=~{::main})` 기반, `<main>` 내부에 폼·`th:if="${param.X}"` 안내. `th:action`이 `_csrf` 자동 주입. **신규 화면 템플릿 선례**(MEMORY: inline-script-must-be-inside-main — 스크립트 불요).
- **Flyway**: `V2__users_role_hierarchy.sql`가 `CHECK (role IN ('ADMIN','SELLER','CONSUMER'))` 이미 적용 → **마이그레이션 불요**.
- **`member/AdminAccountSeedTest`**(test) — `-Dseed.admin.enabled=true`로 수동 ADMIN 심기(UPSERT). 개발 시드 경로로 **유지**(본 작업과 무관, 제거 안 함).

---

## 1. 설계 방식 · 이유

### 1.1 게이트(GET /login) — 도메인 질의는 facade로
- `GET /login`에서 **ADMIN이 0명이면 `redirect:/setup/admin`**, 1명 이상이면 기존대로 `"auth/login"`. "ADMIN 존재 여부"는 도메인 질의이므로 web이 직접 Repository를 보지 않고 **`AdminBootstrapFacade.adminExists()`**(member.spi)를 호출한다(web→member.spi 단방향, package-structure-rule).
- `LoginViewController`에 facade를 주입(`@RequiredArgsConstructor`). 게이트는 **redirect만** 수행 — 비즈니스 로직 없음(web 규칙 준수).
- **모든 미인증 진입점이 자동 커버**: 보호 경로(`/`, `/cart` 등) 미인증 요청 → View EntryPoint가 `302 /login` → 게이트가 `/setup/admin`으로 재유도. 따라서 게이트는 `/login` 한 곳에만 두면 전 진입점에 적용된다(최소 변경).
- **성능**: `adminExists()`는 `countByRole(ADMIN) > 0` 1쿼리. 로그인 페이지 로드는 저빈도 → 직접 질의로 충분. (영구 true 캐싱은 과설계 — Non-goal. ADMIN은 changeRole로 강등돼도 마지막 ADMIN 강등이 금지돼 0으로 회귀 불가하지만, 캐시 도입 이득이 미미.)

### 1.2 생성 화면(GET /setup/admin) — 닫힘 우선
- `GET /setup/admin`: **`adminExists()`면 `redirect:/login`**(이미 부트스트랩 완료 — 화면 폐쇄), 아니면 빈 `AdminSetupForm` 모델 + `"auth/admin-setup"` 렌더.
- 닫힘 검사를 GET·POST **양쪽**에 두는 이유: GET 게이트만으로는 POST 직접 호출(permitAll)을 못 막는다 → POST도 service 레벨에서 재확인(§1.3).

### 1.3 생성 처리(POST /setup/admin) + 도메인 메서드 분리
- **신규 도메인 메서드 `MemberService.bootstrapFirstAdmin(email, rawPassword, name)`**(`@Transactional`):
  1. **트랜잭션 내 `countByRole(ADMIN) != 0`이면 `AdminAlreadyExistsException`(409)** — 동시 경합/직접 POST 가드(닫힘 불변식의 최종 방어선).
  2. 이메일 정규화(trim) + `existsByEmail` → `DuplicateEmailException`.
  3. `passwordEncoder.encode` (BCrypt, 원문 미저장).
  4. `memberRepository.save(User.of(normalizedEmail, hash, name.trim(), null, Role.ADMIN))` — phone 없음, **이벤트 미발행**(확정 결정 2).
  5. `DataIntegrityViolationException`→`DuplicateEmailException` 흡수(signup 선례 동일).
  - **signup과 분리 이유**: signup은 role=CONSUMER 강제 + `MemberRegisteredEvent` 발행 + phone 처리 — 부트스트랩은 role=ADMIN, 무이벤트, ADMIN-부재 가드가 추가돼 정책이 상이. 분리가 옳다(공통 BCrypt 1줄을 위해 합치면 분기 폭증).
- **신규 `MemberService.adminExists()`**(`@Transactional(readOnly=true)`): `return memberRepository.countByRole(Role.ADMIN) > 0;`
- **컨트롤러 `AdminSetupViewController`(`web/member` 확정)** — 게이트가 들어가는 `LoginViewController`와 같은 패키지, 회원 생성 폼인 `MemberSignupViewController` 선례와 동일 위치(라우팅 모호성 제거; `web/auth`에 두지 않는다):
  - `GET /setup/admin`: `facade.adminExists()` → true면 `redirect:/login`, false면 모델 + 뷰.
  - `POST /setup/admin`: `@Valid @ModelAttribute("adminSetupForm") AdminSetupForm` + `BindingResult` → 검증 실패면 비번 clear 후 `"auth/admin-setup"` 재렌더; `facade.createFirstAdmin(...)` 호출 → `DuplicateEmailException`이면 email 필드 에러 + 비번 clear 재렌더, **`AdminAlreadyExistsException`이면 `redirect:/login`**(이미 닫힘), 성공이면 `redirect:/login?adminCreated`.
  - 컨트롤러는 facade만 의존(member.service·Repository 직접 참조 금지).

### 1.4 facade(published port)
- **신규 `member/spi/AdminBootstrapFacade.java`**(인터페이스):
  - `boolean adminExists();`
  - `void createFirstAdmin(String email, String rawPassword, String name);` — 실패 시 `DuplicateEmailException`/`AdminAlreadyExistsException`(common — OPEN 모듈) 전파. 서블릿 타입 비노출.
- **신규 `member/service/AdminBootstrapFacadeImpl.java`**(`@Service`, `@RequiredArgsConstructor`): `MemberService`에 위임(facade는 얇게).

### 1.5 폼 DTO·검증
- **신규 `member/dto/AdminSetupForm.java`** — `SignupForm` 미러링(phone 제외): `@PasswordMatches` 클래스 레벨, `email`(@NotBlank+@Email), `password`(@NotBlank+@Size(min=MemberPasswordPolicy.MIN_LENGTH)), `passwordConfirm`(@NotBlank), `name`(@NotBlank). 가변 POJO(`@Getter/@Setter/@NoArgsConstructor`). 검증 실패 재렌더 시 비번 echo 차단(컨트롤러 `clearPasswords`).
- 기존 `@PasswordMatches`(`member.dto.validation`)·`MemberPasswordPolicy.MIN_LENGTH`(8) 재사용 — 새 검증 애노테이션 신설 금지.

### 1.6 예외
- **신규 `common/exception/AdminAlreadyExistsException`** — `BusinessException` 확장, `HttpStatus.CONFLICT`(409). signup의 `DuplicateEmailException`과 동일 계열 스타일. View에서는 상태코드가 아니라 redirect로 변환(error-response-rule: View=redirect/재렌더). REST 경로 없음.

### 1.7 보안 설정(SecurityConfig)
- View 체인 authorize에 **`GET /setup/admin`·`POST /setup/admin` permitAll** 추가(`/signup` permitAll 라인 근처). 경로가 `/admin/**`(hasRole ADMIN)와 겹치지 않음(`/setup/...`).
- CSRF는 기존 `CookieCsrfTokenRepository`가 보호 — 폼 `th:action`이 `_csrf` 자동 주입(추가 설정 불요). STATELESS·EntryPoint·필터 **무변경**.
- **REST 추가 없음**: api-authorization-rule상 ADMIN 생성은 매우 민감 → 화면(SSR) 1회성 경로로 한정하고 `/api/v1/**`엔 노출하지 않는다.

---

## 2. 구성 요소

- **신규 `member/spi/AdminBootstrapFacade.java`** — `adminExists()`, `createFirstAdmin(email, rawPassword, name)`(§1.4).
- **신규 `member/service/AdminBootstrapFacadeImpl.java`**(`@Service`) — `MemberService` 위임.
- **수정 `member/service/MemberService.java`** — `boolean adminExists()`(readOnly) + `User bootstrapFirstAdmin(email, rawPassword, name)`(§1.3). Repository 호출은 이 클래스에 유지. **클래스 Javadoc(`:32-34`, "로그인 자격증명 검증, 사용자 조회, 검색, 권한 변경 담당")에 "최초 ADMIN 부트스트랩"을 추가 갱신**한다.
- **신규 `member/dto/AdminSetupForm.java`**(§1.5).
- **신규 `common/exception/AdminAlreadyExistsException.java`**(§1.6).
- **신규 `web/member/AdminSetupViewController.java`**(또는 `web/auth`) — `GET/POST /setup/admin`(§1.3). facade 주입.
- **수정 `web/member/LoginViewController.java`** — `AdminBootstrapFacade` 주입, `GET /login` 게이트(adminExists 0명 → `redirect:/setup/admin`).
- **수정 `security/SecurityConfig.java`** — View 체인 authorize에 `/setup/admin` GET·POST permitAll(§1.7).
- **신규 `templates/auth/admin-setup.html`** — `layout/blank` 기반, `<main>` 내 폼(email/password/passwordConfirm/name) + `th:action="@{/setup/admin}"`(CSRF 자동) + `th:field` + 필드 에러 표시. login.html 톤 일치.
- **무변경**: API 체인, JWT/쿠키/세션, `signup`/`changeRole`, `MemberRegisteredEvent` 발행, `AdminAccountSeedTest`, Flyway.

---

## 3. 데이터 흐름

**(1) 부트스트랩 게이트(ADMIN 0명)**
1. 사용자가 `/`(또는 보호 경로) 접근 → 미인증 → View EntryPoint `302 /login`.
2. `GET /login` → `LoginViewController` → `facade.adminExists()`=false → `redirect:/setup/admin`.
3. `GET /setup/admin` → `adminExists()`=false → 빈 `AdminSetupForm` + `"auth/admin-setup"` 렌더.

**(2) 최초 ADMIN 생성**
1. `POST /setup/admin`(email/password/passwordConfirm/name + `_csrf`) → `AdminSetupViewController`.
2. `@Valid` 실패 → 비번 clear → `"auth/admin-setup"` 재렌더(필드 에러).
3. `facade.createFirstAdmin` → `MemberService.bootstrapFirstAdmin`: `countByRole(ADMIN)==0` 재확인 → `existsByEmail` → BCrypt → `User.of(..., Role.ADMIN)` 저장(**이벤트 없음**).
4. 성공 → `redirect:/login?adminCreated`. (`login.html`에 `param.adminCreated` 안내 추가 — view-implementor.)
5. 사용자가 방금 만든 계정으로 일반 로그인(기존 흐름).

**(3) 부트스트랩 폐쇄(ADMIN ≥1)**
1. `GET /login` → `adminExists()`=true → 기존 `"auth/login"` 정상.
2. `GET /setup/admin` 직접 접근 → `adminExists()`=true → `redirect:/login`.
3. `POST /setup/admin` 직접 호출 → `bootstrapFirstAdmin`이 `AdminAlreadyExistsException` → 컨트롤러 `redirect:/login`(생성 안 됨).

---

## 4. 예외 처리 전략

- **검증 실패(POST)**: `@Valid` BindingResult 에러 → 비번 clear → `"auth/admin-setup"` 재렌더(REST JSON 금지 — error-response-rule View=재렌더). `@PasswordMatches` 불일치 동일.
- **이메일 중복**: `DuplicateEmailException` → `bindingResult.rejectValue("email", ...)` + 비번 clear → 재렌더(MemberSignupViewController 선례).
- **이미 ADMIN 존재**: `AdminAlreadyExistsException`(GET 게이트로 평시엔 도달 불가, 직접 POST/동시 경합 시) → `redirect:/login`(화면 폐쇄, 메시지 불필요 — 닫힌 화면이라 노출 정보 최소화).
- **동시성 unique 위반**: `DataIntegrityViolationException`→`DuplicateEmailException` 흡수(signup 동일).
- **비밀번호 원문 로그/echo 금지**(Constraint): 로그·재렌더에 원문 미포함.

---

## 5. 검증 방법

- **메인 게이트(필수)**: Modulith verify(`./gradlew :modulith:check` 또는 해당 verify 태스크 — web→member.spi 단방향, facade 서블릿 타입 비노출 회귀 가드) + **풀 스위트 그린**(testing-rule). 느린 통합은 타깃 우선, 풀 `./gradlew test`는 마지막 1회(MEMORY: testcontainers-red-green-iteration-cost).
- **단위(Mockito, `MemberServiceTest`)**:
  - `bootstrapFirstAdmin`: `countByRole(ADMIN)==0` → `save`에 `Role.ADMIN` 인자(ArgumentCaptor) + `passwordEncoder.encode` 호출 + **`eventPublisher.publishEvent` 미호출**(verifyNoInteractions/never) 단언.
  - `countByRole(ADMIN)>0` → `AdminAlreadyExistsException`, `save` 미호출.
  - `existsByEmail`=true → `DuplicateEmailException`.
  - `adminExists()`: count 0→false, 1→true.
- **슬라이스(MockMvc, `@WebMvcTest` + facade Mock)**:
  - `GET /login`: `adminExists()`=false → 3xx redirect `/setup/admin`; true → 200 + `auth/login`.
  - `GET /setup/admin`: true → redirect `/login`; false → 200 + `auth/admin-setup` + 모델 `adminSetupForm`.
  - `POST /setup/admin`: 검증 실패 → 200 재렌더; 성공 → redirect `/login?adminCreated`; `AdminAlreadyExistsException` → redirect `/login`. **CSRF 토큰 포함 요청으로 테스트**(permitAll이지만 CSRF 보호 유지).
- **통합(Testcontainers)**: 실 DB, ADMIN 0명 컨텍스트 → `POST /setup/admin` → `countByRole(ADMIN)==1` & `findByEmail(...).getRole()==ADMIN` 확인. **격리 전제 명시**: 테스트가 ADMIN을 직접 심지 않고(시드/`AdminAccountSeedTest` 비활성), `@Transactional` 롤백 또는 clean DB로 다른 테스트가 ADMIN을 남기지 않음을 보장(flaky 방지). (MEMORY: smallint/JdbcTypeCode·validate 무관하나 실DB 컨텍스트 안정성 유의.)
- **E2E(Playwright, 핵심 — MEMORY: verify-admin-list-page-features-with-e2e / 조건부 redirect)**: ADMIN 없는 깨끗한 DB → `/login` 접근 시 `/setup/admin` 표시 → 폼 입력·제출 → `/login?adminCreated` 안내 → 생성 계정으로 로그인 성공 → 로그아웃 후 `/setup/admin` 재접근 시 `/login`으로 닫힘 + `/login`이 더 이상 `/setup/admin`으로 안 보냄. (앱 기동·정리: MEMORY perf-test-notification log 모드 무관하나, 시드/계정 부트스트랩 주의.)

---

## 6. 트레이드오프

- **bootstrapFirstAdmin 분리 vs signup 파라미터화**: 분리 채택 — role/이벤트/가드 정책이 상이. 합치면 `boolean isAdmin`·이벤트 분기로 한 메서드가 비대(가독성·테스트성 악화).
- **게이트 위치 `/login` 한 곳 vs 글로벌 필터/인터셉터**: `/login` 채택 — EntryPoint가 모든 미인증을 `/login`으로 모으므로 한 곳 게이트로 충분. 필터는 매 요청 count 쿼리·과설계.
- **`/setup/admin` 경로 vs `/admin/setup`**: `/setup/admin` 채택 — `/admin/**`가 hasRole(ADMIN)이라 `/admin/setup`은 ADMIN 없으면 접근 불가(닭-달걀). `/setup/...`는 매처 충돌 없음.
- **동시 경합 advisory lock 미도입**: 트랜잭션 내 재확인으로 창 축소. 최초 1회·보호할 기존 ADMIN 없음 → 권한 상승 아님. 락은 후속 하드닝(Non-goal).
- **이벤트 미발행**: 부트스트랩=시스템 행위. 환영 이메일 부적절(확정 결정). 일반 가입 통계가 ADMIN을 포함하지 않는 부수효과는 의도된 것.
- **adminExists 무캐싱**: 저빈도 페이지라 1쿼리 허용. 캐시 도입은 무효화 복잡도 대비 이득 미미.

---

## Non-goals
- 다중 ADMIN 생성/관리 UI(기존 admin 회원관리 책임). `AdminAccountSeedTest` 제거. 자동 로그인·토큰/세션 변경. REST(`/api/v1/**`) ADMIN 생성 엔드포인트. advisory lock·adminExists 캐싱. Flyway 변경.

---

## 오케스트레이션

1. **backend-implementor**(주축):
   - `member/service`: `MemberService.adminExists()`+`bootstrapFirstAdmin()`, `AdminBootstrapFacadeImpl`.
   - `member/spi`: `AdminBootstrapFacade`.
   - `member/dto`: `AdminSetupForm`.
   - `common/exception`: `AdminAlreadyExistsException`.
   - `web/member`: `AdminSetupViewController`(GET/POST `/setup/admin`), `LoginViewController` 게이트.
   - `security`: `SecurityConfig` View 체인 `/setup/admin` permitAll.
   - 단위/슬라이스/통합 테스트(§5).
2. **view-implementor**:
   - `templates/auth/admin-setup.html`(layout/blank, `<main>` 내 폼·필드 에러·CSRF 자동). `login.html`에 `th:if="${param.adminCreated}"` 안내 추가.
3. **reviewer** → (FAIL 시) **fixer** → 재리뷰. 중점: 닫힘 불변식(GET·POST 양쪽 가드)·이벤트 미발행·role=ADMIN·web→member.spi 경계·CSRF·비번 echo 차단·경로 충돌(`/admin/**`).
4. **메인 게이트**: Modulith verify + 풀 스위트 그린.
5. **e2e-runner**: ADMIN 0→ `/login`→`/setup/admin`→생성→`/login?adminCreated`→로그인→재접근 닫힘(조건부 redirect 실증).

---

## 완료 조건
- [ ] ADMIN 0명: `GET /login` → `redirect:/setup/admin`, `GET /setup/admin` → 폼 렌더.
- [ ] `POST /setup/admin` → `Role.ADMIN` 계정 생성(BCrypt 해시·name 암호화), **`MemberRegisteredEvent` 미발행**, 성공 `redirect:/login?adminCreated`.
- [ ] ADMIN ≥1: `GET /login` 정상 로그인 화면, `GET/POST /setup/admin` → `/login`(엔드포인트 폐쇄).
- [ ] 검증 실패/이메일 중복 → 비번 clear 후 폼 재렌더(필드 에러). 이미 ADMIN 존재(직접 POST) → `redirect:/login`(생성 안 됨).
- [ ] web→member.spi 단방향(facade 경유), `/setup/admin` permitAll + CSRF 보호, `/admin/**` 매처 무충돌.
- [ ] 단위(이벤트 미발행·role=ADMIN·가드)·슬라이스(게이트/닫힘 redirect)·통합(실DB 영속)·E2E(조건부 redirect 전 흐름) 통과 + Modulith verify + 풀 스위트 그린.

---

## 코드 대조 요약 (메인 보고용)
- **읽은 핵심 파일**: `member/service/MemberService.java`(`signup` role=CONSUMER+이벤트·`changeRole` ADMIN 승격 금지·`countByRole` 사용 선례), `member/repository/MemberRepository.java`(`countByRole`·`existsByEmail` 재사용), `member/domain/User.java`+`Role.java`(`User.of`·name 자동암호화·`@Enumerated(STRING)`), `security/SecurityConfig.java`(View 체인 `:163-247`, `/admin/**` hasRole ADMIN, permitAll 패턴), `web/member/LoginViewController.java`(게이트 지점), `web/member/MemberSignupViewController.java`(폼 컨트롤러 선례), `web/auth/CookieLoginViewController.java`(web→spi facade 경계 선례), `member/spi/MemberSignupFacade.java`·`ViewAuthFacade.java`(published port), `member/dto/SignupForm.java`(검증 선례), `templates/auth/login.html`(화면 선례), `V2__users_role_hierarchy.sql`(role ADMIN 허용 — 마이그레이션 불요).
- **핵심 보안 불변식(reviewer 주목)**: ADMIN ≥1이면 `GET`·`POST /setup/admin` 양쪽 폐쇄(공개 엔드포인트의 권한 상승 차단). POST는 GET 게이트만으로 못 막으므로 **service 트랜잭션 내 `countByRole==0` 재확인이 최종 방어선**.
- **경로 함정**: `/admin/**`=hasRole(ADMIN)이라 부트스트랩 경로를 `/admin/...`에 두면 닭-달걀(ADMIN 없이 접근 불가) → `/setup/admin` 채택.
- **마이그레이션·이벤트·세션 변경 없음** — 기존 구조 재사용.

# 054 Plan — View 인증 JWT 단일화 Phase 3: JWT 쿠키 인증 cutover + 세션 제거

> Task: `docs/tasks/backend/054-backend-shop-core-view-auth-jwt-cookie-cutover.md`
> 전략: 052(CSRF·SavedRequest 쿠키화)·053(Flash 쿠키화)가 세션의 **비인증 의존**을 모두 stateless로 옮겨놨다. 이제 View(브라우저) 인증을 formLogin 세션 → **JWT HttpOnly 쿠키 + STATELESS**로 cutover하고 세션을 완전히 제거한다(JSESSIONID 미생성). API 체인(`/api/v1/**`)은 이미 JWT — 무변경.
> 경로 추적: 감사 #1 권장안(`spring-session-data-redis` 외부화)과 **다른 경로**를 task가 채택했다 — 세션 스토어를 외부화하는 대신 자족(self-contained) JWT 쿠키 cutover로 **세션 스토어 자체를 제거**한다(멀티 인스턴스 수평 확장을 세션 복제 없이 달성).

---

## 0. 코드 대조 (현재 상태 — 작업 트리 실측)

- **`security/SecurityConfig.java`** — 3체인 구조:
  - actuator 체인 `@Order(0)`(`:68-82`): `EndpointRequest.toAnyEndpoint()` + CSRF disable + STATELESS. **무변경**.
  - API 체인 `@Order(1)`(`:88-149`): `securityMatcher("/api/v1/**")` + CSRF disable + STATELESS + `addFilterBefore(jwtAuthenticationFilter, UsernamePasswordAuthenticationFilter.class)` + `RestAuthenticationEntryPoint`(401 JSON). **JWT 재사용 기준 — 무변경**.
  - View 체인 `@Order(2)`(`:155-228`): **formLogin/logout + 세션 생성(기본)** + `CookieRequestCache`(`:220`, `:241-247`, 052) + `CookieCsrfTokenRepository.withHttpOnlyFalse()`(`:225`, 052) + `userDetailsService`. **전면 개편 대상.** 현재 `sessionCreationPolicy` 미지정 → Spring 기본 `IF_REQUIRED`(formLogin이 세션 생성).
  - `jwtAuthenticationFilter` 빈(`:275-280`): `JwtTokenProvider` + `RefreshTokenStore` 주입.
- **`JwtAuthenticationFilter`**(`security/`): `OncePerRequestFilter`. **Authorization: Bearer 헤더만** 파싱(`extractBearerToken`, `:84-90`). 검증 흐름: `jwtTokenProvider.parse` → `extractJti` → `refreshTokenStore.isBlacklisted(jti)`(매 요청 Redis 조회) → 유효 시 `UsernamePasswordAuthenticationToken(userId, null, authorities)`로 SecurityContext 설정. **principal = `userId`(Long)**.
- **`JwtTokenProvider`**: `createAccess(userId, email, roles)` — access 클레임에 `sub=userId`, **`email`**, `roles`, `jti`, `exp`. `createRefresh(userId)` — refresh 클레임 `sub`/`jti`/`exp`만(roles·email 없음). `parse`(만료→`InvalidTokenException`), `extractUserId`, `extractRoles`, `extractJti`, `remainingTtl`. **`extractEmail`은 없음**(claim은 있으나 추출 헬퍼 미존재).
- **`RefreshTokenStore`/`RedisRefreshTokenStore`**: `storeRefresh(userId, token, ttl)`(SHA-256 hash 저장), `matchesRefresh(userId, token)`, `deleteRefresh(userId)`, `blacklistAccess(jti, ttl)`, `isBlacklisted(jti)`. **refresh 회전 없음** — 키는 `{prefix}{userId}` 1개, 같은 userId 재로그인 시 덮어쓰기.
- **`AuthServiceResponse`**(`member/service/`, `:42-56`): API 로그인 토큰 발급 로직. `memberService.authenticate(email,pw)` → `createAccess`/`createRefresh` → `storeRefresh` → `recordLoginByEmail` → `TokenResponse`. **`refresh()`(`:65-89`)는 회전하지 않음**(기존 refresh 유지, 새 access만 발급) — 무음 refresh 동시성에 유리. `logout()`(`:97-111`): `deleteRefresh` + `blacklistAccess`. ← **054 브라우저 로그인/refresh/로그아웃이 공용화할 발급 로직.**
- **현재 브라우저 로그인 흐름**: `web/member/LoginViewController`(GET `/login` → `auth/login` 뷰만), formLogin이 POST `/login` 처리(`loginProcessingUrl`), 파라미터 **`username`/`password`**(Spring 기본), 성공 시 `defaultSuccessUrl("/")`/SavedRequest 복귀, 실패 `/login?error`. `LoginActivityRecorder`가 `InteractiveAuthenticationSuccessEvent`로 `last_login_at` 기록(**formLogin 전용 이벤트**).
- **로그인 템플릿**: `templates/auth/login.html` — `form th:action="@{/login}" method="post"`, `name="username"`/`name="password"`, `param.error`/`param.logout`/`param.signup` 등 분기, `_csrf` 자동 주입. **로그아웃 폼**: `home/home.html`·`fragments/header.html` — `form th:action="@{/logout}" method="post"`.
- **★ View principal 계약(핵심 회귀점)**: `web/support/CurrentActorResolver`(`:16-21`)가 `auth.getName()` → **email** 로 `CurrentActor`를 만들고, 14개 View 컨트롤러가 `actor.email()`을 facade에 넘긴다(예 `CartViewController:64 cartFacade.getCart(actor.email())`). 템플릿도 `sec:authentication="name"`(header.html·home.html)으로 **email 표시**. **현 JWT 필터는 principal=userId(Long) → `getName()`이 숫자 문자열**을 반환 → cutover 시 모든 View 인증 사용처가 깨진다. **→ View용 JWT 인증은 principal의 `getName()`이 email이어야 한다.**
- 052·053 **이미 구현 완료**(`web/support/CookieFlashMapManager`·`FlashCookieConfig` 존재, SecurityConfig 쿠키화 반영). 본 Phase는 이들이 **STATELESS에서도 세션 의존 없이** 동작함을 회귀 검증만 하면 된다(둘 다 쿠키 저장 — 세션 비의존 설계 확인 완료).

---

## 1. 설계 방식 · 이유

### 1.1 토큰 발급 로직 공용화 (중복 금지)
- **발급 로직은 `AuthServiceResponse`에 이미 존재**(login/refresh/logout). 그러나 `AuthServiceResponse`는 ServiceResponse 레이어 = **REST 응답 조합 전용**(architecture-rule: View/Scheduler에서 사용 금지). View가 이를 직접 호출하면 레이어 위반.
- **해결: 토큰 발급 코어를 `security` 모듈의 신규 application 컴포넌트 `AuthTokenIssuer`로 추출**한다. 입력=인증된 `User`(또는 userId·email·roles), 출력=`IssuedTokens(accessToken, refreshToken, accessTtl)` 값 객체. 내부에서 `createAccess`+`createRefresh`+`storeRefresh`를 1곳에 수행. **API(`AuthServiceResponse`)와 View(`AuthCookieService`)가 동일 `AuthTokenIssuer`를 호출**하고, **전달 매체만 다르게** 한다:
  - API: `IssuedTokens` → `TokenResponse` JSON 바디.
  - View: `IssuedTokens` → `Set-Cookie`(access_token/refresh_token).
- 이렇게 하면 발급 시퀀스(클레임 구성·refresh hash 저장·TTL)가 **단일 코드**가 된다. `AuthServiceResponse.login()`은 `authenticate` + `AuthTokenIssuer.issue(user)` + `recordLoginByEmail` 조합으로 축소(리팩터링 — 동작 동일, 회귀 테스트로 가드). refresh 재발급(새 access only)·logout(revoke+blacklist)도 `AuthTokenIssuer`/store 위임으로 공용화 검토하되, **본 Phase 범위는 "중복 발급 코드 금지"** 이므로 access+refresh 동시 발급(login) 경로 공용화를 최소 필수로 한다.

### 1.2 쿠키 JWT 인증 필터: 기존 필터 **공용화 확장** (신설 지양)
- **결정: 기존 `JwtAuthenticationFilter`를 토큰 소스 추상화로 확장**한다(View 전용 필터 신설은 코드 중복). 현재 `extractBearerToken`(헤더)만 보던 것을, **헤더 OR `access_token` 쿠키** 둘 다 탐색하도록 `extractToken(request)`로 일반화:
  - API 요청(`/api/v1/**`): Authorization 헤더 우선(기존 동작 보존).
  - View 요청: `access_token` 쿠키.
  - 한 필터가 둘 다 처리해도 안전(체인별 `securityMatcher`로 격리, 같은 토큰 의미). 단 **principal 차이**(§0 ★) 때문에 인증 토큰 생성 방식을 분기해야 한다:
    - **API**: 현행 유지(principal=userId) — REST는 `(long) authentication.getPrincipal()`로 userId를 추출(`CartServiceResponse:35`·`MemberServiceResponse:55` 선례) — principal 객체가 Long으로 유지되어야 무회귀.
    - **View**: principal의 `getName()`=email 필요.
  - **선택지 비교**:
    - (A) 필터를 체인별 2개 빈으로 분리(`apiJwtAuthenticationFilter`/`viewJwtAuthenticationFilter`)하되 **공용 파싱·blacklist 로직은 동일 클래스**에 두고 "principal 빌더"만 주입.
    - (B) principal을 userId·email **둘 다 담는 통일 객체**(`AuthenticatedUser(userId,email,roles)`)로 바꾸고, `getName()`=email override + REST 사용처를 userId 접근으로 일괄 수정.
  - **채택: (A)**. API 체인 인증 토큰의 principal이 **Long으로 유지**돼야 `getPrincipal()` 캐스팅 사용처(ServiceResponse 다수 — `CartServiceResponse:35`·`MemberServiceResponse:55`)가 무회귀다. (B)는 그 `(long) getPrincipal()` 캐스팅 사용처를 전수 수정해야 해 블라스트 반경이 task 범위를 넘는다. (A)는 **토큰 소스(헤더/쿠키)와 principal 표현(userId/email)** 2개 전략만 체인별로 주입 — `JwtAuthenticationFilter`에 `Function<HttpServletRequest,String> tokenExtractor`와 principal 빌더(`PrincipalFactory`)를 생성자 파라미터로 받게 하고, 빈 2개를 `@Order(1)`/`@Order(2)` 체인에 각각 `addFilterBefore`. **단일 클래스·로직 공용, 빈 2개**로 중복 없이 분기.
  - View access 클레임에 **email이 이미 들어있으므로**(§0 createAccess) `extractEmail(claims)` 헬퍼(신규)로 꺼내 principal 구성 — refresh 토큰엔 email 없음에 주의(인증은 access로만).
- **blacklist 매 요청 조회**(task 결정): View 필터도 `isBlacklisted(jti)`를 **매 요청 호출**(API와 동일). 로그아웃 즉시 반영 위해 stateless라도 유지.

### 1.3 무음(silent) refresh 필터
- **access 쿠키 만료 + refresh 쿠키 유효** 시 새 access를 발급·쿠키 재설정 후 요청을 그대로 진행(30분마다 로그아웃 방지). View 체인 전용 `SilentRefreshFilter`(`OncePerRequestFilter`)를 **JWT 인증 필터 앞**에 배치:
  1. SecurityContext가 이미 인증됨 → 통과(access 유효).
  2. access 쿠키 만료/무효 + `refresh_token` 쿠키 존재 → `jwtTokenProvider.parse(refresh)`(만료면 실패→무처리, 인증 필터가 미인증 처리) → `matchesRefresh(userId, refresh)` 확인 → **OK면 `AuthTokenIssuer`로 새 access 발급**(refresh는 회전하지 않음 — §1.4) → `access_token` 쿠키 재설정 → 이번 요청에서 인증되도록 SecurityContext 채움.
  - **처리 경로 확정**: `SilentRefreshFilter`가 새 access 발급 후 **직접 SecurityContext 설정 + `AuthCookies.writeAccess`(Set-Cookie)** 까지 수행하고, 후속 JWT 인증 필터는 평상 경로(이미 인증됨 → 통과)만. 단 로직 중복 회피 위해 access 검증/principal 구성은 §1.2의 공용 헬퍼 재사용. (새 access 쿠키를 request에 래핑해 후속 JWT 필터가 인증하는 방식은 필터 순서상 취약하므로 비권장.)
- **회전 비활성 채택 이유**(§1.4)로 동시 다중 탭 refresh가 멱등.

### 1.4 무음 refresh 동시성 (다중 탭)
- `RedisRefreshTokenStore`는 **refresh를 회전하지 않는다**(§0: `matchesRefresh`만, 재발급 시 store 갱신 없음). 즉 같은 refresh로 N개 탭이 동시에 access 재발급해도 **모두 성공**(refresh 키 불변, hash 비교 통과). **회전 도입하지 않음** — 회전하면 동시 만료 시 한 탭만 성공/나머지 강제 로그아웃(UX 악화)되고, refresh 재사용 탐지는 task Non-goal. **결정: 회전 비활성 유지(멱등) → 무음 refresh 동시성 안전.** (보안상 refresh 탈취 회전 탐지는 후속 과제로 명시.)

### 1.5 미인증 진입점 분기 (View 302 vs API 401)
- API 체인은 `RestAuthenticationEntryPoint`(401 JSON) **유지**.
- View 체인은 미인증 시 **302 `/login`**. formLogin 제거로 그 기본 EntryPoint(LoginUrlAuthenticationEntryPoint)가 사라지므로, **`LoginUrlAuthenticationEntryPoint("/login")`을 명시 등록**(또는 동등 redirect EntryPoint). 보호 View + 토큰 없음/만료/무효/blacklist → 302 `/login`. 052 `CookieRequestCache`가 원 URL 저장 → 로그인 후 복귀.
- **체인별 EntryPoint 완전 분리** 확인: API=401, View=302. (현재도 분리돼 있으나 View는 formLogin이 암묵 제공 → 명시 빈으로 전환.)

### 1.6 쿠키 표준 (SSOT)
- 이름: `access_token` / `refresh_token`(상수). 속성: `HttpOnly`·`Secure`·`SameSite=Lax`·`Path=/`.
  - `HttpOnly`: JS 접근 불필요(SSR) → XSS 토큰 탈취 차단.
  - `SameSite=Lax`: top-level GET 리다이렉트·same-site 폼 POST에 쿠키 전송됨(로그인 폼·네비 OK). `None` 회피.
  - `Secure`: 052/053 쿠키 정책과 일치(운영 HTTPS 전제, 로컬 http 호환 방식 동일 따름).
  - maxAge: access ≈ `JwtProperties.accessTtl`(PT30M), refresh ≈ `refreshTtl`(P14D). **TTL SSOT = `JwtProperties`** — 쿠키 maxAge·JWT exp·Redis TTL 모두 이 값 참조(별도 상수 금지).
  - SameSite 작성: `jakarta.servlet.http.Cookie` 미지원 → 053 선례대로 `org.springframework.http.ResponseCookie` 빌더 → `response.addHeader("Set-Cookie", ...)`.
- 쿠키 read/write를 **`AuthCookies` 유틸 1곳**에 집중(이름·속성·TTL 단일 정의) — 발급/무음refresh/로그아웃이 공용.

### 1.7 세션 제거
- View 체인 `sessionCreationPolicy(STATELESS)` 추가, `formLogin(...)` 블록 제거. spring-session 미도입. → JSESSIONID 미생성. `LoginActivityRecorder`의 `InteractiveAuthenticationSuccessEvent`는 formLogin 제거로 **더 이상 발행 안 됨** → `last_login_at` 기록이 누락된다. **→ `AuthTokenIssuer`/`AuthCookieService` 로그인 경로에서 `recordLoginByEmail`를 명시 호출**(API `login()`이 이미 호출하는 것과 동일 패턴). `LoginActivityRecorder`는 미사용화(제거 또는 비활성) — 회귀 가드 필요.

---

## 2. 구성 요소

- **신규 `security/AuthTokenIssuer.java`**(`@Component`): `IssuedTokens issue(long userId, String email, List<String> roles)` — `createAccess`+`createRefresh`+`storeRefresh(refreshTtl)`. API·View 공용 발급 코어(§1.1). 값 객체 `IssuedTokens(access, refresh, accessTtlSeconds)`.
- **신규 `security/AuthCookies.java`**(유틸/`@Component`): 쿠키 이름 상수, `ResponseCookie` 빌더(HttpOnly·Secure·Lax·Path·maxAge), `writeTokens(response, IssuedTokens)`, `writeAccess(...)`, `clearTokens(response)`(maxAge=0), `readAccess(request)`, `readRefresh(request)`. TTL은 `JwtProperties` 주입(§1.6).
- **신규 `member/service/AuthCookieService.java`(=`ViewAuthService`)**(`@Service`): View 로그인/로그아웃 application 로직. 배치는 아래 **레이어 주의**에서 `member/service`로 확정.
  - `loginAndSetCookies(email, rawPassword, response)`: `memberService.authenticate` → `AuthTokenIssuer.issue` → `recordLoginByEmail` → `AuthCookies.writeTokens`. 실패(`InvalidCredentialsException`) 전파 → 컨트롤러가 `/login?error` redirect.
  - `logout(request, response)`: access 쿠키 → jti/userId 추출 → `deleteRefresh` + `blacklistAccess` → `AuthCookies.clearTokens`.
  - **레이어 주의**: `authenticate`·`recordLoginByEmail`은 member 도메인 서비스 호출 → member 모듈에 둔다. **배치 결정(확정)**: **`ViewAuthService`=`member/service`**. 근거 — (1) member→security 의존은 `AuthServiceResponse`(이미 `security.JwtTokenProvider`·`RefreshTokenStore`·`JwtProperties` import) 선례로 확립된 **허용 방향**이고, (2) web 배치는 `package-structure-rule`(web.support는 Authentication→CurrentActor류만, 비즈니스/트랜잭션 금지)로 배제된다. 쿠키 I/O(`AuthCookies`)·발급 코어(`AuthTokenIssuer`)는 security에 둔다. Modulith verify는 회귀 가드로만(경계 위반 없음 재확인).
- **수정 `security/JwtAuthenticationFilter.java`**: `extractToken`을 토큰 소스 전략(`Function<HttpServletRequest,String>`)으로 일반화 + principal 빌더 전략 주입(§1.2 (A)). 단일 클래스, 빈 2개.
- **신규 `security/SilentRefreshFilter.java`**(`OncePerRequestFilter`, View 체인 전용, §1.3).
- **신규 `security/CookieLoginViewController.java` 또는 기존 `web/member` 확장**: `POST /login`(폼 username/password) → `AuthCookieService.loginAndSetCookies` → 성공 redirect(SavedRequest 복귀 또는 `/`), 실패 `/login?error`. `POST /logout` → 쿠키 제거+revoke → `/login?logout`. **배치**: View 진입점이므로 `web/member` 또는 `web/auth`(컨트롤러), 인증 로직은 service 위임(web에 비즈니스 금지 — package-structure-rule).
- **신규 `security` redirect EntryPoint**: View 체인용 `LoginUrlAuthenticationEntryPoint("/login")` 빈(§1.5).
- **수정 `security/SecurityConfig.java`**:
  - API 체인: `addFilterBefore`를 `apiJwtAuthenticationFilter`(헤더 소스/userId principal)로(동작 동일 — 기존 빈을 전략 주입 형태로 교체). **나머지 무변경.**
  - View 체인: `formLogin(...)` 제거, `sessionCreationPolicy(STATELESS)` 추가, `addFilterBefore(silentRefreshFilter, ...)` + `addFilterBefore(viewJwtAuthenticationFilter, UsernamePasswordAuthenticationFilter.class)`, `exceptionHandling.authenticationEntryPoint(loginRedirectEntryPoint)`. `logout(...)`은 커스텀 컨트롤러로 대체하거나 Security `logout` 핸들러에 쿠키삭제+revoke 추가(택1 — 컨트롤러 권장: blacklist/revoke 로직 명시). CSRF(`CookieCsrfTokenRepository`)·`CookieRequestCache`·`userDetailsService`·authorizeHttpRequests **매처 전부 유지**.
  - `jwtAuthenticationFilter` 빈 → 전략 주입 빈 2개로 분할.
- **`JwtTokenProvider`**: `extractEmail(Claims)` 헬퍼 추가(access email claim 추출 — View principal용).
- **무변경**: API 체인 authorize 규칙·`RestAuthenticationEntryPoint`/`RestAccessDeniedHandler`, View authorize 매처, 052 CSRF/RequestCache, 053 Flash, 14개 View 컨트롤러·`CurrentActorResolver`(principal `getName()`=email 보장으로 무수정), 로그인/로그아웃 템플릿(파라미터명·action 동일 — formLogin과 동일 계약 유지).

---

## 3. 데이터 흐름 (4흐름)

**(1) 브라우저 로그인**
1. POST `/login`(폼 username/password + `_csrf`) → `CookieLoginViewController`.
2. `AuthCookieService.loginAndSetCookies`: `authenticate`(BCrypt) → `AuthTokenIssuer.issue`(access+refresh 발급, refresh hash Redis 저장) → `recordLoginByEmail`(last_login_at) → `AuthCookies.writeTokens`(Set-Cookie access_token·refresh_token, HttpOnly·Lax).
3. redirect: `CookieRequestCache` 저장 URL 복귀 또는 `/`. **세션 미생성**.
4. 실패: `InvalidCredentialsException` → redirect `/login?error`(템플릿 `param.error`).

**(2) 인증된 요청 (View)**
1. 보호 View 요청 + `access_token` 쿠키 동봉.
2. `SilentRefreshFilter`: access 유효 → 통과. `viewJwtAuthenticationFilter`: `extractToken`=쿠키 → `parse` → `isBlacklisted(jti)`(Redis 1회) → 유효 시 principal `getName()`=email인 Authentication 설정.
3. View 컨트롤러: `CurrentActorResolver.resolve(auth)` → `actor.email()` facade 전달(무회귀). `sec:authentication="name"`=email 렌더.

**(3) 무음 refresh**
1. 보호 View 요청, `access_token` 만료(쿠키 잔존하나 JWT exp 경과) + `refresh_token` 유효.
2. `SilentRefreshFilter`: access parse 실패(만료) 감지 → refresh `parse`+`matchesRefresh` OK → `AuthTokenIssuer`로 **새 access만 발급**(refresh 유지·회전X) → `AuthCookies.writeAccess`(새 access 쿠키) → SecurityContext 인증 설정 → 요청 진행(재로그인 없음).
3. refresh도 만료/무효 → 인증 미설정 → JWT 필터 통과 후 미인증 → EntryPoint 302 `/login`.
4. 다중 탭 동시 만료: refresh 불변이라 각 탭 독립 성공(멱등 §1.4).

**(4) 로그아웃**
1. POST `/logout`(+`_csrf`) → 컨트롤러 → `AuthCookieService.logout`.
2. access 쿠키 → jti/userId 추출 → `deleteRefresh(userId)`(refresh revoke) + `blacklistAccess(jti, remainingTtl)`(access 즉시 무효) → `AuthCookies.clearTokens`(maxAge=0).
3. redirect `/login?logout`. 이후 그 access는 blacklist로 매 요청 차단.

---

## 4. 예외 처리 전략

- **자격 실패(로그인)**: `InvalidCredentialsException`(열거 방지 동일 메시지) → 컨트롤러가 `/login?error` redirect(API의 401 JSON 아님 — error-response-rule View=redirect+flash). 쿠키 미발급.
- **토큰 만료/위조/blacklist(인증 요청)**: 인증 필터가 SecurityContext 미설정 → View EntryPoint **302 `/login`**(API는 401 유지). `InvalidTokenException`은 필터 내부에서 삼키고 미인증 위임(현 패턴 유지).
- **무음 refresh 실패**(refresh 만료/불일치/탈퇴): 새 access 미발급 → 미인증 → 302 `/login`. 탈퇴 사용자 차단은 `matchesRefresh`(logout 시 hash 삭제로 자연 실패) + 필요 시 active 확인(`AuthServiceResponse.refresh`의 `isActive()` 선례 참고).
- **쿠키 파싱/누락**: access 없음 → 미인증(보호 경로면 302). 손상 토큰 → parse 실패 → 미인증. fail-safe(예외 비전파).
- **CSRF**: 로그인/로그아웃 POST는 052 `CookieCsrfTokenRepository` + 폼 `_csrf` 히든으로 보호 유지(STATELESS와 무관 — 쿠키 저장).

---

## 5. 검증 방법

- **메인 게이트(필수)**: `./gradlew modulith:check`(Modulith verify — security/web/member 경계 회귀 가드, ViewAuthService=`member/service` 확정 배치의 위반 없음 재확인) + **풀 스위트 그린**(testing-rule). 느린 통합은 타깃 우선, 풀 ./gradlew test는 마지막 1회(MEMORY: testcontainers-red-green-iteration-cost).
- **단위/슬라이스**:
  - `JwtAuthenticationFilter` 쿠키 소스 + email principal 분기(헤더=userId/쿠키=email) 단위. **API 체인 인증 후 `authentication.getPrincipal() instanceof Long`(=userId 무회귀, `(long) getPrincipal()` 캐스팅 사용처 보존) 단언.**
  - `AuthCookies` 쿠키 속성(HttpOnly·Secure·Lax·Path·maxAge=accessTtl/refreshTtl) 라운드트립.
  - `SilentRefreshFilter`: access만료+refresh유효 → 새 access 쿠키+인증, refresh만료 → 미인증.
  - `AuthTokenIssuer` 공용화 회귀: API `AuthServiceResponse.login`이 동일 발급 결과 유지(기존 `AuthRestControllerSecurityTest`·토큰 테스트 그린).
  - `SecurityConfigTest`·`ActuatorSecurityTest` 그린(체인 분리 무회귀).
- **세션 제거 검증**: 로그인 응답에 **`Set-Cookie: JSESSIONID` 부재** + 후속 요청에 세션 생성 없음을 MockMvc/통합으로 단언(`Set-Cookie` 헤더에 JSESSIONID 미포함). 가능하면 `HttpSessionEventPublisher` 카운트 0 또는 `request.getSession(false)==null` 가드.
- **★ View principal 회귀(핵심)**: 쿠키 인증 후 `auth.getName()`=email → `CurrentActorResolver`·`sec:authentication="name"`·14개 facade 사용처(cart/order/review/account 등) 정상. **E2E 필수**(MockMvc는 쿠키↔템플릿 가시성 공백을 놓침 — MEMORY: verify-admin-list-page-features-with-e2e).
- **무세션 의존 무회귀**: 052 CSRF 폼 POST(전 폼)·053 Flash 1회성이 **세션 없이도** 정상(통합+E2E).
- **멀티 인스턴스 실증(task 핵심)**: 로컬 2-인스턴스(8080/8081, **세션 스토어 없음**, 동일 JWT secret) → 8080 로그인 `access_token` 쿠키로 8081 보호 페이지 인증 유지(JWT self-contained). bootRun JVM 누수·PG 고갈 주의(MEMORY: bootrun-jvm-leak-pg-exhaustion — 측정 후 taskkill java).
- **E2E 전체 회귀**: 로그인→복귀(SavedRequest)·장바구니·주문·결제·취소·판매자/admin 배송·상품/variant/이미지/카테고리 CRUD·account·리뷰·판매자 신청 + 로그아웃(쿠키 제거+blacklist 즉시 차단) + 무음 refresh(access TTL 경과 후 네비 유지).

---

## 6. 트레이드오프

- **필터 공용 확장 vs View 전용 필터 신설**: 확장 채택 — 파싱·blacklist 로직 단일화(중복 제거). 비용은 전략 주입 분기 복잡도 1단계. 신설은 isBlacklisted/parse 중복 → over-engineering·회귀 표면 증가.
- **principal 전략 (A) 체인별 빌더 vs (B) 통일 principal 객체**: (A) 채택 — REST 사용처(userId)·테스트 무회귀. (B)는 깔끔하나 `(long) authentication.getPrincipal()` 캐스팅 사용처(`CartServiceResponse:35`·`MemberServiceResponse:55` 등 ServiceResponse 다수) 전수 수정으로 task 범위 초과.
- **refresh 회전 비활성**: 멱등(다중 탭 안전)·UX 우선. 탈취 회전 탐지 미도입 → 보안상 후속 과제(명시). task Non-goal이라 본 Phase 미포함.
- **무음 refresh 필터 분리 vs 인증 필터 통합**: 분리 — 책임 단일(만료 시 재발급). 통합하면 인증 필터가 비대.
- **last_login_at**: formLogin 이벤트 소멸 → 로그인 서비스 명시 호출로 이전(API와 동일). 누락 방지 회귀 테스트 필수.
- **쿠키 4KB**: access JWT(email+roles claim) 수백 바이트, refresh 수백 바이트 → 한계 무해.

---

## Non-goals
- API 체인(`/api/v1/**`) 인가·발급 로직 변경(공용화 추출 외). 052·053 재작업. remember-me·OAuth·SPA·모바일·refresh 회전 탈취 탐지. principal 통일 객체(B) 리팩터링.

---

## 오케스트레이션

1. **backend-implementor**(보안/필터/서비스 — 작업의 주축):
   - `security`: `AuthTokenIssuer`·`AuthCookies`·`JwtAuthenticationFilter` 확장(전략 주입)·`SilentRefreshFilter`·View redirect EntryPoint·`JwtTokenProvider.extractEmail`.
   - `member/service`(확정): `ViewAuthService`(로그인/로그아웃 application) — `AuthServiceResponse.login`을 `AuthTokenIssuer` 공용화로 리팩터링(API 동작 보존).
   - `web/auth`(또는 web/member): `CookieLoginViewController`(POST /login·/logout).
   - `SecurityConfig`: View 체인 STATELESS+formLogin 제거+필터 2종+EntryPoint, API 체인 필터 빈 전략 교체(동작 동일).
   - 단위/슬라이스 테스트(§5). `LoginActivityRecorder` 처리(제거/대체) + last_login_at 회귀 가드.
2. **view-implementor**(템플릿 — 변경 필요 시 최소):
   - **원칙: 템플릿 무변경 목표**(login.html·logout 폼은 formLogin과 동일 action·파라미터명 유지 → 커스텀 컨트롤러가 같은 계약 수용). **단** principal `getName()`=email이 깨지지 않는지(`sec:authentication="name"`·header.html) E2E로 확인하는 책임이 view-implementor 몫. 로그인 실패/로그아웃 파라미터(`?error`/`?logout`) redirect 계약이 템플릿 분기와 일치하는지 점검. 실제 템플릿 수정이 필요해질 때만(예: 메시지 키 변경) 담당 — **현 설계상 수정 불요 예상.**
3. **reviewer** → (FAIL 시) **fixer** → 재리뷰. 중점: 발급 로직 공용화(중복 0)·체인별 principal(email/userId)·blacklist 매 요청·STATELESS+JSESSIONID 미생성·EntryPoint 분기(302/401)·모듈 경계(ViewAuthService 배치)·쿠키 속성 SSOT·052/053 무회귀.
4. **메인 게이트**: Modulith verify + 풀 스위트 그린.
5. **e2e-runner**: 로그인/복귀·전 폼·로그아웃 즉시차단·무음 refresh·세션 무회귀(052 CSRF·053 Flash)·**JSESSIONID 미생성**·**멀티 인스턴스 2노드 인증 유지**.

---

## 완료 조건
- [ ] View 체인 `STATELESS` + `access_token` 쿠키 JWT 인증, formLogin·세션 생성 제거 → **JSESSIONID 미생성**.
- [ ] 브라우저 로그인 → access/refresh HttpOnly·Secure·Lax·Path=/ 쿠키 발급, **API와 동일 `AuthTokenIssuer` 공용**(중복 발급 코드 0).
- [ ] 무음 refresh(access 만료+refresh 유효 → 새 access 쿠키, 재로그인 없음), 다중 탭 멱등(회전X).
- [ ] 로그아웃 → 쿠키 제거 + access blacklist + refresh revoke, 즉시 차단.
- [ ] 미인증 보호 View → **302 `/login`**(API는 401 JSON 유지), 로그인 후 052 CookieRequestCache 복귀.
- [ ] View principal `getName()`=email → `CurrentActorResolver`·14 facade·`sec:authentication` 무회귀.
- [ ] TTL/쿠키 속성 SSOT=`JwtProperties`. blacklist 매 요청 조회.
- [ ] last_login_at 기록 유지(formLogin 이벤트 대체).
- [ ] Modulith verify + 풀 스위트 그린, 전 폼·무음refresh·세션무회귀 E2E, **2-인스턴스 무세션 인증 유지** 실증.

---

## 코드 대조 요약 (메인 보고용)

- **읽은 핵심 파일**: `security/SecurityConfig.java`(3체인 `@Order 0/1/2`, View `:155-228` 개편 대상), `security/JwtAuthenticationFilter.java`(Bearer 헤더만·principal=userId·blacklist 매요청), `security/JwtTokenProvider.java`(access에 email claim 존재·`extractEmail` 부재), `security/RefreshTokenStore.java`+`RedisRefreshTokenStore.java`(**refresh 회전 없음**·blacklist), `security/JwtProperties.java`(TTL SSOT access PT30M/refresh P14D), `member/service/AuthServiceResponse.java`(API 발급 로직 — 공용화 추출 원천, `refresh()` 회전 안 함), `member/service/MemberUserDetailsService.java`·`MemberService.authenticate/getById/recordLoginByEmail`, `member/service/LoginActivityRecorder.java`(formLogin 이벤트 — cutover로 소멸), `web/support/CurrentActorResolver.java`+`CurrentActor.java`(**`auth.getName()`=email 의존 — 최대 회귀점**), `templates/auth/login.html`·`fragments/header.html`·`home/home.html`(폼 action/파라미터 계약).
- **052/053 상태**: 둘 다 **구현 완료**(`web/support/CookieFlashMapManager`·`FlashCookieConfig` 존재, SecurityConfig `CookieCsrfTokenRepository`·`CookieRequestCache` 반영). 본 Phase는 이들의 세션 비의존 동작을 회귀 검증만.
- **최대 리스크(plan-reviewer 주목)**: ① JWT principal=userId vs View `getName()`=email 불일치 → 체인별 principal 빌더로 해결(§1.2). ② 발급 로직 공용화 시 `AuthServiceResponse` 리팩터링 회귀(API 토큰 테스트로 가드). ③ `ViewAuthService` 모듈 배치 → **`member/service` 확정**(member→security는 `AuthServiceResponse` 선례로 허용 방향, web은 package-structure-rule로 배제), Modulith verify는 회귀 가드. ④ last_login_at 이벤트 소멸 누락. ⑤ STATELESS 전환 후 052 CSRF/053 Flash 무회귀(둘 다 쿠키 저장이라 설계상 안전, E2E 실증).

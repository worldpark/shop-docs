# 054. View 인증 JWT 단일화 Phase 3 — JWT 쿠키 인증 cutover + 세션 제거

> 출처: JWT 단일화 phase 분할의 최종 단계. **선행 필수: 052(CSRF·SavedRequest stateless) + 053(Flash 쿠키화) 완료.**
> 본 Phase: View(브라우저) 인증을 formLogin 세션 → **JWT HttpOnly 쿠키 + STATELESS**로 전환하고 **세션을 제거**한다. 052·053이 세션 비인증 의존을 이미 stateless로 옮겨놨으므로, 이 단계에서 세션을 없애도 CSRF·Flash·SavedRequest가 깨지지 않는다.

## 선행 의존 (반드시 052·053 후)
- 052: CSRF가 `CookieCsrfTokenRepository`, SavedRequest가 `CookieRequestCache`로 이미 전환됨(세션 비의존).
- 053: Flash가 쿠키 FlashMapManager로 이미 전환됨(세션 비의존).
- → 이 시점에 세션은 **인증 용도로만** 남아 있으므로, 인증을 쿠키 JWT로 옮기면 세션이 완전히 불필요해진다.

## 범위
1. **View 체인 STATELESS + JWT 쿠키 인증 필터**: `access_token` HttpOnly 쿠키에서 JWT를 읽어 `SecurityContext`를 채우는 필터(기존 `jwtAuthenticationFilter`의 Bearer→쿠키 변형 또는 공용화). `sessionCreationPolicy(STATELESS)`. formLogin·세션 생성 제거.
2. **브라우저 로그인 → 쿠키 발급**: `POST /login` 자격 검증(기존 `userDetailsService`+BCrypt) 성공 시 access+refresh JWT 발급(**기존 `JwtTokenProvider`+`RedisRefreshTokenStore` 재사용 — API `/api/v1/auth/login`과 토큰 발급 로직 공용화, 중복 금지**) → HttpOnly·Secure·SameSite=Lax 쿠키 set → redirect(052의 `CookieRequestCache` 복귀 또는 `/`). formLogin을 커스텀 `AuthenticationSuccessHandler` 또는 전용 로그인 컨트롤러로 교체.
3. **무음 refresh 필터**: access 쿠키 만료 + refresh 쿠키 유효 시 새 access 발급·쿠키 재설정 후 요청 계속(브라우징 중 30분마다 로그아웃 방지).
4. **로그아웃**: `POST /logout` → 쿠키 제거 + access **blacklist** + refresh **revoke**(기존 Redis 폐기 재사용).
5. **미인증 처리**: 보호 View + 토큰 없음/만료/무효 → **302 `/login`**(API처럼 401 JSON 아님).
6. **쿠키 표준**: `access_token`/`refresh_token` — `HttpOnly`·`Secure`·`SameSite=Lax`·`Path=/`. TTL access≈PT30M, refresh≈P14D(JwtProperties SSOT).
7. **세션 제거**: formLogin·세션 생성 정책·잔여 세션 설정 제거. spring-session 미도입. JSESSIONID 미생성.

## 리스크 / 결정
- **[결정] blacklist 매 요청 조회**: 즉시 로그아웃 반영 위해 View 요청마다 access blacklist Redis 조회 → 요청당 Redis 1회(API 체인 현 동작과 일치시킬 것). "stateless"라도 폐기 즉시성 때문에 이 조회는 남음.
- **[리스크] 무음 refresh 동시성**: 여러 탭 동시 만료 → refresh 동시 시도. `RedisRefreshTokenStore` 회전 정책 확인 후 회전 비활성 또는 멱등 처리.
- **[리스크·검증] SameSite=Lax**: top-level GET 리다이렉트·same-site 폼 POST 쿠키 전송 OK. None 회피.

## Non-goals
- API 체인(`/api/v1/**`) 변경(이미 JWT). 052·053이 다룬 CSRF/Flash/SavedRequest 재작업. SPA/모바일/OAuth/remember-me.

## 검증
- **로그인/로그아웃**: 로그인 → `access_token`/`refresh_token` HttpOnly 쿠키 set, **JSESSIONID 미생성(세션 0)** → 보호 페이지 → 로그아웃 시 쿠키 제거 + blacklist/revoke.
- **무음 refresh**: access TTL 경과 후 네비게이션 → 재로그인 없이 유지(새 access 쿠키).
- **미인증**: 보호 View 무토큰 → 302 `/login`, 로그인 후 복귀(052 CookieRequestCache).
- **세션 의존 무회귀**: CSRF 폼 POST(052)·Flash 메시지(053)가 **세션 없이도** 정상(통합 + E2E).
- **멀티 인스턴스 실증(핵심)**: 로컬 2-인스턴스(8080/8081, **세션 스토어 없음**) → 8080 로그인 쿠키로 8081 보호 페이지 인증 유지(JWT self-contained).
- **전체 E2E 회귀**: 모든 폼/네비(로그인·장바구니·주문·결제·판매자/admin 배송·CRUD·account) + 메인 게이트(Modulith verify + 풀 스위트).

## 참고
- `security/SecurityConfig.java`: API 체인 `:96-148`(JWT 재사용 기준), View 체인 `:154-224`(전면 개편 대상).
- `JwtTokenProvider`, `RedisRefreshTokenStore`(refresh/회전·revoke), blacklist, `jwtAuthenticationFilter`(쿠키 변형 기준), `JwtProperties`(TTL SSOT).
- 선행: 052·053. 규칙: api-authorization-rule, error-response-rule(View redirect+flash), architecture-rule, ADR-005.
- 감사 근거: `docs/report/architecture/001-multi-instance-readiness-audit.md` #1.

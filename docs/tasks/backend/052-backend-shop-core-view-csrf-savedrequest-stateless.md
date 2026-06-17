# 052. View 인증 JWT 단일화 Phase 1 — CSRF·SavedRequest stateless화 (세션 의존 사전 제거)

> 출처: 사용자 결정("인증은 JWT만 사용")의 phase 분할. 결합본(JWT 쿠키 전면 전환)을 052·053·054로 분리.
> 전략: 세션은 "반만 제거" 불가 — STATELESS 전환 즉시 CSRF·Flash·SavedRequest가 동시에 깨진다. 따라서 **세션이 살아있는 동안** 세션 비인증 의존을 먼저 stateless로 옮긴 뒤(Phase 1·2, 앱 그린 유지), **Phase 3(054)에서 인증을 JWT 쿠키로 cutover하며 세션 제거**한다.
> 본 Phase: SecurityConfig 레벨의 두 세션 의존 — **CSRF 토큰 저장소**와 **SavedRequest(로그인 후 복귀)** — 를 stateless로 전환. **인증 방식·세션 자체는 무변경**(여전히 formLogin 세션). 054 cutover의 위험을 미리 제거하는 prep.

## 배경
- View 체인(`SecurityConfig:154-224`)은 현재:
  - CSRF: 기본 `HttpSessionCsrfTokenRepository`(세션 저장).
  - SavedRequest: `HttpSessionRequestCache`(`htmlNavigationRequestCache`, `:219-240`, 세션 저장).
- 둘 다 세션에 얹혀 있어, 054에서 세션을 STATELESS로 바꾸면 **모든 폼 POST 403 + 로그인 후 복귀 URL 소실**. 본 Phase에서 미리 stateless 저장소로 옮긴다(세션 유지 상태에서도 정상 동작).

## 범위
1. **CSRF 저장소 stateless 전환**: View 체인 CSRF를 `CookieCsrfTokenRepository`로 교체(`withHttpOnlyFalse()` — Thymeleaf 서버 렌더 `_csrf` 히든 주입 및 필요 시 JS 접근 호환). CSRF 보호 활성 유지. 폼 POST가 쿠키 토큰으로 정상 검증되는지 확인.
2. **SavedRequest stateless 전환**: `HttpSessionRequestCache` → `CookieRequestCache`(Spring Security 제공, 저장 요청을 쿠키 직렬화)로 교체. 기존 "HTML 네비게이션만 저장" 의도(`htmlNavigationRequestCache`의 MediaType 매칭) 유지 — `CookieRequestCache`에 동등한 RequestMatcher 적용 또는 동작 검증. 쿠키 크기 한계(URL만 저장이라 무해) 확인.
3. 인증(formLogin)·세션 생성 정책은 **무변경**. spring-session 미도입.

## Non-goals
- 인증 방식 변경(Phase 3/054 소관), Flash 변경(Phase 2/053), 세션 제거(054).
- API 체인(`/api/v1/**`) 무관.

## 검증
- **CSRF 회귀**: 대표 폼 POST(로그인, 장바구니 담기, 주문, 결제, 판매자 배송 ship/deliver, 상품/카테고리 CRUD)가 **쿠키 CSRF 토큰**으로 정상 통과. 위조/누락 토큰 403.
- **SavedRequest 회귀**: 미인증으로 보호 페이지 접근 → 로그인 → **원래 URL로 복귀**(쿠키 기반). 백그라운드 probe/XHR는 복귀 대상 아님(기존 의도 유지).
- **세션 무변경 확인**: 로그인은 여전히 세션(JSESSIONID) 기반(이 Phase에선 정상).
- 메인: Modulith verify + 풀 스위트 그린 + 관련 E2E(폼 POST·로그인 후 복귀).

## 참고
- `security/SecurityConfig.java:154-240`(View 체인·CSRF·`htmlNavigationRequestCache`).
- Spring Security `CookieCsrfTokenRepository`, `CookieRequestCache`.
- 후속: 053(Flash 쿠키화), 054(인증 JWT 쿠키 cutover — 052·053 선행 필수).
- 감사 근거: `docs/report/architecture/001-multi-instance-readiness-audit.md` #1.

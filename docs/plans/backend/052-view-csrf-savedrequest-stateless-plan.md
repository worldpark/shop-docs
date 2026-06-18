# 052 Plan — View 인증 JWT 단일화 Phase 1: CSRF·SavedRequest stateless화

> Task: `docs/tasks/backend/052-backend-shop-core-view-csrf-savedrequest-stateless.md`
> 전략: 세션은 "반만 제거" 불가 → Phase 3(054) 인증 cutover 전에 세션 비인증 의존을 미리 stateless로 옮긴다. 본 Phase는 **CSRF 토큰 저장소**와 **SavedRequest**를 세션→쿠키로 전환. **인증·세션 자체는 무변경**(여전히 formLogin 세션).

## 0. 코드 대조 (현재 상태)
- `security/SecurityConfig.java` View 체인(@Order 2, `:154-224`):
  - CSRF: **명시 `.csrf()` 설정 없음** → Spring Security 기본(CSRF 활성 + `HttpSessionCsrfTokenRepository`). 주석 `:221` "CSRF 기본 활성 유지, 폼 th:action으로 _csrf 히든 자동 주입".
  - SavedRequest: `.requestCache(rc -> rc.requestCache(htmlNavigationRequestCache()))`(`:219`). `htmlNavigationRequestCache()`(`:234-240`) = `HttpSessionRequestCache` + `MediaTypeRequestMatcher(TEXT_HTML, ignore ALL)`(HTML 네비게이션만 저장 — DevTools probe/XHR 제외).
- API 체인(@Order 1, `:96-148`): `csrf.disable()` + `STATELESS` — **무관/무변경**.
- Thymeleaf 폼은 서버 렌더로 `_csrf` 히든 필드 주입(JS가 쿠키를 읽지 않음).

## 1. CSRF 저장소 세션→쿠키 (§1)
- View 체인에 `.csrf(csrf -> csrf.csrfTokenRepository(CookieCsrfTokenRepository.withHttpOnlyFalse()))` 추가 — 토큰을 세션이 아닌 `XSRF-TOKEN` 쿠키에 저장. CSRF 보호 **활성 유지**.
- **Thymeleaf 호환**: 폼은 서버 렌더 `_csrf` 히든이라 기본 `CsrfTokenRequestAttributeHandler`(Spring Security 6 기본, XOR 마스킹)로 정상 검증된다 — JS가 쿠키를 읽을 필요 없음. `withHttpOnlyFalse()`는 향후 JS 접근(054) 대비 — Phase 1만 보면 HttpOnly 유지도 가능하나, 054 연속성·일관성 위해 `withHttpOnlyFalse()` 채택. 구현자는 모든 폼 POST가 통과하는지 검증.
- deferred token / BREACH(XOR) 동작은 기본 핸들러 유지(별도 핸들러 교체 불필요 — SSR 폼 전용).

## 2. SavedRequest 세션→쿠키 (§2)
- `htmlNavigationRequestCache()`의 `HttpSessionRequestCache` → **`CookieRequestCache`**로 교체(저장 요청 URL을 쿠키 직렬화). 기존 "HTML 네비게이션만 저장" 의도 유지: `CookieRequestCache.setRequestMatcher(htmlMatcher)`로 동일 `MediaTypeRequestMatcher(TEXT_HTML, ignore ALL)` 적용.
- 메서드명/주석은 의미에 맞게(예 `htmlNavigationRequestCache`는 유지하되 내부 구현만 교체).
- 쿠키 크기: URL만 저장이라 4KB 한계 무해.

## 3. 무변경
- formLogin·`sessionCreationPolicy`(세션 생성)·`userDetailsService`는 **그대로**. spring-session 미도입. API 체인 무변경.

## Non-goals
- 인증 방식/세션 제거(054), Flash(053), API 체인.

## 검증
- **CSRF 회귀(핵심·전 폼)**: 로그인(POST /login), 장바구니 담기/수정/삭제, 주문/체크아웃, 결제(`/orders/*/payment`), 취소, 판매자 배송 ship/deliver, admin 배송 ship/deliver, 상품·옵션·variant·이미지 CRUD, 카테고리 CRUD, account, 리뷰, 판매자 신청 — **쿠키 CSRF 토큰으로 정상 통과**. 위조/누락 토큰 → 403.
- **SavedRequest 회귀**: 미인증으로 보호 페이지 접근 → 로그인 → **쿠키 기반으로 원 URL 복귀**. 백그라운드 probe/XHR/favicon은 복귀 대상 아님(기존 의도 유지).
- **세션 무변경 확인**: 로그인은 이 Phase에선 여전히 세션(JSESSIONID). flash 메시지도 정상(아직 세션 — 053에서 전환).
- 메인 게이트: Modulith verify + 풀 스위트 그린.
- E2E: 로그인 후 복귀 + 대표 폼 POST(예 장바구니·판매자 배송) CSRF 통과.

## 리스크
- **[최우선] CSRF 쿠키 전환 후 폼 깨짐**: 서버 렌더 `_csrf` 히든이 쿠키 저장소와 정상 연동되는지 — 전 폼 회귀 필수. Spring Security 6의 XOR 토큰·deferred 로딩 특이점 주의(기본 핸들러로 SSR은 정상이나 E2E로 실증).
- CookieRequestCache는 요청 **URL만** 저장(헤더/바디 미저장) — redirect-after-login엔 충분.
- 본 Phase 변경은 SecurityConfig 한 곳이나 **블라스트 반경이 전 폼**이라 게이트+E2E 비중 높음.

## 오케스트레이션
1. backend-implementor: `SecurityConfig` View 체인 CSRF·requestCache 교체.
2. reviewer → (FAIL 시) fixer → 재리뷰.
3. 메인 게이트: Modulith verify + 풀 스위트.
4. e2e-runner: 로그인 후 복귀 + 대표 폼 CSRF 회귀.

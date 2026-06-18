# 053 Plan — View 인증 JWT 단일화 Phase 2: Flash 메시지 세션→쿠키 stateless화

> Task: `docs/tasks/backend/053-backend-shop-core-view-flash-cookie-stateless.md`
> 전략: 세션은 "반만 제거" 불가 → Phase 3(054) 인증 cutover 전에 세션 비인증 의존을 미리 stateless로 옮긴다. 본 Phase는 **PRG Flash 메시지 저장소**를 세션→쿠키로 전환. **인증·세션 자체는 무변경**(여전히 formLogin 세션). 052(CSRF·SavedRequest)와 독립·병렬, 둘 다 054의 선행.

## 0. 코드 대조 (현재 상태)

- **Flash 사용처 감사**: `web/**/*ViewController.java` **14파일·60곳** `addFlashAttribute`(grep 실측 — task 문서의 "131곳"은 추정치였고 실측은 60곳). 키는 `flashSuccess`/`flashError` 2종뿐, 값은 **전부 짧은 한국어 String** — 리터럴(예 `"리뷰가 작성되었습니다."`) 또는 `e.getMessage()`. **객체·리스트·비문자 flash 없음**(직렬화 대형/타입 리스크 없음). 대표 파일:
  - `web/order/OrderViewController.java:112,129,221,223,255,257`(결제·취소), `web/order/SellerShipViewController.java:76,113`·`web/order/AdminShipViewController.java:65,96`(ship/deliver `flashSuccess`/`flashError`), `web/cart/CartViewController.java:92,125`(담기 `flashError`), `web/product/AdminCategoryViewController.java`·`SellerProductVariantViewController.java`·`SellerProductImageViewController.java`(CRUD), `web/member/AccountViewController.java:145,186`(account), `web/member/SellerApplicationViewController.java:106,109`(판매자 신청), `web/review/ReviewViewController.java:100,142,168`.
- **렌더 경로**: `templates/fragments/messages.html`(`:5-6`) `th:if="${flashSuccess}"`/`${flashError}` — flash 속성이 **다음 요청 모델에 노출**되어야 렌더됨(8개 템플릿이 이 fragment 사용). 즉 "redirect 후 모델 노출 + 1회 소비"가 핵심 계약.
- **현재 저장소**: `flashMapManager`/`FlashMapManager` 빈 **정의 없음**(전 소스 grep 0건) → Spring MVC `WebMvcAutoConfiguration`이 **기본 `SessionFlashMapManager`(세션 저장)** 제공 중. 054에서 STATELESS 전환 시 flash 전부 소실 → 본 Phase에서 쿠키화.
- **Config 위치**: `web` 모듈에 `WebMvcConfigurer`·MVC용 `@Configuration` **없음**(`AdminDashboardSseSchedulingConfig`·`SellerSalesStatsSseSchedulingConfig`는 SSE 스케줄 전용, 무관). `web.support`에는 `CurrentActor*`·`NavActiveControllerAdvice`만 존재. → 신규 빈은 `web` 모듈에 둔다(package-structure-rule: web = "View 진입점 support").
- **052 상태**: `SecurityConfig`(`:225` CSRF `CookieCsrfTokenRepository`, `:241-247` `CookieRequestCache`) 이미 쿠키화 완료. 본 Phase는 **SecurityConfig 무수정**(flash는 MVC 레이어, 보안 체인 밖).

## 1. 설계 방식 · 이유

- **빈 1개 교체로 60호출부 무수정**: Spring MVC `DispatcherServlet`은 컨텍스트에서 **빈 이름 `flashMapManager`(타입 `FlashMapManager`)** 를 자동 탐색해 사용한다(없으면 기본 `SessionFlashMapManager`). 동일 이름·타입 빈을 등록하면 컨트롤러의 `addFlashAttribute`/`RedirectAttributes` 호출부와 `RedirectView`의 flash 처리 코드는 **전혀 건드리지 않고** 저장 매체만 세션→쿠키로 바뀐다.
- **`AbstractFlashMapManager` 상속 채택**: 직접 `FlashMapManager` 구현은 **만료(expiration) 처리·targetRequestPath/params 매칭·소비 후 제거·동시성 mutex**를 전부 재구현해야 한다. Spring의 `AbstractFlashMapManager`는 이 로직(`retrieveAndUpdate`의 매칭/만료/제거)을 모두 제공하고, 하위 클래스는 **저장 입출력 3개 훅만** 구현하면 된다:
  - `retrieveFlashMaps(HttpServletRequest)` — 쿠키 → `List<FlashMap>` 복원
  - `updateFlashMaps(List<FlashMap>, request, response)` — `List<FlashMap>` → 쿠키 set(빈 리스트면 쿠키 만료)
  - `getFlashMapsMutex(request)` — 세션 비의존이므로 `null` 반환(상위가 mutex 없이 동작 허용)
  - → over-spec 없이 검증된 상위 로직 재사용. 신규 클래스 1개 + 등록 빈 1개로 최소 변경.

## 2. 구성 요소

- **신규 `web/support/CookieFlashMapManager.java`** — `extends AbstractFlashMapManager`.
  - 쿠키 이름: `FLASH` (상수). 속성: `Path=/`, **`HttpOnly`**(JS 접근 불필요 — SSR 렌더), **`SameSite=Lax`**(redirect-after-POST의 top-level GET에 쿠키 전송됨), `Secure`는 운영 HTTPS 전제로 set(052 CSRF/세션 쿠키 정책과 일치 — 로컬 http 호환 위해 052와 동일 방식 따름).
  - **SameSite 작성 메커니즘**: `jakarta.servlet.http.Cookie`는 Servlet 6.1 미만에서 SameSite 직접 미지원 → Spring **`org.springframework.http.ResponseCookie`** 빌더로 속성(HttpOnly·SameSite=Lax·Path·maxAge)을 구성하고 `responseCookie.toString()`을 `response.addHeader("Set-Cookie", ...)`로 기록한다(코드베이스에 기존 SameSite 패턴 없음 — 본 클래스가 첫 도입).
  - 직렬화: `List<FlashMap>`을 **JSON 배열**로 직렬화 후 **base64 URL-safe** 인코딩해 쿠키 값에 저장. 각 FlashMap 원소는 `{ attrs: {flashSuccess:"...", flashError:"..."}, path: targetRequestPath, params: targetRequestParams, exp: expirationEpochMillis }`. attrs 값은 String 한정(감사 §0)이라 타입 모호성 없음 — Jackson `ObjectMapper`로 직렬화/역직렬화(키·값 String Map).
  - 복원(`retrieveFlashMaps`): `FLASH` 쿠키 없으면 `null`. 있으면 base64 디코드→JSON 파싱→각 원소를 `FlashMap`으로 복구(`put` attrs, `setTargetRequestPath`, `addTargetRequestParams`, 저장된 exp로 `FlashMap` 만료 상태 재현 — 상위 `AbstractFlashMapManager`가 `isExpired()`로 검사). 파싱 실패 시 `null` 반환(아래 §4).
  - 저장(`updateFlashMaps`): 리스트가 **비면 → 쿠키 `maxAge=0`(즉시 만료)** 로 set해 소비 완료를 브라우저에 반영. 비어있지 않으면 직렬화 쿠키 set(maxAge는 미설정=세션 쿠키 또는 짧은 양수; 1회성이므로 다음 요청 소비로 충분).
- **신규 `web/support/FlashCookieConfig.java`**(또는 기존 web 설정에 통합) — `@Configuration`, `@Bean("flashMapManager") FlashMapManager flashMapManager()` 로 `CookieFlashMapManager` 등록. **빈 이름 정확히 `flashMapManager`** 필수(MVC 탐색 키).
- **무변경**: 컨트롤러 14파일·60곳, `messages.html` fragment, `SecurityConfig`, formLogin·세션 정책.

## 3. 데이터 흐름 (PRG 1사이클)

1. POST 처리 컨트롤러: `redirectAttributes.addFlashAttribute("flashSuccess","...")` → `redirect:/orders` 반환.
2. `RedirectView`가 현재 요청의 output FlashMap에 attrs·targetPath 채우고 `flashMapManager.saveOutputFlashMap` 호출 → **`updateFlashMaps`가 `FLASH` 쿠키에 직렬화 저장**(302 응답에 Set-Cookie).
3. 브라우저가 302 따라 GET `/orders` 요청 시 `FLASH` 쿠키 동봉.
4. `DispatcherServlet`이 `flashMapManager.retrieveAndUpdate` 호출 → **`retrieveFlashMaps`로 쿠키 복원** → 상위가 경로/만료 매칭으로 해당 FlashMap 선택 → **모델에 `flashSuccess` 노출** + **소비된 FlashMap을 리스트에서 제거 후 `updateFlashMaps` 재호출(빈 리스트 → 쿠키 maxAge=0 만료)**.
5. `messages.html`이 `${flashSuccess}` 렌더. **다음 요청엔 쿠키 소멸 → 1회성 보장**.

## 4. 예외 처리 전략

- **쿠키 파싱 실패**(손상·구버전 포맷·base64/JSON 오류): `retrieveFlashMaps(HttpServletRequest)`에서 예외를 삼키고 `null` 반환(=flash 없음). flash는 1회성 부가 알림이라 손실돼도 기능 안전(fail-safe). 손상 쿠키는 다음 정상 PRG의 `updateFlashMaps`(쓰기 경로)에서 덮어써져 정리된다. **주의: `retrieveFlashMaps`는 `HttpServletResponse`를 받지 않으므로 그 안에서 Set-Cookie 작성은 불가** — 좀비 쿠키 즉시 정리가 필요하면 반드시 `response`를 가진 `updateFlashMaps` 경로에서 처리한다(load-bearing fail-safe는 "예외 삼키고 null"). 로깅은 `debug` 수준(스팸 방지).
- **쿠키 크기 초과**(이론상 4KB): 감사상 값이 짧은 단문 1개라 비현실적이나, 직렬화 길이가 한계 근접 시 **저장 생략(flash drop)** 후 debug 로그 — 깨진 응답 헤더보다 메시지 1회 누락이 안전. (forbidden-rule: 조용한 데이터 유실 금지 대상 아님 — flash는 비영속 UI 힌트).
- **비-String attr 방어**: 직렬화 시 값이 String이 아니면 `String.valueOf`로 강제(현재 전부 String이라 무발동, 미래 회귀 방어).

## 5. 검증 방법

- **메인 게이트(필수)**: `./gradlew modulith:check`(Modulith verify — `web` 모듈에 빈 추가가 모듈 경계 위반 없는지) + **풀 스위트 그린**(testing-rule). `web.support` 신규 클래스는 web 모듈 내부라 경계 무영향.
- **단위 테스트**(`CookieFlashMapManagerTest`): 직렬화↔역직렬화 라운드트립, 빈 리스트→maxAge=0, 손상 쿠키→null(예외 미전파), targetRequestPath/만료 매칭 1건.
- **빈 배선 회귀 가드**(권장): `@SpringBootTest`에서 `flashMapManager` 빈이 실제 `CookieFlashMapManager` 타입으로 주입되어 기본 `SessionFlashMapManager`를 대체했는지 단언 — 빈 이름 오타로 인한 미대체(조용한 회귀)를 잡는다.
- **Flash 회귀 E2E(핵심)**: 대표 PRG 흐름에서 **redirect 후 메시지 표시 + 다음 요청 소멸(1회성)**:
  - 장바구니 담기(`flashError` 경로), 주문/결제(`flashSuccess`/`flashError`), 취소, 판매자 배송 ship/deliver, admin 배송 ship/deliver, 상품·variant·이미지·카테고리 CRUD, account 수정, 판매자 신청. 각 케이스: ① redirect 직후 fragment에 메시지 보임 ② **바로 다음 GET(새로고침)에 메시지 사라짐**(중복·잔존 없음) ③ `FLASH` 쿠키가 소비 후 만료됨.
- **세션 무변경 확인**: 이 Phase에선 로그인 JSESSIONID·formLogin 정상(052 CSRF·SavedRequest도 무회귀).

## 6. 트레이드오프

- **AbstractFlashMapManager 상속 vs 직접 구현**: 상속 채택 — 만료/매칭/소비 로직 재사용으로 코드·버그 표면 최소. 직접 구현은 over-engineering(plan-reviewer FAIL 리스크).
- **HttpOnly 유지**: 052 CSRF 쿠키는 `withHttpOnlyFalse()`(JS 대비)였으나 flash는 **서버 렌더 전용**이라 JS 접근 불요 → HttpOnly 유지가 더 안전(XSS 노출 면적 축소). 054와의 일관성 위해 SameSite=Lax는 동일.
- **쿠키 4KB 한계**: 현재 단문 1개라 무해. 만약 미래에 대형/리스트 flash를 넣으면 한계 위험 — §4 drop 가드 + plan에 "flash는 짧은 메시지 String 한정" 제약 명시로 회귀 방어.
- **base64(JSON) 오버헤드**: 단문 1개 기준 수십 바이트 → 무시 가능. 가독성보다 안전한 쿠키 인코딩 우선.
- **다중 동시 PRG**: 한 응답이 여러 output flash를 만드는 케이스는 현 코드에 없음(컨트롤러당 단일 redirect). 상위 로직이 `List<FlashMap>`을 지원하므로 발생해도 정상.

## Non-goals

- 인증/세션 제거(054), CSRF/SavedRequest(052 — 이미 완료), 컨트롤러 flash 호출부 수정(중앙 1빈 교체로 회피), flash 값 구조 변경.

## 오케스트레이션

1. **backend-implementor**: `web/support/CookieFlashMapManager.java`(AbstractFlashMapManager 상속) + `web/support/FlashCookieConfig.java`(`flashMapManager` 빈 등록) 신규. `CookieFlashMapManagerTest` 단위. SecurityConfig·컨트롤러·템플릿 무수정.
2. **reviewer** → (FAIL 시) **fixer** → 재리뷰(빈 이름 `flashMapManager` 정확성, HttpOnly/SameSite, 1회성 만료, 파싱 fail-safe, 모듈 경계 중점).
3. **메인 게이트**: Modulith verify + 풀 스위트 그린.
4. **e2e-runner**: 대표 PRG 흐름(장바구니 담기·주문/결제·취소·판매자/admin ship·deliver·상품/variant/이미지/카테고리 CRUD·account·판매자 신청)에서 redirect 후 메시지 표시 + **1회성 소멸** + 세션 무회귀 검증.

## 완료 조건

- [ ] `flashMapManager` 빈이 `CookieFlashMapManager`(AbstractFlashMapManager 상속)로 등록되어 기본 `SessionFlashMapManager` 대체.
- [ ] 컨트롤러 14파일·60곳 `addFlashAttribute` **무수정**, `messages.html` 무수정으로 flash 정상 렌더.
- [ ] flash 쿠키 `HttpOnly`·`SameSite=Lax`·`Path=/`, 소비 직후 `maxAge=0` 만료(1회성).
- [ ] 손상 쿠키 fail-safe(예외 미전파, flash drop).
- [ ] Modulith verify + 풀 스위트 그린, 대표 PRG E2E(표시+1회성) 통과, 세션 무회귀.

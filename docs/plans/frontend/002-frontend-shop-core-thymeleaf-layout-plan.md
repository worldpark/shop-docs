# 002. shop-core Thymeleaf 레이아웃/프래그먼트 — Plan

> 범위: shop-core SSR(Thymeleaf) 공통 레이아웃 + 프래그먼트(header/footer/nav/messages) + 정적 리소스 기본 구조 + 샘플 페이지 + 템플릿 렌더링 테스트.
> 범위 밖(후속 Task): member/product/cart/order 등 도메인 화면, 디자인 시스템·CSS 프레임워크(Bootstrap/Tailwind), JS 번들러/빌드 파이프라인, ObjectStorage 기반 상품 이미지(별도 Task), i18n 메시지 번들 본격 도입.
> 과도 설계 금지 원칙을 전 섹션에 적용한다.

---

## 구현 목표
이후 도메인 화면이 반복 없이 콘텐츠 슬롯만 채워 확장되도록, shop-core에 공통 Thymeleaf 레이아웃·프래그먼트(header/footer/nav/messages)와 정적 리소스 기본 구조를 도입하고, 기존 login/home/error 템플릿을 레이아웃 기반으로 통합하며, 프래그먼트 포함을 검증하는 렌더링 테스트를 제공한다.

---

## 사전 확정 사실 (재조사로 확인됨)
- 기존 템플릿 3종(auth/login.html, home/home.html, error/error.html)은 모두 단독 완결형이며 인라인 style 이 중복된다.
- build.gradle: spring-boot-starter-thymeleaf, thymeleaf-extras-springsecurity6 보유. thymeleaf-layout-dialect 미보유.
- SecurityConfig: 공개 경로 = GET /login, /css/**, /js/**, /images/**, /favicon.ico, /error. 그 외 인증 필요. 정적 자산을 static/css|js|images 에 두면 permitAll 서빙됨.
- 컨트롤러: LoginViewController GET /login -> auth/login(모델 무전달). HomeViewController GET / -> home/home(모델 무전달, 보호 경로). ViewExceptionHandler -> error/error + 모델 키 status(int)/message(String).
- 테스트 프로파일(src/test/resources/application.yml): DataSource/JPA/Kafka/Modulith 자동설정 제외, spring.thymeleaf.check-template-location:false. 실 DB 없이 기동, 본 Task 렌더링 테스트도 동일 프로파일에서 동작.
- 기존 테스트가 단언하는 계약(회귀 금지 대상): 뷰 이름 auth/login, error/error, 폼 action @{/login}/@{/logout}, 필드명 username/password, param.error/param.logout 분기, 모델 키 status/message, CSRF 활성(th:action 자동 _csrf 주입).

---

## 레이아웃 방식 결정 (핵심 쟁점 1)
결정: 네이티브 Thymeleaf 3.1 프래그먼트 방식 채택. thymeleaf-layout-dialect 의존성 추가하지 않음.

| 항목 | 네이티브 프래그먼트 (채택) | layout-dialect |
|---|---|---|
| 의존성 | 0 (보유 starter로 충족) | +1 (nz.net.ultraq) |
| 방식 | layout/base.html 에 th:fragment 로 layout(title, content) 정의 후 페이지가 th:replace 로 슬롯 주입 | html 태그에 layout:decorate + layout:fragment 슬롯 |
| 가독성 | 충분(슬롯 2개) | 더 직관적 |
| 확장성 | content 슬롯만 채우면 도메인 화면 무한 확장. 본 범위에 충분 | 동일 |
| 위험 | 슬롯 누락 시 빈 영역(테스트로 방어) | 추가 의존성·Spring Boot 3.5 BOM 비관리 가능성·학습 비용 |

근거: 필요한 슬롯이 title/content 2개뿐이라 layout-dialect의 이점이 본 범위에서 과잉이다. 과도 설계 금지 및 의존성 0 원칙에 따라 네이티브 방식을 택한다. layout-dialect 채택 시 build.gradle 수정이 영향 범위에 포함되나, 채택안은 build.gradle 미수정.

---

## 영향 범위

### 신규 파일

| 파일 | 담당 | 비고 |
|---|---|---|
| shop-core/src/main/resources/templates/layout/base.html | view | 공통 레이아웃. layout(title, content) fragment. head 공통 메타/CSS 링크/title 슬롯 + body 에 header,nav,messages,main(content),footer 조립 |
| shop-core/src/main/resources/templates/layout/blank.html | view | 로그인/에러용 경량 레이아웃. blank(title, content) fragment. head 공통 + footer 만, header/nav 없음 |
| shop-core/src/main/resources/templates/fragments/header.html | view | header fragment. 사이트명/로고 + 인증 상태별 메뉴(sec:authorize) |
| shop-core/src/main/resources/templates/fragments/nav.html | view | nav(active) fragment. 주요 메뉴 링크(@{/} 등). active 파라미터로 현재 메뉴 강조(미전달 시 강조 없음) |
| shop-core/src/main/resources/templates/fragments/footer.html | view | footer fragment. 저작권/고정 문구. 렌더링 테스트 마커 텍스트 포함 |
| shop-core/src/main/resources/templates/fragments/messages.html | view | messages fragment. 플래시 메시지 영역(flashSuccess/flashError th:if 분기) |
| shop-core/src/main/resources/static/css/app.css | view | 공통 스타일. 기존 3개 템플릿의 중복 인라인 스타일을 이전·통합 |
| shop-core/src/main/resources/static/js/app.js | view | 최소 골격(빈 IIFE 1개). 번들러/프레임워크 없음 |
| shop-core/src/main/resources/static/images/.gitkeep | view | 디렉터리 placeholder(SecurityConfig /images/** permitAll 과 정합) |
| shop-core/src/test/java/com/shop/shop/view/LayoutRenderingTest.java | backend | MockMvc 실제 렌더링 -> 프래그먼트 포함 검증(신규, 기존 테스트 미수정) |

> 샘플 페이지 결정: 신규 페이지를 만들지 않고 home/home.html 을 공통 레이아웃(layout/base.html) 기반으로 리팩터링해 샘플 겸용으로 사용한다. 근거: GET /(보호) 라우트와 HomeViewController 가 이미 존재하므로 새 컨트롤러/라우트가 불필요(과도 설계 회피). Acceptance(샘플 페이지가 공통 레이아웃 사용)는 home 이 충족.

### 수정 파일

| 파일 | 담당 | 변경 내용 | 보존 계약 |
|---|---|---|---|
| shop-core/src/main/resources/templates/auth/login.html | view | layout/blank.html 기반 리팩터링. 인라인 style 제거 -> app.css. 로그인 폼만 content 슬롯에 | 폼 @{/login} POST, name=username/name=password, param.error/param.logout 분기, 뷰 이름 auth/login |
| shop-core/src/main/resources/templates/home/home.html | view | layout/base.html 기반 리팩터링(header/nav/footer 적용). 인라인 style 제거. sec:authentication name 및 로그아웃 폼 유지 | @{/logout} POST, sec:authentication name, 뷰 이름 home/home |
| shop-core/src/main/resources/templates/error/error.html | view | layout/blank.html 기반 리팩터링(권장). 인라인 style 제거 | 모델 키 status/message 바인딩, 뷰 이름 error/error |

> 미수정: build.gradle(의존성 0 추가), SecurityConfig, 컨트롤러 3종, ViewExceptionHandler, 기존 테스트(SecurityConfigTest/ViewExceptionHandlerTest/AdviceSeparationTest), 테스트 application.yml. 컨트롤러는 뷰 이름만 반환하므로 변경 불필요.

---

## 1. 설계 방식 및 이유

### 1.1 두 개의 레이아웃 — base(풀) / blank(경량)
- layout/base.html: header + nav + messages + main(content) + footer 조립. 인증 후 일반 화면(home 및 후속 도메인 화면)의 표준 골격.
- layout/blank.html: head 공통 + footer 만(header/nav 없음). 로그인·에러처럼 네비게이션이 의미 없는 미니멀 화면용. 공통 head/CSS/footer 를 재사용해 일관성을 유지하면서 로그인 화면에 불필요한 네비를 강요하지 않는다.
- 두 레이아웃 모두 head 공통 블록(charset/viewport/CSS 링크 @{/css/app.css}/title 슬롯)을 동일 규약으로 가진다.

근거: 로그인/에러에 header·nav 를 붙이면 비인증 상태에서 메뉴가 어색하고, 로그인 화면은 중앙 정렬 카드 UI 가 자연스럽다. 경량 레이아웃을 별도로 두되 공통 head/footer/CSS 는 공유하여 Acceptance(공통 레이아웃 또는 공통 프래그먼트 사용)를 충족하면서 과도 통합을 피한다.

### 1.2 프래그먼트 명명·파라미터 규칙
- header fragment(무파라미터). 인증 메뉴 분기는 sec:authorize isAuthenticated/isAnonymous 로 최소한만(로그인/로그아웃 링크 노출 제어). RBAC·권한별 메뉴는 범위 밖.
- nav(active) fragment — 현재 활성 메뉴 키(문자열) 1개만 파라미터로 받아 th:classappend 로 강조. 미전달 허용(기본 강조 없음). 메뉴 항목은 현재 존재하는 @{/}(홈) 중심 최소 구성, 후속 도메인 링크는 화면 추가 시 확장.
- footer fragment(무파라미터). 고정 문구 + 렌더링 테스트용 안정 마커 텍스트 포함.
- messages fragment(무파라미터). 모델의 플래시 키를 직접 참조.
- 파라미터는 위 최소 집합으로 고정(과도한 파라미터화 금지).

### 1.3 정적 CSS 통합
- 기존 3개 템플릿의 중복 인라인 스타일(box-sizing/body/카드/alert/button 등)을 static/css/app.css 단일 파일로 이전. 페이지별 차이는 클래스(login-container/home-container/error-container)로 구분해 한 파일에 수용.
- 자체 최소 CSS 만. CSS 프레임워크 도입 금지.

### 1.4 확장성 (member/product/cart/order 화면이 얹히는 방식)
후속 도메인 화면은 새 템플릿 파일에서 최상단 th:replace 로 layout/base 의 layout(title, content) 한 줄과 title/main 본문만 작성하면 header/nav/messages/footer/CSS 가 자동 조립된다. 즉 도메인 화면은 content 슬롯만 채우며 공통 골격을 반복 작성하지 않는다. nav 에 도메인 메뉴 링크를 추가하고 nav(active)에 활성 키를 넘기는 것 외 레이아웃 변경 불필요.

---

## 2. 구성 요소 (요약)
- 레이아웃: layout/base.html(풀), layout/blank.html(경량) — view
- 프래그먼트: fragments/header.html, fragments/nav.html, fragments/footer.html, fragments/messages.html — view
- 정적: static/css/app.css, static/js/app.js, static/images/.gitkeep — view
- 샘플: home/home.html(base 적용, 샘플 겸용) — view (신규 페이지 없음)
- 리팩터링: auth/login.html(blank), home/home.html(base), error/error.html(blank) — view
- 테스트: view/LayoutRenderingTest.java — backend

---

## 3. 데이터 흐름
1. ViewController(HomeViewController GET / -> home/home, LoginViewController GET /login -> auth/login)가 뷰 이름 반환(모델 무전달 유지). ViewExceptionHandler -> error/error + status/message.
2. 페이지 템플릿 최상단 th:replace 로 레이아웃 프래그먼트를 호출하며 ::title/::main(content 영역)을 슬롯으로 주입.
3. 레이아웃이 body 조립 순서대로 fragments/header header -> fragments/nav nav(active) -> fragments/messages messages -> content -> fragments/footer footer 를 th:replace 로 포함.
4. 정적 리소스 링크는 th:href @{/css/app.css}, th:src @{/js/app.js}, 이미지 @{/images/...} — base URL 하드코딩 없이 컨텍스트 상대 URL 표현식으로만 합성. SecurityConfig permitAll 경로와 정합.
5. 플래시 메시지 흐름: (후속 화면에서) 리다이렉트 시 RedirectAttributes.addFlashAttribute 로 flashSuccess/flashError String 메시지를 담으면 fragments/messages.html 이 th:if 로 표시. 모델 키 규약: flashSuccess, flashError(둘 다 String). 본 Task 는 영역과 키 규약만 확립(실제 플래시 발생 화면은 후속). Entity/ServiceResponse 미사용 — 원시 String 만.
6. 인증 컨텍스트: header 는 sec:authorize 로, home 은 기존 sec:authentication name 으로 표시. CSRF 는 폼 th:action 자동 _csrf 주입 유지(login @{/login}, home @{/logout}).

### 로그인 메시지 vs 플래시 메시지 관계
로그인 화면은 기존대로 param.error/param.logout 기반 메시지를 login.html 자체에 유지한다(Spring Security 리다이렉트 쿼리 파라미터 흐름). 일반 페이지는 fragments/messages.html 의 flash 키를 사용한다. 두 메커니즘을 억지로 통합하지 않는다(과도 설계 회피).

---

## 4. 예외 처리 전략 (화면 구조 관점)
- 본 Task 는 비즈니스 예외가 아닌 화면 구조/렌더링 중심이다. REST 공통 에러 포맷·BusinessException 흐름과 섞지 않는다.
- 프래그먼트 누락/슬롯 미주입 위험: th:replace 경로·프래그먼트명 오타 시 렌더 예외 또는 빈 영역 발생 -> 렌더링 테스트가 프래그먼트 마커 텍스트 존재로 방어.
- error/error.html 을 layout/blank.html 로 통합하더라도 ViewExceptionHandler 의 모델 키(status/message)와 뷰 이름(error/error)을 그대로 사용한다. 핸들러 코드는 수정하지 않는다. 통합이 렌더 위험을 키운다고 판단되면 error.html 은 인라인 유지 가능(트레이드오프 6 참조). 단 CSS 중복 제거 일관성상 통합 권장.
- error 페이지는 레이아웃을 쓰더라도 무한 루프 위험이 없다(프래그먼트 정적 포함, 추가 컨트롤러 호출 없음).

---

## 5. 검증 방법

### 5.1 신규 렌더링 테스트 (view/LayoutRenderingTest.java, backend)
- 형태: @SpringBootTest + @AutoConfigureMockMvc + @ActiveProfiles("test") (기존과 동일, 실 DB 없이 기동). spring-security-test 사용.
- 보호 페이지(/)는 @WithMockUser 로 인증 컨텍스트 부여 후 GET.
- 검증 항목:
  - (T1) GET /login(인증 불필요) -> 200, 본문에 공통 프래그먼트 마커(footer 텍스트) + 기존 로그인 요소(name=username, _csrf 히든) 포함.
  - (T2) GET /(@WithMockUser) -> 200, 본문에 header/nav/footer 프래그먼트 마커 포함 + 레이아웃 적용 확인(공통 head/CSS 링크 /css/app.css).
  - (T3) include/fragment 일관성: 공통 footer 마커 텍스트가 login·home 양쪽 응답에 동일 등장.
- 마커 텍스트(footer/nav/header 식별 문자열)는 인터페이스 계약으로 plan 에 고정(아래 7장 표) — view 가 만든 텍스트와 backend 테스트 단언이 일치해야 함.

### 5.2 기존 테스트 회귀 없음 확인
- SecurityConfigTest (b)는 뷰 이름 auth/login 까지만 단언(본문 미검증) -> 리팩터링 후에도 뷰 이름 유지로 통과.
- ViewExceptionHandlerTest/AdviceSeparationTest 는 뷰 이름 error/error + 모델 키 단언(본문 미검증) -> 유지로 통과.
- 보존 계약(뷰 이름·폼 action·필드명 username/password·param.error/logout·모델 키 status/message·CSRF 자동 주입)을 리팩터링에서 깨지 않는다.

### 5.3 실행
- ./gradlew test (워크스페이스 루트에서 shop-core 진입 후 실행). 실 DB 없이 통과해야 한다.

### Acceptance Criteria 대 검증 매핑
| Acceptance | 검증 |
|---|---|
| 로그인 페이지가 공통 레이아웃/프래그먼트 사용 | login.html 이 layout/blank 사용 + 공통 footer 프래그먼트 포함(T1) |
| 샘플 페이지가 공통 레이아웃 사용 | home.html 이 layout/base 사용(T2). home 을 샘플로 채택 |
| 헤더/푸터/네비게이션 프래그먼트 정상 렌더링 | T2 가 header/nav/footer 마커 단언 |
| 템플릿 include/fragment 구조 일관 | 모든 페이지가 layout th:replace 단일 규약 + footer 마커 양쪽 등장(T3) |
| 관련 테스트 통과 | ./gradlew test 그린(기존 + 신규) |

---

## 6. 트레이드오프
1. 레이아웃 방식: 네이티브 프래그먼트(의존성 0, 슬롯 2개로 충분) vs layout-dialect(직관적이나 +1 의존성·BOM 호환 위험). -> 네이티브 채택. 슬롯이 늘어 가독성이 떨어지면 후속 Task 에서 재검토 가능.
2. 로그인 전용 경량 레이아웃: blank.html 분리(로그인 UX 자연스러움, 일관성은 head/footer/CSS 공유로 확보) vs base.html 단일(파일 1개 감소, 그러나 로그인에 어색한 nav 강요). -> 분리 채택. 공통 head/footer 는 프래그먼트 공유로 중복 최소화.
3. 샘플 페이지: home 재사용(컨트롤러/라우트 추가 0, 과도 설계 회피) vs 신규 샘플 페이지(별도 컨트롤러 필요). -> home 재사용. 별도 라우트 만들지 않음.
4. error.html 레이아웃 통합: 통합(CSS 중복 제거 일관성) vs 인라인 유지(렌더 경로 단순·안전). -> 통합 권장하되, 리뷰에서 렌더 위험이 제기되면 인라인 유지로 후퇴 가능(모델 키만 보존하면 무관).
5. 정적 CSS 분리 수준: 단일 app.css(현 범위에 충분) vs 페이지별 CSS 분리(과잉). -> 단일 파일. 후속에 커지면 분리.
6. sec:authorize 도입 범위: 헤더 로그인/로그아웃 링크 노출 분기까지만 vs 권한별 메뉴(RBAC). -> 최소(isAuthenticated/isAnonymous)만. RBAC 범위 밖.
7. 테스트 본문 검증 깊이: 프래그먼트 마커 문자열 + 핵심 요소(username/_csrf/css 링크) 단언 vs DOM 정밀 파싱. -> 마커 + 핵심 요소(과도한 결합 회피, 마커 텍스트 변경 시 깨질 수 있음을 계약으로 관리).

---

## 7. backend / view 분담 및 호출 순서 (인터페이스 계약)

### 호출 순서 (결정)
home 을 샘플로 재사용하므로 새 ViewController 가 불필요하다. 따라서:
1. [view] 레이아웃(base/blank) + 프래그먼트(header/nav/footer/messages) + 정적(app.css/app.js/images) 작성, login/home/error 리팩터링.
2. [backend] view/LayoutRenderingTest.java 작성/실행 (템플릿 산출물에 의존하므로 view 완료 후).

> CLAUDE.md 기본 백엔드->화면 순은 Service/DTO 선정의가 필요할 때의 규칙이다. 본 Task 는 Service/DTO·신규 라우트가 없고 렌더링 테스트가 템플릿 산출물에 의존하므로 view 먼저, backend(테스트) 나중이 타당하다.

### 인터페이스 계약 표 (양 에이전트 정합 기준)
| 항목 | 값 | 비고 |
|---|---|---|
| 풀 레이아웃 fragment | layout/base :: layout(title, content) | header/nav/messages/main/footer 조립 |
| 경량 레이아웃 fragment | layout/blank :: blank(title, content) | head + footer 만 |
| header fragment | fragments/header :: header | sec:authorize 메뉴 분기 |
| nav fragment | fragments/nav :: nav(active) | active 문자열 1개(선택) |
| footer fragment | fragments/footer :: footer | footer 마커 텍스트 포함(테스트 단언 대상) |
| messages fragment | fragments/messages :: messages | flash 키 참조 |
| 플래시 모델 키 | flashSuccess(String), flashError(String) | Entity/ServiceResponse 금지 |
| 정적 링크 | @{/css/app.css}, @{/js/app.js}, @{/images/**} | base URL 하드코딩 금지 |
| 보존 뷰 이름 | auth/login, home/home, error/error | 컨트롤러/핸들러 미수정 |
| 보존 폼/필드 | @{/login}/@{/logout} POST, username/password, param.error/param.logout | CSRF 자동 주입 |
| 보존 모델 키 | status(int), message(String) | error 페이지 |
| 테스트 마커(계약) | footer 식별 문자열 / nav·header 식별 문자열 | view 가 정한 텍스트를 backend 테스트가 그대로 단언 — 메인 에이전트가 두 산출물 간 텍스트 일치 정합 |

> 메인 에이전트 정합 책임: view 완료 후 footer/header/nav 마커 텍스트의 실제 문자열을 backend 테스트 단언과 일치시킨다(불일치 시 T1~T3 실패).

---

## 제약 반영 명시
- base URL 하드코딩 금지: 모든 링크를 @{...} 컨텍스트 상대 URL 로만 합성(3장 4번, 7장). 절대 URL/호스트 미사용. 본 Task 는 앱 정적 자산이며 ObjectStorage/storage key 대상이 아님(혼동 방지로 명시).
- Entity 모델 직접 전달 금지: 모델에는 플래시 String 키(flashSuccess/flashError)·기존 원시 키(status/message)만. Entity 미전달(home/login 은 모델 무전달 유지).
- ServiceResponse 미사용: View 렌더링에 ServiceResponse 를 쓰지 않는다. 본 Task 는 Service 자체가 없다.

---

## 완료 조건 체크리스트
- [ ] layout/base.html(layout(title,content)) 작성 — header/nav/messages/main/footer 조립
- [ ] layout/blank.html(blank(title,content)) 작성 — head + footer
- [ ] fragments/header.html, nav.html, footer.html, messages.html 작성(명명·파라미터 1.2 준수)
- [ ] static/css/app.css 로 기존 3개 인라인 스타일 통합, static/js/app.js 최소 골격, static/images/.gitkeep
- [ ] home/home.html -> layout/base 적용(샘플 겸용), sec:authentication/로그아웃 폼 유지
- [ ] auth/login.html -> layout/blank 적용, 폼/필드/param 분기 유지
- [ ] error/error.html -> layout/blank 적용(권장), 모델 키 status/message 유지
- [ ] 모든 정적/이미지 링크 @{...} 표현식, base URL 하드코딩 없음
- [ ] view/LayoutRenderingTest.java 작성(T1/T2/T3)
- [ ] footer/header/nav 마커 텍스트가 view 산출물 대 backend 테스트 단언과 일치
- [ ] ./gradlew test 통과(신규 + 기존 회귀 없음: 뷰 이름·폼·필드·param·모델 키 보존)
- [ ] build.gradle·SecurityConfig·컨트롤러·ViewExceptionHandler·기존 테스트 미수정 확인

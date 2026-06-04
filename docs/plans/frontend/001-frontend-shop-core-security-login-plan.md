# 001. shop-core Spring Security + 로그인 화면 — Plan

> 범위: shop-core SSR(Thymeleaf) 화면을 위한 기본 인증/인가 경계 + 폼 로그인 흐름 + 테스트.
> 범위 밖(후속 Task): 회원 도메인/회원가입, Role 세분화(RBAC), REST 인증(JWT/세션 API), Remember-me, 비밀번호 재설정, OAuth2.
> 과도 설계 금지 원칙을 전 섹션에 적용한다.

---

## 구현 목표
shop-core에 첫 SecurityConfig를 도입해 공개/보호 경로 정책과 폼 로그인·로그아웃·CSRF 흐름을 확립하고, Thymeleaf 로그인 화면과 인증 성공/실패/로그아웃 통합 테스트를 제공한다.

---

## 영향 범위

### 신규 파일

| 파일 | 담당 | 비고 |
|---|---|---|
| shop-core/src/main/java/com/shop/shop/security/SecurityConfig.java | backend | SecurityFilterChain + PasswordEncoder + InMemoryUserDetailsManager 빈 |
| shop-core/src/main/java/com/shop/shop/security/SecurityUserProperties.java | backend | 개발용 로그인 자격증명 설정 바인딩(shop.security.user.*) |
| shop-core/src/main/java/com/shop/shop/auth/controller/LoginViewController.java | backend | GET /login 에서 auth/login 뷰 반환(로직 없음) |
| shop-core/src/main/java/com/shop/shop/home/controller/HomeViewController.java | backend | GET / 에서 home/home 뷰 반환(보호 경로 검증용 최소 컨트롤러) |
| shop-core/src/main/resources/templates/auth/login.html | view | 로그인 폼(th:action 으로 /login, error/logout 메시지 분기) |
| shop-core/src/main/resources/templates/home/home.html | view | 인증 후 홈(로그아웃 폼 포함) |
| shop-core/src/test/java/com/shop/shop/security/SecurityConfigTest.java | backend | (a)~(e) 시나리오 통합/슬라이스 테스트 |

### 수정 파일
- 없음(코드 수정 0). build.gradle 의존성, application.yml 모두 보유. 단 main application.yml에 개발용 자격증명 기본값 블록(shop.security.user)을 선택적으로 추가할 수 있음(트레이드오프 섹션 참고, 기본값을 코드 상수로 둘 경우 미수정).
- 기존 RestExceptionHandler / ViewExceptionHandler / error/error.html: 수정 없음. 충돌 점검만 수행(섹션 4, 6).

> 패키지 결정: 보안은 특정 도메인 모듈에 속하지 않는 전역 관심사이므로 com.shop.shop.security에 둔다(common.config도 후보였으나, 향후 UserDetailsService 교체와 보안 전용 빈 증가를 고려해 전용 패키지가 응집도가 높다). 로그인 화면은 인증 기능 묶음이므로 com.shop.shop.auth.controller({module}/controller 규칙 준수). 홈은 com.shop.shop.home.controller.

---

## 1. 설계 방식 및 이유

### 1.1 인증 소스 — 개발용 InMemoryUserDetailsManager
- 회원(member) 도메인이 아직 없고 이 Task 범위도 아니다. DB 조회용 UserDetailsService를 구현할 저장소가 존재하지 않는다.
- 따라서 baseline 인증 소스는 InMemoryUserDetailsManager + BCryptPasswordEncoder로 둔다(고정 사용자 1명).
- 자격증명은 SecurityUserProperties(shop.security.user.username / shop.security.user.password)로 외부화하되, 미설정 시 개발용 기본값(user / dev1234)을 코드 상수로 폴백한다. raw 비밀번호는 빈 생성 시 passwordEncoder.encode(...)로 인코딩한다(평문 저장 금지).
- 후속 전환 방향(명시만): 회원 도메인 Task에서 UserDetailsService 구현체(DB 조회)를 빈으로 등록하면 in-memory 빈을 대체한다. SecurityConfig는 UserDetailsService/PasswordEncoder 인터페이스에만 의존하도록 작성해 교체 비용을 최소화한다. 이 Task에서 회원 테이블/엔티티를 만들지 않는다.

### 1.2 단일 SecurityFilterChain + 경로별 정책
- 현재 REST 엔드포인트가 0개다. 체인을 둘로 쪼개는(securityMatcher 분리) 것은 현 시점에 과도 설계다.
- 단일 SecurityFilterChain으로 가되, REST/View 정책 방향은 명확히 못 박는다.
  - /api/v1/** : 인증 진입점을 HTTP 401(JSON 흐름에 적합)로 응답. authorizeHttpRequests에서 인증 요구 + exceptionHandling().defaultAuthenticationEntryPointFor(HttpStatusEntryPoint(401), 매처 /api/v1/**)로 해당 경로만 401을 내고, 그 외(View)는 폼 로그인 리다이렉트(302 to /login)를 기본 진입점으로 사용한다.
  - 근거: REST 예외 응답과 View 예외 처리를 섞지 않는다 제약. View는 redirect, REST는 401로 분리. REST 엔드포인트가 실제 추가되는 시점에 securityMatcher 기반 체인 분리로 리팩터링할 수 있다(후속 여지).

### 1.3 공개 vs 보호 경로
- 공개(permitAll): GET /login, 정적 자산(/css/**, /js/**, /images/**, /favicon.ico), 에러 디스패치(/error).
- 보호(authenticated): 그 외 모든 View 경로(/ 포함).
- POST /login, POST /logout은 Spring Security 필터가 처리하므로 별도 컨트롤러 매핑을 만들지 않는다.

### 1.4 CSRF 활성 유지
- Spring Security 기본 CSRF를 끄지 않는다. 폼 흐름에서 필수.
- Thymeleaf 폼이 th:action을 사용하면 _csrf 히든 필드가 자동 주입된다. login/home 폼은 반드시 th:action을 쓴다.

### 1.5 보호 경로 검증용 최소 홈 컨트롤러 신설
- 비인증 to 보호 경로 to /login redirect 검증에는 보호되는 실제 View 경로가 하나 필요하다.
- 테스트 전용 더미 대신 실제 홈 컨트롤러(GET /)를 둔다(어차피 첫 화면이 필요하고, 로그아웃 후 착지/로그인 성공 기본 착지 지점으로도 재사용). 최소 1개만 만들고 그 이상 화면은 만들지 않는다.

---

## 2. 구성 요소 (생성/수정 클래스, 파일)

### [backend-implementor] com.shop.shop.security.SecurityConfig
- 역할: 전역 보안 설정. SecurityFilterChain, 인증 소스, 인코더 빈 정의.
- 어노테이션: @Configuration, @EnableWebSecurity, @EnableConfigurationProperties(SecurityUserProperties.class).
- 빈:
  - SecurityFilterChain filterChain(HttpSecurity http):
    - authorizeHttpRequests: 공개 경로 permitAll(섹션 1.3) + anyRequest().authenticated().
    - formLogin: loginPage(/login), loginProcessingUrl(/login)(기본값과 동일, 명시), defaultSuccessUrl(/, false), failureUrl(/login?error), permitAll().
    - logout: logoutUrl(/logout), logoutSuccessUrl(/login?logout), permitAll().
    - exceptionHandling: /api/v1/** 매처에 대해 HttpStatusEntryPoint(HttpStatus.UNAUTHORIZED) 등록(REST 401). 그 외는 formLogin 기본 진입점(LoginUrlAuthenticationEntryPoint to 302 redirect).
    - CSRF: 기본 활성 유지(명시적 설정 없음 또는 명시적 enable). 끄지 않는다.
  - PasswordEncoder passwordEncoder() to BCryptPasswordEncoder.
  - UserDetailsService userDetailsService(SecurityUserProperties props, PasswordEncoder encoder) to InMemoryUserDetailsManager(사용자 1명, encoder.encode(props.password())).
- 비즈니스 로직: 없음(설정/빈 조립만).

### [backend-implementor] com.shop.shop.security.SecurityUserProperties
- 역할: shop.security.user 프리픽스 바인딩(record 또는 클래스).
- 필드: username(기본값 user), password(기본값 dev1234). @ConfigurationProperties(prefix = shop.security.user).
- 주의: 운영 비밀번호를 코드/평문 yml에 남기지 않는다는 주석 + 후속 DB 인증 전환 TODO 명시.

### [backend-implementor] com.shop.shop.auth.controller.LoginViewController
- 역할: GET /login 에서 로그인 뷰 반환.
- 어노테이션: @Controller.
- 메서드: @GetMapping(/login) String login() returns auth/login. 파라미터(error, logout)는 컨트롤러에서 처리하지 않고 템플릿에서 param.error/param.logout으로 분기(컨트롤러 무로직 유지). 비즈니스 로직 0.

### [backend-implementor] com.shop.shop.home.controller.HomeViewController
- 역할: GET / 에서 홈 뷰 반환(보호 경로).
- 어노테이션: @Controller.
- 메서드: @GetMapping(/) String home() returns home/home. 로직 0. (사용자명 표시는 템플릿에서 sec:authentication=name 사용 — 모델에 Entity/DTO를 담지 않는다.)

### [view-implementor] templates/auth/login.html
- 역할: 로그인 폼 렌더링.
- 요구: form th:action 으로 /login, method post (CSRF 히든 자동 주입). 필드 name=username, name=password. 제출 버튼.
- 메시지 분기: th:if param.error to 실패 메시지, th:if param.logout to 로그아웃 안내.
- Entity/DTO 모델 의존 없음(폼 DTO 불필요 — 아래 계약 참고).

### [view-implementor] templates/home/home.html
- 역할: 인증 후 홈. 로그아웃 폼 포함.
- 요구: form th:action 으로 /logout, method post + 로그아웃 버튼(POST, CSRF 자동). xmlns:sec 네임스페이스로 sec:authentication=name 사용자명 표시.

### [backend-implementor] com.shop.shop.security.SecurityConfigTest
- 역할: (a)~(e) 검증(섹션 5).

### 폼 로그인 DTO 필요 여부 — 불필요
- 폼 로그인 POST /login은 Spring Security의 UsernamePasswordAuthenticationFilter가 username/password 파라미터를 직접 읽는다. 커맨드 객체(@ModelAttribute) 바인딩이 아니므로 폼 DTO/ViewModel을 만들지 않는다. (만들면 과도 설계.)

---

## 백엔드 - 화면 인터페이스 계약 (정합 필수)

메인 에이전트가 backend-implementor to view-implementor 순으로 호출하며, 아래 계약을 양측이 동일하게 따른다.

| 항목 | 계약 값 |
|---|---|
| 로그인 뷰 이름 | auth/login (파일 templates/auth/login.html) |
| 홈 뷰 이름 | home/home (파일 templates/home/home.html) |
| 로그인 폼 action | th:action 으로 /login, method post |
| 로그인 필드명 | username, password (Spring Security 기본 파라미터명) |
| 로그아웃 폼 action | th:action 으로 /logout, method post |
| 로그인 성공 착지 | / (defaultSuccessUrl, alwaysUse=false) |
| 로그인 실패 리다이렉트 | /login?error to 템플릿 param.error 분기 |
| 로그아웃 리다이렉트 | /login?logout to 템플릿 param.logout 분기 |
| CSRF | 활성. th:action 사용으로 _csrf 히든 자동 주입(템플릿이 수동 히든 필드 추가 금지) |
| 사용자명 표시 | 템플릿에서 sec:authentication=name (thymeleaf-extras-springsecurity6, 보유) |
| 모델 키 | 없음(로그인/홈 모두 모델 무전달). Entity 전달 금지 규칙 자동 충족 |

---

## 3. 데이터 흐름

1. 비인증 사용자가 보호 경로(GET /) 요청 to SecurityFilterChain이 미인증 판단 to (View 경로이므로) 302 redirect to /login.
2. GET /login to permitAll to LoginViewController.login() to auth/login 렌더. 폼은 th:action 으로 /login이라 응답 HTML에 _csrf 히든 필드 포함.
3. 사용자가 username/password 입력 후 POST /login 제출(브라우저가 _csrf 동봉) to UsernamePasswordAuthenticationFilter가 InMemoryUserDetailsManager로 인증.
   - 성공 to SecurityContext에 인증 저장, 302 to /(또는 진입 시도했던 보호 경로) to home/home 렌더.
   - 실패 to 302 to /login?error to 템플릿이 param.error로 오류 메시지 표시.
4. /api/v1/**(향후) 비인증 접근 to 리다이렉트 대신 401(JSON 흐름 적합, 본문 없음/시큐리티 기본).
5. 로그아웃: 홈의 POST /logout(CSRF 동봉) to LogoutFilter가 세션 무효화 to 302 to /login?logout to 템플릿이 param.logout로 안내.

CSRF 토큰 흐름: GET 응답 폼에 토큰 주입 to POST 시 동봉 to 서버 검증 통과. 테스트에서는 with(csrf())로 토큰 제공.

---

## 4. 예외 처리 전략

- 인증 실패/접근 거부 = Spring Security 책임. AuthenticationException(미인증) to AuthenticationEntryPoint: View는 /login redirect, /api/v1/**는 401. AccessDeniedException(인가 거부) to 시큐리티 기본 처리(현 Task는 Role 미분화라 사실상 미발생).
- 애플리케이션 예외 = 기존 advice 책임. 컨트롤러/서비스에서 던지는 BusinessException 등은 종전대로 RestExceptionHandler(REST, JSON ErrorResponse) / ViewExceptionHandler(View, error/error 뷰)가 처리. SecurityConfig는 이 advice들을 건드리지 않는다.
- REST(401) vs View(redirect) 분리가 REST 예외 응답과 View 예외 처리를 섞지 않는다 제약을 충족한다. 보안 예외는 필터 단계에서 종결되어 advice까지 도달하지 않으므로 책임이 겹치지 않는다.
- 기존 핸들러 충돌 없음: 보안 예외(필터 레벨)와 애플리케이션 예외(@ControllerAdvice, 디스패처 레벨)는 처리 지점이 다르다. error 디스패치 경로(/error)는 permitAll로 열어 두어 인증 필터가 에러 렌더를 막지 않게 한다.

---

## 5. 검증 방법

### 테스트 슬라이스 선택 — @SpringBootTest(webEnvironment=MOCK) + @AutoConfigureMockMvc
- 이유: @WebMvcTest는 시큐리티 슬라이스에서 SecurityConfig + 컨트롤러를 @Import하면 동작하지만, InMemoryUserDetailsManager/PasswordEncoder/SecurityUserProperties(@ConfigurationProperties) 빈 로딩과 @EnableConfigurationProperties를 슬라이스에서 재구성해야 해 설정이 번거롭다.
- 실 DB가 불필요(in-memory 인증)하고, 테스트 프로파일(src/test/resources/application.yml)이 DataSource/JPA/Kafka/Modulith 자동설정을 이미 제외한다. 따라서 @SpringBootTest로 띄워도 DB 없이 컨텍스트가 뜬다.
- @AutoConfigureMockMvc(addFilters 기본 true to 시큐리티 필터 적용). spring-security-test의 formLogin(), logout(), csrf(), user()/SecurityMockMvcRequestPostProcessors 활용.
- 대안(트레이드오프 섹션): @WebMvcTest로 더 가볍게 갈 수도 있으나 빈 구성 비용 증가. 본 Task는 통합 성격이 강해 @SpringBootTest 채택.

### 검증 시나리오 - Acceptance Criteria 매핑

| # | 테스트 | 기대 | Acceptance Criteria |
|---|---|---|---|
| (a) | GET / 비인증 | status 302, redirectedUrl 패턴 **/login | 비인증 사용자는 보호 경로 접근 시 로그인 페이지로 이동 |
| (b) | GET /login | status 200, view auth/login, 응답 본문에 _csrf 와 name=username 포함 | 로그인 폼이 CSRF 토큰과 함께 정상 렌더링 |
| (c) | formLogin().user(user).password(pw) (+csrf) | authenticated(), status 302 to / | 로그인 성공 흐름 확인 |
| (d) | formLogin().user(user).password(wrong) (+csrf) | unauthenticated(), 302 to /login?error | 로그인 실패 흐름 확인 |
| (e) | logout() (인증 상태) | 302 to /login?logout | 로그아웃 흐름 확인 |
| (보강) | GET /api/v1/ping(미존재) 비인증 | redirect 아님 — 401(매처 정책 검증). 엔드포인트가 없으면 401 또는 404가 되므로, 정책 단언이 불안정하면 이 케이스는 정책 주석으로 남기고 단언은 (a)~(e)에 집중 | REST 정책 방향 문서화 |

- CSRF 검증: (c)~(e)는 with(csrf()) 또는 formLogin()/logout()(자동 csrf 포함) 사용. CSRF 없는 POST /login이 403임을 1케이스로 추가해 CSRF 활성도 단언 가능(선택).

### 회귀 확인
- 기존 공통 기반 테스트(BaseEntityTest, AdviceSeparationTest, RestExceptionHandlerTest, ViewExceptionHandlerTest, ShopCoreApplicationTests)가 깨지지 않아야 한다.
- 주의점: 기존 advice 테스트들은 excludeAutoConfiguration = SecurityAutoConfiguration.class + addFilters=false로 시큐리티를 명시적으로 배제해 슬라이스로 동작한다. 이 Task가 SecurityConfig(@Configuration, @EnableWebSecurity)를 추가해도 그 테스트들은 @WebMvcTest(controllers=...)로 SecurityConfig를 컴포넌트 스캔하지 않으므로 영향 없음. ShopCoreApplicationTests(전체 컨텍스트 로딩)는 SecurityConfig 빈이 추가로 로딩되지만 in-memory라 DB 의존 없이 정상 기동해야 한다 — 이 점을 구현 시 확인한다.
- 실행: 워크스페이스 루트가 아닌 shop-core/ 에서 ./gradlew test.

---

## 6. 트레이드오프

| 결정 | 선택 | 대안 | 사유 |
|---|---|---|---|
| 인증 소스 | InMemoryUserDetailsManager | DB 기반 UserDetailsService | 회원 도메인이 이 Task 범위 밖. DB 테이블 신설은 과도 설계. 인터페이스 의존으로 후속 무중단 교체 |
| 자격증명 위치 | @ConfigurationProperties + 코드 기본값 폴백 | 순수 하드코딩 / 순수 yml | 로컬은 기본값으로 즉시 동작, 운영/공유 환경은 env로 주입 가능. 평문 비밀번호를 코드/yml에 박는 위험 최소화(개발용 기본값임을 주석 명시) |
| 필터 체인 | 단일 SecurityFilterChain + 경로별 정책 | securityMatcher 2체인 분리 | 현재 REST 0개. 분리는 과도. 정책 방향(REST 401 / View redirect)만 명확히 박고, REST 도입 시 체인 분리로 리팩터링 |
| 보호 경로 검증 수단 | 실제 홈 컨트롤러 GET / 신설 | 테스트 전용 더미 컨트롤러 | 어차피 첫 화면, 로그인 성공 착지, 로그아웃 착지로 재사용. 더미보다 자연스럽고 최소 1개만 추가 |
| 폼 DTO | 없음 | LoginForm DTO | 시큐리티 필터가 파라미터 직접 파싱. DTO는 불필요 |
| 테스트 슬라이스 | @SpringBootTest + @AutoConfigureMockMvc | @WebMvcTest + @Import | in-memory 빈/@ConfigurationProperties 로딩 단순. 실 DB 불필요(test 프로파일이 자동설정 제외) |
| REST 미인증 응답 | 401(매처 한정) | 전역 redirect | View/REST 예외 분리 제약 충족 |

---

## Spring Boot 컨벤션
- 패키지: 보안 전역 com.shop.shop.security, 인증 화면 com.shop.shop.auth.controller, 홈 com.shop.shop.home.controller({module}/controller 규칙).
- 어노테이션: @Configuration, @EnableWebSecurity, @EnableConfigurationProperties, @Bean, @Controller, @GetMapping.
- 예외 처리: 보안 예외는 시큐리티 필터(EntryPoint), 애플리케이션 예외는 기존 @ControllerAdvice. 모든 커스텀 예외는 RuntimeException 상속(BusinessException) 유지.
- ViewController는 view name(String) 반환, 모델에 Entity 금지(이 Task는 모델 무전달).
- CSRF 활성 유지. 정적 자산은 ObjectStorage와 무관(보안 permitAll 경로일 뿐).

---

## 완료 조건 체크리스트
- [ ] SecurityConfig에 SecurityFilterChain + BCryptPasswordEncoder + InMemoryUserDetailsManager 빈 정의
- [ ] SecurityUserProperties로 자격증명 외부화(+개발용 기본값, 평문 비밀번호 인코딩)
- [ ] 공개 경로(GET /login, 정적, /error) permitAll, 그 외 authenticated
- [ ] formLogin: loginPage /login, success /, failure /login?error
- [ ] logout: /logout to /login?logout
- [ ] /api/v1/** 미인증 시 redirect 대신 401 정책 적용
- [ ] CSRF 활성 유지(폼은 th:action 사용으로 자동 주입)
- [ ] LoginViewController GET /login to auth/login(로직 0)
- [ ] HomeViewController GET / to home/home(로직 0)
- [ ] templates/auth/login.html: username/password 폼, error/logout 메시지 분기
- [ ] templates/home/home.html: 로그아웃 폼 + sec:authentication
- [ ] 테스트 (a)~(e) 작성 및 통과
- [ ] 기존 공통 기반 테스트 회귀 없음
- [ ] shop-core/ 에서 ./gradlew test 그린

## 워크플로우 분담
1. backend-implementor: SecurityConfig, SecurityUserProperties, LoginViewController, HomeViewController, SecurityConfigTest.
2. view-implementor: auth/login.html, home/home.html (위 인터페이스 계약 준수).
3. 호출 순서: backend to view(Service/뷰이름/필드명 계약 확정 후). 이후 reviewer to (FAIL 시) fixer, 최대 3회.

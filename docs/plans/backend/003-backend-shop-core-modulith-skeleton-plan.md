# 003. shop-core Spring Modulith 모듈 골격 — 구현 Plan (하이브리드 경계 개정본)

> 영역: backend (Spring Modulith 모듈 경계 골격 + 구조 검증 테스트 + 로그인 UI 모듈 편입)
> 대상 프로젝트: shop-core (모듈러 모놀리스)
> 작성일: 2026-05-30 / 개정일: 2026-05-30
> 상태: plan only (코드 변경 없음)
> 채택안(A) 기준 화면(Thymeleaf) 산출물이 없으므로 view-implementor 분담은 없고 backend-implementor 가 단독 수행한다.

---

## Revision 노트 (이번 개정 요지)

사용자가 확정한 하이브리드 모듈 경계 모델에 맞춰 기존 plan을 개정한다. 변경 핵심은 3가지다.

1. 로그인 UI를 member 모듈로 편입: com.shop.shop.auth.controller.LoginViewController -> com.shop.shop.member.controller.LoginViewController 로 클래스를 이동한다. 이동 후 auth 패키지는 비므로 auth 패키지(디렉터리) 제거(빈 패키지로 남기지 않음). 따라서 Modulith 모듈 목록에서 auth가 사라진다.
2. security 모듈은 횡단 인프라로 분리 유지: SecurityConfig 를 member 로 편입하지 않는다. 인증 메커니즘(필터체인, UserDetailsService 빈, CSRF)은 횡단 관심사이며, 인증 주체/UI(member)와 인증 메커니즘(security)을 분리한다.
3. home(HomeViewController)은 앱 셸로 유지: 그대로 둔다. 재구성하지 않는다.

뷰 이름/템플릿 처리 결정 = 채택안 (A) 최소 변경. 클래스만 member.controller 로 이동하고 뷰 이름 auth/login, 템플릿 경로 templates/auth/login.html 를 그대로 유지한다. 따라서 SecurityConfigTest 의 view name 단언(auth/login)과 모든 기존 테스트가 무수정으로 통과하며, view-implementor 분담이 발생하지 않는다. (대안 (B)는 6장 트레이드오프에 명시.)

기존 plan 대비 유지: 6개 도메인 모듈(member/product/cart/order/payment/inventory) x 7서브패키지 package-info 전략, common OPEN 선언, ModularityTests(plain JUnit, verify), writeDocumentation 미포함, displayName 미부여, 빈 패키지 package-info 전략, 이벤트 계약 변경 금지, 도메인 기능 구현 범위 밖. 경계 재조정은 로그인 UI 이동 + auth 제거에 한정하며 security/home/product 등 다른 패키지 재구성은 하지 않는다.

---

## 구현 목표
shop-core 핵심 도메인을 Spring Modulith 모듈 경계(member/product/cart/order/payment/inventory 6개)로 분리하고, 각 모듈에 7개 표준 서브패키지(controller/service/repository/domain/dto/event/messaging) 골격과 모듈 간 직접 의존을 금지하는 구조 검증 테스트를 추가한다. 동시에 로그인 UI(LoginViewController)를 member 모듈로 편입하고 빈 auth 패키지를 제거한다. 실제 도메인 기능(Entity/Service/Repository/이벤트) 구현은 범위 밖(이동되는 LoginViewController는 기존 단순 뷰 반환 그대로 유지).

## 영향 범위

### 이동 파일 (1개)
- com.shop.shop.auth.controller.LoginViewController -> com.shop.shop.member.controller.LoginViewController
  - 변경: 패키지 선언(package com.shop.shop.member.controller;)만 변경. 본문(GetMapping /login -> return auth/login)은 (A) 채택으로 무변경. import 변경 없음(다른 모듈 타입 미사용).
  - Javadoc 1줄 보강 권장: 회원 모듈의 로그인 화면 진입점 취지(선택, 본문 로직 불변).

### 제거 패키지 (1개)
- com.shop.shop.auth.controller 및 상위 com.shop.shop.auth 디렉터리 — LoginViewController 이동 후 비므로 디렉터리째 제거(빈 패키지/잔존 package-info 금지). Modulith 모듈 목록에서 auth 소멸.

### 신규 파일 (main) — 모듈 루트 package-info 6개 + 서브패키지 package-info 42개 = 48개
- 6개 모듈 x package-info.java(모듈 루트): com/shop/shop/{member,product,cart,order,payment,inventory}/package-info.java
- 6개 모듈 x 7개 서브패키지 package-info.java: com/shop/shop/{module}/{controller,service,repository,domain,dto,event,messaging}/package-info.java
  - 비고: member/controller 패키지는 package-info.java(레이어 설명)와 실제 클래스 LoginViewController.java 가 공존한다(package-info.java 는 타입이 아니라 패키지 문서이므로 실제 클래스와 충돌 없음).

### 신규 파일 (test)
- shop-core/src/test/java/com/shop/shop/ModularityTests.java (구조 검증: ApplicationModules.verify())

### 조건부 신규 (검증 결과에 따라, 1.3, 6장)
- com/shop/shop/common/package-info.java (common 을 OPEN 모듈로 선언 — verify 결과로 확정, 기본 생성 권장)
- com/shop/shop/{security,home}/package-info.java (verify 가 이들 때문에 깨질 때에만 최소 조치 — auth 는 제거되므로 대상에서 제외)

### 수정 파일
- 없음 (build.gradle 은 Modulith 의존성을 이미 보유 — 추가 불필요. SecurityConfig/SecurityConfigTest/LayoutRenderingTest/템플릿 모두 (A) 채택으로 무수정)

### 범위 밖 (필요성만 언급, 후속 Task로 미룸)
- 도메인 Entity/Service/Repository, Kafka Producer/Listener, 모듈 간 노출 인터페이스, 이벤트 페이로드 클래스, 모듈 문서(PlantUML) 상시 생성
- member 도메인의 DB 기반 UserDetailsService 구현(SecurityConfig 가 인터페이스로 DI 받을 대상) — 후속 (1.6 방향만 기록)

### 영향 범위 요약 표
| 항목 | 대상 | 내용 |
|---|---|---|
| 이동 파일 | LoginViewController | auth.controller -> member.controller (패키지 선언만, (A)로 본문 불변) |
| 제거 패키지 | com.shop.shop.auth | 디렉터리째 삭제(빈 패키지 금지) |
| 신규 main | package-info 48개 | 6 모듈 루트 + 42 서브패키지 |
| 조건부 main | common package-info(OPEN) | 기본 생성 권장 / security, home 은 깨질 때만 |
| 신규 test | ModularityTests | verify() |
| 무수정 | SecurityConfig / SecurityConfigTest / LayoutRenderingTest / 템플릿 | (A) 채택으로 영향 없음 |

---

## 1. 설계 방식 및 이유

### 1.0 하이브리드 경계 모델의 설계 근거 (이번 개정의 핵심)
- member = 인증 주체 + 로그인 UI 진입점. 로그인 화면(/login)은 회원이 자신을 식별/인증하는 행위의 UI이므로 회원 도메인의 진입점으로 보는 것이 도메인 응집에 부합한다. 따라서 LoginViewController 를 member.controller 로 편입한다. 이는 CLAUDE.md 의 {module}/controller 레이어 규칙(ViewController -> Service -> Repository)에도 그대로 맞는다(현재는 단순 뷰 반환이므로 Service 의존 없음).
- security = 횡단 인증 메커니즘. SecurityFilterChain, CSRF, 미인증 진입점(401/302) 분기, PasswordEncoder, (개발용)UserDetailsService 빈 구성은 특정 도메인이 아니라 앱 전체에 가로지르는 인프라다. 이를 member 에 넣으면 product/order 등 다른 도메인 요청의 보안까지 member 가 소유하게 되어 경계가 흐려진다. 그래서 security 를 별도 횡단 모듈로 유지한다.
- home = 앱 셸. /(인증 후 홈)은 특정 도메인이 아니라 로그인 직후 진입하는 셸 화면이므로 home 모듈로 유지한다. 도메인 화면(상품 목록 등)이 추가되면 각 도메인 모듈이 자기 화면을 갖고, home 은 셸/대시보드 역할만 한다.
- 향후 느슨 결합 방향(편입 없이): member 도메인이 성장하면 member 가 DB 기반 UserDetailsService 구현 빈을 소유하고, security 의 SecurityConfig 는 그 구현을 UserDetailsService 인터페이스 타입으로 DI 받는다(현재 SecurityConfig 의 TODO 주석과 일치). 이때도 security -> member 의 타입 import 의존을 강제로 만들 필요가 없고 스프링 DI 로 런타임 주입되므로, 모듈 경계를 유지한 채 인메모리 -> DB 인증으로 교체할 수 있다. 본 Task 범위 밖이며 방향만 기록한다.

### 1.1 Spring Modulith 모듈 인식 원리
- Spring Modulith 는 SpringBootApplication 이 위치한 base package(com.shop.shop) 직하의 각 패키지를 하나의 application module 로 자동 인식한다(컨벤션 기반).
- 기존 common/security/home 도 각각 모듈로 취급된다. (개정 전 목록에 있던 auth 는 제거되므로 더 이상 모듈이 아니다.)
- 개정 후 전체 모듈 목록: member / product / cart / order / payment / inventory(6 도메인) + common(OPEN) / security / home. (auth 제외)
- 모듈 루트 타입은 공개 API, 서브패키지 타입은 internal(외부 참조 시 verify 위반)로 간주된다. 이것이 모듈 간 직접 의존 금지를 정적으로 강제하는 메커니즘이다.
- 편입된 member.controller.LoginViewController 는 member 모듈의 internal 타입이 된다. 외부 모듈이 이 타입을 직접 참조하지 않는 한 verify 위반이 없다(1.3.1 참조).

### 1.2 7개 서브패키지가 모두 internal인 의미 (member 만 controller 에 실 클래스 보유)
- product/cart/order/payment/inventory 5개 모듈은 모듈 루트 타입 없이 7개 서브패키지만(빈 package-info) 갖는다 -> 공개 API 없는 빈 모듈. 협력이 없어 verify 가 검사할 의존이 없다.
- member 모듈은 더 이상 순수 빈 골격이 아니다: member.controller 에 실 클래스 LoginViewController 가 위치한다. 나머지 6개 서브패키지 및 controller 의 package-info 는 그대로 두어 후속 구현 슬롯을 유지한다. LoginViewController 는 단순 뷰 반환이라 다른 모듈 타입을 import 하지 않으므로 member 가 illegal 의존을 만들지 않는다.
- 향후 모듈 간 통신은 (a) Kafka/도메인 이벤트, (b) 명시 노출 API 타입으로만. 직접 internal 참조는 금지이며 verify 가 잡는다.

### 1.3 common 공유 모듈 처리 (핵심 쟁점)
- 현재 cross-package import 는 0건(이동되는 LoginViewController 도 import 없음). 즉 지금 시점 verify()는 추가 조치 없이 통과할 가능성이 높다.
- 그러나 common(BaseEntity, BusinessException, ErrorResponse, 예외 핸들러, JpaAuditingConfig)은 향후 모든 도메인 모듈이 의존하는 횡단 공유 모듈이다. 도메인 코드가 들어오면 member.domain -> common.domain.BaseEntity 같은 의존이 필연적이며, common 을 일반 모듈로 두면 다수 모듈이 common 의 internal 타입을 참조하여 verify 가 깨진다.
- 결정: common 을 OPEN 모듈로 선언한다. 표준 방법은 모듈 루트 package-info.java 에 다음을 다는 것이다.

      @org.springframework.modulith.ApplicationModule(
          type = org.springframework.modulith.ApplicationModule.Type.OPEN)
      package com.shop.shop.common;

  OPEN 모듈은 다른 모듈이 그 서브패키지(internal 포함) 타입에 접근해도 verify 위반으로 잡지 않는다. 정당한 최소 조치이며, 후속 도메인 Task 가 바로 시작 가능하게 한다.
- 불확실성 처리: OPEN 표현 후보 셋. 구현 에이전트는 verify()를 돌려 가장 단순히 통과하는 1개를 택한다.
  1. (1순위) package-info.java 에 ApplicationModule(type = Type.OPEN) — 표준/최소.
  2. (대안) ApplicationModules.of(...) 호출 시 설정/필터로 common 을 shared 지정.
  3. (대안) verify 시 allowed dependency 명시.
  -> 1순위 통과 시 채택, 실패 시에만 대안으로. (1.3.x 에서 Type.OPEN 은 지원 API)

#### 1.3.1 로그인 UI 이동의 Modulith verify 영향 재검토 (개정 핵심)
- security -> member import 의존이 생기지 않는다. SecurityConfig 는 LoginViewController 타입을 import 하지 않고 /login URL 문자열(상수 LOGIN_PAGE)로만 로그인 페이지/처리 URL/실패 URL 을 연결한다(실제 코드 확인: loginPage /login 등). LoginViewController 가 member 로 이동해도 security 는 여전히 문자열로만 연결되므로 security -> member 모듈 의존이 발생하지 않는다 -> verify 위반 없음.
- member.controller.LoginViewController 는 다른 모듈 타입을 import 하지 않는다. 본문이 Controller + GetMapping + return auth/login 뿐이라 common.exception 등 어떤 모듈 타입도 참조하지 않는다(실제 코드 확인). 따라서 member -> 타 모듈 illegal 의존이 없다. 설령 추후 common 타입을 참조하더라도 common 은 OPEN 이라 허용된다.
- auth 모듈 소멸은 verify 에 무해하다. auth 는 LoginViewController 단일 클래스만 있던 모듈이었고 다른 모듈이 auth 타입을 참조한 적이 없다. 모듈이 사라져도 끊어질 의존이 없다.
- 결론: 로그인 UI 이동 + auth 제거 후에도 verify PASS 가 기대값이다.

#### 1.3.2 security/home 점검 방향 (auth 는 제외)
- security/home 도 모듈로 잡힌다. 현재 상호 참조가 없어 verify 를 깨지 않을 것으로 예상한다. home 은 컨트롤러만, security 는 자기완결적 설정이라 cycle/illegal-dependency 가 없다.
- SecurityConfig 가 향후 member UserDetailsService 로 교체될 때 DI 로 인터페이스를 받는 방향이며(1.0 말미) 타입 import 를 강제하지 않으므로 본 Task 범위에선 무관.
- verify 가 이들 때문에 깨질 때에만 최소 조치(의존 허용 선언 또는 OPEN)를 적용하고 재구성(이동/병합)은 하지 않는다. 현 상태에선 무조치가 기본.

### 1.4 빈 패키지 Git 유지 전략 (핵심 쟁점)
- Git 은 빈 디렉터리를 추적하지 않으므로 빈 서브패키지가 커밋에서 사라진다.
- 채택: 각 패키지에 package-info.java. 사유: 런타임 산출물 없음, 패키지 문서화, Modulith 패키지 인식의 Java 관용, Acceptance 각 모듈에 7개 패키지 준비 충족.
- .gitkeep(Java 관례 위배), marker 빈 클래스(남발 위험) 미채택.
- 각 package-info.java 에 레이어 역할 1~2줄 Javadoc(controller=REST/View 진입점, service=비즈니스 로직, repository=영속화, domain=Entity, dto=요청/응답 DTO, event=도메인 이벤트, messaging=Kafka Producer). CLAUDE.md 레이어 규약을 주석 가드레일로 남긴다.
- member/controller 의 package-info 와 LoginViewController 공존: package-info.java 는 패키지 문서(타입 아님)이므로 같은 패키지 실 클래스와 충돌하지 않는다. controller package-info Javadoc 에 View 진입점(현재 LoginViewController 가 /login 담당) 1줄 추가 가능(선택).

### 1.5 모듈 식별/명명 (핵심 쟁점)
- 컨벤션(패키지=모듈)만으로 인식 충분. displayName 부여는 선택.
- 채택(최소주의): 6개 도메인 모듈 루트 package-info 는 Javadoc 설명만(displayName 생략, YAGNI). common 만 OPEN 선언을 위해 ApplicationModule 사용. 필요 시 후속 부여.

### 1.6 member 루트 package-info 역할 설명 (개정 반영)
- member 모듈 루트 package-info Javadoc 은 회원 도메인 + 로그인 UI 진입점으로 기술한다. (인증 주체이자 로그인 화면(/login) ViewController 소유. 향후 DB 기반 UserDetailsService 구현 소스가 되며, security 모듈은 그 구현을 인터페이스로 DI 받는다 — 방향만 기록.)

---

## 2. 구성 요소 (생성/이동할 파일)

### main — 이동 (1개)
- com.shop.shop.member.controller.LoginViewController (from auth.controller). 패키지 선언만 변경, 본문 불변((A)). Javadoc 보강 선택. 이동 후 com.shop.shop.auth 디렉터리 제거.

### main — 모듈 루트 package-info (6개)
com/shop/shop/{module}/package-info.java.
- member — 회원 도메인 + 로그인 UI 진입점(인증 주체, 향후 DB 기반 UserDetailsService 소스; LoginViewController 가 /login 담당)
- product — 상품 도메인
- cart — 장바구니 도메인
- order — 주문 도메인 (OrderCompletedEvent 발행 소유)
- payment — 결제 도메인 (PaymentFailedEvent 발행 소유)
- inventory — 재고 도메인
- 비고: order/payment 의 messaging/event 서브패키지는 향후 토픽 발행 지점이 됨을 Javadoc 에 방향만 기록(이벤트 계약 SSOT 는 docs/architecture.md — 본 Task 에서 계약 변경/페이로드 클래스 생성 금지).

### main — 서브패키지 package-info (42개 = 6 x 7)
각 모듈 controller / service / repository / domain / dto / event / messaging 7개. 레이어 역할 Javadoc, 타입 정의 없음.
- 예외: member/controller 에는 package-info.java + LoginViewController.java 가 공존한다.

### main — 조건부 (verify 결과로 확정)
- com/shop/shop/common/package-info.java — ApplicationModule(type = Type.OPEN) (기본 생성 권장).
- com/shop/shop/{security,home}/package-info.java — verify 가 깰 때에만 최소 조치. (auth 는 제거되어 대상 아님.)

### test (1개)
#### com.shop.shop.ModularityTests
- 역할: 모듈 구조 정적 검증.
- 형태: plain JUnit 5(SpringBootTest 불필요, 실 DB 불필요). verify()는 ArchUnit 정적 분석이라 컨텍스트 부팅 없음 -> test profile 자동설정 제외/DataSource 부재와 무관.
- 핵심 코드:

      static final ApplicationModules MODULES = ApplicationModules.of(ShopCoreApplication.class);

      @Test
      void verifiesModuleStructure() {
          MODULES.verify();   // cycle / illegal internal dependency 발견 시 실패
      }

- writeDocumentationSnippets()는 미포함(과도). 위치는 base package(com.shop.shop).

---

## 3. 데이터 흐름 (개념적 — 본 Task 는 런타임 코드 흐름 없음)

### 3.1 구조 검증 흐름 (정적)
```
./gradlew test
  -> ModularityTests (plain JUnit)
  -> ApplicationModules.of(ShopCoreApplication.class)
       : base package(com.shop.shop) 직하 패키지를 모듈로 스캔
       (member/product/cart/order/payment/inventory/common/security/home)   <- auth 제거됨
  -> .verify()
       : ArchUnit 으로 모듈 간 의존 분석
       - 서브패키지(internal) 타입을 외부 모듈이 참조 -> 위반
       - 순환 의존(cycle) -> 위반
       - OPEN 모듈(common)의 internal 참조 -> 허용
  -> 위반 0건이면 PASS
```

### 3.2 로그인 화면 런타임 흐름 (이동 후, 참고 — 본 Task 신규 로직 없음)
```
브라우저 GET /login
  -> [security] SecurityFilterChain: permitAll (GET /login)
  -> [member] LoginViewController.login()  -> view auth/login ((A) 유지)
  -> Thymeleaf: templates/auth/login.html 렌더 ((A) 경로 유지)
폼 POST /login (csrf 포함)
  -> [security] UsernamePasswordAuthenticationFilter (URL 문자열 연결, 타입 의존 없음)
  -> 성공 302 -> /  (home, 앱 셸)
* security 는 LoginViewController 타입을 모름(URL 로만 연결) -> 모듈 경계 유지
```

### 3.3 향후 모듈 간 연결 방향
```
[member/product/cart/order/payment/inventory] -- 의존 --> [common(OPEN): BaseEntity, 예외, 설정]
[security] -- DI(인터페이스 UserDetailsService) --> [member 구현]   (편입 없이 느슨 결합, 후속)
order/payment --(도메인 이벤트 발행: Modulith Outbox)--> messaging(Kafka Producer)
  shop-core 외부(notification)는 Kafka 이벤트로만 단방향 구독 (동기 호출/DB 공유 금지)
모듈 간 직접 협력이 필요하면: internal 직접 참조 금지 -> 노출 API 타입 또는 이벤트로만
```

---

## 4. 예외 처리 전략 (본 Task 범위에서의 의미)

- 본 Task 는 런타임 도메인 코드가 없어 try/catch/커스텀 예외 코드를 작성하지 않는다(이동되는 LoginViewController 도 예외 처리 없음).
- 예외 처리는 verify 실패 = 빌드/테스트 실패로 해석한다. verify 가 잡는 위반: internal 타입 직접 참조, 순환 의존(cycle), 미허용 의존.
- 로그인 UI 이동 관련 위반 가능성 점검: security 가 member.controller.LoginViewController(internal)를 import 하면 위반이지만, security 는 URL 문자열로만 연결하므로 import 가 없다(1.3.1). 이동으로 인한 신규 위반은 예상되지 않는다.
- common 미선언 시 향후 예상 위반: 도메인 모듈이 common.domain.BaseEntity / common.exception.BusinessException(internal)을 상속/참조하면 다수 모듈에서 illegal dependency 가 대량 발생. 이를 선제 차단하려 common 을 OPEN 으로 둔다(1.3).
- 골격 단계에서 예외 변환 규칙, Entity-API 직접 반환 금지는 package-info Javadoc 가드레일로만 남기고 강제 코드는 후속 Task 로 미룬다.

---

## 5. 검증 방법 (./gradlew test)

### 5.1 구조 검증 통과
- ModularityTests.verifiesModuleStructure()가 MODULES.verify() 호출 PASS -> 모듈 경계/의존 규칙 충족. 실 DB/컨텍스트 부팅 없이 통과(정적 분석).

### 5.2 모듈 직접 의존 금지를 잡는 메커니즘
- Modulith 는 base package 직하 패키지를 모듈로, 서브패키지 타입을 internal 로 모델링한다. verify()는 ArchUnit 규칙으로 외부 모듈의 internal 참조/모듈 순환을 검사한다. 골격은 (member 제외) 빈 모듈이라 위반 없이 PASS 하고, 향후 위반 시 즉시 FAIL 로 드러난다(회귀 가드).

### 5.3 로그인 UI 이동/auth 제거 후 회귀 없음 (개정 핵심)
- SecurityConfigTest (a)~(e) + CSRF: (A) 채택으로 view 이름이 여전히 auth/login 이므로 (b) view name 단언(auth/login) 그대로 통과. (a)(c)(d)(e)/CSRF 는 URL/인증 상태 검증이라 패키지 이동과 무관. -> 무수정 통과.
- LayoutRenderingTest T1~T3: /login, / 렌더 본문 마커(footer 마커, name=username, csrf, header/nav 마커, /css/app.css)만 단언 -> 컨트롤러 패키지/뷰 이름에 비의존. (A)에서 템플릿 경로(templates/auth/login.html)도 그대로이므로 렌더 결과 불변 -> 영향 없음.
- 기존 25개 테스트 회귀 없음: package-info 신규는 타입/빈 미추가, LoginViewController 이동은 패키지 선언만 바꿔 빈 등록/핸들러 매핑(/login)이 동일하므로 컨텍스트 기동/MVC 슬라이스에 영향 없음.

### 5.4 verify 가 기존 패키지 때문에 깨지지 않음 확인
- security/home/common + 6 도메인 모듈 전체 verify PASS 확인. (auth 는 제거되어 모듈 목록에서 빠짐.) 깨질 경우 1.3.2 최소 조치 후 재실행. 현재 import 0건이라 무조치 통과가 기대값.

### 5.5 Acceptance Criteria 검증 매핑
| Acceptance | 검증 |
|---|---|
| 모듈 패키지 골격이 아키텍처 규칙과 일치 | 6모듈 x 7서브패키지 package-info 존재(2장) + CLAUDE.md {module}/controller 규칙(member.controller=LoginViewController) 일치 |
| 로그인 UI 의 member 편입 + auth 제거 | LoginViewController 이동(2장) + auth 디렉터리 삭제 확인, 모듈 목록에서 auth 부재(3.1) |
| Spring Modulith 구조 검증 테스트 통과 | ModularityTests verify() PASS (5.1), 이동/제거 후에도 PASS (1.3.1, 5.3) |
| 이후 기능 Task 가 모듈 단위로 바로 시작 가능 | 7서브패키지 사전 생성 + common OPEN 선언(1.3) |
| 모듈 간 직접 의존 금지 규칙을 테스트로 검증 | verify()의 internal/cycle 검사 (5.2), security -> member 미의존 확인(1.3.1) |
| 기존 테스트 회귀 없음 | SecurityConfigTest/LayoutRenderingTest 무수정 통과 + 기존 25개 green (5.3) |

---

## 6. 트레이드오프

- 로그인 UI 모듈 귀속 (채택: member 편입 = 사용자 확정 하이브리드)
  - 채택: LoginViewController -> member.controller. (장) 인증 주체/UI 도메인 응집, {module}/controller 규칙 부합. (단) member 가 빈 골격이 아니게 됨(의도된 결과). security 는 분리 유지.
  - 미채택: auth 모듈 존속 — 단일 컨트롤러만의 모듈로 경계 가치가 낮고 회원 도메인과의 응집을 약화.
  - 미채택: security 로 편입 — 횡단 메커니즘과 화면 진입점을 한 모듈에 섞어 경계가 흐려짐.

- 뷰 이름/템플릿 처리 (채택: (A) 최소 변경)
  - (A) 채택 — 클래스만 이동, 뷰 이름 auth/login, 템플릿 templates/auth/login.html 유지.
    - 장: 테스트 무수정(SecurityConfigTest 의 view name 단언 auth/login 그대로 통과), view-implementor 분담 불필요, 변경 최소. Java 모듈 경계가 핵심이고 템플릿 경로는 평면 리소스라 경계와 무관.
    - 단: member 컨트롤러가 auth/login 뷰를 반환하는 명명 불일치가 약간 남음(기능 무해, 추후 정리 가능).
  - (B) 대안 — 일관 변경: 뷰 이름 member/login, 템플릿 templates/auth/login.html -> templates/member/login.html 이동.
    - 장: 패키지/뷰/템플릿 명명 일관.
    - 단: SecurityConfigTest 의 view name 단언 수정 필요(auth/login -> member/login). LayoutRenderingTest 는 /login 본문 마커(footer/username/csrf) 단언이라 뷰 이름 비의존이므로 영향 없으나, 템플릿이 새 경로에 존재해야 렌더가 성공하므로 템플릿 이동 = view-implementor 작업 유발. 즉 backend 단독이 아니라 backend -> view 분담이 추가됨.
  - 권장 사유: 과도 변경 회피 + 테스트 무수정 + 경계 본질(Java 모듈)에 집중. 사용자가 일관성을 더 원하면 (B)로 전환(담당/테스트 수정 표기는 7장).

- common OPEN/shared 선언 여부 (채택: OPEN 선언)
  - 채택: common 루트 package-info 에 ApplicationModule(type=Type.OPEN). (장) 후속 도메인 모듈이 BaseEntity/예외/설정을 막힘없이 의존, verify 가 향후 무더기 위반을 내지 않음. (단) common 내부 구조 노출(공유 모듈 특성상 의도된 결과).
  - 미채택: 무조치(후속 미룸) — 도메인 첫 Task 에서 즉시 verify 가 깨짐.
  - 미채택: 모듈마다 allowed-dependency 일일이 선언 — 보일러플레이트 증가.

- package-info vs marker 클래스 (채택: package-info)
  - 채택: 빈 패키지 유지를 package-info.java 로(member.controller 는 LoginViewController 와 공존). (장) Java 관용/문서화/런타임 무영향. (단) 파일 수 48개.
  - 미채택: .gitkeep(Java 관례 위배), marker 빈 클래스(남발 위험).

- ApplicationModule(displayName) 부여 여부 (채택: 미부여, common 제외)
  - 채택: 도메인 모듈은 Javadoc 만(YAGNI). verify 무관.

- 서브패키지 전부 생성 vs 모듈 루트만 (채택: 7서브패키지 전부)
  - 채택: Acceptance 각 모듈에 7개 패키지 준비 직접 충족 + 후속 즉시 시작. (단) 빈 package-info 다수.

- writeDocumentationSnippets 포함 여부 (채택: 미포함)
  - 채택: verify 만. (장) 최소/CI 빠름. (단) 모듈 다이어그램 산출 없음.

- security/home 처리 (채택: 무조치 기본, 깨질 때만 최소 조치 / auth 는 제거)
  - 채택: 현재 의존 0건이라 무조치 PASS 기대. 깨질 때만 최소 선언, 재구성 금지. auth 는 본 Task 에서 제거되므로 처리 대상 아님.

---

## Spring Boot / Modulith 컨벤션
- 패키지: com.shop.shop.{member,product,cart,order,payment,inventory}.{controller,service,repository,domain,dto,event,messaging}. (auth 제거; member.controller 에 LoginViewController 공존)
- 어노테이션: org.springframework.modulith.ApplicationModule(type = Type.OPEN) (common 한정). 도메인 모듈은 컨벤션 인식만. 이동된 LoginViewController 는 Controller 그대로.
- 테스트: org.springframework.modulith.core.ApplicationModules.of(ShopCoreApplication.class).verify() (plain JUnit 5, 컨텍스트/DB 불필요).
- 레이어 규약(package-info Javadoc 가드레일): RestController -> ServiceResponse -> Service -> Repository, ViewController -> Service -> Repository, EventListener -> Service -> Repository, Entity 직접 반환 금지, 예외는 RuntimeException 상속 커스텀으로 변환.
- 인증 경계: 인증 주체/UI = member, 인증 메커니즘 = security(횡단). SecurityConfig 는 UserDetailsService/PasswordEncoder 인터페이스에만 의존(향후 member 구현을 DI). URL 문자열 연결로 member 타입 import 회피.
- 이벤트 계약 SSOT 는 docs/architecture.md — 본 Task 에서 변경/페이로드 클래스 생성 금지.

## 완료 조건
- [ ] LoginViewController 를 auth.controller -> member.controller 로 이동(패키지 선언 변경, (A)로 본문/뷰 이름 auth/login 유지)
- [ ] com.shop.shop.auth 디렉터리 제거(빈 패키지/잔존 package-info 없음)
- [ ] 6개 모듈 루트 package-info.java 생성 (member 는 회원 도메인 + 로그인 UI 진입점 명시)
- [ ] 6모듈 x 7서브패키지 = 42개 서브패키지 package-info.java 생성 (member/controller 는 LoginViewController 와 공존)
- [ ] common 모듈 OPEN 선언(package-info ApplicationModule(type=Type.OPEN)) — verify 통과 형태로 확정
- [ ] (필요 시) security/home 에 대한 최소 조치 — verify 가 깰 때에만, 재구성 금지 (auth 는 제거되어 대상 아님)
- [ ] ModularityTests(plain JUnit, ApplicationModules.verify()) 추가 및 PASS (모듈 목록에 auth 부재, member 에 LoginViewController 포함 상태에서 PASS)
- [ ] ./gradlew test verify 통과 + 기존 테스트 회귀 없음: SecurityConfigTest(view name 단언 auth/login 포함)/LayoutRenderingTest 무수정 통과, 기존 25개 green (실 DB 불필요)
- [ ] security 가 member.controller.LoginViewController 타입을 import 하지 않음 확인(URL 문자열 연결 유지) -> security -> member 의존 부재
- [ ] package-info Javadoc 에 레이어 규약/모듈 역할 가드레일 기재
- [ ] 도메인 Entity/Service/Repository/이벤트 클래스 미생성(범위 준수), 이벤트 계약 미변경

## 7. 담당 표기
- 채택안 (A) 기준: backend-implementor 단독 수행. 로그인 UI 이동은 Java 클래스의 패키지 선언 변경(=Java 작업)이고 뷰 이름/템플릿 경로를 유지하므로 화면(Thymeleaf) 산출물이 없다 -> view-implementor 분담 없음.
- (B) 선택 시에만: 템플릿 templates/auth/login.html -> templates/member/login.html 이동 + 뷰 이름 변경에 따른 SecurityConfigTest view name 단언 수정이 필요하므로, backend-implementor(클래스/뷰 이름/테스트 단언) -> view-implementor(템플릿 이동) 순으로 분담 추가.

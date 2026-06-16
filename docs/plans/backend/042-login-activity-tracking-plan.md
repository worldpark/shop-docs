# Plan 042. 로그인 활동 추적 (last_login_at)

> 대상 Task: `docs/tasks/backend/042-backend-shop-core-login-activity-tracking.md`
> 범위: 로그인 성공 시 `users.last_login_at` 갱신(REST·formLogin 둘 다). 집계·화면은 Task 043.
> 순서: 스키마+엔티티+기록(backend-implementor) → reviewer → 풀 게이트.

## 0. 확정 사실 (코드 검증됨)
- **REST 로그인은 AuthenticationManager 미사용**: `AuthServiceResponse.login`이 `memberService.authenticate(email,password)`(수동 검증)로 User 반환 → `AuthenticationSuccessEvent` **발생 안 함**. ⇒ 전역 이벤트 리스너 1개로 통합 불가. **2-훅**(REST=서비스 직접, formLogin=success handler)이 정확.
- **formLogin은 Spring `UsernamePasswordAuthenticationFilter` 경유**: `SecurityConfig:204` formLogin, `loginProcessingUrl`. **커스텀 successHandler를 건드리지 않는다**(기존 `.defaultSuccessUrl("/")` + 커스텀 `htmlNavigationRequestCache()`가 DevTools-probe 리다이렉트 버그를 막고 있어 successHandler 교체 시 회귀 위험 — plan-reviewer 지적).
- **formLogin은 `InteractiveAuthenticationSuccessEvent` 발행**: `AbstractAuthenticationProcessingFilter.successfulAuthentication()`(=UsernamePasswordAuthenticationFilter)가 이 이벤트를 발행한다. **REST 수동 authenticate·JwtAuthenticationFilter는 이 필터를 안 거치므로 미발행** → 이 이벤트 리스너는 **formLogin에만** 발동(요청마다 X). ⇒ formLogin 훅은 **successHandler 교체 대신 이벤트 리스너**로 구현(회귀·경계 위험 0).
- User 시간 매핑: `java.time.Instant`(예 `deletedAt @Column(name="deleted_at") Instant`). 팩토리/의도 메서드(Setter 금지).
- **Clock 빈 의존 금지(plan-reviewer BLOCKER)**: 유일한 Clock 빈 `payment` `OrderExpirySchedulingConfig.systemClock()`은 `@ConditionalOnProperty(shop.order.pending-expiry.enabled=true)`인데 **테스트는 false**(`test/resources/application.yml`) → 테스트 컨텍스트에 Clock 빈 없음. 주입하면 풀 @SpringBootTest 전수 붕괴([[full-context-test-repo-mock-shared-annotation]] 류). ⇒ **Clock 주입하지 말고 `Instant.now()` 직접 사용**(User.withdraw의 `Instant.now()` 선례와 동일). `Instant`는 절대시각 → 30일 윈도우 비교에 KST 변환 불필요(표시만 KST), 테스트는 non-null/갱신(>= 기준시각) 단언으로 충분.
- `memberService.authenticate(email,password): User`, `MemberUserDetailsService`(formLogin/REST 공용, `findActiveByEmail`로 탈퇴 차단).

## 1. 스키마 (Flyway V9)
- `V9__users_last_login.sql`: `ALTER TABLE users ADD COLUMN last_login_at timestamptz NULL;`. 기존 행 NULL(소급 불가 — 한계).
- 인덱스: `CREATE INDEX idx_users_last_login_at ON users (last_login_at);`(043의 30일 카운트 대비, 저비용). 다음 번호 V9(현행 최신 V8) 확인.

## 2. 엔티티
- `member/domain/User.java`: `@Column(name="last_login_at") private Instant lastLoginAt;` + 의도 메서드 `public void recordLogin(Instant now){ this.lastLoginAt = now; }`. (Setter 금지, 기존 of/withdraw 패턴.)
- 스키마 매핑 검증(schema-mapping-validation-rule): Entity Instant ↔ timestamptz 정합.

## 3. 기록 로직 — 단일 진입점 + 2-훅
### 3.1 member 진입점
- `MemberService`(또는 적절한 member 서비스)에 `recordLoginByEmail(String email)`: `findActiveByEmail`(또는 동등)로 User 조회 → `user.recordLogin(Instant.now())`. `@Transactional`(쓰기, `authenticate`가 readOnly라 **별도 메서드로 분리**). **Clock 빈 주입 안 함**(§0 BLOCKER — `Instant.now()` 직접). **email 단일 시그니처**(REST·formLogin 둘 다 email 보유). 미존재/탈퇴 시 조용히 무시(로그인 성공 후 호출이라 정상 케이스엔 항상 존재).
- **spi 노출 불필요**: REST 훅(§3.2)·formLogin 이벤트 리스너(§3.3)가 **둘 다 member 모듈 내부**라 `MemberService`를 직접 호출. published port 신규 노출 없음(과설계 제거). 기존 `AccountFacade`는 self-service 계정용이라 의미 부정합 — 재사용 안 함.

### 3.2 REST 훅
- `AuthServiceResponse.login(...)`: `memberService.authenticate(...)` 성공 직후(토큰 발급 전/후 무관) `recordLogin...(user.getEmail())` 호출. 같은 member.service 내부라 직접 호출.

### 3.3 formLogin 훅 (이벤트 리스너 — successHandler 미교체, 회귀·경계 위험 0)
> plan-reviewer MAJOR 2건(① security→member.spi 컴파일 의존 위반 ② successHandler 교체 시 defaultTargetUrl/htmlNavigationRequestCache 회귀)을 **이벤트 리스너 방식으로 원천 회피**한다. SecurityConfig·successHandler·requestCache를 **전혀 건드리지 않는다**.
- **`member` 모듈에 `@Component` 리스너**(예 `LoginActivityRecorder`): `@EventListener` 또는 `ApplicationListener<InteractiveAuthenticationSuccessEvent>` — `event.getAuthentication().getName()`(=email)으로 `MemberService.recordLoginByEmail(email)` 호출. 의존: 스프링 시큐리티 **프레임워크 이벤트 타입**(`InteractiveAuthenticationSuccessEvent`) + **같은 모듈 `MemberService`**뿐 → **모듈 경계 위반 없음**(member는 이미 spring-security 의존 — `MemberUserDetailsService`).
- **`SecurityConfig` 변경 없음**: successHandler·requestCache·defaultSuccessUrl 그대로 보존 → 기존 리다이렉트/probe 회귀 방지 장치 무손상.
- **단일 발동 보장(코드 확정됨)**: `InteractiveAuthenticationSuccessEvent`는 `AbstractAuthenticationProcessingFilter`(=formLogin 필터)만 발행. REST 수동 `authenticate`·`JwtAuthenticationFilter`(컨텍스트 직접 세팅)는 미발행 → **formLogin 1회만**, 요청마다 갱신 아님, REST와 이중기록 없음(REST는 §3.2 직접 호출).
- **검증 필수**: formLogin 통합 테스트(MockMvc `formLogin()`)로 이벤트가 실제 발행·리스너 발동→`last_login_at` 갱신을 확인(이벤트 발행 누락 시 즉시 적발). 만약 환경상 이벤트가 안 뜨면 차선책으로 successHandler 방식(이 경우 §3.3 이전판처럼 `setDefaultTargetUrl("/")`+`htmlNavigationRequestCache` 주입+super 필수)로 전환 — 단 1차는 이벤트 방식.

## 4. 조회 토대
- 30일 윈도우 카운트(`countByStatus(ACTIVE)`, `countByStatusAndLastLoginAtAfter(ACTIVE, threshold)`)는 **소비처 Task 043에 둔다**(본 Task는 "기록"만). 042는 read 메서드 불필요.

## 5. 순서 / 검증
1. backend-implementor: V9 + 엔티티 + member 진입점 + REST 훅 + formLogin 이벤트 리스너(InteractiveAuthenticationSuccessEvent) + 테스트 → reviewer. (SecurityConfig 무변경.)
2. 메인: 풀 스위트 그린(로그인 플로우 비파괴 회귀).
3. (E2E는 별도 필요성 낮음 — last_login_at는 화면 무노출. 통합 테스트로 충분. 043 대시보드 E2E에서 간접 검증.)

## 6. 테스트 (타깃)
- **REST 로그인 기록**: `AuthServiceResponse.login` 또는 통합 — 로그인 성공 후 해당 user `last_login_at` non-null/갱신(Testcontainers 또는 모킹 검증).
- **formLogin 기록(이벤트)**: MockMvc `formLogin()` 통합으로 `InteractiveAuthenticationSuccessEvent` 발행→리스너→`last_login_at` 갱신 확인(이벤트 미발행 시 적발). 리스너 단위(이벤트→`recordLoginByEmail` 호출 검증)도 보강.
- **미기록 케이스**: 로그인 실패(인증 예외)·탈퇴 차단 시 `last_login_at` 미갱신.
- **회귀**: REST 토큰 발급 정상 + formLogin 302 리다이렉트(saved request/"/") 보존 — **SecurityConfig·successHandler·requestCache 무변경이라 본질적으로 보존**(이벤트 방식의 이점). 풀 게이트의 기존 formLogin/probe 테스트가 그대로 통과하는지 확인.
- 스키마 매핑 검증. 풀 컨텍스트 영향(신규 빈 = `LoginActivityRecorder` 이벤트 리스너 + member 진입점 — 신규 repository 없음, **Clock 빈 의존도 없음**(§0)이라 @MockSharedRepositories·Clock 관련 풀 컨텍스트 붕괴 없음, 풀 게이트로 확인).

## 7. 리뷰 관점
- **두 경로 모두 기록**(REST=서비스 직접, formLogin=`InteractiveAuthenticationSuccessEvent` 리스너), 매 요청이 아닌 **로그인 시점만**(JWT 필터·REST 수동 authenticate는 이벤트 미발행). 실패·탈퇴 미기록. 이중기록 없음.
- **SecurityConfig·successHandler·requestCache·defaultSuccessUrl 무변경** 확인(probe 리다이렉트 회귀 방지 — 이벤트 방식이라 애초에 안 건드림).
- 모듈 경계: 리스너가 **member 모듈 내부**에서 프레임워크 이벤트 타입 + 같은 모듈 `MemberService`만 의존(security→member 컴파일 의존 없음). 시각은 `Instant.now()` 직접(Clock 빈 의존 없음 — §0 BLOCKER), 테스트는 non-null/갱신 단언.
- 엔티티 Setter 금지·의도 메서드. 스키마 매핑 정합(timestamptz↔Instant). 소급 불가 한계 인지.
- 가상스레드 대비: 블로킹 write가 Service 경계, ThreadLocal 직접 미사용.

# 011. shop-core /me 엔드포인트 중복 정리 — 구현 Plan

> 영역: backend only (member 도메인 REST API 중복 제거 + 테스트 정리)
> 대상 프로젝트: shop-core (member 도메인 controller/service + security·member 테스트)
> 작성일: 2026-06-06
> 상태: plan only (코드 변경 없음)
> 성격: 신규 기능 아님 — 중복 API 제거 + 테스트 정리 리팩터링
> view-implementor: 불필요. Thymeleaf 화면·DB schema·Flyway·이벤트 계약·JWT 로직 변경 없음. backend-implementor만 필요.
> 선행: Task 006(JWT 로그인, GET /api/v1/auth/me 도입), Task 007(GET /api/v1/members/me 도입). 이 둘이 만든 MeResponse / MemberService.getById / principal=userId(long) 규약 위에서 중복만 제거한다.

---

## 구현 목표

shop-core의 내 정보 조회 API를 GET /api/v1/members/me 하나로 일원화한다. Task 006에서 도입된 중복 구현 GET /api/v1/auth/me(AuthRestController.me + AuthServiceResponse.me)와 이를 검증하던 테스트를 제거하고, canonical API(MemberRestController.me + MemberServiceResponse.me)의 권한·인증 테스트를 보강한다. auth 도메인은 login/refresh/logout 책임만 남긴다. MeResponse 구조, principal 규약(userId(long)), JWT 발급/refresh/logout 로직, SecurityConfig는 변경하지 않는다.

---

## 1. 설계 방식 및 이유

### 1.1 canonical 선택: GET /api/v1/members/me
- 도메인 의미상 내 회원 정보 조회는 member 도메인의 책임이다(package-structure-rule: member = 회원 가입·로그인·마이페이지). 마이페이지/내 정보는 member에 속한다.
- auth 도메인(AuthRestController)은 인증 책임(login/refresh/logout)에 집중한다. auth가 회원 프로필을 반환하는 것은 책임 혼선이다.
- 두 핸들러는 현재 완전히 동일한 로직이다: (long) authentication.getPrincipal() -> memberService.getById(userId) -> MeResponse.from(user). 즉 AuthServiceResponse.me(L113-117)와 MemberServiceResponse.me(L54-58)는 동일하다. 둘 중 member 쪽을 남긴다.

### 1.2 제거가 단순·안전한 근거 (코드베이스 확인 결과)
- /api/v1/auth/me와 /api/v1/members/me는 둘 다 SecurityConfig의 /me 전용 requestMatcher 없이 anyRequest().authenticated()(SecurityConfig L79)로만 보호된다. grep으로 /me 전용 matcher가 없음을 확인했다. -> SecurityConfig 변경 불필요.
- auth/me 핸들러를 제거해도 보안 경로 규칙은 그대로 유지된다. 제거 후 GET /api/v1/auth/me는 매핑이 사라지므로:
  - 유효 토큰 + 인증 통과 시: 매핑된 핸들러 없음 -> 404 (더 이상 MeResponse 200을 반환하지 않음 = Acceptance 충족).
  - 비인증 시: JwtAuthenticationFilter/EntryPoint가 먼저 작동 -> 401 JSON.
- authServiceResponse.me 호출처는 AuthRestController.me 단 1곳뿐이다(grep 확인: main 호출 1건 + 테스트 참조). 외부 의존 없음 -> 메서드 제거 안전.

### 1.3 범위 밖 (과도한 설계 금지)
- 새 API 추가 금지, /api/v1/auth/me 호환 alias 금지(Constraint), MeResponse 구조 변경 금지, 소유권 검사 로직 추가 금지(principal userId 자체가 본인 식별이므로 별도 소유권 검증 코드 불필요 — 기존과 동일하게 유지).

---

## 2. 구성 요소 (변경/제거/유지 — 파일·라인 단위)

### 2-A. 수정 (코드 제거)

| 파일 | 작업 | 라인(현재) |
|---|---|---|
| shop-core/src/main/java/com/shop/shop/member/controller/AuthRestController.java | me(Authentication) 핸들러 제거(L67-76). 미사용 import 정리: MeResponse(L4), GetMapping(L12), Authentication(L11). 클래스 javadoc L25-26의 GET /me 언급 제거. | L4, L11-12, L67-76 |
| shop-core/src/main/java/com/shop/shop/member/service/AuthServiceResponse.java | me(Authentication) 메서드 제거(L106-117). 미사용 import 정리: MeResponse(L6), org.springframework.security.core.Authentication(L15). login/refresh/logout에서 Authentication/MeResponse 미사용 확인 후 제거. | L6, L15, L106-117 |

### 2-B. 유지 (변경 없음 — canonical)

| 파일 | 비고 |
|---|---|
| shop-core/src/main/java/com/shop/shop/member/controller/MemberRestController.java | me 핸들러(L48-60) 그대로 유지. canonical. |
| shop-core/src/main/java/com/shop/shop/member/service/MemberServiceResponse.java | me(Authentication)(L45-58) 그대로 유지. principal userId -> getById -> MeResponse. |
| shop-core/src/main/java/com/shop/shop/member/dto/MeResponse.java | 필드/의미 변경 금지(Constraint). 그대로. |
| shop-core/src/main/java/com/shop/shop/security/SecurityConfig.java | /me 전용 matcher 없음 -> 변경 없음. |
| JWT 계열(JwtTokenProvider/JwtAuthenticationFilter/RefreshTokenStore/JwtProperties) | 변경 없음(Constraint). |

### 2-C. 수정 (테스트 정리)

| 파일 | 작업 |
|---|---|
| shop-core/src/test/java/com/shop/shop/security/AuthRestControllerSecurityTest.java | auth/me 검증 테스트 제거: me_with_valid_bearer_token_returns_200(L149-159), me_without_token_returns_401_json(L161-167), me_with_tampered_token_returns_401_json(L169-176). logout_then_me_with_blacklisted_access_returns_401(L213-231)은 auth/me로 blacklist를 검증하므로 members/me로 대상 경로만 교체해 유지(또는 MemberRestControllerTest로 이관 — 5.4절). login/refresh/logout 성공·실패 테스트는 유지. 클래스 javadoc(L43-52)의 /me 시나리오 문구 정리. |
| shop-core/src/test/java/com/shop/shop/member/service/AuthServiceResponseTest.java | me_returns_me_response(L134-147) 제거. 미사용 import 정리: MeResponse(L7), UsernamePasswordAuthenticationToken(L19), Authentication(L20), SimpleGrantedAuthority(L21). login/refresh/logout 테스트(L67-132)는 유지. |
| shop-core/src/test/java/com/shop/shop/member/controller/MemberRestControllerTest.java | members/me 권한·인증 테스트 보강(5.3절): SELLER 200, ADMIN 200, 위조 토큰 401, blacklist access 401 추가. 기존 CONSUMER 200(L200-211)·비인증 401(L213-219)·signup 회귀(L107-232)는 유지. blacklist 검증 추가 시 FakeRefreshTokenStore/JwtTokenProvider 주입 필요(이미 Import(FakeRefreshTokenStore.class) 존재, JwtTokenProvider는 Autowired 존재). |
| shop-core/src/test/java/com/shop/shop/member/service/MemberServiceResponseTest.java | me_returns_me_response_using_principal_user_id(L63-80) 유지. 권장 단위 테스트 충족 확인. 필요 시 password 미노출 단언 보강(5.2절). |

### 2-D. 신규 파일
- 없음. (새 API/DTO/클래스 추가 금지)

---

## 3. 데이터 흐름 (GET /api/v1/members/me, 변경 없이 canonical 경로 확정)

    1) 클라이언트: GET /api/v1/members/me, Authorization: Bearer {accessToken}
    2) JwtAuthenticationFilter (SecurityConfig L81, UsernamePasswordAuthenticationFilter 앞):
       - Bearer access token 파싱·서명·만료 검증
       - blacklist(jti) 조회 — logout된 토큰이면 거부
       - 통과 시 SecurityContext에 Authentication 설정, principal = userId(long)
    3) SecurityFilterChain: securityMatcher(/api/v1/**) -> anyRequest().authenticated() 통과
    4) MemberRestController.me(Authentication) (L56-60): 비즈니스 로직 없이 위임
    5) MemberServiceResponse.me(Authentication) (L54-58):
       - long userId = (long) authentication.getPrincipal()
       - User user = memberService.getById(userId)        // 본인 식별 = principal userId
       - return MeResponse.from(user)                       // Entity 직접 노출 금지 -> DTO 변환
    6) 응답: 200 + MeResponse JSON { id, email, name, role }  // password/passwordHash 미포함

- principal 규약: userId(long) (006 JwtAuthenticationFilter 규약). 변경 없음.
- 소유권: principal userId 자체가 본인 식별이므로 별도 Repository 소유권 조회 불필요(api-authorization-rule: 소유권 검사는 Service 계층 도메인 규칙 — 여기선 principal=본인이 그 규칙). Controller에서 Repository 직접 조회·문자열 권한 비교 없음.

---

## 4. 예외 처리 전략 (ErrorResponse 포맷 유지 — error-response-rule)

/api/v1/** 는 REST 포맷(ErrorResponse JSON: status/error/message/path/timestamp)을 유지한다. View 에러 페이지로 새지 않는다.

| 상황 | 처리 주체 | 결과 |
|---|---|---|
| 비인증(토큰 없음) | RestAuthenticationEntryPoint (SecurityConfig L83) | 401 JSON |
| 위조 토큰 (서명 불일치) | JwtAuthenticationFilter -> EntryPoint | 401 JSON |
| 만료 토큰 | JwtAuthenticationFilter -> EntryPoint | 401 JSON |
| blacklist된 access token (logout 후) | JwtAuthenticationFilter(jti blacklist 조회) -> EntryPoint | 401 JSON |
| (제거 후) GET /api/v1/auth/me 유효 토큰 | 매핑 없음 -> DispatcherServlet | 404 (MeResponse 200 아님) |

- 모든 예외는 RuntimeException 상속 커스텀 예외(BusinessException/InvalidTokenException 등)로 변환되고 RestControllerAdvice 한 곳에서만 조립한다(기존 유지). Controller/ServiceResponse에서 ErrorResponse 직접 조립 없음.
- 응답 본문에 스택트레이스·SQL·Entity 비노출(기존 유지). MeResponse는 password/passwordHash/password_hash 미포함(record 구조로 보장).

---

## 5. 검증 방법

전체: ./gradlew test (shop-core) 통과. 통과 개수가 아니라 무엇을 검증했는지를 근거로 한다(testing-rule).

### 5.1 단위 — AuthServiceResponseTest (정리)
- [ ] me_returns_me_response 제거 후, login/refresh/logout 테스트만 남고 컴파일·통과.
- [ ] 미사용 import 제거로 경고 없이 빌드.

### 5.2 단위 — MemberServiceResponseTest (유지·보강)
- [ ] me가 principal userId((long)getPrincipal())를 추출해 MemberService.getById에 위임함을 검증(기존 L63-80).
- [ ] me가 MeResponse로 변환하고 password 관련 필드를 노출하지 않음 — MeResponse 필드(id/email/name/role)만 단언(이미 충족).

### 5.3 REST/Security — MemberRestControllerTest (보강, canonical 집중)
- [ ] GET /api/v1/members/me CONSUMER 유효 Bearer -> 200 + MeResponse (기존 유지)
- [ ] GET /api/v1/members/me SELLER 유효 Bearer -> 200 (신규)
- [ ] GET /api/v1/members/me ADMIN 유효 Bearer -> 200 (신규)
- [ ] GET /api/v1/members/me 비인증 -> 401 JSON (status==401, redirect 아님) (기존 유지)
- [ ] GET /api/v1/members/me 위조 토큰(Bearer invalid.jwt.token) -> 401 JSON (신규)
- [ ] GET /api/v1/members/me logout 후 blacklist access token -> 401 (신규: FakeRefreshTokenStore.storeRefresh + logout 후 동일 access로 접근)
- [ ] 응답에 password/passwordHash/password_hash 미포함 단언(선택 보강)
- 비고: SELLER/ADMIN 200 검증은 해당 role User stub + memberService.getById(id) mock + 해당 role authority access token 발급. RoleHierarchy(ADMIN>SELLER>CONSUMER)는 변경하지 않으며, members/me는 최소권한 CONSUMER이므로 상위 권한 모두 접근 가능해야 한다(api-authorization-rule).

### 5.4 REST/Security — AuthRestControllerSecurityTest (정리)
- [ ] auth/me 3개 테스트 제거(L149-176).
- [ ] blacklist 회귀(logout_then_me_with_blacklisted_access_returns_401)는 대상 경로를 members/me로 교체해 유지하거나 5.3절로 이관(중복 회피, 한 곳에만 둔다).
- [ ] login 성공 200 / 실패 401 유지 (L118-147)
- [ ] login Valid 검증 400 유지 (L233-243)
- [ ] refresh 200 유지 (L178-189)
- [ ] logout 후 refresh 401 유지 (L191-211)
- [ ] (선택 회귀) GET /api/v1/auth/me 유효 토큰 -> 더 이상 200 MeResponse 아님(404 단언) 1건.

### 5.5 회귀 — signup (member, 변경 없음 확인)
- [ ] POST /api/v1/members/signup public 201 유지 (MemberRestControllerTest L107-121, 222-232)
- [ ] signup 검증 실패 400 유지 (L142-182)
- [ ] signup 중복 이메일 409 유지 (L184-198)
- [ ] signup 응답 password 미노출 유지 (L123-140)

### 5.6 Acceptance Criteria 매핑
- 모든 Task Acceptance 항목(members/me 200/권한/401/blacklist, auth/me MeResponse 미반환, AuthRestController=login/refresh/logout만, AuthServiceResponse에 me 부재, login/refresh/logout/signup 회귀 통과, password 미노출)이 위 5.1~5.5로 커버됨을 구현 완료 시 체크.

---

## 6. 트레이드오프

- auth/me 제거 후 404 vs 405/명시적 제거 안내: alias·deprecation 응답을 남기지 않고 단순 매핑 삭제(404)를 택한다. Constraint가 호환 alias 금지를 명시하고, 내부 포트폴리오 단계라 외부 클라이언트 호환 부담이 없다. 트레이드오프: 기존에 auth/me를 호출하던 코드가 있다면 404를 받는다 -> grep으로 호출처가 AuthRestController.me 1곳뿐임을 확인해 위험을 제거했다.
- blacklist 회귀 테스트의 위치 이동: auth/me로 검증하던 blacklist 회귀를 members/me로 옮긴다. 트레이드오프: 테스트 diff가 커 보이지만, 검증 의미(logout된 access는 보호 자원 접근 불가)는 동일하게 보존되고 canonical 경로 기준으로 일원화된다.
- member 테스트로 권한 검증 집중: 권한(CONSUMER/SELLER/ADMIN) 매트릭스를 MemberRestControllerTest에 모은다. 트레이드오프: 해당 테스트 클래스가 다소 커지나, canonical API의 권한 계약을 한 파일에서 추적 가능해 api-authorization-rule의 추적 가능한 위치 명시에 부합한다.
- SecurityConfig 무변경 선택: /me 전용 matcher를 추가하지 않고 anyRequest().authenticated()에 의존한다. 트레이드오프: 경로별 권한이 SecurityConfig에 명시적으로 안 보이지만(테스트와 api-authorization 표로 추적), Task Constraint(RoleHierarchy/security 무변경)와 최소 변경 원칙에 부합한다.

---

## 완료 조건 (체크리스트)
- [ ] AuthRestController에서 /me 핸들러 제거 — login/refresh/logout만 남음
- [ ] AuthServiceResponse.me 제거 — login/refresh/logout 책임만 남음
- [ ] MemberRestController.me / MemberServiceResponse.me / MeResponse 무변경 유지
- [ ] SecurityConfig·JWT·RoleHierarchy·schema·이벤트·View 무변경
- [ ] auth/me 검증 테스트 제거, members/me 권한/인증/blacklist 테스트 보강
- [ ] ./gradlew test 전체 통과(5절 전 항목)

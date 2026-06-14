# 029 — shop-core 계정 self-service(비밀번호 변경·정보 수정·탈퇴 with View) 구현 plan

- 대상 Task: docs/tasks/backend/029-backend-shop-core-account-self-service-management-with-view.md
- Revision: docs/plans/revisions/backend/029-...-revision-1.md (설계 정정 4건+경미 2건, Task에 반영 완료)
- 패키지 루트: com.shop.shop (레포 shop-core)
- 작성일: 2026-06-14

## 구현 목표
로그인 사용자가 본인 계정을 self-service로 관리한다 — (1) 비밀번호 변경(현재 비번 확인 + 신규 정책 검증), (2) 정보 수정(name/phone), (3) 탈퇴(소프트 삭제). REST API + Thymeleaf 화면. 모든 동작은 principal 본인 한정(IDOR 불가). 이벤트/notification 무관.

## 작업 분담(중요)
- backend-implementor: Entity, MemberStatus enum, 도메인 메서드, V6 마이그레이션, DTO(Request/Form 클래스), @PasswordMatches 일반화, Repository(findActiveByEmail), AccountService, AccountServiceResponse, AccountFacade+구현, REST 컨트롤러, 탈퇴 차단 가드 3지점(MemberUserDetailsService / MemberService.authenticate / refresh 검증), SecurityConfig 경로, 전 backend 테스트.
- view-implementor: web/member/AccountViewController.java, templates/member/account.html, 모델 바인딩, flash/PRG, 비번 echo 차단, View 렌더링 테스트. (Form DTO 클래스 자체는 backend가 member/dto에 생성하지만, 컨트롤러 바인딩/clear 로직/템플릿/모델키는 view-implementor 담당.)

> 경계: View 폼 백킹 DTO(PasswordChangeForm/ProfileUpdateForm)는 member/dto에 두어 @PasswordMatches/@Size 재사용(007 SignupForm 선례 동일). 클래스 생성은 backend, 사용/clear/모델키는 view.

---

## 1. 설계 방식 및 이유

### 1.1 상태 표현 — MemberStatus enum 채택(nullable deletedAt 단독 불채택)
- 채택: MemberStatus { ACTIVE, WITHDRAWN } enum 컬럼 status(NOT NULL, DEFAULT ACTIVE) + 감사용 deleted_at timestamptz NULL(탈퇴 시각 기록).
- 이유:
  - 가드 분기(findActiveByEmail, authenticate, refresh)는 활성/탈퇴 의미가 본질. enum이 의도를 명시하고 @Enumerated(STRING)로 SellerApplicationStatus(V5) 선례와 일관.
  - nullable deletedAt 단독은 deletedAt IS NULL = 활성 암묵 규칙을 모든 조회에 강제해 누락 위험. 향후 상태(SUSPENDED 등) 확장 시 enum이 자연스럽다(단 본 Task는 2값만 — YAGNI).
  - deleted_at은 보조 감사 컬럼으로 병행. status가 권위, deleted_at은 시점 기록.
- DB 정합: V6에서 status varchar(20) NOT NULL DEFAULT ACTIVE CHECK (status IN (ACTIVE, WITHDRAWN)) + deleted_at timestamptz. Entity @Enumerated(STRING) + @Column(name=deleted_at). created/updated 트리거 패턴과 달리 deleted_at은 JPA가 직접 set(도메인 메서드에서 Instant.now()).

### 1.2 email 재사용 정책 — 재사용 불가(unique 유지, 탈퇴 행 보존) 채택
- 채택: 기존 email citext UNIQUE 제약을 그대로 유지. 탈퇴 행이 email을 점유하므로 동일 email 재가입 불가.
- 이유: 부분 유니크(WHERE status != WITHDRAWN)로 재사용을 허용하면 동일 email에 복수 user 행이 생겨 주문/감사 추적의 회원 식별이 모호해진다. email 마스킹/익명화/데이터 이전은 Task가 명시적으로 범위 밖. 재가입은 다른 email로 가능하므로 사용자 영향 제한적. V6에서 unique 제약 변경 없음(가장 단순/안전).

### 1.3 AccountService 분리(MemberService 확장 불채택)
- 채택: 신규 member/service/AccountService + member/service/AccountServiceResponse(REST 조합). 인증 가드(authenticate status 체크)는 기존 MemberService.authenticate 안에서 처리(호출 지점이 거기 — 별도 클래스 불가).
- 이유:
  - MemberService는 이미 인증/검색/권한변경으로 책임이 넓다. self-service 라이프사이클(changePassword/updateProfile/withdraw)을 분리해 단일 책임 유지. refresh 이중 분기/encode 부수효과를 한 곳에 모아 테스트 격리.
  - 단, findActiveByEmail/getById 조회와 가드(authenticate)는 기존 클래스가 이미 소유 → 중복 도입 금지. AccountService는 MemberRepository/PasswordEncoder/RefreshTokenStore를 직접 주입(MemberService 선례 패턴 그대로).

### 1.4 AccountFacade 설계(View 전용 published port)
- member/spi/AccountFacade(인터페이스, @NamedInterface(spi) 패키지) + member/service/AccountFacadeImpl(package-private, @Service).
- web은 AccountFacade만 참조 — member Entity/Service/Role enum 비참조(007/008 facade 선례).
- facade가 email→userId 해석(findActiveByEmail)과 표시용 scalar DTO 변환을 내부 처리. 변경 작업은 form scalar를 받아 AccountService에 위임.

### 1.5 본인 식별 — REST는 userId, View는 email→userId
- REST: principal == userId(long)(JwtAuthenticationFilter 규약). (long) authentication.getPrincipal() → AccountService에 userId 직접 전달(MemberServiceResponse.me 선례 동일).
- View: formLogin principal == email(String)(authentication.getName()). AccountFacade가 findActiveByEmail(email).getId()로 해석 후 위임. 활성 조회 이유: 화면 진입은 로그인 직후 본인 조회이며 탈퇴 행이 화면에 도달하면 안 됨(경미2).
- 경로에 타 회원 id 없음(/me, /account 셀프 경로) → IDOR 원천 차단.

---

## 2. 구성 요소(정확 경로/시그니처)

### [신규] member/domain/MemberStatus.java — backend
enum MemberStatus { ACTIVE, WITHDRAWN } — DB CHECK(ACTIVE, WITHDRAWN)와 1:1.

### [수정] member/domain/User.java — backend
추가 필드:
- @Enumerated(EnumType.STRING) @Column(name=status, nullable=false, length=20) private MemberStatus status;  // V6 DEFAULT ACTIVE
- @Column(name=deleted_at) private Instant deletedAt;  // null=활성, 탈퇴 시각

- of(...) 정적 팩토리: status = MemberStatus.ACTIVE 기본 세팅 추가(deletedAt=null). 기존 시그니처 유지(테스트/signup 호환).
- 도메인 메서드(Setter 금지, dirty checking):
  - changePassword(String newPasswordHash): this.passwordHash = newPasswordHash;
  - updateProfile(String name, String phone): this.name = name; this.phone = phone;
  - withdraw(): this.status = MemberStatus.WITHDRAWN; this.deletedAt = Instant.now();
  - isActive(): return this.status == MemberStatus.ACTIVE;
> 재탈퇴는 가드가 차단하므로 withdraw()는 단순 전이(멱등 — 추가 검증 불요, YAGNI).

### [수정] member/repository/MemberRepository.java — backend
신설(기존 findByEmail 무변경):
- @Query(select u from User u where u.email = :email and u.status = com.shop.shop.member.domain.MemberStatus.ACTIVE) Optional<User> findActiveByEmail(@Param(email) String email);
> citext 대소문자 무시는 = 비교가 DB 레벨에서 처리(findByEmail 선례 동일).

### [수정] member/dto/validation/PasswordMatches.java — backend
속성 추가(D 정정): String field() default password; String confirmField() default passwordConfirm; message 유지.
default 유지 → SignupRequest/SignupForm 무변경.

### [수정] member/dto/validation/PasswordMatchesValidator.java — backend
- initialize(PasswordMatches a)에서 this.field=a.field(); this.confirmField=a.confirmField(); 저장.
- extractField(value, field)/extractField(value, confirmField)로 비교.
- 위반 보고 노드: addPropertyNode(confirmField)(하드코딩 passwordConfirm → confirmField 값으로).
- getter/record accessor 추출 로직 그대로 재사용.

### [신규 DTO] member/dto/ — backend(클래스 생성), view(바인딩 사용)
- PasswordChangeRequest(record, REST): 클래스 레벨 @PasswordMatches(field=newPassword, confirmField=newPasswordConfirm). 필드: @NotBlank String currentPassword, @NotBlank @Size(min=MemberPasswordPolicy.MIN_LENGTH) String newPassword, @NotBlank String newPasswordConfirm.
- PasswordChangeForm(class, View, @Getter/@Setter/@NoArgsConstructor): 동일 필드/검증 + @PasswordMatches(field=newPassword, confirmField=newPasswordConfirm).
- ProfileUpdateRequest(record, REST): @NotBlank String name, String phone(optional, 007 규칙 계승).
- ProfileUpdateForm(class, View): 동일.
- 탈퇴는 별도 서버 입력 DTO 불요(확인 체크박스는 View UX — 무바디 POST + CSRF). 필요 시 WithdrawForm은 View에서만.

### [신규] member/service/AccountService.java — backend
주입: MemberRepository, PasswordEncoder, RefreshTokenStore. @Slf4j @Service @RequiredArgsConstructor.
- @Transactional void changePassword(long userId, String currentPassword, String newPassword)
- @Transactional void updateProfile(long userId, String name, String phone)
- @Transactional void withdraw(long userId)

- changePassword: findById→없으면 MemberNotFoundException; passwordEncoder.matches(current, hash) 실패 시 거부(4장); user.changePassword(encode(newPassword)); refresh 이중 분기 무효화. 로그 userId만.
- updateProfile: findById; user.updateProfile(name, normalizePhone(phone)). refresh 무효화 없음(인증 영향 없음). email/role/password 불변.
- withdraw: findById; user.withdraw(); refresh 이중 분기 무효화. 물리 delete 호출 없음.
- refresh 무효화 헬퍼: changeRole의 이중 분기(TransactionSynchronizationManager.isSynchronizationActive() → afterCommit / else 직접호출) 그대로 복제(경미1).

### [수정] member/service/MemberService.java — backend
- authenticate(email, raw)에 status 가드 추가(C 정정): findByEmail→matches 후, if (!user.isActive()) throw new InvalidCredentialsException();(계정 열거 방지 위해 동일 메시지). UserDetails 미경유 경로 보강. 기존 findByEmail 무변경.
- refresh 재발급 가드는 AuthServiceResponse.refresh에 1줄 추가(3장 참조).

### [신규] member/service/AccountServiceResponse.java — backend(REST 조합)
주입: AccountService. @Service @RequiredArgsConstructor. View/Scheduler 미사용(architecture-rule).
- void changePassword(Authentication auth, PasswordChangeRequest req)  // userId=(long)auth.getPrincipal()
- void updateProfile(Authentication auth, ProfileUpdateRequest req)
- void withdraw(Authentication auth)
각각 principal→userId 추출 후 AccountService 위임. 반환 없음(REST는 204 — 비번/해시 비노출).

### [신규] member/spi/AccountFacade.java + member/service/AccountFacadeImpl.java — backend
인터페이스(scalar/DTO만):
- AccountInfo getAccountInfo(String email);            // 표시용 — email/name/phone (해시/role/토큰 비노출)
- void changePassword(String email, String currentPassword, String newPassword);
- void updateProfile(String email, String name, String phone);
- void withdraw(String email);
- AccountInfo(record, member/dto): email, name, phone(scalar만).
- 구현체: findActiveByEmail(email).getId()로 userId 해석 후 AccountService 위임. getAccountInfo는 활성 조회 후 DTO 변환.

### [신규] member/controller/MemberAccountRestController.java — backend
@RestController @RequestMapping(/api/v1/members) @RequiredArgsConstructor. 주입 AccountServiceResponse.
- @PatchMapping(/me/password) ResponseEntity<Void> changePassword(Authentication auth, @Valid @RequestBody PasswordChangeRequest req)  // 204
- @PatchMapping(/me) ResponseEntity<Void> updateProfile(Authentication auth, @Valid @RequestBody ProfileUpdateRequest req)  // 204
- @DeleteMapping(/me) ResponseEntity<Void> withdraw(Authentication auth)  // 204
> 기존 MemberRestController(/signup, GET /me)와 같은 base path이나 별 클래스로 분리(self-service 응집). GET /me(MeResponse)는 MemberRestController에 남김.

### [신규] web/member/AccountViewController.java — view-implementor
@Controller @RequestMapping(/account) @RequiredArgsConstructor @Slf4j. 주입 AccountFacade.
- GET 빈경로 → 모델 accountInfo(AccountInfo) + passwordForm(new) + profileForm(name/phone 프리필) → view member/account.
- POST /password @Valid @ModelAttribute(passwordForm) PasswordChangeForm + BindingResult → 검증/현재비번 실패 재렌더(비번 clear), 성공 redirect:/account?password + flash.
- POST /profile @Valid ProfileUpdateForm → 성공 redirect:/account?profile + flash.
- POST /withdraw → 순서 고정: facade.withdraw(email) 성공 → SecurityContextLogoutHandler.logout(request, response, authentication)(현재 HTTP 세션 무효화, 기본 invalidateHttpSession=true) → redirect:/login?withdraw. 완료 안내는 로그인 화면에서 쿼리파라미터(param.withdraw)로 표시 — flash 사용 금지(세션 무효화로 flash attribute가 소실되므로). 탈퇴 경로에서만 flash 미사용(비번/정보 수정 PRG flash는 유지).
  - 근거(코드 확인): 홈 `/`는 보호 경로(HomeViewController 주석 "보호 경로", SecurityConfig viewChain anyRequest().authenticated()). 세션 무효화 후 redirect:/ 하면 formLogin이 302→/login으로 보내 실질 귀결이 /login이고, 세션 기반 flash는 이미 소실된다. 따라서 명시적으로 /login?withdraw로 redirect한다. (Task Backend-View Contract "탈퇴 제출 → 로그아웃 + redirect /"의 위반이 아니라 보호 경로+세션 무효화 특성에 따른 구체화이며, failureUrl=/login?error·logoutSuccessUrl=/login?logout 쿼리파라미터 안내 선례와 동일 방식.)
- 모델 키: accountInfo(예약어 회피), passwordForm/profileForm, flash 기존 fragment(비번/정보 수정 PRG에 한함).

### [신규] templates/member/account.html — view-implementor
- email/name/phone 표시(비번/해시 비노출), 비번 변경 폼/정보 수정 폼/탈퇴 폼(확인 UX), CSRF 히든 자동(th:action), flash/message fragment/layout 재사용.

### [신규] db/migration/V6__users_account_lifecycle.sql — backend
- ALTER TABLE users ADD COLUMN status varchar(20) NOT NULL DEFAULT ACTIVE CHECK (status IN (ACTIVE, WITHDRAWN));  // 실제 SQL은 작은따옴표로 리터럴 표기
- ALTER TABLE users ADD COLUMN deleted_at timestamptz;
- email unique 제약 변경 없음(재사용 불가 정책 — 1.2).
- status 인덱스 추가 불요(YAGNI — 활성 조회는 email unique로 단건).
V1~V5 무변경, Hibernate validate 정합(status NOT NULL/length 20, deleted_at nullable).

### [수정] security/SecurityConfig.java — backend
- REST 체인: /api/v1/members/me/** 는 anyRequest().authenticated()가 이미 커버(별 matcher 불요). 의도 명시 주석만 권장.
- View 체인: /account, /account/** → .authenticated() 명시 matcher 추가(anyRequest 앞). 미인증은 formLogin 302→/login.
- JwtAuthenticationFilter 무변경(stateless 유지 — A 정정).

### [재사용/무변경] RedisRefreshTokenStore/RedisProperties, BCryptPasswordEncoder, MemberPasswordPolicy, BusinessException, RestExceptionHandler/ViewExceptionHandler, V1~V5, event-catalog 5절, notification 전부, MemberRestController(GET /me).

---

## 3. 데이터 흐름

### 3-1. 비밀번호 변경
- REST PATCH /api/v1/members/me/password: Filter 인증(principal=userId) → @Valid(NotBlank/Size/@PasswordMatches confirm) → MemberAccountRestController → AccountServiceResponse.changePassword(auth, req)(userId 추출) → AccountService.changePassword(userId, current, new) → findById → matches(current, hash) 검증 → encode(new) → user.changePassword(newHash)(dirty UPDATE) → refresh 무효화 이중 분기(afterCommit 또는 직접) → 커밋 → 204(빈 바디).
- View POST /account/password: formLogin 세션(principal=email) → @Valid PasswordChangeForm+BindingResult → 실패 시 비번 clear 재렌더 → AccountFacade.changePassword(email, current, new) → findActiveByEmail(email).getId() → AccountService(동일) → 성공 redirect:/account?password + flash. (View는 refresh 미발급 → 무효화는 View 세션 무영향, 현재 세션 유지.)

### 3-2. 정보 수정
- REST PATCH /api/v1/members/me: 인증 → @Valid ProfileUpdateRequest(name 필수) → ServiceResponse → AccountService.updateProfile(userId, name, phone) → user.updateProfile(name, normalizePhone(phone)) → 커밋 → 204. refresh 무효화 없음(인증 영향 없음). email/role/password 불변.
- View POST /account/profile: email→userId → 동일 → redirect:/account?profile + flash.

### 3-3. 탈퇴(소프트 삭제)
- REST DELETE /api/v1/members/me: 인증 → ServiceResponse → AccountService.withdraw(userId) → findById → user.withdraw()(status=WITHDRAWN, deletedAt=now) → refresh 무효화 이중 분기 → 커밋 → 204. 물리 delete 없음.
- View POST /account/withdraw: email→userId → AccountFacade.withdraw 성공 → SecurityContextLogoutHandler.logout(req, res, auth)(현재 HTTP 세션 무효화) → redirect:/login?withdraw(완료 안내는 param.withdraw로 표시 — flash는 세션 무효화로 소실되므로 미사용). 보호 경로 `/` + 세션 무효화 특성상 redirect:/는 실질 /login으로 귀결되므로 명시적으로 /login?withdraw로 보낸다(Task 계약 구체화).

### 3-4. 탈퇴 후 차단(경로별 독립 가드 3지점 — C 정정)
1. View 로그인(MemberUserDetailsService.loadUserByUsername): 탈퇴 사용자 거부 — findActiveByEmail 사용 또는 조회 후 if(!user.isActive()) throw new UsernameNotFoundException(...). (권장: 활성 조회로 단순화. enabled 단독 의존 금지.)
2. REST 로그인(MemberService.authenticate): matches 통과 후 if(!user.isActive()) throw new InvalidCredentialsException();(UserDetails 미경유 → enabled 무효이므로 직접 가드).
3. refresh 재발급(AuthServiceResponse.refresh): matchesRefresh가 탈퇴 시 deleteRefresh로 hash 부재 → 자연 false. 의도 명시로 getById 후 if(!user.isActive()) throw new InvalidTokenException(...) 1줄 추가.
- 기존 access/HTTP 세션: 즉시 무효화 범위 밖(A 정정) — access는 TTL 30분 이내 후 만료, View 타 기기 세션은 SessionRegistry 미도입. JwtAuthenticationFilter 무변경.
- 잔여 access로 self-service 호출 가능 한계(의도 범위 내): 탈퇴 후 잔여 access TTL(≤30분) 동안 self-service 변경 요청(PATCH /me/password, PATCH /me, DELETE /me)은 status 가드 부재로 통과한다(A 정정의 access TTL 위임과 일관 — 무효화는 신규 로그인/refresh 재발급 경로에 한정). AccountService에 isActive 가드를 추가하지 않는 이유: (1) 재활성화 벡터 부재로 안전 — withdraw는 멱등(이미 WITHDRAWN을 다시 WITHDRAWN으로), changePassword/updateProfile는 status를 건드리지 않아 어떤 self-service 경로로도 ACTIVE 복귀 불가, (2) 과설계 회피(YAGNI) — 모든 self-service 메서드에 가드를 깔면 access TTL 위임 결정(A)과 모순되고 새 가드 추가는 본 plan 제약 밖. access 만료 후에는 신규 인증 자체가 가드 3지점에서 차단된다.

---

## 4. 예외 처리 전략

| 상황 | 처리 | REST | View |
|---|---|---|---|
| 현재 비번 불일치 | AccountService 거부 | 400 ErrorResponse JSON | 재렌더 + bindingResult.rejectValue(currentPassword, ...) + 비번 clear |
| confirm 불일치 | @PasswordMatches(field=newPassword, confirmField=newPasswordConfirm) | 400(필드 위반) | 재렌더(newPasswordConfirm 필드 에러) + 비번 clear |
| 신규 비번 정책 위반(8자 미만) | @Size(min=MIN_LENGTH) | 400 | 재렌더 + 비번 clear |
| name 누락 | @NotBlank | 400 | 재렌더 |
| 탈퇴 사용자 로그인/refresh | 가드 3지점 | 401(InvalidCredentials/InvalidToken) | formLogin 실패(UsernameNotFound → /login?error) |
| 사용자 부재(이론상) | MemberNotFoundException | 404 | facade 활성 조회 실패 → 처리(로그인 직후라 사실상 불가) |
| IDOR(타인 변경) | 경로에 타 id 없음 → 구조적 불가 | — | — |
| 미인증 접근 | SecurityConfig | 401 JSON(RestAuthenticationEntryPoint) | 302 → /login |

- 신규 예외 클래스 도입 여부: 현재 비번 불일치는 기존 BusinessException(현재 비밀번호가 일치하지 않습니다., HttpStatus.BAD_REQUEST) 재사용(error-response-rule: BusinessException이 status 보유, RestExceptionHandler가 변환). 전용 예외(InvalidCurrentPasswordException 등) 추가하지 않음(YAGNI — 메시지+400으로 충분). View에서 currentPassword 필드 에러로 표현하려면 컨트롤러가 BusinessException catch 후 rejectValue(SignupViewController의 DuplicateEmail→rejectValue 선례 동일).
- 탈퇴 후 로그인 거부는 계정 열거 방지를 위해 없음/불일치/탈퇴 모두 동일 메시지(InvalidCredentials)로 통일(authenticate 선례 주석).
- error-response-rule 준수: REST는 @RestControllerAdvice(RestExceptionHandler) 단일 변환, View는 재렌더/flash. 컨트롤러/서비스에서 ErrorResponse 직접 조립 금지.
- 비번 원문/해시/토큰/Redis 상태는 응답/로그/View에 비노출. 로그는 userId만.

---

## 5. 검증 방법(Task Test 섹션 분해)

### 5-1. 단위(Mockito)
- AccountServiceTest:
  - changePassword: 현재 비번 불일치 → 예외, changePassword 미호출, deleteRefresh 미호출.
  - changePassword 성공: encode(newPassword) 호출, user.changePassword(newHash), 동기화 비활성 컨텍스트에서 deleteRefresh(userId) 직접 호출 분기 검증.
  - updateProfile: name/phone만 반영(email/role/passwordHash 불변), deleteRefresh 미호출.
  - withdraw: status=WITHDRAWN 전이 + deletedAt 세팅 + deleteRefresh 호출, memberRepository.delete* 미호출(물리 delete 없음).
- UserTest(도메인): changePassword/updateProfile/withdraw/isActive 단언.
- PasswordMatchesValidatorTest(또는 AccountValidationTest): @PasswordMatches(field=newPassword, confirmField=newPasswordConfirm)에서 confirm 불일치가 newPasswordConfirm 필드 위반으로 보고됨(일반화 후 무음 통과 회귀 차단). default(password/passwordConfirm)도 회귀 그린.

### 5-2. 슬라이스/통합(@DataJpaTest 또는 Testcontainers)
- MemberRepositoryAccountTest: V6 적용 + validate 정합(status/deleted_at). findActiveByEmail — ACTIVE 단건 반환, WITHDRAWN 미반환. 소프트 삭제 후 findByEmail은 여전히 반환(무변경 확인), findActiveByEmail은 empty.
- email 재사용 불가: 탈퇴 행 존재 시 동일 email INSERT → unique 위반(정책 채택 확인, 선택적).

### 5-3. Security/REST(MockMvc)
- MemberAccountRestControllerSecurityTest(또는 통합):
  - PATCH /me/password, PATCH /me, DELETE /me — 인증 본인 성공(204), 비인증 401.
  - 비번 변경 후 refresh 무효화(통합: deleteRefresh 호출 또는 이후 refresh 재발급 실패).
  - 탈퇴 후 REST 재로그인(authenticate) 거부 + refresh 재발급 거부. 기존 access 즉시 차단은 비요구(TTL 위임 — 단언하지 않음).
  - 셀프 경로만 존재(타 id 받는 경로 부재) 확인.

### 5-4. View 렌더링
- AccountViewControllerTest(@WebMvcTest + facade mock 또는 통합):
  - GET /account 렌더(비번/해시 비노출, accountInfo/passwordForm/profileForm 모델).
  - 비번/정보 폼 성공 → redirect + flash(PRG).
  - 비번 검증 실패 재렌더 → 비밀번호 echo 금지(필드 null).
  - 탈퇴 → 세션 무효화(SecurityContextLogoutHandler 호출) + redirect:/login?withdraw(flash 미단언 — 세션 무효화로 소실되므로 미사용; 안내는 param.withdraw로 검증).
  - (조건부 가시성은 testing-rule상 필요 시 E2E — 기본은 MockMvc.)

### 5-5. 회귀 + 게이트
- 006 로그인/로그아웃, 007 가입(@PasswordMatches default 무변경), 008 admin role(이중 분기 동일) 그린.
- 검증 게이트: ./gradlew test 풀 그린(verification-gate-rule).

---

## 6. 트레이드오프

| 결정 | 선택 | 대안 | 사유 |
|---|---|---|---|
| 상태 표현 | MemberStatus enum + deleted_at 병행 | nullable deletedAt 단독 / boolean withdrawn | enum이 가드 의도 명시/V5 선례 일관/확장 여지. deletedAt 단독은 조회마다 IS NULL 강제로 누락 위험. 2값만 — 과확장 안 함 |
| email 재사용 | 재사용 불가(unique 유지) | 부분 유니크 + 마스킹/이전 | 단순/비파괴, 회원 식별 모호성 차단. 익명화/이전은 범위 밖. 재가입은 타 email 가능 |
| access 즉시 무효화 | 보류(TTL 30분 이내 위임) | jti 블랙리스트/per-request DB 조회/token-version | changeRole가 이미 과설계 보류 결정. stateless 파괴/전 요청 DB 조회 비용. A 정정 준수 |
| AccountService 분리 | 분리 | MemberService 확장 | 단일 책임/테스트 격리. 단 가드(authenticate)/조회는 기존 클래스 소유 → 중복 도입 회피 |
| SessionRegistry | 미도입 | Spring Session + maximumSessions | View 타 기기 세션 강제 만료는 새 정책 설계 → 새 정책 금지 제약/범위 밖. 현재 세션 종료는 /logout(탈퇴 흐름 포함) |
| refresh 무효화 | 이중 분기(afterCommit+직접) | afterCommit 단독 | 비트랜잭션 테스트에서 삭제 누락 방지(경미1). changeRole 선례 그대로 |
| findActiveByEmail | 신설 | findByEmail 변경 | findByEmail은 admin 검색 등 공유 — 시그니처/시맨틱 변경 시 회귀(경미2) |
| 현재비번 불일치 예외 | BusinessException 재사용 | 전용 예외 클래스 | YAGNI — 메시지+400으로 충분. View는 catch→rejectValue(SignupView 선례) |

---

## 완료 조건
- [ ] 현재 비번 정확 입력 시에만 변경, 불일치 거부. 변경 후 BCrypt 해시 갱신 + refresh 무효화.
- [ ] name/phone만 수정(email/role/password 불변).
- [ ] 탈퇴 시 status=WITHDRAWN + deletedAt, 신규 로그인(View/REST)/refresh 재발급 차단, 물리 삭제 없음. access는 TTL 위임.
- [ ] 모든 동작 principal 본인만(타 id 경로 부재), 미인증 401/302.
- [ ] 응답/View에 해시/토큰/Redis 상태 비노출.
- [ ] V6가 V1~V5 무수정으로 status/deleted_at 추가, Hibernate validate 정합.
- [ ] @PasswordMatches 일반화 — default 무변경 + newPassword/newPasswordConfirm 위반 보고.
- [ ] 이벤트/notification 무변경.
- [ ] ./gradlew test 풀 그린.

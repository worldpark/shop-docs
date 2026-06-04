# 007. shop-core 회원가입 + 회원가입 화면 — 구현 Plan

> 영역: backend + view (REST 회원가입/내 정보 API + Thymeleaf 회원가입 화면 + member 도메인 회원가입 로직 + DuplicateEmailException + Security 공개경로 추가 + 테스트)
> 대상 프로젝트: shop-core (member 도메인 + security 공개경로 + 템플릿). notification 무관, 이벤트 계약 변경 없음.
> 작성일: 2026-06-03
> 상태: plan only (코드 변경 없음)
> 선행: Task 006(JWT 로그인) 산출물 재사용 — `User`/`Role`/`MemberRepository`/`MemberService`/`MeResponse`/`SecurityConfig`/`BusinessException` 계열 위에 가산적으로 구축한다.

---

## 구현 목표

`shop-core` `member` 모듈에 일반 사용자(`CONSUMER`) 회원가입을 **REST API**(`POST /api/v1/members/signup`)와 **Thymeleaf 화면**(`GET/POST /signup`)으로 구현하고, JWT 인증 사용자 본인 정보 조회 API(`GET /api/v1/members/me`)를 추가한다. 도메인 회원가입 로직(이메일 중복 검증·BCrypt 해시·기본 role `CONSUMER`·저장)은 `MemberService.signup(...)`에 단일 소유하고 REST/View 진입점이 공유한다. 회원가입 성공 시 화면은 `/login?signup`으로 이동하고 로그인 화면에 안내 메시지·회원가입 링크가 노출되어 가입→로그인 흐름이 완성된다.

---

## 영향 범위

### 신규 파일 (main — Java)

**member 도메인**
- `shop-core/src/main/java/com/shop/shop/member/dto/SignupRequest.java` — REST 회원가입 요청 DTO(`record`, Bean Validation)
- `shop-core/src/main/java/com/shop/shop/member/dto/SignupResponse.java` — REST 회원가입 응답 DTO(`record`, `from(User)`)
- `shop-core/src/main/java/com/shop/shop/member/dto/SignupForm.java` — **View 폼 백킹 객체(가변 클래스, Lombok getter/setter)** + Bean Validation
- `shop-core/src/main/java/com/shop/shop/member/dto/validation/PasswordMatches.java` — 비밀번호 일치 교차검증 제약 애너테이션(채택 시, §1.2)
- `shop-core/src/main/java/com/shop/shop/member/dto/validation/PasswordMatchesValidator.java` — 위 제약의 `ConstraintValidator`(SignupRequest·SignupForm 공용)
- `shop-core/src/main/java/com/shop/shop/member/service/MemberServiceResponse.java` — REST 응답 조합 전용(ServiceResponse 레이어) — signup/me
- `shop-core/src/main/java/com/shop/shop/member/controller/MemberRestController.java` — `/api/v1/members/**` REST 진입점(signup·me)
- `shop-core/src/main/java/com/shop/shop/member/controller/MemberSignupViewController.java` — `@Controller` GET/POST `/signup` 진입점

**common.exception**
- `shop-core/src/main/java/com/shop/shop/common/exception/DuplicateEmailException.java` — 이메일 중복(409), `BusinessException` 상속

**설정(선택, §1.2 정책값 추적)**
- `shop-core/src/main/java/com/shop/shop/member/MemberPasswordPolicy.java` — 비밀번호 최소 길이 상수(또는 `@ConfigurationProperties`) — 기본은 **상수 클래스**(YAGNI)

### 신규 파일 (main — 템플릿)
- `shop-core/src/main/resources/templates/member/signup.html` — 회원가입 화면(view name `member/signup`, layout 적용)

### 신규 파일 (test)
- `shop-core/src/test/java/com/shop/shop/member/service/MemberServiceSignupTest.java` — signup 단위(성공/중복/해시/기본 role) (Mockito)
- `shop-core/src/test/java/com/shop/shop/member/service/MemberServiceResponseTest.java` — signup/me 조합 단위(fake/mock)
- `shop-core/src/test/java/com/shop/shop/member/controller/MemberRestControllerTest.java` — REST MockMvc(signup 201/400/409, me 200/401)
- `shop-core/src/test/java/com/shop/shop/member/controller/MemberSignupViewControllerTest.java` — View MockMvc(GET 200 렌더·CSRF, POST 성공 redirect, POST 실패 재렌더)
- `shop-core/src/test/java/com/shop/shop/member/dto/SignupValidationTest.java` — Bean Validation 단위(이메일 형식·최소 길이·비번 불일치) (선택, Validator 직접)
- `shop-core/src/test/java/com/shop/shop/member/MemberWiringTest.java` — **운영 배선 회귀**(fake 미import, `MemberRestController`/`MemberServiceResponse`/`MemberSignupViewController` 빈 등록 단언) (§5, P1/testing-rule)

### 수정 파일
- `shop-core/src/main/java/com/shop/shop/member/repository/MemberRepository.java` — `boolean existsByEmail(String email)` 추가
- `shop-core/src/main/java/com/shop/shop/member/service/MemberService.java` — `User signup(...)` 추가(`@Transactional` 쓰기)
- `shop-core/src/main/java/com/shop/shop/security/SecurityConfig.java` — REST 체인 `POST /api/v1/members/signup` permitAll, View 체인 `GET/POST /signup` permitAll
- `shop-core/src/main/resources/templates/auth/login.html` — `param.signup` 성공 메시지 + 회원가입 링크(`GET /signup`) 추가(기존 보존 계약 비파괴)
- `shop-core/src/test/java/com/shop/shop/view/LayoutRenderingTest.java` — (선택) `/signup` 렌더·login `param.signup` 검증을 신규 View 테스트로 분리(기존 T1~T3 비파괴, 본 파일 미수정이 기본)

### 마이그레이션 — **불필요 (신규 SQL 없음)**
- `users.role` CHECK는 **Task 006의 `V2__users_role_hierarchy.sql`** 에서 이미 `ADMIN/SELLER/CONSUMER`로 정합되었고 `database_design.md §4.1`도 갱신됨. 회원가입 기본 role `CONSUMER`는 V2 DEFAULT/CHECK와 일치 → **V3 마이그레이션 불필요**(Constraint "role CHECK 정합" 충족). 컬럼/제약 변경 없음.

### 범위 밖 (명시적 제외 — YAGNI)
- `SELLER`/`ADMIN` 가입 public 노출, 관리자 권한 변경 API
- Kakao OAuth2/소셜 로그인/비밀번호 없는 계정/이메일 인증(verification) 흐름
- 비밀번호 재설정·변경, 회원 정보 수정/탈퇴
- 약관 동의·중복확인 AJAX·rate limit·CAPTCHA(public API 입력검증/비밀번호 미노출만 본 Task 적용)
- 회원가입 도메인 이벤트 발행(이벤트 계약 변경 금지 — Welcome 알림 등은 후속)
- `auth/me`(006 산출)와 `members/me` 통합/제거(§1.7)

---

## 1. 설계 방식 및 이유

### 1.1 View 폼 백킹 객체(SignupForm)는 가변 클래스, REST 요청 DTO(SignupRequest)는 record
- **결정**: `SignupForm` = Lombok `@Getter @Setter`(+`@NoArgsConstructor`)를 가진 **가변 POJO**. `SignupRequest`/`SignupResponse` = Java `record`.
- 근거:
  - View는 `th:object="${signupForm}"` + `th:field="*{email}"`로 바인딩하고, **검증 실패 재렌더링 시 입력값을 다시 채워야** 한다(Acceptance: "유효하지 않은 폼 제출 시 입력값과 검증 메시지 표시"). Spring MVC `@ModelAttribute` 데이터 바인딩은 기본 생성자 + setter(JavaBean) 경로가 가장 안정적이고, `BindingResult`/`th:field`의 프로퍼티 접근·재바인딩과 호환된다. record는 불변·생성자 전용이라 부분 바인딩/재렌더 경로에서 취약(특히 검증 실패 시 필드 단위 echo).
  - REST는 `@RequestBody`로 한 번에 역직렬화하고 응답에 echo가 없으므로 `record`가 간결·불변으로 적합(006 DTO 컨벤션과 일치).
- 트레이드오프(§6): 폼/요청 DTO 두 타입 존재 → 약간의 중복. 그러나 진입점별 제약(재렌더 vs 불변)이 달라 분리가 정당. 도메인 로직은 `MemberService.signup`이 단일 소유하므로 중복은 DTO 표면에 한정.

### 1.2 비밀번호 정책 검증 위치 — Bean Validation + 교차검증 커스텀 제약
- 단일 필드 검증은 **Bean Validation 애너테이션**으로 선언: `@Email`(형식), `@NotBlank`(필수), `@Size(min=…)`(최소 길이), `name @NotBlank`, `phone`은 optional(미입력 허용 — `@Pattern`은 과설계로 미적용, 빈 문자열→null 정규화는 Service에서 트림 처리).
- **password == passwordConfirm 교차검증**: **클래스 레벨 커스텀 제약 `@PasswordMatches`** 채택. 근거: REST(`SignupRequest`)·View(`SignupForm`) **양쪽에서 동일 규칙을 선언적으로 재사용**하고, 위반을 `BindingResult`/`MethodArgumentNotValidException`이 일관되게 잡아 View 재렌더·REST 400으로 자연 변환된다. Validator는 두 타입을 모두 처리하도록 인터페이스(또는 reflection 최소화 위해 공통 접근 메서드)로 구현. 컨트롤러 if-검증 대비: 비즈니스 로직을 컨트롤러에 넣지 않고(Constraint) 검증 계층에 위치.
  - 과설계 경계: 교차검증은 **이 1건**만 커스텀 제약으로 둔다(검증 프레임워크 일반화·다중 제약 조합기 등은 도입 안 함).
- **정책 세부값(최소 길이)** 추적: `MemberPasswordPolicy.MIN_LENGTH = 8`(기본 8) **상수 클래스**로 둔다. `@Size(min=…)`은 컴파일 상수가 필요하므로 상수 참조. 근거: 환경별 가변 요구가 없어 `@ConfigurationProperties`는 과함(YAGNI). 후속에 환경별 정책이 필요해지면 properties로 승격. 본 Task는 "상수 또는 설정으로 추적 가능"(Requirement) 중 상수 채택을 plan에 명시.
- **구현 시 확인**: 교차검증 Validator가 SignupRequest(record)·SignupForm(class) 두 타입에서 동작하도록 공통 접근 방식(예: 두 타입에 동일 시그니처 `password()/passwordConfirm()` 또는 getter) 정합 — backend-implementor가 두 DTO 동시 작성 시 메서드명 일치.

### 1.3 비밀번호 원문 미노출 (DB/로그/응답/View 모델)
- DB: `User.passwordHash`에 **BCrypt 해시만** 저장(`PasswordEncoder.encode`). 원문 컬럼 없음.
- 응답: `SignupResponse`/`MeResponse`에 password/passwordHash 필드 **부재**(memberId/email/name/role만). Entity 직접 반환 금지(DTO 변환).
- 로그: `MemberService.signup` 성공/실패 로그는 **이메일 마스킹 또는 userId 위주**, password 원문/해시 로그 금지(006 `authenticate` 컨벤션 계승). 예: `log.info("signup 완료: userId={}", user.getId())`.
- **재렌더 시 비밀번호 echo 금지**: 검증 실패로 `member/signup` 재렌더링 시 `password`/`passwordConfirm` 값을 폼에 다시 채우지 않는다. 구현: (a) ViewController가 실패 응답 직전 `signupForm.setPassword(null); signupForm.setPasswordConfirm(null)` 처리(이메일/name/phone은 유지), **또는** (b) 템플릿의 password input에 `th:field` 대신 `name`만 두고 `value`를 바인딩하지 않음. **기본: (a)** (BindingResult와 `th:field` 일관 유지하면서 값만 비움). 이 결정은 §8 인터페이스 계약에 명시(두 에이전트 정합).

### 1.4 이메일 중복 처리 — 사전 체크(existsByEmail) + DB unique 2중, 진입점별 표현 분리
- 도메인: `MemberService.signup`이 `memberRepository.existsByEmail(email)` → 존재 시 `DuplicateEmailException`(409) throw. 저장은 `User.of(email, hash, name, phone, Role.CONSUMER)` → `save`.
- 동시성 경합: 사전 체크와 INSERT 사이 경합은 **DB `users.email` UNIQUE 제약**(V1 정의)이 최종 방어. 경합으로 `DataIntegrityViolationException` 발생 시 `MemberService`가 이를 `DuplicateEmailException`으로 **변환**(catch → throw)한다. 근거: "모든 예외는 RuntimeException 상속 커스텀 예외로 변환"(공통 규칙) + 이중 안전. 과설계 경계: 재시도/락은 도입 안 함(예외 변환만).
- 진입점별 표현:
  - **REST**: `DuplicateEmailException`(409) → `RestExceptionHandler`가 `ErrorResponse` JSON 변환(error-response-rule, 상태충돌 409 매핑).
  - **View**: ViewController가 `MemberService.signup` 호출을 `try/catch(DuplicateEmailException)`로 감싸 `bindingResult.rejectValue("email", "duplicate", "이미 사용 중인 이메일입니다.")` 후 `member/signup` **재렌더링**(JSON 금지 — Constraint). REST 인증/인가 실패를 View redirect와 섞지 않음(006 체인 분리 유지).

### 1.5 레이어 분리 (REST vs View, 도메인 로직 단일 소유)
- **공통 도메인 로직**은 `MemberService.signup`에 둔다: 입력 정규화(트림) → `existsByEmail` 중복 검사 → `passwordEncoder.encode` → `User.of(..., Role.CONSUMER)` 저장 → `User` 반환. **기본 role `CONSUMER` 강제**(요청에서 role을 받지 않음 — SELLER/ADMIN public 가입 차단, Constraint). REST/View 두 진입점이 동일 메서드 공유.
- **REST 레이어**: `MemberRestController(@RestController, /api/v1/members)` → `MemberServiceResponse`(ServiceResponse, REST 전용) → `MemberService` → `MemberRepository`.
  - `POST /signup`: `@Valid @RequestBody SignupRequest` → `memberServiceResponse.signup(req)` → `SignupResponse` + **201 Created**(`ResponseEntity.status(CREATED)`, 선택 `Location: /api/v1/members/{id}`).
  - `GET /me`: 인증 필요 → `memberServiceResponse.me(authentication)` → `MeResponse`(200). Controller 비즈니스 로직 금지.
- **View 레이어**: `MemberSignupViewController(@Controller)` → `MemberService` 직접 호출(ServiceResponse 미사용 — architecture-rule).
  - `GET /signup`: model에 빈 `signupForm` 추가 → view `"member/signup"`.
  - `POST /signup`: `@Valid @ModelAttribute("signupForm") SignupForm form` + `BindingResult` → 검증 실패 시 비번 필드 비우고(§1.3) `"member/signup"` 재렌더 → 성공 시 `MemberService.signup(...)` 호출(중복은 §1.4 catch) → 성공 시 `"redirect:/login?signup"`.
  - 모델엔 DTO/ViewModel(`signupForm`)만, Entity 금지.
- `MemberServiceResponse`는 `MemberService`에 위임만(login/refresh가 없는 회원가입+me 전용). `AuthServiceResponse`(006)와 별개 — auth(토큰)와 member(가입/내정보) 책임 분리.

### 1.6 보안 공개 경로 추가 (api-authorization-rule 표 반영)
- **REST 체인(@Order(1), `/api/v1/**`)**: `POST /api/v1/members/signup` → `permitAll`(public). `GET /api/v1/members/me`는 별도 명시 없이 `anyRequest().authenticated()`로 인증 필요(JWT principal=userId). 401은 `RestAuthenticationEntryPoint`(006), 권한은 `RoleHierarchy`로 CONSUMER 이상.
- **View 체인(@Order(2))**: `GET /signup`·`POST /signup` → `permitAll`(public). `POST /signup`은 CSRF 보호 대상(View 체인 CSRF 활성 유지) — 폼 `th:action="@{/signup}"`로 `_csrf` 자동 주입.
- 비파괴: 기존 공개 경로(`GET /login`·정적·`/error`)와 formLogin/logout 유지. `SecurityConfigTest`(006) 비파괴 — signup permitAll 추가는 가산적.

| API | 공개 여부 | 최소 권한 | 상위 허용 | 소유권 | 처리 위치 |
|---|---|---|---|---|---|
| `GET /signup` | public | 없음 | 해당없음 | 불필요 | View 체인 permitAll |
| `POST /signup` | public | 없음 | 해당없음 | 불필요 | View 체인 permitAll(+CSRF) |
| `POST /api/v1/members/signup` | public | 없음 | 해당없음 | 불필요 | REST 체인 permitAll |
| `GET /api/v1/members/me` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`,`ROLE_ADMIN` | 필요(본인) | REST 체인 authenticated + JWT principal |

### 1.7 `members/me` vs `auth/me` 중복 (의도된 Task 요구)
- 006이 이미 `GET /api/v1/auth/me`를 제공하지만 Task 007은 `GET /api/v1/members/me`를 명시 요구한다 → **`members/me`를 신규 추가**한다. `auth/me` 제거는 본 Task 범위 밖(다른 테스트/계약 영향)이라 **유지**한다. 두 엔드포인트는 동일 `MeResponse.from(User)`(006 재사용)를 반환하며, principal(userId) 추출 로직도 `AuthServiceResponse.me`와 동일 패턴(`MemberServiceResponse.me`). 향후 정리(택1)는 후속 Task로 미룬다. 이 중복 사실과 처리 방침을 본 절에 1줄로 명시(검토자 혼동 방지).

### 1.8 `/api/v1/members/me` 인증·소유권
- JWT `JwtAuthenticationFilter`(006)가 `Authentication`의 principal에 **userId(long)** 를 설정한다(`AuthServiceResponse.me`가 `(long) authentication.getPrincipal()`로 사용 중 — 동일 규약 재사용). `MemberServiceResponse.me`는 principal userId로 `memberService.getById(userId)` → 본인 정보만 조회(소유권=본인). 다른 사용자 id를 경로로 받지 않으므로 IDOR 표면 없음. 비인증 요청은 필터가 SecurityContext 미설정 → `anyRequest().authenticated()` → 401(`RestAuthenticationEntryPoint`, ErrorResponse JSON).

---

## 2. 구성 요소

### main — member.dto

**`SignupRequest` (record)** — REST 요청
```
@PasswordMatches
public record SignupRequest(
    @NotBlank @Email String email,
    @NotBlank @Size(min = MemberPasswordPolicy.MIN_LENGTH) String password,
    @NotBlank String passwordConfirm,
    @NotBlank String name,
    String phone) {}   // phone optional
```
- 클래스 레벨 `@PasswordMatches`로 password==passwordConfirm 교차검증.

**`SignupResponse` (record)** — REST 응답(비번 미포함)
```
public record SignupResponse(long memberId, String email, String name, String role) {
    public static SignupResponse from(User u) { return new SignupResponse(u.getId(), u.getEmail(), u.getName(), u.getRole().name()); }
}
```

**`SignupForm` (가변 class)** — View 폼 백킹
- `@Getter @Setter @NoArgsConstructor`, 클래스 레벨 `@PasswordMatches`.
- 필드: `@NotBlank @Email email`, `@NotBlank @Size(min=MIN_LENGTH) password`, `@NotBlank passwordConfirm`, `@NotBlank name`, `phone`(optional).
- `toSignupRequest()` 또는 ViewController가 필드 추출해 `MemberService.signup` 호출(둘 다 가능 — 기본: ViewController가 form 필드를 service에 직접 전달).

**`validation.PasswordMatches` / `PasswordMatchesValidator`**
- `@Target(TYPE) @Retention(RUNTIME) @Constraint(validatedBy = PasswordMatchesValidator.class)`.
- Validator: 대상 객체에서 `password`/`passwordConfirm` 추출(SignupRequest accessor·SignupForm getter 모두 처리) → 불일치 시 `passwordConfirm` 필드에 위반 보고(`addPropertyNode("passwordConfirm")`)해 View가 해당 필드 에러로 표시.

### main — member (정책)
**`MemberPasswordPolicy`** — `public static final int MIN_LENGTH = 8;`(주석으로 정책 출처 추적). `@Size(min = MemberPasswordPolicy.MIN_LENGTH)` 참조.

### main — member.repository (수정)
**`MemberRepository`** — 기존 + `boolean existsByEmail(String email);`(citext 대소문자 무시 비교).

### main — member.service

**`MemberService.signup` (수정 — 메서드 추가)**
```
@Transactional
public User signup(String email, String rawPassword, String name, String phone) {
    String normalizedEmail = email.trim();   // 정규화(트림). citext가 대소문자 처리.
    if (memberRepository.existsByEmail(normalizedEmail)) throw new DuplicateEmailException();
    String hash = passwordEncoder.encode(rawPassword);
    try {
        User user = memberRepository.save(User.of(normalizedEmail, hash, name.trim(), normalizePhone(phone), Role.CONSUMER));
        log.info("회원가입 완료: userId={}", user.getId());   // 원문/해시 로그 금지
        return user;
    } catch (DataIntegrityViolationException e) {   // 동시성 경합 unique 위반 흡수
        throw new DuplicateEmailException();
    }
}
```
- 기본 role `CONSUMER` 강제(요청에서 role 미수신). 기존 `authenticate`/`getById` 비파괴.
- `normalizePhone`: 빈 문자열→null(optional).

**`MemberServiceResponse` (신규, @Service @RequiredArgsConstructor)** — REST 전용
- 의존: `MemberService`.
- `SignupResponse signup(SignupRequest req)` → `memberService.signup(req.email(), req.password(), req.name(), req.phone())` → `SignupResponse.from(user)`.
- `MeResponse me(Authentication auth)` → `(long) auth.getPrincipal()` → `memberService.getById(userId)` → `MeResponse.from(user)`(006 재사용).

### main — member.controller

**`MemberRestController` (신규, @RestController @RequestMapping("/api/v1/members"))**
- `POST /signup`: `@Valid @RequestBody SignupRequest` → `memberServiceResponse.signup(req)` → `ResponseEntity.status(CREATED).body(resp)`(201). 비즈니스 로직 없음.
- `GET /me`: `Authentication` → `memberServiceResponse.me(auth)` → `ResponseEntity.ok(meResponse)`(200).

**`MemberSignupViewController` (신규, @Controller @RequiredArgsConstructor)** — backend-implementor 작성
- 의존: `MemberService`.
- `@GetMapping("/signup")` → `model.addAttribute("signupForm", new SignupForm())` → return `"member/signup"`.
- `@PostMapping("/signup")` `@Valid @ModelAttribute("signupForm") SignupForm form, BindingResult br`:
  - `if (br.hasErrors())` → 비번 필드 clear(§1.3) → return `"member/signup"`.
  - `try { memberService.signup(form.getEmail(), form.getPassword(), form.getName(), form.getPhone()); } catch (DuplicateEmailException e) { br.rejectValue("email", "duplicate", "이미 사용 중인 이메일입니다."); 비번 clear; return "member/signup"; }`
  - 성공 → return `"redirect:/login?signup"`.
- view name 반환(ModelAndView 가능), 모델엔 `signupForm`(+BindingResult 자동)만 — Entity 금지.

### main — common.exception (신규)
**`DuplicateEmailException extends BusinessException`** — `super("이미 사용 중인 이메일입니다.", HttpStatus.CONFLICT)`(409). 기존 `BusinessException(message, status)` 생성자 재사용. `RestExceptionHandler`가 자동으로 409 ErrorResponse 변환.

### main — security (수정)
**`SecurityConfig`**
- REST 체인 `authorizeHttpRequests`에 `.requestMatchers(HttpMethod.POST, "/api/v1/members/signup").permitAll()` 추가(login/refresh permitAll 라인 옆). `GET /api/v1/members/me`는 별도 라인 없이 `anyRequest().authenticated()` 적용.
- View 체인 공개 경로에 `.requestMatchers(HttpMethod.GET, "/signup").permitAll()` + `.requestMatchers(HttpMethod.POST, "/signup").permitAll()` 추가. CSRF·formLogin·logout 기존 유지.

### main — 템플릿 (view-implementor 작성)

**`templates/member/signup.html`** (신규)
- 레이아웃: **`layout/blank`**(로그인 화면과 동일 경량 레이아웃 — 비인증 화면에 nav 불필요, §6). `th:replace="~{layout/blank :: blank(title=~{::title}, content=~{::main})}"`.
- 폼: `<form th:action="@{/signup}" method="post" th:object="${signupForm}">`(CSRF 자동 주입), 필드 `th:field="*{email}"`,`*{password}`,`*{passwordConfirm}`,`*{name}`,`*{phone}`.
- 비밀번호 필드는 §1.3대로 value echo 안 함(ViewController가 값 clear).
- 검증 메시지: `th:errors="*{email}"` 등 필드별 + 전역(`th:errors="*{*}"` 또는 비번 불일치 글로벌). email 중복은 `rejectValue("email",...)`로 email 필드 에러에 표시.
- 로그인 링크(`<a th:href="@{/login}">`).

**`templates/auth/login.html`** (수정 — view-implementor)
- 기존 보존: 폼 `@{/login}` POST, `name="username"`/`name="password"`, `param.error`/`param.logout` 분기, `_csrf` 자동 주입, 뷰 이름 `auth/login`, footer 마커(LayoutRenderingTest T1 깨지 않음).
- 추가: `<div th:if="${param.signup}">회원가입이 완료되었습니다. 로그인해 주세요.</div>` + 회원가입 링크 `<a th:href="@{/signup}">회원가입</a>`.

---

## 3. 데이터 흐름

### 3.1 View 회원가입 성공
```
GET /signup (public) → MemberSignupViewController.get → model signupForm → member/signup 렌더(CSRF 포함)
POST /signup (public, CSRF) {email,password,passwordConfirm,name,phone}
  → @Valid SignupForm + BindingResult (형식/길이/일치 통과)
  → MemberService.signup(email,pw,name,phone)
       → existsByEmail false → encode(pw) → save(User.of(...,CONSUMER))
  → redirect:/login?signup
GET /login?signup → auth/login: param.signup 메시지 표시
```

### 3.2 View 회원가입 실패
```
POST /signup
  (a) 검증 실패(@Valid) → BindingResult.hasErrors → 비번 clear → member/signup 재렌더(필드 에러 표시, 이메일/name/phone 유지)
  (b) 이메일 중복 → MemberService.signup → DuplicateEmailException
        → catch → br.rejectValue("email","duplicate",...) → 비번 clear → member/signup 재렌더
  (JSON 아님 — Thymeleaf 화면)
```

### 3.3 REST 회원가입
```
POST /api/v1/members/signup (public) JSON {email,password,passwordConfirm,name,phone}
  → MemberRestController.signup(@Valid)
  성공 → MemberServiceResponse.signup → MemberService.signup → SignupResponse → 201 (+Location)
  검증 실패 → MethodArgumentNotValidException → RestExceptionHandler → 400 ErrorResponse
  중복 → DuplicateEmailException(409) → RestExceptionHandler → 409 ErrorResponse
  (응답/로그에 password/passwordHash 없음)
```

### 3.4 내 정보 조회
```
GET /api/v1/members/me  Authorization: Bearer {access}
  → REST 체인 JwtAuthenticationFilter (006): parse → blacklist 확인 → SecurityContext(principal=userId, ROLE_*)
  → authenticated 통과 → MemberRestController.me → MemberServiceResponse.me
       → (long)principal → memberService.getById(userId) → MeResponse → 200
  비인증/위조/만료 → SecurityContext 미설정 → 401 RestAuthenticationEntryPoint(ErrorResponse JSON, redirect 아님)
```

---

## 4. 예외 처리 전략

| 상황 | 예외/처리 | HTTP | 반환 경로 |
|---|---|---|---|
| REST 입력 검증 실패(형식/길이/비번불일치) | `MethodArgumentNotValidException` | 400 | `RestExceptionHandler` → ErrorResponse JSON |
| REST 이메일 중복 | `DuplicateEmailException`(BusinessException 409) | 409 | `RestExceptionHandler` → ErrorResponse JSON |
| REST /me 비인증 | filter 미설정 → EntryPoint | 401 | `RestAuthenticationEntryPoint`(006) → ErrorResponse JSON |
| REST /me 사용자 없음(토큰 유효 but 삭제) | `getById` → `InvalidTokenException`(006, 401) | 401 | `RestExceptionHandler` |
| View 입력 검증 실패 | `BindingResult.hasErrors` | — | `member/signup` 재렌더(필드 에러) |
| View 이메일 중복 | `DuplicateEmailException` catch → `rejectValue` | — | `member/signup` 재렌더 |
| 동시성 unique 경합 | `DataIntegrityViolationException` → `DuplicateEmailException` 변환 | 409(REST)/재렌더(View) | Service에서 변환 |

- 모든 예외는 `RuntimeException` 상속 커스텀(`BusinessException` 계열)으로 변환(공통 규칙). 비밀번호 원문/해시·스택트레이스·SQL 응답·로그 비노출(error-response-rule, Constraint).
- **REST 에러 JSON ↔ View 재렌더 엄격 분리**(error-response-rule 적용범위 — JSON은 `/api/v1/**`만). View `POST /signup` 실패는 절대 JSON 반환 안 함. 006의 REST/View 체인 분리 유지.

---

## 5. 검증 방법

> 실행 위치: `shop-core/`. 명령: `./gradlew test`. Redis는 `FakeRefreshTokenStore`(@Import, @Primary)로 격리, 실 DB 없이 test profile 기동. `@SpringBootTest` 류는 `@Import(FakeRefreshTokenStore.class)` + `@MockBean MemberRepository, MemberUserDetailsService` 컨벤션 준수(006/002 패턴).

### 5.1 단위 테스트 (Mockito)
- `MemberServiceSignupTest`: signup 성공(User 반환, role=CONSUMER, save 인자 캡처로 passwordHash가 raw≠hash·`encode` 호출 검증); `existsByEmail` true → `DuplicateEmailException`; `DataIntegrityViolationException` → `DuplicateEmailException` 변환; **저장 비밀번호가 BCrypt 해시(원문 아님)** (ArgumentCaptor로 `User.passwordHash` ≠ raw, BCrypt prefix `$2`); 기본 role `CONSUMER`.
- `MemberServiceResponseTest`: signup → `SignupResponse`(password 필드 부재); me → principal userId로 `getById` → `MeResponse`.
- `SignupValidationTest`(선택, Validator 직접): 잘못된 email 형식·짧은 password·password≠passwordConfirm 각각 위반; 정상 입력 위반 0. SignupRequest·SignupForm 양쪽 동일 규칙 확인.

### 5.2 REST MockMvc (`MemberRestControllerTest`)
- `POST /api/v1/members/signup` 성공 201 + body memberId/email/name/role, **password/passwordHash 미포함**(`jsonPath` 부재 단언).
- 검증 실패(잘못된 email / 짧은 pw / 비번 불일치) → 400 ErrorResponse(status/error/message/path).
- 중복 이메일 → 409 ErrorResponse.
- `GET /api/v1/members/me`: 유효 Bearer → 200 + 본인 MeResponse; **비인증 → 401**(ErrorResponse JSON, redirect 아님).
- `MemberRepository` @MockBean stub(existsByEmail/save/findById), `PasswordEncoder`는 실 빈(BCrypt) 또는 mock.

### 5.3 View MockMvc (`MemberSignupViewControllerTest`)
- `GET /signup` → 200, view `member/signup`, **`_csrf` 포함**(CSRF 렌더), 공통 레이아웃 마커(footer) 포함.
- `POST /signup` 정상(`with(csrf())`) → 302 `redirect:/login?signup`, `MemberService.signup` 호출 검증.
- `POST /signup` 검증 실패 → 200 view `member/signup` + `model().attributeHasFieldErrors("signupForm", ...)`, **응답 본문에 password 값 echo 없음**.
- `POST /signup` 중복 이메일(service가 `DuplicateEmailException` throw stub) → 200 `member/signup` + email 필드 에러.
- login 화면 `param.signup` 메시지·회원가입 링크: `GET /login?signup` → 본문에 안내 메시지 + `@{/signup}` 링크(또는 LayoutRenderingTest 분리 테스트).

### 5.4 운영 배선 회귀 (`MemberWiringTest`, P1/testing-rule)
- **fake 미import 금지 위반 주의**: 본 회귀는 신규 빈이 운영 컴포넌트 스캔에서 실제 등록되는지 확인. `@SpringBootTest`(test profile)로 컨텍스트 기동 후 `context.getBean(MemberRestController.class)`, `MemberServiceResponse.class`, `MemberSignupViewController.class` 등록 단언. (RefreshTokenStore는 fake 필요하므로 `@Import(FakeRefreshTokenStore.class)`는 유지하되, 본 Task 신규 빈들은 fake로 대체되는 대상이 아니므로 운영 구현체가 그대로 등록됨 — fake가 신규 빈 배선을 가리지 않음을 단언). MemberRepository는 @MockBean(슬라이스 회피).
- 근거: 006 `RefreshTokenStoreWiringTest` 패턴 계승. 신규 진입 빈(Controller/ServiceResponse) 의존이 운영에서 모두 해결됨을 보장.

### 5.5 기존 테스트 비파괴
- `LayoutRenderingTest`(T1~T3): `auth/login.html` 수정이 `name="username"`·`_csrf`·footer 마커를 깨지 않음(추가만, 기존 요소 보존). **본 파일 미수정이 기본**.
- `SecurityConfigTest`(006): signup permitAll 추가는 가산적 — 기존 View 체인 동작(302/login 200/CSRF) 비파괴.
- `AuthRestControllerSecurityTest`(006): `auth/me` 등 기존 엔드포인트 영향 없음(members/me는 신규 별도).
- `ShopCoreApplicationTests.contextLoads`/`ModularityTests`: member 모듈 신규 빈이 모듈 경계(member→common/security 횡단) 위반 없이 기동.

### 5.6 수동/docker 검증 (CI 외, 구현자)
- docker PG: signup 후 `users` row의 `role='CONSUMER'`, `password_hash`가 `$2`(BCrypt) prefix, `email` citext 저장 확인. `ddl-auto=validate`로 User Entity 정합(V2 기준, 신규 마이그레이션 없음).

### 5.7 Acceptance Criteria 대 검증 매핑
| Acceptance | 검증 |
|---|---|
| GET /signup 렌더링 | 5.3 GET 200 view member/signup |
| 공통 레이아웃/프래그먼트 사용 | 5.3 footer 마커 + layout/blank |
| 회원가입 폼 CSRF 렌더 | 5.3 `_csrf` 포함 |
| 유효 제출 시 CONSUMER 생성 + /login?signup | 5.1 role CONSUMER + 5.3 302 redirect |
| 유효하지 않은 제출 시 검증 메시지 표시 | 5.3 fieldErrors + 재렌더 |
| POST signup 유효 JSON 201 | 5.2 201 |
| 중복 이메일 실패 | 5.1 DuplicateEmailException + 5.2 409 + 5.3 email 에러 |
| 저장 비밀번호 BCrypt | 5.1 captor `$2` prefix + 5.6 docker |
| 응답에 password/passwordHash 없음 | 5.2 jsonPath 부재 |
| /me 본인 정보 반환 | 5.2 me 200 |
| 비인증 /me 401 | 5.2 me 401 |
| 사용자/권한 모델 충돌 없음 | 5.5 SecurityConfigTest/Modularity 비파괴, V2 재사용 |
| 관련 테스트 통과 | `./gradlew test` 그린 |

---

## 6. 트레이드오프

- **SignupForm 클래스 vs record** — 채택 클래스(가변): (장) `th:field`/`BindingResult` 재렌더·부분 바인딩 안정. (단) DTO 타입 2개(form/request) 중복. 미채택 record: 재렌더·필드 echo 경로 취약. → §1.1.
- **교차검증: 커스텀 제약 `@PasswordMatches` vs 컨트롤러/서비스 if-검증** — 채택 커스텀 제약: (장) REST/View 선언적 재사용, `BindingResult`/400 일관 변환, Controller 로직 0(Constraint). (단) Validator 1개 추가. 미채택 if-검증: 컨트롤러 분기·중복·재사용 불가.
- **정책값: 상수 vs @ConfigurationProperties** — 채택 상수(`MemberPasswordPolicy.MIN_LENGTH`): (장) `@Size(min=)` 컴파일 상수 충족·YAGNI. (단) 환경별 가변 불가. 미채택 properties: 현 요구에 과함(필요 시 후속 승격).
- **중복 처리: 사전 existsByEmail + DB unique 변환 vs 한쪽만** — 채택 둘 다(사전 체크로 일반 경로 깔끔, unique 위반 catch로 경합 흡수): (장) 정확·이중 안전. (단) catch 1블록. 미채택 unique-only: 경합 외 일반 케이스도 예외 비용·메시지 일관성 저하.
- **members/me 신규 vs auth/me 재사용** — 채택 members/me 신규(auth/me 유지): (장) Task 명시 요구 충족·체인/계약 비파괴. (단) 일시적 중복. 통합은 후속(§1.7).
- **signup 레이아웃: blank vs base** — 채택 blank(login과 동일 경량): (장) 비인증 화면에 nav 불필요·login UX 일관. (단) base 미사용. 미채택 base: 비인증 상태 nav 어색.
- **비번 재렌더 echo 차단: ViewController clear vs 템플릿 value 미바인딩** — 채택 ViewController clear(§1.3 (a)): (장) `th:field` 일관 유지하며 값만 비움. (단) 컨트롤러 1줄. 미채택 (b): 템플릿이 password만 다른 규칙(가독성 저하).

---

## Spring Boot 컨벤션
- 패키지: `com.shop.shop.member.{controller|service|repository|domain|dto}`(+`dto.validation`, 정책 상수는 `member`), `com.shop.shop.common.exception`(횡단), `com.shop.shop.security`(보안 설정). package-structure-rule 준수(member 모듈, 새 모듈 없음).
- 어노테이션: `@RestController`/`@Controller`/`@RequestMapping`/`@PostMapping`/`@GetMapping`/`@RequestBody`/`@ModelAttribute`/`@Valid`, `@Service`/`@RequiredArgsConstructor`/`@Transactional`/`@Slf4j`, Bean Validation(`@Email`/`@NotBlank`/`@Size`/`@Constraint` 커스텀), Lombok `@Getter`/`@Setter`/`@NoArgsConstructor`. REST DTO는 `record`, View 폼은 가변 class.
- 레이어: REST `RestController → ServiceResponse → Service → Repository`(Controller 로직 금지, ServiceResponse REST 전용). View `ViewController → Service → Repository`(ServiceResponse 미사용, 모델은 DTO/ViewModel만, Entity 금지). 도메인 로직 단일 소유(`MemberService.signup`).
- 보안/데이터: 비밀번호 BCrypt 해시 저장·원문 미노출(DB/로그/응답/View 모델), 기본 role CONSUMER 강제(SELLER/ADMIN public 금지). REST 에러 ErrorResponse JSON ↔ View 재렌더 분리. notification 코드/DB 미참조, 이벤트 계약 변경 0, 신규 마이그레이션 0.

## 완료 조건 체크리스트
- [ ] `MemberRepository.existsByEmail` 추가
- [ ] `MemberService.signup`(중복검사·BCrypt encode·CONSUMER 저장·unique 경합 변환·원문 미로그) 추가
- [ ] `DuplicateEmailException`(409, BusinessException 상속) 추가
- [ ] `SignupRequest`(record, @Email/@NotBlank/@Size/@PasswordMatches) + `SignupResponse`(record, from)
- [ ] `SignupForm`(가변 class, 동일 검증) + `@PasswordMatches`/`PasswordMatchesValidator`(REST/View 공용)
- [ ] `MemberPasswordPolicy.MIN_LENGTH` 상수
- [ ] `MemberServiceResponse`(signup/me, REST 전용) + `MemberRestController`(POST signup 201·GET me 200)
- [ ] `MemberSignupViewController`(GET signup·POST signup 재렌더/redirect, 비번 echo 차단)
- [ ] `SecurityConfig`: REST `POST /api/v1/members/signup` permitAll, View `GET/POST /signup` permitAll(기존 비파괴)
- [ ] `templates/member/signup.html`(layout/blank, `@{/signup}` POST, 필드 email/password/passwordConfirm/name/phone, CSRF 자동, 필드 에러 표시, 비번 echo 없음)
- [ ] `auth/login.html` `param.signup` 메시지 + 회원가입 링크 추가(username/_csrf/footer 마커 비파괴)
- [ ] 단위(MemberServiceSignup/MemberServiceResponse/SignupValidation) + REST MockMvc(201/400/409, me 200/401) + View MockMvc(GET 200·CSRF, POST redirect/재렌더) + 배선 회귀(MemberWiringTest)
- [ ] 기존 비파괴: LayoutRenderingTest(T1~T3)·SecurityConfigTest·AuthRestControllerSecurityTest·Modularity·contextLoads
- [ ] 비밀번호 원문 저장/로그/응답/View 모델 노출 0, role CONSUMER 강제, Controller 비즈니스 로직 0, Entity 응답/모델 직접 전달 0, 신규 마이그레이션 0, notification 참조 0
- [ ] `./gradlew test` 전체 통과(+구현자 docker: role CONSUMER·BCrypt prefix·citext)

## 에이전트 분담 (backend → view 순서)

**호출 순서**: backend-implementor 먼저(Service·DTO·ViewController·Security·REST·테스트), 그다음 view-implementor(템플릿). 근거: `SignupForm` 필드·`MemberService.signup` 시그니처·view name·redirect 규약이 먼저 고정돼야 템플릿이 안정 바인딩(CLAUDE.md 백→화 순).

**같은 `.java` 동시편집 회피**: `MemberSignupViewController.java`(폼 처리·서비스 호출·redirect·비번 clear)는 **backend-implementor 단독** 작성. 템플릿(`member/signup.html`·`login.html` 수정)·정적·View 렌더링 단언 텍스트는 **view-implementor**. backend가 만든 모델 키·필드명·view name에 템플릿을 맞춘다.

| 항목 | 값 | 담당 정합 |
|---|---|---|
| 회원가입 view name | `member/signup` | backend(컨트롤러 반환) ↔ view(템플릿 경로) |
| 템플릿 경로 | `templates/member/signup.html` | view |
| 폼 action / method | `POST @{/signup}` | view(템플릿) ↔ backend(매핑) |
| 폼 필드명 | `email`,`password`,`passwordConfirm`,`name`,`phone` | backend(SignupForm 필드) ↔ view(`th:field`) |
| 폼 백킹 모델 키 | `signupForm`(+BindingResult `errors`) | backend(@ModelAttribute name) ↔ view(`th:object`) |
| 성공 redirect | `redirect:/login?signup` | backend |
| 실패 재렌더 | `member/signup`(필드 에러, 비번 값 미echo) | backend(로직) + view(에러 표시) |
| 비번 echo 차단 방식 | ViewController가 실패 시 password/passwordConfirm clear | backend |
| login 추가 | `param.signup` 안내 메시지 + `@{/signup}` 링크 | view(login.html), backend는 redirect 쿼리만 |
| `MemberService.signup` 시그니처 | `User signup(String email, String rawPassword, String name, String phone)` (role 내부 CONSUMER) | backend |
| `SignupForm` 필드/getter | email/password/passwordConfirm/name/phone + getter/setter | backend |
| `SignupRequest` 필드 | email/password/passwordConfirm/name/phone(record) | backend |
| `SignupResponse` 필드 | memberId/email/name/role(record, 비번 제외) | backend |
| REST signup | `POST /api/v1/members/signup` → 201 SignupResponse | backend |
| 내 정보 | `GET /api/v1/members/me` → 200 MeResponse(006 재사용) | backend |
| login 보존 계약 | `name="username"`/`name="password"`·`_csrf`·`param.error`/`param.logout`·footer 마커 | view(비파괴) |

**구현 시 확인(메인 에이전트 취합)**: (1) `@PasswordMatches` Validator가 SignupRequest(record)·SignupForm(class) 두 타입에서 password/passwordConfirm 접근 정합, (2) View 검증 실패 재렌더에서 password echo 0(테스트 본문 단언), (3) `existsByEmail` citext 대소문자 무시 동작(docker PG), (4) `members/me` principal=userId(long) 규약이 006 `JwtAuthenticationFilter` 설정과 일치, (5) signup permitAll 추가가 SecurityConfigTest/REST 체인 비파괴.

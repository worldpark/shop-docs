# 006. shop-core JWT 로그인 + Redis 로그인 상태 + 계층형 권한 — 구현 Plan

> 영역: backend (REST 인증 API + JWT 발급/검증 + Redis refresh/blacklist + member 로그인 도메인 + Role hierarchy + Security 필터체인 분리 + BaseEntity DB소유 정렬 + V2 마이그레이션 + 테스트)
> 대상 프로젝트: shop-core (REST + security + member 도메인). 화면(Thymeleaf) 신규 작업 없음 — 기존 View 로그인 흐름은 비파괴 유지.
> 작성일: 2026-06-03
> 상태: plan only (코드 변경 없음)

---

## 구현 목표

`shop-core`의 사용자 로그인을 REST 기반 JWT 방식으로 구현한다. `member` 도메인에 DB 기반 로그인 사용자(`User` Entity/Repository/Service/UserDetailsService)를 두고, `security` 지원 모듈에 JWT 발급/검증·Redis refresh/blacklist·Role hierarchy(`ADMIN > SELLER > CONSUMER`)·REST/View 분리 필터체인을 구성한다. 개발용 `InMemoryUserDetailsManager`를 운영 경로에서 제거하고, `created_at`/`updated_at`을 DB 소유(트리거+DEFAULT)로 정렬하도록 `BaseEntity`를 읽기 전용 매핑으로 교정한다. V1 `users.role` CHECK(customer/admin)는 V1 불변이므로 **V2 마이그레이션**으로 `ADMIN/SELLER/CONSUMER`로 교체한다.

---

## 영향 범위

### 신규 파일 (main)

**member 도메인**
- `shop-core/src/main/java/com/shop/shop/member/domain/User.java` — 로그인 사용자 Entity(`users` 매핑, BaseEntity 상속)
- `shop-core/src/main/java/com/shop/shop/member/domain/Role.java` — enum `{CONSUMER, SELLER, ADMIN}`
- `shop-core/src/main/java/com/shop/shop/member/repository/MemberRepository.java` — `findByEmail`
- `shop-core/src/main/java/com/shop/shop/member/service/MemberService.java` — 로그인 검증(BCrypt matches)·사용자 조회 도메인 Service
- `shop-core/src/main/java/com/shop/shop/member/service/MemberUserDetailsService.java` — `UserDetailsService` 구현(email 식별자)
- `shop-core/src/main/java/com/shop/shop/member/dto/LoginRequest.java` — 로그인 요청 DTO(email, password)
- `shop-core/src/main/java/com/shop/shop/member/dto/RefreshRequest.java` — refresh 요청 DTO(refreshToken)
- `shop-core/src/main/java/com/shop/shop/member/dto/TokenResponse.java` — access/refresh 응답 DTO
- `shop-core/src/main/java/com/shop/shop/member/dto/MeResponse.java` — `/me` 응답 DTO(id, email, name, role)
- `shop-core/src/main/java/com/shop/shop/member/controller/AuthRestController.java` — `/api/v1/auth/**` REST 진입점
- `shop-core/src/main/java/com/shop/shop/member/service/AuthServiceResponse.java` — REST 응답 조합 전용(ServiceResponse 레이어)

**security 지원 모듈**
- `shop-core/src/main/java/com/shop/shop/security/JwtProperties.java` — `@ConfigurationProperties(shop.security.jwt)` secret/access-ttl/refresh-ttl/issuer
- `shop-core/src/main/java/com/shop/shop/security/JwtTokenProvider.java` — access/refresh 발급·파싱·검증(jti/roles/subject/exp)
- `shop-core/src/main/java/com/shop/shop/security/JwtAuthenticationFilter.java` — `OncePerRequestFilter`, Bearer 검증 + blacklist 조회 + SecurityContext 설정
- `shop-core/src/main/java/com/shop/shop/security/RefreshTokenStore.java` — refresh 상태 저장 인터페이스(포트)
- `shop-core/src/main/java/com/shop/shop/security/RedisRefreshTokenStore.java` — `StringRedisTemplate` 구현(refresh hash 저장 + blacklist 등록/조회)
- `shop-core/src/main/java/com/shop/shop/security/RestAuthenticationEntryPoint.java` — 401 → ErrorResponse JSON
- `shop-core/src/main/java/com/shop/shop/security/RestAccessDeniedHandler.java` — 403 → ErrorResponse JSON
- `shop-core/src/main/java/com/shop/shop/security/AuthErrorResponseWriter.java` — 필터/핸들러 공용 ErrorResponse JSON 직렬화 헬퍼(중복 제거)

**common.exception**
- `shop-core/src/main/java/com/shop/shop/common/exception/InvalidCredentialsException.java` — 잘못된 자격증명(401)
- `shop-core/src/main/java/com/shop/shop/common/exception/InvalidTokenException.java` — 토큰 만료/위조/형식/refresh 무효(401)

**마이그레이션**
- `shop-core/src/main/resources/db/migration/V2__users_role_hierarchy.sql` — role CHECK 교체 + DEFAULT 변경 + 기존 행 값 변환(customer→CONSUMER, admin→ADMIN)

### 신규 파일 (test)
- `shop-core/src/test/java/com/shop/shop/security/JwtTokenProviderTest.java` — 발급/검증/만료/위조(단위)
- `shop-core/src/test/java/com/shop/shop/security/RefreshTokenStoreTest.java` — 저장/조회/삭제/blacklist(StringRedisTemplate mock 또는 fake)
- `shop-core/src/test/java/com/shop/shop/security/RoleHierarchyTest.java` — 계층 매핑(단위)
- `shop-core/src/test/java/com/shop/shop/member/service/MemberServiceTest.java` — 로그인 성공/실패(단위, Mockito)
- `shop-core/src/test/java/com/shop/shop/member/service/AuthServiceResponseTest.java` — login/refresh/logout 조합 + logout 후 refresh 재사용 실패(단위, fake store)
- `shop-core/src/test/java/com/shop/shop/security/AuthRestControllerSecurityTest.java` — MockMvc: login 성공/실패401, Bearer 인증, 토큰 없음/위조 401, 권한별 403
- `shop-core/src/test/java/com/shop/shop/security/support/FakeRefreshTokenStore.java` — Redis 없는 테스트용 인메모리 store

### 수정 파일
- `shop-core/build.gradle` — jjwt 의존성 추가
- `shop-core/src/main/resources/application.yml` — `shop.security.jwt.*` 추가(secret env, access/refresh ttl, issuer). 기존 `shop.redis.auth.*` 재사용
- `shop-core/src/test/resources/application.yml` — 테스트용 jwt secret/ttl + Redis 자동설정 정책 확인(섹션 5.4)
- `shop-core/src/main/java/com/shop/shop/security/SecurityConfig.java` — 단일 체인 → REST 체인(@Order(1)) + View 체인(@Order(2))로 분리, JWT 필터/엔트리포인트/RoleHierarchy 빈, InMemory 제거
- `shop-core/src/main/java/com/shop/shop/common/domain/BaseEntity.java` — DB 소유 읽기 전용 매핑으로 교정
- `shop-core/src/test/java/com/shop/shop/common/domain/BaseEntityTest.java` — 읽기 전용 매핑 검증으로 수정
- `docs/entity/database_design.md` — §4.1 `users.role`을 ADMIN/SELLER/CONSUMER로 갱신 + V2 사유 기록

### 삭제 파일
- `shop-core/src/main/java/com/shop/shop/security/SecurityUserProperties.java` — InMemory 자격증명 폴백(DB UserDetailsService로 대체)
- `shop-core/src/main/java/com/shop/shop/common/config/JpaAuditingConfig.java` — `@EnableJpaAuditing` 의존 제거(BaseEntity가 DB 소유로 전환되어 앱 auditing 불필요)

### 범위 밖 (필요성만 명시, 후속 Task로 미룸)
- 회원가입·비밀번호 재설정·OAuth2·관리자/판매자 가입 심사(Task §Context 명시)
- refresh token 회전(rotation)·token family·다중 디바이스 세션 관리(섹션 6 트레이드오프 — 본 Task는 단일 refresh per user)
- 보호 도메인 리소스(product/order 등)별 method security 부여(엔드포인트가 아직 없음 — RoleHierarchy 빈과 `/me`로 계층 검증)
- Testcontainers/embedded Redis 도입(Task 005 결정과 일관, mock/fake 격리)
- 시드 사용자/관리자 계정(회원가입 후속 Task. dev 시드는 만들지 않음 — 테스트는 mock 사용자로 검증)

---

## 1. 설계 방식 및 이유

### 1.1 JWT 라이브러리 — jjwt(io.jsonwebtoken) 채택
- 채택: `jjwt`(`jjwt-api` + 런타임 `jjwt-impl`, `jjwt-jackson`). HS256 대칭키로 발급·파싱을 풀컨트롤한다.
- 근거: 본 Task는 자체 로그인 API가 토큰을 **발급**하고, refresh 검증·logout blacklist를 직접 제어한다. `spring-security-oauth2-resource-server`(Nimbus)는 "이미 발급된 토큰을 검증하는 resource server" 모델에 최적화돼 있어, 발급(특히 refresh 흐름·jti 기반 blacklist 연동)은 추가 코드가 필요하다. jjwt가 발급+파싱+클레임 제어를 한 라이브러리에서 단순하게 제공해 본 시나리오에 적합하다(트레이드오프 섹션 6).
- secret은 `shop.security.jwt.secret`(env `SHOP_SECURITY_JWT_SECRET`)로 외부화한다. **코드 하드코딩 금지**(Constraint). HS256은 충분한 길이(≥256bit)의 secret을 요구하므로 yml 기본값/env에서 길이를 보장하고, `JwtProperties`에서 부재/짧은 secret이면 기동 실패하도록 검증한다.
- 발급 클레임: access는 `sub`(userId), `email`, `roles`(예: `["ROLE_CONSUMER"]`), `jti`(UUID), `iss`, `iat`, `exp`. refresh는 `sub`, `jti`, `iss`, `iat`, `exp`(roles 미포함 — 권한은 access만 보유).

### 1.2 Security 필터체인 분리 — REST(@Order(1)) + View(@Order(2))
- 두 개의 `SecurityFilterChain`으로 분리한다. 단일 체인에 JWT(stateless)와 formLogin(session)을 혼재하면 정책 충돌(CSRF/세션/엔트리포인트)이 발생하므로 `securityMatcher`로 경계를 나눈다.
- **REST 체인** `@Order(1)`:
  - `securityMatcher("/api/v1/**")`
  - `sessionCreationPolicy(STATELESS)`, `csrf().disable()` (API 한정 — JWT는 CSRF 비대상, 토큰 기반)
  - `authorizeHttpRequests`: `POST /api/v1/auth/login`·`POST /api/v1/auth/refresh` `permitAll`, 그 외 `/api/v1/**` `authenticated`
  - `JwtAuthenticationFilter`를 `UsernamePasswordAuthenticationFilter` 앞에 추가
  - `exceptionHandling`: `authenticationEntryPoint(RestAuthenticationEntryPoint)`(401), `accessDeniedHandler(RestAccessDeniedHandler)`(403) — 둘 다 **error-response-rule ErrorResponse JSON** 반환
  - formLogin/logout 미설정(REST는 토큰 기반)
- **View 체인** `@Order(2)`:
  - matcher 미지정(나머지 전체) — 기존 formLogin(`/login`)·logout(`/logout`)·CSRF 활성·세션 정책을 **그대로 유지**(비파괴)
  - `userDetailsService`는 DB 기반 `MemberUserDetailsService`로 교체(InMemory 제거 — 1.3)
  - 기존 공개 경로(`/login` GET, 정적 자산, `/error`) 유지
- `RoleHierarchy` 빈은 두 체인이 공유한다(섹션 1.6).
- 비파괴: 기존 `SecurityConfigTest`(a~e + CSRF)는 View 체인 동작을 검증한다. View 자격증명이 InMemory → DB로 바뀌므로 해당 테스트의 사용자 조달 방식 변경이 필요(섹션 5.4에서 처리).

### 1.3 인증 소스 DB 전환 — InMemoryUserDetailsManager 제거
- 운영 경로에서 `InMemoryUserDetailsManager` + `SecurityUserProperties`를 제거하고, `member`의 `MemberUserDetailsService`(email 식별자)로 교체한다. REST(JWT 발급 시 자격 검증)와 View(formLogin) 모두 동일 `UserDetailsService`를 사용한다.
- `SecurityUserProperties`는 **삭제**한다(dev 프로파일 격리 대신 제거 — YAGNI). 회원가입이 후속 Task이므로 운영 시드 사용자는 부재하나, 본 Task의 검증은 mock 사용자/MockMvc로 수행하므로 영향 없음(섹션 5). 로컬 수동 확인이 필요하면 docker PG에 직접 INSERT(섹션 5.5)로 대체한다 — dev 시드 코드는 만들지 않는다.
- `PasswordEncoder`(BCrypt) 빈은 유지한다(로그인 검증·향후 회원가입 공용).

### 1.4 BaseEntity DB 소유 읽기 전용 정렬 (사용자 승인)
- 현재 `BaseEntity`는 `@EntityListeners(AuditingEntityListener)` + `@CreatedDate`/`@LastModifiedDate`(앱 시계)다. database_design.md §8/§25/Task 004 의도는 **DB 소유**(DEFAULT now() + `set_updated_at` 트리거)다. 현재는 INSERT=앱 시계, UPDATE=트리거 시계로 출처가 갈리는 어정쩡한 공존 상태다.
- 교정: `createdAt`/`updatedAt`을 `@Column(name="created_at"/"updated_at", insertable=false, updatable=false)` `Instant`로 매핑하고 `@CreatedDate`/`@LastModifiedDate`/`@EntityListeners`를 제거한다 → DB DEFAULT + 트리거가 단일 소유. JPA는 insert/update에서 두 컬럼을 제외하고, persist 후 `flush + refresh`(또는 `@DynamicInsert`)로 DB 생성값을 읽을 수 있게 한다(구현 재량 — 본 Task에서 시간 컬럼을 응답에 노출하지 않으면 refresh도 불필요).
- `JpaAuditingConfig`(`@EnableJpaAuditing`)는 shop-core에서 불필요해지므로 **삭제**한다. `@EnableJpaAuditing` 의존 제거.
- 주의: notification `BaseEntity`는 건드리지 않는다(Task 004의 의도적 deviation — 별개 프로젝트/인스턴스).
- `BaseEntityTest`는 auditing 검증(AuditingHandler/markCreated)에서 read-only 매핑 검증(`@Column insertable=false`·`updatable=false`, `@CreatedDate`/`@LastModifiedDate`/`@EntityListeners` 부재)으로 수정한다(섹션 5.4).

### 1.5 V2 마이그레이션 — role 값 정렬 (V1 불변 deviation)
- V1 `users.role`은 `CHECK(role IN ('customer','admin')) DEFAULT 'customer'`다. 본 Task는 `ADMIN/SELLER/CONSUMER`가 필요하나 V1은 적용 후 불변(checksum)이므로 **V2**로 변경한다.
- `V2__users_role_hierarchy.sql` 내용(순서 중요 — 데이터 변환 → DEFAULT 교체 → CHECK 교체):
  1. 기존 CHECK·DEFAULT 제거(`ALTER TABLE users DROP CONSTRAINT ...`, `ALTER COLUMN role DROP DEFAULT`)
  2. 기존 행 값 변환: `UPDATE users SET role = 'CONSUMER' WHERE role = 'customer'; UPDATE ... 'ADMIN' WHERE role = 'admin';`
  3. 새 DEFAULT: `ALTER COLUMN role SET DEFAULT 'CONSUMER'`
  4. 새 CHECK: `CHECK (role IN ('ADMIN','SELLER','CONSUMER'))`
- 저장 케이싱은 **대문자**(`ADMIN/SELLER/CONSUMER`)로 둔다. `@Enumerated(STRING)` enum 상수명과 1:1 매핑되고, Spring Security 권한은 `ROLE_` prefix를 붙여 `ROLE_ADMIN` 등으로 변환한다(저장값에는 prefix 없음).
- V2 SQL 헤더 주석에 **deviation 사유**(database_design.md §4.1은 customer/admin이었으나 권한 계층 요구로 ADMIN/SELLER/CONSUMER로 교체, V1 불변이라 V2로 처리)를 기록하고, database_design.md §4.1도 갱신한다(Constraint).
- 검증 측면: `User` Entity의 `role` enum 매핑은 V2 CHECK와 일치해야 validate 통과한다(구현 시 docker PG로 확인).

### 1.6 Redis refresh / blacklist 설계
- `RefreshTokenStore`(인터페이스 포트)로 추상화하고 `RedisRefreshTokenStore`(`StringRedisTemplate`) 구현. 테스트는 `FakeRefreshTokenStore`로 격리(섹션 5).
- **refresh 저장**: key=`shopcore:auth:refresh:{userId}`(기존 `RedisProperties.Auth.refreshPrefix` 재사용), value=refresh token의 **SHA-256 hash**(원문 저장 지양 — Constraint), TTL=refresh TTL. login 시 저장, refresh 요청 시 제시 토큰 hash와 저장값 비교, logout 시 삭제.
- **blacklist**: logout 시 access token의 `jti`를 key=`shopcore:auth:blacklist:{jti}`에 등록, TTL=access token **잔여 만료 시간**(`exp - now`, 음수면 등록 생략). `JwtAuthenticationFilter`가 매 요청 blacklist 조회로 무효화된 access를 차단한다.
- 인터페이스 메서드(예): `void storeRefresh(long userId, String refreshToken)`, `boolean matchesRefresh(long userId, String refreshToken)`, `void deleteRefresh(long userId)`, `void blacklistAccess(String jti, Duration remainingTtl)`, `boolean isBlacklisted(String jti)`.

### 1.7 TTL 출처 단일화
- refresh token의 만료(JWT `exp`)와 Redis 키 TTL이 **반드시 일치**해야 일관된다. 출처 중복(`JwtProperties.refreshTtl` vs `RedisProperties.Auth.refreshTtl`)을 단일화한다.
- **결정**: refresh/access TTL의 SSOT는 **`JwtProperties`**(`access-ttl`, `refresh-ttl`)다. `RefreshTokenStore`가 Redis 키 TTL을 설정할 때 `JwtProperties.refreshTtl`을 사용한다. `RedisProperties.Auth.refreshPrefix`/`blacklistPrefix`(키 네임스페이스)는 재사용하되, `RedisProperties.Auth.refreshTtl`/`blacklistTtl`(가정치)은 사용하지 않는다(prefix만 재사용, TTL은 JwtProperties 소유). 근거: blacklist TTL은 access 잔여 만료로 **동적 산정**되어야 하고 refresh TTL은 토큰 exp와 동기화돼야 하므로, 정적 yml 가정치(RedisProperties)보다 JwtProperties/런타임 산정이 정확하다. yml의 `shop.redis.auth.*-ttl`은 네임스페이스 설명용 잔존값으로 두되 코드는 참조하지 않음을 주석에 명시한다.

### 1.8 Role hierarchy
- `RoleHierarchy` 빈으로 `ROLE_ADMIN > ROLE_SELLER > ROLE_CONSUMER`를 선언한다(Spring Security 6.x `RoleHierarchyImpl.fromHierarchy(...)` 또는 `withDefaultRolePrefix`). 두 필터체인이 공유한다.
- 계층 평가는 Spring Security 설정/`MethodSecurityExpressionHandler`에 위임한다(Controller 비즈니스 로직으로 권한 판단 금지 — api-authorization-rule). 본 Task는 보호 도메인 엔드포인트가 아직 없으므로, RoleHierarchy 동작은 (a) `RoleHierarchyTest` 단위, (b) MockMvc에서 테스트 전용 보호 경로(또는 `@WithMockUser` 권한별 `/me`/더미 보호 핸들러)로 검증한다(섹션 5.3).

### 1.9 에러 포맷 — 필터/엔트리포인트도 ErrorResponse JSON
- REST 인증/인가 실패(401/403)는 error-response-rule의 공통 `ErrorResponse`(status/error/message/path/timestamp) JSON으로 반환한다(REST 한정).
- 계층:
  - `AuthRestController` 내부에서 던지는 도메인 예외(`InvalidCredentialsException`/`InvalidTokenException`, `BusinessException` 상속)는 기존 `RestExceptionHandler`(`@RestControllerAdvice`)가 ErrorResponse로 변환한다(status 보유).
  - 필터·엔트리포인트·denied 핸들러 레벨(SecurityContext 진입 전, advice가 못 잡는 지점)의 401/403은 `RestAuthenticationEntryPoint`/`RestAccessDeniedHandler`가 `AuthErrorResponseWriter`로 동일 `ErrorResponse` JSON을 직접 직렬화한다(`ObjectMapper` 사용).
- 모든 예외는 `RuntimeException` 상속 커스텀 예외(`common.exception`, 기존 `BusinessException` 계열)로 변환한다. REST 인증 실패를 View 로그인 리다이렉트와 **섞지 않는다**(REST 체인은 redirect 엔트리포인트 미사용 — Constraint).

### 1.10 레이어 준수 (REST: Controller → ServiceResponse → Service → Repository)
- `AuthRestController`: 요청 수신·검증(`@Valid`)·`AuthServiceResponse` 호출·HTTP 응답만. 비즈니스 로직 금지(Constraint).
- `AuthServiceResponse`: REST 응답 조합 전용(login → 자격검증 위임 + 토큰 발급 + Redis 저장 → `TokenResponse`; refresh → 검증 + 새 access; logout → 삭제 + blacklist; me → SecurityContext 사용자 → `MeResponse`). View/Scheduler/EventListener에서는 ServiceResponse 미사용(architecture-rule). 토큰 발급/Redis는 `JwtTokenProvider`/`RefreshTokenStore`에 위임.
- `MemberService`: 도메인 로직(email 조회·BCrypt matches·사용자 조회). Repository는 여기서만 호출.
- DTO/Entity 분리. `User` Entity는 응답으로 직접 반환 금지(`TokenResponse`/`MeResponse` DTO만).

---

## 2. 구성 요소

### main — member 도메인

**`member.domain.Role` (enum)**
- 값: `CONSUMER`, `SELLER`, `ADMIN`. 저장값=상수명(대문자). Spring 권한 변환 헬퍼: `String authority()` → `"ROLE_" + name()`.

**`member.domain.User` (Entity, extends 교정된 BaseEntity)**
- 애너테이션: `@Entity`, `@Table(name="users")`, `@Getter`, `@NoArgsConstructor(access=PROTECTED)`.
- 필드: `@Id @GeneratedValue(strategy=IDENTITY) Long id`; `@Column(name="email", columnDefinition="citext", nullable=false, unique=true) String email`; `@Column(name="password_hash", nullable=false) String passwordHash`; `@Column(nullable=false) String name`; `String phone`; `@Enumerated(STRING) @Column(nullable=false, length=20) Role role`; (createdAt/updatedAt은 BaseEntity).
- **citext validate 리스크(구현 시 확인)**: String↔citext가 Hibernate 6 validate에서 타입 불일치로 막힐 수 있다. 기본값: `@Column(columnDefinition="citext")` 명시. 막히면 (a) `@Type`/커스텀 UserType 또는 (b) validate에서 컬럼 타입 비교가 통과하도록 docker PG로 확인 후 조정. text 컬럼(password_hash/name/phone)은 String↔text가 통과(Task 004 확인).
- 메서드: `boolean matchesPassword(PasswordEncoder, String raw)`는 두지 않고 검증은 Service에서(Entity에 인코더 의존 주입 회피). Entity는 상태 보유만.

**`member.repository.MemberRepository`**
- `interface MemberRepository extends JpaRepository<User, Long>` + `Optional<User> findByEmail(String email)`.

**`member.service.MemberService` (@Service)**
- `User authenticate(String email, String rawPassword)`: `findByEmail` → 없으면 `InvalidCredentialsException` → `passwordEncoder.matches` 실패 시 `InvalidCredentialsException`(존재/비밀번호 오류 메시지 동일하게 처리해 계정 열거 방지) → 성공 시 User 반환. 비밀번호 원문 로그 금지(Constraint).
- `User getById(long userId)`: `/me`·refresh 후 사용자 조회용. 없으면 `InvalidTokenException` 또는 `BusinessException(404)`.

**`member.service.MemberUserDetailsService` (@Service, UserDetailsService)**
- `loadUserByUsername(String email)`: `findByEmail` → `org.springframework.security.core.userdetails.User`(authorities=`ROLE_{role}`) 빌드. 없으면 `UsernameNotFoundException`. View formLogin·(필요 시 REST 인증)에서 공용.

**`member.dto.*` (record)**
- `LoginRequest(@Email @NotBlank String email, @NotBlank String password)`
- `RefreshRequest(@NotBlank String refreshToken)`
- `TokenResponse(String accessToken, String refreshToken, String tokenType /* "Bearer" */, long expiresIn /* access TTL seconds */)`
- `MeResponse(long id, String email, String name, String role)`

**`member.controller.AuthRestController` (@RestController, `@RequestMapping("/api/v1/auth")`)**
- `POST /login` `@Valid LoginRequest` → `authServiceResponse.login(req)` → `TokenResponse` (200)
- `POST /refresh` `@Valid RefreshRequest` → `authServiceResponse.refresh(req)` → `TokenResponse`
- `POST /logout` (Authorization Bearer + 선택 RefreshRequest) → `authServiceResponse.logout(...)` → 204/200
- `GET /me` (인증 필요) → `authServiceResponse.me(authentication)` → `MeResponse`
- 비즈니스 로직 없음. ServiceResponse만 호출.

**`member.service.AuthServiceResponse` (@Service, @RequiredArgsConstructor)**
- 의존: `MemberService`, `JwtTokenProvider`, `RefreshTokenStore`.
- `TokenResponse login(LoginRequest)`: `memberService.authenticate` → `provider.createAccess(user)` + `provider.createRefresh(user)` → `store.storeRefresh(user.id, refresh)` → TokenResponse.
- `TokenResponse refresh(RefreshRequest)`: `provider.parse(refresh)`(만료/위조 → `InvalidTokenException`) → `store.matchesRefresh(userId, refresh)` false면 `InvalidTokenException`(logout/재사용 차단) → 새 access(refresh 재발급 여부=섹션 6, 기본: refresh 유지, access만 재발급) → TokenResponse.
- `void logout(String bearerAccessToken, ...)`: access parse → `store.deleteRefresh(userId)` + `store.blacklistAccess(jti, remainingTtl)`.
- `MeResponse me(Authentication)`: principal userId/email/role → `memberService.getById` → MeResponse.

### main — security

**`security.JwtProperties`** (`@ConfigurationProperties("shop.security.jwt")` record)
- 필드: `String secret`(env, 하드코딩 금지), `Duration accessTtl`, `Duration refreshTtl`, `String issuer`. compact 생성자에서 secret 부재/길이 검증(부족 시 예외).

**`security.JwtTokenProvider` (@Component)**
- `String createAccess(User user)`: subject=userId, claims(email, roles, jti=UUID), exp=now+accessTtl, iss. HS256 서명.
- `String createRefresh(User user)`: subject=userId, jti, exp=now+refreshTtl.
- `Jws<Claims> parse(String token)`: 서명/만료/형식 검증. 실패 분류 → `InvalidTokenException`(만료/위조/형식).
- 추출 헬퍼: `userId`, `roles`, `jti`, `remainingTtl(token)`(blacklist용).

**`security.JwtAuthenticationFilter` (extends OncePerRequestFilter)**
- Authorization `Bearer` 헤더 추출(없으면 통과 → 엔트리포인트가 401 결정). 토큰 parse → blacklist 조회(`store.isBlacklisted(jti)` true면 인증 미설정/401) → `UsernamePasswordAuthenticationToken`(principal=userId/email, authorities=roles) SecurityContext 설정. parse 실패 시 SecurityContext 미설정 → 엔트리포인트 401. (필터에서 예외를 직접 응답 쓰지 않고 EntryPoint로 위임하거나, 형식 오류는 즉시 `AuthErrorResponseWriter`로 401 — 구현 일관성 택1, 기본: EntryPoint 위임).

**`security.RefreshTokenStore`** (인터페이스) / **`security.RedisRefreshTokenStore`** (@Component, `StringRedisTemplate`)
- 섹션 1.6 메서드. hash=SHA-256(`MessageDigest`). prefix는 `RedisProperties.Auth`에서, TTL은 `JwtProperties`에서.

**`security.RestAuthenticationEntryPoint`** (AuthenticationEntryPoint) / **`security.RestAccessDeniedHandler`** (AccessDeniedHandler)
- 각각 401/403 → `AuthErrorResponseWriter.write(response, status, message, path)`.

**`security.AuthErrorResponseWriter`** (@Component)
- `ObjectMapper`로 `ErrorResponse.of(status, message, path)` 직렬화, `application/json` + status 코드. RestExceptionHandler와 동일 포맷 보장.

**`security.SecurityConfig` (수정)**
- 빈: `SecurityFilterChain restChain(@Order(1))`, `SecurityFilterChain viewChain(@Order(2))`, `PasswordEncoder`(유지), `RoleHierarchy`, `JwtAuthenticationFilter` 주입, `RestAuthenticationEntryPoint`/`RestAccessDeniedHandler` 주입. `@EnableConfigurationProperties({JwtProperties.class})`. `SecurityUserProperties`/InMemory 제거.
- method security 필요 시 `@EnableMethodSecurity` + `RoleHierarchy` 연결(보호 도메인 엔드포인트는 후속이므로 본 Task는 필터체인 authorizeHttpRequests 위주).

### common.exception (신규)
- `InvalidCredentialsException extends BusinessException`(status=401, 메시지="이메일 또는 비밀번호가 올바르지 않습니다.")
- `InvalidTokenException extends BusinessException`(status=401, 메시지="유효하지 않은 토큰입니다.")
- 기존 `BusinessException`(message, HttpStatus) 생성자 재사용. 권한 없음(403)은 `RestAccessDeniedHandler`가 처리(예외 생성 불필요).

### 마이그레이션 (신규)
- `V2__users_role_hierarchy.sql` — 섹션 1.5 내용 + 불변/deviation 헤더 주석.

### 설정 (수정)

**`build.gradle`**
- `implementation 'io.jsonwebtoken:jjwt-api:0.12.x'`, `runtimeOnly 'io.jsonwebtoken:jjwt-impl:0.12.x'`, `runtimeOnly 'io.jsonwebtoken:jjwt-jackson:0.12.x'`. (Spring Boot BOM이 jjwt 버전을 관리하지 않으므로 명시 버전 — 구현 시 최신 0.12.x 확인).
- Redis는 기존 `spring-boot-starter-data-redis`가 이미 있음(RedisConfig/RedisProperties 존재) — 추가 불요(구현 시 확인).

**`application.yml` (main)**
```yaml
shop:
  security:
    jwt:
      secret: ${SHOP_SECURITY_JWT_SECRET:}   # 운영 필수, 하드코딩 금지(부재 시 기동 실패)
      access-ttl: ${SHOP_SECURITY_JWT_ACCESS_TTL:PT30M}   # 30분
      refresh-ttl: ${SHOP_SECURITY_JWT_REFRESH_TTL:P14D}  # 14일 — Redis refresh 키 TTL과 동기화
      issuer: ${SHOP_SECURITY_JWT_ISSUER:shop-core}
  redis:
    auth:
      refresh-prefix: ...   # 기존 유지(prefix 재사용). *-ttl 값은 코드 미참조(주석으로 명시)
```
- access-ttl(PT30M) ≠ refresh-ttl(P14D)(Acceptance). blacklist TTL은 access 잔여로 동적 산정.

**`application.yml` (test)**
- 테스트 전용 jwt secret(충분 길이 더미)·짧은 TTL 추가. Redis 자동설정은 단위/MockMvc에서 fake store로 대체하므로 실 Redis 불요(섹션 5.4).

### test (신규/수정) — 섹션 5

---

## 3. 데이터 흐름

### 3.1 로그인
```
POST /api/v1/auth/login {email,password}
  → AuthRestController.login(@Valid) → AuthServiceResponse.login
     → MemberService.authenticate(email, raw)
        → MemberRepository.findByEmail → BCrypt matches (실패 시 InvalidCredentialsException=401)
     → JwtTokenProvider.createAccess(user) (roles=ROLE_*, jti, exp=+accessTtl)
     → JwtTokenProvider.createRefresh(user) (jti, exp=+refreshTtl)
     → RefreshTokenStore.storeRefresh(userId, refresh)
        → Redis SET shopcore:auth:refresh:{userId} = SHA256(refresh), TTL=refreshTtl
  → 200 TokenResponse(access, refresh, "Bearer", accessTtlSeconds)
```

### 3.2 보호 API 요청
```
GET /api/v1/auth/me  Authorization: Bearer {access}
  → REST chain JwtAuthenticationFilter
     → parse(access) (만료/위조 → SecurityContext 미설정)
     → RefreshTokenStore.isBlacklisted(jti)? true → 미인증
     → 유효 → SecurityContext = Auth(userId, ROLE_*)
  → authorizeHttpRequests authenticated 통과
  → AuthServiceResponse.me → MeResponse
  (미인증/위조/만료 → RestAuthenticationEntryPoint 401 ErrorResponse JSON)
```

### 3.3 refresh
```
POST /api/v1/auth/refresh {refreshToken}  (permitAll)
  → AuthServiceResponse.refresh
     → JwtTokenProvider.parse(refresh) (만료/위조 → InvalidTokenException=401)
     → RefreshTokenStore.matchesRefresh(userId, refresh)
        → Redis GET shopcore:auth:refresh:{userId} == SHA256(refresh)?
        → 불일치/부재(=logout됨/재사용/탈취) → InvalidTokenException=401
     → 새 access 발급(기본: refresh 유지) → 200 TokenResponse
```

### 3.4 logout
```
POST /api/v1/auth/logout  Authorization: Bearer {access} (+선택 refresh)
  → AuthServiceResponse.logout
     → parse(access) → userId, jti, remainingTtl
     → RefreshTokenStore.deleteRefresh(userId)   (Redis DEL refresh 키)
     → RefreshTokenStore.blacklistAccess(jti, remainingTtl)  (Redis SET blacklist:{jti} TTL=remaining)
  → 204
이후 같은 refresh로 refresh 요청 → matchesRefresh false → 401 (재사용 차단, Acceptance)
이후 같은 access로 보호 API → isBlacklisted true → 401
```

### 3.5 권한 계층 평가
```
RoleHierarchy(ROLE_ADMIN > ROLE_SELLER > ROLE_CONSUMER)
  → ADMIN principal이 SELLER/CONSUMER 보호 리소스 접근 허용
  → CONSUMER principal이 SELLER/ADMIN 보호 리소스 접근 → 403 RestAccessDeniedHandler(ErrorResponse JSON)
```

---

## 4. 예외 처리 전략

| 상황 | 예외/처리 | HTTP | 반환 경로 |
|---|---|---|---|
| 잘못된 이메일/비밀번호 | `InvalidCredentialsException`(BusinessException) | 401 | RestExceptionHandler → ErrorResponse |
| access 만료/위조/형식 | filter 미인증 → EntryPoint | 401 | RestAuthenticationEntryPoint → ErrorResponse |
| access blacklist(logout 후) | filter 미인증 → EntryPoint | 401 | RestAuthenticationEntryPoint → ErrorResponse |
| Authorization 헤더 없음 | filter 미인증 → EntryPoint | 401 | RestAuthenticationEntryPoint → ErrorResponse |
| refresh 만료/위조 | `InvalidTokenException` | 401 | RestExceptionHandler → ErrorResponse |
| refresh 무효/재사용/logout 후 | `InvalidTokenException`(matchesRefresh false) | 401 | RestExceptionHandler → ErrorResponse |
| 권한 부족(하위→상위) | AccessDeniedException | 403 | RestAccessDeniedHandler → ErrorResponse |
| 검증 실패(@Valid) | MethodArgumentNotValidException | 400 | 기존 RestExceptionHandler |

- 모든 예외는 `RuntimeException` 상속 커스텀 예외로 변환(`BusinessException` 계열). 필터/핸들러 레벨도 동일 `ErrorResponse` JSON(`AuthErrorResponseWriter`).
- REST 인증/인가 실패는 **View 로그인 리다이렉트와 분리**(REST 체인은 redirect 엔트리포인트 미사용 — Constraint). View 체인은 기존 302 redirect 유지.
- 내부 정보(스택트레이스/SQL/원문 토큰/비밀번호) 응답·로그 비노출(error-response-rule, Constraint).

---

## 5. 검증 방법

> 실행 위치: `shop-core/`. 명령: `./gradlew test`. Redis는 mock/fake로 격리(Testcontainers/embedded 미도입 — Task 005 일관, YAGNI).

### 5.1 단위 테스트
- `JwtTokenProviderTest`: access/refresh 발급 → parse 클레임(sub/roles/jti/exp) 일치; 만료 토큰 parse → `InvalidTokenException`; 변조 서명 → `InvalidTokenException`; access.roles 포함·refresh.roles 미포함.
- `RefreshTokenStoreTest`: store→matches(true), 다른 토큰→matches(false), delete 후→matches(false), blacklistAccess→isBlacklisted(true). `StringRedisTemplate` mock 또는 `FakeRefreshTokenStore`(인메모리 Map+TTL 모사).
- `RoleHierarchyTest`: ADMIN authorities가 ROLE_SELLER/ROLE_CONSUMER 함의; CONSUMER가 상위 미함의.
- `MemberServiceTest`(Mockito): authenticate 성공(User 반환); 없는 email→InvalidCredentials; 비밀번호 불일치→InvalidCredentials(메시지 동일).
- `AuthServiceResponseTest`(fake store, mock provider/member): login→토큰+store 저장; refresh 정상→새 access; logout→delete+blacklist; **logout 후 동일 refresh→matches false→InvalidTokenException**(Acceptance).

### 5.2 Security MockMvc 테스트 (`AuthRestControllerSecurityTest`, `@SpringBootTest` + `@AutoConfigureMockMvc` 또는 슬라이스 + fake store `@Import`)
- `POST /api/v1/auth/login` 성공(200 + access/refresh) / 잘못된 비밀번호 401(ErrorResponse).
- `Bearer` 유효 access로 `GET /api/v1/auth/me` 200.
- 토큰 없음 401 / 위조·만료 토큰 401(ErrorResponse JSON, redirect 아님).
- 권한별: 테스트 보호 경로(또는 `@WithMockUser(roles=...)`)로 ADMIN→하위 허용, CONSUMER→상위 403(ErrorResponse).
- `refresh` 정상 → 200; logout 후 동일 refresh → 401.
- MemberRepository는 테스트에서 mock(@MockBean) 또는 fake로 사용자 조달(citext/실 DB 미사용).

### 5.3 컨텍스트 테스트
- `ShopCoreApplicationTests.contextLoads()` 비파괴(test profile, DataSource/Kafka/Flyway 제외 유지 + Redis 처리). JWT 빈/필터체인이 DB·Redis 부재 컨텍스트에서 기동되도록 확인(JwtProperties secret 테스트값 제공, Redis 자동설정 정책 5.4).
- `ModularityTests`(Modulith): member→security/common 의존 방향이 모듈 규칙 위반 없는지 검증 통과(security/common은 횡단 지원 모듈).

### 5.4 기존 테스트 비파괴 / 수정
- **`BaseEntityTest`**: auditing(AuditingHandler/markCreated/@CreatedDate) 검증 → **read-only 매핑 검증으로 수정**(@Column insertable=false·updatable=false, `@CreatedDate`/`@LastModifiedDate`/`@EntityListeners` 부재, `@MappedSuperclass` 유지). (BaseEntity 정렬로 인한 허용된 수정)
- **`SecurityConfigTest`**(a~e + CSRF): InMemory 자격증명(user/dev1234)이 사라지므로 View formLogin 성공/실패 케이스의 사용자 조달을 DB 기반(@MockBean MemberRepository/MemberUserDetailsService로 BCrypt 사용자 stub)으로 조정. View 체인 동작(302 redirect, /login 200, CSRF 403)은 그대로 유지. (필터체인 분리·인증소스 전환으로 인한 허용 수정)
- **test application.yml**: jwt secret 더미 + Redis 자동설정. Redis 미기동 컨텍스트에서 `RedisRefreshTokenStore`(StringRedisTemplate 의존)가 풀 컨텍스트(@SpringBootTest)를 깨지 않도록 — 기본: Redis 자동설정 유지(lettuce는 lazy 연결이라 미기동이어도 빈 생성은 통과)하거나, MockMvc 테스트에서 `RefreshTokenStore`를 `@MockBean`/fake로 교체. **구현 시 확인**: contextLoads가 Redis 연결을 강제하지 않는지(기본 lazy). 깨지면 test profile에서 `RedisAutoConfiguration` 제외 + RefreshTokenStore fake 빈 제공.
- `LayoutRenderingTest`/`RedisPropertiesTest`/exception advice 테스트: 비파괴 확인(변경 없음 목표).

### 5.5 권장 수동/docker 검증 (CI 외, 구현자 별도 확인)
- docker PG 기동 → `V2` Flyway 적용 로그 + `ddl-auto=validate`로 `User` Entity(citext role enum) 통과 확인. validate 실패 시 citext/role CHECK 정합 조정(섹션 1.5/2 citext 항목).
- docker Redis: login 후 `redis-cli keys "shopcore:auth:*"`로 `refresh:{userId}` 확인, logout 후 키 삭제 + `blacklist:{jti}` 등록 확인.

### 5.6 Acceptance Criteria 대 검증 매핑
| Acceptance | 검증 |
|---|---|
| login이 access+refresh 발급 | 5.2 login 200 + 5.1 AuthServiceResponseTest |
| 로그인 시 Redis에 refresh 저장 | 5.1 RefreshTokenStoreTest/AuthServiceResponseTest + 5.5 redis-cli |
| 잘못된 비밀번호 401 | 5.1 MemberServiceTest + 5.2 login 401 |
| Bearer로 보호 API 인증 설정 | 5.2 /me 200 |
| 만료/위조/형식 401 | 5.1 JwtTokenProviderTest + 5.2 위조/만료 401 |
| refresh가 Redis 유효 토큰으로 새 access | 5.1/5.2 refresh 200 |
| logout이 Redis 정보 제거/무효화 | 5.1 logout(delete+blacklist) + 5.5 redis-cli |
| logout 후 동일 refresh 재발급 불가 | 5.1/5.2 logout 후 refresh 401 |
| Role hierarchy ADMIN>SELLER>CONSUMER | 5.1 RoleHierarchyTest + 5.2 권한별 |
| 하위 권한 상위 리소스 접근 불가 | 5.2 CONSUMER→상위 403 |
| secret/TTL/prefix 설정 추적 | JwtProperties + application.yml + RedisProperties 재사용 |
| View 흐름과 JWT 흐름 충돌 없음 | 5.4 SecurityConfigTest(View 체인) 비파괴 + 체인 분리 |
| 관련 테스트 통과 | `./gradlew test` 그린 |

---

## 6. 트레이드오프

- **JWT 라이브러리: jjwt vs oauth2-resource-server(Nimbus)** — 채택 jjwt: (장) 발급+파싱+refresh/blacklist 풀컨트롤, 단순. (단) resource-server 표준 인프라(JWK/issuer 검증 자동) 미사용. 미채택 oauth2-resource-server: 검증 중심 모델이라 자체 발급/refresh/blacklist에 추가 코드 — 본 시나리오에 과함.
- **필터체인 분리: 2개 체인(securityMatcher) vs 단일 체인 분기** — 채택 2체인: (장) stateless/CSRF/엔트리포인트 정책을 REST/View로 깔끔히 격리, View 비파괴. (단) 빈 2개·@Order 관리. 미채택 단일: 정책 혼재로 충돌·가독성 저하.
- **refresh 저장: 원문 vs hash(SHA-256)** — 채택 hash: (장) Redis 유출 시 원문 토큰 비노출(Constraint 준수). (단) 비교 시 hash 계산. 미채택 원문: 보안 약점.
- **refresh 회전(rotation): 도입 vs 미도입** — 채택 미도입(access만 재발급, refresh 유지): (장) 단순, 본 Task 범위 충족. (단) 탈취 refresh 장기 유효(refresh TTL까지) — logout/blacklist로 부분 완화. 회전·token family는 후속(영향범위 밖).
- **InMemoryUserDetailsManager: 제거 vs dev 프로파일 격리** — 채택 제거: (장) 운영/개발 단일 인증 소스(DB), 잔존 코드 0. (단) 시드 사용자 부재로 로컬 수동 로그인은 docker INSERT 필요. 미채택 dev 격리: 코드 잔존·이원화.
- **Redis 격리: mock/fake vs Testcontainers/embedded** — 채택 mock/fake: (장) Task 005 방침 일관, 빠른 테스트, 의존 최소(YAGNI). (단) 실 Redis TTL/동작은 CI 미검증 → 5.5 수동 보완.
- **BaseEntity 정렬: 지금 vs 후속** — 채택 지금(사용자 승인): (장) 첫 도메인 Entity(User) 등장과 함께 DB 소유 일관성 확정, 어정쩡한 공존 해소. (단) BaseEntityTest 수정 + JpaAuditingConfig 삭제 — 허용된 범위.
- **TTL 출처: JwtProperties 단일 소유 vs RedisProperties 재사용** — 채택 JwtProperties 소유(prefix만 RedisProperties 재사용): (장) 토큰 exp와 Redis TTL이 한 출처로 동기화, blacklist는 동적 산정. (단) RedisProperties의 *-ttl 가정치가 미사용 잔존 — 주석으로 명시.

---

## Spring Boot 컨벤션
- 패키지: `com.shop.shop.member.{controller|service|repository|domain|dto}`(도메인), `com.shop.shop.security`(인증 인프라), `com.shop.shop.common.exception`(횡단 예외). package-structure-rule 준수.
- 어노테이션: `@RestController`/`@RequestMapping`/`@PostMapping`/`@GetMapping`/`@Valid`, `@Service`/`@Component`/`@Configuration`, `@Entity`/`@Table`/`@Id`/`@GeneratedValue`/`@Enumerated(STRING)`/`@Column`, `@ConfigurationProperties`/`@EnableConfigurationProperties`, `@EnableWebSecurity`/`@Bean SecurityFilterChain`/`@Order`, Lombok `@Getter`/`@NoArgsConstructor`/`@RequiredArgsConstructor`/`@Slf4j`. DTO는 Java `record`.
- 레이어: REST `RestController → ServiceResponse → Service → Repository`. Controller 비즈니스 로직 금지. ServiceResponse는 REST 전용. DTO/Entity 분리, Entity 응답 직접 반환 금지. 모든 예외 RuntimeException 상속 커스텀(BusinessException 계열).
- 보안: JWT secret/TTL/prefix는 설정 추적. 비밀번호 원문 저장/로그 금지. refresh hash 저장. REST 인증/인가 실패 ↔ View redirect 분리.
- 격리: shopcore:* prefix만 사용(RedisProperties 재사용), notif:* 참조 0. notification 코드/DB 미참조.

## 완료 조건
- [ ] build.gradle jjwt(api/impl/jackson) 추가
- [ ] `User`(users 매핑, BaseEntity 상속, citext email, role enum) + `Role{CONSUMER,SELLER,ADMIN}` + `MemberRepository(findByEmail)`
- [ ] `MemberService`(BCrypt authenticate·getById) + `MemberUserDetailsService`(email)
- [ ] DTO: LoginRequest/RefreshRequest/TokenResponse/MeResponse(record, @Valid)
- [ ] `AuthRestController`(/api/v1/auth/login·refresh·logout·me) + `AuthServiceResponse`(레이어 준수)
- [ ] `JwtProperties`(secret env·access/refresh ttl·issuer, 검증) + `JwtTokenProvider`(발급/파싱/검증)
- [ ] `JwtAuthenticationFilter`(Bearer + blacklist) + `RefreshTokenStore`/`RedisRefreshTokenStore`(refresh hash 저장 + blacklist, JwtProperties TTL)
- [ ] `RestAuthenticationEntryPoint`(401)·`RestAccessDeniedHandler`(403)·`AuthErrorResponseWriter`(ErrorResponse JSON)
- [ ] `RoleHierarchy` 빈(ROLE_ADMIN>ROLE_SELLER>ROLE_CONSUMER) 공유
- [ ] `SecurityConfig`: REST 체인(@Order(1) /api/v1/** stateless·csrf off·JWT·permitAll login/refresh)·View 체인(@Order(2) 기존 유지), InMemory/SecurityUserProperties 제거
- [ ] `InvalidCredentialsException`(401)·`InvalidTokenException`(401) 추가
- [ ] `V2__users_role_hierarchy.sql`(데이터 변환+DEFAULT+CHECK 교체, deviation 헤더 주석) + database_design.md §4.1 갱신
- [ ] `BaseEntity` DB 소유 읽기 전용 정렬 + `JpaAuditingConfig` 삭제 + `BaseEntityTest` 수정
- [ ] application.yml(main) `shop.security.jwt.*` 추가, test yml jwt 더미 secret + Redis 정책
- [ ] 단위(JwtTokenProvider/RefreshTokenStore/RoleHierarchy/MemberService/AuthServiceResponse) + MockMvc Security(login·Bearer·401·권한 403·refresh·logout 재사용 차단) + 컨텍스트(contextLoads/Modularity)
- [ ] 기존 비파괴: SecurityConfigTest(View 체인, 사용자 조달 조정)·BaseEntityTest(read-only로 수정)·LayoutRenderingTest·RedisPropertiesTest·exception advice
- [ ] secret 하드코딩 0, 비밀번호 원문 저장/로그 0, refresh 원문 저장 0(hash), notif:* 참조 0, notification 코드/DB 참조 0, Controller 비즈니스 로직 0, Entity 응답 직접 반환 0, V1 사후 수정 0
- [ ] `./gradlew test` 전체 통과 (+ 구현자 docker 수동: V2 validate·redis-cli keys)

## 에이전트 분담
- 본 Task는 화면(Thymeleaf) 신규 작업 없음 → **backend-implementor 단독** 수행. 기존 View 로그인 흐름은 비파괴 유지(View 체인·`auth/login` 템플릿은 변경 없음).
- 한 에이전트가 **보안(security 필터체인/JWT/Redis)·member 도메인(Entity/Service/UserDetailsService/Controller/ServiceResponse)·V2 마이그레이션·BaseEntity DB소유 정렬**을 일관 처리한다(인증 소스 전환·시간 컬럼 소유권·role 매핑이 상호 의존하므로 분리 시 정합 깨짐).
- 구현 시 별도 확인(메인 에이전트 취합): (1) citext ↔ String validate 통과(docker PG), (2) jjwt 0.12.x 버전·API, (3) test 컨텍스트에서 Redis 자동설정/StringRedisTemplate 빈이 contextLoads를 깨지 않는지, (4) V2 적용 후 `User.role` enum validate 통과, (5) SecurityConfigTest의 DB 사용자 조달 방식이 View 체인에서 정상 동작.

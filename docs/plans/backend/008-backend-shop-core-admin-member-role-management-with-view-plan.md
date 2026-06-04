# 008. shop-core 관리자 회원 권한 관리 + 관리자 화면 — 구현 Plan

> 영역: backend + view (REST 관리자 회원 목록/권한변경 API + Thymeleaf 관리자 화면 + member 도메인 검색/권한변경 로직 + 권한 변경 후 로그인상태 무효화 + 관리자 전용 인가 + 테스트)
> 대상 프로젝트: shop-core (member 도메인 + security 인가 + 템플릿). notification 무관, 이벤트 계약 변경 없음.
> 작성일: 2026-06-03
> 상태: plan only (코드 변경 없음)
> 선행: Task 006(JWT 로그인 + Role hierarchy + RefreshTokenStore + REST/View 체인 분리) 산출물 위에 **자립적으로** 구축한다. **Task 007(회원가입)은 plan만 존재하고 코드 미구현이므로 의존하지 않는다.** 007 계획 산출물(`SignupForm`/`MemberServiceResponse`/`MemberRestController`/`members/me`)을 전제하지 않으며, 008 신규 컨트롤러/DTO는 `Admin*` prefix로 007 계획 파일들과 이름이 겹치지 않아 향후 007 구현 시 공존 가능하다.

---

## 구현 목표

`shop-core` `member` 모듈에 `ADMIN` 전용 회원 관리 기능을 **REST API**(`GET /api/v1/admin/members` 목록·검색·필터·페이지네이션, `PATCH /api/v1/admin/members/{memberId}/role` 권한 변경)와 **Thymeleaf 관리자 화면**(`GET /admin/members` 목록·검색 UI, `POST /admin/members/{memberId}/role` 변경 폼)으로 구현한다. 회원 검색·권한 변경의 도메인 로직(검색 쿼리·role 불변식·로그인상태 무효화)은 `MemberService`에 단일 소유하고 REST/View 진입점이 공유한다. 인가는 Spring Security 필터체인 path 기반(`/api/v1/admin/**`, `/admin/**` → `hasRole("ADMIN")`)으로 처리하며, 권한 변경 성공 시 대상 사용자의 refresh를 즉시 무효화한다(access는 만료 후 반영 — 작업 문서/주석에 명시).

---

## 영향 범위

### 신규 파일 (main — Java)

**member.dto**
- `shop-core/src/main/java/com/shop/shop/member/dto/MemberSummaryResponse.java` — 회원 목록 항목 DTO(`record`, `from(User)`, 민감정보 미포함)
- `shop-core/src/main/java/com/shop/shop/member/dto/RoleChangeRequest.java` — REST PATCH 바디 DTO(`record`, `@NotNull Role role`)
- `shop-core/src/main/java/com/shop/shop/member/dto/MemberSearchCondition.java` — 검색 조건 폼 백킹 객체(가변 class, View `@ModelAttribute` + REST 쿼리 바인딩 공용)
- `shop-core/src/main/java/com/shop/shop/common/dto/PageResponse.java` — 경량 페이지 응답 래퍼(`record<T>`, REST 직렬화 안정용) *(공통 위치 — §2 결정)*

**member.service**
- `shop-core/src/main/java/com/shop/shop/member/service/AdminMemberServiceResponse.java` — REST 응답 조합 전용(ServiceResponse 레이어) — 목록/권한변경

**member.controller**
- `shop-core/src/main/java/com/shop/shop/member/controller/AdminMemberRestController.java` — `@RestController` `/api/v1/admin/members` 진입점
- `shop-core/src/main/java/com/shop/shop/member/controller/AdminMemberViewController.java` — `@Controller` `/admin/members` 진입점(목록·권한변경 폼) — **backend-implementor 작성**

**common.exception**
- `shop-core/src/main/java/com/shop/shop/common/exception/MemberNotFoundException.java` — 대상 회원 없음(404), `BusinessException` 상속
- `shop-core/src/main/java/com/shop/shop/common/exception/RoleChangeNotAllowedException.java` — role 변경 불변식 위반(409/400), `BusinessException` 상속(상태코드 인자 또는 사유별 정적 팩토리 — §2)

### 신규 파일 (main — 템플릿)
- `shop-core/src/main/resources/templates/admin/members.html` — 관리자 회원 목록 화면(view name `admin/members`, `layout/base` 적용) — **view-implementor 작성**

### 신규 파일 (test)
- `shop-core/src/test/java/com/shop/shop/member/service/MemberServiceAdminTest.java` — 검색/필터(단위), role 변경 성공, 자기 ADMIN 강등 실패, 마지막 ADMIN 강등 실패, 불가 role 실패, 변경 성공 시 deleteRefresh 호출(Mockito)
- `shop-core/src/test/java/com/shop/shop/member/service/AdminMemberServiceResponseTest.java` — 목록 PageResponse 매핑·권한변경 위임(fake/mock)
- `shop-core/src/test/java/com/shop/shop/member/controller/AdminMemberRestControllerSecurityTest.java` — REST MockMvc: ADMIN 200, SELLER/CONSUMER 403, 비인증 401, PATCH 성공/404/409/400
- `shop-core/src/test/java/com/shop/shop/member/controller/AdminMemberViewControllerTest.java` — View MockMvc: ADMIN 렌더(목록/검색폼/변경폼), 성공 redirect+flash, 실패 flashError, 비권한 차단
- `shop-core/src/test/java/com/shop/shop/member/AdminMemberWiringTest.java` — 운영 배선 회귀(fake 미적용 대상 빈 등록 단언, P1/testing-rule)

### 수정 파일
- `shop-core/src/main/java/com/shop/shop/member/repository/MemberRepository.java` — 검색 쿼리(`@Query` keyword+role+Pageable) + `countByRole(Role)` 추가(`findById`는 `JpaRepository` 기본 제공 — 활용)
- `shop-core/src/main/java/com/shop/shop/member/service/MemberService.java` — `searchMembers(...)`·`changeRole(...)`·(View principal 통일용) `getByEmail(...)` 추가(`@Transactional`)
- `shop-core/src/main/java/com/shop/shop/security/SecurityConfig.java` — REST 체인 `/api/v1/admin/**` `hasRole("ADMIN")`, View 체인 `/admin/**` `hasRole("ADMIN")` 추가(`anyRequest()` 앞, 기존 비파괴)
- `shop-core/src/main/resources/templates/fragments/nav.html` — `sec:authorize="hasRole('ADMIN')"` 관리자 링크 추가(기존 '홈' 마커 비파괴) — **view-implementor**
- `docs/entity/database_design.md` — (필요 시) §9 회원 검색 인덱스 보강 메모(§1.4 — 신규 마이그레이션 없이 메모만)

### 마이그레이션 — **불필요 (신규 SQL 없음)**
- `users.role` CHECK는 **Task 006의 `V2__users_role_hierarchy.sql`** 에서 이미 `ADMIN/SELLER/CONSUMER`로 정합됨. 본 Task는 컬럼/제약 변경이 없고 기존 컬럼(`email`/`name`/`role`/`created_at`) 조회·`role` UPDATE만 수행 → **V3 불필요**(Constraint "role CHECK는 V2로 이미 정합" 충족).

### 범위 밖 (명시적 제외 — YAGNI)
- `ADMIN` 승격 API/화면, `COMPANY` 권한 도입(Constraint 금지)
- public role 변경, 회원 가입/수정/탈퇴, 비밀번호 재설정
- access token 즉시 무효화를 위한 per-user token-version/access jti 전수 추적(§1.3 보류 근거)
- 회원 상세 화면, 권한 변경 이력 audit 테이블, 회원 정렬/엑셀 export
- 시드 ADMIN 계정 생성 코드(007 미구현 + 시드 부재 — 로컬 수동 검증은 docker PG 직접 INSERT로 대체, §5.6)

---

## 1. 설계 방식 및 이유

### 1.1 인가 적용 방식 — 필터체인 path 기반(`hasRole("ADMIN")`), `@PreAuthorize`는 미채택(기본)
- **결정**: 006의 두 체인 `authorizeHttpRequests`에 path 매처를 `anyRequest()` **앞에** 추가한다.
  - REST 체인(@Order(1), `/api/v1/**`): `.requestMatchers("/api/v1/admin/**").hasRole("ADMIN")`
  - View 체인(@Order(2)): `.requestMatchers("/admin/**").hasRole("ADMIN")`
- `hasRole("ADMIN")`은 006의 공유 `RoleHierarchy`(ROLE_ADMIN > ROLE_SELLER > ROLE_CONSUMER)와 결합해 **ADMIN만 통과**한다(SELLER/CONSUMER는 ADMIN을 함의하지 않으므로 차단 — api-authorization-rule "상위만 하위 함의"). `ROLE_` prefix는 `hasRole`이 자동 부여하므로 매처는 `"ADMIN"`으로 둔다.
- **실패 표현은 체인별로 분리**(006 계승):
  - REST: 비인증 → `RestAuthenticationEntryPoint`(401 ErrorResponse JSON), 권한부족 → `RestAccessDeniedHandler`(403 ErrorResponse JSON).
  - View: 비인증 → formLogin redirect(`/login`), 권한부족 → 403(View 체인 기본 — 필요 시 `error/4xx` 뷰, error-response-rule "View는 JSON 금지").
- **`@PreAuthorize` 미채택(기본)**: 본 Task는 엔드포인트 단위 권한이 단순(전부 ADMIN)하므로 체인 path 기반으로 충분하다. 006이 `@EnableMethodSecurity`를 이미 활성화했으나, 메서드 보안 중복 부여는 과설계 경계(YAGNI). 권한 판단을 Controller 비즈니스 로직(문자열 비교)으로 처리하지 않는다(api-authorization-rule 금지) — Security 설정에 위임한다.
- 비파괴: 신규 매처는 가산적이라 006 `SecurityConfigTest`/`AuthRestControllerSecurityTest`(기존 `/api/v1/auth/**`·View 체인) 동작에 영향 없음.

### 1.2 role 변경 도메인 불변식 — `MemberService.changeRole`에 단일 소유
`changeRole`은 `@Transactional` 쓰기 메서드로, 아래 불변식을 **순서대로** 검증한다(REST/View 공유, Controller에 로직 금지).
1. **대상 존재**: `memberRepository.findById(targetId)` → 없으면 `MemberNotFoundException`(404).
2. **변경 가능 target role 제한**: 요청 `newRole ∈ {SELLER, CONSUMER}`만 허용. `newRole == ADMIN`이면 `RoleChangeNotAllowedException`(400, "ADMIN 권한으로의 변경은 허용되지 않습니다.") — ADMIN 승격 금지(Constraint).
3. **자기 자신 ADMIN 강등 금지**: `adminUserId == targetId && target.role == ADMIN`이면 `RoleChangeNotAllowedException`(409, "본인의 ADMIN 권한은 변경할 수 없습니다.").
4. **마지막 ADMIN 강등 금지**: `target.role == ADMIN && memberRepository.countByRole(ADMIN) <= 1`이면 `RoleChangeNotAllowedException`(409, "마지막 ADMIN 권한은 변경할 수 없습니다."). (3과 4는 둘 다 "ADMIN을 강등"하는 케이스이므로 target이 ADMIN일 때만 평가.)
5. **변경 적용**: `target.changeRole(newRole)`(Entity에 상태 변경 메서드 추가 — setter 대신 의도 노출 메서드) → JPA dirty checking으로 트랜잭션 커밋 시 UPDATE.
6. **로그**: 성공/실패 로그를 민감정보 없이 남긴다(예: `log.info("role 변경: adminUserId={}, targetId={}, {} -> {}", adminUserId, targetId, oldRole, newRole)`). password_hash/token 등 미로그.
- 시그니처(기본): `void changeRole(long adminUserId, long targetId, Role newRole)`. `adminUserId`는 "행위 관리자"(자기 강등 차단용) — REST/View 모두 동일 시그니처로 호출(principal 통일은 §1.3).
- `COMPANY` 등 미존재 enum은 컴파일 단계에서 차단(Role enum에 없음 — Constraint).

### 1.3 권한 변경 후 로그인 상태 정책 + principal 통일 (Task 필수)
- **결정**: 변경 성공 시 **대상 사용자의 refresh를 즉시 무효화**한다 — `refreshTokenStore.deleteRefresh(targetId)`(006 인터페이스 메서드). 이후 대상은 access 만료 시 refresh 재발급이 막혀 재로그인해야 새 권한이 반영된다.
- **access token은 만료(≤ access TTL 30분)까지 기존 권한으로 동작**한다. access는 role 클레임을 담고(006) 서명 검증만으로 통과하며, 현 구조에 access jti 전수 추적/per-user token-version이 없어 즉시 무효화는 과설계다 → **보류**(작업 문서/주석에 "access는 만료 후 반영" 명시 — Task Requirement "즉시 반영 안 하면 명시" 충족).
- **deleteRefresh 호출 위치**: **DB role 변경 커밋 후** 호출한다. 근거: Redis는 비트랜잭셔널(롤백 불가)이라 트랜잭션 내부에서 호출 후 DB 롤백 시 refresh만 사라지는 불일치가 생긴다. 변경이 확정된 뒤 무효화하는 편이 안전하며, 만에 하나 deleteRefresh 실패 시에도 "재로그인 강제"는 benign(보안상 더 보수적). 구현(기본): `MemberService.changeRole`을 `@Transactional`로 DB 변경만 수행하고, refresh 무효화는 **트랜잭션 커밋 이후**(`TransactionSynchronization afterCommit` 또는 메서드 말미 호출 + 주석)에서 호출. member→security 의존(순환 없음, 006 확인: `AuthServiceResponse`가 이미 `RefreshTokenStore` import)으로 호출 가능.
- **principal 통일(REST vs View 차이 — 중요)**: "행위 관리자 userId"를 양 진입점에서 동일하게 `changeRole`에 전달한다.
  - **REST**(JWT 필터): principal = userId(long). `AdminMemberServiceResponse`가 `(long) authentication.getPrincipal()`로 직접 추출(006 `AuthServiceResponse.me` 동일 규약).
  - **View**(form login 세션): principal = `UserDetails`(username = email). `AdminMemberViewController`가 세션 email로 `MemberService.getByEmail(email)` → `User.getId()`를 얻어 `adminUserId`로 통일. 이 차이를 §8 계약·주석에 명시한다.

### 1.4 목록 검색/필터/페이지네이션 — Repository `@Query` + `Pageable`
- **결정**: `MemberRepository`에 검색 쿼리를 `@Query`(JPQL)로 추가한다. 조건: `keyword`(email **또는** name 부분일치, optional/null) + `role`(optional/null) + `Pageable`. 반환 `Page<User>`.
  - email은 citext라 like 비교가 대소문자 무시되고, name은 `lower(u.name) like lower(concat('%', :keyword, '%'))`로 대소문자 무시. null 파라미터는 `(:keyword is null or ...)` / `(:role is null or u.role = :role)`로 무조건 통과 처리.
  - `countByRole(Role role)` derived query 추가(마지막 ADMIN 판별용, §1.2 4번).
- **결정 — Specification 대신 `@Query`**: 검색 조건이 2개(keyword, role)로 고정·소규모라 Criteria/Specification은 과설계(YAGNI). `@Query` 정적 JPQL이 가독·테스트 용이. 조건이 늘면 후속에 Specification 승격.
- 인덱스: `users`에는 현재 검색 전용 인덱스가 없다. role 필터는 `(role)` 인덱스, email/name like는 부분일치라 인덱스 효율이 낮다. **본 Task는 신규 마이그레이션을 만들지 않으므로**(role CHECK는 V2 정합) 인덱스 추가는 보류하고, database_design.md §9에 "관리자 회원 검색용 `(role)` 인덱스는 데이터 증가 시 후속 마이그레이션으로 추가 검토" 메모만 남긴다(과설계 회피).

### 1.5 REST 페이지 응답 — 경량 `PageResponse<T>` record
- **결정**: REST는 Spring `Page`를 직접 직렬화하지 않고 `PageResponse<T>(List<T> content, int page, int size, long totalElements, int totalPages)` record로 감싼다.
- 근거: Spring Boot 3.3+는 `Page`(`PageImpl`) 직접 직렬화 시 불안정 구조 경고를 낸다. `PagedModel`(spring-hateoas) 도입은 의존·표면 증가로 과함(YAGNI). 경량 record가 명시적·안정적이며 본 Task 응답 형태(content + 페이지 메타)에 충분.
- 위치: `common.dto.PageResponse`(횡단 — 후속 목록 API 재사용). `AdminMemberServiceResponse`가 `Page<User>` → `PageResponse<MemberSummaryResponse>`로 변환(Entity 직접 노출 금지).

### 1.6 DTO/응답 — 민감정보 미노출
- `MemberSummaryResponse(long memberId, String email, String name, String role, OffsetDateTime createdAt)` — `password_hash`/refresh/token 등 **절대 미포함**. `from(User u)` 정적 팩토리(`u.getRole().name()` 문자열, `u.getCreatedAt()`). createdAt 타입은 `User`/`BaseEntity` getter 타입에 맞춘다(`Instant`면 `Instant`로 — **구현 시 확인**, 006 BaseEntity가 DB 소유 읽기전용 매핑).
- `RoleChangeRequest(@NotNull Role role)` — REST PATCH 바디. `Role` enum 역직렬화로 미정의 값은 400(`HttpMessageNotReadableException` → RestExceptionHandler). SELLER/CONSUMER만 허용·ADMIN 거부는 §1.2 서비스 불변식이 최종 책임(검증 애너테이션만으로는 enum 부분집합 강제가 번거로워 서비스에서 처리 — 일관 단일 소유).
- `MemberSearchCondition`(가변 class, `@Getter @Setter @NoArgsConstructor`) — `String keyword; Role role; int page = 0; int size = 20;`. View `@ModelAttribute("searchCondition")` 바인딩(검색폼 echo) + REST 쿼리 파라미터 바인딩 공용. (REST는 record 대신 이 class를 쿼리 바인딩에 재사용하거나, REST는 개별 `@RequestParam`으로 받아도 무방 — **구현 시 택1**, 기본: View는 class 바인딩, REST는 개별 `@RequestParam`으로 명시.)
- Entity를 API 응답·View 모델에 직접 전달 금지(architecture-rule/forbidden-rule) — 항상 DTO 변환.

### 1.7 레이어 분리 (REST vs View, 도메인 로직 단일 소유)
- **공통 도메인 로직**: `MemberService.searchMembers(keyword, role, pageable)` / `changeRole(adminUserId, targetId, newRole)` / `getByEmail(email)`에 단일 소유. Repository는 여기서만 호출.
- **REST 레이어**: `AdminMemberRestController(@RestController, /api/v1/admin/members)` → `AdminMemberServiceResponse`(ServiceResponse, REST 전용) → `MemberService` → `MemberRepository`.
  - `GET ""`: `@RequestParam`(keyword/role/page/size) → `adminMemberServiceResponse.search(...)` → `PageResponse<MemberSummaryResponse>`(200).
  - `PATCH "/{memberId}/role"`: `@Valid @RequestBody RoleChangeRequest` + `Authentication` → `adminMemberServiceResponse.changeRole(auth, memberId, req)` → 200(또는 204). Controller 비즈니스 로직 금지.
- **View 레이어**: `AdminMemberViewController(@Controller)` → `MemberService` 직접(ServiceResponse 미사용 — architecture-rule).
  - `GET "/admin/members"`: `@ModelAttribute("searchCondition") MemberSearchCondition cond` → `memberService.searchMembers(...)` → model `members`(= `Page<MemberSummaryResponse>`)·`searchCondition` → view `"admin/members"`. 모델엔 DTO/ViewModel만(Entity 금지).
  - `POST "/admin/members/{memberId}/role"`: `@RequestParam("role") Role role` + `Authentication`(세션 email→adminUserId, §1.3) + `RedirectAttributes ra` → `memberService.changeRole(...)` → 성공 시 `ra.addFlashAttribute("flashSuccess", ...)` → `redirect:/admin/members`. 실패(`BusinessException`) catch → `ra.addFlashAttribute("flashError", e.getMessage())` → `redirect:/admin/members`(JSON 금지 — Constraint). flash 키는 기존 messages 프래그먼트 규약(`flashSuccess`/`flashError`) 사용.

---

## 2. 구성 요소

### main — member.repository (수정)

**`MemberRepository`** (기존 `findByEmail` + `JpaRepository<User,Long>` 기본 `findById`/`save`)
```java
@Query("""
    select u from User u
    where (:keyword is null or :keyword = ''
           or u.email like concat('%', :keyword, '%')
           or lower(u.name) like lower(concat('%', :keyword, '%')))
      and (:role is null or u.role = :role)
    """)
Page<User> search(@Param("keyword") String keyword, @Param("role") Role role, Pageable pageable);

long countByRole(Role role);
```
- email은 citext라 like가 대소문자 무시. **구현 시 확인**: citext 컬럼에 대한 JPQL `like`가 PG에서 정상 동작하는지(docker PG). 막히면 native query 또는 `lower()` 비교로 조정.

### main — member.service (수정)

**`MemberService`** (기존 `authenticate`/`getById` 비파괴 + 추가)
```java
@Transactional(readOnly = true)
public Page<User> searchMembers(String keyword, Role role, Pageable pageable) { ... }

@Transactional(readOnly = true)
public User getByEmail(String email) {                 // View principal(email→userId) 통일용
    return memberRepository.findByEmail(email)
        .orElseThrow(() -> new MemberNotFoundException(...));
}

@Transactional
public void changeRole(long adminUserId, long targetId, Role newRole) {
    // §1.2 불변식: 존재(404) → newRole ADMIN 거부(400) → 자기 ADMIN(409) → 마지막 ADMIN(409) → 적용 + 로그
    // (refresh 무효화는 커밋 후 — §1.3)
}
```
- `changeRole`은 도메인 불변식 단일 소유. `RefreshTokenStore` 주입(member→security, 순환 없음)으로 `deleteRefresh(targetId)`를 커밋 후 호출(§1.3).
- 비밀번호/토큰 미로그.

**`AdminMemberServiceResponse`** (신규, `@Service @RequiredArgsConstructor`) — REST 전용
- 의존: `MemberService`.
- `PageResponse<MemberSummaryResponse> search(String keyword, Role role, int page, int size)` → `memberService.searchMembers(...)` → `Page<User>` → map(`MemberSummaryResponse::from`) → `PageResponse.of(...)`.
- `void changeRole(Authentication auth, long memberId, RoleChangeRequest req)` → `long adminUserId = (long) auth.getPrincipal();` → `memberService.changeRole(adminUserId, memberId, req.role())`.

### main — member.controller

**`AdminMemberRestController`** (신규, `@RestController @RequestMapping("/api/v1/admin/members") @RequiredArgsConstructor`)
- `GET ""`: `@RequestParam(required=false) String keyword, @RequestParam(required=false) Role role, @RequestParam(defaultValue="0") int page, @RequestParam(defaultValue="20") int size` → `ResponseEntity.ok(serviceResponse.search(...))`(200).
- `PATCH "/{memberId}/role"`: `@PathVariable long memberId, @Valid @RequestBody RoleChangeRequest req, Authentication auth` → `serviceResponse.changeRole(auth, memberId, req)` → `ResponseEntity.ok().build()`(200) 또는 `noContent()`(204). 비즈니스 로직 없음.

**`AdminMemberViewController`** (신규, `@Controller @RequestMapping("/admin/members") @RequiredArgsConstructor`) — backend-implementor 작성
- 의존: `MemberService`.
- `@GetMapping`: `@ModelAttribute("searchCondition") MemberSearchCondition cond` → `Page<MemberSummaryResponse> members = memberService.searchMembers(...).map(MemberSummaryResponse::from)` → `model.addAttribute("members", members)` → `"admin/members"`. (검색조건 모델 키 `searchCondition`은 `@ModelAttribute`로 자동 추가.)
- `@PostMapping("/{memberId}/role")`: `@PathVariable long memberId, @RequestParam("role") Role role, Authentication auth, RedirectAttributes ra`:
  - `long adminUserId = memberService.getByEmail(auth.getName()).getId();`(principal 통일, §1.3)
  - `try { memberService.changeRole(adminUserId, memberId, role); ra.addFlashAttribute("flashSuccess", "권한이 변경되었습니다."); } catch (BusinessException e) { ra.addFlashAttribute("flashError", e.getMessage()); }`
  - `return "redirect:/admin/members";`
- view name/redirect 반환, 모델엔 DTO/ViewModel만(Entity 금지).

### main — member.dto / common.dto
- `MemberSummaryResponse`(record, `from(User)`, 민감정보 0) — §1.6.
- `RoleChangeRequest`(record, `@NotNull Role role`) — §1.6.
- `MemberSearchCondition`(가변 class, keyword/role/page/size, getter/setter) — §1.6.
- `common.dto.PageResponse<T>`(record, content/page/size/totalElements/totalPages + 정적 팩토리 `of(...)`) — §1.5.

### main — common.exception (신규)
- `MemberNotFoundException extends BusinessException` — `super("회원을 찾을 수 없습니다.", HttpStatus.NOT_FOUND)`(404).
- `RoleChangeNotAllowedException extends BusinessException` — 사유별 HTTP 분기 필요: ADMIN 승격(400), 자기/마지막 ADMIN(409). **결정**: 정적 팩토리(`forbiddenPromotion()`=400, `selfDemotion()`/`lastAdmin()`=409)로 메시지·상태 캡슐화. `RestExceptionHandler`가 status로 ErrorResponse 변환.

### main — security (수정)
**`SecurityConfig`**
- REST 체인 `authorizeHttpRequests`: `anyRequest().authenticated()` **앞에** `.requestMatchers("/api/v1/admin/**").hasRole("ADMIN")` 추가.
- View 체인 `authorizeHttpRequests`: `anyRequest().authenticated()` **앞에** `.requestMatchers("/admin/**").hasRole("ADMIN")` 추가.
- `RoleHierarchy`/엔트리포인트/denied 핸들러/JWT 필터/formLogin/CSRF는 006 그대로(비파괴).

### main — 템플릿 (view-implementor 작성)
**`templates/admin/members.html`** (신규)
- 레이아웃: **`layout/base`**(인증된 관리자 화면 — full 레이아웃, nav 포함). 기존 base 프래그먼트 시그니처 준수.
- 검색 폼: `<form method="get" th:action="@{/admin/members}" th:object="${searchCondition}">` — `keyword` 텍스트 입력(`th:field="*{keyword}"`), `role` 셀렉트(ALL/ADMIN/SELLER/CONSUMER, `th:field="*{role}"`), 제출. (검색은 GET이라 CSRF 불요.)
- 목록 테이블: `members.content` 반복 → email/name/role/createdAt 컬럼. 페이지네이션(`members.number`/`members.totalPages`).
- 권한 변경 폼: 각 행에 `<form method="post" th:action="@{/admin/members/{id}/role(id=${m.memberId})}">` — `_csrf` 자동 주입(View 체인 CSRF 활성), `role` 셀렉트 옵션 **SELLER/CONSUMER만**(ADMIN 옵션 없음 — §1.2), 제출 버튼.
- 메시지: 기존 `fragments/messages`(키 `flashSuccess`/`flashError`) 프래그먼트 사용.
- 비밀번호 hash/token 등 민감정보 미표시(Constraint).

**`templates/fragments/nav.html`** (수정 — view-implementor)
- 기존 '홈' 링크(LayoutRenderingTest 마커) **보존** + `<a sec:authorize="hasRole('ADMIN')" th:href="@{/admin/members}">회원 관리</a>` 추가(`thymeleaf-extras-springsecurity6`의 `sec:authorize` — 006 RoleHierarchy로 ADMIN만 노출). 기존 `nav(active)` 시그니처·'홈' 텍스트 비파괴.

### test — §5

---

## 3. 데이터 흐름

### 3.1 View 목록 조회/검색
```
GET /admin/members?keyword=&role=SELLER&page=0&size=20  (인증 + ADMIN)
  → View 체인: 인증(form session) + /admin/** hasRole ADMIN 통과
  → AdminMemberViewController.list(@ModelAttribute searchCondition)
       → MemberService.searchMembers(keyword, role, PageRequest.of(page,size))
            → MemberRepository.search(...) → Page<User>
       → .map(MemberSummaryResponse::from)  (Entity → DTO)
  → model: members(DTO 페이지), searchCondition → view "admin/members"
  (비인증 → /login redirect, 비ADMIN → 403)
```

### 3.2 View role 변경 성공/실패 (+로그인상태 무효화)
```
POST /admin/members/42/role  role=SELLER  (인증 + ADMIN + CSRF)
  → AdminMemberViewController.changeRole
       → adminUserId = memberService.getByEmail(auth.getName()).getId()  (principal 통일)
       → memberService.changeRole(adminUserId, 42, SELLER)
            → findById(42) (없으면 MemberNotFoundException)
            → newRole==ADMIN? no
            → target.role==ADMIN && self/last? no
            → target.changeRole(SELLER) (커밋 시 UPDATE)
            → [커밋 후] refreshTokenStore.deleteRefresh(42)  (대상 재로그인 강제, access는 만료 후 반영)
       → flashSuccess → redirect:/admin/members
  실패(불변식 위반/대상없음) → catch BusinessException → flashError → redirect:/admin/members
  (JSON 아님 — flash + 화면 재조회)
```

### 3.3 REST 목록 200
```
GET /api/v1/admin/members?keyword=kim&role=CONSUMER&page=0&size=20  Bearer{access, ROLE_ADMIN}
  → REST 체인 JwtAuthenticationFilter(006): SecurityContext(userId, ROLE_ADMIN)
  → /api/v1/admin/** hasRole ADMIN 통과
  → AdminMemberRestController.list → AdminMemberServiceResponse.search
       → memberService.searchMembers → Page<User> → PageResponse<MemberSummaryResponse>
  → 200 PageResponse(content[…민감정보 0…], page, size, totalElements, totalPages)
```

### 3.4 REST PATCH 권한 변경 (성공/403/401/409/400)
```
PATCH /api/v1/admin/members/42/role  {"role":"SELLER"}  Bearer{ROLE_ADMIN}
  → 인가 통과 → AdminMemberServiceResponse.changeRole(auth,42,req)
       → adminUserId=(long)principal → memberService.changeRole(adminUserId,42,SELLER)
  → 200 (또는 204)

비인증(토큰 없음/위조) → JwtFilter 미설정 → 401 RestAuthenticationEntryPoint(ErrorResponse JSON)
SELLER/CONSUMER 토큰   → hasRole ADMIN 실패 → 403 RestAccessDeniedHandler(ErrorResponse JSON)
대상 없음              → MemberNotFoundException → 404 ErrorResponse
자기/마지막 ADMIN 강등 → RoleChangeNotAllowedException → 409 ErrorResponse
role=ADMIN/미정의 값   → RoleChangeNotAllowedException(400) / HttpMessageNotReadable(400) → 400 ErrorResponse
```

---

## 4. 예외 처리 전략

| 상황 | 예외/처리 | HTTP | 반환 경로(REST) | 반환 경로(View) |
|---|---|---|---|---|
| 비인증 접근 | filter 미설정 → EntryPoint | 401 | `RestAuthenticationEntryPoint` → ErrorResponse JSON | formLogin redirect `/login` |
| 권한 부족(SELLER/CONSUMER) | `AccessDeniedException` | 403 | `RestAccessDeniedHandler` → ErrorResponse JSON | 403(View, `error/4xx` — JSON 금지) |
| 대상 회원 없음 | `MemberNotFoundException` | 404 | `RestExceptionHandler` → ErrorResponse | catch → `flashError` + redirect |
| ADMIN 승격 요청 | `RoleChangeNotAllowedException`(400) | 400 | `RestExceptionHandler` → ErrorResponse | catch → `flashError` + redirect |
| role 미정의 값(역직렬화) | `HttpMessageNotReadableException` | 400 | `RestExceptionHandler` → ErrorResponse | (View는 `Role` 바인딩 실패 → flashError) |
| 자기 ADMIN 강등 | `RoleChangeNotAllowedException`(409) | 409 | `RestExceptionHandler` → ErrorResponse | catch → `flashError` + redirect |
| 마지막 ADMIN 강등 | `RoleChangeNotAllowedException`(409) | 409 | `RestExceptionHandler` → ErrorResponse | catch → `flashError` + redirect |
| 검증 실패(@Valid `@NotNull role`) | `MethodArgumentNotValidException` | 400 | `RestExceptionHandler` → ErrorResponse | — |

- 모든 예외는 `RuntimeException` 상속 커스텀(`BusinessException` 계열)으로 변환(공통 규칙). 내부 정보(스택트레이스/SQL/토큰/hash) 응답·로그 미노출(error-response-rule, Constraint).
- **REST 에러 JSON ↔ View flash redirect 엄격 분리**(error-response-rule 적용범위 — JSON은 `/api/v1/**`만). View 실패는 절대 JSON 반환 안 함(006 체인 분리 유지).

---

## 5. 검증 방법

> 실행 위치: `shop-core/`. 명령: `./gradlew test`. Redis는 `FakeRefreshTokenStore`(@Import, @Primary)로 격리. `@SpringBootTest` 류는 `@Import(FakeRefreshTokenStore.class)` + `@MockBean MemberRepository, MemberUserDetailsService` 컨벤션 준수(006 패턴). 실 DB 없이 test profile 기동.

### 5.1 단위 테스트 (Mockito)
- `MemberServiceAdminTest`:
  - `searchMembers`: keyword/role 조합으로 `repository.search(...)` 위임·파라미터 전달 검증(repository mock).
  - `changeRole` 성공: target SELLER→CONSUMER 등 정상 변경 시 `target.getRole()` 갱신 + **`refreshTokenStore.deleteRefresh(targetId)` 호출**(커밋 후 단계 mock 검증).
  - **자기 ADMIN 강등 실패**: `adminUserId==targetId && target=ADMIN` → `RoleChangeNotAllowedException`(409), UPDATE/deleteRefresh 미호출.
  - **마지막 ADMIN 강등 실패**: `target=ADMIN && countByRole(ADMIN)==1` → 409, 미변경.
  - **불가 role 실패**: `newRole=ADMIN` → `RoleChangeNotAllowedException`(400), 미변경.
  - **대상 없음**: `findById` empty → `MemberNotFoundException`(404).
- `AdminMemberServiceResponseTest`: search → `PageResponse<MemberSummaryResponse>` 매핑(content에 민감정보 필드 부재 단언) + page 메타; changeRole → principal(long) 추출 후 `memberService.changeRole(adminUserId,...)` 위임.

### 5.2 Security/REST MockMvc (`AdminMemberRestControllerSecurityTest`)
- `GET /api/v1/admin/members`: **ADMIN(@WithMockUser(roles="ADMIN") 또는 Bearer ROLE_ADMIN) → 200** + PageResponse 구조; **SELLER → 403**, **CONSUMER → 403**(ErrorResponse JSON); **비인증 → 401**(ErrorResponse JSON, redirect 아님).
- `PATCH /api/v1/admin/members/{id}/role`: ADMIN 성공 200/204; 대상 없음 → 404; 자기/마지막 ADMIN → 409; `role=ADMIN` → 400; `@NotNull` 누락 → 400; SELLER/CONSUMER → 403; 비인증 → 401.
- 응답 본문에 **password_hash/token 미포함** jsonPath 부재 단언.
- `MemberRepository` @MockBean stub(search/countByRole/findById). REST principal=userId(long) 규약으로 `changeRole` 자기 강등 케이스 구성.

### 5.3 View MockMvc (`AdminMemberViewControllerTest`)
- `GET /admin/members`(@WithMockUser(roles="ADMIN")) → 200, view `admin/members`, model `members`·`searchCondition` 존재, **검색 폼·권한변경 폼 렌더**(목록/검색/변경 폼 마커), 민감정보 미표시.
- 검색: `?keyword=kim&role=SELLER` → `searchMembers` 호출 인자 검증.
- `POST /admin/members/{id}/role`(`with(csrf())`, role=SELLER) → 302 `redirect:/admin/members`, `flashSuccess` flash, `memberService.changeRole(adminUserId,...)` 호출(adminUserId가 세션 email→getByEmail로 통일됐는지 — getByEmail stub).
- 실패(service가 `RoleChangeNotAllowedException` throw stub) → 302 redirect + `flashError` flash(JSON 아님).
- **권한 없는 사용자 차단**: SELLER/CONSUMER `GET /admin/members` → 403; 비인증 → `/login` redirect(302). (View 체인 인가 — SecurityConfig 매처 반영.)

### 5.4 운영 배선 회귀 (`AdminMemberWiringTest`, P1/testing-rule)
- `@SpringBootTest`(test profile, `@Import(FakeRefreshTokenStore.class)` + `@MockBean MemberRepository, MemberUserDetailsService`)로 컨텍스트 기동 후 `context.getBean(AdminMemberRestController.class)`, `AdminMemberServiceResponse.class`, `AdminMemberViewController.class` 등록 단언. **신규 진입 빈은 fake 대체 대상이 아니므로 운영 구현체가 그대로 등록됨**(fake가 신규 배선을 가리지 않음을 확인 — 006 `RefreshTokenStoreWiringTest`·testing-rule 계승). `RefreshTokenStore`는 운영 구현(`RedisRefreshTokenStore`) 배선이 006 `RefreshTokenStoreWiringTest`로 이미 보장됨 — 본 Task는 그 빈을 변경하지 않음.

### 5.5 기존 테스트 비파괴
- `SecurityConfigTest`(006, View 체인 a~e+CSRF): `/admin/**` 매처 추가는 가산적 — 기존 공개/인증 경로 동작 비파괴.
- `AuthRestControllerSecurityTest`(006): `/api/v1/auth/**`·`/me` 영향 없음(admin 매처는 별도 경로).
- `LayoutRenderingTest`: `nav.html` 수정이 **'홈' 마커·`nav(active)` 시그니처를 보존**(관리자 링크는 추가만). T1~T3 비파괴.
- `ModularityTests`(Modulith): member→security/common 횡단 의존 방향 유지(member→security는 006부터 존재), 모듈 경계 위반 0.
- `ShopCoreApplicationTests.contextLoads`: 신규 빈 의존 운영 해결.

### 5.6 수동/docker 검증 (CI 외, 구현자)
- ADMIN 계정 부재(007 미구현·시드 없음) → **docker PG에 직접 INSERT**(email/`password_hash`=BCrypt/`role='ADMIN'`)로 e2e 수동 검증(시드 코드 신규 작성은 범위 밖, Task 008 명시). 로그인 후 `GET /admin/members` 렌더·검색·role 변경 → DB `role` 변경 + `redis-cli` `shopcore:auth:refresh:{targetId}` 삭제 확인. `ddl-auto=validate`로 User Entity(V2 기준) 정합.

### 5.7 Acceptance Criteria 대 검증 매핑
| Acceptance | 검증 |
|---|---|
| ADMIN 목록 화면 접근 | 5.3 GET 200 view admin/members |
| SELLER/CONSUMER/비인증 화면 접근 불가 | 5.3 SELLER/CONSUMER 403 + 비인증 /login redirect |
| email/name/role/createdAt 표시 | 5.3 목록 렌더 마커 + 5.1 MemberSummaryResponse |
| 검색/role 필터 사용 | 5.3 검색 인자 + 5.1 searchMembers |
| role SELLER/CONSUMER 변경 | 5.1 changeRole 성공 + 5.2 PATCH 200 + 5.3 POST redirect |
| 변경 후 DB role 변경 | 5.1 target.getRole() 갱신 + 5.6 docker |
| 자기 ADMIN 강등 실패 | 5.1 self 409 + 5.2 PATCH 409 |
| 마지막 ADMIN 강등 실패 | 5.1 last 409 + 5.2 PATCH 409 |
| 관리자 REST API ADMIN만 | 5.2 ADMIN 200 / SELLER·CONSUMER 403 / 비인증 401 |
| 응답·화면 민감정보 미노출 | 5.2 jsonPath 부재 + 5.3 미표시 |
| 로그인 상태 정책 구현/명시 | 5.1 deleteRefresh 호출 + §1.3(access 만료 후 반영 명시) + 5.6 redis-cli |
| 관련 테스트 통과 | `./gradlew test` 그린 |

---

## 6. 트레이드오프
- **인가: 체인 path 기반(`hasRole`) vs `@PreAuthorize`** — 채택 path 기반: (장) 엔드포인트 단순(전부 ADMIN), 006 스타일 일관, 한곳 추적. (단) 메서드 단위 세분화 불가. 미채택 `@PreAuthorize`: 본 Task 권한이 단순해 중복·과설계.
- **로그인 상태: refresh 무효화(채택) vs 완전 즉시(token-version/access blacklist 전수) vs 만료 후 반영(미조치)** — 채택 refresh 무효화: (장) 재로그인 강제로 새 권한 반영, 006 `deleteRefresh` 재사용, 비용 0. (단) access는 TTL(≤30분)까지 기존 권한. 미채택 완전 즉시: access jti 전수 추적/token-version 인프라 필요 — 과설계. 미채택 무조치: 정책 부재.
- **페이지 응답: 경량 `PageResponse`(채택) vs Spring `Page` 직접 vs `PagedModel`** — 채택 경량: (장) Boot 3.3+ Page 직렬화 경고 회피, 의존 0, 명시적. (단) 래퍼 1개. 미채택 Page 직접: 경고·불안정 구조. 미채택 PagedModel: 의존·표면 과함.
- **검색 구현: `@Query`(채택) vs Specification** — 채택 `@Query`: (장) 조건 2개 고정·가독·테스트 용이·YAGNI. (단) 동적 조건 확장성 낮음. 미채택 Specification: 현 규모에 과함(후속 승격).
- **role 변경 로직 위치: `MemberService` 단일(채택) vs Controller/ServiceResponse 분산** — 채택 단일: (장) REST/View 공유, 불변식 한곳, Controller 로직 0(Constraint). (단) 시그니처에 adminUserId 전파. 미채택 분산: 중복·일관성 저하.
- **View 실패: redirect+flash(채택) vs 재렌더** — 채택 redirect+flash(PRG): (장) 새로고침 중복 제출 방지, 목록 최신 재조회, 기존 messages 프래그먼트 재사용. (단) flash 1회성. 미채택 재렌더: 검색 상태 보존엔 유리하나 본 Task는 변경 후 목록 갱신이 자연스러움.
- **principal 통일: View에서 email→userId 조회(채택) vs principal에 userId 보관** — 채택 조회: (장) 006 form session(UserDetails) 구조 비파괴, REST/View 동일 `changeRole` 시그니처. (단) 변경당 `getByEmail` 1회. 미채택 principal 변경: 006 View 체인 인증 모델 변경 위험.

---

## Spring Boot 컨벤션
- 패키지: `com.shop.shop.member.{controller|service|repository|domain|dto}`(member 모듈, 새 모듈 없음), `com.shop.shop.common.{exception|dto}`(횡단), `com.shop.shop.security`(인가 설정). package-structure-rule 준수.
- 어노테이션: `@RestController`/`@Controller`/`@RequestMapping`/`@GetMapping`/`@PatchMapping`/`@PostMapping`/`@PathVariable`/`@RequestParam`/`@RequestBody`/`@ModelAttribute`/`@Valid`, `@Service`/`@RequiredArgsConstructor`/`@Transactional`/`@Slf4j`, `@Query`/`@Param`, Bean Validation(`@NotNull`), Lombok `@Getter`/`@Setter`/`@NoArgsConstructor`. REST DTO·응답·PageResponse는 `record`, View 검색 폼은 가변 class.
- 레이어: REST `RestController → ServiceResponse → Service → Repository`(Controller 로직 금지, ServiceResponse REST 전용). View `ViewController → Service → Repository`(ServiceResponse 미사용, 모델 DTO/ViewModel만, Entity 금지). 도메인 로직 단일 소유(`MemberService`).
- 보안/데이터: ADMIN 전용 인가(SELLER/CONSUMER/비인증 차단), 자기/마지막 ADMIN 강등 차단, ADMIN 승격·COMPANY 금지, public role 변경 금지. 민감정보(hash/token/Redis 상태) 응답·View 미노출. 권한 변경 트랜잭션 안 수행 + 성공/실패 로그(민감정보 없이). REST ErrorResponse JSON ↔ View flash redirect 분리. notification 코드/DB 미참조, 이벤트 계약 변경 0, 신규 마이그레이션 0.

## 완료 조건 체크리스트
- [ ] `MemberRepository.search(keyword,role,Pageable)` + `countByRole(Role)` 추가(citext like 동작 확인)
- [ ] `MemberService.searchMembers`·`changeRole`(불변식 4종+로그+커밋 후 deleteRefresh)·`getByEmail` 추가(기존 authenticate/getById 비파괴)
- [ ] `MemberNotFoundException`(404)·`RoleChangeNotAllowedException`(400 승격/409 자기·마지막) 추가
- [ ] `MemberSummaryResponse`(record, 민감정보 0)·`RoleChangeRequest`(record, @NotNull)·`MemberSearchCondition`(가변 class)·`common.dto.PageResponse`(record)
- [ ] `AdminMemberServiceResponse`(search→PageResponse, changeRole REST principal=userId) — REST 전용
- [ ] `AdminMemberRestController`(GET 목록 200·PATCH role 200/204) — Controller 로직 0
- [ ] `AdminMemberViewController`(GET 목록·POST role, 세션 email→adminUserId 통일, flash redirect) — backend-implementor
- [ ] `SecurityConfig`: REST `/api/v1/admin/**` hasRole ADMIN, View `/admin/**` hasRole ADMIN(anyRequest 앞, 006 비파괴)
- [ ] `templates/admin/members.html`(layout/base, GET 검색폼 searchCondition·목록 email/name/role/createdAt·페이지·POST 변경폼 role 옵션 SELLER/CONSUMER+CSRF·messages 프래그먼트) — view-implementor
- [ ] `fragments/nav.html` `sec:authorize hasRole ADMIN` 관리자 링크 추가('홈' 마커·`nav(active)` 비파괴) — view-implementor
- [ ] 단위(검색/필터·role 변경 성공·자기 ADMIN 실패·마지막 ADMIN 실패·불가 role 실패·deleteRefresh 호출) + REST MockMvc(ADMIN 200·SELLER/CONSUMER 403·비인증 401·PATCH 성공/404/409/400) + View MockMvc(ADMIN 렌더·검색·POST redirect+flash·실패 flashError·비권한 차단) + 배선 회귀(AdminMemberWiringTest)
- [ ] 기존 비파괴: SecurityConfigTest·AuthRestControllerSecurityTest·LayoutRenderingTest(nav '홈' 마커)·ModularityTests·contextLoads
- [ ] 민감정보 응답/View 노출 0, ADMIN 전용 인가, 자기/마지막 ADMIN 강등 차단, ADMIN 승격·COMPANY·public role 변경 0, Controller 비즈니스 로직 0, Entity 응답/모델 직접 전달 0, 신규 마이그레이션 0, notification 참조 0, 이벤트 계약 변경 0
- [ ] `./gradlew test` 전체 통과(+구현자 docker: ADMIN INSERT e2e·DB role 변경·redis refresh 삭제·citext like·V2 validate)

## 에이전트 분담 (backend → view 순서)

**호출 순서**: backend-implementor 먼저(Repository·Service·DTO·PageResponse·예외·SecurityConfig·REST·`AdminMemberViewController`·테스트), 그다음 view-implementor(`admin/members.html`·`nav.html`·View 렌더링 단언). 근거: 모델 키(`members`/`searchCondition`)·`MemberSearchCondition` 필드·`MemberService` 시그니처·view name·redirect·flash 규약이 먼저 고정돼야 템플릿이 안정 바인딩(CLAUDE.md 백→화 순).

**같은 `.java` 동시편집 회피**: `AdminMemberViewController.java`(폼 처리·세션 email→adminUserId 통일·changeRole 호출·flash·redirect)는 **backend-implementor 단독** 작성. 템플릿(`admin/members.html`·`nav.html`)·정적·View 렌더링 단언 텍스트는 **view-implementor**. backend가 만든 모델 키·필드명·view name·폼 action에 템플릿을 맞춘다.

| 항목 | 값 | 담당 정합 |
|---|---|---|
| 목록 view name | `admin/members` | backend(컨트롤러 반환) ↔ view(템플릿 경로) |
| 템플릿 경로 | `templates/admin/members.html` | view |
| 레이아웃 | `layout/base`(full, nav 포함) | view |
| 검색 파라미터 | `keyword`,`role`,`page`,`size` | backend(MemberSearchCondition/@RequestParam) ↔ view(폼 필드) |
| 회원 목록 모델 키 | `members`(DTO 페이지) | backend(model) ↔ view(`th:each`) |
| 검색 조건 모델 키 | `searchCondition` | backend(@ModelAttribute name) ↔ view(`th:object`) |
| 권한 변경 폼 action / method | `POST @{/admin/members/{memberId}/role}` | view(템플릿) ↔ backend(매핑) |
| 권한 변경 필드명 | `role`(옵션 SELLER/CONSUMER만) | backend(@RequestParam) ↔ view(셀렉트) |
| 성공 redirect | `redirect:/admin/members` | backend |
| 메시지 키 | `flashSuccess`/`flashError`(messages 프래그먼트) | backend(flash) ↔ view(표시) |
| nav 관리자 링크 | `sec:authorize hasRole('ADMIN')` → `@{/admin/members}` | view(nav.html), backend(인가 매처) |
| `MemberService.changeRole` 시그니처 | `void changeRole(long adminUserId, long targetId, Role newRole)` | backend |
| `MemberService.searchMembers` 시그니처 | `Page<User> searchMembers(String keyword, Role role, Pageable pageable)` | backend |
| `MemberService.getByEmail` | `User getByEmail(String email)`(View principal 통일) | backend |
| `MemberSummaryResponse` 필드 | memberId/email/name/role/createdAt(민감정보 0) | backend |
| `RoleChangeRequest` 필드 | role(record, @NotNull) | backend |
| `PageResponse` 필드 | content/page/size/totalElements/totalPages | backend |
| REST 목록 | `GET /api/v1/admin/members` → 200 PageResponse | backend |
| REST 권한변경 | `PATCH /api/v1/admin/members/{memberId}/role` → 200/204 | backend |
| 인가 매처 | REST `/api/v1/admin/**`·View `/admin/**` hasRole ADMIN | backend |
| nav 보존 계약 | '홈' 링크·`nav(active)` 시그니처(LayoutRenderingTest) | view(비파괴) |

**구현 시 확인(메인 에이전트 취합)**:
1. **View principal=email→userId**: form login session principal이 `UserDetails`(username=email)이므로 `auth.getName()`→`getByEmail`→userId로 통일(REST는 principal=userId 직접). 두 경로가 동일 `changeRole(adminUserId,...)` 호출하는지.
2. **REST principal=userId(long)**: `(long) authentication.getPrincipal()`(006 `AuthServiceResponse.me` 규약)로 자기 강등 케이스 동작.
3. **Page 직렬화**: REST는 `PageResponse`(record) 사용 — Spring `Page` 직접 직렬화 안 함(Boot 3.3+ 경고 회피).
4. **citext like**: `MemberRepository.search`의 JPQL `like`가 citext email에서 대소문자 무시·정상 동작하는지(docker PG). 막히면 native/`lower()` 조정.
5. **createdAt 타입**: `MemberSummaryResponse.createdAt`을 `User`/`BaseEntity` getter 타입(006 DB 소유 읽기전용 매핑 — `Instant`/`OffsetDateTime`)에 정합.
6. **deleteRefresh 트랜잭션 경계**: DB role 변경 커밋 후 호출(Redis 롤백 불가) — `afterCommit` 또는 메서드 말미 호출 + 주석.

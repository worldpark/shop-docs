# 027. shop-core 판매자 신청·심사·승격 워크플로우 (with View) — 구현 Plan

> 영역: backend + view (판매자 self-service 신청 REST/View + ADMIN 심사 REST/View + `SellerApplication` 도메인 상태머신 + V5 마이그레이션 + 승인 시 008 `MemberService.changeRole` 재사용 승격 + 인가/자격 분리 + 테스트)
> 대상 프로젝트: shop-core (member 도메인 + web 레이어 + security 인가 + 템플릿). notification 무관, 이벤트 계약 변경 없음.
> 작성일: 2026-06-13
> 상태: plan only (코드 변경 없음)
> 선행/재사용: Task 006(JWT·RoleHierarchy·RefreshTokenStore·REST/View 체인 분리), Task 008(ADMIN 회원 권한 관리 — `MemberService.changeRole`·`AdminMemberFacade`·`AdminMemberViewController`·불변식·커밋 후 refresh 무효화 정책). **본 Task는 008 위에 "신청자 주도 온보딩 + 심사 상태머신"을 더하며 승인 시 008 `changeRole`을 그대로 호출한다. 008/006 산출물을 재구현하지 않는다.**

---

## 구현 목표

`shop-core` `member` 모듈에 **판매자 신청 → ADMIN 심사 → SELLER 승격** 워크플로우를 구현한다. `CONSUMER`가 사업자 정보를 담아 신청(`POST /api/v1/seller-applications`, `POST /seller-applications`)하고, 본인 신청 상태를 조회(`/seller-applications/me`)하며, `ADMIN`이 상태 필터로 목록을 조회(`/api/v1/admin/seller-applications`, `/admin/seller-applications`)하고 **승인 시 신청자를 008 `MemberService.changeRole(reviewerId, applicantId, SELLER)` 경로로 SELLER 승격**하거나 **반려**(사유 기록)한다. 신청 레코드(`reviewedBy`/`decidedAt`/`status`/`rejectReason`)가 곧 판매자 승격의 감사 기록이며 별도 감사 테이블은 만들지 않는다.

**설계 핵심 — 인가(authorization) ≠ 자격(eligibility)**: RoleHierarchy(`ADMIN>SELLER>CONSUMER`) 때문에 보안 계층에서 "CONSUMER만, 상위 차단"은 표현 불가하므로, 신청 엔드포인트의 보안 floor는 `authenticated`로 두고, "현재 role==CONSUMER만 신청 가능"은 **서비스 도메인 자격 규칙**으로 검증해 부적격(SELLER/ADMIN)은 **403이 아닌 409**로 거부한다.

---

## 영향 범위

### 신규 파일 (main — Java)

**member.domain**
- `shop-core/src/main/java/com/shop/shop/member/domain/SellerApplication.java` — `BaseEntity` 상속 Entity, 상태머신 메서드(`approve`/`reject`) 소유
- `shop-core/src/main/java/com/shop/shop/member/domain/SellerApplicationStatus.java` — `enum { PENDING, APPROVED, REJECTED }`

**member.repository**
- `shop-core/src/main/java/com/shop/shop/member/repository/SellerApplicationRepository.java` — PENDING 존재 체크·상태 필터 페이지 조회·본인 최신 신청 조회

**member.service**
- `shop-core/src/main/java/com/shop/shop/member/service/SellerApplicationService.java` — 신청/승인/반려 도메인 로직 단일 소유, 승인 시 `MemberService.changeRole` 재사용(단일 트랜잭션)
- `shop-core/src/main/java/com/shop/shop/member/service/SellerApplicationServiceResponse.java` — consumer REST 응답 조합 전용(ServiceResponse — 신청/내 신청 조회)
- `shop-core/src/main/java/com/shop/shop/member/service/AdminSellerApplicationServiceResponse.java` — admin REST 응답 조합 전용(ServiceResponse — 목록/승인/반려)
- `shop-core/src/main/java/com/shop/shop/member/service/SellerApplicationFacadeImpl.java` — `SellerApplicationFacade` 구현(신청자 View용, package-private)
- `shop-core/src/main/java/com/shop/shop/member/service/AdminSellerApplicationFacadeImpl.java` — `AdminSellerApplicationFacade` 구현(관리자 View용, package-private)

**member.spi**
- `shop-core/src/main/java/com/shop/shop/member/spi/SellerApplicationFacade.java` — 신청자 View용 published port. **Role enum 비노출** — 자격 결과를 scalar/DTO(`eligible`/`reason`/내 신청 상태 DTO)로 변환
- `shop-core/src/main/java/com/shop/shop/member/spi/AdminSellerApplicationFacade.java` — 관리자 View용 published port. 목록(DTO 페이지)·승인·반려를 `email`(String)·`status`(String)·scalar로 노출

**member.controller**
- `shop-core/src/main/java/com/shop/shop/member/controller/SellerApplicationRestController.java` — `@RestController /api/v1/seller-applications`(consumer)
- `shop-core/src/main/java/com/shop/shop/member/controller/AdminSellerApplicationRestController.java` — `@RestController /api/v1/admin/seller-applications`(admin)

**member.dto**
- `SellerApplicationRequest.java` — 신청 요청(record, 사업자 정보 + Bean Validation)
- `SellerApplicationResponse.java` — 내 신청/단건 상태 응답(record, `from(SellerApplication)`)
- `SellerApplicationSummaryResponse.java` — admin 목록 항목(record, `from(SellerApplication)`)
- `SellerApplicationEligibility.java` — View facade가 web으로 내리는 자격 결과(record `boolean eligible`, `String reason`)

**web.member**
- `shop-core/src/main/java/com/shop/shop/web/member/SellerApplicationViewController.java` — 신청 폼/제출/내 상태(`@Controller`)
- `shop-core/src/main/java/com/shop/shop/web/member/AdminSellerApplicationViewController.java` — 관리자 목록/승인/반려(`@Controller`)

### 신규 파일 (main — 마이그레이션)
- `shop-core/src/main/resources/db/migration/V5__seller_application.sql` — `seller_application` 테이블 + 부분 유니크 인덱스(`WHERE status='PENDING'`) + FK(users) + updated_at 트리거

### 신규 파일 (main — 템플릿, view-implementor)
- `templates/seller-applications/apply.html` — 신청 폼(자격 미달 시 안내 분기)
- `templates/seller-applications/me.html` — 내 신청 상태
- `templates/admin/seller-applications.html` — 관리자 심사 목록(상태 필터 + 승인/반려 폼)

### 신규 파일 (test)
- `member/service/SellerApplicationServiceTest.java` — 신청 자격(CONSUMER만, SELLER/ADMIN 409)·PENDING 중복 거부·승인 시 `changeRole(.., SELLER)` 1회 호출 인자검증·반려·비-PENDING 승인 멱등(Mockito)
- `member/domain/SellerApplicationTest.java` — 상태 전이 메서드 단언(approve/reject, 터미널 재전이 거부)
- `member/repository/SellerApplicationRepositoryTest.java` — `@DataJpaTest` + Testcontainers: 부분 유니크 인덱스가 PENDING 중복 차단·REJECTED 후 재신청 허용·V5 validate 정합
- `member/controller/SellerApplicationRestControllerSecurityTest.java` — consumer REST MockMvc(자격 409·소유권·401)
- `member/controller/AdminSellerApplicationRestControllerSecurityTest.java` — admin REST MockMvc(ADMIN 200·SELLER/CONSUMER 403·401·승인 후 role=SELLER)
- `web/member/SellerApplicationViewControllerTest.java` — 신청 폼/내 상태 렌더·폼 vs 안내 분기·제출 redirect
- `web/member/AdminSellerApplicationViewControllerTest.java` — 관리자 목록 렌더·승인/반려 redirect+flash·비권한 차단
- `member/SellerApplicationWiringTest.java` — 운영 배선 회귀(신규 진입 빈 등록 단언, verification-gate-rule §4)

### 수정 파일
- `shop-core/src/main/java/com/shop/shop/security/SecurityConfig.java` — REST/View 체인에 신청 경로 매처 추가(§1.1). admin 경로(`/api/v1/admin/**`·`/admin/**` hasRole ADMIN)는 008이 이미 커버하므로 **추가 매처 불필요**, 신청 경로만 `authenticated` floor 명시
- (영향 — 신규 Repository 빈 추가) 기존 풀컨텍스트 `@SpringBootTest` 중 `SellerApplicationRepository`를 컴포넌트 스캔으로 요구하게 되는 테스트에 `@MockitoBean SellerApplicationRepository` 추가(verification-gate-rule §4 — §5.5)

### 재사용·무변경
- `MemberService.changeRole(long adminUserId, long targetId, Role newRole)`(008) — 승인 승격에 그대로 호출. 불변식·커밋 후 `deleteRefresh` afterCommit·access 만료 후 반영 정책 재사용
- `MemberService.getByEmail`(View principal email→userId 통일), `MemberService.getById`(승인 시 신청자 현재 role 확인)
- `member/domain/Role`·`User`·`User.changeRole`, RoleHierarchy/JWT/Redis 정책, `common.dto.PageResponse`, `common.exception.BusinessException`/`RestExceptionHandler`/`ViewExceptionHandler`, `web.support.CurrentActor`/`CurrentActorResolver`, `fragments/messages.html`

### 범위 밖 (명시적 제외 — YAGNI / Constraint)
- 판매자 소유권/판매자 범위 인가(products·shipments `seller_id` 스코핑), COMPANY 권한, ADMIN 가입 흐름
- 사업자등록번호 외부 진위확인 API, 별도 감사 테이블, 신청 결과 알림(notification 이벤트·이메일 — 신규 이벤트 계약 0)
- 008의 직접 role 토글 변경, V1~V4 수정, JWT/Redis 로그인 상태 정책 재구현

---

## 1. 설계 방식 및 이유

### 1.1 인가 vs 자격(eligibility) 분리 — 보안 floor=authenticated, CONSUMER-only는 서비스 자격→409 (설계 핵심)
- **결정**: 신청 엔드포인트(`POST /api/v1/seller-applications`, `GET /api/v1/seller-applications/me`, `GET /seller-applications/apply`, `POST /seller-applications`, `GET /seller-applications/me`)의 **보안 계층 최소 권한은 `authenticated`**로 둔다. admin 심사 경로는 `ROLE_ADMIN`.
- **근거**: 본 프로젝트는 RoleHierarchy(`ROLE_ADMIN > ROLE_SELLER > ROLE_CONSUMER`, `SecurityConfig.roleHierarchy()`)를 쓰며 api-authorization-rule이 "상위 권한은 하위 권한 API에 접근 가능"을 명시한다. 따라서 `hasRole("CONSUMER")`는 ADMIN/SELLER도 통과시키므로 보안 계층에서 "CONSUMER만, 상위 차단"은 **표현 불가**(이는 규칙 위반이 아니라 의도된 함의). "CONSUMER만 신청"은 인가가 아니라 **도메인 자격 규칙**이다 — SELLER/ADMIN은 권한 부재가 아니라 *이미 동급 이상이라 신청 행위 자체가 무의미*하므로 거부된다.
- **SecurityConfig 매처(§2 security)**:
  - REST 체인: `/api/v1/admin/**` → `hasRole("ADMIN")`는 **008이 이미 존재**(line 78). `/api/v1/admin/seller-applications/**`가 그 아래 포함되므로 **추가 매처 불필요**. consumer 신청(`/api/v1/seller-applications/**`)은 `anyRequest().authenticated()`가 이미 커버하나, **의도 명시 + 회귀 가드**로 `anyRequest` 앞에 `.requestMatchers("/api/v1/seller-applications/**").authenticated()`를 가산 추가(005/016/018 전용 matcher 명시 선례 line 83~88).
  - View 체인: `/admin/**` → `hasRole("ADMIN")`는 **008이 이미 존재**(line 126) → admin 심사 화면 커버, 추가 불필요. 신청자 화면(`/seller-applications/**`)은 `anyRequest().authenticated()`가 커버하나 같은 이유로 `.requestMatchers("/seller-applications/**").authenticated()`를 가산 추가.
  - **금지**: 신청 화면을 `hasRole("CONSUMER")`로 묶지 않는다 — RoleHierarchy로 ADMIN/SELLER가 통과되며, *차단하면 "이미 SELLER/ADMIN" 안내 화면이 도달 불가*해진다(Task Requirement). 보안 floor는 `authenticated`로만.
- **자격 검증 위치**: `SellerApplicationService.apply(applicantUserId, request)`가 `memberService.getById(applicantUserId).getRole()`로 현재 role을 **명시 확인**하고 `CONSUMER`가 아니면 `SellerApplicationNotEligibleException`(409)을 던진다. RoleHierarchy 함의에 기대지 않는다.

### 1.2 008 changeRole 재사용 전략 — 승인은 단일 트랜잭션 안에서 changeRole 호출
- **결정**: `SellerApplicationService.approve(reviewerAdminId, applicationId)`를 `@Transactional` 쓰기 메서드로 두고, 내부에서 (a)신청 상태 전이 `application.approve(reviewerAdminId)` + (b)**`memberService.changeRole(reviewerAdminId, application.getUserId(), Role.SELLER)`** 를 **같은 트랜잭션**에서 호출한다. `MemberService.changeRole`은 `@Transactional`(Propagation.REQUIRED 기본)이라 호출자 트랜잭션에 **합류**한다 → 신청 상태 전이와 role 변경이 원자적으로 커밋/롤백된다.
- **근거**: Task가 "승인은 008 경로 재사용, 단일 트랜잭션, 재구현 금지"를 명시. `changeRole`이 이미 ① 대상 존재(404) ② ADMIN 승격 금지(400) ③ 자기 강등 금지(409) ④ 마지막 ADMIN 강등 금지(409) ⑤ 커밋 후 refresh 무효화(`afterCommit` → `deleteRefresh`)를 담고 있다. CONSUMER→SELLER 승격은 이 경로가 허용하며(② ADMIN 아님, ③④ target이 ADMIN이 아니라 미평가), 추가 불변식·로그인 정책을 새로 만들 필요가 없다.
- **afterCommit 타이밍(§6 트레이드오프 상세)**: `changeRole`이 등록하는 `afterCommit` 동기화는 **현재 외곽 트랜잭션이 커밋된 직후** 실행된다(합류 트랜잭션이므로 외곽 커밋 시점에 한 번에). 즉 신청 `APPROVED` 커밋 + role UPDATE 커밋이 모두 확정된 뒤 `deleteRefresh(applicantUserId)`가 호출된다 → 일관성 보장. afterCommit 실패 시에도 "재로그인 강제"는 benign(008 정책 그대로).
- **승인 시 신청자가 CONSUMER가 아닐 때(레이스)**: 승인 직전 admin 토글로 이미 SELLER가 된 경우 → §1.4 자격 재확인으로 graceful 처리(4xx 확정).

### 1.3 레이어 구성 — REST(Controller→ServiceResponse→Service→Repository) / View(Controller→spi facade→Service)
- **공통 도메인 로직**: `SellerApplicationService`가 신청/승인/반려/조회 로직과 상태머신 호출을 **단일 소유**. Repository·`MemberService`는 여기서만 호출.
- **REST 레이어**(architecture-rule):
  - consumer: `SellerApplicationRestController(@RestController /api/v1/seller-applications)` → `SellerApplicationServiceResponse` → `SellerApplicationService`. principal=userId(long) — `(long) auth.getPrincipal()`(006/008 규약).
  - admin: `AdminSellerApplicationRestController(@RestController /api/v1/admin/seller-applications)` → `AdminSellerApplicationServiceResponse` → `SellerApplicationService`. 승인/반려 시 reviewer adminUserId = `(long) auth.getPrincipal()`.
  - Controller 비즈니스 로직 0(forbidden-rule). ServiceResponse는 Entity→DTO 변환만, 비즈니스 위임.
- **View 레이어**(architecture-rule + package-structure-rule `web` 규칙):
  - `web`은 member 내부 Entity/Service/`Role` enum을 직접 참조할 수 없으므로 **spi facade 경유**. `SellerApplicationViewController` → `SellerApplicationFacade`, `AdminSellerApplicationViewController` → `AdminSellerApplicationFacade`. facade 구현체는 member 내부 `service` 패키지(package-private)에 배치.
  - **facade는 Role enum이 아닌 scalar/DTO 노출**(architecture-rule "포트는 자기 모듈 소유 DTO/scalar만"): `SellerApplicationFacade.checkEligibility(email) → SellerApplicationEligibility(boolean eligible, String reason)`. web은 `eligible`/`reason`으로만 폼 vs 안내를 분기하고, 현재 role/PENDING 판정 자체는 facade 구현(member.spi 구현)이 수행한다. View 진입점 principal은 `CurrentActor`(email)로 받아 facade에 String email 전달, facade가 `getByEmail`로 userId 해석.

### 1.4 상태머신 — PENDING→APPROVED|REJECTED (터미널), 도메인 메서드 소유
- **결정**: `SellerApplication.approve(long reviewerId)` / `reject(long reviewerId, String reason)`를 Entity 도메인 메서드로 두고 상태·`reviewedBy`·`decidedAt`·`rejectReason`을 함께 갱신한다(setter 금지, 의도 노출 메서드 — `User.changeRole` 선례). 비-PENDING에서 호출 시 `IllegalStateException`이 아닌 도메인 가드로 차단하되, **서비스가 상태를 먼저 확인**해 정책 분기(§1.6)한다.
- **비-PENDING 승인 처리 — 확정: 멱등 skip이 아닌 409(상태 충돌)로 거부**. 근거: APPROVED/REJECTED는 터미널이며 재심사는 의미가 부여돼야 하는 행위다. 멱등 skip은 "이미 처리됨"을 성공으로 위장해 ADMIN에게 잘못된 피드백을 준다. error-response-rule "상태 충돌→409"에 맞춰 `SellerApplicationStateConflictException`(409)으로 명시 거부한다. (단건 idempotent replay 요구는 Task 범위 밖.)
- **승인 시점 신청자 현재 role≠CONSUMER 처리 — 확정: 409**. 승인 직전 신청자가 이미 SELLER/ADMIN이 된 경우(admin 토글 레이스) → `memberService.getById(applicantUserId).getRole()`가 CONSUMER가 아니면 승인을 진행하지 않고 `SellerApplicationStateConflictException`(409, "신청자가 이미 판매자 이상 권한입니다.")로 거부하고 신청 상태는 그대로 둔다(ADMIN이 별도 처리). changeRole 자체는 SELLER→SELLER 재설정을 막지 않으나, 워크플로 의미상(신청자 = CONSUMER 전제) 서비스에서 선제 차단한다.

### 1.5 중복 신청 차단 — 부분 유니크 인덱스 + 제약 위반 흡수 (005 패턴)
- **결정**: Postgres **부분 유니크 인덱스** `CREATE UNIQUE INDEX uq_seller_application_pending ON seller_application (user_id) WHERE status='PENDING'`로 "사용자당 PENDING 1건" 불변식을 **DB 권위 가드**로 둔다(V1 line 84/140 부분 유니크 선례). `apply()`는 ① 사전 체크 `existsByUserIdAndStatus(userId, PENDING)` → 있으면 409, ② INSERT 시 경합으로 `DataIntegrityViolationException` 발생 시 catch → `SellerApplicationDuplicateException`(409)로 **흡수**(005 `CartService.getOrCreateCart`·`MemberService.signup` unique 복구 선례). REJECTED/APPROVED는 인덱스 대상 아님 → **REJECTED 후 재신청 허용**.
- **근거**: 사전 체크만으로는 동시 2건 신청 경합을 막지 못한다(TOCTOU). DB 부분 유니크가 최종 권위, 앱 사전 체크는 정상 경로의 빠른 실패용. 앱레벨 비관적 락은 과설계(§6).

### 1.6 DTO/민감정보 — Entity 비노출, 사업자 필드 확정
- **사업자 정보 필드 — 확정**: `businessName`(상호명, 필수), `businessRegistrationNumber`(사업자등록번호, 필수), `contactPhone`(담당자 연락처, 필수) **3개로 고정**. 외부 진위확인·추가 필드(대표자명/주소/업태 등) 도입 금지(Task Constraint "과도한 필드 금지"). 검증: `@NotBlank` + 사업자등록번호 형식은 **숫자 10자리 패턴(`@Pattern`)만**(외부 검증 없음).
- DTO는 모두 record, Entity를 응답/View 모델에 직접 전달 금지(architecture-rule/forbidden-rule). 비밀번호 hash·token·Redis 상태 미노출. 목록 응답은 신청자 식별(userId/email)·사업자 정보·상태·신청일만.
- `SellerApplicationResponse`(내 신청): `id, status, businessName, businessRegistrationNumber, contactPhone, rejectReason, createdAt, decidedAt`. `SellerApplicationSummaryResponse`(admin 목록): + `userId`·신청자 식별. 목록은 `PageResponse<SellerApplicationSummaryResponse>` 래핑(008 `PageResponse` 재사용).

### 1.7 /me 신청 이력 없음 정책 — 확정: REST는 404, View는 빈 안내 화면
- **REST `GET /api/v1/seller-applications/me` — 확정: 이력 없으면 404**. 근거: error-response-rule "리소스 없음→404". REST는 명시적 부재 신호가 클라이언트에 유용하며 빈 200보다 일관적. `SellerApplicationNotFoundException`(404).
- **View `GET /seller-applications/me` — 확정: 이력 없으면 빈 안내 화면(200)**. 근거: View는 404 에러 페이지보다 "아직 신청 내역이 없습니다 + 신청하기 링크"가 UX상 자연스럽다(facade가 `Optional`/nullable DTO 반환, controller가 null이면 안내 모드 모델로 렌더). REST 404 ↔ View 빈 화면 분리는 008 "REST JSON ↔ View flash/render 분리" 정신과 일관.
- `/me`는 role 자격 제한 없음(`authenticated`+소유권만) — 승격된 SELLER도 본인 APPROVED 이력 조회 가능(Task Requirement). 소유권: 항상 본인(principal userId) 신청만 조회(다른 사용자 신청 조회 경로 없음).

---

## 2. 구성 요소

### main — member.domain (신규)

**`SellerApplicationStatus`** — `enum { PENDING, APPROVED, REJECTED }`. DB 저장값=상수명(V5 CHECK), `@Enumerated(STRING)`.

**`SellerApplication`** (`@Entity @Table(name="seller_application")`, `extends BaseEntity`, `@Getter`, `@NoArgsConstructor(PROTECTED)`)
- 필드: `Long id`(IDENTITY), `Long userId`(FK users, `@Column(name="user_id")`), `@Enumerated(STRING) SellerApplicationStatus status`, `String businessName`, `String businessRegistrationNumber`, `String contactPhone`, `String rejectReason`(nullable), `Long reviewedBy`(nullable), `Instant decidedAt`(nullable). `createdAt`/`updatedAt`은 `BaseEntity`(DB 소유, insertable/updatable=false). **`decidedAt`은 도메인이 명시 set**(BaseEntity와 별개 — 심사 시각).
- 정적 팩토리: `static SellerApplication submit(long userId, String businessName, String businessRegistrationNumber, String contactPhone)` → status=PENDING.
- 상태 메서드:
  - `void approve(long reviewerId)` — status가 PENDING이 아니면 가드(서비스가 선제 확인하므로 방어적), `status=APPROVED; reviewedBy=reviewerId; decidedAt=Instant.now()`.
  - `void reject(long reviewerId, String reason)` — `status=REJECTED; reviewedBy=reviewerId; rejectReason=reason; decidedAt=Instant.now()`.
- 시그니처상 `Role`/Spring 타입 비참조(순수 도메인).

### main — member.repository (신규)

**`SellerApplicationRepository extends JpaRepository<SellerApplication, Long>`**
```java
boolean existsByUserIdAndStatus(long userId, SellerApplicationStatus status);

// 내 신청: 가장 최근 1건 (createdAt desc) — /me
Optional<SellerApplication> findFirstByUserIdOrderByCreatedAtDesc(long userId);

// admin 목록: 상태 필터(null=전체) + 페이지
@Query("""
    select sa from SellerApplication sa
    where (:status is null or sa.status = :status)
    """)
Page<SellerApplication> search(@Param("status") SellerApplicationStatus status, Pageable pageable);
```
- `findById`/`save`는 `JpaRepository` 기본.

### main — member.service (신규)

**`SellerApplicationService`** (`@Service @RequiredArgsConstructor @Slf4j`)
- 의존: `SellerApplicationRepository`, `MemberService`(현재 role 확인 + 승격 재사용).
- `@Transactional SellerApplication apply(long applicantUserId, SellerApplicationRequest req)`:
  1. 현재 role 확인: `memberService.getById(applicantUserId).getRole() != CONSUMER` → `SellerApplicationNotEligibleException`(409).
  2. PENDING 사전 체크: `existsByUserIdAndStatus(applicantUserId, PENDING)` → `SellerApplicationDuplicateException`(409).
  3. `save(SellerApplication.submit(...))` — try/catch `DataIntegrityViolationException` → `SellerApplicationDuplicateException`(409) 흡수(§1.5).
  4. 로그: `log.info("판매자 신청 제출: userId={}, applicationId={}", ...)`.
- `@Transactional(readOnly=true) SellerApplication getMyLatest(long userId)`: `findFirstByUserIdOrderByCreatedAtDesc` → 없으면 `SellerApplicationNotFoundException`(404)(REST 경로). *(View 경로는 facade가 Optional로 받아 안내 분기 — §1.7)*
- `@Transactional(readOnly=true) Optional<SellerApplication> findMyLatest(long userId)`: View facade용 nullable 조회.
- `@Transactional(readOnly=true) Page<SellerApplication> search(SellerApplicationStatus status, Pageable pageable)`: admin 목록.
- `@Transactional void approve(long reviewerAdminId, long applicationId)`:
  1. `findById` → 없으면 `SellerApplicationNotFoundException`(404).
  2. status != PENDING → `SellerApplicationStateConflictException`(409)(§1.4 비-PENDING 거부).
  3. 신청자 현재 role 재확인: `memberService.getById(app.getUserId()).getRole() != CONSUMER` → `SellerApplicationStateConflictException`(409)(§1.4 레이스).
  4. `memberService.changeRole(reviewerAdminId, app.getUserId(), Role.SELLER)` — **단일 트랜잭션 합류 승격**(§1.2). 008 불변식·커밋 후 deleteRefresh 재사용.
  5. `app.approve(reviewerAdminId)`(dirty checking UPDATE).
  6. 로그: `log.info("판매자 신청 승인: reviewerId={}, applicationId={}, applicantUserId={}", ...)`.
- `@Transactional void reject(long reviewerAdminId, long applicationId, String reason)`:
  1. `findById`→404, 2. status!=PENDING→409, 3. `app.reject(reviewerAdminId, reason)`, role 변경 없음. 로그.

**`SellerApplicationServiceResponse`** (`@Service @RequiredArgsConstructor`) — consumer REST 전용
- `SellerApplicationResponse apply(Authentication auth, SellerApplicationRequest req)`: `long uid=(long)auth.getPrincipal(); return SellerApplicationResponse.from(service.apply(uid, req));`
- `SellerApplicationResponse me(Authentication auth)`: `service.getMyLatest((long)auth.getPrincipal())` → `from` (404는 service가 던짐).

**`AdminSellerApplicationServiceResponse`** (`@Service @RequiredArgsConstructor`) — admin REST 전용
- `PageResponse<SellerApplicationSummaryResponse> list(String status, int page, int size)`: status(String)→enum(null=전체) 변환 후 `service.search(...).map(from)` → `PageResponse.of`.
- `void approve(Authentication auth, long id)`: `service.approve((long)auth.getPrincipal(), id)`.
- `void reject(Authentication auth, long id, RejectRequest req)`: `service.reject((long)auth.getPrincipal(), id, req.reason())`.

**`SellerApplicationFacadeImpl implements SellerApplicationFacade`** (package-private, `@Service`)
- 의존: `SellerApplicationService`, `MemberService`.
- `SellerApplicationEligibility checkEligibility(String email)`: `User u=memberService.getByEmail(email);` role!=CONSUMER → `new SellerApplicationEligibility(false, "이미 판매자 이상 권한입니다.")`; PENDING 존재 → `(false, "이미 심사 중인 신청이 있습니다.")`; else `(true, null)`. **Role enum을 web에 노출하지 않고 boolean/String만 반환**(§1.3).
- `void apply(String email, SellerApplicationRequest req)`: `service.apply(memberService.getByEmail(email).getId(), req)`(자격은 service가 재검증 — 409).
- `Optional<SellerApplicationResponse> findMyApplication(String email)`: `service.findMyLatest(getByEmail.getId()).map(SellerApplicationResponse::from)`.

**`AdminSellerApplicationFacadeImpl implements AdminSellerApplicationFacade`** (package-private, `@Service`)
- 의존: `SellerApplicationService`.
- `Page<SellerApplicationSummaryResponse> search(String status, int page, int size)`: status(String)→enum 변환(null=전체) → `service.search(...).map(from)`.
- `void approve(String adminEmail, long id)` / `void reject(String adminEmail, long id, String reason)`: adminEmail→userId(`memberService.getByEmail`) 후 `service.approve/reject`. *(reviewer principal 통일 — View는 email, REST는 userId.)*

### main — member.spi (신규, 인터페이스만)

**`SellerApplicationFacade`** (published port, `@NamedInterface("spi")` 패키지)
```java
SellerApplicationEligibility checkEligibility(String email);          // Role enum 비노출 — scalar/DTO
void apply(String email, SellerApplicationRequest req);
Optional<SellerApplicationResponse> findMyApplication(String email);  // View: 없으면 안내(§1.7)
```
**`AdminSellerApplicationFacade`**
```java
Page<SellerApplicationSummaryResponse> search(String status, int page, int size);   // status String
void approve(String adminEmail, long applicationId);
void reject(String adminEmail, long applicationId, String reason);
```
- 포트 시그니처는 web 타입(Authentication/Form)을 받지 않고 자기 모듈 DTO/scalar(String/long/`SellerApplication*Response`/`SellerApplicationEligibility`)만 노출(architecture-rule). web→member.spi 단방향.

### main — member.controller (신규)

**`SellerApplicationRestController`** (`@RestController @RequestMapping("/api/v1/seller-applications") @RequiredArgsConstructor`)
- `@PostMapping`: `@Valid @RequestBody SellerApplicationRequest req, Authentication auth` → `ResponseEntity.status(201).body(serviceResponse.apply(auth, req))`(201 Created).
- `@GetMapping("/me")`: `Authentication auth` → `ResponseEntity.ok(serviceResponse.me(auth))`(200, 없으면 404 from service).

**`AdminSellerApplicationRestController`** (`@RestController @RequestMapping("/api/v1/admin/seller-applications") @RequiredArgsConstructor`)
- `@GetMapping`: `@RequestParam(required=false) String status, @RequestParam(defaultValue="0") int page, @RequestParam(defaultValue="20") int size` → 200 `PageResponse<SellerApplicationSummaryResponse>`.
- `@PostMapping("/{id}/approve")`: `@PathVariable long id, Authentication auth` → `serviceResponse.approve(auth,id)` → 200.
- `@PostMapping("/{id}/reject")`: `@PathVariable long id, @Valid @RequestBody RejectRequest req, Authentication auth` → `serviceResponse.reject(auth,id,req)` → 200.
- Controller 비즈니스 로직 0.

### main — member.dto (신규)
- `SellerApplicationRequest(@NotBlank String businessName, @NotBlank @Pattern(regexp="\\d{10}", message="사업자등록번호는 숫자 10자리입니다.") String businessRegistrationNumber, @NotBlank String contactPhone)` — record.
- `RejectRequest(@NotBlank String reason)` — record(반려 사유 필수).
- `SellerApplicationResponse(long id, String status, String businessName, String businessRegistrationNumber, String contactPhone, String rejectReason, Instant createdAt, Instant decidedAt)` — record, `from(SellerApplication)`.
- `SellerApplicationSummaryResponse(long id, long userId, String status, String businessName, String businessRegistrationNumber, String contactPhone, Instant createdAt, Instant decidedAt)` — record, `from(SellerApplication)`. *(신청자 식별=userId. email 표시가 필요하면 facade/서비스에서 조인 매핑 — 본 plan은 민감정보 최소화 위해 userId만; Task "신청자 식별"은 userId로 충족.)*
- `SellerApplicationEligibility(boolean eligible, String reason)` — record(View facade 자격 결과, Role enum 비노출).

### main — common.exception (신규)
- `SellerApplicationNotEligibleException extends BusinessException` — `super("판매자 신청 자격이 없습니다(현재 권한 확인).", HttpStatus.CONFLICT)`(409).
- `SellerApplicationDuplicateException extends BusinessException` — `super("이미 심사 중인 신청이 있습니다.", HttpStatus.CONFLICT)`(409).
- `SellerApplicationStateConflictException extends BusinessException` — `super(msg, HttpStatus.CONFLICT)`(409, 비-PENDING 승인/반려·승인 레이스).
- `SellerApplicationNotFoundException extends BusinessException` — `super("판매자 신청을 찾을 수 없습니다.", HttpStatus.NOT_FOUND)`(404).
- 모두 `BusinessException` 상속 → `RestExceptionHandler`가 status로 ErrorResponse 변환(추가 핸들러 불필요). View는 `BusinessException` catch → flash(008 패턴).

### main — web.member (신규)

**`SellerApplicationViewController`** (`@Controller @RequestMapping("/seller-applications") @RequiredArgsConstructor @Slf4j`)
- 의존: `SellerApplicationFacade`, `CurrentActorResolver`.
- `@GetMapping("/apply")`: `Authentication auth` → `SellerApplicationEligibility e = facade.checkEligibility(auth.getName())` → `model.addAttribute("eligible", e.eligible()); model.addAttribute("reason", e.reason()); model.addAttribute("form", new SellerApplicationForm())` → view `seller-applications/apply`. **폼 vs 안내 분기**: 템플릿이 `eligible`로 폼/안내 렌더(보안 차단 아님 — §1.1).
- `@PostMapping`: `@Valid @ModelAttribute("form") SellerApplicationForm form, BindingResult br, Authentication auth, RedirectAttributes ra` → 검증 실패 시 재렌더; `try { facade.apply(auth.getName(), form.toRequest()); ra.addFlashAttribute("flashSuccess","신청이 접수되었습니다."); } catch (BusinessException e){ ra.addFlashAttribute("flashError", e.getMessage()); }` → `redirect:/seller-applications/me`.
- `@GetMapping("/me")`: `Authentication auth` → `Optional<SellerApplicationResponse> app = facade.findMyApplication(auth.getName())` → `app.ifPresentOrElse(a->model.addAttribute("application",a), ()->model.addAttribute("application",null))` → view `seller-applications/me`(없으면 안내, §1.7).
- *(web은 `SellerApplicationForm`을 web.member에 두고 `toRequest()`로 member DTO 변환 — 포트가 web Form 비참조, 변환은 web 책임(architecture-rule). **확정: web.member에 `SellerApplicationForm`(가변 class) 신규** + `toRequest()`.)*

**`AdminSellerApplicationViewController`** (`@Controller @RequestMapping("/admin/seller-applications") @RequiredArgsConstructor @Slf4j`)
- 의존: `AdminSellerApplicationFacade`.
- `@GetMapping`: `@RequestParam(required=false) String status, @RequestParam(defaultValue="0") int page, @RequestParam(defaultValue="20") int size, Model model` → `model.addAttribute("applications", facade.search(status,page,size)); model.addAttribute("status", status)` → view `admin/seller-applications`.
- `@PostMapping("/{id}/approve")`: `@PathVariable long id, Authentication auth, RedirectAttributes ra` → `try{ facade.approve(auth.getName(), id); ra.addFlashAttribute("flashSuccess","승인되었습니다."); }catch(BusinessException e){ ra.addFlashAttribute("flashError", e.getMessage()); }` → `redirect:/admin/seller-applications`.
- `@PostMapping("/{id}/reject")`: `@PathVariable long id, @RequestParam("rejectReason") String rejectReason, Authentication auth, RedirectAttributes ra` → `facade.reject(auth.getName(), id, rejectReason)` try/catch flash → redirect. (View action 필드 `rejectReason` — Backend-View Contract.)

### main — security (수정)
**`SecurityConfig`** (§1.1)
- REST 체인 `anyRequest().authenticated()` **앞에**: `.requestMatchers("/api/v1/seller-applications/**").authenticated()`(의도 명시·회귀 가드). admin REST는 line 78 `/api/v1/admin/**` hasRole ADMIN이 이미 커버 — **추가 없음**.
- View 체인 `anyRequest().authenticated()` **앞에**: `.requestMatchers("/seller-applications/**").authenticated()`. admin View는 line 126 `/admin/**` hasRole ADMIN이 이미 커버 — **추가 없음**.
- RoleHierarchy/엔트리포인트/핸들러/JWT/formLogin/CSRF는 006/008 그대로(비파괴). **신청 화면을 hasRole CONSUMER로 묶지 않는다**(§1.1).

### main — 마이그레이션 (신규)
**`V5__seller_application.sql`** (V1~V4 무변경, Flyway 소유, Hibernate validate)
```sql
-- V5__seller_application.sql — 판매자 신청 워크플로우 (Task 027)
-- [V5 불변 규칙] 적용 후 수정 금지. V1~V4 변경 없음.
CREATE TABLE seller_application (
    id                            bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id                       bigint       NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    status                        varchar(20)  NOT NULL
                                  CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED')),
    business_name                 text         NOT NULL,
    business_registration_number  text         NOT NULL,
    contact_phone                 text         NOT NULL,
    reject_reason                 text,
    reviewed_by                   bigint       REFERENCES users (id) ON DELETE SET NULL,
    decided_at                    timestamptz,
    created_at                    timestamptz  NOT NULL DEFAULT now(),
    updated_at                    timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX idx_seller_application_user_id ON seller_application (user_id);
CREATE INDEX idx_seller_application_status  ON seller_application (status);
-- 사용자당 PENDING 1건 (부분 유니크 — V1 line 84/140 선례). REJECTED/APPROVED 후 재신청 허용.
CREATE UNIQUE INDEX uq_seller_application_pending
    ON seller_application (user_id) WHERE status = 'PENDING';

-- updated_at 자동 갱신 (BaseEntity가 updatable=false로 매핑 → JPA 미기록 → 트리거 필수, V4 선례)
CREATE TRIGGER trg_seller_application_set_updated_at
    BEFORE UPDATE ON seller_application
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```
- 타입 정합: `user_id`/`reviewed_by` bigint = `users.id` bigint. `status` varchar(20)+CHECK ↔ `@Enumerated(STRING)`. `decided_at` timestamptz ↔ `Instant`. `created_at`/`updated_at` DB DEFAULT+트리거 ↔ `BaseEntity`(insertable/updatable=false). `business_*`/`contact_phone` text NOT NULL ↔ Entity 필드.

### main — 템플릿 (view-implementor)
**`templates/seller-applications/apply.html`** — `layout/base` 적용. `th:if="${eligible}"`이면 신청 폼(`method="post" th:action="@{/seller-applications}" th:object="${form}"`, `_csrf` 자동, `businessName`/`businessRegistrationNumber`/`contactPhone` 입력 + 검증 에러 표시), `th:unless="${eligible}"`이면 `reason` 안내 + 로그인/홈 링크(차단 아님). `fragments/messages`.
**`templates/seller-applications/me.html`** — `sellerApplication` 존재 시 status/사업자정보/rejectReason/createdAt/decidedAt 표시, null이면 "신청 내역 없음 + 신청하기(`/seller-applications/apply`)". `fragments/messages`. (모델 키는 `sellerApplication` — `application`은 Thymeleaf 암묵 scope 객체와 충돌하므로 사용 금지, E2E로 발견.)
**`templates/admin/seller-applications.html`** — `layout/base`. status 필터 폼(GET, ALL/PENDING/APPROVED/REJECTED), 목록 테이블(`applications.content` 반복: userId/사업자정보/status/createdAt), PENDING 행에만 승인/반려 폼(`POST .../{id}/approve`·`.../{id}/reject` + `rejectReason` 입력, `_csrf` 자동), 페이지네이션, `fragments/messages`. 008 `admin/members.html` 패턴 계승.

---

## 3. 데이터 흐름

### 3.1 (a) 신청 제출 — REST
```
POST /api/v1/seller-applications  {businessName,businessRegistrationNumber,contactPhone}  Bearer{ROLE_CONSUMER}
  → REST 체인 JwtFilter: SecurityContext(userId, ROLE_CONSUMER)
  → /api/v1/seller-applications/** authenticated 통과
  → SellerApplicationRestController.create(@Valid req, auth)
       → SellerApplicationServiceResponse.apply(auth, req)  [uid=(long)principal]
            → SellerApplicationService.apply(uid, req)
                 1) getById(uid).role != CONSUMER → 409 NotEligible
                 2) existsByUserIdAndStatus(uid,PENDING) → 409 Duplicate
                 3) save(submit(...))  (경합 시 DataIntegrityViolation → 409 Duplicate 흡수)
       → SellerApplicationResponse.from(saved)
  → 201 Created (민감정보 0)
  SELLER/ADMIN principal → 1)에서 409 (보안 403 아님 — 자격 규칙)
  비인증 → 401 RestAuthenticationEntryPoint(JSON)
```
### 3.1' (a') 신청 제출 — View (폼 vs 안내 분기)
```
GET /seller-applications/apply (인증, role 무관)
  → View 체인: /seller-applications/** authenticated 통과 (SELLER/ADMIN도 진입)
  → SellerApplicationViewController.applyForm(auth)
       → facade.checkEligibility(auth.getName()) → SellerApplicationEligibility(eligible,reason)
  → model: eligible/reason/form → view "seller-applications/apply"
       eligible=true  → 신청 폼 렌더
       eligible=false → reason 안내 렌더 (차단 아님)
POST /seller-applications (CSRF, @Valid form)
  → facade.apply(email, form.toRequest())  [service가 자격 409 재검증]
  → 성공 flashSuccess / 실패(BusinessException) flashError → redirect:/seller-applications/me
```
### 3.2 (b) 내 신청 조회
```
REST  GET /api/v1/seller-applications/me  Bearer{본인}
  → ServiceResponse.me(auth) → service.getMyLatest(uid)
       findFirstByUserIdOrderByCreatedAtDesc → 있으면 from(200) / 없으면 404 NotFound
  (SELLER로 승격된 본인도 APPROVED 조회 가능 — role 제한 없음, 소유권만)
View  GET /seller-applications/me → facade.findMyApplication(email)(Optional)
  → 있으면 application 모델 / 없으면 안내 화면(200, §1.7)
```
### 3.3 (c) 관리자 목록
```
GET /api/v1/admin/seller-applications?status=PENDING&page=0&size=20  Bearer{ROLE_ADMIN}
  → /api/v1/admin/** hasRole ADMIN(008 매처) 통과
  → AdminSellerApplicationRestController.list → AdminSellerApplicationServiceResponse.list
       status(String)→enum(null=전체) → service.search(status,pageable) → map(from) → PageResponse
  → 200 PageResponse<SellerApplicationSummaryResponse>
  SELLER/CONSUMER → 403, 비인증 → 401
View GET /admin/seller-applications → /admin/** hasRole ADMIN → facade.search → applications 모델 → view "admin/seller-applications"
```
### 3.4 (d) 승인 → changeRole 승격 (단일 트랜잭션, afterCommit refresh 무효화)
```
POST /api/v1/admin/seller-applications/42/approve  Bearer{ROLE_ADMIN}
  → ServiceResponse.approve(auth,42) [reviewerId=(long)principal]
  → [@Transactional 시작] SellerApplicationService.approve(reviewerId, 42)
       1) findById(42) → 없으면 404
       2) status != PENDING → 409 StateConflict (비-PENDING 거부, §1.4)
       3) getById(app.userId).role != CONSUMER → 409 StateConflict (레이스, §1.4)
       4) memberService.changeRole(reviewerId, app.userId, SELLER)  ← 008 합류(같은 TX)
            존재/ADMIN승격/자기·마지막ADMIN 불변식 통과(CONSUMER→SELLER) → User.changeRole(SELLER)
            afterCommit 동기화 등록(deleteRefresh(app.userId))  ← 아직 미실행
       5) app.approve(reviewerId)  (status=APPROVED, reviewedBy, decidedAt)
     [@Transactional 커밋] → role UPDATE + application UPDATE 원자 커밋
     → afterCommit 실행: refreshTokenStore.deleteRefresh(app.userId) (재로그인 강제, access 만료 후 반영)
  → 200
View POST /admin/seller-applications/42/approve → facade.approve(adminEmail,42)[email→reviewerId] → flash → redirect
```
### 3.5 (e) 반려
```
POST /api/v1/admin/seller-applications/42/reject  {reason}  Bearer{ROLE_ADMIN}
  → ServiceResponse.reject(auth,42,req) → service.reject(reviewerId,42,reason)
       1) findById→404  2) status!=PENDING→409  3) app.reject(reviewerId,reason) (REJECTED, role 변경 없음)
  → 200  (REJECTED는 부분 유니크 대상 아님 → 재신청 허용)
View POST /admin/seller-applications/42/reject (rejectReason) → facade.reject → flash → redirect
```

---

## 4. 예외 처리 전략

| 상황 | 예외/처리 | HTTP | REST 반환 | View 반환 |
|---|---|---|---|---|
| 비인증 접근(신청/me/admin) | filter 미설정 → EntryPoint | 401 | `RestAuthenticationEntryPoint`(JSON) | formLogin redirect `/login` |
| admin 경로 권한 부족(CONSUMER/SELLER) | `AccessDeniedException` | 403 | `RestAccessDeniedHandler`(JSON) | 403(View, JSON 금지) |
| 신청 부적격(현재 role SELLER/ADMIN) | `SellerApplicationNotEligibleException` | **409** | `RestExceptionHandler`→ErrorResponse | catch→flashError+redirect / apply 화면 안내 |
| PENDING 중복(사전 체크 + 경합 흡수) | `SellerApplicationDuplicateException` | **409** | ErrorResponse | catch→flashError+redirect |
| 비-PENDING 승인/반려(터미널) | `SellerApplicationStateConflictException` | **409** | ErrorResponse | catch→flashError+redirect |
| 승인 시 신청자 role≠CONSUMER(레이스) | `SellerApplicationStateConflictException` | **409** | ErrorResponse | catch→flashError+redirect |
| 신청 없음(/me·승인/반려 대상) | `SellerApplicationNotFoundException` | 404 | ErrorResponse | (View /me는 안내 화면 200 — §1.7 / 대상 없는 승인은 flashError) |
| 검증 실패(@Valid 사업자정보·reason) | `MethodArgumentNotValidException` | 400 | ErrorResponse | BindingResult 재렌더 / flashError |
| 승인 승격 시 008 불변식(ADMIN 승격 등) | `RoleChangeNotAllowedException`(008, 400/409) | 400/409 | ErrorResponse | catch→flashError (실제로는 CONSUMER→SELLER라 미발생) |

- 모든 예외는 `BusinessException` 상속 → `RestExceptionHandler` 한 곳 변환(error-response-rule, 추가 핸들러 0). View는 `BusinessException` catch→flash redirect(008 패턴), **절대 JSON 미반환**(error-response-rule 적용범위 `/api/v1/**`만).
- **409 채택 근거**(error-response-rule "상태 충돌→409"): 부적격(SELLER/ADMIN)은 권한 부재(403)가 아니라 *이미 동급 이상이라 신청이 무의미한 상태 충돌*이다(§1.1). 중복/비-PENDING/레이스도 모두 상태 충돌→409로 일관.
- 내부정보(스택/SQL/token/hash) 응답·로그 미노출.

---

## 5. 검증 방법

> 실행 위치: `shop-core/`. 명령: `./gradlew test`. 단위는 Mockito, DB 슬라이스는 `@DataJpaTest`+Testcontainers(PostgreSQL — citext/부분 유니크/CHECK는 H2 재현 불가, testing-rule §슬라이스). 풀컨텍스트 `@SpringBootTest`는 008 컨벤션(`@Import(FakeRefreshTokenStore.class)` + `@MockitoBean` repositories) 계승.

### 5.1 단위 (Mockito) — `SellerApplicationServiceTest`
- **신청 자격**: `getById` role=CONSUMER stub → `apply` 성공 + `repository.save` 1회 호출 인자검증. role=SELLER / role=ADMIN stub → `SellerApplicationNotEligibleException`(409), `save` 미호출.
- **PENDING 중복**: `existsByUserIdAndStatus(.,PENDING)=true` → `SellerApplicationDuplicateException`(409). `save`가 `DataIntegrityViolationException` throw stub → 같은 예외로 흡수 검증(409).
- **승인**: status=PENDING + 신청자 role=CONSUMER stub → `approve` 시 **`memberService.changeRole(reviewerId, applicantUserId, Role.SELLER)` 정확히 1회 호출** `ArgumentCaptor`로 인자(reviewerId/applicantUserId/SELLER) 검증 + `app.getStatus()==APPROVED`·`reviewedBy`·`decidedAt` 세팅.
- **비-PENDING 승인**: status=APPROVED/REJECTED stub → `SellerApplicationStateConflictException`(409), `changeRole` 미호출.
- **승인 레이스**: status=PENDING + 신청자 role=SELLER stub → 409, `changeRole` 미호출.
- **반려**: PENDING stub → `reject` 시 `app.getStatus()==REJECTED`·`rejectReason`·`reviewedBy` 세팅 + **`changeRole` 미호출** 검증. 비-PENDING 반려 → 409.
- `SellerApplicationServiceResponseTest`/`AdminSellerApplicationServiceResponseTest`: principal(long) 추출·DTO 매핑(민감정보 필드 부재 단언)·status String↔enum 변환 위임.

### 5.2 도메인 — `SellerApplicationTest`
- `submit` → status PENDING·필드 세팅. `approve(rid)` → APPROVED/reviewedBy/decidedAt. `reject(rid,reason)` → REJECTED/rejectReason. 터미널 상태 재전이 가드(approve 후 reject 호출 시 방어 동작) 단언.

### 5.3 슬라이스/통합 (`@DataJpaTest`+Testcontainers) — `SellerApplicationRepositoryTest`
- **부분 유니크 인덱스**: 동일 userId PENDING 2건 INSERT → 2번째 `DataIntegrityViolationException`(uq_seller_application_pending). PENDING 1건 + APPROVED/REJECTED 다건은 허용.
- **REJECTED 후 재신청 허용**: REJECTED 1건 존재 + 새 PENDING INSERT → 성공.
- **V5 validate 정합**: Testcontainers에 Flyway V1~V5 적용 + `ddl-auto=validate` 기동 성공(Entity↔테이블 타입 정합 — bigint FK·varchar CHECK·timestamptz·DB 소유 시간 컬럼).
- `existsByUserIdAndStatus`·`findFirstByUserIdOrderByCreatedAtDesc`·`search(status)` 쿼리 동작.

### 5.4 Security/REST (MockMvc)
- `SellerApplicationRestControllerSecurityTest`: `POST /api/v1/seller-applications` — CONSUMER 201, **SELLER/ADMIN 409**(보안 403 아님 — 자격), 비인증 401, @Valid 누락 400. `GET /me` — 본인(CONSUMER/SELLER 무관) 200, 없으면 404, 비인증 401. 응답 jsonPath에 passwordHash/token 부재 단언.
- `AdminSellerApplicationRestControllerSecurityTest`: 목록/approve/reject — ADMIN 200, CONSUMER/SELLER 403, 비인증 401. approve 성공 시 `memberService.changeRole(.., SELLER)` 호출(또는 통합에서 대상 role=SELLER 확인). reject 시 `reason` @Valid 400. principal=userId(long) 규약으로 reviewerId 전달 검증.

### 5.5 View (MockMvc) + 운영 배선 + 회귀
- `SellerApplicationViewControllerTest`: `GET /apply`(@WithMockUser CONSUMER) → 200 view `seller-applications/apply`, model `eligible`/`form`; SELLER/ADMIN 진입 시 `eligible=false`+`reason` 렌더(차단 아님). `POST /seller-applications`(csrf) → 302 redirect `/seller-applications/me`+flashSuccess; 자격 실패 stub → flashError. `GET /me` → application 있음/없음(안내) 분기 렌더. 비인증 → /login redirect.
- `AdminSellerApplicationViewControllerTest`: `GET /admin/seller-applications`(ADMIN) → 200 view + model `applications`/`status`; status 필터 인자 검증. `POST .../{id}/approve|reject`(csrf) → 302 redirect+flash. CONSUMER/SELLER → 403, 비인증 → /login.
- **조건부 가시성(PENDING 행에만 승인/반려 폼·apply 폼 vs 안내)은 MEMORY(verify-admin-list-page-features-with-e2e)·testing-rule에 따라 Playwright E2E로 검증**(MockMvc는 쿼리↔템플릿 가시성 공백을 놓침). E2E는 `e2eTest` 별도 태스크(e2e-runner 담당).
- `SellerApplicationWiringTest`(verification-gate-rule §4): `@SpringBootTest`(`@Import(FakeRefreshTokenStore.class)`+필요한 `@MockitoBean`)로 신규 진입 빈(`SellerApplicationRestController`/`AdminSellerApplicationRestController`/`SellerApplicationServiceResponse`/`AdminSellerApplicationServiceResponse`/`SellerApplicationService`/facade impl 2종/ViewController 2종) 운영 등록 단언.
- **회귀 — 신규 Repository 빈 파급(verification-gate-rule §4)**: `SellerApplicationRepository`(`@Repository`) 추가로 컴포넌트 스캔이 바뀌므로, **기존 풀컨텍스트 `@SpringBootTest`가 JPA repository를 `@MockitoBean`으로 스텁하는 패턴이면 `@MockitoBean SellerApplicationRepository`를 함께 추가**한다(008/기존 `*Repository` mock 관례). 008 admin role 관리·007 가입·006 로그인·`SecurityConfigTest`·`ModularityTests`(member→security/common 방향 유지, web→member.spi 단방향)·`contextLoads` 그린 유지.
- **동적 게이트(verification-gate-rule §2)**: 메인 에이전트가 `./gradlew test` 전체 `BUILD SUCCESSFUL`을 직접 확인. "pre-existing 실패" 주장은 baseline 대조(§3)로 검증. docker 수동: ADMIN/CONSUMER INSERT → 신청→승인→DB role=SELLER + redis refresh 삭제 + V5 validate + 부분 유니크 확인.

### 5.6 Acceptance 대 검증 매핑
| Acceptance | 검증 |
|---|---|
| CONSUMER 신청·본인 조회 | 5.1 apply 성공·5.4 POST 201·GET me 200 |
| SELLER/ADMIN·PENDING 중복 거부(409) | 5.1 NotEligible/Duplicate 409·5.4 409 |
| 승격 SELLER도 /me 조회 | 5.4 SELLER GET me 200 |
| 승인 시 SELLER 승격(changeRole) | 5.1 changeRole(.,SELLER) 1회·5.4 approve·docker role=SELLER |
| 반려 REJECTED·role 무변경·재신청 | 5.1 reject·5.3 REJECTED 후 재신청 |
| 보안 floor authenticated·admin ADMIN·자격 409 | 5.4 401/403/409 |
| 단일 트랜잭션·refresh 정책 | §1.2·5.1 changeRole 합류·docker redis |
| V5 부분 유니크·validate·민감정보 0·이벤트 무변경 | 5.3·5.1 DTO·범위 밖 명시 |

---

## 6. 트레이드오프

- **중복 차단: 부분 유니크 인덱스+제약 흡수(채택) vs 앱레벨 락** — 채택: (장) DB 권위 가드로 TOCTOU 경합까지 차단, V1 부분 유니크·005 흡수 선례, 비용 0, REJECTED 후 재신청 자연 허용. (단) 예외 흡수 코드 1곳. 미채택 비관적/분산 락: 현 규모 과설계, 인프라 부담.
- **부적격: 409(상태 충돌, 채택) vs 403(권한)** — 채택 409: (장) 인가≠자격 분리 명확화, RoleHierarchy 함의와 충돌 없음, "이미 동급 이상" 의미 정확(error-response-rule 상태충돌). (단) 통상 "거부=403" 직관과 다름 → Task/주석 명시로 보완. 미채택 403: RoleHierarchy로 보안 표현 불가 + 안내 화면 도달 차단.
- **/me 없음: REST 404 / View 빈 안내(채택) vs 양쪽 빈응답 vs 양쪽 404** — 채택 분리: (장) REST는 부재 신호 명시(error-response-rule), View는 UX상 안내+신청 링크가 자연(008 REST/View 분리 정신). (단) 두 경로 동작 차이 → §1.7·계약 명시. 미채택 통일: 한쪽 UX/일관성 손해.
- **승인: 단일 트랜잭션 changeRole 합류(채택) vs 분리 호출** — 채택 합류: (장) 신청 상태+role UPDATE 원자성, 008 afterCommit refresh 무효화가 외곽 커밋 후 정확히 1회 실행, 부분 성공 없음. (단) `changeRole`이 던지는 예외가 승인 트랜잭션 전체 롤백(의도된 동작). 미채택 분리(별 TX): role만 바뀌고 신청 미반영(또는 역) 불일치 위험.
- **비-PENDING 승인: 409 거부(채택) vs 멱등 skip vs 4xx 외 무처리** — 채택 409: (장) 터미널 상태 재심사 시도를 명시 거부, ADMIN에 정확 피드백, 일관된 상태충돌 매핑. (단) 동시 더블클릭 시 2번째 409(View flash로 흡수). 미채택 멱등 skip: "이미 처리"를 성공 위장 → 오인 유발.
- **승인 레이스(신청자 이미 SELLER): 409 거부(채택) vs 상태만 정리** — 채택 409: (장) 워크플로 전제(신청자=CONSUMER) 위반을 명시, ADMIN 수동 판단 유도. (단) 드문 케이스에 ADMIN 1회 개입. 미채택 자동 정리: 암묵 상태 변경으로 추적성 저하.
- **사업자 필드: 3개 고정(채택) vs 확장 집합** — 채택 최소(상호명/사업자번호/연락처): (장) Task "과도한 필드/외부 진위확인 금지" 준수, 검증 단순(숫자 10자리 패턴). (단) 실제 심사 정보 부족 → 후속 Task 확장 여지. 미채택 확장(대표자/주소/업태): 범위 초과·외부 검증 유혹.
- **목록 신청자 식별: userId(채택) vs email 조인** — 채택 userId: (장) 민감정보 최소, 추가 조인 0, Task "신청자 식별" 충족. (단) ADMIN이 userId만 봄 → 필요 시 후속에서 email 조인 매핑(범위 밖). 미채택 email 노출: 민감정보 표면 증가.

---

## Spring Boot 컨벤션
- 패키지: `com.shop.shop.member.{domain|repository|service|controller|dto|spi}`(member 모듈, 새 모듈 0), `com.shop.shop.web.member`(View 진입점), `com.shop.shop.common.{exception|dto}`(횡단), `com.shop.shop.security`. package-structure-rule 준수. facade 인터페이스=`member.spi`(@NamedInterface), 구현=`member.service` package-private.
- 어노테이션: `@RestController`/`@Controller`/`@RequestMapping`/`@GetMapping`/`@PostMapping`/`@PathVariable`/`@RequestParam`/`@RequestBody`/`@ModelAttribute`/`@Valid`, `@Service`/`@Repository`/`@RequiredArgsConstructor`/`@Transactional`/`@Slf4j`, `@Query`/`@Param`, `@Entity`/`@Table`/`@Id`/`@GeneratedValue(IDENTITY)`/`@Enumerated(STRING)`/`@Column`, Bean Validation(`@NotBlank`/`@Pattern`). REST DTO/응답=record, View Form=가변 class.
- 레이어: REST `RestController→ServiceResponse→Service→Repository`(Controller 로직 0), View `ViewController→spi facade→Service`(ServiceResponse 미사용, web은 Role enum/Entity 비참조, 모델 DTO/ViewModel만). 도메인 로직 단일 소유(`SellerApplicationService`). 승격은 008 `MemberService.changeRole` 재사용.
- 보안/데이터: 신청 floor=authenticated(자격은 서비스 409), admin=ROLE_ADMIN, /me 소유권 본인. 민감정보 미노출. 단일 트랜잭션 승인 + 008 refresh 무효화 재사용. V5 부분 유니크+CHECK, validate 정합, V1~V4 무변경. notification/이벤트 계약 무변경.

## 완료 조건 체크리스트
- [ ] `SellerApplication`(BaseEntity, submit/approve/reject 상태머신)·`SellerApplicationStatus` enum
- [ ] `SellerApplicationRepository`(existsByUserIdAndStatus·findFirstByUserIdOrderByCreatedAtDesc·search(status,Pageable))
- [ ] `SellerApplicationService`(apply 자격 CONSUMER 409·PENDING 중복 409 흡수 / approve 단일 TX changeRole(.,SELLER) 재사용·비-PENDING 409·레이스 409 / reject 409·role 무변경 + 로그)
- [ ] `SellerApplicationServiceResponse`(consumer)·`AdminSellerApplicationServiceResponse`(admin, status String↔enum, PageResponse) — Controller 로직 0
- [ ] `SellerApplicationFacade`(checkEligibility→`SellerApplicationEligibility`, Role 비노출)·`AdminSellerApplicationFacade`(search/approve/reject) + 구현 2종(member.service, package-private)
- [ ] `SellerApplicationRestController`(POST 201·GET /me)·`AdminSellerApplicationRestController`(목록·approve·reject)
- [ ] DTO: `SellerApplicationRequest`(@NotBlank+@Pattern)·`RejectRequest`·`SellerApplicationResponse`·`SellerApplicationSummaryResponse`·`SellerApplicationEligibility`(Entity 비노출)
- [ ] 예외 4종(`NotEligible`409·`Duplicate`409·`StateConflict`409·`NotFound`404) — BusinessException 상속
- [ ] `web/member` ViewController 2종(폼 vs 안내 분기·flash redirect·CurrentActor/email 통일) + web.member `SellerApplicationForm`
- [ ] `SecurityConfig`: REST/View 신청 경로 `authenticated` 가산 매처(admin은 008 매처 재사용, 신청 화면 hasRole CONSUMER 금지)
- [ ] `V5__seller_application.sql`(테이블+FK bigint+CHECK+부분 유니크 WHERE status='PENDING'+updated_at 트리거, V1~V4 무변경)
- [ ] 템플릿 3종(`seller-applications/apply`·`me`·`admin/seller-applications`, layout/base, messages 프래그먼트, 폼/안내·승인/반려 폼) — view-implementor
- [ ] 단위(자격/중복/승인 changeRole 1회 인자검증/비-PENDING·레이스 409/반려) + 도메인 상태전이 + @DataJpaTest(부분 유니크·REJECTED 재신청·V5 validate) + REST MockMvc(자격 409·ADMIN/403/401·승인 후 SELLER) + View MockMvc(분기·redirect+flash·차단) + E2E(조건부 가시성) + WiringTest
- [ ] 회귀: 신규 Repository 빈 파급 — 기존 풀컨텍스트 테스트 `@MockitoBean SellerApplicationRepository` 추가, 006/007/008/SecurityConfigTest/ModularityTests/contextLoads 그린
- [ ] 민감정보 0, 신청 floor authenticated+자격 409, admin ROLE_ADMIN, /me 소유권, 단일 TX 승격+008 refresh 정책, V5 정합, notification/이벤트 계약 무변경, Controller 로직 0, Entity 응답/모델 직접 전달 0
- [ ] `./gradlew test` 전체 `BUILD SUCCESSFUL`(메인 직접 확인) + docker(신청→승인 role=SELLER·redis refresh 삭제·부분 유니크·V5 validate)

## 에이전트 분담 (backend → view 순서)
**호출 순서**: backend-implementor 먼저(도메인·Repository·Service·ServiceResponse·facade+구현·DTO·예외·SecurityConfig·REST·ViewController·V5·테스트), 그다음 view-implementor(템플릿 3종·View 렌더링 단언). 근거: 모델 키(`eligible`/`reason`/`form`/`sellerApplication`/`applications`/`status`)·view name·폼 action·flash 규약·`SellerApplicationForm` 필드가 먼저 고정돼야 템플릿이 안정 바인딩(CLAUDE.md 백→화).
**동시편집 회피**: `web/member` ViewController 2종(폼 처리·email→facade·flash·redirect·분기)은 **backend-implementor 단독**. 템플릿·View 렌더링 단언 텍스트는 **view-implementor**.

| 항목 | 값 | 담당 정합 |
|---|---|---|
| 신청 폼 view | `seller-applications/apply`(model `eligible`/`reason`/`form`) | backend ↔ view |
| 신청 제출 | `POST /seller-applications` → redirect `/seller-applications/me` | backend(매핑) ↔ view(action) |
| 내 신청 view | `seller-applications/me`(model `sellerApplication`, null=안내; `application`은 Thymeleaf 예약 scope와 충돌 — 회피) | backend ↔ view |
| 관리자 목록 view | `admin/seller-applications`(model `applications`/`status`) | backend ↔ view |
| 목록 필터 | `status`/`page`/`size` | backend(@RequestParam) ↔ view(폼) |
| 승인/반려 action | `POST /admin/seller-applications/{id}/approve`·`/reject`(필드 `rejectReason`) | view ↔ backend |
| 성공 redirect(admin) | `/admin/seller-applications` | backend |
| flash 키 | `flashSuccess`/`flashError`(messages 프래그먼트) | backend ↔ view |
| 인가 매처 | REST `/api/v1/seller-applications/**` authenticated·admin은 008 `/api/v1/admin/**`·View `/seller-applications/**` authenticated·admin은 `/admin/**` | backend |
| facade 노출 | `SellerApplicationEligibility(eligible,reason)`·DTO만(Role enum 비노출) | backend |
| 승격 호출 | `memberService.changeRole(reviewerId, applicantUserId, Role.SELLER)`(단일 TX 합류) | backend |

**구현 시 확인(메인 취합)**:
1. **changeRole 합류 트랜잭션**: `SellerApplicationService.approve`의 `@Transactional`에 `MemberService.changeRole`(REQUIRED)이 합류해 원자 커밋되는지, 008 afterCommit `deleteRefresh`가 외곽 커밋 후 1회 실행되는지(단위 mock + docker redis).
2. **V5 정합/validate**: bigint FK·varchar(20) CHECK·timestamptz·부분 유니크(`WHERE status='PENDING'`)가 Entity(@Enumerated STRING·BaseEntity insertable/updatable=false)와 validate 정합(Testcontainers).
3. **부분 유니크 경합 흡수**: 사전 체크 통과 후 동시 INSERT의 `DataIntegrityViolationException`이 409로 흡수되는지(005 선례).
4. **신규 Repository 빈 파급**: 기존 풀컨텍스트 `@SpringBootTest`가 `SellerApplicationRepository`를 요구해 컨텍스트 로드가 깨지지 않도록 `@MockitoBean` 추가(verification-gate-rule §4).
5. **principal 통일**: REST=userId(long, `(long)auth.getPrincipal()`), View=email(`CurrentActor`/`auth.getName()`→facade가 `getByEmail`로 reviewer/applicant userId 해석).
6. **자격 409 vs 보안 403**: 신청 화면을 `hasRole("CONSUMER")`로 묶지 않았는지(안내 화면 도달 보장), SELLER/ADMIN 신청이 보안 403이 아니라 서비스 409로 거부되는지(MockMvc).

---

핵심 확정 사항: (1) 신청 보안 floor=`authenticated`, CONSUMER-only는 서비스 자격→**409**; (2) `/me`는 REST=**404**·View=**빈 안내 화면**; (3) 비-PENDING 승인 및 승인 레이스는 **409 거부**(멱등 skip 아님); (4) 사업자 필드는 **상호명·사업자등록번호·담당자연락처 3개 고정**; (5) 승인은 **단일 트랜잭션 안에서 008 `changeRole(.., SELLER)` 합류** 호출(afterCommit refresh 무효화 재사용); (6) 중복 차단은 **부분 유니크 인덱스 `WHERE status='PENDING'` + 제약위반 흡수**; (7) facade는 Role enum 대신 `SellerApplicationEligibility(eligible, reason)` scalar/DTO 노출.

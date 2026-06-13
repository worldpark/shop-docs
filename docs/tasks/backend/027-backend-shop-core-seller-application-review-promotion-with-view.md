# 027. shop-core 판매자 신청·심사·승격 워크플로우 (with View)

> 출처: backlog `docs/backlog/backend/002-backend-shop-core-seller-admin-account-management.md` 승격(범위 A). backlog 002의 "관리자 권한 변경 API"는 **Task 008이 이미 구현**(`AdminMemberRestController`/`AdminMemberFacade`/`AdminMemberViewController`, RoleHierarchy·self/last-admin 가드)했으므로, 본 Task는 **남은 부분 = 판매자 self-service 신청 → ADMIN 심사 → SELLER 승격 워크플로우**만 다룬다.

## Target
shop-core

---

## Goal
`CONSUMER`가 **판매자(SELLER) 권한을 신청**하고, `ADMIN`이 **심사(승인/반려)** 하며, **승인 시 신청자가 SELLER로 승격**되는 워크플로우를 REST API + Thymeleaf 화면으로 구현한다. 승격은 008이 만든 회원 권한 변경 경로(`MemberService.changeRole`)를 **재사용**한다(재구현 금지). 신청 레코드(신청자·심사자·시각·상태·반려 사유)가 곧 판매자 승격의 **감사(audit) 기록**이 된다.

> 008과의 관계: 008은 **ADMIN이 임의 회원 role을 직접 토글**(SELLER/CONSUMER)하는 경로(유지·무변경). 본 Task는 그 위에 **신청자 주도 온보딩 + 심사 상태머신**을 더한다. 둘은 공존하며, 승인은 008의 `changeRole`을 호출해 승격한다.

## Context
- **권한 모델(006/008)**: `Role { CONSUMER, SELLER, ADMIN }`, 계층 `ADMIN > SELLER > CONSUMER`(RoleHierarchy). public 가입(007)은 `CONSUMER`만. `ADMIN`은 시드(`AdminAccountSeedTest`)로만 생성 — 가입 흐름 없음.
- **승격 경로 재사용(008, 무변경)**: `member.spi.AdminMemberFacade.changeRole` → `MemberService.changeRole(adminUserId, targetMemberId, Role)`가 권한 변경을 수행하며 불변식(ADMIN 승격 금지·자기 강등 금지·마지막 ADMIN 강등 금지)과 **권한 변경 후 JWT/Redis 로그인 상태 처리 정책**을 이미 담고 있다. CONSUMER→SELLER 승격은 이 경로가 허용하므로 **승인 시 그대로 호출**한다.
- **신규 도메인**: 판매자 신청(`seller_application`) 개념은 코드·스키마에 없음 → 신규 Entity/테이블(**V5 Flyway 마이그레이션**) + Service + facade + REST + View.
- **레이어 규칙(member 모듈 계승)**: REST는 `@RestController → ServiceResponse → Service → Repository`, View는 `@Controller(web) → spi facade → Service`(web은 member 내부 Entity/Service 직접 참조 금지 — `AdminMemberFacade` 패턴 계승). domain enum(`Role`)을 web이 컴파일타임 참조하지 않도록 facade가 String↔enum 변환.
- **마이그레이션**: 현 V1~V4. 신규 `V5__seller_application.sql`. Flyway 소유·Hibernate validate(ADR-007). V1~V4 수정 금지.

## API Authorization
> `docs/rules/api-authorization-rule.md` 준수 — 최소 권한 + 소유권 검사.

| API | 공개 여부 | 보안 계층 최소 권한 | 상위 권한(계층) | 소유권 검사 | 신청 자격(서비스) | 비고 |
|---|---|---|---|---|---|---|
| `POST /api/v1/seller-applications` | authenticated | authenticated | 계층상 접근 가능 | 본인(principal) | **현재 role==CONSUMER만, SELLER/ADMIN은 409** | 판매자 신청 제출 |
| `GET /api/v1/seller-applications/me` | authenticated | authenticated | 계층상 접근 가능 | 본인 | 제한 없음(승격 후 SELLER도 본인 이력 조회) | 내 신청 상태 조회 |
| `GET /seller-applications/apply` | authenticated | authenticated | 계층상 접근 가능 | 본인 | 자격 미달이면 폼 대신 안내(차단 아님) | 신청 폼 화면 |
| `POST /seller-applications` | authenticated | authenticated | 계층상 접근 가능 | 본인 | **현재 role==CONSUMER만, SELLER/ADMIN은 409** | 신청 폼 제출(View) |
| `GET /seller-applications/me` | authenticated | authenticated | 계층상 접근 가능 | 본인 | 제한 없음 | 내 신청 상태 화면 |
| `GET /api/v1/admin/seller-applications` | authenticated | `ROLE_ADMIN` | 최상위(해당 없음) | 불필요 | — | 신청 목록(상태 필터) |
| `POST /api/v1/admin/seller-applications/{id}/approve` | authenticated | `ROLE_ADMIN` | 최상위(해당 없음) | 불필요 | — | 승인 → SELLER 승격 |
| `POST /api/v1/admin/seller-applications/{id}/reject` | authenticated | `ROLE_ADMIN` | 최상위(해당 없음) | 불필요 | — | 반려(사유) |
| `GET /admin/seller-applications` | authenticated | `ROLE_ADMIN` | 최상위(해당 없음) | 불필요 | — | 심사 목록 화면 |
| `POST /admin/seller-applications/{id}/approve` · `/reject` | authenticated | `ROLE_ADMIN` | 최상위(해당 없음) | 불필요 | — | 심사 폼 제출(View) |

> **인가 계층 vs 자격(eligibility) 분리 — 설계 핵심**:
> - 본 프로젝트는 RoleHierarchy(`ROLE_ADMIN > ROLE_SELLER > ROLE_CONSUMER`, `SecurityConfig` `roleHierarchy()` 빈)를 쓰며, `api-authorization-rule.md`가 "상위 권한은 하위 권한 API에 접근할 수 있다"를 명시한다. 따라서 **보안 계층에서 "CONSUMER만 허용, 상위는 차단"은 표현 불가**(`hasRole("CONSUMER")`는 RoleHierarchy로 ADMIN/SELLER도 통과시키며, 이는 규칙 위반이 아니라 의도된 동작). 신청 엔드포인트의 보안 floor는 **`authenticated`**로 둔다.
> - "**CONSUMER만 신청 가능**"은 인가가 아니라 **도메인 자격(eligibility)** 규칙이다. ADMIN/SELLER는 권한이 없어서가 아니라 *이미 동급 이상이라 신청 행위 자체가 무의미*하므로 거부된다 → 보안 403이 아닌 **상태 충돌 409**(서비스에서 현재 role 명시 확인). View 신청 폼은 차단 대신 "이미 SELLER/ADMIN" 안내를 렌더한다.
> - `*/me`(내 신청 상태)는 자격 제한을 두지 않는다 — 승인되면 신청자는 SELLER로 승격되므로, CONSUMER 전용으로 묶으면 본인이 자기 승인 결과를 못 보는 모순이 발생한다. **`authenticated` + 소유권(본인)** 만 적용.

## Requirements
- **도메인: `SellerApplication` Entity + `seller_application` 테이블(V5)**
  - 필드(최소): `id`, `userId`(신청자, FK users), `status`(`PENDING`/`APPROVED`/`REJECTED`), **최소 사업자 정보**(예: `businessName` 상호명 + `businessRegistrationNumber` 사업자등록번호 + `contactPhone` — 정확 집합은 plan 확정, 과도한 필드/외부 진위확인 금지), `rejectReason`(nullable), `reviewedBy`(심사 ADMIN userId, nullable), `createdAt`, `decidedAt`(nullable). `BaseEntity` auditing 패턴 계승.
  - **상태머신**: `PENDING → APPROVED | REJECTED`. APPROVED/REJECTED는 터미널. 상태 전이는 도메인 메서드(`approve(reviewerId)`/`reject(reviewerId, reason)`)로.
  - **중복 신청 차단**: 한 사용자는 **PENDING 신청을 최대 1건**만 보유. Postgres **부분 유니크 인덱스**(`UNIQUE(user_id) WHERE status='PENDING'`)로 DB 권위 가드 + 신청 시 사전 체크(경합은 005 패턴처럼 제약 위반 흡수). REJECTED 후 재신청 허용.
- **신청(자격: 현재 role==CONSUMER)**
  - `POST /api/v1/seller-applications`: 인증 사용자가 신청. 보안 floor는 `authenticated`이며, **서비스에서 현재 role이 `CONSUMER`가 아니면 거부**(SELLER=이미 판매자, ADMIN=대상 아님 → **409 Conflict**, 상태 충돌). PENDING 중복이면 거부(409). 신청 폼 검증(필수 사업자 정보). RoleHierarchy 상속에 기대지 말고 현재 role을 명시 확인(인가가 아닌 도메인 자격 규칙).
  - `GET /api/v1/seller-applications/me`: 본인 신청 상태/사유 조회. **role 자격 제한 없음**(`authenticated`+소유권만 — 승격 후 SELLER도 본인 이력 조회 가능). 신청 이력이 없으면 빈/404 정책 plan 확정. Entity 비노출(DTO).
- **심사(ADMIN)**
  - `GET /api/v1/admin/seller-applications?status=&page=&size=`: 신청 목록(상태 필터·페이지네이션). 신청자 식별·사업자 정보·상태·신청일 표시(민감정보 제외).
  - `POST .../{id}/approve`: PENDING 신청 승인 → **`MemberService.changeRole(reviewerAdminId, applicantUserId, SELLER)` 재사용으로 승격** + 신청 `APPROVED`(reviewedBy/decidedAt 기록). **단일 트랜잭션**(상태 전이 + 승격 + JWT/로그인 상태 정책은 008 경로가 처리). 비-PENDING 신청 승인은 멱등 skip 또는 4xx(plan 확정). 승인 시점 신청자가 이미 CONSUMER가 아니면(예: 그새 admin 토글로 SELLER) graceful 처리(상태만 정리 또는 4xx — plan 확정).
  - `POST .../{id}/reject`: PENDING 신청 반려(사유 필수) → `REJECTED`(reviewedBy/decidedAt/rejectReason 기록). role 변경 없음.
- **화면(with View — `web` 레이어, spi facade 경유)**
  - 신청자: `GET /seller-applications/apply`(폼), `POST /seller-applications`(제출→redirect), `GET /seller-applications/me`(상태). 화면 진입 보안 floor는 `authenticated`(SELLER/ADMIN도 진입 가능) — **facade가 폼 vs 안내 분기를 scalar/DTO로 내려준다**. web은 `Role` enum을 참조할 수 없으므로(레이어 규칙) facade가 `eligible`(boolean)·`reason`(예: 이미 SELLER/PENDING 존재) 같은 자격 결과를 반환하고, controller는 그 값으로만 분기한다(현재 role/PENDING 판정 자체는 member.spi 구현이 수행). 제출(`POST`) 시점에 서비스가 자격(role==CONSUMER)을 재검증해 부적격이면 409. 보안 계층에서 SELLER/ADMIN을 차단하지 않는다(차단하면 안내 화면이 도달 불가).
  - 관리자: `GET /admin/seller-applications`(목록+상태 필터), `POST /admin/seller-applications/{id}/approve|reject`(폼 제출→redirect, flash 메시지). 008의 `/admin/members` 화면 패턴·fragment 재사용.
- **감사(audit)**: 별도 감사 테이블을 만들지 **않는다**. `seller_application`의 `reviewedBy`/`decidedAt`/`status`/`rejectReason`이 **판매자 승격 감사 기록**이다(누가·언제·대상·결과). (008의 일반 role 토글 감사는 본 Task 범위 아님.)
- **로그**: 신청 제출/승인(승격)/반려를 `userId`·`applicationId`·심사자와 함께 로깅(008 로그 패턴 계승).

## Constraints
- **승격 재구현 금지**: 승인은 `MemberService.changeRole`(008) 경로를 호출해 SELLER로 승격한다. 권한 변경 불변식·JWT/Redis 로그인 상태 정책을 새로 만들지 않는다(008 재사용).
- **자가 권한 상승 금지**: 신청은 권한을 바꾸지 않는다(상태만 PENDING 생성). 실제 승격은 **ADMIN 승인**으로만 발생. 신청자가 스스로 SELLER가 되는 경로 없음.
- **신청 자격은 인가가 아닌 도메인 규칙**: 신청 제출은 현재 role이 정확히 `CONSUMER`인 사용자만 가능하되, 이는 **보안 계층(인가)이 아니라 서비스의 자격(eligibility) 검증**이다. RoleHierarchy(`ADMIN>SELLER>CONSUMER`)와 `api-authorization-rule.md`("상위 권한은 하위 권한 API에 접근 가능") 때문에 보안 계층에서 "CONSUMER만, 상위 차단"은 표현할 수 없으며 표현하려 들지 않는다. 부적격(SELLER/ADMIN) 거부는 **403이 아닌 409(상태 충돌)**.
- **ADMIN 생성 흐름 없음**: ADMIN은 시드 전용(본 Task는 SELLER 승격만). "관리자 가입"은 도입하지 않는다.
- **범위 밖(명시)**: 판매자 **소유권/판매자 범위 인가**(products·shipments의 seller_id 스코핑, SELLER 자기 것만 관리 — 별도 후속), 008의 직접 role 토글 변경, 사업자등록번호 외부 진위확인 API, 신청 결과 알림(notification 이벤트·이메일 — 신규 이벤트 계약 추가 없음, 필요 시 별도 Task), `COMPANY` 권한.
- **이벤트 계약 무변경**: `event-catalog.md`/§5 불변(신규 토픽/이벤트 없음). notification 코드·DB 미참조.
- **민감정보 비노출**: 비밀번호 hash·token·Redis 상태를 목록/응답/View에 노출 금지. Entity를 응답/View 모델에 직접 전달 금지(DTO).
- **레이어 규칙**: Controller 비즈니스 로직 금지. web→member.spi 단방향(web이 member Entity/Service/`Role` enum 직접 참조 금지).

## Files
> shop-core 단일 레포. member 모듈 + web 레이어. 정확 경로/필드는 plan 확정.
- (신규) `member/domain/SellerApplication.java`, `member/domain/SellerApplicationStatus.java`
- (신규) `member/repository/SellerApplicationRepository.java`(존재 체크/상태 필터 조회/잠금 등)
- (신규) `member/service/SellerApplicationService.java`(+ `ServiceResponse`) — 신청/승인/반려, 승인 시 `MemberService.changeRole` 재사용, 단일 트랜잭션
- (신규) `member/spi/SellerApplicationFacade.java`(신청자 View용 — 자격 결과를 `Role` enum이 아닌 scalar/DTO로 노출: `eligible`/`reason`/내 신청 상태)·`AdminSellerApplicationFacade.java`(관리자 View용) + 구현체(`member/service`)
- (신규) `member/controller/SellerApplicationRestController.java`(consumer), `AdminSellerApplicationRestController.java`(admin)
- (신규) `member/dto/**` — 신청 요청/응답, 목록 응답, 상태 DTO(Entity 비노출)
- (신규) `web/member/SellerApplicationViewController.java`, `web/member/AdminSellerApplicationViewController.java`
- (신규) `src/main/resources/db/migration/V5__seller_application.sql` — 테이블 + 부분 유니크 인덱스(`WHERE status='PENDING'`) + FK(users)
- (신규) `templates/seller-applications/apply.html`·`me.html`, `templates/admin/seller-applications.html`(+ fragment 재사용)
- (수정) `security/**` — 위 엔드포인트 인가(authorization-rule 표 반영). 008의 admin 보안 설정 패턴 계승
- (재사용·무변경) `member/service/MemberService.changeRole`·`AdminMemberFacade`(008), `member/domain/Role`/`User`, RoleHierarchy/JWT/Redis 로그인 상태 정책, `common/exception/BusinessException`
- (변경 없음) `event-catalog.md`/`architecture.md` §5, notification 전부, V1~V4

## Backend - View Contract
| 항목 | 값 |
|---|---|
| 신청 폼 화면 | `GET /seller-applications/apply` → view `seller-applications/apply` |
| 신청 제출 | `POST /seller-applications` → 성공 redirect `/seller-applications/me` |
| 내 신청 상태 화면 | `GET /seller-applications/me` → view `seller-applications/me` |
| 관리자 심사 목록 | `GET /admin/seller-applications` → view `admin/seller-applications` |
| 목록 필터 파라미터 | `status`(PENDING/APPROVED/REJECTED), `page`, `size` |
| 승인 폼 action | `POST /admin/seller-applications/{id}/approve` |
| 반려 폼 action | `POST /admin/seller-applications/{id}/reject` (필드 `rejectReason`) |
| 성공 리다이렉트(관리자) | `/admin/seller-applications` |
| 모델 키 | 목록 `applications`, 내 신청 `sellerApplication`(주의: `application`은 Thymeleaf 암묵 scope 객체와 충돌 — 예약어 회피), 메시지 기존 flash/message fragment |

## Acceptance Criteria
- `CONSUMER`는 판매자 신청을 제출할 수 있고, 본인 신청 상태를 조회할 수 있다.
- 이미 `SELLER`/`ADMIN`인 사용자, 또는 PENDING 신청 보유자는 **중복/부적격 신청이 거부**된다(서비스의 현재 role==CONSUMER 자격 검증 + PENDING 1건 제약, 부적격은 **409**). 이는 인가 차단이 아닌 도메인 자격 규칙이다.
- 승격되어 `SELLER`가 된 신청자도 `*/me`에서 본인 신청 결과(APPROVED)를 조회할 수 있다(`/me`는 role 자격 제한 없이 본인 소유권만 검사).
- `ADMIN`은 신청 목록을 상태 필터로 조회하고, **승인 시 신청자가 `SELLER`로 승격**(DB role 변경)되며 신청이 `APPROVED`(reviewedBy/decidedAt 기록)된다. 승격은 008 `changeRole` 경로로 수행된다.
- `ADMIN`이 **반려**하면 신청이 `REJECTED`(사유 기록)되고 role은 변경되지 않는다. 반려 후 재신청 가능.
- 신청 엔드포인트의 보안 floor는 `authenticated`(비인증 401), admin 심사는 `ROLE_ADMIN`만(CONSUMER/SELLER 403, 비인증 401). 신청 자격(role==CONSUMER)은 서비스에서 검증되어 SELLER/ADMIN은 409. 소유권: 본인 신청만 조회.
- 승인/반려는 단일 트랜잭션이며, 승인 시 권한 변경 후 JWT/Redis 로그인 상태 정책(008)이 적용된다.
- V5 마이그레이션이 V1~V4 수정 없이 `seller_application` + 부분 유니크 인덱스를 추가하고 Entity와 validate 정합. 응답/View에 민감정보 미노출. 이벤트 계약/notification 무변경.

## Test
- **단위(Mockito)**: 신청 — CONSUMER만 가능(SELLER/ADMIN 거부), PENDING 중복 거부; 승인 — 상태 PENDING→APPROVED + `MemberService.changeRole(.., SELLER)` 1회 호출(인자 검증, 승격 재사용), 비-PENDING 승인 처리; 반려 — REJECTED+사유, role 변경 없음. `SellerApplication` 상태 전이 메서드 단언.
- **슬라이스/통합(@DataJpaTest 또는 Testcontainers)**: 부분 유니크 인덱스(`WHERE status='PENDING'`)가 PENDING 중복을 막고 REJECTED 후 재신청은 허용함. V5 적용 + validate 정합.
- **Security/REST(MockMvc)**: `POST /api/v1/seller-applications` — CONSUMER 성공, SELLER/ADMIN 부적격 **409**(보안 403이 아님 — 자격 규칙), 비인증 401; `GET /api/v1/seller-applications/me` — 본인(CONSUMER/SELLER 무관) 성공, 비인증 401; admin 목록/approve/reject — ADMIN 성공, CONSUMER/SELLER 403, 비인증 401; 승인 후 대상 role=SELLER.
- **View 렌더링**: 신청 폼/내 상태 화면(CONSUMER), 관리자 심사 목록·승인/반려 폼(ADMIN) 렌더링 + 권한 없는 접근 차단 + 폼 제출 성공 redirect. (조건부 버튼/폼 가시성은 testing-rule상 필요 시 E2E로 검증.)
- **회귀**: 008 admin role 관리·007 가입·006 로그인 테스트 그린. `./gradlew test` 풀 그린.

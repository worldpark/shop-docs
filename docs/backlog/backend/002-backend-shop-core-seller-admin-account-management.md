# (backlog) 판매자/관리자 가입 및 권한 관리 (관리자 Task)

> 상태: backlog (미착수)
> 영역: shop-core (backend / member·security)
> 출처: Task 006/007 — 일반 회원가입은 `CONSUMER`만 public, `SELLER`/`ADMIN` 생성·권한 변경은 "후속 관리자 Task"로 명시

## 배경 / 동기
- 권한 계층은 `ADMIN > SELLER > CONSUMER`(006). 일반 public 회원가입(007)은 `CONSUMER`만 생성한다.
- `SELLER`/`ADMIN`은 public 가입으로 열지 않는다(보안 제약). 별도 관리자 흐름이 필요.

## 범위 (할 것)
- 관리자(ADMIN) 전용 회원 권한 부여/변경 API(예: `PATCH /api/v1/admin/members/{id}/role`), `@PreAuthorize`/RoleHierarchy 기반 인가.
- 판매자 신청/심사 흐름(가입 신청 → ADMIN 승인 → SELLER 승격) 설계.
- 권한 변경 감사 로그(누가/언제/대상) 고려.

## 범위 밖 / 주의
- 자가 권한 상승 절대 금지(권한 변경은 ADMIN만).
- api-authorization-rule의 최소 권한·소유권 검사 반영.

## 선행 의존
- Task 006(JWT/RoleHierarchy), 007(member 도메인) 완료.

## 참고
- `docs/tasks/backend/006-...md` Context, `docs/tasks/backend/007-...md` Context/Constraints

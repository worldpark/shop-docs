# (backlog) 회원가입 Welcome 알림 이벤트 발행

> 상태: **승격 완료 → Task 028** (`docs/tasks/backend/028-backend-shop-core-signup-welcome-event-with-notification.md`) — `MemberRegisteredEvent`(topic `member-registered`) 계약 + shop-core Outbox 발행 + notification 구독·발송으로 명세화.
> (이하 원본 backlog 내용 — 명세는 Task 028을 따른다)
> 영역: shop-core (backend / member·event·messaging) → notification 소비
> 출처: Task 007 범위 밖 — "회원가입 도메인 이벤트 발행(Welcome 알림 등)은 이벤트 계약 변경 금지로 후속"

## 배경 / 동기
- 회원가입 성공 시 환영 알림(이메일 등)을 보내려면 신규 공개 이벤트가 필요.
- 이는 시스템 공개 계약 추가이므로 `docs/event-catalog.md`(SSOT)와 `docs/architecture.md` §5 토픽 표를 먼저 수정해야 한다(이벤트 계약 규칙).

## 범위 (할 것)
- 이벤트 계약 먼저 정의: 예) `MemberRegisteredEvent`(eventId, occurredAt, memberId, email, name) — 자족적 페이로드, eventId/occurredAt 포함.
- `docs/event-catalog.md` + `docs/architecture.md` §5 토픽 표 추가(코드보다 문서 먼저 — event-contract-rule).
- shop-core: Transactional Outbox(Spring Modulith Event Publication Registry)로 발행(member 트랜잭션과 함께).
- notification: 신규 토픽 구독 Consumer + 발송 핸들러(멱등) — notification 측 별도 Task로 분리 가능.

## 범위 밖 / 주의
- 알림 실패가 회원가입 트랜잭션에 영향 주지 않을 것(단방향·비동기).
- 페이로드에 비밀번호 등 민감정보 금지.

## 선행 의존
- Task 007(member signup) 완료. notification 발송 핸들러 인프라(005 Consumer 골격).

## 참고
- `docs/rules/event-contract-rule.md`, `docs/event-catalog.md`, `docs/architecture.md` §5

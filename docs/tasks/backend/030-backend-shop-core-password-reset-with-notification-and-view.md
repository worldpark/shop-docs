# 030. shop-core 비밀번호 재설정 (비로그인·이메일 토큰) + notification 발송 (with View)

> 출처: backlog `docs/backlog/backend/004-backend-shop-core-account-management.md` 승격(범위 B — **비로그인 비밀번호 재설정**). 029(로그인 self-service)와 분리한 이유: 재설정은 **비로그인 흐름 + 신규 이벤트 계약(`PasswordResetRequestedEvent`) + notification 이메일 발송**이 얽혀 028(Welcome)과 동일하게 양 레포·계약 추가 작업이다.

## Target
shop-core (member·auth·event + web) + notification (consumer·service)

> shop-core는 토큰 발급·검증·새 비밀번호 설정과 **재설정 메일 이벤트 발행**(이메일 직접 발송 금지·단방향)을 담당하고, 실제 재설정 링크 이메일은 notification이 보낸다.

---

## Goal
비밀번호를 잊은 **비로그인 사용자**가 이메일로 재설정을 요청하면, shop-core가 **1회용·단기 만료 토큰**을 발급(Redis 저장)하고 **`PasswordResetRequestedEvent`** 를 Transactional Outbox로 발행한다. notification이 신규 토픽 **`password-reset-requested`** 를 구독해 **재설정 링크 이메일**을 보낸다. 사용자가 그 토큰으로 새 비밀번호를 설정하면 토큰이 즉시 무효화되고 기존 세션이 만료된다. REST API + Thymeleaf 화면 제공. **이메일 존재 여부를 노출하지 않는다(enumeration 방지).**

## Context
- **인증/비밀번호(006/007)**: `BCryptPasswordEncoder` 공용. 새 비밀번호 정책은 007 가입 규칙(`@PasswordMatches`/길이) 재사용. `MemberRepository.findByEmail`(citext)로 이메일→사용자 해석.
- **Redis 토큰 저장(006 선례)**: `RedisRefreshTokenStore`가 `shopcore:auth:refresh:{userId}`에 **SHA-256(refresh)** 만 저장(원문 미저장)하고 TTL을 둔다. 재설정 토큰도 동일 원칙 — **신규 namespace `shopcore:auth:reset:`** 에 `SHA-256(token)`→userId, 단기 TTL(예: 30분), **1회용**(사용 즉시 삭제). `RedisProperties.Auth`에 `resetPrefix`/`resetTtl` 추가.
- **이메일 발송 불가(아키텍처)**: shop-core는 이메일을 직접 보내지 않는다(단방향 이벤트만). 재설정 메일도 **신규 이벤트 발행** → notification 소비 구조(023~025 인프라 재사용)로만 보낸다. 028(Welcome)과 동일한 발행/소비 패턴.
- **이벤트 계약 SSOT(event-contract-rule)**: `event-catalog.md` + `architecture.md` §5를 **코드보다 먼저** 수정. 공통 봉투 + 자족 페이로드.
- **로그인 상태 정책(008 선례)**: 재설정 성공(비밀번호 교체) 시 `refreshTokenStore.deleteRefresh(userId)`를 `afterCommit()`로 호출해 기존 세션 무효화.
- **DB**: 토큰은 Redis가 권위(별도 테이블 불요). `users` 스키마 변경 없음 → **V_ 마이그레이션 추가 없음**(029의 V6와 독립).
- **029 의존(비밀번호 교체·활성 판정)**: confirm의 새 비밀번호 적용은 `User.changePassword`(029 도메인 메서드)를, request의 "활성 사용자" 판정은 029의 소프트 삭제 상태(WITHDRAWN 제외)를 전제로 한다. **029 선행 권장.** 029 미선행 시 본 Task가 ① `User.changePassword`를 직접 추가하고 ② 탈퇴 상태 판정은 029 도입 전까지 생략(전원 활성 간주)한다 — plan에서 029 선후를 확정한다.

## API Authorization
> `docs/rules/api-authorization-rule.md` 준수. **전 흐름 비로그인** → `permitAll`. 소유권은 회원 식별이 아니라 **토큰 소지 자체가 증명**(capability). 토큰은 단기·1회용·해시 저장으로 보호.

| API | 공개 여부 | 보안 계층 최소 권한 | 소유권/증명 | 비고 |
|---|---|---|---|---|
| `POST /api/v1/auth/password-reset/request` | public | `permitAll` | 없음(이메일만) | 재설정 요청 — **항상 동일 202/200**(enumeration 방지) |
| `POST /api/v1/auth/password-reset/confirm` | public | `permitAll` | **유효 토큰 소지** | 토큰 + 새 비밀번호로 교체 |
| `GET /password-reset` | public | `permitAll` | 없음 | 재설정 요청 폼 화면 |
| `POST /password-reset` | public | `permitAll` | 없음(이메일만) | 요청 폼 제출 → 항상 동일 안내 |
| `GET /password-reset/confirm` | public | `permitAll` | 토큰(쿼리) | 새 비밀번호 입력 폼(토큰 hidden) |
| `POST /password-reset/confirm` | public | `permitAll` | 유효 토큰 소지 | 새 비밀번호 폼 제출 → `/login?reset` |

> **enumeration 방지가 인가의 일부**: `request`는 이메일 존재 여부와 무관하게 **동일 응답·동일 소요시간 경향**을 유지한다(존재할 때만 토큰 발급·이벤트 발행, 미존재면 no-op이되 응답은 동일). "해당 이메일 없음" 같은 차별 응답 금지.

## Requirements
- **이벤트 계약 정의(코드보다 먼저 — event-contract-rule)**
  - `docs/event-catalog.md`에 **`PasswordResetRequestedEvent` (topic: `password-reset-requested`)** 추가. 필드:
    | 필드 | 타입 | 필수 | 설명 |
    |---|---|---|---|
    | `eventId` | UUID | ✓ | 공통 봉투(멱등 키) |
    | `occurredAt` | ISO-8601 | ✓ | 공통 봉투(이벤트 발행 시각 — `Instant.now()`. 기존 이벤트 관행과 동일) |
    | `memberId` | long | ✓ | 회원 PK |
    | `memberEmail` | string | ✓ | 수신 이메일 |
    | `memberName` | string | ✓ | 수신자 이름 |
    | `resetUrl` | string | ✓ | 재설정 링크(토큰 포함, 본문 삽입용) |
    | `expiresAt` | ISO-8601 | ✓ | 토큰 만료 시각(본문 안내용) |
  - `docs/architecture.md` §5 토픽 표 행 추가: `password-reset-requested` | `PasswordResetRequestedEvent` | 비밀번호 재설정 요청 | member | notification.
  - **토큰 페이로드 노출 주의(plan에 명시)**: 재설정 토큰은 이메일 본문 링크 전달에 필수라 `resetUrl`로 페이로드에 포함된다. 이는 OTP성 **단기·1회용** 토큰이므로 위험을 TTL·일회성·미로그로 한정한다. Outbox(`event_publication`) 행은 외부화 완료 후 정리되는 전제. (대안: 토큰 대신 별도 채널 — 사이드 프로젝트 범위 밖.)
- **shop-core — 요청(`POST /api/v1/auth/password-reset/request`, View `POST /password-reset`)**
  - 입력: `email`. `findByEmail`로 활성 사용자 조회. **존재 시**: 랜덤 토큰 생성(충분한 엔트로피) → `SHA-256(token)`을 Redis `shopcore:auth:reset:{hash}`→userId로 TTL과 함께 저장(원문 미저장) → `resetUrl`(예: `{baseUrl}/password-reset/confirm?token={token}`, **`baseUrl`은 설정 프로퍼티 — 하드코딩 금지**)·`expiresAt` 구성 → `PasswordResetRequestedEvent`를 **Outbox 발행**. **미존재/탈퇴(029)**: 토큰·이벤트 없이 no-op. **두 경우 모두 동일 응답**(202/200, "메일을 보냈습니다" 류 — enumeration 방지).
  - 동일 이메일 연속 요청 rate/replace 정책은 plan 확정(권장: 기존 토큰 교체 또는 최신만 유효). 토큰을 로그에 남기지 않는다.
- **shop-core — 확정(`POST /api/v1/auth/password-reset/confirm`, View `POST /password-reset/confirm`)**
  - 입력: `token`, `newPassword`, `newPasswordConfirm`. `SHA-256(token)`로 Redis 조회 → 없음/만료면 거부(400 — 유효하지 않거나 만료된 토큰). userId 확보 후 새 비밀번호 정책 검증(007 계승) → `passwordEncoder.encode` → `user.changePassword(newHash)`(029 도메인 메서드 재사용 가능). **성공 시 토큰 즉시 삭제(1회용)** + `refreshTokenStore.deleteRefresh(userId)` `afterCommit()`. 비밀번호 변경과 토큰 삭제·세션 무효화는 일관되게 처리(토큰 삭제는 Redis 비트랜잭셔널 — 순서/실패 정책 plan 확정).
- **notification — 소비·발송**
  - (신규) `dto/PasswordResetRequestedEvent.java` — 계약 미러(record, `EventEnvelope`).
  - (수정) `consumer/NotificationEventConsumer.java` — `@KafkaListener(topics="password-reset-requested", ...)` `onPasswordResetRequested` → `processingService.process(event)`.
  - (수정) `service/NotificationMessageRenderer.java` — case 추가 → 재설정 안내 제목/본문(`resetUrl` 링크 + `expiresAt` 만료 안내, `memberName` 인사). `memberEmail`/`resetUrl` 결손 → `NonRetryableNotificationException`.
  - (수정) `service/DlqReprocessingService.java` — `password-reset-requested.DLQ` 매핑.
  - 멱등·발송 상태머신·CircuitBreaker는 기존 인프라 재사용.

## Constraints
- **enumeration 방지**: `request`는 이메일 존재 여부를 응답으로 드러내지 않는다(동일 응답). 존재할 때만 토큰 발급·이벤트 발행, 미존재면 조용히 no-op.
- **토큰 안전**: 1회용(사용/만료 후 무효), 단기 TTL, **SHA-256 해시로 저장**(원문 Redis 미저장 — refresh 패턴 계승), 로그에 토큰 미기록. 만료/사용/위조 토큰 confirm 거부.
- **단방향·비동기 발송**: 재설정 메일은 이벤트 발행으로만(이메일 직접 발송 금지). 발송 실패가 토큰 발급/응답을 막지 않는다(at-least-once + 멱등). 단, **메일이 안 가면 사용자가 토큰을 못 받는다** — 발송 신뢰성은 023~025 인프라(재시도·DLQ·CB)에 의존.
- **비밀번호 보호(007 계승)**: 새 비밀번호 정책 검증, BCrypt, 원문 저장/로그/응답 금지. 재설정 성공 시 기존 refresh 무효화.
- **민감정보 페이로드 최소화**: 토큰(`resetUrl`) 외 비밀번호/해시 등 금지. 토큰은 단기·1회용으로 위험 한정(plan에 근거 명시).
- **계약 문서 우선**: `event-catalog.md` + `architecture.md` §5를 코드보다 먼저(event-contract-rule, 가산 변경).
- **DB 스키마 변경 없음**: 토큰은 Redis 권위. `users` 변경 없음(V_ 추가 없음 — 029의 V6와 무관·독립). notification `processed_event` 재사용.
- **Redis namespace 분리**: `shopcore:auth:reset:` 신설(기존 refresh/blacklist와 분리). `RedisProperties.Auth` 확장.
- **레이어 규칙**: REST `@RestController→ServiceResponse→Service→Repository`, View `@Controller(web)→spi facade→Service`. 토큰 발급/검증은 서비스/인프라(Redis 어댑터) 경계. 컨트롤러 비즈니스 로직 금지.

## Files
> shop-core + notification. 정확 경로/필드는 plan 확정.
- (수정) `docs/event-catalog.md` — `PasswordResetRequestedEvent` 스키마 + 예시 JSON
- (수정) `docs/architecture.md` §5 — 토픽 표 행 추가
- (신규) shop-core `member/event/PasswordResetRequestedEvent.java` — `@Externalized("password-reset-requested")` record
- (신규) shop-core `member/service/PasswordResetService.java`(+ `ServiceResponse`) — request/confirm, 토큰 발급/검증, 이벤트 발행, 비번 교체, refresh 무효화
- (신규) shop-core `security/PasswordResetTokenStore.java` **포트 인터페이스** + `RedisPasswordResetTokenStore` 운영 구현(Redis `shopcore:auth:reset:`, SHA-256 저장/조회/삭제, TTL) + 테스트용 인메모리 Fake — `RefreshTokenStore`/`RedisRefreshTokenStore`/`FakeRefreshTokenStore` **3분할 패턴 계승**(단위 테스트가 Redis 없이 동작)
- (수정) shop-core `common/config/RedisProperties.java` — `Auth`에 `resetPrefix`/`resetTtl`
- (신규) shop-core `member/dto/**` — `PasswordResetRequest`, `PasswordResetConfirmRequest`/`PasswordResetForm`/`PasswordResetConfirmForm`
- (신규) shop-core `member/controller/PasswordResetRestController.java` — `/api/v1/auth/password-reset/request|confirm`
- (신규) shop-core `member/spi/PasswordResetFacade.java` + 구현체 — web용(이메일/토큰/새 비번 처리, scalar 결과)
- (신규) shop-core `web/auth/PasswordResetViewController.java` — `GET/POST /password-reset`, `GET/POST /password-reset/confirm`
- (신규) shop-core `templates/auth/password-reset-request.html`·`password-reset-confirm.html`(+ blank layout·messages 재사용), `auth/login.html`에 "비밀번호를 잊으셨나요?" 링크 추가
- (수정) shop-core `security/SecurityConfig.java` — 위 REST/View 경로 `permitAll`(REST·View 체인 모두)
- (재사용) shop-core `User.changePassword`(029)·`BCryptPasswordEncoder`·`@PasswordMatches`·`RedisRefreshTokenStore.deleteRefresh`
- (신규) notification `dto/PasswordResetRequestedEvent.java`
- (수정) notification `consumer/NotificationEventConsumer.java`·`service/NotificationMessageRenderer.java`·`service/DlqReprocessingService.java`
- (재사용·무변경) notification `EventProcessingService`/`EmailSender`/`processed_event`/CircuitBreaker
- (변경 없음) V1~V6(shop-core), notification Flyway

## Backend - View Contract
| 항목 | 값 |
|---|---|
| 재설정 요청 화면 | `GET /password-reset` → view `auth/password-reset-request` |
| 요청 제출 | `POST /password-reset` → **항상** 동일 안내 화면/redirect(`/password-reset?sent`, enumeration 방지) |
| 새 비밀번호 화면 | `GET /password-reset/confirm?token=...` → view `auth/password-reset-confirm`(token hidden, 무효/만료 토큰 안내) |
| 확정 제출 | `POST /password-reset/confirm` → 성공 redirect `/login?reset`(실패 재렌더, 비번 echo 금지) |
| 로그인 화면 링크 | `auth/login`에 `GET /password-reset` 링크 |
| 모델 키 | 요청 폼 `passwordResetForm`, 확정 폼 `passwordResetConfirmForm`, 토큰 상태 `resetTokenValid`(scalar), 메시지 기존 flash/message fragment |

## Acceptance Criteria
- **존재하는 이메일**로 재설정 요청 시 토큰이 발급(Redis 저장)되고 `PasswordResetRequestedEvent`가 발행되어 notification이 **재설정 링크 이메일을 발송**한다(log mode 스모크 또는 smtp).
- **존재하지 않는/탈퇴한 이메일**로 요청해도 **동일한 응답**을 반환한다(토큰·이벤트 없음, "메일 발송" 류 — enumeration 방지).
- **유효한 토큰 + 정책에 맞는 새 비밀번호**로 confirm 시 비밀번호가 교체되고, **토큰이 즉시 무효화(1회용)** 되며 기존 refresh 토큰이 만료된다. 변경된 비밀번호로 로그인 가능.
- **만료·이미 사용·위조 토큰**으로 confirm 시 거부된다(유효하지 않은 토큰).
- 토큰은 Redis에 SHA-256 해시로만 저장되고 원문/토큰이 로그·응답·View에 노출되지 않는다(`resetUrl`은 이메일 본문 전달 목적의 이벤트 페이로드에 한함).
- `docs/event-catalog.md` + `docs/architecture.md` §5에 `password-reset-requested`/`PasswordResetRequestedEvent`가 반영되어 코드 record와 정합한다. `users` 스키마·기존 이벤트 무변경.

## Test
- **shop-core 단위(Mockito)**: request — 존재 이메일이면 토큰 저장 + `publishEvent(PasswordResetRequestedEvent)` 1회(인자 검증: `resetUrl`·`expiresAt`·`memberEmail` 정합), 미존재 이메일이면 저장·발행 없이 동일 결과 반환(enumeration 방지). confirm — 유효 토큰이면 `encode(newPassword)`+`changePassword`+토큰 삭제+`afterCommit` refresh 삭제, 만료/없는/사용된 토큰이면 거부, 새 비번 정책 위반 거부. (페이로드 record는 비밀번호/해시 필드를 타입 레벨에서 보유하지 않음 — 런타임 단언 대상 아님. `resetUrl` 토큰은 단기·1회용이므로 별도 취급.)
- **shop-core 통합(Testcontainers + Redis)**: 토큰이 `shopcore:auth:reset:` namespace에 SHA-256으로 저장되고 TTL 적용, confirm 성공 시 삭제(재사용 불가), TTL 경과 후 무효. `event_publication`에 이벤트 적재(요청 트랜잭션 커밋 시).
- **Security/REST(MockMvc)**: `/api/v1/auth/password-reset/request`·`/confirm` 모두 `permitAll`(비로그인 200/202/400), 존재/미존재 이메일 응답 동일, 잘못된 토큰 confirm 400, 성공 후 새 비번 로그인 가능.
- **notification 단위/통합**: `NotificationMessageRenderer`가 `PasswordResetRequestedEvent` → 재설정 본문(`resetUrl` 링크·`expiresAt`), `memberEmail`/`resetUrl` 결손 NonRetryable. consumer 위임 + DLQ 매핑. `EventProcessingService` 멱등(동일 eventId SENT skip).
- **notification 역직렬화 parity(중요)**: `dto/EventDeserializationTest`에 **`password-reset-requested` JSON → `PasswordResetRequestedEvent` 매핑 케이스 추가**(필드 `eventId`/`occurredAt`/`memberId`/`memberEmail`/`memberName`/`resetUrl`/`expiresAt` 전수). shop-core `@Externalized` record ↔ notification DTO는 공유 라이브러리 없이 **JSON 필드명 기반으로만 정합**하므로 계약 drift를 이 테스트로 회귀 차단(특히 `resetUrl`/`expiresAt` 같은 신규 필드명 누락 방지).
- **View 렌더링**: 요청 폼/확정 폼 렌더, 요청 제출 시 enumeration-safe 동일 안내, 무효 토큰 안내, 확정 성공 redirect `/login?reset`, 비번 echo 금지.
- **종단 스모크(testing-rule §종단 스모크)**: 요청 → Kafka → notification 로그 재설정 메일 1건 → 본문의 토큰으로 confirm → 로그인 성공(라이브 연계).
- **회귀**: 006 로그인·007 가입·029 계정 self-service 테스트 그린. shop-core·notification `./gradlew test` 풀 그린.

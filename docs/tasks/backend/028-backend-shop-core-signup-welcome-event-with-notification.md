# 028. 회원가입 Welcome 알림 이벤트 (shop-core 발행 + notification 발송)

> 출처: backlog `docs/backlog/backend/005-backend-shop-core-signup-welcome-event.md` 승격. Task 007(회원가입)이 "회원가입 도메인 이벤트 발행(Welcome 알림 등)은 이벤트 계약 변경 금지로 후속"으로 미뤄둔 항목. 신규 공개 이벤트 계약 추가 + 양 레포(shop-core 발행 / notification 소비).

## Target
shop-core (member·event) + notification (consumer·service)

> 두 레포에 걸치지만 **하나의 기능**(회원가입 환영 알림 end-to-end)이다. shop-core는 이벤트만 발행하고(단방향), 실제 이메일은 notification이 보낸다. 동기 호출·DB 공유 없음.

---

## Goal
회원가입(007)이 성공하면 shop-core가 **`MemberRegisteredEvent`** 를 Transactional Outbox(Spring Modulith Event Publication Registry)로 발행하고, notification이 신규 토픽 **`member-registered`** 를 구독해 **환영(Welcome) 이메일**을 발송한다. 알림 실패는 회원가입 트랜잭션에 영향을 주지 않는다(단방향·비동기·at-least-once).

> 023~025가 구축한 notification 발송 인프라(채널 추상화·렌더러·post-commit 발송 상태머신·멱등·DLQ·SMTP CircuitBreaker)를 **재사용**한다. 신규 토픽 1개를 그 위에 얹는 것이 본 Task의 notification 측 작업 전부다.

## Context
- **회원가입(007)**: REST `POST /api/v1/members/signup` + View `POST /signup` 모두 `MemberService.signup(email, rawPassword, name, phone)`(`@Transactional`, `User` 반환)을 단일 진입점으로 호출하며(View는 `MemberSignupFacadeImpl`이 단순 위임), 가입 성공 시 `User`(role=`CONSUMER` 강제)를 저장한다. **현재 이벤트 발행 없음**(`member/event/` 비어 있음).
- **회원 생성 경로 = signup 1곳(+ ADMIN 시드)**: 실제 회원 생성은 public `signup`이 유일하다. ADMIN은 가입 흐름 없이 시드(`AdminAccountSeedTest`)로 생성되며 — **welcome 대상이 아니다**(signup을 거치지 않으므로 발행 안 됨, 의도된 동작). 따라서 `signup` 단일 발행 지점이 환영 대상 회원 전체를 정확히 커버한다("단일 발행 지점"은 "모든 회원 생성 경로"가 아니라 "모든 환영 대상 회원 경로"를 의미).
- **발행 패턴(004, event-publication-registry)**: 기존 `OrderCancelledEvent`/`OrderCompletedEvent`/`PaymentFailedEvent`/`ShippingStartedEvent`가 `@Externalized("토픽")` record + `ApplicationEventPublisher.publishEvent(event)`를 `@Transactional` 경계 안에서 호출 → `event_publication` 테이블(Outbox)에 적재 → 커밋 후 외부화 poller가 Kafka로 발행. **이미 검증된 경로(024-1 직렬화 교정 완료)를 그대로 따른다.**
- **이벤트 계약 SSOT(event-contract-rule)**: 토픽 목록은 `docs/architecture.md` §5, 필드 스키마는 `docs/event-catalog.md`. **코드보다 계약 문서를 먼저 수정**한다. 공통 봉투(`eventId`, `occurredAt`) 필수, 자족 페이로드(컨슈머가 shop-core 역조회 금지).
- **notification 소비 구조(023~025)**: `NotificationEventConsumer`(토픽별 `@KafkaListener` → `EventProcessingService.process(event)`), `NotificationMessageRenderer`(이벤트 타입 switch → 수신자·제목·본문), `EventProcessingService`(멱등 claim `processed_event` PENDING→SENT/FAILED + post-commit 발송), `DlqReprocessingService`(`.DLQ` 재처리 매핑), `EmailSender`(log/smtp 채널 + CircuitBreaker). **신규 토픽은 DTO·consumer 메서드·renderer case·DLQ 매핑만 추가하면 나머지(멱등·상태머신·CB)는 자동 적용.**
- **수신자 정보**: 환영 메일에 필요한 이메일·이름은 페이로드에 자족 포함. 기존 이벤트 컨벤션(`memberId`/`memberEmail`/`memberName`)을 따라 renderer 검증(`memberEmail` blank → NonRetryable) 패턴과 정합시킨다.

## API Authorization
> `docs/rules/api-authorization-rule.md` 준수.

**신규 REST/View 엔드포인트 없음.** 발행은 기존 회원가입 흐름(007, public `permitAll`)에 부수되는 도메인 이벤트이며, 별도 API 표면을 추가하지 않는다. notification 측도 컨슈머(내부)만 추가한다. → 인가 변경 없음.

## Requirements
- **이벤트 계약 정의(코드보다 먼저 — event-contract-rule)**
  - `docs/event-catalog.md`에 **`MemberRegisteredEvent` (topic: `member-registered`)** 섹션 추가. 필드(공통 봉투 포함):
    | 필드 | 타입 | 필수 | 설명 |
    |---|---|---|---|
    | `eventId` | UUID | ✓ | 공통 봉투(멱등 키) |
    | `occurredAt` | ISO-8601 | ✓ | 공통 봉투(이벤트 발행 시각 — `Instant.now()`, 커밋 직전. 기존 이벤트 관행과 동일) |
    | `memberId` | long | ✓ | 회원 PK |
    | `memberEmail` | string | ✓ | 환영 메일 수신 이메일 |
    | `memberName` | string | ✓ | 수신자 이름 |
  - `docs/architecture.md` §5 토픽 표에 행 추가: `member-registered` | `MemberRegisteredEvent` | 회원가입 확정 | member | notification.
- **shop-core 발행**
  - (신규) `member/event/MemberRegisteredEvent.java` — `@Externalized("member-registered")` record(`eventId`, `occurredAt`, `memberId`, `memberEmail`, `memberName`). 기존 이벤트 record 스타일 계승.
  - `MemberService.signup(...)`에서 가입 성공 직후 **같은 `@Transactional` 안**에서 `eventPublisher.publishEvent(new MemberRegisteredEvent(UUID.randomUUID(), Instant.now(), saved.getId(), saved.getEmail(), saved.getName()))` 발행. REST/View 공통 경로이므로 **발행 지점은 1곳**(중복 발행 금지). 가입 실패(중복 이메일 등 롤백) 시 Outbox 적재도 롤백되어 미발행.
  - 페이로드에 **비밀번호/해시 등 민감정보 금지**.
- **notification 소비·발송**
  - (신규) `dto/MemberRegisteredEvent.java` — shop-core 계약 미러(record, `EventEnvelope` 구현: `eventId`/`occurredAt`).
  - (수정) `consumer/NotificationEventConsumer.java` — `@KafkaListener(topics="member-registered", groupId="notification", containerFactory="kafkaListenerContainerFactory")` `onMemberRegistered(...)` → `processingService.process(event)` 위임(기존 4개 리스너 패턴 동일).
  - (수정) `service/NotificationMessageRenderer.java` — switch에 `MemberRegisteredEvent` case 추가 → 환영 제목/본문 렌더(`memberName` 인사 + 가입 환영 문구). `memberEmail` blank/필수 결손 → `NonRetryableNotificationException`(기존 검증 패턴 계승).
  - (수정) `service/DlqReprocessingService.java` — `DLQ_TOPICS`에 `member-registered.DLQ`, `TOPIC_TYPE_MAP`에 매핑 추가.
  - 멱등·발송 상태머신(`processed_event` PENDING→SENT/FAILED)·CircuitBreaker는 기존 `EventProcessingService`/`EmailSender` 재사용(신규 코드 없음).

## Constraints
- **단방향·비동기**: 알림 발송 실패가 **회원가입 트랜잭션에 영향 금지**. shop-core는 Outbox에 적재 후 커밋만 보장하고, 외부화·발송 결과를 동기 대기하지 않는다. 유실 방지 우선(at-least-once) — 멱등으로 중복 흡수.
- **민감정보 페이로드 금지**: 비밀번호/해시/토큰 등 절대 미포함. 환영에 필요한 최소 식별·수신 정보만.
- **자족 페이로드**: notification은 shop-core를 역조회하지 않는다(DB 공유·동기 호출 없음).
- **계약 문서 우선**: `event-catalog.md` + `architecture.md` §5를 코드보다 먼저 갱신(event-contract-rule). 변경은 가산(신규 토픽 추가)이므로 기존 이벤트 호환성 영향 없음.
- **발행 단일 지점**: REST/View가 공유하는 `MemberService.signup` 1곳에서만 발행(컨트롤러/뷰 각각 발행 금지 — 중복).
- **DB 스키마 변경 없음**: V_ 마이그레이션 추가 없음(shop-core `event_publication`·notification `processed_event` 모두 기존 테이블 재사용).
- **레이어 규칙**: 이벤트 발행은 member 서비스 레이어 책임. 컨트롤러/web에서 직접 발행 금지.

## Files
> shop-core + notification. 정확 경로/필드는 plan 확정.
- (수정) `docs/event-catalog.md` — `MemberRegisteredEvent` 스키마 + 예시 JSON
- (수정) `docs/architecture.md` §5 — 토픽 표 행 추가
- (신규) shop-core `member/event/MemberRegisteredEvent.java` — `@Externalized("member-registered")` record
- (수정) shop-core `member/service/MemberService.java` — `signup` 내 `ApplicationEventPublisher.publishEvent` 추가(+ 필드 주입)
- (신규) notification `dto/MemberRegisteredEvent.java` — 계약 미러 record(`EventEnvelope`)
- (수정) notification `consumer/NotificationEventConsumer.java` — `onMemberRegistered` 리스너
- (수정) notification `service/NotificationMessageRenderer.java` — 환영 렌더 case
- (수정) notification `service/DlqReprocessingService.java` — `member-registered.DLQ` 매핑
- (재사용·무변경) shop-core Outbox/외부화 설정, notification `EventProcessingService`/`EmailSender`/`processed_event`/CircuitBreaker, 양 레포 Flyway(V_ 추가 없음)

## Acceptance Criteria
- 회원가입(REST `POST /api/v1/members/signup` 또는 View `POST /signup`) 성공 시 shop-core `event_publication`에 `MemberRegisteredEvent` 행이 적재되고 커밋 후 Kafka `member-registered` 토픽으로 외부화된다.
- 가입 실패(중복 이메일 등으로 트랜잭션 롤백) 시 이벤트가 발행되지 않는다.
- notification이 `member-registered`를 수신해 **환영 이메일을 발송**한다(log mode 스모크 로그 또는 smtp). `processed_event`가 PENDING→SENT로 전이한다.
- 동일 `eventId` 재전달 시 중복 발송되지 않는다(멱등). 발송 실패는 FAILED 기록 후 재시도/DLQ 대상이 된다.
- 이벤트 페이로드에 비밀번호/해시 등 민감정보가 없다.
- `docs/event-catalog.md` + `docs/architecture.md` §5에 `member-registered`/`MemberRegisteredEvent`가 반영되어 코드 record와 필드 정합한다. 기존 이벤트 계약·발송은 무변경(회귀 없음).

## Test
- **shop-core 단위(Mockito)**: `MemberService.signup` 성공 시 `ApplicationEventPublisher.publishEvent`가 `MemberRegisteredEvent`로 **1회** 호출됨(인자 캡처로 `memberId`/`memberEmail`/`memberName` 정합, `eventId`/`occurredAt` non-null) 검증. 중복 이메일 등 실패 경로에서는 발행 호출 없음. (페이로드 record에 비밀번호/해시 필드를 두지 않는 것은 record 정의·코드리뷰 레벨에서 보장 — 런타임 단언 대상 아님.)
- **shop-core 통합(Testcontainers)**: 가입 트랜잭션 커밋 시 `event_publication`에 INCOMPLETE 행 1건 적재, 롤백 시 미적재. `@Externalized` 직렬화 정합(024-1 회귀 — base64 이중 직렬화 없음).
- **notification 단위(Mockito)**: `NotificationMessageRenderer`가 `MemberRegisteredEvent` → 환영 제목/본문 렌더(`memberName` 포함), `memberEmail` blank → `NonRetryableNotificationException`. consumer가 `process` 위임. DLQ 매핑에 `member-registered.DLQ` 포함.
- **notification 역직렬화 parity(중요)**: 기존 `dto/EventDeserializationTest`(각 이벤트 JSON→DTO 필드 매핑 단언) 패턴에 **`member-registered` JSON → `MemberRegisteredEvent` 매핑 케이스 추가**. shop-core `@Externalized` record와 notification DTO는 공유 라이브러리 없이 **JSON 필드명 기반으로만 정합**하므로(필드명 한 글자라도 어긋나면 역직렬화 시 null/실패), 양측 계약 drift를 이 테스트로 회귀 차단한다. 필드: `eventId`/`occurredAt`/`memberId`/`memberEmail`/`memberName` 전부 매핑 확인.
- **notification 통합**: `EventProcessingService.process(MemberRegisteredEvent)` → `processed_event` PENDING→SENT, 동일 `eventId` 재처리 시 SENT skip(멱등).
- **종단 스모크(testing-rule §종단 스모크)**: shop-core 가입 → Kafka → notification 로그 이메일 발송 1건 확인(라이브 연계). 발행측 직렬화·구독측 역직렬화 정합 확인.
- **회귀**: 007 가입(REST/View)·기존 4개 이벤트 발행/소비 테스트 그린. shop-core·notification `./gradlew test` 풀 그린.

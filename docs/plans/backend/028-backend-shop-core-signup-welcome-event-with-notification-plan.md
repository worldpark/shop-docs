# Task 028 구현 Plan — 회원가입 Welcome 알림 이벤트

> 대상 Task: `docs/tasks/backend/028-backend-shop-core-signup-welcome-event-with-notification.md`
> 관련 규칙: `docs/rules/event-contract-rule.md`, `docs/rules/architecture-rule.md`, `docs/rules/package-structure-rule.md`, `docs/rules/testing-rule.md`, `docs/architecture.md` §5, `docs/event-catalog.md`
> 범위: shop-core(발행) + notification(소비·발송) — **하나의 기능**(회원가입 환영 알림 end-to-end). 단방향·비동기. DB 스키마 변경 없음.

## 구현 목표
회원가입 성공 시 shop-core가 `MemberRegisteredEvent`를 Transactional Outbox로 발행하고, notification이 신규 토픽 `member-registered`를 구독해 환영(Welcome) 이메일을 발송한다. 알림 실패는 회원가입 트랜잭션에 영향을 주지 않는다(at-least-once + 멱등).

---

## 1. 설계 방식 및 이유

### 1-A. 발행 지점 = `MemberService.signup` 단일점
- REST `POST /api/v1/members/signup`와 View `POST /signup`이 **모두** `MemberService.signup(email, rawPassword, name, phone)`(`@Transactional`, `User` 반환)를 단일 진입점으로 호출한다(View는 `MemberSignupFacadeImpl`이 단순 위임). 따라서 `signup` 1곳에서만 발행하면 두 경로를 모두 커버하고 **중복 발행이 구조적으로 불가능**하다.
- 컨트롤러/web에서 발행하지 않는다(레이어 규칙: 이벤트 발행은 member 서비스 레이어 책임). 컨트롤러·뷰 각각 발행은 중복 위험 + 레이어 위반이므로 금지.
- ADMIN 시드 계정은 `signup`을 거치지 않으므로 환영 대상이 아니며, 이는 **의도된 동작**이다("단일 발행 지점"은 "모든 환영 대상 회원 경로"를 의미).

### 1-B. `@Externalized` record + ApplicationEventPublisher 재사용 (신규 인프라 0)
- 기존 `OrderCompletedEvent`/`PaymentFailedEvent`/`OrderCancelledEvent`/`ShippingStartedEvent`가 쓰는 검증된 패턴을 **그대로** 따른다: `@org.springframework.modulith.events.Externalized("member-registered")` record + `@Transactional` 안에서 `ApplicationEventPublisher.publishEvent(event)`.
- Spring Modulith Event Publication Registry가 `event_publication`(Outbox)에 INCOMPLETE 적재 → 커밋 후 외부화 poller가 Kafka로 발행. `application.yml`의 `spring.modulith.events.externalization.enabled=true`, producer `value-serializer=ByteArraySerializer`(Modulith ByteArrayJsonMessageConverter가 JSON byte[] 변환 — 024-1 직렬화 교정 완료)를 그대로 사용한다. **중앙 등록 리스트·NewTopic 빈 불필요**(`@Externalized` 어노테이션 + auto-create로 충분).

### 1-C. notification은 보일러플레이트만 추가
- 023~025가 구축한 멱등(`processed_event` PENDING→SENT/FAILED)·post-commit 발송 상태머신·CircuitBreaker·DLQ 인프라는 **무변경 재사용**한다. 신규 토픽은 ① DTO 미러 record, ② consumer `@KafkaListener` 메서드, ③ renderer switch case, ④ DLQ 매핑만 추가하면 나머지가 자동 적용된다.
- 새 추상화/제네릭/설정 레이어를 만들지 않는다(과도한 설계 금지). renderer는 기존 `requireEmail(...)` 검증 패턴, consumer는 `process(event)` 단순 위임 패턴을 동일하게 따른다.

### 1-D. 계약 문서 우선(event-contract-rule)
- 토픽 목록 SSOT는 `architecture.md` §5, 필드 스키마 SSOT는 `event-catalog.md`다. **코드보다 계약 문서를 먼저 수정**한다. 변경은 가산(신규 토픽 1개 추가)이라 기존 이벤트 호환성 영향 없음.

### 1-E. 자족 페이로드
- 환영 메일에 필요한 `memberEmail`·`memberName`을 페이로드에 자족 포함한다(컨슈머가 shop-core 역조회 금지). 기존 이벤트의 `memberId`/`memberEmail`/`memberName` 컨벤션을 따라 renderer 검증(`memberEmail` blank → NonRetryable)과 정합한다.

---

## 2. 구성 요소

> 패키지 base: shop-core `com.shop.shop`, notification `com.shop.notification`.

### 2-A. 계약 문서 (코드보다 먼저 — event-contract-rule)
1. **(수정) `docs/event-catalog.md`** — `## MemberRegisteredEvent (topic: \`member-registered\`)` 섹션 추가. 필드 표 + 예시 JSON.

   | 필드 | 타입 | 필수 | 설명 |
   |---|---|---|---|
   | `eventId` | UUID | ✓ | 공통 봉투(멱등 키) |
   | `occurredAt` | ISO-8601(UTC) | ✓ | 공통 봉투(발행 시각 — `Instant.now()`, 커밋 직전) |
   | `memberId` | long | ✓ | 회원 PK |
   | `memberEmail` | string | ✓ | 환영 메일 수신 이메일 |
   | `memberName` | string | ✓ | 수신자 이름 |

   예시 JSON:
   ```json
   {
     "eventId": "b7d4e1f2-0000-0000-0000-000000000005",
     "occurredAt": "2026-06-14T05:00:00Z",
     "memberId": 101,
     "memberEmail": "welcome@example.com",
     "memberName": "신규회원"
   }
   ```

2. **(수정) `docs/architecture.md` §5 토픽 표** — 행 추가:
   `| \`member-registered\` | \`MemberRegisteredEvent\` | 회원가입 확정 | member | notification |`

### 2-B. shop-core (발행)
3. **(신규) `shop-core/src/main/java/com/shop/shop/member/event/MemberRegisteredEvent.java`**
   - 패키지: `com.shop.shop.member.event` (`member` 모듈의 `event` 패키지 — package-structure-rule).
   - `@Externalized("member-registered")` record. `OrderCompletedEvent` 스타일(클래스 Javadoc + `TOPIC` 상수) 계승.
   - 시그니처: `public record MemberRegisteredEvent(UUID eventId, Instant occurredAt, long memberId, String memberEmail, String memberName)`
   - `public static final String TOPIC = "member-registered";`
   - **민감정보(비밀번호/해시/토큰) 필드 금지.**

4. **(수정) `shop-core/src/main/java/com/shop/shop/member/service/MemberService.java`**
   - `@RequiredArgsConstructor` final 필드에 `private final ApplicationEventPublisher eventPublisher;` 추가(`org.springframework.context.ApplicationEventPublisher`).
   - `signup(...)`의 `User user = memberRepository.save(...)` 직후, **같은 `@Transactional` 안**에서:
     ```java
     eventPublisher.publishEvent(new MemberRegisteredEvent(
             UUID.randomUUID(), Instant.now(),
             user.getId(), user.getEmail(), user.getName()));
     ```
   - `import java.time.Instant; java.util.UUID;` 추가. 가입 실패(`DuplicateEmailException` 등 롤백) 시 발행도 롤백되어 미발행(catch 블록보다 앞·save 성공 직후 발행하되 같은 트랜잭션이므로 어느 위치든 롤백 시 Outbox 적재도 롤백).
   - 비밀번호 원문/해시 로그 금지 규칙 유지(기존 로그 변경 없음).

### 2-C. notification (소비·발송)
5. **(신규) `notification/src/main/java/com/shop/notification/dto/MemberRegisteredEvent.java`**
   - 패키지: `com.shop.notification.dto`. shop-core 계약 **미러** record, `EventEnvelope` 구현.
   - 시그니처: `public record MemberRegisteredEvent(UUID eventId, Instant occurredAt, long memberId, String memberEmail, String memberName) implements EventEnvelope {}`
   - **필드명·순서가 shop-core record와 정확히 일치**해야 한다(JSON 필드명 기반 역직렬화).

6. **(수정) `notification/src/main/java/com/shop/notification/consumer/NotificationEventConsumer.java`**
   - 리스너 메서드 추가(기존 4개 패턴 동일):
     ```java
     @KafkaListener(topics = "member-registered", groupId = "notification", containerFactory = "kafkaListenerContainerFactory")
     public void onMemberRegistered(MemberRegisteredEvent event) {
         processingService.process(event);
     }
     ```
   - import 추가. 로직 없음 — `process` 위임만.

7. **(수정) `notification/src/main/java/com/shop/notification/service/NotificationMessageRenderer.java`**
   - `render(...)` switch에 `case MemberRegisteredEvent e -> renderMemberRegistered(e);` 추가.
   - `private RenderedMessage renderMemberRegistered(MemberRegisteredEvent event)`: `requireEmail(event.memberEmail(), ...)` 호출 → 제목/본문 렌더(예: 제목 `"[환영] 가입을 축하합니다"`, 본문 `"안녕하세요, {memberName}님.\n\n회원가입을 환영합니다. ..."`) → `new RenderedMessage(event.memberEmail(), subject, body)` 반환.
   - 필수 필드는 `memberEmail`뿐(`requireEmail` blank → `NonRetryableNotificationException`). `memberName`은 인사에만 쓰이며 추가 필수 검증 불요(기존 OrderCompleted와 동일 수준 — 과도 검증 금지).

8. **(수정) `notification/src/main/java/com/shop/notification/service/DlqReprocessingService.java`**
   - `DLQ_TOPICS`에 `"member-registered.DLQ"` 추가.
   - `TOPIC_TYPE_MAP`에 `"member-registered.DLQ", MemberRegisteredEvent.class` 매핑 추가. import 추가.
   - 멱등·발송 상태머신·CircuitBreaker는 `EventProcessingService`/`EmailSender`/`processed_event` **무변경 재사용**.

### 2-D. 재사용·무변경
- shop-core Outbox/외부화 설정(`application.yml`, ByteArraySerializer), `event_publication` 테이블.
- notification `EventProcessingService`/`NotificationDispatchService`/`EmailSender`/CircuitBreaker/`processed_event` 테이블.
- 양 레포 Flyway — **V_ 마이그레이션 추가 없음**. 토픽 `member-registered`/`member-registered.DLQ`는 `KAFKA_AUTO_CREATE_TOPICS_ENABLE=true`로 자동 생성.

---

## 3. 데이터 흐름 (end-to-end)

1. 사용자가 REST `POST /api/v1/members/signup` 또는 View `POST /signup` 호출 → (View는 `MemberSignupFacadeImpl` → ) `MemberService.signup(...)` 진입(`@Transactional` 시작).
2. 이메일 정규화 → 중복 사전 체크 → BCrypt 해시 → `memberRepository.save(...)` → `User user` 반환.
3. **같은 트랜잭션 안**에서 `eventPublisher.publishEvent(new MemberRegisteredEvent(UUID.randomUUID(), Instant.now(), user.getId(), user.getEmail(), user.getName()))` 호출.
4. Spring Modulith Event Publication Registry가 `event_publication`에 **INCOMPLETE** 행 1건 적재(아직 발행 전).
5. 트랜잭션 **커밋** → 커밋 후 외부화 poller가 해당 행을 JSON(byte[])으로 직렬화해 Kafka `member-registered` 토픽으로 발행 → 행 COMPLETE 처리. (커밋 실패/롤백 시 4의 행도 롤백 → 미발행.)
6. notification `NotificationEventConsumer.onMemberRegistered(MemberRegisteredEvent event)`가 토픽 구독 수신. `StringJsonMessageConverter`가 리스너 파라미터 타입(`MemberRegisteredEvent`)으로 JSON 역직렬화(필드명 기반).
7. `EventProcessingService.process(event)` 위임:
   - ① 사전 skip: `processed_event`에 동일 `eventId`가 SENT면 멱등 skip.
   - ② claim(PENDING) 커밋(신규 INSERT 또는 비터미널 재방문 UPDATE).
   - ③ 트랜잭션 밖 dispatch → `NotificationMessageRenderer.render(event)` → `renderMemberRegistered` 환영 제목/본문 생성 → `EmailSender`(log/smtp + CircuitBreaker)로 발송.
8. 발송 성공 → `recordSent`(PENDING→**SENT**). 발송 실패(`NotificationException`) → `recordFailed`(→**FAILED**) 후 재전파 → DefaultErrorHandler 재시도 → 소진 시 `member-registered.DLQ` 적재.
9. (운영자 트리거 시) `DlqReprocessingService.reprocessDlq()`가 `member-registered.DLQ`를 poll → `MemberRegisteredEvent`로 역직렬화 → `process` 재투입(멱등 가드).

---

## 4. 예외 처리 전략

- **가입 롤백 시 미발행**: 발행이 `signup`의 `@Transactional` 경계 안 + Outbox 적재이므로, 중복 이메일(`DuplicateEmailException`)·동시성 unique 위반(`DataIntegrityViolationException`→`DuplicateEmailException`) 등 롤백 시 `event_publication` 적재도 함께 롤백되어 **이벤트가 발행되지 않는다**.
- **단방향(알림 실패가 가입에 영향 없음)**: shop-core는 Outbox 적재 후 커밋만 보장하고, 외부화·발송 결과를 동기 대기하지 않는다. notification 발송 실패는 회원가입 응답/트랜잭션에 영향 없음(architecture §9 불변식).
- **발송 실패 → FAILED/DLQ**: dispatch 실패 시 `processed_event` FAILED 기록(별도 TX) 후 예외 재전파 → DefaultErrorHandler 재시도 → 소진 시 `member-registered.DLQ`. 유실 방지 우선(at-least-once).
- **멱등 중복 흡수**: 동일 `eventId` 재전달 시 SENT면 사전 skip, claim 경합은 `DataIntegrityViolationException` 흡수 → **중복 발송 안 됨**.
- **renderer 필수 필드 결손 → NonRetryable**: `memberEmail` blank/누락 시 `NonRetryableNotificationException` → 재시도 무의미 처리(non-retryable 경로). `memberName` 등은 인사용으로 추가 강제 검증하지 않음(과도 검증 금지).
- **민감정보 차단**: 페이로드 record에 비밀번호/해시/토큰 필드를 두지 않음(record 정의·코드리뷰 레벨 보장).

---

## 5. 검증 방법 (Task Test 섹션 → 테스트 클래스/메서드 매핑)

> 명세 Test 항목을 누락 없이 매핑한다. 신규 파일은 기존 동종 테스트 위치/네이밍을 따른다.

### 5-A. shop-core 단위 (Mockito) — `member/service/MemberServiceSignupTest.java`(수정)
- ⚠️ 기존 `setUp()`이 `new MemberService(memberRepository, passwordEncoder, refreshTokenStore)`로 3-arg 생성 중 → **`ApplicationEventPublisher` mock 추가**해 4-arg로 변경(전 테스트 메서드 영향).
- 신규 케이스:
  - `signup_success_publishes_MemberRegisteredEvent_once`: 성공 시 `ApplicationEventPublisher.publishEvent`가 `MemberRegisteredEvent`로 **1회** 호출. `ArgumentCaptor<MemberRegisteredEvent>`로 `memberId`/`memberEmail`/`memberName` 정합(저장된 User 값과 일치), `eventId`·`occurredAt` non-null 단언.
  - `signup_duplicateEmail_does_not_publish`: 사전 체크 중복 → `DuplicateEmailException`, `verify(eventPublisher, never()).publishEvent(any())`.
  - `signup_raceUniqueViolation_does_not_publish`: `save`가 `DataIntegrityViolationException` → `DuplicateEmailException`, 발행 호출 없음.

### 5-B. shop-core 통합 (Testcontainers) — `member/service/MemberRegisteredOutboxIntegrationTest.java`(신규)
- 기존 `OrderCancellationOutboxIntegrationTest` 패턴 계승(`@SpringBootTest` + `@AutoConfigureTestDatabase(NONE)` + `@Testcontainers` + `externalization.enabled=false` + `@TransactionalEventListener(AFTER_COMMIT)` CaptureListener 또는 `event_publication` JdbcTemplate 조회).
- 케이스:
  - 가입 커밋 시 `event_publication`에 INCOMPLETE 행 1건 적재(또는 AFTER_COMMIT 캡처 1건) + 페이로드 필수 필드(`memberId`/`memberEmail`/`memberName`) 검증.
  - 롤백(중복 이메일) 시 미적재(0건).

### 5-C. notification 단위 (Mockito)
- `service/NotificationMessageRendererTest.java`(수정 또는 케이스 추가):
  - `MemberRegisteredEvent` → 환영 제목/본문 렌더, 본문에 `memberName` 포함 단언.
  - `memberEmail` blank → `NonRetryableNotificationException`.
- `consumer/NotificationEventConsumerTest.java`(있으면 수정): `onMemberRegistered`가 `processingService.process(event)` 위임 단언.
- `service/DlqReprocessingServiceTest.java`(있으면 수정): `DLQ_TOPICS`/`TOPIC_TYPE_MAP`에 `member-registered.DLQ`→`MemberRegisteredEvent` 포함 단언.

### 5-D. notification 역직렬화 parity (중요) — `dto/EventDeserializationTest.java`(수정)
- **케이스 추가**: `member-registered` JSON(event-catalog 예시) → `MemberRegisteredEvent` 역직렬화, `eventId`/`occurredAt`/`memberId`/`memberEmail`/`memberName` **전부** 매핑 단언.
- `MemberRegisteredEvent_implements_eventEnvelope`: `EventEnvelope.class.isAssignableFrom(...)` 단언.
- 이 테스트가 shop-core record ↔ notification DTO **필드명 drift**를 회귀 차단(공유 라이브러리 없이 JSON 필드명 기반 정합).

### 5-E. notification 통합 — 기존 `EventProcessingService` 통합 테스트에 케이스 추가(있으면)
- `process(MemberRegisteredEvent)` → `processed_event` PENDING→SENT, 동일 `eventId` 재처리 시 SENT skip(멱등). 신규 토픽 전용 통합이 과하면 기존 멱등 통합의 파라미터화/추가 케이스로 흡수.

### 5-F. 종단 스모크 (testing-rule §종단 스모크 — 필수)
- **실제 발행측 경로(`@Externalized`/Outbox)로 발행된 실 이벤트** → 실 컨슈머 → notification `processed_event` SENT + 발송(log mode) 로그 도달 단언. 합성 이벤트 주입 금지.
- testing-rule 허용 조합: 토픽 전수 대신 (a) 공유 발행 경로 대표 1~2개 종단 스모크 + (b) production `application.yml` 직렬화 설정 파일경로 직접 읽기 회귀 가드. `member-registered`는 (a)에 포함하거나, 기존 종단 스모크가 공유 외부화 경로를 대표하면 직렬화 회귀는 자동 커버 — **단 parity 테스트(5-D)는 필수**.
- 배치: docker-compose 양 앱 기동 필요 시 별도 태스크/CI 스텝(`e2e-runner`). EmbeddedKafka로 외부화 경로를 실제로 태울 수 있으면 effective 직렬화 설정을 명시 고정해 `test` 내 배치 가능.

### 5-G. 회귀
- shop-core `./gradlew test` 풀 그린(007 가입 REST/View + 기존 4개 이벤트 발행 무회귀, 024-1 직렬화 회귀 무재발).
- notification `./gradlew test` 풀 그린(기존 4개 소비·렌더·DLQ·역직렬화 무회귀).

---

## 6. 트레이드오프

- **at-least-once + 멱등 (중복 발송 허용) vs exactly-once**: Kafka exactly-once는 트랜잭션 프로듀서/컨슈머 복잡도가 높다. 본 설계는 Outbox(발행 신뢰) + `processed_event` 멱등(소비 중복 흡수)으로 **유실 0 + 드문 중복 발송 허용**을 택한다. 환영 메일 중복은 사용자 영향이 경미하고 멱등으로 사실상 차단되므로 비용 대비 합리적.
- **단일 트랜잭션 내 발행 (Outbox)**: 가입 DB 변경과 이벤트 적재가 원자적이라 "가입 성공했는데 이벤트 누락" 또는 "롤백됐는데 발행됨"이 구조적으로 불가능. 대가는 커밋 후 외부화까지의 **짧은 발행 지연**(poller 주기) — 환영 메일에 허용 가능.
- **`occurredAt` = 발행 시각(`Instant.now()`, 커밋 직전)**: 별도 도메인 타임스탬프 없이 발행 시각을 봉투 시각으로 사용(기존 이벤트 관행 동일). 가입 시각과 미세 차이가 있을 수 있으나 환영 알림 용도엔 무의미.
- **자족 페이로드(역조회 금지) vs 최소 페이로드**: `memberEmail`/`memberName`을 페이로드에 담아 notification 독립성 보장(단방향 불변식). 대가는 페이로드가 다소 커지고 변경 시 양 레포 미러 동기화 필요 — parity 테스트(5-D)로 drift 방지.
- **계약 문서 우선의 오버헤드**: 코드 전에 `event-catalog.md`/`architecture.md` 수정은 한 단계 더 들지만, SSOT 일관성과 양 레포 미러 정합의 기준점을 확보(event-contract-rule).

---

## 구현 순서 (체크리스트)

- [ ] 1. (계약 우선) `docs/event-catalog.md`에 `MemberRegisteredEvent` 섹션 + 예시 JSON 추가
- [ ] 2. (계약 우선) `docs/architecture.md` §5 토픽 표에 `member-registered` 행 추가
- [ ] 3. shop-core `member/event/MemberRegisteredEvent.java` 신규 (`@Externalized` record)
- [ ] 4. shop-core `MemberService`에 `ApplicationEventPublisher` 주입 + `signup` 내 발행 추가
- [ ] 5. shop-core 단위 `MemberServiceSignupTest` 생성자 4-arg 갱신 + 발행 검증 케이스 3종 추가
- [ ] 6. shop-core 통합 `MemberRegisteredOutboxIntegrationTest` 신규(커밋 적재/롤백 미적재)
- [ ] 7. notification `dto/MemberRegisteredEvent.java` 미러 record 신규(`EventEnvelope`)
- [ ] 8. notification `consumer/NotificationEventConsumer`에 `onMemberRegistered` 리스너 추가
- [ ] 9. notification `service/NotificationMessageRenderer`에 환영 렌더 case 추가
- [ ] 10. notification `service/DlqReprocessingService`에 `member-registered.DLQ` 매핑 추가
- [ ] 11. notification `dto/EventDeserializationTest`에 parity 케이스 + EventEnvelope 단언 추가
- [ ] 12. notification 단위(renderer/consumer/DLQ) 케이스 추가
- [ ] 13. 종단 스모크 1개(실 Outbox 발행→실 컨슈머→SENT 도달) 배치/실행 경로 확정
- [ ] 14. shop-core·notification `./gradlew test` 풀 그린 + 회귀 확인

## 완료 조건 (Acceptance)
- [ ] 가입 성공 시 `event_publication` 적재 + 커밋 후 `member-registered` 외부화
- [ ] 가입 실패(롤백) 시 미발행
- [ ] notification 수신 → 환영 이메일 발송 + `processed_event` PENDING→SENT
- [ ] 동일 `eventId` 재전달 시 중복 발송 없음, 발송 실패 시 FAILED→DLQ
- [ ] 페이로드에 민감정보 없음
- [ ] `event-catalog.md` + `architecture.md` §5 ↔ 코드 record 필드 정합, 기존 이벤트 무회귀

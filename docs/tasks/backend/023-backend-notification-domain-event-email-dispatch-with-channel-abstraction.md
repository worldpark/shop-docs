# 023. notification 도메인 이벤트 → 실제 이메일 알림 발송 (채널 추상화 + 이벤트별 렌더링 + order-cancelled 구독)

## Target
notification

---

## Goal
`005`(Consumer 골격 + 멱등 + DLQ)가 깔아둔 소비 파이프라인 위에, **shop-core 도메인 이벤트를 실제 알림(이메일)으로 발송하는 핸들러**를 구현해 **이벤트 루프를 닫는다**. 현재는 발행 측(`016` order-completed · `017` payment-failed · `018` order-cancelled · `020` shipping-started)이 모두 갖춰졌으나, notification은 **로그 스텁(`LoggingNotificationDispatchService`)만** 두고 실제 발송이 없다. 본 Task는:
- **발송 채널을 추상화**하고(`이메일 우선`), 로그 스텁을 **실제 이메일 발송 어댑터**로 교체한다.
- **이벤트 타입별 메시지 렌더링**(수신자·제목·본문)을 추가한다 — **자족 페이로드만** 사용(shop-core 역조회 금지).
- **`order-cancelled` 구독을 신설**한다 — `018`이 발행하고 `architecture.md` §5에 notification 소비자로 등록돼 있으나 005 골격이 미구독한 토픽이다(DTO·Consumer·핸들러 부재). 이걸 추가해 4개 토픽 전부를 발송으로 연결한다.

> 본 Task는 **이메일 채널의 실제 발송**만 다룬다. SMS/푸시 채널, **post-commit 발송 분리·발송 이력/DLQ 재처리 → 후속 Task 024**, **Resilience4j CircuitBreaker → 025**은 **범위 밖**이다. **Redis dedup·`RedisConfig` 정리(008)는 보류**(DB `processed_event` 권위로 충분 — `docs/plans/revisions/backend/notification-dedup-store-redis-vs-db-decision-revision-1.md`). 멱등은 005가 만든 `processed_event`(DB UNIQUE) 권위 저장소를 그대로 재사용하고, 실패 시엔 005의 Kafka 재시도/DLQ를 재사용한다(고급 회복탄력성은 025).

---

## Context
- **선행(구현 완료 전제)**
  - `005`: notification Kafka Consumer 골격 + 멱등(`processed_event` UNIQUE(`event_id`)) + 재시도/DLQ(`DefaultErrorHandler`, 원본토픽`.DLQ`) + **발송 추상화 인터페이스 `NotificationDispatchService` + 로그 스텁 `LoggingNotificationDispatchService`**. 처리 진입점은 `EventProcessingService.process` → `EventProcessingTransactionHelper.claimAndDispatch`(멱등 insert + dispatch **단일 트랜잭션**). 현재 구독 토픽: `order-completed`/`payment-failed`/`shipping-started` **3종**.
  - `016`/`017`/`018`/`020`: 발행 측 — `OrderCompletedEvent`/`PaymentFailedEvent`/`OrderCancelledEvent`/`ShippingStartedEvent`를 Outbox(Modulith Event Publication Registry)로 발행. **4개 토픽 모두 발행 중.**
- **현 상태의 공백(본 Task가 메우는 것)**
  - `order-cancelled` 토픽은 `architecture.md` §5·`event-catalog.md`에 **이미 계약 등록**돼 있으나, notification에 **DTO·Consumer 메서드·핸들러가 없다**(005 골격이 018 이전 시점이라 미반영). → DTO 미러 + Consumer 구독 + 발송 핸들러 신설.
  - dispatch가 `[DISPATCH] ... to=email` 로그만 출력한다(수신자만 추출, 제목·본문·실제 전송 없음). → 이벤트별 렌더링 + 실제 이메일 전송.
- **이벤트 계약(변경 없음 — event-contract-rule)**
  - 본 Task는 **소비 측 전용**이다. `event-catalog.md`/`architecture.md` §5를 **변경하지 않는다**(4개 토픽·페이로드 모두 기존 그대로). notification DTO는 계약을 **미러링**한다(공유 라이브러리 없이 양쪽 동기화 — architecture §5). `OrderCancelledEvent` DTO는 catalog 필드(orderId/orderNumber/memberId/memberEmail/memberName/items[productId,productName,quantity]/refunded/refundedAmount/currency/cancelledAt) 1:1 반영.
  - 페이로드는 **자족적**이다 — 발송에 필요한 수신자(`memberEmail`/`memberName`)·주문/상품 스냅샷이 페이로드에 포함돼 있어 **shop-core 재조회가 불필요**하고, 규칙상 금지된다.
- **멱등·재시도·DLQ 모델(005 재사용, 변경 없음)**
  - 권위 멱등 = DB `processed_event`(UNIQUE `event_id`). `process`가 사전 `existsByEventId` 빠른 skip → `claimAndDispatch`가 `save+flush`(claim) 후 `dispatch` 호출, **claim+dispatch 단일 트랜잭션**. dispatch가 `NotificationException`을 던지면 **트랜잭션 롤백(claim도 롤백) → 컨테이너 재시도 → 소진 시 DLQ**. 유니크 경합은 `process`가 트랜잭션 경계 밖에서 `DataIntegrityViolationException`으로 흡수(`[DUPLICATE]`).
  - 본 Task는 이 구조를 **그대로 유지**하고 `dispatch` 구현만 실제 발송으로 교체한다. **재시도/DLQ 골격을 재설계하지 않는다.**
- **at-least-once / 이중 발송 윈도우(설계상 인지 — plan에서 기본값 확정)**
  - 이메일 전송은 **롤백 불가한 외부 부작용**이다. 005의 claim+dispatch 단일 트랜잭션에서 "전송 성공 → 커밋 실패(드묾)" 시 같은 이벤트가 재시도되어 **이메일이 한 번 더 갈 수 있다**(at-least-once + DB 멱등이 지배적 dedup, 잔여 중복 윈도우는 커밋 실패 시점에 한함).
  - **권장 기본값**: 005의 단일 트랜잭션 구조를 **유지**한다 — 전송 실패 시 롤백→재시도로 **알림 유실을 막는 것**이 사이드 프로젝트 단계에서 드문 중복보다 우선이다. **정확히 한 번(exactly-once)** 을 위한 커밋-후-발송(post-commit) + 발송상태 머신/이력 테이블은 **후속 Task 024 범위**다(본 Task에서 구조 변경 금지).
  - (인지) 블로킹 SMTP 호출이 DB 트랜잭션 내부에서 일어나 트랜잭션이 전송 시간만큼 길어진다(커넥션 보유). 사이드 프로젝트 수용 범위이며, 비동기/post-commit 분리는 024로 미룬다. **가상스레드 대비(CLAUDE.md): 블로킹 I/O(SMTP)는 발송 어댑터(Infra 경계)에 두고 `ThreadLocal` 직접 사용 금지.**
- **레이어 규칙(005·package-structure-rule 계승)**
  - Consumer는 로직 없이 `EventProcessingService`로만 위임(Repository 직접 호출 금지, 예외 잡지 않음 — `DefaultErrorHandler` 위임).
  - 실제 발송은 Service 계층 뒤 **채널 추상화 포트**로 격리한다. Entity를 외부로 노출하지 않는다. REST Controller/`ServiceResponse` 없음.
- **프로파일 가드(005 계승)**: Consumer·Service·Dispatch 빈은 `@Profile("kafkatest | !test")`로 가드된다(`test` 단독 프로파일에서 Kafka/JPA 자동설정 제외와 정합). **신규 발송/채널/렌더 빈도 같은 가드를 따른다** — 풀컨텍스트 `test` 회귀·외부 SMTP 접속 유발 금지. **단, dev/운영 `EmailSender` 택1은 이 `@Profile` 가드와 직교하는 별도 프로퍼티(`notification.mail.mode`)로 한다** — 같은 `@Profile` 문자열에 합치면 두 어댑터가 동시 등록돼 빈 유일성이 깨진다(`NoUniqueBeanDefinitionException`). 아래 Requirements "발송 채널 추상화" 참조.

## Authorization / 공개 표면
> 본 Task는 **신규 REST/View 엔드포인트가 없다**(Kafka 소비 → 백그라운드 발송). 외부 호출 API를 추가하지 않으므로 api-authorization-rule 엔드포인트 권한 항목은 해당 없음.
- 외부로 나가는 표면은 **이메일 발송**뿐이다. 수신자는 **페이로드의 `memberEmail`** 로만 결정한다(역조회·외부 주소록 조회 금지).
- 메일 본문에 **민감정보/비밀**(토큰·카드번호·내부 식별자 등)을 넣지 않는다(016/017/018 페이로드 정책 계승). 본문은 페이로드에 담긴 사용자 노출 가능 정보(주문번호·상품명·금액·실패 사유 메시지 등)만 사용한다.

## Requirements
- **`order-cancelled` 구독 신설**
  - `OrderCancelledEvent` DTO(notification `dto`) 추가 — `event-catalog.md` 필드 1:1. items는 `productId`/`productName`/`quantity`만 — **completed의 `OrderItem`(원시형 `long unitPrice` 보유)을 재사용하지 않는다**(취소 페이로드엔 단가가 없어 역직렬화 시 `unitPrice`가 조용히 `0`이 되고, 원시형이라 nullable 처리도 불가). **별도 `CancelledItem`(productId/productName/quantity) record를 신설**한다. `EventEnvelope` 구현(`eventId`/`occurredAt`).
  - `NotificationEventConsumer`에 `@KafkaListener(topics = "order-cancelled", groupId = "notification", ...)` 메서드 추가 → `processingService.process(event)` 위임(기존 3개와 동일 패턴).
- **발송 채널 추상화(이메일 우선)**
  - **계층 분리(중요 — 오케스트레이터 ≠ 전송 채널)**: `NotificationDispatchService`(기존 인터페이스 유지)는 **단일 구현**(예: `EmailNotificationDispatchService`)으로 두고 **렌더링 + `EmailSender.send` 위임**만 한다. **기존 `LoggingNotificationDispatchService`(dispatch 스텁)는 제거**하고, 그 로그-only 동작은 `EmailSender`의 dev 어댑터(`LoggingEmailSender`)가 승계한다. dispatch 오케스트레이터와 전송 채널은 **서로 다른 인터페이스**이므로 dispatch 구현을 "EmailSender 어댑터로 강등"하지 않는다(타입/계층 혼동 금지).
  - **발송 채널 포트**: `EmailSender`(예: `send(to, subject, body)` 수준의 얇은 인터페이스)를 `service` 패키지에 정의한다. 구현 어댑터도 notification 레포 내(`service`, 블로킹 SMTP I/O = Infra 경계)에 둔다. SMS/푸시 포트는 만들지 않는다(YAGNI — 이메일 우선).
  - **dev/운영 어댑터 2종 + 택1 메커니즘(빈 유일성 모순 방지)**:
    - `LoggingEmailSender`(dev, **소켓 없음** — 로그만): **기본값**.
    - `JavaMailEmailSender`(운영, `spring-boot-starter-mail`/`JavaMailSender` SMTP).
    - **택1은 `@Profile`이 아니라 프로퍼티 `notification.mail.mode`(`log`|`smtp`)로 한다.** 테스트 격리 가드(`@Profile("kafkatest | !test")`)와 채널 선택(`mail.mode`)은 **직교하는 두 축**이므로 한 `@Profile` 문자열에 합치지 않는다 — 합치면 두 어댑터가 동일 가드로 동시 등록돼 `NoUniqueBeanDefinitionException`. 권장 배선: 두 어댑터 모두 `@Profile("kafkatest | !test")` + `LoggingEmailSender`에 `@ConditionalOnProperty(name="notification.mail.mode", havingValue="log", matchIfMissing=true)`, `JavaMailEmailSender`에 `havingValue="smtp"`. → **항상 정확히 하나** 활성, 기본 `log`라 로컬·`kafkatest`·"SMTP 미설정 운영"에서 소켓을 안 연다.
  - **운영 SMTP 자격증명/실서버 연동은 설정 주도**(`spring.mail.*` + 환경변수)로 두고, 실제 운영 계정 발급·검증은 범위 밖(설정 자리만 마련). (참고: MailHog 등 로컬 SMTP catcher는 `mail.mode=smtp` + host=localhost로 쓰는 **로컬 한정 옵션**이며 소켓을 열므로 테스트/CI 기본이 아니다 — 테스트/기본은 `LoggingEmailSender`.)
- **이벤트 타입별 메시지 렌더링**
  - 4개 이벤트 각각에 대해 **수신자·제목·본문**을 만드는 렌더링을 둔다(타입별 분기 또는 타입별 렌더러). 페이로드 자족 데이터만 사용:
    - `OrderCompletedEvent` → 주문 확정/결제 완료 안내(주문번호·항목·총액).
    - `PaymentFailedEvent` → 결제 실패 안내(주문번호·금액·`failureReason`). `failureCode` 같은 내부 코드는 본문 노출 최소화(사람이 읽는 `failureReason` 우선).
    - `OrderCancelledEvent` → 취소 안내. `refunded`로 **환불/미환불 문구 분기**(refunded=true면 환불 금액 안내, false면 미결제 취소 문구). (참고: 사용자취소/시스템만료 구분 필드는 계약에 없음 — 022가 의도적으로 미도입 → 문구 구분하지 않음.)
    - `ShippingStartedEvent` → 배송 시작 안내(주문번호·`carrier`·`trackingNumber`·이 배송분 items).
  - 본문 포맷은 **간단한 문자열/기본 HTML**로 충분하다. 무거운 템플릿 엔진 도입·다국어(i18n)·HTML 레이아웃 고도화는 범위 밖(YAGNI).
- **실패 분류(005의 예외 체계 재사용)**
  - 전송 실패를 retryable/non-retryable로 구분한다: **일시적 SMTP 오류**(연결/타임아웃 등) → `NotificationException`(retryable) → 컨테이너 재시도 → 소진 시 DLQ. **영구 실패**(주소 형식 오류·렌더 불가한 페이로드 등 재시도해도 동일) → `NonRetryableNotificationException` → 무의미한 재시도 없이 DLQ 직행. `ProcessingError`의 retryable 힌트·로깅을 그대로 활용.
- **멱등(005 재사용, 변경 없음)**
  - 동일 `eventId` 재수신 시 발송 1회만(사전 skip 또는 claim 유니크 경합 흡수). 본 Task는 **새 멱등 메커니즘을 만들지 않는다**(Redis dedup 적용은 009).
- **설정**
  - `spring.mail.*`(host/port/username/password/from 등) `application.yml` 자리 + 환경변수 오버라이드. 발송 관련 옵션(보내는 사람 주소, dev/운영 어댑터 선택 등)은 기존 `notification.*` 설정 패턴(`@ConfigurationProperties`)을 따른다.
  - `build.gradle`에 메일 의존(`spring-boot-starter-mail`) 추가(현재 미포함).

## Constraints
- **이벤트 계약 무변경**: `event-catalog.md`/`architecture.md` §5 변경 없음. notification DTO는 계약 미러링만. 신규 토픽/이벤트/필드 추가 없음. **소비 측이 계약을 바꾸지 않는다.**
- **shop-core 역조회 금지**: notification은 shop-core 코드/DB/REST를 참조하지 않는다. 발송에 필요한 모든 값은 페이로드에서만 취한다(자족). 페이로드에 없는 정보가 필요하면 그것은 **계약 개정(발행 측 Task)** 이지 본 Task가 아니다.
- **005 파이프라인 보존**: Consumer→Service→(채널) 위임·멱등 단일 트랜잭션·재시도/DLQ 골격을 재설계하지 않는다. `dispatch` 구현 교체 + `order-cancelled` 구독 추가 + 렌더링/채널 신설에 한정. Consumer는 Repository 직접 호출·예외 흡수 금지.
- **범위 밖(명시)**: SMS/푸시 채널, **post-commit/비동기 발송 분리(exactly-once 윈도우 축소)·발송 실패/DLQ 이력·재처리 테이블·`processed_event` 상태머신 확장 → 024**, **Resilience4j CircuitBreaker(SMTP 장애 격리·fail-fast) → 025**. **Redis dedup 적용·`RedisConfig @ConditionalOnBean` 정리(008)는 보류**(DB 권위로 충분 — revision 문서). 그 외 템플릿 엔진/다국어. **신규 Flyway 마이그레이션 없음**(발송 이력 테이블 미도입 — `processed_event` 그대로).
  - **재시도 자체는 005의 Kafka 재시도/DLQ를 재사용**한다(본 Task가 별도 재시도 프레임워크를 도입하지 않는다). Resilience4j는 **메시지 재배달 계층(Kafka `DefaultErrorHandler`+DLQ)을 대체하지 않으며**, 도입 시 아웃바운드 SMTP 호출 둘레의 CircuitBreaker로 한정한다 — 025 소관.
- **at-least-once 수용**: 단일 트랜잭션 유지로 전송 후 커밋 실패 시 드문 이중 발송을 수용한다(유실 방지 우선). 구조 변경(post-commit)은 024.
- **프로파일/테스트 오염 금지(verification-gate)**: 신규 발송/채널/렌더 빈은 `@Profile("kafkatest | !test")` 가드 유지. 실제 SMTP 어댑터가 **풀컨텍스트 `test`에서 외부 접속을 시도하지 않도록** 한다(빈 지연 생성·dev 어댑터 기본). 발송 로직 테스트는 컨테이너 트리거가 아니라 **Service/렌더/채널을 직접 호출** + **Mock/Fake `EmailSender`** 로 검증한다(실제 메일 전송 금지).
- **가상스레드 대비**: 블로킹 SMTP I/O는 발송 어댑터(Infra 경계)에 격리, `ThreadLocal` 직접 사용 금지(CLAUDE.md).
- **민감정보 본문 금지**: 메일 본문/제목에 비밀·결제 수단·내부 식별자 노출 금지. 페이로드의 사용자 노출 가능 필드만 사용.

## Files
> 정확한 경로/빈 배선은 plan 확정. notification 단일 레포 내부 작업.
- (신규) `notification/dto/OrderCancelledEvent.java` + `notification/dto/CancelledItem.java` — catalog 미러(취소 items 전용 record, `OrderItem` 재사용 안 함)
- (수정) `notification/consumer/NotificationEventConsumer.java` — `order-cancelled` `@KafkaListener` 메서드 추가(4종)
- (신규) `notification/service/EmailSender` 포트 + 어댑터 2종: `LoggingEmailSender`(dev, 소켓 없음·기본) / `JavaMailEmailSender`(운영 SMTP). 둘 다 `@Profile("kafkatest | !test")`, 택1은 `notification.mail.mode` `@ConditionalOnProperty`(`@Profile` 아님)
- (신규) 이벤트 타입별 **메시지 렌더링**(렌더러 또는 분기) — 수신자·제목·본문 생성, 자족 페이로드만
- (신규/교체) `notification/service`의 `NotificationDispatchService` **단일 구현**(예: `EmailNotificationDispatchService`) — 렌더링 + `EmailSender.send`. retryable/non-retryable 분류로 `NotificationException`/`NonRetryableNotificationException` 사용. **기존 `LoggingNotificationDispatchService` 제거**(로그-only 동작은 `LoggingEmailSender`가 승계)
- (수정) `notification/src/main/resources/application.yml` — `spring.mail.*` + 발송 옵션(`@ConfigurationProperties`), `notification.mail.mode` 기본 `log`
- (수정) `notification/build.gradle` — `spring-boot-starter-mail` 추가
- (재사용·무변경) `EventProcessingService`/`EventProcessingTransactionHelper`(멱등·트랜잭션 골격), `ProcessedEvent`/`ProcessedEventRepository`, `EventEnvelope`, `NotificationException`/`NonRetryableNotificationException`/`ProcessingError`
- (변경 없음) `docs/event-catalog.md`/`docs/architecture.md` §5, `notification` Flyway 마이그레이션(신규 없음), Redis dedup 설정(미적용 — 009)

## Layer Contract (notification 레이어 규칙)
| 항목 | 위치 | 규칙 |
|---|---|---|
| 토픽 구독 | `consumer` | 4종(`order-completed`/`payment-failed`/`order-cancelled`/`shipping-started`) `@KafkaListener` → `EventProcessingService.process` 위임만. 로직·Repository 직접 호출·예외 흡수 금지 |
| 멱등·트랜잭션 | `service`(005 재사용) | `process`(사전 skip + 경합 흡수) → `claimAndDispatch`(claim+dispatch 단일 트랜잭션). 변경 없음 |
| 발송 오케스트레이션 | `service`(`NotificationDispatchService` 구현) | 이벤트 → 렌더링 → 채널 전송. retryable/non-retryable 분류. Entity 비노출 |
| 메시지 렌더링 | `service`(렌더러/분기) | 타입별 수신자·제목·본문. **자족 페이로드만**(shop-core 역조회 금지) |
| 이메일 전송 | `EmailSender` 어댑터(`service`, Infra 경계) | 블로킹 SMTP 격리. dev(`LoggingEmailSender`)/운영(`JavaMailEmailSender`) 택1은 `notification.mail.mode` 프로퍼티(`@Profile` 아님). `ThreadLocal` 미사용 |
| 멱등 저장 | `domain`/`repository`(005 재사용) | `processed_event` UNIQUE(`event_id`). 상태머신 확장 없음(009) |

## Behavior Contract (동기 응답 표면 없음)
- 본 Task는 REST/View 동기 응답이 없다. 동작은 **토픽 소비 → 이메일 발송 1건**으로 관측된다.
- 정상 1건 = 이벤트 소비 → `processed_event` claim → 렌더링 → `EmailSender.send` 성공 → 커밋(`[PROCESSED]`/발송 로그).
- 일시 전송 실패 = `NotificationException` → 트랜잭션 롤백(claim 롤백) → 재시도 → 소진 시 `원본토픽.DLQ`.
- 영구 실패 = `NonRetryableNotificationException` → 재시도 없이 DLQ.
- 중복 수신 = 사전 skip 또는 경합 흡수 → 발송 0건(`[DUPLICATE]`).
- 관측성: 발송 성공/중복/실패/DLQ가 `eventId`·타입과 함께 로깅된다(005 로그 + 발송 로그).

## Acceptance Criteria
- 4개 토픽(`order-completed`/`payment-failed`/`order-cancelled`/`shipping-started`) 모두 Consumer가 구독하고 발송 핸들러로 연결된다(특히 **신설 `order-cancelled`** 포함).
- 각 이벤트가 **타입별 제목·본문·수신자(`memberEmail`)** 로 렌더링되어 `EmailSender`로 전송된다. `OrderCancelledEvent`는 `refunded`에 따라 환불/미환불 문구가 분기된다.
- 렌더링·발송이 **자족 페이로드만** 사용한다(shop-core 역조회 코드 없음).
- 정상 처리 시 `processed_event`가 성공으로 남고 이메일 1건 전송. 동일 `eventId` 재수신 시 **발송 1회만**(멱등).
- 일시 전송 실패 → 재시도 설정 적용 후 소진 시 해당 토픽 `.DLQ`로 라우팅. 영구 실패 → 재시도 없이 DLQ.
- 신규 발송/채널/렌더 빈이 `@Profile` 가드되어 **풀컨텍스트 `test`에서 외부 SMTP 접속·발송을 유발하지 않는다**. 풀컨텍스트 테스트 회귀 없음.
- `event-catalog.md`/`architecture.md` §5 무변경, 신규 토픽/이벤트/필드/마이그레이션 없음. shop-core 미참조. `005` 멱등·DLQ 회귀 없음.

## Test
- 단위(Mockito): 타입별 렌더링 — 4개 이벤트 각각 수신자/제목/본문이 페이로드 필드로 구성되는지(특히 `OrderCancelledEvent` refunded=true/false 문구 분기, `PaymentFailedEvent`의 `failureReason` 사용). 렌더링이 페이로드 외 소스를 참조하지 않음(자족) 단언.
- 단위(Mockito): `NotificationDispatchService.dispatch` — 정상 시 `EmailSender.send` 1회 호출(인자 검증), 일시 실패 시 `NotificationException`(retryable), 영구 실패(주소 형식 오류 등) 시 `NonRetryableNotificationException` 전파. **Mock/Fake `EmailSender`로 실제 전송 없이** 검증.
- 단위(Mockito): `NotificationEventConsumer.onOrderCancelled`가 `EventProcessingService.process`로 위임(기존 3개와 동일 패턴). DTO 역직렬화 테스트(`order-cancelled` 페이로드 → `OrderCancelledEvent`).
- 멱등/트랜잭션(005 슬라이스 재사용): dispatch가 실제 발송으로 바뀐 뒤에도 — 정상 시 claim 커밋·발송 1회, dispatch 예외 시 claim 롤백(재처리 가능), 중복 `eventId` 흡수. Fake `EmailSender`로 발송 호출 횟수 검증(이중 발송 없음).
- 통합(EmbeddedKafka, 005 패턴): EmbeddedKafka topics에 `order-cancelled`·`order-cancelled.DLQ` 추가. `order-cancelled` 정상 소비 → 발송 1회 + `processed_event` 1건. 일시 실패 강제 → 재시도 후 `order-cancelled.DLQ` 라우팅. 중복 소비 → 발송 추가 없음. **실제 SMTP 미사용** — `NotificationDispatchService`(005 기존 패턴) 또는 `EmailSender` 중 한 계층을 Fake/`@Primary`로 오버라이드(기본 `mail.mode=log`면 `LoggingEmailSender`라 소켓도 없음).
- 회귀: 기존 3개 토픽 발송 경로·005 멱등/DLQ 테스트 그린. 풀컨텍스트 `test`가 SMTP 접속을 시도하지 않음(가드 확인).

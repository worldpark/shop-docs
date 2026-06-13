# 023 Plan — notification 도메인 이벤트 → 실제 이메일 발송 (채널 추상화 + 이벤트별 렌더링 + order-cancelled 구독)

- Task: docs/tasks/backend/023-backend-notification-domain-event-email-dispatch-with-channel-abstraction.md
- Target: notification (단일 레포 내부)
- 선행: 005(Consumer 골격 + 멱등 processed_event UNIQUE + 재시도/DLQ). 발행 측 016/017/018/020 모두 발행 중.
- 본 plan은 005 파이프라인(Consumer→EventProcessingService→EventProcessingTransactionHelper claim+dispatch 단일 트랜잭션, DefaultErrorHandler+DLQ)을 재설계하지 않고 보존한다. dispatch 구현 교체 + order-cancelled 구독 추가 + 렌더링/EmailSender 채널 신설에 한정한다.

---

## 1. 설계 방식 및 이유

### 1.1 채택 설계 (3계층 분리)
오케스트레이터 != 전송 채널 != 렌더링을 서로 다른 타입으로 분리한다.

NotificationEventConsumer (4종 @KafkaListener)
  -> EventProcessingService.process            (005, 변경 없음 — 사전 skip + 경합 흡수)
    -> EventProcessingTransactionHelper.claimAndDispatch  (005, 변경 없음 — claim+dispatch 단일 TX)
      -> NotificationDispatchService.dispatch = EmailNotificationDispatchService (신규 단일 구현)
          - NotificationMessageRenderer.render(event) -> RenderedMessage(to, subject, body)
          - EmailSender.send(to, subject, body)
              - LoggingEmailSender   (dev/기본, 소켓 없음)
              - JavaMailEmailSender   (운영 SMTP)

- 오케스트레이터 NotificationDispatchService(기존 인터페이스, 시그니처 무변경): 렌더 + 전송 위임 + 실패 분류만. 단일 구현 EmailNotificationDispatchService.
- 렌더러 NotificationMessageRenderer: 이벤트 타입 -> 수신자·제목·본문. 자족 페이로드만 사용.
- 전송 포트 EmailSender: send(to, subject, body) 얇은 인터페이스. 어댑터 2종.

### 1.2 근거 (대안 대비)
- 왜 dispatch 구현을 EmailSender 어댑터로 강등하지 않는가: dispatch는 이벤트->렌더->채널선택 오케스트레이션이고 EmailSender는 to/subject/body->전송이라 책임이 다르다. 합치면 향후 채널 추가(SMS/푸시는 024)에서 분기 지옥이 된다. 단, 채널 추가 추상화(SMS/푸시 포트)는 지금 만들지 않는다(YAGNI — 이메일 우선).
- 왜 dev/운영 택1을 @Profile이 아니라 notification.mail.mode @ConditionalOnProperty로 하는가: 두 어댑터 모두 005 테스트 격리 가드 @Profile(kafkatest | !test)를 그대로 달아야 한다(풀컨텍스트 test에서 외부 SMTP 미접속). 같은 @Profile 문자열에 둘을 합치면 동일 가드로 둘 다 등록 -> NoUniqueBeanDefinitionException. 테스트 격리(@Profile)와 채널 선택(mail.mode)은 직교하는 두 축이므로 분리한다. -> 항상 정확히 하나 활성, 기본 log(소켓 없음).
- 왜 렌더러를 타입별 클래스 다발이 아니라 단일 렌더러 내부 switch로: 이벤트 4종 고정·계약 무변경이라 전략 패턴 레지스트리는 과설계(YAGNI). Java 21 switch 패턴 매칭으로 단일 NotificationMessageRenderer 안에서 타입별 분기. 테스트는 타입별 메서드 단위로 충분.
- 왜 005 단일 트랜잭션을 그대로 두는가: 6장 트레이드오프 참조(at-least-once 유실 방지 우선, exactly-once/post-commit은 024).

### 1.3 ShippingStartedEvent DTO와 catalog 간 기존 불일치 처리 (중요 — 정직 보고)
- catalog(020)는 ShippingStartedEvent에 shipmentId(long)와 items 배열(productId/productName/quantity)을 추가했으나, notification의 ShippingStartedEvent DTO에는 두 필드가 없다(005가 020 이전에 작성됨 — catalog 020 노트도 notification 소비자 미구현으로 적시).
- Task 023 요구는 ShippingStartedEvent -> 배송 시작 안내(주문번호·carrier·trackingNumber·이 배송분 items)이다. 현 DTO로는 items 렌더가 불가하다.
- 결정(계약 무변경 범위 내 미러 동기화): notification ShippingStartedEvent DTO를 catalog 1:1로 미러 보강한다 — shipmentId(long)와 items 필드를 추가하고, items용 ShipmentItem(productId/productName/quantity) record를 신설한다. 이는 event-catalog.md/architecture.md §5를 바꾸지 않으며(계약은 이미 020에서 확정), notification DTO는 계약 미러링 규칙을 충족시키는 소비 측 동기화다. items 미러가 없으면 Task의 shipping 렌더 요구(items 포함)를 충족할 수 없다.
- ShipmentItem은 OrderItem(unitPrice 보유)/CancelledItem과 별개 record다(배송 페이로드에 unitPrice 없음 — OrderItem 재사용 시 unitPrice가 조용히 0). 자족 충족.
- items 결손 처리(방향 B — 필수 결손 = non-retryable로 통일): catalog(020)에서 ShippingStartedEvent.items는 필수(✓) 필드다. 따라서 렌더 시 items가 null이거나 빈 목록이면 정상 분기로 흡수하지 않고 NonRetryableNotificationException으로 분류해 DLQ 직행시킨다 — plan 자신의 "필수 필드 결손(예: memberEmail 공백) → non-retryable" 원칙과 대칭. shipmentId·carrier·trackingNumber 등 다른 필수 필드 결손도 동일하게 "필수 결손 = non-retryable" 원칙으로 통일한다(필드별 분기를 나열하지 않고 단일 원칙 적용; 렌더러가 필수값 결손을 감지하면 NonRetryableNotificationException).
- 기존 테스트 샘플 갱신 필요: notification/src/test/java/com/shop/notification/dto/EventDeserializationTest.java의 ShippingStarted JSON 샘플(현재 shipmentId·items 없음 — 역직렬화 시 shipmentId=0, items=null)을 catalog 020 샘플(shipmentId + items[] 포함)로 갱신해야 한다. 옛 샘플을 그대로 두면 items=null로 필수 결손 → non-retryable 분류와 충돌하므로, 검증 섹션(5장)에 이 샘플 갱신을 명시한다. (테스트 코드 수정은 implementor가 수행.)

---

## 2. 구성 요소 (정확한 패키지·경로·시그니처)

### 2.1 신규 — DTO (계약 미러)
- notification/dto/OrderCancelledEvent.java : record OrderCancelledEvent(UUID eventId, Instant occurredAt, long orderId, String orderNumber, long memberId, String memberEmail, String memberName, List[CancelledItem] items, boolean refunded, long refundedAmount, String currency, Instant cancelledAt) implements EventEnvelope
- notification/dto/CancelledItem.java : record CancelledItem(long productId, String productName, int quantity) — OrderItem 재사용 금지(취소 페이로드엔 unitPrice 없음)
- notification/dto/ShipmentItem.java : record ShipmentItem(long productId, String productName, int quantity) — ShippingStarted items 미러(1.3). OrderItem/CancelledItem과 별개

catalog 필드 1:1. event-catalog.md/§5는 무변경.

### 2.2 수정 — DTO
- notification/dto/ShippingStartedEvent.java : catalog 020 미러 보강 — long shipmentId, List[ShipmentItem] items 추가(catalog 순서대로). 기존 필드와 implements EventEnvelope 유지

### 2.3 신규 — 렌더링
- notification/service/RenderedMessage.java : record RenderedMessage(String to, String subject, String body)
- notification/service/NotificationMessageRenderer.java : @Component @Profile(kafkatest | !test). RenderedMessage render(EventEnvelope event) — Java switch 패턴 매칭으로 4종 분기. 페이로드 자족 필드만 사용. 알 수 없는 타입/필수값(memberEmail 공백) -> NonRetryableNotificationException. from 주소는 발송 측(EmailSender)이 보유하므로 렌더러는 to만 생성.

렌더 규칙(자족 페이로드만):
- OrderCompletedEvent -> 제목 [주문 확정] {orderNumber}, 본문: 항목(productName x quantity) 목록 + 총액(totalAmount·currency).
- PaymentFailedEvent -> 제목 [결제 실패] {orderNumber}, 본문: 금액(amount·currency) + failureReason(사람이 읽는 문구). failureCode 등 내부 코드는 본문 노출 최소화(미포함).
- OrderCancelledEvent -> 제목 [주문 취소] {orderNumber}, 본문: 취소 항목 목록 + refunded 분기(true -> 환불 {refundedAmount} {currency} 문구, false -> 미결제 주문 취소 문구). 사용자취소/시스템만료 구분 안 함(계약에 필드 없음).
- ShippingStartedEvent -> 제목 [배송 시작] {orderNumber}, 본문: carrier + trackingNumber + 이 배송분 items 목록. items는 catalog 필수(✓) 필드이므로 null/빈 목록이면 NonRetryableNotificationException(필수 결손 = non-retryable, 1.3). shipmentId는 내부 식별자라 본문 노출 최소화(로깅용).

### 2.4 신규/교체 — 발송 오케스트레이터
- notification/service/EmailNotificationDispatchService.java (신규) : @Service @Profile(kafkatest | !test) implements NotificationDispatchService. 생성자 주입 NotificationMessageRenderer, EmailSender. dispatch(EventEnvelope): render -> emailSender.send(to, subject, body). 실패 분류(4장)로 NotificationException(retryable)/NonRetryableNotificationException 전파. 발송 성공/타입/eventId 로깅.
- notification/service/LoggingNotificationDispatchService.java (제거) : 로그-only 동작은 LoggingEmailSender가 승계. dispatch 구현은 EmailNotificationDispatchService 단일.

NotificationDispatchService 인터페이스는 시그니처 무변경(void dispatch(EventEnvelope)). Javadoc만 스텁 -> 실제 이메일 발송으로 갱신.

### 2.5 신규 — 전송 채널 포트 + 어댑터 2종
- notification/service/EmailSender.java (포트) : interface EmailSender 에 void send(String to, String subject, String body) 한 메서드. 얇은 인터페이스. SMS/푸시 포트 없음(YAGNI).
- notification/service/LoggingEmailSender.java (dev/기본) : @Component @Profile(kafkatest | !test) + @ConditionalOnProperty(name=notification.mail.mode, havingValue=log, matchIfMissing=true). 소켓 없음 — to/subject 로그만 출력. 005 [DISPATCH] 로그 동작 승계.
- notification/service/JavaMailEmailSender.java (운영 SMTP) : @Component @Profile(kafkatest | !test) + @ConditionalOnProperty(name=notification.mail.mode, havingValue=smtp). JavaMailSender(spring-boot-starter-mail) 주입 + MailProperties(from 주소). SimpleMailMessage 구성 후 mailSender.send(...). 블로킹 SMTP I/O는 이 어댑터(Infra 경계)에 격리, ThreadLocal 미사용. org.springframework.mail.MailException을 잡아 4장 분류로 NotificationException/NonRetryableNotificationException 변환.

둘 다 동일 @Profile 가드 + 직교 프로퍼티로 항상 정확히 하나 활성. 기본 log라 로컬·kafkatest·SMTP 미설정 운영에서 소켓 안 엶.

### 2.6 신규 — 설정 프로퍼티
- notification/common/config/MailProperties.java : @ConfigurationProperties(prefix=notification.mail) record MailProperties(String mode, String from). 컴팩트 생성자에서 mode 기본 log, from 기본값(예: no-reply@shop.local) 폴백(RedisProperties 패턴 동일).
- @EnableConfigurationProperties 등록 위치(명시): 기존 등록 지점은 RedisConfig의 @EnableConfigurationProperties(RedisProperties.class)(notification/src/main/java/com/shop/notification/common/config/RedisConfig.java:25)다. 동일 패턴으로 신규 @Configuration MailConfig(notification/common/config/MailConfig.java)에 @EnableConfigurationProperties(MailProperties.class)를 둔다(또는 기존 설정 클래스에 어노테이션 추가). implementor 추정 제거 — RedisConfig 패턴을 따른다.

### 2.7 수정 — Consumer
- notification/consumer/NotificationEventConsumer.java : order-cancelled @KafkaListener(groupId=notification, containerFactory=kafkaListenerContainerFactory) 메서드 onOrderCancelled(OrderCancelledEvent) 추가 -> processingService.process(event) 위임(기존 3종과 동일 패턴). import 추가. Repository 직접 호출·예외 흡수 없음.

### 2.8 수정 — 빌드/설정
- notification/build.gradle : spring-boot-starter-mail 의존 추가.
- notification/src/main/resources/application.yml : spring.mail.*(host/port/username/password — 환경변수 오버라이드, 기본 빈/주석 자리) + notification.mail.mode 기본 log(NOTIFICATION_MAIL_MODE) + notification.mail.from 기본 no-reply@shop.local(NOTIFICATION_MAIL_FROM) 추가. 기존 블록 변경 없음.

### 2.9 재사용·무변경 (재설계 금지)
EventProcessingService, EventProcessingTransactionHelper, ProcessedEvent/ProcessedEventRepository, EventEnvelope, KafkaConsumerConfig(DefaultErrorHandler/addNotRetryableExceptions 그대로 — NonRetryableNotificationException이 이미 DLQ 직행 분류됨), NotificationException/NonRetryableNotificationException/ProcessingError. 신규 Flyway 마이그레이션 없음. docs/event-catalog.md/architecture.md §5 무변경. Redis dedup 미적용(009).

---

## 3. 데이터 흐름

### 3.1 정상 (1건)
1. Kafka에서 order-cancelled(또는 기존 3종) 레코드 수신 -> StringJsonMessageConverter가 OrderCancelledEvent로 역직렬화 -> NotificationEventConsumer.onOrderCancelled.
2. EventProcessingService.process(event): existsByEventId(eventId) 사전 체크 -> 미존재 -> transactionHelper.claimAndDispatch(event) 호출.
3. claimAndDispatch(@Transactional): processedEventRepository.save(ProcessedEvent.processed(...)) + flush()로 claim.
4. 같은 TX 내 dispatchService.dispatch(event): NotificationMessageRenderer.render(event) -> RenderedMessage(to=memberEmail, subject, body) -> EmailSender.send(to, subject, body)(log 모드면 로그만, smtp 모드면 SMTP 전송).
5. 전송 성공 -> dispatch 정상 반환 -> [PROCESSED] 로그 -> 트랜잭션 커밋(claim 확정). 메시지 RECORD ack.

### 3.2 실패 — 일시(retryable)
- EmailSender.send에서 일시적 SMTP 오류(연결/타임아웃 등) -> 어댑터가 NotificationException(msg, cause, retryable=true)로 변환·전파.
- claimAndDispatch가 NotificationException을 catch하지 않고 ProcessingError 로깅 후 재throw -> @Transactional 롤백 -> claim도 롤백(재처리 가능 불변식).
- EventProcessingService.process는 NotificationException을 흡수하지 않음 -> 컨테이너 DefaultErrorHandler로 전파 -> FixedBackOff(backoff-ms, max-attempts-1) 재시도 -> 소진 시 DeadLetterPublishingRecoverer가 원본토픽.DLQ로 라우팅.

### 3.3 실패 — 영구(non-retryable)
- 렌더 불가(알 수 없는 타입·memberEmail 공백·필수 필드 결손[예: ShippingStarted items null/빈 목록], 1.3) 또는 영구 SMTP 거절(주소 형식 오류 등) -> NonRetryableNotificationException(NotificationException 하위).
- 동일하게 TX 롤백·claim 롤백 후 전파. DefaultErrorHandler.addNotRetryableExceptions(NonRetryableNotificationException.class)(기존 배선)가 재시도 없이 즉시 DLQ 라우팅.

### 3.4 중복 수신
- process 사전 existsByEventId true -> [DUPLICATE] skip 후 dispatch 호출 0 -> 발송 0건.
- 사전 체크 통과 후 동시 경합 시 save+flush가 DataIntegrityViolationException(UNIQUE 위반) -> 협력 빈 TX 롤백 -> process(TX 경계 밖)가 흡수 -> [DUPLICATE] race condition absorbed, 발송 0건.

이메일은 롤백 불가 외부 부작용. 3.1에서 전송 성공 -> 커밋 실패(드묾) 시 재시도로 이메일 1회 추가 가능(at-least-once). DB 멱등이 지배적 dedup. 6장 참조.

---

## 4. 예외 처리 전략

- 일시 SMTP 오류(연결 거부/타임아웃/일시 5xx) -> NotificationException(msg, cause, retryable=true) [retryable] -> TX 롤백(claim 롤백) -> 컨테이너 재시도 -> 소진 시 DLQ.
- 영구 SMTP 거절(주소 형식 오류·수신 거부 등 재시도 무의미) -> NonRetryableNotificationException [non-retryable] -> TX 롤백 -> 재시도 없이 DLQ 직행.
- 렌더 불가(알 수 없는 이벤트 타입, memberEmail null/blank, 필수 필드 결손 — 예: ShippingStarted items가 null/빈 목록, shipmentId·carrier·trackingNumber 결손) -> NonRetryableNotificationException [non-retryable] -> 동일하게 DLQ 직행. 원칙: catalog 필수(✓) 필드 결손 = non-retryable(필드별 분기 없이 단일 원칙, 1.3).

분류 기준·배선:
- retryable 판단(JavaMailEmailSender 최소 매핑): org.springframework.mail.MailException 계층을 어댑터에서 다음으로 분기한다.
  - 연결/타임아웃류(MailSendException 중 전송 실패 — 일시 네트워크/일시 5xx) -> NotificationException(retryable=true) [retryable].
  - 주소 형식 거절(수신자 주소 무효 등) -> NonRetryableNotificationException [non-retryable](재시도해도 동일).
  - 인증 실패(MailAuthenticationException) -> NonRetryableNotificationException [non-retryable](인증은 재시도해도 동일하게 실패).
  - 그 외 모호한 MailException -> retryable 기본(안전망: 유실보다 재시도 우선 — Task at-least-once 정책과 정합).
- 트랜잭션 롤백: NotificationException은 RuntimeException -> @Transactional 기본 롤백 대상. EventProcessingTransactionHelper가 catch 후 ProcessingError.from(...) 로깅하고 재throw(005 그대로). claim+dispatch 단일 TX라 claim도 함께 롤백 -> 재처리 시 멱등 마킹 없음 -> 재발송 가능.
- 재시도/DLQ: 005의 DefaultErrorHandler(FixedBackOff) + DeadLetterPublishingRecoverer + addNotRetryableExceptions(NonRetryableNotificationException.class) 그대로 재사용. 본 Task는 별도 재시도 프레임워크/Resilience4j 도입 안 함(024).
- 경합 예외: DataIntegrityViolationException은 process가 TX 경계 밖에서 흡수(005 그대로) — 발송 예외 분류와 무관.

신규 예외 타입 추가 없음(005의 2종 재사용). ProcessingError의 retryable 힌트·로깅 그대로 활용.

---

## 5. 검증 방법 (테스트 항목 -> Acceptance Criteria 매핑)

모든 신규 발송/채널/렌더 테스트는 실제 SMTP 미사용. Mock/Fake EmailSender 또는 mail.mode=log 기본. 테스트 규칙·verification-gate 준수.

### 5.1 단위 — 렌더링 (NotificationMessageRendererTest)
- 4종 각각 render(event)의 to=memberEmail, subject/body에 페이로드 필드 포함 단언.
  - OrderCancelled refunded=true -> 환불 금액 문구 포함, refunded=false -> 미결제 취소 문구·환불 문구 부재.
  - PaymentFailed -> failureReason 포함, failureCode 미포함(내부 코드 노출 최소).
  - ShippingStarted -> carrier/trackingNumber/items 목록 포함. items가 null이거나 빈 목록일 때 NonRetryableNotificationException(필수 결손 = non-retryable, 1.3).
- 자족성 단언: 렌더러가 Repository/외부 클라이언트 의존 없음(생성자 무인자 또는 MailProperties만). shop-core 참조 0.
- 알 수 없는 타입·memberEmail blank -> NonRetryableNotificationException.
- AC 매핑: 타입별 제목·본문·수신자 렌더, refunded 분기, 자족 페이로드만.

### 5.2 단위 — 발송 오케스트레이터 (EmailNotificationDispatchServiceTest, Mockito)
- Mock NotificationMessageRenderer + Mock EmailSender: 정상 시 emailSender.send(to, subject, body) 1회(ArgumentCaptor로 인자 검증).
- EmailSender.send가 일시 오류 던질 때 -> NotificationException(retryable) 전파.
- 영구 오류(주소 형식 등)/렌더 예외 -> NonRetryableNotificationException 전파.
- AC 매핑: EmailSender로 전송, 일시/영구 실패 분류.

### 5.3 단위 — Consumer (NotificationEventConsumerTest 보강)
- onOrderCancelled(event) -> processingService.process(event) 정확히 1회(기존 3종 패턴 동일).
- AC 매핑: order-cancelled 구독·핸들러 연결.

### 5.4 단위 — DTO 역직렬화 (EventDeserializationTest 보강)
- catalog order-cancelled JSON -> OrderCancelledEvent 전 필드 매핑(items->CancelledItem, refunded/refundedAmount/currency/cancelledAt).
- OrderCancelledEvent implements EventEnvelope 단언.
- (샘플 갱신) 기존 ShippingStarted JSON 샘플(shipmentId·items 없음)을 catalog 020 샘플(shipmentId + items[] 포함)로 교체하고 shipmentId·items(+ShipmentItem) 매핑 단언 추가. 옛 샘플을 두면 items=null이 되어 1.3의 필수 결손 = non-retryable 분류와 충돌하므로 교체 필수.
- AC 매핑: DTO 미러, 신설 order-cancelled 포함.

### 5.5 슬라이스 — 멱등/트랜잭션 (EventProcessingServiceTransactionTest 재사용/회귀)
- dispatch가 실제 발송으로 바뀐 뒤에도: 정상 claim 커밋·dispatch 1회, dispatch 예외 시 claim 롤백(이력 0건·재처리 가능), 중복 eventId 흡수. NotificationDispatchService를 @MockitoBean으로 두어 실제 발송 없이 검증(기존 패턴 그대로).
- AC 매핑: 정상 시 processed 성공·1건 전송, 재수신 1회만, 실패 시 롤백.

### 5.6 통합 — EmbeddedKafka (NotificationEventConsumerIntegrationTest 보강, 005 패턴)
- @EmbeddedKafka topics에 order-cancelled·order-cancelled.DLQ 추가.
- order-cancelled 정상 produce -> 발송 1회 + processed_event(Fake store) 1건.
- 일시 실패 강제(Fake/@Primary 오버라이드로 retryable 예외) -> 재시도 후 order-cancelled.DLQ 라우팅(DLT 헤더 검증, 기존 DLQ 테스트 패턴).
- 중복 소비 -> 발송 추가 없음.
- 오버라이드 계층: 기존처럼 NotificationDispatchService를 @Primary Fake로 두거나, EmailSender만 Fake로 두는 두 방식 중 택1(기본 mail.mode=log면 LoggingEmailSender라 소켓 없음).
- AC 매핑: 4토픽 구독·발송 연결(신설 order-cancelled), 일시 실패->DLQ, 멱등.

### 5.7 회귀 / 가드
- 기존 3토픽 발송 경로·005 멱등/DLQ 테스트 그린 유지.
- 풀컨텍스트 test(단독 프로파일)가 SMTP 접속 시도 안 함: 신규 발송/채널/렌더 빈 @Profile(kafkatest | !test) 가드 확인. mail.mode 미설정 시 LoggingEmailSender 활성(소켓 없음). JavaMailEmailSender는 mail.mode=smtp에서만 등록.
- (선택) MailPropertiesTest(ApplicationContextRunner, RedisPropertiesTest 패턴): mode 기본 log·from 기본값 폴백·오버라이드 바인딩.
- AC 매핑: 풀컨텍스트 test 외부 접속 없음, 005 회귀 없음, catalog/§5 무변경·신규 마이그레이션 없음.

---

## 6. 트레이드오프

1. at-least-once 단일 트랜잭션 유지 (채택)
   - 득: 전송 실패 시 롤백->재시도로 알림 유실 방지. 005 구조 보존(재설계 0). DB 멱등이 지배적 dedup.
   - 실: 전송 성공 -> 커밋 실패(드묾) 시 동일 이벤트 재시도로 이메일 1회 추가 발송 가능(잔여 중복 윈도우는 커밋 실패 시점 한정).
   - 대안(미채택): post-commit/발송상태머신/이력 테이블로 exactly-once 윈도우 축소 -> 024(backlog 009 승격) 범위. 본 Task 구조 변경 금지.

2. 블로킹 SMTP in-transaction (수용)
   - 득: 005 단일 TX 단순성 유지. 추가 스레드/비동기 인프라 없음.
   - 실: SMTP 전송 시간만큼 DB 트랜잭션·커넥션 보유 길어짐. 사이드 프로젝트 수용 범위.
   - 완화: 블로킹 I/O를 EmailSender 어댑터(Infra 경계)에 격리, ThreadLocal 직접 사용 금지(가상스레드 대비, CLAUDE.md). 비동기/post-commit 분리는 024.

3. dev/운영 어댑터 프로퍼티 택1 (notification.mail.mode)
   - 득: 테스트 격리(@Profile)와 채널 선택(mail.mode) 직교 분리로 NoUniqueBeanDefinitionException 회피. 기본 log라 로컬·CI·SMTP 미설정 운영에서 소켓 0. 운영은 env로 smtp 전환만.
   - 실: 빈 활성 조건이 @Profile + @ConditionalOnProperty 2축이라 배선 이해 비용 약간 증가. 잘못된 mail.mode 값(오타) 시 두 어댑터 모두 비활성 -> EmailSender 빈 부재로 dispatch 실패 가능 -> matchIfMissing=true(log)와 문서/yml 기본값으로 완화.

4. 렌더러 단일 클래스 switch vs 타입별 렌더러 다발 (단일 채택)
   - 득: 이벤트 4종 고정·계약 무변경이라 단순·테스트 용이. 과설계 회피(YAGNI).
   - 실: 향후 이벤트 종류 급증 시 switch 비대 -> 그 시점에 전략 레지스트리로 리팩터(현재 불필요).

5. ShippingStartedEvent DTO 미러 보강 (1.3)
   - 득: Task의 shipping items 렌더 요구 충족. catalog(020)와 소비 측 DTO 정합 회복. 계약 SSOT 무변경(미러 동기화만).
   - 실: 005가 만든 DTO에 필드 2개와 record 1개 추가 -> 기존 ShippingStarted 역직렬화 테스트 영향(필드 없는 옛 샘플은 shipmentId=0·items=null). 방향 B(필수 결손 = non-retryable, 1.3)를 채택하므로 옛 샘플을 catalog 020 샘플(shipmentId·items 포함)로 교체해 흡수하고, items 결손은 렌더러에서 NonRetryableNotificationException으로 분류(memberEmail 결손 처리와 대칭).

---

## 완료 조건 (체크리스트)
- [ ] OrderCancelledEvent/CancelledItem DTO 신설(catalog 1:1, OrderItem 재사용 안 함), ShippingStartedEvent+ShipmentItem 미러 보강.
- [ ] NotificationEventConsumer에 order-cancelled 리스너 추가(4종, process 위임만).
- [ ] NotificationDispatchService 단일 구현 EmailNotificationDispatchService(렌더+위임+실패분류), LoggingNotificationDispatchService 제거.
- [ ] NotificationMessageRenderer(4종 렌더, refunded 분기, failureReason 사용, 자족), RenderedMessage.
- [ ] EmailSender 포트 + LoggingEmailSender(기본·소켓 없음)/JavaMailEmailSender(smtp). 둘 다 @Profile(kafkatest|!test) + notification.mail.mode @ConditionalOnProperty 택1.
- [ ] MailProperties(notification.mail), application.yml에 spring.mail.* + notification.mail.mode/from, build.gradle에 spring-boot-starter-mail.
- [ ] 단위/슬라이스/통합 테스트(5장) 추가·그린. 005 멱등/DLQ·기존 3토픽 회귀 없음.
- [ ] 풀컨텍스트 test에서 SMTP 미접속(가드 확인). event-catalog.md/architecture.md §5 무변경, 신규 토픽/필드/마이그레이션 없음, shop-core 미참조.

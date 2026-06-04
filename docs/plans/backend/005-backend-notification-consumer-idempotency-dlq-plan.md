# 005. notification Kafka Consumer 골격 + 멱등 체크 테이블 + DLQ — 구현 Plan

> 영역: backend (Kafka Consumer 골격 + 이벤트 DTO + 멱등 처리 이력 + 재시도/DLQ 에러 핸들링 + 알림 발송 스텁 + 테스트)
> 대상 프로젝트: notification (순수 Kafka Consumer, REST 없음)
> 작성일: 2026-06-03
> 상태: plan only (코드 변경 없음)

---

## 구현 목표
shop-core 공개 이벤트 3종(`order-completed`/`payment-failed`/`shipping-started`)을 구독하는 Kafka Consumer 골격을 만들고, `eventId` 기반 멱등 처리 이력 테이블과 재시도→DLQ 경로를 구성해 소비 신뢰성의 최소 동작을 검증한다. 실제 발송은 스텁/로그 Service로 대체한다.

## 영향 범위

### 신규 파일 (main)
- DTO (이벤트 봉투 + 3종 페이로드)
  - `notification/src/main/java/com/shop/notification/dto/EventEnvelope.java` (공통 봉투 인터페이스: `eventId()`, `occurredAt()`)
  - `notification/src/main/java/com/shop/notification/dto/OrderCompletedEvent.java`
  - `notification/src/main/java/com/shop/notification/dto/OrderItem.java` (OrderCompletedEvent의 `items[]` 중첩 DTO)
  - `notification/src/main/java/com/shop/notification/dto/PaymentFailedEvent.java`
  - `notification/src/main/java/com/shop/notification/dto/ShippingStartedEvent.java`
- Consumer
  - `notification/src/main/java/com/shop/notification/consumer/NotificationEventConsumer.java` (3개 `@KafkaListener` 메서드, Service로만 위임)
- 멱등 도메인/리포지토리
  - `notification/src/main/java/com/shop/notification/domain/ProcessedEvent.java` (멱등 처리 이력 Entity, BaseEntity 상속)
  - `notification/src/main/java/com/shop/notification/domain/ProcessingStatus.java` (enum: `PROCESSED`, `FAILED`)
  - `notification/src/main/java/com/shop/notification/repository/ProcessedEventRepository.java`
- Service
  - `notification/src/main/java/com/shop/notification/service/EventProcessingService.java` (오케스트레이션: 멱등 체크 → 발송 위임 → 이력 저장, 트랜잭션 경계 소유)
  - `notification/src/main/java/com/shop/notification/service/NotificationDispatchService.java` (발송 스텁 인터페이스)
  - `notification/src/main/java/com/shop/notification/service/LoggingNotificationDispatchService.java` (스텁 구현: 로그만)
- 예외
  - `notification/src/main/java/com/shop/notification/common/exception/NonRetryableNotificationException.java` (마커 하위 예외, 즉시 DLQ 분류용 — 섹션 4.2)
- Kafka 설정
  - `notification/src/main/java/com/shop/notification/common/config/KafkaConsumerConfig.java` (ConsumerFactory / ListenerContainerFactory / DefaultErrorHandler + DeadLetterPublishingRecorder + KafkaTemplate)

### 신규 파일 (test)
- 단위 테스트
  - `notification/src/test/java/com/shop/notification/dto/EventDeserializationTest.java`
  - `notification/src/test/java/com/shop/notification/service/EventProcessingServiceTest.java`
  - `notification/src/test/java/com/shop/notification/consumer/NotificationEventConsumerTest.java`
- 통합 테스트 (EmbeddedKafka)
  - `notification/src/test/java/com/shop/notification/consumer/NotificationEventConsumerIntegrationTest.java` (정상/중복/DLQ)
  - `notification/src/test/java/com/shop/notification/support/FakeProcessedEventStore.java` (DB 없는 통합 테스트용 인메모리 멱등 저장 더미 — 섹션 5.3 참조)
- 통합 테스트 profile
  - `notification/src/test/resources/application-kafkatest.yml` (Kafka 자동설정만 활성, DB는 계속 제외 — 섹션 5.3)

### 수정 파일
- `notification/src/main/resources/application.yml` (재시도/backoff/DLQ 관련 커스텀 프로퍼티 + DLQ produce용 producer 직렬화. 기존 kafka consumer 블록은 유지)
- `notification/src/test/resources/application.yml` (변경 없음이 원칙. 통합 테스트는 별도 `kafkatest` profile에서 자동설정 제외를 무력화 — 섹션 5.3)

### 범위 밖 (필요성만 명시, 후속 Task로 미룸)
- 실제 이메일/SMS/푸시 발송, 멀티채널 라우팅, 외부 게이트웨이 연동, 발송 결과(채널별) 영속 엔티티
- 재시도 토픽 체이닝(retry-topic), `@RetryableTopic` 기반 비차단 재시도
- DLQ 컨슈머/재처리(reprocess) 파이프라인, DLQ 적재 모니터링
- 멱등 이력 보존기간(TTL)·아카이빙, Flyway 스키마 관리(현재 ddl-auto=create 유지)

---

## 1. 설계 방식 및 이유

### 1.1 멱등 처리 위치와 순서 (발송 "전" 멱등 체크)
- 순서: `eventId` 멱등 체크 → 미처리면 발송(스텁) → 처리 이력 `PROCESSED` 저장. 즉 멱등 체크를 발송 앞단에 둔다.
- 근거: 알림은 "한 번만 보낸다"가 핵심이므로 동일 `eventId` 재수신 시 발송 로직 자체가 다시 실행되면 안 된다. 발송 후 체크로는 중복 발송을 막을 수 없다.
- 구현: `EventProcessingService`가 단일 트랜잭션 안에서 (a) `eventId` 존재 여부 확인 (b) 신규면 `ProcessedEvent` insert + 발송 위임 (c) 커밋. 동일 `eventId`가 이미 있으면 발송을 건너뛰고 "중복" 로그만 남긴다.
- 동시성: 같은 `eventId`가 거의 동시에 두 번 도착하는 경합은 DB의 `eventId` 유니크 제약으로 최종 방어한다. insert 시 `DataIntegrityViolationException`이 나면 "이미 다른 처리가 선점함 = 중복"으로 간주해 발송하지 않고 정상(중복) 처리로 흡수한다(예외를 재시도로 전파하지 않음).

### 1.2 멱등 마킹 전략 — "처리 시작 시 insert" vs "성공 후 insert"
- 채택: 성공 경로 기준 "발송 직전 insert + 같은 트랜잭션 커밋"(claim-then-send). 발송 스텁이 동기·무부작용(로그)이라 트랜잭션 내 발송이 안전하다.
- 실패 시: 발송 위임이 `NotificationException`을 던지면 트랜잭션을 롤백해 `ProcessedEvent`도 함께 롤백한다 → 처리 이력이 남지 않으므로 재시도/재수신 시 다시 처리 가능(at-least-once 의미 보존). 즉 "성공해야 멱등 마킹이 영속된다".
- `FAILED` 상태 저장은 멱등 트랜잭션과 분리한다(섹션 1.4 트랜잭션 경계). 멱등 키 점유와 실패 기록의 의미가 다르기 때문이다.
- 트레이드오프와 대안은 섹션 6.

### 1.3 Kafka 에러 핸들러: DefaultErrorHandler + DeadLetterPublishingRecorder (컨테이너 단위)
- 채택: 컨테이너 레벨 `DefaultErrorHandler`에 `DeadLetterPublishingRecorder`를 결합. 재시도(고정 backoff) 소진 후 원본 토픽 + `.DLQ`로 자동 라우팅한다.
- DLQ 토픽 네이밍: `DeadLetterPublishingRecorder`의 destination resolver를 커스터마이즈해 기본 `<topic>-dlt`가 아니라 `<topic>.DLQ`(Task 규칙)로 보낸다. 예: `order-completed` → `order-completed.DLQ`.
- 근거:
  - spring-kafka 표준 메커니즘으로 "재시도 + DLQ 전송 + 원본 페이로드/추적 헤더 보존"을 한 곳에서 선언적으로 처리한다. `DeadLetterPublishingRecorder`가 원본 key/value/파티션과 `kafka_dlt-*` 예외 헤더(예외 클래스/메시지/스택/원본 토픽·오프셋)를 자동 부착하므로 "추적 가능한 헤더 보존" 요구를 직접 코딩 없이 충족한다.
  - 비차단 재시도(`@RetryableTopic`/retry-topic 체이닝)는 토픽 수가 늘고 운영 복잡도가 커져 본 Task 범위(골격)에는 과하다(YAGNI). 차단형 `DefaultErrorHandler`로 충분.
- 메서드 단위(try/catch in listener)로 DLQ를 직접 produce하지 않는 이유: 재시도·백오프·헤더 부착·offset commit 타이밍을 컨테이너가 일관되게 관리하도록 위임하는 편이 견고하다(섹션 6).

### 1.4 트랜잭션 경계
- `EventProcessingService.process(...)`(멱등 체크 + 멱등 insert + 발송 위임)는 `@Transactional`로 하나의 경계로 묶는다. 발송 스텁 실패 시 멱등 insert가 함께 롤백되어 "성공해야 마킹 영속" 불변식을 보장한다.
- 실패 이력(`FAILED`) 기록이 필요한 경우는 `@Transactional(propagation = REQUIRES_NEW)` 별도 경계의 보조 메서드(`markFailed`)로 남긴다(주 트랜잭션 롤백과 독립적으로 남도록). 단 본 Task에서 `FAILED` 영속은 "선택적 보강"으로 두고, 최소 구현은 로깅(ProcessingError) 우선 — 과도 설계 방지(섹션 6, 열린 결정).
- Kafka offset commit과 DB 트랜잭션은 분산 트랜잭션으로 묶지 않는다(YAGNI). at-least-once + DB 멱등으로 정확히 한 번의 효과(effectively-once)를 달성한다. 이 조합이 멱등 테이블을 두는 본질적 이유다.
- `EventProcessingService`는 컨슈머 스레드에서 호출되므로 컨테이너 ack-mode는 기본(`BATCH`/리스너 정상 반환 시 commit) 또는 `RECORD`로 두어, 리스너가 예외 없이 반환해야 offset이 커밋되도록 한다(실패 시 재시도/ DLQ 후 commit).

### 1.5 이벤트 공통 봉투(Envelope) 처리
- 3종 이벤트는 공통으로 `eventId`(UUID string), `occurredAt`(ISO-8601) 를 가진다(event-catalog.md). 공통 접근을 위해 `EventEnvelope` 인터페이스를 두고 3개 DTO가 구현한다 → Consumer/Service가 `eventId`/`occurredAt`을 타입 안전하게 추출(멱등 키, 추적).
- DTO는 불변 `record`로 정의하고 Jackson 역직렬화 대상으로 둔다(`JsonDeserializer` 사용). 필드명은 event-catalog.md와 1:1. `eventId`는 `UUID`, `occurredAt`/`orderedAt`/`attemptedAt`/`shippedAt` 등 시각은 `Instant`로 매핑(ISO-8601 UTC). 금액은 `long`, 수량은 `int`.
- DTO/Entity 분리: 이벤트 DTO(`dto`)와 멱등 Entity(`domain`)는 완전히 분리한다. Entity는 외부로 노출하지 않는다(REST 없음 + 규칙).
- 봉투 계약은 event-catalog.md SSOT를 그대로 반영만 하고 **변경하지 않는다**(이벤트 계약 변경 금지).

---

## 2. 구성 요소 (생성할 클래스/파일)

### main

#### com.shop.notification.dto.EventEnvelope
- 역할: 모든 이벤트 DTO가 구현하는 공통 봉투. 멱등 키·추적 시각 추출 단일 통로.
- 형태: `public interface EventEnvelope { UUID eventId(); Instant occurredAt(); }`
- 비고: record가 인터페이스를 구현하면 accessor 메서드가 자동으로 계약을 충족한다.

#### com.shop.notification.dto.OrderCompletedEvent (record, implements EventEnvelope)
- 필드(event-catalog.md OrderCompletedEvent 전부): `UUID eventId`, `Instant occurredAt`, `long orderId`, `String orderNumber`, `long memberId`, `String memberEmail`, `String memberName`, `List<OrderItem> items`, `long totalAmount`, `String currency`, `Instant orderedAt`.
- 비고: `items`는 중첩 DTO 리스트.

#### com.shop.notification.dto.OrderItem (record)
- 필드: `long productId`, `String productName`, `int quantity`, `long unitPrice`.

#### com.shop.notification.dto.PaymentFailedEvent (record, implements EventEnvelope)
- 필드: `UUID eventId`, `Instant occurredAt`, `long orderId`, `String orderNumber`, `long memberId`, `String memberEmail`, `String memberName`, `long amount`, `String currency`, `String failureCode`, `String failureReason`, `Instant attemptedAt`.

#### com.shop.notification.dto.ShippingStartedEvent (record, implements EventEnvelope)
- 필드: `UUID eventId`, `Instant occurredAt`, `long orderId`, `String orderNumber`, `long memberId`, `String memberEmail`, `String memberName`, `String carrier`, `String trackingNumber`, `Instant shippedAt`.

#### com.shop.notification.domain.ProcessingStatus (enum)
- 값: `PROCESSED`, `FAILED`. (멱등 이력의 처리 상태)

#### com.shop.notification.domain.ProcessedEvent (Entity, extends BaseEntity)
- 역할: 멱등 처리 이력. `eventId` 유니크로 중복 처리 차단 + 상태 추적.
- 애너테이션: `@Entity`, `@Table(name = "processed_event", uniqueConstraints = @UniqueConstraint(columnNames = "event_id"))`, Lombok `@Getter`, `@NoArgsConstructor(access = PROTECTED)`.
- 필드:
  - `@Id @GeneratedValue(strategy = IDENTITY) private Long id;`
  - `@Column(name = "event_id", nullable = false, unique = true) private UUID eventId;`
  - `@Column(name = "event_type", nullable = false) private String eventType;` (예: `OrderCompletedEvent`)
  - `@Enumerated(STRING) @Column(nullable = false) private ProcessingStatus status;`
  - `@Column private String failureReason;` (FAILED일 때만)
  - (createdAt/updatedAt은 BaseEntity 상속)
- 정적 팩토리: `static ProcessedEvent processed(UUID eventId, String eventType)`, `static ProcessedEvent failed(UUID eventId, String eventType, String reason)`.
- 비고: Entity 외부 노출 금지 — Service 내부에서만 사용, Consumer로 반환하지 않는다.

#### com.shop.notification.repository.ProcessedEventRepository
- `interface ProcessedEventRepository extends JpaRepository<ProcessedEvent, Long>`
- 메서드: `boolean existsByEventId(UUID eventId);`
- 비고: Service만 호출(Consumer 직접 호출 금지).

#### com.shop.notification.service.NotificationDispatchService (인터페이스)
- 역할: 발송 추상화(스텁/실구현 교체 지점). 실제 발송 미구현.
- 메서드: `void dispatch(EventEnvelope event);` (이벤트 타입별 분기는 구현체 내부 instanceof 패턴매칭 또는 오버로드 — 스텁은 타입명·수신자만 로깅).

#### com.shop.notification.service.LoggingNotificationDispatchService (구현, @Service)
- 역할: 발송 스텁. `log.info("[DISPATCH] type={}, eventId={}, to={}", ...)`만 수행. 실제 이메일/SMS/푸시 호출 없음(Constraint 준수).
- 비고: 향후 실제 채널 구현으로 교체될 단일 후크.

#### com.shop.notification.service.EventProcessingService (@Service)
- 역할: 멱등 + 발송 오케스트레이션. Consumer가 위임하는 유일한 진입점. Repository는 여기서만 호출.
- 핵심 메서드: `@Transactional void process(EventEnvelope event)`
  - 1) `if (repo.existsByEventId(event.eventId())) { log "[DUPLICATE]"; return; }`
  - 2) 신규: `repo.save(ProcessedEvent.processed(eventId, typeName))` (유니크 충돌 시 `DataIntegrityViolationException` → "[DUPLICATE]"로 흡수, 재throw 안 함)
  - 3) `dispatchService.dispatch(event)` 호출
  - 4) 성공 로그 `[PROCESSED]`. 실패(`NotificationException`)면 트랜잭션 롤백되며 호출자(컨테이너 에러 핸들러)로 전파 → 재시도/DLQ.
- 보조: (선택) `markFailed(...)`는 후속 보강 시 `REQUIRES_NEW`로 분리. 최소 구현은 `ProcessingError` 로깅으로 대체(열린 결정 4.5).
- `eventType` 결정: `event.getClass().getSimpleName()`.

#### com.shop.notification.consumer.NotificationEventConsumer (@Component)
- 역할: 3개 토픽 구독 골격. **로직 없음 — Service로만 위임**(레이어 규칙). Repository 직접 호출 금지.
- 메서드(각 `@KafkaListener(topics = "...", groupId = "notification", containerFactory = "...")`):
  - `void onOrderCompleted(OrderCompletedEvent event)` → `processingService.process(event)`
  - `void onPaymentFailed(PaymentFailedEvent event)` → `processingService.process(event)`
  - `void onShippingStarted(ShippingStartedEvent event)` → `processingService.process(event)`
- 비고: 예외를 잡지 않는다(throw 그대로 전파 → 컨테이너 `DefaultErrorHandler`가 재시도/DLQ 결정). group-id는 yml 기본값(notification)과 일치.

#### com.shop.notification.common.exception.NonRetryableNotificationException (신규)
- 역할: 재시도 무의미한 영구 오류 마커. `DefaultErrorHandler.addNotRetryableExceptions(...)`로 즉시 DLQ 분류용.
- `extends NotificationException`. 생성자는 `(String message)`, `(String message, Throwable cause)`로 부모에 위임(retryable=false 의미 고정).
- 비고: 과한 계층 금지 — 본 Task에서 추가하는 유일한 하위 예외.

#### com.shop.notification.common.config.KafkaConsumerConfig (@Configuration)
- 역할: ConsumerFactory / ListenerContainerFactory / 에러 핸들러 / DLQ 라우팅 / KafkaTemplate(DLQ produce용) 구성.
- 빈:
  - `ConsumerFactory<String, Object>`: yml의 bootstrap/group/deserializer 사용(`JsonDeserializer`, trusted packages `com.shop.*`). 타입 헤더 부재 대비 `JsonDeserializer`의 type mapping 또는 `@KafkaListener` 파라미터 타입 기반 역직렬화 활용.
  - `ProducerFactory<String, Object>` + `KafkaTemplate<String, Object>`: DLQ 전송용(JSON 직렬화).
  - `DeadLetterPublishingRecorder`: destination resolver를 `(record, ex) -> new TopicPartition(record.topic() + ".DLQ", record.partition())` (파티션 음수면 임의 — `-1` 처리)로 커스터마이즈해 `<topic>.DLQ` 네이밍 적용.
  - `DefaultErrorHandler`: `new DefaultErrorHandler(recorder, new FixedBackOff(intervalMs, maxAttempts))`. `NonRetryableNotificationException`은 `addNotRetryableExceptions(...)`로 즉시 DLQ(섹션 4).
  - `ConcurrentKafkaListenerContainerFactory<String, Object>`: 위 ConsumerFactory + 에러 핸들러 주입. ack-mode RECORD.
- 비고: 모든 매직넘버(backoff interval, max attempts)는 yml 커스텀 프로퍼티(`notification.kafka.retry.*`)에서 주입 — 하드코딩 금지.

### 설정 변경

#### notification/src/main/resources/application.yml (수정)
- 기존 `spring.kafka.consumer` 블록 유지.
- 추가: DLQ produce용 producer 직렬화 설정(필요 시 `spring.kafka.producer.key/value-serializer`), 커스텀 재시도 프로퍼티:
  ```yaml
  notification:
    kafka:
      retry:
        max-attempts: 3      # 최초 1 + 재시도 2 (FixedBackOff maxAttempts 의미에 맞춰 구현에서 환산)
        backoff-ms: 1000
      dlq:
        suffix: ".DLQ"
  ```
- 비고: suffix를 프로퍼티화해 네이밍 규칙을 한 곳에서 관리.

### test

#### dto/EventDeserializationTest (단위)
- `ObjectMapper`(JavaTimeModule 등록)로 event-catalog.md의 JSON 샘플 3종을 각 record로 역직렬화 → 모든 필수 필드 매핑 검증(특히 `eventId` UUID, `occurredAt`/`orderedAt`/`attemptedAt`/`shippedAt` Instant, `items` 중첩, 금액 long). 필수 필드 누락 없이 catalog와 1:1임을 보장.

#### service/EventProcessingServiceTest (단위, Mockito)
- mock `ProcessedEventRepository` + mock `NotificationDispatchService` 주입.
- 케이스:
  - 신규 eventId → `existsByEventId=false` → save 1회 + dispatch 1회.
  - 중복 eventId → `existsByEventId=true` → save/dispatch 0회(중복 처리 안 함).
  - save가 `DataIntegrityViolationException`(경합) → dispatch 0회 + 예외 비전파(중복으로 흡수).
  - dispatch가 `NotificationException`(retryable) → 예외 전파(컨테이너로 위임됨을 입증), retryable 플래그 보존.

#### consumer/NotificationEventConsumerTest (단위, Mockito)
- mock `EventProcessingService` 주입 → 각 리스너 메서드가 `process(event)`를 정확히 1회 위임하는지(Consumer에 비즈니스 로직 없음, Repository 미접근) 검증.

#### consumer/NotificationEventConsumerIntegrationTest (통합, @EmbeddedKafka)
- profile `kafkatest`(섹션 5.3) — Kafka 자동설정 활성, DB는 인메모리 더미(`FakeProcessedEventStore`)로 대체.
- 시나리오:
  - 정상: `order-completed`로 이벤트 produce → 리스너가 소비, dispatch 1회, 멱등 store에 PROCESSED 1건.
  - 중복: 동일 `eventId` 2회 produce → dispatch 정확히 1회(두 번째는 중복 흡수).
  - DLQ: dispatch가 항상 `NotificationException` 던지도록 구성한 테스트 빈 사용 → 재시도 소진 후 `order-completed.DLQ` 토픽에 원본 페이로드 + `kafka_dlt-*` 헤더가 적재됨을 consumer로 polling 검증.

#### support/FakeProcessedEventStore (test 지원)
- 통합 테스트에서 실 DB 없이 멱등 동작을 검증하기 위한 인메모리 `ProcessedEventRepository` 대체(또는 `EventProcessingService`가 의존하는 포트의 테스트 더블). `ConcurrentHashMap<UUID, ...>`로 exists/save 모사 + 유니크 경합 모사 옵션.
- 비고: 통합 테스트의 초점은 Kafka 소비/재시도/DLQ 라우팅이므로 실제 JPA 영속은 단위 테스트(mock)로 분리 검증, 통합은 흐름 검증에 집중(섹션 6).

---

## 3. 데이터 흐름

### 3.1 정상 소비
```
shop-core가 order-completed 토픽에 OrderCompletedEvent(JSON) 발행
  → 컨테이너가 record 수신, JsonDeserializer로 OrderCompletedEvent record 역직렬화
  → NotificationEventConsumer.onOrderCompleted(event)  [로직 없음]
  → EventProcessingService.process(event)  @Transactional 시작
     → existsByEventId(eventId) == false
     → save(ProcessedEvent.processed(eventId, "OrderCompletedEvent"))
     → dispatchService.dispatch(event)  → 로그만 (스텁)
     → 트랜잭션 커밋  → log "[PROCESSED] eventId=..."
  → 리스너 정상 반환 → 컨테이너 offset commit
```

### 3.2 중복 수신
```
동일 eventId 재수신 (재처리/at-least-once 중복)
  → process(event) @Transactional
     → 경로 A: existsByEventId == true → log "[DUPLICATE] skip eventId=..." → return (dispatch 안 함)
     → 경로 B(경합): existsByEventId 통과했으나 save에서 유니크 위반(DataIntegrityViolationException)
                    → "[DUPLICATE] race eventId=..." 로그 → 예외 흡수, dispatch 안 함, 정상 반환
  → offset commit (재시도/DLQ 없음 — 중복은 정상 처리로 간주)
결과: 알림 처리 로직(dispatch)은 eventId당 정확히 1회.
```

### 3.3 실패 → 재시도 → DLQ
```
process(event) 중 dispatchService.dispatch(...)가 NotificationException throw
  → @Transactional 롤백 (ProcessedEvent insert도 롤백 → 멱등 마킹 영속 안 됨)
  → 예외가 리스너 밖으로 전파
  → 컨테이너 DefaultErrorHandler 개입:
       - retryable 분류(섹션 4)면 FixedBackOff(backoff-ms)로 max-attempts까지 재시도
         (재시도마다 동일 record 재소비 → 같은 흐름 반복)
       - 재시도 소진 OR non-retryable이면:
         DeadLetterPublishingRecorder가 원본 record(key/value/partition)를
         "<topic>.DLQ"(예: order-completed.DLQ)로 produce
         + kafka_dlt-exception-* 헤더(예외 클래스/메시지/원본 토픽·오프셋) 부착
  → DLQ 전송 후 원본 record offset commit (다음 record 진행)
  → log "[DLQ] eventId=..., topic=order-completed.DLQ, reason=..."
```
- 멱등 마킹이 롤백되므로, 동일 이벤트가 추후 정상 경로로 재발행/재처리되면 다시 정상 처리 가능(실패가 영구 차단되지 않음).

---

## 4. 예외 처리 전략

### 4.1 NotificationException retryable 분류
- 발송 스텁/Service 경계에서 외부/일시 오류는 `NotificationException(msg, cause, true)`(retryable), payload 검증 실패 등 영구 오류는 `NonRetryableNotificationException`으로 변환한다(규칙: 모든 예외를 RuntimeException 상속 커스텀 예외로 변환).
- `ProcessingError.from(eventType, sourceEventId=eventId, e, occurredAt)`로 구조적 로깅(기존 common 재사용). `sourceEventId`에 이벤트의 `eventId`를 넣어 추적 연계.

### 4.2 DefaultErrorHandler backoff
- `FixedBackOff(backoff-ms, attempts)`로 차단형 재시도. 값은 yml(`notification.kafka.retry.*`)에서 주입.
- non-retryable 즉시 DLQ: 발송 단계에서 영구 오류는 `NonRetryableNotificationException`(마커 하위 예외)로 던지고, `addNotRetryableExceptions(NonRetryableNotificationException.class)`로 재시도 없이 DLQ 처리한다.
- 이 마커 예외는 본 Task에서 추가하는 최소 1개 하위 타입(과한 계층 금지). 위치: `common/exception/NonRetryableNotificationException.java`.
- 비고: 기존 `NotificationException.isRetryable()`(인스턴스 플래그)는 로깅/`ProcessingError` 표현용으로 유지하고, 컨테이너 재시도 분류는 예외 클래스 기반으로 한다(섹션 6 트레이드오프).

### 4.3 non-retryable 즉시 DLQ
- `NonRetryableNotificationException`(또는 역직렬화 실패 등 컨테이너가 회복 불가로 판단하는 예외)은 재시도 없이 즉시 `DeadLetterPublishingRecorder`로 `<topic>.DLQ` 라우팅.
- 역직렬화 실패는 `ErrorHandlingDeserializer`로 감싸 poison message가 무한 재시도 되지 않고 DLQ로 가도록 구성(선택 보강 — 열린 결정 4.5).

### 4.4 멱등 충돌 처리
- `existsByEventId` 사전 체크 + `eventId` 유니크 제약 이중 방어. 경합으로 인한 `DataIntegrityViolationException`은 "중복"으로 흡수(예외 전파/재시도 금지). 이로써 동시 수신에도 dispatch는 1회.

### 4.5 열린 결정 / 가정
- (a) **분류 방식**: 인스턴스 `isRetryable()` vs 클래스 기반 `DefaultErrorHandler` 분류 불일치 → 기본값으로 "non-retryable은 `NonRetryableNotificationException` 마커로 표현 + 클래스 기반 즉시 DLQ"를 채택. 추후 더 세밀한 정책이 필요하면 커스텀 분류 함수로 확장.
- (b) **FAILED 이력 영속**: 최소 구현은 `ProcessingError` 로깅으로 대체(DLQ 전송이 추적을 담당). 필요 시 `REQUIRES_NEW`로 `ProcessedEvent.failed(...)` 저장 보강 — 본 Task에서는 로깅 우선, 영속은 후속 보강 가능으로 둔다.
- (c) **ErrorHandlingDeserializer** 적용 여부: poison message 대비 권장이나, 통합 테스트는 정상 타입 produce 위주이므로 적용은 합리적 기본(적용 권장)으로 두되 구현 재량.
- 어느 경우든 구현이 막히지 않도록 위 기본값을 채택해 진행한다.

---

## 5. 검증 방법

> 실행 위치: 하위 프로젝트 `notification/`. 명령: `./gradlew test`.

### 5.1 단위 테스트 목록
- `EventDeserializationTest`: 3종 JSON 샘플 역직렬화 → catalog 필드 1:1 매핑.
- `EventProcessingServiceTest`: 신규/중복/경합(유니크 위반 흡수)/실패 전파(retryable 보존).
- `NotificationEventConsumerTest`: 3개 리스너가 `process()`로 위임(로직·Repository 미접근).

### 5.2 EmbeddedKafka 통합 테스트 시나리오 (NotificationEventConsumerIntegrationTest)
- 정상: produce → dispatch 1회 + 멱등 store PROCESSED 1건.
- 중복: 동일 eventId 2회 produce → dispatch 정확히 1회.
- DLQ: 항상 실패하는 dispatch 빈 → 재시도 소진 후 `order-completed.DLQ`에 원본 payload + `kafka_dlt-*` 헤더 적재 확인(테스트 consumer로 poll).

### 5.3 자동설정 제외 정책 vs 통합 테스트 충돌 회피
- 현재 `test/resources/application.yml`은 DataSource/Hibernate/DataSourceTx/**Kafka** 자동설정을 모두 제외 → EmbeddedKafka 통합 테스트는 Kafka 자동설정이 필요하므로 그대로는 충돌.
- 회피 전략(채택): 통합 테스트 전용 **별도 profile `kafkatest`** 도입.
  - `notification/src/test/resources/application-kafkatest.yml` 신규: 기본 test의 exclude 중 `KafkaAutoConfiguration` 제외를 무력화(또는 통합 테스트 클래스에서 `@TestPropertySource(properties = "spring.autoconfigure.exclude=")`로 override)하여 Kafka만 활성. DB는 여전히 제외(인메모리 더미로 멱등 대체).
  - 통합 테스트 클래스: `@SpringBootTest`, `@ActiveProfiles({"test","kafkatest"})`, `@EmbeddedKafka(topics = {"order-completed","payment-failed","shipping-started","order-completed.DLQ",...})`, `@Import`로 `FakeProcessedEventStore`/실패 dispatch 빈 주입.
- 단위 테스트(Mockito)는 컨텍스트 미기동이라 제외 정책과 무관.
- 기존 `NotificationApplicationTests.contextLoads()`(profile=test, Kafka 자동설정 제외)는 영향받지 않도록, `KafkaConsumerConfig`/Consumer 빈이 Kafka 자동설정에 강결합돼 풀 컨텍스트 기동을 깨지 않게 한다(KafkaTemplate/ConsumerFactory 빈이 자동설정 제외 시 부재로 기동 실패할 수 있으므로 — 가드 필요. 기본 채택: `contextLoads`가 깨지면 통합 테스트와 동일하게 `kafkatest`에서만 Kafka 빈을 활성화하도록 `@Profile`/조건부 빈으로 분리하거나, 기존 contextLoads test profile에서도 Kafka 빈이 안전하게 생성되도록 ConsumerFactory를 yml 기반으로 lazy 구성). 구현 시 `./gradlew test` 그린이 기준.

### 5.4 Acceptance Criteria 대 검증 매핑
| Acceptance | 검증 |
|---|---|
| 컨텍스트가 Kafka Consumer 설정과 함께 로드 | 통합 테스트 컨텍스트 기동(5.2) + 기존 contextLoads 비파괴(5.3) |
| 세 공개 토픽 구독 Consumer 메서드 존재 | `NotificationEventConsumer` 3개 `@KafkaListener` + ConsumerTest(5.1) |
| Consumer가 Service로 위임 | `NotificationEventConsumerTest`(위임 1회, Repo 미접근) |
| DTO가 catalog 필수 필드 반영 | `EventDeserializationTest`(필드 1:1, 5.1) |
| 멱등 Entity + eventId 유니크 제약 | `ProcessedEvent` `@UniqueConstraint(event_id)` + 단위/통합 |
| 동일 eventId 2회 → 처리 1회 | `EventProcessingServiceTest`(중복/경합) + 통합 중복 시나리오 |
| 정상 처리 시 성공 상태 저장 | 신규 케이스 save(PROCESSED) 검증(5.1) |
| 실패 시 재시도 설정 적용 | `DefaultErrorHandler`+FixedBackOff + 통합 DLQ 시나리오(재시도 후 DLQ) |
| 재시도 소진 후 DLQ 라우팅 | 통합 DLQ 시나리오: `<topic>.DLQ` 적재 + 헤더(5.2) |
| 레이어 규칙 위반 없음 | Consumer→Service→Repository, Repo는 Service만 호출(ConsumerTest/구조) |
| 관련 테스트 통과 | `./gradlew test` 전체 green |

---

## 6. 트레이드오프

- **멱등 체크 위치: 발송 전 vs 발송 후**
  - 채택: 발송 전 + 같은 트랜잭션 마킹. (장) 중복 발송 원천 차단, effectively-once. (단) 발송이 비동기·장시간이면 트랜잭션 보유가 길어짐 — 본 Task 발송은 동기 로그 스텁이라 무해.
  - 미채택: 발송 후 마킹 → 중복 발송 가능, 알림 도메인에 부적합.

- **멱등 마킹: 성공 후 영속(claim-then-send) vs 시작 시 영속(processing 상태)**
  - 채택: 성공 트랜잭션 커밋 시 영속(실패 시 롤백). (장) 실패가 영구 차단되지 않음(재처리 가능), 구현 단순. (단) 발송 직후~커밋 사이 크래시 시 재처리(드문 중복) 가능 — at-least-once 전제상 허용.
  - 미채택: 시작 시 `PROCESSING` insert → 상태 기계/재시도 시 상태 전이 관리 복잡(YAGNI).

- **DLQ 구현: DeadLetterPublishingRecorder vs 수동 produce**
  - 채택: `DefaultErrorHandler` + `DeadLetterPublishingRecorder`. (장) 재시도·헤더 보존·offset 관리 표준화, 추적 헤더 자동. (단) 토픽 네이밍 커스터마이즈(`.DLQ`) 코드 1곳 필요.
  - 미채택: 리스너 try/catch 후 `KafkaTemplate`로 수동 produce → 재시도/백오프/헤더/offset을 직접 관리, 실수 여지 큼.

- **재시도 정책 위치: 컨테이너 단위 vs 메서드 단위**
  - 채택: 컨테이너 단위(`DefaultErrorHandler`). (장) 3개 리스너 일관 정책, 한 곳 관리. (단) 리스너별 차등 정책은 추가 팩토리 필요(현재 불필요).
  - 미채택: 메서드 단위(`@RetryableTopic`) → 토픽 증식·비차단 복잡도(YAGNI, 후속).

- **재시도 방식: 차단형(FixedBackOff) vs 비차단형(retry-topic)**
  - 채택: 차단형. (장) 골격 검증에 단순·충분. (단) 긴 backoff 시 파티션 처리 지연 — 본 Task 무해.
  - 미채택: 비차단 retry-topic 체이닝 → 후속에 명시만.

- **Consumer 구성: 단일 클래스 3메서드 vs 토픽별 클래스 분리**
  - 채택: 단일 `NotificationEventConsumer` 3메서드. (장) 골격 단계 응집·간결, 위임 패턴 동일. (단) 이벤트별 처리 분기가 커지면 분리 필요 — 현재는 모두 `process()` 위임이라 단일이 적합.

- **통합 테스트 멱등 저장: 실 DB(@DataJpaTest/H2) vs 인메모리 더미**
  - 채택: 인메모리 더미(`FakeProcessedEventStore`) + 멱등 JPA는 단위(mock)로 분리. (장) notification의 "H2 미도입·DB 자동설정 제외" 방침 유지, 통합 테스트는 Kafka 흐름에 집중. (단) 실제 유니크 제약의 DB 레벨 동작은 통합에서 직접 검증 못 함 → 단위에서 `DataIntegrityViolationException` 흡수로 커버.
  - 미채택: 통합에 H2 도입 → 방침 위배·범위 확대.

- **non-retryable 표현: 인스턴스 boolean vs 마커 하위 예외**
  - 채택: 마커 `NonRetryableNotificationException`(최소 1개 하위 타입) + 클래스 기반 즉시 DLQ. (장) `DefaultErrorHandler` 분류와 자연스럽게 맞물림. (단) 기존 `isRetryable()` 플래그와 표현 이중화 — 로깅/`ProcessingError`는 플래그, 컨테이너 분류는 클래스 사용으로 역할 구분.
  - 미채택: 컨테이너에 인스턴스 단위 커스텀 분류 함수만 → 가능하나 표준 패턴에서 벗어나 가독성 저하.

---

## Spring Boot 컨벤션
- 패키지: `com.shop.notification.{consumer|service|repository|domain|dto}` + 횡단 설정/예외는 `common.{config|exception|error|domain}`(기존 구조 준수, package-structure-rule.md).
- 어노테이션: `@KafkaListener`, `@Component`, `@Service`, `@Transactional`(+`REQUIRES_NEW` 보조), `@Entity`/`@Table`/`@UniqueConstraint`/`@Id`/`@GeneratedValue`/`@Enumerated(STRING)`, `@Configuration`, Lombok `@Getter`/`@NoArgsConstructor`/`@RequiredArgsConstructor`/`@Slf4j`. DTO는 Java `record`.
- 예외: 모든 외부/일시 오류를 `NotificationException`(retryable) 또는 `NonRetryableNotificationException`으로 변환(RuntimeException 상속). `ProcessingError`(기존 record)로 구조적 로깅. **HttpStatus·ErrorResponse·RestControllerAdvice 없음**(REST 부재).
- Entity 미노출: `ProcessedEvent`는 Service 내부 전용, Consumer/외부로 반환 금지. DTO/Entity 분리.
- 기존 common 재사용: `NotificationException`/`ProcessingError`/`BaseEntity`/`JpaAuditingConfig` 중복 생성 금지(그대로 활용).
- 화면(view) 작업 없음: notification은 Thymeleaf/뷰 없음 → view-implementor 분담 없음.
- 가정: 스키마는 현 `ddl-auto=create`(개발)로 생성, Flyway는 본 Task 범위 아님.

## 완료 조건
- [ ] 이벤트 DTO 3종(`OrderCompletedEvent`/`PaymentFailedEvent`/`ShippingStartedEvent`) + `OrderItem` + `EventEnvelope` 생성, catalog 필수 필드 1:1 반영
- [ ] `NotificationEventConsumer` 3개 `@KafkaListener`(order-completed/payment-failed/shipping-started, group-id=notification), Service로만 위임(Repository 미접근)
- [ ] `KafkaConsumerConfig`: ConsumerFactory + ListenerContainerFactory + `DefaultErrorHandler`(FixedBackOff) + `DeadLetterPublishingRecorder`(`<topic>.DLQ` 라우팅) + KafkaTemplate
- [ ] `ProcessedEvent`(BaseEntity 상속, `event_id` 유니크) + `ProcessingStatus` + `ProcessedEventRepository(existsByEventId)`
- [ ] `EventProcessingService`(@Transactional: 멱등 체크→발송→PROCESSED 저장, 유니크 경합 흡수, 실패 전파)
- [ ] `NotificationDispatchService`(인터페이스) + `LoggingNotificationDispatchService`(스텁, 실제 발송 없음)
- [ ] `NonRetryableNotificationException`(마커, 즉시 DLQ 분류용) 추가
- [ ] application.yml에 재시도/backoff/DLQ suffix 커스텀 프로퍼티 추가(하드코딩 금지), 기존 consumer 블록 유지
- [ ] 성공/중복/실패/DLQ 로그 출력(`[PROCESSED]`/`[DUPLICATE]`/`[DLQ]`)
- [ ] 단위 테스트: DTO 역직렬화 / 멱등 Service(신규·중복·경합·실패) / Consumer 위임
- [ ] 통합 테스트(@EmbeddedKafka, `kafkatest` profile): 정상·중복·DLQ 라우팅(`order-completed.DLQ` + `kafka_dlt-*` 헤더)
- [ ] 기존 `NotificationApplicationTests.contextLoads()`(test profile) 비파괴
- [ ] REST Controller/ServiceResponse/ErrorResponse/RestControllerAdvice 산출물 0개, shop-core 코드/DB/REST 참조 0개, Consumer의 Repository 직접 호출 0개, Entity 외부 노출 0개, 이벤트 계약 변경 0건
- [ ] `./gradlew test` 전체 통과

## 에이전트 분담
- 본 Task는 전부 **backend-implementor** 단독 수행. notification에 view가 없으므로 view-implementor 분담 없음.
- 후속 Task와의 인터페이스 계약(미리 안정화): `EventEnvelope(eventId, occurredAt)`, `NotificationDispatchService.dispatch(EventEnvelope)`, `EventProcessingService.process(EventEnvelope)`, `ProcessedEventRepository.existsByEventId(UUID)`, DLQ 네이밍 규칙 `<topic>.DLQ`.

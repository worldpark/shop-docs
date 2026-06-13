# 024-1 shop-core Modulith Kafka 외부화 직렬화 수정 plan

> Spring Modulith Kafka 외부화가 `ByteArrayJsonMessageConverter`로 만든 `byte[]`를 자동설정 producer의 `JsonSerializer`가 **다시 base64 문자열로 직렬화**(이중 직렬화)해 전 토픽이 notification DLQ로 직행하는 버그를, **producer `value-serializer`를 `ByteArraySerializer`로 교정**해 wire를 plain JSON으로 복구한다. 이벤트 계약·페이로드·토픽·Outbox 골격·notification은 전부 불변, **wire 인코딩만** 교정하고 EmbeddedKafka 회귀 테스트로 고정한다.

---

## 1. 설계 방식 및 이유

### 근본 원인 재확인(코드 교차 검증 완료)
- shop-core 메인 코드 전체에서 `KafkaTemplate` / `KafkaOperations` / `.send(` 사용처가 **0건**. 외부로 나가는 모든 이벤트는 `@Externalized` 5종(`order-completed`/`payment-failed`/`order-cancelled`/`shipping-started` + 스모크 전용 `shop-core-smoke-test`) 뿐이며, 전부 Spring Modulith Event Publication Registry(Outbox) → externalization auto-config 경로로 발행된다.
- shop-core에는 커스텀 `KafkaTemplate`/`ProducerFactory`/직렬화 빈이 없다. 외부화는 자동설정 producer(`spring.kafka.producer.*`)를 그대로 사용한다.
- `spring-modulith-events-kafka:1.3.1`의 `KafkaJacksonConfiguration`은 외부화 메시지를 `ByteArrayJsonMessageConverter`로 변환 → 페이로드가 이미 **JSON 바이트(`byte[]`)** 로 KafkaTemplate에 전달된다.
- 그런데 `application.yml`의 `value-serializer: org.springframework.kafka.support.serializer.JsonSerializer`가 그 `byte[]`를 **한 번 더 JSON 직렬화 → base64 문자열(`"<base64>"`)**. 결과 wire = `"eyJ..."`(이중 직렬화). notification은 `StringDeserializer + Jackson MessageConverter`로 `{...}`를 기대하므로 `ConversionException` → 전 이벤트 DLQ.

### 결정: 전역 자동설정 producer `value-serializer`를 `ByteArraySerializer`로 변경
- 근거 1 (YAGNI/최소 변경): shop-core에 `@Externalized` 외 **직접 발행 경로가 부재**함을 코드로 확인했다. 따라서 전역 producer를 `ByteArraySerializer`로 바꿔도 영향받는 발행 경로는 외부화 경로 단 하나뿐이고, 그 경로가 바로 `byte[]`를 보내므로 전역 변경이 **최소·충분**하다.
- 근거 2 (대안 기각): "외부화 전용 `KafkaTemplate`/`ProducerFactory` 빈 분리"는 *서로 다른 직렬화를 요구하는 발행 경로가 둘 이상 공존할 때* 정당화된다. 현재 그런 경로가 없으므로 전용 빈은 불필요한 빈/추상화 추가(과도한 설계)이며 forbidden-rule·YAGNI에 반한다. 추후 객체를 직접 보내는 producer가 생기면 그때 분리한다.
- 근거 3 (대칭성): 같은 부류(이중 인코딩) 버그를 notification 발행 경계(`.DLQ` producer)에서 024가 `JsonSerializer→StringSerializer`로 이미 교정했다. shop-core는 `ByteArrayJsonMessageConverter`가 이미 `byte[]`를 만들므로 대칭 교정값이 `StringSerializer`가 아니라 **`ByteArraySerializer`** 다(byte[]는 추가 인코딩 없이 그대로 전송해야 함).

### key-serializer는 `StringSerializer` 유지
- 외부화 라우팅 키는 Modulith가 문자열로 산정하며 notification 컨슈머/파티셔닝이 String 키를 전제한다. value 이중 직렬화와 무관한 정상 경로이므로 변경하지 않는다. (이번 버그는 value 경로 한정.)

---

## 2. 구성 요소

### 수정 파일
- **`shop-core/src/main/resources/application.yml`** (1줄 변경 + 주석 정정)
  - `spring.kafka.producer.value-serializer`: `org.springframework.kafka.support.serializer.JsonSerializer` → **`org.apache.kafka.common.serialization.ByteArraySerializer`**
  - `key-serializer`: `org.apache.kafka.common.serialization.StringSerializer` **유지**
  - 45번 라인 오기 주석(`StringSerializer(key) + JsonSerializer(value) — Modulith 외부화 어댑터와 호환`)을 사실로 정정: Modulith `ByteArrayJsonMessageConverter`가 JSON `byte[]`를 만들므로 value는 `ByteArraySerializer`여야 wire가 plain JSON이 된다는 취지로 교체.

### 신규 파일 (회귀 테스트 1종)
- **`shop-core/src/test/java/com/shop/shop/platform/event/OutboxKafkaWireFormatTest.java`** (정확한 패키지/클래스명은 implementor 재량 가능, platform 모듈 권장 — `DummyOutboxSmokeEvent`와 동일 위치)
  - 책임: `@Externalized` 이벤트를 **실제 외부화 경로**로 발행시킨 뒤 EmbeddedKafka 토픽에서 raw `StringDeserializer` 컨슈머로 wire 값을 수신해 **plain JSON 오브젝트**임을 단언. 현 `JsonSerializer` 설정에서 실패하고 `ByteArraySerializer`에서 통과하도록 설계.
  - 발행 이벤트는 **계약 4종 중 대표 + 스모크 전용** 중에서 택한다. 권장: notification 미구독 토픽인 **`DummyOutboxSmokeEvent`(`shop-core-smoke-test`)** 를 1차 대상으로 사용(테스트 토픽 오염·계약 토픽 점유 회피). 공유 producer 설정이므로 1종으로 4개 계약 토픽 전체가 동일하게 교정됨이 보장된다(AC의 "대표 1~2종 + 공유설정 근거"). 추가 신뢰가 필요하면 계약 이벤트 1종(`OrderCancelledEvent`)을 한 케이스 더 둔다.
  - 과도한 빈/추상화 금지: 신규 프로덕션 빈·설정 클래스 없음. 테스트 안에서만 EmbeddedKafka + raw 컨슈머 구성.

### 변경 없음 (명시)
- `@Externalized` 이벤트 레코드 5종, `docs/event-catalog.md`, `docs/architecture.md` §5(토픽 표), Outbox/Registry, `event_publication`(V1) 스키마, notification 전부.
- 기본 테스트 `src/test/resources/application.yml`(전역 Kafka/JPA-events autoconfig 제외)은 **변경하지 않는다.** 새 wire 테스트만 자기 클래스 안에서 그 제외를 국소적으로 되살린다(§5).

---

## 3. 데이터 흐름

### 공통 발행 파이프라인 (변경 없음)
```
도메인 트랜잭션 안에서 ApplicationEventPublisher.publishEvent(@Externalized 이벤트)
  → Modulith Event Publication Registry: event_publication INCOMPLETE 저장 (Outbox, JPA)
  → 트랜잭션 커밋
  → externalization auto-config: ByteArrayJsonMessageConverter 가 이벤트를 JSON byte[] 로 변환
  → 자동설정 KafkaTemplate.send(topic, key=String, value=byte[])
  → producer value-serializer 적용
  → wire
```

### 수정 전 (버그 — 이중 인코딩)
```
value = byte[]("{\"eventId\":...,\"items\":[...]}")   ← 이미 JSON 바이트
  → JsonSerializer.serialize(byte[])  → byte[]를 JSON 값으로 다시 직렬화 → base64 문자열
  → wire: "eyJldmVudElkIjoi...=="     (선두 바이트 22 65 79 4a = `"eyJ`)
  → notification: StringDeserializer → "eyJ...=="(문자열) → Jackson readValue → ConversionException
  → 재시도 없이 <topic>.DLQ 라우팅  (전 토픽 동일)
```

### 수정 후 (plain JSON)
```
value = byte[]("{\"eventId\":...,\"items\":[...]}")
  → ByteArraySerializer.serialize(byte[]) → 바이트 그대로 전송 (추가 인코딩 없음)
  → wire: {"eventId":"...","occurredAt":"...","items":[{"productId":...}], ...}   (선두 바이트 7B = `{`)
  → notification: StringDeserializer → "{...}" → Jackson readValue(EventDto) 성공 → 정상 처리(PENDING→SENT)
```

- 페이로드 **내용은 수정 전/후 완전 동일**(base64를 풀면 동일 JSON). 바뀌는 것은 **wire 바이트 래핑뿐**이다 → 계약 불변.
- 4개 계약 토픽(`order-completed`/`payment-failed`/`order-cancelled`/`shipping-started`)은 **동일한 자동설정 producer**를 공유하므로 한 번의 serializer 교정으로 전부 plain JSON 발행된다.

---

## 4. 예외 처리 전략

- 본 변경은 직렬화 **설정** 교정이라 새 런타임 예외 경로를 추가하지 않는다. 도메인 로직·트랜잭션·롤백 동작은 불변.
- **`ByteArraySerializer`가 깨지는 유일 조건** = "외부화 경로 외에서 `byte[]`가 아닌 객체를 자동설정 producer로 직접 보내는 경우". 코드 전수 확인 결과 그런 경로가 **부재**(`KafkaTemplate`/`.send` 0건, 전부 `@Externalized`). 따라서 회귀 위험 없음. 이 부재 사실은 plan-reviewer/구현 단계에서 재확인 대상으로 명시한다(새 직접 발행 코드가 추가되면 이 가정이 깨지므로).
- **외부화 실패 시 회복 동작 불변**: 직렬화/전송 실패 시 해당 `event_publication` 레코드는 INCOMPLETE로 남아 Modulith 재시도·추적이 그대로 동작한다(Outbox 골격 보존). 이번 변경은 오히려 그간 성공처럼 보였으나 wire가 깨져 컨슈머가 DLQ로 보내던 상황을 정상화한다(발행측은 성공으로 커밋되었으므로 shop-core 재시도 트리거는 아니었음 — 컨슈머측 DLQ 문제였음을 명확히 함).
- notification 측 DLQ/재시도는 024 범위로 불변. 본 수정이 정상 wire를 공급하면 더 이상 ConversionException으로 DLQ에 빠지지 않는다.

---

## 5. 검증 방법

### 핵심 회귀 테스트: EmbeddedKafka wire 포맷 단언 (필수)
설계 의도 — **이전 `JsonSerializer` 설정에서 반드시 실패**, `ByteArraySerializer`에서 통과해야 회귀로서 의미가 있다(testing-rule §회귀).

구성:
- `@SpringBootTest` + **`@EmbeddedKafka(topics = "shop-core-smoke-test")`**(`spring-kafka-test` 기존 의존; 대상 토픽을 **명시 사전생성**해 auto-create 타이밍에 의한 0건 수신 flaky 예방) + **Testcontainers PostgreSQL**(`@ServiceConnection`) — Outbox(`event_publication`)는 JPA-backed이므로 실 DataSource가 필요(기존 `*OutboxIntegrationTest` + 빈값 `spring.autoconfigure.exclude=` 리셋 선례 `CartServiceIntegrationTest` 패턴 재사용).
- **기본 test yml의 전역 제외를 국소 해제**: 기본 `src/test/resources/application.yml`은 `KafkaAutoConfiguration`·`JpaEventPublicationAutoConfiguration`을 제외하고 externalization을 끈다. 이 테스트는 실제 외부화 경로를 타야 하므로 클래스 `@TestPropertySource`로:
  - `spring.autoconfigure.exclude=`(빈 값으로 리셋 — testing-rule §슬라이스·프로파일의 "리셋 시 의도치 않게 살아나는 자동설정 점검" 준수: DataSource는 Testcontainers로 제공, Flyway는 `spring.flyway.enabled=true`로 마이그레이션 적용),
  - `spring.modulith.events.externalization.enabled=true`,
  - `spring.kafka.bootstrap-servers=${spring.embedded.kafka.brokers}`,
  - (producer serializer는 메인 `application.yml` 값을 그대로 사용 — 이게 SUT다. 테스트에서 serializer를 재정의하지 않는다.)
- 흐름:
  1. raw 컨슈머를 EmbeddedKafka에 등록(`key=StringDeserializer`, `value=StringDeserializer`) — Modulith/Jackson 변환을 우회해 **원시 wire 문자열**을 본다.
  2. `@Transactional` 경계에서 대상 `@Externalized` 이벤트(권장 `DummyOutboxSmokeEvent`)를 publish → 커밋 → 외부화.
  3. **`KafkaTestUtils.getRecords(consumer, Duration)`** 폴링으로 토픽(`shop-core-smoke-test`)에서 1건 수신. **Awaitility 신규 의존을 추가하지 않는다**(레포에 awaitility 직접 의존 없음 — `spring-kafka-test`의 `KafkaTestUtils`로 충분).
- 단언:
  - (a) wire 값 첫 비공백 문자가 `'{'`(plain JSON 오브젝트). **`'"'`(이중따옴표 래핑) 아님**, base64 패턴(`^[A-Za-z0-9+/]+=*$`) 아님 — 이중 직렬화 회귀를 직접 차단.
  - (b) `objectMapper.readValue(value, DummyOutboxSmokeEvent.class)`(또는 대상 타입) **성공**.
  - (c) 핵심 필드 일치: `eventId`(왕복 동일), `occurredAt` 비null 등.
- **이전 설정 실패 보장 방법**: serializer를 `JsonSerializer`로 두면 wire가 `"eyJ..."`가 되어 (a)에서 첫 문자가 `'"'` → 즉시 실패한다. 즉 단언 (a)가 회귀 가드다. (검증 절차에서 implementor는 일시적으로 value-serializer를 `JsonSerializer`로 토글해 RED → 원복해 GREEN을 1회 확인하고, 그 토글 흔적은 커밋하지 않는다. 영구 토글 플래그/주석은 추가하지 않음 — 과도한 설계 금지.) **작업 보고에 토글 RED 시점의 단언 (a) 실패 메시지 1줄을 인용**해 회귀 가드의 실효성을 문서로 남긴다(증적 비영속 보완).

### 회귀(기존 그린 유지)
- 기존 `*OutboxIntegrationTest`(Order/Payment/Shipping/Expiry, externalization=false로 페이로드 캡처) 그대로 그린 — 본 변경은 serializer만 건드리므로 영향 없음.
- `ModularityTests`(모듈 경계), `event_publication` 관련 동작 회귀 없음.
- 다른 producer 직접 발행 경로 부재를 구현 단계에서 1회 더 grep 재확인(가정 고정).

### 실행 게이트
- shop-core에서 `./gradlew test` 전체 그린(verification-gate-rule §검증 실행). EmbeddedKafka·Testcontainers 기반이라 외부 브로커 비의존 — 일반 `test`의 인프라 비의존 원칙 보존(Testcontainers는 docker 필요, 기존 통합 테스트와 동일 전제).

### (선택/수동) 실구동 연계 재스모크 — 보고 항목
- docker 인프라 + shop-core/notification 기동 → 실제 도메인 이벤트(예: 미결제 만료로 `OrderCancelledEvent`) 발행 → notification `processed_event`가 `PENDING→SENT`, `[EMAIL_DISPATCHED]` 로그, 해당 `.DLQ` 무증가 확인(024 스모크 절차 재사용). 수동 확인/미확인 여부를 작업 보고에 남긴다.

---

## 6. 트레이드오프

- **전역 serializer 변경의 파급**: 자동설정 producer는 현재 외부화 경로만 사용하므로 파급 무해. 단, 앞으로 누군가 자동설정 `KafkaTemplate`으로 **객체를 직접** 보내면 `ByteArraySerializer`가 `ClassCastException` 류로 깨진다. 이 경우의 정당한 대응은 그 시점에 **외부화 전용 producer 빈 분리**다(지금 미리 만들지 않음 — YAGNI). 본 plan은 "직접 발행 경로 부재"를 검증·문서화해 이 가정을 명시한다.
- **`ByteArrayJsonMessageConverter` 의존**: fix의 정합성은 Modulith 외부화가 `byte[]`를 만든다는 1.3.1 동작에 의존한다. Modulith 버전 업 시 컨버터가 바뀌면(예: 다시 객체 전달) serializer 가정을 재확인해야 한다. EmbeddedKafka wire 테스트가 이 회귀를 자동으로 잡는다(버전 업 후에도 wire가 `{`로 시작하는지 검증).
- **대안(전용 KafkaTemplate/ProducerFactory) 대비 단순성**: 전용 빈 분리는 미래 확장에 유연하나 지금은 빈/설정 1~2개 추가 + 외부화 어댑터에 그 빈을 연결하는 배선 비용이 든다. 발행 경로가 하나뿐인 현 상태에선 application.yml 1줄 + 회귀 테스트가 동일 효과를 최소 비용으로 달성한다. 단순성을 택하고, 분리는 두 번째 직렬화 요구가 실재할 때로 미룬다.
- **테스트 비용**: 새 wire 테스트는 EmbeddedKafka + Testcontainers라 다소 무겁다(컨텍스트 1개 추가). 그러나 이 버그(전 토픽 DLQ 직행)는 페이로드 캡처형 기존 테스트가 **구조적으로 놓친** wire 계층 결함이므로, 실제 wire를 보는 테스트가 유일한 회귀 안전망이다. 비용 대비 정당.

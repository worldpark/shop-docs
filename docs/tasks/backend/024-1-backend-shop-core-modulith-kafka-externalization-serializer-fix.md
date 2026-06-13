# 024-1. shop-core Modulith Kafka 외부화 직렬화 수정 (이중 직렬화/base64 래핑 → plain JSON)

> 출처: **Task 024 라이브 연계 스모크(2026-06-13)** 에서 발견. shop-core가 발행한 도메인 이벤트가 wire에 **base64로 감싼 JSON 문자열**(`"<base64>"`)로 실려, notification이 역직렬화에 실패하고 **모든 실 이벤트가 DLQ로 직행**한다. 4개 토픽 전부 영향. notification(024) 자체는 정상 — 본 Task는 **shop-core 발행측 직렬화 버그**를 고친다.

## Target
shop-core

---

## Goal
shop-core의 Spring Modulith Kafka 외부화가 도메인 이벤트를 **plain JSON**(`{...}`)으로 발행하도록 직렬화 설정을 바로잡아, notification(및 임의의 컨슈머)이 `event-catalog.md` 계약대로 역직렬화할 수 있게 한다. shop-core↔notification 단방향 이벤트 통합을 실제로 복구한다.
- 페이로드 **필드/계약은 변경하지 않는다**(`event-catalog.md`/`architecture.md` §5 불변). **wire 인코딩만** 교정한다.

## Context
- **발견 경위**: Task 024 검증을 위한 shop-core↔notification 실구동 연계 스모크 중, shop-core가 만료 스케줄러로 발행한 `OrderCancelledEvent`를 notification이 소비하다 `org.springframework.kafka.support.converter.ConversionException: Failed to convert from JSON`으로 실패 → 재시도 없이 `order-cancelled.DLQ`로 라우팅됨(DLQ 헤더 `kafka_dlt-exception-cause-fqcn`로 확인).
- **증상(증거)**: `order-cancelled` 토픽의 실제 wire 값이 `"eyJldmVudElkIjoi...=="`(hex 선두 `22 65 79 4a` = `"eyJ`). base64를 풀면 `{"eventId":...,"items":[{"productId":...}],"refunded":false,...}` — **`event-catalog`·notification DTO와 1:1 일치하는 정상 JSON**이다. 즉 **내용은 정확하고 wire 래핑만 잘못**됐다.
- **근본 원인(라이브러리 확정)**: `spring-modulith-events-kafka:1.3.1`의 `KafkaJacksonConfiguration`이 외부화에 **`ByteArrayJsonMessageConverter`** 를 사용한다 → 이벤트를 **`byte[]`(JSON 바이트)** 로 변환해 KafkaTemplate에 넘긴다. 그런데 shop-core는 **커스텀 KafkaTemplate/직렬화 빈이 없고**, 자동설정 producer의 `spring.kafka.producer.value-serializer: org.springframework.kafka.support.serializer.JsonSerializer`를 그대로 쓴다 → `JsonSerializer`가 그 `byte[]`를 **다시 JSON 직렬화(=base64 문자열로 인코딩)** 한다. 결과: `byte[]({"...JSON..."})` → `"<base64>"` **이중 직렬화**.
  - `application.yml`의 주석 "`StringSerializer(key) + JsonSerializer(value)` — Modulith 외부화 어댑터와 호환"은 **오기**다. ByteArrayJsonMessageConverter 경로에는 value 직렬화가 `ByteArraySerializer`여야 한다(JsonSerializer 아님).
- **영향 범위**: 외부화 경로(자동설정 producer)는 4개 토픽(`order-completed`/`payment-failed`/`order-cancelled`/`shipping-started`) 모두 공유 → **전 토픽 동일 증상**. 실 shop-core 이벤트가 notification에서 정상 처리된 적이 없을 가능성이 높다(연계 스모크의 `SENT` 행은 모두 합성 주입 이벤트였음).
- **연관**: 같은 부류(이중 인코딩) 버그를 notification 발행 경계(`.DLQ` producer)에서는 024가 이미 `JsonSerializer→StringSerializer`로 교정했다. 본 Task는 **대칭 위치(shop-core 발행 경계)** 를 교정한다.

## Authorization / 공개 표면
> 신규 REST/View 없음(Kafka 발행 설정 변경). api-authorization-rule 해당 없음.
- 외부로 나가는 표면 변화 없음(토픽·페이로드 동일). **wire 바이트 인코딩만** plain JSON으로 바뀐다.

## Requirements
- **producer value 직렬화 교정**: shop-core `application.yml`의 `spring.kafka.producer.value-serializer`를 `JsonSerializer` → **`org.apache.kafka.common.serialization.ByteArraySerializer`** 로 변경(Modulith `ByteArrayJsonMessageConverter`가 만든 `byte[]`를 그대로 전송). `key-serializer`(`StringSerializer`)는 **유지**. 오기 주석을 정정한다.
  - (대안 검토는 plan에서) 자동설정 producer 전역 변경 대신 **외부화 전용 KafkaTemplate/ProducerFactory 빈**을 분리할지 여부 — shop-core가 직접 `KafkaTemplate.send`로 발행하는 다른 경로가 없으면(현재 없음 — 전부 `@Externalized`) **전역 `ByteArraySerializer` 변경이 최소·충분**(YAGNI). plan이 "다른 producer 경로 부재"를 코드로 확인 후 택1.
- **wire 포맷 회귀 테스트(필수)**: `@Externalized` 이벤트를 발행했을 때 Kafka wire 값이 **plain JSON 오브젝트**(`{`로 시작, base64/이중따옴표 래핑 아님)이며 **원본 이벤트로 역직렬화 가능**함을 단언하는 테스트를 추가한다. 이 테스트는 **현 `JsonSerializer` 설정에서 반드시 실패**하고 `ByteArraySerializer`에서 통과해야 의미가 있다(testing-rule §회귀).
- **계약 불변**: `event-catalog.md`·`architecture.md` §5·이벤트 필드/토픽명 변경 없음. notification 무변경(024가 이미 정상).

## Constraints
- **이벤트 계약 무변경**: 페이로드 필드·토픽·`event-catalog.md`/§5 불변. wire **인코딩만** 교정.
- **Modulith 아웃박스/레지스트리 골격 보존**: Event Publication Registry(Outbox)·`@Externalized` 라우팅·`event_publication` 스키마(V1)·externalization auto-config 동작을 재설계하지 않는다. 변경은 **producer value-serializer(+주석)** 와 **테스트**에 한정.
- **key 직렬화 유지**: `key-serializer`는 `StringSerializer` 그대로(외부화 키 호환).
- **다른 producer 경로 회귀 금지**: shop-core가 `@Externalized` 외에 직접 Kafka 발행하는 경로가 있으면 그 경로의 직렬화 정합을 함께 확인(현재 없음으로 파악 — plan 확인).
- **범위 밖**: notification 측 변경(024 완료), 신규 토픽/이벤트/필드, dedup/회복탄력성, consumer 역직렬화 방식 변경. event-catalog 예시 JSON 갱신(내용 동일하므로 불필요).
- **테스트 오염 금지**: EmbeddedKafka 기반 테스트로 한정, 외부 브로커 비의존. 풀컨텍스트 `test` 그린 유지.

## Files
> 정확한 경로/배선은 plan 확정. shop-core 단일 레포.
- (수정) `shop-core/src/main/resources/application.yml` — `spring.kafka.producer.value-serializer: ByteArraySerializer`, 오기 주석 정정.
- (신규/수정) 외부화 wire 포맷 테스트 — EmbeddedKafka로 `@Externalized` 이벤트 발행 → raw 컨슈머(StringDeserializer)로 값 수신 → plain JSON 오브젝트 + 이벤트 역직렬화 단언(현 설정 실패·수정 후 통과). (기존 outbox/externalization 테스트가 있으면 확장 — 예: `DummyOutboxSmokeEvent`/`shop-core-smoke-test` 경로.)
- (변경 없음) `@Externalized` 이벤트 레코드들, `event-catalog.md`/`architecture.md` §5, Outbox/Registry, notification 전부.

## Acceptance Criteria
- 외부화된 이벤트의 Kafka wire 값이 **plain JSON 오브젝트**(`{...}`)이고, raw 컨슈머가 이를 원본 이벤트(및 notification DTO)로 **역직렬화 성공**한다(base64/이중따옴표 래핑 제거).
- 4개 토픽(`order-completed`/`payment-failed`/`order-cancelled`/`shipping-started`) 모두 동일하게 plain JSON 발행(공유 producer 설정이므로 대표 1~2종 + 공유설정 근거로 충분).
- 회귀 테스트가 **이전 `JsonSerializer` 설정에서 실패**하고 수정 후 통과한다.
- `event-catalog.md`/`architecture.md` §5·페이로드 필드·토픽명 무변경. Modulith Outbox/Registry 회귀 없음. notification 미변경.
- 풀컨텍스트 `test` 그린.
- (선택/수동) shop-core↔notification 실구동 연계 재스모크: 실제 발행 이벤트가 notification에서 `PENDING→SENT`로 처리됨(024 스모크 절차 재사용) — e2e-runner/수동 검증 항목으로 보고.

## Test
- **통합(EmbeddedKafka, shop-core)**: `@Externalized` 이벤트를 트랜잭션 안에서 publish → Outbox 외부화 → EmbeddedKafka 토픽에서 **raw `StringDeserializer` 컨슈머**로 값 수신 → (a) 값이 `{`로 시작하는 JSON 오브젝트(첫 char `"`/base64 아님), (b) `objectMapper.readValue(value, EventType)` 성공, (c) 핵심 필드(eventId 등) 일치 단언. **이전 `JsonSerializer` 설정에서 실패함**을 회귀로 확보.
- **회귀**: 기존 Outbox/externalization·모듈 구조·`event_publication` 관련 테스트 그린. 다른 producer 경로 부재 확인.
- **(선택) 연계 재스모크**: docker 인프라 + shop-core/notification 기동 → 이벤트 발행 → notification `processed_event` `SENT` + `[EMAIL_DISPATCHED]` 로그(024 스모크 재사용). 수동/보고 항목.

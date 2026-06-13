# shop-core 외부화 직렬화 버그 + 서비스 간 종단 스모크 규칙 (Revision 1)

- 대상: shop-core Modulith Kafka 이벤트 외부화 직렬화, 서비스 간 이벤트 통합 검증 방식
- 관련 Task: `docs/tasks/backend/024-backend-notification-post-commit-dispatch-and-send-history.md`(이 Task의 라이브 검증 중 발견), `docs/tasks/backend/024-1-backend-shop-core-modulith-kafka-externalization-serializer-fix.md`(본 버그 수정 — 신규)
- 관련 규칙: `docs/rules/testing-rule.md`(§"서비스 간 이벤트 종단(end-to-end) 스모크 — 필수" 신설)
- 발견/결정 일자: 2026-06-13
- 결정자: 사용자
- 목적: 024 검증을 위한 shop-core↔notification 실구동 연계 스모크에서 드러난 **발행측 직렬화 이중 인코딩 버그**와, 그것을 **단위/슬라이스/합성 통합 테스트가 구조적으로 놓친 이유**, 그에 따른 **종단 스모크 규칙 신설**을 기록한다.

---

## 1. 발견 경위

Task 024(notification post-commit/상태머신/DLQ 재처리) 구현·검증을 마친 뒤, **실 인프라(Kafka/PostgreSQL) + shop-core·notification 양 앱 기동** 으로 종단 연계 스모크를 수행했다. shop-core의 미결제 만료 스케줄러가 발행한 `OrderCancelledEvent`를 notification이 소비하다 `ConversionException: Failed to convert from JSON`으로 실패해 **모든 이벤트가 `*.DLQ`로 직행**하는 것을 관측했다. 024(notification) 자체는 정상이었고, 원인은 **shop-core 발행측 직렬화**였다.

---

## 2. 버그 — shop-core 외부화 이중 직렬화 (base64 래핑)

### 증상
`order-cancelled` 토픽의 실제 wire 값이 `"eyJldmVudElkIjoi...=="`(hex 선두 `22 65 79 4a` = `"eyJ`). base64를 풀면 `event-catalog`·notification DTO와 1:1 일치하는 정상 JSON. **내용은 정확하고 wire 래핑만 잘못**됐다 → 컨슈머가 객체로 역직렬화 불가.

### 근본 원인
- `spring-modulith-events-kafka:1.3.1`의 `KafkaJacksonConfiguration`이 외부화에 **`ByteArrayJsonMessageConverter`** 를 써서 이벤트를 **이미 JSON `byte[]`** 로 KafkaTemplate에 넘긴다. 라이브러리는 `kafka-json.properties`로 `spring.kafka.producer.value-serializer=ByteArraySerializer`를 **기본값**으로 제공(낮은 우선순위).
- 그런데 shop-core `application.yml`이 `value-serializer: JsonSerializer`로 **그 기본값을 override**(높은 우선순위) → `JsonSerializer`가 `byte[]`를 **한 번 더 직렬화 = base64 문자열로 인코딩** → 이중 직렬화.
- `application.yml`의 주석("`JsonSerializer(value)` — Modulith 외부화 어댑터와 호환")은 **오기**였다. 즉 무작위 실수가 아니라 **오해가 설정에 박혀** 있었다.

### 영향
외부화 경로(자동설정 producer)는 4개 계약 토픽(`order-completed`/`payment-failed`/`order-cancelled`/`shipping-started`)을 모두 공유 → **전 토픽 동일 증상**. 실 shop-core 이벤트가 notification에서 정상 처리된 적이 없었을 가능성이 높다(스모크의 `SENT` 행은 전부 합성 주입 이벤트였음).

### 수정 (Task 024-1)
producer `value-serializer`를 `JsonSerializer → ByteArraySerializer`로 1줄 교정(라이브러리 기본과 정합). key는 `StringSerializer` 유지. 전용 KafkaTemplate 빈 미도입(직접 발행 경로 0건 — YAGNI).

> 대칭 메모: 같은 부류(이중 인코딩) 버그를 notification 발행 경계(`.DLQ` producer)에서 024가 `JsonSerializer→StringSerializer`로 이미 교정했다(`.DLQ` value는 String). shop-core는 컨버터가 `byte[]`를 만들므로 대칭 교정값이 `ByteArraySerializer`다.

---

## 3. 왜 기존 테스트가 못 잡았나 (구조적 사각)

이 버그는 **라이브 종단 테스트 아니면 현실적으로 발견 불가**였다. 검증됨:

1. **발행측 무증상**: 외부화가 "성공" 커밋돼도 예외 0건. 결함은 컨슈머 역직렬화에서만 드러난다. 발행측(016~020)을 먼저 만들 당시엔 받을 컨슈머조차 없었다(피드백 루프 미폐쇄).
2. **in-process 캡처 테스트의 한계**: shop-core의 `*OutboxIntegrationTest`는 `@TransactionalEventListener(AFTER_COMMIT)` + `externalization.enabled=false`로 **이벤트 객체만 캡처** → 직렬화/wire 단계를 안 탄다.
3. **컨슈머 통합의 한계**: notification의 EmbeddedKafka 통합은 **자신의 DTO로 정상 형식 이벤트를 produce**(합성) → 실제 발행측 직렬화 wire를 거치지 않는다.
4. **순진한 wire 테스트조차 false-pass**: 024-1에서 처음 만든 wire 포맷 테스트가 **버그 설정에서도 GREEN**이었다. `src/test/resources/application.yml`이 `src/main`을 **classpath shadow**해서, 테스트가 production serializer를 안 읽고 라이브러리 기본(ByteArraySerializer)만 적용받았기 때문. → "wire를 테스트하자"고 한 사람조차 잘못된 초록불을 받는 함정.
5. **이론 검증의 함정**: 코드 리뷰가 property precedence 이론으로 "RED 난다"며 통과시켰으나, **실제 토글 실행에서 GREEN**이라 false-green이 반증됐다.

---

## 4. 결정 — 서비스 간 이벤트 종단 스모크 규칙 신설

`docs/rules/testing-rule.md`에 **§"서비스 간 이벤트 종단(end-to-end) 스모크 — 필수"** 를 추가한다. 핵심:

| 항목 | 규칙 |
|---|---|
| 의무 | 이벤트 드리븐 통합(발행→소비)에 **토픽별 종단 스모크 최소 1개**. 발행측 무증상이므로 컨슈머까지 가야 결함이 보인다. |
| 종단 스모크 정의 | **실제 발행 경로(`@Externalized`/Outbox)로 발행된 실 이벤트** → 실제 컨슈머 → **종단 상태**(예: `processed_event` `SENT`) 단언. **합성 이벤트로 대체 금지.** |
| 대체 금지 계층 | in-process 캡처(externalization=false), 컨슈머 단독(합성 produce), shadow로 false-pass하는 순진한 wire 테스트. |
| 비용 절감 조합 | 토픽 전수 대신 **대표 1~2개 종단 스모크 + 직렬화 설정 회귀 가드**(production `application.yml`을 **파일경로로 직접 읽어** 단언 — classpath shadow 우회). |
| 배치 | 인프라 비의존 `test`와 충돌하면 별도 태스크/CI 스텝(`e2e-runner`). EmbeddedKafka로 발행측 외부화 경로를 태울 수 있으면 `test` 내, 단 **effective 직렬화 설정 명시 고정**. |
| RED 확인 | 회귀 가드의 "버그 설정에서 실패"는 **실제 토글로 RED를 경험 확인** — 이론 추론 금지. |

---

## 5. 결과 (조치)

| 항목 | 조치 |
|---|---|
| shop-core 외부화 serializer | `JsonSerializer → ByteArraySerializer` 교정 (Task 024-1, 완료) |
| 회귀 가드 | `ProductionKafkaSerializerConfigTest` 신설 — production `application.yml`을 파일경로 직접 읽어 serializer 단언(shadow 면역, JsonSerializer 시 실제 RED 검증) |
| wire 테스트 정정 | `OutboxKafkaWireFormatTest` — 허위 전제("main app.yml이 SUT") 정정 + `@TestPropertySource`로 serializer 명시 고정 |
| 규칙 | `testing-rule.md`에 종단 스모크 §신설 |
| 024 검증 | notification 024는 실 Kafka+PG에서 `PENDING→SENT`·V2 마이그레이션·DLQ 라우팅·Option B 단일 인코딩까지 확인(연계 스모크) |

---

## 6. 보존되는 사실 / 후속

- shop-core 외부화의 정상 wire는 **plain JSON 오브젝트**(`{...}`)다. Modulith가 `byte[]` JSON을 만들므로 producer value 직렬화는 **`ByteArraySerializer`** 여야 한다(라이브러리 기본과 정합). 이 값을 다시 바꾸면 전 토픽이 깨진다.
- shop-core에 `@Externalized` 외 **직접 Kafka 발행 경로는 없다**(전역 `ByteArraySerializer`가 안전한 근거). 향후 객체를 직접 보내는 producer가 생기면 그때 **외부화 전용 producer 빈 분리**가 정당해진다.
- Modulith 버전 업 시 외부화 컨버터(`ByteArrayJsonMessageConverter`)가 바뀌면 serializer 가정을 재확인한다 — wire 테스트가 회귀를 자동 감지한다.
- **권장 후속**: CI 파이프라인에 docker-compose 기반 또는 EmbeddedKafka 기반 종단 스모크 스텝을 상시화(현재는 수동 연계 스모크 + 설정 회귀 가드로 대체). 더 강한 보장이 필요하면 컨트랙트 테스트(Pact/Spring Cloud Contract)로 wire 계약을 박제한다(architecture가 택한 "미러링·공유 라이브러리 없음" 트레이드오프의 보완).

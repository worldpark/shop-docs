# Plan 063. shop-core 이벤트 발행 회복(1) — Modulith 미완료 발행 재기동 시 재발행

> 대상 Task: `docs/tasks/backend/063-backend-shop-core-modulith-republish-outstanding-on-restart.md`
> 선행 결정: ADR-002(Transactional Outbox with Spring Modulith)의 "회복 자동화" 부분을 채운다.
> 구현 담당: `backend-implementor` (메인 오케스트레이션은 메인 에이전트).
> 화면 변경: **없음** → `view-implementor` 불필요. 도메인 로직·REST·뷰·스키마·이벤트 계약 무변경.
> 경계: 본 Task는 **재기동 회복**만 1급화한다. 정상 가동 중 주기적 재제출(스케줄러 + 리더 가드)은 **Task 064**, 미완료 건수 관측 강화는 **Task 064/065** 영역이다. 본 plan에서 신규 스케줄러·빈·엔드포인트·분산락을 제안하면 범위 위반이다.

---

## 1. 목표

shop-core가 기동 시 `event_publication`의 **미완료(INCOMPLETE, `completion_date IS NULL`) 발행을 자동 재제출**하도록 한다. 발행 시점에 Kafka가 프로듀서 `delivery.timeout`(~2분)을 초과해 장기 다운이어서 외부화에 영구 실패했더라도, **다음 기동에서 자동 복구**된다(원 리스너 재호출 → 외부화 리스너가 Kafka로 재발행 → 성공 시 `completion_date` 기록). 본질은 **`application.yml` 한 줄 + 회복 검증 통합 테스트 1개**다. 신규 프로덕션 클래스·빈·스케줄러는 만들지 않는다. 풀컨텍스트 `./gradlew test` 그린 유지.

---

## 2. 변경 대상 파일

- **수정 1개**: `shop-core/src/main/resources/application.yml` — `spring.modulith.events` 블록에 republish 프로퍼티 1줄 + 주석 추가.
- **신규(테스트) 1개**: `shop-core/src/test/java/com/shop/shop/platform/event/OutboxRepublishOnRestartIntegrationTest.java`(가칭) — 미완료 발행이 재제출되어 Kafka로 재외부화되고 `completion_date`가 채워짐을 검증.
- **기존 main 픽스처 재사용(신규 아님)**: `DummyEventPublishService`(`shop-core/src/main/java/com/shop/shop/platform/service/DummyEventPublishService.java`)·`DummyOutboxSmokeEvent`(`shop-core/src/main/java/com/shop/shop/platform/event/DummyOutboxSmokeEvent.java`)는 이미 `src/main`에 존재하는 Outbox 스모크 픽스처다(`OutboxKafkaWireFormatTest`가 동일하게 주입·재사용 중). 본 Task에서 **신규 생성하지 않고 그대로 재사용**한다 — "신규(테스트) 픽스처"로 오인 금지.
- **신규 프로덕션 클래스: 없음.** 재발행 메커니즘은 Spring Modulith가 이미 제공한다(§4 근거). 우리는 라이브러리가 제공하는 동작을 **프로퍼티로 활성화**만 한다.
- **build.gradle 변경: 없음.** 필요한 의존(`spring-modulith-starter-jpa`, `spring-modulith-events-kafka`, 테스트의 `spring-modulith-starter-test`, Testcontainers PG, `spring-kafka-test`)은 이미 존재(`OutboxKafkaWireFormatTest`가 동일 스택으로 동작 중).

---

## 3. 설정 변경 (application.yml)

`shop-core/src/main/resources/application.yml`의 기존 `spring.modulith.events` 블록(현재 38~47행, `externalization.enabled: true` 인접)에 다음을 추가한다.

```yaml
  modulith:
    events:
      externalization:
        enabled: true  # Spring Modulith Event Publication Registry 기반 Kafka 외부화 활성
      # [Task 063] 기동 시 미완료(INCOMPLETE, completion_date IS NULL) 발행을 자동 재제출한다.
      #   동작: 컨텍스트 기동 완료 시점(SmartInitializingSingleton)에 PersistentApplicationEventMulticaster가
      #         이 플래그를 읽어, 미완료 publication의 원 리스너를 재호출 → 외부화 리스너가 Kafka로 재발행한다.
      #   대상: completion_date IS NULL 인 건만. 이미 완료된 발행은 재제출되지 않는다(정상 흐름 불변).
      #   성격: at-least-once 회복 — 컨슈머 멱등 전제(§6). 재발행이 중복 전달을 유발할 수 있다.
      #   다중 노드 주의: 여러 노드 동시 기동 시 각 노드가 미완료분을 재발행 → Kafka 중복 게시 가능.
      #                  컨슈머 멱등으로 무해. "상시 회복을 리더 1노드만"으로 좁히는 건 Task 064(리더 가드) 영역.
      republish-outstanding-events-on-restart: ${SHOP_CORE_REPUBLISH_ON_RESTART:true}
      # JPA 변형(spring-modulith-starter-jpa) 사용 중이므로 아래 JDBC 전용 프로퍼티는 실효 없음.
      # ddl-auto=validate가 Hibernate 자동 DDL을 이미 차단하므로 추가 비활성 플래그는 불필요.
      jdbc:
        schema-initialization:
          enabled: false
```

**프로퍼티 키 — jar config-metadata 실측으로 확정(중요, 메인 셸 확인).** `spring-modulith-events-core-1.3.1.jar`의 `META-INF/spring-configuration-metadata.json`을 unzip해 직접 확인한 출력:

```
"name": "spring.modulith.republish-outstanding-events-on-restart",   ← 레거시(deprecated)
  "type": "java.lang.Boolean", "defaultValue": "false",
  "deprecation": { "replacement": "spring.modulith.events.republish-outstanding-events-on-restart",
                   "reason": "Moved to spring.modulith.events namespace. To be removed in 1.4.", "since":"1.3" }
"name": "spring.modulith.events.republish-outstanding-events-on-restart",   ← 정식(namespaced)
  "type": "java.lang.Boolean", "defaultValue": "false"
```

→ 유효(정식) 키는 `spring.modulith.events.republish-outstanding-events-on-restart`(타입 `Boolean`, 기본값 `false`)다. plan이 §3 yml에 둔 키와 위치(`spring.modulith.events` 블록 내부, `externalization.enabled` 인접)가 **이 실측과 정확히 일치**한다. **`...republish-outstanding-publications-on-restart`(Task 본문 표기)는 1.3.1 메타데이터에 존재하지 않는다 — 키워드는 `-events-`이지 `-publications-`가 아니다.** 비네임스페이스 레거시 키 `spring.modulith.republish-outstanding-events-on-restart`는 1.3에서 deprecated(1.4 제거 예정, 대체키가 위 네임스페이스 키)이며 멀티캐스터가 신규 키 → 레거시 키 순으로 fallback 조회한다. **신규 네임스페이스 키만 사용한다.**

- **환경변수 오버라이드**: `${SHOP_CORE_REPUBLISH_ON_RESTART:true}` — 기본 ON, 필요 시 `SHOP_CORE_REPUBLISH_ON_RESTART=false`로 끌 수 있다(다중 노드 운영에서 특정 노드만 비활성화하는 등). 로컬/운영 동일 ON 권장(at-least-once 회복은 단일/다중 노드 모두 안전, 중복은 컨슈머 멱등 흡수).
- 운영(`application-prod.yml`)·로컬(`application-local.yml`) 별도 오버라이드는 두지 않는다(공통 ON). 향후 다중 노드에서 리더만 회복하길 원하면 064가 담당한다.

---

## 4. 재발행 동작 설명 (Modulith 1.3.1 근거)

`spring-modulith-events-core-1.3.1.jar`의 `org.springframework.modulith.events.support.PersistentApplicationEventMulticaster`가 제공하는 동작(키·기본값은 §3 jar config-metadata 실측으로 확정):

1. 이 멀티캐스터는 `SmartInitializingSingleton` **및** `IncompleteEventPublications`를 구현한다.
2. **트리거 = `afterSingletonsInstantiated()`** — 컨텍스트의 모든 싱글톤 초기화 완료 직후(즉 앱 기동 시점) 1회 호출된다. 별도 스케줄러·`ApplicationReadyEvent` 리스너가 아니라 기동 1회성 훅이다.
3. 이 훅이 `Environment.getProperty("spring.modulith.events.republish-outstanding-events-on-restart", Boolean.class)`를 읽고(없으면 레거시 키 fallback), `Boolean.TRUE`이면 `resubmitIncompletePublications(p -> true)`를 호출한다(아니면 즉시 return — no-op).
4. `resubmitIncompletePublications(Predicate)`는 `IncompleteEventPublications` 인터페이스의 메서드로, 레지스트리의 **미완료(완료 미기록) publication**만 모아 **원 리스너(target listener)를 다시 invoke**한다. 우리 도메인에서 비동기·미완료 가능한 리스너는 Modulith 외부화 어댑터(라이브러리 내부 — 1.3.1에서 `DelegatingEventExternalizer`가 담당) 경로뿐이므로, 재호출 = **Kafka 재외부화**로 귀결된다. 재외부화 성공 시 레지스트리가 해당 publication의 `completion_date`를 기록한다.
5. **완료분 비대상**: predicate가 incomplete만 선별하므로 `completion_date`가 채워진 건은 재제출되지 않는다. 기동마다 이미 발행 완료된 이벤트가 다시 나가지 않는다 → 정상 흐름·기존 테스트 불변.
6. **in-process 부수효과 유무**: 미완료 publication의 리스너가 in-process 사이드이펙트를 가진 비동기 리스너라면 그 사이드이펙트도 재실행될 수 있다. 그러나 현 코드베이스의 미완료 가능 비동기 리스너는 Modulith 외부화 어댑터(라이브러리 내부) 단일(event_publication 운영 데이터 전건이 외부화 대상, Task 본문 확인)이므로 **재발행 = Kafka 재외부화 외 in-process 부수효과 없음.**

부가로, 같은 멀티캐스터가 **프로그래밍 API**(`resubmitIncompletePublications(Predicate)`, `resubmitIncompletePublicationsOlderThan(Duration)`)를 빈으로 노출한다(타입 `IncompleteEventPublications`로 주입 가능). 이는 §7 테스트에서 "재기동 트리거와 동일 코드 경로"를 결정적으로 구동하는 레버로 쓴다.

---

## 5. 데이터 흐름 (발행 실패 → INCOMPLETE 잔존 → 재기동 → 재외부화 → completion)

```
[정상]
도메인 변경 + publishEvent(ProductSearchIndexChangedEvent)  ── 같은 @Transactional ──┐
  → Modulith Registry가 event_publication INCOMPLETE 저장 (커밋과 원자적)              │ 커밋
  → 커밋 후 Modulith 외부화 어댑터(라이브러리 내부) → KafkaTemplate 외부화 성공                    │
  → completion_date 기록 (완료)  ────────────────────────────────────────────────────┘

[장기 다운으로 영구 실패]
  → 외부화 시도, Kafka가 delivery.timeout(~2분) 초과 다운 → 프로듀서 전송 영구 실패
  → completion_date 미기록 → event_publication 에 INCOMPLETE 잔존 (유실 없음, 단 재발행 자동화 부재 = 현재 갭)

[Task 063 — 다음 기동]
  → 앱 기동, 싱글톤 초기화 완료 → afterSingletonsInstantiated() 1회 호출
  → republish-outstanding-events-on-restart=true 감지
  → resubmitIncompletePublications(p->true): 미완료(completion_date IS NULL) 전건의 외부화 리스너 재호출
  → Modulith 외부화 어댑터(라이브러리 내부) 재외부화 → Kafka 재도착
  → completion_date 기록 (회복 완료)
```

---

## 6. 예외 처리 / 멱등 (at-least-once → 컨슈머 멱등)

재발행은 정의상 **중복 전달**을 유발할 수 있다(재기동 회복, 다중 노드 동시 기동). 이는 **새 멱등 위반을 만들지 않는다** — 이미 시스템이 at-least-once 전제로 멱등 컨슈머를 갖추고 있음을 대조:

- **shop-core indexer 컨슈머**: `ProductSearchIndexChangedEvent`를 `eventId` 멱등 키 + ES external version(`occurredAt` epoch millis, `_id=productId`)으로 upsert → 중복·순서 역전을 흡수(이벤트 클래스 Javadoc·Task 본문 확인). 재발행 동일 이벤트가 N회 도착해도 ES 최종 상태 동일.
- **notification 컨슈머**: idempotency + retry/DLQ 보유(Task 005). 본 Task는 notification 구독 이벤트(`ProductSearchIndexChangedEvent`는 비구독)와 무관하나, 일반 외부화 이벤트의 중복도 컨슈머 멱등으로 무해.
- **프로듀서 측**: `enable.idempotence=true`(acks=all), 본 Task에서 acks/retries/idempotence 튜닝 없음(Non-goal). 재발행 자체는 새 트랜잭션·새 외부화 시도일 뿐, 발행 경로 코드 무변경.
- **재제출 실패 처리**: 재기동 재제출이 또 실패하면(여전히 Kafka 다운) 해당 건은 다시 INCOMPLETE로 남아 **다음 기동에 재시도**된다(at-least-once 보존, 유실 없음). 상시 가동 중 재시도는 064.

이벤트 계약(`event-contract-rule.md`) 무변경: 토픽·페이로드 스키마·`@Externalized` 미수정. `docs/event-catalog.md` 갱신 불필요.

---

## 7. 검증 / 테스트 (확정안 — A: Testcontainers PG + EmbeddedKafka 통합)

### 7.1 권장안 확정: **A안(통합 — 재발행 실제 검증)** 채택. B안(슬라이스 프로퍼티 바인딩 단언)은 회복을 실제로 검증하지 못해 **불채택**.

근거: `OutboxKafkaWireFormatTest`라는 **동일 스택(Testcontainers PG + `@EmbeddedKafka` + `DummyEventPublishService`/`DummyOutboxSmokeEvent` Outbox 경로) 선례**가 이미 그린으로 존재한다. 그 **배선**(컨테이너·EmbeddedKafka·`@TestPropertySource` 국소 리셋·raw 컨슈머)을 계승하면 "미완료 시드 → 재제출 → Kafka 재도착 + `completion_date` 채워짐"을 결정적으로 단언할 수 있어, "테스트 없이 기능 추가 금지"(testing-rule)를 충족하면서 over-engineering도 피한다. 단, **`event_publication` 행을 직접 질의/시드하는 부분은 선례가 없는 신규 idiom**이다(선례는 배선만 제공; §7.2·§7.3 참조).

### 7.2 배선 (OutboxKafkaWireFormatTest 계승)

신규 테스트 클래스: `OutboxRepublishOnRestartIntegrationTest`.

- `@SpringBootTest` + `@AutoConfigureTestDatabase(replace = NONE)` + `@Testcontainers`(`PostgreSQLContainer("postgres:16.4-alpine")` + `@ServiceConnection`) + `@EmbeddedKafka(topics = DummyOutboxSmokeEvent.TOPIC)`.
- `@TestPropertySource`로 `OutboxKafkaWireFormatTest`와 동일하게 **테스트 yml의 전역 비활성을 국소 리셋**한다(이게 핵심 — `src/test/resources/application.yml`은 `spring.autoconfigure.exclude`에 `JpaEventPublicationAutoConfiguration`을 넣고 `externalization.enabled=false`로 둔다):
  - `spring.autoconfigure.exclude=`(빈 값 리셋 — JPA event publication / Kafka 자동설정 복원)
  - `spring.modulith.events.externalization.enabled=true`
  - `spring.modulith.events.republish-outstanding-events-on-restart=true`  ← **본 Task가 켜는 플래그를 테스트에서 명시 고정**
  - `spring.kafka.bootstrap-servers=${spring.embedded.kafka.brokers}`
  - `spring.kafka.producer.value-serializer=...ByteArraySerializer`
  - `spring.flyway.enabled=true`, `spring.jpa.hibernate.ddl-auto=validate`
  - `shop.order.pending-expiry.enabled=false`(스케줄러 빈 비활성, 선례 동일)
- 주입: `DummyEventPublishService`, `IncompleteEventPublications`(멀티캐스터 빈), `JdbcTemplate`(event_publication 상태 질의·시드), `EmbeddedKafkaBroker` + raw `StringDeserializer` 컨슈머(`OutboxKafkaWireFormatTest`의 `setUp`/`tearDown` 그대로).
  - **idiom 출처 명확화(과장 정정)**: `event_publication` 테이블을 직접 SELECT/UPDATE하는 테스트는 코드베이스에 **선례가 0건**이다(`PaymentOutboxIntegrationTest`는 `payments`/`orders`만 JdbcTemplate으로 질의하고 event_publication은 in-memory 리스너로 단언한다). 따라서 **event_publication 직접 질의/시드는 본 Task가 도입하는 신규 idiom**이며, 차용하는 것은 통합 테스트의 **JdbcTemplate 사용 패턴 자체**뿐이다. 실제 컬럼은 §7.3에 못박았다(추정 금지).

### 7.3 미완료 publication을 **결정적으로** 만드는 방법 (확정)

> "Kafka를 죽여 외부화를 실패시킨다"는 EmbeddedKafka 환경에서 재현이 까다롭고 flaky하다. 대신 **레지스트리 자체에 INCOMPLETE 행을 결정적으로 만든 뒤, 재제출 경로를 구동**한다.

**`event_publication` 실제 스키마 (running PG `\d`로 확인 — 메인 셸. implementor는 추정하지 말고 이 컬럼명/타입을 그대로 쓴다):**

```
id               uuid          PRIMARY KEY (not null)
publication_date timestamptz   not null
listener_id      text          not null
serialized_event text          not null
event_type       text          not null
completion_date  timestamptz   nullable   ← INCOMPLETE 마커 (NULL = 미완료)
```

확정 절차:
1. **정상 발행(베이스라인)**: `DummyEventPublishService.publish(msg)`를 호출해 정상 발행한다. 커밋 후 외부화가 완료되어 해당 행 `completion_date`가 채워진다(Awaitility로 Kafka 1건 수신을 확인).
2. **방금 시드한 행 식별**: 1단계가 만든 publication 행의 PK를 캡처한다 —
   `SELECT id FROM event_publication WHERE serialized_event LIKE '%<eventId>%'`
   (또는 `listener_id`가 외부화 리스너인 행으로 좁힌다). 이 `id`(uuid)를 이후 UPDATE·단언의 대상으로 고정한다.
3. **미완료 상태로 되돌림(시드)**: 캡처한 PK로 `UPDATE event_publication SET completion_date = NULL WHERE id = ?`를 실행해 그 행을 INCOMPLETE로 되돌린다. 이로써 "재기동 직전 INCOMPLETE 잔존" 상태를 결정적으로 재현한다.
   - **커밋 경계(중요 — MAJOR)**: Modulith의 resubmit는 미완료 publication을 **DB에서 재조회**한다. 따라서 이 시드 UPDATE는 (4)의 resubmit 호출 **전에 반드시 커밋**되어 있어야 한다. 이를 위해 **테스트 메서드에 `@Transactional`을 붙이지 않는다**(통합 테스트 관례 — `OutboxKafkaWireFormatTest`도 비-`@Transactional`). 비-트랜잭션 컨텍스트의 `JdbcTemplate.update`는 자동 커밋되므로 UPDATE가 즉시 커밋되고, (4)의 resubmit가 DB 재조회 시 이 incomplete 행을 본다. 이 인과(커밋된 UPDATE를 resubmit가 DB 재조회로 본다)를 깨면 재발행이 트리거되지 않는다.
   - **대안 부적합 근거**: "externalization을 끈 채 발행해 자연 INCOMPLETE를 만든다"는 부적합하다 — `@Externalized` 이벤트라도 externalization OFF면 **외부화 리스너가 등록되지 않아** resubmit 대상(미완료 외부화 publication) 자체가 생기지 않는다. 그래서 본 절차는 정상 발행(리스너 등록·완료) 후 UPDATE로 완료 마커만 되돌리는 방식을 택한다.
4. **컨슈머 오프셋 정리**: 1단계에서 받은 레코드를 비운 뒤(또는 새 group 컨슈머 재구독), 재발행 도착만 깨끗이 관측한다.
5. **재발행 트리거**: 주입한 `IncompleteEventPublications.resubmitIncompletePublications(p -> true)`를 호출한다. **이는 §4에서 확인한 바, 기동 시 `afterSingletonsInstantiated()`가 호출하는 것과 동일한 코드 경로**다(DB의 incomplete 재조회 → 외부화 재시도). 즉 "프로퍼티 ON일 때 기동이 수행하는 재발행"을 결정적으로 구동하는 것이며, 테스트에서 완전 컨텍스트 재기동을 흉내 내는 과한 장치를 피한다.
   - 보강(선택): 프로퍼티 자체의 startup 와이어링까지 확인하려면, 별도 테스트 메서드에서 `republish-...=true`로 띄운 컨텍스트가 정상 기동하고(멀티캐스터가 시작 시 no-op/resubmit를 수행) 회귀 없음을 확인한다. 그러나 **재발행 결과 단언은 (5)의 프로그래밍 트리거로 수행**한다.

### 7.4 단언

- **(a) Kafka 재도착**: 재제출 후 `KafkaTestUtils.getRecords(consumer, 10s)`로 `DummyOutboxSmokeEvent.TOPIC`에 해당 `eventId`가 도착함을 단언(`OutboxKafkaWireFormatTest`의 wire 파싱 idiom 재사용).
- **(b) completion 기록**: Awaitility로 `JdbcTemplate` 질의 — §7.3에서 캡처한 PK(`id` uuid)의 행이 `completion_date IS NOT NULL`(회복 완료)이 됨을 단언(`SELECT completion_date FROM event_publication WHERE id = ?`).
- **(c) 완료분 비재발행(회귀 가드)**: 사전에 정상 완료된 별도 이벤트(completion_date 채워진 행)는 재제출 호출에도 **다시 Kafka로 나가지 않음**을 단언(재제출 후 추가 도착 0건 또는 incomplete-only 선별 확인). → "기동마다 완료분 재발송 안 함" 명세를 코드로 못 박음.

### 7.5 완전 컨텍스트 재기동을 테스트에서 하지 않는 이유

완전 재기동(컨텍스트 close/refresh) 시뮬레이션은 (i) `@SpringBootTest` 컨텍스트 캐시·`@EmbeddedKafka` 수명과 충돌하고 (ii) 재기동 시 `afterSingletonsInstantiated`가 도는 시점을 결정적으로 관측하기 어려워 flaky하다. §4에서 startup 트리거가 호출하는 메서드가 공개 빈 API(`IncompleteEventPublications`)와 **동일 경로**임을 확인했으므로, 그 API를 직접 구동하는 것이 **동등하면서 결정적**이다. testing-rule("테스트 없이 기능 추가 금지")은 §7.4 단언으로 충족하고, over-engineering(컨텍스트 재기동 하네스)은 회피한다.

### 7.6 게이트

- 타깃 테스트만 먼저 RED→GREEN 반복(Testcontainers 비용 절감 — memory 선례). 풀 `./gradlew test`(~19분)는 마지막 1회.
- **풀컨텍스트 `./gradlew test` 그린**(verification-gate-rule §2, 메인 최종 동적 게이트).

---

## 8. 트레이드오프

- **재기동 회복(063) vs 상시 회복(064)**: 063은 기동 1회 훅(`afterSingletonsInstantiated`)이라 신규 빈·스케줄러·락 0으로 최저 비용이다. 단 "장기 다운 중 재기동이 일어나지 않으면" 회복이 지연된다(다음 기동까지 INCOMPLETE 잔존). 상시(주기) 회복은 064(스케줄 재제출 + `SchedulerLeaderGuard`)가 보완한다 — 상호 보완, 본 Task에서 064 기능 선구현 금지.
- **다중 노드 중복 외부화 vs 단순성**: 노드 N개 동시 기동 시 각자 미완료분을 재발행 → Kafka 중복 게시 가능. 컨슈머 멱등(§6)으로 무해하므로, 재기동 회복은 **리더 게이트 없이 노드별 독립 동작**(저비용·단순)으로 둔다. "회복을 리더 1노드만"이 필요하면 064. 본 Task는 환경변수(`SHOP_CORE_REPUBLISH_ON_RESTART`)로 노드별 on/off 여지만 남긴다.
- **테스트 깊이**: 완전 재기동 하네스(최대 충실도, 고비용·flaky) vs 프로그래밍 트리거(동일 코드 경로, 결정적). 후자를 택해 충실도/안정성 균형을 잡았다(§7.5).

---

## 9. plan 확정 결정 (구현 전 고정)

1. **프로퍼티 키**: `spring.modulith.events.republish-outstanding-events-on-restart`(1.3.1 유효 키, jar config-metadata 실측 — §3에 실측 출력 인용, 메인 셸 확인). 레거시 키(`spring.modulith.republish-...`)는 deprecated(1.4 제거). 오타 키(`-publications-`)는 메타데이터에 부재 → 미사용. 값 `${SHOP_CORE_REPUBLISH_ON_RESTART:true}`(기본 ON, 로컬/운영 공통).
2. **신규 프로덕션 코드 0**: 재발행은 Modulith 멀티캐스터의 기동 훅이 수행. 클래스·빈·스케줄러·엔드포인트 신설 없음.
3. **테스트 = A안**: `OutboxKafkaWireFormatTest` **배선** 계승(Testcontainers PG + `@EmbeddedKafka` + 기존 main Dummy 이벤트 재사용 + `@TestPropertySource` 국소 리셋, 비-`@Transactional`). `event_publication` 직접 질의/시드는 신규 idiom(선례 0건). 정상 발행 → 해당 행 PK 캡처 → `UPDATE ... SET completion_date = NULL`(자동 커밋) → `IncompleteEventPublications.resubmitIncompletePublications`(= 기동 트리거와 동일 경로, DB incomplete 재조회)로 구동 → Kafka 재도착 + 해당 PK `completion_date` 채워짐 + 완료분 비재발행 단언.
4. **주의 문서화 수준**: at-least-once·재기동 트리거·다중 노드 중복을 yml 주석(§3) + plan 트레이드오프(§8)에 명문화. 064/065 경계 명시.

---

## 10. 리뷰 관점 (reviewer 체크리스트)

- **범위 최소성**: 프로덕션 변경이 `application.yml` **한 줄(+주석)** 인가. 신규 프로덕션 클래스·빈·`@Scheduled`·엔드포인트·분산락이 **없는가**(있으면 064 범위 침범 → FAIL).
- **프로퍼티 정확성**: 키가 `spring.modulith.events.republish-outstanding-events-on-restart`인가(`-events-`, `-publications-` 아님). `externalization.enabled`와 같은 `spring.modulith.events` 블록에 위치하는가. 환경변수 오버라이드(`${...:true}`) 형태인가. build.gradle 버전 하드코딩 변경 없는가.
- **테스트가 회복을 실제 검증하는가**: 단순 프로퍼티 바인딩 단언에 그치지 않고, (a) INCOMPLETE 시드 → (b) 재제출(기동과 동일 경로) → (c) **Kafka 재도착 AND `completion_date` 채워짐**을 단언하는가. 완료분 비재발행 회귀 가드가 있는가.
- **배선 계승**: `OutboxKafkaWireFormatTest`의 `@TestPropertySource` 국소 리셋(`autoconfigure.exclude=` 빈 값, `externalization.enabled=true`, `bootstrap-servers=${spring.embedded.kafka.brokers}`, `ByteArraySerializer`, flyway/ddl-auto)을 따랐는가. 새 mock/컨텍스트 전략을 발명하지 않았는가.
- **회귀 0**: 완료된 발행은 재제출되지 않음(정상 흐름 불변). 테스트 컨텍스트의 republish ON이 기존 외부화/Outbox 통합 테스트를 깨지 않는가(미완료 시드 부작용이 다른 테스트로 누수되지 않게 시드를 자기 테스트 내에 한정). 풀 `./gradlew test` 그린.
- **계약/도메인 불변**: `@Externalized` 토픽·페이로드·`docs/event-catalog.md` 무변경. REST/뷰/스키마/SecurityConfig 무변경(api-authorization-rule 해당 없음).

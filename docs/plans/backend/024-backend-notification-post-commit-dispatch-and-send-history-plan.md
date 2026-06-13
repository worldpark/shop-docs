# 024 notification post-commit 발송 분리 + 발송 상태머신/이력(V2) + DLQ 재처리 plan

> 023의 `claim+dispatch 단일 트랜잭션`을 **claim(PENDING) 커밋 → 트랜잭션 밖 dispatch → 결과(SENT/FAILED) 기록** 3단계로 분리해 블로킹 SMTP를 DB 트랜잭션 밖으로 빼고(long-transaction 제거), `processed_event`를 `PENDING→SENT/FAILED` 상태머신으로 확장(V2)하며, `.DLQ` 페이로드를 발송 경로로 재투입하는 멱등 재처리 컴포넌트를 추가한다. 이벤트 계약·005/023 골격·메시지 재배달 계층은 무변경.

---

## 1. 설계 방식 및 이유

본 Task는 메시지 재배달 계층(005)·발송 오케스트레이션/렌더링/채널(023)은 그대로 두고, **`process` 흐름의 트랜잭션 경계 재배치 + `processed_event` 상태머신 + `.DLQ` 재처리**만 더한다. Task가 plan에 위임한 5개 택1을 아래와 같이 확정한다. 모든 결정은 Task 불변식(터미널 `SENT`만 사전 skip, 비터미널 재claim 원자 가드, dispatch는 트랜잭션 밖, FAILED=audit-only, 재처리 소스는 `.DLQ`)을 만족하도록 상호 정합되게 골랐다.

### (a) 터미널 성공 상태 명명

| 결정 | **`PROCESSED` → `SENT`로 개명** |
|---|---|
| 근거 | 상태머신이 `PENDING → SENT \| FAILED`로 바뀌므로, 터미널 성공을 `PROCESSED`로 두면 "처리됨"이 "claim됨(PENDING)"인지 "발송 성공"인지 의미가 모호해진다. `SENT`는 "발송 완료"를 명시해 사전 skip 불변식("터미널 `SENT`만 skip")과 1:1 대응한다. churn은 V2 데이터 이행 + enum/팩토리/테스트 갱신으로 한정되며 한 번에 끝난다(아래 영향 범위). |

**개명 영향 범위(한 번에 갱신):**
- `ProcessingStatus`: `{PROCESSED, FAILED}` → `{PENDING, SENT, FAILED}` (`PROCESSED` 제거, `PENDING`/`SENT` 추가).
- `ProcessedEvent` 책임 한정: `pending()` 팩토리(신규 claim INSERT용, `status=PENDING, attempts=1`) + 추적 필드(`attempts`/`dispatchedAt`/`lastFailureAt`) 보유. **엔티티 레벨 전이 메서드(`markSent()`/`markFailed()`)는 두지 않는다** — SENT/FAILED 전이와 재claim(attempts+1)은 모두 repository `@Modifying` UPDATE(eventId 직접)가 수행하므로 엔티티 전이 메서드는 프로덕션 미호출 dead code가 된다. 기존 `processed(...)` 팩토리는 `pending(...)`으로 대체(개명), `failed(...)` 팩토리는 INSERT 경로에서 쓰이지 않으면 제거(전이는 SQL이 담당).
- V2 마이그레이션: 기존 행 `UPDATE ... SET status='SENT' WHERE status='PROCESSED'` + CHECK 술어 교체.
- 기존 테스트 갱신 지점(개명에 직접 닿는 것만):
  - `EventProcessingServiceTransactionTest`: `ProcessedEvent.processed(...)` 호출 → `pending()` 팩토리 경로로, `getStatus()==PROCESSED` 단언 → `SENT`로(상태 전이 자체는 repository `@Modifying` 슬라이스에서 검증). dispatch 실패 시 "claim 롤백(이력 0건)" 단언은 **구조가 바뀌므로 재작성**(아래 §5).
  - `EventProcessingTransactionHelperTest`: 현재 `transactionHelper.claimAndDispatch(event)`를 직접 호출(:74,89,107)하고 단일-TX claim-then-send 불변식·`PROCESSED` 상태를 단언한다. §2가 `claimAndDispatch`를 제거/분리하므로 이 테스트는 **컴파일 불가** → **기존 테스트는 삭제**하고, 분리된 협력 빈 메서드(`claimPending`·`recordSent`·`recordFailed`)에 대한 **신규 단위 테스트로 대체**(메서드가 사라지므로 1:1 이관이 아니라 신규 작성, 아래 §5).
  - 통합 테스트(`NotificationEventConsumerIntegrationTest`)의 주석/표현 `PROCESSED` → `SENT`(단언이 `hasEventId` 기반이라 로직 영향 적음, 상태 단언 추가 시 `SENT`).
  - `FakeProcessedEventStore`: 상태 전이/재claim 모사 위해 메서드 추가(아래 §5).

### (b) post-commit 메커니즘

| 결정 | **순차 호출 분리** (claim TX 협력 빈 → 트랜잭션 밖 dispatch → 결과기록 TX 협력 빈) |
|---|---|
| 근거 | `@TransactionalEventListener(AFTER_COMMIT)`는 (1) dispatch가 리스너로 비동기·간접화돼 호출 순서/예외 재전파가 불투명하고, (2) AFTER_COMMIT 리스너에서 던진 예외는 원래 트랜잭션 커밋 이후라 **Kafka 컨테이너의 동기 재시도 경로로 자연스럽게 재전파되지 않는다**(005 `DefaultErrorHandler` 합류 불가) → 재시도/DLQ 골격 보존 불가. 순차 호출 분리는 현 `EventProcessingTransactionHelper`(self-invocation 우회용 별도 빈) 패턴을 그대로 이어받아 호출 순서·예외 재전파가 명료하고, dispatch가 어떤 트랜잭션에도 들지 않음을 코드로 단언 가능하다. **불변식**: dispatch는 claim TX 빈/결과기록 TX 빈 **바깥**(=`EventProcessingService.process` 본문, `@Transactional` 없음)에서 호출된다. |

### (c) 비터미널 재claim 원자 가드

| 결정 | **조건부 `UPDATE ... SET status='PENDING', attempts=attempts+1 WHERE event_id=? AND status<>'SENT'`의 affected-rows 판정** |
|---|---|
| 근거 | (1) `@Version` 낙관적 락은 `OptimisticLockException` 처리 분기와 재조회 루프가 필요해 코드가 늘고, 단일 UPDATE로 충분한 곳에 엔티티 버전 컬럼/예외 변환을 더한다(YAGNI). (2) `SELECT ... FOR UPDATE`는 행 락을 잡지만 본 Task 불변식은 "dispatch 동안 락을 잡지 않음"(long-transaction 회피)이라 락을 claim 직후 곧 풀 거면 조건부 UPDATE와 효과가 같고 오히려 복잡. (3) 조건부 UPDATE는 **단일 원자 statement**로 `WHERE status<>'SENT'`가 터미널 가드 + 재claim 선점 판정을 동시에 수행한다. `@Modifying` 쿼리의 **반환 int(affected rows)=1**이면 이 워커가 선점, **=0**이면 다른 워커 선점 또는 이미 `SENT` → dispatch하지 않고 종료. lost update 방지 불변식 충족. |

> 정합 메모: 신규 이벤트는 INSERT 경로(UNIQUE 경합 → `DataIntegrityViolationException` 흡수, 005 그대로), 비터미널 재방문만 이 조건부 UPDATE 경로. 두 경로는 `process`에서 명확히 분기한다(§3).

### (d) DLQ 재처리 형태

| 결정 | **`.DLQ` 전용 리스너를 "수동/배치로만 활성"** (자동 상시 소비 안 함). redrive(.DLQ→원본토픽 re-publish)는 채택 안 함 |
|---|---|
| 근거 | (1) redrive는 메시지를 원본 토픽에 되쏘아 정상 컨슈머가 다시 소비 → "DLQ 적재 → 재투입 → 또 DLQ" 무한 루프 위험과 원본 토픽 오프셋 오염이 있고, 외부 트리거 없는 본 Task엔 과하다. (2) `.DLQ` 전용 리스너는 페이로드 보유 메시지를 직접 읽어 **발송 경로(`EventProcessingService.process`)로 재투입**하므로 `.DLQ`→원본 되쏘기 없이 멱등 재발송이 끝난다. **외부 API 미노출**: REST/View 트리거 없음. **테스트 비활성 가드**: 022의 `@ConditionalOnProperty` 가드 선례를 따른다(022는 스케줄러 컴포넌트 + `@EnableScheduling` 설정 **양쪽을 `@ConditionalOnProperty(...enabled=true)`로 가드**해 풀컨텍스트 `test`에서 백그라운드 실행을 차단). 본 Task도 `.DLQ` 재처리 컴포넌트를 프로퍼티 가드로 두어 풀컨텍스트 `test`·기본 기동에서 `.DLQ`를 자동 소비하지 않고, 수동 트리거(또는 가드된 스케줄러)로만 발송 경로에 재투입한다. 구체 메커니즘(리스너 `autoStartup=false` vs `@ConditionalOnProperty` 가드)은 implementor 확정 여지로 둔다. `@Profile("kafkatest | !test")` 유지. |

> `.DLQ`는 정의상 재시도 소진 후에만 적재되므로 "재시도 중 행"과의 경합이 없어 `dead_lettered`/age/attempts 윈도우 가드가 불필요(Task 명시). 재투입의 멱등은 사전 skip(`SENT`)+재claim 가드가 그대로 보장.

### (e) 추적 컬럼 최소 집합

| 결정 | `attempts`(int, NOT NULL **DEFAULT 1**) · `dispatched_at`(timestamptz NULL) · `last_failure_at`(timestamptz NULL) **3개만 신규**. `failure_reason`(V1 기존)은 재사용 |
|---|---|
| 근거 | audit/재처리 관측에 필요한 최소: **시도 횟수**(재claim마다 +1), **발송 성공 시각**(`SENT` 전이 시 set), **마지막 실패 시각**(`FAILED` 전이 시 set). `failure_reason`은 V1에 이미 있으므로 재사용(마지막 실패 사유). `created_at`/`updated_at`은 `BaseEntity` auditing이 이미 소유(첫 claim 시각 ≈ `created_at`). 별도 `send_history` 테이블·페이로드 컬럼·성공 횟수/채널 컬럼 등은 도입 안 함(YAGNI, 페이로드 미보관 불변식). |

> **구현 정정(DEFAULT 0→1)**: `attempts`는 `DEFAULT 1`로 구현했다. `pending()` 신규 INSERT는 항상 `attempts=1`이라 DEFAULT를 타지 않고, DEFAULT가 적용되는 대상은 V2 이행으로 `SENT`가 되는 **기존 `PROCESSED` 행**뿐인데 이 행은 "이미 1회 발송 완료"이므로 `attempts=1`이 의미상 옳다(reviewer 확인). V2 SQL에 동일 취지 주석 있음.

---

## 2. 구성 요소

> notification 단일 레포 내부. 경로는 `notification/src/main/java/com/shop/notification/...`.

### 수정 파일

| 파일 | 책임 변경 |
|---|---|
| `service/EventProcessingService.java` | `process`를 3단계로 재구성: ① 사전 skip(**터미널 `SENT`만**) ② claim(PENDING) 커밋 — 신규는 INSERT(경합 `DataIntegrityViolationException` 흡수 유지), 비터미널 재방문은 **조건부 UPDATE affected-rows 판정**(0이면 양보·종료) ③ **트랜잭션 밖** dispatch 호출 → 성공/실패에 따라 결과기록 TX 빈 호출 + 예외 재전파. self-invocation 우회 위해 트랜잭션 경계는 협력 빈에 위임(현 구조 계승). |
| `service/EventProcessingTransactionHelper.java` | 단일 `claimAndDispatch` 제거/분리 → **claim TX 메서드**(`claimPending`: INSERT 또는 조건부 UPDATE, `@Transactional`)와 **결과기록 TX 메서드**(`recordSent`/`recordFailed`, `@Transactional`)로 분리. **dispatch 호출은 이 빈에서 제거**(트랜잭션 밖에서 `process`가 호출). |
| `domain/ProcessedEvent.java` | 책임 한정: `pending()` 팩토리(신규 claim INSERT용, `status=PENDING, attempts=1`) + 추적 필드 `attempts`/`dispatchedAt`/`lastFailureAt` 보유. **엔티티 레벨 전이 메서드(`markSent()`/`markFailed()`/attempts 증가)는 두지 않는다** — SENT/FAILED 전이와 재claim은 repository `@Modifying` UPDATE가 담당(엔티티 전이 메서드는 프로덕션 미호출 dead code). Entity 비노출 유지. |
| `domain/ProcessingStatus.java` | `{PROCESSED, FAILED}` → `{PENDING, SENT, FAILED}`. |
| `repository/ProcessedEventRepository.java` | `existsByEventIdAndStatus(eventId, SENT)`(터미널 사전 skip), `findByEventId(eventId)`(**재방문-vs-신규 claim 경로 분기 판단용** — 결과기록용 아님), 재claim용 `@Modifying @Query("UPDATE ... SET status=PENDING, attempts=attempts+1, updated_at=now() WHERE eventId=:id AND status<>SENT")`(int 반환), 결과기록용 `@Modifying` UPDATE 쿼리 — `recordSent`(eventId로 `status=SENT, dispatched_at=now(), updated_at=now()` 직접 UPDATE)·`recordFailed`(eventId로 `status=FAILED, failure_reason=:reason, last_failure_at=now(), updated_at=now()` 직접 UPDATE). **`@Modifying` UPDATE는 JPA auditing(`@LastModifiedDate`)을 우회**하고 V1엔 트리거가 없으므로, 세 UPDATE문 모두 `updated_at=now()`를 함께 SET해 audit 컬럼이 INSERT 시각에 고착(stale)되지 않게 한다. **엔티티 save/재조회 경유 안 함**: 재claim 결정(c)이 affected-rows 판정으로 엔티티 적재를 요구하지 않으므로, 결과기록도 eventId 직접 UPDATE로 일관(SENT/FAILED 기록 전 `findByEventId` 재조회 불필요). |

### 신규 파일

| 파일 | 책임 |
|---|---|
| `src/main/resources/db/migration/V2__processed_event_send_state.sql` | V1 무명 status CHECK DROP → `status IN ('PENDING','SENT','FAILED')` 재ADD; `UPDATE processed_event SET status='SENT' WHERE status='PROCESSED'` 데이터 이행; `attempts int NOT NULL DEFAULT 0`, `dispatched_at timestamptz`, `last_failure_at timestamptz` 추가. **V1 수정 금지(체크섬).** |
| `service/DlqReprocessingService.java`(또는 별도 컴포넌트) | `.DLQ` 토픽 메시지(페이로드 보유)를 수동/배치 트리거로 소비 → `EventProcessingService.process`로 재투입(멱등). **호출 가능한 수동 트리거 메서드**(예: `.DLQ`를 raw `KafkaConsumer`로 poll → 각 메시지를 `process`로 재투입)로 구현해 테스트/운영이 직접 호출 가능하게 한다 — 순수 자동 `@KafkaListener`만으로 두지 않는다(§5의 '수동 트리거 메서드를 테스트가 직접 호출' 계약 충족; 기존 `NotificationEventConsumerIntegrationTest`가 raw `KafkaConsumer`로 `.DLQ`를 poll하는 선례 계승). **4개 `.DLQ` 토픽(`order-completed.DLQ`/`payment-failed.DLQ`/`order-cancelled.DLQ`/`shipping-started.DLQ`) → 구체 이벤트 타입 매핑** 후 `process(EventEnvelope)` 재투입(4개 메인 리스너 미러; 구체 배선은 implementor 확정 여지). `@Profile("kafkatest | !test")` + **테스트 비활성**(자동 소비 안 함: 022의 `@ConditionalOnProperty` 가드 선례를 따름, 구체 메커니즘은 implementor 확정). 외부 REST/View 미노출. |

### 변경 없음(재사용)

- `consumer/NotificationEventConsumer`(4종 구독, 위임만), `service/EmailNotificationDispatchService`·`NotificationMessageRenderer`·`EmailSender`/`LoggingEmailSender`/`JavaMailEmailSender`(023), `common/exception/*`·`common/error/ProcessingError`.

> **구현 일탈(사용자 승인 — KafkaConsumerConfig 1줄 변경)**: plan 초안은 `KafkaConsumerConfig`를 "변경 없음"으로 뒀으나, 구현 중 **잠복 프로덕션 버그**가 드러났다 — `dlqProducerFactory`의 value 직렬화가 `JsonSerializer`라, 메인 컨슈머가 String(JSON)으로 받은 값을 DLPR가 한 번 더 인코딩해 `.DLQ`에 **이중 인코딩** JSON이 적재된다(`.DLQ` 소비자가 없던 023까지는 무해·잠복). 024가 `.DLQ`를 처음 소비하면서 `DlqReprocessingService`의 역직렬화가 **항상 실패** → 재처리 기능 자체가 불능. **Option B(발행측 근본 수정)로 사용자 승인** 후 `dlqProducerFactory` value 직렬화를 `JsonSerializer → StringSerializer`로 1줄 변경해 `.DLQ`가 원본 토픽과 동일한 단일 JSON을 보존하게 했다. 재배달 **라우팅/재시도/비재시도 예외 동작은 무변경**(직렬화 포맷만 교정). `KafkaConsumerConfig`에 사유 주석 있음. (`DefaultErrorHandler`/DLQ 라우팅/재시도 설정 자체는 그대로.)
- `docs/event-catalog.md`/`docs/architecture.md §5`, notification DTO 미러, Redis dedup(미적용).

---

## 3. 데이터 흐름

`process(event)` 본문(트랜잭션 없음)에서 협력 빈을 순차 호출한다. 표기: `[T]`=별도 짧은 트랜잭션, `[NT]`=트랜잭션 밖.

### 정상(신규 1건)
1. `[NT]` 사전 skip 체크: `existsByEventIdAndStatus(eventId, SENT)` → false(통과).
2. `[NT]` 재방문 판단: `findByEventId` 없음 → **신규** → claim TX 빈 `claimPending` INSERT(`status=PENDING, attempts=1`) **커밋**. (블로킹 SMTP 이전, DB 트랜잭션 닫힘.)
3. `[NT]` `dispatchService.dispatch(event)` 호출 — 렌더링 + `EmailSender.send`. **트랜잭션 밖**. 성공.
4. `[T]` 결과기록 빈 `recordSent(eventId)`: `status=SENT, dispatched_at=now` 커밋. `[EMAIL_DISPATCHED]`/`SENT` 로그.
5. 리스너 정상 반환 → 컨테이너 오프셋 커밋(AckMode.RECORD). 이메일 1건.

### 일시 실패(retryable)
1~2. 동일(PENDING 커밋됨).
3. `[NT]` dispatch가 `NotificationException(retryable=true)`.
4. `[T]` `recordFailed(eventId, reason)`: `status=FAILED, failure_reason, last_failure_at=now` 커밋(**별도 TX → 재전파해도 롤백 안 됨**).
5. `process`가 예외 **재전파** → `DefaultErrorHandler`가 **컨테이너 동기 재호출(in-memory re-seek)**.
6. 재호출: 사전 skip → `FAILED`(비터미널) 통과 → **재방문(UPDATE)** → 조건부 `UPDATE ... WHERE status<>'SENT'` affected=1 → `PENDING, attempts+1` 커밋 → 재dispatch.
7. 재시도 소진 → `원본토픽.DLQ` 발행 + `FAILED` 행 audit 잔존.

### 영구 실패(non-retryable)
1~2. 동일. 3. dispatch가 `NonRetryableNotificationException`. 4. `[T]` `recordFailed`. 5. 재전파 → `DefaultErrorHandler`가 비재시도(설정상 `addNotRetryableExceptions`) → **재시도 없이 `.DLQ`** + `FAILED` 행 audit.

### 중복·경합
- **이미 `SENT`**: 1단계에서 `existsByEventIdAndStatus(...,SENT)=true` → 발송 0건 `[DUPLICATE]` skip.
- **최초 claim INSERT 경합**(두 워커 동시 신규): 한쪽 INSERT 성공, 다른 쪽 `DataIntegrityViolationException` → `process`가 트랜잭션 밖에서 흡수 `[DUPLICATE]`(005 그대로).
- **비터미널 재claim 경합**(두 워커가 `PENDING`/`FAILED` 동시 재방문): 조건부 UPDATE는 단일 원자 statement → 한 워커만 affected=1(선점·dispatch), 다른 워커 affected=0 → **dispatch 안 하고 종료**(lost update 없음). 단, SMTP 동안 락 미보유라 cross-node 동시 dispatch는 완전 직렬화 안 됨(§6, 단일 노드 미발생).

### DLQ 재처리
1. (수동/배치 트리거) `DlqReprocessingService`가 `.DLQ` 토픽 메시지(페이로드 보유) 소비.
2. 역직렬화한 이벤트로 `EventProcessingService.process(event)` 재투입.
3. 멱등: 이미 `SENT`면 사전 skip(무동작), 아니면 재claim→재dispatch→성공 시 `FAILED/PENDING → SENT`.
4. `.DLQ`=소진 후만 적재 → "재시도 중 행" 경합 없음 → 별도 윈도우 가드 불필요.

---

## 4. 예외 처리 전략

- **`NotificationException`(retryable)**: dispatch(트랜잭션 밖)에서 발생 → `process`가 catch → `[T] recordFailed` 호출(별도 TX 커밋, FAILED+사유+`last_failure_at`+`updated_at=now()`) → **동일 예외 재전파**. 별도 TX이므로 재전파해도 FAILED 기록은 살아남는다(단일 TX 시절 "claim 롤백"과 결정적 차이). `DefaultErrorHandler`가 동기 재시도. (`recordSent`/`recordFailed`/재claim의 `@Modifying` UPDATE는 JPA auditing을 우회하므로 `updated_at`을 SQL에서 직접 갱신 — §2.)
- **`NonRetryableNotificationException`**: 동일하게 `recordFailed` 후 재전파. `KafkaConsumerConfig.addNotRetryableExceptions(NonRetryableNotificationException.class)`가 재시도 없이 `.DLQ` 라우팅(무변경).
- **`DataIntegrityViolationException`**(최초 INSERT claim 경합): claim TX 빈 밖(`process`)에서 흡수 → `[DUPLICATE]`. 단일 TX 시절과 동일하게 **트랜잭션 경계 밖에서만** 흡수해야 `UnexpectedRollbackException` 오염을 피한다(현 분리 사유 계승). 재claim(UPDATE) 경로에서는 DIVE가 안 나므로 **조건부 UPDATE affected-rows=0**으로 선점을 판정(이 경로엔 DIVE 흡수가 적용 안 됨 — Task 명시).
- **결과기록 TX 자체 실패**(드묾): `recordSent`/`recordFailed` 커밋 실패 시 예외 전파 → 컨테이너 재시도. "전송 성공 → SENT 기록 직전 크래시" 잔여 윈도우는 단일 TX와 구조적으로 동일하게 수용(§6).
- 로깅: claim/`[EMAIL_DISPATCHED]`/`[DISPATCH_FAILED]`(`ProcessingError.from`)/재claim/`[DUPLICATE]`/`[DLQ]`/재처리를 `eventId`·타입·상태와 함께(005/023 계승).

---

## 5. 검증 방법

빌드/검증 명령(notification 레포): `./gradlew test`(Windows: `gradlew.bat test`). 풀컨텍스트 `test` 그린 + 005/023 회귀 없음이 게이트.

### 단위(Mockito)
- **`EventProcessingService.process` 3단계**(`EventProcessingServiceTest` 확장): 사전 skip이 `SENT`에만 동작(`PENDING`/`FAILED`는 통과해 재claim 호출), 신규=claim INSERT 경로·재방문=조건부 UPDATE 경로 분기, dispatch 성공 시 `recordSent` 1회·실패 시 `recordFailed` 1회 후 예외 재전파, 호출 순서/횟수. `transactionHelper`/`dispatchService`/`repository` Mock.
- **`ProcessedEvent.pending()` 팩토리 + 추적 필드 기본값**(신규 단위): `pending()`이 `status=PENDING`, `attempts=1`, `dispatched_at`/`last_failure_at` null로 생성됨을 단언. **상태 전이(SENT/FAILED 전이·재claim attempts+1)는 엔티티 메서드가 아니라 repository `@Modifying` UPDATE가 수행하므로, 그 검증은 아래 "슬라이스 — 재claim 원자성"과 같은 `@Modifying` 슬라이스 계층에서 affected-rows·컬럼 갱신(`status`/`dispatched_at`/`last_failure_at`/`updated_at`)으로 한다**(여기 단위에서는 전이 메서드를 두지 않으므로 전이 단언 없음).
- **분리된 협력 빈 단위**(`EventProcessingTransactionHelperTest` **삭제** 후 분리 빈 신규 단위 테스트 작성): `claimPending`(신규 INSERT / 비터미널 조건부 UPDATE), `recordSent`(dispatched_at set), `recordFailed`(failure_reason/last_failure_at set) 각각의 호출·인자를 단언(기존 `claimAndDispatch` 단위 단언과 1:1 이관 아님 — 메서드가 사라지므로 신규 작성). dispatch 호출이 이 빈에서 제거됐음(트랜잭션 밖 `process` 책임)을 함께 단언.
- **`DlqReprocessingService`**(신규 단위): `.DLQ` 메시지 → `process` 재투입 1회, 이미 `SENT`면 사전 skip으로 무동작(별도 윈도우 가드 없음).

### 슬라이스 — repository `@Modifying` UPDATE (재claim 원자성 + 결과기록 전이)
- **조건부 재claim UPDATE affected-rows**(`@DataJpaTest` + H2, 또는 Testcontainers PG): 비터미널 행에 조건부 전이 → affected=1(선점·`PENDING`, `attempts+1`), 이미 `SENT`면 affected=0(미발송), 동시 재claim 모사 시 한 워커만 1행(lost update 없음).
- **결과기록 UPDATE 컬럼 갱신**(같은 슬라이스 계층): `recordSent`(eventId) → `status=SENT`·`dispatched_at` set, `recordFailed`(eventId, reason) → `status=FAILED`·`failure_reason`·`last_failure_at` set. **세 UPDATE(재claim/`recordSent`/`recordFailed`) 모두 `updated_at`이 INSERT 시각보다 갱신됨**(auditing 우회 보정 검증).

### 트랜잭션/post-commit(`EventProcessingServiceTransactionTest` **재작성**)
- 단일 TX 시절 "dispatch 실패 → claim 롤백(이력 0건)" 단언을 **구조 변화에 맞게 교체**: dispatch가 트랜잭션 밖에서 호출됨, dispatch 실패 시 **`PENDING` claim은 커밋 유지**(이력 1건, `status=FAILED`로 기록), 재방문 시 재claim 가능. 최초 INSERT 경합 `DataIntegrityViolationException` 흡수 유지. Fake/Mock `NotificationDispatchService`로 발송 횟수(이중 발송 없음) 검증.
- `FakeProcessedEventStore` 확장: 결과기록(`recordSent`/`recordFailed`)·조건부 재claim(affected-rows) UPDATE를 eventId 직접 갱신으로 모사(엔티티 전이 메서드 아님 — 프로덕션 repository `@Modifying`와 동형), 기존 롤백 콜백은 보존하되 "claim 별도 커밋"이 롤백되지 않도록 결과기록 TX와 분리 모사.

### 마이그레이션(`FlywayMigrationScriptTest` 확장 → DB 적용형 보강)
- 현 테스트는 V1 **정적 텍스트** 검증만 한다. V2 정합(문자열 값·CHECK·데이터 이행)은 정적 검증으로 부족 → **Testcontainers PG에서 V1→V2 적용** 테스트 추가: 기존 `PROCESSED` 행이 `SENT`로 이행됨, `PENDING`/`SENT`/`FAILED` 외 값 INSERT 시 CHECK 거부, `attempts`/`dispatched_at`/`last_failure_at` 컬럼 존재. (정적 텍스트 검증은 V2 파일 존재·`processed_event` 포함·shop-core 토큰 부재 회귀로 유지.)

### 통합(EmbeddedKafka + 005/023 패턴, `NotificationEventConsumerIntegrationTest` 확장)
- 정상 소비 → `PENDING→SENT` + 발송 1회. 일시 실패 강제 → `FAILED` 기록 + 동기 재시도 후 `원본토픽.DLQ` 발행. `.DLQ` 메시지 재처리 → 재발송 후 `SENT`. 중복(`SENT`) → 발송 추가 없음. 실제 SMTP 미사용(`mail.mode=log` `LoggingEmailSender` 또는 Fake `NotificationDispatchService` `@Primary` 오버라이드). `FakeProcessedEventStore` 상태 단언 추가.
- **`.DLQ` 재처리 트리거 메커니즘**: 재처리 컴포넌트(`DlqReprocessingService`)의 **수동 트리거 메서드를 테스트가 직접 호출**해 `.DLQ` 페이로드를 발송 경로(`EventProcessingService.process`)로 재투입한다(리스너 자동 소비는 test에서 비활성 가드라 자동 트리거되지 않으므로 — Task의 '수동 호출 가능한 컴포넌트 기본'과 정합).

### 회귀
- 기존 4개 토픽 발송 경로·005 멱등/DLQ·023 렌더링/채널 테스트 그린. 풀컨텍스트 `test`가 SMTP 접속·`.DLQ` 자동 소비·스케줄러 동작을 유발하지 않음(가드 확인).

---

## 6. 트레이드오프

- **잔여 이중 발송(단일 노드)**: "전송 성공 → `SENT` 결과기록 커밋 직전 크래시" 윈도우는 단일 TX와 **구조적으로 동일**하게 남는다. 본 Task는 이를 축소하지 않으며(목적은 long-transaction 제거+durable audit), 재방문 시 `FAILED`/`PENDING`을 재발송 대상으로 두므로 같은 이메일이 한 번 더 갈 수 있다. 최종 dedup 차단자는 `processed_event` UNIQUE + 터미널 `SENT`.
- **다중 노드 동시 dispatch 노출↑(정직한 악화)**: 단일 TX는 INSERT UNIQUE 경합이 dispatch를 직렬화했으나, post-commit은 `PENDING`을 dispatch 전에 커밋하고 SMTP 동안 락을 안 잡으므로 리밸런스 중 두 노드가 동시에 dispatch할 창이 새로 열린다. 재claim 원자 가드는 **lost update**(둘 다 dispatch 안 함)는 막지만, "A가 dispatch 중 B가 PENDING 재claim"의 동시 dispatch는 **완전 직렬화하지 못한다**(리스/lease는 long-transaction 재발 → 범위 밖). 현 배포는 단일 브로커·단일 노드(architecture §8)라 실질 노출 없음.
- **`FAILED` 행 = audit-only의 한계**: `processed_event`는 페이로드를 보관하지 않으므로 `FAILED` 행만으로는 재발송 불가. 재처리 소스는 페이로드를 가진 `.DLQ` 토픽뿐 → `.DLQ` 메시지 보존(retention)에 재처리 가능성이 종속된다. `FAILED` 행은 실패 사유·시도 횟수·시각의 관측 용도로만 쓴다.
- **개명 churn**: `PROCESSED→SENT` 개명은 V2 데이터 이행 + enum/팩토리/기존 테스트 갱신을 강제한다(일회성 비용). 의미 명료성·사전 skip 불변식 정합이 그 비용을 정당화한다고 판단.
- **"exactly-once 근접"의 정직한 의미**: 진짜 exactly-once 아님. 실이득은 (a) long-transaction 제거(SMTP 동안 DB 트랜잭션/커넥션 미보유 — 본질), (b) 터미널 `SENT` 기반 재발송 억제(단일 TX `PROCESSED` 커밋과 parity, 개선 아님), (c) durable 실패 audit + 의도적 `.DLQ` 재처리. 더 강한 보장(트랜잭셔널 메시징/2PC/리스 직렬화)은 범위 밖.

# 024. notification post-commit 발송 분리(exactly-once 근접) + 발송 상태머신/이력(V2) + DLQ 재처리

> 출처: `023`(발송)이 범위 밖으로 미룬 발송 신뢰성(**long-transaction 제거** + durable 발송 상태/audit) + backlog `009`(발송 이력/DLQ 추적). (구 025 → 024로 번호 하향 — Redis dedup Task 삭제 결정, `docs/plans/revisions/backend/notification-dedup-store-redis-vs-db-decision-revision-1.md`.)
> **다중 노드 신뢰성 트랙(정직한 위치)**: 리밸런스↑ → 재배달↑ 상황에서 본 Task의 실이득은 **블로킹 SMTP 동안 DB 트랜잭션/커넥션을 보유하지 않음** + **발송 결과의 durable audit/재처리**다. 이중 발송 자체는 본 Task로 **줄지 않으며**(단일 노드 윈도우 동일, cross-node는 오히려 노출↑ — Goal 박스), 최종 dedup 차단자는 여전히 `processed_event` UNIQUE + 터미널 `SENT`다. Redis dedup보다 우선하는 이유도 "윈도우 축소"가 아니라 위 두 실이득에 있다(revision §다중 노드 관점).

## Target
notification

---

## Goal
`023`의 **claim + dispatch 단일 트랜잭션**(`EventProcessingTransactionHelper.claimAndDispatch`)이 갖는 **long-transaction** 트레이드오프를 구조적으로 제거하고, 발송 결과를 durable하게 남긴다.
- **long-transaction(본 Task가 실제로 푸는 문제)**: 블로킹 SMTP 발송이 DB 트랜잭션 안에서 일어나 트랜잭션·커넥션을 전송 시간만큼 보유한다(023 Context "at-least-once" 명시 인지 사항). post-commit 분리로 SMTP가 트랜잭션 밖으로 나간다.
- **이중 발송(본 Task가 푸는 문제가 아님 — 명시)**: "전송 성공 → 결과 기록 직전 크래시" 윈도우는 단일 TX와 동일하게 남고, cross-node(리밸런스) 동시 dispatch는 오히려 노출이 늘 수 있다(아래 박스). 본 Task의 목적은 윈도우 축소가 아니라 long-transaction 제거 + durable audit/재처리다.

이를 위해:
- **post-commit 발송 분리**: 멱등 claim(`PENDING`)을 **먼저 커밋**한 뒤, **트랜잭션 밖에서** dispatch(렌더링+SMTP)하고, 결과를 별도 짧은 트랜잭션으로 `SENT`/`FAILED` 기록한다. → 블로킹 I/O 동안 DB 트랜잭션을 보유하지 않는다.
- **발송 상태머신**: `PENDING → SENT | FAILED`(FAILED는 재처리 시 `PENDING`으로 환원). 사전 멱등 skip을 **터미널 성공(`SENT`)에만** 적용해, 비터미널(`PENDING`/`FAILED`)은 재배달 시 재발송 대상이 되게 한다.
- **발송 이력/추적(notification V2 Flyway 마이그레이션)**: 발송 결과·실패 사유·시도 횟수를 durable하게 남겨 audit + DLQ 재처리 경로를 제공한다(backlog 009 승격).
- **DLQ 재처리 경로**: Kafka 재시도가 소진돼 `원본토픽.DLQ`로 빠진 메시지(페이로드 보유)를 **프로그램/배치로 발송 경로에 재투입**한다(외부 관리 API는 미노출 — 아래 Authorization 참조). `processed_event`의 `FAILED` 행은 재처리 소스가 아니라 audit이다(페이로드 미보관 — Requirements 참조).

> **"exactly-once 근접"의 정의(완전 보장 아님 — 명확화).** 본 Task는 진짜 exactly-once를 보장하지 **않는다**. 실제로 얻는 것은: **(a) long-transaction 제거**(SMTP 동안 DB 트랜잭션/커넥션 미보유 — 가장 분명하고 본질적인 이득), **(b) 터미널 `SENT` 기반 재발송 억제**(SENT 커밋 후 재배달은 사전 skip — 단, 이는 단일 TX의 `PROCESSED` 커밋도 이미 하던 것으로 **개선이 아니라 parity**), **(c) durable한 실패 audit + 의도적 재처리**.
> **잔여 이중 발송(정직한 한계).** 단일 노드: "전송 성공 → 결과 기록 커밋 직전 크래시" 윈도우는 단일 TX와 구조적으로 동일하게 남는다. **다중 노드(악화 가능)**: 단일 TX는 INSERT UNIQUE 경합이 dispatch를 직렬화해 cross-node 동시 발송을 막았으나, post-commit은 `PENDING`을 dispatch 전에 커밋하고 SMTP 동안 락을 잡지 않으므로 리밸런스 중 두 노드가 동시에 dispatch할 창이 새로 열린다. 본 Task는 이를 **재claim 원자 가드로 bound**(lost update 방지)하되 **완전 직렬화는 하지 않는다**(SMTP 동안 락/리스 보유는 long-transaction 재발 → 범위 밖). 최종 dedup 차단자는 `processed_event` UNIQUE + 터미널 `SENT`다. 현 배포는 단일 브로커·단일 노드(architecture §8)라 이 창은 실질 노출이 없다.

> 023의 단일 트랜잭션을 바꾸는 **구조 변경**이라 결합도가 가장 높다. CircuitBreaker(`025`)·Redis dedup(보류)과 분리한다.

---

## Context
- **선행(구현 완료 전제)**
  - `005`: notification Consumer 골격 + 멱등(`processed_event` UNIQUE(`event_id`)) + 재시도/DLQ(`DefaultErrorHandler` + `DeadLetterPublishingRecoverer`, 원본토픽`.DLQ`) + 발송 추상화. `AckMode.RECORD`.
  - `023`: 실제 이메일 발송 — `NotificationDispatchService` 단일 구현 `EmailNotificationDispatchService`(렌더링 + `EmailSender.send`), `EmailSender` 어댑터 2종(`LoggingEmailSender` 기본 / `JavaMailEmailSender`), `order-cancelled` 구독 신설. 4개 토픽 모두 발송 연결됨.
- **현 구조(본 Task가 바꾸는 지점) — `EventProcessingService` / `EventProcessingTransactionHelper`**
  - `process`: `existsByEventId`로 **무조건 사전 skip**(`[DUPLICATE]`) → 미존재 시 `transactionHelper.claimAndDispatch` 호출 → `DataIntegrityViolationException`만 흡수(경합 `[DUPLICATE]`).
  - `claimAndDispatch`: **단일 `@Transactional`** — `processedEventRepository.save(ProcessedEvent.processed(...))` + `flush`(claim, status=`PROCESSED`) → `dispatchService.dispatch`(렌더링 + 블로킹 SMTP) → 실패 시 `NotificationException` 던져 **트랜잭션 전체 롤백**(claim 동반 롤백) → 컨테이너 재시도 → 소진 시 DLQ.
- **현 도메인 자산(이미 깔린 forward-looking 이음매)**
  - `ProcessedEvent`에 `status`(`ProcessingStatus`)·`failureReason` 컬럼이 **이미 존재**하고 `failed(eventId, type, reason)` 팩토리도 있으나 **현재 미사용**(claim이 항상 `PROCESSED`로 낙관적 기록, 실패 시 통째 롤백되어 `FAILED` 행이 남지 않음). 본 Task가 이 이음매를 실제 상태머신으로 활성화한다.
  - V1 `processed_event` CHECK는 `status IN ('PROCESSED','FAILED')`만 허용 → **`PENDING` 추가에 V2 마이그레이션 필요**(V1은 체크섬 보호 — 수정 금지).
  - `ProcessedEventRepository`: `existsByEventId`만 존재.
- **이벤트 계약(변경 없음 — event-contract-rule)**: 본 Task는 **소비 측 내부 신뢰성** 변경이다. `event-catalog.md`/`architecture.md` §5·토픽·페이로드·notification DTO 미러를 **변경하지 않는다**. shop-core 역조회 금지(자족 페이로드만 — 023 계승).
- **재시도/DLQ 골격(005 재사용, 무변경)**: `KafkaConsumerConfig`의 `DefaultErrorHandler`(FixedBackOff + `NonRetryableNotificationException` 비재시도) + `DeadLetterPublishingRecoverer`(`원본토픽.DLQ`)를 **재설계하지 않는다**. listener가 예외를 던지면 재시도/DLQ가 그대로 동작한다. 본 Task는 메시지 재배달 계층이 아니라 **DB 측 상태 전이/기록**과 **그 위의 재처리**를 더한다.
- **가상스레드 대비(CLAUDE.md)**: 블로킹 SMTP I/O는 `EmailSender` 어댑터(Infra 경계)에 격리 유지. post-commit 분리로 블로킹 I/O가 DB 트랜잭션 경계 **밖**으로 나가 트랜잭션 보유 시간이 짧아진다. `ThreadLocal` 직접 사용 금지.

## Authorization / 공개 표면
> 본 Task는 **신규 REST/View 엔드포인트가 없다**(Kafka 소비 → 백그라운드 발송/재처리). api-authorization-rule 엔드포인트 권한 항목은 **해당 없음**.
- **DLQ 재처리 트리거는 외부 API로 노출하지 않는다(결정).** notification은 023과 동일하게 **공개 동기 표면이 없는** 백그라운드 서비스로 유지한다. 재처리는 **프로그램/배치(내부 컴포넌트)** 경로로만 제공한다(가드된 스케줄러 또는 수동 호출 — 아래 Requirements). 관리자용 화면/REST 트리거는 **범위 밖**(필요 시 별도 Task에서 api-authorization-rule 적용해 도입).
- 외부로 나가는 표면은 023과 동일하게 **이메일 발송**뿐이다. 수신자·본문 정책(자족 페이로드, 민감정보 금지)은 023을 그대로 계승한다(본 Task는 발송 내용이 아니라 발송 신뢰성만 바꾼다).

## Requirements
- **post-commit 발송 분리(claim 커밋 → dispatch → 결과 기록)**
  - `process`를 3단계로 재구성한다:
    1. **사전 skip**: 동일 `eventId`가 **터미널(`SENT`)** 로 이미 존재하면 즉시 `[DUPLICATE]` skip. (비터미널 `PENDING`/`FAILED`는 skip하지 않고 재발송 단계로 진행 — 컨테이너 동기 재시도/재배달/재처리 허용.)
    2. **claim(PENDING) — 두 경로의 race 가드가 다름(중요)**: `PENDING` 행을 **자체 짧은 트랜잭션**으로 확정하고 **커밋**한다(블로킹 SMTP 이전).
       - **신규 이벤트(INSERT)**: UNIQUE insert. 동시 최초 처리 경합은 005와 동일하게 **트랜잭션 경계 밖에서 `DataIntegrityViolationException` 흡수**(`[DUPLICATE]`). ← 이 가드는 **INSERT 경로에만** 유효하다.
       - **비터미널 재방문(UPDATE = 재claim)**: 이미 행이 있으므로 INSERT가 아니라 UPDATE다 → **`DataIntegrityViolationException`이 발생하지 않는다**(위 흡수 가드가 못 막음). 따라서 재claim은 **원자적 조건부 전이**로 한다: `UPDATE ... SET status='PENDING', attempts=attempts+1 WHERE event_id=? AND status<>'SENT'`의 **affected-rows 판정**(또는 낙관적 `@Version` / `SELECT ... FOR UPDATE`). **affected-rows=0이면 다른 워커가 선점(또는 이미 `SENT`)** → 발송하지 않고 종료. 정확한 메커니즘은 plan 택1하되 "**한 행을 동시에 두 워커가 재claim해 둘 다 dispatch하지 않을 것**"(lost update 방지)을 불변식으로 둔다.
       - **한계(명시)**: 재claim 가드는 lost update를 막지만, SMTP 동안 락을 보유하지 않으므로(=long-transaction 회피의 대가) 리밸런스 중 "A가 dispatch 진행 중, B가 PENDING을 재claim" 동시 dispatch를 **완전히 직렬화하지는 못한다**(리스/lease는 범위 밖 — Goal 박스). 단일 노드 배포에선 발생하지 않는다.
    3. **dispatch(트랜잭션 밖) → 결과 기록(별도 짧은 트랜잭션)**: `dispatchService.dispatch`를 **DB 트랜잭션 없이** 호출 → 성공 시 `SENT`, 실패 시 `FAILED`(+사유)로 **별도 트랜잭션 기록**(별도 TX이므로 재전파해도 롤백되지 않음) 후 예외를 **재전파**(`NotificationException`/`NonRetryableNotificationException`)해 005의 재시도/DLQ로 합류시킨다.
  - **재시도 의미(용어 정확화)**: 예외 재전파 시 `DefaultErrorHandler`는 **컨테이너 내 동기 재호출(in-memory re-seek)**로 `process`를 다시 부른다(오프셋 이동·재배달 아님). 매 재호출은 사전 skip(비터미널 통과) → **재claim(조건부 UPDATE)** → 재dispatch. 진짜 재배달(오프셋 미커밋 후 re-poll)은 리밸런스/재기동 시에만 일어나며 같은 경로를 탄다.
  - **post-commit 메커니즘**: 단일 `process` 흐름 안에서 **순차 호출 분리**(claim TX 협력 빈 → 트랜잭션 밖 dispatch → 결과기록 TX 협력 빈)를 기본으로 한다. `@TransactionalEventListener(AFTER_COMMIT)` 등 대안은 plan이 비교·확정하되, **dispatch가 어떤 DB 트랜잭션 경계에도 들지 않을 것**을 불변식으로 둔다.
  - **자기호출 프록시 우회 주의(005 계승)**: 트랜잭션 경계(claim/결과기록)는 `process`와 **다른 빈/메서드**여야 프록시가 적용되고 경합 예외를 경계 밖에서 흡수할 수 있다(현 `EventProcessingTransactionHelper` 분리 사유와 동일).
- **발송 상태머신 — `processed_event` 상태 확장(신규 테이블 대신 확장 — 결정)**
  - 별도 `send_history` 테이블을 신설하지 **않고**, 이미 `status`/`failureReason`/`failed()` 이음매가 있는 `processed_event`를 **상태머신으로 확장**한다(이벤트당 1행, UNIQUE(`event_id`) 권위 재사용 — 신규 테이블은 event_id 권위 중복·조인만 늘리는 YAGNI). 상태: **`PENDING`(claim, 미발송) → `SENT`(발송 성공, 터미널) | `FAILED`(발송 실패, 재처리 대기)**.
    - **명명 결정**: 023까지 터미널 성공을 `PROCESSED`로 썼다. 본 Task는 의미를 분명히 하기 위해 터미널 성공을 **`SENT`로 명명**한다(상태머신 `PENDING→SENT/FAILED`와 일치). `PROCESSED`→`SENT` 전환은 **V2 마이그레이션에서 기존 행 데이터 이행 + CHECK 갱신**으로 처리하고, enum/팩토리/관련 테스트(`EventProcessingServiceTransactionTest` 등)를 함께 갱신한다. (대안: `PROCESSED`를 터미널 성공으로 그대로 재사용 — churn은 적으나 의미 혼동. plan이 최종 택1하되 **택1 근거를 문서화**한다.)
  - `ProcessedEvent`에 상태 전이 메서드(예: `pending()`/`markSent()`/`markFailed(reason)`/재claim)와 추적 필드를 추가한다: **시도 횟수**(예: `attempts`), **발송 시각**(`dispatchedAt`), **마지막 실패 시각/사유**. 정확한 컬럼 집합은 plan 확정(과도한 컬럼 금지 — audit/재처리에 필요한 최소).
- **V2 Flyway 마이그레이션(신규)**
  - `notification/src/main/resources/db/migration/V2__*.sql`: ① `status` CHECK 갱신 — V1의 **무명 inline CHECK 제약**(`status varchar CHECK (status IN ('PROCESSED','FAILED'))` → Postgres 자동 생성명 `processed_event_status_check`)을 **DROP 후 새 술어로 ADD**(`PENDING` 추가 + 명명 결정 시 `SENT`). ② 명명 결정이 `SENT`면 기존 행 **`UPDATE ... SET status='SENT' WHERE status='PROCESSED'`** 데이터 이행. ③ 추적 컬럼 추가. V1은 **수정 금지**(체크섬 보호 — V1 헤더 불변 규칙). DDL은 마이그레이션이 소유(ADR-007).
  - **정합 검증의 한계 인지**: Hibernate validate는 컬럼/타입/nullability만 보고 **CHECK 술어·enum 문자열 값은 검증하지 않는다**(enum=varchar 매핑). 따라서 `SENT`/`PENDING` 문자열 정합은 validate가 아니라 **`FlywayMigrationScriptTest`(V1→V2 적용 + 기존 행 이행 + CHECK 위반 거부)로 검증**한다.
- **DLQ 재처리 경로(`원본토픽.DLQ` 소비/redrive — 외부 API 미노출)**
  - **재처리 소스는 `.DLQ` 토픽이다(`processed_event` FAILED 행이 아니다).** 이유: 재발송에는 **수신자·주문·금액 등 페이로드 전체**가 필요한데, `processed_event`는 `event_id`/`event_type`/`status`/`failure_reason`(+추적 필드)만 저장하고 **페이로드를 보관하지 않는다** → FAILED 행만으로는 렌더링/재발송이 **불가능**하다. 반면 `DeadLetterPublishingRecoverer`가 `원본토픽.DLQ`로 보낸 메시지에는 **원본 페이로드가 그대로 있다**.
  - **재처리 컴포넌트**: `원본토픽.DLQ`를 (수동 트리거/배치로) 소비해 원래 발송 경로(`EventProcessingService.process` 또는 dispatch)로 재투입한다. **재발송은 멱등** — 사전 skip(터미널 `SENT`)과 재claim 가드가 그대로 보호하고, 성공 시 `SENT`. 구현 형태는 plan 확정(① `.DLQ` 전용 리스너를 수동/배치 활성, 또는 ② `.DLQ` 메시지를 원본 토픽으로 re-publish하는 redrive).
  - **이중 발송 가드가 불필요해짐(설계 단순화)**: `.DLQ` 토픽 메시지는 **정의상 Kafka 재시도 소진 후**(컨테이너가 더 이상 다루지 않음)에만 적재되므로, "아직 재시도 중인 행"과의 경합이 **원천적으로 없다**. 따라서 FAILED-행 스캔 방식이 요구하던 `dead_lettered`/age/attempts 가드를 **두지 않는다**(자초한 race 제거).
  - **`processed_event`의 `FAILED` 행 = 순수 audit**: 재처리 소스가 아니라 발송 결과 추적/관측 용도다(실패 사유·시도 횟수·시각).
  - 트리거: **수동 호출 가능한 컴포넌트**를 기본으로 하고, 가드된 스케줄러/리스너 자동 활성은 **선택(plan 확정)**. 채택 시 022 선례대로 **테스트 비활성 가드**(풀컨텍스트 `test`에서 미동작·`.DLQ` 자동 소비 안 함)를 둔다. 외부 REST/View 트리거는 도입하지 않는다.
- **실패 분류(005/023 재사용, 무변경)**: 일시 SMTP 오류 → `NotificationException`(retryable) → 재시도 → DLQ. 영구 실패(주소 형식·렌더 불가) → `NonRetryableNotificationException` → 재시도 없이 DLQ. 본 Task는 분류 체계를 바꾸지 않고, 결과 기록(`FAILED`+사유)만 추가한다.
- **프로파일 가드(005/023 계승)**: 신규/수정 빈(재구성된 `process` 협력 빈, 재처리 컴포넌트, 스케줄러)은 `@Profile("kafkatest | !test")` 가드를 유지한다. 풀컨텍스트 `test`에서 외부 SMTP 접속·재처리 스케줄러 동작을 유발하지 않는다.

## Constraints
- **이벤트 계약 무변경**: `event-catalog.md`/`architecture.md` §5·토픽·페이로드·notification DTO 미러 변경 없음. 신규 토픽/이벤트/필드 추가 없음.
- **shop-core 역조회 금지**: 발송/재처리에 필요한 모든 값은 페이로드/`processed_event`에서만 취한다. shop-core 코드/DB/REST 미참조.
- **005/023 골격 보존**: 메시지 재배달 계층(`DefaultErrorHandler` + DLQ + 재시도 설정 + 비재시도 예외)·Consumer 위임·`EmailSender`/렌더러(023)·실패 분류 체계를 **재설계하지 않는다**. 변경은 **`process`의 트랜잭션 분리(post-commit) + 상태머신/추적(V2) + 재처리 컴포넌트**에 한정. Consumer는 Repository 직접 호출·예외 흡수 금지(무변경).
- **멱등 권위 유지**: dedup 권위는 `processed_event` UNIQUE(`event_id`) 단일(DB). Redis dedup 도입 **금지**(보류 — revision 문서). 사전 skip을 **터미널 `SENT`에만** 적용하는 변경 외에 새 멱등 메커니즘을 만들지 않는다.
- **exactly-once "근접" 범위 한정**: 완전 보장 아님(Goal의 정의 참조). "결과 기록 직전 크래시" 잔여 윈도우 수용. 더 강한 보장(트랜잭셔널 메시징/2PC 등)은 범위 밖.
- **범위 밖(명시)**: Resilience4j SMTP CircuitBreaker(`025`), Redis dedup(보류), SMS/푸시 채널, 관리자 재처리 화면/REST, 발송 내용/렌더링 변경(023 고정), 신규 토픽/이벤트. 메시지 재시도 프레임워크 교체.
- **프로파일/테스트 오염 금지(verification-gate)**: 신규/수정 빈 `@Profile` 가드 유지. 풀컨텍스트 `test`가 SMTP 접속·스케줄러 동작·외부 I/O를 유발하지 않음.
- **가상스레드 대비**: 블로킹 SMTP는 `EmailSender` 어댑터(Infra 경계)에 격리, post-commit으로 DB 트랜잭션 밖에서 호출. `ThreadLocal` 직접 사용 금지.

## Files
> 정확한 경로/빈 배선/컬럼 집합은 plan 확정. notification 단일 레포 내부 작업.
- (수정) `notification/service/EventProcessingService.java` — `process` 3단계 재구성: 사전 skip(터미널 `SENT`만), claim(`PENDING`) 커밋, **트랜잭션 밖 dispatch** 후 결과 기록(`SENT`/`FAILED`) + 예외 재전파. 경합(`DataIntegrityViolationException`) 흡수 유지.
- (수정/분리) `notification/service/EventProcessingTransactionHelper.java` — 단일 `claimAndDispatch` 트랜잭션을 **claim TX**(PENDING 커밋)와 **결과기록 TX**(SENT/FAILED)로 분리. dispatch는 **이 빈 밖**(트랜잭션 밖)에서 호출.
- (수정) `notification/domain/ProcessedEvent.java` — `PENDING` 상태 + 전이 메서드(`pending`/`markSent`/`markFailed`/재claim) + 추적 필드(`attempts`/`dispatchedAt`/`lastFailureAt` 등 최소 집합).
- (수정) `notification/domain/ProcessingStatus.java` — `PENDING` 추가(+ 명명 결정 시 `PROCESSED`→`SENT`).
- (수정) `notification/repository/ProcessedEventRepository.java` — 터미널 여부 조회(`existsByEventIdAndStatus`/`findByEventId`), **재claim용 원자적 조건부 전이**(`@Modifying UPDATE ... WHERE event_id=? AND status<>'SENT'` 반환 행 수 / 낙관적 `@Version` / `SELECT ... FOR UPDATE`).
- (신규) `notification/src/main/resources/db/migration/V2__*.sql` — V1 무명 CHECK DROP 후 `PENDING`(+`SENT` 명명 결정) 술어로 재ADD, 기존 행 `PROCESSED→SENT` 이행(택1 시) + 추적 컬럼. **V1 수정 금지.**
- (신규) DLQ 재처리 컴포넌트(`notification/service` 또는 별도 패키지) — **`원본토픽.DLQ` 소비/redrive**로 페이로드 보유 메시지를 발송 경로에 재투입(프로그램/배치). 별도 윈도우 가드 불필요(.DLQ=소진 후). `@Profile("kafkatest | !test")` + 테스트 비활성(자동 소비 안 함). 스케줄러/자동 리스너는 선택.
- (수정 — 직렬화 1줄, 구현 중 사용자 승인) `notification/common/config/KafkaConsumerConfig.java` — `dlqProducerFactory` value 직렬화 `JsonSerializer → StringSerializer`. 사유: 메인 컨슈머가 value를 String(JSON)으로 받으므로 DLPR도 String으로 발행해야 `.DLQ`가 원본과 동일한 단일 JSON을 보존(이중 인코딩 방지). 023까지 `.DLQ` 소비자가 없어 잠복했던 버그를 024 재처리가 노출. **재배달 라우팅/재시도/비재시도 예외 동작은 무변경**(직렬화 포맷만 교정). `DefaultErrorHandler`/DLQ 라우팅/재시도 설정·`DeadLetterPublishingRecoverer` 자체는 그대로, `dead_lettered` 행 마킹 훅은 `.DLQ` 소비 방식 채택으로 미도입.
- (재사용·무변경) `NotificationEventConsumer`(4종 구독), `EmailNotificationDispatchService`/`NotificationMessageRenderer`/`EmailSender` 어댑터(023), `NotificationException`/`NonRetryableNotificationException`/`ProcessingError`, 메시지 재배달 골격(`DefaultErrorHandler`/DLQ/재시도 설정).
- (변경 없음) `docs/event-catalog.md`/`docs/architecture.md` §5, notification DTO 미러, Redis dedup(미적용).

## Layer Contract (notification 레이어 규칙)
| 항목 | 위치 | 규칙 |
|---|---|---|
| 토픽 구독 | `consumer`(무변경) | 4종 `@KafkaListener` → `EventProcessingService.process` 위임만. 로직·Repository 직접 호출·예외 흡수 금지 |
| 멱등·오케스트레이션 | `service`(`EventProcessingService`) | 사전 skip(터미널 `SENT`만) → claim 커밋 → post-commit dispatch → 결과 기록. 최초 INSERT 경합은 `DataIntegrityViolationException` 흡수, **비터미널 재claim은 원자적 조건부 UPDATE**(`WHERE status<>'SENT'`)로 보호 |
| 트랜잭션 경계 | `service`(`EventProcessingTransactionHelper`) | claim TX / 결과기록 TX **분리**. dispatch는 트랜잭션 밖. self-invocation 우회 위해 별도 빈 유지 |
| 발송 오케스트레이션 | `service`(023 `EmailNotificationDispatchService`, 무변경) | 렌더링 + `EmailSender.send`. retryable/non-retryable 분류 |
| 발송 상태/이력 | `domain`/`repository`(`processed_event` 확장) | `PENDING→SENT/FAILED` + 추적 필드(audit 전용). UNIQUE(`event_id`) 권위. Entity 비노출. **페이로드 미보관** |
| DLQ 재처리 | `service`(신규 컴포넌트) | **`원본토픽.DLQ` 소비/redrive**(페이로드 보유)로 발송 경로 재투입. 멱등(SENT skip+재claim 가드). `.DLQ`=소진 후라 별도 윈도우 가드 불필요. 외부 API 미노출 |
| 이메일 전송 | `EmailSender` 어댑터(023, 무변경) | 블로킹 SMTP 격리(Infra). post-commit으로 DB 트랜잭션 밖에서 호출. `mail.mode` 택1 |

## Behavior Contract (동기 응답 표면 없음)
- 본 Task는 REST/View 동기 응답이 없다. 동작은 **토픽 소비 → 상태 전이 + 이메일 발송**으로 관측된다.
- **정상 1건**: 소비 → `PENDING` claim 커밋 → (트랜잭션 밖) `EmailSender.send` 성공 → `SENT` 기록 커밋 → 오프셋 커밋(`[EMAIL_DISPATCHED]`/`SENT` 로그). 이메일 1건.
- **일시 전송 실패**: `PENDING` 커밋됨 → dispatch가 `NotificationException` → `FAILED`(사유) 기록 커밋(별도 TX) → 예외 재전파 → **컨테이너 동기 재시도(in-memory re-seek)**. 매 재호출은 사전 skip이 `FAILED`(비터미널) 통과 → **재claim(조건부 UPDATE)** → 재발송. 소진 시 `원본토픽.DLQ`로 발행 + `FAILED` 행 audit 잔존.
- **영구 실패**: `NonRetryableNotificationException` → `FAILED` 기록 → 재시도 없이 `.DLQ`.
- **중복/경합**: 동일 `eventId`가 이미 `SENT`면 발송 0건(`[DUPLICATE]`). 최초 claim INSERT 경합은 `DataIntegrityViolationException` 흡수(`[DUPLICATE]`). 비터미널 재claim 경합은 조건부 UPDATE affected-rows=0으로 선점자에게 양보.
- **DLQ 재처리**: `원본토픽.DLQ` 메시지(페이로드 보유, 재시도 소진 후)를 재처리 컴포넌트가 발송 경로로 재투입 → 성공 시 `FAILED→SENT`. 이미 `SENT`면 사전 skip으로 무동작.
- **관측성**: claim/발송 성공/실패/재처리/DLQ가 `eventId`·타입·상태와 함께 로깅된다(005/023 로그 계승).

## Acceptance Criteria
- dispatch(렌더링+SMTP)가 **DB 트랜잭션 밖에서** 실행된다(claim TX가 SMTP 동안 열려 있지 않음 — long-transaction 제거 검증).
- `processed_event`가 **상태머신**(`PENDING→SENT/FAILED`)으로 동작한다: 정상 시 `PENDING`→`SENT`, 일시/영구 실패 시 `FAILED`(사유 기록), 재처리/재배달 성공 시 `FAILED/PENDING`→`SENT`.
- 사전 멱등 skip이 **터미널 `SENT`에만** 적용되어, `PENDING`/`FAILED` 이벤트가 재시도/재처리에서 재발송 대상이 된다. **비터미널 재claim은 원자적 조건부 전이**로, 동시 재claim 시 한 워커만 dispatch한다(lost update 없음). 동일 `eventId` `SENT` 재수신 시 **발송 0건**.
- V2 마이그레이션이 V1을 수정하지 않고 `PENDING`(+명명 결정 반영) 및 추적 컬럼을 추가하며, 기존 `PROCESSED` 행 이행·CHECK 위반 거부가 `FlywayMigrationScriptTest`로 검증된다(문자열 값 정합은 Hibernate validate가 아닌 이 테스트가 담보).
- 일시 전송 실패 → 동기 재시도 소진 시 `원본토픽.DLQ` 발행 + `FAILED` 행 audit 잔존. 영구 실패 → 재시도 없이 `.DLQ`. **메시지 재배달 골격(005) 회귀 없음.**
- DLQ 재처리 컴포넌트가 **`.DLQ` 토픽 메시지(페이로드 보유)** 를 발송 경로로 재투입해 **멱등 재발송**한다(성공 시 `SENT`). `.DLQ`는 소진 후만 적재되므로 별도 윈도우 가드 없이 동시 발송이 발생하지 않는다.
- 신규/수정 빈이 `@Profile` 가드되어 **풀컨텍스트 `test`에서 외부 SMTP 접속·재처리 스케줄러 동작을 유발하지 않는다**. `event-catalog.md`/§5·shop-core 미참조. **005/023 회귀 없음, 풀컨텍스트 test 그린.**

## Test
- **단위(Mockito)**: `process` 3단계 — 사전 skip이 `SENT`에만 동작(`PENDING`/`FAILED`는 통과), claim→dispatch→결과기록 호출 순서/횟수, dispatch 예외 시 `FAILED` 기록 후 예외 재전파. Fake/Mock `NotificationDispatchService`·`ProcessedEventRepository`(`FakeProcessedEventStore` 패턴 재사용).
- **단위(Mockito)**: `ProcessedEvent` 상태 전이(`pending`/`markSent`/`markFailed`/재claim) + 추적 필드 갱신 단언.
- **단위/슬라이스**: **재claim 원자성** — 비터미널 행에 대한 조건부 전이가 affected-rows로 선점 판정(이미 `SENT`면 0행 → 미발송), 동시 재claim 모사 시 한 워커만 dispatch(lost update 없음).
- **단위(Mockito)**: DLQ 재처리 컴포넌트 — **`.DLQ` 메시지(페이로드 보유)** 를 발송 경로로 재투입, 재발송 성공 시 `SENT`, 이미 `SENT`면 사전 skip으로 무동작(별도 윈도우 가드 없음).
- **트랜잭션/post-commit(슬라이스, `EventProcessingServiceTransactionTest` 확장)**: dispatch가 **트랜잭션 밖**에서 호출됨(claim 커밋 후) 검증 — dispatch 실패 시 **`PENDING` claim은 커밋 유지**(단일 TX 시절 "claim 롤백"과 달라짐), `FAILED` 기록됨, 재방문 시 재claim 가능. 최초 claim 경합(`DataIntegrityViolationException`) 흡수 유지. Fake `EmailSender`로 발송 횟수(이중 발송 없음) 검증.
- **마이그레이션**: `FlywayMigrationScriptTest`에 V2 반영(Testcontainers PG에서 V1→V2 적용, 기존 `PROCESSED→SENT` 이행, **`PENDING`/`SENT` 외 값 CHECK 거부** 검증).
- **통합(EmbeddedKafka + Testcontainers PG, 005/023 패턴)**: 정상 소비 → `PENDING`→`SENT` 1행 + 발송 1회. 일시 실패 강제 → `FAILED` 기록 + 동기 재시도 후 `원본토픽.DLQ` 발행. 컨테이너 재호출 → 재claim·재발송(터미널 skip이 `SENT`만). `.DLQ` 메시지 재처리 → 재발송 후 `SENT`. 중복(`SENT`) → 발송 추가 없음. **실제 SMTP 미사용**(`mail.mode=log` `LoggingEmailSender` 또는 Fake `EmailSender`/`NotificationDispatchService` 오버라이드).
- **회귀**: 기존 4개 토픽 발송 경로·005 멱등/DLQ·023 렌더링/채널 테스트 그린. 풀컨텍스트 `test`가 SMTP 접속·스케줄러 동작을 시도하지 않음(가드 확인).

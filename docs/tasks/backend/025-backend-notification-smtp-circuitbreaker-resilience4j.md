# 025. notification SMTP 발송 CircuitBreaker(Resilience4j) — 외부 의존 회복탄력성

> 출처: `023`(발송)이 범위 밖으로 미룬 회복탄력성. post-commit(`024`)과 분리. (구 026 → 025로 번호 하향 — Redis dedup Task 삭제 결정, `docs/plans/revisions/backend/notification-dedup-store-redis-vs-db-decision-revision-1.md`.)

## Target
notification

---

## Goal
`023`의 아웃바운드 SMTP 호출(`JavaMailEmailSender.send`) 둘레에 Resilience4j **CircuitBreaker**를 적용해, SMTP 장애 시 **fail-fast**(매 메시지마다 죽은 서버를 두드리지 않고 SMTP 타임아웃만큼 대기하지도 않음)로 전환하고, 그 실패를 **Kafka 재시도/DLQ로 흘려보낸다**.
- 적용 지점은 **아웃바운드 `JavaMailEmailSender.send`(실 SMTP I/O) 둘레만**. `LoggingEmailSender`(소켓 없음)·발송 오케스트레이터(`EmailNotificationDispatchService`)·Consumer에는 적용하지 않는다.
- **Kafka `DefaultErrorHandler`+DLQ(메시지 재배달)는 대체하지 않는다** — 대체 시 DLQ·at-least-once 안전망 소실(023 Context 명시).

> Resilience4j는 **재시도 프레임워크 교체가 아니다.** 메시지 재시도는 005 Kafka 골격이 그대로 담당하고, 본 Task는 **외부 SMTP 의존 격리(CircuitBreaker)만** 더한다. Retry/RateLimiter/Bulkhead 등 다른 Resilience4j 모듈은 도입하지 않는다.

---

## Context
- **선행(구현 완료 전제)**
  - `005`: Consumer 골격 + 멱등 + 재시도/DLQ(`KafkaConsumerConfig`의 `DefaultErrorHandler` FixedBackOff(max-attempts 3) + `DeadLetterPublishingRecoverer` `원본토픽.DLQ` + `addNotRetryableExceptions(NonRetryableNotificationException)`).
  - `023`: `EmailSender` 포트 + 어댑터 2종 — `LoggingEmailSender`(기본, `mail.mode=log`, 소켓 없음) / `JavaMailEmailSender`(`mail.mode=smtp`, 실 SMTP). **`JavaMailEmailSender`가 이미 `MailException`을 분류**한다: 일시적 전송 실패(연결/타임아웃) → `NotificationException(retryable=true)`, 인증 실패·수신자 주소 형식 거절 → `NonRetryableNotificationException`(즉시 DLQ).
  - `024`(**완료**): dispatch가 **post-commit으로 분리됨** — `EventProcessingService.process`가 claim(PENDING) 커밋 후 **DB 트랜잭션 밖에서** `dispatch`(렌더링+SMTP)를 호출하고, 실패 시 `recordFailed`(FAILED 기록) 후 예외를 재전파해 Kafka 재시도/DLQ로 합류한다. **SMTP 호출이 더 이상 DB 트랜잭션 안에 있지 않다.**
- **본 Task의 가치(024 이후 정정)**: 스켈레톤은 "in-tx 잔존 시 장시간 retry로 트랜잭션을 길게 보유하는 것 방지"를 동기로 들었으나, **024가 dispatch를 트랜잭션 밖으로 빼서 long-transaction 우려는 이미 해소**됐다. 그래서 본 Task의 fail-fast 가치는 **순수하게 외부 의존 격리**다: SMTP 서버가 죽었을 때 (1) 매 메시지가 SMTP 타임아웃만큼 블로킹되는 것을 막고(스레드/처리 지연 폭증 방지), (2) 죽은 서버를 반복 두드리지 않으며, (3) 그 실패를 빠르게 Kafka 재시도/DLQ로 흘려 024의 `FAILED` 상태머신·`.DLQ` 재처리 경로에 합류시킨다(복구 후 재발송 가능).
- **분류 재사용(023, 변경 없음)**: 일시 SMTP 오류는 `NotificationException(retryable)`, 영구 오류는 `NonRetryableNotificationException`. 본 Task는 이 체계를 바꾸지 않고, **CircuitBreaker open 상태의 fail-fast(`CallNotPermittedException`)를 `NotificationException(retryable)`로 변환**해 동일 경로에 합류시킨다.
- **기본값 log 모드**: `notification.mail.mode` 기본 `log` → `LoggingEmailSender`만 활성(`JavaMailEmailSender` 미생성). 풀컨텍스트 `test`도 log 모드 → **CB가 감싸는 SMTP 경로 자체가 없다**(소켓·CB 미관여). CB는 `smtp` 모드에서만 의미를 가진다.
- **이벤트 계약/Outbox/멱등 무관**: 본 Task는 아웃바운드 SMTP 호출 경계 한정. 이벤트 계약·`processed_event`·신규 마이그레이션과 무관.

## Authorization / 공개 표면
> 본 Task는 **신규 REST/View 엔드포인트가 없다**. api-authorization-rule 해당 없음.
- 외부로 나가는 표면은 023과 동일하게 **이메일 발송**뿐이다. CB는 그 발송 호출의 회복탄력성만 더할 뿐 발송 내용·수신자 정책을 바꾸지 않는다.

## Requirements
- **Resilience4j 의존 추가**
  - `notification/build.gradle`에 Resilience4j CircuitBreaker 의존을 추가한다. 버전은 Spring Boot BOM이 관리하지 않으므로 **Resilience4j BOM 또는 명시 버전**으로 고정(plan 확정).
- **CircuitBreaker 적용 — 아웃바운드 SMTP 호출 한정 (데코레이터 권장)**
  - CB는 **분류된 `NotificationException`을 던지는 `EmailSender.send` 경계**(= `JavaMailEmailSender.send`)에만 적용한다. **적용 방식은 plan이 택1하되, (b) 데코레이터를 권장 기본안으로 둔다**:
    - **(b, 권장) 데코레이터** `ResilientEmailSender implements EmailSender`가 `JavaMailEmailSender`를 감싸 `CircuitBreaker.decorateRunnable`로 호출하고 **`catch (CallNotPermittedException)`만** 잡아 변환. `JavaMailEmailSender`는 순수 SMTP 어댑터로 유지(composition). 코어 `resilience4j-circuitbreaker` + 프로파일/조건 가드된 수동 `CircuitBreakerRegistry`만 쓰면 자동설정 부작용도 없다(아래 #테스트 가드).
    - (a, 대안) `@CircuitBreaker(name="smtp", fallbackMethod=...)` 애너테이션(`resilience4j-spring-boot3`+AOP). **단, fallback은 OPEN의 `CallNotPermittedException`뿐 아니라 보호 메서드가 던지는 모든 예외에 호출되므로**, fallback이 **`CallNotPermittedException`만 retryable로 변환하고 그 외(`NotificationException`/`NonRetryableNotificationException`)는 원본 그대로 재전파**해야 한다(미준수 시 아래 변환 불변식 위반).
  - **CB 경계 불변식(중요 — 조용한 무동작 방지)**: CB는 **raw `mailSender.send`(`MailException`을 던지는 내부 호출) 둘레에 두지 않는다.** record/ignore 타입은 경계에서 **실제로 던져지는 타입(`NotificationException`/`NonRetryableNotificationException`)과 일치**해야 한다 — 경계와 타입이 어긋나면 CB가 아무 실패도 집계하지 못해 영영 OPEN되지 않는다(기능 조용히 사망).
  - **빈 유일성 불변식(023 계승 — `NoUniqueBeanDefinitionException` 방지)**: 데코레이터 채택 시 **smtp 모드의 활성 `EmailSender`는 `ResilientEmailSender` 하나**여야 한다. `JavaMailEmailSender`를 `EmailSender` 빈으로 동시 노출하지 않는다 — 내부 위임체(`@Qualifier`/non-`@Component` 협력자)로 강등해 `EmailNotificationDispatchService`의 `EmailSender` 주입이 모호해지지 않게 한다.
  - **적용 제외 불변식**: CB는 `LoggingEmailSender`(소켓 없음)·`EmailNotificationDispatchService`(오케스트레이터)·Consumer를 **감싸지 않는다**. `smtp` 모드에서 활성 EmailSender만 CB 경로를 탄다.
- **open 상태 fail-fast → retryable 변환 (변환 불변식 — 분류 보존)**
  - CB가 OPEN이면 SMTP를 시도하지 않고 `CallNotPermittedException`으로 즉시 실패한다. **`CallNotPermittedException`만** `NotificationException(retryable=true)`로 변환해 던진다(`NonRetryable` 아님 — 서킷이 복구될 수 있으므로 재시도 경로 유지). → `EventProcessingService`가 `recordFailed`(FAILED) 후 재전파 → `DefaultErrorHandler` 재시도(역시 fail-fast) → 소진 시 `원본토픽.DLQ`(024 계승, 무변경).
  - **불변식(중요)**: 변환은 **오직 `CallNotPermittedException`에만** 적용한다. CLOSED/HALF_OPEN에서 실 SMTP가 던진 `NotificationException`/`NonRetryableNotificationException`은 **분류 그대로 재전파**한다. 특히 **`NonRetryableNotificationException`(주소/인증)을 retryable로 둔갑시키지 않는다** — 그러면 즉시 DLQ여야 할 영구 오류가 무의미하게 재시도되어 아래 Behavior Contract("NonRetryable → 즉시 DLQ")·서킷 ignore 정책과 모순된다. (애너테이션 방식의 fallback이 모든 예외에 호출되는 점을 특히 주의 — 위 적용 방식 (a) 단서.)
- **서킷 개방 판정 입력 분리(중요)**: CB는 **서버 건강 신호인 일시적 실패만** 집계해 열어야 한다.
  - **record(서킷 카운트)**: 일시 SMTP 실패 = `NotificationException`(retryable, `JavaMailEmailSender`가 던지는 connect/timeout 류).
  - **ignore(서킷 무영향)**: **`NonRetryableNotificationException`**(인증 실패·주소 형식 등 per-message 영구 오류)는 서버 건강과 무관하므로 서킷을 열지 않는다. `NonRetryableNotificationException`이 `NotificationException`의 하위 타입이므로, `recordExceptions=[NotificationException]` + `ignoreExceptions=[NonRetryableNotificationException]`로 하위 타입을 제외(ignore 우선). 영구 오류는 기존대로 즉시 DLQ.
- **Resilience4j Retry 미도입(결정)**: 짧은 Retry조차 두지 않는다. **메시지 재시도는 005 Kafka `DefaultErrorHandler` 단일 담당**(이중 재시도 회피). RateLimiter/Bulkhead/TimeLimiter도 범위 밖.
- **설정**: `application.yml`에 `resilience4j.circuitbreaker.instances.smtp.*`(sliding-window-type/size, failure-rate-threshold, minimum-number-of-calls, wait-duration-in-open-state, permitted-number-of-calls-in-half-open-state 등) + 환경변수 오버라이드. 합리적 기본값은 plan이 확정(과도한 튜닝 금지).
  - **윈도우 집계 특성 인지**: CB `smtp` 인스턴스는 **전역 공유**다 — 4개 `@KafkaListener` 컨테이너(스레드)와 **각 메시지의 Kafka 인메모리 재시도(max-attempts=3)** 가 모두 같은 sliding window에 기록된다(의도: SMTP 서버 전역 건강 신호). 따라서 **한 메시지가 최대 3회 실패를 기여**하므로, `minimum-number-of-calls`/`failure-rate-threshold`를 너무 낮게 잡으면 단일 메시지로 조기 OPEN될 수 있다 — 임계값은 이를 감안해 정한다.
- **관측성**: CB 상태 전이(CLOSED→OPEN→HALF_OPEN→CLOSED)와 open 시 fail-fast를 **실 SMTP 실패와 구분되는 로그**로 남긴다(`eventId`/타입과 함께, 005/023/024 로그 패턴 계승).
- **프로파일/테스트 가드**: CB 빈/설정이 풀컨텍스트 `test`(기본 log 모드) 기동을 오염하거나 외부 SMTP 접속을 유발하지 않게 한다. `JavaMailEmailSender`의 기존 가드(`@Profile("kafkatest | !test")` + `@ConditionalOnProperty(mail.mode=smtp)`)를 데코레이터/래핑이 깨지 않도록 유지.
  - **자동설정 부작용 주의**: `resilience4j-spring-boot3`를 쓰면 `CircuitBreakerRegistry`·AOP aspect 빈이 **모든 프로파일(포함 `test`)에서 자동 생성**된다. 권장안인 **데코레이터 + 코어 라이브러리 + 프로파일/조건 가드된 수동 `CircuitBreakerRegistry`** 를 쓰면 자동설정 자체를 피해 `test`(Kafka/JPA 자동설정 제외 최소 컨텍스트) 오염 위험이 없다. 애너테이션/자동설정 방식을 택하면 **풀컨텍스트 `test` 기동 무오염**을 AC 검증 항목으로 둔다.

## Constraints
- **메시지 재배달 계층 대체 금지**: `DefaultErrorHandler` + DLQ + FixedBackOff + `addNotRetryableExceptions`(005) 무변경. CB는 **아웃바운드 SMTP 호출 격리에 한정**하고 Kafka 재시도/DLQ를 대신하지 않는다.
- **023 분류·024 post-commit/상태머신 보존**: `JavaMailEmailSender`의 retryable/non-retryable 분류, `EmailNotificationDispatchService` 렌더링+위임, `EventProcessingService`의 claim→트랜잭션밖 dispatch→recordSent/recordFailed 골격을 재설계하지 않는다. 변경은 **SMTP 호출 둘레 CB + open→retryable 변환 + 설정**에 한정.
- **이벤트 계약 무변경, 신규 마이그레이션 없음**: `event-catalog.md`/§5·`processed_event`(V2)·notification DTO 미러 불변.
- **멱등/dedup 무관**: Redis dedup 도입 금지(보류 — revision 문서). `processed_event` UNIQUE 권위 그대로.
- **범위 밖(명시)**: post-commit/발송 이력/상태머신·`.DLQ` 재처리(024 완료), Redis dedup(보류), SMS/푸시, 실 SMTP 계정 발급/운영 연동, 관리자 표면, Resilience4j Retry/RateLimiter/Bulkhead/TimeLimiter.
- **프로파일/테스트 오염 금지(verification-gate)**: 풀컨텍스트 `test`(log 모드)가 CB로 인해 외부 SMTP 접속·기동 실패를 유발하지 않음. CB 단위/통합 검증은 `JavaMailSender`를 Mock/Fake로 실패 주입(실제 SMTP 미접속).
- **가상스레드 대비**: 블로킹 SMTP는 `JavaMailEmailSender`(Infra 경계)에 격리 유지. CB 데코레이터/래핑도 `ThreadLocal` 직접 사용 금지.

## Files
> 정확한 경로/방식(애너테이션 vs 데코레이터)/설정값은 plan 확정. notification 단일 레포.
- (수정) `notification/build.gradle` — Resilience4j CircuitBreaker 의존(+BOM/버전 고정).
- (신규, 권장) `notification/service/ResilientEmailSender.java` — `EmailSender` 데코레이터가 `JavaMailEmailSender`(내부 위임체) 래핑, CB 적용 + **`CallNotPermittedException`만** `NotificationException(retryable)` 변환(그 외 분류 예외 원본 재전파). **smtp 모드 활성 `EmailSender` 빈은 이것 하나**(JavaMailEmailSender는 `EmailSender` 빈으로 미노출). (대안: `JavaMailEmailSender`에 `@CircuitBreaker`+fallback — fallback이 비-CallNotPermitted 원본 재전파 필수.)
- (수정) `notification/service/JavaMailEmailSender.java` — 데코레이터 채택 시 `EmailSender` 빈 노출 제거(내부 위임체로 강등, `@Qualifier`/non-`@Component`). 분류 로직(retryable/non-retryable)은 그대로.
- (신규) `notification/.../config` — (데코레이터+코어 채택 시) 프로파일/조건 가드된 `CircuitBreakerRegistry` 빈. (자동설정 방식이면 불필요.)
- (수정) `notification/src/main/resources/application.yml` — `resilience4j.circuitbreaker.instances.smtp.*` + 환경변수 오버라이드. (필요 시 `@ConfigurationProperties`로 옵션 노출 — YAGNI 범위.)
- (재사용·무변경) `common/exception/NotificationException`·`NonRetryableNotificationException`, `service/EmailNotificationDispatchService`·`EmailSender`·`LoggingEmailSender`, `common/config/KafkaConsumerConfig`(재배달 골격), `service/EventProcessingService`·`EventProcessingTransactionHelper`(024 post-commit/상태머신).
- (변경 없음) `docs/event-catalog.md`/`docs/architecture.md` §5, notification DTO 미러, Flyway 마이그레이션(신규 없음), Redis dedup(미적용).

## Layer Contract (notification 레이어 규칙)
| 항목 | 위치 | 규칙 |
|---|---|---|
| 발송 오케스트레이션 | `service`(`EmailNotificationDispatchService`, 무변경) | 렌더링 + `EmailSender.send` 위임. CB 미부착 |
| 이메일 전송(CB 적용) | `ResilientEmailSender` 데코레이터(권장)가 `JavaMailEmailSender` 래핑, Infra 경계 | **`EmailSender.send` 경계(분류 예외를 던지는 지점)에만 CB**. **`CallNotPermittedException`만** `NotificationException(retryable)`로 변환, 그 외 분류 예외는 원본 재전파. smtp 모드 활성 EmailSender 빈은 **하나**(빈 유일성). `mail.mode=smtp` 한정 |
| 로그 어댑터 | `LoggingEmailSender`(기본/test, 무변경) | 소켓 없음 → CB 미적용 |
| 실패 분류 | `service`(023, 무변경) | 일시 SMTP → `NotificationException`(record), 영구 → `NonRetryableNotificationException`(ignore — 서킷 무영향) |
| 메시지 재배달 | `common/config/KafkaConsumerConfig`(005, 무변경) | `DefaultErrorHandler`+DLQ가 유일 재시도. CB가 대체하지 않음 |
| 발송 상태머신 | `service`/`domain`(024, 무변경) | dispatch는 트랜잭션 밖. CB fail-fast도 `recordFailed`(FAILED) 경유 후 재전파 |

## Behavior Contract (동기 응답 표면 없음)
- 본 Task는 REST/View 동기 응답이 없다. 동작은 **SMTP 호출의 CB 상태 전이 + 발송/실패**로 관측된다.
- **정상(CB CLOSED)**: dispatch → `JavaMailEmailSender.send`(CB 통과) → SMTP 성공 → 024 `recordSent`(SENT). 이메일 1건.
- **SMTP 일시 실패 누적**: 각 실패가 `NotificationException(retryable)` → CB가 record → failure-rate 임계 초과 → **CB OPEN**. (임계 전 실패는 기존대로 재시도/DLQ.)
- **CB OPEN(fail-fast)**: 후속 `send`가 SMTP를 **시도하지 않고** `CallNotPermittedException` → `NotificationException(retryable)` 변환 → 024 `recordFailed`(FAILED) → 재전파 → `DefaultErrorHandler` 재시도(역시 fail-fast, SMTP 미접속이라 즉시) → 소진 시 `원본토픽.DLQ`. (블로킹 없음.)
- **복구**: `wait-duration-in-open-state` 경과 → **HALF_OPEN** → 허용 호출 시도 → 성공률 회복 시 **CLOSED**(정상 발송 재개). OPEN 기간 `.DLQ`에 쌓인 이벤트는 **024 `.DLQ` 재처리**로 재발송 가능.
- **영구 실패(주소/인증, `NonRetryable`)**: CB가 **ignore**(서킷 무영향) → 기존대로 재시도 없이 `.DLQ` 직행.
- **log 모드(기본/test)**: `JavaMailEmailSender` 미생성 → CB 경로 없음 → 소켓·CB 미관여.
- **관측성**: CB 상태 전이·open fail-fast가 실 SMTP 실패와 구분돼 로깅된다.

## Acceptance Criteria
- `JavaMailEmailSender`의 실 SMTP 호출에 CircuitBreaker가 적용되고, **일시 SMTP 실패 누적 시 OPEN → 후속 호출 fail-fast(SMTP 미접속)** 된다.
- OPEN 상태 fail-fast(`CallNotPermittedException`)가 **`NotificationException(retryable)`로 변환**되어 Kafka 재시도/DLQ로 합류한다(`.DLQ` 라우팅 확인). `wait-duration` 경과 후 **HALF_OPEN → 복구 시 CLOSED**.
- **`NonRetryableNotificationException`(주소/인증)은 서킷을 열지 않고(ignore) 분류도 보존되어 즉시 DLQ로 간다.** 변환은 **`CallNotPermittedException`에만** 적용되고, 실 SMTP가 던진 `NotificationException`/`NonRetryableNotificationException`은 **원본 그대로 재전파**된다(영구 오류가 retryable로 둔갑하지 않음).
- 데코레이터 채택 시 **smtp 모드의 `EmailSender` 빈이 정확히 하나**여서 `EmailNotificationDispatchService` 주입이 모호하지 않다(`NoUniqueBeanDefinitionException` 없음, 023 불변식 유지).
- Resilience4j Retry/기타 모듈 미도입(Kafka 재시도와 이중화 없음). **005 메시지 재배달·023 분류·024 post-commit/상태머신 회귀 없음.**
- CB는 `LoggingEmailSender`·오케스트레이터·Consumer·raw `mailSender.send`를 감싸지 않는다(분류 예외를 던지는 `EmailSender.send` 경계 한정).
- 풀컨텍스트 `test`(기본 log 모드)에서 CB가 외부 SMTP 접속·기동 오염을 유발하지 않는다. 신규 마이그레이션/이벤트 계약 변경 없음.

## Test
- **단위(Mockito + Resilience4j 직접 구성)**: 작은 sliding window의 `CircuitBreaker`로 결정적 전이 검증 — `JavaMailSender` Mock이 일시 실패(`MailSendException` connect/timeout) 주입 → 임계 초과 → **OPEN**; OPEN 상태 `send` 호출이 `CallNotPermittedException` → **`NotificationException(retryable=true)`로 변환**되어 전파됨을 단언; `wait-duration` 경과 모사 → HALF_OPEN → 성공 주입 → CLOSED. **`NonRetryableNotificationException`(주소/인증) 주입 시 서킷 카운트 미증가(OPEN 안 됨)** 단언(record/ignore 분리 검증).
- **단위**: 변환 계층 — (1) OPEN fail-fast(`CallNotPermittedException`)가 `NonRetryable`이 아니라 **retryable** `NotificationException`으로 변환됨(재시도 경로), **(2) CLOSED/HALF_OPEN에서 실 SMTP가 던진 `NonRetryableNotificationException`은 변환 없이 원본 그대로 전파됨**(영구 오류 분류 보존 → 즉시 DLQ) 단언. 두 케이스로 "CallNotPermitted만 변환" 불변식을 박제.
- **배선 검증(testing-rule §컨텍스트/배선)**: `mail.mode=smtp` 컨텍스트에서 `EmailSender` 빈이 **`ResilientEmailSender` 하나**로 해석되고 `JavaMailEmailSender`가 `EmailSender` 빈으로 중복 노출되지 않음을 단언(`NoUniqueBeanDefinitionException` 회귀 차단). `mail.mode=log`(기본)에서는 `LoggingEmailSender`만 활성·CB 경로 없음.
- **통합(EmbeddedKafka, `mail.mode=smtp` 컨텍스트, `JavaMailSender` Mock/Fake로 실패 주입)**: SMTP 일시 실패 누적 → CB OPEN → 후속 메시지 fail-fast → `원본토픽.DLQ` 라우팅 + 024 `FAILED` 기록 확인. **실제 SMTP 미접속**(JavaMailSender Mock). 복구(성공 주입) 후 정상 발송 재개. — 이 통합 테스트는 `smtp` 모드 전용 컨텍스트로 격리(풀 `test`는 log 모드 유지).
- **회귀**: 기존 발송 경로·005 멱등/DLQ·023 분류·024 상태머신/`.DLQ` 재처리 테스트 그린. **풀컨텍스트 `test`(log 모드)가 CB로 인해 SMTP 접속·기동 오염을 유발하지 않음**(가드 확인).

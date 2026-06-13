# 025 notification SMTP 발송 CircuitBreaker(Resilience4j) plan

> `JavaMailEmailSender.send`(실 SMTP I/O)를 감싸는 `EmailSender` 데코레이터 `ResilientEmailSender`에 Resilience4j-core CircuitBreaker를 적용해, SMTP 장애 시 fail-fast(`CallNotPermittedException`)로 전환하고 그것만 `NotificationException(retryable)`로 변환해 005 Kafka 재시도/DLQ·024 상태머신 경로로 합류시킨다. record=`NotificationException`/ignore=`NonRetryableNotificationException`로 서버 건강 신호만 서킷에 집계한다. 자동설정을 피해(코어+프로파일/조건 가드 수동 Registry) 풀컨텍스트 `test`(log 모드) 무오염. 023 분류·024 post-commit/상태머신·005 재배달·이벤트 계약·마이그레이션 전부 무변경.

---

## 1. 설계 방식 및 이유

본 Task는 005 재배달 계층·023 분류·024 post-commit/상태머신을 그대로 두고, **`JavaMailEmailSender.send`(분류 예외를 던지는 `EmailSender.send` 경계) 둘레에 CircuitBreaker + `CallNotPermittedException`→retryable 변환 + 설정**만 더한다. Task가 plan에 위임한 5개 택1을 아래와 같이 확정한다. 5개 불변식(① CallNotPermitted만 변환 ② 경계=`EmailSender.send`(분류 예외 지점) ③ smtp 모드 EmailSender 빈 유일성 ④ record·ignore 분리 ⑤ 풀test CB 무관여)을 모두 만족하도록 상호 정합되게 골랐다.

### (a) 적용 방식 — 데코레이터 vs 애너테이션

| 결정 | **데코레이터 `ResilientEmailSender implements EmailSender`** (Task 권장안 채택) |
|---|---|
| 근거 | 데코레이터는 본 Task의 5개 불변식을 **구조적으로** 충족한다. (1) **경계 정합**(불변식 ②): 데코레이터가 위임하는 메서드는 `JavaMailEmailSender.send`(이미 `MailException`을 `NotificationException`/`NonRetryableNotificationException`으로 분류한 뒤 던지는 지점)이므로, CB가 감싸는 호출의 실패 타입 = 경계에서 실제로 던져지는 분류 타입으로 자동 일치한다. raw `mailSender.send`(`MailException`)를 감싸는 실수가 원천 차단된다. (2) **CallNotPermitted만 변환**(불변식 ①): `decorateRunnable` 호출을 `try/catch (CallNotPermittedException)`로 감싸 OPEN fail-fast만 잡아 변환하고, CLOSED/HALF_OPEN에서 위임체가 던진 분류 예외(`NotificationException`/`NonRetryableNotificationException`)는 catch 대상이 아니므로 **원본 그대로 자연 전파**된다. 애너테이션 방식의 fallback은 *모든* 예외에 호출되어(Task §적용방식 a 단서) "fallback에서 비-CallNotPermitted를 원본 재전파"를 수기로 보장해야 하는 함정이 있는데, 데코레이터는 이 함정 자체가 없다. (3) **빈 유일성**(불변식 ③): 데코레이터가 유일한 `@Component EmailSender`가 되고 `JavaMailEmailSender`는 비-빈 협력자로 강등하면 smtp 모드 EmailSender 빈은 정확히 하나가 된다. (4) **자동설정 회피**(불변식 ⑤): 데코레이터는 AOP/aspect가 불필요하므로 `resilience4j-spring-boot3` 자동설정 없이 코어 라이브러리 + 수동 Registry만으로 동작 → 풀컨텍스트 `test`에 CB 빈이 새지 않는다. |

### (b) 의존 — 코어 vs spring-boot3 / 버전 고정

| 결정 | **`io.github.resilience4j:resilience4j-circuitbreaker` 코어** + **`resilience4j-bom`으로 버전 고정** (spring-boot3 스타터·AOP·자동설정 미도입) |
|---|---|
| 근거 | 데코레이터(a) 채택 시 필요한 것은 `CircuitBreakerRegistry`/`CircuitBreaker`/`CircuitBreakerConfig`/`CallNotPermittedException` API뿐이다. `resilience4j-spring-boot3`는 `CircuitBreakerAutoConfiguration`이 **모든 프로파일(`test` 포함)에서** `CircuitBreakerRegistry` + `resilience4j.*` 바인딩 + AOP aspect 빈을 자동 생성하므로(불변식 ⑤ 위협), 코어만 도입하고 Registry 빈을 **프로파일/조건 가드된 수동 빈**으로 직접 만든다. 버전: Spring Boot BOM이 Resilience4j를 관리하지 않으므로(현 `build.gradle`에 resilience4j 부재 확인) `dependencyManagement { imports { mavenBom "io.github.resilience4j:resilience4j-bom:<버전>" } }`로 BOM 임포트 후 모듈은 버전 없이 선언한다(향후 다른 r4j 모듈 추가 시 버전 정합 유지). 버전 핀은 implementor가 Java 21/Spring Boot 3.5.x 호환 안정 버전으로 확정(과도한 추측 금지). |

### (c) CircuitBreakerRegistry / 설정 바인딩 + 프로파일·조건 가드

| 결정 | **수동 `CircuitBreakerRegistry` 빈 + `@ConfigurationProperties`로 바인딩한 전용 properties 레코드** (자동 `resilience4j.*` 바인딩 미사용), `@Profile("kafkatest | !test")` + `@ConditionalOnProperty(notification.mail.mode=smtp)` 가드 |
|---|---|
| 근거 | 코어 라이브러리(b)는 `resilience4j.*` yml 자동 바인딩을 제공하지 않으므로(그건 spring-boot3 스타터 기능), 설정은 **자체 properties 레코드**(`notification.resilience.smtp.*`)로 노출해 수동 Registry 빈이 `CircuitBreakerConfig`를 조립한다. 가드는 **CB 빈이 의미를 갖는 smtp 모드에서만**, 그리고 `JavaMailEmailSender`/`LoggingEmailSender`와 동일한 `@Profile("kafkatest | !test")`로 둔다 → 풀컨텍스트 `test`(기본 log 모드 + JPA/Kafka 자동설정 제외)에서 Registry/데코레이터/properties 빈이 모두 미생성(불변식 ⑤). `MailConfig`(`@EnableConfigurationProperties(MailProperties.class)`) 선례를 따라 신규 `ResilienceConfig`가 properties 활성 + Registry 빈을 보유한다. **Registry는 인메모리 in-process**(가상스레드 대비: `ThreadLocal` 직접 사용 없음 — r4j Registry는 내부 상태를 `AtomicReference` 기반으로 관리). |

> 정합 메모: `notification.resilience.smtp.*` 키는 자동설정 회피를 위해 의도적으로 r4j 표준 `resilience4j.circuitbreaker.instances.smtp.*` 네임스페이스를 **쓰지 않는다**(Task §설정의 `resilience4j.*` 예시는 자동설정 방식 기준 — 데코레이터+코어 채택에 맞춰 자체 네임스페이스로 정정). 환경변수 오버라이드는 동일하게 적용된다(예: `NOTIFICATION_RESILIENCE_SMTP_FAILURE_RATE`).

### (d) record/ignore + CallNotPermitted만 변환의 코드 위치

| 결정 | `CircuitBreakerConfig`에 **`recordExceptions(NotificationException.class)` + `ignoreExceptions(NonRetryableNotificationException.class)`**, 변환은 **`ResilientEmailSender.send`의 `catch (CallNotPermittedException)`** 단 한 곳 |
|---|---|
| 근거 | `NonRetryableNotificationException extends NotificationException`(상속 확인)이므로 ignore가 record의 하위 타입을 제외(ignore 우선 평가) → 일시 SMTP 실패(`NotificationException`, retryable)만 서킷 카운트(record), 영구 오류(주소/인증, `NonRetryable`)는 서킷 무영향(ignore)(불변식 ④). 성공 호출은 자동 success 집계. 변환은 OPEN 상태에서 r4j가 던지는 `CallNotPermittedException`에만 적용 — 데코레이터 `send`에서 `decorateRunnable`을 실행하고 `catch (CallNotPermittedException e) { throw new NotificationException("SMTP 서킷 OPEN — fail-fast, 재시도 가능", e, true); }`. CLOSED/HALF_OPEN에서 위임체가 던진 분류 예외는 이 catch에 걸리지 않아 **원본 그대로 전파**(불변식 ①). `NonRetryable`이 retryable로 둔갑하지 않으므로 즉시 DLQ 보존. |

### (e) CB 설정 기본값 (전역 공유 + 인메모리 재시도 집계 감안)

| 항목 | 기본값 | 근거 |
|---|---|---|
| `sliding-window-type` | `COUNT_BASED` | 트래픽이 균일하지 않은 알림 워크로드에서 시간 기반보다 호출 N건 기반이 결정적·예측 가능. 단위 테스트도 작은 COUNT 윈도우로 전이를 결정적으로 검증 가능. |
| `sliding-window-size` | `20` | 4개 `@KafkaListener` 컨테이너 + 각 메시지 최대 3회 인메모리 재시도(max-attempts=3)가 **전역 공유 윈도우**에 기록됨을 감안. 너무 작으면 단일 메시지 3회 실패로 조기 OPEN. |
| `minimum-number-of-calls` | `10` | 한 메시지가 최대 3회 기여하므로, **단일 메시지의 3회 실패만으로 OPEN되지 않도록** 최소 호출 수를 충분히(≥3회 초과) 둔다. SMTP 서버가 정말 죽으면 여러 메시지가 빠르게 누적되어 10건은 금방 채워진다. |
| `failure-rate-threshold` | `50`(%) | 절반 이상 실패 시 OPEN. 전역 SMTP 건강 신호로 합리적·표준값. 과도한 민감/둔감 회피. |
| `wait-duration-in-open-state` | `30s` | OPEN 유지 시간. 죽은 SMTP를 30초 동안 두드리지 않다가 HALF_OPEN으로 탐침. .DLQ에 쌓인 건은 024 `.DLQ` 재처리로 복구. 과도한 튜닝 금지(운영 시 환경변수 조정). |
| `permitted-number-of-calls-in-half-open-state` | `3` | HALF_OPEN에서 탐침 호출 수. 소수 성공/실패로 CLOSED/재OPEN 판정. |
| (자동 전이) `automatic-transition-from-open-to-half-open-enabled` | `false`(기본) | 백그라운드 스케줄러 스레드 생성을 피한다(가상스레드/스레드 관리 단순). 다음 호출 시점에 시간 경과로 HALF_OPEN 전이(호출 구동) — 알림은 메시지 구동이라 충분. |

> 모든 값은 `notification.resilience.smtp.*`로 노출 + 환경변수 오버라이드. **과도한 튜닝/추가 파라미터(slow-call, retry 등) 도입 금지**(Task 범위).

---

## 2. 구성 요소

> notification 단일 레포. 경로 `notification/src/main/java/com/shop/notification/...`. 레이어: 발송 어댑터/데코레이터는 `service`, 설정은 `common/config`(현 `KafkaConsumerConfig`/`MailConfig` 위치 계승).

### 수정 파일

| 파일 | 책임 변경 |
|---|---|
| `build.gradle` | `dependencyManagement` 블록에 `resilience4j-bom` import 추가 + `implementation 'io.github.resilience4j:resilience4j-circuitbreaker'`(코어, 버전 BOM 위임). `resilience4j-spring-boot3`·AOP 미추가. 기존 의존/테스트 의존 무변경. |
| `service/JavaMailEmailSender.java` | **`EmailSender` 빈 노출 제거 → 내부 위임체로 강등**(불변식 ③). `@Component` 제거(또는 `@Component`+`@Qualifier`로 비-기본 빈화). 분류 로직(`MailAuthenticationException`/`MailSendException`→retryable/non-retryable)·`@Profile("kafkatest \| !test")`+`@ConditionalOnProperty(mail.mode=smtp)` 가드는 **무변경 보존**. `ResilientEmailSender`가 생성자 주입으로 이 위임체를 받는다. |
| `src/main/resources/application.yml` | `notification.resilience.smtp.*`(sliding-window-type/size, failure-rate-threshold, minimum-number-of-calls, wait-duration-in-open-state, permitted-number-of-calls-in-half-open-state) + 환경변수 오버라이드 추가. 기존 `mail.*`/`kafka.*`/`dlq.*` 무변경. |

### 신규 파일

| 파일 | 책임 |
|---|---|
| `service/ResilientEmailSender.java` | **smtp 모드의 유일한 `@Component EmailSender`**(불변식 ③). 생성자로 `JavaMailEmailSender`(위임체)와 `CircuitBreaker`(name="smtp", Registry에서 획득)를 주입. `send(to,subject,body)`는 `circuitBreaker.executeRunnable(() -> delegate.send(...))`(또는 `decorateRunnable` 후 run)로 위임 호출, **`catch (CallNotPermittedException)`만** 잡아 `NotificationException(retryable=true)`로 변환·재전파(불변식 ①). 그 외 예외(위임체의 분류 예외 포함)는 catch 없이 통과(불변식 ①). `@Profile("kafkatest \| !test")`+`@ConditionalOnProperty(mail.mode=smtp)` 가드(`JavaMailEmailSender`와 동일 — log 모드/풀test 미생성, 불변식 ⑤). CB 상태 전이·open fail-fast 로그(`eventId`는 인자에 없으므로 to/subject + 서킷 상태로, 실 SMTP 실패와 구분되는 `[SMTP_CB_OPEN]` 류 마커). 블로킹 SMTP는 위임체에 격리, `ThreadLocal` 직접 사용 없음(가상스레드 대비). |
| `common/config/ResilienceConfig.java` | `@Configuration` + `@Profile("kafkatest \| !test")` + `@ConditionalOnProperty(mail.mode=smtp)` + `@EnableConfigurationProperties(ResilienceProperties.class)`. **수동 `CircuitBreakerRegistry` 빈**(b/c): properties로 `CircuitBreakerConfig`(record/ignore + 윈도우/임계값) 조립 → `CircuitBreakerRegistry.of(config)`. **`CircuitBreaker` 빈**(name="smtp"): `registry.circuitBreaker("smtp")` + 상태 전이 이벤트 리스너 등록(`onStateTransition`→로그). 자동설정 미사용(코어). |
| `common/config/ResilienceProperties.java` | `@ConfigurationProperties("notification.resilience.smtp")` record/클래스 — slidingWindowType/Size, failureRateThreshold, minimumNumberOfCalls, waitDurationInOpenState(Duration), permittedNumberOfCallsInHalfOpenState. `MailProperties` 레코드 패턴 계승. |

### 변경 없음(재사용)

- `service/EmailSender`(포트 — 시그니처 무변경), `service/LoggingEmailSender`(소켓 없음 → CB 미적용, 불변식), `service/EmailNotificationDispatchService`(오케스트레이터 — `EmailSender` 주입만, CB 미부착), `service/NotificationMessageRenderer`.
- `common/exception/NotificationException`·`NonRetryableNotificationException`(record/ignore 타입으로 재사용 — 무변경).
- `common/config/KafkaConsumerConfig`(005 재배달 골격 — `DefaultErrorHandler`/DLQ/`addNotRetryableExceptions` 무변경), `common/config/MailConfig`/`MailProperties`.
- `service/EventProcessingService`·`EventProcessingTransactionHelper`(024 post-commit/상태머신 — `recordSent`/`recordFailed` 무변경), `service/DlqReprocessingService`.
- `docs/event-catalog.md`/`docs/architecture.md §5`, notification DTO 미러, Flyway 마이그레이션(신규 없음), Redis dedup(미적용).

---

## 3. 데이터 흐름

표기: smtp 모드 한정. `[CB]`=CircuitBreaker 통과/판정 지점. log 모드는 `JavaMailEmailSender`/`ResilientEmailSender`/CB 미생성이라 이 흐름 자체가 없다.

```
EventProcessingService.process (024, NT)
  └→ dispatchService.dispatch (023 오케스트레이터, CB 미부착)
       └→ EmailSender.send  == ResilientEmailSender.send  [CB 경계]
            └→ circuitBreaker.executeRunnable( JavaMailEmailSender.send )  ← raw mailSender.send는 위임체 내부(CB 밖)
```

### 정상 (CB CLOSED)
1. `process`(NT) → claim(PENDING) 커밋(024) → `dispatch`(NT) → `ResilientEmailSender.send`.
2. `[CB]` CLOSED → 위임체 `JavaMailEmailSender.send` 실행 → `mailSender.send` SMTP 성공 → CB success 집계.
3. `dispatch` 정상 반환 → 024 `recordSent`(SENT). 이메일 1건. CB 무전이.

### 일시 실패 누적 → OPEN
1. 각 호출에서 위임체가 connect/timeout → `NotificationException(retryable)` throw.
2. `[CB]` record(=`NotificationException`) → 실패 집계. 변환 catch 대상 아님 → **원본 그대로 전파**(불변식 ①).
3. `dispatch`가 `NotificationException` 전파 → 024 `recordFailed`(FAILED) → `process` 재전파 → 005 `DefaultErrorHandler` 동기 재시도(각 재시도도 같은 전역 윈도우에 record).
4. `minimum-number-of-calls`(10) 도달 + `failure-rate`(50%) 초과 → **CB OPEN**. (임계 전 실패는 기존대로 재시도/소진 시 DLQ — 005/024 그대로.)

### OPEN fail-fast → CallNotPermitted → retryable → 005/024 합류
1. OPEN 동안 후속 `send` → `[CB]`가 위임체를 **호출하지 않고**(SMTP 미접속, 블로킹 없음) `CallNotPermittedException` throw.
2. `ResilientEmailSender`의 `catch (CallNotPermittedException)` → `NotificationException(retryable=true)`로 변환·throw + `[SMTP_CB_OPEN]` 로그(실 SMTP 실패와 구분).
3. `dispatch`가 retryable `NotificationException` 전파 → **024 `recordFailed`(FAILED)** → `process` 재전파 → 005 `DefaultErrorHandler` 재시도(역시 OPEN이라 즉시 fail-fast) → 소진 시 **`원본토픽.DLQ`**(024/005 무변경).

### 복구 (HALF_OPEN → CLOSED)
1. `wait-duration-in-open-state`(30s) 경과 후 다음 호출 시 → **HALF_OPEN** 전이.
2. `permitted-number-of-calls-in-half-open-state`(3) 만큼 위임체 탐침 호출 → 성공률 회복 → **CLOSED**(정상 발송 재개). 실패 지속 → 재 OPEN.
3. OPEN 기간 `.DLQ`에 쌓인 이벤트는 **024 `.DLQ` 재처리**(`DlqReprocessingService` 수동 트리거)로 재발송 → `process` 멱등(SENT 사전 skip / 비터미널 재claim) 후 SENT.

### 영구 실패 (NonRetryable, ignore)
1. 위임체가 주소/인증 → `NonRetryableNotificationException` throw.
2. `[CB]` ignore(=`NonRetryableNotificationException`) → **서킷 카운트 미증가**(서버 건강 무관, 불변식 ④). 변환 catch 대상 아님 → **원본 그대로 전파**.
3. `dispatch` 전파 → 024 `recordFailed`(FAILED) → `process` 재전파 → 005 `addNotRetryableExceptions`로 **재시도 없이 즉시 `.DLQ`**(무변경).

> 합류점 요약: 본 Task는 CB OPEN fail-fast를 **retryable `NotificationException`으로 변환**해 정확히 024 `recordFailed`→재전파→005 `DefaultErrorHandler`/DLQ 경로로 흘려보낸다. 024 상태머신·005 재배달 코드는 한 줄도 바뀌지 않는다.

---

## 4. 예외 처리 전략

CB 경계(`ResilientEmailSender.send`)에서 마주치는 예외는 정확히 두 부류로, **`CallNotPermittedException`만** 변환하고 나머지는 원본 재전파한다(불변식 ①).

| 예외 (발생 위치) | CB 처리 | `ResilientEmailSender` 처리 | 하류(024/005) |
|---|---|---|---|
| `CallNotPermittedException` (OPEN, r4j가 던짐) | — (서킷이 차단) | **`catch` → `NotificationException(msg, e, retryable=true)`로 변환·throw** | 024 `recordFailed`(FAILED) → 재전파 → 005 재시도/소진 시 DLQ |
| `NotificationException` retryable (위임체 CLOSED/HALF_OPEN 실 SMTP 일시 실패) | **record**(서킷 카운트) | **catch 안 함 → 원본 그대로 전파** | 024 `recordFailed` → 재전파 → 005 재시도/DLQ |
| `NonRetryableNotificationException` (위임체 주소/인증) | **ignore**(서킷 무영향) | **catch 안 함 → 원본 그대로 전파**(분류 보존) | 024 `recordFailed` → 재전파 → 005 `addNotRetryableExceptions` 즉시 DLQ |
| 성공 | success 집계 | — | 024 `recordSent`(SENT) |

- **변환 코드 위치(단일 지점)**: `ResilientEmailSender.send`의 `catch (CallNotPermittedException)`. 다른 어떤 곳에서도 분류 예외를 변환·재분류하지 않는다. 특히 **`NonRetryableNotificationException`을 retryable로 둔갑시키지 않는다**(불변식 ① — Behavior Contract "NonRetryable → 즉시 DLQ" 보존).
- **record/ignore 위치**: `ResilienceConfig`의 `CircuitBreakerConfig` 빌더(`recordExceptions(NotificationException.class)` + `ignoreExceptions(NonRetryableNotificationException.class)`). ignore가 record 하위 타입을 제외(불변식 ④).
- **경계 정합(불변식 ②)**: CB가 감싸는 것은 `JavaMailEmailSender.send`(분류 예외를 던지는 지점)지 **raw `mailSender.send`(`MailException`)가 아니다.** raw 호출은 위임체 내부(CB 밖)에 남고, CB는 위임체가 던진 `NotificationException`/`NonRetryableNotificationException`을 record/ignore한다 → 경계 타입 = record/ignore 타입 일치 → "집계 못 해 영영 OPEN 안 됨"(조용한 사망) 방지.
- 로깅: CB 상태 전이(`onStateTransition` 리스너 → `[SMTP_CB_TRANSITION] from→to`)와 OPEN fail-fast(`[SMTP_CB_OPEN]`)를 실 SMTP 실패(`JavaMailEmailSender`의 기존 로그)와 구분되는 마커로 남긴다(005/023/024 패턴 계승).

---

## 5. 검증 방법

빌드/검증(notification 레포): `./gradlew test`(Windows: `gradlew.bat test`). 풀컨텍스트 `test` 그린 + 005/023/024 회귀 없음이 게이트. **실제 SMTP 미접속**(JavaMailSender Mock/Fake) 일관.

### 단위 — CB 전이 결정적 (Mockito + r4j 직접 구성)
`ResilientEmailSenderTest`: 작은 윈도우 `CircuitBreakerConfig`(예: slidingWindowSize=5, minimumNumberOfCalls=5, failureRate=50%, COUNT_BASED)로 `CircuitBreakerRegistry`를 **테스트 코드에서 직접 조립**(자동설정 의존 없음), `JavaMailEmailSender` Mock을 위임체로 주입한 `ResilientEmailSender`를 `new`로 생성.
- **OPEN 전이**: Mock이 일시 실패(`NotificationException(retryable)`) 주입 → 임계 호출 후 CB 상태 OPEN 단언.
- **OPEN fail-fast 변환**(불변식 ① 케이스 1): OPEN 상태 `send` → 던져진 예외가 `NotificationException` **AND `isRetryable()==true` AND `NonRetryableNotificationException`이 아님** 단언(`CallNotPermitted`→retryable). 위임체 Mock이 호출되지 않음(fail-fast, `verify(...).send(...)` no more interactions) 단언.
- **HALF_OPEN→CLOSED**: `wait-duration` 경과 모사(작은 duration + 시간 경과/`transitionToHalfOpenState()`로 결정적 유도) → 성공 주입 → CLOSED 단언, 정상 위임 호출.
- **record/ignore 분리**(불변식 ④): `NonRetryableNotificationException`(주소/인증) 주입 시 **CB 실패 카운트 미증가**(`circuitBreaker.getMetrics().getNumberOfFailedCalls()` 불변 또는 동일 횟수 주입해도 OPEN 안 됨) 단언.

### 단위 — 변환 2케이스 박제 (불변식 ①)
같은 `ResilientEmailSenderTest`에서:
- (1) OPEN fail-fast(`CallNotPermittedException`) → **retryable** `NotificationException`(위 OPEN 케이스).
- (2) **CLOSED/HALF_OPEN에서 위임체가 던진 `NonRetryableNotificationException`은 변환 없이 동일 인스턴스 그대로 전파**(`assertThat(thrown).isInstanceOf(NonRetryableNotificationException.class)`, isRetryable=false 보존). 두 케이스로 "CallNotPermitted만 변환" 불변식 고정.

### 배선 검증 (testing-rule §컨텍스트/배선, 불변식 ③·⑤)
`ApplicationContextRunner` 기반(부트 풀컨텍스트 불필요 — `MailPropertiesTest` 패턴 계승):
- **smtp 모드 빈 유일성**: `mail.mode=smtp` + 필요한 협력 빈(JavaMailSender Mock 등) 구성으로 `ResilienceConfig`+`ResilientEmailSender`+`JavaMailEmailSender`를 로드 → `context.getBean(EmailSender.class)`가 **`ResilientEmailSender` 하나**로 해석됨(`NoUniqueBeanDefinitionException` 없음), `JavaMailEmailSender`가 `EmailSender` 빈으로 중복 노출되지 않음 단언(불변식 ③, 023 계승 회귀 차단). 이 테스트는 **버그(JavaMailEmailSender가 EmailSender 빈으로 동시 노출)에서 반드시 RED**가 되도록 구성(testing-rule §"버그 있던 코드에서 실패").
- **log 모드 무관여**: `mail.mode=log`(기본)에서 `LoggingEmailSender`만 활성, `ResilientEmailSender`/`CircuitBreakerRegistry`/`ResilienceProperties` 빈 **미생성** 단언(불변식 ⑤).
- **ResilienceProperties 바인딩**: `MailPropertiesTest` 패턴으로 기본값/오버라이드 바인딩 단언(별도 경량 테스트).

### 통합 (EmbeddedKafka, smtp 모드 격리 컨텍스트, JavaMailSender Mock 실패 주입)
**smtp 모드 전용 컨텍스트 격리 방식**: `NotificationEventConsumerIntegrationTest`(log 모드, 풀 흐름)는 그대로 두고, **별도 신규 통합 테스트** `SmtpCircuitBreakerIntegrationTest`를 둔다.
- `@SpringBootTest` + `@ActiveProfiles({"test","kafkatest"})` + `@EmbeddedKafka`(원본 4토픽 + `.DLQ`) + `@TestPropertySource(properties = {"notification.mail.mode=smtp", "notification.resilience.smtp.minimum-number-of-calls=<작게>", "notification.resilience.smtp.sliding-window-size=<작게>", "notification.resilience.smtp.failure-rate-threshold=50", "notification.kafka.retry.*", "notification.dlq.suffix=.DLQ"})` → 이 컨텍스트만 smtp 모드로 띄워 `ResilientEmailSender`+CB 경로 활성화.
- **JavaMailSender는 Mock/Fake로 실패 주입**(실제 SMTP 미접속): `@TestConfiguration`에서 `@Primary @Bean JavaMailSender`를 Mockito mock으로 등록해 `send` 호출 시 `MailSendException`(connect/timeout류) throw → 위임체가 retryable `NotificationException`으로 분류 → CB가 record. (DB는 기존처럼 `FakeProcessedEventStore` + `ResourcelessTransactionManager`로 대체.)
- **시나리오**: 일시 실패 메시지 누적 → CB OPEN → 후속 메시지 fail-fast(`CallNotPermitted`→retryable) → **`원본토픽.DLQ` 라우팅**(raw `KafkaConsumer` poll로 단언, 기존 패턴) + **024 `FAILED` 기록**(FakeStore 상태 단언). 그 후 Mock을 성공으로 전환 + `wait-duration` 경과 → HALF_OPEN→CLOSED → 정상 발송 재개(`SENT`) 또는 `.DLQ` 재처리로 SENT. (시간 의존 최소화를 위해 `wait-duration`을 짧게 오버라이드.)

### 회귀 (불변식 ⑤)
- **풀컨텍스트 `test`(기본 log 모드)에서 CB 무관여**: 기존 `NotificationEventConsumerIntegrationTest`(log 모드) 및 부트 컨텍스트 테스트가 CB 빈 생성/외부 SMTP 접속/기동 실패 없이 그린. `ResilientEmailSender`/`CircuitBreakerRegistry`/`ResilienceProperties`가 log 모드·풀test에서 미생성됨을 배선 검증(위)으로 보장.
- 005 멱등/DLQ·023 분류·024 post-commit/상태머신/`.DLQ` 재처리 기존 테스트 전부 그린(코드 무변경 확인).
- 신규 마이그레이션/이벤트 계약 변경 없음 확인.

> **구현 노트(테스트 명확화 — plan-reviewer 보강)**
> - **Mock 대상 구분**: 단위(`ResilientEmailSenderTest`)는 **위임체 `JavaMailEmailSender`를 Mock**해 `NotificationException(retryable)`/`NonRetryableNotificationException`을 **직접** 던지게 한다(CB record/ignore·변환을 던지는 타입 그대로 결정적 검증). 통합(`SmtpCircuitBreakerIntegrationTest`)은 **`JavaMailSender`(raw)를 `@Primary` Mock**해 `MailSendException`을 던지게 한다(위임체 분류 로직까지 실제 경유). 두 계층의 Mock 대상을 혼동하지 말 것.
> - **HALF_OPEN 전이는 호출 구동**: `automatic-transition-from-open-to-half-open-enabled=false`(§1e)이므로 `wait-duration` 경과만으로 자동 HALF_OPEN되지 않고 **다음 `send` 호출**이 전이를 트리거한다. 단위는 `transitionToHalfOpenState()`로 결정적 유도(주석으로 "자동 전이 off → 호출 구동" 명시). 
> - **통합의 복구 단언은 폴링/await**: HALF_OPEN→CLOSED 복구는 전역 공유 CB + 4개 리스너 경합으로 타이밍 의존적이다. 통합 테스트는 복구·SENT 단언을 기존 `awaitSent`(넉넉한 await) 패턴으로 폴링하고 `wait-duration`을 짧게 오버라이드한다.

---

## 6. 트레이드오프

- **데코레이터 vs 애너테이션**: 데코레이터는 클래스 1개(+위임체 강등)를 추가하지만, fallback의 "모든 예외에 호출" 함정·자동설정 부작용·빈 모호성을 구조적으로 제거한다. 애너테이션은 코드가 짧아 보이나 5개 불변식을 수기 규율로 지켜야 해 회귀 위험이 크다(특히 NonRetryable 둔갑·풀test 오염). 데코레이터의 명시성을 택했다.
- **전역 CB 공유**: smtp 인스턴스 1개를 4개 리스너 컨테이너 + 각 메시지의 인메모리 재시도(max-attempts=3)가 공유한다 — 의도(SMTP 서버 **전역** 건강 신호)에 부합하나, **한 메시지가 최대 3회 실패를 기여**한다. `minimum-number-of-calls=10`/`failure-rate=50%`로 단일 메시지 조기 OPEN을 방지했지만, 산발적 일시 실패가 윈도우에 섞이면 임계 근처에서 민감해질 수 있다. 토픽/메시지별 분리 CB는 "전역 건강 신호"라는 본 Task 목적과 어긋나 도입하지 않는다.
- **코어 vs spring-boot3 자동설정**: 코어+수동 Registry는 yml 자동 바인딩·Actuator 헬스 통합·`@CircuitBreaker` AOP 편의를 포기한다(이 Task 범위 밖이라 손실 아님). 대신 `test` 오염 위험 제거 + 의존 최소화를 얻는다. 향후 메트릭/헬스 노출이 필요하면 그때 spring-boot3로 전환(YAGNI).
- **CB 설정 민감도**: 윈도우/임계값은 전역 공유+재시도 집계 특성상 워크로드에 민감하다. 기본값은 합리적 출발점일 뿐, 운영 SMTP 특성에 따라 환경변수로 조정해야 한다(과도한 사전 튜닝은 하지 않음 — Task 명시).
- **관측성 범위**: CB 상태 전이/ open fail-fast를 로그로만 남기고 메트릭 익스포트는 두지 않는다(코어 선택의 귀결). 단일 노드·단일 브로커 현 배포(architecture §8)에서 로그로 충분하다고 판단.

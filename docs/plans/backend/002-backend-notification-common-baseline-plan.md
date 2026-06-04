# 002. notification 공통 기반 클래스 — 구현 Plan

> 영역: backend (JPA 공통 엔티티 기반 + 내부 오류 추적 모델 + 커스텀 예외 베이스 + 테스트)
> 대상 프로젝트: notification (순수 Kafka Consumer, REST 없음)
> 작성일: 2026-05-30
> 상태: plan only (코드 변경 없음)

---

## 구현 목표
notification의 Consumer 에서 Service 거쳐 Repository 계층이 재사용할 JPA 공통 베이스 엔티티(BaseEntity + auditing)와 컨슈머 맥락에 맞는 내부 오류 추적 모델(REST ErrorResponse 아님), RuntimeException 상속 단일 커스텀 예외 베이스를 최소 범위로 구성하고, 실 DB/Kafka 없는 테스트 컨텍스트에서 통과하는 검증을 갖춘다.

## 영향 범위
- 신규 파일 (main)
  - notification/src/main/java/com/shop/notification/common/domain/BaseEntity.java
  - notification/src/main/java/com/shop/notification/common/config/JpaAuditingConfig.java
  - notification/src/main/java/com/shop/notification/common/exception/NotificationException.java
  - notification/src/main/java/com/shop/notification/common/error/ProcessingError.java (내부 오류 추적 모델 — 경량 값 객체)
- 신규 파일 (test)
  - notification/src/test/java/com/shop/notification/common/domain/BaseEntityTest.java
  - notification/src/test/java/com/shop/notification/common/exception/NotificationExceptionTest.java
  - notification/src/test/java/com/shop/notification/common/error/ProcessingErrorTest.java
  - notification/src/test/java/com/shop/notification/common/domain/support/SampleAuditableEntity.java (test 전용 BaseEntity 상속 샘플)
- 수정 파일
  - 없음 (기존 NotificationApplication, NotificationApplicationTests, build.gradle, test application.yml 변경 없음 — 풀 컨텍스트 검증은 기존 NotificationApplicationTests.contextLoads() 재사용)
- 범위 밖 (필요성만 언급, 후속 Task로 미룸)
  - 실제 Consumer/Service/Repository 본체, 운영 알림 도메인 엔티티(예: 발송 이력)
  - DLQ 토픽 / 재시도 정책 / 실패 영속 엔티티(실패 추적을 DB에 적재하는 테이블)
  - 멱등 처리용 처리 이력 엔티티
  - REST 관련 일체(ErrorResponse JSON DTO, RestControllerAdvice, GlobalExceptionHandler, MockMvc/@WebMvcTest)

> 비고: Task의 Files 항목에 consumer/**, service/** 가 적시되어 있으나, 본 Task는 "공통 기반"이 책임이다. 커스텀 예외가 "Consumer/Service 계층에서 사용될" 베이스라는 의미이며, 본 Task에서 Consumer/Service 본체 클래스를 만들지 않는다(과도 설계 금지). 경계는 섹션 6 트레이드오프에 명시.

---

## 1. 설계 방식 및 이유

### 1.1 패키지 배치 (shop-core 001과 일관, common 횡단 모듈)
- 공통 기반은 com.shop.notification.common 하위에 domain / config / exception / error 로 분리한다. 001(shop-core)의 common.{domain|config|exception} 구조와 일관성을 유지하되, 컨슈머 맥락의 내부 오류 모델을 common.error로 별도 분리한다(REST exception.ErrorResponse와 의미가 다름을 패키지로 구분).
- BaseEntity는 @MappedSuperclass로 두어 매핑 전용 기반임을 명확히 한다(Entity 직접 노출 금지 원칙의 출발점). notification은 REST가 없어 응답 노출 위험은 낮으나 일관성/재사용성을 위해 동일 원칙 적용.

### 1.2 REST 없음 → 001과의 핵심 차이 (명시적 구분)
- notification은 web/security/thymeleaf 의존성이 없는 순수 Kafka 컨슈머다. 따라서 001의 다음 구성요소는 본 Task에 해당 없음이며 만들지 않는다:
  - ErrorResponse(HTTP JSON DTO), RestExceptionHandler/@RestControllerAdvice, ViewExceptionHandler/@ControllerAdvice, error/error.html 뷰
  - @WebMvcTest, MockMvc, SecurityAutoConfiguration 제외, addFilters=false
- Requirements의 "ErrorResponse 또는 내부 오류 추적 모델"은 컨슈머 맥락(재시도/DLQ/멱등/실패 추적)에 맞는 내부 오류 추적 모델(ProcessingError)로 해석한다. HTTP 응답이 아니라 "메시지 처리 실패를 코드 내부에서 표현/전달/로깅"하는 경량 값 객체다.

### 1.3 내부 오류 추적 모델 — 경량 값 객체로 결정 (엔티티 아님)
- ProcessingError는 JPA 엔티티가 아닌 불변 경량 값 객체(record)로 둔다.
- 근거: 실패를 DB에 적재(실패 영속 엔티티)/DLQ로 보내는 것은 후속 Consumer Task 범위다. 본 Task는 "공통 기반/모델"까지이므로, 실패 사유를 코드 내부에서 구조화해 표현하는 최소 모델이면 충분하다. 지금 엔티티로 만들면 테이블/마이그레이션/리포지토리까지 끌고 와 과도 설계가 된다(YAGNI).
- 담는 필드(자족적/최소): eventType(어떤 이벤트 처리 중 실패했나, String), sourceEventId(원본 이벤트의 eventId — 멱등/추적, String), reason(실패 사유 메시지, String), exceptionType(원인 예외 클래스명, String), retryable(재시도 가능 여부, boolean), occurredAt(발생 시각, Instant).
- 정적 팩토리: ProcessingError.from(eventType, sourceEventId, NotificationException, Instant) 형태로 예외에서 조립. occurredAt 주입은 테스트 결정성을 위해 인자로 받는 오버로드 + 현재시각 기본 오버로드 둘 다 둔다(과하지 않은 선에서).
- 이후 Consumer Task에서 이 record를 (a) 구조적 로깅, (b) DLQ 페이로드, (c) 실패 영속 엔티티 변환의 소스로 재사용할 수 있게 자족적으로 구성한다.

### 1.4 커스텀 예외 베이스 — 방향 정리 최소 구현
- RuntimeException을 상속한 단일 베이스 NotificationException만 둔다. 도메인/원인별 구체 예외 계층은 후속 Task에서 상속 추가.
- HttpStatus 개념은 REST가 없으므로 부적절 — 넣지 않는다(001과의 명확한 차이).
- 컨슈머 맥락 최소 상태만: 메시지, 원인 cause(Throwable), 그리고 retryable(boolean) 1개. retryable은 "재처리하면 회복 가능(일시 장애)" vs "재처리해도 실패(영구 오류 → DLQ 후보)"를 호출측이 분기할 수 있는 최소 힌트다.
- 재시도/DLQ "정책"(횟수/백오프/DLQ 토픽명/전송) 구현은 본 Task 범위 아님. 베이스에는 분류 힌트(boolean)만 두고 정책은 후속 Consumer Task로 위임. enum/계층 등 과한 구조는 두지 않는다.

### 1.5 JPA Auditing 충돌 가드 (001 교훈 선제 적용)
- @Configuration @EnableJpaAuditing 단독 구성은, DataSource를 제외한 test profile의 @SpringBootTest 풀 컨텍스트에서 "JPA metamodel must not be empty" 오류를 유발한다(001에서 실측). notification의 test application.yml은 DataSource/Hibernate/Kafka 자동설정을 모두 제외하므로 동일 위험이 있다.
- 따라서 처음부터 JpaAuditingConfig에 @ConditionalOnBean(DataSource.class) 가드를 적용해 DataSource가 없는 테스트 컨텍스트에서는 auditing 설정이 비활성화되도록 한다(시행착오 생략).

---

## 2. 구성 요소 (생성할 클래스/파일)

### main

#### com.shop.notification.common.domain.BaseEntity
- 역할: 모든 알림 도메인 Entity가 상속하는 공통 매핑 기반.
- 애너테이션: @MappedSuperclass, @EntityListeners(AuditingEntityListener.class), Lombok @Getter.
- 필드:
  - @CreatedDate @Column(updatable = false) private Instant createdAt;
  - @LastModifiedDate private Instant updatedAt;
- 비고: id는 도메인별 전략(시퀀스/UUID)이 다를 수 있어 BaseEntity에 강제하지 않는다(001과 동일 결정). auditing 시간 필드만 공통화. setter 없음.

#### com.shop.notification.common.config.JpaAuditingConfig
- 역할: @CreatedDate/@LastModifiedDate 채움 활성화.
- 애너테이션: @Configuration, @EnableJpaAuditing, @ConditionalOnBean(DataSource.class).
- 충돌 회피: 가드로 인해 test profile(DataSource 제외) 풀 컨텍스트에서 auditing 빈이 생성되지 않아 metamodel-empty 오류를 회피한다. 운영(실 DataSource 존재) 환경에서는 정상 활성화.

#### com.shop.notification.common.exception.NotificationException
- 역할: 모든 notification 커스텀 예외의 단일 베이스.
- extends RuntimeException.
- 필드: private final boolean retryable; (HttpStatus 없음).
- 생성자(최소):
  - (String message) → retryable 기본값 false(보수적, 무한 재처리 방지). 영구 오류로 간주, 후속 정책에서 명시적 retryable 사용 유도.
  - (String message, Throwable cause) → retryable 기본 false.
  - (String message, Throwable cause, boolean retryable) → 명시 지정.
- 접근자: isRetryable().
- 비고: 도메인 구체 예외는 후속 Task에서 이 베이스 상속.

#### com.shop.notification.common.error.ProcessingError
- 역할: 컨슈머 메시지 처리 실패의 내부 표현(REST 응답 아님). 로깅/후속 DLQ/실패영속의 소스로 재사용 가능한 자족적 값 객체.
- 형태: record ProcessingError(String eventType, String sourceEventId, String reason, String exceptionType, boolean retryable, Instant occurredAt).
- 정적 팩토리:
  - from(String eventType, String sourceEventId, NotificationException e, Instant occurredAt)
  - from(String eventType, String sourceEventId, NotificationException e) (occurredAt = Instant.now())
- 비고: null 처리 최소 방어는 구현 재량. 과한 검증 로직은 지양.

### test

#### support/SampleAuditableEntity (test 전용)
- @Entity + extends BaseEntity + 최소 식별자(@Id 등). BaseEntity 상속/재사용 가능성 입증용. 운영 도메인 엔티티 아님(test source set에만 위치).
- 비고: 실 DB로 영속하지 않고, auditing 동작은 AuditingHandler로 검증하므로 매핑 메타데이터 보유 + 상속 구조 확인 용도.

#### BaseEntityTest
- 실 DB/H2 없이 auditing 동작 검증: AuditingHandler + 고정 DateTimeProvider(고정 Instant) 구성 → SampleAuditableEntity(또는 BaseEntity 직접 상속 더미)에 markCreated() 후 createdAt != null(고정값 일치), markModified() 후 updatedAt 갱신 검증.
- 보강: reflection으로 createdAt/updatedAt 필드의 @CreatedDate/@LastModifiedDate/@Column(updatable=false) 존재, 클래스의 @MappedSuperclass/@EntityListeners 존재 검증 가능.

#### NotificationExceptionTest
- 순수 단위 테스트(JUnit5). 검증:
  - 메시지 생성자 → getMessage() 일치, isRetryable() 기본 false.
  - (message, cause) 생성자 → getCause() 동일 참조, retryable false.
  - (message, cause, retryable=true) 생성자 → isRetryable() true, cause 전파.
  - instanceof RuntimeException 확인(언체크 예외 보장).

#### ProcessingErrorTest
- 순수 단위 테스트. 검증:
  - from(..., NotificationException, fixedInstant) → 각 필드(eventType/sourceEventId/reason=예외 메시지/exceptionType=예외 클래스명/retryable=예외의 retryable/occurredAt=고정값) 매핑 정확.
  - retryable 플래그가 예외에서 모델로 전파되는지(true/false 양쪽).
  - record 동등성(같은 값 → equals true) 기본 검증.

#### NotificationApplicationTests (기존, 재사용 — 신규 아님)
- 기존 @SpringBootTest @ActiveProfiles("test") contextLoads()가 JpaAuditingConfig(가드 적용) 추가 후에도 깨지지 않는지로 풀 컨텍스트 기동을 검증. 파일 수정 없음.

---

## 3. 데이터 흐름

실제 Consumer/Service/Repository 본체는 본 Task에서 구현하지 않으므로, 공통 기반이 "어디서 쓰일지"의 개념 흐름으로 서술한다.

### 3.1 예외 변환 흐름 (개념 — 후속 Consumer/Service에서 사용)
```
Kafka 메시지 도착 → Consumer(@KafkaListener) → Service.handle(payload)
  → Service 내부에서 외부/checked 예외(역직렬화/전송 실패 등) 발생
  → Service가 NotificationException(message, cause, retryable?)로 변환하여 throw
     (모든 예외를 RuntimeException 상속 커스텀 예외로 변환 규칙 충족)
  → Consumer(또는 에러 핸들러)가 NotificationException.isRetryable()로
     재처리/스킵(향후 DLQ) 분기 — 정책 구현은 후속 Task
```

### 3.2 내부 오류 모델 생성 흐름 (개념)
```
NotificationException 포착 지점(Consumer 에러 핸들러/Service 경계)
  → ProcessingError.from(eventType, sourceEventId, e, occurredAt) 조립
  → 용도: (a) 구조적 로깅, (b) [후속] DLQ 페이로드, (c) [후속] 실패 영속 엔티티 변환
  → sourceEventId 보존으로 멱등/추적 연계(이벤트 계약의 eventId 활용)
```

### 3.3 Auditing 채움 흐름 (운영 환경)
```
알림 도메인 Entity(BaseEntity 상속) 영속화(save) → Hibernate flush 직전
  → AuditingEntityListener 콜백 → AuditingHandler가 DateTimeProvider(현재 시각)로
     @CreatedDate(최초 insert), @LastModifiedDate(insert/update) 주입
JpaAuditingConfig(@EnableJpaAuditing, DataSource 있을 때만)가 이 핸들러를 활성화
```
- 테스트 컨텍스트(DataSource 제외)에서는 가드로 인해 auditing 빈이 비활성 → 풀 컨텍스트 기동 안전. auditing 동작 자체는 BaseEntityTest의 AuditingHandler 단위 검증으로 커버.

---

## 4. 예외 처리 전략

### 4.1 커스텀 예외 베이스
- NotificationException extends RuntimeException 단일 베이스 + boolean retryable(기본 false). HttpStatus 없음(REST 부재).
- "모든 예외는 RuntimeException 상속 커스텀 예외로 변환" 규칙: Service 경계에서 외부/checked 예외(역직렬화/DB/메일/SMS 게이트웨이 등)를 NotificationException으로 변환하는 권장 패턴을 명시(본 Task는 베이스 제공까지, 변환 코드는 후속 Service Task).

### 4.2 재시도/DLQ를 고려한 변환 방향
- retryable은 분류 힌트만 제공한다:
  - true: 일시적 장애(네트워크 타임아웃 등) — 재처리 시 회복 가능 → 후속 Task에서 재시도 대상.
  - false(기본): 영구 오류(잘못된 payload/검증 실패 등) — 재처리 무의미 → 후속 Task에서 DLQ/스킵 대상.
- 재시도 횟수/백오프/DLQ 토픽/전송 로직은 본 Task에서 구현하지 않는다(베이스에 필드/계층 추가 금지). 방향만 정리.

### 4.3 멱등 맥락
- ProcessingError.sourceEventId로 원본 이벤트의 eventId(이벤트 계약상 모든 이벤트가 보유)를 보존한다. 후속 Consumer Task가 처리 이력/멱등 키로 활용할 수 있도록 자족적으로 남긴다(본 Task는 모델 필드 제공까지).

### 4.4 알림 실패 격리(주문/결제에 영향 없음)와의 관계
- notification은 shop-core를 동기 호출하지 않고 Kafka 단방향 구독만 한다(CLAUDE.md 금지 규칙). 따라서 NotificationException/ProcessingError는 notification 내부에서만 소비되며 shop-core로 역류하지 않는다 — 알림 처리 실패가 주문/결제 흐름에 영향을 주지 않는 격리를 코드 구조상 보장한다. 본 공통 기반은 이 격리 원칙을 위반하지 않는다(REST 역호출/DB 공유 일체 없음).

---

## 5. 검증 방법 (./gradlew test)

> 실행 위치: 하위 프로젝트 notification/. 실 DB/Kafka 없는 test profile(DataSource/Hibernate/DataSourceTx/Kafka 자동설정 제외)에서 통과해야 한다. web/security 의존성이 없으므로 @WebMvcTest/MockMvc/SecurityAutoConfiguration 제외/addFilters는 일절 불필요.

### 5.1 Auditing 단위 검증 (BaseEntityTest)
- AuditingHandler + 고정 DateTimeProvider 구성 → markCreated() 후 createdAt이 고정 Instant로 채워짐, markModified() 후 updatedAt 갱신 검증. (실 DB/H2 불필요 — notification은 H2 미도입, 방침 유지)
- 보강: reflection으로 매핑 애너테이션/@MappedSuperclass 존재 검증.

### 5.2 커스텀 예외 동작 검증 (NotificationExceptionTest)
- 메시지/원인(cause)/retryable(true/false) 전파, instanceof RuntimeException 확인.

### 5.3 내부 오류 모델 검증 (ProcessingErrorTest)
- from(...) 팩토리의 필드 매핑(eventType/sourceEventId/reason/exceptionType/retryable/occurredAt) 정확성, retryable 전파, record 동등성. 고정 Instant로 결정적 검증.
- REST Controller 없이도 모델이 단위 테스트로 검증됨을 입증(Acceptance 충족).

### 5.4 풀 컨텍스트 기동 (기존 NotificationApplicationTests 재사용)
- @SpringBootTest @ActiveProfiles("test") contextLoads()가 JpaAuditingConfig(@ConditionalOnBean(DataSource.class) 가드) 추가 후에도 깨지지 않는지 확인. DataSource 부재 시 auditing 빈 미생성 → metamodel-empty 오류 회피.

### 5.5 Acceptance Criteria 대 검증 매핑
| Acceptance | 검증 |
|---|---|
| BaseEntity가 알림 도메인 Entity에서 재사용 가능 | @MappedSuperclass 설계 + SampleAuditableEntity(test 상속 샘플) + BaseEntityTest (5.1) |
| Consumer/Service에서 사용할 커스텀 예외 기반 준비 | NotificationException 베이스 + NotificationExceptionTest (5.2) |
| REST Controller 없이도 내부 오류 모델이 테스트 가능 | ProcessingError(record) + ProcessingErrorTest (5.3) |
| 관련 테스트 통과 | ./gradlew test 전체 green + 풀 컨텍스트 기동 (5.4) |

---

## 6. 트레이드오프

- 내부 오류 모델: 엔티티 vs 경량 모델
  - 채택: 경량 record(ProcessingError). (장) 테이블/마이그레이션/리포지토리 없이 즉시 단위 테스트 가능, 범위 최소. (단) 실패를 DB로 추적하려면 후속 Task에서 영속 엔티티로 변환 필요 → 본 record를 소스로 재사용하도록 자족적 설계.
  - 미채택: 지금 JPA 엔티티화 → 실패 영속/리포지토리/스키마까지 끌고 와 과도 설계(YAGNI), 본 Task 범위 초과.
- 예외 베이스에 retryable 포함 여부
  - 채택: boolean retryable 1개만 포함(기본 false). (장) 후속 재시도/DLQ 분기를 위한 최소 힌트 제공, 컨슈머 맥락에 적합. (단) 세분류 필요 시 enum 전환 가능 — 현재는 boolean으로 충분.
  - 미채택: enum/예외 계층/HttpStatus → REST 부재/정책 미정 상황에 과함.
  - 기본값 결정: false(보수적, 영구 오류로 간주). 무한 재처리 위험 회피. 일시 장애는 변환 지점에서 명시적으로 true 지정.
- Auditing 검증 방식
  - 채택: AuditingHandler + 고정 DateTimeProvider 단위 + 풀 컨텍스트 기동 확인. (장) H2/실 DB 불필요, 방침 유지. (단) 실제 insert/update 시점 주입은 후속 도메인 Task의 통합 테스트에서 자연 검증.
  - 미채택: H2 + @DataJpaTest → 방침 위배/과도.
- JpaAuditingConfig 가드
  - 채택: @ConditionalOnBean(DataSource.class) 선제 적용(001 실측 교훈). (장) test profile 풀 컨텍스트 안전. (단) 가드 1개 추가 — 충돌 회피 대비 합리적 비용.
- Consumer/Service 본체 구현 범위
  - 채택: 본 Task는 공통 기반(BaseEntity/예외 베이스/오류 모델/테스트)만. Consumer/Service 본체와 DLQ/재시도/실패 영속은 후속 Task로 위임. (장) 단일 책임/과도 설계 회피, 두 에이전트 인터페이스(예외/모델 시그니처)만 미리 안정화. (단) 실제 사용 코드는 후속에 등장 — 본 기반이 자족적이어야 함.
- 001(shop-core)과의 일관성 vs 차이
  - 일관: 패키지 구조(common.{domain|config|exception}), BaseEntity(@MappedSuperclass+auditing, id 비강제), auditing 가드 패턴, AuditingHandler 단위 검증.
  - 차이(REST 부재): ErrorResponse JSON DTO/Rest/View advice/error 뷰/@WebMvcTest/MockMvc/Security 제외 일절 없음. 내부 오류는 HTTP 응답이 아닌 ProcessingError 값 객체로, HttpStatus 대신 retryable로 표현.

---

## Spring Boot 컨벤션
- 패키지: com.shop.notification.common.{domain|config|exception|error}.
- 어노테이션: @MappedSuperclass, @EntityListeners(AuditingEntityListener.class), @CreatedDate/@LastModifiedDate, @Column(updatable=false), @Configuration, @EnableJpaAuditing, @ConditionalOnBean(DataSource.class), Lombok @Getter.
- 예외 처리: RuntimeException 상속 NotificationException 베이스로 변환(HttpStatus 없음, retryable 힌트). REST 공통 포맷 없음.
- Entity 미노출: BaseEntity는 @MappedSuperclass. notification은 REST/View 진입점이 없어 Entity 응답 노출 경로 자체가 없음.
- 화면(view) 작업 없음: notification은 Thymeleaf/뷰가 없으므로 view-implementor 분담 없음.

## 완료 조건
- [ ] BaseEntity(@MappedSuperclass + auditing 필드, id 비강제) 생성
- [ ] JpaAuditingConfig(@EnableJpaAuditing + @ConditionalOnBean(DataSource.class)) 생성, 풀 컨텍스트 기동 깨지지 않음
- [ ] NotificationException 베이스 생성(RuntimeException 상속, retryable 보유, HttpStatus 없음)
- [ ] ProcessingError 내부 오류 모델(record) 생성 — 엔티티 아님, REST DTO 아님
- [ ] test 전용 SampleAuditableEntity(BaseEntity 상속) 생성 — 재사용 입증용
- [ ] BaseEntityTest(AuditingHandler 단위) 통과
- [ ] NotificationExceptionTest(메시지/cause/retryable/언체크) 통과
- [ ] ProcessingErrorTest(from 매핑/retryable 전파/동등성) 통과
- [ ] 기존 NotificationApplicationTests.contextLoads() 풀 컨텍스트 통과(가드 검증)
- [ ] REST/View/Security/MockMvc 관련 산출물 0개(notification 컨벤션 준수)
- [ ] ./gradlew test 전체 통과

## 에이전트 분담
- 본 Task는 전부 backend-implementor 단독 수행. notification에 view가 없으므로 view-implementor 분담 없음.
- 후속 Consumer/Service Task와의 인터페이스 계약(미리 안정화할 시그니처): NotificationException(message, cause, retryable), ProcessingError.from(eventType, sourceEventId, NotificationException, Instant), BaseEntity(createdAt/updatedAt).

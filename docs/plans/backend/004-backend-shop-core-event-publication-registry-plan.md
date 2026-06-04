# 004. shop-core Event Publication Registry + 더미 이벤트 발행 — 구현 Plan

> 영역: backend (Spring Modulith Event Publication Registry / Transactional Outbox + Kafka 외부화 스모크 검증)
> 대상 프로젝트: shop-core (모듈러 모놀리스)
> 작성일: 2026-06-02
> 상태: plan only (코드 변경 없음)
> 담당: backend-implementor 단독. 화면(Thymeleaf/정적 리소스) 산출물 없음, view-implementor 분담 없음.

---

## 0. 작업 구분 요약 (백엔드 vs 화면)

| 구분 | 항목 | 담당 |
|---|---|---|
| 백엔드 | build.gradle 의존성, application.yml 설정, 더미 이벤트 record, 발행 Service, ServiceResponse, RestController, 트랜잭션/로깅, 테스트 | backend-implementor |
| 화면 | 없음 (이 Task는 순수 백엔드. Thymeleaf 템플릿/정적 자산/ViewController 변경 없음) | 해당 없음 |

이 Task는 도메인 기능 구현 전에 Kafka 외부화 경로를 조기 검증(smoke)하는 인프라성 작업이다. 사용자 대면 화면이 없으므로 view-implementor 호출은 발생하지 않는다.

---

## 1. 구현 목표

shop-core에서 Spring Modulith Event Publication Registry 기반 Transactional Outbox 발행 경로(이벤트 저장 후 Kafka 외부화)를 구성하고, 도메인 기능 구현 전에 더미 이벤트 발행 REST 엔드포인트로 발행 경로를 조기 검증한다. 공개 이벤트 계약(OrderCompletedEvent / PaymentFailedEvent / ShippingStartedEvent)은 일절 건드리지 않는다.

---

## 2. 설계 방식 및 이유

### 2.1 패키지 위치 결정: 신규 platform 모듈
- 더미 이벤트는 어느 도메인(cart/order/payment 등)에도 속하지 않는 스모크 검증 전용 인프라 산출물이다.
- common(OPEN 모듈)에 넣으면 횡단 공유 컴포넌트가 오염되고, 더미라는 한시적 성격이 영구 공유 모듈에 섞인다.
- 따라서 신규 top-level 모듈 com.shop.shop.platform 을 신설하고 그 하위에 더미 이벤트 관련 클래스를 모은다.
  - Spring Modulith는 com.shop.shop 직속 하위 패키지를 자동으로 모듈로 인식하므로 platform은 독립 모듈이 된다.
  - 한시성/격리성을 패키지 이름과 Javadoc으로 명시하여 이후 삭제/교체가 쉽다.
  - 도메인 모듈을 참조하지 않으므로 ModularityTests(verify) 위반이 발생하지 않는다.
- 명명: 이벤트 클래스는 DummyOutboxSmokeEvent처럼 Dummy/Smoke 토큰을 명시해 공개 도메인 이벤트와 절대 혼동되지 않게 한다.

### 2.2 발행 메커니즘: Spring Modulith Event Externalization
- Spring ApplicationEventPublisher로 발행한 이벤트를 Event Publication Registry(JPA)가 트랜잭션 안에서 저장(Outbox)하고, 커밋 후 Kafka로 외부화한다.
- 이벤트 클래스에 @Externalized("토픽명") 를 부여하면 Modulith가 Kafka로 라우팅한다 (Spring Modulith 1.3.x).
  - 라우팅 키(토픽명 뒤 콜론콜론 키)는 선택. 더미는 키 없이 토픽만 지정한다. 예: @Externalized("shop-core-smoke-test").
  - 외부화 전역 스위치는 spring.modulith.events.externalization.enabled 설정으로 제어한다.
- 트랜잭션 안에서 publishEvent() 호출, 같은 트랜잭션에서 publication 레코드가 INCOMPLETE로 저장, 커밋 시 spring-modulith-events-kafka 브로커 어댑터가 직렬화해 외부 발행, 성공 시 COMPLETED 마킹.

### 2.3 레이어: REST 컨벤션 준수
- RestController, ServiceResponse, Service, Repository 원칙을 따른다.
- 단, 이 Task는 도메인 영속화가 없어 Repository가 불필요하다. Event Publication Registry 자체가 Outbox(영속) 역할을 대신하므로 별도 Repository는 만들지 않는다(과도한 설계 회피).
- ServiceResponse는 REST 응답 조합 전용 계층으로 더미 발행 결과(eventId, occurredAt 등)를 응답 DTO로 조립한다.
- Controller에는 로직 없음: 요청 받아 ServiceResponse 위임만.

### 2.4 의존성 추가 (검토 결과: 추가 필요)
현재 build.gradle에는 외부화 모듈이 없다. 다음을 추가한다:
- org.springframework.modulith:spring-modulith-events-api  (@Externalized 등 외부화 API)
- org.springframework.modulith:spring-modulith-events-kafka (Kafka 외부화 어댑터, 브로커 바인딩)
- 버전은 BOM(spring-modulith-bom:1.3.1)이 관리하므로 버전 미기재.
- spring-modulith-starter-jpa는 이미 있어 JPA Event Publication Registry는 확보됨. spring-kafka도 이미 존재.

---

## 3. 구성 요소 (전체 경로)

### 3.1 신규 파일 (main)

shop-core/src/main/java/com/shop/shop/platform/package-info.java
- 역할: platform 모듈 루트 문서. 더미/스모크 전용 한시 모듈임을 명시. 도메인 모듈 비참조 가드레일 기술.

shop-core/src/main/java/com/shop/shop/platform/event/DummyOutboxSmokeEvent.java
- 역할: 더미 이벤트 페이로드 (Java record).
- 필드: UUID eventId, Instant occurredAt, String message.
  - eventId/occurredAt은 CLAUDE.md 이벤트 규칙(eventId + 발생 시각) 준수.
- 어노테이션: @org.springframework.modulith.events.Externalized("shop-core-smoke-test")
  - 토픽 shop-core-smoke-test로 외부화. 공개 토픽명(OrderCompletedEvent 등)과 겹치지 않게 -smoke-test 접미.
- 비고: notification이 구독하지 않는 토픽(스모크 전용). 공개 계약 문서 미반영(의도적).

shop-core/src/main/java/com/shop/shop/platform/dto/DummyEventPublishResponse.java
- 역할: REST 응답 DTO (record). Entity/이벤트 직접 노출 금지 원칙 준수.
- 필드: String eventId, Instant occurredAt, String message, String topic.

shop-core/src/main/java/com/shop/shop/platform/service/DummyEventPublishService.java
- 역할: 더미 이벤트 생성 + 트랜잭션 내 발행.
- 어노테이션: @Service, 발행 메서드에 @Transactional, @Slf4j.
- 의존: org.springframework.context.ApplicationEventPublisher.
- 메서드: DummyOutboxSmokeEvent publish(String message)
  - eventId=UUID.randomUUID(), occurredAt=Instant.now()로 이벤트 생성.
  - publishEvent(event) 호출 (트랜잭션 안, Registry가 Outbox 저장).
  - 발행 시도 로그(info: eventId/topic), 예외 시 실패 로그(error) 후 BusinessException으로 변환해 재던짐(공통 예외 규칙).

shop-core/src/main/java/com/shop/shop/platform/service/DummyEventServiceResponse.java
- 역할: REST 응답 조합 전용 계층(컨벤션의 ServiceResponse 역할).
- 어노테이션: @Service(또는 @Component), 의존: DummyEventPublishService.
- 메서드: DummyEventPublishResponse publishDummy(String message)
  - Service 호출 결과(DummyOutboxSmokeEvent)를 DummyEventPublishResponse DTO로 변환(토픽명 포함).

shop-core/src/main/java/com/shop/shop/platform/controller/DummyEventController.java
- 역할: 더미 발행 REST 진입점. 로직 없음, ServiceResponse 위임만.
- 어노테이션: @RestController, @RequestMapping("/api/v1/platform/smoke") (REST는 /api/v1/** 패턴 준수).
- 엔드포인트: POST /api/v1/platform/smoke/events
  - 바디(선택): message 필드 또는 쿼리 파라미터. 단순화를 위해 message는 optional, 기본값 부여.
  - 반환: ResponseEntity<DummyEventPublishResponse> (200 또는 202).

shop-core/src/main/java/com/shop/shop/platform/{controller,service,event,dto}/package-info.java (권장)
- 역할: 기존 모듈 컨벤션(서브패키지 package-info)과 일관성 유지용 레이어 문서. 최소 controller/service/event/dto 4개 권장.

### 3.2 수정 파일

shop-core/build.gradle
- dependencies에 추가: spring-modulith-events-api, spring-modulith-events-kafka (BOM 관리 버전).

shop-core/src/main/resources/application.yml
- spring.modulith.events.externalization.enabled: true (외부화 활성).
- Kafka producer 설정은 이미 존재(key=String, value=JsonSerializer)이며 외부화 직렬화와 호환. 변경 없음(확인만, 주석으로 추적 가능성 명시).
- event_publication 테이블은 현재 ddl-auto=create로 Hibernate가 생성(4.3 참조). 별도 SQL 미필요.

shop-core/src/test/resources/application.yml
- 현재 Kafka/JPA/Outbox 자동설정이 모두 exclude됨. 컨텍스트 테스트가 실 Kafka/DB 없이 로드되도록 이 exclude를 유지한다(6장 전략 참조).
- 외부화를 테스트 프로파일에서 비활성: spring.modulith.events.externalization.enabled: false 명시 추가(테스트 컨텍스트에서 Kafka 브로커 바인딩 시도 방지).

### 3.3 신규 파일 (test)
- shop-core/src/test/java/com/shop/shop/platform/service/DummyEventPublishServiceTest.java
  - 단위 테스트(Mockito): ApplicationEventPublisher mock 주입, publish() 호출 시 eventId/occurredAt 비어있지 않음, publishEvent가 정확히 1회 호출됨 검증.
- shop-core/src/test/java/com/shop/shop/platform/service/DummyEventServiceResponseTest.java
  - 단위 테스트: Service mock, 반환 이벤트가 DTO로 올바르게 매핑(토픽명 포함)되는지 검증.
- 컨텍스트 테스트: 기존 ShopCoreApplicationTests(@SpringBootTest, test 프로파일)가 신규 빈(platform.*) 포함 컨텍스트 로드를 커버. 필요 시 platform 전용 @SpringBootTest 컨텍스트 테스트 1개 추가.
- 모듈 구조: 기존 ModularityTests가 신규 platform 모듈을 자동 검증. platform이 도메인 모듈을 참조하지 않으므로 통과해야 함(구현 시 import 가드).

---

## 4. 데이터 흐름

  POST /api/v1/platform/smoke/events
    -> DummyEventController (@RestController, 로직 없음): message 위임
    -> DummyEventServiceResponse (응답 조합 전용): publishDummy(message)
    -> DummyEventPublishService (@Transactional):
         1) DummyOutboxSmokeEvent(eventId=UUID, occurredAt=now, message) 생성
         2) ApplicationEventPublisher.publishEvent(event)
    -> Spring Modulith Event Publication Registry (JPA):
         트랜잭션 내 event_publication 레코드 INSERT (INCOMPLETE) = Transactional Outbox, 이후 커밋
    -> spring-modulith-events-kafka 어댑터:
         @Externalized(shop-core-smoke-test) 로 Kafka 발행(JsonSerializer)
         성공 -> publication COMPLETED 마킹 / 로그(info)
         실패 -> INCOMPLETE 유지(재시도 대상) / 로그(error)
    -> 응답: DummyEventPublishResponse { eventId, occurredAt, message, topic }

핵심: publishEvent가 트랜잭션 안에서 호출되어 Outbox 레코드와 도메인 변경(이번엔 없음)이 원자적으로 커밋된다. 외부화는 커밋 이후 수행되어 발행 신뢰성을 보장한다.

### 4.3 Event Publication Registry 테이블 생성 경로
- spring-modulith-starter-jpa가 JPA 기반 Registry(event_publication 테이블)를 제공한다.
- 운영/통합 환경: 현재 spring.jpa.hibernate.ddl-auto=create이므로 Modulith 엔티티 매핑으로 테이블이 자동 생성된다. (Flyway 도입 Task에서 validate 전환 시 Modulith 스키마 SQL을 마이그레이션에 포함해야 함을 주석으로 남긴다.)
- 테스트 환경: JpaEventPublicationAutoConfiguration이 exclude되어 Registry 테이블/빈이 로드되지 않음. 단위 테스트는 publisher 모킹으로 우회.

---

## 5. 예외 처리 전략

- 모든 예외는 RuntimeException 상속 커스텀 예외로 변환(CLAUDE.md). Service에서 발행 실패 시 BusinessException(common)으로 래핑해 던진다.
- REST 에러 응답은 기존 RestExceptionHandler(common, @RestControllerAdvice) + ErrorResponse 공통 포맷을 그대로 사용한다. 신규 핸들러 불필요.
- 로깅:
  - 발행 시도: log.info, eventId/topic 포함.
  - 발행 성공: info 레벨 성공 로그.
  - 발행 실패: log.error, eventId + 예외 스택 포함.
- 비동기 외부화(커밋 후) 실패는 호출 스레드 예외로 전파되지 않을 수 있음. 그 경우 publication 레코드가 INCOMPLETE로 남아 재시도/추적 가능함을 Javadoc에 명시(스모크 검증 범위).

---

## 6. 검증 방법 (테스트, Kafka/Outbox 자동설정 exclude 대응)

### 6.1 제약
- test 프로파일 application.yml이 DataSource / HibernateJpa / DataSourceTransactionManager / Kafka / JpaEventPublication 자동설정을 모두 exclude한다. 즉 @SpringBootTest는 실 DB/Kafka/Outbox 없이 로드되어야 한다.

### 6.2 전략
1. 단위 테스트 우선(핵심 검증): 발행 로직은 ApplicationEventPublisher를 Mockito로 모킹한 순수 단위 테스트로 검증한다. DB/Kafka 불필요하므로 exclude 제약과 무관하게 동작. eventId/occurredAt 존재, publishEvent 1회 호출, DTO 매핑 정확성.
2. 컨텍스트 로드 테스트: 기존 ShopCoreApplicationTests(@SpringBootTest, @ActiveProfiles test)가 신규 platform 빈을 포함해 컨텍스트가 깨지지 않고 로드됨을 검증. 외부화 어댑터가 Kafka 브로커 연결을 시도하지 않도록 test 프로파일에서 externalization.enabled=false(그리고 Kafka 자동설정 exclude 유지)로 컨텍스트 로드를 격리. Acceptance 컨텍스트가 Event Publication Registry 설정과 함께 로드된다를 이 테스트로 충족.
3. 모듈 구조 테스트: 기존 ModularityTests.verify()가 신규 platform 모듈을 자동 검증(순환/internal 참조 없음).
4. 선택, Outbox 통합 검증: 실 Outbox/Kafka 검증은 @EmbeddedKafka + 테스트 전용 DB(H2/Testcontainers)가 필요하나, 현 test 프로파일 정책(자동설정 exclude)과 충돌. 본 Task 스모크 범위에서는 단위+컨텍스트 로드로 제한하고, 실 브로커 검증은 후속 통합 테스트 Task로 미룬다(7장 트레이드오프).

### 6.3 Acceptance Criteria 매핑
| Acceptance | 검증 수단 |
|---|---|
| 컨텍스트가 Registry 설정과 함께 로드 | ShopCoreApplicationTests(@SpringBootTest) |
| REST 엔드포인트가 Service 통해 발행 | DummyEventController + Service 단위 테스트 |
| eventId/발생 시각 포함 | DummyEventPublishServiceTest |
| 트랜잭션 안에서 발행 | @Transactional 부여 + 코드 리뷰 + Service 테스트 |
| Kafka producer/외부화 설정 추적 가능 | application.yml diff + build.gradle diff |
| 공개 이벤트 계약 문서 불변 | docs/architecture.md 섹션 5 무변경 확인 |
| 테스트 통과 | 단위 + 컨텍스트 + ModularityTests |

---

## 7. 트레이드오프

1. 신규 platform 모듈 vs common 재사용: 모듈 1개 증가(약간의 구조 비용)를 감수하고 더미의 한시성/격리성을 확보. common 오염/삭제 난이도 회피. (CLAUDE.md 정당한 사유 없이 세 번째 서비스 추가 금지는 별도 마이크로서비스 신설 규칙이며, 여기선 모듈 내 패키지이므로 위반 아님.)
2. 실 Kafka/Outbox E2E 미검증: test 프로파일이 Kafka/JPA 자동설정을 exclude하므로 이번엔 실 브로커 라운드트립을 검증하지 않는다. 스모크 목적(경로 구성/컴파일/컨텍스트 로드/발행 호출)에 한정. 실 외부화 검증은 EmbeddedKafka+테스트DB 도입 후속 Task로 분리.
3. 더미 토픽 notification 미구독: shop-core-smoke-test는 공개 계약 외 토픽이라 notification에 영향 없음. 스모크 후 제거 시 외부 파급 없음.
4. 외부화 비동기 실패 가시성: 커밋 후 외부화 실패는 호출 응답에 즉시 반영되지 않고 publication INCOMPLETE로 남음. 스모크 범위에서는 로그+레코드 추적으로 충분, 자동 재시도/모니터링은 후속.

---

## 8. 완료 조건 (Definition of Done)

- [ ] build.gradle에 spring-modulith-events-api / spring-modulith-events-kafka 추가(BOM 버전).
- [ ] application.yml(main)에 externalization.enabled=true 추가, Kafka producer 설정 추적 가능.
- [ ] application.yml(test)에서 컨텍스트 로드 격리 설정 반영(외부화 비활성 + Kafka exclude 유지).
- [ ] platform 모듈: event(record + @Externalized) / dto / service / serviceResponse / controller / package-info 생성.
- [ ] 더미 이벤트에 eventId(UUID) + occurredAt(Instant) 포함.
- [ ] 발행은 @Transactional 내 ApplicationEventPublisher 사용.
- [ ] 발행 성공/실패 로그 추가, 실패는 BusinessException 변환.
- [ ] REST 엔드포인트 POST /api/v1/platform/smoke/events 가 ServiceResponse 경유.
- [ ] Entity/이벤트 직접 반환 없음(응답 DTO 사용).
- [ ] 단위 테스트 + 컨텍스트 로드 테스트 + ModularityTests 통과.
- [ ] docs/architecture.md 섹션 5(공개 이벤트 계약) 무변경.
- [ ] notification 코드 비참조/DB 비공유.

---

## 9. Spring Boot / Modulith 컨벤션 적용 요약
- 패키지: com.shop.shop.platform.{controller,service,event,dto}.
- 어노테이션: @RestController, @Service, @Transactional, @Slf4j, @org.springframework.modulith.events.Externalized, 필요 시 @org.springframework.modulith.ApplicationModule(platform 루트).
- 예외: BusinessException(common) + RestExceptionHandler(common) 재사용.
- 의존성 버전: spring-modulith-bom 1.3.1이 관리하므로 외부화 모듈 버전 미기재.

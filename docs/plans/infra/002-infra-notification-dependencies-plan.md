# 002. notification 의존성 베이스라인 — 구현 Plan

## 구현 목표
notification에 JPA·PostgreSQL·Spring Kafka·Validation 의존성을 추가하고, 불필요한 web 의존성을 제거하여 "순수 Kafka 컨슈머 + 자기 소유 PostgreSQL" 구성을 만든다. 외부 인프라(DB·Kafka) 없이도 ./gradlew test 의 컨텍스트 로드 테스트가 통과하는 베이스라인을 구성한다.

## 영향 범위 (backend 영역 한정 — 화면 없음)
- 신규 파일
  - notification/src/main/resources/application.yml (기존 application.properties 는 삭제)
  - notification/src/test/resources/application.yml (테스트 자동 적용 — 외부 인프라 차단)
- 수정 파일
  - notification/build.gradle — 의존성 추가/정리, 주석 그룹핑, 레포지토리 정리
  - notification/src/test/java/com/shop/notification/NotificationApplicationTests.java — 테스트 프로파일 명시
- 삭제 파일
  - notification/src/main/resources/application.properties (yml로 일원화)

---

## 1. 설계 방식 및 이유

### 1-1. 왜 이 의존성 세트인가
Task Requirements가 요구하는 의존성은 JPA, PostgreSQL 드라이버, Spring Kafka, Validation 네 가지이며, 이는 notification의 역할(이벤트 구독 + 발송 이력·멱등 데이터 저장, docs/architecture.md 라인 46/67)을 위한 최소 선행 조건이다.

- spring-boot-starter-data-jpa: 발송 이력·멱등 체크(processed_event 류) 데이터를 자기 소유 PostgreSQL에 저장하기 위한 Repository 기반.
- postgresql (runtimeOnly): 운영 DB 드라이버. 컴파일 시점에 노출되지 않도록 runtimeOnly 스코프 (자매 프로젝트 shop-core와 동일 스타일).
- spring-kafka: shop-core 이벤트(OrderCompletedEvent·PaymentFailedEvent·ShippingStartedEvent) 구독. Consumer가 핵심 진입점.
- spring-boot-starter-validation: 이벤트 페이로드 역직렬화 후 DTO 유효성 검증(@Valid/@Validated). Spring Boot 3.x에서는 web에 자동 포함되지 않으므로 명시적 추가 필요(특히 web을 제거하면 더더욱 명시 필요).
- 테스트: spring-boot-starter-test(기존 유지), spring-kafka-test(EmbeddedKafka 옵션 보유, 후속 Consumer Task용).

### 1-2. notification에 들어가지 않는 것 (shop-core와의 차이)
notification은 REST API·View 없는 순수 컨슈머이므로 다음을 추가하지 않는다 (CLAUDE.md notification 섹션):
- Spring Modulith (모듈러 모놀리스는 shop-core 전용)
- Spring Security
- Thymeleaf / thymeleaf-extras-springsecurity6
- spring-boot-starter-web (제거 대상 — 1-3 참고)

### 1-3. web 의존성 유지 여부 — 제거로 판단
결론: spring-boot-starter-web 을 제거한다.

근거:
- notification은 REST API가 없다 (CLAUDE.md: "REST API가 없으면 Controller·ServiceResponse를 두지 않는다"). 진입점은 Kafka Consumer 단 하나.
- web을 두면 Tomcat 내장 서버가 기동되어 포트를 점유하고, 컨슈머 전용 서비스에 불필요한 HTTP 표면을 노출한다.
- web 제거 시 애플리케이션은 비-웹(non-web) 컨텍스트로 부팅된다. Kafka 컨슈머는 @KafkaListener 기반의 백그라운드 리스너 컨테이너로 동작하므로 웹 서버 없이도 정상 동작한다.

제거 시 영향 검토:
- 헬스 체크/관측성: web 제거로 actuator HTTP 엔드포인트가 사라진다. 단, 이 Task 범위는 "의존성 베이스라인"이며 actuator는 Requirements에 없다. 운영 헬스 체크가 필요해지면 별도 Task에서 spring-boot-starter-actuator(+ 필요 시 web)를 추가하는 것으로 미룬다. (트레이드오프 6-2 참고)
- Validation 자동 구성: 기존에는 web이 validation을 끌어왔으나, web 제거 + starter-validation 명시 추가로 동일 기능을 보장한다. 그래서 validation을 반드시 명시적으로 추가한다.
- 부팅 타입 변경: @SpringBootTest는 web 없는 컨텍스트에서도 동작하므로 컨텍스트 로드 테스트에 문제 없다.

### 1-4. application.yml로 전환할지 — yml로 전환
결론: application.properties 를 삭제하고 application.yml 로 전환한다.

근거:
- 자매 프로젝트(shop-core)가 yml로 일원화했고(plan 001), 워크스페이스 전반의 일관성을 위해 동일 포맷을 채택한다.
- datasource·jpa·kafka 등 중첩 키가 늘어나며 yml의 중첩 가독성·멀티-도큐먼트 프로파일 분리가 유리하다.
- Task Requirements가 "필요 시 기본 application.yml 생성"을 명시했고 Files에 application.yml 이 적시됨.

### 1-5. Profile 전략
- default: 로컬/운영 가정. PostgreSQL·Kafka 연결 정보를 환경변수 placeholder로 둔다. 부팅 시 외부 인프라가 있어야 정상 동작 — 이 단계의 운영 가정.
- test: src/test/resources/application.yml 에서 외부 인프라 자동 설정을 비활성화한다. DataSource·JPA·Kafka 자동 구성을 제외해 CI/로컬 모두 인프라 없이 ./gradlew test 통과를 보장한다.

---

## 2. 구성 요소 (파일·설정)

### 2-1. notification/build.gradle (수정)

```groovy
plugins {
    id 'java'
    id 'org.springframework.boot' version '3.5.15-SNAPSHOT'
    id 'io.spring.dependency-management' version '1.1.7'
}

group = 'com.shop'
version = '0.0.1-SNAPSHOT'
description = 'notification'

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(21)
    }
}

repositories {
    mavenCentral()
    maven { url = 'https://repo.spring.io/snapshot' }
}

dependencies {
    // Persistence
    implementation 'org.springframework.boot:spring-boot-starter-data-jpa'
    runtimeOnly   'org.postgresql:postgresql'

    // Messaging
    implementation 'org.springframework.kafka:spring-kafka'

    // Validation
    implementation 'org.springframework.boot:spring-boot-starter-validation'

    // Lombok
    compileOnly       'org.projectlombok:lombok'
    annotationProcessor 'org.projectlombok:lombok'

    // Test
    testImplementation 'org.springframework.boot:spring-boot-starter-test'
    testImplementation 'org.springframework.kafka:spring-kafka-test'
    testCompileOnly   'org.projectlombok:lombok'
    testAnnotationProcessor 'org.projectlombok:lombok'
    testRuntimeOnly   'org.junit.platform:junit-platform-launcher'
}

tasks.named('test') {
    useJUnitPlatform()
}
```

변경 요약:
- 제거: spring-boot-starter-web (1-3 근거).
- 추가: spring-boot-starter-data-jpa, org.postgresql:postgresql(runtimeOnly), spring-kafka, spring-boot-starter-validation, spring-kafka-test(testImplementation).
- 주석 그룹핑: shop-core 스타일에 맞춰 // Persistence, // Messaging, // Validation, // Lombok, // Test 로 그룹화.
- 레포지토리: snapshot 만 유지(Boot SNAPSHOT 사용). Modulith를 안 쓰므로 milestone 레포는 추가하지 않는다.
- BOM: Modulith를 안 쓰므로 dependencyManagement import 불필요. spring-kafka·postgresql 버전은 Boot BOM이 관리하므로 버전 명시 없음.

GAV 정리:

| Group | Artifact | Scope | 버전 관리원 |
|---|---|---|---|
| org.springframework.boot | spring-boot-starter-data-jpa | implementation | Boot BOM |
| org.postgresql | postgresql | runtimeOnly | Boot BOM |
| org.springframework.kafka | spring-kafka | implementation | Boot BOM |
| org.springframework.boot | spring-boot-starter-validation | implementation | Boot BOM |
| org.springframework.boot | spring-boot-starter-test | testImplementation | Boot BOM |
| org.springframework.kafka | spring-kafka-test | testImplementation | Boot BOM |

### 2-2. notification/src/main/resources/application.yml (신규, properties 삭제)

```yaml
spring:
  application:
    name: notification

  datasource:
    url: ${NOTIFICATION_DB_URL:jdbc:postgresql://localhost:5433/notification}
    username: ${NOTIFICATION_DB_USERNAME:notification}
    password: ${NOTIFICATION_DB_PASSWORD:notification}
    driver-class-name: org.postgresql.Driver

  jpa:
    open-in-view: false
    hibernate:
      ddl-auto: create   # 개발 편의용. Flyway 도입 Task에서 validate로 전환
    properties:
      hibernate:
        format_sql: true
    show-sql: false

  kafka:
    bootstrap-servers: ${NOTIFICATION_KAFKA_BOOTSTRAP:localhost:9092}
    consumer:
      group-id: ${NOTIFICATION_KAFKA_GROUP:notification}
      auto-offset-reset: earliest
      key-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      value-deserializer: org.springframework.kafka.support.serializer.JsonDeserializer
      properties:
        spring.json.trusted.packages: "com.shop.*"
```

키 구조 의도:
- spring.datasource.*: 자기 소유 PostgreSQL placeholder. shop-core와 독립 인스턴스임을 명시하기 위해 포트 기본값을 5433으로 둔다(shop-core 5432와 구분; docker-compose Task에서 실제 포트 매핑 확정). 환경변수 미설정 시 로컬 기본값.
- spring.jpa.hibernate.ddl-auto: create: Flyway 도입 전까지 개발 편의 우선(shop-core plan 001과 동일 정책). Flyway 도입 Task에서 validate로 전환. 운영 적용 금지.
- spring.jpa.open-in-view: false: 명시적 트랜잭션 경계 강제.
- spring.kafka.consumer.*: notification은 컨슈머이므로 consumer 키만 둔다(producer 키 없음). JSON 역직렬화(CLAUDE.md 메시징 규약: JSON 직렬화). spring.json.trusted.packages 로 이벤트 페이로드 역직렬화 허용 패키지를 명시.
- server 블록 없음: web 제거로 내장 서버가 없으므로 server.port 를 두지 않는다.

> 주의: 위 datasource/kafka의 default 값은 "운영 가정"이며, 외부 인프라가 없으면 default 프로파일 부팅은 실패할 수 있다(연결 시도). 이 Task는 운영 부팅 검증을 요구하지 않으며, 테스트는 2-3의 test 프로파일로 인프라 없이 통과시킨다.

### 2-3. notification/src/test/resources/application.yml (신규)

테스트 시 외부 인프라 없이 컨텍스트가 뜨도록 자동 설정 제외:

```yaml
spring:
  autoconfigure:
    exclude:
      - org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration
      - org.springframework.boot.autoconfigure.orm.jpa.HibernateJpaAutoConfiguration
      - org.springframework.boot.autoconfigure.jdbc.DataSourceTransactionManagerAutoConfiguration
      - org.springframework.boot.autoconfigure.kafka.KafkaAutoConfiguration
```

설계 의도:
- 이 Task 범위는 의존성·설정·스모크 테스트뿐이다. H2·Testcontainers·EmbeddedKafka 도입은 별도 Task로 미룬다(트레이드오프 6-1).
- DataSource·JPA·Kafka 자동 설정을 테스트에서 제외해 인프라 없는 부팅을 보장한다.
- Modulith 관련 제외 항목은 notification에 없으므로 shop-core plan 001 대비 한 줄 적다.

### 2-4. notification/src/test/java/com/shop/notification/NotificationApplicationTests.java (수정)

```java
package com.shop.notification;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;

@SpringBootTest
@ActiveProfiles("test")
class NotificationApplicationTests {

    @Test
    void contextLoads() {
    }
}
```

@ActiveProfiles("test")는 src/test/resources/application.yml 이 자동 적용되더라도 의도를 명시하고, 향후 application-test.yml 로 분리 시 즉시 호환되도록 한다.

---

## 3. 데이터 흐름 (부팅 시 자동 설정 경로)

비즈니스 데이터 흐름(이벤트 소비·발송)은 이 Task 범위 밖이다. 부팅 시 자동 설정 흐름만 정리한다.

```
NotificationApplication.main()
  -> SpringApplication.run
       1) Environment 로드 (application.yml + 환경변수 placeholder 해석)
       2) 웹 서버 미기동 (starter-web 제거 -> non-web ApplicationContext)
       3) AutoConfiguration import 후보 수집
            - ValidationAutoConfiguration        <- starter-validation
            - DataSourceAutoConfiguration        <- starter-data-jpa + postgresql
            - HibernateJpaAutoConfiguration      <- starter-data-jpa
            - KafkaAutoConfiguration             <- spring-kafka
       4) (default 프로파일) DataSource -> EntityManagerFactory -> JpaTransactionManager
                              ConsumerFactory -> KafkaListenerContainerFactory
                              (실제 DB/broker 연결 시도)
       5) (test 프로파일) DataSource·JPA·Kafka 자동 설정 제외
                          -> DataSource/JPA/Kafka 빈 미생성
                          -> Validation 자동 설정만 활성화된 최소 컨텍스트 부팅
```

핵심: 향후 진입점은 Consumer -> Service -> Repository (CLAUDE.md notification 레이어 규약)이지만, 이 Task에서는 컨슈머·엔티티·Repository를 구현하지 않는다. 테스트 환경의 흐름은 "외부 의존성이 차단된 최소 컨텍스트"이며, 이것이 스모크 테스트(contextLoads)의 성공 조건이다.

---

## 4. 예외 처리 전략 (이 Task 범위: 부팅/연결 실패 관점)

이 Task에는 비즈니스 예외가 없다. "자동 설정 단계의 실패"를 다룬다. (CLAUDE.md "모든 예외는 RuntimeException 상속 커스텀 예외로 변환"·"공통 에러 응답은 REST에서만"은 후속 컨슈머/서비스 Task에서 적용; notification은 REST가 없으므로 공통 에러 응답 포맷 대상이 아니다.)

### 4-1. 의존성 누락
- 모든 라이브러리 버전을 Boot BOM이 관리하므로 개별 GAV에 버전을 박지 않아 충돌 표면을 최소화한다. Modulith BOM이 없으므로 import 충돌 위험도 없다.

### 4-2. DataSource 자동 설정 실패
- starter-data-jpa가 포함되면 DataSourceAutoConfiguration이 DataSource 빈을 만들어야 하며, 풀리지 않으면 컨텍스트 부팅이 실패한다.
- 운영(default): placeholder 기본값으로 드라이버 로딩 단계까지는 통과. 실제 연결 실패는 HikariCP의 lazy connection 동작에 의존(이 Task는 운영 부팅 검증을 요구하지 않음).
- 테스트(test): DataSourceAutoConfiguration·HibernateJpaAutoConfiguration·DataSourceTransactionManagerAutoConfiguration을 제외해 DataSource 빈 자체가 생성되지 않게 한다 -> DB 없이 부팅.

### 4-3. Kafka 자동 설정 실패
- spring-kafka가 클래스패스에 있으면 KafkaAutoConfiguration이 ConsumerFactory·KafkaListenerContainerFactory를 만든다. broker 미연결만으로 부팅이 즉시 실패하지는 않으나, @KafkaListener 컨테이너가 자동 기동되면 broker 연결을 재시도한다.
- 이 Task에는 @KafkaListener가 없으므로 컨테이너가 없다. 그래도 테스트의 결정성을 위해 test 프로파일에서 KafkaAutoConfiguration을 제외해 컨슈머 부트스트랩 시도를 원천 차단한다.

### 4-4. web 제거로 인한 부팅 타입
- web 제거 후 @SpringBootTest는 비-웹 컨텍스트로 동작한다. 별도 처리 없이 contextLoads가 통과한다.

---

## 5. 검증 방법

### 5-1. 빌드/테스트 명령
작업 위치: shop/ (워크스페이스 루트). 실행 위치: notification/.

PowerShell:

```powershell
cd C:\side-project\shop\notification
.\gradlew clean test
```

### 5-2. 스모크 테스트 최소 형태
기존 NotificationApplicationTests를 활용하되 @ActiveProfiles("test")를 추가한다. 이 한 테스트가:
- @SpringBootTest로 ApplicationContext를 로드한다 -> 의존성 해석·자동 설정 호환성 검증.
- src/test/resources/application.yml 이 DataSource·JPA·Kafka 자동 설정을 제외 -> 외부 PostgreSQL/Kafka 없이 PASS.
- contextLoads() 빈 메서드 — 컨텍스트 로드 자체가 검증 단위.

### 5-3. 외부 인프라 없이 통과시키는 처리
- 채택: test 프로파일에서 자동 설정 제외.
  - 장점: 의존성·인프라 도입 0건. Task 범위 최소화. shop-core와 일관.
  - 단점: 실제 JPA/Kafka 동작은 후속 Task에서 별도 검증 필요.
- 비채택: H2 임시·EmbeddedKafka·Testcontainers (트레이드오프 6-1).

### 5-4. 완료 판정 기준
- ./gradlew clean test exit code 0, 콘솔에 BUILD SUCCESSFUL.
- 의존성 해석 실패(Could not resolve)·BeanCreation 실패 메시지 없음.
- 외부 PostgreSQL·Kafka가 기동되어 있지 않아도 통과.

### 5-5. Acceptance Criteria 매핑 검증 체크리스트
Task 문서의 Acceptance Criteria <-> 검증 방법 매핑:

| Acceptance Criteria | 검증 방법 |
|---|---|
| Gradle 의존성 해석이 성공한다 | ./gradlew clean test 가 Could not resolve 없이 진행 |
| 애플리케이션 컨텍스트가 로드된다 | contextLoads() PASS (@SpringBootTest + @ActiveProfiles("test")) |
| 기본 테스트가 통과한다 | BUILD SUCCESSFUL, exit code 0 |
| 이벤트 소비와 JPA 개발에 필요한 의존성이 준비된다 | build.gradle에 data-jpa·postgresql·spring-kafka·validation·spring-kafka-test 존재 |

---

## 6. 트레이드오프

### 6-1. 테스트 인프라: 자동 설정 제외 vs H2 vs EmbeddedKafka vs Testcontainers
| 선택지 | 장점 | 단점 | 채택? |
|---|---|---|---|
| 자동 설정 제외 (test 프로파일) | 0 의존성. 즉시 통과. Task 범위에 부합. shop-core와 일관 | 실제 DB/Kafka 동작 검증 불가 | O |
| H2 임시 도입 | JPA 부팅까지 실제 검증 | PostgreSQL 방언 차이, 후속 마이그레이션 부담 | X |
| EmbeddedKafka(@EmbeddedKafka) | 실제 컨슈머 통합 검증 | 이 Task엔 컨슈머가 없어 검증 대상 부재. 빌드 시간 증가 | X (후속 Consumer Task) |
| Testcontainers | 운영 동일 PostgreSQL/Kafka 검증 | Docker 의존, 빌드 시간 증가, 범위 초과 | X (별도 Task) |

spring-kafka-test는 의존성만 추가해 후속 Consumer Task에서 @EmbeddedKafka로 즉시 활용 가능하게 둔다.

### 6-2. spring-boot-starter-web 제거 vs 유지
- 제거 채택. notification은 REST 없는 순수 컨슈머(CLAUDE.md)이므로 내장 웹 서버·HTTP 표면이 불필요. 포트 점유·공격 표면을 줄인다.
- 유지 시 장점: actuator HTTP 헬스 체크를 바로 붙일 수 있음.
- 제거로 인한 공백(헬스/관측성)은 운영 관측성 Task에서 actuator(+필요 시 web/webflux)로 별도 도입한다. 이 Task Requirements 밖.

### 6-3. application.yml 전환 vs application.properties 유지
- yml 전환 채택. 중첩 키 가독성·멀티-도큐먼트 프로파일 분리·shop-core와의 워크스페이스 일관성. 단일 키 properties는 datasource/kafka 키가 늘면서 부담.

### 6-4. spring.jpa.hibernate.ddl-auto: create vs validate vs none
- create 채택(shop-core plan 001과 동일 정책). Flyway 도입 전까지 엔티티 추가/수정 시 즉시 스키마 반영하는 개발 편의 우선.
- Flyway 도입 Task에서 validate로 전환을 강제(주석으로 명시). 운영 적용 금지(매 부팅 DROP·재생성).
- test 프로파일에서는 JPA 자동 설정이 제외되므로 이 키는 무영향.

### 6-5. Kafka producer 키 미포함
- notification은 컨슈머 전용(단방향, docs/architecture.md 라인 44). 따라서 spring.kafka.consumer.* 만 두고 producer 키는 두지 않는다. DLQ 재발행 등으로 프로듀서가 필요해지면 후속 Task에서 추가.

### 6-6. Modulith/Security/Thymeleaf 미포함
- 이들은 shop-core(모듈러 모놀리스·View·인증) 전용이며 notification 역할과 무관. 추가 시 불필요한 자동 설정·부팅 비용만 늘린다. CLAUDE.md notification 규약에 부합하게 제외.

---

## 완료 조건 체크리스트

- [ ] notification/build.gradle 에서 spring-boot-starter-web 이 제거되었다
- [ ] notification/build.gradle 에 data-jpa·postgresql(runtimeOnly)·spring-kafka·validation이 추가되었다
- [ ] 테스트 의존성에 spring-kafka-test 가 추가되었고 기존 spring-boot-starter-test 가 유지되었다
- [ ] 의존성이 // Persistence·// Messaging·// Validation·// Lombok·// Test 주석으로 그룹핑되었다 (shop-core 스타일)
- [ ] Modulith BOM·milestone 레포 등 notification에 불필요한 항목을 추가하지 않았다
- [ ] notification/src/main/resources/application.properties 가 삭제되고 application.yml 로 대체되었다
- [ ] application.yml 에 datasource(독립 인스턴스)·jpa·kafka consumer 키가 placeholder와 함께 정의되었다 (producer 키 없음, server 블록 없음)
- [ ] spring.jpa.hibernate.ddl-auto 가 create 이며 Flyway 도입 시 validate 전환 주석이 명시되었다
- [ ] notification/src/test/resources/application.yml 에 DataSource·JPA·Kafka 자동 설정 제외가 들어갔다
- [ ] NotificationApplicationTests 에 @ActiveProfiles("test") 가 적용되었다
- [ ] 컨슈머·엔티티·Repository·DTO 등 도메인 코드를 추가하지 않았다 (의존성·설정·스모크 테스트 범위 한정)
- [ ] Flyway/Liquibase·actuator 등 범위 밖 의존성을 추가하지 않았다
- [ ] 이벤트 계약(docs/architecture.md)을 변경하지 않았다
- [ ] cd notification && ./gradlew clean test 실행 시 BUILD SUCCESSFUL 로 종료된다
- [ ] 외부 PostgreSQL·Kafka가 기동되어 있지 않아도 테스트가 통과한다

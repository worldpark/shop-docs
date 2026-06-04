# 001. shop-core 의존성 베이스라인 — 구현 Plan

## 구현 목표
`shop-core`에 JPA·PostgreSQL·Validation·Thymeleaf·Security·Spring Modulith·Spring Kafka 의존성을 추가하고, 외부 인프라(DB·Kafka) 없이도 컨텍스트가 로드·테스트되는 베이스라인을 구성한다.

## 영향 범위
- 신규 파일
  - `shop-core/src/main/resources/application.yml` (기존 `application.properties`는 삭제)
  - `shop-core/src/test/resources/application.yml` (테스트 자동 적용 — 외부 인프라 차단)
- 수정 파일
  - `shop-core/build.gradle` — 의존성/플러그인/BOM/dependencyManagement 추가
  - `shop-core/src/test/java/com/shop/shop/ShopCoreApplicationTests.java` — 테스트 프로파일·자동 설정 제외 강화
- 삭제 파일
  - `shop-core/src/main/resources/application.properties` (yml로 일원화)

---

## 1. 설계 방식 및 이유

### 1-1. 왜 이 의존성 세트인가
Task Requirements가 명시한 7개(JPA, PostgreSQL, Validation, Thymeleaf, Spring Security, Spring Modulith, Spring Kafka)는 `shop-core`의 향후 Phase 0~N 도메인(회원·상품·장바구니·주문·결제·재고) 구현에 필수 선행 조건이다.

- **spring-boot-starter-data-jpa**: 회원/상품/주문 등 모든 도메인 Repository 기반.
- **postgresql (runtimeOnly)**: 운영 DB 드라이버. 컴파일 시점에 노출되지 않도록 runtimeOnly 스코프.
- **spring-boot-starter-validation**: REST DTO·폼 DTO `@Valid` 처리. Spring Boot 3.x부터는 web에 포함되지 않으므로 명시적으로 추가.
- **spring-boot-starter-thymeleaf**: `CLAUDE.md`의 ViewController → Thymeleaf SSR 규약.
- **spring-boot-starter-security**: 회원/주문 인증·인가의 기반.
- **thymeleaf-extras-springsecurity6**: ViewController가 보안 컨텍스트를 템플릿에서 표현(`sec:authorize`)하기 위한 표준 통합. Security와 Thymeleaf가 동시에 들어가는 시점부터 사실상 필수. 트레이드오프 섹션 참고.
- **spring-modulith-starter-core**: `CLAUDE.md`의 "도메인 경계는 Spring Modulith 모듈로 분리" 규약 충족.
- **spring-modulith-starter-jpa**: Outbox(Event Publication Registry)의 JPA 저장소 구현. `CLAUDE.md` "Transactional Outbox(Spring Modulith Event Publication Registry)로 이벤트 발행" 규약 충족.
- **spring-kafka**: Producer/Consumer 기반. (shop-core는 프로듀서만이지만 통합 시 Producer는 `spring-kafka` 모듈로 제공됨.)
- 테스트: `spring-boot-starter-test`, `spring-security-test`, `spring-modulith-starter-test`, `spring-kafka-test`(EmbeddedKafka 옵션 보유).

### 1-2. BOM/버전 관리
- Spring Boot 3.5.15-SNAPSHOT의 `spring-boot-dependencies`가 `spring-kafka` 버전을 관리하므로 별도 버전 명시 불필요.
- **Spring Modulith는 Boot가 관리하지 않으므로 `spring-modulith-bom`을 `dependencyManagement`로 import**한다. 버전: `1.3.1` (Boot 3.5와 호환되는 안정 라인). 트레이드오프 섹션 참고.
- `thymeleaf-extras-springsecurity6`는 Boot BOM이 버전 관리.

### 1-3. application.yml을 만드는 이유
- 운영/개발/테스트별 키 묶음(스프링 자동 설정 입력값)을 명확히 분리해야 하며, 향후 다중 프로파일 확장(yml은 멀티-도큐먼트 분리에 우수)이 필요함.
- 기존 `application.properties`는 단일 키만 있으므로 yml로 일원화한다.

### 1-4. Profile 전략
- `default`: 로컬 개발 가정. PostgreSQL/Kafka 연결 정보는 키만 선언하고 환경변수 placeholder로 둔다 (`${...}`). 부팅 시 외부 인프라가 있어야 정상 동작 — 이 단계의 운영 가정.
- `test`: `src/test/resources/application.yml`에서 외부 인프라 자동 설정을 비활성화. DataSource 자동 구성 제외, Kafka·Modulith·Security 자동 구성도 컨텍스트가 뜨도록 최소 조정. CI/로컬 모두에서 인프라 없이 `./gradlew test` 통과를 보장한다.
- `prod`: 이 Task 범위 밖. 키 윤곽만 default에 두고 실제 값은 환경변수.

---

## 2. 구성 요소 (파일·설정)

### 2-1. `shop-core/build.gradle` 변경 사항

추가/변경 항목:

```groovy
plugins {
    id 'java'
    id 'org.springframework.boot' version '3.5.15-SNAPSHOT'
    id 'io.spring.dependency-management' version '1.1.7'
}

group = 'com.shop'
version = '0.0.1-SNAPSHOT'
description = 'shop-core'

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(21)
    }
}

ext {
    set('springModulithVersion', '1.3.1')
}

repositories {
    mavenCentral()
    maven { url = 'https://repo.spring.io/snapshot' }
    maven { url = 'https://repo.spring.io/milestone' }
}

dependencyManagement {
    imports {
        mavenBom "org.springframework.modulith:spring-modulith-bom:${springModulithVersion}"
    }
}

dependencies {
    // Web / View
    implementation 'org.springframework.boot:spring-boot-starter-web'
    implementation 'org.springframework.boot:spring-boot-starter-thymeleaf'
    implementation 'org.thymeleaf.extras:thymeleaf-extras-springsecurity6'

    // Validation
    implementation 'org.springframework.boot:spring-boot-starter-validation'

    // Security
    implementation 'org.springframework.boot:spring-boot-starter-security'

    // Persistence
    implementation 'org.springframework.boot:spring-boot-starter-data-jpa'
    runtimeOnly   'org.postgresql:postgresql'

    // Modulith (모듈 경계 + Outbox)
    implementation 'org.springframework.modulith:spring-modulith-starter-core'
    implementation 'org.springframework.modulith:spring-modulith-starter-jpa'

    // Messaging
    implementation 'org.springframework.kafka:spring-kafka'

    // Lombok
    compileOnly       'org.projectlombok:lombok'
    annotationProcessor 'org.projectlombok:lombok'

    // Test
    testImplementation 'org.springframework.boot:spring-boot-starter-test'
    testImplementation 'org.springframework.security:spring-security-test'
    testImplementation 'org.springframework.modulith:spring-modulith-starter-test'
    testImplementation 'org.springframework.kafka:spring-kafka-test'
    testCompileOnly   'org.projectlombok:lombok'
    testAnnotationProcessor 'org.projectlombok:lombok'
    testRuntimeOnly   'org.junit.platform:junit-platform-launcher'
}

tasks.named('test') {
    useJUnitPlatform()
}
```

GAV 정리:

| Group | Artifact | Scope | 버전 관리원 |
|---|---|---|---|
| org.springframework.boot | spring-boot-starter-web | implementation | Boot BOM |
| org.springframework.boot | spring-boot-starter-thymeleaf | implementation | Boot BOM |
| org.thymeleaf.extras | thymeleaf-extras-springsecurity6 | implementation | Boot BOM |
| org.springframework.boot | spring-boot-starter-validation | implementation | Boot BOM |
| org.springframework.boot | spring-boot-starter-security | implementation | Boot BOM |
| org.springframework.boot | spring-boot-starter-data-jpa | implementation | Boot BOM |
| org.postgresql | postgresql | runtimeOnly | Boot BOM |
| org.springframework.modulith | spring-modulith-starter-core | implementation | Modulith BOM (1.3.1) |
| org.springframework.modulith | spring-modulith-starter-jpa | implementation | Modulith BOM (1.3.1) |
| org.springframework.kafka | spring-kafka | implementation | Boot BOM |
| org.springframework.boot | spring-boot-starter-test | testImplementation | Boot BOM |
| org.springframework.security | spring-security-test | testImplementation | Boot BOM |
| org.springframework.modulith | spring-modulith-starter-test | testImplementation | Modulith BOM |
| org.springframework.kafka | spring-kafka-test | testImplementation | Boot BOM |

### 2-2. `shop-core/src/main/resources/application.yml` (신규)

기존 `application.properties` 삭제 후 다음으로 대체:

```yaml
spring:
  application:
    name: shop-core

  datasource:
    url: ${SHOP_CORE_DB_URL:jdbc:postgresql://localhost:5432/shop_core}
    username: ${SHOP_CORE_DB_USERNAME:shop_core}
    password: ${SHOP_CORE_DB_PASSWORD:shop_core}
    driver-class-name: org.postgresql.Driver

  jpa:
    open-in-view: false
    hibernate:
      ddl-auto: create   # 개발 편의용. Flyway 도입 Task에서 validate로 전환 (Revision 1, 항목 4)
    properties:
      hibernate:
        format_sql: true
    show-sql: false

  thymeleaf:
    cache: false

  kafka:
    bootstrap-servers: ${SHOP_CORE_KAFKA_BOOTSTRAP:localhost:9092}
    producer:
      key-serializer: org.apache.kafka.common.serialization.StringSerializer
      value-serializer: org.springframework.kafka.support.serializer.JsonSerializer

server:
  port: 8080
```

키 구조 의도:
- `spring.datasource.*`: PostgreSQL placeholder. 환경변수 미설정 시 로컬 기본값.
- `spring.jpa.hibernate.ddl-auto: create`: Flyway 도입 전까지 개발 편의 우선. 부팅 시 테이블 DROP 후 재생성됨에 유의 (로컬 개발 DB 데이터 초기화). Flyway 도입 Task에서 `validate`로 전환 (Revision 1, 항목 4).
- `spring.jpa.open-in-view: false`: 명시적 트랜잭션 경계 강제.
- `spring.thymeleaf.cache: false`: 개발 편의(운영은 profile에서 override 예정).
- `spring.kafka.*`: JSON 직렬화(`CLAUDE.md` 메시징 규약).

### 2-3. `shop-core/src/test/resources/application.yml` (신규)

테스트 시 외부 인프라 없이 컨텍스트가 뜨도록 자동 설정 제외 + 키 무력화:

```yaml
spring:
  autoconfigure:
    exclude:
      - org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration
      - org.springframework.boot.autoconfigure.orm.jpa.HibernateJpaAutoConfiguration
      - org.springframework.boot.autoconfigure.jdbc.DataSourceTransactionManagerAutoConfiguration
      - org.springframework.boot.autoconfigure.kafka.KafkaAutoConfiguration
      - org.springframework.modulith.events.jpa.JpaEventPublicationAutoConfiguration

  thymeleaf:
    check-template-location: false
```

설계 의도:
- 이 Task 범위는 의존성·설정·스모크 테스트뿐. Testcontainers나 EmbeddedKafka·H2 도입은 별도 Task로 미룬다 (트레이드오프 섹션).
- DataSource·JPA·Kafka·Modulith JPA Outbox 자동 설정을 테스트에서 제외해 인프라 없는 부팅을 보장.
- Security 자동 설정은 유지 — 기본 폼 로그인/HTTP Basic이 컨텍스트 부팅에 인프라를 요구하지 않음.
- `thymeleaf.check-template-location: false`: 템플릿 디렉터리가 없어도 부팅 실패하지 않도록.

### 2-4. `shop-core/src/test/java/com/shop/shop/ShopCoreApplicationTests.java` (수정)

```java
package com.shop.shop;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;

@SpringBootTest
@ActiveProfiles("test")
class ShopCoreApplicationTests {

    @Test
    void contextLoads() {
    }
}
```

`@ActiveProfiles("test")`는 `src/test/resources/application.yml`이 자동 적용되더라도 명시적으로 의도를 박아두기 위함(향후 `application-test.yml`로 분리 시 즉시 호환).

---

## 3. 데이터 흐름 (부팅 시 자동 설정 순서)

비즈니스 데이터 흐름은 이 Task에 없다. 부팅 시 빈 등록·자동 설정 흐름만 정리:

```
ShopCoreApplication.main()
  └─ SpringApplication.run
       ├─ Environment 로드 (application.yml + 환경변수 placeholder 해석)
       ├─ AutoConfiguration import 후보 수집
       │    ├─ WebMvcAutoConfiguration            ← starter-web
       │    ├─ ValidationAutoConfiguration        ← starter-validation
       │    ├─ ThymeleafAutoConfiguration         ← starter-thymeleaf
       │    ├─ SecurityAutoConfiguration          ← starter-security
       │    ├─ DataSourceAutoConfiguration        ← starter-data-jpa + postgresql
       │    ├─ HibernateJpaAutoConfiguration      ← starter-data-jpa
       │    ├─ KafkaAutoConfiguration             ← spring-kafka
       │    ├─ ModulithCore                       ← modulith-starter-core
       │    └─ JpaEventPublicationAutoConfiguration ← modulith-starter-jpa
       │
       ├─ (운영/default) DataSource → EntityManagerFactory → JpaTransactionManager
       │                 KafkaTemplate → ProducerFactory
       │                 SecurityFilterChain (default)
       │                 Modulith Event Publication Registry (JPA backed)
       │
       └─ (test 프로파일) 위 5개 자동 설정 제외 → DataSource/JPA/Kafka/Outbox 빈 미생성
                          → Security·Thymeleaf·Web 자동 설정만 활성화된 빈 컨텍스트 부팅
```

핵심: 테스트 환경의 흐름은 "외부 의존성 차단된 최소 컨텍스트"이며, 이는 스모크 테스트(`contextLoads`)의 성공 조건이다.

---

## 4. 예외 처리 전략

이 Task는 비즈니스 예외가 없으므로 "자동 설정 단계의 실패"를 다룬다.

### 4-1. 의존성 누락
- BOM(Boot, Modulith)이 모든 라이브러리 버전을 관리. 개별 GAV에 버전을 박지 않아 충돌 표면을 최소화.
- 누락 가능성이 가장 높은 것은 Spring Modulith BOM. `dependencyManagement.imports`로 import해 컴파일·런타임 모두에서 버전을 일치시킨다.

### 4-2. 자동 설정 충돌
- `spring-boot-starter-data-jpa`가 포함되면 `DataSourceAutoConfiguration`은 DataSource 빈을 반드시 만들어야 하며, URL/드라이버가 풀리지 않으면 컨텍스트가 **부팅 실패**한다.
- 운영(default): `application.yml`의 placeholder 환경변수가 비어도 기본값(`jdbc:postgresql://localhost:5432/shop_core`)을 박아 적어도 드라이버 로딩 단계까지는 통과. 실제 연결 실패는 HikariCP의 lazy connection 처리(`spring.datasource.hikari.initialization-fail-timeout` 기본 동작) 가정 — 이 Task에서는 운영 부팅 검증을 요구하지 않는다.
- 테스트(test): `DataSourceAutoConfiguration`·`HibernateJpaAutoConfiguration`·`DataSourceTransactionManagerAutoConfiguration`·`JpaEventPublicationAutoConfiguration`를 모두 제외해 DataSource 빈 자체가 만들어지지 않게 한다.

### 4-3. Kafka 자동 설정 실패
- `spring-kafka`가 클래스패스에 있으면 `KafkaAutoConfiguration`은 `ProducerFactory`·`ConsumerFactory`를 만들지만, broker 미연결 시 즉시 실패하지는 않는다 (실제 send 시점에 실패). 따라서 컨텍스트 부팅 자체는 OK.
- 다만 일부 Modulith·Kafka 통합 빈이 broker 가용성을 기대하는 케이스를 차단하기 위해 테스트 프로파일에서 `KafkaAutoConfiguration`도 제외.

### 4-4. Modulith Outbox 자동 설정 실패
- `spring-modulith-starter-jpa`는 `event_publication` 테이블을 가정하는 빈을 생성. 테스트에서 DataSource를 제거하면 이 빈도 함께 실패하므로 `JpaEventPublicationAutoConfiguration`을 명시적으로 제외.

### 4-5. Security 기본 자동 설정
- `starter-security`는 모든 엔드포인트를 기본적으로 인증 요구로 잠그지만 컨텍스트 부팅은 항상 성공. 스모크 테스트는 엔드포인트 호출을 하지 않으므로 추가 처리 불필요.

---

## 5. 검증 방법

### 5-1. 빌드/테스트 명령

작업 위치: `shop/` (워크스페이스 루트). 실행 위치: `shop-core/`.

PowerShell:

```powershell
cd C:\side-project\shop\shop-core
.\gradlew clean test
```

### 5-2. 스모크 테스트 최소 형태

기존 `ShopCoreApplicationTests`를 그대로 활용하되 `@ActiveProfiles("test")` 추가. 이 한 테스트가:

- `@SpringBootTest`로 전체 ApplicationContext를 로드한다 → 의존성 해석·자동 설정 호환성 검증.
- `src/test/resources/application.yml`이 인프라 자동 설정을 제외 → 외부 PostgreSQL/Kafka 없이 PASS.
- `contextLoads()` 빈 메서드 — 컨텍스트 로드 자체가 검증 단위.

### 5-3. 외부 인프라 없이 통과시키기 위한 처리
- **선택지: 테스트 프로파일에서 자동 설정 제외** (이 Task 채택)
  - 장점: 의존성·인프라 도입 0건. Task 범위 최소화.
  - 단점: 실제 JPA/Kafka 동작은 후속 Task에서 별도 검증 필요.
- 비채택: Testcontainers, H2 임시, EmbeddedKafka → 트레이드오프 섹션.

### 5-4. 완료 판정 기준
- `./gradlew test` exit code 0.
- 콘솔 출력에 `BUILD SUCCESSFUL`.
- 의존성 해석 실패(`Could not resolve`)·BeanCreation 실패 메시지 없음.

---

## 6. 트레이드오프

### 6-1. Testcontainers vs H2 vs 자동 설정 제외
| 선택지 | 장점 | 단점 | 채택? |
|---|---|---|---|
| 자동 설정 제외 (test 프로파일) | 0 의존성. 즉시 통과. Task 범위에 부합 | 실제 DB/Kafka 동작은 검증 불가 | O |
| H2 임시 도입 | JPA 부팅까지 실제 검증 | PostgreSQL과 방언 차이. 후속 마이그레이션 부담 | X |
| Testcontainers | 운영과 동일 PostgreSQL/Kafka 검증 | Docker 의존, 빌드 시간↑. 이 Task 범위 초과 | X (별도 Task 권장) |

### 6-2. Spring Modulith: BOM import vs 개별 버전 명시
- **BOM import 채택**. 이유: `spring-modulith-starter-core`/`starter-jpa`/`starter-test` 3개 아티팩트를 같이 쓰므로 단일 버전 관리원이 안전. 단일 모듈만 쓸 거면 GAV에 버전 박는 편이 단순하나 Outbox와 테스트가 동시에 들어오는 본 구성에선 BOM이 유리.

### 6-3. `thymeleaf-extras-springsecurity6` 지금 포함 vs 보류
- **지금 포함 채택**. 이유:
  - 이 Task는 의존성 베이스라인이며, 후속 ViewController Task가 시작되자마자 보안 컨텍스트를 템플릿에서 표현할 가능성이 매우 높음 (`sec:authorize`, `${#authentication}`).
  - Boot BOM 관리 라이브러리라 추가 비용·충돌 위험이 거의 없음.
- 보류 시 단점: 후속 화면 Task에서 의존성 추가 PR이 한 번 더 발생.

### 6-4. `spring.jpa.hibernate.ddl-auto`: `validate` vs `create` vs `none`
- **`create` 채택** (Revision 1, 항목 4 — 사용자 결정). Flyway 도입은 별도 후속 Task로 예정되어 있으며, 그 전까지는 엔티티 추가/수정 시 즉시 스키마가 반영되는 **개발 편의**를 우선시한다.
- Flyway 도입 Task의 Acceptance Criteria에 "`ddl-auto`를 `validate`로 전환"을 포함시켜 전환 시점을 강제한다.
- 운영 환경 적용 절대 금지(매 부팅마다 테이블 DROP·재생성). 운영 배포 전 반드시 `validate` 또는 `none`으로 전환.
- 테스트 프로파일에서는 JPA 자동 설정이 제외되므로 이 키는 무영향.

### 6-5. `application.yml`로 통합 vs `application.properties` 유지
- **yml 통합 채택**. 멀티-도큐먼트 프로파일 분리·중첩 키 가독성·Spring 표준 권장. 단일 키 properties는 베이스라인을 넘어선 후속 Task에서 부담.

### 6-6. EmbeddedKafka 도입 시점
- 이 Task에서는 미도입. `spring-kafka-test`는 의존성만 추가해 후속 Producer Task에서 `@EmbeddedKafka`로 즉시 활용 가능하게 둠.

---

## 완료 조건 체크리스트

- [ ] `shop-core/build.gradle`에 JPA·PostgreSQL(runtimeOnly)·Validation·Thymeleaf·Thymeleaf-Security·Security·Modulith(core+jpa)·Kafka 의존성이 모두 추가되었다
- [ ] `dependencyManagement`로 `spring-modulith-bom:1.3.1`이 import되었다
- [ ] `spring.io/snapshot` 및 `spring.io/milestone` 레포지토리가 등록되었다
- [ ] 테스트 의존성에 `spring-security-test`·`spring-modulith-starter-test`·`spring-kafka-test`가 포함되었다
- [ ] `shop-core/src/main/resources/application.properties`가 삭제되고 `application.yml`로 대체되었다
- [ ] `application.yml`에 datasource/jpa/thymeleaf/kafka/server 기본 키가 placeholder와 함께 정의되었다
- [ ] `spring.jpa.hibernate.ddl-auto`가 `create`로 설정되었고, 주석으로 Flyway 도입 시 `validate`로 전환할 것이 명시되었다 (Revision 1, 항목 4)
- [ ] `shop-core/src/test/resources/application.yml`에 DataSource·JPA·Kafka·Modulith JPA Outbox 자동 설정 제외 설정이 들어갔다
- [ ] `ShopCoreApplicationTests`에 `@ActiveProfiles("test")`가 적용되었다
- [ ] 비즈니스 도메인 코드(Member·Product·Order 등)·Controller·Entity·Repository를 추가하지 않았다
- [ ] Flyway/Liquibase 등 마이그레이션 도구를 추가하지 않았다
- [ ] 이벤트 계약(`docs/architecture.md` 섹션 5)을 변경하지 않았다
- [ ] `cd shop-core && ./gradlew clean test` 실행 시 `BUILD SUCCESSFUL`로 종료된다
- [ ] 외부 PostgreSQL·Kafka가 기동되어 있지 않아도 테스트가 통과한다

# 004. Flyway 스키마 관리 전환 — 구현 Plan

> 영역: infra (Flyway 마이그레이션 도입 + DB 스키마 소유권 전환 + Hibernate validate + 테스트 비파괴)
> 대상 프로젝트: workspace (shop-core + notification 두 레포에 걸친 인프라 Task. REST/화면 작업 없음)
> 작성일: 2026-06-03
> 상태: plan only (코드 변경 없음)

---

## 구현 목표
`shop-core`와 `notification`의 DB 스키마 소유권을 Hibernate 자동 생성(`ddl-auto=create`)에서 **Flyway 마이그레이션(`V1__init_schema.sql`)** 으로 전환한다. shop-core는 `docs/entity/database_design.md` 정본대로 도메인 18테이블 + Outbox `event_publication` 1테이블(총 19개)을 V1에 생성하고, notification은 **현재 구현된 자기 소유 테이블(`processed_event`)만** 생성한다. 양 프로젝트 모두 `ddl-auto=validate`로 전환해 Hibernate는 검증만 수행하며, 기존 테스트 컨텍스트(DB 없는 로드 + notification H2 슬라이스)가 깨지지 않도록 테스트 프로파일에서 Flyway를 비활성화한다.

## 영향 범위

### 신규 파일 (main)
- `shop-core/src/main/resources/db/migration/V1__init_schema.sql` — citext 확장 + 도메인 18테이블 + `event_publication` + 인덱스/CHECK/FK/partial unique index + `set_updated_at()` 함수 및 테이블별 트리거 (정본 미러링, V1 불변 헤더 주석)
- `notification/src/main/resources/db/migration/V1__init_schema.sql` — `processed_event` 1테이블만 + deviation 주석(시간 컬럼 앱 소유 사유)

### 신규 파일 (test, 선택적 보강)
- `shop-core/src/test/java/com/shop/shop/migration/FlywayMigrationScriptTest.java` — V1 스크립트 존재/베이스라인 네이밍/필수 토큰(citext, event_publication, set_updated_at) 정적 검증 (DB 불요). *구현 시 가치 판단 — 섹션 6 참조, 최소 보강 권장*
- `notification/src/test/java/com/shop/notification/migration/FlywayMigrationScriptTest.java` — V1 스크립트에 `processed_event`만 존재 + shop-core 도메인 테이블 토큰 부재 검증 (DB 불요)

### 수정 파일
- `shop-core/build.gradle` — `flyway-core` + `flyway-database-postgresql` 의존성 추가
- `shop-core/src/main/resources/application.yml` — `ddl-auto: validate`, `spring.flyway` 설정, `spring.modulith.events.jdbc.schema-initialization.enabled=false`
- `shop-core/src/test/resources/application.yml` — `FlywayAutoConfiguration` 제외(또는 `spring.flyway.enabled=false`) 추가 (DB 없는 컨텍스트 유지)
- `notification/build.gradle` — `flyway-core` + `flyway-database-postgresql` 의존성 추가
- `notification/src/main/resources/application.yml` — `ddl-auto: validate`, `spring.flyway` 설정
- `notification/src/test/resources/application.yml` — `FlywayAutoConfiguration` 제외(또는 `spring.flyway.enabled=false`) 추가
- `notification/src/test/java/com/shop/notification/service/EventProcessingServiceTransactionTest.java` — `@TestPropertySource`에 `spring.flyway.enabled=false` 추가 (H2 슬라이스가 Postgres 전용 V1을 실행하지 않도록 — **필수 보강**)
- `docs/entity/database_design.md` — V1 적용 사실/8장 운영 노트와 실제 산출물 정합(필요 시 event_publication 컬럼/타입을 Modulith 실제 매핑에 맞춰 미세 갱신)

### 범위 밖 (필요성만 명시, 후속 Task로 미룸)
- shop-core 도메인 `@Entity`/Repository/Service 신규 작성 (스키마만 선행, 엔티티는 후속 도메인 Task. **이 Task에서 도메인 기능 구현 금지**)
- notification 알림 발송 이력 / 실패·DLQ 추적 테이블 (현재 미구현 → V1에 만들지 않음. 후속 발송 도메인 Task에서 `V2__`로 추가)
- Flyway 검증용 Testcontainers 도입 (섹션 6 트레이드오프 — 본 Task는 수동/문서화 검증으로 충분)
- `flywayMigrate`/`flywayInfo` Gradle 태스크용 `org.flywaydb.flyway` Gradle 플러그인 (앱 기동 시 Spring Boot 자동 실행으로 충분. 플러그인은 선택)
- V2+ 스키마 진화, 보존 정책(완료 이벤트 정리), 시드 데이터

---

## 1. 설계 방식 및 이유

### 1.1 스키마 소유권 전환 — Flyway 단독 소유 + Hibernate는 validate
- `ddl-auto`를 양 프로젝트에서 `create` → `validate`로 바꾼다. 이후 스키마 생성/변경은 오직 Flyway `db/migration/V*.sql`가 담당하고, Hibernate는 부팅 시 매핑된 `@Entity`가 Flyway 생성 스키마와 일치하는지 **검증만** 한다(불일치 시 기동 실패 = 조기 안전망).
- `create`/`update` 유지 금지(Constraint). Flyway와 Hibernate가 동시에 스키마를 만들면 소유권이 모호해지고 `validate`와 양립 불가하므로, "스키마 소유권은 Flyway 하나" 원칙(database_design.md §8, §10)을 코드로 강제한다.
- Spring Boot는 클래스패스에 `flyway-core`가 있고 `DataSource`가 존재하면 `FlywayAutoConfiguration`이 활성화되어 **앱 기동 시 마이그레이션을 자동 실행**한다. 별도 Gradle 태스크 없이 기동만으로 마이그레이션 → validate 순서가 보장된다(Flyway는 JPA EntityManagerFactory보다 먼저 동작하도록 자동 정렬됨).

### 1.2 validate 전환의 안전성 (shop-core: 엔티티 부재 상태)
- 현재 shop-core에는 매핑된 도메인 `@Entity`가 없다(`common.BaseEntity`는 `@MappedSuperclass`라 테이블 아님, 도메인 패키지는 `package-info.java` 스켈레톤뿐). 따라서 `validate`는 검증할 도메인 매핑이 없어 도메인 18테이블에 대해서는 아무것도 검증하지 않는다.
- 결과: V1에 정본 전체 스키마를 미리 생성해도 **validate가 깨지지 않는다**(스키마가 엔티티보다 앞선 정상 상태). 후속 도메인 Task가 `@Entity`를 추가할 때 V1 스키마에 맞춰 매핑하면 validate가 점진적으로 실효를 갖는다. 이는 과도설계가 아니라 Task Requirement/Acceptance가 명시적으로 요구하는 "정본 기반 init schema"다.
- 단 **유일하게 매핑이 존재해 validate가 즉시 작동하는 대상**은 shop-core의 Modulith JPA Event Publication 엔티티(`event_publication`)다 → 1.3에서 정합을 다룬다.

### 1.3 Modulith `event_publication` 정합 — JPA 레지스트리 (Task 문구와 실제 구현의 불일치 해소)
- **불일치 포인트**: Task Requirement는 `spring.modulith.events.jdbc.schema-initialization.enabled=false`(JDBC 변형 가정)를 명시하나, shop-core build.gradle은 `spring-modulith-starter-jpa` + `spring-modulith-events-api/kafka`를 쓰는 **JPA 기반** Event Publication Registry다(JDBC 아님). 또한 test application.yml이 `org.springframework.modulith.events.jpa.JpaEventPublicationAutoConfiguration`을 제외하는 것이 JPA 변형의 증거다.
- **결정**:
  - (a) `event_publication`은 **Flyway가 소유**한다(V1에 포함). Modulith 자동 스키마 초기화에 맡기지 않는다(Constraint).
  - (b) JPA 변형에서는 JDBC용 `spring.modulith.events.jdbc.schema-initialization.enabled` 프로퍼티가 실효가 없을 수 있다. 그러나 Task가 명시했고 향후 JDBC 변형으로 바뀌어도 안전하며 부작용이 없으므로 **설정을 그대로 유지**하되, JPA 변형임을 yml 주석에 명시한다. (JPA 변형의 자동 DDL 생성은 `ddl-auto=validate`로 이미 차단되므로 추가 비활성 플래그가 불필요 — 이 점도 주석에 근거로 남긴다.)
  - (c) **validate 통과가 관건**: `ddl-auto=validate`면 Hibernate가 Modulith의 `JpaEventPublication` 엔티티 매핑(컬럼명/타입/nullable)을 Flyway 생성 `event_publication`에 대해 검증한다. 따라서 V1 DDL은 Modulith 1.3.x JPA 엔티티와 **정확히 일치**해야 한다.
- **구현 시 반드시 확인** (막히지 않을 기본값 + 확인 절차):
  - 기본값(database_design.md §4.7 기준): `id uuid PK`, `listener_id text NOT NULL`, `event_type text NOT NULL`, `serialized_event text NOT NULL`, `publication_date timestamptz NOT NULL`, `completion_date timestamptz NULL`.
  - 확인 절차: 의존성 jar(`spring-modulith-events-jpa`)에 동봉된 표준 스키마 리소스 또는 `org.springframework.modulith.events.jpa.JpaEventPublication` 엔티티의 실제 `@Column` 매핑(특히 컬럼명 케이스, `publication_date`/`completion_date`의 정확한 명칭, text vs varchar, nullable)을 열어 대조한다. 동봉 DDL이 있으면 그 DDL을 정본으로 삼아 V1에 옮긴다(직접 작성보다 안전 — 섹션 6).
  - 검증: 깨끗한 Postgres에 Flyway 적용 후 `ddl-auto=validate`로 shop-core 기동 → Modulith 엔티티 validate 통과 여부로 정합을 확정한다. 불일치 시 V1의 해당 컬럼 정의를 Modulith 매핑에 맞춰 수정한다(엔티티 매핑은 프레임워크 소유라 건드리지 않음 → DDL을 맞춘다).
  - 위험/대안: `validate`는 테이블 단위 제외가 불가하므로 "DDL을 정확히 일치"가 유일한 해법이다. 동봉 DDL과 §4.7이 다르면 **동봉 DDL(=실제 엔티티)이 우선**이며, 그 차이를 database_design.md §4.7에 반영한다.

### 1.4 `created_at` / `updated_at` 소유권 — 프로젝트별 차등 결정 (deviation 명시)
- **shop-core (정본대로 DB 소유)**: `created_at`/`updated_at`을 `timestamptz NOT NULL DEFAULT now()`로 두고, `set_updated_at()` 트리거 함수 1개 + `updated_at` 보유 테이블별 트리거로 갱신을 DB가 소유한다(§8). 향후 도메인 엔티티는 시간 컬럼을 **읽기 전용**(`@Column(insertable=false, updatable=false)`)으로 매핑한다. JPA가 직접 갱신하지 않는다(Constraint).
- **notification (앱 측 auditing 유지 — 이 Task에서 BaseEntity 변경 안 함)**:
  - notification `BaseEntity`는 Spring Data JPA auditing(`@CreatedDate`/`@LastModifiedDate`, `Instant`)으로 앱이 값을 채운다. 이는 Task 002 산출물이며, 이 Task에서 DB 트리거 소유로 리팩터링하면 **범위 초과**이고 `BaseEntityTest`(AuditingHandler 검증)·`JpaAuditingConfig` 등 002/005 산출물 파손 위험이 크다.
  - **결정**: notification `processed_event.created_at`/`updated_at`은 `timestamptz`로 두되 **트리거를 강제하지 않고 앱(JPA auditing)이 소유**한다. nullable은 `NOT NULL DEFAULT now()`로 둔다(앱 auditing이 항상 채우므로 NOT NULL이 안전하고, 혹시 누락돼도 DEFAULT가 2차 방어). 이는 BaseEntity 매핑(`Instant`, nullable 미지정)과 호환된다.
  - **근거 & deviation 처리**: `database_design.md`는 **shop-core 설계의 SSOT**이며, notification은 독립 인스턴스로서 자기 소유 테이블만 구조적으로 미러링한다. notification은 정본의 트리거 소유 모델과 의도적으로 다르므로, Constraint("정본과 다른 스키마는 SQL 주석/작업문서에 이유")에 따라 **notification V1 SQL 헤더 주석에 사유**(앱 측 JPA auditing 소유, 002 BaseEntity 정합, 범위 격리)를 남긴다.

### 1.5 테스트 프로파일 전략 — 가장 깨지기 쉬운 부분 (Flyway 비활성)
- **양 프로젝트 기본 test application.yml**: 현재 `DataSource`/`HibernateJpa`/`DataSourceTx`/`Kafka` 자동설정을 제외해 **DB 없이 컨텍스트를 로드**한다. 여기에 `flyway-core`가 클래스패스에 들어오면 `FlywayAutoConfiguration`이 활성 후보가 되어, DataSource가 없는데 Flyway가 동작하려다 컨텍스트가 깨질 수 있다.
  - 조치: 두 test application.yml의 `spring.autoconfigure.exclude`에 `org.springframework.boot.autoconfigure.flyway.FlywayAutoConfiguration`을 **추가**하거나, 더 견고하게 `spring.flyway.enabled=false`를 둔다. (둘 다 두면 가장 안전.)
- **notification `EventProcessingServiceTransactionTest` (005 산출물, 필수 보강)**:
  - 이 테스트는 `@DataJpaTest` + `@AutoConfigureTestDatabase(replace=ANY)` + H2 + `@TestPropertySource(spring.autoconfigure.exclude=)`로 **전체 exclude를 리셋**하고 `ddl-auto=create-drop`으로 실제 트랜잭션/유니크 제약/롤백을 검증한다.
  - 위험: exclude가 리셋되고 H2 `DataSource`가 존재하면 `FlywayAutoConfiguration`이 활성화되어 **Postgres 전용 V1 SQL(citext, partial index, trigger)을 H2에 실행 → 실패**하거나 `create-drop`과 충돌한다.
  - 조치(**필수**): 이 테스트의 `@TestPropertySource`에 `spring.flyway.enabled=false`를 추가해 Flyway를 끄고, 기존 H2 슬라이스(create-drop)가 그대로 동작하게 한다. 이 테스트는 H2 인메모리로 멱등/롤백 검증을 계속 수행한다(Flyway 검증은 별도 — 1.5 마지막).
- **shop-core 테스트**(Modulith verification/security/contextLoads 등)도 DB 없이 도므로 Flyway 비활성 유지로 충분하다.
- **마이그레이션 자체의 검증**: 단위/컨텍스트 테스트는 DB가 없으므로 V1 SQL의 실제 실행은 "깨끗한 로컬 Postgres + docker-compose 기동 후 앱 기동(Flyway 자동 실행) + validate 통과"로 **수동/문서화 검증**한다(섹션 5). Testcontainers로 자동화할 수도 있으나 본 Task 범위엔 과해 보류한다(섹션 6 트레이드오프).

### 1.6 shop-core V1 스키마 범위 — 정본 전체 19테이블
- database_design.md의 도메인 18테이블 + `event_publication`(총 19)을 V1에 생성한다. Task Requirement/Acceptance가 "정본의 도메인 테이블/제약/인덱스/트리거 반영 + event_publication 포함"을 명시하므로 과도설계가 아니다.
- 포함 요소: `CREATE EXTENSION IF NOT EXISTS citext`; 모든 테이블(`bigint GENERATED ALWAYS AS IDENTITY` PK); FK(ON DELETE 정책 정본대로: CASCADE/SET NULL/RESTRICT); CHECK 제약(enum=varchar+CHECK, 금액 ≥0, 수량 >0, rating 1~5, ends_at>starts_at 등); partial unique index(`addresses UNIQUE(user_id) WHERE is_default`, `product_images UNIQUE(product_id) WHERE is_primary`); 일반 인덱스(§9 전체); `variant_values` 복합 PK; `set_updated_at()` 함수 + `updated_at` 보유 테이블별 트리거(users/products/carts/orders/payments/reviews 등); 금액 `numeric(12,2)`, 시각 `timestamptz`.
- V1 헤더 주석에 **"적용 후 수정 금지, 변경은 V2+로 추가(checksum 불일치 방지)"** 규칙을 명시한다(§8). 동시성 노트(재고/쿠폰 조건부 업데이트)는 스키마가 아닌 애플리케이션 로직이므로 V1 SQL에는 `CHECK(stock>=0)` 등 2차 방어선만 반영하고, 조건부 업데이트는 후속 도메인 Task 책임임을 주석/문서로 남긴다.

### 1.7 V1 불변 / V2+ 규칙
- 적용된 마이그레이션 파일은 절대 수정하지 않는다(checksum). 모든 스키마 변경은 `V2__`, `V3__`…로 새 파일 추가. 이 규칙을 양 프로젝트 V1 SQL 헤더 주석 + database_design.md §8에 명문화한다.

---

## 2. 구성 요소

### 수정: 의존성 (build.gradle ×2)
- **flyway-core**: 두 프로젝트 모두 `implementation 'org.flywaydb:flyway-core'` 추가(버전은 Spring Boot 3.5.x BOM 관리에 위임 — 명시 버전 하드코딩 회피).
- **flyway-database-postgresql 필요 여부**: Flyway 10+(Spring Boot 3.3+ 동봉)부터 **Postgres 지원이 `flyway-database-postgresql` 별도 모듈로 분리**되었다. Postgres에 Flyway를 쓰려면 이 의존성이 사실상 필수다. 기본값으로 두 프로젝트 모두 `runtimeOnly 'org.flywaydb:flyway-database-postgresql'`을 추가한다(버전 BOM 위임).
  - **구현 시 확인**: 부팅 시 "No database found to handle jdbc:postgresql" 류 오류가 나면 이 모듈 누락이 원인이므로 추가로 해결한다. Spring Boot 3.5.x BOM이 버전을 관리하는지 확인하고, 미관리면 `flyway-core`와 동일 버전을 명시한다.

### 수정: main application.yml ×2
- **공통**: `spring.jpa.hibernate.ddl-auto: validate`. `spring.flyway`: `enabled: true`, `locations: classpath:db/migration`, `baseline-on-migrate: false`(깨끗한 DB 전제, 베이스라인 V1). 운영/개발 동일 적용(Acceptance: 운영/개발에서 validate).
- **shop-core 추가**: `spring.modulith.events.jdbc.schema-initialization.enabled: false`(Task 명시 — JPA 변형이라 무실효일 수 있음을 주석으로. validate가 자동 DDL을 이미 차단함도 주석). `modulith.events.externalization.enabled=true`는 유지.
- **datasource는 유지**(shop-core 5432 / notification 5433). DB 공유 금지 — 각 인스턴스 독립.

### 수정: test application.yml ×2
- `spring.autoconfigure.exclude`에 `FlywayAutoConfiguration` 추가 + `spring.flyway.enabled: false`. DB 없는 컨텍스트 로드 정책 유지(기존 exclude 항목 보존).
- notification `kafkatest` profile은 이미 DB 자동설정 제외(DB 없음)라 Flyway도 자연히 비활성이지만, 안전상 `spring.flyway.enabled=false`가 기본 test yml에서 상속되도록 둔다(프로파일 병합 확인 — 구현 시).

### 수정: notification EventProcessingServiceTransactionTest (필수)
- `@TestPropertySource(properties = { ..., "spring.flyway.enabled=false" })` 추가. 기존 H2 + `create-drop` 슬라이스를 보존하고 Postgres 전용 V1이 H2에 실행되지 않게 한다.

### 신규: shop-core V1__init_schema.sql
- 헤더 주석(V1 불변/V2+ 규칙, 정본 출처 명시) → `CREATE EXTENSION IF NOT EXISTS citext;` → `set_updated_at()` 함수 → 테이블 그룹별 DDL:
  1. 회원·인증: `users`(citext email UK, role CHECK), `addresses`(partial unique on is_default, user_id 인덱스)
  2. 카탈로그: `categories`(자기참조 FK SET NULL), `products`(category FK, status CHECK, base_price CHECK≥0, category/status 인덱스), `product_images`(partial unique on is_primary), `product_options`(UNIQUE(product_id,name)), `option_values`(UNIQUE(option_id,value)), `product_variants`(sku UK, price/stock CHECK), `variant_values`(복합 PK)
  3. 장바구니: `carts`(user_id UNIQUE), `cart_items`(UNIQUE(cart_id,variant_id), quantity CHECK>0)
  4. 주문·결제: `orders`(order_number UK, status CHECK, 금액 CHECK, 배송 스냅샷, user/status/created_at 인덱스), `order_items`(variant SET NULL, 스냅샷, order/variant 인덱스), `order_item_option_values`((option_name,option_value) 인덱스), `payments`(order_id UK, method/status CHECK)
  5. 쿠폰: `coupons`(code UK, discount_type CHECK, value CHECK>0, ends_at>starts_at CHECK), `user_coupons`(UNIQUE(user_id,coupon_id), 미사용 partial index)
  6. 리뷰: `reviews`(order_item_id UK 실구매 검증, rating CHECK 1~5, product/user 인덱스)
  7. 인프라: `event_publication`(Modulith 표준 컬럼 — 1.3 확인 결과 반영)
  - → `updated_at` 보유 테이블별 `CREATE TRIGGER trg_{table}_set_updated_at BEFORE UPDATE ... EXECUTE FUNCTION set_updated_at();`

### 신규: notification V1__init_schema.sql
- 헤더 주석: V1 불변/V2+ 규칙 + **deviation 주석**(시간 컬럼은 정본 트리거 모델과 달리 앱 JPA auditing이 소유 — 1.4 사유, 002 BaseEntity 정합, notification은 자기 소유 테이블만 미러링).
- `processed_event` 1테이블만:
  - `id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY`
  - `event_id uuid NOT NULL`, `UNIQUE(event_id)` (Entity의 `@UniqueConstraint(columnNames="event_id")` 정합)
  - `event_type varchar(255) NOT NULL` (Hibernate 기본 길이 정합)
  - `status varchar(255) NOT NULL CHECK (status IN ('PROCESSED','FAILED'))` (enum=varchar+CHECK; `@Enumerated(STRING)` 정합)
  - `failure_reason text` (nullable)
  - `created_at timestamptz NOT NULL DEFAULT now()`, `updated_at timestamptz NOT NULL DEFAULT now()` (앱 auditing 소유, 트리거 없음)
- **구현 시 확인**: ProcessedEvent의 실제 컬럼 길이/nullable/이름과 1:1 대조해 `validate` 통과를 보장한다. `status` CHECK 값은 `ProcessingStatus` enum 상수(`PROCESSED`,`FAILED`)와 일치시킨다.
- shop-core 도메인 테이블 복제 금지(Constraint) — 이 파일에는 `users`/`orders` 등 일절 없음.

### 신규: 마이그레이션 스크립트 정적 테스트 ×2 (선택적 보강)
- DB 없이 클래스패스의 V1 리소스를 읽어 (a) 파일 존재/네이밍(`V1__init_schema.sql`), (b) shop-core: `citext`/`event_publication`/`set_updated_at`/partial index 토큰 존재, (c) notification: `processed_event` 존재 + shop-core 도메인 테이블 토큰 부재(복제 금지 회귀 방지)를 문자열/정규식으로 검증. 컨텍스트 미기동이라 기존 exclude 정책과 무관.

### 수정: docs/entity/database_design.md
- §4.7/§8/§10이 이미 Flyway 소유·트리거·event_publication을 기술하므로 대규모 변경 불요. 1.3 구현 확인에서 event_publication 실제 컬럼/타입이 §4.7과 다르면 그 차이만 반영한다. notification deviation은 정본(shop-core 설계)에는 기술하지 않고 notification V1 SQL 주석에 남긴다(정본 SSOT 경계 유지).

---

## 3. 데이터 흐름

### 3.1 앱 기동 / 마이그레이션 흐름 (운영·개발)
```
앱 부팅 → Spring Boot DataSource 초기화
  → FlywayAutoConfiguration: db/migration/V*.sql 스캔
     → schema_history 비어있음 → V1__init_schema.sql 실행 (CREATE EXTENSION/테이블/인덱스/트리거)
     → flyway_schema_history에 V1 체크섬 기록
  → Hibernate EntityManagerFactory 초기화 (Flyway 이후)
     → ddl-auto=validate: 매핑된 @Entity ↔ Flyway 생성 스키마 대조
        - shop-core: 도메인 엔티티 없음(검증 대상 없음) + Modulith JpaEventPublication ↔ event_publication 검증
        - notification: ProcessedEvent ↔ processed_event 검증
  → validate 통과 시 컨텍스트 로드 완료
재기동 시: schema_history에 V1 있음 → 마이그레이션 skip → validate만 재수행
```

### 3.2 테스트 컨텍스트 흐름
```
[shop-core/notification 기본 test profile]
  spring.autoconfigure.exclude(DataSource/HibernateJpa/Kafka/Flyway) + flyway.enabled=false
  → DataSource·Flyway 미동작 → 기존대로 DB 없는 컨텍스트 로드 (비파괴)

[notification EventProcessingServiceTransactionTest]
  @DataJpaTest + H2(replace=ANY) + exclude 리셋 + ddl-auto=create-drop + flyway.enabled=false(보강)
  → Flyway off → H2가 create-drop으로 스키마 생성 → 멱등/유니크/롤백 검증 (기존 동작 유지)
```

### 3.3 shop-core Outbox event_publication 기동 흐름
```
도메인 트랜잭션 커밋 → Modulith가 event_publication에 미완료 행 insert(같은 트랜잭션)
  → 외부화(Kafka 발행) 성공 → completion_date 채움
event_publication 테이블은 V1(Flyway)이 생성, Modulith 자동 초기화는 비활성
  → ddl-auto=validate가 Modulith JPA 엔티티 매핑과 V1 DDL 일치를 부팅 시 검증
```

---

## 4. 예외 처리 전략 (실패 증상 / 진단 / 복구)

### 4.1 Hibernate validate 실패
- 증상: 부팅 시 `SchemaManagementException: Schema-validation: missing table/column [...]` 또는 타입 불일치. shop-core에서는 주로 `event_publication`(Modulith) 또는 후속 엔티티 도입 후 도메인 테이블, notification에서는 `processed_event` 컬럼 불일치.
- 진단: 오류 메시지의 테이블/컬럼명을 V1 DDL과 엔티티 `@Column`에 대조. notification은 `status`/`event_type` 길이(255), `event_id` uuid/unique, 시간 컬럼 타입 확인.
- 복구: **엔티티(특히 Modulith 프레임워크 엔티티)는 건드리지 않고 V1 DDL을 수정**한다. 단 V1이 이미 운영 DB에 적용된 뒤라면 V1 수정 금지 → `V2__`로 ALTER 추가(checksum 보호). 개발 중 미적용 상태면 깨끗한 DB 재생성 후 V1 직접 수정 가능.

### 4.2 Flyway 체크섬 불일치 (Validate failed: migration checksum mismatch)
- 증상: 이미 적용된 V1을 사후 편집해 재기동 시 `FlywayValidateException`.
- 원인/규칙: 적용된 마이그레이션 수정 금지(§8).
- 복구: 변경은 `V2__`로 추가. 개발 환경에서 의도적 재작성이 필요하면 깨끗한 DB(또는 `flyway clean` — 운영 금지)에서 다시 적용. 운영에서는 절대 V1 편집/clean 금지.

### 4.3 Modulith 스키마 불일치 (validate가 event_publication에서 실패)
- 증상: 4.1의 특수 케이스로 `event_publication`의 컬럼명/타입이 Modulith JPA 엔티티와 어긋남.
- 진단: 1.3 절차대로 의존성 동봉 스키마/`JpaEventPublication` 매핑과 V1 DDL 대조.
- 복구: V1의 `event_publication` 정의를 Modulith 실제 매핑에 맞춤(테이블 단위 validate 제외 불가하므로 정확 일치가 유일 해법). 적용 후라면 V2 ALTER.

### 4.4 PostgreSQL 핸들러 부재 (flyway-database-postgresql 누락)
- 증상: 부팅 시 Flyway가 jdbc:postgresql URL을 처리할 데이터베이스 모듈을 못 찾음.
- 복구: `flyway-database-postgresql` 의존성 추가(2장). 버전 BOM/명시 확인.

### 4.5 테스트 컨텍스트 파손 (Flyway가 테스트에서 동작)
- 증상: H2 슬라이스에서 citext/partial index/trigger 실행 실패, 또는 DB 없는 컨텍스트에서 Flyway가 DataSource를 찾다 실패.
- 복구: 1.5대로 test yml에 Flyway exclude/disable, `EventProcessingServiceTransactionTest`에 `spring.flyway.enabled=false`.

---

## 5. 검증 방법

> 자동 테스트 실행 위치: 각 하위 프로젝트(`shop-core/`, `notification/`). 마이그레이션 실행 검증은 docker-compose 로컬 Postgres에서 수동/문서화.

### 5.1 자동 테스트 (CI 가능)
- `shop-core/`: `./gradlew test` — 기존 Modulith verification/security/contextLoads + (선택) FlywayMigrationScriptTest 그린. DB 없는 컨텍스트 로드 비파괴.
- `notification/`: `./gradlew test` — 기존 002/005 단위·통합(EmbeddedKafka kafkatest) + `EventProcessingServiceTransactionTest`(H2, flyway off 보강) + (선택) 스크립트 테스트 그린.

### 5.2 로컬 마이그레이션 실검증 (권장, 수동)
```
docker compose -f docker/shop/docker-compose.yml up -d   # 5432/5433 Postgres, Kafka
# shop-core: 앱 기동(Flyway 자동) 또는 ./gradlew bootRun → 로그에 "Migrating schema ... to version 1" 확인 + validate 무오류
# notification: 동일하게 기동 → V1 적용 + processed_event validate 통과
```

### 5.3 DB 확인 (psql)
```
docker exec -it shop-core-postgres psql -U shop_core -d shop_core -c "\dt"
  → 도메인 18테이블 + event_publication + flyway_schema_history 확인
docker exec -it shop-notification-postgres psql -U notification -d notification -c "\dt"
  → processed_event + flyway_schema_history만 (shop-core 도메인 테이블 부재 확인)
```

### 5.4 Acceptance Criteria 대 검증 매핑
| Acceptance | 검증 |
|---|---|
| 두 프로젝트 Flyway 의존성 보유 | build.gradle ×2 (flyway-core + postgresql 모듈) — 5.2 기동 로그 |
| 운영/개발에서 ddl-auto=validate | main yml ×2, 5.2 기동 시 validate 수행 |
| shop-core V1이 정본 핵심 테이블/제약/인덱스/트리거 반영 | V1 SQL + 5.3 `\dt` + (선택) 스크립트 토큰 테스트 |
| shop-core V1에 event_publication 포함 | V1 SQL + 5.3 `\dt` + 1.3 validate 통과 |
| Modulith JDBC 스키마 자동초기화 비활성 | shop-core yml `schema-initialization.enabled=false` (JPA 변형 주석) |
| notification V1은 소유 테이블만 | notification V1(processed_event only) + 5.3 도메인 테이블 부재 + 스크립트 테스트(복제 토큰 부재) |
| 깨끗한 Postgres에서 마이그레이션 후 컨텍스트 로드 | 5.2 기동 성공 |
| validate가 Flyway 스키마 통과 | 5.2 무오류 기동(shop-core Modulith, notification ProcessedEvent) |
| 기존 테스트 통과 | 5.1 양 프로젝트 `./gradlew test` 그린 |
| DB 공유/동기 호출/이벤트 계약 변경 없음 | 독립 datasource 유지, notification V1에 shop-core 테이블 없음, 이벤트 DTO/토픽 무변경 |

---

## 6. 트레이드오프

- **shop-core V1 범위: 정본 전체 19테이블 선반영 vs 엔티티 등장 시 점진 생성**
  - 채택: 전체 선반영. (장) Task가 명시적으로 요구하는 정본 init schema 충족, 후속 도메인 Task가 스키마에 맞춰 매핑만 하면 됨, validate가 즉시 안전망. (단) 엔티티보다 스키마가 앞섬 — 단, 정본이 SSOT이므로 의도된 상태. 도메인 엔티티는 만들지 않아 과도설계 회피.
  - 미채택: 도메인별 점진 V1/V2 — Task Requirement 위배, 정본 추적성 저하.

- **event_publication DDL: 직접 작성 vs 의존성 동봉 스키마 재사용**
  - 채택: Modulith 동봉 표준 스키마/엔티티 매핑을 정본으로 대조해 V1에 반영. (장) validate 정확 일치 보장, 버전 업 시 차이 추적 용이. (단) 구현 단계에서 jar 내부 확인 필요(1.3 절차).
  - 미채택: §4.7만 보고 임의 작성 → 컬럼명/타입 미세 차이로 validate 실패 위험.

- **테스트에서 Flyway 끄기 vs Testcontainers 실검증**
  - 채택: 테스트는 Flyway off(DB 없는 컨텍스트/ H2 슬라이스 보존) + 마이그레이션 실검증은 docker-compose 수동/문서화. (장) 기존 테스트 비파괴, 범위 최소(YAGNI). (단) CI에서 V1 SQL 실행이 자동 검증되지 않음 → 정적 스크립트 테스트로 일부 보완, 실 Postgres 검증은 5.2 수동.
  - 미채택: Testcontainers(Postgres) 도입으로 V1을 CI에서 실행·validate. (장) 자동화·신뢰도↑. (단) 의존성/빌드 시간/도커 요구 — 본 인프라 Task 범위에 과함, 후속 인프라 개선으로 명시.

- **notification 시간 컬럼: 앱 소유 유지 vs DB 트리거 소유 전환**
  - 채택: 앱(JPA auditing) 소유 유지 + V1은 NOT NULL DEFAULT now()만. (장) 002 BaseEntity/테스트 비파괴, 범위 격리, 매핑 호환. (단) 정본 트리거 모델과 차이 → deviation 주석으로 명시.
  - 미채택: notification도 트리거 소유로 통일 → 002 산출물 리팩터링(BaseEntity 읽기전용 전환 + 테스트 수정) 필요, 범위 초과/회귀 위험.

- **flyway-database-postgresql 분리 의존성**
  - 채택: 추가(Flyway 10+에서 사실상 필수). (장) Postgres 핸들러 보장. (단) 의존성 1개 추가 — 합리적 비용.
  - 미채택: flyway-core만 → Postgres 미인식 가능성. 구현 시 BOM 동봉 여부 확인 후 확정.

- **마이그레이션 실행 트리거: 앱 기동 자동 vs Gradle flyway 플러그인**
  - 채택: Spring Boot 기동 시 자동 실행. (장) 추가 플러그인/설정 불요, 기동=마이그레이션→validate 보장. (단) `flywayMigrate`/`flywayInfo` 태스크 부재 → Task의 권장 명령은 "앱 기동 시 자동 실행 확인"으로 충족. 필요 시 후속에 플러그인 추가.

---

## Spring Boot 컨벤션
- 패키지/위치: 마이그레이션은 양 프로젝트 `src/main/resources/db/migration/V1__init_schema.sql`(Flyway 기본 location, 베이스라인 네이밍). 선택 테스트는 `com.shop.{shop|notification}.migration`.
- 설정: `spring.jpa.hibernate.ddl-auto: validate`, `spring.flyway.{enabled,locations,baseline-on-migrate}`. shop-core `spring.modulith.events.jdbc.schema-initialization.enabled: false`. 매직값/하드코딩 URL 없음(datasource는 기존 유지).
- SQL 규칙: `bigint GENERATED ALWAYS AS IDENTITY` PK, snake_case·복수형(테이블), 금액 `numeric(12,2)`, 시각 `timestamptz`, enum=`varchar + CHECK`, partial unique index, `set_updated_at()` 트리거. event_publication은 프레임워크 표준 스키마(uuid PK 예외 허용 — §4.7).
- 어노테이션(테스트 보강): `@TestPropertySource`(flyway.enabled=false), 기존 `@DataJpaTest`/`@SpringBootTest` 유지. 도메인 `@Entity` 신규 작성 없음.
- 불변 규칙: 적용된 V1 수정 금지, 변경은 V2+. notification deviation은 SQL 주석에 사유 기록.

## 완료 조건
- [ ] 양 build.gradle에 `flyway-core` + `flyway-database-postgresql` 추가(버전 BOM 위임/확인)
- [ ] 양 main application.yml `ddl-auto: validate` + `spring.flyway` 설정
- [ ] shop-core main yml `spring.modulith.events.jdbc.schema-initialization.enabled: false`(JPA 변형 주석)
- [ ] shop-core `V1__init_schema.sql`: citext + 도메인 18테이블 + event_publication + FK/CHECK/partial unique/일반 인덱스 + set_updated_at 함수·트리거, V1 불변 헤더 주석
- [ ] event_publication DDL이 Modulith JPA 엔티티와 정합(validate 통과) — 의존성 동봉 스키마 대조 확인
- [ ] notification `V1__init_schema.sql`: `processed_event` 1테이블만(event_id uuid unique, status varchar+CHECK, 시간 NOT NULL DEFAULT now()), shop-core 도메인 테이블 0개, deviation 주석
- [ ] 양 test application.yml `FlywayAutoConfiguration` 제외 + `flyway.enabled=false`
- [ ] notification `EventProcessingServiceTransactionTest`에 `spring.flyway.enabled=false` 보강(H2 슬라이스 보존)
- [ ] (선택) 마이그레이션 스크립트 정적 테스트 ×2(토큰 존재/복제 부재)
- [ ] database_design.md 정합(event_publication 실제 매핑 차이 반영 — 필요 시)
- [ ] `./gradlew test` 양 프로젝트 그린(기존 002/005 테스트 비파괴)
- [ ] 로컬 docker-compose 기동 후 양 앱 기동 시 Flyway 자동 실행 + validate 무오류 + `\dt`로 테이블/event_publication·processed_event 확인
- [ ] ddl-auto=create/update 잔존 0건, Flyway+Hibernate 동시 생성 0건, notification DB에 shop-core 도메인 테이블 0건, 이벤트 계약 변경 0건, 적용 V1 사후 수정 0건

## 에이전트 분담
- 본 Task는 화면(view) 없음 → **backend-implementor 단독** 수행.
- 단, **shop-core와 notification 두 레포에 걸친 인프라 작업**임을 명시한다. 두 프로젝트의 build.gradle/application.yml/V1 SQL/test 보강을 한 에이전트가 일관 정책(Flyway 도입 방식, test 비활성 방식, V1 불변 규칙)으로 처리한다.
- 구현 시 별도 확인 항목(메인 에이전트가 결과 취합): (1) Modulith 동봉 event_publication 스키마/엔티티 실제 매핑, (2) `flyway-database-postgresql` 버전 BOM 관리 여부, (3) ProcessedEvent 컬럼 1:1 정합, (4) docker-compose Postgres에서 V1 적용 + validate 실통과.

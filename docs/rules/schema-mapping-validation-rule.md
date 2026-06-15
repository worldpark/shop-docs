# Schema Mapping Validation Rule

JPA `@Entity` 매핑과 Flyway 마이그레이션 SQL의 **스키마 정합**을 다룬다. 이 코드베이스는 **Flyway가 스키마를 단독 소유**하고 Hibernate는 `spring.jpa.hibernate.ddl-auto=validate`로 **검증만** 수행한다(ADR-007, `application.yml:14`). 따라서 Entity 컬럼 매핑이 Flyway가 만든 실제 DDL과 한 글자라도 어긋나면 부팅이 실패한다. 본 규칙은 그 불일치를 **느린 전체 스위트가 아니라 초 단위 전용 테스트로 선제 탐지**하게 한다. `docs/rules/testing-rule.md`(테스트 작성)와 `docs/rules/verification-gate-rule.md`(완료 게이트)를 보완한다.

> 배경: Task 032에서 `reviews.rating` 컬럼은 V1 스키마상 `smallint`(int2)인데 `Review` Entity가 Java `int`(JDBC INTEGER)로 매핑됐다. `ddl-auto=validate`는 `Schema-validation: wrong column type encountered in column [rating] ... found [int2 (Types#SMALLINT)], but expecting [integer (Types#INTEGER)]`로 **entityManagerFactory 빌드 자체를 실패**시켰고, 그 결과 리뷰와 무관한 **모든 실DB(Testcontainers/Redis) 통합 테스트 ~34개 클래스(150건+)가 컨텍스트 기동 단계에서 연쇄 실패**했다. 단일 컬럼 매핑 오류 하나를 찾는 데 **19분짜리 전체 스위트**를 돌려야 했다. 전용 검증 테스트가 있었다면 수 초에 단일 컬럼명을 짚어 끝났다. 본 규칙은 그 공백을 메운다.

---

## 1. 원칙 — Flyway가 스키마 소유, Entity는 그에 정합
- 스키마의 정본(SSOT)은 **Flyway 마이그레이션 SQL**(`shop-core/src/main/resources/db/migration/V*.sql`)과 그 설계 문서 `docs/entity/database_design.md`다.
- 모든 `@Entity`의 모든 매핑 컬럼은 **Flyway가 적용한 DDL과 컬럼명·타입·nullable이 정확히 일치**해야 한다. Hibernate는 이를 `validate`로만 확인하며, 불일치 시 **자동 보정하지 않고 부팅을 거부**한다.
- 한 Entity의 매핑 오류는 **그 Entity와 무관한 전체 통합 테스트를 무더기로 깨뜨린다**(entityManagerFactory가 모든 Entity를 한꺼번에 검증하므로). "내 변경은 X 도메인뿐"이라는 직관으로 파급 범위를 좁게 보지 말 것.

## 2. 선제 검증 — 전용 스키마 validate 테스트를 둔다(필수)
신규/변경 Entity가 Flyway DDL과 정합하는지를 **전체 스위트와 독립적으로, 빠르게** 확인하는 **단일 전용 테스트**를 유지한다.

- 위치(권장): `shop-core/src/test/java/com/shop/shop/SchemaMappingValidationTest.java`.
- 방식: **Testcontainers PostgreSQL + Flyway migrate(전체 V*) + `ddl-auto=validate`로 모든 `@Entity`를 한 번에 검증**. 컨텍스트가 뜨면(=SessionFactory 빌드 성공) 모든 Entity가 현재 마이그레이션과 정합한다는 뜻이다. 무거운 풀 `@SpringBootTest` 대신 **`@DataJpaTest` 슬라이스**(JPA+Flyway만 기동, Kafka/Redis/web 미기동)로 둬서 빠르게 유지한다.
- 이 테스트는 **신규 컬럼/Entity 추가나 타입 변경 직후 가장 먼저 단독 실행**한다(아래 §5). 전체 스위트를 돌리기 전에 매핑 결함을 초 단위로 격리하기 위함이다.

참조 구현(슬라이스 — 빠름, 실제 동작 검증됨 `shop-core/src/test/java/com/shop/shop/SchemaMappingValidationTest.java`):
```java
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@Testcontainers
@TestPropertySource(properties = {
        "spring.autoconfigure.exclude=",          // 테스트 application.yml의 광범위 제외(JPA/Flyway 등)를 리셋
        "spring.flyway.enabled=true",
        "spring.jpa.hibernate.ddl-auto=validate"
})
class SchemaMappingValidationTest {

    @Container
    @ServiceConnection
    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16.4-alpine");

    @Autowired
    private TestEntityManager em;

    @Test
    @DisplayName("모든 @Entity 매핑이 Flyway 마이그레이션 DDL과 validate 정합한다")
    void allEntitiesValidateAgainstFlywaySchema() {
        // @DataJpaTest 컨텍스트가 ddl-auto=validate로 전 Entity를 검증한 뒤 기동된다.
        // 여기 도달했다는 것 자체가 정합의 증거다. 스캔 누락(false-pass)을 막으려 등록 Entity 수를 추가 단언한다.
        int entityCount = em.getEntityManager().getEntityManagerFactory()
                .getMetamodel().getEntities().size();
        assertThat(entityCount).isGreaterThanOrEqualTo(20);
    }
}
```
> 이 코드베이스의 테스트 `application.yml`은 DataSource/Hibernate/Flyway 자동설정을 광범위하게 제외하므로 `spring.autoconfigure.exclude=`로 **반드시 리셋**해야 Flyway migrate + JPA validate가 동작한다(기존 `ProductRepositoryIntegrationTest` 선례와 동일). `@DataJpaTest`는 메인 앱 패키지(`com.shop.shop`) 이하 전 `@Entity`를 스캔하므로 별도 `@EntityScan` 불필요. 모듈 분리 등으로 누락 Entity가 생기면 `@EntityScan("com.shop.shop")`를 더하고, RED 확인(§6)에서 누락 여부를 점검한다.

## 3. 신규/변경 Entity 체크리스트 — "Entity와 Flyway SQL 양쪽에 포함되었는가"
컬럼을 추가/변경하거나 Entity를 신설할 때, 아래를 **양쪽(Entity 매핑 ↔ Flyway DDL)** 에서 함께 확인한다.

1. **컬럼 존재**: 매핑한 필드의 컬럼이 Flyway DDL에 **존재**하는가. 반대로 DDL의 NOT NULL 컬럼이 Entity에 **누락**되어 INSERT가 깨지지 않는가.
2. **컬럼명**: `@Column(name=...)`이 DDL 컬럼명과 정확히 일치하는가(스네이크케이스). 마이그레이션 간 개명 이력 주의(예: products `owner_id`(과거 `seller_id` 아님), product_variants `stock`(`stock_quantity` 아님)).
3. **타입 정합**(validate가 가장 자주 깨지는 지점):
   - `smallint`(int2) ↔ Java `int`/`Integer`: 기본 매핑은 INTEGER라 **불일치**. 필드 타입은 유지하고 **`@JdbcTypeCode(org.hibernate.type.SqlTypes.SMALLINT)`** 를 붙인다(`short`로 바꾸면 시그니처 파급 — 비권장). `columnDefinition`만으로는 validate를 통과하지 못한다.
   - 상태/enum 컬럼: DDL은 `varchar + CHECK`, Entity는 `@Enumerated(EnumType.STRING)`(또는 String 스칼라). `EnumType.ORDINAL` 금지.
   - 큰 문자열: DDL `text` ↔ `@Column(columnDefinition = "text")`.
   - 금액/수량: `numeric(p,s)` ↔ `BigDecimal` + `@Column(precision=, scale=)` 정합.
   - 시간 컬럼: `created_at`/`updated_at`이 **DB 트리거 소유**면 `BaseEntity` 상속 + 읽기전용(`insertable=false, updatable=false`)으로 매핑한다(트리거가 있는 테이블만 — 없으면 BaseEntity 미상속, 혼동 금지).
   - UUID/`jsonb`/배열 등 PostgreSQL 고유 타입은 적절한 `@JdbcTypeCode`/컨버터로 정합.
4. **nullable / unique**: `@Column(nullable=, unique=)`이 DDL `NOT NULL`/`UNIQUE` 제약과 일치하는가.
5. **CHECK/도메인 불변식**: DDL CHECK(예: `rating BETWEEN 1 AND 5`)는 validate 대상이 아니므로, 도메인 메서드(`create`/`edit`)와 Bean Validation(`@Min/@Max`)으로 **앱 계층에서도 방어**한다.

## 4. 마이그레이션 작성 규칙(스키마 변경 시)
- 적용된 마이그레이션(`V1`~)은 **Flyway 체크섬으로 보호**된다 — **절대 수정하지 않는다**. 컬럼 추가/타입 변경은 항상 **새 `V{n+1}__*.sql`** 로 추가한다.
- 스키마 무변경(기존 컬럼을 새 Entity가 매핑만)인 경우엔 새 마이그레이션을 만들지 말고, 매핑이 기존 DDL과 정합함을 §2 테스트로 확인한다(Task 032 `reviews`는 V1 기존 컬럼 매핑 — 신규 마이그레이션 없음).
- 변경 후 `docs/entity/database_design.md`의 해당 표/의도를 동기화한다.

## 5. 워크플로 — 매핑 변경은 전용 테스트를 먼저 돌린다
- Entity 신설/컬럼·타입 변경 또는 새 마이그레이션 추가 직후, **전체 스위트보다 먼저** 전용 테스트를 단독 실행한다:
  - `./gradlew test --tests "com.shop.shop.SchemaMappingValidationTest"`
  - RED면 메시지의 `column [..]`/`table [..]`로 **단일 불일치를 즉시 격리**해 고친다(전체 스위트 19분 대기 불필요).
- 전용 테스트가 GREEN이 된 뒤에 verification-gate(전체 `./gradlew test`)로 넘어간다. 즉 **스키마 정합은 동적 게이트의 1차 관문**이다.

## 6. RED를 경험으로 확인한다
- 새 전용 테스트(또는 그 변형)는 **버그가 있던 매핑에서 반드시 실패**해야 의미가 있다(testing-rule 공통 원칙 연장).
- 도입/수정 시 의도적으로 매핑을 어긋나게(예: SMALLINT 애너테이션 제거) 만들어 **테스트가 RED가 되는지 1회 확인**한 뒤 복원한다. "이론상 잡힌다"로 갈음하지 않는다.
- `@EntityScan` 누락 등으로 **검증 대상에서 빠진 Entity는 false-pass**를 만든다 — 전 패키지 Entity가 실제 검증되는지 RED 확인에 포함한다.

## 7. 게이트와의 관계
- 본 규칙의 전용 테스트 GREEN은 **verification-gate-rule §2 동적 게이트의 선행 부분 집합**이다. 전체 스위트 그린을 대체하지 않는다(전체 그린은 여전히 메인 에이전트가 확인).
- 스키마 매핑 결함으로 통합 테스트가 무더기 실패하면, "환경/인프라 탓"이나 "pre-existing"으로 단정하지 말고(verification-gate-rule §3) **먼저 §2 전용 테스트로 매핑 정합부터 격리**한다 — 대량 실패의 단일 근본 원인일 때가 많다.

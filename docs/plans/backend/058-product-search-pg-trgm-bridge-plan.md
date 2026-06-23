# 058. 공개 상품 검색 pg_trgm 브리지 — Plan

> Task SSOT: docs/tasks/backend/058-backend-shop-core-product-search-pg-trgm-bridge.md
> ADR: docs/adr/011-product-search-elasticsearch-secondary-index.md (본 task = T0 폴백 기반)
> 후속: T5+6 backend/061 의 ES 장애 graceful-degrade 폴백 경로가 본 산출물(pg_trgm 인덱스 경로)을 영구 재사용한다.

## 구현 목표
PostgreSQL `pg_trgm` 확장 + `products.name` 의 `lower(name) gin_trgm_ops` GIN 식 인덱스(V12)를 추가하고, 기존 공개 목록 검색 3종의 `LOWER(p.name) LIKE LOWER(CONCAT('%', kw, '%'))` 절이 **쿼리 문구 변경 없이** 해당 GIN 인덱스를 타게 만들어 선행 와일드카드 풀스캔을 완화한다. 검색 의미·정렬·집계·페이징·status 화이트리스트는 회귀 0.

---

## 1. 설계 방식 · 이유

### 1-1. 핵심 설계 결정 — 식 인덱스 `lower(name)` + 쿼리 무변경 (후보 A 채택)

**채택: (A) 식 인덱스 `CREATE INDEX ... USING gin (lower(name) gin_trgm_ops)` + ProductRepository 쿼리 문구 무변경.**

근거 (코드 대조로 확정):
- 현재 3종 쿼리의 검색 절은 모두 동일하다(ProductRepository.java L59/L69, L105/L115, L151/L161):
  `AND (CAST(:keyword AS string) IS NULL OR LOWER(p.name) LIKE LOWER(CONCAT('%', CAST(:keyword AS string), '%')))`
- `Product.name` 은 `@Column(nullable = false) private String name;` (Product.java L56-57) — `@Column(name=...)` 오버라이드 없음 → DDL 컬럼명 = `products.name`. 따라서 식 인덱스 표현식은 정확히 `lower(name)`.
- Hibernate `PostgreSQLDialect` 는 JPQL `LOWER(p.name)` 를 SQL `lower(p1_0.name)` 로, JPQL `LIKE` 를 SQL `like` 로 렌더한다. PostgreSQL planner는 **인덱스 표현식 `lower(name)` 과 쿼리 좌변 표현식 `lower(p1_0.name)` 가 동일하고, 연산자가 `like` (gin_trgm_ops가 지원하는 `~~`)** 이면 `idx_products_name_trgm` 에 대한 Bitmap Index Scan을 선택한다. 식 인덱스가 쿼리 좌변과 매칭되므로 **쿼리를 native로 바꾸거나 ILIKE로 재작성할 필요가 없다.**
- `CAST(:keyword AS string)` (NULL 파라미터 bytea 회귀 방지, ProductRepositoryIntegrationTest L43-45 문서화)는 RHS(`CONCAT` 내부)에만 영향을 주며 좌변 `lower(name)` 표현식에 영향이 없다 → 인덱스 매칭 불변.

**후보 B 기각**: `USING gin (name gin_trgm_ops)` + 쿼리를 `name ILIKE` 로 재작성. 기각 사유 — (1) 쿼리 3종×2(query/countQuery)=6곳을 수정해 회귀 표면이 커지고, (2) JPQL에 ILIKE 직접 표현이 없어 native 전환을 유발(정렬/집계/projection 동일 재작성 부담), (3) `name gin_trgm_ops` 인덱스는 `lower(name) like` 좌변과 표현식이 불일치해 그대로는 인덱스를 못 탄다. A안은 쿼리 무변경으로 회귀 0 제약과 "과도한 설계 금지"에 가장 부합한다.

> **검증 게이트(필수)**: A안이 실제로 인덱스를 타는지는 EXPLAIN 실측이 수용 기준이다(§5-2). 만에 하나 planner가 표현식을 매칭하지 못하면(예: Hibernate가 `lower(...)` 가 아닌 다른 SQL로 렌더) — 그 경우에만 폴백으로 해당 3종 메서드를 native `@Query`(정렬/집계/projection/countQuery 문자열만 SQL로 1:1 이식, `ProductSummaryProjection` 매핑은 인터페이스 기반 또는 동일 생성자 projection 유지)로 전환한다. **이 native 폴백은 EXPLAIN RED일 때만 발동하며, 기본 경로가 아니다.** implementor는 A안을 먼저 적용하고 EXPLAIN으로 확인한다.

### 1-2. CONCURRENTLY 미사용 (일반 CREATE INDEX)
Flyway 마이그레이션은 기본적으로 트랜잭션 안에서 실행되며 `CREATE INDEX CONCURRENTLY` 는 트랜잭션 내 실행이 금지된다. 본 환경의 `products` 는 초기/소량 데이터이고 인덱스 빌드가 짧으므로 **일반 `CREATE INDEX`** 를 사용한다(테이블 잠금 짧음, 운영 부담 무시 가능). CONCURRENTLY를 위한 Flyway 트랜잭션 분리(`-- flyway:executeInTransaction=false` 등) 같은 추가 복잡도는 도입하지 않는다(과도한 설계 회피). V8(idx 2종 일반 CREATE INDEX)·V3(idx_products_owner_id 일반 CREATE INDEX) 선례와 동일 톤.

### 1-3. 매니지드 PG 호환
`pg_trgm` 은 PostgreSQL contrib 번들로 postgres:16.4-alpine(compose·Testcontainers 동일) 및 주요 매니지드 PG에서 `CREATE EXTENSION IF NOT EXISTS pg_trgm` 만으로 활성된다. PGroonga/mecab-ko/커스텀 사전은 사용하지 않는다(ADR-011 §맥락 — 이게 브리지를 손해 없는 선택으로 만드는 이유).

---

## 2. 영향 범위 (구성 요소)

### 신규 파일
- `shop-core/src/main/resources/db/migration/V12__product_name_trgm_index.sql`

### 수정 파일
- `shop-core/src/main/java/com/shop/shop/product/repository/ProductRepository.java` — **JavaDoc만 보강**(쿼리 문구 무변경, A안). 선행 와일드카드 풀스캔 → `idx_products_name_trgm`(lower(name) gin_trgm_ops) 활용 전환 의도 + ADR-011 T0 브리지 + T5+6(061) ES 폴백 재사용 교차참조 명시.
- `shop-core/perf/k6/scenarios/catalog-read.js` — keyword 가압 변형(기존 자산 재사용, §4).

### 신규 테스트
- `shop-core/src/test/java/com/shop/shop/product/repository/ProductSearchTrgmIndexIntegrationTest.java` — EXPLAIN 인덱스 사용 실측 + 검색 동등성/경계 고정(Testcontainers, ProductRepositoryIntegrationTest 패턴 계승).

### 무변경 (재사용)
PublicProductService(`findPublicProducts` 정규화·`PUBLIC_STATUSES`), ProductSearchCondition, ProductSummaryProjection, PublicProductRestController/Facade/View, Product Entity(인덱스만 추가 — 매핑 무변경), V1~V11, event-catalog.md, notification 전부, ProductRepository의 `findByOwnerIdOrderByCreatedAtDescIdDesc`·`countByStatusIn`.

---

## 3. 구현 상세

### 3-1. V12__product_name_trgm_index.sql (신규)

- 역할: pg_trgm 활성 + `products.name` 대소문자 무시 부분일치 검색용 GIN 식 인덱스 생성.
- 내용(정확):
  - `CREATE EXTENSION IF NOT EXISTS pg_trgm;`
  - `CREATE INDEX idx_products_name_trgm ON products USING gin (lower(name) gin_trgm_ops);`
- 네이밍: `idx_products_name_trgm` (선례 `idx_테이블_컬럼` — V3 `idx_products_owner_id`, V8 `idx_inventory_stock_ledger_variant_id` 계승; trgm 접미로 인덱스 종류 표시).
- 주석(V3/V8 톤): ADR-011 §결정 브리지 근거 / pg_trgm contrib·매니지드 호환(이미지·확장 설치 불필요) / **인덱스 표현식 `lower(name)` 이 쿼리 `LOWER(p.name) LIKE` 좌변과 일치해 GIN을 타게 하는 의도** / CONCURRENTLY 미사용 사유(트랜잭션 마이그레이션·소량 데이터) / V1~V11 불변·V12 신규 / T5+6(061) ES 폴백 재사용 교차참조.

### 3-2. ProductRepository.java (수정 — JavaDoc만)

- 메서드/필드: 변경 없음. `findPublicProductsLatest` / `findPublicProductsPriceAsc` / `findPublicProductsPriceDesc` 의 `@Query` value·countQuery 문구, 파라미터, `ProductSummaryProjection` 7인자 생성자, GROUP BY, ORDER BY, `COUNT(DISTINCT p.id)` 모두 현행 유지.
- 비즈니스 로직: 무변경. 인터페이스 상단 또는 3종 메서드 JavaDoc에 한 단락 추가 —
  - "상품명 부분일치 검색은 `V12 idx_products_name_trgm`(lower(name) gin_trgm_ops) GIN 식 인덱스를 사용한다. `LOWER(p.name) LIKE LOWER(CONCAT('%', kw, '%'))` 좌변 `lower(name)` 이 인덱스 표현식과 일치해 선행 와일드카드여도 Bitmap Index Scan으로 풀린다(ADR-011 T0 브리지). 이 경로는 T5+6(backend/061)에서 ES 장애 시 폴백으로 재사용된다."

### 3-3. catalog-read.js (수정 — §4 참조)

---

## 4. 데이터 흐름 & k6 측정 변형

### 4-1. 런타임 데이터 흐름 (무변경)
`GET /api/v1/products?keyword=…&sort=…` → Controller/Facade → `PublicProductService.findPublicProducts`(keyword trim→blank시 null 정규화, `PUBLIC_STATUSES`=[ON_SALE,SOLD_OUT] 적용, sort별 repo 메서드 선택) → ProductRepository 3종 중 1종 → **(신규)** planner가 `lower(name) like lower(...)` 를 `idx_products_name_trgm` Bitmap Index Scan으로 처리 → GROUP BY 집계 → `ProductSummaryProjection` → 응답. **서비스/컨트롤러/뷰 시그니처·흐름 전부 동일, DB 접근 경로(풀스캔→인덱스)만 변화.**

### 4-2. k6 측정 변형 (기존 자산 재사용 우선)
- 방식: `catalog-read.js` 의 목록 호출(L157-159)을 **환경변수로 keyword를 선택적으로 부착**하도록 파라미터화. 신규 시나리오 파일을 만들지 않는다(기존 자산 재사용 = Task 지시).
  - `const SEARCH_KEYWORD = __ENV.SEARCH_KEYWORD || '';`
  - 목록 URL: keyword가 있으면 `&keyword=${encodeURIComponent(SEARCH_KEYWORD)}` 추가, 없으면 현행과 동일(기존 동작 보존 — 회귀 0).
  - 시드 상품명은 `setupCatalogSeed`(seed.js L305/L331) → `PERF-Catalog-<prefix>`. 따라서 검색 가압 keyword 예: `SEARCH_KEYWORD=Catalog`(≥3그램, 시드 상품명 부분문자열 → 검색 절을 실제로 탄다).
- 측정 절차(메모리 주의 반영):
  1. **깨끗한 DB**에서 측정(k6-perf-baseline-needs-clean-db). 측정 전 테스트 주문/상품/장바구니 정리, threshold를 열화 상태에 앵커링 금지.
  2. **notification log 모드**(`mail.mode=log` 등 — perf-test-notification-must-be-log-mode). signup 환영메일 실 SMTP 방지.
  3. background bootRun 누수(PG 연결 고갈) 주의 — 재기동 전 java 프로세스/연결수 확인(bootrun-jvm-leak-pg-exhaustion).
  4. **적용 전 측정**: V12 미적용(또는 인덱스 DROP) 상태에서 `SEARCH_KEYWORD=Catalog` 가압 → p95 export.
  5. **적용 후 측정**: V12 적용 상태 동일 가압 → p95 export.
  6. 전/후 p95 + 사용 시드 규모(`CATALOG_PRODUCT_COUNT` 기본 50)·keyword 분포를 측정 노트로 기록.
- **trigram 한계 노트(한 줄, 측정 노트에 기록)**: keyword 3그램 미만(2글자 이하)은 trigram 인덱스 효과가 제한적이라 planner가 seq scan으로 폴백할 수 있다(결과 동등, 성능 이득만 제한). 또한 시드 상품명이 `PERF-Catalog-` 공통 접두를 공유해 selectivity가 낮으면(거의 전건 매치) 인덱스 이득이 작게 보일 수 있으니, 측정 노트에 selectivity 조건을 함께 기록한다.

> k6는 게이트가 아닌 측정이다. 메인 에이전트가 절차 안전(clean DB·log 모드·연결 정리)을 자기 눈으로 확인한다.

---

## 5. 검증 방법 (verification-gate-rule / schema-mapping-validation-rule / testing-rule)

순서대로 좁은 관문 → 넓은 회귀로 진행. 느린 통합은 타깃만, 풀 스위트는 마지막 1회(testcontainers-red-green-iteration-cost).

### 5-1. 1차 관문 — SchemaMappingValidationTest 단독
`gradlew test --tests "com.shop.shop.SchemaMappingValidationTest"` 를 V12 추가 **직후** 단독 실행. V12 Flyway migrate 성공 + 전 Entity validate GREEN을 초 단위로 확인. RED면 V12 SQL 오류를 즉시 격리(인덱스는 validate 무관하나 migrate 실패 시 컨텍스트 자체가 안 뜸).

### 5-2. 인덱스 사용 실측 (EXPLAIN, Testcontainers) — 수용 기준
신규 `ProductSearchTrgmIndexIntegrationTest`(ProductRepositoryIntegrationTest 슬라이스 구성 계승: `@DataJpaTest` + `AutoConfigureTestDatabase.NONE` + Testcontainers postgres:16.4-alpine + `spring.autoconfigure.exclude=` + `flyway.enabled=true` + `ddl-auto=validate`):
- 충분한 행 수의 상품(예: 동일/유사 상품명 다수 + 매치 소수)을 시드해 planner가 인덱스를 선택할 통계 조건을 만든 뒤,
- 검색 절과 **동일한 SQL 표현식**(`lower(name) like lower('%' || ? || '%')`)에 대해 `EXPLAIN` 실행 → 결과 문자열에 **`idx_products_name_trgm`** 및 Bitmap Index Scan 류가 포함됨을 단언.
- **RED 보장**: 인덱스 누락/표현식 불일치로 인덱스를 못 타면 단언 실패하도록 작성(schema-mapping-validation-rule §6 — "이론상 인덱스를 탄다"로 갈음 금지). 실측이 A안 채택의 수용 근거다. (소량 시드로 planner가 seq scan을 고를 수 있으므로, 테스트는 인덱스 선택을 유도할 만큼 행을 시드하거나 `enable_seqscan=off` 세션 설정으로 인덱스 사용 가능성 자체를 검증 — 둘 중 안정적인 쪽을 implementor가 택하고 사유를 주석에 남긴다.)

### 5-3. 검색 동등성 / 경계 고정 (Testcontainers 슬라이스)
전환 전후 결과 동등을 고정. (A안은 쿼리 문구가 동일하므로 본질적으로 동등하지만, 인덱스 유무에 따른 결과 차이가 0임을 명시적으로 고정한다):
- 대소문자 혼합 keyword(`sh`/`SHIRT` 등 — 기존 ProductRepositoryIntegrationTest의 `keyword_caseInsensitivePartialMatch`·`keyword_upperCaseInput_matches` 케이스 계승), 부분문자열, 미존재 keyword(빈 결과), null/blank keyword(전체), categoryId 필터, status 화이트리스트(ON_SALE/SOLD_OUT만), 정렬 3종, 다중 페이지(totalElements=COUNT(DISTINCT p.id)) 동일.
- **trigram 경계**: 2글자 이하 짧은 keyword(seq scan 폴백 가능)에서도 **결과 집합은 LIKE와 동일**함을 단언(인덱스는 동등성에 영향 없음 — 성능만 영향).

### 5-4. 회귀
기존 `ProductRepositoryIntegrationTest` 전체 그린(공개 목록/검색/displayPrice/purchasable/정렬/페이징/판매자 IDOR). 공개 목록/상세/검색/판매자 목록/admin 통계 관련 기존 테스트 그린.

### 5-5. 모듈 경계 + 풀 스위트
ModularityTests/ArchUnit 그린(product 모듈 내부 변경만 — cross-module 의존 0). 마지막 1회 `gradlew test` 풀 그린 + Spring Modulith verify를 메인 에이전트가 자기 눈으로 확인(verification-gate-rule). (참고 메모리: 핵심 서비스 repo 의존 추가가 아니므로 `@MockSharedRepositories` 영향 없음 — 인덱스/쿼리 무변경 범위.)

### 5-6. k6 베이스라인
§4-2 절차. 게이트 아님(측정·기록).

---

## 6. 예외 처리 전략
- **신규 예외 경로 0.** 검색은 공개 읽기 경로이며 본 task는 인덱스 추가 + 쿼리 인덱스 활용 전환만 한다. keyword null/blank는 PublicProductService에서 이미 null 정규화(무변경)되고, repository는 `CAST(:keyword AS string) IS NULL` 로 조건을 스킵(현행 유지 — bytea 회귀 방지 로직 보존).
- **마이그레이션 실패 처리**: V12 migrate 실패 시 전 통합 테스트 컨텍스트가 안 뜨므로 5-1 단독 관문으로 선제 격리. `CREATE EXTENSION IF NOT EXISTS` / 일반 `CREATE INDEX` 모두 idempotent하지 않은 부분(인덱스 중복 생성)은 Flyway 버전 단조성으로 1회만 적용되어 안전.
- **인가/소유권**: 변경 없음(공개 permitAll, status 화이트리스트가 노출 제어 — api-authorization-rule 표 무변경).

---

## 7. 트레이드오프
- **A안(식 인덱스+쿼리 무변경) vs B안(native+ILIKE)**: A안은 회귀 표면 최소(쿼리 6곳 무변경)·과도설계 회피가 장점. 단점은 "인덱스를 실제로 타는가"가 planner 표현식 매칭에 의존 → EXPLAIN 실측으로 강제 검증(5-2). B안은 인덱스 매칭이 더 명시적이지만 native 6곳 재작성으로 회귀 위험·유지보수 비용이 크다. **회귀 0 + Task 범위 최소 원칙상 A안이 우월.**
- **CONCURRENTLY 미사용**: 인덱스 빌드 중 짧은 테이블 쓰기 잠금 가능 — 초기/소량 데이터에서 무시 가능. 운영 데이터가 커진 뒤 적용한다면 별도 운영 절차(트랜잭션 분리 CONCURRENTLY)가 필요하나 본 task 범위 밖.
- **GIN trigram 한계**: 형태소/동의어/어간 미지원(맥북↔맥북케이스 토큰 정규화 불가) — 이는 본 브리지의 의도된 한계이며 ES+Nori(T2+3/061)가 담당. pg_trgm은 음절 substring/fuzzy 수준의 부분일치 가속만 제공. 2글자 이하·저selectivity에서 인덱스 이득 제한(결과 동등). 이 한계는 측정 노트에 명시한다.
- **GIN 인덱스 쓰기 비용**: 상품 INSERT/UPDATE(name 변경) 시 GIN 유지 비용 소폭 증가. 상품 쓰기 빈도가 검색 읽기 대비 낮아 순이득.

---

## 완료 조건
- [ ] V12가 Testcontainers Flyway migrate 성공 + pg_trgm 확장·`idx_products_name_trgm` 생성. V12 적용 후 SchemaMappingValidationTest GREEN(5-1).
- [ ] EXPLAIN에서 검색 쿼리가 `idx_products_name_trgm` Bitmap Index Scan 사용을 실측 단언(5-2, RED 보장).
- [ ] 검색 동등성: keyword 부분일치·대소문자 무시·null 스킵·categoryId·status 화이트리스트·정렬 3종·페이징(totalElements)이 전환 전과 동일. 2글자 이하 경계에서도 결과 집합 동등(5-3).
- [ ] 회귀 0: 기존 ProductRepositoryIntegrationTest·공개/상세/판매자/admin 통계 그린(5-4). ModularityTests/ArchUnit·풀 스위트·Modulith verify 그린(5-5).
- [ ] ProductRepository 쿼리 문구·projection·정렬·countQuery 무변경(JavaDoc만 보강). PublicProductService/ProductSearchCondition/Controller/Facade/View 시그니처 무변경.
- [ ] pg_trgm(contrib)만 사용 — 매니지드 PG 호환 유지(이미지/커스텀 확장 없음). V1~V11 무변경. 이벤트/notification 무변경.
- [ ] 적용 전/후 검색 p95 베이스라인 측정·기록(깨끗한 DB·notification log 모드). trigram 한계 1줄 노트 포함(5-6, §4-2).
- [ ] T5+6(backend/061) ES 폴백 재사용이 V12 SQL 주석 + ProductRepository JavaDoc에 교차참조로 남음.

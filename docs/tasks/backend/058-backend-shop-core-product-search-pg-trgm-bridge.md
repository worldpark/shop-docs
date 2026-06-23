# 058. shop-core 공개 상품 검색 pg_trgm 브리지 — 선행 와일드카드 LIKE 풀스캔 완화 + ES 폴백 기반

> 출처: ADR-011(상품 검색은 Elasticsearch(+Nori) 보조 인덱스로 분리, PostgreSQL을 SoT로 유지) 후속 이니셔티브의 **T0 task**. ADR-011 §결정의 브리지(선택) 항목과 §결과의 선택적 pg_trgm 브리지로 선행 와일드카드 풀스캔을 즉시 완화하고 이를 영구 폴백으로 재사용한다는 방침을 구현 task로 구체화한다.
> 범위 SSOT: 본 문서. 설계 결정(인덱스 표현식·쿼리 재작성 형태·측정 절차 세부)은 후속 docs/plans/backend/058-product-search-pg-trgm-bridge-plan.md 에 위임한다.

## Target
shop-core (product 모듈 — repository 검색 쿼리 + Flyway 마이그레이션). View/REST/Service 시그니처 무변경(읽기 경로 내부 쿼리만 전환).

> DB 인덱스(pg_trgm GIN) 추가 + ProductRepository 공개 목록 검색 3종의 상품명 부분일치를 trigram 인덱스가 동작하는 형태로 전환하는 데 한정한다. 검색 결과 의미(상품명 부분일치, 대소문자 무시)는 유지하고, 풀스캔에서 GIN 인덱스 활용으로 바꾼다.

---

## Goal
1. PostgreSQL pg_trgm 확장을 활성화하고 products.name 에 trigram GIN 인덱스(gin_trgm_ops)를 생성하는 Flyway 마이그레이션(다음 V번호 = **V12**)을 추가한다.
2. ProductRepository 의 공개 목록 집계 쿼리 3종(findPublicProductsLatest / findPublicProductsPriceAsc / findPublicProductsPriceDesc)의 상품명 검색을 **선행 와일드카드 LIKE 풀스캔에서 trigram GIN 인덱스를 타는 형태**로 전환한다. 기존 의미(부분일치·대소문자 무시·keyword null이면 조건 스킵)와 정렬/집계(displayPrice=COALESCE(MIN(활성 v.price), basePrice) · status 화이트리스트 · GROUP BY · 페이징 totalElements)는 회귀 없이 유지한다.
3. 적용 전/후 공개 카탈로그 검색(keyword 포함 목록 조회) p95를 기존 k6 자산(shop-core/perf/k6 하위)으로 측정해 풀스캔 완화 효과를 베이스라인으로 남긴다.

## Context
- **이니셔티브 내 위치(교차참조)**: 본 task는 상품 검색 개선 이니셔티브의 **T0(폴백 기반)**이다. 후속 task 맵 — T1 infra/006(ES 인프라·클라이언트) · T2+3 backend/059(색인 모델·Nori 매핑 + 이벤트 indexer) · T4 backend/060(재색인·백필 잡) · **T5+6 backend/061(검색 읽기 경로 + 폴백 + 뷰)**. 본 task가 만드는 pg_trgm 경로는 ADR-011 §결정 원칙 5(장애 폴백)에 따라 **T5+6(061)이 ES 장애 시 graceful degrade 폴백으로 재사용**한다. 즉 본 task의 산출물은 (1) 도입 즉시 LIKE 통증 완화(임시 브리지), (2) ES 도입 후에도 영구 폴백 — 두 역할을 동시에 가진다(ADR-011 §결과).
- **현재 검색 코드(전환 대상)**:
  - shop-core/src/main/java/com/shop/shop/product/repository/ProductRepository.java — 공개 목록 집계 쿼리 3종. 각 쿼리/countQuery의 검색 절이 모두 동일하게 CAST(:keyword AS string) IS NULL 이면 스킵, 아니면 LOWER(p.name) LIKE LOWER(CONCAT(앞와일드, keyword, 뒤와일드)) 형태. 선행 와일드카드 때문에 B-tree 인덱스를 못 타 풀스캔(ADR-011 §맥락).
  - shop-core/src/main/java/com/shop/shop/product/service/PublicProductService.java — findPublicProducts(keyword, categoryId, sort, pageable)가 keyword를 trim 후 blank이면 null로 정규화하고 sort별 repository 메서드를 호출. status 화이트리스트 PUBLIC_STATUSES=[ON_SALE, SOLD_OUT]를 이 한 곳에서만 적용. **이 Service의 시그니처·정규화·화이트리스트는 무변경**(쿼리 내부만 전환).
  - shop-core/src/main/java/com/shop/shop/web/product/ProductSearchCondition.java — View 검색 조건 객체(keyword/categoryId/sort/page/size). **무변경**.
- **DB / 매니지드 호환**: compose Postgres는 postgres:16.4-alpine(docker/shop/docker-compose.yml), 테스트는 Testcontainers postgres:16.4-alpine. pg_trgm은 **PostgreSQL contrib 모듈 번들**로 공식 이미지·주요 매니지드 PG(RDS/CloudSQL/Supabase 등) 모두에서 CREATE EXTENSION pg_trgm 만으로 활성화된다 — **DB 이미지 교체·커스텀 확장 설치 불필요**(ADR-011 표: pg_trgm은 어디서나 가능, PGroonga/한국어 FTS와 달리 매니지드 호환). 이 호환성이 본 브리지를 손해 없는 선택으로 만든다.
- **Flyway 선례**: 적용된 마이그레이션 V1~V11(최신 = V11__shipments_seller_id_backfill.sql)은 체크섬 보호 — 수정 금지. 신규는 **V12__ 접두 SQL**. 인덱스 추가 선례: V3(CREATE INDEX idx_products_owner_id ON products (owner_id)), V8(CREATE INDEX idx_inventory_stock_ledger 계열). 네이밍 컨벤션 idx_테이블_컬럼 계승(예: idx_products_name_trgm).
- **측정 자산**: shop-core/perf/k6/scenarios/catalog-read.js(공개 카탈로그 읽기, read_duration Trend·p95/p99, setupCatalogSeed로 상품 시드, handleSummary 메트릭 export). **단, 현재 default()는 GET /api/v1/products 를 sort=latest 로 keyword 없이 호출**해 검색 절을 거의 안 탄다 — 베이스라인은 **keyword를 포함한 검색 요청**을 가압해야 trigram 효과가 측정된다(시드 상품명에서 추출한 부분 문자열로 keyword 변형). 측정 절차 세부(시나리오 변형 방식, 시드 규모/상품명 다양성)는 plan 확정.
- **측정 환경 주의(메모리)**: k6 베이스라인은 **깨끗한 DB**에서 측정한다(누적 주문/상품이 쿼리를 열화시켜 baseline을 오염 — k6-perf-baseline-needs-clean-db). 측정 전 테스트 데이터 정리, threshold를 열화 상태에 앵커링 금지. 부하 시 **notification은 log 모드**(signup에서 환영메일 실 SMTP 발송 사고 방지 — perf-test-notification-must-be-log-mode). background bootRun 누수로 PG 연결 고갈 주의(bootrun-jvm-leak-pg-exhaustion).

## 범위 경계 (명시)
**범위 안(본 T0):**
- CREATE EXTENSION IF NOT EXISTS pg_trgm + products.name trigram GIN 인덱스(gin_trgm_ops)를 만드는 V12 마이그레이션.
- 공개 목록 검색 3종(쿼리 + countQuery)의 상품명 부분일치를 trigram GIN 인덱스가 동작하는 형태로 전환(선행 와일드카드 인덱싱). 정렬/집계/페이징/status 화이트리스트 회귀 0.
- 적용 전/후 검색 p95 베이스라인 측정·기록.

**범위 밖(명시 — 후속 task):**
- **한국어 형태소 분석**(어간·합성어 분해·동의어). pg_trgm은 **음절 단위 substring/fuzzy 수준**이며 형태소 분석이 아니다(맥북 케이스와 맥북케이스의 토큰 정규화·동의어를 못 함 — ADR-011 §맥락). 형태소 검색은 ES+Nori로 T2+3(059)·T5+6(061)에서 제공.
- **자동완성·패싯·연관도 랭킹**(ES 표면). 본 task는 정렬을 latest/priceAsc/priceDesc로 유지하며 검색 score 정렬을 추가하지 않는다.
- 상품 설명·카테고리·태그 등 **상품명 외 필드 검색 확장**(현재도 상품명 단일 컬럼 — 유지).
- ES 인프라/클라이언트/색인/이벤트(T1·T2+3·T4) 및 검색 읽기 모델 분리(T5+6).

## API Authorization
> docs/rules/api-authorization-rule.md. 본 task는 **공개 읽기 경로의 내부 쿼리만 전환**하며 인가 표면을 바꾸지 않는다.

| API/경로 | 공개 여부 | 최소 권한 | 소유권 검사 | 비고 |
|---|---|---|---|---|
| GET /api/v1/products (목록·검색) | permitAll | — | 불필요 | 무변경(공개). status 화이트리스트가 노출 제어(ON_SALE/SOLD_OUT만) — 본 task로 무변경 |
| GET /products (View 목록) | permitAll | — | 불필요 | 무변경(공개) |

> 신규 엔드포인트·신규 권한·소유권 검사 없음. status 화이트리스트는 PublicProductService.PUBLIC_STATUSES 단일 소유 그대로(쿼리 WHERE 절의 p.status IN :statuses 유지).

## Requirements
### A. Flyway 마이그레이션 (V12)
- CREATE EXTENSION IF NOT EXISTS pg_trgm; (contrib 번들 — 이미지/확장 설치 불필요. 주석에 매니지드 PG 호환·ADR-011 근거 명시).
- products.name 에 trigram GIN 인덱스 생성: CREATE INDEX idx_products_name_trgm ON products USING gin (상품명_표현식 gin_trgm_ops); 형태.
  - 쿼리가 LOWER(p.name) LIKE 대소문자 무시 부분일치 의미를 유지하려면 인덱스 표현식과 쿼리 표현식이 **정확히 일치**해야 인덱스를 탄다(예: 양쪽 모두 lower(name)). 정확한 표현식(lower(name) 식 인덱스 vs name 인덱스 + 쿼리 정규화)은 plan 확정.
  - CONCURRENTLY는 Flyway 트랜잭션 마이그레이션과 충돌(트랜잭션 내 실행 불가)하므로 사용 여부·분리 실행 필요 시 plan에서 결정(초기 데이터 소량이면 일반 CREATE INDEX로 충분).
- 마이그레이션은 신규 V12 파일로만 추가. 적용된 V1~V11 수정 금지(schema-mapping-validation-rule §4).
- 인덱스만 추가(컬럼/타입 변경 없음)이므로 Entity 매핑 변경 없음. 단 SchemaMappingValidationTest(전 Entity validate)가 V12 적용 후에도 GREEN인지 확인(인덱스는 validate 무관하나 마이그레이션 실패 시 컨텍스트 자체가 안 뜸 — Test 절 참조).

### B. ProductRepository 검색 쿼리 전환
- 3종 쿼리(findPublicProductsLatest/PriceAsc/PriceDesc)의 **쿼리·countQuery 양쪽** 검색 절을 trigram GIN 인덱스를 타는 형태로 전환한다. 검색 절은 3종에서 동일 형태여야 한다(현재도 동일).
- **의미 유지**: keyword null이면 조건 스킵, 대소문자 무시 부분일치(앞뒤 와일드카드). keyword 값은 PublicProductService에서 이미 trim 및 blank에서 null 정규화됨(무변경) — 쿼리는 정규화된 keyword를 받는다.
- **인덱스 활용 보장**: 쿼리의 검색 표현식이 인덱스 표현식과 매칭되어 GIN을 타도록 한다. JPQL LIKE가 Postgres ILIKE/like + trigram 인덱스로 풀리는지(또는 native query나 명시 lower() 표현이 필요한지)를 plan에서 확정하고, **EXPLAIN으로 Bitmap Index Scan(idx_products_name_trgm) 사용을 실측 확인**(Test 절). JPQL의 LOWER LIKE LOWER 형태가 식 인덱스와 매칭 안 되면 native @Query로 전환 가능(정렬/집계/projection 동일 유지 조건).
- **회귀 0**: displayPrice(COALESCE(MIN(활성 v.price), p.basePrice)), status 화이트리스트(p.status IN :statuses), categoryId 필터, GROUP BY 컬럼 목록, ORDER BY(latest=createdAt DESC,id DESC / priceAsc / priceDesc), countQuery의 COUNT(DISTINCT p.id) 페이징 정확도, ProductSummaryProjection 생성자 인자/순서 모두 현행과 동일.
- PublicProductService·ProductSearchCondition·Controller·Facade·View 시그니처 무변경.

### C. 베이스라인 측정
- 적용 **전/후** 공개 카탈로그 **검색**(keyword 포함) p95를 shop-core/perf/k6/scenarios/catalog-read.js 기반으로 측정. 현재 시나리오가 keyword 없이 호출하므로 keyword 가압 변형이 필요(시드 상품명 부분문자열로 keyword 생성). 변형을 신규 시나리오/프로파일로 둘지 기존 시나리오 파라미터화할지는 plan 확정(기존 자산 재사용 우선).
- 측정은 깨끗한 DB + notification log 모드(Context 메모리 주의). 결과(전/후 p95, 사용 시드 규모·keyword 분포)를 plan 또는 측정 노트에 기록. 회귀 임계 앵커링 금지(누적 열화 상태에서 측정 금지).
- trigram의 한계(짧은 keyword 3그램 미만에서 인덱스 효과 제한·정확도 vs LIKE 차이 가능)를 측정 노트에 한 줄 남긴다.

### D. 공통
- 기존 코드 스타일 유지(task-rule). 설계와 다르게 구현 시 사유를 plan 또는 코드 주석에 명시(task-rule).
- Entity를 API 응답으로 직접 반환 금지(forbidden-rule) — 본 task는 projection 유지로 자동 충족. Controller 비즈니스 로직 금지 — 무변경.

## Constraints
- **검색 의미 유지**: 부분일치·대소문자 무시·keyword null 스킵. 결과 집합이 LIKE와 동등(또는 trigram 특성상 미세 차이가 있으면 plan에 명시·테스트로 경계 고정). 정렬은 latest/priceAsc/priceDesc 그대로 — 검색 score 정렬 추가 금지(범위 밖).
- **스키마 정합(schema-mapping-validation-rule)**: 인덱스 추가는 컬럼/타입 변경이 아니므로 Entity 매핑 무변경. 그러나 V12 마이그레이션이 Testcontainers Flyway migrate에서 성공해야 모든 실DB 테스트 컨텍스트가 뜬다(마이그레이션 실패는 전 통합 테스트 연쇄 실패). SchemaMappingValidationTest로 V12 포함 전체 마이그레이션 + validate를 선제 확인.
- **매니지드 PG 호환 유지**: pg_trgm(contrib)만 사용. PGroonga·mecab-ko·커스텀 사전 등 매니지드 미제공 확장 금지(ADR-011 §맥락 — 그게 본 브리지를 택한 이유).
- **모듈 경계**: product 모듈 내부 변경만(repository 쿼리 + 마이그레이션). 신규 cross-module 의존 0. Spring Modulith ModularityTests/ArchUnit 그린 유지.
- **이벤트/notification 무변경**: Kafka 이벤트·event-catalog.md·notification 무참조(검색은 읽기 경로). dual-write·outbox 변경 없음(그건 T2+3/T4).
- **Flyway 불변**: V1~V11 수정 금지. V12만 추가.
- **회귀 0**: 공개 목록/검색/페이징/정렬/상세, 판매자 목록, admin 통계(countByStatusIn) 등 ProductRepository 다른 메서드 무변경.

## Files
> 정확 경로/표현식/시그니처는 plan 확정. 아래는 선례 대조 기준.

### 신규 (backend-implementor)
- shop-core/src/main/resources/db/migration/V12__product_name_trgm_index.sql — CREATE EXTENSION IF NOT EXISTS pg_trgm + products.name trigram GIN 인덱스(gin_trgm_ops). 주석에 ADR-011 브리지 근거·매니지드 호환·인덱스/쿼리 표현식 일치 의도 명시(V3/V8 인덱스 추가 주석 톤).

### 수정 (backend-implementor)
- shop-core/src/main/java/com/shop/shop/product/repository/ProductRepository.java — 공개 목록 3종 쿼리·countQuery의 상품명 검색 절을 trigram GIN 인덱스를 타는 형태로 전환. JavaDoc에 선행 와일드카드 풀스캔에서 pg_trgm GIN(idx_products_name_trgm) 활용으로의 전환과 ADR-011 T0 브리지임을 명시. 정렬/집계/projection/status/페이징 무변경.

### 측정 (backend-implementor 또는 perf 담당 — plan 확정)
- shop-core/perf/k6/scenarios/catalog-read.js (또는 신규 검색 변형/프로파일) — keyword 가압으로 검색 절을 타게 변형(기존 자산 재사용 우선). 적용 전/후 p95 export. 측정 노트(전/후 p95·trigram 한계)는 plan 또는 별도 노트.

### 무변경(재사용)
PublicProductService(findPublicProducts 정규화·PUBLIC_STATUSES), ProductSearchCondition, ProductSummaryProjection, PublicProductRestController/Facade/View, Product Entity(인덱스만 추가, 매핑 무변경), V1~V11 마이그레이션, event-catalog.md, notification 전부, ProductRepository의 판매자 목록·countByStatusIn.

## Acceptance Criteria
- V12 마이그레이션이 Testcontainers Flyway migrate에서 성공하고 pg_trgm 확장 + products.name trigram GIN 인덱스가 생성된다. V12 적용 후 SchemaMappingValidationTest(전 Entity validate) GREEN.
- 공개 목록 검색(keyword 포함) 쿼리가 **EXPLAIN에서 trigram GIN 인덱스(idx_products_name_trgm)를 사용**(Bitmap Index Scan)하고, 동일 keyword에 대해 전환 전 LIKE와 **결과 집합·정렬·페이징 totalElements가 동등**하다(미세 차이가 있으면 plan에 명시된 경계대로 테스트 고정).
- keyword가 null/blank인 경우, categoryId 필터, status 화이트리스트(ON_SALE/SOLD_OUT만 노출), displayPrice 정렬(latest/priceAsc/priceDesc), 페이징이 전환 전과 동일(회귀 0).
- 적용 전/후 검색 p95 베이스라인이 측정·기록되고, 풀스캔 대비 완화가 확인된다(깨끗한 DB·notification log 모드에서 측정).
- pg_trgm만 사용해 매니지드 PG 호환이 유지된다(커스텀 확장·이미지 교체 없음). product 모듈 경계·이벤트·notification 무변경. ModularityTests/ArchUnit·풀 스위트 그린.
- 본 task가 후속 T5+6(061)의 ES 장애 폴백 경로로 재사용 가능함이 문서(JavaDoc/plan 교차참조)에 남는다.

## Test
> testing-rule + verification-gate-rule + schema-mapping-validation-rule.
- **스키마 정합(1차 관문)**: SchemaMappingValidationTest 단독 실행(gradlew test --tests 로 해당 클래스만)을 V12 추가 직후 먼저 돌린다 — V12 Flyway migrate 성공 + 전 Entity validate GREEN을 초 단위로 확인(전체 스위트 전에). RED면 마이그레이션 SQL 오류를 즉시 격리.
- **인덱스 사용 실측(Testcontainers 통합)**: postgres:16.4-alpine 컨테이너에서 V12 적용 후 공개 검색 쿼리에 대해 **EXPLAIN으로 trigram GIN 인덱스 사용을 단언**(Bitmap Index Scan on idx_products_name_trgm). 인덱스 누락 시(또는 표현식 불일치로 인덱스 미사용 시) RED가 되도록 — 이론상 인덱스를 탄다로 갈음 금지(schema-mapping-validation-rule §6 RED 확인 정신). ProductRepositoryIntegrationTest(기존 실DB 선례) 패턴 계승.
- **검색 동등성(슬라이스 + Testcontainers)**: 전환 후 3종 쿼리가 keyword 부분일치·대소문자 무시·null 스킵·categoryId·status 화이트리스트·정렬·페이징(totalElements)에서 전환 전과 동일 결과. 대소문자 혼합 keyword, 부분문자열, 미존재 keyword(빈 결과), 다중 페이지 케이스 포함.
- **회귀**: 공개 목록/상세/검색/판매자 목록/admin 통계 관련 기존 테스트 그린. ModularityTests/ArchUnit 그린.
- **성능 베이스라인(k6)**: catalog-read 기반 검색 가압으로 적용 전/후 p95 측정. 깨끗한 DB + notification log 모드(Context 메모리 주의). 결과 기록. (k6는 게이트가 아닌 측정 — 메인 에이전트가 절차 안전을 확인.)
- 메인 에이전트가 gradlew test 풀 그린 + Spring Modulith verify를 자기 눈으로 확인(verification-gate-rule). 느린 통합 반복은 타깃 테스트만, 풀 스위트는 마지막 1회(testcontainers-red-green-iteration-cost).

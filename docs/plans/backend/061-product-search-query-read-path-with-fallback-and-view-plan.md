# 061. shop-core 상품 검색 — ES 읽기 경로(Nori 랭킹·status필터·페이징) + 장애 폴백 + 뷰 컷오버 — Plan

> Task SSOT: `docs/tasks/backend/061-backend-shop-core-product-search-query-read-path-with-fallback-and-view.md`
> ADR: `docs/adr/011-*`(상품 검색=ES(+Nori) 보조 인덱스, SoT=PG, ES=사본). 이니셔티브 T5(읽기 경로)+T6(뷰 컷오버).
> 전제(재사용·무변경): T0/058(pg_trgm GIN — **머지됨**, V12), T1/006(ES 클라이언트), T2+3/059(인덱스 매핑·alias·증분 indexer), T4/060(재색인). 본 Task는 **읽기 전용**(ES에 쓰지 않음 — dual-write 금지).
> 범위: keyword 검색의 ES 읽기 경로 교체 + ES 장애 graceful 폴백 + 드리프트 완화 + 뷰/REST 자동 컷오버. 자동완성·패싯·동의어·검색어 분석 적재는 범위 밖.
> 관련 규칙: `docs/rules/inapp-consumer-external-engine-rule.md`(ES 빈 게이팅·자원 수명·풀스위트 검증), architecture/package-structure/api-authorization/error-response/testing/verification-gate.

---

## 0. 코드 대조 (2026-06-23 실측)

| 항목 | 사실 | 061 활용 |
|---|---|---|
| **058 폴백 머지 여부** | **머지됨** — `V12__product_name_trgm_index.sql`: `CREATE EXTENSION pg_trgm; CREATE INDEX idx_products_name_trgm ON products USING gin (lower(name) gin_trgm_ops)`. 3종 공개목록 쿼리의 `LOWER(p.name) LIKE LOWER(CONCAT('%',keyword,'%'))`가 이 GIN 인덱스 사용 | **폴백 = 기존 `findPublicProducts*` 경로 그대로**(신규 폴백 코드 0) |
| 읽기 경로 단일 변경점 | `PublicProductService.findPublicProducts(keyword,categoryId,sort,Pageable)→Page<ProductSummaryProjection>`가 status 화이트리스트(`PUBLIC_STATUSES=[ON_SALE,SOLD_OUT]`) 단일 소유 + sort switch. **REST(`PublicProductServiceResponse.list`)·View(`PublicProductFacadeImpl.listProducts`) 둘 다 이 메서드 호출** 후 동일 이미지 IN+DTO 조립 | 여기 keyword 분기 추가 → 양쪽 자동 컷오버, 조립/계약 무변경 |
| projection | `ProductSummaryProjection(productId,name,displayPrice,categoryId,categoryName,status(ProductStatus),purchasableVariantCount)`. `displayPrice=COALESCE(MIN(활성 v.price),basePrice)`, `purchasable=SUM(CASE active AND stock>0)`. GROUP BY 에 `p.createdAt` 포함, latest는 `ORDER BY p.createdAt DESC,p.id DESC` | byIds 재투영 쿼리가 동일 집계 재사용 |
| ES 인덱스 필드 | `product-index.json`: productId(long), name/description/categoryName(text korean_nori), status(keyword), displayPrice(scaled_float×100), purchasableVariantCount(int), categoryId(long). **createdAt 없음** | latest 정렬은 ES `_score`로 매핑(아래 결정 2) |
| ES 클라이언트 | `co.elastic.clients:elasticsearch-java` 8.18.8. `search(...)` 미사용(신규). alias `products`(`ProductSearchIndexNames.ALIAS`) | 검색 DSL 신규 |
| ES 빈 게이팅 | `ProductSearchIndexConfig`(@AutoConfiguration+@ConditionalOnBean(ElasticsearchClient)+@ConditionalOnProperty(shop.search.indexer.enabled)). test 프로파일은 ES 자동설정 exclude. 060이 `ObjectProvider`로 코어 서비스를 ES-옵셔널로 배선한 선례 | 검색 어댑터 동일 게이트 + PublicProductService가 ObjectProvider 주입 |
| resilience4j | **없음**(의존성·@CircuitBreaker 0) | 폴백은 timeout+try/catch+경량 쿨다운(신규 의존 금지) |
| micrometer | actuator + micrometer-prometheus 있음, 커스텀 메트릭 0 | MeterRegistry 주입(Counter/Timer) |
| E2E | `src/e2eTest`(Playwright 1.52, `AbstractE2eTest`, BASE_URL env). 공개 목록 검색 E2E 없음. `e2eTest` gradle task(앱 기동 전제) | 신규 `PublicProductSearchE2eTest` |
| Testcontainers ES 하니스 | `ProductSearchIndexIntegrationTest`(Nori ImageFromDockerfile + PG @ServiceConnection + shop.search.indexer.enabled=true + @DirtiesContext + Awaitility) | 읽기경로/폴백 통합 테스트 계승 |

---

## 1. 확정 설계 결정 (Task가 plan에 위임한 7항목)

### 결정 1 — 읽기 모델 분리: **`PublicProductService.findPublicProducts` 내부 keyword 분기 + PG SoT 재투영**
- keyword 정규화(trim/blank→null) 후 **keyword != null** 이면: `ProductSearchPort.search(...)`로 ES 조회(상품 ID 랭킹 순서 + totalHits) → `ProductRepository.findPublicProductSummariesByIds(ids, PUBLIC_STATUSES)`로 **PG SoT 재투영**(displayPrice/status/purchasable 동일 집계) → ES 랭킹 순서로 재정렬 → `PageImpl<ProductSummaryProjection>(ordered, clamped, totalHits)` 반환.
- keyword == null(전체/카테고리 필터만) → **기존 PG 집계 경로 그대로**(ES 미경유, 회귀 0).
- ES 실패/비가용 → **기존 `findPublicProducts*`(keyword 포함, pg_trgm) 폴백**(같은 계약).
- **status 화이트리스트 단일 소유 유지**: `PUBLIC_STATUSES`가 ① ES term 필터, ② PG 재투영 WHERE, ③ PG 폴백 모두에 적용(이 Service 한 곳).
- **양쪽 호출자(REST/View) 무변경**: `findPublicProducts`가 `Page<ProductSummaryProjection>`를 그대로 반환하므로 이미지 IN+DTO+PageResponse 조립이 동일하게 동작.

### 결정 2 — ES 쿼리 DSL + 정렬/연관도
- **쿼리**: `bool`{ `must`: `multi_match`(query=keyword, fields=`name^3`,`description^2`,`categoryName^1` — 이름>설명>카테고리 부스팅, `operator=and` 또는 `fuzziness` 보수 적용은 구현 시 형태소 매칭 품질로 확정), `filter`: status `terms`[ON_SALE,SOLD_OUT] + (categoryId!=null 시) categoryId `term` }. Nori 분석은 인덱스 매핑(korean_nori)에 종속 — 본 Task는 질의만.
  - **status term 값 = enum name 문자열**: 인덱스 `status`는 `ProductSearchDocument.status`가 `ProductStatus.name()`(String, keyword)로 색인된다(059). 따라서 terms 값은 `ProductStatus.ON_SALE.name()`/`SOLD_OUT.name()`(="ON_SALE"/"SOLD_OUT") 문자열로 보낸다(enum 객체 아님).
- **정렬 매핑**(createdAt 인덱스 부재 반영):
  - `LATEST`(기본, keyword 검색) → **`_score` desc + `productId` desc tiebreak**. (키워드 검색에서 "최신"은 인덱스에 createdAt가 없어 **연관도 우선**으로 매핑 — Task 결정 2(a) "keyword 검색 시 _score 우선". 회귀 기준은 keyword **없는** 목록뿐이며 그건 기존 PG 경로 유지.)
  - `PRICE_ASC` → `displayPrice` asc + productId asc, `PRICE_DESC` → `displayPrice` desc + productId desc.
- **페이징**: `from=page*size`, `size=clampedSize`(1~100). totalHits=`response.hits().total().value()`.
- **가격 정렬 권위(트레이드오프)**: 정렬 키는 ES 색인 `displayPrice`(사본, 변경 후 증분 색인 전 일시 stale 가능)지만 **화면에 표기되는 displayPrice는 PG SoT 재투영값**(권위). 전역 PG-권위 가격정렬은 전체 매치 ID를 받아 PG 정렬해야 해 ES 페이징을 깨고 비용↑ → 미채택. 사본 가격정렬 드리프트는 증분 indexer(059)가 수초 내 수렴(ADR-011) — 수용.
- 결과 추출: 어댑터는 `hit.id()`(=_id=productId) → `Long.parseLong`로 ID 랭킹 리스트 + totalHits 반환(문서 본문 재조회 불필요 — 표시는 PG 재투영).

### 결정 3 — 폴백 전환·서킷·타임아웃: **짧은 타임아웃 + 즉시 try/catch 폴백 + 경량 인프로세스 쿨다운(resilience4j 미도입)**
- 프로젝트에 resilience4j 없음 → 신규 의존/직접 CB 구현은 과도. **읽기는 멱등**이라 재시도 없이 **즉시 폴백**.
- **타임아웃**: ES `search` 호출에 짧은 요청 타임아웃(예 `shop.search.query.timeout-ms` 기본 800ms — slow ES를 빠르게 폴백). 연결 거부(ES 다운)는 즉시 실패.
- **폴백 트리거**: ES 호출이 예외(연결 실패/타임아웃/5xx/직렬화 오류)면 어댑터 경계에서 흡수 → PG 폴백. 도메인 예외로 누수 금지.
- **경량 쿨다운(미니 서킷) — 소유 위치 = 어댑터로 확정**: `EsProductSearchAdapter`가 `AtomicLong cooldownUntilEpochMs` 보유(예외→폴백 신호 흡수가 어댑터 경계라는 결정 3·6과 응집). ES 실패 시 짧은 쿨다운(예 `shop.search.query.cooldown-ms` 기본 5000ms) 동안 어댑터의 `search(...)`가 즉시 "비가용" 신호(예: 빈 Optional 또는 전용 예외)를 반환해 Service가 PG로 떨어진다(매 요청 타임아웃 비용 회피). 쿨다운 만료 후 다음 검색이 ES 재시도. 시각은 런타임 `System.currentTimeMillis()`(워크플로 샌드박스 아님). resilience4j급 half-open/슬라이딩윈도우는 후속 여지(YAGNI). Service는 쿨다운 상태를 알 필요 없음 — 어댑터가 "ES 했다/못했다"만 신호.
- **폴백 경로 = 기존 `findPublicProducts*`(pg_trgm)** — status 필터·페이징·정렬·displayPrice 계약 동일(코드 재사용, 신규 0).

### 결정 4 — 관측: **MeterRegistry Counter/Timer + WARN 로깅(검색어 PII 비로깅)**
- `MeterRegistry` 주입(자동제공). 메트릭:
  - `product.search.requests`(tag `path`=`es`|`fallback`) Counter — 폴백률 산출.
  - `product.search.es.duration` Timer — ES 검색 지연.
- 폴백 전환 시 WARN 로깅: 사유(타임아웃/연결/5xx)·결과 건수만, **검색어 원문 비로깅**(PII/길이 — 마스킹 또는 길이만). 
- actuator health: ES `elasticsearch` health는 infra/006이 이미 노출(readiness 제외 — 검색 장애가 앱 down 비유발). 본 Task는 health 신규 기여 없음(검색 폴백이 가용성 흡수). 

### 결정 5 — 드리프트 완화 재투영 책임
- (a) **status 이중 필터**: ES term 필터(1차) + PG 재투영 `WHERE p.status IN PUBLIC_STATUSES`(2차, ES 사본이 stale해 비공개로 바뀐 항목 제거). "검색엔 뜨는데 DRAFT/HIDDEN" 차단.
- (b) **랭킹 순서 보존**: ES ID 순서를 보존 — PG byIds 결과를 `Map<id,projection>`로 만들고 ES ID 리스트 순서로 재조립(누락 ID는 드리프트 제거된 것).
- (c) **count 정합**: `totalElements=ES totalHits`로 둔다. 드리프트로 페이지 내용이 size보다 줄 수 있으나(드문 일시적), 재카운트는 연관도 페이징 의미를 깨므로 totalHits 채택(드리프트 항목은 ES term 필터로 대부분 1차 차단됨 — 2차는 보강). 이 선택을 코드 주석·plan에 명시.
- (c-보강) 클릭스루 상세는 `getPublicProductDetail`이 이미 PG SoT 단건 검증(미존재·DRAFT·HIDDEN→404, 활성 variant만) — **무변경 재사용**으로 "검색엔 뜨는데 품절/삭제" 닫힘.

### 결정 6 — 검색 어댑터 모듈 배치: **`product/search` 내부(059 인접)**
- `product/search/ProductSearchPort`(인터페이스, product 내부 — cross-module 아님이라 spi 불필요) + `product/search/EsProductSearchAdapter`(impl, `ElasticsearchClient` 사용, `ProductSearchIndexConfig`에 @Bean 등록 — 동일 게이트 상속). 검색 결과 record `ProductSearchHits(List<Long> ids, long totalHits)`(product 내부).
- `PublicProductService`는 `ObjectProvider<ProductSearchPort>` 주입(ES 부재·flag off 시 빈 부재 → 항상 PG). 코어 서비스 자체는 ES 비의존 배선(풀 컨텍스트 안전 — 신규 규칙 §1). ModularityTests: 전부 product 내부 → 위반 0.

### 결정 7 — 키워드 정규화·안전
- trim/blank→null(현행 유지). **타입드 클라이언트 빌더**(`multiMatch.query(keyword)`)는 파라미터 바인딩이라 query_string 인젝션 위험 없음(query_string/simple_query_string 미사용).
- **과대 길이 방어**: keyword 길이 상한(예 100자) 초과 시 절단 또는 폴백(구현 시 확정, 기본 절단).
- **deep paging 가드**: `from+size`가 ES `max_result_window`(기본 10000) 초과 시 폴백 또는 빈 결과. 현행 size≤100 클램프 + page 가드(`(page+1)*size<=10000`) 추가.

---

## 2. 영향 범위 (파일)

### 신규 (backend-implementor)
- `product/search/ProductSearchPort.java` — 검색 읽기 포트(인터페이스): `ProductSearchHits search(String keyword, Long categoryId, List<ProductStatus> statuses, PublicProductSort sort, int page, int size)`. product 내부 DTO/scalar만.
- `product/search/ProductSearchHits.java` — record(List<Long> ids 랭킹순, long totalHits). product 내부.
- `product/search/EsProductSearchAdapter.java` — `ElasticsearchClient` 호출(bool+multi_match 부스팅+status terms+categoryId term+sort+from/size), 타임아웃, hit.id()→ID 추출. 예외→폴백 신호(상위에서 흡수). `ProductSearchIndexConfig`에 @Bean(게이트 상속). MeterRegistry로 ES 지연 기록.
- 테스트(아래 §4).

### 수정 (backend-implementor)
- `product/service/PublicProductService.java` — `findPublicProducts`에 keyword 분기(ES→PG 재투영) + 폴백 경계 + 쿨다운 + 메트릭. `ObjectProvider<ProductSearchPort>` + `MeterRegistry` 주입. status 화이트리스트 단일 소유 유지. keyword 없으면 기존 경로 그대로.
- `product/repository/ProductRepository.java` — `findPublicProductSummariesByIds(List<Long> ids, List<ProductStatus> statuses)` 추가(읽기 전용, 기존 집계식 동일, `WHERE p.id IN :ids AND p.status IN :statuses`, ORDER BY 없음 — 메모리 재정렬). 기존 쿼리·pg_trgm 폴백 쿼리 무변경.
- `application.yml` — `shop.search.query.{timeout-ms:800, cooldown-ms:5000, max-keyword-length:100}` 추가(기본값 포함).
- **`product/service/PublicProductServiceTest.java`(기존 단위 테스트 — 필수 갱신)** — `PublicProductService`에 `ObjectProvider<ProductSearchPort>` + `MeterRegistry` 2개 의존이 생성자로 추가되므로 `@RequiredArgsConstructor` 생성자 arity가 5→7로 바뀐다. 이 테스트는 명시적 5-인자 생성자(`new PublicProductService(...)`, 현재 line 82-84)로 직접 생성하므로 **컴파일이 깨진다**. 생성자 호출을 갱신: 추가 인자로 `ObjectProvider<ProductSearchPort>` mock(기본 `getIfAvailable()`/`getObject()`가 empty/없음 → keyword 분기에서 항상 PG로 떨어지게 stub)과 `MeterRegistry`(`io.micrometer.core.instrument.simple.SimpleMeterRegistry` 권장 — 실제 인스턴스)를 전달. 기존 keyword-없는/있는 PG 경로 단언은 그대로 유지(ObjectProvider empty라 ES 미경유). **구현자는 `PublicProductService`를 직접 생성하는 다른 테스트가 있는지도 grep으로 확인해 함께 갱신**(없으면 무동작).

### 무변경(재사용/전제)
- `PublicProductServiceResponse.list`·`PublicProductFacadeImpl.listProducts`·`PublicProductFacade`·`PublicProductRestController`·`PublicProductViewController`·`ProductSearchCondition`·`templates/product/list.html`(표면 무변경 — read path 교체 자동 반영), `ProductSummaryProjection`·`PublicProductSummaryResponse`·`PageResponse`·`PublicProductDtoMapper`·`PublicProductSort`, `getPublicProductDetail`(상세 SoT — 클릭스루), `findPrimaryImages`, displayPrice/soldOut 헬퍼, `SecurityConfig`(permitAll 무변경), V1~V12 마이그레이션·pg_trgm 인덱스, ES 매핑/indexer/재색인(T2+3/T4), event-catalog/§5·notification 전부.

> **view-implementor 불요**: 표면(템플릿·모델 키·URL·정렬 셀렉트) 무변경이 목표이고 "검색 저하" 안내 배지는 1차 미도입(우아한 폴백이 결과를 그대로 반환). read path 교체가 facade→service 내부에서 닫혀 화면 자동 컷오버.

## 3. 검색 읽기 데이터 흐름
1. GET /products 또는 /api/v1/products → facade/ServiceResponse → `PublicProductService.findPublicProducts(keyword,categoryId,sort,pageable)`.
2. keyword==null → 기존 PG 집계 switch 반환(회귀 0).
3. keyword!=null 且 ObjectProvider 존재 且 쿨다운 비활성 → `ProductSearchPort.search(...)`(ES):
   - bool(multi_match name^3>description^2>categoryName^1 + status terms + categoryId term) + sort(결정 2) + from/size → `ProductSearchHits(ids, totalHits)`.
4. `ProductRepository.findPublicProductSummariesByIds(ids, PUBLIC_STATUSES)` → PG SoT 재투영(드리프트 status 제거) → ES ID 순서로 재정렬 → `PageImpl(ordered, clamped, totalHits)`.
5. ES 예외/타임아웃 → 메트릭 + 쿨다운 open + WARN(검색어 비로깅) → **기존 `findPublicProducts*`(pg_trgm) 폴백** 반환.
6. 호출자(REST/View)는 동일 이미지 IN+DTO+PageResponse 조립(무변경). 클릭스루 상세는 PG SoT 재확인(무변경).

## 4. 검증 (testing-rule + verification-gate + 신규 규칙 §4)
### 단위/슬라이스(Mockito — 타깃)
- 어댑터 DSL 조립(multi_match 부스팅·status terms·categoryId term·sort 매핑·from/size). Service keyword 분기(있음→포트+재투영, 없음→기존 PG). 폴백 경계(포트 예외→PG 위임, 도메인 예외 비누수). 재투영 시 드리프트 status 제거 + ES 랭킹 순서 보존 + totalHits 보존. 쿨다운(실패 후 window 내 ES 스킵). keyword 길이/ deep-paging 가드. ObjectProvider empty→항상 PG.
### DB 통합(Testcontainers PG)
- keyword 없는 목록 회귀(집계 3종 정렬·displayPrice·count 불변). `findPublicProductSummariesByIds` 집계가 공개목록과 동일(드리프트 status 제외). 폴백(pg_trgm) status/페이징/정렬/displayPrice 계약.
### 검색 통합(Testcontainers ES Nori + PG — 059 하니스, @DirtiesContext)
- 형태소 매칭("맥북케이스"↔"맥북 케이스"), 부스팅 랭킹 순서, status 필터(비공개 제외), 페이징(from/size·totalHits), 정렬 매핑(LATEST=_score, price=displayPrice). **ES 다운 토글**(컨테이너 stop 또는 잘못된 uri) → PG 폴백 결과 반환 + 핵심 경로 무영향. 드리프트(ES ON_SALE인데 PG HIDDEN) 항목 목록 제거.
### Security/REST(MockMvc — ES 불요)
- GET /api/v1/products·/products permitAll(비인증 200), 응답 포맷·모델 키 무변경, 정렬 파라미터 바인딩. 상세 비공개 404 회귀. (ES 부재 → 폴백 경로로 200.)
### 브라우저 E2E(e2e-runner — 앱 기동 전제, 별도 스텝)
- 신규 `PublicProductSearchE2eTest`(extends `AbstractE2eTest`): /products 검색어 입력→결과 표기, 정렬 변경·페이징 이동 시 검색어 보존, 카테고리 필터 결합, 클릭스루 상세 진입. **ES 없이 앱 기동해도 동일 뷰 경로(폴백 pg_trgm)로 검색박스 표면이 동작함을 검증**(Nori/연관도는 위 검색 통합 테스트가 담당). 앱 기동(bootRun + KEK 등 메모리 선례)·`./gradlew e2eTest`는 메인이 별도 스텝으로 e2e-runner에 위임.
### 회귀(메인 동적 게이트)
- 기존 목록/상세/REST·관련 화면 그린. keyword 미입력 탐색/주문 경로 회귀 0. ModularityTests/ArchUnit 그린. **메인이 풀 `./gradlew test` 직접 그린 + Modulith verify 확인**(신규 규칙 §4 — 게이팅 회귀는 타깃 실행이 못 잡음). Testcontainers 반복은 타깃, 풀스위트 마지막 1회. E2E는 e2e-runner 스텝 그린 별도 확인.

## 5. Acceptance Criteria 매핑
| Task AC | 충족 |
|---|---|
| keyword 검색 ES Nori 매칭 + status 화이트리스트 + 페이징/정렬/displayPrice 계약 동일, keyword 없는 목록 100% 기존 | 결정 1·2·5 + 검색/DB 통합 |
| ES 다운→pg_trgm 폴백 자동 + 핵심 경로 무영향 + 폴백 관측 | 결정 3·4 + ES 토글 통합 테스트 |
| 비공개/품절/삭제 닫힘(status 이중필터+상세 SoT) | 결정 5 + 드리프트 테스트 |
| 검색박스 ES 경로 자동 사용(표면 무변경) | 결정 1(facade→service 내부 교체) + E2E |
| 인가/스키마/이벤트/notification 무변경 + ModularityTests·풀스위트 그린 | §2 무변경 + 회귀 |

## 6. 트레이드오프
- **ES 내부 분기 vs 별도 오케스트레이션**: findPublicProducts 단일 변경점이 REST/View 동시 컷오버·계약 무변경(채택).
- **사본 가격정렬 vs PG-권위 전역정렬**: 사본 정렬이 ES 페이징·연관도 보존(채택), 표기값은 PG 권위. 전역 PG정렬은 페이징 파괴·비용(기각).
- **latest=_score(keyword 시)**: 인덱스 createdAt 부재 + 검색 연관도 우선이 자연스러움(채택). createdAt 색인 추가는 T2+3 매핑 변경이라 범위 밖.
- **timeout+쿨다운 vs resilience4j**: 신규 의존 없이 즉시 폴백+지속장애 비용 회피(채택). 풀 CB(half-open/윈도우)는 후속(YAGNI).
- **totalHits count**: 연관도 페이징 의미 보존 위해 ES totalHits 채택, 드리프트 일시 오차 수용(기각: 재카운트).
- **view-implementor 없음**: 표면 무변경 목표 — read path 내부 교체로 화면 자동 컷오버(배지 미도입).

## 7. 구현 시 해소할 검증 게이트(추정 금지 — 실측)
1. elasticsearch-java 8.18.x `search(...)` + `bool`/`multiMatch`(fields^boost)/`terms`/`term`/`sort`(score, field scaled_float)/from/size/`hits().total().value()`/`hit.id()` 정확 시그니처.
2. 검색 호출 타임아웃 적용 방식(요청 옵션 vs 클라이언트 transport timeout) 실측 — slow ES에서 폴백 트리거 확인.
3. `findPublicProductSummariesByIds` 집계가 공개목록과 동일 displayPrice/purchasable(패리티) + IN 절 성능(대량 ID는 size≤100라 무해).
4. ObjectProvider(ProductSearchPort) 부재(test/ES off)에서 PublicProductService 배선·항상 PG + 풀 `@SpringBootTest` 회귀 0(baseline 대조 — 신규 규칙 §1).
5. 쿨다운/타임아웃/keyword 길이/deep-paging 가드 단위 검증. 검색어 원문 비로깅 확인.
6. ES 토글 통합에서 폴백이 같은 계약(status/페이징/정렬/displayPrice) 반환 + keyword 없는 목록·상세·장바구니 무영향.
7. E2E는 앱 기동 필요 — 메인이 bootRun(ES 선택)·e2eTest 스텝으로 e2e-runner에 위임(풀스위트 게이트와 별도).

## 8. 워크플로우
1. (완료) 코드 대조 + plan → **plan-reviewer → 필요 시 plan-fixer**.
2. PASS 후 **backend-implementor**(풀스위트 금지, `--tests` 타깃). **view-implementor 불요**(표면 무변경).
3. **reviewer** → FAIL 시 **fixer**(최대 3회).
4. **메인이 풀 `./gradlew test` 그린 + ModularityTests 직접 확인**(verification-gate §2). baseline 대조 회귀 0.
5. **E2E**: 메인이 앱 기동 후 **e2e-runner**로 `PublicProductSearchE2eTest` 실행·통과 확인(별도 스텝 — gradlew test 게이트 밖).
6. 보고. 커밋은 사용자 요청 시.

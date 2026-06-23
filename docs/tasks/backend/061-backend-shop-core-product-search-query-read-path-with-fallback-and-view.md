# 061. shop-core 상품 검색 — ES 읽기 경로(Nori 랭킹·status필터·페이징) + 장애 폴백 + 뷰/목록 컷오버 (with View)

> 출처: 상품 검색 개선 이니셔티브(ADR-011)의 T5(검색 읽기 경로) + T6(뷰/목록 컷오버) 통합 Task.
> ADR-011은 "상품 검색 = Elasticsearch(+Nori) 보조 인덱스, SoT = PostgreSQL, ES는 사본(언제든 재색인 복원)"을 확정했다. 본 Task는 그중 읽기(조회) 경로와 화면 컷오버만 담당한다.
> 범위 SSOT: 본 문서. 설계 결정(쿼리 DSL·읽기모델 분리 형태·폴백 전환 임계·서킷 정책·모듈 배치)은 docs/plans/backend/061-product-search-query-read-path-with-fallback-and-view-plan.md 에 위임한다.

## 이니셔티브 Task 맵 (교차참조 — 본 Task의 의존 전제)
- T0 backend/058: pg_trgm + GIN(선행 와일드카드 풀스캔 완화). 본 Task가 ES 장애 폴백 경로로 재사용한다.
- T1 infra/006: ES/OpenSearch + Nori 인프라(엔진·클라이언트·docker-compose·헬스). 범위 밖.
- T2+3 backend/059: 색인 매핑 + 이벤트 기반 indexer(생성/수정/상태/variant·가격 변경 → ES 갱신). 본 Task가 이 인덱스를 조회한다. 범위 밖.
- T4 backend/060: 풀 재색인·백필 잡(초기 적재·매핑 변경·드리프트 복구). 범위 밖.
- T5+6 backend/061 = 본 Task.

> 본 Task는 T0·T1·T2+3·T4에 의존한다(폴백 경로·ES 엔진/클라이언트·검색 인덱스·인덱스 데이터가 존재한다는 전제). 선행 Task가 아직 머지되지 않았다면 plan 단계에서 인터페이스 계약(인덱스 이름·문서 스키마·ES 클라이언트 빈)을 선행 Task plan과 맞춘 뒤 착수한다. ES 클라이언트·매핑·indexer를 본 Task에서 만들지 않는다.

---

## Target
shop-core product 모듈(검색 읽기 경로) + web/product(목록 화면 컷오버)

> 읽기 전용이다. 검색 인덱스를 쓰지(write) 않는다 — 색인은 T2+3(indexer)·T4(재색인) 책임이며 본 Task는 무변경 전제다. 신규 Kafka 이벤트·notification·스키마 변경 없음. 자동완성·패싯·동의어·검색어 로그/분석 적재는 범위 밖(후속).

## Goal
1. 공개 상품 검색(keyword 존재) 읽기 경로를 ES 쿼리로 교체한다. ES는 Nori 형태소 분석 기반 match(이름>설명>태그 등 필드 부스팅) + status 화이트리스트 필터([ON_SALE, SOLD_OUT]) + 페이징 + 기존 정렬 옵션(latest/priceAsc/priceDesc) 호환으로 검색 결과(상품 ID + 랭킹 순서)를 돌려준다. 검색 결과를 기존 목록 읽기 모델로 투영해 기존 목록 응답 계약(displayPrice/status/페이징/정렬)을 바이트 단위로 유지(회귀 0)한다.
2. ES 비가용 시 graceful degrade — ES 장애(연결 실패·타임아웃·5xx·서킷 오픈)면 T0의 pg_trgm/LIKE(DB) 경로로 자동 폴백한다. 검색 장애가 목록·상세·장바구니·주문 등 핵심 경로를 절대 차단하지 않는다(검색 표면만 저하). 폴백 전환 기준·관측(메트릭/로그)을 명시한다.
3. 드리프트 완화(ADR-011 원칙 4) — (a) 쿼리 시 status 필터로 "검색엔 뜨는데 비공개(DRAFT/HIDDEN)"를 닫고, (b) 클릭스루 시 SoT(상세, getPublicProductDetail)에서 status·활성 variant를 재확인해 "검색엔 뜨는데 품절/삭제"를 닫는다(상세는 이미 PG SoT 단건 조회 — 무변경 재사용). 목록 투영도 PG SoT projection을 거치므로 status가 ES 사본과 어긋난 항목은 화면에서 제거/SOLD_OUT 처리된다.
4. 뷰/목록 컷오버 — 기존 공개 상품 목록 화면(GET /products)의 검색박스가 read path 교체로 자동으로 ES 경로를 사용한다. 표면(템플릿·모델 키·URL·정렬 셀렉트) 변경을 최소화한다(원칙적으로 무변경 — read path만 교체). REST(GET /api/v1/products)도 동일 경로를 사용한다.

## Context
### 현재(교체 대상) 코드 — 정렬/페이징/displayPrice/status 노출 계약을 그대로 유지해야 함
- product/repository/ProductRepository.java: 공개 목록 집계 쿼리 3종(findPublicProductsLatest/findPublicProductsPriceAsc/findPublicProductsPriceDesc). status IN :statuses + 상품명 단일 컬럼에 대한 선행 와일드카드 LIKE(소문자) — 풀스캔(ADR-011 맥락). GROUP BY p.id, displayPrice = COALESCE(MIN(활성 v.price), p.basePrice), purchasableVariantCount = SUM(CASE …). countQuery 분리.
- product/service/PublicProductService.java: findPublicProducts(keyword, categoryId, sort, pageable) — size 1~MAX_SIZE(100) 클램프, keyword trim/blank→null 정규화, sort enum별 repository 메서드 선택. status 화이트리스트([ON_SALE, SOLD_OUT]) 단일 소유(이 Service 한 곳). findPrimaryImages(IN 배치 N+1 회피). getPublicProductDetail(상세 단건 SoT — 클릭스루 재확인에 재사용, 무변경). resolveDisplayPrice/isSoldOut/isVariantAvailable 헬퍼.
- product/service/PublicProductServiceResponse.java(REST 조합): list(...) — sort String→enum, findPublicProducts 호출, 대표이미지 IN 조회, projection+이미지→PublicProductSummaryResponse 조립, PageResponse.of 래핑.
- product/spi/PublicProductFacade.java(View 포트) + product/service/PublicProductFacadeImpl.java: listProducts(keyword, categoryId, sort, page, size) → PublicProductPage(content, page, size, totalElements, totalPages).
- web/product/PublicProductViewController.java: GET /products — page/size 보정, ProductSearchCondition 생성, publicProductFacade.listProducts(...) 호출, 모델 키 products/searchCondition/categories. GET /products/{id} 상세(클릭스루 — SoT 재확인 지점). permitAll(비인증 접근 가능, principal 미사용).
- web/product/ProductSearchCondition.java(View 모델 키 searchCondition): keyword/categoryId/sort(기본 latest)/page/size. 검색 폼·정렬 셀렉트·페이징 링크의 조건 유지.
- product/controller/PublicProductRestController.java: GET /api/v1/products(목록) / GET /api/v1/products/{id}(상세). permitAll, 소유권 없음.
- product/dto/ProductSummaryProjection.java(내부 projection): productId/name/displayPrice/categoryId/categoryName/status/purchasableVariantCount. hasPurchasableVariant(). product.dto 내부 전용(모듈 밖 비노출, Entity 미보유).
- 템플릿 templates/product/list.html: 검색 폼(GET /products, keyword/categoryId/sort/size hidden), 정렬 셀렉트(latest/priceAsc/priceDesc), 카드 displayPrice 표기, 페이징 링크(keyword/categoryId/sort/page/size 보존). 이 표면은 변경하지 않는 것을 기본으로 한다.

### 부재(선행 Task가 채움 — 본 Task 의존 전제, 본 Task가 만들지 않음)
- ES 엔진/클라이언트 빈·연결 설정(T1 infra/006). 검색 인덱스 매핑·indexer(T2+3 backend/059). 재색인 잡(T4 backend/060). pg_trgm 폴백 쿼리(T0 backend/058).

### 규칙·선례 (반드시 대조)
- 레이어: REST는 RestController → ServiceResponse → Service → Repository/검색어댑터, View는 @Controller(web) → product.spi facade → Service(architecture-rule). web은 product 내부 domain/repository/비공개 service·Entity·검색 클라이언트 직접 참조 금지. Entity·projection을 web/REST 응답에 직접 노출 금지(DTO/record만).
- 모듈 경계(package-structure-rule): 검색 읽기는 product 모듈 내부. ES 검색 어댑터/포트도 product 내부 패키지에 배치(예: product/search 또는 product/repository 인접 — plan 확정). 신규 도메인 모듈 추가 금지. ModularityTests/ArchUnit 그린 유지.
- 인가(api-authorization-rule): 공개 목록/상세/검색은 모두 permitAll(비인증 접근). 소유권 검사 불필요(공개 카탈로그). 검색 read path 교체는 인가 표면을 바꾸지 않는다 — SecurityConfig 무변경.
- 에러 응답(error-response-rule): REST 검색 실패는 폴백으로 흡수하므로 정상 200 반환이 기본. 폴백마저 불가한 극단(DB·ES 동시 장애)에서만 기존 5xx 핸들러 경유. View는 JSON 포맷 미사용 — 검색 저하는 화면에 결과 반환(필요 시 "검색 일시 저하" 안내 — plan 확정, 표면 최소).
- 테스트(testing-rule, verification-gate-rule): DB 통합은 Testcontainers, 검색 통합은 Testcontainers ES(아래 Test 절). 목록 화면 검색박스·조건부 가시성은 MockMvc/통합으로 못 잡으므로 브라우저 E2E(Playwright) 필수.
- 메모리 선례: verify-admin-list-page-features-with-e2e — 목록 페이지 검색/조건부 버튼은 실제 브라우저 E2E로 검증(MockMvc·통합은 쿼리↔템플릿 가시성 공백을 놓침). thymeleaf-reserved-model-attribute-names — 모델 키 application/session/param/request 금지(현 모델 키 products/searchCondition/categories는 안전, 유지). 인라인 script는 main 내부.
- forbidden-rule: dual-write 금지(본 Task는 읽기 전용 — ES에 쓰지 않음). 신규 모듈/직접 cross-module 의존 금지.

## plan 확정 필요 (설계 결정 — 본 Task가 plan에 위임)
1. 검색 읽기 모델 분리 형태: ES 검색을 product 내부 어댑터(예: ProductSearchPort/EsProductSearchAdapter)로 두고 PublicProductService가 keyword 존재 시 이를 호출할지, ServiceResponse에 분기를 둘지. (권장: Service가 keyword != null → 검색 어댑터(ID+랭킹) 조회 → PG에서 해당 ID들의 목록 projection을 SoT로 재투영(displayPrice/status/purchasableVariant 계산 재사용) → ES 랭킹 순서 보존. keyword 없으면 기존 목록 경로 그대로.) status 화이트리스트 단일 소유 위치(Service) 유지.
2. ES 쿼리 DSL: Nori match/multi_match + 필드 부스팅(이름 > 설명 > 태그 등 — 실제 색인 필드는 T2+3 매핑에 종속, plan에서 매핑 계약 확인 후 확정), status term 필터, from/size 페이징, 정렬 옵션(latest/priceAsc/priceDesc) 매핑 방식. 정렬과 연관도의 관계 확정: 기존 sort 옵션은 그대로 노출하되 (a) 기본 정렬에 연관도(_score)를 어떻게 끼울지(예: keyword 검색 시 _score 우선, 명시 sort 선택 시 해당 필드), (b) priceAsc/priceDesc를 ES 정렬로 줄지 PG 재투영 후 정렬할지(displayPrice는 활성 variant MIN 집계라 ES 사본 가격과 어긋날 수 있음 — 가격 정렬은 PG SoT 기준 권위 권장). 회귀 기준: keyword 없는 목록은 100% 기존 경로(_score 무관).
3. 폴백 전환 기준·서킷 정책: 무엇을 ES 장애로 보고(연결 거부/타임아웃/5xx/서킷 오픈) 언제 pg_trgm/LIKE로 떨어질지. 타임아웃 값, 재시도 여부(읽기라 멱등 — 짧은 재시도 또는 즉시 폴백), 서킷브레이커(resilience4j 등 기존 R2 resilience 선례 대조 — Task 045) 채택 여부. 폴백이 T0의 pg_trgm을 쓸지 현행 LIKE를 쓸지(T0 머지 전이면 LIKE, 후면 pg_trgm — plan에서 선행 의존 상태로 결정). 폴백 경로도 status 필터·페이징·정렬·displayPrice 계약 동일해야 함.
4. 관측(observability): 폴백 발생률·ES 검색 지연·에러율 메트릭(micrometer — Task 037 notification observability 선례 대조) 노출 키, 폴백 전환 로그 레벨/내용(검색어 PII 주의 — 원문 로깅 금지 또는 마스킹). actuator health에 ES 의존을 readiness로 넣을지(넣되 검색 장애가 앱 전체 down으로 번지지 않게 — health detail만, liveness 불포함). plan 확정.
5. 드리프트 완화 투영 책임: 검색 결과 ID를 PG projection으로 재투영할 때 (a) ES엔 있으나 PG에서 status가 비공개로 바뀐 항목 제거, (b) ES 랭킹 순서와 PG 재조회 순서 정렬 보존(IN + 메모리 재정렬, 또는 ID 순서 맵핑), (c) totalElements/totalPages를 ES totalHits로 줄지 재투영 후 보정할지(status 드리프트로 일부 제거 시 count 정합). plan 확정 — 페이징 계약 깨지지 않게.
6. 검색 어댑터 모듈 배치: product/search(신규 하위 패키지) vs product/repository 인접 vs product/spi 포트 + 내부 어댑터. Spring Modulith 모듈 경계 위반 없이(검색 클라이언트는 product 내부 의존), ArchUnit/ModularityTests 그린. plan 확정.
7. 키워드 정규화·안전: keyword trim/blank→null(현행 유지), ES 쿼리 인젝션·과대 길이 방어, 특수문자/빈 검색 처리. 페이지 size 클램프(현행 MAX_SIZE=100) ES from+size 상한(deep paging 가드) 정합. plan 확정.

## API Authorization
> docs/rules/api-authorization-rule.md 준수. 본 Task는 기존 공개 카탈로그 읽기 경로의 내부 구현만 ES로 교체한다. 인가 표면(권한·소유권·공개 여부)은 무변경이다.

| API/경로 | 공개 여부 | 최소 권한 | 상위 권한 허용 | 소유권 검사 | 비고 |
|---|---|---|---|---|---|
| GET /api/v1/products (REST, 기존) | permitAll(공개) | — (비인증 허용) | — | 불필요(공개 카탈로그) | 검색 read path만 ES로 교체. 응답 계약 무변경 |
| GET /api/v1/products/{id} (REST, 기존) | permitAll(공개) | — | — | 불필요 | 상세 — 클릭스루 SoT 재확인 지점, 무변경 |
| GET /products (View, 기존) | permitAll(공개) | — | — | 불필요 | 목록 화면 검색박스 — read path 교체로 ES 자동 사용 |
| GET /products/{id} (View, 기존) | permitAll(공개) | — | — | 불필요 | 상세 — 드리프트 완화(status·활성 variant 재확인) |

> 공개 카탈로그라 principal·소유권 무관. SecurityConfig 변경 없음. 검색 입력은 인증과 무관한 공개 파라미터(keyword/categoryId/sort/page/size) — 신규 권한 경계 없음.

## Requirements
### A. 검색 읽기 경로(ES) 교체 — T5
- keyword 존재 시 ES 쿼리로 검색: Nori 형태소 match(+필드 부스팅) + status 화이트리스트 term 필터 + from/size 페이징 + 기존 정렬 옵션(latest/priceAsc/priceDesc) 호환. 검색 결과(상품 ID + 랭킹 순서)를 받아 PG SoT projection으로 재투영(displayPrice/status/purchasableVariant — 기존 계산 재사용)해 PublicProductSummaryResponse/PublicProductPage 조립.
- keyword 없는 목록(전체/카테고리 필터만)은 기존 PG 집계 경로 그대로(ES 미경유 — 회귀 0). categoryId 필터는 ES 검색 시에도 적용(plan: ES term 또는 PG 재투영 단계 중 확정).
- 응답 계약 바이트 단위 유지: 모델 키(products/searchCondition/categories), DTO 필드(displayPrice/status/soldOut/primaryImageUrl/페이징 page·size·totalElements·totalPages), 정렬 옵션 3종. REST PageResponse 포맷 동일.
- 읽기 전용: ES에 쓰지 않는다(dual-write 금지). 인덱스 매핑·문서 스키마는 T2+3 계약을 소비만 한다.

### B. 장애 폴백 — T5
- ES 비가용(연결 실패/타임아웃/5xx/서킷 오픈) 시 pg_trgm(T0) 또는 LIKE 경로로 자동 폴백. 폴백 경로도 status 필터·페이징·정렬·displayPrice 계약 동일. 사용자에겐 (저하된) 검색 결과가 그대로 반환(핵심 경로 무중단).
- 격리: 검색 실패가 목록(keyword 없는)·상세·장바구니·주문·결제 경로를 차단하지 않는다. 검색 어댑터 예외는 폴백 경계에서 흡수하고 도메인 예외로 누수시키지 않는다.
- 폴백 전환·서킷·타임아웃 정책은 plan 확정(3번). 폴백 발생·지연·에러율 관측 노출(4번).

### C. 드리프트 완화 — T5
- 쿼리 시 status 화이트리스트 필터(ES term + PG 재투영 재확인 이중) — "검색엔 뜨는데 DRAFT/HIDDEN" 차단.
- 클릭스루(상세 진입) 시 SoT 재확인: getPublicProductDetail이 이미 PG에서 status·활성 variant를 단건 검증(미존재·DRAFT·HIDDEN → 404, 비활성 variant 비노출) — 무변경 재사용. "검색엔 뜨는데 품절/삭제" 닫힘.
- 목록 재투영이 PG SoT를 거치므로 ES 사본이 뒤처진(stale) 항목은 화면에서 제거 또는 SOLD_OUT 표기.

### D. 뷰/목록 컷오버 — T6
- GET /products 목록 화면 검색박스가 read path 교체로 ES 경로를 자동 사용(컨트롤러·facade 시그니처·모델 키 무변경이 목표). 정렬 셀렉트·페이징 링크·검색 폼 표면 변경 최소(원칙 무변경).
- 표면 변경이 불가피하면(예: "검색 저하" 안내 배지) main 내부 인라인만, 모델 키 예약어 회피. plan 확정.
- REST·View 둘 다 동일 검색 읽기 경로를 공유(중복 구현 금지).

### E. 공통
- 레이어/모듈 경계 준수(architecture-rule, package-structure-rule). web·REST에 Entity/projection 직접 노출 금지. 검색 클라이언트는 product 내부에서만 의존.
- 스키마/이벤트/notification 무변경. ES 인덱스 쓰기 무관(읽기 전용).

## Constraints
- 응답 계약 무변경(회귀 0): displayPrice(활성 variant MIN/basePrice 폴백) 계산, status 노출(ON_SALE/SOLD_OUT 화이트리스트), 페이징(page/size/totalElements/totalPages), 정렬 3종(latest/priceAsc/priceDesc), 모델 키, REST PageResponse 포맷. keyword 없는 목록은 100% 기존 PG 경로.
- 읽기 전용: ES에 쓰지 않는다(dual-write 금지 — ADR-011 원칙 2, forbidden-rule). 색인은 T2+3·T4 책임. 인덱스 매핑·문서 스키마 변경 금지(소비만).
- 핵심 경로 격리: 검색 장애가 목록(전체)·상세·장바구니·주문·결제·홈을 차단 금지(ADR-011 원칙 5). 폴백 또는 graceful degrade로 흡수.
- 인가 무변경: 공개 permitAll, 소유권 없음. SecurityConfig 무변경.
- 스키마/이벤트/notification 무변경: 마이그레이션 없음, event-catalog.md 불변, notification 미참조.
- 모듈 경계: 신규 도메인 모듈 금지. 검색 어댑터는 product 내부. 신규 cross-module 직접 의존 0. ModularityTests/ArchUnit 그린.
- 범위 밖(명시): 엔진·클라이언트·인프라(T1 infra/006) / 매핑·증분 indexer·색인 이벤트(T2+3 backend/059) / 풀 재색인·백필 잡(T4 backend/060) / 자동완성·패싯·동의어·검색어 분석 적재(후속). pg_trgm 폴백 인덱스 생성(T0 backend/058 — 본 Task는 소비). 가격/재고 정합 색인 로직(T2+3).

## Files
> 정확 경로/시그니처/패키지는 plan 확정. 아래는 선례 대조 기준 예시.
### 신규 (backend-implementor)
- product/search/ProductSearchPort.java(또는 product/spi) — 검색 읽기 포트(인터페이스): keyword/categoryId/status/sort/page/size → 검색 결과(상품 ID 목록 + 랭킹 순서 + totalHits). product 모듈 소유 DTO/scalar만.
- product/search/EsProductSearchAdapter.java — ES 클라이언트(T1 빈) 호출, Nori match + 부스팅 + status 필터 + 페이징 + 정렬 DSL 조립. 예외→폴백 신호 변환.
- (선택) product/search/ProductSearchFallback.java 또는 Service 내 폴백 분기 — ES 실패 시 pg_trgm/LIKE(T0/현행) 경로 위임.
- (선택) 검색 읽기 결과 내부 record(상품 ID + score/순서) — product.dto 내부 전용.

### 수정 (backend-implementor)
- product/service/PublicProductService.java — findPublicProducts에 keyword 존재 시 검색 포트 경유 + PG SoT 재투영 분기 추가(status 화이트리스트 단일 소유 유지). keyword 없으면 기존 PG 집계 그대로. 폴백 경계 배치.
- product/service/PublicProductServiceResponse.java — 검색 경로 결과를 기존 조립 흐름(대표이미지 IN + DTO 매핑 + PageResponse)에 합류(응답 계약 유지).
- product/spi/PublicProductFacadeImpl.java — listProducts가 교체된 Service 경로 사용(시그니처·PublicProductPage 무변경).
- (필요 시) product/repository/ProductRepository.java — 검색 결과 ID 집합에 대한 SoT 재투영 집계 쿼리 1개(IN + displayPrice/status/purchasableVariant 계산, ES 랭킹 순서 보존용). 폴백이 pg_trgm이면 T0가 추가한 메서드 재사용(중복 추가 금지).
- (관측) micrometer 메트릭/health 기여(폴백률·검색 지연 — plan 확정 위치).

### 수정 (view-implementor — 표면 변경 발생 시에만)
- (원칙 무변경) web/product/PublicProductViewController.java, templates/product/list.html, web/product/ProductSearchCondition.java — read path 교체가 화면에 자동 반영되므로 기본 무변경. "검색 저하" 안내 등 표면 추가가 plan에서 확정되면 이 파일들만 최소 수정(main 내부 인라인, 모델 키 예약어 회피).

### 무변경(재사용)
product/controller/PublicProductRestController.java(경로·시그니처), PublicProductFacade(포트 시그니처), ProductSummaryProjection, PublicProductDtoMapper, getPublicProductDetail(상세 SoT — 클릭스루 재확인), findPrimaryImages, displayPrice/soldOut/available 헬퍼, SecurityConfig, V1~최신 마이그레이션, event-catalog.md, notification 전부. ES 인덱스 매핑·indexer·재색인 잡(T2+3/T4 소유).

## Backend - View Contract
| 항목 | 값 |
|---|---|
| 목록/검색 화면 | GET /products → view product/list, 모델 키 products(PublicProductPage)/searchCondition(ProductSearchCondition)/categories(List CategoryResponse) — 무변경 |
| 검색 폼 | GET /products?keyword=&categoryId=&sort=&page=&size= — 무변경(URL·파라미터 동일, 내부 경로만 ES) |
| 정렬 옵션 | latest / priceAsc / priceDesc — 무변경(연관도는 keyword 검색 시 내부 _score, 표면 셀렉트 불변) |
| 상세(클릭스루) | GET /products/{id} → product/detail, SoT status·활성 variant 재확인(드리프트 완화) — 무변경 |
| REST 목록/검색 | GET /api/v1/products → PageResponse PublicProductSummaryResponse — 포맷 무변경, 내부 경로 ES |
| 폴백 표면 | ES 장애 시 사용자에겐 (저하된) 검색 결과 정상 반환, 핵심 경로 무중단(안내 배지는 plan 확정 시에만) |

## Acceptance Criteria
- keyword 검색 시 ES Nori 형태소 매칭(예: "맥북케이스"↔"맥북 케이스")으로 결과가 나오고, status 화이트리스트(ON_SALE/SOLD_OUT)만 노출되며, 페이징·정렬(latest/priceAsc/priceDesc)·displayPrice 표기가 기존 계약과 동일하다(회귀 0). keyword 없는 목록은 기존 PG 경로와 100% 동일.
- ES를 내리면(다운/타임아웃) 검색이 pg_trgm/LIKE 폴백으로 자동 전환되어 결과를 계속 반환하고, 목록(전체)·상세·장바구니·주문 경로는 영향 없이 동작한다(검색 표면만 저하). 폴백 전환이 메트릭/로그로 관측된다.
- "검색엔 떴는데 비공개/품절/삭제"가 닫힌다: 쿼리 status 필터 + PG 재투영 + 클릭스루 상세 SoT 재확인으로 stale 항목이 목록에서 제거/SOLD_OUT 처리되고, 비공개 상세는 404.
- 목록 화면 검색박스가 ES 경로를 사용(표면 무변경). 정렬/페이징/카테고리 필터가 검색과 함께 동작한다.
- 인가·스키마·이벤트·notification 무변경. ModularityTests/ArchUnit·풀 스위트 그린.

## Test
> testing-rule + verification-gate-rule. 목록 검색박스·조건부 가시성·정렬/페이징 결합은 MockMvc·통합으로 쿼리↔템플릿 가시성 공백을 못 잡으므로 브라우저 E2E(e2e-runner) 필수(메모리 verify-admin-list-page-features-with-e2e). 인라인 script가 main 밖이면 무동작·콘솔에러 없음 — E2E로.
- 단위/슬라이스(Mockito): 검색 어댑터 DSL 조립(Nori match + 부스팅 + status 필터 + from/size + 정렬 매핑). Service의 keyword 분기(있음→검색포트+재투영, 없음→기존 PG). 폴백 경계(검색 포트 예외→pg_trgm/LIKE 위임, 도메인 예외 비누수). 재투영 시 status 드리프트 항목 제거·랭킹 순서 보존·페이징 count 정합.
- DB 통합(Testcontainers PostgreSQL): keyword 없는 목록 회귀(기존 집계 3종 정렬·displayPrice·count 불변). 폴백 경로(pg_trgm/LIKE)의 status 필터·페이징·정렬·displayPrice 계약.
- 검색 통합(Testcontainers Elasticsearch/OpenSearch + Nori): 형태소 매칭(합성어 분해·띄어쓰기 정규화), 필드 부스팅 랭킹 순서, status 필터(비공개 제외), 페이징(from/size·totalHits), 정렬 옵션 매핑. ES 다운 토글 → DB 폴백 전환 검증(컨테이너 stop/타임아웃 유발 → 폴백 결과 반환 + 핵심 경로 무영향). (인프라 비의존 원칙과 충돌 시 별도 태스크/스텝 분리 — testing-rule 배치 절.)
- Security/REST(MockMvc): GET /api/v1/products·/products 검색 permitAll(비인증 200), 응답 포맷·모델 키 무변경, 정렬 파라미터 바인딩. 상세 비공개 404 회귀.
- 브라우저 E2E(e2e-runner, 필수): 목록 화면 검색어 입력 → ES 결과 표기(형태소 매칭) → 정렬 변경·페이징 이동에서 검색어 보존 → 카테고리 필터 결합. 클릭스루 상세 진입 시 비공개/품절 항목 안전 처리. (가능하면) ES 다운 시 검색 저하해도 목록 전체·상세·장바구니 화면 정상.
- 회귀: 기존 목록/상세/REST·관련 화면 그린 유지. keyword 미입력 주문/탐색 경로 회귀 0. 메인 에이전트가 ./gradlew test 풀 그린 + Modulith verify를 자기 눈으로 확인(verification-gate-rule). 검색 통합/E2E가 별도 태스크면 e2e-runner/해당 스텝 그린 확인.

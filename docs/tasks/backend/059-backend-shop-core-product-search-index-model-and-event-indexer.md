# 059. shop-core 상품 검색 — 색인 문서 스키마·Nori 매핑 + 이벤트 기반 indexer 쓰기경로 (T2+T3)

> 출처: 상품 검색 개선 이니셔티브. 방향 결정은 ADR-011(상품 검색을 ES(+Nori) 보조 인덱스로 분리, PG=SoT). 본 Task는 그 ADR이 후속 plan에 위임한 항목 중 색인 대상 필드·매핑·분석기(T2)와 이벤트 indexer 쓰기 경로(T3)를 통합 1개 Task로 다룬다.
> 범위 SSOT: 본 문서. 설계 결정(모듈 배치·정확한 매핑 JSON·이벤트 시그니처·인덱서 토폴로지)은 docs/plans/backend/059-product-search-index-model-and-event-indexer-plan.md 에 위임한다.
> 이니셔티브 Task 맵(경계 명확화): T0 backend/058(pg_trgm 브리지·폴백) · T1 infra/006(ES/OpenSearch 엔진·클라이언트 기동 — 본 Task의 전제) · T2+3 backend/059 = 본 Task · T4 backend/060(전량 재색인·백필 잡 — 본 Task의 매핑/문서 스키마를 재사용) · T5+6 backend/061(검색 읽기 모델·쿼리·랭킹·폴백·뷰 — 본 Task가 만든 인덱스를 조회). 인프라 기동·검색 쿼리는 본 Task 범위 밖.

## Target
shop-core (product 모듈 — 색인 document·매핑 부트스트랩 + product 도메인 이벤트 정의/발행 + 이벤트 구독 indexer)

> 색인 쓰기 경로에 한정한다. ES에 무엇을 어떤 매핑으로 적재할지(문서 스키마·Nori 분석기·버전드 인덱스+alias)와, product 도메인 변경을 어떻게 이벤트로 받아 ES upsert/delete 하는지(outbox 경유·dual-write 금지·실패 격리)까지가 범위다. 검색 질의·랭킹·자동완성·패싯·동의어·폴백·뷰는 범위 밖(T5+6). 전량 재색인 잡은 범위 밖(T4 — 단, 본 Task의 매핑/문서 스키마를 재사용하도록 인덱스 부트스트랩·document 변환을 재사용 가능한 형태로 노출).

---

## Goal
1. 색인 문서 스키마 + Nori 매핑 정의. PG products/product_variants/categories에서 도출 가능한 검색 문서(예: productId, name, description, categoryId, categoryName, status, displayPrice, 활성·구매가능 variant 존재 여부 등 — 실제 가용 필드는 코드 대조로 확정)를 1개 ES 문서 타입으로 정의한다. 한국어 형태소 검색을 위해 Nori 분석기를 텍스트 필드(이름/설명/카테고리명)에 적용하고, 필드 부스팅 후보(이름 > 설명 > 카테고리)를 매핑 설계에 반영한다.
2. 버전드 인덱스 + alias 부트스트랩(멱등). 물리 인덱스는 버전드(예: products-v1)로 만들고 읽기/쓰기는 alias(예: products)로 가리킨다. 매핑 변경 시 새 버전 인덱스를 만들어 alias를 스왑할 수 있게 한다(T4 재색인이 이 부트스트랩을 재사용). 부트스트랩은 멱등(이미 있으면 생성하지 않음).
3. 이벤트 기반 indexer 쓰기 경로. product 도메인의 색인 영향 변경(상품 생성/수정/상태 전이/삭제, variant 가격·활성·재고로 인한 구매가능 여부 변화)을 Kafka 이벤트(Transactional Outbox 경유)로 발행하고, 이를 구독하는 indexer가 ES 문서를 upsert/delete 한다. dual-write(트랜잭션 내 ES 직접 쓰기) 금지 — ADR-011 원칙. 색인 실패는 핵심 경로(상품 등록/주문)를 막지 않도록 격리하고 재시도·DLQ로 처리한다.

## Context
> 모든 경로는 코드 대조 확인(2026-06-22). 본 Task 착수 plan 단계에서 재대조한다.

### 색인 대상 필드 출처(코드 대조)
- product/domain/Product: id, name(not null), description(nullable), category(ManyToOne, nullable — 미분류 허용), ownerId(스칼라 long), basePrice(BigDecimal numeric(12,2)), status(Enumerated STRING). 정적 팩토리 create(status=DRAFT 강제) + 의도 메서드 update(category,name,description,basePrice,status)로만 변경.
- product/domain/ProductStatus: DRAFT, ON_SALE, SOLD_OUT, HIDDEN(V3 CHECK 대문자 1:1). 공개 노출 화이트리스트는 기존 공개 목록 쿼리 기준 ON_SALE, SOLD_OUT(코드: PublicProductService/ProductRepository.findPublicProducts 계열의 statuses 파라미터). DRAFT/HIDDEN은 비노출.
- product/domain/ProductVariant: price(BigDecimal), stock(int), isActive(boolean), sku. displayPrice = COALESCE(MIN(활성 variant price), basePrice), purchasableVariantCount = 활성 그리고 stock>0 개수 — 기존 공개 목록 집계(ProductRepository.findPublicProductsLatest 등 ProductSummaryProjection 산출식)와 동일 정의를 색인 문서가 따라야 검색 결과와 목록이 일관된다(이 산출식이 색인 document 변환의 SoT).
- product/repository/ProductRepository: 현재 공개 검색은 상품명 단일 컬럼 선행 와일드카드 LIKE(ADR-011 동기 — 풀스캔·형태소 부재). 본 Task는 이 쿼리를 건드리지 않는다(읽기 경로 교체는 T5+6).

### 이벤트 인프라 현황(코드 대조 — 무엇이 있고 무엇을 신설하는가)
- product 도메인 이벤트는 현재 0개. product/event/·product/messaging/ 에 package-info.java만 존재(이벤트 클래스 없음). 따라서 색인 트리거 이벤트는 신규 정의 필요.
- 기존 이벤트 발행 패턴(선례): order/event/OrderCompletedEvent 등은 Externalized 토픽 record + ApplicationEventPublisher.publishEvent 를 Transactional 안에서 호출 → Spring Modulith Event Publication Registry(event_publication INCOMPLETE = Outbox) → 커밋 후 Kafka 외부화(ADR-002). product도 이 패턴을 그대로 따른다.
- 기존 6개 알림 토픽(order-completed/payment-failed/order-cancelled/shipping-started/member-registered/password-reset-requested)은 notification 구독용 알림 계약이며 색인 용도가 아니다. 색인 이벤트는 별개 계약이다.
- product 변경 진입점(이벤트 발행 지점 후보 — plan 확정): ProductService.register(생성), ProductService.update(수정+상태 전이 포함 — 별도 상태전이 메서드 없이 generic update로 status 변경됨), ProductVariantService.createVariant/updateVariant/deleteVariant(가격·활성·구매가능 변화), StockAdjustmentService(재고 변동 → 구매가능 여부 변화). 상품 삭제 경로 유무는 plan에서 코드 재확인(있으면 delete 이벤트, 없으면 status=HIDDEN/제외만).

### indexer/consumer 배치 선례
- notification 컨슈머(notification/consumer/NotificationEventConsumer): KafkaListener(topics, groupId) → Service 위임만, Repository 직접 호출·예외 캐치 금지(DefaultErrorHandler/DLQ 위임), Profile("kafkatest | !test")로 슬라이스 격리. indexer 컨슈머도 동형 패턴(별도 groupId).
- 모듈 경계 선례: order.spi published port facade, product/spi/UserDirectory ← member/adapter(의존 역전, NamedInterface). indexer가 product 내부에 있으면 이벤트→indexer→ES가 모듈 내부로 닫힌다.

## plan 확정 필요 (설계 결정 — 본 Task가 plan에 위임)
1. indexer 모듈 배치(핵심 위임 항목). 색인 이벤트 구독 indexer를 (A) product 모듈 내부 하위(예: product/messaging 또는 product/indexer)에 둘지, (B) 별도 search 모듈/consumer로 분리할지 plan에서 확정한다. 판단 기준: package-structure-rule의 도메인 6개 고정·정당한 사유 없이 모듈 추가 금지(forbidden-rule) vs 검색이 product와 독립 진화한다는 ADR-011 동기. 권장 출발점: 1차 범위에선 색인 대상이 product 도메인뿐이므로 신규 모듈 없이 product 내부 하위 컴포넌트로 두고, ES 클라이언트는 공통/인프라 경계(infra/006 산출물)를 주입받는다. 단 검색 읽기(T5+6)에서 별도 search 표면이 커지면 그때 모듈 분리를 재검토. 최종은 plan + ModularityTests/ArchUnit 그린 기준으로 확정.
2. 색인 이벤트 계약 설계(신규). 어떤 이벤트를 신설할지: (a) 도메인별 세분 이벤트(ProductCreated/ProductUpdated/ProductStatusChanged/ProductDeleted/ProductVariantChanged) vs (b) 단일 ProductIndexingRequested(productId + 변경종류 + 색인 필요 스냅샷) 통합 이벤트. 권장: indexer가 productId로 현재 상태를 재구성(또는 자족 스냅샷 동봉)하는 멱등 upsert/delete 트리거 1~2종으로 단순화(대량 매핑 변경에 강함). 이벤트는 outbox 경유(Externalized)·자족(컨슈머 재조회 최소)·eventId+발생시각 포함(event-contract-rule). 계약 확정 시 docs/event-catalog.md를 코드보다 먼저 갱신하고 토픽을 docs/architecture.md 섹션5에 등재(ADR-004). 색인 토픽은 notification 비구독(알림 계약 아님)임을 카탈로그에 명시.
3. document 변환 SoT 재사용. 색인 document(productId/name/description/categoryName/status/displayPrice/구매가능 여부)의 산출식을 기존 공개 목록 집계(displayPrice=COALESCE(MIN 활성 price, basePrice), purchasable=활성 그리고 stock>0)와 동일 정의로 맞춰 검색-목록 일관성을 보장한다. 변환 로직을 T4 재색인이 재사용할 수 있게 배치(plan 확정 — 별도 indexer document mapper).
4. Nori 매핑·부스팅·인덱스 토폴로지. Nori 분석기 설정(tokenizer/decompound 모드·품사 필터·정규화)과 필드별 analyzer 적용, 부스팅 후보(이름>설명>카테고리), 버전드 인덱스명·alias명·매핑 JSON 위치(클래스/리소스). 동의어·자동완성·패싯은 후속(범위 밖) — 1차는 형태소+부스팅 매핑까지. 매핑 부트스트랩 컴포넌트 위치·멱등 생성 방식(애플리케이션 기동 시 vs 명시 호출 — T4와의 책임 분담) 확정.
5. 실패 격리·멱등·드리프트. indexer 처리 멱등(같은 이벤트 재처리 시 동일 결과 — eventId/버전/productId 기준), 재시도·DLQ 정책(notification DefaultErrorHandler 선례 대조), 색인 실패가 product 트랜잭션을 롤백시키지 않음(outbox 분리로 구조적 보장). status 전이(ON_SALE↔SOLD_OUT/HIDDEN/DRAFT) 색인 반영으로 검색엔 뜨는데 품절/삭제 드리프트 완화(ADR-011 섹션4).
6. ES 클라이언트 의존 주입 경계. ES/OpenSearch 클라이언트(infra/006 산출물 가정)를 indexer가 어떻게 주입받는지(공통 인프라 빈)·자체호스팅 전제(고정 결정)와 정합. 클라이언트 기동·연결 설정 자체는 본 Task 범위 밖(T1).

## Event Contract (색인 — plan에서 event-catalog 먼저 갱신)
> event-contract-rule 준수. 본 Task는 신규 색인 이벤트를 도입한다(product 이벤트 0 → N). 알림 6종과 별개 계약이며 notification은 구독하지 않는다.

| 항목 | 내용 |
|---|---|
| 발행 모듈 | product |
| 발행 기반 | Spring Modulith Transactional Outbox(Externalized, event_publication → Kafka) — dual-write 금지(ADR-002/011) |
| 구독자 | 색인 indexer(배치는 plan 1번 — product 내부 하위 또는 search 모듈), groupId는 notification과 분리 |
| 토픽(후보) | 예: product-index-changed(또는 세분 토픽) — kebab-case, plan 확정 후 event-catalog/architecture 섹션5에 등재 |
| 페이로드 | eventId(UUID, 멱등 키) + 발생시각(KST ISO-8601, ADR-009) + productId + 변경종류/삭제여부 + 색인 필요 필드(자족) — event-catalog SSOT에 필드표 추가 |
| 멱등 | 컨슈머는 재시도·DLQ 대비 멱등 upsert/delete(event-contract-rule) |

## Requirements
### A. 색인 문서 스키마 + Nori 매핑(T2)
- 검색 document 정의: productId(키), name, description?, categoryId/categoryName, status, displayPrice(=COALESCE(MIN 활성 variant price, basePrice)), purchasable(활성 그리고 stock>0 존재 여부 또는 count) 등 — 실제 가용 필드는 코드 대조로 확정, 노출 화이트리스트(ON_SALE/SOLD_OUT) 정책은 색인 시 status 필드로 싣고 필터링은 읽기(T5+6)에 위임(색인엔 status 보존).
- Nori 분석기를 텍스트 필드(name/description/categoryName)에 적용, 부스팅 후보(name>description>category) 매핑 반영. 동의어·자동완성·패싯은 후속(범위 밖).
- 버전드 인덱스(products-v1) + alias(products) 부트스트랩, 멱등 생성, 매핑 JSON 단일 출처. T4 재색인이 동일 부트스트랩/document 변환 재사용 가능.

### B. 이벤트 기반 indexer 쓰기 경로(T3)
- product 변경 진입점(register/update(상태전이 포함)/variant create·update·delete/stock 조정)에서 색인 이벤트를 outbox로 발행(ApplicationEventPublisher + Externalized, Transactional 내부). dual-write 금지.
- indexer(컨슈머)가 이벤트 구독 → ES upsert(생성/수정/상태전이/가격·구매가능 변화) / delete(삭제 또는 비노출 정책에 따른 제거 — plan 확정: delete vs status로만 표현). 컨슈머는 Service 위임·멱등·예외 비캐치(DLQ 위임), Profile 슬라이스 격리(notification 선례).
- 색인 실패 격리: product 트랜잭션 무영향(outbox 분리), 재시도·DLQ. 핵심 경로(상품 등록/주문) 비차단.

### C. 공통
- 레이어: 이벤트 진입점 EventListener/Consumer → Service → ES 클라이언트(architecture-rule). web/REST 신설 없음(본 Task는 검색 API 아님). Entity를 모듈 밖/이벤트 페이로드로 노출 금지 — DTO/스칼라/document record만.
- KST 표기(ADR-009): 이벤트 시각 필드 KST ISO-8601, 저장은 Instant/timestamptz.
- ES=사본·재생성 가능(ADR-011): 색인 손실/매핑 변경 시 T4 재색인으로 복원 가능한 구조(부트스트랩·document 변환 재사용).

## Constraints
- dual-write 금지(ADR-011 핵심). 트랜잭션 내 ES 직접 쓰기 금지. 모든 색인은 outbox 이벤트 경유. SoT=PG, ES=재생성 가능 보조.
- 읽기 경로 무변경. 기존 공개 목록/검색 쿼리(ProductRepository 공개 목록 LIKE)·PublicProductService·상품 상세·주문/장바구니 경로 회귀 0. 검색 질의 교체는 T5+6.
- 인프라 기동 범위 밖(T1). ES/OpenSearch 엔진 컨테이너·클라이언트 빈 기동/연결 설정은 infra/006 전제로 가정. 본 Task는 클라이언트를 주입받아 매핑·색인만.
- 재색인 잡 범위 밖(T4). 전량 백필/드리프트 복구 잡은 060. 단 본 Task의 매핑 부트스트랩·document 변환을 060이 재사용하도록 재사용 가능하게 노출.
- 검색 읽기 범위 밖(T5+6). 쿼리·랭킹·부스팅 실제 적용·자동완성·패싯·동의어·폴백(pg_trgm/LIKE)·검색 뷰는 061.
- 모듈 경계. 신규 모듈 추가는 plan에서 정당화(forbidden-rule). 도메인 6개 고정 — search 모듈 신설 시 사유 명시. cross-module 의존은 published port/이벤트로만. ModularityTests/ArchUnit 그린.
- 이벤트 계약 절차. 신규 색인 토픽/페이로드는 event-catalog.md 먼저 갱신 후 코드(event-contract-rule), architecture 섹션5 등재(ADR-004), 알림 6종과 분리·notification 비구독 명시.
- 스키마 무변경(PG). products/product_variants/categories 매핑·마이그레이션 무변경(색인은 읽기만). outbox event_publication은 Modulith 기존 메커니즘 그대로.

## Files
> 정확 경로/이름/시그니처/매핑 JSON·이벤트 필드는 plan 확정. 아래는 선례 대조 기준 예시(모듈 배치는 plan 1번 결정에 따라 product 내부 또는 search 모듈).
### 신규 (backend-implementor)
- product/event/Product...IndexEvent.java(신규 색인 이벤트 record, Externalized) — outbox 발행, 자족 페이로드, eventId+발생시각.
- 색인 indexer 컨슈머(예: product/messaging/ProductIndexEventConsumer.java 또는 search/consumer/...) — KafkaListener Service 위임, 멱등, 예외 비캐치(DLQ), Profile 격리.
- 색인 서비스(예: product/service/ProductIndexService.java 또는 search/service/...) — document 변환(displayPrice/purchasable 산출식 = 공개 목록 집계와 동일) + ES upsert/delete.
- 매핑/부트스트랩(예: ProductIndexBootstrap·Nori 매핑 JSON 리소스) — 버전드 인덱스+alias 멱등 생성, T4 재사용 가능.
- 색인 document record(예: ProductSearchDocument) — Entity 비노출, 스칼라/record만.

### 수정 (backend-implementor)
- product 변경 진입점(ProductService.register/update, ProductVariantService.create/update/deleteVariant, StockAdjustmentService) — 색인 이벤트 발행 호출 추가(트랜잭션 내 ApplicationEventPublisher, ES 직접 쓰기 아님).
- docs/event-catalog.md — 신규 색인 이벤트 필드표 추가(코드보다 먼저), notification 비구독 명시.
- docs/architecture.md 섹션5 — 색인 토픽 등재(알림 6종과 구분).

### 무변경(재사용/비대상)
ProductRepository 공개 목록/검색 쿼리(LIKE)·PublicProductService·상품 상세·주문/장바구니·알림 6개 이벤트·notification 전부·products/product_variants 스키마/마이그레이션. infra/006(ES 클라이언트 기동)·060(재색인)·061(검색 쿼리)은 별 Task.

## Test
> testing-rule + verification-gate-rule. 색인은 외부 ES 상태가 산출물이므로 단위만으론 부족 — Testcontainers(ES+Kafka)로 이벤트→ES 반영을 실제 검증.
- 단위/슬라이스(Mockito): document 변환(displayPrice=COALESCE(MIN 활성 price, basePrice), purchasable=활성 그리고 stock>0)이 공개 목록 집계와 동일 산출. indexer 컨슈머가 Service 위임·멱등(같은 eventId 재처리 동일 결과). 이벤트 발행이 변경 진입점에서 트랜잭션 내 1회.
- 통합(Testcontainers ES + Kafka): 상품 생성→ES upsert(검색 가능 상태). 수정(name/price)→문서 갱신. 상태 전이(ON_SALE→HIDDEN/SOLD_OUT, DRAFT→ON_SALE)→가시성/status 필드 반영. 삭제(또는 비노출)→문서 delete/제외. variant 가격·활성·재고 변경→displayPrice/purchasable 갱신. dual-write 부재 검증(ES 다운/지연 시 product 트랜잭션 커밋·outbox 적재, ES 복구 후 색인 따라잡기). DLQ 격리(독성 이벤트가 핵심 경로 비차단).
- Nori 토큰화: ES analyze API로 한국어 형태소 토큰화 확인(예: 맥북 케이스 와 맥북케이스 합성어 분해/정규화) — 부스팅·랭킹 실제 검색 결과는 T5+6에서.
- 회귀: 공개 목록/검색(LIKE)·상품 상세·주문/장바구니·알림 6종 그린. ModularityTests/ArchUnit·event-catalog↔코드 정합(schema-mapping/event-contract) 그린. 메인 에이전트가 gradlew test 풀 그린 + Modulith verify를 자기 눈으로 확인(verification-gate-rule). Testcontainers 반복은 타깃 테스트만, 풀 스위트는 마지막 1회(메모리 비용 절감).

## Acceptance Criteria
- ES에 Nori 분석기를 적용한 버전드 상품 인덱스(+alias)가 멱등 부트스트랩되고, 한국어 형태소 토큰화가 analyze API로 확인된다(합성어 분해/정규화).
- 상품 생성/수정/상태 전이/삭제·variant 가격·활성·재고 변경이 outbox 이벤트 경유로 ES 문서에 upsert/delete 되어 반영된다(트랜잭션 내 ES 직접 쓰기 없음 — dual-write 금지 충족).
- 색인 document의 displayPrice·purchasable이 기존 공개 목록 집계와 동일 정의로 산출되어 검색-목록 일관성이 유지된다.
- ES 장애/지연이 상품 등록·주문 등 핵심 트랜잭션을 차단하지 않고(outbox 분리), 독성 이벤트는 DLQ로 격리되며, ES 복구 후 색인이 따라잡는다. indexer는 멱등하다.
- 신규 색인 이벤트 계약이 event-catalog.md/architecture 섹션5에 등재되고(코드보다 먼저), 알림 6종·notification과 분리됨이 명시된다. 읽기 경로(LIKE 검색·상세·주문)·PG 스키마는 무변경(회귀 0). ModularityTests/ArchUnit·풀 스위트 그린.

## 범위 밖(명시)
- ES/OpenSearch 엔진·클라이언트 기동·연결 설정(infra/006, T1) — 본 Task는 클라이언트 주입 가정.
- 전량 재색인·백필·드리프트 복구 잡(backend/060, T4) — 본 Task의 매핑/document 변환을 재사용.
- 검색 쿼리·연관도 랭킹·부스팅 실제 적용·자동완성·패싯·동의어·장애 폴백(pg_trgm/LIKE)·검색 뷰(backend/061, T5+6).
- pg_trgm 브리지/폴백(backend/058, T0).

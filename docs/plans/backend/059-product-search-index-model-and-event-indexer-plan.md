# 059. shop-core 상품 검색 — 색인 문서 스키마·Nori 매핑 + 이벤트 기반 indexer 쓰기경로 (T2+T3) — Plan

> Task SSOT: `docs/tasks/backend/059-backend-shop-core-product-search-index-model-and-event-indexer.md`
> ADR: `docs/adr/011-product-search-elasticsearch-secondary-index.md` (SoT=PG, ES=재생성 가능 보조 인덱스, dual-write 금지)
> 전제(T1): infra/006 완료 — `co.elastic.clients:elasticsearch-java` 의존 + `spring.elasticsearch.uris` 설정 + Spring Boot 자동설정 `ElasticsearchClient` 빈 + `_cat/plugins` analysis-nori 내장. **본 plan은 그 클라이언트 위에서 인덱스·매핑·색인 쓰기경로만 구현**한다.
> 범위: T2(색인 문서 스키마·Nori 매핑·버전드 인덱스+alias 부트스트랩) + T3(이벤트 기반 indexer 쓰기경로). 검색 질의·랭킹·폴백·뷰(T5+6/061), 전량 재색인 잡(T4/060), 인프라 기동(T1/006)은 범위 밖.

---

## 0. 코드 대조 재확인 (2026-06-23 — 착수 시점 실측)

| 항목 | 사실(파일) | 설계 영향 |
|---|---|---|
| Product 필드 | `product/domain/Product`: id, category(@ManyToOne LAZY nullable), ownerId(scalar long), name(NN), description(nullable), basePrice(BigDecimal 12,2 NN), status(@Enumerated STRING) | 색인 문서 필드 출처 |
| 상태 | `ProductStatus`: DRAFT/ON_SALE/SOLD_OUT/HIDDEN. `create()`는 status=DRAFT 강제, `update(category,name,description,basePrice,status)`로만 변경(별도 상태전이 메서드 없음) | 상태 전이=update 경유 → 색인 트리거는 update 한 곳 |
| Variant·재고 SoT | `product/domain/ProductVariant`(price,stock,isActive,sku)와 `inventory/domain/VariantStock`(id,stock,isActive)는 **동일 물리 테이블 `product_variants`를 매핑하는 두 Entity**. 재고 컬럼은 단일(`product_variants.stock`) | 재고 SoT 단일 → purchasable 일관. 같은 TX 내 auto-flush로 snapshot 쿼리가 최신 stock 반영 |
| 공개 목록 집계(문서 변환 SoT) | `product/repository/ProductRepository.findPublicProducts*`: `displayPrice = COALESCE(MIN(v.price), p.basePrice)` (LEFT JOIN ProductVariant v ON v.product=p AND v.isActive=true), `purchasableVariantCount = SUM(CASE WHEN v.isActive=true AND v.stock>0 THEN 1 ELSE 0 END)`. 투영: `ProductSummaryProjection(productId,name,displayPrice,categoryId,categoryName,status,purchasableVariantCount)` | 색인 문서의 displayPrice·purchasable을 **동일 식**으로 산출(검색-목록 일관성) |
| 변경 진입점(이벤트 발행 지점) | `ProductService.register(...)`, `ProductService.update(...)`(상태 전이 포함), `ProductVariantService.createVariant/updateVariant/deleteVariant`, `StockAdjustmentService.adjustStock`(product 모듈, inventory.spi 위임). **모두 클래스 레벨 `@Transactional`, 현재 이벤트 발행 0** | 이 메서드들에 `ApplicationEventPublisher.publishEvent` 추가 |
| 상품 삭제 경로 | **없음**(ProductService에 delete 없음). variant 삭제는 product 삭제 아님 | 색인 delete 이벤트 불필요 — 비노출은 status 필드 + 읽기 필터(T5+6) |
| 이벤트 발행 선례 | `order/event/OrderCompletedEvent`: `@Externalized("order-completed")` record(eventId UUID + occurredAt Instant + 도메인 필드), `ApplicationEventPublisher.publishEvent`를 `@Transactional` 내부 호출 → Modulith Outbox(`event_publication`) → Kafka | 동형 패턴 차용 |
| 외부화 인프라 | `spring-modulith-events-kafka` + `spring.modulith.events.externalization.enabled=true`. 프로듀서 value-serializer=ByteArray(Modulith ByteArrayJsonMessageConverter가 JSON byte[] 변환) | 신규 `@Externalized` 이벤트는 자동으로 동일 토픽으로 외부화 |
| **shop-core Kafka 컨슈머** | **현재 0개**(`@KafkaListener` 없음, ConsumerFactory/ErrorHandler 없음). shop-core는 지금까지 발행만 | indexer가 shop-core 최초 in-app 컨슈머 → **컨슈머 인프라 신설 필요** |
| 컨슈머 선례(타 레포) | `notification/consumer/NotificationEventConsumer`: `@KafkaListener(topics,groupId,containerFactory)` Service 위임·예외 비캐치, `@Profile("kafkatest \| !test")`. `notification/common/config/KafkaConsumerConfig`: `DefaultErrorHandler`(FixedBackOff max-attempts) + `DeadLetterPublishingRecoverer`(topic+".DLQ") | shop-core에 **동형 컨슈머 config를 신설**(notification 미러) |
| ES 클라이언트 게이트 | test `application.yml`이 `spring.autoconfigure.exclude`로 ES 자동설정 2종 제외 → **test 프로파일엔 `ElasticsearchClient` 빈 없음**. Testcontainers ES 테스트만 exclude 리셋 | ES 접촉 빈은 `@ConditionalOnBean(ElasticsearchClient.class)`로 게이트(풀 `@SpringBootTest` 회귀 차단) |
| Testcontainers 선례 | PG=`@ServiceConnection PostgreSQLContainer`, Kafka=`@EmbeddedKafka`, ES=`@Container ElasticsearchContainer + @DynamicPropertySource`(`SearchClientConnectionIntegrationTest`), Outbox→Kafka=`OutboxKafkaWireFormatTest` | indexer 통합 테스트는 PG+Kafka+ES 결합 |
| 모듈 구조 | 도메인 6개(member/product/cart/inventory/order/payment) + common/security/web/platform. `search` 모듈 없음. `ModularityTests.verify()` 존재 | 신규 모듈 추가 안 함(아래 결정 1) |

---

## 1. 확정 설계 결정 (Task가 plan에 위임한 6항목)

### 결정 1 — indexer 모듈 배치: **신규 모듈 없이 `product` 모듈 내부 하위 컴포넌트**
- 1차 색인 대상은 product 도메인뿐이고, 문서 변환 SoT가 `ProductRepository` 공개 목록 집계(product 내부)다. T4 재색인(060)도 product 모듈에서 동일 컴포넌트를 재사용한다. → 색인 표면이 product에 닫힌다.
- package-structure-rule(도메인 6개 고정) + forbidden-rule(정당 사유 없는 모듈 추가 금지)에 따라 **`search` 모듈을 신설하지 않는다.** ADR-011의 "검색 독립 진화" 동기는 **검색 읽기 표면이 커지는 T5+6**에서 재검토하며, 본 Task는 쓰기경로(색인)만이라 product 내부로 충분하다.
- 배치:
  - `product/event/ProductSearchIndexChangedEvent` — 외부화 이벤트(자족 스냅샷)
  - `product/messaging/ProductSearchIndexConsumer` — `@KafkaListener` → service 위임
  - `product/search/ProductSearchIndexService` — 문서 변환 + ES upsert
  - `product/search/ProductSearchDocument` — ES 문서 record(Entity 비노출)
  - `product/search/ProductSearchIndexBootstrap` — 버전드 인덱스+alias 멱등 생성(T4 재사용)
  - `product/search/ProductSearchIndexNames` — 인덱스/alias/매핑리소스 상수(단일 출처)
- **Kafka 컨슈머 인프라(횡단)는 `common`에 둔다**: `common/config/SearchIndexKafkaConsumerConfig`(ConsumerFactory/ConcurrentKafkaListenerContainerFactory + DefaultErrorHandler + DLQ). 컨슈머 컨테이너 팩토리는 도메인 무관 인프라이므로 package-structure-rule("공통/횡단 코드는 공통 패키지")상 common이 맞다(notification이 `common/config/KafkaConsumerConfig`에 둔 것과 동형).
- **ModularityTests 정합**: product 내부 하위 패키지(`product/search`, `product/messaging`)는 모듈 내부라 경계 위반 없음. product → common(OPEN) 의존 허용. `ElasticsearchClient`(외부 라이브러리 빈)·`ApplicationEventPublisher`는 모듈이 아니라 위반 없음. 신규 cross-module 의존 없음.

### 결정 2 — 색인 이벤트 계약: **자족 스냅샷 upsert 이벤트 1종(delete 이벤트 없음)**
- **단일 이벤트 `ProductSearchIndexChangedEvent`** (`@Externalized("product-search-index-changed")`). 변경 종류(생성/수정/상태전이/variant·재고 변화)를 구분하지 않고 **"이 productId의 현재 색인 스냅샷이 이렇다"** 만 싣는 멱등 upsert 트리거. event-contract-rule "페이로드 자족(컨슈머 재조회 금지)" 준수 → indexer는 재조회 없이 페이로드만 ES에 upsert.
- **delete 이벤트 없음**: 상품 하드 삭제 경로가 없고(0항 대조), 비노출(DRAFT/HIDDEN)은 "색인엔 status 보존, 필터링은 읽기(T5+6)"로 표현(Task Requirements A·ADR-011 §4). variant 삭제도 product 삭제가 아니라 **스냅샷 재계산 upsert**(displayPrice/purchasable 갱신)다. → upsert 단일 트리거로 모든 케이스 표현. (향후 하드 삭제 경로가 생기면 그때 delete 이벤트 추가 — YAGNI.)
- 페이로드(자족 — 발행 시점 product 모듈에서 공개목록 집계와 동일 식으로 산출해 동봉):

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `eventId` | UUID | ✓ | 공통 봉투(멱등 키) |
| `occurredAt` | Instant(직렬화 KST ISO-8601 +09:00) | ✓ | 공통 봉투. ES external version 소스(epoch millis) |
| `productId` | long | ✓ | 색인 문서 `_id` |
| `name` | string | ✓ | 상품명 |
| `description` | string | ✗(nullable) | 상품 설명 |
| `categoryId` | Long | ✗(nullable) | 미분류 허용 |
| `categoryName` | string | ✗(nullable) | 미분류 시 null |
| `status` | string | ✓ | ProductStatus name(DRAFT/ON_SALE/SOLD_OUT/HIDDEN) — 색인 보존, 필터는 읽기 |
| `displayPrice` | BigDecimal | ✓ | `COALESCE(MIN 활성 variant price, basePrice)` (공개목록 집계와 동일 식) |
| `purchasableVariantCount` | long | ✓ | `활성 AND stock>0` 개수 (공개목록 집계와 동일 식) |

- 시각: `occurredAt`은 `Instant.now()`(커밋 직전), 저장 `timestamptz`/`Instant`, 직렬화 KST(ADR-009) — 선례 이벤트와 동일.

### 결정 3 — 문서 변환 SoT 재사용: **단건 스냅샷 쿼리 1개를 `ProductRepository`에 추가, T4 재사용**
- 공개 목록 집계와 **동일 JPQL 식**으로 단일 productId의 스냅샷을 산출하는 메서드를 추가:
  ```
  // ProductRepository (기존 공개목록과 동일 displayPrice/purchasable 식 — 검색·목록 일관성 SoT)
  // SELECT new ProductSearchSnapshotProjection(
  //   p.id, p.name, p.description, c.id, c.name, p.status,
  //   COALESCE(MIN(v.price), p.basePrice),
  //   SUM(CASE WHEN v.isActive = true AND v.stock > 0 THEN 1L ELSE 0L END))
  // FROM Product p LEFT JOIN p.category c
  //   LEFT JOIN ProductVariant v ON v.product = p AND v.isActive = true
  // WHERE p.id = :productId
  // GROUP BY p.id, p.name, p.description, c.id, c.name, p.status, p.basePrice
  Optional<ProductSearchSnapshotProjection> findSearchSnapshot(@Param("productId") long productId);
  ```
  - `displayPrice`·`purchasableVariantCount` 식은 `findPublicProductsLatest`와 **문자 그대로 동일**해야 한다(검색-목록 일관성 — Task Requirements A). description은 공개목록 투영엔 없지만 색인엔 필요해 추가 select(집계 키에 무관, GROUP BY에 포함).
  - 신규 투영 `product/dto/ProductSearchSnapshotProjection`(record, product 내부 — Entity 비노출).
- **재사용**: 변경 진입점들은 이 한 메서드로 스냅샷을 얻어 이벤트를 구성(자족). T4(060) 전량 재색인은 동일 식의 배치 변형(전체/페이지 스캔)을 쓰되, **이벤트→문서 매핑(`ProductSearchIndexChangedEvent`/스냅샷 → `ProductSearchDocument`)은 `ProductSearchIndexService`의 매퍼를 공용**으로 호출한다. 즉 "산출식(repository)"과 "문서 매핑(service)" 둘 다 단일 출처.
- **재고 일관성(같은 TX)**: `StockAdjustmentService.adjustStock`은 inventory `VariantStock`(동일 `product_variants` 테이블)로 stock을 변경한 뒤 같은 트랜잭션에서 `findSearchSnapshot`(JPQL over ProductVariant)을 호출한다. Hibernate auto-flush가 쿼리 전 stock UPDATE를 flush하므로 스냅샷은 최신 재고를 반영한다(두 Entity 동일 컬럼).

### 결정 4 — Nori 매핑·인덱스 토폴로지
- **버전드 인덱스 `products-v1` + alias `products`**(읽기/쓰기 모두 alias). 매핑 변경 시 새 버전 인덱스 생성 후 alias 스왑(T4가 이 부트스트랩 재사용). 상수는 `ProductSearchIndexNames`에 단일 정의(`ALIAS="products"`, `CURRENT_INDEX="products-v1"`).
- **매핑 JSON 단일 출처**: `shop-core/src/main/resources/search/product-index.json`(settings.analysis + mappings). 부트스트랩이 이 리소스를 읽어 인덱스 생성.
- **Nori 분석기**(settings.analysis): custom analyzer `korean_nori`
  - tokenizer: `nori_tokenizer`, `decompound_mode: mixed`(합성어 원형+분해 동시 색인 — "맥북케이스"→"맥북케이스","맥북","케이스")
  - filter: `nori_part_of_speech`(조사·어미 등 불용 품사 제거), `lowercase`
  - (동의어·자동완성·readingform·사용자 사전은 범위 밖 — 후속)
- **필드 매핑**:
  | 필드 | ES 타입 | 분석기/비고 |
  |---|---|---|
  | (문서 `_id`) | — | `productId` 사용 |
  | `productId` | long | |
  | `name` | text | analyzer `korean_nori` (부스팅 1순위 후보) |
  | `description` | text | analyzer `korean_nori` (2순위) |
  | `categoryName` | text | analyzer `korean_nori` (3순위) |
  | `categoryId` | long | 필터용 |
  | `status` | keyword | 읽기 필터용(노출 화이트리스트는 T5+6) |
  | `displayPrice` | scaled_float(scaling_factor 100) | 가격 정렬/범위(T5+6). BigDecimal(2자리)와 정합 |
  | `purchasableVariantCount` | integer | 읽기에서 `>0` 판정 |
- **부스팅**: name>description>categoryName은 **설계 의도로 문서화**하되 실제 가중치는 **질의 시(T5+6)** 적용한다(ES는 index-time boost를 권장하지 않음). 본 Task 매핑은 세 텍스트 필드를 Nori로 분석 가능하게 만드는 것까지.
- **부트스트랩 멱등·책임 분담**: `ProductSearchIndexBootstrap`이 기동 시(`ApplicationRunner`/`SmartLifecycle`) **인덱스 부재 시에만 생성 + alias 부재 시에만 연결**(`indices().exists` 선검사). 이미 있으면 무동작(멱등). **ES 미가용이어도 부팅을 막지 않는다**(try/catch + WARN 로깅 — ADR: 검색 장애가 핵심 경로 비차단). 생성 로직은 public 메서드로 노출해 **T4 재색인이 "새 버전 인덱스 생성 → 백필 → alias 스왑"에 재사용**.

### 결정 5 — 실패 격리·멱등·드리프트
- **dual-write 금지·트랜잭션 격리**: 변경 진입점은 ES를 직접 건드리지 않고 `ApplicationEventPublisher.publishEvent`만 호출 → Modulith Outbox(`event_publication`, product TX와 동일 커밋) → 커밋 후 Kafka 외부화 → indexer 컨슈머가 ES upsert. ES 다운/지연이 product TX(상품 등록·재고 조정)를 롤백시키지 않음(구조적 보장).
- **멱등 upsert**: 문서 `_id = productId` → 같은 이벤트 재처리(재시도/at-least-once)도 동일 결과. 추가로 **ES external version = `occurredAt` epoch millis**(`VersionType.External`)로 **순서 역전 보호**(늦게 도착한 옛 이벤트가 최신 문서를 덮어쓰지 않음; ES가 낮은 버전 거부 → `VersionConflictException`은 정상 무시).
- **재시도·DLQ**: `common/config/SearchIndexKafkaConsumerConfig`에 `DefaultErrorHandler(FixedBackOff)` + `DeadLetterPublishingRecoverer`(topic+".DLQ") — notification 선례 미러. 컨슈머는 예외를 캐치하지 않고 던져 ErrorHandler에 위임(Service 위임만). ES 일시 장애 → 백오프 재시도로 복구 후 따라잡기, 독성 이벤트 → DLQ 격리(핵심 경로·다른 이벤트 비차단).
- **버전 충돌(순서 역전) 처리 — 확정**: external version으로 늦게 도착한 옛 이벤트가 거부되는 것은 **정상 동작이며 DLQ로 가면 안 된다.** 처리 방식은 **`ProductSearchIndexService.upsert` 내부에서 ES version-conflict 예외를 캐치해 DEBUG/INFO 로깅 후 정상 반환(swallow)** 로 확정한다(컨슈머는 여전히 예외 비캐치 원칙 유지 — 충돌은 service가 비-오류로 흡수하므로 컨슈머까지 전파 안 됨). 재시도해도 같은 충돌이 반복되어 무의미하므로 ErrorHandler 재시도/ DLQ 경로에 태우지 않는다. (구현 시 8.15.x client의 정확한 version-conflict 예외 타입을 실측 — §8 게이트 #8.)
- **in-process 중복 수신 금지**: `@Externalized` 이벤트는 Kafka로 나갔다가 `@KafkaListener`로 되돌아오는 **왕복 1경로만** 둔다. in-process `@ApplicationModuleListener`를 추가하지 않는다(추가 시 동일 이벤트가 인-프로세스로도 전달돼 ES 이중 처리). 색인 소비는 Kafka 컨슈머 1곳뿐.
- **드리프트 완화**: status 전이(update)도 upsert로 status 필드 반영 → "검색엔 뜨는데 비노출" 은 읽기 필터(T5+6)가 닫음. **주문 기인 재고 변동(체크아웃 차감/취소 복원)은 본 Task의 실시간 색인 트리거에 포함하지 않는다**(아래 결정 5-범위). 그로 인한 "검색엔 구매가능, 실제 품절" 드리프트는 (a) 읽기 시 클릭스루 SoT 재확인·status 필터(T5+6), (b) 주기적 전량 재색인(T4)으로 완화(ADR-011 §4·결과). best-effort purchasable임을 카탈로그·코드 주석에 명시.
  - **범위 근거**: Task의 변경 진입점 목록은 register/update/variant CRUD/`StockAdjustmentService`(운영자 조정)이며 주문 체크아웃/취소 경로는 **불포함**. Constraints "주문/장바구니 경로 회귀 0·핵심 경로 비차단"과 정합 — order 핫패스에 색인 이벤트를 끼워 넣지 않는다. (주문 기인 재고 색인은 필요 시 후속에서 inventory 이벤트로 추가.)

### 결정 6 — ES 클라이언트 주입 경계 + 테스트 컨텍스트 격리
- indexer/index service/bootstrap은 infra/006이 자동 구성한 **`co.elastic.clients.elasticsearch.ElasticsearchClient` 빈을 생성자 주입**(공통 인프라 빈). 클라이언트 기동·연결 설정은 본 Task 범위 밖(T1 전제).
- **ES 접촉 빈은 모두 `@ConditionalOnBean(ElasticsearchClient.class)`로 게이트**: `ProductSearchIndexService`, `ProductSearchIndexBootstrap`. test `application.yml`이 ES 자동설정을 exclude → test 프로파일엔 `ElasticsearchClient` 부재 → 이 빈들 미생성 → **풀 `@SpringBootTest`(보안/뷰/컨트롤러·`@MockSharedRepositories` 군) 컨텍스트 로드 회귀 차단**(verification-gate §4). Testcontainers indexer 통합 테스트만 exclude 리셋 → 빈 활성.
- **컨슈머·컨슈머 config 게이트**: `ProductSearchIndexConsumer`와 `SearchIndexKafkaConsumerConfig`는 `@Profile("kafkatest | !test")`(notification 선례). 순수 `test` 프로파일에선 비활성(Kafka 자동설정도 test에서 제외), 운영/로컬(`!test`) 활성, 통합 테스트는 `kafkatest`로 활성. 컨슈머가 의존하는 `ProductSearchIndexService`는 통합 테스트(ES 리셋)에서 함께 활성되어 배선 성립.
- **변경 진입점의 `publishEvent` 호출은 ES 비접촉**이라 전 프로파일에서 안전(컨텍스트 로드 시 미실행, 메서드 호출 시에만 Outbox 적재). 기존 ProductService/ProductVariantService 단위·슬라이스 테스트 영향은 구현 시 타깃 실행으로 확인(아래 Test).

---

## 2. 이벤트 계약 문서 선갱신 (코드보다 먼저 — event-contract-rule)

> indexer는 **notification이 아니라 shop-core 내부 product indexer**(별 groupId)가 구독한다. 알림 6종과 분리. 카탈로그/아키텍처에 "notification 비구독·색인 전용" 명시.

### `docs/event-catalog.md`
- "토픽 인덱스" 표 아래, 기존 "비-알림 인프라 토픽(참고)" 단락과 같은 톤으로 **색인 전용 이벤트 섹션 추가**: 토픽 `product-search-index-changed`, 발행 모듈 product, 구독자 **shop-core product indexer(groupId=`product-search-indexer`)**, **notification 비구독**(알림 계약 아님 — SSOT 본문에 명시). 결정 2 필드표 + JSON 예시 추가.
- 카탈로그 상단 설명("notification이 구독하는 …의 SSOT")과 모순되지 않도록, 본 이벤트가 **알림 계약이 아닌 내부 색인 계약**임을 명시(platform 스모크 토픽 단락과 동급 처리, 단 이쪽은 실제 계약이므로 필드표 등재).

### `docs/architecture.md` §5 토픽 목록 표
- 행 추가: `product-search-index-changed` | `ProductSearchIndexChangedEvent` | 상품/variant/재고(운영자 조정) 변경 | product | **shop-core product indexer(비-notification)**.
- 표 아래 주석에 "색인 토픽은 notification 비구독, 알림 6종과 분리" 한 줄.

---

## 3. 영향 범위 (파일)

### 신규 (backend-implementor)
- `product/event/ProductSearchIndexChangedEvent.java` — `@Externalized("product-search-index-changed")` record(결정 2 필드).
- `product/dto/ProductSearchSnapshotProjection.java` — repository 투영 record(product 내부).
- `product/search/ProductSearchDocument.java` — ES 문서 record(Entity 비노출, 스칼라만).
- `product/search/ProductSearchIndexNames.java` — alias/인덱스/매핑리소스 상수.
- `product/search/ProductSearchIndexService.java` — `@ConditionalOnBean(ElasticsearchClient.class)`. 이벤트→`ProductSearchDocument` 매핑(공용) + ES upsert(`_id=productId`, external version=occurredAt). 버전 충돌 무해 처리.
- `product/search/ProductSearchIndexBootstrap.java` — `@ConditionalOnBean(ElasticsearchClient.class)`. 버전드 인덱스+alias 멱등 생성(부팅 best-effort, T4 재사용 public 메서드).
- `product/messaging/ProductSearchIndexConsumer.java` — `@Profile("kafkatest | !test")`. `@KafkaListener(topics="product-search-index-changed", groupId="product-search-indexer", containerFactory=...)` → service 위임(예외 비캐치).
- `common/config/SearchIndexKafkaConsumerConfig.java` — `@Profile("kafkatest | !test")`. ConsumerFactory/ConcurrentKafkaListenerContainerFactory(JSON byte[] 역직렬화 — notification `KafkaConsumerConfig` 미러) + DefaultErrorHandler(FixedBackOff) + DeadLetterPublishingRecoverer(".DLQ").
- `src/main/resources/search/product-index.json` — Nori settings.analysis + mappings(결정 4, 매핑 단일 출처).
- 테스트(아래 Test 절): 단위(매핑 패리티·컨슈머 위임·멱등) + 통합(PG+Kafka+ES) + Nori analyze.

### 수정 (backend-implementor)
- `product/repository/ProductRepository.java` — `findSearchSnapshot(productId)` 추가(공개목록과 동일 식, 결정 3).
- `product/service/ProductService.java` — register/update 말미에 스냅샷 조회 후 `publishEvent(ProductSearchIndexChangedEvent)`(생성자에 `ApplicationEventPublisher` 주입). TX 내부, ES 비접촉.
- `product/service/ProductVariantService.java` — createVariant/updateVariant/deleteVariant 말미에 해당 product 스냅샷 재계산 후 publish(삭제 후에도 product는 존재 → upsert).
- `product/service/StockAdjustmentService.java` — adjustStock(inventory 위임) 후 product 스냅샷 재계산 publish(같은 TX auto-flush로 최신 재고 반영).
- `docs/event-catalog.md`, `docs/architecture.md` §5 — §2 선갱신.

### 무변경(회귀 0 — 명시)
ProductRepository 공개 목록/검색 LIKE 쿼리(식 재사용만, 기존 쿼리 무변경)·PublicProductService·상품 상세·order/cart/payment·알림 6 이벤트·notification 전부·products/product_variants/categories 스키마·Flyway·Modulith Outbox 메커니즘.

---

## 4. 색인 데이터 흐름

1. 운영자/판매자 상품·variant·재고 변경 → 진입점 서비스(`@Transactional`)가 도메인 변경 수행.
2. 같은 TX에서 `findSearchSnapshot(productId)`로 displayPrice/purchasable/status/categoryName 산출(공개목록과 동일 식, auto-flush로 최신 반영).
3. `publishEvent(ProductSearchIndexChangedEvent(스냅샷))` → Modulith가 `event_publication`(INCOMPLETE)에 적재(같은 커밋). **ES 직접 쓰기 없음.**
4. TX 커밋 → Modulith가 Kafka 토픽 `product-search-index-changed`로 외부화(JSON byte[]).
5. `ProductSearchIndexConsumer`(groupId=`product-search-indexer`)가 수신 → `ProductSearchIndexService.upsert(event)`.
6. service가 `ProductSearchDocument` 매핑 → `ElasticsearchClient.index(alias=products, id=productId, version=occurredAt, externalVersion)`. 멱등·순서 역전 안전.
7. 실패: 일시 장애→DefaultErrorHandler 백오프 재시도→복구 후 따라잡기. 독성→`product-search-index-changed.DLQ`. 버전 충돌→무해 무시.
8. 부팅: `ProductSearchIndexBootstrap`이 `products-v1`+alias 멱등 생성(ES 미가용이면 WARN 후 진행, 부팅 비차단).

---

## 5. 검증 방법 (testing-rule + verification-gate-rule)

### 단위/슬라이스(Mockito — 풀스위트 금지, 타깃 실행)
- **문서 변환 패리티**: `findSearchSnapshot`/`ProductSearchIndexService` 매핑이 `displayPrice=COALESCE(MIN 활성 price, basePrice)`, `purchasableVariantCount=활성 AND stock>0`로 공개목록 집계와 동일 산출(대표 케이스: 활성 variant 다수, 활성 없음→basePrice, stock 0→purchasable 제외).
- **컨슈머 위임·멱등**: 컨슈머가 service.upsert 위임만(Repository 직접·예외 캐치 없음). 같은 eventId/payload 재처리 시 동일 문서(멱등). 옛 occurredAt 이벤트가 최신 문서 미갱신(version 분기).
- **발행 1회**: 각 변경 진입점이 TX 내 `publishEvent` 정확히 1회(ApplicationEventPublisher mock 검증).

> **Nori 이미지 주의(load-bearing)**: indexer 통합 테스트는 `korean_nori` 분석기를 가진 인덱스를 **생성**하므로 `analysis-nori`가 설치된 ES 이미지가 필요하다. 기존 `SearchClientConnectionIntegrationTest`는 health만 확인해 **plain 공식 이미지**(Nori 없음)를 쓰지만, 본 Task 통합 테스트는 그 이미지를 그대로 쓰면 인덱스 생성이 실패한다. → `docker/shop/Dockerfile.search`로 빌드되는 **Nori 내장 이미지**를 사용한다(Testcontainers `ImageFromDockerfile`로 `Dockerfile.search` 빌드, 또는 로컬 `shop-search:8.15.3` 태그 이미지 참조). 구현 시 어느 방식이 CI/로컬에서 안정적인지 실측(§8 게이트 #7).

### 통합(Testcontainers — PG `@ServiceConnection` + ES `@Container`/`@DynamicPropertySource`(Nori 이미지) + Kafka `@EmbeddedKafka`, profile `kafkatest`, ES exclude 리셋, externalization on)
- 상품 생성→ES 문서 upsert(검색 가능 상태). 수정(name/price)→문서 갱신. 상태 전이(DRAFT→ON_SALE, ON_SALE→HIDDEN/SOLD_OUT)→status 필드 반영. variant 가격/활성/재고 변경 + 운영자 adjustStock→displayPrice/purchasableVariantCount 갱신. variant 전체 삭제→displayPrice=basePrice·purchasable=0 upsert.
- **dual-write 부재**: ES 끊은 채 상품 등록→product TX 커밋 + `event_publication` 적재 확인, ES 복구 후 색인 따라잡기. **DLQ 격리**: 독성 이벤트가 `.DLQ`로 가고 핵심 경로/후속 이벤트 비차단.
- 부트스트랩 멱등: 2회 기동(재호출)해도 인덱스/alias 중복 생성·오류 없음.

### Nori 토큰화
- ES `_analyze`(analyzer `korean_nori`)로 한국어 형태소·합성어 분해/정규화 확인(예: "맥북 케이스"/"맥북케이스" 토큰 교집합). 부스팅·연관도 실제 검색 결과는 T5+6.

### 회귀(메인 동적 게이트)
- 공개 목록/검색(LIKE)·상품 상세·order/cart·알림 6종 그린. `ModularityTests`/ArchUnit 그린. event-catalog↔코드 정합(신규 이벤트 필드 일치). **메인 에이전트가 `./gradlew test` 풀 그린을 자기 눈으로 1회 확인**(verification-gate §2). 특히 **신규 빈(@ConditionalOnBean·@Profile 게이트) 추가가 풀 `@SpringBootTest` 컨텍스트 로드를 깨지 않음**을 baseline 대조로 확인(§4 — additive diff도 회귀 가능). Testcontainers 반복은 타깃만, 풀스위트는 마지막 1회.

---

## 6. Acceptance Criteria 매핑

| Task AC | 충족 방식 |
|---|---|
| Nori 버전드 인덱스+alias 멱등 부트스트랩 + analyze 형태소 확인 | 결정 4 + 부트스트랩 + Nori analyze 테스트 |
| 생성/수정/상태전이/variant·가격·활성·재고 변경 → outbox 경유 upsert(dual-write 없음) | 결정 2·5 + 진입점 publishEvent + 통합 테스트 |
| displayPrice·purchasable이 공개목록 집계와 동일 정의 | 결정 3(동일 JPQL 식) + 패리티 단위 테스트 |
| ES 장애가 핵심 TX 비차단·독성 DLQ 격리·복구 후 따라잡기·멱등 | 결정 5 + dual-write/DLQ 통합 테스트 |
| 색인 이벤트 계약 카탈로그/§5 등재(코드보다 먼저)·알림 비분리 명시·읽기/스키마 무변경 | §2 + §3 무변경 목록 + 회귀 |

---

## 7. 트레이드오프

- **단일 upsert 이벤트 vs 세분 이벤트**: 자족 스냅샷 단일 이벤트는 멱등·대량 매핑변경에 강하고 indexer가 단순(재조회 0). 변경 종류 정보 손실은 본 Task(쓰기경로)에서 불요. 채택.
- **delete 이벤트 없음**: 하드 삭제 경로 부재 + status 보존/읽기 필터로 표현 가능 → over-spec 회피. 채택(향후 삭제 경로 생기면 추가).
- **주문 기인 재고 색인 제외**: order 핫패스 무변경(회귀 0·비차단) 우선, 드리프트는 읽기 필터+T4 재색인으로 완화(ADR-011 §4). 실시간 정확도 일부 양보.
- **product 내부 배치 vs search 모듈**: 1차 색인 표면이 product뿐 → 모듈 추가 없이 내부 배치(forbidden-rule). 검색 읽기가 커지는 T5+6에서 분리 재검토.
- **`@ConditionalOnBean`/`@Profile` 게이트**: 풀 컨텍스트 회귀를 구조적으로 차단(보수적). 통합 테스트만 리셋해 실엔진 검증.
- **ES external version=occurredAt**: 순서 역전 보호를 싸게 확보. 동일 ms 충돌 가능성은 단일 aggregate 빈도상 무시 가능.

---

## 8. 구현 시 해소할 검증 게이트 (추정 금지 — 코드/빌드/테스트 실측)
1. `ElasticsearchClient` 정확 FQCN(`co.elastic.clients.elasticsearch.ElasticsearchClient`)·인덱스 생성/매핑/`index` API 시그니처 실측(8.15.x client).
2. Modulith 외부화 JSON byte[] 와이어포맷 ↔ 컨슈머 역직렬화 정합: notification `KafkaConsumerConfig` 역직렬화 설정을 shop-core에 미러할 때 value-deserializer/타입 매핑 실측(`OutboxKafkaWireFormatTest` 와이어포맷 대조).
3. `@ConditionalOnBean(ElasticsearchClient.class)` 게이트가 **순수 test 프로파일에서 indexer 빈 미생성 + 통합 테스트(exclude 리셋)에서 생성**을 둘 다 만족하는지 실측(풀 `@SpringBootTest` baseline 대조 — §4).
4. `@Profile("kafkatest | !test")` 컨슈머가 순수 test에서 비활성, `kafkatest` 통합 테스트에서 활성됨 실측.
5. `findSearchSnapshot` 식이 `findPublicProductsLatest`와 **문자 동일**(displayPrice/purchasable) — 패리티 테스트로 증명.
6. 부트스트랩이 ES 미가용 시 부팅 비차단(try/catch) 실측, 2회 호출 멱등 실측.
7. Nori `analysis-nori`가 인덱스 settings에서 정상 적용되는지(`_analyze`) — 8.15.3 Nori 빌드 이미지/Testcontainers 이미지 정합.
8. ES 8.15.x client의 **version-conflict 예외 정확 타입** 실측 → `ProductSearchIndexService`가 그 타입만 캐치해 swallow(순서 역전 정상 처리, DLQ 비유발). 다른 ES 예외는 전파(재시도/DLQ).

---

## 9. 워크플로우 (메인 오케스트레이션)
1. (완료) 코드 대조 + 본 plan 작성 → **plan-reviewer 리뷰 → 필요 시 plan-fixer**.
2. PASS 후 **backend-implementor**에 본 plan 위임(풀스위트 금지, `--tests` 타깃 실행 명시 — subagent-rule). view 없음(검색 뷰는 T5+6).
3. **reviewer** 정적 리뷰 → FAIL 시 **fixer**(최대 3회).
4. **메인이 `./gradlew test` 풀 그린 + ModularityTests verify 직접 확인**(verification-gate §2). baseline 대조로 풀 컨텍스트 회귀 0 확인.
5. 결과 취합·보고. (커밋은 사용자 요청 시에만 — 자동 커밋 금지.)

# 060. shop-core 상품 검색 — 풀 재색인·백필 잡(PG→ES bulk + alias swap 무중단 컷오버) — Plan

> Task SSOT: `docs/tasks/backend/060-backend-shop-core-product-search-full-reindex-backfill-job.md`
> ADR: `docs/adr/011-*`(SoT=PG, ES=재생성 가능 보조, 풀 재색인을 1급 기능으로). 이니셔티브 T4.
> 전제(재사용): T1 infra/006(ES 클라이언트), **T2+3 backend/059**(색인 문서·Nori 매핑·alias 규약·증분 indexer — 커밋 `c1328d8`). 본 Task는 그 매핑/문서/alias를 **재사용해 전량 적재**만 한다(매핑·스키마 재정의 없음).
> 범위: 풀 재색인·백필 오케스트레이션(전량 keyset 순회 → bulk → 새 버전 인덱스 → 원자적 alias swap → 정리 → ADMIN 트리거)만. 검색 쿼리·랭킹·폴백·뷰(T5+6/061)는 범위 밖. 신규 Kafka 이벤트·notification 없음(내부 운영 작업).
> **관련 규칙(이번 이니셔티브에서 신설)**: `docs/rules/inapp-consumer-external-engine-rule.md`(외부 엔진 통합 빈 게이팅·Kafka/스레드 자원 수명·풀스위트 검증). 본 Task도 이를 따른다.

---

## 0. 코드 대조 (2026-06-23 실측 — 059 커밋 후)

| 항목 | 사실 | 060 활용 |
|---|---|---|
| 단건 스냅샷 쿼리 | `ProductRepository.findSearchSnapshot(productId)` → `ProductSearchSnapshotProjection`(productId,name,description,categoryId,categoryName,status(ProductStatus),displayPrice(BigDecimal),purchasableVariantCount(long)). JPQL: `COALESCE(MIN(v.price),p.basePrice)` + `SUM(CASE WHEN v.isActive=true AND v.stock>0 THEN 1L ELSE 0L END)`, `LEFT JOIN ProductVariant v ON v.product=p AND v.isActive=true`, `GROUP BY p.id,p.name,p.description,c.id,c.name,p.status,p.basePrice` | **동일 집계식**의 keyset 변형 신규 추가 |
| keyset/스트리밍 | 코드베이스에 **없음**(전부 offset Pageable). `@QueryHints`·Slice·Stream 없음 | 신규 keyset 메서드 설계 |
| 색인 문서/상수 | `ProductSearchDocument`(record + `from(event)`), `ProductSearchIndexNames`(ALIAS="products", CURRENT_INDEX="products-v1", MAPPING_RESOURCE="search/product-index.json") | 재사용 + `from(snapshot)` 추가 |
| ES 인덱스 생성 | `ProductSearchIndexBootstrap.createIndex(name)`는 **private + products-v1 하드코딩**. `ensureIndex()` public(멱등, ES 미가용 시 부팅 비차단). 단건 upsert는 `ProductSearchIndexService.upsert(event)`(alias에 _id=productId, external version) | createIndex(name)/alias-swap/bulk를 **공용 admin으로 추출** + bootstrap alias-centric 리팩터 |
| ES 빈 게이팅 | 059 `ProductSearchIndexConfig`(@AutoConfiguration, `@ConditionalOnBean(ElasticsearchClient)` + `@ConditionalOnProperty(shop.search.indexer.enabled)`)가 service/bootstrap @Bean 등록. test 프로파일은 ES 자동설정 exclude → 빈 부재 | 동일 게이트에 admin @Bean 추가, 트리거 빈은 ES 비의존(ObjectProvider) |
| ES client API | `co.elastic.clients:elasticsearch-java`(Boot 3.5 BOM, 8.15.x). `indices().create/exists/existsAlias/putAlias/delete`, `index(...)` 사용 중. **`bulk(...)`·`updateAliases(...)`·`indices().get(wildcard)`는 미사용**(본 Task 신규 — 구현 시 정확 시그니처 실측) | bulk·원자 swap·정리 |
| 스케줄러 선례 | `payment/service/UnpaidOrderExpiryScheduler`: `@ConditionalOnProperty` + `@Scheduled` + `SchedulerLeaderGuard.runIfLeader(resource,task)`(best-effort, ADR-005), 스케줄러 비-@Transactional | 1차 트리거는 ADMIN REST이므로 스케줄 미채택(결정 1) |
| admin 보안 | `SecurityConfig` restChain: `/api/v1/**` securityMatcher, `requestMatchers("/api/v1/admin/**").hasRole("ADMIN")`(이미 커버). admin 컨트롤러 선례 `AdminCategoryRestController`(컨트롤러→ServiceResponse), JWT principal=userId(long) | 신규 matcher 불요, 재색인 엔드포인트 자동 인가 |
| async | `@Async`/`@EnableAsync`/TaskExecutor **없음**. `VirtualThreadConfig`(요청 레벨, off by default)만. 배경 잡 상태 추적 패턴 **없음** | 서비스 내부 단일 executor + in-memory 상태(신규, 최소) |
| ServiceResponse 선례 | `ProductServiceResponse`(auth→actorId, Entity→DTO, REST 전용). 202 선례: `ResponseEntity.status(ACCEPTED)` | 미러 |
| 통합 테스트 하니스 | `ProductSearchIndexIntegrationTest`: PG `@ServiceConnection` + Nori `ImageFromDockerfile`(../docker/shop/Dockerfile.search) + `@DynamicPropertySource`(es uris) + `shop.search.indexer.enabled=true` + `@DirtiesContext` | 동일 하니스 계승 |

---

## 1. 확정 설계 결정 (Task가 plan에 위임한 7항목)

### 결정 1 — 트리거: **ADMIN REST(수동) + 비동기 시작(202)**
- 초기 적재·매핑 변경·드리프트 복구는 사람이 의도적으로 트리거하는 운영 작업이다. 주기 자동 전량 재색인은 부하·비용 부담 → 1차는 **ADMIN 수동 트리거**. 스케줄(정기 드리프트 보정)은 후속 선택지로 남긴다(범위 밖).
- 엔드포인트(`/api/v1/admin/products/search-index/**`는 `SecurityConfig`가 이미 `hasRole("ADMIN")`로 커버 — **신규 matcher 불요**, 코드 대조 확인):
  - `POST /api/v1/admin/products/search-index/reindex` → **202 Accepted** + 현재 상태 DTO(비동기 시작).
  - `GET /api/v1/admin/products/search-index/status` → 200 + 마지막/진행 상태 DTO.
- 레이어(architecture-rule): `AdminProductSearchReindexRestController` → `ProductSearchReindexServiceResponse`(REST 조합 전용) → `ProductSearchReindexService`(오케스트레이션). 컨트롤러·ServiceResponse에 비즈니스 로직 금지.

### 결정 2 — 장시간 잡 실행 모델: **비동기 시작(202) + in-memory 상태, 동기 `reindex()` 코어**
- 전량 적재는 장시간이라 HTTP 동기 완주는 타임아웃 위험 → 트리거는 **즉시 202 반환**, 잡은 백그라운드 실행.
- 실행: `ProductSearchReindexService`가 **단일 스레드 executor**(daemon)를 보유. `startAsync()`가 잡을 submit하고 즉시 반환. 진행/결과는 **in-memory `AtomicReference<ReindexStatus>`**로 추적(state, startedAt, finishedAt, processedCount, newIndex, errorMessage). `status()`로 조회.
  - **가드 리셋 안전(필수)**: `running` CAS-true 직후 `executor.submit(...)`을 try로 감싸 submit 자체가 던지면(예: 컨텍스트 종료 후 `RejectedExecutionException`) **catch에서 `running=false` 복원** + 상태 FAILED. 정상 경로의 `running=false`는 잡 본문 finally(성공/실패 무관)에 둔다. → CAS-true 후 어떤 경로로도 `running`이 true 고착되지 않게 한다.
- **동기 코어 `reindex()`**(순회→bulk→swap→정리)를 분리해 통합 테스트가 직접 호출·단언(비동기 타이밍 비의존). 엔드포인트는 `startAsync()`만 호출.
- **자원 수명(필수 — 059 교훈/규칙 준수)**: 서비스가 `DisposableBean` 구현, `destroy()`에서 executor를 shutdown해 스레드 누수 차단(`docs/rules/inapp-consumer-external-engine-rule.md` §2).
- 비동기 스레드는 SecurityContext/요청 스코프 없음 — 재색인은 전역 작업이라 무관. ThreadLocal 직접 사용 금지, 블로킹 I/O(ES/PG)는 서비스/인프라 경계(CLAUDE.md).

### 결정 3 — 전량 순회: **keyset(seek) 페이지네이션, 배치=read=bulk 동일 크기**
- OFFSET 깊은 페이지 열화 회피 → `WHERE p.id > :lastId ORDER BY p.id ASC LIMIT batch`의 keyset 순회. 마지막 배치가 비면 종료.
- `ProductRepository` 신규(읽기 전용, 기존 쿼리 무변경): `findSearchSnapshot`과 **문자 동일 집계식**의 keyset 변형 — 단건 `WHERE p.id = :productId` → `WHERE p.id > :lastId`, `ORDER BY p.id ASC`, 배치 한정. 반환 `List<ProductSearchSnapshotProjection>`(Page 아님 → count 쿼리 없음).
  - 시그니처(택1, 구현 시 컴파일 확인): Spring Data 3.x `Limit` — `List<ProductSearchSnapshotProjection> findSearchSnapshotsAfter(@Param("lastId") long lastId, org.springframework.data.domain.Limit limit)`; 또는 `Pageable`(`PageRequest.of(0, batch)`). GROUP BY + ORDER BY p.id는 JPQL에 명시.
- **N+1 방지**: 집계 쿼리가 `ProductVariant`·`Category`를 JOIN+GROUP으로 단일 쿼리에 합치므로(연관 lazy 로딩 안 함, 스칼라 projection) variant/category N+1이 구조적으로 없다(059 동일). 배치 크기는 설정값(기본 500, `shop.search.reindex.batch-size`).
- 잡 전체를 단일 트랜잭션으로 묶지 않는다(장시간 tx 회피). 각 배치 read는 짧은 read-only(Spring Data 기본). keyset은 상태 비저장(`id > lastId`)이라 커서 트랜잭션 불요. 진행 중 데이터 변경분은 증분 indexer(059)·다음 재색인이 수렴(ADR-011 최종 일관성).

### 결정 4 — 중복 실행 가드: **in-process `AtomicBoolean`(동시 트리거 409) + 멱등 의존**
- 같은 노드 동시/중복 트리거: `running` `AtomicBoolean.compareAndSet(false,true)` 실패 시 **409 Conflict + 현재 상태**(이미 진행 중). 잡 종료(성공/실패) 시 `running=false`.
- 다중 노드: **가드 없음(멱등에 의존)**. 새 인덱스+swap이라 두 노드가 동시에 돌려도 정합은 깨지지 않는다(각자 새 인덱스 생성 후 마지막 swap이 alias 결정, 미사용 인덱스는 정리 대상). 수동 ADMIN 트리거는 빈도가 낮아 분산 리더 게이트는 **과도설계** — `SchedulerLeaderGuard`는 스케줄 변형 도입 시(후속) 적용한다. ADR-005: 게이트 실패에도 정합 불변.

### 결정 5 — 인덱스 네이밍/alias swap/정리
- **새 버전 인덱스명**: `products-v` + 타임스탬프(예: `products-v" + Instant.now().toEpochMilli()`). 059의 `products-v1`과 동일 `products-v*` 접두(정리 매칭). 잡 실행 시각은 **서비스 런타임에서 생성**(워크플로 샌드박스 아님 — Java `Instant.now()` 정상).
- **read alias 단일(`products`)**: 증분 indexer(059)는 `upsert`를 **alias `products`** 에 쓴다(read=write alias 동일). 재색인이 alias를 새 인덱스로 옮기면 그 시점 이후 증분 upsert는 새 인덱스로 간다. 적재 진행 중에는 alias가 **기존 인덱스 유지** → 증분도 기존에 계속 쓰여 드리프트 최소(swap 후 다음 재색인/증분이 수렴). read/write alias 분리는 1차 미도입(YAGNI — 단일 alias로 충분, 분리 시 증분 경로까지 손대야 함). 
  > **드리프트 주의(문서화)**: 적재~swap 사이에 발생한 증분 변경은 기존 인덱스엔 반영되나 새 인덱스 스냅샷엔 누락될 수 있다(새 인덱스는 잡 시작 시점 PG 스냅샷). swap 후 그 변경은 증분 indexer가 새 인덱스에 다시 upsert하거나 다음 재색인이 수렴 — ADR-011 최종 일관성 허용. 1차는 이 창(window)을 수용하고 운영 로그에 남긴다.
- **원자적 swap**: `elasticsearchClient.indices().updateAliases(...)` 단일 호출에 `remove(alias from 모든 기존 인덱스)` + `add(alias to 새 인덱스)` 액션을 함께. (구현 시 정확 API 실측 — 미사용 신규.)
- **정리**: swap 성공 후, `products-v*` 중 **현재(새) + 직전 1개**(creation_date 최신순)만 보존, 나머지 삭제. 정리 실패는 WARN 로깅하되 잡 실패로 보지 않음(이미 swap 성공). 059 `products-v1`도 이 정책에 포함(2회 재색인 후 삭제 대상).
- **bootstrap alias-centric 리팩터(필수)**: 현재 `ProductSearchIndexBootstrap`은 `products-v1` 인덱스 존재로 판정해, 재색인이 alias를 옮기고 `products-v1`을 정리하면 **재부팅 시 빈 `products-v1`을 재생성**(orphan)한다. → bootstrap을 **alias 존재 기준**으로 변경: alias `products`가 (어느 인덱스든) 존재하면 무동작; 없을 때만 `products-v1` 생성 후 alias 연결. 059 동작(빈 ES 초기 부트스트랩)은 보존, orphan 재생성만 제거.

### 결정 6 — bulk 크기·백프레셔·타임아웃·실패
- **bulk 적재**: 배치(기본 500 문서)마다 `BulkOperation` 리스트(각 `index` op: `index(newIndex).id(productId).document(doc)` — **plain index, external version 없음**: 새 인덱스 단일 패스라 순서/덮어쓰기 이슈 없음). `elasticsearchClient.bulk(...)` 호출.
- **부분 실패**: `response.errors()==true`면 실패 item(productId+error) 로깅 후 **잡 중단(throw)** → swap 미수행(부분 인덱스 비노출). 1차는 재시도 없이 중단(안전 우선); 배치 내 재시도는 후속 개선 여지. 
- **타임아웃/백프레셔**: 배치 순차 처리(병렬 아님)가 자연 스로틀. bulk 요청 타임아웃은 클라이언트 기본 + 필요 시 설정. 배치 간 간격(`shop.search.reindex.throttle-ms`, 기본 0)으로 ES 부하 조절 여지.
- **치명 실패 경계**: createIndex 이후 어느 단계(배치 read/bulk)에서 실패해도 **swap 호출 전이면 alias 불변**(기존 인덱스 유지, 검색 영향 0). 미완성 새 인덱스는 다음 실행 정리 대상으로 남김. 상태=FAILED + errorMessage 기록.

### 결정 7 — 색인 대상 범위: **전체 상품(status 무관), status 필드 보존**
- 059 증분 indexer가 status 무관 전량을 색인하고 노출 필터는 읽기(T5+6)에 위임하는 것과 **정합**. 재색인도 전 status 상품을 적재하고 `status` 필드를 실어 T5+6 조회 필터가 닫는다(ADR-011 원칙 4). → keyset WHERE는 `p.id > :lastId`만(status 필터 없음). variant/category 합성은 T2+3 문서 스키마(`ProductSearchDocument`) 준수.

---

## 2. 영향 범위 (파일)

### 신규 (backend-implementor)
- `product/search/ProductSearchIndexAdmin.java` — ES 저수준 admin 연산 공용화: `createIndex(String name)`(매핑 JSON 로드 — bootstrap에서 이관), `boolean aliasExists()`, `Set<String> indicesBehindAlias()`, `void pointAliasTo(String newIndex)`(원자 updateAliases: 기존 remove + 새 add), `void bulkIndex(String index, List<ProductSearchDocument> docs)`(_id=productId, 실패 시 throw), `void deleteIndex(String name)`, `List<String> listVersionIndices()`(`products-v*`). `ProductSearchIndexConfig`(059)에서 `@Bean`(게이트 상속)으로 등록.
- `product/service/ProductSearchReindexService.java` — 오케스트레이션(keyset 순회→문서 변환→bulk→createIndex→pointAliasTo→정리), 동기 `reindex()` + `startAsync()`/`status()` + `AtomicBoolean` 가드 + 단일 executor + `DisposableBean.destroy()`. ES admin은 **`ObjectProvider<ProductSearchIndexAdmin>`**로 주입(ES 비활성 시 빈 부재 → reindex는 명확한 "검색 엔진 비활성" 실패). 항상 등록되는 @Service(ES 비의존 배선).
- `product/service/ProductSearchReindexServiceResponse.java` — REST 조합(auth→trigger/status, DTO 변환). ServiceResponse는 REST 전용.
- `product/controller/AdminProductSearchReindexRestController.java` — `POST .../reindex`(202), `GET .../status`(200). `/api/v1/admin/**` 자동 인가.
- `product/dto/ReindexStatusResponse.java`(상태 DTO: state/startedAt/finishedAt/processedCount/newIndex/error) (+ 내부 `ReindexStatus`/`ReindexResult` 필요 시).
- `ProductSearchDocument.from(ProductSearchSnapshotProjection)` 정적 팩토리 추가(status enum→name(), 나머지 1:1). (기존 `from(event)`와 공존.)
- 테스트(아래 §4).

### 수정 (backend-implementor)
- `product/repository/ProductRepository.java` — `findSearchSnapshotsAfter(lastId, limit)` keyset 추가(읽기 전용, 집계식 = `findSearchSnapshot`과 동일). 기존 쿼리 무변경.
- `product/search/ProductSearchIndexBootstrap.java` — createIndex/alias 연산을 `ProductSearchIndexAdmin`에 위임 + **alias-centric**(alias 존재 시 무동작)로 변경. ES 미가용 시 부팅 비차단 유지.
- `product/search/ProductSearchIndexConfig.java` — `ProductSearchIndexAdmin` @Bean 추가(기존 게이트 상속), bootstrap 생성자 시그니처 변경 반영.

### 무변경(재사용/전제)
- T1 ES 클라이언트·연결, T2+3 `ProductSearchDocument`/`ProductSearchIndexNames`/매핑 JSON/증분 indexer·이벤트, Product/ProductVariant/Category Entity·PG 스키마·Flyway, 공개 목록 쿼리, `SchedulerLeaderGuard`(미사용 — 스케줄 미채택), event-catalog/§5·notification 전부, `SecurityConfig`(admin matcher 이미 커버 — 무변경).

---

## 3. 재색인 데이터 흐름
1. ADMIN이 `POST .../reindex` → 컨트롤러 → ServiceResponse → `startAsync()`. `running` CAS 성공 시 executor submit + 202(상태=RUNNING). 실패 시 409.
2. (백그라운드) `reindex()`: `newIndex="products-v"+epochMillis` → `admin.createIndex(newIndex)`.
3. keyset 루프: `findSearchSnapshotsAfter(lastId, batch)` → `ProductSearchDocument.from(snapshot)` 변환 → `admin.bulkIndex(newIndex, docs)` → `lastId=마지막 productId`, processedCount 누적, 진행 로깅. 빈 배치면 종료.
4. 전량 성공 후에만 `admin.pointAliasTo(newIndex)`(원자 swap). 그 전 어느 단계 실패면 swap 미수행(alias 불변, 검색 영향 0), 상태=FAILED.
5. swap 성공 후 `admin.정리`(현재+직전1 보존, 나머지 삭제 — 실패는 WARN). 상태=SUCCESS(processedCount/newIndex/finishedAt).
6. 부팅 시 `ProductSearchIndexBootstrap`(alias-centric): alias 있으면 무동작, 없으면 `products-v1`+alias 생성(빈 ES 초기화).

## 4. 검증 (testing-rule + verification-gate-rule + 신규 규칙 §4)
### 단위(Mockito — 타깃 실행)
- 문서 변환 `from(snapshot)` 패리티(status.name(), displayPrice/purchasable 그대로). keyset 순회 종료(배치들 후 빈 배치 → 종료, lastId 진행). **bulk 실패 시 swap 미호출**(verify `pointAliasTo` 0회) + 상태 FAILED. 전량 성공 시에만 swap 1회 + 정리 호출. 동시 트리거 가드(두 번째 startAsync → 409, reindex 미실행). ES admin 부재(ObjectProvider empty) → reindex "비활성" 실패.
### 통합(Testcontainers ES(Nori)+PG — 059 하니스 계승, `@DirtiesContext`)
- PG에 상품 N건(여러 status·variant 활성/재고 조합) 시드 → `reindex()` → 새 인덱스 N건 + alias가 새 인덱스 지시. 문서 displayPrice/purchasable이 공개목록 집계와 일치.
- **중간 강제 실패**(예: 두 번째 배치에서 bulk 실패 유도) → alias **기존 인덱스 유지**(검색 영향 0), 상태 FAILED.
- **재실행 멱등**: 2회 연속 → 최종 문서 수·내용 동일, alias 최신 새 인덱스, 정리 정책대로(보존 개수).
- **매핑 변경 재구축**: 새 인덱스에 매핑 적용 후 swap → 활성.
- keyset 경계: 페이지 크기 배수·마지막 페이지에서 누락/중복 0(전량 적재).
- **bootstrap alias-centric**: alias 존재 상태 재부팅 시 orphan `products-v1` 재생성 안 함.
### Security/REST(MockMvc — ES 불요)
- `reindex` ADMIN→202, CONSUMER→403, 비로그인→401. `status` 동일 인가. 비동기 즉시 응답(완주 비대기). (ADMIN 202 케이스는 ES 부재로 백그라운드 잡이 실패하나 엔드포인트 202는 정상 — 잡 완료 비대기.)
### 회귀(메인 동적 게이트)
- 공개 목록(latest/priceAsc/priceDesc)·판매자 목록·countByStatusIn·059 증분 indexer/패리티 테스트 그린. ModularityTests/ArchUnit 그린. **메인이 풀 `./gradlew test` 직접 그린 확인**(신규 규칙 §4 — 게이팅·자원 누수 회귀는 타깃 실행이 못 잡음). Testcontainers 반복은 타깃, 풀스위트 마지막 1회.

## 5. Acceptance Criteria 매핑
| Task AC | 충족 |
|---|---|
| 풀 재색인 → 새 인덱스 bulk 적재 + alias 새 인덱스 지시 | §3 + 통합 테스트 |
| 진행 중/실패 시 alias 기존 유지(부분 비노출) | 결정 6 swap 게이트 + 중간 실패 테스트 |
| 2회 실행 멱등 + 미완성 인덱스 정리 | 결정 5 정리 + 멱등 테스트 |
| 매핑 변경 무중단 재구축 / 드리프트 복구 | 새 인덱스+swap(매핑 변경 테스트), PG 권위 재생성 |
| 트리거 인가·비블로킹 | 결정 1·2 + Security/REST 테스트 |
| PG/공개쿼리/이벤트/notification 무변경 + ModularityTests·풀스위트 그린 | §2 무변경 + 회귀 |

## 6. 트레이드오프
- **단일 alias vs read/write 분리**: 단일 alias가 증분 경로 무변경으로 최소 구현(채택). 적재~swap 창의 드리프트는 증분/다음 재색인이 수렴(ADR-011) — 1차 수용.
- **in-process 가드 vs 분산 리더**: 수동 ADMIN 트리거+멱등이라 in-process AtomicBoolean로 충분, 분산 리더는 과도설계(스케줄 도입 시 재검토).
- **bulk 실패 시 중단 vs 재시도**: 안전(부분 인덱스 비노출) 우선 중단. 배치 재시도는 후속.
- **admin 추출 + bootstrap 리팩터**: DRY·alias-centric 정합 확보(채택). 059 커밋 코드 변경이나 Task가 명시 허용한 "공용 색인 어댑터 추출".
- **ObjectProvider 게이팅**: 트리거 엔드포인트는 ES 비의존으로 항상 배선(보안 테스트 가능), ES 작업만 게이트 — 풀 컨텍스트 회귀 차단(신규 규칙 §1).

## 7. 구현 시 해소할 검증 게이트(추정 금지 — 실측)
1. `elasticsearchClient.bulk(...)` / `BulkOperation`(index op, _id, document) 정확 시그니처(8.15.x) + `response.errors()`/`items()` 처리.
2. `indices().updateAliases(...)` 원자 remove+add 액션 시그니처(미사용 신규).
3. `indices().get("products-v*")`(또는 cat) 와일드카드 조회·creation_date로 정리 대상 선별.
4. keyset 메서드 `Limit` vs `Pageable` 반환 List 컴파일·실행(GROUP BY + ORDER BY p.id + limit, count 쿼리 미발생 확인).
5. `ObjectProvider<ProductSearchIndexAdmin>` 빈 부재 시 reindex 동작(명확 실패) + 트리거 빈 풀 컨텍스트 배선(ES 없는 보안 테스트 그린 — baseline 대조).
6. bootstrap alias-centric 변경이 059 통합 테스트 회귀 0. 특히 059 `ProductSearchIndexIntegrationTest`의 `@BeforeEach`(`delete(products-v1)` 후 `ensureIndex()`)가 새 alias-centric 로직에서도 `products-v1`을 재생성하는지 확인 — 그 테스트는 alias가 `products-v1`에만 연결되므로 삭제 시 alias도 소멸→재생성 성립(이 전제가 유지되는지 실측).
7. executor `DisposableBean.destroy()` shutdown으로 스레드 누수 0(병렬 풀스위트 행 방지 — 신규 규칙 §2). `running` 가드가 submit 실패 경로에서도 복원됨(위 결정 2)을 단위 테스트로 확인.
8. keyset 쿼리의 LIMIT가 실제 SQL로 푸시다운되어 in-memory 페이징(HHH000104) 미발생 — 스칼라 집계라 발생 안 할 것이나 1회 실측.

## 8. 워크플로우
1. (완료) 코드 대조 + 본 plan → **plan-reviewer → 필요 시 plan-fixer**.
2. PASS 후 **backend-implementor**(풀스위트 금지, `--tests` 타깃 — subagent-rule). view 없음.
3. **reviewer** → FAIL 시 **fixer**(최대 3회).
4. **메인이 `./gradlew test` 풀 그린 + ModularityTests 직접 확인**(verification-gate §2, 신규 규칙 §4) — baseline 대조로 풀 컨텍스트 회귀 0.
5. 보고. 커밋은 사용자 요청 시.

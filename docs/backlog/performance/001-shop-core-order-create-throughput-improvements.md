# (backlog) 주문 생성 처리량(throughput) 개선 분석

> 상태: backlog (미착수 — 분석/측정 우선)
> 영역: shop-core (backend / order·inventory 도메인 + k6 perf 자산)
> 출처: 사용자 질문 — "응답속도 테스트상 ~200rps가 적정이었는데 성능을 더 개선할 요소가 있는가". 핫패스 실사 후 작성.
> 관련: `docs/report/performance/001-virtual-thread-ab-measurement.md`(VT는 throughput 지렛대 아님), k6 order-create 프로파일(`shop-core/perf/k6`).

## 핵심 결론 (먼저)
1. **현재 측정된 ~100~200rps 한계는 "단일 variant 자기경합"이라는 측정 방식의 산물**이다. perf 시드가 SKU(variant)를 1개만 만들어 모든 주문이 같은 행 락에 직렬화된다. 무엇을 고치기 전에 **다중 variant로 재측정**하는 것이 0순위.
2. 단일 핫 SKU 처리량 = `1 / (행 락 보유 시간)`. 비관적 락은 **트랜잭션 커밋까지** 유지되므로, 진짜 레버는 **락 보유 시간(critical section) 단축**이다.
3. 흔히 기대하는 일부 "최적화"(조건부 UPDATE, 커넥션 풀 상향, 가상스레드)는 **단일 핫-행 한계를 실제로는 옮기지 못한다**. 솔직한 효과 구분이 본 문서의 목적.

## 배경 — 병목의 정체 (코드 확인)
- `OrderService.createOrderTx`(`@Transactional`)가 주문 생성 임계구역. (`shop-core/.../order/service/OrderService.java:136-256`)
- 흐름:
  1. 장바구니 조회 → 사전검증 스냅샷(락 없음, advisory)
  2. variantId 오름차순으로 `InventoryStockPort.decrease()` 호출 → `findByIdForUpdate` = **`SELECT ... FOR UPDATE`** (variant 행 비관적 락). (`inventory/service/InventoryStockPortImpl.java:56-76`, `inventory/spi/InventoryStockPort.java:17`)
  3. 락 보유 상태로 **락-후 스냅샷 재조회 쿼리**(`getOrderableSnapshots` 2번째 호출, price 권위값 확보용 — `OrderService.java:176`)
  4. order INSERT + 항목 N개 INSERT + 옵션값 INSERT + (쿠폰 시) 조건부 UPDATE 2건 + 장바구니 DELETE
  5. 커밋 → 이때 비로소 행 락 해제 (PostgreSQL 쓰기 락은 tx 종료까지 유지)
- 즉 락은 2단계부터 커밋까지 유지되며, 그 안의 모든 쿼리·INSERT가 락 창(critical section)에 포함된다.
- **이벤트 발행은 락 창 밖**(Modulith Outbox 외부화 = 커밋 후 비동기). 좋음 — 손볼 것 없음. (`application.yml` modulith.events.externalization.enabled=true)

## 측정 방식의 함정 (가장 중요)
- `shop-core/perf/k6/lib/seed.js`의 `setupSeed()`는 `createVariant`를 **1회만** 호출 → **단일 `variantId`**. order-create 시나리오의 모든 buyer가 그 하나의 SKU를 주문한다.
- `config.js` 주석이 이를 명시: *"단일 variant PESSIMISTIC_WRITE 직렬화"*, *"단일 variant 락 자기유발 경합"*, 앱 처리 상한 ≈ 90~100 orders/s.
- 따라서 측정값은 **"모두가 같은 상품 하나를 동시에 사는"** 최악 경합 시나리오다. 현실 트래픽은 주문이 여러 SKU로 분산되어 행 락이 한 행에 몰리지 않으므로, 실제 운영 처리량은 이보다 훨씬 높다.

## 개선 레버 (우선순위순, 효과 솔직히 표기)

### 0순위 — 측정 현실화 (무위험, 최대 효과)
- order-create 시드를 **다중 variant**로 변경(예: catalog-read 시드가 이미 상품 50개 생성 — `setupCatalogSeed` 패턴 차용)하고 buyer가 variant를 분산 선택하도록 시나리오 수정. 재측정.
- 기대: 행 경합이 제거되어 200rps를 크게 상회, "진짜 한계"가 DB 행 락이 아니라 커넥션 풀/코어임이 드러남.
- 산출물: 다중 variant 베이스라인 JSON + 단일 vs 분산 비교표.

### 1순위 — 락 보유 시간 단축 (핫 SKU에 실효, 저위험)
- **(a) Hibernate JDBC 배칭** — 현재 `application.yml`에 미설정(확인됨). `spring.jpa.properties.hibernate.jdbc.batch_size`(예 20) + `order_inserts=true` + `order_updates=true` 추가 → 락 창 안의 order+항목+옵션값 INSERT 라운드트립을 묶어 락 창 단축. **순수 설정, 위험 낮음.**
- **(b) 락-후 재조회 쿼리 정리** — `OrderService.java:176`의 2번째 `getOrderableSnapshots`(락 후 price 권위값)를 decrease 경로에서 함께 반환받거나, 동시 가격 수정이 실질 위험이 아니면 1단계 advisory 스냅샷을 신뢰해 제거 → 락 창 안의 쿼리 1회 감소. **단 방어적 재검증이라 정합성 트레이드오프 검토 필요.**

### 2순위 — 원자적 조건부 UPDATE (효과 제한적 — 솔직히)
- `SELECT FOR UPDATE` + read-modify-write 대신 `UPDATE variant_stock SET stock = stock - :q WHERE id=:id AND is_active AND stock >= :q` 1방 + 영향 행수 검사.
- **주의: 같은 트랜잭션 안에선 이 UPDATE의 행 락도 커밋까지 유지되므로 핫-행 직렬화 한계는 바뀌지 않는다.** 이득은 SELECT+UPDATE 2회 → 1회 라운드트립 절감과 lost-update 방지뿐. "처리량 폭증"을 기대하면 안 됨.

### 3순위 — 커넥션 풀 / DB 스케일
- 현재 HikariCP `maximum-pool-size=10`(`application.yml:14`, 기본값 복원). PG `max_connections` 기본 100.
- 0순위로 행 경합을 제거한 **분산 주문** 상황에서만 풀 상향(+코어)이 처리량을 끌어올린다. 단일 행에 묶인 동안엔 풀을 늘려도 전부 락 대기 → 무의미.

### 4순위 — 아키텍처 (진짜 플래시세일 규모일 때만)
- 단일 SKU가 DB 행 락 처리량을 반드시 넘어야 하는 경우에 한해:
  - 재고 예약을 Redis 원자 카운터로 분리(주문은 비동기 영속화 + 원장 정합 보정). 분산락 백로그([[007-backend-shop-core-distributed-lock]]) 연계.
  - 한 SKU 재고를 N버킷으로 샤딩(랜덤 버킷 차감) → 단일 논리 SKU의 병렬도 증가.
- **복잡도·정합성 비용이 크다.** 0순위 측정이 "정말 필요"하다고 말할 때만 착수.

## 레버 아님 (이미 정리됨 — 재론 금지)
- **가상스레드**: A/B 리포트(`docs/report/performance/001`)에서 "VT는 자원효율 도구, throughput 지렛대 아님"으로 결론. 주문 한계를 못 올린다.
- **읽기 캐싱**: 주문 생성은 쓰기·락 바운드라 무관.
- **이벤트 발행 비동기화**: 이미 Outbox로 커밋 후 외부화 — 락 창 밖.

## 권장 순서
1. (0) 다중 variant 시드 + 재측정 → 진짜 한계 위치 확인.
2. (1) 측정이 핫-SKU 락 창을 가리키면 Hibernate 배칭 + 락-후 쿼리 정리.
3. (3) 분산 처리량이 풀/코어에 막히면 풀 상향.
4. (4) 단일 SKU 초고동시(플래시세일)가 실제 요구로 확인될 때만 아키텍처 변경.

## 범위 밖 / 주의
- 본 문서는 **분석·우선순위**다. 착수 시 각 레버를 별도 task/plan으로 분해하고, **변경 전후 k6 베이스라인 비교**(깨끗한 DB, notification log 모드 — [[k6-perf-baseline-needs-clean-db]], [[perf-test-notification-must-be-log-mode]])로 효과를 수치 검증한다.
- 비관적 락 → 조건부 UPDATE 전환 시 재고 원장(StockLedgerEntry) 적재·복원/취소 경로 정합을 깨지 않을 것.

## 참고
- 핫패스: `shop-core/.../order/service/OrderService.java`(createOrderTx), `inventory/service/InventoryStockPortImpl.java`(decrease/increase), `inventory/spi/InventoryStockPort.java`.
- perf 자산: `shop-core/perf/k6/lib/{config.js,seed.js}`, `profiles/{load,stress,smoke}.js`, `baselines/order-create-*.json`.
- 설정: `shop-core/src/main/resources/application.yml`(hikari pool 14, jpa 16-23, modulith externalization 38-47).
- 측정 선례: `docs/plans/performance/002·003`(load/stress 프로파일), `docs/report/performance/001`(VT A/B).

# 034 shop-core 재고 조정(Adjustment) + 재고 변동 원장(Ledger) 구현 Plan

> 대상 Task: `docs/tasks/backend/034-backend-shop-core-inventory-stock-adjustment-ledger.md`
> 본 plan은 Task의 "설계 정정(2026-06-15)" 4개 결정을 코드 실측과 대조해 확정한 구현 명세다. Non-goals(예약/확정 분리·backorder·부분복원·재입고·Low-stock 이벤트·멀티로케이션·분산락=Task 035)는 포함하지 않는다.

## 구현 목표
주문 차감/취소·만료 복원/운영자 조정 등 **성공한 모든 재고 변동**을 사유·전후 수량·행위자·발생시각과 함께 기록하는 감사 원장(`inventory_stock_ledger`)을 신설하고, 손실·손상·실사 보정용 **운영자 재고 조정 API**를 seller/product 네임스페이스에 추가한다.

---

## 1. 설계 방식 및 이유

### 1.1 원장 적재 위치 — inventory 포트가 잠금 트랜잭션 안에서 atomically 기록
재고 변동의 SSOT는 `VariantStock.stock` UPDATE다(`InventoryStockPortImpl.java:46,70`). 원장은 그 UPDATE와 **같은 비관적 락·같은 트랜잭션 안에서** 전후 수량을 캡처해 적재해야 정합한다. 따라서 호출자가 별도 ledger 포트를 따로 부르는 방식이 아니라, **기존 `decrease`/`increase` 포트에 변동 맥락(reason·actorId·memo)을 인자로 추가**하고 inventory 구현이 락 안에서 원장 row를 INSERT한다.

- 이유: ① 전후 수량은 락을 잡은 inventory만 권위 있게 안다. ② 호출자가 ledger를 따로 부르면 `increase()`의 **variant 미존재 skip 경로**(`InventoryStockPortImpl.java:71-75`)를 호출자가 알 수 없어 "재고는 그대로인데 원장만 기록"되는 불일치가 생긴다. inventory가 skip을 판정하므로 skip 시 원장 미기록을 보장할 수 있다(Task Goal 1·Scope 일치).
- reason/actorId/memo는 **primitive·inventory 소유 enum만** 전달 — order Entity 참조 없음(모듈 경계 유지, `InventoryStockPort.java:15`).

### 1.2 변동 맥락은 호출자가 전달 — increase가 취소/만료를 구분 못 하기 때문
`increase()`는 취소(`OrderCancellationImpl.cancel`)·만료(`cancelByExpiry`) 둘 다에서 호출되지만(`OrderCancellationImpl.java:204-206`) 내부적으로 구분 불가하다. 맥락을 아는 호출자(취소 경로=`CANCEL_RESTORE`, 만료 경로=`EXPIRY_RESTORE`, 주문 생성=`ORDER_DECREASE`)가 reason을 명시 전달한다.

### 1.3 조정 API는 seller/product 네임스페이스 — 소유권을 inventory가 판정 불가
SELLER 소유권은 `Product.ownerId`(V3) 기반이며 product가 소유한다(`ProductService.checkOwnership:168`). inventory는 product를 직접 참조할 수 없다(`InventoryStockPort.java:15`). 따라서 조정/조회 엔드포인트를 **`/api/v1/seller/products/{productId}/variants/{variantId}/...`** 에 두고(기존 `SellerProductVariantRestController` 규약과 정합), 소유권은 `ProductService.getOwnedProduct(actorId, actorIsAdmin, productId)`로 native 해결한 뒤, 재고변경·원장 적재·원장 조회는 **published port(inventory.spi)** 로 위임한다. 이는 `order → inventory.spi` 선례와 동형인 `product → inventory.spi` 의존이며, Modulith `@NamedInterface("spi")`가 허용한다(`inventory/spi/package-info.java:10`, `ModularityTests.java`).

### 1.4 occurred_at — Instant 저장, KST 렌더 (ADR-009)
`occurred_at`은 `timestamptz`/`Instant`로 절대시각 저장, 조회 응답 DTO에서만 KST(`Asia/Seoul`) ISO-8601 오프셋으로 표현. 시각 생성은 inventory가 `Instant.now()`로 잡는다(전후 수량과 동일 시점 일관).

---

## 2. 구성 요소 (신설/수정, 패키지 경로까지)

### 2.1 Flyway 마이그레이션 — 신설
**신규 `shop-core/src/main/resources/db/migration/V8__inventory_stock_ledger.sql`** (다음 버전 = V8; 현재 최신 V7 확인).

```sql
CREATE TABLE inventory_stock_ledger (
    id              bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    variant_id      bigint      NOT NULL
                    REFERENCES product_variants (id) ON DELETE CASCADE,
    delta           int         NOT NULL,            -- 부호 있는 변동량(차감 음수, 복원/증분 조정 양수)
    reason          varchar(20) NOT NULL
                    CHECK (reason IN ('ORDER_DECREASE','CANCEL_RESTORE','EXPIRY_RESTORE','ADJUSTMENT')),
    quantity_before int         NOT NULL CHECK (quantity_before >= 0),
    quantity_after  int         NOT NULL CHECK (quantity_after >= 0),
    actor_id        bigint      REFERENCES users (id) ON DELETE SET NULL,  -- 시스템=NULL, 운영자=users.id
    memo            text,                            -- ADJUSTMENT 필수(앱 검증), 그 외 NULL
    occurred_at     timestamptz NOT NULL
);
CREATE INDEX idx_inventory_stock_ledger_variant_id ON inventory_stock_ledger (variant_id);
CREATE INDEX idx_inventory_stock_ledger_occurred_at ON inventory_stock_ledger (occurred_at);
```

- `delta`/`quantity_*`는 `int`(product_variants.stock과 동형 `int` — `VariantStock.java:35`). **`smallint` 회피**(메모리 선례: smallint↔int 매핑이 entityManagerFactory를 깸). 모든 수량 컬럼 `int` 사용으로 `@JdbcTypeCode` 불요.
- `actor_id`는 `ON DELETE SET NULL`(회원 탈퇴 시 감사 원장 보존). 시스템 변동(주문/취소/만료)은 actor_id NULL(Task Scope: "시스템=약속값/null").
- `occurred_at`에 DB DEFAULT를 두지 않는다 — 앱(inventory)이 전후 수량과 동일 시점에 `Instant`로 명시 세팅(트리거/디폴트와의 시점 불일치 방지).
- 이 테이블은 **신규 컬럼만 가지므로 BaseEntity(트리거 updated_at) 미상속** — `occurred_at`만 시각 컬럼.

### 2.2 inventory 도메인/리포지토리 — 신설
- **신규 Entity** `com.shop.shop.inventory.domain.StockLedgerEntry`
  - `@Entity @Table(name = "inventory_stock_ledger")`, `@Id @GeneratedValue(strategy = IDENTITY) Long id`.
  - 필드: `long variantId`, `int delta`, `@Enumerated(EnumType.STRING) StockChangeReason reason`(`@Column varchar`), `int quantityBefore`, `int quantityAfter`, `Long actorId`(nullable), `String memo`(nullable, `@Column(columnDefinition="text")`), `Instant occurredAt`.
  - 정적 팩토리 `StockLedgerEntry.of(variantId, delta, reason, before, after, actorId, memo, occurredAt)`. Setter 금지(`VariantStock` 컨벤션 계승).
- **신규 enum** `com.shop.shop.inventory.spi.StockChangeReason` — `ORDER_DECREASE, CANCEL_RESTORE, EXPIRY_RESTORE, ADJUSTMENT`. **inventory 소유**(포트로 호출자에게 노출되는 유일한 비-primitive 타입). **spi 패키지 배치**: order/product가 reason을 참조하는데 `inventory.domain`은 `@NamedInterface`가 아니라 ModularityTests가 깨지므로 `inventory.spi`에 둔다(구현 단계 정정, 2026-06-15).
- **신규 Repository** `com.shop.shop.inventory.repository.StockLedgerRepository extends JpaRepository<StockLedgerEntry, Long>`
  - `Page<StockLedgerEntry> findByVariantIdOrderByOccurredAtDescIdDesc(long variantId, Pageable pageable)` (원장 조회, 최신순; id 보조정렬로 동시각 안정 정렬).

### 2.3 inventory published port — 수정(시그니처 확장 + 조회/조정 메서드 추가)
**수정** `com.shop.shop.inventory.spi.InventoryStockPort`:
- `void decrease(long variantId, int quantity)` → **`void decrease(long variantId, int quantity, StockChangeContext context)`**
- `void increase(long variantId, int quantity)` → **`void increase(long variantId, int quantity, StockChangeContext context)`**
- **신규 조정 메서드** `void adjustStock(long variantId, int delta, long actorId, String memo)` — reason=ADJUSTMENT 고정. delta(부호 있는 보정량), memo 필수, actorId 운영자.
- **신규 조회 메서드** `Page<StockLedgerView> getLedger(long variantId, Pageable pageable)` — `StockLedgerView`는 inventory.spi 소유 record DTO(Entity 미노출).
- **신규 내부 타입(포트 동반)**:
  - `record StockChangeContext(StockChangeReason reason, Long actorId, String memo)` + 정적 팩토리 `system(StockChangeReason reason)`(actorId=null, memo=null), `operator(StockChangeReason reason, long actorId, String memo)`.
  - `record StockLedgerView(long id, long variantId, int delta, StockChangeReason reason, int quantityBefore, int quantityAfter, Long actorId, String memo, Instant occurredAt)`.
  - port는 web 타입을 받지 않는다(architecture-rule) — scalar·inventory enum·Pageable만.

### 2.4 inventory 구현체 — 수정
**수정** `com.shop.shop.inventory.service.InventoryStockPortImpl`(생성자에 `StockLedgerRepository` 추가):
- `decrease`: 락 획득 → isActive/stock 검증 → `before=getStock()` 캡처 → `decrease(qty)` → `after=getStock()` → `StockLedgerEntry.of(variantId, -qty, ctx.reason(), before, after, ctx.actorId(), ctx.memo(), Instant.now())` INSERT.
- `increase`: `findByIdForUpdate` → 존재 시 `before` 캡처 → `increase(qty)` → `after` → 원장 INSERT(delta=+qty). **미존재 skip 경로는 원장 미기록**(현행 `ifPresentOrElse` else 분기 유지, log만).
- **신규 `adjustStock`**: `findByIdForUpdate`로 락 → 미존재 → `VariantNotFoundException`(404; 조정은 명시적 단건 대상이라 미존재는 부정확 입력 = 404. 주문 차감의 `InsufficientStockException` 409와 구분, §4). → `newStock = stock + delta` 계산 → **`newStock < 0` → `InsufficientStockException`(409)**(DB CHECK `stock>=0`과 정합) → `before` 캡처 → delta 부호에 따라 stock 갱신 → `after` → 원장 INSERT(reason=ADJUSTMENT, actorId, memo). isActive 미검사(비활성 variant도 실사 보정 허용 — `increase` JavaDoc:51 선례).
- **신규 `getLedger`**: `@Transactional(readOnly=true)`로 `StockLedgerRepository.findByVariantIdOrderByOccurredAtDescIdDesc(...)` → `StockLedgerView` 매핑.

### 2.5 product 위임 서비스 — 신설 (소유권 게이트 + variant↔product 검증)
**신규** `com.shop.shop.product.service.StockAdjustmentService`(`@Service @Transactional`):
- 의존: `ProductService`(소유권), `ProductVariantRepository`(variant↔product 소속 검증), `InventoryStockPort`(inventory.spi 위임).
- `void adjustStock(long actorId, boolean actorIsAdmin, long productId, long variantId, int delta, String memo)`:
  1. `productService.getOwnedProduct(actorId, actorIsAdmin, productId)` → 소유권(404)·상품 미존재(404).
  2. variant↔product 소속 검증: `productVariantRepository.findById(variantId).filter(v -> v.getProduct().getId().equals(productId)).orElseThrow(() -> new VariantNotFoundException(variantId))` (선례 `ProductVariantService.java:107-109`).
  3. memo 누락 검증(서비스 2차 — Bean Validation 1차): `memo == null || memo.isBlank()` → `BusinessException(400)`.
  4. `inventoryStockPort.adjustStock(variantId, delta, actorId, memo)` 위임(음수/미존재 inventory 책임).
- `Page<StockLedgerView> getLedger(long actorId, boolean actorIsAdmin, long productId, long variantId, Pageable pageable)`: 위 1·2 동일 → `inventoryStockPort.getLedger(variantId, pageable)` 위임. `@Transactional(readOnly=true)`.
- 배치 근거: product가 소유권을 보유하므로 위임 게이트는 product에 둔다(§1.3). inventory.spi의 `StockLedgerView`를 그대로 통과(web facade에서 응답 DTO로 변환).

### 2.6 product ServiceResponse + Controller + DTO — 신설
- **신규** `com.shop.shop.product.service.StockAdjustmentServiceResponse`(`@Service`): REST principal 추출(`(long) auth.getPrincipal()`, `ROLE_ADMIN` 보유 판정 — `ProductVariantServiceResponse` 패턴 복제), `StockAdjustmentService` 위임, `StockLedgerView` → 응답 DTO 변환(occurred_at KST 렌더).
- **신규 Controller** `com.shop.shop.product.controller.SellerStockAdjustmentRestController`
  - `@RestController @RequestMapping("/api/v1/seller/products/{productId}/variants/{variantId}")`.
  - `@PostMapping("/stock-adjustments")` → `ResponseEntity<StockAdjustmentResponse>`(기존 variant create와 일관성 위해 200 OK 채택). 본문 `@Valid StockAdjustmentRequest`.
  - `@GetMapping("/ledger")` → `ResponseEntity<Page<StockLedgerResponse>>`. `Pageable`(기본 size·정렬은 서비스가 occurred_at desc 고정).
  - 비즈니스 로직 없음 — ServiceResponse 위임(forbidden-rule).
- **신규 DTO** `com.shop.shop.product.dto`:
  - `record StockAdjustmentRequest(@NotNull Integer delta, @NotBlank String memo)` — delta는 0 금지(`@NotNull` + 서비스에서 `delta == 0` → 400).
  - `record StockAdjustmentResponse(long variantId, int delta, int quantityBefore, int quantityAfter, String occurredAt)` — `of(StockLedgerView)` 팩토리, occurred_at KST 렌더.
  - `record StockLedgerResponse(long id, int delta, String reason, int quantityBefore, int quantityAfter, Long actorId, String memo, String occurredAt)` — `from(StockLedgerView)` 팩토리, KST 렌더.

### 2.7 호출부 수정 — 3곳 (재고 동작 불변, 맥락 전달만 추가)
- `order/service/OrderService.java:169` `inventoryStockPort.decrease(variantId, qty)` → `decrease(variantId, qty, StockChangeContext.system(ORDER_DECREASE))`.
- `order/service/OrderCancellationImpl.java:205` `inventoryStockPort.increase(...)` → 취소 경로(`cancel`)는 `CANCEL_RESTORE`, 만료 경로(`cancelByExpiry`)는 `EXPIRY_RESTORE`. **현재 `doCancel`이 두 경로 공통 코어**이므로 **`doCancel`에 `StockChangeReason restoreReason` 파라미터 추가**(`cancel`→CANCEL_RESTORE, `cancelByExpiry`→EXPIRY_RESTORE 전달). `increase(item.getVariantId(), item.getQuantity(), StockChangeContext.system(restoreReason))`.
- `payment/service/PaymentService.java:328` `expirePendingOrder`는 `orderCancellation.cancelByExpiry(orderId)` 호출만 하므로 **변경 없음**(reason은 `cancelByExpiry` 내부에서 EXPIRY_RESTORE 결정. PaymentService는 inventory 포트를 직접 부르지 않음).

### 2.8 보안 — 수정 불요
`/api/v1/seller/**` → `hasRole("SELLER")`가 이미 신규 경로를 커버(RoleHierarchy로 ADMIN 함의). SecurityConfig 변경 없음.

---

## 3. 데이터 흐름 (단계별)

### 3.1 (a) 주문 차감/취소/만료 시 원장 적재
- **주문 차감**: `OrderService.createOrderTx`(@Transactional) → variantId 오름차순 → `inventoryStockPort.decrease(vId, qty, ctx[ORDER_DECREASE])` → inventory: 락 → 검증 → before 캡처 → stock-=qty → after → ledger INSERT(delta=-qty, actor=null). 전부 order 트랜잭션 1커밋.
- **취소 복원**: `PaymentService.cancel` → `OrderCancellation.cancel` → `doCancel(order, refundInfo, CANCEL_RESTORE)` → variantId 오름차순 `increase(vId, qty, ctx[CANCEL_RESTORE])` → inventory: 락 → before → stock+=qty → after → ledger INSERT(delta=+qty). variant 미존재 시 stock·ledger 둘 다 skip.
- **만료 복원**: `PaymentService.expirePendingOrder` → `cancelByExpiry` → `doCancel(order, RefundInfo(false,0,KRW), EXPIRY_RESTORE)` → 위와 동일, reason=EXPIRY_RESTORE.

### 3.2 (b) 운영자 조정 POST
`POST /api/v1/seller/products/{pid}/variants/{vid}/stock-adjustments` {delta, memo}
→ `SellerStockAdjustmentRestController` → `StockAdjustmentServiceResponse`(actorId·actorIsAdmin 추출)
→ `StockAdjustmentService.adjustStock`: ① `getOwnedProduct`(소유권 404) → ② variant↔product 소속(404) → ③ memo/delta 검증(400) → ④ `inventoryStockPort.adjustStock(vid, delta, actorId, memo)`
→ inventory: 락(`findByIdForUpdate`) → 미존재 404 → `newStock=stock+delta<0` → 409 → before → stock 갱신 → after → ledger INSERT(reason=ADJUSTMENT, actorId, memo, occurredAt=now)
→ 200 `StockAdjustmentResponse`(before/after/occurredAt KST).

### 3.3 (c) 원장 조회 GET
`GET /api/v1/seller/products/{pid}/variants/{vid}/ledger?page&size`
→ Controller → ServiceResponse → `StockAdjustmentService.getLedger`: 소유권·소속 검증(404) → `inventoryStockPort.getLedger(vid, pageable)` → `StockLedgerRepository.findByVariantIdOrderByOccurredAtDescIdDesc` → `StockLedgerView` Page
→ 200 `Page<StockLedgerResponse>`(occurred_at KST 렌더).

---

## 4. 예외 처리 전략 (error-response-rule 매핑)

| 상황 | 예외 | HTTP | 책임 위치 |
|---|---|---|---|
| 조정 결과 음수 재고 | `InsufficientStockException`(기존, 409) | 409 | inventory `adjustStock` (DB CHECK `stock>=0` 정합) |
| variant↔productId 불일치 | `VariantNotFoundException`(기존, 404) | 404 | product `StockAdjustmentService`(소속 검증 선례) |
| variant 미존재(조정 대상) | `VariantNotFoundException`(404) | 404 | inventory `adjustStock`(락 후 미존재). 단, product 소속검증이 먼저 404 |
| 소유권 위반(타 SELLER) | `ProductAccessDeniedException`(기존, **404** 존재 은닉) | 404 | `ProductService.checkOwnership` |
| 상품 미존재 | `ProductNotFoundException`(기존, 404) | 404 | `ProductService.getOwnedProduct` |
| memo 누락(ADJUSTMENT) | `@NotBlank`(1차) → `BusinessException`(2차, 400) | 400 | DTO Bean Validation + `StockAdjustmentService` |
| delta 누락/0 | `@NotNull`(1차) → `BusinessException`(`delta==0`, 400) | 400 | DTO + 서비스 |
| 인증 없음 | Security 401 | 401 | SecurityConfig |
| CONSUMER 접근 | Security 403 | 403 | `hasRole("SELLER")` |

- 소유권 위반이 403 아닌 404인 이유: 기존 product 소유권 규약(존재 은닉)을 재사용하므로 정합 유지. Task의 "403·404"는 비인가 권한(403)과 타 소유자(404)를 함께 의미하며 본 plan은 그 규약을 따른다.
- 모든 예외는 `BusinessException` 계층 → `RestExceptionHandler`가 단일 변환. Controller/Service에서 `ErrorResponse` 직접 조립 금지.

---

## 5. 검증 방법 (테스트 클래스별)

### 5.1 schema-mapping (1차 관문 — 전체 스위트보다 먼저)
- `SchemaMappingValidationTest`(기존)에 신규 Entity가 자동 포함됨(`com.shop.shop` 전 Entity 스캔). V8 적용 후 `ddl-auto=validate` 통과 확인.
- **RED 경험 확인(필수)**: `StockLedgerEntry.delta`를 일부러 어긋난 매핑으로 RED 확인 후 복원(rule 절차). 단독 실행: `./gradlew test --tests "com.shop.shop.SchemaMappingValidationTest"`.

### 5.2 inventory 통합 (Testcontainers)
- **신규** `inventory/repository/StockLedgerRepositoryIntegrationTest`: variant_id FK·occurred_at desc 정렬·페이지네이션·actor_id NULL 저장.
- **신규** `inventory/service/InventoryStockPortImplLedgerIntegrationTest`:
  - decrease/increase가 reason별로 원장 1건씩 기록(전후 수량 정확).
  - **`increase()` variant 미존재 skip → 원장 미기록**(핵심 — Task 명시).
  - `adjustStock` 양수/음수 delta 정상, 음수 재고 → 409 + 원장 미기록(롤백), 미존재 → 404.

### 5.3 동시성 (RED→GREEN, 선례 `OrderCancellationConcurrencyIntegrationTest`)
- **신규** `inventory/service/StockAdjustmentConcurrencyIntegrationTest`: 동일 variant 동시 조정 N건이 `PESSIMISTIC_WRITE`로 직렬화 → 최종 stock·ledger 건수 정합(잃어버린 갱신 없음). RED는 락 제거 변형으로 1회 확인.

### 5.4 단위 (Mockito)
- **신규** `product/service/StockAdjustmentServiceTest`: 소유권 위반 404, variant↔product 불일치 404, memo 공란 400, delta=0 400, 정상 위임 호출 인자 검증(`inventoryStockPort.adjustStock` mock).
- **신규/확장** `inventory/service/InventoryStockPortImplTest`: adjustStock 음수 거부 409, before/after 캡처 인자 검증.

### 5.5 권한 매트릭스 (api-authorization-rule)
- **신규** `product/controller/SellerStockAdjustmentRestControllerSecurityTest`: 자기 product variant 조정 — SELLER 200 / ADMIN 200 / 타 SELLER product 404 / CONSUMER 403 / 비인증 401. ledger GET 동일 매트릭스.
- **메모리 선례 주의**: ledger GET은 조건부 버튼 없는 순수 데이터라 MockMvc로 충분(E2E 불요).

### 5.6 회귀
- 기존 order 차감/취소/만료 테스트는 포트 시그니처 확장으로 컴파일·mock stubbing 갱신 필요 → `decrease`/`increase` mock 호출을 새 시그니처로 수정(동작 불변 회귀 0 확인).
- `ModularityTests.verifiesModuleStructure()` GREEN — product→inventory.spi가 named interface 의존이라 통과(order 선례 동형).

---

## 6. 트레이드오프

| 결정 | 채택 | 버린 안 | 이유 |
|---|---|---|---|
| 원장 적재 위치 | 기존 포트 시그니처 확장(decrease/increase에 context) | 별도 `LedgerPort`를 호출자가 따로 호출 | 별도 포트는 `increase()` variant-skip을 호출자가 못 잡아 "재고 그대로·원장만 기록" 불일치. 전후 수량도 락 잡은 inventory만 권위. (Task 모순1 결정) |
| 조정 API 배치 | product 네임스페이스(`product→inventory.spi`) | `/api/v1/inventory/...`에서 inventory가 소유권 판정 | inventory는 `Product.ownerId` 참조 금지 — 소유권 판정 불가. order 선례 동형 의존. (Task 모순2 결정) |
| context 타입 | decrease/increase 공통 `StockChangeContext` | increase는 reason만, decrease만 Context | 시그니처 일관·테스트 단순. 시스템 경로는 `system(reason)` 팩토리로 actorId/memo null 노이즈 제거 |
| variant 미존재(조정) | 404(`VariantNotFoundException`) | 409(`InsufficientStockException`, 차감 선례) | 조정은 명시적 단건 대상 → 미존재는 부정확 입력(404)이 의미상 정확. 차감은 주문 흐름의 상태충돌(409)과 성격 다름 |
| 원장 조회 응답 | `Page<StockLedgerResponse>`(페이지네이션) | 전체 List | 원장은 누적 증가 — 페이지네이션 필수. occurred_at desc 고정 |
| reason enum 소유 | inventory 소유(포트로 노출) | order/product 소유 | 변동 분류는 재고 도메인 개념 — inventory가 SSOT. 포트로 넘기는 유일한 비-primitive(모듈 경계 허용 타입) |

---

## 7. 구현 순서 (단계별)

1. **V8 마이그레이션 + 신규 Entity/enum/Repository**(`StockLedgerEntry`, `StockChangeReason`, `StockLedgerRepository`) → `SchemaMappingValidationTest` 단독 RED→GREEN(§5.1).
2. **inventory.spi 포트 확장**: `StockChangeContext`/`StockLedgerView` 추가, `decrease`/`increase` 시그니처 변경, `adjustStock`/`getLedger` 선언.
3. **`InventoryStockPortImpl` 구현**(원장 적재·adjustStock·getLedger) → inventory 통합/단위·동시성 테스트(§5.2·5.3·5.4).
4. **호출부 3곳 수정**(OrderService, OrderCancellationImpl `doCancel` reason 주입; PaymentService 무변경) → 기존 order 테스트 mock 갱신·회귀(§5.6).
5. **product 위임 계층**: `StockAdjustmentService` → `StockAdjustmentServiceResponse` → DTO → `SellerStockAdjustmentRestController` → 단위·권한 매트릭스(§5.4·5.5).
6. **ModularityTests** GREEN 확인 → 전체 `./gradlew test`(verification-gate).

---

## 8. 영향받는 기존 호출부 변경 명세 (3곳)

| 파일:라인 | 현재 | 변경 후 |
|---|---|---|
| `order/service/OrderService.java:169` | `inventoryStockPort.decrease(cartItem.variantId(), cartItem.quantity())` | `...decrease(vId, qty, StockChangeContext.system(StockChangeReason.ORDER_DECREASE))` |
| `order/service/OrderCancellationImpl.java:128,205` | `doCancel(Order, RefundInfo)` / `increase(vId, qty)` | `doCancel(Order, RefundInfo, StockChangeReason restoreReason)`; `cancel`→`CANCEL_RESTORE`, `cancelByExpiry`→`EXPIRY_RESTORE`; `increase(vId, qty, StockChangeContext.system(restoreReason))` |
| `payment/service/PaymentService.java:328` | `orderCancellation.cancelByExpiry(orderId)` | **변경 없음**(reason은 `cancelByExpiry` 내부 결정; PaymentService는 inventory 포트 미사용) |

> 동시성 규약 유지: 조정도 `findByIdForUpdate` PESSIMISTIC_WRITE, 다건은 variantId 오름차순(조정 API는 단건이라 자연 충족). decrease/increase의 기존 오름차순 호출 규약 불변.

---

## 9. 미해결/확인 필요 사항
- **조정 응답 코드(200 vs 201)**: 기존 `SellerProductVariantRestController.createVariant`가 200을 쓰므로 일관성 위해 200 채택. 201 선호 시 implementor 단계에서 통일(영향 미미).
- **ledger 응답 형태(Page vs List)**: Page 채택(누적 증가 대비). 프런트 요구가 단순 최근 N건이면 size 기본값으로 흡수 가능.
- 위 둘은 설계 차단 요소 아님 — 구현 시 확정.

## 완료 조건
- [ ] V8 마이그레이션 + `StockLedgerEntry`/`StockChangeReason`/`StockLedgerRepository` 신설, `SchemaMappingValidationTest` GREEN(RED 1회 경험)
- [ ] `InventoryStockPort` 확장(decrease/increase context, adjustStock, getLedger) + `InventoryStockPortImpl` 원장 atomically 적재(increase skip=미기록)
- [ ] 호출부 3곳 reason 전달(동작 회귀 0)
- [ ] product `StockAdjustmentService`/ServiceResponse/Controller/DTO 신설(소유권·소속·memo·음수 검증)
- [ ] 통합/단위/동시성/권한 매트릭스/schema-mapping 테스트 GREEN, `ModularityTests` GREEN, 전체 `./gradlew test` 통과

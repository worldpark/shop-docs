# 019. shop-core 주문 이행 — Shipment 모델 도입 + 배송 생성(preparing) — 구현 계획(plan, with View)

> Task SSOT: `docs/tasks/backend/019-backend-shop-core-order-shipment-model-and-creation-with-view.md` — **설계 모순 4건이 수정 반영된 최신본.** 본 plan은 그 결정(모순1~4)을 그대로 따른다.
> Revision SSOT: `docs/plans/revisions/backend/019-backend-shop-core-order-shipment-model-and-creation-revision-1.md` — 모순1(V4 트리거 생성), 모순2(거부 직접 throw·Outcome 미채택), 모순3(400/409 분리), 정합4(소비자 표시 020 이연). plan은 이 결정을 변형 없이 반영한다.
> 선행 Task(구현 완료 전제): 015(주문 생성·`order_items`)·016(결제 승인 → `pending→paid`·`OrderConfirmation`·주문 row 비관락 패턴)·018(취소/환불/재고복원·취소 가드·`Order` 의도 메서드·`OrderCancellationImpl` 락 패턴). 016/018 경로는 **본 Task에서 변경하지 않는다**(rollup 분기만 추가).
> 선례 plan(구조·톤·레이어·테스트 패턴 기준): `docs/plans/backend/016-...-plan.md`, `docs/plans/backend/018-...-plan.md`(`OrderCancellationImpl` 락·가드·404 재검증 패턴 — 본 Task의 `OrderFulfillmentService`가 이를 대칭으로 따른다).
> 이벤트 계약: **본 Task는 이벤트를 발행하지 않는다.** `ShippingStartedEvent`는 020 소관. event-catalog/architecture §5 무변경.
> 영역: backend(V4 마이그레이션 + Shipment/ShipmentItem 엔티티 + 리포지토리 + 이행 서비스 + REST 컨트롤러/DTO + admin facade + SecurityConfig + 백엔드/통합/동시성 테스트) + view(`templates/admin/orders.html` + `AdminOrderViewController` 뷰 바인딩 + View 렌더링 테스트)
> 대상 프로젝트: shop-core (Spring Modulith 모듈러 모놀리스)
> 작성일: 2026-06-11
> 상태: plan only (코드 변경 없음 — 구현은 backend-implementor / view-implementor가 수행)
> 담당: backend-implementor(V4·엔티티·리포지토리·서비스·REST·DTO·admin facade·SecurityConfig·백엔드/통합/동시성/구조 테스트) → view-implementor(`templates/admin/orders.html` + `AdminOrderViewController` 뷰 바인딩 + View 렌더링 테스트)
> 진행: backend-implementor → view-implementor → reviewer → fixer 사이클(최대 3회)
> 범위 한정(엄수): 본 Task는 **배송 시작(`shipping`)·완료(`delivered`)·`ShippingStartedEvent`·소비자 배송목록 블록을 구현하지 않는다**(020/021). `Shipment`는 `preparing` 생성까지만, `Order` rollup은 `paid→preparing`까지만. 이후 단계 이음매(seller_id nullable, status CHECK 세 값)는 스키마/주석으로만 둔다.

---

## 0. 작업 구분 요약 (백엔드 vs 화면)

### 0.1 담당 분담표

| 구분 | 항목 | 담당 |
|---|---|---|
| 백엔드 | `V4__shipments.sql` — `shipments`/`shipment_items` 테이블 + `idx_shipment_items_shipment_id` + **`trg_shipments_set_updated_at` BEFORE UPDATE 트리거**(기존 `set_updated_at()` 재사용, 모순1) | backend-implementor |
| 백엔드 | `order/domain/Shipment`(정적 팩토리 `preparing` 생성, `BaseEntity` 상속)·`order/domain/ShipmentItem`(scalar `orderItemId` + `shipmentId` 매핑) | backend-implementor |
| 백엔드 | `order/domain/Order.markPreparing()`(`paid→preparing` rollup) | backend-implementor |
| 백엔드 | `order/repository/ShipmentRepository`(주문별 배송 조회 + 이미 배정된 `order_item_id` 조회) | backend-implementor |
| 백엔드 | `order/service/OrderFulfillmentService.createShipment(orderId, orderItemIds?)` — 주문 row 비관락 + 상태/항목 검증 + Shipment/ShipmentItem 생성 + rollup + **거부 직접 throw**(모순2) | backend-implementor |
| 백엔드 | `common/exception/OrderFulfillmentConflictException`(409, 신규) | backend-implementor |
| 백엔드 | `order/controller/AdminOrderFulfillmentRestController`(`POST`/`GET /api/v1/admin/orders/{orderId}/shipments`) + `order/dto/CreateShipmentRequest`·`ShipmentResponse`(+ `ShipmentItemResponse`) | backend-implementor |
| 백엔드 | `order/spi/AdminOrderFulfillmentFacade`(View용 published port) + `order/service/AdminOrderFulfillmentFacadeImpl`(이행 대상 주문 목록·배송 생성 위임) | backend-implementor |
| 백엔드 | `security/SecurityConfig` — `/api/v1/admin/orders/*/shipments`·`/admin/orders/**` 권한 확인/명시 | backend-implementor |
| 백엔드 | 단위·Mockito·통합(Testcontainers+Modulith)·동시성·REST/Security·구조 테스트 | backend-implementor |
| 화면 | `templates/admin/orders.html` — 이행 대상 주문 목록 + 미발송 항목 + 배송 생성 폼(CSRF) + 배송 현황 표시 | view-implementor |
| 화면 | `web/order/AdminOrderViewController`(`GET /admin/orders` + `POST /admin/orders/{orderId}/shipments`) — facade 위임·뷰 바인딩·flash | view-implementor |
| 화면 | View 렌더링 테스트(폼 노출/CSRF/성공 flashSuccess/불가 flashError/비ADMIN) | view-implementor |

> 호출 순서: **백엔드 → 화면.** `AdminOrderFulfillmentFacade` 시그니처·`ShipmentResponse`/이행 대상 목록 DTO·`OrderFulfillmentConflictException`(409) 계약이 먼저 고정되어야 View가 폼 노출 조건·flashError 경로를 안정적으로 검증한다.
> **소비자 측 무변경(정합4)**: 소비자 `OrderFacade`/`OrderResponse`/`OrderDtoMapper`/`templates/order/detail.html`·`list.html`은 **019에서 손대지 않는다.** 소비자 화면은 기존 rollup `order.status`(=`상품 준비 중`) 라벨만 노출한다. 배송 목록 블록·`OrderResponse.shipments`는 추적정보가 등장하는 **020에서 신설**한다. 이 분담표·아래 모든 섹션에 소비자 측 작업 항목은 존재하지 않는다.

### 0.2 양 영역 인터페이스 접점 (어긋남 방지)

| 항목 | 값 (계약) |
|---|---|
| View facade 시그니처 | `AdminOrderFulfillmentFacade.listFulfillableOrders(Pageable) → Page<AdminOrderFulfillmentView>`(이행 대상 주문 + 미발송 항목 + 기존 배송 현황), `createShipment(long orderId, List<Long> orderItemIds) → ShipmentResponse`(성공) / 거부 시 `BusinessException`(400/409) throw |
| View 생성 핸들러 | `AdminOrderViewController.createShipment`(`POST /admin/orders/{orderId}/shipments`) — `try { facade.createShipment(orderId, ids) → flashSuccess } catch (BusinessException e) { flashError(e.getMessage()) } return "redirect:/admin/orders"`(AdminMemberViewController.changeRole 패턴 재사용) |
| 폼 노출 조건 | `order.status`가 `paid`/`preparing`이고 **미발송 항목이 1건 이상**일 때만 배송 생성 폼 노출. 종결/이행중(미발송 0건)·`pending`은 폼 미노출 |
| REST 생성 응답 | 성공 `201` + `ShipmentResponse`(shipmentId·orderId·status(`preparing`)·item 목록). 입력 오류 `400`·상태 충돌 `409`·미존재 주문 `404` + `ErrorResponse`. 비인증 `401`·비ADMIN `403` |
| 모델 키(View) | `orders`(`Page<AdminOrderFulfillmentView>`, DTO — Entity 금지) / `flashSuccess`·`flashError`. View name `admin/orders`, redirect `redirect:/admin/orders` |

---

## 1. 설계 방식 및 이유

### 1.0 사전 확정 사실 (실제 shop-core 코드 점검 완료 — 가정 아님)

아래는 실제 소스 점검 결과이며 plan의 모든 경로/시그니처가 이에 근거한다.

- **마이그레이션 번호**: `db/migration`에 `V1__init_schema.sql`·`V2__users_role_hierarchy.sql`·`V3__product_status_and_owner.sql`만 존재 → **다음 번호는 `V4`.**
- **`set_updated_at()` 함수 + 트리거 패턴(V1, line 33~39)**: V1이 `CREATE OR REPLACE FUNCTION set_updated_at() ... NEW.updated_at = now()`(plpgsql)를 정의하고, 테이블마다 `CREATE TRIGGER trg_{table}_set_updated_at BEFORE UPDATE ON {table} FOR EACH ROW EXECUTE FUNCTION set_updated_at()`(users/products/carts/orders/payments/reviews)를 건다. → **V4는 이 기존 함수를 재사용**해 `shipments`에 트리거만 추가한다(함수 재정의 불필요 — 모순1).
- **`orders` 스키마(V1, line 242~273)**: `status varchar(20) CHECK (status IN ('pending','paid','preparing','shipping','delivered','cancelled','refunded'))` — `preparing` 이미 허용. `created_at`/`updated_at timestamptz NOT NULL DEFAULT now()` + `trg_orders_set_updated_at`. → 주문 status는 rollup으로만 전이, **새 상태값·새 컬럼 추가 0건.**
- **`order_items` 스키마(V1, line 278~294)**: `id`·`order_id`(FK `orders` ON DELETE CASCADE, NOT NULL)·`variant_id`(FK ON DELETE SET NULL, nullable)·`product_name`·`unit_price`·`quantity`·`line_amount`. `idx_order_items_order_id`. **`order_items`는 `updated_at` 컬럼 없음**(불변 스냅샷). → `shipment_items.order_item_id`는 `order_items(id)`를 참조.
- **`BaseEntity`(`common/domain/BaseEntity.java`)**: `created_at`/`updated_at`을 `insertable=false, updatable=false`로 매핑(JPA 읽기전용, DB가 소유). → `Shipment`가 `BaseEntity`를 상속하면 JPA가 `updated_at`을 절대 쓰지 않으므로 **트리거 없이는 020/021 UPDATE에서 `updated_at`이 영원히 stale**(모순1의 실버그) → V4 트리거 필수.
- **`Order`(`order/domain/Order.java`)**: `@OneToMany(mappedBy="order", cascade=ALL, orphanRemoval=true) List<OrderItem> items`. 의도 메서드 `markPaid()`(pending→paid)·`markCancelled()`(pending→cancelled)·`markRefunded()`(paid→refunded). **Setter 없음.** → **`markPreparing()`(paid→preparing)** 의도 메서드를 같은 패턴(상태 가드 + `IllegalStateException`)으로 추가. `order.getItems()`로 미발송 판정.
- **`OrderItem`(`order/domain/OrderItem.java`)**: `id`·`@ManyToOne Order order`·`variantId`(nullable)·`productName`·`quantity` 등. **`updated_at` 없어 `BaseEntity` 미상속.** `getId()`/`getProductName()`/`getQuantity()`/`getVariantId()` 제공.
- **`OrderRepository`(`order/repository/OrderRepository.java`)**: `findByIdForUpdate(long id)` → `Optional<Order>`, `@Lock(PESSIMISTIC_WRITE)` + `@Query("select o from Order o where o.id = :id")`(items fetch 없음). `findByUserIdOrderByCreatedAtDescIdDesc`·`findByIdAndUserId` 등. → 이행 서비스가 `findByIdForUpdate`로 주문 row를 잠그고 같은 영속성 컨텍스트에서 `order.getItems()` lazy 접근(`OrderCancellationImpl`가 같은 방식).
- **`OrderCancellationImpl`(`order/service/OrderCancellationImpl.java`, package-private, `@Service @Transactional`)**: `findByIdForUpdate` 잠금 → 소유권/상태 분기 → 종결 전이 → 재고 복원. **본 Task의 `OrderFulfillmentService`가 이 락·가드 구조를 대칭으로 따른다**(단 소유권 검사는 관리자 경로라 불요 — 1.4 참조). 018 취소 가드: `preparing`/`shipping`/`delivered`는 취소 409 → rollup `paid→preparing`이 이 가드와 정합(1.5).
- **`OrderServiceResponse`(`order/service`, public)**: `(long) authentication.getPrincipal()` → `OrderService` 위임 → `OrderDtoMapper`로 DTO 변환. **본 Task admin REST는 별도 `AdminOrderFulfillmentRestController` → `OrderFulfillmentService`** 경로(소비자 `OrderServiceResponse` 무변경).
- **admin 선례(`web/member/AdminMemberViewController` + `member/spi/AdminMemberFacade` + `member/service/AdminMemberFacadeImpl` + `member/controller/AdminMemberRestController`)**: ViewController(`@Controller`, `/admin/members`)는 **published facade(`spi`)만 의존**, facade 구현은 도메인 내부 `service`에 배치, REST(`/api/v1/admin/members`)는 ServiceResponse 위임. `try { facade.x() → flashSuccess } catch (BusinessException e) { flashError }` PRG 패턴. → **본 Task가 `order` 모듈에 그대로 복제**(`web/order/AdminOrderViewController` + `order/spi/AdminOrderFulfillmentFacade` + `order/service/AdminOrderFulfillmentFacadeImpl`).
- **`SecurityConfig`(`security/SecurityConfig.java`)**: REST 체인에 `.requestMatchers("/api/v1/admin/**").hasRole("ADMIN")`(line 78, `anyRequest` 앞)·View 체인에 `.requestMatchers("/admin/**").hasRole("ADMIN")`(line 126). → **admin 배송 경로는 기존 `/admin/**`·`/api/v1/admin/**` 규칙에 이미 포함**. 016/018 선례대로 의도 명시 전용 matcher를 추가할 수 있으나(회귀 방지), 기존 규칙으로 충분하므로 **명시 라인 추가는 선택**(구현 시 confirm 후 결정 — 본 plan은 "확인 후 필요 시 명시"로 둔다).
- **`OrderCancellationConflictException`(`common/exception`)**: `extends BusinessException`, `super(message, HttpStatus.CONFLICT)`(409). → **본 Task `OrderFulfillmentConflictException`을 동형으로 신규 추가**(409, 의미 분리). 입력 오류 400은 기존 예외(예: `IllegalArgumentException` 매핑 또는 신규 입력 예외) — 4절에서 확정.
- **테스트 프로파일 제약(016/018과 동일)**: `src/test/resources/application.yml`이 DataSource/JPA/Flyway 자동설정 제외 → 통합/동시성은 016/018의 Testcontainers 별도 프로파일(`@AutoConfigureTestDatabase(NONE)` + `@Testcontainers`(postgres:16.4-alpine + `@ServiceConnection`) + `@TestPropertySource`(`spring.autoconfigure.exclude=` 리셋 + `spring.flyway.enabled=true` + `ddl-auto=validate`)) 패턴을 **그대로 재사용**. 본 Task는 이벤트 미발행이므로 Outbox 검증 대신 **`event_publication` 무변화**를 확인한다.

### 1.1 Order 1:N Shipment 모델 — 배송을 별도 애그리거트로 (이유)

핵심 설계는 "주문 이행을 **배송(Shipment) 단위**로 모델링한다"이다.

- 한 주문은 여러 판매자/부분 배송으로 나뉠 수 있으므로 추적정보(`carrier`/`tracking_number`/`shipped_at`/`delivered_at`)와 상태(`preparing→shipping→delivered`)를 **주문이 아니라 배송이 소유**해야 한다. `orders`에 주문단위 배송 컬럼을 두면 부분 배송·멀티셀러를 표현할 수 없다.
- 따라서 `Order 1:N Shipment`, `Shipment 1:N ShipmentItem`(각 `order_item`은 최대 1개 배송에 속함 — `shipment_items.order_item_id` UNIQUE). 미발송 항목은 `order.getItems()` − 이미 배정된 `shipment_items`로 판정한다.
- **`orders.status`는 rollup 결과로만 전이**한다. 새 상태값을 추가하지 않고(`preparing` 이미 CHECK 포함), 본 Task는 `paid→preparing`만 발생시킨다. 주문 status는 "이 주문에 배송이 시작되었는가"의 요약값이고 권위는 `shipments`에 있다.

### 1.2 이행 오케스트레이션을 order 모듈이 소유 (순환 방지·외부계 없음)

- `docs/architecture.md` §5: "배송은 별도 모듈이 아니라 order 모듈의 책임이다." → `Shipment`/`ShipmentItem` 엔티티·`ShipmentRepository`·`OrderFulfillmentService`·`AdminOrderFulfillmentRestController`·admin facade를 **모두 `order` 모듈**에 둔다.
- 018 취소는 `payment → order.spi`(cross-module)였지만, **배송 생성은 외부계가 전혀 없다**: 결제(`payment`)·재고(`inventory`)·PG를 호출하지 않는다(배송 생성은 재고를 건드리지 않음 — 재고는 015 차감/018 복원 소관). `OrderFulfillmentService`는 `OrderRepository`·`ShipmentRepository`만 의존하므로 **새 cross-module 의존이 0건**이고 순환 위험도 0이다.
- REST(`order/controller`)·admin facade(`order/spi`)·View(`web/order`)가 모두 order 모듈(또는 `web → order.spi` 단방향)이라 `ModularityTests`가 그대로 그린이다.

### 1.3 rollup(paid→preparing) 방식 — 첫 배송 생성 시 1회

- **첫 배송 생성**: 주문이 `paid`면 `Order.markPreparing()`으로 `paid→preparing` 전이(rollup). 이 시점에 주문은 "이행이 시작됨"을 status로 요약한다.
- **추가 배송 생성**: 주문이 이미 `preparing`이면 status를 **변경하지 않는다**(rollup 멱등). 남은 미발송 항목으로 두 번째 배송을 만들어도 주문은 `preparing` 유지.
- rollup은 `paid`→`preparing` 한 방향만(본 Task). `preparing→shipping`(전체 배송이 shipping일 때)·`→delivered`는 020/021의 rollup이며 **본 Task는 구현하지 않는다**(이음매로만 인지).

### 1.4 관리자 단일 주체 (소유권 검사 불요 — 이유)

- 판매자↔주문/배송 소유권 매핑이 없고(주문 multi-seller 가능, `Product.ownerId`만 존재), 판매자 가입·권한(backlog 002) 미구현 → 이행 전이 주체를 **`ROLE_ADMIN` 단일**로 한정한다. 관리자는 모든 주문에 권한이 있으므로 `OrderFulfillmentService`는 **소유권 검사를 수행하지 않는다**(018 소비자 취소가 `userId` 일치를 검사한 것과 대비). 미존재 주문은 평범하게 404(은닉 불요 — 관리자 경로).
- `shipments.seller_id`는 backlog 002에서 판매자 범위 이행을 켜기 위한 **nullable 이음매**로만 두고 본 Task에서 채우거나 강제하지 않는다(`product.spi`에 ownerId 해석을 추가하지 않음 — 새 의존 0).

### 1.5 018 취소 가드와의 정합 (명시)

- 첫 배송 생성으로 주문이 `preparing`이 되면 `OrderCancellationImpl`의 가드(`preparing`/`shipping`/`delivered`→취소 409)가 취소를 차단한다 → **이행 시작 후 취소 불가**가 자동 성립.
- 배송 전(`paid`, 배송 0건)에는 018 취소(환불)가 여전히 가능하다.
- 두 흐름(배송 생성 vs 취소)은 **같은 주문 row PESSIMISTIC_WRITE 락**으로 직렬화된다(둘 다 `findByIdForUpdate`). 한쪽이 커밋한 뒤 다른 쪽이 권위 상태를 본다 → 모순 없음(3.5).

### 1.6 거부 = 직접 throw, Outcome 미채택 (모순2 — 이유)

- 018이 `OrderCancellation`에 `Outcome` 값 패턴을 둔 이유는 **payment(소비 모듈)가 `order.spi`를 호출하는 cross-module 경계**에서 예외 대신 값으로 결과를 넘겨 호출자가 매핑하기 위함이었다.
- `OrderFulfillmentService`는 **order 모듈 내부**에서 order 자신의 REST(`ServiceResponse` 미경유 — admin REST가 직접 위임)·View facade가 직접 호출하며, **분리 예정도 없다** → cross-module 값 매핑의 이유가 없다. 따라서 **거부(잘못된 주문 상태/항목)는 도메인 예외(`OrderFulfillmentConflictException` 409 / 입력 오류 400)를 서비스에서 직접 throw**한다.
- 거부는 **부작용 발생 전에 판정**한다(Shipment/ShipmentItem INSERT·rollup 전에 상태/항목을 검증) → 트랜잭션 롤백할 부작용이 없어 트랜잭션 안에서 던져도 안전. 성공은 `ShipmentResponse`(Entity 미노출 scalar record)를 반환하고 한 트랜잭션 원자 커밋한다. **`Outcome` enum을 도입하지 않는다.**
- (018과 달리 "멱등 200" 분기도 본 Task엔 없다 — 배송 생성은 "이미 목표 상태" 개념이 없고, 이미 배정된 항목 지정은 멱등이 아니라 409 충돌이다. 020/021의 멱등 200은 그 task 소관.)

---

## 2. 구성 요소 (서비스, 클래스, 파일 — 정확한 패키지 경로)

> 2.1 = backend-implementor, 2.2 = view-implementor. (B)=backend, (V)=view. 모든 경로는 `shop-core/src/main/java/com/shop/shop/` 기준.

### 2.1 backend-implementor 담당 범위

#### (B) 신규 — 마이그레이션 (모순1: 트리거 포함)
- `shop-core/src/main/resources/db/migration/V4__shipments.sql`(신규) — **추가만**(기존 migration 무변경):
  ```sql
  CREATE TABLE shipments (
      id              bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      order_id        bigint       NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
      seller_id       bigint,                         -- nullable 이음매(backlog 002, 본 Task 미사용)
      status          varchar(20)  NOT NULL
                      CHECK (status IN ('preparing', 'shipping', 'delivered')),  -- 세 값 모두 포함(020/021 재변경 불필요)
      carrier         text,                           -- nullable(020에서 사용)
      tracking_number text,                           -- nullable(020에서 사용)
      shipped_at      timestamptz,                    -- nullable(020에서 사용)
      delivered_at    timestamptz,                    -- nullable(021에서 사용)
      created_at      timestamptz  NOT NULL DEFAULT now(),
      updated_at      timestamptz  NOT NULL DEFAULT now()
  );
  CREATE INDEX idx_shipments_order_id ON shipments (order_id);

  -- updated_at 자동 갱신(모순1, 필수): BaseEntity가 updatable=false로 매핑하므로 트리거 없으면 020/021 UPDATE에서 stale
  CREATE TRIGGER trg_shipments_set_updated_at
      BEFORE UPDATE ON shipments
      FOR EACH ROW EXECUTE FUNCTION set_updated_at();   -- V1 기존 함수 재사용

  CREATE TABLE shipment_items (
      id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      shipment_id   bigint NOT NULL REFERENCES shipments (id) ON DELETE CASCADE,
      order_item_id bigint NOT NULL REFERENCES order_items (id) ON DELETE CASCADE,
      created_at    timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT uq_shipment_items_order_item UNIQUE (order_item_id)   -- 한 주문항목은 최대 1개 배송
  );
  CREATE INDEX idx_shipment_items_shipment_id ON shipment_items (shipment_id);
  ```
  - `shipment_items`는 `updated_at` 없음(불변·append) → 트리거 불필요(모순1). `order_item_id` UNIQUE가 동시 createShipment의 항목 이중 배정을 DB 레벨에서 차단(3.4).
  - `ON DELETE CASCADE`(order 삭제 시 정합) — 단 015~019 범위에 order 삭제는 없음(방어).

#### (B) 신규 — 도메인 (Setter 금지·의도 메서드)
- `order/domain/Shipment.java`(신규) — `@Entity @Table(name="shipments")`, `BaseEntity` 상속, `@Getter @NoArgsConstructor(PROTECTED)`(Order 선례).
  - 필드: `Long id`, `Long orderId`(scalar — `@Column(name="order_id")`. 같은 모듈이라 `@ManyToOne Order` 연관 매핑도 허용되나, 미발송 판정·응답은 scalar로 충분하고 Order↔Shipment 양방향을 만들 필요가 없으므로 **`orderId` scalar 채택**), `Long sellerId`(nullable 이음매), `String status`, `String carrier`/`trackingNumber`(생성 시 null), `Instant shippedAt`/`deliveredAt`(생성 시 null), `@OneToMany(mappedBy="shipment", cascade=ALL) List<ShipmentItem> items`.
  - 정적 팩토리 `static Shipment preparing(long orderId)` (또는 `create(orderId, sellerId)`) — `status="preparing"`, 추적필드 null. `addItem(ShipmentItem)` 의도 메서드(양방향 연관 세팅).
  - **`markShipping`/`markDelivered`는 정의하지 않는다**(020/021 — 본 Task 범위 밖). javadoc에 "본 Task는 preparing 생성만, shipping/delivered 전이는 020/021" 명시.
- `order/domain/ShipmentItem.java`(신규) — `@Entity @Table(name="shipment_items")`, `@Getter @NoArgsConstructor(PROTECTED)`. **`updated_at` 없으므로 `BaseEntity` 미상속**(OrderItem 선례).
  - 필드: `Long id`, `@ManyToOne(LAZY) @JoinColumn(name="shipment_id") Shipment shipment`(양방향), `Long orderItemId`(scalar `@Column(name="order_item_id")`). 정적 팩토리 `static ShipmentItem of(long orderItemId)`, `assignShipment(Shipment)`(package-private, Shipment.addItem에서 호출).

#### (B) 수정 — 도메인 (rollup)
- `order/domain/Order.java`(수정) — 의도 메서드 추가:
  - `markPreparing()`: `paid`→`preparing`. 이미 `preparing`→멱등 no-op(추가 배송 생성 시 status 불변). 그 외(`pending`/`shipping`/`delivered`/종결)→`IllegalStateException`(상위 `OrderFulfillmentService`가 이미 차단하므로 방어적). `markPaid`/`markCancelled` 선례와 동형. javadoc에 "rollup `paid→preparing`(첫 배송 생성). shipping/delivered rollup은 020/021" 명시. **기존 메서드 무변경.**

#### (B) 신규 — 리포지토리
- `order/repository/ShipmentRepository.java`(신규) — `extends JpaRepository<Shipment, Long>`:
  - `List<Shipment> findByOrderId(long orderId)` — 주문별 배송 목록(REST GET·admin 현황).
  - 이미 배정된 `order_item_id` 조회: `@Query("select si.orderItemId from ShipmentItem si where si.shipment.orderId = :orderId") List<Long> findAssignedOrderItemIds(long orderId)`(또는 `ShipmentItemRepository` 별도 신설 — 구현 시 단일 리포지토리로 통합 권장). 미발송 판정에 사용.
  - (이행 대상 주문 목록은 `OrderRepository`로 `paid`/`preparing` 주문 페이지 조회 — admin facade 2.1 참조. 신규 메서드 필요 시 `OrderRepository`에 `Page<Order> findByStatusIn(Collection<String> statuses, Pageable)` 추가.)

#### (B) 신규 — 이행 서비스 (핵심)
- `order/service/OrderFulfillmentService.java`(신규, **`public` 클래스 확정**(모순①) — `AdminOrderFulfillmentRestController`(`order/controller`)와 `AdminOrderFulfillmentFacadeImpl`(`order/service`)가 **다른 패키지에서 직접 호출**하므로 package-private이면 컨트롤러가 접근 불가. `OrderServiceResponse`(public)가 REST-facing인 선례와 동일. admin 엔드포인트는 `Authentication` principal-id가 불필요(관리자 전역)하므로 016/018의 `OrderServiceResponse` 별도 래퍼는 두지 않고 **이 public 서비스를 REST/facade가 공통 호출**한다), `@Service @Transactional @RequiredArgsConstructor`:
  - 의존: `OrderRepository`·`ShipmentRepository`. (외부계·이벤트·재고 의존 0 — 1.2)
  - 쓰기 메서드 `ShipmentCreationResult createShipment(long orderId, List<Long> orderItemIds)`:
    1. **주문 row `findByIdForUpdate(orderId)` PESSIMISTIC_WRITE 잠금** → empty면 `OrderNotFoundException`(404). (동시 배송 생성·018 취소와 직렬화 — 1.5)
    2. **상태 검증**: `order.getStatus()`가 `paid` 또는 `preparing`이 아니면(`pending`/`shipping`/`delivered`/`cancelled`/`refunded`) → `OrderFulfillmentConflictException`(409). **부작용 전 throw**(모순2).
    3. **대상 항목 결정**: `assigned = shipmentRepository.findAssignedOrderItemIds(orderId)`. `unassigned = order.getItems()` 중 id가 `assigned`에 없는 항목.
       - `orderItemIds`가 **지정됨**: 각 id가 (a) `order.getItems()`에 존재하지 않거나 해당 주문 소속이 아니면 → **`400`**(입력 오류, 모순3). (b) 이미 `assigned`에 있으면 → **`409`**(상태 충돌, 모순3). 검증 통과한 항목만 대상.
       - `orderItemIds`가 **생략(null/empty)**: 대상 = `unassigned` 전부.
       - **대상이 0건**(미발송 항목 없음 / 지정 항목이 전부 이미 배정) → **`409`**(상태 충돌, 만들 배송 없음, 모순3).
    4. **`Shipment.preparing(orderId)` 생성 + 각 대상에 `ShipmentItem.of(orderItemId)` 추가** → `shipmentRepository.save`.
    5. **rollup**: `order.getStatus()`가 `paid`면 `order.markPreparing()`(첫 배송, dirty checking). 이미 `preparing`이면 호출 생략(status 불변).
    6. **커밋** → `ShipmentCreationResult`(내부 record: shipmentId·orderId·status·items[(orderItemId·productName·quantity)]) 반환.
  - **동시성**: 동시 createShipment로 같은 항목이 두 배송에 들어가는 것을 (a) 주문 row 락(같은 주문 동시 요청 직렬화) + (b) `shipment_items.order_item_id` UNIQUE(DB 최후 방어)로 보장. 락 통과 후 UNIQUE 위반이 발생하면 `DataIntegrityViolationException` → **409로 매핑**(3.4).
  - 읽기 메서드 `List<ShipmentResponse> getShipments(long orderId)`(모순②) — `shipmentRepository.findByOrderId` + `ShipmentResponse` 변환을 **서비스가 수행**한다. 컨트롤러가 Repository를 직접 보지 않도록(레이어 일관 — REST/facade가 이 메서드를 호출). 미존재 주문이어도 빈 목록 반환(404는 생성 경로에서만).
  - 내부 record `ShipmentCreationResult` + `ShipmentItemResult` (createShipment의 DTO 변환은 admin REST/facade에서 `ShipmentResponse`로).

#### (B) 신규 — 예외
- `common/exception/OrderFulfillmentConflictException.java`(신규) — `extends BusinessException`, `super(message, HttpStatus.CONFLICT)`(409). `OrderCancellationConflictException` 동형. javadoc: "주문이 `paid`/`preparing`이 아님 / 미발송 항목 0건 / 이미 배정된 항목 지정 — 부작용(Shipment INSERT·rollup) 전 판정해 던진다(모순2). 롤백할 부작용 없음." 입력 오류(400)는 4절에서 확정한 예외 사용.

#### (B) 신규 — REST 컨트롤러 + DTO
- `order/controller/AdminOrderFulfillmentRestController.java`(신규) — `@RestController @RequestMapping("/api/v1/admin/orders/{orderId}/shipments") @RequiredArgsConstructor`. (AdminMemberRestController 선례 — 비즈니스 로직 없음·서비스 위임만):
  - `@PostMapping`: `create(@PathVariable long orderId, @Valid @RequestBody(required=false) CreateShipmentRequest req) → ResponseEntity<ShipmentResponse>(201)` — `orderFulfillmentService.createShipment(orderId, req?.orderItemIds())` → DTO 변환 → `201 Created`.
  - `@GetMapping`: `list(@PathVariable long orderId) → ResponseEntity<List<ShipmentResponse>>(200)` — `orderFulfillmentService.getShipments(orderId)`(모순② — 서비스 읽기 메서드, 컨트롤러는 Repository 직접 접근 금지) → 200.
  - order 모듈(순환 없음). admin이라 소유권 검사 불요(1.4). **컨트롤러는 `OrderFulfillmentService`(public)만 의존**(Repository 직접 주입 금지).
- `order/dto/CreateShipmentRequest.java`(신규) — `record CreateShipmentRequest(List<Long> orderItemIds)`(생략/빈 목록 = 미발송 전부, 4절 참조 — `null`/`[]` 모두 "전부"로 처리).
- `order/dto/ShipmentResponse.java`(신규) — `record ShipmentResponse(long shipmentId, long orderId, String status, List<ShipmentItemResponse> items)`. status lowercase(`preparing`). Entity·ownerId·로컬경로 미포함.
- `order/dto/ShipmentItemResponse.java`(신규) — `record ShipmentItemResponse(long orderItemId, String productName, int quantity)`.

#### (B) 신규 — admin facade (View용 published port + 구현)
- `order/spi/AdminOrderFulfillmentFacade.java`(신규, published port — `package-info.java` `@NamedInterface` 확인/추가):
  - `Page<AdminOrderFulfillmentView> listFulfillableOrders(Pageable pageable)` — `paid`/`preparing` 주문 + 각 주문의 미발송 항목 + 기존 배송 현황(scalar DTO). View 목록·폼 렌더용.
  - `ShipmentResponse createShipment(long orderId, List<Long> orderItemIds)` — 배송 생성 위임. 성공 시 `ShipmentResponse`, 거부 시 `BusinessException`(400/409) 전파.
  - `record AdminOrderFulfillmentView(long orderId, String orderNumber, String status, List<UnshippedItem> unshippedItems, List<ShipmentResponse> shipments)` + `record UnshippedItem(long orderItemId, String productName, int quantity)` — Entity 미노출. (DTO는 `order/dto`에 두거나 facade 내부 record로 — 구현 시 `order/dto` 권장.)
- `order/service/AdminOrderFulfillmentFacadeImpl.java`(신규, package-private, `@Service @RequiredArgsConstructor`) — `AdminMemberFacadeImpl` 선례. `OrderRepository`(이행 대상 목록)·`ShipmentRepository`·`OrderFulfillmentService` 위임 + DTO 변환. 미발송 항목 = `order.getItems()` − 배정된 order_item_id.
- **REST는 facade 미경유**(admin REST → `OrderFulfillmentService`(public) 직접 호출 — 모순① 반영, 별도 ServiceResponse 래퍼 없음) / **View는 facade 경유**(web → order.spi 단방향). REST·View 둘 다 **동일한 public `OrderFulfillmentService`**를 호출해 로직 단일화(SSOT).

#### (B) 수정 — security
- `security/SecurityConfig.java` — `/api/v1/admin/**`(line 78)·`/admin/**`(line 126)가 이미 `hasRole("ADMIN")`로 배송 경로를 덮는다(1.0 확인). **016/018 선례대로 의도 명시 전용 matcher**(`/api/v1/admin/orders/*/shipments`·`/admin/orders/**`)를 `anyRequest`/광역 admin 라인 인접에 추가할 수 있다(회귀 방지·의도 명시). 본 plan은 "기존 규칙으로 충분 — 구현 시 확인 후 필요하면 명시 라인만 추가, 매칭 순서·기존 라인 무변경"으로 둔다.

#### (B) 무변경(확인만)
- 소비자 `OrderFacade`/`OrderFacadeImpl`/`OrderResponse`/`OrderDtoMapper`/`OrderServiceResponse`/`OrderRestController` — **019에서 손대지 않는다(정합4)**. `OrderConfirmationImpl`(016)·`OrderCancellationImpl`(018) 무변경. `RestExceptionHandler`/`ViewExceptionHandler` — `BusinessException`(400/404/409) 기존 매핑 재사용, 신규 핸들러 불필요. `inventory.spi`·`payment.spi` 미참조(배송 생성은 재고/결제 무관). 이벤트 발행 0(event-catalog/architecture §5 무변경).

#### (B) 신규 — 테스트 (5절 매핑)
- `order/domain/ShipmentTest`(신규) — `Shipment.preparing` 생성(status·추적필드 null), `ShipmentItem` 매핑.
- `order/domain/OrderTest`(보강) — `markPreparing` 허용(`paid`)·멱등(`preparing`)·금지(그 외).
- `order/service/OrderFulfillmentServiceTest`(신규, Mockito) — 대상 선택·rollup·400/409 분리·락 우선.
- `order/service/OrderFulfillmentIntegrationTest`(신규, Testcontainers+Modulith) — 저장·rollup·트리거·UNIQUE·이벤트 미발행.
- `order/service/OrderFulfillmentConcurrencyIntegrationTest`(신규, Testcontainers) — 동시 생성·취소 동시.
- `order/controller/AdminOrderFulfillmentRestControllerSecurityTest`(신규) — 201/400/409/404·ADMIN/401/403.
- 구조 테스트(`ModularityTests` 등 보강) — Shipment order 위치·이행 코드 payment/inventory 미의존.

### 2.2 view-implementor 담당 범위

#### (V) 신규 — web/order ViewController
- `web/order/AdminOrderViewController.java`(신규) — `@Controller @RequestMapping("/admin/orders") @RequiredArgsConstructor`. **`AdminOrderFulfillmentFacade`(spi)만 의존**(web → order.spi 단방향, AdminMemberViewController 선례). 도메인 내부 Service/Entity/Repository 직접 참조 금지.
  - `@GetMapping list(@PageableDefault Pageable, Model)` → `facade.listFulfillableOrders(pageable)` → `model.addAttribute("orders", ...)` → view name `"admin/orders"`.
  - `@PostMapping("/{orderId}/shipments") createShipment(@PathVariable long orderId, @RequestParam(required=false) List<Long> orderItemIds, RedirectAttributes ra)`:
    - `try { facade.createShipment(orderId, orderItemIds); ra.addFlashAttribute("flashSuccess", "배송이 생성되었습니다."); } catch (BusinessException e) { ra.addFlashAttribute("flashError", e.getMessage()); } return "redirect:/admin/orders";`(PRG, AdminMemberViewController.changeRole 패턴 복제).

#### (V) 신규 — templates/admin/orders.html
- `shop-core/src/main/resources/templates/admin/orders.html`(신규) — `templates/admin/members.html` 레이아웃/스타일 톤 재사용:
  - 이행 대상 주문 목록(`orders` = `Page<AdminOrderFulfillmentView>`): orderNumber·status·기존 배송 현황(배송별 status + 포함 항목).
  - **배송 생성 폼**: `order.status`가 `paid`/`preparing`이고 **미발송 항목(`unshippedItems`)이 1건 이상**일 때만 노출(`th:if`). `<form th:action="@{/admin/orders/{orderId}/shipments(orderId=${o.orderId})}" method="post">` + 미발송 항목 체크박스(`name="orderItemIds"`, 미선택 시 미발송 전부) + "배송 생성" 버튼. **CSRF 토큰 포함**(Thymeleaf `th:action` 자동 주입).
  - `flashSuccess`/`flashError` 표시 영역. 종결/`pending`/미발송 0건 주문은 폼 미노출.

#### (V) 신규 — 테스트 (5절 매핑)
- `view/AdminOrderViewRenderingTest`(신규, `@SpringBootTest`+MockMvc, `@MockitoBean AdminOrderFulfillmentFacade`): 목록 렌더·폼 노출(paid/preparing+미발송 존재)·미노출(미발송 0건/종결/pending)·CSRF·생성 성공 flashSuccess+`/admin/orders` redirect·불가(`OrderFulfillmentConflictException` 409) flashError+redirect·ADMIN 접근/비ADMIN 403/비인증 `/login`.

---

## 3. 데이터 흐름

### 3.1 배송 생성 — REST (POST /api/v1/admin/orders/{orderId}/shipments)
1. Security REST 체인 `/api/v1/admin/**` `hasRole("ADMIN")`. 비인증 401 JSON / 비ADMIN 403 JSON.
2. `AdminOrderFulfillmentRestController.create(orderId, CreateShipmentRequest)` → `OrderFulfillmentService.createShipment(orderId, req?.orderItemIds())`(`@Transactional`).
3. ① `orderRepository.findByIdForUpdate(orderId)` PESSIMISTIC_WRITE 잠금 → empty면 `OrderNotFoundException`(404).
4. ② 상태 검증: `paid`/`preparing`이 아니면 `OrderFulfillmentConflictException`(409, **부작용 전 throw**).
5. ③ 미발송 항목 판정: `assigned = ShipmentRepository.findAssignedOrderItemIds(orderId)`, `unassigned = order.getItems() − assigned`. 지정 id 검증(미존재/타 주문 → **400**, 이미 배정 → **409**). 대상 0건 → **409**.
6. ④ `Shipment.preparing(orderId)` + 대상별 `ShipmentItem.of(orderItemId)` 생성 → save.
7. ⑤ rollup: `paid`면 `order.markPreparing()`(→preparing). 이미 `preparing`이면 status 불변.
8. ⑥ 원자 커밋(shipments 1행 + shipment_items N행 + (첫 배송 시)orders.status=preparing). `ShipmentCreationResult` → `ShipmentResponse` → `201 Created`. **이벤트 발행 0**(event_publication 무변화).

### 3.2 배송 생성 — View (POST /admin/orders/{orderId}/shipments)
1. Security View 체인 `/admin/**` `hasRole("ADMIN")`. 비인증 302/login·비ADMIN 403.
2. `AdminOrderViewController.createShipment` → `AdminOrderFulfillmentFacade.createShipment(orderId, orderItemIds)`.
3. `AdminOrderFulfillmentFacadeImpl.createShipment` → `OrderFulfillmentService.createShipment`(3.1 ①~⑥ 도메인 로직, **커밋**) → `ShipmentResponse` 또는 거부 예외 전파.
4. 핸들러: 성공 → `flashSuccess("배송이 생성되었습니다.")` + `redirect:/admin/orders`. `catch (BusinessException e)`(400/409) → `flashError(e.getMessage())` + redirect(부작용 없음).

### 3.3 배송 현황 조회
- REST `GET /api/v1/admin/orders/{orderId}/shipments` → `ShipmentRepository.findByOrderId` → `List<ShipmentResponse>`(200).
- View `GET /admin/orders` → `AdminOrderFulfillmentFacade.listFulfillableOrders` → `paid`/`preparing` 주문 + 미발송 항목 + 배송 현황 → `templates/admin/orders.html`.

### 3.4 미발송 항목 판정 + 동시 생성 (항목 이중 배정 차단)
- 미발송 = `order.getItems()`의 각 id 중 `shipment_items`에 아직 없는 것(`ShipmentRepository.findAssignedOrderItemIds`로 배정 id 집합 조회 후 차집합).
- **동시 createShipment(같은 주문)**: 승자가 ① 주문 row 잠금 → 미발송 판정 → save → 커밋. 패자는 같은 주문 row 락 대기 → 승자 커밋 후 갱신된 `assigned`를 권위 관찰 → 같은 항목이면 대상 0건(409) 또는 이미 배정(409). DB 최후 방어: `shipment_items.order_item_id` UNIQUE — 락을 우회한 경합 시 `DataIntegrityViolationException` → 409로 매핑. **한 항목은 정확히 1개 배송에만.**

### 3.5 배송 생성 vs 018 취소 동시 (주문 row 락 직렬화 — 1.5)
- `createShipment`의 `findByIdForUpdate`와 018 `OrderCancellationImpl`의 `findByIdForUpdate`가 **같은 주문 row PESSIMISTIC_WRITE를 두고 직렬화.**
  - 취소 먼저 커밋(`paid→cancelled/refunded`) → 배송 생성이 `cancelled`/`refunded` 관찰 → ② 상태 검증 409(상태 불변).
  - 배송 생성 먼저 커밋(`paid→preparing`) → 취소가 `preparing` 관찰 → 018 가드 취소 409. 모순 상태 없음.

---

## 4. 예외 처리 전략 (error-response-rule 준수)

| 상황 | 발생 지점 | 예외/결과 | REST 매핑 | View 매핑 |
|---|---|---|---|---|
| 미존재 주문 | `OrderFulfillmentService` ①(`findByIdForUpdate` empty) | `OrderNotFoundException`(404) — 관리자 경로라 존재 은닉 불요(평범한 404) | 404 + ErrorResponse | error 뷰(404) |
| 주문이 `paid`/`preparing` 아님(`pending`/`shipping`/`delivered`/`cancelled`/`refunded`) | ② 상태 검증(**부작용 전**) | `OrderFulfillmentConflictException`(409) **직접 throw**(모순2) | 409 + ErrorResponse(상태 불변) | flashError + `/admin/orders` redirect |
| 미발송 항목 0건(만들 배송 없음) / 지정 항목이 이미 다른 배송에 배정 | ③ 대상 판정(부작용 전) | `OrderFulfillmentConflictException`(409, **상태 충돌**, 모순3) | 409 + ErrorResponse | flashError + redirect |
| 지정 `orderItemId`가 미존재 / 해당 주문 소속 아님 | ③ 입력 검증(부작용 전) | **입력 오류 400** — `IllegalArgumentException` → RestExceptionHandler 400 매핑(기존 매핑 확인) 또는 신규 `InvalidShipmentItemException`(400) 1종(모순3) | 400 + ErrorResponse | flashError + redirect |
| 동시 경합 UNIQUE 위반(`order_item_id`) | ④ save | `DataIntegrityViolationException` → **409로 매핑**(상태 충돌) | 409 + ErrorResponse | flashError + redirect |
| 비정상 rollup(paid/preparing 아닌데 markPreparing) | `Order.markPreparing` | `IllegalStateException`(②에서 이미 차단 — 정상 흐름 미발생, 방어) | 500 + 전체 롤백 | 500/error 뷰 |
| 시스템 오류(저장/락) | 트랜잭션 내 임의 단계 | RuntimeException | 500 + **전체 롤백**(부분 반영 없음) | 500/error 뷰 |
| 비인증 / 권한 부족 | Security 필터 | — | 401 / 403 | `/login` redirect / 403 |

핵심 규칙:
- **성공 = 원자 커밋 + 201(REST)/redirect(View).** Shipment·ShipmentItem·rollup이 한 트랜잭션으로 부분 반영 없이 커밋된다.
- **거부 = 모두 서비스에서 도메인 예외 직접 throw(모순2).** 입력 오류 **400**, 상태 충돌 **409**(모순3) — 부작용(Shipment INSERT·rollup) 발생 전 판정이라 롤백할 부작용이 없다. `Outcome` 값 패턴 미사용. "멱등 200" 분기 없음(배송 생성엔 멱등 개념 없음 — 1.6).
- **입력 오류(400) vs 상태 충돌(409) 분리 고정(모순3)**: 요청 자체의 유효성(미존재/타 주문 orderItemId)=400 / 현재 리소스 상태와의 충돌(미발송 0건·이미 배정·잘못된 주문 상태)=409. 016(금액 불일치 400)·018(이행단계 409) 선례.
- **error-response-rule**: 응답·로그에 내부 PG 원문·스택트레이스·`ownerId`·로컬 경로·Entity 비노출. 신규 예외 최대 2종(`OrderFulfillmentConflictException` 409 + 입력 오류 400 — 기존 예외 재사용 가능하면 재사용). 404/500은 기존 재사용.
- **View는 절대 JSON 반환 안 함** — `BusinessException` catch → `flashError` + redirect(AdminMemberViewController 선례).

---

## 5. 검증 방법 (테스트 클래스 매핑 + Acceptance 매핑)

> 테스트 프로파일은 016/018과 동일 — 통합/동시성은 Testcontainers 별도 프로파일(`@AutoConfigureTestDatabase(NONE)` + `@Testcontainers` postgres:16.4-alpine + `@ServiceConnection` + `@TestPropertySource`(autoconfigure exclude 리셋 + flyway enabled + `ddl-auto=validate`)). 본 Task는 **이벤트 미발행**이므로 Outbox 검증 대신 `event_publication` 무변화를 확인한다. 실행: `./gradlew test`.

### 단위(자동) — ShipmentTest / OrderTest
- `Shipment.preparing`: status=`preparing`, `carrier`/`trackingNumber`/`shippedAt`/`deliveredAt` 모두 null. `addItem`으로 ShipmentItem 양방향 연결.
- `Order.markPreparing`(rollup): `paid→preparing` 허용 / `preparing→preparing` 멱등 no-op / 그 외(`pending`/`shipping`/`delivered`/`cancelled`/`refunded`) `IllegalStateException`.
- 016/018 회귀: `markPaid`/`markCancelled`/`markRefunded` 기존 전이 그린 유지.

### 단위(자동) — OrderFulfillmentServiceTest (Mockito)
- 대상 선택: `orderItemIds` 생략 → 미발송 전부로 Shipment 1건. 지정 → 해당 항목만.
- 첫 배송(`paid`) → `Order.markPreparing` 호출(rollup paid→preparing). 추가 배송(`preparing`) → markPreparing 미호출(status 불변).
- **상태 충돌 409 직접 throw**: 미발송 0건 / 지정 항목 이미 배정 / 주문이 `pending`·`shipping`·`delivered`·종결 → `OrderFulfillmentConflictException`(409), **Shipment 저장·rollup 미수행**(부작용 전 throw 검증).
- **입력 오류 400**: 미존재·타 주문 소속 `orderItemId` 지정 → 400(모순3).
- 미존재 주문 → 404.
- **락 우선(InOrder)**: `findByIdForUpdate`가 상태/항목 검증보다 먼저 호출.

### 통합 — 저장·rollup·트리거·UNIQUE·이벤트 (Testcontainers + Modulith)
- `OrderFulfillmentIntegrationTest`:
  - `paid` 주문 배송 생성 → `shipments`(`preparing`)+`shipment_items` 저장 + **`orders.status=preparing` rollup**.
  - 이미 `preparing` 주문 추가 배송 → 새 `shipments`(`preparing`) 저장, 주문 status 불변.
  - 동일 항목 중복 배정 차단(`shipment_items.order_item_id` UNIQUE 위반 검증).
  - **`shipments` UPDATE 시 `updated_at` 갱신(트리거 동작, 모순1)** — 직접 UPDATE(또는 020 선행 시뮬레이션) 후 `updated_at > created_at` 단언. V4 적용 후 `shipments`/`shipment_items` 테이블·`trg_shipments_set_updated_at` 트리거 존재 확인.
  - 시스템 오류(강제 예외) 시 부분 반영 없음(shipments/shipment_items/orders 원자 롤백).
  - **이벤트 미발행**: 배송 생성 커밋 후 `event_publication` 행 증가 0(이 단계 무발행).

### 동시성 — (Testcontainers)
- `OrderFulfillmentConcurrencyIntegrationTest`:
  - 동일 주문 동시 createShipment(같은 미발송 항목) → 주문 row 락 직렬화 + UNIQUE로 항목 이중 배정 0, 한쪽만 성공·다른쪽 409.
  - 배송 생성 vs 018 취소 동시 → 주문 row 락 직렬화, 모순 없음(3.5: 한쪽 종결 반영, 다른쪽 권위 상태 관찰).

### REST/Security(자동) — AdminOrderFulfillmentRestControllerSecurityTest (@SpringBootTest, MockMvc, @MockitoBean OrderFulfillmentService/ShipmentRepository)
- `POST /api/v1/admin/orders/{id}/shipments`: 성공 201 + `ShipmentResponse`(status `preparing`·items). 상태 충돌 409 / 입력 오류 400 / 미존재 404 + ErrorResponse(내부정보 `jsonPath doesNotExist`). `GET` 200 배송 목록.
- 권한: ADMIN 201/200·비인증 401·비ADMIN(CONSUMER/SELLER) 403. 응답 status lowercase.

### View(자동) — AdminOrderViewRenderingTest (@MockitoBean AdminOrderFulfillmentFacade)
- `GET /admin/orders` 렌더(목록·배송 현황). 배송 생성 폼: paid/preparing+미발송 존재 시 노출, 미발송 0건/종결/pending 미노출. CSRF 토큰 포함.
- `POST /admin/orders/{id}/shipments` 성공 → flashSuccess + `/admin/orders` redirect. 불가(`OrderFulfillmentConflictException` 409) → flashError + redirect.
- 비ADMIN 403·비인증 `/login` redirect. **소비자 배송 목록 블록 테스트는 020에서**(019는 소비자 측 무변경 — 정합4).

### 구조(자동) — ModularityTests / Module 구조 테스트
- `Shipment`/`ShipmentItem`/`OrderFulfillmentService`/`ShipmentRepository`/`AdminOrderFulfillmentRestController`/admin facade가 모두 order 모듈(`com.shop.shop.order..`) 위치.
- 이행 코드가 `payment.spi`/`payment`·`inventory`를 의존하지 않음(배송 생성은 외부계 0). `web.order`가 order 도메인 내부(Service/Entity/Repository) 직접 참조 안 함(`order.spi` facade만).
- `ModularityTests.verify()` 통과. **015/016/018 회귀 없음**(소비자 경로·취소 경로·결제 경로 무변경).

### Acceptance Criteria 매핑 표

| Acceptance(Task) | 검증 수단 |
|---|---|
| `paid` 배송 생성 → shipments(preparing)+shipment_items 저장 + rollup paid→preparing + 201 | OrderFulfillmentServiceTest·OrderFulfillmentIntegrationTest·RestControllerSecurityTest |
| 이미 `preparing` 추가 배송 → 새 shipments 저장, status 불변 | OrderFulfillmentServiceTest·OrderFulfillmentIntegrationTest |
| `orderItemIds` 생략=미발송 전부 / 지정=해당 항목 | OrderFulfillmentServiceTest |
| 항목 이중 배정 없음(UNIQUE+락) / 미발송 0건·이미 배정 → 409 / 미존재·타 주문 → 400(모순3) | OrderFulfillmentServiceTest·ConcurrencyIntegrationTest·RestControllerSecurityTest |
| `pending`/`shipping`/`delivered`/종결 → 409, 상태 불변 | OrderFulfillmentServiceTest·RestControllerSecurityTest |
| 거부 직접 throw·부분 반영 없음(Outcome 미사용, 모순2) | OrderFulfillmentServiceTest·OrderFulfillmentIntegrationTest |
| ROLE_ADMIN만 — 비인증 401·비ADMIN 403 | RestControllerSecurityTest·AdminOrderViewRenderingTest |
| admin `/admin/orders` 배송 현황·생성 폼 / 소비자 측 019 신규 없음(정합4) | AdminOrderViewRenderingTest(소비자 미변경은 015/018 회귀 그린으로 확인) |
| 018 상호작용(preparing→취소 409 / paid 취소 가능 / 동시 직렬화) | ConcurrencyIntegrationTest + 018 기존 테스트 회귀 |
| 원자 커밋 / 시스템 오류 전체 롤백 | OrderFulfillmentIntegrationTest·RestControllerSecurityTest |
| V4: shipments/shipment_items(status CHECK 세 값) + trg_shipments_set_updated_at(모순1), orders·기존 migration 무변경, UPDATE 시 updated_at 갱신 | OrderFulfillmentIntegrationTest(트리거·테이블 존재) |
| ModularityTests 통과(새 cross-module 의존 없음), 015/016/018 회귀 없음 | ModularityTests·기존 테스트 전체 통과 |

---

## 6. 트레이드오프

- **배송 단위 모델 채택 vs 주문 단위(orders에 배송 컬럼)**: `Shipment`/`ShipmentItem` 별도 애그리거트는 멀티셀러·부분 배송(한 주문을 여러 배송으로)을 표현하고 추적정보를 배송이 소유하게 해 모델이 정확하다. 주문 단위(orders에 carrier 등 추가)는 단순하지만 부분 배송을 못 그리고 020/021에서 재모델링이 필요하다. **복잡도(테이블 2개·UNIQUE·미발송 판정)를 감수하고 확장성·정확성 우선.**

- **관리자 항목 선택 vs 판매자 자동 그룹핑**: 관리자가 미발송 항목을 골라 배송을 만든다(seller_id 미사용). 판매자↔주문 소유권 매핑·판매자 권한(backlog 002)이 없어 자동 `seller_id` 그룹핑을 켤 수 없다. `shipments.seller_id`를 **nullable 이음매**로만 두어 backlog 002에서 판매자 범위 이행을 추가 마이그레이션 없이 켤 수 있게 한다. **현 단계 단순성 + 미래 이음매 보존.**

- **Outcome 미채택, 단순 throw(모순2) vs 018식 Outcome 값**: 이행 서비스는 order 모듈 내부에서 직접 호출되고 분리 예정이 없어 cross-module 값 매핑(018이 payment→order.spi 경계에서 둔 이유)이 불필요하다. 거부는 부작용 전 판정이라 트랜잭션 안에서 바로 던져도 롤백할 부작용이 없다. **단순성 우선** — 단 미래에 이행을 별도 모듈로 분리하면 값-매핑 이음매가 없어 그때 도입해야 하는 비용이 있다(현재는 분리 예정 없음).

- **rollup `paid→preparing`만 vs 즉시 전체 상태머신**: 본 Task는 `paid→preparing` rollup만 구현하고 `preparing→shipping→delivered` rollup·`Shipment.markShipping`/`markDelivered`·`ShippingStartedEvent`는 020/021로 미룬다(단계 분할 — 각 task = 의미 있는 단일 증분). 한 번에 전체 상태머신을 넣으면 이벤트·소비자 표시·rollup 합산 로직이 검증 폭증한다. **점진 분할 우선**(status CHECK 세 값·트리거를 V4에 미리 넣어 020/021 마이그레이션 재변경은 회피).

- **소비자 표시 020 이연(정합4) vs 019에서 배송 블록 추가**: 019 단계 배송은 `preparing`뿐이고 주문 rollup `order.status`(=`preparing`)를 detail/list가 이미 라벨로 표시한다 → 소비자에게 배송 블록을 그리면 rollup status와 **정보 중복**이고 의미 있는 추적정보(carrier/tracking)는 020에서 등장한다. `OrderResponse.shipments`·소비자 배송 블록을 020에 한 번에 도입해 거의 빈 UI 추가를 피한다. **admin 측 배송 표시는 019 유지**(admin facade — 소비자 OrderResponse와 무관).

- **부분 발송(한 항목 수량 분할)·판매자 이행·반품/교환·shipping/delivered 전이·이벤트 미구현**: Task Constraint 준수. 019는 **Shipment 모델 + 배송 생성(preparing) + rollup paid→preparing + admin View**까지. 배송 시작/완료·`ShippingStartedEvent`·소비자 배송 목록은 020/021 소관이며 본 plan은 스키마/주석 이음매(status CHECK 세 값·트리거·nullable 추적필드)로만 대비한다.

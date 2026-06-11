# 019. shop-core 주문 이행 — Shipment 모델 도입 + 배송 생성(preparing) (with View)

## Target
shop-core

---

## Goal
주문 이행(fulfillment)을 **배송(Shipment) 단위**로 모델링하는 기반을 도입한다. 한 주문은 여러 판매자/부분 배송으로 나뉠 수 있으므로 배송을 **별도 엔티티(Order 1:N Shipment)** 로 둔다. 본 Task는 **배송 애그리거트 도입 + 배송 생성(`preparing`)** 까지만 다룬다.

- **Shipment(배송)**: 주문의 일부(또는 전부) 항목을 묶은 발송 단위. 자체 `status`(`preparing → shipping → delivered`)와 배송 추적 필드(`carrier`/`trackingNumber`/`shippedAt`/`deliveredAt`)를 가진다. **본 Task에서 사용하는 상태는 `preparing`(생성 직후)뿐**이다.
- 관리자가 `paid` 주문의 **미발송 항목**을 골라 **배송을 생성**(`preparing`)한다. 첫 배송 생성 시 주문 `status`는 rollup으로 `paid→preparing`이 된다.
- 소비자는 자기 주문 상세에서 **배송 목록**(배송별 상태·포함 항목)을 읽기 전용으로 확인한다.

> **분할**: 배송 이행은 결제(015→016→017)와 같은 입자도로 단계 분할한다. **019(본 Task)**: Shipment 모델 + 생성(`preparing`). **020**: 배송 시작(`shipping`) + `ShippingStartedEvent` 발행. **021**: 배송 완료(`delivered`). → 본 Task는 **배송 시작/완료 전이와 이벤트 발행을 구현하지 않는다**(020/021).

> **범위 한정**: 전이 주체는 **관리자(`ROLE_ADMIN`)**다. 판매자 범위 이행, 한 주문항목 수량의 분할 발송, 소비자 구매확정, 반품/교환은 범위 밖이다.

---

## Context
- **선행(구현 완료 전제)**
  - `015`: 주문 생성(`pending`) + `order_items`(variantId·productName·quantity·unitPrice 스냅샷, `idx_order_items_order_id`).
  - `016`: 결제 승인 → `pending→paid`. **주문 row 비관적 락(`OrderRepository.findByIdForUpdate`, `@Lock(PESSIMISTIC_WRITE)`) + 권위 재검증** 패턴 확립.
  - `018`: 취소/환불/재고복원. **`Order` 의도 메서드**·**Outcome 값 패턴**·**취소 가드(orders.status가 `preparing`/`shipping`/`delivered`/종결이면 취소 409)**. 본 Task의 rollup `paid→preparing`이 이 가드와 정합해야 한다(§018 상호작용).
- **상태값(orders CHECK 이미 허용)**: `orders.status` CHECK = `pending/paid/preparing/shipping/delivered/cancelled/refunded`. 주문 status는 배송 rollup 결과로만 전이하며 새 상태값을 추가하지 않는다. 본 Task는 `paid→preparing`만 발생시킨다.
- **현재 부재 → 신규 migration 필요**: `shipments`/`shipment_items` 테이블 없음. `orders`에 주문단위 배송 컬럼(carrier 등)을 **추가하지 않는다**(추적정보는 `shipments` 소유).
- **모듈 소유(배송 = order 책임)**: `docs/architecture.md` §5 "배송은 별도 모듈이 아니라 order 모듈의 책임이다." → Shipment 엔티티·서비스·컨트롤러를 모두 `order` 모듈에 둔다. 새 cross-module 의존을 만들지 않는다(payment/payment.spi 무관).
- **권한 모델 결정(설계 판단)**: 판매자↔주문/배송 소유권 매핑이 없고(주문 multi-seller 가능, `Product.ownerId`만 존재) 판매자 가입·권한(backlog 002) 미구현 → 이행 전이 주체를 **`ROLE_ADMIN` 단일**로 한정(소유권 검사 불요). `shipments.seller_id`는 backlog 002에서 판매자 범위 이행을 켜기 위한 **nullable 이음매**로만 두고 본 Task에서 채우거나 강제하지 않는다(product.spi에 ownerId 해석을 추가하지 않음). 소비자는 자기 주문 배송 목록을 읽기 전용 조회(타인 주문 404 존재 은닉, `015` 정책).

## API Authorization
> `api-authorization-rule` 준수 — 이행 전이는 관리자 전용(소유권 검사 불요), 소비자는 자기 주문 읽기.

| API | 공개 여부 | 최소 권한 | 소유권 검사 | 비고 |
|---|---|---|---|---|
| `POST /api/v1/admin/orders/{orderId}/shipments` | authenticated | `ROLE_ADMIN` | 불필요(관리자) | 미발송 항목으로 배송 생성. body: `orderItemIds[]`(생략 시 미발송 전부). → 201 |
| `GET /api/v1/admin/orders/{orderId}/shipments` | authenticated | `ROLE_ADMIN` | 불필요(관리자) | 주문의 배송 목록(관리용) |
| `GET /admin/orders` (View) | authenticated | `ROLE_ADMIN` | 불필요(관리자) | 이행 대상 주문 목록 + 배송 생성 진입 |
| `POST /admin/orders/{orderId}/shipments` (View) | authenticated | `ROLE_ADMIN` | 불필요(관리자) | 배송 생성 폼, 성공 flashSuccess / 불가 flashError |
| `GET /orders/{orderId}` (기존, View) | authenticated | `ROLE_CONSUMER`(+상위) | 필요 | 본인 주문 배송 목록 읽기(신규 엔드포인트 아님 — 표시 확장) |

- 관리자 경로는 `/api/v1/admin/**`(REST line 78)·`/admin/**`(View line 126)의 `hasRole("ADMIN")` 정책에 포함된다 — 포함 여부 확인 후 필요 시 명시 라인 추가(016/018 선례).
- 소비자 배송 조회는 **기존 `GET /orders/{orderId}` 화면 확장**으로 처리(신규 엔드포인트 없음).

## Requirements
- **신규 migration(`V4`) — 배송 스키마**
  - `shipments`: `id`, `order_id`(FK `orders` scalar, NOT NULL), `seller_id`(nullable 이음매), `status` VARCHAR CHECK(`preparing`/`shipping`/`delivered`) — **세 값 모두 CHECK에 포함**(020/021에서 migration 재변경 불필요), `carrier`(nullable), `tracking_number`(nullable), `shipped_at`(nullable), `delivered_at`(nullable), `created_at`/`updated_at`(DB 트리거 소유 — BaseEntity 읽기전용 매핑).
  - `shipment_items`: `id`, `shipment_id`(FK `shipments`, NOT NULL), `order_item_id`(FK `order_items`, **UNIQUE** — 한 주문항목은 최대 1개 배송에만 속함), `created_at`. `idx_shipment_items_shipment_id`.
  - **`updated_at` 자동 갱신 트리거 생성(필수)**: `shipments`는 `BaseEntity`가 `updated_at`을 `updatable=false`로 읽기전용 매핑하므로(JPA가 안 씀), V1의 기존 함수를 재사용한 트리거를 **반드시** 추가한다 — `CREATE TRIGGER trg_shipments_set_updated_at BEFORE UPDATE ON shipments FOR EACH ROW EXECUTE FUNCTION set_updated_at();`. 트리거 없으면 020 `ship`/021 `deliver`의 UPDATE에서 `updated_at`이 영원히 stale. `shipment_items`는 `updated_at`이 없어 트리거 불필요.
  - `orders`·`orders.status` CHECK·다른 테이블·기존 migration은 변경하지 않는다.
- **도메인(order 모듈, Setter 금지·의도 메서드)**
  - `Shipment`(`order/domain`): 정적 팩토리로 `preparing` 생성. **본 Task에서는 `preparing` 상태와 생성만 구현**(`markShipping`/`markDelivered`는 020/021). `carrier`/`tracking`/`shipped_at`/`delivered_at`는 생성 시 null. `BaseEntity` 상속.
  - `ShipmentItem`(`order/domain`): `shipmentId`·`orderItemId` scalar 보유(정확한 매핑은 plan에서 확정 — 같은 모듈이라 연관 매핑도 허용).
  - `Order` rollup 전이: `markPreparing()`(`paid→preparing`). 그 외 상태 호출은 도메인 예외. (`markShipping`/`markDelivered`는 020/021.)
- **이행 오케스트레이션(order 모듈)** — 예: `OrderFulfillmentService.createShipment(orderId, orderItemIds?)`(`@Transactional`)
  1. **주문 row `PESSIMISTIC_WRITE` 잠금**(`findByIdForUpdate`) — 동시 배송 생성·`018` 취소와 직렬화.
  2. 주문이 `paid` 또는 `preparing`인지 검증(그 외 — `pending`/`shipping`/`delivered`/종결 — `409`).
  3. 대상 항목 결정: `orderItemIds` 지정 시 그 항목, 생략 시 **아직 어떤 배송에도 속하지 않은 미발송 항목 전부**(`order.getItems()` − 이미 `shipment_items`에 배정된 항목). 상태코드 분리(모순3): **입력 오류(지정 `orderItemId`가 미존재 또는 해당 주문 소속 아님) = `400`**, **상태 충돌(미발송 항목 0건이라 만들 배송 없음 / 지정 항목이 이미 다른 배송에 배정됨) = `409`**.
  4. `Shipment`(`preparing`) + `ShipmentItem` 생성.
  5. **rollup: 주문이 `paid`면 `markPreparing()`**(첫 배송 생성). 이미 `preparing`이면 주문 status 불변.
  6. 커밋 → `201` + ShipmentResponse.
  - **멱등·동시성**: 동시 `createShipment`로 같은 항목이 두 배송에 들어가지 않도록 `shipment_items.order_item_id` UNIQUE + 주문 row 락으로 보장(충돌 시 `409`).
  - **거부는 직접 throw, Outcome 값 패턴 미채택(모순2)**: 거부(잘못된 주문 상태/항목)는 `OrderFulfillmentConflictException`(409) 등 도메인 예외를 **서비스에서 직접 throw**한다. 부작용 발생 전 판정이라 롤백할 부작용이 없다. 018이 `OrderCancellation`에 Outcome을 둔 건 payment→order.spi **cross-module 경계** 때문이고, 이행 서비스는 order 모듈 내부에서 직접 호출되어 그 경계가 없으므로 값-매핑 indirection을 두지 않는다. 성공은 `ShipmentResponse`(Entity 미노출 scalar record) 반환.
- **`018` 취소와의 상호작용(명시)**: 첫 배송 생성으로 주문이 `preparing`이 되면 `018`의 취소 가드(이행단계 409)가 취소를 차단한다. 배송 전(`paid`, 배송 0건)에는 `018` 취소(환불)가 여전히 가능하다. 두 흐름은 주문 row 락으로 직렬화된다.
- **REST Controller**(`order/controller`) — `RestController → ServiceResponse → Service`. 배송 생성/목록. order 모듈(순환 없음).
- **Admin ViewController**(`web/order`) — `@Controller → order spi facade → Service`. `GET /admin/orders`(이행 대상 주문 목록 + 미발송 항목으로 배송 생성 폼) + `POST /admin/orders/{orderId}/shipments`. 성공 flashSuccess, `BusinessException`(409 등) catch → flashError + redirect(016/018 패턴).
- **소비자 View(정합4 — 신규 작업 없음, 020 이연)**: 019 단계 배송은 `preparing`뿐이고 주문 rollup `order.status`(=`preparing`)는 `templates/order/detail.html`·`list.html`이 **이미 라벨로 표시**한다(중복) → 019에서 **소비자 상세에 배송 목록 블록을 추가하지 않고**, `OrderResponse`에 `shipments` 필드도 추가하지 않는다. 소비자 측 배송 목록 블록·`OrderResponse.shipments`는 **추적정보가 등장하는 020에서 신설**한다. (admin 화면의 배송 표시는 아래 admin facade 경유로 019에서 제공 — 소비자 `OrderResponse`와 무관.)
- **`SecurityConfig`** — `/api/v1/admin/orders/*/shipments`·`/admin/orders/**`가 `ROLE_ADMIN` 정책에 포함되는지 확인 후 필요 시 명시.
- Entity를 API 응답·View 모델에 직접 전달하지 않는다(scalar DTO). 단위·통합·REST/Security·View·구조 테스트 작성.

## Constraints
- **본 Task는 배송 시작/완료·이벤트 발행을 구현하지 않는다**(020/021). `Shipment`는 `preparing` 생성까지만, `Order` rollup은 `paid→preparing`까지만.
- **배송 단위 모델**: 추적정보는 `shipments`가 소유. `orders`에 주문단위 배송 컬럼 추가 금지, `orders.status`는 rollup 결과로만 전이(새 상태값 없음).
- **모듈 순환 의존 금지**: Shipment 엔티티·서비스·컨트롤러를 `order` 모듈에 둔다. 새 cross-module 의존 금지(기존 방향만). `ModularityTests`·구조 테스트 그린.
- **신규 migration은 추가만**: `shipments`/`shipment_items` 신설(status CHECK는 세 값 모두 포함) + **`shipments` `updated_at` 갱신 트리거(`trg_shipments_set_updated_at`, 기존 `set_updated_at()` 재사용) 생성(모순1)**. `orders`·기존 테이블·기존 migration 변경 금지.
- **관리자 단일 주체**: 판매자 범위 이행·자동 판매자 그룹핑은 범위 밖. `shipments.seller_id` 미사용 이음매. 소유권 검사는 소비자 읽기 경로에만.
- **성공은 원자 커밋, 거부는 직접 throw(모순2·3)**: 배송 생성+rollup은 한 트랜잭션 원자 커밋(`201`). 거부는 서비스에서 도메인 예외를 **직접 throw**(부작용 전 판정) — 입력 오류 `400`, 상태 충돌 `409`. Outcome 값 패턴 미사용.
- 비밀/민감정보·Entity·로컬 경로·`ownerId` 노출 금지(016/018 계승). `notification` 미참조. Controller 비즈니스 로직 금지, DTO/Entity 분리.

## Files
> 정확한 경로/migration 파일명은 plan에서 확정.
- (신규) `src/main/resources/db/migration/V4__shipments.sql`(`shipments`/`shipment_items`)
- (신규) `order/domain/Shipment`(preparing 생성), `order/domain/ShipmentItem`
- (신규) `order/repository/ShipmentRepository`
- (신규) `order/service/OrderFulfillmentService`(+ Outcome record) — `createShipment` + rollup `paid→preparing`
- (신규) `order/controller/AdminOrderFulfillmentRestController`(`POST`/`GET /api/v1/admin/orders/{orderId}/shipments`) + `order/dto`(CreateShipmentRequest/ShipmentResponse)
- (신규) `common/exception/OrderFulfillmentConflictException`(409) — 필요 시(기존 conflict 예외 재사용 가능하면 재사용)
- (신규) `web/order/AdminOrderViewController`(+ `templates/admin/orders.html`, 배송 생성 폼)
- (수정) `order/domain/Order`(rollup `markPreparing`)
- (신규/수정) admin facade(`order/spi`, View용 이행 대상 주문 목록·배송 생성 위임). **소비자 `OrderFacade`/`OrderResponse`는 019에서 손대지 않는다(정합4 — 020 이연).**
- (수정) `security/SecurityConfig`(admin 배송 생성 경로 권한 확인/명시)
- (참고) `templates/order/detail.html`·`list.html`의 소비자 배송 목록 블록은 **020에서 추가**(019는 기존 rollup status 라벨만 — 신규 편집 없음).

## Module Boundary Contract

| 항목 | 위치 | 규칙 |
|---|---|---|
| Shipment/ShipmentItem 엔티티 | `order/domain` | 배송 = order 책임. setter 금지, 의도 메서드 |
| 이행 Service | `order/service` | 주문 row 비관락 + 배송 생성 + rollup |
| 이행 REST Controller | `order/controller` | `/api/v1/admin/...`, `ServiceResponse`. order 모듈(순환 없음) |
| Admin ViewController | `web/order` | Thymeleaf SSR, order spi facade만 의존. `web → domain.spi` 단방향 |
| View/Form/DTO | `order/dto` 또는 `web/**` | Entity 직접 노출 금지 |

- 새 cross-module 의존을 만들지 않는다. `ModularityTests` 통과.

## Backend - View Contract

| 항목 | 값 |
|---|---|
| Admin 이행 목록 | `GET /admin/orders` → `templates/admin/orders.html`(주문 + 미발송 항목 + 배송 생성 폼) |
| 배송 생성 폼 | `POST /admin/orders/{orderId}/shipments`(미발송 항목 선택, 노출 조건: `paid`/`preparing` 주문에 미발송 항목 존재) |
| 생성 성공 | flashSuccess + redirect(`/admin/orders` 또는 주문 상세) |
| 생성 불가(409 등) | `BusinessException` catch → flashError + redirect(부작용 없음) |
| 소비자 상세/목록 표시 | **019 신규 없음(정합4)** — 기존 rollup `order.status` 라벨만(`상품 준비 중`). 배송 목록 블록은 020에서 신설 |

> 폼은 CSRF 토큰 포함. 비인증 admin 접근 `/login` redirect, ROLE 부족 403.

## API Response Contract
- 배송 생성: `201` + `ShipmentResponse`(shipmentId·orderId·status(`preparing`)·포함 항목 목록). 목록: `200` + 배송 배열.
- 상태코드 분리(모순3): **입력 오류(지정 `orderItemId` 미존재/타 주문 소속) = `400`**, **상태 충돌(미발송 항목 0건 / 이미 다른 배송에 배정된 항목 지정 / 주문이 `pending`·`shipping`·`delivered`·종결) = `409`**. 둘 다 `ErrorResponse`(내부정보 비노출).
- 미존재 주문: `404`. 비인증 `401`(REST)/`/login`(View), 권한 부족 `403`.
- 응답에 Entity·`ownerId`·로컬 경로 미포함. `status` lowercase.

## Acceptance Criteria
- `paid` 주문에 미발송 항목으로 배송 생성 → `shipments`(`preparing`)+`shipment_items` 저장, **주문 rollup `paid→preparing`**, `201`.
- 이미 `preparing` 주문에 남은 미발송 항목으로 추가 배송 생성 → 새 `shipments`(`preparing`) 저장, 주문 status 불변(`preparing`).
- `orderItemIds` 생략 시 미발송 항목 전부로 배송 1건 생성. 지정 시 해당 항목만.
- 동일 항목이 두 배송에 배정되지 않음(`shipment_items.order_item_id` UNIQUE + 주문 row 락). **미발송 항목 0건/이미 배정된 항목 지정 → `409`**(상태 충돌). **미존재·타 주문 소속 `orderItemId` 지정 → `400`**(입력 오류).
- `pending`/`shipping`/`delivered`/종결(`cancelled`/`refunded`) 주문에 배송 생성 시도 → `409`, 상태 불변.
- 거부는 `OrderFulfillmentConflictException` 등 **직접 throw**로 처리되고 부분 반영이 없다(Outcome 값 패턴 미사용 — 모순2).
- 배송 생성은 **`ROLE_ADMIN`만** — 비인증 401, 비ADMIN(CONSUMER/SELLER) 403.
- admin은 `/admin/orders`에서 주문별 배송 현황을 조회한다. **소비자 측은 019에서 배송 목록 블록 신규 없음(정합4)** — 기존 rollup status 라벨만 노출.
- `018` 상호작용: 첫 배송 생성으로 주문 `preparing`이면 취소 시도 `409`(018 가드). 배송 0건(`paid`)이면 취소(환불) 가능. 배송 생성 vs 취소 동시 → 주문 row 락 직렬화, 모순 없음.
- 배송 생성+rollup은 부분 반영 없이 원자 커밋. 시스템 오류 시 전체 롤백.
- View: admin 배송 생성 폼(CSRF) 노출, 성공 flashSuccess·불가 flashError. 소비자 측은 기존 rollup `order.status` 라벨만(배송 목록 블록은 020 — 정합4).
- 신규 migration으로 `shipments`/`shipment_items` 생성(status CHECK 세 값 포함) + **`trg_shipments_set_updated_at` 트리거 생성**(모순1), `orders`·`status` CHECK·기존 migration 무변경. `shipments` row UPDATE 시 `updated_at`이 갱신된다.
- `ModularityTests`/구조 테스트 통과(새 cross-module 의존 없음). `015`/`016`/`018` 회귀 없음.

## Test
- 단위: `Shipment` 생성(`preparing`, 추적필드 null). `Order.markPreparing()` 허용(`paid`)·금지(그 외).
- 단위(Mockito): `OrderFulfillmentService.createShipment` — 대상 항목 선택/미발송 전부, 첫 배송 시 rollup `paid→preparing`·추가 배송 시 status 불변, **상태 충돌(미발송 0건·이미 배정·잘못된 주문 상태) → 409 직접 throw**, **입력 오류(미존재·타 주문 orderItemId) → 400**(모순2·3), 락이 검증보다 먼저.
- 통합(Testcontainers + Modulith): 배송 생성 커밋 시 `shipments`/`shipment_items` 저장·주문 status rollup. 동일 항목 중복 배정 차단(UNIQUE). **`shipments` UPDATE 시 `updated_at` 갱신(트리거 동작, 모순1)**. 시스템 오류 시 부분 반영 없음. V4 적용 후 테이블·트리거 존재. **이벤트 미발행**(이 단계는 event_publication 무변화).
- 동시성(Testcontainers): 동일 주문 동시 createShipment → 주문 row 락 직렬화, 항목 이중 배정 없음. 배송 생성 vs `018` 취소 동시 → 직렬화, 모순 없음.
- REST/Security: 생성 201 / 상태 충돌 409 / 입력 오류 400 / 미존재 404, ADMIN 200·비인증 401·비ADMIN 403, 응답 내부정보 비노출.
- View: admin 배송 생성 폼(CSRF) 렌더링, 성공 redirect+flashSuccess, 불가 flashError. 비인증 admin `/login` redirect. **소비자 배송 목록 블록 테스트는 020에서**(019는 기존 rollup status 라벨만, 정합4).
- 구조: Shipment order 모듈 위치, 이행 코드가 payment.spi/payment 미의존, `web.order`가 도메인 내부 직접 참조 안 함, `ModularityTests.verify()` 통과.

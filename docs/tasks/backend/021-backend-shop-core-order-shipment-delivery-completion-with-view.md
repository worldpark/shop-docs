# 021. shop-core 주문 이행 — 배송 완료(delivered) (with View)

## Target
shop-core

---

## Goal
`019`(Shipment 모델 + 생성 `preparing`)·`020`(배송 시작 `shipping` + ShippingStartedEvent) 위에 **배송 완료** 전이를 추가해 배송 라이프사이클을 마무리한다. 관리자가 `shipping` 배송을 완료 처리하면:
- 배송 `shipping → delivered`, `deliveredAt` 기록.
- 주문 rollup: **모든 order_items가 배송에 배정되고 모든 배송이 `delivered`면** 주문 `shipping → delivered`. 아니면 주문 status 불변(`shipping` 유지 — 부분 배송 완료).

소비자는 자기 주문 상세 배송 목록에서 `delivered` 상태·배송완료시각을 읽기 전용으로 확인한다.

> **분할**: 019(모델+생성) → 020(시작+이벤트) → **021(본 Task: 완료)**. 본 Task는 배송 라이프사이클의 종착점이다.

> **범위 한정**: 전이 주체는 **관리자(`ROLE_ADMIN`)**. 소비자 구매확정(자동/수동 `delivered` 확정), 반품/교환(`delivered` 이후), **배송완료 알림 이벤트**는 범위 밖이다(배송완료 이벤트는 카탈로그 미정의 — 필요 시 후속에서 문서 먼저 추가).

---

## Context
- **선행(구현 완료 전제)**
  - `019`: `shipments`/`shipment_items` 스키마(status CHECK에 `delivered` 이미 포함, `delivered_at` 컬럼 존재), `Shipment`(`preparing` 생성), 주문 row 비관락 직렬화, admin 배송 관리 View, 소비자 배송 목록.
  - `020`: `Shipment.markShipping`, `Order.markShipping` rollup, `OrderFulfillmentService.ship`, `ShippingStartedEvent`(배송 단위). 소비자 추적정보 표시.
  - `018`: 취소 가드(orders.status가 이행단계/종결이면 취소 409) — `delivered`도 취소 불가 상태. 주문 row 락 직렬화.
- **상태값**: `orders.status` CHECK에 `delivered` 포함(V1). `shipments.status` CHECK에 `delivered` 포함(019). 신규 migration 불필요(`delivered_at`은 019에서 이미 추가).
- **모듈 소유**: 배송 완료 전이는 `order` 모듈(배송 = order 책임). 외부계·이벤트 없음 → 새 의존 없음. payment/payment.spi 무관.
- **권한**: 배송 완료는 `ROLE_ADMIN`(019/020과 동일). 소비자는 자기 주문 읽기 전용.

## API Authorization

| API | 공개 여부 | 최소 권한 | 소유권 검사 | 비고 |
|---|---|---|---|---|
| `POST /api/v1/admin/shipments/{shipmentId}/deliver` | authenticated | `ROLE_ADMIN` | 불필요(관리자) | `shipping → delivered` |
| `POST /admin/shipments/{shipmentId}/deliver` (View) | authenticated | `ROLE_ADMIN` | 불필요(관리자) | 배송 완료 폼, 성공 flashSuccess / 불가 flashError |
| `GET /orders/{orderId}` (기존, View) | authenticated | `ROLE_CONSUMER`(+상위) | 필요 | 본인 주문 배송완료 상태 읽기(표시 확장) |

- 관리자 경로는 `/api/v1/admin/shipments/**`·`/admin/shipments/**`(`hasRole("ADMIN")`)에 포함 — 020에서 이미 명시됐다면 그대로, 누락 시 명시.

## Requirements
- **도메인(order 모듈, Setter 금지·의도 메서드)**
  - `Shipment.markDelivered(Instant deliveredAt)`: `shipping → delivered`. deliveredAt 기록. 그 외 상태 호출은 도메인 예외. 이미 `delivered`이면 멱등.
  - `Order.markDelivered()`: rollup `shipping → delivered`. 그 외 상태 호출은 도메인 예외.
- **이행 오케스트레이션(order 모듈)** — 예: `OrderFulfillmentService.deliver(shipmentId)`(`@Transactional`)
  1. shipment 조회 + **해당 주문 row `PESSIMISTIC_WRITE` 잠금**(`findByIdForUpdate`) — 동시 이행·`018` 취소와 직렬화.
  2. shipment 상태 권위 재검증: `shipping`이면 진행. **이미 `delivered`이면 멱등 반환**(상태 불변). 그 외(`preparing`/역방향) → `409`.
  3. `Shipment.markDelivered(deliveredAt)`.
  4. **rollup 판정**: **주문의 모든 order_items가 배송에 배정**(미배정 항목 0) **&& 그 주문의 모든 shipment가 `delivered`** 이면 `Order.markDelivered()`. 아니면 주문 status 불변(`shipping` 유지 — 부분 배송 완료는 `shipping`에 접힘).
  5. 커밋 → `200` + 갱신 ShipmentResponse.
  - **거부는 직접 throw, 멱등은 200 반환, Outcome 값 패턴 미채택(모순2)**: 잘못된 전이(`preparing`/역방향/종결 주문)는 `OrderFulfillmentConflictException`(409)을 **직접 throw**(부작용 전 판정). **이미 `delivered`(멱등)은 현재 `ShipmentResponse`를 `200`으로 반환**. 018 Outcome은 payment→order.spi cross-module 경계 때문이었고, 이행 서비스는 order 모듈 내부 직접 호출이라 값-매핑 indirection을 두지 않는다. 성공/멱등 모두 `ShipmentResponse` 반환하되 **주문 종착 여부(주문이 `delivered`로 전이됐는지)를 응답 필드로 표현**(거부 분류용 Outcome enum이 아니라 성공 응답의 스칼라 플래그). Entity 미노출 scalar record.
- **rollup 판정 정확성**
  - "모든 항목 배정"은 `order_items` 중 `shipment_items`에 없는 항목이 0인지로 판정한다(미배정 항목이 있으면 주문은 아직 `delivered`가 아니다 — 일부 항목이 배송 생성조차 안 됨).
  - 단조 전진: 한 번 `delivered`가 된 주문은 되돌리지 않는다.
- **멱등·동시성**: 같은 배송 `deliver` 중복은 부작용 없이 멱등 반환. 주문 row 락이 동시 이행·취소와 직렬화. 멀티 배송에서 마지막 배송 완료가 주문 `delivered`를 트리거한다(동시 완료 시 락으로 직렬화되어 rollup 한 번만 전이).
- **REST Controller**(`order/controller`, 020 확장) — `POST /api/v1/admin/shipments/{shipmentId}/deliver`.
- **Admin ViewController**(`web/order`, 020 확장) — `POST /admin/shipments/{shipmentId}/deliver`(노출 조건: shipment=`shipping`). 성공 flashSuccess, `BusinessException` catch → flashError + redirect.
- **소비자 View 확장**(기존 핸들러) — 배송 목록에서 `delivered` 배송에 배송완료시각 표시. 주문이 `delivered`면 목록 rollup 라벨(`배송 완료`).
- **`SecurityConfig`** — `/api/v1/admin/shipments/*/deliver`·`/admin/shipments/**` `ROLE_ADMIN` 포함 확인(020에서 대부분 커버).
- Entity를 응답·View 모델에 직접 전달하지 않는다. 단위·통합·REST/Security·View·구조 테스트 작성.

## Constraints
- **본 Task는 배송 라이프사이클의 완료만 다룬다**: `Shipment.markDelivered`/`Order.markDelivered` rollup. 배송완료 이벤트·구매확정·반품/교환은 범위 밖.
- **신규 migration 없음**: 019의 스키마(`shipments.status` CHECK `delivered`, `delivered_at`)로 충분.
- **rollup 단조 전진**: `delivered`는 전 항목 배정 && 전 배송 delivered일 때만. 부분 배송 완료는 `shipping` 유지(새 상태값 없음). 되돌림 없음.
- **모듈 순환 의존 금지**: 전이를 `order` 모듈에. 새 cross-module 의존 금지. `ModularityTests` 그린.
- **성공은 원자 커밋, 거부는 부작용 전 판정, 멱등**: 전이+rollup은 한 트랜잭션 원자 커밋(`200`). 잘못된 전이는 부작용 전 `409`. `deliver` 중복은 멱등.
- **관리자 단일 주체**: 소유권 검사는 소비자 읽기 경로에만. `notification` 미참조. Entity·로컬 경로 노출 금지. Controller 비즈니스 로직 금지, DTO/Entity 분리.

## Files
> 정확한 경로는 plan에서 확정. 본 Task는 신규 파일이 적고 대부분 019/020 확장.
- (수정) `order/domain/Shipment`(`markDelivered`), `order/domain/Order`(rollup `markDelivered`)
- (수정) `order/service/OrderFulfillmentService`(`deliver` + rollup 판정: 전 항목 배정 && 전 배송 delivered)
- (수정) `order/repository/ShipmentRepository`(주문의 배송 전체 상태 조회, 미배정 항목 존재 여부 판정 쿼리) + 필요 시 `OrderItemRepository` 조회
- (수정) `order/controller/AdminOrderFulfillmentRestController`(`POST /api/v1/admin/shipments/{shipmentId}/deliver`)
- (수정) `web/order/AdminOrderViewController`(`POST /admin/shipments/{shipmentId}/deliver`) + `templates/admin/orders.html`(배송 완료 폼)
- (수정) `templates/order/detail.html`(배송완료시각 표시), `templates/order/list.html`(`배송 완료` 라벨)
- (수정) `security/SecurityConfig`(배송 완료 경로 권한 확인)

## Module Boundary Contract

| 항목 | 위치 | 규칙 |
|---|---|---|
| 배송 완료 전이 | `order/domain` | `Shipment.markDelivered`/`Order.markDelivered`, setter 금지 |
| 배송 완료 Service | `order/service` | 주문 row 비관락 + 상태 재검증 + 전이 + rollup 판정 |
| 배송 완료 REST | `order/controller` | `/api/v1/admin/shipments/{id}/deliver`, `ServiceResponse`. order 모듈(순환 없음) |
| Admin ViewController | `web/order` | Thymeleaf SSR, order spi facade만 의존 |

- 새 cross-module 의존을 만들지 않는다. `ModularityTests` 통과.

## Backend - View Contract

| 항목 | 값 |
|---|---|
| 배송 완료 폼 | `POST /admin/shipments/{shipmentId}/deliver`(노출 조건: shipment=`shipping`) |
| 완료 성공 | flashSuccess + redirect(`/admin/orders` 또는 주문 상세) |
| 완료 불가(409 등) | `BusinessException` catch → flashError + redirect(부작용 없음) |
| 소비자 상세 표시 | `order/detail` 배송 목록에서 `delivered` 배송에 배송완료시각 |
| 소비자 목록 표시 | 주문 rollup `delivered`면 `배송 완료` 라벨 |

> 폼은 CSRF 토큰 포함. 비인증 admin `/login` redirect, ROLE 부족 403.

## API Response Contract
- 배송 완료: `200` + `ShipmentResponse`(status `delivered`·deliveredAt). 응답에 주문 종착 여부(주문이 `delivered`로 전이됐는지) 표현 권장. 멱등 재완료도 동일 결과 `200`.
- 잘못된 전이(`preparing`/역방향/이미 종결 주문): `409` + `ErrorResponse`.
- 미존재 배송: `404`. 비인증 `401`(REST)/`/login`(View), 권한 부족 `403`.
- 응답에 Entity·`ownerId`·로컬 경로 미포함. `status` lowercase.

## Acceptance Criteria
- `shipping` 배송 `deliver` → 배송 `delivered` + deliveredAt 기록, `200`.
- 단일 배송 주문: 그 배송 `deliver` → **모든 항목 배정 && 모든 배송 delivered** 충족 → 주문 rollup `shipping→delivered`.
- 멀티 배송 주문: 일부 배송만 `delivered`이면 주문 status `shipping` 유지(부분 배송). **마지막 배송 완료** 시 주문 `delivered`로 전이.
- 미배정 항목이 남은 주문: 모든 생성된 배송이 `delivered`여도 주문은 `delivered`로 전이하지 않는다(`shipping` 유지).
- 같은 배송 `deliver` 중복 → **멱등 200**, 상태 불변.
- `preparing`/역방향/이미 종결(취소·환불) 주문의 배송 `deliver` 시도 → `409`, 상태 불변.
- 배송 완료는 **`ROLE_ADMIN`만** — 비인증 401, 비ADMIN 403.
- 소비자는 자기 주문 상세에서 `delivered` 배송완료시각·rollup 상태를 조회(타인 주문 404).
- 전이+rollup은 부분 반영 없이 원자 커밋. 시스템 오류 시 전체 롤백.
- 동시성: 멀티 배송 마지막 2건 동시 `deliver` → 주문 row 락 직렬화, 주문 rollup 한 번만 `delivered`로 전이(모순 없음). 배송 완료 vs `018` 취소 동시 → 직렬화.
- 신규 migration 없음(019 스키마로 충분). `ModularityTests`/구조 테스트 통과. `019`/`020`/`016`/`018` 회귀 없음.

## Test
- 단위: `Shipment.markDelivered`(허용 `shipping`/금지/멱등, deliveredAt 기록). `Order.markDelivered()` 허용(`shipping`)·금지.
- 단위(Mockito): `OrderFulfillmentService.deliver` — shipping→delivered, rollup 판정(단일 배송 완료 시 주문 delivered / 멀티 배송 일부 완료 시 shipping 유지 / 미배정 항목 있으면 shipping 유지 / 마지막 배송 완료 시 delivered), 잘못된 전이 409, 멱등 재호출, 락이 재검증보다 먼저.
- 통합(Testcontainers): deliver 커밋 시 shipment·주문 status 전이 원자성. 멀티 배송 마지막 완료가 주문 delivered 트리거. 미배정 항목 시 shipping 유지. 멱등 재호출 상태 불변. **이벤트 미발행**(이 단계는 event_publication 무변화). 시스템 오류 시 부분 반영 없음.
- 동시성(Testcontainers): 멀티 배송 마지막 2건 동시 deliver → 주문 row 락 직렬화, rollup 한 번만 delivered. 배송 완료 vs `018` 취소 동시 → 직렬화, 모순 없음.
- REST/Security: deliver 200 / 잘못된 전이 409 / 미존재 404, ADMIN 200·비인증 401·비ADMIN 403, 응답 내부정보 비노출.
- View: admin 배송 완료 폼(CSRF) 렌더링(shipping), 성공 redirect+flashSuccess, 불가 flashError. 소비자 상세 배송완료시각·목록 `배송 완료` 라벨. 비인증 admin `/login` redirect.
- 구조: 배송 완료 코드 order 모듈 위치, payment.spi/payment 미의존, `web.order` 도메인 내부 직접 참조 안 함, `ModularityTests.verify()` 통과.

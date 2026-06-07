# 015. shop-core 장바구니 기반 주문 생성 + 주문 조회 화면

## Target
shop-core

---

## Goal
`shop-core`에서 로그인한 사용자가 장바구니의 주문 가능한 항목 전체를 주문으로 생성하고, 주문 목록/상세 화면과 REST API에서 자기 주문을 조회할 수 있게 구현한다. 주문 생성 시 상품명·옵션·가격·배송지는 주문 시점 스냅샷으로 저장하고, 재고는 주문 생성 트랜잭션 안에서 원자적으로 차감한다.

---

## Context
- `014`에서 장바구니 담기/조회/수량 변경/삭제와 장바구니 화면을 구현했다
- `orders`, `order_items`, `order_item_option_values`, `payments` 스키마는 V1에 이미 존재한다
- `orders`는 주문 헤더이며 금액과 배송지 스냅샷을 저장한다
- `order_items`는 주문 항목이며 `variant_id`는 참조용이고, 상품명/옵션/단가/수량/라인 금액은 주문 시점 스냅샷이다
- `order_item_option_values`는 옵션명/옵션값 스냅샷 저장용이다
- 이번 Task는 주문을 `pending` 상태로 생성한다
- 이번 Task에서 결제 승인, 결제 실패, 환불, 배송 시작은 구현하지 않는다
- 이번 Task에서 `OrderCompletedEvent`를 발행하지 않는다. `OrderCompletedEvent`는 결제 완료 또는 주문 확정 Task에서 발행한다
- 장바구니는 재고를 예약/차감하지 않는다. 재고 정합성은 주문 생성 트랜잭션에서 보장한다
- order 모듈은 cart/product/inventory/member 내부 Entity/Repository/Service를 직접 참조하지 않는다
- 주문 생성에 필요한 장바구니 항목은 cart 모듈의 published API(`cart.spi`)로 조회/정리한다
- 주문 상품 스냅샷은 product 모듈의 주문 전용 published API(`product.spi.ProductOrderCatalog`)로 조회한다
- 재고 차감은 inventory 모듈의 published API(`inventory.spi`)로 수행한다
- View 흐름(form-login)은 principal=email, REST 흐름(JWT)은 principal=userId(long)로 경로가 다르다. order View facade는 `member.spi.MemberDirectory`로 email→userId 변환을 수행한다
- API 추가 시 `docs/rules/api-authorization-rule.md`를 따른다
- 이벤트 계약을 추가/변경하지 않는다

## API Authorization

| API | 공개 여부 | 최소 권한 | 상위 권한 허용 | 소유권 검사 | 비고 |
|---|---|---|---|---|---|
| `GET /checkout` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 장바구니 기반 주문서 화면 |
| `POST /orders` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 주문 생성 폼 제출 |
| `GET /orders` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 내 주문 목록 화면 |
| `GET /orders/{orderId}` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 내 주문 상세 화면 |
| `POST /api/v1/orders` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 장바구니 기반 주문 생성 API |
| `GET /api/v1/orders` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 내 주문 목록 API |
| `GET /api/v1/orders/{orderId}` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 내 주문 상세 API |

## Requirements
- `Order` Entity/Repository/Service를 구현한다
  - `userId`
  - `orderNumber`
  - `status`
  - `itemsAmount`
  - `discountAmount`
  - `shippingFee`
  - `finalAmount`
  - 배송지 스냅샷: `shipRecipient`, `shipPhone`, `shipPostcode`, `shipAddress1`, `shipAddress2`
  - `createdAt`, `updatedAt`
- `OrderItem` Entity/Repository를 구현한다
  - `order`
  - `variantId`
  - `productName`
  - `optionLabel`
  - `unitPrice`
  - `quantity`
  - `lineAmount`
- `OrderItemOptionValue` Entity/Repository를 구현한다
  - `orderItem`
  - `optionName`
  - `optionValue`
  - `sortOrder`
- Order Entity는 member Entity를 직접 참조하지 않고 `userId` scalar를 가진다
- OrderItem Entity는 product variant Entity를 직접 참조하지 않고 `variantId` scalar를 가진다
- 주문 생성은 현재 로그인 사용자의 장바구니 전체를 기준으로 한다
- 장바구니가 비어 있으면 주문 생성은 실패한다
- 장바구니에 구매 불가능 항목이 하나라도 있으면 주문 생성은 실패한다
  - 상품 status가 `ON_SALE`이 아님
  - variant가 inactive
  - variant가 삭제되어 product purchase catalog에서 조회되지 않음
- 장바구니 항목 quantity가 현재 stock보다 크면 주문 생성은 `409`로 실패한다
  - 재고 부족은 락 전 스냅샷 사전검증과 락 후 권위 검증 모두 동일하게 `409`(`InsufficientStockException`, 상태 충돌)로 응답한다 — `error-response-rule` line 58("상태 충돌(재고 부족 등) → 409") 근거
  - `400`은 배송지 필수값 누락·형식 오류 등 입력 검증에만 사용한다(재고 부족은 입력 오류가 아니라 상태 충돌이다)
- 주문 생성은 부분 주문을 만들지 않는다. 장바구니 항목 중 하나라도 실패하면 주문과 재고 차감과 장바구니 정리는 모두 롤백된다
- 주문 생성 시 주문 항목 스냅샷을 저장한다
  - 상품명은 주문 시점 product name
  - 옵션 라벨은 주문 시점 option label
  - 단가는 주문 시점 variant price
  - 수량은 장바구니 quantity
  - lineAmount = unitPrice × quantity
- 주문 생성 시 옵션명/옵션값 스냅샷을 저장한다
  - order 전용 product published API(`ProductOrderCatalog`)가 옵션명/옵션값 목록을 제공한다
  - order 모듈은 product 내부 option Entity를 직접 참조하지 않는다
- 금액은 주문 시점 스냅샷으로 저장한다
  - `itemsAmount` = 모든 주문 항목 lineAmount 합계
  - `discountAmount` = 0
  - `shippingFee` = 0
  - `finalAmount` = itemsAmount - discountAmount + shippingFee
  - 이번 Task에서 쿠폰, 배송비 계산은 구현하지 않는다
- 배송지는 주문 요청 값으로 스냅샷 저장한다
  - `recipient`, `phone`, `postcode`, `address1`은 필수
  - `address2`는 선택
  - 이번 Task에서 address book CRUD나 기본 배송지 선택 기능은 구현하지 않는다
- 주문번호는 사용자 노출용으로 생성한다
  - `order_number` unique 제약을 만족해야 한다
  - 충돌 가능성이 낮은 형식으로 생성하고, unique 충돌 시 재시도하거나 명확히 실패 처리한다
  - 예: `ORD-yyyyMMdd-HHmmss-<random>`
  - DB `uq_orders_order_number` 위반(`DataIntegrityViolationException`)을 캐치해 **재시도 상한(예: 최대 3회)** 안에서 새 번호로 재생성하고, 상한 초과 시 명확히 실패 처리한다(무한 재시도 금지)
- 주문 status는 생성 시 `pending`으로 저장한다
- 주문 생성 트랜잭션의 단계 순서를 고정한다(락 보유 시간 최소화 + "락 구간 내 외부 I/O 금지" 양립)
  1. 장바구니 조회(`CartCheckoutReader`) — 빈 장바구니면 즉시 실패
  2. 주문 스냅샷 조회·구매가능성/사전 재고 검증(`ProductOrderCatalog`, 락 없음) — 구매 불가/사전 재고 부족이면 `409`로 실패
  3. `variantId` 오름차순으로 inventory 재고 row 비관적 락 획득
  4. 락 구간 내 **권위 재검증**: 최신 stock + 최신 purchasable(product.status==ON_SALE && variant.active) — 부족/구매 불가면 `409`로 실패하고 전체 롤백
  5. 재고 차감(`InventoryStockPort`)
  6. order/order_items/order_item_option_values 스냅샷 저장
  7. 장바구니 비우기(`clearCart`)
  8. 커밋
  - 스냅샷 조회(2)는 락(3) 이전에 수행해 락 보유 구간을 최소화한다
  - 권위 검증(4)은 stock뿐 아니라 purchasable도 포함한다. 사전 검증(2) 통과 후 판매자가 상품을 HIDDEN/SOLD_OUT으로 바꾸거나 variant를 비활성화하는 TOCTOU를 막는다
- 주문 생성 트랜잭션 안에서 재고를 차감한다
  - inventory published API는 주문 대상 variant 재고 row를 **비관적 락**으로 조회한 뒤 재고를 검증/차감한다
  - JPA `@Lock(PESSIMISTIC_WRITE)`(PostgreSQL `SELECT ... FOR UPDATE`)를 사용한다
  - 같은 variant에 대한 동시 주문 생성은 재고 row 단위로 직렬화된다
  - 한 주문에 여러 variant가 있으면 데드락 위험을 줄이기 위해 `variantId` 오름차순으로 락을 획득한다
  - 락을 잡은 뒤 현재 stock이 주문 quantity보다 작으면 주문 생성은 `409`로 실패하고 전체 트랜잭션을 롤백한다
  - 락을 잡은 구간 안에서는 외부 I/O, Kafka 발행, 결제 호출을 수행하지 않는다
  - inventory 모듈은 `product_variants` 테이블에 매핑되는 **inventory 소유 JPA Entity(예: `VariantStock`, `id`·`stock`·`isActive` 매핑)**를 두고, 이 Entity를 `@Lock(PESSIMISTIC_WRITE)`로 조회·갱신한다
    - product 모듈의 `ProductVariant` Entity / Repository / Service를 직접 참조하지 않는다
    - 같은 물리 테이블을 두 Entity가 매핑하므로, 주문 트랜잭션 안에서 `stock` 컬럼을 write하는 주체는 inventory Entity 하나로 한정한다(같은 트랜잭션에서 product `ProductVariant`를 로드·수정하지 않는다)
    - inventory Entity는 신규 row를 insert하지 않는다(기존 row의 `stock` UPDATE 전용). 스키마는 Flyway가 소유하며 `ddl-auto`로 테이블을 생성하지 않는다
    - `is_active`는 `product_variants` 같은 row에 있으므로, inventory가 그 row를 `FOR UPDATE`로 잠그면 판매자의 variant 비활성화 UPDATE가 직렬화된다. 락 구간에서 `isActive`를 함께 읽어 variant 활성 여부를 권위 재검증한다(비활성이면 `409`)
- 락 후 purchasable 재검증의 직렬화 범위
  - **variant.active**: inventory 변형 락(`product_variants` row `FOR UPDATE`)으로 완전 직렬화된다(위 `isActive` 재검증)
  - **product.status**: `products`는 별도 테이블/row라 variant 락으로 직렬화되지 않는다. 락 후 `ProductOrderCatalog`로 최신 status를 재조회해 일반적 경합을 차단하고, 남는 micro-window는 `pending` 단계라 수용하며 결제/주문 확정 Task에서 purchasable을 재검증한다(defense in depth)
  - 이번 Task에서 `products` row까지 `FOR UPDATE`로 잠그는 완전 직렬화는 도입하지 않는다(테이블 2개 락 순서·데드락 표면 증가, 상품 상태 관리 범위 밖)
- 주문 생성 성공 후 장바구니 항목을 비운다
  - 주문 생성/재고 차감/장바구니 비우기는 하나의 트랜잭션에서 처리한다
  - 실패하면 장바구니는 유지한다
- 주문 조회는 자기 주문만 가능하다
  - 다른 사용자의 주문 상세 접근은 404 존재 은닉으로 통일한다
- 주문 목록은 최신순으로 페이지네이션한다
- 주문 상세는 주문 헤더, 주문 항목, 옵션 스냅샷, 배송지 스냅샷, 금액 스냅샷을 반환/표시한다
- `SecurityConfig`에 order/checkout 경로 최소 권한을 명시적으로 추가한다
  - REST 체인(`/api/v1/**`): `/api/v1/orders/**` `hasRole("CONSUMER")`
  - View 체인: `/checkout`, `/orders`, `/orders/**` `hasRole("CONSUMER")`
- REST Controller는 `RestController -> ServiceResponse -> Service -> Repository` 레이어를 따른다
- ViewController는 `web` 모듈에 두고 `ViewController(@Controller) -> order.spi View facade -> Service -> Repository` 레이어를 따른다
- `web` 모듈은 order 내부 `domain`, `repository`, 비공개 `service` 패키지를 직접 참조하지 않는다
- order 모듈은 cart/product/inventory/member 내부 `domain`, `repository`, 비공개 `service` 패키지를 직접 참조하지 않는다
- Entity를 API 응답이나 View 모델에 직접 전달하지 않는다
- 관련 단위 테스트, REST/Security 테스트, View 렌더링 테스트, 구조 테스트를 작성한다

## Constraints
- 이번 Task에서 결제 승인/결제 취소/결제 실패 처리를 구현하지 않는다
- 이번 Task에서 `payments` row를 생성하지 않는다
- 이번 Task에서 `OrderCompletedEvent`, `PaymentFailedEvent`, `ShippingStartedEvent`를 발행하지 않는다
- 이번 Task에서 Kafka 이벤트 계약을 변경하지 않는다
- 이번 Task에서 쿠폰, 배송비 계산, 포인트, 프로모션을 구현하지 않는다
- 이번 Task에서 배송 시작/배송 완료/주문 취소/환불을 구현하지 않는다
- 이번 Task에서 비회원 주문을 구현하지 않는다
- 이번 Task에서 address book CRUD나 기본 배송지 관리를 구현하지 않는다
- 기존 migration을 수정하지 않는다
- `orders`, `order_items`, `order_item_option_values` 스키마가 이미 충분하면 신규 migration을 추가하지 않는다
- 주문 생성 시 product variant 재고는 차감하지만, cart 모듈에서 재고를 차감하지 않는다
- 주문 생성 실패 시 재고 차감과 주문 저장과 장바구니 정리가 부분 반영되면 안 된다
- Controller에서 비즈니스 로직을 작성하지 않는다
- DTO와 Entity를 분리한다
- `notification` 코드나 DB를 참조하지 않는다

## Files
- `shop-core/src/main/java/com/shop/shop/order/controller/**`
- `shop-core/src/main/java/com/shop/shop/order/service/**`
- `shop-core/src/main/java/com/shop/shop/order/repository/**`
- `shop-core/src/main/java/com/shop/shop/order/domain/**`
- `shop-core/src/main/java/com/shop/shop/order/dto/**`
- `shop-core/src/main/java/com/shop/shop/order/spi/**`
- `shop-core/src/main/java/com/shop/shop/cart/spi/**`
- `shop-core/src/main/java/com/shop/shop/cart/service/**`
- `shop-core/src/main/java/com/shop/shop/product/spi/**`
- `shop-core/src/main/java/com/shop/shop/product/service/**`
- `shop-core/src/main/java/com/shop/shop/inventory/spi/**`
- `shop-core/src/main/java/com/shop/shop/inventory/service/**`
- `shop-core/src/main/java/com/shop/shop/inventory/repository/**`
- `shop-core/src/main/java/com/shop/shop/member/spi/**`
- `shop-core/src/main/java/com/shop/shop/common/exception/**`
- `shop-core/src/main/java/com/shop/shop/security/**`
- `shop-core/src/main/java/com/shop/shop/web/order/**`
- `shop-core/src/main/resources/templates/order/checkout.html`
- `shop-core/src/main/resources/templates/order/list.html`
- `shop-core/src/main/resources/templates/order/detail.html`
- `shop-core/src/main/resources/templates/cart/index.html`
- `shop-core/src/main/resources/templates/fragments/nav.html`
- `shop-core/src/test/java/com/shop/shop/order/**`
- `shop-core/src/test/java/com/shop/shop/inventory/**`
- `shop-core/src/test/java/com/shop/shop/web/order/**`
- `shop-core/src/test/java/com/shop/shop/view/**`
- `shop-core/src/test/java/com/shop/shop/security/**`

## Module Boundary Contract

| 항목 | 위치 | 규칙 |
|---|---|---|
| Order REST Controller | `order/controller` | `/api/v1/orders/**`, `ServiceResponse` 사용 |
| Order ViewController | `web/order` | Thymeleaf SSR, order facade만 의존 |
| Order facade interface | `order/spi` | `@NamedInterface("spi")` published API |
| Order facade implementation | `order/service` | order service 위임, Entity -> DTO 변환 |
| Cart checkout port | `cart/spi` | order가 참조 가능한 cart published API |
| Cart checkout implementation | `cart/service` | cart 내부 repository로 checkout cart 조회/비우기 |
| Product order catalog port | `product/spi` | order가 참조 가능한 product published API |
| Product order catalog implementation | `product/service` | product 내부 repository로 주문 스냅샷 조회 |
| Inventory stock port | `inventory/spi` | order가 참조 가능한 inventory published API |
| Inventory stock implementation | `inventory/service` + `inventory/domain` + `inventory/repository` | `product_variants`에 매핑된 inventory 소유 Entity(`VariantStock`)를 `PESSIMISTIC_WRITE` 락으로 검증/차감, product Entity 직접 참조 금지 |
| Member directory port | `member/spi` | View email→userId 변환에 사용 |
| Order Entity | `order/domain` | userId/variantId scalar 사용, member/product Entity 직접 참조 금지 |
| View model/Form/DTO | `order/dto` 또는 `web/order` | Entity 직접 노출 금지 |

권장 cart SPI:

- `CartCheckoutReader`
  - `CartCheckout getCheckoutCart(long userId)`
  - `void clearCart(long userId)`
    - cart는 `uq_carts_user_id`로 user당 1개이므로 cartId를 인자로 받지 않고 userId로만 식별·소유권 검증한다(cartId 동반 시 불일치 위험만 증가)
  - `CartCheckout`에는 cartId, items 포함
  - item DTO에는 cartItemId, variantId, quantity 포함
  - cart Entity나 CartItem Entity는 노출하지 않는다

권장 product SPI:

- `ProductOrderCatalog`
  - `List<OrderableVariantSnapshot> getOrderableSnapshots(Collection<Long> variantIds)`
  - 반환 DTO에는 variantId, productId, productName, optionLabel, optionValues, price, active, stock, purchasable 여부 포함
  - optionValues는 optionName, optionValue, sortOrder 스냅샷 DTO로 제공한다
  - product Entity, variant Entity, option Entity는 노출하지 않는다
  - 기존 `ProductPurchaseCatalog`(cart용, optionLabel만 제공)와 별개의 신규 포트다. `ProductOrderCatalog`는 주문 스냅샷에 필요한 **optionName/optionValue/sortOrder 옵션값 목록**을 추가로 제공하므로 분리한다. 단, productName/price/optionLabel/active/stock/purchasable 판정 로직은 두 포트가 중복 구현하지 않도록 product 내부 공통 조회/매핑을 재사용한다
  - `stock`·`active`·`productStatus` 필드는 주문 사전검증용 advisory 값이며, 권위 있는 재고·purchasable 판정은 락 구간(4단계)에서 수행한다. 사전검증 통과 후에도 락 후 재검증에서 `409`로 실패할 수 있다
  - 락 후 product.status 재검증에 사용할 수 있도록 동일 포트로 최신 status 재조회가 가능해야 한다

권장 inventory SPI:

- `InventoryStockPort`
  - `void decrease(long variantId, int quantity)`
  - 내부에서 `product_variants`에 매핑된 inventory 소유 Entity(`VariantStock`)를 `@Lock(PESSIMISTIC_WRITE)`로 조회한 뒤 stock과 variant 활성(`isActive`)을 검증하고 stock을 차감한다
  - 여러 variant를 차감해야 하면 호출자가 `variantId` 오름차순으로 호출하거나, port가 collection 기반 메서드를 제공해 내부에서 정렬 후 락을 획득한다
  - 재고 부족·variant 비활성은 상태 충돌로 변환(`InsufficientStockException` 등)하고 REST에서는 `409`로 응답한다
  - product Entity/Repository/Service를 직접 참조하지 않는다(같은 테이블을 매핑하는 별도 Entity만 사용)

권장 order facade:

- `OrderFacade`
  - 주문서 조회
  - 주문 생성
  - 내 주문 목록 조회
  - 내 주문 상세 조회
  - View principal email -> userId 변환(`member.spi.MemberDirectory` 사용)과 REST principal userId 경로 차이를 내부에서 통일한다

## Backend - View Contract

| 항목 | 값 |
|---|---|
| 주문서 화면 경로 | `GET /checkout` |
| 주문서 View name | `order/checkout` |
| 주문 생성 폼 action | `POST /orders` |
| 주문 목록 화면 경로 | `GET /orders` |
| 주문 목록 View name | `order/list` |
| 주문 상세 화면 경로 | `GET /orders/{orderId}` |
| 주문 상세 View name | `order/detail` |
| 주문 생성 폼 필드 | `recipient`, `phone`, `postcode`, `address1`, `address2` |
| 주문서 모델 키 | `checkout` |
| 주문 목록 모델 키 | `orders` |
| 주문 상세 모델 키 | `order` |
| 주문 생성 성공 리다이렉트 | `/orders/{orderId}` |
| 주문 생성 실패 처리 | flashError 후 `/checkout` redirect |
| 장바구니 주문하기 버튼 | `/checkout` 링크 또는 form 이동 |
| nav 주문 링크 | `/orders` |

## API Response Contract

권장 DTO:

- `OrderCreateRequest`
  - `recipient`
  - `phone`
  - `postcode`
  - `address1`
  - `address2`
- `OrderResponse`
  - `orderId`
  - `orderNumber`
  - `status`
  - `items`
  - `itemsAmount`
  - `discountAmount`
  - `shippingFee`
  - `finalAmount`
  - `shippingAddress`
  - `createdAt`
- `OrderItemResponse`
  - `orderItemId`
  - `variantId`
  - `productName`
  - `optionLabel`
  - `optionValues`
  - `unitPrice`
  - `quantity`
  - `lineAmount`
- `OrderItemOptionValueResponse`
  - `optionName`
  - `optionValue`
  - `sortOrder`
- `ShippingAddressResponse`
  - `recipient`
  - `phone`
  - `postcode`
  - `address1`
  - `address2`
- `OrderSummaryResponse`
  - `orderId`
  - `orderNumber`
  - `status`
  - `representativeItemName`
  - `itemCount`
  - `finalAmount`
  - `createdAt`

주의:

- 주문 응답은 주문 시점 스냅샷 기준이다
- 현재 product name/price/option 변경이 기존 주문 응답에 영향을 주면 안 된다
- `ownerId`, member Entity, product Entity, variant Entity, cart Entity, 로컬 파일 경로는 응답에 포함하지 않는다
- `status`는 DB 값과 정렬해 lowercase 문자열(`pending`, `paid` 등)로 응답한다

## Acceptance Criteria
- 비인증 사용자는 주문서/주문 목록/주문 상세 화면에 접근할 수 없고 로그인으로 이동한다
- `CONSUMER`는 자기 주문서와 자기 주문 목록/상세에 접근할 수 있다
- `SELLER`, `ADMIN`도 권한 계층에 따라 자기 주문서와 자기 주문 목록/상세에 접근할 수 있다
- 비인증 사용자의 주문 REST API 요청은 401 JSON을 반환한다
- ROLE 없는 인증 토큰의 주문 REST API 요청은 403 JSON을 반환한다
- 장바구니가 비어 있으면 주문 생성은 실패한다
- 장바구니에 구매 불가능 항목이 있으면 주문 생성은 실패한다
- 장바구니 항목 quantity가 현재 stock보다 크면 주문 생성은 409로 실패한다
- 동시 주문으로 stock이 부족해진 경우 비관적 락 획득 후 최신 stock 기준 검증에서 주문 생성이 409로 실패하고 전체 트랜잭션이 롤백된다
- 사전 검증 통과 후 락 직전에 product가 HIDDEN/SOLD_OUT으로 바뀌거나 variant가 비활성화되면, 락 후 purchasable 재검증에서 주문 생성이 409로 실패하고 전체 트랜잭션이 롤백된다
- 배송지 필수값 누락·형식 오류는 400으로 실패한다(재고/상태 충돌 409와 구분)
- 주문 생성 성공 시 `orders`에 `pending` 주문이 생성된다
- 주문 생성 성공 시 `order_items`에 상품명/옵션라벨/단가/수량/라인금액 스냅샷이 저장된다
- 주문 생성 성공 시 `order_item_option_values`에 옵션명/옵션값 스냅샷이 저장된다
- 주문 생성 성공 시 `itemsAmount`, `discountAmount=0`, `shippingFee=0`, `finalAmount`가 저장된다
- 주문 생성 성공 시 배송지 스냅샷이 저장된다
- 주문 생성 성공 시 product variant stock이 주문 수량만큼 차감된다
- 주문 생성 성공 시 장바구니 항목이 비워진다
- 주문 생성 실패 시 주문/주문항목이 저장되지 않고 재고와 장바구니가 변경되지 않는다
- 주문번호는 중복되지 않는다
- 사용자는 자기 주문 목록을 최신순으로 조회할 수 있다
- 사용자는 자기 주문 상세를 조회할 수 있다
- 다른 사용자의 주문 상세 접근은 404(존재 은닉)로 실패한다
- 주문 응답과 화면은 주문 시점 스냅샷을 표시한다
- 상품명/가격/옵션이 주문 후 변경되어도 기존 주문 상세 표시값은 바뀌지 않는다
- 이번 Task에서 payment row를 생성하지 않는다
- 이번 Task에서 OrderCompletedEvent를 발행하지 않는다
- `SecurityConfig`에서 주문 경로(REST `/api/v1/orders/**`, View `/checkout`, `/orders`, `/orders/**`)에 최소 권한 `ROLE_CONSUMER`가 명시적으로 적용된다
- order 모듈은 cart/product/inventory/member 내부 구현을 직접 참조하지 않고 published API 또는 scalar만 사용한다
- ViewController는 `web/order`에 위치하고 order 내부 구현에 직접 의존하지 않는다
- 관련 테스트가 통과한다

## Test
- `./gradlew test`
- 권장 단위 테스트
  - 장바구니 기반 주문 생성 성공
  - 빈 장바구니 주문 생성 실패
  - 구매 불가능 항목 포함 시 주문 생성 실패
  - stock 부족 항목 포함 시 주문 생성 실패
  - 비관적 락 획득 후 최신 stock 부족 시 주문 생성 실패
  - 락 후 purchasable 재검증 실패(product HIDDEN/SOLD_OUT 또는 variant 비활성) 시 주문 생성 실패
  - 주문 생성 실패 시 cart clear 호출 없음
  - 주문 생성 실패 시 저장된 order/orderItem 없음
  - 주문 생성 성공 시 order status `pending`
  - 주문 생성 성공 시 상품명/옵션/가격/배송지 스냅샷 저장
  - 주문 생성 성공 시 itemsAmount/finalAmount 계산
  - 주문 생성 성공 시 inventory stock decrease 호출
  - 주문 생성 성공 시 cart clear 호출
  - 주문번호 unique 충돌 재시도 또는 실패 처리
  - 자기 주문 목록 최신순 조회
  - 자기 주문 상세 조회
  - 다른 사용자 주문 상세 404 존재 은닉
- 권장 Cart SPI 테스트
  - `CartCheckoutReader.getCheckoutCart`가 cart Entity/CartItem Entity를 노출하지 않고 scalar DTO만 반환
  - `clearCart(userId)`가 해당 userId의 cart만 비우고 다른 user의 cart에는 영향이 없음
  - cart가 없는 userId의 `clearCart`는 조용한 no-op이 아니라 정의된 동작(예외 또는 명시적 무효)으로 처리
- 권장 Product SPI 테스트
  - 주문 스냅샷 조회 성공
  - `DRAFT`/`HIDDEN`/`SOLD_OUT` 상품 variant는 purchasable=false
  - 비활성 variant는 purchasable=false
  - optionName/optionValue/sortOrder 스냅샷 DTO 제공
  - product/variant/option Entity를 SPI DTO로 노출하지 않음
- 권장 Inventory SPI 테스트
  - stock 충분 시 비관적 락 기반 decrement 성공
  - stock 부족 시 `InsufficientStockException`
  - 여러 variant 차감 시 variantId 오름차순으로 락 획득
  - stock 충분하지만 variant 비활성 시 상태 충돌로 실패(`409` 매핑)
  - product Entity/Repository/Service 직접 참조 없음
  - 재고가 음수가 되지 않음
- 권장 동시성 통합 테스트 (Testcontainers PostgreSQL + `@SpringBootTest`)
  - 같은 variant 재고가 1일 때 동일 variant를 동시에 주문하는 2개 트랜잭션 중 하나만 성공하고 나머지는 `409`(`InsufficientStockException`)으로 실패한다
  - 비관적 락으로 동일 variant 주문이 직렬화되어 stock이 음수가 되지 않는다
  - 사전 검증 통과 후 variant 비활성화가 락 직전에 커밋되면 락 후 purchasable 재검증에서 `409`로 실패한다(variant.active 직렬화 검증)
  - 실패 트랜잭션은 order/order_items/재고/장바구니가 모두 롤백된다
  - 실제 PostgreSQL row-level lock(`SELECT ... FOR UPDATE`) 동작을 Mockito 단위 테스트가 아닌 실 DB로 검증한다
  - 이 테스트는 DataSource/Flyway/JPA 자동설정이 활성화된 통합 테스트 프로파일에서 실행한다(테스트 기본 프로파일의 자동설정 제외와 충돌하지 않게 별도 구성한다)
- 권장 Member SPI 테스트
  - View facade에서 `MemberDirectory.findUserIdByEmail`로 email→userId 변환
- 권장 REST/Security 테스트
  - `POST /api/v1/orders` CONSUMER 200/201, 비인증 401, ROLE 없는 인증 403, SELLER/ADMIN 200
  - `POST /api/v1/orders` 배송지 입력 검증 실패 400
  - `POST /api/v1/orders` 재고 부족(사전/동시성) 실패 409
  - `POST /api/v1/orders` 락 후 purchasable 충돌(HIDDEN/SOLD_OUT/비활성) 실패 409
  - `GET /api/v1/orders` 자기 주문 목록 200
  - `GET /api/v1/orders/{orderId}` 자기 주문 상세 200
  - `GET /api/v1/orders/{orderId}` 타 사용자 주문 404
  - 응답에 ownerId, member Entity, product Entity, variant Entity, cart Entity, 로컬 절대 경로 미포함
- 권장 View 테스트
  - `GET /checkout` 인증 사용자 렌더링
  - `GET /checkout` 비인증 사용자는 `/login` redirect
  - 주문서에 장바구니 주문 가능 항목과 금액 렌더링
  - 주문 생성 폼 CSRF 포함
  - 주문 생성 성공 redirect `/orders/{orderId}`
  - 주문 생성 실패 시 flashError 표시
  - `GET /orders` 주문 목록 렌더링
  - `GET /orders/{orderId}` 주문 상세 렌더링
  - nav에 주문 링크 포함
- 권장 구조 테스트
  - `web.order`가 `order.domain`, `order.repository`, `order.service`를 직접 참조하지 않음
  - `order` 모듈이 `cart.domain`, `cart.repository`, `cart.service`를 직접 참조하지 않음
  - `order` 모듈이 `product.domain`, `product.repository`, `product.service`를 직접 참조하지 않음
  - `order` 모듈이 `inventory.domain`, `inventory.repository`, `inventory.service`를 직접 참조하지 않음
  - `order` 모듈이 `member.domain`, `member.repository`, `member.service`를 직접 참조하지 않음
  - `order` 모듈은 cart/product/inventory/member published API 또는 scalar만 사용
  - `inventory` 모듈이 product Entity/Repository/Service를 직접 참조하지 않음
  - `ModularityTests.verify()` 통과

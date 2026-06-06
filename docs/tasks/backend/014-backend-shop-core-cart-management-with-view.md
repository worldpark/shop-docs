# 014. shop-core 장바구니 담기 + 조회 + 수량 변경 화면

## Target
shop-core

---

## Goal
`shop-core`에서 로그인한 사용자가 공개 상품 상세에서 variant를 장바구니에 담고, 장바구니 화면과 REST API에서 항목 조회·수량 변경·삭제를 할 수 있게 구현해 주문 생성으로 이어지는 구매 흐름의 기반을 만든다.

---

## Context
- `013`에서 공개 상품 목록/상세 화면과 API를 구현했다
- 상품 구매 단위는 `product_variants`다
- 장바구니 스키마(`carts`, `cart_items`)는 V1에 이미 존재한다
- `carts`는 회원당 1개이며 `user_id` unique 제약을 가진다
- `cart_items`는 `(cart_id, variant_id)` unique 제약을 가진다
- 장바구니는 주문 전 임시 보관 영역이며, 이번 Task에서 재고를 차감하거나 예약하지 않는다
- cart 모듈은 product 내부 Entity/Repository/Service를 직접 참조하지 않는다
- variant 구매 가능 여부와 표시 정보는 product 모듈의 published API(`product.spi`)를 통해 조회한다
- View 흐름(form-login)은 principal=email, REST 흐름(JWT)은 principal=userId(long)로 경로가 다르다. cart는 View 진입에서 email→userId 변환이 필요하며, 이 변환은 member 모듈의 published port(`member.spi`)를 통해 수행한다
  - 기존 `product.spi.UserDirectory`는 **product 소유 포트**이므로 cart가 재사용하지 않는다. cart가 사용할 email→userId 조회는 `member.spi`에 신규 port로 노출한다(소유=조회 주체 모듈인 member, 기존 UserDirectory 선례와 동일한 의존 역전)
- API 추가 시 `docs/rules/api-authorization-rule.md`를 따른다

## API Authorization

| API | 공개 여부 | 최소 권한 | 상위 권한 허용 | 소유권 검사 | 비고 |
|---|---|---|---|---|---|
| `GET /cart` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 내 장바구니 화면 |
| `POST /cart/items` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 장바구니 담기 폼 제출 |
| `POST /cart/items/{cartItemId}` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 수량 변경 폼 제출 |
| `POST /cart/items/{cartItemId}/delete` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 장바구니 항목 삭제 폼 제출 |
| `GET /api/v1/cart` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 내 장바구니 조회 API |
| `POST /api/v1/cart/items` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 장바구니 담기 API |
| `PATCH /api/v1/cart/items/{cartItemId}` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 수량 변경 API |
| `DELETE /api/v1/cart/items/{cartItemId}` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 장바구니 항목 삭제 API |

## Requirements
- `Cart` Entity/Repository/Service를 구현한다
  - `userId`
  - 회원당 1개
  - 없으면 최초 조회/담기 시 생성한다
- `CartItem` Entity/Repository/Service를 구현한다
  - `cart`
  - `variantId`
  - `quantity`
  - `addedAt`
- Cart Entity는 member Entity를 직접 참조하지 않고 `userId` scalar를 가진다
- CartItem Entity는 product variant Entity를 직접 참조하지 않고 `variantId` scalar를 가진다
- 같은 variant를 다시 담으면 새 row를 만들지 않고 기존 항목 quantity를 증가시킨다
  - 재담기로 quantity를 증가시킬 때 `addedAt`은 최초 담은 시점을 유지한다(갱신하지 않는다)
- 장바구니/항목 생성은 비관적 락 없이 처리하되, unique 제약(`uq_carts_user_id`, `uq_cart_items_cart_variant`) 동시성 경합을 안전하게 처리한다
  - "없으면 생성"과 "같은 variant 재담기 증가"는 동시 요청 시 unique 위반이 발생할 수 있으므로, `DataIntegrityViolationException` 발생 시 재조회 후 기존 row에 증가시키는 방식 등으로 복구한다(요청 실패로 노출하지 않는다)
- quantity는 1 이상이어야 한다
- cartItem 수량 변경은 임시 장바구니 데이터이므로 비관적 락을 적용하지 않고 last write wins를 허용한다
  - 같은 사용자가 같은 cartItem을 여러 탭에서 동시에 수정하면 마지막으로 처리된 요청의 quantity가 최종 값이 된다
  - 재고 정합성은 장바구니가 아니라 주문 생성/확정 단계에서 보장한다
- 장바구니 담기/수량 변경 시 현재 구매 가능한 variant인지 검증한다
  - 상품 status가 `ON_SALE`
  - variant가 active
  - variant stock이 요청 quantity 이상
- 재고는 장바구니 담기/수량 변경 시 차감하지 않는다
- 장바구니 조회 시 현재 상품/variant 상태를 반영한다
  - 상품이 비공개 상태가 되었거나 variant가 비활성화되었거나 재고가 부족하면 해당 항목을 `available=false` 또는 `stockEnough=false`로 표시한다
  - 자동 삭제하지 않는다
- 장바구니 화면을 구현한다
  - `GET /cart`
  - 항목 목록, 상품명, 대표 이미지, 옵션 라벨, 단가, 수량, 합계 금액 표시
  - 수량 변경 폼
  - 항목 삭제 폼
  - 주문하기 버튼은 이번 Task에서 동작 구현하지 않고 후속 Task 상태로 둔다
- 공개 상품 상세 화면에 장바구니 담기 폼을 연결한다
  - variant 선택 후 `POST /cart/items`
  - 비인증 사용자는 로그인으로 이동한다
- REST 장바구니 API를 구현한다
  - `GET /api/v1/cart`
  - `POST /api/v1/cart/items`
  - `PATCH /api/v1/cart/items/{cartItemId}`
  - `DELETE /api/v1/cart/items/{cartItemId}`
- REST Controller는 `RestController -> ServiceResponse -> Service -> Repository` 레이어를 따른다
- ViewController는 `web` 모듈에 두고 `ViewController(@Controller) -> cart.spi View facade -> Service -> Repository` 레이어를 따른다
- `web` 모듈은 cart 내부 `domain`, `repository`, 비공개 `service` 패키지를 직접 참조하지 않는다
- cart 모듈은 product 내부 `domain`, `repository`, 비공개 `service` 패키지를 직접 참조하지 않는다
- product variant 구매 가능성/표시 정보 조회용 product facade를 `product.spi` named interface로 노출한다
- cart 화면용 cart facade를 `cart.spi` named interface로 노출한다
- cart의 View 진입 email→userId 변환용 member 조회 port를 `member.spi` named interface로 노출한다(구현은 member 내부 service, cart는 이 port만 의존)
- `SecurityConfig`에 cart 경로 최소 권한을 명시적으로 추가한다 (현재 두 경로 모두 `anyRequest().authenticated()`로만 보호됨 — 최소 권한 `ROLE_CONSUMER`를 강제하지 않음)
  - REST 체인(`/api/v1/**`): `/api/v1/cart/**` `hasRole("CONSUMER")` (역할 계층상 SELLER·ADMIN 함의)
  - View 체인: `/cart`, `/cart/**` `hasRole("CONSUMER")` (미인증은 `/login` redirect)
- product purchase port가 cart에 전달하는 `stock`(수치)은 cart 내부 `stockEnough` 판정에만 사용하고, `CartItemResponse`·View 모델에는 노출하지 않는다(공개 API와 동일하게 정확한 재고 수치 비노출)
- Entity를 API 응답이나 View 모델에 직접 전달하지 않는다
- 관련 단위 테스트, REST/Security 테스트, View 렌더링 테스트, 구조 테스트를 작성한다

## Constraints
- 이번 Task에서 주문 생성 기능을 구현하지 않는다
- 이번 Task에서 결제 기능을 구현하지 않는다
- 이번 Task에서 재고 차감/예약/복원 기능을 구현하지 않는다
- 수량 변경에 비관적 락을 적용하지 않는다. 장바구니는 주문 전 임시 데이터이며, 같은 cartItem 동시 수정은 last write wins를 허용한다
- 이번 Task에서 쿠폰, 배송지, 배송비 계산을 구현하지 않는다
- 이번 Task에서 비회원 장바구니를 구현하지 않는다
- 이번 Task에서 Redis/session 기반 임시 장바구니를 구현하지 않는다
- 장바구니에 담긴 가격은 저장하지 않고 조회 시 현재 variant 가격을 표시한다
- 주문 시점 가격 스냅샷은 주문 Task에서 처리한다
- 다른 사용자의 장바구니나 cartItem을 조회/수정/삭제할 수 없다. 타인 소유 또는 미존재 cartItem 접근은 **404 존재 은닉**으로 통일한다(기존 `ProductAccessDeniedException`=404 컨벤션과 정렬, 403 사용 안 함)
- 검증 실패(quantity<1, 구매 불가능 variant, 요청 quantity가 stock 초과)는 REST에서 일괄 `400`으로 응답한다(stock 초과를 409로 분기하지 않는다)
- Controller에서 비즈니스 로직을 작성하지 않는다
- DTO와 Entity를 분리한다
- `notification` 코드나 DB를 참조하지 않는다
- 이벤트 계약은 변경하지 않는다
- 기존 migration을 수정하지 않는다
- `carts`, `cart_items` 스키마가 이미 충분하면 신규 migration을 추가하지 않는다

## Files
- `shop-core/src/main/java/com/shop/shop/cart/controller/**`
- `shop-core/src/main/java/com/shop/shop/cart/service/**`
- `shop-core/src/main/java/com/shop/shop/cart/repository/**`
- `shop-core/src/main/java/com/shop/shop/cart/domain/**`
- `shop-core/src/main/java/com/shop/shop/cart/dto/**`
- `shop-core/src/main/java/com/shop/shop/cart/spi/**`
- `shop-core/src/main/java/com/shop/shop/product/spi/**`
- `shop-core/src/main/java/com/shop/shop/product/service/**`
- `shop-core/src/main/java/com/shop/shop/member/spi/**`
- `shop-core/src/main/java/com/shop/shop/member/service/**`
- `shop-core/src/main/java/com/shop/shop/web/cart/**`
- `shop-core/src/main/java/com/shop/shop/web/product/**`
- `shop-core/src/main/java/com/shop/shop/common/exception/**`
- `shop-core/src/main/java/com/shop/shop/security/**`
- `shop-core/src/main/resources/templates/cart/index.html`
- `shop-core/src/main/resources/templates/product/detail.html`
- `shop-core/src/main/resources/templates/fragments/nav.html`
- `shop-core/src/test/java/com/shop/shop/cart/**`
- `shop-core/src/test/java/com/shop/shop/web/cart/**`
- `shop-core/src/test/java/com/shop/shop/view/**`
- `shop-core/src/test/java/com/shop/shop/security/**`

## Module Boundary Contract

| 항목 | 위치 | 규칙 |
|---|---|---|
| Cart REST Controller | `cart/controller` | `/api/v1/cart/**`, `ServiceResponse` 사용 |
| Cart ViewController | `web/cart` | Thymeleaf SSR, cart facade만 의존 |
| Cart facade interface | `cart/spi` | `@NamedInterface("spi")` published API |
| Cart facade implementation | `cart/service` | cart service/repository 위임, Entity -> DTO 변환 |
| Product purchase info port | `product/spi` | cart가 참조 가능한 product published API |
| Product purchase info implementation | `product/service` | product 내부 service/repository로 variant 검증·표시 정보 조회 |
| Member directory port (email→userId) | `member/spi` | cart가 참조 가능한 member published API. `product.spi.UserDirectory` 재사용 금지(소유 모듈 분리) |
| Member directory implementation | `member/service` | member 내부 repository로 email→userId 조회 |
| Cart Entity | `cart/domain` | userId/variantId scalar 사용, member/product Entity 직접 참조 금지 |
| View model/Form/DTO | `cart/dto` 또는 `web/cart` | Entity 직접 노출 금지 |

권장 product SPI:

- `ProductPurchaseCatalog`
  - `PurchasableVariant getPurchasableVariant(long variantId)`
  - `List<PurchasableVariant> getPurchasableVariants(Collection<Long> variantIds)`
  - 반환 DTO에는 variantId, productId, productName, productStatus, optionLabel, imageUrl, price, active, stock, purchasable 여부 포함
  - product Entity나 variant Entity는 노출하지 않는다

권장 member SPI:

- `MemberDirectory` (`member.spi`, `@NamedInterface("spi")`)
  - `long findUserIdByEmail(String email)`
  - cart의 View facade가 form-login email을 userId로 해석할 때 사용한다
  - 구현은 `member/service`에 두고 member 내부 repository로 조회한다
  - member Entity를 노출하지 않는다(scalar userId만 반환)

권장 cart facade:

- `CartFacade`
  - 내 장바구니 조회
  - 장바구니 담기
  - 수량 변경
  - 항목 삭제
  - View principal email -> userId 변환(`member.spi.MemberDirectory` 사용)과 REST principal userId 경로 차이를 내부에서 통일한다

## Backend - View Contract

| 항목 | 값 |
|---|---|
| 장바구니 화면 경로 | `GET /cart` |
| 장바구니 View name | `cart/index` |
| 장바구니 템플릿 | `templates/cart/index.html` |
| 장바구니 담기 폼 action | `POST /cart/items` |
| 수량 변경 폼 action | `POST /cart/items/{cartItemId}` |
| 항목 삭제 폼 action | `POST /cart/items/{cartItemId}/delete` |
| 담기 폼 필드 | `variantId`, `quantity` |
| 수량 변경 필드 | `quantity` |
| 장바구니 모델 키 | `cart` |
| 장바구니 항목 모델 키 | `cart.items` |
| 성공 리다이렉트 | `/cart` |
| 실패 처리 | flashError 후 원래 화면 또는 `/cart` redirect |
| 공개 상품 상세 장바구니 폼 | `templates/product/detail.html`에 추가 |
| nav 장바구니 링크 | `/cart` |

## API Response Contract

권장 DTO:

- `CartResponse`
  - `cartId`
  - `items`
  - `totalQuantity`
  - `totalAmount`
  - `hasUnavailableItem`
- `CartItemResponse`
  - `cartItemId`
  - `variantId`
  - `productId`
  - `productName`
  - `optionLabel`
  - `imageUrl`
  - `unitPrice`
  - `quantity`
  - `lineAmount`
  - `available`
  - `stockEnough`
- `CartItemAddRequest`
  - `variantId`
  - `quantity`
- `CartItemQuantityUpdateRequest`
  - `quantity`

주의:

- `unitPrice`와 `lineAmount`는 조회 시점의 현재 variant 가격 기준이다
- 주문 시점 금액 스냅샷은 order Task에서 별도로 저장한다
- `stock` 정확한 수량은 공개 API와 동일하게 노출하지 않고 `stockEnough`로만 표현한다
- `ownerId`, product Entity, variant Entity, 로컬 파일 경로는 응답에 포함하지 않는다

## Acceptance Criteria
- 비인증 사용자는 장바구니 화면에 접근할 수 없고 로그인으로 이동한다
- `CONSUMER`는 자기 장바구니 화면에 접근할 수 있다
- `SELLER`, `ADMIN`도 권한 계층에 따라 자기 장바구니 화면에 접근할 수 있다
- 비인증 사용자의 장바구니 REST API 요청은 401 JSON을 반환한다
- 인증 사용자는 자기 장바구니를 조회할 수 있다
- 장바구니가 없으면 최초 조회 또는 담기 시 생성된다
- 공개 상품 상세에서 variant와 수량을 선택해 장바구니에 담을 수 있다
- 같은 variant를 다시 담으면 기존 cartItem quantity가 증가한다
- quantity가 1보다 작으면 실패한다
- 구매 불가능한 variant는 장바구니에 담을 수 없다
- 요청 quantity가 현재 stock보다 크면 장바구니 담기와 수량 변경은 실패한다
- 장바구니 담기와 수량 변경은 재고를 차감하지 않는다
- 사용자는 cartItem 수량을 변경할 수 있다
- cartItem 수량 변경은 비관적 락 없이 처리하며, 같은 항목 동시 수정은 last write wins를 허용한다
- 사용자는 cartItem을 삭제할 수 있다
- 다른 사용자의 cartItem 수량 변경/삭제는 404(존재 은닉)로 실패한다
- 장바구니 조회는 현재 상품/variant 상태를 반영해 unavailable 또는 stockEnough false 상태를 표시한다
- 장바구니 항목의 가격과 합계는 현재 variant 가격 기준으로 계산된다
- 장바구니 화면에는 상품명, 대표 이미지, 옵션 라벨, 단가, 수량, 합계가 표시된다
- 주문하기 버튼은 동작 구현 없이 후속 Task 상태로 표시된다
- cart 모듈은 product 내부 구현을 직접 참조하지 않고 product published API만 사용한다
- cart 모듈은 member 내부 구현을 직접 참조하지 않고 `member.spi` published API(email→userId)만 사용한다
- `SecurityConfig`에서 cart 경로(REST `/api/v1/cart/**`, View `/cart`·`/cart/**`)에 최소 권한 `ROLE_CONSUMER`가 명시적으로 적용된다(SELLER·ADMIN은 역할 계층으로 함의)
- ViewController는 `web/cart`에 위치하고 cart 내부 구현에 직접 의존하지 않는다
- 관련 테스트가 통과한다

## Test
- `./gradlew test`
- 권장 단위 테스트
  - 장바구니 최초 조회 시 생성
  - 장바구니 담기 성공
  - 같은 variant 재담기 시 quantity 증가
  - quantity 0 이하 실패
  - 구매 불가능 variant 담기 실패
  - 요청 quantity가 stock 초과 시 실패
  - 수량 변경 성공
  - 수량 변경 시 비관적 락을 사용하지 않음
  - 같은 cartItem 동시 수량 변경은 last write wins 정책을 따른다
  - 수량 변경 stock 초과 실패
  - 항목 삭제 성공
  - 다른 사용자 cartItem 접근 실패
  - 장바구니 조회 시 현재 product/variant 표시 정보 조립
  - unavailable item 표시
  - totalQuantity, totalAmount 계산
  - 재고 차감 호출 없음
- 권장 Product SPI 테스트
  - purchasable variant 조회 성공
  - `DRAFT`/`HIDDEN`/`SOLD_OUT` 상품 variant는 구매 불가
  - 비활성 variant 구매 불가
  - 재고 0 variant 구매 불가
  - product/variant Entity를 SPI DTO로 노출하지 않음
- 권장 Member SPI 테스트
  - `MemberDirectory.findUserIdByEmail` email→userId 조회 성공
  - member Entity를 노출하지 않고 scalar userId만 반환
- 권장 동시성 테스트
  - 장바구니 최초 생성 unique 경합(`uq_carts_user_id`) 복구
  - 같은 variant 동시 담기 unique 경합(`uq_cart_items_cart_variant`) 시 재조회 후 quantity 증가
- 권장 REST/Security 테스트
  - `GET /api/v1/cart` CONSUMER 200, 비인증 401
  - `POST /api/v1/cart/items` 성공
  - `POST /api/v1/cart/items` 검증 실패 400
  - `PATCH /api/v1/cart/items/{cartItemId}` 성공
  - `PATCH /api/v1/cart/items/{cartItemId}` 타 사용자 항목 404(존재 은닉)
  - `DELETE /api/v1/cart/items/{cartItemId}` 타 사용자 항목 404(존재 은닉)
  - `GET /api/v1/cart` ROLE 없는 인증 토큰 거부 / CONSUMER·SELLER·ADMIN 200(최소 권한 ROLE_CONSUMER)
  - `DELETE /api/v1/cart/items/{cartItemId}` 성공
  - 응답에 ownerId, product Entity, variant Entity, 로컬 절대 경로 미포함
- 권장 View 테스트
  - `GET /cart` 인증 사용자 렌더링
  - `GET /cart` 비인증 사용자는 `/login` redirect
  - 장바구니 항목 목록 렌더링
  - 수량 변경 폼 CSRF 포함
  - 삭제 폼 CSRF 포함
  - 공개 상품 상세에 장바구니 담기 폼 렌더링
  - 장바구니 담기 성공 redirect
  - 실패 시 flashError 표시
  - nav에 장바구니 링크 포함
- 권장 구조 테스트
  - `web.cart`가 `cart.domain`, `cart.repository`, `cart.service`를 직접 참조하지 않음
  - `cart` 모듈이 `product.domain`, `product.repository`, `product.service`를 직접 참조하지 않음
  - `cart` 모듈이 `member.domain`, `member.repository`, `member.service`를 직접 참조하지 않음
  - `cart` 모듈은 product/member published API(`product.spi`, `member.spi`) 또는 scalar만 사용
  - `cart`가 `product.spi.UserDirectory`를 참조하지 않음(member.spi의 email→userId port만 사용)
  - `ModularityTests.verify()` 통과

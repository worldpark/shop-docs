# 049. 판매자 배송 Phase 2 — 판매자 배송 생성·시작·완료 (소유권 스코핑)

> 출처: 사용자 논의(판매자 배송) Phase 2. Phase 1(`048`)의 order_item owner 스냅샷 + 판매자 주문 조회 위에, **판매자가 자기 상품 항목을 직접 배송 처리**하게 한다. admin 경로는 감독용 유지.
> 선행: **Task 048 완료 필수**(owner_id 스냅샷). api-authorization-rule(최소 권한·소유권 검사) 준수.

## 배경 (코드 확인)
- 현재 배송 생성/시작/완료는 **ADMIN 전용**: `AdminOrderFulfillmentRestController`(`/api/v1/admin/orders/{id}/shipments`), `AdminShipmentRestController`(`.../ship`·`.../deliver`), `OrderFulfillmentService`, admin view `AdminOrderViewController`+`admin/orders.html`.
- `OrderFulfillmentService.createShipment`은 **미발송 항목 전부를 판매자 구분 없이 한 배송**으로 묶고 **`Shipment.seller_id`를 안 채운다**(컬럼은 존재 — 미래 대비 미사용).
- 배송은 **orderItem 단위**(ShipmentItem↔orderItemId)라 **부분 배송·판매자별 분리를 모델이 지원**한다.
- 멀티 배송 주문 상태 롤업은 **이미 구현**: ship은 멱등(preparing→shipping, 이미 shipping 생략), deliver는 **"미배정 항목 0 && 전 배송 delivered → order.markDelivered()"**. → 판매자 부분 배송에도 그대로 재사용(재구현 금지).

## Target / Goal
판매자가 `/seller/orders`에서 **자기 owner_id 항목만**으로 배송을 생성하고 시작(택배사·운송장)·완료할 수 있게 한다. 배송에 **seller_id를 스탬프**하고, 판매자는 **타 판매자 항목을 배송할 수 없다**(소유권 검사). admin 전체 배송 권한은 유지(감독·예외 처리).

## 범위 (Scope)
### 1. 판매자 배송 service (소유권 스코핑 + 그루핑 + seller_id)
- `OrderFulfillmentService`(또는 판매자 전용 경로)에 **판매자 스코핑 배송 생성**: 대상 orderItem을 **요청 판매자 owner_id 것으로 제한**(Phase 1 스냅샷 `order_item.owner_id` 사용 — 런타임 조인 불요). 타 판매자/미존재 항목 지정 시 **404(존재 은닉 — ProductAccessDeniedException·Phase 1 조용한 필터와 정합. plan 049 §1.5)**.
  - 미지정(전부) 시: **해당 판매자의 미발송 항목 전부**로 배송 1건(판매자별 그루핑 자연 성립 — 한 배송=한 판매자).
  - `Shipment.seller_id`를 **요청 판매자 id로 스탬프**(admin이 만든 기존 경로와 구분·집계 가능).
- **판매자 배송 시작/완료**: 대상 shipment의 `seller_id == 요청 판매자` 검증 후 `ship`/`deliver`(기존 `OrderFulfillmentService` 전이·이벤트 재사용). 타 판매자 shipment 조작 차단.
- 주문 행 락(PESSIMISTIC_WRITE)·상태 검증·UNIQUE 경합 처리 등 **기존 createShipment 안전장치 재사용**. 상태 롤업(shipping/delivered)도 기존 멀티배송 로직 그대로.

### 2. 판매자 REST/뷰 진입점
- **REST**(판매자, 소유권 스코핑): 예 `/api/v1/seller/orders/{orderId}/shipments`(생성), `/api/v1/seller/shipments/{shipmentId}/ship`·`/deliver`. principal(email)→ownerId 해석은 facade/service에서(SellerProductFacade 패턴). `/api/v1/seller/**`는 SELLER 권한.
- **뷰**: Phase 1의 `/seller/orders` 화면에 **배송 생성 폼(자기 미발송 항목)·배송 시작(택배사·운송장)·배송 완료 버튼** 추가. 노출 조건은 admin/orders.html 미러(paid/preparing·자기 미발송≥1 등). PRG+flash. CSRF 자동. 인라인 스크립트는 `<main>` 내부.
- **권한 신설이므로 api-authorization-rule 반영**: 모든 판매자 배송 경로에 최소 권한(SELLER) + **서비스 레이어 소유권 검사**(owner_id/seller_id 일치). ADMIN 특례 정책 명시(감독 위해 admin은 전체 가능 유지).

## Non-goals (후속/타 Phase)
- **다중 배송 주문 상태 롤업 재구현** — 이미 구현됨, 재사용만.
- admin 배송 경로 제거 — 유지(감독). admin↔seller 동시 조작 충돌 정합은 Phase 3(`050`).
- 판매자 배송 알림(notification) — Phase 3.
- 기존(admin 생성) shipment의 seller_id 백필 — Phase 3.
- 새 통계/대시보드 지표 — 비범위.

## 검증
- **소유권 매트릭스**(핵심): 판매자A는 자기 항목만 배송 생성/시작/완료. **타 판매자/미존재 항목 지정→404, 타 판매자·seller_id=null(admin) shipment ship/deliver→404(존재 은닉)**. 비SELLER→401/403(권한). ADMIN은 전체 가능(감독). (409는 "만들 배송 없음" 등 상태충돌 전용 — 소유권 위반 아님.)
- **멀티셀러 주문**: 판매자A·B 상품이 섞인 주문에서 각자 자기 항목만 배송 1건씩 생성(seller_id 각자 스탬프), 서로 간섭 없음(부분 배송).
- **상태 롤업 재사용 확인**: A·B 모두 deliver해야 order delivered(기존 deliver-when-all 로직이 판매자 경로에서도 성립) — 통합.
- **브라우저 E2E 필수**: SELLER 로그인→/seller/orders→자기 항목 배송 생성→시작(택배사·운송장)→완료, 타 판매자 항목 비노출·조작 불가([[verify-admin-list-page-features-with-e2e]]).
- 메인: Modulith verify(web→order/product.spi seam 사이클 없음) + 풀 스위트 그린.

## 참고
- admin 선례(미러 대상): `order/controller/{AdminOrderFulfillmentRestController,AdminShipmentRestController}.java`, `order/service/OrderFulfillmentService.java`(createShipment·ship·deliver·롤업), `web/order/AdminOrderViewController.java`, `templates/admin/orders.html`, `order/service/AdminOrderFulfillmentFacadeImpl.java`.
- 소유권: Phase 1 `order_item.owner_id` 스냅샷, `Shipment.seller_id`, `SellerProductFacade`(스코핑 패턴), member.spi(연락처).
- 권한: `security/SecurityConfig.java`(`/api/v1/seller/**`·`/seller/**` SELLER), api-authorization-rule.

# 021 — 배송 완료(delivered): `/admin/orders` 이행 목록에 `shipping` 포함 (Revision 3)

- 대상 Task: `docs/tasks/backend/021-backend-shop-core-order-shipment-delivery-completion-with-view.md`
- 대상 Plan: `docs/plans/backend/021-backend-shop-core-order-shipment-delivery-completion-with-view-plan.md`
- 선행 Revision: revision-1(정합1~5), revision-2(deliver 상태 재검증 순서)
- 결정 일자: 2026-06-12
- 발견 경로: **브라우저 E2E**(`DeliveryCompletionE2eTest`) — 정적 리뷰·MockMvc·Testcontainers 통합이 모두 놓친 통합 결함
- 결정자: 사용자(E2E 결함 보고 → "shipping 포함 수정" 승인)
- 목적: plan이 놓친 **배송 완료 버튼 도달 불가** 결함을 정정한다.

---

## 결정 요약

| # | 항목 | 옛 상태 | 변경 결정 | 심각도 |
|---|---|---|---|---|
| 정합7 | `AdminOrderFulfillmentFacadeImpl.FULFILLABLE_STATUSES` | `["paid", "preparing"]` | `["paid", "preparing", "shipping"]` — 이행 중(미종결) 주문 전체를 `/admin/orders`에 표시 | CRITICAL |

---

## 7. 정합7 — `/admin/orders` 이행 목록에 `shipping` 포함 (CRITICAL)

### 결함 (plan 공백)
- 배송 완료 폼은 `templates/admin/orders.html`에서 `shipment.status == 'shipping'`일 때만 렌더된다(task Backend-View Contract·Files 명시).
- 그런데 배송을 ship하면 **020 rollup으로 주문이 `shipping`으로 전이**된다. `AdminOrderFulfillmentFacadeImpl.listFulfillableOrders`는 `FULFILLABLE_STATUSES = ["paid", "preparing"]`만 조회하므로, `shipping` 주문은 `/admin/orders` 목록에서 **빠진다**.
- 결과: shipment가 `shipping`인 주문이 목록에 없으니 **배송 완료 버튼이 실제 앱에서 영영 렌더되지 않는다**(도달 불가). task Acceptance("admin 배송 완료 폼(CSRF) 렌더링(shipping)")를 충족할 수 없다.

### 왜 plan·리뷰·기존 테스트가 놓쳤나 (검증 공백)
- **plan / plan-reviewer / reviewer**: 템플릿(배송 완료 폼)과 서비스(deliver) 단위에서 정합을 따졌고, "그 shipping 주문이 `/admin/orders` 쿼리에 포함되는가"라는 **목록 쿼리-템플릿 가시성 연결**을 검증하지 않았다.
- **MockMvc View 테스트**(`AdminDeliverViewRenderingTest`): `listFulfillableOrders`를 mock해 `shipping` 주문 모델을 **직접 주입**하므로 실제 상태 필터를 우회 → 통과.
- **Testcontainers 통합 테스트**: `OrderFulfillmentService.deliver`를 **서비스 직접 호출**로 검증(목록 페이지 경유 아님) → 통과.
- **브라우저 E2E**(`DeliveryCompletionE2eTest`): 실제 `/admin/orders` 쿼리 → 템플릿 렌더 전 경로를 통과하므로 "이행 대상 주문이 없습니다."로 **결함을 노출**.

### 결정
- `FULFILLABLE_STATUSES = List.of("paid", "preparing", "shipping")`. 이행 중(아직 `delivered`/`cancelled`/`refunded`로 종결되지 않은) 주문 전체를 `/admin/orders`에 표시한다.
- `delivered`/`cancelled`/`refunded`(종결)은 **제외 유지**(이행 대상 아님).
- 부수 효과(긍정): 멀티 배송에서 첫 배송 ship 후 주문이 `shipping`이 되어 둘째 배송 생성·완료 관리가 막히던 **020 공백도 함께 해소**된다(shipping 주문이 다시 목록에 보이므로).

### 영향 범위
- 변경 파일: `shop-core/.../order/service/AdminOrderFulfillmentFacadeImpl.java`(상수 1줄 + Javadoc 상태 범위 정정).
- 020 ship 워크플로우 무영향(preparing 배송의 ship 폼은 그대로 렌더). 기존 테스트 중 "shipping 주문이 `/admin/orders`에서 제외된다"를 단언하는 케이스 없음(view 테스트는 facade를 mock).
- deliver 도메인/서비스/DTO/REST 로직(정합1~6) 무변경 — 본 정정은 **목록 가시성**만 다룬다.

### 검증
- 브라우저 E2E `DeliveryCompletionE2eTest`: 수정 후 `/admin/orders`에 shipping 주문 표시 → "배송 완료" 클릭(실제 CSRF POST) → flashSuccess → shipment `delivered` + `delivered_at` + 주문 rollup `delivered` DB 교차검증 **통과**.
- 회귀: `AuthJourneyE2eTest`·`CartE2eTest` 그린. 백엔드 슬라이스(`*AdminOrderViewRenderingTest`·`*AdminFulfillment*`·구조·Modulith) 그린.

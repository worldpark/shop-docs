# 020 — 배송 시작(shipping) + ShippingStartedEvent task 설계 정합 6건 수정 (Revision 1)

- 대상 Task: `docs/tasks/backend/020-backend-shop-core-order-shipment-start-shipping-started-event-with-view.md`
- 대상 Plan: 미작성(plan 분해 전, "착수" 상태)
- 선행 Revision: `docs/plans/revisions/backend/019-backend-shop-core-order-shipment-model-and-creation-revision-1.md`(모순1~정합4)
- 결정 일자: 2026-06-11
- 결정자: 사용자(020 배송 시작 task 설계 모순 점검 지시)
- 목적: 020 task를 **이미 구현된 019 산출물**(`OrderFulfillmentService`, `Shipment`, `ShipmentResponse`, `ShipmentItemResponse`) 및 shop-core 코드(`OrderItem.variantId` nullable, `ProductOrderCatalog.getOrderableSnapshots`, `MemberDirectory.findContactByUserId`, `SecurityConfig` admin catch-all, JPA 1차 캐시 의미론)와 대조해 발견한 **설계 정합/결함 6건**의 수정 이유와 기준을 기록한다.

---

## 결정 요약

| # | 항목 | 초기 task 서술 | 변경 결정 | 심각도 |
|---|---|---|---|---|
| 정합1 | 동시 `ship` stale read | "shipment 조회 + 주문 row 잠금" → shipment를 **락 전에 엔티티로 읽는** 흐름으로 해석 가능 | **orderId는 스칼라 projection으로만 읽고**(`findOrderIdById`), **shipment 엔티티 최초 적재는 주문 락 획득 이후**로 강제. "재검증=락 후 fresh 재조회" 명시 | **High**(실버그) |
| 정합2 | `ShipmentResponse` 확장 누락 | Response/소비자 상세가 carrier·tracking·shippedAt 노출을 요구하나 **Files에 DTO 수정 누락** | `ShipmentResponse`에 `carrier`/`trackingNumber`/`shippedAt`(nullable) 추가 + **모든 생성 지점 시그니처 갱신** 명시 | Med-High(컴파일 파급) |
| 정합3 | `markShipping` 멱등 책임 이중 명세 | "이미 `shipping`이면 멱등 처리(**상위 분기 또는 메서드 멱등**)" 이중 서술 | **멱등은 서비스 소유**(preparing일 때만 `markShipping` 호출, 이미 shipping이면 호출 전 200 반환). 도메인 메서드는 `preparing→shipping`만 허용, 그 외 도메인 예외 | Med |
| 정합4 | 멱등 재시작 본문 불일치 미규정 | 이미 `shipping`인 배송에 **다른 운송장번호** 재요청 처리 미정의 | **멱등 판정 키는 shipment 상태(`shipping`)뿐** — 본문 carrier/tracking과 무관하게 기존 값 변경 없이 200 반환(본문 불일치도 오류 아님) | Med |
| 정합5 | P2 해석 불가 정의 과대 | "해석 불가(variant 삭제 등) → 409"를 `getOrderableSnapshots`의 비활성/품절까지 포함할 위험 | **해석 불가 = `variantId` null(SET NULL) 또는 스냅샷 부재(행 삭제)에 한정**. 비활성·품절은 거부 안 함. P2 목적도 '비가역 부작용 방지'가 아니라 '명확한 409'로 정정 | Low-Med |
| 정합6 | `architecture.md` §5 개정 범위 과장 | "§5 주석을 코드보다 먼저 갱신" | **§5는 토픽 표만 있고 필드 상세 부재(event-catalog가 SSOT) → 무변경**. 실질 개정은 `event-catalog.md`만 | Low |

> 검증 사실(코드 대조): `OrderFulfillmentService`(public, 019)·`AdminOrderFulfillmentRestController`·`Shipment`/`ShipmentItem`/`ShipmentResponse`/`ShipmentItemResponse` **존재**. `SecurityConfig` line 78/126에 `/api/v1/admin/**`·`/admin/**`→`hasRole("ADMIN")` **catch-all 존재** → `/api/v1/admin/shipments/**`·`/admin/shipments/**` 자동 포함(신규 보안 규칙 불요). `OrderItem.variantId`는 FK `ON DELETE SET NULL`로 **nullable** → P2 해석 불가 시나리오 실재. `OrderResponse`에 `shipments` 필드 **부재**(정합4/019 이연 정합). `ProductOrderCatalog.getOrderableSnapshots`는 "존재하는 variantId만 반환" + `active`/`purchasable`/`stock` 플래그 동반.

---

## 1. 정합1 — 동시 `ship` stale read 방지(High, 실버그)

- 검증: 엔드포인트가 `/shipments/{shipmentId}/ship`라 **orderId를 모르므로 shipment를 먼저 읽어야** 주문 락을 걸 수 있다. 그래서 코드 순서는 불가피하게 "shipment 읽기 → 주문 락"이다.
- 결함: 락(order)과 판정 대상(shipment)이 **다른 엔티티**다. shipment를 락 전에 **엔티티로** 읽으면, 동일 배송 동시 `ship` 시:
  1. A·B 모두 shipment(`preparing`)를 락 전에 적재.
  2. A가 주문 락 획득 → `shipping` 전이·이벤트 발행·커밋 → 락 해제.
  3. B가 주문 락 획득(직렬화는 정상). 그러나 **JPA 1차 캐시 규칙상** B의 영속성 컨텍스트에 이미 managed인 shipment는 이후 `findById`/JPQL 재호출로도 **DB의 새 값(`shipping`)이 아니라 캐시값(`preparing`)을 반환**한다(`EntityManager.refresh()`만 강제 재적재).
  4. B가 stale `preparing`으로 멱등 가드를 통과 → **`ShippingStartedEvent` 중복 발행** + A의 운송장번호를 B 값으로 덮어씀.
- 핵심: **직렬화는 "B가 A 이후 실행"만 보장할 뿐 "B가 A의 결과를 본다"는 보장하지 않는다.** B는 락 전 stale 스냅샷으로 판정한다. (019 `createShipment`는 락 행위 자체가 order의 최초 적재라 이 문제가 없다 — 020은 락 대상과 판정 대상이 갈라져 발생.)
- 결정(채택 = option 2, 구조적 정확성):
  - **① orderId는 스칼라 projection으로만 조회**(`ShipmentRepository.findOrderIdById` 등 — `findById(...).getOrderId()` 금지: 엔티티가 락 전에 적재됨).
  - **② shipment 엔티티 최초 적재는 반드시 주문 락 획득 이후**(`findById`)에 한다. 락 이전엔 어떤 경로로도 shipment 엔티티를 로드하지 않았으므로 항상 fresh.
  - 대안 비교: option 1(`refresh()`)은 정확성이 **절차적**(호출을 기억해야 맞음, `EntityManager` 의존 추가, 불필요한 2회 SELECT)이라 option 2(**구조적** 정확성 — "락 전엔 엔티티 적재 불가")보다 취약. option 3(shipment 행 직접 `FOR UPDATE`)은 order 락(018 직렬화)과 락 2개를 잡아 락 순서 문제 발생 → 본 설계엔 option 2가 최적.
  - **단서**: (a) 반드시 진짜 projection(스칼라/DTO)일 것, (b) 컨트롤러/facade가 **같은 트랜잭션에서 shipment를 미리 엔티티로 적재하지 않을 것**(업스트림 선적재 시 option 2 보장 무효화).
- 적용: 020 Requirements 이행 오케스트레이션 1·2단계, Files(`ShipmentRepository`), Acceptance(동시 ship), Test(단위 순서·동시성).

## 2. 정합2 — `ShipmentResponse` 추적정보 필드 확장(Med-High, 컴파일 파급)

- 검증: 현재 `ShipmentResponse = {shipmentId, orderId, status, items}`로 **carrier/trackingNumber/shippedAt 부재**. 020 API Response Contract·소비자 상세(`shipping` 배송의 택배사·운송장·배송시작시각)·`OrderResponse.shipments`가 이 필드들을 요구한다.
- 결함: 초기 020 Files에 **`ShipmentResponse` 수정이 누락**(ShipRequest 신규·`OrderResponse.shipments`만 명시). 레코드 필드 추가는 기존 3개 생성 지점(`createShipment`, `getShipments`→`toShipmentResponseWithDetails`, admin facade 변환)을 **전부 컴파일 깨뜨림**.
- 결정: `ShipmentResponse`에 `carrier`(nullable)·`trackingNumber`(nullable)·`shippedAt`(nullable `Instant`)를 추가하고 **모든 생성 지점 시그니처를 갱신**한다(`preparing` 배송은 3필드 null). `seller_id` 등 내부 필드 비노출 유지.
- 적용: 020 Requirements(신규 DTO 확장 bullet), Files(`order/dto/ShipmentResponse` 수정 + 생성 지점 갱신).

## 3. 정합3 — `markShipping` 멱등 책임 단일화(Med)

- 모순: 초기 020은 "이미 `shipping`이면 멱등 처리(**상위 분기 또는 메서드 멱등**)"로 두 갈래를 허용해, 도메인 메서드와 서비스 양쪽에 멱등 책임이 흩어졌다(019 revision §2의 "거부 throw + 멱등 200" 방침과 정합 필요).
- 결정:
  - **멱등 책임은 서비스가 단독 소유**: 서비스는 shipment가 `preparing`일 때만 `markShipping`을 호출하고, 이미 `shipping`이면 호출 전에 현재 `ShipmentResponse`를 `200`으로 반환(이벤트 재발행은 내부 if로 차단).
  - **`Shipment.markShipping`은 `preparing→shipping`만 허용**, 그 외 상태(이미 `shipping`/`delivered`/역방향)는 **도메인 예외**(메서드 자체는 멱등 아님).
  - "상위 분기 또는 메서드 멱등" 이중 명세 제거.
- 적용: 020 Requirements 도메인(`markShipping`) + 이행 오케스트레이션 2단계.

## 4. 정합4 — 멱등 재시작 시 요청 본문 불일치 처리(Med)

- 모순: 이미 `shipping`인 배송에 **다른 carrier/trackingNumber**로 재요청 시 동작 미정의 → 구현자가 "본문 다르면 409"로 해석할 여지.
- 결정: **멱등 판정 키는 shipment 상태(`shipping`)뿐**이다. 이미 `shipping`인 배송에 대한 재요청은 본문 값과 **무관하게 기존 추적정보를 변경 없이 200 반환**한다(배송정보 수정은 020 범위 밖 → 본문 불일치도 오류가 아니고, 기존 값을 덮어쓰지 않는다).
- 적용: 020 이행 오케스트레이션(거부/멱등 단락), API Response Contract, Acceptance(중복 호출).

## 5. 정합5 — P2 해석 불가 정의 한정 + 목적 정정(Low-Med)

- 검증: `OrderItem.variantId`는 `ON DELETE SET NULL`로 nullable. `getOrderableSnapshots`는 "존재하는 variantId만 반환"하되 `active`/`purchasable`/`stock`도 함께 제공.
- 결함: 초기 "해석 불가(variant 삭제 등) → 409"가 **비활성·품절 variant까지 거부**하도록 해석될 위험. 이미 결제·생성된 배송을 품절 사유로 막으면 안 된다.
- 결정:
  - **해석 불가 = `OrderItem.variantId`가 `null`(행 삭제 SET NULL) 또는 스냅샷 목록에 variantId 부재(행 삭제)에 한정.** `active=false`/`purchasable=false`/`stock=0`은 거부하지 않는다(productId 해석만 가능하면 진행).
  - **P2 목적 정정**: 020은 외부 PG 호출이 없어 트랜잭션이 원자 롤백되므로, 사전검증의 목적은 016식 "비가역 부작용(결제 승인) 방지"가 **아니라** 해석 불가 시 `500`(NPE 등) 대신 **명확한 `409` 응답**이다.
- 적용: 020 이행 오케스트레이션 3단계(P2), Acceptance(P2), Test(단위).

## 6. 정합6 — `architecture.md` §5 개정 범위 정정(Low)

- 검증: `docs/architecture.md` §5는 `shipping-started` **토픽 표 1행 + "필드·예시 JSON은 event-catalog 참조" 주석**뿐 — **필드 레벨 내용이 없다**. 발행 모듈(`order`)·소비자(`notification`)도 이미 정확.
- 결함: 초기 020이 "§5 주석을 코드보다 먼저 갱신"이라 적어, 존재하지 않는 §5 필드 편집을 지시.
- 결정: **§5는 무변경**(필요 시 배송 단위 개정을 가리키는 주석 1줄만 허용). 실질 이벤트 계약 개정은 `docs/event-catalog.md`의 `ShippingStartedEvent` 표·예시 JSON에 **`shipmentId`+`items[]`(productId·productName·quantity)** 추가로 한정.
- 적용: 020 Goal intro, Context(이벤트 계약), Constraints, Files(문서), Acceptance.

---

## 7. 파급 정리(021 영향)

| 정합 | 021 파급 |
|---|---|
| 정합1(stale read) | **있음** — 021 `deliver`도 `/shipments/{id}/deliver`로 동일 구조(락 대상 order vs 판정 대상 shipment). 같은 "orderId projection → 락 → shipment 락 후 적재" 패턴을 적용해야 함. 021 task/plan에 반영 권장 |
| 정합2(ShipmentResponse) | **있음** — 021은 `deliveredAt` 노출 필요. 단 020에서 carrier/tracking/shippedAt이 추가되면 021은 `deliveredAt`만 추가(또는 020에서 함께 추가 검토). 021 시점에 확인 |
| 정합3(멱등 책임) | **있음** — `markDelivered`도 동일하게 "서비스 소유 멱등 + 도메인은 단일 전이만" 적용 |
| 정합4(본문 불일치) | 약함 — deliver는 본문 입력이 없거나 최소라 영향 작음 |
| 정합5(P2) | 해당 없음 — deliver는 이벤트 발행이 없으면 P2 불요(021 task 확인) |
| 정합6(§5) | 해당 없음 — 021은 이벤트 미발행이면 event-catalog 개정 없음 |

- 020 수정은 plan 분해 단계로 진행한다. plan에서 추가 모순 발견 시 Revision 2로 잇는다.
- **019 정합(보안 catch-all·락·`Order.getItems()`·018 가드)은 코드 대조에서 문제없음**으로 재확인 — 020 신규 수정 대상 아님.

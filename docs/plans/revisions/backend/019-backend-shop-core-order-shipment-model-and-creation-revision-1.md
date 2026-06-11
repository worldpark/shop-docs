# 019~021 — 배송(Shipment) task 설계 모순 4건 수정 (Revision 1)

- 대상 Task: `docs/tasks/backend/019-backend-shop-core-order-shipment-model-and-creation-with-view.md` (앵커) + `020-...-order-shipment-start-shipping-started-event-with-view.md` + `021-...-order-shipment-delivery-completion-with-view.md`
- 대상 Plan: 미작성(세 task 모두 plan 분해 전, "착수" 상태)
- 결정 일자: 2026-06-11
- 결정자: 사용자(배송 task 설계 모순 점검 지시)
- 목적: 019 task를 실제 shop-core 코드(`OrderRepository.findByIdForUpdate`, `BaseEntity`, V1 트리거, `OrderCancellationImpl` 취소 가드, `Order`↔`OrderItem` 구조, `SecurityConfig` 규칙 순서, `OrderFacade`/`OrderResponse`)와 대조해 발견한 **설계 모순/결함 4건**의 수정 이유와 기준을 기록한다. ②④는 020/021에도 파급되므로 세 task를 함께 정정한다.

---

## 결정 요약

| # | 항목 | 초기 task 서술 | 변경 결정 | 근거 |
|---|---|---|---|---|
| 모순1 | `shipments.updated_at` 갱신 | "DB 트리거 소유 — BaseEntity 읽기전용 매핑"이라 적었으나 V4 요구에 **트리거 생성 지시 누락** | V4에 **`trg_shipments_set_updated_at` BEFORE UPDATE 트리거**(기존 `set_updated_at()` 함수 재사용) 생성을 명시 | `BaseEntity`가 `updated_at`을 `updatable=false`로 매핑(검증) → 트리거 없으면 020/021 상태 전이 시 `updated_at`이 **영원히 stale**(실버그) |
| 모순2 | 거부 결과 표현 | `Outcome`(CREATED/REJECTED 등) **값 패턴 권장** + 동시에 "거부는 부작용 전 판정이라 **던져도 무방**" → 제어흐름 **이중 서술** | 거부는 **`OrderFulfillmentConflictException` 직접 throw**, Outcome 값 패턴 **미채택**. 멱등(이미 목표 상태)은 **현재 상태 DTO를 200으로 반환**(내부 if 분기, 이벤트 재발행만 차단) | 018 Outcome은 **payment→order.spi cross-module 경계**에서 값 매핑이 필요했기 때문. 이행 서비스는 **order 모듈 내부**에서 order 자신이 호출 → 경계 없음 → 값 indirection 불필요·단순 throw가 명확. (016/017과 달리 분리 예정도 없음) |
| 모순3 | 거부 상태코드 | "빈 대상/전부 배정됨"을 Requirements `400/409`·Response `400`·Acceptance `409/400` 으로 **세 곳 불일치** | **입력 오류(미존재·타 주문 소속 orderItemId) = 400**, **상태 충돌(미발송 항목 0=만들 게 없음 / 이미 배정된 항목 지정) = 409** 로 분리 고정 | error-response-rule·HTTP 의미론(입력 검증 vs 상태 충돌). 016(금액 불일치 400)·018(이행단계 409) 선례 |
| 정합4 | 소비자 배송 목록 표시 시점 | 019에서 소비자 상세에 **배송 목록 블록 + `OrderResponse.shipments`** 추가 | 019 소비자 측은 **기존 rollup `order.status` 라벨로만**(detail/list에 이미 존재) 두고, **배송 목록 블록·`OrderResponse.shipments` 추가는 020으로 이연** | 019 단계 배송은 `preparing`뿐 → 소비자에게 보일 정보가 rollup status와 **중복**. 의미 있는 추적정보(carrier/tracking)는 020에 등장 → 단계 분할 취지(각 task=의미 있는 단일 증분)에 정합. **admin 화면의 배송 표시는 019 유지**(admin facade, 소비자 `OrderResponse`와 무관) |

> 검증 사실(코드 대조): `findByIdForUpdate`는 `Optional<Order>` + `@Lock(PESSIMISTIC_WRITE)`. `OrderCancellationImpl` 가드 = `cancelled/refunded`→ALREADY_CANCELLED, `preparing/shipping/delivered`→REJECTED(409), `pending/paid`→정상. `Order`는 `@OneToMany List<OrderItem> items`(→ `order.getItems()`로 미발송 판정). `SecurityConfig`는 `/admin/**`·`/api/v1/admin/**`가 `/orders/**`·`/api/v1/orders/**`보다 **먼저** 선언돼 admin 경로 우선 매칭(문제 없음). V1은 `set_updated_at()` 함수 + 테이블별 `CREATE TRIGGER`. → 모순1/2/3/4만 수정 대상, 보안·락·구조는 정합 확인됨.

---

## 1. 모순1 — `shipments.updated_at` DB 트리거 생성 명시 (필수, 019)

- 검증: `BaseEntity`는 `created_at`/`updated_at`을 `insertable=false, updatable=false`로 매핑(JPA 읽기전용). V1은 `set_updated_at()` plpgsql 함수와 `orders`용 `trg_orders_set_updated_at BEFORE UPDATE` 트리거로 `updated_at`을 DB가 갱신한다.
- 결함: 초기 019는 `shipments`의 created/updated를 "DB 트리거 소유"라 적었으나, **V4 마이그레이션 요구사항에 트리거 생성 지시가 없었다.** 트리거 없이는 `shipments.updated_at`이 INSERT 시 default(now()) 이후 **UPDATE에서 절대 갱신되지 않는다**(020 `ship`/021 `deliver`의 상태 전이가 row를 UPDATE하므로 직접 영향).
- 결정: V4에 다음을 **명시**한다.
  ```sql
  CREATE TRIGGER trg_shipments_set_updated_at
      BEFORE UPDATE ON shipments
      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  ```
  기존 `set_updated_at()` 함수를 재사용한다(함수 재정의 불필요). `shipment_items`는 `updated_at`이 없으므로(불변·append) 트리거 불필요.
- 적용: 019 Requirements/Constraints의 V4 항목과 Acceptance에 트리거 생성을 추가.

## 2. 모순2 — 거부는 직접 throw, Outcome 값 패턴 미채택 (019·020·021)

- 모순: 초기 task들은 결과를 `Outcome`(예: 019 `CREATED/REJECTED`, 020 `SHIPPED/ALREADY_SHIPPED/REJECTED`, 021 `DELIVERED/ALREADY_DELIVERED/REJECTED`) **값**으로 권장하면서, 동시에 "거부는 부작용 전 판정이라 **던져도 무방**"이라 적어 **거부의 제어흐름이 값/예외 두 갈래**로 서술됐다.
- 근거 분석: 018이 `OrderCancellation`에 Outcome을 둔 이유는 **payment(소비 모듈)가 `order.spi`를 호출하는 cross-module 경계**에서 예외 대신 값으로 결과를 넘겨 호출자가 매핑하기 위함이다(017 revision §3의 forward-compat 이음매와 동일 맥락 — 미래 payment 분리 대비). **배송 이행 서비스(`OrderFulfillmentService`)는 order 모듈 내부**에서 order 자신의 REST(`ServiceResponse`)·View facade가 직접 호출하며, 분리 예정도 없다 → **cross-module 값 매핑의 이유가 없다.**
- 결정:
  - **거부(잘못된 상태/전이/항목) = `OrderFulfillmentConflictException`(409) 등 도메인 예외를 서비스에서 직접 throw**한다. 부작용 발생 전에 판정하므로 트랜잭션 롤백할 부작용이 없어 안전(017식 C1 간접화 불필요 — 본 흐름은 "성공=커밋 / 거부=부작용 전 throw").
  - **멱등(이미 목표 상태: 020 이미 `shipping`, 021 이미 `delivered`)** 은 예외가 아니라 **현재 상태 DTO를 `200`으로 반환**한다. 이벤트 재발행 차단은 내부 if 분기로 처리(별도 Outcome 값 불요).
  - `Outcome` enum은 도입하지 않는다(019/020/021 공통).
- 적용: 세 task의 "Outcome 값 패턴 권장" 문구를 위 방침으로 교체. 멱등 200 / 거부 409 throw로 통일.

## 3. 모순3 — 거부 상태코드 400/409 분리 고정 (019)

- 모순: 019가 "빈 대상/전부 배정됨"의 상태코드를 Requirements `400/409`, API Response Contract `400`, Acceptance `409/400` 으로 제각각 적었다.
- 결정: 다음으로 고정한다.
  - **400 (입력 오류)**: 지정한 `orderItemId`가 **존재하지 않거나 해당 주문 소속이 아님**(잘못된 요청 입력).
  - **409 (상태 충돌)**: 대상이 **미발송 항목 0건**(전부 이미 배정되어 만들 배송이 없음) 또는 **지정 항목이 이미 다른 배송에 배정됨**(현재 상태와 충돌).
- 근거: error-response-rule과 HTTP 의미론(요청 자체의 유효성=400 vs 현재 리소스 상태와의 충돌=409). 016(클라이언트 금액 불일치 400)·018(이행단계 취소 409)이 같은 구분을 사용.
- 적용: 019 Requirements/Response Contract/Acceptance의 해당 문구를 위 기준으로 통일.

## 4. 정합4 — 소비자 배송 목록 표시를 020으로 이연 (019·020)

- 관찰: 019 단계에서 shipment의 유일한 상태는 `preparing`이다. 주문 rollup으로 `order.status`도 `preparing`이 되고, 이는 `templates/order/detail.html`·`list.html`이 **이미 라벨로 표시**한다(검증). 따라서 019에서 소비자에게 추가로 "배송 목록 블록"을 그리면 rollup status와 **정보가 중복**되고, 의미 있는 추적정보(carrier/trackingNumber/shippedAt)는 **020에서야 생긴다.**
- 결정:
  - **019 소비자 측 = 기존 rollup `order.status` 라벨로만** 둔다(신규 작업 없음 — 라벨은 이미 존재). `OrderResponse`에 `shipments` 필드 추가·`OrderDtoMapper` 수정·소비자 상세의 배송 목록 블록은 **020으로 이연**한다.
  - **019 admin 측은 그대로** 배송 현황·생성 폼을 표시한다(admin facade 경유 — 소비자 `OrderResponse`와 무관).
  - 020은 배송 시작(추적정보 등장)과 함께 `OrderResponse.shipments` 추가 + 소비자 상세 배송 목록 블록(추적정보 포함)을 신설한다.
- 근거: 단계 분할의 취지(각 task = 의미 있는 단일 증분). 거의 빈 UI 블록 추가를 피하고, 소비자 배송 표시를 추적정보가 생기는 시점(020)에 한 번에 도입.

---

## 5. 파급 정리 (task별 수정 범위)

| Task | 모순1 | 모순2 | 모순3 | 정합4 |
|---|---|---|---|---|
| 019 | ✅ V4 트리거 추가 | ✅ throw + 멱등 200 | ✅ 400/409 분리 | ✅ 소비자 배송 블록·`OrderResponse.shipments` 020 이연 |
| 020 | — (스키마 무변경) | ✅ throw + 멱등 200 | — | ✅ 소비자 배송 목록 블록·`OrderResponse.shipments` 신설 |
| 021 | — | ✅ throw + 멱등 200 | — | — |

- 보안(`/admin/**` 우선 매칭)·락(`findByIdForUpdate Optional<Order>`)·`Order.getItems()` 미발송 판정·018 가드 정합은 **코드 대조에서 문제없음**으로 확인 → 수정 대상 아님.
- 본 revision 반영 후 세 task는 plan 분해 단계로 진행한다. plan에서 추가 모순 발견 시 Revision 2로 잇는다.

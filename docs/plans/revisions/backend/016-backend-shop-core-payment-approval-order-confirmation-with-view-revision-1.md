# 016 — 결제 plan 경계·동시성·조회분리·테스트 보강 (Revision 1)

- 대상 Task: `docs/tasks/backend/016-backend-shop-core-payment-approval-order-confirmation-with-view.md`
- 대상 Plan: `docs/plans/backend/016-backend-shop-core-payment-approval-order-confirmation-with-view-plan.md`
- 결정 일자: 2026-06-08
- 결정자: 사용자(plan 점검 피드백)
- 목적: 초기 plan의 4개 결함(web 타입 누수, PG 전 직렬화 부재, 조회/검증 결합, 이벤트 payload 테스트 누락)을 수정한 이유와 구현 기준을 기록한다.

---

## 결정 요약

| # | 항목 | 초기 plan | 변경 결정 | 근거 |
|---|---|---|---|---|
| 1 | View facade 시그니처 | `PaymentFacade.pay(email, orderId, OrderPaymentForm)` — web 타입을 spi가 수신 | `PaymentFacade.pay(email, orderId, PaymentRequest)` — payment 소유 DTO만 수신, `OrderPaymentForm → PaymentRequest` 변환은 web 책임 | `web → domain.spi` 단방향(architecture-rule) 위반 방지 |
| 2 | 동시 결제 직렬화 | PG 승인이 주문 row 락보다 먼저 → 동시 2건 모두 PG 승인 가능 | **PG 호출 전 `payments` `ready` row INSERT + `uq_payments_order_id` 선점**으로 직렬화. 경합 측 `PaymentInProgressException`(409). `PaymentGatewayPort`에 `idempotencyKey` 추가 | mock은 부작용 없으나 plan이 "실 PG 전환 안전성"을 주장 → 더블 charge 위험 제거 |
| 3 | 조회 ↔ 이벤트 완결성 검증 | `getPaymentStatus`가 `getPayableOrder`(완결성 409) 재사용 | `OrderPaymentReader`를 **`getPayableOrder`(결제 전용, 409) / `getOrderSnapshot`(상태 조회 전용, 소유권 404만)** 로 분리 | 상태 조회·주문 상세 렌더링이 payload 구성 실패로 깨지면 안 됨 |
| 4 | 이벤트 payload 테스트 | `memberEmail/memberName/items[].productId/totalAmount/currency`만 언급 | `eventId`·`occurredAt`·`productName`·`quantity`·`unitPrice` 포함 **전 필수 필드** + **`productName/quantity/unitPrice`의 `order_items` 스냅샷 출처** 검증 명시 | event-catalog 필수 필드 누락·스냅샷 회귀 방지 |

---

## 1. web 타입 누수 차단 (#1)

- 초기 plan은 `payment.spi.PaymentFacade`가 web 모듈 타입 `OrderPaymentForm`을 파라미터로 받았다. 이는 `payment.spi`(도메인 published port)가 `web`을 역참조하게 만들어 `web → domain.spi` 단방향 의존 규칙을 깬다.
- 변경:
  - `PaymentFacade.pay(String email, long orderId, PaymentRequest request)` — payment 소유 `payment.dto.PaymentRequest`만 수신.
  - `OrderPaymentForm`(web 소유) → `PaymentRequest` 변환은 web 결제 핸들러(web 계층)가 수행.
  - `PaymentFacadeImpl`은 `PaymentRequest → PaymentCommand` + `MemberDirectory.findUserIdByEmail`만 담당.
- **이 결정을 rule로 승격**: `docs/rules/architecture-rule.md`("shop-core 모듈 간 통신")에 "published API(spi/facade) 시그니처는 web 등 호출자 계층 타입을 받지 않는다. 변환은 호출자(web) 책임" 규칙을 추가했다(전 작업 공통 적용).

## 2. PG 호출 전 직렬화 — ready row 선점 (#2)

- 초기 plan의 처리 순서는 PG 승인(4단계) → payments 기록(5) → 주문 row 락(6, confirmPaid)이었다. 주문 row 락이 PG 뒤에 있어 **동일 주문 동시 2건이 모두 PG 승인**될 수 있었다. mock은 부작용이 없지만 plan이 실 PG 전환 안전성을 주장하므로 위험하다.
- 변경(8단계로 재정의):
  1. 준비 스냅샷(`getPayableOrder`) — 소유권 404, 이벤트 완결성 사전검증 409
  2. 멱등/충돌 1차 판정
  3. 금액 검증(400)
  4. **`payments` ready row INSERT — `uq_payments_order_id`로 PG 호출 전 직렬화.** 경합 측은 `DataIntegrityViolationException` → 재조회 후 paid 멱등(200)/ready 409(`PaymentInProgressException`)
  5. PG 승인(`authorize(..., idempotencyKey)`) — 선점 1건만 도달
  6. ready→paid 전이(`markPaid`)
  7. `OrderConfirmation.confirmPaid` — orders row `PESSIMISTIC_WRITE` + 권위 재검증 + `OrderCompletedEvent` 발행
  8. 커밋(실패 시 ready 포함 전체 롤백)
- 자원 획득 순서 **payments(uq) → orders(락)** 일관 → 데드락 없음. 실 PG 전환 시 `idempotencyKey`로 프로세스 재시도까지 at-most-once.
- 역할 비충돌: `uq`/ready 선점 = 결제 단일화·PG 단일 호출, `confirmPaid` orders 락 = 주문 상태 권위 전이·이벤트 발행.
- **남은 리스크(017로 이관)**: stale `ready`/`failed` row 만료·정리(TTL/cleanup)는 016/017이 단일 동기 트랜잭션이라 미발생하나, 비동기 PG·트랜잭션 비정상 중단 대비가 필요. `docs/tasks/backend/017-...-payment-failed-event.md` Context/Constraints에 기록했다.

## 3. 조회/명령 경로 분리 (#3)

- 초기 plan은 `getPaymentStatus`가 `getPayableOrder`(productId/연락처 해석 실패 시 409)를 재사용했다. 상태 조회나 주문 상세 렌더링이 이벤트 payload 구성 실패로 깨질 수 있었다.
- 변경: `OrderPaymentReader`를 2메서드로 분리.
  - `getPayableOrder(orderId, requesterUserId)` — 결제(pay) 전용. 소유권 404 + 이벤트 완결성 사전검증 409.
  - `getOrderSnapshot(orderId, requesterUserId)` — 상태 조회 전용. 소유권 404 + 상태/금액 스냅샷만. **409를 던지지 않는다.**
- `getPaymentStatus`·주문 상세는 `getOrderSnapshot`을 사용 → payload 구성 실패와 무관하게 동작.

## 4. 이벤트 payload 테스트 보강 (#4)

- 초기 plan 테스트는 `memberEmail/memberName/items[].productId/totalAmount/currency`만 언급했다.
- 변경: `OrderConfirmationImplTest`·`PaymentOutboxIntegrationTest`가 `OrderCompletedEvent`의 **전 필수 필드**(`eventId`·`occurredAt`·`orderId`·`orderNumber`·`memberId`·`memberEmail`·`memberName`·`items[].productId`·**`items[].productName`·`items[].quantity`·`items[].unitPrice`**·`totalAmount`·`currency`·`orderedAt`)를 검증하고, **`productName/quantity/unitPrice`가 `order_items` 주문 시점 스냅샷 값과 일치**함을 단언(주문 후 product 변경 무영향)하도록 명시했다.

---

## rule 반영 결과

- **#1만 rule로 승격**: `architecture-rule.md`에 포트 시그니처 web 타입 금지 규칙 추가.
- #2(외부호출/ready 선점/idempotency)는 결제 통합 특화라 plan·017에만 기록(rule화 보류 — 과도한 일반화 회피).
- #3(조회/명령 분리)·#4(이벤트 payload 테스트)는 이번 plan/Task에 반영하고 rule화는 보류(추후 재발 시 재검토).

---

## 신규 예외 (016 최종)

`PaymentAmountMismatchException`(400), `OrderConfirmationConflictException`(409), `PaymentEventResolutionException`(409), `PaymentInProgressException`(409, 신규 — ready 선점 경합), `AmountConversionException`(500). `OrderNotFoundException`(404, 015) 재사용.

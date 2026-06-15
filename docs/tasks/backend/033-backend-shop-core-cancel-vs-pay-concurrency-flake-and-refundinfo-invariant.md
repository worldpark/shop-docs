# 033. shop-core 취소 vs 결제 동시성 정합성 버그 해소 (재고 누수·취소 덮어쓰기) + 취소 SPI refundInfo 불변식 강화

> 출처: **Task 031 쿠폰 검증 중 발견**. 전체 스위트(`./gradlew test`)에서 `OrderCancellationConcurrencyIntegrationTest > cancelVsPay_serialized_onlyOneSucceeds`가 간헐 실패. **clean HEAD(쿠폰 변경 전) worktree에서도 동일 재현** → Task 031 회귀가 아닌 **기존 잠재 결함**으로 확정. 쿠폰과 무관(해당 주문엔 쿠폰 없음 → `restoreByOrder`는 0행 no-op).
>
> **⚠️ 실측 정정(2026-06-15, 12회 반복 실행)**: 본 실패는 "테스트 단정만 잘못된 flake"가 아니라 **실제 데이터 정합성 버그**다. 실패 시(12회 중 7회) 최종 상태가 일관되게 `order=paid, payment=paid(10000, 미환불), stock=11(과복원)`이며 **결제·취소가 둘 다 성공(successCount==2)**한다. 즉 취소가 재고를 복원·커밋한 뒤 결제 확정이 **이미 커밋된 취소를 paid로 덮어써** 결제완료 주문인데 재고가 복원돼 누수된다. 이 경합은 **production 결제 경로(`paymentServiceResponse.pay`)** 를 그대로 사용해 재현되므로 production도 안전하지 않다(아래 Context 재작성 참조). 통과 시(5회)는 `order=cancelled, stock=11, payments=[]`(취소 승, 정상).

## Target
shop-core (order·payment 동시성 — 취소/결제 직렬화 경로 + 해당 통합 테스트)

> 본 Task는 **테스트 flake의 근본 원인 해소 + 취소 SPI 계약의 잠재 불변식 갭 강화**에 한정한다. 결제/환불 금액·PG 로직(016/017/018)·이벤트 계약·DB 스키마는 무변경. 신규 이벤트/notification 없음.

---

## Goal
동시 **주문 취소 vs 결제**가 경합할 때, 시스템이 일관된 단일 종착 상태(취소 또는 결제완료, 필요 시 환불)로 수렴하고 **회계·재고 정합**이 깨지지 않음을 보장한다. 구체적으로 **결제 확정(`confirmPaid`)이 락 획득 후에도 stale 상태로 이미 커밋된 취소를 덮어쓰는 직렬화 구멍**을 막아, 결제완료 주문에 재고가 복원·누수되는 정합성 위반을 제거한다. 그리고 그 불변식을 **결정적(deterministic)으로 검증**하도록 `OrderCancellationConcurrencyIntegrationTest`를 정합성 기반 단정으로 바로잡는다. 더불어 취소 SPI(`OrderCancellation.cancel`)가 **호출자가 넘긴 `refundInfo`를 맹신**하는 부차적 계약 취약성에 방어 가드를 추가한다.

## Context (근본 원인 분석 — 코드 + 실측 대조)
> 아래는 12회 반복 실행 실측(실패 7/12)에 근거한다. 통과: `order=cancelled, stock=11, payments=[]`. 실패: `success=2, order=paid, payment=paid(10000·미환불), stock=11(과복원)`.

- **진짜 근본 원인 — 결제 확정 경로의 lock-without-refresh(영속성 컨텍스트 stale 읽기)**:
  - 결제: `PaymentService.pay`(`@Transactional`) — ① `orderPaymentReader.getPayableOrder(...)`가 **managed `Order`(pending) 엔티티를 pay 트랜잭션의 영속성 컨텍스트에 적재**(`OrderPaymentReaderImpl`은 readOnly tx이나 pay의 진행 중 tx에 조인) → ② PG auth → ③ `OrderConfirmation.confirmPaid`가 `orderRepository.findByIdForUpdate`(`PESSIMISTIC_WRITE`)로 락을 잡지만, **이미 영속성 컨텍스트에 적재된 동일 `Order` 인스턴스를 DB에서 refresh하지 않고 그대로 반환**(JPQL 쿼리 결과는 managed 엔티티 상태를 덮어쓰지 않음) → ④ `Order.markPaid()`가 **stale `pending`** 기준으로 실행되어 `pending → paid` 커밋.
  - 결과: 취소 스레드가 먼저 `pending → cancelled`(+재고 복원 +`OrderCancelledEvent`)를 **커밋**해도, 결제 스레드의 confirmPaid는 락을 잡고도 **stale pending**을 보고 `markPaid`로 **취소를 paid로 덮어쓴다**. 최종 `order=paid, payment=paid, stock=11(취소가 복원한 재고가 결제완료 주문에 남아 누수)`. **결제·취소 둘 다 성공(successCount==2)**.
  - 즉 `PESSIMISTIC_WRITE` 락은 잡히지만, 락 획득 후 **stale 캐시 엔티티로 상태 판정**을 하므로 직렬화가 무력화된다. 이 경합은 **production 결제 경로(`paymentServiceResponse.pay`)** 를 그대로 태워 재현되므로 **production도 안전하지 않다**(이전 "production은 이미 안전" 서술은 실측으로 반증됨).
- **테스트 단정도 부정확(부차)**:
  - cancel-vs-pay 케이스는 cancel을 하위 SPI `orderCancellation.cancel(orderId, userId, new RefundInfo(false, 0L, "KRW"))`로 직접 호출하고(test line 199), `assertThat(successCount.get()).isEqualTo(1)`(test line 240)로 "둘 중 하나만 성공"을 단정한다. 그러나 위 정합성 버그로 둘 다 성공(2)이 되어 깨진다. 단정을 **카운트가 아니라 종착 상태·재고·payment 회계 정합**으로 바꿔야 결정적이다(버그 수정 전엔 정합성 단정이 RED여야 한다 — 진짜 버그를 가리지 않게).
  - ※ 이전 문서가 적은 "cancel이 paid를 보고 `markRefunded`로 `paid → refunded` 성공" 메커니즘은 **틀렸다**: 테스트는 `refunded=false`를 넘기므로 `doCancel`은 `markRefunded`가 아니라 `markCancelled`를 호출하고, `Order.markCancelled`는 paid에서 예외다(`Order.java` line 206~208). 실제 성공-2는 위 stale 덮어쓰기로 발생하며 최종 상태는 refunded가 아니라 **paid**다(실측).
- **부차적 계약 갭(낮은 심각도 — 이 버그의 원인은 아님)**:
  - `OrderCancellation.cancel(orderId, userId, refundInfo)`는 `refundInfo`를 검증 없이 신뢰한다. 현재 유일 production 호출자 `PaymentService.cancel`이 항상 락 아래에서 올바른 `refundInfo`를 도출하므로 정상 흐름엔 문제가 없으나, "호출자가 락+도출을 정확히 한다"는 암묵 전제에 의존해 향후 리팩터링/신규 호출자에 취약하다. **이는 본 flake의 원인이 아니며**(원인은 결제측 stale 읽기), defense-in-depth로만 다룬다.

## 문제 요약
1. **정합성 버그(주원인)**: `confirmPaid`가 `PESSIMISTIC_WRITE` 락을 잡은 뒤에도 **영속성 컨텍스트에 먼저 적재된 stale `Order`(pending)** 를 refresh 없이 사용해, **이미 커밋된 취소를 `markPaid`로 덮어쓴다** → 결제완료 주문 + 재고 과복원(누수) + 결제·취소 동시 성공. production 결제 경로에서 재현.
2. **테스트 단정 부정확(부차)**: cancel-vs-pay가 `successCount==1`(카운트)을 단정해 정합성 위반을 "flake"로 오인 → 단정을 종착 상태·재고·payment 회계 정합으로 교체 필요.
3. **계약 취약성(부차, 본 버그 원인 아님)**: `OrderCancellation.cancel`이 `refundInfo`를 맹신 → defense-in-depth 가드 부재.

## plan 확정 필요 (수정 방향 — 두 갈래 이상이므로 plan에서 확정)
> **수정 방향이 둘 이상이라 plan 단계에서 확정하고, 방향이 갈리면 사용자 승인을 받는다.** 본 Task는 production 정합성 버그 수정을 포함하므로(아래 1) 기존 "production 무변경" 전제를 **결제 확정 경로에 한해 완화**한다.
>
> **✅ 사용자 확정(2026-06-15): 1-A(락 후 refresh/재판정) + 2-D(production 경로 + 정합성 단정) + 3-F(doCancel 가드 추가).** 아래 각 항목의 권장안 채택. 대안은 미채택(참고용 보존).

1. **결제 확정 stale 읽기 수정(주 수정 — production 코드)** — 택1:
   - (A) **락 후 refresh**: `confirmPaid`가 `findByIdForUpdate`로 락을 잡은 직후 `EntityManager.refresh(order)`(또는 `findByIdForUpdate`에 refresh 보장)로 **DB 최신 상태를 다시 읽고** status를 재판정 → 취소가 먼저 커밋했으면 `currentStatus != pending` 분기로 **REJECTED**(결제 실패)되어 덮어쓰기 차단.
   - (B) **pre-load 제거**: `PaymentService.pay`가 `getPayableOrder`로 `Order` 엔티티를 영속성 컨텍스트에 적재하지 않도록(스칼라 스냅샷/별도 readOnly 트랜잭션으로 분리) 하여 confirmPaid의 `findByIdForUpdate`가 항상 fresh 로드되게 한다.
   - (C) **@Version 낙관락 도입**: orders에 `@Version` 추가로 stale 덮어쓰기를 충돌로 차단. **단 DB 스키마 변경 → 본 Task 범위/ADR-005 단순화 원칙과 충돌, 비권장**.
   - **권장: (A)** — 최소 변경으로 직렬화 보장(락 의미를 살림), 스키마 무변경. confirmPaid 외 경로(`OrderCancellation`/`OrderFulfillment`)는 첫 읽기가 곧 락 읽기라 동일 취약점 없음(확인 필요). 단 confirmPaid의 멱등(`paid`)·REJECTED 분기 동작이 refresh 후에도 보존되는지 검증.
2. **테스트 수정 방식** — 택1(또는 조합):
   - (D) **production 경로 + 정합성 단정**: cancel 스레드도 가능하면 `PaymentServiceResponse.cancel` 등 production 경로로 호출하고, 단정을 **"최종 order/payment/stock이 단일 정합 상태(① cancelled+복원+payment 없음/환불, 또는 ② paid+미복원+payment paid)"** 로 재구성. 카운트 단정 제거.
   - (E) **raw SPI 유지 + 정합성 단정**: 호출 구조는 두되 단정만 정합성 기반으로 교체.
   - **권장: (D)**. 어느 쪽이든 **수정 1 적용 전에는 정합성 단정이 RED**(현 버그 노출)여야 하고, 적용 후 GREEN이어야 한다(verification-gate RED 확인).
3. **계약 가드(부차, defense-in-depth)** — 택1:
   - (F) **`OrderCancellation.doCancel`에 방어 가드**: 락 재조회 상태가 `paid`인데 `refundInfo.refunded()==false`(또는 refunded=true인데 금액 불일치)면 예외로 종결 거부. production 정상 흐름 무영향(현 `PaymentService.cancel`은 항상 올바른 refundInfo 전달). ※ `Outcome.REJECTED` 반환은 `PaymentService.cancel` line 267~269가 "락 불변식 위반"으로 IllegalStateException을 던지는 기존 의미와 겹치므로, **예외 throw로 통일** 권장.
   - (G) **문서화만**: SPI Javadoc에 호출 계약 명시, 가드 미추가.
   - **권장: (F)** — 저비용 영구 가드. 단 주 수정(1)이 본 flake의 실제 해결책이며, (F)는 부차.

## Requirements
- **정합성 버그 제거(주)**: 결제 확정(`confirmPaid`)이 **락 후 fresh 상태로 재판정**하여, 이미 커밋된 취소를 paid로 덮어쓰지 않는다. 결제완료 주문에 취소 재고 복원이 누수되지 않는다(stock 과복원 0).
- **flake 제거**: cancel-vs-pay 케이스가 **반복 실행에서 결정적으로 통과**한다(카운트 단정 → 정합성 단정). 동시 취소 2건 케이스는 무변경 유지(이미 안정).
- **정합 불변식 검증**: 취소-결제 경합 후 종착 상태가 **단일 정합 조합**이다 — ① `cancelled`(+재고 복원 1회 + payment 없음/환불) **또는** ② `paid`(+재고 미복원 + payment paid) 중 정확히 하나. "paid인데 재고 복원" 같은 혼합 상태가 발생하지 않는다.
- **(plan F 채택 시) 방어 가드**: 락 재조회 상태와 `refundInfo`가 모순(paid인데 refunded=false, 또는 refunded=true인데 금액 불일치)이면 종결을 거부하고 롤백(예외). production 정상 흐름은 무영향.
- **변경 최소화**: 수정은 **결제 확정 경로의 stale 읽기 해소(plan 1)** 와 테스트 단정, (선택) 취소 가드에 한정한다. **환불액 산정·PG 호출·상태머신 전이 로직 자체는 불변**(락 후 fresh 재판정은 기존 status 분기를 살리는 가산). `expirePendingOrder` 경로는 무변경.

## Constraints
- **결제/환불 금액·PG 로직 무변경**(016/017/018): 환불액 산정·PG 호출·상태머신 **전이 규칙**은 불변. 수정은 "락 후 fresh 상태 재판정"(직렬화 정확화)과 모순 입력 거부의 가산만 허용 — 정상 경로 결과 불변.
- **이벤트/notification 무변경**: `OrderCancelledEvent`/`OrderCompletedEvent` 계약·발행 시점 불변. `event-catalog.md`/§5 불변.
- **DB 스키마 무변경**: 신규 마이그레이션 없음. `@Version` 컬럼 도입(plan 1-C)은 스키마 변경이라 **비채택**(plan 1-A refresh로 해결 — ADR-005 단일 DB·PESSIMISTIC_WRITE 유지).
- **동시성 모델 유지**: 분산락 미도입(ADR-005 단일 DB). 기존 `findByIdForUpdate` PESSIMISTIC_WRITE를 유지하되, **락 획득 후 stale 캐시 엔티티가 아닌 fresh 상태로 판정**하도록 정확화한다(새 락/전략 도입 아님 — 기존 락의 의미를 살림).
- **회귀 금지**: 취소/결제/만료 관련 기존 테스트(016/017/018/022)·다른 동시성 테스트 그린 유지. 특히 `confirmPaid` 멱등(`paid`)·금액 불일치 REJECTED 분기가 refresh 후에도 동일 동작해야 한다.
- **flaky 단정 금지**: 새 단정은 타이밍 비의존(결정적)이어야 한다. 재시도/`@RepeatedTest`로 버그를 덮지 않는다(수정 1 전에는 정합성 단정이 RED여야 함).

## Files
> 정확 경로/범위는 plan 확정.
- (수정, **주**) `order/service/OrderConfirmationImpl.java`(`confirmPaid`) — 락 획득 후 fresh 상태 재판정(plan 1-A: `EntityManager.refresh` 또는 fresh 재조회)로 stale `pending` 덮어쓰기 차단. 멱등/REJECTED 분기 보존.
- (수정/검토) `payment/service/PaymentService.java`(`pay`) / `order/service/OrderPaymentReaderImpl.java`(`getPayableOrder`) — (plan 1-B 채택 시) `Order` 엔티티 pre-load 제거. 1-A 채택 시 로직 무변경(필요 시 주석 보강).
- (수정) `src/test/java/com/shop/shop/order/service/OrderCancellationConcurrencyIntegrationTest.java` — cancel-vs-pay를 정합성 단정(order/payment/stock 단일 정합 조합)으로 교체(plan 2). 수정 1 적용 전 RED 확인.
- (수정, plan F 채택 시) `order/service/OrderCancellationImpl.java`(`doCancel`) 또는 `order/spi/OrderCancellation.java` — 락 재조회 상태 vs `refundInfo` 모순 방어 가드(예외) + Javadoc 계약 명시.
- (재사용·무변경) `PaymentGatewayPort`, `event-catalog.md`, notification 전부, 마이그레이션 전부.

## Acceptance Criteria
- 취소-결제 경합을 **반복 실행**해도 최종 상태가 항상 **단일 정합 조합**이다: ① `order=cancelled` + 재고 복원 1회 + payment 없음/환불, **또는** ② `order=paid` + 재고 미복원 + payment paid. **"paid인데 재고 과복원(현 버그: stock=11)" 혼합 상태가 0회**.
- `OrderCancellationConcurrencyIntegrationTest`가 **반복 실행에서 결정적으로 통과**하고, 전체 `./gradlew test` 그린(해당 테스트 단독 N회 반복 통과 확인). **수정 1 적용 전 정합성 단정은 RED**(현 버그 노출)임을 경험으로 확인.
- (plan F 채택 시) `paid` 주문에 모순된 `refundInfo(false,0)`로 `OrderCancellation.cancel` 직접 호출 시 **종결이 거부**된다. production 정상 흐름(`PaymentService.cancel` 경유)은 무영향.
- 환불액·PG·이벤트·DB 스키마가 무변경이고, 016/017/018/022·기타 동시성 테스트가 회귀 없이 그린이다. `confirmPaid` 멱등/REJECTED 분기 회귀 없음.

## Test
- **정합성 회귀(Testcontainers, 핵심)**: cancel-vs-pay를 N회 반복 — 최종 order/payment/stock이 단일 정합 조합인지 단정(타이밍 비의존). **이 단정은 현 코드(수정 전)에서 RED**(success=2·paid·stock=11 노출)여야 하고, 수정 1 적용 후 GREEN이어야 한다(verification-gate RED 확인 — 실측: 현재 12회 중 7회 success=2/paid/stock=11).
- **confirmPaid 직렬화 단위/통합**: 취소가 먼저 커밋된 뒤 결제 확정이 들어오면 **REJECTED(결제 실패)** 로 처리되어 취소를 덮어쓰지 않음을 단정(stale 읽기 수정 검증).
- **(plan F) 가드 단위/통합**: `paid` 주문 + `RefundInfo(false,0)` 직접 호출 → 거부(예외)·롤백 단정. 정상 `refundInfo`(refunded=true, 금액 일치)는 통과.
- **회귀**: 동시 취소 2건 케이스, `OrderCancellationExpiryTest`, `PaymentServiceCancelTest`, 결제 승인/거절(016/017), 만료(022) 그린 유지. `./gradlew test` 풀 그린.

## 참고 (근본원인 코드 위치 — 실측 확인)
- `order/service/OrderConfirmationImpl.java` — `confirmPaid`가 `findByIdForUpdate`(line 60) 후 **이미 적재된 stale `Order`를 refresh 없이 사용** → `markPaid`(주 버그 지점). status 분기 line 41(멱등 paid)/54(REJECTED)/68(금액 불일치).
- `order/service/OrderPaymentReaderImpl.java` — `getPayableOrder`가 managed `Order`를 pay 트랜잭션 영속성 컨텍스트에 적재(stale 원인 제공).
- `order/domain/Order.java` — `markPaid`(pending→paid, line 179~), `markCancelled`(pending→cancelled, **paid면 예외 line 206~208**), `markRefunded`(paid→refunded, line 227~).
- `payment/service/PaymentService.java` — `pay`(line 87~), `cancel`(line 197~, 유일 production `OrderCancellation.cancel` 호출자 line 263; 만료는 `cancelByExpiry` line 328로 분리).
- `src/test/java/com/shop/shop/order/service/OrderCancellationConcurrencyIntegrationTest.java` — cancel-vs-pay: raw SPI 호출 `RefundInfo(false,0)`(line 199~200) + `successCount==1` 단정(line 240). **실측: 7/12 실패(success=2, order=paid, stock=11)**.

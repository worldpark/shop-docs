# 033. shop-core 취소 vs 결제 동시성 테스트 flake 해소 + 취소 SPI refundInfo 불변식 강화

> 출처: **Task 031 쿠폰 검증 중 발견**. 전체 스위트(`./gradlew test`)에서 `OrderCancellationConcurrencyIntegrationTest > cancelVsPay_serialized_onlyOneSucceeds`가 간헐 실패(약 1/3). **clean HEAD(쿠폰 변경 전) worktree에서도 동일 재현** → Task 031 회귀가 아닌 **기존 잠재 결함**으로 확정. 쿠폰과 무관(해당 주문엔 쿠폰 없음 → `restoreByOrder`는 0행 no-op).

## Target
shop-core (order·payment 동시성 — 취소/결제 직렬화 경로 + 해당 통합 테스트)

> 본 Task는 **테스트 flake의 근본 원인 해소 + 취소 SPI 계약의 잠재 불변식 갭 강화**에 한정한다. 결제/환불 금액·PG 로직(016/017/018)·이벤트 계약·DB 스키마는 무변경. 신규 이벤트/notification 없음.

---

## Goal
동시 **주문 취소 vs 결제**가 경합할 때, 시스템이 일관된 단일 종착 상태(취소 또는 결제완료, 필요 시 환불)로 수렴하고 **회계·재고 정합**이 깨지지 않음을 보장한다. 그리고 그 불변식을 **결정적(deterministic)으로 검증**하도록 `OrderCancellationConcurrencyIntegrationTest`의 잘못된 단정을 바로잡는다. 더불어 취소 SPI(`OrderCancellation.cancel`)가 **호출자가 넘긴 `refundInfo`를 맹신**해 실제 주문 상태와 모순된 종결(예: paid 주문을 환불 없이 refunded 처리)을 만들지 못하도록 방어 가드를 추가한다.

## Context (근본 원인 분석 — 코드 대조)
- **production 취소-결제 경합은 이미 직렬화·안전**:
  - 결제: `PaymentService.pay`(`@Transactional`) — `getPayableOrder`(락 없음, 빠른 1차 판정) → PG auth → **권위 확정 `OrderConfirmation.confirmPaid`가 orders row `PESSIMISTIC_WRITE` 잠금** 후 상태 재검증·`Order.markPaid`(`OrderConfirmationImpl` line 35, 112).
  - 취소: production 진입점은 **`PaymentService.cancel`(유일 호출자)** — `getOrderForCancel`로 orders row `PESSIMISTIC_WRITE` 잠금 → **실제 payment에서 `refunded`/`refundedAmount`를 재도출**(paid면 PG refund 수행) → 그 올바른 `RefundInfo`로 `orderCancellation.cancel(orderId, userId, refundInfo)` 위임(`PaymentService` line 196~263).
  - 즉 production에서 취소·결제는 같은 orders row의 `PESSIMISTIC_WRITE`로 상호배제되고, paid 주문 취소는 `PaymentService.cancel`이 **락 아래에서 환불을 재도출**하므로 정합하다.
- **flake의 진짜 원인 — 테스트가 production 경로를 우회**:
  - `OrderCancellationConcurrencyIntegrationTest`의 cancel-vs-pay 케이스는 **하위 SPI `orderCancellation.cancel(orderId, userId, new RefundInfo(false, 0L, "KRW"))`를 직접 호출**한다(`PaymentService.cancel`을 거치지 않음, test line 199).
  - `OrderCancellation.cancel`은 `findByIdForUpdate`(PESSIMISTIC_WRITE)로 락을 잡지만(`OrderCancellationImpl` line 75~86), **종결 처리는 호출자가 준 `refundInfo`(false,0)를 그대로 사용**한다.
  - **결제가 락 경합에서 이기면**: 주문이 `paid`로 확정된 뒤, 직접 호출된 cancel이 락을 잡고 `paid`를 보고 **`paid → refunded` 전이**(`Order.markRefunded`)하며 `outcome=CANCELLED`를 반환 → 테스트의 `successCount`가 **결제(1) + 취소(1) = 2**가 된다.
  - 테스트 단정 `assertThat(successCount.get()).isEqualTo(1)`(test line 240)은 "둘 중 정확히 하나만 성공"을 가정하나, **결제 성공 후 취소가 환불로 성공하는 흐름**을 고려하지 않아 결제가 이기는 타이밍에서 깨진다 → **간헐 실패(flake)**.
- **노출된 잠재 계약 갭(낮은 심각도, 그러나 실재)**:
  - `OrderCancellation.cancel(orderId, userId, refundInfo)`는 `refundInfo`를 **검증 없이 신뢰**한다. 호출자가 `paid` 주문에 `RefundInfo(false, 0)`를 넘기면, doCancel은 `paid → refunded`로 종결하면서 **`OrderCancelledEvent(refunded=false, refundedAmount=0)`를 발행하고 payment row는 환불되지 않은 채** 남는다(회계 불일치).
  - 현재 production에선 유일 호출자 `PaymentService.cancel`이 항상 락 아래에서 올바른 `refundInfo`를 도출하므로 **발생하지 않는다**. 그러나 계약이 "호출자가 락+도출을 정확히 한다"는 암묵 전제에 의존해 **취약**하다(향후 다른 호출자/리팩터링 시 회귀 위험).

## 문제 요약
1. **테스트 결함(주원인)**: cancel-vs-pay 케이스가 (a) production이 아닌 **raw SPI를 stale `RefundInfo(false,0)`로 직접 호출**하고, (b) **`successCount==1`이라는 잘못된 불변식**을 단정해, 결제가 이기는 타이밍에 flake.
2. **계약 취약성(부차)**: `OrderCancellation.cancel`이 `refundInfo`를 맹신 → 실제 상태(paid)와 모순된 종결을 막는 **방어 가드 부재**.

## plan 확정 필요 (수정 방향 — 두 갈래 이상이므로 plan에서 확정)
> **수정 방향이 둘 이상이라 plan 단계에서 확정하고, 방향이 갈리면 사용자 승인을 받는다.**

1. **테스트 수정 방식** — 택1(또는 조합):
   - (A) **production 경로로 교정**: cancel 스레드가 raw `orderCancellation.cancel(...)`이 아니라 **`PaymentService.cancel`(또는 `PaymentServiceResponse.cancel`)**을 호출하도록 변경 → 실제 사용 경로의 직렬화를 검증. 단정도 "최종 상태가 정합(취소 또는 결제완료/환불)이고 재고·회계가 일관"으로 재구성.
   - (B) **불변식 재정의**: raw SPI 직접 호출은 유지하되, `successCount==1` 단정을 "**pending 주문을 변경한 연산은 최대 1건**(결제 성공 시 취소는 환불로 흡수), 종착 상태·재고·payment 회계가 정합"으로 교정.
   - **권장: (A)** — 테스트가 production 직렬화(취소=PaymentService.cancel)를 검증해야 의미가 있고, raw SPI에 stale refundInfo를 주입하는 비현실적 호출을 제거한다.
2. **계약 가드 추가 범위** — 택1:
   - (C) **`OrderCancellation.cancel`/`doCancel`에 방어 가드 추가**: 락으로 재조회한 주문 상태가 `paid`인데 `refundInfo.refunded()==false`(또는 금액 불일치)면 **거부/예외**(불변식 위반)로 종결을 막는다 → 모순된 종결·미환불 refunded 차단(defense-in-depth).
   - (D) **가드 없이 문서화만**: "호출자는 락 아래에서 refundInfo를 도출해야 한다"는 계약 전제를 SPI Javadoc에 명시하고 가드는 추가하지 않음(테스트 교정으로 flake만 해소).
   - **권장: (C)** — 저비용 가드로 잠재 회귀를 영구 차단. 단 production 동작(정상 흐름)에는 무영향이어야 한다(현재 PaymentService.cancel은 항상 올바른 refundInfo를 넘기므로 가드에 걸리지 않음).

## Requirements
- **flake 제거**: `OrderCancellationConcurrencyIntegrationTest`의 cancel-vs-pay 케이스가 **반복 실행에서 결정적으로 통과**한다(타이밍 의존 단정 제거). 동시 취소 2건 케이스 등 다른 케이스는 무변경 유지(이미 안정).
- **정합 불변식 검증**: 취소-결제 경합 후 (1) 주문 종착 상태 ∈ {cancelled, paid, refunded}, (2) 재고 정합(취소/환불 시 복원 1회, 결제 성공 시 미복원), (3) **payment 회계 정합**(refunded 종결이면 payment도 refunded·환불액 일치; paid 종결이면 payment paid)을 단정한다.
- **(plan C 채택 시) 방어 가드**: 락 재조회 상태와 `refundInfo`가 모순(paid인데 refunded=false/금액 0)이면 종결을 거부하고 트랜잭션 롤백(`IllegalStateException` 또는 도메인 예외). production 정상 흐름은 무영향.
- **production 무변경 보장**: `PaymentService.pay`/`cancel`/`expirePendingOrder`의 **금액·PG·상태 전이 로직은 변경하지 않는다**(가드는 가산만). `OrderConfirmation.confirmPaid`·`OrderCancellationImpl.doCancel` 정상 경로 동작 불변.

## Constraints
- **결제/환불 금액·PG 로직 무변경**(016/017/018): 환불액 산정·PG 호출·상태머신 전이 불변. 가드는 "모순 입력 거부"의 가산만 허용.
- **이벤트/notification 무변경**: `OrderCancelledEvent`/`OrderCompletedEvent` 계약·발행 시점 불변. `event-catalog.md`/§5 불변.
- **DB 스키마 무변경**: 신규 마이그레이션 없음. `@Version` 컬럼 도입 등 스키마 변경은 범위 밖(현 PESSIMISTIC_WRITE 직렬화로 충분 — 과설계 금지).
- **동시성 모델 유지**: 분산락 미도입(ADR-005 단일 DB). 기존 `findByIdForUpdate`/`confirmPaid` PESSIMISTIC_WRITE 직렬화를 신뢰·유지하고, 새 락/전략을 도입하지 않는다.
- **회귀 금지**: 취소/결제/만료 관련 기존 테스트(016/017/018/022)·다른 동시성 테스트 그린 유지.
- **flaky 단정 금지**: 새 단정은 타이밍 비의존(결정적)이어야 한다. 재시도/`@RepeatedTest` 남발로 덮지 않는다.

## Files
> 정확 경로/범위는 plan 확정.
- (수정) `src/test/java/com/shop/shop/order/service/OrderCancellationConcurrencyIntegrationTest.java` — cancel-vs-pay 케이스를 production 경로(plan A) 또는 교정 불변식(plan B)으로 수정. payment 회계 정합 단정 추가.
- (수정, plan C 채택 시) `order/service/OrderCancellationImpl.java`(`doCancel`) 또는 `order/spi/OrderCancellation.java` — 락 재조회 상태 vs `refundInfo` 모순 방어 가드 + Javadoc 계약 명시.
- (수정, 선택) `payment/service/PaymentService.java` — (가드 채택 시) 호출 계약 주석 보강(로직 무변경).
- (재사용·무변경) `OrderConfirmationImpl`, `OrderPaymentReader(Impl)`, `PaymentGatewayPort`, `event-catalog.md`, notification 전부, 마이그레이션 전부.

## Acceptance Criteria
- `OrderCancellationConcurrencyIntegrationTest`가 **반복 실행에서 결정적으로 통과**한다(cancel-vs-pay flake 제거). 전체 `./gradlew test` 그린(해당 테스트 단독 N회 반복 통과 확인).
- 취소-결제 경합 후 종착 상태·재고·**payment 회계**가 항상 정합이다(결제 성공 시 미복원·paid, 취소/환불 시 복원 1회·refunded+환불액 일치).
- (plan C 채택 시) `paid` 주문에 모순된 `refundInfo(false,0)`로 `OrderCancellation.cancel` 직접 호출 시 **종결이 거부**되어 미환불 refunded 불일치가 발생하지 않는다. production 정상 흐름(`PaymentService.cancel` 경유)은 무영향.
- 결제/환불 금액·PG·이벤트·DB 스키마가 무변경이고, 016/017/018/022·기타 동시성 테스트가 회귀 없이 그린이다.

## Test
- **동시성 통합(Testcontainers)**: cancel-vs-pay를 production 경로로 N회(예: 반복) 실행 — 최종 상태/재고/payment 회계 정합 단정(타이밍 비의존). 결제 승자·취소 승자 양 분기 모두 정합 확인.
- **(plan C) 가드 단위/통합**: `paid` 주문 + `RefundInfo(false,0)` 직접 호출 → 거부(예외)·롤백 단정. 정상 `refundInfo`(refunded=true, 금액 일치)는 통과.
- **회귀**: `OrderCancellationConcurrencyIntegrationTest`의 동시 취소 2건 케이스, `OrderCancellationExpiryTest`, `PaymentServiceCancelTest`, 결제 승인/거절(016/017), 만료(022) 그린 유지. `./gradlew test` 풀 그린.

## 참고 (근본원인 코드 위치)
- `payment/service/PaymentService.java` — `pay`(line 87~), `cancel`(line 196~263, 유일 production 취소 호출자 line 263)
- `order/service/OrderConfirmationImpl.java` — `confirmPaid` PESSIMISTIC_WRITE(line 35, 58, 112)
- `order/service/OrderCancellationImpl.java` — `cancel`/`doCancel`, `findByIdForUpdate` 락(line 75~117)
- `order/spi/OrderPaymentReader.java` — `getPayableOrder`(락 없음) vs `getOrderForCancel`(PESSIMISTIC_WRITE)
- `src/test/java/com/shop/shop/order/service/OrderCancellationConcurrencyIntegrationTest.java` — cancel-vs-pay raw SPI 직접 호출(line 199) + `successCount==1` 단정(line 240)

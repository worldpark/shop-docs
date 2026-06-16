# Plan 004. shop-core k6 payment-confirm 시나리오 (주문 행 락 + Outbox 발행)

> 대상 Task: `docs/tasks/performance/004-performance-shop-core-k6-payment-confirm-scenario.md`
> 선행: Task 001 하니스(완료). 002/003과 독립.
> 구현 담당: `k6-implementor` (메인 오케스트레이션·파괴적 DB 정리·notification 안전 확인은 메인)

## 0. 운영 안전 게이트 (구현·측정 전 필수)
- **notification은 log 모드이거나 정지여야 한다.** payment-confirm은 매 결제마다 `OrderCompletedEvent`(topic `order-completed`)를 발행 → notification이 **주문 확정 메일**을 보낸다. smtp 모드면 002/003 같은 실 Gmail 대량발송 사고가 재현된다(현재 notification 컨슈머 활성 상태 확인됨 — 모드 미확인). **메인이 측정 직전 notification 정지(또는 log 확정)를 보장**한 뒤에만 k6-implementor가 실행한다.
- **베이스라인은 깨끗한 DB**에서 측정(누적 주문 열화 방지 — 메모리 [[k6-perf-baseline-needs-clean-db]]). 측정 전 메인이 테스트 주문/장바구니 TRUNCATE.

## 1. 목표
결제 확정 핫패스(`POST /api/v1/orders/{orderId}/payment`)를 가압해 **결제 단계 + Outbox 발행 경로의 지연·throughput·에러율**을 측정하고 thresholds를 확정한다. 추세 회귀 감시 기준선.

## 2. 가압 대상 REST 계약 (코드 실사 확정)
| 단계 | 메서드·경로 | 요청 바디 | 응답/추출 | status | 권한 |
|---|---|---|---|---|---|
| (선행) 주문 생성 | `POST /api/v1/orders` | Task 001과 동일 | `orderId` | 201 | CONSUMER |
| **결제 확정** | `POST /api/v1/orders/{orderId}/payment` | `{method?, amount?}` (**둘 다 선택 — 빈 바디 허용, method 기본 "mock"**) | `PaymentResponse`(`status:"paid"`, paymentId, pgTransactionId, paidAt) | **200** | CONSUMER(소유) |

- **빈 바디로 호출**(`{}` 또는 바디 없음) → method="mock", amount=null(주문 finalAmount 사용). amount 전달 시 finalAmount와 불일치하면 400 → **amount는 보내지 않는다**(불일치 400 회피).
- **상태 전이**: pending→paid(`Order.markPaid`), 주문 행 `PESSIMISTIC_WRITE`(`findByIdForUpdate`) + `entityManager.refresh`.
- **멱등**: 이미 paid인 주문 재결제 → **200**(기존 결과 반환, 409 아님). pending이 아닌 다른 상태(취소 등) → **409**.
- **소유권**: 본인 주문만(타인 → 404). 각 VU는 자기 buyer 토큰으로 자기 주문을 결제.
- **발행 이벤트**: 결제 승인 시 `OrderCompletedEvent` → `order-completed`(Modulith Outbox 외부화) → notification 주문확정 메일. **재고 변경 없음**(주문 생성에서 차감 완료). payments row는 `uq_payments_order_id`로 1건 선점.

## 3. 시나리오 설계 (방식 (a) 채택)
**(a) 자기완결: 각 VU 반복 = cart add → order create → 결제 확정.**
- 채택 이유: 매 반복 신선한 PENDING 주문을 만들어 결제하므로 **풀 소진 관리가 없다**(자기 replenish). 방식 (b) 풀 시드는 대량 사전생성(rate×duration 주문) 필요 + 결제 후 재결제는 멱등 no-op이라 측정 오염 → 본 Task는 (a).
- **한계 정직 표기**: (a)는 order-create 단계가 **단일 variant 락(001~003과 동일 ~90~100/s 상한)** 을 거치므로, *순수 결제/Outbox 고립 측정*이 아니라 **종단(order→pay) throughput** 측정이다. **결제 단계 자체 지연은 `Trend payment_confirm_duration`로 분리 계측**한다. 순수 결제 고립(풀 시드 (b))은 후속 옵션(README에 명시).
- VU 흐름: `getValidToken(buyer)` → cart add(200) → order create(201, orderId 추출) → `POST /orders/{orderId}/payment` 빈 바디(200).

## 4. 변경 대상 파일
- `shop-core/perf/k6/scenarios/payment-confirm.js` — **신규**. lib(config·auth·seed) + buildOptions(기존 분기) 재사용. setup=기존 setupSeed(buyer N), VU=order→pay.
- `shop-core/perf/k6/lib/config.js` — `PAYMENT_THRESHOLDS`(형태) 추가. **프로파일은 재사용**(smoke/load/stress), 시나리오만 신규.
- `shop-core/perf/k6/README.md` — payment-confirm 실행·안전 게이트·Kafka 필수 기록.
- 산출: `baselines/payment-confirm-{smoke,load}.json`.

## 5. 계측 / thresholds
- 커스텀 메트릭: `Trend payment_confirm_duration`(결제 POST 자체 지연), `Counter payment_confirmed`(200·status=="paid"), `Counter payment_conflict`(409 — 상태 충돌, cancel-vs-pay 선례 Task 033, 가시화만), `Counter payment_5xx`(>=500).
- check: cart 200 / order 201 / payment 200.
- **PAYMENT_THRESHOLDS(형태, 실측 후 확정)**: `http_req_failed: rate<0.01`, `payment_5xx: count==0`(락/발행 붕괴=비정상), `payment_confirm_duration` p95/p99(측정 후 기입). `payment_conflict`는 임계 없음(정상 비즈니스 흐름). **포화점 측정 금지**(002 교훈) — load 60rps로 구동하되 종단 경로가 포화점 위가 아닌지 §6에서 확인, 필요 시 목표 하향.

## 6. 측정 절차 (메인 안전 게이트 → k6-implementor)
1. **(메인) notification 안전 보장**(정지 또는 log 확정) + 테스트 주문/장바구니 TRUNCATE.
2. **(k6-implementor)** `k6 archive` 정적 검증 → `-e PROFILE=smoke`로 동작 확인(소량) → `-e PROFILE=load`(60rps)로 베이스라인. **달성 결제 RPS·payment_confirm_duration p95/p99·payment_5xx(==0)·payment_conflict·http_req_failed** 기록. dropped/포화 징후 확인(포화점 위면 목표 하향 재측정 — 002 flaky 답습 금지).
3. 관측 p95/p99로 PAYMENT_THRESHOLDS 확정(×2.5~3 여유, smoke/load 선례 일관). `baselines/payment-confirm-load.json`(handleSummary, 토큰 제외, p99 포함) 산출.
4. **smoke/load/stress(order-create) 회귀 0** 확인(시나리오 추가가 기존 프로파일·시나리오에 무영향 — payment-confirm.js만 신규, order-create.js 무변경).

## 7. 검증
- payment-confirm 실행 완료(비정상 종료 없음) + 확정 thresholds 만족, `payment_5xx==0`.
- **Kafka up 전제**(Outbox 외부화). notification log/정지(안전 게이트).
- baseline JSON 토큰 미포함·p99 포함, 깨끗한 DB 측정.
- order-create.js·앱·빌드 무변경. `./gradlew test` 게이트 무관.

## 8. Non-goals
- 결제 거절(decline) 가압 — Task 017 경로, 별도. 취소(cancel) 가압 — 별도.
- 순수 결제 고립(풀 시드 (b)) — 후속 옵션.
- stress 프로파일·coupon 시나리오(003/005), Outbox→Kafka 정합 내부 검증(Testcontainers), 앱/빌드 변경.

## 9. 리뷰 관점
- 결제 호출이 **빈 바디(또는 method만)** 로 200을 받고 amount 미전송(400 회피)인가. orderId를 order-create 응답에서 정확히 추출하는가.
- payment_confirm_duration이 결제 단계만 분리 계측하고, (a)가 종단 측정임을 문서가 정직히 표기하는가.
- PAYMENT_THRESHOLDS가 실측 기반(포화점 회피)·payment_5xx==0 유지인가. baseline 토큰 제외·깨끗한 DB.
- 기존 시나리오/프로파일·앱 무변경, notification 안전 게이트가 README에 명시됐는가.

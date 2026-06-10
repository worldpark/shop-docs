# 017 — 결제 거절 plan 모순 5건 수정 + 거절 트리거 보정 + forward-compat 이음매 (Revision 1)

- 대상 Task: `docs/tasks/backend/017-backend-shop-core-payment-decline-payment-failed-event.md`
- 대상 Plan: `docs/plans/backend/017-backend-shop-core-payment-decline-payment-failed-event-plan.md`
- 결정 일자: 2026-06-10
- 결정자: 사용자(plan 모순 점검 피드백 + 미래 모듈 분리 대비 결정)
- 목적: 초기 017 plan의 설계 모순 5건을 수정한 이유와 구현 기준, 구현 중 발견된 거절 트리거 결함(DB CHECK 충돌) 보정, 그리고 "차후 payment 모듈 분리(HTTP 통신) 시 빈 교체로 동작" 목표를 위해 추가한 무해한 이음매(`OrderConfirmation.Outcome`)의 근거를 기록한다.

---

## 결정 요약

| # | 항목 | 초기 plan/코드 | 변경 결정 | 근거 |
|---|---|---|---|---|
| 모순1 | 결정적 거절 규칙 | **금액 임계**(amount > 100만 → 거절) | **결제수단(method) 기반**으로 전환 → 이후 **`virtual_account`** 로 확정 | 주문당 금액 고정이라 임계 규칙이면 `failed→paid` 재시도 승인이 실 게이트웨이로 **도달 불가** |
| 모순2 | 동시성 불변식 서술 | "선점 1건만 PG에 도달" | "**동시** PG 호출은 1건"으로 정밀화(패자는 승자 커밋 후 직렬 경로로만 도달, Ma2) | Ma2 패자 failed 재사용이 PG 재호출을 유발 → 원 문장과 모순 |
| 모순3 | `markFailed` 사유 처리 | "`failed→failed` 멱등적으로 **사유 갱신**" + 인자 미사용 | "`failed→failed`는 **상태 무변경 no-op**", 인자 미영속·미사용을 **옵션 B 대비 의도**로 명문화 | 옵션 A(사유 미영속)와 "사유 갱신" 서술이 모순 |
| 모순4 | 연락처 해석 시점 | ⑤-B(PG 호출 **후**)에서 `findContactByUserId` 재조회 | **PG 호출 전 1회 사전 해석 → 지역 변수 보관 → ⑤-B 재사용**(후자안) | 거절 커밋 구간(PG 후)에 외부 조회가 있으면 실패 시 거절 유실(C1 위배) |
| 모순5 | 이벤트 currency | `"KRW"` 하드코딩 | **`snapshot.currency()`** 사용 | 승인 경로·`PaymentAuthorizationRequest`와 동일 출처여야 함(코드는 이미 snapshot 사용) |
| 추가결함 | 거절 트리거 method 값 | `"mock-decline"`(모순1 1차 수정값) | **`virtual_account`**(기존 CHECK 허용값) | `payments.method` CHECK(`card/bank_transfer/virtual_account/mock`) 위반 — ready row INSERT(PG 전)에서 깨짐 |
| 3·4(이음매) | 주문 확정 결과 표현 | `OrderConfirmationResult(confirmed, eventPublished)` + REJECTED는 예외 | **`Outcome { CONFIRMED, ALREADY_CONFIRMED, REJECTED }` 값 타입** 도입(409-class throw→값), 현행 동작 100% 보존 | 미래 payment 분리(HTTP) 시 `confirmPaid` 빈 교체 + `UNKNOWN` 분기 추가만으로 끝나게 하는 이음매 |

---

## 1. plan 설계 모순 5건 수정 (적용 결정 = 사용자 지시)

### 1.1 모순1 — 결정적 거절 규칙: 금액 임계 → method 기반(`virtual_account`)
- 초기 plan §1.9는 거절 규칙으로 **금액 임계**(예: `amount > 1,000,000` → 거절)를 채택했다. 그러나 `authorize`에 넘기는 금액은 `snapshot.finalAmount()`로 **주문당 고정**이라, 한 번 임계 초과로 거절된 주문은 **재시도해도 영구 거절** → `failed→paid` 재시도 승인 경로(Ma1·§3.3·수동확인)가 **실 게이트웨이로 도달 불가**가 된다(단위 테스트는 port mock으로 통과하므로 "테스트는 그린인데 실동작 불가"인 위험).
- 결정: `method`는 클라이언트가 **주문을 변경하지 않고** 재시도 시 바꿀 수 있는 유일한 입력 → **method 기반 거절**로 전환. 거절 트리거 method면 declined, 그 외 approved.
- 파급(추가결함): 1차로 정한 트리거 `"mock-decline"`은 `payments.method` CHECK 밖이라 `acquireOrResolveReadyRow`의 ready row INSERT(PG 호출 전)에서 `DataIntegrityViolationException`으로 깨진다. → **기존 허용값 `virtual_account`를 트리거로 재사용**(신규 migration 불필요). `mock`/`card`/`bank_transfer`는 승인 → 재시도 시 이 값으로 바꾸면 `failed→paid`가 실 게이트웨이로 재현된다.

### 1.2 모순2 — "선점 1건만 PG 도달" → "동시 PG 호출 1건"
- §1.3은 "선점 1건만 PG에 도달"이라 했으나, §1.5/3.5의 Ma2(동시 패자가 `failed` row를 재조회·재사용 후 PG 재호출)와 충돌한다.
- 결정: 패자는 **승자 커밋 후 직렬 경로로만** PG에 도달하므로, 불변식을 "**한 주문에 대한 동시 PG 호출은 1건**"으로 정밀화. 구현 시 016 코드 주석도 동일하게 정밀화.

### 1.3 모순3 — `markFailed` "사유 갱신" 문구 ↔ 옵션 A
- §1.4의 "`failed→failed` 멱등적으로 사유 갱신"이 §1.7 옵션 A(사유 미영속)와 모순(갱신할 컬럼이 없음).
- 결정: "`failed→failed`는 **상태 무변경 no-op**"으로 정정. `markFailed(failureCode, failureReason)`는 인자를 받되 **본문 미사용**이며, 이는 **옵션 B(사유 영속) 도입 시 호출부·시그니처 변경 없이 본문 한 줄만 추가**하기 위한 의도적 forward-compat임을 javadoc에 명시.

### 1.4 모순4 — 연락처 재조회 실패 ↔ C1 (후자안 채택)
- ⑤-B(PG 호출 후, 거절 커밋 구간)에서 `findContactByUserId`를 재조회하면, 실패 시 트랜잭션 롤백으로 **거절 기록·이벤트가 유실**(C1 "거절은 반드시 커밋" 위배). 초기 plan은 이 케이스를 에러표에 정의하지 않았다.
- 결정(후자): 연락처를 **PG 호출 전 1회 사전 해석**(`memberDirectory.findContactByUserId(snapshot.userId())`)해 지역 변수로 보관하고, ⑤-B는 **재사용**(재조회 금지). 해석 실패는 항상 PG 호출 전에 드러나 `PaymentEventResolutionException`(409)로 매핑되고, 거절 커밋 구간에는 외부 조회가 없어 거절이 항상 정상 커밋된다. 승인 경로도 연락처를 1회 해석하는 비용이 생기나(거절 여부는 PG 후에야 알 수 있어 불가피), 정합성을 미세 최적화보다 우선.

### 1.5 모순5 — 이벤트 currency 하드코딩 제거
- `PaymentFailedEvent.currency`를 `"KRW"`로 하드코딩했으나, 코드는 이미 `snapshot.currency()`를 승인 경로/`PaymentAuthorizationRequest`에서 사용.
- 결정: 이벤트 currency도 **`snapshot.currency()`** 출처로 통일(하드코딩 금지).

---

## 2. 구현·검증 결과 (오케스트레이션: backend → view → reviewer)

- **backend-implementor**: payment 거절 분기 전체 + `PaymentFailedEvent`(`@Externalized("payment-failed")`) + `PaymentDeclinedException`(402) + `markFailed`/`markPaid`(Ma1) + `acquireOrResolveReadyRow` failed 재사용(Ma1·Ma2) + 연락처 사전 해석(Mi1·모순4) + currency snapshot(모순5) + 단위/Outbox/동시성/REST보안/구조 테스트. 이후 거절 트리거를 `virtual_account`로 보정.
- **view-implementor**: `detail.html`/`OrderViewController.pay` **무변경 확인**(016 flashError·폼 재노출 경로가 거절 흡수) + `PaymentDeclineViewRenderingTest` 5케이스 신규.
- **reviewer**: **1회차 PASS**(C1/Ma1/Ma2/Ma3/Mi1·모순2/4/5·§1.9 트리거·계약 무변경·016 회귀 없음) → fixer 불필요.
- **전체 테스트**: `./gradlew test` BUILD SUCCESSFUL.

### 2.1 수동 확인 (실 앱 + 실 PostgreSQL + 실 Kafka — 자동 테스트가 커버 못하는 Kafka 외부화 라운드트립 포함)
- 거절(`method=virtual_account`): HTTP **402** + ErrorResponse(내부 failureCode/PG원문/스택트레이스 비노출), `payments.status=failed`, `orders.status=pending 유지`, Outbox 1건 → Kafka `payment-failed` 1건. 페이로드 전 필드 정상(memberEmail/memberName=member.spi Mi1, amount=long, currency=KRW, failureCode/failureReason).
- 재시도 승인(`method=mock`): HTTP **200**, `payments` 동일 row 재사용(failed→paid, 1건 유지=uq), `orders.status=paid`, Kafka `order-completed` 1건. event_publication 2건(각 1건씩, 모두 completed) → 승인 시 payment-failed 중복 미발행 확인.

---

## 3. forward-compat 이음매 — `OrderConfirmation.Outcome` (3·4번 결정)

> 배경: 사용자 목표 = "차후 payment 모듈이 별도 서비스(HTTP 통신)로 분리돼도 **빈만 교체하면 동작**하는 구조". DB는 분리하지 않는다는 전제.

### 3.1 결정 근거 (핵심: 공유 DB ≠ 공유 트랜잭션)
- 단일 트랜잭션 원자성은 **DB가 아니라 프로세스 경계**의 산물. payment를 별도 프로세스로 분리하면(공유 DB라도) `pay()`의 `payments.paid`와 `confirmPaid`(orders.paid+OrderCompletedEvent)가 **별도 트랜잭션**이 되어 원자성이 깨진다 → 승인 경로는 **사가(멱등+재시도+정산/보상)** 가 필요. 이는 지금 적용하면 강일관성을 약일관성으로 떨어뜨리는 **회귀**이므로 **분리 시점까지 미룬다**.
- 따라서 지금은 **무해한(additive·비회귀) 이음매**만 심는다. 항목 점검 결과:
  - **3번(멱등키)**: `confirmPaid`는 이미 orderId 기준 멱등(already-paid → 이벤트 재발행 없이 멱등 반환). **추가 구현 불필요.**
  - **4번(결과 타입)**: REJECTED만 값이 아니라 예외(409)였음 → **명시적 `Outcome` 값으로 모델링**.

### 3.2 변경 내용 (현행 동작 100% 보존)
- `order/spi/OrderConfirmation.java`: `enum Outcome { CONFIRMED, ALREADY_CONFIRMED, REJECTED }` 추가. `OrderConfirmationResult`를 `(orderId, orderNumber, Outcome outcome, boolean eventPublished, Instant orderedAt, String rejectedReason)` 6필드로 변경(`confirmed` 불리언 제거 — outcome이 대체).
- `order/service/OrderConfirmationImpl.java`: **409-class 두 경우(비-pending 상태·금액 불일치)를 throw → `Outcome.REJECTED` 값 반환**(rejectedReason 포함). 소유권 404(`OrderNotFoundException`)·금액 long 변환 500(`AmountConversionException`)·productId 해석 실패는 **예외로 유지**(분류 보존). 정상→CONFIRMED, already-paid→ALREADY_CONFIRMED.
- `payment/service/PaymentService.java`: `confirmPaid` 직후 `if (outcome == REJECTED) throw new OrderConfirmationConflictException(rejectedReason)` **되던짐**. 트랜잭션 안에서 던지므로 `payments.markPaid` 포함 **전체 롤백 + REST 409** 가 기존과 정확히 동일하게 보존됨.
- 테스트: OrderConfirmation 409-class를 `outcome()==REJECTED` 단언으로 전환, PaymentService에 "REJECTED→되던짐" 신규 테스트 추가. 016/017 회귀 없음. reviewer **PASS**, 전체 **956건 그린**.

### 3.3 효과
- 미래 분리 시 `OrderConfirmation` 인터페이스에 **HTTP 어댑터 빈**만 주입하고, `pay()`의 REJECTED 분기 **옆에 `UNKNOWN(timeout)` 한 줄**(재시도/정산)만 추가하면 되도록 이음매 확보. 트랜잭션 분리는 분리 시점까지 미뤄 현재 안전성 유지.

---

## 4. 미래 payment 모듈 분리 설계 결론 (참고 기록 — 본 Task 비구현)

> 본 Task에서 구현하지 않으나, 분리 결정 시 따를 방향을 합의했으므로 기록한다.

### 4.1 빈 교체 가능 범위
- **읽기·이벤트·거절 경로 = 빈 교체 가능**(이미 ports & adapters): `OrderPaymentReader.getPayableOrder`, `MemberDirectory.findContactByUserId`(순수 GET), 자족 `PaymentFailedEvent`(Kafka 계약 불변), 거절 경로(confirmPaid 미호출·자족 커밋).
- **승인 쓰기(`OrderConfirmation.confirmPaid`) = 빈 교체로 100% 불가**: 인터페이스/호출 모양은 교체되나 **트랜잭션·실패 의미는 못 숨김**(timeout="모름" 결과). HTTP 어댑터에 멱등+재시도+정산/보상(사가) 추가 필요. blocking HTTP + 응답 분기는 happy/명확실패(2/3)만 처리, **응답 불명(timeout, 1/3)** 은 멱등+재시도+정산으로 덮어야 함.

### 4.2 포트 소유권 (소비자 분포 기준)
| 포트 | 소비자 | 분리 시 소유 |
|---|---|---|
| `OrderPaymentReader` | **payment 전용** | payment 아웃바운드 포트로 재정의(consumer-owned) + HTTP 어댑터 |
| `OrderConfirmation` | **payment 전용** | 〃 |
| `MemberDirectory` | **order·payment·cart 공유** | **member 소유 유지**(payment가 가져가면 안 됨) — payment는 member 계약을 소비만 |
- 양쪽 변경: payment(클라이언트 어댑터) + shop-core(`/internal/...` 엔드포인트 노출, 기존 in-process 구현이 핸들러가 됨). 인터페이스/DTO는 공유 계약 아티팩트 또는 payment 타입으로 매핑(ACL).
- **현 시점 조치**: 포트를 옮기지 않는다(Modulith 구조 테스트와 충돌 + `MemberDirectory`는 공유라 이동 불가 + 분리 미확정). 소유권 재배치는 **실제 분리 시점**에.

---

## 5. 변경 파일 목록

### plan
- `docs/plans/backend/017-...-plan.md` (모순 1~5 + 거절 트리거 `virtual_account` 반영)

### 017 거절 기능 (main)
- `payment/domain/Payment.java`(markFailed/markPaid Ma1), `payment/service/MockPaymentGateway.java`(virtual_account 결정적 거절), `payment/service/PaymentService.java`(거절 분기·연락처 사전해석·currency snapshot·acquireOrResolveReadyRow Ma1/Ma2), `payment/service/PaymentServiceResponse.java`, `payment/service/PaymentFacadeImpl.java`, `payment/event/PaymentFailedEvent.java`(신규), `common/exception/PaymentDeclinedException.java`(신규)

### forward-compat 이음매 (main)
- `order/spi/OrderConfirmation.java`(Outcome + 6필드 result), `order/service/OrderConfirmationImpl.java`(409-class→REJECTED 값), `payment/service/PaymentService.java`(REJECTED 되던짐)

### 테스트
- `payment/domain/PaymentTest.java`, `payment/service/PaymentServiceDeclineTest.java`, `MockPaymentGatewayTest.java`, `PaymentServiceResponseDeclineTest.java`, `PaymentFacadeImplDeclineTest.java`, `PaymentDeclineOutboxIntegrationTest.java`, `PaymentDeclineConcurrencyIntegrationTest.java`, `payment/controller/PaymentRestControllerDeclineSecurityTest.java`, `payment/PaymentModuleStructureTest.java`, `view/PaymentDeclineViewRenderingTest.java`, `order/service/OrderConfirmationImplTest.java`, `payment/service/PaymentServiceTest.java`

---

## 6. 미적용/보류 (범위 밖)

- 승인 경로 사가(트랜잭션 분리 + 재시도 + 정산 + 보상): 분리 시점까지 보류(현 강일관성 유지).
- 포트 소유권 재배치(payment 아웃바운드 포트화) + `/internal` HTTP 엔드포인트 + 컨트랙트 테스트: 분리 시점.
- 거절 사유 영속(옵션 B, `V4` migration), 취소/환불/재고복원/TTL/실 PG/이벤트 계약 변경: 후속 Task.

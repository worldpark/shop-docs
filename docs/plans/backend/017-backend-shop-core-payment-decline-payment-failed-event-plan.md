# 017. shop-core 모의 결제 거절 처리 + PaymentFailedEvent 발행 — 구현 계획(plan)

> Task SSOT: docs/tasks/backend/017-backend-shop-core-payment-decline-payment-failed-event.md
> 선행 Task(구현 완료): docs/tasks/backend/016-...-payment-approval-order-confirmation-with-view.md — 016의 승인 경로·OrderCompletedEvent·주문 확정 로직은 **본 Task에서 변경하지 않는다**(거절 분기만 추가). 단 `markPaid`의 `failed→paid` 확장은 Ma1로 허용.
> 선례 plan(구조·톤·레이어·테스트 패턴 기준): docs/plans/backend/016-...-plan.md + docs/plans/revisions/backend/016-...-revision-1.md
> 이벤트 계약 SSOT: docs/event-catalog.md(PaymentFailedEvent, topic `payment-failed`) — **본 Task에서 무변경**
> 영역: backend(payment 모듈 거절 분기 + PaymentFailedEvent 신규 발행 + member.spi 재사용) + view(거절 flashError 표현/검증)
> 대상 프로젝트: shop-core (Spring Modulith 모듈러 모놀리스)
> 작성일: 2026-06-09
> 상태: plan only (코드 변경 없음 — 구현은 backend-implementor / view-implementor가 수행)
> 담당: backend-implementor(payment 거절 분기 전체 + PaymentFailedEvent + 402 매핑 + 백엔드/통합 테스트) → view-implementor(거절 flashError 표현/검증 + View 렌더링 테스트)
> 진행: backend-implementor → view-implementor → reviewer → fixer 사이클(최대 3회)
> 적용 결정: **C1**(거절은 예외로 트랜잭션 중단 금지·정상 커밋, 402는 커밋 후 매핑), **Ma1**(`markPaid` `failed→paid` 확장 + ready 선점에 `failed` 재사용 분기), **Ma2**(동시 패자가 `failed` row를 만나는 케이스 정의), **Ma3**(REST 거절 = 402 + ErrorResponse 단일 확정), **Mi1**(payment 모듈이 `member.spi.MemberDirectory.findContactByUserId`로 연락처 직접 조회).

---

## 0. 작업 구분 요약 (백엔드 vs 화면)

### 0.1 담당 분담표

| 구분 | 항목 | 담당 |
|---|---|---|
| 백엔드 | `MockPaymentGateway` 거절 분기 활성화(**결정적 규칙**, 무작위 금지). 포트 시그니처 무변경 | backend-implementor |
| 백엔드 | `Payment.markFailed(failureCode, failureReason)` 추가(`ready`/`failed`→`failed`, `paid`→`failed` 금지) + `markPaid` `failed→paid` 확장(Ma1) | backend-implementor |
| 백엔드 | `PaymentService.pay` 거절 분기: PG 거절 시 `ready` row를 `failed`로 전이 + `PaymentFailedEvent` 발행, 주문 `pending` 유지, **거절 결과를 정상 커밋 후 반환**(C1). `PaymentResult`에 거절 표현 추가 | backend-implementor |
| 백엔드 | `acquireOrResolveReadyRow`에 기존 `failed` row 재사용 분기 추가(Ma1) + 동시 패자가 `failed` row를 만나는 케이스 정의(Ma2) | backend-implementor |
| 백엔드 | `PaymentFailedEvent`를 `payment/event`에 `@Externalized("payment-failed")`로 정의·**payment 모듈이 발행**. `memberEmail`/`memberName`은 `member.spi.MemberDirectory.findContactByUserId`로 직접 조회(Mi1), `amount`는 P3(`longValueExact`) 변환 | backend-implementor |
| 백엔드 | `common/exception/PaymentDeclinedException`(402) 추가 — `BusinessException(message, HttpStatus.PAYMENT_REQUIRED)`. **트랜잭션 밖(ServiceResponse/Facade 또는 Controller 후처리)에서만 throw**(C1) | backend-implementor |
| 백엔드 | `PaymentServiceResponse`/`PaymentFacadeImpl`: 커밋된 거절 결과를 받아 REST는 `PaymentDeclinedException`(402)로 매핑, View facade는 거절 결과를 `PaymentDeclinedException`(402, `failureReason` 메시지)로 변환 | backend-implementor |
| 백엔드 | 거절 단위·동시성/Outbox 통합(Testcontainers)·REST/Security·구조 테스트 | backend-implementor |
| 화면 | `templates/order/detail.html` — 거절 시 flashError(거절 사유) 표시 확인(기존 `fragments/messages.html` 재사용), `pending` 유지로 결제 폼 재노출 확인. **신규 폼/핸들러 없음**(016 핸들러가 이미 `BusinessException` catch → flashError) | view-implementor |
| 화면 | View 렌더링 테스트(거절 시 flashError + `/orders/{id}` redirect + 결제 폼 재노출 + 주문 `pending` 유지) | view-implementor |

> 호출 순서: **백엔드 → 화면.** `PaymentService.pay`의 거절 결과 반환 타입·`PaymentDeclinedException`(402)·facade의 거절→예외 매핑이 먼저 고정되어야 View가 flashError 경로를 안정적으로 검증한다.

### 0.2 양 영역 인터페이스 접점 (어긋남 방지)

| 항목 | 값 (계약) — 016 대비 변경점 |
|---|---|
| View 결제 facade 시그니처 | `PaymentFacade.pay(String email, long orderId, PaymentRequest request) → PaymentResponse` **무변경.** 거절은 facade 내부에서 `PaymentDeclinedException`(402, `failureReason` 메시지)으로 던진다(정상 `PaymentResponse` 200으로 표현 금지) |
| View 결제 핸들러 | 016 `OrderViewController.pay`(`POST /orders/{orderId}/payment`) **재사용.** 이미 `catch (BusinessException e) → flashError(e.getMessage()) + redirect`. `PaymentDeclinedException extends BusinessException`이므로 **핸들러 코드 변경 없이** 거절이 flashError로 흐른다 |
| 거절 flash 메시지 | `flashError` = `failureReason`(사용자 노출 가능한 메시지만). 내부 PG 원문·`failureCode`·스택트레이스 비노출 |
| 거절 후 주문 상태 | `pending` 유지 → 주문 상세에서 결제 폼 재노출(`payment.payable=true`). 016 `getPaymentStatus`(`getOrderSnapshot` 경로)가 `payable=pending && !paid`로 이미 산출 |
| REST 거절 응답 | `402 Payment Required` + `ErrorResponse`(Ma3). 200 `PaymentResponse`로 거절 표현 금지 |
| 결제 상태 표시 | `결제 대기`(미결제/ready/failed) / `결제 완료`(paid). `failed`도 "결제 대기"로 표시(재시도 가능). `PaymentStatusView`/표시 로직 016 그대로 — failed는 `paid=false`라 기존 분기로 흡수 |

---

## 1. 설계 방식 및 이유

### 1.1 사전 확정 사실 (016 실제 구현 코드 점검 완료 — 가정 아님)

016은 이미 구현되어 있으며, 아래는 실제 소스 점검 결과다.

- **`payments.status` CHECK가 `failed`를 이미 허용**(`V1__init_schema.sql`, `Payment.java` javadoc 명시: "ready/paid/failed/cancelled/refunded"). → **`failed` 기록에 신규 migration 불필요.** 016 plan/revision도 동일 확인.
- **`Payment` Entity**(`payment/domain/Payment.java`): `id`/`orderId`(unique)/`method`/`status`/`amount`(BigDecimal precision12 scale2)/`pgTransactionId`(nullable)/`paidAt`(nullable) + BaseEntity. 정적 팩토리 `create(orderId, method, amount)`(status="ready"), 의도 메서드 `markPaid(pgTransactionId, paidAt)`(현재 `ready→paid`만 + `paid` 재호출 멱등; `ready` 아니면 `IllegalStateException`). **`failureCode`/`failureReason` 전용 컬럼 없음**(javadoc이 "failed는 017에서 markFailed 추가" 예고). **Setter 없음.** → 017은 `markFailed` 추가 + `markPaid`에 `failed` 시작점 허용(Ma1).
- **`PaymentGatewayPort`**(`payment/spi/PaymentGatewayPort.java`): `authorize(PaymentAuthorizationRequest) → PaymentAuthorizationResult`. `PaymentAuthorizationRequest(orderNumber, amount, currency, method, idempotencyKey)`, `PaymentAuthorizationResult(approved, pgTransactionId, failureCode, failureReason)` + 정적 팩토리 `approved(pgTransactionId)` / **`declined(failureCode, failureReason)` 이미 존재**. → **포트 시그니처 무변경.** 017은 `MockPaymentGateway` 내부에 거절 규칙만 켠다.
- **`MockPaymentGateway`**(`payment/service/MockPaymentGateway.java`): 현재 항상 `approved("MOCK-"+UUID)`. → 017이 결정적 거절 규칙 추가.
- **`PaymentService.pay`**(`payment/service/PaymentService.java`): 8단계 흐름. **현재 거절 시 `if (!authResult.approved()) throw new IllegalStateException(...)`** — 017이 이 분기를 C1 정상 커밋 거절 처리로 교체한다. `acquireOrResolveReadyRow`는 기존 row를 `paid`(멱등)/`ready`(재사용)로만 분기하고 `DataIntegrityViolationException` 후 재조회를 `paid`(멱등)/`ready`(409 `PaymentInProgressException`)로만 분기 — **`failed` 분기 없음**(Ma1/Ma2 추가 대상). 내부 결과 타입 `PaymentResult(Payment payment, String orderNumber)` — **거절 표현 없음**(확장 대상).
- **`PaymentResult`/`PaymentDtoMapper`**: `PaymentResult(Payment, orderNumber)` → `PaymentResponse`(200) 변환만 존재. 거절은 200으로 변환하면 안 되므로(Ma3) 거절은 `PaymentResult`를 거치되 `PaymentDtoMapper`로 200 변환하지 **않고** 매핑 계층에서 402 예외로 분기한다.
- **`PaymentServiceResponse`**(REST) / **`PaymentFacadeImpl`**(View): 둘 다 `paymentService.pay(...)` → `dtoMapper.toPaymentResponse(result)`(200). → 017은 거절 결과를 받아 200 변환 전에 402 예외로 분기.
- **`RestExceptionHandler`**: `@ExceptionHandler(BusinessException.class)`가 `ErrorResponse.of(e.getStatus(), e.getMessage(), uri)` + `ResponseEntity.status(e.getStatus())`로 매핑. → **`PaymentDeclinedException extends BusinessException(msg, HttpStatus.PAYMENT_REQUIRED)`를 던지면 402 + ErrorResponse가 신규 핸들러 없이 자동 매핑**(Ma3). `RestExceptionHandler` 변경 불필요.
- **`BusinessException`**: `(message)`=400, `(message, HttpStatus)` 임의 상태. `HttpStatus.PAYMENT_REQUIRED`(402) 사용 가능.
- **`MemberDirectory.findContactByUserId(long) → MemberContact(email, name)`**(`member/spi/MemberDirectory.java`) **이미 존재**(016이 추가). → **Mi1: payment 모듈이 이 포트로 연락처를 직접 조회**한다. `OrderPaymentReader.OrderPaymentView`는 `userId`(=memberId)만 반환하고 연락처는 반환하지 않으므로(스냅샷에서 꺼낼 수 없음), payment가 `member.spi`로 직접 해석해야 한다(Task Requirements와 일치).
- **`OrderPaymentReader.getPayableOrder`**: 결제 전용 — 소유권 404 + 이벤트 완결성 사전검증(전 항목 productId 해석 + member 연락처 존재). 거절 분기도 이 1단계를 그대로 통과하므로 **연락처/금액은 PG 호출 전(1단계)에 이미 확보 가능**. 거절 페이로드 구성에 필요한 `userId`/`orderNumber`/`finalAmount`/`currency`는 `OrderPaymentView`에 있고, `memberEmail`/`memberName`은 payment가 `member.spi`로 보강(Mi1).
- **View 핸들러**(`web/order/OrderViewController.pay`): `try { paymentFacade.pay(...) → flashSuccess } catch (BusinessException e) { flashError(e.getMessage()) + redirect }`. → **거절(402=`PaymentDeclinedException extends BusinessException`)이 핸들러 변경 없이 flashError로 흐른다.** view-implementor는 메시지 노출/재노출 검증 위주.
- **테스트 프로파일 제약(016과 동일)**: `src/test/resources/application.yml`이 DataSource/JPA/Kafka/Flyway/외부화 자동설정 제외 → Outbox·동시성은 016의 Testcontainers 별도 프로파일(`@AutoConfigureTestDatabase(NONE)` + `@Testcontainers`(postgres:16.4-alpine + `@ServiceConnection`) + `@TestPropertySource`(`spring.autoconfigure.exclude=` 리셋 + `spring.flyway.enabled=true` + `spring.jpa.hibernate.ddl-auto=validate`) + 외부화 `enabled=false`로 `event_publication` 저장만 검증) 패턴을 **그대로 재사용**.

### 1.2 거절은 도메인 정상 흐름 — 트랜잭션 정상 커밋, 402는 커밋 후 매핑 (C1)

핵심 설계는 "거절을 트랜잭션 안에서 예외로 던지지 않는다"이다.

- `PaymentService.pay`는 PG 거절(`!authResult.approved()`) 시 **예외를 던지지 않고**: ① 선점한 `ready` row를 `markFailed(failureCode, failureReason)`로 `failed` 전이 → ② `PaymentFailedEvent` 구성·`ApplicationEventPublisher.publishEvent`(같은 트랜잭션 = Outbox 저장) → ③ 주문은 `pending` 유지(`OrderConfirmation.confirmPaid` **미호출**, `OrderCompletedEvent` **미발행**) → ④ **거절을 도메인 정상 결과로 반환**한다.
- `@Transactional` 메서드가 정상 반환하므로 `failed` row UPDATE + `event_publication` INSERT가 **함께 정상 커밋**된다. 만약 트랜잭션 안에서 `BusinessException`(402)을 던지면 RuntimeException 롤백으로 `failed` 기록·이벤트가 함께 롤백되어 Acceptance("거절 시 `failed` 기록 + 이벤트 발행")가 깨진다 → **금지**(C1).
- 402 응답 변환은 **커밋 이후** ServiceResponse(REST)/FacadeImpl(View) 계층에서 `pay`의 거절 결과를 받아 `PaymentDeclinedException`(402)으로 던진다. 이 throw는 트랜잭션 밖이므로 이미 커밋된 `failed`/이벤트를 롤백시키지 않는다.

**이유**: 거절은 "시스템 오류"가 아니라 "정상적으로 발생하는 비즈니스 결과"다. 결과(failed 기록·알림 이벤트)를 영속화해야 하므로 트랜잭션은 커밋되어야 하고, HTTP 표현(402)은 영속화와 분리된 응답 계층 관심사다. error-response-rule의 "롤백 트리거 예외"와 "정상 결과의 상태 코드 매핑"을 분리한다.

### 1.3 거절 처리 단계 (016 8단계의 5단계 분기 확장)

016 흐름의 **⑤ PG 승인** 직후 분기를 다음으로 확장한다(①~④, ⑥~⑧은 016 그대로).

- ⑤ `PaymentGatewayPort.authorize(...)` 호출(선점 1건만 도달).
- **⑤-A 승인(`approved`)**: 016 경로 — ⑥ `markPaid` → ⑦ `OrderConfirmation.confirmPaid`(주문 확정 + `OrderCompletedEvent`) → ⑧ 커밋. **무변경.**
- **⑤-B 거절(`!approved`)** (신규):
  1. 선점한 `ready` row를 `markFailed(authResult.failureCode(), authResult.failureReason())` → `failed` 전이.
  2. `member.spi.MemberDirectory.findContactByUserId(snapshot.userId())`로 연락처 조회(Mi1). (016 완결성 사전검증 1단계에서 이미 해석 가능함이 보장됨 — 여기서 실제 값 확보.)
  3. `PaymentFailedEvent` 구성: `orderId`/`orderNumber`/`memberId`(=`snapshot.userId()`)/`memberEmail`/`memberName`/`amount`(`finalAmount` → `longValueExact`, P3)/`currency`("KRW")/`failureCode`/`failureReason`/`attemptedAt`(=`Instant.now()`) + 공통 봉투(`eventId`=`UUID.randomUUID()`, `occurredAt`).
  4. `ApplicationEventPublisher.publishEvent(paymentFailedEvent)`(payment 트랜잭션 안 = Outbox 저장).
  5. **거절 결과를 반환**(`OrderConfirmation` 미호출, 주문 status 변경 없음, `OrderCompletedEvent` 미발행).
  - ⑧ 커밋: `payments.status=failed` UPDATE + `event_publication` 1행(INCOMPLETE)이 원자 커밋.

> 거절 분기는 **PG 호출 전 직렬화(④ ready 선점)**의 수혜를 그대로 받는다 — 선점 1건만 PG에 도달하므로 거절도 단일 row에서만 일어난다. `OrderConfirmation`(orders row 비관락)은 거절 분기에서 호출되지 않으므로, 거절 경로는 `payments` row만 갱신하고 orders row를 잠그지 않는다(주문 `pending` 유지를 락 없이 보장).

### 1.4 Entity 상태 전이 확장 — markFailed 신규 + markPaid 확장 (Ma1)

`Payment`에 다음을 추가/확장한다(Setter 금지·의도 메서드 유지).

- **`markFailed(String failureCode, String failureReason)`** (신규):
  - 허용 전이: `ready→failed`, `failed→failed`(재시도 거절 — 멱등적으로 사유 갱신).
  - 금지 전이: `paid→failed` → `IllegalStateException`(승인된 결제를 거절로 역전이 불가).
  - `failureCode`/`failureReason`은 **옵션 A로 Entity에 영속하지 않는다**(전용 컬럼 없음 — 1.7 참조). `markFailed`는 `status="failed"`만 전이하고, `failureCode`/`failureReason`은 인자로 받아 **호출부(PaymentService)가 이벤트 페이로드·반환 결과에 직접 싣는다**. (영속이 필요해지면 후속 Task migration — 옵션 B.) → `markFailed` 시그니처는 사유를 받지만 Entity 필드에 저장하지 않고 전이 의도만 표현한다.
- **`markPaid` 확장(Ma1)**: 현재 `ready→paid` + `paid` 멱등. **`failed→paid` 전이를 추가 허용**(거절 후 재시도 승인). 즉 `if (paid) return;`(멱등) → `if (!(ready || failed)) throw;` → `paid` 전이. **`ready→paid`(016 happy path)는 회귀 없이 유지**(테스트로 보장).

**이유**: 상태 머신을 Entity 안에 의도 메서드로 가두어, "거절 → 재시도 승인"이라는 합법 경로(`failed→paid`)와 불법 경로(`paid→failed`)를 도메인이 강제한다. 016 승인 경로는 `ready→paid`로 그대로 통과.

### 1.5 ready 선점 분기에 failed 재사용 추가 + 동시 패자 failed 케이스 (Ma1·Ma2)

`acquireOrResolveReadyRow`를 확장한다(신규 row INSERT로 `uq_payments_order_id` 위반을 내지 않는다).

- **기존 row 분기(Ma1)**: 현재 `paid`(멱등 반환)/`ready`(재사용)만. **`failed` → 동일 row 재사용 분기 추가**(재승인/재거절 시도). 재승인 성공 시 ⑥에서 `markPaid`가 `failed→paid`로 갱신(Ma1 전이). 재거절 시 ⑤-B가 `markFailed`로 `failed→failed` 갱신.
- **동시 충돌(`DataIntegrityViolationException`) 후 재조회 분기(Ma2)**: 현재 `paid`(멱등)/`ready`(409 `PaymentInProgressException`)만. **재조회 결과 `failed` → 동일 `failed` row 재사용 경로로 합류**(재승인/재거절 시도). 즉 선점 승자가 거절해 row가 `failed`로 남은 뒤 패자가 재조회로 `failed`를 만나면 NPE/미정의 동작 없이 `failed` row를 재사용한다.
  - 단 동일 트랜잭션 내 즉시 재시도 무한루프를 막기 위해, 재조회 분기는 `failed` row를 **반환**만 하고(상위 ⑤에서 PG 재호출), 한 요청은 한 번의 PG 시도만 수행한다(재시도는 사용자/클라이언트의 별도 요청).

**이유**: `uq_payments_order_id`(주문당 1 row) 불변식을 유지하면서, 거절로 생긴 `failed` row가 재시도·동시 경합에서 "막다른 상태"가 되지 않게 한다(409로 영구 차단 방지). `failed`는 `ready`와 달리 "진행 중"이 아니므로 `PaymentInProgressException`(409)을 던지지 않고 재사용한다.

### 1.6 PaymentFailedEvent = payment 모듈 발행 소유 (package-structure-rule)

- `PaymentFailedEvent`를 **`payment/event`**에 `@org.springframework.modulith.events.Externalized("payment-failed")` record로 정의하고, **payment 모듈(`PaymentService`)이 `ApplicationEventPublisher`로 발행**한다. (016 `OrderCompletedEvent`는 order 모듈 소유 — 발행 소유권이 모듈별로 분리됨. `PaymentFailedEvent`는 결제 실패이므로 payment 소유, package-structure-rule.)
- 페이로드는 `docs/event-catalog.md`의 `PaymentFailedEvent` 스키마를 그대로 따른다(계약 무변경): 공통 봉투(`eventId`, `occurredAt`) + `orderId`/`orderNumber`/`memberId`/`memberEmail`/`memberName`/`amount`(long)/`currency`/`failureCode`/`failureReason`/`attemptedAt`.
- `amount`는 `finalAmount`(BigDecimal `numeric(12,2)`) → `long` 변환을 016 P3와 동일 규칙(`BigDecimal.longValueExact()`, 소수부 0만 허용, 위반 시 `AmountConversionException`(500))으로 수행한다. 변환 헬퍼는 payment 내부 private 메서드(`PaymentService` 또는 이벤트 팩토리)로 둔다.
- `memberEmail`/`memberName`은 **payment가 `member.spi.MemberDirectory.findContactByUserId`로 직접 조회**(Mi1) — `OrderPaymentView`/`OrderSnapshotView`는 연락처를 반환하지 않으므로 스냅샷에서 꺼내지 않는다.
- 발행은 `payment` 트랜잭션 안에서 수행해 `event_publication`(INCOMPLETE) Outbox 저장 → 커밋 후 `spring-modulith-events-kafka`가 외부화. 004 메커니즘 재사용(build.gradle/application.yml 변경 불필요).

### 1.7 거절 사유 영속 정책 — 옵션 A 채택 (신규 migration 없음)

- **옵션 A(채택)**: `failureCode`/`failureReason`을 `payments`에 영속하지 않고 **`PaymentFailedEvent` 페이로드와 REST 402 응답에만 싣는다**. `payments.status=failed`만 영속한다.
- **근거(코드 점검)**: `payments` 테이블(V1)에 `failure_code`/`failure_reason` 컬럼이 없고(`Payment.java` 필드 부재 확인), Task가 "기존 migration 수정 금지 + 신규 migration 없이 처리 우선"을 명시. 거절 사유는 (1) 알림 발송용 → 이벤트 페이로드, (2) 사용자 응답용 → REST 402 `failureReason`로 충분하며, 거절 사유를 DB에서 다시 조회할 요구사항이 본 Task에 없다(거절 이력 조회·통계는 범위 밖). → **옵션 A로 충분, 신규 migration 불필요.**
- 옵션 B(보류): 거절 사유 영속/이력 조회가 필요해지면 후속 Task에서 `V4`로 `payments.failure_code`/`failure_reason` 컬럼(또는 `payment_failures` 보조 테이블)을 추가한다. 본 Task에서는 도입하지 않는다.

### 1.8 REST 거절 = 402 + ErrorResponse 단일 확정 (Ma3)

- `PaymentService.pay`가 **커밋한 거절 결과**(`PaymentResult`의 거절 표현)를 `PaymentServiceResponse`(REST)/`PaymentFacadeImpl`(View)가 받아 `PaymentDeclinedException`(402, `failureReason` 메시지)로 던진다.
- `PaymentDeclinedException extends BusinessException(failureReason, HttpStatus.PAYMENT_REQUIRED)` → `RestExceptionHandler`의 기존 `BusinessException` 핸들러가 402 + `ErrorResponse`(status=402, error="Payment Required", message=`failureReason`, path, timestamp)로 자동 매핑. **신규 핸들러 불필요.**
- 거절을 200 `PaymentResponse`로 표현하지 않는다(거절을 정상 본문과 혼용 금지). 정상 `PaymentResponse`(200)는 승인/멱등 전용.
- 응답에 내부 PG 원문·`failureCode`(내부 코드)·스택트레이스를 노출하지 않는다 — `failureReason`(사용자 노출 가능 메시지)만 `message`에 담는다(error-response-rule). `failureCode`는 이벤트 페이로드(notification 분류용)에만 싣는다.

### 1.9 결정적 거절 규칙 (무작위 금지)

- `MockPaymentGateway`에 **결정적 거절 규칙 한 가지**를 문서화·구현한다(무작위 금지 — 단위 테스트 재현성). 데모 규칙(택1, 코드 주석·plan 명시):
  - **채택: 금액 임계 기반 결정 규칙** — 예) `amount`가 특정 임계값 이상(예: `1,000,000원` 초과)이면 `declined("LIMIT_EXCEEDED", "한도 초과로 결제가 거절되었습니다.")`, 그 외 `approved(...)`. (또는 `method == "mock-decline"`이면 거절.) 동일 입력 → 동일 결과를 보장한다.
  - 단위 테스트는 **port를 모킹**해 거절을 주입(`given(gateway.authorize(any())).willReturn(declined(...))`)하고, 모의 구현 자체의 결정성은 `MockPaymentGatewayTest`가 별도로 검증한다.
- `failureCode`는 event-catalog 예시(`INSUFFICIENT_FUNDS`/`LIMIT_EXCEEDED`/`CARD_DECLINED`) 중에서 사용한다.

---

## 2. 구성 요소 (신규/수정 파일 — 정확한 패키지 경로)

> 2.1 = backend-implementor, 2.2 = view-implementor. (B)=backend, (V)=view.

### 2.1 backend-implementor 담당 범위

#### (B) 수정 — payment/domain
- `shop-core/src/main/java/com/shop/shop/payment/domain/Payment.java`
  - 신규 메서드 `markFailed(String failureCode, String failureReason)`: `paid`면 `IllegalStateException`(역전이 금지), `ready`/`failed`면 `status="failed"`. (failureCode/failureReason는 Entity 미영속 — 옵션 A. 전이 의도만 표현; 호출부가 이벤트/응답에 싣는다.)
  - `markPaid` 확장(Ma1): `paid` 멱등 유지 + `failed→paid` 허용 추가(`ready`/`failed`가 아니면 `IllegalStateException`). `ready→paid` 회귀 없음.
  - javadoc 갱신: "status는 017에서 failed 추가. markFailed: ready/failed→failed, paid→failed 금지. markPaid: ready/failed→paid 허용(Ma1)."

#### (B) 수정 — payment/service
- `shop-core/src/main/java/com/shop/shop/payment/service/MockPaymentGateway.java`
  - 결정적 거절 규칙 활성화(1.9): 임계 조건 충족 시 `PaymentAuthorizationResult.declined(failureCode, failureReason)`, 그 외 `approved("MOCK-"+UUID)`. 무작위 금지. 규칙을 javadoc·주석에 명시.
- `shop-core/src/main/java/com/shop/shop/payment/service/PaymentService.java`
  - 의존 추가: `MemberDirectory`(member.spi, Mi1), `ApplicationEventPublisher`.
  - `pay` ⑤-B 거절 분기 신규(1.3): 현재 `throw new IllegalStateException(...)` 제거 → `markFailed` 전이 + `PaymentFailedEvent` 발행 + 주문 `pending` 유지(confirmPaid 미호출) + **거절 결과 반환**(C1).
  - `acquireOrResolveReadyRow` 확장(Ma1·Ma2, 1.5): 기존 row `failed` 재사용 분기 + 동시 충돌 재조회 `failed` 재사용 분기.
  - `PaymentResult` 거절 표현 확장: 거절 여부·`failureCode`·`failureReason`을 담는다(아래).
  - `amount` long 변환 헬퍼(P3, `longValueExact`, 위반 `AmountConversionException`) — order 016 헬퍼와 동일 규칙(payment 내부 private).
- `shop-core/src/main/java/com/shop/shop/payment/service/PaymentService.PaymentResult`(내부 record 수정)
  - 016 `PaymentResult(Payment payment, String orderNumber)` → 거절 표현 추가. 권장: `PaymentResult(Payment payment, String orderNumber, boolean declined, String failureCode, String failureReason)` + 정적 팩토리 `approved(payment, orderNumber)` / `declined(payment, orderNumber, failureCode, failureReason)`. (승인/멱등은 `declined=false`.)
- `shop-core/src/main/java/com/shop/shop/payment/service/PaymentServiceResponse.java`(REST)
  - `pay`: `PaymentResult` 수신 후 `result.declined()`면 `PaymentDeclinedException`(402, `failureReason`) throw(**트랜잭션 밖** — `pay`는 이미 커밋됨, C1). 아니면 기존 `dtoMapper.toPaymentResponse`(200).
- `shop-core/src/main/java/com/shop/shop/payment/service/PaymentFacadeImpl.java`(View facade)
  - `pay`: 동일 — `declined`면 `PaymentDeclinedException`(402, `failureReason`) throw(facade는 트랜잭션 밖). View 핸들러가 `BusinessException`으로 catch → flashError.

#### (B) 신규 — payment/event
- `shop-core/src/main/java/com/shop/shop/payment/event/PaymentFailedEvent.java`
  - `@org.springframework.modulith.events.Externalized("payment-failed")` record. 필드: `UUID eventId`, `Instant occurredAt`, `long orderId`, `String orderNumber`, `long memberId`, `String memberEmail`, `String memberName`, `long amount`, `String currency`, `String failureCode`, `String failureReason`, `Instant attemptedAt`. `public static final String TOPIC = "payment-failed";`(DummyOutboxSmokeEvent/OrderCompletedEvent 선례). 정적 팩토리(권장) `of(...)`로 `eventId`/`occurredAt` 채움. **event-catalog 스키마 그대로 — 계약 무변경.**

#### (B) 신규 — common/exception
- `shop-core/src/main/java/com/shop/shop/common/exception/PaymentDeclinedException.java`
  - `extends BusinessException`, `super(failureReason, HttpStatus.PAYMENT_REQUIRED)`(402). javadoc: "거절은 도메인 정상 흐름 — **트랜잭션 밖(ServiceResponse/Facade)에서만 throw**(C1). 트랜잭션 안에서 던지면 failed/이벤트가 롤백된다. 메시지는 사용자 노출 가능한 failureReason만(내부 PG 원문·failureCode 비노출)."

#### (B) 무변경(확인만) — RestExceptionHandler / SecurityConfig / OrderConfirmation / OrderPaymentReader
- `RestExceptionHandler`: `BusinessException` 핸들러가 `getStatus()`(402)를 그대로 매핑 → **수정 불필요**(확인 후 변경 없음).
- `SecurityConfig`: 016에서 `/api/v1/orders/*/payment`·`/orders/*/payment` hasRole("CONSUMER") 명시 추가 완료 → 신규 엔드포인트 없음, **변경 불필요**.
- `OrderConfirmation`/`OrderPaymentReader`: 시그니처 무변경(거절 분기는 `confirmPaid` 미호출, `getPayableOrder`만 재사용).

#### (B) 신규 — 테스트 (5절 매핑)
- `shop-core/src/test/java/com/shop/shop/payment/domain/PaymentTest.java` — markFailed/markPaid 전이(단위, 016에 없으면 신규).
- `shop-core/src/test/java/com/shop/shop/payment/service/PaymentServiceDeclineTest.java` — 거절 분기(단위, Mockito).
- `shop-core/src/test/java/com/shop/shop/payment/service/MockPaymentGatewayTest.java` — 거절 결정성 보강(016 클래스에 케이스 추가 또는 신규).
- `shop-core/src/test/java/com/shop/shop/payment/service/PaymentServiceResponseDeclineTest.java` / `PaymentFacadeImplDeclineTest.java` — 거절 결과 → 402 매핑(단위).
- `shop-core/src/test/java/com/shop/shop/payment/service/PaymentDeclineOutboxIntegrationTest.java` — 거절 커밋 시 `event_publication`에 `PaymentFailedEvent` 1건 + payload 스키마 + 주문 status/`OrderCompletedEvent` 불변(Testcontainers).
- `shop-core/src/test/java/com/shop/shop/payment/service/PaymentDeclineConcurrencyIntegrationTest.java` — 동시 2건 중 승자 거절 시 패자가 `failed` row 재사용 + `payments` row 1건 유지(Ma2, Testcontainers).
- `shop-core/src/test/java/com/shop/shop/payment/controller/PaymentRestControllerDeclineSecurityTest.java` — 402 + ErrorResponse + 내부정보 비노출(@SpringBootTest+MockMvc, @MockitoBean).
- (구조) 기존 `PaymentModuleStructureTest`에 `PaymentFailedEvent`가 payment 모듈 위치 단언 추가 + payment→order/member/product 내부참조 금지 유지.

### 2.2 view-implementor 담당 범위

#### (V) 수정/확인 — templates/order/detail.html
- `shop-core/src/main/resources/templates/order/detail.html`
  - 거절 시 flashError(거절 사유) 표시 — 기존 `fragments/messages.html`(flashError) 재사용(016에서 이미 존재). **신규 마크업 최소** — flashError 영역이 거절 메시지를 렌더하는지 확인.
  - 주문 `pending` 유지 시 결제 폼 재노출(`th:if="${payment.payable}"`) — 016 조건(`payable = pending && !paid`)이 `failed`(`paid=false`)에서도 폼을 재노출함을 확인. 결제 상태 표시는 `failed`도 "결제 대기"로 흡수(별도 분기 불필요).

#### (V) 무변경(확인만) — web 핸들러
- `shop-core/src/main/java/com/shop/shop/web/order/OrderViewController.java`
  - `pay` 핸들러가 이미 `catch (BusinessException e) → flashError + redirect`. `PaymentDeclinedException`(402)이 `BusinessException`이므로 **코드 변경 없이** 거절이 flashError로 흐른다 → **수정 불필요**(확인만). 변경 시 web→spi 단방향·기존 흐름 회귀 주의.

#### (V) 신규 — 테스트 (5절 매핑)
- `shop-core/src/test/java/com/shop/shop/view/PaymentDeclineViewRenderingTest.java`(@SpringBootTest+MockMvc, @MockitoBean PaymentFacade/OrderFacade): facade가 `PaymentDeclinedException`(402) throw 시 핸들러가 flashError + `/orders/{id}` redirect, 주문 `pending` 유지 시 결제 폼 재노출, paid 주문은 폼 미노출.

---

## 3. 데이터 흐름

### 3.1 결제 거절 — REST (POST /api/v1/orders/{orderId}/payment)
1. Security REST 체인 `/api/v1/orders/*/payment` hasRole(CONSUMER)(016). 비인증 401 JSON / ROLE 없는 인증 403 JSON.
2. `PaymentRestController.pay` → `PaymentServiceResponse.pay(auth, orderId, request)`.
3. ServiceResponse: `userId=(long)auth.getPrincipal()` → `PaymentService.pay(userId, orderId, cmd)`.
4. `PaymentService.pay`(@Transactional, 016 8단계 + ⑤-B):
   - ①~④ 016 동일(getPayableOrder 404/완결성 409 → 멱등/충돌 → 금액 → ready 선점, Ma1/Ma2 failed 재사용 포함).
   - ⑤ `authorize(...)` → 거절(`!approved`).
   - ⑤-B: `markFailed(failureCode, failureReason)`(`ready/failed→failed`) → `member.spi.findContactByUserId`(Mi1) → `PaymentFailedEvent` 구성(amount longValueExact) → `publishEvent`(Outbox) → **주문 pending 유지(confirmPaid 미호출)** → 거절 `PaymentResult` 반환.
   - ⑧ 커밋: `payments.status=failed` + `event_publication` 1행 원자 커밋(C1 — 롤백 없음).
5. ServiceResponse(커밋 후): `result.declined()` → `PaymentDeclinedException`(402, `failureReason`) throw.
6. `RestExceptionHandler` → `402 ErrorResponse`(message=`failureReason`, 내부 PG 원문/failureCode 비노출).

### 3.2 결제 거절 — View (POST /orders/{orderId}/payment)
1. Security View 체인 `/orders/*/payment` hasRole(CONSUMER). 비인증 302/login.
2. `OrderViewController.pay`(016 핸들러) → `CurrentActorResolver.resolve(auth).email()` → `OrderPaymentForm → PaymentRequest` 변환(web) → `PaymentFacade.pay(email, orderId, request)`.
3. `PaymentFacadeImpl`: `findUserIdByEmail` → `PaymentService.pay`(3.1의 4단계 동일 도메인 로직, **커밋**) → `result.declined()` → `PaymentDeclinedException`(402, `failureReason`) throw(트랜잭션 밖).
4. 핸들러 `catch (BusinessException e)` → `flashError(e.getMessage())` + `redirect:/orders/{orderId}`. 주문 `pending` 유지 → 결제 폼 재노출.

### 3.3 거절 후 재시도 승인 (failed→paid, Ma1)
1. 사용자 재요청 → ④ `acquireOrResolveReadyRow`가 기존 `failed` row 재사용(Ma1) → ⑤ `authorize` 승인(이번엔 임계 미충족) → ⑥ `markPaid`(`failed→paid`, Ma1) → ⑦ `confirmPaid`(주문 확정 + `OrderCompletedEvent`, 016 경로) → ⑧ 커밋. REST 200 / View flashSuccess.

### 3.4 PaymentFailedEvent 발행 경로 (Outbox, 004 메커니즘)
- `PaymentService`(payment 모듈)가 `ApplicationEventPublisher.publishEvent(paymentFailedEvent)`를 트랜잭션 안에서 호출 → Modulith Registry가 `event_publication` INCOMPLETE 저장(Outbox) → 커밋 후 `spring-modulith-events-kafka`가 `@Externalized("payment-failed")`로 Kafka 발행 → COMPLETED. 페이로드 자족(memberEmail/memberName/failureCode/failureReason/amount/currency) — notification 역조회 불필요.

### 3.5 동시 결제 패자 — failed 케이스 (Ma2)
- 동시 2건: 승자가 ④ ready 선점 → ⑤ 거절 → ⑤-B `failed`. 패자는 ④ INSERT `DataIntegrityViolationException` → 재조회 `failed` → **`failed` row 재사용 경로로 합류**(Ma2, NPE/미정의 동작 없음). 패자의 PG 재시도가 또 거절되면 독립 `PaymentFailedEvent`(새 `eventId`)가 추가 발행될 수 있다. `payments` row는 항상 1건 유지(`uq_payments_order_id`).

---

## 4. 예외 처리 전략 (error-response-rule 준수)

| 상황 | 발생 지점 | 예외/결과 | REST 매핑 | View 매핑 |
|---|---|---|---|---|
| **PG 거절(declined)** | PaymentService ⑤-B → 커밋 → ServiceResponse/Facade | **예외 아님(커밋)** → 커밋 후 `PaymentDeclinedException`(402) | **402** + ErrorResponse(message=failureReason)(C1·Ma3) | flashError(failureReason) → `/orders/{id}` redirect, pending 유지 |
| 타인/미존재 주문 | OrderPaymentReader 소유권(016) | OrderNotFoundException(404) | 404 존재 은닉 | error 뷰(404) |
| productId/연락처 해석 불가(PG 호출 전) | getPayableOrder 사전검증(016) | PaymentEventResolutionException(409) | 409 + 미생성 | flashError → `/orders/{id}` |
| 동시 ready 선점 경합(잔존 ready) | ④ uq 위반 후 재조회 ready(016) | PaymentInProgressException(409) | 409 | flashError → `/orders/{id}` |
| 동시 패자 재조회 failed(Ma2) | ④ uq 위반 후 재조회 failed | **예외 아님** — failed row 재사용 경로 합류 | (재시도 결과에 따름) | (재시도 결과에 따름) |
| 비정상 상태 전이(paid→failed 등) | Payment.markFailed | IllegalStateException(도메인 불변식) | 500 + 전체 롤백 | 500/error 뷰 |
| amount long 변환 위반(.00 아님/범위) | ⑤-B 페이로드 변환(P3) | AmountConversionException(500) | 500 + 전체 롤백 | 500/error 뷰 |
| 클라이언트 금액 불일치 | ③ 금액 검증(016) | PaymentAmountMismatchException(400) | 400 | flashError → `/orders/{id}` |
| 시스템 오류(저장/발행) | 트랜잭션 내 임의 단계 | RuntimeException | 500 + 전체 롤백(payments failed/이벤트 부분반영 없음) | 500/error 뷰 |

핵심 규칙:
- **거절(declined) = 402, 커밋 후 매핑(C1).** 트랜잭션 안에서 402를 던지지 않는다(롤백 방지). `PaymentDeclinedException`은 ServiceResponse/Facade(트랜잭션 밖)에서만 throw.
- **거절을 200으로 표현하지 않는다(Ma3).** 정상 `PaymentResponse`(200)는 승인/멱등 전용.
- 거절 응답·로그에 내부 PG 원문·스택트레이스·내부 `failureCode`를 노출하지 않는다(error-response-rule). `failureReason`(사용자 노출 메시지)만 `message`/flashError에 담는다. `failureCode`는 이벤트 페이로드(notification 분류용)에만.
- `paid→failed` 역전이·`longValueExact` 위반은 시스템 불변식 위반(500)이며 전체 롤백(거절 자체의 정상 커밋과 구분).
- 신규 예외 1종(`PaymentDeclinedException` 402)만 추가. 016 예외(404/409/400/500) 전부 재사용.

---

## 5. 검증 방법 (테스트 클래스 매핑 + Acceptance 매핑)

> 테스트 프로파일·Outbox 검증 방식은 016(1.1)과 동일 — Testcontainers 별도 프로파일에서 `event_publication` 저장만 검증(외부화 `enabled=false`, 실 Kafka 라운드트립 범위 밖). 거절 주입은 `PaymentGatewayPort` 모킹(`willReturn(declined(...))`).

### 단위(자동) — PaymentTest (Payment Entity)
- `markFailed`: `ready→failed` 허용 · `failed→failed` 허용(재거절 멱등) · `paid→failed` `IllegalStateException`(역전이 금지).
- `markPaid`(Ma1): `failed→paid` 허용 · `ready→paid` 회귀 없음 · `paid` 재호출 멱등.

### 단위(자동) — PaymentServiceDeclineTest (Mockito)
- PG 거절(port mock `declined`) → `payments` `failed` 기록 + `PaymentFailedEvent` 발행(ArgumentCaptor) + **`OrderConfirmation.confirmPaid` 미호출** + `OrderCompletedEvent` 미발행 + 주문 status 변경 없음.
- 거절 시 `pay`가 **예외를 던지지 않고** 거절 `PaymentResult`(`declined=true`) 반환(C1 — 트랜잭션 롤백 없음).
- `PaymentFailedEvent` 페이로드 전 필드 매핑: `eventId`(non-null UUID)·`occurredAt`·`orderId`·`orderNumber`·`memberId`(=userId)·`memberEmail`/`memberName`(member.spi `findContactByUserId`로 채움, Mi1)·`amount`(long, finalAmount longValueExact)·`currency`("KRW")·`failureCode`·`failureReason`·`attemptedAt`.
- ready 선점 분기 `failed` 재사용(Ma1): 기존 `failed` row 존재 시 신규 INSERT 없이 동일 row 재사용. 동시 충돌 재조회 `failed` 재사용(Ma2): NPE 없이 합류.
- 거절 후 재시도 승인: `failed→paid` 전이 + `confirmPaid` 호출(016 확정 경로 진입).

### 단위(자동) — MockPaymentGatewayTest
- 결정적 거절 규칙: 동일 입력(임계 충족) → 항상 `declined`(무작위 아님), 임계 미충족 → `approved`. `failureCode`가 event-catalog 코드 집합.

### 단위(자동) — PaymentServiceResponseDeclineTest / PaymentFacadeImplDeclineTest
- 거절 `PaymentResult` → `PaymentDeclinedException`(402, message=`failureReason`) throw(트랜잭션 밖 — `pay` 커밋 후). 승인/멱등은 `PaymentResponse`(200).
- 응답/예외 메시지에 내부 PG 원문·`failureCode`·스택트레이스 미포함.

### REST/Security(자동) — PaymentRestControllerDeclineSecurityTest (@SpringBootTest, MockMvc, @MockitoBean PaymentServiceResponse)
- `POST /api/v1/orders/{id}/payment` 거절 → **402** + `ErrorResponse`(status=402, error="Payment Required", message=failureReason). 내부 PG 원문/failureCode/스택트레이스 `jsonPath doesNotExist`.
- 거절이 200 `PaymentResponse`로 응답되지 않음(Ma3).
- 거절 후 재시도 승인 → 200 + `paid`.

### 통합 — Outbox·동시성 (Testcontainers PostgreSQL, 자동, 별도 프로파일)
- `PaymentDeclineOutboxIntegrationTest`: 거절 결제 커밋 시 `event_publication`에 `PaymentFailedEvent` 1건 저장 + payload 전 필수 필드(JSON) 만족 + `payments.status=failed` 영속 + **주문 status `pending` 불변** + `OrderCompletedEvent` 미저장. 거절은 정상 커밋(롤백 없음, C1). 시스템 오류(강제 예외) 시 `payments`/`event_publication` 부분 반영 없음(원자성).
- `PaymentDeclineConcurrencyIntegrationTest`: 동시 2건 중 선점 승자 거절 → 패자가 `failed` row 재사용 경로 처리 + `payments` row 1건 유지(`uq_payments_order_id`, Ma2). `PaymentFailedEvent`는 각 거절 시도마다 독립 `eventId`.
- 외부화 `enabled=false`(Outbox 저장만 검증).

### View(자동) — PaymentDeclineViewRenderingTest (@MockitoBean PaymentFacade/OrderFacade)
- facade가 `PaymentDeclinedException`(402) throw → `POST /orders/{id}/payment` 핸들러가 `flashError`(failureReason) + `redirect:/orders/{id}`.
- 거절 후 주문 `pending` 상태 상세에서 결제 폼 재노출(`payment.payable=true`).
- paid 주문은 결제 폼 미노출(회귀 확인).

### 구조(자동) — PaymentModuleStructureTest / ModularityTests
- `PaymentFailedEvent`가 payment 모듈(`com.shop.shop.payment..`)에 위치(발행 소유, package-structure-rule).
- payment가 order/member/product 내부(domain/repository/service) 미참조 — order.spi·member.spi published만(member.spi `findContactByUserId` 사용은 published port).
- `ModularityTests.verify()` 통과.

### 실행 / 수동 확인
- `./gradlew test` 전체 통과(통합 Testcontainers 자동).
- (보조 수동) docker-compose 기동 후 거절 트리거(임계 초과 금액) 결제 1건 → `payments failed`·주문 `pending` 유지·Kafka `payment-failed` 메시지 1건·재시도 승인 시 `failed→paid`·`order-completed` 1건 확인. 확인/미확인 항목을 작업 보고에 남긴다.

### Acceptance Criteria 매핑 표

| Acceptance(Task) | 검증 수단 |
|---|---|
| 거절 시 payments `failed` + 주문 `pending` 유지 | PaymentServiceDeclineTest·PaymentDeclineOutboxIntegrationTest |
| 거절 시 `PaymentFailedEvent` Outbox 저장 + 스키마(memberEmail/memberName/failureCode/failureReason/amount/currency/attemptedAt) | PaymentDeclineOutboxIntegrationTest·PaymentServiceDeclineTest |
| 거절 시 `OrderCompletedEvent` 미발행·주문 status 불변 | PaymentServiceDeclineTest·PaymentDeclineOutboxIntegrationTest |
| 재시도 승인 시 `failed→paid` + 주문 확정 + OrderCompletedEvent(Ma1) | PaymentServiceDeclineTest·PaymentTest |
| 재요청 시 payments row 1건 유지(uq) | PaymentServiceDeclineTest·PaymentDeclineConcurrencyIntegrationTest |
| 동시 승자 거절 시 패자 failed 재사용·row 1건(Ma2) | PaymentDeclineConcurrencyIntegrationTest |
| 거절 트랜잭션 예외 롤백 없이 failed/이벤트 커밋(C1) + REST 402·내부정보 비노출 | PaymentDeclineOutboxIntegrationTest·PaymentRestControllerDeclineSecurityTest |
| View 거절 flashError + `/orders/{id}` redirect + pending 유지 | PaymentDeclineViewRenderingTest |
| 거절 분기 부분 반영 없음(payments/이벤트 원자성) | PaymentDeclineOutboxIntegrationTest |
| `PaymentFailedEvent`를 payment 모듈이 발행 | PaymentModuleStructureTest·PaymentDeclineOutboxIntegrationTest |
| 016 승인 경로·OrderCompletedEvent 회귀 없음 | 016 기존 테스트 전체 통과 + PaymentTest(markPaid ready→paid 회귀) |
| event-catalog/architecture 섹션5 무변경 | 문서 diff 확인 |
| ModularityTests 통과 | ModularityTests |

---

## 6. 트레이드오프

- **거절을 정상 커밋 + 커밋 후 402 매핑(C1) vs 트랜잭션 안 402 throw**: ServiceResponse/Facade에 "거절 결과 → 예외" 변환 한 갈래가 늘지만, 트랜잭션 안에서 `BusinessException`을 던질 때의 `failed`/이벤트 동반 롤백(Acceptance 위반)을 원천 차단한다. 영속(failed 기록·알림 이벤트)과 HTTP 표현(402)의 관심사를 분리한다. 결과 영속 우선.
- **거절 결과를 `PaymentResult` 확장으로 반환 vs 거절 전용 예외를 서비스가 던짐**: `PaymentResult`에 `declined`/`failureCode`/`failureReason` 필드가 늘지만(승인/거절 단일 반환 타입), C1을 위해 서비스가 예외 없이 반환해야 하므로 결과 객체로 거절을 표현한다. 반환 타입 비대 < 트랜잭션 정합성.
- **`markFailed`가 사유를 받지만 Entity에 영속 안 함(옵션 A) vs 컬럼 추가(옵션 B)**: 신규 migration을 피하고(기존 migration 무수정) 사유는 이벤트·402 응답에만 싣는다. 거절 사유를 DB에서 재조회·이력 통계할 요구가 본 Task에 없으므로 옵션 A로 충분. 거절 이력 영속이 필요해지면 후속 Task `V4`(옵션 B)로 확장 — 본 Task 범위 밖. migration 무증가 우선.
- **ready 선점에 failed 재사용 분기 추가(Ma1) vs failed를 in-progress(409)로 취급**: `failed`는 "진행 중"이 아니라 "재시도 가능"이므로 `PaymentInProgressException`(409)로 막지 않고 동일 row를 재사용한다. 분기 한 갈래가 늘지만, 거절이 재결제를 영구 차단(409 막다른 상태)하는 결함을 막는다. `uq_payments_order_id` 불변식(주문당 1 row)은 유지.
- **동시 패자 failed 합류 정의(Ma2) vs 미정의**: 선점 승자 거절로 `failed` row가 남은 뒤 패자 재조회가 `failed`를 만나는 케이스를 명시 정의(재사용 경로 합류)해 NPE·미정의 동작을 제거한다. 동시성 통합 테스트로 검증. 정의 비용 < 운영 비결정성.
- **`PaymentFailedEvent`를 payment 모듈이 발행(package-structure-rule) vs order가 발행**: 016 `OrderCompletedEvent`(order 발행)와 발행 소유 모듈이 다르지만, 결제 실패는 payment 도메인 사건이므로 payment가 발행 소유한다. payment가 `member.spi`로 연락처를 직접 조회(Mi1)하는 추가 의존이 생기지만, member.spi는 published port라 구조 규칙 위반 아님(구조 테스트로 보장).
- **연락처를 payment가 member.spi로 직접 조회(Mi1) vs order 스냅샷이 연락처 반환**: `OrderPaymentView`에 연락처 필드를 추가하지 않고(016 포트 무변경) payment가 `findContactByUserId`로 직접 조회한다. PG 호출 전(1단계 완결성 검증)에 해석 가능함이 보장되므로 "거절 후 연락처 누락"이 없다. 포트 안정성(016 무변경) 우선.
- **REST 거절 = 402 단일 확정(Ma3) vs 200 본문에 declined 표현**: 거절을 200 `PaymentResponse`(declined 플래그)로 표현하면 정상/실패 본문이 혼용되어 클라이언트 분기·캐시·재시도 정책이 모호해진다. 402 + ErrorResponse로 단일화해 HTTP 의미론을 명확히 한다. 200 혼용 금지.
- **MockPaymentGateway 결정적 거절 규칙 vs 무작위**: 임계 기반 결정 규칙으로 단위 테스트 재현성을 확보한다(무작위 금지). 데모는 임계 한 가지만 노출 — 실 PG 전환 시 이 컴포넌트만 교체(포트 무변경). 결정성 > 데모 다양성.
- **Outbox 통합은 event_publication 저장만 검증(실 Kafka 제외)**: 테스트 프로파일이 Kafka 자동설정 exclude(004 트레이드오프) → 실 브로커 외부화는 범위 밖. Outbox 원자성·payload 스키마는 Testcontainers로 자동 검증, 실 Kafka E2E는 별도 Task/E2E.
- **거절/취소/환불/재고복원/TTL/실PG/이벤트 계약변경 미구현**: Task Constraint 준수. 017은 거절 failure path + `PaymentFailedEvent`까지. 016 승인 경로는 무변경(거절 분기 + `markPaid` Ma1 확장만 추가).

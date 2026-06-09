# 017. shop-core 모의 결제 거절 처리 + PaymentFailedEvent 발행

## Target
shop-core

---

## Goal
`016`에서 구현한 모의 결제 승인 흐름에 **결제 거절(declined) 분기**를 추가한다. 모의 PG가 거절하면 `payments`를 `failed`로 기록하고 `PaymentFailedEvent`를 Transactional Outbox로 발행하며, 주문은 `pending`으로 유지해 재시도할 수 있게 한다. REST·View에서 거절 결과를 일관되게 응답·표시한다.

> 이 Task는 결제 흐름의 **failure path**만 다룬다. 승인 경로·주문 확정·`OrderCompletedEvent`는 `016`에서 이미 구현되어 있다.

---

## Context
- 결제 흐름은 두 Task로 분리되어 있다
  - **`016`**: 모의 결제 승인 + 주문 확정 + `OrderCompletedEvent` (구현 완료 전제)
  - **`017`(이 Task)**: 결제 거절 처리 + `PaymentFailedEvent`
- `016`에서 다음이 이미 존재한다(이 Task는 그 위에 거절 분기를 더한다)
  - `payment` 모듈: `Payment` Entity(`ready`/`paid`), `PaymentService`, `PaymentGatewayPort`(승인/거절을 표현할 수 있는 시그니처 + `idempotencyKey`, 모의 구현은 항상 승인), REST `POST/GET /api/v1/orders/{orderId}/payment`, 주문 상세 결제 폼
  - `order` 모듈: `OrderConfirmation` port, `OrderPaymentReader`(결제 준비 `getPayableOrder` + 상태 조회 `getOrderSnapshot` 분리), `Order.markPaid()`, `OrderCompletedEvent`
  - `member.spi` `userId`→`email`/`name` 조회, `product.spi` `variantId`→`productId` 조회
- `016` 결제 처리는 **PG 호출 전 `payments` `ready` row를 INSERT해 `uq_payments_order_id`로 동시 요청을 직렬화**한다(선점 1건만 PG 도달, 경합 측은 `PaymentInProgressException` 409). 이 Task의 거절 분기는 선점한 `ready` row를 `failed`로 전이한다(`ready`→`failed`)
- **stale `ready`/`failed` row 정리 정책(016 plan 남은 리스크 #1 이관)**
  - `016`/`017`은 결제를 **단일 동기 트랜잭션**으로 처리하므로, 트랜잭션 종료 시 `ready` 잔존이 정상적으로 발생하지 않는다(승인→`paid`, 거절→`failed`, 실패→롤백으로 row 제거)
  - 다만 향후 **비동기 PG** 도입이나 트랜잭션 비정상 중단 시 `ready` row가 영구 잔존하면 재결제가 계속 `409 PaymentInProgressException`으로 막힐 수 있다
  - 이 Task는 거절 후 재시도가 **기존 `payments` row(`ready`/`failed`)를 재사용**해 `uq_payments_order_id` 위반 없이 재승인/재거절하도록 보장한다(신규 row insert 금지)
  - `ready`/`failed` row의 **만료(TTL)·정리(cleanup) 스케줄러는 이 Task 범위 밖**이며, 비동기 PG·주문 취소/만료 Task에서 도입한다(여기서는 제약으로만 명시)
- `payments.status` CHECK는 `ready`/`paid`/`failed`/`cancelled`/`refunded`를 허용한다. 이 Task는 `failed` 기록을 추가한다
- `PaymentFailedEvent`(topic `payment-failed`) 페이로드 스키마는 `docs/event-catalog.md`에 이미 정의되어 있다. **이 Task에서 이벤트 계약을 추가·변경하지 않는다**
- 패키지 구조 규칙(`package-structure-rule`)상 **`PaymentFailedEvent`는 `payment` 모듈이 발행 소유**한다
- 이벤트 발행은 `004`에서 구성한 Spring Modulith Event Publication Registry(Transactional Outbox) + `@Externalized` Kafka 외부화 경로를 사용한다
- 이벤트 페이로드는 자족적이어야 한다(`event-contract-rule`). `memberEmail`/`memberName`은 `016`에서 추가한 `member.spi`로 채운다. notification이 shop-core를 역조회하지 않는다
- 거절 시 재고 복원은 하지 않는다. 주문이 `pending`으로 유지되어 재시도 가능하며, 재고 복원·주문 만료는 별도(주문 취소/만료) Task에서 다룬다

## API Authorization
`016`의 결제 엔드포인트 권한 정책을 그대로 따른다(신규 엔드포인트 없음).

| API | 공개 여부 | 최소 권한 | 상위 권한 허용 | 소유권 검사 | 비고 |
|---|---|---|---|---|---|
| `POST /api/v1/orders/{orderId}/payment` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 거절 분기 추가 — 응답 코드만 달라짐 |
| `POST /orders/{orderId}/payment` | authenticated | `ROLE_CONSUMER` | `ROLE_SELLER`, `ROLE_ADMIN` | 필요 | 거절 시 flashError 처리 추가 |

- 다른 사용자의 주문에 대한 결제 요청은 404 존재 은닉으로 통일한다(`016`과 동일)

## Requirements
- `PaymentGatewayPort`의 **모의 구현에 거절 분기를 활성화**한다
  - 거절 결과는 `failureCode`(예: `INSUFFICIENT_FUNDS`, `LIMIT_EXCEEDED`, `CARD_DECLINED`)와 `failureReason`(사람이 읽는 메시지)을 반환한다
  - 거절 경로는 **결정적**이어야 한다(무작위 금지). 단위 테스트는 port를 모킹해 거절을 주입하고, 데모용으로는 결정적 규칙 한 가지만 문서화한다(예: 특정 금액 임계값 또는 특정 method/카드번호로 거절)
  - `016`에서 합의한 포트 시그니처를 변경하지 않는다(거절을 표현하는 필드는 이미 존재)
- `Payment` Entity에 `failed` 전이 의도 메서드(`markFailed(failureCode, failureReason)`)를 추가한다
  - Setter 금지. `failed`는 `ready`/기존 `failed`(재시도)에서만 전이 가능하고, `paid`에서 `failed`로의 역전이는 도메인 예외로 막는다
  - `failureCode`/`failureReason`을 `Payment`에 보유할 수 있다(컬럼이 없으면 신규 migration 없이 보유 가능한 범위로 처리 — 아래 Constraints 참조)
- `PaymentService` 결제 처리에 거절 분기를 추가한다(`016` 단계 순서 확장)
  1. `OrderPaymentReader.getPayableOrder`로 준비 스냅샷 조회·소유권 검증·이벤트 완결성 사전검증(404 존재 은닉, productId 해석 불가/비정상 상태 409) — `016`과 동일. 거절 분기 페이로드에 필요한 member 연락처도 이 단계에서 확보한다
  2. 이미 `paid`면 멱등 반환 — `016`과 동일
  3. 모의 PG 승인 요청
  4. **승인**: `016` 경로(payments `paid` + `OrderConfirmation.confirmPaid` + `OrderCompletedEvent`) — 변경 없음
  5. **거절**: `payments`를 `failed`로 기록하고 `PaymentFailedEvent`를 발행한다. 주문은 `pending`으로 유지한다(상태 변경·`OrderConfirmation` 호출·`OrderCompletedEvent` 발행 없음)
  6. 커밋
- `PaymentFailedEvent`를 `payment/event`에 `@Externalized("payment-failed")`로 정의·발행한다
  - 페이로드는 `docs/event-catalog.md`의 `PaymentFailedEvent` 스키마를 그대로 따른다
    - `orderId`, `orderNumber`, `memberId`(=주문 `userId`), `memberEmail`, `memberName`, `amount`(결제 시도 금액=주문 `finalAmount`), `currency`(`KRW`), `failureCode`, `failureReason`, `attemptedAt`, 공통 봉투(`eventId`, `occurredAt`)
    - `memberEmail`/`memberName`은 `016`의 `OrderPaymentReader` 스냅샷(member 연락처 사전 해석 포함) 또는 `member.spi`로 조회한다. 거절 분기도 PG 호출 전(1단계)에 연락처 해석을 완료해 둔다
    - `amount`는 `numeric(12,2)`(BigDecimal) → `long` 변환 규칙을 `016`(P3)과 동일하게 적용한다: 소수부 0만 허용, `BigDecimal.longValueExact()`로 변환, 위반 시 도메인 예외
  - 발행은 `payment` 트랜잭션 안에서 `ApplicationEventPublisher`로 수행한다(같은 트랜잭션 = Outbox 저장)
- 거절 후 재시도 멱등/일관성을 정의한다
  - `uq_payments_order_id`로 주문당 결제 row는 1건이다. 거절 후 재요청은 동일 row를 `failed`→재승인 시도로 갱신한다(신규 row insert로 unique 위반을 내지 않는다)
  - 재시도가 승인되면 `016` 승인 경로(`paid` + 주문 확정 + `OrderCompletedEvent`)로 진행한다
  - 재시도가 다시 거절되면 `PaymentFailedEvent`가 다시 발행될 수 있다(각 시도가 독립 이벤트). `eventId`는 시도마다 새로 생성한다(컨슈머 멱등은 `eventId` 기준)
- REST 거절 응답을 일관 코드로 정의한다
  - 권장: `402 Payment Required`. `BusinessException` 상태 매핑을 추가하거나 채택 코드를 task/코드 주석에 명시한다
  - 응답 본문은 `error-response-rule`의 `ErrorResponse` 포맷을 따른다(내부 정보 비노출). `failureReason`은 사용자 노출 가능한 메시지만 담는다
  - `PaymentResponse`에 거절 표현 필드(`status=failed`, `failureCode`, `failureReason`)를 노출하는 설계도 허용한다. 단 REST 에러 응답과 정상 응답 본문을 혼용하지 않고 일관되게 한다(채택안을 task/코드에 명시)
- View 거절 처리를 추가한다
  - 주문 상세 결제 폼 제출이 거절되면 flashError로 거절 사유를 표시하고 `/orders/{orderId}`로 redirect한다
  - 주문은 `pending`으로 유지되어 결제 폼이 다시 노출된다(재시도 가능)
- Entity를 API 응답이나 View 모델에 직접 전달하지 않는다
- 관련 단위 테스트, 통합(Outbox 발행) 테스트, REST/Security 테스트, View 렌더링 테스트, 구조 테스트를 작성한다

## Constraints
- 이번 Task에서 결제 취소·환불·부분환불을 구현하지 않는다
- 이번 Task에서 거절 시 재고를 복원하지 않는다(주문 `pending` 유지, 재시도 가능). 재고 복원·주문 만료는 별도 Task
- 이번 Task에서 실제 PG 연동을 하지 않는다(모의 PG 거절 시뮬레이션만)
- 이번 Task에서 Kafka 이벤트 계약(`docs/event-catalog.md`, `docs/architecture.md` 섹션 5)을 변경하지 않는다. 기존 `PaymentFailedEvent` 스키마를 그대로 사용한다
- 이번 Task에서 `016`의 승인 경로·`OrderCompletedEvent`·주문 확정 로직을 변경하지 않는다(거절 분기만 추가)
- 기존 migration을 수정하지 않는다
  - `payments`에 `failureCode`/`failureReason` 전용 컬럼이 없다. 신규 migration **없이** 처리하는 것을 우선한다
    - 옵션 A(권장): `failureCode`/`failureReason`은 `payments`에 영속화하지 않고 `PaymentFailedEvent` 페이로드와 REST 응답에만 싣는다(`payments.status=failed`만 영속). 거절 사유 영속이 필요해지면 후속 Task에서 migration으로 컬럼을 추가한다
    - 옵션 B: 신규 migration(`V4`)로 `payment_failures` 보조 테이블 또는 `payments.failure_code`/`failure_reason` 컬럼을 추가한다. 채택 시 `docs/rules/*`(flyway/architecture) 준수
    - 채택안을 plan/코드에 명시한다
- 결제 거절 분기/`payments failed` 기록/`PaymentFailedEvent` 발행은 하나의 트랜잭션에서 처리한다. 실패 시 부분 반영이 없어야 한다
- 거절은 도메인 정상 흐름이므로 스택트레이스·내부 PG 응답 원문을 응답·로그에 노출하지 않는다(`error-response-rule` 금지 항목)
- Controller에서 비즈니스 로직을 작성하지 않는다
- DTO와 Entity를 분리한다
- `payment` 모듈은 order/member/product 내부 구현을 직접 참조하지 않고 published API 또는 scalar만 사용한다
- `notification` 코드나 DB를 참조하지 않는다

## Files
- `shop-core/src/main/java/com/shop/shop/payment/service/**`
- `shop-core/src/main/java/com/shop/shop/payment/domain/**`
- `shop-core/src/main/java/com/shop/shop/payment/dto/**`
- `shop-core/src/main/java/com/shop/shop/payment/event/**`
- `shop-core/src/main/java/com/shop/shop/payment/spi/**` (모의 PG 거절 구현)
- `shop-core/src/main/java/com/shop/shop/payment/controller/**`
- `shop-core/src/main/java/com/shop/shop/common/exception/**` (402 매핑 필요 시)
- `shop-core/src/main/java/com/shop/shop/web/payment/**` 또는 `web/order/**`
- `shop-core/src/main/resources/templates/order/detail.html`
- `shop-core/src/main/resources/templates/payment/**`
- (옵션 B 채택 시) `shop-core/src/main/resources/db/migration/V4__*.sql`
- `shop-core/src/test/java/com/shop/shop/payment/**`
- `shop-core/src/test/java/com/shop/shop/web/**`
- `shop-core/src/test/java/com/shop/shop/view/**`
- `shop-core/src/test/java/com/shop/shop/security/**`

## Module Boundary Contract

| 항목 | 위치 | 규칙 |
|---|---|---|
| Payment Service 거절 분기 | `payment/service` | 모의 PG 거절 처리, `payments failed` 기록, `PaymentFailedEvent` 발행 |
| PaymentFailedEvent | `payment/event` | `payment` 모듈 발행 소유, `@Externalized("payment-failed")` |
| 모의 PG 거절 구현 | `payment/spi` 구현체 | 결정적 거절 규칙, 실 PG 교체 가능 |
| Member contact port | `member/spi` | `016`에서 추가한 `userId`→`email`/`name` 재사용 |
| 거절 응답 DTO/View | `payment/dto` 또는 `web/**` | Entity 직접 노출 금지, 내부 PG 원문 비노출 |

## Backend - View Contract

| 항목 | 값 |
|---|---|
| 결제 폼 action | `POST /orders/{orderId}/payment` (`016`과 동일) |
| 결제 거절 처리 | flashError(거절 사유) 후 `/orders/{orderId}` redirect |
| 거절 후 주문 상태 | `pending` 유지 → 결제 폼 재노출(재시도 가능) |

## API Response Contract
- 거절 REST 응답: 채택 코드(권장 `402`)로 일관 응답, `ErrorResponse` 포맷
- `PaymentResponse`에 `status=failed`, `failureCode`, `failureReason`를 표현할 수 있다(채택안 명시)
- 내부 PG 응답 원문·스택트레이스는 응답에 포함하지 않는다

## Acceptance Criteria
- 모의 PG 거절 시 `payments`가 `failed`로 기록되고 주문은 `pending`으로 유지된다
- 모의 PG 거절 시 `PaymentFailedEvent`가 같은 트랜잭션의 Outbox(`event_publication`)에 저장되고, 페이로드가 `event-catalog`의 `PaymentFailedEvent` 스키마(`memberEmail`/`memberName`/`failureCode`/`failureReason`/`amount`/`currency`/`attemptedAt`)를 만족한다
- 거절 시 `OrderCompletedEvent`는 발행되지 않고 주문 status는 변경되지 않는다
- 거절된 결제를 재시도해 승인되면 `paid`로 전이되고 주문이 확정되며 `OrderCompletedEvent`가 발행된다(`016` 경로)
- 거절 후 재요청 시 `payments` row가 1건을 유지한다(`uq_payments_order_id` 위반 없음)
- `REST POST /api/v1/orders/{orderId}/payment` 거절은 채택 코드(권장 402)로 일관 응답하고 내부 정보를 노출하지 않는다
- View 결제 폼 제출 거절 시 flashError가 표시되고 `/orders/{orderId}`로 redirect되며 주문은 `pending`으로 유지된다
- 거절 분기 트랜잭션이 부분 반영되지 않는다(`payments`/이벤트 원자성)
- `PaymentFailedEvent`는 `payment` 모듈이 발행한다
- `016`의 승인 경로·`OrderCompletedEvent` 동작이 회귀 없이 유지된다
- `docs/event-catalog.md`와 `docs/architecture.md` 섹션 5(이벤트 계약)는 무변경이다
- `ModularityTests.verify()`를 포함한 관련 테스트가 통과한다

## Test
- `./gradlew test`
- 권장 단위 테스트(payment)
  - 모의 PG 거절(port mock) 시 `payments failed` 기록 + `PaymentFailedEvent` 발행 + order 확정 미호출 + `OrderCompletedEvent` 미발행
  - `Payment.markFailed`가 `paid`에서 거절로 역전이 금지
  - 거절 후 재시도 승인 시 `paid` 전이 + 주문 확정 경로 진입
  - 거절 후 재요청 시 동일 row 갱신(신규 row insert 없음)
  - `PaymentFailedEvent` 페이로드 필드 매핑(memberEmail/memberName/failureCode/failureReason/amount/currency/attemptedAt) 검증
- 권장 모의 PG 테스트
  - 결정적 거절 규칙이 동일 입력에 동일 결과(무작위 아님)
- 권장 통합 테스트(Outbox 발행, Testcontainers PostgreSQL + Modulith)
  - 거절 결제 커밋 시 `event_publication`에 `PaymentFailedEvent`가 1건 저장되고 payload가 스키마를 만족한다
  - 거절 분기 시 주문 status·`OrderCompletedEvent`가 변하지 않는다
  - 거절 트랜잭션 롤백 시 `payments`/`event_publication` 부분 반영 없음
  - 테스트 기본 프로파일의 자동설정 제외와 충돌하지 않게 별도 통합 프로파일에서 실행한다
- 권장 REST/Security 테스트
  - `POST /api/v1/orders/{orderId}/payment` 거절 시 채택 코드(권장 402)
  - 거절 응답에 내부 PG 원문·스택트레이스 미포함
  - 거절 후 재시도 승인 200 + `paid`
- 권장 View 테스트
  - 결제 거절 시 flashError 표시 + 주문 `pending` 유지 + 결제 폼 재노출
- 권장 구조 테스트
  - `PaymentFailedEvent`가 `payment` 모듈에 위치
  - `payment` 모듈이 order/member/product 내부 구현을 직접 참조하지 않음
  - `ModularityTests.verify()` 통과

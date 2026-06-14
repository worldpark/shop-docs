# Event Catalog — 이벤트 페이로드 스키마 (SSOT)

> 이 문서는 shop-core가 발행하고 notification이 구독하는 **이벤트 페이로드 스키마의 SSOT**다.
> 시스템 상위 구조·통신 방향은 `docs/architecture.md`, 이벤트 작성·변경 규칙은 `docs/rules/event-contract-rule.md`를 따른다.
> 토픽 목록은 `docs/architecture.md` 섹션 5에도 요약되어 있으며, 이 문서가 필드 레벨 상세의 단일 출처다.

## 공통 봉투(Envelope)

모든 이벤트는 아래 필드를 **공통으로** 포함한다(멱등·추적용).

| 필드 | 타입 | 설명 |
|---|---|---|
| `eventId` | UUID(string) | 이벤트 고유 식별자. 컨슈머 멱등 키 |
| `occurredAt` | string(ISO-8601, UTC) | 이벤트 발생 시각 |

> 페이로드는 **자족적**으로 구성한다(컨슈머가 shop-core를 재조회하지 않도록). 알림 발송에 필요한 수신자 정보(`memberEmail`, `memberName` 등)를 페이로드에 포함한다.
> 토픽 이름은 kebab-case, 이벤트 타입은 PascalCase 클래스명을 쓴다.

## OrderCompletedEvent (topic: `order-completed`)

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `eventId` | UUID | ✓ | 공통 봉투 |
| `occurredAt` | ISO-8601 | ✓ | 공통 봉투 |
| `orderId` | long | ✓ | 주문 PK |
| `orderNumber` | string | ✓ | 사용자 노출용 주문번호 |
| `memberId` | long | ✓ | 주문 회원 PK |
| `memberEmail` | string | ✓ | 알림 수신 이메일 |
| `memberName` | string | ✓ | 수신자 이름 |
| `items` | array | ✓ | 주문 항목 목록 |
| `items[].productId` | long | ✓ | 상품 PK |
| `items[].productName` | string | ✓ | 상품명(주문 시점 스냅샷) |
| `items[].quantity` | int | ✓ | 수량 |
| `items[].unitPrice` | long | ✓ | 단가(최소 화폐 단위, KRW=원) |
| `totalAmount` | long | ✓ | 결제 총액 |
| `currency` | string | ✓ | 통화 코드(예: `KRW`) |
| `orderedAt` | ISO-8601 | ✓ | 주문 확정 시각 |

```json
{
  "eventId": "9f1c2e3a-...",
  "occurredAt": "2026-06-03T04:21:00Z",
  "orderId": 1024,
  "orderNumber": "ORD-20260603-001024",
  "memberId": 77,
  "memberEmail": "buyer@example.com",
  "memberName": "김철수",
  "items": [
    { "productId": 5, "productName": "무선 키보드", "quantity": 2, "unitPrice": 39000 }
  ],
  "totalAmount": 78000,
  "currency": "KRW",
  "orderedAt": "2026-06-03T04:21:00Z"
}
```

## PaymentFailedEvent (topic: `payment-failed`)

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `eventId` | UUID | ✓ | 공통 봉투 |
| `occurredAt` | ISO-8601 | ✓ | 공통 봉투 |
| `orderId` | long | ✓ | 주문 PK |
| `orderNumber` | string | ✓ | 사용자 노출용 주문번호 |
| `memberId` | long | ✓ | 회원 PK |
| `memberEmail` | string | ✓ | 알림 수신 이메일 |
| `memberName` | string | ✓ | 수신자 이름 |
| `amount` | long | ✓ | 결제 시도 금액 |
| `currency` | string | ✓ | 통화 코드 |
| `failureCode` | string | ✓ | 실패 코드(예: `INSUFFICIENT_FUNDS`) |
| `failureReason` | string | ✓ | 실패 사유(사람이 읽는 메시지) |
| `attemptedAt` | ISO-8601 | ✓ | 결제 시도 시각 |

```json
{
  "eventId": "1a2b3c4d-...",
  "occurredAt": "2026-06-03T04:25:10Z",
  "orderId": 1025,
  "orderNumber": "ORD-20260603-001025",
  "memberId": 78,
  "memberEmail": "buyer2@example.com",
  "memberName": "이영희",
  "amount": 120000,
  "currency": "KRW",
  "failureCode": "INSUFFICIENT_FUNDS",
  "failureReason": "한도 초과로 결제가 거절되었습니다.",
  "attemptedAt": "2026-06-03T04:25:09Z"
}
```

## OrderCancelledEvent (topic: `order-cancelled`)

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `eventId` | UUID | ✓ | 공통 봉투 |
| `occurredAt` | ISO-8601 | ✓ | 공통 봉투 |
| `orderId` | long | ✓ | 주문 PK |
| `orderNumber` | string | ✓ | 사용자 노출용 주문번호 |
| `memberId` | long | ✓ | 회원 PK |
| `memberEmail` | string | ✓ | 알림 수신 이메일 |
| `memberName` | string | ✓ | 수신자 이름 |
| `items` | array | ✓ | 취소 항목 목록 (삭제된 variant 제외) |
| `items[].productId` | long | ✓ | 상품 PK |
| `items[].productName` | string | ✓ | 상품명(주문 시점 스냅샷) |
| `items[].quantity` | int | ✓ | 수량 |
| `refunded` | boolean | ✓ | 환불 여부 (결제완료 취소=true, 미결제 취소=false) |
| `refundedAmount` | long | ✓ | 환불 금액(최소 화폐 단위, KRW=원). 미결제 취소=0 |
| `currency` | string | ✓ | 통화 코드(예: `KRW`) |
| `cancelledAt` | ISO-8601 | ✓ | 취소 처리 시각 |

```json
{
  "eventId": "a1b2c3d4-...",
  "occurredAt": "2026-06-10T10:00:00Z",
  "orderId": 1024,
  "orderNumber": "ORD-20260610-001024",
  "memberId": 77,
  "memberEmail": "buyer@example.com",
  "memberName": "김철수",
  "items": [
    { "productId": 5, "productName": "무선 키보드", "quantity": 2 }
  ],
  "refunded": true,
  "refundedAmount": 78000,
  "currency": "KRW",
  "cancelledAt": "2026-06-10T10:00:00Z"
}
```

## MemberRegisteredEvent (topic: `member-registered`)

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `eventId` | UUID | ✓ | 공통 봉투(멱등 키) |
| `occurredAt` | ISO-8601(UTC) | ✓ | 공통 봉투(발행 시각 — `Instant.now()`, 커밋 직전) |
| `memberId` | long | ✓ | 회원 PK |
| `memberEmail` | string | ✓ | 환영 메일 수신 이메일 |
| `memberName` | string | ✓ | 수신자 이름 |

```json
{
  "eventId": "b7d4e1f2-0000-0000-0000-000000000005",
  "occurredAt": "2026-06-14T05:00:00Z",
  "memberId": 101,
  "memberEmail": "welcome@example.com",
  "memberName": "신규회원"
}
```

## ShippingStartedEvent (topic: `shipping-started`)

> **020 배송 단위 개정**: `shipmentId`(long) + `items[]`(productId·productName·quantity) 추가.
> 발행 주체: `order` 모듈. 소비자: `notification`(미구현 — 현재 구독 없음).
> 필드 상세 SSOT: 본 문서. 토픽 목록은 `docs/architecture.md` §5 참조.

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `eventId` | UUID | ✓ | 공통 봉투 |
| `occurredAt` | ISO-8601 | ✓ | 공통 봉투 (shippedAt과 동일 값) |
| `orderId` | long | ✓ | 주문 PK |
| `orderNumber` | string | ✓ | 사용자 노출용 주문번호 |
| `shipmentId` | long | ✓ | 배송 PK (배송 단위 식별자, 020 추가) |
| `memberId` | long | ✓ | 회원 PK |
| `memberEmail` | string | ✓ | 알림 수신 이메일 |
| `memberName` | string | ✓ | 수신자 이름 |
| `carrier` | string | ✓ | 택배사명 |
| `trackingNumber` | string | ✓ | 운송장 번호 |
| `items` | array | ✓ | 이 배송에 포함된 항목 목록 (주문 전체 아님, 020 추가) |
| `items[].productId` | long | ✓ | 상품 PK (product.spi 해석값) |
| `items[].productName` | string | ✓ | 상품명 (주문 시점 스냅샷) |
| `items[].quantity` | int | ✓ | 수량 (주문 시점 스냅샷) |
| `shippedAt` | ISO-8601 | ✓ | 배송 시작 시각 |

```json
{
  "eventId": "5e6f7a8b-...",
  "occurredAt": "2026-06-03T09:00:00Z",
  "orderId": 1024,
  "orderNumber": "ORD-20260603-001024",
  "shipmentId": 55,
  "memberId": 77,
  "memberEmail": "buyer@example.com",
  "memberName": "김철수",
  "carrier": "CJ대한통운",
  "trackingNumber": "1234567890",
  "items": [
    { "productId": 5, "productName": "무선 키보드", "quantity": 2 }
  ],
  "shippedAt": "2026-06-03T09:00:00Z"
}
```

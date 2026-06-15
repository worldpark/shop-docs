# Event Catalog — 이벤트 페이로드 스키마 (SSOT)

> 이 문서는 shop-core가 발행하고 notification이 구독하는 **이벤트 페이로드 스키마의 SSOT**다.
> 시스템 상위 구조·통신 방향은 `docs/architecture.md`, 이벤트 작성·변경 규칙은 `docs/rules/event-contract-rule.md`를 따른다.
> 토픽 목록은 `docs/architecture.md` 섹션 5에도 요약되어 있으며, 이 문서가 필드 레벨 상세의 단일 출처다.

## 토픽 인덱스 (커버리지)

> shop-core가 발행하고 **notification이 구독**하는 알림 계약 토픽은 아래 6종이다. 각 이벤트는 Spring Modulith `@Externalized`로 외부화되어 Outbox(`event_publication`) → Kafka로 발행되고, notification의 `NotificationEventConsumer`가 `groupId="notification"`으로 구독한다(코드 대조 확인: 2026-06-14).

| 토픽 | 이벤트 | 발행 모듈 | 구독자 | 발행 계기(Task) |
|---|---|---|---|---|
| `order-completed` | OrderCompletedEvent | order | notification | 결제 승인·주문 확정(016) |
| `payment-failed` | PaymentFailedEvent | payment | notification | 결제 거절(017) |
| `order-cancelled` | OrderCancelledEvent | order | notification | 주문 취소·환불(018) / 미결제 만료 자동취소(022) |
| `shipping-started` | ShippingStartedEvent | order | notification | 배송 시작(020) |
| `member-registered` | MemberRegisteredEvent | member | notification | 회원가입 환영(028) |
| `password-reset-requested` | PasswordResetRequestedEvent | member | notification | 비밀번호 재설정(030) |

> **비-알림 인프라 토픽(참고 — 계약 아님)**: `shop-core-smoke-test`(`DummyOutboxSmokeEvent`: `eventId`/`occurredAt`/`message`)는 platform 모듈의 **Outbox·Kafka 외부화 스모크 테스트용**(024-1)이며 **notification이 구독하지 않는다**. 알림 페이로드 계약이 아니므로 본 카탈로그 SSOT 대상에서 제외한다(드리프트 아님).
>
> **무이벤트 도메인 동작(참고)**: 쿠폰 발급·적용(031), 리뷰(032 예정), 계정 self-service(029), 배송 완료(021)는 **신규 이벤트를 발행하지 않는다**(내부 상태 변경). 특히 쿠폰 할인은 `OrderCompletedEvent.totalAmount`/`OrderCancelledEvent.refundedAmount`가 이미 **할인 후 최종 금액**(`Order.finalAmount`/실 결제액)을 싣고 있어 계약 무변경으로 자동 반영된다.

## 공통 봉투(Envelope)

모든 이벤트는 아래 필드를 **공통으로** 포함한다(멱등·추적용).

| 필드 | 타입 | 설명 |
|---|---|---|
| `eventId` | UUID(string) | 이벤트 고유 식별자. 컨슈머 멱등 키 |
| `occurredAt` | string(ISO-8601, KST +09:00) | 이벤트 발생 시각 |

> **시각 표기 규약(ADR-009)**: 모든 시각 필드는 **KST 오프셋 ISO-8601**(`+09:00`, 예: `2026-06-15T14:30:00+09:00`)로 직렬화한다. 이전 UTC(`...Z`) 표기와 **동일 절대시각**이며, `Instant`로 역직렬화하는 컨슈머는 변경 없이 같은 시각으로 수신한다(오프셋 흡수). 저장값은 `timestamptz`로 절대시각 보존, 표현만 KST.
>
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
  "occurredAt": "2026-06-03T13:21:00+09:00",
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
  "orderedAt": "2026-06-03T13:21:00+09:00"
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
  "occurredAt": "2026-06-03T13:25:10+09:00",
  "orderId": 1025,
  "orderNumber": "ORD-20260603-001025",
  "memberId": 78,
  "memberEmail": "buyer2@example.com",
  "memberName": "이영희",
  "amount": 120000,
  "currency": "KRW",
  "failureCode": "INSUFFICIENT_FUNDS",
  "failureReason": "한도 초과로 결제가 거절되었습니다.",
  "attemptedAt": "2026-06-03T13:25:09+09:00"
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
  "occurredAt": "2026-06-10T19:00:00+09:00",
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
  "cancelledAt": "2026-06-10T19:00:00+09:00"
}
```

## MemberRegisteredEvent (topic: `member-registered`)

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `eventId` | UUID | ✓ | 공통 봉투(멱등 키) |
| `occurredAt` | ISO-8601(KST +09:00) | ✓ | 공통 봉투(발행 시각 — `Instant.now()`, 커밋 직전) |
| `memberId` | long | ✓ | 회원 PK |
| `memberEmail` | string | ✓ | 환영 메일 수신 이메일 |
| `memberName` | string | ✓ | 수신자 이름 |

```json
{
  "eventId": "b7d4e1f2-0000-0000-0000-000000000005",
  "occurredAt": "2026-06-14T14:00:00+09:00",
  "memberId": 101,
  "memberEmail": "welcome@example.com",
  "memberName": "신규회원"
}
```

## PasswordResetRequestedEvent (topic: `password-reset-requested`)

> 발행 주체: `member` 모듈. 소비자: `notification`(비밀번호 재설정 메일 렌더링·DLQ 재처리 매핑 구현).
> 비로그인 흐름 — 이메일 존재 여부와 무관하게 응답은 동일(enumeration 방지). 이메일이 존재할 때만 이벤트 발행.
> 필드 상세 SSOT: 본 문서. 토픽 목록은 `docs/architecture.md` §5 참조.
>
> **Outbox 한계 주의**: `resetUrl`에 평문 토큰이 담겨 `event_publication.serialized_event`에 잔존하나,
> 유효성은 Redis 키로만 판정(TTL 30분·1회용)되어 만료/사용 시 redeem 불가한 죽은 값이 된다.
> 전역 Outbox 정리 정책 무변경(revision-1 근거). 동일 DB BCrypt 해시·PII보다 덜 민감.

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `eventId` | UUID | ✓ | 공통 봉투(멱등 키) |
| `occurredAt` | ISO-8601(KST +09:00) | ✓ | 공통 봉투(발행 시각) |
| `memberId` | long | ✓ | 회원 PK |
| `memberEmail` | string | ✓ | 재설정 메일 수신 이메일 |
| `memberName` | string | ✓ | 수신자 이름 |
| `resetUrl` | string | ✓ | 비밀번호 재설정 링크(토큰 포함, 메일 전달 목적 한정) |
| `expiresAt` | ISO-8601(KST +09:00) | ✓ | 토큰 만료 시각(발행 시각 + 30분) |

```json
{
  "eventId": "c3d4e5f6-0000-0000-0000-000000000006",
  "occurredAt": "2026-06-14T19:00:00+09:00",
  "memberId": 102,
  "memberEmail": "user@example.com",
  "memberName": "홍길동",
  "resetUrl": "http://localhost:8080/password-reset/confirm?token=a1b2c3d4e5f6...",
  "expiresAt": "2026-06-14T19:30:00+09:00"
}
```

## ShippingStartedEvent (topic: `shipping-started`)

> **020 배송 단위 개정**: `shipmentId`(long) + `items[]`(productId·productName·quantity) 추가.
> 발행 주체: `order` 모듈. 소비자: `notification`(구독·이메일 렌더링·DLQ 재처리 매핑 구현).
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
  "occurredAt": "2026-06-03T18:00:00+09:00",
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
  "shippedAt": "2026-06-03T18:00:00+09:00"
}
```

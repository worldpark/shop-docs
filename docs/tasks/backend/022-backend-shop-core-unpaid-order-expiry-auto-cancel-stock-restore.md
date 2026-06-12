# 022. shop-core 미결제 주문 만료(TTL) — 자동 취소 + 재고 복원

## Target
shop-core

---

## Goal
`015`(주문 생성, 생성 시 재고 차감)·`016`(결제 승인)·`017`(결제 거절)·`018`(취소/환불/재고 복원) 위에, **일정 시간 결제되지 않은(`pending`) 주문을 자동으로 만료시키는 스케줄러**를 추가한다. 만료 처리는:
- `created_at` 기준 TTL을 초과한 **`pending` 주문**을 주기적으로 감지한다.
- 각 주문을 **자동 취소**한다(주문 `pending → cancelled`) + **재고 복원**(생성 시 차감된 재고를 되돌림) + 결제 row(`ready`/`failed`)가 있으면 `cancelled`로 전이 + **`OrderCancelledEvent` 발행**(refunded=false).
- **PG 환불 없음**(`pending`은 청구된 적 없음). 이미 `paid`로 전이됐거나 이행/종결 상태인 주문은 만료 대상이 아니다.

> 본 Task는 **자동(시스템 주도) 미결제 만료**만 다룬다. 018이 만든 취소/복원 흐름을 **시스템 주도(소유권 검사 없음)·`pending` 전용·환불 없음** 경로로 재사용한다. 사용자 주도 취소(018), 부분 취소(1.3), 반품/교환(1.4), 실 PG·비동기 결제(3.2)는 범위 밖이다.

> **stale `ready`/`failed` 결제 row 정리**는 별도 삭제 job이 아니라 **만료 취소가 그 row를 `cancelled`로 전이**시키는 것으로 달성한다(물리 삭제·보존정책은 범위 밖 — 아래 Context 참조).

---

## Context
- **선행(구현 완료 전제)**
  - `015`: **재고 차감은 주문 생성 시점**에 `inventory.spi.InventoryStockPort.decrease(variantId, quantity)`(비관락 `VariantStock`)로 수행된다(`OrderService.createOrderTx`). 주문은 `pending`으로 생성된다(`Order.create`, status=`pending`). → **`pending` 주문은 이미 재고가 차감돼 있으므로, 만료 시 반드시 재고를 복원해야 한다.**
  - `016`: 결제 승인 시 `OrderConfirmation.confirmPaid`(orders `pending→paid` + `OrderCompletedEvent`). orders row `PESSIMISTIC_WRITE` 잠금으로 결제와 직렬화.
  - `017`: 결제 거절 시 `Payment.markFailed`(`ready→failed`). **거절은 주문을 취소하지 않는다**(주문은 `pending` 유지, 재시도 가능) → 미결제 만료가 이런 `pending`+`failed` 주문을 정리한다. 017이 "`ready`/`failed` row의 만료(TTL)·정리(cleanup) 스케줄러는 **주문 만료 Task에서 도입**"이라고 명시적으로 미뤘다.
  - `018`: **취소 오케스트레이션을 payment 모듈이 소유**(payment→order.spi, 순환 금지). `OrderCancellation.cancel(orderId, requesterUserId, RefundInfo)`(orders row 비관락 + 소유권 + 종결 전이 + 재고 복원 + `OrderCancelledEvent` 발행), `Payment.markCancelled`(`ready`/`failed`→`cancelled`), `Order.markCancelled`(`pending`→`cancelled`), `inventory.spi.increase`(복원), `OrderCancelledEvent`(topic `order-cancelled`, `refunded`/`refundedAmount` 포함)를 **이미 갖췄다**. 본 Task는 이를 재사용한다.
- **상태값(신규 migration 불필요)**
  - `orders.status` CHECK = `pending/paid/preparing/shipping/delivered/cancelled/refunded` — `cancelled` **이미 허용**. 신규 상태값 없음.
  - `payments.status` CHECK = `ready/paid/failed/cancelled/refunded` — `cancelled` **이미 허용**.
  - 만료 판정 기준 시각은 `orders.created_at`(DB 소유, `BaseEntity`, `insertable=false`). TTL은 **설정값**(컬럼 추가 없음).
- **stale 결제 row의 성격(왜 별도 삭제 job이 불필요한가)**
  - `payments`는 `uq_payments_order_id`로 **주문당 결제 1건**이다. `ready`/`failed` 결제 row는 곧 "그 주문이 아직 결제 완료되지 않았다"를 뜻하고, 그 주문은 `pending`(또는 018로 이미 `cancelled`)이다. 결제가 완료되면 같은 row가 `paid`로 전이되어 더는 `ready`/`failed`가 아니다.
  - 따라서 **떠도는(orphan) `ready`/`failed` row는 존재하지 않으며**, 미결제 `pending` 주문을 만료 취소하면 그 결제 row가 `markCancelled`로 정리된다. **물리 삭제/아카이빙(보존정책)** 은 본 Task 범위 밖(후속 — 데이터 보존정책 수립 시).
- **이벤트 계약(코드보다 문서 먼저 — event-contract-rule)**
  - 미결제 만료의 결과(주문 `cancelled` + 재고 복원 + 환불 없음)는 018의 미결제 취소와 **의미가 동일**하므로 **`OrderCancelledEvent`(topic `order-cancelled`)를 그대로 재사용**한다(`refunded=false`, `refundedAmount=0`). **신규 토픽/이벤트를 추가하지 않는다** → `event-catalog.md`/`architecture.md` §5 **변경 없음**.
  - (참고) "사용자 취소 vs 시스템 만료"를 notification이 구분해야 한다면 `OrderCancelledEvent`에 `cause` 같은 필드를 더하는 별도 계약 개정이 필요하다 — 본 Task 범위 밖(현재 소비 컨슈머 없음, 후속 2.1에서 필요 시).
- **모듈 의존 방향(순환 금지 — 중요)**
  - 만료 처리는 order(주문 종결·재고 복원·이벤트)와 payment(결제 row `cancelled` 전이) 양쪽을 건드린다. `order → payment.spi`를 만들면 **순환**이 되어 `ModularityTests`가 깨진다(018 #1과 동일).
  - 따라서 **만료 오케스트레이션은 payment 모듈이 소유**한다(018 대칭). 새 의존은 **`payment → order.spi`(기존 방향)뿐**이다. 스케줄러 컴포넌트도 payment 모듈에 둔다.
- **스케줄러 인프라(신규 도입)**
  - 현재 코드베이스에 `@Scheduled`/`@EnableScheduling` **사용처가 없다**. 본 Task가 **최초로** 주기 실행 스케줄러를 도입한다(Spring `@Scheduled`).
  - CLAUDE.md 가상스레드 대비: 스케줄러 작업은 **`ThreadLocal` 직접 사용 금지**, 블로킹 I/O(DB)는 Service/Infra 경계에 둔다.

## Authorization / 공개 표면
> 본 Task는 **신규 REST/View 엔드포인트가 없다**(자동 백그라운드 스케줄러). 외부에서 호출 가능한 API를 추가하지 않으므로 api-authorization-rule의 엔드포인트 권한 항목은 해당 없음.
- 만료는 **시스템 주도**다 — 사용자 소유권 검사 없이 동작한다(018의 소비자 취소가 가진 `requesterUserId` 소유권 검사를 만료 경로는 적용하지 않는다).
- 만료된 주문은 **기존 소비자 주문 목록/상세 화면이 이미 `cancelled`를 렌더**하므로(018에서 추가됨) **View 변경이 없다**.
- (선택·범위 밖) 관리자 수동 만료 트리거 엔드포인트나 만료 설정 조회 화면은 본 Task에 포함하지 않는다.

## Requirements
- **만료 대상 조회(order.spi 신규 read — scalar)**
  - 예: `findExpiredPendingOrderIds(Instant threshold, int limit)` — `status = 'pending' AND created_at < :threshold`인 주문 id를 **id만(스칼라) 페이지 한도(`limit`)** 로 반환한다(Entity 적재 금지, 한 번에 과도한 락 방지). 정렬은 `created_at`/`id` 오름차순(오래된 것 먼저).
  - `threshold`는 **호출자(스케줄러)가 `Instant.now() - ttl`로 계산해 주입**한다(클록 주입 가능 → 테스트 용이, DB `now()` 하드코딩 금지).
- **시스템 주도 만료 오케스트레이션(payment 모듈 소유)** — 예: `PaymentService.expirePendingOrder(long orderId)`(`@Transactional`)
  1. **만료 전용 locked reader(order.spi)** 로 주문 조회 — **orders row `PESSIMISTIC_WRITE` 잠금**(소유권 검사 **없음** — 시스템). 동시 결제(`confirmPaid`)·동시 취소(018)와 **직렬화**한다. 이 락은 **같은 트랜잭션의 4단계까지 유지**되며, 4단계 order.spi 시스템 취소가 같은 orders row를 다시 잠그면 **재진입 잠금**(같은 트랜잭션이 보유한 락 재획득 = no-op, 018 선례)이다. 서로 다른 락을 두 번 획득하거나 다른 순서로 잠그지 않는다(데드락 방지).
  2. **락 보유 상태 권위 재검증**: `status == 'pending'` 이면 진행. **그 외 상태(`paid`/이행/이미 종결)면 부작용 없이 멱등 skip**(예: 락 직전에 사용자가 결제를 완료해 `paid`가 됐다면 만료하지 않는다 — 만료/결제 race를 락으로 차단). TTL 재확인(락 후 `created_at` 기준 여전히 만료 대상인지)도 권장.
  3. 결제 row가 있으면(`ready`/`failed`) `Payment.markCancelled`(→`cancelled`). 없으면 결제 처리 없음. **PG 환불 호출 없음.** (이 결제 row 전이는 **1단계 orders row 락 보유 상태에서** 수행되어야 동시 `confirmPaid`와 안전하게 직렬화된다 — 락 없이 먼저 결제 row를 건드리지 않는다.)
  4. **order.spi 취소 위임(018 재사용)**: 시스템 주도(소유권 없음)·`pending` 전용·`RefundInfo.refunded=false` 경로로 `Order.markCancelled`(`pending→cancelled`) + **재고 복원**(각 order_item variant를 **variantId 오름차순** `inventory.increase`, 삭제된 variant는 skip+log) + **`OrderCancelledEvent` 발행**(refunded=false, refundedAmount=0, cancelledAt=만료 처리 시각, memberEmail/memberName는 member.spi 해석).
     - 018의 `OrderCancellation.cancel`이 `requesterUserId` 소유권을 검사하므로, **소유권을 검사하지 않는 시스템 만료 진입점**이 필요하다. **로직 중복/분기 발산을 피하려면, 018의 "전이(`markCancelled`)+재고 복원+이벤트 발행" 코어를 소유권 검사 단계와 분리**해, 사용자 취소(소유권 검사 → 코어 호출)와 시스템 만료(코어 직접 호출)가 **동일 코어를 공유**하도록 한다(오버로드 또는 신규 `cancelByExpiry(orderId)`로 노출, **정확한 형태는 plan에서 확정**). 두 경로가 전이/복원/이벤트 로직을 따로 복제하지 않는다. `Outcome` 패턴(018)을 따라 `CANCELLED`/`ALREADY_CANCELLED`(멱등 skip)를 값으로 표현하는 것을 권장.
  5. 전이+복원+(결제 row)전이+이벤트가 **한 트랜잭션으로 원자 커밋**된다.
- **스케줄러(payment 모듈)** — 예: `@Scheduled` 컴포넌트 `expireUnpaidOrders()`
  - 주기적으로 `threshold = now - ttl` 계산 → `findExpiredPendingOrderIds(threshold, batchLimit)` 조회 → **각 id를 `expirePendingOrder(id)`(주문별 독립 트랜잭션)로 처리**. 한 주문 처리 실패가 다른 주문을 롤백하지 않도록 **주문 단위로 트랜잭션·예외를 격리**한다(개별 try/catch + 로깅, 다음 주문 계속).
  - **배치 한도**(`batchLimit`)로 1회 실행당 처리량을 제한(대량 락·롱 트랜잭션 방지). 남은 만료분은 다음 주기에 처리(`@Scheduled` 반복).
  - **설정값**: TTL(예: `shop.order.pending-expiry.ttl`, `Duration`, 기본 30분 등 합리값), 실행 주기(`fixed-delay`/cron), 배치 한도, **활성화 플래그**. 설정은 `application.yml` + `@ConfigurationProperties`(기존 패턴) 사용.
- **상태 전이(018 도메인 메서드 재사용, 신규 도메인 메서드 없음)**
  - `Order.markCancelled()`(`pending→cancelled`), `Payment.markCancelled()`(`ready`/`failed`→`cancelled`), `inventory.spi.increase` — **모두 018에서 추가됨, 그대로 재사용**. 본 Task는 **새 도메인 전이 메서드를 만들지 않는다**.
- **멱등·동시성**
  - 만료는 주문당 1회만 재고를 복원한다(이미 `cancelled`/`refunded`/`paid`면 멱등 skip — **이중 복원·이중 이벤트 금지**). orders row 락이 동시 만료·동시 결제·018 동시 취소와 직렬화한다.
  - 같은 만료 주기가 겹쳐 실행되거나(중복 트리거) 같은 주문이 두 번 선택돼도, 락 후 상태 재검증으로 한 번만 전이된다.

## Constraints
- **신규 migration 없음**: 상태값(`cancelled`)·시각 컬럼(`created_at`) 모두 기존 스키마로 충분. 만료 사유/이력을 영속할 필요가 생기면 후속(`V_` migration).
- **신규 이벤트/토픽 없음**: `OrderCancelledEvent`(`order-cancelled`)를 `refunded=false`로 재사용. `event-catalog.md`/`architecture.md` §5 무변경.
- **신규 도메인 전이 메서드 없음**: 018의 `markCancelled`·`increase`를 재사용. 과도한 추상화·새 포트 발명 금지(YAGNI).
- **모듈 순환 금지**: `order → payment.spi`를 만들지 않는다. 만료 오케스트레이션·스케줄러는 payment 모듈이 소유하고 `payment → order.spi`(기존 방향, 만료 전용 reader + 시스템 취소 진입점)만 추가한다. `ModularityTests`/구조 테스트 그린.
- **PG 환불 없음**: `pending`은 청구 전이므로 환불 경로(018의 paid→refund)를 타지 않는다. `paid`/이행/종결 주문은 **만료 대상 아님**(조회·재검증에서 제외).
- **원자 커밋·부분 반영 금지**: 주문별 전이+복원+이벤트는 한 트랜잭션 원자 커밋. 시스템 오류 시 그 주문만 전체 롤백(다른 주문 영향 없음). 스케줄러는 주문 단위로 격리.
- **트랜잭션 프록시 경계 명시(self-invocation 함정 방지)**: 스케줄러 루프와 `expirePendingOrder`(`@Transactional`)는 **반드시 별도 빈**이어야 한다 — 같은 빈에 두고 내부 호출(self-invocation)하면 Spring AOP 프록시가 우회되어 **`@Transactional`이 무효화**되고, 위의 "주문별 원자 커밋·격리" 보장이 조용히 깨진다. 따라서 ① 스케줄러 컴포넌트 → `expirePendingOrder`는 **빈 경계를 넘는 호출**(프록시 적용), ② **스케줄러 루프 메서드 자체에는 `@Transactional`을 붙이지 않는다**(루프 전체가 한 트랜잭션이 되면 주문별 격리가 깨짐). 각 주문은 `expirePendingOrder` 호출마다 독립 트랜잭션으로 커밋된다.
- **스케줄러가 테스트/기동을 오염하지 않을 것(verification-gate §4)**: `@EnableScheduling`/`@Scheduled` 빈 추가는 모든 풀컨텍스트 `@SpringBootTest`에서 백그라운드 실행을 유발할 수 있다. **스케줄러 빈은 활성화 플래그(`@ConditionalOnProperty` 등)로 가드**해 **테스트 컨텍스트에서는 비활성**(기본 off 또는 test 프로파일 off)으로 둔다. 만료 로직 테스트는 스케줄러 트리거가 아니라 **서비스 메서드(`expirePendingOrder`)를 직접 호출**해 검증한다.
- **가상스레드 대비**: 스케줄러 작업에서 `ThreadLocal` 직접 사용 금지, 블로킹 I/O는 Service/Infra 경계 유지(CLAUDE.md).
- **시각·클록**: 만료 임계는 스케줄러가 `now - ttl`로 계산해 주입(테스트에서 임계/클록 제어 가능). `created_at`은 DB 소유 읽기 전용 — 테스트는 SQL로 `created_at`을 과거로 세팅해 만료 상황을 만든다.
- **비밀/민감정보 이벤트 페이로드 금지**(016/017/018 계승).

## Files
> 정확한 경로는 plan에서 확정. 대부분 018 재사용 + 스케줄러/조회/시스템 진입점 신규.
- (신규) payment 모듈 **스케줄러 컴포넌트**(`@Scheduled expireUnpaidOrders`) + `@EnableScheduling` 설정(가드된 활성화) + `@ConfigurationProperties`(TTL·주기·배치·활성화)
- (수정) `payment/service/PaymentService`(또는 신규 서비스) — `expirePendingOrder(orderId)` 시스템 만료 오케스트레이션(만료 전용 locked reader → `pending` 재검증 → `Payment.markCancelled` → order.spi 시스템 취소 위임)
- (신규) `order/spi` — **만료 대상 조회**(`findExpiredPendingOrderIds(threshold, limit)`, 스칼라) + **만료 전용 시스템 locked reader**(orders row `PESSIMISTIC_WRITE`, 소유권 없음) + **시스템 취소 진입점**(018 `OrderCancellation`의 소유권 없는 변형/오버로드, `pending`·refunded=false) — order 모듈 구현
- (수정) `application.yml`(`shop.order.pending-expiry.*` 설정) — 운영 기본값 + 테스트 비활성
- (재사용·무변경) `order/domain/Order.markCancelled`, `payment/domain/Payment.markCancelled`, `inventory/spi/InventoryStockPort.increase`, `order/event/OrderCancelledEvent`
- (변경 없음) `docs/event-catalog.md`/`docs/architecture.md` §5(신규 이벤트 없음), migration(신규 없음)

## Module Boundary Contract
| 항목 | 위치 | 규칙 |
|---|---|---|
| 만료 스케줄러 | payment 모듈 | `@Scheduled` → `expirePendingOrder` 주문별 위임. payment→order.spi(기존 방향) |
| 만료 오케스트레이션 | payment 모듈(`payment/service`) | 만료 전용 locked reader + `pending` 재검증 + 결제 row `markCancelled` + order.spi 시스템 취소 위임. 환불 없음 |
| 만료 대상 조회·시스템 취소 | `order/spi`(+order 구현) | 스칼라 id 조회 + 소유권 없는 locked reader + 소유권 없는 취소(전이+복원+이벤트) |
| 재고 복원 | `inventory.spi.increase` | 018 재사용(variantId 오름차순, 삭제 variant skip+log) |
| 이벤트 빌드/발행 | `order/event/OrderCancelledEvent` | 018 재사용, refunded=false. 신규 토픽 없음. **이벤트 빌더가 `order → member.spi`(memberEmail/name)·`order → product.spi`(productId) 기존 의존을 재사용**(만료 경로도 동일 — 이벤트 빌드는 의존 없는 작업이 아니다) |

- `payment → order.spi`(만료 reader + 시스템 취소), `order → inventory.spi`(increase), `order → member.spi`·`order → product.spi`(이벤트 빌더, 018에서 이미 존재) — **모두 기존 방향, 순환 없음**. `ModularityTests` 통과.

## Behavior Contract (응답 표면 없음)
- 본 Task는 동기 응답(REST/View)이 없다. 동작은 **스케줄러 주기 실행 → 주문별 만료 커밋**으로 관측된다.
- 만료 1건 = 주문 `pending→cancelled` + 재고 복원 + (결제 row 있으면)`cancelled` + `OrderCancelledEvent`(refunded=false) 1건이 **원자 커밋**.
- 멱등 skip(이미 `paid`/`cancelled`/`refunded`/이행) = 부작용·이벤트 없음.
- 관측성: 만료 처리 건수·각 orderId를 로깅(개별 실패는 로깅 후 다음 주문 계속).

## Acceptance Criteria
- TTL 초과 `pending` 주문(결제 row 없음/`ready`/`failed`) → 주문 `cancelled` + **재고 복원** + (결제 row 있으면)`cancelled` + `OrderCancelledEvent`(refunded=false, refundedAmount=0) Outbox 저장. **PG 환불 호출 없음.**
- TTL 미만 `pending` 주문 → 만료되지 않음(상태·재고 불변).
- `paid`/`preparing`/`shipping`/`delivered`/`cancelled`/`refunded` 주문 → **만료 대상 아님**(조회 제외 + 락 후 재검증으로 skip), 상태·재고 불변, 이벤트 미발행.
- 만료/결제 동시(락 직전 사용자가 결제 완료) → orders row 락으로 직렬화. 결제가 이기면 주문 `paid`, 만료는 skip(취소·복원 없음). 만료가 이기면 주문 `cancelled`, 이후 `confirmPaid`는 거부.
- 같은 주문 중복 만료(겹친 주기/중복 선택) → **멱등**: 재고 이중 복원 없음, 이벤트 1건만.
- 삭제된 variant(order_item.variant_id null) 포함 주문 만료 → 해당 항목 복원 skip+log, 나머지 정상 복원, 만료 성공.
- 스케줄러 1회 실행이 배치 한도까지만 처리하고, 한 주문 처리 실패가 다른 주문을 롤백/중단시키지 않는다(주문 단위 격리). 남은 만료분은 다음 주기에 처리.
- 스케줄러 빈은 테스트 컨텍스트에서 비활성(가드)이며, 만료 로직은 서비스 메서드 직접 호출로 검증된다. 풀컨텍스트 테스트 회귀 없음.
- 신규 migration 없음, 신규 이벤트/토픽 없음(`OrderCancelledEvent` 재사용). `ModularityTests`/구조 테스트 통과(payment↔order 순환 없음). `015`/`016`/`017`/`018` 회귀 없음.

## Test
- 단위(Mockito): `expirePendingOrder` 분기 — `pending`→취소+재고복원+이벤트(환불 없음), 결제 row `ready`/`failed`→`markCancelled`/결제 row 없음→결제 처리 없음, `paid`/이행/종결→멱등 skip(전이·복원·이벤트 없음), 멱등 재호출(복원·이벤트 1회). **만료 전용 locked reader가 전이보다 먼저 호출**(락 우선)·**소유권 검사 미수행** 단언. `findExpiredPendingOrderIds`에 `threshold`가 주입되는지(클록 주입).
- 단위: 스케줄러가 `findExpiredPendingOrderIds(threshold, limit)` 결과를 주문별 `expirePendingOrder`로 위임하고, **한 주문 예외가 다음 주문 처리를 막지 않음**(격리). 배치 한도 적용.
- 통합(Testcontainers): `created_at`을 과거로 세팅한 `pending` 주문이 만료 → 주문/결제 상태 전이 + `event_publication` 1건(`order-cancelled`, refunded=false) + 재고 stock 증가가 **원자 커밋**. TTL 미만 주문 불변. `paid`/이행 주문 불변(이벤트 0). 멱등 재실행 시 재고 불변·이벤트 추가 없음. 시스템 오류 강제 시 해당 주문만 롤백(부분 반영 없음, 다른 주문 정상).
- 동시성(Testcontainers): 만료 vs 결제(`confirmPaid`) 동시 → orders row 락 직렬화, 둘 중 하나만 성립(paid면 만료 skip / cancelled면 결제 거부), 재고·상태 정합. 만료 vs 018 사용자 취소 동시 → 직렬화, 이중 복원 없음.
- 구조: 만료 스케줄러·오케스트레이션이 payment 모듈, 조회·시스템 취소가 order.spi, `payment→order.spi`·`order→inventory.spi`만(순환 없음), `ModularityTests.verify()` 통과. 스케줄러 빈 테스트 비활성 가드 확인.

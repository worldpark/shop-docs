# 022. shop-core 미결제 주문 만료(TTL) — 자동 취소 + 재고 복원 — 구현 계획(plan)

> Task SSOT: `docs/tasks/backend/022-backend-shop-core-unpaid-order-expiry-auto-cancel-stock-restore.md` — **R1~R4 보강이 반영된 최신본.** 본 plan은 그 보강(트랜잭션 프록시 경계 R1, 018 코어 추출 R2, 재진입 락 R3, 이벤트 빌더 의존 R4)을 그대로 따른다.
> 선행 Task(구현 완료 전제): 015(주문 생성·재고 차감)·016(결제 승인·OrderConfirmation·OrderCompletedEvent)·017(결제 거절·PaymentFailedEvent)·**018(취소/환불/재고 복원 — 본 Task가 재사용하는 핵심)**. 016/017/018 경로는 **본 Task에서 변경하지 않는다**(만료 진입점만 추가).
> 선례 plan(구조·톤·레이어·테스트 패턴 기준): `docs/plans/backend/018-...-plan.md`(취소 오케스트레이션·locked reader·Outcome·재고 복원·OrderCancelledEvent), `docs/plans/backend/016-...-plan.md`·`017-...-plan.md`(orders row 락·Testcontainers 프로파일).
> 이벤트 계약 SSOT: `docs/event-catalog.md` + `docs/architecture.md` §5 — **본 Task는 신규 이벤트/토픽을 추가하지 않는다**. 018의 `OrderCancelledEvent`(topic `order-cancelled`)를 `refunded=false`로 재사용 → 문서 **무변경**.
> 영역: backend 전용(백그라운드 스케줄러 + 만료 오케스트레이션 + order.spi 시스템 조회/취소 + 설정). **REST/View 엔드포인트 없음 → view-implementor 작업 없음.**
> 대상 프로젝트: shop-core (Spring Modulith 모듈러 모놀리스)
> 작성일: 2026-06-12
> 상태: plan only (코드 변경 없음 — 구현은 backend-implementor가 수행)
> 담당: **backend-implementor 단독**(스케줄러/설정/오케스트레이션/order.spi 시스템 조회·취소 + 단위·통합·동시성·구조 테스트). view-implementor 작업 없음.
> 진행: backend-implementor → reviewer → fixer 사이클(최대 3회)
> 적용 보강(Task SSOT 반영): **R1**(스케줄러 루프와 `expirePendingOrder(@Transactional)`는 별도 빈 — self-invocation 시 `@Transactional` 무효화 차단, 루프 비-@Transactional, 주문별 독립 트랜잭션), **R2**(018의 전이+재고복원+이벤트 코어를 소유권 검사와 분리해 사용자 취소·시스템 만료가 공유 — 로직 복제 금지), **R3**(1단계 시스템 locked reader 락이 4단계까지 유지·같은 row 재진입, 3단계 `Payment.markCancelled`는 락 보유 상태 수행), **R4**(이벤트 빌더의 `order → member.spi`/`order → product.spi` 기존 의존 명시).

---

## 0. 코드 대조 결과 (실제 소스 점검 — 추측 아님)

> plan의 모든 경로/시그니처/전이는 아래 실측에 근거한다. C1~C12.

| # | 대조 대상 | 실측 결과 | 본 Task 영향 |
|---|---|---|---|
| **C1** | `order/domain/Order.markCancelled()` | `pending→cancelled`, `cancelled` 재호출 멱등 no-op, 그 외 `IllegalStateException`(방어). **이미 존재(018).** | **재사용, 신규 도메인 전이 0.** 시스템 만료는 `pending`만 처리하므로 그대로 적합. |
| **C2** | `payment/domain/Payment.markCancelled()` | `ready`/`failed`→`cancelled`, `cancelled` 멱등, `paid`/`refunded`→`IllegalStateException`. **이미 존재(018).** | **재사용.** 미결제 주문의 결제 row(`ready`/`failed`)만 전이 — 적합. |
| **C3** | `inventory/spi/InventoryStockPort.increase(long,int)` | `findByIdForUpdate(variantId)` 비관락 → `stock += quantity`, row 미존재(변형 삭제) skip+log, `isActive` 미검사. **이미 존재(018).** | **재사용.** 만료 재고 복원이 그대로 사용. |
| **C4** | `order/event/OrderCancelledEvent` | `@Externalized("order-cancelled")` record. 필드: `eventId`/`occurredAt`/`orderId`/`orderNumber`/`memberId`/`memberEmail`/`memberName`/`items[](productId,productName,quantity)`/`refunded`/`refundedAmount`/`currency`/`cancelledAt` + `TOPIC` 상수. **이미 존재(018).** | **재사용, 신규 이벤트/토픽 0.** 만료는 `refunded=false, refundedAmount=0`. |
| **C5** | `order/service/OrderCancellationImpl.cancel(orderId, requesterUserId, refundInfo)` | **핵심**: 1) `findByIdForUpdate` 락 + **2) 소유권 검증(`order.getUserId().equals(requesterUserId)` 불일치 시 404)** + 3) status 분기(`cancelled`/`refunded`→ALREADY, 이행단계→REJECTED) + 4) 종결 전이(refunded면 `markRefunded`, 아니면 `markCancelled`) + 5) 재고 복원(variantId 오름차순, null skip+log) + 6) `OrderCancelledEvent` 발행. | **R2 분기점**: 2)의 소유권 검증을 **시스템 만료는 우회**해야 함. 전이+복원+이벤트(3~6단계) 코어를 소유권 검증과 분리해 공유 → **`cancelByExpiry(long orderId)` 신규 진입점**(2.1.C 참조). |
| **C6** | `order/spi/OrderCancellation` (인터페이스) | `cancel(orderId, requesterUserId, RefundInfo) → OrderCancellationResult`(Outcome `CANCELLED`/`ALREADY_CANCELLED`/`REJECTED`). `RefundInfo(refunded, refundedAmount, currency)`. | **수정**: 소유권 없는 시스템 만료 진입점 `cancelByExpiry(long orderId) → OrderCancellationResult` **추가**(오버로드 아닌 별도 메서드 — 시그니처 의미 명확화). |
| **C7** | `order/spi/OrderPaymentReader` | `getPayableOrder`(무락 결제)·`getOrderSnapshot`(무락 상태조회)·**`getOrderForCancel(orderId, requesterUserId)`(orders row PESSIMISTIC_WRITE + 소유권 404, 018)**. 구현 `OrderPaymentReaderImpl`이 `findByIdForUpdate` + 소유권 검증. | **수정**: 소유권 없는 **시스템 만료 locked reader `getOrderForExpiry(long orderId) → OrderSnapshotView`** 추가(`findByIdForUpdate` + 소유권 검증 **없음**). |
| **C8** | `order/repository/OrderRepository` | `findByIdForUpdate(id)`(PESSIMISTIC_WRITE, 무소유권)·`findByStatusInOrderByCreatedAtDescIdDesc`(페이지)·`findByUserId...`. **만료 대상 스칼라 조회 메서드 없음.** | **수정**: `findExpiredPendingOrderIds(Instant threshold, Pageable) → List<Long>`(또는 `limit` 직접) **신규**. `status='pending' AND created_at < :threshold`, `created_at`/`id` 오름차순, **id만(스칼라)**. |
| **C9** | `payment/service/PaymentService` | public `@Service`. `pay`(8단계)·`cancel(userId, orderId)`(@Transactional, locked reader→상태판정→환불/취소→`OrderCancellation.cancel` 위임)·`getPaymentStatus`. 의존: `OrderPaymentReader`·`OrderConfirmation`·`OrderCancellation`·`PaymentGatewayPort`·`PaymentRepository`·`MemberDirectory`·`ApplicationEventPublisher`. | **수정**: `expirePendingOrder(long orderId)`(@Transactional, 시스템 만료 오케스트레이션) **추가**. 의존은 **이미 보유**한 `OrderPaymentReader`·`OrderCancellation`·`PaymentRepository`만 사용(신규 의존 0). |
| **C10** | `@Scheduled`/`@EnableScheduling` 사용처 | **코드베이스에 0건**(grep 확인). 본 Task가 최초 도입. | 신규 스케줄러 컴포넌트 + `@EnableScheduling` 설정. **활성화 플래그로 가드**(verification-gate §4). |
| **C11** | `@ConfigurationProperties` 패턴 | `RedisProperties`(record + `prefix="shop.redis"` + compact constructor 기본값) + `RedisConfig`(`@Configuration @EnableConfigurationProperties(RedisProperties.class)`). `application.yml`의 `shop.*` 블록과 1:1. | 동일 패턴으로 `OrderExpiryProperties`(record, `prefix="shop.order.pending-expiry"`) + 설정 클래스. `application.yml`에 `shop.order.pending-expiry.*` + test yml은 **활성화 off**. |
| **C12** | 테스트 프로파일 | `src/test/resources/application.yml`이 DataSource/JPA/Kafka/Flyway/외부화 자동설정 **제외**. Outbox·동시성은 016/017/018 Testcontainers 별도 프로파일(`@AutoConfigureTestDatabase(NONE)` + `@Testcontainers`(postgres:16.4-alpine + `@ServiceConnection`) + `@TestPropertySource`(exclude 리셋 + flyway enabled + ddl validate) + 외부화 `enabled=false`)로 검증. | **그대로 재사용.** 만료 통합/동시성 테스트는 018 프로파일 답습. `created_at`은 SQL로 과거 세팅. |

**핵심 결론**: 신규 migration 0, 신규 이벤트/토픽 0, 신규 도메인 전이 메서드 0. 추가되는 것은 **스케줄러 컴포넌트 1 + 설정(properties/config) 1쌍 + `PaymentService.expirePendingOrder` + order.spi 시스템 조회/취소 3개(스칼라 조회·locked reader·`cancelByExpiry`) + 그 구현**뿐이다.

---

## 1. 설계 방식 및 이유

### 1.1 만료 오케스트레이션·스케줄러는 payment 모듈이 소유 (018 대칭 — 순환 회피)

만료 처리는 order(주문 종결·재고 복원·이벤트)와 payment(결제 row `cancelled` 전이) 양쪽을 건드린다. `order → payment.spi`를 만들면 `payment ↔ order` 순환이 되어 `ModularityTests`가 깨진다(018 #1·C9 대칭). 따라서:

- **만료 오케스트레이션(`PaymentService.expirePendingOrder`)·스케줄러 컴포넌트를 payment 모듈에 둔다.**
- 새 의존은 **`payment → order.spi`(기존 방향)** 뿐이다: 시스템 만료 locked reader(`getOrderForExpiry`)·시스템 취소(`cancelByExpiry`)·스칼라 조회(`findExpiredPendingOrderIds`는 order.repository에 두고 order 내부에서 소비 — payment는 reader/취소 SPI로만 접근).
- 018의 `PaymentService.cancel`이 `OrderCancellation.cancel`로 주문 종결을 위임한 것과 정확히 대칭이다(payment가 결제 row를 책임지고, 주문 상태/재고/이벤트는 order에 위임).

### 1.2 트랜잭션 프록시 경계 — 스케줄러 루프와 만료 단위는 별도 빈 (R1)

self-invocation 함정을 차단한다.

- **스케줄러 컴포넌트(`UnpaidOrderExpiryScheduler`)** 는 `@Scheduled` 루프 메서드 `expireUnpaidOrders()`를 가진다. **이 루프 메서드에는 `@Transactional`을 붙이지 않는다**(루프 전체가 한 트랜잭션이 되면 주문별 격리·원자 커밋이 깨진다).
- 루프는 `threshold = now - ttl` 계산 → `findExpiredPendingOrderIds(threshold, limit)`(읽기) → 각 orderId마다 **빈 경계를 넘어** `PaymentService.expirePendingOrder(orderId)`(`@Transactional`)를 호출한다. 빈 경계를 넘으므로 Spring AOP 프록시가 적용되어 `@Transactional`이 유효하다.
- 스케줄러와 `PaymentService`는 **서로 다른 빈**이다(스케줄러는 payment 모듈의 `@Component`, PaymentService는 `@Service`). 같은 빈 내부 호출이 아니므로 프록시 우회가 발생하지 않는다.
- 각 `expirePendingOrder` 호출이 **독립 트랜잭션**으로 커밋되어 "주문별 원자 커밋·격리"(Constraint)가 성립한다.

### 1.3 018 코어 추출 — 소유권 검사와 전이/복원/이벤트 분리 (R2)

C5 실측대로 `OrderCancellationImpl.cancel(orderId, requesterUserId, refundInfo)`은 **2단계에서 소유권 검증**(`order.getUserId().equals(requesterUserId)` 불일치 → 404)을 수행한다. 시스템 만료는 사용자 주체가 없어 소유권 검사를 적용하면 안 된다(Task Authorization §). 로직 복제를 피하려면:

- **코어 추출**: `OrderCancellationImpl`에 `private OrderCancellationResult doCancel(Order lockedOrder, RefundInfo refundInfo)` 코어를 둔다. 이 코어는 **status 분기(ALREADY/REJECTED/진행) + 종결 전이(markCancelled/markRefunded) + 재고 복원 + `OrderCancelledEvent` 발행**을 담당하며 **소유권을 검사하지 않는다**(이미 락된 `Order`를 받는다).
- **사용자 취소 진입점**(기존 `cancel(orderId, requesterUserId, refundInfo)`): `findByIdForUpdate` 락 → **소유권 검증** → `doCancel(order, refundInfo)`.
- **시스템 만료 진입점**(신규 `cancelByExpiry(long orderId)`): `findByIdForUpdate` 락(재진입, R3) → **소유권 검증 없음** → 만료는 항상 미결제(`pending`)·환불 없음이므로 `RefundInfo(false, 0, "KRW")` 고정 → `doCancel(order, refundInfo)`.
- 두 진입점이 **동일 코어 `doCancel`을 공유**한다. 전이/복원/이벤트 로직을 복제하지 않는다.

> **형태 확정·권장**: 오버로드(`cancel(orderId)`)가 아니라 **별도 메서드 `cancelByExpiry(orderId)`** 를 권장한다. (a) 시그니처 자체가 "소유권 없는 시스템 경로"임을 드러내 오용(사용자 경로에서 소유권 없이 호출)을 컴파일 수준에서 분리하고, (b) 만료는 `RefundInfo`가 항상 `(false,0,KRW)`로 고정이라 인자를 받지 않는 편이 호출부를 단순화한다. `Outcome` 패턴(C6)은 그대로 — 만료 정상 흐름은 `CANCELLED`, 이미 종결은 `ALREADY_CANCELLED`(멱등).

### 1.4 시스템 만료 locked reader로 결제/취소와 직렬화 (R3 — 락 우선·재진입)

- **시스템 만료 locked reader `getOrderForExpiry(long orderId)`** (신규 order.spi)는 orders row를 `PESSIMISTIC_WRITE`로 잠그고 **소유권 검증 없이** 스냅샷을 반환한다(`OrderPaymentReaderImpl`이 `findByIdForUpdate(orderId)`로 구현, C7 `getOrderForCancel`의 무소유권 변형).
- 이 락은 `PaymentService.expirePendingOrder`의 **같은 트랜잭션** 1~4단계 전체에 유지된다. 4단계 `OrderCancellation.cancelByExpiry`가 같은 orders row를 `findByIdForUpdate`로 다시 잠그면 **같은 트랜잭션이 보유한 락 재획득 = 재진입(no-op)** 이다(018 `getOrderForCancel`↔`OrderCancellationImpl` 선례와 동형). 서로 다른 락을 두 번 잡거나 다른 순서로 잠그지 않는다(데드락 방지).
- **락 우선**: locked reader가 1단계에서 호출되어 동시 결제(`OrderConfirmation.confirmPaid`도 같은 orders row `PESSIMISTIC_WRITE`)·동시 사용자 취소(018 `getOrderForCancel`)와 직렬화한다. 만료/결제 race를 락으로 차단한다(락 직전 결제 완료 시 2단계 재검증에서 `paid` 관찰 → 멱등 skip).
- **3단계 `Payment.markCancelled`는 1단계 orders row 락 보유 상태에서 수행**한다(R3). 락 없이 먼저 결제 row를 건드리지 않는다 — 동시 `confirmPaid`와 안전 직렬화.

### 1.5 만료 = 미결제(`pending`) 전용·환불 없음 — 018 환불 경로 미진입

- 만료 대상은 `status='pending' AND created_at < threshold` 주문뿐이다(C8 조회 + 2단계 락 후 재검증). `pending`은 청구된 적 없으므로 **PG 환불 호출 없음**(018의 `paid→refund` 경로 미진입).
- 결제 row가 있으면(`ready`/`failed`) `Payment.markCancelled`(C2)로 `cancelled` 전이, 없으면 결제 처리 없음. `refunded=false, refundedAmount=0`.
- 주문은 `Order.markCancelled`(C1)로 `pending→cancelled`. **`refunded` 종결 아님**(018의 결제완료 취소만 `refunded`).
- 이로써 "stale `ready`/`failed` 결제 row 정리"는 별도 삭제 job 없이 만료 취소가 그 row를 `cancelled`로 전이시키는 것으로 달성된다(Task Context).

### 1.6 멱등·동시성 — 락 후 재검증으로 1회만 전이

- 만료는 주문당 1회만 재고를 복원한다. 2단계 락 후 상태 재검증(`pending` 아니면 부작용 없이 멱등 skip) + `cancelByExpiry` 코어의 권위 재검증(이미 `cancelled`/`refunded`면 `ALREADY_CANCELLED`)으로 **이중 복원·이중 이벤트를 차단**한다.
- 같은 만료 주기가 겹쳐 실행되거나(중복 트리거) 같은 주문이 두 번 선택돼도(스칼라 조회 중복), orders row 락 직렬화 + 상태 재검증으로 한 번만 전이된다.
- 만료/결제 동시: 결제가 먼저 커밋 → 만료가 `paid` 관찰 → skip(취소·복원 없음). 만료가 먼저 커밋 → 이후 `confirmPaid`가 `cancelled` 관찰 → `OrderConfirmation.Outcome.REJECTED` → `OrderConfirmationConflictException`(409, 결제 롤백). 모순 없음.

### 1.7 스케줄러가 테스트/기동을 오염하지 않음 (verification-gate §4)

- `@EnableScheduling` + `@Scheduled` 빈은 모든 풀컨텍스트 `@SpringBootTest`에서 백그라운드 실행을 유발할 수 있다. 따라서 **스케줄러 컴포넌트를 활성화 플래그 `@ConditionalOnProperty(prefix="shop.order.pending-expiry", name="enabled", havingValue="true")` 로 가드**한다.
- `application.yml`(운영): `shop.order.pending-expiry.enabled: true`. `src/test/resources/application.yml`: 명시적으로 `false`(또는 운영 yml 기본을 `false`로 두고 운영 프로파일에서 활성). → **테스트 컨텍스트에서 스케줄러 빈이 생성되지 않아** 백그라운드 실행·회귀가 없다.
- 만료 **로직 테스트는 스케줄러 트리거가 아니라 `PaymentService.expirePendingOrder`(및 `OrderCancellation.cancelByExpiry`)를 직접 호출**해 검증한다. 스케줄러 위임/격리/배치는 스케줄러 컴포넌트를 단위로 직접 호출(메서드 호출)해 검증한다.
- **컴포넌트 스캔 파급(§4) 주의**: `expirePendingOrder` 추가는 `PaymentService`(기존 빈)에 메서드를 더하는 것이라 신규 빈이 아니다. 신규 빈은 ① 스케줄러 컴포넌트(가드로 테스트 컨텍스트 미생성), ② `OrderExpiryProperties`/설정(properties는 새 Repository 의존을 만들지 않음), ③ order.repository에 추가되는 쿼리 메서드(`OrderRepository`는 기존 빈, 메서드 추가). **새 Repository 빈을 도입하지 않으므로** 기존 풀컨텍스트 테스트의 `@MockitoBean` 파급은 발생하지 않는다(스케줄러가 새 reader/취소 SPI를 의존하지만, 그 SPI 구현은 기존 `OrderPaymentReaderImpl`/`OrderCancellationImpl`에 메서드를 더하는 것이라 신규 빈 아님). 단, 신규 빈 `OrderExpiryReaderImpl`은 실제 빈으로 뜨므로(새 Repository 의존 없음 — 기존 `OrderRepository` 사용) 컨텍스트 로드에 영향 없음을 구조/전체 테스트로 확인한다.

### 1.8 신규 migration 없음·신규 이벤트 없음 (Constraint)

- 상태값(`cancelled`)·시각(`created_at`, DB 소유 `insertable=false`) 모두 기존 스키마로 충분 → **신규 `V_` migration 0**.
- `OrderCancelledEvent`(`order-cancelled`)를 `refunded=false`로 재사용 → `event-catalog.md`/`architecture.md` §5 **무변경**.
- 신규 도메인 전이 메서드 0(C1/C2 재사용).

---

## 2. 구성 요소 (신규/수정 파일 — 정확한 패키지 경로)

> 전부 backend-implementor 담당. view-implementor 작업 없음.

### 2.1.A (신규) payment 모듈 — 스케줄러 컴포넌트

- `shop-core/src/main/java/com/shop/shop/payment/service/UnpaidOrderExpiryScheduler.java`(신규, package-private `@Component`, `@RequiredArgsConstructor`, `@Slf4j`)
  - `@ConditionalOnProperty(prefix = "shop.order.pending-expiry", name = "enabled", havingValue = "true")` — 테스트 컨텍스트 비활성 가드(verification-gate §4).
  - 의존: `PaymentService`(만료 위임)·`OrderExpiryReader`(만료 후보 스칼라 조회 SPI — 2.2 참조)·`OrderExpiryProperties`·`Clock`(주입 — 테스트 클록 제어).
  - `@Scheduled(fixedDelayString = "${shop.order.pending-expiry.interval}")` 메서드 `expireUnpaidOrders()` — **`@Transactional` 미부착(R1)**:
    1. `Instant threshold = clock.instant().minus(properties.ttl());`
    2. `List<Long> ids = orderExpiryReader.findExpiredPendingOrderIds(threshold, properties.batchLimit());`(읽기 — reader 내부 readOnly 트랜잭션).
    3. 각 `orderId`에 대해 `try { paymentService.expirePendingOrder(orderId); processed++; } catch (Exception e) { log.warn("만료 처리 실패(다음 주문 계속): orderId={}", orderId, e); }` — **주문 단위 예외 격리**(한 주문 실패가 다음 주문을 막지 않음).
    4. `log.info("미결제 만료 스케줄 종료: candidates={}, processed={}", ids.size(), processed);`
  - 루프는 빈 경계를 넘어 `paymentService.expirePendingOrder`를 호출하므로 각 주문이 독립 트랜잭션 커밋(R1).

### 2.1.B (신규) 설정 — `@ConfigurationProperties` (C11 패턴)

- `shop-core/src/main/java/com/shop/shop/payment/service/OrderExpiryProperties.java`(신규, record, `@ConfigurationProperties(prefix = "shop.order.pending-expiry")`)
  - 필드: `boolean enabled`, `Duration ttl`, `Duration interval`(fixed-delay), `int batchLimit`.
  - compact constructor 기본값(RedisProperties 패턴): `ttl == null → Duration.ofMinutes(30)`, `interval == null → Duration.ofMinutes(1)`, `batchLimit <= 0 → 100`. (`enabled`는 yml/프로파일에서 명시.)
  - > 배치는 payment 모듈 내부에 두어 `payment → order.spi` 외 새 의존을 만들지 않는다. (member/security 패턴은 common/config·security에 두지만, 본 설정은 만료 오케스트레이션 소유 모듈인 payment에 둔다.)
- `shop-core/src/main/java/com/shop/shop/payment/service/OrderExpirySchedulingConfig.java`(신규, `@Configuration`, `@EnableConfigurationProperties(OrderExpiryProperties.class)`, `@EnableScheduling`)
  - `@EnableConfigurationProperties`로 properties 바인딩(C11 RedisConfig 패턴).
  - `@EnableScheduling`으로 `@Scheduled` 활성화(C10 — 코드베이스 최초 도입). **이 `@Configuration`도 `@ConditionalOnProperty(prefix="shop.order.pending-expiry", name="enabled", havingValue="true")`로 가드**해 테스트 컨텍스트에서 `@EnableScheduling` 자체를 끈다(컴포넌트+설정 양쪽 가드 — 보수적·확실).
  - `Clock` 빈 제공(`@Bean Clock systemClock() { return Clock.systemUTC(); }`) — 스케줄러 클록 주입·테스트 대체용. (`Clock` 빈은 가드 밖에 두거나 별도 공용 설정으로 둬 테스트에서도 사용 가능하게 한다 — 스케줄러 단위 테스트가 고정 Clock 주입.)

### 2.1.C (수정) payment/service/PaymentService — 시스템 만료 오케스트레이션

- `shop-core/src/main/java/com/shop/shop/payment/service/PaymentService.java` — `expirePendingOrder(long orderId)`(`@Transactional`) **추가**(C9 — 기존 의존 `OrderPaymentReader`·`OrderCancellation`·`PaymentRepository`만 사용, 신규 의존 0).
  - 흐름(R3 락 보유·재진입):
    1. **시스템 만료 locked reader**: `OrderSnapshotView snapshot = orderPaymentReader.getOrderForExpiry(orderId);`(orders row `PESSIMISTIC_WRITE`, **소유권 검증 없음** — 시스템). 동시 결제·취소와 직렬화(1.4).
    2. **락 보유 권위 재검증**: `if (!"pending".equals(snapshot.status())) { log.info("만료 대상 아님 — 멱등 skip: orderId={}, status={}", orderId, status); return; }` — `paid`/이행/종결이면 부작용 없이 skip(만료/결제 race 차단). (TTL 재확인은 스칼라 조회가 이미 threshold로 필터하고 락 후 상태가 권위이므로 status 재검증으로 충분 — reader가 status만 반환하므로 status 재검증을 1차로 한다.)
    3. **결제 row 전이(락 보유 상태, R3)**: `Payment payment = paymentRepository.findByOrderId(orderId).orElse(null); if (payment != null) { payment.markCancelled(); }` — `ready`/`failed`→`cancelled`. 없으면 결제 처리 없음. **PG 환불 호출 없음.**
    4. **order.spi 시스템 취소 위임**: `OrderCancellationResult result = orderCancellation.cancelByExpiry(orderId);`(소유권 없음·`pending` 전용·`refunded=false`). → `Order.markCancelled`(→cancelled) + 재고 복원(variantId 오름차순, null skip+log) + `OrderCancelledEvent`(refunded=false, refundedAmount=0) 발행.
       - **방어 검증**: 2단계에서 `pending`을 확인했으므로 같은 락 하에서 `result.outcome()`은 `CANCELLED`여야 한다. `ALREADY_CANCELLED`/`REJECTED`면 락 불변식 위반 → `IllegalStateException`(전체 롤백). (018 `cancel`의 방어 검증과 동형.)
    5. 전이+복원+(결제 row)전이+이벤트가 **한 트랜잭션 원자 커밋**.
  - 반환: `void`(REST 응답 없음 — 백그라운드). 처리/skip 여부는 로깅으로 관측.
  - javadoc: "시스템 주도 미결제 만료. 소유권 검사 없음(시스템). `pending` 전용·환불 없음. R1(별도 빈에서 호출)·R3(락 보유·재진입) 명시."

### 2.2 (수정) order.spi/order.service — 시스템 만료 locked reader + 시스템 취소 + 스칼라 조회

#### (수정) `order/spi/OrderPaymentReader` — 시스템 만료 locked reader
- `shop-core/src/main/java/com/shop/shop/order/spi/OrderPaymentReader.java` — `OrderSnapshotView getOrderForExpiry(long orderId)` **추가**(C7 `getOrderForCancel`의 무소유권 변형).
  - javadoc: "시스템 만료 전용 — orders row `PESSIMISTIC_WRITE` 잠금, **소유권 검증 없음**(시스템 주도). 환불 결정 전·전이 전 호출(락 우선, R3). `getOrderForCancel`(소유권 검증 O)과 대비. 같은 트랜잭션의 `cancelByExpiry`까지 락 유효(재진입)."
- `shop-core/src/main/java/com/shop/shop/order/service/OrderPaymentReaderImpl.java` — `getOrderForExpiry` 구현(`@Transactional`): `Order order = orderRepository.findByIdForUpdate(orderId).orElseThrow(OrderNotFoundException::new);` → 소유권 검증 **없이** `OrderSnapshotView` 반환. (미존재 주문은 404이지만 스케줄러는 직전 스칼라 조회로 얻은 id를 넘기므로 정상 흐름에선 미존재가 드물다 — 동시 삭제 등 방어로 404 → 스케줄러 try/catch가 격리.)

#### (수정) `order/spi/OrderCancellation` — 시스템 만료 취소 진입점 (R2)
- `shop-core/src/main/java/com/shop/shop/order/spi/OrderCancellation.java` — `OrderCancellationResult cancelByExpiry(long orderId)` **추가**.
  - javadoc: "**시스템 주도 미결제 만료 취소 — 소유권 검사 없음.** `pending` 전용·환불 없음(`RefundInfo(false,0,KRW)` 고정). 사용자 취소 `cancel(orderId, requesterUserId, refundInfo)`와 **전이+복원+이벤트 코어를 공유**(R2 — 로직 복제 금지). orders row 락 재진입(R3). 정상 흐름 Outcome=`CANCELLED`, 이미 종결=`ALREADY_CANCELLED`(멱등). 만료 정상 흐름에서 `REJECTED`(이행단계) 미발생 — `pending`만 조회·재검증되므로."

#### (수정) `order/service/OrderCancellationImpl` — 코어 추출 + 시스템 진입점 (R2)
- `shop-core/src/main/java/com/shop/shop/order/service/OrderCancellationImpl.java` — 리팩터링(로직 복제 0):
  - **코어 추출**: 기존 `cancel(orderId, requesterUserId, refundInfo)` 본문의 status 분기(ALREADY/REJECTED) + 종결 전이(markCancelled/markRefunded) + 재고 복원 + 이벤트 발행을 `private OrderCancellationResult doCancel(Order lockedOrder, RefundInfo refundInfo)` 로 추출(이미 락·소유권 검증을 통과한 `Order`를 받는다).
  - **사용자 취소 `cancel(orderId, requesterUserId, refundInfo)`**: `Order order = findByIdForUpdate(orderId).orElseThrow(...);` → **소유권 검증**(불일치 404) → `return doCancel(order, refundInfo);`. (기존 동작·시그니처 보존 — 회귀 0.)
  - **시스템 만료 `cancelByExpiry(orderId)`**(신규): `Order order = findByIdForUpdate(orderId).orElseThrow(...);`(락 재진입, R3) → **소유권 검증 없음** → `return doCancel(order, new RefundInfo(false, 0L, "KRW"));`.
  - `doCancel` 내부의 재고 복원·이벤트 빌더(`buildOrderCancelledEvent`)는 **변경 없이** 그대로 코어가 호출 — `order → member.spi`(`memberDirectory.findContactByUserId`)·`order → product.spi`(`productOrderCatalog.getOrderableSnapshots`) 기존 의존을 재사용(**R4** — 이벤트 빌드는 의존 없는 작업이 아니며, 만료 경로도 동일하게 이 의존을 탄다).

#### (수정) `order/repository/OrderRepository` — 만료 대상 스칼라 조회
- `shop-core/src/main/java/com/shop/shop/order/repository/OrderRepository.java` — `findExpiredPendingOrderIds` **추가**(C8):
  ```java
  @Query("select o.id from Order o where o.status = 'pending' and o.createdAt < :threshold order by o.createdAt asc, o.id asc")
  List<Long> findExpiredPendingOrderIds(@Param("threshold") Instant threshold, Pageable pageable);
  ```
  - **id만(스칼라)** select(Entity 적재·과도한 락 방지). 정렬 `createdAt asc, id asc`(오래된 것 먼저). `limit`은 `Pageable`(`PageRequest.of(0, batchLimit)`)로 주입(JPQL+`Pageable`이 기존 컨벤션과 일치).
  - `createdAt`은 `BaseEntity`의 `Instant createdAt`(읽기 전용 매핑) — JPQL 비교 가능.

#### (신규) 만료 스칼라 조회의 SPI 노출 — `OrderExpiryReader` (모듈 경계)
- payment 모듈(스케줄러)이 만료 후보 id를 얻으려면 order.spi를 거쳐야 한다(`payment → order.spi`만 허용). `OrderRepository`는 order 내부라 payment가 직접 못 본다. 따라서 **스칼라 조회를 SPI로 노출**한다:
  - `shop-core/src/main/java/com/shop/shop/order/spi/OrderExpiryReader.java`(신규 인터페이스) — `List<Long> findExpiredPendingOrderIds(Instant threshold, int limit)`.
  - `shop-core/src/main/java/com/shop/shop/order/service/OrderExpiryReaderImpl.java`(신규, package-private `@Service @Transactional(readOnly=true)`) — `orderRepository.findExpiredPendingOrderIds(threshold, PageRequest.of(0, limit))` 위임.
  - > **대안 검토**: `OrderPaymentReader`에 스칼라 조회 메서드를 더할 수도 있으나, 이름·의미(결제 reader vs 만료 후보 조회)가 어긋나므로 **전용 SPI `OrderExpiryReader`** 를 권장한다(YAGNI 범위 내 — 새 포트 1개, 만료라는 명확한 책임). 새 빈이지만 새 Repository가 아니라 기존 `OrderRepository`만 의존하므로 컨텍스트 로드 파급은 없다(§4 — 구조/전체 테스트로 확인).

### 2.3 (수정) application.yml — 만료 설정

- `shop-core/src/main/resources/application.yml` — `shop.order.pending-expiry` 블록 추가:
  ```yaml
  shop:
    order:
      pending-expiry:
        enabled: ${SHOP_ORDER_EXPIRY_ENABLED:true}   # 운영 활성
        ttl: ${SHOP_ORDER_EXPIRY_TTL:PT30M}           # 30분 미결제 만료
        interval: ${SHOP_ORDER_EXPIRY_INTERVAL:PT1M}  # 1분 주기(fixed-delay)
        batch-limit: ${SHOP_ORDER_EXPIRY_BATCH:100}   # 1회 최대 처리
  ```
- `shop-core/src/test/resources/application.yml` — `shop.order.pending-expiry.enabled: false` **명시 추가**(verification-gate §4 — 테스트 컨텍스트 스케줄러 비활성).

### 2.4 (재사용·무변경)
- `order/domain/Order.markCancelled`(C1)·`payment/domain/Payment.markCancelled`(C2)·`inventory/spi/InventoryStockPort.increase`(C3)·`order/event/OrderCancelledEvent`(C4) — 그대로 재사용, 코드 변경 없음.
- 016/017/018 결제·취소 경로(`pay`·`cancel`·`handleDeclined`·`OrderConfirmation`) — 무변경(회귀 0). `cancel`은 `doCancel` 코어 추출로 **내부 리팩터링만**(외부 동작·시그니처 불변, 테스트로 보장).
- `docs/event-catalog.md`/`docs/architecture.md` §5 — **무변경**(신규 이벤트 없음).
- migration — 신규 없음.

### 2.5 (신규) 테스트 (5절 매핑)
- `payment/service/PaymentServiceExpiryTest.java`(신규, Mockito) — `expirePendingOrder` 분기.
- `order/service/OrderCancellationExpiryTest.java`(신규 또는 `OrderCancellationImplTest` 보강) — `cancelByExpiry` 코어 공유·소유권 미검사·전이/복원/이벤트.
- `payment/service/UnpaidOrderExpirySchedulerTest.java`(신규, Mockito) — 위임·격리·배치·클록 주입.
- `payment/service/UnpaidOrderExpiryOutboxIntegrationTest.java`(신규, Testcontainers) — 만료 원자 커밋·Outbox·재고 복원·멱등·롤백·null variant.
- `payment/service/UnpaidOrderExpiryConcurrencyIntegrationTest.java`(신규, Testcontainers) — 만료 vs 결제·만료 vs 사용자 취소 직렬화.
- `payment/PaymentModuleStructureTest`(보강)·`order/OrderModuleStructureTest`(보강)·`ModularityTests`(통과) — 스케줄러/오케스트레이션 payment 위치, 조회·시스템 취소 order.spi, payment→order.spi만, 스케줄러 빈 테스트 비활성 가드.

---

## 3. 데이터 흐름

### 3.1 스케줄러 주기 실행 (백그라운드, R1)
1. `@Scheduled(fixedDelay)` → `UnpaidOrderExpiryScheduler.expireUnpaidOrders()`(비-@Transactional, R1).
2. `threshold = clock.instant() - ttl` 계산(클록 주입 — 테스트 제어).
3. `orderExpiryReader.findExpiredPendingOrderIds(threshold, batchLimit)` → `status='pending' AND created_at < threshold` id 스칼라 리스트(createdAt/id asc, 최대 batchLimit).
4. 각 orderId마다 **빈 경계를 넘어** `paymentService.expirePendingOrder(orderId)` 호출(프록시 적용 → 독립 `@Transactional`). 개별 `try/catch`로 예외 격리(실패 로깅 후 다음 주문 계속).
5. 처리 건수·후보 수 로깅. 남은 만료분은 다음 주기에 처리.

### 3.2 주문 1건 만료 (`expirePendingOrder`, 원자 트랜잭션, R3)
1. ① `orderPaymentReader.getOrderForExpiry(orderId)` → orders row `PESSIMISTIC_WRITE` 잠금(**소유권 없음**), 스냅샷 status.
2. ② 락 후 재검증: `status == 'pending'` → 진행. 그 외(`paid`/이행/`cancelled`/`refunded`) → **부작용 없이 멱등 skip(return)**.
3. ③ `paymentRepository.findByOrderId` → 결제 row 있으면(`ready`/`failed`) `Payment.markCancelled()`(→cancelled). 없으면 결제 처리 없음. **PG 환불 없음.** (1단계 락 보유 상태, R3.)
4. ④ `orderCancellation.cancelByExpiry(orderId)`(소유권 없음) → 락 재진입(R3) → `Order.markCancelled()`(→cancelled) → 재고 복원(variantId 오름차순 `increase`, null skip+log) → `OrderCancelledEvent`(refunded=false, refundedAmount=0, cancelledAt, memberEmail/Name=member.spi, items.productId=product.spi[R4]) 발행(Outbox). Outcome `CANCELLED`. (ALREADY/REJECTED면 롤백 — 방어.)
5. ⑤ 원자 커밋(orders cancelled + payments cancelled? + product_variants stock 증가 + event_publication 1행).

### 3.3 멱등·동시 만료 (orders row 락 직렬화)
- **중복 선택/겹친 주기**: 승자가 ① locked reader로 잠금 → 전이·복원·커밋. 패자는 같은 row 락 대기 → 승자 커밋 후 status=`cancelled` 권위 관찰 → ② 멱등 skip(또는 ④ `ALREADY_CANCELLED`). **1건만 복원/이벤트.**
- **만료 vs 결제(`confirmPaid`)**: 같은 orders row `PESSIMISTIC_WRITE` 직렬화. 결제 먼저 → 만료가 `paid` 관찰 → ② skip(취소·복원 없음). 만료 먼저 → 이후 `confirmPaid`가 `cancelled` 관찰 → `OrderConfirmation.Outcome.REJECTED` → `OrderConfirmationConflictException`(409, 결제 롤백).
- **만료 vs 018 사용자 취소**: `getOrderForExpiry`와 `getOrderForCancel` 모두 `findByIdForUpdate(orderId)` → 같은 row 직렬화. 먼저 커밋한 쪽이 종결, 나머지는 권위 상태 관찰해 멱등(`ALREADY_CANCELLED`) → 이중 복원 없음.

### 3.4 OrderCancelledEvent 발행 (Outbox, 004 메커니즘, R4)
- `OrderCancellationImpl.doCancel`(order 모듈)이 `expirePendingOrder` 트랜잭션 안에서 `publishEvent(orderCancelledEvent)` → `event_publication`(INCOMPLETE) Outbox 저장 → 커밋 후 `spring-modulith-events-kafka`가 `@Externalized("order-cancelled")`로 발행. 페이로드는 `order → member.spi`(memberEmail/name)·`order → product.spi`(productId) 해석으로 자족(R4). 만료는 `refunded=false, refundedAmount=0`.

---

## 4. 예외 처리 전략 (REST 엔드포인트 없음 — HTTP 매핑 아님)

> 본 Task는 동기 응답 표면이 없다. 만료는 스케줄러 주기 실행으로 관측되며, 예외는 **트랜잭션 롤백 + 로깅 + 주문 단위 격리**로 처리된다.

| 상황 | 발생 지점 | 처리 |
|---|---|---|
| **`pending` 아님(paid/이행/이미 종결)** | `expirePendingOrder` ② 락 후 재검증 | **부작용 없이 멱등 skip(return)** — 전이·복원·이벤트 0. 정상(예외 아님). 만료/결제 race 차단. |
| **이미 cancelled/refunded** | ② 재검증 또는 ④ `cancelByExpiry`가 `ALREADY_CANCELLED` | **멱등 skip** — 재고 이중 복원·이벤트 추가 없음. |
| **삭제된 variant(order_item.variant_id null)** | ④ 재고 복원·이벤트 빌더 | 해당 항목 복원 **skip+log**, 나머지 정상 복원, 이벤트 items에서 제외, 만료 성공(best-effort, 018 동형). |
| **한 주문 처리 실패(시스템 오류·락 타임아웃 등)** | `expirePendingOrder` 임의 단계 | 그 주문 트랜잭션 **전체 롤백**(부분 반영 없음). **스케줄러 루프의 try/catch가 격리** → 로깅 후 **다음 주문 계속**. |
| **락 불변식 위반(②에서 `pending` 확인 후 ④가 ALREADY/REJECTED)** | `expirePendingOrder` ④ 방어 검증 | `IllegalStateException`(그 주문 전체 롤백). 정상 흐름 미발생(같은 락 하). 스케줄러가 격리·로깅. |
| **금액 변환(refundedAmount=0 고정)** | 이벤트 빌더 | 만료는 `refundedAmount=0`이라 P3 변환 위반 불가(해당 없음). |
| **만료 후보 id의 주문이 동시 삭제·미존재** | ① `getOrderForExpiry` | `OrderNotFoundException`(방어) → 스케줄러 try/catch 격리, 다음 주문 계속. |

핵심 규칙:
- **성공 = 주문별 원자 커밋**(orders cancelled + payments cancelled? + stock 증가 + event_publication 1행 부분 반영 없음).
- **주문 단위 격리**: 한 주문 실패가 다른 주문을 롤백/중단시키지 않는다(스케줄러 루프 비-@Transactional + 개별 try/catch + 주문별 독립 트랜잭션, R1).
- **시스템 오류 = 그 주문만 전체 롤백**. 로그에 orderId·원인 기록.
- 신규 예외 0(409 `OrderCancellationConflictException`은 만료 경로에서 던지지 않음 — 이행단계는 조회·재검증에서 애초 제외).

---

## 5. 검증 방법 (테스트 클래스 매핑 + Acceptance 매핑)

> 테스트 프로파일·Outbox 검증 방식은 016/017/018과 동일(C12) — Testcontainers 별도 프로파일에서 `event_publication` 저장만 검증(외부화 `enabled=false`). `created_at`은 SQL로 과거 세팅해 만료 상황 생성. 클록은 `Clock` 주입으로 제어.

### 단위(Mockito) — PaymentServiceExpiryTest
- `pending`(결제 row 없음) → `getOrderForExpiry` → `cancelByExpiry` 위임 → 전이·복원·이벤트(환불 없음). `markCancelled` 미호출(결제 row 없음).
- `pending`(결제 row `ready`/`failed`) → `Payment.markCancelled` 호출 + `cancelByExpiry` 위임.
- `paid`/`preparing`/`shipping`/`delivered`/`cancelled`/`refunded` → ② 재검증에서 **멱등 skip**(`markCancelled`·`cancelByExpiry`·`increase`·이벤트 0회).
- 멱등 재호출(이미 cancelled) → skip(복원·이벤트 1회 이하).
- **#R3 락 우선 순서**: `getOrderForExpiry`가 `Payment.markCancelled`·`cancelByExpiry`보다 **먼저** 호출(InOrder).
- **소유권 미검사**: `getOrderForExpiry(orderId)`·`cancelByExpiry(orderId)`가 userId 인자 없이 호출됨을 단언.
- **PG refund 미호출**: `paymentGatewayPort.refund` 0회(만료는 환불 없음).
- (방어) `cancelByExpiry`가 `REJECTED`/`ALREADY_CANCELLED` 주입 시 → `IllegalStateException`(락 불변식 위반).

### 단위(Mockito) — OrderCancellationExpiryTest (또는 OrderCancellationImplTest 보강)
- `cancelByExpiry(orderId)` → `findByIdForUpdate` 락 → **소유권 검증 없음**(userId 미사용) → `doCancel`로 `markCancelled`(→cancelled) + 재고 복원(variantId 오름차순, null skip+log) + `OrderCancelledEvent`(refunded=false, refundedAmount=0, member.spi/product.spi 해석[R4]).
- **코어 공유(R2)**: `cancel(orderId, userId, refundInfo)`와 `cancelByExpiry(orderId)`가 동일 `doCancel`을 호출(전이/복원/이벤트 로직 복제 없음 — 사용자 취소 기존 테스트가 그린 유지로 회귀 0 확인).
- 멱등(`ALREADY_CANCELLED`): 이미 cancelled 주문에 `cancelByExpiry` → 복원·이벤트 0.

### 단위(Mockito) — UnpaidOrderExpirySchedulerTest
- `findExpiredPendingOrderIds(threshold, limit)` 결과를 각 `expirePendingOrder(id)`로 위임(횟수·인자 단언).
- **격리**: 한 `expirePendingOrder`가 예외 던져도 다음 주문 `expirePendingOrder` 호출됨(예외가 루프를 멈추지 않음).
- **배치 한도**: `limit`이 `findExpiredPendingOrderIds`에 전달.
- **클록 주입**: `threshold = clock.instant() - ttl` 계산(고정 Clock으로 threshold 단언).
- **루프 비-@Transactional**: 스케줄러 메서드에 `@Transactional` 없음(코드 리뷰/구조 확인).

### 통합(Testcontainers) — UnpaidOrderExpiryOutboxIntegrationTest
- `created_at`을 과거(>ttl)로 세팅한 `pending` 주문 만료 → `orders.status=cancelled` + (결제 row 있으면)`payments.status=cancelled` + **재고 stock 증가** + `event_publication` 1건(`order-cancelled`, refunded=false, refundedAmount=0) **원자 커밋**.
- TTL 미만 `pending` 주문 → 만료 안 됨(상태·재고 불변, 이벤트 0).
- `paid`/이행 주문(created_at 과거여도) → ② 재검증 skip, 불변(이벤트 0).
- 멱등 재실행(`expirePendingOrder` 2회) → 재고 불변·이벤트 추가 없음.
- 시스템 오류 강제(예: `increase`에서 예외 주입) → 그 주문 전체 롤백(orders/payments/stock/event_publication 부분 반영 없음).
- 삭제된 variant(variant_id null) 포함 주문 만료 → 해당 항목 복원 skip, 나머지 정상 복원, 만료 성공, 이벤트 items 제외.

### 동시성(Testcontainers) — UnpaidOrderExpiryConcurrencyIntegrationTest
- 만료 vs 결제(`confirmPaid`) 동시 → orders row 락 직렬화. 결제 승 → 주문 `paid`, 만료 skip(취소·복원 없음). 만료 승 → 주문 `cancelled`, 이후 `confirmPaid` 거부(`OrderConfirmationConflictException`). 재고·상태 정합.
- 만료 vs 018 사용자 취소 동시 → 직렬화, **이중 복원 없음**, 이벤트 1건.
- 같은 주문 동시 만료 2건 → 1건만 복원/이벤트(멱등).

### 구조(자동) — ModularityTests / Module 구조 테스트
- 스케줄러(`UnpaidOrderExpiryScheduler`)·`expirePendingOrder`·설정이 **payment 모듈**(`com.shop.shop.payment..`) 위치.
- 만료 스칼라 조회(`OrderExpiryReader`)·시스템 locked reader(`getOrderForExpiry`)·시스템 취소(`cancelByExpiry`)가 **order.spi**. payment가 order 내부(service/domain/repository)를 직접 참조하지 않음(`OrderModuleStructureTest`/`PaymentModuleStructureTest` 규칙 그린).
- `payment → order.spi`·`order → inventory.spi`·`order → member.spi`·`order → product.spi`만(순환 없음). `ModularityTests.verify()` 통과.
- 스케줄러 빈이 테스트 컨텍스트에서 비활성(`@ConditionalOnProperty enabled=false`)임을 확인(풀컨텍스트 `@SpringBootTest`가 `UnpaidOrderExpiryScheduler` 빈 없이 로드, 015~021 회귀 없음).

### 실행 / 동적 게이트 (verification-gate)
- `./gradlew test` 전체 그린(메인 에이전트가 직접 확인 — 정적 PASS ≠ 빌드 그린). 신규 빈(스케줄러·OrderExpiryReader·설정) 추가가 풀컨텍스트 테스트 컨텍스트 로드를 깨지 않는지 baseline 대조.
- (보조 수동) docker-compose 기동 후: `created_at` 과거 `pending` 주문 생성 → 주기 실행 → orders `cancelled`·재고 복원·Kafka `order-cancelled`(refunded=false) 1건. `paid` 주문은 불변.

### Acceptance Criteria 매핑 표

| Acceptance(Task) | 검증 수단 |
|---|---|
| TTL 초과 `pending`(결제 row 없음/ready/failed) → cancelled + 재고 복원 + (결제 row)cancelled + `order-cancelled`(refunded=false) Outbox, PG 환불 0 | PaymentServiceExpiryTest·UnpaidOrderExpiryOutboxIntegrationTest |
| TTL 미만 `pending` → 불변 | UnpaidOrderExpiryOutboxIntegrationTest |
| paid/이행/cancelled/refunded → 만료 대상 아님(조회 제외 + 락 후 skip), 불변, 이벤트 0 | PaymentServiceExpiryTest·UnpaidOrderExpiryOutboxIntegrationTest |
| 만료/결제 동시 → 락 직렬화(결제 승=만료 skip / 만료 승=결제 거부) | UnpaidOrderExpiryConcurrencyIntegrationTest |
| 같은 주문 중복 만료 → 멱등(이중 복원 없음, 이벤트 1건) | PaymentServiceExpiryTest·UnpaidOrderExpiryConcurrencyIntegrationTest |
| 삭제된 variant 포함 만료 → skip+log, 나머지 복원, 성공 | OrderCancellationExpiryTest·UnpaidOrderExpiryOutboxIntegrationTest |
| 스케줄러 배치 한도·주문 단위 격리(한 실패가 다른 주문 막지 않음) | UnpaidOrderExpirySchedulerTest |
| 스케줄러 빈 테스트 비활성 가드, 풀컨텍스트 회귀 없음 | 구조 테스트·`./gradlew test` 전체 |
| 신규 migration·이벤트·토픽 없음, `ModularityTests` 통과(payment↔order 순환 없음), 015~018 회귀 없음 | 문서 무변경 확인·ModularityTests·전체 테스트 |
| 락 우선(R3)·소유권 미검사·코어 공유(R2)·루프 비-@Transactional(R1) | PaymentServiceExpiryTest(InOrder)·OrderCancellationExpiryTest·UnpaidOrderExpirySchedulerTest |

---

## 6. 트레이드오프

- **payment 만료 오케스트레이션 소유(동기·주문별 단일 트랜잭션) vs order가 직접 만료**: payment가 `order.spi`(시스템 reader/취소)로 위임하면 `payment → order.spi`(기존 방향)만 추가되어 순환이 없고(018 대칭) 전이·복원·이벤트가 주문별 원자 커밋된다. order가 직접 결제 row를 건드리려면 `order → payment.spi` 순환이 필요 → 회피. 순환 회피 + 원자성 우선.
- **별도 빈 분리(R1) vs 단일 빈 self-invocation**: 스케줄러 루프와 `expirePendingOrder`를 별도 빈으로 두면 프록시가 적용되어 주문별 `@Transactional`이 유효하고 격리가 보장된다. 단일 빈 내부 호출은 `@Transactional`이 조용히 무효화되어 "주문별 원자 커밋"이 깨진다(019 류의 은닉 회귀). 명시적 빈 경계 우선.
- **코어 추출(R2) vs 만료 전용 전이/복원/이벤트 복제**: `doCancel` 코어를 사용자 취소·시스템 만료가 공유하면 전이/복원/이벤트 로직이 한 곳에 모여 분기 발산·이중 유지보수가 없다. 별도 복제는 OrderCancelledEvent 빌드·재고 복원 규약(variantId 오름차순·null skip)이 두 곳으로 갈라져 드리프트 위험. 단일 코어 우선(사용자 취소 기존 테스트 그린으로 회귀 0 보장).
- **`cancelByExpiry(orderId)` 별도 메서드 vs `cancel` 오버로드**: 별도 메서드는 시그니처가 "소유권 없는 시스템 경로"임을 드러내 오용을 컴파일 수준에서 분리하고, 만료의 `RefundInfo(false,0,KRW)` 고정을 호출부에서 감춘다. 오버로드는 인자 차이만으로 소유권 유무가 갈려 실수하기 쉽다. 명시적 진입점 우선.
- **전용 `OrderExpiryReader` SPI vs `OrderPaymentReader`에 스칼라 조회 추가**: 전용 SPI는 "결제 reader"와 "만료 후보 조회"의 책임을 분리해 의미가 명확하다(새 포트 1개, 만료라는 단일 책임 — YAGNI 위반 아님). `OrderPaymentReader`에 끼워넣으면 결제와 무관한 조회가 섞여 응집도가 떨어진다. 책임 분리 우선.
- **스칼라 id 조회 + 배치 한도 vs Entity 페이지 일괄 처리**: id만 조회하고 주문별 독립 트랜잭션에서 잠그면 1회 실행당 락 보유 시간·트랜잭션 크기가 작아 롱 트랜잭션·대량 락을 피한다. Entity 일괄 적재·단일 트랜잭션 만료는 락 폭주·부분 실패 시 전량 롤백 위험. 작은 단위 격리 우선(남은 만료분은 다음 주기).
- **활성화 플래그 가드(verification-gate §4) vs 무조건 `@EnableScheduling`**: 가드로 테스트 컨텍스트에서 스케줄러 빈을 제거하면 풀컨텍스트 테스트의 백그라운드 실행·회귀가 차단되고, 로직은 서비스 직접 호출로 검증된다. 무가드는 모든 `@SpringBootTest`에서 주기 작업이 떠 비결정·오염을 낳는다(019 게이트 교훈). 테스트 격리 우선.
- **`refunded` 상태 미사용·PG 환불 미호출**: 만료는 `pending`(청구 전)만 다뤄 환불 경로(018 paid→refund)를 타지 않는다. `cancelled` 단일 종결로 충분(payment row는 `cancelled`). 환불·`refunded`는 사용자 결제완료 취소(018) 소관 — 범위 분리.
- **신규 migration/이벤트/도메인 전이 0(Constraint)**: 만료 사유/이력 영속(만료 vs 사용자 취소 구분 `cause` 필드 등)은 현재 소비 컨슈머가 없어 불필요 → 후속(데이터 보존정책/notification 필요 시 옵션 B). 본 Task는 **자동 미결제 만료 + 재고 복원 + 기존 이벤트 재사용**까지. 부분 취소·반품/교환·실 PG·물리 삭제·View/REST는 범위 밖.

---

### 구현 분담

**view-implementor 작업 없음** — 본 Task는 REST/View 엔드포인트가 없는 백그라운드 스케줄러다. 만료된 주문은 018에서 추가된 소비자 주문 목록/상세 화면이 이미 `cancelled`를 렌더하므로 View 변경이 없다.

**backend-implementor 단독 담당 파일**:
- (신규) `payment/service/UnpaidOrderExpiryScheduler.java` — `@Scheduled` 루프(R1, `@ConditionalOnProperty` 가드, 비-@Transactional, 주문 단위 try/catch 격리)
- (신규) `payment/service/OrderExpiryProperties.java` — `@ConfigurationProperties("shop.order.pending-expiry")`(ttl/interval/batchLimit/enabled)
- (신규) `payment/service/OrderExpirySchedulingConfig.java` — `@EnableConfigurationProperties` + `@EnableScheduling`(가드) + `Clock` 빈
- (수정) `payment/service/PaymentService.java` — `expirePendingOrder(long orderId)`(@Transactional, 시스템 만료 오케스트레이션, R3)
- (수정) `order/spi/OrderPaymentReader.java` — `getOrderForExpiry(long orderId)`(시스템 locked reader, 소유권 없음)
- (수정) `order/service/OrderPaymentReaderImpl.java` — `getOrderForExpiry` 구현
- (수정) `order/spi/OrderCancellation.java` — `cancelByExpiry(long orderId)`(시스템 취소 진입점, R2)
- (수정) `order/service/OrderCancellationImpl.java` — `doCancel` 코어 추출 + `cancelByExpiry` 추가(R2, 사용자 취소 시그니처·동작 보존)
- (신규) `order/spi/OrderExpiryReader.java` + (신규) `order/service/OrderExpiryReaderImpl.java` — 만료 후보 스칼라 조회 SPI
- (수정) `order/repository/OrderRepository.java` — `findExpiredPendingOrderIds(Instant threshold, Pageable)`(id 스칼라, createdAt/id asc)
- (수정) `application.yml` — `shop.order.pending-expiry.*`(운영 기본) + (수정) `src/test/resources/application.yml` — `enabled: false`
- (신규) 테스트: `PaymentServiceExpiryTest`·`OrderCancellationExpiryTest`(또는 ImplTest 보강)·`UnpaidOrderExpirySchedulerTest`·`UnpaidOrderExpiryOutboxIntegrationTest`·`UnpaidOrderExpiryConcurrencyIntegrationTest` + 구조 테스트 보강(`PaymentModuleStructureTest`/`OrderModuleStructureTest`)
- (재사용·무변경) `Order.markCancelled`·`Payment.markCancelled`·`InventoryStockPort.increase`·`OrderCancelledEvent`·`docs/event-catalog.md`·`docs/architecture.md` §5·migration

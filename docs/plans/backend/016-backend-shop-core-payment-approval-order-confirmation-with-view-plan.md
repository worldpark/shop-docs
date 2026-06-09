# 016. shop-core 모의 결제 승인 + 주문 확정 + OrderCompletedEvent 발행 — 구현 계획(plan)

> Task SSOT: docs/tasks/backend/016-backend-shop-core-payment-approval-order-confirmation-with-view.md
> 후속 Task: docs/tasks/backend/017-backend-shop-core-payment-decline-payment-failed-event.md (거절 분기·PaymentFailedEvent — 016은 승인 happy path만. 본 plan의 포트·Entity·게이트웨이 시그니처는 017에서 안 깨지도록 설계한다)
> 이벤트 계약 SSOT: docs/event-catalog.md(OrderCompletedEvent), docs/architecture.md 섹션 5 — **본 Task에서 무변경**
> 영역: backend(payment 모듈 신규 + order.spi 확장 + Outbox 발행) + view(주문 상세 결제 폼/상태)
> 대상 프로젝트: shop-core (Spring Modulith 모듈러 모놀리스)
> 작성일: 2026-06-08
> 상태: plan only (코드 변경 없음 — 구현은 backend-implementor / view-implementor가 수행)
> 담당: backend-implementor(payment 모듈 전체 + order/member/product SPI + Outbox + 백엔드 테스트) → view-implementor(주문 상세 결제 폼/상태 + View 렌더링 테스트)
> 진행: backend-implementor → view-implementor → reviewer → fixer 사이클(최대 3회)
> 선례 코드: 004(platform Outbox/@Externalized), 015(order 스택·비관적 락·principal 이중경로·존재 은닉 404·테스트 프로파일), 009(의존 역전 어댑터), 014(facade+impl)의 네이밍·레이어·예외·테스트 패턴을 그대로 따른다.

---

## 0. 작업 구분 요약 (백엔드 vs 화면)

### 0.1 담당 분담표

| 구분 | 항목 | 담당 |
|---|---|---|
| 백엔드 | `payment` 모듈 전체: Entity(`Payment`)·Repository·Service(`PaymentService`)·ServiceResponse·RestController·DTO(`PaymentRequest`/`PaymentResponse`)·`payment/spi.PaymentGatewayPort`(+모의 구현)·View facade(`PaymentFacade`)+impl | backend-implementor |
| 백엔드 | `order.spi` 포트 **2개** 신규: `OrderPaymentReader`(락 없음, 소유권 404, 이벤트 완결성 사전검증) + `OrderConfirmation`(orders row 비관락 + 권위 재검증 + `pending→paid` + 이벤트 발행) | backend-implementor |
| 백엔드 | `order.service` 두 포트 구현체(`OrderPaymentReaderImpl`/`OrderConfirmationImpl`), `Order.markPaid()` 의도 메서드, `order/event/OrderCompletedEvent` `@Externalized("order-completed")`, `OrderRepository.findByIdForUpdate`(PESSIMISTIC_WRITE) | backend-implementor |
| 백엔드 | `member.spi.MemberDirectory` 확장(`MemberContact findContactByUserId(long)`), `member.service.MemberDirectoryImpl` 구현 추가 | backend-implementor |
| 백엔드 | `product.spi` — `ProductOrderCatalog`로 `variantId→productId` 해석(기존 `OrderableVariantSnapshot.productId` 재사용. 신규 포트 추가 없음 — order 내부에서만 사용) | backend-implementor |
| 백엔드 | `common/exception`: `PaymentAmountMismatchException`(400), `OrderConfirmationConflictException`(409 — 상태 충돌), `PaymentEventResolutionException`(409 — productId/연락처 해석 불가), `AmountConversionException`(500 — `longValueExact` 위반) | backend-implementor |
| 백엔드 | `security.SecurityConfig` — 결제 경로 권한 **명시 확인/추가**(REST `/api/v1/orders/*/payment`, View `/orders/*/payment`) | backend-implementor |
| 백엔드 | 모든 백엔드 테스트(payment 단위·order 확정/준비 단위·SPI 단위·Outbox/동시성 통합(Testcontainers)·REST/Security·구조) | backend-implementor |
| 화면 | `templates/order/detail.html` 결제 영역(결제 상태 표시 + `pending` 시 결제 폼/버튼) | view-implementor |
| 화면 | `web/order/OrderPaymentForm.java`(폼 백킹: method/amount), `web/order/OrderViewController` 또는 `web/payment/PaymentViewController`의 결제 제출 핸들러(`POST /orders/{orderId}/payment`) | view-implementor |
| 화면 | View 렌더링 테스트(결제 폼 CSRF·성공 redirect·결제 완료 상태 표시·비인증 302) | view-implementor |

> 호출 순서: **백엔드 → 화면.** Service/포트/DTO/Facade 시그니처가 먼저 고정되어야 화면이 안정적으로 바인딩된다. 두 영역은 0.2 인터페이스 접점으로 정합한다.

### 0.2 양 영역 인터페이스 접점 (어긋남 방지)

| 항목 | 값 (계약) |
|---|---|
| View 결제 facade | `PaymentFacade.pay(String email, long orderId, PaymentRequest request) → PaymentResponse` / `PaymentFacade.getPaymentStatus(String email, long orderId) → PaymentStatusView`. **facade는 web 모듈 타입(`OrderPaymentForm`)을 받지 않는다 — payment 소유 DTO(`payment.dto.PaymentRequest`)만 받는다**(web→domain.spi 단방향 유지, #1) |
| 결제 폼 DTO / 변환 위치 | web 폼 백킹 `OrderPaymentForm { String method(기본 "mock"), BigDecimal amount(선택) }`(web 소유). **web 결제 핸들러가 `OrderPaymentForm → payment.dto.PaymentRequest`로 변환한 뒤 facade를 호출한다**(변환은 web 계층 책임). recipient 등 배송 필드 없음(배송지는 015 주문 생성 시 확정) |
| 결제 폼 action | `POST /orders/{orderId}/payment` (CSRF 자동 — View 체인 활성) |
| 결제 성공 redirect | `redirect:/orders/{orderId}` (PRG, flash success) |
| flash 키 | 성공: `flashSuccess`(메시지 "결제가 완료되었습니다."). 실패(409/400)는 `flashError` + `redirect:/orders/{orderId}`. (거절 flashError는 017 — 016 모의는 항상 승인) |
| 주문 상세 모델 키 | 기존 `order`(OrderResponse) 유지 + **신규 결제 영역 모델**: `payment`(결제 상태/금액 표시용 view 모델). 결제 폼은 `pending` 주문이고 결제가 `paid`가 아닐 때만 노출 |
| 결제하기 버튼 노출 조건 | `order.status == "pending"` AND 결제가 `paid`가 아님 |
| 결제 상태 표시 | `결제 대기`(ready/미결제) / `결제 완료`(paid) + 금액 표시 |
| 경로/권한 | View `POST /orders/{orderId}/payment` hasRole("CONSUMER"). REST `POST/GET /api/v1/orders/{orderId}/payment` hasRole("CONSUMER"). 미인증 View 302→/login, REST 401 JSON |

---

## 1. 설계 방식 및 이유

### 1.1 사전 확정 사실 (실제 코드 점검 완료 — 가정 아님)

- **`payments` 테이블은 V1에 이미 존재 — 신규 migration 불필요(확정).** `V1__init_schema.sql` line 314~334: `id`(IDENTITY), `order_id`(FK orders RESTRICT), `method varchar(20) CHECK IN('card','bank_transfer','virtual_account','mock')`, `status varchar(20) CHECK IN('ready','paid','failed','cancelled','refunded')`, `amount numeric(12,2) CHECK≥0`, `pg_transaction_id text`, `paid_at timestamptz`, `created_at/updated_at`(default now), `CONSTRAINT uq_payments_order_id UNIQUE(order_id)`, `trg_payments_set_updated_at` 트리거. → **Payment Entity는 BaseEntity 상속(created/updated 읽기전용), status/method는 DB lowercase 문자열, `failureCode`/`failureReason` 전용 컬럼 없음(016은 불필요 — 017 옵션 A에서 영속 미저장).**
- **`payment` 모듈은 골격(서브패키지별 package-info)뿐이다.** `payment/{controller,domain,dto,event,messaging,repository,service}` 전부 package-info만 존재. **`payment/spi` 패키지 없음 → 신규 생성(`@NamedInterface("spi")`).**
- **`order` 모듈은 015로 완전 구현됨.** `Order`(상태 전이 메서드 없음 — `markPaid()` 추가 필요, status는 lowercase 문자열 `"pending"`), `OrderItem`(`variantId` 스칼라 보유, **`productId` 스냅샷 없음** → 이벤트용 productId는 `product.spi`로 `variantId→productId` 해석), `order/spi.OrderFacade`(View 전용), `order/service`(OrderService/OrderServiceResponse/OrderFacadeImpl/OrderDtoMapper), `order/event`(현재 비어있음 — `OrderCompletedEvent` 신규), `OrderRepository`(`findByIdAndUserId`/`findWithItemsByIdAndUserId` 보유, **PESSIMISTIC_WRITE 메서드 없음** → `findByIdForUpdate` 추가). `order.spi/package-info.java`는 이미 `@NamedInterface("spi")`.
- **`product.spi.ProductOrderCatalog` 기존(015)**: `getOrderableSnapshots(Collection<Long> variantIds) → List<OrderableVariantSnapshot>`. record `OrderableVariantSnapshot`이 **`productId`를 이미 보유**. → `OrderPaymentReader`(order 모듈)가 **이 포트를 그대로 재사용**해 변환·이벤트 완결성 사전검증을 한다. **product.spi 신규 포트 불필요.** order는 이미 `product.spi`에 의존(015 구조 테스트 통과).
- **`member.spi.MemberDirectory` 기존(014)**: `findUserIdByEmail(String)→long`만 보유, `@NamedInterface("spi")`. **`userId→연락처(email/name)` 조회 없음 → 신규 메서드 추가.** 구현 `member.service.MemberDirectoryImpl`은 `MemberService`에 위임(미존재 시 IllegalStateException 변환). `member.domain.User`는 `email`/`name` 필드 보유. → `findContactByUserId`는 `MemberService`에 userId 조회 헬퍼가 있으면 재사용, 없으면 `MemberRepository.findById` 경유(member 내부 구현 — order/payment는 포트만 사용).
- **`inventory.spi.InventoryStockPort`(015)**: `InventoryStockRepository.findByIdForUpdate(long)` = `@Lock(PESSIMISTIC_WRITE) @Query("...where vs.id=:id")` → PostgreSQL `SELECT ... FOR UPDATE`. **`OrderConfirmation.confirmPaid`의 orders row 비관락도 동일 패턴**: `OrderRepository`에 `@Lock(PESSIMISTIC_WRITE) findByIdForUpdate(long id)`를 추가해 `orders` row를 잠근다(015가 `product_variants`를 잠그는 것과 동형).
- **platform(004) Outbox 경로**: `@org.springframework.modulith.events.Externalized("토픽명")` + `ApplicationEventPublisher.publishEvent(event)`를 `@Transactional` 안에서 호출하면 `event_publication`에 INCOMPLETE 저장(Outbox), 커밋 후 `spring-modulith-events-kafka`가 외부화. `DummyOutboxSmokeEvent`(record + `@Externalized` + `TOPIC` 상수)가 정확한 선례. `build.gradle`에 `spring-modulith-events-api`/`spring-modulith-events-kafka` 이미 존재, `application.yml`에 `spring.modulith.events.externalization.enabled=true` 존재, test `application.yml`은 외부화 비활성 + Kafka/JPA 자동설정 exclude. → **`OrderCompletedEvent`는 동일 메커니즘 재사용, build.gradle/application.yml 변경 불필요.**
- **`security.SecurityConfig`**: REST 체인(`@Order(1)`, `securityMatcher("/api/v1/**")`)에 `requestMatchers("/api/v1/orders/**").hasRole("CONSUMER")` 이미 존재 → `/api/v1/orders/{id}/payment`가 **이미 덮인다.** View 체인(`@Order(2)`)에 `requestMatchers("/checkout","/orders","/orders/**").hasRole("CONSUMER")` 이미 존재 → `/orders/{id}/payment`도 **이미 덮인다.** RoleHierarchy = ADMIN>SELLER>CONSUMER. → **결제 하위 경로가 기존 정책에 포함됨을 확인하고, Task가 "명시적으로 추가"를 요구하므로 의도를 드러내는 전용 matcher 라인(`/api/v1/orders/*/payment`, `/orders/*/payment`)을 `/orders/**` 앞에 명시 주석과 함께 추가**(동작 동일, 가독·회귀 방지·Acceptance "명시적으로 적용" 충족).
- **`common.exception`**: `BusinessException(message)`=400, `BusinessException(message, HttpStatus)`. REST=`RestExceptionHandler`(@RestControllerAdvice, `BusinessException.getStatus()` 매핑, MethodArgumentNotValid→400, 그 외→500), View=`ViewExceptionHandler`(error/error). 015 신규 예외 다수 존재(`InsufficientStockException` 409, `OrderNotFoundException` 404 등). → **결제 전용 예외 신규 추가(2.1).**
- **테스트 프로파일 제약(중요)**: `src/test/resources/application.yml`이 DataSource·HibernateJpa·DataSourceTransactionManager·Kafka·Flyway·외부화 자동설정 제외 → 기본 컨텍스트로 JPA/실 DB/Outbox 동작 불가. **회피 패턴 확립됨(015)**: `@SpringBootTest`(또는 `@DataJpaTest`) + `@AutoConfigureTestDatabase(replace=NONE)` + `@Testcontainers`(postgres:16.4-alpine + `@ServiceConnection`) + `@TestPropertySource(properties={"spring.autoconfigure.exclude=","spring.flyway.enabled=true","spring.jpa.hibernate.ddl-auto=validate"})`로 자동설정 제외 리셋 + Flyway V1 적용. **Outbox 통합 테스트는 여기에 더해 `spring.modulith.events.externalization.enabled=false`로 두고 `event_publication` 행 저장(INCOMPLETE)만 검증**(실 Kafka 브로커 불요 — 004 트레이드오프와 동일하게 외부화 라운드트립이 아니라 Outbox 저장을 검증). 동시성은 `OrderCreationConcurrencyIntegrationTest` 선례 위에 작성.
- **구조 테스트**: `ModularityTests.verify()`(Modulith 경계), `WebModuleStructureTest`(web→{...,order,payment}.domain/repository/service 직접참조 금지 규칙에 **payment 이미 포함**, 변경 불요), `OrderModuleStructureTest`(order→cart/product/inventory/member 내부참조 금지). → **신규 `PaymentModuleStructureTest`(payment→order/member/product 내부참조 금지 + `OrderCompletedEvent`가 order 모듈에 위치) 추가.**

### 1.2 모듈 책임 분리 — payment는 처리, order는 확정·발행 (P1 경계)

Task가 못박은 핵심 결정을 그대로 따른다.

- **payment 모듈** = 결제 처리 오케스트레이션: 준비 스냅샷 조회(order.spi) → 멱등/충돌 판정 → 금액 검증 → 모의 PG 승인(`PaymentGatewayPort`) → `payments` paid 기록 → 주문 확정 위임(order.spi). **payment는 `order.domain`/`order.repository`/`order.service`(비공개)를 직접 참조하지 않는다.** order row 락도 직접 잡지 않는다.
- **order 모듈** = 주문 확정·이벤트 발행 소유: `OrderConfirmation.confirmPaid`가 orders row를 `PESSIMISTIC_WRITE`로 잠그고 소유권·`status==pending`·금액을 권위 재검증한 뒤 `pending→paid` 전이(`Order.markPaid()`)하고 **`OrderCompletedEvent`를 `ApplicationEventPublisher`로 발행**(같은 트랜잭션 = Outbox 저장). `OrderCompletedEvent`는 `order/event`가 발행 소유(`@Externalized("order-completed")`, package-structure-rule).
- 두 포트 구현(`OrderPaymentReaderImpl`/`OrderConfirmationImpl`)은 **order 내부 `service` 패키지**에 두고, 이벤트 페이로드 구성용 member 연락처는 `member.spi`, item별 productId는 `product.spi`(`ProductOrderCatalog`)로 조회한다(order는 015에서 이미 두 spi에 의존 — 구조 테스트 통과 범위).

**이유**: 발행 소유권을 order에 고정하면 "결제만 승인되고 주문 미확정/미발행"을 트랜잭션 경계와 모듈 경계 양쪽에서 차단한다. payment↛order.domain은 구조 테스트로 강제된다.

### 1.3 트랜잭션 단일화 + 결제 처리 8단계 고정 (원자성·멱등·실 PG 전환 안전성)

`PaymentService.pay(long userId, long orderId, PaymentCommand cmd)`는 **단일 `@Transactional`** 안에서 아래 순서를 고정한다. payment 트랜잭션 안에서 호출되는 `OrderConfirmation.confirmPaid`는 같은 트랜잭션에 참여(`Propagation.REQUIRED` 기본)하므로 `payments` 기록·주문 확정·이벤트 발행이 **하나의 커밋 단위**다.

1. **준비 스냅샷 조회(락 없음)** — `OrderPaymentReader.getPayableOrder(orderId, userId)`.
   - 소유권 검증: 타 사용자 주문·미존재 모두 `OrderNotFoundException`(404 존재 은닉, 015 정책 동일).
   - 반환 `OrderPaymentView`: `orderId`, `orderNumber`, `userId`(=memberId), `status`(lowercase), `finalAmount`(BigDecimal), `currency`("KRW").
   - **이벤트 발행 완결성 사전 검증**(P2): 주문 전 항목 `variantId→productId` 해석(`product.spi`)과 member 연락처(`member.spi` email/name) 모두 가능해야 한다. 하나라도 불가면 **PG 호출 전** `PaymentEventResolutionException`(409). 이 검증은 **결제(pay) 경로 전용**이며, 상태 조회 경로는 호출하지 않는다(#3 — 1.8/3.3 분리). confirmPaid가 락 후 재구성하되, 사전검증으로 "승인 후 구성 실패"를 원천 차단.
2. **멱등/충돌 1차 판정(빠른 경로)** — 준비 스냅샷 `status`로:
   - 이미 `paid`(주문)이고 `payments`가 `paid` → **재발행·더블결제 없이** 기존 결제 결과를 멱등 반환(`PaymentResponse` 200).
   - `pending`이 아닌 그 외 상태 → `OrderConfirmationConflictException`(409 상태 충돌).
3. **금액 검증** — `cmd.amount()`가 전달됐다면 `finalAmount`와 비교, 불일치 → `PaymentAmountMismatchException`(400, 사용자 입력 오류). 미전달이면 검증 생략(서버 권위 값 사용).
4. **결제 선점: `payments` ready row 확보 — PG 호출 전 직렬화의 핵심(#2)** — `PaymentRepository`로 orderId 결제 row를 조회·생성한다.
   - 기존 row 없음 → `Payment.create(orderId, method, finalAmount)`(status="ready") **INSERT**. `uq_payments_order_id`가 **INSERT 시점에 동시 요청을 직렬화**한다: 동일 주문 동시 2건 중 하나만 ready row를 선점하고, 나머지는 unique 인덱스에서 대기하다가 선점 트랜잭션 커밋 후 `DataIntegrityViolationException`을 받는다.
   - 동시 위반(`DataIntegrityViolationException`) → 결제 row 재조회: `paid`면 멱등 반환(200), `ready`(드문 비정상 잔존)면 `PaymentInProgressException`(409, "결제 처리 중").
   - 기존 row가 `paid` → 멱등 반환(200). 기존 row가 `ready`(같은 흐름의 재시도) → 동일 row 재사용(신규 INSERT 안 함).
   - **이 단계가 PG(5단계)보다 먼저 완료되므로, PG 승인을 받는 트랜잭션은 항상 단일화된다.** 동시 요청 2건이 모두 PG 승인되는 문제가 제거된다.
5. **모의 PG 승인** — `PaymentGatewayPort.authorize(PaymentAuthorizationRequest)`(주문번호·금액·통화·method, **idempotencyKey=orderNumber 또는 paymentId 포함**). 016 모의 구현은 **항상 승인**(`PaymentAuthorizationResult.approved`, `pgTransactionId` 부여). 외부 I/O는 이 단계뿐이며 **주문 row 락(7단계) 밖**에서 수행한다 — ready row 선점(4)으로 이미 단일화되어 락 없이도 중복 승인이 차단된다. **이 단계 이후 이벤트 페이로드 구성용 외부 조회가 남지 않는다**(1단계에서 완결성 보장 → 실 PG 전환 시 "승인 후 확정 실패" 차단).
6. **payments paid 전이** — 선점한 ready row를 `markPaid(pgTransactionId, paidAt)`(ready→paid). `amount`는 **서버 권위 `finalAmount`**(클라이언트 금액 미신뢰, 4단계에서 이미 ready로 기록).
7. **주문 확정 위임** — `OrderConfirmation.confirmPaid(orderId, userId, paidAmount=finalAmount)`:
   - `OrderRepository.findByIdForUpdate(orderId)`로 **orders row 비관락**(주문 상태 권위 직렬화).
   - 락 후 권위 재검증: 소유권(`order.userId==userId`, 불일치 404) · `status=="pending"`(이미 `paid`면 멱등 결과 반환·무발행 / 그 외 충돌 409) · 금액(`order.finalAmount.compareTo(paidAmount)==0`, 불일치 409).
   - `Order.markPaid()`(`pending`에서만 허용, 아니면 도메인 예외) → status `paid` 전이.
   - **`OrderCompletedEvent` 구성·발행**: member 연락처(`member.spi`), item productId/productName/quantity/unitPrice(`product.spi` + `order_items` 스냅샷), 금액 long 변환(P3, 1.5)으로 페이로드 자족 구성 → `ApplicationEventPublisher.publishEvent(event)`(같은 트랜잭션 Outbox 저장).
   - 반환 `OrderConfirmationResult`(orderId, orderNumber, paid 여부, orderedAt). 멱등 분기(이미 paid)는 `eventPublished=false`.
8. **커밋** — payments paid + orders paid + event_publication 1행이 원자적으로 커밋. 어느 단계 실패든 전체 롤백(**ready row 선점 포함** 부분 반영 없음).

> **락 획득 순서 일관성(데드락 회피)**: 모든 결제 트랜잭션은 (4) `payments` uq → (7) `orders` row 락 순으로 자원을 획득한다. 동시 요청은 (4)에서 먼저 직렬화되어 (7) 락에 동시 도달하지 않으므로 락 순환이 없다.
> **락 구간 경계 주의**: 7단계 confirmPaid 내부에서만 orders row 락을 보유한다. PG 호출(5)·연락처/productId 조회는 락 구간 밖이다(1단계 사전검증 + 7단계 락 후 재구성은 같은 DB 읽기 — 외부 I/O 아님). 실 PG 어댑터로 교체 시 5단계가 유일한 외부 I/O이며 락 밖이고, ready row 선점 + idempotencyKey로 at-most-once 승인이 보장된다.

### 1.4 멱등성·동시성 직렬화 (Acceptance 핵심)

- **PG 호출 전 직렬화(#2 핵심)**: 동일 주문 동시 결제 2건은 **4단계 `payments` ready row INSERT에서 `uq_payments_order_id`로 직렬화**된다. 하나만 ready를 선점해 PG(5)로 진행하고, 나머지는 `DataIntegrityViolationException` → 재조회로 멱등(paid) 또는 409(in-progress). **PG 승인을 받는 트랜잭션이 항상 1개**이므로 "동시 2건 모두 PG 승인"이 발생하지 않는다(실 PG에서 더블 charge 차단). 실 PG 전환 시 5단계에 idempotencyKey를 전달해 프로세스 재시도까지 at-most-once를 보장한다.
- **멱등**: 이미 `paid`면 2단계(준비 스냅샷)·4단계(ready 선점 재조회)·7단계(락 후 재검증) 어디서든 멱등 반환 — 더블결제·`OrderCompletedEvent` 재발행 없음. 락 없는 준비 스냅샷(2)은 race가 가능하므로 **권위 판정은 4단계 uq 선점 + 7단계 orders 락 후 재검증**이 담당(2단계는 빠른 경로 멱등).
- **주문 상태 권위 직렬화**: `confirmPaid`의 orders row `PESSIMISTIC_WRITE`(7)는 주문 status/금액 전이를 권위 직렬화한다(다른 주문 상태 전이와의 경합 방지). `payments` row 단일성은 `uq_payments_order_id`(4)가 보장 → **`payments` row 1건 유지** + **OrderCompletedEvent 1건만 발행**.
- **역할 비충돌 정리**: `uq_payments_order_id`/ready row 선점(4) = 결제 단일화·PG 단일 호출, `confirmPaid` orders 락(7) = 주문 상태 권위 전이·이벤트 발행. 두 메커니즘은 서로 다른 자원을 일관 순서(payments→orders)로 잡아 충돌·데드락이 없다.
- payment는 order row를 직접 잠그지 않는다(P1) — orders 락은 `OrderConfirmation.confirmPaid`(order 모듈) 안에서만 획득. payment는 자기 소유 `payments` row만 선점한다.

### 1.5 금액 타입 변환 규칙 (P3 — numeric(12,2) BigDecimal → long KRW)

- `orders.final_amount`/`payments.amount`는 `numeric(12,2)`(BigDecimal). `OrderCompletedEvent.totalAmount`/`items[].unitPrice`는 `long`(KRW=원, event-catalog).
- KRW 소수 단위 없음 → BigDecimal 소수부는 0(`.00`)만 허용. 변환은 **`BigDecimal.longValueExact()`**.
- 소수부가 있거나 long 범위 초과 시 `ArithmeticException` → **`AmountConversionException`**(시스템 불변식 위반 — 500. 정상 사용자 입력 오류 아니므로 400 아님)으로 변환해 명확히 실패 + 전체 롤백.
- `Payment.amount`는 BigDecimal로 저장(정밀도 보존), 이벤트 페이로드 직렬화 시점에만 long 변환(저장 정밀도와 계약 타입 분리). 변환 유틸은 order 내부 헬퍼(예: `OrderConfirmationImpl`의 private 메서드) — payment는 변환 불요(금액 그대로 BigDecimal 저장).

### 1.6 PaymentGatewayPort = 교체 가능 추상화 (016 모의 = 항상 승인, 017 거절 시그니처 호환)

- 인터페이스를 `payment/spi`에 두고 모의 구현을 `payment/service`(또는 별도 어댑터)에 분리(ObjectStorage 추상화 철학). **승인/거절을 모두 표현하는 시그니처**로 016에서 확정해 017에서 인터페이스를 바꾸지 않는다.
  - 입력 `PaymentAuthorizationRequest(orderNumber, BigDecimal amount, String currency, String method, String idempotencyKey)`. `idempotencyKey`는 결제 식별자(orderNumber 또는 payment id) — 실 PG 전환 시 프로세스 재시도까지 at-most-once charge 보장(#2). 016 모의는 무시해도 무방하나 시그니처에 포함해 017/실 PG에서 불변.
  - 출력 `PaymentAuthorizationResult { boolean approved, String pgTransactionId, String failureCode(nullable), String failureReason(nullable) }` + 정적 팩토리 `approved(pgTransactionId)` / `declined(failureCode, failureReason)`.
  - 016 모의는 항상 `approved(...)` 반환(거절 분기 비활성). 017이 모의 구현 내부에 결정적 거절 규칙만 추가하면 됨 — 포트·DTO 무변경.

### 1.7 결제 status·Entity 설계 (Setter 금지·정적 팩토리·의도 메서드)

- `Payment` Entity: `orderId` 스칼라(order Entity 직접 참조 금지), `method`(016 기본 `"mock"`), `status`(016에서 `"ready"`/`"paid"`만 — `"failed"`는 017), `amount`(BigDecimal), `pgTransactionId`(nullable, 승인 시), `paidAt`(nullable, 승인 시), `createdAt`/`updatedAt`(BaseEntity 읽기전용, DB 트리거 소유).
- **Setter 금지.** 정적 팩토리 `Payment.create(long orderId, String method, BigDecimal amount)`(status="ready") + 의도 메서드 `markPaid(String pgTransactionId, Instant paidAt)`(ready→paid 전이, paid에서 재호출은 멱등/도메인 예외). `markFailed`는 017에서 추가(016 미구현). `@NoArgsConstructor(PROTECTED)`(Order/ProductVariant 선례).

---

## 2. 구성 요소 (신규/수정 파일 — 정확한 패키지 경로)

> 2.1 backend-implementor = payment 모듈 전체 + order.spi 2포트·구현·Order.markPaid·OrderCompletedEvent + member/product spi + 예외 + Security + 백엔드/통합 테스트. 2.2 view-implementor = 주문 상세 결제 폼/상태 + 결제 제출 핸들러 + View 렌더링 테스트.

### 2.1 backend-implementor 담당 범위

#### 신규 — payment/domain
- `payment/domain/Payment.java` — `@Entity @Table(name="payments")` extends `BaseEntity`. 필드: `Long id`(IDENTITY), `Long orderId`(scalar), `String method`, `String status`, `BigDecimal amount`(precision=12, scale=2), `String pgTransactionId`(nullable), `Instant paidAt`(nullable). `@Getter @NoArgsConstructor(PROTECTED)`. 정적 팩토리 `create(orderId, method, amount)`(status="ready"), 의도 메서드 `markPaid(pgTransactionId, paidAt)`(ready→paid, paid 재호출 멱등 처리). Setter 금지. javadoc에 "status는 016에서 ready/paid만, failed는 017".

#### 신규 — payment/repository
- `payment/repository/PaymentRepository.java` — `JpaRepository<Payment, Long>`. `Optional<Payment> findByOrderId(long orderId)`(주문당 1건 — uq_payments_order_id). ready row 선점(1.3-4)은 `save(Payment.create(...))` INSERT + `uq_payments_order_id` 위반(`DataIntegrityViolationException`) 캐치로 처리(별도 락 쿼리 불요). 동시성 검증을 위해 INSERT는 즉시 flush되어 unique 충돌이 트랜잭션 경계에서 드러나야 한다(`saveAndFlush` 또는 명시 flush).

#### 신규 — payment/spi (신규 패키지)
- `payment/spi/package-info.java` — `@org.springframework.modulith.NamedInterface("spi")`(order.spi 선례 톤).
- `payment/spi/PaymentGatewayPort.java` — 모의 PG 추상화 published port. `PaymentAuthorizationResult authorize(PaymentAuthorizationRequest request)`. record `PaymentAuthorizationRequest(String orderNumber, BigDecimal amount, String currency, String method)`, record `PaymentAuthorizationResult(boolean approved, String pgTransactionId, String failureCode, String failureReason)` + 정적 팩토리 `approved`/`declined`. javadoc에 "016 모의는 항상 승인, 거절 분기는 017".
- `payment/spi/PaymentFacade.java` — View 전용 published port. `PaymentResponse pay(String email, long orderId, PaymentRequest request)`, `PaymentStatusView getPaymentStatus(String email, long orderId)`. **web 타입(`OrderPaymentForm`)을 받지 않고 payment 소유 `PaymentRequest`만 받는다(#1).** email→userId는 내부에서 `MemberDirectory`로 변환(OrderFacade 선례). 구현은 payment 내부 service.

#### 신규 — payment/service
- `payment/service/MockPaymentGateway.java` — `@Component`(package-private) implements `PaymentGatewayPort`. 016: 항상 `PaymentAuthorizationResult.approved(생성 pgTransactionId)`. `pgTransactionId`는 결정적/식별 가능 형식(예: `"MOCK-" + UUID`). 외부 I/O 없음(in-process).
- `payment/service/PaymentService.java` — `@Service`. 모든 메서드 첫 인자 `long userId`. `@Transactional public PaymentResult pay(long userId, long orderId, PaymentCommand cmd)` — 1.3의 8단계 고정 흐름(ready row 선점 포함). 의존: `OrderPaymentReader`, `OrderConfirmation`(order.spi), `PaymentGatewayPort`, `PaymentRepository`. **order.domain/repository 직접 참조 금지.** `@Transactional(readOnly=true) PaymentStatusResult getPaymentStatus(long userId, long orderId)` — **소유권/상태 조회는 `OrderPaymentReader.getOrderSnapshot`(상태 조회 전용, 이벤트 완결성 검증 안 함)을 사용한다(#3).** 타인 404 + `PaymentRepository.findByOrderId`로 결제 status 조립. **상태 조회가 productId/연락처 해석 실패(409)로 깨지지 않는다.** 내부 결과 타입(`PaymentResult`/`PaymentStatusResult` record, Entity 미노출).
- `payment/service/PaymentServiceResponse.java` — `@Service`. REST 전용. `(long) authentication.getPrincipal()` 추출 → `PaymentRequest → PaymentCommand` 변환 → PaymentService 위임 + DTO 변환(`PaymentResponse`). 비즈니스 로직 없음(OrderServiceResponse 선례). 멱등 재요청(이미 paid)은 200으로 기존 결과 반환.
- `payment/service/PaymentFacadeImpl.java` — `payment.spi.PaymentFacade` 구현(package-private). 입력 `PaymentRequest`(web 타입 아님, #1) → `MemberDirectory.findUserIdByEmail(email)` 변환 + `PaymentRequest → PaymentCommand` 변환 후 PaymentService 위임 + DTO 변환(OrderFacadeImpl 선례).
- `payment/service/PaymentDtoMapper.java` — package-private `@Component`. 내부 결과 → `PaymentResponse`/`PaymentStatusView` 변환. ownerId/Entity 미노출.

#### 신규 — payment/dto
- `payment/dto/PaymentRequest.java` — record(`String method`(선택, 기본 "mock"), `BigDecimal amount`(선택 — 전달 시 finalAmount 일치 검증)). 검증은 서비스에서 금액 비교(필수값 강제 없음).
- `payment/dto/PaymentResponse.java` — record(`long paymentId`, `long orderId`, `String orderNumber`, `String status`(lowercase "paid"/"ready"), `String method`, `BigDecimal amount`, `String pgTransactionId`(승인 시), `Instant paidAt`(승인 시)). ownerId/Entity/로컬 경로 미포함.
- `payment/dto/PaymentStatusView.java` — record(주문 상세 결제 영역용: `long orderId`, `String status`(paid/ready/none), `boolean paid`, `boolean payable`(=주문 pending && !paid), `BigDecimal amount`, `Instant paidAt`(nullable)). View가 결제 폼 노출 조건·상태 표시에 사용.

#### 신규 — payment/controller
- `payment/controller/PaymentRestController.java` — `@RestController @RequestMapping("/api/v1/orders/{orderId}/payment")`. 비즈니스 로직 없음, `PaymentServiceResponse` 위임. Authentication 주입(principal=userId).
  - `POST` `@Valid @RequestBody(required=false) PaymentRequest` → 200 + `PaymentResponse`(승인/멱등). 금액 불일치 400, 비정상 상태 409, productId/연락처 해석 불가 409, 타인 404.
  - `GET` → 200 + `PaymentResponse`(또는 status view) 자기 주문 결제 상태. 타인 404.

#### 신규/수정 — order/spi (포트 2개 신규)
- `order/spi/OrderPaymentReader.java` — published port(order 소유), 메서드 **2개**(결제 준비용 / 상태 조회용 분리, #3):
  - `OrderPaymentView getPayableOrder(long orderId, long requesterUserId)` — **결제(pay) 전용.** 소유권 404 존재 은닉 + **이벤트 완결성(전 항목 productId 해석 + member 연락처) 사전검증 불가 시 409**. **017에서 시그니처 불변**.
  - `OrderSnapshotView getOrderSnapshot(long orderId, long requesterUserId)` — **상태 조회 전용.** 소유권 404 존재 은닉 + 주문 상태/금액 스냅샷만 반환. **productId/연락처 해석을 수행하지 않으므로 409로 깨지지 않는다.** 결제 상태 조회·주문 상세 렌더링이 이벤트 payload 구성 실패에 영향받지 않게 한다.
  - record `OrderPaymentView(long orderId, String orderNumber, long userId, String status, BigDecimal finalAmount, String currency)`, record `OrderSnapshotView(long orderId, String orderNumber, long userId, String status, BigDecimal finalAmount, String currency)`(동형 — 의미상 분리, 필요 시 공용 record로 통합 가능). order/member/product Entity 노출 금지.
- `order/spi/OrderConfirmation.java` — published port(order 소유). `OrderConfirmationResult confirmPaid(long orderId, long requesterUserId, BigDecimal paidAmount)`. record `OrderConfirmationResult(long orderId, String orderNumber, boolean confirmed, boolean eventPublished, Instant orderedAt)`. javadoc: "orders row PESSIMISTIC_WRITE + 소유권·status==pending·금액 권위 재검증 + pending→paid + OrderCompletedEvent 발행. 이미 paid면 멱등 무발행 반환, 그 외 충돌 409".
- (`order/spi/package-info.java` 기존 `@NamedInterface("spi")` — 변경 불요. 두 인터페이스 추가 시 자동 published.)

#### 신규 — order/event
- `order/event/OrderCompletedEvent.java` — `@org.springframework.modulith.events.Externalized("order-completed")` record. 필드: 공통 봉투 `UUID eventId`, `Instant occurredAt` + `long orderId`, `String orderNumber`, `long memberId`, `String memberEmail`, `String memberName`, `List<Item> items`, `long totalAmount`, `String currency`, `Instant orderedAt`. 중첩 record `Item(long productId, String productName, int quantity, long unitPrice)`. `public static final String TOPIC = "order-completed";`(DummyOutboxSmokeEvent 선례). **event-catalog 스키마 그대로 — 계약 무변경.**

#### 신규 — order/service (두 포트 구현)
- `order/service/OrderPaymentReaderImpl.java` — `@Service @Transactional(readOnly=true)` package-private implements `OrderPaymentReader`(두 메서드, #3).
  - `getPayableOrder`(결제 전용): `OrderRepository.findWithItemsByIdAndUserId(orderId, requesterUserId)` 없으면 `OrderNotFoundException`(404). **이벤트 완결성 사전검증**: 항목 variantId 목록 → `ProductOrderCatalog.getOrderableSnapshots` → 전 항목 productId 해석 가능 여부 + `MemberDirectory.findContactByUserId(order.userId)` 연락처 존재 여부. 불가 → `PaymentEventResolutionException`(409). `OrderPaymentView` 반환(currency 상수 "KRW").
  - `getOrderSnapshot`(상태 조회 전용): `OrderRepository.findByIdAndUserId(orderId, requesterUserId)` 없으면 `OrderNotFoundException`(404). **productId/연락처 해석·완결성 검증 없이** `OrderSnapshotView`(orderNumber/status/finalAmount/currency)만 반환. 409를 던지지 않는다.
- `order/service/OrderConfirmationImpl.java` — `@Service @Transactional` package-private implements `OrderConfirmation`. `OrderRepository.findByIdForUpdate(orderId)`(비관락) → 소유권(불일치 404) → `status` 분기(paid면 멱등 `OrderConfirmationResult(confirmed=true, eventPublished=false)` / pending 아니면 `OrderConfirmationConflictException` 409) → 금액(`finalAmount.compareTo(paidAmount)!=0` → 409) → `order.markPaid()` → `OrderCompletedEvent` 구성(member.spi 연락처 + product.spi item productId + 금액 longValueExact 변환, 위반 `AmountConversionException` 500) → `eventPublisher.publishEvent(event)`. `@Slf4j` 발행 시도/성공 로그(eventId/topic).
  - 의존: `OrderRepository`, `MemberDirectory`(member.spi), `ProductOrderCatalog`(product.spi), `ApplicationEventPublisher`.
- (수정) `order/domain/Order.java` — 의도 메서드 `markPaid()` 추가: `if(!"pending".equals(status)) throw new IllegalStateException(...)`; `this.status = "paid";`. Setter 추가 금지.
- (수정) `order/repository/OrderRepository.java` — `@Lock(LockModeType.PESSIMISTIC_WRITE) @Query("select o from Order o where o.id = :id") Optional<Order> findByIdForUpdate(@Param("id") long id)` 추가(InventoryStockRepository.findByIdForUpdate 선례 동형). items eager가 필요하면 confirmPaid 내부에서 락 후 `order.getItems()` 접근(같은 트랜잭션 LAZY 로딩) 또는 `findWithItemsByIdAndUserId`로 별도 읽기 — backend-implementor가 락 row와 items 로딩을 같은 영속 컨텍스트에서 일관 처리.

#### 수정 — member/spi + member/service (userId→연락처)
- `member/spi/MemberDirectory.java` — 메서드 추가 `MemberContact findContactByUserId(long userId)` + record `MemberContact(String email, String name)`. 기존 `findUserIdByEmail` 유지. javadoc: "이벤트 페이로드용 연락처. member Entity 노출 금지, scalar DTO만. 미존재 시 IllegalStateException(시스템 불변식)".
- `member/service/MemberDirectoryImpl.java` — `findContactByUserId` 구현: `MemberService`로 userId→User 조회(헬퍼 없으면 member 내부 repository 경유) → `MemberContact(user.getEmail(), user.getName())`. MemberNotFoundException → IllegalStateException 변환(기존 톤).
- (필요 시) `member/service/MemberService.java` — userId 조회 메서드가 없으면 `getById(long)` 추가(member 내부, 외부 미노출).

#### product/spi — 재사용 (신규 없음)
- `product.spi.ProductOrderCatalog.getOrderableSnapshots`가 `OrderableVariantSnapshot.productId`를 이미 제공 → `variantId→productId` 해석에 그대로 사용. 신규 포트/메서드 추가하지 않는다(과도한 설계 회피). 해석 불가(variant 삭제로 스냅샷 누락)는 `OrderPaymentReaderImpl`/`OrderConfirmationImpl`에서 `PaymentEventResolutionException`(409)으로 매핑.

#### 신규 — common/exception (결제 전용, 최소 추가)
- `common/exception/PaymentAmountMismatchException.java` — extends BusinessException(기본 400). 클라이언트 전달 금액 ≠ finalAmount.
- `common/exception/OrderConfirmationConflictException.java` — extends BusinessException, `super(message, HttpStatus.CONFLICT)`(409). 주문 status가 pending/paid 외(비정상 상태 전이 충돌).
- `common/exception/PaymentEventResolutionException.java` — extends BusinessException(409). 이벤트 완결성 사전검증 실패(productId/연락처 해석 불가). 메시지 내부 정보 비노출.
- `common/exception/PaymentInProgressException.java` — extends BusinessException(409). ready row 선점 경합(`DataIntegrityViolationException` 후 재조회 시 ready 잔존 — "결제 처리 중", #2). 내부 정보 비노출.
- `common/exception/AmountConversionException.java` — extends BusinessException, `super(message, HttpStatus.INTERNAL_SERVER_ERROR)`(500). longValueExact 위반(시스템 불변식). (이미 `OrderNotFoundException` 404 존재 — 재사용.)

#### 수정 — security
- `security/SecurityConfig.java` — 기존 `/api/v1/orders/**`·`/orders/**` hasRole("CONSUMER")가 결제 하위 경로를 이미 덮음을 확인하고, **의도 명시용 전용 matcher를 `/orders/**` 라인 앞에 추가**(주석 "결제 경로 — Task 016 명시 권한"):
  - REST 체인: `.requestMatchers("/api/v1/orders/*/payment").hasRole("CONSUMER")` (anyRequest·`/api/v1/orders/**` 앞).
  - View 체인: `.requestMatchers("/orders/*/payment").hasRole("CONSUMER")` (`/orders/**` 앞).
  - 동작은 기존과 동일하나 Acceptance "결제 경로에 최소 권한 ROLE_CONSUMER가 명시적으로 적용된다"를 코드로 충족.

#### 신규 — 테스트 (backend) → 5절 매핑
- `payment/service/PaymentServiceTest.java`(단위, Mockito: OrderPaymentReader/OrderConfirmation/PaymentGatewayPort/PaymentRepository mock).
- `payment/service/PaymentServiceResponseTest.java`(단위: principal userId 추출·DTO 변환·멱등 200·ownerId/Entity 미노출).
- `payment/service/PaymentFacadeImplTest.java`(단위: MemberDirectory email→userId 위임).
- `payment/service/MockPaymentGatewayTest.java`(단위: 항상 승인·pgTransactionId 비어있지 않음·동일 입력 결정성).
- `order/service/OrderPaymentReaderImplTest.java` + `order/service/OrderConfirmationImplTest.java`(단위, Mockito: OrderRepository/MemberDirectory/ProductOrderCatalog/ApplicationEventPublisher mock).
- `order/domain/OrderTest.java`(단위: markPaid가 pending에서만 허용, 그 외 도메인 예외) — 015에 없으면 신규.
- `member/service/MemberDirectoryImplTest.java`(단위: findContactByUserId scalar 반환·Entity 미노출) — 015에 있으면 보강.
- **통합(Testcontainers)**: `payment/service/PaymentOutboxIntegrationTest.java`(승인 커밋 시 event_publication에 OrderCompletedEvent 1건 + payload 스키마 만족 + 시스템오류 롤백) + `payment/service/PaymentConcurrencyIntegrationTest.java`(동일 주문 동시 결제 2건 → 1건 paid·payments 1행·이벤트 1건) — `OrderCreationConcurrencyIntegrationTest` 프로파일 패턴 재사용 + 외부화 비활성.
- `payment/controller/PaymentRestControllerSecurityTest.java`(@SpringBootTest+MockMvc, @MockitoBean PaymentServiceResponse: 401/403/200·role 매핑·400·409·404·비노출 필드).
- `payment/PaymentModuleStructureTest.java`(ArchUnit: payment→order/member/product 내부참조 금지 + `OrderCompletedEvent`가 order 모듈에 위치).

### 2.2 view-implementor 담당 범위

#### 수정 — templates/order/detail.html
- 기존 보존 계약(헤더/항목/금액/배송지) 유지 + **결제 영역 추가**:
  - 결제 상태 표시: `결제 대기`(payment.paid=false) / `결제 완료`(payment.paid=true) + 금액(`payment.amount` 또는 `order.finalAmount`).
  - 결제 폼: `th:if="${payment.payable}"`(=주문 pending && 미결제)일 때만 노출. action `th:action="@{/orders/{orderId}/payment(orderId=${order.orderId})}"` method POST, 히든 `method`(기본 "mock") + 선택 `amount`(서버 권위라 미표시도 허용). CSRF 자동(View 체인). 결제하기 버튼.
  - flash 메시지: 기존 `fragments/messages.html`(flashSuccess/flashError) 재사용.

#### 신규 — web (결제 폼 + 제출 핸들러)
- `web/order/OrderPaymentForm.java`(또는 `web/payment/OrderPaymentForm.java`) — **web 소유** 폼 백킹 record/class(`String method`(기본 "mock"), `BigDecimal amount`(선택)). facade로 직접 넘기지 않는다(#1).
- 결제 제출 핸들러 — `web/order/OrderViewController` 또는 신규 `web/payment/PaymentViewController`(@Controller): `POST /orders/{orderId}/payment`(@ModelAttribute OrderPaymentForm + Authentication + RedirectAttributes). `CurrentActorResolver.resolve(auth).email()` → **`OrderPaymentForm`을 `payment.dto.PaymentRequest`로 변환(web 계층 책임, #1)** → `PaymentFacade.pay(email, orderId, paymentRequest)` → 성공 `flashSuccess` + `redirect:/orders/{orderId}`. BusinessException(409/400) → `flashError` + `redirect:/orders/{orderId}`. `PaymentFacade`(payment.spi)만 의존(도메인 내부·`OrderPaymentReader` 등 미참조).
- 주문 상세 GET 핸들러에 결제 상태 모델 주입: `model.addAttribute("payment", paymentFacade.getPaymentStatus(email, orderId))`(기존 OrderViewController.orderDetail에 추가하거나 PaymentViewController로 분리 — backend facade 시그니처 0.2 준수).

#### 신규 — 테스트 (view) → 5절 매핑
- `view/PaymentViewRenderingTest.java`(@SpringBootTest+MockMvc, PaymentFacade/OrderFacade @MockitoBean): pending 주문 상세 결제 폼(CSRF) 렌더·결제 성공 redirect `/orders/{id}`+flashSuccess·paid 주문은 결제 폼 미노출/결제 완료 표시·비인증 `POST /orders/{id}/payment` 302→/login.
- (선택) `web/payment/PaymentViewControllerTest.java`(컨트롤러 단위: 모델 키 `payment`·redirect·flashSuccess/flashError·email 전달).

---

## 3. 데이터 흐름

### 3.1 결제 승인 — REST (POST /api/v1/orders/{orderId}/payment)
1. Security REST 체인 `/api/v1/orders/*/payment` hasRole(CONSUMER). 비인증 → 401 JSON(RestAuthenticationEntryPoint). ROLE 없는 인증 → 403 JSON(RestAccessDeniedHandler).
2. JWT 필터 principal=userId. `PaymentRestController.POST` → `PaymentServiceResponse.pay(auth, orderId, PaymentRequest)`.
3. ServiceResponse: `userId=(long)auth.getPrincipal()` → `PaymentService.pay(userId, orderId, command)`.
4. `PaymentService.pay`(@Transactional, 1.3의 8단계):
   - ① `OrderPaymentReader.getPayableOrder(orderId, userId)` — 타인/미존재 404, 이벤트 완결성 사전검증 불가 409(PG 호출 전).
   - ② 멱등/충돌 1차: paid면 기존 결제 결과 멱등 반환(200) / pending 아니면 409.
   - ③ 금액 검증: cmd.amount 전달 시 finalAmount 불일치 → 400.
   - ④ **ready row 선점**: `payments` INSERT(uq_payments_order_id 직렬화). 충돌 → 재조회 후 paid 멱등(200)/ready 409(in-progress).
   - ⑤ `PaymentGatewayPort.authorize(..., idempotencyKey)` — 선점 성공 1건만 도달, 모의 항상 승인(pgTransactionId).
   - ⑥ ready→paid 전이(`markPaid`, amount=finalAmount).
   - ⑦ `OrderConfirmation.confirmPaid(orderId, userId, finalAmount)` — orders row 비관락 + 권위 재검증 + markPaid + `OrderCompletedEvent` 발행(같은 트랜잭션 Outbox).
   - ⑧ 커밋(payments paid + orders paid + event_publication 1행 원자, 실패 시 ready 포함 전체 롤백).
5. ServiceResponse → `PaymentResponse`(200). ownerId/Entity 미노출.

### 3.2 결제 승인 — View (POST /orders/{orderId}/payment)
1. Security View 체인 `/orders/*/payment` hasRole(CONSUMER). 비인증 → 302/login.
2. ViewController.pay(orderId, OrderPaymentForm, auth, RedirectAttributes).
3. `CurrentActorResolver.resolve(auth).email()` → **`OrderPaymentForm → PaymentRequest` 변환(web 계층, #1)** → `PaymentFacade.pay(email, orderId, paymentRequest)`.
4. `PaymentFacadeImpl`: `MemberDirectory.findUserIdByEmail(email)` + `PaymentRequest → PaymentCommand` 변환 → `PaymentService.pay(userId, orderId, command)`(3.1의 4단계 동일 도메인 로직).
5. 성공 → `flashSuccess` + `redirect:/orders/{orderId}`(PRG). 실패(400/409) → `flashError` + `redirect:/orders/{orderId}`.

### 3.3 결제 상태 조회 — REST (GET /api/v1/orders/{orderId}/payment) / View (주문 상세)
1. (REST) auth→userId / (View) auth→email→userId(facade).
2. `PaymentService.getPaymentStatus(userId, orderId)`: **`OrderPaymentReader.getOrderSnapshot`(상태 조회 전용 — 이벤트 완결성 검증 없음, #3)**로 소유권 검증(타인 404) + `PaymentRepository.findByOrderId` 결제 status 조립. **productId/연락처 해석 실패가 상태 조회·주문 상세 렌더링을 깨뜨리지 않는다.**
3. (REST) `PaymentResponse`/status 200 / (View) 모델 `payment`(PaymentStatusView) → order/detail 결제 영역 렌더.

### 3.4 OrderCompletedEvent 발행 경로 (Outbox, 004 메커니즘)
- `OrderConfirmationImpl`이 `ApplicationEventPublisher.publishEvent(orderCompletedEvent)`를 payment 트랜잭션 안에서 호출.
- Spring Modulith Event Publication Registry가 같은 트랜잭션에 `event_publication` INCOMPLETE 저장(Transactional Outbox).
- 커밋 후 `spring-modulith-events-kafka` 어댑터가 `@Externalized("order-completed")`로 Kafka 발행(JsonSerializer) → COMPLETED 마킹. 외부화 실패 시 INCOMPLETE 유지(재시도 대상).
- 페이로드는 자족적(memberEmail/memberName/items[].productId/totalAmount/currency) — notification이 shop-core 역조회 불필요.

### 3.5 principal 이중경로 통일 지점
- REST: `PaymentServiceResponse`에서 `(long)auth.getPrincipal()` 통일. View: `PaymentFacadeImpl`에서 `MemberDirectory.findUserIdByEmail(email)` 통일. 이후 `PaymentService`는 userId만 다룬다(소유권·결제 단일 기준).

---

## 4. 예외 처리 전략 (error-response-rule 준수)

| 상황 | 발생 지점 | 예외 | REST 매핑 | View 매핑 |
|---|---|---|---|---|
| 미인증 REST | Security REST 체인 | — | 401 JSON(RestAuthenticationEntryPoint) | — |
| 미인증 View | Security View 체인 | — | — | 302 → /login |
| 권한 부족(ROLE 없는 인증) | Security | — | 403 JSON(RestAccessDeniedHandler) | 403 |
| 타인/미존재 주문 결제·조회 | OrderPaymentReader 소유권 | OrderNotFoundException(404) | **404 존재 은닉**(403 아님) | error 뷰(404) |
| productId/연락처 해석 불가(PG 호출 전, P2) | OrderPaymentReader.getPayableOrder 사전검증(결제 경로만 — 상태 조회는 해당 없음, #3) | PaymentEventResolutionException(409) | **409** + payments/이벤트 미생성 | flashError → /orders/{id} |
| 동시 결제 ready 선점 경합(#2) | payments INSERT uq 위반 후 재조회 ready | PaymentInProgressException(409) | **409**(결제 처리 중) | flashError → /orders/{id} |
| 비정상 상태 전이(pending/paid 외) | 멱등/충돌 판정② / confirmPaid 락 후 | OrderConfirmationConflictException(409) | **409** + 전체 롤백 | flashError → /orders/{id} |
| 클라이언트 금액 ≠ finalAmount | 금액 검증③ | PaymentAmountMismatchException(400) | **400** ErrorResponse | flashError → /orders/{id} |
| 이미 paid 재요청(멱등) | 판정②/confirmPaid 락 후 | — (예외 아님) | **200** 기존 결제 결과, 재발행 없음 | 결제 완료 상태 표시 |
| 금액 long 변환 위반(P3, .00 아님/범위 초과) | OrderConfirmation 변환 | AmountConversionException(500) | **500** + 전체 롤백 | 500/error 뷰 |
| 인증 세션-디렉터리 불일치 | MemberDirectoryImpl(기존) | IllegalStateException | 500 | 500 |
| 시스템 오류(저장/PG/발행) | 트랜잭션 내 임의 단계 | RuntimeException | 500 + **전체 롤백**(payments/주문/이벤트 부분반영 없음) | 500/error 뷰 |

핵심 규칙:
- **상태 충돌(비정상 상태·해석 불가) = 409**, **입력 금액 불일치 = 400**, **타인/미존재 = 404 존재 은닉**, **변환/시스템 불변식 위반 = 500**(error-response-rule). 거절(declined)은 016 범위 밖 — 017에서 402 등 채택.
- `longValueExact` 위반은 **사용자 입력 오류가 아니라 시스템 불변식 위반** → 400이 아니라 AmountConversionException(500). `ArithmeticException` catch → BusinessException 변환(error-response-rule 금지: 스택트레이스/내부 메시지 비노출).
- 멱등 재요청은 예외가 아니라 200 정상 응답(기존 결과). REST 정상/에러 본문 혼용 금지.
- 응답/모델에 ownerId(userId)·Entity·스택트레이스·SQL·내부 PG 원문·로컬 경로 미노출.
- 신규 예외 5종(PaymentAmountMismatch 400, OrderConfirmationConflict 409, PaymentEventResolution 409, PaymentInProgress 409, AmountConversion 500)만 추가, `OrderNotFoundException`(404) 재사용.
- **상태 조회 경로(getPaymentStatus / 주문 상세 렌더링)는 404(소유권) 외 도메인 예외를 내지 않는다(#3)** — 이벤트 완결성 409는 결제(pay) 경로 전용.

---

## 5. 검증 방법 (테스트 클래스 매핑 + 자동/수동 + Acceptance 매핑)

> 테스트 프로파일 제약(1.1): 기본 `application.yml`이 DataSource·HibernateJpa·DataSourceTransactionManager·Kafka·Flyway·외부화 자동설정 제외 → 기본 컨텍스트는 JPA/실 DB/Outbox 동작 불가. **Outbox 저장·동시성 비관락은 Testcontainers 별도 프로파일**(015 패턴: `@AutoConfigureTestDatabase(NONE)`+`@Testcontainers`+`@TestPropertySource`(exclude 리셋+flyway+ddl validate), 외부화는 `enabled=false`로 두고 `event_publication` 행 저장만 검증 — 실 Kafka 불요). Service/REST/View 로직은 Mockito·@MockitoBean.

### 단위(자동) — PaymentServiceTest (Mockito)
- 모의 PG 승인 시 8단계 순서: getPayableOrder → (멱등 판정) → 금액검증 → **ready row 선점(INSERT)** → authorize → ready→paid → confirmPaid 호출. 각 mock 상호작용 verify, **authorize가 ready 선점 이후에 호출됨**을 InOrder로 단언(#2).
- 이미 paid 주문 재요청 → 멱등 반환(ready INSERT·authorize·confirmPaid 미호출 또는 confirmPaid 멱등 분기 eventPublished=false). 더블결제·이벤트 재발행 없음.
- ready 선점 경합(PaymentRepository가 DataIntegrityViolation 후 재조회 ready) → PaymentInProgressException(409). authorize 미호출.
- pending 아닌(비정상) 주문 → OrderConfirmationConflictException(409). authorize/payments 미기록.
- 타인 주문 → OrderPaymentReader가 OrderNotFoundException(404) → ready INSERT·authorize 미호출.
- 클라이언트 금액 불일치 → PaymentAmountMismatchException(400). ready INSERT·authorize 미호출.
- productId/연락처 해석 불가 → PaymentEventResolutionException(409, PG 호출 전 — authorize 미호출, payments/이벤트 미생성).
- payments.amount = finalAmount(서버 권위, 클라이언트 금액 미반영) 단언.

### 단위(자동) — OrderPaymentReaderImplTest / OrderConfirmationImplTest / MockPaymentGatewayTest
- OrderPaymentReader.getPayableOrder(결제 전용): 자기 주문 OrderPaymentView(scalar) 반환·타인 404 존재 은닉·productId 해석 불가 시 409·연락처 해석 불가 시 409·Entity 미노출.
- OrderPaymentReader.getOrderSnapshot(상태 조회 전용, #3): 자기 주문 OrderSnapshotView 반환·타인 404·**productId/연락처 해석 불가 주문이어도 409를 던지지 않고 정상 스냅샷 반환**(상태 조회가 payload 구성 실패로 깨지지 않음).
- OrderConfirmation: pending→paid 전이·금액 불일치 409·이미 paid 멱등(eventPublished=false, 재발행 없음)·기타 상태 409·**OrderCompletedEvent 페이로드 전 필드 매핑 단언(ArgumentCaptor)**: 공통 봉투 `eventId`(non-null UUID)·`occurredAt`(non-null) + `orderId`·`orderNumber`·`memberId`·`memberEmail`·`memberName`·`totalAmount`(long)·`currency`("KRW")·`orderedAt` + `items[]`의 `productId`·**`productName`·`quantity`·`unitPrice`**. **`productName`/`quantity`/`unitPrice`는 `order_items` 주문 시점 스냅샷에서 온다는 것을 명시 검증**(현재 product name/price가 바뀌어도 이벤트는 스냅샷 값) · `productId`는 `product.spi` 해석값 · publishEvent 정확히 1회 · 금액 longValueExact 성공(.00) / 소수부 있으면 AmountConversionException(P3).
- Order.markPaid: pending에서만 허용, 그 외 도메인 예외.
- MockPaymentGateway: 항상 approved·pgTransactionId 비어있지 않음·동일 입력 결정적 결과(무작위 아님 — 017 거절 결정성 사전 보장).

### 단위(자동) — PaymentServiceResponseTest / PaymentFacadeImplTest / MemberDirectoryImplTest
- ServiceResponse: (long)auth.getPrincipal() 추출·PaymentService 위임·PaymentResponse 변환·멱등 200·ownerId/Entity 미노출.
- FacadeImpl: MemberDirectory.findUserIdByEmail 위임·DTO 변환.
- MemberDirectory: findContactByUserId scalar(email/name) 반환·Entity 미노출.

### REST/Security(자동) — PaymentRestControllerSecurityTest (@SpringBootTest, MockMvc, @MockitoBean PaymentServiceResponse)
- `POST /api/v1/orders/{id}/payment`: CONSUMER 200, 비인증 401, ROLE 없는 인증 403, SELLER/ADMIN 200(RoleHierarchy).
- `POST` 금액 불일치 400 / 비정상 상태 409 / productId 해석 불가 409 / 타인 404.
- `POST` ready 선점 경합 409(in-progress) — 동시성 통합과 별개로 단위/슬라이스에서 PaymentInProgressException 매핑 확인.
- `GET /api/v1/orders/{id}/payment`: 자기 결제 상태 200, 타인 404. **productId/연락처 해석 불가 주문이어도 상태 조회 200(getOrderSnapshot 경로 — 409로 깨지지 않음, #3).**
- 응답 본문에 ownerId, member/order/product/variant Entity, 로컬 절대경로 미포함(jsonPath doesNotExist).

### 통합 — Outbox·동시성 (Testcontainers PostgreSQL, 자동, 별도 프로파일)
- `PaymentOutboxIntegrationTest`: 승인 결제 커밋 시 `event_publication`에 OrderCompletedEvent 1건 저장 + **payload 전 필수 필드 만족**(`eventId`·`occurredAt`·`orderId`·`orderNumber`·`memberId`·`memberEmail`·`memberName`·`items[].productId`·**`items[].productName`·`items[].quantity`·`items[].unitPrice`**·`totalAmount`·`currency`·`orderedAt`). **`productName`/`quantity`/`unitPrice`가 `order_items` 스냅샷 값과 일치**함을 단언(주문 후 product 변경 무영향). 직렬화된 payload(JSON)에서 필드 존재·값 검증. 시스템 오류(강제 예외) 트랜잭션은 payments·주문 status·event_publication·**ready row** 모두 롤백(부분 반영 없음).
- `PaymentConcurrencyIntegrationTest`: 동일 주문 동시 결제 2건(스레드 2개) → **1건만 paid 확정·`payments` row 1건 유지(ready 선점 uq)·PG authorize 1회·OrderCompletedEvent 1건만 저장**. 나머지는 멱등(200, paid) 또는 409(in-progress). ready 선점이 PG 호출 전 직렬화함을 실 DB로 검증(#2).
- 외부화 enabled=false(Outbox 저장만 검증, 실 Kafka 라운드트립은 004 트레이드오프대로 범위 밖).

### View(자동) — PaymentViewRenderingTest / PaymentViewControllerTest (@MockitoBean PaymentFacade/OrderFacade)
- pending 주문 상세에 결제 폼(CSRF 히든) 렌더 + 결제 상태 `결제 대기` 표시.
- 결제 성공 → redirect `/orders/{id}` + flashSuccess.
- paid 주문 → 결제 폼 미노출 + `결제 완료` 상태 표시.
- 비인증 `POST /orders/{id}/payment` → 302 /login.

### 구조(자동) — PaymentModuleStructureTest / WebModuleStructureTest / OrderModuleStructureTest / ModularityTests
- payment가 order/member/product 내부(domain/repository/service) 미참조 — order.spi(OrderPaymentReader/OrderConfirmation)·member.spi·published API만.
- OrderCompletedEvent가 order 모듈(`com.shop.shop.order..`)에 위치.
- web.payment/web.order가 도메인 내부 미참조(기존 WebModuleStructureTest, payment 이미 포함 — 변경 불요).
- ModularityTests.verify() 통과(신규 payment.spi/order.spi 2포트 경계 포함).

### 실행 / 수동 확인
- `./gradlew test` 전체 통과(통합 Testcontainers 자동).
- (보조 수동) docker-compose 기동 후 실제 결제 1건 → payments paid·orders paid·Kafka order-completed 메시지 1건·재결제 멱등 확인. 확인/미확인 항목을 작업 완료 보고에 남긴다(013/014/015 정책 동일).

### Acceptance Criteria 매핑 표

| Acceptance | 검증 수단 |
|---|---|
| 비인증 401 / ROLE 없는 인증 403 | PaymentRestControllerSecurityTest |
| CONSUMER/SELLER/ADMIN 자기 주문 결제 가능 | PaymentRestControllerSecurityTest(RoleHierarchy) |
| 타인 주문 결제·조회 404 존재 은닉 | PaymentServiceTest·OrderPaymentReaderImplTest·SecurityTest |
| 승인 시 payments paid(금액=finalAmount/pgTxId/paidAt) | PaymentServiceTest·PaymentOutboxIntegrationTest |
| 승인 시 주문 pending→paid | OrderConfirmationImplTest·PaymentOutboxIntegrationTest |
| 승인 시 OrderCompletedEvent Outbox 저장 + 스키마 | PaymentOutboxIntegrationTest·OrderConfirmationImplTest |
| 이미 paid 재요청 멱등(무발행) | PaymentServiceTest·OrderConfirmationImplTest |
| 동시 결제 1건 확정·payments 1행 | PaymentConcurrencyIntegrationTest |
| 금액 불일치 400 | PaymentServiceTest·SecurityTest |
| productId 해석 불가 PG 호출 전 409·미생성 (P2) | PaymentServiceTest·OrderPaymentReaderImplTest·SecurityTest |
| payment가 order.spi만 사용·order 내부 미참조 (P1) | PaymentModuleStructureTest |
| 주문 row 락이 confirmPaid(order)에서만 (P1) | OrderConfirmationImplTest·PaymentConcurrencyIntegrationTest·코드 리뷰 |
| 금액 longValueExact·소수부 0 아니면 도메인 예외 (P3) | OrderConfirmationImplTest |
| 시스템 오류 부분 반영 없음 | PaymentOutboxIntegrationTest(롤백) |
| 자기 주문 결제 상태 조회 | PaymentServiceTest·GET SecurityTest·View 렌더 |
| 주문 상세 결제 폼(CSRF)·성공 redirect·완료 표시 | PaymentViewRenderingTest |
| SecurityConfig 결제 경로 명시 권한 | 코드 리뷰·SecurityTest |
| payment published API/scalar만 사용 | PaymentModuleStructureTest |
| OrderCompletedEvent를 order가 발행 | OrderConfirmationImplTest·PaymentModuleStructureTest |
| event-catalog/architecture 섹션5 무변경 | 문서 diff 확인 |
| ModularityTests 통과 | ModularityTests |

---

## 6. 트레이드오프

- **payment가 처리 오케스트레이션, order가 확정·발행 소유(P1) vs payment가 전부 처리**: 포트 2개(`OrderPaymentReader`/`OrderConfirmation`)와 order 내부 구현이 늘지만, 발행 소유권을 order에 고정해 "결제만 승인되고 미확정·미발행"을 모듈 경계·트랜잭션 경계 양쪽에서 차단한다. payment↛order.domain은 구조 테스트로 강제.
- **이벤트 완결성 PG 호출 전 사전검증(P2) vs 확정 단계에서 해석**: 1단계에 productId/연락처 해석 비용을 앞당기지만(확정 시 다시 한 번 읽어 미세 중복), "승인 후 productId 누락으로 확정 실패"라는 실 PG 전환 시의 치명 결함을 원천 차단한다. fallback(임의 productId) 금지로 데이터 무결성 우선.
- **준비 스냅샷(락 없음) + 확정 락 후 권위 재검증 이중 판정**: 멱등/충돌 판정을 두 번(빠른 경로 + 권위 경로) 하지만, 락 없는 준비 스냅샷은 race가 가능하므로 권위 판정은 confirmPaid 비관락 후 재검증이 책임진다. 정확성(직렬화) 우선.
- **PG 호출 전 직렬화: ready row uq 선점 vs 주문 row 락 선취(#2)**: "PG 전에 orders row를 락"하면 외부 I/O를 락 구간 안에 넣게 되어(실 PG 지연 동안 락 보유) 처리량·데드락 표면이 나빠진다. 대신 **`payments` ready row INSERT + `uq_payments_order_id`로 PG 호출 전 직렬화**해, 락을 길게 잡지 않고도 동시 2건 중 1건만 PG에 도달하게 한다. orders row 비관락은 PG 이후(7단계)에 짧게 잡아 주문 상태 전이만 권위 직렬화한다. 자원 획득 순서(payments→orders) 일관으로 데드락 없음. 실 PG 전환 시 idempotencyKey로 프로세스 재시도까지 보강. 비용: ready row 선점 로직·in-progress(409) 한 갈래 추가 — "동시 더블 charge 차단"을 위해 수용.
- **orders row 비관적 락(FOR UPDATE) vs 조건부 UPDATE/낙관락**: 015의 재고 락과 동일 철학(주문/결제 흐름은 "잠근 상태를 읽고 status/금액 순차 검증"의 명시성 선호). 비용은 락 보유 구간 — PG 호출을 락 밖(ready 선점으로 단일화)에 두고 락 구간 내 외부 I/O 금지로 완화.
- **상태 조회 reader 분리 vs 단일 reader 재사용(#3)**: `getPayableOrder`(완결성 409)와 `getOrderSnapshot`(소유권만) 두 메서드로 분리해 메서드가 하나 늘지만, 결제 상태 조회·주문 상세 렌더링이 이벤트 payload 구성 실패(productId/연락처 해석 불가)로 깨지는 것을 막는다. 조회 가용성 > 코드 최소화.
- **facade가 payment DTO만 수신(web 타입 차단, #1)**: web 핸들러에 `OrderPaymentForm→PaymentRequest` 변환 한 줄이 늘지만, `web→domain.spi` 단방향 의존을 지켜 spi가 web을 역참조하지 않게 한다(구조 규칙 위반 방지).
- **금액 BigDecimal 저장 + 발행 시 longValueExact 변환(P3)**: 저장 정밀도(numeric 12,2)와 계약 타입(long KRW)을 분리. 소수부 0만 허용·위반 시 500(시스템 불변식)으로 명확히 실패해 잘못된 long 반올림 발행을 막는다(데이터 정확성 > 관대한 처리).
- **PaymentGatewayPort 승인/거절 시그니처를 016에서 확정(모의는 항상 승인)**: 016에서 거절 필드(failureCode/failureReason)를 안 쓰지만 미리 포함해 017에서 포트/DTO를 바꾸지 않는다(인터페이스 안정성 > 016 최소주의). ObjectStorage 추상화 철학과 동일.
- **신규 migration 없음(payments V1 재사용, failureCode 컬럼 미보유)**: 016은 status ready/paid·amount·pgTransactionId·paidAt만 사용해 V1로 충분. 017 거절 사유 영속은 옵션 A(미영속)로 migration 회피 가능 — 016에서 결정 강제하지 않음.
- **SecurityConfig 전용 matcher 추가(기존 /orders/** 가 이미 덮음)**: 동작 변화는 없지만 Acceptance "명시적으로 적용"을 코드로 드러내고 결제 경로 권한 회귀를 가독성으로 방어. 약간의 중복 matcher 비용 수용.
- **Outbox 통합은 event_publication 저장만 검증(실 Kafka 라운드트립 제외)**: 테스트 프로파일이 Kafka 자동설정을 exclude하므로(004 트레이드오프) 실 브로커 외부화는 검증 범위 밖. Outbox 원자성·payload 스키마는 Testcontainers로 자동 검증하고 실 Kafka E2E는 별도 통합 Task/E2E로 미룬다.
- **거절/환불/취소/배송/실PG/쿠폰/재고복원 미구현**: Task Constraint 준수. 016은 승인 happy path + paid 전이 + OrderCompletedEvent까지만. 거절·PaymentFailedEvent는 017.

# 033 Plan — 취소 vs 결제 동시성 정합성 버그 해소(락 후 refresh) + 취소 SPI refundInfo 불변식 강화

> Task: docs/tasks/backend/033-backend-shop-core-cancel-vs-pay-concurrency-flake-and-refundinfo-invariant.md
> 확정 방향(사용자, 2026-06-15): 1-A(락 후 refresh/재판정) + 2-D(production 경로 + 정합성 단정) + 3-F(doCancel 가드). 대안(1-B/1-C/2-E/3-G)은 미채택.

## 구현 목표
결제 확정(confirmPaid)이 PESSIMISTIC_WRITE 락을 잡은 직후 영속성 컨텍스트의 stale Order(pending)를 refresh 없이 사용해 이미 커밋된 취소를 paid로 덮어쓰는 직렬화 구멍을, 락 후 EntityManager.refresh로 메우고(주 수정), 정합 불변식을 결정적으로 검증하도록 동시성 테스트 단정을 정합성 기반으로 교체하며(테스트), doCancel에 refundInfo 모순 방어 가드를 추가한다(부차).

## 영향 범위
- 신규 파일: 없음
- 수정 파일 (모두 shop-core 레포):
  - (주, production) shop-core/src/main/java/com/shop/shop/order/service/OrderConfirmationImpl.java — confirmPaid에 EntityManager.refresh(order) 추가 + 필드 주입
  - (부차, production) shop-core/src/main/java/com/shop/shop/order/service/OrderCancellationImpl.java — doCancel에 refundInfo<->status 모순 방어 가드(예외)
  - (테스트) shop-core/src/test/java/com/shop/shop/order/service/OrderCancellationConcurrencyIntegrationTest.java — cancelVsPay_*를 정합성 단정으로 교체 + doCancel 가드 케이스 추가
- 무변경(검토만): OrderPaymentReaderImpl.java(getPayableOrder — pre-load 원인 제공이나 1-A 채택으로 로직 불변, 주석 보강만), PaymentService.java(pay/cancel/expirePendingOrder — 로직 불변), OrderRepository.java, Order.java(상태전이 규칙 불변), 이벤트/notification/마이그레이션 전부.

## 1. 설계 방식 및 이유

### 1.1 근본 원인 (코드 + 실측 대조 — 확인 완료)
- PaymentService.pay(@Transactional)는 (1) orderPaymentReader.getPayableOrder -> OrderRepository.findWithItemsOnlyByIdAndUserId(JPQL fetch)로 managed Order(pending)를 pay 트랜잭션의 영속성 컨텍스트에 적재한다(OrderPaymentReaderImpl.getPayableOrder는 @Transactional(readOnly=true)지만 pay의 진행 중 물리 트랜잭션/영속성 컨텍스트에 조인).
- 이후 (3) OrderConfirmation.confirmPaid -> OrderRepository.findByIdForUpdate(@Lock(PESSIMISTIC_WRITE))가 SELECT ... FOR UPDATE로 락은 잡지만, JPQL 결과의 엔티티 식별자가 이미 1차 캐시에 있으므로 Hibernate는 DB row의 새 값을 버리고 캐시에 있던 동일 인스턴스를 그대로 반환한다(JPQL 결과는 managed 엔티티 상태를 덮어쓰지 않음 — Hibernate repeatable-read 동작). 즉 findByIdForUpdate가 반환한 order.getStatus()는 stale pending.
- 취소 스레드가 먼저 pending -> cancelled(+재고 복원 +OrderCancelledEvent)를 커밋해도, 결제 스레드의 confirmPaid는 락 획득 후 stale pending을 보고 status 분기를 통과해 markPaid()(pending->paid)를 호출 -> 취소를 paid로 덮어쓴다. 최종 order=paid, payment=paid, stock=11(과복원), 결제·취소 둘 다 성공. (실측 7/12)
- 정리: PESSIMISTIC_WRITE로 직렬화는 일어나지만(락 대기), 락 획득 후 stale 캐시 엔티티로 상태 판정을 하므로 직렬화의 의미가 무력화된다. 부족한 것은 새 락이 아니라 락 후 fresh read다.

### 1.2 채택 설계 — 1-A: 락 직후 refresh로 재판정
confirmPaid에서 findByIdForUpdate로 락을 잡은 직후 EntityManager.refresh(order)를 호출한다. 잠긴 DB row의 최신 commit 상태를 영속성 컨텍스트에 다시 적재한다(취소가 먼저 커밋했다면 order.getStatus()가 cancelled로 갱신됨). 이후 기존 status 분기가 fresh 상태로 동작한다:
- 취소가 먼저 커밋 -> currentStatus == cancelled -> !pending 분기 -> Outcome.REJECTED 반환 -> PaymentService.pay가 OrderConfirmationConflictException(409)으로 되던져 pay 트랜잭션 전체 롤백(payments paid 전이/이벤트/markPaid 모두 무효) -> 덮어쓰기 차단. 최종 단일 정합: order=cancelled, stock 복원 1회, payment 없음.
- 결제가 먼저 커밋 -> 취소 스레드는 자기 경로(getOrderForCancel의 findByIdForUpdate가 곧 첫 읽기 = fresh)에서 paid를 보고 환불 경로로 가거나 raw SPI/가드 경로에서 거부된다. 최종 단일 정합: order=paid, stock 미복원, payment=paid.

왜 refresh 위치가 "락 획득 직후, status 분기 이전"인가: 락(SELECT ... FOR UPDATE)이 걸린 뒤 refresh해야 경쟁 트랜잭션이 이미 커밋을 끝낸 상태를 읽도록 보장된다(락 획득 전 refresh는 다시 race). 락 -> refresh -> 판정 순서가 직렬화 정확성의 핵심이다.

### 1.3 멱등(paid) / 금액 불일치(REJECTED) 분기 보존 논증
refresh는 DB 최신값으로 status/finalAmount를 정확화할 뿐 분기 로직을 바꾸지 않는다.
- 멱등(이미 paid): 중복 결제 확정 시 refresh 후 currentStatus == paid -> 기존 ALREADY_CONFIRMED 분기 그대로(refresh 전 stale로 paid를 못 보던 위험을 오히려 더 정확히 잡음 — 회귀 아닌 강화).
- 비-pending REJECTED: refresh 후에도 pending 외(cancelled/refunded/이행단계)면 동일하게 REJECTED 반환. 본 버그 수정의 핵심 경로.
- 금액 불일치 REJECTED: refresh는 finalAmount도 DB 최신값으로 맞추지만 주문 확정 흐름에서 finalAmount는 불변이므로 비교 결과 동일. 기존 REJECTED 분기 보존.
- 정상(pending) CONFIRMED: 경쟁 없는 정상 결제는 refresh 후에도 pending -> markPaid -> CONFIRMED. 정상 경로 결과 불변.

### 1.4 confirmPaid 외 경로의 stale 취약점 점검 (결론)
- OrderCancellationImpl.cancel / cancelByExpiry: 각 진입점의 첫 DB 읽기가 곧 findByIdForUpdate(락 읽기)이고, 그 트랜잭션(PaymentService.cancel/expirePendingOrder 경유)은 사전에 동일 Order를 managed로 적재하지 않는다(getOrderForCancel/getOrderForExpiry도 첫 읽기가 findByIdForUpdate임). -> 동일 stale 취약점 없음 -> 무변경.
- OrderFulfillmentService(배송 이행): order 적재 전 락 읽기가 첫 읽기 -> 동일 취약점 없음 -> 무변경.
- 결론: stale read 결함은 pay -> getPayableOrder pre-load -> confirmPaid 조합에만 존재. 1-A는 confirmPaid 한 곳만 고친다.

### 1.5 부차 가드 (3-F) 설계
OrderCancellationImpl.doCancel은 호출자가 넘긴 refundInfo를 검증 없이 신뢰한다(현 유일 production 호출자 PaymentService.cancel은 항상 락 아래 올바른 refundInfo 도출 -> 정상 흐름 무영향). defense-in-depth로 락 재조회 상태(lockedOrder.getStatus())와 refundInfo의 모순을 종결 전이 직전에 검사해 모순이면 예외로 종결 거부한다:
- paid인데 refundInfo.refunded() == false -> 결제완료 주문을 환불 없이 cancelled 처리 시도(stale/오호출) -> 예외.
- refundInfo.refunded() == true인데 상태가 paid가 아님(예: pending) -> 미결제 주문에 환불 표기 -> 예외.
- 가드를 통과하면 기존 전이(refunded->markRefunded, 미환불->markCancelled)가 그대로 수행. Order.markCancelled/markRefunded의 도메인 가드는 여전히 2차 방어선으로 보존 — 가드는 그 전에 더 명확한 의미의 예외로 거른다.

왜 REJECTED 반환이 아니라 예외인가: PaymentService.cancel line 267~269는 OrderCancellation.cancel이 Outcome.REJECTED를 반환하면 "락 불변식 위반(#3)"으로 IllegalStateException(500)을 던진다. refundInfo 모순을 REJECTED로 표현하면 그 의미와 충돌(원인 구분 불가)하므로 예외 throw로 통일해 의미를 명확히 하고 트랜잭션을 롤백한다(Task 3-F 권장 그대로).

## 2. 구성 요소 (수정 클래스/메서드/파일)

### 2.1 OrderConfirmationImpl.confirmPaid (주 수정)
- jakarta.persistence.EntityManager 필드 주입. @RequiredArgsConstructor 유지 위해 final 미부여(Lombok 생성자 제외).
  - **구현 편차(확정)**: 실제 구현은 `@PersistenceContext` 대신 **`@Autowired @Lazy private EntityManager entityManager;`** 를 사용한다. 사유 — 이 코드베이스의 JPA 슬라이스 테스트 컨텍스트(`test/resources/application.yml`이 `HibernateJpaAutoConfiguration` 제외)에서 `@PersistenceContext`가 컨텍스트 로드 단계에 EM 빈을 요구해 일부 단위/슬라이스 테스트가 깨진다. `@Autowired @Lazy`는 동일한 Spring **shared(트랜잭션 인식) EntityManager 프록시**에 위임하되 해소를 첫 호출 시점으로 지연시켜, production·통합 테스트에서는 confirmPaid의 활성 트랜잭션 영속성 컨텍스트로 refresh가 정상 라우팅되고(stale 재적재 의도 보존), JPA 미적재 슬라이스 컨텍스트는 로드된다. 동작 동일·의도 무훼손(reviewer 확인). 통합테스트 `cancelFirst_thenPay_shouldBeRejected`가 실 DB로 refresh 동작을 검증.
- 변경 지점: line 60 findByIdForUpdate(...).orElseThrow(...) 직후, 소유권 검증 이전(락 직후 즉시 refresh — 소유권/상태 판정 모두 fresh 기반):
  - Order order = orderRepository.findByIdForUpdate(orderId).orElseThrow(OrderNotFoundException::new);
  - entityManager.refresh(order); // 락 후 DB 최신 상태 재적재 — stale pending 덮어쓰기 차단 (033)
- 이후 소유권/status/금액 분기는 코드 무변경(fresh 값으로 동작). 멱등/REJECTED/CONFIRMED 분기 보존.
- 주석: 왜 refresh가 필요한지(getPayableOrder pre-load로 인한 stale, 락 후 fresh 재판정) 명시.

### 2.2 OrderCancellationImpl.doCancel (부차 가드)
- 위치: line 150 Instant cancelledAt = ... 직전(이미 ALREADY/REJECTED 분기를 통과해 pending/paid만 남은 지점) — 종결 전이(line 152~157) 직전.
- 로직:
  - boolean isPaid = "paid".equals(currentStatus);
  - if (isPaid && !refundInfo.refunded()) { throw new IllegalStateException(...); }
  - if (!isPaid && refundInfo.refunded()) { throw new IllegalStateException(...); }
  - (금액 모순 검사 — refunded=true인데 refundedAmount<=0 등 — 는 가산 옵션. 본 plan은 상태<->refunded 플래그 모순만 1차로 강제. 과도한 설계 방지.)
- Javadoc: doCancel/OrderCancellation.cancel에 "호출자는 락 재조회 상태와 정합하는 refundInfo를 전달해야 한다. 모순 시 IllegalStateException으로 종결 거부" 계약 추가.
- 예외 종류: IllegalStateException(시스템 불변식 위반 — 기존 PaymentService.cancel line 267 락 불변식 위반과 동일 계열, error-response에서 500 매핑). 트랜잭션 롤백.

### 2.3 테스트 (OrderCancellationConcurrencyIntegrationTest)
- cancelVsPay_serialized_onlyOneSucceeds 교체(정합성 단정).
- 신규: doCancel/OrderCancellation.cancel 가드 케이스(paid + RefundInfo(false,0) -> 예외).
- confirmPaid 직렬화(취소 먼저 커밋 후 결제 -> REJECTED) 케이스(아래 5절).
- 동시 취소 2건 케이스(line 101~166)는 무변경 유지(이미 안정).

## 3. 데이터 흐름 (락+refresh 후 단일 정합 수렴 시퀀스)

### 분기 A — 취소 먼저 커밋
1. cancel 스레드: PaymentService.cancel -> getOrderForCancel(findByIdForUpdate = 첫 읽기, fresh pending) -> status=pending -> OrderCancellation.cancel -> markCancelled(pending->cancelled) + 재고 +1 복원 + OrderCancelledEvent -> commit, 락 해제.
2. pay 스레드: getPayableOrder로 managed Order(pending) pre-load -> PG auth -> confirmPaid -> findByIdForUpdate(락 대기 -> 취소 commit 후 획득) -> entityManager.refresh(order) -> status == cancelled -> 비-pending 분기 -> Outcome.REJECTED -> PaymentService.pay가 OrderConfirmationConflictException(409) throw -> pay 트랜잭션 롤백(markPaid 미수행·payments paid 전이 롤백).
3. 최종(정합 1): order=cancelled, stock=11(복원 1회), payment 없음. 결제 스레드는 실패(409). successCount==1.

### 분기 B — 결제 먼저 커밋
1. pay 스레드: pre-load pending -> confirmPaid -> findByIdForUpdate(락 획득) -> refresh(여전히 pending, 경쟁 아직 미커밋) -> markPaid(pending->paid) + OrderCompletedEvent -> commit, 락 해제.
2. cancel 스레드: getOrderForCancel(findByIdForUpdate, 락 대기 -> 결제 commit 후 획득 = fresh paid) -> status=paid -> 환불 경로(PG refund + RefundInfo(true, amount)) -> OrderCancellation.cancel -> markRefunded(paid->refunded) + 재고 복원. (production cancel 경로는 환불을 동반하므로 정합.)
3. 최종(정합 2): order=paid(또는 환불까지 진행 시 refunded), stock은 결제 시점 미복원/환불 시 복원 — 단일 정합 조합, payment=paid/refunded.

핵심: 어느 스레드가 먼저 commit하든 나중 스레드는 락 획득 후 fresh 상태로 판정하므로 "paid인데 재고 과복원" 같은 혼합 상태가 발생하지 않는다. 단정은 카운트가 아니라 종착 상태(order/payment/stock)의 단일 정합 조합으로 검증한다(5절).

### 분기 C — raw SPI 직접 호출(가드 경로, 3-F)
paid 주문에 OrderCancellation.cancel(orderId, userId, RefundInfo(false, 0, "KRW")) 직접 호출 -> doCancel이 락 재조회로 paid 확인 -> refundInfo.refunded()==false 모순 -> IllegalStateException -> 롤백(종결 거부). production PaymentService.cancel 경유는 항상 정합 refundInfo 전달 -> 무영향.

## 4. 예외 처리 전략
- confirmPaid REJECTED 매핑(보존): refresh 후 비-pending -> Outcome.REJECTED 값 반환(기존). PaymentService.pay line 155~157이 OrderConfirmationConflictException(409, BusinessException)으로 변환 -> @RestControllerAdvice 409 JSON(error-response-rule "상태 충돌 -> 409"). 이 매핑 체인은 무변경. 1-A는 "REJECTED에 도달하는 조건"만 정확화(stale pending -> fresh cancelled).
- doCancel 가드 예외: IllegalStateException(시스템/락 불변식 위반 계열, error-response 500). pay/cancel 트랜잭션 안에서 던져져 전체 롤백(환불·재고·이벤트 부분 반영 없음). production 정상 흐름에서는 발생하지 않는 방어선.
- refresh 자체 예외: EntityManager.refresh는 entity가 managed일 때 정상 동작. 락 row가 존재(findByIdForUpdate 성공)하므로 detached/삭제 케이스 비해당. 동시 삭제 같은 비정상이면 EntityNotFoundException -> pay 트랜잭션 롤백(주문 삭제는 본 도메인에 없어 실질 미발생).
- error-response-rule 정합: 신규 응답 포맷/예외 타입 추가 없음. 기존 OrderConfirmationConflictException(409)·IllegalStateException(500) 재사용. View/REST 핸들러 변경 없음.

## 5. 검증 방법 (RED->GREEN 경험 + 회귀)

### 5.1 정합성 회귀 테스트 — RED 확인 절차 (verification-gate-rule "RED는 경험으로 확인")
1. 테스트 단정 교체 선반영(주 수정 1-A 적용 전): cancelVsPay_*에서 assertThat(successCount).isEqualTo(1)(line 240)과 느슨한 stock >= 10(line 250)을 정합성 단정으로 교체:
   - 최종 order.status를 조회해 다음 둘 중 정확히 하나임을 단정:
     - (1) cancelled AND stock==11(복원 1회) AND payments 없음/환불, 또는
     - (2) paid(또는 refunded) AND stock 정합(과복원 아님) AND payments.status in (paid, refunded).
   - "paid인데 stock==11(과복원)" 혼합 상태가 발생하지 않음을 명시 단정.
   - 타이밍 비의존(카운트 의존 제거). 결정성을 위해 N회 반복(@RepeatedTest 또는 루프) — 반복은 결정성 확인용이며 버그를 덮는 재시도가 아님.
2. 수정 1-A 미적용 상태에서 실행 -> RED 확인(실측 12회 중 7회 success=2/paid/stock=11 -> 정합성 단정 실패해야 함). 이 RED를 메인 에이전트가 실제 실행으로 확인(verification-gate 2절).
3. 수정 1-A 적용 후 동일 테스트 -> GREEN(N회 반복 통과). pay 스레드는 이미 production 경로(paymentServiceResponse.pay) 사용. cancel 스레드는 가능하면 production 경로(PaymentServiceResponse.cancel)로 호출(2-D). raw SPI 유지 시 cancel이 RefundInfo(false,0)를 넘기는 점이 production과 다름을 주석으로 명시.

주의(2-D vs 3-F 상호작용): cancel 스레드가 raw SPI로 RefundInfo(false,0)를 넘기는데 결제가 먼저 커밋해 상태가 paid가 되면 3-F 가드가 IllegalStateException을 던진다(정상 — 취소 실패, 결제 승). 이 경우도 "분기 B: order=paid, 취소 실패"의 단일 정합에 수렴하므로 정합성 단정과 모순되지 않는다. 테스트는 cancel 실패를 failCount로 흡수(기존 try/catch 구조 유지). production 경로(PaymentServiceResponse.cancel)로 cancel을 호출하도록 바꾸면 paid 경합 시 환불 경로로 정합 종결 — 2-D 권장.

### 5.2 confirmPaid 직렬화 단위/통합
- 통합(Testcontainers): 취소를 먼저 commit(별도 트랜잭션)한 뒤 confirmPaid(또는 PaymentService.pay) 호출 -> Outcome.REJECTED(또는 pay에서 OrderConfirmationConflictException) 단정. refresh가 없으면(수정 전) 이 단정이 RED여야 함.
- 단위(Mockito): findByIdForUpdate stale 재현이 어려우므로 통합 우선. 단위는 멱등(paid->ALREADY_CONFIRMED)/금액불일치(REJECTED) 분기 보존 회귀를 커버.

### 5.3 doCancel 가드 단위/통합
- paid 주문 + RefundInfo(false, 0, "KRW") 직접 호출 -> IllegalStateException + 롤백(상태/재고 무변경) 단정.
- 정상: paid + RefundInfo(true, amount, "KRW") -> 통과(markRefunded). pending + RefundInfo(false, 0) -> 통과(markCancelled). production 정상 흐름 회귀 0.

### 5.4 회귀 (verification-gate 2절 — 메인이 직접 전체 실행)
- 016/017(결제 승인/거절), 018(취소/환불), 022(만료), OrderCancellationExpiryTest, PaymentServiceCancelTest, 동시 취소 2건 케이스, 기타 동시성 테스트 그린 유지.
- confirmPaid 멱등/REJECTED 분기 회귀 없음(1.3절 논증을 테스트로 확인).
- 전체 ./gradlew test(shop-core) BUILD SUCCESSFUL을 메인 에이전트가 자기 눈으로 확인. RED->GREEN 경험과 baseline 대조(필요 시) 결과를 보고에 기록.
- 스키마 매핑 변경 없음(@Version 미도입) -> schema-mapping-validation 전용 테스트 불필요(단, 회귀로 깨지지 않는지 전체 그린으로 확인).

## 6. 트레이드오프 (채택/미채택 근거)

| 항목 | 채택 | 미채택 | 근거 |
|---|---|---|---|
| 주 수정 | 1-A 락 후 refresh | 1-B pre-load 제거 / 1-C @Version | 1-A는 최소 변경(refresh + 필드)으로 락 의미를 살림, 스키마 무변경. 1-B는 pay 흐름(getPayableOrder 이벤트 완결성 사전검증)을 재배선해 회귀면이 넓음. 1-C는 DB 스키마 변경 -> ADR-005 단순화/Task 제약 위반. |
| 테스트 | 2-D production 경로 + 정합성 단정 | 2-E raw SPI 유지 | 2-D가 production 정합성을 직접 검증(pay는 이미 production 경로). cancel은 production 경로 전환 권장하되 정합성 단정으로 결정성 확보. 카운트 단정 제거가 핵심. |
| 가드 표현 | 3-F 예외(IllegalStateException) | REJECTED 반환 / 3-G 문서화만 | REJECTED는 PaymentService.cancel의 "락 불변식 위반" 의미와 겹쳐 원인 혼동 -> 예외로 통일. 문서화만으론 향후 신규 호출자 방어 불가 -> 저비용 영구 가드(예외) 채택. |
| 가드 범위 | 상태<->refunded 플래그 모순 | + 금액 모순 강제 | 과도한 설계 방지. 상태<->플래그 모순이 본 계약 갭의 핵심. 금액 모순은 가산 옵션으로 남김. |

## Spring Boot 컨벤션
- 패키지: com.shop.shop.order.service(구현체 package-private 유지), com.shop.shop.common.exception(기존 예외 재사용).
- 어노테이션: @PersistenceContext(EntityManager 주입), 기존 @Service @Transactional @RequiredArgsConstructor 유지.
- 예외: 기존 OrderConfirmationConflictException(409)·IllegalStateException(500) 재사용. 신규 예외 없음.
- 락: 기존 findByIdForUpdate(PESSIMISTIC_WRITE) 유지 + 락 후 EntityManager.refresh(새 락/전략 도입 아님).

## 완료 조건
- [ ] confirmPaid가 락 직후 EntityManager.refresh(order)로 fresh 재판정한다(주석 포함). 멱등/REJECTED/CONFIRMED 분기 코드 무변경·보존.
- [ ] doCancel에 status<->refundInfo 모순 시 IllegalStateException 가드 + Javadoc 계약 추가. 정상 흐름 무영향.
- [ ] cancelVsPay_* 단정이 수정 1-A 적용 전 RED, 적용 후 GREEN(메인이 실제 실행으로 확인). 카운트 단정 제거, 종착 단일 정합 조합 단정.
- [ ] confirmPaid 직렬화(취소 먼저->REJECTED) + doCancel 가드(paid+RefundInfo(false,0)->예외) 테스트 추가·통과.
- [ ] 016/017/018/022·동시취소2건·기타 동시성·전체 ./gradlew test(shop-core) 그린(메인 직접 확인).
- [ ] DB 스키마/이벤트/notification/PG/환불액·상태전이 규칙 무변경. confirmPaid 외 경로(cancel/expiry/fulfillment) 무변경(첫 읽기=락 읽기로 stale 취약점 없음).

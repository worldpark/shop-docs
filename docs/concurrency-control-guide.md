# Concurrency Control Guide

> 목적: 다중 노드 배포 여부가 확정되지 않은 상태에서, 동시성 제어를 Task에 어떻게 기록하고 Redisson 분산락을 언제 별도 검토할지 판단한다.
> 적용 범위: `shop-core`의 재고·주문·결제·쿠폰·상품 이미지 등 동일 자원 중복 처리 위험이 있는 기능. `notification`은 Kafka 소비 멱등성과 DB unique 제약을 우선한다.

## 1. 현재 원칙

- 현 단계에서는 Redisson 분산락을 기본값으로 두지 않는다.
- 단일 DB 트랜잭션 안에서 해결 가능한 동시성은 DB 제약, 조건부 UPDATE, 비관적 락, 낙관적 락을 우선한다.
- 락은 최종 안전장치가 아니라 직렬화 수단이다. DB unique/check 제약, 상태 전이 조건, 재조회 검증 같은 권위 검증을 함께 둔다.
- 다중 노드 배포가 확정되거나 DB 트랜잭션 밖 임계구역을 보호해야 할 때 Redisson 또는 Redis 기반 분산락을 별도 Task로 승격한다.
- Task 문서에는 "분산락 적용"을 확정하기보다 "동시성 위험과 현재 방어선, 다중 노드 전환 시 조치"를 먼저 남긴다.

## 2. Task 작성 기준

### Redisson을 직접 언급하지 않는 경우

다음 조건이면 Task에는 Redisson을 필수 구현으로 쓰지 않는다.

- 하나의 PostgreSQL 트랜잭션 안에서 상태 변경이 끝난다.
- 같은 row 또는 unique/check 제약으로 최종 정합성을 보장할 수 있다.
- 동시성 실패가 도메인 예외로 명확히 변환된다.
- 외부 API 호출, 파일 저장, Kafka 발행 같은 트랜잭션 밖 작업을 락으로 감싸지 않아도 된다.

권장 표현:

```md
동시성 제어:
- DB unique/check 제약, 조건부 UPDATE 또는 `PESSIMISTIC_WRITE`를 우선 사용한다.
- 다중 노드 배포 여부가 확정되지 않았으므로 Redisson 분산락은 이번 Task 범위에 포함하지 않는다.
- 향후 다중 노드에서 DB 락만으로 보호되지 않는 임계구역이 확인되면 분산락 적용을 별도 Task로 분리한다.
```

### Redisson을 후보로 언급하는 경우

다음 중 하나라도 해당하면 Task에 "분산락 후보"로 남긴다.

- 같은 자원에 대한 check-then-act 로직이 DB 제약으로 표현되지 않는다.
- 임계구역이 외부 저장소, 외부 결제 API, 파일 시스템, Kafka 발행 전후 보상 로직까지 걸친다.
- 스케줄러 또는 Kafka consumer가 여러 인스턴스에서 같은 작업을 중복 실행할 수 있다.
- 단일 row lock으로 표현하기 어려운 집합 단위 자원이다.
- 다중 노드 배포가 결정되었고 JVM 내부 락 또는 로컬 상태에 의존하고 있다.

권장 표현:

```md
동시성 제어:
- 현재 구현은 DB 트랜잭션/제약을 우선 사용한다.
- 다중 노드 배포 시 `{resourceKey}` 단위 Redisson 분산락 적용 후보로 기록한다.
- 분산락을 도입하더라도 DB 상태 조건/unique/check 제약은 최종 방어선으로 유지한다.
```

### Redisson을 구현 범위에 넣는 경우

다음 조건이 명확할 때만 Redisson 구현을 Task 범위에 포함한다.

- 다중 노드 배포 또는 다중 consumer 실행이 요구사항이다.
- 보호해야 할 자원 key가 명확하다.
- 락 대기 시간, lease time, 재시도, 타임아웃, 실패 시 도메인 응답이 정의되어 있다.
- Redis 장애 시 정책이 정의되어 있다.
- DB 제약 또는 상태 검증으로 최종 정합성 방어선이 남아 있다.

## 3. 현재 동시성 지점 인벤토리

| 영역 | 현재 방식 | 다중 노드 영향 | Redisson 필요성 |
|---|---|---|---|
| 회원가입 이메일 중복 | `users.email` unique + `DataIntegrityViolationException` 변환 | DB 제약 기반이므로 영향 작음 | 불필요 |
| 장바구니 생성/항목 생성 | `uq_carts_user_id`, `uq_cart_items_cart_variant` unique 경합 복구 | DB 제약 기반이므로 영향 작음 | 불필요 |
| 주문 생성 재고 차감 | `product_variants` row `PESSIMISTIC_WRITE` + 락 후 권위 재검증 | DB row lock은 다중 앱 인스턴스에서도 유효 | 보통 불필요 |
| 주문 결제 확정 | `orders` row `PESSIMISTIC_WRITE` + 상태/금액 권위 재검증 + event 발행 | DB row lock과 Outbox가 기준이면 영향 작음 | 보통 불필요 |
| payment row 단일성 | `uq_payments_order_id` unique 선점 | DB 제약 기반이므로 영향 작음 | 불필요 |
| 상품 이미지 개수 상한 | 현재 best-effort check-then-act | 동시 업로드에서 상한 초과 가능 | 엄격 보장 필요 시 후보 |
| 쿠폰 총 발급/사용 한도 | 조건부 UPDATE 권장, 아직 도메인 Task에서 구체화 필요 | DB 조건부 UPDATE면 영향 작음 | DB로 표현 불가한 집합 조건이면 후보 |
| notification 이벤트 중복 소비 | processed event unique 또는 Redis dedup + DB 이력 | consumer group/중복 delivery에 영향 있음 | Redis dedup은 가능하나 DB unique가 권위 |

## 4. 나중에 고쳐도 영향이 작은 구조

- 락 획득/해제 코드가 Service 내부 작은 경계나 공통 컴포넌트로 격리되어 있다.
- 비즈니스 로직이 Redisson, Redis, JVM lock 구현체를 직접 알지 않는다.
- 락 key가 도메인 자원 기준으로 일관된다. 예: `variantId`, `orderId`, `productId`, `couponId`.
- 락 실패와 타임아웃이 도메인 예외로 변환된다.
- 테스트가 "동시 요청 중 하나만 성공" 같은 비즈니스 결과를 검증하고, 특정 락 구현체에 과하게 결합하지 않는다.

권장 형태:

```java
concurrencyGuard.execute(resourceKey, () -> {
    service.changeState(command);
});
```

이 형태라면 현재 내부 구현이 DB 락 중심이어도, 나중에 Redisson 기반 구현으로 바꾸는 영향이 작다.

## 5. 나중에 고치면 영향이 커지는 구조

- `synchronized`, `ReentrantLock`, Redisson API 호출이 여러 Service에 직접 흩어져 있다.
- "락이 있으니 괜찮다"는 전제로 DB unique/check 제약이나 상태 조건을 생략했다.
- 같은 자원인데 락 key 기준이 기능마다 다르다.
- 락 범위가 외부 API 호출, 파일 저장, 이벤트 발행까지 넓고 보상 정책이 없다.
- 트랜잭션 경계와 락 경계가 문서화되어 있지 않다.

이런 경우는 Redisson 도입보다 먼저 임계구역, 트랜잭션 경계, 실패 정책을 재정의한다.

## 6. 새 Task 체크리스트

동시성 가능성이 있는 Task는 다음 항목을 문서에 남긴다.

- 대상 자원: 어떤 id/key 기준으로 경합하는가.
- 현재 방어선: unique/check 제약, 조건부 UPDATE, `PESSIMISTIC_WRITE`, 상태 전이 조건, 멱등 key 중 무엇인가.
- 보호 범위: DB 변경만 보호하는가, 외부 API/파일/Kafka까지 포함하는가.
- 실패 정책: 경합, 타임아웃, 재시도, 중복 요청을 어떤 도메인 예외/응답으로 처리하는가.
- 다중 노드 전환 시 조치: 유지 가능, Redisson 후보, 구조 재검토 중 하나로 표시한다.
- 테스트: 단위 테스트만으로 충분한가, Testcontainers PostgreSQL 동시성 통합 테스트가 필요한가.

## 7. 관련 문서

- `docs/backlog/backend/007-backend-shop-core-distributed-lock.md` — Redisson 도입 재검토 백로그
- `docs/backlog/backend/010-backend-shop-core-product-image-count-limit-concurrency.md` — 상품 이미지 개수 상한 race 후속
- `docs/entity/database_design.md` 섹션 6 — 재고/쿠폰 조건부 UPDATE와 DB 방어선
- `docs/tasks/backend/015-backend-shop-core-order-creation-from-cart-with-view.md` — 재고 차감 비관적 락
- `docs/tasks/backend/016-backend-shop-core-payment-approval-order-confirmation-with-view.md` — 주문 결제 확정 비관적 락

## 8. `docs/plans` 점검 결과

점검일: 2026-06-08

`docs/plans`의 동시성 관련 설계를 기준으로 보면, 이미 구현되었거나 계획된 주요 지점 대부분은 DB 제약 또는 PostgreSQL row lock 기반이라 다중 앱 인스턴스에서도 유지 가능하다. Redisson을 즉시 끼워 넣을 필요가 있는 지점은 확인되지 않았고, 엄격 보장이 필요해질 때 별도 검토해야 할 후보가 일부 있다.

| plan | 동시성 지점 | 현재 설계 | 판정 |
|---|---|---|---|
| `backend/007-backend-shop-core-member-signup-with-view-plan.md` | 이메일 중복 가입 | `existsByEmail` 사전 체크 + `users.email` unique 위반을 `DuplicateEmailException`으로 변환 | 다중 노드 영향 작음. Redisson 불필요 |
| `backend/014-backend-shop-core-cart-management-with-view-plan.md` | 장바구니/항목 생성 경합 | `uq_carts_user_id`, `uq_cart_items_cart_variant` unique 경합 복구 | 다중 노드 영향 작음. Redisson 불필요 |
| `backend/014-backend-shop-core-cart-management-with-view-plan.md` | 재담기 증가/lost update | `quantity + :delta <= :stock` 조건부 atomic UPDATE | DB 단일 문장 기반. Redisson 불필요 |
| `backend/012-backend-shop-core-product-image-management-with-view-plan.md` | 대표 이미지 1개 | partial unique index + unset -> flush -> set 순서 | 단일 요청 정합성은 DB 제약 기반. 동시 대표 변경까지 엄격히 보장하려면 별도 검토 가능 |
| `backend/012-backend-shop-core-product-image-management-with-view-plan.md` | 상품당 이미지 개수 상한 | `countByProductId` 후 `storage.put` 전 검사(best-effort) | check-then-act race 존재. 백로그 010 유지. Redisson/DB 락/조건부 INSERT 후보 |
| `backend/015-backend-shop-core-order-creation-from-cart-with-view-plan.md` | 주문 생성 재고 차감 | `VariantStock` row `PESSIMISTIC_WRITE`, variantId 오름차순, 락 후 권위 재검증 | DB row lock은 다중 노드에서도 유효. Redisson 보통 불필요 |
| `backend/015-backend-shop-core-order-creation-from-cart-with-view-plan.md` | 주문번호 충돌 | `uq_orders_order_number`, 트랜잭션 밖 bounded 재시도 | 다중 노드 영향 작음. Redisson 불필요 |
| `backend/016-backend-shop-core-payment-approval-order-confirmation-with-view-plan.md` | 동일 주문 동시 결제 | `uq_payments_order_id` ready row 선점 + 재조회 멱등/409 | 다중 노드 영향 작음. Redisson 불필요 |
| `backend/016-backend-shop-core-payment-approval-order-confirmation-with-view-plan.md` | 주문 paid 확정/이벤트 발행 | `orders` row `PESSIMISTIC_WRITE` + 상태/금액 재검증 + Outbox | 다중 노드 영향 작음. Redisson 보통 불필요 |
| `backend/005-backend-notification-consumer-idempotency-dlq-plan.md` | Kafka 이벤트 중복 소비 | `processed_event.event_id` unique 최종 방어, 중복 insert 흡수 | 다중 consumer에도 DB 권위로 유지 가능. Redis dedup은 성능 보조 |
| `infra/005-infra-redis-dependencies-and-local-compose-plan.md` | Redis lock namespace | `shopcore:lock:` prefix/TTL만 설계, 실제 락 구현 없음, Redisson 보류 | 현재는 적용 코드 0. 후속 Task에서 의미론 결정 |

### 점검 결론

- **Redisson 불필요/낮은 우선순위**: 회원가입, 장바구니 생성/증가, 주문 재고 차감, 주문번호 충돌, 결제 단일화, 주문 paid 확정, notification 멱등.
- **후보 유지**: 상품 이미지 개수 상한. 현재 plan이 best-effort라고 명시하고 있고, 이미 `docs/backlog/backend/010-backend-shop-core-product-image-count-limit-concurrency.md`로 이연되어 있다.
- **추가 관찰 필요**: 대표 이미지 변경은 partial unique index로 "대표 1개" 최종 방어는 되지만, 동시 대표 변경의 최종 승자 규칙은 last-writer 성격이다. 현재 요구가 "항상 1개"라면 충분하고, "사용자 의도 순서까지 엄격 보장"이 필요해지면 상품 row lock 또는 productId 단위 락 후보로 분리한다.
- **주의할 표현**: 이미 DB row lock으로 해결되는 재고/결제 영역을 "분산락 필요"라고 Task에 쓰면 구현보다 문서가 앞서게 된다. 해당 영역은 "다중 노드에서도 DB 락/unique 제약으로 유지 가능"이라고 적는 편이 맞다.

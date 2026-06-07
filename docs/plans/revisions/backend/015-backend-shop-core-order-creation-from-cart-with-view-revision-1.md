# 015 — 주문 생성 재고 동시성 전략 변경 (Revision 1)

- 대상 Task: `docs/tasks/backend/015-backend-shop-core-order-creation-from-cart-with-view.md`
- 대상 Plan: 작성 전
- 결정 일자: 2026-06-07
- 결정자: 사용자
- 목적: 주문 생성 시 재고 동시성 대응을 **조건부 atomic UPDATE 중심 설계**에서 **비관적 락 기반 재고 검증/차감 설계**로 변경한 이유와 구현 기준을 기록한다.

> **보정 (2026-06-07, task 점검 후 추가 결정):**
> 1. 재고 부족 응답 코드는 **`409`(상태 충돌)로 유지·통일**한다(락 전 스냅샷 사전검증·락 후 권위 검증 모두 `409`, `InsufficientStockException`). `error-response-rule` line 58("상태 충돌(재고 부족 등) → 409")이 직접 근거다. `400`은 배송지 입력 검증 전용. (점검 중 잠시 "전부 400"으로 정했으나 규칙과 충돌해 `409`로 환원했다.)
> 2. 락 구현은 "JDBC 또는 Entity 중 택1"이 아니라 **`product_variants`에 매핑되는 inventory 소유 JPA Entity(`VariantStock`, id·stock·isActive 매핑) + `@Lock(PESSIMISTIC_WRITE)`** 로 확정한다(A안). product `ProductVariant`를 같은 트랜잭션에서 write하지 않는다.
> 3. 락 후 권위 재검증은 stock뿐 아니라 **purchasable**도 포함한다. `variant.active`는 같은 row 락으로 완전 직렬화, `product.status`는 락 후 재조회 + 결제/확정 단계 재검증으로 처리(잔여 micro-window 수용, `products` row 완전 락은 미도입).
> 4. 실제 비관적 락 직렬화 동작은 **Testcontainers PostgreSQL + `@SpringBootTest` 동시성 통합 테스트**로 검증한다.

---

## 결정 요약

| 항목 | 초기 방향 | 변경 결정 | 비고 |
|---|---|---|---|
| 재고 차감 방식 | `UPDATE ... WHERE stock >= quantity` 조건부 atomic UPDATE | **비관적 락 기반 검증/차감** | 주문 생성 트랜잭션 안에서 수행 |
| 락 종류 | UPDATE 실행 시 DB row-level write lock에 의존 | **JPA `PESSIMISTIC_WRITE` 또는 PostgreSQL `SELECT ... FOR UPDATE`** | 명시적으로 재고 row 잠금 |
| 동시 주문 처리 | affected row 0이면 실패 | 락 획득 후 최신 stock 검증, 부족 시 `409` | 같은 variant 주문은 row 단위 직렬화 |
| 다중 variant 주문 | 별도 명시 부족 | **variantId 오름차순으로 락 획득** | 데드락 위험 완화 |
| 락 구간 | UPDATE 한 문장 | 재고 row 조회 → 검증 → 차감 | 외부 I/O 금지 |
| 확장성 기준 | 단순 카운터 차감에 최적 | 주문/결제/정산 확장에 유리 | 향후 도메인 규칙 증가 대비 |

---

## 1. 초기 방향

015 Task 초안은 재고 차감을 아래와 같은 조건부 atomic UPDATE로 처리하는 방향이었다.

```sql
UPDATE product_variants
SET stock = stock - :quantity
WHERE id = :variantId
  AND stock >= :quantity
```

이 방식은 단순 재고 차감에는 장점이 있다.

- 한 SQL 문장으로 검증과 차감이 끝난다.
- 조회 후 계산 후 저장하는 read-modify-write보다 race condition에 강하다.
- UPDATE 실행 중 DB row-level write lock이 잡히므로 같은 row 갱신은 DB에서 직렬화된다.
- affected row가 1이면 성공, 0이면 재고 부족으로 판단할 수 있다.

즉 조건부 UPDATE도 동시성 대응 자체가 없는 방식은 아니다. 단순 카운터 차감에는 충분히 좋은 선택이다.

## 2. 변경 이유

사용자는 “조건부 UPDATE가 가능한데도 왜 실무에서는 비관적 락을 쓰는가”를 질문했고, 이어서 이 프로젝트는 이후 주문/결제/정산 기능이 확장될 예정이므로 비관적 락이 더 적합하지 않느냐고 판단했다.

이 판단을 반영해 015의 재고 동시성 전략을 변경한다.

변경 이유는 다음과 같다.

1. **향후 도메인 규칙 확장**
   - 현재는 “stock이 충분하면 차감”이 전부지만, 이후 결제, 주문 확정, 취소, 환불, 정산, 판매 제한, 안전 재고 같은 규칙이 붙을 수 있다.
   - 비관적 락은 잠근 row의 최신 상태를 읽고 여러 비즈니스 판단을 애플리케이션 코드에서 순차적으로 표현하기 좋다.

2. **읽은 상태를 기준으로 한 결정의 명확성**
   - 조건부 UPDATE는 판단을 SQL 한 문장에 밀어 넣는 방식이다.
   - 비관적 락은 “현재 재고를 잠근 뒤 읽고, 검증하고, 차감한다”는 의도를 코드 구조로 드러낸다.
   - 주문 생성처럼 이후 다른 상태 전이와 연결될 기능에서는 이 명시성이 더 중요하다.

3. **복잡한 주문 흐름과의 정렬**
   - 주문은 단순 재고 카운터보다 큰 트랜잭션 경계다.
   - 주문 스냅샷 생성, 재고 차감, 장바구니 비우기, 이후 결제 준비까지 같은 흐름에 놓인다.
   - 재고 구간을 명시적으로 잠그면 추후 결제/정산 설계에서 어느 상태를 보호하는지 설명하기 쉽다.

4. **데드락 대응 규칙을 task에 명시 가능**
   - 한 주문에 여러 variant가 포함될 수 있다.
   - 비관적 락을 사용할 경우 variant row 락 획득 순서를 `variantId` 오름차순으로 고정해 데드락 위험을 줄인다.

## 3. 변경된 구현 기준

015 Task는 다음 기준을 따른다.

- 주문 생성 트랜잭션 안에서 재고를 차감한다.
- inventory published API가 주문 대상 variant 재고 row를 비관적 락으로 조회한다.
- JPA 구현 시 `PESSIMISTIC_WRITE`, SQL/JDBC 구현 시 PostgreSQL `SELECT ... FOR UPDATE`에 해당하는 row-level lock을 사용한다.
- 같은 variant에 대한 동시 주문 생성은 재고 row 단위로 직렬화된다.
- 한 주문에 여러 variant가 있으면 `variantId` 오름차순으로 락을 획득한다.
- 락을 잡은 뒤 최신 stock이 주문 quantity보다 작으면 `InsufficientStockException`으로 변환하고 REST에서는 `409`로 응답한다.
- 재고 부족 시 주문 저장, 주문 항목 저장, 재고 차감, 장바구니 비우기는 모두 롤백된다.
- 락을 잡은 구간 안에서는 외부 I/O, Kafka 발행, 결제 호출을 수행하지 않는다.
- inventory 구현은 product Entity/Repository/Service를 직접 참조하지 않는다.
- 필요하면 inventory 내부 scalar Entity/Repository 또는 JDBC 기반 repository로 재고 row만 잠그고 갱신한다.

## 4. 조건부 UPDATE와 비관적 락의 트레이드오프 기록

### 조건부 atomic UPDATE가 유리한 경우

- 규칙이 “현재 값이 조건을 만족하면 숫자를 바꾼다” 수준으로 단순하다.
- 한 row의 카운터 차감/증가가 핵심이다.
- 실패 원인을 세밀하게 구분할 필요가 크지 않다.
- 락 보유 시간을 최소화하고 싶다.

### 비관적 락이 유리한 경우

- 읽은 상태를 바탕으로 여러 비즈니스 규칙을 판단해야 한다.
- 재고 외에도 주문, 결제, 취소, 환불, 정산 같은 상태 전이가 이어진다.
- 실패 원인과 상태 전이 과정을 코드에서 명확히 표현하고 싶다.
- 여러 값을 읽고 “이 조합이 가능한가”를 판단한 뒤 일관되게 변경해야 한다.

### 015의 선택

015는 단순 재고 차감으로 끝나는 기능이 아니라 주문/결제/정산 흐름의 시작점이다. 따라서 조건부 UPDATE보다 비관적 락을 기본 전략으로 둔다.

## 5. Task 반영 내용

`docs/tasks/backend/015-backend-shop-core-order-creation-from-cart-with-view.md`에 다음 내용을 반영했다.

- 재고 차감 방식: 조건부 atomic UPDATE → 비관적 락 기반 검증/차감
- 락 구현: `PESSIMISTIC_WRITE` 또는 `SELECT ... FOR UPDATE`
- 동시 주문: 같은 variant row 단위 직렬화
- 다중 variant 주문: `variantId` 오름차순 락 획득
- 재고 부족: 최신 stock 기준 검증 실패 시 `409`
- 락 구간 금지: 외부 I/O, Kafka 발행, 결제 호출 금지
- inventory 경계: product 내부 Entity/Repository/Service 직접 참조 금지
- 테스트 기준: 비관적 락 기반 decrement, stock 부족, 락 획득 순서 검증

## 6. 후속 액션

- [x] 015 Task 문서에 비관적 락 기준 반영
- [x] 본 Revision 기록 작성
- [ ] 015 Plan 작성 시 본 Revision을 기준으로 inventory SPI와 order service 트랜잭션 경계를 구체화
- [ ] 015 구현 시 재고 row 락 획득 순서(`variantId` 오름차순) 테스트 추가
- [ ] 015 구현 시 락 구간 안에서 외부 I/O가 들어가지 않도록 리뷰 체크

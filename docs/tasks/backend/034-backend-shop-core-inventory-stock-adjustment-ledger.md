# 034. shop-core 재고 조정(Adjustment) + 재고 변동 원장(Ledger)

> 출처: 리포트 002(`docs/report/002-opus48-project-maturity-assessment.md`) "완성으로 가기 위한 우선순위" item 4(결제/재고/배송 운영 엣지 보강)의 **재고 축 첫 기능**(축 순서: 재고→배송→결제, 2026-06-15 사용자 확정). 현재 inventory 도메인은 차감/복원만 있고 **변동 이력·관리자 조정 기능이 전무**하다(매핑 실측: VariantStock는 단일 `int stock`, 이력 테이블·조정 API 없음).

## Target
shop-core inventory 도메인 (+ Flyway 마이그레이션). 도메인 내부 완결형 — 배송/결제 축 변경에 의존하지 않는다.

> **재고 변동의 추적(원장)과 운영자 보정(조정)에 한정**한다. 예약/확정 분리·backorder·부분배송/부분환불 복원·재입고 프로세스·Low-stock 이벤트·멀티로케이션은 **범위 밖**(아래 Non-goals).

---

## 설계 정정 (2026-06-15 — 초안 모순 점검 반영)
초안을 코드/규칙과 대조해 모순 2건·보완 2건을 아래 각 절에 반영했다.
- **(모순1) 원장의 reason/actor를 inventory가 자동 캡처할 수 없음** — 포트 시그니처에 없고, `increase()`는 취소·만료를 구분 못 한다(`OrderCancellationImpl.cancel:77` / `cancelByExpiry:98`가 둘 다 `increase` 호출). → 변동 맥락(reason·actorId·memo)을 **호출자가 inventory 포트로 전달**하고, inventory가 **잠금 트랜잭션 안에서 원장을 atomically 적재**(전후 수량 캡처, `increase()` variant-미존재 skip은 미기록). 별도 ledger 포트를 호출자가 따로 부르면 skip을 못 잡으므로 채택하지 않음.
- **(모순2) SELLER 소유권을 inventory가 판정 불가** — 소유권(`Product.ownerId`, V3)은 product 소유, inventory는 product 직접 참조 금지(`InventoryStockPort:15`). → 조정 API를 **기존 seller/product 네임스페이스로 이동**, 소유권은 거기서 native 해결(`ProductService.checkOwnership`, ADMIN 바이패스 재사용). 재고변경·원장 적재는 inventory published port로 위임.
- **(보완1) occurred_at** — 저장 `Instant`(UTC), 표시 시 KST 변환(ADR-009).
- **(보완2)** 신규 테이블 schema-mapping 검증(아래 테스트).

## Goal
1. **재고 변동 원장(ledger)**: 모든 **성공한** 재고 변동(주문 차감 / 취소·만료 복원 / 운영자 조정)을 사유·전후 수량·행위자·발생시각과 함께 기록하는 감사 원장 테이블을 신설한다. 원장 적재는 inventory 자동 훅이 아니라 **맥락을 아는 호출자가 전달한 reason·actor**를 inventory가 잠금 트랜잭션에서 함께 기록한다.
2. **재고 조정(adjustment)**: 손실·손상·실사 보정 사유로 재고를 증감하는 운영자 API. 조정도 원장에 동일하게 남는다.

## 범위 (Scope)
- **스키마(Flyway 신규 마이그레이션, 다음 버전)**: `inventory_stock_ledger`(가칭) — `variant_id`, `delta`(부호 있는 변동량), `reason`(ORDER_DECREASE / CANCEL_RESTORE / EXPIRY_RESTORE / ADJUSTMENT — inventory 소유 enum), `quantity_before`, `quantity_after`, `actor_id`(시스템=약속값/null, 운영자=회원 id), `memo`(조정 사유 텍스트, ADJUSTMENT 필수), `occurred_at`(저장 `Instant`/UTC, 표시 시 KST 변환 — ADR-009).
- **포트 확장(원장 적재 위임)**: `InventoryStockPort.decrease`/`increase`에 변동 맥락(reason·actorId·memo — primitive·enum만, order Entity 참조 없음)을 전달하도록 확장한다. inventory 구현이 잠금 트랜잭션 안에서 전후 수량을 캡처해 원장을 적재하며, `increase()`의 variant 미존재 skip 경로는 원장 미기록.
- **기존 호출부 수정**: 주문 생성(`OrderService.createOrderTx`)·취소(`OrderCancellationImpl`)·만료(`PaymentService.expirePendingOrder` 경유)가 각자 reason·actor를 전달하도록 호출부를 수정한다(재고 동작 변경 없음, 맥락 전달만 추가).
- **조정 경로**: 운영자가 특정 variant 재고를 +/- 보정(reason=ADJUSTMENT, memo 필수). 조정 엔드포인트는 product 모듈 경계(seller/product 네임스페이스)에서 inventory published port(위 확장)를 호출 → **product→inventory.spi 의존**(order 선례 동형, published port라 허용).
- **조정/이력 조회**: 해당 product 소유자(또는 ADMIN)가 variant별 원장 이력 조회.

## API 권한 (api-authorization-rule 적용)
| 항목 | 값 |
|---|---|
| API | `POST /api/v1/seller/products/{productId}/variants/{variantId}/stock-adjustments`, `GET /api/v1/seller/products/{productId}/variants/{variantId}/ledger` |
| 공개 여부 | authenticated |
| 최소 권한 | `ROLE_SELLER` |
| 상위 권한 허용 | `ROLE_ADMIN` |
| 소유권 검사 | 필요 — 기존 seller/product 소유권 재사용(`ProductService.checkOwnership(actorId, actorIsAdmin, …)`, ADMIN 바이패스). variant가 해당 productId 소속인지 함께 검증. |
| 비고 | 기존 `SellerProductVariantRestController`(`/api/v1/seller/products/{productId}/variants`) 규약과 정합(초안의 `/api/v1/inventory/...`는 폐기 — inventory가 소유권을 판정할 수 없음). 권한은 SecurityConfig `/api/v1/seller/**`→`hasRole("SELLER")`, RoleHierarchy로 ADMIN 함의. |

## 동시성 제약 (락 전수 분석 결과 반영)
- 조정은 기존 차감/복원과 **동일한 비관적 락**(`InventoryStockRepository.findByIdForUpdate` = `SELECT ... FOR UPDATE`)을 잡고 수행한다.
- 다건 조정 시 **variantId 오름차순 정렬 후 순차 락**(데드락 회피 규약, `InventoryStockPort` 선례 준수).
- **분산락 불필요**: 이 락은 DB 행 락이고 단일 PostgreSQL을 공유하므로 다중 노드에서도 이미 전역 직렬화된다. (다중 노드 스케줄러 리더 선출은 별 Task 035로 분리.)
- 음수 재고 방지: 조정 결과가 0 미만이면 거부(기존 DB CHECK `stock >= 0` + 앱 검증과 정합).

## Non-goals (명시적 범위 밖)
- 예약(reserve)/확정(commit) 단계 분리, backorder/예약 대기 — 별 이니셔티브.
- 부분배송/부분환불 시 수량 단위 재고 복원 — **배송·결제 축(후속 task)**.
- 재입고(receiving) 워크플로, 재고 이동(transfer), 멀티로케이션.
- Low-stock 임계 감지·이벤트 발행 — 별 task(이벤트 드리븐 확장).
- 분산락/스케줄러 리더 선출 — **Task 035**.

## 테스트 (testing-rule + api-authorization-rule + schema-mapping-validation-rule)
- Testcontainers 통합: 조정 후 stock·ledger 정합, 기존 차감/복원이 reason별로 원장에 기록되는지, `increase()` variant-삭제 skip이 원장 미기록인지, 동시 조정 PESSIMISTIC_WRITE 직렬화(RED→GREEN).
- **schema-mapping 검증**: 신규 `inventory_stock_ledger` JPA Entity ↔ Flyway SQL 정합(`ddl-auto=validate`). `smallint` 컬럼 회피 또는 `@JdbcTypeCode(SMALLINT)` 명시(메모리 선례 — smallint↔int 매핑으로 entityManagerFactory 깨져 연쇄 실패).
- 권한 매트릭스: 자기 product의 variant 조정 SELLER 가능 / ADMIN 가능 / 타 SELLER의 product variant 403·404 / 인증 없음 401.
- 음수 조정 거부, reason·memo 누락 검증, variant↔productId 불일치 거부.

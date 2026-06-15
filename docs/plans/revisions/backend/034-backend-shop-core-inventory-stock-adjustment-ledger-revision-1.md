# 034 재고 조정·변동 원장 — Revision 1 (구현/리뷰/게이트 실측 기록)

- 작성일: 2026-06-15
- 대상 plan: `docs/plans/backend/034-backend-shop-core-inventory-stock-adjustment-ledger-plan.md`
- 대상 task: `docs/tasks/backend/034-backend-shop-core-inventory-stock-adjustment-ledger.md`
- 결과: **전체 게이트 GREEN** — `./gradlew test` BUILD SUCCESSFUL (21m 05s), **1731 tests / 0 failures / 0 errors**
- 워크플로우: planner → plan-reviewer(PASS) → 사용자 승인 → backend-implementor → reviewer(FAIL→fix→FAIL→fix) → 메인 게이트

본 문서는 plan 대비 **구현 단계 편차**, reviewer 사이클, 그리고 **전체 게이트에서만 드러난 회귀와 그 처리**를 기록한다. (plan은 PASS였고 설계 자체는 유지됐다 — 아래는 구현 현실에서 갈린 지점들.)

---

## 1. plan 대비 구현 편차 (3건, 모두 타당)

| # | plan | 구현 | 사유 |
|---|---|---|---|
| 1 | `StockChangeReason`을 `inventory.domain`에 배치 | **`inventory.spi`에 배치** | order/product가 reason을 참조하는데 `inventory.domain`은 `@NamedInterface`가 아니라 `ModularityTests`가 깨진다. spi가 경계상 정확. (plan §2.2 정정 반영) |
| 2 | 포트 `adjustStock(...)` `void` | **`StockLedgerView adjustStock(...)` 반환** | 초기 구현은 void + product 서비스가 `getLedger(...PageRequest.of(0,1))` 재조회 → "최신 1건=방금 조정" 암묵 불변식 의존 + 500 폴백. reviewer 지적으로 포트가 적재한 view를 직접 반환하도록 변경(재조회·폴백 제거). |
| 3 | `VariantNotFoundException(long id)` 사용 | **파라미터 제거** | `id`가 메시지·super에 미사용. reviewer 지적으로 무인자 생성자화(전 호출처 갱신). |

> #1은 task/plan 문서에 이미 정정 반영됨. #2·#3은 본 revision으로 기록.

---

## 2. reviewer 사이클 (FAIL 2회 → 해소)

**1차 FAIL** — 핵심 로직(원장 정합·동시성 락·모듈 경계·보안 게이트·예외 매핑·스키마)은 PASS, 다음만 지적:
- (MAJOR) 동시성 테스트가 **증가 전용**이라 PESSIMISTIC_WRITE 직렬화를 변별 못함 → 증가+감소 혼합 시나리오 추가 + **락 제거 변형으로 RED 실제 확인**(2 FAIL 확인 후 원복).
- (MAJOR) 보안 테스트 미사용 import/매처 + 404 분기 출처 불명확 → 정리 + 소유권 게이트로 404 출처 고정.
- (MINOR×3) 포트 반환형(편차 #2), 예외 파라미터(편차 #3), plan 문서 enum 패키지 표기.

**2차 FAIL** — 보안 테스트에 미사용 `eq` import 1줄 잔존(MINOR) → 메인이 직접 제거(재검토 불요).

---

## 3. 전체 게이트에서만 드러난 회귀 (핵심 기록)

### 3.1 증상
타깃 테스트(`*StockAdjustment*`·`*StockLedger*`·`*InventoryStockPortImpl*`·`SchemaMappingValidationTest`)는 전부 GREEN이었으나, **전체 `./gradlew test`에서 1731개 중 705개 실패**.

### 3.2 근본 원인
- `InventoryStockPortImpl` 생성자에 새 의존 **`StockLedgerRepository`** 추가(원장 적재용).
- 이 프로젝트의 보안/뷰 컨트롤러 테스트는 **풀 `@SpringBootTest` + `@ActiveProfiles("test")`로 실 DB 없이 모든 Repository를 `@MockitoBean`으로 주입**한다(test 프로파일이 JPA 자동설정 제외).
- `InventoryStockRepository`를 mock하는 테스트 **64개** 중 63개가 새 `StockLedgerRepository`를 mock하지 않아 `inventoryStockPortImpl` 빈 생성 실패 → **ApplicationContext 로드 실패** → "failure threshold exceeded"로 같은 컨텍스트 공유 테스트가 **연쇄 실패(705)**.
- 진단 근거(실측): `UnsatisfiedDependencyException: 'inventoryStockPortImpl' 생성자 param 1 → No qualifying bean 'StockLedgerRepository'`. param 0(`InventoryStockRepository`)은 해결됨 = 정합/로직 결함 아님, **테스트 배선(mock 누락)** 문제.

### 3.3 왜 타깃 실행에서 안 잡혔나
타깃 실행은 inventory/order 관련 테스트만 포함, 광범위한 보안/뷰 테스트는 미포함. **풀 컨텍스트 회귀는 전체 게이트라야 드러난다**(메모리 `testcontainers-red-green-iteration-cost`의 "풀 게이트는 마지막 1회"가 정확히 이 종류를 잡는 이유).

---

## 4. 채택한 해결책 — 공용 합성 애노테이션 `@MockSharedRepositories`

수정 방향이 2갈래(① 63개 테스트에 `@MockitoBean StockLedgerRepository` 기계적 추가 vs ② 공용 지원 도입)라 **사용자 승인을 받아 ②를 채택**.

- **신규**: `com.shop.shop.support.MockSharedRepositories` (테스트) — 클래스 레벨 `@MockitoBean(types = { StockLedgerRepository.class })`(Spring Framework 6.2+)을 메타 애노테이션으로 합성.
- **의미**: "풀 컨텍스트가 빈 그래프 충족을 위해 요구하지만 **개별 테스트가 stub하지 않는** Repository"의 **중앙 등록처**. 앞으로 동종 Repository가 추가되면 **이 애노테이션 `types`만** 갱신하면 되고 개별 테스트는 무수정 → **재발 차단**.
- **적용**: 풀 컨텍스트 테스트 **62개**에 애노테이션 1줄 추가(기존 필드·stubbing 무수정 → 리스크 0).
- **제외 2개(정당)**:
  - `SellerStockAdjustmentRestControllerSecurityTest` — `StockLedgerRepository`를 직접 stub(필드 `@MockitoBean`). 애노테이션 추가 시 같은 타입 이중 override 충돌 → 제외.
  - `OrderCreationConcurrencyIntegrationTest` — 실 DB(Testcontainers) 사용으로 실 `StockLedgerRepository` 보유 → mock 불요.
- **검증**: 파일럿(`CartRestControllerSecurityTest`) 단독 통과로 메커니즘 확인 후 롤아웃. 충돌 0건(애노테이션+필드 동시 보유 파일 없음).

### 주의(향후)
- 특정 Repository를 **stub**해야 하는 테스트는 그 타입을 애노테이션에 넣지 말고 종전대로 필드 `@MockitoBean`으로 선언한다(이중 override 충돌 방지).

---

## 5. 최종 검증 게이트

- `./gradlew test` — **BUILD SUCCESSFUL in 21m 05s**, **1731 tests / 0 failures / 0 errors**.
- 포함: schema-mapping(신규 `inventory_stock_ledger`), inventory 통합(원장 적재·`increase` variant-삭제 skip 미기록·음수 409·미존재 404), 동시성 RED→GREEN(증가+감소 혼합), 권한 매트릭스, `ModularityTests`(product→inventory.spi named-interface 의존) GREEN.

---

## 6. 교훈 (재발 방지 후보)

> **핵심 서비스(여러 모듈이 의존하는 published-port 구현)에 새 Repository 의존을 추가하면, 풀 `@SpringBootTest`로 그 서비스를 로드하는 모든 테스트가 그 Repository를 `@MockitoBean`해야 한다.** 타깃 테스트만으로는 이 광범위 컨텍스트 회귀를 놓친다. 이제 그 mock은 `@MockSharedRepositories` 한 곳에서 관리되므로, 차기 동종 변경은 애노테이션 `types`만 갱신하면 된다.

# 050 Plan — 판매자 배송 Phase 3: admin↔seller 공존 정합 + 백필 + admin 표기 + 롤업 회귀

> Task: `docs/tasks/backend/050-backend-shop-core-seller-fulfillment-coexistence-hardening.md`
> 선행: Task 048(owner_id 스냅샷·판매자 주문 조회)·049(판매자 배송 생성/시작/완료) 완료.
> 성격: **신규 기능이 아니라 하드닝**. 롤업·이벤트·동시성·권한은 048/049에서 이미 admin·seller 공용 경로로 구현됨 → **대부분 검증(테스트)**, 실코드는 **V11 백필 마이그레이션 1건 + admin seller 표기**뿐.

---

## 0. 코드 대조 결과 (현재 상태 — 재구현 금지 근거)

| 050 범위 | 현재 코드 | 050 액션 |
|---|---|---|
| 멀티 배송 롤업 | `deliver()`가 (a)전 항목 배정 + (b)전 배송 delivered 판정 후 `order.markDelivered()`. ship 첫 1회만 `order.markShipping()`(멱등). 경로 무관 (`OrderFulfillmentService.java:677-693, 481-485`) | **회귀 검증만** |
| 동시 충돌 | 배송 생성·ship·deliver 모두 `orderRepository.findByIdForUpdate`(PESSIMISTIC_WRITE)로 주문 row 직렬화 + `shipment_items.order_item_id` UNIQUE(`V4__shipments.sql:56`) 최후 방어. UNIQUE 위반 → 409 매핑(`OFS:253-260`) | **동시성 테스트만** |
| 권한 경계 | seller ship/deliver는 `findSellerIdById` 스칼라 검사 → null(admin 생성)·불일치 = `ShipmentNotFoundException`(404 존재은닉) (`SellerFulfillmentFacadeImpl:102-124`). ship/deliver 본체는 admin·seller 공용 | **경계 테스트만** |
| 알림 | seller ship도 공용 `ship()` → `ShippingStartedEvent` Outbox 발행(`OFS:491`, `@Externalized("shipping-started")`) | **구매자 알림 종단 스모크만**(§3 검증만 — 결정) |
| 레거시 seller_id | `shipments.seller_id` nullable(`V4:25`), 과거 admin 생성분 NULL 잔존. `order_items.owner_id`는 V10에서 백필됨 | **V11 백필**(실코드) |
| admin seller 표기 | `admin/orders.html` shipments-section은 `s.shipmentId/status/carrier`만 표시, seller 무표기. `AdminOrderFulfillmentView.shipments`=`List<ShipmentResponse>`(sellerId 없음) | **DTO+facade+view 추가**(§1 선택 — 결정: 포함) |

**결론**: 롤업/동시성/권한/이벤트는 손대지 않는다(검증으로 회귀 확인). 신규/변경 코드는 아래 작업 1·2뿐.

---

## 1. 작업 1 — V11 백필 마이그레이션 (backend-implementor)

### 1.1 파일
`shop-core/src/main/resources/db/migration/V11__shipments_seller_id_backfill.sql` (최신 V10 → 다음 V11).
ADR-007(Flyway 소유 스키마) + V10 owner_id 백필 선례를 따른다. **1회 보정 스크립트 아님 — 버전 마이그레이션**(환경 간 재현·체크섬 보호).

### 1.2 백필 규칙 (단일 소유자만)
대상: `shipments.seller_id IS NULL` 행. 각 배송의 `shipment_items → order_items.owner_id` 조인으로 소유자 판정:
- **순수 단일 소유자**(전 항목이 동일 owner_id이고 **owner_id NULL 항목 0건**) → 그 owner_id로 `seller_id` 채움.
- **혼합 소유자**(`COUNT(DISTINCT)>1`) **또는 owner 불명 항목 1건이라도 포함**(전부 NULL 포함) → **NULL 유지**(백필 불가, 데이터 정합 한계).
- status 무관(preparing/shipping/delivered 모두) — seller_id는 소유 메타데이터지 상태가 아님.

★ **엣지(reviewer 주목)**: `{X 항목 + owner 불명(NULL) 항목}` 혼합도 백필 금지 — owner 불명 항목까지 X가 조작 가능해지는 것을 막기 위해 NULL 항목이 하나라도 있으면 제외. SQL COUNT(DISTINCT)는 NULL을 무시하므로, `WHERE owner_id IS NOT NULL`로 거르지 **말고** `COUNT(*)=COUNT(owner_id)`(NULL 항목 0건)를 HAVING에 추가한다.

```sql
-- 전 항목이 동일 단일 소유자이고 owner 불명(NULL) 항목이 0건인 레거시 배송만 seller_id 백필.
-- 혼합 소유자·owner 불명 포함은 NULL 유지(admin 전용 잔존).
UPDATE shipments s
SET    seller_id = sub.owner_id
FROM (
    SELECT si.shipment_id, MIN(oi.owner_id) AS owner_id
    FROM   shipment_items si
    JOIN   order_items oi ON si.order_item_id = oi.id
    GROUP  BY si.shipment_id
    HAVING COUNT(DISTINCT oi.owner_id) = 1     -- 단일 소유자
       AND COUNT(*) = COUNT(oi.owner_id)       -- owner 불명(NULL) 항목 0건
) sub
WHERE s.id = sub.shipment_id
  AND s.seller_id IS NULL;
```
- 헤더 주석에 V4/V10 불변 규칙·백필 한계(혼합 NULL 유지) 명시.
- 혼합 NULL 잔존 건수는 마이그레이션이 직접 리포트하지 않는다(순수 UPDATE). 한계는 주석+plan으로 문서화하고, **검증 테스트가 혼합 NULL 유지를 단언**(아래 3.1).

### 1.3 ★ 설계 결정 (reviewer 주목) — 백필의 권한 부수효과
백필로 단일소유 레거시 배송은 `seller_id=X`가 되어 **해당 seller가 이후 ship/deliver 가능**해진다(`verifySellerOwnership` 통과). 이는 모순이 아니라 **의도된 정합**: 단일소유 배송은 본래 그 seller의 것이며, 레거시를 seller 스코프 모델로 편입하는 것이 §2 목적. 혼합/불명은 NULL 유지로 **admin 전용**(seller가 못 건드림 — §1 권한 경계 유지). plan·마이그레이션 주석에 명시.

---

## 2. 작업 2 — admin 배송별 seller 구분 표기 (§1 선택 — 포함)

### 2.1 DTO (backend-implementor)
`AdminOrderFulfillmentView`의 배송 표현에 seller 식별을 추가한다. `ShipmentResponse`(REST 공용 DTO)에 member 이름을 섞지 않는다 — **admin 전용 표현**이므로 별도 record 사용:
- `AdminOrderFulfillmentView` 안에 `record AdminShipmentView(long shipmentId, String status, Long sellerId, String sellerLabel, String carrier, String trackingNumber, Instant shippedAt, Instant deliveredAt, List<ShipmentItemResponse> items)` 추가, `shipments` 필드 타입을 `List<AdminShipmentView>`로 교체.
- `sellerLabel`: sellerId non-null → 판매자명(아래 §2.2 fallback 적용), null → `"관리자 직접 처리"`.
- ★ **DTO 주석 갱신 지시(MINOR-2)**: 현재 `AdminOrderFulfillmentView.java:11` 주석은 "Entity·ownerId·로컬 경로 미노출"을 단언한다. `sellerId` 노출이 표면상 상충하므로, implementor는 주석을 **"admin 감독 목적의 sellerId/sellerLabel은 노출(ROLE_ADMIN 한정), 그 외 내부 식별자·Entity·로컬 경로 미노출"** 로 갱신한다. `ShipmentResponse`(REST 공용)는 무오염 유지.

### 2.2 Facade (backend-implementor)
`AdminOrderFulfillmentFacadeImpl.toAdminOrderFulfillmentView` 변환에서 sellerLabel 채움. **N+1 방지**: 페이지 전 배송의 distinct non-null sellerId를 모아 dedup 조회한 `Map<Long,String> sellerNames`를 만들어 재사용(페이지당 판매자 수만큼 — 소수). MemberDirectory에 배치 메서드 신설은 하지 않는다(과설계 회피, 페이지 내 distinct seller 소수).
- `listFulfillableOrders` 시작부에서 `allShipments`의 distinct sellerId 수집 → 이름 맵 1회 구성 → 주문별 변환에 주입.
- ★ **MAJOR-1 — 이름 해석 실패는 fallback, 페이지 비차단**: `MemberDirectoryImpl.findContactByUserId`(`:50-57`)는 **조회 실패 시 `IllegalStateException`을 던진다**. 그런데 `seller_id`(=`owner_id` 스냅샷)는 **판매자 계정이 삭제·비활성화돼도 잔존하는 스냅샷**이라(V10 스냅샷 설계), 그런 배송이 섞이면 dedup 맵 구성 중 예외 → admin 이행 목록 **전체 500**. 따라서 이름 맵 구성 시 sellerId별 `findContactByUserId` 호출을 **try/catch로 감싸 실패 시 `sellerLabel = "판매자(#" + sellerId + ")"` fallback으로 강등**(페이지 비차단). 정상 해석 시에만 실명 표시.
- member.spi에 미존재 허용 조회 메서드 신설은 **하지 않는다**(plan §5 비범위와 충돌 — 옵션 A 채택, fallback은 방어 코드 수 줄).

### 2.3 View (view-implementor)
`admin/orders.html` shipments-section(`s : ${o.shipments}`)에 seller 표기 1줄 추가:
- 배송 status 라벨 옆/아래 `<span class="shipment-seller" th:text="${s.sellerLabel}">` (예 "판매자: 홍길동" / "관리자 직접 처리").
- 기존 ship/deliver/create 폼·바인딩(`s.shipmentId` 등)은 무변경 — `AdminShipmentView`가 동일 필드명 유지.

---

## 3. 검증 (테스트 — backend-implementor 작성, 메인 게이트 + e2e-runner)

### 3.1 백필 검증 (Testcontainers 통합)
V11 적용 후: ① 순수 단일소유 NULL 배송 → seller_id 채워짐, ② 혼합소유(X·Y) 배송 → NULL 유지, ③ 전항목 owner_id NULL → NULL 유지, ④ **`{X + owner NULL}` 혼합 → NULL 유지**(엣지), ⑤ 이미 seller_id 있는 배송(049 생성) → 불변. 시드로 다섯 종류 배송을 만들고 단언.

### 3.2 admin↔seller 공존 (§1)
- **동시성**(통합): 같은 주문에 admin 생성 + seller 생성 동시 → 항목 이중 배정 0, 충돌은 409 일관(UNIQUE/락). `OrderCancellationConcurrencyIntegrationTest` 패턴 재사용. **타이밍 flaky 주의**([[flaky-order-cancellation-concurrency-test]]) — 재실행 단일 실패를 회귀로 오인 금지, 단정은 불변식(이중배정=0)에 둔다.
- **권한 경계**(통합): seller가 (a)admin 생성 seller_id=null 배송 ship/deliver → 404, (b)타 seller 배송 → 404. admin은 seller 생성 배송도 ship/deliver 가능(감독).
- **이름 해석 비차단**(통합, MAJOR-1 회귀): **존재하지 않는(삭제된) sellerId를 가진 배송이 섞인** 이행 목록 → facade가 예외 없이 `listFulfillableOrders` 반환(해당 배송 sellerLabel = `"판매자(#N)"` fallback, 페이지 비차단). 시드로 seller_id가 미존재 userId인 shipment를 만들고 단언.

### 3.3 멀티셀러 롤업 회귀 (§4 — 통합 + E2E)
- **통합**: 판매자 A·B 항목이 섞인 주문 → A·B 각자 배송 생성·ship. 첫 ship에 order preparing→shipping 1회(멱등, 둘째 ship은 order 불변). A·B 모두 deliver → order delivered. 일부만 deliver → order shipping 유지.
- **E2E**(e2e-runner, 049 `SellerFulfillmentE2eTest` 패턴): 판매자 A·B 시나리오 — A 배송 처리 후 order는 배송중, B까지 완료 시 배송완료. admin 화면에서 **양쪽 분기 노출 확인(작업 2)**: (a) seller 생성 배송 → 판매자명 라벨, (b) admin 생성(seller_id=null) 배송 → `"관리자 직접 처리"` 라벨. null 분기는 정적 리뷰 사각([[verify-admin-list-page-features-with-e2e]]) → 둘 다 E2E로 검증.

### 3.4 알림 종단 스모크 (§3 — 검증만)
seller ship → `ShippingStartedEvent` 발행 → notification 소비 → 구매자 알림 종단 1건 스모크(testing-rule 이벤트 종단). seller 대상 신규 알림은 **만들지 않음**(결정). notification은 log 모드 주의([[perf-test-notification-must-be-log-mode]]는 부하 한정 — 종단 1건은 무관하나 실 SMTP 발송 회피 위해 log/가짜 SMTP 권장).

---

## 4. 권한 / 규칙

- **api-authorization-rule**: 신규 엔드포인트 없음. admin 표기는 기존 admin 화면(ROLE_ADMIN) 내 표시 추가 — 신규 권한·소유권 검사 불요. seller 경로 권한은 049 유지(자기 seller_id만, 404 존재은닉).
- **schema-mapping-validation-rule**: V11은 컬럼 추가 없이 기존 `seller_id` UPDATE만 — Entity↔SQL 매핑 변경 없음(`Shipment.sellerId` 기존 매핑). validate 영향 없음.
- **event-contract-rule**: ShippingStartedEvent 계약 무변경(검증만).
- **package-structure-rule**: `AdminShipmentView`는 기존 `order/dto/AdminOrderFulfillmentView` 내부 record로 추가(신규 패키지 없음).

## 5. 비범위 (Non-goals)

- 배송/롤업 모델 재설계, admin 배송 경로 제거, 판매자 정산·수수료, **seller 대상 신규 알림**(§3 검증만 결정), MemberDirectory 배치 메서드 신설.

## 6. 검증 게이트 (verification-gate-rule)

1. 타깃 통합 테스트(백필·동시성·경계·롤업) RED→GREEN — 반복은 타깃만([[testcontainers-red-green-iteration-cost]]).
2. `./gradlew modulith:verify`(또는 Modulith 검증 테스트) PASS.
3. 풀 스위트 `./gradlew test` GREEN(마지막 1회).
4. 앱 기동 후 e2e-runner: 멀티셀러 롤업 E2E + admin seller 표기 노출.
   - **풀 주의**: 기동 시 hikari 풀 기본 10 확인, gradle 데몬 env 캐시 정리([[bootrun-jvm-leak-pg-exhaustion]]).

## 7. 리스크 / 주의

- 동시성 테스트 flaky 타이밍 — 불변식 단정 + 재실행 허용.
- V11 백필은 운영 데이터 일회성 변경 — 혼합 배송 NULL 잔존은 **명시된 한계**(되돌릴 필요 없음, seller_id는 추가 정보).
- admin 표기 N+1 — dedup 이름 맵으로 차단(2.2). reviewer가 페이지 distinct seller 다수 시나리오 지적 시에만 배치 메서드 검토.

## 8. 구현 순서 (오케스트레이션)

1. backend-implementor: V11 + DTO(AdminShipmentView) + facade(sellerLabel·dedup) + 통합테스트(3.1~3.3 통합·3.4 종단).
2. view-implementor: admin/orders.html seller 표기.
3. reviewer → (FAIL 시) fixer → 재리뷰.
4. 메인 게이트: Modulith verify + 풀 스위트.
5. e2e-runner: 멀티셀러 롤업 + admin 표기 E2E.

# 050. 판매자 배송 Phase 3 — admin↔seller 공존 정합 + 백필 + 알림 + 롤업 회귀

> 출처: 사용자 논의(판매자 배송) Phase 3. Phase 2(`049`)로 판매자 배송이 도입된 뒤 남는 **통합·정합·운영** 항목을 모은 하드닝 단계.
> 선행: **Task 049 완료**. 본 Phase는 신규 큰 기능이 아니라 공존·엣지·알림·회귀 검증.

## 배경 (Phase 1·2 완료 전제)
- Phase 2에서 판매자(seller_id 스탬프)·admin(seller_id null) 배송 경로가 **공존**한다.
- 멀티 배송 주문 상태 롤업(deliver-when-all, ship 멱등)은 **이미 구현**(`OrderFulfillmentService`) — 판매자 부분 배송에서도 성립하는지 **회귀 검증**이 필요.
- 기존(Phase 2 이전 admin 생성) shipment은 `seller_id`가 **NULL**로 남아 있다.

## Target / Goal
판매자·admin 배송이 한 주문에서 충돌 없이 공존하고, 멀티셀러 부분 배송에서 주문 상태가 정확히 롤업되며, 판매자에게 배송 처리 결과가 알림으로 연결되고, 레거시 shipment의 seller_id 정합을 맞춘다.

## 범위 (Scope)
### 1. admin↔seller 공존 정합
- **동시 조작 충돌 방지**: 같은 주문에 admin과 seller가 동시에 배송 생성 시 항목 이중 배정이 안 되게(기존 주문 행 락 + ShipmentItem UNIQUE 재사용 확인). 충돌은 409로 일관.
- **권한 경계 재확인**: admin은 전체(감독), seller는 자기 seller_id/owner_id 것만. admin이 만든 seller_id=null 배송을 seller가 못 건드림. seller가 만든 배송을 admin은 감독 가능(정책 명시).
- (선택) admin 화면에 배송별 **seller 구분 표기**(seller_id/판매자명) — 감독 가시성.

### 2. 레거시 shipment seller_id 백필
- Phase 2 이전 admin 생성 shipment(`seller_id` NULL)을, 그 ShipmentItem→orderItem→owner_id로 **단일 판매자면 백필**. **다판매자 혼합 배송(과거 admin이 섞어 만든 경우)은 백필 불가** → NULL 유지 + 로그/리포트(데이터 정합 한계 명시). Flyway 또는 1회 보정 스크립트.

### 3. 판매자 배송 알림 (notification)
- 판매자 배송 시작/완료가 **기존 이벤트 흐름**(예 `ShippingStartedEvent`)에 올라타 구매자 알림이 정상 발행되는지 확인(Phase 2가 기존 전이·이벤트 재사용이면 자동). 필요 시 **판매자 대상 알림**(주문 들어옴/배송 독촉 등)은 별도 검토 — 이벤트 계약 규칙 준수, 과설계 회피.

### 4. 멀티셀러 롤업 회귀 (재구현 아님 — 검증)
- 판매자 부분 배송 시나리오로 **기존 롤업 로직 회귀**: A·B 판매자 각자 배송 → 전부 deliver돼야 order delivered, 일부만 deliver면 order는 shipping 유지. ship 멱등(여러 판매자 첫 ship에 order preparing→shipping 1회).

## Non-goals
- 배송 모델/롤업 재설계 — 기존 재사용·검증만.
- 판매자 정산·수수료 — 별개 도메인.
- admin 배송 경로 제거 — 유지.
- 대규모 알림 신기능 — 기존 이벤트 흐름 검증 위주.

## 검증
- **공존**: admin·seller 동시 배송 생성 동시성 테스트(항목 이중 배정 0, 409 일관 — [[flaky-order-cancellation-concurrency-test]] 류 타이밍 주의). 권한 경계(seller가 admin/타seller 배송 조작 불가).
- **백필**: 레거시 단일판매자 shipment seller_id 채워짐, 혼합 배송은 NULL+로그(통합).
- **알림 종단**: 판매자 배송 시작→구매자 알림 이벤트 발행→소비 종단 스모크(이벤트 드리븐은 발행 무증상이라 종단 필수 — testing-rule §서비스 간 이벤트 종단).
- **롤업 회귀**: 멀티셀러 부분 배송 상태 전이(통합) + **브라우저 E2E**(판매자 A·B 시나리오).
- 메인: Modulith verify + 풀 스위트 그린.

## 참고
- Phase 1·2: `048`·`049`, `order/service/OrderFulfillmentService.java`(롤업·전이·이벤트), `Shipment.seller_id`, `order_item.owner_id`.
- 이벤트: `order/event/ShippingStartedEvent.java`, event-contract-rule, testing-rule(이벤트 종단 스모크 [[perf-test-notification-must-be-log-mode]] 무관 — 알림 발송 경로).
- 권한: api-authorization-rule, `SecurityConfig`.

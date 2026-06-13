# 남은 Task 로드맵 (post-017 / 018 착수 시점 기준)

> 작성일: 2026-06-10
> 목적: `017`(결제 거절) 완료 + `018`(주문 취소/환불/재고복원) 착수 시점에서, **앞으로 남은 작업**을 한 문서로 모은다. 도메인 흐름 후속 · 이벤트 소비(notification) · 아키텍처(모듈 분리/실 PG) · 회원/인증 · 도메인 확장 · 품질을 구분한다.
> 성격: 로드맵(후보·의존·제안 순서). 정식 착수 시 `docs/tasks/backend/`로 승격해 Task 명세를 작성한다. **번호/순서는 권장일 뿐 확정 실행 순서가 아니다.**
> 관련: 과거 Task에서 명시적으로 미뤄둔 항목은 `docs/backlog/backend/README.md`(기존 backlog 인덱스)에도 있다 — 본 문서는 그것까지 포함한 **전체 잔여 그림**이다.

---

## 0. 현재까지 / 진행 중

| Task | 상태 |
|---|---|
| 001~015 | 완료(공통·Modulith·Outbox·인증·회원·상품·장바구니·주문 생성) |
| 016 결제 승인 + 주문 확정 + OrderCompletedEvent | 완료 |
| 017 결제 거절 + PaymentFailedEvent | 완료(+ forward-compat 이음매 `OrderConfirmation.Outcome`, revision-1 §3) |
| 018 주문 취소 + 결제 환불 + 재고 복원 (with View) | 완료 |
| 019 주문 이행 — Shipment 모델 + 배송 생성(preparing) (with View) | 완료(단계 1/3) |
| 020 주문 이행 — 배송 시작(shipping) + ShippingStartedEvent (with View) | 완료(단계 2/3) |
| 021 주문 이행 — 배송 완료(delivered) (with View) | 완료(단계 3/3) |
| **022 미결제 주문 만료(TTL) — 자동 취소 + 재고 복원** | **착수(1.2 승격)** — `docs/tasks/backend/022-backend-shop-core-unpaid-order-expiry-auto-cancel-stock-restore.md` |
| **023 notification 도메인 이벤트 → 실제 이메일 발송 (채널 추상화 + order-cancelled 구독)** | **완료(2.1 승격)** — `docs/tasks/backend/023-backend-notification-domain-event-email-dispatch-with-channel-abstraction.md` (+ JpaAuditingConfig auditing 누락 버그 수정, e2e 로그 스모크 검증) |
| ~~Redis dedup 적용~~ | **보류(삭제)** — DB `processed_event` 권위로 충분(단일/다중 노드). 측정된 DB 읽기 병목 시 재검토. backlog 009 dedup 항목 유지. 결정: `docs/plans/revisions/backend/notification-dedup-store-redis-vs-db-decision-revision-1.md` |
| 024 notification post-commit 발송 분리(exactly-once 근접) + 발송 이력/DLQ 재처리(V2) | **골조(skeleton)** — 023 후속, backlog 009(이력) 승격. **다중 노드 신뢰성 우선 트랙.** `docs/tasks/backend/024-backend-notification-post-commit-dispatch-and-send-history.md` |
| 025 notification SMTP CircuitBreaker(Resilience4j) — 외부 의존 회복탄력성 | **골조(skeleton)** — 023 후속(회복탄력성). `docs/tasks/backend/025-backend-notification-smtp-circuitbreaker-resilience4j.md` |

---

## 1. 주문/결제 라이프사이클 후속 (도메인 흐름)

### 1.1 주문 배송/이행 상태 관리 (preparing → shipping → delivered) — **승격: Task 019·020·021(3분할)**
> **배송을 별도 엔티티로 모델링(Order 1:N Shipment)** — multi-seller·부분 배송 때문에 주문 단위 단일 운송장 모델을 폐기하고 `shipments`/`shipment_items` 신설(`orders.status`는 rollup 집계값). 전이 주체는 **ADMIN 단일**(판매자 범위 이행은 `shipments.seller_id` 이음매로만 두고 backlog 002로 연기). 결제(016/017) 입자도로 **단계 3분할**:
> - **019**(`...-order-shipment-model-and-creation-with-view.md`): Shipment 모델 + 스키마(`V4`) + 배송 생성(`preparing`) + rollup `paid→preparing` + admin 생성 View + 소비자 조회. **이벤트 없음.**
> - **020**(`...-order-shipment-start-shipping-started-event-with-view.md`): 배송 시작(`shipping`) + **`ShippingStartedEvent` 배송 단위 개정**(shipmentId+items[], 구독 컨슈머 없어 안전·문서 먼저) + P2 productId 사전검증 + 추적정보 View.
> - **021**(`...-order-shipment-delivery-completion-with-view.md`): 배송 완료(`delivered`) + rollup `→delivered`(전 항목 배정 && 전 배송 완료 판정).
- 영역: shop-core (order, 일부 view / 판매자·관리자)
- 출처: 016/017 — 결제 완료(`paid`) 이후 주문 라이프사이클 미구현. **`docs/event-catalog.md`에 `ShippingStartedEvent`(topic `shipping-started`)가 이미 정의되어 있어 발행처가 예정된 상태.**
- 범위(예): `paid → preparing → shipping → delivered` 전이(판매자/관리자 액션), 배송 시작 시 `ShippingStartedEvent` 발행(Outbox), 송장/배송 추적 필드, 상태별 화면.
- 선행: 016(주문 확정). 권한은 SELLER/ADMIN 중심 → backlog 002(판매자/관리자) 정합.

### 1.2 결제 미완료 TTL / stale row 정리 + 미결제 주문 만료 — **승격: Task 022**
> **022**(`...-unpaid-order-expiry-auto-cancel-stock-restore.md`): `created_at` 기준 TTL 초과 `pending` 주문을 스케줄러가 감지 → 018 취소/복원 흐름을 **시스템 주도(소유권 없음)·`pending` 전용·환불 없음** 경로로 재사용(주문 `cancelled` + 재고 복원 + 결제 row `cancelled` + `OrderCancelledEvent` refunded=false). 신규 migration/이벤트/도메인 전이 없음. stale `ready`/`failed` row 정리는 만료 취소가 `cancelled` 전이로 흡수(물리 삭제·보존정책은 범위 밖). 스케줄러 빈은 테스트 비활성 가드. 비동기 PG 대비는 후속(3.2).
- 영역: shop-core (payment·order, 스케줄러)
- 출처: **017이 명시적으로 범위 밖**으로 둠 — "`ready`/`failed` row의 만료(TTL)·정리(cleanup) 스케줄러는 비동기 PG·주문 만료 Task에서 도입".
- 선행: **018(취소/재고복원 흐름)**, 016/017. (구현 완료 전제 충족 — 019~021 완료)

### 1.3 부분 취소 (item 단위)
- 영역: shop-core (payment·order·inventory)
- 출처: **018 범위 밖**("전체 주문 단위 취소만").
- 범위(예): 주문 항목 일부 취소 + 부분 환불 + 해당 항목 재고만 복원. 금액 재계산·환불 정산.
- 선행: 018.

### 1.4 반품/교환 (배송 후 return/exchange)
- 영역: shop-core (order·payment·inventory)
- 출처: **018 범위 밖**(`delivered` 이후 회수/재배송 흐름).
- 범위(예): 반품 신청→승인→회수→환불, 교환(재배송). 배송(1.1) 위에 구축.
- 선행: 1.1(배송), 018.

---

## 2. 이벤트 소비 측 (notification — 이벤트 루프 닫기)

### 2.1 notification: 도메인 이벤트 소비 → 실제 알림 발송 — **승격: Task 023(이메일 채널)**
> **023**(`...-domain-event-email-dispatch-with-channel-abstraction.md`): 005 골격 위에 **실제 이메일 발송** — 발송 채널 추상화(이메일 우선) + 이벤트 타입별 렌더링(수신자·제목·본문, 자족 페이로드만) + **`order-cancelled` 구독 신설**(018 발행·§5 등록됐으나 005 미구독). 멱등은 005 `processed_event` 재사용. **SMS/푸시·Redis dedup 적용(009)·발송 이력 테이블(009)·RedisConfig 정리(008)·post-commit 분리(exactly-once)는 범위 밖.** 단일 트랜잭션 유지(at-least-once, 유실 방지 우선).
- 영역: notification (consumer·service)
- 출처: 016/017/018이 `order-completed`·`payment-failed`·(`order-cancelled`)·(`shipping-started`)를 **발행하지만, 실제 알림(이메일/SMS/푸시)을 보내는 발송 핸들러가 없다**(005는 Consumer 멱등/DLQ 골격만).
- 범위(예): 토픽별 Consumer + 발송 핸들러(멱등), 발송 채널 추상화(이메일 우선). 자족 페이로드만 사용(shop-core 역조회 금지).
- 선행: 005(Consumer 골격), 발행 측 각 Task. **backlog 008(RedisConfig 정리)·009(dedup+발송 이력/DLQ 테이블) 동반 권장.**

> 관련 기존 backlog: `005 welcome-event`(회원가입 알림), `008 notification RedisConfig 정리`, `009 notification dedup+이력`.

---

## 3. 아키텍처 / 플랫폼

### 3.1 payment 모듈 분리 (별도 서비스 + HTTP 통신)
- 영역: shop-core ↔ payment-service (아키텍처)
- 출처: **이번 세션 설계 논의** — `017` revision-1 §4에 결론 기록.
- 범위(예):
  - 포트 소유권 재배치: **payment 전용 포트(`OrderPaymentReader`/`OrderConfirmation`)는 payment 아웃바운드 포트로**(consumer-owned), **공유 `MemberDirectory`는 member 소유 유지**.
  - shop-core가 `/internal/...` 엔드포인트 노출(기존 in-process 구현이 핸들러가 됨) + payment 측 HTTP 어댑터(빈 교체).
  - **`confirmPaid` 쓰기 경로는 사가**(멱등키 + timeout=UNKNOWN 재시도 + 리컨실리에이션/보상) — `Outcome`에 `UNKNOWN` 추가. 읽기 포트는 GET 어댑터로 단순 교체.
  - 모듈 구조 테스트 → 컨트랙트 테스트(Pact/Spring Cloud Contract) + Kafka 스키마 호환성.
  - **DB는 분리하지 않는 전제**(공유 DB) — 단 쓰기 소유권 분리 규율 유지(payment는 payments만 write).
- 선행: 016/017/018(거절·취소까지 안정화 후). **분리 확정 시 착수**(현재는 무해한 이음매까지만 적용된 상태).

### 3.2 실 PG 연동 (authorize/refund 실 어댑터)
- 영역: shop-core (payment / 외부 연동)
- 출처: 016/017/018 — 모의 PG(`MockPaymentGateway`)만 구현. 포트(`PaymentGatewayPort.authorize`/`refund`)는 실 PG 교체 가능하도록 설계됨.
- 범위(예): 실 PG 어댑터(승인·환불·웹훅), idempotencyKey at-most-once, 비동기 승인/가상계좌 입금 통지, 환불 실패/부분 환불. 1.2(TTL/만료)·비동기 흐름과 연계.
- 선행: 016/017/018. 비동기 도입 시 1.2 동반.

### 3.3 정적 자산 R2 + CDN 이관
- 영역: shop-core (common/storage)
- 출처: CLAUDE.md — "정적 자산: 로컬 파일 시스템(이후 Cloudflare R2 + CDN으로 이관 예정)". `ObjectStorage` 추상화 이미 존재.
- 범위(예): R2 어댑터로 교체(빈 교체), CDN URL 발급, 마이그레이션.
- 선행: 012(상품 이미지/ObjectStorage).

### 3.4 분산락 실제 구현
- 영역: shop-core (공통 lock)
- 출처: backlog 007 — Redis lock namespace만 설계, 라이브러리 미도입(YAGNI).
- 범위/선행: `docs/backlog/backend/007-...md` 참조. 재고/쿠폰 등 임계구역 Task와 함께.

---

## 4. 회원 / 인증 (기존 backlog — `docs/backlog/backend/` 참조)

| backlog # | 항목 | 비고 |
|---|---|---|
| 001 | `/me` 엔드포인트 중복 정리(auth/me ↔ members/me) | 표면 정리 |
| 002 | 판매자/관리자 가입·권한 관리 | 1.1(배송, SELLER) 전 권장 |
| 003 | Kakao OAuth2 / 소셜 로그인 | 확장 |
| 004 | 계정 관리(비번 재설정/변경, 정보수정/탈퇴) | 재설정 메일은 2.1 연계 |
| 005 | 회원가입 Welcome 알림 이벤트 | 2.1(notification) 연계 |
| 006 | JWT refresh 회전/token family | 보안 강화 |

---

## 5. 기타 도메인 확장 (미정 · 우선순위 낮음)

- 쿠폰/할인(주문 금액 계산·동시성), 리뷰/평점, 위시리스트, 상품 검색/필터 고도화, 주문 내역/대시보드 등. 요구 확정 시 Task로 분해.

---

## 6. 품질 / 동시성

| backlog # | 항목 |
|---|---|
| 010 | 상품 이미지 개수 상한의 동시성 엄격 보장(race 방지) — 분산락(007) 선택 시 007 선행 |

---

## 제안 실행 순서 (의존 기준 — 강제 아님)

```
018(취소/환불/재고복원, 착수)
   └─> 1.2(미결제 TTL/만료 — 018 취소흐름 재사용)
   └─> 1.3(부분 취소) ─> 1.4(반품/교환, 1.1 필요)

1.1(배송/이행 상태, ShippingStartedEvent 발행) ──┐
2.1(notification 발송 핸들러) <───────── 발행 측(016/017/018/1.1) + 008·009
                                              └─ 005(welcome) 함께

3.1(payment 모듈 분리) ── 016/017/018 안정화 후, 분리 확정 시
3.2(실 PG) ── 3.1/1.2와 연계(비동기·환불)

회원/인증(4): 002는 1.1(판매자) 전, 004는 2.1과 연계
품질(6.010): 007(분산락) 선택 시 선행
```

> 핵심 의존 요약: **재고 복원/취소 흐름(018)** 이 1.2(만료)·1.3(부분취소)의 토대. **발행 측 이벤트(016/017/018/1.1)** 가 갖춰질수록 **2.1(notification 발송)** 의 가치가 커진다. **모듈 분리(3.1)** 는 도메인(거절·취소)이 안정화된 뒤, 분리가 확정되면 착수한다(현재는 무해한 이음매까지만 적용).

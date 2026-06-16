# 004. shop-core k6 부하 테스트 3차-b — payment-confirm 시나리오 (주문 행 락 + Outbox 발행)

> 출처: 로드맵 `docs/tasks/performance/performance-shop-core-k6-load-test-roadmap.md` §6 2순위·§15, Task 002 "후속 Task" 3차. 새 핫패스(결제 확정)를 가압하는 **새 시나리오**를 추가하는 단일 기능 Task다("한 Task = 한 기능").
>
> **선행: Task 001(하니스, 완료).** load(002)·stress(003)와 **독립** — payment 시나리오는 1차 하니스(lib·order-create 흐름)만 있으면 작성·구현 가능하다(부하 프로파일은 smoke/load 어느 것으로도 구동). 003과 선후 의존 없음.

## 계승하는 결정 (재논의 금지)
- 도구/타겟 A/게이트 제외/실 스택/summary+JSON — 로드맵 §2.
- **하니스 재사용**: `lib`(config·auth·seed)를 공유하고, **order-create 흐름을 재사용**해 결제 대상 주문을 만든다. 중복 제거 우선.
- **블랙박스 한정**: "결제 확정이 부하에서 SLO를 지키나"의 pass/fail·관측까지. Outbox 발행이 실제 Kafka로 나가는지의 내부 검증은 본 Task 범위 밖(정합은 Testcontainers·기존 테스트 책임).

## 배경
- 결제 확정(`POST /api/v1/orders/{orderId}/payment`)은 **주문 행 락 + Modulith Outbox 이벤트 외부화**가 걸리는 경로다(로드맵 §6 2순위). 부하 하에서 **락 직렬화 + Outbox 적재·발행 경로의 지연·throughput**이 본 시나리오의 관측 대상이다.
- **Kafka 필수**: 주문 확정은 Outbox로 이벤트를 외부화하므로, Kafka off면 발행 경로 충실도가 떨어진다(로드맵 §5). README 사전 점검에 Kafka up 강제.

## 운영 안전 전제 (필수 — 2026-06-16 세션 사고 교훈)
> 본 시나리오는 001~003보다 **이벤트 발행이 더 많다**(결제 확정 → `PaymentApproved`/`OrderConfirmed` 이벤트 → notification이 **주문 확정 메일** 발송). 부하로 수천 건이 발생하므로 아래를 반드시 지킨다.

- **notification은 `log` 모드로 띄우거나 끈다(실 SMTP 금지).** 002/003 부하 중 notification이 실 Gmail SMTP로 환영 메일을 대량 발송해 `454-4.7.0 Too many login attempts`로 차단된 사고가 있었다. payment-confirm은 **주문 확정 메일**까지 유발해 위험이 더 크다. `NOTIFICATION_MAIL_MODE=log`(현재 기본값 log) + `management.health.mail.enabled=false` 확인. 실 메일 확인이 필요하면 가짜 SMTP(Mailpit/MailHog). (메모리 "perf 테스트 시 notification은 log 모드")
- **베이스라인은 깨끗한 DB에서 측정한다.** 누적 주문이 쿼리를 열화시켜 thresholds를 오염시킨다(orders 41,531건 시 p95 13배). 측정 전 테스트 주문/장바구니 TRUNCATE(메인 수행, 사용자 승인). 메모리 "k6 부하 베이스라인은 깨끗한 DB에서".

## Target
`shop-core/perf/k6/scenarios/payment-confirm.js`(신규). `lib`·order-create 흐름 재사용. **앱 코드·빌드·시드 인프라 무변경**(기존 API만 호출).

## Goal
결제 확정 핫패스를 가압해 **주문 행 락 직렬화 + Outbox 발행 경로의 p95/p99·throughput·에러율**을 측정하고 thresholds(형태)를 확정한다. 목적은 추세 회귀 감시 기준선.

## 범위 (Scope)
- **시나리오 흐름**: 각 VU 반복이 **결제 대상 PENDING 주문을 확보 → 결제 확정**한다. 두 방식 중 plan에서 택1:
  - (a) VU가 매 반복 order-create(cart add→order create)로 주문을 만든 뒤 즉시 `POST /api/v1/orders/{orderId}/payment` 승인 — 자기완결, 단 주문생성 비용이 측정에 섞임(결제 단계 전용 `Trend`로 분리 계측).
  - (b) setup이 PENDING 주문 풀을 미리 시드하고 VU가 그중 하나를 결제 — 결제 단계만 고립 측정. 단 주문 풀 소진 관리 필요.
- **계측**: 결제 단계 자체 지연 `Trend payment_confirm_duration`, `Counter payment_confirmed`(성공), `Counter payment_conflict`(이미 결제/취소된 주문 등 상태 충돌 — cancel-vs-pay 선례 Task 033), `Counter payment_5xx`.
- **시드 보강(`lib/seed.js`)**: 결제에 필요한 결제수단/승인 입력 등 기존 API 계약에 맞춘 페이로드. (정확한 결제 승인 요청 스키마·상태 전이는 plan에서 코드 대조로 확정 — Task 001 선례처럼 Explore로 계약 실사.)
- **프로파일 구동**: 기존 smoke/load 프로파일로 구동(`-e PROFILE=...`). 본 Task는 시나리오만 추가하고 새 프로파일은 만들지 않는다.
  - **주의(포화점 재확인)**: load 프로파일의 60rps는 **order-create 핫패스(variant 락)** 기준으로 튜닝된 값이다. payment 경로는 **주문 행 락 + Outbox 발행**이라 포화점·처리상한이 다를 수 있다. load로 구동하되, **payment 경로가 포화점 위에서 측정되지 않는지** plan에서 확인하고(필요 시 payment 전용 목표 RPS를 별도 측정), 002 교훈("포화점 측정은 flaky")을 답습하지 않는다. 방식 (a)는 주문 생성 비용이 섞여 실효 부하가 더 낮을 수 있음도 감안.
- **thresholds(형태)**: `http_req_failed` rate<1%, `payment_confirm_duration` p95/p99(측정 후 기입), `payment_5xx` count==0(락/발행 붕괴=비정상). `payment_conflict`는 임계로 죽이지 않고 가시화(상태 충돌은 정상 비즈니스 흐름).

## Non-goals
- stress 프로파일·coupon 시나리오 — 별 Task(003/005).
- Outbox→Kafka 전달 정합·exactly-once 내부 검증 — Testcontainers/기존 테스트 책임(블랙박스 한정).
- 취소(cancel) 경로 가압 — 별도(필요 시 후속). 단 payment_conflict로 cancel-vs-pay 충돌은 표기.
- 앱/빌드 변경 — 없음.

## 검증 방법
- **사전 점검(필수)**: ① 앱·인프라(PG/Redis/**Kafka**) 기동, ② **notification이 log 모드(또는 정지)** 임을 확인(실 SMTP 발송 사고 방지 — 운영 안전 전제), ③ 측정 전 깨끗한 DB.
- **실행 통과**: `k6 run -e PROFILE=smoke|load shop-core/perf/k6/scenarios/payment-confirm.js`가 비정상 종료 없이 완료, 확정 thresholds 만족.
- **Kafka up 전제**: README 사전 점검(스택 Kafka 포함). Kafka off면 충실도 저하 경고.
- **정합 흔적 0(blackbox)**: `payment_5xx`==0, 결제 성공률이 SLO 내.
- **JSON 아티팩트**: `baselines/payment-confirm-smoke.json`(또는 load) 산출.
- `./gradlew test` 게이트 무관.

## 트레이드오프
- **(a) 매번 주문 생성 vs (b) 주문 풀 시드**: (a)는 자기완결이나 측정에 주문생성 비용 혼입(전용 Trend로 분리), (b)는 결제 단계 고립 측정이나 풀 소진 관리 필요. plan에서 측정 목적(고립 vs 종단)에 따라 택1.

## 참고
- 로드맵 §5(Kafka 필수)·§6(2순위)·§9, Task 001/002, 가압 대상: `POST /api/v1/orders/{orderId}/payment`(주문 행 락 + Outbox), 동시성 선례 Task 033(cancel-vs-pay)
- 구현 담당: `k6-implementor` (계약 실사는 메인이 Explore로 선행)

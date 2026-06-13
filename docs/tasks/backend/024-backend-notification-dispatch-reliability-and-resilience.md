# 024. notification 발송 신뢰성/회복탄력성 — post-commit 발송 + CircuitBreaker(Resilience4j) + dedup + 발송 이력/DLQ 재처리

> ⚠️ **상태: 골조(skeleton) — 미확정.** 023(실제 이메일 발송) 완료 후 정식 명세로 채운다. 아래 항목은 범위 후보이며 plan 단계에서 확정/취사한다.
> 출처: `023`이 범위 밖으로 미룬 회복탄력성 + backlog `009`(dedup + 발송 이력/DLQ 추적) + backlog `008`(RedisConfig 정리) 통합 승격.

## Target
notification

---

## Goal
`023`(실제 이메일 발송 + 4토픽 구독)이 동작하는 발송 파이프라인 위에, **발송 신뢰성과 외부 의존(SMTP) 회복탄력성**을 보강한다. 023이 005의 Kafka 재시도/DLQ를 재사용하는 수준에 머문 부분을 끌어올린다:
- **외부 SMTP 호출 격리**: Resilience4j **CircuitBreaker**로 SMTP 장애 시 fail-fast(매 메시지 재시도로 죽은 서버 두드리기 방지) → Kafka 재시도/DLQ로 흘려보냄.
- **post-commit 발송 분리**: 멱등 claim 커밋 후 발송으로 옮겨 **claim+발송 단일 트랜잭션의 long-transaction·이중 발송 윈도우**를 줄인다(exactly-once 근접).
- **dedup 적용(009)**: `notif:dedup:{eventId}` Redis 1차 방어 → DB `processed_event` 권위 멱등 → 처리 후 마킹(TTL). Redis 장애 시 DB 권위로 graceful degrade.
- **발송 이력/DLQ 재처리(009)**: 발송 결과·실패 사유 추적 테이블 + DLQ 재처리 경로.

> 정식 명세에서 위 4가지를 **단일 Task로 묶을지, 더 쪼갤지** 확정한다(예: 회복탄력성+post-commit / dedup+이력 분리 가능). 한 Task=한 기능(task-rule) 관점 재검토 필요.

---

## Context (채우기 — TODO)
- 선행: `023`(실제 발송), `005`(멱등·DLQ 골격), `008`(RedisConfig 정리 — StringRedisTemplate 주입 선행), backlog `009`.
- 023의 at-least-once 트레이드오프(claim+dispatch 단일 트랜잭션, 전송 후 커밋 실패 시 드문 이중 발송)를 post-commit 구조로 어떻게 바꿀지 — 발송 상태머신(`PENDING→SENT/FAILED`)과 `processed_event` 확장/신규 테이블 관계 결정.
- Resilience4j 적용 지점: **아웃바운드 `EmailSender.send` 둘레만**. **Kafka `DefaultErrorHandler`+DLQ(메시지 재배달)는 대체하지 않는다**(대체 시 DLQ·at-least-once 안전망 소실).
- dedup 설계: `docs/plans/infra/005-...-plan.md` §1.5, application.yml의 `notification.redis.dedup.*`(이미 설정 자리 존재, 적용 코드만 미구현).

## Authorization / 공개 표면 (TODO)
- 신규 REST/View 없음(백그라운드 소비·발송). DLQ 재처리 트리거를 관리자 엔드포인트로 노출할지 여부 결정(노출 시 api-authorization-rule 적용).

## Requirements (후보 — TODO 확정)
- [ ] Resilience4j 의존 추가 + `EmailSender.send` CircuitBreaker(설정값: 실패율 임계·open 지속·half-open). in-tx 잔존 시 fail-fast 우선(장시간 retry 금지).
- [ ] post-commit 발송 분리(claim 커밋 → 발송 → 결과 기록). 트랜잭션/오프셋 커밋 경계 재정의.
- [ ] 발송 이력/실패·DLQ 추적 — notification **V2 Flyway 마이그레이션**(신규 테이블 또는 `processed_event` 상태 확장).
- [ ] DLQ 재처리 경로(수동/배치).
- [ ] Redis dedup 적용(EXISTS 1차 방어 → DB 권위 → 마킹 TTL, graceful degrade).
- [ ] (008) `RedisConfig @ConditionalOnBean` 제거 → Boot 오토컨피그 위임(StringRedisTemplate 주입 회귀 테스트 동반).

## Constraints (TODO)
- 023/005 발송·멱등·DLQ 골격 회귀 없음. 이벤트 계약 무변경(소비 측). shop-core 역조회 금지.
- Resilience4j는 메시지 재배달 계층 대체 금지(SMTP 호출 격리 한정).
- 가상스레드 대비: 블로킹 I/O는 Infra 경계, `ThreadLocal` 직접 사용 금지.
- 프로파일 가드(`kafkatest | !test`) 유지 — 풀컨텍스트 test에서 외부 SMTP/Redis 접속·발송 유발 금지.

## Files (TODO — 정식 명세에서 확정)
- (신규) Resilience4j 설정 + `EmailSender` 어댑터 CircuitBreaker 적용
- (수정) 발송 오케스트레이션 — post-commit 분리, 발송 결과 기록
- (신규) `notification/.../db/migration/V2__...sql` — 발송 이력/상태 테이블
- (신규/수정) dedup 적용 컴포넌트 + `RedisConfig` 정리(008)
- (수정) `notification/build.gradle`(resilience4j), `application.yml`(circuitbreaker·dedup 적용)

## Acceptance Criteria (TODO)
- SMTP 장애 시 CircuitBreaker open → fail-fast → Kafka 재시도/DLQ. 복구 시 half-open→close.
- 동일 eventId 재수신 시 Redis 1차 + DB 권위로 발송 1회. Redis 장애 시에도 DB 권위로 중복 차단(정확성 무손상).
- 발송 결과/실패가 이력 테이블에 추적되고 DLQ 재처리가 가능하다.
- 005/023 회귀 없음, 풀컨텍스트 test 그린(외부 접속 미유발).

## Test (TODO)
- 단위: CircuitBreaker open/half-open/close 전이, dedup 1차 방어 + DB 권위 graceful degrade.
- 통합(EmbeddedKafka + Testcontainers Redis/PG): post-commit 발송·중복 차단·DLQ 재처리·이력 기록.

# 025. notification SMTP 발송 CircuitBreaker(Resilience4j) — 외부 의존 회복탄력성

> ⚠️ **상태: 골조(skeleton) — 미확정.** 023(발송) 이후 정식 명세로 채운다. 아래는 범위 후보이며 plan에서 확정/취사한다.
> 출처: `023`이 범위 밖으로 미룬 회복탄력성. post-commit(024)와 분리. (구 026 → 025로 번호 하향 — Redis dedup Task 삭제 결정, `docs/plans/revisions/backend/notification-dedup-store-redis-vs-db-decision-revision-1.md`.)

## Target
notification

---

## Goal
`023`의 아웃바운드 SMTP 호출(`EmailSender.send`) 둘레에 Resilience4j **CircuitBreaker**를 적용해, SMTP 장애 시 **fail-fast**(매 메시지마다 죽은 서버를 두드리지 않음)로 전환하고 Kafka 재시도/DLQ로 흘려보낸다.
- 적용 지점은 **아웃바운드 `EmailSender.send`(JavaMailEmailSender) 둘레만**.
- **Kafka `DefaultErrorHandler`+DLQ(메시지 재배달)는 대체하지 않는다** — 대체 시 DLQ·at-least-once 안전망 소실(023 Context 명시).

> Resilience4j는 **재시도 프레임워크 교체가 아니다.** 메시지 재시도는 005 Kafka 골격이 그대로 담당하고, 본 Task는 외부 SMTP 의존 격리(CircuitBreaker)만 더한다.

## Context (채우기 — TODO)
- 선행: `023`(EmailSender/JavaMailEmailSender), `005`(재시도/DLQ).
- 023 Context "at-least-once"·Constraints "Resilience4j는 메시지 재배달 계층 대체 금지" 참조.
- in-tx 잔존(024 post-commit 미적용 상태) 시 장시간 retry 금지 — fail-fast 우선(트랜잭션 길게 보유 방지).

## Requirements (후보 — TODO 확정)
- [ ] Resilience4j 의존 추가(`build.gradle`) + `EmailSender.send`(JavaMailEmailSender) CircuitBreaker 적용. 설정값(실패율 임계·open 지속·half-open 호출 수) `application.yml`/`@ConfigurationProperties`.
- [ ] open 상태에서 fail-fast → `NotificationException`(retryable)로 Kafka 재시도/DLQ 경로 합류(분류는 023 4장 재사용).
- [ ] (선택) 짧은 Retry는 두지 않거나 attempts 1~2로 제한(Kafka 재시도와 이중화 회피).

## Constraints (TODO)
- Kafka `DefaultErrorHandler`+DLQ 대체 금지(SMTP 호출 격리 한정). 023 발송·005 골격 회귀 없음.
- 프로파일 가드(`kafkatest | !test`) 유지 — 풀컨텍스트 test에서 외부 SMTP 미접속(CircuitBreaker 설정이 기동을 오염하지 않게).
- 이벤트 계약 무변경, 신규 마이그레이션 없음. 범위 밖: post-commit/이력(024), Redis dedup(보류 — revision 참조).

## Files (TODO)
- (수정) `notification/build.gradle` — resilience4j.
- (수정) `notification/service/JavaMailEmailSender.java`(또는 데코레이터) — CircuitBreaker.
- (수정) `application.yml` — circuitbreaker 설정.

## Acceptance Criteria (TODO)
- SMTP 장애 누적 시 CircuitBreaker open → fail-fast → Kafka 재시도/DLQ. 복구 시 half-open→close.
- 메시지 재시도/DLQ 골격(005)·발송 분류(023) 무변경, 회귀 없음.
- 풀컨텍스트 test 그린(외부 SMTP 미접속).

## Test (TODO)
- 단위: CircuitBreaker open/half-open/close 전이(실패 주입), open 시 fail-fast가 retryable로 전파.
- 통합(EmbeddedKafka): SMTP 실패 누적 → open → DLQ 경로 확인.

# notification dedup 저장소 — Redis vs 물리 DB 결정 (Revision 1)

- 대상: notification 멱등/dedup 설계 (구 Task 024 "Redis dedup 적용 + RedisConfig 정리" — 본 결정으로 **삭제**)
- 관련 Task: `docs/tasks/backend/023-...email-dispatch...md`(발송, 완료), `docs/tasks/backend/024-...post-commit...md`(구 025), `docs/tasks/backend/025-...circuitbreaker...md`(구 026)
- 관련 backlog: `docs/backlog/backend/008-...redisconfig-conditional-cleanup.md`, `docs/backlog/backend/009-...redis-dedup-and-history.md`
- 결정 일자: 2026-06-13
- 결정자: 사용자
- 목적: notification의 이벤트 중복 방지(dedup) 저장소를 **Redis 1차 방어 캐시로 둘지, 물리 DB(`processed_event`)만으로 갈지** 논의한 결론과 그에 따른 Task 재구성을 기록한다.

---

## 결정 요약

1. **notification dedup은 물리 DB(`processed_event` UNIQUE) 단일 권위로 간다. Redis dedup 적용은 보류(미측정 최적화).**
2. 이에 따라 **Redis dedup 적용 Task(구 024)를 삭제**한다.
3. 구 024에 흡수돼 있던 **RedisConfig `@ConditionalOnBean` 정리(008)** 는 **backlog 008로 환원**한다(여전히 유효한 잠복 버그 — 아래 참조). dedup을 도입하지 않으므로 "주입처 생기기 전 선행 정리"라는 시급성은 사라지지만, P1 안티패턴 자체는 남는다.
4. **Task 번호를 한 칸씩 내린다**: 구 025(post-commit 발송 분리 + 발송 이력/DLQ) → **024**, 구 026(SMTP CircuitBreaker) → **025**.

---

## 근거

### 핵심 전제 — "Redis vs DB"는 정확성에선 택1이 아니다
- **권위(authoritative)는 무조건 DB여야 한다.** Redis는 TTL 만료·eviction·비영속이라 권위가 될 수 없다. Redis를 쓰든 안 쓰든 `processed_event`(event_id UNIQUE)가 최종 차단자다. 따라서 질문은 "DB 앞에 Redis 캐시를 한 겹 더 둘 가치가 있나"이다.

### 단일 노드 관점
- Redis dedup이 절약하는 것: *중복* 이벤트일 때 DB `existsByEventId`(인덱스 point lookup, sub-ms) 한 번 생략.
- Redis dedup이 추가하는 것: *신규* 이벤트(정상 시 대부분)마다 EXISTS 왕복 + 커밋 후 SET 왕복 → **흔한 경로를 과세하고 드문 경로만 가속**.
- 중복은 리밸런스/재시도 때만 드물게 발생. DB point lookup은 이 규모에서 병목이 아니며 INSERT의 UNIQUE 제약이 진짜 가드.
- 결론: 외부 의존(Redis up/down)·graceful degrade 분기·전용 테스트 프로파일+Testcontainers 복잡도를 떠안을 만한 실익이 없다 → **조기 최적화(YAGNI)**.

### 다중 노드 관점
- 크로스노드 중복은 **리밸런스 시** 발생(노드 A 처리 중 죽음 → 파티션 B 재배정 → 재처리). 이를 잡으려면 dedup 저장소가 노드 간 공유여야 한다.
- **정확성**: 공유 DB `processed_event` UNIQUE가 어느 노드의 INSERT든 강제 → 경합 시 한쪽 성공, 다른 쪽 `DataIntegrityViolationException`을 **005가 이미 "race condition absorbed"로 흡수**. 크로스노드 중복을 추가 코드 없이 이미 막는다. Redis는 권위가 될 수 없으므로 정확성을 더하지 못한다(SETNX 권위화는 내구성 없는 걸 정확성 경로에 넣는 실수 → 금지).
- **부하**: M개 노드의 공유 DB 읽기(`existsByEventId`) 압력, 특히 리밸런스 버스트를 Redis read-cache가 완화할 수 있다 — 단 **읽기만**. 권위 INSERT(쓰기)는 그대로 DB로 funnel되므로 Redis가 쓰기 경합을 풀지 못한다(그건 테이블 파티셔닝/샤딩 문제).
- **우선순위**: 다중 노드에서 진짜 아픈 건 dedup 저장소가 아니라 **at-least-once 윈도우**(리밸런스↑ → 재배달↑ → "전송 성공 후 커밋 실패" 이중 발송↑). 이메일은 롤백 불가 부작용이므로 **post-commit/상태머신(현 024, 구 025)이 dedup보다 가치가 크다.**

### 결정 규칙(언제 Redis dedup을 켜나)
| 관점 | 권장 |
|---|---|
| 정확성(단일/다중 노드) | **DB UNIQUE**(이미 동작). Redis 권위화 금지 |
| 읽기 부하 분산 | **측정된** DB 읽기 병목/리밸런스 버스트가 있으면 그때 Redis read-cache 추가 |
| 쓰기 경합 | Redis로 못 풂 → 테이블 설계로 해결 |
| 다중 노드 우선순위 | **post-commit/exactly-once > Redis dedup** |

→ **선(先)측정·후(後)도입.** Redis 접속/설정/`RedisProperties` 기반은 infra 005에서 이미 마련돼 있으므로, 필요 시점에 dedup 적용 코드만 추가하면 된다(설계 자리는 보존).

---

## 결과 (Task 재구성)

| 항목 | 조치 |
|---|---|
| 구 024 (Redis dedup 적용 + RedisConfig 정리) | **삭제** (`024-backend-notification-redis-dedup-and-redisconfig-cleanup.md`) |
| RedisConfig `@ConditionalOnBean` 정리(008) | **backlog 008로 환원** (유효한 잠복 P1 — 아래) |
| Redis dedup 적용 | **보류** — backlog 009 dedup 항목으로 남김(측정 후 도입) |
| 구 025 post-commit + 발송 이력/DLQ | **→ 024**로 번호 하향 |
| 구 026 SMTP CircuitBreaker | **→ 025**로 번호 하향 |

> **008은 여전히 유효**: `RedisConfig`의 `@Bean @ConditionalOnBean(RedisConnectionFactory) StringRedisTemplate`는 dedup을 도입하지 않아도 P1 안티패턴(빈 등록 순서 의존)이다. Task 023 e2e에서 동일 패턴 `JpaAuditingConfig`가 실제 기동 결함(이벤트 유실)으로 실증되어 `@Profile("!test")`로 수정된 선례가 있다. 다만 현재 `RedisConfig`의 해당 빈은 **주입처가 없어 무해**하므로(StringRedisTemplate 사용처 0), 시급성은 낮고 backlog 008로 둔다.

---

## 보존되는 사실 / 후속

- notification 멱등의 권위는 `processed_event`(Flyway V1, event_id UNIQUE) 단일. 005 `process`의 사전 `existsByEventId` + `claimAndDispatch` UNIQUE INSERT + 경합 흡수가 단일/다중 노드 중복을 모두 차단한다.
- 다중 노드 신뢰성은 **post-commit/exactly-once(현 024)** 를 우선 트랙으로 본다.
- Redis dedup이 다시 필요해지면(측정된 DB 읽기 병목/리밸런스 버스트) backlog 009의 dedup 설계(`notif:dedup:{eventId}`, EXISTS→DB 권위→SET EX P3D, graceful degrade)를 그대로 되살린다.

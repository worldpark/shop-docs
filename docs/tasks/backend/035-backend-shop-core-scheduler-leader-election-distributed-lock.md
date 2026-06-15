# 035. shop-core 스케줄러 리더 선출(분산락) — 다중 노드 중복 실행 방지

> 출처: 리포트 002 item 4 "분산락(다중 노드) 결정". **Task 034(재고 조정) 진행 중 수행한 락 전수 분석에서 분리**된 횡단 관심사(2026-06-15). 도메인 기능이 아니라 운영/분산 인프라이므로 별 Task로 둔다("한 Task=한 기능").

## 배경 (락 전수 분석 결론)
- 코드베이스의 비관적 락은 **전부 DB 행 락**(`@Lock(PESSIMISTIC_WRITE)` → `SELECT ... FOR UPDATE`)이다. 단일 PostgreSQL을 공유하는 한 **다중 노드에서도 이미 전역 직렬화**되므로, **도메인 행 락에는 분산락이 불필요**하다(덧씌우면 이중 락·데드락 위험).
- 다중 노드의 실제 빈틈은 락이 아니라 **인메모리 `@Scheduled` 스케줄러의 중복 실행**이다: `UnpaidOrderExpiryScheduler.expireUnpaidOrders()`가 **모든 노드에서 동시에 발화**한다. 정합은 주문 행 락으로 보존되나(이중 취소 없음), N개 노드가 같은 만료 후보를 놓고 **경합·중복 작업**한다.

## 기술 선택 (확정)
- **분산락 라이브러리: Redisson(RLock)** — 사용자 확정(2026-06-15). Redis 기반 분산락으로 다중 노드 중 한 노드만 스케줄러를 실행하도록 게이트한다.
- **근거/전제 인프라**: Redis가 이미 운영 자산이다(shop-core는 `spring-boot-starter-data-redis`=Lettuce 기반 `StringRedisTemplate`을 RefreshToken·PasswordReset에 사용). 별도 코디네이터(ZooKeeper 등) 없이 Redisson만 추가하면 된다.
- **공존 주의(Lettuce 무영향)**: `redisson-spring-boot-starter`는 `RedisConnectionFactory`를 Redisson 기반으로 교체해 기존 Lettuce 동작(특히 "지연연결 덕에 브로커 없이 테스트 컨텍스트 로드 통과" 특성)을 바꿀 수 있다. → **starter가 아닌 plain `org.redisson:redisson`** 의존만 추가하고 `RedissonClient` 빈을 별도 등록한다(동일 Redis host/port·DB index 0). 기존 `StringRedisTemplate`/Lettuce 연결팩토리는 건드리지 않는다.
- **적용 범위는 스케줄러 리더 실행에 한정**한다. 도메인 행 락(VariantStock/Order의 `SELECT ... FOR UPDATE`)은 단일 PostgreSQL로 이미 노드 간 직렬화되므로 **Redisson을 덧씌우지 않는다**(이중 락·데드락 위험).

## 선행 결정 (BLOCKED until ADR)
- **ADR-005(분산락 보류) 갱신이 전제.** ADR의 미결 질문은 **"다중 노드 배포를 이번 마일스톤에 채택할지"**이다(메커니즘은 이미 Redisson으로 확정 — 위 "기술 선택"). 채택으로 결정되면 **"분산락=Redisson, 적용=스케줄러 리더 실행"**을 ADR-005에 명문화한다(보류 → 채택 기록). ADR 확정 전까지 본 Task는 착수하지 않는다.

## Target
shop-core platform/common 스케줄링 인프라. **도메인 로직·도메인 행 락은 변경하지 않는다.**

## Goal
ADR-005 채택 결정 시, `@Scheduled` 배치가 다중 노드에서 **중복 실행을 최소화**하도록 Redisson 리더 게이트를 적용한다. (정합 자체는 이미 도메인 행 락=멱등이 보장하며, 어떤 TTL 분산락도 작업 overrun 시 strict 단일 실행을 보장하진 못한다 → 본 Task의 목적은 **중복 작업 축소**다.)

## 범위 (Scope, ADR 채택 시)
- **Redisson 클라이언트·설정 도입**: plain `org.redisson:redisson` 의존 + `RedissonClient` 빈만 등록(연결팩토리 교체 없음, 위 "공존 주의"). 락 키 설정은 **기존 `RedisProperties` 분산락 stub**(`RedisProperties.java:77`, `application.yml:117`의 "분산락 — 키는 {resource}")을 재사용·정리한다(새로 만들지 않음).
- `@Scheduled` 진입점이 Redisson `RLock`을 **`tryLock(0, ...)`(비대기)**으로 획득한 노드에서만 작업을 수행하도록 래핑(획득 실패 노드는 즉시 skip). **leaseTime은 지정하지 않고 Redisson watchdog**(보유 프로세스 생존 동안 자동 갱신)에 맡긴다 — 고정 lease는 작업 overrun 시 실행 중 만료돼 다른 노드와 동시 실행(중복)을 다시 열기 때문. 해제는 `finally`에서 `isHeldByCurrentThread`일 때만 `unlock`.
- 1차 적용 대상: `UnpaidOrderExpiryScheduler.expireUnpaidOrders()`(`payment.service`). 이 스케줄러는 `@ConditionalOnProperty(shop.order.pending-expiry.enabled=true)`로 가드되고 `@EnableScheduling`은 `OrderExpirySchedulingConfig`에 있으므로(`UnpaidOrderExpiryScheduler.java:34,57`), **락 게이트도 같은 활성 조건과 정합**해야 한다(스케줄러 빈이 없으면 락도 무의미).
- **(향후 활성화 시) Modulith 미완료 이벤트 재발행 스케줄러** — 현재 `application.yml`에 republish-on-restart/resubmission 미설정이라 비대상이나, 켜지면 모든 노드가 같은 INCOMPLETE 이벤트를 재발행해 중복이 증폭되므로 동일 Redisson 리더 게이트 적용 대상. (정합은 컨슈머 멱등이 보장하므로 목적은 중복 작업 축소.)
- 새로 추가되는 재고/주문 관련 배치는 동일 Redisson 락 규약을 따르도록 가이드.

## Non-goals
- **도메인 행 락(VariantStock/Order)을 분산락으로 대체하지 않는다** — 불필요(위 배경).
- 비즈니스 로직·이벤트 계약 변경 없음.
- 단일 노드 배포만 유지하기로 ADR이 결정하면 본 Task는 종료(보류 유지).

## 034와의 관계
- **독립.** Task 034(재고 조정)는 035 없이도 다중 노드 정합이 보장된다(DB 행 락). 035는 034의 선행/후행 의존이 아니다.

## 테스트 (채택 시)
- **Testcontainers Redis + Redisson 클라이언트 2개(또는 2 스레드)**로 결정적 시나리오 검증: (a) 동시 `tryLock` 시 정확히 1개만 획득, (b) 보유자가 해제(또는 클라이언트 종료)한 뒤 다른 클라이언트가 획득.
- 진짜 node-death watchdog 페일오버(보유 노드 사망 → ~30s 후 락 만료 → 타 노드 획득)는 **타이밍 의존이라 단위로 결정적 단언이 어렵다** — 통합/수동 검증으로 한정 명시.

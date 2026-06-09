# (backlog) 분산락 실제 구현 (Redisson 도입 재검토)

> 상태: backlog (미착수)
> 영역: shop-core (backend / 재고·쿠폰 등 도메인 + 공통 lock 컴포넌트)
> 출처: Task 005/006 — Redis lock key namespace/TTL(`shopcore:lock:`, PT10S)만 설계, 실제 락 획득/해제와 라이브러리 도입은 후속으로 보류

## 배경 / 동기
- Task 005에서 분산락 key prefix/TTL을 `RedisProperties.Lock`에 설계만 두고, Redisson 등 라이브러리는 사용처가 0이라 미도입(YAGNI).
- 재고 차감/쿠폰 사용 등 동시성 임계 구역이 생기는 도메인 Task에서 실제 락이 필요해진다(database_design.md §6 동시성 노트).

## 범위 (할 것)
- 락 라이브러리 결정: Spring Data Redis(SETNX+토큰+Lua 해제) vs Redisson(watchdog/공정성). 락 의미론(재시도·타임아웃·자동연장) 함께 결정.
- 공통 락 컴포넌트(획득/해제, `shopcore:lock:{resource}` + TTL) 구현, 도메인 임계구역에 적용.
- 락 실패/타임아웃 시 예외 정책, Redis 장애 시 fallback(주문/결제 흐름을 가장하지 않도록 — 005 제약).

## 범위 밖 / 주의
- 락 적용 도메인 로직 자체는 해당 도메인 Task(재고/쿠폰)와 함께.
- DB `CHECK(stock>=0)`/조건부 UPDATE는 2차 방어선으로 유지(락만으로 의존 금지).

## 선행 의존
- Task 005(Redis 기반/lock namespace) 완료. 적용 대상 도메인(재고/주문/쿠폰) Task.

## 참고
- `docs/concurrency-control-guide.md`
- `docs/plans/infra/005-...-plan.md` §1.3, `docs/entity/database_design.md` §6

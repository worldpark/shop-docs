# (backlog) notification 알림 dedup 적용 + 발송 이력/DLQ 추적 테이블

> 상태: backlog (미착수)
> 영역: notification (backend / consumer·service·domain·repository)
> 출처: Task 005(Redis dedup namespace 설계만) + Task 004(notification V1은 processed_event만, 발송 이력/실패추적은 "구현된 범위에 맞춰" 미생성)

## 배경 / 동기
- Task 005에서 알림 중복 방지(dedup) key namespace(`notif:dedup:{eventId}`, P3D)만 설계했고, 실제 적용 코드와 Consumer 처리 로직 변경은 후속으로 미뤘다.
- 권위 멱등 저장소는 DB `processed_event`(유니크)이고, Redis dedup은 빠른 1차 방어 — 이 역할 분담을 코드로 구현해야 한다.

## 범위 (할 것)
- Consumer/Service에 dedup 적용: `notif:dedup:{eventId}` EXISTS 1차 방어 → DB `processed_event` 권위 멱등(기존) → 처리 후 dedup 마킹(TTL).
- Redis miss/장애 시 DB 권위로 graceful degrade(정확성 무손상) 보장.
- (선택) 실제 발송 이력 / 실패·DLQ 추적 테이블 도입 — notification V2 Flyway 마이그레이션, 발송 채널 구현과 함께.

## 범위 밖 / 주의
- 실제 이메일/SMS/푸시 발송 구현은 발송 채널 Task와 함께(여기선 dedup 우선).
- notification RedisConfig 정리(008)를 선행/동반 권장(StringRedisTemplate 주입 필요).

## 선행 의존
- Task 005(Redis namespace), 004(Flyway/ processed_event), 008(RedisConfig 정리).

## 참고
- `docs/plans/infra/005-...-plan.md` §1.5(dedup), `docs/tasks/infra/004-...md`(notification 소유 테이블)

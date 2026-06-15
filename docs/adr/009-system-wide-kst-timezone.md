# ADR-009 — 시스템 전역 타임존을 KST(Asia/Seoul)로 사용한다

## 상태
Accepted (2026-06-15)

## 맥락
- 서비스 대상이 국내 사용자라 화면·DB 조회·로그·이벤트 시각을 KST로 일관되게 보고자 한다.
- 시간 저장은 `timestamptz`(PostgreSQL) + Java `Instant`로 **절대시각(instant)** 을 보존한다(타임존 안전).
- 기본 동작에서는 시각이 여러 경로에서 UTC로 표현되어(예: Jackson은 `Instant`를 항상 `...Z`로 직렬화) 화면 외 영역(REST 응답·이벤트 페이로드·DB 직접 조회)이 UTC로 보였다.

## 결정
시스템 전체를 KST로 운영한다. 단, **저장값은 절대시각(`timestamptz`/`Instant`)으로 유지**하고 **표현(rendering)만 KST**로 통일한다.

- **JVM 기본 타임존 = Asia/Seoul**: shop-core 기동 시 `TimeZone.setDefault(Asia/Seoul)`. 로그 시각·`LocalDate(Time).now()`·Hibernate 타임존 처리가 KST 기준.
- **JSON 직렬화 = KST 오프셋**: 전역 Jackson `Module`로 `Instant`를 `+09:00` 오프셋 ISO-8601로 직렬화(예: `2026-06-15T14:30:00+09:00`). Spring Boot가 primary ObjectMapper에 자동 적용 → **REST 응답과 Spring Modulith Kafka 이벤트 외부화 모두 KST**.
- **DB 세션 기본 타임존 = Asia/Seoul**: `ALTER DATABASE ... SET timezone='Asia/Seoul'`(Flyway V7). `timestamptz` 조회·`now()` 기본 표시가 KST(저장 절대시각 불변).

## 결과
- **이벤트 계약(중요)**: 이벤트 페이로드의 시각 필드(`occurredAt` 등)가 UTC(`...Z`)에서 **KST 오프셋(`+09:00`)** 으로 바뀐다. 둘 다 ISO-8601이며 동일 절대시각을 나타내므로, `Instant`로 역직렬화하는 컨슈머(notification)는 **변경 없이 동일 시각으로 수신**한다(오프셋 흡수).
  - 단 **계약 SSOT(`docs/event-catalog.md`)의 시각 표기·예시를 KST 오프셋으로 갱신**하고, notification 레포가 이를 미러링한다. wire 문자열을 정확히 `...Z`로 단언하던 테스트가 있으면 갱신한다.
- 저장 데이터는 무손실(절대시각 보존). 표현만 KST.
- 다국가 확장 시에는 표현 타임존을 사용자/요청 기준으로 분기해야 하며, 그 단계에서 본 결정을 재검토한다.

## 대안
- (기각) DB 컬럼을 `timestamp`(without tz)로 바꿔 KST 벽시계값을 literal 저장 — 타임존 안티패턴·스키마 변경·기존 데이터 의미 훼손.
- (기각) REST만 KST, 이벤트는 UTC 유지 — 시각 표현이 경로별로 갈려 일관성 저하(사용자 요구는 시스템 전체 KST).

## 관련
- ADR-002(Transactional Outbox), ADR-007(Flyway 소유 스키마), `docs/event-catalog.md`, `docs/rules/event-contract-rule.md`

# Architecture Decision Records

이 디렉터리는 시스템 구조와 장기 변경 비용에 영향을 주는 주요 아키텍처 결정을 기록한다.

| ADR | 상태 | 결정 |
|---|---|---|
| [ADR-001](001-kafka-only-async-integration.md) | Accepted | shop-core와 notification은 Kafka 단방향 비동기 이벤트로만 통합한다. |
| [ADR-002](002-transactional-outbox-with-spring-modulith.md) | Accepted | shop-core 이벤트 발행은 Spring Modulith Event Publication Registry 기반 Transactional Outbox를 사용한다. |
| [ADR-003](003-spring-modulith-modular-monolith.md) | Accepted | shop-core는 Spring Modulith 모듈러 모놀리스로 구성하고, 향후 분리를 위해 port/published API 경계를 유지한다. |
| [ADR-004](004-workspace-level-event-contract-ssot.md) | Accepted | 프로젝트 간 이벤트 계약은 상위 workspace 문서인 `docs/event-catalog.md`를 SSOT로 관리한다. |
| [ADR-005](005-database-first-concurrency-redisson-later.md) | Accepted | 현재는 DB 기반 동시성 제어를 우선하고, 다중 노드 단계에서 Redisson 분산락을 도입한다. |
| [ADR-006](006-object-storage-key-and-local-first-assets.md) | Accepted | 정적 자산은 storage key만 저장하고 `ObjectStorage` 뒤에 둔다. |
| [ADR-007](007-flyway-owned-schema-hibernate-validate.md) | Accepted | DB 스키마 생성과 변경은 Flyway가 소유하고, Hibernate는 `ddl-auto=validate`로 검증만 수행한다. |
| [ADR-009](009-playwright-java-e2e-external-app-target.md) | Accepted | E2E 테스트는 Playwright for Java와 외부 앱 타겟 방식으로 구성한다. |

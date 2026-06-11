# ADR-007 — Flyway가 DB 스키마를 소유하고 Hibernate는 validate만 수행한다

- 작성일: 2026-06-11
- 상태: Accepted
- 범위: shop-core, notification

## 맥락

`shop-core`와 `notification`은 각각 독립 PostgreSQL 인스턴스를 사용한다. 두 프로젝트는 DB를 공유하지 않으며, 각 프로젝트의 DB 스키마도 해당 프로젝트가 독립적으로 소유한다.

초기 개발 단계에서는 Hibernate의 `ddl-auto=create` 같은 자동 DDL 생성이 빠른 출발점이 될 수 있다. 하지만 도메인 테이블, 제약, 인덱스, 트리거, Spring Modulith `event_publication` 같은 운영 스키마가 늘어나면 JPA 자동 생성에 의존하는 방식은 변경 이력과 재현성을 추적하기 어렵다.

스키마 변경은 애플리케이션 코드만큼 장기 호환성과 복구 가능성이 중요하다. 어떤 SQL이 언제 적용되었는지 남아야 하며, 이미 적용된 스키마를 임의로 재작성하지 않아야 한다.

검토한 대안은 다음과 같다.

| 대안 | 장점 | 단점 |
|---|---|---|
| Hibernate `ddl-auto=create/update` | 초기 개발이 빠르고 Entity 변경을 즉시 반영 | 운영 재현성 낮음, 스키마 변경 이력 추적 어려움, DB 제약/인덱스/트리거 표현 한계 |
| 수동 SQL 적용 | 도구 의존성 낮음 | 적용 순서와 이력 관리가 사람에게 의존, 환경별 drift 위험 |
| Flyway migration + Hibernate validate | 스키마 변경 이력과 재현성 확보, Entity 매핑 검증 가능 | migration 작성과 테스트 프로파일 관리가 필요 |

## 결정

양 프로젝트의 DDL 생성과 변경은 Flyway `db/migration/V*.sql`이 단독으로 담당한다.

- Hibernate/JPA는 스키마를 생성하거나 수정하지 않는다.
- 운영/개발 설정에서 `spring.jpa.hibernate.ddl-auto=validate`를 사용한다.
- Hibernate는 Entity 매핑과 Flyway가 적용한 스키마의 정합성만 검증한다.
- `ddl-auto=create`, `ddl-auto=update`를 유지하지 않는다.
- 적용된 Flyway migration은 수정하지 않는다.
- 모든 스키마 변경은 후속 `V2__`, `V3__` migration으로 추가한다.
- `shop-core`의 Spring Modulith `event_publication` 테이블도 Flyway가 소유한다.
- `notification` DB에는 notification이 소유한 테이블만 생성하며, `shop-core` 도메인 테이블을 복제하지 않는다.

## 결과

긍정적 결과:

- DB 스키마 변경 이력이 파일과 `flyway_schema_history`에 남는다.
- 깨끗한 PostgreSQL 인스턴스에서 동일한 스키마를 재현할 수 있다.
- Entity와 실제 DB 스키마가 어긋나면 애플리케이션 기동 시 `validate`로 빠르게 실패한다.
- FK, CHECK, partial unique index, trigger, PostgreSQL 확장 같은 DB 고유 제약을 명시적으로 관리할 수 있다.
- 두 프로젝트의 DB 소유권과 migration 경계가 명확해진다.

부정적 결과와 대응:

- Entity 변경만으로는 스키마가 바뀌지 않는다.
  - DB 변경이 필요한 기능은 반드시 새 Flyway migration을 함께 작성한다.
- 이미 적용된 migration을 수정하면 checksum mismatch가 발생한다.
  - 적용 후 변경은 새 버전 migration으로만 처리한다.
- 테스트에서 Flyway가 항상 켜져 있으면 DB 없는 컨텍스트 로드나 H2 슬라이스가 깨질 수 있다.
  - 기본 test profile에서는 Flyway/JPA 자동설정을 비활성화하고, 실제 스키마 검증이 필요한 테스트는 PostgreSQL/Testcontainers 또는 로컬 PostgreSQL에서 Flyway를 명시적으로 켠다.
- `event_publication`은 프레임워크 소유 Entity와 DDL이 정확히 맞아야 한다.
  - Modulith JPA 매핑 또는 동봉 스키마를 기준으로 Flyway DDL을 작성하고 `validate` 통과로 검증한다.

## 관련 문서

- `docs/tasks/infra/004-infra-flyway-schema-management.md`
- `docs/plans/infra/004-infra-flyway-schema-management-plan.md`
- `docs/entity/database_design.md`
- `docs/architecture.md`

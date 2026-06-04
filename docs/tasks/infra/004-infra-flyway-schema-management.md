# 004. Flyway 스키마 관리 전환

## Target
workspace

---

## Goal
`shop-core`와 `notification`의 DB 스키마 소유권을 Hibernate 자동 생성에서 Flyway 마이그레이션으로 전환하고, `docs/entity/database_design.md`를 기준으로 추적 가능한 초기 스키마를 구성한다.

---

## Context
- 두 프로젝트는 각각 독립 PostgreSQL 인스턴스를 사용한다
- DB 공유는 금지된다
- `docs/entity/database_design.md`는 Flyway 마이그레이션(`V1__init_schema.sql`)을 스키마 정본으로 둔다
- 현재 두 프로젝트는 개발 편의용 `spring.jpa.hibernate.ddl-auto=create`를 사용한다
- Flyway 도입 후 Hibernate는 스키마 생성이 아니라 검증만 수행해야 한다
- `shop-core`는 Spring Modulith Event Publication Registry(`event_publication`)를 사용한다
- `notification`은 자기 DB에 알림 이력, 멱등 처리 이력, 실패/DLQ 추적 데이터를 저장한다

## Requirements
- 두 프로젝트에 Flyway 의존성 추가
- 두 프로젝트에 PostgreSQL용 Flyway 지원 의존성이 필요한지 확인 후 추가
- 두 프로젝트의 `spring.jpa.hibernate.ddl-auto`를 `validate`로 전환
- 두 프로젝트의 Flyway 설정을 `application.yml`에 추가
- `shop-core`에 `src/main/resources/db/migration/V1__init_schema.sql` 작성
  - `docs/entity/database_design.md`의 도메인 테이블을 반영
  - `CREATE EXTENSION IF NOT EXISTS citext` 포함
  - `created_at` / `updated_at` 기본값과 `updated_at` 트리거 포함
  - partial unique index, CHECK 제약, FK, 일반 인덱스 포함
  - Spring Modulith `event_publication` 테이블 포함
- `shop-core`에서 Spring Modulith JDBC 스키마 자동 초기화를 비활성화
  - `spring.modulith.events.jdbc.schema-initialization.enabled=false`
- `notification`에 `src/main/resources/db/migration/V1__init_schema.sql` 작성
  - notification이 소유한 테이블만 포함
  - 멱등 처리 이력, 알림 발송 이력, 실패/DLQ 추적 테이블은 구현된 범위에 맞춰 포함
  - `shop-core` 도메인 테이블을 복제하지 않는다
- 적용된 마이그레이션은 수정하지 않고 이후 변경은 `V2__`, `V3__`로 추가하는 규칙을 문서 또는 주석으로 남긴다
- 테스트 프로파일에서 Flyway/JPA 자동설정 제외 정책을 유지할지, 마이그레이션 검증용 별도 프로파일을 둘지 결정한다
- 관련 테스트를 작성하거나 기존 컨텍스트 테스트가 깨지지 않도록 보강한다

## Constraints
- `docs/entity/database_design.md`와 다른 스키마를 만들 경우 작업 문서 또는 SQL 주석에 이유를 남긴다
- Hibernate `ddl-auto=create`, `update`를 유지하지 않는다
- Flyway와 Hibernate가 동시에 스키마를 생성하게 만들지 않는다
- `event_publication`은 Flyway가 소유하며 Spring Modulith 자동 초기화에 맡기지 않는다
- `created_at` / `updated_at`은 DB 기본값과 트리거가 소유한다
- JPA Entity에서 DB 소유 시간 컬럼을 직접 갱신하지 않는다
- PostgreSQL 네이티브 ENUM 대신 `varchar + CHECK`를 사용한다
- 금액 컬럼은 `numeric(12,2)`로 정의한다
- 시각 컬럼은 `timestamptz`로 정의한다
- notification DB에 shop-core 도메인 데이터를 복제하지 않는다
- 적용된 Flyway 마이그레이션 파일을 나중에 수정하지 않는다

## Files
- `shop-core/build.gradle`
- `shop-core/src/main/resources/application.yml`
- `shop-core/src/test/resources/application.yml`
- `shop-core/src/main/resources/db/migration/V1__init_schema.sql`
- `shop-core/src/test/java/com/shop/shop/**`
- `notification/build.gradle`
- `notification/src/main/resources/application.yml`
- `notification/src/test/resources/application.yml`
- `notification/src/main/resources/db/migration/V1__init_schema.sql`
- `notification/src/test/java/com/shop/notification/**`
- `docs/entity/database_design.md`

## Acceptance Criteria
- 두 프로젝트가 Flyway 의존성을 가진다
- 두 프로젝트의 운영/개발 설정에서 `ddl-auto=validate`가 적용된다
- `shop-core`의 V1 마이그레이션이 `docs/entity/database_design.md`의 핵심 테이블, 제약, 인덱스, 트리거를 반영한다
- `shop-core`의 V1 마이그레이션에 `event_publication` 테이블이 포함된다
- Spring Modulith JDBC 스키마 자동 초기화가 비활성화되어 있다
- `notification`의 V1 마이그레이션은 notification 소유 테이블만 생성한다
- 깨끗한 로컬 PostgreSQL에서 Flyway migration 후 애플리케이션 컨텍스트가 로드된다
- Hibernate validate가 Flyway로 생성된 스키마를 통과한다
- 기존 테스트가 통과한다
- DB 공유, 동기 호출, 이벤트 계약 변경이 발생하지 않는다

## Test
- `./gradlew test` (`shop-core/`)
- `./gradlew test` (`notification/`)
- 권장 로컬 검증
  - `docker compose -f docker/shop/docker-compose.yml up -d`
  - `./gradlew flywayMigrate` 또는 애플리케이션 기동 시 Flyway 자동 실행 확인 (`shop-core/`)
  - `./gradlew flywayMigrate` 또는 애플리케이션 기동 시 Flyway 자동 실행 확인 (`notification/`)
  - Hibernate validate 실패가 없는지 확인
- 권장 DB 확인
  - `docker exec`로 `shop-core` PostgreSQL 컨테이너에 접속해 도메인 테이블과 `event_publication` 생성 여부를 확인
  - `docker exec`로 `notification` PostgreSQL 컨테이너에 접속해 notification 소유 테이블만 생성됐는지 확인
  - 예시: `docker exec -it shop-core-postgres psql -U shop_core -d shop_core -c "\dt"`
  - 예시: `docker exec -it shop-notification-postgres psql -U notification -d notification -c "\dt"`

# 001 — BaseEntity 시간 컬럼 소유권 변경 (Revision 1)

- 대상 Task: `docs/tasks/backend/001-backend-shop-core-common-baseline.md`
- 대상 Plan: `docs/plans/backend/001-backend-shop-core-common-baseline-plan.md`
- 변경 적용 Task: `docs/tasks/backend/006-backend-shop-core-jwt-login-redis-role-hierarchy.md` (이 Task에서 실제 코드 교정 수행)
- 결정 일자: 2026-06-03
- 결정자: 사용자
- 목적: Task 001에서 `BaseEntity`의 `created_at`/`updated_at`을 **JPA auditing(앱 소유)** 로 구현한 초기 설계를, **DB 소유(트리거 + DEFAULT)** 로 변경한 사실을 기록한다.

---

## 결정 요약

| 항목 | 초기 설계 (Task 001) | 변경 결정 | 비고 |
|---|---|---|---|
| `created_at`/`updated_at` 소유 주체 | 애플리케이션 (Spring Data JPA auditing) | **데이터베이스** (`DEFAULT now()` + `set_updated_at()` 트리거) | shop-core 한정 |
| `BaseEntity` 매핑 | `@CreatedDate`/`@LastModifiedDate` + `@EntityListeners(AuditingEntityListener)` | `@Column(insertable=false, updatable=false)` 읽기 전용 | auditing 애너테이션 제거 |
| `JpaAuditingConfig` | `@EnableJpaAuditing` 구성 존재 | **삭제** (불필요) | shop-core 한정 |
| `BaseEntityTest` | AuditingHandler 기반 auditing 검증 | 읽기 전용 매핑 검증으로 수정 | — |
| notification `BaseEntity` | (Task 002에서 동일하게 auditing 사용) | **변경 없음** (의도적 유지) | 아래 "범위" 참조 |

---

## 1. 초기 설계 (Task 001)

Task 001은 "JPA auditing 설정이 필요하면 함께 구성"(Requirements)에 따라 `shop-core` `common.domain.BaseEntity`를 다음과 같이 구현했다.

```java
@MappedSuperclass
@EntityListeners(AuditingEntityListener.class)
public class BaseEntity {
    @CreatedDate  @Column(updatable = false) Instant createdAt;   // 앱이 채움
    @LastModifiedDate                         Instant updatedAt;   // 앱이 채움
}
```
- 시간 값의 주체가 **애플리케이션**(Spring Data JPA auditing)이다.
- 활성화를 위해 `common.config.JpaAuditingConfig`(`@EnableJpaAuditing`, `@ConditionalOnBean(DataSource.class)`)를 함께 두었다.

## 2. 변경 이유

이후 Task에서 스키마 정본과 인프라가 확정되며 초기 설계와 충돌이 드러났다.

1. **정본은 DB 소유로 명시**: `docs/entity/database_design.md`(컨벤션 §, §8)는 `created_at`/`updated_at`을 **DB의 `DEFAULT now()` + 트리거가 소유, 엔티티에서는 읽기 전용**으로 규정한다.
2. **Flyway V1이 DB 소유로 구현됨**: Task 004(Flyway 전환)에서 `V1__init_schema.sql`이 모든 도메인 테이블에 `created_at/updated_at timestamptz NOT NULL DEFAULT now()` + `set_updated_at()` 트리거를 생성했다. 즉 DB는 이미 시간 컬럼의 주인이다.
3. **공존 시 출처가 갈리는 결함**: 현재 상태(앱 auditing + DB 트리거)가 함께 동작하면,
   - **INSERT**: 앱 auditing이 `created_at`을 채워 보냄 → DB `DEFAULT now()` 미사용 → `created_at = 앱 시계`
   - **UPDATE**: 앱이 `updated_at`을 보내지만 `BEFORE UPDATE` 트리거가 `now()`로 덮어씀 → `updated_at = DB 시계`
   - → 한 행에서 생성/수정 시각의 **시계 출처가 불일치**(앱 시간 vs DB 시간)하는 어정쩡한 상태가 된다.
4. **정렬 적기**: 도메인 첫 Entity(`member.User`)가 Task 006에서 처음 등장한다. 첫 엔티티가 잘못된 패턴을 답습하기 전에 baseline을 바로잡는 것이 비용이 가장 낮다.

## 3. 변경 내용 (Task 006에서 적용)

`shop-core`에 한해 BaseEntity를 **DB 소유 읽기 전용**으로 교정한다.

```java
@MappedSuperclass
public class BaseEntity {
    @Column(name = "created_at", insertable = false, updatable = false) Instant createdAt;
    @Column(name = "updated_at", insertable = false, updatable = false) Instant updatedAt;
}
```
- `@CreatedDate`/`@LastModifiedDate`/`@EntityListeners(AuditingEntityListener)` 제거.
- INSERT는 DB `DEFAULT now()`, UPDATE는 `set_updated_at()` 트리거가 단일 소유 → 시계 출처 일관(DB).
- `common.config.JpaAuditingConfig`(`@EnableJpaAuditing`) **삭제** — auditing 불필요.
- `common.domain.BaseEntityTest`를 auditing 검증 → 읽기 전용 매핑 검증(`@Column insertable=false/updatable=false`, auditing 애너테이션 부재, `@MappedSuperclass` 유지)으로 수정.

## 4. 범위 (적용 / 비적용)

- **적용**: `shop-core`만. database_design.md가 shop-core 설계의 SSOT이며 DB 소유를 규정한다.
- **비적용(의도적 유지)**: `notification`의 `common.domain.BaseEntity`는 **앱 측 JPA auditing을 유지**한다.
  - 근거: Task 004 plan(§1.4)에서 notification은 자기 소유 테이블만 구조적으로 미러링하며, 시간 컬럼을 앱 auditing이 소유하는 것을 **의도적 deviation**으로 결정했다. notification `V1__init_schema.sql`(`processed_event`)에는 트리거를 두지 않고 앱이 시간을 채운다.
  - 즉 두 프로젝트의 시간 컬럼 소유 정책이 다름은 의도된 것이며, 본 Revision은 shop-core만 변경한다.

## 5. 영향받는 산출물

| 파일 | 변경 |
|---|---|
| `shop-core/.../common/domain/BaseEntity.java` | 읽기 전용 매핑으로 교정 |
| `shop-core/.../common/config/JpaAuditingConfig.java` | 삭제 |
| `shop-core/.../common/domain/BaseEntityTest.java` | 읽기 전용 매핑 검증으로 수정 |

## 6. 후속 액션

- [x] 본 Revision 기록 작성
- [ ] Task 006 구현에서 위 교정 반영 (backend-implementor)
- [ ] 향후 모든 shop-core 도메인 Entity는 `BaseEntity` 상속만으로 DB 소유 시간 컬럼을 자동 적용 (별도 auditing 설정 불필요)

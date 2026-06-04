# 001 — 트레이드오프 결정 (Revision 1)

- 대상 Plan: `docs/plans/001-infra-shop-core-dependencies-plan.md`
- 결정 일자: 2026-05-30
- 결정자: 사용자
- 목적: Plan에서 제시한 6개 트레이드오프 선택지에 대해 채택안을 확정하고, 원안과 다른 항목을 Plan에 반영하기 위한 기록

---

## 결정 요약

| # | 항목 | 원안 | 결정 | Plan 반영 여부 |
|---|---|---|---|---|
| 1 | 테스트 인프라 | 자동 설정 제외 | 자동 설정 제외 (유지) | 변경 없음 |
| 2 | Modulith 버전 관리 | BOM import | BOM import (유지) | 변경 없음 |
| 3 | thymeleaf-extras-springsecurity6 | 지금 포함 | 지금 포함 (유지) | 변경 없음 |
| 4 | `ddl-auto` | `validate` | **`create`** (개발 편의) → Flyway 도입 시 `validate` | **변경 필요** |
| 5 | 설정 파일 포맷 | `application.yml` | `application.yml` (유지) | 변경 없음 |
| 6 | EmbeddedKafka 도입 | 의존성만 추가 | 의존성만 추가 (유지) | 변경 없음 |

---

## 1. 테스트 인프라: 자동 설정 제외 (유지)

**채택 근거**
- 이 Task의 목표는 **의존성 조립 검증**이지 JPA/Kafka 실동작 검증이 아니다.
- 실동작 검증은 Phase 1 이벤트 워킹 스켈레톤 Task에서 Testcontainers 등으로 별도 도입한다.

**적용**
- `shop-core/src/test/resources/application.yml`에서 DataSource·JPA·Kafka·Modulith JPA Outbox 자동 설정 제외.

---

## 2. Spring Modulith 버전 관리: BOM import (유지)

**채택 근거**
- 단일 모듈 의존성 충돌 시 영향 범위가 더 커진다는 점을 인지하나, `core` + `jpa` + `test` 세 모듈을 동시에 쓰는 구성에서는 **단일 버전 관리원**이 정합성·유지보수성 측면에서 더 안전하다.
- 모듈 추가/업그레이드 시 한 곳(BOM 버전 한 줄)만 수정.

**리스크 대응**
- 호환성 문제 발생 시 BOM 버전 한 줄 변경으로 일괄 롤백 가능.
- 향후 Modulith ↔ Boot 호환성 변동에 대비해 BOM 버전은 Plan에 명시(`1.3.1`).

---

## 3. `thymeleaf-extras-springsecurity6` 지금 포함 (유지)

**채택 근거**
- 회원 가입/로그인 화면이 만들어지자마자 `sec:authorize`·`${#authentication}` 표현이 필요해진다.
- Boot BOM이 관리하는 라이브러리라 충돌 위험 없음.
- 후속 화면 Task의 의존성 추가 PR 1건 절약.

---

## 4. `ddl-auto`: `validate` → **`create`로 변경**

**채택 근거**
- Flyway 도입은 별도 후속 Task로 예정되어 있다.
- 도입 전까지는 **개발 편의**(엔티티 추가/수정 시 즉시 스키마 반영)를 우선시한다.
- 마이그레이션 도구가 들어오는 시점에 `validate`로 전환.

**Plan에 반영할 사항**
- `shop-core/src/main/resources/application.yml`
  - `spring.jpa.hibernate.ddl-auto`: `validate` → `create`
- Plan 본문 설명/트레이드오프 섹션 6-4 업데이트
- 완료 조건 체크리스트의 ddl-auto 관련 항목 갱신

**전환 시점 표식**
- Flyway 도입 Task의 Acceptance Criteria에 "`ddl-auto`를 `validate`로 전환한다"를 포함시켜야 한다.

**주의 사항**
- `create`는 부팅 시 기존 테이블을 **DROP 후 재생성**한다. 로컬 개발 DB의 데이터가 매 부팅마다 초기화됨을 전제로 한다.
- 운영 환경에 절대 적용 금지. 운영 배포 전(또는 Flyway 도입 시) `validate`로 반드시 전환.

---

## 5. 설정 파일 포맷: `application.yml` (유지)

**채택 근거**
- `spring.datasource.*`, `spring.jpa.*`, `spring.kafka.*` 등 중첩 prefix가 많아 yml의 가독성이 우월.
- 멀티-도큐먼트(`---`)로 profile 분리 시 파일 수 증가 없이 관리 가능.

---

## 6. EmbeddedKafka: 의존성만 추가 (유지)

**채택 근거**
- 이 Task에는 발행할 이벤트가 없으므로 EmbeddedKafka로 검증할 대상이 없다.
- 의존성(`spring-kafka-test`)만 미리 잡아두면 후속 Producer Task에서 즉시 `@EmbeddedKafka` 활용 가능.

---

## Plan 반영 변경 요약

| Plan 위치 | 변경 내용 |
|---|---|
| 섹션 2-2 `application.yml` 예시 | `ddl-auto: validate` → `ddl-auto: create` |
| 섹션 6-4 트레이드오프 본문 | "`validate` 채택" → "현 단계 `create` 채택, Flyway 도입 시 `validate` 전환" |
| 완료 조건 체크리스트 | `ddl-auto: create`로 표기 + Flyway Task 인계 항목 추가 |

---

## 후속 액션

- [x] Plan 파일에 ④ 결정 반영
- [ ] Flyway 도입 Task 정의 시 "`ddl-auto`를 `validate`로 전환" Acceptance Criteria 포함
- [ ] `backend-implementor`에 본 Revision과 Plan을 함께 전달

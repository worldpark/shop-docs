# 060. shop-core 상품 검색 — 풀 재색인·백필 잡(PG→ES bulk + alias swap 무중단 컷오버)

> 출처: ADR-011(상품 검색 Elasticsearch 보조 인덱스) 상품 검색 개선 이니셔티브 T4. ADR-011 결정 원칙 3 "풀 재색인·백필 잡을 1급 기능으로"의 구현 Task다.
> 범위 SSOT: 본 문서. 설계 결정은 docs/plans/backend/060-product-search-full-reindex-backfill-job-plan.md(후속)에 위임한다.
>
> ## 이니셔티브 Task 맵 (교차참조)
> - T0 backend/058 — pg_trgm + GIN(임시 브리지·영구 폴백).
> - T1 infra/006 — ES/OpenSearch 인프라(엔진·클라이언트·기동·연결).
> - T2+3 backend/059 — 색인 문서 스키마·Nori 매핑·인덱스 alias 정의 + 이벤트 기반 증분 indexer.
> - **T4 backend/060 = 본 Task** — 풀 재색인·백필(전량 적재).
> - T5+6 backend/061 — 검색 읽기(쿼리 API·랭킹·폴백·뷰).
> - 고정 결정(이니셔티브 공유): 자체호스팅 ES/OpenSearch + Nori / SoT=PG, ES=재생성 가능 보조 / 색인=Kafka 이벤트 기반(증분) / 1차 범위=형태소+랭킹.
> - **의존**: 본 Task는 T1(엔진·클라이언트)과 T2+3(인덱스 매핑·문서 스키마·alias 규약)을 **전제**한다. 본 Task는 그 매핑/스키마를 그대로 재사용해 새 버전 인덱스에 **전량 적재**한다(매핑·스키마를 본 Task가 새로 정의하지 않는다).
> - **증분 indexer(T2+3)와 상보 관계**: T2+3 indexer는 product 도메인 이벤트로 ES를 **증분** 갱신하고, 본 Task는 PG 전량을 **전량** 적재한다. 둘은 같은 매핑·같은 alias 규약 위에서 동작한다.

## Target
shop-core (product 모듈 + 재색인 트리거 진입점)

> **PG 전량 상품을 페이지네이션으로 읽어 ES 새 버전 인덱스에 bulk 색인한 뒤, alias swap으로 무중단 컷오버하는 잡**에 한정한다. 색인 문서 스키마·Nori 매핑·alias 규약(T2+3)과 ES 엔진·클라이언트(T1)는 **전제이며 본 Task가 정의/변경하지 않는다.** 검색 쿼리·랭킹·폴백·뷰(T5+6)는 범위 밖이다. 신규 Kafka 이벤트·notification 발송 없음(재색인은 내부 운영 작업).

---

## Goal
1. **풀 재색인 잡**: PG의 전량 상품(Product + 연관 ProductVariant·Category)을 **페이지네이션**으로 안정적으로 순회하며, T2+3가 정의한 색인 문서로 변환해 ES에 **bulk** 색인한다. 색인 대상 범위(노출 가능 status 한정 vs 전체)는 T5+6 조회 필터와 정합하도록 plan에서 확정한다.
2. **새 버전 인덱스 적재 후 alias swap(무중단 컷오버)**: 매번 **새 버전 인덱스**(예: products-vTIMESTAMP)를 생성해 전량 적재를 완료한 뒤, **read alias(예: products)를 원자적으로 새 인덱스로 전환**한다. 적재 진행 중에는 alias가 **기존(직전) 인덱스를 계속 가리켜** 부분 적재 인덱스를 검색에 노출하지 않는다. 컷오버 후 직전 인덱스 정리(삭제·보존 개수) 정책은 plan 확정.
3. **용도 3종 모두 지원**: (a) 초기 적재(빈 ES 부트스트랩), (b) 매핑/분석기 변경 시 재구축(새 매핑으로 새 인덱스 생성 후 전량 재적재 후 swap), (c) 드리프트 복구(증분 indexer 유실·DLQ 적체로 ES와 PG가 어긋났을 때 PG 권위로 전량 재생성). ADR-011 원칙 1·3(SoT=PG, 항상 재생성 가능)의 운영 안전망.
4. **멱등·재실행 안전**: 잡을 여러 번 실행해도 결과가 동일하다(새 인덱스에 전량 적재 후 swap이므로 부분 실행이 누적 오염되지 않는다). 진행 중 실패 시 alias는 **기존 인덱스를 유지**하고 미완성 새 인덱스는 정리 대상으로 남긴다(검색 영향 0).
5. **트리거 진입점 제공**: ADMIN 수동 트리거 / CLI·배치 / 스케줄 중 plan에서 확정한 방식으로 잡을 기동한다(아래 plan 결정 1).

## Context
- **전량 조회 출처(무변경 전제)**: product/repository/ProductRepository(JPA), product/domain/Product(BaseEntity 상속 — id/name/description/basePrice/status/category(LAZY ManyToOne)/ownerId/createdAt), product/domain/ProductVariant(BaseEntity 미상속 — sku/price/stock/isActive/optionValues), product/domain/Category. 본 Task는 이들에서 **읽기**만 한다(쓰기·스키마 변경 없음). 현재 ProductRepository에는 **전량 안정 순회용 메서드가 없다**(공개 목록 집계 3종 + 판매자 본인 목록 + countByStatusIn만 존재) → 전량 페이지네이션/스트리밍 조회 메서드 신규 추가가 필요할 수 있다(시그니처 plan 확정, 읽기 전용).
- **색인 문서·매핑·alias(T2+3 산출물 전제)**: 색인 문서 필드 구성(name 우선 description tag category 부스팅 등)·Nori 분석기 매핑·인덱스 네이밍/alias 규약·ES 클라이언트(T1)는 T2+3·T1이 소유한다. 본 Task는 그 **문서 변환기·인덱스 생성·alias 전환 API를 재사용**하고, 전량 적재 오케스트레이션(순회·bulk·진행·swap·정리)만 추가한다. T2+3가 alias swap·인덱스 생성 헬퍼를 노출하지 않으면 본 Task에서 그 인프라 호출을 어디에 둘지(공용 색인 어댑터로 추출 vs 본 잡 내부) plan 확정.
- **스케줄러/배치 선례**: payment/service/UnpaidOrderExpiryScheduler(@ConditionalOnProperty 활성 가드 + @Scheduled + SchedulerLeaderGuard.runIfLeader 다중 노드 리더 게이트 + 스케줄러/단위트랜잭션 빈 분리(self-invocation 차단) + 주문별 try/catch 격리). 리더 게이트는 common/concurrency/SchedulerLeaderGuard(best-effort, ADR-005 Task 035). 재색인을 스케줄/배치로 둘 경우 이 패턴을 따른다.
- **동시성 원칙(ADR-005)**: 단일 PostgreSQL 행 락이 정합 권위. 리더 게이트는 **다중 노드 중복 작업 축소(best-effort)** 목적이지 정합 보장이 아니다. 재색인 중복 실행 방지(동시에 두 노드가 같은 잡을 돌려 ES에 동시 bulk·alias 경합)가 필요한지 ADR-005 스케줄러 리더 게이트 선례로 plan에서 판단한다(아래 plan 결정 4).
- **레이어 규칙(architecture-rule)**: 진입점은 RestController to ServiceResponse to Service to Repository(ADMIN 트리거 시) 또는 Scheduler to Service to Repository(스케줄 시). 컨트롤러/스케줄러에 비즈니스 로직 금지. ServiceResponse는 REST 응답 조합 전용(스케줄러/이벤트에서 미사용). Consumer/Scheduler는 Repository 직접 호출 금지(forbidden-rule) → 전량 순회·bulk·swap은 Service 경계에 둔다.
- **모듈 경계(package-structure-rule)**: 도메인 6모듈 고정. 재색인은 **product 모듈 내부**에 둔다(상품 데이터 소유 모듈 — 신규 모듈 신설 사유 없음). ES 클라이언트/색인 어댑터의 모듈 배치는 T1·T2+3 결정을 따른다(본 Task가 신규 cross-module 의존을 만들지 않는다). ModularityTests/ArchUnit 그린 유지.
- **가상스레드 대비(CLAUDE.md)**: 직접 ThreadLocal 사용 금지. 블로킹 I/O(ES bulk HTTP, PG 조회)는 Service/Infrastructure 경계에 둔다.

## plan 확정 필요 (설계 결정 — 본 Task가 plan에 위임)
1. **트리거 방식**: ADMIN 수동 트리거(엔드포인트) / CLI·배치(ApplicationRunner 또는 Gradle/스크립트 진입) / 스케줄(@Scheduled 주기 또는 cron) 중 **확정**. 권장 1차: **ADMIN 수동 트리거 엔드포인트**(초기 적재·매핑 변경·드리프트 복구는 사람이 의도적으로 트리거하는 운영 작업 — 주기 자동 전량 재색인은 부하·비용 부담). 스케줄은 정기 드리프트 보정용으로 후속 검토(선택). 확정 방식에 따라 진입점 레이어(REST vs Scheduler)와 API Authorization 적용 여부가 갈린다.
2. **장시간 잡 실행 모델**: 전량 적재는 장시간(대용량 시 수십 초 수 분)이라 **HTTP 동기 응답으로 완주를 기다리면 타임아웃 위험**. (권장) 트리거는 **비동기 시작 + 즉시 202/작업 식별자 반환**, 진행 상태(시작/진행 건수/완료/실패)는 별도 조회 또는 로깅으로 노출. 동기 실행 허용 여부·진행 상태 노출 형태(로그만 vs 상태 조회 엔드포인트) plan 확정. ThreadLocal 회피·블로킹 I/O 경계(CLAUDE.md) 준수.
3. **전량 순회 방식**: keyset(seek) 페이지네이션(id 기준 WHERE id 초과 lastId ORDER BY id — OFFSET 깊은 페이지 열화 회피, 대용량 안정) vs Slice/Stream(@QueryHints fetch-size). 연관(ProductVariant·Category) 로딩으로 N+1 폭발을 막을 페치 전략(배치 fetch·별도 variant 일괄 조회·@BatchSize). 정확한 ProductRepository 신규 메서드 시그니처·페이지 크기·페치 전략 plan 확정.
4. **다중 노드/동시 실행 가드(중복 재색인 방지)**: 동시에 두 노드(또는 두 번 트리거)가 같은 잡을 돌리면 ES 동시 bulk·alias swap 경합·자원 낭비가 생긴다. **재실행 자체는 멱등(새 인덱스+swap)이라 정합은 깨지지 않지만**, 중복 실행 축소가 바람직하다. ADR-005 스케줄러 리더 게이트(SchedulerLeaderGuard.runIfLeader, best-effort) 선례를 참조해 (a) 게이트 적용 / (b) 재색인 진행 중 상태 플래그로 중복 트리거 거부 / (c) 가드 없음(멱등에 의존) 중 **확정**. 스케줄 방식이면 리더 게이트 권장(선례 정합). ADR-005 원칙대로 게이트 실패 시에도 정합이 깨지지 않음을 명시.
5. **alias·인덱스 네이밍/정리 정책**: 새 버전 인덱스 네이밍 규칙(T2+3 규약 준수), read alias 단일 vs read/write alias 분리(증분 indexer가 write alias로 쓰는 동안 본 Task가 새 인덱스로 swap하는 상호작용 — T2+3와 정합), swap 원자성(ES aliases actions로 add+remove 단일 호출), 컷오버 후 직전 인덱스 보존 개수·삭제 시점(롤백 여지 vs 디스크) plan 확정. **swap 규약은 T2+3 소유 — 본 Task는 그 규약을 따른다.** 본 Task에서 신규 정의가 필요한 부분만 plan에 명시.
6. **bulk 크기·백프레셔·타임아웃·실패 처리**: bulk 배치 크기(문서 수/바이트), bulk 부분 실패(일부 문서 거부) 시 처리(재시도·중단·로깅), bulk 요청 타임아웃, ES 부하 백프레셔(배치 간 간격·실패율 기반 스로틀). 진행 중 치명 실패 시 alias **미전환** 보장(부분 적재 인덱스 비노출) — 이 안전 동작의 정확한 실패 경계 plan 확정.
7. **색인 대상 범위**: 전체 상품 vs 노출 가능 status(ON_SALE/SOLD_OUT) 한정. T5+6 조회가 status 필터로 닫는다면(ADR-011 원칙 4) 전량 적재하고 조회에서 필터 vs 색인 시점에 비노출 status 제외 — T5+6 조회 모델과 정합하도록 확정. variant 가격/재고·category를 문서에 포함하는 형태는 T2+3 문서 스키마를 따른다.

## API Authorization
> docs/rules/api-authorization-rule.md 준수. **트리거를 ADMIN 엔드포인트로 두는 경우에만 적용**(plan 결정 1). CLI/배치/스케줄 방식이면 HTTP 엔드포인트가 없으므로 본 절은 비적용이며, 운영 트리거 접근 통제(쉘/배포 권한)로 대체됨을 plan에 명시한다.

| API | 공개 여부 | 최소 권한 | 상위 권한 허용 | 소유권 검사 | 비고 |
|---|---|---|---|---|---|
| POST /api/v1/admin/products/search-index/reindex (REST, plan 확정 시) | authenticated | ROLE_ADMIN | — | 불필요(전역 운영 작업) | 풀 재색인 잡 트리거(전량 PG to ES, alias swap). 비동기 시작 권장(202) |
| GET /api/v1/admin/products/search-index/status (REST, plan 확정 시 — 선택) | authenticated | ROLE_ADMIN | — | 불필요 | 재색인 진행/마지막 결과 조회(상태 노출 채택 시) |

> 경로는 예시이며 plan 확정. ADMIN 트리거 채택 시 /api/v1/admin 이하가 SecurityConfig에서 hasRole ADMIN로 이미 커버되는지 코드 대조 후 의도를 명시한다(신규 matcher 필요 여부 plan 확정). 소유권 검사 불필요 — 전역 운영 작업(특정 사용자 리소스 아님). 컨트롤러 권한 분기 금지(Spring Security 설정/method security로 처리).

## Requirements
### A. 풀 재색인 잡(Service)
- PG 전량 상품을 페이지네이션(또는 스트리밍)으로 순회하며 T2+3 색인 문서로 변환한다. 연관 ProductVariant·Category 로딩은 N+1을 피하는 페치 전략(plan 결정 3). 색인 대상 범위는 plan 결정 7.
- 변환된 문서를 ES에 **bulk** 색인한다(배치 크기·타임아웃·부분 실패 처리는 plan 결정 6). 매번 **새 버전 인덱스**를 생성해 적재한다(T2+3 매핑/네이밍 규약 사용).
- 전량 적재 완료 후 **read alias를 새 인덱스로 원자적 swap**(add new + remove old 단일 호출). swap 규약은 T2+3 소유 — 본 Task는 그 API를 호출한다.
- 컷오버 후 직전 인덱스 정리(plan 결정 5 — 보존 개수/삭제 시점).
- 진행(시작/처리 건수/완료/실패) 로깅. 진행 상태 노출 형태는 plan 결정 2.

### B. 안전·멱등
- **부분 적재 비노출**: 적재 진행 중·실패 중 alias는 **기존 인덱스를 유지**한다. swap은 전량 적재가 성공적으로 끝난 뒤에만 수행한다(실패 시 미전환).
- **재실행 멱등**: 잡을 N번 실행해도 결과가 동일(새 인덱스 적재 후 swap이므로 직전 실행의 부분 산출물이 누적 오염되지 않음). 실패로 남은 미완성 새 인덱스는 정리 대상(다음 실행 또는 정리 정책이 제거).
- **중복 실행 가드**: plan 결정 4(리더 게이트 / 진행 상태 플래그 / 멱등 의존 중 택1). 게이트 실패 시에도 정합 불변(ADR-005).

### C. 진입점(트리거)
- plan 결정 1 방식으로 잡 기동. ADMIN REST면 API Authorization 적용 + 비동기 시작 권장(plan 결정 2). 스케줄이면 @ConditionalOnProperty 활성 가드 + SchedulerLeaderGuard(UnpaidOrderExpiryScheduler 선례). CLI/배치면 ApplicationRunner·프로파일 가드로 일반 기동 시 자동 실행 방지.
- 진입점은 비즈니스 로직 금지(레이어 규칙) — 순회·bulk·swap·정리는 Service 경계.

### D. 공통
- 읽기 전용(PG): 본 Task는 상품 데이터를 **쓰지 않는다**(스키마·Entity·마이그레이션 변경 없음). PG는 SoT, ES는 사본(ADR-011). 신규 Kafka 이벤트·notification 없음.
- DTO/스칼라만 모듈 경계로 노출. Entity를 ES 색인 어댑터·응답으로 직접 흘리지 않는다(T2+3 문서 DTO 사용, architecture-rule).
- ThreadLocal 직접 사용 금지, 블로킹 I/O는 Service/Infra 경계(CLAUDE.md).

## Constraints
- **범위 경계(엄수)**:
  - 범위 밖 — T1: ES/OpenSearch 엔진·클라이언트·연결(전제, 본 Task가 정의 안 함).
  - 범위 밖 — T2+3: 색인 문서 스키마·Nori 매핑·인덱스/alias **정의**·이벤트 기반 **증분** indexer(본 Task는 그 매핑/스키마/alias 규약을 **재사용해 전량 적재**만 한다).
  - 범위 밖 — T5+6: 검색 쿼리 API·랭킹·장애 폴백·검색 뷰.
  - 본 Task 범위 — **풀 재색인·백필 오케스트레이션**(전량 순회·bulk·새 인덱스 적재·alias swap·정리·트리거)만.
- **PG SoT·무변경**: PG 상품 스키마/Entity/마이그레이션 변경 없음. ProductRepository에 **읽기 전용 전량 순회 메서드 추가만** 허용(plan 결정 3). 쓰기 경로·기존 공개 목록 쿼리 무변경(회귀 금지).
- **ES=재생성 가능 사본(ADR-011)**: ES 인덱스는 권위가 아니며 본 잡으로 PG에서 항상 전량 재생성 가능해야 한다. 부분 적재 인덱스를 검색에 노출하지 않는다(alias swap 게이트).
- **동시성(ADR-005)**: 리더 게이트는 best-effort(중복 작업 축소). 정합은 멱등(새 인덱스+swap)이 보장 — 게이트 실패·중복 실행에도 검색 정합이 깨지지 않는다. 도메인 행 락에 분산락 덧씌우지 않는다.
- **레이어/모듈/금지**: 컨트롤러·스케줄러 비즈니스 로직 금지, Scheduler/Consumer Repository 직접 호출 금지(Service 경유), Entity 응답 직접 노출 금지(forbidden-rule). product 모듈 내부 배치, 신규 cross-module 의존 0, ModularityTests/ArchUnit 그린.
- **이벤트/notification 무변경**: 재색인은 내부 운영 작업 — 신규 Kafka 이벤트·notification·event-catalog.md/§5 무변경.
- **부하 안전**: 전량 bulk가 ES·PG에 과부하를 주지 않도록 배치 크기·백프레셔·타임아웃(plan 결정 6). 운영 트리거 시 부하 영향을 운영 문서/로그에 남긴다.

## Files
> 정확 경로/시그니처/모듈 배치는 plan 확정. 아래는 선례 대조 기준 예시(product 모듈 내부 배치 가정, ADMIN REST 트리거 가정).
### 신규 (backend-implementor)
- product/service/ProductSearchReindexService.java — 전량 순회 후 문서 변환 후 bulk 후 새 인덱스 적재 후 alias swap 후 정리 오케스트레이션. T2+3 색인 어댑터(문서 변환·인덱스 생성·alias swap)와 T1 ES 클라이언트를 **재사용**(직접 ES 매핑/클라이언트 정의 금지). 진행 로깅·실패 시 swap 미전환 보장.
- product/controller/AdminProductSearchIndexRestController.java(트리거가 ADMIN REST일 때) — POST /api/v1/admin/products/search-index/reindex(비동기 시작·202), 선택 GET .../status. ProductSearchIndexServiceResponse 경유(ServiceResponse는 REST 응답 조합 전용). 비즈니스 로직 금지.
- (트리거가 스케줄일 때, 대안) product/service/ProductSearchReindexScheduler.java — @ConditionalOnProperty 활성 가드 + @Scheduled + SchedulerLeaderGuard.runIfLeader(UnpaidOrderExpiryScheduler 선례). 스케줄러/단위트랜잭션 빈 분리.
- (트리거가 CLI/배치일 때, 대안) ApplicationRunner 또는 배치 진입 — 프로파일/프로퍼티 가드로 일반 기동 시 자동 실행 방지.
- product/dto/** — 재색인 결과/진행 상태 DTO(시작/처리 건수/완료/실패 — 상태 노출 채택 시).
### 수정 (backend-implementor)
- product/repository/ProductRepository.java — 전량 안정 순회용 **읽기 전용** 메서드 추가(예: keyset 페이지네이션 findForReindexAfter(lastId, status범위, limit) 또는 Stream/Slice). 정확 시그니처·페치 전략 plan 확정. 기존 쿼리 무변경.
- (트리거가 ADMIN REST이고 신규 matcher 필요 시) security/SecurityConfig.java — /api/v1/admin 이하가 기존에 hasRole ADMIN 커버하면 무변경(코드 대조 후 의도 명시), 미커버 시 matcher 추가.
### 무변경(재사용/전제)
- T1 ES 클라이언트·연결, T2+3 색인 문서 변환기·Nori 매핑·인덱스 생성·alias swap 헬퍼(전제·재사용), Product/ProductVariant/Category Entity·PG 스키마·마이그레이션, 공개 목록 쿼리, common/concurrency/SchedulerLeaderGuard(스케줄 채택 시 재사용), event-catalog.md/§5·notification 전부.

## Acceptance Criteria
- 빈 ES(또는 기존 인덱스 존재) 상태에서 풀 재색인 잡을 실행하면 PG 전량 상품이 새 버전 인덱스에 bulk 색인되고, 완료 후 read alias가 새 인덱스를 가리킨다(검색 표면이 전량을 본다).
- 적재 **진행 중**에는 alias가 **기존 인덱스를 유지**해 부분 적재 인덱스가 검색에 노출되지 않는다. 적재 **중간 실패** 시 alias가 전환되지 않고(기존 인덱스 유지) 검색 영향이 0이다.
- 잡을 **두 번 연속 실행**해도 최종 ES 상태가 동일하다(멱등 — 새 인덱스+swap, 직전 부분 산출물 누적 오염 없음). 실패로 남은 미완성 인덱스는 정리 정책으로 제거된다.
- (매핑 변경 시나리오) 새 매핑으로 새 인덱스를 만들어 전량 재적재 후 swap하면 무중단으로 새 매핑이 활성화된다.
- (드리프트 복구 시나리오) ES와 PG가 어긋난 상태에서 잡을 실행하면 PG 권위로 ES가 PG와 일치하게 재생성된다.
- 트리거(plan 확정 방식)가 인가/가드 정합하다 — ADMIN REST면 비ADMIN 차단(403)·비로그인 401, 장시간 잡이 트리거 응답을 블로킹하지 않는다(비동기 시작 채택 시). 스케줄이면 비리더 노드 skip·@ConditionalOnProperty 비활성 시 미실행.
- PG 상품 스키마/Entity/마이그레이션·공개 목록 쿼리·이벤트·notification이 무변경이다(읽기 전용). ModularityTests/ArchUnit·풀 스위트 그린.

## Test
> docs/rules/testing-rule.md + verification-gate-rule.md. ES 동작은 단위·MockMvc로 검증 불가(인덱스 생성·bulk·alias swap 실동작) → **Testcontainers(ES/OpenSearch)** 통합으로 PG to ES 전량 적재·alias 전환·재실행 멱등을 검증한다. ES Testcontainer 운영 주의(이미지·기동 시간·test 인프라 비의존 원칙과의 분리)는 T1과 정합하도록 plan에서 배치한다(별도 태스크/태그 가능 — testing-rule 인프라 비의존 원칙).
- **단위(Mockito)**: 순회 후 문서 변환 매핑(색인 대상 status 범위 필터, variant/category 합성 — T2+3 문서 스키마 준수), bulk 부분 실패 처리 분기, swap 미전환(중간 실패 시 alias 전환 호출 안 함) 분기, 진행/결과 DTO 조합. ES 어댑터·클라이언트는 mock.
- **통합(Testcontainers — ES + PostgreSQL)**:
  - PG에 상품 N건 시드 후 풀 재색인 후 ES 새 인덱스에 N건 적재 + read alias가 새 인덱스를 가리킴.
  - 적재 중간 강제 실패 후 alias가 **기존 인덱스 유지**(부분 적재 인덱스 비노출), 검색 영향 0.
  - **재실행 멱등**: 잡 2회 연속 실행 후 최종 ES 문서 수·내용 동일, alias가 마지막 새 인덱스 가리킴, 직전 인덱스 정리 정책대로.
  - 매핑 변경 재구축: 새 인덱스 매핑이 swap 후 활성.
  - keyset/스트리밍 전량 순회가 누락/중복 없이 전량을 적재(경계: 페이지 크기 배수·마지막 페이지).
- **Security/REST(MockMvc, ADMIN 트리거 채택 시)**: reindex 트리거 ADMIN 200/202 / CONSUMER 403 / 비로그인 401. status 조회(있으면) 동일 인가. 비동기 시작이면 트리거가 즉시 응답(완주 비대기) 검증.
- **스케줄 채택 시**: SchedulerLeaderGuard로 비리더 노드 skip, @ConditionalOnProperty 비활성 시 빈 미등록(UnpaidOrderExpiryScheduler 선례 테스트 형식).
- **회귀**: 공개 상품 목록 쿼리(latest/priceAsc/priceDesc)·판매자 목록·countByStatusIn 무변경 그린. PG 쓰기 경로·스키마·이벤트·notification 회귀 0. 메인 에이전트가 ./gradlew test 풀 그린 + Modulith verify를 자기 눈으로 확인(verification-gate-rule). ES Testcontainer 통합이 일반 test 인프라 비의존 원칙과 충돌하면 분리 태스크로 두고 실행/판정 주체를 명시.

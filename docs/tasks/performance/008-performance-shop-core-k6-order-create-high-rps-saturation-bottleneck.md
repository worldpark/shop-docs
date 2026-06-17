# 008. shop-core order-create 분산 고RPS 천장·병목 탐색 (saturation + 서버측 메트릭)

> 출처: `docs/report/performance/002-order-create-multi-variant-distribution-measurement.md` §4.2·§5 후속. 분산(N=50) stress가 **200rps에서도 미포화(p95 21ms·dropped 0)** → "진짜 천장"이 200rps 위라 미도달. 일반(분산) 트래픽의 **실제 처리량 천장과 병목(풀/CPU/DB)** 을 찾는다.
> 참고 방법론: `docs/report/performance/001-virtual-thread-ab-measurement.md`(풀 스윕 + 서버측 메트릭 + CPU 공유 주의 + 다회).
> 관련: Task 007(다중 variant 분배 — 본 Task는 그 분산 시드를 전제로 가압), 로드맵 stress(Task 003).

## 계승하는 결정 (재논의 금지)
- **도구/타겟/환경/출력**: k6 / 외부 앱 타겟 `BASE_URL` / docker-compose 실 스택 / summary+JSON(`SUMMARY_EXPORT_PATH` 토큰 제외). Task 001~003·007 그대로.
- **분산 전제**: 본 Task는 반드시 **`ORDER_VARIANT_COUNT≥50`(Task 007 분배)** 로 가압한다. 단일 variant는 행 락 산물(report 002)이라 "일반 트래픽 천장"이 아니다.
- **앱 Java/빌드 무변경**: k6 자산(JS) + 측정 오케스트레이션 + (필요 시) actuator 노출/풀 크기 **설정·env**만. Java 코드·Thymeleaf 미수정. 실제 최적화(풀 상향 확정·락 창 단축·아키텍처)는 **본 Task 결과가 가리키는 별도 Task**.

## 배경 (report 002 확정)
- 분산(N=50) stress(50→200rps)가 p95 21ms·dropped 0으로 **완주** → 200rps에서 풀·CPU·DB 어느 것도 포화 안 됨. 진짜 천장 미도달.
- 따라서 "성능 개선"의 첫 작업은 코드 최적화가 아니라 **천장·병목 위치 확정**이다. 모르는 병목은 못 고친다(report 002 §5).
- 기존 stress는 200rps가 상한이고, **부하 중 서버측 메트릭(hikari/threads/CPU) 수집이 미수행**(report 002 §4.2 명시 공백)이라 병목 분류 불가.

## Target
- `profiles/`(또는 `lib/config.js` PROFILES): **고RPS saturation 프로파일** 신규 — ramping-arrival-rate로 200rps를 넘어 점증(피크 env 튜닝). dropped 급증/p95 무릎이 나오는 RPS = 천장.
- `perf/k6/`(또는 `perf/`): **부하 중 서버측 메트릭 스크랩 스크립트**(actuator/prometheus 폴링 → 타임시리즈 CSV).
- 산출물: 천장 RPS + 병목 분류(풀/CPU/DB) + 리포트 `docs/report/performance/003-...`.

## Goal
분산 order-create를 200rps 위로 점증 가압해 **(1) dropped/p95 무릎으로 실제 처리량 천장 RPS를 찾고**, **(2) 부하 중 서버측 메트릭으로 병목을 풀/CPU/DB로 분류**한다. 이 결과가 다음 최적화 작업(풀 상향이냐, 전용 perf 환경 재측정이냐, 다른 레버냐)을 **게이팅**한다.

## 범위 (Scope)
### 1. 고RPS saturation 프로파일 (k6 자산)
- `ramping-arrival-rate` executor, 200rps를 넘어 점증(예 100→200→300→400→500→600rps, 각 30~45s + 쿨다운). **피크/스텝은 env 튜닝**(`SATURATE_PEAK_RPS` 등) — 천장이 예상 위/아래일 때 조정.
- `preAllocatedVUs`/`maxVUs`를 충분히(예 maxVUs 300~500) — 고RPS에서 VU 풀 자체가 인위적 병목이 되지 않게(단 무한정 금지, 메모리 가드).
- thresholds: stress와 동일하게 진단용(느슨) — `order_5xx==0`만 게이트, p95/dropped는 측정 대상(곡선).
- **분산 전제**: 본 프로파일은 `ORDER_VARIANT_COUNT≥50`과 함께만 의미. README에 명시.
- 시드 buyer 수: arrival-rate maxVUs까지 매핑되도록 `setupSeed`가 maxVUs만큼 buyer 시드(Task 002 선례 — 수량만 프로파일 구동).

### 2. 부하 중 서버측 메트릭 스크랩 (측정 하니스)
- `/actuator/prometheus`를 ~2~5s 간격 폴링해 타임스탬프와 함께 CSV로 적재하는 경량 스크립트(bash/python — 신규 무거운 의존 금지). 수집 지표:
  - **풀**: `hikaricp_connections_active`, `hikaricp_connections_pending`(대기 = 풀 포화 신호), `hikaricp_connections_max`, `hikaricp_connections_acquire`(획득 지연).
  - **스레드**: `jvm_threads_live_threads`, `jvm_threads_peak_threads`.
  - **CPU**: `process_cpu_usage`, `system_cpu_usage`.
  - (선택) `http_server_requests_seconds`(서버측 p95) — k6 클라이언트측과 교차.
- **actuator 노출 확인**: `/actuator/prometheus`가 노출됐는지 점검. 미노출 시 **env/설정으로 노출**(`MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE=health,prometheus` 등 런타임 — Java 코드 무변경). plan에서 현행 확인.

### 3. 병목 분류 — 풀 스윕 (report 001 방법)
- 동일 고RPS 프로파일을 **풀 크기 스윕**(`SHOP_CORE_HIKARI_MAX_POOL`=10 vs 30 vs 50, PG max_connections 미만)으로 각 측정(셀마다 앱 재기동 — report 001 선례).
  - throughput이 풀과 함께 **오르면 풀-바운드** → 풀 상향이 레버(backlog 3순위).
  - 풀을 늘려도 **평탄하면 CPU/DB-바운드** → `process_cpu_usage`≈1.0이면 CPU(개발 머신 공유 → **전용 perf 환경 재측정 필요**), 아니면 DB(쿼리/락).
- 각 셀 다회(3런+) — 단일 런 변동(±10~30%, report 001 §7) 회피, 분포 비중첩으로 확정.

### 4. 산출물
- 천장 RPS(dropped 급증/p95 무릎 직전 RPS) + 병목 분류 + 풀 스윕 표 + 서버측 타임시리즈 발췌.
- 리포트 `docs/report/performance/003-order-create-saturation-bottleneck.md`. baseline JSON `baselines/order-create-saturate-*.json`(대표 런).
- **다음 작업 권고**: 풀-바운드→풀 상향 task / CPU-바운드→전용 perf 환경 task / DB-바운드→쿼리·락 분석.

## Non-goals (본 Task 결과가 게이팅)
- **실제 최적화 착수** — 풀 상향 확정, Hibernate 배칭·락 창 단축(1순위), 아키텍처(4순위)는 본 Task가 병목을 가리킨 뒤 별도 Task. 여기선 **풀 스윕은 병목 분류 수단**일 뿐 운영값 확정 아님.
- **단일 핫-SKU 경로**(ORDER_VARIANT_COUNT=1) — report 002에서 별도 결론. 본 Task는 분산(일반 트래픽) 전용.
- **전용 perf 환경 구축** — CPU-바운드로 판명될 때 별도. 본 Task는 현 개발 머신에서 상대·분류까지.
- 가상스레드 — report 001에서 throughput 지렛대 아님 확정.
- nightly 자동화·TSDB·Grafana 대시보드 — 보류(스크랩 CSV로 충분).

## 예외/오류 처리 전략
- **VU 풀 인위적 병목**: 고RPS에서 maxVUs가 작으면 dropped가 "앱 한계"가 아니라 "VU 부족"으로 오염. maxVUs를 충분히(메모리 가드 내) + dropped 원인을 stdout `Insufficient VUs` 경고로 구분.
- **커넥션 소진/좀비 앱**: 측정 전 떠 있는 앱 인스턴스 1개만 유지(중복 인스턴스가 PG 커넥션·DB 간섭 → 오염). [[k6-perf-baseline-needs-clean-db]] + 깨끗한 DB TRUNCATE.
- **notification 메일 사고**: signup→환영메일이 실 SMTP 난타하지 않게 notification log 모드/미기동([[perf-test-notification-must-be-log-mode]]).
- **고RPS 재고/시드**: 분산이라 행당 부하↓이나 고RPS×시간이 variant 재고를 넘지 않게 `VARIANT_STOCK` 점검.

## 검증 방법
- **천장 식별**: saturation 런 stdout/JSON에서 dropped_iterations가 급증 시작하는 RPS·p95 무릎을 특정(stress knee 판정 선례 — README §5-2).
- **병목 분류 근거**: 풀 스윕 throughput 곡선(풀-바운드 여부) + 서버측 타임시리즈(`hikaricp_connections_pending>0` 지속=풀 포화 / `process_cpu_usage`≈1.0=CPU). **k6 지표 단독이 아니라 서버측과 교차**.
- **order_5xx==0**: 고부하라도 락은 느려질 뿐 5xx 붕괴 없어야 함.
- **다회 분포**: 천장·풀 스윕 결론은 3런+ 비중첩으로(단발 금지).
- **재현 절차**: README에 saturation 실행 + 스크랩 + 풀 스윕 절차 추가.
- Java 빌드 무관 — `./gradlew test` 게이트 아님.

## 트레이드오프
- **고RPS 피크값**: 너무 낮으면 미포화(천장 못 찾음), 너무 높으면 VU 폭증·머신 마비. env 튜닝으로 무릎 주변을 좁힌다(첫 런 광역 → 좁혀 재런).
- **풀 스윕 범위**: 10/30/50 3점이면 풀-바운드 여부 판별 충분(report 001은 10/50 2점으로 CPU-바운드 결론). PG max_connections(기본 100) 미만 유지.
- **개발 머신 한계**: k6·앱·PG CPU 공유라 절대 천장은 비대표적. **병목 "분류"는 유효**하되, CPU-바운드면 절대 천장은 전용 환경에서 재측정해야 운영값이 된다(report 001 ★ 동일).

## 참고
- 동기 리포트: `docs/report/performance/002-order-create-multi-variant-distribution-measurement.md`(§4.2 미포화·§5 후속).
- 방법론: `docs/report/performance/001-virtual-thread-ab-measurement.md`(§2 풀 스윕·서버측 메트릭, §7 운영 메모 — 다회·gradle 데몬·VT 판정).
- 하니스: `shop-core/perf/k6/{lib/config.js,lib/seed.js,scenarios/order-create.js,profiles/*.js,README.md}`, Task 007 분배(`ORDER_VARIANT_COUNT`).
- 관측성: ADR-010(Micrometer/Prometheus actuator). 풀 토글 env `SHOP_CORE_HIKARI_MAX_POOL`, VT 토글 `shop.threads.virtual.enabled`(본 Task 무관).
- 핫패스(측정 대상, 무수정): `OrderService.createOrderTx`, `InventoryStockPortImpl.decrease`.
- 구현 담당: `k6-implementor`(프로파일·스크랩 스크립트·README), 측정 오케스트레이션은 메인.

## 후속 (본 Task 결과가 게이팅)
- **풀-바운드** → 풀 상향 운영값 확정 task(backlog 3순위) + PG max_connections 정합.
- **CPU-바운드** → 전용 perf 환경(부하발생기·앱·DB 분리) 재측정 task → 그 후 진짜 천장 기준 용량 산정.
- **DB-바운드(쿼리/락)** → 락 창 단축(backlog 1순위: Hibernate 배칭·락-후 쿼리 정리) 또는 인덱스/쿼리 분석 task.

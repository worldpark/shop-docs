# Plan 008. order-create 분산 고RPS 천장·병목 탐색

> 대상 Task: `docs/tasks/performance/008-performance-shop-core-k6-order-create-high-rps-saturation-bottleneck.md`
> 범위: k6 자산(config.js의 saturate 프로파일) + 서버측 메트릭 스크랩 스크립트 + README. 앱 Java/빌드 무변경. 측정(saturate 런·풀 스윕·다회)은 온디맨드 라이브 스텝.
> 순서: k6-implementor(프로파일 + 스크랩 스크립트 + README) → reviewer → (온디맨드) saturate 측정 + 풀 스윕 → 병목 분류 리포트(report/performance/003).

## 0. 확정 사실 (코드 검증됨)
- **actuator `/actuator/prometheus` 이미 노출**(`application.yml:166` `include: ${SHOP_CORE_MGMT_ENDPOINTS:health,info,prometheus}`) → **노출 변경 불필요**. 스크랩 스크립트가 바로 폴링 가능.
- `scenarios/order-create.js`는 `PROFILES[PROFILE]`를 읽고 `buildOptions`가 **`ramping-arrival-rate` kind를 이미 처리**(stress와 동일 경로). → `PROFILES.saturate` 추가만으로 `-e PROFILE=saturate` 동작(시나리오 무수정).
- `PROFILES`(config.js:269~)에 smoke/load/stress/conc 존재. stress=ramping(50→200rps, maxVUs 200). saturate는 이를 200rps 위로 확장.
- Task 007 분배: `data.variantIds[(__VU-1+__ITER)%N]`, `ORDER_VARIANT_COUNT`(기본 1). **본 측정은 N≥50 전제**.
- 풀 토글 env `SHOP_CORE_HIKARI_MAX_POOL`(`application.yml:14`, 기본 10), PG max_connections 기본 100. VT 빈은 본 Task 무관(기본 off).
- 시드: `setupSeed(buyerCount)`가 `p.maxVUs||p.vus`만큼 buyer 생성(order-create.js setup) → saturate maxVUs를 충분히 두면 buyer도 그만큼 시드됨.

## 1. saturate 프로파일 (`lib/config.js` — k6 자산)
- `PROFILES.saturate` 추가:
  - `kind: 'ramping-arrival-rate'`, `timeUnit: '1s'`.
  - **stages를 env 피크로 구성**: `SATURATE_PEAK_RPS`(기본 600)까지 점증. 예 100→200→300→400→500→peak(각 30~45s) + `{target:0, duration:'15s'}` 쿨다운. peak를 env로 받아 stages를 동적 생성(헬퍼 함수, 결정적 — random 미사용).
    - 1차 광역 탐색용 기본 stages, 무릎 좁히면 `SATURATE_PEAK_RPS`/스텝 조정.
  - `preAllocatedVUs`(예 100)·`maxVUs`(예 400) — 고RPS에서 VU 풀이 인위적 병목이 되지 않게 충분히. **메모리 가드**: maxVUs 상한 명시(무한정 금지), `Insufficient VUs` 경고로 VU 부족 vs 앱 한계 구분.
  - `thresholds: SATURATE_THRESHOLDS` — 진단용(느슨): `order_5xx: count==0`만 게이트. `http_req_duration`/`dropped_iterations` 임계 없음(곡선 측정). stress thresholds 재사용 또는 동형 신설.
- (선택) `profiles/saturate.js` 엔트리 파일(load.js/stress.js 대칭) — 필수 아님(order-create.js가 PROFILES로 직접 분기).
- **분산 전제 주석**: saturate는 `ORDER_VARIANT_COUNT≥50`과 함께만 의미(단일은 행 락 산물).

## 2. 서버측 메트릭 스크랩 스크립트 (측정 하니스)
- `perf/k6/lib/scrape-metrics.py`(또는 `.sh`) — **신규 무거운 의존 금지**(python 표준 urllib + time, 또는 bash+curl). 인자: 폴링 간격(기본 2~3s), 출력 CSV 경로, 지속 시간(또는 Ctrl-C까지).
- `/actuator/prometheus` 텍스트에서 아래 라인을 정규식 추출해 `ts,metric,value` (또는 wide CSV)로 적재:
  - 풀: `hikaricp_connections_active`, `hikaricp_connections_pending`(>0 지속 = 풀 포화 핵심 신호), `hikaricp_connections_max`, `hikaricp_connections_acquire_seconds_count`/`_sum`(획득 지연 추세).
  - 스레드: `jvm_threads_live_threads`, `jvm_threads_peak_threads`.
  - CPU: `process_cpu_usage`(앱 프로세스), `system_cpu_usage`(머신 — 공유 판단).
  - (선택) `http_server_requests_seconds_count`/`_sum`(서버측 처리량·지연, k6 클라이언트측과 교차).
- 타임스탬프는 스크립트가 부여(시스템 시계) — k6 런 구간과 사후 정렬.
- README에 "saturate 런과 동시에 스크랩 시작/종료" 절차.
- **정규식 라벨 주의(MINOR 반영)**: Prometheus exposition은 라벨이 붙어 나온다 — `hikaricp_connections_max{pool="HikariPool-1"}`, `hikaricp_connections_pending{pool="..."}`. 스크랩 정규식이 **라벨 붙은 라인도 매칭**하도록(메트릭명 뒤 `{...}` 허용). 풀 스윕 검증은 `hikaricp_connections_max` 값이 셀값(10/30/50)인지로 확인.
- **`http_server_requests_seconds`(선택) 라벨 카디널리티**: `uri/method/status`별 다수 라인 → order-create 경로(`POST /api/v1/orders`, `POST /api/v1/cart/items`)만 필터하거나 합산. 선택 항목이므로 구현 시 1택 결정(미구현도 무방 — 핵심은 hikari/CPU).

## 3. 병목 분류 — 풀 스윕 (측정 오케스트레이션, 코드 아님)
- 동일 saturate 프로파일을 `SHOP_CORE_HIKARI_MAX_POOL`=**10 / 30 / 50** 3셀로(각 앱 재기동 — report 001 per-cell 재기동 선례), 각 셀 다회(3런+):
  - throughput(달성 RPS·order_created)이 풀과 함께 **상승 → 풀-바운드**(레버: 풀 상향).
  - 풀 무관 **평탄 → CPU/DB-바운드**: 스크랩 CSV의 `process_cpu_usage`≈1.0이면 CPU(개발 머신 공유 → 전용 환경 재측정), `hikaricp_connections_pending` 지속 高이면 풀 경합, 둘 다 아니면 DB(쿼리/락).
- **gradle 데몬 env 함정 주의**(report 001 §7): 풀 적용은 `hikaricp_connections_max`가 셀 값(10/30/50)으로 보이는지로 검증. bootRun은 `--args` 또는 명시 env로 풀 주입.

## 4. README (`perf/k6/README.md`)
- §5-5 "고RPS saturation + 병목 탐색" 추가 (**기존 §5-4의 단발 `/actuator/metrics/...` curl 대신 `/actuator/prometheus` 폴링 스크립트를 쓴다**는 정합 메모 1줄 — 독자 혼동 방지):
  - 전제: 깨끗한 DB TRUNCATE([[k6-perf-baseline-needs-clean-db]]), notification log/미기동([[perf-test-notification-must-be-log-mode]]), 앱 인스턴스 1개만(좀비 금지 — PG 커넥션 오염).
  - 실행: `-e PROFILE=saturate -e ORDER_VARIANT_COUNT=50 -e SATURATE_PEAK_RPS=600` + 스크랩 스크립트 동시 기동.
  - 풀 스윕: 셀별 `SHOP_CORE_HIKARI_MAX_POOL` 재기동 + 다회.
  - 천장 판정: dropped 급증/p95 무릎 직전 RPS(stress knee 판정 §5-2 준용) + 서버측 교차.
  - CPU 공유 주의: 절대 천장 비대표, 병목 분류는 유효(CPU-바운드면 전용 환경 권고).

## 5. 검증 (코드 게이트)
- **정적**: `k6 inspect -e PROFILE=saturate -e SATURATE_PEAK_RPS=600 ...` 파싱 무오류(+ peak 미지정 기본 600). N=1/50 조합 파싱. 기존 smoke/load/stress 회귀(파싱) 무영향.
- **스크랩 스크립트**: 앱 미기동 시 graceful(연결 실패 로깅), 기동 시 1회 폴링이 예상 지표 라인을 CSV로 적재하는지 단독 스모크.
- 라이브 측정(saturate 런·풀 스윕)은 docker 스택+앱 필요라 코드 게이트 밖 — 온디맨드.
- Java `./gradlew test` 게이트 아님(k6 자산만).

## 6. 순서 / 게이트
1. k6-implementor: `PROFILES.saturate`(+SATURATE_THRESHOLDS, env 피크 stages) → scrape 스크립트 → README §5-5. `k6 inspect` 정적 검증.
2. reviewer: saturate가 ramping-arrival-rate kind로 buildOptions와 정합·분산 전제 명시·thresholds 진단용·스크랩 지표/정규식 정확·신규 의존 없음·앱 무변경.
3. (온디맨드 라이브) 메인: 인프라+앱1개 기동 → 깨끗한 DB → saturate(N=50) 풀 10/30/50 × 3런 + 스크랩 → 천장·병목 분류 → `report/performance/003` + 다음 작업 권고.

## 7. 리뷰 관점
- **분산 전제 강제**: 측정/README가 `ORDER_VARIANT_COUNT≥50`을 요구(단일은 일반 트래픽 천장 아님 — report 002).
- **VU 인위병목 회피**: maxVUs 충분 + 메모리 가드, dropped 원인(VU 부족 vs 앱) 구분.
- **병목 분류 근거**: k6 단독 아니라 **풀 스윕 + 서버측 메트릭 교차**(pending/CPU)로 풀/CPU/DB 판정. CPU-바운드면 전용 환경 권고(개발 머신 절대값 비대표).
- **무변경/무의존**: 앱 Java·actuator 설정(이미 노출) 무변경, 스크랩 표준 라이브러리, k6 자산만. 기존 프로파일 회귀 없음.
- **측정 위생**: 깨끗한 DB·notification 안전·앱 1개·다회 비중첩이 README에 명시.

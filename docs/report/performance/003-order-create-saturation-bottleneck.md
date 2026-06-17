# order-create 분산 고RPS 천장·병목 탐색 리포트

> 측정일: 2026-06-17 · 대상: shop-core order-create 핫패스(분산 N=50)
> Task/Plan: `docs/tasks/performance/008-...`, `docs/plans/performance/008-...` · 동기: `docs/report/performance/002-...`(200rps 미포화 → 진짜 천장 미도달)
> 방법론: `docs/report/performance/001-virtual-thread-ab-measurement.md`(풀 스윕 + 서버측 메트릭 + CPU 공유 주의)

---

## 1. 요약 (Executive Summary)

| 발견 | 결과 | 신뢰도 |
|---|---|---|
| **풀 10 = 풀-바운드** | hikari pending 평균 93·최대 189, app CPU 19% → 기본 풀 10이 고RPS write에 부족 | 높음 |
| **풀 10→30 처리량 +15%** | 150→173/s, dropped 96→74/s, pending 93→75 | 높음 |
| **풀 30→50 평탄(~174/s)** | 풀이 더는 병목 아님, app CPU 여전 21% | 높음 |
| **~174/s 천장 = 공유 머신** | app CPU 21%인데 system CPU 74%(k6+PG+app 동거) → **머신(PG 경합)이 한계, 앱 아님** | 높음(단 dev 머신 한정) |

**결론**:
1. **즉시 가능한 개선**: HikariCP 풀을 **기본 10 → ~20~30**으로 올리면 고RPS 처리량이 실측 +15% 오른다(풀 10이 write-heavy 고부하에 과소). 저위험·순수 설정.
2. **그 위의 진짜 천장은 이 개발 머신에서 측정 불가**. 풀 30+에서 천장이 ~174/s로 평탄하지만 **app CPU는 21%**뿐 — 한계는 애플리케이션이 아니라 **k6·앱·PostgreSQL이 한 머신에서 CPU를 공유**하는 환경(특히 PG)이다. 진짜 운영 천장은 **전용 perf 환경**(부하발생기·앱·DB 분리)에서만 알 수 있다.
3. **앱은 CPU-바운드도 락-바운드도 아니다**(분산). → backlog 1순위(락 창 단축)는 일반 트래픽에 여전히 불필요(report 002 재확인).

---

## 2. 측정 환경 / 방법

- **앱**: shop-core 단일 인스턴스(`local` 프로파일), 풀 크기를 `--spring.datasource.hikari.maximum-pool-size`로 셀마다 직접 주입(gradle 데몬 env 함정 회피 — report 001 §7). 매 셀 `hikaricp_connections_max`로 적용 검증.
- **인프라**: docker-compose(PG 16 / Kafka / Redis). notification 미기동(메일 차단).
- **부하**: k6 v2.0.0, `PROFILE=saturate`(ramping 100→600rps, ~4.25m), **`ORDER_VARIANT_COUNT=50`(분산 — 일반 트래픽)**. preAllocatedVUs=100, maxVUs=400.
- **서버측 메트릭**: `lib/scrape-metrics.py`가 `/actuator/prometheus` 2s 간격 폴링 → hikari(active/pending/max)·jvm_threads·CPU 타임시리즈 CSV(런과 동시).
- **위생**: 매 셀 전 java 전체 종료(좀비 제거)·앱 1개·`TRUNCATE orders/order_items/cart_items`(깨끗한 DB).

### ★ 측정 한계
- **각 셀 1런**(단발). 처리량 추세가 **단조 증가→평탄**으로 명확해 결론은 견고하나, 풀 운영값 확정 전 3런 확인 권장.
- **k6·앱·PG 동일 머신 CPU 공유** → 절대 천장(~174/s)·절대 지연은 비대표적. **풀 스윕 상대 비교·병목 분류는 유효**(report 001 ★ 동일 프레이밍).
- maxVUs=400 도달("Insufficient VUs") — 600rps 도착을 다 못 채움. 단 **완료 처리량(order_created rate)** 은 앱이 실제 처리한 값이라 천장 지표로 유효(VU 캡은 offered load 제한이지 완료율 제한 아님).

---

## 3. 결과 — 풀 스윕 (saturate N=50, →600rps, 각 1런)

| 풀 | 처리량/s | p95(ms) | p99(ms) | dropped/s | hikari pending(avg/max) | active(avg/max) | proc_cpu(avg) | sys_cpu(avg) | order_5xx |
|---|---|---|---|---|---|---|---|---|---|
| **10** | 150.3 | 1226 | 1504 | 96.2 | 93 / 189 | 6.5 / 10 | 0.19 | 0.73 | 0 |
| **30** | 172.9 | 1079 | 1383 | 73.9 | 75 / 169 | 16.9 / 30 | 0.20 | 0.74 | 0 |
| **50** | 174.4 | 1046 | 1332 | 72.4 | 61 / 149 | 25.3 / 50 | 0.21 | 0.74 | 0 |

- 처리량: 10→30 **+22.6/s(+15%)**, 30→50 **+1.5/s(평탄)**.
- app CPU(proc_cpu): 전 셀 **~20% 고정**(앱은 CPU 여유).
- system CPU: ~74%(max 100%) — 머신 전체는 포화 근접(k6+PG+app 합산).
- order_5xx=0 전 셀(락 붕괴 없음).

---

## 4. 분석

### 4.1 풀 10은 풀-바운드 (개선 여지 확정)
풀 10에서 hikari **pending 평균 93·최대 189** — 평균 93개 요청이 10개 커넥션을 기다린다. 그런데 **app CPU는 19%**. 즉 앱은 놀고 있는데 커넥션이 없어 막힌 전형적 **풀-바운드**. 풀을 30으로 키우자 처리량 150→173/s(+15%), pending 93→75, dropped 96→74/s로 모두 개선. → **기본 풀 10은 고RPS write에 과소**.

### 4.2 풀 30+는 머신-바운드 (앱 아님)
풀 30→50에서 처리량이 174로 **평탄**(+1.5/s) — 풀이 더는 병목이 아니다. 그러나 **app CPU는 여전히 21%**뿐이라 앱이 CPU-바운드도 아니다. 한계는 **앱 밖**: `system_cpu_usage` 74%(max 100%)는 k6 부하발생기·PostgreSQL·앱이 **한 머신에서 CPU를 경합**함을 보여준다. 특히 order-create는 커밋당 PG write(insert+commit)라 **PG가 같은 머신에서 CPU를 두고 경쟁**하는 것이 ~174/s 평탄의 실체다. → **이 머신에선 앱의 진짜 천장을 잴 수 없다.**

### 4.3 락은 병목 아님 (재확인)
분산(N=50)이라 variant 행 락 경합이 없고, order_5xx=0·app CPU 저부하. report 002에 이어 **락 창(backlog 1순위)은 일반 트래픽 천장의 원인이 아님**이 재확인됐다.

---

## 5. 결론 / 권고

1. **즉시(저위험) 개선 — HikariCP 풀 상향**: 기본 10 → **20~30**. 실측 근거(풀 10→30 처리량 +15%, pending·dropped 감소). PG `max_connections`(기본 100) 미만 유지. **단 운영값 확정 전 3런 재측정 + 다중 앱 인스턴스 시 합산 커넥션이 PG 한도 내인지 점검.** → backlog 3순위 task로 분해.
2. **진짜 천장 측정 — 전용 perf 환경 필요**: 풀 30+ 천장(~174/s)은 개발 머신 CPU 공유(PG 경합) 산물이라 비대표적. 부하발생기·앱·DB를 **분리한 전용 환경**에서 재측정해야 운영 용량 산정이 가능. → 별도 task.
3. **락 창 단축(1순위)·아키텍처(4순위)는 보류 유지**: 일반 분산 트래픽에선 앱이 락·CPU 바운드가 아님. 단일 핫-SKU 요구가 명확해질 때만(report 002).

### 다음 작업 (게이팅 결과)
- **(권장) 풀 상향 task**: 풀 20/30 후보값 3런 검증 + 운영 기본값 변경 + PG max_connections 정합. ← 본 측정이 정당화.
- **(권장) 전용 perf 환경 task**: 분리 환경에서 분산 order-create 진짜 천장·병목 재측정.
- (보류) 락 창 단축 — 단일 핫-SKU 요구 확인 시.

---

## 6. 산출물 / 재현
- 런타임 JSON/CSV(gitignore): `build/k6/sat-pool{10,30,50}.json`, `build/k6/sat-pool{10,30,50}-metrics.csv`.
- 재현: `shop-core/perf/k6/README.md` §5-5. `-e PROFILE=saturate -e ORDER_VARIANT_COUNT=50 -e SATURATE_PEAK_RPS=600` + `lib/scrape-metrics.py` 동시 기동, 풀 셀별 `--spring.datasource.hikari.maximum-pool-size=N` 재기동, 깨끗한 DB.
- 방법론·CPU 공유 주의: report 001 §2·§7.

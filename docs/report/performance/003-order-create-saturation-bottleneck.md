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
| **피크 ~30~50(~174/s), 그 위 완만 하락** | 50→80→100: 174→171→165/s. **과대 풀은 역효과**(PG 동시 트랜잭션 경합) | 높음(곡선 단조) |
| **배포값 100은 피크보다 ~5% 나쁨(실측)** | 165/s·dropped 83/s·p95 1122 — 30~50보다 throughput↓·dropped↑ + PG 고갈 위험 | 높음 |
| **~174/s 천장 = 공유 머신** | app CPU 21%인데 system CPU 74%(k6+PG+app 동거) → **머신(PG 경합)이 한계, 앱 아님** | 높음(단 dev 머신 한정) |

**결론**:
1. **풀 적정값은 ~30(피크 ~30~50)**: 풀 10→30 처리량 +15%(과소 해소), **30~50에서 피크(~174/s)**, 50→80→100은 **완만히 하락**(174→171→165). 즉 풀을 무작정 키우면 PG 동시 트랜잭션 경합으로 **오히려 약간 나빠진다**.
2. **배포 런타임값 100은 과대(실측)**: 100은 피크(30~50)보다 throughput ~5%↓·dropped↑·p95↑, app CPU 스파이크(0.9). **throughput 이득 0 + PG 고갈 위험**(`max_connections=100` — 단일 인스턴스가 PG 전체 점유, 멀티 인스턴스 즉시 초과). → **100→~30으로 낮추는 것이 맞다**(성능 동일하거나 개선 + 안전).
3. **진짜 천장(~174/s)은 이 개발 머신 한정**: app CPU 21%인데 system CPU 74%(k6+PG+app 동거) → 한계는 앱이 아니라 **머신 CPU 공유(특히 PG)**. 진짜 운영 천장은 **전용 perf 환경**에서만 측정 가능.
4. **앱은 CPU-바운드도 락-바운드도 아니다**(분산). → backlog 1순위(락 창 단축)는 일반 트래픽에 여전히 불필요(report 002 재확인).

---

## 2. 측정 환경 / 방법

- **앱**: shop-core 단일 인스턴스(`local` 프로파일), 풀 크기를 `--spring.datasource.hikari.maximum-pool-size`로 셀마다 직접 주입(gradle 데몬 env 함정 회피 — report 001 §7). 매 셀 `hikaricp_connections_max`로 적용 검증.
- **인프라**: docker-compose(PG 16 / Kafka / Redis). notification 미기동(메일 차단).
- **부하**: k6 v2.0.0, `PROFILE=saturate`(ramping 100→600rps, ~4.25m), **`ORDER_VARIANT_COUNT=50`(분산 — 일반 트래픽)**. preAllocatedVUs=100, maxVUs=400.
- **서버측 메트릭**: `lib/scrape-metrics.py`가 `/actuator/prometheus` 2s 간격 폴링 → hikari(active/pending/max)·jvm_threads·CPU 타임시리즈 CSV(런과 동시).
- **위생**: 매 셀 전 java 전체 종료(좀비 제거)·앱 1개·`TRUNCATE orders/order_items/cart_items`(깨끗한 DB).

### ★ 측정 한계
- **각 셀 1런**(단발, 풀 10/30/50/80/100). 처리량 곡선이 **단조 상승→피크(30~50)→완만 하락**으로 일관(throughput·dropped·p95 신호 정합)이라 결론은 견고하나, 풀 운영값 최종 확정 전 3런 확인 권장.
- **k6·앱·PG 동일 머신 CPU 공유** → 절대 천장(~174/s)·절대 지연은 비대표적. **풀 스윕 상대 비교·병목 분류는 유효**(report 001 ★ 동일 프레이밍).
- maxVUs=400 도달("Insufficient VUs") — 600rps 도착을 다 못 채움. 단 **완료 처리량(order_created rate)** 은 앱이 실제 처리한 값이라 천장 지표로 유효(VU 캡은 offered load 제한이지 완료율 제한 아님).

---

## 3. 결과 — 풀 스윕 (saturate N=50, →600rps, 각 1런)

| 풀 | 처리량/s | p95(ms) | p99(ms) | dropped/s | hikari pending(avg/max) | active(avg/max) | proc_cpu(avg/max) | order_5xx |
|---|---|---|---|---|---|---|---|---|
| **10** | 150.3 | 1226 | 1504 | 96.2 | 93 / 189 | 6.5 / 10 | 0.19 / 0.31 | 0 |
| **30** | 172.9 | 1079 | 1383 | 73.9 | 75 / 169 | 16.9 / 30 | 0.20 / 0.36 | 0 |
| **50** | **174.4** (피크) | 1046 | 1332 | 72.4 | 61 / 149 | 25.3 / 50 | 0.21 / 0.37 | 0 |
| **80** | 171.5 | 1043 | 1301 | 75.9 | 48 / 119 | 39.7 / 80 | 0.20 / 0.40 | 0 |
| **100 (배포값)** | 165.2 | 1122 | 1421 | 83.1 | 44 / 101 | 51.5 / 100 | 0.21 / **0.90** | 0 |

- 처리량 곡선: 10→30 **+22.6/s(+15%, 급상승)** → 30~50 **피크(~174/s)** → 50→80→100 **완만한 하락(174→171.5→165.2)**.
- **배포 런타임값 100은 피크보다 ~5% 낮다(실측, 추정 아님)**: dropped↑(83 vs 72), p95↑(1122 vs 1046), proc_cpu **max 0.9 스파이크**. active avg 51.5 — 100 커넥션이 동시 트랜잭션을 늘려 PG 경합·CPU 부담만 키우고 throughput은 못 올림(과대 풀 역효과).
- app CPU(proc_cpu) avg는 전 셀 ~20% — 앱 자체는 CPU 여유. system CPU ~74%(max 100%) — 머신 전체 포화 근접(k6+PG+app 합산).
- order_5xx=0 전 셀(락 붕괴 없음).

---

## 4. 분석

### 4.1 풀 10은 풀-바운드 (개선 여지 확정)
풀 10에서 hikari **pending 평균 93·최대 189** — 평균 93개 요청이 10개 커넥션을 기다린다. 그런데 **app CPU는 19%**. 즉 앱은 놀고 있는데 커넥션이 없어 막힌 전형적 **풀-바운드**. 풀을 30으로 키우자 처리량 150→173/s(+15%), pending 93→75, dropped 96→74/s로 모두 개선. → **기본 풀 10은 고RPS write에 과소**.

### 4.2 풀 30~50 피크, 그 위는 과대 풀 역효과 (배포값 100 실측)
풀 30→50에서 처리량이 ~174로 피크에 도달하고, **50→80→100은 오히려 완만히 하락**(174→171.5→165.2)한다. **app CPU는 전 구간 ~21%**뿐이라 앱이 CPU-바운드가 아니다. 한계는 **앱 밖**: `system_cpu_usage` 74%(max 100%)는 k6·PostgreSQL·앱이 **한 머신에서 CPU 경합**함을 보여준다. order-create는 커밋당 PG write라, **풀을 키울수록 PG 동시 트랜잭션이 늘어 경합·컨텍스트 스위칭만 증가**(풀 100: active avg 51.5, proc_cpu max 0.9 스파이크) → throughput은 안 오르고 dropped·p95만 악화된다. 즉 **~174/s 천장은 머신(PG) 한계이고, 풀을 그 위로 키우는 건 역효과**다.

### 4.2-1 배포 런타임값 100은 과대 — 낮춰야 함
런타임에서 `SHOP_CORE_HIKARI_MAX_POOL=100`(레포 기본값 10과 별개의 오버라이드)으로 떠 있었는데, 100은 (1) 피크(30~50)보다 throughput ~5% 낮고, (2) **PG `max_connections=100`**이라 단일 인스턴스가 PG 전체를 점유 — 멀티 인스턴스 즉시 초과(측정 중 `too many clients already` 실증). → **100은 throughput 이득 0 + 위험만 추가.** 적정값 **~30**(피크 근처 + 멀티 인스턴스 안전: 3×30=90<100).

### 4.3 락은 병목 아님 (재확인)
분산(N=50)이라 variant 행 락 경합이 없고, order_5xx=0·app CPU 저부하. report 002에 이어 **락 창(backlog 1순위)은 일반 트래픽 천장의 원인이 아님**이 재확인됐다.

---

## 5. 결론 / 권고

1. **풀 right-size — ~30으로 정렬(상향도 하향도 아닌 정렬)**: 측정 곡선상 적정은 **~30(피크 30~50)**. 두 가지 드리프트를 동시에 교정해야 한다:
   - 레포 기본값 **10 → ~30**(10은 풀-바운드, +15% 손해).
   - 런타임 오버라이드 **100 → 제거(~30)**(100은 피크보다 ~5% 낮고 PG 고갈 위험).
   - PG `max_connections=100` 제약: **(앱 인스턴스 수 × 풀) < 100**. 풀 30이면 3인스턴스=90 안전.
   - 운영값 확정 전 3런 재측정 권장(본 측정은 셀당 1런). → backlog 3순위 = Task 047.
2. **진짜 천장 측정 — 전용 perf 환경 필요**: ~174/s 천장은 개발 머신 CPU 공유(PG 경합) 산물이라 비대표적. 부하발생기·앱·DB **분리 환경**에서 재측정해야 운영 용량 산정 가능. → 별도 task.
3. **락 창 단축(1순위)·아키텍처(4순위)는 보류 유지**: 일반 분산 트래픽에선 앱이 락·CPU 바운드가 아님. 단일 핫-SKU 요구가 명확해질 때만(report 002).

### 다음 작업 (게이팅 결과)
- **(권장) 풀 right-size task(047)**: 레포 10·런타임 100을 ~30으로 정렬 + 3런 검증 + PG max_connections 정합. ← 본 측정이 정당화.
- **(권장) 전용 perf 환경 task**: 분리 환경에서 분산 order-create 진짜 천장·병목 재측정.
- (보류) 락 창 단축 — 단일 핫-SKU 요구 확인 시.

---

## 6. 산출물 / 재현
- 런타임 JSON/CSV(gitignore): `build/k6/sat-pool{10,30,50,80,100}.json`, `build/k6/sat-pool{10,30,50,80,100}-metrics.csv`.
- 재현: `shop-core/perf/k6/README.md` §5-5. `-e PROFILE=saturate -e ORDER_VARIANT_COUNT=50 -e SATURATE_PEAK_RPS=600` + `lib/scrape-metrics.py` 동시 기동, 풀 셀별 `--spring.datasource.hikari.maximum-pool-size=N` 재기동, 깨끗한 DB.
- 방법론·CPU 공유 주의: report 001 §2·§7.

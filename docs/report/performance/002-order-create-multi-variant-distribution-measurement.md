# order-create 다중 variant 분산 측정 리포트 — 단일 vs 분산 A/B

> 측정일: 2026-06-17 · 대상: shop-core order-create 핫패스
> Task/Plan: `docs/tasks/performance/007-...`, `docs/plans/performance/007-...` · 분석 출처: `docs/backlog/performance/001-...`(§0순위)
> 방법론 준거: `docs/report/performance/001-virtual-thread-ab-measurement.md`(A/B 상대비교·CPU 공유 주의)

---

## 1. 요약 (Executive Summary)

| 관점 | 결과 | 신뢰도 |
|---|---|---|
| **지속부하(60rps) throughput** | 단일·분산 **동일**(둘 다 포화점 아래라 60rps 완수) | 높음(각 3런) |
| **지속부하 꼬리지연** | 단일 p99 **변동(24~69ms)**, 분산 **안정(23~25ms)** | 높음(3런) |
| **stress(→200rps) 천장** | **단일 붕괴 106/s·p95 894ms·dropped 20/s** vs **분산 200rps 완주·p95 21ms·dropped 0** | 높음(차이 압도적) |

**결론**: 기존 "~100~200rps 한계"는 **단일 variant 행 락 자기경합이라는 측정 방식의 산물**임이 입증됐다. 주문을 여러 variant로 분산하면 동일 앱·동일 머신에서 **200rps 램프를 p95 21ms·dropped 0으로 완주**한다 — 즉 현실(분산) 처리량의 천장은 행 락이 아니며 **200rps보다 훨씬 위**에 있다(본 stress 프로파일로는 포화에 도달조차 못 함).

---

## 2. 측정 환경 / 방법

- **앱**: shop-core 단일 인스턴스(`local` 프로파일), HikariCP 풀 기본 10. notification 미기동(환영메일 발송 경로 차단 — 메일 사고 회피).
- **인프라**: docker-compose(PostgreSQL 16 / Kafka / Redis).
- **부하**: k6 v2.0.0, `scenarios/order-create.js`(cart add → order). variant 분배 `data.variantIds[(__VU-1+__ITER)%N]`(결정적).
- **A/B 변수**: `ORDER_VARIANT_COUNT` — 단일 `N=1`(상품1·variant1, 기존 베이스라인 재현) vs 분산 `N=50`(상품50·variant50).
- **프로파일**: load(constant-arrival-rate 60rps×1m) 각 3런 + stress(ramping 50→200rps, ~4.5m) 각 1런.
- **측정 위생**: 매 런 전 `TRUNCATE orders, order_items, cart_items RESTART IDENTITY CASCADE`(누적 열화 배제). 산출 JSON은 `SUMMARY_EXPORT_PATH`(토큰 제외).

### ★ 측정상 한계 (절대수치 해석 주의)
- k6·shop-core·PostgreSQL이 **동일 개발 머신에서 CPU 공유** → 절대 throughput·지연은 비대표적. **단, 단일 vs 분산은 동일 조건이라 상대 비교는 유효**(report 001과 동일 프레이밍).
- stress는 **각 1런**(load는 3런). stress 단일·분산 차이가 압도적(p95 894ms vs 21ms, dropped 20/s vs 0)이라 단발로도 결론은 견고하나, 정밀화하려면 다회 권장.

---

## 3. 결과

### 3.1 load (60rps × 1m, 각 3런)
| set | order_created | rate/s | p95(ms) | p99(ms) | dropped | order_5xx |
|---|---|---|---|---|---|---|
| 단일 N=1 r1 | 3600 | 55.6 | 17.0 | **68.7** | 0 | 0 |
| 단일 N=1 r2 | 3601 | 56.0 | 16.9 | 24.0 | 0 | 0 |
| 단일 N=1 r3 | 3601 | 55.9 | 16.6 | 27.7 | 0 | 0 |
| 분산 N=50 r1 | 3600 | 55.3 | 16.6 | 25.0 | 0 | 0 |
| 분산 N=50 r2 | 3600 | 55.3 | 16.5 | 23.0 | 0 | 0 |
| 분산 N=50 r3 | 3601 | 55.1 | 16.4 | 24.9 | 0 | 0 |

→ 60rps는 **두 구성 모두 포화점 아래**라 throughput 동일(3600 완수). 차이는 꼬리지연: **단일은 p99가 24~69ms로 변동(락 큐잉성 tail spike)**, **분산은 23~25ms로 안정**.

### 3.2 stress (50→200rps ramp, 각 1런) — 천장 차이
| set | order_created | rate/s(평균) | p95(ms) | p99(ms) | dropped | dropped/s | order_5xx |
|---|---|---|---|---|---|---|---|
| **단일 N=1** | 31,582 | 106.3 | **894** | 1043 | 5,917 | 19.9 | 0 |
| **분산 N=50** | 37,499 | 125.9 | **21** | 35.6 | **0** | 0 | 0 |

→ **단일**: ~106/s에서 붕괴 — 200rps 램프를 못 따라가 dropped 19.9/s, p95 894ms(행 락 큐잉). 기존 baseline(knee≈120, 200rps 붕괴)과 일치.
→ **분산**: 200rps 램프를 **dropped 0·p95 21ms로 완주**. 행 락 경합이 사라져 앱이 200rps를 여유롭게 처리.

---

## 4. 분석

### 4.1 "천장"은 단일 variant 자기경합 산물 (입증)
stress에서 단일은 106/s에서 붕괴(p95 894ms, dropped 20/s)하지만, **같은 앱·같은 머신**에서 분산은 200rps를 p95 21ms·dropped 0으로 완주했다. 두 차이는 오직 **주문이 한 variant 행에 직렬화되느냐**뿐이다. 따라서 backlog 001의 가설 — "~100~200rps 한계 = 단일 variant `PESSIMISTIC_WRITE` 직렬화 산물" — 이 데이터로 확정됐다.

### 4.2 분산의 진짜 천장은 200rps보다 위 (미도달)
분산 stress가 200rps 최대 단계에서도 **p95 21ms·dropped 0**이었다는 것은, **그 부하에서 풀·CPU·DB 어느 것도 포화되지 않았음**을 뜻한다. 즉 현실(분산) 처리량의 천장은 본 stress 프로파일의 상한(200rps)보다 높아 **이번 측정으로는 도달하지 못했다**. 진짜 천장 식별은 **더 높은 RPS의 stress 프로파일**(후속)이 필요하다.

### 4.3 지속부하에서의 꼬리지연 이득
60rps(포화점 아래)에서도 단일은 p99가 한 런(r1)에서 68.7ms로 튀었다. 낮은 부하에서도 단일 variant는 동시 도착 시 짧은 락 큐잉으로 tail이 간헐적으로 악화된다. 분산은 23~25ms로 일관 — 운영 SLO 안정성 측면에서도 분산(현실 트래픽)이 유리하다.

---

## 5. 결론 / 게이팅 결정

1. **현재 ~100~200rps "한계"는 측정 산물**이다. 모든 주문이 같은 SKU 1개를 사는 최악 경합 조건이 만든 수치이며, 현실의 분산 주문에서는 재현되지 않는다.
2. **현실(분산) 처리량은 200rps를 여유롭게 상회**한다. 진짜 천장(풀/CPU)은 본 측정 상한 위라 미도달.
3. **backlog 1순위(락 창 단축 — Hibernate 배칭·락-후 쿼리 정리)는 일반 트래픽엔 긴급하지 않다.** 그 작업의 실익은 **단일 핫-SKU 초고동시**(플래시세일 등) 시나리오에 한정된다. → 일반 운영 목표라면 착수 보류 정당.
4. **backlog 3순위(풀/코어 스케일)** 는 "분산의 진짜 천장"을 더 높은 stress로 찾은 뒤에야 의미 있는 레버다(현 200rps에선 미포화).
5. **단일 핫-SKU가 실제 요구**(특정 상품 동시 주문 폭증)로 확인될 때만 1·4순위(락 창 단축/재고 샤딩·예약) 검토.

### 후속 권장
- 더 높은 RPS(예 300~600rps) stress 프로파일로 분산의 진짜 천장·병목(풀 vs CPU) 식별 + 서버측 메트릭(hikaricp_connections/jvm_threads/CPU) **부하 중 스크랩**(본 측정은 k6 지표만; during-run 서버측 수집은 미수행).
- 단일 핫-SKU 보호가 필요해지면 backlog 1순위 착수 → 본 리포트의 단일 stress(106/s·p95 894ms)를 before 기준선으로 사용.

---

## 6. 산출물 / 재현
- 런타임 JSON(gitignore): `build/k6/mv-{single,dist}-r{1,2,3}.json`, `build/k6/mv-stress-{single,dist}.json`.
- 커밋 베이스라인: `shop-core/perf/k6/baselines/order-create-load-multivariant.json`(분산 load 대표 런).
- 재현 절차: `shop-core/perf/k6/README.md` §5-4. 단일 `-e ORDER_VARIANT_COUNT=1`, 분산 `=50`, 매 런 전 TRUNCATE, 깨끗한 DB.

# HikariCP 커넥션 풀 사이징 — 측정 기록 및 결정

> 작성일: 2026-06-17 · 대상: shop-core (`spring.datasource.hikari.maximum-pool-size`)
> 목적: 풀 크기를 실측으로 정하고, 측정 중 반복된 `too many clients already`의 근본 원인을 규명·정정한다.
> 결정: **운영 기본 풀 = 30** (단일 인스턴스 피크 근처 + 멀티 인스턴스 PG 안전). 관련: report 002·003(원시 측정), Task 047, [[bootrun-jvm-leak-pg-exhaustion]].

---

## 1. 요약 (Executive Summary)

| 항목 | 결론 | 신뢰도 |
|---|---|---|
| **적정 풀 크기** | **30** (피크 30~50 구간, 멀티 인스턴스 안전선) | 높음(상대 비교) |
| **풀 10** | 고RPS write에서 풀-바운드 → throughput −15% | 높음 |
| **풀 100** | 피크보다 ~5% 낮음(과동시 PG 경합) + **PG 고갈 위험** | 높음 |
| **`too many clients` 원인** | application.yml **committed 기본값이 `:100`**(주석엔 "10"이라 오인) → 단일 앱이 PG max_connections=100 통째 점유 | 확정 |
| **절대 천장(~174/s)** | dev 머신 CPU 공유 산물 — 비대표적, 전용 환경 재측정 필요 | 명시적 한계 |

**핵심**: 풀 10은 약간 부족, 풀 100은 오히려 역효과(+위험). **30이 throughput 피크에 사실상 도달하면서 PG 안전(3 인스턴스×30=90<100)**.

---

## 2. 배경 — `too many clients already`의 근본 원인 (정정)

측정 내내 `FATAL: sorry, too many clients already`가 반복돼 측정/E2E가 막혔다. 추적 결과:

- **실제 원인(확정)**: 레포 `application.yml`의 **committed 기본값이 `${SHOP_CORE_HIKARI_MAX_POOL:100}`** 이었다(HEAD diff로 확인). 즉 env 미설정이면 풀 **100**. (주석엔 "기본 10"이라 적혀 있어 **주석·값 불일치**였고, 그 주석 때문에 한때 "기본 10"으로 오인했다.) HikariCP **라이브러리** 기본은 10이지만, 이 레포는 그 위에 명시적으로 100을 얹어둔 상태였다.
- **증상 정합**: 풀 인자 없이 띄운 `./gradlew bootRun` 앱이 100을 잡음(`hikaricp_connections_max=100`) — 이는 committed 기본값 100 그 자체이지 "떠도는 데몬 env 캐시"가 아니다. `--no-daemon`+명시 `--...=10`이면 10. 모든 관측이 *committed 100 + 명시 오버라이드*로 설명된다.
- **PG `max_connections` = 100**(서버 총 연결 상한). **앱 1개가 풀 100이면 그 혼자 PG를 통째 점유** → psql·테스트·다른 앱 자리 0 → "too many clients". SIGKILL된 좀비 JVM의 미회수 연결이 누적돼 악화.
- **해소**: committed 기본값을 **30으로 인하**(본 리포트 결정, 작업트리 반영 `${SHOP_CORE_HIKARI_MAX_POOL:30}`). 풀 테스트(`./gradlew test`)는 Testcontainers 자체 PG라 이 문제와 무관.

> 정정 메모: 초판은 "기본값 10, 100은 gradle 데몬 env 캐시"로 적었으나 **오류**였다. HEAD application.yml이 `:100`임을 커밋 직전 확인 — committed 기본값이 100이었고, 데몬 캐시 가설은 불필요했다. 결론(적정 풀 30)은 측정 기반이라 불변.

---

## 3. 측정 기록

> 공통: 분산 시드(`ORDER_VARIANT_COUNT=50`, 행 락 경합 제거 — report 002), 깨끗한 DB, notification 미기동. 풀은 `--spring.datasource.hikari.maximum-pool-size=N` program-arg로 셀마다 명시(데몬 캐시 우회), `hikaricp_connections_max`로 검증. 각 셀 1런(추세 단조라 결론 견고, 운영값 확정 전 3런 권장).

### 3.1 지속부하 saturate (open 모델, ramping →600rps)
| 풀 | throughput/s | p95(ms) | p99(ms) | dropped/s | hikari pending(avg) | proc_cpu(avg/max) |
|---|---|---|---|---|---|---|
| 10 | 150.3 | 1226 | 1504 | 96.2 | 93 | 0.19 / 0.31 |
| 30 | 172.9 | 1079 | 1383 | 73.9 | 75 | 0.20 / 0.36 |
| **50** | **174.4 (피크)** | 1046 | 1332 | 72.4 | 61 | 0.21 / 0.37 |
| 80 | 171.5 | 1043 | 1301 | 75.9 | 48 | 0.20 / 0.40 |
| 100 | 165.2 | 1122 | 1421 | 83.1 | 44 | 0.21 / **0.90** |

곡선: **10→30 급상승(+15%) → 30~50 피크 → 50→100 완만한 하락.** app CPU는 전 구간 ~20%(앱은 여유), system CPU ~74%(머신 포화 근접).

### 3.2 동시 요청 conc (closed 모델, CONC_VUS)
| 동시 VU | 풀 30 (throughput/s · p95) | 풀 100 (throughput/s · p95) |
|---|---|---|
| 100 | **227 · 290ms** | 189 · 275ms |
| 200 | 153 · 778ms | 153 · 663ms |
| 300 | 125 · 1008ms | 132 · 844ms |

운영 동시성(~100)에선 **풀 30이 throughput 1위(227/s)**. 200+ 과부하 구간은 둘 다 negative scaling(동시성↑ → throughput↓·지연↑), 실패(5xx) 0.
- conc=600은 **부하발생기 한계**(k6가 600 VU를 공유 머신에서 못 띄움 — http_reqs 985뿐)로 무효, 앱 정상.

---

## 4. 분석

- **풀 10 = 풀-바운드**: pending 평균 93인데 app CPU 19% → 앱은 노는데 커넥션이 없어 막힘. 고RPS write에 과소(−15%).
- **30~50 = 피크**: throughput ~174/s. 풀이 더는 병목 아님.
- **50→100 = 과대 풀 역효과**: 풀을 키울수록 PG 동시 트랜잭션·CPU 경합만 늘어 throughput↓(174→165), dropped↑, proc_cpu 스파이크. **풀 100은 "더 많이 받는" 게 아니라 덜 받음.**
- **천장 ~174/s = 머신 한계**: app CPU 21%인데 system CPU 74% → k6·앱·PG 동거 CPU 경합(특히 PG). **앱 자체 한계 아님 — 절대 수치는 비대표적.** 락도 병목 아님(분산, 5xx 0).
- **PG 안전**: `max_connections=100` → (앱 인스턴스 수 × 풀) < 100 이어야 함.

---

## 5. 결정: 풀 = 30

- **이유**:
  1. throughput 피크(30~50)에 사실상 도달 — 30(172.9/s) ≈ 50(174.4/s), 차 ~1%(노이즈 범위). 동시 100 운영 구간에선 30이 오히려 1위(227/s).
  2. **멀티 인스턴스 PG 안전**: 3 인스턴스 × 30 = 90 < 100. 50이면 2 인스턴스(100)에서 이미 한계, 100이면 단일로도 위험.
  3. 10(부족)·100(역효과·위험) 둘 다 비최적.
- **참고**: 단일 인스턴스 고정이고 throughput만 보면 50이 수치상 피크지만, 확장 여지·PG 안전을 위해 **30 채택**(피크와 동급, 더 안전).

---

## 6. 한계 / 후속

- **dev 머신 CPU 공유**로 절대 천장(~174/s)·절대 동시량은 비대표적. **상대 비교(30~50 최적 > 100 > 10)만 신뢰.** 진짜 운영 천장·최대 동시량은 **부하발생기·앱·DB 분리한 전용 perf 환경**에서 재측정해야 함(별도 task).
- 셀당 1런 — 운영값 확정 전 후보(20/30/50) 3런 비중첩 확인 권장(report 001 §7).

---

## 7. 액션 아이템

- [x] `application.yml` 기본값 `${SHOP_CORE_HIKARI_MAX_POOL:100}` → **`:30`** (작업트리 반영 완료). 주석도 "기본 10" 오기를 실측 기반 30으로 갱신 권장.
- [ ] 측정 시 좀비 앱 JVM 누적 주의(`taskkill java` 후 재기동 — [[bootrun-jvm-leak-pg-exhaustion]]).
- [ ] (후속) 전용 perf 환경에서 진짜 천장·최대 동시량 재측정.

## 8. 참고
- 원시 측정: `003-order-create-saturation-bottleneck.md`(풀 스윕·서버측 메트릭), `002-order-create-multi-variant-distribution-measurement.md`(분산 전제).
- 방법론: `001-virtual-thread-ab-measurement.md` §2·§7(상대 비교·다회·gradle 데몬 함정).
- 측정 자산: `shop-core/perf/k6`(saturate 프로파일·scrape-metrics.py), 런타임 JSON/CSV `build/k6/sat-pool*.json`·`conc-p*.json`(gitignore).

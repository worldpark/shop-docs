# 가상스레드 A/B 측정 결과 (Task 006 Revision 1)

- 대상 Task: `docs/tasks/performance/006-performance-shop-core-virtual-thread-ab-evaluation.md`
- 측정 일자: 2026-06-16
- 측정자: 사용자(앱 토글 기동) + 메인(k6·서버측 지표)
- 목적: 가상스레드(VT) 도입/미도입을 동일 워크로드에서 A/B 측정해 **채택 근거**를 데이터로 확보.

## 측정 환경
- 워크로드: `catalog-read.js`(`GET /api/v1/products` + `/products/{id}`, 공개·읽기, 락 없음), **CONC_VUS=300 closed × 40s**, 깨끗한 카탈로그 시드.
- 토글: VT = 빈(`VirtualThreadConfig`, `--shop.threads.virtual.enabled=true`) / 풀 = `--spring.datasource.hikari.maximum-pool-size`. 셀마다 앱 재기동.
- 서버측: Micrometer/Prometheus(`jvm_threads_peak_threads`로 플랫폼 스레드 피크, `hikaricp_connections_max`로 풀 확인). VT 활성 교차검증 = 피크 스레드(가상스레드는 `ThreadMXBean` 미집계).
- **중요 한계**: k6·앱·PostgreSQL이 **동일 개발 머신에서 CPU 공유**. 절대수치(~900/s)는 비대표적(머신 전체 CPU 한계 추정). **VT vs 플랫폼 상대 비교는 동일 조건이라 유효**.

## 매트릭스 (4셀)
| 셀 | 풀 | 모델 | throughput | p95 | p99 | 피크 플랫폼 스레드 | read_5xx |
|---|---|---|---|---|---|---|---|
| 1 | 10 | 플랫폼 | 984/s | 442ms | 570ms | **277** | 0 |
| 2 | 10 | **VT** | 877/s | 472ms | 700ms | **91** | 0 |
| 3 | 50 | 플랫폼 | 863/s | 677ms | 991ms | **280** | 0 |
| 4 | 50 | **VT** | 866/s | 495ms | 656ms | **98** | 0 |

## 발견
1. **throughput은 풀·스레드 모델과 무관하게 ~860~980/s에서 평탄.** 풀 10→50도, 플랫폼→VT도 throughput을 못 올렸다. → 이 읽기 워크로드의 천장은 **CPU/처리능력**(동거 머신 CPU 공유 추정)이지, 커넥션 풀도 스레드 모델도 아니다.
2. **VT의 실이득 = 스레드 효율.** 같은 300 동시 부하를 **플랫폼은 ~280 스레드, VT는 ~90~98 스레드**로 처리(약 1/3). 풀 크기 무관하게 일관.
3. **풀 10→50: throughput 무변화(오히려 풀50 플랫폼은 지연↑).** 병목이 풀이 아니었음을 확증. ("풀 늘리면 VT가 이긴다"는 가설은 기각 — 풀이 캡도 아니었고 throughput 천장은 CPU.)
4. **VT는 throughput·지연에 무해.** 단일 런 변동(±10%) 범위. 풀50에선 VT가 오히려 p95/p99 우위(플랫폼 280 스레드의 컨텍스트 스위칭 경합 < VT 98 스레드).

## 결론 / 권장
- **shop-core HTTP 요청 경로에서 VT의 throughput 이득은 없다**(CPU/처리 바운드). VT의 구체 이득은 **플랫폼 스레드/메모리 자원 효율**(~1/3)이다.
- 따라서 **현 단계 VT 미도입 유지가 합리적**(CLAUDE.md "즉시 활성화 안 함"과 정합). 성능(throughput) 목적의 채택 근거는 없다.
- **채택 가치가 생기는 시점**: (a) 동시성이 매우 높아 플랫폼 스레드 수/메모리가 부담이 될 때(자원 효율), (b) **풀 밖에서 오래 블로킹하는 경로(외부 서비스 호출 등)** 가 생길 때(이땐 throughput 이득 가능). shop-core엔 아직 (b)가 없음.
- **빈은 기본 off로 보존**(`VirtualThreadConfig`, 조건부) — 위 시점에 토글로 켜고 재측정.
- **notification SMTP**(외부 소켓 블로킹)는 VT가 빛날 수 있는 별개 영역 → Task 007 후보(단 SMTP 서버 한도가 진짜 천장, VT+rate바운드 필수).

## 후속
- 더 엄밀히 보려면: 전용 머신(k6/앱/DB 분리)에서 재측정(동거 CPU 공유 제거), 풀=250+PG max_connections 상향 셀(과한 풀 역효과 확인)·외부 블로킹 경로 시뮬레이션.
- 본 결과로 "VT=자원 효율 도구, throughput 지렛대 아님"은 확보됨. 최종 채택/ADR은 사용자 결정.
- 측정 산출물: `build/k6/vt-cell{1..4}-*.json`(런타임, gitignore).

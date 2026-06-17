# 047. HikariCP 커넥션 풀 right-size + 설정 드리프트 정렬 (레포 10 / 런타임 100 → ~30)

> 출처: `docs/report/performance/003-order-create-saturation-bottleneck.md` §5-1(권고). 분산 order-create 고RPS 풀 스윕에서 **피크는 ~30~50(~174/s)**, **레포 기본 10은 풀-바운드(과소, -15%)**, **런타임 100은 과대(피크보다 ~5% 낮고 PG 고갈 위험)**.
> 관련: backlog 3순위(`docs/backlog/performance/001-...`), 측정 하니스 Task 008.

## 배경 (측정 확정 — 곡선)
- report 003 풀 스윕(분산 N=50, →600rps, 셀당 1런): **10:150 → 30:173 → 50:174(피크) → 80:171.5 → 100:165** orders/s. 즉 **10→30 급상승(+15%), 30~50 피크, 50→100 완만 하락**. 풀을 무작정 키우면 PG 동시 트랜잭션 경합으로 **역효과**(100: dropped↑·p95↑·proc_cpu 0.9 스파이크, throughput은 오히려 ↓).
- **두 개의 드리프트**가 공존한다(둘 다 부적정):
  - 레포 `application.yml` 기본값 **10**(`${SHOP_CORE_HIKARI_MAX_POOL:10}`) — 의도적 "측정 가드"였으나 운영엔 과소(풀-바운드).
  - 런타임 오버라이드 **100**(`SHOP_CORE_HIKARI_MAX_POOL=100`, 실행 환경에서 주입 — 레포에 없음) — 과대. throughput 이득 0 + **PG `max_connections=100`** 단일 인스턴스 점유·멀티 인스턴스 초과(측정 중 `too many clients already` 실증).
- 적정값은 **~30**(피크 근처 + 멀티 인스턴스 안전: 3×30=90<100).

## Target / Goal
HikariCP `maximum-pool-size`를 **레포 기본값(10)과 런타임 오버라이드(100) 양쪽 드리프트를 ~30으로 정렬**한다. "상향"이 아니라 **right-size**: 10은 올리고 100은 내려, 피크 처리량 + PG 안전을 동시 확보. env(`SHOP_CORE_HIKARI_MAX_POOL`) 오버라이드 메커니즘은 유지(환경별 조정 가능)하되, **운영 기본을 ~30으로 두고 100 오버라이드는 제거**한다.

## 범위 (Scope)
### 값 확정 (측정 — 코드 변경 전)
- 후보 풀 **20 vs 30 (vs 50)**을 saturate(N=50, →600rps)로 **각 3런** 측정(단발 변동 ±10~30% 배제 — report 001 §7, [[k6-perf-baseline-needs-clean-db]]). report 003은 셀당 1런이라 운영값 확정 전 다회로 굳힌다.
- 선정 기준: 피크 처리량(30~50) + **멀티 인스턴스 PG 안전**(인스턴스 수 × 풀 < 100). 보수적·안전 우선이면 **30**(3인스턴스 90), 인스턴스 1~2개 확정이면 50까지 허용. **100은 후보 아님(과대·역효과·PG 위험 — 실측 확정).**

### 설정 변경 (backend-implementor)
- `application.yml` `maximum-pool-size` 기본값을 확정값으로(`${SHOP_CORE_HIKARI_MAX_POOL:30}` 등). env 플레이스홀더·오버라이드 메커니즘 유지.
- 주석 갱신: "측정 가드 10"이 아니라 "report 003 실측 기반 운영 기본값(피크 ~30)"임을 명시. 변경 근거(리포트 경로) 1줄.
- **런타임 100 오버라이드 제거**: 배포/실행 환경의 `SHOP_CORE_HIKARI_MAX_POOL=100`을 제거(또는 ~30으로)하도록 배포 문서/체크리스트에 명시(이건 레포 코드가 아닌 운영 설정 — 정렬 누락 시 기본값 변경이 무의미).

### PG 정합 (필수 점검)
- PostgreSQL `max_connections`(=100, 확정) 대비 **(앱 인스턴스 수) × (풀 크기) + 여유**가 한도 내인지 점검. 풀 30이면 3인스턴스=90 안전, 100이면 1인스턴스로도 위험. 운영 인스턴스 수 전제를 문서/주석에 명시.

## Non-goals
- **전용 perf 환경 재측정** — report 003 §5-2(머신 CPU 공유로 ~174/s 천장은 비대표적). 별도 task. 본 Task는 "10 과소·100 과대"를 ~30으로 정렬하는 것(전체 용량 산정 아님).
- 락 창 단축(backlog 1순위)·조건부 UPDATE(2순위)·아키텍처(4순위) — 일반 트래픽 병목 아님(report 002·003).
- PG `max_connections` 자체 상향 — 인프라 변경, 별도. 본 Task는 풀을 PG 한도 내로.
- 가상스레드 — throughput 지렛대 아님(report 001).

## 검증
- **측정**: 후보값 3런으로 처리량 이득이 단발 노이즈 아님을 확인(분포 비중첩), `order_5xx==0`(풀 늘려도 락 붕괴 없음), hikari pending 감소 확인.
- **설정 적용**: 앱 기동 후 `hikaricp_connections_max`가 새 기본값인지(env 미지정 시) 확인.
- **회귀**: 풀은 런타임 설정이라 `./gradlew test`(JPA 자동설정 제외 프로파일)에 영향 없음 예상 — 풀 게이트로 확인. 기존 60rps load 베이스라인은 포화점 아래라 풀 무관(불변).
- **PG 한도**: 전제한 인스턴스 수 × 새 풀 < `max_connections` 확인.

## 참고
- 측정 근거: `docs/report/performance/003-order-create-saturation-bottleneck.md`(§3 풀 스윕 표·§5-1 권고).
- 설정: `shop-core/src/main/resources/application.yml`(hikari `maximum-pool-size` ~line 14), env `SHOP_CORE_HIKARI_MAX_POOL`.
- 측정 하니스: `shop-core/perf/k6`(saturate 프로파일·scrape-metrics.py — Task 008).
- 방법론: report 001 §7(다회·gradle 데몬 함정), [[k6-perf-baseline-needs-clean-db]].

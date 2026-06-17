# 047. HikariCP 커넥션 풀 기본값 상향 (10 → 측정 확정값)

> 출처: `docs/report/performance/003-order-create-saturation-bottleneck.md` §5-1(권고). 분산 order-create 고RPS에서 **기본 풀 10이 풀-바운드**(hikari pending 평균 93·app CPU 19%)로 측정됨. 풀 10→30 처리량 **실측 +15%(150→173/s)**.
> 관련: backlog 3순위(`docs/backlog/performance/001-...`), 측정 하니스 Task 008.

## 배경 (측정 확정)
- report 003 풀 스윕(분산 N=50, →600rps): 풀 10은 hikari **pending 평균 93·최대 189**인데 **app CPU 19%** → 앱은 노는데 커넥션이 없어 막힌 **풀-바운드**. 풀 30으로 키우면 처리량 150→173/s(+15%), dropped 96→74/s, pending 93→75로 개선. **풀 30→50은 평탄(~174/s)** — 그 위는 머신(PG CPU 공유) 한계.
- 현재 `application.yml`: `maximum-pool-size: ${SHOP_CORE_HIKARI_MAX_POOL:10}`. **기본 10은 의도적 "측정 가드"**(커밋 "hikari 풀 기본값 10 복원 + VT 토글 기본 off")였다 — 측정 환경 통제용. 본 Task는 **측정이 끝났으니 운영 기본값을 실측 근거로 상향**한다.

## Target / Goal
`application.yml`의 HikariCP `maximum-pool-size` **운영 기본값을 10 → 측정 확정값(후보 20 또는 30)**으로 올린다. env(`SHOP_CORE_HIKARI_MAX_POOL`) 오버라이드는 유지(측정·환경별 조정 가능). 목적은 고RPS write 경로의 풀-바운드 해소로 처리량을 회복하는 것.

## 범위 (Scope)
### 값 확정 (측정 — 코드 변경 전)
- 후보 풀 **10 vs 20 vs 30**을 saturate(N=50, →600rps) 또는 load로 **각 3런** 측정(단발 변동 ±10~30% 배제 — report 001 §7, [[k6-perf-baseline-needs-clean-db]]). report 003은 셀당 1런이라 운영값 확정 전 다회로 굳힌다.
- 선정 기준: 처리량 이득이 **유의(3런 분포 비중첩)**하면서 **수확 체감 직전** + 커넥션 비용. report 003 추세상 **20~30 구간**(10→30 큰 이득, 30→50 평탄). 보수적이면 20, 이득 우선이면 30.

### 설정 변경 (backend-implementor)
- `application.yml` `maximum-pool-size` 기본값을 확정값으로(`${SHOP_CORE_HIKARI_MAX_POOL:20}` 등). env 플레이스홀더·오버라이드 유지.
- 주석 갱신: "측정 가드 10"이 아니라 "report 003 실측 기반 운영 기본값"임을 명시. 변경 근거(리포트 경로) 1줄.

### PG 정합 (필수 점검)
- PostgreSQL `max_connections`(기본 100) 대비 **(앱 인스턴스 수) × (풀 크기) + 여유**가 한도 내인지 점검. 다중 인스턴스 배포 시 풀 30이면 3인스턴스=90 → 여유 부족 가능. 운영 인스턴스 수 전제를 문서/주석에 명시(단일~소수 전제면 20~30 안전).

## Non-goals
- **전용 perf 환경 재측정** — report 003 §5-2(머신 CPU 공유로 ~174/s 천장은 비대표적). 별도 task. 본 Task는 "풀 10이 과소"라는 명확한 부분만 교정(전체 용량 산정 아님).
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

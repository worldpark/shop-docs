# k6 load 목표 RPS 하향 (100→60) — 포화점 측정 flaky 제거 (Revision 1)

- 대상: Task 002 load 프로파일(`docs/tasks/performance/002-...load-profile.md`, plan `docs/plans/performance/002-...-plan.md`)
- 결정 일자: 2026-06-16
- 결정자: 사용자
- 목적: 002에서 확정했던 load 목표 **100rps를 60rps로 낮춘** 이유와 그에 따른 thresholds 재확정을 기록한다.

## 배경 — 무엇이 flaky했나
Task 003(stress) 구현 중 회귀 검증에서, **깨끗한 DB인데도 load(100rps)가 런마다 p95=18ms\~143ms로 크게 흔들리는** 것을 관측했다(같은 코드, 다른 런). med는 ~15ms로 동일했고 꼬리(p90+)만 폭발했다.

## 근본 원인
- 앱의 주문 생성 처리 상한 ≈ **90\~100 orders/s**(단일 variant `PESSIMISTIC_WRITE` 직렬화).
- **100rps는 이 상한과 거의 같다 → "포화점에서 측정"**. 포화점에서는 open 모델(`constant-arrival-rate`)이 본질적으로 불안정하다:
  - VU를 많이 허용(maxVUs=50)하면 → 단일 variant 락에 과투입 → 자기유발 경합 → **지연 캐스케이드**(positive feedback: VU↑→경합↑→지연↑→VU↑).
  - VU를 적게 막으면 → 100rps를 못 채워 **dropped_iterations 폭증**.
  - 둘 중 하나로 항상 flaky.
- 또한 load(100) ≈ stress-knee(120)로 **역할이 겹쳤다**.

## 결정
1. **load 목표를 60rps로 낮춘다**(포화점·knee 아래). 60rps에서는 VU가 ~5개로 안정(에스컬레이션 없음), p95≈22ms·p99≈54ms·dropped=0으로 **run-to-run 변동이 작다**. 실측 확정.
2. **thresholds 재확정**(깨끗한 DB 60rps 실측 × ~2.5, smoke와 일관): `p(95)<60`(22×2.5), `p(99)<150`(54×2.5). 기존 `p(95)<50`/`p(99)<100`(100rps 기준)을 대체.
3. VU 풀도 하향: `preAllocatedVUs=15, maxVUs=30`(60rps엔 ~5개면 충분, 캐스케이드 상한도 낮춤).
4. **역할 분리 명문화**: **load = 지속가능 운영수준**(포화점 아래, 안정·의미 있는 회귀 임계), **stress = 한계·붕괴점(knee≈120rps) 탐색**. 더는 겹치지 않는다.

## 버린 대안
- **임계만 완화**(예 p95<300): 포화점 변동(18\~143ms)을 덮으려면 과대 여유가 필요해 **회귀 감지가 무력화**되고, dropped 쪽 변동도 잔존 → 기각.
- **maxVUs만 축소**: 포화점에선 캐스케이드를 dropped로 바꿀 뿐(여전히 경계 flaky) → 근본 해결 아님.

## 결과 / 산출물
- `lib/config.js`: `PROFILES.load.rate=60`, `preAllocatedVUs=15`, `maxVUs=30`, `LOAD_THRESHOLDS` p95<60·p99<150. 주석에 근거.
- `profiles/load.js`·`README.md`(§5 설계·§6.5 표·§7 임계): 60rps + "왜 100→60" 기록.
- `baselines/order-create-load.json`: 60rps 깨끗한 DB 재측정으로 교체(p95≈22ms, p99≈35ms, 임베드 임계 p95<60/p99<150, 토큰 제외).
- smoke·stress 프로파일 무영향(PROFILES.load·LOAD_THRESHOLDS만 변경).

## 보존되는 사실
- 100/200/300rps 탐색 데이터는 "왜 100이 포화점인가"의 근거로 README §6.5에 남는다(기준 아님, 맥락).
- 베이스라인은 반드시 깨끗한 DB에서 측정한다([[k6-perf-baseline-needs-clean-db]] — 누적 주문이 별개로 성능을 떨어뜨림).

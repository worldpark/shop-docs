# 002. shop-core k6 부하 테스트 2차 — order-create load 프로파일 + 목표 부하 thresholds 확정

> 출처: 로드맵 `docs/tasks/performance/performance-shop-core-k6-load-test-roadmap.md` §12·§15, Task 001 "후속 Task" 2차. 1차(Task 001)가 만든 하니스(lib + order-create 시나리오 + smoke 프로파일)를 **재사용**해 목표 부하 프로파일을 추가하는 단일 기능 Task다("한 Task = 한 기능").

## 계승하는 결정 (재논의 금지)
- **도구/타겟/게이트/환경/출력**: 로드맵 §2 결정 그대로(k6 / 외부 앱 타겟 A `BASE_URL` / 머지 게이트 제외·온디맨드 / docker-compose 실 스택 / summary+JSON). Task 001과 동일.
- **하니스 재사용**: `shop-core/perf/k6/lib`(config·auth·seed)와 `scenarios/order-create.js`를 그대로 쓴다. 본 Task는 **프로파일만 추가**하고 시나리오 흐름은 바꾸지 않는다(중복 제거 우선).
- **블랙박스 한정**: 관측성(Actuator+Micrometer)이 ADR-010으로 도입되었으나, k6는 여전히 "SLO를 지키나"의 pass/fail까지만 한다. "왜 느린가"의 서버측 상관분석은 별도 트랙(로드맵 §15)으로 두고 본 Task에 섞지 않는다.

## 배경
- Task 001 smoke 베이스라인(2026-06-16, 5 VU × 30s): `http_req_duration` p95≈40ms·p99≈53ms, 에러율 0%, `order_5xx` 0, 주문 ~110 orders/s. **현재 thresholds(`lib/config.js`: p95<100·p99<200)는 smoke 기준**이다.
- smoke는 "스크립트 정상 동작 확인"이 목적이라 **부하량을 고정하지 않는다**(VU×duration의 closed 모델 — 총 요청 수가 응답시간에 따라 파생). 따라서 **"초당 N건(목표 RPS)을 SLO 내에 견디는가"**라는 처리량 판정은 아직 못 한다. 이 공백을 메우는 게 본 Task다.
- 주문 생성은 동일/소수 `VariantStock`에 `PESSIMISTIC_WRITE`가 직렬화되는 지점이라, **부하를 올리면 락 경합으로 지연·throughput이 어떻게 변하는지**가 핵심 관측 대상이다(로드맵 §6 1순위).

## 기술 선택
- **load 프로파일은 open 모델(arrival-rate)로 한다.** smoke의 `vus+duration`(closed)은 제공 부하가 응답시간에 종속돼 처리량 SLO 판정에 부적합하다. load는 **`constant-arrival-rate`(목표 RPS 고정)** 또는 워밍업이 필요하면 **`ramping-arrival-rate`(목표 RPS까지 점증 후 plateau 유지)**를 쓴다. 이로써 "락 경합이 목표 RPS를 SLO 안에서 흡수하는가"를 직접 본다.
  - `preAllocatedVUs`/`maxVUs`로 도착률을 채울 VU 풀을 잡는다(응답이 느려지면 VU가 늘어 목표 RPS 유지 시도 → 한계 도달 시 `dropped_iterations`로 드러남 — 침묵 0 RPS 방지).

## Target
`shop-core/perf/k6/profiles/load.js`(신규) + `lib/config.js`의 PROFILES/thresholds 보강. **시나리오·시드 흐름·앱 코드·빌드는 변경하지 않는다.**

## Goal
order-create 핫패스에 **목표 부하(고정 RPS)**를 가해 지속 부하 하의 p95/p99·에러율·`order_5xx`를 측정하고, 그 실측으로 **목표 부하용 thresholds 절대값을 확정**한다(smoke값을 그대로 쓰지 않고 load 측정으로 재확정). 목적은 절대 SLA 합의가 아니라 **추세 회귀 감시의 부하 기준선**을 세우는 것이다(로드맵 §9).

## 범위 (Scope)
- **`profiles/load.js`**: `constant-arrival-rate`(또는 `ramping-arrival-rate`) executor로 `options`를 export. 목표 RPS·duration·`preAllocatedVUs`/`maxVUs`는 plan에서 베이스라인 측정으로 확정(출발 후보: smoke ~110 orders/s를 참고해 그 이상으로 점증, 락 경합이 드러나는 지점까지). `lib/config.js`의 `PROFILES.load`에 파라미터를 두고 `-e PROFILE=load`로 분기(smoke와 동일 패턴).
- **시드 buyer 수 스케일링**: 시나리오의 buyer 매핑(`data.buyers[(__VU-1)%N]`, Task 001)이 arrival-rate의 `maxVUs`까지 충돌 없이 동작하도록, `seed.js`가 **프로파일의 maxVUs만큼 buyer를 시드**하게 한다(현재 smoke는 maxVU=5). variant 재고(`SEED.VARIANT_STOCK=1,000,000`)는 load×duration을 흡수하는지 점검(필요 시 상향). **앱/시드 흐름의 구조는 유지**하고 수량만 프로파일 구동.
- **토큰 수명**: load 런이 access TTL(기본 30분)보다 짧으면 1회 발급으로 충분. 더 길게 돌릴 계획이면 갱신 로직 — 본 Task의 load는 수 분 규모로 잡아 **단일 발급 유지**(갱신은 3차 stress에서 검토).
- **thresholds(load 전용) 확정**: load 실측 p95/p99/에러율로 값을 정한다. smoke와 부하 수준이 다르므로 **load 기준값을 별도로** 둔다(예: PROFILE별 thresholds 분기, 또는 load용 키). `http_req_failed` rate<1%, `order_5xx` count==0(락 붕괴=비정상)은 유지. `order_conflict`(409)는 임계로 죽이지 않되 **부하에서 비정상 폭증**은 가시화.
- **베이스라인 측정·기록**: docker-compose 실 스택 + 앱 기동 상태에서 load 1회 실행 → summary/JSON 확인 → `lib/config.js`에 load thresholds 기입 + `baselines/order-create-load.json` 보관(추세 비교).

## Non-goals (3차 이후)
- `profiles/stress.js`(점증 한계 탐색·붕괴점) — 3차.
- `scenarios/payment-confirm.js`·`coupon-apply.js` — 3차(로드맵 §6 2·3순위).
- nightly 파이프라인·JSON 추세 자동 비교 — 보류(로드맵 §15).
- TSDB(Grafana/InfluxDB)·분산 부하(k6 Cloud) — 보류.
- 토큰 갱신 로직(긴 런) — 본 Task의 load는 단일 발급 규모. stress에서 검토.
- 관측성 연계 원인 규명("왜 느린가") — 별도 트랙(로드맵 §15).
- 앱/빌드 코드 변경 — 없음. k6 자산만.

## 예외/오류 처리 전략
- **목표 RPS 미달(under-provision)**: arrival-rate가 목표를 못 채우면 k6 `dropped_iterations`가 증가한다. 이를 summary로 확인하고, "조용한 저부하"로 위장되지 않게 한다(필요 시 `maxVUs` 상향 또는 목표 RPS 현실화).
- **재고 고갈**: load×duration이 `VARIANT_STOCK`를 초과하면 주문이 409로 무더기 실패(락 붕괴가 아니라 시드 부족). 재고를 넉넉히(또는 duration·RPS에 맞춰) 잡아 베이스라인이 오염되지 않게 한다.
- **시드 실패(setup)**: Task 001과 동일 — 즉시 throw로 런 중단.

## 검증 방법
- **load 실행 통과**: `BASE_URL=http://localhost:8080 k6 run -e PROFILE=load shop-core/perf/k6/scenarios/order-create.js --summary-export=build/k6/order-create-load.json`가 비정상 종료 없이 완료하고 확정한 load thresholds를 만족한다(위반 시 non-zero exit → 판정 게이트).
- **목표 부하 달성 확인**: summary의 달성 RPS(`http_reqs`/`iterations` rate)가 목표 근처이고 `dropped_iterations`가 과도하지 않음(목표를 실제로 가했음을 입증).
- **정합 흔적 0(blackbox)**: `order_5xx`==0, 음수 재고·5xx가 SLO 밖으로 나타나지 않음.
- **JSON 아티팩트**: `baselines/order-create-load.json` 산출·보관(추세 비교 출발점). `build/`는 gitignore이므로 baselines로 복사(Task 001 선례).
- **재현 절차**: README에 load 실행·목표 부하·thresholds 확정 절차 추가(Task 001 README 확장).
- Java 빌드 무관 — `./gradlew test` 게이트 대상 아님(로드맵 §4).

## 트레이드오프
- **open(arrival-rate) vs closed(vus+duration)**: open 채택 — 처리량 SLO("목표 RPS를 SLO 내에 견디나")를 응답시간 종속 없이 본다. closed는 smoke(정상성 확인)에 적합하나 부하 판정엔 부적합.
- **load 전용 thresholds 분리 vs smoke값 재사용**: 분리 — 부하 수준이 달라 같은 임계로 묶으면 회귀 신호가 흐려진다. PROFILE별로 둔다.
- **목표 RPS 절대값**: 개발 머신 단일 런 기준이라 절대 SLA가 아니다. "추세 회귀 감시"용 재현 기준선으로만 쓰고, 운영 SLA는 전용 perf 환경에서 후속 합의(로드맵 §9·§15).

## 참고
- 로드맵: `docs/tasks/performance/performance-shop-core-k6-load-test-roadmap.md`(§6 핫패스, §8 구조, §9 thresholds, §15 후속)
- 1차 Task/plan: `docs/tasks/performance/001-...smoke-baseline.md`, `docs/plans/performance/001-...smoke-baseline-plan.md`
- 1차 하니스: `shop-core/perf/k6/{lib,scenarios/order-create.js,profiles/smoke.js}`, smoke 베이스라인 `shop-core/perf/k6/baselines/order-create-smoke.json`
- 구현 담당: `k6-implementor`(메인 오케스트레이션은 메인 에이전트)

## 후속 Task (본 Task 범위 밖)
- 3차: `profiles/stress.js`(점증 한계·붕괴점 탐색, 토큰 갱신), `scenarios/payment-confirm.js`(주문 행 락 + Outbox), `scenarios/coupon-apply.js`(쿠폰 사용 동시성).
- nightly 파이프라인 + JSON 추세 자동 비교, 시드/정리 자동화(teardown self-clean).
- (ADR-010 관측성 도입 후) k6 부하 구간 ↔ 서버측 메트릭 상관분석.

# 003. shop-core k6 부하 테스트 3차-a — order-create stress 프로파일 (한계·붕괴점 탐색)

> 출처: 로드맵 `docs/tasks/performance/performance-shop-core-k6-load-test-roadmap.md` §8·§15, Task 002 "후속 Task" 3차. 1·2차 하니스를 재사용해 **점증 부하로 한계/붕괴점을 탐색**하는 단일 기능 Task다("한 Task = 한 기능").
>
> **선행: Task 002(load 프로파일).** 본 Task는 load의 베이스라인·arrival-rate executor 패턴 위에서 부하를 점증시킨다. **002 미구현 상태에서 본 문서를 먼저 작성하되, 구현은 002 → 003 순서**로 한다(load 기준선이 있어야 "어디서 무너지는가"를 판정할 수 있다).

## 계승하는 결정 (재논의 금지)
- 도구/타겟 A/게이트 제외/실 스택/summary+JSON — 로드맵 §2. 1·2차와 동일.
- **하니스·시나리오 재사용**: `lib`·`scenarios/order-create.js`를 그대로 쓰고 **프로파일만 추가**(`stress.js`). 시나리오 흐름 무변경.
- **블랙박스 한정**: stress도 "어디까지 SLO를 지키다 무너지나"의 pass/fail·관측까지. 서버측 원인 규명은 별도(로드맵 §15 / ADR-010 관측성 트랙).

## 배경
- smoke(정상성)·load(목표 RPS SLO)는 **정상~목표 범위**만 본다. **목표를 넘어 어디서 p95/에러율이 SLO를 깨고 throughput이 꺾이는지(붕괴점)**는 미측정이다. 비관적 락(주문 생성 `VariantStock` PESSIMISTIC_WRITE)이 **경합 폭증 시 어떻게 열화되는가**가 stress의 핵심 관측 대상이다(로드맵 §6 1순위 심화).
- load와 달리 stress는 **길고 점증**하므로, 1·2차가 미룬 **JWT 토큰 갱신**이 본 Task에서 필요해진다(access TTL 기본 30분 초과 가능).

## 기술 선택
- **`ramping-arrival-rate`(점증 도착률)** executor로 목표 RPS를 단계적으로 올린다(예: load 목표 → 2× → 4× … plateau 구간들). open 모델이라 응답 열화가 `dropped_iterations`·p95 급증으로 드러난다.
- **붕괴점 판정**: 절대 thresholds로 런을 죽이기보다, **단계별 p95/에러율/throughput 곡선**을 산출해 "SLO를 마지막으로 지킨 RPS"를 기록한다(stress의 목적은 게이트 통과가 아니라 한계 발견). 단 `order_5xx`(락 붕괴)·비정상 5xx는 여전히 비정상으로 표기.

## Target
`shop-core/perf/k6/profiles/stress.js`(신규) + `lib/auth.js`에 **토큰 갱신 로직** 추가 + `lib/config.js` PROFILES 보강. **시나리오·앱 코드·빌드 무변경.**

## Goal
order-create 핫패스에 점증 부하를 가해 **SLO를 지키는 최대 RPS(붕괴점)와 그 이후 열화 양상**을 측정·기록한다. 목적은 SLA 합의가 아니라 **용량 한계의 재현 가능한 기준선**과 **회귀(붕괴점이 앞당겨지면 경고)** 감시다.

## 범위 (Scope)
- **`profiles/stress.js`**: `ramping-arrival-rate` stages(점증→plateau 반복)를 `options`로 export. 단계·목표 RPS·`preAllocatedVUs`/`maxVUs`는 plan에서 load 베이스라인 기준으로 확정. `-e PROFILE=stress` 분기(smoke/load와 동일 패턴).
- **토큰 갱신(`lib/auth.js`)**: 런이 access TTL보다 길 수 있으므로 `POST /api/v1/auth/refresh`로 토큰을 주기 갱신하거나 만료 임박 시 재로그인. setup의 buyer 토큰을 VU가 갱신 가능하게 한다(1·2차의 "단일 발급" 한계 해소).
- **시드 스케일**: arrival-rate `maxVUs`까지 buyer 시드(002 패턴 계승), `VARIANT_STOCK`이 stress duration×최대 RPS를 흡수하는지 점검(재고 고갈 409가 붕괴로 오인되지 않게 — 넉넉히).
- **산출/기록**: 단계별 메트릭을 summary/JSON으로 산출, `baselines/order-create-stress.json` 보관. README에 stress 실행·붕괴점 해석 절차 추가.

## Non-goals
- payment/coupon 시나리오 — 별 Task(004/005).
- 절대 SLA 합의, 분산 부하(k6 Cloud), TSDB/대시보드 — 보류.
- 서버측 원인 규명 — 관측성 트랙(로드맵 §15).
- 앱/빌드 변경 — 없음.

## 검증 방법
- **stress 실행 완료**: `k6 run -e PROFILE=stress ... order-create.js`가 완료되고 단계별 메트릭이 산출된다(thresholds로 죽이지 않으므로 "완료 + 곡선 산출"이 통과 기준). `order_5xx`==0(락 붕괴 부재) 확인.
- **붕괴점 기록**: "SLO(load 기준 p95/에러율)를 마지막으로 지킨 RPS"를 README/baselines에 명문화.
- **토큰 갱신 동작**: 장시간 런에서 401 급증 없이 토큰이 갱신됨(미갱신 시 후반부 전량 401로 위장됨 — 그 부재 확인).
- **JSON 아티팩트**: `baselines/order-create-stress.json` 산출.
- `./gradlew test` 게이트 무관(로드맵 §4).

## 참고
- 로드맵 §6·§8·§9·§15, Task 001/002 및 plan, 하니스 `shop-core/perf/k6/**`
- 구현 담당: `k6-implementor`

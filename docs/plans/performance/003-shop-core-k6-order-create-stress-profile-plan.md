# Plan 003. shop-core k6 order-create stress 프로파일 (한계·붕괴점 탐색 + 토큰 갱신)

> 대상 Task: `docs/tasks/performance/003-performance-shop-core-k6-order-create-stress-profile.md`
> 선행: Task 002(load, 완료). load 베이스라인·arrival-rate 패턴 위에서 점증.
> 구현 담당: `k6-implementor` (메인 오케스트레이션·파괴적 DB 정리는 메인 에이전트)

## 1. 목표
`order-create.js`를 재사용해 **점증 부하(ramping-arrival-rate)로 SLO를 지키는 최대 RPS(붕괴점)와 이후 열화 양상**을 측정·기록한다. 길어질 수 있는 stress 런을 위해 **JWT 토큰 갱신**을 하니스에 추가한다. 앱/빌드 무변경.

## 2. 변경 대상 파일
- `shop-core/perf/k6/profiles/stress.js` — **신규**. `ramping-arrival-rate` stages export.
- `shop-core/perf/k6/lib/config.js` — `PROFILES.stress` + 진단용 `STRESS_THRESHOLDS`(느슨 — 곡선 측정이 목적).
- `shop-core/perf/k6/lib/auth.js` — **토큰 갱신 헬퍼**(`getValidToken`) 추가(`POST /api/v1/auth/refresh`).
- `shop-core/perf/k6/lib/seed.js` — buyer 객체에 `refreshToken`·`issuedAt` 저장(현재 accessToken만).
- `shop-core/perf/k6/scenarios/order-create.js` — VU 본문에서 `getValidToken(buyer)`로 토큰 획득(최소 1줄 변경, smoke/load 무영향).
- `shop-core/perf/k6/README.md` — stress 실행·붕괴점 해석·토큰 갱신 절차.
- 산출: `shop-core/perf/k6/baselines/order-create-stress.json`.

## 3. 002가 좁혀준 탐색 구간 (출발점)
002 §6.5 실측: **100rps 정상**(p95=18ms, dropped 0) / **200rps 붕괴**(p95=634ms, dropped 71/s) / 300rps(p95=886ms). → 붕괴점은 **100~200rps 사이**. stress는 이 구간을 **정밀 점증**해 knee를 찾는다.

## 4. executor 설계 (ramping-arrival-rate)
```js
PROFILES.stress = {
  kind: 'ramping-arrival-rate',
  startRate: 50, timeUnit: '1s',
  preAllocatedVUs: 50, maxVUs: 200,   // 고RPS×열화 지연 흡수용 충분히 크게
  stages: [
    { target: 100, duration: '30s' },   // 워밍업/정상 구간
    { target: 120, duration: '45s' },
    { target: 140, duration: '45s' },
    { target: 160, duration: '45s' },
    { target: 180, duration: '45s' },
    { target: 200, duration: '45s' },   // 붕괴 구간까지
    { target: 0,   duration: '15s' },   // 쿨다운
  ],
  thresholds: STRESS_THRESHOLDS,
};
```
- 총 ~5분(< access TTL 30분 — 토큰 갱신은 *기능*으로 넣되 이 런에선 안 터질 수 있음 → §6에서 별도 검증).
- 단계별 p95/dropped는 **k6 stdout 주기 출력 + (관측성 도입됨) Grafana 시계열**로 읽어 knee를 식별한다(aggregate summary는 단계 분리가 안 됨 — 이 한계를 README에 명시).

## 5. thresholds — 진단용(느슨), 게이트 아님
stress는 "어디서 무너지나"를 보는 것이지 통과/실패 게이트가 아니다. **p95/dropped로 런을 죽이지 않는다**(그게 측정 대상이므로).
```js
STRESS_THRESHOLDS = {
  ...BUSINESS_THRESHOLDS,   // http_req_failed rate<0.01, order_5xx count==0
  // http_req_duration / dropped_iterations 임계 없음 — 곡선으로 관찰.
};
```
- **`order_5xx: count==0` 유지**: 과부하라도 비관적 락은 *느려질 뿐 5xx로 무너지면 안 된다*. 5xx가 나오면 진짜 붕괴(락 데드락·풀 고갈 등) → 비정상.
- `http_req_failed`: 과부하 시 타임아웃이 실패로 잡힐 수 있으니, 통과 기준은 "런 완료 + 곡선 산출 + order_5xx==0". 만약 http_req_failed가 위반되면 그건 곡선의 일부로 기록(README에 해석).

## 6. 토큰 갱신 설계
- **seed**: buyer = `{ accessToken, refreshToken, issuedAt }`(로그인 응답의 refreshToken·발급시각 저장).
- **`getValidToken(buyer)`(auth.js)**: VU-로컬 캐시. 토큰 나이가 `__ENV.TOKEN_REFRESH_AFTER_SEC`(기본 1500=25분, TTL 30분 - 버퍼) 초과면 `POST /api/v1/auth/refresh {refreshToken}`로 새 accessToken 획득·캐시. 그 외엔 기존 토큰 반환. k6 VU는 이터레이션 간 모듈 스코프 상태가 유지되므로 VU별 캐시가 가능.
- **smoke/load 무영향**: 짧은 런(30s~1m)은 `TOKEN_REFRESH_AFTER_SEC`(25분)에 도달 못 해 절대 갱신 안 함 → 기존 동작 동일.
- **검증 가능성(§8)**: `TOKEN_REFRESH_AFTER_SEC`를 작게(예 5초) 주면 짧은 런에서도 갱신이 강제 발화 → 갱신 로직을 결정적으로 검증.

## 7. 시나리오 본문 변경(최소)
order-create.js default(): `const token = getValidToken(buyer);` 한 줄 추가 후 `authHeaders(token)` 사용. 나머지(cart→order 흐름·커스텀 메트릭) 무변경. smoke/load도 같은 경로지만 갱신 미발화로 무영향.

## 8. 측정·검증 (메인 + k6-implementor 분담)
- **(메인) 깨끗한 DB**: stress는 고RPS로 대량 주문을 만들므로, 베이스라인 전 메인이 테스트 주문/장바구니를 TRUNCATE(누적 열화 방지 — 메모리 "k6 부하 베이스라인은 깨끗한 DB에서"). 사용자 승인된 정리 방식.
- **(k6-implementor) 구현 + 검증**:
  1. `k6 archive`로 정적 검증(파싱·import).
  2. **토큰 갱신 기능 검증**: `-e PROFILE=smoke -e TOKEN_REFRESH_AFTER_SEC=5`로 짧게 실행 → 갱신이 발화하고 401 없이 통과(refresh 경로 동작 확인). 소량 주문만 생성.
  3. **stress 베이스라인 실행**(깨끗한 DB): `BASE_URL=... SUMMARY_EXPORT_PATH=shop-core/perf/k6/baselines/order-create-stress.json k6 run -e PROFILE=stress ...`. 완료(비정상 종료 없음) + `order_5xx==0` 확인. stdout 주기 출력으로 **knee(SLO 마지막 유지 RPS)** 식별·기록.
  4. baselines JSON에 토큰 미포함(handleSummary) 확인.
- **smoke/load 회귀**: `-e PROFILE=smoke`·`-e PROFILE=load`가 여전히 통과(토큰 헬퍼 추가 후에도).

## 9. 산출/기록
- `baselines/order-create-stress.json`(handleSummary, 토큰 제외).
- README·stress.js 주석에 **knee RPS + 단계별 열화 관찰**(stdout/Grafana 근거) 기록. "SLO를 마지막으로 지킨 RPS"를 명문화.
- 관측성(Prometheus/Grafana) 도입됨 — stress 구간의 서버측 상관(hikaricp 포화·http_server_requests p95)은 Grafana에서 읽을 수 있으나, **본 Task는 k6 클라이언트측 blackbox 곡선까지**(서버측 원인 규명은 별도 트랙, 로드맵 §15). README에 "Grafana로 서버측을 함께 볼 수 있다"만 1줄 안내.

## 10. Non-goals
- payment/coupon 시나리오(004/005), nightly·TSDB 파이프라인, 분산 부하 — 보류.
- 서버측 원인 규명 자동화 — 별도 트랙.
- 앱/빌드/DB 스키마 변경 — 없음(테스트 주문 데이터 TRUNCATE만, 메인 수행).

## 11. 리뷰 관점 (reviewer 체크리스트)
- stress가 `ramping-arrival-rate`로 점증하고, **진단 thresholds가 느슨**(p95/dropped로 안 죽임)하되 `order_5xx==0`은 유지하는가.
- 토큰 갱신: VU-로컬 캐시 + `refresh` 엔드포인트 사용, `TOKEN_REFRESH_AFTER_SEC`로 발화 제어. **smoke/load가 갱신 미발화로 무영향**인가(회귀 0). 갱신 기능이 실제 검증됐는가(low threshold 런).
- 시나리오 본문 변경이 `getValidToken` 도입 최소 수준이고 cart→order 가압 흐름·메트릭 무변경인가.
- 베이스라인이 **깨끗한 DB**에서 측정됐는가(누적 열화 앵커링 금지 — 002 교훈). knee가 stdout/Grafana 근거로 기록됐는가.
- baseline JSON 토큰 미포함, smoke/load 회귀 0, 앱·빌드 무변경.

# Plan 002. shop-core k6 order-create load 프로파일 + 목표 부하 thresholds

> 대상 Task: `docs/tasks/performance/002-performance-shop-core-k6-order-create-load-profile.md`
> 선행: Task 001 하니스(완료). 본 Task는 **프로파일만 추가**하고 시나리오 흐름은 무변경.
> 구현 담당: `k6-implementor` (메인 오케스트레이션은 메인 에이전트)

## 1. 목표
`order-create.js`를 그대로 쓰면서 **목표 RPS를 고정 가압하는 load 프로파일**(open 모델)을 추가하고, 실측으로 **load 전용 thresholds 절대값**을 확정한다. 앱/빌드 무변경.

## 2. 변경 대상 파일
- `shop-core/perf/k6/lib/config.js` — `PROFILES.load` 추가 + **프로파일별 thresholds 분리**(smoke/load).
- `shop-core/perf/k6/scenarios/order-create.js` — `options` 조립을 **closed(vus+duration) / open(arrival-rate) 분기**로 일반화. 시나리오 본문(default/setup 흐름)은 무변경.
- `shop-core/perf/k6/lib/seed.js` — buyer 시드 수를 프로파일의 `maxVUs`(open)까지 확장(현재 `vus`만). setup 호출부 정합.
- `shop-core/perf/k6/profiles/load.js` — load `options` export(smoke.js와 동일 패턴, 선택적 진입점).
- `shop-core/perf/k6/README.md` — load 실행·목표 부하·thresholds 확정 절차 추가.
- 산출: `shop-core/perf/k6/baselines/order-create-load.json`(추세 비교 기준).

## 3. executor 설계 (open 모델)
- **`constant-arrival-rate`** 채택: 목표 RPS를 응답시간과 무관하게 고정 제공(처리량 SLO 판정의 정석). 응답이 느려지면 VU가 `maxVUs`까지 늘어 목표 유지를 시도하고, 못 채우면 `dropped_iterations`로 드러난다(침묵 저부하 방지 — Task §예외처리).
- **단일 variant 경합 특성(중요)**: 시드는 variant 1개만 만들고 모든 VU가 그 한 행에 주문한다 → `VariantStock` 단일 행 `PESSIMISTIC_WRITE`에 집중. load는 이 **락이 목표 RPS를 SLO 내에 직렬화하는지**를 본다. (이게 이 시스템에서 부하 가치가 가장 큰 지점 — 로드맵 §6.)

## 4. config.js 구조 (제안)
프로파일 shape를 `kind`로 구분하고, thresholds를 프로파일별로 둔다.
```js
// 공통 비즈니스 불변식 thresholds (smoke/load 공유)
const BUSINESS_THRESHOLDS = {
  http_req_failed: ['rate<0.01'],
  order_5xx: ['count==0'],
  // order_conflict 는 임계 없음(가시화만)
};

export const SMOKE_THRESHOLDS = {
  ...BUSINESS_THRESHOLDS,
  http_req_duration: ['p(95)<100', 'p(99)<200'],   // 2026-06-16 smoke 베이스라인
};

export const LOAD_THRESHOLDS = {
  ...BUSINESS_THRESHOLDS,
  http_req_duration: ['p(95)<___', 'p(99)<___'],   // PLACEHOLDER: load 실측 후 확정
  dropped_iterations: ['rate<0.01'],                // 목표 RPS 미달(under-provision) 감시
};

export const PROFILES = {
  smoke: { kind: 'closed', vus: 5, duration: '30s', thresholds: SMOKE_THRESHOLDS },
  load:  {
    kind: 'arrival-rate',
    rate: 100, timeUnit: '1s', duration: '1m',      // 시작 목표 — 측정 후 plan §6에서 확정
    preAllocatedVUs: 20, maxVUs: 50,
    thresholds: LOAD_THRESHOLDS,
  },
};
```
- **thresholds 분리 이유**: 부하 수준이 달라 같은 임계로 묶으면 회귀 신호가 흐려진다(Task 트레이드오프).

## 5. order-create.js 옵션 분기 (시나리오 본문 무변경)
```js
const p = PROFILES[PROFILE];
export const options = p.kind === 'arrival-rate'
  ? {
      scenarios: {
        order_create: {
          executor: 'constant-arrival-rate',
          rate: p.rate, timeUnit: p.timeUnit, duration: p.duration,
          preAllocatedVUs: p.preAllocatedVUs, maxVUs: p.maxVUs,
        },
      },
      thresholds: p.thresholds,
    }
  : { vus: p.vus, duration: p.duration, thresholds: p.thresholds };
```
- setup의 buyer 수: `const buyerCount = p.maxVUs || p.vus;` (open이면 maxVUs까지 — VU별 전용 buyer로 카트 교차오염 방지, `(__VU-1)%buyers.length` 매핑 유지). seed.js는 수량만 받으므로 변경 최소.
- **VU 본문(cart add→order create)·커스텀 메트릭은 그대로**. arrival-rate에서도 `__VU`는 1..maxVUs 범위라 buyer 매핑 유효.

## 6. 베이스라인 측정 → 확정 절차 (k6-implementor가 수행)
1. perf 스택 + 앱 기동(localhost:8080, 현재 가동 중). admin 시드 존재(`admin@example.com`).
2. `BASE_URL=http://localhost:8080 k6 run -e PROFILE=load shop-core/perf/k6/scenarios/order-create.js --summary-export=build/k6/order-create-load.json` 실행.
3. summary에서 확인·기록:
   - **달성 RPS**(`http_reqs`/`iterations` rate)가 목표(rate=100) 근처인가, `dropped_iterations`가 과도하지 않은가(목표를 실제로 가했는지 — 아니면 maxVUs 상향 또는 목표 현실화).
   - `http_req_duration` p95/p99, `http_req_failed` rate, `order_5xx`(==0), `order_conflict`.
4. 관측 p95/p99로 `LOAD_THRESHOLDS`의 PLACEHOLDER를 **여유율 적용 round 값**으로 교체(smoke 선례: 관측 ×2~3). 주석에 `// load 베이스라인: YYYY-MM-DD (constant-arrival-rate, <rate>rps×<dur>)` 기입.
5. **목표 RPS 타당성 점검**: 100 RPS가 (a) 트리비얼하게 충족(p95가 smoke와 차이 없음)이면 락 경합이 안 드러난 것 → 목표를 의미 있는 수준으로 상향 재측정, (b) dropped 폭증·p95 급등이면 목표가 한계 근처 → 한계 탐색은 stress(003)로 넘기고 load는 SLO를 지키는 지속 가능 RPS로 하향. **목표값을 측정으로 확정**하고 그 근거를 README/plan에 남긴다.
6. `build/k6/order-create-load.json` → `baselines/order-create-load.json` 복사(`build/`는 gitignore — Task 001 선례).

## 7. 검증
- **load 실행 통과**: 확정 thresholds 하에서 `k6 run -e PROFILE=load ...`가 비정상 종료 없이 완료(위반 시 non-zero exit → 게이트).
- **목표 부하 달성 입증**: 달성 RPS ≈ 목표, dropped_iterations 과도하지 않음.
- **정합 흔적 0(blackbox)**: `order_5xx`==0, 주문 성공률 SLO 내.
- **smoke 회귀 0**: 옵션 분기 일반화 후에도 `k6 run -e PROFILE=smoke ...`가 여전히 통과(closed 모델 무손상). archive 정적 검증도 통과.
- **베이스라인 산출**: `baselines/order-create-load.json` 보관.
- `./gradlew test` 게이트 무관(로드맵 §4).

## 8. plan 확정 결정
1. executor = `constant-arrival-rate`(확정).
2. 시작 목표 = 100 rps × 1m, preAllocatedVUs 20 / maxVUs 50 — **측정으로 §6.5 따라 확정**.
3. thresholds 분리(SMOKE/LOAD), LOAD는 실측 확정. `dropped_iterations` 임계로 under-provision 감시.
4. 토큰 단일 발급 유지(load ~1m < TTL 30m). 갱신은 stress(003).

## 9. 리뷰 관점 (reviewer 체크리스트)
- 옵션 분기(closed/open)가 **smoke를 깨지 않고** load arrival-rate를 올바로 구성하는가(top-level vus/duration과 scenarios 혼용 금지).
- buyer 시드가 `maxVUs`까지 확장돼 `(__VU-1)%buyers.length` 매핑이 카트 교차오염 없이 동작하는가.
- LOAD thresholds가 **실측 기반**(PLACEHOLDER 잔존 금지)이고 smoke와 분리됐는가. 근거 주석이 있는가.
- 달성 RPS·dropped_iterations로 **목표를 실제로 가했음**이 보고됐는가(트리비얼/붕괴 여부 §6.5 판정).
- 시나리오 본문·앱·빌드 무변경, baselines 산출.

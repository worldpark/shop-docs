# 001. shop-core k6 부하 테스트 1차 — k6 하니스 + 주문 생성(order-create) smoke 베이스라인

> 출처: 로드맵 `docs/tasks/performance/performance-shop-core-k6-load-test-roadmap.md` §12 "첫 구현 범위". 로드맵은 방향·결정을 정의하는 살아있는 문서이고, 본 Task는 거기서 분리된 **첫 단일 기능 구현**이다("한 Task = 한 기능"). 로드맵에서 이미 확정된 결정(도구·타겟 방식·게이트 정책·환경·출력)은 본 Task에서 재논의하지 않고 그대로 계승한다.

## 배경
- shop-core 동시성 정합(잃은 갱신 0, 음수 재고 0)은 이미 Testcontainers 통합 테스트(`OrderCancellationConcurrencyIntegrationTest`·`StockAdjustmentConcurrencyIntegrationTest`)가 검증한다. **미검증 영역은 "부하 하에서 비관적 락(DB 행 락)이 SLO를 지키며 무너지지 않는가"**이다(로드맵 §1).
- 주문 생성(cart→order)은 동일/소수 `VariantStock`에 `PESSIMISTIC_WRITE` 락이 가장 첨예하게 직렬화되는 지점이라 **부하 가치가 가장 크다**(로드맵 §6 1순위). 따라서 첫 시나리오로 둔다.

## 계승하는 로드맵 결정 (재논의 금지)
- **도구**: k6 (JS 시나리오 + 내장 `thresholds` pass/fail).
- **타겟 방식 A — 외부 앱 타겟**: `BASE_URL` 환경변수(기본 `http://localhost:8080`). E2E의 `SHOP_CORE_BASE_URL` 규약과 일치(로드맵 §5).
- **게이트 정책**: 머지 게이트 **제외**. 온디맨드 실행. `./gradlew test`와 무관하게 별도 실행하며 **빌드 의존성에 k6 엔진을 끌어들이지 않는다**(로드맵 §4).
- **환경**: docker-compose 실 스택(PG+Redis+Kafka+app). Kafka 필수(주문 확정·취소가 Outbox로 이벤트 외부화하므로 — 단, 본 Task의 가압 대상은 주문 *생성*이며 확정/취소는 2차 Task)(로드맵 §5).
- **출력**: k6 summary + JSON 아티팩트. Grafana/InfluxDB 파이프라인 보류(로드맵 §2·§13 Non-goals).

## Target
`shop-core/perf/k6/` (신규). **애플리케이션 코드·도메인 로직·빌드 설정(build.gradle)은 변경하지 않는다.** k6 스크립트는 떠 있는 앱을 외부에서 가압하는 블랙박스 자산이다.

## Goal
주문 생성 핫패스를 가압할 수 있는 **최소 k6 하니스**(공통 lib + 1순위 시나리오 + smoke 프로파일)를 구성하고, docker-compose perf 스택을 대상으로 **smoke 베이스라인**을 1회 측정해 `thresholds` 초기값을 형태로 확정한다. 목적은 절대 SLA 합의가 아니라 **추세 회귀 감시의 출발점**을 만드는 것이다(로드맵 §9).

## 범위 (Scope)
로드맵 §8 구조 중 **본 Task가 만드는 최소 셋**:

```
shop-core/perf/k6/
  lib/
    config.js        # BASE_URL·기본 옵션·공통 thresholds
    auth.js          # 로그인→JWT 토큰, 인증 헤더 헬퍼
    seed.js          # 상품/variant(충분한 재고)/구매자 계정 시드 (setup용)
  scenarios/
    order-create.js  # 1순위 — 주문 생성 부하 (cart→order)
  profiles/
    smoke.js         # 1~5 VU 짧게 (정상성·회귀 빠른 확인)
  README.md          # 실행 절차·환경 준비·k6 설치
```

- **인증**: k6 `setup()`에서 테스트 사용자 로그인 → JWT 확보 → VU가 Bearer 헤더 재사용. smoke는 짧은 런이라 1회 발급으로 충분(갱신 로직 불필요)(로드맵 §7).
- **시드**: 로드맵 §7의 두 방식 중 **(a) k6 `setup()`이 기존 관리자/판매자 API로 결정적 시드 생성**을 채택한다(가장 자기완결적, 추가 인프라 0, compose 변경 0). variant 재고는 smoke VU×반복을 넉넉히 흡수하도록 충분히 크게 심는다.
- **데이터 오염 방지**: 런별 **유니크 prefix(네임스페이스)** 로 시드 데이터 충돌 방지(E2E 6.1 규율 계승). 전용 perf DB 권장(로드맵 §7).
- **thresholds(형태, 초기값은 베이스라인 후 확정)**: `http_req_failed` rate < 1%, `http_req_duration` p95/p99 < (측정 후 기입), 커스텀 비즈니스 불변식 — 주문 생성 성공률·`order_conflict`(낙관/락 충돌) Counter·Check 표기. 음수 재고가 응답으로 드러나면 0 단언(로드맵 §9).
- **베이스라인 측정**: perf compose 기동 → `smoke.js`로 order-create 1회 실행 → summary/JSON 확인 → 관측된 p95/에러율로 thresholds 초기값을 `config.js`에 기입.

## Non-goals (이번 Task에서 하지 않음)
- `load.js`·`stress.js` 프로파일, `payment-confirm.js`·`coupon-apply.js` 시나리오 — **2차 이후 Task**(로드맵 §12·§15).
- nightly 파이프라인·JSON 추세 비교 자동화 — 보류(로드맵 §13·§15).
- 분산 부하(k6 Cloud), Grafana/InfluxDB 대시보드 — 보류(로드맵 §13).
- 서버측 성능 프로파일링·원인 규명("왜 느린가") — 관측성 도입 이후(로드맵 §2·§13).
- 머지 게이트 편입 — 하지 않음(로드맵 §4).
- 애플리케이션/빌드 코드 변경 — 없음. 시드는 기존 API만 사용한다.

## 예외/오류 처리 전략
- **시드 실패(setup)**: `setup()`에서 상품/variant/계정 생성 또는 로그인 실패 시 즉시 throw해 런을 중단한다(가압 전 환경 미비를 빠르게 드러냄 — "조용한 0 RPS" 방지).
- **토큰 만료**: smoke 런은 토큰 수명보다 짧으므로 1회 발급. (load/stress의 갱신은 후속 Task에서.)
- **앱 미기동/Kafka off**: README에 사전 점검 절차(헬스 체크 GET) 명시. 충실도 저하 조건(Kafka off)을 README에 경고로 남긴다.

## 검증 방법
- **smoke 실행 통과**: `BASE_URL=http://localhost:8080 k6 run -e PROFILE=smoke shop-core/perf/k6/scenarios/order-create.js`가 비정상 종료 없이 완료하고, 설정한 thresholds를 만족한다(위반 시 k6가 non-zero exit → 판정 게이트로 작동).
- **정합 흔적 0**: 가압 결과에 음수 재고·주문 생성 5xx가 SLO 밖으로 나타나지 않음(blackbox 한정 — 정밀 정합은 Testcontainers 책임이므로 본 Task는 응답 수준만 본다).
- **JSON 아티팩트 산출**: `--summary-export=build/k6/order-create-smoke.json`로 결과 보관(추세 비교 출발점).
- **재현 절차**: README만 보고 제3자가 perf 스택 기동 → 시드 → smoke 실행까지 재현 가능.
- 본 Task는 Java 빌드와 무관하므로 `./gradlew test` 게이트 대상이 아니다(로드맵 §4).

## 트레이드오프
- **시드 방식 (a) API setup vs (b) SQL 주입**: (a) 채택 — compose/인프라 변경 0, 엔드포인트 재사용으로 자기완결적. 단 시드도 HTTP라 setup 시간이 늘 수 있음(smoke 규모에선 무시 가능). 대량 시드가 필요한 load/stress 단계에서 (b) 재검토 여지는 후속 Task로 연다.
- **blackbox 한정**: 관측성 보류 상태라 "왜 느린가"는 규명하지 않는다. 본 Task는 "SLO를 지키나"의 pass/fail까지만(로드맵 §2 한계 선인지).
- **smoke만 우선**: load/stress를 미루는 대신 하니스(lib)·1순위 시나리오의 형태를 먼저 굳혀 후속 시나리오가 재사용하도록 한다(중복 제거 우선).

## 참고
- 로드맵: `docs/tasks/performance/performance-shop-core-k6-load-test-roadmap.md` (§5 환경, §6 핫패스, §7 인증/시드, §8 구조, §9 thresholds, §12 첫 범위)
- E2E 전략(같은 "외부 앱 타겟 A" 원칙): `docs/plans/performance/001-e2e-playwright-java-test-strategy.md`
- compose 인프라 자산: `docs/tasks/infra/003-infra-local-docker-compose.md`
- 동시성 정합 선례(정확성은 이 층이 책임): `OrderCancellationConcurrencyIntegrationTest`, `StockAdjustmentConcurrencyIntegrationTest`
- 가압 대상 핫패스 코드: 주문 생성(cart→order, `VariantStock` 차감 `PESSIMISTIC_WRITE`)

## 후속 Task (열려 있음, 본 Task 범위 밖)
- 2차: `profiles/load.js` + 베이스라인 기반 thresholds 절대값 확정.
- 3차: `scenarios/payment-confirm.js`(주문 행 락 + Outbox), `scenarios/coupon-apply.js`(쿠폰 사용 동시성).
- nightly 파이프라인 + JSON 추세 비교, 시드/정리 자동화(런별 네임스페이스 self-clean).

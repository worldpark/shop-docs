# 성능/부하 테스트 로드맵 (Roadmap): k6 (외부 앱 타겟 / A 방식)

- 작성일: 2026-06-15
- 상태: **로드맵(살아있는 문서)** — 방향·결정·우선순위만 정의한다. 실제 구현은 **단일 기능 task로 분리**한다(`task-rule`: 한 Task = 한 기능). 번호 없는 상위 맥락 문서.
- 범위: shop-core HTTP API 부하/성능 테스트의 방향·우선순위·트레이드오프(개별 구현 아님)
- 관련: E2E 전략 `docs/plans/performance/001-e2e-playwright-java-test-strategy.md`(같은 "외부 앱 타겟 A" 원칙 계승), 동시성 선례 `OrderCancellationConcurrencyIntegrationTest`·`StockAdjustmentConcurrencyIntegrationTest`

---

## 1. 배경

shop-core는 동시성 정합을 **비관적 락(DB 행 락, `SELECT ... FOR UPDATE`)**으로 공들여 설계했다(재고 차감·주문 확정·취소·쿠폰). 단위/Testcontainers 통합 테스트는 **정합(정확성)**은 검증하지만 — 잃어버린 갱신 0, 음수 재고 0 — **부하 하의 처리량·지연·락 경합 붕괴 여부**는 측정하지 않는다. 즉 "락이 옳게 직렬화되는가"는 검증됐고, "락이 부하에서 **무너지지 않고 SLO를 지키는가**"는 미검증이다.

k6는 이 공백을 메우는 **블랙박스 부하 도구**다. Go 엔진 + JS 스크립트로 떠 있는 앱을 외부에서 가압한다. JUnit/Testcontainers 스택과 결이 달라 `./gradlew test` 안에 넣지 않는다.

> **한계 선인지(중요)**: 관측성(메트릭/트레이싱/구조화 로그)은 로드맵상 보류 상태다(리포트 002 item 2). 따라서 k6는 당분간 **"p95/에러율이 SLO를 지키나"라는 블랙박스 판정**까지만 한다. **"왜 느린가"(락 대기 vs Kafka vs GC)**의 원인 규명은 관측성 도입 이후로 미룬다. 이 전제를 흐리지 않는다.

---

## 2. 결정 요약

| 항목 | 결정 | 근거(요약) |
|---|---|---|
| 도구 | **k6** | 사용자 확정. 코드형(JS) 시나리오·내장 `thresholds` 기반 pass/fail·낮은 자원으로 높은 VU. CI 친화적 |
| 타겟 방식 | **A — 외부 앱 타겟**(`SHOP_CORE_BASE_URL`, 기본 `http://localhost:8080`) | E2E(Playwright)와 동일 원칙. 완전 배선된 실제 기동 아티팩트가 최고 충실도. 부하는 임베디드/in-process로 재현 의미 적음 |
| 게이트 정책 | **머지 게이트 제외 — 온디맨드 + (선택)nightly** | E2E를 게이트에서 뺀 결정과 동일 논리(반복 비용·flaky). 부하는 느리고 환경 의존적이라 per-commit 부적합 |
| 환경 | **docker-compose 실 스택**(PG+Redis+Kafka+app) | Testcontainers는 부하용 아님. 실제 인프라 위에서만 의미 있는 수치 |
| 출력 | **k6 summary + JSON 아티팩트**(Grafana/InfluxDB 파이프라인 보류) | YAGNI. 관측성 보류와 정합. 추세 비교는 JSON 보관으로 충분 |

> **핵심 원칙**: k6의 목적은 "비관적 락 설계가 부하에서 SLO를 지키는지"의 **블랙박스 증명**이다. 트리비얼한 GET이 아니라 **동시성 핫패스**를 가압한다.

---

## 3. 도구 선택 — 왜 k6

- **코드형·버전관리 친화**: 시나리오가 JS 파일이라 레포에 커밋·리뷰 가능(JMeter XML 대비 우월).
- **pass/fail 내장**: `thresholds`로 "p95<X, 에러율<Y, 커스텀 metric==0"을 위반하면 비정상 종료 → 부하 테스트가 "그래프 구경"이 아니라 **판정 게이트**가 된다.
- **경량 고VU**: 단일 머신으로 수천 VU. 별도 분산 부하 인프라 없이 시작 가능.
- 대안(Gatling/JMeter) 대비 진입장벽·자원이 낮고, 이 프로젝트의 "가벼운 가드" 기조와 맞는다.

---

## 4. 위치 / 게이트 정책

- **머지 게이트에 넣지 않는다.** E2E를 게이트에서 뺀 결정과 같은 논리(반복 비용·flaky·환경 의존). 부하 테스트는 추가로 느리고 무겁다.
- **온디맨드**(개발자가 의도적으로 실행) + **(선택) nightly**(추세 감시·회귀 조기 발견, 머지 비차단).
- k6는 Java가 아니므로 `./gradlew test`와 무관하게 **별도 실행**한다. (선택적으로 `k6 run`을 감싸는 얇은 Gradle/스크립트 래퍼만 둘 수 있다 — 빌드 의존성에 k6 엔진을 끌어들이지 않는다.)

---

## 5. 환경 / 충실도

- 대상은 **docker-compose로 띄운 실제 스택**: PostgreSQL + Redis + Kafka + shop-core app. 기존 인프라 자산(`docs/tasks/infra/003-...local-docker-compose`) 재사용.
- 스크립트는 **`BASE_URL` 환경변수**로 타겟 파라미터화(로컬·staging·전용 perf 환경 전환). E2E의 `SHOP_CORE_BASE_URL` 규약과 일치.
- **Kafka 필수**: 주문 확정·취소는 Modulith Outbox로 이벤트를 외부화하므로, 부하 시 Outbox 적재·발행 경로까지 가압해야 충실하다(Kafka off면 충실도 저하).

---

## 6. 대상 핫패스 (우선순위)

락 설계를 증명하는 동시성 경로를 1순위로. 트리비얼 조회는 후순위.

| 순위 | 시나리오 | 가압 의도 |
|---|---|---|
| 1 | **주문 생성**(cart→order, `VariantStock` 차감 PESSIMISTIC_WRITE) | 동일/소수 variant에 동시 주문 집중 시 처리량·p95·에러율 + **재고 음수·lost-update 0** 확인 |
| 2 | **결제 확정**(주문 행 락 + Outbox 발행) | 락 직렬화 + 이벤트 외부화 경로의 지연·throughput |
| 3 | **쿠폰 적용/주문 할인**(쿠폰 사용 동시성) | 중복 사용 방지 경로의 경합 |
| (참고) | 공개 상품 목록/상세 GET | 읽기 캐시·기본 latency 베이스라인(가벼운 스모크) |

> 1순위(주문 생성)는 이 시스템에서 **락이 가장 첨예하게 직렬화되는 지점**이라 부하 가치가 가장 크다. 여기부터 시작한다.

---

## 7. 인증 / 시드 전략

- **JWT 인증**: API는 Bearer 토큰이 필요. k6 `setup()`에서 테스트 사용자로 로그인→토큰 확보→VU가 헤더 재사용. 토큰 만료보다 짧은 런이면 1회 발급으로 충분, 길면 갱신 로직.
- **결정적 시드**: 부하 전 **상품·variant(충분한 재고)·구매자 계정**을 결정적으로 심는다. 두 방식 중 택1(구현 task에서 확정):
  - (a) k6 `setup()`이 관리자/판매자 API로 시드 생성(엔드포인트 재사용, 가장 자기완결적),
  - (b) 별도 시드 SQL/스크립트를 compose 기동 시 주입.
- **공유 환경 오염 주의**(E2E 6.1과 동일 규율): 런별 **유니크 prefix(네임스페이스)**로 데이터 충돌 방지, 누적 데이터 **주기적 리셋/self-clean**. 부하 런은 데이터를 많이 만들므로 전용 perf DB 권장.

---

## 8. 스크립트 구조 (제안)

```
shop-core/perf/k6/
  lib/
    config.js        # BASE_URL·기본 옵션·thresholds 공통
    auth.js          # 로그인→토큰, 인증 헤더 헬퍼
    seed.js          # 상품/variant/계정 시드(setup용)
  scenarios/
    order-create.js  # 1순위 — 주문 생성 부하
    payment-confirm.js
    coupon-apply.js
  profiles/
    smoke.js         # 1~5 VU 짧게(연기 테스트, 회귀 빠른 확인)
    load.js          # 목표 RPS/VU 정상 부하
    stress.js        # 한계 탐색(점증)
  README.md          # 실행 절차·환경 준비
```

- **profiles 분리**: smoke(빠른 정상성) / load(목표 부하 SLO 판정) / stress(붕괴점 탐색). 같은 시나리오를 옵션만 바꿔 재사용.
- 시나리오는 `lib`의 auth·config·seed를 공유해 중복 제거.

---

## 9. SLO / thresholds (pass/fail)

k6 `thresholds`로 자동 판정(위반 시 비정상 종료 → 게이트화). 초기 목표값은 베이스라인 측정 후 확정하되, 형태는:

- `http_req_failed`: rate < 1%
- `http_req_duration`: p95 < (목표 ms), p99 < (목표 ms)
- **커스텀 비즈니스 불변식**: `stock_negative_total == 0`, `order_conflict_429`는 허용 범위 내(낙관적 충돌은 정상, 락 붕괴는 비정상) — k6 Counter/Check로 표기.

> 임계값은 "추세 회귀 감시"가 1차 목적이다. 절대 수치 SLA 합의는 운영 단계에서.

---

## 10. 테스트 레이어 분담 (중복 방지)

| 레이어 | 도구 | 책임 |
|---|---|---|
| 단위 | JUnit5 + Mockito | 도메인/서비스 로직 |
| 슬라이스·통합 | `@DataJpaTest` + Testcontainers | DB 동작·SQL 회귀·**정합(잃은 갱신 0)** |
| 종단(E2E) | Playwright for Java(A) | 브라우저 핵심 여정 스모크 |
| **부하/성능** | **k6(A)** | **부하 하의 처리량·지연·락 경합 붕괴 여부(블랙박스 SLO)** |

> 정합(정확성)은 이미 Testcontainers 동시성 테스트가 책임진다. k6는 그 층을 떠안지 않고 **"부하에서의 성능·안정성"**만 본다.

---

## 11. 트레이드오프

| 결정 | 채택 | 버린 안 | 이유 |
|---|---|---|---|
| 타겟 방식 | A(외부 앱) | in-process/임베디드 가압 | 부하는 실제 기동 아티팩트 위에서만 의미. E2E와 일관 |
| 게이트 | 머지 제외(온디맨드+nightly) | per-commit 게이트 | 느림·flaky·환경 의존. E2E 결정과 동일 논리 |
| 출력 | summary+JSON | Grafana/InfluxDB 파이프라인 | 관측성 보류(item 2)와 정합, YAGNI |
| 진단 깊이 | 블랙박스 SLO만 | 서버측 원인 규명 | 메트릭/트레이싱 부재 — "왜 느린가"는 관측성 도입 후 |
| 환경 | 전용 perf compose | 공유 테스트 서버 | 부하 데이터 누적·오염이 커 격리 필요 |

---

## 12. 첫 구현 범위 (후속 task에서)

- `perf/k6/lib`(config·auth·seed) + **`scenarios/order-create.js`(1순위) + `profiles/smoke.js`** 최소 셋.
- docker-compose perf 환경 대상으로 smoke→load 순서로 베이스라인 측정, thresholds 초기값 확정.
- README에 실행 절차.

## 13. Non-goals

- 분산 부하 발생(k6 Cloud/오퍼레이터), Grafana 대시보드/시계열 DB 파이프라인 — 보류(YAGNI, 관측성 단계).
- 서버측 성능 프로파일링·튜닝(원인 규명) — 관측성(item 2) 이후.
- 머지 게이트 편입 — 하지 않음.
- notification 직접 가압 — notification은 Kafka 컨슈머(HTTP 아님). 부하는 shop-core가 발행하는 이벤트로 **간접** 유발.

## 14. 실행 방법 (예시)

```bash
# 1) k6 설치 (로컬 1회) — choco/brew/도커 이미지 중 택1
#    예) docker run --rm -i grafana/k6 run - < scenario.js

# 2) perf 스택 기동
docker compose -f docker/shop/docker-compose.yml up -d   # PG+Redis+Kafka+app

# 3) 부하 실행 (대상은 BASE_URL)
BASE_URL=http://localhost:8080 k6 run shop-core/perf/k6/scenarios/order-create.js
#  프로파일 전환: k6 run -e PROFILE=load ... / summary export: --summary-export=build/k6/order-create.json
```

## 15. 후속 과제 (열려 있음)

- **베이스라인 측정 → thresholds 절대값 확정**(현재는 형태만 정의).
- **nightly 파이프라인**: 전용 perf 환경에 compose 기동 → k6 run → JSON 아티팩트 보관·추세 비교. 머지 비차단.
- **시드/정리 자동화**: 런별 네임스페이스 + 누적 데이터 self-clean.
- **시나리오 확장**: 결제 확정·쿠폰 적용 → 점진 추가(핫패스 위주, 얇게 유지).
- **(관측성 도입 후) 원인 규명 연계**: 서버측 메트릭/트레이싱과 k6 부하 구간을 상관 분석.

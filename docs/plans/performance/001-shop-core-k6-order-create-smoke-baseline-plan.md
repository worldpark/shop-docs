# Plan 001. shop-core k6 부하 테스트 1차 — 하니스 + order-create smoke 베이스라인

> 대상 Task: `docs/tasks/performance/001-performance-shop-core-k6-order-create-smoke-baseline.md`
> 로드맵: `docs/tasks/performance/performance-shop-core-k6-load-test-roadmap.md`
> 구현 담당: `k6-implementor` (메인 오케스트레이션은 메인 에이전트)

## 0. 이번 실행 범위 결정 (사용자 확정)
- **1차(구현)**: 스크립트(lib/scenarios/profiles) + README 구현. 검증은 `k6 archive` 정적 검증(서버 불필요). thresholds는 PLACEHOLDER + 측정 후 채우는 절차로 남김.
- **2차(실측)** — ✅ **완료(2026-06-16)**: 사용자 요청으로 라이브 smoke 실측 수행.
  - 환경: docker-compose 인프라(PG+Redis+Kafka, 기동 중) + 앱 localhost:8080(기동 중) + admin 계정 기존재(부트스트랩 생략).
  - 실행: `k6 run -e PROFILE=smoke order-create.js` 2회. 결과 모두 PASS.
    - 관측: `http_req_duration` p95≈40ms / p99≈53ms, `http_req_failed`=0.00%, `order_5xx`=0, `order_created`=3,435/run(~110 orders/s).
  - **thresholds 확정**: PLACEHOLDER → 실측 기반으로 교체(`p(95)<100`, `p(99)<200` — 관측치 ×2~3 여유). `lib/config.js` 주석에 베이스라인·근거 기록.
  - 산출물: `build/k6/order-create-smoke.json`. ⚠️ `build/`는 gitignore 대상 → 추세 비교용 커밋이 필요하면 비-build 경로(예: `shop-core/perf/k6/baselines/`)로 이동은 후속 정리.

## 1. 목표
주문 생성(cart→order) 핫패스를 외부에서 가압하는 **최소 k6 하니스**를 `shop-core/perf/k6/`에 구성한다. 공통 lib(config·auth·seed) + 1순위 시나리오(order-create) + smoke 프로파일 + README. 애플리케이션 Java 코드·`build.gradle`·Thymeleaf·compose는 **변경하지 않는다**.

## 2. 산출물 (파일 트리)
```
shop-core/perf/k6/
  lib/
    config.js        # BASE_URL·PROFILE 분기·공통 thresholds(형태)·시드 상수
    auth.js          # 로그인→JWT, Bearer 헤더 헬퍼, signup 헬퍼
    seed.js          # admin 로그인→seller 승격→상품 게시→variant(대량 재고)→buyer 계정 (setup용)
  scenarios/
    order-create.js  # 1순위 — setup()=시드, default()=cart add→order create + 커스텀 메트릭
  profiles/
    smoke.js         # 1~5 VU 짧게 — options export(시나리오가 import)
  README.md          # 스택 기동·admin 부트스트랩·smoke 실행·thresholds 확정 절차
```
- 산출 JSON: `build/k6/order-create-smoke.json`(smoke 실행 시 `--summary-export`로 생성 — 이번엔 보류, README에 커맨드만).

## 3. 가압 대상 REST 계약 (코드 실사 확정 — 추측 아님)
모든 인증 API는 `Authorization: Bearer {accessToken}`.

| 단계 | 메서드·경로 | 요청 바디 | 응답에서 추출 | 권한 |
|---|---|---|---|---|
| 로그인 | `POST /api/v1/auth/login` | `{email, password}` | `accessToken` (JSON) | 공개 |
| 회원가입 | `POST /api/v1/members/signup` | `{email, password, passwordConfirm, name, phone?}` | `memberId` (201) | 공개 |
| 역할변경(승격) | `PATCH /api/v1/admin/members/{memberId}/role` | `{role:"SELLER"}` | — (200) | ADMIN |
| 상품 등록 | `POST /api/v1/seller/products` | `{categoryId:null, name, description?, basePrice}` | `productId` (status=DRAFT) | SELLER |
| 상품 게시 | `PATCH /api/v1/seller/products/{productId}` | `{categoryId:null, name, basePrice, status:"ON_SALE"}` | — | SELLER(소유) |
| variant 생성 | `POST /api/v1/seller/products/{productId}/variants` | `{sku, price, stock, active:true, optionValueIds:[]}` | `variantId` | SELLER(소유) |
| 장바구니 담기 | `POST /api/v1/cart/items` | `{variantId, quantity}` | — (CartResponse) | CONSUMER |
| 주문 생성 | `POST /api/v1/orders` | `{recipient, phone, postcode, address1, address2?, userCouponId:null}` | `orderId` (201) | CONSUMER |

- **구매 가능 불변식**: 주문은 `product.status==ON_SALE && variant.active`인 항목만 받는다(`ProductOrderCatalogImpl`). 따라서 시드는 **반드시 게시(ON_SALE) + variant active=true**.
- `password` 최소 8자(`@Size(min=8)`), `passwordConfirm` 일치 필수(`@PasswordMatches`). `businessRegistrationNumber` 등 seller-application 경로는 **사용 안 함**(역할변경이 더 단순).
- 카테고리는 `categoryId:null` 허용 → admin 카테고리 생성 단계 **불필요**.

## 4. 인증 / 시드 설계 (방식 a: API 자기완결 + admin 부트스트랩)
### 4.1 admin 부트스트랩 (README 1회 절차, k6 밖)
- 자동 시드 admin이 없으므로 **프로젝트 기존 관례** `AdminAccountSeedTest`를 사용:
  `./gradlew test --tests "*AdminAccountSeedTest*" -Dseed.admin.enabled=true` → `admin@example.com` / `Admin1234!` (role=ADMIN) upsert.
- README에 "fresh perf DB면 1회 실행" 명시. k6는 이 admin 자격으로 로그인만 한다(자격증명은 `__ENV.ADMIN_EMAIL`/`__ENV.ADMIN_PASSWORD`로 오버라이드 가능, 기본값=위).

### 4.2 k6 `setup()` 시드 (런 1회)
런별 유니크 prefix(네임스페이스)로 데이터 충돌 방지. prefix는 `__ENV.RUN_TAG` 우선, 없으면 `setup` 내 `Date.now()`-금지 대안으로 **k6 `uuidv4()` 또는 `__ENV`+VU 비의존 카운터**를 사용(하드코딩 금지).
1. admin 로그인 → `adminToken`.
2. seller가 될 계정 signup(`seller+{prefix}@perf.local`) → `sellerMemberId`.
3. admin이 `PATCH /admin/members/{sellerMemberId}/role {role:SELLER}` → 승격.
4. seller 로그인(승격 후 재로그인으로 SELLER 토큰 확보) → `sellerToken`.
5. `POST /seller/products` → `productId` → `PATCH .../{productId}` status=ON_SALE 게시.
6. `POST /seller/products/{productId}/variants` — `sku=PERF-{prefix}`, `stock` 대량(예 1,000,000: VU×반복 흡수, 재고 고갈로 인한 409를 베이스라인에서 배제), `active:true` → `variantId`.
7. buyer 계정 N개 signup+login(N=프로파일 최대 VU). **VU당 전용 buyer** — 장바구니가 사용자 단위라 주문 생성이 카트를 비우므로, 동일 buyer 공유 시 카트 교차오염 발생. `__VU`로 buyer를 매핑.
8. return `{variantId, buyers:[{token}...]}`.
- **실패 시 즉시 throw**: 어떤 단계든 기대 status code가 아니면 `setup`에서 throw해 런 중단("조용한 0 RPS" 방지). check 실패만으로 끝내지 말고 throw.

### 4.3 VU 본문 `default(data)`
- buyer = `data.buyers[(__VU-1) % data.buyers.length]`.
- `POST /cart/items {variantId, quantity:1}` → `check(status===200)`.
- `POST /orders {recipient, phone, postcode, address1, userCouponId:null}` → `check(status===201)`.
- 커스텀 메트릭:
  - `Counter order_created` (201 카운트),
  - `Counter order_conflict` (409 — 낙관/락 충돌·재고부족; 베이스라인에서 0에 가까워야 함, 비정상 폭증 감시),
  - `Counter order_5xx` (≥500 — 락 붕괴 징후),
  - (선택) `Trend order_create_duration` — order POST 자체 지연.

## 5. thresholds (형태 + 플레이스홀더) — `lib/config.js`
실측 보류이므로 **형태와 보수적 플레이스홀더**만 둔다. README에 "smoke 1회 후 관측 p95/에러율로 교체" 명시.
```js
thresholds: {
  http_req_failed:   ['rate<0.01'],                 // 1% 미만
  http_req_duration: ['p(95)<800', 'p(99)<1500'],   // PLACEHOLDER — smoke 후 교체
  order_5xx:         ['count==0'],                   // 락 붕괴=비정상
  // order_conflict 는 임계로 죽이지 않음(낙관 충돌은 정상). Counter로 가시화만.
}
```
- 값에 `// PLACEHOLDER: 베이스라인 측정 후 확정` 주석을 단다(verification-gate가 "측정값"으로 오인하지 않게).

## 6. 프로파일 / 환경변수
- `profiles/smoke.js`: `export const options = { vus: 5, duration: '30s', thresholds: {...config} }` 또는 `-e PROFILE=smoke` 분기. lib/config가 PROFILE을 읽어 stages/vus 결정. smoke=1~5 VU 짧게.
- 환경변수: `__ENV.BASE_URL`(기본 `http://localhost:8080`), `__ENV.PROFILE`(기본 smoke), `__ENV.ADMIN_EMAIL`/`ADMIN_PASSWORD`, `__ENV.RUN_TAG`. 하드코딩 호스트/시크릿 금지.

## 7. README 필수 내용
1. 사전 점검: `GET /actuator/health`(없으면 `POST /api/v1/auth/login` 도달성)로 앱 기동 확인. Kafka off 시 충실도 저하 경고.
2. 스택 기동: `docker compose -f docker/shop/docker-compose.yml up -d`(인프라 only) → **앱은 별도로 `./gradlew bootRun`(또는 IDE)로 localhost:8080 기동**(compose는 앱을 띄우지 않음 — 인프라 전용임을 명시).
3. admin 부트스트랩 1회: `AdminAccountSeedTest` 커맨드(§4.1).
4. smoke 실행:
   `BASE_URL=http://localhost:8080 "C:\Program Files\k6\k6.exe" run -e PROFILE=smoke shop-core/perf/k6/scenarios/order-create.js --summary-export=build/k6/order-create-smoke.json`
   (k6 PATH 미등록 → 전체 경로. Docker 대안: `docker run --rm -i grafana/k6 run -`, 컨테이너→호스트는 `host.docker.internal`).
5. thresholds 확정: 관측 p95/p99/에러율로 `lib/config.js`의 PLACEHOLDER 교체 절차.

## 8. 검증 (이번 Task)
- **정적 검증(라이브 smoke 대체)**: `"C:\Program Files\k6\k6.exe" archive shop-core/perf/k6/scenarios/order-create.js -O <임시>` 가 에러 없이 통과(JS 파싱·import 해석·options 유효성 확인, 서버 불필요). 산출 임시 아카이브는 정리.
- import 경로(ES module) 정합, `__ENV` 기본값 fallback 존재, 하드코딩 호스트/시크릿 부재.
- 라이브 smoke·JSON 아티팩트 산출은 **보류**(README 절차로 재현 가능하게 남김).

## 9. 명시적 비범위
- `load.js`/`stress.js`, `payment-confirm.js`/`coupon-apply.js` — 후속 Task.
- nightly·JSON 추세 자동화, Grafana/InfluxDB, 분산 부하 — 보류.
- 앱/빌드/compose 변경 — 없음. 시드는 기존 API + 기존 AdminAccountSeedTest만 사용.
- 라이브 smoke 실측 및 thresholds 절대값 확정 — 사용자 스택 기동 후 후속.

## 10. 리뷰 관점 (reviewer 체크리스트)
- 시드 단계 실패가 throw로 런을 중단하는가(조용한 0 RPS 방지).
- order-create가 §3 계약과 정확히 일치하는가(경로·바디 필드·추출 키·status code).
- buyer가 VU별로 분리되어 카트 교차오염이 없는가.
- thresholds가 PLACEHOLDER로 표기되고 실측 사칭이 없는가.
- 하드코딩 호스트/시크릿 부재, ES module 공통화로 중복 제거, plan 밖 시나리오/프로파일 미추가.

# Plan 006. shop-core 가상스레드 A/B 평가 (빈 기반)

> 대상 Task: `docs/tasks/performance/006-performance-shop-core-virtual-thread-ab-evaluation.md`
> 구현: VT 빈·설정=backend-implementor / 다중 variant·고동시성·읽기 워크로드=k6-implementor / A/B 측정=메인
> 선행 점검(완료): 핫패스 `synchronized`·`ThreadLocal` 0건 → pinning 위험 없음, 코드베이스 VT-ready.

## 0. 정직한 측정 전제 (결과 해석의 틀)
- VT는 **풀 밖에서 블로킹하는 다수 동시요청**이 플랫폼 스레드(200)를 고갈시킬 때 이득. 단일 요청은 안 빨라짐.
- shop-core 주문 = **DB 쓰기 → HikariCP 풀 바운드**. PG `max_connections` 기본 ~100이라 풀을 ~90 이상 못 올림 → **다중 variant로 락을 풀어도 throughput은 풀(~90)에서 캡**. 이 경로에서 VT 이득은 **작을 수 있다**(풀이 스레드보다 먼저 캡).
- 따라서 **두 워크로드를 잰다**: (a) 주문 쓰기(풀 바운드 — 현실 핫패스), (b) **공개 상품 읽기 GET**(락 없음, 더 높은 동시성 가능 — VT에 더 공정한 기회). 둘 다 A/B.
- **결론은 측정이 말한다.** "무차이/소폭"이면 "이 워크로드엔 VT가 throughput 지렛대가 아님"이라는 **유효한 근거**(채택하더라도 성능이 아니라 코드 단순화·미래대비 목적). 정직히 기록.

## 1. 백엔드 — VT 빈 + 측정 설정 (backend-implementor)
### 1.1 VT 요청 실행기 빈 (조건부, 기본 off)
신규 `shop-core/src/main/java/.../config/VirtualThreadConfig.java`(또는 web 패키지):
```java
@Configuration
@ConditionalOnProperty(name = "shop.threads.virtual.enabled", havingValue = "true")
public class VirtualThreadConfig {
    @Bean
    public TomcatProtocolHandlerCustomizer<?> virtualThreadProtocolHandlerCustomizer() {
        return handler -> handler.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
    }
}
```
- **전역 `spring.threads.virtual.enabled` 미사용**(요청 처리만 VT, @Async/스케줄러 무영향).
- 기본 off → 프로덕션 동작 무변경. A/B의 도입 런만 `-Dshop.threads.virtual.enabled=true`.
- import: `org.springframework.boot.web.embedded.tomcat.TomcatProtocolHandlerCustomizer`, `java.util.concurrent.Executors`.

### 1.2 측정용 HikariCP 풀 (환경변수 가드, 기본 현행)
`application.yml`에 `spring.datasource.hikari.maximum-pool-size: ${SHOP_CORE_HIKARI_MAX_POOL:10}`(기본 10=현행). 측정 시 `SHOP_CORE_HIKARI_MAX_POOL=80` 등으로 상향(PG 기본 max_connections 100 미만 안전선). 프로덕션 기본 무변경.
- (선택) PG max_connections를 docker-compose에서 올리는 건 본 Task 비범위(기본 100 내에서 측정).

### 1.3 pinning/ThreadLocal — 점검 완료
핫패스 `synchronized`·`ThreadLocal` 0건(메인 grep). 추가 코드 변경 불필요. (JDBC 드라이버 레벨 pinning은 측정에서 서버측 지표로 관찰.)

## 2. k6 — 스레드 바운드 워크로드 (k6-implementor)
### 2.1 다중 variant 시드
`seed.js`에 `setupMultiVariant(buyerCount, variantCount)` 또는 옵션: 상품 1개에 variant N개(예 `__ENV.VARIANT_COUNT` 기본 100, 재고 대량) 생성. **기존 setupSeed 무영향**(전용 함수/옵션, order-create/payment/coupon 시드 불변).
### 2.2 쓰기 시나리오 (주문, variant 분산)
신규 `scenarios/vthread-order.js`(또는 order-create에 variant 분산 옵션): VU가 `data.variants[(__VU + __ITER) % N]`로 **서로 다른 variant** 주문 → 단일 행 락 제거. 고동시성 프로파일로 구동.
### 2.3 읽기 시나리오 (VT에 공정한 기회)
신규 `scenarios/catalog-read.js`: `GET /api/v1/products`(+ `/products/{id}`) 고동시성 가압(락 없음, DB 읽기 블로킹). 공개 엔드포인트라 인증 불필요(시드 최소).
### 2.4 고동시성 프로파일
플랫폼 스레드 200을 넘겨 큐잉시키는 동시성. 전용 `vthread` 프로파일(constant-arrival-rate 고 rate + maxVUs 수백) 또는 stress 재사용. plan 측정 단계에서 동시성 스윕(예 100→300→500 동시).

## 3. A/B 측정 — 3단 풀 × (플랫폼/VT) 매트릭스 (메인 + 사용자 협조)
"풀을 늘리면 VT가 이기나?"를 직접 반증/확증한다. **읽기 경로(catalog-read)가 풀을 가장 깨끗이 가압**(락 없음, 동시 DB 읽기 = 풀 점유)하므로 주 측정은 읽기로, 쓰기(다중 variant)는 보조.

**매트릭스** (각 셀 = 같은 고동시성 워크로드, 깨끗한 DB, 다회):

| 풀 크기 | 플랫폼 스레드 | VT (`-Dshop.threads.virtual.enabled=true`) | 가설 |
|---|---|---|---|
| **10**(현행) | 측정 | 측정 | 풀이 캡 → **VT≈플랫폼**, 스레드 수 200 근처도 안 감 |
| **50**(건강 범위) | 측정 | 측정 | throughput **↑ (둘 다 동등)** — 풀 튜닝 이득은 공유, VT 우위 없음 |
| **250**(+PG max_connections 상향) | 측정 | 측정 | DB 과부하로 **저하** — 과한 풀의 역효과 |

- 풀은 `SHOP_CORE_HIKARI_MAX_POOL`로, 250 셀은 docker-compose PG `-c max_connections=300`(측정용, 본 Task 비범위지만 이 셀만 임시) 필요.
- **앱 토글 기동은 사용자(IDE 호스트 프로세스)**: 풀 환경변수 + VT 플래그 조합으로 각 셀마다 재기동 → 메인이 그 사이 k6 실행. notification은 측정 내내 **정지/log**.
- **비교/규명 지표**: throughput(달성 req/s)·p95/p99·dropped·에러율 + **서버측(Grafana/Prometheus 배선됨)**: 활성 스레드 수(플랫폼 200 캡 도달 여부 vs VT), `hikaricp_connections_active/pending`(풀이 캡인지), `http_server_requests` p95, JVM/GC.
- **결론 도출**: 위 매트릭스로 "**풀이 throughput 지렛대, VT는 DB 바운드에선 무관**"을 데이터로 확정. 어느 셀에서도 스레드가 200 캡에 안 닿고 pending이 풀에서 쌓이면 → "스레드 모델 무관, 풀/DB가 천장" 입증.

## 4. 검증
- VT 빈 조건부(미설정 시 미생성) — 풀 스위트 그린(설정 추가 무해), `-Dshop.threads.virtual.enabled=true` 기동 시 요청 스레드명이 `VirtualThread...`(로그/액추에이터 thread dump)로 확인.
- A/B 산출: 도입/미도입 × (쓰기·읽기) baseline JSON + 비교표 + **결론(개선폭 또는 무차이 + 원인: 스레드 vs 풀 vs 락)**.
- 프로덕션 기본 동작 무변경(VT off, 풀 10) 확인.

## 5. 리뷰 관점
- VT 빈이 전역 프로퍼티 미사용·`@ConditionalOnProperty` 기본 off·요청 실행기만 교체인가. 프로덕션 무영향인가.
- HikariCP 풀이 환경변수 가드(기본 현행)인가.
- k6 다중 variant·읽기 시나리오가 기존 시나리오/시드 무영향인가. 고동시성이 실제로 플랫폼 스레드(200)를 넘기는가.
- 측정이 **스레드/풀/락 병목을 서버측 지표로 구분**하고 결론이 정직한가(무차이도 유효 근거로 기록).

## 6. Non-goals
- VT 실제 채택(기본 on)·프로덕션 풀 튜닝 확정 — 측정 후 별도 결정/ADR. PG max_connections 상향. 분산 부하.

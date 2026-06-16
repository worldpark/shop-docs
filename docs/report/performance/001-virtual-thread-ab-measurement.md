# 가상스레드(Virtual Threads) 도입 A/B 측정 리포트

> 작성일: 2026-06-16 · 대상: shop-core (HTTP 요청 처리 경로)
> 목적: 가상스레드 도입/미도입의 성능 차이를 **동일 워크로드에서 A/B 실측**해 채택 근거를 데이터로 확보.
> 전제: CLAUDE.md "향후 가상스레드 도입 대비"(현재는 즉시 활성화 안 함)에 대한 **평가**이지 채택이 아니다. 관련 Task `docs/tasks/performance/006-...-virtual-thread-ab-evaluation.md`, 결과 revision `docs/plans/revisions/performance/006-...-result-revision-1.md`.

---

## 1. 요약 (Executive Summary)

| 관점 | 결과 | 신뢰도 |
|---|---|---|
| **throughput** | VT 이득 **없음** (~920 req/s, 풀·스레드모델 무관 평탄) | 높음 |
| **꼬리지연 p95/p99** | **VT가 p95 −26%, p99 −28%** (풀50·300동시) | 높음 (각 3런·분포 비중첩) |
| **플랫폼 스레드 수** | VT **~98 vs 플랫폼 ~281** (≈1/3) | 높음 |

**결론**: shop-core HTTP 경로에서 VT는 **"throughput 도구"가 아니라 "고동시성 자원효율 + 꼬리지연 안정화 도구"**다.
**권장**: 현 단계는 throughput이 우선이고 거기엔 이득이 없으므로 **미도입 유지가 합리적**(CLAUDE.md 정합). 단 "VT 무용"이 아니라 **"현 시점 우선순위 아님"** 이 정확. 동시성이 높아 플랫폼 스레드가 수백 개로 포화돼 꼬리지연·메모리가 운영 이슈가 되면 재평가(VT 빈은 기본 off로 보존돼 토글만 하면 됨).

---

## 2. 측정 환경 / 방법

- **대상 워크로드**: `catalog-read.js` — 공개 읽기 `GET /api/v1/products`(목록) + `/products/{id}`(상세). 락 없음·DB 읽기 → 커넥션풀·CPU 가압. 주문/이벤트 미생성이라 notification 무관(측정 안전).
- **부하**: k6 `conc` 프로파일(closed) **CONC_VUS=300 × 40s**, 깨끗한 카탈로그 시드.
- **VT 토글(빈 방식)**: 전역 `spring.threads.virtual.enabled` **미사용**. `VirtualThreadConfig`(`@ConditionalOnProperty(shop.threads.virtual.enabled=true)`, 기본 off)가 `TomcatProtocolHandlerCustomizer`로 **요청 실행기만** `Executors.newVirtualThreadPerTaskExecutor()`로 교체. (@Async/스케줄러/Kafka 무영향.)
- **풀 토글**: `spring.datasource.hikari.maximum-pool-size`(`SHOP_CORE_HIKARI_MAX_POOL`).
- **서버측 지표(관측성, ADR-010)**: Micrometer/Prometheus — `jvm_threads_peak_threads`(플랫폼 스레드 피크), `hikaricp_connections_max`. **VT 활성 교차검증 = 피크 스레드**(가상스레드는 `ThreadMXBean` 미집계 → VT면 피크가 안 치솟음).
- **셀마다 앱 재기동**(VT·풀 조합), 메인이 k6 실행·서버측 수집.

### ★ 측정상 중요 한계 (절대수치 해석 주의)
**k6·shop-core·PostgreSQL이 동일 개발 머신에서 CPU를 공유**한다. 관측된 throughput 천장(~920/s)·꼬리지연 절대값은 **그 머신 전체 CPU 한계의 산물**이라 비대표적이다. **단, VT vs 플랫폼 상대 비교는 동일 조건이므로 유효**하다(본 리포트의 결론은 상대 비교).

---

## 3. 결과 매트릭스

| 셀 | 풀 | 모델 | throughput | p95 | p99 | 피크 플랫폼 스레드 | read_5xx |
|---|---|---|---|---|---|---|---|
| 1 | 10 | 플랫폼 | 984/s | 442ms | 570ms | 277 | 0 |
| 2 | 10 | VT | 877/s | 472ms | 700ms | 91 | 0 |
| 3 | 50 | 플랫폼 | ~920/s | **599~634** (~620) | **830~905** (~865) | **281** | 0 |
| 4 | 50 | **VT** | ~915/s | **436~495** (~460) | **605~656** (~625) | **98** | 0 |

- 풀10(셀1·2)은 단일 런 — 비교 보조용.
- **풀50(셀3·4)은 각 3런** 측정:
  - 플랫폼: p95 = {634, 599, 629}, p99 = {905, 830, 862}, throughput {897, 940, 923}/s
  - VT: p95 = {495, 447, 436}, p99 = {656, 619, 605}, throughput {866, 929, 949}/s
  - **두 분포가 비중첩**: 플랫폼 최선(p95 599 / p99 830)이 VT 최악(p95 495 / p99 656)보다도 나쁘다 → 노이즈 아님.

---

## 4. 분석

### 4.1 throughput — 풀·스레드모델 무관 (이득 없음)
풀 10→50도, 플랫폼→VT도 throughput을 못 올렸다(~900~980/s 평탄). 풀을 늘려도 무변화였으므로 **병목은 커넥션 풀이 아니다**. 천장은 **CPU/처리능력**(동거 머신 CPU 공유 추정). → "풀을 늘리면 VT가 이긴다"는 가설은 **기각**.

### 4.2 꼬리지연 — VT가 유의하게 낮음 (확정 이득)
풀50·300동시에서 **VT가 p95 ~26%↓(~620→~460), p99 ~28%↓(~865→~625)**. 각 3런·분포 비중첩으로 통계적으로 유의.
- **메커니즘**: 플랫폼은 300 동시 요청에 ~280 스레드를 만들어 (CPU 제약 머신에서) CPU를 두고 경합 → 컨텍스트 스위칭/스케줄링 오버헤드가 **꼬리지연을 악화**시킨다. VT는 ~98 스레드(carrier+기준)라 그 경합이 적어 **꼬리지연이 낮다**. = 알려진 **"스레드 풀 포화 시 tail latency 개선"** 이득.
- **단서**: 동거 머신이라 280-스레드 CPU 경합이 **증폭**됨. 코어가 많은 전용 머신에선 이득 폭이 작아질 수 있으나 방향은 타당.

### 4.3 스레드 효율 — VT ≈ 1/3
같은 300 동시 부하를 플랫폼 ~280, VT ~90~98 스레드로 처리(풀 무관 일관). 스레드당 스택 메모리·스케줄링 비용을 감안하면 **고동시성에서 자원 효율**이 분명.

---

## 5. 결론 / 권장

1. **throughput 이득 없음**(CPU 바운드). 성능(처리량) 목적의 VT 채택 근거는 없다.
2. **그러나 고동시성에서 (a) 꼬리지연 −26~28%, (b) 플랫폼 스레드 1/3 의 실측 이득이 확인**됐다. VT는 "성능 도구"가 아니라 **"자원 효율 + 꼬리지연 안정화 도구"**다.
3. **결정**: 현재 동시성·배포 규모에선 throughput이 핵심이고 그 이득이 없으므로 **미도입 유지가 합리적**(CLAUDE.md "즉시 활성화 안 함"과 정합). **"VT 무용"이 아니라 "현 시점 우선순위 아님"**.
4. **재평가 트리거**: 동시성이 높아 플랫폼 스레드가 수백으로 포화되어 **꼬리지연·메모리가 운영 이슈**가 될 때. VT 빈이 기본 off로 보존돼 있어 토글(`shop.threads.virtual.enabled=true`)만으로 켜고 재측정 가능.
5. **throughput 이득이 생기는 별개 조건**: 풀 밖에서 오래 블로킹하는 경로(외부 서비스 호출 등) 추가 시. shop-core엔 아직 없음.

---

## 6. notification 이메일 경로 VT 평가 — 보류 결정

- **SMTP 발송은 외부 소켓 블로킹 I/O**라 원리적으로 VT 적합 영역이나, **신뢰 있는 측정이 현재 불가**하여 보류한다.
  - **log 모드**(현 운영 대안): 네트워크 I/O가 0이라 블로킹이 없어 **VT 비교가 무의미**(차이 0).
  - **실 SMTP(Gmail)**: rate limit·`454` 차단 사고로 **부하 측정 불가**.
  - 신뢰 측정은 **지연 주입 가짜 SMTP**(Mailpit + toxiproxy 등)로만 가능 — 인프라 셋업 필요.
- **분석상 결론은 이미 명확**: notification 이메일의 throughput 천장은 **SMTP 서버 용량**(Gmail은 낮음)이고, 운영은 **CircuitBreaker(025) + 컨슈머 동시성으로 발송을 의도적으로 바운드**(SMTP 보호·454 사고 교훈)한다. 따라서 VT로도 throughput은 못 올린다(SMTP-capped). VT의 이득은 본 리포트와 동일한 **자원 효율(제한된 동시성을 적은 스레드로)** 에 그칠 공산이 크다.
- **결정**: 지연 주입 측정의 셋업 비용 대비 결론이 본 리포트와 유사하므로 **Task 007 보류**. 필요 시 지연 주입 가짜 SMTP로 후속 측정 가능.

---

## 7. 측정 운영 메모 (재현·주의)

본 측정에서 겪은 실무 함정 — 동일 측정 재현 시 참고:

1. **VT 활성 판정 = 피크 플랫폼 스레드**: 가상스레드는 `ThreadMXBean`에 안 잡힌다. 300 동시 부하 후 `jvm_threads_peak_threads`가 **~280이면 플랫폼(VT off), ~90이면 VT on**. idle 상태로는 구분 불가 — 반드시 부하 중/후 피크로 판정.
2. **gradle 데몬 + 환경변수 함정**: `SHOP_X=y ./gradlew bootRun`에서 데몬이 떠 있으면 새 셸 환경변수가 포크된 앱 JVM에 **상속되지 않을 수 있다**. 토글이 안 먹으면 데몬 의심. **확실한 방법**: `--args='--shop.threads.virtual.enabled=true'`(program arg, 최우선) 또는 `java -D... -jar`(jar 직접) 또는 IDE Program arguments. 풀 적용 여부는 `hikaricp_connections_max`(10이 아니라 50으로 보이는지)로 검증.
3. **CPU 공유 증폭**: k6·앱·PG 동거라 스레드 경합 효과가 과장될 수 있음. 절대수치보다 **상대 비교**로 해석. 엄밀히 하려면 부하발생기·앱·DB를 분리한 전용 환경에서 재측정.
4. **단일 런 변동**: 단일 런 p95/p99는 ±10~30% 흔들린다. 결론은 **다회(3런+) 분포 비중첩**으로만 확정(풀50 비교가 그 근거, 풀10은 단일런이라 보조).

---

## 8. 산출물 / 참고

- VT 빈: `shop-core/.../common/config/VirtualThreadConfig.java`(기본 off, 조건부) + `application.yml` hikari 풀 가드.
- 측정 도구: `shop-core/perf/k6/scenarios/catalog-read.js` + `PROFILES.conc`(`CONC_VUS` env) + `READ_THRESHOLDS`.
- 런타임 산출물: `build/k6/vt-cell{1..4}-*.json`(gitignore).
- 관련: Task/plan 006, 결과 revision `docs/plans/revisions/performance/006-...-result-revision-1.md`, 관측성 ADR-010.

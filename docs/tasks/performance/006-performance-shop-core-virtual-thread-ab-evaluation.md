# 006. shop-core 가상스레드 도입 A/B 평가 (빈 기반, 측정 근거 확보)

> 출처: 사용자 요청 — 가상스레드(VT) 도입/미도입의 성능 차이를 **측정해 근거 확보**. CLAUDE.md "향후 가상스레드 도입 대비"(현재는 즉시 활성화 안 함)와 정합 — 본 Task는 **평가**이지 채택이 아니다(VT는 기본 off, A/B 측정 시에만 켠다).

## 배경 / 측정 타당성 (핵심)
- VT는 **"블로킹 I/O 요청이 플랫폼 스레드 풀을 고갈시킬 때"** 처리량·지연을 개선한다. 단일 요청을 빠르게 하지 않는다.
- 현재 shop-core 기본값: Tomcat 플랫폼 스레드 **200**, HikariCP 풀 **10**, VT 미도입(전부 기본값 확인됨).
- **주문 핫패스의 현재 병목은 스레드가 아니다**: 시드가 variant 1개라 모든 주문이 **단일 행 `PESSIMISTIC_WRITE` 락**에 직렬화돼 ~90~100/s에 막힌다(001~005 실측). 이 상태로 VT를 재면 **차이 ≈ 0**(락은 VT와 무관) → "VT 무용"이라는 **가짜 근거**가 나온다.
- 따라서 **유효한 측정은 워크로드를 "스레드 바운드"로 만든 뒤** 해야 한다(아래 Scope).

## 채택 결정 (재논의 금지)
- **전역 프로퍼티 `spring.threads.virtual.enabled` 미사용.** 대신 **빈**으로 Tomcat 요청 실행기만 VT로 교체:
  `TomcatProtocolHandlerCustomizer` + `Executors.newVirtualThreadPerTaskExecutor()`, **`@ConditionalOnProperty(shop.threads.virtual.enabled=true)` 기본 off**.
  - 이유: 범위 명확(요청 처리만, @Async/스케줄러 무영향), 조건부 게이트로 A/B 토글 깔끔, "즉시 활성화 안 함" 기조 유지.

## Target
- shop-core: VT 요청 실행기 빈(`config/` 또는 `web/`), 측정용 HikariCP/Tomcat 설정(프로파일·환경변수 가드).
- k6: 스레드 바운드 워크로드(다중 variant 시드 + 고동시성 프로파일).
- **프로덕션 기본 동작 무변경**(VT off, 풀 기본값) — 측정 시에만 환경변수로 켠다.

## Goal
"VT 도입 vs 미도입"을 **동일 스레드 바운드 워크로드**에서 A/B 측정해 처리량·p95/p99·dropped·서버측 지표 차이를 근거로 제시한다. 결론은 측정이 말하게 한다(개선/무차이 어느 쪽이든 정직히 기록).

## 범위 (Scope)
### (1) 백엔드 — VT 빈 + 측정 설정 (backend-implementor)
- **VT 빈**: 위 `TomcatProtocolHandlerCustomizer`(조건부, 기본 off). 프로덕션 무영향.
- **pinning 점검(중요)**: 핫패스(주문 생성·결제·쿠폰 경로)에 `synchronized` 블록이 블로킹 호출을 감싸면 carrier 스레드가 고정돼 VT 효과가 사라진다. 핫패스 `synchronized` 사용을 grep·점검해 보고(있으면 VT 효과 제약을 명시). ThreadLocal 직접 사용도 점검(CLAUDE.md 권고).
- **측정용 HikariCP 풀 상향**: 기본 10이면 커넥션이 캡이라 스레드가 한가 → VT 무의미. 측정 프로파일에서만 풀을 올린다(예 `SHOP_CORE_HIKARI_MAX_POOL` 환경변수, 기본은 현행 유지). DB가 캡이 되지 않을 정도로(예 100+, PG max_connections 감안).
- **앱/도메인 로직 무변경**(설정·빈만). API·정합 불변.

### (2) k6 — 스레드 바운드 워크로드 (k6-implementor)
- **다중 variant 시드**: `seed.js`가 variant N개(예 50~200) 생성, VU가 분산 주문 → 단일 행 락 직렬화 제거(주문이 서로 다른 행을 잠금). 이래야 ~100/s 천장이 풀려 스레드가 병목이 될 수 있다.
- **고동시성 프로파일**: 플랫폼 스레드 200을 초과해 큐잉시키는 동시성(VU/rate). 기존 stress/load 재사용 또는 전용 프로파일. 블로킹 시간이 충분한 경로(주문 생성=DB 쓰기 블로킹) 가압.
- **읽기 경로 대안(선택)**: 공개 상품 목록 GET(`/api/v1/products`, 락 없음·DB 읽기 블로킹)을 고동시성으로 가압하는 시나리오도 VT 효과 관찰에 유용(쓰기 락 영향 배제). plan에서 택1·혼합.

### (3) A/B 측정 (메인)
- 같은 워크로드·깨끗한 DB·같은 머신. **앱을 두 번 기동**: 미도입(`shop.threads.virtual.enabled` 미설정) vs 도입(`-Dshop.threads.virtual.enabled=true`). 각 **다회 측정**(001~002 교훈: 단일 런 변동 큼).
- notification은 측정 내내 **정지/log**(주문 이벤트 메일 사고 방지 — 005 선례).
- **비교 지표**: 달성 throughput(orders/s), http_req_duration p95/p99, dropped_iterations, 에러율. **서버측(Grafana/Prometheus 이미 배선)**: 활성 스레드 수, `hikaricp_connections_active/pending`, `http_server_requests` p95, JVM.

## Non-goals
- **VT 실제 채택(기본 on)** — 하지 않음(평가만, 기본 off). 채택은 측정 근거 후 별도 결정/ADR.
- 프로덕션 풀·스레드 튜닝 확정 — 측정용 설정만.
- 도메인 로직·API 변경. 분산 부하(k6 Cloud).

## 검증 방법
- VT 빈이 **조건부**로만 활성(미설정 시 미생성)이고 프로덕션 기본 동작 무변경: 풀 스위트 그린(설정 추가가 기존 테스트 무해), `-Dshop.threads.virtual.enabled=true` 기동 시 빈 생성·요청이 VT에서 처리됨(로그/스레드명 `VirtualThread` 확인).
- A/B 측정 산출: 도입/미도입 각 baseline JSON + 비교표(throughput·p95/p99·dropped·서버측). **결론(개선폭 또는 무차이 + 원인)** 을 문서화.
- pinning 점검 결과 기록(핫패스 synchronized 유무 → VT 효과 해석에 반영).

## 트레이드오프 / 정직한 전제
- **워크로드 설계가 결론을 좌우**한다. 락/풀 바운드로 재면 VT 무차이가 나오며, 그건 "지금 워크로드엔 VT 이득 적음"이라는 (유효한) 근거지 "VT 일반적 무용"이 아니다. 스레드 바운드 워크로드 결과와 함께 해석한다.
- pinning(synchronized)·ThreadLocal이 핫패스에 있으면 VT 이득이 깎인다 — 측정 전 점검.
- 단일 PG·개발 머신 한계도 함께 기록(절대수치 아닌 상대 비교가 근거).

## 참고
- CLAUDE.md "향후 가상스레드 도입 대비", k6 로드맵·Task 001~005(워크로드/시드/측정 규율), 관측성 ADR-010(서버측 상관)
- 구현: VT 빈·설정=backend-implementor / 다중 variant·고동시성 워크로드=k6-implementor / A/B 측정=메인

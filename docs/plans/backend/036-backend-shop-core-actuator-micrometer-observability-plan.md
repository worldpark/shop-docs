# Plan 036. shop-core 관측성 기반 — Actuator + Micrometer(Prometheus)

> 대상 Task: `docs/tasks/backend/036-backend-shop-core-actuator-micrometer-observability.md`
> 선행 결정: ADR-010(관측성 도입, r4j 코어 유지). 레지스트리 = **Prometheus**(사용자 확정).
> 구현 담당: `backend-implementor` (메인 오케스트레이션은 메인 에이전트)

## 1. 목표
shop-core가 Actuator health + Prometheus 스크레이프 엔드포인트와 표준 Micrometer 메트릭(JVM·HTTP 서버·HikariCP·Kafka 클라이언트)을 노출한다. 도메인 로직·REST·뷰는 무변경. 풀컨텍스트 테스트 그린 유지.

## 2. 변경 대상 파일
- `shop-core/build.gradle` — 의존 2개 추가.
- `shop-core/src/main/resources/application.yml` — `management` 섹션 추가.
- `shop-core/src/main/java/com/shop/shop/security/SecurityConfig.java` — **actuator 전용 보안 체인(@Order(0)) 신설**(기존 REST@Order(1)/View@Order(2) 체인 무변경).
- (테스트) actuator 노출/인가 검증 통합 테스트 1개 신규.

## 3. 의존 추가 (build.gradle)
```gradle
// Observability (ADR-010) — Actuator + Micrometer Prometheus. 버전은 Spring Boot BOM 관리.
implementation 'org.springframework.boot:spring-boot-starter-actuator'
implementation 'io.micrometer:micrometer-registry-prometheus'
```
- 버전 명시 금지(BOM 위임). web/security는 이미 존재하므로 추가 없음.

## 4. application.yml (management 섹션)
```yaml
management:
  endpoints:
    web:
      exposure:
        include: ${SHOP_CORE_MGMT_ENDPOINTS:health,info,prometheus}   # 와일드카드 금지(최소 노출)
  endpoint:
    health:
      show-details: when_authorized        # 미인증엔 UP/DOWN만, 상세는 인증 시
      probes:
        enabled: true                      # liveness/readiness (단일 노드 단계 선택, 켜둬도 무해)
  metrics:
    tags:
      application: shop-core               # 037(notification)과 구분되는 공통 태그
  prometheus:
    metrics:
      export:
        enabled: true
```
- 관리 포트 분리는 하지 않는다(shop-core는 메인 8080에 actuator 동거 — 업무 API와 같은 포트, 보안 체인으로 분리). 운영 포트 분리가 필요하면 후속.

## 5. 보안 — actuator 전용 체인 (@Order(0) 신설)
현재 `/actuator/**`는 어떤 핸들러에도 매핑되지 않아 **View 체인(@Order(2))의 `anyRequest().authenticated()` + formLogin이 302 리다이렉트**한다. 기존 두 체인을 건드리지 않고 **가장 먼저 매칭되는 전용 체인**을 추가한다.

```java
// import org.springframework.boot.actuate.autoconfigure.security.servlet.EndpointRequest;

@Bean
@Order(0)
public SecurityFilterChain actuatorChain(HttpSecurity http) throws Exception {
    http
        .securityMatcher(EndpointRequest.toAnyEndpoint())   // 관리 base-path(/actuator/**)만 이 체인이 처리
        .authorizeHttpRequests(auth -> auth
            .requestMatchers(EndpointRequest.to("health")).permitAll()   // 헬스 체크·k6 사전 점검 공개
            .anyRequest().permitAll()    // 로컬/개발: prometheus·info 공개. (운영 인가 제한은 plan §8 결정)
        )
        .csrf(csrf -> csrf.disable())                         // 관리 엔드포인트는 폼/브라우저 대상 아님
        .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS));
    return http.build();
}
```
- `@Order(0)`로 REST(@Order(1))·View(@Order(2))보다 먼저 매칭 → actuator 경로가 view formLogin에 더는 안 걸린다.
- `EndpointRequest`는 actuator 의존 추가로 사용 가능(import 경로 위 주석).
- **show-details(§4) × health permitAll 상호작용**: health를 permitAll로 열어도 `show-details: when_authorized`라 **미인증 요청엔 상세 없이 `{"status":"UP"}`만** 반환된다(§7 단언과 일관). 즉 "공개 도달성"과 "상세 비노출"이 동시에 성립한다 — 의도된 동작.
- **운영 노출 정책**(§8): 로컬은 prometheus 공개가 편하나, 운영은 prometheus/info를 네트워크 격리 또는 인가 제한으로 좁힌다. 본 plan은 로컬 기준 permitAll로 두고, 운영 강화는 환경별 설정·후속으로 명시.

## 6. 자동 제공 메트릭 (코드 0줄)
actuator+micrometer-prometheus 추가만으로 자동 바인딩:
- `jvm_*`(메모리·GC·스레드), `process_*`, `system_*`
- `http_server_requests_*`(Spring MVC 타이밍 — 엔드포인트별 p95 등)
- `hikaricp_*`(커넥션 풀 — 주문 핫패스 락 대기와 상관 분석 핵심)
- `spring_kafka_*` / `kafka_*`(프로듀서 — Outbox 발행 경로)
- 커스텀 비즈니스 메트릭은 본 plan 비범위(Task Non-goals).

## 7. 검증
- 앱 기동 후:
  - `GET /actuator/health` → **200 `{"status":"UP"}`**(이전 302 해소).
  - `GET /actuator/prometheus` → 200, `jvm_`, `http_server_requests_`, `hikaricp_` 메트릭 텍스트 노출.
- **신규 통합 테스트**(`@SpringBootTest` + `MockMvc` 또는 `@AutoConfigureMockMvc`): 미인증 `/actuator/health` 200, `/actuator/prometheus` 200(로컬 정책), 임의 보호 경로(`/api/v1/orders`) 여전히 401 — actuator 체인이 다른 경로를 새로 열지 않음(회귀 가드).
  - **배선 전제**: 이 프로젝트의 풀컨텍스트 보안 테스트는 Repository를 모두 mock해야 컨텍스트가 로드된다. 신규 테스트는 **기존 `SecurityConfigTest` 배선 패턴을 그대로 따른다**(`@MockSharedRepositories` + `@ActiveProfiles("test")` + 필요한 `@MockitoBean`/Fake 빈). 새 mock 전략을 발명하지 말 것.
- **풀컨텍스트 `./gradlew test` 그린**(메인 최종 동적 게이트). actuator 체인 추가가 기존 시큐리티/슬라이스 테스트를 깨지 않음.
- k6 README의 사전 점검 `GET /actuator/health`가 실제 200을 반환하는지 확인(정합).

## 8. plan 확정 결정 (구현 전 고정)
1. 레지스트리 = Prometheus(확정).
2. 노출 = `health,info,prometheus`(최소). show-details = `when_authorized`.
3. actuator 보안 = 전용 @Order(0) 체인, health permitAll + (로컬) 나머지 permitAll. 운영 인가 제한은 환경 설정/후속.

## 9. 리뷰 관점 (reviewer 체크리스트)
- actuator 체인이 **@Order(0)**로 REST/View보다 먼저 매칭되고 `securityMatcher(EndpointRequest)`로 **/actuator 범위에만** 적용되는가(다른 경로 인가에 영향 없음).
- 노출 목록에 와일드카드(`*`)가 없는가(최소 노출).
- 기존 REST@Order(1)/View@Order(2) 체인이 **무변경**인가.
- 버전 하드코딩 없이 BOM 위임인가.
- 테스트가 "미인증 health 200 + 보호 경로 401 회귀"를 함께 단언하는가.
- 도메인/REST/뷰 코드 무변경.

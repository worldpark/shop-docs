# 034. shop-core 도메인 통신 전송 토글 기반 — spi 포트 원격(REST) 전환 메커니즘

> 출처: `shop.domains.{도메인}.separated` 플래그 기반 **도메인 통신 추상화 이니셔티브**(2026-06-15). 현재 모듈 간 통신은 spi 포트의 **in-process 어댑터**로만 이뤄진다(`application.yml` `shop.domains.*.separated` 플래그는 선언만 되어 있고 동작에 영향 없음). 본 Task는 그 플래그에 따라 **같은 동기 포트를 원격(REST)으로도 호출**할 수 있는 **공통 전송 토글 기반**을 만든다. 비동기 경로는 본 Task가 새로 만들지 않고 **기존 `@Externalized` Kafka 이벤트를 그대로 재사용**한다. **실제 서비스/DB 분리는 하지 않는다**(공유 DB·단일 배포물 유지).

## Target
shop-core (common 전송 인프라 + spi/adapter 경계 — 도메인 무관 공통 틀)

> **전송 스왑 메커니즘과 공통 인프라에 한정**한다(플래그 기반 빈 선택 + REST 클라이언트 + 내부 서비스 API 보안/에러 매핑). 특정 도메인 적용은 후속(035 member 파일럿). **데이터 소유권/DB 분리·서비스 추출은 범위 밖**(ADR-009 이후 별 이니셔티브). 신규 도메인 기능 없음.

---

## Goal
`shop.domains.{도메인}.separated` 플래그가 `true`면 **그 도메인이 구현(소유)한 어댑터**(= 그 도메인 모듈의 `*/adapter/*` 가 다른 모듈 소유 spi 포트를 구현한 in-process 어댑터, 그리고 그 도메인이 소유·구현한 자기 spi 포트 구현)가 **원격 어댑터**로 전환되어, 그 구현 모듈이 노출하는 **내부 REST 엔드포인트**로 호출되도록 하는 **공통 토글·전송 기반**을 제공한다. `false`(기본)면 **기존 in-process 어댑터**로 처리된다.

> **플래그 의미 확정(A안 — 구현=어댑터 소유 모듈 기준, 2026-06-15 사용자 확정).** 한 포트에는 **소유(인터페이스) 모듈 ≠ 구현(어댑터) 모듈 ≠ 호출 모듈**이 공존한다(예: `product/spi/UserDirectory`는 product 소유 + member 구현 + product 호출). `{도메인}.separated=true`의 대상은 **그 도메인이 구현한 어댑터**다. 예: `member.separated=true` → member가 구현한 `MemberUserDirectoryAdapter`·`MemberReviewerDirectoryAdapter`(product.spi 구현) 및 `MemberDirectoryImpl`(member.spi 구현)이 원격 어댑터로 전환되고, member 모듈이 내부 REST 엔드포인트를 노출한다. 호출 모듈(product·cart·order 등)은 **동일 spi 인터페이스의 원격 빈을 주입**받으므로 호출측 코드는 무변경이다.

기능 동작 결과는 두 모드에서 **동일**해야 한다(전송 경로만 다름). 비동기는 본 Task가 신규 산출물을 만들지 않고 기존 `@Externalized` Kafka 이벤트를 재사용한다. 본 Task는 메커니즘과 공통 인프라만 제공하고, 실제 적용 포트는 035에서 검증한다(여기서는 1개 참조 포트로 메커니즘 동작만 실증).

## Context
- **현재 통신 방식**: 모듈 경계는 `*/spi/*` 포트 + 그 포트를 **구현하는 모듈의 `*/adapter/*` 또는 `*/service/*`** (in-process). 포트마다 **소유(인터페이스) 모듈·구현(어댑터) 모듈·호출 모듈이 서로 다를 수 있다.** 예: `product/spi/UserDirectory`(product 소유) ← `member/adapter/MemberUserDirectoryAdapter`(member 구현) ← product 호출; `member/spi/MemberDirectory`(member 소유) ← `member/service/MemberDirectoryImpl`(member 구현) ← cart/order/payment 호출. `docs/rules/package-structure-rule.md` 준수.
- **플래그 의미(A안)**: `{도메인}.separated=true`는 **그 도메인이 구현(소유)한 어댑터**를 원격화한다는 뜻이다(인터페이스 소유 모듈 기준 아님). 따라서 한 도메인의 플래그를 켜면 그 도메인이 구현한 모든 경계 어댑터(타 모듈 소유 포트 구현 + 자기 소유 포트 구현)가 원격 대상이 되고, 그 도메인 모듈이 내부 REST 엔드포인트를 노출한다.
- **플래그 현황**: `application.yml` `shop.domains.{member,product,cart,inventory,order,payment}.separated`(기본 false, 환경변수 override). **현재 어떤 코드도 이 값을 읽지 않는다.**
- **통신 종류**: 모듈 경계 호출은 (a) **동기 읽기/명령**(예: email→userId, 카탈로그 조회) → 원격 시 **REST**, (b) **비동기 알림**(도메인 이벤트) → 이미 Spring Modulith `@Externalized`로 **Kafka 외부화**(`event-catalog.md`)되어 있음. 본 Task는 (a)의 REST 전환 메커니즘만 신규로 만들고, (b)는 **기존 Kafka 이벤트 경로를 그대로 재사용**한다(본 Task가 Kafka를 새로 만들지 않으며, 신규 request/reply Kafka도 미도입).
- **공유 DB 유지**: 분리하지 않으므로 원격 호출은 같은 앱의 내부 REST 엔드포인트로 **루프백**된다(원격 경로 실증 목적). 데이터·트랜잭션 경계는 변하지 않는다.
- **보안**: 내부 서비스 간 호출용 엔드포인트는 공개 API가 아니다. `docs/rules/api-authorization-rule.md`에 따라 **최소 노출·서비스 인증**이 필요하다.
- **에러 계약**: 원격 호출 실패(4xx/5xx·타임아웃)는 기존 `BusinessException`/`error-response-rule` 체계로 환원되어야 호출측 코드가 모드와 무관하게 동일하게 처리한다.

## plan 확정 필요 (설계 결정 — plan에서 확정)
1. **빈 선택 메커니즘**: 같은 포트 인터페이스에 in-process 빈과 원격 빈 중 **하나만 활성**화하는 방식. (권장: 각 어댑터에 `@ConditionalOnProperty("shop.domains.{도메인}.separated", havingValue=...)`. in-process는 `matchIfMissing=true`. 대안: 팩토리/`@Primary` 셀렉터.) 두 빈 동시 활성/미존재가 없도록 보장.
   - **빈 충돌 방지(필수)**: 기존 in-process 어댑터(`@Component`)에 `@ConditionalOnProperty(..., matchIfMissing=true)`를 **부착**해야 `separated=true`때 in-process 빈과 원격 빈이 동시 등록되어 `NoUniqueBeanDefinitionException`이 나는 것을 막는다(현재 `MemberUserDirectoryAdapter` 등은 무조건 `@Component`로 등록됨). 이 애너테이션 부착은 런타임 동작 불변이지만 **기존 어댑터 파일 수정**이므로, §Constraints의 "in-process 무변경" 원칙의 **명시적 예외(애너테이션 추가, 동작 불변)** 로 plan에 적시한다.
2. **REST 클라이언트 기술**: 동기 호출용 (권장: Spring `RestClient`. 대안: `WebClient`). 타임아웃·커넥션 풀·재시도 정책 기본값.
3. **내부 서비스 API 인증/노출 + 보안 체인**: 내부 호출 전용 엔드포인트의 경로 규약과 인증(공유 서비스 토큰 헤더 vs 기존 JWT 재사용)·SecurityConfig matcher. 외부 비노출 보장.
   - **현재 보안 체인 사실(코드 확인)**: `SecurityConfig.restChain`은 `@Order(1)` + `securityMatcher("/api/v1/**")`이고 `viewChain`은 `@Order(2)` + 나머지 전체(formLogin·CSRF·세션·`anyRequest().authenticated()`). 따라서 `/internal/**`은 **restChain에 매칭되지 않고 viewChain으로 빠져** 브라우저 로그인/세션/CSRF 정책 아래 놓인다 — 서비스 토큰 stateless 호출에 부적합.
   - **해결(필수, plan에서 택1 후 확정)**: (a) **`/internal/**` 전용 신규 `SecurityFilterChain`** 추가 — `@Order(0)`(restChain/viewChain보다 먼저 매칭), `securityMatcher("/internal/**")`, CSRF disable, `SessionCreationPolicy.STATELESS`, 서비스 토큰 인증 필터. 또는 (b) 경로를 **`/api/v1/internal/**`** 로 두어 기존 restChain에 포함시키되 내부 인증 정책(서비스 토큰)을 restChain 안에 명시. 어느 안이든 **@Order 우선순위와 기존 두 체인 비파괴**를 제약으로 둔다.
4. **원격 에러 매핑 + 예외 의미론 보존**: REST 4xx/5xx·타임아웃·연결 실패 → 기존 예외 체계 매핑 규칙(`error-response-rule` 정합). 호출측이 모드 무관 동일 동작.
   - **예외 의미론 보존(필수)**: 원격 전송 실패의 매핑뿐 아니라, **포트 본래의 예외 의미론도 두 모드에서 동일 보존**해야 한다. 예: `UserDirectory`/`MemberDirectory`는 사용자 미존재 시 `IllegalStateException`(BusinessException **비계열**, 시스템 불변식 위반)을 던진다 — 원격 모드에서도 이 동일 타입/의미가 호출측에 전달되도록 매핑한다(원격 4xx를 무조건 BusinessException으로 뭉개지 않는다).
5. **Kafka 경로 범위**: 동기 포트는 REST만. 비동기는 기존 `@Externalized` 이벤트 재사용(본 기반에 request/reply Kafka 미도입 — 과설계 회피). plan에서 명시 확정.
6. **참조 포트(실증용) + 원격 대상 제약**: 메커니즘 검증을 위해 적용할 1개 포트. **원격 전환 대상은 호출자의 `@Transactional`·비관적 락에 묶이지 않은 순수 stateless read 포트만**으로 제한한다.
   - **적합 예**: `product.spi.UserDirectory.findUserIdByEmail`, `member.spi.MemberDirectory`의 단순 read(`findUserIdByEmail`).
   - **부적합(원격 전환 금지)**: `inventory.spi.InventoryStockPort`(order의 `@Transactional` + `SELECT ... FOR UPDATE` 안에서 실행되는 락 기반 차감/복원), `product.spi.ProductOrderCatalog`(비관적 락 획득 **후 재조회 스냅샷**이 저장 권위값 — 원격화 시 락-스냅샷 일관성 깨짐).
   - 권장: 035 member 파일럿에 미리 손대지 않고 영향 적은 stateless read 포트 1개로 토글 동작만 시연. plan에서 선택.
7. **ModularityTests 확인**: 원격 어댑터가 새로 추가하는 `common.transport` 의존 엣지가 ModularityTests를 통과함을 plan에서 확인한다(`common`은 OPEN 모듈이라 어느 도메인 모듈에서도 의존 허용).

## API Authorization
> `docs/rules/api-authorization-rule.md` 준수. 본 Task가 도입하는 **내부 서비스 API는 외부 비노출**이어야 한다. 공개 엔드포인트 신설 없음.
>
> **현재 체인 사실**: `SecurityConfig.restChain`은 `securityMatcher("/api/v1/**")`(@Order(1))라 `/internal/**` 경로를 **매칭하지 않는다** — 그대로 두면 `viewChain`(@Order(2), formLogin·CSRF·세션·`anyRequest authenticated`)으로 빠져 서비스-투-서비스 stateless 호출에 맞지 않는다.
>
> **반영(plan에서 확정)**: 내부 경로는 (a) **`/internal/**` 전용 신규 `SecurityFilterChain`**(@Order(0), `securityMatcher("/internal/**")`, CSRF disable, STATELESS, 서비스 토큰 인증 필터)로 보호하거나, (b) 경로를 `/api/v1/internal/**`로 두어 기존 restChain에 포함시키되 서비스 토큰 인증 정책을 명시한다. 어느 안이든 **@Order 우선순위 정합·기존 두 체인 비파괴**를 지키고, 일반 사용자/브라우저 접근을 차단한다.

## Requirements
- **플래그 기반 스위칭(A안)**: `shop.domains.{도메인}.separated=true`면 **그 도메인이 구현(소유)한 어댑터**가 **원격 어댑터**로, `false`(기본)면 **기존 in-process 어댑터**로 주입된다. 호출 모듈은 동일 spi 인터페이스 빈을 주입받으므로 무변경. 컨텍스트 기동 시 포트당 활성 빈은 정확히 1개.
- **공통 REST 클라이언트**: 내부 호출용 클라이언트 컴포넌트(타임아웃·에러 변환·추적 헤더 전파 포함). 도메인별 원격 어댑터가 재사용한다.
- **내부 서비스 API 골격**: 내부 호출 전용 엔드포인트 규약·보안 matcher. (실제 도메인 엔드포인트는 035에서 추가.) `/internal/**` 전용 보안 체인(또는 `/api/v1/internal/**`)으로 stateless 서비스 인증을 적용 — §API Authorization 참조.
- **에러 환원 + 예외 의미론 보존**: 원격 전송 실패는 기존 `BusinessException` 체계로 매핑하되, **포트 본래 예외 의미론(예: 미존재 시 `IllegalStateException` — BusinessException 비계열)도 두 모드에서 동일 보존**한다.
- **참조 포트 실증(stateless read 한정)**: in-process↔REST 전환을 실증할 1개 포트는 **호출자 `@Transactional`·비관적 락에 묶이지 않은 순수 stateless read 포트**여야 한다(적합: `UserDirectory`/`MemberDirectory` 단순 read. 부적합: `InventoryStockPort`·`ProductOrderCatalog` — 트랜잭션/락 결합). 토글 시 경로 전환을 통합 테스트로 보인다.
- **관측**: 원격 호출 경로 진입을 로깅(민감정보 제외) — 모드 판별 가능.

## Constraints
- **기능 동작 불변**: 두 모드(`true`/`false`) 결과가 동일. in-process 기본 동작(기존 흐름)은 무변경.
  - **명시적 예외(동작 불변)**: 빈 충돌 방지를 위해 기존 in-process 어댑터에 `@ConditionalOnProperty(..., matchIfMissing=true)`를 **부착**하는 것은 허용한다(런타임 동작 불변, 빈 등록 조건만 추가). 이 외의 기존 어댑터 로직 변경은 금지.
- **데이터/트랜잭션 경계 무변경**: 공유 DB 유지. 분산 트랜잭션·데이터 분리 도입 금지(범위 밖). **원격 전환 대상은 호출자 `@Transactional`·비관적 락에 묶이지 않은 순수 stateless read 포트로 제한**한다(부적합: `InventoryStockPort`·`ProductOrderCatalog` — 트랜잭션/락 결합으로 원격화 시 일관성 깨짐).
- **모듈/패키지 규칙**: `package-structure-rule`·ModularityTests 무위반. 원격 어댑터도 기존 의존 역전 방향(구현 모듈 adapter가 상대 모듈 소유 spi 구현)을 유지. spi 인터페이스는 변경하지 않는다(구현만 추가). 원격 어댑터 → `common.transport` 의존 엣지는 ModularityTests 통과를 plan에서 확인(`common`은 OPEN 모듈).
- **이벤트/계약 무변경**: 기존 Kafka 이벤트(`event-catalog.md`)·notification 무변경. 신규 request/reply Kafka 미도입.
- **보안**: 내부 API 외부 비노출. 시크릿 하드코딩 금지(환경변수/`*Properties`).
- **과설계 금지**: 파일럿 단계 필요한 최소 인프라만. 서킷브레이커·서비스 디스커버리·게이트웨이 미도입(후속).
- **테스트 인프라 비의존 원칙**: 단위/슬라이스는 인프라 없이, 원격 경로 통합은 기존 테스트 컨벤션(`testing-rule`) 준수.

## Files
> 정확 경로/배치는 plan 확정. 아래는 예시.
- (신규) `common/transport/**` — 플래그 기반 빈 선택 지원·공통 REST 클라이언트(타임아웃·에러 변환·추적 헤더), 원격 호출 예외→`BusinessException` 매퍼.
- (신규/수정) 내부 API 보안 체인 — `/internal/**` 전용 신규 `SecurityFilterChain`(@Order(0), `securityMatcher("/internal/**")`, CSRF disable, STATELESS, 서비스 토큰 필터)을 `security/SecurityConfig`에 추가하거나 별도 설정 클래스로 분리. (대안: `/api/v1/internal/**` 경로로 두어 기존 restChain에 포함 — 인증 정책 명시.) 기존 restChain(@Order(1))·viewChain(@Order(2)) 비파괴.
- (신규, 참조 실증) 1개 포트의 원격 어댑터 + 내부 엔드포인트(메커니즘 시연용).
- (수정, 선택) `application.yml` — 내부 API 인증/클라이언트 관련 설정 키(필요 시).
- (재사용·무변경) 기존 spi 포트 인터페이스·in-process 어댑터, `event-catalog.md`, notification, 마이그레이션 전부.

## Acceptance Criteria
- `shop.domains.{참조도메인}.separated=false`(기본)에서 기존 in-process 경로로 동작하고, `=true`에서 **원격(REST) 경로**로 동작하며 **결과가 동일**하다. 이 **정상 경로 양모드 동치성은 동일 프로세스 루프백 통합 테스트로 검증**한다.
- 포트당 활성 빈이 정확히 1개임이 컨텍스트 기동에서 보장된다(둘 다/0개 빈 없음).
- 원격 호출 실패(타임아웃·4xx/5xx·연결 실패)→`BusinessException`/`ErrorResponse` 환원은 **REST 클라이언트 에러 변환 단위 테스트(mock 주입)** 로 검증한다(동일 프로세스 루프백에서는 실 네트워크 실패가 자연 발생하지 않으므로 통합 테스트로 검증하지 않는다).
- 포트 본래의 예외 의미론(예: 미존재 시 `IllegalStateException` — BusinessException 비계열)이 **두 모드에서 동일 보존**된다.
- 내부 서비스 API가 외부(브라우저/일반 사용자)에 노출되지 않는다(`/internal/**` 전용 보안 체인 또는 `/api/v1/internal/**` 정책으로 stateless 서비스 인증).
- 기존 모듈 경계 동작·이벤트·notification·ModularityTests 무변경(회귀 없음). `./gradlew test` 풀 그린.

## Test
- **단위(Mockito)**: 빈 선택 조건(`@ConditionalOnProperty`) 분기, **REST 클라이언트 에러 변환**(타임아웃/4xx/5xx/연결 실패 mock → `BusinessException` 매핑) — 원격 실패 검증은 **여기서만**(mock 주입), 추적 헤더 전파, **포트 본래 예외 의미론 보존**(원격 어댑터가 미존재를 `IllegalStateException`으로 환원).
- **슬라이스/통합(Testcontainers·MockMvc)**: 참조 포트로 `separated=false`/`true` 양모드 **정상 경로 동치(같은 입력→같은 출력)만** 검증한다(동일 프로세스 루프백이라 실 네트워크 실패는 통합에서 다루지 않음). 내부 API 보안(비로그인/외부 접근 차단, stateless 서비스 인증) 검증.
- **회귀**: 기존 spi 경계 통합 테스트·ModularityTests 그린. `./gradlew test` 풀 그린.

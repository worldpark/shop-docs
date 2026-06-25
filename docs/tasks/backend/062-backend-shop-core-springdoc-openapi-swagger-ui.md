# 062. shop-core API 문서화 — springdoc-openapi + Swagger UI 도입

> 출처: REST API(`/api/v1/**`) 표면이 25개 컨트롤러로 커진 시점에서 기계가 읽는 OpenAPI 스펙 + Swagger UI를 도입하는 횡단 인프라 작업. 그동안 API 계약은 task 문서·코드 산재였고 대화형 탐색 수단이 없었다.
> notification은 독립 레포·빌드이며 외부 노출 REST 표면이 사실상 없으므로 **본 Task 범위 밖**("한 Task = 한 기능", 037 observability 분리 선례와 동일).
> 범위 SSOT: 본 문서. 설계 결정(시큐리티 체인 배치·스펙 그룹핑·프로파일 게이트·애노테이션 깊이)은 `docs/plans/backend/062-backend-shop-core-springdoc-openapi-swagger-ui-plan.md`에 위임한다.

## 기술 선택
- **springdoc-openapi (webmvc-ui starter)** — Spring Boot 3.x(MVC)의 사실상 표준. `@RestController`/Bean Validation/Jackson 메타데이터로 OpenAPI 3 스펙(`/v3/api-docs`)을 자동 생성하고 Swagger UI(`/swagger-ui.html`)를 번들로 제공한다. (대안: 수기 OpenAPI YAML 유지 — 코드와 드리프트되어 후순위. springfox — Spring Boot 3 미지원, 탈락.)
- **버전 명시 필요**: springdoc은 Spring Boot BOM이 관리하지 않는다. jjwt·redisson 선례와 동일하게 build.gradle에 버전을 고정한다(Spring Boot 3.5 호환 라인 — 정확 버전은 plan에서 확정). 와일드카드/SNAPSHOT 금지.

## Target
shop-core 빌드 의존성 + OpenAPI 설정 빈 + 시큐리티 노출 규칙 + 컨트롤러/DTO 문서화 애노테이션(경량 1차 패스). **도메인 로직·REST 동작·뷰·스키마·이벤트는 변경하지 않는다.**

## Goal
1. shop-core가 `/api/v1/**` REST 표면 전체를 OpenAPI 3 스펙으로 노출한다(`GET /v3/api-docs` JSON, `GET /v3/api-docs.yaml`).
2. Swagger UI(`/swagger-ui.html`)에서 엔드포인트를 탐색하고 "Authorize"(JWT Bearer)로 인증을 넣어 `Try it out` 호출이 가능하다.
3. 스펙이 실제 인가 정책(공개/권한)을 반영한다 — 공개 엔드포인트는 보안 요구 없음, 인증 엔드포인트는 Bearer 요구가 명시된다.
4. View(Thymeleaf, HTML 반환) 컨트롤러는 스펙에서 **제외**한다(API 문서가 화면 핸들러로 오염되지 않음).
5. 풀컨텍스트 테스트·ModularityTests·ArchUnit 그린 유지(문서화 도입이 기존 컨텍스트·모듈 경계를 오염시키지 않음).

## Context
### 현재 구조 — 반드시 대조
- **시큐리티 3체인**(`security/SecurityConfig.java`):
  - `@Order(0)` actuator 체인 — `securityMatcher(EndpointRequest.toAnyEndpoint())`, permitAll, CSRF off, STATELESS.
  - `@Order(1)` REST 체인 — `securityMatcher("/api/v1/**")`, STATELESS, CSRF off(JWT), Bearer 헤더 필터, 미인증 시 `RestAuthenticationEntryPoint`(401 JSON).
  - `@Order(2)` View 체인 — **나머지 전체**(`securityMatcher` 없음), JWT 쿠키 인증, 미인증 시 `LoginUrlAuthenticationEntryPoint`(302 `/login`), CSRF 쿠키 저장소.
  - **핵심 함정**: `/swagger-ui/**`, `/swagger-ui.html`, `/v3/api-docs/**`는 `/api/v1/**`도 actuator 엔드포인트도 아니므로 **현재 View 체인(@Order(2))에 걸려 미인증이면 `/login`으로 302 리다이렉트된다**(Task 036에서 `/actuator/**`가 겪은 것과 동일한 구조적 함정). 명시 허용 규칙이 없으면 Swagger UI/스펙에 아예 도달하지 못한다.
- **REST 인증 방식**: REST 체인은 `Authorization: Bearer <access_token>` 헤더. principal=userId(Long). 따라서 OpenAPI 보안 스키마는 **http bearer(JWT)** 단일이 표준. (View의 access_token 쿠키 인증은 화면 표면이며 API 문서 대상 아님 — Swagger의 호출 대상은 `/api/v1/**`.)
- **에러 응답 계약**(`error-response-rule.md`): `/api/v1/**`는 `@RestControllerAdvice`가 공통 `ErrorResponse`(status/error/message/path/timestamp) JSON으로 변환. 401/403은 시큐리티 EntryPoint·DeniedHandler가 처리.
- **REST 컨트롤러 25종**(member/product/order/payment/cart 도메인 — public/CONSUMER/SELLER/ADMIN 혼재). 인가 매핑은 `SecurityConfig` REST 체인과 각 컨트롤러 보안 테스트(`*SecurityTest`)에 이미 존재한다.
- **응답 본문은 record/DTO**(Entity 직접 노출 금지 — forbidden-rule). springdoc은 이 DTO들에서 스키마를 생성한다.

### 의존·빌드 선례
- BOM 미관리 의존은 버전 고정: `io.jsonwebtoken:jjwt-api:0.12.7`, `org.redisson:redisson:3.50.0`. springdoc도 동일 정책.
- starter 부작용 주의 선례(redisson-spring-boot-starter 금지): 새 starter가 기존 자동설정/필터체인을 바꾸지 않는지 plan에서 확인. springdoc-webmvc-ui는 정적 리소스 핸들러·`/v3/api-docs` 핸들러를 추가하므로 시큐리티·CSP·정적 매핑과의 상호작용 확인 필요.

## plan 확정 필요 (설계 결정 — 본 Task가 plan에 위임)
1. **의존 아티팩트·버전**: `org.springdoc:springdoc-openapi-starter-webmvc-ui:<Spring Boot 3.5 호환 버전>` 확정(버전 고정, BOM 미관리). webmvc-ui(UI 포함) vs webmvc-api(스펙만) 선택 — UI 포함 권장(대화형 탐색 목적).
2. **시큐리티 허용 위치(핵심)**: Swagger/스펙 경로(`/swagger-ui/**`, `/swagger-ui.html`, `/v3/api-docs/**`, `/v3/api-docs.yaml`, springdoc 정적 리소스 경로)를 어디서 permit할지.
   - 권장: actuator 체인(@Order(0)) 선례처럼 **전용 문서 체인(@Order, REST보다 먼저)** 또는 View 체인 상단 permitAll 매처. 코드 대조 후 확정. View 체인에 둘 경우 302 리다이렉트가 풀리는지·CSRF/정적 매처와 충돌 없는지 검증.
   - `/v3/api-docs`는 GET·읽기 전용이므로 CSRF 무관. Swagger UI `Try it out`이 상태 변경 `/api/v1/**`를 칠 때는 REST 체인(CSRF off, Bearer) 그대로 — 추가 CSRF 예외 불필요(확인).
3. **운영 노출 정책(보안)**: 프로덕션에서 스펙/UI를 노출할지. 권장: **non-prod(local/dev)만 활성**, prod는 `springdoc.swagger-ui.enabled=false`·`springdoc.api-docs.enabled=false` 또는 프로파일/`@ConditionalOnProperty`로 차단(민감 표면 과다 노출 방지 — api-authorization-rule 정합, 036의 "와일드카드 노출 금지" 정신). 게이트 방식은 메모리 선례 `shop-core-tests-no-active-profile-gating` 주의(활성 프로파일 없는 풀 @SpringBootTest에서 `@Profile` 역전 위험 → `@ConditionalOnProperty` default-off 권장).
4. **스펙 그룹핑·스캔 범위**: View(@Controller, HTML) 컨트롤러를 스펙에서 제외하고 `/api/v1/**`만 문서화하는 방법 — `GroupedOpenApi`(pathsToMatch `/api/v1/**`) 또는 `packagesToScan`. springdoc 기본은 모든 `@Controller`/`@RestController` 스캔이므로 명시 제한 필요.
5. **OpenAPI 메타·보안 스키마**: `OpenAPI` 빈(title=shop-core API, version, description, 서버 URL은 상대 경로 권장) + 전역 `@SecurityScheme`(type=http, scheme=bearer, bearerFormat=JWT) 정의. 공개 엔드포인트(`/auth/login`·`/members/signup`·공개 상품/카테고리 조회)는 보안 요구에서 제외, 그 외는 Bearer 요구. 공통 `ErrorResponse` 스키마를 401/403/404/409 응답 예시로 매핑할 범위.
6. **애노테이션 깊이(과설계 경계)**: 1차 패스는 **경량** — 컨트롤러별 `@Tag`(도메인 그룹), 주요 `@Operation(summary)` 정도. 엔드포인트마다 전 응답코드 `@ApiResponse`·전 파라미터 `@Parameter`를 빠짐없이 다는 것은 범위 밖(후속 점진 보강). 어디까지 달지 plan에서 상한을 명시(reviewer 과설계 관점 대비).

## API Authorization
> api-authorization-rule.md 준수. 본 Task는 **신규 비즈니스 API를 추가하지 않는다**. 추가되는 표면은 문서/UI 인프라 경로뿐이며, 기존 `/api/v1/**` 인가 정책은 무변경이다.

| 경로 | 공개 여부 | 최소 권한 | 소유권 검사 | 비고 |
|---|---|---|---|---|
| `GET /v3/api-docs`, `/v3/api-docs.yaml`, `/v3/api-docs/**` | non-prod permit / prod 차단 | — | 불필요 | OpenAPI 스펙. prod 노출 정책은 plan 3번 |
| `GET /swagger-ui.html`, `/swagger-ui/**` | non-prod permit / prod 차단 | — | 불필요 | Swagger UI 정적 표면 |
| `/api/v1/**` (기존 전부) | 무변경 | 무변경 | 무변경 | 문서화만. 인가 매처·권한 변경 없음 |

> Swagger UI에서의 실제 호출은 기존 REST 체인(Bearer 인증·권한 매처)을 그대로 통과하므로, UI 노출이 곧 인가 우회가 아니다. 그럼에도 prod 표면 최소화를 위해 스펙/UI는 non-prod 게이트를 기본으로 한다.

## Requirements
### A. 의존·기동
- build.gradle에 springdoc webmvc-ui 의존 추가(버전 고정). 기동 시 `/v3/api-docs`(JSON)·`/v3/api-docs.yaml`·`/swagger-ui.html`이 응답.
- 새 starter가 기존 자동설정(시큐리티 필터체인·정적 리소스 매핑·Jackson·Modulith)을 변경하지 않음을 확인(풀컨텍스트 그린).

### B. 시큐리티 노출
- 문서/UI 경로가 미인증에서 **302 `/login`이 아닌 정상 도달**(non-prod). plan 2번에서 정한 체인/매처로 permit. 기존 3체인 동작(actuator permit, REST 401 JSON, View 302) 회귀 0.
- prod 게이트(plan 3번)에 따라 prod 프로파일에선 스펙/UI 비활성 또는 차단.

### C. OpenAPI 메타·보안 스키마
- `OpenAPI` 빈으로 info(title/version/description)·서버·전역 JWT Bearer `SecurityScheme` 정의. Swagger UI "Authorize"에 Bearer 토큰 입력 → `/api/v1/**` 보호 엔드포인트 호출 성공.
- 공개 엔드포인트는 보안 요구 미표시, 인증 엔드포인트는 Bearer 요구 표시(실제 SecurityConfig 정책과 일치).

### D. 그룹핑·범위 제한
- 스펙에 `/api/v1/**` REST만 포함, View(@Controller HTML) 핸들러 제외. 도메인별 `@Tag` 그룹(member/product/order/payment/cart 등).

### E. 문서화 애노테이션(경량 1차 패스)
- 컨트롤러별 `@Tag`, 주요 엔드포인트 `@Operation(summary)`. Entity 직접 노출 금지 유지(응답 스키마는 기존 DTO/record 기준). 공통 `ErrorResponse` 스키마 노출.

### F. 공통
- 도메인 로직·REST 경로/시그니처/응답 본문·View·스키마(Flyway)·이벤트(event-catalog)·notification **무변경**. 문서화는 메타데이터 추가만.
- 레이어/모듈 경계 준수(architecture-rule, package-structure-rule). OpenAPI 설정 빈은 공통/설정 패키지에 배치(plan 확정), 도메인 모듈 경계 위반 금지.

## Constraints
- **동작 무변경(회귀 0)**: 기존 `/api/v1/**` 25개 컨트롤러의 경로·HTTP 메서드·요청/응답 본문·상태코드·인가 매처 불변. 문서화 애노테이션은 런타임 동작에 영향 없음.
- **버전 고정**: springdoc 버전 명시(BOM 미관리). SNAPSHOT/와일드카드 금지(jjwt·redisson 선례).
- **prod 표면 최소화**: 스펙/UI는 non-prod 기본 노출, prod 차단/비활성(plan 3번). 민감 표면 과다 노출 금지(api-authorization-rule).
- **시큐리티 회귀 0**: 3체인(actuator @Order(0) / REST @Order(1) / View @Order(2)) 동작 보존. 문서 경로 permit이 다른 경로의 인가를 넓히지 않음.
- **Entity 비노출**: 스키마는 기존 응답 DTO/record에서만 생성. Entity를 스펙에 끌어들이지 않음(forbidden-rule).
- **테스트 게이트 회귀**: 풀컨텍스트 `./gradlew test`·ModularityTests·ArchUnit·기존 `*SecurityTest` 그린.
- **범위 밖(명시)**: notification 문서화(독립 레포·별 task) / 수기 OpenAPI 계약·contract test(Spring Cloud Contract 등) / 클라이언트 SDK 자동생성 / API 버저닝 변경 / 엔드포인트별 전수 `@ApiResponse`·예시 완비(후속 점진) / 인증 흐름 변경.

## Files
> 정확 경로/패키지/시그니처는 plan 확정. 아래는 선례 대조 기준 예시.
### 수정
- `shop-core/build.gradle` — springdoc webmvc-ui 의존 추가(버전 고정 + 주석으로 BOM 미관리 사유, jjwt 선례 형식).
- `shop-core/.../security/SecurityConfig.java` — Swagger/스펙 경로 permit(전용 문서 체인 추가 또는 View 체인 매처 — plan 2번). 기존 3체인 주석 규약 유지.
- `shop-core/.../resources/application.yml` (+ 프로파일 yml) — `springdoc.*`(경로·UI 설정), prod 게이트(`api-docs.enabled`/`swagger-ui.enabled` 또는 `@ConditionalOnProperty` 키). 환경변수 오버라이드 가능하게.
- (경량) 도메인 REST 컨트롤러들 — `@Tag`/`@Operation(summary)` 추가(동작 무변경). 상한은 plan 6번.

### 신규
- `shop-core/.../config/OpenApiConfig.java`(또는 common/config) — `OpenAPI` 빈(info·서버·전역 Bearer `SecurityScheme`) + 필요 시 `GroupedOpenApi`(`/api/v1/**`). `@ConditionalOnProperty`로 prod-off 게이트(plan 3·5번).

### 무변경(재사용)
- 모든 Service/Repository/Entity/Flyway 마이그레이션, event-catalog.md, notification 전부, 기존 `@RestControllerAdvice`/`ErrorResponse`, 기존 인가 매처·권한 정책, View 컨트롤러 동작.

## Acceptance Criteria
- 기동 후 `GET /v3/api-docs`가 200 JSON(OpenAPI 3)으로 25개 REST 컨트롤러의 `/api/v1/**` 경로를 포함하고, `GET /swagger-ui.html`이 200으로 UI를 렌더한다(non-prod). 미인증에서 302 `/login`로 새지 않는다.
- View(@Controller HTML) 핸들러는 스펙에 나타나지 않는다.
- 스펙의 보안 정의가 실제 정책과 일치: 공개 엔드포인트(로그인/회원가입/공개 상품·카테고리 조회)는 보안 요구 없음, 보호 엔드포인트는 Bearer 요구. Swagger UI "Authorize"로 Bearer 토큰 입력 후 보호 엔드포인트 `Try it out` 호출이 200/정상 동작한다.
- prod 게이트(plan 3번)에 따라 prod 프로파일에선 스펙/UI가 비활성/차단된다.
- 기존 `/api/v1/**` 동작·인가·에러 응답 회귀 0. 풀컨텍스트 `./gradlew test`·ModularityTests·ArchUnit·기존 `*SecurityTest` 그린.

## Test
> testing-rule + verification-gate-rule. 문서/시큐리티 노출은 MockMvc/슬라이스로 검증 가능(브라우저 E2E는 화면 기능이 아니므로 불필요). "테스트 없이 기능 추가 금지".
- **시큐리티 슬라이스/통합(MockMvc 또는 `@SpringBootTest`)**:
  - 미인증 `GET /v3/api-docs` → 200(JSON), `GET /swagger-ui.html` → 200(또는 springdoc 리다이렉트 후 200). **302 `/login` 아님**(Task 036 actuator 회귀 검증과 동일 패턴).
  - 기존 3체인 회귀: `/api/v1/**` 미인증 401 JSON, View 보호 경로 미인증 302, actuator health 200 — 문서 경로 추가가 다른 체인을 깨지 않음.
  - prod 게이트 활성 시(해당 프로파일/프로퍼티) 스펙/UI 비활성/차단 검증.
- **스펙 내용 검증(통합)**: `/v3/api-docs` JSON에 (a) 대표 공개·보호 엔드포인트 경로 존재, (b) 보안 스키마(bearer/JWT) 정의 존재, (c) View HTML 경로 부재. (springdoc 자동생성 신뢰 — 전수 단언이 아니라 핵심 표면 스모크.)
- **컨텍스트 무오염**: 풀컨텍스트 `./gradlew test` 그린 — springdoc 도입이 기존 컨텍스트 로드·슬라이스·Modulith/ArchUnit을 깨지 않음(메인 최종 동적 게이트, verification-gate-rule §2). 메모리 선례 `shop-core-tests-no-active-profile-gating` 주의 — 게이트는 `@ConditionalOnProperty` default-off로(`@Profile` 역전 회피).
- **회귀**: 기존 `*SecurityTest` 전수 그린, REST 동작/에러 응답 불변. 메인 에이전트가 풀 스위트 그린 + Modulith verify를 자기 눈으로 확인(verification-gate-rule).

## 참고
- Task 036(actuator 시큐리티 노출 함정·전용 체인 선례), `docs/rules/api-authorization-rule.md`, `docs/rules/error-response-rule.md`, `docs/rules/architecture-rule.md`, `docs/rules/package-structure-rule.md`, `docs/rules/verification-gate-rule.md`
- 현재 시큐리티: `shop-core/.../security/SecurityConfig.java`(actuator @Order(0) / REST @Order(1) `/api/v1/**` / View @Order(2))
- 의존 버전 고정 선례: build.gradle의 jjwt(0.12.7)·redisson(3.50.0) 주석

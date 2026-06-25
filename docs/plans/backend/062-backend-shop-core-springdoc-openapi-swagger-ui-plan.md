# Plan 062. shop-core API 문서화 — springdoc-openapi + Swagger UI

> 대상 Task: `docs/tasks/backend/062-backend-shop-core-springdoc-openapi-swagger-ui.md` (범위 SSOT)
> 포맷 선례: `docs/plans/backend/036-backend-shop-core-actuator-micrometer-observability-plan.md` (횡단 인프라 + 시큐리티 전용 체인 신설)
> 구현 담당: `backend-implementor` (메인 오케스트레이션은 메인 에이전트)
> **화면 변경 없음 → `view-implementor` 불필요.** 본 Task는 의존·설정·시큐리티 노출·OpenAPI 빈·경량 컨트롤러 애노테이션만 추가한다. Thymeleaf 템플릿/ViewController는 무변경.

---

## 1. 목표

shop-core가 `/api/v1/**` REST 표면을 OpenAPI 3 스펙(`/v3/api-docs` JSON, `/v3/api-docs.yaml`)으로 노출하고, Swagger UI(`/swagger-ui.html`)에서 "Authorize"(JWT Bearer)로 인증해 보호 엔드포인트를 `Try it out` 호출할 수 있다. View(@Controller HTML) 핸들러는 스펙에서 제외한다. prod 프로파일에선 스펙/UI를 비활성화한다. **도메인 로직·REST 경로/시그니처/응답 본문·상태코드·인가 매처·View·스키마(Flyway)·이벤트는 무변경(회귀 0).** 문서화 애노테이션은 런타임 동작에 영향을 주지 않는 메타데이터 추가다. 풀컨텍스트 `./gradlew test`·ModularityTests·ArchUnit·기존 `*SecurityTest` 그린 유지.

---

## 2. 변경 대상 파일 (정확 경로)

### 수정
- `shop-core/build.gradle` — springdoc webmvc-ui 의존 1개 추가(버전 고정 + BOM 미관리 사유 주석).
- `shop-core/src/main/resources/application.yml` — `springdoc.*` 설정 섹션 + 기본값(non-prod 노출).
- `shop-core/src/main/resources/application-prod.yml` — **신규**(존재 시 수정). prod 게이트 override(`springdoc.api-docs.enabled=false`, `springdoc.swagger-ui.enabled=false`). ※ 현재 prod 프로파일 yml이 없으면 신설하되, **다른 prod 설정은 추가하지 않고** springdoc 게이트만 담는다(범위 최소화).
- `shop-core/src/main/java/com/shop/shop/security/SecurityConfig.java` — **문서 전용 보안 체인 신설**(`@Order(1)`로 삽입, 기존 actuator @Order(0)·REST·View 체인은 매처/동작 무변경. 아래 §5 참조 — 기존 @Order 재배치 포함).
- (경량) 도메인 REST 컨트롤러들(`**/controller/*RestController.java` 실측 약 27종, 증가 가능) — 컨트롤러별 `@Tag` + 주요 핸들러 `@Operation(summary)` 추가. 상한은 §7. ※ task 문서의 "25종" 표기는 실측(27)과 어긋나는 추정치이므로 본 plan은 실측값을 기준으로 한다(스모크 테스트가 개수를 단언하지 않으므로 기능 영향 없음 — 표기만).

### 신규
- `shop-core/src/main/java/com/shop/shop/common/config/OpenApiConfig.java` — `OpenAPI` 빈(info·서버·전역 Bearer `SecurityScheme`) + `GroupedOpenApi` 빈(`pathsToMatch /api/v1/**`). `@ConditionalOnProperty`로 prod-off 게이트.
- `shop-core/src/test/java/com/shop/shop/security/OpenApiDocsSecurityTest.java` — 문서 경로 노출 + 3체인 회귀 + prod 게이트 + 스펙 스모크 통합 테스트(§10).

### 무변경(재사용)
- 모든 Service/Repository/Entity/Flyway 마이그레이션, event-catalog.md, notification 전부, 기존 `@RestControllerAdvice`/`ErrorResponse`(`common/exception/ErrorResponse.java`), 기존 인가 매처·권한 정책, actuator @Order(0) 체인, View 컨트롤러 동작.

> **패키지 배치 근거**: `OpenApiConfig`는 횡단 설정이므로 `common/config`에 둔다. 해당 패키지에는 이미 `AppUrlConfig`, `JacksonKstConfig`, `KafkaTopicConfig`, `RedisConfig`, `RedissonConfig`, `VirtualThreadConfig` 등 동종 `@Configuration`이 존재한다(package-structure-rule "모듈 공통/횡단 코드는 별도 공통 패키지"). 새 도메인 모듈을 만들지 않는다(forbidden-rule).

---

## 3. 의존 추가 (build.gradle 스니펫, 버전 고정 + 사유 주석)

`io.jsonwebtoken:jjwt`(0.12.7)·`org.redisson:redisson`(3.50.0) 주석 형식과 동일하게 "BOM 미관리 → 버전 고정" 사유를 명시한다. webmvc-ui(UI 번들 포함)를 선택한다(webmvc-api는 스펙만 — 대화형 탐색 목적상 탈락).

```gradle
// API 문서화 (Task 062) — springdoc-openapi (webmvc-ui starter).
// /v3/api-docs(OpenAPI 3 JSON·YAML) 자동 생성 + Swagger UI(/swagger-ui.html) 번들.
// Spring Boot BOM 미관리이므로 버전 명시 — jjwt·redisson 선례와 동일 정책. SNAPSHOT/와일드카드 금지.
// 2.8.x = Spring Boot 3.5(Spring 6.2 / MVC) 호환 라인. starter는 자동설정으로
// SpringDocConfiguration·SwaggerUiConfig·정적 리소스 핸들러를 추가하며 기존 시큐리티
// 필터체인을 교체하지 않는다(문서 경로 permit은 §5 전용 체인에서 명시 처리).
implementation 'org.springdoc:springdoc-openapi-starter-webmvc-ui:2.8.9'
```

- **확정 버전: `2.8.9`** (Spring Boot 3.5.x 호환 2.8.x 라인의 안정 버전, 단일 값 고정). 구현 시 `mavenCentral`에서 2.8.x 최신 패치가 resolve되면 그 정확 값으로 주석과 함께 고정하되, **2.8.x 라인을 벗어나지 않는다**(3.x springdoc은 Spring Boot 3.4+ 호환이나 본 plan은 보수적으로 2.8.x 고정 — reviewer가 호환 라인 이탈을 FAIL하지 않도록).
- starter 부작용 확인(redisson-spring-boot-starter 금지 선례 정신): springdoc-webmvc-ui는 `RedisConnectionFactory`·`SecurityFilterChain`·Jackson `ObjectMapper`·Modulith 자동설정을 교체하지 않는다. 추가하는 것은 (a) `/v3/api-docs*` 핸들러, (b) `/swagger-ui/**` 정적 리소스(webjars), (c) OpenAPI 스캐너 빈뿐이다. 풀컨텍스트 그린으로 확인(§10).

---

## 4. application.yml `springdoc.*` 설정 + prod 게이트 (스니펫)

### 4-1. `application.yml` (기본 — non-prod 노출)

`management:` 섹션과 같은 최상위 레벨에 `springdoc:` 섹션을 추가한다. 키는 환경변수 오버라이드 가능하게 한다(yml 선례).

```yaml
# API 문서화 (Task 062) — springdoc-openapi.
# 기본(local/dev): 스펙·UI 노출 ON. prod 프로파일에서 override로 OFF(아래 application-prod.yml).
# enabled 키를 환경변수로도 끌 수 있게 한다(운영 점검·사고 대응 시 즉시 차단).
springdoc:
  api-docs:
    enabled: ${SHOP_CORE_OPENAPI_ENABLED:true}      # /v3/api-docs(JSON·YAML) 생성 ON/OFF
    path: /v3/api-docs                               # 기본값 명시(스펙 경로 SSOT — §5 매처와 일치)
  swagger-ui:
    enabled: ${SHOP_CORE_SWAGGER_UI_ENABLED:true}    # /swagger-ui.html(UI) ON/OFF
    path: /swagger-ui.html                           # 기본값 명시
    # 운영 편의: 태그·메서드 알파벳 정렬(메타데이터만, 동작 무관)
    tags-sorter: alpha
    operations-sorter: method
```

- `springdoc.api-docs.enabled=false` → `/v3/api-docs*` 핸들러 미등록(404). `springdoc.swagger-ui.enabled=false` → Swagger UI 비활성. 두 키가 prod 게이트의 1차 수단이다.
- `path`를 기본값 그대로 명시해 **§5 시큐리티 매처와 application.yml이 동일 경로를 가리킴을 SSOT로 고정**(드리프트 방지).

### 4-2. `application-prod.yml` (prod override — 차단)

```yaml
# prod 표면 최소화 (Task 062) — 스펙/UI 차단. api-authorization-rule 정합(민감 표면 과다 노출 방지).
# enabled=false면 핸들러 자체가 미등록 → 경로 접근 시 404(시큐리티 permit 무관하게 도달 불가).
springdoc:
  api-docs:
    enabled: false
  swagger-ui:
    enabled: false
```

- **게이트 방식 결정**: `@Profile`이 아니라 **springdoc 자체 프로퍼티(`*.enabled`) + 프로파일 yml override**로 끈다.
  - 메모리 선례 `shop-core-tests-no-active-profile-gating`: 풀 `@SpringBootTest`가 active profile 없이(`activeProfiles=[]`) 돌면 `@Profile("...|!test")` 게이트가 역전돼 빈이 의도와 반대로 활성/비활성된다. 따라서 빈 활성/비활성을 `@Profile`에 걸지 않는다.
  - prod 차단은 **프로파일 yml override**(`application-prod.yml`이 `enabled:false`)로 한다. prod에서만 prod 프로파일이 활성이고 enabled=false가 라이브러리 디폴트 true를 명시적으로 덮어 핸들러를 미등록(404)시킨다. local은 기본 yml의 `enabled:true`, 테스트는 §6 주석의 메커니즘(test classpath yml이 main을 가려 프로퍼티 부재 → matchIfMissing + 라이브러리 디폴트 true)을 따른다 — 역전 위험 없음.
  - `OpenApiConfig` 빈 자체의 게이트는 §6의 `@ConditionalOnProperty(... matchIfMissing=true)`로 둔다(아래 근거 참조).

---

## 5. 보안 — 문서 경로 허용 (실제 SecurityConfig 대조)

### 5-1. 핵심 함정 (Task 036과 동일 구조)

`/swagger-ui/**`, `/swagger-ui.html`, `/v3/api-docs/**`, `/v3/api-docs.yaml`는 `/api/v1/**`도 actuator 엔드포인트도 아니므로 **현재 View 체인(@Order(2))의 `anyRequest().authenticated()` + `LoginUrlAuthenticationEntryPoint`에 걸려 미인증 시 302 `/login`** 으로 리다이렉트된다. 명시 permit이 없으면 Swagger UI/스펙에 미인증으로 도달하지 못한다.

### 5-2. 결정: 전용 문서 체인 신설 (View 매처 대신)

**권장안 = 036의 actuator @Order(0) 선례를 본떠 문서 전용 `SecurityFilterChain`을 신설**하고, REST 체인(`/api/v1/**`)보다 먼저 매칭되도록 `@Order`를 배치한다.

| 대안 | 채택 | 근거 |
|---|---|---|
| **A. 전용 문서 체인 신설** (채택) | ✅ | 036과 일관. 문서 경로 인가가 **자기 체인에 격리**되어 다른 두 체인(actuator/REST/View)의 매처·필터·CSRF·EntryPoint를 건드리지 않는다 → 회귀 표면 최소. `securityMatcher`로 문서 경로 범위에만 적용. |
| B. View 체인 상단 permitAll 매처 | ❌ | View 체인은 CSRF(CookieCsrfTokenRepository)·silentRefreshFilter·viewJwtAuthenticationFilter·CookieRequestCache가 얽혀 있어, 매처 추가가 그 필터 흐름·CSRF 회전 로직과 상호작용할 위험. 문서 스펙(GET·읽기 전용)에 불필요한 필터 체인을 통과시킴. 회귀 격리가 약함. |

### 5-3. @Order 재배치 (중요 — 매처 우선순위)

springdoc 경로는 `EndpointRequest`(actuator) 범위 밖이고 `/api/v1/**`도 아니다. 따라서 **문서 체인은 REST 체인(`/api/v1/**`)·View 체인(나머지 전체)보다 먼저 매칭되어야** 한다. 현재 순서는 actuator(0) / REST(1) / View(2)다. 문서 체인을 끼워넣고 아래로 한 칸씩 민다.

- `actuatorChain` → `@Order(0)` (무변경, `EndpointRequest` 매처)
- **`openApiDocsChain` → `@Order(1)` (신규)** — 문서 경로 `securityMatcher`
- `restChain` → `@Order(2)` (기존 @Order(1)에서 +1, **매처·필터·authorize 규칙은 전부 무변경**, 애노테이션 값만 변경)
- `viewChain` → `@Order(3)` (기존 @Order(2)에서 +1, **매처 없음=나머지 전체, 내용 전부 무변경**, 애노테이션 값만 변경)

> @Order 값 변경은 **상대 순서를 보존**하므로 동작 무변경이다(actuator < docs < REST < View). docs 체인은 actuator·REST·View 어느 매처와도 겹치지 않으므로(문서 경로는 셋 다 매칭 안 함) 끼워넣어도 기존 경로 라우팅이 바뀌지 않는다. 다만 reviewer가 "REST/View 체인 무변경"을 검증할 수 있도록 **diff는 @Order 숫자 1자만 바뀜**을 명시한다.

### 5-4. 신규 문서 체인 코드 스니펫

springdoc 경로 상수는 라이브러리가 공개 상수로 제공하지 않으므로(버전별 상이), **명시적 Ant 패턴 문자열**로 매처를 구성한다. application.yml의 `path`(§4)와 동일 경로를 SSOT로 맞춘다.

```java
// import 추가:
//   (org.springframework.core.annotation.Order, HttpSecurity, SecurityFilterChain,
//    SessionCreationPolicy 는 이미 SecurityConfig에 존재)

/**
 * API 문서(OpenAPI 스펙 + Swagger UI) 전용 보안 체인 (@Order(1) — REST/View 체인보다 먼저 매칭).
 *
 * <p>springdoc 경로(/v3/api-docs**, /swagger-ui**)는 /api/v1/** 도 actuator 엔드포인트도
 * 아니므로 지정 매처가 없으면 View 체인(@Order)의 anyRequest().authenticated()에 걸려
 * 302 /login으로 리다이렉트된다(Task 036 actuator와 동일 함정). 이 전용 체인이 가장 먼저
 * 문서 경로만 매칭해 permitAll로 도달성을 보장한다. 다른 세 체인은 매처/필터 무변경.
 *
 * <p>noop 안전성: springdoc.api-docs.enabled / swagger-ui.enabled=false(prod)면 핸들러 자체가
 * 미등록되어 경로가 404가 되므로, 이 체인의 permitAll이 prod에서 표면을 열지 않는다(404 우선).
 *
 * <p>CSRF: 스펙·UI는 GET 읽기 전용이라 CSRF 비대상. Swagger UI "Try it out"의 상태 변경
 * 호출은 대상 경로가 /api/v1/**라 REST 체인(@Order, CSRF off + Bearer)이 처리한다 —
 * 이 체인에 추가 CSRF 예외 불필요.
 */
@Bean
@Order(1)
public SecurityFilterChain openApiDocsChain(HttpSecurity http) throws Exception {
    http
        .securityMatcher(
                "/v3/api-docs/**",      // 그룹 스펙: /v3/api-docs/{group}
                "/v3/api-docs",         // 기본 스펙 JSON
                "/v3/api-docs.yaml",    // YAML
                "/swagger-ui/**",       // Swagger UI 정적 리소스(webjars)
                "/swagger-ui.html"      // UI 진입점(→ /swagger-ui/index.html 리다이렉트)
        )
        .authorizeHttpRequests(auth -> auth.anyRequest().permitAll())
        .csrf(csrf -> csrf.disable())                          // 읽기 전용 + 정적 — 폼/브라우저 CSRF 대상 아님
        .sessionManagement(session ->
                session.sessionCreationPolicy(SessionCreationPolicy.STATELESS));  // 세션 미생성(JSESSIONID 없음)

    return http.build();
}
```

- `securityMatcher(String...)`는 기존 REST 체인의 `securityMatcher("/api/v1/**")`와 동일한 메서드를 쓴다(별도 `AntPathRequestMatcher` import 불필요 — Spring Security가 문자열을 mvc 매처로 처리). 새 import는 사실상 없음(전부 기존에 존재).
- **prod 안전망 2중화**: ① springdoc `enabled=false`로 핸들러 미등록(404) + ② 이 체인은 단지 permit일 뿐(핸들러 없으면 매칭돼도 404). 즉 prod에서 permitAll이라도 표면이 열리지 않는다.

### 5-5. 다른 2(3)체인 무변경 보장

- **actuator 체인(@Order(0))**: 코드 한 줄도 안 건드림.
- **REST 체인**: `@Order(1)` → `@Order(2)` 숫자만. `securityMatcher("/api/v1/**")`·전체 authorize 매처·`apiJwtAuthenticationFilter`·`RestAuthenticationEntryPoint`·`RestAccessDeniedHandler` 전부 무변경.
- **View 체인**: `@Order(2)` → `@Order(3)` 숫자만. 매처·CSRF·필터·EntryPoint 전부 무변경.

---

## 6. OpenAPI 설정 빈 (OpenApiConfig 스니펫)

`common/config/OpenApiConfig.java`. (a) `OpenAPI` 메타·전역 Bearer `SecurityScheme`, (b) `GroupedOpenApi`로 `/api/v1/**`만 스캔(View @Controller 제외). 빈은 `@ConditionalOnProperty`로 게이트한다.

```java
package com.shop.shop.common.config;

import io.swagger.v3.oas.models.Components;
import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import io.swagger.v3.oas.models.security.SecurityRequirement;
import io.swagger.v3.oas.models.security.SecurityScheme;
import org.springdoc.core.models.GroupedOpenApi;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * OpenAPI(springdoc) 설정 — info·전역 JWT Bearer SecurityScheme + /api/v1/** 그룹 스캔.
 *
 * <p>게이트(@ConditionalOnProperty): springdoc.api-docs.enabled 프로퍼티 기준. matchIfMissing=true
 * 이므로 프로퍼티가 부재하면 빈을 등록한다. prod는 application-prod.yml이 enabled=false를
 * 명시하므로 빈 미등록 + 핸들러 미등록.
 * (메모리 선례 shop-core-tests-no-active-profile-gating: 게이트를 @Profile에 걸지 않고 프로퍼티로 둔다.)
 *
 * <p>테스트에서 빈이 등록되는 실제 메커니즘(코드 사실): 풀 @SpringBootTest는
 * src/test/resources/application.yml이 main application.yml을 통째로 가린다
 * (ActuatorSecurityTest.java 주석이 명문화한 동일 shadowing — management 노출도 같은 이유로
 * @SpringBootTest(properties=...)로 명시 주입). 따라서 테스트 classpath에는 §4-1의 springdoc 섹션이
 * 존재하지 않는다. enabled 프로퍼티가 부재(=missing)하므로 (1) matchIfMissing=true가 이 빈을 등록하고,
 * (2) springdoc 라이브러리 자체 기본값(api-docs.enabled/swagger-ui.enabled 미설정 시 true)이
 * 핸들러를 활성화한다. 즉 "main yml 기본 true 상속"이 아니라 "프로퍼티 부재 → matchIfMissing +
 * 라이브러리 디폴트 true"가 스펙 스모크 테스트를 가능케 하는 진짜 인과다.
 * (스모크 테스트는 디폴트에 암묵 의존하지 않도록 §10-1에서 enabled=true를 명시 주입한다.)
 */
@Configuration
@ConditionalOnProperty(prefix = "springdoc.api-docs", name = "enabled", matchIfMissing = true)
public class OpenApiConfig {

    private static final String BEARER_SCHEME = "bearer-jwt";

    /**
     * 전역 메타 + JWT Bearer 보안 스키마.
     * 전역 SecurityRequirement(addSecurityItem)로 Swagger UI "Authorize"가 노출된다.
     * 공개 엔드포인트는 컨트롤러에서 @SecurityRequirements(빈 배열)로 요구를 비운다(§7).
     */
    @Bean
    public OpenAPI shopCoreOpenAPI() {
        return new OpenAPI()
                .info(new Info()
                        .title("shop-core API")
                        .version("v1")
                        .description("shop-core REST API (/api/v1/**). 인증: JWT Bearer (POST /api/v1/auth/login 발급)."))
                // 서버는 상대 경로 — 배포 호스트/포트에 무관(역프록시 뒤에서도 동작)
                .addServersItem(new io.swagger.v3.oas.models.servers.Server().url("/"))
                .components(new Components()
                        .addSecuritySchemes(BEARER_SCHEME, new SecurityScheme()
                                .type(SecurityScheme.Type.HTTP)
                                .scheme("bearer")
                                .bearerFormat("JWT")
                                .description("Authorization: Bearer <access_token>")))
                // 전역 보안 요구 — 보호 엔드포인트 기본값. 공개 엔드포인트는 핸들러에서 해제(§7).
                .addSecurityItem(new SecurityRequirement().addList(BEARER_SCHEME));
    }

    /**
     * /api/v1/** 만 문서화 — View(@Controller HTML) 핸들러를 스펙에서 제외.
     * (springdoc 기본은 모든 @Controller/@RestController 스캔이므로 명시 제한 필수.)
     */
    @Bean
    public GroupedOpenApi apiV1Group() {
        return GroupedOpenApi.builder()
                .group("api-v1")
                .pathsToMatch("/api/v1/**")
                .build();
    }
}
```

- **그룹핑 결정 — `GroupedOpenApi`(pathsToMatch) 채택, `packagesToScan` 대안 탈락**:

  | 방식 | 채택 | 근거 |
  |---|---|---|
  | `pathsToMatch("/api/v1/**")` | ✅ | 인가 경계(`/api/v1/**`)와 **동일 기준**으로 1:1 정렬. View 컨트롤러가 어느 패키지에 있든 경로로 확실히 배제. SecurityConfig REST 체인 매처와 같은 표현 → 일관·검증 용이. |
  | `packagesToScan(...)` | ❌ | REST/View 컨트롤러가 도메인 모듈별로 흩어져 패키지 목록 열거가 장황·취약. View가 같은 패키지에 섞이면 누수. 경로 기준이 더 견고. |

- **공개 vs 보호 표시**: 전역 `addSecurityItem`으로 기본 Bearer 요구. 실제 SecurityConfig REST 체인에서 permitAll인 **공개 엔드포인트**(POST `/api/v1/auth/login`·`/auth/refresh`·`/auth/password-reset/**`·`/members/signup`, GET `/api/v1/categories`·`/api/v1/products`·`/api/v1/products/*`·`/api/v1/products/*/reviews`)는 §7에서 핸들러/컨트롤러에 `@SecurityRequirements`(빈)로 요구를 해제한다. 그 외는 전역 Bearer 요구를 상속.
- `ErrorResponse` 스키마는 springdoc이 `@RestControllerAdvice`/핸들러 반환 타입을 통해 자동 등록하거나, 대표 응답에 노출된다. **전수 `@ApiResponse(content=ErrorResponse)` 매핑은 범위 밖**(§7 상한). 최소한 `ErrorResponse` record가 components.schemas에 나타나도록 §7에서 대표 보호 컨트롤러에 한 번 참조(아래 상한 참조).

---

## 7. 컨트롤러/DTO 애노테이션 (경량 1차 패스 범위·상한)

**과설계 경계(reviewer FAIL 대비) — 1차 패스는 아래만. 그 이상은 명시적 비범위.**

### 범위 (한다)
- **컨트롤러별 `@Tag(name=...)`**: 도메인 그룹 라벨(member/product/order/payment/cart/review/coupon/admin/seller 등). 컨트롤러 클래스에 1개씩.
- **주요 엔드포인트 `@Operation(summary=...)`**: 각 컨트롤러의 대표(핵심) 핸들러에 한 줄 요약. **모든** 핸들러 전수가 아니라 핵심 위주.
- **공개 엔드포인트 보안 해제**: 위 §6 공개 목록 핸들러(또는 그 컨트롤러)에 `@io.swagger.v3.oas.annotations.security.SecurityRequirements`(빈)로 Bearer 요구 제거 → 스펙이 실제 정책과 일치.
- **`ErrorResponse` 스키마 노출(최소 1회)**: 대표 보호 컨트롤러 핸들러 1곳에 한해 `@ApiResponse(responseCode="401", content=@Content(schema=@Schema(implementation=ErrorResponse.class)))` 정도로 ErrorResponse를 components에 끌어올린다(스펙에 공통 에러 스키마 존재 보장 — Acceptance/§10 스모크용). **전 핸들러 전수가 아니라 1회 노출.**

### 비범위 (하지 않는다 — 후속 점진)
- 엔드포인트마다 전 응답코드(`@ApiResponse` 200/400/401/403/404/409 전수) 완비.
- 전 파라미터 `@Parameter`·전 필드 `@Schema(description)` 주석.
- DTO/record 필드별 예시(`example`)·설명 전수.
- 요청/응답 예시(`examples`) 작성.
- API 버저닝·경로 변경·클라이언트 SDK 생성.

> Entity 직접 노출 금지(forbidden-rule) 유지 — 스키마는 기존 응답 DTO/record에서만 생성된다. 컨트롤러 시그니처가 이미 record 반환이므로 별도 작업 불필요.

---

## 8. 데이터 흐름

```
[기동/non-prod]
 springdoc autoconfig 등록 → OpenApiConfig(OpenAPI 빈 + GroupedOpenApi /api/v1/**)
        │
 (1) GET /swagger-ui.html  ── openApiDocsChain(@Order(1)) permitAll ──▶ Swagger UI 정적 리소스 200
 (2) GET /v3/api-docs       ── openApiDocsChain permitAll ──▶ springdoc가 /api/v1/** 핸들러·DTO 스캔
                                  → OpenAPI 3 JSON 생성(info·servers·components.securitySchemes[bearer-jwt]·paths)
 (3) Swagger UI "Authorize" 입력(Bearer <access_token>)  → UI가 이후 호출에 Authorization 헤더 부착
 (4) "Try it out" POST/GET /api/v1/...  ── restChain(@Order(2)) ──▶
                                  apiJwtAuthenticationFilter(Bearer 헤더) → principal=userId(Long)
                                  → 권한 매처(hasRole 등) 통과 시 200 / 미인증 401 JSON / 권한부족 403 JSON
[prod]
 springdoc.api-docs.enabled=false / swagger-ui.enabled=false (application-prod.yml)
   → /v3/api-docs*·/swagger-ui* 핸들러 미등록 → 404 (permit 체인과 무관하게 도달 불가)
   → OpenApiConfig 빈 @ConditionalOnProperty(false) → 미등록
```

핵심: 문서 경로 접근은 신규 docs 체인이, 실제 API 호출은 **기존 REST 체인이 그대로** 처리한다. UI 노출이 곧 인가 우회가 아니다(REST 체인 Bearer·권한 매처 불변).

---

## 9. 예외 처리 전략

- **런타임 동작 무변경**: 문서화는 메타데이터 추가만. 기존 `@RestControllerAdvice`(`ErrorResponse` 변환)·`RestAuthenticationEntryPoint`(401 JSON)·`RestAccessDeniedHandler`(403 JSON)·View `LoginUrlAuthenticationEntryPoint`(302) 전부 무변경 → 에러 응답 계약(error-response-rule) 회귀 0.
- **스펙 표현**: 공통 `ErrorResponse` 스키마를 components에 1회 노출(§7 상한)해 스펙이 에러 형태를 드러내되, 전 엔드포인트 전 상태코드 매핑은 후속. 401/403은 시큐리티 레이어 처리이므로 springdoc 자동생성으로는 일부만 추론될 수 있음 — **자동생성 신뢰, 전수 단언 금지**.
- docs 체인 추가가 REST/View EntryPoint·DeniedHandler 동작을 바꾸지 않음(§5 격리).

---

## 10. 검증 (슬라이스/통합 테스트)

> testing-rule + verification-gate-rule. 브라우저 E2E 불필요(화면 기능 아님 — MockMvc로 충분). **배선은 기존 `SecurityConfigTest`/`ActuatorSecurityTest` 패턴을 그대로 계승**: `@SpringBootTest` + `@AutoConfigureMockMvc` + `@ActiveProfiles("test")` + `@Import(FakeRefreshTokenStore.class)` + `@MockSharedRepositories` + 개별 `@MockitoBean`(Member/Product/Cart/Inventory/Order/Payment/Review/Coupon Repository 전부 + MemberUserDetailsService). **새 mock 전략 발명 금지** — `ActuatorSecurityTest`의 @MockitoBean 목록을 그대로 복제한다.

신규 테스트: `OpenApiDocsSecurityTest`.

> **노출 프로퍼티 명시 주입(결정성)**: 테스트 classpath의 `src/test/resources/application.yml`은 main `application.yml`을 통째로 가린다(ActuatorSecurityTest.java 주석이 명문화한 동일 shadowing). 따라서 테스트에는 §4-1의 `springdoc:` 섹션이 **부재**하며, 문서 노출은 본래 `@ConditionalOnProperty(matchIfMissing=true)` + springdoc 라이브러리 디폴트 true에 의존한다. 이 암묵 의존을 끊기 위해, ActuatorSecurityTest가 management 노출을 `@SpringBootTest(properties=...)`로 명시 주입한 것과 **동일 패턴**으로 노출 테스트(아래 (1)·(2)·(4))에는 `@SpringBootTest(properties={"springdoc.api-docs.enabled=true","springdoc.swagger-ui.enabled=true"})`를 **명시 주입**한다. prod 게이트 테스트(아래 (3))는 동일 키를 `false`로 주입해 라이브러리 디폴트 true를 명시 false로 덮어 404를 재현한다.

### (1) 문서 경로 노출(non-prod) — 302 /login 아님
- 미인증 `GET /v3/api-docs` → **200** (JSON). 302 아님.
- 미인증 `GET /swagger-ui.html` → **200 또는 3xx→/swagger-ui/index.html**(springdoc UI 진입은 index로 리다이렉트할 수 있음 — `/login` 으로 가지 않음을 단언. `is2xxSuccessful() OR redirectedUrlPattern("**/swagger-ui/**")`, 단 `**/login` 이 아님).
- ※ 기동 후 수동 확인(non-test): `GET /v3/api-docs`가 `/api/v1/**` 경로 다수 포함, `GET /swagger-ui.html` UI 렌더.

### (2) 3체인 회귀 가드 (docs 체인이 다른 체인을 깨지 않음)
- 미인증 `GET /api/v1/orders` → **401** (REST 체인 무변경).
- 미인증 `GET /` (보호 View 경로) → **302 `**/login`** (View 체인 무변경).
- 미인증 `GET /actuator/health/liveness` → **200** (actuator 체인 무변경).

### (3) prod 게이트 차단 (프로퍼티 override)
- 별도 테스트 메서드 또는 별도 `@SpringBootTest(properties={"springdoc.api-docs.enabled=false","springdoc.swagger-ui.enabled=false"})` 중첩 클래스: 미인증 `GET /v3/api-docs` → **404**(핸들러 미등록), `GET /swagger-ui.html` → **404**. (prod yml 대신 properties로 동등 조건 재현 — 메모리 선례에 맞춰 @Profile 미사용.)
- **인과 주의**: 이 테스트는 "main yml 기본 true를 덮는" 것이 아니다. 테스트 classpath에는 §4-1 springdoc 섹션이 부재하므로 기본 상태는 **springdoc 라이브러리 디폴트 true**다. 여기에 `enabled=false`를 명시 주입해 라이브러리 디폴트를 덮으면, `@ConditionalOnProperty(matchIfMissing=true)`가 false로 평가되어 `OpenApiConfig` 빈이 미등록되고 springdoc 핸들러도 미등록되어 404가 된다 — 이것이 prod(application-prod.yml의 enabled=false)와 동등한 조건이다.

### (4) 스펙 내용 스모크 (전수 아님 — 핵심 표면)
- `GET /v3/api-docs` JSON 본문에:
  - (a) 대표 **공개** 경로 존재: `/api/v1/products`, `/api/v1/auth/login`.
  - (b) 대표 **보호** 경로 존재: `/api/v1/orders`.
  - (c) **보안 스키마** 존재: `components.securitySchemes.bearer-jwt`(type=http, scheme=bearer).
  - (d) **View HTML 경로 부재**: 예 `/login`, `/cart`(@Controller HTML) 가 paths에 없음 — GroupedOpenApi 격리 확인.
  - (jsonPath 단언. springdoc 자동생성을 신뢰하므로 핵심 키 존재/부재만.)

### (5) 동적 게이트 (메인 최종)
- 풀컨텍스트 `./gradlew test` 그린 — springdoc 도입이 기존 컨텍스트 로드·슬라이스·Modulith/ArchUnit을 깨지 않음(verification-gate-rule §2: **메인이 자기 눈으로 `BUILD SUCCESSFUL` 확인**). `OpenApiConfig`는 새 Repository 의존을 추가하지 않으므로(§4 게이트는 프로퍼티 기반) 기존 @MockSharedRepositories 배선으로 컨텍스트 로드 가능 — 단, 풀스위트로 실증.
- 기존 `*SecurityTest`(`SecurityConfigTest`·`ActuatorSecurityTest`) 전수 그린 — @Order 재배치가 회귀 없음을 실증(특히 `SecurityConfigTest`의 401/302 단언이 그대로 통과해야 함).

---

## 11. 트레이드오프

- **전용 docs 체인 vs View 매처**: 전용 체인 채택. 장점 = 회귀 격리(다른 3체인 무변경, @Order 숫자만), 036과 일관. 비용 = SecurityConfig에 @Bean 1개 + 기존 2체인 @Order 값 +1(상대 순서 보존이라 동작 무변경). View 매처는 CSRF·silentRefresh·CookieRequestCache 흐름과 상호작용 위험이 커 탈락.
- **UI 노출 vs prod 차단**: non-prod 노출(대화형 탐색 가치) + prod 차단(표면 최소화). 2중 안전망(springdoc enabled=false로 핸들러 미등록 + permit 체인은 404로 무력). UI가 곧 인가 우회는 아님(REST 체인 Bearer 불변)이나 prod 보수적 차단.
- **경량 애노테이션 vs 전수 문서화**: 1차 패스는 `@Tag`+핵심 `@Operation`+공개 보안 해제+ErrorResponse 1회만. 전수 `@ApiResponse`/`@Parameter`는 후속(over-spec 회피, reviewer FAIL 방지). springdoc 자동생성(Bean Validation·Jackson·record)을 신뢰.
- **버전 고정 vs BOM**: springdoc은 Spring Boot BOM 미관리 → jjwt·redisson처럼 단일 버전(2.8.9) 고정. SNAPSHOT/와일드카드 금지. 비용 = Spring Boot 업그레이드 시 springdoc 호환 버전 수동 동기화(주석에 호환 라인 명시로 완화).

---

## 12. plan 확정 결정 (구현 전 고정)

1. **의존**: `org.springdoc:springdoc-openapi-starter-webmvc-ui:2.8.9` (버전 고정, BOM 미관리 사유 주석. resolve 시 2.8.x 라인 최신 패치면 그 값으로 고정, 라인 이탈 금지). UI 포함 starter(webmvc-api 아님).
2. **시큐리티**: 전용 문서 체인 `openApiDocsChain` 신설 `@Order(1)`. 기존 actuator(0) 유지, REST(1→2)·View(2→3) @Order 값만 +1(매처·필터·동작 무변경). `securityMatcher`로 `/v3/api-docs**`·`/swagger-ui**` 범위만 permitAll + CSRF off + STATELESS.
3. **prod 게이트**: `@Profile` 미사용. `springdoc.api-docs.enabled`/`swagger-ui.enabled` 프로퍼티 + `application-prod.yml` override(false). 기본 yml은 true(환경변수 오버라이드 가능). `OpenApiConfig`는 `@ConditionalOnProperty(springdoc.api-docs.enabled, matchIfMissing=true)`.
4. **그룹핑**: `GroupedOpenApi.pathsToMatch("/api/v1/**")`. packagesToScan 탈락.
5. **OpenAPI 빈**: info(title=shop-core API, version=v1, description) + 서버 상대경로(`/`) + 전역 JWT Bearer SecurityScheme(`bearer-jwt`, type=http/scheme=bearer/bearerFormat=JWT) + 전역 SecurityRequirement. 공개 엔드포인트는 컨트롤러 `@SecurityRequirements`(빈)로 해제. 배치 = `common/config/OpenApiConfig.java`.
6. **애노테이션 상한**: 컨트롤러 `@Tag` + 핵심 `@Operation(summary)` + 공개 핸들러 보안 해제 + ErrorResponse 1회 노출. 전수 `@ApiResponse`/`@Parameter`/필드 예시는 비범위.

---

## 13. 리뷰 관점 (reviewer 체크리스트)

- **의존**: 버전 하드코딩(2.8.x 단일) + BOM 미관리 사유 주석 존재. SNAPSHOT/와일드카드 없음. webmvc-ui(UI 포함).
- **시큐리티 격리**: `openApiDocsChain`이 `@Order(1)`로 REST/View보다 먼저 매칭되고 `securityMatcher`로 **문서 경로 범위에만** 적용. actuator @Order(0) 무변경. REST/View 체인은 **@Order 숫자만 +1**, securityMatcher·authorize 매처·필터·CSRF·EntryPoint 전부 무변경(diff가 숫자 1자인지 확인).
- **prod 게이트**: `@Profile` 미사용(메모리 선례 역전 회피). 프로퍼티 + prod yml override + `@ConditionalOnProperty(matchIfMissing=true)`. 기본 yml은 노출 true.
- **그룹 범위**: `GroupedOpenApi.pathsToMatch("/api/v1/**")` — View(@Controller HTML) 경로가 스펙에 누수되지 않음(테스트 (4d)로 단언).
- **OpenAPI 빈**: 전역 Bearer SecurityScheme(http/bearer/JWT) + 서버 상대경로. 공개 엔드포인트 보안 해제(`@SecurityRequirements`)가 실제 SecurityConfig permitAll 목록과 일치.
- **애노테이션 과설계 없음**: `@Tag`+핵심 `@Operation`+공개 해제+ErrorResponse 1회 상한 준수. 전수 `@ApiResponse`/`@Parameter` 미작성(over-spec 아님).
- **무변경**: 도메인 로직·REST 경로/시그니처/응답 본문·상태코드·인가 매처·View·Flyway·event-catalog·notification 무변경. Entity 비노출(스키마는 record/DTO만).
- **테스트 배선**: `ActuatorSecurityTest`의 @MockSharedRepositories + @MockitoBean 목록을 그대로 계승(새 전략 발명 없음). 문서 200 + 3체인 회귀(401/302/200) + prod 404 + 스펙 스모크 단언 포함.
- **동적 게이트**: 메인이 풀 `./gradlew test` `BUILD SUCCESSFUL` + 기존 `*SecurityTest` 그린을 자기 눈으로 확인(verification-gate-rule §2). reviewer PASS만으로 완료 인정 금지.

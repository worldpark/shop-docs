# 026. notification RedisConfig `@ConditionalOnBean` 선제 정리 (redundant 빈 + P1 안티패턴 제거)

> 출처: backlog `docs/backlog/backend/008-backend-notification-redisconfig-conditional-cleanup.md` 승격. 근거: `docs/review-patterns.md` **P1**(테스트 더블이 운영 배선을 가려 생긴 거짓 통과 + `@ConditionalOnBean` 오용) — line 48이 이 `RedisConfig` 케이스를 명시적으로 지목.

## Target
notification

---

## Goal
`notification/.../common/config/RedisConfig.java`의 **redundant 커스텀 빈 + P1 안티패턴**(사용자 `@Bean`에 `@ConditionalOnBean` 적용)을 제거한다. 커스텀 `stringRedisTemplate` `@Bean` + `@ConditionalOnBean(RedisConnectionFactory)`를 삭제하고, **Spring Boot `RedisAutoConfiguration`이 이미 제공하는 `StringRedisTemplate`에 위임**한다. 동기는 두 가지다: (1) **redundant 제거** — Boot이 `@ConditionalOnMissingBean`으로 동일 `StringRedisTemplate`을 이미 제공하므로 커스텀 빈은 불필요. (2) **P1 안티패턴 선제 제거** — 순서 취약한 `@ConditionalOnBean`을, dedup(009)이 `StringRedisTemplate` 주입처를 만들기 **전에** 정리해 `@ConditionalOnBean` 체인이 형성될 여지를 차단.

> 기능 변경이 아니다. 현재 `StringRedisTemplate` 주입처가 0건이고, 커스텀 빈이 순서로 skip돼도 **Boot 폴백(`@ConditionalOnMissingBean`)이 채워 넣어 현 시점 기동 실패는 없다** — 런타임 영향 없는 **위생(hygiene) 정리**다.

## Context
- **P1 안티패턴(`docs/review-patterns.md`)**
  - `@ConditionalOnBean`은 **평가 순서에 민감**하며 Spring 공식 문서가 "오토컨피규레이션 클래스에서만 쓰라"고 명시한다(P1 §부수 원인). 사용자 `@Bean`/`@Component`에 붙이면, 해당 설정이 의존 오토컨피그보다 먼저 처리될 때 조건이 false로 평가돼 **빈이 조용히 누락**된다.
  - 선례: shop-core `RedisRefreshTokenStore`가 `@ConditionalOnBean`으로 운영 기동 실패(P1 본문). notification에서도 `JpaAuditingConfig` 동류 패턴이 023 e2e에서 실 기동 결함(이벤트 유실)으로 실증돼 `@Profile("!test")`로 수정된 바 있다.
  - P1 처방(line 40·36): "`@ConditionalOnBean`을 제거하고, **오토컨피그가 이미 제공하는 빈이면 커스텀 빈을 제거하고 위임**하라."
- **현 `RedisConfig` 상태(코드 확인)**
  - `@Configuration @EnableConfigurationProperties(RedisProperties.class)` + `@Bean @ConditionalOnBean(RedisConnectionFactory.class) StringRedisTemplate stringRedisTemplate(...)`.
  - **`StringRedisTemplate`/`RedisTemplate` 주입처 0건**(grep 확인) — 현재는 무해. dedup 실제 적용은 009.
  - **Boot `RedisAutoConfiguration`이 이미 `stringRedisTemplate` 빈을 자동 등록**한다(`RedisConnectionFactory` 존재 시, `@ConditionalOnMissingBean`). 즉 커스텀 빈은 **redundant**.
  - test 프로파일(`src/test/resources/application.yml`·`application-kafkatest.yml`)이 **`RedisAutoConfiguration`을 자동설정 제외** → `RedisConnectionFactory` 빈이 없어 `@ConditionalOnBean`이 false → 커스텀 빈 미생성으로 현재 테스트가 비파괴.
  - **현 위험의 정확한 범위**: 운영(Redis 활성)에서 커스텀 빈이 순서로 skip돼도 Boot의 `@ConditionalOnMissingBean stringRedisTemplate`이 채워 넣으므로 **`StringRedisTemplate` 단독 부재로 인한 기동 실패는 발생하지 않는다.** 즉 RedisConfig의 `@ConditionalOnBean`은 **현재 무해**하다. 진짜 위험은 단독 빈이 아니라 **P1 연쇄**(아래)다.
- **왜 지금(선제)**: P1 기동 실패는 `@ConditionalOnBean` **체인**에서 발생한다(P1 본문 shop-core `RefreshTokenStore`: `@ConditionalOnBean` 커스텀 빈 → `@ConditionalOnBean(그 빈)` 컴포넌트 → 평가 순서로 둘 다 skip → 주입처 NoSuchBean). notification은 아직 하류가 없어 무해하나, **009(dedup)가 `@ConditionalOnBean(StringRedisTemplate)` 류 컴포넌트를 추가하면 연쇄가 실재화**된다. 단독 빈을 지금 정리하면(+ 009는 plain 생성자 주입 사용) 연쇄 자체가 성립하지 않는다 — 주입처 0건인 지금이 무위험 정리 시점.

## Authorization / 공개 표면
> REST/View 없음. api-authorization-rule 해당 없음. 외부 표면 변화 없음(빈 배선 정리만).

## Requirements
- **커스텀 `stringRedisTemplate` 빈 제거 + 위임**
  - `RedisConfig`에서 `@Bean @ConditionalOnBean(RedisConnectionFactory) StringRedisTemplate stringRedisTemplate(...)` 메서드와 미사용 import(`ConditionalOnBean`, `RedisConnectionFactory`, `StringRedisTemplate`, `Bean`)를 **삭제**한다.
  - `@Configuration` + `@EnableConfigurationProperties(RedisProperties.class)`는 **유지**(009 대기용 properties 활성 — `MailConfig` 패턴과 동일). `RedisConfig`는 properties 활성 전용 설정으로 남는다.
  - `RedisConnectionFactory`(Lettuce 자동설정 기본)는 **재정의하지 않는다**(그대로). Redis 활성 환경에선 Boot가 `StringRedisTemplate`을 자동 제공하므로 향후 dedup(009)이 그 빈을 주입한다.
- **009 의존 가정 고정 (운영 배선 가림 RED 가드가 아님 — 정직화)**
  - 커스텀 빈을 삭제하면 `StringRedisTemplate`을 제공하는 주체는 **순수 Spring Boot**다. 따라서 테스트 목적은 testing-rule §운영 배선 검증이 말하는 "우리 운영 구현체 가림 방지 RED 가드"가 **아니다**(가릴 우리 빈이 없음). 대신 **009(dedup)가 의존할 가정 — `RedisAutoConfiguration` 활성 시 `StringRedisTemplate`이 주입 가능 — 을 핀으로 고정**한다(프레임워크 동작/Boot 버전업으로 그 가정이 깨지면 RED 신호). `RedisAutoConfiguration`이 활성인 **격리 컨텍스트**에서 `StringRedisTemplate` 빈 존재를 단언한다. 실 Redis 브로커 없이(Lettuce 지연 연결: 빈 생성만, 연결은 첫 명령 시) 검증한다.
  - 우리 코드에 대한 실질 회귀 가드는 별도로 **"`RedisConfig`에 `@ConditionalOnBean`/커스텀 `@Bean`이 없음"**(아래 Test 회귀)으로 둔다 — 안티패턴 재유입 시 신호.
- **테스트 프로파일 제외 정책 재점검(결론 문서화)**
  - 현 test 프로파일의 `RedisAutoConfiguration` 제외는 **본 정리 후에도 유지**한다(커스텀 운영 빈이 사라져 "가려질 운영 빈"이 없으므로 거짓 통과 위험이 해소됨 — testing-rule). 단, **009(dedup)가 `StringRedisTemplate` 주입 컴포넌트를 추가할 때는** 그 컴포넌트의 운영 배선(Boot 자동 `StringRedisTemplate` 주입)을 별도 검증해야 함을 009로 명시 이월한다(본 Task에서 제외 정책 자체는 변경하지 않음 — 기존 테스트 회귀 금지).

## Constraints
- **기능/동작 변경 없음**: 빈 배선 정리만. dedup 조회/기록 적용은 009. 런타임 거동 불변(주입처 0건).
- **`RedisProperties` + `@EnableConfigurationProperties` 유지**: 009 대기용 설정 기반(주입처 없어도 등록 유지). 삭제 금지.
- **test 자동설정 제외 정책 무변경**: `RedisAutoConfiguration`/`RedisRepositoriesAutoConfiguration` 제외를 본 Task에서 바꾸지 않는다(기존 005/023/024/025 테스트 회귀 금지). 재점검 결론만 문서화.
- **범위 밖**: Redis dedup 실제 적용(009), shop-core `RedisConfig`/다른 `@ConditionalOnBean` 사용처(별개 — 본 Task는 notification `RedisConfig` 한정), `RedisConnectionFactory` 커스터마이징.
- **verification-gate**: 풀컨텍스트 `test` 그린 유지(외부 Redis 미접속).

## Files
> notification 단일 레포.
- (수정) `notification/src/main/java/com/shop/notification/common/config/RedisConfig.java` — 커스텀 `stringRedisTemplate` `@Bean` + `@ConditionalOnBean` + 미사용 import 제거. `@Configuration`+`@EnableConfigurationProperties(RedisProperties.class)`만 유지. 클래스 Javadoc을 "위임" 취지로 정정.
- (신규) 009 의존 가정 고정 테스트(예: `notification/src/test/java/com/shop/notification/common/config/RedisTemplateWiringTest.java`) — `ApplicationContextRunner` + `AutoConfigurations.of(RedisAutoConfiguration.class)`로 `StringRedisTemplate` 빈 존재 단언(실 브로커 미접속, Boot 제공 가정 핀). `MailPropertiesTest`/`RedisPropertiesTest`의 ApplicationContextRunner 패턴 계승.
- (변경 없음) `RedisProperties.java`(유지), `src/test/resources/application.yml`/`application-kafkatest.yml`(제외 유지), `src/main/resources/application.yml`(`notification.redis.*` 설정 유지).

## Acceptance Criteria
- `RedisConfig`에 **`@ConditionalOnBean` 및 커스텀 `stringRedisTemplate` 빈이 없다**(P1 안티패턴 제거). `@EnableConfigurationProperties(RedisProperties.class)`는 유지.
- `RedisAutoConfiguration` 활성 격리 컨텍스트에서 **`StringRedisTemplate` 빈이 Boot 자동설정으로 존재(주입 가능)** 함이 테스트로 **고정**된다(009 의존 가정 핀 — 우리 빈 가림 RED 가드가 아니라 프레임워크 제공 가정 고정). 실질 회귀 가드는 `RedisConfig`에 `@ConditionalOnBean`/커스텀 `@Bean` 부재.
- 풀컨텍스트 `test`(RedisAutoConfiguration 제외) 그린 — **기능/회귀 영향 0**(주입처 없음, 005/023/024/025 무영향).
- review-patterns **P1 체크리스트**("사용자 `@Component`/`@Bean`에 `@ConditionalOnBean`이 붙어 있지 않은가") 충족.
- 이벤트 계약/마이그레이션/다른 설정 무변경.

## Test
- **009 의존 가정 고정(ApplicationContextRunner)**: `RedisAutoConfiguration`을 포함한 격리 컨텍스트 + `RedisConfig`를 로드 → `assertThat(context).hasSingleBean(StringRedisTemplate.class)`(Boot 제공) + `RedisConfig`가 `@ConditionalOnBean` 없이 정상 로드됨 단언. 실 Redis 미접속(Lettuce 지연 연결 — 빈 생성만, 명령 미실행). **목적**: 우리 빈 가림 RED 가드가 아니라 "Redis 활성 시 `StringRedisTemplate` 주입 가능"이라는 **009 의존 가정의 핀**(프레임워크 회귀/Boot 버전업 시 신호).
- **회귀(실질 가드)**: 풀컨텍스트 `test`(RedisAutoConfiguration 제외) 전체 그린 — notification 005/023/024/025 테스트 무영향. **`RedisConfig`에 `@ConditionalOnBean`/커스텀 `@Bean` 부재**(소스/컴파일 확인) — P1 안티패턴 재유입 시 신호.

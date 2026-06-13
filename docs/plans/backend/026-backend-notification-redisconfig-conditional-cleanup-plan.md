# 026 notification RedisConfig `@ConditionalOnBean` 선제 정리 plan

> 한 줄 요약: `RedisConfig`의 redundant 커스텀 `stringRedisTemplate` `@Bean` + P1 안티패턴(`@ConditionalOnBean`)을 삭제해 Spring Boot `RedisAutoConfiguration`에 위임하고, `@EnableConfigurationProperties(RedisProperties.class)`만 남기는 무해(주입처 0건·Boot 폴백)한 위생 정리 + 정직한 가정-고정 테스트.

---

## 1. 설계 방식 및 이유

**결정: 커스텀 `stringRedisTemplate` `@Bean` + `@ConditionalOnBean(RedisConnectionFactory)`를 삭제하고 Boot에 위임한다. `RedisConfig`는 `@Configuration` + `@EnableConfigurationProperties(RedisProperties.class)` 전용(MailConfig 패턴)으로 남긴다.**

근거 세 가지(Task Goal·Context와 일치):
- **redundant**: Spring Boot `RedisAutoConfiguration`이 `RedisConnectionFactory` 존재 시 `@ConditionalOnMissingBean`으로 동일한 `StringRedisTemplate(connectionFactory)` 빈을 이미 자동 등록한다. 커스텀 빈은 Boot 빈과 동치이므로 불필요.
- **P1 안티패턴 선제 제거**(`docs/review-patterns.md` P1, line 48이 이 케이스 지목): 사용자 `@Bean`에 붙은 `@ConditionalOnBean`은 평가 순서에 민감해 빈이 조용히 누락될 수 있는 패턴이다. 지금은 주입처 0건이라 무해하지만, 009(dedup)가 `StringRedisTemplate` 주입 컴포넌트를 추가하기 **전에** 정리해 P1 연쇄(체인) 형성 여지를 차단한다.
- **현재 무해함 명시**: 운영(Redis 활성)에서 커스텀 빈이 순서로 skip돼도 Boot의 `@ConditionalOnMissingBean stringRedisTemplate` 폴백이 채워 넣으므로 단독 빈 부재로 인한 기동 실패는 없다. 따라서 본 변경은 런타임 거동을 바꾸지 않는 **위생 정리**다.

`RedisConfig`를 properties-활성 전용으로 남기는 이유: `RedisProperties`(009 dedup 설정 기반)는 주입처가 없어도 등록을 유지해야 하며, `MailConfig`가 동일하게 `@EnableConfigurationProperties`만 갖는 선례를 따른다.

**택1 — 실질 회귀 가드 방식**

> **결정: (a) 리플렉션 기반 단위 단언으로 "`RedisConfig`에 `@ConditionalOnBean`/커스텀 `@Bean` 부재"를 자동 가드한다.**
> 근거: Task의 Acceptance/Test가 이 부재를 **실질 회귀 가드**로 명시 요구한다. 기존 가정-고정 테스트와 같은 클래스에 리플렉션 단언 1~2줄을 추가하는 것은 새 프로덕션 빈/추상화 없이 끝나는 최소 비용이며, 안티패턴 재유입을 코드 신호로 잡는 가치가 (b)순수 리뷰 체크리스트/소스 확인보다 명확히 크다. 과도한 설계 경계(빈/추상화/별도 테스트 인프라 추가 금지)를 넘지 않는다.

---

## 2. 구성 요소

신규 프로덕션 빈/추상화 **없음**. 파일은 1개 수정 + 1개 신규 테스트.

### (수정) `notification/src/main/java/com/shop/notification/common/config/RedisConfig.java`
- 역할: `RedisProperties` 활성화 전용 설정(`@Configuration` + `@EnableConfigurationProperties`)으로 축소.
- 변경: `stringRedisTemplate` `@Bean` 메서드 삭제 + `@ConditionalOnBean` 삭제 + 미사용 import 삭제(`ConditionalOnBean`, `Bean`, `RedisConnectionFactory`, `StringRedisTemplate`). 클래스 Javadoc을 "Boot 위임" 취지로 정정(`@ConditionalOnBean` 가드 설명·StringRedisTemplate 노출 설명 제거).

최종 형태:
```java
package com.shop.notification.common.config;

import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Configuration;

/**
 * notification Redis 설정.
 * RedisProperties 활성화 전용 (@EnableConfigurationProperties) — MailConfig 패턴 동일.
 *
 * StringRedisTemplate은 별도로 노출하지 않는다.
 * Redis 활성 환경에서 Spring Boot RedisAutoConfiguration이
 * @ConditionalOnMissingBean으로 StringRedisTemplate을 자동 제공하며,
 * 후속 dedup(Task 009)은 그 빈을 그대로 주입한다.
 * RedisConnectionFactory(Lettuce 자동설정 기본)도 재정의하지 않는다.
 */
@Configuration
@EnableConfigurationProperties(RedisProperties.class)
public class RedisConfig {
}
```

### (신규) `notification/src/test/java/com/shop/notification/common/config/RedisTemplateWiringTest.java`
- 역할: ① 009 의존 가정 고정(Redis 활성 시 Boot가 `StringRedisTemplate` 제공) + ② 실질 회귀 가드(`RedisConfig`에 `@ConditionalOnBean`/커스텀 `@Bean` 부재).
- 패턴: `MailPropertiesTest`/`RedisPropertiesTest`의 `ApplicationContextRunner` 계승.
- **명명 주의(Javadoc에 명시)**: 여기서 "wiring"은 **Boot 자동 제공 가정의 핀 + 안티패턴 부재 가드**이지, P1 산출물 `RefreshTokenStoreWiringTest`류의 "우리 운영 구현체 배선 단언"이 **아니다**(우리 빈을 삭제했으므로). 후속 작업자 오해 방지용으로 클래스 Javadoc에 이 구분을 적는다.

### (변경 없음)
`RedisProperties.java`(유지), `MailConfig.java`, `src/test/resources/application.yml`·`application-kafkatest.yml`(둘 다 `RedisAutoConfiguration`/`RedisRepositoriesAutoConfiguration` 제외 — 무변경), `src/main/resources/application.yml`.

---

## 3. 데이터 흐름 (빈 배선 — 컨텍스트별 `StringRedisTemplate` 존재 여부)

| 컨텍스트 | 변경 전 | 변경 후 |
|---|---|---|
| **운영(Redis 활성, `RedisAutoConfiguration` 동작)** | 커스텀 `@Bean @ConditionalOnBean`이 평가 순서에 따라 생성되거나 skip → skip 시 Boot `@ConditionalOnMissingBean` 폴백이 채움. 결과적으로 `StringRedisTemplate` 1개 존재(경로만 취약) | Boot `RedisAutoConfiguration`이 `StringRedisTemplate` 직접·단일 제공. 조건 순서 취약점 없음. 빈 결과 동일(1개 존재) |
| **test 프로파일(`RedisAutoConfiguration` 제외)** | `RedisConnectionFactory` 없음 → `@ConditionalOnBean` false → 커스텀 빈 미생성. `StringRedisTemplate` 0개 | 커스텀 빈 자체가 없음 + 자동설정 제외 → `StringRedisTemplate` 0개. **동일**(회귀 0) |

핵심: 운영·test 두 컨텍스트 모두에서 변경 전후 `StringRedisTemplate` 빈 존재 여부가 **동일**하다(운영 1개, test 0개). 달라지는 것은 운영에서의 제공 경로가 "조건부 커스텀 빈 + 폴백"에서 "Boot 직접"으로 단순화된 것뿐이다.

---

## 4. 예외 처리 전략

본 변경은 빈 배선 정리라 **런타임 예외 경로 변화 없음**. 신규 try/catch·예외·핸들러 없음.

"삭제로 깨질 수 있는 것" 점검 — **없음**:
- `StringRedisTemplate`/`RedisTemplate` 주입처 **0건**(grep 재확인: `RedisConfig.java` 내부 외 참조 없음). 삭제해도 `NoSuchBeanDefinitionException`을 던질 소비자가 없다.
- 운영에서 `StringRedisTemplate`이 필요해지는 시점(009)에는 Boot 자동설정 폴백이 그 빈을 제공한다.
- test 프로파일은 자동설정 제외로 본래 `StringRedisTemplate`이 없었고, 그 빈을 주입하는 빈도 없으므로 컨텍스트 로드 영향 0.

---

## 5. 검증 방법

`./gradlew test`(외부 Redis 미접속, Lettuce 지연 연결 — 빈 생성만, 명령 미실행).

**(1) 009 의존 가정 고정 테스트** — `RedisTemplateWiringTest`
- `ApplicationContextRunner`에 `AutoConfigurations.of(RedisAutoConfiguration.class)`를 추가하고 `RedisConfig`를 사용자 설정으로 로드 → `assertThat(context).hasSingleBean(StringRedisTemplate.class)`.
- **정직한 목적 명시**: 이 단언은 testing-rule이 말하는 "우리 운영 구현체를 더블이 가려 생긴 거짓 통과를 막는 RED 가드"가 **아니다**(가릴 우리 빈이 사라졌음). 순수 Spring Boot가 제공하므로, 이 테스트는 **"Redis 활성 시 `StringRedisTemplate` 주입 가능"이라는 009 의존 가정을 핀으로 고정**하는 것이다 — 프레임워크 회귀/Boot 버전업으로 그 가정이 깨지면 RED 신호. 약화 단언(`doesNotThrow`류 무의미 통과) 금지 — `hasSingleBean`으로 명확히 단언한다.

**(2) 실질 회귀 가드(택1 결정 (a))** — 같은 클래스에 리플렉션 단언
- `RedisConfig`에 `@Bean` 선언 메서드가 **0개**, 그리고 `@ConditionalOnBean` 사용이 **없음**을 리플렉션으로 단언. `@EnableConfigurationProperties` 존재도 단언.
- **검사 표면 명시(false-green 방지)**: `@ConditionalOnBean` 부재는 **클래스 애노테이션 + `getDeclaredMethods()`의 모든 선언 메서드 애노테이션을 둘 다 순회**해 단언한다. P1 안티패턴의 본질은 "**메서드 `@Bean`에 붙은 `@ConditionalOnBean`**"이므로 **메서드 레벨 순회가 핵심** — 클래스만 검사하고 메서드를 누락하면 안티패턴 재유입을 못 잡는 false-green이 된다.
- 목적: P1 안티패턴(사용자 `@Bean`에 `@ConditionalOnBean`) 재유입 시 자동 RED. (보조로, `hasSingleBean(StringRedisTemplate)`의 **단일성** 단언도 커스텀 빈 부활 시 깨져 신호가 된다.)

**(3) 풀 컨텍스트 test 그린**
- `RedisAutoConfiguration` 제외 프로파일에서 notification 005/023/024/025 전체 테스트 그린 — 기능/회귀 영향 0(주입처 0건).

---

## 6. 트레이드오프

- **빈 삭제 vs `@Profile("!test")` 유지**: `@Profile`로 `@ConditionalOnBean`만 떼는 대안도 있으나, Boot가 동일 `StringRedisTemplate`을 `@ConditionalOnMissingBean`으로 자동 제공하므로 커스텀 빈을 유지할 이유 자체가 없다. **삭제가 정답**(redundant 해소 + 안티패턴 동시 제거). `@Profile`은 불필요한 코드를 남길 뿐.
- **가정-고정 테스트의 약한 회귀 가드성(정직)**: (1) 테스트는 우리 코드가 아니라 **프레임워크 가정**을 핀한다 — 우리 운영 배선을 지키는 강한 RED 가드가 아니다(task가 이미 정직화한 입장을 유지). 우리 코드에 대한 실질 가드는 (2) 리플렉션 부재 단언이 담당한다. 이 분리를 과대 주장하지 않고 명시한다.
- **test 자동설정 제외 정책 무변경 → 009 이월**: 본 Task는 `RedisAutoConfiguration` 제외 정책을 바꾸지 않는다(005/023/024/025 회귀 금지). 정리 후 "가려질 운영 빈"이 사라져 거짓 통과 위험은 해소되지만, **009가 `StringRedisTemplate` 주입 컴포넌트를 추가할 때는 그 컴포넌트의 운영 배선(Boot 자동 `StringRedisTemplate` 주입)을 별도 검증해야 함**을 009로 명시 이월한다.

---

## 완료 조건
- [ ] `RedisConfig`에 `@ConditionalOnBean` 및 커스텀 `stringRedisTemplate` `@Bean` 부재. `@EnableConfigurationProperties(RedisProperties.class)` 유지. 미사용 import 제거.
- [ ] `RedisAutoConfiguration` 활성 격리 컨텍스트에서 `StringRedisTemplate` 빈 존재(`hasSingleBean`)가 테스트로 고정됨.
- [ ] 리플렉션 단언으로 `RedisConfig`의 `@Bean`/`@ConditionalOnBean` 부재가 가드됨.
- [ ] `./gradlew test` 풀 컨텍스트 그린(005/023/024/025 무영향).
- [ ] `RedisProperties` + `@EnableConfigurationProperties` 유지, test 자동설정 제외 정책 무변경(009 이월만 문서화).

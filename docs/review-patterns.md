# Review Patterns — 리뷰에서 반복적으로 놓치는 결함 패턴

> reviewer/fixer가 참고하는 누적 체크리스트. 실제로 한 번 빠져나간 결함을 패턴으로 박제해 재발을 막는다.
> 새 결함이 "테스트는 통과했는데 런타임/운영에서 터진" 종류라면 반드시 여기에 한 항목으로 추가한다.

---

## P1. 테스트 더블(@Primary/@MockitoBean)이 운영 배선을 가려 생긴 거짓 통과

- 발견 Task: 006 (shop-core JWT 로그인) — 구현 직후 reviewer PASS, `./gradlew test` 87개 통과했으나 실제 앱 기동에서 실패.
- 증상(런타임):
  ```
  Parameter 1 of method jwtAuthenticationFilter in com.shop.shop.security.SecurityConfig
  required a bean of type 'com.shop.shop.security.RefreshTokenStore' that could not be found.
  ```

### 무슨 일이 있었나
- `RefreshTokenStore`의 운영 구현체 `RedisRefreshTokenStore`가 `@Component` + `@ConditionalOnBean(StringRedisTemplate.class)`로 선언됨.
- 테스트는 (a) `FakeRefreshTokenStore(@Primary)`를 주입해 `RefreshTokenStore` 의존을 항상 채우고, (b) 테스트 `application.yml`이 `RedisAutoConfiguration`을 제외해 `StringRedisTemplate`을 없앰.
- 결과: 테스트 컨텍스트에서 **운영 구현체(`RedisRefreshTokenStore`)가 단 한 번도 인스턴스화되지 않음**. 즉 "운영에서 이 빈이 실제로 배선되는가"를 검증한 테스트가 0건.
- 운영에는 Fake가 없으므로 `RefreshTokenStore` 빈이 없어 기동 실패.

### 핵심 교훈
- **테스트 더블이 검증 대상 자체를 대체하면, 그 대상의 실제 배선/생성은 검증되지 않는다.** 통과한 테스트 수는 안전을 보장하지 않는다.
- 특정 빈을 mock/fake/@Primary로 갈아끼울 때는, **운영 구현체가 운영과 동일한 조건에서 실제로 컨텍스트에 등록되는지** 별도로 검증해야 한다.

### 부수 원인 — `@ConditionalOnBean` 오용 (별도로도 위험)
- `@ConditionalOnBean`은 **평가 순서에 민감**하며 Spring 공식 문서가 "오토컨피규레이션 클래스에서만 쓰라"고 명시한다.
- 사용자 `@Component`/`@Bean`에 붙이면 **컴포넌트 스캔 시점(= 오토컨피그보다 먼저)** 에 평가되어, 아직 등록되지 않은 오토컨피그 빈(`StringRedisTemplate`, `RedisConnectionFactory` 등)을 보지 못하고 조건이 `false`가 되어 빈이 조용히 사라진다.
- 흔한 연쇄: 사용자 `@Bean @ConditionalOnBean(오토컨피그빈)` → 사용자 `@Component @ConditionalOnBean(그 사용자빈)` → 최종 주입처에서 NoSuchBean.

### 리뷰 체크리스트 (이 패턴 적용)
- [ ] 어떤 인터페이스를 `@MockitoBean`/`@Primary` fake로 교체하는 테스트가 있는가? 있다면 그 **인터페이스의 운영 구현체가 실제로 빈 등록되는지** 검증하는 테스트가 따로 있는가?
- [ ] fake/더블이 `@Component`로 자동 스캔되지는 않는가? (자동 스캔되면 운영 배선 검증 테스트에도 새어 들어가 무의미해진다 → `@Import` 전용으로 두라.)
- [ ] 테스트 `application.yml`의 `spring.autoconfigure.exclude`가 **운영 구현체의 의존(예: `StringRedisTemplate`)을 없애** 그 구현체가 테스트에서 절대 생성되지 않게 만들고 있지 않은가?
- [ ] 사용자 `@Component`/`@Bean`에 `@ConditionalOnBean`이 붙어 있지 않은가? 붙어 있다면 평가 순서로 인해 운영에서 빈이 누락될 수 있다. (오토컨피그가 이미 제공하는 빈이면 커스텀 빈을 제거하고 위임하라.)
- [ ] "운영과 동일한 컴포넌트 스캔 + 오토컨피그" 상태로 컨텍스트를 띄워 주요 진입 빈(필터, 컨트롤러 의존)이 모두 해결되는 컨텍스트 테스트가 있는가?

### 올바른 처리
- `@ConditionalOnBean`을 운영 구현체에서 제거하고, 의존 빈은 Spring Boot 오토컨피그(`RedisAutoConfiguration`의 `stringRedisTemplate` 등)에 위임한다.
- 테스트에서 인프라 연결을 피하고 싶으면 **자동설정을 통째로 제외하지 말고**, 지연 연결(Lettuce 등)을 활용해 빈은 생성하되 연결만 미루거나, 동작만 fake로 교체한다.
- fake는 `@Component`가 아닌 `@Import` 전용 클래스로 두고(`@Primary` 유지), **운영 배선 회귀 테스트는 fake를 import하지 않고** `assertThat(context.getBean(Iface.class)).isInstanceOf(RealImpl.class)`로 단언한다. 이 테스트는 수정 전 코드에서 반드시 실패해야 의미가 있다.

### 회귀 방지 산출물
- `shop-core/src/test/java/com/shop/shop/security/RefreshTokenStoreWiringTest.java` — fake 미import + `@SpringBootTest`로 `RefreshTokenStore`가 `RedisRefreshTokenStore`로 배선됨을 단언.

### 다른 곳의 동일 패턴 (선제 점검 대상)
- `notification/.../common/config/RedisConfig.java`도 `@ConditionalOnBean(RedisConnectionFactory.class)` + 커스텀 `stringRedisTemplate` 패턴을 가진다. 현재는 주입처가 없어 무해하나, notification에 Redis 기반 빈(예: dedup용 `StringRedisTemplate` 주입)이 추가되면 동일 기동 실패가 재현된다. 그 Task에서 같은 방식으로 정리할 것.

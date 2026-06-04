# (backlog) notification RedisConfig @ConditionalOnBean 선제 정리

> 상태: backlog (미착수)
> 영역: notification (backend / common.config)
> 출처: RefreshTokenStore 기동 실패 버그 수정 보고 + `docs/review-patterns.md` P1 — notification에 동일 취약 패턴 잔존

## 배경 / 동기
- shop-core에서 `@ConditionalOnBean`을 사용자 `@Component`/`@Bean`에 적용해 운영 빈이 누락되는 기동 실패가 발생했고(P1), 조건 제거 + Boot 오토컨피그 위임으로 수정했다.
- `notification/.../common/config/RedisConfig.java`도 동일하게 `@Bean @ConditionalOnBean(RedisConnectionFactory) StringRedisTemplate` 패턴을 가진다. **현재는 StringRedisTemplate 주입처가 없어 무해**하나, dedup 등 Redis 기반 빈이 추가되면 동일 기동 실패가 재현된다.

## 범위 (할 것)
- notification `RedisConfig`의 커스텀 `stringRedisTemplate` `@Bean` + `@ConditionalOnBean` 제거 → Boot `RedisAutoConfiguration` 위임(`@EnableConfigurationProperties(RedisProperties)`만 유지).
- notification test 프로파일의 Redis 자동설정 제외 정책 재점검(운영 배선이 테스트에서 가려지지 않도록 — testing-rule).
- Redis 기반 빈 추가 시(009와 연계) 운영 배선 회귀 테스트 동반.

## 범위 밖 / 주의
- 기능 변경 없음(빈 배선/조건만). dedup 실제 적용은 009.

## 선행 의존
- 없음(선제 정리 가능). 단 009 직전에 함께 하면 효율적.

## 참고
- `docs/review-patterns.md` P1, `docs/rules/testing-rule.md`

# 005. Redis 의존성 + 로컬 인프라 구성 — 구현 Plan

> 영역: infra (Redis 의존성 도입 + 로컬 docker-compose Redis + 프로젝트별 key namespace/TTL 설계 + 설정 클래스 + 테스트 비파괴)
> 대상 프로젝트: workspace (shop-core + notification 두 레포에 걸친 인프라 Task. REST/화면 작업 없음)
> 작성일: 2026-06-03
> 상태: plan only (코드 변경 없음)

---

## 구현 목표
`shop-core`와 `notification`에 **Spring Data Redis starter**와 접속 설정을 추가하고, 로컬 `docker/shop/docker-compose.yml`에 단일 `shop-redis`(6379) 컨테이너를 기존 인프라 패턴(네트워크 `shop-net`, `restart:"no"`, 이미지 태그 `.env` 변수화, healthcheck, named volume)과 일관되게 추가한다. 각 프로젝트는 **자기 용도에 맞는 Redis key namespace/TTL을 `@ConfigurationProperties`(record, `SecurityUserProperties` 패턴)로 설정화**하고, prefix를 프로젝트별로 분리(shop-core `shopcore:*`, notification `notif:*`)하고 **logical DB index도 분리**(shop-core DB 0, notification DB 1)해 이중 격리한다. 분산락 실제 적용·JWT 발급/검증·알림 dedup 실제 적용·Consumer 처리 로직 변경은 **이 Task 범위 밖**이며 namespace/TTL "설계"와 접속/설정 "기반"만 만든다. 테스트 프로파일에서는 `RedisAutoConfiguration`을 비활성화해 **Redis 브로커 없이 컨텍스트 테스트가 통과**하도록 하고, properties 바인딩/prefix·TTL 값 검증 테스트를 추가한다.

## 영향 범위

### 신규 파일 (main)
- `shop-core/src/main/java/com/shop/shop/common/config/RedisProperties.java` — `@ConfigurationProperties(prefix="shop.redis")` record. Redis key prefix(auth/refresh/blacklist/lock) + TTL 값 바인딩 + 기본값 폴백
- `shop-core/src/main/java/com/shop/shop/common/config/RedisConfig.java` — `@Configuration`. `StringRedisTemplate` 빈 명시 노출(+ `RedisProperties` 활성화). 자동설정 `RedisConnectionFactory` 재사용
- `notification/src/main/java/com/shop/notification/common/config/RedisProperties.java` — `@ConfigurationProperties(prefix="notification.redis")` record. dedup prefix + TTL 바인딩 + 기본값 폴백
- `notification/src/main/java/com/shop/notification/common/config/RedisConfig.java` — `@Configuration`. `StringRedisTemplate` 빈 명시 노출(+ `RedisProperties` 활성화)

### 신규 파일 (test)
- `shop-core/src/test/java/com/shop/shop/common/config/RedisPropertiesTest.java` — `shop.redis.*` 바인딩 + prefix/TTL 기본값·오버라이드 검증 (Redis 미기동, 컨텍스트 불요 또는 Redis 자동설정 제외 컨텍스트)
- `notification/src/test/java/com/shop/notification/common/config/RedisPropertiesTest.java` — `notification.redis.*` 바인딩 + dedup prefix/TTL 기본값·오버라이드 검증 (Redis 미기동)

### 수정 파일
- `docker/shop/docker-compose.yml` — `shop-redis` 서비스 추가(6379, `redis:7.4-alpine` 변수화, healthcheck `redis-cli ping`, named volume `shop-redis-data`, `shop-net`, `restart:"no"`)
- `docker/shop/.env.example` — `REDIS_IMAGE_TAG`, `REDIS_PORT` 변수 추가(로컬 전용 주석)
- `shop-core/build.gradle` — `spring-boot-starter-data-redis` 추가(버전 BOM 위임)
- `shop-core/src/main/resources/application.yml` — `spring.data.redis`(host/port/database=0/timeout) + `shop.redis`(prefix/TTL) 블록 + 용도 주석
- `shop-core/src/test/resources/application.yml` — `spring.autoconfigure.exclude`에 `RedisAutoConfiguration`(+ `RedisRepositoriesAutoConfiguration`) 추가
- `notification/build.gradle` — `spring-boot-starter-data-redis` 추가(버전 BOM 위임)
- `notification/src/main/resources/application.yml` — `spring.data.redis`(host/port/database=1/timeout) + `notification.redis`(dedup prefix/TTL) 블록 + 용도 주석
- `notification/src/test/resources/application.yml` — `spring.autoconfigure.exclude`에 `RedisAutoConfiguration`(+ `RedisRepositoriesAutoConfiguration`) 추가
- `notification/src/test/resources/application-kafkatest.yml` — `RedisAutoConfiguration` 제외 추가(EmbeddedKafka 통합 테스트가 Redis 연결 시도하지 않도록)
- `notification/src/test/java/com/shop/notification/service/EventProcessingServiceTransactionTest.java` — `@TestPropertySource`에 `spring.data.redis.repositories.enabled=false` + Redis 자동설정 비활성 보강(`exclude=` 리셋으로 Redis가 살아나는 문제 차단 — **필수**, 섹션 1.7)

### 범위 밖 (필요성만 명시, 후속 Task로 미룸)
- JWT 발급/검증, refresh token 실제 저장·회전, access token blacklist 실제 적용 코드 (후속 인증 Task)
- 분산락 실제 획득/해제 코드 및 적용 도메인 로직(재고/쿠폰 등), Redisson 등 분산락 라이브러리 (후속 분산락 Task — 섹션 1.3 결정)
- notification 알림 dedup 실제 적용(Consumer/Service 처리 로직 변경) (후속 dedup 적용 Task)
- Redis 장애 시 fallback/Circuit·예외 정책의 실제 구현 (실제 사용 Task에서 정의 — 섹션 4)
- 운영용 Redis 보안(AUTH/TLS)/클러스터/Sentinel 구성 (로컬 단일 Redis만)
- Testcontainers(Redis) 통합 테스트 (섹션 6 트레이드오프 — 본 Task 범위에 과함)

---

## 1. 설계 방식 및 이유

### 1.1 Redis 용도 분리 (프로젝트별 책임)
- **shop-core**: JWT 로그인 상태 저장(refresh token/세션 상태) + access token blacklist + 분산락. 모두 "shop-core 내부" 보조 저장소다. 이 Task는 prefix/TTL **설계와 설정 기반**만 만들고 실제 쓰기/읽기 코드는 만들지 않는다.
- **notification**: 알림 중복 발생 방지(dedup)용 빠른 1차 방어 캐시. 영속 권위는 기존 `processed_event`(DB)이며, Redis dedup은 그 앞단의 빠른 멱등 체크용임을 명확히 구분한다(섹션 1.5). 이 Task는 prefix/TTL 설계와 설정만 만들고 Consumer 처리 로직은 손대지 않는다(Constraint).

### 1.2 key namespace + logical DB 이중 격리 (두 프로젝트 통신/오염 금지 보장)
- **Constraint**: Redis를 두 프로젝트 간 직접 통신 수단으로 쓰지 않고, notification이 shop-core 로그인/도메인 데이터를 읽지 않으며, namespace를 분리한다.
- **이중 격리 채택**:
  1. **key prefix 분리** — shop-core는 `shopcore:*`, notification은 `notif:*`. 코드상 서로의 prefix를 **모른다**(각 프로젝트 `RedisProperties`에 자기 prefix만 존재). 상대 prefix를 참조하는 코드가 0이므로 "직접 통신/교차 read"가 구조적으로 불가능하다.
  2. **logical DB index 분리** — shop-core `spring.data.redis.database=0`, notification `=1`. 로컬에서 단일 Redis 인스턴스를 공유하더라도 다른 DB index를 쓰면 keyspace가 물리적으로 갈린다. prefix만으로도 충돌은 막히지만, DB index 분리로 "실수로라도 교차 접근" 여지를 한 겹 더 제거한다(YAGNI 한도 내 — 설정값 1줄 비용).
- **근거**: 두 프로젝트는 본래 Kafka로만 단방향·비동기 연결(architecture). Redis는 각자의 보조 저장소이지 공유 채널이 아니다. prefix + DB index 분리로 "공유 인스턴스를 쓰되 논리적으로 완전 분리"를 시연한다. (운영에서는 인스턴스 자체 분리가 더 깔끔하나, 로컬 단일 Redis 범위이므로 DB index로 분리 — 섹션 6 트레이드오프.)

### 1.3 Redisson(분산락 라이브러리) 도입 여부 — **이 Task에서는 보류(미채택)**
- **결정**: 이 Task에서는 **Spring Data Redis starter만** 추가하고 Redisson 등 분산락 라이브러리는 **추가하지 않는다**. 분산락 key prefix/TTL은 `shop.redis.lock.*`로 "설계·설정"만 남기고, 실제 락 획득/해제 구현은 분산락 적용 도메인 Task로 미룬다.
- **근거(YAGNI/Constraint)**: Task Constraint가 "분산락 적용 대상 도메인 로직은 이 Task에서 구현하지 않는다"이고, Requirement는 "필요 시 검토 후 추가"(필수 아님)다. 지금 Redisson을 넣으면 (a) 사용처가 0인 의존성 + `RedissonClient` 빈/설정만 늘고, (b) 테스트 컨텍스트에서 Redisson 자동설정이 Redis 연결을 시도해 비파괴 전략(섹션 1.7)을 더 복잡하게 만든다. 락 구현 시점에 락 의미론(공정성·watchdog·재시도)을 함께 결정하는 편이 응집도가 높다.
- **트레이드오프는 섹션 6**. 실제 락 구현 Task에서 Redisson 도입을 재검토하도록 plan/주석에 남긴다(`shop.redis.lock.*` 설계가 그 Task의 입력이 됨).

### 1.4 shop-core key namespace 설계 (prefix + TTL, 모두 설정화)
SSOT는 `shop-core` `application.yml`의 `shop.redis` 블록 + `RedisProperties` record. 실제 키 조립(`prefix + ":" + id`)은 후속 사용 Task의 책임이며, 이 Task는 prefix/TTL 값만 정의·검증한다.

| 용도 | key prefix(설정 키) | 기본값(prefix) | TTL(설정 키) | 기본 TTL | 비고 |
|---|---|---|---|---|---|
| refresh token / 로그인 세션 상태 | `shop.redis.auth.refresh-prefix` | `shopcore:auth:refresh:` | `shop.redis.auth.refresh-ttl` | `P14D`(14일) | 키 식별자는 후속 Task에서 `userId` 또는 `tokenId(jti)`로 확정. refresh 만료와 정합 |
| access token blacklist | `shop.redis.auth.blacklist-prefix` | `shopcore:auth:blacklist:` | `shop.redis.auth.blacklist-ttl` | `PT30M`(30분) | 키는 `jti`. TTL은 **access token 잔여 만료 시간**으로 후속 Task에서 동적 산정(여기 기본값은 access TTL 가정치). 만료 후 자동 삭제로 메모리 누수 방지 |
| 분산락 | `shop.redis.lock.prefix` | `shopcore:lock:` | `shop.redis.lock.ttl` | `PT10S`(짧게) | 키는 `{resource}`. 데드락 방지를 위해 짧은 TTL. 실제 락 구현은 후속(1.3) |

- TTL은 `java.time.Duration`(ISO-8601 `P..T..`)으로 바인딩 → 타입 안전 + 단위 모호성 제거. record 컴팩트 생성자에서 null/blank 기본값 폴백(`SecurityUserProperties` 패턴).
- **구현 시 확인**: 키 식별자 기준(userId vs jti)과 access blacklist TTL의 동적 산정은 JWT Task에서 확정. 기본값은 막히지 않을 합리값으로 둔다.

### 1.5 notification key namespace 설계 (dedup, 설정화) + DB 멱등과의 역할 구분
| 용도 | key prefix(설정 키) | 기본값(prefix) | TTL(설정 키) | 기본 TTL | 비고 |
|---|---|---|---|---|---|
| 알림 중복 방지(dedup) | `notification.redis.dedup.prefix` | `notif:dedup:` | `notification.redis.dedup.ttl` | `P3D`(3일) | 중복 판단 키는 **원본 이벤트 `eventId`**(architecture: 모든 이벤트가 `eventId` 보유 — 멱등 기준). TTL은 이벤트 재전송/재시도 윈도우를 덮는 보존값 |

- **DB `processed_event`와의 역할 구분(명시)**: `processed_event`(Flyway V1, `event_id` UNIQUE)는 **영속 권위(authoritative) 멱등 저장소**다. Redis `notif:dedup:{eventId}`는 그 **앞단의 빠른 1차 방어**(메모리 조회로 DB 왕복 절감)일 뿐, 권위가 아니다. TTL 만료/Redis 장애로 Redis dedup이 miss해도 **DB UNIQUE 제약이 최종 권위로 중복을 막는다**. 따라서 Redis dedup은 "있으면 빠르고, 없어도 정확성 손상 없음"인 보조 캐시다.
- **이 Task 범위**: prefix/TTL 설계와 설정/검증까지. 실제 dedup 조회/기록을 Consumer/Service에 끼워넣는 코드는 **후속**(Constraint: Consumer 처리 로직 변경 금지). 기본 eventId가 멱등 기준임을 plan/주석에 명문화한다.

### 1.6 RedisTemplate vs StringRedisTemplate — **StringRedisTemplate 채택**
- **결정**: 두 프로젝트 모두 `StringRedisTemplate`을 사용/빈 노출한다(자동설정도 기본 제공하나, 의도를 명시하기 위해 `RedisConfig`에서 명시 빈으로 노출 + 직렬화 정책 주석).
- **근거**: 본 Task의 모든 용도(refresh 상태 토큰 문자열, blacklist 마커, lock 토큰, dedup 마커 — 전형적으로 `SET key value EX ttl`/`SETNX`/`EXISTS`)는 **문자열 키 + 단순 문자열 값 + TTL**로 충분하다. `StringRedisTemplate`은 key/value 모두 `StringRedisSerializer`라 `redis-cli`에서 사람이 읽을 수 있고(디버깅 용이), JDK 직렬화의 깨진 바이트/보안 이슈를 피한다. 복잡한 객체 캐싱(JSON 직렬화) 수요가 생기면 그때 별도 `RedisTemplate<String,Object>` 빈을 추가한다(YAGNI).
- **`RedisConfig` 책임**: (a) `@EnableConfigurationProperties(RedisProperties.class)`로 properties 활성화, (b) 자동설정 `RedisConnectionFactory`를 주입받아 `StringRedisTemplate` 빈을 명시 노출(직렬화 정책을 코드/주석으로 고정). `RedisConnectionFactory`(Lettuce, 자동설정 기본)는 재정의하지 않는다.

### 1.7 테스트 프로파일 전략 — 가장 깨지기 쉬운 부분 (Redis 자동설정 비활성)
현재 두 test `application.yml`은 자동설정을 exclude해 인프라 없는 컨텍스트를 로드한다. Redis starter가 클래스패스에 들어오면 `RedisAutoConfiguration`이 활성화되어 컨텍스트 테스트가 (lazy 연결이라 로드는 보통 통과하나) Redis 빈을 잡고, 일부 경로에서 연결을 시도할 수 있다. 또한 properties 검증이 Redis 미기동에서도 동작해야 한다.

- **양 기본 test `application.yml`**: `spring.autoconfigure.exclude`에 추가
  - `org.springframework.boot.autoconfigure.data.redis.RedisAutoConfiguration`
  - `org.springframework.boot.autoconfigure.data.redis.RedisRepositoriesAutoConfiguration`(Redis 리포지토리 스캔 차단 — 본 Task는 리포지토리 미사용이나 안전상 함께 제외)
  - 이렇게 하면 `StringRedisTemplate`/`RedisConnectionFactory` 빈이 생성되지 않아, **Redis 브로커 없이 컨텍스트 테스트가 통과**한다. `RedisConfig`는 `RedisConnectionFactory`에 의존하므로, 제외 시 `RedisConfig`의 `StringRedisTemplate` 빈도 자연히 비활성(또는 `@ConditionalOnBean(RedisConnectionFactory)`로 가드 — 구현 시 택1, 가드 권장).
  - **주의**: `RedisProperties`(`@EnableConfigurationProperties`/`@ConfigurationProperties`)는 자동설정과 무관하게 바인딩되므로, prefix/TTL 검증 테스트는 Redis 자동설정이 꺼져도 동작한다.
- **notification `application-kafkatest.yml`(EmbeddedKafka 통합 테스트)**: 이 프로파일은 Kafka 자동설정만 살리고 DB는 제외한다. 여기에도 `RedisAutoConfiguration`(+ Repositories) 제외를 추가해, EmbeddedKafka 통합 테스트가 Redis 연결을 시도하지 않게 한다(브로커 없음). 기존 EmbeddedKafka 동작 비파괴.
- **notification `EventProcessingServiceTransactionTest`(H2 슬라이스, **필수 보강**)**: 이 테스트는 `@TestPropertySource`에서 `spring.autoconfigure.exclude=`(빈 값)로 **모든 exclude를 리셋**한다. 따라서 Redis starter가 클래스패스에 있으면 이 슬라이스에서 `RedisAutoConfiguration`이 **되살아나** Redis 연결을 시도해 슬라이스가 깨질 위험이 있다.
  - 조치(**필수**): 이 테스트의 `@TestPropertySource`에 Redis 비활성을 명시 보강한다. `@DataJpaTest`는 본래 Redis 빈을 자동 구성하지 않으므로 핵심은 "exclude 리셋이 Redis를 깨우지 않게" 하는 것이다. 가장 견고한 조치는:
    - `spring.data.redis.repositories.enabled=false` 추가(Redis 리포지토리 스캔 차단), 그리고
    - 필요 시 `@DataJpaTest`의 슬라이스 특성상 `RedisAutoConfiguration`이 포함되지 않음을 확인(포함되면 `excludeAutoConfiguration`로 명시 제외). **구현 시 확인**: 이 테스트가 Redis 추가 후에도 그린인지 우선 확인하고, 깨지면 위 보강을 적용한다(막히지 않을 기본값: `spring.data.redis.repositories.enabled=false` + Redis 자동설정 명시 제외).
- **shop-core 테스트**(Modulith verification/security/contextLoads): 기본 test yml의 Redis 자동설정 제외로 비파괴 유지.

---

## 2. 구성 요소

### 수정: 의존성 (build.gradle ×2)
- 두 프로젝트 모두 `implementation 'org.springframework.boot:spring-boot-starter-data-redis'` 추가(버전은 Spring Boot 3.5.x BOM 위임 — 하드코딩 회피, 기존 starter 추가 패턴과 동일). Lettuce 커넥터가 기본 동봉되므로 별도 커넥터 의존 불필요.
- **Redisson 등 분산락 라이브러리는 추가하지 않는다**(섹션 1.3).

### 수정: main application.yml ×2
- **shop-core**:
  - `spring.data.redis`: `host: ${SHOP_CORE_REDIS_HOST:localhost}`, `port: ${SHOP_CORE_REDIS_PORT:6379}`, `database: ${SHOP_CORE_REDIS_DB:0}`, `timeout: 2s`(기존 `${VAR:default}` 패턴).
  - `shop.redis`: auth(refresh/blacklist prefix·ttl) + lock(prefix·ttl) 블록(섹션 1.4 값) + **용도 주석**(JWT 로그인 상태 저장 + 분산락 — Acceptance "용도 구분").
- **notification**:
  - `spring.data.redis`: `host: ${NOTIFICATION_REDIS_HOST:localhost}`, `port: ${NOTIFICATION_REDIS_PORT:6379}`, `database: ${NOTIFICATION_REDIS_DB:1}`, `timeout: 2s`.
  - `notification.redis`: dedup(prefix·ttl) 블록(섹션 1.5 값) + **용도 주석**(알림 중복 방지 — Acceptance "용도 구분", DB processed_event와의 역할 구분 주석).
- **로컬 단일 Redis지만 host/port는 동일(localhost:6379), database index만 0/1로 분리**(섹션 1.2). 운영 전환 시 host를 인스턴스별로 분리할 수 있도록 환경변수화.

### 수정: test application.yml ×2 + application-kafkatest.yml
- 기본 test yml ×2: `spring.autoconfigure.exclude`에 `RedisAutoConfiguration` + `RedisRepositoriesAutoConfiguration` 추가(기존 항목 보존).
- `application-kafkatest.yml`: 동일 2개 제외 추가(EmbeddedKafka 통합 테스트 비파괴).

### 수정: notification EventProcessingServiceTransactionTest (필수)
- `@TestPropertySource`에 `spring.data.redis.repositories.enabled=false`(및 필요 시 Redis 자동설정 명시 제외) 추가 — `exclude=` 리셋으로 Redis가 살아나 H2 슬라이스를 깨뜨리지 않게(섹션 1.7).

### 신규: RedisProperties (record) ×2
- **shop-core** `com.shop.shop.common.config.RedisProperties` — `@ConfigurationProperties(prefix="shop.redis")`. 중첩 record(`Auth(refreshPrefix, refreshTtl, blacklistPrefix, blacklistTtl)`, `Lock(prefix, ttl)`). TTL은 `Duration`. 컴팩트 생성자에서 null/blank → 기본값 폴백(`SecurityUserProperties` 패턴 동일). 클래스 Javadoc에 "키 조립/실제 사용은 후속 Task" 명시.
- **notification** `com.shop.notification.common.config.RedisProperties` — `@ConfigurationProperties(prefix="notification.redis")`. 중첩 record(`Dedup(prefix, ttl)`). 동일 폴백 패턴. Javadoc에 "DB processed_event가 권위, Redis는 1차 방어" 명시.

### 신규: RedisConfig ×2
- **shop-core/notification** `common.config.RedisConfig` — `@Configuration` + `@EnableConfigurationProperties(RedisProperties.class)`. `@Bean StringRedisTemplate stringRedisTemplate(RedisConnectionFactory)` 노출(직렬화 = String key/value, 주석으로 정책 고정). `RedisConnectionFactory`(자동설정 Lettuce) 재정의 안 함. 테스트 비파괴를 위해 `@ConditionalOnBean(RedisConnectionFactory.class)`로 빈 생성 가드(권장 — 자동설정 제외 시 빈 미생성).

### 신규: RedisPropertiesTest ×2
- **shop-core**: `shop.redis.*` 바인딩 검증 — (a) yml 미지정 시 기본 prefix/TTL 폴백값(`shopcore:auth:refresh:` / `P14D` 등), (b) `@TestPropertySource` 또는 `ApplicationContextRunner`로 오버라이드 시 반영, (c) prefix가 `shopcore:`로 시작(namespace 격리 회귀 방지). Redis 미기동에서 동작(바인딩 단위 검증 또는 Redis 자동설정 제외 컨텍스트).
- **notification**: `notification.redis.dedup.*` 바인딩 검증 — 기본 `notif:dedup:` / `P3D`, 오버라이드 반영, prefix가 `notif:`로 시작 + **shop-core prefix(`shopcore:`) 토큰 부재**(교차 namespace 참조 0 회귀 방지). Redis 미기동에서 동작.
- 권장 구현 방식: `ApplicationContextRunner`로 `RedisProperties`만 바인딩(브로커 불요, 가장 가벼움). 또는 `@SpringBootTest` 사용 시 Redis 자동설정 제외 보장.

### 수정: docker-compose.yml — shop-redis 서비스
- 기존 패턴과 1:1 일관:
  - `image: redis:${REDIS_IMAGE_TAG:-7.4-alpine}`(latest 금지, 고정 태그 + .env 변수)
  - `container_name: shop-redis`
  - `ports: ["${REDIS_PORT:-6379}:6379"]`
  - `volumes: ["shop-redis-data:/data"]`(named volume — 기존 PG volume 패턴)
  - `healthcheck: ["CMD","redis-cli","ping"]`(interval/timeout/retries/start_period 기존 PG와 동일 스타일)
  - `networks: [shop-net]`, `restart: "no"`
  - 로컬 개발 전용 주석(운영 보안/클러스터 가장 금지 — AUTH/TLS 없음 명시). DB index 분리(shop-core 0 / notification 1) 주석으로 추적성 부여.
- volume 목록에 `shop-redis-data` 추가. 파일 상단 서비스 개수 주석 갱신.

### 수정: .env.example
- 추가 키(로컬 전용 주석):
  - `REDIS_IMAGE_TAG=7.4-alpine`(latest 금지)
  - `REDIS_PORT=6379`(충돌 시 변경 — 앱 yml의 `*_REDIS_PORT`도 함께 변경 필요 주석)
- SSOT(compose 기본값과 동기) 주석 패턴 유지. AUTH 비밀번호 없음(로컬 단일 Redis) 명시.

---

## 3. 데이터 흐름 (이 Task는 기반 — 향후 사용 개념 흐름)
> 실제 사용 코드(JWT/락/dedup 적용)는 후속 Task다. 아래는 prefix/TTL 설계가 어떻게 쓰일지의 개념 흐름이다.

### 3.1 shop-core — 로그인 상태 / blacklist / 분산락 (향후)
```
[로그인]   인증 성공 → SET shopcore:auth:refresh:{userId|jti} <refresh상태> EX P14D
[로그아웃] access 무효화 → SET shopcore:auth:blacklist:{jti} 1 EX (access 잔여만료)
[검증]     요청 → EXISTS shopcore:auth:blacklist:{jti} 이면 거부
[분산락]   SET shopcore:lock:{resource} <token> NX EX PT10S → 임계영역 → DEL(소유 토큰 확인 후)
```
(이 Task: prefix/TTL 설정 + StringRedisTemplate 빈 + RedisProperties까지. 위 명령 실행 코드는 후속.)

### 3.2 notification — dedup 1차 방어 + DB 권위 (향후)
```
이벤트 수신(eventId) → [1차] EXISTS notif:dedup:{eventId} ? 있으면 skip(빠른 방어)
                     → [권위] processed_event INSERT(event_id UNIQUE) 성공 시 처리
                     → SET notif:dedup:{eventId} 1 EX P3D (다음 재전송 빠른 차단)
Redis miss/장애여도 → processed_event UNIQUE가 최종 멱등 보장(정확성 무손상)
```
(이 Task: prefix/TTL 설정 + StringRedisTemplate 빈 + RedisProperties까지. Consumer/Service 변경 없음 — Constraint.)

### 3.3 격리 흐름(공통)
```
shop-core 앱  → localhost:6379 / DB 0 / shopcore:* 만 접근(상대 prefix 모름)
notification → localhost:6379 / DB 1 / notif:*    만 접근(상대 prefix 모름)
→ 동일 인스턴스라도 DB index + prefix로 keyspace 완전 분리(교차 read/통신 0)
```

---

## 4. 예외 처리 전략 (이 Task 범위: 컨텍스트/테스트 동작)
- **테스트 컨텍스트**: Redis 자동설정 제외(섹션 1.7)로 브로커 없이 컨텍스트/슬라이스/EmbeddedKafka 테스트가 통과. `RedisConfig`는 `@ConditionalOnBean(RedisConnectionFactory)`로 가드되어 자동설정 제외 시 빈 미생성 → 연결 시도 0.
- **로컬 런타임**: Lettuce는 지연 연결이라 앱 기동 자체는 Redis 미기동에서도 통상 부팅된다(실제 명령 실행 시점에 연결). 이 Task는 실행 코드가 없으므로 기동에 영향 없음.
- **실제 사용 Task에서의 fallback(방향만, 범위 밖)**: Constraint("Redis 장애가 주문/결제 흐름 전체를 가장하지 않도록")에 따라, 후속 사용 Task에서 (a) notification dedup은 Redis 장애 시 **DB processed_event 권위로 graceful degrade**(이미 본 설계가 보장), (b) 분산락/로그인 상태는 Redis 장애 시의 예외/타임아웃/대체 정책을 그 Task에서 명시 정의한다. 본 Task는 fallback 코드를 만들지 않고 **방향만 기록**한다.
- **커스텀 예외**: 본 Task는 Redis 연동 실행 코드가 없어 새 예외를 만들지 않는다. 후속 사용 Task에서 Redis 접근 실패를 각 프로젝트 `common.exception`의 `RuntimeException` 상속 커스텀 예외로 변환한다(공통 규칙).

---

## 5. 검증 방법

### 5.1 docker-compose 검증
```
docker compose -f docker/shop/docker-compose.yml config        # shop-redis 포함 렌더 + volume(shop-redis-data) + shop-net, 태그 고정(redis:7.4-alpine, latest 없음)
docker compose -f docker/shop/docker-compose.yml up -d
docker compose -f docker/shop/docker-compose.yml ps            # shop-redis running(healthy), 6379 매핑
docker exec -it shop-redis redis-cli ping                      # 기대: PONG
docker exec -it shop-redis redis-cli -n 0 dbsize / -n 1 dbsize # DB 0/1 분리 keyspace 확인(향후 사용 시)
```

### 5.2 자동 테스트
- `shop-core/`: `./gradlew test` — 기존 Modulith/security/contextLoads 그린(Redis 자동설정 제외로 비파괴) + `RedisPropertiesTest` 그린(prefix/TTL 바인딩·격리).
- `notification/`: `./gradlew test` — 기존 단위 + EmbeddedKafka(kafkatest, Redis 제외) + `EventProcessingServiceTransactionTest`(H2 슬라이스, Redis 비활성 보강) + `RedisPropertiesTest` 그린.

### 5.3 Acceptance Criteria ↔ 검증 매핑
| Acceptance | 검증 |
|---|---|
| docker-compose에 `shop-redis` 추가 | compose `shop-redis`(6379) — 5.1 config/ps |
| `compose config` 성공 | 5.1 config 오류 없이 렌더(태그 고정) |
| 두 프로젝트 Redis 의존성 보유 | build.gradle ×2 `spring-boot-starter-data-redis` |
| Redis 접속 설정 yml에서 추적 가능 | main yml ×2 `spring.data.redis`(host/port/database/timeout) |
| shop-core 용도(JWT 로그인 저장 + 분산락) 구분 | shop-core `shop.redis`(auth/lock) 블록 + 용도 주석 (1.4) |
| notification 용도(알림 중복 방지) 구분 | notification `notification.redis.dedup` 블록 + 주석 (1.5) |
| key prefix 프로젝트별 충돌 없음 | `shopcore:*` vs `notif:*` + DB 0/1 분리, RedisPropertiesTest 격리 검증 (1.2) |
| 테스트 프로파일 Redis 자동설정 처리 명확 | test yml ×2 + kafkatest yml + 슬라이스 테스트 보강(RedisAutoConfiguration 제외) (1.7) |
| 두 프로젝트 컨텍스트 테스트 통과 | 5.2 양 `./gradlew test` 그린 |
| Kafka 계약/DB 스키마 무변경 | 이벤트 DTO/토픽·Flyway V1 무변경(본 Task 미수정) |

---

## 6. 트레이드오프

- **Redisson 도입 vs 보류** — *채택: 보류(Spring Data Redis만).* (장) 사용처 0인 의존성/빈/설정 미증가, 테스트 비파괴 단순, YAGNI·Constraint 준수, 락 의미론을 구현 시점에 응집 결정. (단) 락 구현 Task에서 라이브러리 도입 작업이 발생. → 락 prefix/TTL 설계는 미리 남겨 후속 입력으로 제공.
- **logical DB 분리 vs prefix만** — *채택: 둘 다(이중 격리).* (장) 단일 로컬 Redis에서도 keyspace 물리 분리 + 코드상 prefix 미공유로 교차 접근 구조적 차단. (단) DB index 설정 1줄·운영에서 DB index 사용 비권장 논쟁 존재(운영은 인스턴스 분리가 정석). → 로컬 범위 한정, 운영은 host 분리로 전환 가능하게 환경변수화.
- **StringRedisTemplate vs RedisTemplate** — *채택: StringRedisTemplate.* (장) 본 용도(문자열+TTL)에 적합, redis-cli 가독·디버깅 용이, JDK 직렬화 회피. (단) 복잡 객체 캐싱엔 부적합 → 수요 발생 시 별도 `RedisTemplate<String,Object>`(JSON) 빈 추가.
- **prefix/TTL 설정화(@ConfigurationProperties) vs 상수** — *채택: 설정화(record).* (장) 환경별 오버라이드·테스트 검증 용이, `SecurityUserProperties` 패턴 일관. (단) 클래스/yml 증가 — 합리적 비용, Task가 "설계·정의"를 명시 요구.
- **테스트에서 Redis 끄기 vs Testcontainers** — *채택: 자동설정 제외(비파괴).* (장) 기존 테스트 비파괴, 범위 최소(YAGNI), 브로커 불요. (단) 실 Redis 연동이 CI에서 자동 검증되지 않음 → properties 격리는 단위 테스트로, 실 ping은 docker-compose 수동(5.1)로 보완. Testcontainers는 사용 코드가 생기는 후속 Task로 미룸.
- **단일 Redis vs 프로젝트별 Redis 인스턴스** — *채택: 로컬 단일 Redis + DB index/prefix 분리.* (장) 로컬 컨테이너 1개로 단순, 기존 인프라 경량 원칙 일관. (단) 운영 격리는 인스턴스 분리가 정석 → host 환경변수화로 운영 전환 경로 확보, 운영 보안/클러스터는 범위 밖 명시.

---

## Spring Boot / 인프라 컨벤션
- 패키지: 설정 클래스/Properties는 양 프로젝트 `common.config`(기존 `JpaAuditingConfig`/`SecurityUserProperties` 위치 규칙). 테스트는 `com.shop.{shop|notification}.common.config`.
- `@ConfigurationProperties` record + 컴팩트 생성자 기본값 폴백(`SecurityUserProperties` 패턴). TTL은 `Duration`(ISO-8601), 매직값/하드코딩 prefix 금지.
- yml은 기존 `${VAR:default}` 환경변수 디폴트 패턴 유지(host/port/database 변수화). 용도 주석 필수(Acceptance 용도 구분).
- docker-compose: `docker/shop/`, 이미지 태그 고정(latest 금지)+`.env` 변수화, `shop-net`/`restart:"no"`/healthcheck/named volume 기존 패턴 일관. 로컬 전용·운영 보안 가장 금지 주석.
- 격리: shop-core `shopcore:*`/DB0, notification `notif:*`/DB1. 상대 prefix 참조 코드 0(교차 통신/ read 금지). Kafka 계약·Flyway V1 무변경.
- 테스트 없이 의존성 변경 완료 금지 — RedisPropertiesTest 필수.

## 완료 조건 체크리스트
- [ ] 양 build.gradle에 `spring-boot-starter-data-redis` 추가(버전 BOM 위임), Redisson 미추가
- [ ] shop-core main yml: `spring.data.redis`(host/port/database=0/timeout) + `shop.redis`(auth refresh/blacklist + lock prefix·TTL) + 용도 주석
- [ ] notification main yml: `spring.data.redis`(host/port/database=1/timeout) + `notification.redis.dedup`(prefix·TTL) + 용도/역할구분 주석
- [ ] shop-core `RedisProperties`(record, `shop.redis`) + `RedisConfig`(StringRedisTemplate, @ConditionalOnBean 가드)
- [ ] notification `RedisProperties`(record, `notification.redis`) + `RedisConfig`(StringRedisTemplate, @ConditionalOnBean 가드)
- [ ] 양 test yml `RedisAutoConfiguration` + `RedisRepositoriesAutoConfiguration` 제외
- [ ] notification `application-kafkatest.yml` Redis 자동설정 제외(EmbeddedKafka 비파괴)
- [ ] notification `EventProcessingServiceTransactionTest` Redis 비활성 보강(exclude= 리셋 대응) — 필수
- [ ] 양 `RedisPropertiesTest`: 기본값/오버라이드/prefix 격리(상대 prefix 부재) 검증 (Redis 미기동 동작)
- [ ] docker-compose `shop-redis`(redis:7.4-alpine 변수화, 6379, healthcheck redis-cli ping, named volume shop-redis-data, shop-net, restart:"no", 로컬 전용 주석)
- [ ] `.env.example` `REDIS_IMAGE_TAG`/`REDIS_PORT` 추가(로컬 전용 주석, SSOT 동기)
- [ ] `compose config` 성공 + `up -d` 후 `redis-cli ping`=PONG + DB 0/1 분리 확인
- [ ] 양 `./gradlew test` 그린(기존 003/004/005 산출물·EmbeddedKafka·H2 슬라이스 비파괴)
- [ ] Redisson/분산락 적용 코드 0, JWT 발급검증 0, dedup 적용·Consumer 변경 0, Kafka 계약·Flyway V1 변경 0, 교차 prefix 참조 0

## 에이전트 분담
- 본 Task는 화면(view) 없음 → **backend-implementor 단독** 수행.
- **shop-core와 notification 두 레포에 걸친 인프라 작업**이며, 두 프로젝트의 build.gradle/main·test yml/`RedisProperties`/`RedisConfig`/테스트/compose/.env를 **한 에이전트가 일관 정책**(starter-only·StringRedisTemplate·prefix+DB index 격리·테스트 Redis 비활성·Redisson 보류)으로 처리한다.
- 구현 시 별도 확인 항목(메인 에이전트가 결과 취합): (1) `EventProcessingServiceTransactionTest`가 Redis 추가 후에도 그린인지(아니면 Redis 비활성 보강 적용), (2) `RedisConfig` `@ConditionalOnBean` 가드로 자동설정 제외 시 빈 미생성 확인, (3) refresh 키 식별자(userId vs jti)/blacklist 동적 TTL은 후속 JWT Task 확정(기본값으로 진행), (4) docker-compose에서 `redis-cli ping`=PONG + DB 0/1 keyspace 분리.

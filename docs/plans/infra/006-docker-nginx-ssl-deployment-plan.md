# 006 Plan — 단일 호스트 Docker Compose 배포 인프라 (nginx TLS 종단 + shop-core 멀티 인스턴스 LB + Let's Encrypt)

> Task: shop-core·notification을 Docker 컨테이너로 단일 호스트에 배포. shop-core 앞에 nginx로 SSL 종단 + 로드밸런싱.
> 산출물 위치: `docker/shop/` (docker-rule). 기존 로컬 dev compose(`docker/shop/docker-compose.yml`)는 **무변경 보존**, prod는 별도 `docker-compose.prod.yml`.
> 전제: 실 도메인 보유 + 공인 IP의 80/443 인바운드 개방(Let's Encrypt HTTP-01 챌린지 + HTTPS 서빙).
> 범위 가드(과도설계 금지): k8s·Vault·CI 파이프라인·오토스케일링·다중 호스트 swarm/오케스트레이터 **제외**. 단일 호스트 compose + 호스트 `.env` + 파일 마운트 KEK로 한정(사용자 확정).

---

## 0. 코드/설정 대조 (작업 트리 실측 — plan 근거)

### 0.1 빌드 산출물
- `shop-core/build.gradle`·`notification/build.gradle`: 둘 다 `id 'java'` + `org.springframework.boot 3.5.15-SNAPSHOT`, `group=com.shop`, `version=0.0.1-SNAPSHOT`, Java 21(`JavaLanguageVersion.of(21)`). Spring Boot plugin → `bootJar` 태스크가 `build/libs/{module}-0.0.1-SNAPSHOT.jar`(실행 가능) + `*-plain.jar`(라이브러리, **제외**) 생성. Dockerfile은 `*-SNAPSHOT.jar`(plain 아닌 것) 1개만 실행.
- shop-core는 `src/e2eTest`(Playwright) 소스셋 보유 — Docker 빌드에서는 **제외**(`-x test -x e2eTest`로 빌드 시간/네트워크 절약, 테스트는 별도 게이트에서 수행).

### 0.2 shop-core application.yml — env 오버라이드 키 (전수 확인, `shop-core/src/main/resources/application.yml`)
- DB: `SHOP_CORE_DB_URL`(기본 `jdbc:postgresql://localhost:5432/shop_core`), `SHOP_CORE_DB_USERNAME`, `SHOP_CORE_DB_PASSWORD`, `SHOP_CORE_HIKARI_MAX_POOL`(기본 30).
- Kafka: `SHOP_CORE_KAFKA_BOOTSTRAP`(기본 `localhost:9092`).
- Redis: `SHOP_CORE_REDIS_HOST`(기본 localhost), `SHOP_CORE_REDIS_PORT`(6379), `SHOP_CORE_REDIS_DB`(0).
- App: `SHOP_APP_BASE_URL`(기본 `http://localhost:8080`).
- **인증(기동 필수)**: `SHOP_SECURITY_JWT_SECRET`(기본 빈값 → 32자 미만이면 `JwtProperties` 검증 실패로 기동 실패), `SHOP_SECURITY_JWT_ISSUER`(shop-core), TTL `SHOP_SECURITY_JWT_ACCESS_TTL`(PT30M)/`SHOP_SECURITY_JWT_REFRESH_TTL`(P14D).
- **암호화(기동 필수)**: `SHOP_CRYPTO_KEK_FILE`(**기본값 없음** — `${SHOP_CRYPTO_KEK_FILE}`, 미설정 시 placeholder 미해결로 기동 실패). `CryptoProperties.kekFile`은 `java.nio.file.Path`, `EnvelopeEncryptionUtils.readKek`가 `Files.readString(kekFile, UTF_8).trim()`으로 **파일 경로에서** Base64 KEK를 읽음 → **read-only 볼륨 마운트**가 정확히 맞는 모델.
- 정적 자산: `SHOP_STORAGE_TYPE`(local), `SHOP_STORAGE_ROOT`(`./uploads`), `SHOP_STORAGE_ASSET_BASE_URL`(`http://localhost:8080`), `SHOP_STORAGE_PUBLIC_PREFIX`(`/assets`). `StaticResourceConfig`가 `type=local`일 때 `{public-prefix}/**`를 `file:{root}/`로 서빙 → **멀티 인스턴스는 업로드 파일을 공유 볼륨으로 마운트해야 어느 replica가 받아도 조회 가능**.
- actuator: `SHOP_CORE_MGMT_ENDPOINTS`(health,info,prometheus), `server.port: 8080`(고정).
- 스케줄러/SSE: `SHOP_ORDER_EXPIRY_*`, `SHOP_ADMIN_DASHBOARD_SSE_*`, `SHOP_SELLER_SALES_SSE_*`(기본 운영 활성). **멀티 인스턴스 주의**: 만료 스케줄러는 Redisson 분산락 리더 게이트(`shop.redis.lock`, Task 035)로 **한 노드만 실행** — 공유 Redis 전제. SSE는 노드 로컬 emitter(각 replica가 자기 연결만 push) — 본 plan은 이 동작을 변경하지 않으며, LB 라운드로빈으로 SSE도 어느 노드든 연결 가능(단 SSE는 long-lived 연결이라 nginx `proxy_read_timeout` 상향 필요 — §nginx).

### 0.3 notification application.yml (`notification/src/main/resources/application.yml`)
- `server.port`: `NOTIFICATION_PORT`(기본 8090). 업무 API 없음 — actuator 전용. **외부 노출 불요**(nginx 뒤 아님, 내부망만).
- DB: `NOTIFICATION_DB_URL`(기본 `jdbc:postgresql://localhost:5433/notification`), `NOTIFICATION_DB_USERNAME`, `NOTIFICATION_DB_PASSWORD`.
- Kafka: `NOTIFICATION_KAFKA_BOOTSTRAP`(localhost:9092), `NOTIFICATION_KAFKA_GROUP`(notification).
- Redis: `NOTIFICATION_REDIS_HOST`, `NOTIFICATION_REDIS_PORT`, `NOTIFICATION_REDIS_DB`(**1** — shop-core와 동일 Redis 인스턴스, DB index만 분리).
- 메일: `NOTIFICATION_MAIL_MODE`(기본 **log** — 소켓 미사용; 운영은 `smtp`), `NOTIFICATION_MAIL_FROM`, `SPRING_MAIL_HOST`/`PORT`/`USERNAME`/`PASSWORD`/`SMTP_AUTH`/`SMTP_STARTTLS`. **운영은 `NOTIFICATION_MAIL_MODE=smtp` + 실 SMTP 자격증명**(MEMORY: perf-test-notification-must-be-log-mode — 부하/테스트만 log, 운영은 실 SMTP). actuator `health.mail.enabled=false`(기동 시 SMTP 헬스 의존 없음).

### 0.4 기존 로컬 dev compose (`docker/shop/docker-compose.yml`) — 보존 대상
- 서비스 5개: `shop-core-postgres`(5432), `shop-notification-postgres`(5433→5432), `shop-kafka`(KRaft, 9092 EXTERNAL + 29092 INTERNAL `shop-kafka:29092`), `shop-kafka-ui`(8085), `shop-redis`(6379). 네트워크 `shop-net`(bridge). `restart: "no"`(로컬 일회성).
- **재사용 가능한 패턴**: KRaft Kafka 리스너 분리(INTERNAL `shop-kafka:29092` 컨테이너간 / EXTERNAL `localhost:9092` 호스트), PG healthcheck(`pg_isready`), Redis healthcheck(`redis-cli ping`), named volume. prod compose는 이 정의를 **그대로 차용하되 `restart` 정책·보안·앱/nginx 서비스만 추가**.
- **컨테이너 호스트명 매핑(핵심)**: 앱이 컨테이너 네트워크에서 인프라에 붙으려면 env를 컨테이너 호스트명으로 오버라이드 — DB `shop-core-postgres:5432`/`shop-notification-postgres:5432`(내부 포트는 5432), Kafka **`shop-kafka:29092`(INTERNAL 리스너)**, Redis `shop-redis:6379`. (로컬은 localhost·9092였음.)

### 0.5 052~054 cutover 결과 (검증됨 — 멀티 인스턴스 정합 근거)
- shop-core는 **STATELESS JWT 쿠키 인증**(054: View 체인 `sessionCreationPolicy(STATELESS)`, formLogin/세션 제거, JSESSIONID 미생성). API 체인은 원래 STATELESS. → **세션 스토어/스티키 세션 불요**, 라운드로빈으로 어느 replica든 처리. 054 검증에서 8080↔8081 2노드 인증 유지 실증.
- **전 replica 동일 `SHOP_SECURITY_JWT_SECRET` 필수**(self-contained JWT 교차검증). 불일치 시 A 발급 토큰을 B가 거부.
- **전 replica 동일 KEK 파일 필수**(`SHOP_CRYPTO_KEK_FILE`, 봉투암호화 일관성).
- **★ Secure 쿠키 하드코딩(`security/AuthCookies.java:53,71,87,93`)**: `writeTokens`/`writeAccess`/`clearTokens` 모두 `.secure(true)` **고정**. 운영 HTTPS에선 정상이나, **nginx가 TLS 종단 → 백엔드로는 평문 HTTP가 들어옴**. Secure 쿠키는 "보안 연결(https)"에서만 브라우저↔서버 왕복하는데, Spring이 요청을 https로 인식해야 `ResponseCookie` Secure 발급/`request.isSecure()` 일관성이 성립. → **`server.forward-headers-strategy=framework`(또는 `native`) + nginx `X-Forwarded-Proto: https` 필수**(§6). 미설정 시 Spring은 요청을 http로 인식 → `SHOP_APP_BASE_URL`이 https인데 절대 URL/리다이렉트가 http로 생성되거나 https↔http 혼선·리다이렉트 루프 위험. (054 plan §1.6도 "운영 HTTPS 전제, Secure 쿠키 정상 동작"을 전제로 기록.)
- `/actuator/health` permitAll(`SecurityConfig:74`, Task 036) → compose healthcheck·nginx upstream 헬스 프로브로 사용.

---

## 1. 설계 방식 · 이유

### 1.1 토폴로지 (사용자 확정: 단일 호스트 통합 compose)
인터넷 → **nginx(TLS 종단, 80/443 게시)** → `shop-core` N replica(라운드로빈, 포트 미게시) → 내부 인프라(`postgres×2`·`redis`·`kafka`). `notification`은 Kafka 컨슈머로 동작(외부 미노출). 모두 `docker-compose.prod.yml` 한 파일, 네트워크 `shop-net`.
- **이유**: shop-core가 STATELESS JWT(054)라 세션 복제·스티키 없이 라운드로빈 수평 확장 가능. 단일 호스트라 nginx upstream으로 충분(외부 LB/서비스메시 불요 — 과도설계 회피).

### 1.2 shop-core 멀티 인스턴스 방식 — **명시 복수 서비스 + 정적 upstream** 채택
세 후보 비교:
- (A) `docker compose up --scale shop-core=N`: 한 서비스 정의를 N개로 스케일. 컨테이너명이 `shop-core-1/2/...`로 자동 부여되나 **고정 호스트명이 아니라 nginx 정적 upstream에 못 박기 어렵다**. nginx가 Docker 내장 DNS(`shop-core`)를 resolver로 조회하면 N개 IP를 라운드로빈하나, nginx는 기동 시 1회만 DNS를 캐시 → 스케일 변동/재기동 시 stale. `resolver 127.0.0.11 + set $upstream + proxy_pass $upstream` 변수 방식이 필요(복잡·헬스체크 약함).
- (B) `deploy.replicas: N`: **compose(swarm 아님)에서는 `deploy.replicas`가 무시됨**(`docker compose up`은 deploy 키 대부분 미적용). swarm 전제 → 범위 밖. **탈락.**
- (C) **명시 복수 서비스**(`shop-core-1`, `shop-core-2`, …): 각 인스턴스를 개별 서비스로 선언, 고정 호스트명. nginx `upstream`에 `server shop-core-1:8080; server shop-core-2:8080;` 정적 등록. YAML 공유는 **앵커/별칭(`&shop-core-common` / `<<: *shop-core-common`)**으로 중복 제거(이미지/env/볼륨/healthcheck 공통, 컨테이너명만 차이).

**채택: (C) 명시 복수 서비스 + 정적 nginx upstream.**
- 근거: ① nginx **정적 upstream**이 가장 단순·안정(DNS resolver 변수 방식의 stale·디버깅 난이도 회피), ② nginx의 **passive 헬스체크**(`max_fails`/`fail_timeout`)와 정적 server가 정합, ③ 단일 호스트·소수 인스턴스(기본 2)라 명시 선언 비용이 낮고 YAML 앵커로 중복 제거됨, ④ 인스턴스별 컨테이너명이 고정되어 로그/디버깅·헬스 프로브가 명확. 스케일 변경은 "서비스 추가 + upstream 1줄 추가"로 드물게 수행(단일 호스트 운영 현실에 충분).
- 기본 **2 인스턴스**(`shop-core-1`/`shop-core-2`). 054에서 2노드 실증 완료. 더 필요 시 동일 패턴 복제.

### 1.3 Let's Encrypt 자동화 — **certbot(webroot) 사이드카 + nginx** 채택 (사용자가 nginx 지정 — Caddy 제외)
두 후보:
- (a) **nginx-proxy + acme-companion**: nginx 설정을 컨테이너 라벨로 자동 생성. 자동화 강력하나 **우리 upstream/프록시 헤더/타임아웃 커스터마이징을 라벨 환경에 종속**시키고, nginx.conf를 우리가 직접 못 쥐어 SSE 타임아웃·X-Forwarded 세밀 제어가 불편. 학습/디버깅 비용↑.
- (b) **certbot 사이드카(webroot) + 우리가 직접 쓴 nginx.conf**: nginx는 우리가 완전 제어(upstream·헤더·타임아웃). certbot이 webroot(`/.well-known/acme-challenge/`)에 챌린지 파일을 쓰고, nginx가 그 경로를 평문 80으로 서빙. 인증서는 공유 볼륨, certbot 컨테이너가 `certbot renew`를 주기 루프(예 12h)로 갱신, nginx는 갱신 후 `nginx -s reload`(또는 주기 reload)로 새 인증서 픽업.

**채택: (b) certbot webroot 사이드카.** 근거: nginx.conf 완전 제어가 본 과제 핵심 요구(shop-core LB upstream·X-Forwarded-Proto·SSE 타임아웃)와 직결 → 자동 생성형(a)보다 명시 제어가 안전·검증 용이. webroot 방식은 갱신 시 nginx 무중단(standalone은 80 점유 충돌). **최초 발급 부트스트랩 절차**(§5.3)로 "닭-달걀"(인증서 없으면 nginx 443 기동 실패) 해소.

### 1.4 시크릿 (사용자 확정: 호스트 `.env` + KEK 파일 마운트)
- `.env`(호스트, **gitignore** 확인 필요): JWT secret·DB 비밀번호×2·도메인·LE 이메일·SMTP 자격증명·이미지 태그 등. compose `env_file`/`environment`로 주입.
- **JWT secret**: 전 shop-core 서비스에 **동일 값** 주입(YAML 앵커 공통 env로 1곳 정의 → 두 서비스가 공유 → 불일치 불가능 구조).
- **KEK 파일**: 호스트의 단일 KEK 파일을 **read-only 볼륨**(`:ro`)으로 전 shop-core 서비스에 같은 컨테이너 경로(예 `/run/secrets/kek.b64`)로 마운트 → `SHOP_CRYPTO_KEK_FILE=/run/secrets/kek.b64`(공통 env). 한 파일을 공유하므로 봉투암호화 일관성 보장.

---

## 2. 구성 요소 (산출물 목록)

`docker/shop/` 하위:
- `Dockerfile.shop-core` — shop-core 멀티스테이지 빌드.
- `Dockerfile.notification` — notification 멀티스테이지 빌드.
- `.dockerignore`(각 모듈 빌드 컨텍스트용) — `build/`, `.git`, `node_modules`, IDE 파일, 로컬 `uploads/`, `.env` 제외(빌드 컨텍스트 슬림화·시크릿 유출 방지).
- `docker-compose.prod.yml` — nginx + shop-core×2 + notification + postgres×2 + redis + kafka(+ certbot 사이드카).
- `nginx/nginx.conf`(또는 `nginx/conf.d/shop.conf`) — TLS 종단·HTTP→HTTPS·upstream LB·프록시 헤더·SSE/타임아웃.
- `nginx/options-ssl-nginx.conf`(권장 TLS 파라미터) — certbot 제공 스니펫 또는 직접 작성.
- `.env.example` — 전 키 문서화(실 `.env`는 gitignore).
- (선택) `scripts/init-letsencrypt.sh` — 최초 인증서 발급 부트스트랩(임시 self-signed → certbot 발급 → reload). 단일 호스트 운영 편의용.

기존 `docker-compose.yml`(로컬 dev)·`docker-rule.md`는 **무변경**.

---

## 3. Dockerfile 설계 (×2, 멀티스테이지)

### 3.1 공통 패턴
- **stage 1 (build)**: `gradle:8.x-jdk21` 또는 `eclipse-temurin:21-jdk` + Gradle wrapper. 모듈 소스 복사 → `./gradlew :{module}:bootJar -x test -x e2eTest --no-daemon`. (레포가 모듈별 독립 빌드이므로 빌드 컨텍스트는 해당 모듈 디렉터리 루트. Gradle 캐시 레이어링 위해 `build.gradle`·`settings.gradle`·`gradle/` 먼저 복사 → 의존성 해석 캐시 → 소스 복사 순.)
- **stage 2 (runtime)**: `eclipse-temurin:21-jre`(슬림·JRE만 — corretto:21 대안 가능, temurin 채택: 경량·표준). build 산출물 `build/libs/{module}-0.0.1-SNAPSHOT.jar`(plain 제외) → `/app/app.jar` 복사.
- **비루트 유저**: `RUN useradd -r -u 1001 appuser` (또는 temurin 제공 비루트) → `USER appuser`. KEK 마운트·uploads 볼륨 권한을 이 UID에 맞춤.
- **JVM 옵션**: `ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-XX:+UseG1GC", "-jar", "/app/app.jar"]`. 컨테이너 메모리 한계 인식(`MaxRAMPercentage`)으로 OOM 회피. 가상스레드 미활성(CLAUDE.md — 현 단계 비활성, env로만).
- **포트 EXPOSE**: shop-core `8080`, notification `8090`(문서화 목적, 게시는 compose에서).
- **헬스체크**: Dockerfile `HEALTHCHECK`은 compose의 `healthcheck`로 통일(§4) — JRE 이미지에 curl 없을 수 있어 compose에서 `wget`/Spring actuator 활용 또는 `CMD-SHELL` 분기.

### 3.2 빌드 컨텍스트
- compose `build.context`는 각 모듈 루트(`../../shop-core`, `../../notification` 상대 — compose 파일이 `docker/shop/`에 있으므로). `dockerfile: ../docker/shop/Dockerfile.shop-core`. **결정**: 컨텍스트=모듈 루트, Dockerfile은 `docker/shop/`에서 참조. `.dockerignore`는 각 모듈 루트에 둠(`build/` 등 제외).

---

## 4. docker-compose.prod.yml 설계

### 4.1 서비스 구성
| 서비스(컨테이너명) | 이미지/빌드 | 포트 게시 | 역할 | restart |
|---|---|---|---|---|
| `shop-nginx` | nginx:1.27-alpine | **80:80, 443:443** | TLS 종단·LB·정적 챌린지 | `unless-stopped` |
| `shop-certbot` | certbot/certbot | (없음) | 인증서 발급/갱신 루프 | `unless-stopped` |
| `shop-core-1` | build Dockerfile.shop-core | 없음(내부 8080) | 앱 인스턴스 1 | `unless-stopped` |
| `shop-core-2` | (동일 이미지 재사용/앵커) | 없음(내부 8080) | 앱 인스턴스 2 | `unless-stopped` |
| `shop-notification` | build Dockerfile.notification | 없음(내부 8090) | Kafka 컨슈머·메일 | `unless-stopped` |
| `shop-core-postgres` | postgres:16.4-alpine | 없음 | shop-core DB | `unless-stopped` |
| `shop-notification-postgres` | postgres:16.4-alpine | 없음 | notification DB | `unless-stopped` |
| `shop-redis` | redis:7.4-alpine | 없음 | shop-core(DB0)+notification(DB1) | `unless-stopped` |
| `shop-kafka` | apache/kafka:3.8.1 | 없음(내부 29092만) | 이벤트 브로커 | `unless-stopped` |

- **컨테이너명은 docker-rule `shop-*`** 준수(`shop-core-1`은 `shop-` 접두). **prod는 같은 호스트에서 dev compose와 동시 기동하지 않음 전제**(같은 컨테이너명·포트). 운영 호스트엔 prod만 띄움.
- **포트 게시 최소화(보안)**: 앱/인프라는 호스트 포트 미게시(컨테이너 네트워크 내부만). 외부는 nginx 80/443만. (로컬 dev처럼 9092/5432를 호스트에 열지 **않음** — 공격 표면 축소.) DB는 디버깅 필요 시에만 한시적 게시.
- **이미지 1회 빌드 + 재사용**: shop-core-1을 `build:`로 정의하고 shop-core-2는 동일 `image:` 태그를 참조(앵커 `&shop-core-common`로 env/volume/healthcheck 공통, 두 서비스가 같은 빌드 이미지 공유 — 중복 빌드 방지). `SHOP_IMAGE_TAG` env로 태깅.

### 4.2 공통 앵커 (멀티 인스턴스 중복 제거 + 시크릿 동일 주입)
```yaml
x-shop-core-common: &shop-core-common
  image: shop-core:${SHOP_IMAGE_TAG:-latest}
  environment: &shop-core-env
    SHOP_CORE_DB_URL: jdbc:postgresql://shop-core-postgres:5432/${SHOP_CORE_DB_NAME}
    SHOP_CORE_DB_USERNAME: ${SHOP_CORE_DB_USER}
    SHOP_CORE_DB_PASSWORD: ${SHOP_CORE_DB_PASSWORD}
    SHOP_CORE_KAFKA_BOOTSTRAP: shop-kafka:29092
    SHOP_CORE_REDIS_HOST: shop-redis
    SHOP_CORE_REDIS_PORT: "6379"
    SHOP_CORE_REDIS_DB: "0"
    SHOP_SECURITY_JWT_SECRET: ${SHOP_SECURITY_JWT_SECRET}   # 전 replica 동일(앵커로 1곳 정의)
    SHOP_CRYPTO_KEK_FILE: /run/secrets/kek.b64              # 전 replica 동일 마운트 경로
    SHOP_APP_BASE_URL: https://${SHOP_DOMAIN}
    SHOP_STORAGE_ASSET_BASE_URL: https://${SHOP_DOMAIN}
    SHOP_STORAGE_ROOT: /app/uploads
    SERVER_FORWARD_HEADERS_STRATEGY: framework             # ★ X-Forwarded-* 인식(§6)
  volumes:
    - ./secrets/kek.b64:/run/secrets/kek.b64:ro   # KEK read-only(호스트 bind mount, 운영자 배치)
    - shop-uploads:/app/uploads           # 정적 자산 공유(멀티 인스턴스)
  depends_on:
    shop-core-postgres: { condition: service_healthy }
    shop-redis: { condition: service_healthy }
    shop-kafka: { condition: service_started }
  healthcheck:
    test: ["CMD-SHELL", "wget -qO- http://localhost:8080/actuator/health | grep -q UP || exit 1"]
    interval: 15s
    timeout: 5s
    retries: 5
    start_period: 60s     # Flyway 마이그레이션·컨텍스트 로드 여유
  restart: unless-stopped
  networks: [shop-net]

services:
  shop-core-1:
    <<: *shop-core-common
    container_name: shop-core-1
    build:
      context: ../../shop-core
      dockerfile: ../docker/shop/Dockerfile.shop-core
  shop-core-2:
    <<: *shop-core-common
    container_name: shop-core-2
    # build 없이 image 재사용(shop-core-1이 빌드한 동일 태그)
```
(JWT secret·KEK 경로가 앵커 `*shop-core-env` 1곳에 있어 **두 인스턴스가 구조적으로 동일** — 불일치 사고 방지.)

### 4.3 기동 순서 · 헬스체크 · 의존성
- **depends_on + condition**:
  - shop-core → postgres(`service_healthy`)·redis(`service_healthy`)·kafka(`service_started`). (KRaft 단일 노드는 `service_started`로 충분 — 컨슈머/프로듀서가 재시도.)
  - notification → notification-postgres(healthy)·redis(healthy)·kafka(started).
  - nginx → shop-core-1·shop-core-2(`service_started`로 족함 — nginx passive 헬스체크가 미준비 upstream을 회피; `service_healthy`로 묶으면 앱 기동 전 nginx가 안 떠 챌린지 80도 못 여는 부작용 → **nginx는 started 조건**).
  - certbot → nginx(started, webroot 공유).
- **healthcheck**: PG `pg_isready`, Redis `redis-cli ping`(로컬 dev 재사용), shop-core `/actuator/health` `UP` grep, notification `/actuator/health`(8090).
- **restart 정책**: 전 서비스 `unless-stopped`(운영 — dev의 `"no"`와 다름). 앱 크래시/호스트 재부팅 시 자동 복구.
- **재시작 정책의 한계 명시**: Flyway `baseline-on-migrate=false`·`ddl-auto=validate` → **DB는 첫 기동 시 깨끗해야** V1부터 적용. 멀티 인스턴스가 **동시 첫 기동** 시 Flyway 동시 마이그레이션 경합 가능 — Flyway는 `flyway_schema_history` 락으로 직렬화하나, 안전을 위해 **start_period 충분(60s) + 한 인스턴스 먼저 healthy 후 다음**을 권장(완전 보장 아님). 트레이드오프 §8.

### 4.4 볼륨 · 네트워크
- 볼륨: `shop-core-pg-data`, `notification-pg-data`, `shop-redis-data`(dev와 동일), `shop-uploads`(정적 자산 공유), `letsencrypt-certs`(`/etc/letsencrypt`), `certbot-webroot`(`/var/www/certbot`). Kafka 로그는 운영은 영속 권장(이벤트 유실 방지, `kafka-data` 추가).
- **KEK는 named volume이 아니라 호스트 bind mount**(`./secrets/kek.b64:/run/secrets/kek.b64:ro`) — 운영자가 호스트에 직접 배치, 파일 교체 용이. §4.2 앵커와 통일. **`docker/shop/secrets/`를 `.gitignore`·`.dockerignore`에 추가**(KEK 비커밋 — `.env`는 이미 무시됨).
- 네트워크: `shop-net`(bridge) — 컨테이너 DNS로 호스트명 해석(`shop-core-postgres`·`shop-kafka` 등).

---

## 5. nginx 설정

### 5.1 upstream (shop-core LB)
```nginx
upstream shop_core {
    server shop-core-1:8080 max_fails=3 fail_timeout=15s;
    server shop-core-2:8080 max_fails=3 fail_timeout=15s;
    # 기본 round-robin (STATELESS JWT라 sticky 불요 — 054 검증)
    keepalive 32;   # upstream keepalive로 커넥션 재사용
}
```
- **디스커버리**: 정적 upstream(컨테이너명=고정 호스트명, Docker DNS가 해석). resolver 변수 방식 불채택(§1.2 근거). **passive 헬스체크**: `max_fails`/`fail_timeout`로 죽은 노드 자동 회피. 한 노드 다운 시 라운드로빈이 살아있는 노드로만 분배.

### 5.2 server 블록
- **80 (HTTP)**: ① `/.well-known/acme-challenge/`는 `root /var/www/certbot;`로 서빙(LE 챌린지·갱신). ② 그 외 전부 `return 301 https://$host$request_uri;`(HTTPS 강제).
- **443 (HTTPS, TLS 종단)**:
  - `ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem; ssl_certificate_key .../privkey.pem;` + `options-ssl-nginx.conf`(TLS1.2/1.3·강 cipher) + `ssl_dhparam`.
  - **프록시 헤더(★ Spring https 인지)**:
    ```nginx
    location / {
        proxy_pass http://shop_core;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;   # ★ Secure 쿠키·https URL 인지
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port 443;
        proxy_http_version 1.1;
        proxy_set_header Connection "";              # upstream keepalive
    }
    ```
  - **정적 자산**: `/assets/`(또는 `SHOP_STORAGE_PUBLIC_PREFIX`)도 동일 `proxy_pass http://shop_core`(앱이 `StaticResourceConfig`로 서빙, 공유 볼륨). 추후 R2/CDN 이관 시 이 location만 교체.
  - **SSE 타임아웃(★ 대시보드/판매자 SSE)**: SSE location 또는 전역에 `proxy_read_timeout 3600s; proxy_buffering off;`. SSE 30분 타임아웃보다 nginx read timeout이 커야 조기 절단 방지.
  - 업로드 바디 크기: `client_max_body_size 30M;`(앱 `multipart.max-request-size=30MB`와 정합).
  - 일반 타임아웃: `proxy_connect_timeout 5s; proxy_send_timeout 60s;`.

### 5.3 최초 발급 닭-달걀 해소
443 server는 인증서 파일이 있어야 nginx가 기동된다. **부트스트랩**: ①최초엔 임시 self-signed로 443 기동(또는 80만 먼저) → ②certbot webroot로 실 인증서 발급(80 챌린지) → ③실 인증서로 교체 후 `nginx -s reload`. `scripts/init-letsencrypt.sh`가 이 순서를 자동화(certbot 공식 nginx-certbot 레시피 패턴). 이후 갱신은 certbot 컨테이너 루프(`trap exit TERM; while :; do certbot renew; sleep 12h & wait; done`) + nginx 주기 reload.

---

## 6. Spring profile / 운영 설정 오버라이드

- **`SERVER_FORWARD_HEADERS_STRATEGY=framework`(필수)**: nginx TLS 종단이라 앱은 평문 HTTP 수신. `X-Forwarded-Proto=https`를 Spring이 신뢰해 `request.isSecure()=true`·`scheme=https`로 인식 → Secure 쿠키(`AuthCookies` 하드코딩 `.secure(true)`)가 정상 동작하고, 절대 URL/리다이렉트가 https로 생성됨. (application.yml엔 현재 미설정 → **env로 주입**.)
- **`SHOP_APP_BASE_URL`/`SHOP_STORAGE_ASSET_BASE_URL`=`https://${DOMAIN}`**: 메일 링크·자산 절대 URL이 https 도메인으로 생성.
- **Secure 쿠키**: 코드 하드코딩이라 별도 토글 불요(운영 https 전제).
- **JWT secret/KEK**: §1.4·§4.2 — 전 replica 동일.
- **DB/Kafka/Redis 호스트**: §4.2 컨테이너 호스트명.
- **notification 운영**: `NOTIFICATION_MAIL_MODE=smtp` + `SPRING_MAIL_*`(실 SMTP). `NOTIFICATION_DB_URL=jdbc:postgresql://shop-notification-postgres:5432/...`, `NOTIFICATION_KAFKA_BOOTSTRAP=shop-kafka:29092`, `NOTIFICATION_REDIS_HOST=shop-redis`(DB1).
- **Hikari/스케줄러**: 기본값 유지(`SHOP_CORE_HIKARI_MAX_POOL=30`). 멀티 인스턴스 총 커넥션(2×30=60) < PG `max_connections`(기본 100) 확인 — `.env`로 PG `max_connections` 또는 풀 크기 조정 가능.

---

## 7. 데이터 흐름

**요청 경로(인증된 사용자)**: 인터넷 → `https://${DOMAIN}` → shop-nginx(443 TLS 종단·복호화) → `X-Forwarded-Proto=https` 부여 → upstream `shop_core` 라운드로빈 → shop-core-1 **또는** shop-core-2(어느 쪽이든 동일 JWT secret으로 `access_token` 쿠키 검증, `forward-headers`로 https 인식). 다음 요청이 다른 replica로 가도 self-contained JWT라 인증 유지(스티키 불요).

**TLS 발급/갱신**: certbot → webroot(`/var/www/certbot`) 챌린지 파일 → nginx 80이 `/.well-known/acme-challenge/` 서빙 → LE 검증 → 인증서를 `letsencrypt-certs` 볼륨에 기록 → nginx reload로 픽업.

**이벤트 경로(비동기)**: shop-core(어느 replica든) → Spring Modulith 외부화 → KafkaTemplate → `shop-kafka:29092`(INTERNAL 리스너) → notification 컨슈머(group `notification`) 소비 → DB 멱등 기록(`processed_event`) + 메일 발송(SMTP, 운영 모드). shop-core↔notification **동기 호출·DB 공유 없음**(CLAUDE.md).

**암호화**: shop-core 각 replica가 동일 `/run/secrets/kek.b64`(read-only)에서 KEK 로드 → 봉투암호화 일관(어느 replica가 암호화한 데이터를 다른 replica가 복호화 가능).

---

## 8. 예외 · 실패 처리 + 트레이드오프

- **앱 크래시**: `restart: unless-stopped` 자동 재시작. nginx passive 헬스체크(`max_fails`)로 다운 노드 자동 격리 → 살아있는 replica로 무중단(부분 가용).
- **기동 순서**: `depends_on: condition: service_healthy`(DB·Redis) — 인프라 준비 후 앱 기동. 앱 `start_period 60s`로 Flyway·컨텍스트 로드 여유.
- **JWT secret/KEK 불일치**: 앵커 공통 env·단일 KEK 파일 마운트로 **구조적 차단**(불일치 불가능).
- **인증서 만료**: certbot 갱신 루프(12h) + nginx reload. LE 90일 만료 전 자동 갱신.
- **DB 첫 기동 Flyway 경합(멀티 인스턴스)**: `flyway_schema_history` 락으로 직렬화되나 동시 첫 기동은 비권장 — start_period·passive 헬스로 완화. **트레이드오프**: 완전 무경합 보장하려면 마이그레이션 전용 단발 잡 분리가 정석이나 단일 호스트 소규모엔 과도 → 락 직렬화 신뢰 + 운영 시 "한 노드 먼저 up 후 scale" 절차 권고.
- **트레이드오프 정리**:
  - 명시 복수 서비스(C) vs `--scale`(A): C는 스케일 변경 시 YAML 수정 필요(수동) — 단일 호스트 소수 인스턴스라 수용. 정적 upstream의 단순·안정성이 이득.
  - certbot webroot(b) vs nginx-proxy(a): b는 부트스트랩 1회 수작업(닭-달걀) — nginx 완전 제어 이득이 더 큼.
  - 정적 자산 앱 경유(공유 볼륨): 멀티 인스턴스 공유 볼륨 I/O 부담·R2 이관 전 임시 — 현 단계 단순성 우선(추후 nginx 직접 서빙 또는 R2/CDN).
  - 단일 호스트 SPOF: k8s/다중 호스트 미도입(범위 밖). 가용성은 앱 replica 수준만 — 사용자 확정 범위.
  - SSE long-lived + 라운드로빈: SSE는 연결된 노드에만 push(노드 로컬 emitter). 노드 다운 시 그 노드 SSE 연결 끊김 → 브라우저 재연결(EventSource 자동) → 다른 노드 연결. 본 plan은 동작 변경 없음(명시만).

---

## 9. 검증 방법

1. **빌드**: `docker compose -f docker/shop/docker-compose.prod.yml build` 성공(shop-core·notification 이미지 생성, plain jar 제외 실행 jar 확인).
2. **기동**: `docker compose ... up -d` → 전 서비스 `healthy`(`docker compose ps`). depends_on 순서로 인프라→앱→nginx.
3. **TLS**: `https://${DOMAIN}` 접속 → 유효 인증서(브라우저 자물쇠, `openssl s_client -connect ${DOMAIN}:443` 체인 확인). `http://${DOMAIN}` → 301 https. `/.well-known/acme-challenge/` 서빙 확인.
4. **멀티 인스턴스 라운드로빈 + 인증 유지(★ 핵심)**: 로그인(`access_token` 쿠키 발급) 후 보호 페이지 반복 요청 → nginx가 shop-core-1/2 번갈아 라우팅(컨테이너 로그로 분배 확인)해도 **인증 유지**(054 self-contained JWT 실증과 동일). 한 인스턴스 stop → 나머지로 무중단(passive 헬스체크).
5. **forward-headers/Secure 쿠키**: 응답 `Set-Cookie`에 `Secure` 속성 + https에서 쿠키 정상 왕복(http 리다이렉트 루프 없음). 앱 로그/리다이렉트 URL이 https.
6. **이벤트 소비(notification)**: shop-core에서 이벤트 유발(예 회원가입) → notification 컨슈머 로그에 소비 기록 + (운영 SMTP면) 메일 발송. Kafka `shop-kafka:29092` 내부 연결 확인.
7. **헬스체크**: `/actuator/health` UP(shop-core 각 노드·notification). compose healthcheck green.
8. **KEK 공유**: 두 shop-core가 동일 KEK 경로 마운트(`:ro`) → 암복호화 교차 동작.
9. **갱신 dry-run**: `docker compose exec shop-certbot certbot renew --dry-run` 성공.
10. **로컬 dev compose 무회귀**: 기존 `docker-compose.yml`이 그대로 동작(prod와 별 파일·별 호스트 전제 확인).

---

## 10. Non-goals (범위 밖 — 과도설계 금지)
- k8s·docker swarm·서비스메시·외부 LB·오토스케일링·다중 호스트.
- HashiCorp Vault·KMS·시크릿 매니저(사용자 확정: 호스트 `.env` + KEK 파일 마운트).
- CI/CD 파이프라인·이미지 레지스트리 푸시 자동화(로컬/호스트 빌드).
- R2/CDN 정적 자산 이관(현 단계 앱 경유 — 추후 별 task).
- refresh 토큰 회전·DB 마이그레이션 전용 잡 분리·Kafka 멀티 브로커.
- 코드 변경(앱은 env 오버라이드만으로 동작 — 단, §0.5 `forward-headers-strategy`가 yml에 없어 **env 주입으로 충족**. 만약 env로 안 먹는 특이 케이스가 검증에서 드러나면 그때 최소 코드/yml 보강을 별 항목으로).

---

## 11. 오케스트레이션 (산출물 분담)

본 작업은 **인프라 설정 파일(Dockerfile·compose·nginx·.env.example)** 위주로, 애플리케이션 코드 변경이 없다(env 오버라이드만). 코드 implementor(backend/view)의 도메인이 아니므로 **메인이 직접 작성**하는 것을 기본으로 한다.

1. **메인 직접 작성(인프라 파일)**:
   - `docker/shop/Dockerfile.shop-core`·`Dockerfile.notification`(멀티스테이지·비루트·JVM 옵션).
   - `docker/shop/docker-compose.prod.yml`(앵커·서비스·healthcheck·depends_on·볼륨·네트워크).
   - `docker/shop/nginx/nginx.conf`(upstream·TLS·헤더·SSE 타임아웃)·`options-ssl-nginx.conf`.
   - `docker/shop/.env.example`·`.dockerignore`·`scripts/init-letsencrypt.sh`.
   - 실 `.env`는 사용자가 호스트에 생성(gitignore — 커밋 금지). KEK 파일은 사용자가 호스트에 배치.
2. **backend-implementor(조건부·최소)**: 검증(§9-5)에서 `SERVER_FORWARD_HEADERS_STRATEGY` env 주입만으로 Secure 쿠키/https 인식이 충족되지 **않는** 케이스가 드러나면, 그때 `application.yml`에 `server.forward-headers-strategy` 기본값 추가 또는 SecurityConfig 보강을 **별도 최소 변경**으로 위임.
3. **reviewer → (FAIL 시) fixer → 재리뷰**: 중점 — ① JWT secret·KEK가 전 replica 동일(앵커·마운트 구조), ② nginx X-Forwarded-Proto + forward-headers 정합(Secure 쿠키), ③ 컨테이너 호스트명 매핑표 정확(kafka **29092 INTERNAL**, DB 5432 내부, redis DB index), ④ 멀티 인스턴스 정적 upstream·라운드로빈(스티키 없음), ⑤ depends_on/healthcheck 기동 순서, ⑥ LE 닭-달걀 부트스트랩, ⑦ 로컬 dev compose 무회귀(별 파일·docker-rule `shop-*`·`docker/shop/` 위치), ⑧ 시크릿 비커밋(.dockerignore·.env gitignore).
4. **사용자 검증 게이트**: 실 도메인·공인 80/443·KEK 파일·`.env`는 사용자 호스트 환경 의존 → compose up·TLS·라운드로빈·이벤트 소비(§9)는 사용자 호스트에서 실측 필요.

---

## 12. 완료 조건
- [ ] `Dockerfile.shop-core`·`Dockerfile.notification`: 멀티스테이지(Gradle 빌드→temurin:21-jre), 비루트, bootJar(plain 제외) 실행, JVM 옵션, build 성공.
- [ ] `docker-compose.prod.yml`: nginx + shop-core×2(앵커 공통 env·정적 upstream 정합) + notification + postgres×2 + redis + kafka + certbot, `shop-net`, depends_on+healthcheck 기동 순서, `unless-stopped`, KEK `:ro` + uploads 공유 볼륨.
- [ ] nginx: TLS 종단·80→443 리다이렉트·`/.well-known` 챌린지·shop-core 정적 upstream 라운드로빈·X-Forwarded-Proto https·SSE 타임아웃·`client_max_body_size 30M`.
- [ ] Let's Encrypt: certbot webroot 사이드카·인증서 볼륨·갱신 루프·최초 발급 부트스트랩 스크립트·도메인/이메일 env.
- [ ] `.env.example`: JWT secret·KEK 경로·DB 비번×2·도메인·LE 이메일·SMTP·이미지 태그 등 전 키. 실 `.env`·KEK는 gitignore/미커밋.
- [ ] 시크릿: JWT secret 전 replica 동일(앵커), KEK 단일 파일 read-only 전 replica 마운트.
- [ ] Spring: `SERVER_FORWARD_HEADERS_STRATEGY=framework` + 컨테이너 호스트명 env + https base-url 오버라이드.
- [ ] 검증: compose up·https 인증서·로그인 후 멀티 replica 라운드로빈 인증 유지·notification 이벤트 소비·헬스체크·로컬 dev 무회귀.

---

## 13. 컨테이너 호스트명 / env 매핑표 (구현 참조 SSOT)

| 앱 env 키 | 로컬 기본값 | **prod 컨테이너 값** | 비고 |
|---|---|---|---|
| `SHOP_CORE_DB_URL` | `jdbc:postgresql://localhost:5432/shop_core` | `jdbc:postgresql://shop-core-postgres:5432/${SHOP_CORE_DB_NAME}` | 내부 포트 5432 |
| `SHOP_CORE_DB_USERNAME`/`_PASSWORD` | shop_core | `.env` | 운영 자격증명 |
| `SHOP_CORE_KAFKA_BOOTSTRAP` | `localhost:9092` | **`shop-kafka:29092`** | INTERNAL 리스너(컨테이너간) |
| `SHOP_CORE_REDIS_HOST`/`PORT`/`DB` | localhost/6379/0 | `shop-redis`/6379/**0** | DB index 0 |
| `SHOP_SECURITY_JWT_SECRET` | (빈값→기동실패) | `.env`(전 replica 동일·앵커) | ≥32자 필수 |
| `SHOP_CRYPTO_KEK_FILE` | (미설정→기동실패) | `/run/secrets/kek.b64`(ro 마운트) | Base64 AES-256 KEK |
| `SHOP_APP_BASE_URL`/`SHOP_STORAGE_ASSET_BASE_URL` | `http://localhost:8080` | `https://${SHOP_DOMAIN}` | https 절대 URL |
| `SHOP_STORAGE_ROOT` | `./uploads` | `/app/uploads`(공유 볼륨) | 멀티 인스턴스 공유 |
| `SERVER_FORWARD_HEADERS_STRATEGY` | (yml 미설정) | **`framework`** | nginx TLS 종단 인식 |
| `NOTIFICATION_DB_URL` | `...localhost:5433/notification` | `jdbc:postgresql://shop-notification-postgres:5432/...` | 내부 5432 |
| `NOTIFICATION_KAFKA_BOOTSTRAP` | `localhost:9092` | **`shop-kafka:29092`** | INTERNAL |
| `NOTIFICATION_REDIS_HOST`/`DB` | localhost/**1** | `shop-redis`/**1** | DB index 1 |
| `NOTIFICATION_MAIL_MODE` | log | **smtp**(운영) | 실 SMTP |
| `SPRING_MAIL_HOST`/`USERNAME`/`PASSWORD` 등 | 빈/false | `.env`(운영 SMTP) | |

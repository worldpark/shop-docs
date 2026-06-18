# shop Docker Compose (로컬 dev / 운영 배포)

이 디렉터리는 두 개의 Compose 파일을 둔다.

- **`docker-compose.yml`** — 로컬 개발 전용. 앱(shop-core, notification)은 IDE에서 직접 실행하고, 이 Compose는 인프라(PostgreSQL x2, Kafka x1, Redis)만 담당한다. (아래 "기동 절차"부터)
- **`docker-compose.prod.yml`** — 운영 단일 호스트 배포(nginx TLS 종단/LB + shop-core×2 + notification + 인프라 + certbot). ("운영 배포" 섹션 참고)

아래 로컬 dev 절차 문서가 먼저 오고, 운영 배포 절차는 별도 섹션에 정리한다.

---

## 컨테이너 · 포트 · 볼륨 추적표

| 서비스 / 컨테이너명 | 이미지 (고정 태그) | 호스트:컨테이너 포트 | Named Volume | 네트워크 |
|---|---|---|---|---|
| shop-core-postgres | postgres:16.4-alpine | 5432:5432 | shop-core-pg-data | shop-net |
| shop-notification-postgres | postgres:16.4-alpine | 5433:5432 | notification-pg-data | shop-net |
| shop-kafka | apache/kafka:3.8.1 | 9092:9092 (EXTERNAL) | 없음 (임시) | shop-net |

**미게시 포트** (컨테이너 네트워크 전용):
- 9093: CONTROLLER 리스너 — KRaft 메타데이터 쿼럼 전용
- 29092: INTERNAL 리스너 — 컨테이너 간 브로커 통신

## 앱 ↔ 인프라 정합표

| 앱 | 설정 키 | 기본값 | compose 엔드포인트 |
|---|---|---|---|
| shop-core | datasource.url | jdbc:postgresql://localhost:5432/shop_core | shop-core-postgres :5432 |
| shop-core | kafka.bootstrap-servers | localhost:9092 | shop-kafka EXTERNAL :9092 |
| notification | datasource.url | jdbc:postgresql://localhost:5433/notification | shop-notification-postgres :5432 (호스트 5433) |
| notification | kafka.bootstrap-servers | localhost:9092 | shop-kafka EXTERNAL :9092 |

---

## 사전 요구사항

- Docker Desktop (또는 Docker Engine) 실행 중
- 호스트 포트 5432, 5433, 9092 미점유

---

## 기동 절차

```bash
# 작업 위치: shop/ 루트

# 1. (선택) .env 파일 준비 — 없으면 compose 기본값으로 기동
cp docker/shop/.env.example docker/shop/.env
# 필요 시 .env의 포트/자격증명 수정

# 2. compose 설정 유효성 확인
docker compose -f docker/shop/docker-compose.yml config

# 3. 컨테이너 기동
docker compose -f docker/shop/docker-compose.yml up -d

# 4. 상태 확인
docker compose -f docker/shop/docker-compose.yml ps
```

기대 결과: `3개 컨테이너 running` (shop-core-postgres, shop-notification-postgres는 healthy; shop-kafka는 running)

---

## 검증 절차

### PG 분리 확인

```bash
# shop-core DB 확인
docker exec shop-core-postgres psql -U shop_core -d shop_core -c "\l"

# notification DB 확인
docker exec shop-notification-postgres psql -U notification -d notification -c "\l"

# volume 분리 확인
docker volume ls | findstr "pg-data"
# 출력 예시:
#   local     docker_shop-core-pg-data      (또는 프로젝트명 prefix)
#   local     docker_notification-pg-data
```

### Kafka KRaft 브로커 응답 확인

```bash
# 브로커 API 버전 응답 (정상 기동 확인)
docker exec shop-kafka /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092

# (선택) KRaft 메타데이터 쿼럼 상태 확인 — 단일 voter, leader=1 기대
docker exec shop-kafka /opt/kafka/bin/kafka-metadata-quorum.sh \
  --bootstrap-server localhost:9092 describe --status
```

### KRaft cluster id 자동 포맷 확인

첫 기동 시 Kafka 로그에서 자동 포맷 여부를 확인한다:

```bash
docker compose -f docker/shop/docker-compose.yml logs shop-kafka 2>&1 | head -50
```

**후보 A (자동 포맷 — 본 구성 채택)**: 로그에 `Formatting ...` 또는 cluster id 자동 생성 메시지가 나타나면 정상. `KAFKA_CLUSTER_ID` 환경변수 불필요.

**후보 B (수동 cluster id — 자동 포맷 실패 시 전환)**: 로그에 `Storage directory ... is not formatted` 등이 나오면:
1. `.env.example`의 `KAFKA_CLUSTER_ID` 주석 해제 후 UUID 입력
2. `docker compose ... down` 후 `docker compose ... up -d`
3. 이 경우 kafka 로그 디렉터리에 named volume 추가 권장 (재포맷 충돌 방지)

---

## 중지 / 데이터 초기화

```bash
# 중지 (데이터 보존)
docker compose -f docker/shop/docker-compose.yml down

# 중지 + 볼륨 삭제 (데이터 초기화 — PG 데이터도 삭제됨)
docker compose -f docker/shop/docker-compose.yml down -v
```

---

## 포트 충돌 시

호스트 포트(5432/5433/9092)가 다른 프로세스에 점유된 경우:

1. `.env.example`을 `.env`로 복사
2. `SHOP_CORE_DB_PORT`, `NOTIFICATION_DB_PORT`, `KAFKA_EXTERNAL_PORT` 변경
3. **주의**: `KAFKA_EXTERNAL_PORT`를 변경하면 앱의 `bootstrap-servers` 설정도 함께 변경해야 함 (EXTERNAL advertised listener와 일치 필요)
4. `docker compose ... up -d` 재실행

---

## 운영 배포 (docker-compose.prod.yml)

> 위 절차는 **로컬 dev(`docker-compose.yml`) 전용**이다. 운영 단일 호스트 배포는 별 파일 `docker-compose.prod.yml`을 쓴다.
> 구성: nginx(TLS 종단/LB) + shop-core×2(STATELESS JWT) + notification + 인프라(PG×2·Kafka·Redis) + certbot.
> dev 스택과 **같은 호스트에서 동시 기동 금지**(컨테이너명/포트 충돌).

### 사전 요구사항 (운영)

- 호스트에 `docker/shop/.env` 작성 (`​.env.prod.example` 참고 — `SHOP_DOMAIN`, `LETSENCRYPT_EMAIL`, DB 자격증명, `SHOP_SECURITY_JWT_SECRET` 등). 커밋 금지.
- `docker/shop/secrets/kek.b64` 배치 (Base64 AES-256 KEK). 커밋 금지.
  - 생성 예: `head -c 32 /dev/urandom | base64 > docker/shop/secrets/kek.b64`
- 앱 소스 레포가 형제 경로에 존재 (`../../shop-core`, `../../notification` — build context).
- 도메인 DNS가 이 호스트의 공인 IP를 가리키고, **80/443 인바운드 개방** (Let's Encrypt HTTP-01 챌린지에 80 필수).

### 최초 1회: TLS 인증서 부트스트랩

nginx 443은 인증서 파일이 있어야 기동하므로(닭-달걀), 최초 발급은 전용 스크립트로 한다.

```bash
cd docker/shop
chmod +x scripts/init-letsencrypt.sh
./scripts/init-letsencrypt.sh           # 더미 인증서 → nginx 기동 → webroot 실 인증서 발급 → reload
# 발급 테스트(레이트리밋 회피)는 STAGING=1 ./scripts/init-letsencrypt.sh
```

> **이미 발급된 뒤에는 재실행하지 말 것.** 재발급은 Let's Encrypt 레이트리밋만 소모한다.
> 갱신은 `shop-certbot` 컨테이너(12h 루프)가 자동 처리한다.

### 재빌드 & 배포 (반복 절차)

작업 위치: `docker/shop/`

```bash
cd docker/shop

# 1. 최신 소스 반영 (앱 레포는 별도 git)
git -C ../../shop-core pull
git -C ../../notification pull

# 2. 재빌드 + 배포 (변경된 서비스만 재생성)
docker compose -f docker-compose.prod.yml up -d --build --remove-orphans

# 3. 상태 확인 (shop-core-1/2, shop-notification 이 healthy 여야 정상)
docker compose -f docker-compose.prod.yml ps

# 4. 로그 확인 (Flyway 마이그레이션 + 기동)
docker compose -f docker-compose.prod.yml logs -f shop-core-1 shop-notification
```

- `up -d --build`는 빌드 섹션이 있는 `shop-core-1`·`shop-notification` 이미지를 다시 굽고, 변경된 컨테이너만 재생성한다. PG/Kafka/Redis/nginx/certbot 등 안 바뀐 건 그대로 유지된다.
- `shop-core-2`는 build 없음 — `shop-core-1`이 구운 `shop-core:${SHOP_IMAGE_TAG}` 이미지를 재사용한다.
- `--remove-orphans`: dev 스택 잔여 컨테이너(`shop-kafka-ui` 등)가 같은 프로젝트명으로 섞여 있으면 정리한다.

### (선택) 무중단에 가까운 롤링 배포

shop-core 두 인스턴스를 동시에 재생성하면 짧은 단절이 생긴다(nginx가 `max_fails`/`fail_timeout`로 우회하긴 함). 한 대씩 굴리면 단절을 줄인다.

```bash
# 이미지만 먼저 빌드 (컨테이너 교체 없음)
docker compose -f docker-compose.prod.yml build shop-core-1

# 한 대씩 새 이미지로 교체
docker compose -f docker-compose.prod.yml up -d --no-deps --force-recreate shop-core-1
#   shop-core-1 healthy 확인 후
docker compose -f docker-compose.prod.yml up -d --no-deps --force-recreate shop-core-2
```

### 배포 검증 (운영)

```bash
# 앱 헬스
docker compose -f docker-compose.prod.yml exec shop-core-1 wget -qO- http://localhost:8080/actuator/health

# 외부 HTTPS (302 = 로그인 리다이렉트, 정상)
curl -sk -o /dev/null -w "%{http_code}\n" https://${SHOP_DOMAIN:-kimjr.store}/

# 인증서 발급자/만료 확인 (Let's Encrypt 여야 정상)
echo | openssl s_client -connect localhost:443 -servername ${SHOP_DOMAIN:-kimjr.store} 2>/dev/null \
  | openssl x509 -noout -issuer -dates
```

---

## 보안 주의사항

- 이 Compose는 **로컬 개발 전용**이다. 자격증명(shop_core/notification)은 명백히 로컬용 약한 값이다.
- 실제 `.env` 파일은 `.gitignore`에 등록하여 커밋하지 않는다.
- 운영 환경에서는 시크릿 매니저, TLS/SASL, 강한 패스워드를 사용한다 (본 Task 범위 밖).

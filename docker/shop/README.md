# 로컬 인프라 Docker Compose

로컬 개발 환경 전용. 앱(shop-core, notification)은 IDE에서 직접 실행하고, 이 Compose는 인프라(PostgreSQL x2, Kafka x1)만 담당한다.

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

## 보안 주의사항

- 이 Compose는 **로컬 개발 전용**이다. 자격증명(shop_core/notification)은 명백히 로컬용 약한 값이다.
- 실제 `.env` 파일은 `.gitignore`에 등록하여 커밋하지 않는다.
- 운영 환경에서는 시크릿 매니저, TLS/SASL, 강한 패스워드를 사용한다 (본 Task 범위 밖).

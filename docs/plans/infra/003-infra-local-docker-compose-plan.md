# 003. 로컬 인프라 docker-compose — 구현 Plan (Rev. KRaft)

> Revision 이력: 초판은 Zookeeper 모드(confluentinc/cp-*)였다. 사용자 결정으로 **Kafka KRaft 단일 노드(Zookeeper 제거)**로 개정한다.
> 명세-구현 불일치 명시(CLAUDE.md "설계와 다르게 구현 시 이유 명시"): **Task Requirements는 "Zookeeper 컨테이너 추가"를 명시하나, 본 Plan은 KRaft를 채택한다.** 사유 — Zookeeper는 Kafka 3.5에서 deprecated, 4.0에서 제거된 레거시 메타데이터 저장소이며, KRaft는 컨트롤러 쿼럼을 브로커가 겸임해 단일 컨테이너로 단순화되어 로컬 개발 인프라의 운영 부담·기동 순서 의존을 줄인다. ZK 채택은 곧 제거될 의존을 새로 도입하는 것이므로 채택하지 않는다.

## 구현 목표
로컬 개발 환경에서 shop-core·notification이 각각 독립 PostgreSQL을 쓰고, 단일 노드 Kafka(KRaft 모드, broker+controller 겸임)로 비동기 이벤트 연동을 재현하는 Docker Compose 인프라를 docker/shop/docker-compose.yml 한 파일로 구성한다. 앱 자체는 컨테이너화하지 않고 IDE에서 로컬 실행하며, 두 앱의 기존 application.yml 로컬 기본값(5432/5433/9092)에 정확히 정합시킨다.

## 영향 범위 (infra 영역 한정 — 화면 없음, 앱 컨테이너화 없음)
- 신규 파일
  - docker/shop/docker-compose.yml — PostgreSQL x2, Kafka(KRaft 단일 노드) x1 정의 (Zookeeper 컨테이너 없음 → 총 3개 서비스)
  - docker/shop/.env.example — 로컬 개발용 기본 자격증명/포트/이미지 태그 키 샘플 (실제 .env는 커밋하지 않음)
  - docker/shop/README.md — 기동/검증 절차, 컨테이너·포트 추적표 (Acceptance "추적 가능" 충족용, 권장)
- 수정 파일
  - (없음) shop-core/src/main/resources/application.yml — 변경 불필요 (근거 1-1)
  - (없음) notification/src/main/resources/application.yml — 변경 불필요 (근거 1-1)
- 범위 밖 (이 Task에서 하지 않음)
  - shop-core/notification 앱 Dockerfile·앱 컨테이너 서비스
  - Kafka topic 사전 생성/스키마 변경 (계약 변경 금지 — auto-create에 위임 또는 후속 Task)
  - Flyway·DLQ·운영 보안(TLS/SASL/시크릿 매니저)
  - KRaft 다중 노드/외부 컨트롤러 분리 (단일 노드 겸임으로 충분 — 로컬 범위)

---

## 1. 설계 방식 및 이유

### 1-1. application.yml 변경 불필요 — 근거 (변경 없음)
두 앱은 이미 로컬 기본값을 환경변수 placeholder 형태로 보유하며, 이 Task의 compose가 그 기본값에 맞추도록 설계한다. 따라서 yml 수정은 불필요하다. KRaft 전환 후에도 EXTERNAL advertised=localhost:9092가 유지되므로 정합은 그대로다.

| 앱 | 설정 키 | 현재 기본값 | compose가 노출할 호스트 엔드포인트 | 정합 |
|---|---|---|---|---|
| shop-core | datasource.url | jdbc:postgresql://localhost:5432/shop_core | localhost:5432 / DB shop_core | O |
| shop-core | datasource.username / password | shop_core / shop_core | POSTGRES_USER/PASSWORD shop_core | O |
| shop-core | kafka.bootstrap-servers | localhost:9092 | localhost:9092 (EXTERNAL listener) | O |
| notification | datasource.url | jdbc:postgresql://localhost:5433/notification | localhost:5433 / DB notification | O |
| notification | datasource.username / password | notification / notification | POSTGRES_USER/PASSWORD notification | O |
| notification | kafka.bootstrap-servers | localhost:9092 | localhost:9092 (EXTERNAL listener) | O |

- 앱은 호스트(IDE)에서 실행되므로 모든 접속은 localhost:<published port>로 이뤄진다. compose의 published 포트를 위 표와 동일하게 맞추면 yml은 그대로 부팅된다.
- 두 앱이 같은 localhost:9092를 보지만, 이는 동일한 단일 브로커를 가리키는 것이므로 정상이다(DB 공유와 무관 — Kafka는 본래 공유 채널, docs/architecture.md 4절).
- 변경하지 않는 이유: yml을 건드리면 이미 정합하는 기본값을 흔들 위험만 있고 이득이 없다. 환경별 오버라이드는 이미 placeholder로 가능하다.
- Task Files에 두 yml이 적시되어 있으나, 위 표로 정합이 증명되므로 수정 대상에서 제외하고 검증 단계에서 일치만 확인한다.

### 1-2. 이미지 선택 — apache/kafka 공식 이미지 (KRaft 모드), 태그 고정
- Kafka는 **apache/kafka 공식 이미지**를 사용한다. apache/kafka는 KRaft가 기본이라 단일 컨테이너로 broker+controller를 겸임할 수 있고, Zookeeper 의존이 없다. (초판의 confluentinc/cp-kafka + confluentinc/cp-zookeeper 조합은 폐기.)
- PostgreSQL은 공식 postgres 이미지(alpine 변형)를 사용한다 — 가볍고 공식.
- Task 제약 (latest 금지 / 재현성)에 따라 모든 태그를 고정한다.
- 권장 고정 태그: postgres:16.4-alpine / **apache/kafka:3.8.1**
  - 근거: 3.8.x는 KRaft가 production-ready로 안정화된 라인이며, ZK 모드는 이미 deprecated. 4.x는 ZK 완전 제거 라인이나 본 Task 시점 기준 3.8.1을 안정 고정값으로 채택한다(필요 시 3.9.x로 상향 가능하나 latest 금지 원칙상 명시 태그로만 변경).
- 트레이드오프(이미지 대안, KRaft 채택 결론)는 6절에서 다룬다.

### 1-3. Kafka listener 구성 — CONTROLLER/INTERNAL/EXTERNAL 분리 (KRaft + 호스트 IDE 함정 대응)
KRaft 단일 노드는 controller 쿼럼용 리스너가 추가로 필요하다. 앱이 호스트에서 localhost:9092로 접속하면서, 컨테이너 네트워크 내부 접근(INTERNAL)과 컨트롤러 쿼럼 통신(CONTROLLER)을 분리해 3개 named listener를 둔다.

- KAFKA_PROCESS_ROLES=broker,controller
- KAFKA_NODE_ID=1
- KAFKA_CONTROLLER_QUORUM_VOTERS=1@shop-kafka:9093
- KAFKA_LISTENERS=CONTROLLER://0.0.0.0:9093,INTERNAL://0.0.0.0:29092,EXTERNAL://0.0.0.0:9092
- KAFKA_ADVERTISED_LISTENERS=INTERNAL://shop-kafka:29092,EXTERNAL://localhost:9092  (CONTROLLER는 advertise하지 않음 — 쿼럼 내부 전용)
- KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,INTERNAL:PLAINTEXT,EXTERNAL:PLAINTEXT
- KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER
- KAFKA_INTER_BROKER_LISTENER_NAME=INTERNAL

핵심 원리:
- 클라이언트는 bootstrap 접속 후 브로커가 광고(advertise)하는 주소로 재접속한다. 단일 advertised 주소만 두면 호스트(localhost)와 컨테이너 내부 중 한쪽이 깨진다. 본 Task 전제(앱은 호스트 IDE 실행)에서 EXTERNAL=localhost:9092가 필수이고, INTERNAL=shop-kafka:29092는 향후 컨테이너 간/관리 도구 접근 여지를 남긴다.
- CONTROLLER 리스너(9093)는 KRaft 메타데이터 쿼럼 통신 전용이며 클라이언트에 광고하지 않는다. 단일 노드이므로 쿼럼 voter는 자기 자신(1@shop-kafka:9093) 하나뿐이라 별도 외부 의존 없이 자체 부트스트랩한다.

### 1-3a. apache/kafka 이미지의 cluster id / 스토리지 포맷 처리 (확인 필요 사항 명시)
apache/kafka 공식 이미지는 환경변수 규약은 cp 이미지와 동일하게 KAFKA_ prefix(server.properties 키를 대문자·점→밑줄 변환)를 사용하지만, KRaft는 최초 기동 전 메타데이터 로그 디렉터리 포맷(kafka-storage format --cluster-id ...)이 필요하다는 점이 ZK 모드와 다르다. 처리 방식 후보:

- 후보 A (자동 포맷 — 권장): apache/kafka 공식 이미지의 entrypoint는 미포맷 로그 디렉터리를 감지하면 cluster id를 자동 생성·포맷한다. 이 경우 별도 환경변수 없이 PROCESS_ROLES/NODE_ID/QUORUM_VOTERS만으로 단일 노드가 기동한다. **로컬 단일 노드·재현성 요구(고정 cluster id 불필요)에 부합하므로 후보 A를 권장 채택.**
- 후보 B (수동 cluster id): KAFKA_CLUSTER_ID 환경변수(또는 init 단계에서 kafka-storage random-uuid → format)를 명시해 고정한다. 다중 노드/명시적 재현이 필요할 때 유효하나, 단일 노드 로컬에서는 과도하다.

구현 단계 확인 사항(구현 에이전트가 반드시 검증):
1. 채택한 apache/kafka:3.8.1 이미지가 자동 포맷(후보 A)을 수행하는지 실제 기동 로그로 확인한다. 자동 포맷이 동작하면 KAFKA_CLUSTER_ID를 두지 않는다.
2. 자동 포맷이 동작하지 않으면 후보 B로 전환: .env.example에 KAFKA_CLUSTER_ID 고정값(또는 생성 절차)을 추가하고, compose에 KAFKA_CLUSTER_ID 환경변수를 주입하거나 init용 one-shot 커맨드로 storage format을 수행한다.
3. 어느 경로든 결과는 README 검증 절차에 기록한다(첫 기동 시 포맷 발생 → 이후 volume 보존 시 재포맷 없음).

> 주의: KRaft 메타데이터는 로그 디렉터리에 저장되므로, 데이터 영속이 필요하면 Kafka 로그 디렉터리에 named volume을 둘 수 있다(선택). 로컬 일회성 기동 우선 원칙상 초판과 동일하게 임시(volume 없음)로 두되, 후보 B(고정 cluster id)를 쓸 경우 재포맷 충돌 방지를 위해 volume 사용 여부를 README에 명시한다.

### 1-4. PostgreSQL 분리 원칙 (DB 공유 금지 — docs/architecture.md 6절, 9절) (변경 없음)
- 두 PostgreSQL은 별도 컨테이너 / 별도 호스트 포트(5432, 5433) / 별도 named volume로 완전히 분리한다.
- 단일 PG에 스키마/DB 두 개를 두는 방식은 채택하지 않는다(공유 DB 안티패턴 회피, 인스턴스 소유권 시연이 포트폴리오 목적).

### 1-5. 자격증명/시크릿 — 로컬 개발용 명시 (변경 없음)
- 운영 보안 가장 금지 제약에 따라, compose에는 약하고 명백히 로컬용인 기본값(shop_core/notification)을 두되 .env 치환으로 노출한다.
- .env.example을 커밋하고 실제 .env는 커밋 금지(주석으로 명시). 운영 시크릿 매니저/강한 비밀번호는 범위 밖임을 README·주석에 명기한다.
- 기본값을 둘 자리(compose의 변수 기본값 문법)에 로컬 전용임을 주석으로 표기하여 운영처럼 보이지 않게 한다.

---

## 2. 구성 요소

### 2-1. 파일 목록
- docker/shop/docker-compose.yml — **3개 서비스**(아래), named volume 2개(PG 전용), 단일 사용자 네트워크 1개.
- docker/shop/.env.example — 자격증명·포트·이미지 태그 변수 샘플.
- docker/shop/README.md — 기동/검증/추적표.

### 2-2. 서비스 정의 개요 (docker-compose.yml)
restart 정책은 최소화(로컬 일회성 기동 우선) — 과도 설계 회피. **Zookeeper 서비스 없음. depends_on 없음(KRaft 자체 부트스트랩).**

1. shop-core-postgres
   - image: postgres:16.4-alpine
   - container_name: shop-core-postgres
   - environment: POSTGRES_DB=shop_core, POSTGRES_USER=shop_core, POSTGRES_PASSWORD=shop_core (모두 .env 치환, 기본값 로컬용)
   - ports: 5432:5432
   - volumes: shop-core-pg-data:/var/lib/postgresql/data
   - healthcheck: pg_isready -U shop_core -d shop_core
   - networks: shop-net

2. notification-postgres
   - image: postgres:16.4-alpine
   - container_name: notification-postgres
   - environment: POSTGRES_DB=notification, POSTGRES_USER=notification, POSTGRES_PASSWORD=notification
   - ports: 5433:5432 (호스트 5433 -> 컨테이너 5432)
   - volumes: notification-pg-data:/var/lib/postgresql/data
   - healthcheck: pg_isready -U notification -d notification
   - networks: shop-net

3. shop-kafka  (KRaft 단일 노드 — broker+controller 겸임)
   - image: apache/kafka:3.8.1
   - container_name: shop-kafka
   - depends_on: (없음 — ZK 제거, 자체 컨트롤러 쿼럼 부트스트랩)
   - environment:
     - KAFKA_PROCESS_ROLES=broker,controller
     - KAFKA_NODE_ID=1
     - KAFKA_CONTROLLER_QUORUM_VOTERS=1@shop-kafka:9093
     - KAFKA_LISTENERS=CONTROLLER://0.0.0.0:9093,INTERNAL://0.0.0.0:29092,EXTERNAL://0.0.0.0:9092
     - KAFKA_ADVERTISED_LISTENERS=INTERNAL://shop-kafka:29092,EXTERNAL://localhost:9092
     - KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,INTERNAL:PLAINTEXT,EXTERNAL:PLAINTEXT
     - KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER
     - KAFKA_INTER_BROKER_LISTENER_NAME=INTERNAL
     - KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 (단일 브로커 필수)
     - KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1
     - KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1
     - KAFKA_AUTO_CREATE_TOPICS_ENABLE=true (로컬 편의 — 계약 토픽 자동 생성, 6절 트레이드오프 참고)
     - (조건부) KAFKA_CLUSTER_ID=<고정 UUID>  — 1-3a 후보 B 채택 시에만. 후보 A(자동 포맷)면 미설정.
   - ports: 9092:9092  (EXTERNAL만 호스트 게시)
   - healthcheck: kafka-broker-api-versions.sh --bootstrap-server localhost:9092 (또는 생략, 4절) — apache/kafka 이미지의 스크립트 경로/이름은 구현 시 확인
   - networks: shop-net

### 2-3. 포트 / 볼륨 / 네트워크 / 이미지 표

| 서비스(컨테이너명) | 이미지(고정 태그) | 호스트:컨테이너 포트 | named volume | 네트워크 |
|---|---|---|---|---|
| shop-core-postgres | postgres:16.4-alpine | 5432:5432 | shop-core-pg-data | shop-net |
| notification-postgres | postgres:16.4-alpine | 5433:5432 | notification-pg-data | shop-net |
| shop-kafka | apache/kafka:3.8.1 | 9092:9092 (EXTERNAL) | (없음/임시; 후보 B 시 선택적 kafka 로그 volume) | shop-net |

- CONTROLLER 포트 9093, INTERNAL 포트 29092는 **컨테이너 네트워크 전용**으로 호스트에 게시하지 않는다.
- volume 분리: shop-core-pg-data != notification-pg-data (DB 공유 금지 물리적 보장).
- 네트워크: 사용자 정의 bridge shop-net 단일. 컨테이너 간/쿼럼 DNS 이름(shop-kafka) 해석에 필요(KAFKA_CONTROLLER_QUORUM_VOTERS의 shop-kafka:9093 해석 포함).

### 2-4. .env.example 키 목록
로컬 개발 전용 — 운영 자격증명 아님 (실제 .env 커밋 금지). 키 목록:
- SHOP_CORE_DB_NAME=shop_core
- SHOP_CORE_DB_USER=shop_core
- SHOP_CORE_DB_PASSWORD=shop_core
- SHOP_CORE_DB_PORT=5432
- NOTIFICATION_DB_NAME=notification
- NOTIFICATION_DB_USER=notification
- NOTIFICATION_DB_PASSWORD=notification
- NOTIFICATION_DB_PORT=5433
- KAFKA_EXTERNAL_PORT=9092
- POSTGRES_IMAGE_TAG=16.4-alpine
- KAFKA_IMAGE_TAG=3.8.1   (apache/kafka 태그 — 초판 CP_IMAGE_TAG 폐기)
- (조건부) KAFKA_CLUSTER_ID=<고정 UUID>  — 1-3a 후보 B 채택 시에만 추가. 후보 A면 키 없음.

제거된 키: ZOOKEEPER_CLIENT_PORT (Zookeeper 제거), CP_IMAGE_TAG (KAFKA_IMAGE_TAG로 대체).

compose에서는 변수에 로컬 기본값을 함께 부여하는 문법(예: 변수 미설정 시 shop_core 사용)으로 .env 없이도 기동 가능하게 한다.

---

## 3. 데이터 흐름 (호스트/컨테이너 네트워크 관점)

호스트 IDE에서 실행되는 두 앱과 컨테이너 인프라 간 경로:

- shop-core 앱 -> (jdbc localhost:5432) -> shop-core-postgres (컨테이너 :5432)
- notification 앱 -> (jdbc localhost:5433) -> notification-postgres (컨테이너 내부 :5432)
- shop-core producer -> (localhost:9092 bootstrap) -> shop-kafka EXTERNAL :9092
  - 브로커가 advertised EXTERNAL=localhost:9092로 재광고 -> 클라이언트가 동일 주소로 재접속
- notification consumer -> (localhost:9092 bootstrap, group=notification) -> 동일 브로커에서 구독
- shop-kafka 내부 controller quorum: broker 역할 <-> controller 역할이 **동일 프로세스 내 + CONTROLLER 리스너(shop-kafka:9093)**로 메타데이터를 self-bootstrap. 단일 voter(1@shop-kafka:9093)이므로 외부 컨테이너 의존 없음.

설명:
- DB 경로: 각 앱은 자기 소유 PG 컨테이너에만 접속(포트로 분리). 컨테이너 간 PG-PG 통신 없음.
- 이벤트 경로: shop-core가 토픽(OrderCompletedEvent / PaymentFailedEvent / ShippingStartedEvent, docs/architecture.md 5절)에 발행 -> notification이 group-id notification으로 구독. compose는 채널(Kafka)만 제공하며 토픽 계약·스키마는 손대지 않는다.
- 호스트 vs 컨테이너: 앱이 호스트에서 실행되므로 EXTERNAL advertised 주소(localhost:9092)가 동작의 핵심. 메타데이터 쿼럼은 CONTROLLER 리스너로 컨테이너 내부에서만 동작(ZK 통신 경로를 controller quorum 내부 경로로 대체).

---

## 4. 예외 처리 전략 (이 Task 범위: 기동·연결)

- 기동 순서: **depends_on 없음.** ZK가 사라져 외부 기동 의존이 제거되었다. KRaft 단일 노드는 컨트롤러 쿼럼 voter가 자기 자신뿐이라 자체 부트스트랩하므로 별도 wait 스크립트/순서 게이팅이 불필요하다(과도 설계 회피).
- 최초 기동 포맷: KRaft는 첫 기동 시 메타데이터 로그 디렉터리 포맷이 필요(1-3a). 후보 A(이미지 자동 포맷)면 무개입, 후보 B(수동 cluster id)면 KAFKA_CLUSTER_ID 일관성 유지 필요. 포맷 실패 시 로그에 needs format 류 메시지가 나오면 1-3a 절차로 처리.
- 포트 충돌: 5432/5433/9092가 호스트에서 점유 중이면 기동 실패(2181은 더 이상 없음). README에 충돌 시 .env의 포트 변수로 호스트 포트만 바꾸는 절차 안내. 단 9092 변경 시에는 앱 yml의 bootstrap과 Kafka EXTERNAL advertised 주소를 함께 일치시켜야 함을 명시(호스트 published 포트만 바꾸면 advertised와 어긋날 수 있음). CONTROLLER(9093)·INTERNAL(29092)은 호스트 미게시이므로 충돌 대상 아님.
- PG healthcheck: pg_isready로 준비 상태 노출. 앱은 호스트에서 수동 실행되므로 강한 condition: service_healthy 게이팅은 불필요 — healthcheck는 ps/up 관찰용으로만 둔다.
- Kafka 연결 실패: 가장 흔한 원인은 advertised listener 오설정. 1-3 구성으로 호스트 접속을 보장. 두 번째 흔한 원인은 KRaft 포맷/쿼럼 미수렴 — 컨테이너 로그에서 controller quorum/active controller 선출 여부 확인. healthcheck는 선택(추가 시 kafka-broker-api-versions), 미도입 시 README 검증 절차로 대체.
- 데이터 초기화: 볼륨 삭제는 docker compose down -v로만. 일반 down은 데이터 보존. (후보 B에서 kafka 로그 volume을 둔 경우, cluster id 변경 시 down -v 후 재기동 필요 — README 명시.)
- 이 Task는 인프라만 다루므로 앱 레벨 재시도/DLQ/멱등은 범위 밖(docs/architecture.md 4절, 후속 Consumer Task).

---

## 5. 검증 방법

### 5-1. 절차와 기대 결과
1. docker compose -f docker/shop/docker-compose.yml config
   - 기대: 변수 치환 후 **3개 서비스**·2개 volume·1개 network가 오류 없이 렌더. 이미지 태그가 고정값으로 출력(latest 없음, apache/kafka:3.8.1).
2. docker compose -f docker/shop/docker-compose.yml up -d
   - 기대: shop-core-postgres, notification-postgres, shop-kafka **3개 컨테이너** 생성·기동. (Zookeeper 컨테이너 없음.)
3. docker compose -f docker/shop/docker-compose.yml ps
   - 기대: **3개 모두 running**(PG는 healthy). 포트 매핑이 5432/5433/9092로 표시. 9093/29092는 미게시(표시 안 됨).
4. docker compose -f docker/shop/docker-compose.yml logs shop-kafka
   - 기대: 첫 기동 시 storage 포맷(또는 이미 포맷됨) 후 controller quorum/active controller 선출 로그. 정상 기동(KafkaServer started 류).

### 5-2. 분리·정합 확인법
- PG 분리 확인:
  - docker exec shop-core-postgres psql -U shop_core -d shop_core -c "\l" -> shop_core DB 존재
  - docker exec notification-postgres psql -U notification -d notification -c "\l" -> notification DB 존재
  - 두 컨테이너가 서로 다른 volume(docker volume ls 에서 shop-core-pg-data, notification-pg-data 접미)을 쓰는지 확인
- Kafka bootstrap / KRaft 확인:
  - 호스트에서 docker exec shop-kafka /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 정상 응답 (스크립트 경로는 apache/kafka 이미지 기준 확인)
  - (옵션) docker exec shop-kafka /opt/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server localhost:9092 describe --status -> 단일 voter, leader=1 확인
  - shop-core yml localhost:9092 / notification yml localhost:9092 <-> EXTERNAL published 9092 동일(1-1 표)
  - (옵션) shop-core 앱 기동 시 producer 연결 로그, notification 앱 기동 시 consumer group notification 조인 로그 확인

### 5-3. Acceptance Criteria <-> 검증 체크리스트 매핑
| Acceptance Criteria | 검증 단계 |
|---|---|
| docker compose up으로 PG2·Kafka1(KRaft) 기동 | 5-1 (2),(3) — ps에서 3개 running |
| shop-core DB와 notification DB 분리 | 5-2 PG 분리 확인(별도 컨테이너·포트·volume) |
| Kafka bootstrap 정보가 두 앱 설정과 일치 | 5-2 Kafka 일치 확인 + 1-1 표 |
| 컨테이너 이름·포트가 문서/설정에서 추적 가능 | 2-3 표 + README 추적표, ps 출력과 대조 |

> 참고: 초판 Acceptance "PG2·ZK1·Kafka1"은 Task 명세 표현이나, 본 Plan은 ZK 제거 사유(서두 명시)에 따라 "PG2·Kafka1(KRaft)"로 충족한다.

---

## 6. 트레이드오프

- KRaft vs Zookeeper (결론 변경):
  - **채택: KRaft.** Task Requirements는 ZK를 명시하나, ZK는 Kafka 3.5 deprecated·4.0 제거된 레거시이며 곧 사라질 의존을 새로 도입하게 된다. KRaft는 broker+controller 겸임으로 컨테이너 1개·depends_on 0개로 단순화되고 기동 순서 함정이 사라진다. (서두 명시 사유.)
  - 비용: controller 리스너(9093)·PROCESS_ROLES·QUORUM_VOTERS 등 KRaft 전용 환경변수가 늘고, 최초 기동 시 storage 포맷 처리(1-3a)가 필요. 그러나 ZK 컨테이너·ZK-broker 호환성·기동 순서 의존을 모두 제거하는 이득이 크다.
- 이미지 선택 (apache/kafka vs confluentinc/cp-kafka vs bitnami):
  - **채택: apache/kafka(공식).** KRaft 기본·ZK 불필요·Apache 직접 배포로 라이선스 명확. (초판은 cp-* + cp-zookeeper였으나 ZK 의존 때문에 폐기.)
  - 대안 cp-kafka: KRaft도 지원하나 별도 cp-zookeeper 생태계 전제 문서가 많고, ZK 제거 목적엔 공식 이미지가 더 직접적. bitnami: 경량·환경변수 깔끔하나 라이선스/태그 정책 변동 이력으로 보류.
- listener 구성 (단일 vs CONTROLLER/INTERNAL/EXTERNAL 분리):
  - 채택: 3분리 — 호스트 IDE 실행 전제 + KRaft 컨트롤러 쿼럼 요구. 단일 advertised로는 호스트/컨테이너 동시 접속 불가하고, CONTROLLER 리스너는 KRaft 필수.
  - 비용: 환경변수 다소 장황. 그러나 가장 흔한 함정(advertised 오설정) 회피가 우선.
- cluster id / storage 포맷 (자동 vs 수동):
  - 채택(권장): 후보 A 자동 포맷 — 단일 노드 로컬에선 고정 cluster id가 불필요하고 무개입 기동이 단순. 실제 동작은 구현 시 로그로 확인(1-3a).
  - 대안: 후보 B 수동 KAFKA_CLUSTER_ID — 재현·다중 노드 시 유효하나 로컬엔 과도.
- .env 분리 여부:
  - 채택: .env.example 제공 + compose에 로컬 기본값 병행. -> .env 없이도 즉시 기동되면서, 변수화로 포트 충돌 회피 가능.
  - 비용: 동일 값이 두 곳(.env.example/compose 기본값)에 존재 -> 드리프트 위험. README에 SSOT는 1-1 표임을 명시해 완화.
- healthcheck 수준:
  - 채택: PG만 pg_isready, Kafka는 선택/관찰용. condition: service_healthy 게이팅 미사용(앱이 호스트 수동 실행이라 게이팅 실익 적음).
  - 비용: 기동 직후 짧은 unready 구간 가능 -> 클라이언트 재시도로 흡수.
- 앱 컨테이너화 제외:
  - 채택: 인프라만. 앱은 IDE 로컬 실행 -> 빠른 디버깅 루프, 본 Task 경계와 일치.
  - 비용: 원커맨드 풀스택은 안 됨. 후속 Task에서 앱 Dockerfile·profile(docker) 추가 시 advertised listener를 shop-kafka:29092(INTERNAL) 기준으로 앱이 보도록 재구성 필요.
- 토픽 auto-create:
  - 채택: 로컬 편의로 true. 계약 토픽을 사전 생성하지 않아도 발행/구독 가능.
  - 비용: 오타 토픽도 생성됨. 운영에선 false 권장이나 로컬 범위에서 허용.

---

## Spring Boot / 인프라 컨벤션
- 디렉터리: Docker 파일은 docker/shop/에 위치(CLAUDE.md "Docker 파일 위치").
- 이미지 태그 고정(latest 금지) — 재현성. apache/kafka:3.8.1 / postgres:16.4-alpine.
- 로컬 전용 자격증명임을 주석·README·.env.example로 명시(운영 보안 가장 금지).
- Kafka 토픽 계약(docs/architecture.md 5절)·페이로드 스키마 불변 — compose는 채널만 제공.
- 두 PostgreSQL 물리 분리(별도 컨테이너·포트·volume) — DB 공유 금지(docs/architecture.md 6절,9절).
- 명세-구현 불일치(ZK→KRaft)는 본 문서 서두·6절에 사유 기록(CLAUDE.md 규칙).

## 완료 조건 체크리스트
- [ ] docker/shop/docker-compose.yml 생성: shop-core-postgres / notification-postgres / shop-kafka **3개 서비스** (Zookeeper 없음)
- [ ] shop-core-postgres: 호스트 5432, DB/USER/PASS=shop_core, volume shop-core-pg-data
- [ ] notification-postgres: 호스트 5433, DB/USER/PASS=notification, volume notification-pg-data
- [ ] 두 PG volume·포트 분리 확인 (공유 없음)
- [ ] Kafka KRaft 구성: PROCESS_ROLES=broker,controller / NODE_ID=1 / CONTROLLER_QUORUM_VOTERS=1@shop-kafka:9093
- [ ] listener 3종: CONTROLLER://9093, INTERNAL://29092, EXTERNAL://9092 + 보안 프로토콜 맵(3종 PLAINTEXT) + CONTROLLER_LISTENER_NAMES=CONTROLLER + INTER_BROKER_LISTENER_NAME=INTERNAL
- [ ] advertised: INTERNAL=shop-kafka:29092, EXTERNAL=localhost:9092 (CONTROLLER 미advertise)
- [ ] 호스트 게시: 9092만. 9093·29092는 컨테이너 내부 전용(미게시)
- [ ] 단일 브로커용 replication factor=1 설정 3종 포함(OFFSETS/TRANSACTION_STATE_LOG REPLICATION_FACTOR + TRANSACTION_STATE_LOG_MIN_ISR)
- [ ] KRaft 컨트롤러 쿼럼 자체 부트스트랩 확인 (depends_on 없음 / ZK 없음)
- [ ] cluster id / storage 포맷 처리 확정 (후보 A 자동 포맷 권장; 미동작 시 후보 B로 전환·기록)
- [ ] 모든 이미지 태그 고정값(postgres:16.4-alpine, apache/kafka:3.8.1), latest 없음
- [ ] docker/shop/.env.example 생성 + 로컬 전용 주석 + 키 목록(2-4) (ZOOKEEPER_CLIENT_PORT 제거, KAFKA_IMAGE_TAG 사용)
- [ ] compose가 .env 없이도 기본값으로 기동 가능
- [ ] README(또는 동등 문서)에 컨테이너·포트 추적표(2-3)와 검증 절차(5절) 기재
- [ ] docker compose ... config 오류 없이 렌더
- [ ] docker compose ... up -d 후 ps에서 **3개 running**(PG healthy)
- [ ] 1-1 표 기준 shop-core/notification application.yml과 엔드포인트 일치(yml 무변경 확인)
- [ ] 앱 컨테이너·Dockerfile·토픽 계약 변경 없음(범위 밖 준수)

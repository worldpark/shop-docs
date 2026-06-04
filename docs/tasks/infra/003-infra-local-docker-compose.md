# 003. 로컬 인프라 docker-compose

## Target
workspace

---

## Goal
로컬 개발 환경에서 `shop-core`와 `notification`이 각각 독립 PostgreSQL을 사용하고 apache kafka로 비동기 이벤트 연동을 재현할 수 있도록 Docker Compose 환경을 구성한다.

---

## Context
- `shop-core`와 `notification`은 DB를 공유하지 않는다
- Kafka는 개발 환경에서 단일 브로커로 구성한다
- shop-core는 Kafka producer, notification은 Kafka consumer 역할이다
- Docker 파일은 상위 워크스페이스의 `docker/` 아래에 둔다

## Requirements
- PostgreSQL `shop-core`용 컨테이너 추가
- PostgreSQL `notification`용 컨테이너 추가
- Zookeeper 컨테이너 추가
- Kafka broker 컨테이너 추가
- 각 컨테이너 포트 정의
- 각 PostgreSQL 볼륨 분리
- 기본 DB명, 사용자명, 비밀번호 정의
- 두 앱의 `application.yml`에서 사용할 접속 정보와 맞춘다

## Constraints
- 두 PostgreSQL 인스턴스는 서로 다른 포트와 볼륨을 사용한다
- DB 공유 구조를 만들지 않는다
- Kafka topic 계약은 이 Task에서 변경하지 않는다
- 운영용 보안 설정을 가장하지 않고 로컬 개발용으로 명확히 둔다

## Files
- `docker/shop/docker-compose.yml`
- `shop-core/src/main/resources/application.yml`
- `notification/src/main/resources/application.yml`
- 필요 시 `docker/shop/.env.example`

## Acceptance Criteria
- `docker compose up`으로 PostgreSQL 2개, Zookeeper 1개, Kafka 1개가 기동된다
- `shop-core` DB와 `notification` DB가 분리되어 있다
- Kafka bootstrap server 정보가 두 앱 설정과 일치한다
- 컨테이너 이름과 포트가 문서/설정에서 추적 가능하다

## Test
- `docker compose -f docker/shop/docker-compose.yml config`
- `docker compose -f docker/shop/docker-compose.yml up -d`
- `docker compose -f docker/shop/docker-compose.yml ps`

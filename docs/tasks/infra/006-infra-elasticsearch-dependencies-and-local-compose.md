# 006. 상품 검색 엔진(Elasticsearch/OpenSearch + Nori) 의존성 + 로컬 인프라 구성

> 출처: ADR-011(상품 검색을 Elasticsearch(+Nori) 보조 인덱스로 분리하고 PostgreSQL을 SoT로 유지). 본 Task는 상품 검색 개선 이니셔티브의 **T1(인프라·클라이언트 기반)** 이다.
> 범위 SSOT: 본 문서. 설계 결정(벤더 택1·클라이언트 라이브러리 택1 등)은 docs/plans/infra/006-elasticsearch-dependencies-and-local-compose-plan.md 에 위임한다.
> 본 Task는 **검색 엔진을 기동하고 shop-core가 연결·health up까지만** 한다. 색인 매핑·Nori 분석기 정의·이벤트 indexer·재색인·검색 쿼리는 본 Task 범위 밖이며 후속 Task로 분리한다(아래 이니셔티브 Task 맵 참고).

## Target
workspace (docker compose) + shop-core (검색 클라이언트 의존성·연결 설정·health)

> shop-core 단일 대상이다. notification은 상품 검색과 무관하므로 검색 엔진 의존성을 추가하지 않는다(Redis 005와 달리 검색은 shop-core 전용).

---

## Goal
1. 로컬 Docker Compose(docker/shop/docker-compose.yml)와 운영 Compose(docker/shop/docker-compose.prod.yml)에 **Nori 형태소 분석기 플러그인이 내장된** 검색 엔진(Elasticsearch 또는 OpenSearch) 단일 노드를 추가해, shop-core가 로컬·운영에서 검색 엔진에 접속할 수 있는 인프라를 구성한다.
2. shop-core에 검색 클라이언트 의존성과 접속 설정을 추가하고, 애플리케이션 부팅 시 검색 엔진에 연결되어 actuator health에서 상태가 노출되도록 한다.
3. 위 둘을 Testcontainers(검색 엔진 모듈)로 검증한다 — 앱 컨텍스트가 검색 엔진에 연결되고 health가 up으로 와이어링됨을 확인한다.

> 본 Task의 완료 기준은 엔진 기동 + 연결 + health up 이다. 검색 동작(인덱스 생성·문서 색인·쿼리)은 0이다.

---

## Context
- ADR-011 결정에 따라 상품 검색은 **PostgreSQL을 SoT로 두고 ES/OpenSearch를 항상 재생성 가능한 보조 인덱스**로 둔다. 색인은 Kafka 이벤트 기반(dual-write 금지)이며, 이 색인·쿼리 동작은 모두 후속 Task다.
- 벤더 선택(Elasticsearch vs OpenSearch)·매니지드 vs 자체호스팅 최종 결정은 ADR-011이 plan에 위임했다. **본 이니셔티브의 고정 결정은 1차 구현을 자체호스팅(compose 노드)으로 한다**는 것이다. 매니지드 이관(OpenSearch Service / Elastic Cloud — 둘 다 Nori 지원)은 후속 여지로 남기되, 그 경우 본 compose 노드를 외부 엔드포인트로 교체하고 환경별 설정을 분리한다(운영 메모 참고).
- 벤더 택1은 plan 위임이되, 두 후보 모두 **Nori 지원·라이선스**를 충족해야 한다.
  - Elasticsearch: Nori는 공식 번들 플러그인(analysis-nori)이나 별도 설치가 필요. 라이선스는 ELv2/SSPL 계열 — 자체호스팅 사용은 허용 범위이나 라이선스 조항을 plan에서 확인한다.
  - OpenSearch: Apache 2.0. Nori 분석기 플러그인 제공. 라이선스 측면이 상대적으로 단순.
  - 어느 쪽이든 **Nori 플러그인이 내장된 이미지**(공식 이미지 + 플러그인 설치 빌드 또는 플러그인 동봉 이미지)로 구성한다. plan에서 이미지 빌드 방식(Dockerfile vs 플러그인 사전설치 이미지)을 확정한다.
- compose 기존 패턴(반드시 대조 — 003/005 선례, docker-compose.yml + docker-compose.prod.yml):
  - 이미지 버전은 env 오버라이드 + 기본값 핀 패턴(postgres:16.4-alpine, redis:7.4-alpine 처럼 IMAGE_TAG env + 기본값). 검색 엔진도 동일하게 IMAGE_TAG env + 기본값으로 버전 고정.
  - 컨테이너 이름은 docker-rule에 따라 shop-<이름> 규칙. (예: shop-search)
  - TZ: Asia/Seoul 전 컨테이너 공통.
  - healthcheck + interval/timeout/retries/start_period(검색 엔진은 부팅이 느리므로 start_period를 PG·Redis보다 넉넉히).
  - named volume으로 데이터 영속(local: shop-search-data, prod: prod-shop-search-data). prod는 prod- 접두 규칙.
  - networks: shop-net(bridge) 공통, restart: unless-stopped.
  - 로컬은 호스트 포트 게시(IDE 앱 접속), 운영은 컨테이너 네트워크 내부만 사용(005 Redis·prod Kafka처럼 호스트 미게시 — 공격 표면 축소). 운영 shop-core depends_on에 검색 엔진 condition: service_healthy 추가.
- 검색 엔진 단일 노드 운영 파라미터(로컬·1차):
  - discovery.type=single-node(또는 OpenSearch 대응 설정)로 단일 노드 클러스터.
  - JVM 힙 상한(ES_JAVA_OPTS/OPENSEARCH_JAVA_OPTS 등 Xms/Xmx)을 로컬 개발에 맞게 보수적으로 고정(메모리 폭주 방지).
  - 로컬 개발 전용 보안 완화(보안 플러그인/TLS/AUTH off)를 명시 — 운영 보안·클러스터 구성을 가장하지 않는다(005 Redis와 동일 원칙). 운영 보안(인증·TLS·노드 수)은 매니지드 이관 또는 후속 운영 Task에서 다룬다.
- shop-core application.yml 현행: ENV:default 바인딩 컨벤션 사용(예: SHOP_CORE_DB_URL, SHOP_CORE_REDIS_HOST). 검색 엔진 접속도 동일하게 SHOP_CORE_SEARCH_* env + 기본 localhost 값으로 추가한다. 로컬 기동은 local 프로파일 기준.
- shop-core는 Spring Modulith 구조다. 검색 클라이언트 설정(연결 Bean/프로퍼티 바인딩)은 공용 인프라 성격이므로 common 영역에 둔다(도메인 모듈에 검색 로직을 넣지 않는다 — 검색 도메인 로직은 후속 Task). 정확한 패키지는 plan 확정.

## 이니셔티브 Task 맵 (교차참조 — 본 Task의 경계 확인용)
| Task | 문서 | 범위 | 본 Task와의 관계 |
|---|---|---|---|
| T0 | backend/058 | pg_trgm + GIN(임시 브리지 겸 영구 폴백) | 독립(DB 경로) |
| **T1** | **infra/006 = 본 Task** | **검색 엔진 인프라 노드 + shop-core 클라이언트·연결·health** | — |
| T2+3 | backend/059 | 색인 모델 + Nori 매핑/분석기 정의 + 이벤트 indexer | 본 Task의 연결 위에서 인덱스·매핑·색인 |
| T4 | backend/060 | 풀 재색인·백필 잡 | T2+3 위 |
| T5+6 | backend/061 | 검색 읽기 쿼리 + ES 장애 폴백 + 검색 뷰 | T2+3 위 |

> 본 Task는 위 표의 T2+3/T4/T5+6에 해당하는 어떤 동작도 구현하지 않는다.

## plan 확정 필요 (설계 결정 — 본 Task가 plan에 위임)
1. **벤더 택1**: Elasticsearch vs OpenSearch. Nori 지원·라이선스(ELv2/SSPL vs Apache 2.0)·Spring 클라이언트 호환을 기준으로 plan에서 확정. (본 Task 문서는 둘 다 허용으로 기술.)
2. **Nori 내장 이미지 구성 방식**: 공식 이미지 + 플러그인 설치 Dockerfile 빌드 vs Nori 동봉 이미지 사용. 빌드 시 docker/shop/ 아래 Dockerfile 위치·이미지 태그 핀 컨벤션 확정.
3. **Spring 클라이언트 라이브러리 택1**: Spring Data Elasticsearch(repository/template 추상) vs 공식 Java client(Elasticsearch Java Client / OpenSearch Java Client). 벤더 선택과 정합. health indicator 자동 노출 여부도 함께 확인.
4. **접속 설정 형태**: SHOP_CORE_SEARCH_* env 키 명세(host/port/scheme, 필요 시 username/password — 로컬은 보안 off), local 프로파일 기본값, 운영 compose env 주입 키. 005 Redis(SHOP_CORE_REDIS_HOST/PORT/DB) 명명 패턴과 정합.
5. **actuator health 노출 정책**: 검색 엔진 health를 /actuator/health에 포함할지(클라이언트 라이브러리가 기본 제공하는 health indicator 사용 vs 커스텀). 단, 검색 엔진 장애가 핵심 경로(주문/상세/결제)를 막지 않도록 health 그룹·readiness 반영 방향을 plan에서 고려(폴백 자체는 T5+6).
6. **테스트 프로파일에서 검색 자동설정 처리**: 슬라이스/단위 테스트에서 검색 클라이언트 자동설정 제외 또는 mock 방식(005 Redis 테스트 프로파일 처리 선례와 정합). Testcontainers 통합 테스트만 실엔진 사용.

## API Authorization
> 본 Task는 REST API·View 경로를 추가하지 않는다(인프라·내부 클라이언트·health 와이어링만). 따라서 신규 인가 결정 없음. 검색 API 인가는 검색 쿼리를 추가하는 T5+6(backend/061)에서 api-authorization-rule에 따라 정의한다.

## Requirements
- docker/shop/docker-compose.yml에 검색 엔진 단일 노드 서비스 추가
  - 컨테이너 이름 shop-<이름>(docker-rule), 이미지 버전 env 오버라이드 + 기본 핀
  - Nori 분석기 플러그인 내장(이미지 빌드 또는 플러그인 동봉 이미지 — plan 확정)
  - discovery.type=single-node(또는 대응) 단일 노드, JVM 힙 상한 고정
  - TZ: Asia/Seoul, healthcheck(start_period 넉넉히), named volume 데이터 영속, shop-net, restart: unless-stopped
  - 호스트 포트 게시(로컬 IDE 앱 접속용)
  - 로컬 개발 전용 보안 완화(TLS/AUTH off) 명시 주석
- docker/shop/docker-compose.prod.yml에 동일 엔진 노드 추가
  - 호스트 포트 미게시(내부망 전용 — prod Kafka/Redis 패턴), prod- 접두 named volume
  - shop-core 서비스 depends_on에 검색 엔진 condition: service_healthy 추가
  - shop-core 환경변수에 검색 엔진 접속 키 주입(컨테이너 DNS 이름 기준)
  - 운영 보안 가장 금지 — 매니지드 이관/운영 보안은 후속 범위임을 주석으로 명시
- shop-core 검색 클라이언트 의존성 추가(shop-core/build.gradle)
  - Spring Data Elasticsearch 또는 공식 Java client(plan 확정)
- shop-core application.yml(main/test)에 검색 엔진 접속 설정 추가
  - SHOP_CORE_SEARCH_* env + 로컬 기본값(localhost), local 프로파일 기준
  - 테스트 프로파일에서 검색 자동설정 처리(제외/mock — plan 확정)
- shop-core common 영역에 검색 연결 설정(프로퍼티 바인딩/연결 Bean) 추가
- actuator health에 검색 엔진 상태 노출(plan 확정 정책에 따라)
- 검증 테스트 작성(Testcontainers 검색 엔진 모듈 + 컨텍스트/health 와이어링)

## Constraints
- 본 Task는 **검색 엔진 기동·연결·health up까지만** 한다. 인덱스 생성·매핑·Nori 분석기 정의·문서 색인·검색 쿼리·재색인 등 검색 동작은 일절 구현하지 않는다(T2+3/T4/T5+6).
- 기존 Kafka 이벤트 계약·DB 스키마(Flyway)를 변경하지 않는다. product 도메인 코드를 변경하지 않는다.
- notification에 검색 엔진 의존성·노드를 추가하지 않는다(shop-core 전용).
- 검색 엔진을 shop-core↔notification 통신 채널로 사용하지 않는다.
- 운영용 검색 엔진 보안(인증·TLS)·멀티노드 클러스터 구성을 가장하지 않고, 1차는 로컬·운영 모두 단일 노드 + 로컬 보안 완화로 둔다. 운영 보안 강화·매니지드 이관은 후속 범위.
- 검색 엔진 장애가 주문/상세/결제 등 핵심 경로를 차단하지 않도록 한다(health/readiness 반영 방향만 본 Task, 실제 검색 폴백 정책은 T5+6에서 정의).
- 직접 ThreadLocal 사용을 피하고 블로킹 I/O를 Service/Infrastructure 경계에 둔다(가상스레드 도입 대비 — CLAUDE.md).
- 테스트 없이 의존성·인프라 변경을 완료 처리하지 않는다(testing-rule, verification-gate-rule).

## 운영 메모 (매니지드 이관 대비)
- 1차는 자체호스팅 compose 노드다. 향후 매니지드 검색 서비스(OpenSearch Service / Elastic Cloud)로 이관할 경우, 본 compose 노드를 제거하고 SHOP_CORE_SEARCH_* 접속 설정을 **외부 매니지드 엔드포인트**로 교체한다(환경별 설정 분리 — 인증/TLS 추가). 앱 클라이언트 코드는 엔드포인트·자격증명만 바뀌고 검색 계층 로직은 DB와 독립적으로 유지된다(ADR-011 — DB 매니지드 이관과도 무관).

## Files
- docker/shop/docker-compose.yml
- docker/shop/docker-compose.prod.yml
- (Nori 이미지 빌드 채택 시) docker/shop/Dockerfile.search 또는 plan 확정 경로
- shop-core/build.gradle
- shop-core/src/main/resources/application.yml
- shop-core/src/test/resources/application.yml
- shop-core/src/main/java/com/shop/shop/common/**
- shop-core/src/test/java/com/shop/shop/**
- (필요 시) docker/shop/.env.example / docker/shop/.env.prod.example

## Acceptance Criteria
- 로컬 Compose에 검색 엔진 컨테이너(shop-<이름>)가 추가된다.
- 운영 Compose에 동일 엔진 노드가 추가되고 shop-core가 depends_on: service_healthy로 의존한다.
- docker compose -f docker/shop/docker-compose.yml config가 성공한다.
- docker compose -f docker/shop/docker-compose.prod.yml config가 성공한다.
- 검색 엔진 이미지에 **Nori 분석기 플러그인이 내장**되어 있다(설치 확인 가능).
- 이미지 버전이 env 오버라이드 + 기본값으로 핀 고정된다.
- 검색 엔진 데이터가 named volume으로 영속되고, TZ=Asia/Seoul, healthcheck, shop-net가 설정된다.
- shop-core가 검색 클라이언트 의존성을 가진다.
- shop-core application.yml에서 검색 엔진 접속 설정(SHOP_CORE_SEARCH_*)이 추적 가능하다.
- 앱 부팅 시 검색 엔진에 연결되고 actuator health에서 상태가 노출된다(plan 정책에 따라).
- 테스트 프로파일에서 검색 자동설정 처리 방식이 명확하다.
- Testcontainers 검색 엔진 통합 테스트로 연결·health up이 검증된다.
- shop-core 애플리케이션 컨텍스트 테스트가 통과한다.
- 검색 인덱스·매핑·쿼리 등 검색 동작 코드는 추가되지 않는다(범위 경계 준수).
- 기존 Kafka 이벤트 계약·DB 스키마·product 도메인 코드를 변경하지 않는다.

## Test
- docker compose -f docker/shop/docker-compose.yml config
- docker compose -f docker/shop/docker-compose.prod.yml config
- docker compose -f docker/shop/docker-compose.yml up -d
- 검색 엔진 컨테이너 기동·health 확인
  - 호스트에서 클러스터 health 엔드포인트 조회(예: _cluster/health 또는 _cat/health)로 status green/yellow(단일 노드는 yellow 정상) 확인
  - Nori 플러그인 설치 확인(예: _cat/plugins에 analysis-nori / OpenSearch 대응 플러그인 노출)
- ./gradlew test (shop-core/)
- 권장 테스트
  - 검색 엔진 접속 properties 바인딩 테스트
  - Testcontainers(검색 엔진 모듈) 기반 연결·actuator health up 와이어링 통합 테스트

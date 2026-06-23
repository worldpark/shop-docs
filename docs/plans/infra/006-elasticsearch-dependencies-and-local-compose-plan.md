# 006. 상품 검색 엔진(Elasticsearch + Nori) 의존성 + 로컬/운영 인프라 구성 — Plan

> Task SSOT: `docs/tasks/infra/006-infra-elasticsearch-dependencies-and-local-compose.md`
> ADR: `docs/adr/011-product-search-elasticsearch-secondary-index.md` (SoT=PG, ES=재생성 가능 보조 인덱스)
> 본 plan = ADR-011 후속 이니셔티브 **T1(인프라·클라이언트 기반)**.
> **완료 기준 = 검색 엔진 기동 + shop-core 연결 + actuator health up까지.** 인덱스 생성·매핑·Nori 분석기 정의·문서 색인·검색 쿼리·재색인은 전부 범위 밖(T2+3/T4/T5+6).

---

## 구현 목표
shop-core 전용 검색 엔진(Elasticsearch + Nori) 단일 노드를 로컬/운영 compose에 추가하고, shop-core에 공식 Java client 의존성·접속 설정·actuator health를 와이어링한다 — **기동·연결·health up까지만**.

---

## 0. 확정된 설계 결정 (Task가 plan에 위임한 6항목)

### 결정 1 — 벤더: **Elasticsearch** (권장안 1개)
| 기준 | Elasticsearch | OpenSearch | 판정 |
|---|---|---|---|
| Nori 지원 | 공식 번들 플러그인 `analysis-nori`(별도 설치) | `analysis-nori` 플러그인 제공 | 동률 |
| 라이선스(자체호스팅) | Elastic License v2 / SSPL 듀얼 | Apache 2.0 | OpenSearch 우위 |
| Spring 클라이언트 1급 지원 | **Spring Boot 3.5가 Elasticsearch Java Client(`co.elastic.clients`)를 1급 자동설정·actuator health로 지원** | Spring Boot 기본 자동설정/actuator health 미지원(별도 배선 필요) | **ES 우위 — 결정 요인** |
| 매니지드 이관(Nori) | Elastic Cloud(Nori 지원) | OpenSearch Service(Nori 지원) | 동률 |

**권장 = Elasticsearch.** 결정 요인은 **본 Task의 목표가 "최소 의존으로 연결+health만"** 이라는 점이다. Spring Boot 3.5는 `ElasticsearchClientAutoConfiguration` + `ElasticsearchRestClientAutoConfiguration` + 그에 묶인 **actuator health indicator를 1급으로 제공**한다. OpenSearch는 Spring Boot 기본 스타터·자동설정·health indicator가 없어 동일 목표 달성에 **커스텀 클라이언트 빈 + 커스텀 HealthIndicator를 직접 구현**해야 하므로, "과도설계 금지·최소 의존" 제약과 충돌한다. ES를 고르면 본 Task에서 **추가 코드 거의 0(설정 바인딩만)** 으로 health까지 닿는다.

**라이선스 영향(한 단락):** Elasticsearch 7.11+ 는 Elastic License v2(ELv2)와 SSPL의 듀얼 라이선스다. ELv2가 금지하는 것은 ① 매니지드/호스티드 검색 서비스로 **재판매**, ② 라이선스 키 우회, ③ 저작권 표시 제거뿐이다. **본 프로젝트처럼 자사 쇼핑몰 백엔드 내부 보조 인덱스로 자체호스팅 사용**하는 것은 ELv2 허용 범위에 완전히 포함되며 추가 의무가 없다(검색을 외부에 SaaS로 되팔지 않으므로). SSPL 트리거(서비스로서의 ES 제공)에도 해당하지 않는다. 따라서 자체호스팅 1차 구현에 라이선스 리스크는 없다. 매니지드 이관 시에도 Elastic Cloud를 그대로 쓰면 라이선스 이슈가 발생하지 않는다.

### 결정 2 — Nori 내장 이미지: **Dockerfile 빌드(`docker/shop/Dockerfile.search`)**
- 공식 `docker.elastic.co/elasticsearch/elasticsearch` 이미지에는 `analysis-nori`가 **기본 미포함**이므로 플러그인 설치가 필요하다. "Nori 동봉 비공식 이미지"는 출처·버전 추적·재현성이 떨어지므로 채택하지 않는다.
- **공식 이미지 + `elasticsearch-plugin install analysis-nori` RUN** 으로 Dockerfile 빌드한다(R2 Dockerfile.shop-core 선례처럼 `docker/shop/` 하위 배치).
- 파일: **`docker/shop/Dockerfile.search`**
  ```dockerfile
  # syntax=docker/dockerfile:1
  # Elasticsearch + Nori(한국어 형태소) 분석기 내장 이미지.
  # 베이스 태그는 빌드 인자로 핀(재현성). analysis-nori는 ES 버전과 정확히 일치해야 설치된다.
  ARG ES_IMAGE_TAG=8.15.3
  FROM docker.elastic.co/elasticsearch/elasticsearch:${ES_IMAGE_TAG}
  # 번들 플러그인 — 배치형 자동승인(-b), 오프라인 캐시 불필요(공식 레지스트리 자동 매칭)
  RUN bin/elasticsearch-plugin install --batch analysis-nori
  ```
- 이미지 태그 핀: 베이스 태그를 `ES_IMAGE_TAG` env(기본 `8.15.3`)로 빌드 인자 주입 — compose가 `build.args`로 전달. **`analysis-nori`는 ES 버전과 정확히 동일해야** 설치되므로 단일 태그 변수로 통일한다.
  > **검증 게이트(구현 시 확정 필요):** ES 8.x 정확 패치 태그(`8.15.3`)가 현재 `docker.elastic.co`에 존재하고 `analysis-nori`가 매칭 설치되는지는 `docker build` 시 실측한다. 8.x 라인 내 가용 최신 패치로 핀(latest 금지). ES 8.x는 보안(xpack security)이 기본 ON이므로 **결정 5의 보안 완화 env가 반드시 함께** 적용돼야 단일 노드가 뜬다.

### 결정 3 — Spring 클라이언트: **공식 Elasticsearch Java Client(`co.elastic.clients:elasticsearch-java`) — Spring Boot 자동설정 경유**
- **Spring Data Elasticsearch(repository/template) 채택 안 함.** 본 Task는 인덱스/문서/쿼리 추상이 **0**이므로 repository/template 계층은 전부 미사용 데드코드가 되어 과도설계(plan-reviewer over-spec FAIL 리스크)다.
- Spring Boot 3.5 BOM이 관리하는 **`co.elastic.clients:elasticsearch-java`** 를 쓴다(버전 BOM 위임 — jjwt처럼 명시하지 않음). Spring Boot의 `ElasticsearchClientAutoConfiguration`이 `spring.elasticsearch.*` 프로퍼티로 `ElasticsearchClient` 빈을 자동 구성한다.
- **build.gradle 좌표(정확):**
  ```gradle
  // Elasticsearch 검색 엔진(ADR-011 T1) — 연결·health 와이어링 전용.
  // 공식 Java client. Spring Boot BOM이 버전 관리(elasticsearch-java).
  // 인덱스/매핑/쿼리는 후속 Task(T2+3/T4/T5+6) — 본 Task는 의존+설정+health만.
  implementation 'co.elastic.clients:elasticsearch-java'
  ```
  > **검증 게이트(구현 시 실측):** Spring Boot 3.5.15-SNAPSHOT BOM이 `co.elastic.clients:elasticsearch-java` 버전을 관리하는지(버전 생략 가능 여부)를 `./gradlew dependencies` 또는 컴파일로 확인한다. BOM 미관리로 판명되면 jjwt/redisson 선례대로 버전 명시(ES 8.15.x 라인과 정합하는 client 버전)한다 — 이 경우 build.gradle에 한 줄 버전 주석을 단다.
- **actuator health indicator 자동 노출(핵심 — 결정 5와 연동):** Spring Boot actuator는 Elasticsearch 클라이언트가 클래스패스에 있고 health에 노출되면 **`ElasticsearchRestClientHealthIndicator`(`elasticsearch` health 컴포넌트)** 를 자동 등록한다.
  > **검증 게이트(구현 시 실측 — 추정 금지):** 위 자동 health indicator가 `co.elastic.clients` 경로에서 실제로 자동 등록되는지를 **Testcontainers 연결 통합 테스트에서 `/actuator/health` 응답의 `components.elasticsearch.status == UP`** 으로 실측 단언한다. 만약 자동 indicator가 등록되지 않으면(클라이언트 종류/버전 차이), **최소 커스텀 `HealthIndicator`(ES `info()` ping 1회 → UP/DOWN) 1개**를 `common/search`에 추가한다. 이는 health 노출이 목표이므로 허용되는 최소 코드이며, 인덱스/쿼리 동작이 아니다(범위 경계 유지). 어느 경로든 health up이 **테스트로 증명**돼야 완료.

### 결정 4 — 접속 설정 형태: `SHOP_CORE_SEARCH_*` env (Redis 명명 패턴과 정합)
- 로컬 보안 off라 username/password **불필요** → URI 단일 키로 둔다(Spring Boot `spring.elasticsearch.uris` 바인딩). 운영 매니지드 이관 시 username/password/TLS env를 추가하는 자리만 주석으로 남긴다(본 Task에선 미구현).
- env 키(Redis `SHOP_CORE_REDIS_HOST/PORT/DB` 패턴 계승):
  - **`SHOP_CORE_SEARCH_URIS`** → `spring.elasticsearch.uris` (기본 `http://localhost:9200`)
  - (선택, 매니지드 대비 자리만) `SHOP_CORE_SEARCH_USERNAME` / `SHOP_CORE_SEARCH_PASSWORD` — 로컬/1차 운영은 미사용(빈값). 본 Task에서 yml에 추가하되 기본 빈값으로 두고 주석으로 "1차 미사용"을 명시.
- 호스트 게시 포트는 ES 기본 **9200**(로컬 IDE 앱 접속), 컨테이너 간 cluster transport 9300은 단일 노드라 미게시.

### 결정 5 — actuator health 노출 정책: **포함하되 readiness 그룹에서 제외**
- `SHOP_CORE_MGMT_ENDPOINTS:health,info,prometheus`(최소 노출) 정책 무변경 — `health`가 이미 노출 중이므로 endpoints include 변경 없음.
- 검색 엔진 다운이 **핵심 경로(주문/상세/결제)를 막지 않도록**, ES health를 전체 `/actuator/health`에는 노출하되 **readiness 그룹에서 제외**한다. 운영 compose의 shop-core healthcheck/로드밸런서 트래픽 컷이 ES 다운으로 트리거되지 않게 하기 위함이다(실제 검색 폴백은 T5+6).
  ```yaml
  management:
    endpoint:
      health:
        group:
          readiness:
            include: readinessState   # ES(elasticsearch) 컴포넌트 제외 → ES 다운이 readiness DOWN 유발 안 함
  ```
  > **근거:** Spring Boot 기본 readiness 그룹은 `readinessState`만 포함하므로(외부 health indicator 자동 미포함) **이 명시는 "기본 동작 고정(회귀 가드)"** 성격이다. 단, ES health indicator의 기본 그룹 편입 여부는 버전에 따라 다를 수 있어 **명시 고정**한다. **이 한 줄은 over-spec이 아니라, 향후 Spring Boot/ES 버전 업그레이드에서 `elasticsearch` health indicator가 기본 readiness 그룹에 편입될 가능성에 대비한 명시적 방어선이다** — 그런 변화가 와도 ES 다운이 readiness DOWN→트래픽 컷을 유발하지 않도록 그룹 구성을 우리 의도로 고정해 둔다(검색 다운이 핵심 경로를 막지 않는다는 결정 5의 불변식 보존). 이 방어선이 실제로 유효한지는 아래 검증 게이트에서 ES 컨테이너를 끊은 채 readiness가 ES 영향을 받지 않음을 실측 단언으로 건다. liveness는 `livenessState`(현행 probes.enabled=true) 유지.
  > **검증 게이트:** Testcontainers 테스트에서 ES 컨테이너를 띄운 채 `/actuator/health` 전체는 `elasticsearch` UP을 포함하고, ES를 끊었을 때(또는 readiness 그룹 응답에서) **readiness가 ES 영향을 받지 않음**을 단언한다(최소 1개).

### 결정 6 — 테스트 프로파일에서 검색 자동설정 처리: **test application.yml `spring.autoconfigure.exclude`에 ES 자동설정 2종 추가**
- **이유(메모리 — 풀 컨텍스트 민감성):** 현재 `src/test/resources/application.yml`은 DataSource/JPA/Kafka/Flyway 자동설정을 exclude해 **인프라 없이 풀 `@SpringBootTest`(보안/뷰/컨트롤러 다수, `@MockSharedRepositories` 군) 컨텍스트 로드가 통과**하도록 설계돼 있다. ES 클라이언트 자동설정을 그대로 두면 그 모든 풀 컨텍스트 테스트가 부팅 시 ES 연결/health 와이어링을 시도해 **연쇄 실패** 위험이 있다(Redis는 Lettuce 지연 연결로 살았지만 ES health indicator는 부팅 시 ping 가능성이 있어 보수적으로 차단).
- 처리: test `application.yml`의 `spring.autoconfigure.exclude` 목록에 **ES 클라이언트/REST 자동설정 2종**을 추가:
  ```yaml
  - org.springframework.boot.autoconfigure.elasticsearch.ElasticsearchClientAutoConfiguration
  - org.springframework.boot.autoconfigure.elasticsearch.ElasticsearchRestClientAutoConfiguration
  ```
  > **검증 게이트(정확 FQCN 실측):** 위 자동설정 클래스 FQCN은 Spring Boot 3.5에서 패키지/이름이 다를 수 있으므로 **구현 시 IDE/의존성에서 정확 FQCN을 확인**해 기재한다(추정으로 고정 금지). 이는 testing-rule §슬라이스·프로파일("자동설정 제외 충돌 점검")과 정합.
- **Testcontainers ES 통합 테스트만** 실엔진을 쓴다. 그 테스트는 `@TestPropertySource`로 위 exclude를 **리셋**한다 — `spring.autoconfigure.exclude`는 list가 아니라 **단일 키이므로 `@TestPropertySource`에서 그 키를 덮어쓰면 test `application.yml`의 목록 전체가 교체**된다(누적이 아님). 따라서 ES 자동설정을 재활성하려면 해당 테스트의 `@TestPropertySource`에 `spring.autoconfigure.exclude=`를 ES 2종이 빠진 값(또는 빈값)으로 단일 키 덮어쓰기한다. 그리고 `spring.elasticsearch.uris`를 컨테이너 매핑 포트로 `@DynamicPropertySource` 주입한다. **이 메커니즘(`@ServiceConnection` PostgreSQLContainer + `@DynamicPropertySource` 매핑 포트 주입 + `@TestPropertySource` 단일 키 exclude 덮어쓰기)을 `PasswordResetRedisIntegrationTest`에서 계승한다 — 계승하는 것은 위치가 아니라 이 Testcontainers 메커니즘이다. 메커니즘 동형이며, 신규 테스트의 패키지 위치는 `common/search`로 확정한다**(`PasswordResetRedisIntegrationTest`는 도메인 `security/` 패키지에 있으나, 본 테스트는 ES라는 **횡단 공통 인프라**의 연결·health를 검증하므로 package-structure-rule상 `common/search`가 맞다 — 도메인 `security`와 무관하니 위치를 따라가지 않는다).
- **PG 의존 풀 컨텍스트가 필요한 health 통합 테스트**라면 `@SpringBootTest + @ServiceConnection PostgreSQLContainer`(`PasswordResetRedisIntegrationTest`의 메커니즘 — 위치는 `common/search`)로 PG+ES를 함께 띄운다. 단순 properties 바인딩 테스트는 컨테이너 없이 단위로 둔다.

---

## 영향 범위

### 신규 파일
- `docker/shop/Dockerfile.search` — ES + analysis-nori 빌드
- `shop-core/src/main/java/com/shop/shop/common/search/SearchProperties.java` — `@ConfigurationProperties` 접속 메타(선택적 — 결정 3 검증 후 커스텀 HealthIndicator가 필요할 때만 추가, 아니면 yml만으로 충분)
- `shop-core/src/test/java/com/shop/shop/common/search/SearchClientConnectionIntegrationTest.java` — Testcontainers(elasticsearch) 연결 + actuator health up 통합 테스트. **패키지 위치는 `common/search`로 확정**(ES = 횡단 공통 인프라, package-structure-rule). `PasswordResetRedisIntegrationTest`는 도메인 `security/`에 있으나 위치가 아니라 **Testcontainers 메커니즘**(`@ServiceConnection` PostgreSQLContainer + `@DynamicPropertySource` 매핑 포트 주입 + `@TestPropertySource` 단일 키 `spring.autoconfigure.exclude=` 덮어쓰기)만 계승한다(결정 6).
- `shop-core/src/test/java/com/shop/shop/common/search/SearchPropertiesBindingTest.java` — 접속 설정 바인딩 단위 테스트(권장 테스트)

> `SearchProperties` / `common/search` 패키지는 **결정 3·5 검증 게이트 결과에 따라 조건부**다. ES 자동설정만으로 연결+health가 닿으면(가장 가능성 높은 경로) **main 자바 코드 신규 0**(yml + build.gradle만)이며, 커스텀 health가 필요할 때만 최소 클래스를 추가한다. 패키지 배치는 package-structure-rule상 횡단 공통 → `common` 하위 `search`(Redis가 `common/config`에 있는 것과 동형의 공통 인프라 설정 위치).

### 수정 파일
- `docker/shop/docker-compose.yml` — `shop-search` 서비스 + `shop-search-data` 볼륨
- `docker/shop/docker-compose.prod.yml` — `shop-search` 서비스 + `prod-shop-search-data` 볼륨 + `&shop-core-env`에 `SHOP_CORE_SEARCH_URIS` + shop-core `depends_on`에 `shop-search: service_healthy`
- `docker/shop/.env.example` — `ES_IMAGE_TAG`, `SHOP_CORE_SEARCH_PORT`(호스트 게시) 추가
- `docker/shop/.env.prod.example` — `ES_IMAGE_TAG` 추가
- `shop-core/build.gradle` — `implementation 'co.elastic.clients:elasticsearch-java'` + `testImplementation 'org.testcontainers:elasticsearch'`
- `shop-core/src/main/resources/application.yml` — `spring.elasticsearch.uris` + readiness 그룹 명시
- `shop-core/src/test/resources/application.yml` — `spring.autoconfigure.exclude`에 ES 자동설정 2종 추가

---

## 구현 상세

### docker/shop/Dockerfile.search (신규)
- 역할: 공식 ES 이미지에 `analysis-nori` 설치한 재현 가능한 검색 이미지.
- 내용: 결정 2의 Dockerfile. `ARG ES_IMAGE_TAG` 빌드 인자로 베이스 태그 핀.

### docker/shop/docker-compose.yml — `shop-search` 서비스 추가
```yaml
  # ----------------------------------------------------------
  # 검색 엔진(Elasticsearch + Nori) 단일 노드 — 로컬 개발 전용 (ADR-011 T1)
  # 호스트 게시: 9200 (앱이 localhost:9200로 접속)
  # 로컬 전용 주의: xpack security/TLS OFF. 운영 보안/멀티노드 구성을 가장하지 않는다(Redis 005 원칙).
  # Nori는 Dockerfile.search 빌드 시 analysis-nori 플러그인으로 내장(_cat/plugins로 확인).
  # 색인/매핑/쿼리는 후속 Task(T2+3/T4/T5+6) — 본 노드는 기동·연결·health up까지만.
  # ----------------------------------------------------------
  shop-search:
    build:
      context: .
      dockerfile: Dockerfile.search
      args:
        ES_IMAGE_TAG: ${ES_IMAGE_TAG:-8.15.3}
    image: shop-search:${ES_IMAGE_TAG:-8.15.3}     # 빌드 결과 태깅(버전 핀)
    container_name: shop-search
    environment:
      TZ: Asia/Seoul
      discovery.type: single-node                  # 단일 노드 클러스터
      xpack.security.enabled: "false"              # 로컬 보안 완화(AUTH/TLS off) — 운영 가장 금지
      ES_JAVA_OPTS: ${ES_JAVA_OPTS:--Xms512m -Xmx512m}   # 로컬 힙 상한 보수적 고정(메모리 폭주 방지)
      bootstrap.memory_lock: "false"          # mlock 권한 없는 로컬 환경에서 단일 노드 기동 안정성 위한 보수값(task엔 없으나 over-spec 아님 — 로컬 부팅 실패 방지)
    ports:
      - "${SHOP_CORE_SEARCH_PORT:-9200}:9200"      # 호스트 IDE 앱 접속(9300 transport는 단일노드라 미게시)
    volumes:
      - shop-search-data:/usr/share/elasticsearch/data
    healthcheck:
      # 단일 노드는 cluster status yellow가 정상(레플리카 미할당). yellow|green 둘 다 healthy로 인정.
      test: ["CMD-SHELL", "curl -fsS http://localhost:9200/_cluster/health | grep -qE '\"status\":\"(green|yellow)\"' || exit 1"]
      interval: 10s
      timeout: 10s
      retries: 10
      start_period: 60s                            # ES 부팅이 느림 — PG·Redis(10s)보다 넉넉히
    networks:
      - shop-net
    restart: unless-stopped
```
- `volumes:` 블록에 `shop-search-data: { driver: local }` 추가.
- **`bootstrap.memory_lock: "false"` 사유:** task에 명시되지 않은 추가 env이나 over-spec이 아니다 — mlock(메모리 잠금) 권한이 없는 로컬 개발 환경에서 ES 단일 노드가 부팅 실패하지 않도록 하는 **보수값**이다(memory_lock을 켜면 권한 없는 호스트에서 부트스트랩 체크에 막혀 컨테이너가 기동 못 함). 운영 매니지드 이관 전까지의 로컬·1차 단일 노드 안정성 목적이며, 운영 보안/성능 튜닝(가장)이 아니다.
> **검증 게이트:** ES 공식 이미지에 `curl`이 포함되는지 실측(미포함 시 healthcheck를 `wget` 또는 ES 내장 도구로 교체). 003/005 compose는 PG `pg_isready`·Redis `redis-cli`처럼 이미지 내장 도구를 썼다.

### docker/shop/docker-compose.prod.yml — `shop-search` 서비스 추가
- 동일 엔진. **차이점(운영 패턴 — prod Kafka/Redis 계승):**
  - **호스트 포트 미게시**(`ports:` 없음 — 내부망 전용, 공격 표면 축소).
  - 볼륨 `prod-shop-search-data`(prod- 접두), `volumes:` 블록에 선언.
  - 동일 `build`(context `.`, `Dockerfile.search`) + `image: shop-search:${ES_IMAGE_TAG:-8.15.3}`.
  - 운영 보안 미가장 주석: `# 운영 보안(인증/TLS)·멀티노드는 매니지드 이관(Elastic Cloud) 또는 후속 운영 Task 범위 — 1차는 단일 노드 + 보안 완화(ADR-011/Task 006 Constraints).`
- `&shop-core-env` 앵커에 키 추가(컨테이너 DNS 이름):
  ```yaml
      SHOP_CORE_SEARCH_URIS: http://shop-search:9200
  ```
- `x-shop-core-common`의 `depends_on`에 추가:
  ```yaml
      shop-search:
        condition: service_healthy
  ```
  (shop-core-1/2 둘 다 앵커 상속이라 자동 반영.)

### docker/shop/.env.example / .env.prod.example
- 공통: `ES_IMAGE_TAG=8.15.3   # latest 금지 — 재현성. analysis-nori는 이 ES 버전과 정확히 일치 설치.`
- `.env.example`만: `SHOP_CORE_SEARCH_PORT=9200   # 호스트 포트 충돌 시 변경(앱 SHOP_CORE_SEARCH_URIS도 동시 변경)`
- `.env.prod.example`만: `ES_IMAGE_TAG=8.15.3`(호스트 포트 미게시이므로 SEARCH_PORT 없음).

### shop-core/build.gradle
- Persistence/Redis 의존 블록 인근에 ES client 추가(결정 3 좌표).
- Test 블록에 Testcontainers ES 모듈:
  ```gradle
  // Elasticsearch — 검색 엔진 연결·health 와이어링 검증용 실엔진 통합 테스트. 버전은 testcontainers-bom 위임.
  testImplementation 'org.testcontainers:elasticsearch'
  ```
  > **검증 게이트:** `org.testcontainers:elasticsearch` 모듈명/BOM 관리 여부 실측(postgresql/minio가 이미 BOM 위임이라 동형 기대). 테스트 JVM `-Xmx1536m` 상한(현 설정)에 ES 컨테이너 추가 메모리 압박이 없는지 풀스위트 1회 확인(메모리 OOM→고아 컨테이너 선례).

### shop-core/src/main/resources/application.yml
- `spring` 하위(Redis `data.redis` 블록 인근)에 추가:
  ```yaml
    # Elasticsearch 검색 엔진(ADR-011 T1) — 보조 인덱스 연결.
    # 로컬 단일 노드, 보안 off라 자격증명 불필요. 매니지드 이관 시 username/password/TLS 추가.
    # 색인/쿼리는 후속 Task — 본 설정은 연결·health 와이어링 전용.
    elasticsearch:
      uris: ${SHOP_CORE_SEARCH_URIS:http://localhost:9200}
  ```
- `management.endpoint.health`에 readiness 그룹 명시(결정 5).

### shop-core/src/test/resources/application.yml
- `spring.autoconfigure.exclude` 목록에 ES 자동설정 2종 추가(결정 6, FQCN은 검증 게이트로 확정).

---

## 데이터 흐름 (부팅 시 연결·health 와이어링)
1. compose: `shop-search` 컨테이너 기동 → ES 단일 노드 부팅(보안 off) → healthcheck `_cluster/health` yellow/green → healthy.
2. (운영) shop-core는 `depends_on: shop-search service_healthy`로 ES ready 후 기동.
3. shop-core 부팅: `spring.elasticsearch.uris` → Spring Boot `ElasticsearchClientAutoConfiguration`이 `ElasticsearchClient` 빈 자동 구성(연결은 클라이언트 특성상 첫 사용/health ping 시점).
4. actuator: `elasticsearch` health indicator 자동 등록 → `/actuator/health.components.elasticsearch.status`. readiness 그룹은 `readinessState`만 → ES 다운이 readiness DOWN 유발 안 함.
5. 블로킹 ES I/O는 클라이언트 빈(Service/Infra 경계)에 격리. 본 Task는 직접 `ThreadLocal` 미사용(CLAUDE.md 가상스레드 대비).

---

## 예외 처리 전략 (검색 엔진 다운 시 — 핵심 경로 비차단)
- **부팅:** ES 미가용이어도 shop-core가 부팅 실패하지 않아야 한다(Redis Lettuce 지연 연결과 동형 목표). ES client 빈 생성이 즉시 연결을 강제하지 않는 한 부팅은 통과.
  > **검증 게이트(추정 금지):** ES 자동설정 빈이 부팅 시 eager 연결을 시도하는지 실측. eager로 부팅이 막히면, ES 미가용 시에도 컨텍스트가 로드되도록 보장(필요 시 client 빈 lazy 구성 — RedissonConfig `lazyInitialization` 선례). 이를 **"ES 컨테이너 없이 컨텍스트 로드 통과"** 테스트(또는 test 프로파일 ES 자동설정 exclude로 이미 보장)로 증명.
- **운영 health:** ES 다운 → `/actuator/health` 전체는 `elasticsearch DOWN`을 표시하되 **readiness는 UP 유지**(결정 5) → LB 트래픽·핵심 경로 비차단.
- **실제 검색 폴백(pg_trgm/LIKE graceful degrade)은 T5+6 범위** — 본 Task는 health/readiness 격리 방향만.

---

## Spring Boot 컨벤션
- 패키지: 횡단 공통 → `com.shop.shop.common.search`(필요 시). Redis가 `common/config`에 있는 것과 동형. 도메인(`product` 등) 무변경.
- `@ConfigurationProperties`(필요 시): RedisProperties record 스타일 계승(기본값 폴백 compact 생성자). 단 ES URI는 Spring Boot 표준 `spring.elasticsearch.*`로 충분하므로 **커스텀 properties는 결정 3·5 검증 결과 커스텀 health가 필요할 때만** 추가(YAGNI).
- env:default 바인딩(`${SHOP_CORE_SEARCH_URIS:http://localhost:9200}`) — 기존 컨벤션 동일.
- 예외 처리: 본 Task는 비즈니스 예외 신설 0(연결·health만).

---

## 검증 방법
1. **compose config 양쪽:**
   - `docker compose -f docker/shop/docker-compose.yml config` 성공
   - `docker compose -f docker/shop/docker-compose.prod.yml config` 성공
2. **엔진 기동 + Nori 확인(수동 — 보고에 기록):**
   - `docker compose -f docker/shop/docker-compose.yml up -d shop-search`
   - `_cluster/health` status green/yellow(단일 노드 yellow 정상)
   - `_cat/plugins`에 `analysis-nori` 노출(Nori 내장 확인)
   - `curl http://localhost:9200/_cluster/health` 200
3. **Testcontainers 연결·health up 통합 테스트(자동):**
   - `org.testcontainers:elasticsearch`로 ES(Nori 빌드 이미지 또는 공식 ES 이미지) 컨테이너 기동
   - `spring.elasticsearch.uris`를 매핑 포트로 `@DynamicPropertySource` 주입
   - **`/actuator/health.components.elasticsearch.status == UP`** 실측 단언(결정 3 핵심 게이트)
   - readiness 그룹이 ES 영향 받지 않음 단언(결정 5)
   > Nori 설치 여부 단언은 본 Task 범위(연결+health) 밖이므로 통합 테스트에선 굳이 안 함 — Nori는 매핑/분석기를 쓰는 T2+3에서 검증. 본 Task는 compose 수동 `_cat/plugins`로만 확인.
4. **접속 properties 바인딩 단위 테스트:** `spring.elasticsearch.uris` 바인딩 + 기본값 검증.
5. **전체 컨텍스트 회귀(메인이 직접 — verification-gate §2):** `./gradlew test` 전체 `BUILD SUCCESSFUL`. 특히 **풀 `@SpringBootTest`(보안/뷰/컨트롤러·`@MockSharedRepositories` 군) 컨텍스트 로드가 ES 의존 추가로 깨지지 않음**을 확인(결정 6 exclude가 막는지 baseline 대조). additive diff도 컴포넌트 스캔으로 회귀 가능(§4).
6. **범위 경계 확인(검색 동작 코드 0):** 인덱스 생성·매핑·Nori 분석기 정의·문서 색인·검색 쿼리·재색인 코드가 추가되지 않았음(`product` 도메인·Flyway·Kafka 계약·notification 무변경) 리뷰에서 확인.

---

## 트레이드오프
- **벤더(ES vs OpenSearch):** ES = Spring Boot 1급 자동설정·actuator health로 본 Task 최소 코드 달성(채택). OpenSearch = Apache 2.0로 라이선스는 더 단순하나, Spring 기본 자동설정·health 부재로 본 Task에서 커스텀 배선이 늘어 과도설계화 → 미채택. ELv2 자체호스팅 리스크 없음으로 ES의 라이선스 단점이 본 용례에 무영향.
- **클라이언트(공식 Java client vs Spring Data ES):** 공식 client = 인덱스/쿼리 추상 0인 본 Task에 정확히 맞는 최소 의존(채택). Spring Data ES = repository/template이 전부 데드코드 → over-spec 미채택. 후속 T2+3에서 색인 추상이 필요해지면 그때 도입 여부 재결정(YAGNI).
- **자체호스팅 vs 매니지드:** 1차 자체호스팅 compose 노드(ADR-011 고정 결정). 운영 부담·정합성 영구 부채를 짊어지나, 비용·로컬 재현성 우위. 매니지드(Elastic Cloud) 이관은 `SHOP_CORE_SEARCH_URIS`/자격증명 교체만으로 가능하게 설정 분리(운영 메모) — 본 Task는 자리만, 미구현.
- **Dockerfile 빌드 vs 동봉 이미지:** 빌드 = 재현성·출처 신뢰(채택, 빌드 시간 비용 감수). 동봉 비공식 이미지 = 즉시성이나 버전·출처 추적성 약화 미채택.
- **test 자동설정 exclude vs lazy 연결:** exclude = 풀 컨텍스트 안전(보수적, 채택). lazy만으로 충분할 수도 있으나(Redis 선례) ES health indicator 부팅 ping 리스크를 회피하려 exclude로 확실히 차단. Testcontainers 테스트만 리셋해 실엔진 검증.

---

## 완료 조건
- [ ] 로컬/운영 compose에 `shop-search`(ES+Nori) 단일 노드 추가, `docker compose ... config` 양쪽 성공
- [ ] 이미지 태그 `ES_IMAGE_TAG` env+기본 핀, `analysis-nori` 내장(`_cat/plugins` 확인), TZ=Asia/Seoul, healthcheck(start_period 넉넉), named volume(local `shop-search-data`/prod `prod-shop-search-data`), shop-net, restart
- [ ] 운영: 호스트 포트 미게시, shop-core `depends_on: shop-search service_healthy`, `SHOP_CORE_SEARCH_URIS` 주입, 운영 보안 미가장 주석
- [ ] shop-core `co.elastic.clients:elasticsearch-java` 의존 + `spring.elasticsearch.uris`(SHOP_CORE_SEARCH_URIS) 설정
- [ ] actuator `/actuator/health`에 `elasticsearch` 노출 + readiness 그룹에서 제외(핵심 경로 비차단)
- [ ] test 프로파일 ES 자동설정 exclude(풀 컨텍스트 비차단), Testcontainers 통합 테스트만 실엔진
- [ ] Testcontainers 연결·health up 통합 테스트 + properties 바인딩 테스트 작성, `./gradlew test` 전체 그린
- [ ] 검색 동작 코드(인덱스/매핑/Nori 정의/색인/쿼리/재색인) 0, product/Flyway/Kafka/notification 무변경

---

## 구현 시 반드시 해소할 검증 게이트(추정 금지 — 코드/빌드/테스트로 확정)
1. ES 8.x 정확 패치 태그 가용성 + `analysis-nori` 매칭 설치(`docker build` 실측)
2. Spring Boot 3.5.15-SNAPSHOT BOM의 `co.elastic.clients:elasticsearch-java` 버전 관리 여부(미관리 시 명시)
3. **`elasticsearch` actuator health indicator 자동 등록 여부**(Testcontainers `/actuator/health` 실측 — 미등록 시 최소 커스텀 HealthIndicator 1개)
4. test `spring.autoconfigure.exclude` ES 자동설정 정확 FQCN(2종)
5. ES client 빈 부팅 시 eager 연결 여부(eager면 lazy 구성으로 "ES 없이 부팅 통과" 보장)
6. ES 공식 이미지 healthcheck 도구(curl/wget) 존재
7. `org.testcontainers:elasticsearch` 모듈 BOM 관리 + 테스트 JVM 메모리 영향(`-Xmx1536m`)

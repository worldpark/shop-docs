# Testing Rule

테스트 작성·검증 규칙. Task 수행 규칙(`docs/rules/task-rule.md`)의 "테스트 없이 기능 추가 금지"를 구체화한다.
누적되는 결함 패턴과 배경은 `docs/review-patterns.md`를 따른다.

## 공통
- 테스트 없이 기능/의존성 변경을 완료 처리하지 않는다.
- 테스트 레이어와 도구:
  - 단위: JUnit 5 + Mockito.
  - DB 통합: `@DataJpaTest` + **Testcontainers(PostgreSQL)**. H2로 재현 불가한 PostgreSQL 고유 동작(예: NULL 파라미터 타입 추론) 회귀를 잡는다.
  - 브라우저 E2E: **Playwright for Java**. 핵심 사용자 여정을 얇게 검증한다. 방식·운영 주의는 `docs/plans/performance/001-e2e-playwright-java-test-strategy.md`, 실행은 `shop-core/src/e2eTest/README.md`.
- 통과한 테스트 "개수"를 안전의 근거로 삼지 않는다. 무엇을 검증했는지를 근거로 삼는다.

## 테스트 더블(mock/fake/@Primary)과 운영 배선
- 어떤 인터페이스를 `@MockitoBean`/`@Primary` fake로 대체하면, **그 인터페이스의 운영 구현체는 그 테스트에서 검증되지 않는다.** 이를 전제로 한다.
  - 테스트 더블 애너테이션은 Spring Boot 3.4+에서 deprecated된 `@MockBean`/`@SpyBean` 대신 `@MockitoBean`/`@MockitoSpyBean`(`org.springframework.test.context.bean.override.mockito.*`)을 사용한다.
- 운영 구현체가 운영과 동일한 조건(컴포넌트 스캔 + 자동설정)에서 **실제로 빈으로 등록되는지** 검증하는 테스트를 별도로 둔다.
  - 예: fake를 import하지 않고 `@SpringBootTest`로 컨텍스트를 띄워 `assertThat(context.getBean(Iface.class)).isInstanceOf(RealImpl.class)`를 단언한다.
  - 이 회귀 테스트는 **버그가 있던 코드에서 반드시 실패**해야 의미가 있다.
- 테스트용 fake/더블은 `@Component`로 자동 스캔되게 두지 않는다. `@Import` 전용(또는 직접 `new`)으로 두어 운영 배선 검증 테스트에 새어 들어가지 않게 한다.
- 테스트에서 인프라 연결을 피하려고 **운영 구현체의 의존 빈을 자동설정 제외로 통째로 없애지 않는다.**
  - 자동설정 제외는 운영 구현체가 테스트에서 절대 생성되지 않게 만들어 거짓 통과를 유발한다.
  - 대안: 지연 연결(예: Lettuce는 첫 명령 시 연결)을 활용해 빈은 생성하되 연결만 미루거나, 동작만 fake로 교체한다.

## 컨텍스트/배선 검증
- 필터·컨트롤러·서비스의 주입 의존이 운영에서 모두 해결되는지, "운영과 동일한 컴포넌트 스캔 + 자동설정" 컨텍스트 테스트로 확인한다.
- `@ConditionalOnBean` / `@ConditionalOnProperty` 등 조건부 빈은 테스트에서 조건이 충족되는 경로를 최소 1개 검증한다(조건이 항상 거짓이면 그 빈은 테스트 대상에서 사라진다).

## 슬라이스·프로파일
- 인프라 미가용 환경에서 도는 슬라이스 테스트(@DataJpaTest 등)는 DB 종류 차이(예: PostgreSQL citext/trigger ↔ H2)와 프로파일별 자동설정 제외 충돌을 점검한다.
- 통합 테스트에서 자동설정 제외 정책을 리셋(`spring.autoconfigure.exclude=`)하면, 의도치 않게 살아나는 자동설정(Redis/Flyway 등)이 테스트를 깨거나 거짓 통과시키지 않는지 확인한다.

## 검증 실행
- 변경한 프로젝트에서 `./gradlew test` 전체 통과를 확인한다.
- 인프라(DB/Kafka/Redis)가 필요한 실동작은 가능하면 로컬 docker-compose로 수동 확인하고, 확인/미확인 항목을 작업 보고에 남긴다.
- 브라우저 E2E(`./gradlew e2eTest`)는 `check`/`test`에 포함되지 않는 **별도 태스크**다(실행 중인 앱 필요 — 일반 `test`의 인프라 비의존 원칙 보존). 실행/판정은 `e2e-runner` 에이전트 또는 CI 스텝이 담당한다.

## 서비스 간 이벤트 종단(end-to-end) 스모크 — 필수
> 배경/실증: `docs/plans/revisions/backend/shop-core-modulith-externalization-serializer-bug-and-e2e-smoke-revision-1.md`(shop-core 외부화 이중 직렬화 버그를 라이브 종단 스모크로만 발견).

- **이벤트 드리븐 통합(shop-core 발행 → notification 소비)에는 토픽별 종단 스모크를 최소 1개 둔다.** 발행측이 **무증상**이기 때문이다: 외부화가 "성공" 커밋돼도 wire 직렬화가 깨지면 발행측엔 예외가 없고, 결함은 **오직 컨슈머 역직렬화에서만** 드러난다.
- 아래 계층은 이 결함(발행 wire ↔ 소비 계약 불일치)을 **구조적으로 놓친다 — 이것들로 대체 금지**:
  - in-process 캡처(`@TransactionalEventListener(AFTER_COMMIT)` + `externalization.enabled=false`): 직렬화/wire 단계를 타지 않는다.
  - 컨슈머 단독 통합(컨슈머 자신의 DTO로 produce하는 EmbeddedKafka): **합성 이벤트**라 실제 발행측 직렬화 경로를 안 거친다.
  - 순진한 wire 테스트도 `application.yml` **classpath shadow**(test resource가 main을 가림)로 production 직렬화 설정을 안 읽어 **false-pass**할 수 있다(실증됨).
- **종단 스모크의 정의**: **실제 발행측 경로(`@Externalized`/Outbox)로 발행된 실 이벤트** → 실제 컨슈머 → **종단 상태 도달**(예: notification `processed_event` `SENT` + 발송 로그)을 단언. **합성 이벤트 주입으로 대체하지 않는다.**
- **비용 절감 조합 허용**: 토픽 전수 대신 (a) 공유 발행 경로를 대표하는 **1~2개 종단 스모크** + (b) **직렬화 설정 회귀 가드**(production `application.yml` 값을 파일경로로 직접 읽어 단언 — classpath shadow 우회)를 조합해도 된다. 핵심은 "**실 wire가 실 컨슈머에서 처리되는가**"를 CI가 한 번은 확인하는 것.
- **배치**: 종단 스모크가 일반 `test`의 인프라 비의존 원칙과 충돌하면(docker-compose 양 앱 기동 등) 브라우저 E2E처럼 **별도 태스크/스텝**으로 분리하고 `e2e-runner` 또는 CI 스텝이 담당한다. EmbeddedKafka로 발행측 외부화 경로를 실제로 태울 수 있으면 `test` 내에 두되, **effective 직렬화 설정을 명시 고정**해 라이브러리 기본값에 암묵 의존하지 않는다.
- **회귀 가드의 RED는 경험으로 확인한다**(공통 §"통과 개수를 안전 근거로 삼지 않는다" 연장): "버그 설정에서 실패"는 **실제로 토글해 RED를 확인**해야 보장된다 — precedence/이론 추론으로 갈음하지 않는다.

# In-App Kafka 컨슈머 · 외부 엔진(ES) 통합 규칙

shop-core에 **인앱 Kafka 컨슈머**나 **외부 엔진(Elasticsearch 등) 의존 빈**을 추가할 때의 가드레일. `docs/rules/verification-gate-rule.md`(§4 가산적 빈 회귀)·`docs/rules/event-contract-rule.md`·`docs/rules/testing-rule.md`를 보완한다.

> 배경/실증(Task 059 — shop-core 최초 인앱 Kafka 컨슈머 + ES 색인): 타깃 테스트는 전부 그린이었으나 **풀 `./gradlew test`에서만** 드러난 결함 3종(① 프로파일 게이팅으로 41개 컨텍스트 로드 실패, ② Kafka producer 누수로 병렬 스위트 행, ③ `save()` 반환값 미사용 NPE)이 연속 발생했다. 모두 "메인이 풀 스위트를 직접 돌린다"는 검증 게이트가 잡았다. 본 규칙은 그 함정을 사전에 닫는다.

## 1. 빈 게이팅 — `@Profile("…| !test")` 금지, `@ConditionalOnProperty` default-off 사용
- shop-core의 풀 `@SpringBootTest` 통합 테스트들은 **active profile 없이**(`activeProfiles=[]`) 실행된다. 따라서 `@Profile("kafkatest | !test")` 같은 게이트는 `!test`가 **참**이 되어 빈이 **활성화**된다(notification 레포의 컨슈머 패턴을 그대로 복제하면 안 된다 — notification과 프로파일 컨벤션이 다르다).
- 활성화된 컨슈머 설정이 `${spring.kafka.bootstrap-servers}` 등 test `application.yml`에 없는 placeholder를 요구하면 **컨텍스트 로드가 연쇄 실패**한다.
- 규칙: "운영/로컬·특정 통합 테스트에서만 켜고 나머지 전부 끄는" 빈은 **`@ConditionalOnProperty(name="…enabled", havingValue="true")` default-off**로 게이트한다. main `application.yml`에서만 `${ENV:true}`로 켜고, 그 빈이 필요한 통합 테스트만 `@TestPropertySource`로 `=true` + 필요한 인프라(EmbeddedKafka bootstrap-servers 등)를 주입한다.
- 외부 엔진 클라이언트(ES `ElasticsearchClient` 등)에 의존하는 빈은 **`@AutoConfiguration(after = …ClientAutoConfiguration.class) + @ConditionalOnBean(클라이언트.class)`** 로 등록한다(`META-INF/spring/…AutoConfiguration.imports`). `@ConditionalOnBean`을 `@Component`/`@Service`/일반 `@Configuration`에 직접 붙이면 컴포넌트 스캔 시점(자동설정 前)에 조건이 평가돼 항상 false가 된다.

## 2. Kafka 클라이언트 자원 수명 — 빈 밖 생성물은 명시적으로 close
- Spring 라이프사이클 밖에서 만든 Kafka 클라이언트(`DefaultKafkaProducerFactory`/`KafkaTemplate`/`Consumer`)는 컨텍스트 종료 시 **자동 정리되지 않는다.** 정리하지 않으면 **EmbeddedKafka 브로커가 종료된 뒤에도 producer가 무한 재연결**을 시도하며, 풀 **병렬 fork** 스위트에서 fork JVM 종료를 막아 **행(hang)** 을 유발한다(로그가 `Connection to node … could not be established`로 폭주).
- 규칙(설정 빈): DLQ 발행용 producer factory처럼 `@ConditionalOnMissingBean(ProducerFactory/KafkaTemplate)` 충돌을 피하려 **빈이 아닌 인스턴스**로 만들었다면, 설정 클래스가 `DisposableBean`을 구현해 `destroy()`에서 그 factory를 `destroy()` 한다.
- 규칙(테스트): 테스트가 직접 만든 `KafkaTemplate`/`DefaultKafkaProducerFactory`/`Consumer`는 **try-with-resources 또는 finally에서 close/destroy** 한다. Kafka/ES를 띄우는 통합 테스트에는 **`@DirtiesContext`(AFTER_CLASS)** 로 컨슈머 컨테이너·외부화 producer를 확실히 정리한다.

## 3. dual-write 금지 · 멱등 · DLQ (외부 엔진 색인)
- 외부 엔진(ES) 색인은 **트랜잭션 내 직접 쓰기 금지(dual-write)**. 도메인 변경은 outbox 이벤트(Spring Modulith `@Externalized`)로만 발행하고, 인덱서 컨슈머가 외부 엔진에 반영한다(`docs/adr/011-*`).
- 컨슈머는 **멱등** 처리(문서 `_id`=도메인 PK upsert, 필요 시 occurredAt 기반 external version으로 순서 역전 보호). 순서 역전/버전 충돌은 **정상 무시**(DLQ로 보내지 않음), 그 외 실패만 `DefaultErrorHandler` 재시도 → `.DLQ` 격리.
- 운영 broker는 auto-create off이므로 **`.DLQ` 토픽도 `NewTopic` 빈으로 선언**한다(토픽 프로비저닝 SSOT — `KafkaTopicConfig`).
- 색인 토픽은 **notification 비구독**(알림 6종과 별개 계약)임을 `docs/event-catalog.md`·`docs/architecture.md` §5에 명시한다.

## 4. 검증 — 풀 스위트는 메인이 직접, 타깃은 못 잡는다
- 위 1~2의 회귀(컨텍스트 로드 실패·병렬 행)는 **타깃 `--tests` 실행에선 보이지 않는다**(해당 컨텍스트/병렬 조건을 재현하지 않음). 단계 종료 전 **메인 에이전트가 풀 `./gradlew test`를 직접 1회** 돌려 `BUILD SUCCESSFUL`을 자기 눈으로 확인한다(`verification-gate-rule` §2).
- 부수 가드: 도메인 메서드는 `repository.save(entity)`의 **반환(영속) 엔티티**를 사용한다. 반환을 버리고 로컬 엔티티를 쓰면 운영(IDENTITY로 id 채워짐)에선 무해하지만, `save`를 목하는 테스트에서 **null id 역참조(NPE)** 로 깨진다 — 운영-테스트 동작 분기의 흔한 원인(Task 059 실증).

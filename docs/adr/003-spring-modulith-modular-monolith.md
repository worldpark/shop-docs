# ADR-003 — shop-core를 Spring Modulith 모듈러 모놀리스로 구성

- 작성일: 2026-06-10
- 상태: Accepted
- 범위: shop-core

## 맥락

`shop-core`는 회원, 상품, 장바구니, 주문, 결제, 재고를 포함하는 핵심 거래 시스템이다. 도메인 경계는 분명히 나누고 싶지만, 현재 단계에서 각 도메인을 별도 배포 서비스로 분리하면 운영·테스트·트랜잭션 복잡도가 빠르게 증가한다.

다만 장기적으로는 일부 모듈을 별도 서비스로 분리할 수 있다. 이때 호출 코드를 대규모로 바꾸지 않도록, 모듈 간 데이터 접근은 구현체가 아니라 port/published API에 의존하게 둔다. 현재는 같은 프로세스 안의 in-process 구현 빈을 사용하고, 분리 시점에는 같은 port를 구현하는 HTTP client, Kafka request/reply, event projection consumer 같은 adapter 빈으로 교체할 수 있어야 한다.

검토한 대안은 다음과 같다.

| 대안 | 장점 | 단점 |
|---|---|---|
| 단일 레이어드 모놀리스 | 초기 구현이 가장 단순 | 도메인 경계가 흐려지고 장기적으로 결합 증가 |
| 마이크로서비스 | 독립 배포와 확장성 | 현재 규모 대비 운영 복잡도 과다, 분산 트랜잭션/사가 부담 |
| Spring Modulith 모듈러 모놀리스 | 한 프로세스 안에서 명확한 모듈 경계와 테스트 가능 | 경계 규칙을 꾸준히 지켜야 함 |

## 결정

`shop-core`는 Spring Modulith 기반 모듈러 모놀리스로 구성한다.

- 도메인 경계는 Spring Modulith application module로 표현한다.
- 모듈 간 비공개 구현 패키지 직접 참조를 금지한다.
- 모듈 간 비동기 통지는 Spring Modulith application event를 우선 사용한다.
- 동기 조회가 꼭 필요하면 각 모듈이 노출한 published API 또는 port를 통해 호출한다.
- port/published API의 호출자는 통신 방식에 의존하지 않는다. 현재 구현은 in-process 빈이지만, 모듈 분리 시 같은 계약을 구현하는 HTTP/Kafka adapter 빈으로 교체할 수 있게 둔다.
- 모듈 밖으로 Entity를 노출하지 않고 DTO/scalar를 사용한다.
- `notification`으로 나가는 Kafka 이벤트와 shop-core 내부 Modulith 이벤트를 구분한다.

## 결과

긍정적 결과:

- 하나의 애플리케이션 안에서 주문·결제 같은 강한 트랜잭션 경계를 유지할 수 있다.
- 도메인 모듈 경계를 코드와 테스트로 검증할 수 있다.
- 향후 특정 모듈을 별도 서비스로 분리할 때 포트와 이벤트 경계가 출발점이 된다.
- 모듈 분리 시 호출자 코드는 유지하고, port 구현 빈을 in-process 구현에서 HTTP/Kafka adapter로 바꾸는 전환 경로를 가질 수 있다.
- 포트폴리오 목적상 마이크로서비스를 과도하게 늘리지 않고도 모듈 설계를 보여줄 수 있다.

부정적 결과와 대응:

- 같은 프로세스 안에 있으므로 경계를 쉽게 우회할 수 있다.
  - package structure rule과 Modulith 구조 테스트로 우회를 차단한다.
- published API가 무분별하게 늘면 사실상 내부 호출망이 된다.
  - 우선순위는 내부 application event이며, 동기 API는 필요한 조회에 한정한다.
- port가 현재 in-process 구현 세부사항을 노출하면 나중에 HTTP/Kafka adapter로 교체하기 어렵다.
  - port 시그니처는 web 타입, Entity, Repository 모델을 받거나 반환하지 않고, 모듈 소유 DTO와 scalar만 사용한다.
- payment 같은 모듈은 나중에 별도 서비스 후보가 될 수 있다.
  - 현재는 모듈러 모놀리스로 안정화하고, 분리 확정 시 별도 ADR과 migration plan을 작성한다.

## 관련 문서

- `docs/architecture.md`
- `docs/rules/architecture-rule.md`
- `docs/rules/package-structure-rule.md`
- `docs/backlog/backend/remaining-tasks-roadmap.md`

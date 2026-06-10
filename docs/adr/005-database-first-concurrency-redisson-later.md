# ADR-005 — 현재는 DB 기반 동시성 제어를 우선하고 다중 노드 단계에서 Redisson을 도입

- 작성일: 2026-06-10
- 상태: Accepted
- 범위: shop-core 동시성 제어

## 맥락

`shop-core`에는 회원가입 이메일 중복, 장바구니 항목 중복, 주문 생성 재고 차감, 결제 확정, 상품 이미지 개수 제한, 쿠폰 발급 한도처럼 동일 자원에 대한 동시성 경합 지점이 있다.

현재 프로젝트는 로컬/개발 환경과 단일 애플리케이션 인스턴스를 중심으로 구현 중이다. 하지만 향후 다중 노드 배포 단계에서는 여러 애플리케이션 인스턴스가 같은 도메인 자원을 동시에 변경할 수 있으므로 노드 간 직렬화 수단이 필요해진다.

검토한 대안은 다음과 같다.

| 대안 | 장점 | 단점 |
|---|---|---|
| 모든 경합에 Redisson 선도입 | 다중 노드 전환 준비가 빠름 | 사용처가 확정되지 않은 락 의미론과 운영 복잡도 증가 |
| DB 제약과 row lock만 사용 | 구현이 단순하고 PostgreSQL이 최종 정합성 권위가 됨 | DB 밖 임계구역이나 집합 단위 자원에는 한계 |
| 단계적 전략 | 현재는 DB 기반으로 닫고, 다중 노드 단계에서 Redisson 도입 | 전환 시점에 별도 작업과 회귀 검증 필요 |

## 결정

현재 단계에서는 PostgreSQL 기반 동시성 제어를 우선한다.

- unique/check 제약
- 조건부 UPDATE
- 상태 전이 조건
- `PESSIMISTIC_WRITE` row lock
- 트랜잭션 안 권위 재검증

Redisson 분산락은 배제하지 않는다. 향후 다중 노드 배포 단계에서 동일 도메인 자원에 대한 노드 간 경합을 직렬화하기 위해 도입한다.

Redisson 도입 후보는 다음과 같다.

- 다중 노드에서 같은 자원을 동시에 처리하는 scheduler 또는 consumer
- DB 단일 row lock으로 표현하기 어려운 집합 단위 자원
- 상품 이미지 개수 상한처럼 check-then-act race가 존재하는 기능
- 쿠폰 총 발급/사용 한도처럼 자원 key 단위 직렬화가 필요한 기능
- 외부 API, 파일 저장, Kafka 발행 전후 보상 로직이 함께 걸린 임계구역

Redisson 도입 후에도 DB 제약과 상태 검증은 최종 정합성 방어선으로 유지한다. Redisson은 직렬화 수단이지 최종 정합성 근거가 아니다.

## 결과

긍정적 결과:

- 현재 구현은 PostgreSQL 트랜잭션과 제약을 기준으로 단순하고 검증 가능하게 유지된다.
- 다중 노드 전환 전까지 불필요한 분산락 운영 복잡도를 피한다.
- Redisson 도입 시에도 DB 방어선을 유지하므로 락 장애나 lease 문제에 대한 피해를 줄일 수 있다.
- 적용 대상과 lock key, wait time, lease time, timeout 정책을 도메인별로 명확히 정의할 수 있다.

부정적 결과와 대응:

- 일부 기능은 다중 노드 전환 전까지 best-effort 동시성으로 남을 수 있다.
  - 해당 지점은 backlog와 task 문서에 명시하고, 엄격 보장이 필요한 시점에 Redisson 적용 task로 승격한다.
- 나중에 Redisson을 도입할 때 코드 변경이 필요하다.
  - Service 내부에 락 API를 직접 흩뿌리지 않고 공통 concurrency guard 형태로 격리한다.
- 락이 있으면 DB 검증을 생략하려는 유혹이 생긴다.
  - DB unique/check/status condition/row lock을 최종 방어선으로 유지한다.

## 관련 문서

- `docs/concurrency-control-guide.md`
- `docs/backlog/backend/007-backend-shop-core-distributed-lock.md`
- `docs/backlog/backend/010-backend-shop-core-product-image-count-limit-concurrency.md`
- `docs/entity/database_design.md`

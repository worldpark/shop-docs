# ADR-004 — 이벤트 계약을 상위 workspace 문서 SSOT로 관리

- 작성일: 2026-06-10
- 상태: Accepted
- 범위: shop-core, notification, docs

## 맥락

`shop-core`와 `notification`은 별도 프로젝트이며 Kafka 이벤트로만 통합된다. 이벤트 payload는 두 프로젝트 사이의 공개 인터페이스다.

이 계약을 어디에 둘지 결정해야 했다.

검토한 대안은 다음과 같다.

| 대안 | 장점 | 단점 |
|---|---|---|
| producer 코드가 계약 | 구현과 가까움 | consumer가 producer 코드에 결합됨 |
| 공유 Java 라이브러리 | 타입 재사용 가능 | 배포·버전 관리 부담, 양 프로젝트가 라이브러리에 결합 |
| schema registry | 운영 수준 계약 관리에 적합 | 현재 사이드 프로젝트 단계 대비 인프라·운영 비용 큼 |
| workspace 문서 SSOT | 두 프로젝트 밖에서 계약을 명시적으로 관리 | 코드 생성/호환성 검증은 별도 보완 필요 |

## 결정

이벤트 계약은 상위 workspace의 `docs/event-catalog.md`를 필드 레벨 SSOT로 관리한다.

- 이벤트 topic 목록은 `docs/architecture.md`에 요약한다.
- 이벤트 payload 상세 필드, 필수 여부, 예시 JSON은 `docs/event-catalog.md`에 둔다.
- 각 프로젝트는 공유 라이브러리 없이 자기 DTO를 둔다.
- 계약 변경 시 코드보다 `docs/event-catalog.md`를 먼저 수정한다.
- 변경은 필드 추가 같은 가산적 변경을 우선한다.
- 삭제와 타입 변경은 호환성 검토 후에만 수행한다.

## 결과

긍정적 결과:

- 프로젝트 간 공유물이 코드가 아니라 공개 계약으로 제한된다.
- notification은 shop-core 내부 클래스나 DB 스키마를 알 필요가 없다.
- 포트폴리오 문서에서 시스템 인터페이스를 쉽게 확인할 수 있다.
- 현재 규모에서 schema registry나 공유 라이브러리의 운영 부담을 피한다.

부정적 결과와 대응:

- DTO 중복이 발생한다.
  - 중복은 의도된 경계 비용으로 받아들이고, 이벤트 계약 변경 시 양쪽 DTO를 함께 갱신한다.
- 문서와 코드가 어긋날 수 있다.
  - 이벤트 발행/소비 테스트에서 payload 필수 필드와 topic을 검증한다.
- 대규모 팀/다수 consumer 환경에서는 문서 SSOT만으로 부족할 수 있다.
  - 필요 시 schema registry 또는 contract test를 후속 ADR로 검토한다.

## 관련 문서

- `docs/architecture.md`
- `docs/event-catalog.md`
- `docs/rules/event-contract-rule.md`

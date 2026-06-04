# Event Contract Rule

## 이벤트 계약 규칙
- 이벤트 토픽 목록은 `docs/architecture.md` 섹션 5, 필드 레벨 페이로드 스키마 SSOT는 `docs/event-catalog.md`다.
- 이벤트 계약 변경 시 코드보다 공개 계약 SSOT(`docs/event-catalog.md`)를 먼저 수정한다.
- 페이로드는 자족적으로 구성한다. 컨슈머가 shop-core를 재조회하지 않도록 한다.
- 모든 이벤트는 `eventId`와 발생 시각을 포함한다. 멱등성과 추적을 위한 필수 값이다.
- 변경은 가산적(필드 추가)을 우선한다.
- 필드 삭제와 타입 변경은 호환성 검토 후에만 수행한다.
- 컨슈머는 재시도와 DLQ에 대비해 멱등하게 이벤트를 처리한다.
- shop-core는 Transactional Outbox(Spring Modulith Event Publication Registry)로 이벤트를 발행한다.

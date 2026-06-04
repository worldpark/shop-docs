# Forbidden Rule

## 금지 규칙
- notification이 shop-core를 동기 호출하지 않는다. REST 호출과 직접 DB 조회 모두 금지한다.
- 두 프로젝트가 같은 DB를 공유하지 않는다.
- 알림 실패가 주문과 결제 흐름에 영향을 주지 않는다.
- Controller에서 비즈니스 로직을 작성하지 않는다.
- Consumer와 Scheduler에서 Repository를 직접 호출하지 않는다.
- Entity를 API 응답으로 직접 반환하지 않는다.
- 정당한 사유 없이 세 번째 독립 배포 서비스/프로젝트를 추가하지 않는다.

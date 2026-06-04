# Workspace Rule

## 작업 위치
- 항상 상위 워크스페이스 루트(`shop/`)에서 하네스를 실행한다.
- 하위 프로젝트 작업 시 해당 폴더(`shop-core/`, `notification/`)로 진입한다.
- 하위 레포를 단독 클론하거나 그 안에서 하네스를 실행하면 `docs/`와 상위 작업 규칙을 볼 수 없다.

## 설계 문서 위치
- 전체 아키텍처: `docs/architecture.md`
- 이벤트 토픽 목록: `docs/architecture.md` 섹션 5
- 이벤트 페이로드 스키마(SSOT): `docs/event-catalog.md`

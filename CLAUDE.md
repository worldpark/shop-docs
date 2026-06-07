# 프로젝트 컨텍스트

## 프로젝트 구성
- **shop-core**: 쇼핑몰 핵심 도메인. 회원·상품·장바구니·주문·결제·재고. Kafka 이벤트 프로듀서
- **notification**: 알림 발송. shop-core 이벤트를 구독해 이메일·SMS·푸시 전송. Kafka 컨슈머
- 두 프로젝트는 Kafka 이벤트로만 단방향·비동기 연결된다. 동기 호출·DB 공유 없음

## 기술 스택
- Backend: Java 21, Spring Boot 3.5.15-SNAPSHOT, Lombok
- View (shop-core): Thymeleaf (서버 사이드 렌더링)
- DB: PostgreSQL (프로젝트별 독립 인스턴스)
- 정적 자산: 로컬 파일 시스템 (이후 Cloudflare R2 + CDN으로 이관 예정)
- 모듈 구조 (shop-core): Spring Modulith
- 메시징: Kafka (JSON 직렬화)
- 빌드: Gradle (레포별 독립 빌드)
- 테스트: JUnit 5 + Mockito (단위), Testcontainers (DB 통합), Playwright for Java (브라우저 E2E — `docs/plans/performance/001-e2e-playwright-java-test-strategy.md`)

## 작업 규칙
세부 작업 규칙은 `docs/rules/*rule.md`를 따른다.
새 작업을 시작하기 전 `docs/architecture.md`와 작업에 관련된 `docs/rules/*rule.md`를 읽는다.
API를 추가하거나 변경할 때는 반드시 `docs/rules/api-authorization-rule.md`를 읽고 최소 허용 권한과 소유권 검사 필요 여부를 작업 문서 또는 코드에 반영한다.

## 향후 가상스레드 도입 대비
현재 단계에서는 가상스레드를 즉시 활성화하지 않으며, 새 기능은 직접 `ThreadLocal` 사용을 피하고 블로킹 I/O를 Service/Infrastructure 경계에 둔다.

- 작업 위치와 문서 맵: `docs/rules/workspace-rule.md`
- 아키텍처/레이어 규칙: `docs/rules/architecture-rule.md`
- 정적 자산/이미지 저장 규칙: `docs/rules/static-asset-rule.md`
- 이벤트 계약 규칙: `docs/rules/event-contract-rule.md`
- API 권한 규칙: `docs/rules/api-authorization-rule.md`
- REST 에러 응답 규칙: `docs/rules/error-response-rule.md`
- Docker 규칙: `docs/rules/docker-rule.md`
- Task 수행 규칙: `docs/rules/task-rule.md`
- 테스트 규칙: `docs/rules/testing-rule.md`
- 서브에이전트 작업 규칙: `docs/rules/subagent-rule.md`
- 금지 규칙: `docs/rules/forbidden-rule.md`
- 패키지 구조 규칙: `docs/rules/package-structure-rule.md`

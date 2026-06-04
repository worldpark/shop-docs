# Architecture Rule

이 문서는 시스템 구조 설명이 아니라 구현 시 지켜야 할 레이어 규칙을 정의한다.
시스템 책임 경계와 통신 구조는 `docs/architecture.md`를 따른다.

## shop-core (모듈러 모놀리스)
- REST 진입점은 `RestController -> ServiceResponse -> Service -> Repository` 레이어를 따른다.
- View 진입점은 `ViewController(@Controller) -> Service -> Repository` 레이어를 따르며 Thymeleaf 템플릿으로 렌더링한다.
- 이벤트 진입점은 `EventListener -> Service -> Repository` 레이어를 따른다.
- 스케줄러 진입점은 `Scheduler -> Service -> Repository` 레이어를 따른다.
- `ServiceResponse`는 REST 응답 조합 전용이며 View/Scheduler/EventListener에서는 사용하지 않는다.
- ViewController는 view name 또는 `ModelAndView`를 반환하고 모델에는 DTO/ViewModel만 담는다. Entity를 직접 전달하지 않는다.
- 도메인 경계는 Spring Modulith 모듈로 분리하며 모듈 간 직접 의존은 금지한다. 모듈 목록은 `docs/rules/package-structure-rule.md`를 따른다.
- REST API는 `/api/v1/**` 패턴, View 경로는 사용자 친화적 경로(`/orders`, `/products/{id}`)를 사용한다.

## shop-core 모듈 간 통신
- 다른 모듈의 비공개 구현 패키지(service/repository/domain 등)를 직접 참조하지 않는다.
- 모듈 간 통신은 우선 **Spring Modulith 애플리케이션 이벤트**(`ApplicationEventPublisher` + `@ApplicationModuleListener`)로 한다. 이는 shop-core **내부** 이벤트이며, notification으로 나가는 **Kafka 이벤트**(`docs/architecture.md` 섹션 5)와 구분한다.
- 동기 조회가 꼭 필요하면 각 모듈이 노출한 **published API(named interface/port)**를 통해서만 호출한다. 비공개 구현에는 접근하지 않는다.
- 모듈 경계를 넘는 데이터는 DTO로 주고받고 Entity를 모듈 밖으로 노출하지 않는다.

## notification
- 이벤트 진입점은 `Consumer -> Service -> Repository` 레이어를 따른다.
- REST API가 없으면 Controller와 ServiceResponse를 두지 않는다.

## 공통
- DTO와 Entity는 반드시 분리한다.
- 모든 예외는 `RuntimeException` 상속 커스텀 예외로 변환한다.
- 에러 응답은 REST API에서만 공통 포맷을 사용한다. 포맷과 예외 변환 규칙은 `docs/rules/error-response-rule.md`를 따른다.
- 프로젝트 간 통신, 데이터 소유권, 금지 규칙은 각각 `docs/architecture.md`와 `docs/rules/forbidden-rule.md`를 따른다.

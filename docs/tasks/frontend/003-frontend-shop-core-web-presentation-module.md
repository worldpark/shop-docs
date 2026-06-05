# 003. shop-core Web 프레젠테이션 모듈 분리

## Target
shop-core

---

## Goal
`shop-core`의 Thymeleaf ViewController를 독립적인 `web` 지원 모듈로 분리하되, `web`이 도메인 내부 구현에 직접 의존하지 않는 얇은 프레젠테이션 어댑터가 되도록 구조와 규칙을 정리한다.

---

## Context
- `shop-core`는 Spring Modulith 기반 모듈러 모놀리스이며 Thymeleaf SSR 화면을 함께 제공한다
- 현재 ViewController는 각 도메인 모듈의 `controller` 패키지에 REST Controller와 함께 위치한다
- 향후 `member`, `product` 등 도메인 모듈이 별도 서비스 또는 별도 프로젝트로 분리될 가능성을 고려한다
- 도메인 분리 이후에도 쇼핑몰 화면 서버는 하나의 프레젠테이션 레이어로 유지할 수 있어야 한다
- 단순히 Controller를 한곳에 모으는 것이 아니라, ViewController를 도메인 공개 API를 호출하는 어댑터로 분리하는 것이 목적이다
- ViewController는 view name 또는 `ModelAndView`를 반환하고 모델에는 DTO/ViewModel만 담는다
- `ServiceResponse`는 REST 응답 조합 전용이며 View 렌더링에는 사용하지 않는다

## Requirements
- `web` 지원 모듈 패키지를 추가한다
- `web` 모듈을 Spring Modulith가 인식하는 지원/횡단 모듈로 문서화한다
- 기존 ViewController를 `web` 모듈로 이동한다
- ViewController는 도메인 내부 구현 패키지에 직접 의존하지 않는다
- `web` 모듈은 각 도메인 모듈이 노출한 published API 또는 View 전용 facade/port만 의존한다
- 도메인 모듈은 `web` 모듈을 의존하지 않는다
- ViewController에서 `Repository`, `Entity`, 도메인 내부 service 구현체를 직접 참조하지 않는다
- View 모델은 `web` 모듈 안에 두거나, 도메인 published API가 반환하는 DTO를 화면 용도에 맞게 변환해 사용한다
- 기존 Thymeleaf 템플릿 경로와 사용자-facing URL은 유지한다
- 로그인, 회원가입, 관리자 회원 관리, 판매자 상품 관리 등 기존 SSR 화면이 동일하게 동작해야 한다
- `home` 모듈의 책임을 검토하고, 홈 화면도 `web` 모듈로 통합할지 또는 `home`을 유지할지 작업 문서 또는 코드 주석에 명시한다
- Spring Modulith 구조 검증 테스트를 보강해 `web` 모듈의 의존 방향을 검증한다
- View 렌더링 테스트를 보강한다

## Constraints
- 이번 Task는 화면 모듈 경계 정리 작업이며 신규 비즈니스 기능을 추가하지 않는다
- URL, View name, 템플릿 파일명은 정당한 사유 없이 변경하지 않는다
- `web` 모듈에서 다른 모듈의 `repository`, `domain`, 비공개 `service` 패키지를 직접 참조하지 않는다
- Entity를 View 모델에 직접 전달하지 않는다
- `ServiceResponse`를 View 렌더링에 사용하지 않는다
- REST Controller는 이번 Task에서 `web` 모듈로 이동하지 않는다
- REST API 경로와 응답 포맷은 변경하지 않는다
- 도메인 모듈 간 직접 의존을 새로 만들지 않는다
- `notification` 코드나 DB를 참조하지 않는다
- Kafka 이벤트 계약은 변경하지 않는다
- 화면 분리 때문에 보안 최소 권한과 소유권 검사가 약해지면 안 된다

## Files
- `docs/rules/package-structure-rule.md`
- `docs/rules/architecture-rule.md`
- `shop-core/src/main/java/com/shop/shop/web/**`
- `shop-core/src/main/java/com/shop/shop/home/**`
- `shop-core/src/main/java/com/shop/shop/member/controller/**`
- `shop-core/src/main/java/com/shop/shop/product/controller/**`
- `shop-core/src/main/java/com/shop/shop/*/spi/**`
- `shop-core/src/main/java/com/shop/shop/*/adapter/**`
- `shop-core/src/main/resources/templates/**`
- `shop-core/src/test/java/com/shop/shop/**`

## Web Module Contract

| 항목 | 규칙 |
|---|---|
| 모듈 성격 | Spring Modulith 지원 모듈 |
| 책임 | Thymeleaf ViewController, ViewModel, Form, 화면 조립 |
| 허용 의존 | 도메인 published API, View 전용 facade/port, DTO |
| 금지 의존 | 도메인 Entity, Repository, 비공개 Service 구현, 다른 프로젝트 코드 |
| 반환 | view name 또는 `ModelAndView` |
| 모델 | DTO/ViewModel/Form만 허용 |
| REST 처리 | 제외. REST Controller는 각 도메인 모듈에 유지 |

## Migration Scope

| 기존 위치 | 이동 후 후보 |
|---|---|
| `home/controller/HomeViewController` | `web/controller/HomeViewController` |
| `member/controller/LoginViewController` | `web/member/LoginViewController` 또는 `web/controller/member/LoginViewController` |
| `member/controller/MemberSignupViewController` | `web/member/MemberSignupViewController` 또는 `web/controller/member/MemberSignupViewController` |
| `member/controller/AdminMemberViewController` | `web/member/AdminMemberViewController` 또는 `web/controller/member/AdminMemberViewController` |
| `product/controller/SellerProductViewController` | `web/product/SellerProductViewController` 또는 `web/controller/product/SellerProductViewController` |

> 세부 패키지 형태는 구현 시 하나로 결정한다. 단, `web` 안에서도 member/product 등 화면 영역별 하위 패키지를 두어 화면 책임을 찾기 쉽게 유지한다.

## Acceptance Criteria
- `web` 지원 모듈이 추가되고 문서화된다
- 기존 SSR 화면 URL과 View name이 유지된다
- 기존 ViewController가 `web` 모듈로 이동된다
- `web` 모듈은 도메인 Entity와 Repository를 직접 참조하지 않는다
- `web` 모듈은 도메인 비공개 service 구현체를 직접 참조하지 않는다
- 필요한 도메인 조회/명령은 published API 또는 View 전용 facade/port를 통해 수행된다
- 도메인 모듈은 `web` 모듈에 의존하지 않는다
- REST Controller는 각 도메인 모듈에 유지된다
- View 모델에 Entity가 직접 노출되지 않는다
- 로그인, 회원가입, 관리자 회원 관리, 판매자 상품 관리 화면이 기존과 동일한 URL로 렌더링된다
- Spring Modulith 구조 검증 테스트가 통과한다
- 관련 View 렌더링 테스트가 통과한다

## Test
- `./gradlew test`
- 권장 구조 테스트
  - `web` 모듈이 도메인 `domain` 패키지를 참조하지 않음
  - `web` 모듈이 도메인 `repository` 패키지를 참조하지 않음
  - `web` 모듈이 도메인 비공개 `service` 구현을 참조하지 않음
  - 도메인 모듈이 `web` 모듈을 참조하지 않음
- 권장 View 테스트
  - 홈 화면 렌더링
  - 로그인 화면 렌더링
  - 회원가입 화면 렌더링
  - 관리자 회원 관리 화면 권한별 접근 검증
  - 판매자 상품 관리 화면 권한별 접근 검증

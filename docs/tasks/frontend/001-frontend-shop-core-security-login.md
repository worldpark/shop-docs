# 001. shop-core Spring Security + 로그인 화면

## Target
shop-core

---

## Goal
`shop-core`의 Thymeleaf SSR 화면에 필요한 기본 인증/인가 경계와 폼 로그인 흐름을 구현한다.

---

## Context
- `shop-core`는 Thymeleaf 기반 SSR 화면을 호스팅한다
- View 경로는 사용자 친화적 경로를 사용한다
- REST API는 `/api/v1/**` 패턴을 사용한다
- CSRF는 Thymeleaf 폼 제출 흐름에서 활성화한다

## Requirements
- Spring Security 기본 설정 구현
- 공개 경로와 인증 필요 경로 정책 정의
- Thymeleaf 기반 로그인 화면 구현
- 로그인/로그아웃 흐름 구현
- CSRF 활성화
- 인증 성공/실패 흐름 테스트 작성

## Constraints
- Controller에서 비즈니스 로직을 작성하지 않는다
- ViewController는 view name 또는 `ModelAndView`를 반환한다
- 모델에는 DTO/ViewModel만 담고 Entity를 직접 전달하지 않는다
- REST 예외 응답과 View 예외 처리를 섞지 않는다
- 보안 설정은 `shop-core`에만 적용한다

## Files
- `shop-core/src/main/java/com/shop/shop/**/config/**`
- `shop-core/src/main/java/com/shop/shop/**/controller/**`
- `shop-core/src/main/resources/templates/**`
- `shop-core/src/test/java/com/shop/shop/**`

## Acceptance Criteria
- 비인증 사용자는 보호 경로 접근 시 로그인 페이지로 이동한다
- 로그인 폼이 CSRF 토큰과 함께 정상 렌더링된다
- 로그인 성공/실패 흐름이 확인된다
- 로그아웃 흐름이 확인된다
- 관련 MVC 또는 통합 테스트가 통과한다

## Test
- `./gradlew test`

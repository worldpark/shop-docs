# 002. shop-core Thymeleaf 레이아웃/프래그먼트

## Target
shop-core

---

## Goal
이후 화면 작업이 반복 없이 진행될 수 있도록 `shop-core`의 Thymeleaf 공통 레이아웃, 프래그먼트, 정적 리소스 기본 구조를 구현한다.

---

## Context
- `shop-core`는 Thymeleaf 기반 SSR 화면을 제공한다
- ViewController는 view name 또는 `ModelAndView`를 반환한다
- 모델에는 DTO/ViewModel만 담는다
- 로그인 화면은 이 레이아웃 기반 위에서 일관된 UI를 가져야 한다

## Requirements
- 공통 레이아웃 템플릿 구현
- 헤더 프래그먼트 구현
- 푸터 프래그먼트 구현
- 네비게이션 프래그먼트 구현
- 에러 메시지/플래시 메시지 영역 구현
- 정적 리소스 기본 구조 준비
- 최소 1개 샘플 페이지 구현
- 템플릿 렌더링 테스트 작성

## Constraints
- 템플릿에 base URL을 하드코딩하지 않는다
- Entity를 템플릿 모델에 직접 전달하지 않는다
- `ServiceResponse`를 View 렌더링에 사용하지 않는다
- 화면 구조는 이후 member/product/cart/order 화면이 확장 가능한 형태여야 한다

## Files
- `shop-core/src/main/resources/templates/layout/**`
- `shop-core/src/main/resources/templates/fragments/**`
- `shop-core/src/main/resources/templates/**`
- `shop-core/src/main/resources/static/**`
- `shop-core/src/test/java/com/shop/shop/**`

## Acceptance Criteria
- 로그인 페이지가 공통 레이아웃 또는 공통 프래그먼트를 사용한다
- 샘플 페이지가 공통 레이아웃을 사용한다
- 헤더/푸터/네비게이션 프래그먼트가 정상 렌더링된다
- 템플릿 include/fragment 구조가 일관된다
- 관련 테스트가 통과한다

## Test
- `./gradlew test`

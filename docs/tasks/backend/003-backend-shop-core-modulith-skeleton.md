# 003. shop-core Spring Modulith 모듈 골격

## Target
shop-core

---

## Goal
`shop-core`의 핵심 도메인을 Spring Modulith 모듈 경계로 분리하고, 이후 기능 개발이 모듈 단위로 진행될 수 있도록 패키지 골격과 구조 검증 테스트를 추가한다.

---

## Context
- `shop-core`는 회원, 상품, 장바구니, 주문, 결제, 재고를 포함하는 모듈러 모놀리스다
- 도메인 경계는 Spring Modulith 모듈로 분리한다
- 모듈 간 직접 의존은 금지한다
- 이벤트 발행은 이후 Transactional Outbox(Spring Modulith Event Publication Registry)로 확장한다

## Requirements
- `member` 모듈 패키지 골격 생성
- `product` 모듈 패키지 골격 생성
- `cart` 모듈 패키지 골격 생성
- `order` 모듈 패키지 골격 생성
- `payment` 모듈 패키지 골격 생성
- `inventory` 모듈 패키지 골격 생성
- 각 모듈에 `controller`, `service`, `repository`, `domain`, `dto`, `event`, `messaging` 패키지 준비
- Spring Modulith 구조 검증 테스트 추가

## Constraints
- 모듈 간 직접 의존을 만들지 않는다
- Entity를 API 응답으로 직접 반환하지 않는 구조를 전제로 둔다
- 실제 도메인 기능 구현은 이 Task 범위에 포함하지 않는다
- 빈 패키지는 Git에 남지 않으므로 필요한 경우 최소 marker 또는 package-info 전략을 사용한다
- 이벤트 계약 변경은 하지 않는다

## Files
- `shop-core/src/main/java/com/shop/shop/member/**`
- `shop-core/src/main/java/com/shop/shop/product/**`
- `shop-core/src/main/java/com/shop/shop/cart/**`
- `shop-core/src/main/java/com/shop/shop/order/**`
- `shop-core/src/main/java/com/shop/shop/payment/**`
- `shop-core/src/main/java/com/shop/shop/inventory/**`
- `shop-core/src/test/java/com/shop/shop/**`

## Acceptance Criteria
- 모듈 패키지 골격이 아키텍처 규칙과 일치한다
- Spring Modulith 구조 검증 테스트가 통과한다
- 이후 기능 Task가 모듈 단위로 바로 시작 가능하다
- 모듈 간 직접 의존 금지 규칙을 테스트로 검증한다

## Test
- `./gradlew test`

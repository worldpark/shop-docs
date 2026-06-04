# API Authorization Rule

API 개발 시 각 엔드포인트가 어떤 권한까지 접근 가능한지 결정하기 위한 기준 문서다.
레이어 규칙은 `docs/rules/architecture-rule.md`, 시스템 경계는 `docs/architecture.md`를 따른다.

## 권한 계층

권한은 아래 순서의 계층형 권한으로 설계한다.

```text
ADMIN > SELLER > CONSUMER
```

Spring Security 권한명은 `ROLE_` prefix를 사용한다.

| 권한 | 의미 | 포함하는 하위 권한 |
|---|---|---|
| `ROLE_ADMIN` | 시스템 전체 관리자 | SELLER, CONSUMER |
| `ROLE_SELLER` | 판매자 | CONSUMER |
| `ROLE_CONSUMER` | 일반 구매자 | 없음 |

## 기본 원칙

- 모든 API는 명시적으로 공개 API인지 인증 필요 API인지 구분한다.
- 인증 필요 API는 최소 허용 권한을 task, controller, security 설정 중 추적 가능한 위치에 명시한다.
- 상위 권한은 하위 권한 API에 접근할 수 있다.
- 하위 권한은 상위 권한 API에 접근할 수 없다.
- 권한 판단은 Controller 비즈니스 로직으로 처리하지 않고 Spring Security 설정 또는 method security로 처리한다.
- 사용자 본인 소유 리소스 접근은 권한과 소유권 검사를 함께 고려한다.
- Entity를 권한 판단 결과나 API 응답으로 직접 노출하지 않는다.

## API 권한 결정 템플릿

새 API task를 작성할 때 아래 항목을 포함한다.

| 항목 | 값 |
|---|---|
| API | 예: `POST /api/v1/products` |
| 공개 여부 | public / authenticated |
| 최소 권한 | 예: `ROLE_SELLER` |
| 상위 권한 허용 | 예: `ROLE_ADMIN` |
| 소유권 검사 | 필요 / 불필요 |
| 비고 | 예: 판매자는 자기 상품만 수정 가능 |

## 도메인별 기본 기준

| 도메인 | API 유형 | 최소 권한 | 비고 |
|---|---|---|---|
| member | 회원가입, 로그인, 토큰 재발급 | public | 토큰 재발급은 refresh token 검증 필요 |
| member | 내 정보 조회/수정 | CONSUMER | 본인 소유권 검사 필요 |
| member | 사용자 관리 | ADMIN | |
| product | 상품 목록/상세 조회 | public | 공개 상품만 노출 |
| product | 상품 등록/수정/삭제 | SELLER | 판매자는 자기 상품만 관리 |
| product | 상품 승인/상태 강제 변경 | ADMIN | |
| cart | 장바구니 조회/수정 | CONSUMER | 본인 소유권 검사 필요 |
| order | 주문 생성/조회 | CONSUMER | 본인 주문만 조회 |
| order | 주문 상태 관리 | SELLER | 판매자/관리자 범위는 task에서 명시 |
| inventory | 재고 조회/변경 | SELLER | 판매자는 자기 상품 variant만 변경 |
| payment | 결제 요청/조회 | CONSUMER | 본인 주문 기준 |
| payment | 결제 실패/환불 관리 | ADMIN | |

## 공개 API 기준

다음은 public으로 둘 수 있다.

- 로그인
- 토큰 재발급
- 회원가입
- 공개 상품 목록/상세 조회
- 정적 자산 조회

public API라도 입력 검증, rate limit, 민감 정보 비노출 규칙은 적용한다.

## 소유권 검사 기준

권한만으로 충분하지 않은 API는 소유권 검사를 추가한다.

- CONSUMER: 본인 계정, 본인 장바구니, 본인 주문, 본인 리뷰
- SELLER: 자기 상품, 자기 상품의 재고, 자기 상품 관련 주문 처리
- ADMIN: 전체 리소스

소유권 검사는 Service 계층에서 도메인 규칙으로 검증한다.
Controller에서 직접 Repository를 조회해 소유권을 판단하지 않는다.

## 테스트 기준

권한이 있는 API는 다음 테스트를 작성한다.

- 최소 권한 사용자는 접근 가능
- 상위 권한 사용자는 접근 가능
- 하위 권한 사용자는 403
- 인증 없는 요청은 401
- 소유권이 필요한 경우 다른 사용자의 리소스 접근은 403 또는 404

## 금지

- 권한 없는 요청을 Controller 비즈니스 로직에서 문자열 비교로 처리하지 않는다.
- 하위 권한이 상위 권한 API에 접근하도록 열어두지 않는다.
- API task에서 권한 정책을 생략하지 않는다.
- `notification`이 `shop-core` 권한 정보를 동기 조회하지 않는다.

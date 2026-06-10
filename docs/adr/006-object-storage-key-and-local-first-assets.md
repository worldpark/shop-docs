# ADR-006 — 정적 자산은 storage key만 저장하고 ObjectStorage 뒤에 둔다

- 작성일: 2026-06-10
- 상태: Accepted
- 범위: shop-core 정적 자산, 상품 이미지

## 맥락

상품 이미지는 현재 로컬 파일 시스템에 저장한다. 하지만 향후 Cloudflare R2와 CDN으로 이관할 계획이 있으므로 도메인 모델과 DB가 현재 저장소 구현이나 public URL에 결합되면 안 된다.

검토한 대안은 다음과 같다.

| 대안 | 장점 | 단점 |
|---|---|---|
| DB에 절대 URL 저장 | 조회와 렌더링이 단순 | CDN/base URL 변경 시 데이터 마이그레이션 필요 |
| DB에 로컬 파일 경로 저장 | 로컬 구현이 단순 | R2/CDN 이관 시 도메인 데이터가 저장소 구현에 결합 |
| DB에는 storage key만 저장 | 저장소 교체와 URL 정책 변경이 쉬움 | URL 합성 지점이 별도로 필요 |

## 결정

정적 자산은 DB에 host를 포함하지 않은 storage key만 저장한다.

- 예: `products/{uuid}.jpg`
- DB에 절대 URL을 저장하지 않는다.
- 도메인 코드는 `ObjectStorage` 인터페이스에만 의존한다.
- 현재 구현은 `LocalObjectStorage`를 사용한다.
- 향후 `R2ObjectStorage`로 교체 가능해야 한다.
- URL 합성은 설정값과 view helper 같은 한 곳에서만 수행한다.
- 파일은 항상 새 key로 저장하고 동일 key를 덮어쓰지 않는다.

## 결과

긍정적 결과:

- 로컬 파일 시스템에서 R2/CDN으로 이관할 때 DB 데이터 변경을 최소화한다.
- CDN base URL, bucket, public domain 변경이 도메인 데이터에 영향을 주지 않는다.
- 동일 key overwrite를 피하므로 CDN cache invalidation 비용과 일관성 문제를 줄인다.
- controller, service, template에 base URL 하드코딩이 퍼지지 않는다.

부정적 결과와 대응:

- 화면 렌더링 시 storage key를 public URL로 변환하는 단계가 필요하다.
  - URL 합성 책임을 view helper 또는 설정 기반 컴포넌트 한 곳에 둔다.
- 로컬 저장소와 R2 저장소의 동작 차이를 추상화해야 한다.
  - `ObjectStorage` port를 기준으로 adapter를 교체한다.
- 비공개 객체나 presigned URL 요구는 현재 범위 밖이다.
  - 도입 시 private object 흐름을 별도 ADR과 task로 정의한다.

## 관련 문서

- `docs/architecture.md`
- `docs/rules/static-asset-rule.md`
- `docs/tasks/backend/012-backend-shop-core-product-image-management-with-view.md`

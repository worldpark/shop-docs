# (backlog) 상품 이미지 개수 상한의 동시성 엄격 보장

> 상태: backlog (미착수)
> 영역: shop-core (backend / product 이미지 도메인 + 공통 storage)
> 출처: Task 012 — 상품당 이미지 개수 상한(기본 10장)을 애플리케이션 레벨 best-effort로만 구현. 동시 업로드 race는 후속으로 보류(리뷰 비차단 지적).

## 배경 / 동기
- Task 012에서 `ProductImageService.upload()`가 `objectStorage.put` 이전에 `countByProductId(productId) >= maxImagesPerProduct`를 검사해 개수 상한을 적용한다(기본 10장, 설정 `shop.storage.max-images-per-product`).
- 이 검사는 **읽고-나서-쓰는(check-then-act)** 구조라, 같은 상품에 두 요청이 동시에 `count = 9`를 읽으면 둘 다 통과해 상한을 잠깐 초과(10장 → 11장 이상)할 수 있다.
- DB 유니크/체크 제약이 아니라 앱 레벨 검사이므로 동시성 보장이 없다. Task 012 범위(best-effort 상한)에는 부합하지만, 엄격한 상한이 필요해지면 별도 처리가 필요하다.

## 범위 (할 것)
- 엄격 보장 방식 결정 (트레이드오프 비교):
  - (a) 비관적 락: 업로드 트랜잭션에서 상품 행(또는 이미지 집합)에 `SELECT ... FOR UPDATE`로 직렬화 후 count 검사.
  - (b) DB 제약: `sort_order`를 0..N-1로 강제하는 등 개수 상한을 표현할 수 있는 제약/조건부 INSERT (예: `INSERT ... WHERE (SELECT count(*) ...) < :max`).
  - (c) 애플리케이션 락(분산락, [[007-backend-shop-core-distributed-lock]])으로 `{productId}` 단위 임계구역 직렬화.
- 선택안 적용 + 동시 업로드 시 상한 초과가 발생하지 않음을 검증하는 동시성 테스트.

## 범위 밖 / 주의
- 단일 요청 경로의 개수 상한 자체는 Task 012에서 이미 동작한다(여기서는 동시성 보장만 강화).
- 과설계 회피: 실제로 동시 업로드 초과가 문제되는 트래픽/요구가 확인된 뒤 착수. 그 전까지 best-effort 유지.
- storage 보상 트랜잭션(put→DB, DB 실패 시 delete) 의미론을 깨지 않을 것(Task 012 §1.5 / plan 4절).

## 선행 의존
- Task 012(상품 이미지 관리) 완료. (c)안 선택 시 [[007-backend-shop-core-distributed-lock]] 선행.

## 참고
- `docs/plans/backend/012-backend-shop-core-product-image-management-with-view-plan.md` §1.7(개수 상한), §4(예외표), §7(트레이드오프)
- `docs/tasks/backend/012-backend-shop-core-product-image-management-with-view.md` (Requirements/AC 개수 상한 항목)
- `shop-core/.../product/service/ProductImageService.java` `upload()` / `validateImageCount()`

# 038. 판매자 상품 옵션 삭제 + Variant 삭제 + Variant 수정 UI 완성

> 출처: 사용자 요청 — 판매자 상품 관리(variants 페이지)에 **① 옵션 삭제, ② Variant 삭제, ③ Variant 수정 기능**이 필요. 현황 실사로 갭 확정(아래).

## 현황 / 갭 (실사 확정)
| 기능 | 상태 |
|---|---|
| 옵션 삭제 | **service~template 전부 없음** |
| Variant 삭제 | **service~template 전부 없음** |
| Variant 수정 | 백엔드(service `updateVariant`·facade·REST PATCH·view POST `/variants/{id}`) **이미 완성**, **템플릿 UI만 스텁**(수정 버튼이 data-* 속성·`id=variant-edit-form`만 깔려 있고 JS 없어 동작 안 함) |

## 삭제 안전성 (실사 — 제약 없음)
- **옵션 삭제**: `option_values`·`variant_values`가 `ON DELETE CASCADE`라 DB가 자동 정리. variant 참조 차단 불필요.
- **Variant 삭제**: `order_items.variant_id`가 `ON DELETE SET NULL`(주문 스냅샷 보존)이라 주문에 쓰인 variant도 삭제 가능. `VariantStock`은 `product_variants`와 동일 물리 테이블이라 함께 삭제됨.

## Target / Goal
판매자가 variants 관리 페이지에서 옵션·Variant를 **삭제**하고 Variant를 **수정**할 수 있게 한다. 백엔드 삭제 2종을 기존 create/update 패턴으로 추가하고(소유권·검증·BusinessException 계승), 템플릿에 삭제 버튼·Variant 수정 UI를 완성한다.

## 범위 (Scope)
### 백엔드 (backend-implementor) — 삭제 2종
- **옵션 삭제**: `ProductOptionService.deleteOption` → `ProductOptionServiceResponse` → `SellerProductOptionRestController` `@DeleteMapping("/{optionId}")` → `SellerProductVariantFacade.deleteOption`+Impl → `SellerProductVariantViewController` `@PostMapping("/seller/products/{productId}/options/{optionId}/delete")`.
- **Variant 삭제**: `ProductVariantService.deleteVariant` → `ProductVariantServiceResponse` → `SellerProductVariantRestController` `@DeleteMapping("/{variantId}")` → `Facade.deleteVariant`+Impl → ViewController `@PostMapping("/seller/products/{productId}/variants/{variantId}/delete")`.
- **소유권·검증**: `productService.getOwnedProduct(actorId, actorIsAdmin, productId)` + 대상 존재·소유 검증(`findById().filter(productId 일치)`, `OptionNotFoundException`/`VariantNotFoundException`). 기존 create/update 패턴 그대로.
- **Variant 수정 백엔드는 신규 작업 없음**(완성됨).

### 뷰 (view-implementor) — `templates/seller/product-variants.html`
- **옵션 삭제 버튼**: 각 옵션에 삭제 폼(POST `.../options/{optionId}/delete`, CSRF 자동, confirm).
- **Variant 삭제 버튼**: variants 테이블 각 행에 삭제 폼(POST `.../variants/{variantId}/delete`, confirm).
- **Variant 수정 UI 완성**: 현재 스텁(수정 버튼 data-*·생성폼 `#variant-edit-form`) 기반으로, "수정" 클릭 시 생성폼을 해당 variant 값(sku/price/stock/active/optionValueIds)으로 채우고 action을 update 엔드포인트로 전환·제목/버튼을 "수정"으로·취소 복귀. (JS 보강 또는 인라인 편집 — plan에서 확정.)

## Non-goals
- 옵션/옵션값 수정, 옵션값 삭제 — 본 Task 비범위(요청은 옵션 삭제·Variant 삭제·수정). 필요 시 후속.
- 도메인 cascade·orphanRemoval 추가 — DB cascade로 충분(JPA delete + DB ON DELETE CASCADE). 불필요한 연관 추가 금지.

## 검증
- 백엔드: REST DELETE 권한(SELLER 204 / CONSUMER 403 / 비인증 401 / 타판매자 404), 존재X 404. view 컨트롤러 매핑·redirect·flash. 타깃 테스트(`*SellerProductOption*`/`*SellerProductVariant*`).
- **뷰: 브라우저 E2E 필수** — 목록 페이지의 조건부 버튼/폼·JS 동작은 MockMvc·통합이 못 잡는다(메모리 "목록 페이지 조건부 버튼/폼은 실제 브라우저 E2E로 검증"). 옵션/Variant 삭제·수정 흐름을 e2e-runner로 확인.
- 메인 최종: 풀 스위트 그린.

## 참고
- 실사: 본 Task 작성 시 옵션/variant CRUD 전수 조사 결과.
- 패턴: `ProductOptionService.createOption`·`ProductVariantService.updateVariant`(소유권·검증), `SellerProductVariantViewController`(404 수정으로 클래스 매핑 제거 — 각 메서드 전체 경로), 기존 REST 컨트롤러 보안 테스트.
- 주의: view 컨트롤러는 최근 클래스 `@RequestMapping` 제거됨(옵션 404 수정). 신규 삭제 핸들러도 **전체 경로**로 매핑.

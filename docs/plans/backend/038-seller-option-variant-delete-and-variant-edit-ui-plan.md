# Plan 038. 판매자 옵션 삭제 + Variant 삭제 + Variant 수정 UI 완성

> 대상 Task: `docs/tasks/backend/038-...-option-variant-delete-and-variant-edit-ui.md`
> 구현: 삭제 백엔드=backend-implementor → 화면(삭제 버튼·수정 UI)=view-implementor → reviewer → e2e-runner.
> 선행 실사 완료(옵션/variant CRUD 전수). Variant 수정 백엔드는 이미 완성 — 화면만.

## 1. 백엔드 — 옵션 삭제·Variant 삭제 (backend-implementor)
기존 create/update와 **동일 레이어·동일 패턴**으로 추가. 로직 신설 없이 미러링.

### 1.1 옵션 삭제
- `ProductOptionService.deleteOption(long actorId, boolean actorIsAdmin, long productId, long optionId)`:
  - `productService.getOwnedProduct(actorId, actorIsAdmin, productId)`(소유권),
  - `productOptionRepository.findById(optionId).filter(o -> o.getProduct().getId().equals(productId)).orElseThrow(OptionNotFoundException::new)`(존재·소유),
  - `productOptionRepository.delete(option)`. (DB `ON DELETE CASCADE`가 option_values·variant_values 정리 — 추가 검증/삭제 불필요.)
- `ProductOptionServiceResponse.deleteOption(Authentication auth, long productId, long optionId)`: principal(userId) 추출 → service 위임.
- `SellerProductOptionRestController`: `@DeleteMapping("/{optionId}")` → `ResponseEntity<Void>` 204(`noContent`).
- `SellerProductVariantFacade.deleteOption(String actorEmail, boolean actorIsAdmin, long productId, long optionId)` + Impl(userDirectory로 email→userId 등 기존 facade 패턴, service 위임).
- `SellerProductVariantViewController`: `@PostMapping("/seller/products/{productId}/options/{optionId}/delete")` → try{ facade.deleteOption; flashSuccess "옵션이 삭제되었습니다." } catch(BusinessException){ flashError } → `redirect:/seller/products/{productId}/variants`.

### 1.2 Variant 삭제
- `ProductVariantService.deleteVariant(long actorId, boolean actorIsAdmin, long productId, long variantId)`:
  - 소유권 + `productVariantRepository.findById(variantId).filter(v -> v.getProduct().getId().equals(productId)).orElseThrow(VariantNotFoundException::new)`(V11과 동일 하위리소스 검증),
  - `productVariantRepository.delete(variant)`. (order_items `ON DELETE SET NULL`·variant_values cascade — 추가 처리 불필요.)
- `ProductVariantServiceResponse.deleteVariant(auth, productId, variantId)`.
- `SellerProductVariantRestController`: `@DeleteMapping("/{variantId}")` → 204.
- `SellerProductVariantFacade.deleteVariant(...)` + Impl.
- `SellerProductVariantViewController`: `@PostMapping("/seller/products/{productId}/variants/{variantId}/delete")` → flash + `redirect:/.../variants`.

### 1.3 주의
- view 컨트롤러는 **클래스 `@RequestMapping` 없음**(옵션 404 수정으로 제거). 신규 삭제 핸들러도 **전체 경로**로 매핑(`/seller/products/{productId}/options/{optionId}/delete`, `.../variants/{variantId}/delete`).
- 예외 클래스 재사용: `OptionNotFoundException`, `VariantNotFoundException`(존재). 신규 예외 만들지 말 것.
- ServiceResponse/Facade/Controller가 기존 create/update와 **동일 시그니처 스타일**(actorEmail/admin, auth principal 추출 방식)을 따르는지 기존 코드 대조.

### 1.4 백엔드 테스트 (타깃만, subagent-rule)
- REST: `SellerProductOptionRestControllerSecurityTest`/`SellerProductVariantRestControllerSecurityTest` 패턴으로 `DELETE` 추가 — SELLER 204 / CONSUMER 403 / 비인증 401 / 타판매자 404 / 존재X 404.
- view: `SellerProductVariantViewControllerTest`에 삭제 핸들러 매핑·redirect·flash·facade 호출 검증 추가.
- 실행: `./gradlew test --tests "*SellerProductOption*" --tests "*SellerProductVariant*"` (풀 스위트 금지).

## 2. 화면 — 삭제 버튼 + Variant 수정 UI (view-implementor)
`templates/seller/product-variants.html` 만 수정(+ 필요 시 static js/css).

### 2.1 옵션 삭제 버튼
- 옵션 목록 루프(각 `option`)의 헤더(`.option-header`)에 삭제 폼:
  `<form method="post" th:action="@{/seller/products/{productId}/options/{optionId}/delete(productId=${product.productId}, optionId=${option.optionId})}" onsubmit="return confirm('이 옵션을 삭제하면 옵션값·관련 조합도 삭제됩니다. 계속할까요?')">` + `<button class="btn btn-danger btn-sm">옵션 삭제</button>`. CSRF 자동(_csrf 수동 금지).

### 2.2 Variant 삭제 버튼
- variants 테이블에 "삭제" 처리 추가(수정 열에 함께 또는 별 열): 각 행에
  `<form method="post" th:action="@{/seller/products/{productId}/variants/{variantId}/delete(...)}" onsubmit="return confirm('이 variant를 삭제할까요?')">` + `<button class="btn btn-danger btn-sm">삭제</button>`.

### 2.3 Variant 수정 UI 완성 (스텁 → 동작)
현재: 행마다 "수정" 버튼(`data-variant-id/sku/price/stock/active`) + 생성폼 `id="variant-edit-form"`. **JS 부재로 미동작**.
- **접근(스텁 완성)**: "수정" 버튼에 **`data-option-value-ids`(콤마조인 `${#strings.listJoin(variant.optionValueIds, ',')}` 등)** 추가. 작은 JS(템플릿 하단 `<script>` 또는 `static/js`)로:
  1. "수정" 클릭 → 생성폼(`#variant-edit-form`)의 sku/price/stock/active를 data-*로 채움,
  2. optionValue 체크박스 전체 해제 후 `data-option-value-ids`의 id만 체크,
  3. 폼 `action`을 `/seller/products/{productId}/variants/{variantId}`(update)로 교체,
  4. 제목 "새 Variant 추가"→"Variant 수정", 버튼 "Variant 추가"→"Variant 수정", **"취소" 버튼**으로 생성 모드 복귀(action·라벨·필드 리셋),
  5. 폼으로 스크롤.
- 수정 버튼은 현재 `<a href=...>`(페이지 이동)이라 **type=button**으로 바꿔 네비게이션 막고 JS만 동작하게 한다(기존 hidden 재제출 폼 제거 또는 정리).
- 검증 실패(서버 재렌더) 시 기존 흐름 유지(이미 createVariant/updateVariant가 폼 에러 echo).

### 2.4 화면 검증 — 브라우저 E2E 필수
메모리 "목록 페이지 조건부 버튼/폼·JS는 MockMvc·통합이 못 잡으니 실제 브라우저 E2E로 검증". e2e-runner로:
- seller 로그인 → 상품 수정 → variants 페이지 → 옵션 삭제·variant 삭제·variant 수정 흐름 각각 동작 확인(삭제 후 목록 반영, 수정 폼 채워짐·저장 반영).

## 3. 순서 / 검증 게이트
1. backend-implementor(삭제 2종 + 타깃 테스트) → reviewer.
2. view-implementor(삭제 버튼·수정 UI) → reviewer.
3. 메인: 풀 스위트 그린(최종 동적 게이트).
4. e2e-runner: 앱 기동 상태에서 삭제·수정 브라우저 검증.

## 4. 리뷰 관점
- 삭제 service가 소유권·존재·소유 검증을 create/update와 동일하게 하는가(타판매자 404). 신규 예외 없이 기존 재사용.
- 삭제 view 핸들러가 **전체 경로**(클래스 매핑 없음)로 매핑되고 flash·redirect 정합인가.
- REST DELETE 권한 매트릭스(SELLER 204/CONSUMER 403/비인증 401/타판매자·존재X 404).
- 템플릿 삭제 폼 CSRF 자동·confirm, Variant 수정 JS가 optionValueIds까지 정확히 채우고 action 전환·취소 복귀하는가.
- DB cascade로 삭제 부수효과가 안전한가(옵션→옵션값·variant_values, variant→order_items SET NULL). 도메인에 불필요한 cascade/orphanRemoval 추가 안 했는가.

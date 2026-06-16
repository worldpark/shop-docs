# 039. 판매 등록 시 기본가격 ↔ Variant 가격 혼동 해소 (등록 UX)

> 출처: 사용자 요청 — "기본가격과 Variant 가격이 따로 있어 판매 등록 시 헷갈린다. 모델은 그대로 두고 화면에서 좋은 방법 없나."
> 결정: **가격 모델은 절대가(variant.price가 실제 결제가) 그대로 유지**. delta/가산 모델로 바꾸지 않는다. **view 레이어만** 개선해 혼동을 없앤다.

## 배경 / 현황 (실사 확정)
- **결제가는 variant 가격**: 장바구니·주문·결제 모두 `variant.price` 사용(`CartService:308` `unitPrice=variant.price()`, `OrderService:194,231` 락 후 snapshot.price, `Product*CatalogImpl`이 `variant.getPrice()` 반환). `basePrice`는 과금 경로에 안 들어간다.
- **basePrice의 실제 역할**: ① 공개 목록 `displayPrice = COALESCE(MIN(활성 variant price), basePrice)`(활성 variant 있으면 최저가, 없으면 폴백) — `ProductRepository:48,94,107`, ② 판매자 화면 등록 기준가(`SellerProductSummaryView`), ③ 공개 DTO 미노출.
- **혼동 원인**: 등록 화면(`product-form.html`)에 "기본 가격" 입력칸(`basePrice`, line 81~92)이 있고, variants 화면(`product-variants.html`)에 variant별 "가격" 입력칸(line 174~185)이 또 있는데, **어느 게 실제 결제가인지 화면이 설명하지 않는다.**

## Target / Goal
판매자가 "기본가격"과 "variant 가격"의 역할을 화면에서 즉시 이해하고, variant 가격 입력 부담·혼동 없이 등록을 마칠 수 있게 한다. **백엔드 도메인·스키마·결제 로직은 변경 없음.**

## 범위 (Scope) — view-implementor

### A. 라벨·안내문 명확화 (`product-form.html`, `product-variants.html`)
- `product-form.html` 기본가격(line 83 label) → 라벨 "**기본 가격**" 유지하되 **인라인 도움말** 추가:
  "옵션(Variant)을 추가하면 **목록에는 최저 옵션가가 '○○원~'로 표시**되고, **실제 결제는 각 옵션 가격으로** 됩니다. 옵션이 없으면 이 기본 가격이 표시됩니다." (문구는 plan에서 확정·간결화)
- `product-variants.html` variant 추가 폼 가격칸(line 176 label) 옆 한 줄: "**이 가격으로 실제 결제됩니다.**"
- 톤·마크업은 기존 `.field-hint`/`.help-text` 등 현행 클래스 재사용(신규 CSS 최소화).

### B. variant 가격 = 기본가 prefill (★핵심, `product-variants.html` + 모델)
- variant **추가** 폼의 가격 입력에 **상품 기본가격을 기본값/placeholder로 미리 채움**. 같으면 그대로 제출, 다르면 조정.
- → 절대가 모델이지만 판매자에게는 "**기본가에서 옵션별로 조정**"하는 멘탈모델로 보이게 한다(사용자가 원래 기대한 흐름).
- **선행 확인(plan)**: variants 페이지 모델의 `product`(현재 `SellerProductRef`)에 `basePrice`가 노출되는지 확인. 없으면 **`SellerProductRef`/Facade가 basePrice를 싣도록 view-binding 범위에서 추가**(도메인 변경 아님, 조회 DTO 필드 추가). VariantForm의 검증 실패 재렌더 시에도 prefill이 사용자가 입력한 값을 덮지 않도록 주의(`th:field` 우선, 초기 노출만 prefill).

### C. 구매자 표시 미리보기 (선택 — plan에서 포함 여부 결정)
- `product-form.html` 기본가격 옆/아래 라이브 힌트: "구매자에겐 **최저 옵션가 ○○원~** 로 표시됩니다"(variant 있으면 MIN, 없으면 기본가). 등록 폼은 variant가 아직 없을 수 있으므로 정적 안내로 단순화 가능.

## Non-goals
- 가격 모델 변경(base+delta/가산, option_value 가격 컬럼 추가) — **명시적 비범위**. 절대가 유지.
- basePrice 필수→선택 전환, 컬럼/엔티티 변경 — 비범위(혼동 해소는 문구·prefill로 충분).
- 결제·주문·장바구니·카탈로그 가격 산정 로직 — 불변.

## 검증
- **브라우저 E2E 필수**(메모리 "목록/폼 조건부 UI·JS는 MockMvc·통합이 못 잡음"): 판매자 로그인 → 상품 등록(기본가 입력, 안내 노출 확인) → variants 페이지에서 variant 추가 폼 가격칸에 **기본가 prefill 확인** → 다른 값으로 조정·저장 반영 확인.
- prefill이 검증 실패 재렌더 시 사용자 입력을 덮지 않는지 확인.
- 백엔드 회귀 없음(조회 DTO에 basePrice 추가 시 타깃 테스트만): `*SellerProductVariant*` 그린.

## 참고
- 가격 흐름 실사: 본 세션 — `CartService`/`OrderService`/`Product*CatalogImpl`/`ProductRepository`.
- 화면: `templates/seller/product-form.html`(basePrice line 81~92), `templates/seller/product-variants.html`(variant 추가 폼 line 156~). view 컨트롤러 `SellerProductVariantViewController`(model `product`=SellerProductRef).
- 같은 화면을 다루는 Task 038(옵션·Variant 삭제·수정 UI)과 연계 — 038 이후 진행 권장.

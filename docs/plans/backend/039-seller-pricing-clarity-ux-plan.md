# Plan 039. 판매 등록 기본가↔Variant 가격 혼동 해소 (A+B)

> 대상 Task: `docs/tasks/backend/039-backend-shop-core-seller-pricing-clarity-ux.md`
> 범위 확정: 사용자 지시로 **A(라벨·안내) + B(variant 가격 = 기본가 prefill)** 만. C(구매자 표시 미리보기)는 제외.
> 가격 모델(절대가) 불변. 결제·주문·장바구니·카탈로그 로직 무변경.
> 구현: 조회 DTO 필드 추가=backend-implementor → 화면=view-implementor → reviewer → 풀 게이트 → e2e-runner.

## 실사 결론 (코드 확인 완료)
- variants 페이지 모델 `product`는 `SellerProductRef(long productId, String name)` — **basePrice 미노출**. B(prefill)에 basePrice가 필요하므로 **DTO에 basePrice 추가**가 선행.
- `SellerProductRef` 생성처 2곳(둘 다 `Product` 엔티티 보유 → `getBasePrice()` 가능):
  - `SellerProductVariantFacadeImpl.java:49`
  - `SellerProductImageFacadeImpl.java:47`
- `SellerProductRef` 소비: `VariantManagementView`, `ProductImageManagementView`(이미지 화면은 basePrice 안 써도 무해).
- 폼: `product-form.html` basePrice 입력 line 81~92(label line 83). `product-variants.html` variant **생성**폼 가격 입력 line 174~192(`th:field="*{price}"`, id `variantPrice`), 인라인 `<script>`(반드시 `<main>` 내부 — [[inline-script-must-be-inside-main-layout-fragment]]). price는 BigDecimal(scale 2)이라 렌더 표현은 "10000.00".

## 1. 백엔드 — SellerProductRef에 basePrice 추가 + GET prefill (backend-implementor)
### 1.1 DTO 필드 추가
- `SellerProductRef` 레코드에 `java.math.BigDecimal basePrice` 컴포넌트 추가 → `record SellerProductRef(long productId, String name, BigDecimal basePrice)`.
- **production 생성처 2곳**을 `new SellerProductRef(product.getId(), product.getName(), product.getBasePrice())`로 갱신:
  - `product/service/SellerProductVariantFacadeImpl.java:49`
  - `product/service/SellerProductImageFacadeImpl.java:47`
- Javadoc("상품 ID와 이름만") 1줄 갱신.
- **다른 레이어 변경 없음**(Service/Repository/Entity 불변, 결제·주문 무관). 소비처 record(`VariantManagementView`/`ProductImageManagementView`)는 필드 보유만 하므로 변화 없음.

### 1.2 테스트 생성처 갱신 (확정 — record canonical constructor라 인자 추가 시 전부 컴파일 에러)
`new SellerProductRef(...)` 직접 생성 **테스트 5곳(4파일)** 을 basePrice 인자 추가로 갱신(임의 BigDecimal, 예 `new BigDecimal("10000.00")`):
- `src/test/java/com/shop/shop/web/product/SellerProductVariantViewControllerTest.java:168`
- `src/test/java/com/shop/shop/web/product/SellerProductImageViewControllerTest.java:170`
- `src/test/java/com/shop/shop/view/SellerProductImagesRenderingTest.java:155, 229, 342`
- `src/test/java/com/shop/shop/view/SellerProductVariantsRenderingTest.java:157`

### 1.3 GET prefill (B의 서버 사이드 처리 — 비파괴 보장)
variants 페이지 **GET 핸들러**에서 `model.addAttribute("variantForm", new VariantForm())` 하는 자리(`SellerProductVariantViewController` line 80 부근)에서, **새 VariantForm의 price를 basePrice로 세팅**한다:
`VariantForm vf = new VariantForm(); vf.setPrice(view.product().basePrice()); model.addAttribute("variantForm", vf);`
(VariantForm에 price setter/가변 필드가 없으면 setter 추가 또는 생성자 활용 — 폼 백킹 객체라 가변이 일반적. basePrice가 null이면 그대로 null 세팅.)
- **검증 실패 재렌더 경로는 건드리지 않는다**: 그 경로들(createVariant/updateVariant 실패 시 `model.addAttribute("variantForm", <제출된 form>)`)은 사용자가 제출한 variantForm을 그대로 echo → price가 비어 검증 실패한 경우에도 빈 채로 에러와 함께 표시(모순 없음).
- 결과: **초기 GET만** 가격칸이 basePrice로 보이고, 검증 실패 재렌더는 사용자 입력 보존 → 완전 비파괴.
- **일관성**: 옵션/옵션값 생성 검증 실패 재렌더 경로(`createOption` line 112, `createOptionValue` line 159)도 `new VariantForm()`을 재주입하므로, 그곳도 **동일하게 `vf.setPrice(basePrice)`** 적용해 variant 생성폼 가격칸을 초기 GET과 통일한다(작은 헬퍼 `newPrefilledVariantForm(basePrice)` 추출 권장). 단 **variant POST 검증 실패 경로(createVariant/updateVariant)는 절대 건드리지 말 것**(제출 폼 echo 보존).

### 1.4 타깃 테스트 (풀 스위트 금지)
`./gradlew test --tests "*SellerProductVariant*" --tests "*SellerProductImage*"` — 위 4개 테스트 파일(`SellerProductVariantViewControllerTest`, `SellerProductImageViewControllerTest`, `SellerProductImagesRenderingTest`, `SellerProductVariantsRenderingTest`)을 모두 커버. 컴파일·그린 확인. 추가로 GET prefill 검증(렌더된 가격 input value=basePrice)을 `SellerProductVariantsRenderingTest`에 1케이스 보강 권장.

## 2. 화면 — 라벨·안내(A) + 기본가 prefill(B) (view-implementor)
`templates/seller/product-form.html` + `templates/seller/product-variants.html`만 수정.

### 2.A 라벨·안내문 (기존 클래스 재사용, 신규 CSS 최소화)
- `product-form.html` 기본가격 필드(label line 83 부근)에 도움말 1~2줄 추가:
  "옵션(Variant)을 추가하면 목록에는 **최저 옵션가가 '○○원~'로 표시**되고, **실제 결제는 각 옵션 가격으로** 됩니다. 옵션이 없으면 이 기본 가격이 표시됩니다." (간결화 가능). 기존 `.field-hint`/유사 클래스 또는 `<small class="help-text">` 사용.
- `product-variants.html` variant 생성폼 가격 입력(label line 176 부근) 옆 한 줄: "**이 가격으로 실제 결제됩니다.**"

### 2.B variant 생성폼 가격 prefill — 서버 GET prefill + 취소 시 JS 복원
**초기 prefill은 §1.3 서버 사이드(GET에서 variantForm.price=basePrice)** 로 처리한다(th:field가 그 값을 렌더). 화면(JS)은 **취소 경로만** 보강:
- 인라인 `<script>` 상단에 기본가 주입: `var basePrice = /*[[${product.basePrice}]]*/ '';` (th:inline javascript, null이면 빈문자).
- **취소 복귀(resetToCreateMode)**: 기존 `priceInput.value=''`(가격 비움)를 `priceInput.value = (basePrice !== null && basePrice !== '' ? basePrice : '')`로 바꿔 생성 모드 복귀 시 가격칸이 다시 기본가를 보이게 한다(서버 초기 GET과 일관).
- **수정 모드(switchToEditMode)**: 기존대로 해당 variant price로 덮어씀(변경 없음).
- **로드시 JS prefill은 두지 않는다**(검증 실패 재렌더에서 빈 가격칸을 basePrice로 덮는 모순 방지 — plan-reviewer MAJOR 반영). 초기값은 전적으로 서버 GET이 책임.
- basePrice는 BigDecimal → "10000.00" 형태로 채워짐(number input 정상). 의도된 충실한 값.

### 2.C 주의
- 인라인 `<script>`는 반드시 `<main>` 내부([[inline-script-must-be-inside-main-layout-fragment]]). 기존 스크립트에 basePrice 변수·prefill만 추가(구조 유지).
- Thymeleaf 예약 모델명 회피(이미 `product`/`variantForm` 사용 — 무관).

## 3. 순서 / 검증 게이트
1. backend-implementor(SellerProductRef basePrice + 생성처 2곳 + 깨진 테스트) → reviewer.
2. view-implementor(A 안내 + B prefill JS) → reviewer.
3. 메인: 풀 스위트 그린(최종 게이트).
4. e2e-runner: 앱 기동(JWT secret + Hikari 풀 10, [[k6-perf-baseline-needs-clean-db]] 무관) 상태에서
   - 상품 등록 폼에 기본가 안내 노출,
   - variants 페이지 진입 시 생성폼 가격칸이 **기본가로 prefill**,
   - "수정" 클릭 → 해당 variant 가격으로 교체, "취소" → 다시 기본가로 복귀.

## 4. 리뷰 관점
- DTO 필드 추가가 **production 생성처 2곳 + 테스트 5곳**에 빠짐없이 반영됐는가(컴파일·그린). 다른 레이어 오염 없는가.
- **초기 prefill은 서버 GET**(variantForm.price=basePrice)에서 오고, **검증 실패 재렌더 경로는 제출된 폼을 그대로 echo**해 사용자 입력을 덮지 않는가(특히 price 자체를 비워 검증 실패한 경우 빈 채로 유지). 취소 시 JS가 기본가로 복원, 수정 모드는 variant price로 덮음 — 경로 정합.
- 안내 문구가 사실과 일치(결제=variant 가격, 목록=최저가 표시, 폴백=basePrice). 과장/오정보 없는가.
- 인라인 스크립트가 `<main>` 내부 유지. 신규 CSS 최소·기존 클래스 재사용.
- 결제·주문·장바구니·카탈로그 무변경(범위 준수).

# Task 057 — shop-core 쿠폰 화면(admin 관리 + 사용자 쿠폰함·체크아웃 적용) plan

> 범위 SSOT: docs/tasks/backend/057-backend-shop-core-coupon-admin-management-and-user-wallet-checkout-view.md
> 대상: shop-core. 구현자: view-implementor(Thymeleaf 화면·View 컨트롤러 뷰바인딩·정적 리소스) + backend-implementor(admin 조회 facade/REST·OrderFacade 체크아웃 합성·SecurityConfig·폼 바인딩).
> 본 plan은 Task가 위임한 5개 설계 결정을 코드 대조로 확정한다. 쿠폰 비즈니스 로직(발급/적용/할인계산/소비/복원·동시성)은 031에서 완성·검증됐고 본 Task는 무변경이다(회귀 금지).
> 패키지 루트는 com.shop.shop(코드 대조 확인 — com.shop 아님).

## 구현 목표
ADMIN이 /admin/coupons에서 쿠폰 정의를 목록·사용현황과 함께 보고 등록 폼으로 생성한다. 로그인 사용자가 /coupons 쿠폰함에서 보유 쿠폰을 미사용/사용/만료 구분으로 보고 코드로 발급받는다. 체크아웃(/checkout)에서 적용가능 쿠폰을 선택해 예상 할인을 보고 주문 생성 시 userCouponId로 적용한다. 모든 비즈니스 로직은 031 서비스 재사용이며, 본 Task는 화면 + 화면 구동용 최소 조회만 추가한다.

## 영향 범위

### 신규 파일
#### view-implementor
- web/coupon/CouponViewController.java — GET /coupons, POST /coupons/claim
- web/coupon/AdminCouponViewController.java — GET /admin/coupons, POST /admin/coupons
- web/coupon/CouponClaimForm.java — 발급 폼(code)
- web/coupon/AdminCouponCreateForm.java — admin 생성 폼
- src/main/resources/templates/coupon/wallet.html — 쿠폰함
- src/main/resources/templates/admin/coupons.html — admin 목록 + 등록 폼

#### backend-implementor
- order/spi/CouponFacade.java — 쿠폰함 View 전용 facade(published port)
- order/spi/AdminCouponFacade.java — admin 쿠폰 View 전용 facade(published port)
- order/service/CouponFacadeImpl.java — CouponFacade 구현(CouponService 위임 + MemberDirectory로 email→userId)
- order/service/AdminCouponFacadeImpl.java — AdminCouponFacade 구현(CouponService.createDefinition + 목록 조회 위임)
- order/dto/CouponWalletItemResponse.java(또는 기존 UserCouponResponse 재사용 — §2.6 확정) — 쿠폰함 행 표시 DTO
- (테스트) 아래 §5에 열거한 View 슬라이스/Security/단위/E2E 테스트 클래스

### 수정 파일
- order/repository/CouponRepository.java — findAllByOrderByEndsAtDesc() 1개 추가(읽기 전용)
- order/spi/OrderFacade.java — getCheckout 반환을 적용가능 쿠폰 포함으로 확장하거나 별도 메서드 추가(§2.4 확정)
- order/dto/OrderCheckoutResponse.java — 적용가능 쿠폰 리스트 필드 추가(§2.4 확정 — 채택안)
- order/service/(OrderFacade 구현체) — getCheckout이 CouponService.getApplicable 합성
- web/order/OrderViewController.java — createOrder가 form.userCouponId를 OrderCreateRequest 6번째 인자로 전달(현재 null 고정 제거), checkout 모델에 적용가능 쿠폰 노출 정합
- web/order/OrderCreateForm.java — userCouponId(Long, 선택) 필드 추가
- src/main/resources/templates/order/checkout.html — 쿠폰 선택 UI + 예상 할인 표기 + 폼 userCouponId 입력
- src/main/resources/templates/fragments/nav.html — admin 쿠폰 관리 + CONSUMER 쿠폰함 링크 추가
- security/SecurityConfig.java — View 체인에 /coupons, /coupons 이하 hasRole CONSUMER matcher 추가
- (선택, 결정 1 채택 시) order/controller/AdminCouponRestController.java + order/service/CouponServiceResponse.java — GET /api/v1/admin/coupons 추가

### 무변경(재사용)
order/service/CouponService(claim/getMyCoupons/getApplicable/computeDiscount/consume/restoreByOrder/createDefinition), order/service/CouponServiceResponse(REST), order/service/CouponDtoMapper, order/controller/CouponRestController, order/controller/AdminCouponRestController(POST 생성), order/domain/Coupon·UserCoupon, order/repository/UserCouponRepository, OrderService.createOrderTx(쿠폰 적용·할인·소비), OrderCancellationImpl.doCancel(복원), DTO(AdminCouponResponse/UserCouponResponse/ApplicableCouponResponse/CouponClaimRequest/AdminCouponCreateRequest), V1~최신 마이그레이션, event-catalog.md/§5, notification 전부, CartCheckoutReader/ProductOrderCatalog.

---

## 1. 설계 방식 및 이유 (Task 위임 5개 결정 확정)

### 1.1 admin 목록/사용현황 조회 노출 방식 — View 전용 facade 채택 + REST 추가는 비채택(결정 1)
admin 쿠폰 목록/사용현황 조회는 41 선례(AdminCategoryFacade)와 동일하게 **order.spi의 View 전용 facade(AdminCouponFacade)** 로만 노출한다. 별도 GET /api/v1/admin/coupons REST는 만들지 않는다.

근거(코드 대조):
- 041 admin 카테고리 관리는 AdminCategoryViewController가 product.spi의 AdminCategoryFacade만 의존하고 별도 admin 조회 REST를 만들지 않았다(목록은 facade.list()). 043 admin 대시보드도 web 조합 facade만 쓴다. 화면이 유일한 소비자인 admin 조회는 REST 표면을 늘리지 않는 것이 선례다.
- Task가 둘 중 하나로 확정을 위임했고, "REST(또는 View 컨트롤러용 조회 경로)" 둘 다 허용된 범위다. View facade가 변경 표면이 작고(REST 컨트롤러·ServiceResponse·Security 테스트 불필요) 모듈 경계도 동일하다.
- 단, 쿠폰 정의 생성 REST(POST /api/v1/admin/coupons)는 031에서 이미 존재하므로 admin이 API로도 생성은 가능하다(무변경). 본 Task는 그 위에 화면만 얹는다.

대안(비채택): GET /api/v1/admin/coupons REST 추가. 화면 외 소비자가 없고 041 선례와 어긋나 표면만 늘린다. (만약 reviewer가 REST 일관성을 강하게 요구하면 §2.4의 facade를 ServiceResponse로 한 줄 위임하는 컨트롤러만 추가하는 fallback이 가능하나 기본 비채택.)

### 1.2 쿠폰함 위치 — 별도 페이지 /coupons 채택(결정 2)
쿠폰함은 029 /account에 통합하지 않고 **별도 페이지(GET /coupons → coupon/wallet)** 로 둔다.

근거:
- 029 AccountViewController는 /account가 비밀번호 변경/정보 수정/탈퇴 self-service 전용이고 AccountFacade(member.spi)만 의존한다. 쿠폰함을 끼우면 member web 컨트롤러가 order 도메인(쿠폰)을 참조하게 돼 책임·모듈 경계가 섞인다.
- 쿠폰은 order 모듈 소속(031 결정)이므로 web/coupon에 별도 컨트롤러를 두고 order.spi facade를 의존하는 것이 모듈 경계상 깔끔하다(015 web/order, 041 web/product 선례와 동형).
- nav CONSUMER 메뉴 블록(장바구니/주문 내역 인접)에 쿠폰함 링크를 추가한다.

### 1.3 체크아웃 쿠폰 선택 UI — 배송지 폼 내부 단일 제출 + 서버사이드 미리보기(결정 3)
015 checkout.html의 결제 금액 섹션 인접에 쿠폰 선택 영역을 두고, **배송지 폼(POST /orders) 안에 userCouponId 입력(라디오/셀렉트)을 포함**시켜 한 번의 제출로 적용한다. 적용가능 쿠폰·예상 할인은 **GET /checkout 서버사이드 렌더**로 제공한다(applicable ajax 비채택).

근거(코드 대조):
- 015 checkout.html은 이미 form action=/orders method=post 단일 폼이고 recipient/phone/postcode/address1/address2 5개 input을 담는다. userCouponId input(hidden 아님 — 라디오/셀렉트) 1개를 같은 폼에 추가하면 OrderViewController.createOrder가 @ModelAttribute OrderCreateForm으로 함께 바인딩한다.
- 서버사이드 렌더는 GET /checkout의 itemsAmount와 동일 기준으로 getApplicable을 계산하므로 화면 표기 할인과 실제 적용 할인의 기준이 일치한다(ajax는 별도 호출로 타이밍·일관성 표면 증가). 메모리 선례상 체크아웃 조건부 선택은 E2E로 검증하므로 서버사이드가 E2E 안정성도 높다.
- 최종 할인은 주문 생성 시 OrderService.createOrderTx의 computeDiscount가 권위(화면 expectedDiscount는 안내용). 사용자가 라디오를 바꿔도 서버 재계산이 정답.

### 1.4 적용가능 쿠폰을 OrderCheckoutResponse에 합성(결정 4)
GET /checkout 모델에 적용가능 쿠폰을 싣는 방법은 **OrderCheckoutResponse에 적용가능 쿠폰 리스트 필드를 추가**하고 OrderFacade.getCheckout 구현이 CouponService.getApplicable을 합성하는 방식으로 한다.

근거(코드 대조):
- OrderCheckoutResponse는 현재 items/itemsAmount/discountAmount/shippingFee/finalAmount/hasItems record다. record에 List 필드 1개를 추가(예: applicableCoupons)하는 것은 가산 변경이고, OrderViewController는 이미 model.addAttribute(checkout, ...) 한 번으로 모델을 채우므로 별도 모델 키를 늘리지 않아도 된다.
- CouponService.getApplicable(long userId)은 이미 order 모듈 내부 메서드이고 장바구니 itemsAmount를 자체 산정한다(CartCheckoutReader/ProductOrderCatalog 사용). OrderFacade 구현체(order/service)가 같은 모듈에서 CouponService를 직접 주입·호출하면 신규 cross-module 의존이 0이다(둘 다 order 모듈 internal).
- ApplicableCouponView/ApplicableCouponResponse가 이미 (userCouponId, couponId, code, name, applicable, expectedDiscount, reason)을 제공한다. checkout 화면 표기에 충분하므로 OrderCheckoutResponse의 새 필드 타입으로 ApplicableCouponResponse(또는 동등 record)를 재사용한다.
- 대안(별도 모델 키 applicableCoupons): OrderViewController.checkout이 OrderFacade에서 별도 메서드로 쿠폰 목록을 받아 model.addAttribute를 2번 한다. 합성 record 1개가 더 응집적이라 채택안은 OrderCheckoutResponse 합성. (Task의 Backend-View Contract는 applicableCoupons 모델 키를 예시로 적었으나, plan은 checkout.applicableCoupons 합성으로 더 단순화한다 — 모델 키 1개 유지. view-implementor는 checkout.applicableCoupons로 접근.)

### 1.5 신규 백엔드 최소화 — 조회 read만(결정 5)
- CouponRepository에 findAllByOrderByEndsAtDesc() 1개만 추가(admin 목록·사용현황용 전체 조회). 파생 쿼리라 구현 0줄. 읽기 전용.
- AdminCouponFacade.list()는 이 메서드 결과를 AdminCouponResponse(이미 used_count/usage_limit/is_active 포함)로 매핑해 반환. 사용현황은 Coupon.usedCount/usageLimit를 그대로 노출(추가 집계 불필요 — used_count가 이미 권위 카운터).
- 비즈니스 로직(할인·소비·복원·동시성)은 일절 손대지 않는다. createDefinition도 031 메서드 그대로 위임.

---

## 2. 구성 요소

### 2.1 View 컨트롤러 (web/coupon) — view-implementor 뷰바인딩 / backend-implementor facade 호출 영역

> View 인증 전제(코드 대조): View 보안체인은 054 cutover로 **JWT 쿠키 인증 + STATELESS(formLogin 제거)**다. viewJwtAuthenticationFilter의 emailPrincipalFactory가 principal getName()=email을 세팅하므로 CurrentActorResolver.resolve(auth).email()=auth.getName()=email로 데이터 흐름이 그대로 성립한다(015/029 선례와 동일 — 메커니즘만 form-login→JWT 쿠키로 바뀌었을 뿐 facade로 email이 전달되는 흐름은 동형).

**CouponViewController** (@Controller)
- 의존: CouponFacade(order.spi), CurrentActorResolver(web.support — 015/029 선례).
- GET /coupons → view coupon/wallet. CurrentActorResolver.resolve(auth).email() → CouponFacade.getMyWallet(email) → model.addAttribute(couponWallet, ...) + model.addAttribute(couponClaimForm, new CouponClaimForm()).
- POST /coupons/claim → @Valid @ModelAttribute(couponClaimForm) CouponClaimForm + BindingResult. 검증 실패 시 flashError 후 redirect:/coupons(폼 단순 — 재렌더 대신 PRG). 성공 시 CouponFacade.claim(email, form.getCode()) → flashSuccess + redirect:/coupons. BusinessException(404/400/409) catch → flashError + redirect:/coupons(메시지 그대로).
- 비즈니스 로직 없음(015/029/041 컨트롤러 패턴).

**AdminCouponViewController** (@Controller, @RequestMapping(/admin/coupons))
- 의존: AdminCouponFacade(order.spi). 인가는 SecurityConfig View 체인 /admin 이하 hasRole ADMIN가 커버(컨트롤러 권한 분기 금지 — 041 동일).
- GET /admin/coupons → AdminCouponFacade.list() → model.addAttribute(coupons, List AdminCouponResponse) + couponForm(없으면 new). 041 list() 패턴 복제(폼 에러 재렌더 시 RedirectAttributes 보존).
- POST /admin/coupons → @Valid @ModelAttribute(couponForm) AdminCouponCreateForm + BindingResult. 검증 실패 시 목록 재조회 후 동일 뷰 재렌더(041 create 패턴). 성공 시 AdminCouponFacade.create(...) → flashSuccess + redirect:/admin/coupons. DuplicateCouponCodeException 등 BusinessException → flashError + redirect.

### 2.2 폼 backing object (web/coupon) — view-implementor
- CouponClaimForm: @NotBlank String code(+ getter/setter). Entity 미바인딩.
- AdminCouponCreateForm: code/name(@NotBlank), discountType(@NotBlank — fixed 또는 percent), value(@NotNull @Positive BigDecimal), minOrderAmount(BigDecimal), maxDiscount(BigDecimal nullable), startsAt/endsAt(@NotNull Instant — datetime-local 바인딩, KST), usageLimit(Integer nullable — 빈값=무제한), isActive(Boolean). 검증 어노테이션은 폼에 두되 CHECK(value 양수, endsAt이 startsAt 초과)·discountType 화이트리스트의 최종 권위는 031 Coupon.create/createDefinition(도메인 검증 + DB CHECK)이다 — 폼은 1차 UX 검증, facade가 BusinessException으로 최종 거부.

### 2.3 View 전용 facade (order/spi + order/service) — backend-implementor

**CouponFacade** (order/spi, @NamedInterface published port)
- UserCouponWallet getMyWallet(String email) 또는 List CouponWalletItemResponse getMyWallet(String email) — email→userId(MemberDirectory) 후 CouponService.getMyCoupons(userId) 위임, View 표시 DTO로 매핑.
- void claim(String email, String code) — email→userId 후 CouponService.claim(userId, code). 반환 불필요(View는 redirect).
- 구현 CouponFacadeImpl(order/service): MemberDirectory(member.spi — 015 OrderFacade 선례로 이미 order가 의존)로 email→userId 해석. CouponService 주입(같은 모듈 internal). Entity 미노출.

**AdminCouponFacade** (order/spi, @NamedInterface published port)
- List AdminCouponResponse list() — CouponRepository.findAllByOrderByEndsAtDesc() → AdminCouponResponse 매핑(used_count/usage_limit/is_active 포함). 읽기 전용.
- AdminCouponResponse create(AdminCouponCreateRequest req) — CouponService.createDefinition(req) 위임(031 그대로). 또는 폼 필드를 받는 시그니처(plan: web→spi 경계에 web 타입 전달 금지 규칙상 AdminCouponCreateRequest(order/dto)로 변환해 전달 — OrderViewController가 PaymentRequest 변환하는 선례와 동형. AdminCouponViewController가 form→AdminCouponCreateRequest 변환).
- 구현 AdminCouponFacadeImpl(order/service): CouponService + CouponRepository(또는 CouponService에 list 위임) 주입. (CouponRepository를 facade 구현이 직접 주입하는 것은 같은 모듈 internal이라 허용 — order/service가 order/repository 의존은 정상.)

> 모듈 경계: CouponFacade/AdminCouponFacade는 order.spi에 인터페이스만 두고 @NamedInterface(spi)로 노출, 구현은 order/service. web/coupon은 order.spi만 의존(order 내부 service/repository/domain 직접 참조 금지 — package-structure-rule). 015 OrderFacade/041 AdminCategoryFacade와 동형.

### 2.4 OrderFacade 체크아웃 합성 — backend-implementor
- OrderCheckoutResponse에 List ApplicableCouponResponse applicableCoupons 필드 추가(가산). record 컴포넌트 추가 — 프로덕션 OrderFacadeImpl(order/service)의 **2개 생성지점**(빈 장바구니 early-return: OrderFacadeImpl.java line 67, 정상 경로: line 112) + 영향 테스트를 갱신해야 컴파일 정합이 맞는다(코드 대조 확정 — §5.5 회귀 목록 참조). 빈 장바구니 early-return은 applicableCoupons=List.of()로 채운다.
- OrderFacade 구현체(order/service)의 getCheckout(email)이 기존 장바구니 합성에 더해 CouponService.getApplicable(userId)를 호출해 ApplicableCouponResponse 리스트를 채운다. CouponService는 같은 order 모듈 internal이라 신규 cross-module 의존 0. (getApplicable은 자체적으로 동일 장바구니 itemsAmount를 산정하므로 getCheckout과 기준 일치.)
- 빈 장바구니(hasItems=false): CouponService.getApplicable(CouponService.java line 174-179)은 보유 미사용 쿠폰이 있으면 각 항목을 applicable=false / reason="장바구니가 비어 있습니다."로 반환하고, 보유 미사용 쿠폰이 없을 때만 빈 리스트를 반환한다(031 동작 — 코드 대조). 어느 쪽이든 checkout.html은 hasItems=false 분기에서 쿠폰 영역을 미표시하므로 화면상 무해. (다만 빈 장바구니 early-return 경로(OrderFacadeImpl line 67)는 getApplicable을 호출하지 않고 applicableCoupons=List.of()로 둔다 — getApplicable 합성은 정상 경로 line 112에서만 수행.)

### 2.5 SecurityConfig — backend-implementor
- View 체인에 .requestMatchers(/coupons, /coupons/**).hasRole(CONSUMER) 추가. 위치는 기존 /checkout, /orders matcher 인접(line 212 근처), anyRequest 앞. /coupons/claim도 이 matcher가 커버.
- REST·admin·checkout 경로는 무변경(이미 커버 — Task Context 인가 현황 참조).

### 2.6 표시 DTO — backend/view 공유
- 쿠폰함: 031 UserCouponResponse(userCouponId/couponId/code/name/discountType/value/minOrderAmount/maxDiscount/startsAt/endsAt/used/usedAt/expired)를 그대로 View 표시에 재사용 가능(이미 used/expired 플래그 포함). 신규 DTO 불필요 시 CouponFacade.getMyWallet이 List UserCouponResponse 반환(CouponDtoMapper 재사용). → 채택: UserCouponResponse 재사용(신규 DTO 미생성, 변경 표면 최소). CouponWalletItemResponse는 만들지 않음.
- admin 목록: 031 AdminCouponResponse 재사용(used_count/usage_limit/is_active 포함). 신규 DTO 불필요.
- 체크아웃: 031 ApplicableCouponResponse 재사용(OrderCheckoutResponse.applicableCoupons 필드 타입).

> 결과: 신규 DTO 0개(전부 031 DTO 재사용). facade/컨트롤러/템플릿/SecurityConfig/폼만 추가·수정.

---

## 3. 데이터 흐름

### 3.1 admin 쿠폰 목록·생성 — /admin/coupons
1. SecurityConfig View 체인 /admin 이하 hasRole ADMIN 통과(비ADMIN 403, 비인증 /login redirect).
2. GET: AdminCouponViewController.list → AdminCouponFacade.list() → CouponRepository.findAllByOrderByEndsAtDesc() → AdminCouponResponse 매핑 → model(coupons, couponForm) → admin/coupons.
3. POST: 폼 검증(UX 1차) → form→AdminCouponCreateRequest 변환 → AdminCouponFacade.create → CouponService.createDefinition(031: Coupon.create 도메인 검증 + save). code 중복 → DuplicateCouponCodeException(409) → flashError. 성공 → flashSuccess + redirect:/admin/coupons.

### 3.2 쿠폰함 조회·발급 — /coupons
1. SecurityConfig View 체인 /coupons 이하 hasRole CONSUMER 통과.
2. GET: CouponViewController.wallet → CurrentActor.email → CouponFacade.getMyWallet(email) → email→userId(MemberDirectory) → CouponService.getMyCoupons(userId)(031: user_coupons + coupon 조인, used/expired 계산) → List UserCouponResponse → model(couponWallet, couponClaimForm) → coupon/wallet. 타인 쿠폰은 userId 조건으로 원천 차단(IDOR).
3. POST claim: CouponFacade.claim(email, code) → CouponService.claim(031: findByCode→isClaimable→save, UNIQUE 위반→CouponAlreadyOwnedException 409). 성공 flashSuccess + redirect:/coupons / 실패(404/400/409) flashError + redirect:/coupons.

### 3.3 체크아웃 적용가능 표기 + 주문 적용 — /checkout, POST /orders
1. GET /checkout(015 기존 흐름): OrderViewController.checkout → OrderFacade.getCheckout(email). 구현체가 장바구니 합성 + CouponService.getApplicable(userId) 합성 → OrderCheckoutResponse(items..., applicableCoupons) → model(checkout) → order/checkout.
2. 화면: hasItems=true면 결제 금액 섹션 + 쿠폰 선택 라디오(쿠폰 미적용 기본 + checkout.applicableCoupons 중 applicable=true는 선택 가능·expectedDiscount 표기, applicable=false는 reason과 함께 disabled). 선택값은 배송지 폼(action=/orders) 안의 name=userCouponId.
3. POST /orders: OrderViewController.createOrder → OrderCreateForm(userCouponId 포함) → OrderCreateRequest(recipient,phone,postcode,address1,address2, userCouponId) — 현재 null 고정을 form.getUserCouponId()로 교체 → OrderFacade.createOrder → OrderService.createOrderTx(031: userCouponId 있으면 computeDiscount→Order 9-arg→consume; 없으면 기존 흐름). 적용 거부(400/409) → BusinessException → flashError + redirect:/checkout(015 동일). 성공 → redirect:/orders/{orderId}.
4. userCouponId 빈값/null이면 OrderCreateRequest.userCouponId=null → 031 createOrderTx가 discount=0 기존 흐름(회귀 0).

> 폼 빈 문자열 바인딩 주의: HTML 라디오/셀렉트의 쿠폰 미적용 옵션 value=""(빈 문자열). Spring이 Long userCouponId에 빈 문자열을 바인딩하면 null이 되도록 한다(@ModelAttribute 기본 — 빈 문자열→null 변환 정상). view-implementor는 쿠폰 미적용 옵션 value를 빈값으로 두고, 라디오 미선택 방지를 위해 쿠폰 미적용을 checked 기본으로 둔다.

---

## 4. 예외 처리 전략
- REST(031, 무변경): /api/v1/coupons 이하·/api/v1/admin/coupons는 RestExceptionHandler가 ErrorResponse JSON(error-response-rule). 본 Task는 REST 예외 흐름 무변경.
- View: BusinessException(404 CouponNotFound, 400 CouponNotClaimable/NotApplicable, 409 CouponAlreadyOwned/Conflict/DuplicateCouponCode)을 컨트롤러가 catch → flashError(메시지 그대로) + redirect(041/015/029 View 패턴). View는 ErrorResponse JSON을 쓰지 않는다(error-response-rule: View는 에러 페이지/flash). 메시지는 031 예외의 사용자 노출 메시지 그대로(내부 정보 비노출).
- admin 생성 검증 실패: 폼 @Valid 실패는 BindingResult로 재렌더(목록 재조회), 도메인 검증 실패(value/기간/discountType)·code 중복은 facade BusinessException → flashError.

| 분기 | 경로 | 처리 |
|---|---|---|
| 비인증 | 모든 View 경로 | Security → /login redirect |
| 비CONSUMER가 /coupons | /coupons 이하 | 403(View 체인) |
| 비ADMIN이 /admin/coupons | /admin 이하 | 403(View 체인) |
| 발급: 미존재/비활성/기간외/중복 | POST /coupons/claim | BusinessException → flashError + redirect:/coupons |
| admin 생성: 폼 검증 실패 | POST /admin/coupons | BindingResult 재렌더(목록 재조회) |
| admin 생성: code 중복/도메인 검증 | POST /admin/coupons | BusinessException → flashError + redirect |
| 주문 적용: 거부(400/409) | POST /orders | 031 BusinessException → flashError + redirect:/checkout(015 기존) |

---

## 5. 검증 방법

> verification-gate-rule: reviewer PASS(정적) != 빌드 그린. 메인이 gradlew test 전체 그린 + Modulith verify를 별도 확인. **목록 페이지 조건부 버튼/폼·체크아웃 쿠폰 선택·인라인 script(main 내부 여부)는 MockMvc·통합으로 못 잡으므로 e2e-runner 대상**(메모리: verify-admin-list-page-features-with-e2e, inline-script-must-be-inside-main).

### 5.1 단위/슬라이스 (Mockito / @WebMvcTest)
- CouponFacadeImpl/AdminCouponFacadeImpl: email→userId 해석·CouponService 위임·Entity 미노출 단언. AdminCouponFacade.list()가 findAllByOrderByEndsAtDesc 결과를 AdminCouponResponse로 매핑(used_count/usage_limit 보존).
- CouponViewController/AdminCouponViewController(@WebMvcTest, facade @MockitoBean): GET 모델 키(couponWallet/coupons/couponForm) + 뷰 이름, POST 성공 redirect+flash, BusinessException→flashError 분기, 폼 검증 실패 재렌더(admin) / redirect(claim).
- OrderViewController(기존 테스트 갱신): createOrder가 form.userCouponId를 OrderCreateRequest 6번째 인자로 전달(현재 null→form 값). userCouponId 미선택 시 null 전달(회귀). getCheckout 모델에 applicableCoupons 노출.

### 5.2 View 렌더링 (MockMvc 슬라이스 / 통합)
- GET /coupons·/admin/coupons·/checkout 렌더: 모델 DTO만(Entity 비노출), 폼 CSRF 토큰 포함, applicableCoupons 표기. (단 조건부 가시성·선택은 5.4 E2E.)

### 5.3 Security/REST (MockMvc)
- View: /coupons CONSUMER 200 / 비인증 redirect / (역할계층) SELLER·ADMIN 통과. /admin/coupons ADMIN 200 / CONSUMER 403 / 비인증 redirect.
- 031 회귀: /api/v1/coupons 이하·/api/v1/admin/coupons·주문 경로 인가 그린(무변경 확인).

### 5.4 브라우저 E2E (e2e-runner — 필수)
- admin: ADMIN 로그인 → /admin/coupons → 쿠폰 등록(목록·used/limit 사용현황 반영) → 중복 코드 거부 flash. 비ADMIN 접근 차단.
- 쿠폰함: CONSUMER 로그인 → /coupons → 코드 발급(목록 반영·미사용 배지) → 중복 발급 거부 → 사용/만료 구분 배지 표기.
- 체크아웃: CONSUMER 장바구니 담기 → /checkout 적용가능 쿠폰 선택(expectedDiscount 표기, 적용불가 쿠폰 disabled+reason) → 주문 생성 → 주문 상세 discountAmount/finalAmount 할인 반영. 쿠폰 미선택 주문은 할인 0(회귀). (인라인 script 사용 시 main 내부 — 드롭 여부 E2E로.)

### 5.5 회귀 (verification-gate)
- 015/029/031/041 화면·REST·서비스 그린 유지. 쿠폰 미적용 주문 생성·결제·취소(015/016/017/018) 그린.
- OrderCheckoutResponse record 컴포넌트 추가에 따른 컴파일·정합 갱신 대상(코드 대조 확정 — 전수 열거):
  - 프로덕션: `order/service/OrderFacadeImpl.java`의 `new OrderCheckoutResponse(...)` **2곳**(빈 장바구니 early-return line 67, 정상 경로 line 112).
  - 템플릿: `templates/order/checkout.html`(checkout.applicableCoupons 접근).
  - 테스트: `web/order/OrderViewControllerTest.java`(line 416 부근 sampleCheckoutResponse), `view/OrderViewRenderingTest.java`(**2곳** — sample line 387, empty line 398), `order/service/OrderFacadeImplTest.java`(line 94/120/143에서 getCheckout 결과 사용 — 새 컴포넌트 정합 점검).
- ModularityTests/ArchUnit: web/coupon→order.spi 단방향, order 내부 신규 cross-module 의존 0(CouponFacade/AdminCouponFacade는 order.spi, 구현은 order/service). order가 member.spi(MemberDirectory) 의존은 015 기존(추가 신규 아님).
- 메인 에이전트가 gradlew test 전체 BUILD SUCCESSFUL + Modulith verify를 자기 눈으로 확인.

---

## 6. 트레이드오프

| 결정 | 채택안 | 대안 | 비용/이득 |
|---|---|---|---|
| admin 조회 노출 | View 전용 facade(AdminCouponFacade) | GET /api/v1/admin/coupons REST | 채택: 041 선례·표면 최소(REST 컨트롤러/ServiceResponse/Security 테스트 불필요). 대안: 화면 외 소비자 없어 표면만 증가. |
| 쿠폰함 위치 | 별도 /coupons 페이지 | /account 통합 | 채택: order 모듈 경계 정합(web/coupon→order.spi), 책임 분리. 대안: member web이 order 도메인 참조 → 경계 오염. |
| 체크아웃 적용 UI | 배송지 폼 내 단일 제출 + 서버사이드 미리보기 | applicable ajax | 채택: itemsAmount 기준 일치·E2E 안정·기존 단일 폼 재사용. 대안: 별도 호출 타이밍/일관성 표면 증가. |
| 적용가능 쿠폰 모델 | OrderCheckoutResponse.applicableCoupons 합성 | 별도 모델 키 | 채택: 모델 키 1개 유지·응집. record 컴포넌트 가산만(OrderFacadeImpl 생성 2곳 + 영향 테스트 갱신 — §5.5). 대안: addAttribute 2회·facade 메서드 추가. |
| 표시 DTO | 031 DTO 재사용(UserCouponResponse/AdminCouponResponse/ApplicableCouponResponse) | 신규 View DTO | 채택: 신규 DTO 0개·변경 표면 최소. 대안: 중복 DTO 유지비용. |
| 신규 백엔드 | CouponRepository 목록 메서드 1개 + facade | 신규 서비스/REST 다수 | 채택: 비즈니스 로직 무변경·회귀 0. 대안: 표면 증가·회귀 위험. |

---

## 완료 조건
- [ ] ADMIN /admin/coupons 목록(사용현황 used/limit·활성여부) + 등록 폼 생성(중복 거부), 비ADMIN 차단.
- [ ] CONSUMER /coupons 쿠폰함(미사용/사용/만료 구분) + 코드 발급(중복/미존재/기간외 거부), 타인 쿠폰 비노출.
- [ ] /checkout 적용가능 쿠폰·예상 할인 표기(적용불가 사유·선택 불가), 쿠폰 선택 주문 생성 시 discountAmount/finalAmount 031 계산대로 반영.
- [ ] 쿠폰 미선택 주문 015/031 기존 흐름 동일(discount=0, 회귀 0).
- [ ] 031 비즈니스 로직·스키마·이벤트·notification 무변경. 신규 DTO 0개·신규 비즈니스 로직 0.
- [ ] SecurityConfig View /coupons matcher 추가, 나머지 인가 무변경.
- [ ] View 슬라이스/Security/단위 테스트 + 브라우저 E2E(admin 목록·쿠폰함·체크아웃 선택) 그린.
- [ ] gradlew test 풀 그린(메인 확인) + ModularityTests/ArchUnit 그린.

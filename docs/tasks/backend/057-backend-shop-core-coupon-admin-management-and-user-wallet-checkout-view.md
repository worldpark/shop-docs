# 057. shop-core 쿠폰 화면 — admin 관리(생성·목록·사용현황) + 사용자 쿠폰함·체크아웃 적용 (with View)

> 출처: Task 031(쿠폰 발급·조회·적용 + 주문 할인) 후속. 031은 백엔드/REST에 한정했고 쿠폰 관련 Thymeleaf 화면을 별도 후속 Task로 명시 분리했다(031 Target, Constraints 화면 범위 밖). 본 Task가 그 화면 공백을 채운다.
> 범위 SSOT: 본 문서. 설계 결정은 docs/plans/backend/057-coupon-admin-management-and-user-wallet-checkout-view-plan.md 에 위임한다.

## Target
shop-core (order 모듈 내 coupon 컴포넌트 + web 레이어)

> 화면(Thymeleaf SSR) + 화면 구동에 필요한 최소 백엔드 조회에 한정한다. 쿠폰 비즈니스 로직(발급/적용/할인계산/소비/복원·동시성)은 031에서 완성됐고 무변경이다. 신규 Kafka 이벤트·notification 발송 없음(031과 동일). 쿠폰 수정/삭제/비활성/회원 직접발급은 범위 밖(후속).

---

## Goal
1. ADMIN이 /admin/coupons 화면에서 쿠폰 정의를 목록 조회(코드/이름/할인/유효기간/사용현황 used_count·usage_limit/활성여부)하고, 같은 화면의 등록 폼으로 쿠폰 정의를 생성한다. 생성은 031의 POST /api/v1/admin/coupons(서비스 CouponService.createDefinition)를 재사용하고, 목록/사용현황 조회 경로만 신규 추가한다.
2. 로그인 사용자(CONSUMER)가 /coupons 쿠폰함 화면에서 보유 쿠폰을 미사용/사용/만료 구분으로 조회하고, 코드 입력 발급(claim) 폼으로 쿠폰을 받는다. 031의 GET /api/v1/coupons·POST /api/v1/coupons(서비스 getMyCoupons/claim)를 재사용한다.
3. 체크아웃(GET /checkout) 화면에서 현재 장바구니에 적용 가능한 보유 쿠폰을 선택하면 예상 할인액이 표기되고, 주문 생성(POST /orders) 시 선택한 userCouponId가 전달돼 서버가 할인을 적용한다. 031의 GET /api/v1/coupons/applicable(서비스 getApplicable)·주문 생성 userCouponId 경로를 재사용한다(이미 OrderCreateRequest.userCouponId 필드 존재, View 생성부는 현재 null 고정 — 본 Task로 실제 값 전달).

## Context
- 031에서 이미 완성·검증된 백엔드(무변경 전제):
  - order/controller/CouponRestController: POST /api/v1/coupons(claim), GET /api/v1/coupons(쿠폰함), GET /api/v1/coupons/applicable(적용 미리보기).
  - order/controller/AdminCouponRestController: POST /api/v1/admin/coupons(쿠폰 정의 생성 — 최소).
  - order/service/CouponService: claim/getMyCoupons/getApplicable/computeDiscount/consume/restoreByOrder/createDefinition + 내부 결과 record(UserCouponView/ApplicableCouponView/CouponDefResult 등). order/service/CouponServiceResponse(REST 응답 조합), order/service/CouponDtoMapper.
  - DTO: AdminCouponResponse(id/code/name/discountType/value/minOrderAmount/maxDiscount/startsAt/endsAt/usageLimit/usedCount/isActive), UserCouponResponse, ApplicableCouponResponse, CouponClaimRequest, AdminCouponCreateRequest.
  - order/domain/Coupon·UserCoupon(V1 스키마 매핑, BaseEntity 미상속), order/repository/CouponRepository·UserCouponRepository. OrderService.createOrderTx의 userCouponId 적용·할인계산·소비, OrderCancellationImpl.doCancel의 복원.
  - 단위/통합/Security/금액전파 테스트 존재(031).
- 부재(본 Task가 채움): 쿠폰 관련 Thymeleaf 화면 0개. admin 쿠폰 관리 페이지 없음. admin REST는 생성 하나뿐 — 목록/사용현황 조회 API·경로 없음. CouponRepository에 전체 목록 조회 메서드 없음(findByCode/조건부 UPDATE만 존재).
- 화면 선례(반드시 대조):
  - 사용자 self-service 화면: 029 web/member/AccountViewController + member/account.html(GET 화면 + POST 폼 PRG + flash, AccountFacade(member.spi) 경유, 모델 키 accountInfo/passwordForm).
  - 체크아웃/주문 생성: 015 web/order/OrderViewController(GET /checkout 에서 order/checkout, POST /orders), OrderFacade(order.spi), 모델 키 checkout(OrderCheckoutResponse). 주문 생성부가 이미 OrderCreateRequest(...,null)로 6번째 인자 userCouponId를 null 고정 중(031 plan — 본 Task가 실제 값으로 채움).
  - admin 목록 페이지: 041 web/product/AdminCategoryViewController + admin/categories.html(/admin/categories GET 목록 + 등록 폼 + AdminCategoryFacade(product.spi) 경유, 검증 실패 재렌더/성공 PRG), 043 web/admin/AdminDashboardViewController(/admin/dashboard), 008 admin/members.html. admin 뷰 인가는 SecurityConfig View 체인 /admin 이하 hasRole ADMIN가 일괄 커버(컨트롤러 권한 분기 금지).
- 레이아웃·모델 키 규약(메모리 주의):
  - 레이아웃은 layout/base layout(title, content)로 main 내용만 렌더한다. 인라인 script는 반드시 main 내부에 둔다(main 밖 script는 조용히 드롭, 정적 리뷰 사각지대, E2E만 잡음).
  - Thymeleaf 예약 모델 키(application/session/param/request) 금지 — 도메인 접두사 사용.
  - nav 링크: fragments/nav.html(role별 sec:authorize, active 비교 — admin 메뉴 블록·CONSUMER 메뉴 블록 존재).
- 인가 현황(SecurityConfig 코드 대조):
  - REST: /api/v1/coupons 이하 hasRole CONSUMER(line 130) — 쿠폰함/applicable이 이미 커버. /api/v1/admin 이하 hasRole ADMIN(line 122) — 신규 admin 조회 GET이 자동 커버.
  - View: /admin 이하 hasRole ADMIN(line 200) — admin 쿠폰 화면 커버. /checkout, /orders 이하 hasRole CONSUMER(line 212) — 체크아웃 커버. /coupons(쿠폰함 View) 경로는 미커버 → SecurityConfig View 체인에 matcher 신규 추가 필요.

## plan 확정 필요 (설계 결정 — 본 Task가 plan에 위임)
1. admin 목록/사용현황 조회를 REST로 노출할지 View 전용 facade로만 둘지: 041 선례(AdminCategoryFacade View 전용)와 043 admin 페이지 패턴을 대조. 사용자 합의 범위가 목록/사용현황 조회 REST(또는 View 컨트롤러용 조회 경로)를 소폭 신규 추가이므로 둘 중 하나를 plan에서 확정한다. api-authorization-rule 반영 — REST 추가 시 ADMIN·소유권 불필요 명시.
2. 쿠폰함 위치: 별도 페이지(GET /coupons → coupon/wallet)로 둘지 029 계정 화면에 통합할지. 029는 /account가 계정 self-service 전용이라 쿠폰함을 끼우면 책임이 섞인다 → (권장) 별도 페이지 + nav CONSUMER 메뉴에 쿠폰함 링크. plan 확정.
3. 체크아웃 쿠폰 선택 UI 부착 위치: 015 order/checkout.html의 결제 금액 섹션 위에 쿠폰 선택 영역을 두고, 배송지 폼(POST /orders) 안에 userCouponId 입력을 포함시켜 한 번의 제출로 적용. (적용가능 쿠폰 미리보기를 GET /checkout 서버사이드 렌더로 줄지, applicable ajax로 줄지 plan 확정 — 서버사이드 권장: 동일 itemsAmount 기준·E2E 안정.)
4. 체크아웃 적용가능 쿠폰을 어떻게 모델에 싣는지: OrderCheckoutResponse(현재 items/itemsAmount/discountAmount/shippingFee/finalAmount/hasItems)에 적용가능 쿠폰 리스트를 추가할지, 별도 모델 키로 분리할지. order 모듈은 이미 CouponService.getApplicable을 내부 호출 가능 → OrderFacade.getCheckout이 쿠폰 미리보기를 합성하거나 별도 facade 메서드로 분리. plan 확정(모듈 경계 신규 cross-module 의존 0 유지).
5. 화면 추가에 따른 신규 백엔드 최소화: admin 목록/사용현황 조회(read) 외에 비즈니스 로직 변경 없음(할인계산·소비·복원·동시성 무변경 — 회귀 금지). CouponRepository에 전체 목록 조회 메서드(예: findAllByOrderByEndsAtDesc) 1개 추가 정도로 한정. plan에서 정확 시그니처 확정.

## API Authorization
> docs/rules/api-authorization-rule.md 준수. 본 Task는 화면 진입점과 (신규) admin 조회만 추가하며, 적용/발급/조회 비즈니스 경로는 031에서 이미 인가·소유권이 확정됐다(무변경).

| API/경로 | 공개 여부 | 최소 권한 | 상위 권한 허용 | 소유권 검사 | 비고 |
|---|---|---|---|---|---|
| GET /admin/coupons (View, 신규) | authenticated | ROLE_ADMIN | — | 불필요(전체 정의) | 쿠폰 목록·사용현황 화면 |
| POST /admin/coupons (View, 신규) | authenticated | ROLE_ADMIN | — | 불필요 | 쿠폰 정의 생성 폼 제출 → createDefinition 재사용 |
| GET /api/v1/admin/coupons (REST, 신규 — plan 확정 시) | authenticated | ROLE_ADMIN | — | 불필요 | 쿠폰 목록·사용현황 조회(읽기 전용) |
| POST /api/v1/admin/coupons (REST, 031 기존) | authenticated | ROLE_ADMIN | — | 불필요 | 쿠폰 정의 생성 — 무변경 |
| GET /coupons (View, 신규) | authenticated | ROLE_CONSUMER | ROLE_SELLER,ROLE_ADMIN | principal 본인 | 내 쿠폰함 화면(미사용/사용/만료) |
| POST /coupons/claim (View, 신규) | authenticated | ROLE_CONSUMER | ROLE_SELLER,ROLE_ADMIN | principal 본인 | 코드 발급 폼 제출 → claim 재사용 |
| GET /checkout (View, 015 기존) | authenticated | ROLE_CONSUMER | ROLE_SELLER,ROLE_ADMIN | principal 본인 | 체크아웃 — 적용가능 쿠폰 표기 추가 |
| POST /orders (View, 015 기존) | authenticated | ROLE_CONSUMER | ROLE_SELLER,ROLE_ADMIN | principal 본인 | 주문 생성 — userCouponId 실제 전달 |
| GET /api/v1/coupons, POST /api/v1/coupons, GET /api/v1/coupons/applicable (031 기존) | authenticated | ROLE_CONSUMER | — | principal 본인 | 무변경 |

> 소유권은 모두 principal에서만 도출(031 계승 — IDOR 차단). View JWT 쿠키 인증(054 cutover — viewJwtAuthenticationFilter의 emailPrincipalFactory가 principal getName()=email 세팅, STATELESS) principal=email → facade에서 email→userId 해석(015/029 CurrentActorResolver/MemberDirectory 선례, 데이터 흐름 동일). admin 화면은 전체 쿠폰 정의 대상이라 소유권 무관(전체 조회, ADMIN 전용).
> SecurityConfig 변경: View 체인에 /coupons, /coupons 이하 hasRole CONSUMER matcher 신규 추가(/checkout 인접). 나머지 경로는 기존 /admin, /api/v1/admin, /api/v1/coupons, /checkout이 이미 커버(무변경).

## Requirements
### A. ADMIN 쿠폰 관리 화면 (/admin/coupons)
- 목록(GET /admin/coupons): 전체 쿠폰 정의를 표로 렌더. 컬럼: 코드, 이름, 할인(타입 fixed/percent + value, percent는 max_discount 병기), 최소주문금액, 유효기간(startsAt~endsAt, KST 표현 — ADR-009), 사용현황 usedCount / usageLimit(usageLimit null이면 무제한), 활성여부(isActive). 빈 목록 안내 메시지. 정렬은 plan 확정(권장: endsAt desc 또는 id desc).
- 생성(POST /admin/coupons): 등록 폼(코드/이름/할인타입(fixed 또는 percent 셀렉트)/value/minOrderAmount/maxDiscount(percent 시)/startsAt/endsAt/usageLimit(빈값=무제한)/isActive). 검증 실패 시 폼 에러 재렌더(목록 재조회), 성공 시 flashSuccess + redirect:/admin/coupons(041 PRG 패턴 동일). 백엔드는 031 createDefinition 재사용 — code 중복 409(DuplicateCouponCodeException), value 음수/0, endsAt이 startsAt 이하, discountType 오류는 기존 검증/예외 흐름 그대로 flashError 또는 폼 에러로 표기.
- 신규 백엔드(조회 최소): admin 목록/사용현황을 위한 조회 경로(View facade AdminCouponFacade.list() 또는 GET /api/v1/admin/coupons)와 CouponRepository 전체 목록 조회 메서드 1개. 읽기 전용. 비즈니스 로직·할인·소비·복원 무변경.
- nav admin 메뉴 블록에 쿠폰 관리 링크 추가(sec:authorize hasRole ADMIN, active=admin-coupons).

### B. 사용자 쿠폰함 화면 (/coupons)
- 조회(GET /coupons): 본인 보유 쿠폰을 미사용/사용/만료 구분으로 표시(031 getMyCoupons의 used/usedAt/expired 플래그 사용). 코드/이름/할인/유효기간/상태 배지. 빈 목록 안내. 모델 키는 예약어 회피(예: couponWallet — request/param 등 금지).
- 발급(POST /coupons/claim): 코드 입력 폼 1개. 성공 시 flashSuccess + redirect:/coupons, 실패(404 미존재/400 비활성·기간외/409 중복보유) 시 flashError + redirect(031 예외 메시지 그대로 노출 — error-response 규칙상 View는 flash). 백엔드는 031 claim 재사용.
- nav CONSUMER 메뉴 블록에 쿠폰함 링크 추가(sec:authorize hasRole CONSUMER, active=coupons).

### C. 체크아웃 쿠폰 적용 (/checkout + POST /orders)
- GET /checkout: 현재 장바구니 기준 적용 가능 보유 쿠폰을 표기(031 getApplicable: applicable=true 쿠폰별 expectedDiscount, applicable=false 쿠폰은 reason). 쿠폰 선택 UI(라디오/셀렉트 — 쿠폰 미적용 기본 + 적용가능 쿠폰 목록)를 결제 금액 섹션과 함께 배치. 적용 불가 쿠폰은 사유와 함께 비활성 표기(선택 불가).
- POST /orders: 배송지 폼 안에 userCouponId(선택, 빈값=미적용) 포함. OrderViewController.createOrder가 폼의 userCouponId를 OrderCreateRequest의 6번째 인자로 전달(현재 null 고정 → 실제 값). 서버는 031 OrderService.createOrderTx의 검증·할인계산·소비를 그대로 수행(무변경). 적용 거부(400/409) 시 기존 BusinessException → flashError + redirect:/checkout(015 흐름 동일).
- 예상 할인 표기: GET /checkout 렌더 시 적용가능 쿠폰의 expectedDiscount를 화면에 표시(서버사이드 렌더 권장 — itemsAmount 동일 기준). 사용자가 쿠폰 선택을 바꿔도 최종 할인은 주문 생성 시 서버 계산이 권위(화면 표기는 안내용).
- 회귀 금지: userCouponId 미선택(빈값/null) 시 015/031 기존 흐름과 바이트 단위 동일(discount=0). 쿠폰 미적용 주문 회귀 0.

### D. 공통
- 레이어: View는 @Controller(web) → spi facade → Service. web이 order/coupon 내부 domain/repository/비공개 service·Entity 직접 참조 금지(015/029/041 계승). Entity를 View 모델에 직접 전달 금지(DTO/record만).
- 모든 폼 CSRF 자동(_csrf 수동 주입 금지). 인라인 script 사용 시 main 내부.
- KST 표현(ADR-009): 유효기간·발급/사용 시각은 KST로 표현(저장은 Instant).

## Constraints
- 031 비즈니스 로직 무변경(회귀 금지): 할인 계산(Coupon.calculateDiscount), 쿠폰 소비(consume/조건부 UPDATE), 복원(restoreByOrder), 동시성(1인1매 UNIQUE/1회용/총 한도), 주문 적용 흐름(createOrderTx)은 손대지 않는다. 본 Task는 화면 + 조회 read만 추가한다.
- 신규 백엔드 최소: admin 목록/사용현황 조회(read) + CouponRepository 목록 메서드 1개 + (선택) View facade·REST 1개. 그 외 신규 서비스 비즈니스 로직 금지.
- 스키마/이벤트/notification 무변경: coupons/user_coupons V1 그대로, 신규 마이그레이션 없음. event-catalog.md/§5 불변, notification 미참조(031과 동일).
- 모듈 경계: 쿠폰은 order 모듈 내부(031 결정). 신규 cross-module 의존 0(admin facade·View facade는 order.spi published port로 노출, 구현은 order/service). ModularityTests/ArchUnit 그린 유지.
- 인가: admin 화면/REST는 ADMIN(컨트롤러 권한 분기 금지 — SecurityConfig 일괄). 쿠폰함/체크아웃은 CONSUMER + principal 본인(IDOR 차단). View /coupons matcher 추가 외 SecurityConfig 변경 최소.
- 수정/삭제/비활성/회원 직접발급 범위 밖: admin은 생성+목록+사용현황 조회만. 후속 Task로 분리.
- Entity 비노출·민감정보 비표기: 화면/응답에 Entity·불필요 내부 식별자 노출 금지. admin 목록은 정의 정보만(쿠폰 보유 회원 명단·PII 비표기).

## Files
> 정확 경로/시그니처/모델 키는 plan 확정. 아래는 선례 대조 기준 예시.
### 신규 (view-implementor)
- web/coupon/CouponViewController.java — GET /coupons(쿠폰함), POST /coupons/claim(발급). CouponFacade(order.spi) 경유, CurrentActorResolver로 email 해석(015/029 선례).
- web/coupon/AdminCouponViewController.java — GET /admin/coupons(목록+폼), POST /admin/coupons(생성). AdminCouponFacade(order.spi) 경유(041 AdminCategoryViewController 패턴).
- web/coupon/CouponClaimForm.java, web/coupon/AdminCouponCreateForm.java — 폼 backing object(검증 어노테이션, Entity 미바인딩).
- templates/coupon/wallet.html — 쿠폰함(보유 목록 + 발급 폼).
- templates/admin/coupons.html — admin 목록(사용현황) + 등록 폼(admin/categories.html 톤).
- (수정) order/checkout.html — 결제 금액 섹션에 적용가능 쿠폰 선택 UI + 예상 할인 표기 추가, 배송지 폼에 userCouponId 입력 포함.
- (수정) fragments/nav.html — admin 쿠폰 관리·CONSUMER 쿠폰함 링크 추가.

### 신규/수정 (backend-implementor)
- order/spi/CouponFacade.java(신규, View 전용) — getMyWallet(email), claim(email, code) 등 쿠폰함 facade. 구현체 order/service/CouponFacadeImpl.java(또는 기존 서비스 위임).
- order/spi/AdminCouponFacade.java(신규, View 전용) — list()(목록·사용현황), create(...)(031 createDefinition 위임). 구현체 order/service.
- (수정) order/repository/CouponRepository.java — 전체 목록 조회 메서드 1개(예: List Coupon findAllByOrderByEndsAtDesc()) 추가. 읽기 전용.
- (수정) order/spi/OrderFacade.java + 구현 — getCheckout(email)가 적용가능 쿠폰 미리보기를 합성(또는 별도 facade 메서드). OrderCheckoutResponse에 적용가능 쿠폰 필드 추가 또는 별도 응답(plan 확정 — 모델 키 분리 가능).
- (수정) web/order/OrderViewController.java — createOrder가 OrderCreateForm.userCouponId를 OrderCreateRequest 6번째 인자로 전달(현재 null 고정 제거). GET /checkout 모델에 적용가능 쿠폰 추가.
- (수정) web/order/OrderCreateForm.java — userCouponId(Long, 선택) 필드 추가.
- (수정, plan 확정 시) order/controller/AdminCouponRestController.java — GET /api/v1/admin/coupons(목록·사용현황) 추가 + CouponServiceResponse에 조회 메서드.
- (수정) security/SecurityConfig.java — View 체인에 /coupons, /coupons 이하 hasRole CONSUMER matcher 추가(/checkout 인접). 나머지 무변경.

### 무변경(재사용)
CouponService(claim/getMyCoupons/getApplicable/createDefinition/computeDiscount/consume/restoreByOrder), CouponServiceResponse, CouponDtoMapper, CouponRestController, Coupon/UserCoupon/UserCouponRepository, OrderService.createOrderTx(쿠폰 적용 로직), OrderCancellationImpl.doCancel(복원), V1~최신 마이그레이션, event-catalog.md/§5, notification 전부, CartCheckoutReader/ProductOrderCatalog.

## Backend - View Contract
| 항목 | 값 |
|---|---|
| 쿠폰함 화면 | GET /coupons → view coupon/wallet, 모델 키 couponWallet(보유 쿠폰 목록 DTO), couponClaimForm |
| 쿠폰 발급 제출 | POST /coupons/claim → 성공 redirect /coupons + flashSuccess, 실패 flashError + redirect /coupons |
| admin 쿠폰 화면 | GET /admin/coupons → view admin/coupons, 모델 키 coupons(정의·사용현황 목록 DTO), couponForm |
| admin 쿠폰 생성 제출 | POST /admin/coupons → 검증실패 재렌더, 성공 redirect /admin/coupons + flashSuccess |
| 체크아웃 적용가능 쿠폰 | GET /checkout 모델 키 applicableCoupons(applicable/expectedDiscount/reason) — checkout 모델 키와 공존 |
| 주문 생성 쿠폰 전달 | POST /orders 폼 필드 userCouponId(선택) → OrderCreateRequest.userCouponId |
| Flash 키 | flashSuccess / flashError(기존 messages fragment) |
| nav | admin 쿠폰 관리(/admin/coupons, active=admin-coupons), CONSUMER 쿠폰함(/coupons, active=coupons) |

## Acceptance Criteria
- ADMIN이 /admin/coupons에서 전체 쿠폰 정의를 사용현황(usedCount/usageLimit, 무제한 표기)·활성여부와 함께 목록으로 보고, 등록 폼으로 쿠폰을 생성하면 목록에 반영된다(중복 코드는 거부 메시지). 비ADMIN은 접근 차단(403/redirect).
- CONSUMER가 /coupons에서 본인 쿠폰을 미사용/사용/만료 구분으로 조회하고, 코드 입력으로 발급받으면 쿠폰함에 추가된다(미존재/중복보유/기간외는 사유 메시지). 타인 쿠폰은 보이지 않는다.
- /checkout에서 현재 장바구니에 적용 가능한 보유 쿠폰과 예상 할인액이 표기되고, 적용 불가 쿠폰은 사유와 함께 선택 불가로 표시된다. 쿠폰을 선택해 주문하면 Order.discountAmount/finalAmount가 031 계산대로 반영된다(결제/환불 금액이 할인된 finalAmount 추종 — 무변경).
- 쿠폰 미선택 시 주문 생성이 015/031 기존 흐름과 동일하다(discount=0, 회귀 0).
- 031 비즈니스 로직(할인·소비·복원·동시성)·스키마·이벤트·notification이 무변경이다. ModularityTests/ArchUnit·풀 스위트 그린.

## Test
> testing-rule + verification-gate-rule. 목록 페이지 조건부 버튼/폼·체크아웃 쿠폰 선택은 MockMvc·통합으로 쿼리와 템플릿 가시성 공백을 못 잡으므로 반드시 브라우저 E2E(e2e-runner)로 검증. 인라인 script가 main 밖이면 무동작·콘솔에러 없음으로 정적 리뷰가 못 잡으므로 E2E로.
- 단위/슬라이스(Mockito): 신규 facade(CouponFacade/AdminCouponFacade)가 email→userId 해석·서비스 위임만 하고 Entity 미노출. CouponRepository 목록 메서드 정렬. View 컨트롤러 핸들러 분기(검증 실패 재렌더/성공 PRG/BusinessException flashError).
- View 렌더링(MockMvc/슬라이스): GET /coupons, GET /admin/coupons, GET /checkout 렌더(모델 키·DTO, Entity 비노출), 폼 CSRF 포함, 발급/생성 성공 redirect + flash. POST /orders에 userCouponId 바인딩 → OrderCreateRequest 6번째 인자 전달 검증.
- Security/REST(MockMvc): /admin/coupons(View), /api/v1/admin/coupons(GET, 추가 시) ADMIN 200 / CONSUMER 403 / 비로그인 401·redirect. /coupons(View) CONSUMER 200 / 비로그인 redirect. 031의 /api/v1/coupons 이하·주문 경로 인가 회귀 그린.
- 브라우저 E2E(e2e-runner, 필수):
  - ADMIN 로그인 → /admin/coupons → 쿠폰 등록(목록·사용현황 반영) → 중복 코드 거부 메시지. 비ADMIN 차단.
  - CONSUMER 로그인 → /coupons 발급(목록 반영, 미사용 배지) → 중복 발급 거부 메시지 → 만료/사용 구분 표기.
  - CONSUMER 장바구니 담기 → /checkout에서 적용가능 쿠폰 선택(예상 할인 표기) → 주문 생성 → 주문 상세 discountAmount/finalAmount가 할인 반영. 적용 불가 쿠폰 선택 불가. 쿠폰 미선택 주문은 할인 0.
- 회귀: 015/029/031/041 관련 화면·REST 그린 유지. 쿠폰 미적용 주문 생성·결제·취소 회귀 0. 메인 에이전트가 gradlew test 풀 그린 + Modulith verify를 자기 눈으로 확인(verification-gate-rule).

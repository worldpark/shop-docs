# Task 032 — shop-core 상품 리뷰: 실구매 검증 작성·조회·수정·삭제 + 평점 집계 (with View) plan

> 범위 SSOT: docs/tasks/backend/032-backend-shop-core-product-review-purchase-verified-with-view.md
> 대상: shop-core (review 컴포넌트 = product 모듈 호스팅 + order 모듈 adapter + web). 구현자: backend-implementor → view-implementor.
> 본 plan은 Task가 위임한 6개 설계 결정을 코드 대조로 확정한다(§plan 결정).
> 패키지 루트: com.shop.shop (코드 대조 — com.shop 아님). DB는 reviews V1 그대로 사용(무변경, 마이그레이션 없음 — 현재 최신 V6).
> 이벤트/notification 무변경. 6개 도메인 모듈 고정(신규 review 모듈 금지).

## 구현 목표
구매를 완료(배송 완료, delivered)한 로그인 사용자가 본인이 산 상품에 대해 평점(1~5)+내용으로 리뷰를 작성하고, 본인 리뷰를 수정·삭제할 수 있다. 리뷰는 order_item 단위로 실구매를 검증(본인 소유 주문 항목 + 주문 delivered)하며, order_items UNIQUE로 구매 1건당 1리뷰를 보장한다. 상품 상세 화면·공개 API는 해당 상품의 리뷰 목록 + 평균 평점·리뷰 수를 누구나 조회한다. REST API + Thymeleaf 화면을 제공한다.

---

## §plan 결정 (Task가 위임한 6개 설계 결정 — 확정)

| # | 결정 항목 | 확정 | 근거 |
|---|---|---|---|
| 1 | 모듈 배치 / SPI 방향 | product 모듈 호스팅 + product/spi/PurchaseVerificationPort(product 소유·소비) ← order/adapter/OrderPurchaseVerificationAdapter(order 구현). | 리뷰는 상품 상세에 표시(읽기 응집은 product). 기존 의존 방향 order → product.spi가 정립(ProductOrderCatalog/ProductPurchaseCatalog/UserDirectory 모두 product 소유, order/member adapter 구현). 호스팅(product)이 포트를 소비하고 상대(order)가 구현 → product → order 역의존 0(ModularityTests 위반 회피). order는 이미 product.spi를 의존하므로 신규 cross-module 의존 방향 0. |
| 2 | 구매 완료 기준 상태 | 주문 레벨 delivered 단일 기준. | Task 021에서 주문 status가 delivered로 rollup(Order.markDelivered). 배송 완료 후 후기가 의미 정합. 부분 배송(shipment 단위) 미채택(과설계). 대안 paid 미채택(미배송 후기 방지). |
| 3 | product_id 도출 + variant null 엣지 | order_item.variant_id → product_variants.product_id 서버 도출(바디로 product_id 미수신 — 위조 차단). variant_id null(옵션 삭제)이면 거부 400. | OrderItem.variantId는 nullable(ON DELETE SET NULL, OrderItem.java line 50). 도출 불가 시 reviews.product_id NOT NULL 불충족. error-response-rule 매핑표에 410 없음 → 400 사용. |
| 4 | 수정·삭제 범위 / 삭제 방식 | 본인 리뷰 수정(rating/content)·삭제 포함, 물리 삭제. | 물리 삭제로 order_item_id UNIQUE를 비워 재작성 허용. reviews에 deleted_at 없음(V1) → 소프트 삭제는 스키마 변경 = 과설계, 미채택. |
| 5 | 평점 집계 + 반올림 | AVG(rating)/COUNT(*) 쿼리 집계, 캐시 컬럼 미도입. 평균은 소수 1자리 HALF_UP. 0건이면 average=null·count=0. 상품 상세에만 노출(카탈로그 목록 평균 범위 밖). | 캐시 컬럼은 스키마 변경+동기화 복잡도. reviews (product_id) 인덱스 존재(database_design line 597). 반올림은 서비스 DTO 조립에서. |
| 6 | View 진입 / content 상한 / 페이징 / 표시명 | GET /reviews/new?orderItemId= 제공 + 상품 상세는 목록·평균만(작성 진입 링크 최소). content 1000자(@Size). 목록 최신순(createdAt DESC, id DESC) size 10. 작성자 표시명은 이메일 로컬파트 마스킹(ab***) — email/전화 비노출. 표시명 조회는 **product 소유 신규 포트 ReviewerDirectory** (IN 배치, member adapter 구현, 마스킹은 member 측)로 수행한다(§2.6). | 주문 내역 진입 통합은 별 Task. content는 text이나 앱 상한. 코드 대조 결과 member.spi에는 마스킹/표시명 배치 포트가 없고 `MemberDirectory.findContactByUserId`는 단건(email 원문 반환 — 목록 N+1·PII 노출). 재사용 불가 → 신규 포트 불가피. 기존 `UserDirectory`/`ProductOrderCatalog`와 동일한 의존 역전(member → product.spi 구현) → product → member 신규 의존 없음(ModularityTests 무파급). |

---

## 영향 범위

### 신규 파일 (product 모듈 — 호스팅)
- product/domain/Review.java — reviews 매핑 Entity(BaseEntity 상속), create(...)/edit(rating, content), rating 1~5 검증.
- product/repository/ReviewRepository.java — findByProductId(페이징), findByIdAndUserId(소유), 집계(avgRating/countByProductId), existsByOrderItemId(선검사 보조).
- product/service/ReviewService.java (내부 결과 record 포함) — 작성/수정/삭제/목록·집계 도메인 로직.
- product/service/ReviewServiceResponse.java — REST 응답 조합 전용(@Service).
- product/service/ReviewDtoMapper.java — 내부 결과 record → DTO 변환(@Component, package-private).
- product/service/ReviewFacadeImpl.java — ReviewFacade 구현(package-private, View 전용 + email→userId 해석).
- product/spi/PurchaseVerificationPort.java — order_item 소유·상태·variant→product 검증 read 포트(product 소유, @NamedInterface "spi").
- product/spi/ReviewerDirectory.java — 작성자 표시명(마스킹) 배치 조회 포트(product 소유, @NamedInterface "spi"). `Map<Long,String> maskedDisplayNamesByUserId(Collection<Long>)`(IN 배치). member adapter가 구현, 마스킹은 member 측(§2.6).
- product/spi/ReviewFacade.java — web용 표시 DTO(scalar) + 작성/수정/삭제 처리(published port).
- product/controller/ReviewRestController.java — POST /api/v1/reviews, PATCH/DELETE /api/v1/reviews/{id}, GET /api/v1/products/{productId}/reviews.
- product/dto/ReviewCreateRequest.java — (Long orderItemId, Integer rating, String content) + Bean Validation.
- product/dto/ReviewUpdateRequest.java — (Integer rating, String content).
- product/dto/ReviewResponse.java — 단건/목록 행(작성자 마스킹 표시명·평점·내용·작성일).
- product/dto/ProductReviewSummaryResponse.java — (Double averageRating, long reviewCount, page 메타, List<ReviewResponse> reviews).
- web/review/ReviewViewController.java — GET /reviews/new, POST /reviews, POST /reviews/{id}/edit, POST /reviews/{id}/delete.
- web/review/ReviewForm.java — 폼 백킹 객체(orderItemId·rating·content + 수정용 reviewId).
- (신규 예외, common/exception — 모두 BusinessException 상속)
  - ReviewNotFoundException (404 — 미존재/타인 리뷰 존재 은닉)
  - ReviewTargetNotFoundException (404 — 미존재/타인 order_item 존재 은닉)
  - ReviewNotPurchasedException (400 — 미배송: delivered 아님)
  - ReviewableProductMissingException (400 — variant null로 product_id 도출 불가)
  - DuplicateReviewException (409 — order_item_id UNIQUE: 구매 1건당 1리뷰)
- (템플릿) src/main/resources/templates/review/form.html + 상품 상세 fragment(§2.7).
- (테스트) §5에 열거.

### 신규 파일 (order 모듈 — adapter)
- order/adapter/OrderPurchaseVerificationAdapter.java — product.spi.PurchaseVerificationPort 구현(order_item 소유·status 조회 + product.spi.ProductOrderCatalog로 variant→productId 해석).
- order/adapter/package-info.java — Spring Modulith 인식용(없으면 생성).

### 신규 파일 (member 모듈 — adapter)
- member/adapter/MemberReviewerDirectoryAdapter.java — product.spi.ReviewerDirectory 구현(@Component, MemberUserDirectoryAdapter 선례 동형). userId 집합 IN 배치 조회 후 email 로컬파트 마스킹(앞 2자 + ***)하여 `Map<Long,String>` 반환 — email 원문 product 비노출. 의존 방향: member → product.spi 단방향(기존과 동일).

### 수정 파일
- security/SecurityConfig.java — REST/View 체인에 리뷰 matcher 추가(§3.7).
  - REST: GET /api/v1/products/*/reviews permitAll(공개), /api/v1/reviews/** hasRole("CONSUMER").
  - View: GET /products/* 이미 permitAll(상세 — 무변경), /reviews/** hasRole("CONSUMER").
- 상품 상세 View(013 PublicProductViewController.getProductDetail + templates/product/detail.html) — 리뷰 목록·평균·리뷰 수 모델 주입 + fragment 삽입.
  - 모델 키: productReviews(목록/페이지), reviewSummary(평균·개수) — Thymeleaf 예약어(request/param/application/session) 회피(MEMORY).
- (선택) docs/entity/database_design.md — 리뷰 작성/실구매 검증 라이프사이클 의도 보강(스키마 무변경).

### 무변경(재사용)
order_item/order Entity·Repository(adapter가 모듈 내부에서만 접근), ProductOrderCatalog(variant→productId 재사용), UserDirectory(email→userId), member.spi(기존 포트 무변경 — 표시명은 신규 ReviewerDirectory 사용이라 member.spi 재사용 아님, §2.6), RestExceptionHandler/ViewExceptionHandler, BaseEntity, event-catalog.md/§5, notification 전부, V1~V6 마이그레이션(V7 만들지 않음).

---

## 1. 설계 방식 및 이유

### 1.1 모듈 배치 = product 호스팅 + 의존 역전(결정 1)
리뷰 컴포넌트(domain/repository/service/controller/dto/facade)를 전부 product 모듈 내부에 둔다. 리뷰의 1차 노출 지점이 상품 상세이고, 평균 평점·목록 조회가 product의 읽기 책임에 응집한다.

작성 시 필요한 실구매 검증 데이터(order_item 소유·주문 status)는 order 모듈 소유다. product가 직접 참조하면 product → order 역의존이 생겨 ModularityTests를 위반한다. 그래서 포트 의존 역전을 적용한다:
- product/spi/PurchaseVerificationPort (product가 인터페이스 소유·소비) — @NamedInterface("spi").
- order/adapter/OrderPurchaseVerificationAdapter (order가 구현) — order_item·order를 자기 모듈 내부에서 읽고, variant→productId는 이미 보유한 product.spi.ProductOrderCatalog 의존으로 해석.

의존 방향은 order → product.spi 단방향(기존 ProductOrderCatalog/ProductPurchaseCatalog/UserDirectory와 동일 패턴). product는 order를 전혀 참조하지 않는다. ArchUnit/Modulith 무파급.

> variant→productId 해석: order adapter가 ProductOrderCatalog.getOrderableSnapshots(List.of(variantId))로 productId를 얻는다(snapshot.productId()). variant 삭제로 order_item.variantId == null이거나 snapshot이 비면 도출 불가 → 포트가 productId 없음을 신호(§1.4 record)하고 product 서비스가 400으로 변환.

### 1.2 Entity는 BaseEntity 상속(쿠폰과 상반)
reviews는 created_at/updated_at + trg_reviews_set_updated_at 트리거가 있다(database_design §4.6, line 563). 따라서 Review는 BaseEntity를 상속한다(시간 컬럼은 DB 소유 읽기전용, insertable=false/updatable=false). Order 선례와 동일(Order.java line 34). 031 쿠폰 Entity는 시간 컬럼이 없어 미상속 — 혼동 금지(ADR-007 validate 정합).

### 1.3 실구매 검증 = order 데이터 단일 출처(결정 2)
"구매 완료"는 주문 status == delivered. 작성 시 검증 순서:
1. order_item 소유: order_item.order.userId == principal. 위반/미존재 → 404 존재 은닉(ReviewTargetNotFoundException).
2. 주문 status == delivered. 미달 → 400(ReviewNotPurchasedException).
3. product_id 도출(variant→product). 불가 → 400(ReviewableProductMissingException).

1~3은 PurchaseVerificationPort.verify(orderItemId, userId) 한 번에 위임(order adapter가 order_item + order status 조회, ProductOrderCatalog로 productId 해석). 포트는 통과 시 productId 반환, 단계별 실패를 record로 신호(§1.4).

### 1.4 PurchaseVerificationPort 반환 계약
포트는 product 소유이므로 product 예외를 시그니처에 강제하지 않는다. 결합 최소화를 위해 결과 record 반환:
- (채택) PurchaseVerification verify(long orderItemId, long userId) → record PurchaseVerification(boolean ownedAndExists, boolean delivered, Long productId). product의 ReviewService가 record를 보고 예외(404/400)를 던진다. order adapter는 product 예외를 모름.
- (대안, 미채택) 포트가 직접 product 예외를 던짐 → order adapter가 product.common 예외 의존. 결합 증가.

> IDOR 보장: ownedAndExists=false는 "미존재"와 "타인 소유"를 구분하지 않는다(둘 다 false). product 서비스는 false → 404 단일 변환. 존재 은닉 유지.

### 1.5 중복 작성 방어 = order_item_id UNIQUE(쿠폰 선례)
uq_reviews_order_item_id(order_item_id NOT NULL UNIQUE)가 SSOT. 선검사 existsByOrderItemId는 메시지용 best-effort, 409 변환 SSOT는 DataIntegrityViolationException catch(TOCTOU 경합도 UNIQUE 최종 차단 — CouponService.claim line 78~84 동형) → DuplicateReviewException(409).

### 1.6 수정·삭제 = 본인 한정·물리 삭제(결정 4)
- 수정: findByIdAndUserId(reviewId, userId) empty → 404(ReviewNotFoundException, 존재 은닉). Review.edit(rating, content)만 호출 — productId/userId/orderItemId/createdAt 불변, updatedAt 트리거 갱신.
- 삭제: empty → 404. 물리 delete. 삭제 후 같은 order_item 재작성 허용(UNIQUE 해제).

### 1.7 평점 집계 = 쿼리 집계·1자리 반올림(결정 5)
ReviewRepository avg/count 집계. 서비스가 BigDecimal.setScale(1, HALF_UP) → Double 정규화(0건 average=null·count=0). 캐시 컬럼 미도입. 상품 상세에만 노출(회귀 0).

### 1.8 마이그레이션 불필요(V7 만들지 않음)
reviews는 V1 완비(컬럼·CHECK·UNIQUE·트리거·(product_id)/(user_id) 인덱스). 스키마 무변경. 최신 V6 유지.

---

## 2. 구성 요소

### 2.1 도메인 — product/domain/Review.java
- 매핑: @Entity @Table(name="reviews"), extends BaseEntity, @NoArgsConstructor(PROTECTED), @Getter, Setter 금지.
- 필드(스칼라 — Product/User/OrderItem Entity 직접 참조 금지, Long 보유): Long id(IDENTITY), Long productId, Long userId, Long orderItemId, int rating, String content(nullable). createdAt/updatedAt은 BaseEntity 상속(읽기전용).
- create(long productId, long userId, long orderItemId, int rating, String content): rating 1~5 검증(위반 시 IllegalStateException — 서비스 사전 검증, 방어적·CHECK 정합).
- edit(int rating, String content): rating 재검증 후 rating/content만 변경(dirty checking).

### 2.2 리포지토리 — product/repository/ReviewRepository
extends JpaRepository<Review, Long>:
- Page<Review> findByProductIdOrderByCreatedAtDescIdDesc(long productId, Pageable pageable) — 목록(최신순).
- Optional<Review> findByIdAndUserId(long id, long userId) — 수정/삭제 소유(미존재/타인 → empty → 404).
- boolean existsByOrderItemId(long orderItemId) — 선검사 보조.
- 집계: @Query("select avg(r.rating) from Review r where r.productId = :pid") Double avgRatingByProductId(@Param("pid") long pid) + long countByProductId(long productId). (또는 단일 projection avg+count — 구현자 재량.)

### 2.3 서비스 — product/service/ReviewService (@Service)
의존: ReviewRepository, PurchaseVerificationPort(자기 모듈 spi), ReviewerDirectory(자기 모듈 spi — 표시명 마스킹, §2.6), ReviewDtoMapper.
- @Transactional ReviewResult create(long userId, long orderItemId, int rating, String content):
  1. PurchaseVerification v = purchaseVerificationPort.verify(orderItemId, userId).
  2. !v.ownedAndExists() → ReviewTargetNotFoundException(404).
  3. !v.delivered() → ReviewNotPurchasedException(400).
  4. v.productId() == null → ReviewableProductMissingException(400).
  5. (선검사) existsByOrderItemId(orderItemId) → DuplicateReviewException(409, best-effort).
  6. save(Review.create(v.productId(), userId, orderItemId, rating, content)) → DataIntegrityViolationException catch → DuplicateReviewException(409, SSOT).
  7. log.info("리뷰 작성: userId={}, reviewId={}, productId={}", ...)(민감정보 금지).
- @Transactional ReviewResult edit(long userId, long reviewId, int rating, String content): findByIdAndUserId empty → ReviewNotFoundException(404). review.edit(rating, content). 로깅.
- @Transactional void delete(long userId, long reviewId): findByIdAndUserId empty → 404. delete. 로깅.
- @Transactional(readOnly=true) ReviewSummaryResult getProductReviews(long productId, int page, int size): 페이지 조회 + avgRating + count, 평균 1자리 반올림(0건 null), 행별 작성자 마스킹 표시명(§2.6). 공개 — 비로그인 가능.
- 내부 결과 record: ReviewResult, ReviewRow, ReviewSummaryResult(Double averageRating, long reviewCount, int page, int size, long totalElements, int totalPages, List<ReviewRow> rows). Entity 미노출.

### 2.4 ServiceResponse — product/service/ReviewServiceResponse (@Service)
REST 응답 조합 전용(architecture-rule: REST에서만):
- ReviewResponse create(Authentication auth, ReviewCreateRequest req) — userId=(long)auth.getPrincipal().
- ReviewResponse update(Authentication auth, long reviewId, ReviewUpdateRequest req).
- void delete(Authentication auth, long reviewId).
- ProductReviewSummaryResponse getProductReviews(long productId, int page, int size) — 공개(auth 무관).

### 2.5 컨트롤러 — product/controller/ReviewRestController (@RestController)
- POST /api/v1/reviews → 201, @Valid ReviewCreateRequest → ReviewResponse.
- PATCH /api/v1/reviews/{id} → 200, @Valid ReviewUpdateRequest → ReviewResponse.
- DELETE /api/v1/reviews/{id} → 204.
- GET /api/v1/products/{productId}/reviews?page&size → 200, ProductReviewSummaryResponse(공개).
- 비즈니스 로직 없음 — ReviewServiceResponse 위임. principal은 Authentication.

### 2.6 작성자 표시명 마스킹(결정 6 — product 소유 신규 포트 ReviewerDirectory)
응답에 작성자 식별용 표시명 필요하나 email/전화 비노출 원칙.

코드 대조 결과: member.spi에는 표시명/마스킹용 포트가 없다. 유일한 회원 연락처 조회인 `MemberDirectory.findContactByUserId(long)`는 **단건 시그니처**이고 **email 원문(MemberContact.email)을 그대로 반환**한다(member/spi/MemberDirectory.java line 43·51). 이를 리뷰 목록에 쓰면 (a) 행당 조회 N+1, (b) email 원문이 product로 노출되어 마스킹 책임이 product로 새는 문제가 있다. 따라서 **재사용 불가 — 신규 포트가 불가피**하다.

- (채택) product 소유 신규 포트 `product/spi/ReviewerDirectory` 신설 — 기존 `UserDirectory`/`ProductOrderCatalog`와 동일한 의존 역전(member → product.spi 구현, product → member 신규 의존 없음).
  - 시그니처: `Map<Long, String> maskedDisplayNamesByUserId(Collection<Long> userIds)` — **IN 배치 1회**(행당 조회·N+1 금지). 결과 맵에 없는 userId는 호출측에서 기본 표시명("탈퇴회원" 등)으로 폴백.
  - 구현: `member/adapter/MemberReviewerDirectoryAdapter`(@Component, MemberUserDirectoryAdapter 선례 동형)가 구현한다. **마스킹(email 로컬파트 앞 2자 + ***)은 member 측 adapter에서 수행**한다 — email 원문은 product로 절대 넘기지 않는다(개인정보 비노출, 마스킹 책임이 회원 소유 모듈에 응집).
  - userId 조회는 member 내부 배치 조회 사용(MemberService에 배치 조회가 없으면 member 내부에서 IN 조회 보강 — member 모듈 내부 변경, 경계 무위반).
- (대안, 미채택) member.spi 단건 포트 재사용 → 위 N+1·PII 노출로 불가. user_id만 노출 → UX 빈약. users에 실명/닉네임 컬럼 없음 → 마스킹 email이 현실적.

> 표시명 조회는 목록 userId 집합으로 1회(IN) — 행당 조회 금지. product는 마스킹 완료된 표시명 문자열만 수신한다.

### 2.7 View — web/review/ReviewViewController (@Controller) + 상품 상세 확장
- 의존: ReviewFacade(product.spi) + web.support의 Authentication → email 보조. web은 review/product 내부 Service·Entity 직접 참조 금지.
- GET /reviews/new?orderItemId= → ReviewForm(빈 폼) + view review/form.
- POST /reviews → reviewFacade.create(email, orderItemId, rating, content) → 성공 PRG redirect /products/{productId}?review + flash. 실패(BindingResult/BusinessException) → 폼 재렌더(입력 보존).
- POST /reviews/{id}/edit → reviewFacade.edit(email, id, rating, content) → redirect /products/{productId}?review.
- POST /reviews/{id}/delete → reviewFacade.delete(email, id) → redirect /products/{productId}.
- 상품 상세(PublicProductViewController.getProductDetail): reviewFacade.getProductReviews(productId, page, size) 결과를 모델 키 productReviews(목록/페이지) + reviewSummary(평균·개수)로 주입. templates/product/detail.html에 리뷰 fragment 삽입.
  - 주의(MEMORY): 모델 키 request/param/application/session 금지 — productReviews/reviewSummary/reviewForm 도메인 접두사.

### 2.8 facade — product/spi/ReviewFacade + product/service/ReviewFacadeImpl
- 인터페이스(spi): web 전용 표시 DTO(scalar)만 노출, 시그니처는 web 타입 비참조(String email + 스칼라/포트 DTO).
  - ProductReviewSummaryView getProductReviews(long productId, int page, int size)(공개).
  - long create(String email, long orderItemId, int rating, String content) → productId 반환.
  - long edit(String email, long reviewId, int rating, String content) → productId 반환.
  - long delete(String email, long reviewId) → productId 반환(redirect용).
  > facade 4메서드 중 delete만 long(productId)을 반환한다 — REST측 §2.4 ReviewServiceResponse.delete는 void(DELETE 204, 본문 불요)이나, View는 삭제 후 `/products/{productId}`로 PRG redirect해야 하므로 redirect 대상 산출용 productId가 필요하다(채널별 요구 차이, 모순 아님).
- 구현(service, package-private): UserDirectory.findUserIdByEmail(email)로 해석 후 ReviewService 위임 + DTO 변환(SellerProductFacadeImpl 선례).

### 2.9 order adapter — order/adapter/OrderPurchaseVerificationAdapter
- @Component implements PurchaseVerificationPort.
- 의존: order_item+order 조회 수단(아래), ProductOrderCatalog(variant→productId).
- verify(long orderItemId, long userId): order_item + order(userId·status) 조회. order_item 없거나 order.userId != userId → ownedAndExists=false. delivered = "delivered".equals(order.status). variantId null → productId=null; 아니면 ProductOrderCatalog.getOrderableSnapshots(List.of(variantId)) 첫 결과 productId(없으면 null). return new PurchaseVerification(true, delivered, productId).
  - snapshot 빔(non-null variantId인데 결과 빈) 경로 = 거의 도달 불가한 방어 코드: variant 삭제는 FK ON DELETE SET NULL로 order_item.variant_id를 null로 만들고 스냅샷(productName 등)은 보존(OrderItem.java line 46~51)하므로, **null 경로로 이미 처리**된다. 즉 non-null variantId는 해당 variant 존재를 함의 → snapshot 항상 1건. 그래도 null 반환으로 방어해 두면 서비스가 400으로 안전 변환.
- order_item 조회 수단: OrderRepository에 order_item 단건 조회가 없다(OrderItem은 Order.items 컬렉션). adapter는 order 내부이므로 신규 OrderItemRepository 또는 OrderRepository에 @Query projection 추가(order 내부 변경 — 경계 무위반). 권장: order/repository 경량 projection(select oi.id, o.userId, o.status, oi.variantId from OrderItem oi join oi.order o where oi.id=:id). Entity 노출 없음.
- Entity를 product로 노출하지 않음 — record PurchaseVerification만 반환.

### 2.10 DTO — product/dto
- ReviewCreateRequest(@NotNull Long orderItemId, @NotNull @Min(1) @Max(5) Integer rating, @Size(max=1000) String content).
- ReviewUpdateRequest(@NotNull @Min(1) @Max(5) Integer rating, @Size(max=1000) String content).
- ReviewResponse(long reviewId, long productId, String authorDisplayName, int rating, String content, Instant createdAt, Instant updatedAt) — Entity·email 미노출.
- ProductReviewSummaryResponse(Double averageRating, long reviewCount, int page, int size, long totalElements, int totalPages, List<ReviewResponse> reviews).

### 2.11 예외(common/exception — 모두 BusinessException 상속)
| 예외 | HTTP | 기본 메시지 |
|---|---|---|
| ReviewTargetNotFoundException | 404 | "리뷰 대상 주문 항목을 찾을 수 없습니다." (존재 은닉) |
| ReviewNotFoundException | 404 | "리뷰를 찾을 수 없습니다." (존재 은닉) |
| ReviewNotPurchasedException | 400 | "배송 완료 후에 리뷰를 작성할 수 있습니다." |
| ReviewableProductMissingException | 400 | "삭제된 상품은 리뷰할 수 없습니다." |
| DuplicateReviewException | 409 | "이미 작성한 리뷰가 있습니다." |

---

## 3. 데이터 흐름

### 3.1 작성 — POST /api/v1/reviews
1. JWT 필터 → SecurityConfig /api/v1/reviews/** hasRole("CONSUMER")(비로그인 401, 비CONSUMER 403).
2. ReviewRestController.create → ReviewServiceResponse.create(auth, req) → userId=(long)auth.getPrincipal().
3. ReviewService.create: verify → ownedAndExists=false→404 / delivered=false→400 / productId=null→400 / 선검사→409 / save UNIQUE catch→409(SSOT).
4. ReviewResponse 201.

### 3.2 수정 — PATCH /api/v1/reviews/{id}
인가 통과 → ReviewService.edit → findByIdAndUserId empty → 404(존재 은닉) → Review.edit → updatedAt 트리거 갱신 → 200.

### 3.3 삭제 — DELETE /api/v1/reviews/{id}
인가 통과 → findByIdAndUserId empty → 404 → 물리 delete → 204. 이후 같은 order_item 재작성 허용.

### 3.4 목록·집계 — GET /api/v1/products/{productId}/reviews(공개)
permitAll → getProductReviews → 페이지 조회 + AVG/COUNT + 표시명 IN 배치 마스킹 → ProductReviewSummaryResponse 200. 비로그인 200.

### 3.5 상품 상세 View — GET /products/{id}(공개)
getProductDetail이 기존 product 모델 + reviewFacade.getProductReviews(...)를 productReviews/reviewSummary로 주입 → product/detail 렌더(리뷰 fragment). 0건이면 빈 목록·평점 표기(회귀 0).

### 3.6 작성/수정/삭제 폼(View) — PRG
GET /reviews/new?orderItemId= → review/form. POST /reviews → facade.create → 성공 redirect /products/{productId}?review + flash, 실패 재렌더(입력 보존). edit/delete 제출도 PRG. CSRF는 View 체인 기본 활성(th:action _csrf 자동).

### 3.7 SecurityConfig 매처(주의 — 경로 우선순위)
- REST 체인: 공개 GET /api/v1/products/*/reviews permitAll. 기존 GET /api/v1/products/* permitAll(line 79)은 한 세그먼트 와일드카드라 /products/{id}/reviews(2세그먼트)는 매칭하지 않음 → 별도 matcher 필요. 추가: .requestMatchers(HttpMethod.GET, "/api/v1/products/*/reviews").permitAll() (anyRequest 앞) + .requestMatchers("/api/v1/reviews/**").hasRole("CONSUMER")(coupons matcher 인접). admin/seller/orders matcher와 prefix 충돌 없음.
  - 검증 포인트: MockMvc로 비로그인 GET 200·POST 401.
- View 체인: GET /products/*는 이미 permitAll(line 137 — 무변경). 쓰기 폼은 .requestMatchers("/reviews/**").hasRole("CONSUMER")(미인증 302→/login). GET /reviews/new도 이 matcher 보호(작성은 CONSUMER 전용).

---

## 4. 예외 처리 전략
error-response-rule 준수: 모든 예외는 BusinessException 상속 → REST는 RestExceptionHandler가 ErrorResponse JSON 단일 변환, View는 ViewExceptionHandler가 error/error 렌더. Controller/Service에서 ErrorResponse 직접 조립 금지. 메시지에 내부 정보(SQL/스택/소유자 식별) 비노출.

| 분기 | 경로 | 예외/처리 | HTTP |
|---|---|---|---|
| 비로그인 쓰기 | /api/v1/reviews/**, /reviews/** | Security(REST 401 / View 302→login) | 401/302 |
| 비CONSUMER 쓰기 | 상동(`/api/v1/reviews/**`, `/reviews/**`) | Security 403 | 403 |
| 타인/미존재 order_item 작성 | create | ReviewTargetNotFoundException(존재 은닉) | 404 |
| 미배송(delivered 아님) | create | ReviewNotPurchasedException | 400 |
| variant null(product_id 도출 불가) | create | ReviewableProductMissingException | 400 |
| rating 범위 밖(0/6/null) | create/edit | @Valid(@Min/@Max/@NotNull) | 400 |
| content 1000자 초과 | create/edit | @Valid(@Size) | 400 |
| 중복 작성(같은 order_item) | create | DuplicateReviewException(선검사+UNIQUE catch) | 409 |
| 타인/미존재 리뷰 수정·삭제 | edit/delete | ReviewNotFoundException(존재 은닉) | 404 |
| 미존재 상품 리뷰 목록 | getProductReviews | (예외 아님) 빈 목록·count 0·avg null | 200 |

> 작성 검증 예외는 ReviewService.create @Transactional 안에서 발생 → 롤백. IDOR 정책: order_item·리뷰의 미존재/타인은 동일하게 404로 은닉(쿠폰 CouponNotFoundException 선례 일관).

---

## 5. 검증 방법
> verification-gate-rule: reviewer PASS(정적) ≠ 빌드 그린. 메인이 ./gradlew test 전체 그린 별도 확인. 신규 빈(ReviewRepository/ReviewService/PurchaseVerificationPort 어댑터/ReviewerDirectory 어댑터) 추가로 풀컨텍스트/Modulith 테스트가 신규 빈을 해결하는지 확인.

### 5.1 단위(JUnit5 + Mockito)
- ReviewDomainTest(Review): create rating 경계(1·5 통과, 0·6 IllegalStateException), edit가 rating/content만 변경(productId/userId/orderItemId 불변), null content 허용.
- ReviewServiceCreateTest: verify 결과 분기 — ownedAndExists=false→404, delivered=false→400, productId=null→400, existsByOrderItemId=true→409, save DataIntegrityViolation(mock)→409, 정상 저장. productId가 verify 결과에서만 주입(요청 바디 무시) 단언.
- ReviewServiceEditTest / ReviewServiceDeleteTest: 본인(성공)/타인·미존재(findByIdAndUserId empty→404), edit이 rating/content만 반영.
- ReviewSummaryTest: AVG 1자리 HALF_UP(예: 4.333→4.3), 0건 average=null·count=0. ReviewerDirectory를 mock하여 표시명이 마스킹 문자열로 주입되고 응답 어디에도 email 원문이 없음을 단언. ReviewerDirectory.maskedDisplayNamesByUserId가 **목록 userId 집합으로 정확히 1회** 호출(행당 호출 0 — IN 배치) 단언(Mockito verify times(1) + 캡처한 인자에 모든 userId 포함).
- MemberReviewerDirectoryAdapterTest: 여러 userId 입력 → email 로컬파트 마스킹(예: "alice@x.com"→"al***") Map 반환, 결과에 email 원문 미포함, 미존재 userId는 맵에서 누락(폴백은 호출측 책임), 입력 컬렉션으로 member 배치 조회 1회(N+1 아님) 단언.
- OrderPurchaseVerificationAdapterTest: order_item 미존재/타인→ownedAndExists=false, delivered/비delivered 매핑, variantId null→productId null, ProductOrderCatalog로 productId 해석.

### 5.2 통합(@DataJpaTest / @SpringBootTest + Testcontainers PostgreSQL)
- ReviewOrderItemUniqueIntegrationTest: 같은 order_item_id 2회 INSERT → 2번째 DataIntegrityViolation(uq_reviews_order_item_id). 삭제 후 재작성 성공.
- ReviewPurchaseVerificationIntegrationTest: delivered만 작성 가능(pending/paid/preparing/shipping/cancelled/refunded는 400), 타 회원 order_item→404, variant 삭제(variant_id=null)→400.
- ReviewAggregateIntegrationTest: 동일 product 다건 AVG/COUNT 정확성, 삭제 후 집계 갱신.
- ReviewBaseEntityValidateIntegrationTest: Review+BaseEntity 매핑이 V1 reviews와 validate 정합(작성 후 updatedAt non-null, edit 후 updatedAt 증가).

### 5.3 Security/REST(MockMvc)
- ReviewRestControllerSecurityTest: POST/PATCH/DELETE /api/v1/reviews/** 비로그인 401, 비CONSUMER 403, CONSUMER 통과(역할 계층 SELLER/ADMIN 통과). GET /api/v1/products/{id}/reviews 비로그인 200(공개). 타 회원 리뷰 수정·삭제→404, 타 회원 order_item 작성→404. rating 0/6→400, content 초과→400.
- 매처 우선순위 가드: /api/v1/products/*/reviews GET 200 & 쓰기 prefix 분리 확인.

### 5.4 View 렌더링
- 상품 상세에 리뷰 목록·평균·리뷰 수 렌더(작성자 마스킹·email 비노출 단언), 모델 키 productReviews/reviewSummary 존재.
- 작성/수정/삭제 폼 제출 성공 redirect(/products/{id}?review) + flash, 검증 실패 재렌더(입력 보존, 200).
- 리뷰 미작성 상세 기존 동일(빈 목록·평점 0/null 표기 — 회귀 0).
- 조건부 가시성(작성 버튼 노출/숨김)은 testing-rule상 필요 시 E2E(MEMORY: 목록 조건부 버튼은 브라우저 E2E).

### 5.5 회귀(verification-gate)
- 상품 상세(013)·주문(015~022)·쿠폰(031) 전 스위트 그린 유지. 리뷰 미작성 상세 동일.
- ArchUnit(ProductModuleStructureTest/OrderModuleStructureTest) + ModularityTests 그린 — product→order 및 product→member 역의존 0(포트 의존 역전). order adapter는 product.spi만, member adapter(MemberReviewerDirectoryAdapter)는 product.spi(ReviewerDirectory)만 의존. 신규 ReviewerDirectory가 product/spi의 @NamedInterface("spi")에 포함되는지(member에서 구현 가능) 확인. 신규 order/adapter 패키지 Modulith 인식(package-info) 확인.
- 메인 에이전트가 ./gradlew test BUILD SUCCESSFUL 자기 눈으로 확인.

---

## 6. 트레이드오프

| 결정 | 채택안 | 대안 | 비용/이득 |
|---|---|---|---|
| 모듈 배치 | product 호스팅 + product.spi 포트 ← order.adapter | order 호스팅 / 신규 review 모듈 | 채택: 읽기 응집·기존 order→product.spi 방향 유지·역의존 0. 대안1은 product가 order로부터 평균평점을 받는 어색한 방향(평균은 product 데이터). 대안2는 6모듈 고정 위반. |
| 구매완료 기준 | delivered 단일 | paid 이후 / shipment 단위 | 채택: 배송 후 후기 정합·status rollup 재사용. 대안: 미배송 후기/부분배송 복잡도. |
| product_id | order_item 서버 도출, variant null→400 | 바디 수신 / 410 | 채택: 위조 차단·NOT NULL 충족. 바디 수신은 IDOR. 410은 규칙표 미보유. |
| 삭제 방식 | 물리 삭제 | 소프트 삭제 | 채택: UNIQUE 해제 재작성·스키마 무변경. 소프트는 deleted_at 컬럼 필요. |
| 평점 집계 | AVG/COUNT 쿼리·1자리 HALF_UP | 캐시 컬럼 | 채택: 단순·(product_id) 인덱스 활용. 캐시는 동기화 복잡도. |
| 중복 방어 | UNIQUE catch(SSOT)+선검사 | 선검사만 | 채택: TOCTOU 경합도 UNIQUE 최종 차단. 선검사만은 경합 누수. |
| 표시명 | email 로컬파트 마스킹(IN 배치) | userId 노출 / 행당 조회 | 채택: 개인정보 비노출·N+1 회피. |
| 검증 결과 표현 | 포트가 record 반환 | 포트가 product 예외 던짐 | 채택: order adapter가 product.common 예외 비의존(결합 감소). |

---

## 완료 조건
- [ ] delivered 주문의 본인 order_item으로만 작성 가능, 타인/미존재→404, 미배송→400, variant null→400.
- [ ] 같은 order_item 두 번째 작성→409, 삭제 후 재작성 허용.
- [ ] 본인 리뷰만 수정·삭제(타인→404), 수정 시 rating/content만 변경(불변 필드 유지).
- [ ] 상품 상세·목록 API 공개 조회(비로그인 200), 평균(1자리)·리뷰 수·목록 반환, 작성자 email 비노출(마스킹).
- [ ] product_id는 order_item에서 도출(바디 무시), Review가 BaseEntity 상속해 created_at/updated_at·validate 정합.
- [ ] V1 스키마·이벤트·notification·상품/주문/쿠폰 흐름 무변경, 리뷰 미작성 상세 기존 동일.
- [ ] product→order 역의존 0(ArchUnit/Modulith 그린), ./gradlew test 풀 그린(메인 확인).

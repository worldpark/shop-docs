# 032. shop-core 상품 리뷰 — 실구매 검증 작성·조회·수정·삭제 + 평점 집계 (with View)

> 출처: `docs/backlog/backend/remaining-tasks-roadmap.md` §5(기타 도메인 확장) "리뷰/평점" 승격. DB 스키마(`reviews`)는 **V1에 이미 정의**되어 있으나(코드 미구현) 비즈니스 로직·REST·화면·실구매 검증이 전무하다. 본 Task가 그 공백을 채운다.

## Target
shop-core (review 도메인 + product·order 연동 + web)

> **백엔드/REST 서비스 + 상품 상세 리뷰 화면**에 한정한다(서비스·도메인·REST API·실구매 검증·평점 집계 + Thymeleaf 리뷰 목록·작성/수정/삭제 폼). 신규 이벤트·notification 발송 없음(리뷰 작성은 내부 상태 — 알림 연계는 후속). 리뷰 신고·관리자 모더레이션·이미지 첨부·판매자 답글·"도움돼요"는 범위 밖(후속).

---

## Goal
구매를 완료한 로그인 사용자가 **자신이 산 상품**에 대해 **평점(1~5) + 내용**으로 리뷰를 작성하고, 본인 리뷰를 **수정·삭제**할 수 있다. 리뷰는 `order_item` 단위로 **실구매를 검증**(본인 소유 주문 항목 + 주문 배송 완료)하며, `order_items` UNIQUE 제약으로 **구매 1건당 리뷰 1개**를 보장한다. 상품 상세 화면은 해당 상품의 **리뷰 목록 + 평균 평점·리뷰 수**를 누구나 조회할 수 있다(공개). REST API + Thymeleaf 화면을 제공한다.

## Context
- **DB 스키마는 V1에 존재(무변경 우선)**: `reviews`(`product_id` FK→products NOT NULL CASCADE / `user_id` FK→users NOT NULL CASCADE / `order_item_id` FK→order_items **NOT NULL UNIQUE** ON DELETE RESTRICT / `rating` smallint CHECK(1~5) / `content` text / `created_at`·`updated_at` + 트리거). 정본: `docs/entity/database_design.md` §4.6, V1 `reviews`(line 391~413).
- **쿠폰(031)과 상반 — Entity는 `BaseEntity` 상속**: `reviews`는 `created_at`/`updated_at` 컬럼·`trg_reviews_set_updated_at` 트리거가 **있다**. 따라서 `Review` Entity는 **`BaseEntity`를 상속**한다(ddl-auto=validate 정합, ADR-007). ※ 031 쿠폰 Entity는 created_at/updated_at가 없어 BaseEntity 미상속이었음 — 혼동 금지.
- **구매 1건당 1리뷰 = `order_item_id` UNIQUE**: `uq_reviews_order_item_id`(V1 line 405). 같은 주문 항목으로 두 번째 리뷰 INSERT는 `DataIntegrityViolationException` → 409로 변환(쿠폰 1인 1매 선례와 동일 패턴).
- **실구매 검증 데이터 출처**: `order_items`(`id`/`order_id`/`variant_id`(nullable, ON DELETE SET NULL)/`product_name` 스냅샷/...). **주문 항목에는 `product_id`가 없고 `variant_id`만 있다** → 리뷰 대상 `product_id`는 `order_item.variant_id → product_variants.product_id`로 도출해야 한다. 주문 소유권은 `order_items.order_id → orders.user_id == principal`로 검증한다.
- **주문 상태(015~022)**: `orders.status ∈ {pending,paid,preparing,shipping,delivered,cancelled,refunded}`(Order.java line 25). 배송 완료는 `delivered`(021에서 rollup). 실구매 검증의 "구매 완료" 기준 상태는 plan 확정(권장: `delivered`).
- **상품 카탈로그(013)**: 상품 상세는 공개 조회(`/products/{id}` View, `GET /api/v1/products/{id}` 등). 리뷰 목록·평균 평점은 이 상세 컨텍스트에 노출된다. product 모듈이 상품 조회의 책임을 가진다.
- **회원 식별**: REST는 principal=userId(JWT), View formLogin은 principal=email(String) → spi facade로 email→userId 해석(029 선례). 작성/수정/삭제 소유권은 principal 본인 한정.
- **모듈 배치(plan 확정 — 아래 §plan 결정)**: package-structure-rule은 도메인 6개 고정(member/product/cart/order/payment/inventory). 리뷰를 `product` 모듈(상품 상세 노출 중심)에 둘지 `order` 모듈(실구매 검증 중심)에 둘지 plan에서 확정한다(7번째 모듈 신설 회피 — 031 선례).
- **이벤트 무변경**: 리뷰는 내부 상태. `event-catalog.md`/§5 무변경, notification 무관(029·031과 동일하게 이벤트/알림 없음).

## plan 확정 필요 (설계 결정 — 본 Task가 plan에 위임)
1. **모듈 배치**: 리뷰 컴포넌트를 `product` 모듈 vs `order` 모듈 중 어디에 호스팅할지. 리뷰는 product에 표시되지만(읽기 응집) 작성 시 order_item 실구매 검증(order 데이터)이 필요하다 → **모듈 간 읽기 포트(spi)** 가 한쪽에 필요. **SPI 의존 역전 규칙(package-structure-rule): 호스팅 모듈이 포트 인터페이스를 소유(소비)하고 상대 모듈이 adapter로 구현한다.** (권장: `product` 모듈 호스팅 + **`product/spi`가 실구매 검증 포트(order_item 소유·상태·variant→product 조회)를 소유하고 `order/adapter`가 구현** — 기존 `order → product.spi` 의존 방향 유지, 신규 역의존 없음. 대안: `order` 모듈 호스팅 + **`order/spi`가 product 평균평점 포트를 소유하고 `product/adapter`가 구현**.) **둘 중 하나로 확정.** 신규 모듈 신설 금지. ※ "order 모듈이 포트를 소유" 식으로 두면 `product → order` 역의존이 생겨 ModularityTests 위반 — 호스팅=포트 소비자 원칙을 지킬 것.
2. **실구매 "구매 완료" 기준 상태**: 어느 주문 상태부터 리뷰 작성 허용인가. (권장: `delivered`(배송 완료 후 후기) 단일 기준. 대안: `paid` 이후 허용.) 부분 배송(shipment 단위)까지 볼지 여부 포함 — 권장은 **주문 레벨 `delivered`** 단순화.
3. **`product_id` 도출 + variant 삭제 엣지**: `order_item.variant_id → product_variants.product_id`로 도출. **`variant_id`가 null(상품 옵션 삭제)인 주문 항목**의 리뷰 작성 처리 — (권장: product_id 도출 불가 → 리뷰 작성 거부 **400**("삭제된 상품은 리뷰할 수 없습니다"). 대안: 작성 차단 메시지 표기.) plan 확정. **`product_id`는 요청 바디로 받지 않고 order_item에서만 도출**(위조 차단). ※ error-response-rule HTTP 매핑표(400/404/409/422)에 410이 없으므로 거부는 400으로 한다(410 채택 시 규칙표 보강 필요).
4. **수정·삭제 범위**: 본 Task에 본인 리뷰 수정(rating/content)·삭제 포함 여부·삭제 방식(물리 삭제 vs 소프트). (권장: 수정·삭제 **포함**, 물리 삭제(`order_item_id` UNIQUE를 비워 재작성 허용). 소프트 삭제는 과설계 — 채택 안 함.) plan 확정.
5. **평점 집계(평균·개수) 노출 범위**: 상품 상세에 평균 평점·리뷰 수 표기. 집계 방식 — (권장: 조회 시 `AVG(rating)`/`COUNT(*)` 쿼리 집계, 비정규화 캐시 컬럼 미도입. 카탈로그 목록 평균평점 노출은 범위 밖 — 상품 상세만.) 반올림 규칙(소수 1자리 등) plan 확정.
6. **리뷰 작성 진입 경로(View)**: 어디서 작성 폼에 진입하는가. (권장: 주문 내역/상세에서 `delivered` 항목별 "리뷰 작성" 진입 + 상품 상세에는 목록만. 주문 내역 화면이 별도 Task라면 본 Task는 작성 폼 라우트(`GET /reviews/new?orderItemId=`)만 제공하고 진입 링크는 최소.) plan 확정.

## API Authorization
> `docs/rules/api-authorization-rule.md` 준수. 작성/수정/삭제는 **principal 본인 + 실구매 검증** 한정(IDOR 차단 — order_item 소유·대상 product를 principal/order_item에서만 도출). 조회는 공개.

| API | 공개 여부 | 최소 권한 | 소유권/증명 | 비고 |
|---|---|---|---|---|
| `POST /api/v1/reviews` | authenticated | `CONSUMER` | principal 본인 + order_item 실구매 | 리뷰 작성(orderItemId·rating·content) |
| `PATCH /api/v1/reviews/{id}` | authenticated | `CONSUMER` | principal 본인(리뷰 작성자) | 본인 리뷰 수정(rating/content) |
| `DELETE /api/v1/reviews/{id}` | authenticated | `CONSUMER` | principal 본인(리뷰 작성자) | 본인 리뷰 삭제 |
| `GET /api/v1/products/{productId}/reviews` | **public** | — | — | 상품 리뷰 목록 + 집계(공개 조회) |
| `GET /products/{id}` (확장) | public | — | — | 상품 상세 View에 리뷰 목록·평균 평점 노출 |
| `GET /reviews/new?orderItemId=` (View) | authenticated | `CONSUMER` | principal 본인 + order_item 실구매 | 리뷰 작성 폼 |
| `POST /reviews` (View) | authenticated | `CONSUMER` | principal 본인 + order_item 실구매 | 작성 폼 제출 → redirect |
| `POST /reviews/{id}/edit`·`/delete` (View) | authenticated | `CONSUMER` | principal 본인(작성자) | 수정/삭제 폼 제출 |

> 공개 조회(`GET .../reviews`, 상품 상세)는 SecurityConfig `permitAll`(상품 카탈로그 013 선례 경로와 동일 정책). 작성/수정/삭제는 `hasRole("CONSUMER")` + 서비스 계층 소유권/실구매 검증. **소유권은 principal userId + order_item 소유에서만 도출**(바디/경로로 타 회원·타 order_item 신뢰 금지).

## Requirements
- **리뷰 작성(`POST /api/v1/reviews`, View `POST /reviews`)**
  - 입력: `orderItemId`, `rating`(1~5), `content`(선택, 길이 상한 plan 확정). 검증:
    1. `order_item`이 존재하고 그 `order.user_id == principal`(소유) — 위반 시 **404(존재 은닉)**(IDOR 방어 — 타 회원/미존재를 동일하게 404로 숨김. Task 031 쿠폰 "미보유/타인 → 404" 선례 일관).
    2. 주문 상태가 **구매 완료 기준**(plan 결정 2, 권장 `delivered`) — 미달 시 400(거부, "배송 완료 후 작성 가능").
    3. `product_id` 도출(order_item.variant_id → variant.product_id) — variant 삭제(null)면 거부(plan 결정 3).
    4. `rating` 범위(1~5) 도메인 검증(CHECK 정합).
  - 저장: `Review.create(productId, userId, orderItemId, rating, content)`(여기서 `productId`는 **service가 order_item에서 도출한 값만 주입** — 요청 바디로 받지 않음, 위조 차단). `order_item_id` UNIQUE 위반(이미 리뷰됨) → **409**(구매 1건당 1리뷰). 선검사(`existsByOrderItemId`)는 사용자 메시지용 best-effort이고, **409 변환의 SSOT는 `DataIntegrityViolationException` catch**(TOCTOU 경합도 UNIQUE가 최종 방어 — 031 쿠폰 1인1매 선례).
- **리뷰 수정(`PATCH /api/v1/reviews/{id}`, View `POST /reviews/{id}/edit`)**
  - 본인(작성자 `review.user_id == principal`)만 `rating`/`content` 수정. 타인 → **404(존재 은닉)**(작성/삭제와 동일 IDOR 정책). `order_item_id`/`product_id`/작성자 불변. `updated_at` 자동 갱신(트리거).
- **리뷰 삭제(`DELETE /api/v1/reviews/{id}`, View `POST /reviews/{id}/delete`)**
  - 본인만 삭제(plan 결정 4 — 권장 물리 삭제). 삭제 후 같은 `order_item`으로 재작성 허용(UNIQUE 해제).
- **리뷰 목록·집계 조회(`GET /api/v1/products/{productId}/reviews`, 상품 상세 View)**
  - 해당 상품의 리뷰 목록(작성자 표시명·평점·내용·작성일) + **평균 평점·리뷰 수** 반환(공개). 페이징(plan 확정 — 권장 최신순 페이지네이션). Entity 직접 반환 금지(DTO). 작성자 개인정보(email 등) 비노출(표시명/마스킹 규칙 plan 확정).
- **화면(with View — `web` 레이어, spi facade 경유)**
  - 상품 상세(`GET /products/{id}`)에 리뷰 목록·평균 평점·리뷰 수 노출(013 화면 확장). web은 review/product Entity·Service 직접 참조 금지, **spi facade**가 표시용 DTO(scalar) 제공(027/029 facade 패턴 계승).
  - 리뷰 작성 폼(`GET /reviews/new?orderItemId=`) → 제출(`POST /reviews`)은 PRG(redirect) + flash. 수정/삭제 폼 제출도 PRG. 검증 실패 시 재렌더(입력 보존).
- **도메인 메서드**: `Review`에 정적 팩토리 `create(...)` + `edit(rating, content)`(Setter 금지). 작성자/대상/order_item 불변.
- **로그**: 작성/수정/삭제를 `userId`·`reviewId`와 함께 로깅(민감정보 로그 금지).

## Constraints
- **본인 + 실구매 한정(IDOR 차단)**: 작성/수정/삭제는 principal 본인만. 대상 `order_item`은 본인 소유 주문의 항목만 신뢰하고, `product_id`는 order_item에서만 도출한다(바디로 product_id/타 order_item 받지 않음). 타인 리뷰 변경 경로 없음.
- **구매 1건당 1리뷰**: `order_item_id` UNIQUE로 보장(중복 작성 409). 동시 작성 경합도 UNIQUE가 차단(쿠폰 1인 1매 선례).
- **DB 스키마 변경 없음**: `reviews`는 V1 사용(무변경, 신규 마이그레이션 없음). Entity는 V1 컬럼 매핑 + **`BaseEntity` 상속**(created_at/updated_at 존재 — 쿠폰과 상반).
- **이벤트/notification 무변경**: 리뷰는 내부 상태. `event-catalog.md`/§5 불변, notification 코드·DB 미참조(알림 연계는 후속).
- **레이어/모듈 규칙**: REST `@RestController→ServiceResponse→Service→Repository`, View `@Controller(web)→spi facade→Service`. 컨트롤러 비즈니스 로직 금지. **모듈 경계 통신은 spi/published port**(리뷰 호스팅 모듈이 상대 모듈(order 실구매 검증 또는 product 조회) 데이터를 읽을 때 spi 경유 — 내부 Entity 직접 참조 금지). 6개 도메인 모듈 고정(신규 review 모듈 신설 금지).
- **개인정보 보호**: 리뷰 목록 공개 응답에 작성자 email/전화 등 노출 금지(표시명/마스킹만).
- **회귀 금지**: 상품 상세(013)·주문(015~022)·쿠폰(031) 기존 흐름 무변경. 리뷰 미작성 상품 상세는 기존과 동일(빈 목록·평점 0/표기).

## Files
> 정확 경로/모듈 배치는 plan 확정(§plan 결정 1). 아래는 `product` 모듈 호스팅 가정 예시.
- (신규) `product/domain/Review.java` — `reviews` 매핑 Entity(**BaseEntity 상속**), `create(...)`/`edit(rating, content)` 도메인 메서드, rating 1~5 검증.
- (신규) `product/repository/ReviewRepository.java` — `findByProductId`(페이징), `findByIdAndUserId`(소유), 집계(`avg`/`count` by product), `existsByOrderItemId`(선검사 보조 — UNIQUE가 최종 방어).
- (신규) `product/service/ReviewService.java`(+ `ReviewServiceResponse`) — 작성(실구매 검증·product_id 도출·UNIQUE)/수정/삭제/목록·집계.
- (신규) `product/spi/PurchaseVerificationPort.java` — order_item 소유·상태·variant→product 조회 read 포트(모듈 경계). **product 호스팅 시 이 포트는 `product/spi`가 소유하고 `order/adapter`가 구현**(의존 역전 — 기존 `order → product.spi` 방향 유지). order 호스팅 대안 채택 시에만 포트 소유 모듈이 바뀐다(§plan 결정 1).
- (신규) `product/dto/**` — `ReviewCreateRequest`(orderItemId·rating·content), `ReviewUpdateRequest`, `ReviewResponse`, `ProductReviewSummaryResponse`(평균·개수·목록), (View 폼 객체).
- (신규) `product/controller/ReviewRestController.java` — `POST /api/v1/reviews`, `PATCH/DELETE /api/v1/reviews/{id}`, `GET /api/v1/products/{productId}/reviews`.
- (신규) `product/spi/ReviewFacade.java` + 구현체 — web용 표시 DTO(scalar) + 처리(email→userId 해석).
- (신규/수정) `web/product/**` 또는 신규 `web/review/ReviewViewController.java` — `GET /reviews/new`, `POST /reviews`, `POST /reviews/{id}/edit|delete`.
- (수정) 상품 상세 View 컨트롤러·템플릿(013) — 리뷰 목록·평균 평점·리뷰 수 + (조건부) 작성 진입.
- (신규) `src/main/resources/templates/review/**` 또는 상품 상세 템플릿 fragment — 리뷰 목록·작성/수정/삭제 폼(기존 layout/fragment·messages 재사용).
- (수정) `security/SecurityConfig.java` — `POST/PATCH/DELETE /api/v1/reviews/**`·`/reviews/**` `hasRole("CONSUMER")`, `GET /api/v1/products/*/reviews`·상품 상세는 `permitAll`(013 정책 일관).
- (수정, 선택) `docs/entity/database_design.md` — 리뷰 작성/실구매 검증 라이프사이클 의도 보강(스키마 무변경).
- (재사용·무변경) order_item/order 조회(spi), product 조회, `MemberRepository`/principal 해석, `RestExceptionHandler`(BusinessException), `event-catalog.md`/§5, notification 전부.

## Backend - View Contract
| 항목 | 값 |
|---|---|
| 상품 상세 리뷰 노출 | `GET /products/{id}` → 모델에 리뷰 목록·평균 평점·리뷰 수(모델 키는 Thymeleaf 예약어 회피 — `productReviews`/`reviewSummary` 등 도메인 접두사) |
| 리뷰 작성 폼 | `GET /reviews/new?orderItemId=` → view `review/form` |
| 작성 제출 | `POST /reviews` → 성공 redirect `/products/{productId}?review` (실패 재렌더, 입력 보존) |
| 수정 제출 | `POST /reviews/{id}/edit` → 성공 redirect `/products/{productId}?review` |
| 삭제 제출 | `POST /reviews/{id}/delete` → 성공 redirect `/products/{productId}` |
| 모델 키 | 리뷰 목록 `productReviews`, 집계 `reviewSummary`, 폼 백킹 `reviewForm`(주의: `request`/`param` 등 암묵 scope 예약어 회피) |

## Acceptance Criteria
- 구매 완료(기준 상태) 주문의 **본인 order_item**으로만 리뷰를 작성할 수 있고, **타인 주문 항목·미존재는 404(존재 은닉)**, 미구매·미배송 항목은 400으로 거부된다.
- 같은 `order_item`으로 **두 번째 리뷰 작성은 거부**된다(409, 구매 1건당 1리뷰). 삭제 후에는 재작성이 허용된다.
- 본인 리뷰만 **수정·삭제**할 수 있고, 타인 리뷰는 변경·삭제할 수 없다(**404 존재 은닉**). 수정 시 `rating`/`content`만 바뀌고 작성자·대상·order_item은 불변이다.
- 상품 상세/리뷰 목록 API는 **누구나 조회**할 수 있고, 평균 평점·리뷰 수와 목록을 반환하며, 작성자 개인정보(email 등)는 노출되지 않는다.
- `product_id`는 요청이 아니라 **order_item에서 도출**되며, variant 삭제로 도출 불가한 항목은 작성이 거부된다.
- `reviews` V1 스키마·기존 이벤트·notification·상품/주문 흐름이 무변경이고, 리뷰 미작성 상품 상세는 기존과 동일하다(회귀 없음).
- `Review` Entity가 `BaseEntity`를 상속해 `created_at`/`updated_at`과 `validate` 정합한다(신규 마이그레이션 없음).

## Test
- **단위(Mockito)**: 작성 — 소유 위반/미배송/이미리뷰(UNIQUE)/variant null(product_id 도출 불가)/rating 범위 분기. product_id가 order_item에서 도출되는지(요청 바디 무시). 수정 — 본인/타인 분기, rating·content만 반영(불변 필드 유지). 삭제 — 본인/타인 분기. `Review` 도메인 메서드(`create`/`edit`/rating 검증) 단언.
- **통합(Testcontainers)**: `order_item_id` UNIQUE 위반 거부(같은 항목 2회 작성 → 2번째 409). 실구매 검증(배송 완료 주문 항목만 작성 가능) — 상태별. 삭제 후 재작성 성공. 집계(`AVG`/`COUNT`) 정확성. `Review`+`BaseEntity` `validate` 정합(V1 적용).
- **Security/REST(MockMvc)**: `POST/PATCH/DELETE /api/v1/reviews/**` 비로그인 401, 타 회원 리뷰 수정·삭제 불가(본인만, 타인 → **404 존재 은닉**), 타 회원 order_item 작성 불가(**404**). `GET /api/v1/products/{id}/reviews`·상품 상세는 **비로그인 200(공개)**. rating 범위 밖(0/6) 작성 → 400.
- **View 렌더링**: 상품 상세에 리뷰 목록·평균 평점 렌더(작성자 개인정보 비노출), 작성/수정/삭제 폼 제출 성공 redirect + flash, 검증 실패 재렌더 입력 보존. (조건부 가시성 — 작성 버튼 노출/숨김 — 은 testing-rule상 필요 시 E2E.)
- **회귀**: 상품 상세(013)·주문(015~022)·쿠폰(031) 그린 유지. 리뷰 미작성 상품 상세 기존 동일. `./gradlew test` 풀 그린.

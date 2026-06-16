# 043. 관리자 통계 대시보드 — 유저 이용률·상품 판매율·환불율

> 출처: 사용자 요청 — admin이 전체 유저 이용률·상품 판매율·환불율을 보는 페이지.
> **선행: Task 042**(로그인 활동 추적 `last_login_at`) 완료 후 착수(이용률이 그 데이터에 의존).
> 지표 정의 확정(사용자):
> - 환불율 = **건수 기준**, 기간 = **최근 30일**, 분모에 **cancelled/pending 포함(=전체 주문)**.
> - 상품 판매율 = **DRAFT/HIDDEN 미포함**(게시 상품만 분모), 기간 최근 30일.
> - 유저 이용률 = **접속 기반(B)** — 최근 30일 접속 회원 / 전체 활성 회원.

## Target / Goal
관리자가 `/admin/dashboard`(또는 적절한 admin 경로)에서 **3개 핵심 지표**를 한 화면에서 본다. 모두 **읽기 전용 집계**, 기간은 **최근 30일(앱 KST 기준 now−30일)**.

## 지표 정의 (확정)
### ① 유저 이용률 (접속 기반, Task 042 의존)
- **= 최근 30일 내 `last_login_at` 있는 활성 회원 수 / 전체 활성 회원 수**(`users.status='ACTIVE'`).
- numerator: `status='ACTIVE' AND last_login_at >= (now−30d)`. denominator: `status='ACTIVE'`.
- (역할 범위: "전체적인" 요청 → 전체 활성 회원. CONSUMER 한정 여부는 plan에서 확인·기본 전체.)
- 한계: 042 배포 후 점진 채움(소급 불가) — 화면에 "집계 시작 이후 접속분" 주석.

### ② 전체 상품 판매율 (게시 상품 기준)
- **= 최근 30일 판매된 게시 상품 수(distinct) / 전체 게시 상품 수**.
- denominator: `products.status NOT IN ('DRAFT','HIDDEN')`(= ON_SALE + SOLD_OUT).
- numerator: 최근 30일(`orders.created_at >= now−30d`) **완료 판매**(status ∈ {paid,preparing,shipping,delivered}, Task 040 COUNTED_STATUSES 재사용) 주문항목의 variant→product distinct 중 **게시 상품**만. 삭제 variant(variant_id NULL)는 자동 제외(한계, 040과 동일).

### ③ 환불율 (건수 기준)
- **= 최근 30일 `status='refunded'` 주문 수 / 최근 30일 전체 주문 수**.
- denominator: 최근 30일 **모든** 주문(`pending`·`cancelled` **포함**, 즉 상태 무관 전체).
- numerator: 최근 30일 `status='refunded'` 주문 수.
- 기간 기준: `orders.created_at >= now−30d`(주문 생성 시각). 한계: 부분환불 미추적(전체환불 status만), 환불 발생 시점이 아닌 주문 생성 시점 윈도우 — 화면/문서 주석.

## 아키텍처 (Modulith — Task 040 패턴 재사용)
3모듈(member·order·product) 데이터를 **web이 각 모듈 spi facade로 조합**(사이클 없음, `OrderViewController`·Task 040 web 조합 선례).
- **member**: `AdminMemberFacade`(또는 신규)에 `이용률용 카운트`(전체 활성 / 30일 접속 활성) read 추가 — Task 042의 `last_login_at` 사용.
- **order**: 환불율용 `최근30일 전체 주문수`·`최근30일 refunded 주문수` 카운트 + 상품 판매율용 `최근30일 완료판매 variantId 집합(또는 distinct)` read 추가(`OrderItemSalesRepository`/Admin facade).
- **product**: 게시 상품 수(`status NOT IN DRAFT/HIDDEN`) + 주어진 판매 variantId 집합 → **게시 상품 distinct count**(소유권 무관, 전체) read 추가.
- **web**: 신규 `AdminDashboardViewController` + 조합 컴포넌트(`AdminDashboardAssembler`)가 3 facade 호출 → 비율 계산(0 division 가드) → 뷰 모델. order는 variantId(Long)만 노출(product 타입 누설 없음, 040과 동일 seam).
- 기간(now−30d)은 **web/service에서 앱 Clock(KST)로 계산해 각 facade에 threshold 전달**(각 모듈은 시계 정책 무지).

## 범위
### 백엔드 (backend-implementor)
- member/order/product 각 admin facade·repository에 위 카운트 read 메서드 추가(읽기 전용).
- web 조합 컴포넌트 + 뷰 컨트롤러(GET /admin/dashboard) + 뷰 모델 DTO(비율·원시 카운트). 비율은 BigDecimal/퍼센트, 분모 0 가드(0%거나 "N/A").
### 화면 (view-implementor)
- `templates/admin/dashboard.html`: 3지표 카드/표(비율 % + 원시 수치 "x / y"). 각 지표에 정의·한계 주석(30일 기준, 이용률 점진 채움, 판매율 게시상품 기준·삭제variant 제외, 환불율 건수·부분환불 미추적). nav에 "대시보드" 링크. 인라인 script 쓰면 `<main>` 내부.

## Non-goals
- 차트/그래프·추세(시계열) — 숫자 지표만. 추세는 로그인이벤트/주문 시계열 별도 후속.
- 기간 선택 UI(주간/월간 토글) — 최근 30일 고정(후속 가능).
- 금액 기준 환불율·sell-through(재고대비) — 비범위(건수·판매상품비율로 확정).
- CSV/내보내기.

## 검증
- 백엔드: 각 카운트 쿼리 정확(상태·기간·게시상품 필터), 분모 0 가드, 30일 경계. order는 variantId만, product가 게시상품 distinct 매핑. **Modulith verify**(web만 3 spi 조합, 사이클 없음). IDOR 무관(전체 통계, admin 전용).
- **브라우저 E2E**: ADMIN 로그인 → /admin/dashboard → 시드한 데이터(회원 로그인분·완료주문·환불주문·게시/DRAFT 상품)로 3비율이 기대값과 일치, 비ADMIN 차단.
- 풀 스위트 그린.

## 참고
- 선행: Task 042(`last_login_at`).
- 패턴: Task 040(web 조합·order variantId seam·`OrderItemSalesRepository`), `SellerProductStatsViewController`/`Assembler`.
- 상태값: `Order.status` lowercase String(paid/preparing/shipping/delivered/cancelled/refunded/pending), `ProductStatus`(DRAFT/ON_SALE/SOLD_OUT/HIDDEN). 전역 KST(ADR-009).
- 모듈 경계: member.spi/order.spi/product.spi, web 조합(Task 040 선례), `web/package-info` 허용 의존.

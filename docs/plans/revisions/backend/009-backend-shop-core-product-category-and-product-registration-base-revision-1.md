# 009 — View principal 의존 역전(포트-어댑터) + 응답 코드 정정 (Revision 1)

- 대상 Task: `docs/tasks/backend/009-backend-shop-core-product-category-and-product-registration-base.md`
- 대상 Plan: `docs/plans/backend/009-backend-shop-core-product-category-and-product-registration-base-plan.md`
- 변경 적용 Task: Task 009 (구현 착수 전 plan 단계에서 반영 — 코드 미작성 상태)
- 결정 일자: 2026-06-04
- 결정자: 사용자
- 목적: 009 plan 최초안에서 View 진입점이 `MemberService.getByEmail`을 직접 호출(= `product → member` 모듈 간 도메인 직접 의존)하던 설계를, **포트-어댑터(의존 역전)** 로 변경한 사실과, 승인 과정에서 확정한 응답 코드 결정을 기록한다.

---

## 결정 요약

| 항목 | 최초 plan안 | 변경 결정 | 비고 |
|---|---|---|---|
| View email→userId 변환 | `SellerProductViewController`가 `MemberService.getByEmail()` 직접 호출 | **`product.spi.UserDirectory` 포트** 주입 → 어댑터가 member에 위임 | product→member 직접 의존 제거 |
| 의존 방향 | `product → member`(도메인 서비스) | **`member → product.spi`**(의존 역전, @NamedInterface) | product는 member 미참조 |
| 포트 소유 | (없음) | `product.spi.UserDirectory` — product 모듈 소유, published port | 분리 시 어댑터만 교체 |
| 어댑터 | (없음) | `member.adapter.MemberUserDirectoryAdapter implements UserDirectory` | member 모듈 소유 |
| `ProductService` 의존 | (최초안 라인 37 "MemberService.getByEmail 의존"으로 부정확 기술) | **순수 도메인 — member·포트 비의존**, `actorId(long)`/`actorIsAdmin` 인자로만 수신 | 모순 표현 정정 |
| 생성(카테고리/상품) 응답 코드 | 201 Created(일부 "또는 200") | **200 OK** | 기존 008 컨벤션 일관 |
| 타인 상품 수정/조회 응답 | 404 (최초안 그대로) | **404 유지**(존재 은닉) | 변경 아님 — 승인 확정 기록 |

---

## 1. 변경 이유 — 포트-어댑터 의존 역전

### 1.1 배경
- `product` 모듈은 **장차 외부 서비스로 분리**하려는 기획 의도를 가진다.
- 최초 plan안은 View(form-login) 진입점에서 principal(email)을 userId로 변환하기 위해 `MemberService.getByEmail(email).getId()`를 직접 호출했다. 이는 008 `AdminMemberViewController`의 패턴을 계승한 것이나, 008은 **member 모듈 내부**(member→member)라 자연스러운 반면, product에서 같은 패턴을 쓰면 **처음으로 `product → member` 모듈 간 도메인 직접 의존**이 생긴다.
- REST 진입점은 이미 principal=userId(long)이라 member 의존이 없다. 즉 결합은 **오직 View(form-login principal=email)** 에서만 발생한다.

### 1.2 규칙 근거
- `docs/rules/architecture-rule.md`: "동기 조회가 꼭 필요하면 각 모듈이 노출한 **published API(named interface/port)** 를 통해서만 호출한다. 비공개 구현에는 접근하지 않는다. 모듈 경계를 넘는 데이터는 DTO로 주고받고 Entity를 모듈 밖으로 노출하지 않는다."
- 직접 `MemberService`(member의 service 패키지) 호출은 이 조항에 어긋난다. 포트 경유로 전환한다.

### 1.3 의존 역전을 택한 이유 (vs published API 호출)
- 단순 published API 모델(member가 인터페이스 노출 → product가 호출)은 의존 방향이 여전히 `product → member`라 분리 시 결합이 남는다.
- **의존 역전**(포트를 product가 소유, member가 구현)으로 두면 `product`는 member를 **전혀 모른다**. 외부 분리 시 어댑터를 **REST 호출 구현으로 교체**하기만 하면 되어 분리 의도에 가장 부합한다.

---

## 2. 변경 내용 (Task 009 구현에서 적용)

### 2.1 포트 — product 소유
- `com.shop.shop.product.spi.UserDirectory` (인터페이스)
  ```java
  // com.shop.shop.product.spi.UserDirectory  (포트 — product 소유)
  public interface UserDirectory {
      // 인증 세션 email → userId. 미존재 시 도메인 불변식 위반(IllegalStateException 가정)
      long findUserIdByEmail(String email);
  }
  ```
- `com.shop.shop.product.spi.package-info.java` — `@NamedInterface("spi")`로 published named interface 노출(member가 참조 가능하게).

### 2.2 어댑터 — member 소유 (의존 역전)
- `com.shop.shop.member.adapter.MemberUserDirectoryAdapter`(`@Component`) `implements com.shop.shop.product.spi.UserDirectory`
  - `findUserIdByEmail(email)` → `memberService.getByEmail(email).getId()` 위임.
  - 의존 방향: **member → product.spi**(named interface). product는 member를 참조하지 않는다.

### 2.3 진입점/도메인
- `SellerProductViewController`: `UserDirectory` 포트 주입 → `findUserIdByEmail(auth.getName())`로 actorId 획득(member 직접 호출 0). `actorIsAdmin`은 authority(`ROLE_ADMIN` 직접 보유)로 판정.
- `ProductService`: **순수 도메인 — member·포트 비의존**. `register/update/getForEdit`는 `actorId(long)`/`actorIsAdmin(boolean)`을 인자로만 받는다.
- REST(`ProductServiceResponse`): principal=userId(long) 직접 추출 — **포트 불요, 무변경**.

### 2.4 패키지 규칙 정합
- `product.spi`(포트)·`member.adapter`(어댑터)는 `package-structure-rule.md` 표준 패키지 목록(controller/service/repository/domain/dto/event/messaging)에 없다.
- (a) architecture-rule "published API(named interface/port)" 조항으로 정당화한다.
- (b) **후속 제안(별도 task)**: `package-structure-rule.md`에 한 줄 보강 — "모듈 published port = `{module}/spi`(@NamedInterface), 외부 모듈이 그 포트를 구현하는 어댑터 = `{module}/adapter`." (이번 task에서 규칙 파일 자체는 수정하지 않는다.)

### 2.5 응답 코드 정정 (승인 확정)
- 생성(카테고리/상품) 성공 응답: 최초안 201 → **200 OK**(기존 008 관리자 API 컨벤션 일관). plan 내 201 표기 전부 200으로 교체 완료.
- 타인 판매자 상품 수정/조회: **404**(존재 은닉, 열거 방지) — 최초안 유지, 승인으로 확정.

---

## 3. 검증 영향
- **View 테스트**(`SellerProductViewControllerTest`): `UserDirectory`를 `@MockBean`/fake로 주입해 `findUserIdByEmail` stub → member 의존 없이 View 단독 검증.
- **배선 회귀**(`ProductWiringTest`): `MemberUserDirectoryAdapter` 빈 등록 + `UserDirectory` 운영 배선 단언 추가.
- **ModularityTests**: `product → member` 참조 0, `member → product.spi`(@NamedInterface) 단방향만 허용. `ownerId`는 스칼라 long(member Entity 미노출).

---

## 4. 영향받는 산출물

| 파일 | 변경 |
|---|---|
| `docs/plans/backend/009-...-plan.md` | 포트-어댑터로 일관 수정(영향범위·§1.4·§1.6·§2·§3·§5·§6·체크리스트·분담표), 201→200 정정 |
| `shop-core/.../product/spi/UserDirectory.java` | **신규**(포트, product 소유) — 구현 시 |
| `shop-core/.../product/spi/package-info.java` | **신규**(`@NamedInterface("spi")`) — 구현 시 |
| `shop-core/.../member/adapter/MemberUserDirectoryAdapter.java` | **신규**(어댑터, member 소유) — 구현 시 |
| `shop-core/.../product/controller/SellerProductViewController.java` | `UserDirectory` 포트 주입(member 직접 호출 제거) — 구현 시 |

---

## 5. 후속 액션
- [x] 본 Revision 기록 작성
- [ ] Task 009 구현에서 포트-어댑터 반영 (backend-implementor: 포트·어댑터·ViewController 포트 주입·ModularityTests/WiringTest)
- [x] `package-structure-rule.md`에 `{module}/spi`·`{module}/adapter` 패키지 규칙 보강 (2026-06-04 적용 — "shop-core 모듈 간 통신 패키지" 절)
- [ ] 향후 다른 모듈도 모듈 경계 동기 조회가 필요하면 동일하게 published port(@NamedInterface) + 어댑터 패턴을 따른다

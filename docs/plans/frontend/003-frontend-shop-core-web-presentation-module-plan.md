# 003. shop-core Web 프레젠테이션 모듈 분리 — Plan

> 범위: shop-core의 Thymeleaf ViewController 5종을 신규 `web` 지원 모듈로 이동하고, ViewController가 도메인 내부 구현(Entity·Repository·비공개 Service)에 직접 의존하지 않도록 도메인별 View 전용 facade(published port)를 도입한다. URL·View name·템플릿 파일명·REST API는 변경하지 않는다.
> 범위 밖: 신규 비즈니스 기능, REST Controller 이동, 도메인 모듈 추가, Kafka/이벤트 계약 변경, 화면 디자인/CSS 변경, notification.
> 과도 설계 금지 원칙을 전 섹션에 적용한다.

---

## 구현 목표
`shop-core`의 ViewController를 독립 `web` 지원 모듈로 분리하되, `web`이 각 도메인이 노출한 **View 전용 facade/port(named interface) + DTO**만 의존하는 얇은 프레젠테이션 어댑터가 되게 한다. 도메인 모듈은 `web`을 의존하지 않으며, 향후 `member`/`product`가 별도 서비스로 분리되어도 화면 서버는 하나의 프레젠테이션 레이어로 유지될 수 있다.

---

## 사전 확정 사실 (재조사로 확인됨)

### 현재 ViewController와 도메인 결합
| ViewController | 현재 위치 | 도메인 결합(제거 대상) |
|---|---|---|
| `HomeViewController` | `home/controller` | 없음 (뷰 이름만 반환) |
| `LoginViewController` | `member/controller` | 없음 (뷰 이름만 반환) |
| `MemberSignupViewController` | `member/controller` | `MemberService`(비공개 service), `SignupForm`(dto), `DuplicateEmailException`(common·OPEN) |
| `AdminMemberViewController` | `member/controller` | `MemberService`(Page<**User** Entity> 반환), `Role`(domain enum), `MemberSearchCondition`/`MemberSummaryResponse`(dto), `BusinessException`(common·OPEN) |
| `SellerProductViewController` | `product/controller` | `ProductService`/`CategoryService`(**Product/Category** Entity 반환), `ProductStatus`(domain enum), `ProductForm`/`CategoryResponse`(dto), `UserDirectory`(product.spi) |

### Spring Modulith 현황
- 인식 모듈: member / product / cart / order / payment / inventory / common(OPEN) / security(OPEN) / home / platform.
- `home` 모듈의 유일한 코드는 `home/controller/HomeViewController` 하나뿐이다 (`home/package-info.java` 없음).
- `product/spi`는 이미 `@NamedInterface("spi")`로 선언됨(`UserDirectory` 보유). `MemberUserDirectoryAdapter`(member)가 구현 — 의존 방향 `member → product.spi` 단방향.
- `member`에는 `spi` 패키지가 없다. `member/dto`·`product/dto`는 named interface가 아니다.
- 구조 검증: `ModularityTests.verifiesModuleStructure()`가 `ApplicationModules.of(...).verify()` 실행.

### 회귀 금지 계약(보존 대상)
- View name: `home/home`, `auth/login`, `member/signup`, `admin/members`, `seller/product-form`, `error/error`.
- URL: `/`, `/login`, `/signup`(GET/POST), `/admin/members`(GET) + `/admin/members/{memberId}/role`(POST), `/seller/products/new|""|{id}/edit|{id}`(GET/POST).
- 모델 키: `signupForm`, `members`, `searchCondition`, `productForm`, `categories`, `statuses`, `productId`. Flash: `flashSuccess`/`flashError`.
- 보안: View 체인 `/admin/**`→`hasRole("ADMIN")`, `/seller/**`→`hasRole("SELLER")`(상위 ADMIN 함의). 소유권 검사는 `ProductService`(getForEdit/update)에 잔존.
- 비밀번호 echo 차단, 이메일 중복 시 BindingResult 재렌더(JSON 금지), PRG redirect 패턴.
- 템플릿 바인딩: `admin/members.html`는 role 옵션을 문자열 리터럴(ADMIN/SELLER/CONSUMER)로 렌더하고 `th:field="*{role}"`로 `searchCondition.role` 바인딩. `m.role`은 이미 String. `seller/product-form.html`는 `statuses`를 `th:value="${s}" th:text="${s}"`로 렌더하고 `th:field="*{status}"`로 `ProductForm.status` 바인딩 → **String 타입과 호환**.
- REST 독립성: `AdminMemberRestController`는 `@RequestParam Role role`을 독립 사용(`MemberSearchCondition` 미사용). `Seller/Category RestController`는 `ProductResponse`/`CategoryResponse`/`ProductCreateRequest`/`ProductUpdateRequest`만 사용(`ProductForm` 미사용). → 아래 enum→String 변경은 REST에 영향 없음.

---

## 핵심 설계 결정

### 결정 1 — `web`는 도메인의 "View 전용 facade(published port)"만 의존한다
서비스는 Entity를 반환하고 비공개 `service` 패키지에 있으므로 web이 직접 못 쓴다. 각 도메인이 **named interface(`{module}/spi`)에 View 전용 facade**를 노출하고 **DTO만 반환**한다. facade 구현체는 도메인 내부(비공개 `service` 패키지)에 두고 기존 Service에 위임한다. web은 facade 인터페이스와 DTO(named interface)만 참조한다.

- 근거: Web Module Contract(허용 의존 = published API/facade/port/DTO, 금지 = Entity/Repository/비공개 Service). `product/spi/UserDirectory` 선례와 동일 패턴.
- facade는 도메인이 **소유·구현**(member facade는 member가, product facade는 product가 구현) — `UserDirectory`(의존 역전 포트)와 달리 단순 published API다. 의존 방향 `web → {member,product}.spi/.dto` 단방향, 도메인은 web을 모름.

### 결정 2 — enum 필드는 facade 경계에서 String으로 변환한다
web이 도메인 enum(`Role`, `ProductStatus`)을 컴파일타임에 참조하면 `..domain..` 의존이 되어 위반이다. View 폼/조건의 enum 필드를 String으로 바꾸고 facade 구현이 String↔enum을 변환한다.
- `MemberSearchCondition.role`: `Role` → `String` (nullable, 빈값=전체). **View 전용**이라 REST 무영향.
- `ProductForm.status`: `ProductStatus` → `String`. **View 전용**이라 REST 무영향.
- `statuses` 모델: web이 `ProductStatus.values()`를 못 부르므로 facade가 `List<String> productStatusNames()` 제공.
- 템플릿은 이미 문자열 기반 렌더(사전 확정 사실) → 변경 불필요.

### 결정 3 — 폼/DTO는 도메인 `dto` 패키지에 유지하고 named interface로 노출한다
`SignupForm`/`MemberSearchCondition`/`MemberSummaryResponse`(member·dto), `ProductForm`/`CategoryResponse`(product·dto)를 web으로 옮기지 않는다. 옮기면 `SignupForm`이 의존하는 `MemberPasswordPolicy`·`@PasswordMatches`(member 내부)와 검증 테스트까지 연쇄 이동해 영향 범위가 과도해진다. 대신 `member/dto`·`product/dto`를 `@NamedInterface("dto")`로 노출하면 web이 참조 가능하다. enum 제거(결정 2) 후 web이 만지는 표면엔 도메인 타입이 없다.
- `getForEdit` 결과는 `ProductResponse`(record에 `ProductStatus` 노출)를 쓸 수 없으므로 **신규 View DTO `ProductFormView`**(status=String)를 `product/dto`에 추가한다.

### 결정 4 — `home` 모듈을 제거하고 홈 화면을 `web`으로 통합한다
`home`은 컨트롤러 1개짜리 화면 진입 모듈이다. 본 Task가 화면 진입점을 `web`으로 모으므로 `home`을 유지할 이유가 없다. `HomeViewController`를 `web/home`으로 이동하고 `com.shop.shop.home` 패키지를 제거한다. 결정 근거를 `web` package-info와 `package-structure-rule.md`에 명시한다.

### 결정 5 — actor(email→userId) 해석은 facade 구현 내부로 흡수한다
`SellerProductViewController`의 `userDirectory.findUserIdByEmail(...)` 호출을 facade 안으로 옮긴다. facade는 `actorEmail`(=`auth.getName()`)을 받고 구현체가 내부에서 기존 `UserDirectory`에 위임한다(product가 소유한 포트라 product 내부 사용 OK). web은 `UserDirectory`를 직접 참조하지 않고 `actorEmail`/`actorIsAdmin`만 넘긴다. `actorIsAdmin` 판정(ROLE_ADMIN authority 직접 보유)은 순수 Spring Security 로직이라 web에 잔존.

---

## 모듈/패키지 구조 (목표)

```
com.shop.shop.web                         # 신규 지원 모듈 (leaf, named interface 불필요)
├─ package-info.java                       # @ApplicationModule, 지원 모듈 문서 + home 통합 결정
├─ home/HomeViewController.java            # GET / → "home/home"
├─ member/
│  ├─ LoginViewController.java             # GET /login → "auth/login"
│  ├─ MemberSignupViewController.java      # MemberSignupFacade 사용
│  └─ AdminMemberViewController.java       # AdminMemberFacade 사용
└─ product/SellerProductViewController.java# SellerProductFacade 사용

com.shop.shop.member.spi                   # 신규 named interface ("spi")
├─ package-info.java                        # @NamedInterface("spi")
├─ MemberSignupFacade.java
└─ AdminMemberFacade.java
com.shop.shop.member.service               # facade 구현(비공개) — 기존 Service 위임
├─ MemberSignupFacadeImpl.java
└─ AdminMemberFacadeImpl.java
com.shop.shop.member.dto  (package-info에 @NamedInterface("dto") 추가)

com.shop.shop.product.spi                  # 기존 named interface ("spi")에 추가
├─ SellerProductFacade.java
└─ (UserDirectory 유지)
com.shop.shop.product.service              # facade 구현(비공개) — Service+UserDirectory 위임
└─ SellerProductFacadeImpl.java
com.shop.shop.product.dto  (package-info에 @NamedInterface("dto") 추가; ProductFormView 신규)
```

> `home` 패키지(`com.shop.shop.home`)는 제거한다.

---

## 인터페이스 계약 (backend ↔ view 정합 — 메인 에이전트 확정)

### member.spi
```java
public interface MemberSignupFacade {
    /** 회원가입. 실패 시 DuplicateEmailException(common) 전파. 반환값 없음(View는 미사용). */
    void signup(String email, String password, String name, String phone);
}
public interface AdminMemberFacade {
    /** role: null/빈값=전체. 반환은 DTO 페이지(Entity 금지). */
    org.springframework.data.domain.Page<MemberSummaryResponse>
        searchMembers(String keyword, String role, int page, int size);
    /** adminEmail→userId 해석 + role(String)→Role 변환 후 위임. 실패 시 BusinessException 전파. */
    void changeRole(String adminEmail, long targetMemberId, String role);
}
```
### product.spi
```java
public interface SellerProductFacade {
    java.util.List<CategoryResponse> listCategories();
    java.util.List<String> productStatusNames();              // ProductStatus.name() 목록
    long register(String actorEmail, Long categoryId, String name,
                  String description, java.math.BigDecimal basePrice);   // 신규 productId 반환
    ProductFormView getForEdit(String actorEmail, boolean actorIsAdmin, long productId); // 소유권 검사 포함
    void update(String actorEmail, boolean actorIsAdmin, long productId, Long categoryId,
                String name, String description, java.math.BigDecimal basePrice, String status);
}
```
### 신규 DTO (product.dto)
```java
public record ProductFormView(Long categoryId, String name, String description,
                              java.math.BigDecimal basePrice, String status) { /* Product Entity→View DTO 변환 정적 팩토리 */ }
```
### web 컨트롤러 모델 키 계약 (불변)
| 컨트롤러 | 모델 키 | 타입 |
|---|---|---|
| MemberSignup | `signupForm` | `SignupForm`(member.dto) |
| AdminMember | `members` / `searchCondition` | `Page<MemberSummaryResponse>` / `MemberSearchCondition`(role:String) |
| SellerProduct | `productForm` / `categories` / `statuses` / `productId` | `ProductForm`(status:String) / `List<CategoryResponse>` / `List<String>` / `long` |

---

## 권한/소유권 보존 (api-authorization-rule 준수)
- 인가는 기존 `SecurityConfig` View 체인(`/admin/**`=ADMIN, `/seller/**`=SELLER)에서 그대로 처리한다. 컨트롤러 이동만으로 경로 패턴·권한이 바뀌지 않음을 테스트로 단언한다.
- 소유권 검사(`ProductService.getForEdit/update`의 `checkOwnership`)는 facade 위임 경로에서 그대로 수행된다. facade는 `actorIsAdmin`을 전달해 ADMIN 스킵/일반 소유권 검사를 보존한다.
- 화면 분리로 최소 권한·소유권이 약화되지 않음: 권한별 접근(최소권한 200 / 하위권한 403 / 비인증 redirect) 및 타인 상품 404 테스트를 web 컨트롤러 위치에서 유지한다.

---

## 영향 범위

### 신규 파일
| 파일 | 담당 | 비고 |
|---|---|---|
| `web/package-info.java` | backend | `@ApplicationModule` 지원 모듈 선언 + home 통합/web 책임 문서 |
| `web/home/HomeViewController.java` | view | 기존 home 컨트롤러 이동 |
| `web/member/LoginViewController.java` | view | 이동 |
| `web/member/MemberSignupViewController.java` | view | 이동 + `MemberSignupFacade` 사용 |
| `web/member/AdminMemberViewController.java` | view | 이동 + `AdminMemberFacade` 사용, role String |
| `web/product/SellerProductViewController.java` | view | 이동 + `SellerProductFacade` 사용, status String |
| `member/spi/package-info.java` | backend | `@NamedInterface("spi")` |
| `member/spi/MemberSignupFacade.java` | backend | |
| `member/spi/AdminMemberFacade.java` | backend | |
| `member/service/MemberSignupFacadeImpl.java` | backend | `MemberService` 위임 |
| `member/service/AdminMemberFacadeImpl.java` | backend | `MemberService` 위임(email→id, String→Role, User→DTO 매핑) |
| `product/spi/SellerProductFacade.java` | backend | |
| `product/service/SellerProductFacadeImpl.java` | backend | `ProductService`/`CategoryService`/`UserDirectory` 위임 |
| `product/dto/ProductFormView.java` | backend | View 전용 DTO(status=String) |
| `test/.../web/.../WebModuleStructureTest.java` | backend | ArchUnit 방향 규칙 |
| facade 구현 단위 테스트(member/product) | backend | Mockito로 Service 위임/변환 검증 |

### 수정 파일
| 파일 | 담당 | 변경 | 보존 계약 |
|---|---|---|---|
| `member/dto/package-info.java` | backend | `@NamedInterface("dto")` 추가 | 기존 javadoc 유지 |
| `product/dto/package-info.java` | backend | `@NamedInterface("dto")` 추가 | |
| `member/dto/MemberSearchCondition.java` | backend | `Role role` → `String role` | getter/setter 명 유지(`getRole`/`setRole`) |
| `product/dto/ProductForm.java` | backend | `ProductStatus status` → `String status` | 필드명 `status` 유지, `@NotBlank` 등 검증은 등록/수정 분기 로직과 정합 |
| `ModularityTests.java` | backend | javadoc 모듈 목록 갱신(web 추가, home 제거) | `verify()` 유지 |
| `docs/rules/package-structure-rule.md` | backend | 지원 모듈 표: `home` 제거·`web` 추가, web 계약 문서화, `{module}/spi`에 View facade 용례 추가 | |

### 삭제 파일
| 파일 | 담당 |
|---|---|
| `home/controller/HomeViewController.java` (→ web 이동) | view |
| `member/controller/{Login,MemberSignup,AdminMember}ViewController.java` (→ web 이동) | view |
| `product/controller/SellerProductViewController.java` (→ web 이동) | view |

### 테스트 이동/수정 (view 담당, 일부 backend 보조)
> 핵심: facade는 기존 Service에 위임하므로, **full-context(@SpringBootTest)에서 Repository를 stub하던 기존 테스트의 호출 체인(controller→facade→service→repo)이 그대로 성립**한다. 따라서 대부분 패키지/임포트 정정 + 위치 이동으로 통과하며, Service를 직접 mock하던 부분만 facade mock으로 교체한다.
- 이동: `member/controller/MemberSignupViewControllerTest`, `member/controller/AdminMemberViewControllerTest`, `product/controller/SellerProductViewControllerTest` → `web/...` 테스트 패키지. View name·모델 키·권한·redirect·소유권 단언 유지.
- 렌더링 테스트(`view/SignupRenderingTest`, `view/AdminMembersRenderingTest`, `view/SellerProductFormRenderingTest`, `view/LayoutRenderingTest`): 그대로 유지하되 컨트롤러 이동/enum→String에 따른 임포트·stub만 정정.
- enum→String 영향: `ProductForm`/`MemberSearchCondition`를 직접 enum으로 세팅하던 테스트가 있으면 String으로 정정.

---

## 구조 검증 테스트 (task "권장 구조 테스트" 충족)
`WebModuleStructureTest`(ArchUnit, spring-modulith-starter-test 경유) + 기존 `ModularityTests.verify()` 이원화:
1. `..web..` 클래스가 `..member.domain..`/`..member.repository..`/`..member.service..`/`..product.domain..`/`..product.repository..`/`..product.service..`를 참조하지 않음.
2. `..member..`/`..product..`(및 기타 도메인) 클래스가 `..web..`를 참조하지 않음.
3. `web`이 도메인 Entity(`..domain..`)·Repository(`..repository..`)를 참조하지 않음(1과 중복이나 task 항목 명시 단언).
4. `ModularityTests.verify()`: named interface 경계 위반(web이 비노출 타입 참조) 시 실패 — 1차 가드.

> ArchUnit은 facade 구현이 `member/service`/`product/service`(비공개)에 있어도 web이 인터페이스(`spi`)만 import하므로 규칙 위반이 아님을 보장한다.

---

## View 렌더링 테스트 (task "권장 View 테스트" 충족)
이동 후 web 위치에서 다음을 유지/검증한다.
- 홈(`/` → home/home), 로그인(`/login` → auth/login), 회원가입(`/signup` → member/signup) 렌더링.
- 관리자 회원 관리(`/admin/members`): ADMIN 200 / 하위권한 403 / 비인증 redirect, role 필터·권한 변경 흐름.
- 판매자 상품 관리(`/seller/products/**`): SELLER 200 / CONSUMER 403 / 비인증 redirect / ADMIN 200(함의), 타인 상품 404(소유권), 검증 실패 재렌더·입력값 유지.

---

## 작업 순서 (subagent-rule: backend → view)
1. **backend-implementor**: named interface(package-info) + facade 인터페이스/구현 + `ProductFormView` + enum→String + `ModularityTests` javadoc + `WebModuleStructureTest` + facade 단위 테스트 + `package-structure-rule.md` 갱신. (web 컨트롤러는 만들지 않음 — 계약만 확정)
2. **view-implementor**: 5개 ViewController를 `web`으로 이동·facade 배선, `home` 패키지 제거, 컨트롤러/렌더링 테스트 이동·정정. 템플릿은 변경하지 않음(바인딩 호환).
3. **reviewer → fixer** 사이클(최대 3회): plan 기준 스타일/보안/버그 리뷰. PASS까지.
4. 검증: `cd shop-core && ./gradlew test` 전체 통과. Modularity/구조/렌더링 테스트 포함.

---

## 검증 기준 (Acceptance 매핑)
- `web` 지원 모듈 추가·문서화 → web/package-info + package-structure-rule.md.
- URL·View name 유지 → 보존 계약 + 렌더링 테스트.
- ViewController 5종 web 이동, Entity/Repository/비공개 Service 미참조 → 구조 테스트 1·2·3 + ModularityTests.
- 도메인 조회/명령은 facade(published port) 경유 → facade 계약.
- 도메인 모듈이 web 미의존, REST Controller 도메인 잔존 → 구조 테스트 2 + (REST 미이동).
- 권한별 접근·소유권 보존 → 권한/소유권 테스트.
- `./gradlew test` 통과.

---

## 리스크/주의
- `member/dto`·`product/dto` 전체를 named interface로 노출 → REST 요청 DTO까지 노출되나, DTO는 모듈 간 통용 통화라 수용 가능. web이 실제 참조하는 타입만 사용.
- enum→String 변경 시 기존 컨트롤러/테스트의 enum 직접 사용 누락 정정 필요(컴파일 에러로 조기 검출).
- `home` 제거 시 `com.shop.shop.home` 잔여 참조 없음 확인(현재 컨트롤러 1개뿐, 그 외 참조 없음 — 재확인 단계 포함).
- facade 구현을 `service`(비공개)에 두어 named interface 표면 최소화. `spi` 패키지엔 인터페이스만.

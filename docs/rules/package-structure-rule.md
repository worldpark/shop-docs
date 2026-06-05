# Package Structure Rule

## shop-core 도메인 모듈 목록 (정식 명칭)

도메인 모듈은 아래 6개로 고정한다. 패키지명은 표의 영문 소문자를 그대로 쓴다.

| 모듈(패키지) | 책임 | 비고 |
|---|---|---|
| `member` | 회원 가입·로그인·마이페이지 | |
| `product` | 상품 등록/수정(관리자), 목록·상세 | |
| `cart` | 장바구니 담기/조회/수정 | |
| `inventory` | 재고 조회·차감·복원 | |
| `order` | 주문 생성·확정, **배송 시작** | `OrderCompletedEvent`, `ShippingStartedEvent` 발행 |
| `payment` | 결제(모의 PG), 실패 처리 | `PaymentFailedEvent` 발행 |

- 배송은 별도 모듈이 아니라 `order` 모듈의 책임이다.
- 정당한 사유 없이 도메인 모듈을 추가하지 않는다(`docs/rules/forbidden-rule.md`).
- 모듈 공통/횡단 코드(예: `ObjectStorage`, `ErrorResponse`, `BaseEntity`)는 별도 공통 패키지에 두고 모듈 간 직접 의존으로 대체하지 않는다.

## shop-core 지원/횡단 모듈

현재 코드 기준으로 아래 지원/횡단 모듈도 Spring Modulith가 인식한다.
이 모듈들은 도메인 6개 목록에 포함하지 않는다.

| 모듈(패키지) | 책임 | 비고 |
|---|---|---|
| `common` | 공통 예외, BaseEntity, 공통 설정 | 횡단 공통 모듈 |
| `security` | Spring Security 설정 | 인증/인가 인프라 |
| `web` | Thymeleaf ViewController·ViewModel·Form·화면 조립 | SSR 화면 진입 전담. 도메인의 named interface(spi/dto)만 의존. 도메인 내부(Entity·Repository·비공개 Service) 직접 참조 금지. |
| `platform` | Outbox/Kafka 스모크 검증 | 한시적 인프라 검증 모듈 |

> `home` 모듈(홈 화면 ViewController 1개)은 `web` 모듈로 통합되어 제거된다(Task 003 view-implementor 단계).

## shop-core (모듈별 반복)
- `{module}/controller`
- `{module}/service`
- `{module}/repository`
- `{module}/domain` (entity)
- `{module}/dto`
- `{module}/event` (도메인 이벤트 정의)
- `{module}/messaging` (Kafka Producer)

## shop-core 모듈 간 통신 패키지 (선택 — 필요 시에만)

모듈 경계를 넘는 **동기 조회**가 꼭 필요할 때만 둔다. 통신 규칙은 `docs/rules/architecture-rule.md`("shop-core 모듈 간 통신")를 따른다. 모듈 간 통신은 우선 Spring Modulith 애플리케이션 이벤트로 하고, 동기 조회가 불가피할 때 아래 published port를 사용한다.

- `{module}/spi` — 해당 모듈이 노출하는 **published port(named interface)**. `package-info.java`에 `@NamedInterface`로 선언한다. 포트를 **소유한 모듈**이 인터페이스를 정의하고, 구현은 외부 모듈의 어댑터가 맡는다(의존 역전). 또한 **View 전용 facade(published API)** 인터페이스도 여기에 둔다 — web이 도메인 내부 Service를 직접 참조하지 않도록 도메인이 노출하는 얇은 facade. facade 구현체는 도메인 내부 `service` 패키지에 배치하고 `spi` 패키지에는 인터페이스만 둔다.
- `{module}/adapter` — 다른 모듈의 `spi` 포트를 **구현하는 어댑터**. 구현체를 **두는 모듈**이 소유하며, 대상 모듈의 비공개 구현(service/repository/domain)이 아니라 포트(인터페이스)만 의존한다. 모듈 경계를 넘는 데이터는 DTO/스칼라로 주고받고 Entity를 노출하지 않는다.

> 예(Task 009): `product/spi/UserDirectory`(@NamedInterface) ← `member/adapter/MemberUserDirectoryAdapter`. 의존 방향은 `member → product.spi` 단방향이며 `product`는 `member`를 참조하지 않는다(외부 서비스 분리 대비 의존 역전).

## notification
- `consumer` (Kafka Consumer)
- `service`
- `repository`
- `domain`
- `dto`

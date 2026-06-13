# Architecture — 쇼핑몰 시스템 (상위/전체)

> 이 문서는 두 Spring 프로젝트 **상위**의 시스템 아키텍처 SSOT다.
> 다루는 것: 프로젝트 구성, 책임 경계, 프로젝트 간 통신·계약.
> 다루지 않는 것: 각 프로젝트 내부 상세(모듈·레이어·클래스). 그건 각 프로젝트의 코드·컨벤션을 따른다(별도 내부 문서는 두지 않는다).
> 작업자가 지켜야 할 세부 구현 규칙은 `docs/rules/*rule.md`를 따른다.

## 1. 시스템 개요

- 독립 배포되는 두 개의 Spring Boot 프로젝트로 구성한다.
  - **shop-core**: 쇼핑몰 핵심. 회원·상품·장바구니·주문·결제·재고 (모듈러 모놀리스). Thymeleaf 기반 SSR 화면을 함께 호스팅한다.
  - **notification**: 알림 발송. shop-core 이벤트를 구독해 이메일·SMS·푸시 전송.
- 두 프로젝트는 **Kafka 이벤트로만, 단방향·비동기**로 연결된다. 동기 호출·DB 공유 없음.
- 목적: 포트폴리오. 명확한 서비스 경계 + 이벤트 드리븐을 시연.

## 2. 프로젝트 구성 / 레포 레이아웃

두 프로젝트는 **각각 독립된 프로젝트**다. 로컬에서는 이를 감싸는 **상위 워크스페이스 폴더**에 나란히 두고, 그 폴더에서 작업·하네스 실행을 한다.

```
shop/                            # 상위 루트 폴더 = 작업 위치 (가벼운 메타 레포)
├─ docs/
│  ├─ architecture.md            # (이 문서) 시스템 상위 SSOT
│  ├─ adr/                       # 주요 아키텍처 결정 기록
│  ├─ event-catalog.md           # 이벤트 페이로드 스키마 SSOT
│  └─ rules/                     # 작업자가 지켜야 할 세부 구현 규칙
├─ shop-core/                    # 별도 Git 레포 — 독립 빌드·배포
│  └─ ...
└─ notification/                 # 별도 Git 레포 — 독립 빌드·배포
   └─ ...
```

- `architecture.md`, `docs/`, `docs/rules/`는 어느 프로젝트 레포에도 속하지 않으므로 **상위 워크스페이스(메타 레포)에서 관리**한다.
- 프로젝트별 내부 문서는 두지 않는다. 내부 상세는 코드와 Spring Modulith 컨벤션으로 설명된다.
- 공유하는 것은 오직 **이벤트 계약(contract)**뿐이다. 코드·DB·트랜잭션은 공유하지 않는다.

## 3. 컴포넌트 / 책임 경계

| 프로젝트 | 책임 | 데이터 | 통신 역할 |
|---|---|---|---|
| shop-core | 거래 도메인 + Thymeleaf SSR UI, 도메인 이벤트 발행 | PostgreSQL (자기 소유) | Kafka **프로듀서** |
| notification | 알림 발송, 발송 이력 관리 | PostgreSQL (자기 소유) | Kafka **컨슈머** |

## 4. 통신 / 통합

- 채널: **Kafka**. shop-core가 발행자, notification이 구독자.
- 방향: **단방향**. notification → shop-core 역호출(REST/조회) 금지.
- 발행 신뢰성: shop-core는 **Transactional Outbox**(Spring Modulith Event Publication Registry)로 트랜잭션과 함께 저장 후 외부화.
- 소비 신뢰성: notification은 **멱등 소비 + 재시도 + DLQ**.
- 결합도: 두 프로젝트는 서로의 코드·스키마를 모른다. 이벤트 계약으로만 연결된다.

## 5. 이벤트 계약 (Contract)

- 이벤트 스키마는 **시스템의 공개 인터페이스**다. 어느 프로젝트 레포에도 속하지 않으므로 상위 워크스페이스의 `docs/`에서 단일 관리한다.
- 각 레포는 이 계약을 기준으로 자기 DTO를 둔다. 사이드 프로젝트 단계에선 공유 라이브러리 대신 계약을 보고 미러링하고, 계약 변경 시 양쪽을 동기화한다.
- **필드 레벨 페이로드 스키마(SSOT)는 `docs/event-catalog.md`** 에 있다. 이벤트 작성·변경 규칙은 `docs/rules/event-contract-rule.md`를 따른다.

### 토픽 / 이벤트 목록 (소유: shop-core)

| 토픽 이름 | 이벤트 타입 | 발행 시점 | 발행 모듈 | 소비자 |
|---|---|---|---|---|
| `order-completed` | `OrderCompletedEvent` | 주문 확정 | order | notification |
| `payment-failed` | `PaymentFailedEvent` | 결제 실패 | payment | notification |
| `order-cancelled` | `OrderCancelledEvent` | 주문 취소 | order | notification |
| `shipping-started` | `ShippingStartedEvent` | 배송 시작 | order(배송) | notification |

> 토픽 이름은 kebab-case, 이벤트 타입은 PascalCase 클래스명을 쓴다. 배송은 별도 모듈이 아니라 order 모듈의 책임이다. 각 이벤트의 필드·예시 JSON은 `docs/event-catalog.md` 참조.

## 6. 데이터 소유권

- 각 프로젝트는 **자기 PostgreSQL 인스턴스만** 소유한다. 공유 DB 금지(공유 데이터베이스 안티패턴).
- shop-core 도메인 데이터를 notification으로 복제·저장하지 않는다. 필요한 값은 이벤트 페이로드로 전달한다.
- notification은 발송 이력·멱등 체크 등 자기 책임 데이터만 저장한다.

## 7. 정적 자산 저장소

- 상품 이미지 등 정적 자산은 **현 단계에서는 shop-core 로컬 파일 시스템**에서 서빙한다.
- **추후 Cloudflare R2 + CDN**으로 이관 예정이며, 구현 교체가 가능해야 한다.
- 저장 key, URL 합성, 업로드 처리 등 세부 구현 규칙은 `docs/rules/static-asset-rule.md`를 따른다.
- 비공개 객체(영수증·증빙 등)는 현 단계 범위 밖. 도입 시 presigned URL 흐름을 인터페이스에 추가한다.

## 8. 배포 토폴로지

- shop-core: 앱 인스턴스 + PostgreSQL + 정적 자산 로컬 디스크 (이후 R2 + CDN).
- notification: 앱 인스턴스 + PostgreSQL + Kafka 컨슈머 그룹.
- Kafka: 단일 클러스터(개발 환경은 단일 브로커).
- 사이드 프로젝트 단계에서는 Eureka / API Gateway / Kubernetes 도입을 보류한다.

## 9. 시스템 불변 조건

- 두 프로젝트는 동일 DB를 공유하지 않는다.
- notification은 shop-core를 동기 호출하지 않는다 (단방향).
- 알림 실패가 주문·결제 흐름에 영향을 주지 않는다.
- 프로젝트 간 상호작용 채널은 Kafka 이벤트 하나뿐이다.

> 구현 단계의 금지 규칙은 `docs/rules/forbidden-rule.md`를 따른다.

## 10. 관련 ADR

- [ADR-001 — shop-core와 notification의 비동기 통합 경계](adr/001-shop-core-notification-async-boundary.md)
- [ADR-002 — Spring Modulith Event Publication Registry 기반 Transactional Outbox](adr/002-transactional-outbox-with-spring-modulith.md)
- [ADR-003 — shop-core를 Spring Modulith 모듈러 모놀리스로 구성](adr/003-spring-modulith-modular-monolith.md)
- [ADR-004 — 이벤트 계약을 상위 workspace 문서 SSOT로 관리](adr/004-workspace-level-event-contract-ssot.md)
- [ADR-005 — 현재는 DB 기반 동시성 제어를 우선하고 다중 노드 단계에서 Redisson을 도입](adr/005-database-first-concurrency-redisson-later.md)
- [ADR-006 — 정적 자산은 storage key만 저장하고 ObjectStorage 뒤에 둔다](adr/006-object-storage-key-and-local-first-assets.md)
- [ADR-007 — Flyway가 DB 스키마를 소유하고 Hibernate는 validate만 수행한다](adr/007-flyway-owned-schema-hibernate-validate.md)
- [ADR-008 — Playwright for Java와 외부 앱 타겟 방식으로 E2E 테스트를 구성](adr/008-playwright-java-e2e-external-app-target.md)

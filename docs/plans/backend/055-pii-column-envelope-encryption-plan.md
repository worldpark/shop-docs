# 055 Plan — PII 컬럼 봉투암호화 (JPA AttributeConverter / @Convert)

> 목표: shop-core DB의 평문 개인정보 컬럼을 `EnvelopeEncryptionUtils`(AES-256-GCM + AES Key Wrap, 봉투암호화) 기반으로 **저장 시 암호화 / 조회 시 복호화**한다.
> 방식: JPA `AttributeConverter`(`@Convert`)로 투명 적용 — 코드는 평문, DB는 암호문. 서비스 코드 무수정.
> 범위 가드: 검색/유니크에 쓰이는 `email`은 **제외**(블라인드 인덱스 별도 필요). 기존 평문 데이터 백필은 **범위 밖**(빈 DB 신규 배포 전제 — 테스트용).

## 0. 코드 대조 (확인됨)
- `common/crypto/EnvelopeEncryptionService`(@Component): `String encrypt(String)`/`String decrypt(String)` — KEK 파일(`CryptoProperties.kekFile`) 사용. AttributeConverter가 그대로 호출.
- `CryptoProperties`(record, `shop.crypto`): `Path kekFile`, **검증 없음**. `application.yml:177 kek-file: ${SHOP_CRYPTO_KEK_FILE}`(기본값 없음).
- **현재 @Convert/AttributeConverter 사용 0건** → 전 PII 평문.
- **대상 컬럼이 조회 조건/유니크에 미사용** 확인(Repository `findBy…` 0건, `@Query` WHERE 0건, 마이그레이션 UNIQUE/INDEX 없음) → 봉투암호화(비결정성) 적용해도 기능 무영향.
- 대상 컬럼 타입 전부 `text` → 암호문 길이 증가 무해.

## 1. 대상 컬럼 (엔티티 보유分만)
| 엔티티 | 필드(컬럼) |
|---|---|
| `member/domain/User` | `name`, `phone` (**email 제외**) |
| `order/domain/Order` | `shipRecipient`·`shipPhone`·`shipPostcode`·`shipAddress1`·`shipAddress2` |
| `payment/domain/Payment` | `pgTransactionId` |
| `member/domain/SellerApplication` | `businessRegistrationNumber`·`businessName`·`contactPhone` |
- **`addresses` 테이블**: JPA 엔티티 없음(legacy/스냅샷 경유) → @Convert 적용 불가, **스킵**(실데이터는 `orders.ship_*`로 스냅샷).
- 제외: `email`(검색/유니크), `last_login_at`(timestamp·정렬), `inventory_stock_ledger.actor_id`(FK·JOIN), `password_hash`(이미 BCrypt).

## 2. 구성 요소
- **신규 `common/crypto/EncryptedStringConverter`** (`@Converter` + `@Component`): `AttributeConverter<String,String>`.
  - 생성자 주입 `EnvelopeEncryptionService`(Spring Boot가 Hibernate에 빈 주입 — `hibernate.resource.beans.container` 기본 활성).
  - `convertToDatabaseColumn(String plain)`: `plain == null ? null : crypto.encrypt(plain)`.
  - `convertToEntityAttribute(String enc)`: `enc == null ? null : crypto.decrypt(enc)`.
  - **null 통과**(nullable 컬럼 ship_address2/phone/pg_transaction_id 대응).
- **대상 엔티티 필드에 `@Convert(converter = EncryptedStringConverter.class)`** 부착(+ 기존 `@Column` 유지).

## 3. ★ 테스트 KEK 주입 (필수 — 미적용 시 횡단 붕괴)
현재 풀 `@SpringBootTest`가 KEK 없이 그린인 건 "크립토를 호출하지 않아서"다. @Convert 도입 후엔 엔티티 저장/조회마다 `crypto.encrypt/decrypt`가 KEK를 읽으므로, **모든 통합 테스트에 유효 KEK 공급이 필요**.
- **방식**: `src/test/resources/test-kek.b64`(고정 Base64 AES-256 — **테스트 전용 비밀 아님, 커밋 가능**) 추가 + `src/test/resources/application.yml`에 `shop.crypto.kek-file: ${user.dir}/src/test/resources/test-kek.b64` 설정(Gradle test 작업 디렉터리=모듈 루트라 해석됨). 기존 test `application.yml` 있으면 **머지**(다른 키 보존).
- 단위 converter 테스트는 자체 KEK(tempDir)로 격리(기존 `EnvelopeEncryptionServiceTest` 패턴 재사용 가능).

## 4. 데이터 흐름
저장: `repo.save(order)` → Hibernate가 각 `@Convert` 필드에 `convertToDatabaseColumn` → `crypto.encrypt` → DB엔 `v1:iv:wrappedDek:cipher` 형식 암호문.
조회: DB 암호문 → `convertToEntityAttribute` → `crypto.decrypt` → 엔티티엔 평문. 서비스·뷰는 평문만 봄(무수정).

## 5. 예외 처리
- KEK 부재/오류 → `EnvelopeEncryptionService`가 `CryptoException` 전파(저장/조회 실패로 드러남 — fail-fast, 평문 유실 없음).
- null 필드 → 변환기 null 통과.
- 복호화 실패(손상 암호문/KEK 불일치) → `CryptoException`(조용한 평문화 금지 — forbidden-rule "조용한 데이터 유실" 회피).

## 6. 검증
- **단위**: `EncryptedStringConverter` 라운드트립(평문→암호문→평문), null 통과, 암호문이 평문과 다름.
- **통합(핵심)**: 대상 엔티티 1개 이상(예 Order)을 실DB(Testcontainers)에 save→find → **엔티티 필드 평문 복원** + **DB raw 컬럼은 암호문**(네이티브 쿼리로 `ship_phone`이 평문과 다름·`v1:`로 시작 확인). KEK 주입(§3)이 동작함을 실증.
- **회귀**: 대상 엔티티를 다루는 기존 통합 테스트(주문 생성·결제·판매자 신청·account)가 그린 — 횡단 KEK 주입 정상.
- **스키마 매핑**: 컬럼 타입 무변경(text)이라 `ddl-auto=validate` 무영향. 마이그레이션 추가 없음.
- 메인 게이트: Modulith verify + 풀 스위트 그린.

## 7. 트레이드오프 / 주의
- 봉투암호화 비결정성 → 대상 컬럼은 검색·유니크 불가(이미 미사용 확인). 향후 검색 필요해지면 블라인드 인덱스 별도.
- 기존 평문 데이터 백필은 범위 밖(신규/빈 DB 전제). 운영 데이터 있으면 일회성 마이그레이션 별 task.
- 암호문 오버헤드(수십~백 바이트) — text 컬럼이라 무해.
- 변환기 빈 주입: Spring Boot가 JPA 컨버터에 빈 주입 지원하나, 구현자는 통합 테스트로 실제 주입 동작 확인.

## 8. 오케스트레이션
1. backend-implementor: `EncryptedStringConverter` + 4개 엔티티 `@Convert` + 테스트 KEK(§3) + 단위/통합 테스트.
2. reviewer → (FAIL 시) fixer → 재리뷰. 중점: null 처리·KEK 테스트 주입·대상 컬럼 정확(email 제외)·복호화 실패 fail-fast·기존 테스트 무회귀.
3. 메인 게이트: Modulith verify + 풀 스위트.

## 9. 완료 조건
- [ ] `EncryptedStringConverter`(@Converter·@Component, null 통과) — `EnvelopeEncryptionService` 주입.
- [ ] User(name·phone)·Order(ship_* 5)·Payment(pg_transaction_id)·SellerApplication(business_registration_number·business_name·contact_phone)에 `@Convert`. **email 미적용.**
- [ ] 테스트 KEK 주입(`src/test/resources/test-kek.b64` + test `application.yml`) — 통합 테스트가 KEK로 동작.
- [ ] 통합 테스트: 엔티티 평문 복원 + DB raw 암호문 실증.
- [ ] Modulith verify + 풀 스위트 그린(횡단 무회귀).

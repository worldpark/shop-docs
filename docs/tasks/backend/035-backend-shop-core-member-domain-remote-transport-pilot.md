# 035. shop-core member 도메인 원격 전송 파일럿 — member 경계 포트의 REST 전환

> 출처: `shop.domains.*.separated` 도메인 통신 추상화 이니셔티브(2026-06-15)의 **첫 도메인 적용**. 공통 전송 토글 기반(034)을 **member 도메인**에 실제 적용해, member가 제공하는 경계 spi 포트를 `shop.domains.member.separated` 플래그에 따라 **in-process ↔ REST**로 전환한다. **실제 서비스/DB 분리는 하지 않는다**(공유 DB·단일 배포물 유지 — 원격 경로 실증·패턴 확립이 목적).

## Target
shop-core (member 도메인 경계 포트 + 034 공통 전송 기반 적용)

> **member가 제공하는 경계 포트의 REST 원격 어댑터 + 내부 엔드포인트에 한정**한다. 다른 도메인(product/cart/order/payment/inventory) 적용은 후속(이 파일럿 패턴 복제). member 도메인 기능 자체(가입·로그인·계정)는 무변경. 데이터/DB 분리·서비스 추출 범위 밖.

## 선행 의존
- **034(전송 토글 기반)** 완료 전제: 플래그 기반 빈 선택 메커니즘, 공통 REST 클라이언트, 내부 서비스 API 보안/에러 매핑 인프라.

---

## Goal
`shop.domains.member.separated=true`면 다른 모듈이 member로 들어오는 경계 호출이 **REST(내부 API)** 로 처리되고, `false`(기본)면 **기존 in-process 어댑터(DB 직접 조회)** 로 처리된다. 두 모드의 결과(이메일→userId 해석, 연락처/표시명 조회)는 **동일**하다. member를 첫 도메인으로 삼아 원격 전송 패턴(원격 어댑터 + 내부 엔드포인트 + 플래그 배선 + 양모드 테스트)을 확립한다.

## Context (member 경계 포트 — 코드 대조)
- member는 식별/연락처 **제공자**다. 다른 모듈이 member로 들어오는 경계 호출(동기 읽기):
  - `product/spi/UserDirectory.findUserIdByEmail(email)` ← `member/adapter/MemberUserDirectoryAdapter`(현재 member DB 직접 조회). 소비처: product(예: `ReviewFacadeImpl`의 email→userId 해석), View facade 등.
  - `product/spi/ReviewerDirectory.maskedDisplayNamesByUserId(userIds)` ← `member/adapter/MemberReviewerDirectoryAdapter`(IN 배치 + 이메일 로컬파트 마스킹, member 측 수행). 소비처: product(리뷰 작성자 표시명).
  - `member/spi/MemberDirectory.findContactByUserId(userId)`(→ `MemberContact{email,name}`) ← member 내부 구현. 소비처: member 외부에서 연락처가 필요한 지점.
- 모두 **동기 읽기**라 원격 전송은 **REST**가 적합(034 규칙: 동기=REST). 비동기 이벤트는 본 Task 무관.
- **공유 DB·단일 배포물**: 원격 어댑터는 member 내부 REST 엔드포인트로 루프백 호출(같은 앱·같은 DB). 분리하지 않음 — 원격 경로 실증·패턴 확립이 목적.
- **마스킹 책임 유지**: `ReviewerDirectory`의 이메일 마스킹은 member 측에서 수행(원본 email 비노출). REST 응답도 **마스킹된 표시명만** 반환(개인정보 보호 — `api-authorization-rule`).
- **의존 역전 유지**: 원격 어댑터도 기존과 같이 상대 모듈(member)이 product.spi를 구현하는 방향을 지킨다(ModularityTests 무위반).

## API Authorization
> `docs/rules/api-authorization-rule.md` 준수. member 내부 서비스 API는 **외부 비노출 내부 전용**(034가 정한 `/internal/**` 보안 규약·서비스 인증 적용). 일반 사용자/브라우저 접근 차단. 응답에 **email 원문·전화 등 민감정보 비노출**(표시명은 마스킹, 연락처 포트는 내부 전용·최소 노출).

## Requirements
- **원격 어댑터 추가(member 제공 포트)**: `product/spi/UserDirectory`, `product/spi/ReviewerDirectory`, `member/spi/MemberDirectory` 각각에 대해 **REST 호출 원격 어댑터 빈**을 추가한다. `shop.domains.member.separated=true`면 원격 빈, `false`(기본)면 기존 in-process 어댑터가 활성(034 빈 선택 메커니즘 사용, 포트당 활성 1개).
- **member 내부 REST 엔드포인트**: 위 읽기들을 내부 전용으로 노출(email→userId, 연락처, 마스킹 표시명 배치). 외부 비노출·서비스 인증. 마스킹은 응답 생성 시 member 측 수행.
- **양모드 동치**: `separated=false`/`true`에서 동일 결과. 특히 (a) email→userId 해석, (b) 표시명 마스킹(IN 배치·email 원문 미노출), (c) 연락처 조회가 두 모드 동일.
- **에러 환원**: 원격 실패(미존재/타임아웃/4xx·5xx)가 in-process와 동일한 의미(예: 미해석 시 동일 빈 결과/예외)로 호출측에 전달(034 에러 매핑 재사용).
- **관측**: member 경계 호출이 원격 경로로 갔는지 로깅(민감정보 제외).

## Constraints
- **member 기능 무변경**: 가입·로그인·계정 self-service·비밀번호 재설정 등 member 자체 로직 불변. 본 Task는 **경계 제공 포트의 전송 경로 추가**만.
- **결과 동일성**: 두 모드 동작 결과 동일(전송만 다름). in-process 기본 경로 무변경.
- **공유 DB·트랜잭션 경계 무변경**: 데이터 분리·분산 트랜잭션 도입 금지. 원격은 읽기 조회.
- **개인정보 보호**: REST 응답에 email 원문/전화 노출 금지(표시명은 마스킹, 연락처는 내부 전용 최소 노출). 기존 마스킹 규약 유지.
- **모듈/계약 규칙**: spi 인터페이스 무변경(구현만 추가). `package-structure-rule`·ModularityTests·의존 역전 무위반. 이벤트/notification 무변경.
- **과설계 금지**: member 경계 포트에 필요한 최소만. 서킷브레이커·캐시·디스커버리 미도입(후속).

## Files
> 정확 경로/배치는 plan 확정. 아래는 예시.
- (신규) `member/adapter/remote/RemoteMemberUserDirectoryAdapter.java` — `product/spi/UserDirectory` REST 구현(`separated=true` 활성).
- (신규) `member/adapter/remote/RemoteMemberReviewerDirectoryAdapter.java` — `product/spi/ReviewerDirectory` REST 구현.
- (신규) `member/adapter/remote/RemoteMemberDirectoryAdapter.java` — `member/spi/MemberDirectory` REST 구현(소비 컨텍스트에서 플래그로 선택).
- (수정) 기존 `member/adapter/MemberUserDirectoryAdapter`·`MemberReviewerDirectoryAdapter` 등 — in-process 빈에 `separated=false` 활성 조건 부여(034 메커니즘).
- (신규) `member/controller/internal/MemberInternalRestController.java`(또는 034 규약 경로) — email→userId, 연락처, 마스킹 표시명 배치 내부 엔드포인트.
- (신규) member 내부 API 요청/응답 DTO(마스킹된 표시명·내부 전용).
- (재사용) 034 공통 REST 클라이언트·빈 선택·내부 API 보안·에러 매퍼, 기존 member 서비스/리포지토리(원격 엔드포인트가 내부에서 호출), `shop.domains.member.separated` 플래그.
- (재사용·무변경) spi 포트 인터페이스, 이벤트/notification, 마이그레이션.

## Acceptance Criteria
- `shop.domains.member.separated=false`(기본)에서 기존 in-process 어댑터로, `=true`에서 **REST 원격 어댑터**로 member 경계 호출이 처리되며 **결과가 동일**하다(양모드 통합 테스트).
- 리뷰 작성자 표시명이 두 모드 모두 **마스킹**되고 응답 어디에도 email 원문이 없다.
- email→userId 해석·연락처 조회가 두 모드 동일 결과.
- member 내부 REST API가 외부(브라우저/일반 사용자)에 노출되지 않는다.
- member 자체 기능(가입/로그인/계정)·이벤트·notification·ModularityTests 무변경. `./gradlew test` 풀 그린.

## Test
- **단위(Mockito)**: 원격 어댑터가 REST 클라이언트 응답을 spi 반환 계약으로 올바로 변환(마스킹·배치·미존재 처리). 빈 선택 조건(`separated` true/false) 분기.
- **통합(Testcontainers·MockMvc)**: `separated=false`/`true` 양모드에서 (a) email→userId, (b) 마스킹 표시명 배치(email 비노출), (c) 연락처 조회가 동일 결과. member 내부 API 보안(외부 접근 차단) 검증.
- **회귀**: 리뷰(032)·계정(029) 등 member 경계를 쓰는 흐름이 양모드에서 그린. ModularityTests 그린. `./gradlew test` 풀 그린.

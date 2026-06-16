# 042. 로그인 활동 추적 (last_login_at) — 통계 대시보드 선행작업

> 출처: 사용자 요청 — admin 통계 대시보드의 "유저 이용률"을 **접속 기반(B안)** 으로 산출하기 위한 **선행 인프라**. 현재 로그인/접속 추적 데이터가 전혀 없음(last_login·세션·로그인이력 부재).
> 본 Task는 **추적 인프라만** 구축한다. 이용률 집계·화면은 Task 043(대시보드)에서 이 데이터를 소비한다.

## 배경 / 갭 (실사 확정)
- `users`(member 모듈)에 가입일(created_at)·상태(ACTIVE/WITHDRAWN, V6)는 있으나 **마지막 로그인/접속 추적 컬럼 없음**.
- 로그인 경로가 **둘**: ① REST/JWT `AuthRestController.login → AuthServiceResponse.login`, ② 화면 formLogin(`SecurityConfig` formLogin, `MemberUserDetailsService` 공용 UserDetailsService). **둘 다 기록해야** 누락이 없다.
- 전역 KST 결정(ADR-009, V7) — 타임스탬프는 앱의 시스템 시계(KST) 사용.

## Target / Goal
회원이 **로그인에 성공할 때마다 `users.last_login_at`을 현재 시각으로 갱신**한다. REST·formLogin **두 경로 모두** 기록한다. 집계/화면은 비범위(043). 본 Task로 "접속 기반 이용률"의 데이터 토대를 만든다.

## 범위 (Scope) — backend-implementor
### 1. 스키마 (Flyway V9)
- `users`에 `last_login_at timestamptz NULL` 추가(다음 번호 = V9). 기존 행은 NULL(소급 불가 — 알려진 한계).
- 인덱스: 30일 윈도우 카운트 쿼리 대비 `last_login_at`에 인덱스(선택 — 회원 규모 작으면 생략 가능, plan에서 판단).

### 2. 엔티티
- `member/domain/User.java`에 `Instant lastLoginAt`(또는 프로젝트 시간 타입 관례) 필드 + `recordLogin(Instant now)` 의도 메서드(Setter 금지, 기존 of/update 패턴). smallint/timestamp 매핑은 기존 컬럼 관례 따름.

### 3. 기록 로직 (한 곳에 모으고 두 경로에서 호출)
- member에 로그인 기록 진입점 1개: 예 `member` 서비스/facade의 `recordLogin(email 또는 userId)` — 해당 회원 조회 후 `recordLogin(now)`. `@Transactional`(쓰기). 시각은 앱 Clock(KST).
- **REST 경로**: `AuthServiceResponse.login(...)` 성공 직후(토큰 발급 시점) 위 진입점 호출.
- **formLogin 경로**: 커스텀 `AuthenticationSuccessHandler` **또는** `ApplicationListener<AuthenticationSuccessEvent>`(security/web)로 성공 시 위 진입점 호출. **plan에서 확정**: 이벤트 리스너 1개로 REST·formLogin을 모두 커버할 수 있는지(REST 로그인이 AuthenticationManager를 거치면 이벤트가 양쪽에서 발생 → 단일 리스너로 통합 가능; 수동 검증이면 REST는 서비스에서 직접 호출). 어느 쪽이든 **두 경로 모두 빠짐없이** 기록할 것.
- 비밀번호 검증 **성공 시에만** 기록(실패/탈퇴 차단된 로그인은 미기록). 가상스레드 대비: 블로킹 DB write는 Service 경계에 둠(ThreadLocal 직접 사용 금지).

### 4. 조회 토대 (선택, 043에서 써도 됨)
- `MemberRepository.countByStatusAndLastLoginAtAfter(status, threshold)` 등 30일 윈도우 카운트의 기반 메서드를 본 Task에 둘지 043에 둘지는 plan에서 결정(본 Task는 "기록"이 핵심, 카운트는 043 소비처와 함께 둬도 무방).

## Non-goals
- 이용률 **집계·화면**(Task 043).
- 로그인 이벤트 이력 테이블(DAU/MAU·추세) — 본 Task는 단일 `last_login_at` 스냅샷만. 추세가 필요해지면 별도 후속.
- 과거 로그인 소급(backfill) — 불가(기존 데이터 없음). 배포 후 점진 채움(한계 문서화).

## 검증
- 단위/통합: **REST 로그인** 성공 시 `last_login_at` 갱신, **formLogin** 성공 시 갱신(둘 다). 로그인 실패·탈퇴 차단 시 미갱신. Testcontainers로 실제 컬럼 갱신 1케이스.
- 스키마 매핑 검증(Entity ↔ Flyway 정합, schema-mapping-validation-rule).
- 회귀: 로그인 플로우(REST 토큰 발급·formLogin 302) 비파괴.
- 풀 스위트 + (해당 시) 풀 컨텍스트 테스트 영향 확인.

## 참고 (실사)
- 로그인: `member/controller/AuthRestController.java:37`, `member/service/AuthServiceResponse.java:42`(REST), `security/SecurityConfig.java:204`(formLogin, loginProcessingUrl), `member/service/MemberUserDetailsService.java`(공용 UserDetails, 탈퇴 차단 findActiveByEmail).
- 엔티티/스키마: `member/domain/User.java`, `db/migration/`(최신 V8 → 신규 V9). 전역 KST V7/ADR-009.
- 후속 소비처: Task 043 admin 통계 대시보드(유저 이용률 = 최근 30일 접속 회원 / 전체 활성 회원).

# 001 — E2E 테스트 전략: Playwright for Java (외부 앱 타겟 / A 방식)

- 작성일: 2026-06-07
- 상태: 확정 (구현 완료)
- 범위: shop-core 브라우저 종단(E2E) 테스트 도입 및 방향 결정

---

## 1. 배경

shop-core는 **Thymeleaf 서버사이드 렌더링 + Spring Security(폼 로그인/CSRF/세션)** 기반이라,
폼 바인딩·리다이렉트·세션 흐름의 통합 동작은 단위/슬라이스 테스트로는 끝까지 검증되지 않는다.
실제로 직전 작업에서 상품목록 쿼리의 `bytea` 오류는 단위·통합 테스트를 모두 통과하고도
**실제 화면 렌더링 경로에서만** 드러났다 — 풀스택 회귀를 잡는 얇은 E2E 레이어의 필요성을 보여준 사례다.

초기에는 별도 Node.js 디렉터리(`/e2e`)에 Playwright(JS)로 1건(`signup-login.spec.js`)이 구성되어 있었다.
이를 점검하면서 두 가지 결정이 필요했다.

1. **바인딩**: JS Playwright vs Playwright for Java
2. **앱 기동 방식**: 외부에 떠 있는 앱에 접속(A) vs 테스트가 앱+인프라를 직접 기동(B)

---

## 2. 결정 요약

| 항목 | 결정 | 근거(요약) |
|---|---|---|
| 바인딩 | **Playwright for Java** | Java/Gradle/JUnit/Testcontainers로 툴체인 일원화. 엔진·로케이터·웹-퍼스트 assertion은 JS판과 동일해 능력 손실 없음 |
| 기동 방식 | **A — 외부 앱 타겟** (`SHOP_CORE_BASE_URL`, 기본 `http://localhost:8080`) | 상시 테스트 서버가 존재하는 전제에서 가장 충실도 높고 비용 낮음. B의 자기완결 기동 이점이 무의미해짐 |

> **핵심 원칙:** E2E의 목적은 "실제로 배선된 시스템의 통합 충실도" 검증이다.
> 테스트 서버라는 완전 배선 환경이 있으면, 그것을 가리키는 A가 정석이다.

---

## 3. 바인딩 결정 — JS vs Java

모든 Playwright 언어 바인딩은 **동일 엔진·동일 드라이버**를 쓴다. 브라우저 자동화 능력 차이는 없다.

- **잃는 것은 능력이 아니라 "JS 전용 테스트 러너(`@playwright/test`)의 편의기능"**:
  `webServer` 자동기동, 내장 retry/병렬/sharding, `playwright.config.js` projects, 실패 시 자동 trace/screenshot,
  HTML 리포트 — 이들은 JUnit5/Gradle 등가물로 대체한다.
- **유지하는 것**: `getByRole`/`getByLabel`/`getByText`, auto-waiting,
  웹-퍼스트 assertion(`PlaywrightAssertions.assertThat(...)`), 타임아웃/스크린샷/trace/네트워크 가로채기 — 전부 동일 제공.
- **부수 이점**: 레포에서 npm/package.json 제거. (내부적으로 번들된 Node 드라이버는 Gradle 의존성이 관리 — 개발자가 Node 툴체인을 다룰 일 없음.)

### 이식 중 실제로 드러난 함정 (회귀 가치 있음)
- `Pattern.quote()`가 만드는 **`\Q...\E`** 구문은 금지. Playwright는 Java `Pattern`을 내부 **JavaScript 정규식**으로
  변환하는데 JS 정규식은 `\Q...\E`를 지원하지 않아 매치가 깨진다.
- 대안: 와일드카드 없는 URL은 정확 문자열 매칭(`hasURL("...")`), 특수문자는 JS 호환 정규식
  (`Pattern.compile("/login\\?signup")`)을 사용한다.

---

## 4. 기동 방식 트레이드오프 — A vs B (vs C)

### A. 외부 앱 접속 (채택)
- 테스트는 실행 중인 앱의 URL만 안다. 브라우저만 테스트가 소유한다.

### B. `@SpringBootTest(RANDOM_PORT)` + Testcontainers 자동기동
- 테스트가 in-process 임베디드 서버 + 컨테이너(Postgres/Redis/Kafka)를 직접 띄운다.

### C. docker-compose 기반 (A의 자동화 형태)
- CI에서 실제 이미지 빌드 → compose로 app+infra 기동 → Playwright 접속. 최고 충실도, 최고 비용.

| 기준 | A. 외부 앱 | B. @SpringBootTest + TC |
|---|---|---|
| 자기완결성 | ✗ 앱·DB·Redis·Kafka 사전 기동 필요 | ✅ `e2eTest` 하나로 전부 |
| CI 재현성 | △ compose+health-wait 별도 | ✅ Docker만 있으면 동일 |
| 데이터 격리 | ✗ 공유 DB row 누적 | ✅ 매 런 새 컨테이너 |
| 실패 재현 | ✗ 동일 외부 환경 필요 | ✅ 테스트가 환경 동반 |
| 검증 대상 | ✅ **실제 기동 아티팩트**(staging 가능) | △ in-process(테스트 classpath/config) |
| 기동 의존성 부담 | 낮음 | **높음(특히 Kafka 컨테이너)** |
| 속도/자원 | ✅ 앱 이미 떠 있음 | ✗ 매 런 full context + 컨테이너 |
| 코드 복잡도 | ✅ 단순 | ✗ `@DynamicPropertySource`·autoconfigure 리셋 |
| 환경 유연성 | ✅ 임의 URL 타게팅 | ✗ 자기 자신만 |

### 이 프로젝트 특유의 B 딜레마 (Postgres + Redis + Kafka)
shop-core는 기동 시 3종 인프라에 묶인다(특히 **Kafka — Modulith 이벤트 externalization**).
- **B를 충실하게(Kafka·Redis까지)** → 진짜에 가깝지만 Kafka 컨테이너가 느리고 무겁다.
- **B를 가볍게(Kafka off + Postgres만)** → 빠르지만 이벤트 발행 경로 미검증 → **A보다 충실도가 낮아지는 역설**.

→ 테스트 서버가 존재하면 이 딜레마 자체가 사라진다. **A가 맞다.**

---

## 5. A 채택의 결정 근거 (테스트 서버 전제)

상시 테스트 서버가 있으면:
1. 그 서버가 **완전 배선된 실제 환경** = 최고 충실도. B의 in-process 서버는 패키징·이미지·실데이터 위 Flyway·외부 config를 검증 못 한다.
2. B의 유일한 강점(자기완결 기동)이 **무의미**해지고, 매 런 컨테이너 재기동 비용만 남는다.
3. 기존 인프라 투자 재사용. e2e용 Testcontainers 배선 유지보수 불필요.
4. `SHOP_CORE_BASE_URL`만 바꿔 CI·로컬·staging 어디든 동일 테스트 실행.

---

## 6. 운영 시 주의 (A + 공유 테스트 서버)

A를 **공유** 서버에 물릴 때의 본질적 리스크. 도입·확장 시 반드시 지킬 규율.

### 6.1 공유 가변 상태 — 격리/정리
- 테스트는 **자기 데이터를 직접 생성**한다(시드 가정 금지). 현재 회원가입 테스트는 `System.currentTimeMillis()` 기반 유니크 이메일 사용.
- 공유 데이터에 **파괴적 단언/변경 금지**.
- e2e 데이터(유저/주문 등)가 누적되므로 **주기적 리셋 또는 self-cleaning** 전략 필요.
- 동시 실행 레이스 방지를 위해 런별 유니크 prefix(네임스페이스) 권장.

### 6.2 버전 스큐 — "무엇을 게이트하나"
테스트 서버는 보통 main/develop 배포본을 돈다. 목적에 따라 적합성이 갈린다.

| 목적 | 테스트 서버(A)로 충분? |
|---|---|
| 배포 후 스모크 / 회귀 / 환경 검증 | ✅ A가 정답 |
| 머지 전 그 PR 브랜치 코드 게이트 | ❌ 서버엔 그 코드 없음 → PR 검증 불가 |

→ per-PR로 **미머지 코드**를 게이트해야 한다면, 그때만 "PR을 임시 환경에 배포 후 A 실행"(ephemeral) 또는 compose 기동(C)이 의미를 가진다. 이것이 B/ephemeral이 남는 유일한 자리다.

---

## 7. 테스트 레이어 분담 (중복 방지)

| 레이어 | 도구 | 책임 |
|---|---|---|
| 단위 | JUnit5 + Mockito | 도메인/서비스 로직 |
| 슬라이스·통합 | `@DataJpaTest` + **Testcontainers(PostgreSQL)** | DB 고유 동작·SQL 회귀 (예: `bytea` NULL 파라미터) |
| 종단(E2E) | **Playwright for Java (A)** | 브라우저로 핵심 사용자 여정(회원가입→로그인→홈) |

> DB 단위의 격리·재현은 이미 Testcontainers 통합 테스트가 책임진다.
> E2E는 그 층을 떠안지 않고, **얇은 핵심 여정 스모크**로 유지한다. 폼 검증·권한 분기 등 세부는 MockMvc/슬라이스로 커버한다.

---

## 8. 구현 내용

### 8.1 구성 (`shop-core`)
- **소스셋**: `src/e2eTest/java` — 일반 `test`와 분리. `check`/`test`에 **포함되지 않음**(인프라 비의존 원칙 보존; `check --dry-run`으로 확인).
- **의존성**: `com.microsoft.playwright:playwright:1.52.0` (`e2eTestImplementation`)
- **Gradle 태스크**:
  - `installPlaywrightBrowsers` — Java용 Chromium 설치(최초 1회). JS판과 별개 빌드 사용.
  - `e2eTest` — E2E 실행. 실행 중인 앱 필요.
- **실패 산출물**: `build/e2e-artifacts/<클래스>_<메서드>.png` + `-trace.zip` (gitignore된 `build/` 하위)

### 8.2 파일
| 파일 | 역할 |
|---|---|
| `shop-core/build.gradle` | e2eTest 소스셋·의존성·태스크 추가 |
| `src/e2eTest/java/com/shop/shop/e2e/AuthJourneyE2eTest.java` | 인증 핵심 여정 스모크 — 회원가입→로그인, 로그인 실패, 로그아웃·세션 종료 |
| `src/e2eTest/java/com/shop/shop/e2e/support/PlaywrightArtifactsExtension.java` | 실패 시 스크린샷·trace 캡처(JS 러너 자동 캡처 대체) |
| `src/e2eTest/java/com/shop/shop/e2e/support/PlaywrightPageHolder.java` | Extension이 page/context에 접근하는 계약 |
| `src/e2eTest/README.md` | 실행 절차·주의사항 |

### 8.3 제거
- Node.js `/e2e` 디렉터리 (untracked 상태였음)
- 루트 `.gitignore`의 `e2e/node_modules` 등 obsolete 항목 정리 (E2E 산출물은 `build/`로 커버)

---

## 9. 실행 방법

```bash
# 1) 브라우저 설치 (최초 1회)
./gradlew installPlaywrightBrowsers

# 2) 인프라 + 앱 기동 (또는 테스트 서버 URL 사용)
docker compose -f docker/shop/docker-compose.yml up -d
SHOP_SECURITY_JWT_SECRET=... ./gradlew bootRun     # shop-core

# 3) E2E 실행 (대상은 SHOP_CORE_BASE_URL, 기본 localhost:8080)
./gradlew e2eTest
# 테스트 서버 타겟 예: SHOP_CORE_BASE_URL=https://test.example.com ./gradlew e2eTest
```

검증 완료: 실제 앱(`localhost:8080`, PostgreSQL 16.4) 대상으로 `e2eTest` 통과 확인(2026-06-07).

---

## 10. 후속 과제 (열려 있음)

- **CI 파이프라인**: 테스트 서버 URL을 시크릿/프로파일로 주입하는 `e2eTest` 스텝. post-merge 스모크로 우선 배치.
- **데이터 정리 전략**: e2e 계정/데이터 누적에 대한 주기적 리셋 또는 self-cleaning.
- **런별 네임스페이스**: 동시 실행 충돌 방지용 유니크 prefix 헬퍼.
- **여정 확장**: 상품 목록/상세, 장바구니 담기 등 핵심 경로 점진 추가(얇게 유지).
- **(조건부) per-PR 게이트**: 미머지 코드 검증이 필요해지면 ephemeral 환경 배포 또는 compose 기동(C) 도입 검토.

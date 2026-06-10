# ADR-009 — Playwright for Java와 외부 앱 타겟 방식으로 E2E 테스트를 구성

- 작성일: 2026-06-10
- 상태: Accepted
- 범위: shop-core E2E 테스트

## 맥락

`shop-core`는 Thymeleaf SSR, Spring Security form login, CSRF, session 기반 화면 흐름을 제공한다. 단위 테스트와 MockMvc/슬라이스 테스트만으로는 실제 브라우저에서 폼 바인딩, redirect, 세션, 렌더링이 함께 동작하는지 끝까지 확인하기 어렵다.

초기에는 Playwright JavaScript 구성이 있었지만, 프로젝트의 주 툴체인은 Java, Gradle, JUnit 5, Testcontainers다. 또한 E2E 테스트가 앱과 인프라를 직접 띄울지, 이미 떠 있는 앱을 대상으로 할지 결정해야 했다.

검토한 대안은 다음과 같다.

| 대안 | 장점 | 단점 |
|---|---|---|
| Playwright JS | 생태계와 러너 편의기능 풍부 | Node/npm 툴체인 추가 관리 필요 |
| Playwright for Java | Java/Gradle/JUnit 툴체인 일원화 | JS 전용 runner 편의기능 일부를 직접 구성해야 함 |
| 테스트가 앱과 인프라 직접 기동 | 자기완결성 높음 | PostgreSQL, Redis, Kafka 전체 기동 비용과 복잡도 큼 |
| 외부 앱 타겟 | 실제 배선된 서버를 검증, 단순하고 빠름 | 앱/인프라 사전 기동 필요, 공유 상태 관리 필요 |

## 결정

E2E 테스트는 Playwright for Java를 사용하고, 외부에 실행 중인 앱을 대상으로 한다.

- 기본 대상 URL은 `SHOP_CORE_BASE_URL`로 주입한다.
- 기본값은 로컬 `http://localhost:8080`이다.
- E2E source set은 일반 `test`와 분리한다.
- `test`/`check`는 인프라 비의존 원칙을 유지한다.
- E2E는 얇은 핵심 사용자 여정 스모크로 유지한다.

## 결과

긍정적 결과:

- Java/Gradle/JUnit 중심의 테스트 툴체인을 유지한다.
- 실제 기동된 앱, 실제 Spring Security, 실제 Thymeleaf 렌더링을 브라우저로 검증한다.
- Kafka/Redis/PostgreSQL을 매 E2E 실행마다 Testcontainers로 띄우는 부담을 피한다.
- 같은 테스트를 로컬, 테스트 서버, staging URL에 재사용할 수 있다.

부정적 결과와 대응:

- 외부 앱과 인프라가 떠 있어야 한다.
  - E2E는 `test`/`check`에 포함하지 않고 명시적으로 실행한다.
- 공유 테스트 서버를 대상으로 하면 데이터가 누적될 수 있다.
  - 테스트 데이터는 런별 유니크 값을 사용하고, 파괴적 단언을 피한다.
- PR별 미머지 코드 검증에는 외부 shared 서버 방식이 맞지 않을 수 있다.
  - 필요 시 ephemeral 환경 배포 또는 compose 기반 실행을 별도 전략으로 추가한다.
- Playwright Java에서 Java `Pattern.quote()`의 `\Q...\E`는 JS 정규식 변환과 맞지 않는다.
  - URL 매칭은 정확 문자열 또는 JS 호환 정규식을 사용한다.

## 관련 문서

- `docs/plans/performance/001-e2e-playwright-java-test-strategy.md`
- `docs/local-e2e.md`
- `shop-core/src/e2eTest/README.md`

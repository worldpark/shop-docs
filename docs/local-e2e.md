# Local Web E2E

shop-core를 띄우고 실제 Thymeleaf 화면을 **Playwright for Java**로 열어 브라우저 동작을 검증하는 하네스.

> 방식 결정(외부 앱 타겟 = A 방식)·트레이드오프는 `docs/plans/performance/001-e2e-playwright-java-test-strategy.md`,
> 실행 절차 상세·주의사항은 `shop-core/src/e2eTest/README.md`가 단일 출처(SSOT)다. 이 문서는 로컬 실행 진입점만 안내한다.
>
> (구 Node.js `e2e/` + npm 구성은 Playwright for Java로 이관되어 제거되었다.)

## Prerequisites

- Docker Desktop 실행 중 (PostgreSQL/Redis/Kafka)
- Java 21 (Gradle toolchain)
- 최초 1회 브라우저 설치: `./gradlew installPlaywrightBrowsers` (스크립트 사용 시 자동)

## Run (script)

워크스페이스 루트에서:

```powershell
.\scripts\run-shop-core-e2e.ps1
```

스크립트는 `docker/shop/docker-compose.yml`을 기동하고, `local` 프로파일로 `shop-core`를 실행한 뒤
`/login`이 뜰 때까지 대기하고, Playwright Java용 브라우저 설치 후 `./gradlew e2eTest`를 실행한다.

변형:

```powershell
.\scripts\run-shop-core-e2e.ps1 -SkipInfra        # 인프라 기동 생략
.\scripts\run-shop-core-e2e.ps1 -KeepAppRunning   # 종료 후 앱 유지
.\scripts\run-shop-core-e2e.ps1 -BaseUrl http://localhost:8080
```

## Manual Run

```powershell
# 1) 인프라
docker compose -f docker/shop/docker-compose.yml up -d

# 2) 앱 (shop-core) — local 프로파일
cd shop-core
.\gradlew.bat bootRun --args="--spring.profiles.active=local"
```

다른 터미널에서:

```powershell
cd shop-core
.\gradlew.bat installPlaywrightBrowsers   # 최초 1회
.\gradlew.bat e2eTest                     # 대상: SHOP_CORE_BASE_URL (기본 http://localhost:8080)
```

- 다른 환경 타겟: `$env:SHOP_CORE_BASE_URL="https://test.example.com"; .\gradlew.bat e2eTest`
- 실패 산출물: `shop-core/build/e2e-artifacts/<클래스>_<메서드>.png` 및 `-trace.zip`
  (`npx playwright show-trace <파일>` 또는 https://trace.playwright.dev)

## Current Smoke Flow

- `/signup` 열기
- 유니크 사용자 생성
- `/login?signup` 리다이렉트 확인
- 렌더된 로그인 폼으로 로그인
- 인증된 `/` 접근 확인

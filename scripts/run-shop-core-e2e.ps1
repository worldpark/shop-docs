param(
    [string] $BaseUrl = "http://localhost:8080",
    [switch] $SkipInfra,
    [switch] $KeepAppRunning
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$composeFile = Join-Path $root "docker/shop/docker-compose.yml"
$shopCoreDir = Join-Path $root "shop-core"
$gradleWrapper = Join-Path $shopCoreDir "gradlew.bat"
$logsDir = Join-Path $root "build/e2e"
$appOutLog = Join-Path $logsDir "shop-core.out.log"
$appErrLog = Join-Path $logsDir "shop-core.err.log"

New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

if (-not $SkipInfra) {
    docker compose -f $composeFile up -d
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose failed with exit code $LASTEXITCODE"
    }
}

$env:SPRING_PROFILES_ACTIVE = "local"
$env:SHOP_CORE_BASE_URL = $BaseUrl

$process = Start-Process `
    -FilePath "cmd.exe" `
    -ArgumentList "/c", "`"$gradleWrapper`" bootRun --args=--spring.profiles.active=local" `
    -WorkingDirectory $shopCoreDir `
    -RedirectStandardOutput $appOutLog `
    -RedirectStandardError $appErrLog `
    -WindowStyle Hidden `
    -PassThru

try {
    $deadline = (Get-Date).AddMinutes(3)
    do {
        Start-Sleep -Seconds 2
        try {
            $response = Invoke-WebRequest -Uri "$BaseUrl/login" -UseBasicParsing -TimeoutSec 5
            if ($response.StatusCode -eq 200) {
                break
            }
        } catch {
            if ($process.HasExited) {
                throw "shop-core exited before becoming ready. See $appOutLog and $appErrLog"
            }
        }
    } while ((Get-Date) -lt $deadline)

    if ((Get-Date) -ge $deadline) {
        throw "Timed out waiting for shop-core at $BaseUrl. See $appOutLog and $appErrLog"
    }

    Push-Location $shopCoreDir
    try {
        # Playwright Java용 Chromium 설치 (이미 설치돼 있으면 빠르게 통과 — 멱등)
        & $gradleWrapper installPlaywrightBrowsers
        if ($LASTEXITCODE -ne 0) {
            throw "playwright browser install failed with exit code $LASTEXITCODE"
        }
        # E2E 실행 — 대상은 위에서 설정한 $env:SHOP_CORE_BASE_URL
        & $gradleWrapper e2eTest
        if ($LASTEXITCODE -ne 0) {
            throw "Playwright e2eTest failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
} finally {
    if (-not $KeepAppRunning -and -not $process.HasExited) {
        taskkill /PID $process.Id /T /F | Out-Null
    }
}

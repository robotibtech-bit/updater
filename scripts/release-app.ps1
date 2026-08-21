<#
관리 대상 앱 하나를 release 서명으로 빌드해 릴리스하고 apps.json 카탈로그를 자동으로
동기화합니다.

정책(2026-08-21): 이 스크립트는 항상 Release 빌드만 만듭니다. GitHub Release와
apps.json에는 Release APK만 올라갑니다 — Debug 빌드는 로컬 개발/테스트 전용이며 이
스크립트가 다루지 않습니다.

Release 서명 키는 이 저장소 어디에도 없습니다 — 아래 네 환경변수로만 전달받습니다:
  IB_RELEASE_STORE_FILE      release keystore 파일의 전체 경로
  IB_RELEASE_STORE_PASSWORD  keystore 비밀번호
  IB_RELEASE_KEY_ALIAS       key alias
  IB_RELEASE_KEY_PASSWORD    key 비밀번호
네 값 중 하나라도 없으면 이 스크립트는 빌드를 시도하지 않고 즉시 중단합니다. 대상
프로젝트의 build.gradle.kts에도 같은 조건의 방어 로직이 있어(assembleRelease 자체가
실패), 이 스크립트를 건너뛰고 gradlew를 직접 돌려도 동일하게 막힙니다. 어느 경우든
새 키를 임의로 만들지 않습니다.

사용 예 (IB 앱 새 버전 배포 — 실제 회사 release 키 환경변수를 먼저 설정해 둔 뒤):
  .\release-app.ps1 -AppId ib-library -DisplayName "IB 도서관 안내" `
      -ProjectDir C:\KSH\IB -GitHubRepo robotibtech-bit/IB `
      -ReleaseNote "행사 URL 인앱 웹뷰, 예절/추천 게임 추가"

동작 순서:
  1. release 서명 환경변수 4종이 모두 있는지 확인 (없으면 즉시 중단)
  2. 대상 프로젝트의 build.gradle.kts에서 applicationId / versionCode / versionName을 읽음 (읽기 전용, 수정 없음)
  3. -SkipBuild 없으면 해당 프로젝트에서 assembleRelease 실행
  4. 빌드된 APK를 apksigner로 서명 검증 — 서명이 없거나 검증 실패면 중단(게시 안 함).
     -ExpectedReleaseSha256을 지정했으면 인증서 지문이 그 값과 정확히 일치하는지도 확인.
  5. GitHub 릴리스를 태그(v버전명)로 생성하거나, 이미 있으면 자산을 덮어쓰기 업로드
  6. updater 저장소의 apps.json에서 appId가 같은 항목을 갱신(없으면 새로 추가)
  7. apps.json 변경사항을 커밋하고 (-SkipPush 없으면) push

이 스크립트는 대상 앱의 build.gradle.kts를 읽기만 하고 절대 수정하지 않습니다.
#>
param(
    [Parameter(Mandatory = $true)][string]$AppId,
    [Parameter(Mandatory = $true)][string]$DisplayName,
    [Parameter(Mandatory = $true)][string]$ProjectDir,
    [Parameter(Mandatory = $true)][string]$GitHubRepo,
    [Parameter(Mandatory = $true)][string]$ReleaseNote,
    [string]$ModuleDir = "app",
    [string]$JavaHome = "C:\Program Files\Android\Android Studio\jbr",
    [string]$UpdaterRepoDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    # release 인증서 SHA-256 지문을 알고 있으면 지정 — 서명은 됐지만 "엉뚱한" 키로 서명된
    # APK가 배포되는 걸 막는 마지막 방어선이다. 콜론 없이 대소문자 무관하게 비교한다.
    [string]$ExpectedReleaseSha256,
    [switch]$SkipBuild,
    [switch]$SkipPush
)

# 콘솔이 한글을 깨진 코드페이지로 표시하는 걸 방지 — 기능에는 영향 없지만(git/파일 쓰기는
# 이미 UTF-8) 사람이 읽는 오류 메시지가 알아볼 수 있어야 "배포 중단 후 알림"이 실효성이 있다.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Fail($message) {
    Write-Host "오류: $message" -ForegroundColor Red
    exit 1
}

function Get-GradleValue([string]$content, [string]$pattern, [string]$fieldName) {
    $m = [regex]::Match($content, $pattern)
    if (-not $m.Success) { Fail "build.gradle.kts에서 $fieldName 값을 찾지 못했습니다." }
    return $m.Groups[1].Value
}

# 0. release 서명 환경변수 확인 — 하나라도 없으면 빌드를 시도조차 하지 않는다(정책:
#    새 키를 임의로 만들지 않고, 배포를 중단한 뒤 알린다).
$releaseEnvNames = @("IB_RELEASE_STORE_FILE", "IB_RELEASE_STORE_PASSWORD", "IB_RELEASE_KEY_ALIAS", "IB_RELEASE_KEY_PASSWORD")
$missingEnv = $releaseEnvNames | Where-Object { [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) }
if ($missingEnv.Count -gt 0) {
    Fail "Release 서명 키 환경변수가 없습니다: $($missingEnv -join ', ') — 정해진 회사 Release 키를 준비해 이 값들을 설정한 뒤 다시 시도하세요. 새 키를 임의로 만들지 않습니다."
}

# 1. gradle에서 버전 정보 읽기 (읽기 전용)
$gradleFile = Join-Path $ProjectDir "$ModuleDir\build.gradle.kts"
if (-not (Test-Path $gradleFile)) { Fail "build.gradle.kts를 찾을 수 없습니다: $gradleFile" }
$gradleContent = Get-Content $gradleFile -Raw

$packageName = Get-GradleValue $gradleContent 'applicationId\s*=\s*"([^"]+)"' "applicationId"
$versionCode = Get-GradleValue $gradleContent 'versionCode\s*=\s*(\d+)' "versionCode"
$versionName = Get-GradleValue $gradleContent 'versionName\s*=\s*"([^"]+)"' "versionName"

Write-Host "== $AppId ($packageName) v$versionName (code $versionCode) [RELEASE] ==" -ForegroundColor Cyan

# 2. 빌드 (release 전용)
$releaseOutputDir = Join-Path $ProjectDir "$ModuleDir\build\outputs\apk\release"
if (-not $SkipBuild) {
    Write-Host "-- Release APK 빌드 중..."
    Push-Location $ProjectDir
    $env:JAVA_HOME = $JavaHome
    & .\gradlew.bat ":${ModuleDir}:assembleRelease" --console=plain
    $buildExit = $LASTEXITCODE
    Pop-Location
    if ($buildExit -ne 0) { Fail "gradle release 빌드 실패 (exit $buildExit) — 위 Gradle 출력에 원인이 있습니다." }
}
if (-not (Test-Path $releaseOutputDir)) { Fail "release 출력 폴더를 찾을 수 없습니다: $releaseOutputDir (경로가 다르면 -ModuleDir을 확인하세요)" }
$apkCandidates = Get-ChildItem $releaseOutputDir -Filter "*.apk" -File
if ($apkCandidates.Count -eq 0) { Fail "release 출력 폴더에 APK가 없습니다: $releaseOutputDir" }
if ($apkCandidates.Count -gt 1) { Fail "release 출력 폴더에 APK가 여러 개 있습니다(${$apkCandidates.Count}개) — 이전 빌드 찌꺼기를 정리한 뒤 다시 시도하세요: $releaseOutputDir" }
$apkPath = $apkCandidates[0].FullName

# 3. 서명 검증 — 서명이 없거나(디버그 키 등 실수로 붙었거나) 검증 실패면 절대 배포하지 않는다.
Write-Host "-- APK 서명 검증 중... ($apkPath)"
$sdkRoot = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "Android\Sdk" } else { $null }
$apksigner = $null
if ($sdkRoot -and (Test-Path (Join-Path $sdkRoot "build-tools"))) {
    $buildToolsDir = Get-ChildItem (Join-Path $sdkRoot "build-tools") -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if ($buildToolsDir) {
        $candidate = Join-Path $buildToolsDir.FullName "apksigner.bat"
        if (Test-Path $candidate) { $apksigner = $candidate }
    }
}
if (-not $apksigner) { Fail "apksigner.bat을 찾을 수 없습니다(Android SDK build-tools 확인 필요) — 서명 검증 없이는 배포하지 않습니다." }

$env:JAVA_HOME = $JavaHome
$verifyOutput = & $apksigner verify --print-certs $apkPath 2>&1
$verifyExit = $LASTEXITCODE
Write-Host $verifyOutput
if ($verifyExit -ne 0) { Fail "APK 서명 검증에 실패했습니다(unsigned 이거나 손상된 APK일 수 있습니다) — 배포를 중단합니다." }

$sha256Line = $verifyOutput | Select-String "SHA-256 digest:\s*([0-9a-fA-F]+)"
if (-not $sha256Line) { Fail "서명은 됐지만 apksigner 출력에서 SHA-256 지문을 읽지 못했습니다 — 배포를 중단합니다." }
$actualSha256 = $sha256Line.Matches[0].Groups[1].Value.ToLowerInvariant()
Write-Host "-- 서명 인증서 SHA-256: $actualSha256"

if ($ExpectedReleaseSha256) {
    $expected = $ExpectedReleaseSha256.Replace(":", "").ToLowerInvariant()
    if ($actualSha256 -ne $expected) {
        Fail "서명 인증서가 기대한 값과 다릅니다. 기대: $expected / 실제: $actualSha256 — 잘못된 키로 서명됐을 수 있어 배포를 중단합니다."
    }
    Write-Host "-- 서명 인증서가 -ExpectedReleaseSha256과 일치합니다."
}

# 4. 릴리스 자산 준비
$tag = "v$versionName"
$assetName = "$AppId-$versionName.apk"
$assetPath = Join-Path $env:TEMP $assetName
Copy-Item $apkPath $assetPath -Force

# 5. GitHub 릴리스 생성 또는 자산 업로드
Write-Host "-- GitHub 릴리스 확인 중... ($GitHubRepo $tag)"
gh release view $tag --repo $GitHubRepo *> $null
$releaseExists = ($LASTEXITCODE -eq 0)

if ($releaseExists) {
    Write-Host "-- 기존 릴리스에 자산 업로드(덮어쓰기)..."
    gh release upload $tag $assetPath --repo $GitHubRepo --clobber
    if ($LASTEXITCODE -ne 0) { Fail "gh release upload 실패" }
} else {
    Write-Host "-- 새 릴리스 생성..."
    gh release create $tag $assetPath --repo $GitHubRepo --title $tag --notes $ReleaseNote
    if ($LASTEXITCODE -ne 0) { Fail "gh release create 실패" }
}

$apkUrl = "https://github.com/$GitHubRepo/releases/download/$tag/$assetName"

# 6. apps.json 갱신
$catalogPath = Join-Path $UpdaterRepoDir "apps.json"
if (-not (Test-Path $catalogPath)) { Fail "apps.json을 찾을 수 없습니다: $catalogPath" }
Write-Host "-- 카탈로그 갱신 중... ($catalogPath)"

$catalog = Get-Content $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json
$appsList = New-Object System.Collections.ArrayList
if ($catalog.apps) { foreach ($a in $catalog.apps) { [void]$appsList.Add($a) } }

$newEntry = [ordered]@{
    appId       = $AppId
    displayName = $DisplayName
    packageName = $packageName
    versionCode = [int64]$versionCode
    versionName = $versionName
    apkUrl      = $apkUrl
    releaseNote = $ReleaseNote
}

$existingIndex = -1
for ($i = 0; $i -lt $appsList.Count; $i++) {
    if ($appsList[$i].appId -eq $AppId) { $existingIndex = $i; break }
}
if ($existingIndex -ge 0) {
    $appsList[$existingIndex] = $newEntry
    Write-Host "-- 기존 '$AppId' 항목을 갱신했습니다."
} else {
    [void]$appsList.Add($newEntry)
    Write-Host "-- 새 '$AppId' 항목을 추가했습니다."
}

$outObject = [ordered]@{ apps = $appsList }
$json = $outObject | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($catalogPath, $json, (New-Object System.Text.UTF8Encoding($false)))

# 7. 커밋 + push
Push-Location $UpdaterRepoDir
git add apps.json
git commit -m "apps.json 갱신: $AppId $versionName"
$commitExit = $LASTEXITCODE
if ($commitExit -ne 0) {
    Write-Host "-- 커밋할 변경 사항이 없습니다 (이미 최신 상태일 수 있음)."
} elseif (-not $SkipPush) {
    git push origin main
    if ($LASTEXITCODE -ne 0) { Pop-Location; Fail "git push 실패" }
} else {
    Write-Host "-- -SkipPush 지정됨: 커밋만 하고 push는 하지 않았습니다."
}
Pop-Location

Write-Host "== 완료 ==" -ForegroundColor Green
Write-Host "appId=$AppId packageName=$packageName versionCode=$versionCode versionName=$versionName"
Write-Host "apkUrl=$apkUrl"
Write-Host "signerSha256=$actualSha256"

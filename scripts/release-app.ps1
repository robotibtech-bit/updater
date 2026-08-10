<#
관리 대상 앱 하나를 릴리스하고 apps.json 카탈로그를 자동으로 동기화합니다.

사용 예 (IB 앱 새 버전 배포):
  .\release-app.ps1 -AppId ib-library -DisplayName "IB 도서관 안내" `
      -ProjectDir C:\KSH\IB -GitHubRepo robotibtech-bit/IB `
      -ReleaseNote "행사 URL 인앱 웹뷰, 예절/추천 게임 추가"

동작 순서:
  1. 대상 프로젝트의 build.gradle.kts에서 applicationId / versionCode / versionName을 읽음 (읽기 전용, 수정 없음)
  2. -SkipBuild 없으면 해당 프로젝트에서 assembleDebug 실행
  3. GitHub 릴리스를 태그(v버전명)로 생성하거나, 이미 있으면 자산을 덮어쓰기 업로드
  4. updater 저장소의 apps.json에서 appId가 같은 항목을 갱신(없으면 새로 추가)
  5. apps.json 변경사항을 커밋하고 (-SkipPush 없으면) push

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
    [switch]$SkipBuild,
    [switch]$SkipPush
)

function Fail($message) {
    Write-Host "오류: $message" -ForegroundColor Red
    exit 1
}

function Get-GradleValue([string]$content, [string]$pattern, [string]$fieldName) {
    $m = [regex]::Match($content, $pattern)
    if (-not $m.Success) { Fail "build.gradle.kts에서 $fieldName 값을 찾지 못했습니다." }
    return $m.Groups[1].Value
}

# 1. gradle에서 버전 정보 읽기 (읽기 전용)
$gradleFile = Join-Path $ProjectDir "$ModuleDir\build.gradle.kts"
if (-not (Test-Path $gradleFile)) { Fail "build.gradle.kts를 찾을 수 없습니다: $gradleFile" }
$gradleContent = Get-Content $gradleFile -Raw

$packageName = Get-GradleValue $gradleContent 'applicationId\s*=\s*"([^"]+)"' "applicationId"
$versionCode = Get-GradleValue $gradleContent 'versionCode\s*=\s*(\d+)' "versionCode"
$versionName = Get-GradleValue $gradleContent 'versionName\s*=\s*"([^"]+)"' "versionName"

Write-Host "== $AppId ($packageName) v$versionName (code $versionCode) ==" -ForegroundColor Cyan

# 2. 빌드
$apkPath = Join-Path $ProjectDir "$ModuleDir\build\outputs\apk\debug\$ModuleDir-debug.apk"
if (-not $SkipBuild) {
    Write-Host "-- 디버그 APK 빌드 중..."
    Push-Location $ProjectDir
    $env:JAVA_HOME = $JavaHome
    & .\gradlew.bat ":${ModuleDir}:assembleDebug" --console=plain
    $buildExit = $LASTEXITCODE
    Pop-Location
    if ($buildExit -ne 0) { Fail "gradle 빌드 실패 (exit $buildExit)" }
}
if (-not (Test-Path $apkPath)) { Fail "빌드된 APK를 찾을 수 없습니다: $apkPath (경로가 다르면 -ModuleDir을 확인하세요)" }

# 3. 릴리스 자산 준비
$tag = "v$versionName"
$assetName = "$AppId-$versionName.apk"
$assetPath = Join-Path $env:TEMP $assetName
Copy-Item $apkPath $assetPath -Force

# 4. GitHub 릴리스 생성 또는 자산 업로드
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

# 5. apps.json 갱신
$catalogPath = Join-Path $UpdaterRepoDir "apps.json"
if (-not (Test-Path $catalogPath)) { Fail "apps.json을 찾을 수 없습니다: $catalogPath" }
Write-Host "-- 카탈로그 갱신 중... ($catalogPath)"

$catalog = Get-Content $catalogPath -Raw | ConvertFrom-Json
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

# 6. 커밋 + push
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

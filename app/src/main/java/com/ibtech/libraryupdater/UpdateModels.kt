package com.ibtech.libraryupdater

/** apps.json 카탈로그의 앱 한 항목. */
data class AppCatalogEntry(
    val appId: String,
    val displayName: String,
    val packageName: String,
    val versionCode: Long,
    val versionName: String,
    val apkUrl: String,
    val releaseNote: String,
)

data class InstalledAppInfo(val versionCode: Long, val versionName: String)

enum class AppInstallState { NOT_INSTALLED, UPDATE_AVAILABLE, UP_TO_DATE }

/** 카탈로그 한 항목 + 이 태블릿에 실제 설치된 상태를 합친 화면용 모델. */
data class ManagedAppUiState(
    val entry: AppCatalogEntry,
    val installed: InstalledAppInfo?,
    val state: AppInstallState,
    val isDownloading: Boolean = false,
    val downloadPercent: Int = 0,
    val errorMessage: String? = null,
) {
    /** 새로 설치하는 경우와 업데이트하는 경우 모두 같은 다운로드 동작이라 하나로 취급한다. */
    val canInstallOrUpdate: Boolean
        get() = !isDownloading && state != AppInstallState.UP_TO_DATE
}

enum class CatalogLoadState { LOADING, LOADED, ERROR }

data class ManagerUiState(
    val loadState: CatalogLoadState = CatalogLoadState.LOADING,
    val apps: List<ManagedAppUiState> = emptyList(),
    val statusMessage: String = "",
    val canInstallPackages: Boolean = false,
)

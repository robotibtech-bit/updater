package com.ibtech.libraryupdater

import android.app.Application
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class UpdaterViewModel(application: Application) : AndroidViewModel(application) {
    private val repository = UpdateRepository(application)
    private val _uiState = MutableStateFlow(ManagerUiState())
    val uiState: StateFlow<ManagerUiState> = _uiState.asStateFlow()

    init {
        refreshInstallPermission()
        checkForUpdates()
    }

    fun refreshInstallPermission() {
        _uiState.update { it.copy(canInstallPackages = getApplication<Application>().packageManager.canRequestPackageInstalls()) }
    }

    /** 카탈로그를 새로 받아 목록 전체(설치 여부 포함)를 다시 계산한다. */
    fun checkForUpdates() {
        viewModelScope.launch {
            _uiState.update { it.copy(loadState = CatalogLoadState.LOADING, statusMessage = "앱 목록을 확인하고 있습니다.") }
            runCatching {
                withContext(Dispatchers.IO) {
                    val catalog = repository.fetchCatalog()
                    catalog.map { entry ->
                        val installed = repository.getInstalledInfo(entry.packageName)
                        val state = when {
                            installed == null -> AppInstallState.NOT_INSTALLED
                            entry.versionCode > installed.versionCode -> AppInstallState.UPDATE_AVAILABLE
                            else -> AppInstallState.UP_TO_DATE
                        }
                        ManagedAppUiState(entry = entry, installed = installed, state = state)
                    }
                }
            }.onSuccess { apps ->
                _uiState.update {
                    it.copy(loadState = CatalogLoadState.LOADED, apps = apps, statusMessage = "")
                }
            }.onFailure { error ->
                _uiState.update {
                    it.copy(loadState = CatalogLoadState.ERROR, statusMessage = error.toUserMessage("앱 목록 확인"))
                }
            }
        }
    }

    /**
     * [appId]의 앱을 내려받아 설치 화면을 연다. 이미 설치돼 있으면 업데이트로, 없으면 신규
     * 설치로 동작한다 — Android 설치 절차 자체는 두 경우가 같다(같은 packageName이면 덮어쓰기,
     * 없으면 새로 설치).
     */
    fun downloadAndInstall(appId: String, onInstallReady: (Intent) -> Unit) {
        val app = _uiState.value.apps.firstOrNull { it.entry.appId == appId } ?: return
        if (!app.canInstallOrUpdate) return
        if (!_uiState.value.canInstallPackages) {
            updateApp(appId) { it.copy(errorMessage = "설치하려면 '알 수 없는 앱 설치' 권한이 필요합니다.") }
            return
        }

        viewModelScope.launch {
            updateApp(appId) { it.copy(isDownloading = true, downloadPercent = 0, errorMessage = null) }
            runCatching {
                withContext(Dispatchers.IO) {
                    repository.downloadApk(app.entry) { percent ->
                        updateApp(appId) { it.copy(downloadPercent = percent) }
                    }
                }
            }.onSuccess { apk ->
                val context = getApplication<Application>()
                val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", apk)
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                updateApp(appId) { it.copy(isDownloading = false) }
                onInstallReady(intent)
            }.onFailure { error ->
                updateApp(appId) { it.copy(isDownloading = false, errorMessage = error.toUserMessage("APK 다운로드")) }
            }
        }
    }

    private fun updateApp(appId: String, transform: (ManagedAppUiState) -> ManagedAppUiState) {
        _uiState.update { state ->
            state.copy(
                apps = state.apps.map { if (it.entry.appId == appId) transform(it) else it }
            )
        }
    }

    fun installPermissionIntent(): Intent = Intent(
        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
        Uri.parse("package:${getApplication<Application>().packageName}"),
    )
}

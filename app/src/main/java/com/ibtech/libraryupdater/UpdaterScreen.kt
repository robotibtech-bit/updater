package com.ibtech.libraryupdater

import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@Composable
fun UpdaterScreen(
    viewModel: UpdaterViewModel,
    onOpenInstallPermission: () -> Unit,
    onInstallApk: (Intent) -> Unit,
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(modifier = Modifier.fillMaxSize()) {
            Column(modifier = Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("아이비테크 앱 관리", fontSize = 28.sp, fontWeight = FontWeight.Bold)
                Text(
                    "설치되지 않은 앱은 설치하고, 이미 설치된 앱은 새 버전이 있는지 확인합니다.",
                    fontSize = 15.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                if (!state.canInstallPackages) {
                    Text("APK를 설치하려면 '알 수 없는 앱 설치' 권한이 필요합니다.", fontSize = 15.sp)
                    OutlinedButton(onClick = onOpenInstallPermission, modifier = Modifier.fillMaxWidth().height(52.dp)) {
                        Text("설치 권한 설정")
                    }
                }

                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedButton(
                        onClick = viewModel::checkForUpdates,
                        enabled = state.loadState != CatalogLoadState.LOADING,
                        modifier = Modifier.height(48.dp)
                    ) { Text("새로고침") }
                    if (state.loadState == CatalogLoadState.LOADING) {
                        CircularProgressIndicator(modifier = Modifier.height(24.dp))
                    }
                    if (state.loadState == CatalogLoadState.ERROR) {
                        Text(state.statusMessage, color = MaterialTheme.colorScheme.error, fontSize = 14.sp)
                    }
                }
            }

            LazyColumn(
                contentPadding = PaddingValues(horizontal = 24.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
                modifier = Modifier.fillMaxSize()
            ) {
                items(state.apps, key = { it.entry.appId }) { app ->
                    AppRow(
                        app = app,
                        canInstallPackages = state.canInstallPackages,
                        onInstallOrUpdate = {
                            viewModel.downloadAndInstall(app.entry.appId, onInstallApk)
                        }
                    )
                }
            }
        }
    }
}

@Composable
private fun AppRow(
    app: ManagedAppUiState,
    canInstallPackages: Boolean,
    onInstallOrUpdate: () -> Unit,
) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)) {
        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(app.entry.displayName, fontSize = 20.sp, fontWeight = FontWeight.Bold)

            InfoRow("현재 버전", app.installed?.let { "${it.versionName} (${it.versionCode})" } ?: "설치되지 않음")
            InfoRow("최신 버전", "${app.entry.versionName} (${app.entry.versionCode})")

            Text(text = statusLabel(app.state), fontSize = 15.sp, color = statusColor(app.state))

            if (app.entry.releaseNote.isNotBlank()) {
                Text(app.entry.releaseNote, fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }

            if (app.isDownloading) {
                Text("다운로드 중... ${app.downloadPercent}%", fontSize = 15.sp)
                LinearProgressIndicator(
                    progress = { app.downloadPercent / 100f },
                    modifier = Modifier.fillMaxWidth().height(8.dp),
                )
            }

            if (app.errorMessage != null) {
                Text(app.errorMessage, fontSize = 14.sp, color = MaterialTheme.colorScheme.error)
            }

            if (app.state != AppInstallState.UP_TO_DATE) {
                Button(
                    onClick = onInstallOrUpdate,
                    enabled = app.canInstallOrUpdate && canInstallPackages,
                    modifier = Modifier.fillMaxWidth().height(48.dp)
                ) {
                    Text(if (app.state == AppInstallState.NOT_INSTALLED) "설치" else "업데이트")
                }
            }
        }
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, fontSize = 14.sp, fontWeight = FontWeight.Medium)
    }
}

private fun statusLabel(state: AppInstallState): String = when (state) {
    AppInstallState.NOT_INSTALLED -> "설치 가능"
    AppInstallState.UPDATE_AVAILABLE -> "업데이트 가능"
    AppInstallState.UP_TO_DATE -> "최신 버전입니다."
}

@Composable
private fun statusColor(state: AppInstallState) = when (state) {
    AppInstallState.NOT_INSTALLED -> MaterialTheme.colorScheme.primary
    AppInstallState.UPDATE_AVAILABLE -> MaterialTheme.colorScheme.primary
    AppInstallState.UP_TO_DATE -> MaterialTheme.colorScheme.onSurfaceVariant
}

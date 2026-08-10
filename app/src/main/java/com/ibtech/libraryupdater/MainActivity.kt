package com.ibtech.libraryupdater

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels

class MainActivity : ComponentActivity() {
    private val viewModel: UpdaterViewModel by viewModels()

    private val permissionLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        viewModel.refreshInstallPermission()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            UpdaterTheme {
                UpdaterScreen(
                    viewModel = viewModel,
                    onOpenInstallPermission = { permissionLauncher.launch(viewModel.installPermissionIntent()) },
                    onInstallApk = { startActivity(it) },
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        viewModel.refreshInstallPermission()
    }
}

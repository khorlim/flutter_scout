package com.example.scout_test_app

import android.Manifest
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Runtime permission prompts for lib/system_dialogs_main.dart, without a
// plugin dependency.
class MainActivity : FlutterActivity() {
    private var pending: Pair<String, MethodChannel.Result>? = null

    private fun permission(kind: Any?): String? = when (kind) {
        "camera" -> Manifest.permission.CAMERA
        "microphone" -> Manifest.permission.RECORD_AUDIO
        "notifications" -> Manifest.permission.POST_NOTIFICATIONS
        else -> null
    }

    private fun status(permission: String): String =
        if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) "granted" else "denied"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "scout_test_app/permissions")
            .setMethodCallHandler { call, result ->
                val permission = permission(call.arguments)
                when {
                    permission == null -> result.success("unsupported")
                    call.method == "status" -> result.success(status(permission))
                    call.method == "request" && status(permission) == "granted" -> result.success("granted")
                    call.method == "request" && pending == null -> {
                        pending = permission to result
                        requestPermissions(arrayOf(permission), REQUEST_CODE)
                    }
                    call.method == "request" -> result.success("busy")
                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_CODE) return
        val (permission, result) = pending ?: return
        pending = null
        result.success(status(permission))
    }

    companion object {
        private const val REQUEST_CODE = 4711
    }
}

package dev.msgrepo.mobile

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    companion object {
        const val CHANNEL = "dev.msgrepo.mobile/bridge"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isNotificationListenerEnabled" ->
                        result.success(isNotificationListenerEnabled())

                    "openNotificationListenerSettings" -> {
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        result.success(null)
                    }

                    // Dart 侧用 dart:io 直接读写该目录（同一应用沙箱）
                    "getQueueDir" ->
                        result.success(File(filesDir, "queue").absolutePath)

                    // 已见应用列表（NotificationCaptureService 维护），返回文件内容
                    "getSeenApps" -> {
                        val file = File(filesDir, "seen_apps.json")
                        result.success(if (file.exists()) file.readText() else null)
                    }

                    // 打开附件访问方式：http(s) 链接、content://、应用 deeplink 均可
                    "openDeeplink" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrBlank()) {
                            result.success(false)
                        } else {
                            try {
                                val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(intent)
                                result.success(true)
                            } catch (e: Exception) {
                                result.success(false)
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun isNotificationListenerEnabled(): Boolean {
        val flat = Settings.Secure.getString(
            contentResolver,
            "enabled_notification_listeners"
        ) ?: return false
        return flat.split(':').any { entry ->
            val cn = ComponentName.unflattenFromString(entry)
            cn != null && cn.packageName == packageName
        }
    }
}

package dev.msgrepo.mobile

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.provider.Telephony
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import android.content.ContentValues
import android.os.Environment
import android.provider.MediaStore

class MainActivity : FlutterActivity() {

    companion object {
        const val CHANNEL = "dev.msgrepo.mobile/bridge"
        const val REQ_SMS_PERMISSION = 4101

        /** 采集服务（独立组件）通过它把「队列有新数据」推给 Dart 侧（P3-3）。 */
        @Volatile
        var bridgeChannel: MethodChannel? = null
    }

    /** 进行中的运行时权限请求回调（短信导入，v2.6）。 */
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_SMS_PERMISSION) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        bridgeChannel = channel
        channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isNotificationListenerEnabled" ->
                        result.success(isNotificationListenerEnabled())

                    "openNotificationListenerSettings" -> {
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        result.success(null)
                    }

                    // Dart 侧用 dart:io 直接读写该目录（同一应用沙箱）
                    // F09：用系统浏览器/其它应用打开链接（不引入 url_launcher 依赖）
          "openUrl" -> {
            val url = call.argument<String>("url")
            result.success(openUrl(url))
          }
          // F10：把附件导出到系统「下载」目录（MediaStore，无需 FileProvider），返回可见路径
          "exportToDownloads" -> {
            val path = call.argument<String>("path")
            val name = call.argument<String>("name") ?: "attachment"
            val mime = call.argument<String>("mime") ?: "application/octet-stream"
            try {
              result.success(exportToDownloads(path, name, mime))
            } catch (e: Exception) {
              result.error("export_failed", e.message, null)
            }
          }
          "getQueueDir" ->
                        result.success(File(filesDir, "queue").absolutePath)

                    // 已见应用列表（NotificationCaptureService 维护），返回文件内容
                    "getSeenApps" -> {
                        val file = File(filesDir, "seen_apps.json")
                        result.success(if (file.exists()) file.readText() else null)
                    }

                    // 已安装的可启动应用列表：[{packageName, appName}, ...] 按名称排序。
                    // PackageManager 查询较慢，放后台线程（Result 可跨线程回调）。
                    "getInstalledApps" -> {
                        Thread {
                            try {
                                result.success(installedAppsJson())
                            } catch (t: Throwable) {
                                result.success("[]")
                            }
                        }.start()
                    }

                    // 应用图标 PNG（96px）；应用不存在返回 null
                    "getAppIcon" -> {
                        val pkg = call.argument<String>("packageName")
                        if (pkg.isNullOrBlank()) {
                            result.success(null)
                        } else {
                            Thread {
                                try {
                                    result.success(appIconPng(pkg))
                                } catch (t: Throwable) {
                                    result.success(null)
                                }
                            }.start()
                        }
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

                    // ---- 保活（v2.6）：电池优化白名单 + 国产 ROM 设置入口 ----

                    "isIgnoringBatteryOptimizations" ->
                        result.success(isIgnoringBatteryOptimizations())

                    // 直接弹出"加入电池优化白名单"系统对话框；厂商阉割该弹窗时
                    // 回退到电池优化列表页。返回是否成功打开了任一界面。
                    "requestIgnoreBatteryOptimizations" -> {
                        var opened = false
                        if (!isIgnoringBatteryOptimizations()) {
                            opened = try {
                                val intent = Intent(
                                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:$packageName"),
                                )
                                startActivity(intent)
                                true
                            } catch (t: Throwable) {
                                false
                            }
                        }
                        if (!opened) {
                            opened = openBatteryOptimizationSettings()
                        }
                        result.success(opened)
                    }

                    "openBatteryOptimizationSettings" ->
                        result.success(openBatteryOptimizationSettings())

                    // 国产 ROM（vivo/小米/华为/OPPO/荣耀）自启动/后台运行设置页：
                    // 无公开 API，逐个尝试已知组件，全部失败返回 false
                    // （由 Dart 侧给图文引导）。
                    "openAutoStartSettings" ->
                        result.success(openAutoStartSettings())

                    // 本应用的系统应用详情页（通用回退入口）
                    "openAppDetailsSettings" -> {
                        val opened = try {
                            val intent = Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$packageName"),
                            )
                            startActivity(intent)
                            true
                        } catch (t: Throwable) {
                            false
                        }
                        result.success(opened)
                    }

                    // ---- 短信导入（v2.6）：READ_SMS 运行时权限 + 系统短信库读取 ----

                    "hasSmsPermission" -> result.success(hasSmsPermission())

                    "requestSmsPermission" -> {
                        if (hasSmsPermission()) {
                            result.success(true)
                        } else if (pendingPermissionResult != null) {
                            result.success(false) // 已有进行中的授权请求
                        } else {
                            pendingPermissionResult = result
                            requestPermissions(
                                arrayOf(Manifest.permission.READ_SMS),
                                REQ_SMS_PERMISSION,
                            )
                        }
                    }

                    // 系统短信库全部短信（收件箱+已发），按时间升序；
                    // 上限 20000 条防 OOM。后台线程执行，Result 可跨线程回调。
                    "readSmsMessages" -> {
                        if (!hasSmsPermission()) {
                            result.success("[]")
                        } else {
                            Thread {
                                try {
                                    result.success(readSmsJson())
                                } catch (t: Throwable) {
                                    result.success("[]")
                                }
                            }.start()
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /// F09：打开链接。成功返回 true；没有可用应用返回 false（不抛异常给 Dart）。
  private fun openUrl(url: String?): Boolean {
    if (url.isNullOrBlank()) return false
    return try {
      val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      }
      startActivity(intent)
      true
    } catch (e: Exception) {
      false
    }
  }

  /// F10：把应用私有目录里的附件导出到系统「下载」目录。
  /// 走 MediaStore（Android 10+ 不需要存储权限），返回「下载/<name>」这样的可见描述。
  private fun exportToDownloads(path: String?, displayName: String, mime: String): String {
    if (path.isNullOrBlank()) throw IllegalArgumentException("path 为空")
    val src = java.io.File(path)
    if (!src.exists()) throw IllegalStateException("文件不存在")
    val values = ContentValues().apply {
      put(MediaStore.Downloads.DISPLAY_NAME, displayName)
      put(MediaStore.Downloads.MIME_TYPE, mime)
      put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
    }
    val resolver = contentResolver
    val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
      ?: throw IllegalStateException("无法创建下载条目")
    resolver.openOutputStream(uri)?.use { out ->
      src.inputStream().use { input -> input.copyTo(out) }
    } ?: throw IllegalStateException("无法写入下载目录")
    return "下载/$displayName"
  }

  private fun installedAppsJson(): String {
        val pm = packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val seen = HashSet<String>()
        val arr = JSONArray()
        val resolved = pm.queryIntentActivities(intent, 0)
            .sortedBy { it.loadLabel(pm).toString().lowercase() }
        for (info in resolved) {
            val pkg = info.activityInfo.packageName ?: continue
            if (!seen.add(pkg)) continue
            val obj = JSONObject()
            obj.put("packageName", pkg)
            obj.put("appName", info.loadLabel(pm).toString())
            arr.put(obj)
        }
        return arr.toString()
    }

    private fun appIconPng(packageName: String): ByteArray? {
        return try {
            val drawable = packageManager.getApplicationIcon(packageName)
            val bitmap = drawableToBitmap(drawable)
            val scaled = if (bitmap.width > 96 || bitmap.height > 96) {
                Bitmap.createScaledBitmap(bitmap, 96, 96, true)
            } else {
                bitmap
            }
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.PNG, 100, out)
            out.toByteArray()
        } catch (t: Throwable) {
            null
        }
    }

    private fun drawableToBitmap(d: Drawable): Bitmap {
        if (d is BitmapDrawable && d.bitmap != null) return d.bitmap
        val w = d.intrinsicWidth.coerceAtLeast(1)
        val h = d.intrinsicHeight.coerceAtLeast(1)
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        d.setBounds(0, 0, w, h)
        d.draw(canvas)
        return bmp
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

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val pm = getSystemService(PowerManager::class.java) ?: return false
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun openBatteryOptimizationSettings(): Boolean {
        return try {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            true
        } catch (t: Throwable) {
            false
        }
    }

    /**
     * 逐个尝试国产 ROM 已知的自启动/后台管理设置组件（无公开 API，靠厂商
     * 约定组件名；覆盖 vivo(i管家)/小米/华为/OPPO/荣耀），任一可拉起即返回 true。
     */
    private fun openAutoStartSettings(): Boolean {
        val candidates = listOf(
            // vivo / iQOO（i管家 自启动管理）
            ComponentName(
                "com.vivo.permissionmanager",
                "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
            ),
            ComponentName(
                "com.iqoo.secure",
                "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
            ),
            ComponentName(
                "com.iqoo.secure",
                "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager",
            ),
            // 小米（安全中心 自启动管理）
            ComponentName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity",
            ),
            // 华为（手机管家 启动管理）
            ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            ),
            // OPPO（手机管家 自启动管理）
            ComponentName(
                "com.coloros.phonemanager",
                "com.coloros.phonemanager.startupapp.StartupAppListActivity",
            ),
            // 荣耀
            ComponentName(
                "com.hihonor.systemmanager",
                "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            ),
        )
        for (cn in candidates) {
            try {
                val intent = Intent().setComponent(cn)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return true
            } catch (t: Throwable) {
                // 该厂商组件不存在，尝试下一个
            }
        }
        return false
    }

    private fun hasSmsPermission(): Boolean {
        return checkSelfPermission(Manifest.permission.READ_SMS) ==
            PackageManager.PERMISSION_GRANTED
    }

    /**
     * 读取系统短信库（content://sms）：收件箱 + 已发，按时间升序。
     * 输出 [{address, body, date, type}]，type=1 收件 / 2 已发；上限 20000 条。
     */
    private fun readSmsJson(): String {
        val arr = JSONArray()
        val cursor = contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(
                Telephony.Sms.ADDRESS,
                Telephony.Sms.BODY,
                Telephony.Sms.DATE,
                Telephony.Sms.TYPE,
            ),
            null,
            null,
            "${Telephony.Sms.DATE} ASC",
        ) ?: return "[]"
        cursor.use {
            var count = 0
            while (it.moveToNext() && count < 20000) {
                val body = it.getString(1)?.trim().orEmpty()
                if (body.isEmpty()) continue
                val obj = JSONObject()
                obj.put("address", it.getString(0) ?: "")
                obj.put("body", body)
                obj.put("date", it.getLong(2))
                obj.put("type", it.getInt(3))
                arr.put(obj)
                count++
            }
        }
        return arr.toString()
    }
}

package dev.msgrepo.mobile

import android.app.Notification
import android.content.pm.PackageManager
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/**
 * 通知采集服务。监听到的通知提取为一条 JSON，原子写入应用私有目录
 * filesDir/queue/<yyyy-MM-dd>/<uuid>.json（先写 .tmp 再 rename），
 * 由 Dart 侧轮询读取并删除，避免与 Dart 端 SQLite 产生并发写冲突。
 *
 * 采集过滤：读取 Dart 侧 shared_preferences 写入的配置（SharedPreferences 文件
 * "FlutterSharedPreferences"，key "flutter.app_filter_config"，值为
 * {"mode": "all"|"allowlist", "packages": [...]}）。allowlist 模式只放行
 * packages 中的应用，被拦截的直接丢弃、不进队列。
 *
 * 已见应用：无论是否放行，把 {packageName, appName, lastSeenAt} 更新到
 * filesDir/seen_apps.json（顶层为 packageName -> 条目 的 JSON 对象，
 * 原子写 tmp+rename），供 Dart 设置页列出候选应用。
 */
class NotificationCaptureService : NotificationListenerService() {

    // 同一进程内的去重窗口：NotificationListenerService 与 MainActivity 同属
    // 本应用进程，Listener 重启后窗口清空，最终去重由 Dart 端 contentHash 保证
    private val recentKeys = LinkedHashSet<String>()

    private val seenAppsLock = Any()

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        try {
            handle(sbn)
        } catch (t: Throwable) {
            // 监听器绝不能崩溃，否则系统会禁用后频繁重绑
        }
    }

    private fun handle(sbn: StatusBarNotification) {
        val notification = sbn.notification ?: return
        val packageName = sbn.packageName ?: return
        if (packageName == this.packageName) return

        val extras = notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
        if (title.isBlank() && text.isBlank()) return

        val postedAt =
            if (sbn.postTime > 0) sbn.postTime else System.currentTimeMillis()

        val appName = try {
            val info = packageManager.getApplicationInfo(packageName, 0)
            packageManager.getApplicationLabel(info).toString()
        } catch (e: PackageManager.NameNotFoundException) {
            packageName
        }

        // 无论是否放行都记录"已见应用"，让设置页能列出当前被拦截的应用
        recordSeenApp(packageName, appName, postedAt)

        // 采集层拦截：不允许的应用不进队列、不入库
        if (!isAllowed(packageName)) return

        val conversationTitle =
            extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString()

        // 系统折叠机制会把同一应用的多次通知合并成一条（EXTRA_TEXT 形如
        // "[5条]某某: …"）。MessagingStyle 通知在 EXTRA_MESSAGES 里携带逐条
        // 原始消息，拆开后逐条入库，避免不相关内容被绑在一起处理。
        val bundled = extras.getParcelableArray(Notification.EXTRA_MESSAGES)
        if (bundled != null && bundled.isNotEmpty()) {
            for (m in bundled) {
                if (m !is android.os.Bundle) continue
                val sender = m.getCharSequence("sender")?.toString().orEmpty()
                val mText = m.getCharSequence("text")?.toString().orEmpty()
                if (mText.isBlank()) continue
                val mTime = m.getLong("time").let { if (it > 0) it else postedAt }
                emit(
                    packageName, appName, notification.channelId, conversationTitle,
                    title, mText, mTime, sender
                )
            }
            return
        }
        emit(
            packageName, appName, notification.channelId, conversationTitle,
            title, text, postedAt, null
        )
    }

    /** 去重后把一条（拆分后的）消息原子写入队列目录。 */
    private fun emit(
        packageName: String,
        appName: String,
        channelId: String?,
        conversationTitle: String?,
        title: String,
        text: String,
        postedAt: Long,
        sender: String?,
    ) {
        val dedupKey = "$packageName|$title|$sender|$text|$postedAt"
        synchronized(recentKeys) {
            if (!recentKeys.add(dedupKey)) return
            if (recentKeys.size > 512) {
                recentKeys.remove(recentKeys.first())
            }
        }

        val obj = JSONObject()
        obj.put("packageName", packageName)
        obj.put("appName", appName)
        obj.put("channelId", channelId ?: JSONObject.NULL)
        obj.put("conversationTitle", conversationTitle ?: JSONObject.NULL)
        obj.put("sender", sender ?: JSONObject.NULL)
        obj.put("title", title)
        obj.put("text", text)
        obj.put("postedTime", postedAt)

        writeAtomically(obj)
    }

    /**
     * 按应用过滤。配置缺失/解析失败一律按 mode=all 放行（向后兼容）。
     * SharedPreferences 有内存缓存，每次读取开销可忽略。
     */
    private fun isAllowed(packageName: String): Boolean {
        return try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            val json = prefs.getString("flutter.app_filter_config", null)
                ?: return true
            val config = JSONObject(json)
            if (config.optString("mode", "all") != "allowlist") return true
            val packages = config.optJSONArray("packages") ?: return false
            for (i in 0 until packages.length()) {
                if (packages.optString(i) == packageName) return true
            }
            false
        } catch (t: Throwable) {
            true
        }
    }

    private fun recordSeenApp(packageName: String, appName: String, seenAt: Long) {
        synchronized(seenAppsLock) {
            try {
                val file = File(filesDir, "seen_apps.json")
                val root = try {
                    if (file.exists()) JSONObject(file.readText()) else JSONObject()
                } catch (t: Throwable) {
                    JSONObject()
                }
                val entry = JSONObject()
                entry.put("packageName", packageName)
                entry.put("appName", appName)
                entry.put("lastSeenAt", seenAt)
                root.put(packageName, entry)

                val tmp = File(filesDir, "seen_apps.json.tmp")
                tmp.writeText(root.toString())
                if (!tmp.renameTo(file)) {
                    file.writeText(root.toString())
                    tmp.delete()
                }
            } catch (t: Throwable) {
                // 记录失败不影响采集主流程
            }
        }
    }

    private fun writeAtomically(obj: JSONObject) {
        val day = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
        val dir = File(filesDir, "queue/$day")
        if (!dir.exists()) dir.mkdirs()
        val fileName = "${UUID.randomUUID()}.json"
        val tmp = File(dir, "$fileName.tmp")
        val target = File(dir, fileName)
        tmp.writeText(obj.toString())
        if (!tmp.renameTo(target)) {
            target.writeText(obj.toString())
            tmp.delete()
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        // 不需要处理移除事件
    }
}

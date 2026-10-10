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
 */
class NotificationCaptureService : NotificationListenerService() {

    // 同一进程内的去重窗口：NotificationListenerService 与 MainActivity 同属
    // 本应用进程，Listener 重启后窗口清空，最终去重由 Dart 端 contentHash 保证
    private val recentKeys = LinkedHashSet<String>()

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

        val dedupKey = "$packageName|$title|$text|$postedAt"
        synchronized(recentKeys) {
            if (!recentKeys.add(dedupKey)) return
            if (recentKeys.size > 512) {
                recentKeys.remove(recentKeys.first())
            }
        }

        val appName = try {
            val info = packageManager.getApplicationInfo(packageName, 0)
            packageManager.getApplicationLabel(info).toString()
        } catch (e: PackageManager.NameNotFoundException) {
            packageName
        }

        val obj = JSONObject()
        obj.put("packageName", packageName)
        obj.put("appName", appName)
        obj.put("channelId", notification.channelId ?: JSONObject.NULL)
        obj.put(
            "conversationTitle",
            extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString()
                ?: JSONObject.NULL
        )
        obj.put("title", title)
        obj.put("text", text)
        obj.put("postedTime", postedAt)

        writeAtomically(obj)
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

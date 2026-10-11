# MsgRepo Mobile（Flutter / 仅 Android）

MsgRepo 手机端：自动采集 Android 通知 + 手动添加带附件的消息，通过 USB + adb reverse
把待处理消息发给电脑端本地 AI，接收结构化结果（日程/待办/笔记等），展示并调度本地提醒。

## 构建与运行

本仓库是手工编写的标准 Flutter 工程，安装 Flutter SDK 后即可直接运行：

```bash
cd mobile
flutter pub get
flutter run          # 连接 Android 设备（minSdk 26 / Android 8.0+）
```

发布构建：`flutter build apk --release`（release 目前使用 debug 签名，正式发布前请在
`android/app/build.gradle` 中配置签名）。

## 连接电脑端

```bash
adb reverse tcp:8765 tcp:8765
```

手机 App 默认访问 `http://127.0.0.1:8765`（可在「我的」页修改）。同步前请先在
「我的」页填入电脑端配对时生成的 Token。

## 需要的权限

| 权限 | 用途 | 授权方式 |
|---|---|---|
| 通知监听（NotificationListenerService） | 自动采集其他应用通知 | 「我的」页或收件箱顶部引导条跳转系统设置页手动开启 |
| POST_NOTIFICATIONS | Android 13+ 弹出本地提醒 | 首次启动时弹窗请求 |
| SCHEDULE_EXACT_ALARM | 精确时刻提醒 | 安装即授予（Android 12 起默认允许，用户可撤销） |
| RECEIVE_BOOT_COMPLETED | 开机后由 flutter_local_notifications 重新调度提醒 | 安装即授予 |
| INTERNET + 明文 HTTP | 经 adb reverse 访问 127.0.0.1 | manifest 中 usesCleartextTraffic="true" |

## 架构说明

### Kotlin ↔ Dart 桥接

`NotificationListenerService` 回调发生在系统绑定环境中，直接在 Kotlin 侧写 Dart 的
SQLite 库会产生并发冲突。因此采用**文件队列 + 轮询**：

- Kotlin `NotificationCaptureService.onNotificationPosted` 提取
  packageName/appName/channelId/title/text/postedTime/conversationTitle，
  原子写入（`.tmp` + rename）`filesDir/queue/<yyyy-MM-dd>/<uuid>.json`；
- Dart `NotificationBridge` 每 10s 轮询队列目录，解析入库（计算
  `contentHash = sha256(packageName|title|body|postedAt)` 去重）后删除文件；
- MethodChannel `dev.msgrepo.mobile/bridge` 只承担授权检查/跳转、deeplink 拉起、
  队列目录路径查询、seen apps 读取。

### 应用采集过滤

在「我的 → 应用采集过滤」可选择只收集指定应用的通知：

- 配置存 SharedPreferences（JSON 字符串），Dart 与 Kotlin 共享。**过滤发生在
  Kotlin 采集层**：不允许的应用直接丢弃，不进队列、不入库；
- 「仅指定应用」模式下列表为空 = 什么都不收集，设置页会有明显提示；
- 手动添加的消息（packageName 为 `manual`）永远不受此设置影响；
- 收件箱列表支持按来源应用筛选（基于本地消息的 distinct 查询）。

**已见应用（seen apps）**：Kotlin 端无论是否放行，都会把
`{packageName, appName, lastSeenAt}` 更新到 `filesDir/seen_apps.json`
（原子写 tmp+rename），设置页的「添加应用」据此列出发过通知的应用（含当前被拦截的）
供勾选，支持搜索；未发过通知的应用不在其中，可手动输入包名添加。

### 数据流

通知/手动消息 → SQLite `raw_messages`（status=pending）→ 下拉或点同步按钮 →
POST `/v1/sync`（携带 pending 消息与注册表协商）→ 响应中
`processedMessageIds` 置为 processed、`results` 写入 `structured_items` →
按 `time` 字段用 flutter_local_notifications 调度本地提醒。

### 已知限制

- 未生成应用图标资源（本机无 Flutter SDK），manifest 未声明 `android:icon`，
  将使用系统默认图标；如需自定义请放入 `android/app/src/main/res/mipmap-*`。
- `time.kind=recurring` 不支持本地调度，仅在详情页展示 RRULE。
- 未引入 flutter_timezone，本地时区通过系统时区名/UTC 偏移推断，个别设备可能退回 UTC。

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/task.dart';
import 'database.dart';
import '../services/app_log.dart';

/// 是否该为这个任务排提醒：active + 有未来的 start_at。纯函数，便于单测。
bool shouldScheduleReminder(Task task, {required int nowMs}) {
  if (task.status != TaskStatus.active) return false;
  final s = task.startAt;
  if (s == null) return false;
  return s > nowMs;
}

/// 依据是否具备精确闹钟权限选择调度模式：未授权时降级为不精确。
/// 纯函数，使「降级」这件事能在单测里断言（P1-5）。
AndroidScheduleMode scheduleModeFor({required bool exactAllowed}) =>
    exactAllowed
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;

/// 本地提醒调度（设计 §0，v2）：有 start_at 的 active 任务在 start_at 时刻
/// 发一条本地通知（标题 = 任务名）。无时间任务不排。
///
/// 任务增删改/完成/归档由 database.dart 的 tasks 写方法触发 [rescheduleAll]
/// 全量重排；应用启动时也重排一次（main.dart）。
///
/// P1-4 / P1-5（2026-10-17）：
/// - 重排不再用 cancelAll()，只取消「上次排过的任务提醒」，AI 完成通知不再被误清；
/// - 精确闹钟权限先查询，未授予时降级为 inexactAllowWhileIdle（提醒仍会响，
///   可能延迟数分钟），状态由 [exactAlarmsAllowed] 暴露给设置页；
/// - 整个重排包在 try/catch 中并记录 [lastError]，不再静默失效。
class ReminderService {
  ReminderService._();

  static final ReminderService instance = ReminderService._();

  static const _channelId = 'msgrepo_reminders';
  static const _channelName = '任务提醒';
  static const _channelDesc = '有开始时间的任务到点本地提醒';

  static const _aiChannelId = 'msgrepo_ai';
  static const _aiChannelName = 'AI 处理';
  static const _aiChannelDesc = 'AI 后台处理完成提醒';
  static const _aiNotificationId = 0xA1;

  /// 已排上的任务提醒 id 列表（重排时只取消这些，避免波及别的通知）。
  static const _keyScheduledIds = 'reminder_scheduled_ids';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// 精确闹钟权限（null = 尚未查询）。
  bool? _exactAllowed;

  /// 最近一次重排失败的原因（null = 无错误）。
  String? _lastError;

  bool get initialized => _initialized;

  /// 最近一次重排失败的原因，设置页展示用。
  String? get lastError => _lastError;

  /// 是否具备精确闹钟权限；未查询过时按 true 处理（乐观，首次重排会校准）。
  bool get exactAlarmsAllowed => _exactAllowed ?? true;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  Future<void> init() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    _resolveLocalTimezone();

    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@drawable/ic_notification'),
    );
    await _plugin.initialize(initSettings);

    // Android 13+ 运行时通知权限
    await _android?.requestNotificationsPermission();
    await refreshExactAlarms();

    _initialized = true;
  }

  /// 查询精确闹钟权限并缓存（init / 重排 / 设置页刷新时调用）。
  Future<bool> refreshExactAlarms() async {
    try {
      final v = await _android?.canScheduleExactNotifications();
      _exactAllowed = v ?? true;
    } catch (e) {
      // 老版本 Android 或通道异常：按可用处理，由调度层自行决定
      _exactAllowed = true;
      debugPrint('canScheduleExactNotifications 查询失败: $e');
    }
    return exactAlarmsAllowed;
  }

  /// 请求精确闹钟权限（Android 12+ 跳系统设置页）。返回请求后的实际状态。
  Future<bool> requestExactAlarms() async {
    try {
      await _android?.requestExactAlarmsPermission();
    } catch (e) {
      debugPrint('requestExactAlarmsPermission 失败: $e');
    }
    return refreshExactAlarms();
  }

  /// 排提醒用的调度模式：有精确权限用精确，否则降级为不精确。
  AndroidScheduleMode get _scheduleMode =>
      scheduleModeFor(exactAllowed: exactAlarmsAllowed);

  /// 依据「当前偏移 / 半年后偏移 / 时区缩写」在 tz 数据库里挑选本地时区（P3-6）。
  ///
  /// 旧实现只按当前 UTC 偏移取第一个匹配项：中文系统的 timeZoneName 常是
  /// 「CST」「中国标准时间」这类非 IANA 名，匹配失败后就退化成「按偏移扫描」，
  /// 而同一偏移下 DST 规则不同的地区会排错（例如把 +8 无 DST 的地方选成有 DST 的区）。
  /// 这里再加一个「半年后偏移」维度过滤 DST 规则，最后用缩写优先命中。
  /// 纯函数（时间由调用方传入），便于单测。
  String pickLocalZoneName({
    required DateTime now,
    required Duration offsetNow,
    required Duration offsetLater,
    required String abbreviation,
  }) {
    final later = now.add(const Duration(days: 180));
    String? sameAbbrev;
    String? sameRules;
    for (final name in tz.timeZoneDatabase.locations.keys) {
      final loc = tz.getLocation(name);
      final nowLoc = tz.TZDateTime.from(now, loc);
      if (nowLoc.timeZoneOffset != offsetNow) continue;
      if (tz.TZDateTime.from(later, loc).timeZoneOffset != offsetLater) continue;
      sameRules ??= name;
      if (nowLoc.timeZoneName.toUpperCase() == abbreviation) {
        sameAbbrev = name;
        break;
      }
    }
    return sameAbbrev ?? sameRules ?? 'UTC';
  }

  /// 未引入 flutter_timezone：先按系统时区名匹配（Android 通常返回 IANA 名），
  /// 失败再按偏移 + DST 规则挑选，最后退回 UTC。
  void _resolveLocalTimezone() {
    final now = DateTime.now();
    try {
      tz.setLocalLocation(tz.getLocation(now.timeZoneName));
      return;
    } catch (_) {
      // 预期分支：系统给的不是 IANA 名，走下面的偏移 + DST 规则挑选，不算错误
    }
    final name = pickLocalZoneName(
      now: now,
      offsetNow: now.timeZoneOffset,
      offsetLater: now.add(const Duration(days: 180)).timeZoneOffset,
      abbreviation: now.timeZoneName.toUpperCase(),
    );
    tz.setLocalLocation(tz.getLocation(name));
  }

  int _notificationId(String taskId) => taskId.hashCode & 0x7fffffff;

  /// 为一批任务分配互不冲突的通知 id（P3-7）。
  ///
  /// 旧实现直接用 `taskId.hashCode & 0x7fffffff`：两个任务撞上同一 id 时，
  /// 后者的提醒会把前者覆盖掉（表现为「某个任务永远不提醒」）。
  /// 这里以 hashCode 为起点做线性探测，并避开 AI 完成通知占用的 id。
  Map<String, int> assignNotificationIds(Iterable<String> taskIds) {
    final used = <int>{_aiNotificationId};
    final out = <String, int>{};
    var probe = 1;
    for (final id in taskIds) {
      var n = _notificationId(id);
      while (used.contains(n)) {
        n = probe++ & 0x7fffffff;
        if (n == 0) n = 1;
      }
      used.add(n);
      out[id] = n;
    }
    return out;
  }

  /// 为单个任务排提醒：仅 active + startAt 在未来。返回是否真的排上了。
  Future<bool> scheduleForTask(Task task, {int? id}) async {
    if (!_initialized) return false;
    final nid = id ?? _notificationId(task.id);
    await _plugin.cancel(nid);
    if (!shouldScheduleReminder(task,
        nowMs: DateTime.now().millisecondsSinceEpoch)) {
      return false;
    }
    final startAt = task.startAt!;
    await _plugin.zonedSchedule(
      nid,
      task.title,
      task.description?.isNotEmpty == true ? task.description : task.title,
      tz.TZDateTime.fromMillisecondsSinceEpoch(tz.local, startAt),
      _details,
      androidScheduleMode: _scheduleMode,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: task.id,
    );
    return true;
  }

  /// 全量重排：只取消「上次排过的任务提醒」，再按当前任务重排。
  ///
  /// 不用 cancelAll()：那会连带清掉 AI 完成通知（P1-4）；
  /// 失败一律记录到 [lastError] 并 debugPrint，不再静默（P1-5）。
  Future<void> rescheduleAll() async {
    if (!_initialized) return;
    _lastError = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final prev = prefs.getStringList(_keyScheduledIds) ?? const <String>[];
      for (final s in prev) {
        final id = int.tryParse(s);
        if (id == null) continue;
        try {
          await _plugin.cancel(id);
        } catch (e, st) {
          AppLog.instance.warn('reminder.cancel', e, st);
          // 单条取消失败不影响后续
        }
      }

      await refreshExactAlarms();

      final tasks =
          await AppDatabase.instance.getTasks(status: TaskStatus.active);
      final scheduled = <String>[];
      final ids = assignNotificationIds(tasks.map((t) => t.id));
      for (final task in tasks) {
        try {
          final id = ids[task.id];
          if (await scheduleForTask(task, id: id)) {
            scheduled.add(id.toString());
          }
        } catch (e) {
          // 单条失败不阻塞其余任务，但要留下痕迹
          _lastError = '任务「${task.title}」排提醒失败：$e';
          debugPrint(_lastError!);
        }
      }
      await prefs.setStringList(_keyScheduledIds, scheduled);
    } catch (e) {
      _lastError = '提醒重排失败：$e';
      debugPrint(_lastError!);
    }
  }

  NotificationDetails get _details => const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.high,
          priority: Priority.high,
        ),
      );

  /// AI 后台处理完成的一次性通知（v2.6.2）：面板收起期间跑完时提醒回来确认结果。
  /// 普通通知即可，不引入前台服务。
  /// 注意：任务重排只取消任务提醒 id，不再 cancelAll，本条通知不会被误清（P1-4）。
  Future<void> notifyAiProcessingDone(int pendingConfirm, int failed) async {
    if (!_initialized) return;
    await _plugin.show(
      _aiNotificationId,
      'AI 处理完成',
      '$pendingConfirm 条结果待确认${failed > 0 ? '，$failed 条失败' : ''}',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _aiChannelId,
          _aiChannelName,
          channelDescription: _aiChannelDesc,
          importance: Importance.defaultImportance,
        ),
      ),
    );
  }
}

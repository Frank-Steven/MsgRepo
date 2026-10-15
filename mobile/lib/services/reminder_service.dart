import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/task.dart';
import 'database.dart';

/// 本地提醒调度（设计 §0，v2）：有 start_at 的 active 任务在 start_at 时刻
/// 发一条本地通知（标题 = 任务名）。无时间任务不排。
///
/// 任务增删改/完成/归档由 database.dart 的 tasks 写方法触发 [rescheduleAll]
/// 全量重排；应用启动时也重排一次（main.dart）。
class ReminderService {
  ReminderService._();

  static final ReminderService instance = ReminderService._();

  static const _channelId = 'msgrepo_reminders';
  static const _channelName = '任务提醒';
  static const _channelDesc = '有开始时间的任务到点本地提醒';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    _resolveLocalTimezone();

    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@drawable/ic_notification'),
    );
    await _plugin.initialize(initSettings);

    // Android 13+ 运行时通知权限
    final android =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();

    _initialized = true;
  }

  /// 未引入 flutter_timezone：先按系统时区名匹配，失败则按当前 UTC 偏移
  /// 在数据库中找一个偏移一致的 location，再不行退回 UTC。
  void _resolveLocalTimezone() {
    try {
      tz.setLocalLocation(tz.getLocation(DateTime.now().timeZoneName));
      return;
    } catch (_) {}
    final offset = DateTime.now().timeZoneOffset;
    for (final name in tz.timeZoneDatabase.locations.keys) {
      final loc = tz.getLocation(name);
      if (tz.TZDateTime.now(loc).timeZoneOffset == offset) {
        tz.setLocalLocation(loc);
        return;
      }
    }
    tz.setLocalLocation(tz.UTC);
  }

  int _notificationId(String taskId) => taskId.hashCode & 0x7fffffff;

  /// 为单个任务排提醒：仅 active + startAt 在未来。
  Future<void> scheduleForTask(Task task) async {
    if (!_initialized) return;
    await _plugin.cancel(_notificationId(task.id));
    if (task.status != TaskStatus.active) return;
    final startAt = task.startAt;
    if (startAt == null) return;
    if (startAt <= DateTime.now().millisecondsSinceEpoch) return;
    await _plugin.zonedSchedule(
      _notificationId(task.id),
      task.title,
      task.description?.isNotEmpty == true ? task.description : task.title,
      tz.TZDateTime.fromMillisecondsSinceEpoch(tz.local, startAt),
      _details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: task.id,
    );
  }

  /// 全量重排：先清空本应用全部通知再逐个重排（任务写操作后/启动时调用）。
  Future<void> rescheduleAll() async {
    if (!_initialized) return;
    await _plugin.cancelAll();
    final tasks = await AppDatabase.instance.getTasks(status: TaskStatus.active);
    for (final task in tasks) {
      await scheduleForTask(task);
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
}

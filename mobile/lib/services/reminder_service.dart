import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models.dart';
import 'database.dart';

/// 本地提醒调度：只读取 StructuredItem.time。
/// point/range 以 startAt、deadline 以 deadline 为基准，各减 reminderOffsets 分钟；
/// recurring 不在本地调度（仅展示 rrule）。
class ReminderService {
  ReminderService._();

  static final ReminderService instance = ReminderService._();

  static const _channelId = 'msgrepo_reminders';
  static const _channelName = '消息提醒';
  static const _channelDesc = '日程、待办等结构化结果的本地提醒';

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

  int _notificationId(String itemId, int offsetMinutes) =>
      Object.hash(itemId, offsetMinutes) & 0x7fffffff;

  Future<void> scheduleForItem(StructuredItem item) async {
    if (!_initialized) return;
    await cancelForItem(item);

    final base = item.time.baseTime;
    if (base == null) return; // none / recurring 不调度

    // P0 立即提醒一次
    if (item.priority == 'P0') {
      await _plugin.show(
        _notificationId(item.id, -1),
        '【紧急】${item.title}',
        item.summary.isNotEmpty ? item.summary : item.title,
        _details,
        payload: item.id,
      );
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    for (final offset in item.time.reminderOffsets) {
      final at = base - offset * 60 * 1000;
      if (at <= now) continue;
      await _plugin.zonedSchedule(
        _notificationId(item.id, offset),
        item.title,
        item.summary.isNotEmpty ? item.summary : item.title,
        tz.TZDateTime.fromMillisecondsSinceEpoch(tz.local, at),
        _details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: item.id,
      );
    }
  }

  Future<void> cancelForItem(StructuredItem item) async {
    if (!_initialized) return;
    await _plugin.cancel(_notificationId(item.id, -1));
    for (final offset in item.time.reminderOffsets) {
      await _plugin.cancel(_notificationId(item.id, offset));
    }
  }

  /// 应用启动时重排所有未来提醒（进程被杀后 zonedSchedule 仍可触发，
  /// 这里主要覆盖数据库恢复/重新安装后的场景）。
  Future<void> rescheduleAll() async {
    if (!_initialized) return;
    final items = await AppDatabase.instance.getStructuredItems();
    for (final item in items) {
      await scheduleForItem(item);
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

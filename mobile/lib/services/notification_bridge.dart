import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models.dart';
import 'database.dart';

/// Kotlin ↔ Dart 桥接：
/// - MethodChannel 负责通知监听授权检查/跳转、附件 deeplink 拉起；
/// - 通知数据不走 MethodChannel，Kotlin 的 NotificationListenerService 将每条
///   通知原子写入 filesDir/queue/<日期>/<uuid>.json，Dart 每 10s 轮询读取、
///   入库后删除文件。
class NotificationBridge {
  NotificationBridge._();

  static final NotificationBridge instance = NotificationBridge._();

  static const _channel = MethodChannel('dev.msgrepo.mobile/bridge');
  static const _pollInterval = Duration(seconds: 10);
  static const _uuid = Uuid();

  final _onNewMessages = StreamController<int>.broadcast();

  /// 每次轮询到新通知时广播新入库条数。
  Stream<int> get onNewMessages => _onNewMessages.stream;

  Timer? _timer;
  bool _pulling = false;
  String? _queueDir;

  Future<bool> isListenerEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isNotificationListenerEnabled') ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> openListenerSettings() async {
    await _channel.invokeMethod<void>('openNotificationListenerSettings');
  }

  /// 打开附件访问方式（http 链接 / content:// / 应用 deeplink）。
  Future<bool> openDeeplink(String url) async {
    try {
      return await _channel
              .invokeMethod<bool>('openDeeplink', {'url': url}) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<String> _getQueueDir() async {
    final cached = _queueDir;
    if (cached != null) return cached;
    try {
      final dir = await _channel.invokeMethod<String>('getQueueDir');
      if (dir != null) {
        _queueDir = dir;
        return dir;
      }
    } on MissingPluginException {
      // 回退到应用私有 files 目录（Android 上即 filesDir）
    }
    final supportDir = await getApplicationSupportDirectory();
    final dir = '${supportDir.path}/queue';
    _queueDir = dir;
    return dir;
  }

  void startPolling() {
    _timer ??= Timer.periodic(_pollInterval, (_) => pullOnce());
    // 启动时立即拉一次
    unawaited(pullOnce());
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  /// 读取队列文件并入库，返回新入库条数。
  Future<int> pullOnce() async {
    if (_pulling) return 0;
    _pulling = true;
    try {
      final root = Directory(await _getQueueDir());
      if (!await root.exists()) return 0;

      var imported = 0;
      await for (final entity in root.list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final map =
              jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
          final message = _fromQueueEntry(map);
          if (await AppDatabase.instance.insertRawMessageIfNew(message)) {
            imported++;
          }
        } catch (_) {
          // 单个文件损坏不阻塞其他文件，文件照删避免反复失败
        } finally {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }

      // 清理空日期目录
      await for (final entity in root.list()) {
        if (entity is Directory) {
          try {
            if (await entity.list().isEmpty) await entity.delete();
          } catch (_) {}
        }
      }

      if (imported > 0) _onNewMessages.add(imported);
      return imported;
    } catch (_) {
      return 0;
    } finally {
      _pulling = false;
    }
  }

  RawMessage _fromQueueEntry(Map<String, dynamic> map) {
    final packageName = map['packageName'] as String? ?? 'unknown';
    final title = map['title'] as String? ?? '';
    final body = map['text'] as String? ?? '';
    final postedAt = (map['postedTime'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    return RawMessage(
      id: _uuid.v4(),
      source: MessageSource(
        packageName: packageName,
        appName: map['appName'] as String?,
        channelId: map['channelId'] as String?,
        conversationTitle: map['conversationTitle'] as String?,
        sender: map['sender'] as String?,
      ),
      title: title,
      body: body,
      postedAt: postedAt,
      captureType: RawMessage.captureNotification,
      contentHash: computeContentHash(packageName, title, body, postedAt),
    );
  }
}

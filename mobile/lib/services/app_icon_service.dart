import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 应用图标加载（v2.4）：平台通道从 PackageManager 取 PNG（96px），
/// 内存 + 磁盘（<cacheDir>/app_icons/<包名>.png）双层缓存；
/// 应用已卸载/查询失败返回 null，调用方显示占位。
class AppIconService {
  AppIconService._();

  static final AppIconService instance = AppIconService._();

  static const _channel = MethodChannel('dev.msgrepo.mobile/bridge');

  /// packageName -> PNG 字节；null 表示已确认无图标（不再重复查询）。
  final Map<String, Uint8List?> _mem = {};

  /// 正在进行的磁盘/通道加载合并（避免滚动列表并发重复触发）。
  final Map<String, Future<Uint8List?>> _inflight = {};

  Future<Uint8List?> iconFor(String packageName) {
    if (_mem.containsKey(packageName)) {
      return Future.value(_mem[packageName]);
    }
    return _inflight.putIfAbsent(
      packageName,
      () => _load(packageName).whenComplete(() => _inflight.remove(packageName)),
    );
  }

  Future<Uint8List?> _load(String packageName) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/app_icons/$packageName.png');
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          return _mem[packageName] = bytes;
        }
      }
      final bytes = await _channel.invokeMethod<Uint8List>(
          'getAppIcon', {'packageName': packageName});
      if (bytes != null && bytes.isNotEmpty) {
        await file.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        return _mem[packageName] = bytes;
      }
    } catch (_) {
      // 图标是锦上添花，失败静默
    }
    return _mem[packageName] = null;
  }
}

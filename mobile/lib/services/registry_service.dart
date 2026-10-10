import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';

/// 分类注册表：首启从 assets 加载默认注册表并缓存到 SharedPreferences；
/// 同步后记录电脑端实际使用的版本，供下次同步决定是否携带完整注册表。
class RegistryService {
  RegistryService._();

  static final RegistryService instance = RegistryService._();

  static const _keyRegistryJson = 'registry_json';
  static const _keyDesktopVersion = 'desktop_registry_version';
  static const _assetPath = 'assets/registry/default.json';

  CategoryRegistry? _cached;

  Future<CategoryRegistry> load() async {
    final cached = _cached;
    if (cached != null) return cached;

    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyRegistryJson) ??
        await rootBundle.loadString(_assetPath);
    final registry =
        CategoryRegistry.fromJson(_decode(json));
    if (!prefs.containsKey(_keyRegistryJson)) {
      await prefs.setString(_keyRegistryJson, json);
    }
    _cached = registry;
    return registry;
  }

  Map<String, dynamic> _decode(String json) =>
      (const JsonDecoder().convert(json) as Map).cast<String, dynamic>();

  /// 记录电脑端实际使用的注册表版本。响应只带版本号不带内容，
  /// 本地继续使用当前注册表；下次同步请求若版本不一致会携带完整注册表。
  Future<void> noteDesktopVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDesktopVersion, version);
  }

  Future<String?> desktopVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyDesktopVersion);
  }
}

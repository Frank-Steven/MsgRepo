import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models.dart';
import 'database.dart';
import 'registry_service.dart';
import 'reminder_service.dart';

class SyncException implements Exception {
  final String message;

  SyncException(this.message);

  @override
  String toString() => message;
}

class SyncOutcome {
  final int sent;
  final int processed;
  final int results;
  final List<String> warnings;

  const SyncOutcome({
    required this.sent,
    required this.processed,
    required this.results,
    this.warnings = const [],
  });
}

/// 经 adb forward 与电脑端通信：POST /v1/sync 上传待处理消息并接收结构化结果。
class SyncClient {
  SyncClient._();

  static final SyncClient instance = SyncClient._();

  static const _keyToken = 'pair_token';
  static const _keyBaseUrl = 'base_url';
  static const _keyDeviceId = 'device_id';
  static const defaultBaseUrl = 'http://127.0.0.1:8765';

  Future<String> getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyBaseUrl) ?? defaultBaseUrl;
  }

  Future<void> setBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyBaseUrl, url);
  }

  Future<String> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyToken) ?? '';
  }

  Future<void> setToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyToken, token);
  }

  Future<String> getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_keyDeviceId);
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(_keyDeviceId, id);
    }
    return id;
  }

  /// GET /v1/health 测连通。
  Future<bool> health() async {
    final baseUrl = await getBaseUrl();
    try {
      final resp = await http
          .get(Uri.parse('$baseUrl/v1/health'))
          .timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 收集 pending 消息 → 发送 → 成功则置 processed、写入结果、调度提醒。
  Future<SyncOutcome> sync() async {
    final db = AppDatabase.instance;
    final registry = await RegistryService.instance.load();
    final desktopVersion = await RegistryService.instance.desktopVersion();

    final pending = await db.getRawMessages(status: RawMessage.statusPending);
    if (pending.isEmpty) {
      return const SyncOutcome(sent: 0, processed: 0, results: 0);
    }
    pending.sort((a, b) => a.postedAt.compareTo(b.postedAt));

    // 协议：电脑端版本与本地一致时省略 registry 以减小请求
    final includeRegistry =
        desktopVersion == null || desktopVersion != registry.version;
    final request = SyncRequest(
      deviceId: await getDeviceId(),
      registryVersion: registry.version,
      registry: includeRegistry ? registry : null,
      messages: pending,
    );

    final baseUrl = await getBaseUrl();
    final token = await getToken();
    final http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse('$baseUrl/v1/sync'),
            headers: {
              'Content-Type': 'application/json',
              if (token.isNotEmpty) 'Authorization': 'Bearer $token',
            },
            body: jsonEncode(request.toJson()),
          )
          .timeout(const Duration(seconds: 120));
    } catch (e) {
      throw SyncException('无法连接电脑端，请确认 USB 已连接并执行 adb forward：$e');
    }
    if (resp.statusCode != 200) {
      throw SyncException('同步失败 HTTP ${resp.statusCode}：${resp.body}');
    }

    final parsed = SyncResponse.fromJson(
        (jsonDecode(utf8.decode(resp.bodyBytes)) as Map)
            .cast<String, dynamic>());

    if (parsed.processedMessageIds.isNotEmpty) {
      await db.updateRawMessageStatus(
          parsed.processedMessageIds, RawMessage.statusProcessed);
    }
    await db.insertStructuredItems(parsed.results);
    await RegistryService.instance.noteDesktopVersion(parsed.registryVersion);
    for (final item in parsed.results) {
      await ReminderService.instance.scheduleForItem(item);
    }

    return SyncOutcome(
      sent: pending.length,
      processed: parsed.processedMessageIds.length,
      results: parsed.results.length,
      warnings: parsed.warnings,
    );
  }
}

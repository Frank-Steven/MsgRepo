import 'dart:async';
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
  final int failed;
  final List<String> warnings;

  const SyncOutcome({
    required this.sent,
    required this.processed,
    required this.results,
    this.failed = 0,
    this.warnings = const [],
  });
}

/// 经 adb reverse 与电脑端通信：POST /v1/sync 上传待处理消息并接收结构化结果。
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

  /// 流式同步进度：(已处理消息数, 结构化条目数)，每处理完一条广播一次。
  final _onProgress = StreamController<(int, int)>.broadcast();
  Stream<(int, int)> get onProgress => _onProgress.stream;

  /// 收集 pending 消息 → 单次流式请求 → 电脑端逐条处理逐条返回，
  /// 每收到一条结果立即落库、置 processed、调度提醒；连接中断只丢正在处理的一条。
  Future<SyncOutcome> sync() async {
    final db = AppDatabase.instance;
    final registry = await RegistryService.instance.load();
    final desktopVersion = await RegistryService.instance.desktopVersion();

    final pending = await db.getRawMessages(status: RawMessage.statusPending);
    if (pending.isEmpty) {
      return const SyncOutcome(sent: 0, processed: 0, results: 0);
    }
    pending.sort((a, b) => a.postedAt.compareTo(b.postedAt));

    final prefs = await SharedPreferences.getInstance();
    final customPrompt = prefs.getString('custom_prompt')?.trim() ?? '';
    final reprocessIds = await db.getNeedsReprocessIds();
    final baseUrl = await getBaseUrl();
    final token = await getToken();

    // 协议：电脑端版本与本地一致时省略 registry 以减小请求
    final request = SyncRequest(
      deviceId: await getDeviceId(),
      registryVersion: registry.version,
      registry:
          (desktopVersion == null || desktopVersion != registry.version)
              ? registry
              : null,
      customPrompt: customPrompt.isEmpty ? null : customPrompt,
      reprocessMessageIds: reprocessIds.isEmpty ? null : reprocessIds,
      stream: true,
      messages: pending,
    );

    var processed = 0, failed = 0;
    final seenItemIds = <String>{};
    final warnings = <String>[];

    final req = http.Request('POST', Uri.parse('$baseUrl/v1/sync'));
    req.headers['Content-Type'] = 'application/json';
    if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
    req.body = jsonEncode(request.toJson());

    final client = http.Client();
    try {
      final streamed =
          await client.send(req).timeout(const Duration(seconds: 30));
      if (streamed.statusCode != 200) {
        final errBody = await streamed.stream.bytesToString();
        throw SyncException('同步失败 HTTP ${streamed.statusCode}：$errBody');
      }

      Future<void> handleItem(Map<String, dynamic> itemJson) async {
        final item = StructuredItem.fromJson(itemJson);
        await db.insertStructuredItems([item]);
        await ReminderService.instance.scheduleForItem(item);
        seenItemIds.add(item.id);
      }

      Future<void> handleProcessed(List<String> ids) async {
        if (ids.isEmpty) return;
        await db.updateRawMessageStatus(ids, RawMessage.statusProcessed);
        await db.clearNeedsReprocess(ids);
        processed += ids.length;
      }

      final contentType = streamed.headers['content-type'] ?? '';
      if (!contentType.contains('x-ndjson')) {
        // 兼容旧版电脑端：一次性 JSON 响应
        final body = await streamed.stream
            .bytesToString()
            .timeout(const Duration(seconds: 600));
        final parsed = SyncResponse.fromJson(
            (jsonDecode(body) as Map).cast<String, dynamic>());
        await handleProcessed(parsed.processedMessageIds);
        for (final item in parsed.results) {
          await handleItem(item.toJson());
        }
        await RegistryService.instance
            .noteDesktopVersion(parsed.registryVersion);
        warnings.addAll(parsed.warnings);
      } else {
        // NDJSON 流式：每行一个事件，逐条落库（240s 无新事件视为断流）
        final buf = StringBuffer();
        await for (final chunk in streamed.stream
            .timeout(const Duration(seconds: 240))
            .transform(utf8.decoder)) {
          buf.write(chunk);
          final text = buf.toString();
          var consumed = 0;
          var nl = text.indexOf('\n');
          while (nl >= 0) {
            final line = text.substring(consumed, nl).trim();
            consumed = nl + 1;
            nl = text.indexOf('\n', consumed);
            if (line.isEmpty) continue;
            Map<String, dynamic> ev;
            try {
              ev = (jsonDecode(line) as Map).cast<String, dynamic>();
            } catch (_) {
              continue;
            }
            switch (ev['type'] as String? ?? '') {
              case 'progress':
                await handleProcessed(
                    (ev['processedMessageIds'] as List?)?.cast<String>() ??
                        const []);
                failed +=
                    ((ev['failedMessageIds'] as List?)?.length ?? 0);
                final itemJson = ev['item'];
                if (itemJson is Map) {
                  await handleItem(itemJson.cast<String, dynamic>());
                }
                warnings.addAll(
                    (ev['warnings'] as List?)?.cast<String>() ?? const []);
                _onProgress.add((processed, seenItemIds.length));
              case 'warning':
                final m = ev['message'] as String?;
                if (m != null) warnings.add(m);
              case 'done':
                final v = ev['registryVersion'] as String?;
                if (v != null) {
                  await RegistryService.instance.noteDesktopVersion(v);
                }
                warnings.addAll(
                    (ev['warnings'] as List?)?.cast<String>() ?? const []);
            }
          }
          final remaining = text.substring(consumed);
          buf.clear();
          buf.write(remaining);
        }
      }
    } on SyncException {
      rethrow;
    } catch (e) {
      if (processed > 0 || seenItemIds.isNotEmpty) {
        throw SyncException('连接中断（已完成 $processed 条并已保存，剩余消息将在下次同步继续）：$e');
      }
      throw SyncException('无法连接电脑端，请确认 USB 已连接并执行 adb reverse：$e');
    } finally {
      client.close();
    }

    return SyncOutcome(
      sent: pending.length,
      processed: processed,
      results: seenItemIds.length,
      failed: failed,
      warnings: warnings,
    );
  }
}

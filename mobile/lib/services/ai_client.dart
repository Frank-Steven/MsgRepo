import 'dart:async';
import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/message.dart';
import 'categories.dart';
import 'junk_rules.dart';

/// AI 接口配置（设计 §8.1/§9）。电脑端条目自动生成（isDesktop=true），不持久化、不可删；
/// 远程接口以 JSON 列表存 shared_preferences。
class AiEndpoint {
  final String id;
  final String name;
  final String baseUrl;
  final String apiKey;
  final String model;
  final bool isDesktop;

  const AiEndpoint({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.apiKey = '',
    this.model = '',
    this.isDesktop = false,
  });

  factory AiEndpoint.fromJson(Map<String, dynamic> json) => AiEndpoint(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        baseUrl: json['baseUrl'] as String? ?? '',
        apiKey: json['apiKey'] as String? ?? '',
        model: json['model'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
      };

  AiEndpoint copyWith({
    String? name,
    String? baseUrl,
    String? apiKey,
    String? model,
  }) =>
      AiEndpoint(
        id: id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        isDesktop: isDesktop,
      );
}

/// 任务草稿（设计 §8.2）；startAt/endAt 已解析为本地时间。
class AiTaskDraft {
  final String title;
  final String? description;
  final String kind; // TaskKind.point | TaskKind.range
  final DateTime? startAt;
  final DateTime? endAt;
  final String priority; // TaskPriority.important | normal | minor

  const AiTaskDraft({
    required this.title,
    this.description,
    required this.kind,
    this.startAt,
    this.endAt,
    required this.priority,
  });

  static DateTime? _parseLocal(dynamic v) {
    if (v is! String || v.trim().isEmpty) return null;
    final dt = DateTime.tryParse(v.trim().replaceFirst(' ', 'T'));
    return dt;
  }

  factory AiTaskDraft.fromJson(Map<String, dynamic> json) => AiTaskDraft(
        title: (json['title'] as String? ?? '').trim(),
        description: (json['description'] as String?)?.trim(),
        kind: json['kind'] == 'range' ? 'range' : 'point',
        startAt: _parseLocal(json['startAt']),
        endAt: _parseLocal(json['endAt']),
        priority: const ['important', 'normal', 'minor'].contains(json['priority'])
            ? json['priority'] as String
            : 'normal',
      );
}

/// 单条消息的 AI 评估结果。
class AiProcessResult {
  final String messageId;
  final String priority; // MessagePriority.red | yellow | green | junk
  final String reason;
  final AiTaskDraft? taskDraft;

  const AiProcessResult({
    required this.messageId,
    required this.priority,
    required this.reason,
    this.taskDraft,
  });
}

/// AI 处理流式事件（设计 §8.3）。
sealed class AiEvent {
  const AiEvent();
}

class AiTokenDelta extends AiEvent {
  final String messageId;
  final String delta;
  const AiTokenDelta(this.messageId, this.delta);
}

class AiMessageResult extends AiEvent {
  final AiProcessResult result;
  const AiMessageResult(this.result);
}

class AiMessageError extends AiEvent {
  final String messageId;
  final String error;
  const AiMessageError(this.messageId, this.error);
}

class AiAllDone extends AiEvent {
  final int total;
  final int failed;
  const AiAllDone(this.total, this.failed);
}

class AiException implements Exception {
  final String message;
  AiException(this.message);
  @override
  String toString() => message;
}

/// AI 客户端（设计 §8.1）：电脑端在线（health 探测，30s 缓存）走 adb 通道 /v1/process，
/// 否则走设置中的默认远程 OpenAI 兼容接口（SSE 流式自行解析）。
class AiClient {
  AiClient._();

  static final AiClient instance = AiClient._();

  static const desktopEndpointId = 'desktop';
  static const desktopName = '电脑端';
  static const defaultDesktopBaseUrl = 'http://127.0.0.1:8765';

  // 与 v1 SyncClient 共用同一组 key，旧配对 token / 地址直接兼容
  static const _keyToken = 'pair_token';
  static const _keyBaseUrl = 'base_url';
  static const _keyEndpoints = 'ai_endpoints';
  static const _keyDefaultEndpoint = 'ai_default_endpoint';
  static const _keyDeviceName = 'desktop_device_name';
  static const keyCustomPrompt = 'custom_prompt';

  http.Client? _activeClient;
  bool _cancelled = false;

  /// 中断正在进行的处理（已产出的事件保留）。
  void cancelActive() {
    _cancelled = true;
    _activeClient?.close();
    _activeClient = null;
  }

  // ---- 接口配置 CRUD ----

  Future<String> getDesktopBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyBaseUrl) ?? defaultDesktopBaseUrl;
  }

  Future<void> setDesktopBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyBaseUrl, url);
  }

  /// 电脑端自动条目（置顶、不可删）。
  Future<AiEndpoint> desktopEndpoint() async => AiEndpoint(
        id: desktopEndpointId,
        name: desktopName,
        baseUrl: await getDesktopBaseUrl(),
        isDesktop: true,
      );

  Future<List<AiEndpoint>> getRemoteEndpoints() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_keyEndpoints);
    if (json == null) return [];
    try {
      return (jsonDecode(json) as List)
          .map((e) => AiEndpoint.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveRemoteEndpoints(List<AiEndpoint> endpoints) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _keyEndpoints, jsonEncode(endpoints.map((e) => e.toJson()).toList()));
  }

  Future<void> upsertEndpoint(AiEndpoint endpoint) async {
    final list = await getRemoteEndpoints();
    final i = list.indexWhere((e) => e.id == endpoint.id);
    if (i >= 0) {
      list[i] = endpoint;
    } else {
      list.add(endpoint);
    }
    await _saveRemoteEndpoints(list);
  }

  Future<void> deleteEndpoint(String id) async {
    if (id == desktopEndpointId) return;
    final list = await getRemoteEndpoints();
    list.removeWhere((e) => e.id == id);
    await _saveRemoteEndpoints(list);
    if (await getDefaultEndpointId() == id) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyDefaultEndpoint);
    }
  }

  /// 默认远程接口 id；null 表示未选（电脑端始终自动优先，不参与默认选择）。
  Future<String?> getDefaultEndpointId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyDefaultEndpoint);
  }

  Future<void> setDefaultEndpointId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDefaultEndpoint, id);
  }

  Future<AiEndpoint?> defaultRemoteEndpoint() async {
    final list = await getRemoteEndpoints();
    if (list.isEmpty) return null;
    final id = await getDefaultEndpointId();
    for (final e in list) {
      if (e.id == id) return e;
    }
    return list.first;
  }

  String newEndpointId() => const Uuid().v4();

  // ---- 电脑端配对 / 探测 ----

  Future<String> getDesktopToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyToken) ?? '';
  }

  Future<void> setDesktopToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyToken, token);
  }

  /// POST /v1/pair（免认证）：无 body 取当前 token，reset=true 重新签发。
  /// 返回 (token, deviceName)。
  Future<(String, String)> pairDesktop({bool reset = false}) async {
    final baseUrl = await getDesktopBaseUrl();
    final resp = await http
        .post(
          Uri.parse('$baseUrl/v1/pair'),
          headers: {'Content-Type': 'application/json'},
          body: reset ? '{"reset":true}' : null,
        )
        .timeout(const Duration(seconds: 5));
    if (resp.statusCode != 200) {
      throw AiException('配对失败 HTTP ${resp.statusCode}');
    }
    final data = (jsonDecode(resp.body) as Map).cast<String, dynamic>();
    final token = data['token'] as String? ?? '';
    if (token.isEmpty) throw AiException('配对响应缺少 token');
    await setDesktopToken(token);
    final deviceName = data['deviceName'] as String? ?? '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDeviceName, deviceName);
    return (token, deviceName);
  }

  /// 最近一次配对返回的电脑端设备名。
  Future<String> getDesktopDeviceName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyDeviceName) ?? '';
  }

  bool? _desktopOnlineCache;
  DateTime? _desktopOnlineAt;

  /// 电脑端在线探测：GET /v1/health，超时 2s，结果缓存 30s（设计 §8.1）。
  Future<bool> isDesktopOnline({bool force = false}) async {
    final cachedAt = _desktopOnlineAt;
    if (!force &&
        _desktopOnlineCache != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < const Duration(seconds: 30)) {
      return _desktopOnlineCache!;
    }
    final baseUrl = await getDesktopBaseUrl();
    var ok = false;
    try {
      final resp = await http
          .get(Uri.parse('$baseUrl/v1/health'))
          .timeout(const Duration(seconds: 2));
      ok = resp.statusCode == 200;
    } catch (_) {
      ok = false;
    }
    _desktopOnlineCache = ok;
    _desktopOnlineAt = DateTime.now();
    return ok;
  }

  /// 测试接口连通：电脑端打 /v1/pair（顺带刷新 token），远程打 /v1/models。
  /// 成功返回描述文字，失败抛 AiException。
  Future<String> testEndpoint(AiEndpoint endpoint) async {
    if (endpoint.isDesktop) {
      final (_, deviceName) = await pairDesktop();
      await isDesktopOnline(force: true);
      return '已连接${deviceName.isNotEmpty ? '：$deviceName' : ''}';
    }
    final headers = <String, String>{};
    if (endpoint.apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${endpoint.apiKey}';
    }
    final http.Response resp;
    try {
      resp = await http
          .get(Uri.parse('${endpoint.baseUrl}/models'), headers: headers)
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      throw AiException('无法连接：$e');
    }
    if (resp.statusCode != 200) {
      throw AiException('HTTP ${resp.statusCode}');
    }
    try {
      final data = (jsonDecode(resp.body) as Map).cast<String, dynamic>();
      final count = (data['data'] as List?)?.length;
      return count != null ? '连通正常（$count 个模型）' : '连通正常';
    } catch (_) {
      return '连通正常';
    }
  }

  // ---- 处理 ----

  /// 单次批量的消息数上限（v2.6.1 省 Token：批量合并请求，分批发送）。
  static const batchSize = 10;

  /// 路由（设计 §8.1）：电脑端在线走 /v1/process，否则走默认远程接口。
  /// v2.6.1 省 Token 策略：送模型前先跑本地垃圾规则预过滤（命中直接判
  /// junk、reason 标「规则判定」，不消耗 Token）；其余按 [batchSize] 分批，
  /// 每批合并为一次请求（系统提示词只传一次）。
  Stream<AiEvent> process(List<Message> msgs) async* {
    _cancelled = false;
    if (msgs.isEmpty) {
      yield const AiAllDone(0, 0);
      return;
    }
    // 本地规则预过滤（两端同一套规则，desktop/src/ai/junk-rules.ts）
    final toEval = <Message>[];
    for (final m in msgs) {
      final hit = junkRuleHit(m);
      if (hit != null) {
        yield AiMessageResult(AiProcessResult(
          messageId: m.id,
          priority: MessagePriority.junk,
          reason: hit,
        ));
      } else {
        toEval.add(m);
      }
    }
    if (toEval.isEmpty) {
      yield AiAllDone(msgs.length, 0);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final customPrompt = prefs.getString(keyCustomPrompt)?.trim() ?? '';

    if (await isDesktopOnline()) {
      final settled = <String>{};
      try {
        await for (final ev in _processViaDesktop(toEval, customPrompt)) {
          if (ev is AiMessageResult) settled.add(ev.result.messageId);
          if (ev is AiMessageError) settled.add(ev.messageId);
          yield ev;
        }
        return;
      } on AiException catch (e) {
        // 通道层失败（连不上/配对失败/断流）：只标记尚无结果的消息
        var failed = 0;
        for (final m in toEval) {
          if (settled.contains(m.id)) continue;
          failed++;
          yield AiMessageError(m.id, e.message);
        }
        yield AiAllDone(toEval.length, failed);
        return;
      }
    }

    final endpoint = await defaultRemoteEndpoint();
    if (endpoint == null) {
      for (final m in toEval) {
        yield AiMessageError(m.id, '电脑端不在线且未配置远程 AI 接口（设置 → AI 接口）');
      }
      yield AiAllDone(toEval.length, toEval.length);
      return;
    }
    var failed = 0;
    // 批量合并请求：每批一次调用，流式原文归到批首消息的卡片，
    // 完成后按 messageId 拆分结果（v2.6.1）
    for (var i = 0; i < toEval.length; i += batchSize) {
      if (_cancelled) break;
      final batch = toEval.sublist(
          i, i + batchSize > toEval.length ? toEval.length : i + batchSize);
      try {
        await for (final ev in _processBatchViaRemote(batch, endpoint, customPrompt)) {
          yield ev;
        }
      } on AiException catch (e) {
        failed += batch.length;
        for (final m in batch) {
          yield AiMessageError(m.id, e.message);
        }
      }
    }
    yield AiAllDone(toEval.length, failed);
  }

  // ---- 电脑端通道：POST /v1/process，NDJSON 事件流 ----

  Stream<AiEvent> _processViaDesktop(List<Message> msgs, String customPrompt) async* {
    final baseUrl = await getDesktopBaseUrl();
    final now = DateTime.now();

    http.Request buildRequest(String token) {
      final req = http.Request('POST', Uri.parse('$baseUrl/v1/process'));
      req.headers['Content-Type'] = 'application/json';
      if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
      req.body = jsonEncode({
        'messages': [
          for (final m in msgs)
            {
              'id': m.id,
              'title': m.title,
              'body': m.body,
              if (m.appName != null) 'appName': m.appName,
              if (m.conversationTitle != null)
                'conversationTitle': m.conversationTitle,
              if (m.sender != null) 'sender': m.sender,
              'postedAt': m.postedAt,
            },
        ],
        if (customPrompt.isNotEmpty) 'customPrompt': customPrompt,
        'now': now.toIso8601String(),
        'timezone': now.timeZoneName,
      });
      return req;
    }

    final client = http.Client();
    _activeClient = client;
    try {
      var streamed = await client
          .send(buildRequest(await getDesktopToken()))
          .timeout(const Duration(seconds: 15));
      if (streamed.statusCode == 401) {
        // 自动配对（设计 §11）：401 时调一次 /v1/pair 并重试
        await streamed.stream.bytesToString();
        final (token, _) = await pairDesktop();
        streamed = await client
            .send(buildRequest(token))
            .timeout(const Duration(seconds: 15));
      }
      if (streamed.statusCode != 200) {
        final errBody = await streamed.stream.bytesToString();
        throw AiException('电脑端处理失败 HTTP ${streamed.statusCode}：$errBody');
      }
      var sawDone = false;
      await for (final line
          in _lines(streamed.stream).timeout(const Duration(seconds: 240))) {
        final ev = _parseDesktopEvent(line);
        if (ev == null) continue;
        if (ev is AiAllDone) sawDone = true;
        yield ev;
      }
      if (!sawDone) {
        throw AiException('连接中断，未收到完成事件');
      }
    } on AiException {
      rethrow;
    } catch (e) {
      if (_activeClient == null) return; // 被 cancelActive 中断
      throw AiException('无法连接电脑端：$e');
    } finally {
      if (_activeClient == client) _activeClient = null;
      client.close();
    }
  }

  AiEvent? _parseDesktopEvent(String line) {
    Map<String, dynamic> ev;
    try {
      ev = (jsonDecode(line) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
    final messageId = ev['messageId'] as String? ?? '';
    switch (ev['type']) {
      case 'token':
        return AiTokenDelta(messageId, ev['delta'] as String? ?? '');
      case 'result':
        final draft = ev['taskDraft'];
        return AiMessageResult(AiProcessResult(
          messageId: messageId,
          priority: _normalizePriority(ev['priority']),
          reason: ev['reason'] as String? ?? '',
          taskDraft:
              draft is Map ? AiTaskDraft.fromJson(draft.cast<String, dynamic>()) : null,
        ));
      case 'error':
        return AiMessageError(messageId, ev['error'] as String? ?? '未知错误');
      case 'done':
        return AiAllDone(
          (ev['total'] as num?)?.toInt() ?? 0,
          (ev['failed'] as num?)?.toInt() ?? 0,
        );
    }
    return null;
  }

  // ---- 远程接口：OpenAI 兼容 /chat/completions，SSE 自行解析 ----

  /// 批量评估（v2.6.1）：多条消息合并一次请求，schema 返回结果数组按
  /// messageId 一一对应；流式原始输出归到批首消息的卡片，完成后按消息拆分。
  Stream<AiEvent> _processBatchViaRemote(
      List<Message> batch, AiEndpoint endpoint, String customPrompt) async* {
    final now = DateTime.now();
    final streamId = batch.first.id; // 流式原文归属的卡片（批首消息）

    final req = http.Request(
        'POST', Uri.parse('${endpoint.baseUrl}/chat/completions'));
    req.headers['Content-Type'] = 'application/json';
    if (endpoint.apiKey.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer ${endpoint.apiKey}';
    }
    req.body = jsonEncode({
      'model': endpoint.model,
      'temperature': 0,
      'stream': true,
      'messages': [
        {'role': 'system', 'content': _buildBatchSystemPrompt(customPrompt)},
        {'role': 'user', 'content': _buildBatchUserContent(batch, now)},
      ],
    });

    final client = http.Client();
    _activeClient = client;
    try {
      final streamed =
          await client.send(req).timeout(const Duration(seconds: 30));
      if (streamed.statusCode != 200) {
        final errBody = await streamed.stream.bytesToString();
        throw AiException('远程接口返回 ${streamed.statusCode}：$errBody');
      }
      final full = StringBuffer();
      await for (final line
          in _lines(streamed.stream).timeout(const Duration(seconds: 180))) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') break;
        Map<String, dynamic> json;
        try {
          json = (jsonDecode(data) as Map).cast<String, dynamic>();
        } catch (_) {
          continue;
        }
        final choices = json['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final delta = (choices.first as Map)['delta'];
        final content = (delta is Map) ? delta['content'] : null;
        if (content is String && content.isNotEmpty) {
          full.write(content);
          yield AiTokenDelta(streamId, content);
        }
      }
      final results = parseBatchEvalOutput(batch, full.toString());
      for (final m in batch) {
        final r = results[m.id];
        if (r != null) {
          yield AiMessageResult(r);
        } else {
          yield AiMessageError(m.id, '模型未返回该条结果');
        }
      }
    } on AiException {
      rethrow;
    } catch (e) {
      if (_activeClient == null) return; // 被 cancelActive 中断
      throw AiException('远程接口调用失败：$e');
    } finally {
      if (_activeClient == client) _activeClient = null;
      client.close();
    }
  }

  /// 批量评估系统提示词（与 desktop buildEvalBatchSystemPrompt 逐条一致，
  /// 设计 §8.2）：schema 为结果数组，元素按 messageId 对应输入消息。
  String _buildBatchSystemPrompt(String customPrompt) {
    final catList = kPromptCategories
        .map((c) =>
            '- ${c.key}（${c.displayName}）: ${c.description}'
            '${c.priorityHints != null ? ' 优先级提示：${c.priorityHints}' : ''}')
        .join('\n');
    var prompt = '你是消息评估助手。用户消息里有「消息列表」，为其中每条消息输出一个评估对象，'
        '整体组成一个 JSON 数组（顺序与输入一致）：\n'
        '[{"messageId":"输入消息的 messageId","priority":"red|yellow|green|junk",'
        '"reason":"一句话理由","taskDraft":null 或 '
        '{"title":"...","description":"...","kind":"point|range","startAt":"YYYY-MM-DDTHH:mm",'
        '"endAt":"YYYY-MM-DDTHH:mm","priority":"important|normal|minor"}}]\n'
        'priority 语义：red=重要、yellow=值得关注、green=一般、junk=垃圾（营销、推广、无用系统提示等）。'
        '判断重要与垃圾是首要职责。结合来源应用与会话语境判断（如银行/支付类通知多重要、'
        '应用商店的推广多为垃圾）。\n'
        'taskDraft 规则：\n'
        '- 消息包含明确可执行事项时给出，否则为 null；值得留存备查但无需执行的内容'
        '（笔记类，如账号信息、地址、灵感）也给 taskDraft，priority=minor。\n'
        '- title 不超过 20 个字符（中文按 2 字符计），超长的细节放入 description。\n'
        '- kind=point 时点任务只需 startAt；kind=range 时段任务需要 startAt 和 endAt；'
        '没有明确时间的可执行事项省略 startAt/endAt（不定时任务）。\n'
        '- 消息包含一个主事项和多个子步骤时，只给主事项草稿，子步骤以换行列表写进 '
        'description，不要拆成多个草稿。\n'
        '- 任务 priority：important=重要、normal=一般、minor=不重要。\n'
        '时间用本地时间字符串 "YYYY-MM-DDTHH:mm" 输出（不要自行换算毫秒），相对日期（如"本周五""下周一"）'
        '查用户消息里的日期对照表确定；解析出的时间必须晚于基准时间：若字面日期标注了"已过去"，顺延到下一个未来的同名日期。\n'
        '分类参考（辅助判断重要性与垃圾）：\n$catList\n'
        '只输出 JSON 数组。';
    if (customPrompt.isNotEmpty) {
      prompt +=
          '\n用户附加要求（优先级高于默认规则，但不违反输出 JSON 格式）：\n$customPrompt';
    }
    return prompt;
  }

  /// 上下文裁剪（v2.6.1 省 Token）：标题 100 字符、正文 500 字符截断。
  static const titleMaxChars = 100;
  static const bodyMaxChars = 500;

  static String _truncate(String text, int max) {
    final chars = text.characters;
    if (chars.length <= max) return text;
    return '${chars.take(max)}…（已截断）';
  }

  String _buildBatchUserContent(List<Message> batch, DateTime now) {
    String fmt(DateTime d) =>
        '${d.year}年${d.month}月${d.day}日（周${'日一二三四五六'[d.weekday % 7]}）'
        ' ${d.hour}:${d.minute.toString().padLeft(2, '0')}';
    return jsonEncode({
      '基准时间': fmt(now),
      '日期对照表': _buildDateHints(now),
      '消息列表': [
        for (final m in batch)
          {
            'messageId': m.id,
            '消息时间': fmt(DateTime.fromMillisecondsSinceEpoch(m.postedAt)),
            '来源应用': m.appName,
            '会话': m.conversationTitle,
            '发送者': m.sender,
            '标题': _truncate(m.title, titleMaxChars),
            '正文': _truncate(m.body, bodyMaxChars),
          },
      ],
    });
  }

  /// 日期对照表（与 desktop buildDateHints 一致，周一为一周第一天）。
  String _buildDateHints(DateTime base) {
    const weekChars = '日一二三四五六';
    String fmt(DateTime d) =>
        '${d.year}年${d.month}月${d.day}日（周${weekChars[d.weekday % 7]}）';
    DateTime day(int offset) =>
        DateTime(base.year, base.month, base.day + offset, base.hour,
            base.minute);
    final lines = ['今天=${fmt(day(0))}', '明天=${fmt(day(1))}', '后天=${fmt(day(2))}'];
    final dow = base.weekday - 1; // 周一=0
    const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    for (var i = 0; i < 7; i++) {
      lines.add('本${names[i]}=${fmt(day(i - dow))}${i - dow < 0 ? '（已过去）' : ''}');
    }
    for (var i = 0; i < 7; i++) {
      lines.add('下${names[i]}=${fmt(day(i - dow + 7))}');
    }
    return lines.join('\n');
  }

  static String _normalizePriority(dynamic v) {
    const valid = ['red', 'yellow', 'green', 'junk'];
    return valid.contains(v) ? v as String : 'green';
  }

  /// 解析批量评估输出：取首个 [ 到末个 ] 的 JSON 数组，按 messageId 建 map。
  /// 容忍 markdown 围栏/前后缀文字；数组中缺 messageId 或 id 不在批次内的
  /// 元素忽略；完全没有合法数组时抛 AiException（整批报错）。
  static Map<String, AiProcessResult> parseBatchEvalOutput(
      List<Message> batch, String content) {
    final start = content.indexOf('[');
    final end = content.lastIndexOf(']');
    if (start == -1 || end <= start) {
      throw AiException(
          '模型未返回 JSON 数组：${content.substring(0, content.length > 200 ? 200 : content.length)}');
    }
    List<dynamic> arr;
    try {
      arr = jsonDecode(content.substring(start, end + 1)) as List<dynamic>;
    } catch (e) {
      throw AiException('模型输出 JSON 解析失败：$e');
    }
    final known = {for (final m in batch) m.id};
    final results = <String, AiProcessResult>{};
    for (final item in arr) {
      if (item is! Map) continue;
      final map = item.cast<String, dynamic>();
      final id = map['messageId'] as String?;
      if (id == null || !known.contains(id)) continue;
      final draft = map['taskDraft'];
      results[id] = AiProcessResult(
        messageId: id,
        priority: _normalizePriority(map['priority']),
        reason: map['reason'] as String? ?? '',
        taskDraft: draft is Map
            ? AiTaskDraft.fromJson(draft.cast<String, dynamic>())
            : null,
      );
    }
    return results;
  }

  /// StreamedResponse 字节流 → utf8 分行（跨 chunk 的行缓存拼接）。
  Stream<String> _lines(http.ByteStream stream) {
    final buf = StringBuffer();
    return stream.transform(utf8.decoder).expand((chunk) {
      buf.write(chunk);
      final text = buf.toString();
      final lines = <String>[];
      var consumed = 0;
      var nl = text.indexOf('\n');
      while (nl >= 0) {
        final line = text.substring(consumed, nl).trim();
        if (line.isNotEmpty) lines.add(line);
        consumed = nl + 1;
        nl = text.indexOf('\n', consumed);
      }
      buf.clear();
      buf.write(text.substring(consumed));
      return lines;
    });
  }
}

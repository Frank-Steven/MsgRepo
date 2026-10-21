import 'dart:async';
import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'prompt_rules.dart';
import 'secret_store.dart';
import 'package:uuid/uuid.dart';

import '../models/message.dart';
import 'categories.dart';
import 'junk_rules.dart';
import '../services/app_log.dart';

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

  factory AiTaskDraft.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] == 'range' ? 'range' : 'point';
    return AiTaskDraft(
      title: (json['title'] as String? ?? '').trim(),
      description: (json['description'] as String?)?.trim(),
      kind: kind,
      startAt: _parseLocal(json['startAt']),
      // point 任务只保留单个时刻：模型偶尔会多写 endAt，这里直接丢弃（P1-1）
      endAt: kind == 'range' ? _parseLocal(json['endAt']) : null,
      priority:
          const ['important', 'normal', 'minor'].contains(json['priority'])
              ? json['priority'] as String
              : 'normal',
    );
  }
}

/// 单条消息的 AI 评估结果。
class AiProcessResult {
  final String messageId;
  final String priority; // MessagePriority.red | yellow | green | junk
  final String reason;

  /// 兼容字段：第一条任务草稿（旧调用点仍读它）。
  final AiTaskDraft? taskDraft;

  /// N1：一条消息可以产出多个任务草稿（0..n）。
  final List<AiTaskDraft> taskDrafts;

  const AiProcessResult({
    required this.messageId,
    required this.priority,
    required this.reason,
    this.taskDraft,
    this.taskDrafts = const [],
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

  /// 凭据存储（P2-1）：key 与配对 token 走安全存储；测试可替换为内存实现。
  static SecretStore secretStore = SecureSecretStore();

  static String _secretKeyFor(String endpointId) => 'ai_key_$endpointId';

  // ---- O06：HTTP 客户端复用 ----
  //
  // 原来每个请求都 `http.Client()` … `close()`：160 条消息 = 160 次 TLS 握手。
  // 现在整个实例复用一个 client（连接池也跟着复用），取消/关闭时丢弃并重建，
  // 保证任何路径都不会复用「已关闭」的实例。
  /// 客户端工厂：测试可替换以注入 fake client / 统计创建次数。
  static http.Client Function() clientFactory = () => http.Client();

  http.Client? _http;

  /// 复用的 HTTP 客户端（首次使用时创建）。
  http.Client get _client => _http ??= clientFactory();

  /// 关闭并丢弃复用的客户端（取消中断 / 测试收尾用）；下次请求会重新创建。
  void closeClient() {
    final c = _http;
    _http = null;
    _activeClient = null;
    if (c != null) c.close();
  }

  /// 在途请求的标记（只用于「被 cancelActive 中断」的判定，不等于连接本身）。
  http.Client? _activeClient;
  bool _cancelled = false;

  /// 在途 HTTP 请求数（Q11 护栏，2026-10-21 用户裁决「接受现状」）。
  ///
  /// 因为 client 现在全实例复用，`cancelActive()` 会中断**所有**在途请求；
  /// 当前产品路径 `ai_processing` 串行（`_pumping`）不会并发，所以是可接受的。
  /// 这里只做「悄悄出现并发就报警」，防止将来有人加了并发调用却查不出偶发失败。
  int _inflight = 0;

  /// 当前在途请求数（测试/诊断用）。
  int get inflightCount => _inflight;

  /// 中断正在进行的处理（已产出的事件保留）。
  ///
  /// 注意：client 共享 → 这里会中断**全部**在途请求（见 Q11 / `_inflight` 注释）。
  void cancelActive() {
    _cancelled = true;
    if (_inflight > 1) {
      // 并发尚未支持：这里喊一声，别让「取消 A 顺手弄死 B」变成无迹可寻的偶发 bug。
      AppLog.instance.warn(
        'ai.cancel-concurrent',
        StateError('cancelActive 时有 $_inflight 个在途请求，将全部中断（当前只支持单路 AI 请求）'),
        StackTrace.current,
      );
    }
    closeClient(); // 关掉在途连接，并丢弃实例（下次请求重建）
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
    List<AiEndpoint> parsed;
    try {
      parsed = (jsonDecode(json) as List)
          .map((e) => AiEndpoint.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (e, st) {
      AppLog.instance.warn('ai.read-endpoints', e, st);
      return [];
    }

    // P2-1：密钥单独从安全存储取；同时把旧版明文 key 迁移出去。
    var migrated = false;
    final withKeys = <AiEndpoint>[];
    for (final e in parsed) {
      final stored = await secretStore.read(_secretKeyFor(e.id)) ?? '';
      final legacy = e.apiKey;
      if (legacy.isNotEmpty && stored.isEmpty) {
        await secretStore.write(_secretKeyFor(e.id), legacy);
        migrated = true;
      }
      withKeys.add(e.copyWith(apiKey: legacy.isNotEmpty ? legacy : stored));
    }
    if (migrated) {
      await _saveRemoteEndpoints(withKeys);
      AppLog.instance.warn('ai.migrate-keys',
          StateError('已把 ${withKeys.length} 个接口的明文 key 迁入安全存储'));
    }
    return withKeys;
  }

  Future<void> _saveRemoteEndpoints(List<AiEndpoint> endpoints) async {
    final prefs = await SharedPreferences.getInstance();
    // P2-1：密钥进安全存储，SharedPreferences 里只留不含 key 的配置。
    final plain = <Map<String, dynamic>>[];
    for (final e in endpoints) {
      if (e.apiKey.isNotEmpty) {
        await secretStore.write(_secretKeyFor(e.id), e.apiKey);
      } else {
        await secretStore.delete(_secretKeyFor(e.id));
      }
      plain.add(e.toJson()..remove('apiKey'));
    }
    await prefs.setString(_keyEndpoints, jsonEncode(plain));
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
    await secretStore.delete(_secretKeyFor(id));
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

  // P2-1：配对 token 同样是凭据，一起放进安全存储；旧值自动迁移一次。
  Future<String> getDesktopToken() async {
    final stored = await secretStore.read(_keyToken) ?? '';
    if (stored.isNotEmpty) return stored;
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(_keyToken) ?? '';
    if (legacy.isNotEmpty) {
      await secretStore.write(_keyToken, legacy);
      await prefs.remove(_keyToken);
    }
    return legacy;
  }

  Future<void> setDesktopToken(String token) async {
    await secretStore.write(_keyToken, token);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyToken); // 清掉可能存在的明文旧值
  }

  /// POST /v1/pair（免认证）：无 body 取当前 token，reset=true 重新签发。
  /// 返回 (token, deviceName)。
  Future<(String, String)> pairDesktop({bool reset = false}) async {
    final baseUrl = await getDesktopBaseUrl();
    final resp = await _client
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
      final resp = await _client
          .get(Uri.parse('$baseUrl/v1/health'))
          .timeout(const Duration(seconds: 2));
      ok = resp.statusCode == 200;
    } catch (e, st) {
      AppLog.instance.warn('ai.health', e, st);
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
    final hint = endpointConfigHint(endpoint.baseUrl);
    if (hint != null) throw AiException(hint);
    final headers = <String, String>{};
    if (endpoint.apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${endpoint.apiKey}';
    }
    final url = joinEndpointUrl(endpoint.baseUrl, 'models');
    final http.Response resp;
    try {
      resp = await _client
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      throw AiException('无法连接 $url：$e');
    }
    if (resp.statusCode != 200) {
      final detail = describeUpstreamError(resp.body);
      throw AiException('HTTP ${resp.statusCode} @ $url${detail.isEmpty ? '' : '：$detail'}');
    }
    // 成功时把模型 id 列出来（U1/N2）：上游只校验 /models 不校验模型名，
    // 用户很容易填成版本号（如 DeepSeek-V41-Flash）导致真实调用 400。
    final ids = <String>[];
    try {
      final data = (jsonDecode(resp.body) as Map).cast<String, dynamic>();
      final list = data['data'];
      if (list is List) {
        for (final m in list) {
          if (m is Map && m['id'] is String) ids.add(m['id'] as String);
        }
      }
    } catch (e, st) { AppLog.instance.warn('ai.parse-models', e, st); }
    if (ids.isEmpty) return '连通正常';
    final shown = ids.take(5).join('、');
    return '连通正常（${ids.length} 个模型：$shown${ids.length > 5 ? '…' : ''}）';
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
    // U2：结构化规则（类型 → 处理方式）+ 自由文本，拼成同一条附加要求下发；
    // 自由文本沿用原 key（custom_prompt），老用户已写的内容不受影响。
    final customPrompt = composeCustomPrompt(
      rules: await PromptRulesStore.load(),
      freeText: prefs.getString(keyCustomPrompt) ?? '',
    );

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
        // P1-2（已收紧）：只有「模型输出不合格」才降级逐条重试；配置/网络类错误
        // 整批会以同样方式失败，逐条重发等于把一份全量提示词付 N 次（实测 15 条消息
        // 被放大成 15 次全量请求，拖慢速度且烧 token）。
        if (batch.length == 1 || !shouldRetryPerMessage(e.message)) {
          failed += batch.length;
          for (final m in batch) {
            yield AiMessageError(m.id, e.message);
          }
          continue;
        }
        for (final m in batch) {
          if (_cancelled) break;
          var gotResult = false;
          try {
            await for (final ev
                in _processBatchViaRemote([m], endpoint, customPrompt)) {
              if (ev is AiMessageResult) gotResult = true;
              yield ev;
            }
          } on AiException catch (e2) {
            if (!gotResult) {
              failed++;
              yield AiMessageError(m.id, e2.message);
            }
            continue;
          }
          if (!gotResult) failed++;
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

    final client = _client;
    _activeClient = client;
    _inflight++;
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
      // O06：客户端复用，这里只解除「在途」标记；需要中断请走 cancelActive()
      if (_activeClient == client) _activeClient = null;
      _inflight--;
    }
  }

  AiEvent? _parseDesktopEvent(String line) {
    Map<String, dynamic> ev;
    try {
      ev = (jsonDecode(line) as Map).cast<String, dynamic>();
    } catch (e, st) {
      AppLog.instance.warn('ai.ndjson-line', e, st);
      return null;
    }
    final messageId = ev['messageId'] as String? ?? '';
    switch (ev['type']) {
      case 'token':
        return AiTokenDelta(messageId, ev['delta'] as String? ?? '');
      case 'result':
        final drafts = parseTaskDrafts(ev['taskDraft'], ev['taskDrafts']);
        return AiMessageResult(AiProcessResult(
          messageId: messageId,
          priority: _normalizePriority(ev['priority']),
          reason: ev['reason'] as String? ?? '',
          taskDraft: drafts.isEmpty ? null : drafts.first,
          taskDrafts: drafts,
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

    final hint = endpointConfigHint(endpoint.baseUrl);
    if (hint != null) throw AiException(hint);
    final url = joinEndpointUrl(endpoint.baseUrl, 'chat/completions');
    final req = http.Request('POST', Uri.parse(url));
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

    final client = _client;
    _activeClient = client;
    _inflight++;
    try {
      final streamed =
          await client.send(req).timeout(const Duration(seconds: 30));
      if (streamed.statusCode != 200) {
        final errBody = await streamed.stream.bytesToString();
        throw AiException(
            '远程接口返回 ${streamed.statusCode} @ $url：${describeUpstreamError(errBody)}');
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
        } catch (e, st) {
          AppLog.instance.warn('ai.sse-json', e, st);
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
      // O06：同上，不关闭复用实例
      if (_activeClient == client) _activeClient = null;
      _inflight--;
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
        '"reason":"一句话理由","taskDrafts":['
        '{"title":"...","description":"...","kind":"point|range","startAt":"YYYY-MM-DDTHH:mm",'
        '"endAt":"YYYY-MM-DDTHH:mm","priority":"important|normal|minor"}]}]\n'
        'priority 语义：red=重要、yellow=值得关注、green=一般、junk=垃圾（营销、推广、无用系统提示等）。'
        '判断重要与垃圾是首要职责。结合来源应用与会话语境判断（如银行/支付类通知多重要、'
        '应用商店的推广多为垃圾）。\n'
        'taskDrafts 规则（数组，最多 3 个；**没有可执行事项就给空数组 []**，这是常态）：\n'
        '- 判断标准只有一句：**用户还得动手去做**吗？说不清「做什么/对谁/什么时候」的一律不给草稿。\n'
        '- 一条消息里有多件互不相关的事，每件给一个草稿；同一件事的多个步骤仍只给一个草稿。\n'
        // 2026-10-20 用户与合作者决定：不再产出「笔记类草稿」（不能加附件时与手机备忘录重合；
        // 笔记模块本身砍不砍以后再定，见 TODO Q08）。提示词里对应规则已删除。
        '- 消息本身不带可执行动作时（账号信息、地址、灵感、要买的东西等）**不要**给草稿；\n'
        '  「值得留存备查」不构成建任务的理由。\n'
        '- **以下一律给空数组 []**（这些不是待办）：\n'
        '  · 支付/扣款/消费回执（“您账户…发生快捷支付扣款人民币42.76”“支付成功”“到账通知”）；\n'
        '  · 应用更新/升级提示、应用商店推送、版本发布公告、系统升级完成；\n'
        '  · 群公告、有人在群里问话/@你、催你回复 —— 那是聊天，不是待办；\n'
        '    除非原消息明确约定了事项与时间（如“明晚8点前把表发我”“周五前交报名表”）；\n'
        '  · 系统状态提示（充电、USB、Wi-Fi/信号、电量、蓝牙）；\n'
        '  · 纯告知、营销、广告、验证码、物流泛通知（“预计明天送达”这类无动作的）。\n'
        '- **禁止把消息标题换个说法抄成任务**：「回复<某人/某群>」「更新<某应用>」「留意<某事>」这类模板化短语不是任务，\n'
        '  除非消息里给了明确的时间或交付物。\n'
        '- title 不超过 20 个字符（中文按 2 字符计），超长的细节放入 description。\n'
        '- kind=point 时点任务只需 startAt；kind=range 时段任务需要 startAt 和 endAt；'
        '没有明确时间的可执行事项省略 startAt/endAt（不定时任务）。\n'
        '- 同一件事的多步骤在主事项草稿里用换行列表写进 description；互不相关的事才拆成多个草稿。\n'
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

  /// 拼接 baseUrl 与接口路径：去掉尾部多余斜杠，避免 `//` 之类的 404（N2 诊断）。
  static String joinEndpointUrl(String baseUrl, String path) {
    final trimmed = baseUrl.trim();
    final noTrail = trimmed.replaceAll(RegExp(r'/+$'), '');
    return noTrail.isEmpty ? path : '$noTrail/$path';
  }

  /// 整批失败后是否值得降级为逐条重试（P1-2 收紧，2026-10-18）。
  ///
  /// 只有「模型输出本身不合格」才逐条重试——这类失败往往由某一条的上下文触发，
  /// 拆开重发有意义。配置错误（400 模型名 / 401 鉴权 / 404 路径）、网络、超时
  /// 会让整批以同样方式失败，逐条重发等于把同一份全量提示词付 N 次钱。
  /// 真机实测：模型名配错时 15 条消息被放大成 15 次全量请求（用户反馈
  /// 「每条消息单独发送，拖累速度且增加 token 消耗」）。
  static bool shouldRetryPerMessage(String message) =>
      message.contains('模型未返回 JSON 数组') ||
      message.contains('模型输出 JSON 解析失败');

  /// 从上游响应里提取人类可读的错误信息（N2）。
  ///
  /// 上游常把真正原因放在 error.message 里（如 DeepSeek 的
  /// 「The supported API model names are …」），直接截断原始 JSON 会把它切掉。
  static String describeUpstreamError(String body) {
    final text = body.trim();
    if (text.isEmpty) return '';
    try {
      final data = jsonDecode(text);
      if (data is Map) {
        final err = data['error'];
        final msg = err is Map
            ? err['message']
            : (err is String ? err : data['message']);
        if (msg is String && msg.trim().isNotEmpty) return msg.trim();
      }
    } catch (_) {
      // 预期分支：上游返回的不是 JSON（纯文本错误），下面按原文截断即可
    }
    return text.length > 240 ? '${text.substring(0, 240)}…' : text;
  }

  /// 常见配置错误的前置提示（N2）：返回 null 表示没发现明显问题。
  /// 背景：DeepSeek 同时提供两种格式——Anthropic 格式的 base_url 是
  /// https://api.deepseek.com/anthropic ，而本应用走 OpenAI 兼容的
  /// /chat/completions 与 /models；把 Anthropic 地址填进来只会得到 401/404。
  static String? endpointConfigHint(String baseUrl) {
    final b = baseUrl.trim();
    final lower = b.toLowerCase();
    if (b.isEmpty) {
      return 'Base URL 为空：请填写接口地址（如 https://api.deepseek.com）';
    }
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return 'Base URL 需以 http:// 或 https:// 开头';
    }
    if (lower.endsWith('/anthropic') || lower.contains('/anthropic/')) {
      return '该地址是 Anthropic 兼容格式（…/anthropic），而本应用使用 OpenAI 兼容格式。'
          'DeepSeek 请改为 https://api.deepseek.com（去掉 /anthropic）。';
    }
    return null;
  }

  static String _normalizePriority(dynamic v) {
    const valid = ['red', 'yellow', 'green', 'junk'];
    return valid.contains(v) ? v as String : 'green';
  }

  /// 解析任务草稿（N1）：优先 `taskDrafts` 数组，兼容旧的单个 `taskDraft`。
  /// 空标题的草稿直接丢弃（模型偶尔给空壳）。
  static List<AiTaskDraft> parseTaskDrafts(dynamic single, dynamic multi) {
    final out = <AiTaskDraft>[];
    if (multi is List) {
      for (final e in multi) {
        if (e is! Map) continue;
        final d = AiTaskDraft.fromJson(e.cast<String, dynamic>());
        if (d.title.trim().isNotEmpty) out.add(d);
      }
    }
    if (out.isEmpty && single is Map) {
      final d = AiTaskDraft.fromJson(single.cast<String, dynamic>());
      if (d.title.trim().isNotEmpty) out.add(d);
    }
    return out;
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
      final drafts = parseTaskDrafts(map['taskDraft'], map['taskDrafts']);
      results[id] = AiProcessResult(
        messageId: id,
        priority: _normalizePriority(map['priority']),
        reason: map['reason'] as String? ?? '',
        taskDraft: drafts.isEmpty ? null : drafts.first,
        taskDrafts: drafts,
      );
    }
    return results;
  }

  /// StreamedResponse 字节流 → utf8 分行（跨 chunk 的行缓存拼接）。
  /// 按行切分流式响应（SSE / NDJSON）。
  ///
  /// 2026-10-20 性能修复：原实现每个 chunk 都 `buf.toString()` 整串复制再 substring，
  /// 长流是 O(n²) 且跑在 UI isolate；现在用可变缓冲 + 已消费位置原地推进，
  /// 只保留没读完的尾行。
  Stream<String> _lines(http.ByteStream stream) {
    final pending = StringBuffer();
    return stream.transform(utf8.decoder).expand((chunk) {
      pending.write(chunk);
      final text = pending.toString();
      final lines = <String>[];
      var consumed = 0;
      var nl = text.indexOf('\n');
      while (nl >= 0) {
        final line = text.substring(consumed, nl).trim();
        if (line.isNotEmpty) lines.add(line);
        consumed = nl + 1;
        nl = text.indexOf('\n', consumed);
      }
      if (consumed > 0) {
        pending
          ..clear()
          ..write(text.substring(consumed));
      }
      return lines;
    });
  }
}

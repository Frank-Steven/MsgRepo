import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../ai_client.dart';
import 'models.dart';

/// desktop `GET /v1/models` 返回的一个模型条目（design-v3 §6.2）。
class DesktopModelEntry {
  final String id;
  final String name;
  final String provider;
  final String model;

  /// 连通性探测结果；null = 尚未探测。
  final bool? reachable;

  const DesktopModelEntry({
    required this.id,
    required this.name,
    required this.provider,
    required this.model,
    this.reachable,
  });

  factory DesktopModelEntry.fromJson(Map<String, dynamic> json) =>
      DesktopModelEntry(
        id: json['id'] as String,
        name: json['name'] as String? ?? json['id'] as String,
        provider: json['provider'] as String? ?? ModelProvider.openaiCompat,
        model: json['model'] as String? ?? '',
        reachable: json['reachable'] as bool?,
      );
}

/// 助理对话通道（design-v3 §3.6/§5.4、details §2.4）：
/// 复用 AiClient 的路由/配对/HTTP 基建，提供 /v1/chat SSE 解析与
/// 离线远程（OpenAI 兼容）通道。
///
/// 路由策略：
/// 1. 对话绑定的 modelConfigId 命中本地远程端点 → 直连该远程端点
///    （无论电脑端是否在线——绑定远程就是明确要求走它）；
/// 2. 否则电脑端在线 → POST /v1/chat（modelConfigId 透传给 desktop 路由，
///    远程端点 id 对 desktop 无意义，置空让 desktop 用默认模型）；
/// 3. 电脑端离线 → 默认远程端点（OpenAI 兼容 /chat/completions，SSE 自行解析）。
///
/// 工具说明书由调用方（assistant_service）组装进消息序列，本类不持有说明书。
class AssistantClient {
  AssistantClient._();

  static final AssistantClient instance = AssistantClient._();

  /// 独立通道实例（inbox.triage 子调用用，details §4）：与共享 [instance]
  /// 的在途请求/取消标记互不影响——子调用在回合流中途发起，
  /// 若共用单例会踩掉主对话的 _activeClient 簿记。
  AssistantClient.independent();

  http.Client? _http;
  http.Client? _activeClient;
  bool _cancelled = false;

  http.Client get _client => _http ??= AiClient.clientFactory();

  /// 中断在途对话（已产出的事件保留，details §2.2：未闭合块整体丢弃）。
  void cancelActive() {
    _cancelled = true;
    closeClient();
  }

  void closeClient() {
    final c = _http;
    _http = null;
    _activeClient = null;
    if (c != null) c.close();
  }

  /// 测试注入：替换底层 client / 复位取消标记。
  void debugReset() {
    _cancelled = false;
    closeClient();
  }

  // ---- 电脑端模型列表（model_picker 展示用） ----

  /// GET /v1/models；401 时自动配对一次重试。电脑端离线时抛 AiException。
  Future<({List<DesktopModelEntry> models, String? defaultModelId})>
      getDesktopModels() async {
    final ai = AiClient.instance;
    final baseUrl = await ai.getDesktopBaseUrl();
    Future<http.Response> request(String token) => _client.get(
          Uri.parse('$baseUrl/v1/models'),
          headers: {if (token.isNotEmpty) 'Authorization': 'Bearer $token'},
        );
    var resp = await request(await ai.getDesktopToken())
        .timeout(const Duration(seconds: 5));
    if (resp.statusCode == 401) {
      final (token, _) = await ai.pairDesktop();
      resp = await request(token).timeout(const Duration(seconds: 5));
    }
    if (resp.statusCode != 200) {
      throw AiException('拉取模型列表失败 HTTP ${resp.statusCode}');
    }
    final data = (jsonDecode(resp.body) as Map).cast<String, dynamic>();
    final models = ((data['models'] as List?) ?? const [])
        .map((e) => DesktopModelEntry.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    return (models: models, defaultModelId: data['defaultModelId'] as String?);
  }

  // ---- 对话 ----

  /// 发起一轮对话，产出 ChatEvent 流（token_delta / done / error）。
  ///
  /// [messages] 为完整请求消息序列（含说明书前言），按时间升序；
  /// [attachments] 为本轮展开后的附件上下文块（带 [#note:标题] 引用头）；
  /// [modelConfigId] 为对话绑定的模型配置（desktop 模型 id 或远程端点 id）。
  Stream<ChatEvent> chat({
    required String conversationId,
    required List<ChatMessageModel> messages,
    List<ChatAttachment> attachments = const [],
    String? modelConfigId,
  }) async* {
    _cancelled = false;
    final ai = AiClient.instance;

    // 1. 对话绑定的远程端点优先
    if (modelConfigId != null) {
      for (final e in await ai.getRemoteEndpoints()) {
        if (e.id == modelConfigId) {
          yield* _chatViaRemote(e, messages);
          return;
        }
      }
    }

    // 2. 电脑端在线 → /v1/chat
    if (await ai.isDesktopOnline()) {
      // 远程端点 id 对 desktop 无意义（上面未命中说明不是远程 id，
      // 但保险起见只在命中 desktop 模型语义时透传——未知 id 置空走默认）
      yield* _chatViaDesktop(
        conversationId: conversationId,
        messages: messages,
        attachments: attachments,
        modelConfigId: modelConfigId,
      );
      return;
    }

    // 3. 离线 → 默认远程端点
    final endpoint = await ai.defaultRemoteEndpoint();
    if (endpoint == null) {
      yield const ChatError('LinkModel 不在线且未配置远程 AI 接口（助理 → 模型配置）');
      return;
    }
    yield* _chatViaRemote(endpoint, messages);
  }

  // ---- 电脑端通道：POST /v1/chat，SSE（data: {...}） ----

  Stream<ChatEvent> _chatViaDesktop({
    required String conversationId,
    required List<ChatMessageModel> messages,
    required List<ChatAttachment> attachments,
    String? modelConfigId,
  }) async* {
    final ai = AiClient.instance;
    final baseUrl = await ai.getDesktopBaseUrl();

    http.Request buildRequest(String token) {
      final req = http.Request('POST', Uri.parse('$baseUrl/v1/chat'));
      req.headers['Content-Type'] = 'application/json';
      if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
      req.body = jsonEncode({
        'conversationId': conversationId,
        'messages': [for (final m in messages) m.toJson()],
        if (attachments.isNotEmpty)
          'attachments': [for (final a in attachments) a.toJson()],
        if (modelConfigId != null) 'modelConfigId': modelConfigId,
        'stream': true,
      });
      return req;
    }

    final client = _client;
    _activeClient = client;
    try {
      var streamed = await client
          .send(buildRequest(await ai.getDesktopToken()))
          .timeout(const Duration(seconds: 15));
      if (streamed.statusCode == 401) {
        // 自动配对（沿用 /v1/process 惯例）：401 时调一次 /v1/pair 并重试
        await streamed.stream.bytesToString();
        final (token, _) = await ai.pairDesktop();
        streamed = await client
            .send(buildRequest(token))
            .timeout(const Duration(seconds: 15));
      }
      if (streamed.statusCode != 200) {
        final errBody = await streamed.stream.bytesToString();
        throw AiException('LinkModel 对话失败 HTTP ${streamed.statusCode}：$errBody');
      }
      var sawDone = false;
      await for (final line
          in _lines(streamed.stream).timeout(const Duration(seconds: 240))) {
        // SSE（data: 前缀）与裸 NDJSON 都容忍
        final payload =
            line.startsWith('data:') ? line.substring(5).trim() : line;
        if (payload.isEmpty || payload == '[DONE]') continue;
        ChatEvent ev;
        try {
          ev = ChatEvent.parseLine(payload);
        } catch (_) {
          continue; // 无法识别的行跳过，不中断流
        }
        if (ev is ChatDone) sawDone = true;
        yield ev;
      }
      if (!sawDone && !_cancelled) {
        yield const ChatError('连接中断，未收到完成事件');
      }
    } on AiException catch (e) {
      yield ChatError(e.message);
    } catch (e) {
      if (_activeClient == null || _cancelled) return; // 被 cancelActive 中断
      yield ChatError('无法连接 LinkModel：$e');
    } finally {
      if (_activeClient == client) _activeClient = null;
    }
  }

  // ---- 远程通道：OpenAI 兼容 /chat/completions，SSE 自行解析 ----

  Stream<ChatEvent> _chatViaRemote(
      AiEndpoint endpoint, List<ChatMessageModel> messages) async* {
    final hint = AiClient.endpointConfigHint(endpoint.baseUrl);
    if (hint != null) {
      yield ChatError(hint);
      return;
    }
    final url = AiClient.joinEndpointUrl(endpoint.baseUrl, 'chat/completions');
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
        for (final m in messages)
          // OpenAI 兼容端点支持 system；tool 角色折叠为带前缀的 user 消息
          // （与 desktop buildProviderMessages 的折叠规则一致）
          switch (m.role) {
            ChatRole.tool => {'role': 'user', 'content': '[工具执行结果]\n${m.content}'},
            _ => {'role': m.role, 'content': m.content},
          },
      ],
    });

    final client = _client;
    _activeClient = client;
    try {
      final streamed =
          await client.send(req).timeout(const Duration(seconds: 30));
      if (streamed.statusCode != 200) {
        final errBody = await streamed.stream.bytesToString();
        yield ChatError('远程接口返回 ${streamed.statusCode} @ $url：'
            '${AiClient.describeUpstreamError(errBody)}');
        return;
      }
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
          yield ChatTokenDelta(content);
        }
      }
      yield const ChatDone();
    } catch (e) {
      if (_activeClient == null || _cancelled) return; // 被 cancelActive 中断
      yield ChatError('远程接口调用失败：$e');
    } finally {
      if (_activeClient == client) _activeClient = null;
    }
  }

  /// StreamedResponse 字节流 → utf8 分行（跨 chunk 的行缓存拼接）。
  /// 与 AiClient._lines 同算法（性能修复 O03 的版本）。
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

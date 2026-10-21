import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/ai_client.dart';
import 'package:msgrepo_mobile/services/app_log.dart';
import 'package:msgrepo_mobile/services/secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// O06 回归：HTTP 客户端要**复用**。
///
/// 原实现里 _processViaDesktop / _processBatchViaRemote 每次请求都
/// http.Client() … close()；批量处理 160 条消息就是 160 次 TLS 握手。
/// 现在整个 AiClient 复用一个实例，取消/关闭时才丢弃重建。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int created;
  late List<_FakeHttpClient> fakes;

  /// 装一个可计数的 fake client 工厂。
  void installFake(
      Future<http.StreamedResponse> Function(http.BaseRequest) handler) {
    created = 0;
    fakes = <_FakeHttpClient>[];
    AiClient.clientFactory = () {
      created++;
      final c = _FakeHttpClient(handler);
      fakes.add(c);
      return c;
    };
  }

  setUp(() {
    AiClient.secretStore = InMemorySecretStore();
    SharedPreferences.setMockInitialValues({});
    AiClient.instance.closeClient(); // 清掉上一个用例可能留下的实例
  });

  tearDown(() {
    AiClient.instance.closeClient();
    AiClient.clientFactory = () => http.Client();
  });

  test('连续两次请求只创建 1 个 client（health 探测路径）', () async {
    installFake((req) async => _json(200, '{"ok":true}'));

    expect(await AiClient.instance.isDesktopOnline(force: true), isTrue);
    expect(await AiClient.instance.isDesktopOnline(force: true), isTrue);

    expect(created, 1, reason: '两次探测必须复用同一个 client');
    expect(fakes.single.sendCount, 2, reason: '两次探测都走了同一个实例');
  });

  test('批量处理两次也只创建 1 个 client（chat/completions 路径）', () async {
    await AiClient.instance.upsertEndpoint(const AiEndpoint(
      id: 'e1',
      name: '测试接口',
      baseUrl: 'https://api.test',
      apiKey: 'sk-test',
      model: 'test-model',
    ));
    await AiClient.instance.setDefaultEndpointId('e1');

    var completions = 0;
    installFake((req) async {
      if (req.url.path.endsWith('/v1/health')) {
        return _json(503, '{}'); // 电脑端不在线 → 走远程接口
      }
      if (req.url.path.endsWith('/chat/completions')) {
        completions++;
        final body =
            (jsonDecode((req as http.Request).body) as Map<String, dynamic>);
        final messages = body['messages'] as List;
        final userContent = (messages.last as Map)['content'] as String;
        final ids = <String>[
          for (final match in RegExp(r'm[0-9]+').allMatches(userContent))
            match.group(0)!,
        ];
        final arr = [
          for (final id in ids)
            {
              'messageId': id,
              'priority': 'yellow',
              'reason': '待关注',
              'taskDraft': null,
            }
        ];
        final payload = jsonEncode({
          'choices': [
            {
              'delta': {'content': jsonEncode(arr)}
            }
          ]
        });
        final sse = 'data: $payload\n\ndata: [DONE]\n\n';
        return http.StreamedResponse(Stream.value(utf8.encode(sse)), 200,
            headers: {'content-type': 'text/event-stream'});
      }
      return _json(404, '{}');
    });

    // 先把 health 缓存置为 false，保证走远程路径
    await AiClient.instance.isDesktopOnline(force: true);
    final createdAfterHealth = created;

    final msgs = [_msg('m1'), _msg('m2')];
    final first = await AiClient.instance.process(msgs).toList();
    final second = await AiClient.instance.process(msgs).toList();

    expect(first.whereType<AiMessageResult>(), hasLength(2));
    expect(second.whereType<AiMessageResult>(), hasLength(2));
    expect(completions, 2, reason: '两次 process 各发一次批量请求');
    expect(created, createdAfterHealth,
        reason: '两次批量请求不得各自新建 client（复用 health 建的那个）');
    expect(fakes, hasLength(1));
    expect(fakes.single.sendCount, 3, reason: '1 次 health + 2 次 completions');
  });

  // Q11 护栏（2026-10-21 用户裁决「接受现状」）：共享 client 后 cancelActive 会中断所有在途请求，
  // 当前产品路径串行、不会并发；这里验证「并发计数」与「并发时告警」，将来悄悄加并发能被日志抓到。
  test('并发在途计数正确，cancelActive 时并发会告警', () async {
    await AiClient.instance.upsertEndpoint(const AiEndpoint(
      id: 'e1',
      name: '测试接口',
      baseUrl: 'https://api.test',
      apiKey: 'sk-test',
      model: 'test-model',
    ));
    await AiClient.instance.setDefaultEndpointId('e1');

    final gates = <Completer<void>>[];
    installFake((req) async {
      if (req.url.path.endsWith('/v1/health')) return _json(503, '{}');
      if (req.url.path.endsWith('/chat/completions')) {
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future; // 挂住，制造「两个请求同时在飞」
        return _json(500, '{}');
      }
      return _json(404, '{}');
    });

    // 先把 health 缓存置 false，保证走远程路径
    await AiClient.instance.isDesktopOnline(force: true);
    AppLog.instance.clear();

    final a = AiClient.instance.process([_msg('m1')]).drain<void>();
    final b = AiClient.instance.process([_msg('m2')]).drain<void>();
    // 等到两个远程请求都发出去（各自挂在自己的 gate 上）
    for (var i = 0; i < 50 && gates.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(gates, hasLength(2), reason: '两个 process 应各自发出一个批量请求');
    expect(AiClient.instance.inflightCount, 2, reason: '两个请求同时在飞');

    AiClient.instance.cancelActive();
    expect(
      AppLog.instance.entries.any((e) => e.scope == 'ai.cancel-concurrent'),
      isTrue,
      reason: '并发时取消必须留下告警，便于排查「取消 A 弄死 B」',
    );

    for (final g in gates) {
      if (!g.isCompleted) g.complete();
    }
    await Future.wait([a, b]).catchError((_) => <void>[]);
    expect(AiClient.instance.inflightCount, 0, reason: '请求结束后计数必须归零');
  });
  test('关闭后不复用已关闭实例（重新创建）', () async {
    installFake((req) async => _json(200, '{"ok":true}'));

    await AiClient.instance.isDesktopOnline(force: true);
    expect(created, 1);

    AiClient.instance.closeClient();
    expect(fakes.single.closed, isTrue, reason: 'close() 要真正关掉实例');

    await AiClient.instance.isDesktopOnline(force: true);
    expect(created, 2, reason: '关闭后必须重建，不能复用已关闭的 client');
    expect(fakes.last.closed, isFalse);
  });
}

http.StreamedResponse _json(int code, String body) => http.StreamedResponse(
    Stream.value(utf8.encode(body)), code,
    headers: {'content-type': 'application/json'});

Message _msg(String id) => Message(
      id: id,
      packageName: 'com.tencent.mm',
      appName: '微信',
      title: '明天下午三点开会',
      body: '记得带电脑',
      postedAt: DateTime(2026, 10, 21, 9).millisecondsSinceEpoch,
      captureType: 'notification',
      contentHash: 'hash-$id',
      createdAt: DateTime(2026, 10, 21, 9).millisecondsSinceEpoch,
    );

class _FakeHttpClient extends http.BaseClient {
  _FakeHttpClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest) _handler;
  int sendCount = 0;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sendCount++;
    return _handler(request);
  }

  @override
  void close() {
    closed = true;
  }
}

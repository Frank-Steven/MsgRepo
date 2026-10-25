import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/ai_client.dart';
import 'package:msgrepo_mobile/services/ai_processing.dart';
import 'package:msgrepo_mobile/services/undo_service.dart';

/// A02（用户 2026-10-20 确认语义）：「不采用 / 驳回」= 丢弃选中的 AI 结果、
/// 消息退回未处理，**不落库、不建任务、不改 priority/status**。
///
/// 与 confirm 的关键区别在有无写库副作用，所以这里重点断言：
/// - outcome 从会话移除、返回丢弃条数；
/// - message 对象原封不动（status/priority 不变）；
/// - 不产生撤销项（confirm 一定会 UndoService.register，没注册就说明没走写库路径）；
/// - 只作用于「待确认结果」，失败/未完成条目不会被当成结果丢掉；
/// - 会话收尾按 closePanel 规则。
Message _msg({
  String id = 'm1',
  String status = MessageStatus.pending,
  String priority = MessagePriority.none,
}) =>
    Message(
      id: id,
      packageName: 'com.test',
      title: '标题$id',
      body: '正文$id',
      postedAt: 1700000000000,
      captureType: 'notification',
      contentHash: 'h-$id',
      status: status,
      priority: priority,
      createdAt: 1700000000000,
    );

/// 假处理流：逐条给 green 结果（走的是服务层真实泵循环）。
Stream<AiEvent> okProcessor(List<Message> msgs) async* {
  for (final m in msgs) {
    yield AiMessageResult(AiProcessResult(
        messageId: m.id, priority: MessagePriority.green, reason: 'ok'));
  }
  yield AiAllDone(msgs.length, 0);
}

/// 假处理流：逐条给错误（无 AI 结果，不属于「待确认」）。
Stream<AiEvent> failProcessor(List<Message> msgs) async* {
  for (final m in msgs) {
    yield AiMessageError(m.id, '模拟失败');
  }
  yield AiAllDone(0, msgs.length);
}

void main() {
  final svc = AiProcessingService.instance;

  setUp(() {
    svc.reset();
    UndoService.instance.clear();
  });
  tearDown(() async {
    await svc.idle;
    svc.reset();
    svc.processor = AiClient.instance.process;
    UndoService.instance.clear();
  });

  /// 入队并等到结果落定，返回会话里当前 outcomes 的快照。
  Future<List<AiOutcome>> settle(List<String> ids) async {
    svc.processor = okProcessor;
    svc.enqueue([for (final id in ids) _msg(id: id)]);
    await svc.idle;
    return svc.session!.outcomes.toList();
  }

  group('A02 discard：不采用选中的 AI 结果', () {
    test('只移除选中的待确认结果，返回丢弃条数，未选中的保留', () async {
      final all = await settle(['a', 'b', 'c']);
      expect(svc.pendingConfirmCount, 3);

      final dropped = svc.discard([all[0], all[2]]);

      expect(dropped, 2);
      expect(svc.session, isNotNull);
      expect(svc.session!.outcomes.map((o) => o.message.id), ['b']);
      expect(svc.pendingConfirmCount, 1);
      expect(svc.session!.outcomeOf('a'), isNull);
      expect(svc.session!.outcomeOf('c'), isNull);
    });

    test('不写库 / 不建任务 / 不产生撤销项：消息仍是未处理且状态字段不变', () async {
      final all = await settle(['a', 'b']);
      final m = all.first.message;
      expect(m.status, MessageStatus.pending);
      expect(m.priority, MessagePriority.none);

      final dropped = svc.discard(all);

      expect(dropped, 2);
      // 消息对象原封不动（confirm 会改这两项并写库）
      expect(m.status, MessageStatus.pending);
      expect(m.priority, MessagePriority.none);
      // confirm 的写库路径一定会 register 撤销项；没注册 ⇒ 没走 confirm
      expect(UndoService.instance.latest, isNull);
      expect(svc.pendingConfirmCount, 0);
      // 全部丢弃 + 队列空 ⇒ 会话按 closePanel 规则清空
      expect(svc.session, isNull);
    });

    test('失败条目不是「待确认结果」，丢弃时返回 0 且条目保留', () async {
      svc.processor = failProcessor;
      svc.enqueue([_msg(id: 'f')]);
      await svc.idle;

      final failed = svc.session!.outcomes.single;
      expect(failed.result, isNull);
      expect(failed.error, isNotNull);

      expect(svc.discard([failed]), 0);
      expect(svc.session!.outcomes.single, same(failed));
      expect(svc.session!.failCount, 1);
    });

    test('混合会话：只丢有结果的条目（失败条目随会话收尾一并清空）', () async {
      svc.processor = (msgs) async* {
        yield AiMessageResult(AiProcessResult(
            messageId: msgs[0].id, priority: MessagePriority.green, reason: 'ok'));
        yield AiMessageError(msgs[1].id, 'boom');
        yield const AiAllDone(1, 1);
      };
      svc.enqueue([_msg(id: 'ok'), _msg(id: 'bad')]);
      await svc.idle;
      expect(svc.pendingConfirmCount, 1);
      expect(svc.session!.failCount, 1);

      final dropped = svc.discard(svc.session!.outcomes.toList());

      // 只有 1 条是「待确认结果」；失败条目不算丢弃条数
      expect(dropped, 1);
      // 队列空 + 无待确认结果 ⇒ 会话清空（与 closePanel 一致，失败残留随之收尾）
      expect(svc.session, isNull);
    });

    test('空列表 / 会话不存在时返回 0，不报错', () async {
      expect(svc.discard(const <AiOutcome>[]), 0);
      expect(svc.session, isNull);

      final all = await settle(['a']);
      expect(svc.discard(const <AiOutcome>[]), 0);
      expect(svc.session!.outcomes.single, same(all.single));
    });

    test('丢弃的那条同时释放流式原文，未丢弃的仍保留', () async {
      svc.processor = (msgs) async* {
        for (final m in msgs) {
          yield AiTokenDelta(m.id, '一段很长的流式原文');
        }
        for (final m in msgs) {
          yield AiMessageResult(AiProcessResult(
              messageId: m.id, priority: MessagePriority.green, reason: ''));
        }
        yield AiAllDone(msgs.length, 0);
      };
      svc.enqueue([_msg(id: 'a'), _msg(id: 'b')]);
      await svc.idle;
      expect(svc.session!.rawById.containsKey('a'), isTrue);
      expect(svc.session!.rawById.containsKey('b'), isTrue);

      final all = svc.session!.outcomes.toList();
      expect(svc.discard([all[0]]), 1); // 只丢 a，会话保留（b 仍待确认）

      expect(svc.session, isNotNull);
      expect(svc.session!.rawById.containsKey('a'), isFalse);
      expect(svc.session!.rawById.containsKey('b'), isTrue);
    });
  });
}

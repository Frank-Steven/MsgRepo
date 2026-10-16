import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/ai_client.dart';
import 'package:msgrepo_mobile/services/ai_processing.dart';

Message _msg({
  String id = 'm1',
  String status = MessageStatus.pending,
  String? contentHash,
}) =>
    Message(
      id: id,
      packageName: 'com.test',
      title: '标题$id',
      body: '正文$id',
      postedAt: 1700000000000,
      captureType: 'notification',
      contentHash: contentHash ?? 'h-$id',
      status: status,
      createdAt: 1700000000000,
    );

/// 假处理流：逐条立即给 green 结果。
Stream<AiEvent> okProcessor(List<Message> msgs) async* {
  for (final m in msgs) {
    yield AiMessageResult(
        AiProcessResult(messageId: m.id, priority: 'green', reason: 'ok'));
  }
  yield AiAllDone(msgs.length, 0);
}

/// 假处理流：逐条立即给错误。
Stream<AiEvent> failProcessor(List<Message> msgs) async* {
  for (final m in msgs) {
    yield AiMessageError(m.id, '模拟失败');
  }
  yield AiAllDone(0, msgs.length);
}

void main() {
  final svc = AiProcessingService.instance;

  setUp(() => svc.reset());
  tearDown(() async {
    await svc.idle;
    svc.reset();
    svc.processor = AiClient.instance.process;
  });

  group('filterProcessable 发起前统一过滤（v2.6.2）', () {
    test('processed 消息默认排除，显式重新处理才放行', () {
      final msgs = [
        _msg(id: 'a'),
        _msg(id: 'b', status: MessageStatus.processed),
      ];
      final (toProcess, skipped) = filterProcessable(msgs,
          reprocess: false, processingIds: const {}, processedHashes: const {});
      expect(toProcess.map((m) => m.id), ['a']);
      expect(skipped, {'processed': 1});

      final (toProcess2, skipped2) = filterProcessable(msgs,
          reprocess: true, processingIds: const {}, processedHashes: const {});
      expect(toProcess2.map((m) => m.id), ['a', 'b']);
      expect(skipped2, isEmpty);
    });

    test('正在处理中的消息排除（即使显式重新处理）', () {
      final msgs = [_msg(id: 'a'), _msg(id: 'b')];
      final (toProcess, skipped) = filterProcessable(msgs,
          reprocess: true,
          processingIds: const {'b'},
          processedHashes: const {});
      expect(toProcess.map((m) => m.id), ['a']);
      expect(skipped, {'processing': 1});
    });

    test('pending 且同内容已有 processed 记录的重复消息排除', () {
      final msgs = [
        _msg(id: 'a', contentHash: 'dup'),
        _msg(id: 'b', contentHash: 'unique'),
        // processed 消息不受哈希去重影响（由 processed 规则管）
        _msg(id: 'c', status: MessageStatus.processed, contentHash: 'dup'),
      ];
      final (toProcess, skipped) = filterProcessable(msgs,
          reprocess: true,
          processingIds: const {},
          processedHashes: const {'dup'});
      expect(toProcess.map((m) => m.id), ['b', 'c']);
      expect(skipped, {'duplicate': 1});
    });

    test('跳过原因计数并存且顺序保留', () {
      final msgs = [
        _msg(id: 'p1', status: MessageStatus.processed),
        _msg(id: 'ok1'),
        _msg(id: 'doing'),
        _msg(id: 'ok2'),
        _msg(id: 'dup', contentHash: 'seen'),
      ];
      final (toProcess, skipped) = filterProcessable(msgs,
          reprocess: false,
          processingIds: const {'doing'},
          processedHashes: const {'seen'});
      expect(toProcess.map((m) => m.id), ['ok1', 'ok2']);
      expect(skipped, {'processed': 1, 'processing': 1, 'duplicate': 1});
    });
  });

  group('连续排队模型（v2.6.4）', () {
    test('追加去重：队列/处理中/待确认结果中的 id 跳过', () async {
      svc.processor = okProcessor;
      final (added1, _) = svc.enqueue([_msg(id: 'a'), _msg(id: 'b')]);
      expect(added1, 2);
      await svc.idle; // a、b 跑完，结果待确认（仍在会话中）

      final (added2, skipped2) =
          svc.enqueue([_msg(id: 'b'), _msg(id: 'c')]);
      expect(added2, 1);
      expect(skipped2, 1); // b 有待确认结果，去重跳过
      await svc.idle;
      expect(svc.session!.outcomes.map((o) => o.message.id),
          ['a', 'b', 'c']);
    });

    test('结果跨批累积，待确认计数随追加增长', () async {
      svc.processor = okProcessor;
      svc.enqueue([_msg(id: 'a')]);
      await svc.idle;
      expect(svc.pendingConfirmCount, 1);

      svc.enqueue([_msg(id: 'b'), _msg(id: 'c')]);
      await svc.idle;
      expect(svc.pendingConfirmCount, 3); // 累积，不需要先确认
      expect(svc.session!.settledCount, 3);
      expect(svc.session!.enqueuedCount, 3);
    });

    test('组批按队列当前快照：12 条一次入队分 10+2 两批', () async {
      final sizes = <int>[];
      svc.processor = (msgs) {
        sizes.add(msgs.length);
        return okProcessor(msgs);
      };
      svc.enqueue([for (var i = 0; i < 12; i++) _msg(id: 'm$i')]);
      await svc.idle;
      expect(sizes, [10, 2]);
      expect(svc.pendingConfirmCount, 12);
    });

    test('顺序消费：上一批未跑完时追加的消息不提前开批', () async {
      final gate = Completer<void>();
      final batches = <List<String>>[];
      svc.processor = (msgs) {
        batches.add([for (final m in msgs) m.id]);
        return Stream.fromFuture(gate.future).asyncExpand(
            (_) => Stream.fromIterable([
                  for (final m in msgs)
                    AiMessageResult(AiProcessResult(
                        messageId: m.id, priority: 'green', reason: '')),
                  AiAllDone(msgs.length, 0),
                ]));
      };
      svc.enqueue([_msg(id: 'a')]);
      svc.enqueue([_msg(id: 'b')]); // 追加时第一批正在跑
      expect(batches, [
        ['a']
      ]); // 并发约束：同一时刻只有一个模型请求
      expect(svc.running, isTrue);
      gate.complete();
      await svc.idle;
      expect(batches, [
        ['a'],
        ['b']
      ]);
      expect(svc.running, isFalse);
    });

    test('出错条目允许重试：旧 error 条目替换为新排队条目', () async {
      svc.processor = failProcessor;
      svc.enqueue([_msg(id: 'a')]);
      await svc.idle;
      expect(svc.session!.outcomeOf('a')!.error, isNotNull);

      svc.processor = okProcessor;
      final (added, skipped) = svc.enqueue([_msg(id: 'a')]);
      expect(added, 1);
      expect(skipped, 0);
      await svc.idle;
      final a = svc.session!.outcomeOf('a')!;
      expect(a.error, isNull);
      expect(a.result, isNotNull);
      // 列表里只有一条 a（替换而非追加）
      expect(
          svc.session!.outcomes.where((o) => o.message.id == 'a').length, 1);
    });

    test('会话清空条件：失败残留不自动清空；无待确认时 closePanel 清空；'
        '有待确认时 closePanel 保留', () async {
      // 失败残留：队列排空后会话保留（等用户查看/重试）
      svc.processor = failProcessor;
      svc.enqueue([_msg(id: 'a')]);
      await svc.idle;
      expect(svc.session, isNotNull);
      expect(svc.session!.failCount, 1);
      expect(svc.running, isFalse);

      // 无待确认结果：面板关闭清空会话
      svc.closePanel();
      expect(svc.session, isNull);

      // 有待确认结果：面板关闭保留会话
      svc.processor = okProcessor;
      svc.enqueue([_msg(id: 'b')]);
      await svc.idle;
      expect(svc.pendingConfirmCount, 1);
      svc.closePanel();
      expect(svc.session, isNotNull);
    });

    test('排队/处理中 id 集驱动处理中标记与发起前去重', () async {
      final gate = Completer<void>();
      svc.processor = (msgs) => Stream.fromFuture(gate.future)
          .asyncExpand((_) => const Stream<AiEvent>.empty());
      svc.enqueue([_msg(id: 'a'), _msg(id: 'b')]);
      expect(svc.processingIds, {'a', 'b'}); // a 在飞、b 排队都算处理中
      expect(svc.isProcessing('b'), isTrue);
      gate.complete();
      await svc.idle;
      // 空流（未返回任何结果）：条目被防御性标记为失败，泵不会死循环
      expect(svc.processingIds, isEmpty);
      expect(svc.session!.failCount, 2);
    });
  });

  group('AiProcessingSession 计数', () {
    test('done/remaining/fail/pendingConfirm 随结果推进', () {
      final session = AiProcessingSession();
      session.outcomes.addAll(
          [AiOutcome(_msg(id: 'a')), AiOutcome(_msg(id: 'b')), AiOutcome(_msg(id: 'c'))]);
      expect(session.doneCount, 0);
      expect(session.remainingCount, 3);
      expect(session.pendingConfirmCount, 0);

      session.outcomeOf('a')!.result = const AiProcessResult(
          messageId: 'a', priority: 'green', reason: '一般');
      expect(session.doneCount, 1);
      expect(session.remainingCount, 2);
      expect(session.pendingConfirmCount, 1);

      session.outcomeOf('b')!.error = '网络失败';
      expect(session.doneCount, 2);
      expect(session.failCount, 1);
      expect(session.pendingConfirmCount, 1); // 失败不计待确认
    });
  });
}

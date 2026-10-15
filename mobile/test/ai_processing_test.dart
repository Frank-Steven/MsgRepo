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

void main() {
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

  group('AiProcessingSession 计数', () {
    test('done/fail/pendingConfirm 随结果推进', () {
      final session =
          AiProcessingSession([_msg(id: 'a'), _msg(id: 'b'), _msg(id: 'c')]);
      expect(session.total, 3);
      expect(session.doneCount, 0);
      expect(session.pendingConfirmCount, 0);
      expect(session.running, isTrue);

      session.outcomeOf('a')!.result = const AiProcessResult(
          messageId: 'a', priority: 'green', reason: '一般');
      expect(session.doneCount, 1);
      expect(session.pendingConfirmCount, 1);

      session.outcomeOf('b')!.error = '网络失败';
      expect(session.doneCount, 2);
      expect(session.failCount, 1);
      expect(session.pendingConfirmCount, 1); // 失败不计待确认

      session.outcomeOf('a')!.confirmed = true;
      expect(session.pendingConfirmCount, 0);
    });

    test('rawById 按消息累积流式原文', () {
      final session = AiProcessingSession([_msg(id: 'a')]);
      session.rawById.putIfAbsent('a', StringBuffer.new).write('{"pri');
      session.rawById.putIfAbsent('a', StringBuffer.new).write('ority":');
      expect(session.rawById['a'].toString(), '{"priority":');
    });
  });
}

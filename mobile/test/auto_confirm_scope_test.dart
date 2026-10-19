import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/ai_client.dart';
import 'package:msgrepo_mobile/services/ai_processing.dart';

/// U19 回归：自动确认只能作用于「本次自动提交」的消息，且取消后必须失效。
void main() {
  Message msg(String id) => Message(
        id: id,
        packageName: 'com.tencent.mm',
        title: 't',
        body: 'b',
        postedAt: 1,
        captureType: 'notification',
        contentHash: 'h$id',
        createdAt: 1,
      );

  AiOutcome ok(String id) => AiOutcome(msg(id))
    ..result = AiProcessResult(
      messageId: id,
      priority: MessagePriority.green,
      reason: 'ok',
    );

  AiOutcome failed(String id) => AiOutcome(msg(id))..error = 'boom';

  group('selectAutoConfirmTargets', () {
    test('只确认本次自动提交的那批', () {
      final outcomes = [ok('a'), ok('b'), ok('c')];
      final picked = selectAutoConfirmTargets(
          outcomes: outcomes, messageIds: {'a', 'b'});
      expect(picked.map((o) => o.message.id), ['a', 'b']);
    });

    test('用户手动追加的处理不会被顺带确认', () {
      // a 是自动批次的，manual 是用户自己点处理追加的
      final outcomes = [ok('a'), ok('manual')];
      final picked =
          selectAutoConfirmTargets(outcomes: outcomes, messageIds: {'a'});
      expect(picked.map((o) => o.message.id), ['a']);
    });

    test('失败条目跳过（留给人工看）', () {
      final outcomes = [ok('a'), failed('b')];
      final picked = selectAutoConfirmTargets(
          outcomes: outcomes, messageIds: {'a', 'b'});
      expect(picked.map((o) => o.message.id), ['a']);
    });

    test('未完成（还在处理）的条目跳过', () {
      final pending = AiOutcome(msg('c'));
      final outcomes = [ok('a'), pending];
      final picked = selectAutoConfirmTargets(
          outcomes: outcomes, messageIds: {'a', 'c'});
      expect(picked.map((o) => o.message.id), ['a']);
    });

    test('空 id 集合 → 什么都不确认', () {
      expect(
          selectAutoConfirmTargets(
              outcomes: [ok('a')], messageIds: const <String>{}),
          isEmpty);
    });

    test('ids 里有但会话里没有 → 忽略，不抛错', () {
      final picked = selectAutoConfirmTargets(
          outcomes: [ok('a')], messageIds: {'a', 'ghost'});
      expect(picked.length, 1);
    });
  });

  group('取消即解除自动确认（真机踩过的坑）', () {
    test('arm 后 armed=true，cancel 后 armed=false', () async {
      final svc = AiProcessingService.instance;
      svc.armAutoConfirm(['a', 'b']);
      expect(svc.autoConfirmArmed, isTrue);
      await svc.cancel();
      expect(svc.autoConfirmArmed, isFalse,
          reason: '取消后不能再把已出结果的部分自动确认掉');
    });

    test('disarm 也可直接关闭', () {
      final svc = AiProcessingService.instance;
      svc.armAutoConfirm(['x']);
      svc.disarmAutoConfirm();
      expect(svc.autoConfirmArmed, isFalse);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/ai_client.dart';
import 'package:msgrepo_mobile/services/junk_rules.dart';

Message _msg({
  String id = 'm1',
  String title = '',
  String body = '',
  String? sender,
}) =>
    Message(
      id: id,
      packageName: 'com.test',
      sender: sender,
      title: title,
      body: body,
      postedAt: 1700000000000,
      captureType: 'notification',
      contentHash: 'h-$id',
      createdAt: 1700000000000,
    );

void main() {
  group('junkRuleHit 本地垃圾规则', () {
    test('营销关键词命中标题', () {
      expect(junkRuleHit(_msg(title: '限时秒杀，全场五折')), isNotNull);
    });

    test('营销关键词命中正文', () {
      expect(junkRuleHit(_msg(body: '点击领取优惠券，先到先得')), isNotNull);
    });

    test('退订字样命中', () {
      expect(junkRuleHit(_msg(body: '回复TD退订')), isNotNull);
    });

    test('106 服务号含退订字样命中', () {
      expect(
          junkRuleHit(_msg(sender: '10690000123', body: '您的账单已出，回T退订')),
          isNotNull);
    });

    test('普通聊天不误伤', () {
      expect(junkRuleHit(_msg(title: '张三', body: '明天下午开会别忘了')), isNull);
    });

    test('106 服务号规则与普通关键词命中理由可区分', () {
      // 长服务号优先走服务号规则理由
      expect(
          junkRuleHit(_msg(sender: '10690000123', body: '您的账单已出，回T退订')),
          contains('运营服务号'));
      // 普通号码不适用服务号规则，但「退订」关键词仍命中（宁漏勿错）
      expect(junkRuleHit(_msg(sender: '张三', body: '回T退订')), contains('关键词'));
    });

    test('命中理由标注规则判定', () {
      final hit = junkRuleHit(_msg(body: '0元购火爆进行中'));
      expect(hit, startsWith('规则判定'));
    });
  });

  group('parseBatchEvalOutput 批量结果解析', () {
    final batch = [_msg(id: 'a'), _msg(id: 'b')];

    test('数组按 messageId 建 map', () {
      final out = AiClient.parseBatchEvalOutput(batch, '''
[
  {"messageId":"a","priority":"red","reason":"重要账单",
   "taskDraft":{"title":"还信用卡","kind":"point","startAt":"2026-10-20T10:00","priority":"important"}},
  {"messageId":"b","priority":"junk","reason":"广告","taskDraft":null}
]''');
      expect(out.length, 2);
      expect(out['a']!.priority, 'red');
      expect(out['a']!.taskDraft!.title, '还信用卡');
      expect(out['a']!.taskDraft!.kind, 'point');
      expect(out['a']!.taskDraft!.startAt, DateTime(2026, 10, 20, 10, 0));
      expect(out['b']!.priority, 'junk');
      expect(out['b']!.taskDraft, isNull);
    });

    test('容忍 markdown 围栏与前后缀文字', () {
      final out = AiClient.parseBatchEvalOutput(batch,
          '好的，结果如下：\n```json\n[{"messageId":"a","priority":"green","reason":"一般","taskDraft":null}]\n```\n以上。');
      expect(out['a']!.priority, 'green');
      expect(out.containsKey('b'), isFalse);
    });

    test('未知 messageId 与缺 id 元素忽略', () {
      final out = AiClient.parseBatchEvalOutput(batch, '''
[
  {"messageId":"zzz","priority":"red","reason":"?","taskDraft":null},
  {"priority":"yellow","reason":"无 id","taskDraft":null},
  {"messageId":"b","priority":"yellow","reason":"值得关注","taskDraft":null}
]''');
      expect(out.length, 1);
      expect(out['b']!.priority, 'yellow');
    });

    test('非法 priority 归一为 green', () {
      final out = AiClient.parseBatchEvalOutput(batch,
          '[{"messageId":"a","priority":"urgent","reason":"x","taskDraft":null}]');
      expect(out['a']!.priority, 'green');
    });

    test('无数组抛 AiException', () {
      expect(() => AiClient.parseBatchEvalOutput(batch, '模型瞎说一通'),
          throwsA(isA<AiException>()));
    });

    test('坏 JSON 抛 AiException', () {
      expect(() => AiClient.parseBatchEvalOutput(batch, '[{"messageId":"a",]'),
          throwsA(isA<AiException>()));
    });
  });

  group('上下文裁剪参数', () {
    test('标题/正文截断上限常量', () {
      expect(AiClient.titleMaxChars, 100);
      expect(AiClient.bodyMaxChars, 500);
      expect(AiClient.batchSize, 10);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/ai_client.dart';

/// N1 回归：任务草稿解析要支持「一条消息 → 多个任务」，并兼容旧的单个 taskDraft。
void main() {
  test('taskDrafts 数组 → 多个草稿', () {
    final drafts = AiClient.parseTaskDrafts(null, [
      {'title': '交周报', 'kind': 'point', 'priority': 'important'},
      {'title': '预约体检', 'kind': 'point', 'priority': 'normal'},
    ]);
    expect(drafts.length, 2);
    expect(drafts[0].title, '交周报');
    expect(drafts[1].title, '预约体检');
  });

  test('只有旧字段 taskDraft 时仍能解析（向后兼容）', () {
    final drafts = AiClient.parseTaskDrafts(
      {'title': '单条任务', 'kind': 'range', 'priority': 'minor'},
      null,
    );
    expect(drafts.length, 1);
    expect(drafts.single.kind, 'range');
  });

  test('数组与单个同时存在时以数组为准', () {
    final drafts = AiClient.parseTaskDrafts(
      {'title': '旧字段' },
      [
        {'title': '新一'},
        {'title': '新二'},
      ],
    );
    expect(drafts.map((d) => d.title).toList(), ['新一', '新二']);
  });

  test('空标题的草稿被丢弃', () {
    final drafts = AiClient.parseTaskDrafts(null, [
      {'title': '   '},
      {'title': '有效任务'},
    ]);
    expect(drafts.length, 1);
    expect(drafts.single.title, '有效任务');
  });

  test('两者都为空 → 空列表', () {
    expect(AiClient.parseTaskDrafts(null, null), isEmpty);
  });
}

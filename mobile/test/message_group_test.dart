import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/ui/messages/message_widgets.dart';

/// v2.6 回归：消息去颜色化——红/黄/绿分组下线，AI 评估的 priority 仍落库，
/// 但不再决定分组。v2.6.3：新增「已处理」分组（status=processed 且非垃圾），
/// 与「已完成」筛选键（关联任务 done，叠加维度）区分。
void main() {
  Message msg(String priority,
          {String status = MessageStatus.pending}) =>
      Message(
        id: 'm-$priority-$status',
        packageName: 'pkg',
        title: 't',
        body: 'b',
        postedAt: 0,
        captureType: 'notification',
        contentHash: 'h-$priority-$status',
        priority: priority,
        status: status,
        createdAt: 0,
      );

  test('分组键：pending 的红/黄/绿/未评估全部归未处理', () {
    expect(messageGroupKey(msg(MessagePriority.red)), kGroupPending);
    expect(messageGroupKey(msg(MessagePriority.yellow)), kGroupPending);
    expect(messageGroupKey(msg(MessagePriority.green)), kGroupPending);
    expect(messageGroupKey(msg(MessagePriority.none)), kGroupPending);
  });

  test('分组键：status=processed 且非垃圾归已处理（v2.6.3）', () {
    expect(
        messageGroupKey(msg(MessagePriority.none,
            status: MessageStatus.processed)),
        kGroupProcessed);
    expect(
        messageGroupKey(msg(MessagePriority.green,
            status: MessageStatus.processed)),
        kGroupProcessed);
  });

  test('分组键：垃圾优先于已处理（processed 的垃圾仍归垃圾组）', () {
    expect(messageGroupKey(msg(MessagePriority.junk)), MessagePriority.junk);
    expect(
        messageGroupKey(msg(MessagePriority.junk,
            status: MessageStatus.processed)),
        MessagePriority.junk);
  });

  test('分组顺序与筛选 chips：未处理/已处理/垃圾（+独立「已完成」键）', () {
    expect(kGroupOrder,
        [kGroupPending, kGroupProcessed, MessagePriority.junk]);
    expect(messageGroupLabel(kGroupPending), '未处理');
    expect(messageGroupLabel(kGroupProcessed), '已处理');
    expect(messageGroupLabel(MessagePriority.junk), '垃圾');
    expect(messageGroupLabel(kFilterDone), '已完成');
  });
}

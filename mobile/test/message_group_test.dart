import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/ui/messages/message_widgets.dart';

/// v2.6 回归：消息去颜色化——红/黄/绿分组下线，列表只剩 未处理/垃圾 两组；
/// AI 评估的 priority 仍落库，但不再决定分组。
void main() {
  Message msg(String priority) => Message(
        id: 'm-$priority',
        packageName: 'pkg',
        title: 't',
        body: 'b',
        postedAt: 0,
        captureType: 'notification',
        contentHash: 'h-$priority',
        priority: priority,
        createdAt: 0,
      );

  test('分组键：垃圾单独一组，红/黄/绿/未评估全部归未处理', () {
    expect(messageGroupKey(msg(MessagePriority.junk)), MessagePriority.junk);
    expect(messageGroupKey(msg(MessagePriority.red)), kGroupPending);
    expect(messageGroupKey(msg(MessagePriority.yellow)), kGroupPending);
    expect(messageGroupKey(msg(MessagePriority.green)), kGroupPending);
    expect(messageGroupKey(msg(MessagePriority.none)), kGroupPending);
  });

  test('分组顺序与筛选 chips：只剩 未处理/垃圾（+独立「已完成」键）', () {
    expect(kGroupOrder, [kGroupPending, MessagePriority.junk]);
    expect(messageGroupLabel(kGroupPending), '未处理');
    expect(messageGroupLabel(MessagePriority.junk), '垃圾');
    expect(messageGroupLabel(kFilterDone), '已完成');
  });
}

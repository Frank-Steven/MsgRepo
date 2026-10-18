import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/ui/messages/message_widgets.dart';

/// N1 UI 回归：一条消息关联多个任务时，标记处显示数量角标（而不是单个完成勾）。
void main() {
  Message msg() => const Message(
        id: 'm1',
        packageName: 'pkg',
        title: '课代表通知',
        body: '交作业，另外记得预约体检',
        postedAt: 0,
        captureType: 'notification',
        contentHash: 'h1',
        createdAt: 0,
      );

  Widget host(MessageTile tile) =>
      MaterialApp(home: Scaffold(body: tile));

  testWidgets('关联 2 个任务 → 显示数字角标 2', (tester) async {
    await tester.pumpWidget(host(MessageTile(
      message: msg(),
      linkedTaskCount: 2,
      linkedTaskPriority: 'normal',
      actions: const [],
    )));
    expect(find.text('2'), findsOneWidget, reason: '多关联要有数量角标');
    expect(find.byIcon(Icons.task_alt), findsNothing,
        reason: '多关联时不显示单个完成勾');
  });

  testWidgets('关联 1 个任务 → 显示完成勾，不显示数字', (tester) async {
    await tester.pumpWidget(host(MessageTile(
      message: msg(),
      linkedTaskCount: 1,
      linkedTaskPriority: 'important',
      actions: const [],
    )));
    expect(find.byIcon(Icons.task_alt), findsOneWidget);
    expect(find.text('1'), findsNothing);
  });

  testWidgets('未关联任务 → 空心圆点，无角标无勾', (tester) async {
    await tester.pumpWidget(host(MessageTile(
      message: msg(),
      actions: const [],
    )));
    expect(find.byIcon(Icons.task_alt), findsNothing);
  });
}

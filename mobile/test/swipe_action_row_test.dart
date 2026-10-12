import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:msgrepo_mobile/ui/messages/message_widgets.dart';

void main() {
  testWidgets('左滑露出动作块后，点击动作块触发回调而不是被内容吞掉', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SwipeActionRow(
              actions: [
                SwipeAction(
                  icon: Icons.auto_awesome,
                  label: '自动处理',
                  color: Colors.pink,
                  onTap: () => tapped++,
                ),
              ],
              child: Container(
                height: 80,
                color: Colors.blue,
                child: const Text('content'),
              ),
            ),
          ),
        ),
      ),
    );

    // 左滑超过阈值，松手吸住
    await tester.drag(find.text('content'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(find.text('自动处理'), findsOneWidget);

    // 点击露出的动作块（回归：内容 Transform 的命中区域曾盖住动作条）
    await tester.tap(find.text('自动处理'));
    await tester.pumpAndSettle();
    expect(tapped, 1);

    // 动作触发后菜单应收起
    expect(find.text('自动处理'), findsNothing);
  });

  testWidgets('菜单展开时点击内容区域收起菜单', (tester) async {
    var contentTapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SwipeActionRow(
              actions: [
                SwipeAction(
                  icon: Icons.archive,
                  label: '归档',
                  color: Colors.green,
                  onTap: () {},
                ),
              ],
              onTap: () => contentTapped++,
              child: Container(
                width: 300,
                height: 80,
                color: Colors.blue,
                child: const Text('content'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.text('content'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(find.text('归档'), findsOneWidget);

    await tester.tapAt(tester.getCenter(find.text('content')));
    await tester.pumpAndSettle();
    expect(find.text('归档'), findsNothing);
    expect(contentTapped, 0);
  });
}

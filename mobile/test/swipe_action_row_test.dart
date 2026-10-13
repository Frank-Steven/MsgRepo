import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:msgrepo_mobile/ui/messages/message_widgets.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

SwipeActionRow _row({
  required List<SwipeAction> actions,
  VoidCallback? onTap,
  String text = 'content',
}) =>
    SwipeActionRow(
      actions: actions,
      onTap: onTap,
      child: Container(
        height: 80,
        color: Colors.blue,
        alignment: Alignment.center,
        child: Text(text),
      ),
    );

void main() {
  testWidgets('轻扫 ≥40dp 即展开，松手吸附到全展（设计 §5.1 验收 1）', (tester) async {
    await tester.pumpWidget(_wrap(_row(actions: [
      SwipeAction(
        icon: Icons.auto_awesome,
        label: '自动处理',
        color: Colors.pink,
        onTap: () {},
      ),
    ])));

    await tester.drag(find.text('content'), const Offset(-50, 0));
    await tester.pumpAndSettle();
    expect(find.text('自动处理'), findsOneWidget);
  });

  testWidgets('快速甩动即展开（设计 §5.1 验收 1）', (tester) async {
    await tester.pumpWidget(_wrap(_row(actions: [
      SwipeAction(
        icon: Icons.archive,
        label: '归档',
        color: Colors.green,
        onTap: () {},
      ),
    ])));

    await tester.fling(find.text('content'), const Offset(-200, 0), 1200);
    await tester.pumpAndSettle();
    expect(find.text('归档'), findsOneWidget);
  });

  testWidgets('展开后点击动作块必触发回调，且菜单收起（验收 2）', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(_wrap(_row(actions: [
      SwipeAction(
        icon: Icons.auto_awesome,
        label: '自动处理',
        color: Colors.pink,
        onTap: () => tapped++,
      ),
    ])));

    await tester.drag(find.text('content'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(find.text('自动处理'), findsOneWidget);

    await tester.tap(find.text('自动处理'));
    await tester.pumpAndSettle();
    expect(tapped, 1);
    // 动作触发后菜单收起（动作块随 actionPane 卸载）
    expect(find.text('自动处理'), findsNothing);
  });

  testWidgets('展开后点击行内容收起，不触发行点击；反扫也收起（验收 3）',
      (tester) async {
    var contentTapped = 0;
    await tester.pumpWidget(_wrap(_row(
      actions: [
        SwipeAction(
          icon: Icons.archive,
          label: '归档',
          color: Colors.green,
          onTap: () {},
        ),
      ],
      onTap: () => contentTapped++,
    )));

    await tester.drag(find.text('content'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(find.text('归档'), findsOneWidget);

    await tester.tapAt(tester.getCenter(find.text('content')));
    await tester.pumpAndSettle();
    expect(find.text('归档'), findsNothing);
    expect(contentTapped, 0);

    // 再次展开后反向扫动收起（用 fling：单次大跳变的反向 drag 会被库的
    // StillGesture 判定回弹，真机连续小步拖动无此问题）
    await tester.drag(find.text('content'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(find.text('归档'), findsOneWidget);
    await tester.fling(find.text('content'), const Offset(100, 0), 800);
    await tester.pumpAndSettle();
    expect(find.text('归档'), findsNothing);
  });

  testWidgets('多行各自独立展开/收起，互不干扰（验收 4）', (tester) async {
    await tester.pumpWidget(_wrap(ListView(
      children: [
        _row(
          text: 'row-a',
          actions: [
            SwipeAction(
                icon: Icons.archive,
                label: '归档A',
                color: Colors.green,
                onTap: () {}),
          ],
        ),
        _row(
          text: 'row-b',
          actions: [
            SwipeAction(
                icon: Icons.archive,
                label: '归档B',
                color: Colors.red,
                onTap: () {}),
          ],
        ),
      ],
    )));

    await tester.drag(find.text('row-a'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(find.text('归档A'), findsOneWidget);

    // 展开第二行，第一行保持展开（无 autoClose 分组）
    await tester.drag(find.text('row-b'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(find.text('归档A'), findsOneWidget);
    expect(find.text('归档B'), findsOneWidget);

    // 收起第一行不影响第二行
    await tester.tapAt(tester.getCenter(find.text('row-a')));
    await tester.pumpAndSettle();
    expect(find.text('归档A'), findsNothing);
    expect(find.text('归档B'), findsOneWidget);
  });
}

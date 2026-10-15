import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/ui/schedule/yearly_view.dart';
import 'package:msgrepo_mobile/ui/schedule/day_view.dart';

/// v2.5 回归：fling 惯性滚动在第一次甩动后必须持续有效。
/// 根因：fling 动画用 SingleTickerProviderStateMixin 反复新建
/// AnimationController，第二次 createTicker 触发断言（debug 下抛异常，
/// fling 静默失效）。修复为 TickerProviderStateMixin + 帧末回收。
void main() {
  Widget yearly() => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: YearlyView(
              tasks: const [],
              selectedTaskId: null,
              onTaskSelected: (_) {},
              onTaskMoved: (_, __, ___) {},
              onYearTap: (_) {},
              onVisibleWindowChanged: (_, __) {},
              onCenterChanged: (_) {},
            ),
          ),
        ),
      );

  Widget day() => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: DayView(
              tasks: const [],
              selectedTaskId: null,
              onTaskSelected: (_) {},
              onTaskMoved: (_, __, ___) {},
              onBlankLongPress: (_) {},
              onVisibleWindowChanged: (_, __) {},
              onCenterChanged: (_) {},
            ),
          ),
        ),
      );

  testWidgets('年度视图连续两次 fling 均有惯性（无断言异常）', (tester) async {
    await tester.pumpWidget(yearly());
    await tester.pump();
    final target = find.byType(YearlyView);

    await tester.fling(target, const Offset(-300, 0), 1200);
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);

    // 第二次 fling：修复前在此处抛 SingleTickerProviderStateMixin 断言
    await tester.fling(target, const Offset(-300, 0), 1200);
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);

    // 动画自然衰减结束也不应再有异常
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('日视图连续两次 fling 均有惯性（无断言异常）', (tester) async {
    await tester.pumpWidget(day());
    await tester.pump();
    final target = find.byType(DayView);

    await tester.fling(target, const Offset(-300, 0), 1200);
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);

    await tester.fling(target, const Offset(300, 0), 1200);
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });
}

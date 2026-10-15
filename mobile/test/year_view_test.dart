import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/ui/schedule/year_view.dart';

/// v2.6 回归：年视图「现在」定位加深——滚动到当前月所在块并在可视区垂直居中。
void main() {
  testWidgets('「现在」定位加深：当月块在可视区垂直居中', (tester) async {
    final key = GlobalKey<YearViewState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 700,
          child: YearView(
            key: key,
            tasks: const [],
            selectedTaskId: null,
            onTaskSelected: (_) {},
            onMonthTap: (_) {},
            onTaskMoved: (_, __, ___) {},
            onBlankLongPress: (_) {},
            onVisibleWindowChanged: (_, __) {},
            onCenterChanged: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump();

    key.currentState!.scrollToNow();
    await tester.pump();

    // 与 year_view 同一套公式复核偏移：
    // 月块边长 = (宽 - 2*pad(8) - 2*gap(6)) / 3，行 = (month-1)~/3；
    // item 索引空间 × itemExtent(gridH + 24 + 8) + 标签 24 + 块中心，减半个视口。
    const pad = 8.0, gap = 6.0, labelH = 24.0;
    const infiniteScrollOffset = 1 << 20;
    const width = 400.0;
    const block = (width - 2 * pad - 2 * gap) / 3;
    const gridH = block * 4 + 3 * gap + 2 * pad;
    const itemExtent = gridH + labelH + 8;
    final now = DateTime.now();
    final itemTop = (now.year - 2000 + infiniteScrollOffset) * itemExtent;
    final blockTop = pad + ((now.month - 1) ~/ 3) * (block + gap);
    final center = itemTop + labelH + blockTop + block / 2;
    final dim = tester.getSize(find.byType(ListView)).height;
    final expected = center - dim / 2;

    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;
    expect(controller.offset, moreOrLessEquals(expected, epsilon: 1.0),
        reason: '当月块应垂直居中');
    // 脉冲目标 = 当前年月
    expect(find.text('${now.year}年'), findsWidgets);
    await tester.pump(const Duration(seconds: 2)); // 排空脉冲/防抖计时器
    expect(tester.takeException(), isNull);
  });
}

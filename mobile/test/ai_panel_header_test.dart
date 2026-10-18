import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/ui/messages/ai_panel.dart';

/// U9 回归：窄屏 + 大字号下，头部不得出现 RenderFlex 溢出，标题必须单行。
void main() {
  testWidgets('窄屏 320dp + 1.8 倍字号：不溢出，标题单行省略', (tester) async {
    tester.view.physicalSize = const Size(320 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(1.8)),
        child: Scaffold(
          body: AiProcessingHeader(
            settled: 1234,
            enqueued: 99999,
            pending: 1234,
          ),
        ),
      ),
    ));

    expect(tester.takeException(), isNull, reason: '不应出现布局溢出异常');
    expect(find.text('AI 处理中'), findsOneWidget);
    expect(find.textContaining('已处理 1234/99999'), findsOneWidget);
  });

  testWidgets('正常宽度下计数与标题都完整可见', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AiProcessingHeader(settled: 3, enqueued: 10, pending: 2),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('已处理 3/10 · 待确认 2'), findsOneWidget);
  });
}

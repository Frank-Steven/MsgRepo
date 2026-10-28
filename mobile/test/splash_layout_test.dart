import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/ui/splash_gate.dart';

/// Q13-A + B05/B06 的版式契约测试（2026-10-24），2026-10-28 起背景改为跟随深浅模式。
///
/// Q13-A 之后**原生阶段只铺背景色、不画图标**（`windowSplashScreenAnimatedIcon`
/// 显式指向透明占位 `@drawable/splash_icon_transparent`），所以下面这些数字是
/// **Flutter 侧唯一口径**（不再需要和原生 drawable 对齐）：
/// - 图标 116dp：1080px / 2.75 密度 ≈ 319px（设计稿 320px，屏宽 29.6%）；
/// - 图标中心在屏高 46.5%：864dp 高 ≈ 401.8dp；
/// - 图标底→名称顶 35dp（设计稿 96px @2.75）；
/// - 背景两档：浅 #FAFAFA / 深 #121212（与 res values(-night)/colors.xml 同步）。
///
/// 它同时给真机验收提供算术口径：图标应在 319px 附近、中心 y ≈ 1105px（2376 屏）。
void main() {
  /// 本机口径：1080×2376 物理像素 / devicePixelRatio 2.75 → 392.7×864 逻辑像素。
  void setDevice(WidgetTester tester) {
    tester.view.devicePixelRatio = 2.75;
    tester.view.physicalSize = const Size(1080, 2376);
    addTearDown(tester.view.reset);
  }

  /// 让 minimumDuration(900ms) 与退场动画(300ms) 都跑完。
  ///
  /// 只调 pumpAndSettle 不够：淡入结束后到 900ms 之间没有新帧，
  /// pumpAndSettle 会提前收工并留下 pending timer（测试 teardown 会报错）。
  Future<void> settleSplash(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pumpAndSettle();
  }

  Future<void> pumpSplash(WidgetTester tester,
      {Brightness? brightness, Key? key}) {
    return tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: brightness ?? Brightness.light),
      home: SplashGate(
        // 同一测试里多次 pump 时给不同 key，否则 State 复用、_showSplash 仍是 false
        key: key,
        bootstrap: Future<void>.value(),
        child: const SizedBox.expand(),
      ),
    ));
  }

  testWidgets('图标 116dp、水平居中、中心落在屏高 46.5%', (tester) async {
    setDevice(tester);
    await pumpSplash(tester);
    await tester.pump(const Duration(milliseconds: 200));

    final screen = tester.getSize(find.byType(SplashGate));
    expect(screen.height, closeTo(864, 0.5), reason: '1080/2.75 应为 864 逻辑像素');

    final icon = tester.getRect(find.byKey(const ValueKey('splash-icon')));
    expect(icon.width, closeTo(116, 0.01));
    expect(icon.height, closeTo(116, 0.01));
    expect(icon.center.dx, closeTo(screen.width / 2, 0.5), reason: '水平居中');
    expect(icon.center.dy / screen.height, closeTo(0.465, 0.0005),
        reason: '图标中心应在屏高 46.5%');

    await settleSplash(tester);
  });

  testWidgets('间距：图标底→名称顶 35dp', (tester) async {
    setDevice(tester);
    await pumpSplash(tester);
    await tester.pump(const Duration(milliseconds: 200));

    final icon = tester.getRect(find.byKey(const ValueKey('splash-icon')));
    final name = tester.getRect(find.byKey(const ValueKey('splash-name')));

    expect(name.top - icon.bottom, closeTo(35, 0.01));

    await settleSplash(tester);
  });

  testWidgets('文字：名称无下划线（21sp），颜色随深浅模式；标语已移除', (tester) async {
    setDevice(tester);
    await pumpSplash(tester);
    await tester.pump(const Duration(milliseconds: 200));

    final name = tester.widget<Text>(find.byKey(const ValueKey('splash-name')));
    expect(name.data, 'Manalist');
    expect(name.style?.fontSize, 21);
    // 2026-10-28：默认浅色主题下为深色文字（深色主题下为白色，见背景用例）
    expect(name.style?.color, Colors.black87);
    // 2026-10-24 用户：不要下划线
    expect(name.style?.decoration, isNot(TextDecoration.underline));

    // 2026-10-28 用户：启动页标语移除
    expect(find.byKey(const ValueKey('splash-tagline')), findsNothing);

    await settleSplash(tester);
  });

  testWidgets('背景跟随深浅模式：浅 #FAFAFA / 深 #121212', (tester) async {
    setDevice(tester);
    for (final brightness in [Brightness.light, Brightness.dark]) {
      await pumpSplash(tester, brightness: brightness, key: ValueKey(brightness));
      await tester.pump(const Duration(milliseconds: 200));

      final expected = splashBackgroundFor(brightness);
      final bg = tester.widgetList<ColoredBox>(find.byType(ColoredBox)).where(
          (w) =>
              w.color == splashBackgroundLight ||
              w.color == splashBackgroundDark ||
              w.color == const Color(0xFF3F51B5) ||
              w.color == const Color(0xFF283593));
      expect(bg.length, 1, reason: '$brightness 下应恰好一处启动页底色');
      expect(bg.first.color, expected,
          reason: '$brightness 下背景应为 $expected');

      await settleSplash(tester);
    }
  });

  test('像素换算契约：116dp ≈ 319px，46.5% @864dp ≈ 401.8dp', () {
    // 与卡面目标（320px ±10%、中心 46.5% ±2%）对齐；原生侧用同样参数烘焙位图。
    expect(splashIconSize * 2.75, closeTo(319, 1));
    expect(864 * splashIconCenterRatio, closeTo(401.76, 0.5));
    // 圆角比例与设计稿 rx 56 / 256 一致（原生 PNG 用同一比例烘焙）。
    expect(splashIconRadiusRatio, closeTo(56 / 256, 1e-9));
  });
}

import 'package:flutter/material.dart';

/// 启动页品牌色 —— **单档，不分昼夜**。
///
/// B07（2026-10-24 复核）：原生侧跟系统夜间模式、Flutter 侧跟 App 主题设置，
/// 「系统浅色 + App 深色」时会从 `#3F51B5` 跳到 `#283593`，交接处出现色相跳变。
/// Q13② 拍板统一品牌蓝，因此这里和 `android res values/values-night/colors.xml` 的
/// `splash_bg` 都必须是这**一个**色值，改一处就要同步另一处。
const Color splashBrandBlue = Color(0xFF3F51B5);

/// 图标边长（dp）。1080px 屏 / 2.75 密度 ≈ 320px，屏宽 29.6%（设计稿口径）。
const double splashIconSize = 116;

/// 图标中心相对屏高的位置 —— 46.5%，视觉中心略高于几何中心（设计稿口径）。
const double splashIconCenterRatio = 0.465;

/// 图标底 → 名称顶的距离（dp）。设计稿 96px @2.75。
const double splashIconToNameGap = 35;

/// 名称底 → 小字顶的距离（dp）。设计稿 80px @2.75。
const double splashNameToTaglineGap = 29;

/// 圆角半径占图标边长的比例（设计稿 rx 56 / 256 ≈ 21.875%）。
const double splashIconRadiusRatio = 0.21875;

/// 名称字号（sp）。设计稿 56px @2.75 ≈ 21sp。
const double splashNameFontSize = 21;

/// 一句话介绍字号（sp）。设计稿 32px @2.75 ≈ 12sp。
const double splashTaglineFontSize = 12;

/// F15（2026-10-22 用户）+ Q13②（2026-10-24 用户拍板）启动动画。
///
/// 设计（版式取自图标方案稿的启动页，按 Q13②「保留品牌蓝、按原稿比例重算」落地）：
/// 1. 图标从**完全透明**渐变到**完全不透明**（600ms，easeOut）。B05 要求「交接处不缩放」，
///    所以这里**不做**原来的 0.96 → 1.0 轻微放大，只保留透明度淡入。
///    Q13-A（2026-10-24 用户选 A）后，**原生阶段只铺品牌蓝、不画任何图标**
///    （`windowSplashScreenAnimatedIcon` 显式指向透明占位），因此这次 0 → 1 淡入
///    是图标的**首次出现**，不存在「原生图标消失再重现」的交接闪烁；
/// 2. 名称与一行小字延后 150ms 淡入（500ms），避免三块同时跳到脸上；
/// 3. 底层先在**第一帧**画启动页，下一帧才构建 [child]（主界面），这样数据库/页面初始化的
///    重活发生在启动页盖着的时候，而不是让用户盯着白屏；
/// 4. 启动完成（[bootstrap] 完成且不短于 [minimumDuration]）后启动页整体淡出（300ms）。
class SplashGate extends StatefulWidget {
  const SplashGate({
    super.key,
    required this.bootstrap,
    required this.child,
    this.minimumDuration = const Duration(milliseconds: 900),
  });

  /// 冷启动的重活（提醒初始化、采集轮询等）；完成得再快也不短于 [minimumDuration]。
  final Future<void> bootstrap;

  /// 启动页退场后显示的内容（HomeShell）。
  final Widget child;

  /// 启动页至少停留多久 —— 太快会像闪一下，比加载本身更让人不安。
  final Duration minimumDuration;

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> with TickerProviderStateMixin {
  static const Duration _iconFade = Duration(milliseconds: 600);
  static const Duration _textFade = Duration(milliseconds: 500);
  static const Duration _exitFade = Duration(milliseconds: 300);

  late final AnimationController _icon = AnimationController(
    vsync: this,
    duration: _iconFade,
  );
  late final AnimationController _text = AnimationController(
    vsync: this,
    duration: _textFade,
  );
  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: _exitFade,
  );

  bool _mountChild = false;
  bool _showSplash = true;

  @override
  void initState() {
    super.initState();
    // ① 先让启动页自己画上屏，② 再构建主界面（避免重活拖慢第一帧）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _mountChild = true);
    });
    _icon.forward();
    Future<void>.delayed(const Duration(milliseconds: 150), () {
      if (mounted) _text.forward();
    });
    _waitAndExit();
  }

  Future<void> _waitAndExit() async {
    try {
      await Future.wait<void>([
        widget.bootstrap,
        Future<void>.delayed(widget.minimumDuration),
      ]);
    } catch (_) {
      // 初始化失败也要退出启动页（主界面自己会报错/降级），不能卡在启动页
    }
    if (!mounted) return;
    await _exit.forward();
    if (!mounted) return;
    setState(() => _showSplash = false);
  }

  @override
  void dispose() {
    _icon.dispose();
    _text.dispose();
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final splash = LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height;
        // 关键版式：图标中心落在屏高 46.5%（不是整块内容居中）
        final iconTop = height * splashIconCenterRatio - splashIconSize / 2;
        final iconFade = CurvedAnimation(parent: _icon, curve: Curves.easeOut);
        final textFade = CurvedAnimation(parent: _text, curve: Curves.easeOut);
        return ColoredBox(
          color: splashBrandBlue,
          child: Stack(
            children: [
              Positioned(
                top: iconTop,
                left: 0,
                right: 0,
                child: Center(
                  child: FadeTransition(
                    opacity: iconFade,
                    child: const _SplashIcon(key: ValueKey('splash-icon')),
                  ),
                ),
              ),
              Positioned(
                top: iconTop + splashIconSize + splashIconToNameGap,
                left: 0,
                right: 0,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FadeTransition(
                      opacity: textFade,
                      child: const Text(
                        'Manalist',
                        key: ValueKey('splash-name'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: splashNameFontSize,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                          color: Colors.white,
                          // 2026-10-24 用户：开屏两行文字都纯白、都不要下划线
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: splashNameToTaglineGap),
                    FadeTransition(
                      opacity: textFade,
                      child: const Text(
                        '让纷杂的消息，归于条理',
                        key: ValueKey('splash-tagline'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: splashTaglineFontSize,
                          // 2026-10-24 用户：小字也改纯白（原 white70 偏灰）
                          color: Colors.white,
                          letterSpacing: 1.2,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        // 主界面：第一帧之后再挂，重活在启动页盖着时进行
        if (_mountChild) widget.child,
        if (_showSplash)
          FadeTransition(
            opacity: Tween<double>(begin: 1, end: 0).animate(
              CurvedAnimation(parent: _exit, curve: Curves.easeIn),
            ),
            child: splash,
          ),
      ],
    );
  }
}

/// 启动页图标：**圆角卡片**（不是圆形 —— 早期注释写错，B05 复核指出）。
///
/// 圆角用 [splashIconRadiusRatio]（设计稿 rx 56 / 256），与品牌图自身的圆角一致。
/// 卡片**不加外投影**：会撑大视觉包围盒、与设计稿「320px 卡片」的像素口径不符；
/// 深度感由图标图内自带的柔和阴影提供。
class _SplashIcon extends StatelessWidget {
  const _SplashIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(splashIconSize * splashIconRadiusRatio),
      child: Image.asset(
        'assets/splash/icon.png',
        width: splashIconSize,
        height: splashIconSize,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}

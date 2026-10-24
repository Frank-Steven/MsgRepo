import 'package:flutter/material.dart';

/// F15（2026-10-22 用户）：启动时屏幕空白 → 加「图标淡入」启动动画。
///
/// 设计（版式取自图标方案稿的启动页：图标 + 名称 + 一行小字）：
/// 1. 图标从**完全透明**渐变到**完全不透明**（600ms，easeOut），同时轻微放大（0.96 → 1.0）；
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
    final tt = Theme.of(context).textTheme;
    // 启动页背景用**品牌色**（与 android/res 里 launch_background / windowSplashScreenBackground 完全一致），
    // 这样「系统启动窗 → Flutter 启动页」是同一块底色，不会出现白 → 蓝的跳变。
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final splashBg = isDark ? const Color(0xFF283593) : const Color(0xFF3F51B5);
    final splash = ColoredBox(
      color: splashBg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FadeTransition(
              opacity: CurvedAnimation(parent: _icon, curve: Curves.easeOut),
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.96, end: 1).animate(
                  CurvedAnimation(parent: _icon, curve: Curves.easeOut),
                ),
                child: const _SplashIcon(),
              ),
            ),
            const SizedBox(height: 28),
            FadeTransition(
              opacity: CurvedAnimation(parent: _text, curve: Curves.easeOut),
              child: Text(
                'MsgRepo',
                style: tt.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 12),
            FadeTransition(
              opacity: CurvedAnimation(parent: _text, curve: Curves.easeOut),
              child: Text(
                '让纷杂的消息，归于条理',
                style: tt.bodySmall?.copyWith(
                  color: Colors.white70,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
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

/// 启动页图标：圆形卡片底 + 轻投影（图标本身自带浅底，圆角裁剪后在深色主题下也像「一张卡」）。
class _SplashIcon extends StatelessWidget {
  const _SplashIcon();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A000000),
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: Image.asset(
          'assets/splash/icon.png',
          width: 180,
          height: 180,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }
}

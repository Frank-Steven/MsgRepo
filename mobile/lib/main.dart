import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/ai_processing.dart';
import 'services/app_ui_state.dart';
import 'services/notification_bridge.dart';
import 'services/reminder_service.dart';
import 'ui/messages/ai_panel.dart';
import 'ui/messages/messages_page.dart';
import 'ui/notes/notes_page.dart';
import 'ui/schedule/schedule_page.dart';
import 'ui/settings_page.dart';
import 'ui/todos/todos_page.dart';
import 'services/app_log.dart';

/// 全局主题模式（设置页修改后即时生效）。持久化 key：theme_mode。
final themeModeNotifier = ValueNotifier<ThemeMode>(ThemeMode.system);

ThemeMode themeModeFromString(String? v) => switch (v) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

String themeModeToString(ThemeMode mode) => switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      _ => 'system',
    };

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 调试期错误落盘：部分设备 logcat 不可读，Flutter/异步错误写入
  // filesDir/debug_errors.log 供 adb pull 排查。
  if (kDebugMode) {
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      _appendDebugError(
          'FlutterError', details.exceptionAsString(), details.stack);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _appendDebugError('PlatformDispatcher', error.toString(), stack);
      return true;
    };
  }

  // 初始化失败（如本地数据损坏）也不能阻塞 runApp，否则直接黑屏
  try {
    await ReminderService.instance.init();
    // 进程重启后重排未来提醒（年度任务的逐年重复提醒暂不支持，跳过）
    await ReminderService.instance.rescheduleAll();
  } catch (e) {
    debugPrint('ReminderService 初始化失败: $e');
  }
  try {
    NotificationBridge.instance.startPolling();
  } catch (e) {
    debugPrint('NotificationBridge 启动失败: $e');
  }

  try {
    final prefs = await SharedPreferences.getInstance();
    themeModeNotifier.value =
        themeModeFromString(prefs.getString('theme_mode'));
  } catch (e) {
    debugPrint('主题设置读取失败: $e');
  }

  runApp(const MsgRepoApp());
}

Future<void> _appendDebugError(
    String kind, String message, StackTrace? stack) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/debug_errors.log');
    await f.writeAsString(
      '\n=== ${DateTime.now().toIso8601String()} [$kind] ===\n$message\n$stack\n',
      mode: FileMode.append,
    );
  } catch (e, st) {
    AppLog.instance.warn('main.log-file', e, st);
  }
}

/// SnackBar 主题（v2.6）：深色模式不再用 M3 默认的浅反色底——
/// 深色主题用深色 surface + 浅色文字，浅色主题保持反色底。
/// 全局 ThemeData 统一设置，所有 SnackBar（含撤销进度条）自动走此封装。
SnackBarThemeData snackBarThemeFor(ColorScheme cs) {
  final dark = cs.brightness == Brightness.dark;
  return SnackBarThemeData(
    backgroundColor: dark ? cs.surfaceContainerHigh : cs.inverseSurface,
    contentTextStyle:
        TextStyle(color: dark ? cs.onSurface : cs.onInverseSurface),
    actionTextColor: dark ? cs.primary : cs.inversePrimary,
  );
}

// 主题只算一次（O10）：`ColorScheme.fromSeed` 每次构建都跑一遍 HCT 换算，
// 切换深浅色时它被重复执行两遍，是主题切换卡顿的固定开销之一。
final ColorScheme _lightScheme = ColorScheme.fromSeed(seedColor: Colors.indigo);
final ColorScheme _darkScheme =
    ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.dark);
final ThemeData _lightTheme = ThemeData(
  useMaterial3: true,
  colorScheme: _lightScheme,
  snackBarTheme: snackBarThemeFor(_lightScheme),
);
final ThemeData _darkTheme = ThemeData(
  useMaterial3: true,
  colorScheme: _darkScheme,
  snackBarTheme: snackBarThemeFor(_darkScheme),
);

class MsgRepoApp extends StatelessWidget {
  const MsgRepoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'MsgRepo',
          debugShowCheckedModeBanner: false,
          theme: _lightTheme,
          darkTheme: _darkTheme,
          themeMode: mode,
          // O10：过渡时长从默认 200ms 收到 160ms。主题切换期间整棵树逐帧重建，
          // 缩短时长能减少「卡一下」的总帧数，观感靠曲线保住平滑。
          themeAnimationDuration: const Duration(milliseconds: 160),
          themeAnimationCurve: Curves.easeInOut,
          home: const HomeShell(),
        );
      },
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppUiState.instance.setTab(_index);
    // 冷启动时可能已在后台（如被通知拉起），用真实生命周期初始化
    final lc = WidgetsBinding.instance.lifecycleState;
    AppUiState.instance
        .setForeground(lc == null || lc == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // U19-C：只有真正离开（pause/hidden/detach）才算后台；
    // inactive 可能只是分屏/失焦/系统弹窗，不该因此改成发通知。
    final background = state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    AppUiState.instance.setForeground(!background);
  }

  int _index = 0;

  // IndexedStack 保活页面不会随切页重跑 initState，切入时用 GlobalKey 主动刷新
  final _scheduleKey = GlobalKey<SchedulePageState>();
  final _todosKey = GlobalKey<TodosPageState>();
  final _notesKey = GlobalKey<NotesPageState>();
  final _messagesKey = GlobalKey<MessagesPageState>();

  late final _pages = [
    SchedulePage(key: _scheduleKey),
    TodosPage(key: _todosKey),
    NotesPage(key: _notesKey),
    MessagesPage(key: _messagesKey),
    const SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          AnimatedBuilder(
            animation: AiProcessingService.instance,
            builder: (context, _) => _buildAiBanner(),
          ),
          // O10：RepaintBoundary 把页面栈的重绘与横幅/导航栏隔开，
          // 主题过渡时不必带着整屏一起重绘。
          Expanded(
            child: RepaintBoundary(
              child: IndexedStack(index: _index, children: _pages),
            ),
          ),
        ],
      ),
      bottomNavigationBar: AnimatedBuilder(
        animation: MessageBadges.instance,
        builder: (context, _) => _buildNavBar(),
      ),
    );
  }

  /// 全局 AI 处理横幅（U19-G）：任何 tab 都能看到进度，点击回到消息页并打开面板。
  Widget _buildAiBanner() {
    final session = AiProcessingService.instance.session;
    if (session == null) return const SizedBox.shrink();
    final running = session.running;
    final pending = session.pendingConfirmCount;
    final failed = session.failCount;
    if (!running && pending == 0 && failed == 0) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final String text;
    if (running) {
      text = 'AI 处理消息中 ${session.settledCount}/${session.enqueuedCount}'
          ' · 待确认 $pending';
    } else if (pending > 0) {
      text = 'AI 处理消息完成：$pending 条结果待确认'
          '${failed > 0 ? '，$failed 条失败' : ''}';
    } else {
      text = 'AI 处理消息完成：$failed 条失败';
    }
    final topInset = MediaQuery.of(context).padding.top;
    return Material(
      color: cs.primaryContainer,
      child: InkWell(
        onTap: () async {
          setState(() => _index = AppUiState.messagesTabIndex);
          AppUiState.instance.setTab(AppUiState.messagesTabIndex);
          _messagesKey.currentState?.reload();
          await showAiProcessPanel(context,
              onChanged: () => _messagesKey.currentState?.reload());
        },
        child: Padding(
          // 页面本身不带 SafeArea，横幅要自己避开状态栏（真机截图发现压在时间上）
          padding: EdgeInsets.fromLTRB(12, 6 + topInset, 12, 6),
          child: Row(
            children: [
              if (running)
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else
                Icon(Icons.check_circle_outline,
                    size: 16, color: cs.onPrimaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(text,
                    style:
                        TextStyle(fontSize: 12, color: cs.onPrimaryContainer)),
              ),
              Icon(Icons.chevron_right, size: 16, color: cs.onPrimaryContainer),
            ],
          ),
        ),
      ),
    );
  }

  /// U19-B：底部导航；「消息」带未处理数角标（页面常驻，后台也会刷新）
  Widget _buildNavBar() {
    final pending = MessageBadges.instance.pending;
    return NavigationBar(
      height: 72,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      selectedIndex: _index,
      onDestinationSelected: (i) {
        setState(() => _index = i);
        AppUiState.instance.setTab(i);
        switch (i) {
          case 0:
            _scheduleKey.currentState?.reload();
          case 1:
            _todosKey.currentState?.reload();
          case 2:
            _notesKey.currentState?.reload();
          case 3:
            _messagesKey.currentState?.reload();
        }
      },
      destinations: [
        const NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined), label: '日程'),
        const NavigationDestination(
            icon: Icon(Icons.check_circle_outline), label: '待办'),
        const NavigationDestination(
            icon: Icon(Icons.notes_outlined), label: '笔记'),
        NavigationDestination(
            icon: Badge(
              isLabelVisible: pending > 0,
              label: Text(pending > 99 ? '99+' : '$pending'),
              child: const Icon(Icons.mail_outline),
            ),
            label: '消息'),
        const NavigationDestination(
            icon: Icon(Icons.settings_outlined), label: '设置'),
      ],
    );
  }
}

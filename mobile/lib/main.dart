import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/notification_bridge.dart';
import 'services/reminder_service.dart';
import 'ui/messages/messages_page.dart';
import 'ui/notes/notes_page.dart';
import 'ui/settings_page.dart';
import 'ui/todos/todos_page.dart';

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
    // 进程重启后重排未来提醒（recurring 不支持调度，跳过）
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
    themeModeNotifier.value = themeModeFromString(prefs.getString('theme_mode'));
  } catch (e) {
    debugPrint('主题设置读取失败: $e');
  }

  runApp(const MsgRepoApp());
}

Future<void> _appendDebugError(String kind, String message, StackTrace? stack) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/debug_errors.log');
    await f.writeAsString(
      '\n=== ${DateTime.now().toIso8601String()} [$kind] ===\n$message\n$stack\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}

class MsgRepoApp extends StatelessWidget {
  const MsgRepoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) => MaterialApp(
        title: 'MsgRepo',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.indigo, brightness: Brightness.dark),
        ),
        themeMode: mode,
        home: const HomeShell(),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  // IndexedStack 保活页面不会随切页重跑 initState，切入时用 GlobalKey 主动刷新
  final _todosKey = GlobalKey<TodosPageState>();
  final _notesKey = GlobalKey<NotesPageState>();
  final _messagesKey = GlobalKey<MessagesPageState>();

  late final _pages = [
    const _SchedulePlaceholder(),
    TodosPage(key: _todosKey),
    NotesPage(key: _notesKey),
    MessagesPage(key: _messagesKey),
    const SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        height: 72,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        selectedIndex: _index,
        onDestinationSelected: (i) {
          setState(() => _index = i);
          switch (i) {
            case 1:
              _todosKey.currentState?.reload();
            case 2:
              _notesKey.currentState?.reload();
            case 3:
              _messagesKey.currentState?.reload();
          }
        },
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.calendar_month_outlined), label: '日程'),
          NavigationDestination(
              icon: Icon(Icons.check_circle_outline), label: '待办'),
          NavigationDestination(icon: Icon(Icons.notes_outlined), label: '笔记'),
          NavigationDestination(
              icon: Icon(Icons.mail_outline), label: '消息'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined), label: '设置'),
        ],
      ),
    );
  }
}

/// 日程占位页（阶段 4 接入三视图）。
class _SchedulePlaceholder extends StatelessWidget {
  const _SchedulePlaceholder();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('日程')),
      body: const Center(child: Text('日程视图将在阶段 4 接入')),
    );
  }
}

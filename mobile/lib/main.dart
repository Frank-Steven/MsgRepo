import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/notification_bridge.dart';
import 'services/reminder_service.dart';
import 'ui/inbox_page.dart';
import 'ui/items_page.dart';
import 'ui/settings_page.dart';

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

  // IndexedStack 保活页面不会随切页重跑 initState，切到结构化页时主动刷新
  final _itemsKey = GlobalKey<ItemsPageState>();

  late final _pages = [
    const InboxPage(),
    ItemsPage(key: _itemsKey),
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
          if (i == 1) _itemsKey.currentState?.reload();
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.inbox_outlined), label: '收件箱'),
          NavigationDestination(
              icon: Icon(Icons.auto_awesome_outlined), label: '结构化'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: '我的'),
        ],
      ),
    );
  }
}

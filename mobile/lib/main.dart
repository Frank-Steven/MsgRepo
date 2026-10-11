import 'package:flutter/material.dart';

import 'services/notification_bridge.dart';
import 'services/reminder_service.dart';
import 'ui/inbox_page.dart';
import 'ui/items_page.dart';
import 'ui/settings_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ReminderService.instance.init();
  // 进程重启后重排未来提醒（recurring 不支持调度，跳过）
  await ReminderService.instance.rescheduleAll();
  NotificationBridge.instance.startPolling();
  runApp(const MsgRepoApp());
}

class MsgRepoApp extends StatelessWidget {
  const MsgRepoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MsgRepo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const HomeShell(),
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

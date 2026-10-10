import 'dart:async';

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/database.dart';
import '../services/notification_bridge.dart';
import '../services/sync_client.dart';
import 'add_message_page.dart';

class InboxPage extends StatefulWidget {
  const InboxPage({super.key});

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> with WidgetsBindingObserver {
  List<RawMessage> _messages = [];
  String _filter = 'all'; // all | pending | processed | archived
  bool _listenerEnabled = true;
  bool _syncing = false;
  StreamSubscription<int>? _sub;

  static const _filters = {
    'all': '全部',
    'pending': '待处理',
    'processed': '已处理',
    'archived': '已归档',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
    _checkListener();
    _sub = NotificationBridge.instance.onNewMessages.listen((_) => _reload());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkListener();
      _reload();
    }
  }

  Future<void> _checkListener() async {
    final enabled = await NotificationBridge.instance.isListenerEnabled();
    if (mounted) setState(() => _listenerEnabled = enabled);
  }

  Future<void> _reload() async {
    final messages = await AppDatabase.instance.getRawMessages(
        status: _filter == 'all' ? null : _filter);
    if (mounted) setState(() => _messages = messages);
  }

  Future<void> _sync() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      final outcome = await SyncClient.instance.sync();
      if (!mounted) return;
      final text = outcome.sent == 0
          ? '没有待处理消息'
          : '已同步 ${outcome.sent} 条，处理 ${outcome.processed} 条，'
              '新增结构化结果 ${outcome.results} 条'
              '${outcome.warnings.isEmpty ? '' : '；警告：${outcome.warnings.join('；')}'}';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(text)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _syncing = false);
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('收件箱'),
        actions: [
          IconButton(
            tooltip: '立即同步',
            onPressed: _syncing ? null : _sync,
            icon: _syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: '手动添加',
        onPressed: () async {
          final added = await Navigator.of(context).push<bool>(
            MaterialPageRoute(builder: (_) => const AddMessagePage()),
          );
          if (added == true) _reload();
        },
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          if (!_listenerEnabled)
            MaterialBanner(
              content: const Text('通知监听未授权，无法自动采集通知'),
              leading: const Icon(Icons.notifications_off_outlined),
              actions: [
                TextButton(
                  onPressed: () async {
                    await NotificationBridge.instance.openListenerSettings();
                    await _checkListener();
                  },
                  child: const Text('去授权'),
                ),
              ],
            ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final entry in _filters.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(entry.value),
                      selected: _filter == entry.key,
                      onSelected: (_) {
                        setState(() => _filter = entry.key);
                        _reload();
                      },
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _sync,
              child: _messages.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(height: 120),
                        Center(child: Text('暂无消息，下拉可触发同步')),
                      ],
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: _messages.length,
                      itemBuilder: (context, i) =>
                          _MessageTile(message: _messages[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  final RawMessage message;

  const _MessageTile({required this.message});

  @override
  Widget build(BuildContext context) {
    final m = message;
    final statusColor = switch (m.status) {
      RawMessage.statusPending => Colors.orange,
      RawMessage.statusProcessed => Colors.green,
      _ => Colors.grey,
    };
    final statusLabel = switch (m.status) {
      RawMessage.statusPending => '待处理',
      RawMessage.statusProcessed => '已处理',
      _ => '已归档',
    };
    return ListTile(
      leading: Icon(m.captureType == RawMessage.captureNotification
          ? Icons.notifications_outlined
          : Icons.edit_note),
      title: Text(
        m.title.isEmpty ? '(无标题)' : m.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${m.source.appName ?? m.source.packageName}'
        '${m.source.conversationTitle != null ? ' · ${m.source.conversationTitle}' : ''}'
        ' · ${formatMillis(m.postedAt)}\n${m.body}',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: true,
      trailing: Chip(
        label: Text(statusLabel, style: const TextStyle(fontSize: 11)),
        backgroundColor: statusColor.withOpacity(0.15),
        side: BorderSide.none,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

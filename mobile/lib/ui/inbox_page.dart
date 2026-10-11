import 'dart:async';

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/database.dart';
import '../services/notification_bridge.dart';
import '../services/reminder_service.dart';
import '../services/sync_client.dart';
import 'add_message_page.dart';

class InboxPage extends StatefulWidget {
  const InboxPage({super.key});

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> with WidgetsBindingObserver {
  List<RawMessage> _messages = [];
  List<SourceApp> _sources = [];
  String _filter = 'all'; // all | pending | processed | archived
  String? _appFilter; // null = 全部应用，否则为 packageName
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
    final db = AppDatabase.instance;
    final messages = await db.getRawMessages(
        status: _filter == 'all' ? null : _filter, packageName: _appFilter);
    final sources = await db.getDistinctSources();
    if (mounted) {
      setState(() {
        _messages = messages;
        _sources = sources;
        // 所选应用的消息可能已不存在，回退到全部
        if (_appFilter != null &&
            !_sources.any((s) => s.packageName == _appFilter)) {
          _appFilter = null;
        }
      });
    }
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

  /// 右滑：待处理/已处理 → 归档；已归档 → 恢复为已处理。纯本地操作。
  /// 返回是否真正从列表移除该条目（"全部"视图下归档后仍可见，滑块弹回）。
  Future<bool> _swipeMessage(RawMessage m) async {
    final archiving = m.status != RawMessage.statusArchived;
    final newStatus =
        archiving ? RawMessage.statusArchived : RawMessage.statusProcessed;
    final staysVisible = _filter == 'all';
    await AppDatabase.instance.updateRawMessageStatus([m.id], newStatus);
    if (!mounted) return false;
    setState(() {
      if (staysVisible) {
        final i = _messages.indexWhere((e) => e.id == m.id);
        if (i >= 0) _messages[i].status = newStatus;
      } else {
        _messages.removeWhere((e) => e.id == m.id);
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(archiving ? '已归档' : '已恢复为已处理')));
    return !staysVisible;
  }

  /// 左滑回退（仅已处理）：回 pending + needs_reprocess=1，
  /// 删除关联结构化条目并取消其提醒。
  Future<bool> _revertMessage(RawMessage m) async {
    if (m.status != RawMessage.statusProcessed) return false;
    final affected =
        await AppDatabase.instance.revertMessageToPending(m.id);
    for (final item in affected) {
      await ReminderService.instance.cancelForItem(item);
    }
    if (!mounted) return false;
    setState(() {
      if (_filter == 'all') {
        final i = _messages.indexWhere((e) => e.id == m.id);
        if (i >= 0) {
          _messages[i].status = RawMessage.statusPending;
          _messages[i].needsReprocess = true;
        }
      } else {
        _messages.removeWhere((e) => e.id == m.id);
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已回退，下次同步将重新处理')));
    return _filter != 'all';
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
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final entry in _filters.entries)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(entry.value),
                        labelPadding:
                            const EdgeInsets.symmetric(horizontal: 4),
                        selected: _filter == entry.key,
                        onSelected: (_) {
                          setState(() => _filter = entry.key);
                          _reload();
                        },
                      ),
                    ),
                  ),
                if (_sources.isNotEmpty)
                  Center(
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String?>(
                        value: _appFilter,
                        hint: const Text('全部应用'),
                        items: [
                          const DropdownMenuItem<String?>(
                              value: null, child: Text('全部应用')),
                          for (final s in _sources)
                            DropdownMenuItem<String?>(
                              value: s.packageName,
                              child: Text(s.displayName),
                            ),
                        ],
                        onChanged: (v) {
                          setState(() => _appFilter = v);
                          _reload();
                        },
                      ),
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
                      itemBuilder: (context, i) => _MessageTile(
                        message: _messages[i],
                        onArchive: () => _swipeMessage(_messages[i]),
                        onRevert: () => _revertMessage(_messages[i]),
                      ),
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

  /// 右滑确认回调：执行归档/恢复，返回是否将条目从列表移除。
  final Future<bool> Function() onArchive;

  /// 左滑确认回调：已处理 → 回退待处理，返回是否将条目从列表移除。
  final Future<bool> Function() onRevert;

  const _MessageTile({
    required this.message,
    required this.onArchive,
    required this.onRevert,
  });

  @override
  Widget build(BuildContext context) {
    final m = message;
    final archived = m.status == RawMessage.statusArchived;
    final canRevert = m.status == RawMessage.statusProcessed;
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
    return Dismissible(
      key: ValueKey(m.id),
      direction: canRevert
          ? DismissDirection.horizontal
          : DismissDirection.startToEnd, // 右滑归档；已处理可左滑回退
      background: Container(
        color: archived ? Colors.green : Colors.blueGrey,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        child: Row(
          children: [
            Icon(
              archived ? Icons.unarchive_outlined : Icons.archive_outlined,
              color: Colors.white,
            ),
            const SizedBox(width: 8),
            Text(archived ? '恢复' : '归档',
                style: const TextStyle(color: Colors.white)),
          ],
        ),
      ),
      secondaryBackground: Container(
        color: Colors.orange,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text('回退', style: TextStyle(color: Colors.white)),
            SizedBox(width: 8),
            Icon(Icons.undo, color: Colors.white),
          ],
        ),
      ),
      confirmDismiss: (direction) => direction == DismissDirection.startToEnd
          ? onArchive()
          : onRevert(),
      child: ListTile(
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
      ),
    );
  }
}

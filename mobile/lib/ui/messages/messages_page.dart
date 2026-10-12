import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../models/task.dart';
import '../../services/database.dart';
import '../../services/notification_bridge.dart';
import '../../services/undo_service.dart';
import '../add_message_page.dart';
import '../tasks/task_editor.dart';
import 'ai_panel.dart';
import 'archived_page.dart';
import 'message_widgets.dart';

/// v2 消息主列表页（设计 §5.1）：分组吸顶列表 + Chip 筛选行 + 左滑块状菜单
/// + 多选批量操作。归档消息在独立页面（ArchivedMessagesPage）。
class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});

  @override
  State<MessagesPage> createState() => MessagesPageState();
}

class MessagesPageState extends State<MessagesPage> {
  final AppDatabase _db = AppDatabase.instance;

  List<Message> _messages = [];
  List<SourceApp> _sources = [];
  bool _loading = true;

  /// 状态分组多选筛选（默认全选）。
  final Set<String> _groupFilter = Set.of(kGroupOrder);
  String? _appFilter; // null = 全部应用

  bool _selecting = false;
  final Set<String> _selected = {};
  final Set<String> _collapsed = {};

  StreamSubscription<int>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = NotificationBridge.instance.onNewMessages.listen((_) => reload());
    reload();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// 重新加载列表（供 GlobalKey 外部触发）。
  Future<void> reload() async {
    final messages = await _db.getMessages(packageName: _appFilter);
    final sources = await _db.getDistinctMessageSources();
    if (!mounted) return;
    setState(() {
      _messages = messages
          .where((m) => m.status != MessageStatus.archived)
          .toList();
      _sources = sources;
      _loading = false;
      // 所选应用的消息可能已不存在，回退到全部
      if (_appFilter != null &&
          !_sources.any((s) => s.packageName == _appFilter)) {
        _appFilter = null;
      }
      _selected.removeWhere((id) => !_messages.any((m) => m.id == id));
      if (_selected.isEmpty) _selecting = false;
    });
  }

  List<Message> get _visible => _messages
      .where((m) => _groupFilter.contains(messageGroupKey(m)))
      .toList();

  Map<String, List<Message>> get _grouped {
    final map = {for (final k in kGroupOrder) k: <Message>[]};
    for (final m in _visible) {
      map[messageGroupKey(m)]!.add(m);
    }
    return map;
  }

  // ---- AI 处理（设计 §8：路由 + 流式面板）----

  Future<void> _processWithAi(List<String> ids) async {
    final msgs = await _db.getMessagesByIds(ids);
    if (msgs.isEmpty || !mounted) return;
    // 保持传入顺序（多选时为用户点选顺序）
    final order = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    msgs.sort(
        (a, b) => (order[a.id] ?? ids.length).compareTo(order[b.id] ?? ids.length));
    await showAiProcessPanel(context, msgs, onChanged: reload);
    await reload();
  }

  Future<void> _addManually() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const AddMessagePage()));
    await reload();
  }

  // ---- 单条/批量操作（成功后注册撤销，见设计 §6）----

  Future<void> _createTask(Message msg) async {
    final result = await showTaskEditor(
      context,
      seedTitle: msg.title,
      seedDescription: msg.body,
      sourceMessageId: msg.id,
    );
    final task = result?.task;
    if (task == null) return;
    await _db.insertTask(task);
    await _db.setMessageLinkedTask(msg.id, task.id);
    UndoService.instance.register(
      label: '已创建任务',
      undo: () async {
        await _db.deleteTasks([task.id]);
        await _db.setMessageLinkedTask(msg.id, null);
      },
    );
    if (!mounted) return;
    showUndoSnackBar(context, '已创建任务', onUndone: reload);
    await reload();
  }

  /// 删除选中消息各自关联的任务，并清除链接；撤销整体回滚。
  Future<void> _deleteLinkedTasks(List<Message> targets) async {
    final pairs = <(Message, Task?)>[];
    for (final m in targets) {
      final id = m.linkedTaskId;
      pairs.add((m, id == null ? null : await _db.getTaskById(id)));
    }
    await _db
        .deleteTasks([for (final (_, t) in pairs) if (t != null) t.id]);
    for (final (m, _) in pairs) {
      await _db.setMessageLinkedTask(m.id, null);
    }
    UndoService.instance.register(
      label: '已删除任务',
      undo: () async {
        for (final (m, t) in pairs) {
          if (t != null) await _db.insertTask(t);
          await _db.setMessageLinkedTask(m.id, m.linkedTaskId);
        }
      },
    );
    if (!mounted) return;
    showUndoSnackBar(context, '已删除任务', onUndone: reload);
    await reload();
  }

  Future<void> _markJunk(List<Message> targets) async {
    await _db.updateMessagePriority(
        [for (final m in targets) m.id], MessagePriority.junk);
    UndoService.instance.register(
      label: '已标记垃圾',
      undo: () async {
        for (final m in targets) {
          await _db.updateMessagePriority([m.id], m.priority);
        }
      },
    );
    if (!mounted) return;
    showUndoSnackBar(context, '已标记垃圾', onUndone: reload);
    await reload();
  }

  Future<void> _unjunk(List<Message> targets) async {
    await _db.updateMessagePriority(
        [for (final m in targets) m.id], MessagePriority.none);
    UndoService.instance.register(
      label: '已移出垃圾',
      undo: () async {
        await _db.updateMessagePriority(
            [for (final m in targets) m.id], MessagePriority.junk);
      },
    );
    if (!mounted) return;
    showUndoSnackBar(context, '已移出垃圾', onUndone: reload);
    await reload();
  }

  Future<void> _archive(List<Message> targets) async {
    await _db.updateMessageStatus(
        [for (final m in targets) m.id], MessageStatus.archived);
    UndoService.instance.register(
      label: '已归档',
      undo: () async {
        for (final m in targets) {
          await _db.updateMessageStatus([m.id], m.status);
        }
      },
    );
    if (!mounted) return;
    showUndoSnackBar(context, '已归档', onUndone: reload);
    await reload();
  }

  // ---- 多选模式 ----

  List<Message> get _selectedMessages =>
      _messages.where((m) => _selected.contains(m.id)).toList();

  void _toggleSelect(Message m) {
    setState(() {
      if (!_selected.remove(m.id)) _selected.add(m.id);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  Future<void> _runBatch(Future<void> Function(List<Message>) op) async {
    final targets = _selectedMessages;
    _exitSelection();
    if (targets.isNotEmpty) await op(targets);
  }

  // ---- 左滑菜单（按行状态，设计 §5.1）----

  List<SwipeAction> _actionsFor(Message m) {
    final cs = Theme.of(context).colorScheme;
    final isJunk = m.priority == MessagePriority.junk;
    final isPending = messageGroupKey(m) == kGroupPending;
    if (isJunk) {
      return [
        SwipeAction(
          icon: Icons.restore,
          label: '移出垃圾',
          color: cs.primary,
          onTap: () => _unjunk([m]),
        ),
        SwipeAction(
          icon: Icons.archive_outlined,
          label: '归档',
          color: cs.secondary,
          onTap: () => _archive([m]),
        ),
      ];
    }
    return [
      SwipeAction(
        icon: Icons.auto_awesome,
        label: isPending ? '自动处理' : '重新处理',
        color: cs.tertiary,
        onTap: () => _processWithAi([m.id]),
      ),
      if (m.linkedTaskId == null)
        SwipeAction(
          icon: Icons.add_task,
          label: '创建任务',
          color: cs.primary,
          onTap: () => _createTask(m),
        )
      else
        SwipeAction(
          icon: Icons.delete_outline,
          label: '删除任务',
          color: cs.error,
          onTap: () => _deleteLinkedTasks([m]),
        ),
      SwipeAction(
        icon: Icons.block,
        label: '标记垃圾',
        color: cs.outline,
        onTap: () => _markJunk([m]),
      ),
      SwipeAction(
        icon: Icons.archive_outlined,
        label: '归档',
        color: cs.secondary,
        onTap: () => _archive([m]),
      ),
    ];
  }

  // ---- 导入 / 归档入口 ----

  void _showImportSheet() {
    const entries = [
      (Icons.chat_bubble_outline, '微信'),
      (Icons.forum_outlined, 'QQ'),
      (Icons.sms_outlined, '短信'),
    ];
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (icon, name) in entries)
              ListTile(
                leading: Icon(icon),
                title: Text('从$name导入'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('即将支持')));
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openArchived() async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ArchivedMessagesPage()));
    await reload();
  }

  // ---- UI ----

  AppBar _buildAppBar() {
    if (_selecting) {
      return AppBar(
        leading: IconButton(
          tooltip: '退出',
          icon: const Icon(Icons.close),
          onPressed: _exitSelection,
        ),
        title: Text('已选 ${_selected.length} 项'),
        actions: [
          TextButton(
            onPressed: () => setState(
                () => _selected.addAll(_visible.map((m) => m.id))),
            child: const Text('全选'),
          ),
          TextButton(
            onPressed: _selected.isEmpty
                ? null
                : () => setState(() => _selected.clear()),
            child: const Text('取消'),
          ),
        ],
      );
    }
    return AppBar(
      title: const Text('消息'),
      actions: [
        IconButton(
          tooltip: '手动添加',
          icon: const Icon(Icons.add),
          onPressed: _addManually,
        ),
        IconButton(
          tooltip: '导入',
          icon: const Icon(Icons.file_upload_outlined),
          onPressed: _showImportSheet,
        ),
        IconButton(
          tooltip: '已归档',
          icon: const Icon(Icons.archive_outlined),
          onPressed: _openArchived,
        ),
      ],
    );
  }

  Widget _buildFilterRow(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    BorderSide chipSide(bool selected) => selected
        ? BorderSide.none
        : BorderSide(color: cs.outlineVariant);
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final key in kGroupOrder)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Text(messageGroupLabel(key)),
                  selected: _groupFilter.contains(key),
                  showCheckmark: false,
                  selectedColor: cs.secondaryContainer,
                  backgroundColor: cs.surfaceContainerHighest,
                  side: chipSide(_groupFilter.contains(key)),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (sel) => setState(() {
                    if (sel) {
                      _groupFilter.add(key);
                    } else {
                      _groupFilter.remove(key);
                    }
                  }),
                ),
              ),
            ),
          if (_sources.isNotEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Container(
                    width: 1, height: 24, color: cs.outlineVariant),
              ),
            ),
          if (_sources.isNotEmpty) ...[
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: const Text('全部'),
                  selected: _appFilter == null,
                  showCheckmark: false,
                  selectedColor: cs.secondaryContainer,
                  backgroundColor: cs.surfaceContainerHighest,
                  side: chipSide(_appFilter == null),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (_) {
                    setState(() => _appFilter = null);
                    reload();
                  },
                ),
              ),
            ),
            for (final s in _sources)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(s.displayName),
                    selected: _appFilter == s.packageName,
                    showCheckmark: false,
                    selectedColor: cs.secondaryContainer,
                    backgroundColor: cs.surfaceContainerHighest,
                    side: chipSide(_appFilter == s.packageName),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (_) {
                      setState(() => _appFilter = s.packageName);
                      reload();
                    },
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildList() {
    final grouped = _grouped;
    final empty = grouped.values.every((l) => l.isEmpty);
    if (empty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          Center(child: Text(_loading ? '加载中…' : '暂无消息')),
        ],
      );
    }
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        for (final key in kGroupOrder)
          if (grouped[key]!.isNotEmpty) ...[
            // 不用 pinned: 多个固定吸顶头挤在视口顶部会产生非法 SliverGeometry
            //（layoutExtent > paintExtent）导致整个视口不绘制；分组头随内容滚动。
            SliverPersistentHeader(
              delegate: MessageGroupHeaderDelegate(
                groupKey: key,
                count: grouped[key]!.length,
                collapsed: _collapsed.contains(key),
                onToggle: () => setState(() {
                  if (!_collapsed.remove(key)) _collapsed.add(key);
                }),
              ),
            ),
            if (!_collapsed.contains(key))
              SliverList.builder(
                itemCount: grouped[key]!.length,
                itemBuilder: (context, i) {
                  final m = grouped[key]![i];
                  return MessageTile(
                    key: ValueKey(m.id),
                    message: m,
                    selecting: _selecting,
                    selected: _selected.contains(m.id),
                    actions: _actionsFor(m),
                    onTap: () {
                      if (_selecting) _toggleSelect(m);
                    },
                    onLongPress: () {
                      if (!_selecting) {
                        setState(() {
                          _selecting = true;
                          _selected.add(m.id);
                        });
                      }
                    },
                  );
                },
              ),
          ],
        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }

  Widget _buildSelectionBar() {
    final targets = _selectedMessages;
    final hasSelection = targets.isNotEmpty;
    final anyJunk =
        targets.any((m) => m.priority == MessagePriority.junk);
    final allJunk = hasSelection &&
        targets.every((m) => m.priority == MessagePriority.junk);
    final allLinked = hasSelection &&
        targets.every((m) => m.linkedTaskId != null);
    final selectedIds = [for (final m in targets) m.id];
    return SelectionActionBar(
      actions: [
        SelectionAction(
          icon: Icons.archive_outlined,
          tooltip: '归档',
          enabled: hasSelection,
          onTap: () => _runBatch(_archive),
        ),
        SelectionAction(
          icon: Icons.block,
          tooltip: '标记垃圾',
          enabled: hasSelection && !anyJunk,
          onTap: () => _runBatch(_markJunk),
        ),
        SelectionAction(
          icon: Icons.restore,
          tooltip: '移出垃圾',
          enabled: allJunk,
          onTap: () => _runBatch(_unjunk),
        ),
        SelectionAction(
          icon: Icons.delete_outline,
          tooltip: '删除任务',
          enabled: allLinked,
          onTap: () => _runBatch(_deleteLinkedTasks),
        ),
        SelectionAction(
          icon: Icons.add_task,
          tooltip: '创建任务',
          enabled: targets.length == 1,
          onTap: () {
            final m = targets.first;
            _exitSelection();
            _createTask(m);
          },
        ),
        SelectionAction(
          icon: Icons.auto_awesome,
          tooltip: '自动处理',
          enabled: hasSelection,
          onTap: () {
            _exitSelection();
            _processWithAi(selectedIds);
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: Column(
        children: [
          _buildFilterRow(context),
          const Divider(height: 1),
          Expanded(
            child: RefreshIndicator(
              onRefresh: reload,
              child: _buildList(),
            ),
          ),
          if (_selecting) _buildSelectionBar(),
        ],
      ),
    );
  }
}

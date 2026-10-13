import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../models/task.dart';
import '../../services/database.dart';
import '../../services/task_scale.dart';
import '../../services/undo_service.dart';
import '../tasks/task_editor.dart';

/// 待办页（设计 §3，v2.1：按时间尺度分页）：顶部尺度页签 +
/// 各尺度 active 任务列表 + 已完成/已归档两个特殊页签。
class TodosPage extends StatefulWidget {
  const TodosPage({super.key});

  @override
  State<TodosPage> createState() => TodosPageState();
}

class TodosPageState extends State<TodosPage> {
  static const _recentWindow = Duration(hours: 24);
  static const _annualYearCount = 5;

  /// 页签顺序（设计 §3）：年度/季度/月度/整周/整日/定时/不定时/已完成/已归档。
  static const _scaleTabs = [
    'yearly',
    'quarterly',
    'monthly',
    'weekly',
    'daily',
    'timed',
  ];

  int _tab = 6; // 默认「不定时」（原"我的待办"）

  /// 六个时间尺度各自的 active 任务（不含 is_annual，按开始时间升序）。
  final Map<String, List<Task>> _byScale = {for (final s in _scaleTabs) s: []};
  List<Task> _untimed = [];
  List<Task> _annual = [];
  List<Task> _done = [];
  List<Task> _archived = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final db = AppDatabase.instance;
    final results = await Future.wait([
      db.getTasks(status: TaskStatus.active),
      db.getUntimedTasks(),
      db.getAnnualTasks(),
      db.getTasks(status: TaskStatus.done),
      db.getTasks(status: TaskStatus.archived),
    ]);
    final active = results[0];
    final untimed = results[1];
    // 年度任务（is_annual）与派生尺度正交：只在「年度」页签逐年展示
    final annual = results[2]
        .where((t) => t.status == TaskStatus.active)
        .toList();
    final done = results[3]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final archived = results[4]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final byScale = {for (final s in _scaleTabs) s: <Task>[]};
    for (final t in active) {
      final s = t.startAt;
      if (s == null || t.isAnnual) continue;
      final scale = deriveTimeScale(
        DateTime.fromMillisecondsSinceEpoch(s),
        t.endAt == null ? null : DateTime.fromMillisecondsSinceEpoch(t.endAt!),
      );
      byScale[scale]?.add(t);
    }
    // getTasks 已按 start_at 升序，分组内天然有序
    if (!mounted) return;
    setState(() {
      _byScale
        ..clear()
        ..addAll(byScale);
      _untimed = untimed;
      _annual = annual;
      _done = done;
      _archived = archived;
      _loading = false;
    });
  }

  void _showUndoSnack(String label) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('$label · 撤销'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () async {
            await UndoService.instance.undoLatest();
            await reload();
          },
        ),
      ),
    );
  }

  /// 勾选完成/取消完成；有来源消息时联动归档/恢复（设计 §3 行内勾选）。
  Future<void> _toggleDone(Task task) async {
    final db = AppDatabase.instance;
    final completing = task.status != TaskStatus.done;
    final msgId = task.sourceMessageId;
    final oldMsgStatus =
        msgId == null ? null : (await db.getMessageById(msgId))?.status;
    await db.setTaskStatus(
        [task.id], completing ? TaskStatus.done : TaskStatus.active);
    if (msgId != null) {
      await db.updateMessageStatus([msgId],
          completing ? MessageStatus.archived : MessageStatus.processed);
    }
    UndoService.instance.register(
      label: completing ? '已完成' : '已恢复',
      undo: () async {
        await db.setTaskStatus([task.id], task.status);
        if (msgId != null && oldMsgStatus != null) {
          await db.updateMessageStatus([msgId], oldMsgStatus);
        }
      },
    );
    await reload();
    if (mounted) _showUndoSnack(completing ? '已完成' : '已恢复');
  }

  Future<void> _unarchive(Task task) async {
    final db = AppDatabase.instance;
    await db.setTaskStatus([task.id], TaskStatus.active);
    UndoService.instance.register(
      label: '已取出',
      undo: () => db.setTaskStatus([task.id], TaskStatus.archived),
    );
    await reload();
    if (mounted) _showUndoSnack('已取出');
  }

  Future<void> _createTask() async {
    final result = await showTaskEditor(context);
    final task = result?.task;
    if (result == null || result.deleted || task == null || !mounted) return;
    final db = AppDatabase.instance;
    await db.insertTask(task);
    UndoService.instance.register(
      label: '已新建',
      undo: () => db.deleteTasks([task.id]),
    );
    await reload();
    if (mounted) _showUndoSnack('已新建');
  }

  Future<void> _editTask(Task task) async {
    final result = await showTaskEditor(context, existing: task);
    if (result == null || !mounted) return;
    final db = AppDatabase.instance;
    if (result.deleted) {
      await db.deleteTasks([task.id]);
      UndoService.instance.register(
        label: '已删除',
        undo: () => db.insertTask(task),
      );
      await reload();
      if (mounted) _showUndoSnack('已删除');
    } else if (result.task != null) {
      await db.updateTask(result.task!);
      UndoService.instance.register(
        label: '已保存',
        undo: () => db.insertTask(task),
      );
      await reload();
      if (mounted) _showUndoSnack('已保存');
    }
  }

  Future<void> _showSourceMessage(String messageId) async {
    final msg = await AppDatabase.instance.getMessageById(messageId);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(msg?.title ?? '来源消息'),
        content: SingleChildScrollView(
            child: Text(msg == null ? '原文已不存在' : msg.body)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  List<Task> _annualSorted() {
    final list = [..._annual];
    list.sort((a, b) {
      final am = a.startAt;
      final bm = b.startAt;
      if (am == null && bm == null) return 0;
      if (am == null) return -1;
      if (bm == null) return 1;
      final da = DateTime.fromMillisecondsSinceEpoch(am);
      final dbb = DateTime.fromMillisecondsSinceEpoch(bm);
      final c = da.month.compareTo(dbb.month);
      return c != 0 ? c : da.day.compareTo(dbb.day);
    });
    return list;
  }

  bool _isRecent(Task task) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return now - task.updatedAt < _recentWindow.inMilliseconds;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('待办'),
        actions: [
          IconButton(
            tooltip: '新建任务',
            onPressed: _createTask,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: Column(
        children: [
          _ScaleTabBar(
            tabs: const ['年度', '季度', '月度', '整周', '整日', '定时', '不定时', '已完成', '已归档'],
            selected: _tab,
            onChanged: (i) => setState(() => _tab = i),
          ),
          const Divider(height: 1),
          Expanded(
            child: RefreshIndicator(
              onRefresh: reload,
              child: _loading
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(height: 160),
                        Center(child: CircularProgressIndicator()),
                      ],
                    )
                  : _buildTabBody(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBody() {
    switch (_tab) {
      case 7:
        return _taskListView(_done, done: true);
      case 8:
        return _taskListView(_archived, archived: true);
      case 6:
        return _taskListView(_untimed);
      case 0:
        return _yearlyTabBody();
      default:
        return _taskListView(_byScale[_scaleTabs[_tab]] ?? const []);
    }
  }

  Widget _taskListView(List<Task> tasks,
      {bool done = false, bool archived = false}) {
    if (tasks.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          Center(child: _EmptyHint()),
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: tasks.length + 1,
      itemBuilder: (context, i) {
        if (i == tasks.length) return const SizedBox(height: 32);
        final task = tasks[i];
        return _TaskRow(
          task: task,
          archived: archived,
          recent: done && _isRecent(task),
          onTap: () => _editTask(task),
          onToggleDone: archived ? null : () => _toggleDone(task),
          onUnarchive: archived ? () => _unarchive(task) : null,
          onShowSource: task.sourceMessageId == null
              ? null
              : () => _showSourceMessage(task.sourceMessageId!),
        );
      },
    );
  }

  /// 「年度」页签（设计 §3）：先列派生尺度=年度的任务，
  /// 再接 is_annual 逐年分节（今年起 5 年，无任务的年份也显示年份标题）。
  Widget _yearlyTabBody() {
    final currentYear = DateTime.now().year;
    final derived = _byScale['yearly']!;
    final sorted = _annualSorted();
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        if (derived.isNotEmpty) ...[
          _sectionHeader(context, '年度尺度', derived.length),
          for (final task in derived)
            _TaskRow(
              task: task,
              onTap: () => _editTask(task),
              onToggleDone: () => _toggleDone(task),
              onShowSource: task.sourceMessageId == null
                  ? null
                  : () => _showSourceMessage(task.sourceMessageId!),
            ),
        ],
        _sectionHeader(context, '年度任务', _annual.length),
        for (var i = 0; i < _annualYearCount; i++) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 8, 12, 2),
            child: Text('${currentYear + i}年',
                style: Theme.of(context).textTheme.labelLarge),
          ),
          // 年度任务按 startAt 的月日在每年重复展示
          for (final task in sorted)
            _TaskRow(
              task: task,
              onTap: () => _editTask(task),
              onToggleDone: () => _toggleDone(task),
              onShowSource: task.sourceMessageId == null
                  ? null
                  : () => _showSourceMessage(task.sourceMessageId!),
            ),
        ],
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, String title, int count) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(width: 8),
          Text('$count',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// 尺度页签条（设计 §3 + §10.1）：等宽段、横向可滚动、选中只改底色。
class _ScaleTabBar extends StatelessWidget {
  final List<String> tabs;
  final int selected;
  final ValueChanged<int> onChanged;

  const _ScaleTabBar({
    required this.tabs,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outline),
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              for (var i = 0; i < tabs.length; i++) ...[
                if (i > 0) Container(width: 1, color: scheme.outline),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(i),
                  child: Container(
                    width: 60,
                    height: double.infinity,
                    alignment: Alignment.center,
                    color: i == selected
                        ? scheme.secondaryContainer
                        : Colors.transparent,
                    child: Text(
                      tabs[i],
                      style: TextStyle(
                        fontSize: 13,
                        color: i == selected
                            ? scheme.onSecondaryContainer
                            : scheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text('无', style: TextStyle(color: scheme.onSurfaceVariant));
  }
}

Color _priorityColor(String priority) => switch (priority) {
      TaskPriority.important => Colors.red,
      TaskPriority.minor => Colors.green,
      _ => Colors.amber,
    };

String _two(int v) => v.toString().padLeft(2, '0');

String _fmtMs(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
}

String _timeSummary(Task task) {
  final s = task.startAt;
  if (s == null) return '—';
  if (task.kind == TaskKind.range && task.endAt != null) {
    return '${_fmtMs(s)} → ${_fmtMs(task.endAt!)}';
  }
  return _fmtMs(s);
}

class _TaskRow extends StatelessWidget {
  final Task task;
  final bool archived;
  final bool recent;
  final VoidCallback onTap;
  final VoidCallback? onToggleDone;
  final VoidCallback? onUnarchive;
  final VoidCallback? onShowSource;

  const _TaskRow({
    required this.task,
    this.archived = false,
    this.recent = false,
    required this.onTap,
    this.onToggleDone,
    this.onUnarchive,
    this.onShowSource,
  });

  /// 行内尺度徽标（设计 §3）：派生尺度小字 chip。
  Widget _scaleChip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scale = deriveTimeScale(
      task.startAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(task.startAt!),
      task.endAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(task.endAt!),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        timeScaleLabel(scale),
        style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final done = task.status == TaskStatus.done;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (!archived)
              GestureDetector(
                onTap: onToggleDone,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: done ? scheme.primary : Colors.transparent,
                    border: Border.all(
                      width: 2,
                      color: done ? scheme.primary : scheme.outline,
                    ),
                  ),
                  child: done
                      ? Icon(Icons.check, size: 14, color: scheme.onPrimary)
                      : null,
                ),
              ),
            if (!archived) const SizedBox(width: 10),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _priorityColor(task.priority),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          task.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            decoration:
                                done ? TextDecoration.lineThrough : null,
                            color: done ? scheme.onSurfaceVariant : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _scaleChip(context),
                      if (recent) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('最近',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: scheme.onPrimaryContainer)),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    _timeSummary(task),
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (onShowSource != null)
              IconButton(
                tooltip: '查看来源消息',
                visualDensity: VisualDensity.compact,
                onPressed: onShowSource,
                icon: Icon(Icons.message_outlined,
                    size: 18, color: scheme.onSurfaceVariant),
              ),
            if (onUnarchive != null)
              IconButton(
                tooltip: '取出',
                visualDensity: VisualDensity.compact,
                onPressed: onUnarchive,
                icon: Icon(Icons.unarchive_outlined,
                    size: 20, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

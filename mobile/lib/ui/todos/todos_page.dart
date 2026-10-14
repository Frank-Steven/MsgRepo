import 'package:flutter/material.dart';

import '../../models/task.dart';
import '../../services/database.dart';
import '../../services/task_scale.dart';
import '../../services/undo_service.dart';
import '../messages/message_widgets.dart';
import '../tasks/task_editor.dart';
import '../tasks/task_tile.dart';

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

  /// 折叠的父任务 id（设计 §3：子任务在父行下缩进，默认展开）。
  final Set<String> _collapsedParents = {};

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
    showUndoSnackBar(context, label, onUndone: () async => reload());
  }

  /// 勾选完成/取消完成；有来源消息时联动归档/恢复（设计 §3 行内勾选）。
  Future<void> _toggleDone(Task task) =>
      toggleTaskDoneWithUndo(context, task, onChanged: reload);

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
    if (result.parentExpanded != null) {
      await db.updateTask(result.parentExpanded!);
    }
    await db.insertTask(task);
    final parentBefore = result.parentBefore;
    UndoService.instance.register(
      label: '已新建',
      undo: () async {
        await db.deleteTasks([task.id]);
        if (parentBefore != null) await db.updateTask(parentBefore);
      },
    );
    await reload();
    if (mounted) _showUndoSnack('已新建');
  }

  Future<void> _editTask(Task task) async {
    final result = await showTaskEditor(context, existing: task);
    if (result == null || !mounted) return;
    final db = AppDatabase.instance;
    if (result.deleted) {
      // 删父任务前先把子任务升级为普通任务（parent_id 置空），
      // 与删除合并为一个复合撤销（设计 §7）。
      final children = await db.getChildTasks(task.id);
      for (final c in children) {
        await db.updateTask(c.copyWith(parentId: () => null));
      }
      await db.deleteTasks([task.id]);
      UndoService.instance.register(
        label: '已删除',
        undo: () async {
          await db.insertTask(task);
          for (final c in children) {
            await db.updateTask(c);
          }
        },
      );
      await reload();
      if (mounted) _showUndoSnack('已删除');
    } else if (result.task != null) {
      if (result.parentExpanded != null) {
        await db.updateTask(result.parentExpanded!);
      }
      await db.updateTask(result.task!);
      final parentBefore = result.parentBefore;
      UndoService.instance.register(
        label: '已保存',
        undo: () async {
          await db.insertTask(task);
          if (parentBefore != null) await db.updateTask(parentBefore);
        },
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

  /// 子任务分组（设计 §3）：父任务在同列表时子任务附在父行下缩进，
  /// 父不在本列表的子任务按顶级行平铺；父行可折叠（默认展开）。
  Map<String, List<Task>> _childrenMap(List<Task> tasks) {
    final ids = {for (final t in tasks) t.id};
    final byParent = <String, List<Task>>{};
    for (final t in tasks) {
      final p = t.parentId;
      if (p != null && ids.contains(p)) {
        byParent.putIfAbsent(p, () => []).add(t);
      }
    }
    return byParent;
  }

  List<Task> _visibleRows(List<Task> tasks, Map<String, List<Task>> byParent) {
    final rows = <Task>[];
    for (final t in tasks) {
      final p = t.parentId;
      if (p != null && byParent.containsKey(p)) continue; // 由父行带出
      rows.add(t);
      if (!_collapsedParents.contains(t.id)) {
        rows.addAll(byParent[t.id] ?? const []);
      }
    }
    return rows;
  }

  Widget _tileFor(Task task, Map<String, List<Task>> byParent,
      {bool archived = false, bool recent = false}) {
    final isChild =
        task.parentId != null && byParent.containsKey(task.parentId);
    final children = byParent[task.id] ?? const <Task>[];
    return TaskTile(
      task: task,
      archived: archived,
      recent: recent,
      indent: isChild ? 24 : 0,
      hasChildren: children.isNotEmpty,
      collapsed: _collapsedParents.contains(task.id),
      onToggleCollapse: () => setState(() {
        if (!_collapsedParents.remove(task.id)) {
          _collapsedParents.add(task.id);
        }
      }),
      onTap: () => _editTask(task),
      onToggleDone: archived ? null : () => _toggleDone(task),
      onUnarchive: archived ? () => _unarchive(task) : null,
      onShowSource: task.sourceMessageId == null
          ? null
          : () => _showSourceMessage(task.sourceMessageId!),
    );
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
    final byParent = _childrenMap(tasks);
    final rows = _visibleRows(tasks, byParent);
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: rows.length + 1,
      itemBuilder: (context, i) {
        if (i == rows.length) return const SizedBox(height: 32);
        final task = rows[i];
        return _tileFor(task, byParent,
            archived: archived, recent: done && _isRecent(task));
      },
    );
  }

  /// 「年度」页签（设计 §3）：先列派生尺度=年度的任务，
  /// 再接 is_annual 逐年分节（今年起 5 年，无任务的年份也显示年份标题）。
  Widget _yearlyTabBody() {
    final currentYear = DateTime.now().year;
    final derived = _byScale['yearly']!;
    final derivedByParent = _childrenMap(derived);
    final derivedRows = _visibleRows(derived, derivedByParent);
    final sorted = _annualSorted();
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        if (derived.isNotEmpty) ...[
          _sectionHeader(context, '年度尺度', derived.length),
          for (final task in derivedRows) _tileFor(task, derivedByParent),
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
            _tileFor(task, const {}),
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


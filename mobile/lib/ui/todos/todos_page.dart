import 'package:flutter/material.dart';

import '../../models/task.dart';
import '../../services/database.dart';
import '../../services/task_scale.dart';
import '../../services/undo_service.dart';
import '../messages/message_widgets.dart';
import '../shared/segmented_selector.dart';
import '../tasks/task_detail_panel.dart';
import '../tasks/task_editor.dart';
import '../tasks/task_tile.dart';

/// 待办页（设计 §3，v2.3）：顶部尺度页签（含计数徽标）+ PageView 滑动翻页。
/// 点击任务行弹出任务详情面板（与日程视图共用 TaskDetailPanel），
/// 仅面板右上角编辑图标进编辑器；有子任务的行尾显示「已完成数/总数」；
/// 面板中点击父/子任务跳转到对应尺度页签并高亮定位。
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
  static const _tabLabels = ['年度', '季度', '月度', '整周', '整日', '定时', '不定时', '已完成', '已归档'];

  int _tab = 6; // 默认「不定时」（原"我的待办"）

  /// 六个时间尺度各自的 active 任务（不含 is_annual，按开始时间升序）。
  final Map<String, List<Task>> _byScale = {for (final s in _scaleTabs) s: []};
  List<Task> _untimed = [];
  List<Task> _annual = [];
  List<Task> _done = [];
  List<Task> _archived = [];

  /// 各父任务的直接子任务进度（done, total）（v2.3）。
  Map<String, (int, int)> _progress = {};
  bool _loading = true;

  /// 折叠的父任务 id（设计 §3：子任务在父行下缩进，默认展开）。
  final Set<String> _collapsedParents = {};

  /// 高亮定位的任务（v2.3：详情面板跳转选中态）。
  String? _selectedTaskId;
  final Map<String, GlobalKey> _rowKeys = {};

  final PageController _pageController = PageController(initialPage: 6);
  final ScrollController _tabScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _tabScrollController.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    final db = AppDatabase.instance;
    final results = await Future.wait([
      db.getTasks(status: TaskStatus.active),
      db.getUntimedTasks(),
      db.getAnnualTasks(),
      db.getTasks(status: TaskStatus.done),
      db.getTasks(status: TaskStatus.archived),
      db.getSubtaskProgress(),
    ]);
    final active = results[0] as List<Task>;
    final untimed = results[1] as List<Task>;
    // 年度任务（is_annual）与派生尺度正交：只在「年度」页签逐年展示
    final annual = (results[2] as List<Task>)
        .where((t) => t.status == TaskStatus.active)
        .toList();
    final done = (results[3] as List<Task>)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final archived = (results[4] as List<Task>)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final progress = results[5] as Map<String, (int, int)>;
    final byScale = {for (final s in _scaleTabs) s: <Task>[]};
    for (final t in active) {
      final s = t.startAt;
      if (s == null || t.isAnnual) continue;
      byScale[deriveTaskScale(t.startAt, t.endAt)]?.add(t);
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
      _progress = progress;
      _loading = false;
    });
  }

  /// 各页签计数徽标（设计 §3，v2.3）：年度 = 派生年度 + is_annual 任务数。
  List<int> get _tabBadges => [
        _byScale['yearly']!.length + _annual.length,
        for (final s in _scaleTabs.skip(1)) _byScale[s]!.length,
        _untimed.length,
        _done.length,
        _archived.length,
      ];

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

  /// 点击任务行：下方弹出任务详情面板（设计 §3，v2.3；不再直接进编辑器）。
  void _showDetail(Task task) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => TaskDetailPanel(
        task: task,
        onEdit: () {
          Navigator.of(ctx).pop();
          _editTask(task);
        },
        onOpenTask: (t) {
          Navigator.of(ctx).pop();
          _jumpToTask(t);
        },
      ),
    );
  }

  /// 任务所在页签（v2.3 跳转定位用）。
  int _tabForTask(Task t) {
    if (t.status == TaskStatus.done) return 7;
    if (t.status == TaskStatus.archived) return 8;
    if (t.isAnnual) return 0;
    if (t.startAt == null) return 6;
    final idx = _scaleTabs.indexOf(deriveTaskScale(t.startAt, t.endAt));
    return idx >= 0 ? idx : 6;
  }

  /// 跳转到任务对应尺度页签并高亮定位（滚动到可见 + 选中态）（设计 §3，v2.3）。
  void _jumpToTask(Task t) {
    final tab = _tabForTask(t);
    setState(() {
      _tab = tab;
      _selectedTaskId = t.id;
      if (t.parentId != null) _collapsedParents.remove(t.parentId);
    });
    _pageController.jumpToPage(tab);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _rowKeys[t.id]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          alignment: 0.3,
        );
      }
    });
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: SegmentedSelector<int>(
              values: const [0, 1, 2, 3, 4, 5, 6, 7, 8],
              labels: _tabLabels,
              badges: _tabBadges,
              selected: _tab,
              equalWidth: false,
              itemWidth: 64,
              scrollController: _tabScrollController,
              onChanged: (i) {
                setState(() => _tab = i);
                _pageController.animateToPage(i,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut);
              },
            ),
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
                  : PageView(
                      controller: _pageController,
                      onPageChanged: (i) => setState(() => _tab = i),
                      children: [
                        for (var i = 0; i < _tabLabels.length; i++)
                          _buildTabBody(i),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBody(int tab) {
    switch (tab) {
      case 7:
        return _taskListView(_done, done: true);
      case 8:
        return _taskListView(_archived, archived: true);
      case 6:
        return _taskListView(_untimed);
      case 0:
        return _yearlyTabBody();
      default:
        return _taskListView(_byScale[_scaleTabs[tab]] ?? const []);
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
      {bool archived = false, bool recent = false, bool keyed = true}) {
    final isChild =
        task.parentId != null && byParent.containsKey(task.parentId);
    final children = byParent[task.id] ?? const <Task>[];
    final progress = _progress[task.id];
    return TaskTile(
      key: keyed ? _rowKeys.putIfAbsent(task.id, () => GlobalKey()) : null,
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
      progress: (progress != null && progress.$2 > 0) ? progress : null,
      selected: task.id == _selectedTaskId,
      onTap: () => _showDetail(task),
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
          // 年度任务按 startAt 的月日在每年重复展示（同一任务出现多次，
          // 只在第一年分节挂 GlobalKey，避免重复 key 冲突）
          for (final task in sorted)
            _tileFor(task, const {}, keyed: i == 0),
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

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text('无', style: TextStyle(color: scheme.onSurfaceVariant));
  }
}

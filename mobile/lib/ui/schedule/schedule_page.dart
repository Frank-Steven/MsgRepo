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
import 'day_view.dart';
import 'month_view.dart';
import 'schedule_shared.dart';
import 'year_view.dart';
import 'yearly_view.dart';

/// 日程页（设计 §2，v2.3/v2.4 修订）：年度/年/月/日四级视图均无限滚动。
///
/// v2.3 变更：
/// - 平移箭头移入标题栏（[←] 标题 [→]），控制条只留段选器（居中固定宽）
///   与「现在」按钮；
/// - 任务加载改为按可视窗口增量缓存（[onVisibleWindowChanged] 驱动），
///   视图滚动即加载，不再按"当前期"整期重查；
/// - 点选任务后底部板块切换为任务详情面板（[TaskDetailPanel]）。
///
/// v2.4 变更：
/// - 各视图 onVisibleWindowChanged 上报**精确可视范围**（加载提前量在
///   [_ensureRange] 内统一加），底部任务面板 = 可视范围 ∩ scalesForView
///   放行集合的全部任务（不再限定单一尺度，年度视图也显示）；
/// - 标题：年度 = 实际可视年份范围（随缩放），年 = 「2026」、
///   月 = 「2026-10」、日 = 「2026-10-14 周三」。
///
/// 尺度过滤表（§2）：年度视图 = yearly；年视图 = quarterly/monthly/weekly；
/// 月视图 = weekly/daily；日视图 = timed；不定时不进日程。
/// （v2.4：is_annual UI 下线，不再逐年平移/特判。）
///
/// 通过 GlobalKey<SchedulePageState> 暴露 [SchedulePageState.reload]，
/// 供壳层切页时刷新（与其他页一致）。
class SchedulePage extends StatefulWidget {
  const SchedulePage({super.key});

  @override
  State<SchedulePage> createState() => SchedulePageState();
}

class SchedulePageState extends State<SchedulePage> {
  /// 0=年度 1=年 2=月 3=日
  int _granularity = 0;

  /// 当前视图的可视中心（由各视图 onCenterChanged 回写）。
  DateTime _anchor = DateTime.now();

  Task? _selectedTask;

  /// 当前视图的精确可视范围（各视图 onVisibleWindowChanged 上报，v2.4）——
  /// 用于底部任务面板与年度标题。
  int? _visStartMs;
  int? _visEndMs;

  /// 增量任务缓存：覆盖 [_cacheStart, _cacheEnd] 区间（按 id 覆盖式合并）。
  final Map<String, Task> _cache = {};
  int? _cacheStart;
  int? _cacheEnd;
  bool _loading = true;

  final _yearlyKey = GlobalKey<YearlyViewState>();
  final _yearKey = GlobalKey<YearViewState>();
  final _monthKey = GlobalKey<MonthViewState>();
  final _dayKey = GlobalKey<DayViewState>();

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// 初始/全量刷新：清空缓存，加载可视中心 ±2 年。
  Future<void> reload() async {
    _cache.clear();
    _cacheStart = null;
    _cacheEnd = null;
    final y = _anchor.year;
    await _ensureRange(
      DateTime(y - 2).millisecondsSinceEpoch,
      DateTime(y + 3).millisecondsSinceEpoch,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      final sel = _selectedTask;
      if (sel != null) _selectedTask = _cache[sel.id] ?? sel;
    });
  }

  /// 视口超出缓存范围时增量加载（向两侧各扩一个窗口宽做提前量）。
  Future<void> _ensureRange(int startMs, int endMs) async {
    final cs = _cacheStart, ce = _cacheEnd;
    if (cs != null && ce != null && startMs >= cs && endMs <= ce) return;
    final span = endMs - startMs;
    final ns = (cs == null
            ? startMs
            : (startMs < cs ? startMs : cs)) -
        span;
    final ne =
        (ce == null ? endMs : (endMs > ce ? endMs : ce)) + span;
    final db = AppDatabase.instance;
    // active 为主，done 淡色/划线展示；archived 不显示。
    // getTasksOverlapping 无条件包含年度任务，这里按平移后的发生年过滤。
    final results = await Future.wait([
      db.getTasksOverlapping(ns, ne),
      db.getTasksOverlapping(ns, ne, status: TaskStatus.done),
    ]);
    final tasks = [...results[0], ...results[1]]
        .where((t) => occurrenceOverlapping(t, ns, ne) != null);
    if (!mounted) return;
    setState(() {
      for (final t in tasks) {
        _cache[t.id] = t;
      }
      _cacheStart =
          _cacheStart == null ? ns : (_cacheStart! < ns ? _cacheStart! : ns);
      _cacheEnd = _cacheEnd == null ? ne : (_cacheEnd! > ne ? _cacheEnd! : ne);
    });
  }

  /// 甘特区任务：按当前粒度的尺度过滤表过滤（v2.4：不再对 is_annual
  /// 特判——该概念 UI 下线，老数据按派生尺度进各视图）。
  List<Task> get _ganttTasks {
    switch (_granularity) {
      case 0:
        return _filterByScales('yearly');
      case 1:
        return _filterByScales('year');
      case 2:
        return _filterByScales('month');
      default:
        return _filterByScales('day');
    }
  }

  List<Task> _filterByScales(String view) {
    final scales = scalesForView(view);
    return _cache.values
        .where((t) => scales.contains(deriveTaskScale(t.startAt, t.endAt)))
        .toList();
  }

  /// 底部任务列表板块（v2.4 §13 修订）：当前**可视时间范围**内、且尺度在
  /// 当前视图放行集合（scalesForView）内的全部任务，不再限定单一尺度；
  /// 年度视图同样显示（放行集合 = yearly）。
  List<Task> get _bottomTasks {
    final viewName =
        const ['yearly', 'year', 'month', 'day'][_granularity];
    final scales = scalesForView(viewName);
    final vs = _visStartMs, ve = _visEndMs;
    if (vs == null || ve == null) return const [];
    return _cache.values
        .where((t) =>
            t.status == TaskStatus.active &&
            t.startAt != null &&
            scales.contains(deriveTaskScale(t.startAt, t.endAt)) &&
            occurrenceOverlapping(t, vs, ve) != null)
        .toList()
      ..sort((a, b) => a.startAt!.compareTo(b.startAt!));
  }

  void _showUndoSnack(String label) {
    showUndoSnackBar(context, label, onUndone: () async => reload());
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
      setState(() => _selectedTask = null);
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
          await db.updateTask(task);
          if (parentBefore != null) await db.updateTask(parentBefore);
        },
      );
      await reload();
      if (mounted) _showUndoSnack('已保存');
    }
  }

  Future<void> _createTask({int? seedStartAt, String? seedKind}) async {
    final result = await showTaskEditor(context,
        seedStartAt: seedStartAt, seedKind: seedKind);
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

  /// 拖拽落库：更新时间 + 撤销（恢复旧任务）+ 刷新。
  Future<void> _moveTask(Task task, int newStartMs, int? newEndMs) async {
    final updated = task.copyWith(
      startAt: () => newStartMs,
      endAt: () => newEndMs,
    );
    final db = AppDatabase.instance;
    await db.updateTask(updated);
    UndoService.instance.register(
      label: '已调整时间',
      undo: () => db.updateTask(task),
    );
    await reload();
    if (mounted) _showUndoSnack('已调整时间');
  }

  /// 勾选完成/取消完成（底部板块，设计 §2 行 UI 照搬待办页）。
  Future<void> _toggleDone(Task task) =>
      toggleTaskDoneWithUndo(context, task, onChanged: reload);

  /// 详情面板中点父/子任务：按目标任务的尺度切换到能展示它的粒度并定位。
  void _jumpToTask(Task t) {
    final s = t.startAt;
    if (s == null) return; // 不定时任务在日程无视图可跳
    final g = t.isAnnual
        ? 0
        : switch (deriveTaskScale(t.startAt, t.endAt)) {
            'yearly' => 0,
            'quarterly' || 'monthly' => 1,
            'weekly' || 'daily' => 2,
            _ => 3,
          };
    setState(() {
      _granularity = g;
      _selectedTask = t;
      _anchor = DateTime.fromMillisecondsSinceEpoch(s);
    });
    _afterTwoFrames(() {
      switch (g) {
        case 0:
          _yearlyKey.currentState?.scrollToTask(t);
        case 1:
          _yearKey.currentState?.scrollToTask(t);
        case 2:
          _monthKey.currentState?.scrollToTask(t);
        case 3:
          _dayKey.currentState?.scrollToTask(t);
      }
    });
  }

  /// 等两帧再定位：第一帧新视图挂载（其首帧 scrollToNow），第二帧覆盖到目标。
  void _afterTwoFrames(VoidCallback fn) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) => fn());
    });
  }

  void _onTaskSelected(Task? t) {
    setState(() => _selectedTask = t);
  }

  /// 可视窗口变化：记录精确可视范围（底部面板/标题用）+ 增量加载。
  void _onWindowChanged(int startMs, int endMs) {
    setState(() {
      _visStartMs = startMs;
      _visEndMs = endMs;
    });
    _ensureRange(startMs, endMs);
  }

  /// 标题栏箭头平移：年度 ±20 年、年 ±1 年、月 ±1 月、日 ±1 天。
  void _shiftPeriod(int delta) {
    final target = switch (_granularity) {
      0 => DateTime(_anchor.year + delta * 20, _anchor.month),
      1 => DateTime(_anchor.year + delta, _anchor.month),
      2 => DateTime(_anchor.year, _anchor.month + delta),
      _ => DateTime(_anchor.year, _anchor.month, _anchor.day + delta),
    };
    setState(() => _anchor = target);
    switch (_granularity) {
      case 0:
        _yearlyKey.currentState?.scrollTo(target);
      case 1:
        _yearKey.currentState?.scrollTo(target);
      case 2:
        _monthKey.currentState?.scrollTo(target);
      case 3:
        _dayKey.currentState?.scrollTo(target);
    }
  }

  void _goNow() {
    switch (_granularity) {
      case 0:
        _yearlyKey.currentState?.scrollToNow();
      case 1:
        _yearKey.currentState?.scrollToNow();
      case 2:
        _monthKey.currentState?.scrollToNow();
      case 3:
        _dayKey.currentState?.scrollToNow();
    }
  }

  /// AppBar 标题（v2.4）：年度 = 实际可视年份范围（随缩放变化）；
  /// 年 = 「2026」；月 = 「2026-10」；日 = 「2026-10-14 周三」。
  String get _title {
    switch (_granularity) {
      case 0:
        final vs = _visStartMs, ve = _visEndMs;
        if (vs != null && ve != null) {
          final first = DateTime.fromMillisecondsSinceEpoch(vs).year;
          final last =
              DateTime.fromMillisecondsSinceEpoch(ve - 1).year;
          return '$first–$last';
        }
        return '${_anchor.year - 10}–${_anchor.year + 9}';
      case 2:
        final m = _anchor.month.toString().padLeft(2, '0');
        return '${_anchor.year}-$m';
      case 3:
        const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
        final mo = _anchor.month.toString().padLeft(2, '0');
        final d = _anchor.day.toString().padLeft(2, '0');
        return '${_anchor.year}-$mo-$d ${weekdays[_anchor.weekday - 1]}';
      default:
        return '${_anchor.year}';
    }
  }

  Widget _ganttView() {
    final tasks = _ganttTasks;
    switch (_granularity) {
      case 0:
        return YearlyView(
          key: _yearlyKey,
          tasks: tasks,
          selectedTaskId: _selectedTask?.id,
          onTaskSelected: _onTaskSelected,
          onTaskMoved: _moveTask,
          onYearTap: _drillToYear,
          onVisibleWindowChanged: _onWindowChanged,
          onCenterChanged: (c) => setState(() => _anchor = c),
        );
      case 2:
        return MonthView(
          key: _monthKey,
          tasks: tasks,
          selectedTaskId: _selectedTask?.id,
          onTaskSelected: _onTaskSelected,
          onDayTap: _drillToDay,
          onTaskMoved: _moveTask,
          onBlankLongPress: (ms) => _createTask(
            seedStartAt: ms + const Duration(hours: 9).inMilliseconds,
            seedKind: TaskKind.point,
          ),
          onVisibleWindowChanged: _onWindowChanged,
          onCenterChanged: (c) => setState(() => _anchor = c),
        );
      case 3:
        return DayView(
          key: _dayKey,
          tasks: tasks,
          selectedTaskId: _selectedTask?.id,
          onTaskSelected: _onTaskSelected,
          onTaskMoved: _moveTask,
          onBlankLongPress: (ms) => _createTask(
            seedStartAt: ms,
            seedKind: TaskKind.point,
          ),
          onVisibleWindowChanged: _onWindowChanged,
          onCenterChanged: (c) => setState(() => _anchor = c),
        );
      default:
        return YearView(
          key: _yearKey,
          tasks: tasks,
          selectedTaskId: _selectedTask?.id,
          onTaskSelected: _onTaskSelected,
          onMonthTap: _drillToMonth,
          onTaskMoved: _moveTask,
          onBlankLongPress: (ms) {
            final m = DateTime.fromMillisecondsSinceEpoch(ms);
            _createTask(
              seedStartAt:
                  DateTime(m.year, m.month, 1, 9).millisecondsSinceEpoch,
              seedKind: TaskKind.range,
            );
          },
          onVisibleWindowChanged: _onWindowChanged,
          onCenterChanged: (c) => setState(() => _anchor = c),
        );
    }
  }

  void _drillToYear(int year) {
    final target = DateTime(year, 7);
    setState(() {
      _granularity = 1;
      _selectedTask = null;
      _anchor = target;
    });
    _afterTwoFrames(() => _yearKey.currentState?.scrollTo(target));
  }

  void _drillToMonth(int monthMs) {
    final m = DateTime.fromMillisecondsSinceEpoch(monthMs);
    final target = DateTime(m.year, m.month, 15);
    setState(() {
      _granularity = 2;
      _selectedTask = null;
      _anchor = target;
    });
    _afterTwoFrames(() => _monthKey.currentState?.scrollTo(target));
  }

  void _drillToDay(int dayMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(dayMs);
    final target = DateTime(d.year, d.month, d.day);
    setState(() {
      _granularity = 3;
      _selectedTask = null;
      _anchor = target;
    });
    _afterTwoFrames(() => _dayKey.currentState?.scrollTo(target));
  }

  /// 底部板块：有选中 = 任务详情面板；无选中 = 原任务列表（设计 §2）。
  Widget _bottomSection(BuildContext context) {
    final selected = _selectedTask;
    if (selected != null) {
      return Expanded(
        flex: 2,
        child: Column(children: [
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              child: TaskDetailPanel(
                key: ValueKey(selected.id),
                task: selected,
                onEdit: () => _editTask(selected),
                onOpenTask: _jumpToTask,
              ),
            ),
          ),
        ]),
      );
    }
    final tasks = _bottomTasks;
    return Expanded(
      flex: 2,
      child: Column(
        children: [
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
            child: Row(
              children: [
                Text('任务', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(width: 8),
                Text('${tasks.length}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          Expanded(
            child: tasks.isEmpty
                ? Center(
                    child: Text('无',
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  )
                : ListView.builder(
                    itemCount: tasks.length,
                    itemBuilder: (context, i) {
                      final task = tasks[i];
                      return TaskTile(
                        task: task,
                        onTap: () => _editTask(task),
                        onToggleDone: () => _toggleDone(task),
                        onShowSource: task.sourceMessageId == null
                            ? null
                            : () => _showSourceMessage(task.sourceMessageId!),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          IconButton(
            tooltip: '上一期',
            visualDensity: VisualDensity.compact,
            onPressed: () => _shiftPeriod(-1),
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(child: Center(child: Text(_title))),
          IconButton(
            tooltip: '下一期',
            visualDensity: VisualDensity.compact,
            onPressed: () => _shiftPeriod(1),
            icon: const Icon(Icons.chevron_right),
          ),
        ]),
      ),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 260,
                    child: SegmentedSelector<int>(
                      values: const [0, 1, 2, 3],
                      labels: const ['年度', '年', '月', '日'],
                      selected: _granularity,
                      onChanged: (i) {
                        if (i == _granularity) return;
                        setState(() {
                          _granularity = i;
                          _selectedTask = null;
                        });
                        _afterTwoFrames(() {
                          switch (i) {
                            case 0:
                              _yearlyKey.currentState?.scrollTo(_anchor);
                            case 1:
                              _yearKey.currentState?.scrollTo(_anchor);
                            case 2:
                              _monthKey.currentState?.scrollTo(_anchor);
                            case 3:
                              _dayKey.currentState?.scrollTo(_anchor);
                          }
                        });
                      },
                    ),
                  ),
                  TextButton(onPressed: _goNow, child: const Text('现在')),
                ],
              ),
            ),
          ),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else ...[
            Expanded(flex: 3, child: _ganttView()),
            // v2.4：底部面板所有粒度都显示（含年度）
            _bottomSection(context),
          ],
        ],
      ),
    );
  }
}

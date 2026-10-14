import 'package:flutter/material.dart';

import '../../models/task.dart';
import '../../services/database.dart';
import '../../services/date_ranges.dart';
import '../../services/task_scale.dart';
import '../../services/undo_service.dart';
import '../messages/message_widgets.dart';
import '../tasks/task_editor.dart';
import '../tasks/task_tile.dart';
import 'day_view.dart';
import 'month_view.dart';
import 'schedule_shared.dart';
import 'year_view.dart';
import 'yearly_view.dart';

/// 日程页（设计 §2，v2.2：四粒度）：年度/年/月/日四级视图 + 顶部控制条。
///
/// 尺度过滤表（§2）：年度视图 = yearly + is_annual 逐年节点；
/// 年视图 = quarterly/monthly/weekly；月视图 = weekly/daily；
/// 日视图 = timed；不定时不进日程；is_annual 只进年度视图。
/// 年/月/日视图下方有底部任务列表板块（§2）：年视图下 = yearly∩当年、
/// 月视图下 = monthly∩当月、日视图下 = daily∩当日（均为 active）。
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
  late int _year; // 年度粒度下为窗口中心年
  late int _month;
  late DateTime _day;

  List<Task> _tasks = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _year = now.year;
    _month = now.month;
    _day = DateTime(now.year, now.month, now.day);
    reload();
  }

  /// 当前视图的查询范围（年度粒度取中心年 ±10 窗口；
  /// 月视图取覆盖当月的完整周网格）。
  (int, int) get _range {
    switch (_granularity) {
      case 0:
        return (
          DateTime(_year - 10).millisecondsSinceEpoch,
          DateTime(_year + 11).millisecondsSinceEpoch,
        );
      case 2:
        final first = DateTime(_year, _month);
        final start = DateTime(
            first.year, first.month, first.day - first.weekday % 7);
        final last = DateTime(_year, _month + 1, 0);
        final end =
            DateTime(last.year, last.month, last.day + (7 - last.weekday % 7));
        return (start.millisecondsSinceEpoch, end.millisecondsSinceEpoch);
      case 3:
        final start = DateTime(_day.year, _day.month, _day.day);
        return (
          start.millisecondsSinceEpoch,
          DateTime(start.year, start.month, start.day + 1)
              .millisecondsSinceEpoch
        );
      default:
        final r = yearRange(_year);
        return (r.startMs, r.endMs);
    }
  }

  Future<void> reload() async {
    final db = AppDatabase.instance;
    final (startMs, endMs) = _range;
    // active 为主，done 淡色/划线展示；archived 不显示。
    // getTasksOverlapping 无条件包含年度任务，这里按平移后的发生年过滤。
    final results = await Future.wait([
      db.getTasksOverlapping(startMs, endMs),
      db.getTasksOverlapping(startMs, endMs, status: TaskStatus.done),
    ]);
    final tasks = [...results[0], ...results[1]]
        .where((t) => occurrenceOverlapping(t, startMs, endMs) != null)
        .toList();
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _loading = false;
    });
  }

  /// 甘特区任务：按当前粒度的尺度过滤表过滤（is_annual 只进年度视图）。
  List<Task> get _ganttTasks {
    switch (_granularity) {
      case 0:
        return _tasks
            .where((t) =>
                t.isAnnual || deriveTaskScale(t.startAt, t.endAt) == 'yearly')
            .toList();
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
    return _tasks
        .where((t) =>
            !t.isAnnual && scales.contains(deriveTaskScale(t.startAt, t.endAt)))
        .toList();
  }

  /// 底部任务列表板块（设计 §2）：年视图下 = yearly∩当年；
  /// 月视图下 = monthly∩当月；日视图下 = daily∩当日；年度视图无底部板块。
  List<Task> get _bottomTasks {
    final scale = switch (_granularity) {
      1 => 'yearly',
      2 => 'monthly',
      3 => 'daily',
      _ => '',
    };
    if (scale.isEmpty) return const [];
    final (startMs, endMs) = _range;
    return _tasks
        .where((t) =>
            t.status == TaskStatus.active &&
            !t.isAnnual &&
            t.startAt != null &&
            deriveTaskScale(t.startAt, t.endAt) == scale &&
            occurrenceOverlapping(t, startMs, endMs) != null)
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

  void _drillToYear(int year) {
    setState(() {
      _year = year;
      _granularity = 1;
    });
    reload();
  }

  void _drillToMonth(int month) {
    setState(() {
      _month = month;
      _granularity = 2;
    });
    reload();
  }

  void _drillToDay(DateTime day) {
    setState(() {
      _day = DateTime(day.year, day.month, day.day);
      _year = day.year;
      _month = day.month;
      _granularity = 3;
    });
    reload();
  }

  /// 上跳链（设计 §2.5）：日 → 月 → 年 → 年度。
  void _jumpUp() {
    if (_granularity == 0) return;
    setState(() => _granularity--);
    reload();
  }

  void _goToday() {
    final now = DateTime.now();
    setState(() {
      _year = now.year;
      _month = now.month;
      _day = DateTime(now.year, now.month, now.day);
    });
    reload();
  }

  void _shiftPeriod(int delta) {
    setState(() {
      switch (_granularity) {
        case 0:
          _year += delta * 10; // 年度窗口按 ±10 年平移
        case 1:
          _year += delta;
        case 2:
          final d = DateTime(_year, _month + delta);
          _year = d.year;
          _month = d.month;
        case 3:
          _day = DateTime(_day.year, _day.month, _day.day + delta);
          _year = _day.year;
          _month = _day.month;
      }
    });
    reload();
  }

  /// AppBar 标题（设计 §2/§2.5）：年度粒度显示轴覆盖区间，其余显示当前期。
  String get _title {
    switch (_granularity) {
      case 0:
        return '${_year - 10}–${_year + 10}';
      case 2:
        return '$_year年$_month月';
      case 3:
        const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
        return '${_day.year}年${_day.month}月${_day.day}日'
            '（${weekdays[_day.weekday - 1]}）';
      default:
        return '$_year年';
    }
  }

  Widget _ganttView() {
    switch (_granularity) {
      case 0:
        return YearlyView(
          key: ValueKey('Y-$_year'),
          centerYear: _year,
          tasks: _ganttTasks,
          onTaskTap: _editTask,
          onTaskMoved: _moveTask,
          onYearTap: _drillToYear,
        );
      case 2:
        return MonthView(
          key: ValueKey('m-$_year-$_month'),
          year: _year,
          month: _month,
          tasks: _ganttTasks,
          onDayTap: _drillToDay,
          onTaskTap: _editTask,
          onTaskMoved: _moveTask,
          onBlankLongPress: (day) => _createTask(
            seedStartAt:
                DateTime(day.year, day.month, day.day, 9).millisecondsSinceEpoch,
            seedKind: TaskKind.point,
          ),
        );
      case 3:
        return DayView(
          key: ValueKey('d-$_day'),
          day: _day,
          tasks: _ganttTasks,
          onTaskTap: _editTask,
          onTaskMoved: _moveTask,
          onBlankLongPress: (ms) => _createTask(
            seedStartAt: ms,
            seedKind: TaskKind.point,
          ),
        );
      default:
        return YearView(
          key: ValueKey('y-$_year'),
          year: _year,
          tasks: _ganttTasks,
          onMonthTap: _drillToMonth,
          onTaskTap: _editTask,
          onTaskMoved: _moveTask,
          onBlankLongPress: (month) => _createTask(
            seedStartAt: DateTime(_year, month, 1, 9).millisecondsSinceEpoch,
            seedKind: TaskKind.range,
          ),
        );
    }
  }

  /// 底部任务列表板块（设计 §2）：行 UI 照搬待办页（TaskTile 平铺）。
  Widget _bottomSection(BuildContext context) {
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
      appBar: AppBar(title: Text(_title)),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '上一期',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _shiftPeriod(-1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: ScheduleSegments(
                      labels: const ['年度', '年', '月', '日'],
                      selected: _granularity,
                      onChanged: (i) {
                        if (i == _granularity) return;
                        setState(() => _granularity = i);
                        reload();
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: '下一期',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _shiftPeriod(1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                  TextButton(onPressed: _goToday, child: const Text('今天')),
                  IconButton(
                    tooltip: '上跳',
                    visualDensity: VisualDensity.compact,
                    onPressed: _granularity > 0 ? _jumpUp : null,
                    icon: const Icon(Icons.arrow_upward),
                  ),
                ],
              ),
            ),
          ),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else ...[
            Expanded(flex: 3, child: _ganttView()),
            if (_granularity != 0) _bottomSection(context),
          ],
        ],
      ),
    );
  }
}

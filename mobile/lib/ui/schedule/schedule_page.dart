import 'package:flutter/material.dart';

import '../../models/task.dart';
import '../../services/database.dart';
import '../../services/date_ranges.dart';
import '../../services/undo_service.dart';
import '../tasks/task_editor.dart';
import 'day_view.dart';
import 'month_view.dart';
import 'schedule_shared.dart';
import 'year_view.dart';

/// 日程页（设计 §2，应用首屏）：年/月/日三粒度视图 + 顶部控制条。
///
/// 通过 GlobalKey<SchedulePageState> 暴露 [SchedulePageState.reload]，
/// 供壳层切页时刷新（与其他页一致）。
class SchedulePage extends StatefulWidget {
  const SchedulePage({super.key});

  @override
  State<SchedulePage> createState() => SchedulePageState();
}

class SchedulePageState extends State<SchedulePage> {
  /// 0=年 1=月 2=日
  int _granularity = 0;
  late int _year;
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

  /// 当前视图的展示范围（月视图取覆盖当月的完整周网格）。
  (int, int) get _range {
    switch (_granularity) {
      case 1:
        final first = DateTime(_year, _month);
        final start = DateTime(
            first.year, first.month, first.day - first.weekday % 7);
        final last = DateTime(_year, _month + 1, 0);
        final end =
            DateTime(last.year, last.month, last.day + (7 - last.weekday % 7));
        return (start.millisecondsSinceEpoch, end.millisecondsSinceEpoch);
      case 2:
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

  void _showUndoSnack(String label) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(label),
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
        undo: () => db.updateTask(task),
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
    await db.insertTask(task);
    UndoService.instance.register(
      label: '已新建',
      undo: () => db.deleteTasks([task.id]),
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

  void _drillToMonth(int month) {
    setState(() {
      _month = month;
      _granularity = 1;
    });
    reload();
  }

  void _drillToDay(DateTime day) {
    setState(() {
      _day = DateTime(day.year, day.month, day.day);
      _year = day.year;
      _month = day.month;
      _granularity = 2;
    });
    reload();
  }

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
          _year += delta;
        case 1:
          final d = DateTime(_year, _month + delta);
          _year = d.year;
          _month = d.month;
        case 2:
          _day = DateTime(_day.year, _day.month, _day.day + delta);
          _year = _day.year;
          _month = _day.month;
      }
    });
    reload();
  }

  /// AppBar 标题（设计 §2，v2.1）：不显示"日程"，显示当前粒度的时间尺度。
  String get _title {
    switch (_granularity) {
      case 1:
        return '$_year年$_month月';
      case 2:
        const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
        return '${_day.year}年${_day.month}月${_day.day}日'
            '（${weekdays[_day.weekday - 1]}）';
      default:
        return '$_year年';
    }
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
                      labels: const ['年', '月', '日'],
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
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : switch (_granularity) {
                    1 => MonthView(
                        key: ValueKey('m-$_year-$_month'),
                        year: _year,
                        month: _month,
                        tasks: _tasks,
                        onDayTap: _drillToDay,
                        onTaskTap: _editTask,
                        onTaskMoved: _moveTask,
                        onBlankLongPress: (day) => _createTask(
                          seedStartAt: DateTime(day.year, day.month, day.day, 9)
                              .millisecondsSinceEpoch,
                          seedKind: TaskKind.point,
                        ),
                      ),
                    2 => DayView(
                        key: ValueKey('d-$_day'),
                        day: _day,
                        tasks: _tasks,
                        onTaskTap: _editTask,
                        onTaskMoved: _moveTask,
                        onBlankLongPress: (ms) => _createTask(
                          seedStartAt: ms,
                          seedKind: TaskKind.point,
                        ),
                      ),
                    _ => YearView(
                        key: ValueKey('y-$_year'),
                        year: _year,
                        tasks: _tasks,
                        onMonthTap: _drillToMonth,
                        onTaskTap: _editTask,
                        onTaskMoved: _moveTask,
                        onBlankLongPress: (month) => _createTask(
                          seedStartAt: DateTime(_year, month, 1, 9)
                              .millisecondsSinceEpoch,
                          seedKind: TaskKind.range,
                        ),
                      ),
                  },
          ),
        ],
      ),
    );
  }
}

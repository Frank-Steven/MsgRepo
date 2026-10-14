import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/task.dart';
import 'layout.dart';
import 'schedule_shared.dart';

enum _DragMode { move, resizeStart, resizeEnd }

/// 月视图（v2.3）：纵向无限滚动，按月分段；每月固定 6 行周网格
///（星期日→星期六，前后月溢出日淡显），月与月按周衔接。
/// 日格内沿用 v2.2 的节点/线段标记；选中-调整（仅已选中的任务可拖拽，
/// 未选中时任务上的拖动手势落入列表滚动）；点空白格：有选中=取消，
/// 无选中=下钻日视图。
class MonthView extends StatefulWidget {
  final List<Task> tasks;
  final String? selectedTaskId;
  final ValueChanged<Task?> onTaskSelected;

  /// 点空白日格下钻：参数为该日 0 点时间戳。
  final ValueChanged<int> onDayTap;

  /// 拖拽落库回调：(原任务, 新 startAt, 新 endAt)。
  final void Function(Task task, int newStartMs, int? newEndMs) onTaskMoved;

  /// 长按空白日格：参数为该日 0 点时间戳。
  final ValueChanged<int> onBlankLongPress;
  final void Function(int startMs, int endMs) onVisibleWindowChanged;
  final ValueChanged<DateTime> onCenterChanged;

  const MonthView({
    super.key,
    required this.tasks,
    required this.selectedTaskId,
    required this.onTaskSelected,
    required this.onDayTap,
    required this.onTaskMoved,
    required this.onBlankLongPress,
    required this.onVisibleWindowChanged,
    required this.onCenterChanged,
  });

  @override
  State<MonthView> createState() => MonthViewState();
}

class MonthViewState extends State<MonthView> {
  static const int _baseYear = 2000; // item 0 = 2000 年 1 月
  static const double _labelH = 24;
  static const double _cellH = 56;
  static const int _rows = 6; // 固定 6 行保证 itemExtent 恒定

  static double get _itemExtent =>
      _labelH + _MonthLayout.headerH + _rows * _cellH;

  // 初始偏移直接落在当前月（item index 空间 = unit + infiniteScrollOffset），
  // 避免首帧渲染到 item 0（基准年之前的远古月份）再跳变的闪烁。
  late final ScrollController _ctrl = ScrollController(
      initialScrollOffset:
          itemIndexForUnit(_monthIndexOf(DateTime.now())) * _itemExtent);
  Timer? _pulseTimer;
  DateTime? _pulseDay; // 「现在」脉冲：今天所在格

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) scrollToNow();
    });
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  int _monthIndexOf(DateTime d) => (d.year - _baseYear) * 12 + d.month - 1;
  DateTime _monthOfIndex(int i) => DateTime(_baseYear + i ~/ 12, i % 12 + 1);

  void _reportWindow() {
    if (!_ctrl.hasClients) return;
    // _ctrl.offset 处于 item index 空间（含 infiniteScrollOffset 大偏移），
    // 映射回月份单位序号必须经 unitIndexForItem。
    final firstItem = (_ctrl.offset / _itemExtent).floor();
    final count =
        (_ctrl.position.viewportDimension / _itemExtent).ceil() + 1;
    final a = _monthOfIndex(unitIndexForItem(firstItem));
    final b = DateTime(a.year, a.month + count);
    widget.onVisibleWindowChanged(
        a.millisecondsSinceEpoch, b.millisecondsSinceEpoch);
    final centerItem =
        ((_ctrl.offset + _ctrl.position.viewportDimension / 2) / _itemExtent)
            .floor();
    final c = _monthOfIndex(unitIndexForItem(centerItem));
    widget.onCenterChanged(DateTime(c.year, c.month, 15));
  }

  void scrollToNow() {
    final now = DateTime.now();
    _jumpToMonth(_monthIndexOf(now));
    _pulseTimer?.cancel();
    setState(() => _pulseDay = DateTime(now.year, now.month, now.day));
    _pulseTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _pulseDay = null);
    });
  }

  void scrollTo(DateTime target) => _jumpToMonth(_monthIndexOf(target));

  void scrollToTask(Task t) {
    final s = t.startAt;
    if (s == null) return;
    _jumpToMonth(_monthIndexOf(DateTime.fromMillisecondsSinceEpoch(s)));
  }

  void _jumpToMonth(int index) {
    if (!_ctrl.hasClients) return;
    final max = _ctrl.position.maxScrollExtent;
    // 顶对齐目标月分段（标签行在顶部），不再留 -8 残影
    _ctrl.jumpTo(
        (itemIndexForUnit(index) * _itemExtent).clamp(0.0, max));
    _reportWindow();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, cons) {
      return NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n is ScrollUpdateNotification || n is ScrollEndNotification) {
            _reportWindow();
          }
          return false;
        },
        child: ListView.builder(
          controller: _ctrl,
          itemExtent: _itemExtent,
          itemBuilder: (context, i) {
            final m = _monthOfIndex(i - infiniteScrollOffset);
            return _MonthItem(
              key: ValueKey('${m.year}-${m.month}'),
              year: m.year,
              month: m.month,
              width: cons.maxWidth,
              cellH: _cellH,
              rows: _rows,
              tasks: widget.tasks,
              selectedTaskId: widget.selectedTaskId,
              pulseDay: _pulseDay,
              onTaskSelected: widget.onTaskSelected,
              onDayTap: widget.onDayTap,
              onTaskMoved: widget.onTaskMoved,
              onBlankLongPress: widget.onBlankLongPress,
            );
          },
        ),
      );
    });
  }
}

class _MonthItem extends StatefulWidget {
  final int year;
  final int month;
  final double width;
  final double cellH;
  final int rows;
  final List<Task> tasks;
  final String? selectedTaskId;
  final DateTime? pulseDay;
  final ValueChanged<Task?> onTaskSelected;
  final ValueChanged<int> onDayTap;
  final void Function(Task task, int newStartMs, int? newEndMs) onTaskMoved;
  final ValueChanged<int> onBlankLongPress;

  const _MonthItem({
    super.key,
    required this.year,
    required this.month,
    required this.width,
    required this.cellH,
    required this.rows,
    required this.tasks,
    required this.selectedTaskId,
    required this.pulseDay,
    required this.onTaskSelected,
    required this.onDayTap,
    required this.onTaskMoved,
    required this.onBlankLongPress,
  });

  @override
  State<_MonthItem> createState() => _MonthItemState();
}

class _MonthItemState extends State<_MonthItem> {
  Task? _dragOriginal;
  _DragMode? _dragMode;
  int _deltaStart = 0; // 预览位移（天）
  int _deltaEnd = 0;
  double _grabOffset = 0;
  int _origStartIdx = 0;
  int _origEndIdx = 0;

  late final DateTime _gridStart;

  @override
  void initState() {
    super.initState();
    final first = DateTime(widget.year, widget.month);
    _gridStart =
        DateTime(first.year, first.month, first.day - first.weekday % 7);
  }

  (int, int) get _gridRange {
    final end = DateTime(_gridStart.year, _gridStart.month,
        _gridStart.day + widget.rows * 7);
    return (_gridStart.millisecondsSinceEpoch, end.millisecondsSinceEpoch);
  }

  List<Task> _displayTasks() {
    final (startMs, endMs) = _gridRange;
    final list = <Task>[];
    for (final t in widget.tasks) {
      var d = displayOccurrence(t, startMs, endMs);
      if (d == null) continue;
      if (_dragOriginal?.id == t.id) {
        final dv = d;
        d = dv.copyWith(
          startAt: () =>
              dv.startAt! + Duration(days: _deltaStart).inMilliseconds,
          endAt: () => dv.endAt == null
              ? null
              : dv.endAt! + Duration(days: _deltaEnd).inMilliseconds,
        );
      }
      list.add(d);
    }
    return list;
  }

  void _onTapUp(TapUpDetails d, _MonthLayout layout) {
    final hit = layout.hitTest(d.localPosition);
    if (hit != null) {
      final original = layout.originals[hit.taskId];
      if (original != null) widget.onTaskSelected(original);
      return;
    }
    if (widget.selectedTaskId != null) {
      widget.onTaskSelected(null); // 有选中时点空白 = 取消选中
      return;
    }
    final day = layout.dayAt(d.localPosition);
    if (day != null) {
      widget.onDayTap(day.millisecondsSinceEpoch);
    }
  }

  void _onLongPress(LongPressStartDetails d, _MonthLayout layout) {
    if (layout.hitTest(d.localPosition) != null) return;
    final day = layout.dayAt(d.localPosition);
    if (day != null) {
      widget.onBlankLongPress(day.millisecondsSinceEpoch);
    }
  }

  void _onPanStart(DragStartDetails d, _MonthLayout layout) {
    final hit = layout.hitTest(d.localPosition);
    // 选中-调整：仅已选中的任务可拖拽，否则手势落入列表滚动
    if (hit == null || hit.taskId != widget.selectedTaskId) return;
    final original = layout.originals[hit.taskId];
    final span = layout.spanOf(hit.taskId);
    if (original == null || span == null) return;
    setState(() {
      _dragOriginal = original;
      _dragMode = hit.mode;
      _deltaStart = 0;
      _deltaEnd = 0;
      _origStartIdx = span.$1;
      _origEndIdx = span.$2;
      _grabOffset = layout.dayPosAt(d.localPosition) - span.$1;
    });
  }

  void _onPanUpdate(DragUpdateDetails d, _MonthLayout layout) {
    if (_dragOriginal == null) return;
    final dp = layout.dayPosAt(d.localPosition);
    final span = _origEndIdx - _origStartIdx;
    final maxIdx = widget.rows * 7 - 1;
    setState(() {
      switch (_dragMode!) {
        case _DragMode.move:
          final start0 = (dp - _grabOffset).round().clamp(0, maxIdx - span);
          _deltaStart = start0 - _origStartIdx;
          _deltaEnd = _deltaStart;
        case _DragMode.resizeStart:
          final start0 = dp.round().clamp(0, _origEndIdx);
          _deltaStart = start0 - _origStartIdx;
        case _DragMode.resizeEnd:
          final end0 = dp.round().clamp(_origStartIdx, maxIdx);
          _deltaEnd = end0 - _origEndIdx;
      }
    });
  }

  void _onPanEnd() {
    final original = _dragOriginal;
    final mode = _dragMode;
    if (original != null &&
        mode != null &&
        (_deltaStart != 0 || _deltaEnd != 0)) {
      const dayMs = Duration.millisecondsPerDay;
      final newStart = original.startAt! +
          (mode == _DragMode.resizeEnd ? 0 : _deltaStart) * dayMs;
      final oe = original.endAt;
      final newEnd = oe == null
          ? null
          : oe +
              (mode == _DragMode.resizeStart
                      ? 0
                      : mode == _DragMode.resizeEnd
                          ? _deltaEnd
                          : _deltaStart) *
                  dayMs;
      widget.onTaskMoved(original, newStart, newEnd);
    }
    setState(() {
      _dragOriginal = null;
      _dragMode = null;
      _deltaStart = 0;
      _deltaEnd = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final gridH = _MonthLayout.headerH + widget.rows * widget.cellH;
    final display = _displayTasks();
    final layout = _MonthLayout.build(
      width: widget.width,
      height: gridH,
      year: widget.year,
      month: widget.month,
      gridStart: _gridStart,
      rows: widget.rows,
      tasks: display,
      originals: {for (final t in widget.tasks) t.id: t},
      scheme: scheme,
      now: DateTime.now(),
      selectedTaskId: widget.selectedTaskId,
      pulseDay: widget.pulseDay,
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // 固定高度标签行：Padding+Text 的实际高度随设备字体缩放浮动，
      // 不定高会把 Column 顶出 itemExtent 造成 1px 溢出
      SizedBox(
        height: MonthViewState._labelH,
        child: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('${widget.year} 年 ${widget.month} 月',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant)),
          ),
        ),
      ),
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _onTapUp(d, layout),
        onLongPressStart: (d) => _onLongPress(d, layout),
        onPanStart: (d) => _onPanStart(d, layout),
        onPanUpdate: (d) => _onPanUpdate(d, layout),
        onPanEnd: (_) => _onPanEnd(),
        onPanCancel: _onPanEnd,
        child: CustomPaint(
          size: Size(widget.width, gridH),
          painter: _MonthPainter(layout),
        ),
      ),
    ]);
  }
}

class _HitRegion {
  final Rect rect;
  final String taskId;
  final _DragMode mode;

  const _HitRegion(this.rect, this.taskId, this.mode);
}

/// 单个日格内的一段标记（点或线段的一段）。
class _CellMark {
  final Task task;
  final int cellIndex;
  final double x1;
  final double x2;
  final double y;
  final Color color;
  final bool isPoint;
  final bool isStartCell;
  final bool isEndCell;

  /// 子任务（父任务在同视图可见时与父同 y，画更小节点/更细线段）。
  final bool isSubtask;

  const _CellMark({
    required this.task,
    required this.cellIndex,
    required this.x1,
    required this.x2,
    required this.y,
    required this.color,
    required this.isPoint,
    required this.isStartCell,
    required this.isEndCell,
    this.isSubtask = false,
  });
}

class _MonthLayout {
  static const headerH = 20.0;
  static const _marksTop = 17.0;
  static const _laneDy = 7.0;

  final double width;
  final double height;
  final double cellW;
  final double cellH;
  final int rows;
  final DateTime gridStart;
  final int year;
  final int month;
  final List<_CellMark> marks;
  final List<_HitRegion> hitRegions;
  final Map<String, Task> originals;
  final Map<String, (int, int)> spans; // taskId -> (startCellIdx, endCellIdx)
  final ColorScheme scheme;
  final DateTime now;
  final String? selectedTaskId;
  final DateTime? pulseDay;

  _MonthLayout._({
    required this.width,
    required this.height,
    required this.cellW,
    required this.cellH,
    required this.rows,
    required this.gridStart,
    required this.year,
    required this.month,
    required this.marks,
    required this.hitRegions,
    required this.originals,
    required this.spans,
    required this.scheme,
    required this.now,
    required this.selectedTaskId,
    required this.pulseDay,
  });

  static const _priorities = [
    TaskPriority.important,
    TaskPriority.normal,
    TaskPriority.minor,
  ];

  static double _fracOfDay(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return (d.hour * 60 + d.minute) / 1440.0;
  }

  static _MonthLayout build({
    required double width,
    required double height,
    required int year,
    required int month,
    required DateTime gridStart,
    required int rows,
    required List<Task> tasks,
    required Map<String, Task> originals,
    required ColorScheme scheme,
    required DateTime now,
    String? selectedTaskId,
    DateTime? pulseDay,
  }) {
    final cellW = width / 7;
    final cellH = (height - headerH) / rows;
    final cellCount = rows * 7;

    Rect cellRect(int i) => Rect.fromLTWH(
        (i % 7) * cellW, headerH + (i ~/ 7) * cellH, cellW, cellH);

    final marks = <_CellMark>[];
    final hitRegions = <_HitRegion>[];
    final spans = <String, (int, int)>{};

    for (final t in tasks) {
      final s = t.startAt;
      if (s == null) continue;
      final e = t.endAt;
      final laneIdx = _priorities.contains(t.priority)
          ? _priorities.indexOf(t.priority)
          : 1;
      // 子任务：父任务在本视图可见时用父的泳道 y（设计 §3）
      final pid = t.parentId;
      final parent = pid == null ? null : originals[pid];
      final isSubtask = parent != null;
      final parentLaneIdx = parent == null
          ? laneIdx
          : (_priorities.contains(parent.priority)
              ? _priorities.indexOf(parent.priority)
              : 1);
      final color = priorityColor(scheme, t.priority);
      var firstCell = -1;
      var lastCell = -1;
      for (var i = 0; i < cellCount; i++) {
        final cellStart = DateTime(gridStart.year, gridStart.month,
                gridStart.day + i)
            .millisecondsSinceEpoch;
        final cellEnd = cellStart + Duration.millisecondsPerDay;
        final isPoint = e == null;
        final hit = isPoint
            ? (s >= cellStart && s < cellEnd)
            : (s < cellEnd && e > cellStart);
        if (!hit) continue;
        if (firstCell < 0) firstCell = i;
        lastCell = i;
        final rect = cellRect(i);
        final y = rect.top + _marksTop + parentLaneIdx * _laneDy + 3;
        final x1 = isPoint || s >= cellStart
            ? rect.left + 6 + (rect.width - 12) * _fracOfDay(s)
            : rect.left;
        final x2 = isPoint
            ? x1
            : (e < cellEnd
                ? rect.left + 6 + (rect.width - 12) * _fracOfDay(e)
                : rect.right);
        marks.add(_CellMark(
          task: t,
          cellIndex: i,
          x1: x1,
          x2: x2,
          y: y,
          color: color,
          isPoint: isPoint,
          isStartCell: i == firstCell,
          isEndCell: false, // 先占位，循环结束后统一修正
          isSubtask: isSubtask,
        ));
      }
      if (firstCell >= 0) {
        spans[t.id] = (firstCell, lastCell);
        // 修正末格标记
        for (var i = 0; i < marks.length; i++) {
          if (marks[i].task.id == t.id && marks[i].cellIndex == lastCell) {
            marks[i] = _CellMark(
              task: marks[i].task,
              cellIndex: marks[i].cellIndex,
              x1: marks[i].x1,
              x2: marks[i].x2,
              y: marks[i].y,
              color: marks[i].color,
              isPoint: marks[i].isPoint,
              isStartCell: marks[i].isStartCell,
              isEndCell: true,
              isSubtask: marks[i].isSubtask,
            );
          }
        }
      }
    }

    // 命中区域：子任务在前（与父同 y 叠加时优先命中子任务）
    for (final m in [
      ...marks.where((x) => x.isSubtask),
      ...marks.where((x) => !x.isSubtask)
    ]) {
      if (m.isPoint) {
        hitRegions.add(_HitRegion(
            Rect.fromCircle(center: Offset(m.x1, m.y), radius: 10),
            m.task.id,
            _DragMode.move));
      } else {
        if (m.isEndCell) {
          hitRegions.add(_HitRegion(
              Rect.fromCircle(center: Offset(m.x2, m.y), radius: 9),
              m.task.id,
              _DragMode.resizeEnd));
        }
        if (m.isStartCell) {
          hitRegions.add(_HitRegion(
              Rect.fromCircle(center: Offset(m.x1, m.y), radius: 9),
              m.task.id,
              _DragMode.resizeStart));
        }
        hitRegions.add(_HitRegion(
            Rect.fromLTRB(m.x1, m.y - 6, m.x2, m.y + 6),
            m.task.id,
            _DragMode.move));
      }
    }

    return _MonthLayout._(
      width: width,
      height: height,
      cellW: cellW,
      cellH: cellH,
      rows: rows,
      gridStart: gridStart,
      year: year,
      month: month,
      marks: marks,
      hitRegions: hitRegions,
      originals: originals,
      spans: spans,
      scheme: scheme,
      now: now,
      selectedTaskId: selectedTaskId,
      pulseDay: pulseDay,
    );
  }

  (int, int)? spanOf(String taskId) => spans[taskId];

  _HitRegion? hitTest(Offset p) {
    for (final r in hitRegions) {
      if (r.rect.contains(p)) return r;
    }
    return null;
  }

  /// 位置对应的日格日期；在网格外返回 null。
  DateTime? dayAt(Offset p) {
    if (p.dy < headerH) return null;
    final col = (p.dx / cellW).floor();
    final row = ((p.dy - headerH) / cellH).floor();
    if (col < 0 || col > 6 || row < 0 || row >= rows) return null;
    return DateTime(
        gridStart.year, gridStart.month, gridStart.day + row * 7 + col);
  }

  /// 位置对应的连续日坐标（0 起，含日内小数），拖拽吸附取整用。
  double dayPosAt(Offset p) {
    final col = (p.dx / cellW).floor().clamp(0, 6);
    final fracX = (p.dx / cellW - col).clamp(0.0, 1.0);
    final row = ((p.dy - headerH) / cellH).floor().clamp(0, rows - 1);
    return row * 7 + col + fracX;
  }
}

class _MonthPainter extends CustomPainter {
  final _MonthLayout layout;

  _MonthPainter(this.layout);

  @override
  void paint(Canvas canvas, Size size) {
    final scheme = layout.scheme;
    const weekdays = ['日', '一', '二', '三', '四', '五', '六'];
    final headerStyle =
        TextStyle(fontSize: 11, color: scheme.onSurfaceVariant);
    for (var i = 0; i < 7; i++) {
      final tp = TextPainter(
        text: TextSpan(text: weekdays[i], style: headerStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
          canvas, Offset((i + 0.5) * layout.cellW - tp.width / 2, 4));
    }

    final today =
        DateTime(layout.now.year, layout.now.month, layout.now.day);
    final dateStyle = TextStyle(fontSize: 11, color: scheme.onSurface);
    final outsideStyle = TextStyle(
        fontSize: 11,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.5));
    final gridLine = Paint()
      ..color = scheme.outlineVariant.withValues(alpha: 0.5)
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;

    final pulse = layout.pulseDay;
    for (var i = 0; i < layout.rows * 7; i++) {
      final rect = Rect.fromLTWH(
          (i % 7) * layout.cellW,
          _MonthLayout.headerH + (i ~/ 7) * layout.cellH,
          layout.cellW,
          layout.cellH);
      final day = DateTime(layout.gridStart.year, layout.gridStart.month,
          layout.gridStart.day + i);
      final isToday = day == today;
      final isPulse = pulse != null && day == pulse;
      if (isPulse) {
        canvas.drawRect(
            rect, Paint()..color = scheme.primary.withValues(alpha: 0.15));
      } else if (isToday) {
        canvas.drawRect(
            rect.deflate(1),
            Paint()
              ..color = scheme.primaryContainer.withValues(alpha: 0.45));
      }
      canvas.drawRect(rect, gridLine);
      if (isPulse) {
        canvas.drawRect(
            rect,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2
              ..color = scheme.primary.withValues(alpha: 0.7));
      }
      final tp = TextPainter(
        text: TextSpan(
          text: '${day.day}',
          style: (day.month == layout.month ? dateStyle : outsideStyle)
              .copyWith(
            color: isToday ? scheme.primary : null,
            fontWeight: isToday ? FontWeight.w700 : null,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(rect.left + 4, rect.top + 2));
    }

    for (final m in layout.marks) {
      final done = m.task.status == TaskStatus.done;
      final color = m.color.withValues(alpha: done ? doneTaskOpacity : 1.0);
      final r = m.isSubtask ? 2.0 : 3.0;
      final selected = m.task.id == layout.selectedTaskId;
      if (m.isPoint) {
        if (selected) {
          canvas.drawCircle(
              Offset(m.x1, m.y),
              r + 3,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.5
                ..color = scheme.primary);
        }
        canvas.drawCircle(Offset(m.x1, m.y), r, Paint()..color = color);
      } else {
        if (selected) {
          canvas.drawLine(
            Offset(m.x1, m.y),
            Offset(m.x2, m.y),
            Paint()
              ..color = scheme.primary.withValues(alpha: 0.5)
              ..strokeWidth = m.isSubtask ? 5.5 : 7
              ..strokeCap = StrokeCap.round,
          );
        }
        canvas.drawLine(
          Offset(m.x1, m.y),
          Offset(m.x2, m.y),
          Paint()
            ..color = color
            ..strokeWidth = m.isSubtask ? 1.5 : 3
            ..strokeCap = StrokeCap.round,
        );
        if (m.isStartCell) {
          canvas.drawCircle(Offset(m.x1, m.y), r, Paint()..color = color);
        }
        if (m.isEndCell) {
          canvas.drawCircle(Offset(m.x2, m.y), r, Paint()..color = color);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_MonthPainter oldDelegate) => true;
}

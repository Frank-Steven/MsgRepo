import 'package:flutter/material.dart';

import '../../models/task.dart';
import 'schedule_shared.dart';

enum _DragMode { move, resizeStart, resizeEnd }

/// 月视图（设计 §2.2）：4-6 行周网格（星期日→星期六），日格内沿用
/// 节点/线段（高度受限只画节点，名称层省略），跨日任务画跨格线段。
class MonthView extends StatefulWidget {
  final int year;
  final int month;
  final List<Task> tasks;
  final ValueChanged<DateTime> onDayTap;
  final ValueChanged<Task> onTaskTap;

  /// 拖拽落库回调：(原任务, 新 startAt, 新 endAt)。
  final void Function(Task task, int newStartMs, int? newEndMs) onTaskMoved;
  final ValueChanged<DateTime> onBlankLongPress;

  const MonthView({
    super.key,
    required this.year,
    required this.month,
    required this.tasks,
    required this.onDayTap,
    required this.onTaskTap,
    required this.onTaskMoved,
    required this.onBlankLongPress,
  });

  @override
  State<MonthView> createState() => _MonthViewState();
}

class _MonthViewState extends State<MonthView> {
  Task? _dragOriginal;
  _DragMode? _dragMode;
  int _deltaStart = 0; // 预览位移（天）
  int _deltaEnd = 0;
  double _grabOffset = 0;
  int _origStartIdx = 0;
  int _origEndIdx = 0;

  late final DateTime _gridStart;
  late final int _rows;

  (int, int) get _gridRange {
    final end = DateTime(_gridStart.year, _gridStart.month,
        _gridStart.day + _rows * 7);
    return (_gridStart.millisecondsSinceEpoch, end.millisecondsSinceEpoch);
  }

  @override
  void initState() {
    super.initState();
    final first = DateTime(widget.year, widget.month);
    _gridStart =
        DateTime(first.year, first.month, first.day - first.weekday % 7);
    final last = DateTime(widget.year, widget.month + 1, 0);
    _rows = ((first.day - 1 + first.weekday % 7) + last.day + 6) ~/ 7;
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
      if (original != null) widget.onTaskTap(original);
      return;
    }
    final day = layout.dayAt(d.localPosition);
    if (day != null) widget.onDayTap(day);
  }

  void _onLongPress(LongPressStartDetails d, _MonthLayout layout) {
    if (layout.hitTest(d.localPosition) != null) return;
    final day = layout.dayAt(d.localPosition);
    if (day != null) widget.onBlankLongPress(day);
  }

  void _onPanStart(DragStartDetails d, _MonthLayout layout) {
    final hit = layout.hitTest(d.localPosition);
    if (hit == null) return;
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
    final maxIdx = _rows * 7 - 1;
    setState(() {
      switch (_dragMode!) {
        case _DragMode.move:
          final start0 = (dp - _grabOffset)
              .round()
              .clamp(0, maxIdx - span);
          _deltaStart = start0 - _origStartIdx;
          _deltaEnd = _deltaStart;
        case _DragMode.resizeStart:
          // v2.2 取消跨度钳制：只受网格界与本端点次序约束
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
    final display = _displayTasks();
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = _MonthLayout.build(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          year: widget.year,
          month: widget.month,
          gridStart: _gridStart,
          rows: _rows,
          tasks: display,
          originals: {for (final t in widget.tasks) t.id: t},
          scheme: scheme,
          now: DateTime.now(),
        );
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _onTapUp(d, layout),
          onLongPressStart: (d) => _onLongPress(d, layout),
          onPanStart: (d) => _onPanStart(d, layout),
          onPanUpdate: (d) => _onPanUpdate(d, layout),
          onPanEnd: (_) => _onPanEnd(),
          onPanCancel: _onPanEnd,
          child: CustomPaint(
            size: Size(constraints.maxWidth, constraints.maxHeight),
            painter: _MonthPainter(layout),
          ),
        );
      },
    );
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
    for (final m in [...marks.where((x) => x.isSubtask), ...marks.where((x) => !x.isSubtask)]) {
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
      tp.paint(canvas,
          Offset((i + 0.5) * layout.cellW - tp.width / 2, 4));
    }

    final today = DateTime(
        layout.now.year, layout.now.month, layout.now.day);
    final dateStyle = TextStyle(fontSize: 11, color: scheme.onSurface);
    final outsideStyle =
        TextStyle(fontSize: 11, color: scheme.onSurfaceVariant.withValues(alpha: 0.5));
    final gridLine = Paint()
      ..color = scheme.outlineVariant.withValues(alpha: 0.5)
      ..strokeWidth = 0.5;

    for (var i = 0; i < layout.rows * 7; i++) {
      final rect = Rect.fromLTWH((i % 7) * layout.cellW,
          _MonthLayout.headerH + (i ~/ 7) * layout.cellH, layout.cellW, layout.cellH);
      canvas.drawRect(rect, gridLine..style = PaintingStyle.stroke);
      final day = DateTime(layout.gridStart.year, layout.gridStart.month,
          layout.gridStart.day + i);
      final isToday = day == today;
      if (isToday) {
        canvas.drawRect(
            rect.deflate(1),
            Paint()
              ..color = scheme.primaryContainer.withValues(alpha: 0.45));
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
      if (m.isPoint) {
        canvas.drawCircle(Offset(m.x1, m.y), r, Paint()..color = color);
      } else {
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

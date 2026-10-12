import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/task.dart';
import 'layout.dart';
import 'schedule_shared.dart';

enum _DragMode { move, resizeStart, resizeEnd }

/// 日视图（设计 §2.3）：横轴 00:00-24:00，捏合缩放比例尺
/// （最宽到每 5 分钟一个节点），名称层在甘特上方独立区域 45° 斜排。
///
/// 手势合一在一个 scale 识别器里：落在任务上是拖拽（5 分钟吸附），
/// 落在空白是平移/捏合缩放，避免与横向滚动手势互相抢占。
class DayView extends StatefulWidget {
  final DateTime day;
  final List<Task> tasks;
  final ValueChanged<Task> onTaskTap;

  /// 拖拽落库回调：(原任务, 新 startAt, 新 endAt)。
  final void Function(Task task, int newStartMs, int? newEndMs) onTaskMoved;

  /// 长按空白：参数为该时刻的时间戳（5 分钟吸附）。
  final ValueChanged<int> onBlankLongPress;

  const DayView({
    super.key,
    required this.day,
    required this.tasks,
    required this.onTaskTap,
    required this.onTaskMoved,
    required this.onBlankLongPress,
  });

  @override
  State<DayView> createState() => _DayViewState();
}

class _DayViewState extends State<DayView> {
  static const _nodeSpacingPx = 14.0;

  /// 当前比例尺：多少分钟一个节点（5 = 最宽）。
  double _mpn = 30;
  double _scrollX = 0;
  double _startMpn = 30;
  double _startScrollX = 0;
  double _startFocalX = 0;

  Task? _dragOriginal;
  _DragMode? _dragMode;
  double _deltaMin = 0; // 预览位移（分钟，已按 5 分钟吸附）
  double _origStartMin = 0;
  double _origEndMin = 0;

  Timer? _nowTimer;

  double get _ppm => _nodeSpacingPx / _mpn;

  DateTime get _dayStart =>
      DateTime(widget.day.year, widget.day.month, widget.day.day);

  (int, int) get _dayRange => (
        _dayStart.millisecondsSinceEpoch,
        _dayStart.millisecondsSinceEpoch + Duration.millisecondsPerDay,
      );

  @override
  void initState() {
    super.initState();
    // 当前时间竖线每分钟重绘
    _nowTimer =
        Timer.periodic(const Duration(minutes: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _nowTimer?.cancel();
    super.dispose();
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  List<Task> _displayTasks() {
    final (startMs, endMs) = _dayRange;
    final list = <Task>[];
    for (final t in widget.tasks) {
      var d = displayOccurrence(t, startMs, endMs);
      if (d == null) continue;
      if (_dragOriginal?.id == t.id) {
        final deltaMs = (_deltaMin * 60000).round();
        final dv = d;
        d = dv.copyWith(
          startAt: () =>
              dv.startAt! + (_dragMode == _DragMode.resizeEnd ? 0 : deltaMs),
          endAt: () => dv.endAt == null
              ? null
              : dv.endAt! + (_dragMode == _DragMode.resizeStart ? 0 : deltaMs),
        );
      }
      list.add(d);
    }
    return list;
  }

  void _onScaleStart(ScaleStartDetails d, _DayLayout layout) {
    final hit = layout.hitTest(d.localFocalPoint);
    _startFocalX = d.localFocalPoint.dx;
    _startMpn = _mpn;
    _startScrollX = _scrollX;
    if (hit != null) {
      final original = layout.originals[hit.taskId];
      final span = layout.spanOf(hit.taskId);
      if (original != null && span != null) {
        setState(() {
          _dragOriginal = original;
          _dragMode = hit.mode;
          _deltaMin = 0;
          _origStartMin = span.$1;
          _origEndMin = span.$2;
        });
      }
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d, _DayLayout layout) {
    if (_dragOriginal != null) {
      final raw = (d.localFocalPoint.dx - _startFocalX) / _ppm;
      final snapped = (raw / 5).round() * 5.0;
      setState(() {
        switch (_dragMode!) {
          case _DragMode.move:
            final span = _origEndMin - _origStartMin;
            _deltaMin =
                snapped.clamp(-_origStartMin, 1440 - span - _origStartMin);
          case _DragMode.resizeStart:
            _deltaMin =
                snapped.clamp(-_origStartMin, _origEndMin - _origStartMin - 5);
          case _DragMode.resizeEnd:
            _deltaMin =
                snapped.clamp(_origStartMin - _origEndMin + 5, 1440 - _origEndMin);
        }
      });
      return;
    }
    setState(() {
      _scrollX = (_startScrollX - (d.localFocalPoint.dx - _startFocalX))
          .clamp(0.0, math.max(0.0, layout.contentW - layout.viewW));
      _mpn = (_startMpn / d.scale).clamp(5.0, 60.0);
    });
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final original = _dragOriginal;
    final mode = _dragMode;
    if (original != null && mode != null && _deltaMin != 0) {
      final deltaMs = (_deltaMin * 60000).round();
      final newStart = original.startAt! +
          (mode == _DragMode.resizeEnd ? 0 : deltaMs);
      final oe = original.endAt;
      final newEnd =
          oe == null ? null : oe + (mode == _DragMode.resizeStart ? 0 : deltaMs);
      widget.onTaskMoved(original, newStart, newEnd);
    }
    setState(() {
      _dragOriginal = null;
      _dragMode = null;
      _deltaMin = 0;
    });
  }

  void _onTapUp(TapUpDetails d, _DayLayout layout) {
    final hit = layout.hitTest(d.localPosition);
    if (hit != null) {
      final original = layout.originals[hit.taskId];
      if (original != null) widget.onTaskTap(original);
    }
  }

  void _onLongPress(LongPressStartDetails d, _DayLayout layout) {
    if (layout.hitTest(d.localPosition) != null) return;
    final minute = ((d.localPosition.dx + _scrollX) / _ppm / 5).round() * 5;
    if (minute < 0 || minute > 1435) return;
    widget.onBlankLongPress(
        _dayStart.millisecondsSinceEpoch + minute * 60000);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final nameStyle = TextStyle(fontSize: 11, color: scheme.onSurface);
    double measure(String title) => (TextPainter(
          text: TextSpan(text: title, style: nameStyle),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout())
            .width;
    final display = _displayTasks();
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = _DayLayout.build(
          viewW: constraints.maxWidth,
          viewH: constraints.maxHeight,
          day: _dayStart,
          tasks: display,
          originals: {for (final t in widget.tasks) t.id: t},
          ppm: _ppm,
          scrollX: _scrollX,
          mpn: _mpn,
          scheme: scheme,
          nameStyle: nameStyle,
          measure: measure,
          now: DateTime.now(),
        );
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (d) => _onScaleStart(d, layout),
          onScaleUpdate: (d) => _onScaleUpdate(d, layout),
          onScaleEnd: _onScaleEnd,
          onTapUp: (d) => _onTapUp(d, layout),
          onLongPressStart: (d) => _onLongPress(d, layout),
          child: ClipRect(
            child: CustomPaint(
              size: Size(constraints.maxWidth, constraints.maxHeight),
              painter: _DayPainter(layout),
            ),
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

class _DayItem {
  final Task task;
  final double x1; // 画布坐标（已减 scrollX）
  final double x2;
  final double y;
  final Color color;
  final bool isPoint;
  final bool startInDay;
  final bool endInDay;

  const _DayItem({
    required this.task,
    required this.x1,
    required this.x2,
    required this.y,
    required this.color,
    required this.isPoint,
    required this.startInDay,
    required this.endInDay,
  });
}

class _DayLayout {
  static const headerH = 18.0;
  static const laneH = 40.0;
  static const nameLayerH = 100.0;

  final double viewW;
  final double viewH;
  final double contentW;
  final double ppm;
  final double scrollX;
  final double mpn;
  final double namesH; // 0 = 名称层整体隐藏
  final DateTime day;
  final List<_DayItem> items;
  final Map<String, DayNameSlot> nameSlots;
  final List<_HitRegion> hitRegions;
  final Map<String, Task> originals;
  final Map<String, (double, double)> spans; // taskId -> (startMin, endMin)
  final ColorScheme scheme;
  final TextStyle nameStyle;
  final double nowMin; // <0 = 展示的不是今天

  _DayLayout._({
    required this.viewW,
    required this.viewH,
    required this.contentW,
    required this.ppm,
    required this.scrollX,
    required this.mpn,
    required this.namesH,
    required this.day,
    required this.items,
    required this.nameSlots,
    required this.hitRegions,
    required this.originals,
    required this.spans,
    required this.scheme,
    required this.nameStyle,
    required this.nowMin,
  });

  static const _priorities = [
    TaskPriority.important,
    TaskPriority.normal,
    TaskPriority.minor,
  ];

  static _DayLayout build({
    required double viewW,
    required double viewH,
    required DateTime day,
    required List<Task> tasks,
    required Map<String, Task> originals,
    required double ppm,
    required double scrollX,
    required double mpn,
    required ColorScheme scheme,
    required TextStyle nameStyle,
    required double Function(String) measure,
    required DateTime now,
  }) {
    final dayStartMs = day.millisecondsSinceEpoch;
    final contentW = 1440 * ppm;

    // 名称空位：把任务钳制到当天后交给纯函数分配
    final clamped = <Task>[];
    for (final t in tasks) {
      final s = t.startAt;
      if (s == null) continue;
      final cs = math.max(s, dayStartMs);
      final ce =
          t.endAt == null ? null : math.min(t.endAt!, dayStartMs + 86400000);
      clamped.add(t.copyWith(startAt: () => cs, endAt: () => ce));
    }
    final slots = assignDayNames(clamped,
        minutesPerNode: mpn, measureText: measure);
    final nameSlots = {for (final s in slots) s.taskId: s};
    final anyVisible = slots.any((e) => e.visible);
    final namesH = anyVisible ? nameLayerH : 0.0;

    double laneY(int laneIdx) =>
        namesH + headerH + laneIdx * laneH + laneH / 2;

    final items = <_DayItem>[];
    final hitRegions = <_HitRegion>[];
    final spans = <String, (double, double)>{};
    for (final t in clamped) {
      final s = t.startAt!;
      final e = t.endAt;
      final laneIdx = _priorities.contains(t.priority)
          ? _priorities.indexOf(t.priority)
          : 1;
      final startMin = (s - dayStartMs) / 60000.0;
      final endMin = e == null ? startMin : (e - dayStartMs) / 60000.0;
      spans[t.id] = (startMin, endMin);
      final x1 = startMin * ppm - scrollX;
      final x2 = e == null ? x1 : endMin * ppm - scrollX;
      items.add(_DayItem(
        task: t,
        x1: x1,
        x2: x2,
        y: laneY(laneIdx),
        color: priorityColor(scheme, t.priority),
        isPoint: e == null,
        startInDay: s >= dayStartMs,
        endInDay: e == null || e <= dayStartMs + 86400000,
      ));
    }
    for (final it in items) {
      if (it.isPoint) {
        hitRegions.add(_HitRegion(
            Rect.fromCircle(center: Offset(it.x1, it.y), radius: 12),
            it.task.id,
            _DragMode.move));
      } else {
        if (it.endInDay) {
          hitRegions.add(_HitRegion(
              Rect.fromCircle(center: Offset(it.x2, it.y), radius: 10),
              it.task.id,
              _DragMode.resizeEnd));
        }
        if (it.startInDay) {
          hitRegions.add(_HitRegion(
              Rect.fromCircle(center: Offset(it.x1, it.y), radius: 10),
              it.task.id,
              _DragMode.resizeStart));
        }
        hitRegions.add(_HitRegion(
            Rect.fromLTRB(it.x1, it.y - 8, it.x2, it.y + 8),
            it.task.id,
            _DragMode.move));
      }
    }

    final isToday = day.year == now.year &&
        day.month == now.month &&
        day.day == now.day;
    return _DayLayout._(
      viewW: viewW,
      viewH: viewH,
      contentW: contentW,
      ppm: ppm,
      scrollX: scrollX,
      mpn: mpn,
      namesH: namesH,
      day: day,
      items: items,
      nameSlots: nameSlots,
      hitRegions: hitRegions,
      originals: originals,
      spans: spans,
      scheme: scheme,
      nameStyle: nameStyle,
      nowMin: isToday ? now.hour * 60 + now.minute + now.second / 60.0 : -1,
    );
  }

  (double, double)? spanOf(String taskId) => spans[taskId];

  _HitRegion? hitTest(Offset p) {
    for (final r in hitRegions) {
      if (r.rect.contains(p)) return r;
    }
    return null;
  }
}

class _DayPainter extends CustomPainter {
  final _DayLayout layout;

  _DayPainter(this.layout);

  @override
  void paint(Canvas canvas, Size size) {
    final scheme = layout.scheme;
    final ppm = layout.ppm;
    final scrollX = layout.scrollX;
    final top = layout.namesH;
    final ganttTop = top + _DayLayout.headerH;

    // 泳道底色
    for (var i = 0; i < 3; i++) {
      canvas.drawRect(
        Rect.fromLTWH(0, ganttTop + i * _DayLayout.laneH, size.width,
            _DayLayout.laneH),
        Paint()
          ..color = priorityColor(scheme, _DayLayout._priorities[i])
              .withValues(alpha: 0.05),
      );
    }

    // 刻度：每小时竖格线 + 标签；每 30 分钟一个刻度点（只画可视范围）
    final labelStyle =
        TextStyle(fontSize: 10, color: scheme.onSurfaceVariant);
    final firstHour = math.max(0, (scrollX / ppm / 60).floor());
    final lastHour = math.min(24, ((scrollX + size.width) / ppm / 60).ceil());
    final gridPaint = Paint()
      ..color = scheme.outlineVariant.withValues(alpha: 0.6)
      ..strokeWidth = 0.5;
    for (var h = firstHour; h <= lastHour; h++) {
      final x = h * 60 * ppm - scrollX;
      canvas.drawLine(
          Offset(x, top), Offset(x, size.height), gridPaint);
      final tp = TextPainter(
        text: TextSpan(text: '$h:00', style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x + 2, top + 3));
    }
    final firstTick = math.max(0, (scrollX / ppm / 30).floor());
    final lastTick = math.min(48, ((scrollX + size.width) / ppm / 30).ceil());
    final tickPaint = Paint()..color = scheme.onSurfaceVariant;
    for (var t = firstTick; t <= lastTick; t++) {
      final x = t * 30 * ppm - scrollX;
      canvas.drawCircle(
          Offset(x, ganttTop - 4), 1.5, tickPaint);
    }

    // 任务：时间点=节点；时间段=带断点方块的线段
    for (final it in layout.items) {
      if (it.x2 < -40 || it.x1 > size.width + 40) continue; // 裁剪
      final done = it.task.status == TaskStatus.done;
      final color = it.color.withValues(alpha: done ? doneTaskOpacity : 1.0);
      if (it.isPoint) {
        canvas.drawCircle(Offset(it.x1, it.y), 5, Paint()..color = color);
      } else {
        canvas.drawLine(
          Offset(it.x1, it.y),
          Offset(it.x2, it.y),
          Paint()
            ..color = color
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round,
        );
        if (it.startInDay) {
          _drawBreak(canvas, it.x1, it.y, color);
        }
        if (it.endInDay) {
          _drawBreak(canvas, it.x2, it.y, color);
        }
      }
    }

    // 名称层：45° 斜文本带 + 垂直虚线
    if (layout.namesH > 0) {
      final dashPaint = Paint()
        ..color = scheme.onSurfaceVariant.withValues(alpha: 0.7)
        ..strokeWidth = 1;
      for (final it in layout.items) {
        final slot = layout.nameSlots[it.task.id];
        if (slot == null || !slot.visible) continue;
        final anchorX = slot.centerMinutes * ppm - scrollX;
        if (anchorX < -100 || anchorX > size.width + 100) continue;
        // 虚线：从文本带起点垂直向下连到节点/线段
        var dy = layout.namesH - 6.0;
        while (dy < it.y - 8) {
          canvas.drawLine(
              Offset(anchorX, dy), Offset(anchorX, dy + 3), dashPaint);
          dy += 6;
        }
        final done = it.task.status == TaskStatus.done;
        final tp = TextPainter(
          text: TextSpan(
            text: it.task.title,
            style: layout.nameStyle.copyWith(
              decoration: done ? TextDecoration.lineThrough : null,
              color: done
                  ? scheme.onSurface.withValues(alpha: doneTaskOpacity)
                  : null,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        canvas.save();
        canvas.translate(anchorX, layout.namesH - 4);
        canvas.rotate(-math.pi / 4);
        tp.paint(canvas, Offset(3, -tp.height + 2));
        canvas.restore();
      }
    }

    // 当前时间高亮竖线
    if (layout.nowMin >= 0) {
      final x = layout.nowMin * ppm - scrollX;
      if (x >= 0 && x <= size.width) {
        canvas.drawLine(
          Offset(x, top),
          Offset(x, size.height),
          Paint()
            ..color = scheme.primary
            ..strokeWidth = 1.5,
        );
      }
    }
  }

  /// 时间段端点的断点方块。
  void _drawBreak(Canvas canvas, double x, double y, Color color) {
    canvas.drawRect(
      Rect.fromCenter(center: Offset(x, y), width: 8, height: 8),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_DayPainter oldDelegate) => true;
}

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/task.dart';
import 'layout.dart';
import 'schedule_shared.dart';

enum _DragMode { move, resizeStart, resizeEnd }

/// 日视图（设计 §2.3，v2.3 修订）：横轴为**连续时间轴**（双向无限滚动，
/// 滚过 24:00 无缝进入次日，跨日午夜画日期分隔线并标注新日期），
/// 坐标以 2000-01-01 本地零点起算的绝对分钟数为基准；比例尺捏合缩放
/// 无级跟手（双指焦点对应的时间点为锚）。
///
/// 选中-调整（v2.3 §13-6）：点按任务（节点/线段/名称）出现描边选中态，
/// 仅选中任务可拖拽调时间（5 分钟吸附，可跨日）；点按空白取消选中；
/// 未选中时手势全部落入平移/缩放（横向滚动优先）。
/// 名称层（v2.3 §13-7）：贪心放置，纯碰撞决定可见性，无比例尺阈值。
class DayView extends StatefulWidget {
  final List<Task> tasks;

  /// 选中任务 id（选中态描边 + 拖拽使能）。
  final String? selectedTaskId;

  /// 点按任务 = 选中；点按空白 = 取消选中（null）。
  final ValueChanged<Task?> onTaskSelected;

  /// 拖拽落库回调：(原任务, 新 startAt, 新 endAt)。
  final void Function(Task task, int newStartMs, int? newEndMs) onTaskMoved;

  /// 长按空白：参数为该时刻的时间戳（5 分钟吸附）。
  final ValueChanged<int> onBlankLongPress;

  /// 可视时间窗变化（父级按窗口加载任务）。
  final void Function(int startMs, int endMs) onVisibleWindowChanged;

  /// 可视中心变化（父级更新标题/期移基准）。
  final ValueChanged<DateTime> onCenterChanged;

  const DayView({
    super.key,
    required this.tasks,
    required this.selectedTaskId,
    required this.onTaskSelected,
    required this.onTaskMoved,
    required this.onBlankLongPress,
    required this.onVisibleWindowChanged,
    required this.onCenterChanged,
  });

  @override
  State<DayView> createState() => DayViewState();
}

class DayViewState extends State<DayView> {
  /// 缩放范围：最小 = 24h 恰好铺满可视宽，最大 = 每 5 分钟 48dp。
  static const _maxPpm = 48.0 / 5;

  /// 绝对分钟基准：2000-01-01 本地零点。
  static final _epochMs = DateTime(2000).millisecondsSinceEpoch;

  /// 实际可滚动范围：2000-01-01 ~ 2100-01-01（双向“无限”的实际边界）。
  static final _maxMin =
      (DateTime(2100).millisecondsSinceEpoch - _epochMs) / 60000.0;

  /// 当前比例尺（px/分钟）；null = 未初始化，首帧定位到当前时刻。
  double? _ppm;
  double _scrollMin = 0; // 左边缘的绝对分钟数
  bool _positioned = false;
  double _viewW = 0;
  double _startPpm = 0;
  double _startScrollMin = 0;
  double _startFocalX = 0;

  Task? _dragOriginal;
  _DragMode? _dragMode;
  double _deltaMin = 0; // 预览位移（分钟，已按 5 分钟吸附）
  double _origStartMin = 0;
  double _origEndMin = 0;

  Timer? _nowTimer;

  /// 「现在」按钮脉冲高亮的目标时刻（绝对分钟），1.5 秒后恢复。
  double? _pulseMin;
  Timer? _pulseTimer;

  double get _nowMin =>
      (DateTime.now().millisecondsSinceEpoch - _epochMs) / 60000.0;

  @override
  void initState() {
    super.initState();
    _nowTimer = Timer.periodic(const Duration(minutes: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _nowTimer?.cancel();
    _pulseTimer?.cancel();
    super.dispose();
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  // ---- 供父级调用的定位方法 ----

  /// 滚动到当前时刻并居中，短暂脉冲高亮（设计 §13-10）。
  void scrollToNow() {
    final ppm = _ppm ?? (_viewW > 0 ? _viewW / 1440 : 1.0);
    setState(() {
      _scrollMin = (_nowMin - _viewW / (2 * ppm)).clamp(0.0, _maxMin);
      _positioned = true;
      _pulseMin = _nowMin;
    });
    _pulseTimer?.cancel();
    _pulseTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _pulseMin = null);
    });
    _reportWindow();
    widget.onCenterChanged(DateTime.now());
  }

  /// 滚动到指定时间点并居中（期移箭头用）。
  void scrollTo(DateTime anchor) {
    final ppm = _ppm ?? 1.0;
    final min = (anchor.millisecondsSinceEpoch - _epochMs) / 60000.0;
    setState(() {
      _scrollMin = (min - _viewW / (2 * ppm)).clamp(0.0, _maxMin);
      _positioned = true;
    });
    _reportWindow();
  }

  /// 滚动到任务并使其居中（详情面板跳转用）。
  void scrollToTask(Task t) {
    final s = t.startAt;
    if (s == null) return;
    final ppm = _ppm ?? 1.0;
    final mid = (s - _epochMs) / 60000.0 +
        (t.endAt == null ? 0 : (t.endAt! - s) / 120000.0);
    setState(() {
      _scrollMin = (mid - _viewW / (2 * ppm)).clamp(0.0, _maxMin);
      _positioned = true;
    });
    _reportWindow();
  }

  void _reportWindow() {
    if (_viewW <= 0 || _ppm == null) return;
    const marginMin = 2 * 1440.0;
    final startMs = ((_scrollMin - marginMin) * 60000 + _epochMs).round();
    final endMs =
        ((_scrollMin + _viewW / _ppm! + marginMin) * 60000 + _epochMs).round();
    widget.onVisibleWindowChanged(startMs, endMs);
    final centerMs =
        ((_scrollMin + _viewW / (2 * _ppm!)) * 60000 + _epochMs).round();
    widget.onCenterChanged(DateTime.fromMillisecondsSinceEpoch(centerMs));
  }

  List<Task> _displayTasks() {
    final list = <Task>[];
    for (final t in widget.tasks) {
      if (t.startAt == null) continue;
      var d = t;
      if (_dragOriginal?.id == t.id) {
        final deltaMs = (_deltaMin * 60000).round();
        d = t.copyWith(
          startAt: () =>
              t.startAt! + (_dragMode == _DragMode.resizeEnd ? 0 : deltaMs),
          endAt: () => t.endAt == null
              ? null
              : t.endAt! + (_dragMode == _DragMode.resizeStart ? 0 : deltaMs),
        );
      }
      list.add(d);
    }
    return list;
  }

  void _onScaleStart(ScaleStartDetails d, _DayLayout layout) {
    final hit = layout.hitTest(d.localFocalPoint);
    _startFocalX = d.localFocalPoint.dx;
    _startPpm = layout.ppm;
    _startScrollMin = _scrollMin;
    // 仅选中任务可拖拽（v2.3 选中-调整）
    if (hit != null && hit.taskId == widget.selectedTaskId) {
      final original = layout.originals[hit.taskId];
      final span = layout.spans[hit.taskId];
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
      final raw = (d.localFocalPoint.dx - _startFocalX) / layout.ppm;
      final snapped = (raw / 5).round() * 5.0;
      setState(() {
        switch (_dragMode!) {
          case _DragMode.move:
            _deltaMin = snapped;
          case _DragMode.resizeStart:
            _deltaMin =
                snapped.clamp(double.negativeInfinity, _origEndMin - _origStartMin - 5);
          case _DragMode.resizeEnd:
            _deltaMin = snapped.clamp(
                _origStartMin - _origEndMin + 5, double.infinity);
        }
      });
      return;
    }
    // 平移 + 无级缩放，以双指焦点对应的时间点为锚（焦点下时间不动）
    final minPpm = layout.viewW / 1440;
    final newPpm = (_startPpm * d.scale).clamp(minPpm, _maxPpm);
    final focalMin = _startScrollMin + _startFocalX / _startPpm;
    setState(() {
      _ppm = newPpm;
      _scrollMin =
          (focalMin - d.localFocalPoint.dx / newPpm).clamp(0.0, _maxMin);
    });
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final original = _dragOriginal;
    final mode = _dragMode;
    if (original != null && mode != null && _deltaMin != 0) {
      final deltaMs = (_deltaMin * 60000).round();
      final newStart =
          original.startAt! + (mode == _DragMode.resizeEnd ? 0 : deltaMs);
      final oe = original.endAt;
      final newEnd = oe == null
          ? null
          : oe + (mode == _DragMode.resizeStart ? 0 : deltaMs);
      widget.onTaskMoved(original, newStart, newEnd);
    }
    if (_dragOriginal == null) _reportWindow();
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
      if (original != null) widget.onTaskSelected(original);
    } else {
      widget.onTaskSelected(null);
    }
  }

  void _onLongPress(LongPressStartDetails d, _DayLayout layout) {
    if (layout.hitTest(d.localPosition) != null) return;
    final min = ((_scrollMin + d.localPosition.dx / layout.ppm) / 5).round() * 5;
    widget.onBlankLongPress((_epochMs + min * 60000).round());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final nameStyle = TextStyle(fontSize: 11, color: scheme.onSurface);
    final measureCache = <String, double>{};
    double measure(String title) => measureCache.putIfAbsent(
        title,
        () => (TextPainter(
              text: TextSpan(text: title, style: nameStyle),
              textDirection: TextDirection.ltr,
              maxLines: 1,
            )..layout())
            .width);
    final display = _displayTasks();
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewW = constraints.maxWidth;
        final minPpm = constraints.maxWidth / 1440;
        // _ppm 必须在此初始化：_reportWindow 依赖它，若保持 null
        // 则 onCenterChanged/onVisibleWindowChanged 永不上报（标题与内容脱节）
        _ppm = (_ppm ?? minPpm).clamp(minPpm, _maxPpm);
        final ppm = _ppm!;
        if (!_positioned) {
          // 首帧：当前时刻居中
          _scrollMin = (_nowMin - constraints.maxWidth / (2 * ppm))
              .clamp(0.0, _maxMin);
          _positioned = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => _reportWindow());
        }
        _scrollMin = _scrollMin.clamp(0.0, _maxMin);
        final layout = _DayLayout.build(
          viewW: constraints.maxWidth,
          viewH: constraints.maxHeight,
          tasks: display,
          originals: {for (final t in widget.tasks) t.id: t},
          ppm: ppm,
          scrollMin: _scrollMin,
          epochMs: _epochMs,
          scheme: scheme,
          nameStyle: nameStyle,
          measure: measure,
          nowMin: _nowMin,
          selectedTaskId: widget.selectedTaskId,
          pulseMin: _pulseMin,
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
  final double x1; // 画布坐标
  final double x2;
  final double y;
  final Color color;
  final bool isPoint;
  final bool isSubtask;

  const _DayItem({
    required this.task,
    required this.x1,
    required this.x2,
    required this.y,
    required this.color,
    required this.isPoint,
    required this.isSubtask,
  });
}

class _DayLayout {
  /// 刻度带高度：容纳斜 45° 向上的时间标注 + 跨日日期标注。
  static const headerH = 44.0;
  static const laneH = 40.0;
  static const nameLayerH = 100.0;

  final double viewW;
  final double viewH;
  final double ppm;
  final double scrollMin;
  final int epochMs;
  final double namesH; // 0 = 名称层无可见名称
  final int majorTickMin;
  final int? minorTickMin;
  final int labelStride;
  final List<_DayItem> items;
  final Map<String, DayNameSlot> nameSlots;
  final List<_HitRegion> hitRegions;
  final Map<String, Task> originals;
  final Map<String, (double, double)> spans; // taskId -> (绝对起, 绝对止)
  final ColorScheme scheme;
  final TextStyle nameStyle;
  final double nowMin;
  final String? selectedTaskId;
  final double? pulseMin;

  _DayLayout._({
    required this.viewW,
    required this.viewH,
    required this.ppm,
    required this.scrollMin,
    required this.epochMs,
    required this.namesH,
    required this.majorTickMin,
    required this.minorTickMin,
    required this.labelStride,
    required this.items,
    required this.nameSlots,
    required this.hitRegions,
    required this.originals,
    required this.spans,
    required this.scheme,
    required this.nameStyle,
    required this.nowMin,
    required this.selectedTaskId,
    required this.pulseMin,
  });

  static const _priorities = [
    TaskPriority.important,
    TaskPriority.normal,
    TaskPriority.minor,
  ];

  static _DayLayout build({
    required double viewW,
    required double viewH,
    required List<Task> tasks,
    required Map<String, Task> originals,
    required double ppm,
    required double scrollMin,
    required int epochMs,
    required ColorScheme scheme,
    required TextStyle nameStyle,
    required double Function(String) measure,
    required double nowMin,
    required String? selectedTaskId,
    required double? pulseMin,
  }) {
    final (majorTickMin, minorTickMin, labelStride) = dayTickInterval(ppm);

    double xOf(double absMin) => (absMin - scrollMin) * ppm;

    // 名称空位：贪心放置（v2.3），轴 = 绝对分钟
    final slots = assignAngledNames(
      tasks,
      axisOf: (t) {
        final startMin = (t.startAt! - epochMs) / 60000.0;
        final endMin = t.endAt == null
            ? startMin
            : math.max(startMin, (t.endAt! - epochMs) / 60000.0);
        return (startMin, endMin);
      },
      axisPerPx: 1 / ppm,
      anchorStep: 5,
      measureText: measure,
    );
    final nameSlots = {for (final s in slots) s.taskId: s};
    final namesH = slots.any((e) => e.visible) ? nameLayerH : 0.0;

    double laneY(int laneIdx) =>
        namesH + headerH + laneIdx * laneH + laneH / 2;

    final items = <_DayItem>[];
    final hitRegions = <_HitRegion>[];
    final spans = <String, (double, double)>{};
    for (final t in tasks) {
      final s = t.startAt!;
      final e = t.endAt;
      var laneIdx = _priorities.contains(t.priority)
          ? _priorities.indexOf(t.priority)
          : 1;
      // 子任务：父任务在本视图可见时用父的泳道 y（设计 §3）
      final pid = t.parentId;
      final parent = pid == null ? null : originals[pid];
      final isSubtask = parent != null;
      if (parent != null) {
        laneIdx = _priorities.contains(parent.priority)
            ? _priorities.indexOf(parent.priority)
            : 1;
      }
      final startMin = (s - epochMs) / 60000.0;
      final endMin = e == null ? startMin : (e - epochMs) / 60000.0;
      spans[t.id] = (startMin, endMin);
      final x1 = xOf(startMin);
      final x2 = e == null ? x1 : xOf(endMin);
      items.add(_DayItem(
        task: t,
        x1: x1,
        x2: x2,
        y: laneY(laneIdx),
        color: priorityColor(scheme, t.priority),
        isPoint: e == null,
        isSubtask: isSubtask,
      ));
    }
    // 命中区域：子任务在前（与父同 y 叠加时优先命中子任务）
    for (final it in [
      ...items.where((i) => i.isSubtask),
      ...items.where((i) => !i.isSubtask)
    ]) {
      if (it.isPoint) {
        hitRegions.add(_HitRegion(
            Rect.fromCircle(center: Offset(it.x1, it.y), radius: 12),
            it.task.id,
            _DragMode.move));
      } else {
        hitRegions.add(_HitRegion(
            Rect.fromCircle(center: Offset(it.x2, it.y), radius: 10),
            it.task.id,
            _DragMode.resizeEnd));
        hitRegions.add(_HitRegion(
            Rect.fromCircle(center: Offset(it.x1, it.y), radius: 10),
            it.task.id,
            _DragMode.resizeStart));
        hitRegions.add(_HitRegion(
            Rect.fromLTRB(it.x1, it.y - 8, it.x2, it.y + 8),
            it.task.id,
            _DragMode.move));
      }
    }
    // 名称命中区域：点按名称 = 选中该任务（设计 §13-6）
    if (namesH > 0) {
      for (final it in items) {
        if (it.isSubtask) continue;
        final slot = nameSlots[it.task.id];
        if (slot == null || !slot.visible) continue;
        final anchorX = xOf(slot.centerMinutes);
        hitRegions.add(_HitRegion(
            Rect.fromLTWH(anchorX - 2, 0, slot.textWidth * 0.7 + 8, namesH),
            it.task.id,
            _DragMode.move));
      }
    }

    return _DayLayout._(
      viewW: viewW,
      viewH: viewH,
      ppm: ppm,
      scrollMin: scrollMin,
      epochMs: epochMs,
      namesH: namesH,
      majorTickMin: majorTickMin,
      minorTickMin: minorTickMin,
      labelStride: labelStride,
      items: items,
      nameSlots: nameSlots,
      hitRegions: hitRegions,
      originals: originals,
      spans: spans,
      scheme: scheme,
      nameStyle: nameStyle,
      nowMin: nowMin,
      selectedTaskId: selectedTaskId,
      pulseMin: pulseMin,
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

  double _xOf(double absMin) => (absMin - layout.scrollMin) * layout.ppm;

  @override
  void paint(Canvas canvas, Size size) {
    final scheme = layout.scheme;
    final top = layout.namesH;
    final ganttTop = top + _DayLayout.headerH;

    _drawTicks(canvas, size, top, ganttTop);

    // 任务：时间点=节点；时间段=带断点方块的线段；子任务画更小节点/更细线；
    // 选中任务加描边（v2.3 选中-调整）
    for (final it in layout.items) {
      if (it.x2 < -40 || it.x1 > size.width + 40) continue; // 裁剪
      final done = it.task.status == TaskStatus.done;
      final color = it.color.withValues(alpha: done ? doneTaskOpacity : 1.0);
      if (it.isPoint) {
        canvas.drawCircle(Offset(it.x1, it.y), it.isSubtask ? 3.5 : 5,
            Paint()..color = color);
      } else {
        canvas.drawLine(
          Offset(it.x1, it.y),
          Offset(it.x2, it.y),
          Paint()
            ..color = color
            ..strokeWidth = it.isSubtask ? 1.5 : 3
            ..strokeCap = StrokeCap.round,
        );
        final breakSize = it.isSubtask ? 5.0 : 8.0;
        _drawBreak(canvas, it.x1, it.y, color, breakSize);
        _drawBreak(canvas, it.x2, it.y, color, breakSize);
      }
      if (it.task.id == layout.selectedTaskId) {
        _drawSelection(canvas, it, scheme);
      }
    }

    // 名称层：45° 斜文本带 + 垂直虚线
    if (layout.namesH > 0) {
      final dashPaint = Paint()
        ..color = scheme.onSurfaceVariant.withValues(alpha: 0.7)
        ..strokeWidth = 1;
      for (final it in layout.items) {
        if (it.isSubtask) continue; // 子任务不显示名称（与父同 y 叠加）
        final slot = layout.nameSlots[it.task.id];
        if (slot == null || !slot.visible) continue;
        final anchorX = _xOf(slot.centerMinutes);
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

    // 「现在」脉冲高亮（1.5 秒）
    final pulseMin = layout.pulseMin;
    if (pulseMin != null) {
      final x = _xOf(pulseMin);
      if (x >= -20 && x <= size.width + 20) {
        canvas.drawRect(
          Rect.fromLTWH(x - 8, top, 16, size.height - top),
          Paint()..color = scheme.primary.withValues(alpha: 0.18),
        );
      }
    }

    // 当前时间竖线
    final nowX = _xOf(layout.nowMin);
    if (nowX >= 0 && nowX <= size.width) {
      canvas.drawLine(
        Offset(nowX, top),
        Offset(nowX, size.height),
        Paint()
          ..color = scheme.primary
          ..strokeWidth = 1.5,
      );
    }
  }

  void _drawSelection(Canvas canvas, _DayItem it, ColorScheme scheme) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = scheme.primary;
    if (it.isPoint) {
      canvas.drawCircle(Offset(it.x1, it.y), 9, paint);
    } else {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(it.x1 - 6, it.y - 9, it.x2 + 6, it.y + 9),
          const Radius.circular(6),
        ),
        paint,
      );
    }
  }

  /// 动态刻度（连续时间轴，v2.3）：主刻度 = 竖格线 + 刻度短线 + 斜 45°
  /// 时间标注；跨日午夜画更强的日期分隔线并标注新日期。
  void _drawTicks(Canvas canvas, Size size, double top, double ganttTop) {
    final scheme = layout.scheme;
    final ppm = layout.ppm;
    final scrollMin = layout.scrollMin;
    final major = layout.majorTickMin;
    final minor = layout.minorTickMin;
    final gridPaint = Paint()
      ..color = scheme.outlineVariant.withValues(alpha: 0.6)
      ..strokeWidth = 0.5;
    final tickPaint = Paint()
      ..color = scheme.onSurfaceVariant
      ..strokeWidth = 1;
    final dayPaint = Paint()
      ..color = scheme.onSurfaceVariant.withValues(alpha: 0.8)
      ..strokeWidth = 1;
    final labelStyle =
        TextStyle(fontSize: 10, color: scheme.onSurfaceVariant);
    final dayLabelStyle =
        TextStyle(fontSize: 11, color: scheme.onSurface);

    final firstMin = scrollMin;
    final lastMin = scrollMin + size.width / ppm;

    // 日期分隔线：每个本地午夜（绝对分钟 % 1440 == 0，epoch 为本地零点）
    var midnight = (firstMin / 1440).floor() * 1440;
    while (midnight <= lastMin) {
      if (midnight >= firstMin) {
        final x = _xOf(midnight.toDouble());
        canvas.drawLine(Offset(x, top), Offset(x, size.height), dayPaint);
        final d = DateTime.fromMillisecondsSinceEpoch(
            layout.epochMs + midnight * 60000);
        final tp = TextPainter(
          text: TextSpan(
              text: '${d.month}月${d.day}日', style: dayLabelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x + 4, top + 2));
      }
      midnight += 1440;
    }

    // 次刻度短线（只画可视范围，落在主刻度上的跳过）
    if (minor != null) {
      final firstMinor = (firstMin / minor).floor();
      final lastMinor = (lastMin / minor).ceil();
      for (var t = firstMinor; t <= lastMinor; t++) {
        if (t * minor % major == 0) continue;
        final x = _xOf(t * minor.toDouble());
        canvas.drawLine(
            Offset(x, ganttTop - 3), Offset(x, ganttTop), tickPaint);
      }
    }

    // 主刻度：竖格线 + 刻度短线 + 斜 45° 标注（过挤按 2 的幂隔档）
    final firstMajor = (firstMin / major).floor();
    final lastMajor = (lastMin / major).ceil();
    for (var t = firstMajor; t <= lastMajor; t++) {
      final minute = t * major;
      final x = _xOf(minute.toDouble());
      canvas.drawLine(Offset(x, top), Offset(x, size.height), gridPaint);
      canvas.drawLine(
          Offset(x, ganttTop - 6), Offset(x, ganttTop), tickPaint);
      if (t % layout.labelStride != 0) continue;
      final d = DateTime.fromMillisecondsSinceEpoch(
          layout.epochMs + minute * 60000);
      final label = '${d.hour}:${_two(d.minute)}';
      final tp = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      // 锚在刻度点，旋转 -45° 向右上延伸
      canvas.save();
      canvas.translate(x + 2, ganttTop - 8);
      canvas.rotate(-math.pi / 4);
      tp.paint(canvas, Offset(2, -tp.height + 1));
      canvas.restore();
    }
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// 时间段端点的断点方块。
  void _drawBreak(Canvas canvas, double x, double y, Color color,
      [double size = 8]) {
    canvas.drawRect(
      Rect.fromCenter(center: Offset(x, y), width: size, height: size),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_DayPainter oldDelegate) => true;
}

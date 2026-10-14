import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/task.dart';
import 'layout.dart';
import 'schedule_shared.dart';

enum _DragMode { move, resizeStart, resizeEnd }

/// 年度视图（设计 §2.1，v2.2）：横向年份轴，窗口为中心年 ±10 年，
/// 横向滚动 + 捏合缩放（刻度档 1/5/10 年），年份标注 -45° 斜向上。
/// 尺度为 yearly 的任务：单年内 = 节点、跨年 = 带端点线段；is_annual 任务
/// 在每年画一个小节点；当前年高亮竖带；点年格下钻该年的年视图。
/// 拖拽粒度 = 年：移动整体平移整数年（保留月日时分），起止端点吸附年界；
/// 无跨度上限（v2.2 取消钳制）。
///
/// 手势合一在一个 scale 识别器里：落在任务上是拖拽，落在空白是平移/缩放。
class YearlyView extends StatefulWidget {
  /// 窗口中心年（窗口 = [centerYear-10, centerYear+10]）。
  final int centerYear;

  /// 已按年度视图尺度过滤的任务（yearly + is_annual）。
  final List<Task> tasks;
  final ValueChanged<Task> onTaskTap;

  /// 拖拽落库回调：(原任务, 新 startAt, 新 endAt)。
  final void Function(Task task, int newStartMs, int? newEndMs) onTaskMoved;

  /// 点按年格空白：下钻该年的年视图。
  final ValueChanged<int> onYearTap;

  const YearlyView({
    super.key,
    required this.centerYear,
    required this.tasks,
    required this.onTaskTap,
    required this.onTaskMoved,
    required this.onYearTap,
  });

  @override
  State<YearlyView> createState() => _YearlyViewState();
}

class _YearlyViewState extends State<YearlyView> {
  /// 缩放范围：最小 = 整个 21 年窗口恰好铺满可视宽（随宽度动态算），
  /// 最大 = 每年 320dp。
  static const _maxPpy = 320.0;

  /// 名称层显示阈值：每年 ≥64dp 才尝试放置（最密刻度档思路）。
  static const _nameThresholdPpy = 64.0;

  int get _windowStart => widget.centerYear - 10;
  static const _spanYears = 21;

  double? _ppy; // null = 未初始化，首帧按窗口铺满可视宽
  double _scrollX = 0;
  double _startPpy = 0;
  double _startScrollX = 0;
  double _startFocalX = 0;

  Task? _dragOriginal;
  _DragMode? _dragMode;
  int _deltaYears = 0; // 预览位移（整数年）
  int _origStartMs = 0;
  int? _origEndMs;

  @override
  void didUpdateWidget(YearlyView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.centerYear != widget.centerYear) {
      // 平移窗口后让中心年回到可视中央
      _scrollX = -1; // 标记：下一帧按中心年居中
    }
  }

  static int _shiftYears(int ms, int dy) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return DateTime(d.year + dy, d.month, d.day, d.hour, d.minute, d.second)
        .millisecondsSinceEpoch;
  }

  List<Task> _displayTasks() {
    if (_dragOriginal == null || _deltaYears == 0) return widget.tasks;
    final list = <Task>[];
    for (final t in widget.tasks) {
      if (t.id == _dragOriginal!.id && !t.isAnnual) {
        // 与 _onScaleEnd 同一套计算：移动 = 整体平移整数年；
        // 起止端点 = 吸附年界
        int? newStart = t.startAt;
        int? newEnd = t.endAt;
        switch (_dragMode!) {
          case _DragMode.move:
            newStart =
                t.startAt == null ? null : _shiftYears(t.startAt!, _deltaYears);
            newEnd = t.endAt == null ? null : _shiftYears(t.endAt!, _deltaYears);
          case _DragMode.resizeStart:
            final ty =
                DateTime.fromMillisecondsSinceEpoch(_origStartMs).year +
                    _deltaYears;
            newStart = DateTime(ty).millisecondsSinceEpoch;
          case _DragMode.resizeEnd:
            final ty = DateTime.fromMillisecondsSinceEpoch(_origEndMs!).year +
                _deltaYears;
            newEnd = DateTime(ty + 1).millisecondsSinceEpoch;
        }
        list.add(t.copyWith(startAt: () => newStart, endAt: () => newEnd));
      } else {
        list.add(t);
      }
    }
    return list;
  }

  void _onScaleStart(ScaleStartDetails d, _YearlyLayout layout) {
    final hit = layout.hitTest(d.localFocalPoint);
    _startFocalX = d.localFocalPoint.dx;
    _startPpy = layout.ppy;
    _startScrollX = _scrollX;
    if (hit != null && !layout.annualIds.contains(hit.taskId)) {
      final original = layout.originals[hit.taskId];
      final span = layout.spans[hit.taskId];
      if (original != null && span != null) {
        setState(() {
          _dragOriginal = original;
          _dragMode = hit.mode;
          _deltaYears = 0;
          _origStartMs = span.$1;
          _origEndMs = span.$2;
        });
      }
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d, _YearlyLayout layout) {
    if (_dragOriginal != null) {
      final rawYears = (d.localFocalPoint.dx - _startFocalX) / layout.ppy;
      final dy = rawYears.round();
      final origStartYear =
          DateTime.fromMillisecondsSinceEpoch(_origStartMs).year;
      final origEndYear = _origEndMs == null
          ? origStartYear
          : DateTime.fromMillisecondsSinceEpoch(_origEndMs!).year;
      setState(() {
        switch (_dragMode!) {
          case _DragMode.move:
            final span = origEndYear - origStartYear;
            _deltaYears = dy.clamp(
                _windowStart - origStartYear,
                _windowStart + _spanYears - 1 - span - origStartYear);
          case _DragMode.resizeStart:
            _deltaYears = dy.clamp(_windowStart - origStartYear,
                origEndYear - origStartYear);
          case _DragMode.resizeEnd:
            _deltaYears = dy.clamp(
                origStartYear - origEndYear,
                _windowStart + _spanYears - origEndYear);
        }
      });
      return;
    }
    // 平移 + 无级缩放，以双指焦点对应的年份为锚（焦点下年份不动）
    final minPpy = layout.viewW / _spanYears;
    final newPpy = (_startPpy * d.scale).clamp(minPpy, _maxPpy);
    final focalYear = (_startScrollX + _startFocalX) / _startPpy;
    final newScrollX = focalYear * newPpy - d.localFocalPoint.dx;
    setState(() {
      _ppy = newPpy;
      _scrollX = newScrollX.clamp(
          0.0, math.max(0.0, _spanYears * newPpy - layout.viewW));
    });
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final original = _dragOriginal;
    final mode = _dragMode;
    if (original != null && mode != null && _deltaYears != 0) {
      final int newStart;
      final int? newEnd;
      switch (mode) {
        case _DragMode.move:
          newStart = _shiftYears(_origStartMs, _deltaYears);
          newEnd =
              _origEndMs == null ? null : _shiftYears(_origEndMs!, _deltaYears);
        case _DragMode.resizeStart:
          // 起点吸附年界（1 月 1 日 00:00）
          final ty = DateTime.fromMillisecondsSinceEpoch(_origStartMs).year +
              _deltaYears;
          newStart = DateTime(ty).millisecondsSinceEpoch;
          newEnd = _origEndMs;
        case _DragMode.resizeEnd:
          // 终点吸附年界（目标年结束 = 下一年 1 月 1 日 00:00，左闭右开）
          final ty = DateTime.fromMillisecondsSinceEpoch(_origEndMs!).year +
              _deltaYears;
          newStart = _origStartMs;
          newEnd = DateTime(ty + 1).millisecondsSinceEpoch;
      }
      widget.onTaskMoved(original, newStart, newEnd);
    }
    setState(() {
      _dragOriginal = null;
      _dragMode = null;
      _deltaYears = 0;
    });
  }

  void _onTapUp(TapUpDetails d, _YearlyLayout layout) {
    final hit = layout.hitTest(d.localPosition);
    if (hit != null) {
      final original = layout.originals[hit.taskId];
      if (original != null) widget.onTaskTap(original);
      return;
    }
    // 空白年格：下钻该年的年视图
    final year =
        _windowStart + ((d.localPosition.dx + _scrollX) / layout.ppy).floor();
    if (year >= _windowStart && year < _windowStart + _spanYears) {
      widget.onYearTap(year);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final display = _displayTasks();
    return LayoutBuilder(
      builder: (context, constraints) {
        final minPpy = constraints.maxWidth / _spanYears;
        final ppy = (_ppy ?? minPpy).clamp(minPpy, _maxPpy);
        var scrollX = _scrollX.clamp(
                0.0, math.max(0.0, _spanYears * ppy - constraints.maxWidth))
            .toDouble();
        if (_scrollX == -1) {
          // 窗口平移后中心年居中
          scrollX = (10.5 * ppy - constraints.maxWidth / 2)
              .clamp(0.0, math.max(0.0, _spanYears * ppy - constraints.maxWidth))
              .toDouble();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _scrollX == -1) setState(() => _scrollX = scrollX);
          });
        }
        final layout = _YearlyLayout.build(
          viewW: constraints.maxWidth,
          viewH: constraints.maxHeight,
          windowStart: _windowStart,
          spanYears: _spanYears,
          tasks: display,
          originals: {for (final t in widget.tasks) t.id: t},
          ppy: ppy,
          scrollX: scrollX,
          scheme: scheme,
          now: DateTime.now(),
        );
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (d) => _onScaleStart(d, layout),
          onScaleUpdate: (d) => _onScaleUpdate(d, layout),
          onScaleEnd: _onScaleEnd,
          onTapUp: (d) => _onTapUp(d, layout),
          child: ClipRect(
            child: CustomPaint(
              size: Size(constraints.maxWidth, constraints.maxHeight),
              painter: _YearlyPainter(layout),
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

class _YearlyItem {
  final Task task;
  final double x1; // 画布坐标（已减 scrollX）
  final double x2;
  final double y;
  final Color color;
  final bool isPoint;
  final bool isSubtask;
  final bool startInWindow;
  final bool endInWindow;

  const _YearlyItem({
    required this.task,
    required this.x1,
    required this.x2,
    required this.y,
    required this.color,
    required this.isPoint,
    required this.isSubtask,
    required this.startInWindow,
    required this.endInWindow,
  });
}

class _AnnualNode {
  final Task task;
  final double x;
  final double y;
  final Color color;

  const _AnnualNode({
    required this.task,
    required this.x,
    required this.y,
    required this.color,
  });
}

class _YearlyLayout {
  static const headerH = 44.0;
  static const nameLayerH = 100.0;
  static const slotH = 18.0;

  final double viewW;
  final double viewH;
  final double ppy;
  final double scrollX;
  final int windowStart;
  final int spanYears;
  final double namesH;
  final List<double> laneHeights; // 每条优先级泳道的高度（随槽位数伸缩）
  final int majorTickYears;
  final int? minorTickYears;
  final int labelStride;
  final List<_YearlyItem> items;
  final List<_AnnualNode> annualNodes;
  final Set<String> annualIds;
  final Map<String, double> nameAnchors; // 可见名称 taskId → 锚点 x（画布坐标）
  final List<_HitRegion> hitRegions;
  final Map<String, Task> originals;
  final Map<String, (int, int?)> spans; // taskId -> (startMs, endMs)
  final ColorScheme scheme;
  final int nowYear;

  _YearlyLayout._({
    required this.viewW,
    required this.viewH,
    required this.ppy,
    required this.scrollX,
    required this.windowStart,
    required this.spanYears,
    required this.namesH,
    required this.laneHeights,
    required this.majorTickYears,
    required this.minorTickYears,
    required this.labelStride,
    required this.items,
    required this.annualNodes,
    required this.annualIds,
    required this.nameAnchors,
    required this.hitRegions,
    required this.originals,
    required this.spans,
    required this.scheme,
    required this.nowYear,
  });

  static const _priorities = [
    TaskPriority.important,
    TaskPriority.normal,
    TaskPriority.minor,
  ];

  /// 毫秒时间戳 → 距窗口起点的年小数（按各年实际长度插值）。
  static double _yearFraction(int ms, int windowStart) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final y0 = DateTime(d.year).millisecondsSinceEpoch;
    final y1 = DateTime(d.year + 1).millisecondsSinceEpoch;
    return d.year - windowStart + (ms - y0) / (y1 - y0);
  }

  static _YearlyLayout build({
    required double viewW,
    required double viewH,
    required int windowStart,
    required int spanYears,
    required List<Task> tasks,
    required Map<String, Task> originals,
    required double ppy,
    required double scrollX,
    required ColorScheme scheme,
    required DateTime now,
  }) {
    final (majorTickYears, minorTickYears, labelStride) =
        yearTickInterval(ppy);
    final winStartMs = DateTime(windowStart).millisecondsSinceEpoch;
    final winEndMs =
        DateTime(windowStart + spanYears).millisecondsSinceEpoch;

    int laneIndexOf(Task t) => _priorities.contains(t.priority)
        ? _priorities.indexOf(t.priority)
        : 1;

    // 非 is_annual 任务：按优先级分泳道，泳道内按年小数区间贪心分槽；
    // 子任务（parent_id 非空）父在窗口内可见时与父同泳道同槽（设计 §3）。
    final laneSlots = List.generate(3, (_) => <List<(double, double)>>[]);
    final slotOf = <String, (int, int)>{}; // taskId -> (lane, slot)
    final regular = tasks.where((t) => !t.isAnnual).toList()
      ..sort((a, b) {
        final c = (a.startAt ?? 0).compareTo(b.startAt ?? 0);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    final subtaskItems = <_YearlyItem>[];
    final items = <_YearlyItem>[];
    final spans = <String, (int, int?)>{};

    _YearlyItem toItem(Task t, int laneIdx, int slot,
        {bool isSubtask = false}) {
      final s = t.startAt!;
      final e = t.endAt;
      spans[t.id] = (s, e);
      final x1 = _yearFraction(s, windowStart) * ppy - scrollX;
      final x2 =
          e == null ? x1 : _yearFraction(e, windowStart) * ppy - scrollX;
      return _YearlyItem(
        task: t,
        x1: x1,
        x2: x2,
        y: double.nan, // 泳道高度确定后回填
        color: priorityColor(scheme, t.priority),
        isPoint: e == null,
        isSubtask: isSubtask,
        startInWindow: s >= winStartMs,
        endInWindow: e == null || e <= winEndMs,
      );
    }

    final pending = <(Task, int, int, bool)>[]; // task, lane, slot, isSubtask
    for (final t in regular) {
      final s = t.startAt;
      if (s == null) continue;
      final e = t.endAt;
      if (s >= winEndMs) continue;
      if (e != null && e <= winStartMs) continue;
      if (e == null && s < winStartMs) continue;
      final lane = laneIndexOf(t);
      final f1 = _yearFraction(s, windowStart);
      final f2 = e == null ? f1 : _yearFraction(e, windowStart);
      final parentId = t.parentId;
      final parentPlace = parentId == null ? null : slotOf[parentId];
      if (parentPlace != null) {
        pending.add((t, parentPlace.$1, parentPlace.$2, true));
        continue;
      }
      final slots = laneSlots[lane];
      var slot = 0;
      while (true) {
        if (slot == slots.length) slots.add([]);
        final clash =
            slots[slot].any((iv) => f1 <= iv.$2 && iv.$1 <= f2);
        if (!clash) {
          slots[slot].add((f1, f2));
          break;
        }
        slot++;
      }
      slotOf[t.id] = (lane, slot);
      pending.add((t, lane, slot, false));
    }

    // 泳道高度：槽位数 * slotH，至少一条槽的高度
    final laneHeights = [
      for (var i = 0; i < 3; i++)
        math.max(1, laneSlots[i].length) * slotH + 16,
    ];

    double laneTop(int laneIdx) {
      var y = headerH.toDouble();
      for (var i = 0; i < laneIdx; i++) {
        y += laneHeights[i];
      }
      return y;
    }

    double itemY(int laneIdx, int slot) =>
        laneTop(laneIdx) + 8 + slot * slotH + slotH / 2;

    // 名称层：每年 ≥64dp 时按 45° 斜文本贪心放置（放不下不显示）
    final allowNames = ppy >= _YearlyViewState._nameThresholdPpy;
    final nameAnchors = <String, double>{};
    final placedU = <(double, double)>[];
    final placedV = <double>[];
    bool nameFits(double anchorPx, double lengthPx) {
      const sqrt2 = math.sqrt2;
      final u0 = anchorPx / sqrt2;
      final u1 = u0 + lengthPx;
      final v = -anchorPx / sqrt2;
      for (var i = 0; i < placedU.length; i++) {
        final (pu0, pu1) = placedU[i];
        if (u1 > pu0 && u0 < pu1 && (v - placedV[i]).abs() < 14) return false;
      }
      return true;
    }

    for (final (t, lane, slot, isSub) in pending) {
      final item = toItem(t, lane, slot, isSubtask: isSub);
      final y = itemY(lane, slot);
      final placed = _YearlyItem(
        task: item.task,
        x1: item.x1,
        x2: item.x2,
        y: y,
        color: item.color,
        isPoint: item.isPoint,
        isSubtask: item.isSubtask,
        startInWindow: item.startInWindow,
        endInWindow: item.endInWindow,
      );
      if (isSub) {
        subtaskItems.add(placed);
      } else {
        items.add(placed);
        if (allowNames) {
          final width = t.title.length * 11.0; // 粗略估算（全角≈字宽）
          final anchor = placed.x1;
          if (width / math.sqrt2 <= nameLayerH - 8 &&
              nameFits(anchor, width)) {
            nameAnchors[t.id] = anchor;
            const sqrt2 = math.sqrt2;
            placedU.add((anchor / sqrt2, anchor / sqrt2 + width));
            placedV.add(-anchor / sqrt2);
          }
        }
      }
    }
    final namesH = nameAnchors.isEmpty ? 0.0 : nameLayerH;
    // 名称层出现时整体下移
    if (namesH > 0) {
      items.addAll(subtaskItems);
      final shifted = [
        for (final it in items)
          _YearlyItem(
            task: it.task,
            x1: it.x1,
            x2: it.x2,
            y: it.y + namesH,
            color: it.color,
            isPoint: it.isPoint,
            isSubtask: it.isSubtask,
            startInWindow: it.startInWindow,
            endInWindow: it.endInWindow,
          )
      ];
      items
        ..clear()
        ..addAll(shifted);
    } else {
      items.addAll(subtaskItems);
    }

    // is_annual：按 startAt 的月日映射到窗口内每年一个小节点（设计 §2.1）
    final annualNodes = <_AnnualNode>[];
    final annualIds = <String>{};
    for (final t in tasks) {
      if (!t.isAnnual || t.startAt == null) continue;
      annualIds.add(t.id);
      final origin = DateTime.fromMillisecondsSinceEpoch(t.startAt!);
      final lane = laneIndexOf(t);
      final y = itemY(lane, 0) + namesH;
      for (var year = windowStart; year < windowStart + spanYears; year++) {
        final occ = DateTime(year, origin.month, origin.day, origin.hour,
            origin.minute, origin.second);
        annualNodes.add(_AnnualNode(
          task: t,
          x: _yearFraction(occ.millisecondsSinceEpoch, windowStart) * ppy -
              scrollX,
          y: y,
          color: priorityColor(scheme, t.priority),
        ));
      }
    }

    // 命中区域：子任务在前（优先命中），端点优先于中段
    final hitRegions = <_HitRegion>[];
    final ordered = [
      ...items.where((i) => i.isSubtask),
      ...items.where((i) => !i.isSubtask),
    ];
    for (final it in ordered) {
      if (it.isPoint) {
        hitRegions.add(_HitRegion(
            Rect.fromCircle(center: Offset(it.x1, it.y), radius: 12),
            it.task.id,
            _DragMode.move));
      } else {
        if (it.endInWindow) {
          hitRegions.add(_HitRegion(
              Rect.fromCircle(center: Offset(it.x2, it.y), radius: 10),
              it.task.id,
              _DragMode.resizeEnd));
        }
        if (it.startInWindow) {
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
    for (final n in annualNodes) {
      hitRegions.add(_HitRegion(
          Rect.fromCircle(center: Offset(n.x, n.y), radius: 10),
          n.task.id,
          _DragMode.move));
    }
    // 名称也可点按进编辑器
    for (final it in items) {
      final anchor = nameAnchors[it.task.id];
      if (anchor == null) continue;
      hitRegions.add(_HitRegion(
          Rect.fromLTWH(anchor - 2, 0, 60, namesH), it.task.id, _DragMode.move));
    }

    return _YearlyLayout._(
      viewW: viewW,
      viewH: viewH,
      ppy: ppy,
      scrollX: scrollX,
      windowStart: windowStart,
      spanYears: spanYears,
      namesH: namesH,
      laneHeights: laneHeights,
      majorTickYears: majorTickYears,
      minorTickYears: minorTickYears,
      labelStride: labelStride,
      items: items,
      annualNodes: annualNodes,
      annualIds: annualIds,
      nameAnchors: nameAnchors,
      hitRegions: hitRegions,
      originals: originals,
      spans: spans,
      scheme: scheme,
      nowYear: now.year,
    );
  }

  _HitRegion? hitTest(Offset p) {
    for (final r in hitRegions) {
      if (r.rect.contains(p)) return r;
    }
    return null;
  }
}

class _YearlyPainter extends CustomPainter {
  final _YearlyLayout layout;

  _YearlyPainter(this.layout);

  @override
  void paint(Canvas canvas, Size size) {
    final scheme = layout.scheme;
    final ppy = layout.ppy;
    final scrollX = layout.scrollX;
    final top = layout.namesH;
    final ganttTop = top + _YearlyLayout.headerH;

    // 当前年高亮竖带
    final nowX = (layout.nowYear - layout.windowStart) * ppy - scrollX;
    if (nowX + ppy >= 0 && nowX <= size.width) {
      canvas.drawRect(
        Rect.fromLTWH(nowX, top, ppy, size.height - top),
        Paint()..color = scheme.primary.withValues(alpha: 0.08),
      );
    }

    // 泳道底色
    var laneTop = ganttTop;
    for (var i = 0; i < 3; i++) {
      canvas.drawRect(
        Rect.fromLTWH(0, laneTop, size.width, layout.laneHeights[i]),
        Paint()
          ..color = priorityColor(scheme, _YearlyLayout._priorities[i])
              .withValues(alpha: 0.05),
      );
      laneTop += layout.laneHeights[i];
    }

    _drawTicks(canvas, size, top, ganttTop);

    // 任务：节点 / 带端点方块的线段；子任务画更小节点/更细线
    for (final it in layout.items) {
      if (it.x2 < -40 || it.x1 > size.width + 40) continue; // 裁剪
      final done = it.task.status == TaskStatus.done;
      final color = it.color.withValues(alpha: done ? doneTaskOpacity : 1.0);
      if (it.isPoint) {
        canvas.drawCircle(
            Offset(it.x1, it.y), it.isSubtask ? 3.5 : 5, Paint()..color = color);
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
        if (it.startInWindow) {
          _drawBreak(canvas, it.x1, it.y, color, breakSize);
        }
        if (it.endInWindow) {
          _drawBreak(canvas, it.x2, it.y, color, breakSize);
        }
      }
    }

    // is_annual 每年一个小节点
    for (final n in layout.annualNodes) {
      if (n.x < -20 || n.x > size.width + 20) continue;
      final done = n.task.status == TaskStatus.done;
      canvas.drawCircle(
        Offset(n.x, n.y),
        3.5,
        Paint()
          ..color = n.color.withValues(alpha: done ? doneTaskOpacity : 1.0),
      );
    }

    // 名称层：45° 斜文本 + 垂直虚线
    if (layout.namesH > 0) {
      final dashPaint = Paint()
        ..color = scheme.onSurfaceVariant.withValues(alpha: 0.7)
        ..strokeWidth = 1;
      for (final it in layout.items) {
        final anchor = layout.nameAnchors[it.task.id];
        if (anchor == null) continue;
        if (anchor < -120 || anchor > size.width + 120) continue;
        var dy = layout.namesH - 6.0;
        while (dy < it.y - 8) {
          canvas.drawLine(
              Offset(anchor, dy), Offset(anchor, dy + 3), dashPaint);
          dy += 6;
        }
        final done = it.task.status == TaskStatus.done;
        final tp = TextPainter(
          text: TextSpan(
            text: it.task.title,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurface
                  .withValues(alpha: done ? doneTaskOpacity : 1.0),
              decoration: done ? TextDecoration.lineThrough : null,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        canvas.save();
        canvas.translate(anchor, layout.namesH - 4);
        canvas.rotate(-math.pi / 4);
        tp.paint(canvas, Offset(3, -tp.height + 2));
        canvas.restore();
      }
    }
  }

  /// 动态刻度（设计 §2.1）：主刻度 = 长竖格线 + 刻度短线 + 斜 -45° 年份标注
  /// （过挤按 2 的幂隔档）；次刻度 = 短刻度线。
  void _drawTicks(Canvas canvas, Size size, double top, double ganttTop) {
    final scheme = layout.scheme;
    final ppy = layout.ppy;
    final scrollX = layout.scrollX;
    final major = layout.majorTickYears;
    final minor = layout.minorTickYears;
    final gridPaint = Paint()
      ..color = scheme.outlineVariant.withValues(alpha: 0.6)
      ..strokeWidth = 0.5;
    final tickPaint = Paint()
      ..color = scheme.onSurfaceVariant
      ..strokeWidth = 1;
    final labelStyle =
        TextStyle(fontSize: 10, color: scheme.onSurfaceVariant);
    final firstYear =
        layout.windowStart + (scrollX / ppy).floor() - 1;
    final lastYear =
        layout.windowStart + ((scrollX + size.width) / ppy).ceil() + 1;

    if (minor != null) {
      final firstMinor = (firstYear - layout.windowStart) ~/ minor * minor;
      for (var o = firstMinor;
          o <= lastYear - layout.windowStart;
          o += minor) {
        if (o < 0 || o % major == 0) continue;
        final x = o * ppy - scrollX;
        canvas.drawLine(
            Offset(x, ganttTop - 3), Offset(x, ganttTop), tickPaint);
      }
    }

    final firstMajor = (firstYear - layout.windowStart) ~/ major * major;
    for (var o = firstMajor; o <= lastYear - layout.windowStart; o += major) {
      if (o < 0) continue;
      final x = o * ppy - scrollX;
      canvas.drawLine(Offset(x, top), Offset(x, size.height), gridPaint);
      canvas.drawLine(
          Offset(x, ganttTop - 6), Offset(x, ganttTop), tickPaint);
      if ((o ~/ major) % layout.labelStride != 0) continue;
      final tp = TextPainter(
        text: TextSpan(
            text: '${layout.windowStart + o}', style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      canvas.save();
      canvas.translate(x + 2, ganttTop - 8);
      canvas.rotate(-math.pi / 4);
      tp.paint(canvas, Offset(2, -tp.height + 1));
      canvas.restore();
    }
  }

  void _drawBreak(
      Canvas canvas, double x, double y, Color color, double size) {
    canvas.drawRect(
      Rect.fromCenter(center: Offset(x, y), width: size, height: size),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_YearlyPainter oldDelegate) => true;
}

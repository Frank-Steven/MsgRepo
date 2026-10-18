import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../models/task.dart';
import 'layout.dart';
import 'schedule_shared.dart';

enum _DragMode { move, resizeStart, resizeEnd }

/// 年度视图（设计 §2.1，v2.3 修订）：横向年份轴**双向无限滚动**
/// （坐标 = 2000 年起算的绝对年小数，初始居中当前年），捏合缩放
/// （焦点锚定），刻度档 1/5/10 年，年份标注 -45° 斜向上。
/// 尺度为 yearly 的任务：单年内 = 节点、跨年 = 带端点线段；当前年高亮竖带。
/// （v2.4：is_annual 逐年节点下线，老 is_annual 任务按普通任务画。）
///
/// 选中-调整（v2.3 §13-6）：点按任务出现描边选中态，仅选中任务可拖拽
/// （移动 = 整数年平移保留月日；起止端点吸附年界；无跨度上限）；
/// 有选中时点空白 = 取消选中，无选中时点空白 = 下钻该年的年视图。
/// 名称层（v2.3 §13-7）：贪心放置，纯碰撞决定可见性。
class YearlyView extends StatefulWidget {
  /// 已按年度视图尺度过滤的任务（yearly，覆盖可视窗口）。
  final List<Task> tasks;
  final String? selectedTaskId;
  final ValueChanged<Task?> onTaskSelected;

  /// 拖拽落库回调：(原任务, 新 startAt, 新 endAt)。
  final void Function(Task task, int newStartMs, int? newEndMs) onTaskMoved;

  /// 点按空白年格（无选中时）：下钻该年的年视图。
  final ValueChanged<int> onYearTap;

  final void Function(int startMs, int endMs) onVisibleWindowChanged;
  final ValueChanged<DateTime> onCenterChanged;

  const YearlyView({
    super.key,
    required this.tasks,
    required this.selectedTaskId,
    required this.onTaskSelected,
    required this.onTaskMoved,
    required this.onYearTap,
    required this.onVisibleWindowChanged,
    required this.onCenterChanged,
  });

  @override
  State<YearlyView> createState() => YearlyViewState();
}

class YearlyViewState extends State<YearlyView>
    with TickerProviderStateMixin {
  /// 缩放范围：最小 = 20 年铺满可视宽，最大 = 每年 320dp。
  static const _maxPpy = 320.0;

  /// 绝对年小数基准（2000-01-01）。
  static const _epochYear = 2000;

  /// 实际可滚动范围：1900 ~ 2200 年。
  static const _minYear = 1900;
  static const _maxYear = 2200;

  double? _ppy; // null = 未初始化，首帧定位到当前年
  double _scrollYf = 0; // 左边缘的绝对年小数
  bool _positioned = false;
  double _viewW = 0;
  double _startPpy = 0;
  double _startScrollYf = 0;
  double _startFocalX = 0;

  Task? _dragOriginal;
  _DragMode? _dragMode;
  int _deltaYears = 0; // 预览位移（整数年）
  int _origStartMs = 0;
  int? _origEndMs;

  /// 「现在」脉冲高亮的目标年，1.5 秒后恢复。
  int? _pulseYear;
  Timer? _pulseTimer;

  /// fling 惯性滚动（v2.4）：水平甩动后按摩擦衰减继续平移。
  AnimationController? _flingCtrl;
  double _flingStartYf = 0;

  void _cancelFling() {
    _flingCtrl?.stop();
    _flingCtrl?.dispose();
    _flingCtrl = null;
  }

  void _startFling(double vxPxPerSec) {
    final ppy = _ppy;
    if (ppy == null || vxPxPerSec.abs() < 120) return; // 低速不惯性
    _cancelFling();
    _flingStartYf = _scrollYf;
    // 模拟值 = 像素位移（正 = 手指向右甩）；scrollYf 反向变化
    final sim = FrictionSimulation(0.09, 0, vxPxPerSec);
    final ctrl = AnimationController.unbounded(vsync: this);
    ctrl.addListener(() {
      final next = _flingStartYf - ctrl.value / ppy;
      if (next <= _minScroll || next >= _maxScroll) {
        // 撞边界即停；value 通知循环里不能就地 dispose 自己，帧末回收
        final c = _flingCtrl;
        if (c != null) {
          _flingCtrl = null;
          c.stop();
          WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
        }
        setState(
            () => _scrollYf = next.clamp(_minScroll, _maxScroll));
        _reportWindow();
        return;
      }
      setState(() => _scrollYf = next);
      _reportOnUnitChange(); // v2.6.1：惯性中标题实时跟随（单位变化才上报）
    });
    ctrl.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        _cancelFling();
        _reportWindow();
      }
    });
    _flingCtrl = ctrl;
    ctrl.animateWith(sim);
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
    _cancelFling();
    super.dispose();
  }

  /// 毫秒时间戳 → 绝对年小数（按各年实际长度插值）。
  static double _yearFraction(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final y0 = DateTime(d.year).millisecondsSinceEpoch;
    final y1 = DateTime(d.year + 1).millisecondsSinceEpoch;
    return d.year - _epochYear + (ms - y0) / (y1 - y0);
  }

  double get _minScroll => _minYear - _epochYear.toDouble();
  double get _maxScroll => _maxYear - _epochYear.toDouble();

  static int _shiftYears(int ms, int dy) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return DateTime(d.year + dy, d.month, d.day, d.hour, d.minute, d.second)
        .millisecondsSinceEpoch;
  }

  // ---- 供父级调用的定位方法 ----

  /// 滚动到当前年并居中，短暂脉冲高亮（设计 §13-10）。
  /// v2.6.1：先停掉进行中的 fling 动画，否则动画下一帧会覆盖定位。
  void scrollToNow() {
    _cancelFling();
    final ppy = _ppy ?? (_viewW > 0 ? _viewW / 20 : 20.0);
    final nowYf = _yearFraction(DateTime.now().millisecondsSinceEpoch);
    setState(() {
      _scrollYf = (nowYf - _viewW / (2 * ppy)).clamp(_minScroll, _maxScroll);
      _positioned = true;
      _pulseYear = DateTime.now().year;
    });
    _pulseTimer?.cancel();
    _pulseTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _pulseYear = null);
    });
    _reportWindow();
    widget.onCenterChanged(DateTime.now());
  }

  /// 滚动到指定年并居中（期移箭头用）。
  void scrollTo(DateTime anchor) {
    _cancelFling();
    final ppy = _ppy ?? 20.0;
    final yf = _yearFraction(anchor.millisecondsSinceEpoch);
    setState(() {
      _scrollYf = (yf - _viewW / (2 * ppy)).clamp(_minScroll, _maxScroll);
      _positioned = true;
    });
    _reportWindow();
  }

  /// 滚动到任务并使其居中（详情面板跳转用）。
  void scrollToTask(Task t) {
    _cancelFling();
    final s = t.startAt;
    if (s == null) return;
    final ppy = _ppy ?? 20.0;
    final f1 = _yearFraction(s);
    final f2 = t.endAt == null ? f1 : _yearFraction(t.endAt!);
    setState(() {
      _scrollYf =
          ((f1 + f2) / 2 - _viewW / (2 * ppy)).clamp(_minScroll, _maxScroll);
      _positioned = true;
    });
    _reportWindow();
  }

  /// 上次上报的（首可视年, 末可视年, 中心年）——滚动/缩放中只在单位
  /// 变化时上报（v2.6.1：标题实时跟随，又不每帧 setState）。
  (int, int, int)? _lastReportKey;

  void _reportOnUnitChange() {
    if (_viewW <= 0 || _ppy == null) return;
    final ppy = _ppy!;
    final key = (
      _scrollYf.floor(),
      (_scrollYf + _viewW / ppy).floor(),
      (_scrollYf + _viewW / (2 * ppy)).floor(),
    );
    if (key != _lastReportKey) _reportWindow();
  }

  void _reportWindow() {
    if (_viewW <= 0 || _ppy == null) return;
    // 精确可视范围（v2.4：加载提前量由父级 _ensureRange 负责，
    // 这里上报的范围同时用于底部面板与随缩放变化的标题）
    final startMs = DateTime(_epochYear + _scrollYf.floor())
        .millisecondsSinceEpoch;
    // 右缘年小数落在的年 = 最后可视年；区间右端 = 其次年 1 月 1 日
    final lastVisYear = _epochYear + (_scrollYf + _viewW / _ppy!).floor();
    final endMs = DateTime(lastVisYear + 1).millisecondsSinceEpoch;
    final centerYf = _scrollYf + _viewW / (2 * _ppy!);
    _lastReportKey = (
      _scrollYf.floor(),
      (_scrollYf + _viewW / _ppy!).floor(),
      centerYf.floor(),
    );
    widget.onVisibleWindowChanged(startMs, endMs);
    widget.onCenterChanged(
        DateTime(_epochYear + centerYf.floor(), 7));
  }

  List<Task> _displayTasks() {
    if (_dragOriginal == null || _deltaYears == 0) return widget.tasks;
    final list = <Task>[];
    for (final t in widget.tasks) {
      if (t.id == _dragOriginal!.id) {
        // 与 _onScaleEnd 同一套计算：移动 = 整体平移整数年；
        // 起止端点 = 吸附年界
        int? newStart = t.startAt;
        int? newEnd = t.endAt;
        switch (_dragMode!) {
          case _DragMode.move:
            newStart =
                t.startAt == null ? null : _shiftYears(t.startAt!, _deltaYears);
            newEnd =
                t.endAt == null ? null : _shiftYears(t.endAt!, _deltaYears);
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
    _cancelFling();
    final hit = layout.hitTest(d.localFocalPoint);
    _startFocalX = d.localFocalPoint.dx;
    _startPpy = layout.ppy;
    _startScrollYf = _scrollYf;
    // 仅选中任务可拖拽（v2.3 选中-调整）
    if (hit != null && hit.taskId == widget.selectedTaskId) {
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
      final dy = ((d.localFocalPoint.dx - _startFocalX) / layout.ppy).round();
      final origStartYear =
          DateTime.fromMillisecondsSinceEpoch(_origStartMs).year;
      final origEndYear = _origEndMs == null
          ? origStartYear
          : DateTime.fromMillisecondsSinceEpoch(_origEndMs!).year;
      setState(() {
        switch (_dragMode!) {
          case _DragMode.move:
            final span = origEndYear - origStartYear;
            _deltaYears = dy.clamp(_minYear - origStartYear,
                _maxYear - 1 - span - origStartYear);
          case _DragMode.resizeStart:
            _deltaYears =
                dy.clamp(_minYear - origStartYear, origEndYear - origStartYear);
          case _DragMode.resizeEnd:
            _deltaYears = dy.clamp(
                origStartYear - origEndYear, _maxYear - origEndYear);
        }
      });
      return;
    }
    // 平移 + 无级缩放，以双指焦点对应的年份为锚（焦点下年份不动）
    final minPpy = layout.viewW / 20;
    final newPpy = (_startPpy * d.scale).clamp(minPpy, _maxPpy);
    final focalYf = _startScrollYf + _startFocalX / _startPpy;
    setState(() {
      _ppy = newPpy;
      _scrollYf = (focalYf - d.localFocalPoint.dx / newPpy)
          .clamp(_minScroll, _maxScroll);
    });
    _reportOnUnitChange(); // v2.6.1：拖动/缩放中标题实时跟随
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
    final wasDragging = _dragOriginal != null;
    setState(() {
      _dragOriginal = null;
      _dragMode = null;
      _deltaYears = 0;
    });
    if (wasDragging) {
      _reportWindow();
    } else {
      // 平移手势结束：带惯性继续滚动（v2.4）
      _startFling(d.velocity.pixelsPerSecond.dx);
      // 低速不触发惯性时 _startFling 直接返回——这里补一次上报，
      // 否则慢拖后标题/底部面板停在旧值（v2.6.1）
      _reportOnUnitChange();
    }
  }

  void _onTapUp(TapUpDetails d, _YearlyLayout layout) {
    final hit = layout.hitTest(d.localPosition);
    if (hit != null) {
      final original = layout.originals[hit.taskId];
      if (original != null) widget.onTaskSelected(original);
      return;
    }
    if (widget.selectedTaskId != null) {
      // 有选中时点空白 = 取消选中（设计 §13-6）
      widget.onTaskSelected(null);
      return;
    }
    // 无选中时点空白年格 = 下钻该年的年视图（设计 §2.1）
    final year =
        _epochYear + ((d.localPosition.dx / layout.ppy) + _scrollYf).floor();
    widget.onYearTap(year);
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
        final minPpy = constraints.maxWidth / 20;
        final ppy = (_ppy ?? minPpy).clamp(minPpy, _maxPpy);
        if (!_positioned) {
          final nowYf = _yearFraction(DateTime.now().millisecondsSinceEpoch);
          _scrollYf = (nowYf - constraints.maxWidth / (2 * ppy))
              .clamp(_minScroll, _maxScroll);
          _positioned = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => _reportWindow());
        }
        _scrollYf = _scrollYf.clamp(_minScroll, _maxScroll);
        final layout = _YearlyLayout.build(
          viewW: constraints.maxWidth,
          viewH: constraints.maxHeight,
          tasks: display,
          originals: {for (final t in widget.tasks) t.id: t},
          ppy: ppy,
          scrollYf: _scrollYf,
          epochYear: _epochYear,
          scheme: scheme,
          measure: measure,
          now: DateTime.now(),
          selectedTaskId: widget.selectedTaskId,
          pulseYear: _pulseYear,
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
  final double x1; // 画布坐标
  final double x2;
  final double y;
  final Color color;
  final bool isPoint;
  final bool isSubtask;

  const _YearlyItem({
    required this.task,
    required this.x1,
    required this.x2,
    required this.y,
    required this.color,
    required this.isPoint,
    required this.isSubtask,
  });
}

class _YearlyLayout {
  static const headerH = 44.0;
  static const nameLayerH = 100.0;
  static const slotH = 18.0;

  final double viewW;
  final double viewH;
  final double ppy;
  final double scrollYf;
  final int epochYear;
  final double namesH;
  final List<double> laneHeights;
  final int majorTickYears;
  final int? minorTickYears;
  final int labelStride;
  final List<_YearlyItem> items;
  final Map<String, DayNameSlot> nameSlots;
  final List<_HitRegion> hitRegions;
  final Map<String, Task> originals;
  final Map<String, (int, int?)> spans; // taskId -> (startMs, endMs)
  final ColorScheme scheme;
  final int nowYear;
  final String? selectedTaskId;
  final int? pulseYear;

  _YearlyLayout._({
    required this.viewW,
    required this.viewH,
    required this.ppy,
    required this.scrollYf,
    required this.epochYear,
    required this.namesH,
    required this.laneHeights,
    required this.majorTickYears,
    required this.minorTickYears,
    required this.labelStride,
    required this.items,
    required this.nameSlots,
    required this.hitRegions,
    required this.originals,
    required this.spans,
    required this.scheme,
    required this.nowYear,
    required this.selectedTaskId,
    required this.pulseYear,
  });

  static const _priorities = [
    TaskPriority.important,
    TaskPriority.normal,
    TaskPriority.minor,
  ];

  static double _yearFraction(int ms, int epochYear) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final y0 = DateTime(d.year).millisecondsSinceEpoch;
    final y1 = DateTime(d.year + 1).millisecondsSinceEpoch;
    return d.year - epochYear + (ms - y0) / (y1 - y0);
  }

  static _YearlyLayout build({
    required double viewW,
    required double viewH,
    required List<Task> tasks,
    required Map<String, Task> originals,
    required double ppy,
    required double scrollYf,
    required int epochYear,
    required ColorScheme scheme,
    required double Function(String) measure,
    required DateTime now,
    required String? selectedTaskId,
    required int? pulseYear,
  }) {
    final (majorTickYears, minorTickYears, labelStride) =
        yearTickInterval(ppy);

    double xOf(double yf) => (yf - scrollYf) * ppy;

    int laneIndexOf(Task t) => _priorities.contains(t.priority)
        ? _priorities.indexOf(t.priority)
        : 1;

    // 名称贪心放置（v2.3）：轴 = 绝对年小数，锚点按月步进
    final nameSlotsList = assignAngledNames(
      tasks.where((t) => t.startAt != null).toList(),
      axisOf: (t) {
        final f1 = _yearFraction(t.startAt!, epochYear);
        final f2 =
            t.endAt == null ? f1 : _yearFraction(t.endAt!, epochYear);
        return (f1, f2);
      },
      axisPerPx: 1 / ppy,
      anchorStep: 1 / 12,
      measureText: measure,
      maxHeightPx: nameLayerH - 8,
    );
    final nameSlots = {for (final s in nameSlotsList) s.taskId: s};
    final namesH = nameSlotsList.any((e) => e.visible) ? nameLayerH : 0.0;

    // 按优先级分泳道，泳道内按年小数区间贪心分槽；
    // 子任务（parent_id 非空）父在可见任务中则与父同泳道同槽（设计 §3）。
    final laneSlots = List.generate(3, (_) => <List<(double, double)>>[]);
    final slotOf = <String, (int, int)>{}; // taskId -> (lane, slot)
    final regular = tasks.where((t) => t.startAt != null).toList()
      ..sort((a, b) {
        final c = a.startAt!.compareTo(b.startAt!);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    final items = <_YearlyItem>[];
    final spans = <String, (int, int?)>{};
    final pending = <(Task, int, int, bool)>[]; // task, lane, slot, isSubtask

    for (final t in regular) {
      final lane = laneIndexOf(t);
      final f1 = _yearFraction(t.startAt!, epochYear);
      final f2 = t.endAt == null ? f1 : _yearFraction(t.endAt!, epochYear);
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
        final clash = slots[slot].any((iv) => f1 <= iv.$2 && iv.$1 <= f2);
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
      var y = namesH + headerH.toDouble();
      for (var i = 0; i < laneIdx; i++) {
        y += laneHeights[i];
      }
      return y;
    }

    double itemY(int laneIdx, int slot) =>
        laneTop(laneIdx) + 8 + slot * slotH + slotH / 2;

    for (final (t, lane, slot, isSub) in pending) {
      final s = t.startAt!;
      final e = t.endAt;
      spans[t.id] = (s, e);
      final x1 = xOf(_yearFraction(s, epochYear));
      final x2 = e == null ? x1 : xOf(_yearFraction(e, epochYear));
      items.add(_YearlyItem(
        task: t,
        x1: x1,
        x2: x2,
        y: itemY(lane, slot),
        color: priorityColor(scheme, t.priority),
        isPoint: e == null,
        isSubtask: isSub,
      ));
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
            Rect.fromCircle(center: Offset(it.x1, it.y), radius: 14),
            it.task.id,
            _DragMode.move));
      } else {
        hitRegions.add(_HitRegion(
            Rect.fromCircle(center: Offset(it.x2, it.y), radius: 14),
            it.task.id,
            _DragMode.resizeEnd));
        hitRegions.add(_HitRegion(
            Rect.fromCircle(center: Offset(it.x1, it.y), radius: 14),
            it.task.id,
            _DragMode.resizeStart));
        hitRegions.add(_HitRegion(
            Rect.fromLTRB(it.x1, it.y - 10, it.x2, it.y + 10),
            it.task.id,
            _DragMode.move));
      }
    }
    // 名称命中区域：点按名称 = 选中（设计 §13-6）
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

    return _YearlyLayout._(
      viewW: viewW,
      viewH: viewH,
      ppy: ppy,
      scrollYf: scrollYf,
      epochYear: epochYear,
      namesH: namesH,
      laneHeights: laneHeights,
      majorTickYears: majorTickYears,
      minorTickYears: minorTickYears,
      labelStride: labelStride,
      items: items,
      nameSlots: nameSlots,
      hitRegions: hitRegions,
      originals: originals,
      spans: spans,
      scheme: scheme,
      nowYear: now.year,
      selectedTaskId: selectedTaskId,
      pulseYear: pulseYear,
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

  double _xOf(double yf) => (yf - layout.scrollYf) * layout.ppy;


  // U11：两个半径 5 的点相距 <= 12px 时视觉上已经相碰，合并为一个点。
  static const double _clusterThresholdPx = 12;

  NodeClusters? _cachedClusters;

  /// U11：时间点任务节点聚类（重合的画一个代表点，标题合并）。
  NodeClusters _clusters() => _cachedClusters ??= NodeClusters.build(
        [
          for (final it in layout.items)
            if (it.isPoint) (id: it.task.id, x: it.x1, y: it.y),
        ],
        thresholdPx: _clusterThresholdPx,
      );
  @override
  void paint(Canvas canvas, Size size) {
    final scheme = layout.scheme;
    final ppy = layout.ppy;
    final top = layout.namesH;
    final ganttTop = top + _YearlyLayout.headerH;

    // 当前年高亮竖带
    final nowX = (layout.nowYear - layout.epochYear).toDouble();
    final nowX0 = _xOf(nowX);
    if (nowX0 + ppy >= 0 && nowX0 <= size.width) {
      canvas.drawRect(
        Rect.fromLTWH(nowX0, top, ppy, size.height - top),
        Paint()..color = scheme.primary.withValues(alpha: 0.08),
      );
    }

    _drawTicks(canvas, size, top, ganttTop);

    // 任务：节点 / 带端点圆点的线段；子任务画更小节点/更细线；
    // 选中任务加描边（v2.3 选中-调整）。无泳道底纹（v2.3 §13-8）。
      // U11：时间几乎重合的点会叠在一起，只画一个代表点（否则「一个点 + 多个标题」）。
      final clusters = _clusters();
      for (final it in layout.items) {
        if (it.x2 < -40 || it.x1 > size.width + 40) continue; // 裁剪
        final done = it.task.status == TaskStatus.done;
        final color = it.color.withValues(alpha: done ? doneTaskOpacity : 1.0);
        if (it.isPoint) {
          if (!clusters.isRepresentative(it.task.id)) continue;
          final ci = clusters.indexOfId(it.task.id)!;
          final c = clusters.centerOf(ci);
          canvas.drawCircle(Offset(c.$1, c.$2), it.isSubtask ? 3.5 : 5,
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
          final endR = it.isSubtask ? 3.5 : 5.0;
          _drawBreak(canvas, it.x1, it.y, color, endR);
          _drawBreak(canvas, it.x2, it.y, color, endR);
        }
        if (it.task.id == layout.selectedTaskId) {
          _drawSelection(canvas, it, scheme);
        }
      }

      // 名称层：45° 斜文本 + 垂直虚线（U11：重合点的标题合并成「A / B」）
      if (layout.namesH > 0) {
        final dashPaint = Paint()
          ..color = scheme.onSurfaceVariant.withValues(alpha: 0.7)
          ..strokeWidth = 1;
        final clusters = _clusters();
        for (final it in layout.items) {
          if (it.isSubtask) continue;
          final slot = layout.nameSlots[it.task.id];
          if (slot == null || !slot.visible) continue;
          final ci = clusters.indexOfId(it.task.id);
          final merged = ci != null && clusters.ids(ci).length > 1;
          if (merged && !clusters.isRepresentative(it.task.id)) continue;
          final anchorX = _xOf(slot.centerMinutes);
          if (anchorX < -120 || anchorX > size.width + 120) continue;
          final targetY = merged ? clusters.centerOf(ci).$2 : it.y;
          var dy = layout.namesH - 6.0;
          while (dy < targetY - 8) {
            canvas.drawLine(
                Offset(anchorX, dy), Offset(anchorX, dy + 3), dashPaint);
            dy += 6;
          }
          final done = it.task.status == TaskStatus.done;
          final titles = merged
              ? [
                  for (final id in clusters.ids(ci))
                    layout.originals[id]?.title ?? '',
                ].where((s) => s.isNotEmpty).join(' / ')
              : it.task.title;
          final tp = TextPainter(
            text: TextSpan(
              text: titles,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface
                    .withValues(alpha: done ? doneTaskOpacity : 1.0),
                decoration: (done && !merged) ? TextDecoration.lineThrough : null,
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
    final pulseYear = layout.pulseYear;
    if (pulseYear != null) {
      final x = _xOf((pulseYear - layout.epochYear).toDouble());
      if (x + ppy >= 0 && x <= size.width) {
        canvas.drawRect(
          Rect.fromLTWH(x, top, ppy, size.height - top),
          Paint()..color = scheme.primary.withValues(alpha: 0.2),
        );
      }
    }
  }

  void _drawSelection(Canvas canvas, _YearlyItem it, ColorScheme scheme) {
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

  /// 动态刻度（设计 §2.1）：主刻度 = 长竖格线 + 刻度短线 + 斜 -45° 年份标注
  /// （过挤按 2 的幂隔档）；次刻度 = 短刻度线。
  void _drawTicks(Canvas canvas, Size size, double top, double ganttTop) {
    final scheme = layout.scheme;
    final ppy = layout.ppy;
    final scrollYf = layout.scrollYf;
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

    // 可视范围内的刻度序号（刻度序号 = 年 - epochYear，从 0 起对齐 major）
    final firstTick = scrollYf.floor() - major;
    final lastTick = (scrollYf + size.width / ppy).ceil() + major;

    if (minor != null) {
      var t = (firstTick / minor).floor() * minor;
      while (t <= lastTick) {
        if (t % major != 0) {
          final x = _xOf(t.toDouble());
          canvas.drawLine(
              Offset(x, ganttTop - 3), Offset(x, ganttTop), tickPaint);
        }
        t += minor;
      }
    }

    // 主刻度：当前年（nowYear）的 tick 用 primary 标注（v2.4）
    final nowYearTick = DateTime.now().year - layout.epochYear;
    var t = (firstTick / major).floor() * major;
    while (t <= lastTick) {
      final x = _xOf(t.toDouble());
      final isNow = t <= nowYearTick && nowYearTick < t + major;
      canvas.drawLine(Offset(x, top), Offset(x, size.height), gridPaint);
      canvas.drawLine(
          Offset(x, ganttTop - 6),
          Offset(x, ganttTop),
          isNow
              ? (Paint()
                ..color = scheme.primary
                ..strokeWidth = 1.5)
              : tickPaint);
      if ((t ~/ major) % layout.labelStride == 0) {
        final tp = TextPainter(
          text: TextSpan(
              text: '${layout.epochYear + t}',
              style: isNow
                  ? labelStyle.copyWith(
                      color: scheme.primary, fontWeight: FontWeight.w600)
                  : labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        canvas.save();
        canvas.translate(x + 2, ganttTop - 8);
        canvas.rotate(-math.pi / 4);
        tp.paint(canvas, Offset(2, -tp.height + 1));
        canvas.restore();
      }
      t += major;
    }
  }

  /// 时间段端点的圆点（v2.5：方块改圆点，与时间点节点同半径）。
  void _drawBreak(Canvas canvas, double x, double y, Color color,
      [double radius = 5]) {
    canvas.drawCircle(Offset(x, y), radius, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_YearlyPainter oldDelegate) => true;
}

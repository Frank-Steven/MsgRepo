import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

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

class DayViewState extends State<DayView>
    with TickerProviderStateMixin {
  /// 缩放范围：最小 = 24h 恰好铺满可视宽，最大 = 每 5 分钟 48dp。
  static const _maxPpm = 48.0 / 5;

  /// 绝对分钟基准：2000-01-01 本地零点。
  static final _epochMs = DateTime(2000).millisecondsSinceEpoch;

  /// 实际可滚动范围：2000-01-01 ~ 2100-01-01（双向“无限”的实际边界）。
  static final _maxMin =
      (DateTime(2100).millisecondsSinceEpoch - _epochMs) / 60000.0;

  /// 当前比例尺（px/分钟）；null = 未初始化，首帧定位到当前时刻。
  double? _ppm;

  /// 文本宽度测量缓存（跨帧复用，键 = 标题）。
  final Map<String, double> _measureCache = {};

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

  /// fling 惯性滚动（v2.4）：水平甩动后按摩擦衰减继续平移。
  AnimationController? _flingCtrl;
  double _flingStartMin = 0;

  void _cancelFling() {
    _flingCtrl?.stop();
    _flingCtrl?.dispose();
    _flingCtrl = null;
  }

  void _startFling(double vxPxPerSec) {
    final ppm = _ppm;
    if (ppm == null || vxPxPerSec.abs() < 120) return; // 低速不惯性
    _cancelFling();
    _flingStartMin = _scrollMin;
    // 模拟值 = 像素位移（正 = 手指向右甩）；scrollMin 反向变化
    final sim = FrictionSimulation(0.09, 0, vxPxPerSec);
    final ctrl = AnimationController.unbounded(vsync: this);
    ctrl.addListener(() {
      final next = (_flingStartMin - ctrl.value / ppm);
      if (next <= 0 || next >= _maxMin) {
        // 撞边界即停。注意：正处于 value 通知循环里，不能就地 dispose 自己，
        // 先停 ticker，帧末再回收（v2.5 修复：原 _cancelFling() 在 listener 中
        // dispose 自己，且旧实现反复新建 controller 会触发
        // SingleTickerProviderStateMixin 的多 ticker 断言，导致第二次起 fling 失效）
        final c = _flingCtrl;
        if (c != null) {
          _flingCtrl = null;
          c.stop();
          WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
        }
        setState(() => _scrollMin = next.clamp(0.0, _maxMin));
        _reportWindow();
        return;
      }
      setState(() => _scrollMin = next);
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
    _cancelFling();
    super.dispose();
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  // ---- 供父级调用的定位方法 ----

  /// 滚动到当前时刻并居中，短暂脉冲高亮（设计 §13-10）。
  /// v2.6.1：先停掉进行中的 fling 动画，否则动画下一帧会覆盖定位。
  void scrollToNow() {
    _cancelFling();
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
    _cancelFling();
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
    _cancelFling();
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

  /// 上次上报的（首可视日, 末可视日, 中心日）——滚动/缩放中只在单位
  /// 变化时上报（v2.6.1：标题跟随可视中心日期，又不每帧 setState）。
  (int, int, int)? _lastReportKey;

  void _reportOnUnitChange() {
    if (_viewW <= 0 || _ppm == null) return;
    final ppm = _ppm!;
    final key = (
      (_scrollMin / 1440).floor(),
      ((_scrollMin + _viewW / ppm) / 1440).floor(),
      ((_scrollMin + _viewW / (2 * ppm)) / 1440).floor(),
    );
    if (key != _lastReportKey) _reportWindow();
  }

  void _reportWindow() {
    if (_viewW <= 0 || _ppm == null) return;
    // 精确可视范围（v2.4：加载提前量由父级 _ensureRange 负责，
    // 这里上报的范围同时用于底部面板与标题）
    final startMs = (_scrollMin * 60000 + _epochMs).round();
    final endMs =
        ((_scrollMin + _viewW / _ppm!) * 60000 + _epochMs).round();
    final centerMs =
        ((_scrollMin + _viewW / (2 * _ppm!)) * 60000 + _epochMs).round();
    _lastReportKey = (
      (_scrollMin / 1440).floor(),
      ((_scrollMin + _viewW / _ppm!) / 1440).floor(),
      (centerMs / 86400000).floor(),
    );
    widget.onVisibleWindowChanged(startMs, endMs);
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
    _cancelFling();
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
      // U15：最小刻度 1 分钟（原先 5 分钟，小幅拖动会「不动」而显得卡顿）
      final snapped = snapToMinutes(raw);
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
    _reportOnUnitChange(); // v2.6.1：拖动/缩放中标题实时跟随
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
    final wasDragging = _dragOriginal != null;
    setState(() {
      _dragOriginal = null;
      _dragMode = null;
      _deltaMin = 0;
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
    // U15：长按空白处新建任务也按 1 分钟量化
    final min = snapToMinutes(_scrollMin + d.localPosition.dx / layout.ppm);
    widget.onBlankLongPress((_epochMs + min * 60000).round());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final nameStyle = TextStyle(fontSize: 11, color: scheme.onSurface);
    // measure 缓存常驻 State（2026-10-20 性能）：原来每帧新建，
    // 拖拽时每帧都要为每个标签组标题的每一行重新 TextPainter.layout 量宽。
    final measureCache = _measureCache;
    double measure(String title) => measureCache.putIfAbsent(
        title,
        () => (TextPainter(
              text: TextSpan(text: title, style: nameStyle),
              textDirection: TextDirection.ltr,
              maxLines: 30,
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
  final int rowIdx; // R01：行分配结果（0 起）

  final bool isPoint;
  final bool isSubtask;

  const _DayItem({
    required this.rowIdx,
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
  static const laneH = labelH + markerH;
  // R01-A（2026-10-20）：不再用顶部 160px 名称层 + 45° 斜排，改成每行自带「标签行 + 标记行」。
  static const labelH = 15.0; // 与 yearly_view 对齐
  static const markerH = 18.0; // 与 yearly_view 对齐
  static const labelGapPx = 6.0; // 标签之间留白（与 yearly_view 的 _labelGapPx 一致）

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
  /// R1-A：标签分组与「组 → 槽位」映射（唯一一次贪心的结果）
  final List<LabelGroup> groups;
  final Map<String, DayNameSlot> groupSlots;
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
    required this.groups,
    required this.groupSlots,
    required this.hitRegions,
    required this.originals,
    required this.spans,
    required this.scheme,
    required this.nameStyle,
    required this.nowMin,
    required this.selectedTaskId,
    required this.pulseMin,
  });

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

    // ---- R01（2026-10-20 拍板）：按开始时间排序 + 行分配 + 单行标签 ----
    // 不再按颜色/优先级分泳道；按开始时间依次从第 1 行试：
    // 行内已有任务与本任务「投影间距 < 130px」（≈20 字标签宽）即算占用，换下一行；行数不限。
    // 方案 B（用户 2026-10-20 拍板试这个）：行占用按「**标记不重叠**」判定。
    // 原 130px（≈20 字标签宽）在最小缩放下相当于 8.7 小时 —— 同一天几乎每个任务
    // 都单独占一行，且拖动时来回跳行，观感极差。标签是否显示仍由「正上方有空间」判定。
    const rowGapPx = 18.0; // 节点直径 10 + 间隙（逻辑像素）
    final ordered = [...tasks]..sort((a, b) {
        final c = a.startAt!.compareTo(b.startAt!);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    // 每行已占用的 px 区间（只存真实区间，判定时才加 130px 光环）
    final rowSpans = <List<(double, double)>>[];
    int rowOf(double xa, double xb) {
      final left = math.min(xa, xb);
      final right = math.max(xa, xb);
      for (var r = 0; r < rowSpans.length; r++) {
        var clash = false;
        for (final iv in rowSpans[r]) {
          if (left - rowGapPx < iv.$2 && iv.$1 < right + rowGapPx) {
            clash = true;
            break;
          }
        }
        if (!clash) {
          rowSpans[r].add((left, right));
          return r;
        }
      }
      rowSpans.add([(left, right)]);
      return rowSpans.length - 1;
    }

    // 名称带高度：有任务就预留（放不下的标签不画，但带子保留，避免行位置跳动）
    const namesH = 0.0; // R01-A：标签贴在自己那一行，不再占用顶部名称带

    double laneY(int rowIdx) =>
        headerH + rowIdx * laneH + labelH + markerH / 2;

    // 先按开始时间给「非子任务」分配行；子任务跟随父任务的 y（父子同线）。
    final rowsByTask = <String, int>{};
    final spans = <String, (double, double)>{};
    final x1ByTask = <String, double>{};
    final x2ByTask = <String, double>{};
    for (final t in ordered) {
      final startMin = (t.startAt! - epochMs) / 60000.0;
      final endMin = t.endAt == null
          ? startMin
          : math.max(startMin, (t.endAt! - epochMs) / 60000.0);
      spans[t.id] = (startMin, endMin);
      final x1 = xOf(startMin);
      final x2 = t.endAt == null ? x1 : xOf(endMin);
      x1ByTask[t.id] = x1;
      x2ByTask[t.id] = x2;
      final pid = t.parentId;
      final parentVisible = pid != null && originals.containsKey(pid);
      if (parentVisible) continue; // 子任务不参与行分配
      rowsByTask[t.id] = rowOf(x1, x2);
    }
    for (final t in ordered) {
      final pid = t.parentId;
      if (pid != null && originals.containsKey(pid)) {
        rowsByTask[t.id] = rowsByTask[pid] ?? 0;
      }
    }


    // 标签：单行、不合并、不换行、先到先得（R01）。
    // 点任务：正上方有空间才显示；线段任务：显示在「最左侧符合条件」的点上方；都不行就不显示。
    final nameSlots = <String, DayNameSlot>{};
    final hitRegions = <_HitRegion>[];
    final items = <_DayItem>[];
    for (final t in ordered) {
      final rowIdx = rowsByTask[t.id] ?? 0;
      final x1 = x1ByTask[t.id]!;
      final x2 = x2ByTask[t.id]!;
      final pid = t.parentId;
      items.add(_DayItem(
        task: t,
        x1: x1,
        x2: x2,
        y: laneY(rowIdx),
        color: priorityColor(scheme, t.priority),
        isPoint: t.endAt == null,
        isSubtask: pid != null && originals.containsKey(pid),
        rowIdx: rowIdx,
      ));
    }

    /// 某个 x 区间在「指定行的上方」是否空着（row=0 时上方是名称带，视为空）。
    bool freeAbove(int rowIdx, double left, double right) {
      if (rowIdx <= 0) return true;
      final above = rowSpans[rowIdx - 1];
      for (final iv in above) {
        // 与 yearly_view 口径一致：留 6px 间隙，避免标签贴着别的节点
        if (left - labelGapPx < iv.$2 && iv.$1 < right + labelGapPx) return false;
      }
      return true;
    }

    for (final it in items) {
      if (it.isSubtask) continue;
      final title = it.task.title.trim();
      if (title.isEmpty) continue;
      final w = measure(title);
      if (w < 6) continue;
      double? anchorX;
      if (it.isPoint) {
        if (freeAbove(it.rowIdx, it.x1, it.x1 + w)) anchorX = it.x1;
      } else {
        // 线段任务：从 x1 起按标签宽度步进，找最左侧「上方空着」的点
        var probe = it.x1;
        while (probe <= it.x2) {
          if (freeAbove(it.rowIdx, probe, probe + w)) {
            anchorX = probe;
            break;
          }
          probe += math.max(24.0, w * 0.5);
        }
      }
      if (anchorX == null) continue;
      nameSlots[it.task.id] = DayNameSlot(
        taskId: it.task.id,
        centerMinutes: scrollMin + anchorX / ppm,
        textWidth: w,
        visible: true,
      );
    }

    // R01：节点不再合并 → 不再构造 LabelGroup；保留字段以兼容绘制/比较代码
    const groups = <LabelGroup>[];
    const groupSlots = <String, DayNameSlot>{};

    // 命中区域：子任务在前（与父同 y 叠加时优先命中子任务）
    for (final it in [
      ...items.where((i) => i.isSubtask),
      ...items.where((i) => !i.isSubtask)
    ]) {
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
    // 名称命中区域：点按名称 = 选中该任务（设计 §13-6）
      // 名称命中区域（R01-A）：标签贴在节点正上方，点在标签上等于选中该任务。
      for (final it in items) {
        if (it.isSubtask) continue;
        final slot = nameSlots[it.task.id];
        if (slot == null || !slot.visible) continue;
        final anchorX = xOf(slot.centerMinutes);
        hitRegions.add(_HitRegion(
            Rect.fromLTWH(anchorX - 2, it.y - markerH / 2 - labelH,
                slot.textWidth + 8, labelH),
            it.task.id,
            _DragMode.move));
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
        groups: groups,
        groupSlots: groupSlots,
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

    // 任务：时间点=节点；时间段=带端点圆点的线段；子任务画更小节点/更细线；
    // 选中任务加描边（v2.3 选中-调整）
      // 节点：点任务按「标签组」只画一个代表点（组内 y 最小者，即优先级最高），
      // 组内点任务 ≥2 时点画大一圈；时段任务照常画线段。
      for (final it in layout.items) {
        if (it.x2 < -40 || it.x1 > size.width + 40) continue; // 裁剪
        final done = it.task.status == TaskStatus.done;
        final color = it.color.withValues(alpha: done ? doneTaskOpacity : 1.0);
        if (it.isPoint) {
          final baseR = it.isSubtask ? 3.5 : 5.0;
          canvas.drawCircle(Offset(it.x1, it.y), baseR, Paint()..color = color);
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

      // 标签层（R01-A）：每行自己一条标签线，水平单行贴在节点正上方；放不下就不画。
      for (final it in layout.items) {
        final slot = layout.nameSlots[it.task.id];
        if (slot == null || !slot.visible) continue;
        final anchorX = _xOf(slot.centerMinutes);
        if (anchorX < -140 || anchorX > size.width + 140) continue;
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
          ellipsis: '…',
        )..layout(maxWidth: slot.textWidth + 2);
        tp.paint(canvas, Offset(anchorX, it.y - _DayLayout.markerH / 2 - tp.height));
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

    // 主刻度：竖格线 + 刻度短线 + 斜 45° 标注（过挤按 2 的幂隔档）；
    // 当前时刻所在的主刻度用 primary 标注（v2.4）
    final firstMajor = (firstMin / major).floor();
    final lastMajor = (lastMin / major).ceil();
    final nowSlot = (layout.nowMin / major).floor();
    for (var t = firstMajor; t <= lastMajor; t++) {
      final minute = t * major;
      final x = _xOf(minute.toDouble());
      final isNow = t == nowSlot;
      canvas.drawLine(Offset(x, top), Offset(x, size.height), gridPaint);
      canvas.drawLine(
          Offset(x, ganttTop - 6),
          Offset(x, ganttTop),
          isNow
              ? (Paint()
                ..color = scheme.primary
                ..strokeWidth = 1.5)
              : tickPaint);
      if (t % layout.labelStride != 0) continue;
      final d = DateTime.fromMillisecondsSinceEpoch(
          layout.epochMs + minute * 60000);
      final label = '${d.hour}:${_two(d.minute)}';
      final tp = TextPainter(
        text: TextSpan(
            text: label,
            style: isNow
                ? labelStyle.copyWith(
                    color: scheme.primary, fontWeight: FontWeight.w600)
                : labelStyle),
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

  /// 时间段端点的圆点（v2.5：方块改圆点，与时间点节点同半径）。
  void _drawBreak(Canvas canvas, double x, double y, Color color,
      [double radius = 5]) {
    canvas.drawCircle(Offset(x, y), radius, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_DayPainter oldDelegate) {
    final a = oldDelegate.layout;
    final b = layout;
    if (!identical(a.scheme, b.scheme)) return true;
    if (a.viewW != b.viewW ||
        a.viewH != b.viewH ||
        a.ppm != b.ppm ||
        a.scrollMin != b.scrollMin ||
        a.epochMs != b.epochMs ||
        a.namesH != b.namesH ||
        a.majorTickMin != b.majorTickMin ||
        a.minorTickMin != b.minorTickMin ||
        a.labelStride != b.labelStride ||
        a.selectedTaskId != b.selectedTaskId ||
        a.pulseMin != b.pulseMin ||
        a.nowMin != b.nowMin) {
      return true;
    }
    // 布局每帧都会重建（items/groups 都是新 List），所以不能比 identical，
    // 要比内容 —— 否则等于恒 true，等于没优化（code-writer 2026-10-20 指出）。
    if (!_sameItems(a.items, b.items)) return true;
    if (!_sameGroups(a.groups, b.groups)) return true;
    return false;
  }

  static bool _sameItems(List<_DayItem> a, List<_DayItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.task.id != y.task.id ||
          x.x1 != y.x1 ||
          x.x2 != y.x2 ||
          x.y != y.y ||
          x.color != y.color ||
          x.isPoint != y.isPoint ||
          x.isSubtask != y.isSubtask) {
        return false;
      }
    }
    return true;
  }

  static bool _sameGroups(List<LabelGroup> a, List<LabelGroup> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.id != y.id ||
          x.title != y.title ||
          x.startAxis != y.startAxis ||
          x.endAxis != y.endAxis ||
          x.taskIds.length != y.taskIds.length) {
        return false;
      }
    }
    return true;
  }}

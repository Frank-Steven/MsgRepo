import 'package:flutter/material.dart';

import '../../models/task.dart';
import 'layout.dart';
import 'schedule_shared.dart';

enum _DragMode { move, resizeStart, resizeEnd }

/// 年视图（设计 §2.1）：4 行（季度）× 3 块（月），块内红黄绿三条泳道，
/// 全图泳道垂直位置由优先级决定（跨行跨月对齐）。
class YearView extends StatefulWidget {
  final int year;
  final List<Task> tasks;
  final ValueChanged<int> onMonthTap;
  final ValueChanged<Task> onTaskTap;

  /// 拖拽落库回调：(原任务, 新 startAt, 新 endAt)。
  final void Function(Task task, int newStartMs, int? newEndMs) onTaskMoved;
  final ValueChanged<int> onBlankLongPress;

  const YearView({
    super.key,
    required this.year,
    required this.tasks,
    required this.onMonthTap,
    required this.onTaskTap,
    required this.onTaskMoved,
    required this.onBlankLongPress,
  });

  @override
  State<YearView> createState() => _YearViewState();
}

class _YearViewState extends State<YearView> {
  Task? _dragOriginal;
  _DragMode? _dragMode;
  int _dragStartMonth = 1; // 预览（1-12）
  int _dragEndMonth = 1;
  int _origStartMonth = 1; // 拖拽开始时展示副本的月份
  int _origEndMonth = 1;
  double _grabOffset = 0; // monthPos 抓取偏移（保留月内小数部分）

  (int, int) get _yearRange => (
        DateTime(widget.year).millisecondsSinceEpoch,
        DateTime(widget.year + 1).millisecondsSinceEpoch,
      );

  List<Task> _displayTasks() {
    final (startMs, endMs) = _yearRange;
    final list = <Task>[];
    for (final t in widget.tasks) {
      var d = displayOccurrence(t, startMs, endMs);
      if (d == null) continue;
      if (_dragOriginal?.id == t.id) d = _previewTask(d);
      list.add(d);
    }
    return list;
  }

  /// 拖拽预览：吸附月边界（起点到 1 日，终点到月末，时间保留原时分）。
  Task _previewTask(Task display) {
    final s = DateTime.fromMillisecondsSinceEpoch(display.startAt!);
    final newStart = DateTime(widget.year, _dragStartMonth, 1, s.hour, s.minute);
    int? newEnd;
    final e = display.endAt;
    if (e != null) {
      final ed = DateTime.fromMillisecondsSinceEpoch(e);
      newEnd = DateTime(widget.year, _dragEndMonth + 1, 1, ed.hour, ed.minute)
          .millisecondsSinceEpoch;
    }
    return display.copyWith(
      startAt: () => newStart.millisecondsSinceEpoch,
      endAt: () => newEnd,
    );
  }

  void _onTapUp(TapUpDetails d, _YearLayout layout) {
    final hit = layout.hitTest(d.localPosition);
    if (hit != null) {
      final original = layout.originals[hit.taskId];
      if (original != null) widget.onTaskTap(original);
      return;
    }
    final month = layout.monthAt(d.localPosition);
    if (month != null) widget.onMonthTap(month);
  }

  void _onLongPress(LongPressStartDetails d, _YearLayout layout) {
    if (layout.hitTest(d.localPosition) != null) return;
    final month = layout.monthAt(d.localPosition);
    if (month != null) widget.onBlankLongPress(month);
  }

  void _onPanStart(DragStartDetails d, _YearLayout layout) {
    final hit = layout.hitTest(d.localPosition);
    if (hit == null) return;
    final item = layout.itemById(hit.taskId);
    final original = layout.originals[hit.taskId];
    if (item == null || original == null) return;
    setState(() {
      _dragOriginal = original;
      _dragMode = hit.mode;
      _origStartMonth = item.lane.startMonth;
      _origEndMonth = item.lane.endMonth;
      _dragStartMonth = item.lane.startMonth;
      _dragEndMonth = item.lane.endMonth;
      _grabOffset =
          layout.monthPosAt(d.localPosition) - (item.lane.startMonth - 1);
    });
  }

  void _onPanUpdate(DragUpdateDetails d, _YearLayout layout) {
    if (_dragOriginal == null) return;
    final mp = layout.monthPosAt(d.localPosition);
    final span = _origEndMonth - _origStartMonth; // 0 = 月内节点
    setState(() {
      switch (_dragMode!) {
        case _DragMode.move:
          final start0 =
              (mp - _grabOffset).round().clamp(0, 11 - span);
          _dragStartMonth = start0 + 1;
          _dragEndMonth = start0 + 1 + span;
        case _DragMode.resizeStart:
          // 钳制：跨度 < 1 整年（<= 11 个月）
          final start0 =
              mp.round().clamp(_origEndMonth - 1 - 11, _origEndMonth - 1);
          _dragStartMonth = start0.clamp(0, 11) + 1;
        case _DragMode.resizeEnd:
          final end0 =
              mp.round().clamp(_origStartMonth - 1, _origStartMonth - 1 + 11);
          _dragEndMonth = end0.clamp(0, 11) + 1;
      }
    });
  }

  void _onPanEnd() {
    final original = _dragOriginal;
    final mode = _dragMode;
    if (original != null && mode != null) {
      final deltaStartM = _dragStartMonth - _origStartMonth;
      final deltaEndM = _dragEndMonth - _origEndMonth;
      if (deltaStartM != 0 || deltaEndM != 0) {
        final os = DateTime.fromMillisecondsSinceEpoch(original.startAt!);
        final newStart = DateTime(
                os.year, os.month + deltaStartM, 1, os.hour, os.minute)
            .millisecondsSinceEpoch;
        int? newEnd;
        final oe = original.endAt;
        if (oe != null) {
          final ed = DateTime.fromMillisecondsSinceEpoch(oe);
          final deltaM = switch (mode) {
            _DragMode.resizeEnd => deltaEndM,
            _DragMode.resizeStart => 0,
            _DragMode.move => deltaStartM,
          };
          // 终点吸附到月末：取下月 1 日（查询/展示按半开区间处理）
          newEnd = DateTime(ed.year, ed.month + deltaM + 1, 1, ed.hour,
                  ed.minute)
              .millisecondsSinceEpoch;
        }
        widget.onTaskMoved(original, newStart, newEnd);
      }
    }
    setState(() {
      _dragOriginal = null;
      _dragMode = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final display = _displayTasks();
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = _YearLayout.build(
          width: constraints.maxWidth,
          maxHeight: constraints.maxHeight,
          year: widget.year,
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
            size: Size(constraints.maxWidth, layout.height),
            painter: _YearPainter(layout),
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

class _YearItem {
  final Task task;
  final YearLaneItem lane;
  final double x1;
  final double x2;
  final double y;
  final Color color;
  final double nameX; // 名称锚点（节点取 x1，线段取 x2）
  final TextPainter? name; // 放得下才非空

  const _YearItem({
    required this.task,
    required this.lane,
    required this.x1,
    required this.x2,
    required this.y,
    required this.color,
    required this.nameX,
    this.name,
  });
}

class _YearLayout {
  static const pad = 8.0;
  static const gap = 6.0;
  static const labelH = 20.0;
  static const _naturalSlotH = 16.0;
  static const blockVPad = 4.0;

  final double width;
  final double height;
  final double blockW;
  final double blockH;
  final double slotH;
  final int year;
  final Map<String, int> laneSlotCounts; // priority -> 槽位数
  final List<Rect> monthBlocks; // 12 块，索引 = 月-1
  final List<_YearItem> items;
  final List<_HitRegion> hitRegions;
  final Map<String, Task> originals;
  final ColorScheme scheme;
  final int currentMonth; // 0 = 当前年不在今年

  _YearLayout._({
    required this.width,
    required this.height,
    required this.blockW,
    required this.blockH,
    required this.slotH,
    required this.year,
    required this.laneSlotCounts,
    required this.monthBlocks,
    required this.items,
    required this.hitRegions,
    required this.originals,
    required this.scheme,
    required this.currentMonth,
  });

  static const _priorities = [
    TaskPriority.important,
    TaskPriority.normal,
    TaskPriority.minor,
  ];

  static double _fracInMonth(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final days = DateTime(d.year, d.month + 1, 0).day;
    return ((d.day - 1) + (d.hour * 60 + d.minute) / 1440.0) / days;
  }

  static _YearLayout build({
    required double width,
    required double maxHeight,
    required int year,
    required List<Task> tasks,
    required Map<String, Task> originals,
    required ColorScheme scheme,
    required DateTime now,
  }) {
    final blockW = (width - 2 * pad - 2 * gap) / 3;
    final byId = {for (final t in tasks) t.id: t};
    final laneItems = <String, List<YearLaneItem>>{};
    final laneSlotCounts = <String, int>{};
    for (final p in _priorities) {
      final items =
          layoutYearLane(tasks.where((t) => t.priority == p).toList(), year);
      laneItems[p] = items;
      laneSlotCounts[p] =
          items.fold(0, (m, e) => e.slot + 1 > m ? e.slot + 1 : m).clamp(1, 99);
    }

    // 槽位过高时整体压缩 slotH，保证 12 块一屏绘完不滚动
    var slotH = _naturalSlotH;
    double totalH(double sh) {
      final blockH =
          labelH + sh * laneSlotCounts.values.fold(0, (a, b) => a + b) +
              2 * blockVPad;
      return 4 * blockH + 3 * gap + 2 * pad;
    }

    if (maxHeight.isFinite && totalH(slotH) > maxHeight) {
      final lanesTotal = laneSlotCounts.values.fold(0, (a, b) => a + b);
      final blockH = (maxHeight - 3 * gap - 2 * pad) / 4;
      slotH = ((blockH - labelH - 2 * blockVPad) / lanesTotal)
          .clamp(8.0, _naturalSlotH);
    }
    final height =
        maxHeight.isFinite ? maxHeight : totalH(slotH);
    final blockH = (height - 3 * gap - 2 * pad) / 4;

    double blockLeft(int month) => pad + ((month - 1) % 3) * (blockW + gap);
    double blockTop(int month) => pad + ((month - 1) ~/ 3) * (blockH + gap);

    final monthBlocks = [
      for (var m = 1; m <= 12; m++)
        Rect.fromLTWH(blockLeft(m), blockTop(m), blockW, blockH),
    ];

    // 泳道在块内的 y 偏移：由优先级决定，全图对齐
    final laneTopInBlock = <String, double>{};
    var acc = labelH;
    for (final p in _priorities) {
      laneTopInBlock[p] = acc;
      acc += laneSlotCounts[p]! * slotH;
    }

    final items = <_YearItem>[];
    final nameStyle = TextStyle(fontSize: 10, color: scheme.onSurfaceVariant);
    final doneNameStyle = nameStyle.copyWith(
      decoration: TextDecoration.lineThrough,
    );

    for (final p in _priorities) {
      final lane = laneItems[p]!;
      // 同槽位按 x 排序，用于计算名称可用宽度
      final slotNextX = <String, double>{};
      final sorted = [...lane]..sort((a, b) {
          final c = a.slot.compareTo(b.slot);
          return c != 0 ? c : a.startMonth.compareTo(b.startMonth);
        });
      for (var i = 0; i < sorted.length; i++) {
        if (i + 1 < sorted.length && sorted[i + 1].slot == sorted[i].slot) {
          final n = sorted[i + 1];
          slotNextX[sorted[i].taskId] = n.extendsBefore
              ? blockLeft(n.startMonth)
              : blockLeft(n.startMonth) +
                  blockW * _fracInMonth(byId[n.taskId]!.startAt!);
        }
      }
      final color = priorityColor(scheme, p);
      for (final li in lane) {
        final task = byId[li.taskId];
        if (task == null) continue;
        final startMs = task.startAt!;
        final endMs = task.endAt;
        final x1 = li.extendsBefore
            ? blockLeft(li.startMonth)
            : blockLeft(li.startMonth) + blockW * _fracInMonth(startMs);
        final x2 = li.startMonth == li.endMonth && endMs == null
            ? x1
            : li.extendsAfter
                ? blockLeft(li.endMonth) + blockW
                : blockLeft(li.endMonth) +
                    blockW * _fracInMonth(endMs ?? startMs);
        final y = blockTop(li.startMonth) +
            laneTopInBlock[p]! +
            li.slot * slotH +
            slotH / 2;
        final isNode = li.startMonth == li.endMonth &&
            !li.extendsBefore &&
            !li.extendsAfter;
        final nameX = (isNode ? x1 : x2) + 9;
        final avail =
            (slotNextX[li.taskId] ?? (width - pad)) - nameX - 2;
        final done = task.status == TaskStatus.done;
        final tp = TextPainter(
          text: TextSpan(
              text: task.title, style: done ? doneNameStyle : nameStyle),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        items.add(_YearItem(
          task: task,
          lane: li,
          x1: x1,
          x2: x2,
          y: y,
          color: color,
          nameX: nameX,
          name: tp.width <= avail ? tp : null,
        ));
      }
    }

    final hitRegions = <_HitRegion>[];
    for (final it in items) {
      final isSegment = it.lane.startMonth != it.lane.endMonth ||
          it.lane.extendsBefore ||
          it.lane.extendsAfter;
      if (isSegment) {
        hitRegions.add(
            _HitRegion(Rect.fromCircle(center: Offset(it.x2, it.y), radius: 10),
                it.task.id, _DragMode.resizeEnd));
        hitRegions.add(
            _HitRegion(Rect.fromCircle(center: Offset(it.x1, it.y), radius: 10),
                it.task.id, _DragMode.resizeStart));
        hitRegions.add(_HitRegion(
            Rect.fromLTRB(it.x1, it.y - 8, it.x2, it.y + 8),
            it.task.id,
            _DragMode.move));
      } else {
        hitRegions.add(_HitRegion(
            Rect.fromCircle(center: Offset(it.x1, it.y), radius: 12),
            it.task.id,
            _DragMode.move));
      }
    }

    return _YearLayout._(
      width: width,
      height: height,
      blockW: blockW,
      blockH: blockH,
      slotH: slotH,
      year: year,
      laneSlotCounts: laneSlotCounts,
      monthBlocks: monthBlocks,
      items: items,
      hitRegions: hitRegions,
      originals: originals,
      scheme: scheme,
      currentMonth: now.year == year ? now.month : 0,
    );
  }

  _YearItem? itemById(String taskId) {
    for (final it in items) {
      if (it.task.id == taskId) return it;
    }
    return null;
  }

  /// 命中任务元素（端点优先于线段中段）。
  _HitRegion? hitTest(Offset p) {
    for (final r in hitRegions) {
      if (r.rect.contains(p)) return r;
    }
    return null;
  }

  /// 位置所在月块（1-12），不在任何块内返回 null。
  int? monthAt(Offset p) {
    for (var i = 0; i < 12; i++) {
      if (monthBlocks[i].contains(p)) return i + 1;
    }
    return null;
  }

  /// 位置对应的连续月坐标（0.0-12.0），拖拽吸附取整用；纵向跨行有效。
  double monthPosAt(Offset p) {
    final col =
        ((p.dx - pad) / (blockW + gap)).floor().clamp(0, 2);
    final fracX =
        ((p.dx - pad - col * (blockW + gap)) / blockW).clamp(0.0, 1.0);
    final row =
        ((p.dy - pad) / (blockH + gap)).floor().clamp(0, 3);
    return (row * 3 + col + fracX).clamp(0.0, 12.0);
  }
}

class _YearPainter extends CustomPainter {
  final _YearLayout layout;

  _YearPainter(this.layout);

  static const _nodeR = 4.5;

  @override
  void paint(Canvas canvas, Size size) {
    final scheme = layout.scheme;
    // 月块与泳道
    for (var m = 1; m <= 12; m++) {
      final rect = layout.monthBlocks[m - 1];
      final rrect =
          RRect.fromRectAndRadius(rect, const Radius.circular(8));
      final isCurrent = m == layout.currentMonth;
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = isCurrent
              ? scheme.primaryContainer.withValues(alpha: 0.45)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      );
      if (isCurrent) {
        canvas.drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = scheme.primary,
        );
      }
      // 泳道底色（优先级色极低透明度），保证跨块上下对齐可见
      var laneTop = rect.top + _YearLayout.labelH;
      for (final p in _YearLayout._priorities) {
        final h = layout.laneSlotCounts[p]! * layout.slotH;
        canvas.drawRect(
          Rect.fromLTWH(rect.left + 2, laneTop, rect.width - 4, h),
          Paint()..color = priorityColor(scheme, p).withValues(alpha: 0.07),
        );
        laneTop += h;
      }
      final tp = TextPainter(
        text: TextSpan(
          text: '$m月',
          style: TextStyle(
            fontSize: 11,
            fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
            color: isCurrent ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(rect.left + 6, rect.top + 3));
    }

    // 任务节点/线段/名称
    for (final it in layout.items) {
      final done = it.task.status == TaskStatus.done;
      final color = it.color.withValues(alpha: done ? doneTaskOpacity : 1.0);
      final isSegment = it.lane.startMonth != it.lane.endMonth ||
          it.lane.extendsBefore ||
          it.lane.extendsAfter;
      if (isSegment) {
        canvas.drawLine(
          Offset(it.x1, it.y),
          Offset(it.x2, it.y),
          Paint()
            ..color = color
            ..strokeWidth = 2.5
            ..strokeCap = StrokeCap.round,
        );
        _drawEnd(canvas, it.x1, it.y, color, it.lane.extendsBefore, true);
        _drawEnd(canvas, it.x2, it.y, color, it.lane.extendsAfter, false);
      } else {
        canvas.drawCircle(Offset(it.x1, it.y), _nodeR, Paint()..color = color);
      }
      final name = it.name;
      if (name != null) {
        name.paint(canvas, Offset(it.nameX, it.y - name.height / 2));
      }
    }
  }

  /// 端点：普通端点画圆点；延伸出年边界的端点画斜切箭头指出边界。
  void _drawEnd(Canvas canvas, double x, double y, Color color,
      bool extendsOut, bool isStart) {
    if (!extendsOut) {
      canvas.drawCircle(Offset(x, y), _nodeR, Paint()..color = color);
      return;
    }
    final dir = isStart ? -1.0 : 1.0;
    final path = Path()
      ..moveTo(x + dir * 7, y)
      ..lineTo(x, y - 4.5)
      ..lineTo(x, y + 4.5)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_YearPainter oldDelegate) => true;
}

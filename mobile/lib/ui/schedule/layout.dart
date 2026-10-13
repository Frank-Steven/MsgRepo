import 'dart:math' as math;

import '../../models/task.dart';
import '../../services/text_width.dart';

/// 年视图泳道布局项（设计 §2.1 填充算法）。
class YearLaneItem {
  final String taskId;

  /// 钳制到当前年后的起止月（1-12）。
  final int startMonth;
  final int endMonth;

  /// 任务实际起点/终点不在当前年（端点画延伸样式，不为跨年部分保留槽位）。
  final bool extendsBefore;
  final bool extendsAfter;

  /// 泳道内槽位，0 起往下。
  final int slot;

  const YearLaneItem({
    required this.taskId,
    required this.startMonth,
    required this.endMonth,
    required this.extendsBefore,
    required this.extendsAfter,
    required this.slot,
  });
}

/// 年视图单条优先级泳道的槽位填充（设计 §2.1）：
/// 按开始时间升序，从 slot 0 起找第一个月份区间无重叠的槽位放下；
/// 被更早任务占据的槽位跳过继续往下。跨年任务按钳制后的范围占位
/// （每年独立调用本函数，跨年部分自然落到相邻年泳道的最上面槽位）。
List<YearLaneItem> layoutYearLane(List<Task> tasks, int year) {
  final yearStart = DateTime(year).millisecondsSinceEpoch;
  final yearEnd = DateTime(year + 1).millisecondsSinceEpoch;
  final entries = <_LaneEntry>[];
  for (final t in tasks) {
    final s = t.startAt;
    if (s == null) continue;
    final e = t.endAt ?? s;
    // 与本年无交集则跳过：时间点需落在年内，区间需与年内有正长度交集
    if (s >= yearEnd) continue;
    if (t.endAt == null ? e < yearStart : e <= yearStart) continue;
    final cs = math.max(s, yearStart);
    // 结束时刻恰为月/年边界时归前一月/年（e-1），保证落在年内且语义正确
    final ce = math.max(cs, math.min(e - 1, yearEnd - 1));
    entries.add(_LaneEntry(
      taskId: t.id,
      startMs: s,
      startMonth: DateTime.fromMillisecondsSinceEpoch(cs).month,
      endMonth: DateTime.fromMillisecondsSinceEpoch(ce).month,
      extendsBefore: s < yearStart,
      extendsAfter: e >= yearEnd,
    ));
  }
  entries.sort((a, b) {
    final c = a.startMs.compareTo(b.startMs);
    return c != 0 ? c : a.taskId.compareTo(b.taskId);
  });
  final slots = <List<(int, int)>>[];
  final result = <YearLaneItem>[];
  for (final en in entries) {
    var slot = 0;
    while (true) {
      if (slot == slots.length) slots.add([]);
      final occupied = slots[slot];
      final clash = occupied.any(
          (iv) => en.startMonth <= iv.$2 && iv.$1 <= en.endMonth);
      if (!clash) {
        occupied.add((en.startMonth, en.endMonth));
        result.add(YearLaneItem(
          taskId: en.taskId,
          startMonth: en.startMonth,
          endMonth: en.endMonth,
          extendsBefore: en.extendsBefore,
          extendsAfter: en.extendsAfter,
          slot: slot,
        ));
        break;
      }
      slot++;
    }
  }
  return result;
}

class _LaneEntry {
  final String taskId;
  final int startMs;
  final int startMonth;
  final int endMonth;
  final bool extendsBefore;
  final bool extendsAfter;

  const _LaneEntry({
    required this.taskId,
    required this.startMs,
    required this.startMonth,
    required this.endMonth,
    required this.extendsBefore,
    required this.extendsAfter,
  });
}

/// 日视图刻度档位（设计 §2.3，v2.1 修订）。
///
/// 返回 (主刻度间隔分钟, 次刻度间隔分钟?, 时间标注隔几个显示)：
/// - 主刻度 = 候选 5/15/30/60/120 中「相邻标注间距 ≥ [labelSpacingPx]」的最密档，
///   都不满足时取 120 分钟；
/// - 次刻度 = 下一更密档，间距不足 [minorSpacingPx] 时省略（null）；
/// - 标注按 2 的幂隔一个显示（stride=1 即每个主刻度都标），保证实际标注
///   间距 ≥ [labelSpacingPx]。
(int, int?, int) dayTickInterval(
  double pxPerMinute, {
  double labelSpacingPx = 64,
  double minorSpacingPx = 6,
}) {
  final ppm = math.max(pxPerMinute, 1e-6);
  const candidates = [5, 15, 30, 60, 120];
  var majorIdx = candidates.indexWhere((c) => c * ppm >= labelSpacingPx);
  if (majorIdx < 0) majorIdx = candidates.length - 1;
  final major = candidates[majorIdx];
  final minor = majorIdx > 0 &&
          candidates[majorIdx - 1] * ppm >= minorSpacingPx
      ? candidates[majorIdx - 1]
      : null;
  var stride = 1;
  while (major * ppm * stride < labelSpacingPx) {
    stride *= 2;
  }
  return (major, minor, stride);
}

/// 日视图名称空位分配结果（设计 §2.3 名称层）。
class DayNameSlot {
  final String taskId;

  /// 名称锚点（一天内分钟数）：虚线从节点/线段向上连到该位置。
  final double centerMinutes;

  /// 参与碰撞的文本宽（px，估算或调用方测量）。
  final double textWidth;

  /// 比例尺未达阈值或找不到空位时为 false（节点/线段仍照常绘制）。
  final bool visible;

  const DayNameSlot({
    required this.taskId,
    required this.centerMinutes,
    required this.textWidth,
    required this.visible,
  });
}

/// 日视图名称空位分配（设计 §2.3）。
///
/// 仅当 [minutesPerNode] <= 5（每 5 分钟一个节点的密度）时才尝试放置。
/// 按开始时间升序；时间点任务锚点固定在其时刻，时间段任务在自身范围内
/// 按 5 分钟步长找最靠前的空位。45° 斜文本带从下往上生长。
///
/// 碰撞检测取舍：所有文本带共享同一 45° 旋转角，把坐标系旋转 -45° 后
/// 每个 OBB 变成 AABB（沿文本方向 u ∈ [a/√2, a/√2 + L]，垂直方向
/// v = -a/√2 ± 厚度/2），两盒相交 = u 区间相交且 v 间距小于厚度和的
/// 一半。这比通用分离轴简单且对本场景精确；不检查名称层外的遮挡
/// （超过 [maxHeightPx] 的文本判为放不下）。
List<DayNameSlot> assignDayNames(
  List<Task> tasks, {
  required double minutesPerNode,
  double nodeSpacingPx = 14,
  double fontPx = 12,
  double maxHeightPx = 96,
  double Function(String title)? measureText,
}) {
  final measure = measureText ??
      // 全角字符约等于字宽，ASCII 约为一半（与 displayWidth 的 2/1 计量对应）
      (title) => displayWidth(title) * fontPx / 2;
  final allowed = minutesPerNode <= 5;
  final pxPerMinute = nodeSpacingPx / minutesPerNode;
  final k = 1 / pxPerMinute; // 分钟 / px：几何全部换算到「分钟单位」
  const sqrt2 = math.sqrt2;

  final sorted = [...tasks]..sort((a, b) {
      final c = (a.startAt ?? 0).compareTo(b.startAt ?? 0);
      return c != 0 ? c : a.id.compareTo(b.id);
    });

  final placedU = <(double, double)>[];
  final placedV = <double>[];
  final placedW = <double>[];
  final byId = <String, DayNameSlot>{};

  for (final t in sorted) {
    final s = t.startAt;
    if (s == null) continue;
    final startMin = _minuteOfDay(s);
    // 时间段任务的结束分钟（跨日钳到 24:00）；锚点可在 [startMin, endMin] 内
    final endMin = t.endAt == null
        ? startMin
        : math.max(startMin, math.min(1440.0, _minuteOfDay(t.endAt!)));
    final textWidth = measure(t.title);
    final lengthMin = textWidth * k;
    final thicknessMin = fontPx * 1.2 * k;
    final fitsHeight = lengthMin / sqrt2 <= maxHeightPx * k;

    var anchor = startMin;
    var visible = false;
    if (allowed && fitsHeight) {
      // 候选锚点：时间点只有自身时刻；时间段在范围内按 5 分钟步长前移
      for (var a = startMin; a <= endMin + 0.001; a += 5) {
        if (_fits(a, lengthMin, thicknessMin, placedU, placedV, placedW)) {
          anchor = a;
          visible = true;
          placedU.add((a / sqrt2, a / sqrt2 + lengthMin));
          placedV.add(-a / sqrt2);
          placedW.add(thicknessMin);
          break;
        }
      }
    }
    byId[t.id] = DayNameSlot(
      taskId: t.id,
      centerMinutes: anchor,
      textWidth: textWidth,
      visible: visible,
    );
  }
  // 按输入顺序返回
  return [for (final t in tasks) if (byId.containsKey(t.id)) byId[t.id]!];
}

double _minuteOfDay(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return d.hour * 60 + d.minute + d.second / 60.0;
}

bool _fits(
  double anchorMin,
  double lengthMin,
  double thicknessMin,
  List<(double, double)> placedU,
  List<double> placedV,
  List<double> placedW,
) {
  const sqrt2 = math.sqrt2;
  final u0 = anchorMin / sqrt2;
  final u1 = anchorMin / sqrt2 + lengthMin;
  final v = -anchorMin / sqrt2;
  for (var i = 0; i < placedU.length; i++) {
    final (pu0, pu1) = placedU[i];
    final vGap = (v - placedV[i]).abs();
    if (u1 > pu0 && u0 < pu1 && vGap < (thicknessMin + placedW[i]) / 2) {
      return false;
    }
  }
  return true;
}

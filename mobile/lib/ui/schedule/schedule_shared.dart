import 'package:flutter/material.dart';

import '../../models/task.dart';

/// 优先级配色（设计 §10.3：自绘视图颜色随深色模式适配）。
Color priorityColor(ColorScheme scheme, String priority) {
  final dark = scheme.brightness == Brightness.dark;
  return switch (priority) {
    TaskPriority.important =>
      dark ? Colors.red.shade300 : Colors.red.shade600,
    TaskPriority.minor =>
      dark ? Colors.green.shade300 : Colors.green.shade600,
    _ => dark ? Colors.amber.shade300 : Colors.amber.shade700,
  };
}

/// 已完成任务的降不透明度（淡色 + 名称划线由绘制方处理）。
const double doneTaskOpacity = 0.38;

/// 年度任务把 startAt 的月日时分平移到 [year]（2/29 等非法日期由
/// DateTime 自动进位），返回该年的 (startMs, endMs)。
(int, int?) annualOccurrence(Task t, int year) {
  final s = DateTime.fromMillisecondsSinceEpoch(t.startAt!);
  final occ = DateTime(
      year, s.month, s.day, s.hour, s.minute, s.second, s.millisecond);
  final occMs = occ.millisecondsSinceEpoch;
  final end = t.endAt;
  return (occMs, end == null ? null : occMs + (end - t.startAt!));
}

/// 任务在半开区间 [startMs, endMs) 内的展示时间：普通任务原样返回；
/// 年度任务逐年平移后取首个与区间相交的年份。无交集返回 null。
(int, int?)? occurrenceOverlapping(Task t, int startMs, int endMs) {
  final s = t.startAt;
  if (s == null) return null;
  if (!t.isAnnual) return t.overlaps(startMs, endMs) ? (s, t.endAt) : null;
  final firstYear = DateTime.fromMillisecondsSinceEpoch(startMs).year;
  final lastYear = DateTime.fromMillisecondsSinceEpoch(endMs - 1).year;
  for (var y = firstYear; y <= lastYear; y++) {
    final (os, oe) = annualOccurrence(t, y);
    final hit =
        oe == null ? (os >= startMs && os < endMs) : (os < endMs && oe > startMs);
    if (hit) return (os, oe);
  }
  return null;
}

/// 构建展示副本：年度任务平移到区间内的发生年，其余原样返回。
/// 无交集返回 null（调用方据此过滤）。
Task? displayOccurrence(Task t, int startMs, int endMs) {
  final occ = occurrenceOverlapping(t, startMs, endMs);
  if (occ == null) return null;
  if (!t.isAnnual) return t;
  return t.copyWith(startAt: () => occ.$1, endAt: () => occ.$2);
}


/// 自然周期区间，半开 [startMs, endMs)，单位毫秒。
class DateRange {
  final int startMs;
  final int endMs;

  const DateRange(this.startMs, this.endMs);
}

/// 今天的 [00:00, 次日 00:00)。
DateRange todayRange([DateTime? now]) {
  final n = now ?? DateTime.now();
  final start = DateTime(n.year, n.month, n.day);
  final end = DateTime(n.year, n.month, n.day + 1);
  return DateRange(start.millisecondsSinceEpoch, end.millisecondsSinceEpoch);
}

/// 本周的 [本周日 00:00, 下周日 00:00)。周从星期日开始，
/// 与日程月视图 Sunday→Saturday 一致。
DateRange thisWeekRange([DateTime? now]) {
  final n = now ?? DateTime.now();
  // DateTime.weekday：Monday=1 … Sunday=7；Sunday 是本周第 0 天。
  final start = DateTime(n.year, n.month, n.day - n.weekday % 7);
  final end = DateTime(start.year, start.month, start.day + 7);
  return DateRange(start.millisecondsSinceEpoch, end.millisecondsSinceEpoch);
}

/// 本月的 [1 日 00:00, 次月 1 日 00:00)。
DateRange thisMonthRange([DateTime? now]) {
  final n = now ?? DateTime.now();
  final start = DateTime(n.year, n.month);
  final end = DateTime(n.year, n.month + 1);
  return DateRange(start.millisecondsSinceEpoch, end.millisecondsSinceEpoch);
}

/// 本季度的 [季首月 1 日 00:00, 下季首月 1 日 00:00)。
DateRange thisQuarterRange([DateTime? now]) {
  final n = now ?? DateTime.now();
  final quarterStartMonth = ((n.month - 1) ~/ 3) * 3 + 1;
  final start = DateTime(n.year, quarterStartMonth);
  final end = DateTime(n.year, quarterStartMonth + 3);
  return DateRange(start.millisecondsSinceEpoch, end.millisecondsSinceEpoch);
}

/// 本年的 [1 月 1 日 00:00, 次年 1 月 1 日 00:00)。
DateRange thisYearRange([DateTime? now]) {
  final n = now ?? DateTime.now();
  return yearRange(n.year);
}

/// 指定年份的 [1 月 1 日 00:00, 次年 1 月 1 日 00:00)。
DateRange yearRange(int year) {
  return DateRange(DateTime(year).millisecondsSinceEpoch,
      DateTime(year + 1).millisecondsSinceEpoch);
}

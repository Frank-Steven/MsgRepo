import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/ui/schedule/layout.dart';

Task _task(String id, int startMs,
        {int? endMs, String title = '任务'}) =>
    Task(
      id: id,
      title: title,
      kind: endMs == null ? TaskKind.point : TaskKind.range,
      startAt: startMs,
      endAt: endMs,
      createdAt: 0,
      updatedAt: 0,
    );

int _ms(int year, int month, [int day = 1, int hour = 9, int minute = 0]) =>
    DateTime(year, month, day, hour, minute).millisecondsSinceEpoch;

void main() {
  group('layoutYearLane', () {
    test('泳道内按开始时间排序返回', () {
      final items = layoutYearLane([
        _task('b', _ms(2026, 6)),
        _task('a', _ms(2026, 2)),
        _task('c', _ms(2026, 10)),
      ], 2026);
      expect(items.map((e) => e.taskId), ['a', 'b', 'c']);
      // 互不重叠，全部占 slot 0
      expect(items.every((e) => e.slot == 0), isTrue);
    });

    test('被更早跨月线段占据的槽位跳过，继续往下排', () {
      final items = layoutYearLane([
        _task('line', _ms(2026, 1), endMs: _ms(2026, 4)), // 1-3 月线段
        _task('n1', _ms(2026, 2), endMs: _ms(2026, 3, 15)), // 2-3 月线段
        _task('n2', _ms(2026, 3)),
        _task('after', _ms(2026, 5)),
      ], 2026);
      final byId = {for (final e in items) e.taskId: e};
      expect(byId['line']!.slot, 0);
      expect(byId['n1']!.slot, 1); // slot 0 的 2 月被线段占据
      expect(byId['n2']!.slot, 2); // slot 0/1 的 3 月均被占据
      expect(byId['after']!.slot, 0); // 5 月空出，回到最上槽位
    });

    test('起点在上一年：钳制到 1 月并标记 extendsBefore', () {
      final items = layoutYearLane([
        _task('cross', _ms(2025, 11), endMs: _ms(2026, 3)),
      ], 2026);
      final e = items.single;
      expect(e.startMonth, 1);
      expect(e.endMonth, 3); // 结束于 3 月 1 日 09:00，覆盖进 3 月
      expect(e.extendsBefore, isTrue);
      expect(e.extendsAfter, isFalse);
    });

    test('终点在下一年：钳制到 12 月并标记 extendsAfter，本年不为其保留槽位', () {
      final items = layoutYearLane([
        _task('cross', _ms(2026, 10), endMs: _ms(2027, 3)),
        _task('nov', _ms(2026, 11)),
      ], 2026);
      final byId = {for (final e in items) e.taskId: e};
      expect(byId['cross']!.endMonth, 12);
      expect(byId['cross']!.extendsAfter, isTrue);
      // 11 月被本年钳制范围（10-12 月）占据，排到下一槽位
      expect(byId['nov']!.slot, 1);
      // 同一任务在 2027 年独立布局：占据最上面槽位
      final next = layoutYearLane([
        _task('cross', _ms(2026, 10), endMs: _ms(2027, 3)),
      ], 2027);
      expect(next.single.slot, 0);
      expect(next.single.extendsBefore, isTrue);
    });

    test('与本年无交集的任务不出现；时间点用起止同月节点语义', () {
      final items = layoutYearLane([
        _task('other', _ms(2025, 6)),
        _task('point', _ms(2026, 7, 15)),
      ], 2026);
      expect(items, hasLength(1));
      expect(items.single.startMonth, 7);
      expect(items.single.endMonth, 7);
    });

    test('结束恰为月初边界时归前一月', () {
      final items = layoutYearLane([
        _task('t', _ms(2026, 1, 10, 0, 0), endMs: _ms(2026, 3, 1, 0, 0)),
      ], 2026);
      expect(items.single.startMonth, 1);
      expect(items.single.endMonth, 2);
    });
  });

  group('assignDayNames', () {
    final day = DateTime(2026, 10, 12);
    int at(int hour, [int minute = 0]) =>
        DateTime(day.year, day.month, day.day, hour, minute)
            .millisecondsSinceEpoch;

    test('比例尺未达每 5 分钟一个节点时全部不可见', () {
      final slots = assignDayNames(
        [_task('a', at(9)), _task('b', at(14))],
        minutesPerNode: 10,
      );
      expect(slots, hasLength(2));
      expect(slots.every((e) => !e.visible), isTrue);
    });

    test('达到 5 分钟阈值且互不碰撞时可见', () {
      final slots = assignDayNames(
        [_task('a', at(9), title: '站会'), _task('b', at(14), title: '评审')],
        minutesPerNode: 5,
      );
      expect(slots.every((e) => e.visible), isTrue);
      expect(slots[0].centerMinutes, 9 * 60);
      expect(slots[1].centerMinutes, 14 * 60);
    });

    test('时间点任务锚点固定，与已放置文本碰撞则不显示名称', () {
      final slots = assignDayNames(
        [
          _task('a', at(9, 0), title: '晨会'),
          _task('b', at(9, 2), title: '讨论'), // 2 分钟后，斜文本带必然碰撞
        ],
        minutesPerNode: 5,
      );
      final byId = {for (final e in slots) e.taskId: e};
      expect(byId['a']!.visible, isTrue);
      expect(byId['b']!.visible, isFalse);
    });

    test('时间段任务在范围内找靠前空位', () {
      final slots = assignDayNames(
        [
          _task('a', at(9, 0), title: '晨会'),
          // 覆盖 09:00-10:00：锚点从 09:00 起按 5 分钟步进，09:00/09:05 均被
          // 晨会的斜文本带挡住，09:10 放得下
          _task('b', at(9, 0), endMs: at(10, 0), title: ' workshops '),
        ],
        minutesPerNode: 5,
      );
      final b = slots.firstWhere((e) => e.taskId == 'b');
      expect(b.visible, isTrue);
      expect(b.centerMinutes, 9 * 60 + 10);
    });

    test('标题过长超出名称层高度时不显示', () {
      final slots = assignDayNames(
        [_task('a', at(9), title: '这是一个名字特别特别长的任务标题啊啊啊')],
        minutesPerNode: 5,
      );
      expect(slots.single.visible, isFalse);
    });
  });

  group('dayTickInterval', () {
    test('最大缩放（每 5 分钟 48dp）：主刻度 15 分钟 + 5 分钟次刻度', () {
      final (major, minor, stride) = dayTickInterval(48 / 5);
      // 5*9.6=48 <64，15*9.6=144 ≥64
      expect(major, 15);
      expect(minor, 5);
      expect(stride, 1);
    });

    test('中等缩放：选「间距 ≥64dp」的最密档', () {
      // 15*2.8=42 <64，30*2.8=84 ≥64
      final (major, minor, stride) = dayTickInterval(2.8);
      expect(major, 30);
      expect(minor, 15);
      expect(stride, 1);
    });

    test('24h 恰好一屏：主刻度 120 分钟，标注隔一个显示', () {
      const ppm = 390 / 1440; // 120*ppm≈32.5 <64
      final (major, minor, stride) = dayTickInterval(ppm);
      expect(major, 120);
      expect(minor, 60);
      expect(stride, 2); // 2 的幂：32.5*2=65 ≥64
    });

    test('比例尺极小时次刻度省略、标注按 2 的幂继续隔档', () {
      final (major, minor, stride) = dayTickInterval(0.05);
      expect(major, 120);
      expect(minor, isNull); // 60*0.05=3 <6
      expect(stride, 16); // 120*0.05*16=96 ≥64
    });
  });
}

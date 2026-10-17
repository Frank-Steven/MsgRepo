import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/services/ai_client.dart';

/// P1-1 回归：point 任务只表示单个时刻，带 endAt 也不得被当成时间范围。
void main() {
  group('Task.overlaps', () {
    test('point 任务带脏 endAt 时仍按点判断', () {
      final t = Task(
        id: 't1',
        title: '交报告',
        kind: TaskKind.point,
        startAt: DateTime(2026, 10, 13, 9).millisecondsSinceEpoch,
        endAt: DateTime(2026, 10, 20).millisecondsSinceEpoch, // 脏数据
        createdAt: 0,
        updatedAt: 0,
      );
      final s = DateTime(2026, 10, 14).millisecondsSinceEpoch;
      final e = DateTime(2026, 10, 15).millisecondsSinceEpoch;
      // 按点：10-13 09:00 不在 [10-14, 10-15) 内
      expect(t.overlaps(s, e), isFalse);
      // 若按 range 处理（修复前），这里会为 true
    });

    test('range 任务照常按区间判断', () {
      final t = Task(
        id: 't2',
        title: '出差',
        kind: TaskKind.range,
        startAt: DateTime(2026, 10, 13).millisecondsSinceEpoch,
        endAt: DateTime(2026, 10, 20).millisecondsSinceEpoch,
        createdAt: 0,
        updatedAt: 0,
      );
      final s = DateTime(2026, 10, 14).millisecondsSinceEpoch;
      final e = DateTime(2026, 10, 15).millisecondsSinceEpoch;
      expect(t.overlaps(s, e), isTrue);
    });
  });

  group('AiTaskDraft.fromJson', () {
    test('kind=point 时丢弃模型多写的 endAt', () {
      final d = AiTaskDraft.fromJson({
        'title': '交报告',
        'kind': 'point',
        'startAt': '2026-10-20T10:00',
        'endAt': '2026-10-25T18:00',
        'priority': 'normal',
      });
      expect(d.kind, 'point');
      expect(d.startAt, DateTime(2026, 10, 20, 10, 0));
      expect(d.endAt, isNull, reason: 'point 不应保留 endAt');
    });

    test('kind=range 时保留 endAt', () {
      final d = AiTaskDraft.fromJson({
        'title': '出差',
        'kind': 'range',
        'startAt': '2026-10-20T10:00',
        'endAt': '2026-10-25T18:00',
      });
      expect(d.kind, 'range');
      expect(d.startAt, DateTime(2026, 10, 20, 10, 0));
      expect(d.endAt, DateTime(2026, 10, 25, 18, 0));
    });
  });
}

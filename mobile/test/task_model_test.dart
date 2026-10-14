import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/task.dart';

void main() {
  group('Task.parentId 序列化（v2.2）', () {
    test('toRow/fromRow 往返保留 parent_id', () {
      const t = Task(
        id: 'a',
        title: '子任务',
        kind: TaskKind.point,
        startAt: 1000,
        parentId: 'parent-1',
        createdAt: 0,
        updatedAt: 0,
      );
      final row = t.toRow();
      expect(row['parent_id'], 'parent-1');
      final restored = Task.fromRow(row);
      expect(restored.parentId, 'parent-1');
    });

    test('旧库行（无 parent_id 列）读出 null', () {
      final row = const Task(
        id: 'a',
        title: '任务',
        kind: TaskKind.point,
        createdAt: 0,
        updatedAt: 0,
      ).toRow()
        ..remove('parent_id');
      expect(Task.fromRow(row).parentId, isNull);
    });

    test('copyWith 置空 parentId 用 () => null', () {
      const t = Task(
        id: 'a',
        title: '子任务',
        kind: TaskKind.point,
        parentId: 'p',
        createdAt: 0,
        updatedAt: 0,
      );
      expect(t.copyWith(parentId: () => null).parentId, isNull);
      expect(t.copyWith(title: '改名').parentId, 'p');
      expect(t.copyWith(parentId: () => 'p2').parentId, 'p2');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/services/subtask_stats.dart';

Task _t(String id,
        {String? parentId, String status = TaskStatus.active}) =>
    Task(
      id: id,
      title: id,
      kind: TaskKind.point,
      parentId: parentId,
      status: status,
      createdAt: 0,
      updatedAt: 0,
    );

void main() {
  group('computeSubtaskProgress（设计 §3，v2.3）', () {
    test('统计直接子任务 done/总数', () {
      final progress = computeSubtaskProgress([
        _t('p1'),
        _t('c1', parentId: 'p1', status: TaskStatus.done),
        _t('c2', parentId: 'p1'),
        _t('c3', parentId: 'p1', status: TaskStatus.done),
        _t('p2'),
        _t('c4', parentId: 'p2'),
      ]);
      expect(progress['p1'], (2, 3));
      expect(progress['p2'], (0, 1));
    });

    test('无子任务的任务不出现在结果里', () {
      expect(computeSubtaskProgress([_t('a'), _t('b')]), isEmpty);
    });

    test('只算直接子任务：子任务的子任务（数据中不应存在）不计入祖父', () {
      final progress = computeSubtaskProgress([
        _t('grand'),
        _t('mid', parentId: 'grand'),
        _t('leaf', parentId: 'mid'),
      ]);
      expect(progress['grand'], (0, 1)); // 只计 mid
      expect(progress['mid'], (0, 1)); // 只计 leaf
    });

    test('archived 子任务计入总数但不计入完成数', () {
      final progress = computeSubtaskProgress([
        _t('c', parentId: 'p', status: TaskStatus.archived),
      ]);
      expect(progress['p'], (0, 1));
    });
  });
}

import '../models/task.dart';

/// 统计各父任务的直接子任务进度（设计 §3，v2.3）：
/// parentId -> (done 数, 总数)。只算直接子任务，不递归。
Map<String, (int, int)> computeSubtaskProgress(Iterable<Task> tasks) {
  final result = <String, (int, int)>{};
  for (final t in tasks) {
    final p = t.parentId;
    if (p == null) continue;
    final cur = result[p] ?? (0, 0);
    result[p] = (
      cur.$1 + (t.status == TaskStatus.done ? 1 : 0),
      cur.$2 + 1,
    );
  }
  return result;
}

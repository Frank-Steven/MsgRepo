import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../models/task.dart';
import '../../services/database.dart';
import '../../services/date_ranges.dart';
import '../../services/undo_service.dart';
import '../tasks/task_editor.dart';

/// 待办页（设计 §3）：单页分组列表，分组即全部视图。
class TodosPage extends StatefulWidget {
  const TodosPage({super.key});

  @override
  State<TodosPage> createState() => TodosPageState();
}

class TodosPageState extends State<TodosPage> {
  static const _recentWindow = Duration(hours: 24);
  static const _annualYearCount = 5;

  List<Task> _untimed = [];
  List<Task> _today = [];
  List<Task> _week = [];
  List<Task> _month = [];
  List<Task> _quarter = [];
  List<Task> _year = [];
  List<Task> _annual = [];
  List<Task> _done = [];
  List<Task> _archived = [];
  bool _loading = true;

  final _collapsed = <String>{};

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final db = AppDatabase.instance;
    final now = DateTime.now();
    final ranges = [
      todayRange(now),
      thisWeekRange(now),
      thisMonthRange(now),
      thisQuarterRange(now),
      thisYearRange(now),
    ];
    final results = await Future.wait([
      db.getUntimedTasks(),
      for (final r in ranges) db.getTasksOverlapping(r.startMs, r.endMs),
      db.getAnnualTasks(),
      db.getTasks(status: TaskStatus.done),
      db.getTasks(status: TaskStatus.archived),
    ]);
    final untimed = results[0];
    final annual = results[6];
    final done = results[7]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final archived = results[8]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    // getTasksOverlapping 无条件包含年度任务，这里按年平移其月日后再判交集
    final periods = [
      for (var i = 0; i < ranges.length; i++)
        results[1 + i]
            .where((t) =>
                !t.isAnnual || _annualHits(t, ranges[i].startMs, ranges[i].endMs))
            .toList(),
    ];
    if (!mounted) return;
    setState(() {
      _untimed = untimed;
      _today = periods[0];
      _week = periods[1];
      _month = periods[2];
      _quarter = periods[3];
      _year = periods[4];
      _annual = annual;
      _done = done;
      _archived = archived;
      _loading = false;
    });
  }

  /// 年度任务按 startAt 的月日平移到区间覆盖的每一年，判断是否有交集。
  bool _annualHits(Task t, int startMs, int endMs) {
    final s = t.startAt;
    if (s == null) return false;
    final start = DateTime.fromMillisecondsSinceEpoch(s);
    final durationMs = (t.endAt ?? s) - s;
    final firstYear = DateTime.fromMillisecondsSinceEpoch(startMs).year;
    final lastYear = DateTime.fromMillisecondsSinceEpoch(endMs - 1).year;
    for (var y = firstYear; y <= lastYear; y++) {
      final occ = DateTime(y, start.month, start.day, start.hour, start.minute,
          start.second, start.millisecond);
      final occMs = occ.millisecondsSinceEpoch;
      if (durationMs == 0) {
        if (occMs >= startMs && occMs < endMs) return true;
      } else if (occMs < endMs && occMs + durationMs > startMs) {
        return true;
      }
    }
    return false;
  }

  void _showUndoSnack(String label) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('$label · 10 秒内可撤销'),
        duration: const Duration(seconds: 10),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () async {
            await UndoService.instance.undoLatest();
            await reload();
          },
        ),
      ),
    );
  }

  /// 勾选完成/取消完成；有来源消息时联动归档/恢复（设计 §3 行内勾选）。
  Future<void> _toggleDone(Task task) async {
    final db = AppDatabase.instance;
    final completing = task.status != TaskStatus.done;
    final msgId = task.sourceMessageId;
    final oldMsgStatus =
        msgId == null ? null : (await db.getMessageById(msgId))?.status;
    await db.setTaskStatus(
        [task.id], completing ? TaskStatus.done : TaskStatus.active);
    if (msgId != null) {
      await db.updateMessageStatus([msgId],
          completing ? MessageStatus.archived : MessageStatus.processed);
    }
    UndoService.instance.register(
      label: completing ? '已完成' : '已恢复',
      undo: () async {
        await db.setTaskStatus([task.id], task.status);
        if (msgId != null && oldMsgStatus != null) {
          await db.updateMessageStatus([msgId], oldMsgStatus);
        }
      },
    );
    await reload();
    if (mounted) _showUndoSnack(completing ? '已完成' : '已恢复');
  }

  Future<void> _unarchive(Task task) async {
    final db = AppDatabase.instance;
    await db.setTaskStatus([task.id], TaskStatus.active);
    UndoService.instance.register(
      label: '已取出',
      undo: () => db.setTaskStatus([task.id], TaskStatus.archived),
    );
    await reload();
    if (mounted) _showUndoSnack('已取出');
  }

  Future<void> _createTask() async {
    final result = await showTaskEditor(context);
    final task = result?.task;
    if (result == null || result.deleted || task == null || !mounted) return;
    final db = AppDatabase.instance;
    await db.insertTask(task);
    UndoService.instance.register(
      label: '已新建',
      undo: () => db.deleteTasks([task.id]),
    );
    await reload();
    if (mounted) _showUndoSnack('已新建');
  }

  Future<void> _editTask(Task task) async {
    final result = await showTaskEditor(context, existing: task);
    if (result == null || !mounted) return;
    final db = AppDatabase.instance;
    if (result.deleted) {
      await db.deleteTasks([task.id]);
      UndoService.instance.register(
        label: '已删除',
        undo: () => db.insertTask(task),
      );
      await reload();
      if (mounted) _showUndoSnack('已删除');
    } else if (result.task != null) {
      await db.updateTask(result.task!);
      UndoService.instance.register(
        label: '已保存',
        undo: () => db.insertTask(task),
      );
      await reload();
      if (mounted) _showUndoSnack('已保存');
    }
  }

  Future<void> _showSourceMessage(String messageId) async {
    final msg = await AppDatabase.instance.getMessageById(messageId);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(msg?.title ?? '来源消息'),
        content: SingleChildScrollView(
            child: Text(msg == null ? '原文已不存在' : msg.body)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  List<Task> _annualSorted() {
    final list = [..._annual];
    list.sort((a, b) {
      final am = a.startAt;
      final bm = b.startAt;
      if (am == null && bm == null) return 0;
      if (am == null) return -1;
      if (bm == null) return 1;
      final da = DateTime.fromMillisecondsSinceEpoch(am);
      final dbb = DateTime.fromMillisecondsSinceEpoch(bm);
      final c = da.month.compareTo(dbb.month);
      return c != 0 ? c : da.day.compareTo(dbb.day);
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final currentYear = DateTime.now().year;
    return Scaffold(
      appBar: AppBar(
        title: const Text('待办'),
        actions: [
          IconButton(
            tooltip: '新建任务',
            onPressed: _createTask,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: reload,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (_loading)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              ..._groupSlivers('mine', '我的待办', _untimed),
              ..._groupSlivers('today', '今天', _today),
              ..._groupSlivers('week', '本周', _week),
              ..._groupSlivers('month', '本月', _month),
              ..._groupSlivers('quarter', '本季度', _quarter),
              ..._groupSlivers('year', '本年', _year),
              ..._annualSlivers(currentYear),
              ..._groupSlivers('done', '已完成', _done, kind: _GroupKind.done),
              ..._groupSlivers('archived', '已归档', _archived,
                  kind: _GroupKind.archived),
              const SliverToBoxAdapter(child: SizedBox(height: 32)),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _annualSlivers(int currentYear) {
    final collapsed = _collapsed.contains('annual');
    final sorted = _annualSorted();
    return [
      _headerSliver('annual', '年度任务', _annual.length),
      if (!collapsed)
        SliverList.builder(
          itemCount: _annualYearCount,
          itemBuilder: (context, i) {
            final year = currentYear + i;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(32, 8, 12, 2),
                  child: Text('$year',
                      style: Theme.of(context).textTheme.labelLarge),
                ),
                // 年度任务按 startAt 的月日在每年重复展示
                for (final task in sorted)
                  _TaskRow(
                    task: task,
                    onTap: () => _editTask(task),
                    onToggleDone: () => _toggleDone(task),
                    onShowSource: task.sourceMessageId == null
                        ? null
                        : () => _showSourceMessage(task.sourceMessageId!),
                  ),
              ],
            );
          },
        ),
    ];
  }

  List<Widget> _groupSlivers(String key, String title, List<Task> tasks,
      {_GroupKind kind = _GroupKind.active}) {
    final collapsed = _collapsed.contains(key);
    return [
      _headerSliver(key, title, tasks.length),
      if (!collapsed)
        tasks.isEmpty
            ? const SliverToBoxAdapter(child: _EmptyHint())
            : SliverList.builder(
                itemCount: tasks.length,
                itemBuilder: (context, i) {
                  final task = tasks[i];
                  return _TaskRow(
                    task: task,
                    archived: kind == _GroupKind.archived,
                    recent: kind == _GroupKind.done && _isRecent(task),
                    onTap: () => _editTask(task),
                    onToggleDone: kind == _GroupKind.archived
                        ? null
                        : () => _toggleDone(task),
                    onUnarchive: kind == _GroupKind.archived
                        ? () => _unarchive(task)
                        : null,
                    onShowSource: task.sourceMessageId == null
                        ? null
                        : () => _showSourceMessage(task.sourceMessageId!),
                  );
                },
              ),
    ];
  }

  bool _isRecent(Task task) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return now - task.updatedAt < _recentWindow.inMilliseconds;
  }

  Widget _headerSliver(String key, String title, int count) {
    // 不用 pinned: 多个固定吸顶头挤在视口顶部会产生非法 SliverGeometry
    //（layoutExtent > paintExtent）导致整个视口不绘制；分组头随内容滚动。
    return SliverPersistentHeader(
      delegate: _GroupHeaderDelegate(
        title: title,
        count: count,
        collapsed: _collapsed.contains(key),
        onToggle: () => setState(() {
          if (!_collapsed.remove(key)) _collapsed.add(key);
        }),
      ),
    );
  }
}

enum _GroupKind { active, done, archived }

class _GroupHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String title;
  final int count;
  final bool collapsed;
  final VoidCallback onToggle;

  _GroupHeaderDelegate({
    required this.title,
    required this.count,
    required this.collapsed,
    required this.onToggle,
  });

  @override
  double get minExtent => 44;

  @override
  double get maxExtent => 44;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(
                collapsed ? Icons.chevron_right : Icons.expand_more,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(width: 8),
              Text('$count',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_GroupHeaderDelegate oldDelegate) => true;
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 6, 12, 6),
      child:
          Text('无', style: TextStyle(color: scheme.onSurfaceVariant)),
    );
  }
}

Color _priorityColor(String priority) => switch (priority) {
      TaskPriority.important => Colors.red,
      TaskPriority.minor => Colors.green,
      _ => Colors.amber,
    };

String _two(int v) => v.toString().padLeft(2, '0');

String _fmtMs(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
}

String _timeSummary(Task task) {
  final s = task.startAt;
  if (s == null) return '—';
  if (task.kind == TaskKind.range && task.endAt != null) {
    return '${_fmtMs(s)} → ${_fmtMs(task.endAt!)}';
  }
  return _fmtMs(s);
}

class _TaskRow extends StatelessWidget {
  final Task task;
  final bool archived;
  final bool recent;
  final VoidCallback onTap;
  final VoidCallback? onToggleDone;
  final VoidCallback? onUnarchive;
  final VoidCallback? onShowSource;

  const _TaskRow({
    required this.task,
    this.archived = false,
    this.recent = false,
    required this.onTap,
    this.onToggleDone,
    this.onUnarchive,
    this.onShowSource,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final done = task.status == TaskStatus.done;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (!archived)
              GestureDetector(
                onTap: onToggleDone,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: done ? scheme.primary : Colors.transparent,
                    border: Border.all(
                      width: 2,
                      color: done ? scheme.primary : scheme.outline,
                    ),
                  ),
                  child: done
                      ? Icon(Icons.check, size: 14, color: scheme.onPrimary)
                      : null,
                ),
              ),
            if (!archived) const SizedBox(width: 10),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _priorityColor(task.priority),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          task.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            decoration:
                                done ? TextDecoration.lineThrough : null,
                            color: done ? scheme.onSurfaceVariant : null,
                          ),
                        ),
                      ),
                      if (recent) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('最近',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: scheme.onPrimaryContainer)),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    _timeSummary(task),
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (onShowSource != null)
              IconButton(
                tooltip: '查看来源消息',
                visualDensity: VisualDensity.compact,
                onPressed: onShowSource,
                icon: Icon(Icons.message_outlined,
                    size: 18, color: scheme.onSurfaceVariant),
              ),
            if (onUnarchive != null)
              IconButton(
                tooltip: '取出',
                visualDensity: VisualDensity.compact,
                onPressed: onUnarchive,
                icon: Icon(Icons.unarchive_outlined,
                    size: 20, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

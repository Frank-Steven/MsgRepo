import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../models/task.dart';
import '../../services/database.dart';
import '../../services/task_scale.dart';
import '../../services/undo_service.dart';
import '../messages/message_widgets.dart';

/// 勾选完成/取消完成并注册撤销（设计 §3 行内勾选；待办页/日程页底部板块共用）。
/// 有来源消息时联动归档/恢复。
Future<void> toggleTaskDoneWithUndo(
  BuildContext context,
  Task task, {
  required Future<void> Function() onChanged,
}) async {
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
  await onChanged();
  if (context.mounted) {
    showUndoSnackBar(context, completing ? '已完成' : '已恢复',
        onUndone: () async => onChanged());
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

/// 任务行（设计 §3；待办页/日程页底部板块共用）：勾选圆框 + 优先级点 +
/// 标题 + 尺度徽标 + 时间摘要 + 来源/归档按钮。子任务用 [indent] 缩进；
/// 有子任务的父行显示折叠箭头（[onToggleCollapse]）。
class TaskTile extends StatelessWidget {
  final Task task;
  final bool archived;
  final bool recent;

  /// 子任务缩进宽度（0 = 顶级行）。
  final double indent;

  /// 是否有子任务（true 时显示折叠箭头）。
  final bool hasChildren;
  final bool collapsed;
  final VoidCallback? onToggleCollapse;
  final VoidCallback onTap;
  final VoidCallback? onToggleDone;
  final VoidCallback? onUnarchive;
  final VoidCallback? onShowSource;

  const TaskTile({
    super.key,
    required this.task,
    this.archived = false,
    this.recent = false,
    this.indent = 0,
    this.hasChildren = false,
    this.collapsed = false,
    this.onToggleCollapse,
    required this.onTap,
    this.onToggleDone,
    this.onUnarchive,
    this.onShowSource,
  });

  /// 行内尺度徽标（设计 §3）：派生尺度小字 chip。
  Widget _scaleChip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scale = deriveTaskScale(task.startAt, task.endAt);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        timeScaleLabel(scale),
        style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final done = task.status == TaskStatus.done;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.only(left: 12 + indent, right: 12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (hasChildren)
                GestureDetector(
                  onTap: onToggleCollapse,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Icon(
                      collapsed ? Icons.chevron_right : Icons.expand_more,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
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
                        const SizedBox(width: 6),
                        _scaleChip(context),
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
      ),
    );
  }
}

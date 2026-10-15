import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../models/task.dart';
import '../../services/database.dart';
import '../../services/task_scale.dart';
import '../shared/priority_dot.dart';
import 'task_tile.dart';

/// 任务详情面板（设计 §3/§7，v2.3；v2.5 内嵌统一）：待办页与日程页底部
/// 面板共用同一组件（列表模式/详情模式互斥切换，不再是底部弹出抽屉）。
///
/// 内容：名称、尺度徽标、优先级色点、时间、描述；父任务条目、来源消息
/// （可点查看原文）、子任务列表（含完成进度）；右上角编辑图标进编辑器。
/// [onClose] 非空时左上角显示返回按钮（关闭详情回列表模式）。
/// 父/子任务条目点击经 [onOpenTask] 回调，由宿主决定跳转逻辑
/// （待办页 = 切页签并高亮；日程页 = 跳到所在尺度视图并选中）。
class TaskDetailPanel extends StatefulWidget {
  final Task task;

  /// 右上角编辑图标。
  final VoidCallback onEdit;

  /// 点击父任务/子任务条目。
  final ValueChanged<Task>? onOpenTask;

  /// 左上角关闭（返回列表模式）；null 不显示。
  final VoidCallback? onClose;

  const TaskDetailPanel({
    super.key,
    required this.task,
    required this.onEdit,
    this.onOpenTask,
    this.onClose,
  });

  @override
  State<TaskDetailPanel> createState() => _TaskDetailPanelState();
}

class _TaskDetailPanelState extends State<TaskDetailPanel> {
  Task? _parent;
  List<Task> _children = [];
  Message? _source;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(TaskDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.id != widget.task.id ||
        oldWidget.task.updatedAt != widget.task.updatedAt) {
      _load();
    }
  }

  Future<void> _load() async {
    final db = AppDatabase.instance;
    final t = widget.task;
    final parent =
        t.parentId == null ? null : await db.getTaskById(t.parentId!);
    final children = await db.getChildTasks(t.id);
    final source = t.sourceMessageId == null
        ? null
        : await db.getMessageById(t.sourceMessageId!);
    if (!mounted) return;
    setState(() {
      _parent = parent;
      _children = children;
      _source = source;
      _loaded = true;
    });
  }

  void _showSourceDialog() {
    final msg = _source;
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

  Widget _scaleChip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        timeScaleLabel(deriveTaskScale(
            widget.task.startAt, widget.task.endAt)),
        style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
      ),
    );
  }

  Widget _taskLinkRow(BuildContext context, Task t) {
    final scheme = Theme.of(context).colorScheme;
    final done = t.status == TaskStatus.done;
    return InkWell(
      onTap: widget.onOpenTask == null ? null : () => widget.onOpenTask!(t),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: taskPriorityDotColor(t.priority),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                t.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  decoration: done ? TextDecoration.lineThrough : null,
                  color: done ? scheme.onSurfaceVariant : null,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              taskTimeSummary(t),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (widget.onOpenTask != null)
              Icon(Icons.chevron_right,
                  size: 16, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = widget.task;
    final done = t.status == TaskStatus.done;
    final doneCount =
        _children.where((c) => c.status == TaskStatus.done).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (widget.onClose != null)
                IconButton(
                  tooltip: '返回列表',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.arrow_back, size: 20),
                ),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: taskPriorityDotColor(t.priority),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        decoration:
                            done ? TextDecoration.lineThrough : null,
                      ),
                ),
              ),
              IconButton(
                tooltip: '编辑',
                visualDensity: VisualDensity.compact,
                onPressed: widget.onEdit,
                icon: const Icon(Icons.edit_outlined, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _scaleChip(context),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  taskTimeSummary(t),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          if (t.description != null && t.description!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(t.description!,
                style: Theme.of(context).textTheme.bodySmall),
          ],
          if (!_loaded)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Center(
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            ),
          if (_parent != null) ...[
            const SizedBox(height: 8),
            Text('父任务', style: Theme.of(context).textTheme.labelLarge),
            _taskLinkRow(context, _parent!),
          ],
          if (t.sourceMessageId != null) ...[
            const SizedBox(height: 8),
            InkWell(
              onTap: _showSourceDialog,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.message_outlined,
                        size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _source?.title ?? '来源消息（原文已不存在）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    Icon(Icons.chevron_right,
                        size: 16, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ],
          if (_children.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('子任务 $doneCount/${_children.length}',
                style: Theme.of(context).textTheme.labelLarge),
            for (final c in _children) _taskLinkRow(context, c),
          ],
        ],
      ),
    );
  }
}

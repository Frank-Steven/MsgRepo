import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../models/message.dart';
import '../../models/task.dart';
import '../../services/ai_client.dart';
import '../../services/database.dart';
import '../../services/undo_service.dart';
import 'message_widgets.dart';

/// 从消息页升起「AI 处理中」面板（设计 §8.3）：实时滚动原始输出 → 完成后汇总确认。
/// [onChanged] 在数据落库或撤销后回调（消息页 reload）。
Future<void> showAiProcessPanel(
  BuildContext context,
  List<Message> messages, {
  VoidCallback? onChanged,
}) {
  return showModalBottomSheet(
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    builder: (_) => AiProcessPanel(messages: messages, onChanged: onChanged),
  );
}

class _Outcome {
  final Message message;
  AiProcessResult? result;
  String? error;
  bool confirmed = false;

  /// 汇总页勾选状态（v2.4：checkbox + 「确认选中」）；默认勾选。
  bool checked = true;

  _Outcome(this.message);
}

class AiProcessPanel extends StatefulWidget {
  final List<Message> messages;
  final VoidCallback? onChanged;

  const AiProcessPanel({super.key, required this.messages, this.onChanged});

  @override
  State<AiProcessPanel> createState() => _AiProcessPanelState();
}

class _AiProcessPanelState extends State<AiProcessPanel> {
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  final _scroll = ScrollController();

  /// 每条消息的流式原始输出（v2.4 卡片化：各自独立成卡）。
  final Map<String, StringBuffer> _rawById = {};
  late final List<_Outcome> _outcomes;

  StreamSubscription<AiEvent>? _sub;
  bool _running = true;
  String? _currentId;
  String? _fatalError;

  int get _doneCount =>
      _outcomes.where((o) => o.result != null || o.error != null).length;
  int get _resultCount => _outcomes.where((o) => o.result != null).length;
  int get _junkCount => _outcomes
      .where((o) => o.result?.priority == MessagePriority.junk)
      .length;
  int get _draftCount =>
      _outcomes.where((o) => o.result?.taskDraft != null).length;
  int get _failCount => _outcomes.where((o) => o.error != null).length;
  int get _unconfirmedCount =>
      _outcomes.where((o) => o.result != null && !o.confirmed).length;

  /// 勾选且待确认的条数（v2.4「确认选中」）。
  int get _checkedCount => _outcomes
      .where((o) => o.result != null && !o.confirmed && o.checked)
      .length;

  @override
  void initState() {
    super.initState();
    _outcomes = [for (final m in widget.messages) _Outcome(m)];
    if (widget.messages.isNotEmpty) _currentId = widget.messages.first.id;
    _sub = AiClient.instance.process(widget.messages).listen(
      _onEvent,
      onError: (Object e) => setState(() {
        _running = false;
        _fatalError = '$e';
      }),
      onDone: () {
        if (mounted) setState(() => _running = false);
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onEvent(AiEvent ev) {
    if (!mounted) return;
    setState(() {
      switch (ev) {
        case AiTokenDelta(:final messageId, :final delta):
          _currentId = messageId;
          _rawById.putIfAbsent(messageId, StringBuffer.new).write(delta);
          _scrollToEnd();
        case AiMessageResult(:final result):
          _outcomeOf(result.messageId)?.result = result;
        case AiMessageError(:final messageId, :final error):
          _outcomeOf(messageId)?.error = error;
        case AiAllDone():
          _running = false;
      }
    });
  }

  _Outcome? _outcomeOf(String messageId) {
    for (final o in _outcomes) {
      if (o.message.id == messageId) return o;
    }
    return null;
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  /// 取消：中断流，已产出的结果保留在汇总面板。
  Future<void> _cancel() async {
    AiClient.instance.cancelActive();
    await _sub?.cancel();
    if (mounted) setState(() => _running = false);
  }

  void _showUndoSnack(String label) {
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(label),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () async {
              _messengerKey.currentState?.hideCurrentSnackBar();
              await UndoService.instance.undoLatest();
              widget.onChanged?.call();
            },
          ),
        ),
      );
  }

  /// 确认 = 写回 priority + status(processed)；有任务草稿则建任务并互链。
  /// 每次确认作为一个复合逆操作进撤销队列（设计 §5.2/§6）。
  Future<void> _confirm(List<_Outcome> targets) async {
    final db = AppDatabase.instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    final undoItems = <({
      String messageId,
      String oldPriority,
      String oldStatus,
      String? oldLinkedTaskId,
      String? createdTaskId,
    })>[];
    for (final o in targets) {
      final r = o.result;
      if (r == null || o.confirmed) continue;
      final m = o.message;
      String? taskId;
      final draft = r.taskDraft;
      if (draft != null && draft.title.isNotEmpty) {
        final task = Task(
          id: const Uuid().v4(),
          title: draft.title,
          description: draft.description,
          kind: draft.kind,
          startAt: draft.startAt?.millisecondsSinceEpoch,
          endAt: draft.endAt?.millisecondsSinceEpoch,
          priority: draft.priority,
          sourceMessageId: m.id,
          status: TaskStatus.active,
          createdAt: now,
          updatedAt: now,
        );
        await db.insertTask(task);
        taskId = task.id;
      }
      await db.updateMessagePriority([m.id], r.priority);
      await db.updateMessageStatus([m.id], MessageStatus.processed);
      await db.setMessageLinkedTask(m.id, taskId);
      undoItems.add((
        messageId: m.id,
        oldPriority: m.priority,
        oldStatus: m.status,
        oldLinkedTaskId: m.linkedTaskId,
        createdTaskId: taskId,
      ));
      o.confirmed = true;
    }
    if (undoItems.isEmpty) return;
    final count = undoItems.length;
    UndoService.instance.register(
      label: '已确认 $count 条 AI 结果',
      undo: () async {
        for (final u in undoItems.reversed) {
          final taskId = u.createdTaskId;
          if (taskId != null) await db.deleteTasks([taskId]);
          await db.updateMessagePriority([u.messageId], u.oldPriority);
          await db.updateMessageStatus([u.messageId], u.oldStatus);
          await db.setMessageLinkedTask(u.messageId, u.oldLinkedTaskId);
        }
      },
    );
    widget.onChanged?.call();
    if (mounted) setState(() {});
    _showUndoSnack('已确认 $count 条 AI 结果');
  }

  // ---- UI ----

  Color _priorityColor(ColorScheme cs, String priority) =>
      messageGroupDotColor(priority) ?? cs.outline;

  String _taskPriorityLabel(String priority) => switch (priority) {
        TaskPriority.important => '重要',
        TaskPriority.minor => '不重要',
        _ => '一般',
      };

  String _draftSummary(AiTaskDraft draft) {
    final parts = <String>[draft.title];
    final start = draft.startAt;
    if (start != null) {
      var t = formatMessageTime(start.millisecondsSinceEpoch);
      final end = draft.endAt;
      if (end != null) {
        t += ' ~ ${formatMessageTime(end.millisecondsSinceEpoch)}';
      }
      parts.add(t);
    }
    parts.add(_taskPriorityLabel(draft.priority));
    return parts.join(' · ');
  }

  Widget _buildProcessing() {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Expanded(
              child: Text('AI 处理中',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            Text('已完成 $_doneCount/共 ${widget.messages.length} 条',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
            TextButton(onPressed: _cancel, child: const Text('取消')),
          ],
        ),
        const SizedBox(height: 8),
        // 每条消息一张状态卡片（v2.4）：等待/处理中/完成/失败图标 + 标题；
        // 处理中卡片内滚动显示该条的流式输出（等宽字体），完成后折叠为摘要。
        Expanded(
          child: ListView(
            controller: _scroll,
            children: [for (final o in _outcomes) _buildProcessingCard(o)],
          ),
        ),
      ],
    );
  }

  Widget _buildProcessingCard(_Outcome o) {
    final cs = Theme.of(context).colorScheme;
    final m = o.message;
    final title = m.title.isEmpty ? '(无标题)' : m.title;
    final isCurrent = o.message.id == _currentId &&
        o.result == null &&
        o.error == null &&
        _running;

    final Widget statusIcon;
    if (o.error != null) {
      statusIcon = Icon(Icons.error_outline, size: 20, color: cs.error);
    } else if (o.result != null) {
      statusIcon =
          Icon(Icons.check_circle, size: 20, color: Colors.green.shade600);
    } else if (isCurrent) {
      statusIcon = const SizedBox(
          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2));
    } else {
      statusIcon = Icon(Icons.schedule, size: 20, color: cs.outline);
    }

    final raw = _rawById[o.message.id]?.toString() ?? '';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      elevation: 0,
      color: cs.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                statusIcon,
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                if (o.result != null) ...[
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _priorityColor(cs, o.result!.priority),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ),
            if (isCurrent && raw.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 160),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                // reverse 让内容贴底，新 token 自动可见，无需手动滚到底
                child: SingleChildScrollView(
                  reverse: true,
                  child: Text(
                    raw,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ] else if (o.result != null) ...[
              const SizedBox(height: 2),
              Text(
                [
                  if (o.result!.reason.isNotEmpty) o.result!.reason,
                  if (o.result!.taskDraft != null)
                    '任务草稿：${_draftSummary(o.result!.taskDraft!)}',
                ].join('；'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ] else if (o.error != null) ...[
              const SizedBox(height: 2),
              Text(o.error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: cs.error)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildOutcomeTile(_Outcome o) {
    final cs = Theme.of(context).colorScheme;
    final m = o.message;
    final error = o.error;
    final result = o.result;
    final title = m.title.isEmpty ? '(无标题)' : m.title;

    if (error != null) {
      return ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.error_outline, color: cs.error),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(error, maxLines: 2, overflow: TextOverflow.ellipsis),
      );
    }
    if (result == null) {
      return ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: cs.outline)),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: const Text('未完成'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // v2.4：checkbox 勾选决定「确认选中」的批量范围；已确认显示对勾
            if (o.confirmed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Icon(Icons.check_circle, color: cs.primary, size: 20),
              )
            else
              SizedBox(
                width: 32,
                height: 32,
                child: Checkbox(
                  value: o.checked,
                  visualDensity: VisualDensity.compact,
                  onChanged: (v) =>
                      setState(() => o.checked = v ?? false),
                ),
              ),
            const SizedBox(width: 6),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _priorityColor(cs, result.priority),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w500)),
                  if (result.reason.isNotEmpty)
                    Text(result.reason,
                        style: TextStyle(
                            fontSize: 13, color: cs.onSurfaceVariant)),
                  if (result.taskDraft != null)
                    Text('任务草稿：${_draftSummary(result.taskDraft!)}',
                        style: TextStyle(fontSize: 13, color: cs.primary)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildSummary() {
    final cs = Theme.of(context).colorScheme;
    final parts = <String>[
      '评估 $_resultCount 条',
      '垃圾 $_junkCount 条',
      '任务草稿 $_draftCount 条',
      if (_failCount > 0) '失败 $_failCount 条',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('处理结果',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            if (_unconfirmedCount > 0)
              TextButton(
                onPressed: () {
                  // 全选 / 全不选切换（只作用于未确认且有结果的条目）
                  final anyUnchecked = _outcomes.any(
                      (o) => o.result != null && !o.confirmed && !o.checked);
                  setState(() {
                    for (final o in _outcomes) {
                      if (o.result != null && !o.confirmed) {
                        o.checked = anyUnchecked;
                      }
                    }
                  });
                },
                child: Text(_checkedCount < _unconfirmedCount
                    ? '全选'
                    : '全不选'),
              ),
            FilledButton(
              onPressed: _checkedCount == 0
                  ? null
                  : () => _confirm([
                        for (final o in _outcomes)
                          if (o.result != null && !o.confirmed && o.checked) o,
                      ]),
              child: Text(_checkedCount == 0
                  ? '确认选中'
                  : '确认选中（$_checkedCount）'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(parts.join(' / '),
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
        if (_fatalError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child:
                Text(_fatalError!, style: TextStyle(fontSize: 13, color: cs.error)),
          ),
        const Divider(height: 16),
        Expanded(
          child: ListView(
            children: [for (final o in _outcomes) _buildOutcomeTile(o)],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.8;
    // showModalBottomSheet 会从 MediaQuery 移除顶部 padding（removeTop: true），
    // 普通 SafeArea 拿不到状态栏高度，需直接从 View 读取。
    final topPad = MediaQueryData.fromView(View.of(context)).padding.top;
    return ScaffoldMessenger(
      key: _messengerKey,
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: Padding(
          padding: EdgeInsets.only(top: topPad),
          child: SizedBox(
            height: height - topPad,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: _running ? _buildProcessing() : _buildSummary(),
            ),
          ),
        ),
      ),
    );
  }
}

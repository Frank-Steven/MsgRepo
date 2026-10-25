import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../services/fold_markers.dart';
import '../../models/task.dart';
import '../../services/ai_client.dart';
import '../../services/ai_processing.dart';
import 'message_widgets.dart';

/// 从消息页升起「AI 处理中」面板（设计 §8.3）：实时滚动原始输出 → 完成后汇总确认。
/// 会话状态常驻 [AiProcessingService]（v2.6.2 后台处理），面板只是它的视图——
/// 收起（「后台」按钮）处理继续，重开看到同一会话。
/// [onChanged] 在数据落库或撤销后回调（消息页 reload）。
Future<void> showAiProcessPanel(
  BuildContext context, {
  VoidCallback? onChanged,

  /// true = 由「未处理达到阈值」自动触发（面板标题会标出来，便于区分）。
  bool auto = false,
}) {
  return showModalBottomSheet(
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    builder: (_) => AiProcessPanel(onChanged: onChanged, auto: auto),
  );
}

class AiProcessPanel extends StatefulWidget {
  final VoidCallback? onChanged;
  final bool auto;

  const AiProcessPanel({super.key, this.onChanged, this.auto = false});

  @override
  State<AiProcessPanel> createState() => _AiProcessPanelState();
}

class _AiProcessPanelState extends State<AiProcessPanel> {
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  final _scroll = ScrollController();

  AiProcessingService get _svc => AiProcessingService.instance;
  int _tokenRevision = 0;

  AiProcessingSession? get _session => _svc.session;

  @override
  void initState() {
    super.initState();
    _tokenRevision = _svc.tokenRevision;
    _svc.attachPanel();
    _svc.addListener(_onService);
  }

  @override
  void dispose() {
    _svc.removeListener(_onService);
    _svc.detachPanel();
    _scroll.dispose();
    super.dispose();
  }

  void _onService() {
    if (!mounted) return;
    final session = _session;
    if (session == null) {
      // 会话被清空（别处关闭/收尾），面板随之退出
      Navigator.of(context).maybePop();
      return;
    }
    if (_svc.tokenRevision != _tokenRevision) {
      _tokenRevision = _svc.tokenRevision;
      _scrollToEnd();
    }
    setState(() {});
  }

  DateTime _lastScrollAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 流式输出时跟随到底部：节流 300ms，且只在用户本来就贴着底部时才跟随
  /// （每个 token 都 jumpTo 会在上千条的 builder 列表里反复触发布局，是 ANR 的帮凶）。
  void _scrollToEnd() {
    final now = DateTime.now();
    if (now.difference(_lastScrollAt).inMilliseconds < 300) return;
    _lastScrollAt = now;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      if (pos.maxScrollExtent - pos.pixels > 400) return; // 用户上滑看历史时不抢
      _scroll.jumpTo(pos.maxScrollExtent);
    });
  }

  /// 后台（v2.6.2）：收起面板，处理在服务层继续；消息页顶部有全局指示可回来。
  void _goBackground() => Navigator.of(context).pop();

  /// 取消：中断流，已产出的结果保留在汇总面板。
  Future<void> _cancel() => _svc.cancel();

  void _showUndoSnack(String label) {
    showUndoSnackBar(context, label,
        messenger: _messengerKey.currentState,
        onUndone: () => widget.onChanged?.call());
  }

  /// 确认选中：写库委托服务层（复合撤销在服务层注册），面板负责提示与刷新。
  Future<void> _confirm(List<AiOutcome> targets) async {
    final count = await _svc.confirm(targets);
    if (count == 0) return;
    widget.onChanged?.call();
    _showUndoSnack('已确认 $count 条 AI 结果');
  }

  /// 不采用 / 驳回选中（A02，用户 2026-10-20 确认语义）：丢弃这批 AI 结果、
  /// 消息退回未处理，不落库、不建任务。走服务层纯内存 [AiProcessingService.discard]，
  /// 与「确认选中」共用同一作用范围（checkbox 选中的待确认结果）。
  ///
  /// 与确认不同，丢弃没有可撤销的写操作，所以二次确认用普通对话框而不是撤销
  /// SnackBar —— 一旦丢弃只能重新发起 AI 处理。
  Future<void> _discard(List<AiOutcome> targets) async {
    final n = targets.where((o) => o.result != null).length;
    if (n == 0) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('不采用这些 AI 结果？'),
        content: Text('丢弃 $n 条 AI 结果，消息退回未处理，不建任务。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('丢弃')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final count = _svc.discard(targets);
    if (count == 0) return;
    widget.onChanged?.call();
    _toastDiscarded(count);
  }

  /// 不采用后的提示。
  ///
  /// 丢弃会把选中的待确认结果移出会话；若因此清空会话，面板会立刻自动收起
  /// （_onService 里的 maybePop），面板内嵌的 ScaffoldMessenger 随路由销毁，
  /// 提示会丢 —— 此时退回页面级 messenger。
  void _toastDiscarded(int count) {
    final text = '已丢弃 $count 条 AI 结果（消息保持未处理）';
    final inner = _messengerKey.currentState;
    if (_session != null && inner != null) {
      inner.hideCurrentSnackBar();
      inner.showSnackBar(SnackBar(content: Text(text)));
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  /// 关闭：交由服务层收尾（队列空且无待确认结果才清空会话；否则会话保留，
  /// 消息页入口可回来继续确认/观看进度）。
  void _close() {
    _svc.closePanel();
    Navigator.of(context).pop();
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

  Widget _buildProcessing(AiProcessingSession session) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AiProcessingHeader(
          settled: session.settledCount,
          enqueued: session.enqueuedCount,
          pending: session.pendingConfirmCount,
          onCancel: _cancel,
          onBackground: _goBackground,
        ),
        const SizedBox(height: 8),
        // 每条消息一张状态卡片（v2.4）：等待/处理中/完成/失败图标 + 标题；
        // 处理中卡片内滚动显示该条的流式输出（等宽字体），完成后折叠为摘要。
        // O02：上千条时 ListView(children:) 会在一帧里建出全部卡片 → ANR。
        // （2026-10-20 复核：40cd25a 只改了跟随滚动，没改这里；历史上从未出现 builder）
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            itemCount: session.outcomes.length,
            itemBuilder: (context, i) =>
                _buildProcessingCard(session, session.outcomes[i]),
          ),
        ),
      ],
    );
  }

  Widget _buildProcessingCard(AiProcessingSession session, AiOutcome o) {
    final cs = Theme.of(context).colorScheme;
    final m = o.message;
    // U14：展示层剥离折叠后缀，数据层保持原样
    final title = m.title.isEmpty ? '(无标题)' : stripFoldMarkers(m.title);
    final isCurrent = o.message.id == session.currentId &&
        o.result == null &&
        o.error == null &&
        session.running;

    final Widget statusIcon;
    if (o.error != null) {
      statusIcon = Icon(Icons.error_outline, size: 20, color: cs.error);
    } else if (o.result != null) {
      statusIcon =
          Icon(Icons.check_circle, size: 20, color: Colors.green.shade600);
    } else if (isCurrent) {
      statusIcon = const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2));
    } else {
      statusIcon = Icon(Icons.schedule, size: 20, color: cs.outline);
    }

    final raw = session.rawById[o.message.id]?.toString() ?? '';

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
                  child:
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
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

  Widget _buildOutcomeTile(AiOutcome o) {
    final cs = Theme.of(context).colorScheme;
    final m = o.message;
    final error = o.error;
    final result = o.result;
    // U14：展示层剥离折叠后缀，数据层保持原样
    final title = m.title.isEmpty ? '(无标题)' : stripFoldMarkers(m.title);

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
            child:
                CircularProgressIndicator(strokeWidth: 2, color: cs.outline)),
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
            // v2.4：checkbox 勾选决定「确认选中」的批量范围；
            // v2.6.4：确认过的条目已从列表移除，剩下的都待确认
            SizedBox(
              width: 32,
              height: 32,
              child: Checkbox(
                value: o.checked,
                visualDensity: VisualDensity.compact,
                onChanged: (v) => setState(() => o.checked = v ?? false),
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

  Widget _buildSummary(AiProcessingSession session) {
    final cs = Theme.of(context).colorScheme;
    final outcomes = session.outcomes;
    final resultCount = outcomes.where((o) => o.result != null).length;
    final junkCount = outcomes
        .where((o) => o.result?.priority == MessagePriority.junk)
        .length;
    final draftCount =
        outcomes.where((o) => o.result?.taskDraft != null).length;
    // v2.6.4：确认过的条目已从列表移除，列表里有结果的条目都待确认
    final pendingCount = session.pendingConfirmCount;
    final checkedCount =
        outcomes.where((o) => o.result != null && o.checked).length;
    final parts = <String>[
      '评估 $resultCount 条',
      '垃圾 $junkCount 条',
      '任务草稿 $draftCount 条',
      if (session.failCount > 0) '失败 ${session.failCount} 条',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child:
                  Text('处理结果', style: Theme.of(context).textTheme.titleMedium),
            ),
            if (pendingCount > 0)
              TextButton(
                onPressed: () {
                  // 全选 / 全不选切换（只作用于有结果的待确认条目）
                  final anyUnchecked =
                      outcomes.any((o) => o.result != null && !o.checked);
                  setState(() {
                    for (final o in outcomes) {
                      if (o.result != null) {
                        o.checked = anyUnchecked;
                      }
                    }
                  });
                },
                child: Text(checkedCount < pendingCount ? '全选' : '全不选'),
              ),
            TextButton(
              onPressed: _close,
              child: Text(pendingCount > 0 ? '稍后确认' : '关闭'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(parts.join(' / '),
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
        // A02：批量操作单独一行。「确认选中」与新增的「不采用」作用范围完全相同
        // （checkbox 选中的待确认结果），二者并排且同时受 checkedCount 控制；
        // 原来「确认选中 / 稍后确认」与标题挤在同一行，再加一个按钮在窄屏或大
        // 字号下必然溢出（与 U9 头部同一类问题），故拆成两行。
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton(
              onPressed: checkedCount == 0
                  ? null
                  : () => _confirm([
                        for (final o in outcomes)
                          if (o.result != null && o.checked) o,
                      ]),
              child: Text(checkedCount == 0 ? '确认选中' : '确认选中（$checkedCount）'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: checkedCount == 0
                  ? null
                  : () => _discard([
                        for (final o in outcomes)
                          if (o.result != null && o.checked) o,
                      ]),
              child: Text(checkedCount == 0 ? '不采用' : '不采用（$checkedCount）'),
            ),
          ],
        ),
        const Divider(height: 16),
        // O02：同上，汇总页也惰性渲染。
        Expanded(
          child: ListView.builder(
            itemCount: outcomes.length,
            itemBuilder: (context, i) => _buildOutcomeTile(outcomes[i]),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
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
              child: session == null
                  ? const Center(child: Text('没有进行中的 AI 处理'))
                  : session.running
                      ? _buildProcessing(session)
                      : _buildSummary(session),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「AI 处理中」头部（U9 神秘排版修复）：标题与计数分成两行。
///
/// 修复前的结构是 Row[spinner, Expanded(标题), 计数, 取消, 后台]：计数与两个按钮
/// 是固定宽度，窄屏或大字号下会把剩余宽度吃光，Expanded 分到 0 宽 —— 标题于是
/// 逐字换行变成竖排，并溢出压到下一行的进度文字上（真机截图所见）。
/// 现在计数单独一行、标题固定单行省略，任何字号下都不会再互相挤压。
class AiProcessingHeader extends StatelessWidget {
  final int settled;
  final int enqueued;
  final int pending;
  final bool auto;
  final VoidCallback? onCancel;
  final VoidCallback? onBackground;

  const AiProcessingHeader({
    super.key,
    required this.settled,
    required this.enqueued,
    required this.pending,
    this.auto = false,
    this.onCancel,
    this.onBackground,
  });

  @override
  Widget build(BuildContext context) {
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            TextButton(onPressed: onCancel, child: const Text('取消')),
            TextButton(onPressed: onBackground, child: const Text('后台')),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 28, bottom: 4),
          child: Text(
            '已处理 $settled/$enqueued · 待确认 $pending',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

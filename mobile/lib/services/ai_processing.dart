import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/message.dart';
import '../models/task.dart';
import 'ai_client.dart';
import 'database.dart';
import 'reminder_service.dart';
import 'undo_service.dart';

/// 一条消息的处理结局（AI 面板卡片/汇总行共用的视图模型；v2.6.2 起随会话
/// 常驻服务层，面板收起后处理进度与结果都保留）。
class AiOutcome {
  final Message message;
  AiProcessResult? result;
  String? error;
  bool confirmed = false;

  /// 汇总页勾选状态（v2.4：checkbox + 「确认选中」）；默认勾选。
  bool checked = true;

  AiOutcome(this.message);

  bool get settled => result != null || error != null;
}

/// AI 处理会话：一次批量处理的全部状态（设计 §8.3）。
class AiProcessingSession {
  AiProcessingSession(List<Message> messages)
      : outcomes = [for (final m in messages) AiOutcome(m)];

  final List<AiOutcome> outcomes;

  /// 每条消息的流式原始输出（v2.4 卡片化：各自独立成卡）。
  final Map<String, StringBuffer> rawById = {};

  bool running = true;
  String? currentId;
  String? fatalError;

  int get total => outcomes.length;
  int get doneCount => outcomes.where((o) => o.settled).length;
  int get failCount => outcomes.where((o) => o.error != null).length;

  /// 已有评估结果、等待用户确认的条数（后台处理完成后的收尾入口计数）。
  int get pendingConfirmCount =>
      outcomes.where((o) => o.result != null && !o.confirmed).length;

  AiOutcome? outcomeOf(String messageId) {
    for (final o in outcomes) {
      if (o.message.id == messageId) return o;
    }
    return null;
  }
}

/// 发起前统一过滤（v2.6.2，在选择集构建处过滤，不依赖面板拦截）：
/// - 正在处理中的消息跳过；
/// - 已 processed 的消息只有显式「重新处理」（[reprocess]=true）才放行；
/// - pending 且同内容（content_hash）已有 processed 记录的重复消息跳过（v2.6.1 省 Token）。
/// 返回 (可处理列表, 各跳过原因计数)，输入顺序保留。
(List<Message>, Map<String, int>) filterProcessable(
  List<Message> msgs, {
  required bool reprocess,
  required Set<String> processingIds,
  required Set<String> processedHashes,
}) {
  final toProcess = <Message>[];
  var skippedProcessing = 0, skippedProcessed = 0, skippedDup = 0;
  for (final m in msgs) {
    if (processingIds.contains(m.id)) {
      skippedProcessing++;
    } else if (!reprocess && m.status == MessageStatus.processed) {
      skippedProcessed++;
    } else if (m.status == MessageStatus.pending &&
        processedHashes.contains(m.contentHash)) {
      skippedDup++;
    } else {
      toProcess.add(m);
    }
  }
  return (toProcess, {
    if (skippedProcessed > 0) 'processed': skippedProcessed,
    if (skippedProcessing > 0) 'processing': skippedProcessing,
    if (skippedDup > 0) 'duplicate': skippedDup,
  });
}

/// AI 处理会话持有者（v2.6.2 后台处理，设计 §8.3）：会话从消息页发起后常驻于此，
/// 面板只是它的视图——收起面板（「后台」按钮）处理继续，重开面板看到同一会话。
///
/// 同时是「正在处理」消息 id 集的唯一来源（内存态，不落库，页面间天然一致；
/// 应用重启即清——未确认结果随之丢弃，设计上确认动作必须用户在场完成）。
class AiProcessingService extends ChangeNotifier {
  AiProcessingService._();

  static final AiProcessingService instance = AiProcessingService._();

  AiProcessingSession? _session;
  StreamSubscription<AiEvent>? _sub;

  /// 粗粒度状态版本号：start/result/error/done/cancel/confirm/clear 时 +1。
  /// 消息页只在版本变化时重建（token 高频事件不触发整页 setState）。
  int revision = 0;

  /// token 流版本号：面板用来触发滚动到底（每 token +1）。
  int tokenRevision = 0;

  int _panelDepth = 0; // 打开中的面板数（判断后台完成是否发系统通知）

  AiProcessingSession? get session => _session;
  bool get running => _session?.running ?? false;

  /// 正在处理中的消息 id 集（v2.6.2：列表处理中标记 + 发起前排除）。
  Set<String> get processingIds {
    final s = _session;
    if (s == null || !s.running) return const {};
    return {for (final o in s.outcomes) if (!o.settled) o.message.id};
  }

  bool isProcessing(String messageId) => processingIds.contains(messageId);

  /// 待确认结果条数（会话存在且已跑完时作为「待确认」入口计数）。
  int get pendingConfirmCount => _session?.pendingConfirmCount ?? 0;

  void attachPanel() => _panelDepth++;
  void detachPanel() => _panelDepth--;

  /// 发起新会话；返回 null 表示成功，否则为不可发起的原因（供 SnackBar）。
  String? start(List<Message> messages) {
    final s = _session;
    if (s != null && s.running) return '上一批仍在处理中';
    if (s != null && s.pendingConfirmCount > 0) {
      return '有 ${s.pendingConfirmCount} 条待确认结果，请先在面板中确认';
    }
    final session = AiProcessingSession(messages);
    _session = session;
    revision++;
    notifyListeners();
    _sub = AiClient.instance.process(messages).listen(
      (ev) => _onEvent(session, ev),
      onError: (Object e) {
        session.fatalError = '$e';
        _finish(session);
      },
      onDone: () => _finish(session),
    );
    return null;
  }

  void _onEvent(AiProcessingSession session, AiEvent ev) {
    if (!identical(session, _session)) return;
    switch (ev) {
      case AiTokenDelta(:final messageId, :final delta):
        session.currentId = messageId;
        session.rawById.putIfAbsent(messageId, StringBuffer.new).write(delta);
        tokenRevision++;
        notifyListeners(); // 高频：不 bump revision，只有面板在听
      case AiMessageResult(:final result):
        session.outcomeOf(result.messageId)?.result = result;
        revision++;
        notifyListeners();
      case AiMessageError(:final messageId, :final error):
        session.outcomeOf(messageId)?.error = error;
        revision++;
        notifyListeners();
      case AiAllDone():
        session.running = false;
    }
  }

  void _finish(AiProcessingSession session) {
    if (!identical(session, _session)) return;
    session.running = false;
    revision++;
    notifyListeners();
    // 后台完成（面板已收起）且有待确认结果：发一次性系统通知提醒回来收尾
    // （普通通知，不引入前台服务；可能被后续任务提醒重排 cancelAll 清掉，
    // 应用内顶部指示条是可靠入口）。
    if (_panelDepth == 0 && session.pendingConfirmCount > 0) {
      ReminderService.instance.notifyAiProcessingDone(
          session.pendingConfirmCount, session.failCount);
    }
  }

  /// 取消：中断流，已产出的结果保留在汇总面板。
  Future<void> cancel() async {
    AiClient.instance.cancelActive();
    await _sub?.cancel();
    final s = _session;
    if (s != null && s.running) {
      s.running = false;
      revision++;
      notifyListeners();
    }
  }

  /// 确认 = 写回 priority + status(processed)；有任务草稿则建任务并互链。
  /// 每次确认作为一个复合逆操作进撤销队列（设计 §5.2/§6）。返回确认条数。
  Future<int> confirm(List<AiOutcome> targets) async {
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
    if (undoItems.isEmpty) return 0;
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
    revision++;
    notifyListeners();
    return count;
  }

  /// 会话收尾：结果全部确认（或无结果可确认）后由面板关闭时调用。
  void clear() {
    if (_session == null) return;
    _session = null;
    revision++;
    notifyListeners();
  }
}

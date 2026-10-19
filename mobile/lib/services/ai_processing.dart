import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/message.dart';
import '../models/task.dart';
import 'ai_client.dart';
import 'app_log.dart';
import 'app_ui_state.dart';
import 'task_dedupe.dart';
import 'database.dart';
import 'reminder_service.dart';
import 'undo_service.dart';

/// 一条消息的处理结局（AI 面板卡片/汇总行共用的视图模型；v2.6.2 起随会话
/// 常驻服务层，v2.6.4 起为连续排队模型：排队 → 处理中 → 结果待确认/失败，
/// 确认后从会话列表移除）。
class AiOutcome {
  final Message message;
  AiProcessResult? result;
  String? error;

  /// 汇总页勾选状态（v2.4：checkbox + 「确认选中」）；默认勾选。
  bool checked = true;

  AiOutcome(this.message);

  bool get settled => result != null || error != null;
}

/// AI 处理会话（v2.6.4 连续排队，设计 §8.3）：开放式队列，随时可追加消息，
/// 结果跨批累积；确认过的条目移除。队列空且列表空时由服务层清空会话。
class AiProcessingSession {
  final List<AiOutcome> outcomes = [];

  /// 每条消息的流式原始输出（v2.4 卡片化：各自独立成卡；批量请求的流式
  /// 原文归批首消息卡片）。
  final Map<String, StringBuffer> rawById = {};

  bool running = false;
  String? currentId;

  /// 累计入队/完结条数（单调递增，不受确认移除影响），供「处理中 x/y」展示。
  int enqueuedCount = 0;
  int settledCount = 0;

  /// 已完结（结果+失败）的当前列表条数。
  int get doneCount => outcomes.where((o) => o.settled).length;

  /// 排队中 + 处理中的条数。
  int get remainingCount => outcomes.where((o) => !o.settled).length;

  int get failCount => outcomes.where((o) => o.error != null).length;

  /// 已有评估结果、等待用户确认的条数（确认后条目即从列表移除）。
  int get pendingConfirmCount =>
      outcomes.where((o) => o.result != null).length;

  AiOutcome? outcomeOf(String messageId) {
    for (final o in outcomes) {
      if (o.message.id == messageId) return o;
    }
    return null;
  }
}

/// 发起前统一过滤（v2.6.2，在选择集构建处过滤，不依赖面板拦截）：
/// - 正在处理中/排队中的消息跳过；
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

/// AI 处理会话持有者（v2.6.4 连续排队模型，设计 §8.3）：
/// - 随时可 [enqueue]：处理进行中或有结果待确认时都能追加，挂到队列尾部
///   按序继续，不需要等上一批跑完、也不需要先确认；
/// - 同一时刻只跑一个模型请求：泵循环按队列当前快照取 ≤[AiClient.batchSize]
///   条组批（复用 AiClient 单批流，含垃圾规则预过滤），追加的自然进入下一批；
/// - 结果跨批累积，[confirm] 确认后条目移除；队列空且列表空才会话清空。
///
/// 同时是「正在处理」消息 id 集的唯一来源（内存态，不落库，页面间天然一致；
/// 应用重启即清——未确认结果随之丢弃，设计上确认动作必须用户在场完成）。
/// 自动确认的目标选择（纯函数，便于单测）：
/// 只取「本轮自动提交的那些消息」里**成功且有结果**的条目；
/// 失败条目（error != null）与未完成条目一律跳过。
List<AiOutcome> selectAutoConfirmTargets({
  required List<AiOutcome> outcomes,
  required Set<String> messageIds,
}) =>
    [
      for (final o in outcomes)
        if (messageIds.contains(o.message.id) &&
            o.settled &&
            o.error == null &&
            o.result != null)
          o,
    ];

class AiProcessingService extends ChangeNotifier {
  AiProcessingService._();

  static final AiProcessingService instance = AiProcessingService._();

  AiProcessingSession? _session;
  /// 单条消息保留的原始流字符上限（只用于展示）。
  static const int _rawLimit = 4000;

  Timer? _tokenNotifyTimer;

  void _scheduleTokenNotify() {
    if (_tokenNotifyTimer != null) return;
    _tokenNotifyTimer = Timer(const Duration(milliseconds: 100), () {
      _tokenNotifyTimer = null;
      notifyListeners();
    });
  }

  bool _pumping = false;
  bool _cancelRequested = false;

  /// 追加新消息后重置；队列排空且面板收起时凭它只发一次完成通知。
  bool _notifiedPending = false;

  /// U19：自动触发的那一轮处理结束后是否自动确认（用户 2026-10-18 要求）。
  ///
  /// **按消息 id 记录**，而不是一个全局开关：自动跑的同时用户手动再选几条处理时，
  /// 那些手动提交的消息不能被顺带自动确认（用户没点确认）。
  /// 只对一次自动触发生效，用完即清；手动处理永远走人工确认。
  Set<String>? _autoConfirmIds;

  /// 武装「处理完自动确认」，只对 [messageIds] 生效。
  void armAutoConfirm(Iterable<String> messageIds) =>
      _autoConfirmIds = messageIds.toSet();

  void disarmAutoConfirm() => _autoConfirmIds = null;

  bool get autoConfirmArmed => _autoConfirmIds != null;

  Future<void>? _pumpFuture;

  /// 处理流工厂（@visibleForTesting：测试替换为假流；默认走 AiClient 路由）。
  @visibleForTesting
  Stream<AiEvent> Function(List<Message>) processor = AiClient.instance.process;

  /// 粗粒度状态版本号：入队/逐条结果/批开始/排空/确认/清空时 +1。
  /// 消息页只在版本变化时重建（token 高频事件不触发整页 setState）。
  int revision = 0;

  /// token 流版本号：面板用来触发滚动到底（每 token +1）。
  int tokenRevision = 0;

  int _panelDepth = 0; // 打开中的面板数（判断后台完成是否发系统通知）

  AiProcessingSession? get session => _session;

  /// 队列是否正在消费（有批在跑）。
  bool get running => _pumping;

  /// 排队中 + 处理中的消息 id 集（v2.6.2：列表处理中标记 + 发起前排除）。
  Set<String> get processingIds {
    final s = _session;
    if (s == null) return const {};
    return {for (final o in s.outcomes) if (!o.settled) o.message.id};
  }

  bool isProcessing(String messageId) => processingIds.contains(messageId);

  /// 待确认结果条数（跨批累积）。
  int get pendingConfirmCount => _session?.pendingConfirmCount ?? 0;

  /// 等待泵循环空闲（当前队列排空）。
  ///
  /// 自动处理的连续批处理用它：一批跑完（含自动确认）再取下一批。
  Future<void> get idle => _pumpFuture ?? Future.value();

  /// 测试用：强制清空会话与泵状态（不改 processor）。
  @visibleForTesting
  void reset() {
    _tokenNotifyTimer?.cancel();
    _tokenNotifyTimer = null;
    _session = null;
    _cancelRequested = false;
    _notifiedPending = false;
    revision++;
    notifyListeners();
  }

  void attachPanel() => _panelDepth++;
  void detachPanel() => _panelDepth--;

  /// 追加到处理队列尾部（v2.6.4：随时可添加）。已在会话中的 id
  /// （排队/处理中/待确认结果）去重跳过；出错的条目允许重试（旧 error
  /// 条目替换为新排队条目，排到队尾）。返回 (加入数, 跳过数)。
  (int, int) enqueue(List<Message> messages) {
    final session = _session ?? AiProcessingSession();
    _session = session;
    var added = 0, skipped = 0;
    for (final m in messages) {
      final existing = session.outcomeOf(m.id);
      if (existing != null) {
        if (existing.error != null) {
          // 重试失败条目：移除旧条目，重新排队
          session.outcomes.remove(existing);
        } else {
          skipped++;
          continue;
        }
      }
      session.outcomes.add(AiOutcome(m));
      session.enqueuedCount++;
      added++;
    }
    if (added > 0) {
      _notifiedPending = false; // 追加新消息，重置完成通知状态
      revision++;
      notifyListeners();
      // 泵已在跑时由它自然消费到追加的条目，不重复启动（也不覆盖
      // _pumpFuture，idle 始终指向在跑的泵）
      if (!_pumping) _pumpFuture = _pump();
    }
    return (added, skipped);
  }

  /// 泵循环：同一时刻只跑一个模型请求，按队列当前快照取 ≤batchSize 条组批，
  /// 顺序消费直到队列排空（追加进来的消息自然进入后续批次）。
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    _cancelRequested = false;
    final session = _session;
    if (session != null) session.running = true;
    revision++;
    notifyListeners();
    try {
      for (;;) {
        if (_cancelRequested) break;
        final s = _session;
        if (s == null) break;
        // 组批快照：队列头部 ≤batchSize 条未完结消息
        final batch = <AiOutcome>[];
        for (final o in s.outcomes) {
          if (batch.length >= AiClient.batchSize) break;
          if (!o.settled) batch.add(o);
        }
        if (batch.isEmpty) break;
        s.currentId = batch.first.message.id;
        revision++;
        notifyListeners();
        try {
          await for (final ev
              in processor([for (final o in batch) o.message])) {
            _onEvent(s, ev);
          }
          // 防御：处理流正常结束但有条目未收到结果/错误（如流被截断），
          // 标记失败避免泵循环对同一批无限重试
          if (!_cancelRequested) {
            var anyUnsettled = false;
            for (final o in batch) {
              if (!o.settled) {
                o.error = '处理流结束但未返回该条结果';
                s.settledCount++;
                anyUnsettled = true;
              }
            }
            if (anyUnsettled) {
              revision++;
              notifyListeners();
            }
          }
        } catch (e) {
          // 流级异常（未能逐条给出错误）且非用户取消：整批标记失败
          if (!_cancelRequested) {
            for (final o in batch) {
              if (!o.settled) {
                o.error = '$e';
                s.settledCount++;
              }
            }
            revision++;
            notifyListeners();
          }
        }
      }
    } finally {
      _pumping = false;
      // 取消：丢弃未产出结果的排队/在飞条目（已产出的结果保留）
      if (_cancelRequested) {
        _session?.outcomes.removeWhere((o) => !o.settled);
        _cancelRequested = false;
      }
      final s = _session;
      if (s != null) s.running = false;
      revision++;
      notifyListeners();
    }
    _drained();
  }

  void _onEvent(AiProcessingSession session, AiEvent ev) {
    if (!identical(session, _session)) return;
    switch (ev) {
      case AiTokenDelta(:final messageId, :final delta):
        session.currentId = messageId;
        final buf = session.rawById.putIfAbsent(messageId, StringBuffer.new);
        buf.write(delta);
        // 原始流只保留末尾一段：上千条消息时无限累积会让内存与重排都失控
        if (buf.length > _rawLimit) {
          final tail = buf.toString().substring(buf.length - _rawLimit);
          buf
            ..clear()
            ..write('…$tail');
        }
        tokenRevision++;
        // 合并通知：每个 token 都 notifyListeners 会让面板按 token 频率重排，
        // 上千条队列时直接把主线程压垮（真机 ANR）。这里约 10fps 合并一次。
        _scheduleTokenNotify();
      case AiMessageResult(:final result):
        final o = session.outcomeOf(result.messageId);
        if (o != null && !o.settled) {
          o.result = result;
          session.settledCount++;
        }
        revision++;
        notifyListeners();
      case AiMessageError(:final messageId, :final error):
        final o = session.outcomeOf(messageId);
        if (o != null && !o.settled) {
          o.error = error;
          session.settledCount++;
        }
        revision++;
        notifyListeners();
      case AiAllDone():
        break; // 泵循环自管批次节奏，无需处理
    }
  }

  /// 队列排空：后台（面板收起）且有待确认结果时发一次性系统通知
  /// （普通通知，不引入前台服务；应用内顶部指示条是可靠入口）。
  void _drained() {
    final s = _session;
    // U19：一次性令牌 —— 排空时无论用不用都先取走并清空，
    // 否则本轮全失败时令牌残留，会干扰之后「用户手动处理」的那一轮。
    final armedIds = _autoConfirmIds;
    _autoConfirmIds = null;
    if (armedIds != null && s != null && !_pumping) {
      unawaited(_autoConfirmNow(s, armedIds));
    }
    // 已武装自动确认时不再发「待确认」通知：否则用户会先后收到
    // 「N 条待确认」和「已自动确认 N 条」两条互相矛盾的通知。
    if (armedIds == null &&
        s != null &&
        !_pumping &&
        s.pendingConfirmCount > 0 &&
        _panelDepth == 0 &&
        !_notifiedPending) {
      _notifiedPending = true;
      ReminderService.instance
          .notifyAiProcessingDone(s.pendingConfirmCount, s.failCount);
    }
    _maybeClear();
  }

  /// 自动确认：只把**本次自动提交**的那些消息里「成功且有结果」的写回
  /// （建任务 + 置 processed）。失败条目与用户手动追加的消息保持原样。
  Future<void> _autoConfirmNow(
      AiProcessingSession s, Set<String> armedIds) async {
    final targets =
        selectAutoConfirmTargets(outcomes: s.outcomes, messageIds: armedIds);
    final failed = s.outcomes
        .where((o) => armedIds.contains(o.message.id) && o.error != null)
        .length;
    if (targets.isEmpty) {
      // 全失败：也要告知，否则用户只收到「已提交」却不知道一条都没成
      AppLog.instance.warn('ai.auto-confirm', '无可确认结果（失败 $failed 条）');
      if (!AppUiState.instance.messagesVisible) {
        await ReminderService.instance.notifyAutoFailed(failed);
      }
      return;
    }
    try {
      final n = await confirm(targets);
      AppLog.instance.warn('ai.auto-confirm',
          '自动确认 $n 条 AI 结果（新建任务 $lastConfirmCreatedTasks 个，失败 $failed 条）');
      // U19-A：后台/非消息页场景下，这是用户唯一能察觉「跑完了」的提示
      if (!AppUiState.instance.messagesVisible) {
        await ReminderService.instance
            .notifyAutoFinished(n, createdTasks: lastConfirmCreatedTasks, failed: failed);
      }
    } catch (e, st) {
      AppLog.instance.warn('ai.auto-confirm', e, st);
    }
  }

  /// 会话清空条件（v2.6.4）：队列空（无在跑/排队）且结果列表空
  /// （全部确认移除，无失败残留）。
  void _maybeClear() {
    final s = _session;
    if (s != null && !_pumping && s.outcomes.isEmpty) {
      _session = null;
      revision++;
      notifyListeners();
    }
  }

  /// 取消：中断当前模型调用，未产出结果的排队/在飞条目丢弃，
  /// 已产出的结果保留在汇总面板。
  Future<void> cancel() async {
    _cancelRequested = true;
    // 用户主动取消：已出结果的条目也不能再自动确认（否则等于「取消无效」）
    _autoConfirmIds = null;
    AiClient.instance.cancelActive();
  }

  /// 确认 = 写回 priority + status(processed)；有任务草稿则建任务并互链。
  /// 每次确认作为一个复合逆操作进撤销队列（设计 §5.2/§6）。
  /// 确认过的条目从会话列表移除（v2.6.4），处理继续。返回确认条数。
  /// 确认串行化（子代理审查：自动确认与面板手点可能并发，各自查一遍活动任务
  /// 再逐条插入 → 重复任务 + 双份撤销记录）。这里用 Future 链把调用排队。
  Future<void> _confirmQueue = Future<void>.value();

  /// 最近一次 confirm 新建的任务数（给通知文案用）。
  int lastConfirmCreatedTasks = 0;

  Future<int> confirm(List<AiOutcome> targets) {
    final result = _confirmQueue.then((_) => _confirmImpl(targets));
    _confirmQueue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<int> _confirmImpl(List<AiOutcome> targets) async {
    final db = AppDatabase.instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    // 防重复任务：先取一遍进行中的任务，草稿命中「同一件事」就复用它、只建关联。
    // 典型场景：群里把同一条通知发了两遍 → 两条消息各自产出同名同时间的草稿，
    // 以前会建出两条一模一样的任务（真机数据里已出现过）。
    final activeTasks = await db.getActiveTasks();
    final undoItems = <({
      String messageId,
      String oldPriority,
      String oldStatus,
      List<String> oldTaskIds,
      List<String> createdTaskIds,
    })>[];
    final confirmed = <AiOutcome>[];
    var createdTasks = 0;
    for (final o in targets) {
      final r = o.result;
      if (r == null) continue;
      final m = o.message;
      // N1：一条消息可能产出多个任务草稿；空标题的丢弃。
      final drafts = r.taskDrafts.isNotEmpty
          ? r.taskDrafts
          : (r.taskDraft != null ? [r.taskDraft!] : const <AiTaskDraft>[]);
      final oldTaskIds = await db.taskIdsForMessage(m.id);
      final createdIds = <String>[];
      final reusedIds = <String>[];
      for (final draft in drafts) {
        if (draft.title.trim().isEmpty) continue;
        final startAtMs = draft.startAt?.millisecondsSinceEpoch;
        final reuse = findReusableTask(activeTasks,
            title: draft.title, startAt: startAtMs);
        if (reuse != null) {
          // 命中已有任务：不新建，稍后只加一条关联（多对多的本意）
          if (!reusedIds.contains(reuse.id)) reusedIds.add(reuse.id);
          continue;
        }
        final task = Task(
          id: const Uuid().v4(),
          title: draft.title,
          description: draft.description,
          kind: draft.kind,
          startAt: draft.startAt?.millisecondsSinceEpoch,
          // 兜底：point 任务不落 end_at，保持与派生尺度一致（P1-1）
          endAt: draft.kind == TaskKind.range
              ? draft.endAt?.millisecondsSinceEpoch
              : null,
          priority: draft.priority,
          sourceMessageId: m.id,
          status: TaskStatus.active,
          createdAt: now,
          updatedAt: now,
        );
        await db.insertTask(task);
        createdIds.add(task.id);
        activeTasks.add(task); // 同批内的后续草稿也能命中这条
      }
      await db.updateMessagePriority([m.id], r.priority);
      await db.updateMessageStatus([m.id], MessageStatus.processed);
      // 关联语义与旧版一致：用本次草稿替换旧绑定（无草稿则清空）。
      await db.unlinkAllForMessage(m.id);
      for (final id in [...createdIds, ...reusedIds]) {
        await db.linkMessageTask(m.id, id);
      }
      undoItems.add((
        messageId: m.id,
        oldPriority: m.priority,
        oldStatus: m.status,
        oldTaskIds: oldTaskIds,
        createdTaskIds: createdIds,
      ));
      if (reusedIds.isNotEmpty) {
        AppLog.instance.warn('ai.confirm-reuse',
            '复用已有任务 ${reusedIds.length} 个（消息 ${m.id}）');
      }
      confirmed.add(o);
    }
    lastConfirmCreatedTasks = createdTasks;
    if (undoItems.isEmpty) return 0;
    final count = undoItems.length;
    UndoService.instance.register(
      label: '已确认 $count 条 AI 结果',
      undo: () async {
        for (final u in undoItems.reversed) {
          if (u.createdTaskIds.isNotEmpty) {
            await db.deleteTasks(u.createdTaskIds);
          }
          await db.updateMessagePriority([u.messageId], u.oldPriority);
          await db.updateMessageStatus([u.messageId], u.oldStatus);
          await db.unlinkAllForMessage(u.messageId);
          for (final id in u.oldTaskIds) {
            await db.linkMessageTask(u.messageId, id);
          }
        }
      },
    );
    // 确认过的条目从列表移除；队列空且列表空时会话随之清空
    _session?.outcomes.removeWhere(confirmed.contains);
    revision++;
    notifyListeners();
    _maybeClear();
    return count;
  }

  /// 面板关闭时收尾：无待确认结果（剩余为失败条目或直接为空）时清空会话；
  /// 队列仍在跑或有待确认结果时会话保留（消息页入口可回来继续）。
  void closePanel() {
    final s = _session;
    if (s != null && !_pumping && s.pendingConfirmCount == 0) {
      _session = null;
      revision++;
      notifyListeners();
    }
  }
}

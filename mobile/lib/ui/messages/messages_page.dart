import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../models/task.dart';
import '../../services/ai_processing.dart';
import '../../services/database.dart';
import '../../services/import_service.dart';
import '../../services/notification_bridge.dart';
import '../../services/undo_service.dart';
import '../add_message_page.dart';
import '../tasks/task_editor.dart';
import 'ai_panel.dart';
import 'archived_page.dart';
import 'import_page.dart';
import 'message_detail_sheet.dart';
import 'message_widgets.dart';
import '../../services/app_log.dart';
import '../../services/app_ui_state.dart';
import '../../services/reminder_service.dart';
import '../../services/auto_process.dart';

/// v2 消息主列表页（设计 §5.1）：分组吸顶列表 + Chip 筛选行 + 左滑块状菜单
/// + 多选批量操作。归档消息在独立页面（ArchivedMessagesPage）。
class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});

  @override
  State<MessagesPage> createState() => MessagesPageState();
}

class MessagesPageState extends State<MessagesPage> {
  final AppDatabase _db = AppDatabase.instance;

  List<Message> _messages = [];
  List<SourceApp> _sources = [];

  /// 全部任务 id → Task（v2.6：绑定消息显示任务优先级色点；
  /// 兼作 v2.4「已完成」筛选与行划线样式数据源）。
  Map<String, Task> _tasksById = {};

  /// messageId → 关联任务 id 列表（N1 多对多）
  Map<String, List<String>> _taskLinks = {};
  bool _loading = true;

  /// 截断提示只提示一次/会话（P3-8）
  bool _limitHintShown = false;

  /// 状态分组多选筛选（默认全选）；另含特殊键 [kFilterDone]（已完成）。
  final Set<String> _groupFilter = Set.of(kGroupOrder);
  String? _appFilter; // null = 全部应用

  bool _selecting = false;
  final Set<String> _selected = {};
  final Set<String> _collapsed = {};

  /// 通知监听权限（v2.5：null=未知；false 时顶部显示恢复引导横幅）。
  bool? _listenerEnabled;

  /// U19：自动处理正在执行（防止重入）
  bool _autoProcessRunning = false;

  StreamSubscription<int>? _sub;

  /// AI 处理服务的粗粒度版本号快照（v2.6.2）：token 高频事件不重建整页，
  /// 只在会话状态变化（开始/逐条结果/完成/确认/清空）时 setState。
  int _aiRevision = 0;

  @override
  void initState() {
    super.initState();
    _sub = NotificationBridge.instance.onNewMessages.listen((_) => reload());
    _aiRevision = AiProcessingService.instance.revision;
    AiProcessingService.instance.addListener(_onAiProcessingChanged);
    reload();
  }

  @override
  void dispose() {
    AiProcessingService.instance.removeListener(_onAiProcessingChanged);
    _sub?.cancel();
    super.dispose();
  }

  /// 角标 = DB 里的未处理条数（与页面筛选无关，后台也会被调用）。
  Future<void> _updateBadge() async {
    try {
      final n = await _db.countMessages(status: MessageStatus.pending);
      if (!mounted) return;
      MessageBadges.instance.setPending(n);
    } catch (e, st) {
      AppLog.instance.warn('messages.badge', e, st);
    }
  }

  void _onAiProcessingChanged() {
    final rev = AiProcessingService.instance.revision;
    if (!mounted || rev == _aiRevision) return;
    _aiRevision = rev;
    setState(() {});
    // 自动确认会把消息置 processed 却没有 reload —— 角标要跟着刷新
    // （子代理审查：否则后台跑完后角标长期停在旧值）。
    final s = AiProcessingService.instance.session;
    final drained = s == null || (!s.running && s.outcomes.isEmpty);
    if (drained) unawaited(_updateBadge());
  }

  /// 重新加载列表（供 GlobalKey 外部触发）。
  /// v2.5：消息与来源是关键路径；任务表（绑定色点/「已完成」筛选/划线用）
  /// 失败不阻塞列表展示——此前三者同处一个 Future.wait，任一路失败会让列表
  /// 永远停在「加载中…」（表现为"消息抓取失效"）。
  Future<void> reload() async {
    try {
      final results = await Future.wait([
        _db.getMessages(packageName: _appFilter),
        _db.getDistinctMessageSources(),
        _db.countMessages(packageName: _appFilter),
        _db.messageTaskLinks(),
      ]);
      if (!mounted) return;
      // P3-8：超过默认上限时提示一次，不再静默截断
      final total = results[2] as int;
      final fetched = (results[0] as List<Message>).length;
      if (fetched < total && !_limitHintShown) {
        _limitHintShown = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('消息较多：仅显示最近 $fetched 条（共 $total 条），更早的未加载'),
            duration: const Duration(seconds: 4),
          ));
        });
      }
      setState(() {
        _messages = (results[0] as List<Message>)
            .where((m) => m.status != MessageStatus.archived)
            .toList();
        _sources = results[1] as List<SourceApp>;
        _taskLinks = results[3] as Map<String, List<String>>;
        _loading = false;
        // 所选应用的消息可能已不存在，回退到全部
        if (_appFilter != null &&
            !_sources.any((s) => s.packageName == _appFilter)) {
          _appFilter = null;
        }
        _selected.removeWhere((id) => !_messages.any((m) => m.id == id));
        if (_selected.isEmpty) _selecting = false;
      });
    } catch (e, st) {
      AppLog.instance.warn('messages.reload', e, st);
      if (mounted) setState(() => _loading = false);
    }
    // 尽力加载：任务表（绑定消息的优先级色点 +「已完成」筛选/划线）
    try {
      final tasks = await _db.getTasks();
      if (!mounted) return;
      setState(() => _tasksById = {for (final t in tasks) t.id: t});
    } catch (e, st) { AppLog.instance.warn('messages.done-tasks', e, st); }
    // 通知监听权限状态（v2.5：丢失时页面顶部给恢复引导）
    try {
      final enabled = await NotificationBridge.instance.isListenerEnabled();
      if (mounted) setState(() => _listenerEnabled = enabled);
    } catch (e, st) { AppLog.instance.warn('messages.listener-state', e, st); }
    // U19-B：更新底部导航「消息」角标（取 DB 的未处理数，不受页面 500 条上限影响）
    await _updateBadge();
    // U19：未处理堆到阈值时自动提交处理（放在 reload 末尾，避免与首帧竞争）
    await _maybeAutoProcess();
  }

  /// 某条消息关联的任务 id（N1）：优先关联表，回退旧列。
  List<String> _linkedTaskIds(Message m) {
    final ids = _taskLinks[m.id];
    if (ids != null && ids.isNotEmpty) return ids;
    final single = m.linkedTaskId;
    return (single == null || single.isEmpty) ? const [] : [single];
  }

  /// 任一关联任务已完成即视为「已完成」（用于筛选与划线）。
  bool _isLinkedDone(Message m) =>
      _linkedTaskIds(m).any((id) => _tasksById[id]?.status == TaskStatus.done);

  /// 主关联任务的优先级（决定消息卡色点）。
  String? _linkedTaskPriority(Message m) {
    final ids = _linkedTaskIds(m);
    if (ids.isEmpty) return null;
    return _tasksById[ids.first]?.priority;
  }

  // 分组结果缓存（2026-10-20 性能）：原来每次 setState（多选一行、折叠、切 chip）
  // 都重跑「全量过滤 + 分组 List 分配」；500 条时每帧都是 O(n) 分配。
  List<Message>? _visibleCache;
  Map<String, List<Message>>? _groupedCache;
  Object? _cacheKeyMessages;
  Object? _cacheKeyTasks;
  Set<String>? _cacheKeyFilter;

  bool _cachesFresh() =>
      _visibleCache != null &&
      identical(_cacheKeyMessages, _messages) &&
      identical(_cacheKeyTasks, _tasksById) &&
      setEquals(_cacheKeyFilter, _groupFilter);

  List<Message> get _visible {
    final cached = _visibleCache;
    if (cached != null && _cachesFresh()) return cached;
    final visible = _messages.where((m) {
      if (_groupFilter.contains(messageGroupKey(m))) return true;
      // 「已完成」筛选：额外放行关联任务已完成的消息（不占分组）
      return _groupFilter.contains(kFilterDone) && _isLinkedDone(m);
    }).toList();
    _visibleCache = visible;
    _groupedCache = null;
    _cacheKeyMessages = _messages;
    _cacheKeyTasks = _tasksById;
    _cacheKeyFilter = Set.of(_groupFilter);
    return visible;
  }

  Map<String, List<Message>> get _grouped {
    final cached = _groupedCache;
    if (cached != null && _cachesFresh()) return cached;
    final map = {for (final k in kGroupOrder) k: <Message>[]};
    for (final m in _visible) {
      map[messageGroupKey(m)]!.add(m);
    }
    _groupedCache = map;
    return map;
  }

  // ---- AI 处理（设计 §8：路由 + 流式面板）----

  /// 发起 AI 处理。[reprocess]=true 仅用于单条左滑「重新处理」——
  /// 已 processed 的消息只有这条路径允许再次发起（v2.6.2）。
  /// v2.6.4 连续排队：随时可追加，挂到队列尾部按序处理，不等上一批跑完。
  /// U19：未处理消息达到阈值时自动提交处理。
  ///
  /// **候选集取自数据库，不依赖页面列表**（2026-10-20 修）：此前用 `_messages`，
  /// 而页面一次只加载 500 条，于是「DB 里 2000+ 未处理」只会送 500 条去处理。
  /// 现在：阈值按 DB 的 pending 总数判断，每轮只取最早的一批（kAutoProcessBatchSize）。
  Future<void> _maybeAutoProcess() async {
    if (_autoProcessRunning) return;
    if (!await AutoProcessState.enabled()) return;
    final threshold = await AutoProcessState.threshold();
    final pendingTotal = await _db.countMessages(status: MessageStatus.pending);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final lastAt = await AutoProcessState.lastRunAt();
    final svc = AiProcessingService.instance;
    final ok = shouldAutoProcess(
      pendingCount: pendingTotal,
      alreadyProcessing: svc.running,
      lastAutoAtMs: lastAt,
      nowMs: nowMs,
      threshold: threshold,
    );
    if (!ok || !mounted) return;

    _autoProcessRunning = true;
    AppLog.instance.warn('auto-process',
        'DB 未处理 $pendingTotal 条 ≥ 阈值 $threshold，开始连续处理（每批 $kAutoProcessBatchSize）');
    if (AppUiState.instance.messagesVisible) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('未处理 $pendingTotal 条（阈值 $threshold），开始自动处理')));
    }

    var pendingBefore = pendingTotal;
    var batches = 0;
    var totalSubmitted = 0;
    try {
      // 连续清积压：每批跑完（含自动确认）再取下一批，直到低于阈值或无进展
      while (mounted && batches < kAutoProcessMaxBatches) {
        final sessionIds = <String>{
          for (final o in svc.session?.outcomes ?? const <AiOutcome>[])
            o.message.id,
        };
        final candidates = (await _db.getMessages(
          status: MessageStatus.pending,
          limit: kAutoProcessBatchSize,
          oldestFirst: true, // 先清最早的积压
        ))
            .where((m) =>
                !sessionIds.contains(m.id) && !svc.isProcessing(m.id))
            .toList();
        if (candidates.isEmpty) break;

        final ids = [for (final m in candidates) m.id];
        // 只对本次自动提交的这些消息自动确认（用户手动追加的不受影响）
        svc.armAutoConfirm(ids);
        final added = await _processWithAi(ids, auto: true, openPanel: batches == 0);
        if (added == 0) {
          svc.disarmAutoConfirm();
          break;
        }
        totalSubmitted += added;
        batches++;
        // 等这一批跑完（排空 + 自动确认）再决定要不要继续
        await svc.idle;
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await AutoProcessState.markRun(DateTime.now().millisecondsSinceEpoch);

        final after = await _db.countMessages(status: MessageStatus.pending);
        AppLog.instance.warn('auto-process',
            '第 $batches 批完成：提交 $totalSubmitted 条，剩余未处理 $after 条（阈值 $threshold）');
        if (after >= pendingBefore) break; // 没有进展，别硬跑
        pendingBefore = after;
        if (after < threshold) break; // 已降到阈值以下，收工
      }
    } catch (e, st) {
      svc.disarmAutoConfirm();
      AppLog.instance.warn('auto-process', e, st);
    } finally {
      _autoProcessRunning = false;
    }
  }
  /// 返回实际入队条数（0 表示全部被过滤/跳过）。
  Future<int> _processWithAi(List<String> ids,
      {bool reprocess = false, bool auto = false, bool openPanel = true}) async {
    final msgs = await _db.getMessagesByIds(ids);
    if (msgs.isEmpty || !mounted) return 0;
    // 保持传入顺序（多选时为用户点选顺序）
    final order = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    msgs.sort(
        (a, b) => (order[a.id] ?? ids.length).compareTo(order[b.id] ?? ids.length));
    // v2.6.1/v2.6.2：选择集构建处统一过滤（不依赖面板拦截）——正在处理中/
    // 已 processed（非显式重新处理）/同内容已有 processed 记录的重复消息跳过
    final svc = AiProcessingService.instance;
    final processedHashes = await _db.getProcessedContentHashes();
    if (!mounted) return 0;
    final (toProcess, skipped) = filterProcessable(
      msgs,
      reprocess: reprocess,
      processingIds: svc.processingIds,
      processedHashes: processedHashes,
    );
    // v2.6.4：追加进队列时再按会话内 id 去重（队列/处理中/待确认结果）
    final (added, skippedInSession) = svc.enqueue(toProcess);
    final parts = <String>[
      if (skipped['processed'] case final n?) '$n 条已处理',
      if (skipped['processing'] case final n?) '$n 条正在处理',
      if (skipped['duplicate'] case final n?) '$n 条重复内容',
      if (skippedInSession > 0) '$skippedInSession 条已在会话中',
    ];
    if (parts.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('跳过 ${parts.join('、')}')));
    }
    if (added == 0) return 0;
    if (auto) {
      // 自动触发：只有「用户正看着消息页」才弹面板（不阻塞等它关闭，
      // 否则有失败条目时面板停在汇总页，自动流程与冷却记录都会被挂住）。
      // 后台 / 不在消息页时弹面板没人看得见，改用系统通知告知（U19-A/C）。
      if (AppUiState.instance.messagesVisible) {
        unawaited(showAiProcessPanel(context, onChanged: reload, auto: true)
            .catchError((Object e, StackTrace st) {
          AppLog.instance.warn('ai.panel-auto', e, st);
        }));
      } else {
        unawaited(ReminderService.instance.notifyAutoStarted(added));
      }
      await reload();
    } else {
      await showAiProcessPanel(context, onChanged: reload);
      await reload();
    }
    return added;
  }

  Future<void> _addManually() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const AddMessagePage()));
    await reload();
  }

  // ---- 单条/批量操作（成功后注册撤销，见设计 §6）----

  Future<void> _createTask(Message msg) async {
    final result = await showTaskEditor(
      context,
      seedTitle: msg.title,
      seedDescription: msg.body,
      sourceMessageId: msg.id,
    );
    final task = result?.task;
    if (task == null) return;
    if (result!.parentExpanded != null) {
      await _db.updateTask(result.parentExpanded!);
    }
    await _db.insertTask(task);
    await _db.setMessageLinkedTask(msg.id, task.id);
    final parentBefore = result.parentBefore;
    UndoService.instance.register(
      label: '已创建任务',
      undo: () async {
        await _db.deleteTasks([task.id]);
        await _db.setMessageLinkedTask(msg.id, null);
        if (parentBefore != null) await _db.updateTask(parentBefore);
      },
    );
    if (!mounted) return;
    showUndoSnackBar(context, '已创建任务', onUndone: reload);
    await reload();
  }

  /// 取消选中消息各自关联的任务（删除任务并清除链接）；撤销整体回滚。
  /// 删父任务前先把其子任务升级为普通任务（parent_id 置空），
  /// 与删除合并为同一个复合撤销（设计 §7）。
  /// 取消选中消息各自关联的**全部**任务（N1：一条消息可能关联多个任务）。
  /// 删父任务前先把其子任务升级为普通任务（parent_id 置空），与删除合并为同一复合撤销。
  Future<void> _deleteLinkedTasks(List<Message> targets) async {
    // (消息, 该消息关联的任务列表)
    final pairs = <(Message, List<Task>)>[];
    for (final m in targets) {
      final ids = _linkedTaskIds(m);
      final tasks = <Task>[];
      for (final id in ids) {
        final t = await _db.getTaskById(id);
        if (t != null) tasks.add(t);
      }
      pairs.add((m, tasks));
    }
    final childrenOf = <String, List<Task>>{};
    for (final (_, tasks) in pairs) {
      for (final t in tasks) {
        final children = await _db.getChildTasks(t.id);
        if (children.isEmpty) continue;
        childrenOf[t.id] = children;
        for (final c in children) {
          await _db.updateTask(c.copyWith(parentId: () => null));
        }
      }
    }
    final allIds = [
      for (final (_, tasks) in pairs)
        for (final t in tasks) t.id,
    ];
    if (allIds.isNotEmpty) await _db.deleteTasks(allIds);
    for (final (m, _) in pairs) {
      await _db.unlinkAllForMessage(m.id);
    }
    UndoService.instance.register(
      label: '已取消任务',
      undo: () async {
        for (final (m, tasks) in pairs) {
          for (final t in tasks) {
            await _db.insertTask(t);
            await _db.linkMessageTask(m.id, t.id);
          }
        }
        for (final children in childrenOf.values) {
          for (final c in children) {
            await _db.updateTask(c);
          }
        }
      },
    );
  }

  /// 彻底删除消息（v2.4：垃圾消息左滑「删除」）；撤销 = 整体回插。
  Future<void> _deleteMessagesForever(List<Message> targets) async {
    await _db.deleteMessages([for (final m in targets) m.id]);
    UndoService.instance.register(
      label: '已删除',
      undo: () => _db.restoreMessages(targets),
    );
    if (!mounted) return;
    showUndoSnackBar(context, '已删除', onUndone: reload);
    await reload();
  }

  Future<void> _markJunk(List<Message> targets) async {
    await _db.updateMessagePriority(
        [for (final m in targets) m.id], MessagePriority.junk);
    UndoService.instance.register(
      label: '已标记垃圾',
      undo: () async {
        for (final m in targets) {
          await _db.updateMessagePriority([m.id], m.priority);
        }
      },
    );
    if (!mounted) return;
    showUndoSnackBar(context, '已标记垃圾', onUndone: reload);
    await reload();
  }

  Future<void> _unjunk(List<Message> targets) async {
    await _db.updateMessagePriority(
        [for (final m in targets) m.id], MessagePriority.none);
    UndoService.instance.register(
      label: '已移出垃圾',
      undo: () async {
        await _db.updateMessagePriority(
            [for (final m in targets) m.id], MessagePriority.junk);
      },
    );
    if (!mounted) return;
    showUndoSnackBar(context, '已移出垃圾', onUndone: reload);
    await reload();
  }

  Future<void> _archive(List<Message> targets) async {
    await _db.updateMessageStatus(
        [for (final m in targets) m.id], MessageStatus.archived);
    UndoService.instance.register(
      label: '已归档',
      undo: () async {
        for (final m in targets) {
          await _db.updateMessageStatus([m.id], m.status);
        }
      },
    );
    if (!mounted) return;
    showUndoSnackBar(context, '已归档', onUndone: reload);
    await reload();
  }

  // ---- 多选模式 ----

  List<Message> get _selectedMessages =>
      _messages.where((m) => _selected.contains(m.id)).toList();

  void _toggleSelect(Message m) {
    setState(() {
      if (!_selected.remove(m.id)) _selected.add(m.id);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  Future<void> _runBatch(Future<void> Function(List<Message>) op) async {
    final targets = _selectedMessages;
    _exitSelection();
    if (targets.isNotEmpty) await op(targets);
  }

  // ---- 左滑菜单（按行状态，设计 §5.1）----

  List<SwipeAction> _actionsFor(Message m) {
    final cs = Theme.of(context).colorScheme;
    final isJunk = m.priority == MessagePriority.junk;
    // v2.6.2：pending 才是「自动处理」；已处理/其他状态 = 显式「重新处理」
    final isPending = m.status == MessageStatus.pending;
    if (isJunk) {
      return [
        SwipeAction(
          icon: Icons.restore,
          label: '移出垃圾',
          color: cs.primary,
          onTap: () => _unjunk([m]),
        ),
        SwipeAction(
          icon: Icons.archive_outlined,
          label: '归档',
          color: cs.secondary,
          onTap: () => _archive([m]),
        ),
        SwipeAction(
          icon: Icons.delete_forever_outlined,
          label: '删除',
          color: cs.error,
          onTap: () => _deleteMessagesForever([m]),
        ),
      ];
    }
    return [
      SwipeAction(
        icon: Icons.auto_awesome,
        label: isPending ? '自动处理' : '重新处理',
        color: cs.tertiary,
        onTap: () => _processWithAi([m.id], reprocess: !isPending),
      ),
      if (_linkedTaskIds(m).isEmpty)
        SwipeAction(
          icon: Icons.add_task,
          label: '创建任务',
          color: cs.primary,
          onTap: () => _createTask(m),
        )
      else
        SwipeAction(
          icon: Icons.delete_outline,
          label: '取消任务',
          color: cs.error,
          onTap: () => _deleteLinkedTasks([m]),
        ),
      SwipeAction(
        icon: Icons.block,
        label: '标记垃圾',
        color: cs.outline,
        onTap: () => _markJunk([m]),
      ),
      SwipeAction(
        icon: Icons.archive_outlined,
        label: '归档',
        color: cs.secondary,
        onTap: () => _archive([m]),
      ),
    ];
  }

  // ---- 导入 / 归档入口 ----

  Future<void> _openImport(String source) async {
    final imported = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => ImportPage(source: source)));
    if (imported == true) await reload();
  }

  void _showImportSheet() {
    const entries = [
      (Icons.chat_bubble_outline, '微信', ImportSource.wechat),
      (Icons.forum_outlined, 'QQ', ImportSource.qq),
      (Icons.sms_outlined, '短信', ImportSource.sms),
    ];
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (icon, name, source) in entries)
              ListTile(
                leading: Icon(icon),
                title: Text('从$name导入'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _openImport(source);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openArchived() async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ArchivedMessagesPage()));
    await reload();
  }

  // ---- UI ----

  AppBar _buildAppBar() {
    if (_selecting) {
      return AppBar(
        leading: IconButton(
          tooltip: '退出',
          icon: const Icon(Icons.close),
          onPressed: _exitSelection,
        ),
        title: Text('已选 ${_selected.length} 项'),
        actions: [
          TextButton(
            onPressed: () => setState(
                () => _selected.addAll(_visible.map((m) => m.id))),
            child: const Text('全选'),
          ),
          TextButton(
            onPressed: _selected.isEmpty
                ? null
                : () => setState(() => _selected.clear()),
            child: const Text('取消'),
          ),
        ],
      );
    }
    return AppBar(
      title: const Text('消息'),
      actions: [
        IconButton(
          tooltip: '手动添加',
          icon: const Icon(Icons.add),
          onPressed: _addManually,
        ),
        IconButton(
          tooltip: '导入',
          icon: const Icon(Icons.move_to_inbox_outlined),
          onPressed: _showImportSheet,
        ),
        IconButton(
          tooltip: '已归档',
          icon: const Icon(Icons.archive_outlined),
          onPressed: _openArchived,
        ),
      ],
    );
  }

  Widget _buildFilterRow(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    BorderSide chipSide(bool selected) => selected
        ? BorderSide.none
        : BorderSide(color: cs.outlineVariant);
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final key in kGroupOrder)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Text(messageGroupLabel(key)),
                  selected: _groupFilter.contains(key),
                  showCheckmark: false,
                  selectedColor: cs.secondaryContainer,
                  backgroundColor: cs.surfaceContainerHighest,
                  side: chipSide(_groupFilter.contains(key)),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (sel) => setState(() {
                    if (sel) {
                      _groupFilter.add(key);
                    } else {
                      _groupFilter.remove(key);
                    }
                  }),
                ),
              ),
            ),
          // 「已完成」（v2.4）：不占分组，额外显示关联任务已完成的消息
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(messageGroupLabel(kFilterDone)),
                selected: _groupFilter.contains(kFilterDone),
                showCheckmark: false,
                selectedColor: cs.secondaryContainer,
                backgroundColor: cs.surfaceContainerHighest,
                side: chipSide(_groupFilter.contains(kFilterDone)),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onSelected: (sel) => setState(() {
                  if (sel) {
                    _groupFilter.add(kFilterDone);
                  } else {
                    _groupFilter.remove(kFilterDone);
                  }
                }),
              ),
            ),
          ),
          if (_sources.isNotEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Container(
                    width: 1, height: 24, color: cs.outlineVariant),
              ),
            ),
          if (_sources.isNotEmpty) ...[
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: const Text('全部'),
                  selected: _appFilter == null,
                  showCheckmark: false,
                  selectedColor: cs.secondaryContainer,
                  backgroundColor: cs.surfaceContainerHighest,
                  side: chipSide(_appFilter == null),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (_) {
                    setState(() => _appFilter = null);
                    reload();
                  },
                ),
              ),
            ),
            for (final s in _sources)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(s.displayName),
                    selected: _appFilter == s.packageName,
                    showCheckmark: false,
                    selectedColor: cs.secondaryContainer,
                    backgroundColor: cs.surfaceContainerHighest,
                    side: chipSide(_appFilter == s.packageName),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (_) {
                      setState(() => _appFilter = s.packageName);
                      reload();
                    },
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// 通知监听权限丢失横幅（v2.5）：重装/系统回收权限后用户可自行恢复。
  Widget _buildListenerBanner(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Icon(Icons.notifications_off_outlined,
                size: 18, color: cs.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text('通知监听未授权，无法自动采集消息',
                  style: TextStyle(fontSize: 13, color: cs.onErrorContainer)),
            ),
            TextButton(
              onPressed: () async {
                await NotificationBridge.instance.openListenerSettings();
                await Future.delayed(const Duration(seconds: 1));
                reload();
              },
              child: const Text('去授权'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    final grouped = _grouped;
    final empty = grouped.values.every((l) => l.isEmpty);
    if (empty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          Center(child: Text(_loading ? '加载中…' : '暂无消息')),
        ],
      );
    }
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        for (final key in kGroupOrder)
          if (grouped[key]!.isNotEmpty) ...[
            // 不用 pinned: 多个固定吸顶头挤在视口顶部会产生非法 SliverGeometry
            //（layoutExtent > paintExtent）导致整个视口不绘制；分组头随内容滚动。
            SliverPersistentHeader(
              delegate: MessageGroupHeaderDelegate(
                groupKey: key,
                count: grouped[key]!.length,
                collapsed: _collapsed.contains(key),
                onToggle: () => setState(() {
                  if (!_collapsed.remove(key)) _collapsed.add(key);
                }),
              ),
            ),
            if (!_collapsed.contains(key))
              SliverList.builder(
                itemCount: grouped[key]!.length,
                itemBuilder: (context, i) {
                  final m = grouped[key]![i];
                  // v2.6.2：正在 AI 处理中的消息显示处理中标记并禁用左滑
                  final processing =
                      AiProcessingService.instance.isProcessing(m.id);
                  return MessageTile(
                    key: ValueKey(m.id),
                    message: m,
                    selecting: _selecting,
                    selected: _selected.contains(m.id),
                    processing: processing,
                    swipeEnabled: !processing,
                    linkedTaskDone: _isLinkedDone(m),
                    linkedTaskPriority: _linkedTaskPriority(m),
                    linkedTaskCount: _linkedTaskIds(m).length,
                    actions: _actionsFor(m),
                    onTap: () {
                      if (_selecting) {
                        _toggleSelect(m);
                      } else {
                        // P3-2：点开详情看正文与附件（图片可放大）
                        showMessageDetail(context, m);
                      }
                    },
                    onLongPress: () {
                      if (!_selecting) {
                        setState(() {
                          _selecting = true;
                          _selected.add(m.id);
                        });
                      }
                    },
                  );
                },
              ),
          ],
        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }

  Widget _buildSelectionBar() {
    final targets = _selectedMessages;
    final hasSelection = targets.isNotEmpty;
    final anyJunk =
        targets.any((m) => m.priority == MessagePriority.junk);
    final allJunk = hasSelection &&
        targets.every((m) => m.priority == MessagePriority.junk);
    final allLinked = hasSelection &&
        targets.every((m) => _linkedTaskIds(m).isNotEmpty);
    final selectedIds = [for (final m in targets) m.id];
    return SelectionActionBar(
      actions: [
        SelectionAction(
          icon: Icons.archive_outlined,
          tooltip: '归档',
          enabled: hasSelection,
          onTap: () => _runBatch(_archive),
        ),
        SelectionAction(
          icon: Icons.block,
          tooltip: '标记垃圾',
          enabled: hasSelection && !anyJunk,
          onTap: () => _runBatch(_markJunk),
        ),
        SelectionAction(
          icon: Icons.restore,
          tooltip: '移出垃圾',
          enabled: allJunk,
          onTap: () => _runBatch(_unjunk),
        ),
        SelectionAction(
          icon: Icons.delete_outline,
          tooltip: '取消任务',
          enabled: allLinked,
          onTap: () => _runBatch(_deleteLinkedTasks),
        ),
        SelectionAction(
          icon: Icons.add_task,
          tooltip: '创建任务',
          enabled: targets.length == 1,
          onTap: () {
            final m = targets.first;
            _exitSelection();
            _createTask(m);
          },
        ),
        SelectionAction(
          icon: Icons.auto_awesome,
          tooltip: '自动处理',
          enabled: hasSelection,
          onTap: () {
            _exitSelection();
            _processWithAi(selectedIds);
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: Column(
        children: [
          if (_listenerEnabled == false) _buildListenerBanner(context),
          _buildFilterRow(context),
          const Divider(height: 1),
          Expanded(
            child: RefreshIndicator(
              onRefresh: reload,
              child: _buildList(),
            ),
          ),
          if (_selecting) _buildSelectionBar(),
        ],
      ),
    );
  }
}

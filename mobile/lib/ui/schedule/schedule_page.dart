import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/task.dart';
import '../../services/database.dart';
import '../../services/task_scale.dart';
import '../../services/undo_service.dart';
import '../messages/message_widgets.dart';
import '../shared/segmented_selector.dart';
import '../tasks/task_detail_panel.dart';
import '../tasks/task_editor.dart';
import '../tasks/task_tile.dart';
import 'day_view.dart';
import 'month_view.dart';
import 'schedule_shared.dart';
import 'year_view.dart';
import 'yearly_view.dart';

/// 日程页（设计 §2，v2.3/v2.4 修订）：年度/年/月/日四级视图均无限滚动。
///
/// v2.3 变更：
/// - 平移箭头移入标题栏（[←] 标题 [→]），控制条只留段选器（居中固定宽）
///   与「现在」按钮；
/// - 任务加载改为按可视窗口增量缓存（[onVisibleWindowChanged] 驱动），
///   视图滚动即加载，不再按"当前期"整期重查；
/// - 点选任务后底部板块切换为任务详情面板（[TaskDetailPanel]）。
///
/// v2.4 变更：
/// - 各视图 onVisibleWindowChanged 上报**精确可视范围**（加载提前量在
///   [_ensureRange] 内统一加），底部任务面板 = 可视范围 ∩ scalesForView
///   放行集合的全部任务（不再限定单一尺度，年度视图也显示）；
/// - 标题：年度 = 实际可视年份范围（随缩放），年 = 「2026」、
///   月 = 「2026-10」、日 = 「2026-10-14 周三」。
///
/// 尺度过滤表（§2）：年度视图 = yearly；年视图 = quarterly/monthly/weekly；
/// 月视图 = weekly/daily；日视图 = timed；不定时不进日程。
/// （v2.4：is_annual UI 下线，不再逐年平移/特判。）
///
/// 通过 GlobalKey<SchedulePageState> 暴露 [SchedulePageState.reload]，
/// 供壳层切页时刷新（与其他页一致）。
class SchedulePage extends StatefulWidget {
  const SchedulePage({super.key});

  @override
  State<SchedulePage> createState() => SchedulePageState();
}

class SchedulePageState extends State<SchedulePage> {
  /// 0=年度 1=年 2=月 3=日
  int _granularity = 0;

  /// 当前视图的可视中心（由各视图 onCenterChanged 回写）。
  DateTime _anchor = DateTime.now();

  Task? _selectedTask;

  /// 底部面板模式（v2.5）：false=任务列表（默认），true=任务详情。
  /// 图表点选只选中（列表高亮定位），不直接进详情；列表行点击才进详情。
  bool _detailMode = false;

  /// 底部列表行 key（选中任务滚动定位用）。
  final Map<String, GlobalKey> _bottomRowKeys = {};

  /// 当前视图的精确可视范围（各视图 onVisibleWindowChanged 上报，v2.4）——
  /// 用于底部任务面板与年度标题。
  int? _visStartMs;
  int? _visEndMs;

  /// 增量任务缓存：覆盖 [_cacheStart, _cacheEnd] 区间（按 id 覆盖式合并）。
  final Map<String, Task> _cache = {};
  int? _cacheStart;
  int? _cacheEnd;
  bool _loading = true;

  // ---- P1 性能：_cache 派生列表缓存 ----
  /// _cache 内容版本：任何写入（清空/合并）都递增，用于失效派生列表。
  int _cacheRevision = 0;

  /// 甘特区任务列表缓存（键 = _cache 版本 + 当前粒度）。
  ///
  /// 注意：读取端 [_ganttTasks] 必须 lazy memo —— 未命中就**现算并回填**，
  /// 绝不能返回默认空列表，否则会静默降级成「图表整块没任务」。
  List<Task>? _ganttCache;
  int _ganttCacheRevision = -1;
  int _ganttCacheGranularity = -1;

  final _yearlyKey = GlobalKey<YearlyViewState>();
  final _yearKey = GlobalKey<YearViewState>();
  final _monthKey = GlobalKey<MonthViewState>();
  final _dayKey = GlobalKey<DayViewState>();

  // ---- F13②：图表区 / 底部面板 可拖动分割线 ----

  /// 图表区占（可用高度）的比例，默认 0.6；拖分割线改它，夹在
  /// [_splitRatioMin]~[_splitRatioMax]，松手写 SharedPreferences。
  static const _splitPrefsKey = 'schedule_split_ratio';
  /// 下限 0.4（Lead 2026-10-20 拍板）：日视图顶部固定 204px（名称带 160 +
  /// 刻度带 44），再低会让可视行区变成 0 —— 「拖到最小等于什么都看不见」。
  static const _splitRatioMin = 0.4;
  static const _splitRatioMax = 0.85;

  /// 分割线手柄高度（含细分隔线 + 中间短横条）。
  static const _splitHandleH = 22.0; // 拖动条高度（加大热区，2026-10-21 用户反馈难点中）

  /// 顶部拖动区高度：图表最上方的日期/刻度带（用户 2026-10-21 说的「黄色区域」）。
  static const _topDragBandH = 26.0; // 顶部可见拖动条高度

  double _splitRatio = 0.6;

  @override
  void initState() {
    super.initState();
    _loadSplitRatio();
    reload();
  }

  /// 启动时读回上次拖好的分割比例（读不到就用默认 0.6）。
  Future<void> _loadSplitRatio() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble(_splitPrefsKey);
      if (saved == null || !mounted) return;
      setState(() => _splitRatio =
          saved.clamp(_splitRatioMin, _splitRatioMax).toDouble());
    } catch (_) {
      // 读取失败保持默认比例，不影响页面
    }
  }

  /// 松手落库：下次进入日程页沿用这次拖出来的比例。
  Future<void> _saveSplitRatio() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_splitPrefsKey, _splitRatio);
    } catch (_) {
      // 写入失败只影响记忆，不影响本次布局
    }
  }

  /// F13②：分割手柄——**图表区与下方任务栏的分界线**（tooltip 语义：
  /// 拖动这条线 = 调整上方图表 / 下方任务列表的高度）。
  /// 上下拖动改 [_splitRatio]；只吃竖直手势，与图表区内部的横向
  /// 平移/缩放不冲突。
  /// 顶部可见拖动条：向下拖 = 日程表变高（调整的是日程表，不是任务栏）。
  /// 2026-10-21 用户反馈「不知道按哪里才能拖」，所以做成有底色、有图标、有文案的显式手柄。
  Widget _topGrip(double avail) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (d) {
        if (avail <= 0) return;
        final next = (_splitRatio + d.delta.dy / avail)
            .clamp(_splitRatioMin, _splitRatioMax);
        if (next != _splitRatio) setState(() => _splitRatio = next.toDouble());
      },
      onVerticalDragEnd: (_) => _saveSplitRatio(),
      onVerticalDragCancel: _saveSplitRatio,
      child: Container(
        height: _topDragBandH,
        width: double.infinity,
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.drag_handle, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text('拖动这里调整日程表高度',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget _splitHandle(double avail) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (d) {
        if (avail <= 0) return;
        final next =
            (_splitRatio + d.delta.dy / avail).clamp(_splitRatioMin, _splitRatioMax);
        if (next != _splitRatio) setState(() => _splitRatio = next.toDouble());
      },
      onVerticalDragEnd: (_) => _saveSplitRatio(),
      onVerticalDragCancel: _saveSplitRatio,
      child: SizedBox(
        height: _splitHandleH,
        width: double.infinity,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 细分隔线（贯穿整宽）
            Positioned.fill(
              child: Align(
                alignment: Alignment.center,
                child: Container(
                  height: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.7),
                ),
              ),
            ),
            // 中间短横条（拖拽热区提示）
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
              // 底色让「这里可以拖」更明显（用户 2026-10-21）
              Positioned.fill(
                child: ColoredBox(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// F13②：图表区 + 可拖动分割线 + 底部面板。
  ///
  /// 两个面板按像素高度（[_splitRatio]）分配，不再用固定 flex，
  /// 这样拖分割线就真的能改变图表区高度（日视图行多了可以拉高）。
  Widget _splitBody(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final total = constraints.maxHeight;
      if (!total.isFinite || total <= 0) {
        // 兜底：高度未知时退回原来的固定 flex 布局
        return Column(children: [
          Expanded(flex: 3, child: _ganttView()),
          Expanded(flex: 2, child: _bottomSection(context)),
        ]);
      }
      final avail =
          (total - _splitHandleH).clamp(0.0, double.infinity).toDouble();
      final ganttH = avail * _splitRatio;
      final bottomH = avail - ganttH;
      return Column(children: [
          // 图表区：顶部一条**可见的拖动条**（用户 2026-10-21：拖它调整日程表高度，且要有 UI 提示）。
          SizedBox(
            height: ganttH,
            child: Column(children: [
              _topGrip(avail),
              Expanded(child: _ganttView()),
            ]),
          ),
          _splitHandle(avail),
        SizedBox(height: bottomH, child: _bottomSection(context)),
      ]);
    });
  }

  /// _cache 内容变了：递增版本，派生列表（[_ganttTasks]）下次读到时按需重算。
  void _markCacheDirty() => _cacheRevision++;

  /// 初始/全量刷新：清空缓存，加载可视中心 ±2 年。
  Future<void> reload() async {
    _cache.clear();
    _markCacheDirty();
    _cacheStart = null;
    _cacheEnd = null;
    final y = _anchor.year;
    await _ensureRange(
      DateTime(y - 2).millisecondsSinceEpoch,
      DateTime(y + 3).millisecondsSinceEpoch,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      final sel = _selectedTask;
      if (sel != null) _selectedTask = _cache[sel.id] ?? sel;
    });
  }

  /// 视口超出缓存范围时增量加载（向两侧各扩一个窗口宽做提前量）。
  Future<void> _ensureRange(int startMs, int endMs) async {
    final cs = _cacheStart, ce = _cacheEnd;
    if (cs != null && ce != null && startMs >= cs && endMs <= ce) return;
    final span = endMs - startMs;
    final ns = (cs == null
            ? startMs
            : (startMs < cs ? startMs : cs)) -
        span;
    final ne =
        (ce == null ? endMs : (endMs > ce ? endMs : ce)) + span;
    final db = AppDatabase.instance;
    // active 为主，done 淡色/划线展示；archived 不显示。
    // getTasksOverlapping 无条件包含年度任务，这里按平移后的发生年过滤。
    final results = await Future.wait([
      db.getTasksOverlapping(ns, ne),
      db.getTasksOverlapping(ns, ne, status: TaskStatus.done),
    ]);
    final tasks = [...results[0], ...results[1]]
        .where((t) => occurrenceOverlapping(t, ns, ne) != null);
    if (!mounted) return;
    setState(() {
      for (final t in tasks) {
        _cache[t.id] = t;
      }
      _cacheStart =
          _cacheStart == null ? ns : (_cacheStart! < ns ? _cacheStart! : ns);
      _cacheEnd = _cacheEnd == null ? ne : (_cacheEnd! > ne ? _cacheEnd! : ne);
      _markCacheDirty(); // 合并进 _cache 后派生列表失效
    });
  }

  /// 甘特区任务：按当前粒度的尺度过滤表过滤（v2.4：不再对 is_annual
  /// 特判——该概念 UI 下线，老数据按派生尺度进各视图）。
  ///
  /// P1：按（_cache 版本, 粒度）lazy 缓存。原来每次 build 都会对全量 _cache
  /// 重跑 scalesForView + 全表 filter + toList：可视窗口滚动
  /// [_onWindowChanged] 每次 setState 都重来一遍，且下发给子视图的列表
  /// 每帧都是新实例（子视图还得逐项比内容）。命中时直接返回同一个 List。
  List<Task> get _ganttTasks {
    final cached = _ganttCache;
    if (cached != null &&
        _ganttCacheRevision == _cacheRevision &&
        _ganttCacheGranularity == _granularity) {
      return cached;
    }
    // 未命中：现算并回填（禁止返回默认空列表）
    final tasks = _filterByScales(_ganttScaleView);
    _ganttCache = tasks;
    _ganttCacheRevision = _cacheRevision;
    _ganttCacheGranularity = _granularity;
    return tasks;
  }

  /// 当前粒度对应的尺度放行集合名（与 [_filterByScales] 入参同一套映射）。
  String get _ganttScaleView => switch (_granularity) {
        0 => 'yearly',
        1 => 'year',
        2 => 'month',
        _ => 'day',
      };

  List<Task> _filterByScales(String view) {
    final scales = scalesForView(view);
    return _cache.values
        .where((t) =>
              scales.contains(deriveTaskScale(t.startAt, t.endAt, kind: t.kind)))
        .toList();
  }

  /// 底部任务列表板块（v2.4 §13 修订）：当前**可视时间范围**内、且尺度在
  /// 当前视图放行集合（scalesForView）内的全部任务，不再限定单一尺度；
  /// 年度视图同样显示（放行集合 = yearly）。
  List<Task> get _bottomTasks {
    final viewName =
        const ['yearly', 'year', 'month', 'day'][_granularity];
    final scales = scalesForView(viewName);
    final vs = _visStartMs, ve = _visEndMs;
    if (vs == null || ve == null) return const [];
    return _cache.values
        .where((t) =>
            t.status == TaskStatus.active &&
            t.startAt != null &&
            scales.contains(deriveTaskScale(t.startAt, t.endAt, kind: t.kind)) &&
            occurrenceOverlapping(t, vs, ve) != null)
        .toList()
      ..sort((a, b) => a.startAt!.compareTo(b.startAt!));
  }

  void _showUndoSnack(String label) {
    showUndoSnackBar(context, label, onUndone: () async => reload());
  }

  Future<void> _editTask(Task task) async {
    final result = await showTaskEditor(context, existing: task);
    if (result == null || !mounted) return;
    final db = AppDatabase.instance;
    if (result.deleted) {
      // 删父任务前先把子任务升级为普通任务（parent_id 置空），
      // 与删除合并为一个复合撤销（设计 §7）。
      final children = await db.getChildTasks(task.id);
      for (final c in children) {
        await db.updateTask(c.copyWith(parentId: () => null));
      }
      await db.deleteTasks([task.id]);
      UndoService.instance.register(
        label: '已删除',
        undo: () async {
          await db.insertTask(task);
          for (final c in children) {
            await db.updateTask(c);
          }
        },
      );
      if (!mounted) return; // P3-5：删除后可能已离开页面
      setState(() => _selectedTask = null);
      _detailMode = false;
      await reload();
      if (mounted) _showUndoSnack('已删除');
    } else if (result.task != null) {
      if (result.parentExpanded != null) {
        await db.updateTask(result.parentExpanded!);
      }
      await db.updateTask(result.task!);
      final parentBefore = result.parentBefore;
      UndoService.instance.register(
        label: '已保存',
        undo: () async {
          await db.updateTask(task);
          if (parentBefore != null) await db.updateTask(parentBefore);
        },
      );
      await reload();
      if (mounted) _showUndoSnack('已保存');
    }
  }

  Future<void> _createTask({int? seedStartAt, String? seedKind}) async {
    final result = await showTaskEditor(context,
        seedStartAt: seedStartAt, seedKind: seedKind);
    final task = result?.task;
    if (result == null || result.deleted || task == null || !mounted) return;
    final db = AppDatabase.instance;
    if (result.parentExpanded != null) {
      await db.updateTask(result.parentExpanded!);
    }
    await db.insertTask(task);
    final parentBefore = result.parentBefore;
    UndoService.instance.register(
      label: '已新建',
      undo: () async {
        await db.deleteTasks([task.id]);
        if (parentBefore != null) await db.updateTask(parentBefore);
      },
    );
    await reload();
    if (mounted) _showUndoSnack('已新建');
  }

  /// 拖拽落库：更新时间 + 撤销（恢复旧任务）+ 刷新。
  Future<void> _moveTask(Task task, int newStartMs, int? newEndMs) async {
    final updated = task.copyWith(
      startAt: () => newStartMs,
      endAt: () => newEndMs,
    );
    final db = AppDatabase.instance;
    await db.updateTask(updated);
    UndoService.instance.register(
      label: '已调整时间',
      undo: () => db.updateTask(task),
    );
    await reload();
    if (mounted) _showUndoSnack('已调整时间');
  }

  /// 勾选完成/取消完成（底部板块，设计 §2 行 UI 照搬待办页）。
  Future<void> _toggleDone(Task task) =>
      toggleTaskDoneWithUndo(context, task, onChanged: reload);

  /// 详情面板中点父/子任务：按目标任务的尺度切换到能展示它的粒度并定位，
  /// 选中并展示其详情。
  void _jumpToTask(Task t) {
    final s = t.startAt;
    if (s == null) return; // 不定时任务在日程无视图可跳
    final g = switch (deriveTaskScale(t.startAt, t.endAt, kind: t.kind)) {
      'yearly' => 0,
      'quarterly' || 'monthly' => 1,
      'weekly' || 'daily' => 2,
      _ => 3,
    };
    setState(() {
      _granularity = g;
      _selectedTask = t;
      _detailMode = true;
      _anchor = DateTime.fromMillisecondsSinceEpoch(s);
    });
    _afterTwoFrames(() {
      switch (g) {
        case 0:
          _yearlyKey.currentState?.scrollToTask(t);
        case 1:
          _yearKey.currentState?.scrollToTask(t);
        case 2:
          _monthKey.currentState?.scrollToTask(t);
        case 3:
          _dayKey.currentState?.scrollToTask(t);
      }
    });
  }

  /// 等两帧再定位：第一帧新视图挂载（其首帧 scrollToNow），第二帧覆盖到目标。
  void _afterTwoFrames(VoidCallback fn) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) => fn());
    });
  }

  /// 图表点选（v2.5）：只选中——图表描边 + 底部列表滚动高亮定位，
  /// 不直接打开详情；空白取消选中时详情模式一并退出。
  void _onTaskSelected(Task? t) {
    setState(() {
      _selectedTask = t;
      if (t == null) {
        _detailMode = false;
      }
    });
    if (t == null) return;
    // 选中的任务应当就在底部列表（同一可视范围 ∩ 尺度集合）；
    // 边界情况（拖拽出可视范围等）给短暂提示
    if (!_bottomTasks.any((e) => e.id == t.id)) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content: Text('该任务不在当前可视范围的任务列表中'),
            duration: Duration(seconds: 2)));
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _bottomRowKeys[t.id]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          alignment: 0.5,
        );
      }
    });
  }

  /// 可视窗口变化：记录精确可视范围（底部面板/标题用）+ 增量加载。
  void _onWindowChanged(int startMs, int endMs) {
    setState(() {
      _visStartMs = startMs;
      _visEndMs = endMs;
    });
    _ensureRange(startMs, endMs);
  }

  /// 兜底窗口（B01，2026-10-20）：各视图的可视范围是首帧 post-frame 才上报的，
  /// 在那之前 `_visStartMs/_visEndMs` 为 null，`_bottomTasks` 直接返回空数组 ——
  /// 表现就是「刚进年度视图，底部显示任务 0，图上明明有任务」。
  /// 这里按当前粒度与锚点推算一个合理的默认窗口，视图上报后再被真实值覆盖。
  String _windowSeedKey = '';

  void _maybeSeedWindow() {
    final key = '$_granularity|${_anchor.year}-${_anchor.month}-${_anchor.day}';
    if (_visStartMs != null && _windowSeedKey == key) return;
    _windowSeedKey = key;
    final a = _anchor;
    late DateTime s, e;
    switch (_granularity) {
      case 0: // 年度视图：±20 年（与标题区间一致）
        s = DateTime(a.year - 20);
        e = DateTime(a.year + 21);
      case 1: // 年视图
        s = DateTime(a.year);
        e = DateTime(a.year + 1);
      case 2: // 月视图
        s = DateTime(a.year, a.month);
        e = DateTime(a.year, a.month + 1);
      default: // 日视图
        s = DateTime(a.year, a.month, a.day);
        e = DateTime(a.year, a.month, a.day + 1);
    }
    _visStartMs = s.millisecondsSinceEpoch;
    _visEndMs = e.millisecondsSinceEpoch;
  }

  /// 标题栏箭头平移：年度 ±20 年、年 ±1 年、月 ±1 月、日 ±1 天。
  void _shiftPeriod(int delta) {
    final target = switch (_granularity) {
      0 => DateTime(_anchor.year + delta * 20, _anchor.month),
      1 => DateTime(_anchor.year + delta, _anchor.month),
      2 => DateTime(_anchor.year, _anchor.month + delta),
      _ => DateTime(_anchor.year, _anchor.month, _anchor.day + delta),
    };
    setState(() => _anchor = target);
    switch (_granularity) {
      case 0:
        _yearlyKey.currentState?.scrollTo(target);
      case 1:
        _yearKey.currentState?.scrollTo(target);
      case 2:
        _monthKey.currentState?.scrollTo(target);
      case 3:
        _dayKey.currentState?.scrollTo(target);
    }
  }

  void _goNow() {
    switch (_granularity) {
      case 0:
        _yearlyKey.currentState?.scrollToNow();
      case 1:
        _yearKey.currentState?.scrollToNow();
      case 2:
        _monthKey.currentState?.scrollToNow();
      case 3:
        _dayKey.currentState?.scrollToNow();
    }
  }

  /// AppBar 标题（v2.4）：年度 = 实际可视年份范围（随缩放变化）；
  /// 年 = 「2026」；月 = 「2026-10」；日 = 「2026-10-14 周三」。
  String get _title {
    switch (_granularity) {
      case 0:
        final vs = _visStartMs, ve = _visEndMs;
        if (vs != null && ve != null) {
          final first = DateTime.fromMillisecondsSinceEpoch(vs).year;
          final last =
              DateTime.fromMillisecondsSinceEpoch(ve - 1).year;
          return '$first–$last';
        }
        return '${_anchor.year - 10}–${_anchor.year + 9}';
      case 2:
        final m = _anchor.month.toString().padLeft(2, '0');
        return '${_anchor.year}-$m';
      case 3:
        const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
        final mo = _anchor.month.toString().padLeft(2, '0');
        final d = _anchor.day.toString().padLeft(2, '0');
        return '${_anchor.year}-$mo-$d ${weekdays[_anchor.weekday - 1]}';
      default:
        return '${_anchor.year}';
    }
  }

  Widget _ganttView() {
    final tasks = _ganttTasks;
    switch (_granularity) {
      case 0:
        return YearlyView(
          key: _yearlyKey,
          tasks: tasks,
          selectedTaskId: _selectedTask?.id,
          onTaskSelected: _onTaskSelected,
          onTaskMoved: _moveTask,
          onYearTap: _drillToYear,
          onVisibleWindowChanged: _onWindowChanged,
          onCenterChanged: (c) => setState(() => _anchor = c),
        );
      case 2:
        return MonthView(
          key: _monthKey,
          tasks: tasks,
          selectedTaskId: _selectedTask?.id,
          onTaskSelected: _onTaskSelected,
          onDayTap: _drillToDay,
          onTaskMoved: _moveTask,
          onBlankLongPress: (ms) => _createTask(
            seedStartAt: ms + const Duration(hours: 9).inMilliseconds,
            seedKind: TaskKind.point,
          ),
          onVisibleWindowChanged: _onWindowChanged,
          onCenterChanged: (c) => setState(() => _anchor = c),
        );
      case 3:
        return DayView(
          key: _dayKey,
          tasks: tasks,
          selectedTaskId: _selectedTask?.id,
          onTaskSelected: _onTaskSelected,
          onTaskMoved: _moveTask,
          onBlankLongPress: (ms) => _createTask(
            seedStartAt: ms,
            seedKind: TaskKind.point,
          ),
          onVisibleWindowChanged: _onWindowChanged,
          onCenterChanged: (c) => setState(() => _anchor = c),
        );
      default:
        return YearView(
          key: _yearKey,
          tasks: tasks,
          selectedTaskId: _selectedTask?.id,
          onTaskSelected: _onTaskSelected,
          onMonthTap: _drillToMonth,
          onTaskMoved: _moveTask,
          onBlankLongPress: (ms) {
            final m = DateTime.fromMillisecondsSinceEpoch(ms);
            _createTask(
              seedStartAt:
                  DateTime(m.year, m.month, 1, 9).millisecondsSinceEpoch,
              seedKind: TaskKind.range,
            );
          },
          onVisibleWindowChanged: _onWindowChanged,
          onCenterChanged: (c) => setState(() => _anchor = c),
        );
    }
  }

  void _drillToYear(int year) {
    final target = DateTime(year, 7);
    setState(() {
      _granularity = 1;
      _selectedTask = null;
      _detailMode = false;
      _anchor = target;
    });
    _afterTwoFrames(() => _yearKey.currentState?.scrollTo(target));
  }

  void _drillToMonth(int monthMs) {
    final m = DateTime.fromMillisecondsSinceEpoch(monthMs);
    final target = DateTime(m.year, m.month, 15);
    setState(() {
      _granularity = 2;
      _selectedTask = null;
      _detailMode = false;
      _anchor = target;
    });
    _afterTwoFrames(() => _monthKey.currentState?.scrollTo(target));
  }

  void _drillToDay(int dayMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(dayMs);
    final target = DateTime(d.year, d.month, d.day);
    setState(() {
      _granularity = 3;
      _selectedTask = null;
      _detailMode = false;
      _anchor = target;
    });
    _afterTwoFrames(() => _dayKey.currentState?.scrollTo(target));
  }

  /// 底部板块（v2.5 双模式）：详情模式 = TaskDetailPanel（带返回按钮）；
  /// 列表模式 = 可视范围任务列表（选中行高亮，点击行进详情）。
  Widget _bottomSection(BuildContext context) {
    final selected = _selectedTask;
    if (_detailMode && selected != null) {
      return Column(children: [
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            child: TaskDetailPanel(
              key: ValueKey(selected.id),
              task: selected,
              onClose: () => setState(() => _detailMode = false),
              onEdit: () => _editTask(selected),
              onOpenTask: _jumpToTask,
            ),
          ),
        ),
      ]);
    }
    final tasks = _bottomTasks;
    return Column(
      children: [
        const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
            child: Row(
              children: [
                Text('任务', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(width: 8),
                Text('${tasks.length}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          Expanded(
            child: tasks.isEmpty
                ? Center(
                    child: Text('无',
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  )
                : ListView.builder(
                    itemCount: tasks.length,
                    itemBuilder: (context, i) {
                      final task = tasks[i];
                      return TaskTile(
                        key: _bottomRowKeys.putIfAbsent(
                            task.id, () => GlobalKey()),
                        task: task,
                        selected: task.id == _selectedTask?.id,
                        onTap: () => setState(() {
                          _selectedTask = task;
                          _detailMode = true;
                        }),
                        onToggleDone: () => _toggleDone(task),
                        onShowSource: task.sourceMessageId == null
                            ? null
                            : () => _showSourceMessage(task.sourceMessageId!),
                      );
                    },
                  ),
        ),
      ],
    );
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

  @override
  Widget build(BuildContext context) {
    // B01：视图还没上报可视窗口时，先用推算窗口，避免底部「任务 0」闪一下
    _maybeSeedWindow();

    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          IconButton(
            tooltip: '上一期',
            visualDensity: VisualDensity.compact,
            onPressed: () => _shiftPeriod(-1),
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(child: Center(child: Text(_title))),
          IconButton(
            tooltip: '下一期',
            visualDensity: VisualDensity.compact,
            onPressed: () => _shiftPeriod(1),
            icon: const Icon(Icons.chevron_right),
          ),
        ]),
      ),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 260,
                    child: SegmentedSelector<int>(
                      values: const [0, 1, 2, 3],
                      labels: const ['年度', '年', '月', '日'],
                      selected: _granularity,
                      onChanged: (i) {
                        if (i == _granularity) return;
                        setState(() {
                          _granularity = i;
                          _selectedTask = null;
                          _detailMode = false;
                        });
                        _afterTwoFrames(() {
                          switch (i) {
                            case 0:
                              _yearlyKey.currentState?.scrollTo(_anchor);
                            case 1:
                              _yearKey.currentState?.scrollTo(_anchor);
                            case 2:
                              _monthKey.currentState?.scrollTo(_anchor);
                            case 3:
                              _dayKey.currentState?.scrollTo(_anchor);
                          }
                        });
                      },
                    ),
                  ),
                  TextButton(onPressed: _goNow, child: const Text('现在')),
                ],
              ),
            ),
          ),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else
            // F13②：图表区 + 可拖动分割线 + 底部面板。
            // v2.4：底部面板所有粒度都显示（含年度）。
            Expanded(child: _splitBody(context)),
        ],
      ),
    );
  }
}

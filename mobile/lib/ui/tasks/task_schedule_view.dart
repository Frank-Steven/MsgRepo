import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/task.dart';
import '../../services/database.dart';
import '../../services/task_scale.dart';
import '../../services/undo_service.dart';
import '../messages/message_widgets.dart';
import 'task_detail_panel.dart';
import 'task_editor.dart';
import 'task_tile.dart';
import 'views/day_view.dart';
import 'views/month_view.dart';
import 'views/schedule_shared.dart';
import 'views/year_view.dart';
import 'views/yearly_view.dart';

/// 任务页·甘特视图宿主（原日程页 SchedulePage，v3 阶段 4 改造；设计 §2，v2.3/v2.4 修订）：
/// 年度/年/月/日四级视图均无限滚动。
///
/// v3 阶段 4 变更：
/// - 粒度不再由本组件内的段选器控制，改由 [granularity] 构造参数下发
///   （任务页顶部「列表/日/月/年/年度」切换）；「现在」按钮移入 AppBar actions；
/// - 详情面板跳父/子任务需要跨粒度时经 [onSwitchGranularity] 回调请求
///   宿主（任务页）切换视图模式。
///
/// 历史行为（保持不变）：
/// - 任务加载按可视窗口增量缓存（[onVisibleWindowChanged] 驱动），
///   视图滚动即加载，不再按"当前期"整期重查；
/// - 各视图 onVisibleWindowChanged 上报**精确可视范围**（加载提前量在
///   [_ensureRange] 内统一加），底部任务面板 = 可视范围 ∩ scalesForView
///   放行集合的全部任务；
/// - 标题：年 = 「2026」、月 = 「2026-10」、日 = 「2026-10-14 周三」。
///
/// 尺度过滤表（§2）：年视图 = quarterly/monthly/weekly；
/// 月视图 = weekly/daily；日视图 = timed；不定时不进甘特视图。
class TaskScheduleView extends StatefulWidget {
  /// 0=年度 1=年 2=月 3=日（由任务页视图切换器下发）。
  final int granularity;

  /// 详情面板跳转需要切到别的粒度时回调（宿主负责换 mode 并重建本组件）。
  final ValueChanged<int>? onSwitchGranularity;

  const TaskScheduleView({
    super.key,
    required this.granularity,
    this.onSwitchGranularity,
  });

  @override
  State<TaskScheduleView> createState() => TaskScheduleViewState();
}

class TaskScheduleViewState extends State<TaskScheduleView> {
  /// 当前视图的可视中心（由各视图 onCenterChanged 回写）。
  DateTime _anchor = DateTime.now();

  Task? _selectedTask;

  /// 底部面板模式（v2.5）：false=任务列表（默认），true=任务详情。
  /// 图表点选只选中（列表高亮定位），不直接进详情；列表行点击才进详情。
  bool _detailMode = false;

  /// _jumpToTask 主动换粒度时置位：didUpdateWidget 不重置选中/详情。
  bool _pendingJump = false;

  /// 底部列表行 key（选中任务滚动定位用）。
  final Map<String, GlobalKey> _bottomRowKeys = {};

  /// 当前视图的精确可视范围（各视图 onVisibleWindowChanged 上报，v2.4）——
  /// 用于底部任务面板与标题。
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

  // ---- F13②：图表区 / 任务栏 / 标签带 三段独立高度（2026-10-21）----
  //
  // 设计原则（用户要求：拖其中一条时另一部分不许跟着动）：
  //  · `_barH`（任务栏）与 `_nameBandH`（45° 标签带）**互相独立**，各自持久化；
  //  · **顶部抓手** = 图表内部那条（day_view 自绘自收手势）：它跟着手指走，
  //    改的是「标签带高度」`_nameBandH` —— 抓手自己移动、任务栏纹丝不动，行区相应增减；
  //  · **底部抓手** = 页面里那条：只改 `_barH`（任务栏高度），图表随之变高/变矮；
  //  · 图表高度 = 视口 − 底部抓手 − 任务栏（永远铺满，无页面滚动）。
  static const _barPrefsKey = 'schedule_bar_height';
  static const _nameBandPrefsKey = 'schedule_name_band_h';
  static const _chartMinH = 250.0; // 行程 = avail − 图表下限 − 任务栏下限（该式对两侧恒等）。三轮调参：250/250→97（太小）→200/200→197（翻倍）→250/60→≈287（约三倍）
  // 2026-10-21：310/60 → 250/250（行程≈97，用户嫌太小）→ 200/200（行程≈197，约翻倍）
  // 2026-10-21 用户要求「任务栏可拖范围 = 日程表可拖范围」，故两者都取 250（图表固定 chrome 236 + 余量）
  static const _barMinH = 60.0;

  /// 45° 标签带高度的下限 / 默认值（default 与 day_view 的 nameLayerH 保持一致）。
  static const _nameBandMin = 70.0;
  static const _nameBandDefault = 160.0;

  /// 图表内部固定的两条带高（与 day_view 的常量对齐）：
  /// 刻度带 44 + 行高 34。标签带上限要留出「空槽 + 刻度带 + 至少 2 行 + 余量」。
  static const _dayHeaderH = 44.0;
  static const _dayLaneH = 34.0;

  /// 两条手柄共用的高度（可见的灰色拖动条 + 短横条）。
  static const _handleH = 32.0; // 拖动手柄高度：加大热区，手指更容易按住（2026-10-21）

  double? _barH; // 任务栏高度；null = 用默认比例

  /// 45° 标签带（顶部抓手拖出来的那段）高度，持久化。
  double _nameBandH = _nameBandDefault;
  double? _nameBandStart; // 按下瞬间的标签带高度（绝对映射用）

  /// 底部手柄的上一次指针 y（必须存在 State 上：拖动会触发 setState 重建，
  /// 局部变量会被重置，导致「只有第一帧生效」。2026-10-21 踩过这个坑。）
  /// 顶部抓手的起始 y 现在由 day_view 自己持有（方案 1b：图表自绘自收手势）。
  double? _dragLastYBar;
  double? _barDragStart; // 按下瞬间的任务栏高度（绝对映射用）

  /// 分栏区域的视口高度（_splitBody 布局时记录）：抓手拖动回调靠它换算边界，
  /// 这样顶部抓手（在 day_view 内部）也能共用同一套逻辑，不必互传坐标。
  double _splitVp = 0;

  @override
  void initState() {
    super.initState();
    _loadHeights();
    reload();
  }

  @override
  void didUpdateWidget(TaskScheduleView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.granularity == widget.granularity) return;
    if (_pendingJump) {
      // _jumpToTask 主动换粒度：选中/详情保留，滚动由 _jumpToTask 自己安排
      _pendingJump = false;
      return;
    }
    // 宿主切换视图模式：清选中并滚动到当前锚点（原段选器 onChanged 的行为）
    setState(() {
      _selectedTask = null;
      _detailMode = false;
    });
    _afterTwoFrames(() => _scrollCurrentTo(_anchor));
  }

  /// 读回上次拖好的高度（读不到就用默认值）。
  Future<void> _loadHeights() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bar = prefs.getDouble(_barPrefsKey);
      final nameBand = prefs.getDouble(_nameBandPrefsKey);
      setState(() {
        if (bar != null) _barH = bar;
        if (nameBand != null) _nameBandH = nameBand;
      });
    } catch (_) {
      // 读失败用默认布局，不影响使用
    }
  }

  Future<void> _saveHeights() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bar = _barH;
      if (bar != null) await prefs.setDouble(_barPrefsKey, bar);
      await prefs.setDouble(_nameBandPrefsKey, _nameBandH);
    } catch (_) {
      // fire-and-forget：写失败只影响下次进入的默认值
    }
  }

  /// 拖动手柄：`Listener` 直接吃原始指针（不走手势竞技场），
  /// 并用「按下点 → 当前点」的累计位移换算新尺寸 —— 绝对映射才跟手，
  /// 逐帧增量会因丢帧显得滞后。
  Widget _handle({
    required String id,
    required double? Function() startYRead,
    required void Function(double?) startYWrite,
    required void Function(double dyFromPress) onDrag,
    required VoidCallback onEnd,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Listener(
      key: ValueKey('schedule-handle-$id'),
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        startYWrite(e.position.dy);
        onDrag(0);
      },
      onPointerMove: (e) {
        final s = startYRead();
        if (s == null) return;
        onDrag(e.position.dy - s);
      },
      onPointerUp: (_) {
        startYWrite(null);
        onEnd();
      },
      onPointerCancel: (_) => startYWrite(null),
      child: Container(
        height: _handleH,
        width: double.infinity,
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        alignment: Alignment.center,
        child: Container(
          width: 56,
          height: 4,
          decoration: BoxDecoration(
            color: scheme.outlineVariant,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }

  /// 安全版 clamp：当窗口太矮导致「下限 > 上限」时**返回上限**，
  /// 而不是抛 `Invalid argument(s)`（2026-10-21 年度视图下崩溃即此原因）。
  double _safeClamp(double v, double lo, double hi) =>
      lo <= hi ? v.clamp(lo, hi) : hi;

  /// 视口高度 → 任务栏允许的最大高度（图表至少保留 _chartMinH）。
  double _barMaxAt(double vp) {
    final avail = vp - _handleH;
    return _safeClamp(avail - _chartMinH, _barMinH, avail);
  }

  /// 视口高度 → 当前任务栏高度（未拖过时按 40% 默认比例）。
  double _barHAt(double vp) {
    final avail = vp - _handleH;
    return _safeClamp(_barH ?? avail * 0.40, _barMinH, _barMaxAt(vp));
  }

  /// 抓手拖动（顶部/底部共用）：绝对映射 —— 按下瞬间记起始高度，
  /// 之后一律用「当前指针 y − 按下指针 y」的累计位移换算，跟手不滞后。
  void _dragBoundary(double dyFromPress) {
    final vp = _splitVp;
    if (!vp.isFinite || vp <= 0) return;
    final barMax = _barMaxAt(vp);
    final barH = _barHAt(vp);
    final start = _barDragStart ??= barH;
    final next = _safeClamp(start - dyFromPress, _barMinH, barMax);
    if (next != (_barH ?? barH)) setState(() => _barH = next);
  }

  /// 视口高度 → 标签带允许的最大高度。
  ///
  /// 关键：**标签带行程要与分界线行程一致**，否则用户会觉得「任务栏能拖的比日程表少」。
  /// 分界线行程 = avail − 图表下限 − 任务栏下限；这里让 标签带上限 = 下限 + 同一行程，
  /// 再用「至少留 1 行」的布局上限夹一次，保证图表不会把行挤没。
  double _nameBandMaxAt(double vp) {
    if (!vp.isFinite || vp <= 0) return _nameBandMin;
    final avail = vp - _handleH;
    final travel = avail - _chartMinH - _barMinH;
    final chartH = _safeClamp(avail - _barHAt(vp), _chartMinH, avail);
    final byLayout = chartH - _handleH - _dayHeaderH - _dayLaneH;
    return _safeClamp(_nameBandMin + travel, _nameBandMin, byLayout);
  }

  /// 顶部抓手拖动：**绝对映射** —— 按下记起始标签带高度，之后用累计位移换算。
  /// 向下拖 = 标签带变高（抓手跟着手指走）、行区变矮；**任务栏高度完全不参与**。
  void _dragNameBand(double dyFromPress) {
    final vp = _splitVp;
    if (!vp.isFinite || vp <= 0) return;
    final start = _nameBandStart ??= _nameBandH;
    final next = _safeClamp(start + dyFromPress, _nameBandMin, _nameBandMaxAt(vp));
    if (next != _nameBandH) setState(() => _nameBandH = next);
  }

  /// 布局：**永远铺满屏幕**，自由度只有「任务栏高度」与「标签带高度」。
  ///
  /// 2026-10-21 用户反馈：拖红色（图表）→ 蓝色（任务栏）被拖着走、拖绿色（任务栏标题）→ 整页滚动、
  /// 在红色里滚动 → 也变成整页滚动。根因是上一版把整页放进 `SingleChildScrollView` 并允许两段各自独立
  /// 设高（会溢出/留白，手势全被页面滚动吃掉）。
  ///
  /// 现在改成标准分栏：`图表 = 视口 - 手柄 - 任务栏` 自动铺满，**不再有页面滚动**；
  /// 两个抓手（顶部那条在图表内、图表与任务栏之间那条在页面里）都是同一个边界的抓点：
  /// 往下拖 = 图表变高、任务栏变矮；往上拖反之。
  Widget _splitBody(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final vp = constraints.maxHeight;
      if (!vp.isFinite || vp <= 0) {
        return Column(children: [
          Expanded(flex: 3, child: _ganttView()),
          Expanded(flex: 2, child: _bottomSection(context)),
        ]);
      }
      final avail = vp - _handleH;
      final barH = _barHAt(vp);
      final chartH = _safeClamp(avail - barH, _chartMinH, avail);
      // 记录视口高度：底部抓手 + day_view 内部那条抓手都靠它换算边界
      _splitVp = vp;
      // 标签带高度按当前分栏几何夹紧：任务栏被拖大后，标签带不会把行区挤没
      _nameBandH = _safeClamp(_nameBandH, _nameBandMin, _nameBandMaxAt(vp));

      // F13②-方案1b：顶部抓手由 DayView 自己画、自己收指针（位置与图表几何
      // 天然对齐），页面侧不再叠 Positioned 抓手，否则两层会抢指针。
      return Column(children: [
        SizedBox(
          height: chartH,
          child: _ganttView(),
        ),
        _handle(
          id: 'bar',
          startYRead: () => _dragLastYBar,
          startYWrite: (v) => _dragLastYBar = v,
          onDrag: _dragBoundary,
          onEnd: () {
            _barDragStart = null;
            _saveHeights();
          },
        ),
        SizedBox(height: barH, child: _bottomSection(context)),
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
        _ganttCacheGranularity == widget.granularity) {
      return cached;
    }
    // 未命中：现算并回填（禁止返回默认空列表）
    final tasks = _filterByScales(_ganttScaleView);
    _ganttCache = tasks;
    _ganttCacheRevision = _cacheRevision;
    _ganttCacheGranularity = widget.granularity;
    return tasks;
  }

  /// 当前粒度对应的尺度放行集合名（与 [_filterByScales] 入参同一套映射）。
  String get _ganttScaleView => switch (widget.granularity) {
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
  /// 当前视图放行集合（scalesForView）内的全部任务，不再限定单一尺度。
  List<Task> get _bottomTasks {
    final viewName =
        const ['yearly', 'year', 'month', 'day'][widget.granularity];
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
      // 删除前快照锚点行 + 受影响正文原文，撤销时整体复原。
      final snapshot = await db.snapshotTaskDeletion([task.id]);
      await db.deleteTasks([task.id]);
      UndoService.instance.register(
        label: '已删除',
        undo: () async {
          await db.insertTask(task);
          await db.restoreTaskDeletionSnapshot(snapshot);
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

  /// 勾选完成/取消完成（底部板块，设计 §2 行 UI 照搬待办列表）。
  Future<void> _toggleDone(Task task) =>
      toggleTaskDoneWithUndo(context, task, onChanged: reload);

  /// 详情面板中点父/子任务：按目标任务的尺度切换到能展示它的粒度并定位，
  /// 选中并展示其详情。跨粒度时经 [TaskScheduleView.onSwitchGranularity]
  /// 请宿主换 mode（v3 阶段 4；年度尺度任务落到年度视图）。
  void _jumpToTask(Task t) {
    final s = t.startAt;
    if (s == null) return; // 不定时任务在甘特无视图可跳
    final g = switch (deriveTaskScale(t.startAt, t.endAt, kind: t.kind)) {
      'yearly' => 0,
      'quarterly' || 'monthly' => 1,
      'weekly' || 'daily' => 2,
      _ => 3,
    };
    setState(() {
      _selectedTask = t;
      _detailMode = true;
      _anchor = DateTime.fromMillisecondsSinceEpoch(s);
    });
    if (g != widget.granularity) {
      _pendingJump = true;
      widget.onSwitchGranularity?.call(g);
    }
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
  /// 表现就是「刚进视图，底部显示任务 0，图上明明有任务」。
  /// 这里按当前粒度与锚点推算一个合理的默认窗口，视图上报后再被真实值覆盖。
  String _windowSeedKey = '';

  void _maybeSeedWindow() {
    final key =
        '${widget.granularity}|${_anchor.year}-${_anchor.month}-${_anchor.day}';
    if (_visStartMs != null && _windowSeedKey == key) return;
    _windowSeedKey = key;
    final a = _anchor;
    late DateTime s, e;
    switch (widget.granularity) {
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
    final target = switch (widget.granularity) {
      0 => DateTime(_anchor.year + delta * 20, _anchor.month),
      1 => DateTime(_anchor.year + delta, _anchor.month),
      2 => DateTime(_anchor.year, _anchor.month + delta),
      _ => DateTime(_anchor.year, _anchor.month, _anchor.day + delta),
    };
    setState(() => _anchor = target);
    _scrollCurrentTo(target);
  }

  /// 滚动当前粒度视图到指定日期。
  void _scrollCurrentTo(DateTime target) {
    switch (widget.granularity) {
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
    switch (widget.granularity) {
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

  /// AppBar 标题（v2.4）：年 = 「2026」；月 = 「2026-10」；日 = 「2026-10-14 周三」。
  String get _title {
    switch (widget.granularity) {
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
    switch (widget.granularity) {
      case 0:
        return YearlyView(
          key: _yearlyKey,
          tasks: tasks,
          selectedTaskId: _selectedTask?.id,
          onTaskSelected: _onTaskSelected,
          onTaskMoved: _moveTask,
          onYearTap: (year) {
            final target = DateTime(year, 7);
            setState(() => _anchor = target);
            widget.onSwitchGranularity?.call(1);
            _afterTwoFrames(() => _yearKey.currentState?.scrollTo(target));
          },
          onVisibleWindowChanged: _onWindowChanged,
          onCenterChanged: (c) => setState(() => _anchor = c),
        );
      case 2:
        return MonthView(
          key: _monthKey,
          tasks: tasks,
          selectedTaskId: _selectedTask?.id,
          onTaskSelected: _onTaskSelected,
          onDayTap: (ms) {
            final d = DateTime.fromMillisecondsSinceEpoch(ms);
            final target = DateTime(d.year, d.month, d.day);
            setState(() => _anchor = target);
            widget.onSwitchGranularity?.call(3);
            _afterTwoFrames(() => _dayKey.currentState?.scrollTo(target));
          },
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
          // F13②：名称带高度由页面持久化并下发（抓手拖动改的就是它）；
          // 抓手空槽仍由图表自绘自收手势，页面只拿「累计位移」回调。
          handleSlotH: _handleH,
          showHandle: widget.granularity == 3,
          nameBandH: _nameBandH,
          // 顶部抓手 → 标签带高度（抓手自己跟着手指走，任务栏不动）
          onHandleDrag: _dragNameBand,
          onHandleDragEnd: () {
            _nameBandStart = null;
            _barDragStart = null;
            _saveHeights();
          },
        );
      default:
        return YearView(
          key: _yearKey,
          tasks: tasks,
          selectedTaskId: _selectedTask?.id,
          onTaskSelected: _onTaskSelected,
          onMonthTap: (ms) {
            final m = DateTime.fromMillisecondsSinceEpoch(ms);
            final target = DateTime(m.year, m.month, 15);
            setState(() => _anchor = target);
            widget.onSwitchGranularity?.call(2);
            _afterTwoFrames(() => _monthKey.currentState?.scrollTo(target));
          },
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
        actions: [
          TextButton(onPressed: _goNow, child: const Text('现在')),
        ],
      ),
      body: Column(
        children: [
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else
            // F13②：图表区 + 可拖动分割线 + 底部面板。
            Expanded(child: _splitBody(context)),
        ],
      ),
    );
  }
}

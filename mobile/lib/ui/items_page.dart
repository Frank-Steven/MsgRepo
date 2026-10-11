import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/database.dart';
import '../services/registry_service.dart';
import 'item_detail_page.dart';

const confidenceThreshold = 0.6;

Color priorityColor(String priority) => switch (priority) {
      'P0' => Colors.red,
      'P1' => Colors.orange,
      'P2' => Colors.blue,
      _ => Colors.grey,
    };

String _two(int n) => n.toString().padLeft(2, '0');

/// HH:mm
String formatHm(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${_two(d.hour)}:${_two(d.minute)}';
}

/// 按天分组用的日期标题，如 2026-10-11 周六
String formatDayHeader(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  return '${d.year}-${_two(d.month)}-${_two(d.day)} ${weekdays[d.weekday - 1]}';
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

class ItemsPage extends StatefulWidget {
  const ItemsPage({super.key});

  @override
  State<ItemsPage> createState() => ItemsPageState();
}

class ItemsPageState extends State<ItemsPage> {
  List<StructuredItem> _items = [];
  CategoryRegistry? _registry;
  String _categoryFilter = 'all';
  String _view = 'category'; // category | schedule | todo

  // 日程表视图内部层级：year → month → day，_focus 为当前聚焦日期
  String _calLevel = 'year';
  DateTime _focus = DateTime.now();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 供外部（如底部导航切页）触发的公开刷新入口
  Future<void> reload() => _reload();

  Future<void> _reload() async {
    final items = await AppDatabase.instance.getStructuredItems();
    final registry = await RegistryService.instance.load();
    if (mounted) {
      setState(() {
        _items = items;
        _registry = registry;
      });
    }
  }

  Future<void> _openDetail(StructuredItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ItemDetailPage(item: item)),
    );
    await _reload();
  }

  /// todo 勾选联动（公共方法）：payload.status 切换 + 关联消息 归档/恢复。
  Future<void> _toggleTodo(StructuredItem item, bool done) async {
    await AppDatabase.instance.setTodoDone(item, done);
    await _reload();
  }

  String _kindLabel(StructuredItem item) => itemKindLabel(item, _registry);

  bool _isDone(StructuredItem item) => item.payload['status'] == 'done';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('结构化结果')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'category', label: Text('分类')),
                ButtonSegment(value: 'schedule', label: Text('日程表')),
                ButtonSegment(value: 'todo', label: Text('任务清单')),
              ],
              selected: {_view},
              onSelectionChanged: (v) => setState(() => _view = v.first),
            ),
          ),
          if (_view == 'category') _buildCategoryChips(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reload,
              // 年/月视图为 GridView，本身可滚动
              child: switch (_view) {
                'schedule' => _buildScheduleView(),
                'todo' => _buildTodoView(),
                _ => _buildCategoryView(),
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---- 分类视图 ----

  Widget _buildCategoryChips() {
    final categories = _items.map((e) => e.category).toSet().toList();
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final chip in [
            ('all', '全部'),
            ...categories.map((k) => (k, _registry?.displayNameOf(k) ?? k)),
          ])
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Text(chip.$2),
                  labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                  selected: _categoryFilter == chip.$1,
                  onSelected: (_) =>
                      setState(() => _categoryFilter = chip.$1),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCategoryView() {
    final visible = _categoryFilter == 'all'
        ? _items
        : _items.where((e) => e.category == _categoryFilter).toList();
    if (visible.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          Center(child: Text('暂无结构化结果，请先在收件箱同步')),
        ],
      );
    }

    // 按分类分组展示
    final grouped = <String, List<StructuredItem>>{};
    for (final item in visible) {
      grouped.putIfAbsent(item.category, () => []).add(item);
    }
    final groupKeys = grouped.keys.toList()
      ..sort((a, b) =>
          (_registry?.displayNameOf(a) ?? a)
              .compareTo(_registry?.displayNameOf(b) ?? b));

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        for (final key in groupKeys) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              _registry?.displayNameOf(key) ?? key,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
          ),
          for (final item in grouped[key]!)
            _ItemTile(item: item, onTap: () => _openDetail(item)),
        ],
      ],
    );
  }

  // ---- 日程表视图（年/月/日） ----

  /// 数据源：所有 time.kind ∈ {point, range, deadline} 且有时间点的条目（含 todo）。
  List<StructuredItem> get _timedItems =>
      _items.where((e) => e.time.baseTime != null).toList();

  /// 条目时间是否与 [start, end) 区间相交（range 跨区间算相交）。
  bool _overlaps(StructuredItem e, int start, int end) {
    final t = e.time;
    int? s;
    int? en;
    if (t.kind == ItemTime.kindRange) {
      s = t.startAt;
      en = t.endAt ?? t.startAt;
    } else {
      s = t.baseTime;
      en = s;
    }
    if (s == null) return false;
    return s < end && (en ?? s) >= start;
  }

  List<StructuredItem> _itemsOnDay(DateTime day) {
    final ds = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;
    final de = ds + 86400000;
    final list =
        _timedItems.where((e) => _overlaps(e, ds, de)).toList();
    list.sort((a, b) => a.time.baseTime!.compareTo(b.time.baseTime!));
    return list;
  }

  int _countInMonth(int year, int month) {
    final ms = DateTime(year, month).millisecondsSinceEpoch;
    final me = DateTime(year, month + 1).millisecondsSinceEpoch;
    return _timedItems.where((e) => _overlaps(e, ms, me)).length;
  }

  Widget _buildScheduleView() {
    return switch (_calLevel) {
      'month' => _buildMonthView(),
      'day' => _buildDayView(),
      _ => _buildYearView(),
    };
  }

  Widget _calHeader(String title, VoidCallback? onBack,
      {VoidCallback? onPrev, VoidCallback? onNext}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
                icon: const Icon(Icons.arrow_back), onPressed: onBack)
          else
            const SizedBox(width: 48),
          IconButton(
              icon: const Icon(Icons.chevron_left), onPressed: onPrev),
          Expanded(
            child: Center(
              child: Text(title,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
          IconButton(
              icon: const Icon(Icons.chevron_right), onPressed: onNext),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  // 年视图：12 个月网格，显示每月条目数
  Widget _buildYearView() {
    final year = _focus.year;
    return Column(
      children: [
        _calHeader('$year 年', null,
            onPrev: () =>
                setState(() => _focus = DateTime(year - 1, _focus.month)),
            onNext: () =>
                setState(() => _focus = DateTime(year + 1, _focus.month))),
        Expanded(
          child: GridView.count(
            crossAxisCount: 3,
            childAspectRatio: 1.7,
            padding: const EdgeInsets.all(12),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            children: [
              for (var m = 1; m <= 12; m++)
                _MonthCell(
                  year: year,
                  month: m,
                  count: _countInMonth(year, m),
                  isCurrent: year == DateTime.now().year &&
                      m == DateTime.now().month,
                  onTap: () => setState(() {
                    _focus = DateTime(year, m);
                    _calLevel = 'month';
                  }),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // 月视图：周一开头的日历网格
  Widget _buildMonthView() {
    final year = _focus.year;
    final month = _focus.month;
    final firstWeekday = DateTime(year, month, 1).weekday; // 1=周一
    final offset = firstWeekday - 1;
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final today = _dateOnly(DateTime.now());

    return Column(
      children: [
        _calHeader('$year 年 $month 月',
            () => setState(() => _calLevel = 'year'),
            onPrev: () =>
                setState(() => _focus = DateTime(year, month - 1)),
            onNext: () =>
                setState(() => _focus = DateTime(year, month + 1))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              for (final w in ['一', '二', '三', '四', '五', '六', '日'])
                Expanded(
                  child: Center(
                    child: Text(w,
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: GridView.count(
            crossAxisCount: 7,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (var i = 0; i < offset; i++) const SizedBox.shrink(),
              for (var d = 1; d <= daysInMonth; d++)
                _DayCell(
                  day: DateTime(year, month, d),
                  items: _itemsOnDay(DateTime(year, month, d)),
                  isToday: _dateOnly(DateTime(year, month, d)) == today,
                  onTap: () => setState(() {
                    _focus = DateTime(year, month, d);
                    _calLevel = 'day';
                  }),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // 日视图：简易甘特 + 当天条目列表
  Widget _buildDayView() {
    final dayItems = _itemsOnDay(_focus);
    return Column(
      children: [
        _calHeader(formatDayHeader(_focus.millisecondsSinceEpoch),
            () => setState(() => _calLevel = 'month'),
            onPrev: () => setState(
                () => _focus = _focus.subtract(const Duration(days: 1))),
            onNext: () => setState(
                () => _focus = _focus.add(const Duration(days: 1)))),
        if (dayItems.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: _Gantt(items: dayItems, day: _focus, isDone: _isDone),
          ),
        Expanded(
          child: dayItems.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [
                    SizedBox(height: 80),
                    Center(child: Text('当天没有条目')),
                  ],
                )
              : ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    for (final item in dayItems)
                      _DayItemTile(
                        item: item,
                        kindLabel: _kindLabel(item),
                        categoryLabel:
                            _registry?.displayNameOf(item.category) ??
                                item.category,
                        isDone: _isDone(item),
                        onToggleDone: item.category == 'todo'
                            ? (done) => _toggleTodo(item, done)
                            : null,
                        onTap: () => _openDetail(item),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  // ---- 任务清单视图 ----

  Widget _buildTodoView() {
    final todos = _items.where((e) => e.category == 'todo').toList();
    if (todos.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          Center(child: Text('暂无待办条目')),
        ],
      );
    }
    final open = todos.where((e) => !_isDone(e)).toList();
    final done = todos.where(_isDone).toList();

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        for (final item in open)
          _TodoTile(
              item: item,
              isDone: false,
              kindLabel: _kindLabel(item),
              onToggle: _toggleTodo,
              onTap: () => _openDetail(item)),
        if (done.isNotEmpty) ...[
          const Divider(height: 24),
          for (final item in done)
            _TodoTile(
                item: item,
                isDone: true,
                kindLabel: _kindLabel(item),
                onToggle: _toggleTodo,
                onTap: () => _openDetail(item)),
        ],
      ],
    );
  }
}

class _ItemTile extends StatelessWidget {
  final StructuredItem item;
  final VoidCallback onTap;

  const _ItemTile({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = priorityColor(item.priority);
    final lowConfidence = item.confidence < confidenceThreshold;
    final base = item.time.baseTime;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: Container(
          width: 4,
          height: 40,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(item.priority,
                  style: TextStyle(fontSize: 11, color: color)),
            ),
            Expanded(
              child: Text(item.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.summary, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (base != null)
              Text(formatMillis(base),
                  style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        trailing: lowConfidence
            ? const Tooltip(
                message: 'AI 置信度较低',
                child: Chip(
                  label: Text('待确认', style: TextStyle(fontSize: 11)),
                  backgroundColor: Color(0x1FFF9800),
                  side: BorderSide.none,
                  visualDensity: VisualDensity.compact,
                ),
              )
            : null,
        onTap: onTap,
      ),
    );
  }
}

/// 年视图月份格。
class _MonthCell extends StatelessWidget {
  final int year;
  final int month;
  final int count;
  final bool isCurrent;
  final VoidCallback onTap;

  const _MonthCell({
    required this.year,
    required this.month,
    required this.count,
    required this.isCurrent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: isCurrent ? scheme.primaryContainer : null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('$month月', style: Theme.of(context).textTheme.titleMedium),
            Text(
              count > 0 ? '$count 条' : '无',
              style: TextStyle(
                fontSize: 12,
                color: count > 0 ? scheme.primary : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 月视图日期格：日期 + 最多 3 个按优先级着色的小圆点。
class _DayCell extends StatelessWidget {
  final DateTime day;
  final List<StructuredItem> items;
  final bool isToday;
  final VoidCallback onTap;

  const _DayCell({
    required this.day,
    required this.items,
    required this.isToday,
    required this.onTap,
  });

  static const _priorityRank = {'P0': 0, 'P1': 1, 'P2': 2, 'P3': 3};

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sorted = List.of(items)
      ..sort((a, b) => (_priorityRank[a.priority] ?? 4)
          .compareTo(_priorityRank[b.priority] ?? 4));
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: isToday
                ? BoxDecoration(color: scheme.primary, shape: BoxShape.circle)
                : null,
            alignment: Alignment.center,
            child: Text(
              '${day.day}',
              style: TextStyle(
                fontSize: 13,
                color: isToday ? scheme.onPrimary : null,
                fontWeight: isToday ? FontWeight.bold : null,
              ),
            ),
          ),
          const SizedBox(height: 2),
          SizedBox(
            height: 8,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final item in sorted.take(3))
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    decoration: BoxDecoration(
                      color: priorityColor(item.priority),
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 日视图简易甘特：0-24 小时刻度 + range 横向色条 + point/deadline 菱形/圆点。
class _Gantt extends StatelessWidget {
  final List<StructuredItem> items;
  final DateTime day;
  final bool Function(StructuredItem) isDone;

  const _Gantt({required this.items, required this.day, required this.isDone});

  @override
  Widget build(BuildContext context) {
    final ds = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;
    const totalMs = 86400000;
    final ranges =
        items.where((e) => e.time.kind == ItemTime.kindRange).toList();
    final instants =
        items.where((e) => e.time.kind != ItemTime.kindRange).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth - 44; // 左侧刻度列宽
        double x(int ms) =>
            (((ms - ds) / totalMs).clamp(0.0, 1.0)) * w;

        final tickStyle = TextStyle(
            fontSize: 10, color: Theme.of(context).hintColor);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(width: 44),
                SizedBox(
                  width: w,
                  height: 16,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (final h in [0, 6, 12, 18])
                        Positioned(
                            left: w * h / 24 - 8,
                            child: Text('$h:00', style: tickStyle)),
                      Positioned(
                          right: -8, child: Text('24:00', style: tickStyle)),
                    ],
                  ),
                ),
              ],
            ),
            for (final e in ranges) ..._rangeBar(e, x, w),
            if (instants.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    const SizedBox(width: 44),
                    SizedBox(
                      width: w,
                      height: 16,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          for (final e in instants)
                            Positioned(
                              left: x(e.time.baseTime!) - 5,
                              child: Icon(
                                e.time.kind == ItemTime.kindDeadline
                                    ? Icons.diamond
                                    : Icons.circle,
                                size: 10,
                                color: isDone(e)
                                    ? Colors.grey
                                    : priorityColor(e.priority),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  List<Widget> _rangeBar(StructuredItem e, double Function(int) x, double w) {
    final start = e.time.startAt!;
    final end = e.time.endAt ?? e.time.startAt!;
    final left = x(start);
    final right = math.max(x(end), left + 4);
    final done = isDone(e);
    return [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 44,
              child: Text(formatHm(start),
                  style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ),
            SizedBox(
              width: w,
              height: 14,
              child: Stack(
                children: [
                  Positioned(
                    left: left,
                    width: right - left,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: (done ? Colors.grey : priorityColor(e.priority))
                            .withValues(alpha: done ? 0.4 : 0.7),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ];
  }
}

/// 日视图条目行：时间 + 优先级色条 + 标题 + 类别/分类标签；todo 带 Checkbox。
class _DayItemTile extends StatelessWidget {
  final StructuredItem item;
  final String kindLabel;
  final String categoryLabel;
  final bool isDone;
  final Future<void> Function(bool done)? onToggleDone;
  final VoidCallback onTap;

  const _DayItemTile({
    required this.item,
    required this.kindLabel,
    required this.categoryLabel,
    required this.isDone,
    required this.onToggleDone,
    required this.onTap,
  });

  String get _timeText {
    final t = item.time;
    switch (t.kind) {
      case ItemTime.kindRange:
        final start = t.startAt != null ? formatHm(t.startAt!) : '--';
        final end = t.endAt != null ? formatHm(t.endAt!) : '--';
        return '$start-$end';
      case ItemTime.kindDeadline:
        return '截止 ${t.deadline != null ? formatHm(t.deadline!) : '--'}';
      default:
        return t.startAt != null ? formatHm(t.startAt!) : '--';
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = isDone ? Colors.grey : priorityColor(item.priority);
    final titleStyle = isDone
        ? const TextStyle(
            color: Colors.grey, decoration: TextDecoration.lineThrough)
        : null;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        onTap: onTap,
        leading: onToggleDone != null
            ? Checkbox(
                value: isDone, onChanged: (v) => onToggleDone!(v ?? false))
            : SizedBox(
                width: 76,
                child: Text(_timeText,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isDone ? Colors.grey : null)),
              ),
        title: Row(
          children: [
            Container(
              width: 4,
              height: 18,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: Text(item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle),
            ),
          ],
        ),
        subtitle: Text(
          '${onToggleDone != null ? '$_timeText · ' : ''}'
          '${item.summary.isNotEmpty ? '${item.summary} · ' : ''}$categoryLabel',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: isDone ? Colors.grey : null),
        ),
        trailing: Chip(
          label: Text(kindLabel, style: const TextStyle(fontSize: 11)),
          side: BorderSide.none,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}

/// 任务清单视图行：Checkbox + 标题 + 类别标签 + 开始/截止时间。
class _TodoTile extends StatelessWidget {
  final StructuredItem item;
  final bool isDone;
  final String kindLabel;
  final Future<void> Function(StructuredItem item, bool done) onToggle;
  final VoidCallback onTap;

  const _TodoTile({
    required this.item,
    required this.isDone,
    required this.kindLabel,
    required this.onToggle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = item.time;
    final end = t.endAt ?? t.deadline;
    final timeText =
        '开始 ${t.startAt != null ? formatMillis(t.startAt!) : '--'}'
        ' · 截止 ${end != null ? formatMillis(end) : '--'}';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        onTap: onTap,
        leading: Checkbox(
          value: isDone,
          onChanged: (v) => onToggle(item, v ?? false),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: isDone
                    ? const TextStyle(
                        color: Colors.grey,
                        decoration: TextDecoration.lineThrough)
                    : null,
              ),
            ),
            Chip(
              label: Text(kindLabel, style: const TextStyle(fontSize: 11)),
              side: BorderSide.none,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        subtitle: Text(timeText,
            style: TextStyle(
                fontSize: 12, color: isDone ? Colors.grey : null)),
      ),
    );
  }
}

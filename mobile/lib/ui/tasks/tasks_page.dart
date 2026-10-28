import 'package:flutter/material.dart';

import '../shared/segmented_selector.dart';
import 'task_list_view.dart';
import 'task_schedule_view.dart';

/// 任务页（design-v3 §4，v3 阶段 4）：合并原「待办」与「日程」两页，
/// 顶部视图切换「列表 / 日 / 月 / 年」，数据同源 tasks 表，各视图按
/// 时间尺度（deriveTaskScale / scalesForView）过滤。
///
/// - 列表 = 原待办页（[TaskListView]：尺度页签 + 多选 + 内嵌详情）；
/// - 日/月/年 = 原日程页对应粒度（[TaskScheduleView]，粒度由本页下发，
///   视图内下钻（点月份/日期）经 onSwitchGranularity 回本页换 mode）。
/// - 甘特视图懒构建：首次切到才创建（与壳层 _builtTabs 同一策略）。
class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => TasksPageState();
}

class TasksPageState extends State<TasksPage> {
  /// 0=列表 1=日 2=月 3=年
  int _mode = 0;

  static const _granularityForMode = {1: 3, 2: 2, 3: 1};
  static const _modeForGranularity = {3: 1, 2: 2, 1: 3};

  final _listKey = GlobalKey<TaskListViewState>();
  final _scheduleKey = GlobalKey<TaskScheduleViewState>();

  /// 甘特视图是否已创建（未访问过的模式不构建）。
  bool _scheduleBuilt = false;

  /// 壳层切页时刷新：列表始终刷新；甘特视图仅在已构建时刷新。
  Future<void> reload() async {
    await _listKey.currentState?.reload();
    if (_scheduleBuilt) await _scheduleKey.currentState?.reload();
  }

  void _switchMode(int mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      if (mode != 0) _scheduleBuilt = true;
    });
  }

  /// 甘特视图内部下钻/详情跳转需要换粒度时回调（年=1 月=2 日=3）。
  void _switchGranularity(int g) {
    final mode = _modeForGranularity[g];
    if (mode != null) _switchMode(mode);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Center(
                child: SizedBox(
                  width: 300,
                  child: SegmentedSelector<int>(
                    values: const [0, 1, 2, 3],
                    labels: const ['列表', '日', '月', '年'],
                    selected: _mode,
                    onChanged: _switchMode,
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: IndexedStack(
                index: _mode == 0 ? 0 : 1,
                children: [
                  TaskListView(key: _listKey),
                  if (_scheduleBuilt)
                    TaskScheduleView(
                      key: _scheduleKey,
                      granularity: _granularityForMode[_mode] ?? 3,
                      onSwitchGranularity: _switchGranularity,
                    )
                  else
                    const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

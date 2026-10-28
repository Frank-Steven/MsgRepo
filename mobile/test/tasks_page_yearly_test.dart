import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/ui/shared/segmented_selector.dart';
import 'package:msgrepo_mobile/ui/tasks/task_list_view.dart';
import 'package:msgrepo_mobile/ui/tasks/task_schedule_view.dart';
import 'package:msgrepo_mobile/ui/tasks/tasks_page.dart';
import 'package:msgrepo_mobile/ui/tasks/views/year_view.dart';
import 'package:msgrepo_mobile/ui/tasks/views/yearly_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'task_anchors_test.dart' show createBaseTables;

/// 任务页视图切换「列表/日/月/年/年度」五档回归（v3 收尾）：
/// 「年度」档 = TaskScheduleView(granularity: 0) 的 YearlyView，
/// 甘特视图懒构建（首次切到才创建）。
///
/// 在 tester.runAsync 真异步区里跑：FakeAsync 区会让 sqflite_ffi 的
/// DB 调用挂死（与 anchor_navigation_test 同一范式）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  final appDb = AppDatabase.instance;

  Future<void> settle(WidgetTester tester, [int times = 10]) async {
    for (var i = 0; i < times; i++) {
      await Future.delayed(const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pump();
  }

  /// 任务页顶部切换器（5 档）；TaskListView 的尺度页签也是
  /// SegmentedSelector<int>（10 档），按段数区分。
  Finder tasksPageSwitcher() => find.byWidgetPredicate(
      (w) => w is SegmentedSelector<int> && w.values.length == 5);

  Finder switcherLabel(String label) =>
      find.descendant(of: tasksPageSwitcher(), matching: find.text(label));

  testWidgets('切换器含「年度」档，切到后懒构建挂载 YearlyView', (tester) async {
    await tester.runAsync(() async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await createBaseTables(db);
      appDb.debugAttachDatabase(db);

      await tester.pumpWidget(const MaterialApp(home: TasksPage()));
      await settle(tester);

      for (final label in ['列表', '日', '月', '年', '年度']) {
        expect(switcherLabel(label), findsOneWidget);
      }
      expect(find.byType(TaskListView), findsOneWidget);
      expect(find.byType(YearlyView), findsNothing, reason: '甘特懒构建');

      // 切到「年度」：granularity 0 → YearlyView
      await tester.tap(switcherLabel('年度'));
      await settle(tester);
      expect(find.byType(TaskScheduleView), findsOneWidget);
      expect(find.byType(YearlyView), findsOneWidget);
      final schedule = tester.widget<TaskScheduleView>(
          find.byType(TaskScheduleView));
      expect(schedule.granularity, 0);

      // 切回「年」：同一宿主换粒度 → YearView
      await tester.tap(switcherLabel('年'));
      await settle(tester);
      expect(find.byType(YearView), findsOneWidget);
      expect(find.byType(YearlyView), findsNothing);

      appDb.debugDetachDatabase();
      await db.close();
    });
  });
}

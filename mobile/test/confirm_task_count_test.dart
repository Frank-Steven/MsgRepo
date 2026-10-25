import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/services/ai_client.dart';
import 'package:msgrepo_mobile/services/ai_processing.dart';

/// B08 回归（2026-10-25）：`_confirmImpl` 里 `var createdTasks = 0;` 从未自增，
/// `lastConfirmCreatedTasks` 恒为 0 → 「新建 M 个任务」的通知文案永远 M=0，
/// 而任务其实建了。
///
/// 计数逻辑抽成纯函数 [planConfirmTasks]（无需真库即可测）：
/// - 每个**新建**任务计 1（多草稿各计 1）；
/// - 命中已有任务只记关联（复用），**不计入**新建数；
/// - 同批内相同草稿命中前一条刚建的任务，也不重复计数。
AiTaskDraft draft(
  String title, {
  DateTime? startAt,
  DateTime? endAt,
  String kind = TaskKind.point,
  String priority = TaskPriority.normal,
}) =>
    AiTaskDraft(
      title: title,
      kind: kind,
      startAt: startAt,
      endAt: endAt,
      priority: priority,
    );

Task existingTask(String id, String title, {int? startAt}) => Task(
      id: id,
      title: title,
      kind: TaskKind.point,
      startAt: startAt,
      createdAt: 1,
      updatedAt: 1,
    );

const now = 1700000000000;

void main() {
  group('planConfirmTasks：新建任务计数（B08）', () {
    test('多个新草稿全部新建 → 新建数 = 草稿数（确认后会累加到 createdTasks）', () {
      final activeTasks = <Task>[];
      final plan = planConfirmTasks(
        drafts: [
          draft('买菜'),
          draft('开会', startAt: DateTime(2026, 10, 26, 9)),
          draft('出差',
              kind: TaskKind.range,
              startAt: DateTime(2026, 10, 27, 9),
              endAt: DateTime(2026, 10, 28, 18)),
        ],
        activeTasks: activeTasks,
        messageId: 'm1',
        now: now,
      );

      expect(plan.newTasks.length, 3);
      expect(plan.reusedIds, isEmpty);
      // 模拟 _confirmImpl 的累加语义
      var createdTasks = 0;
      createdTasks += plan.newTasks.length;
      expect(createdTasks, 3);

      // 新任务的来源消息正确；point 不落 endAt，range 保留
      expect(plan.newTasks.every((t) => t.sourceMessageId == 'm1'), isTrue);
      expect(plan.newTasks[0].endAt, isNull);
      expect(plan.newTasks[2].endAt, DateTime(2026, 10, 28, 18).millisecondsSinceEpoch);
      // 新任务也进了 activeTasks（同批后续草稿可命中）
      expect(activeTasks.length, 3);
    });

    test('命中已有任务 → 不新建、复用不计入新建数（B08 的关键）', () {
      final existing = existingTask('t1', '买菜');
      final activeTasks = [existing];
      final plan = planConfirmTasks(
        drafts: [draft('买菜')],
        activeTasks: activeTasks,
        messageId: 'm1',
        now: now,
      );

      expect(plan.newTasks, isEmpty);
      expect(plan.reusedIds, ['t1']);
      var createdTasks = 0;
      createdTasks += plan.newTasks.length;
      expect(createdTasks, 0, reason: '复用命中不能算新建任务');
    });

    test('多草稿混合：命中复用的那条不计数，其余各计 1', () {
      final activeTasks = [existingTask('t1', '买菜')];
      final plan = planConfirmTasks(
        drafts: [draft('买菜'), draft('写周报'), draft('交报告')],
        activeTasks: activeTasks,
        messageId: 'm1',
        now: now,
      );

      expect(plan.newTasks.length, 2);
      expect(plan.reusedIds, ['t1']);
      expect(activeTasks.length, 3); // 1 已有 + 2 新建
    });

    test('同批同一件事的重复草稿只建 1 条、第二条记复用', () {
      final activeTasks = <Task>[];
      final plan = planConfirmTasks(
        drafts: [draft('写周报'), draft('写周报')],
        activeTasks: activeTasks,
        messageId: 'm1',
        now: now,
      );

      expect(plan.newTasks.length, 1);
      expect(plan.reusedIds.length, 1);
      expect(plan.reusedIds.single, plan.newTasks.single.id);
      expect(activeTasks.length, 1);
    });

    test('空标题草稿不新建也不计数', () {
      final plan = planConfirmTasks(
        drafts: [draft('   '), draft('正常')],
        activeTasks: <Task>[],
        messageId: 'm1',
        now: now,
      );

      expect(plan.newTasks.length, 1);
      expect(plan.newTasks.single.title, '正常');
    });
  });

  group('draftsOf：多草稿优先、兼容单草稿字段', () {
    const multi = AiProcessResult(
      messageId: 'm1',
      priority: 'green',
      reason: '',
      taskDraft: AiTaskDraft(title: '旧', kind: TaskKind.point, priority: TaskPriority.normal),
      taskDrafts: [
        AiTaskDraft(title: 'a', kind: TaskKind.point, priority: TaskPriority.normal),
        AiTaskDraft(title: 'b', kind: TaskKind.point, priority: TaskPriority.normal),
      ],
    );
    const single = AiProcessResult(
      messageId: 'm1',
      priority: 'green',
      reason: '',
      taskDraft: AiTaskDraft(title: '仅一条', kind: TaskKind.point, priority: TaskPriority.normal),
    );
    const none = AiProcessResult(messageId: 'm1', priority: 'green', reason: '');

    test('有 taskDrafts 时优先用多草稿（忽略兼容字段 taskDraft）', () {
      expect(draftsOf(multi).map((d) => d.title), ['a', 'b']);
    });

    test('只有单草稿字段时回退为一条', () {
      expect(draftsOf(single).map((d) => d.title), ['仅一条']);
    });

    test('都没有时返回空表', () {
      expect(draftsOf(none), isEmpty);
    });
  });
}

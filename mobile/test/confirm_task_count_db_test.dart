import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/models/task.dart';
import 'package:msgrepo_mobile/services/ai_client.dart';
import 'package:msgrepo_mobile/services/ai_processing.dart';
import 'package:msgrepo_mobile/services/app_log.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:msgrepo_mobile/services/undo_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// B08 真回归（2026-10-25 审计后补）：之前的 confirm_task_count_test 只测了
/// 纯函数 planConfirmTasks，并在测试里手动模拟 createdTasks += ...；如果
/// _confirmImpl 里那一行被删掉，测试仍会全过。
///
/// 这里用 sqflite_common_ffi 的内存库注入 AppDatabase，让真实的
/// AiProcessingService.confirm -> _confirmImpl -> applyAiConfirmBatch 跑一遍，
/// 直接断言 lastConfirmCreatedTasks 与 DB 行数。复用命中时新建数必须是 0。
Message _msg(String id) => Message(
      id: id,
      packageName: 'com.test',
      title: '标题',
      body: '正文',
      postedAt: 1700000000000,
      captureType: 'notification',
      contentHash: 'h-$id',
      status: MessageStatus.pending,
      priority: MessagePriority.none,
      createdAt: 1700000000000,
    );

Task _existing(String id, String title) => Task(
      id: id,
      title: title,
      kind: TaskKind.point,
      priority: TaskPriority.normal,
      status: TaskStatus.active,
      createdAt: 1,
      updatedAt: 1,
    );

AiTaskDraft _draft(String title) => AiTaskDraft(
      title: title,
      kind: TaskKind.point,
      priority: TaskPriority.normal,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  final svc = AiProcessingService.instance;
  late Database db;

  setUp(() async {
    AppLog.instance.clear();
    UndoService.instance.clear();
    svc.reset();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    // v8：关联落点为 task_anchors；锚点重建路径要读/写消息正文与 content_hash
    await db.execute('''
      CREATE TABLE messages(
        id TEXT PRIMARY KEY,
        package_name TEXT NOT NULL DEFAULT 'com.test',
        title TEXT NOT NULL DEFAULT '标题',
        body TEXT NOT NULL DEFAULT '正文',
        posted_at INTEGER NOT NULL DEFAULT 1700000000000,
        content_hash TEXT NOT NULL DEFAULT '',
        priority TEXT NOT NULL DEFAULT 'none',
        status TEXT NOT NULL DEFAULT 'pending',
        linked_task_id TEXT,
        edited_at INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE tasks(
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        description TEXT,
        kind TEXT NOT NULL,
        start_at INTEGER,
        end_at INTEGER,
        priority TEXT NOT NULL,
        is_annual INTEGER NOT NULL DEFAULT 0,
        source_message_id TEXT,
        parent_id TEXT,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await createV8Tables(db);
    await db.insert('messages', {
      'id': 'm1',
      'priority': MessagePriority.none,
      'status': MessageStatus.pending,
    });
    AppDatabase.instance.debugAttachDatabase(db);
  });

  tearDown(() async {
    await svc.idle;
    // applyAiConfirmBatch 会起 400ms 的重排 timer；等它跑完再关内存库
    await Future<void>.delayed(const Duration(milliseconds: 450));
    svc.reset();
    svc.processor = AiClient.instance.process;
    AppDatabase.instance.debugDetachDatabase();
    await db.close();
    UndoService.instance.clear();
    AppLog.instance.clear();
  });

  test('真实 confirm：两条新草稿 -> lastConfirmCreatedTasks=2 且 DB 落两条任务', () async {
    svc.processor = (msgs) async* {
      yield AiMessageResult(AiProcessResult(
        messageId: msgs.single.id,
        priority: MessagePriority.green,
        reason: 'ok',
        taskDrafts: [_draft('买菜'), _draft('写周报')],
      ));
      yield const AiAllDone(1, 0);
    };
    svc.enqueue([_msg('m1')]);
    await svc.idle;

    final confirmed = await svc.confirm(svc.session!.outcomes.toList());

    expect(confirmed, 1);
    expect(svc.lastConfirmCreatedTasks, 2, reason: 'B08：新建任务数必须真实累加');
    expect((await db.query('tasks')).length, 2);
    final row = (await db.query('messages')).single;
    expect(row['status'], MessageStatus.processed);
    expect(row['priority'], MessagePriority.green);
  });

  test('真实 confirm：命中已有任务 -> lastConfirmCreatedTasks=0，只建关联', () async {
    await db.insert('tasks', _existing('t1', '买菜').toRow());
    svc.processor = (msgs) async* {
      yield AiMessageResult(AiProcessResult(
        messageId: msgs.single.id,
        priority: MessagePriority.green,
        reason: 'ok',
        taskDrafts: [_draft('买菜')],
      ));
      yield const AiAllDone(1, 0);
    };
    svc.enqueue([_msg('m1')]);
    await svc.idle;

    final confirmed = await svc.confirm(svc.session!.outcomes.toList());

    expect(confirmed, 1);
    expect(svc.lastConfirmCreatedTasks, 0, reason: '复用命中不能计入新建任务');
    expect((await db.query('tasks')).length, 1);
    final anchors = await db.query('task_anchors');
    expect(anchors.length, 1, reason: 'v8：确认落锚点而不是 links 行');
    expect(anchors.single['task_id'], 't1');
    expect(anchors.single['target_id'], 'm1');
    expect(anchors.single['target_type'], 'message');
    // marker 追加到正文末尾
    final body = (await db.query('messages')).single['body'] as String;
    expect(body, '正文 ⟦task:${anchors.single['id']}⟧');
  });
}

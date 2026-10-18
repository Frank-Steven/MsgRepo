import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// N1 数据层回归：v5→v6 迁移、多对多关联表、旧列双写是否一致。
/// 用 sqflite_common_ffi 跑真 SQLite，不依赖手机。
/// 取单值查询的整数结果（避免依赖 sqflite 包的 Sqflite.firstIntValue）。
Future<int> firstInt(Database db, String sql) async {
  final rows = await db.rawQuery(sql);
  return (rows.first.values.first as int?) ?? 0;
}

void main() {
  sqfliteFfiInit();

  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    // 造 v5 形态：迁移只依赖这两列
    await db.execute('CREATE TABLE messages(id TEXT PRIMARY KEY, linked_task_id TEXT)');
    await db.execute('CREATE TABLE tasks(id TEXT PRIMARY KEY, source_message_id TEXT)');
  });

  tearDown(() async {
    await db.close();
  });

  test('v6 迁移：两个方向的旧 1:1 绑定都灌进关联表', () async {
    await db.insert('messages', {'id': 'm1', 'linked_task_id': 't1'});
    await db.insert('messages', {'id': 'm2', 'linked_task_id': null});
    await db.insert('tasks', {'id': 't2', 'source_message_id': 'm2'});

    await createMessageTaskLinksTable(db);
    await migrateLinksToV6(db);

    final rows = await db.query('message_task_links', orderBy: 'message_id, task_id');
    expect(rows.length, 2);
    expect(rows[0]['message_id'], 'm1');
    expect(rows[0]['task_id'], 't1');
    expect(rows[1]['message_id'], 'm2');
    expect(rows[1]['task_id'], 't2');
  });

  test('迁移幂等：重复执行不会插重复行', () async {
    await db.insert('messages', {'id': 'm1', 'linked_task_id': 't1'});
    await db.insert('tasks', {'id': 't1', 'source_message_id': 'm1'});
    await createMessageTaskLinksTable(db);
    await migrateLinksToV6(db);
    await migrateLinksToV6(db);
    final n = await firstInt(db, 'SELECT COUNT(*) FROM message_task_links');
    expect(n, 1, reason: '同一对 message/task 只应有一行');
  });

  test('一条消息可以同时关联多个任务（多对多成立）', () async {
    await db.insert('messages', {'id': 'm1', 'linked_task_id': null});
    await createMessageTaskLinksTable(db);
    for (final t in ['t1', 't2', 't3']) {
      await db.insert('message_task_links',
          {'message_id': 'm1', 'task_id': t, 'created_at': DateTime.now().millisecondsSinceEpoch});
    }
    final n = await firstInt(db, "SELECT COUNT(*) FROM message_task_links WHERE message_id = 'm1'");
    expect(n, 3);
  });

  test('setSingleMessageTaskLink：写入时同步旧列，置空时清掉关联行', () async {
    await db.insert('messages', {'id': 'm1', 'linked_task_id': null});
    await createMessageTaskLinksTable(db);

    await setSingleMessageTaskLink(db, 'm1', 't1');
    var msg = (await db.query('messages', where: "id = 'm1'")).single;
    expect(msg['linked_task_id'], 't1');
    var n = await firstInt(db, 'SELECT COUNT(*) FROM message_task_links');
    expect(n, 1);

    await setSingleMessageTaskLink(db, 'm1', null);
    msg = (await db.query('messages', where: "id = 'm1'")).single;
    expect(msg['linked_task_id'], isNull);
    n = await firstInt(db, 'SELECT COUNT(*) FROM message_task_links');
    expect(n, 0);
  });

  test('多个任务指向同一条消息也成立（反方向）', () async {
    await createMessageTaskLinksTable(db);
    for (final t in ['t1', 't2']) {
      await db.insert('message_task_links',
          {'message_id': 'm9', 'task_id': t, 'created_at': DateTime.now().millisecondsSinceEpoch});
    }
    final targets = await db.query('message_task_links',
        columns: ['task_id'],
        where: 'message_id = ?',
        whereArgs: ['m9'],
        orderBy: 'created_at ASC, task_id ASC');
    expect(targets.map((r) => r['task_id']).toList(), ['t1', 't2']);
  });
}

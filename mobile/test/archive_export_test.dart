import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/models/message.dart';
import 'package:msgrepo_mobile/services/archive_export_service.dart';
import 'package:msgrepo_mobile/services/attachment_store.dart';
import 'package:msgrepo_mobile/services/database.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// v2.9 过渡版本存档导出：zip 结构、manifest、links/linked_task_id → 锚点转换、
/// front matter、附件打包。用 sqflite_common_ffi 内存库跑真 SQLite（与
/// message_task_links_test 同款基建），zip 用 archive 包解开校验。
void main() {
  sqfliteFfiInit();

  late Database db;
  late Directory tmp;
  late Directory attachDir;
  late Directory outDir;

  const markerPattern =
      r'⟦task:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})⟧';

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    // 与 database.dart 的 v7 形态一致的最小建表
    await db.execute('''
      CREATE TABLE messages(
        id TEXT PRIMARY KEY,
        package_name TEXT NOT NULL,
        app_name TEXT,
        channel_id TEXT,
        conversation_title TEXT,
        sender TEXT,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        posted_at INTEGER NOT NULL,
        capture_type TEXT NOT NULL,
        import_source TEXT,
        attachments TEXT NOT NULL DEFAULT '[]',
        content_hash TEXT NOT NULL UNIQUE,
        status TEXT NOT NULL DEFAULT 'pending',
        priority TEXT NOT NULL DEFAULT 'none',
        linked_task_id TEXT,
        edited_at INTEGER,
        created_at INTEGER NOT NULL
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
        priority TEXT NOT NULL DEFAULT 'normal',
        is_annual INTEGER NOT NULL DEFAULT 0,
        source_message_id TEXT,
        status TEXT NOT NULL DEFAULT 'active',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        parent_id TEXT
      )
    ''');
    await createMessageTaskLinksTable(db);
    await db.execute(
        'CREATE TABLE notebooks(id TEXT PRIMARY KEY, name TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)');
    await db.execute(
        'CREATE TABLE chapters(id TEXT PRIMARY KEY, notebook_id TEXT NOT NULL, name TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)');
    await db.execute(
        'CREATE TABLE notes(id TEXT PRIMARY KEY, chapter_id TEXT NOT NULL, title TEXT NOT NULL, content TEXT NOT NULL DEFAULT \'\', content_format TEXT NOT NULL DEFAULT \'plain\', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)');

    tmp = Directory.systemTemp.createTempSync('archive_export_test');
    attachDir = Directory(p.join(tmp.path, 'attachments'))..createSync();
    outDir = Directory(p.join(tmp.path, 'out'))..createSync();
    AttachmentStore.debugDirOverride = attachDir;
  });

  tearDown(() async {
    AttachmentStore.debugDirOverride = null;
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<void> insertTask(String id,
      {String? title,
      String status = 'active',
      String? parentId}) async {
    await db.insert('tasks', {
      'id': id,
      'title': title ?? '任务$id',
      'description': null,
      'kind': 'point',
      'start_at': null,
      'end_at': null,
      'priority': 'normal',
      'is_annual': 0,
      'source_message_id': null,
      'status': status,
      'created_at': 1000,
      'updated_at': 1000,
      'parent_id': parentId,
    });
  }

  Future<void> insertMessage(String id, String body,
      {String? linkedTaskId,
      List<Attachment> attachments = const [],
      int createdAt = 2000}) async {
    await db.insert('messages', {
      'id': id,
      'package_name': 'com.test',
      'app_name': 'Test',
      'channel_id': null,
      'conversation_title': null,
      'sender': null,
      'title': '标题$id',
      'body': body,
      'posted_at': createdAt,
      'capture_type': 'notification',
      'import_source': null,
      'attachments':
          jsonEncode(attachments.map((e) => e.toJson()).toList()),
      'content_hash': 'hash-$id',
      'status': 'pending',
      'priority': 'none',
      'linked_task_id': linkedTaskId,
      'edited_at': null,
      'created_at': createdAt,
    });
  }

  Future<void> insertLink(String messageId, String taskId, int createdAt) =>
      db.insert('message_task_links', {
        'message_id': messageId,
        'task_id': taskId,
        'created_at': createdAt,
      });

  Future<Map<String, ArchiveFile>> exportAndUnzip() async {
    final result = await ArchiveExportService.instance
        .exportArchive(database: db, outputDir: outDir);
    final bytes = await File(result.path).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    return {for (final f in archive.files) f.name: f};
  }

  Map<String, dynamic> jsonOf(Map<String, ArchiveFile> files, String name) =>
      jsonDecode(utf8.decode(files[name]!.content as List<int>))
          as Map<String, dynamic>;

  List<dynamic> jsonListOf(Map<String, ArchiveFile> files, String name) =>
      jsonDecode(utf8.decode(files[name]!.content as List<int>))
          as List<dynamic>;

  String textOf(Map<String, ArchiveFile> files, String name) =>
      utf8.decode(files[name]!.content as List<int>);

  test('空库也能导出：zip 结构完整，counts 全 0', () async {
    final files = await exportAndUnzip();
    for (final name in [
      'manifest.json',
      'tasks.json',
      'messages.json',
      'anchors.json',
      'library/notebooks.json',
      'library/files.json',
    ]) {
      expect(files.containsKey(name), isTrue, reason: '缺少 $name');
    }
    final manifest = jsonOf(files, 'manifest.json');
    expect(manifest['format'], 'msgrepo-archive');
    expect(manifest['version'], 1);
    expect(manifest['appVersion'], isA<String>());
    expect(manifest['exportedAt'], isA<int>());
    expect(manifest['counts'],
        {'tasks': 0, 'messages': 0, 'notes': 0, 'files': 0, 'anchors': 0});
  });

  test('links 与 linked_task_id 都转为锚点，marker 追加到正文末尾', () async {
    await insertTask('t1', title: '买菜');
    await insertTask('t2', title: '取快递', status: 'archived');
    await insertTask('t3', title: '无关任务');
    await insertMessage('m1', '记得买菜', createdAt: 2001);
    await insertMessage('m2', '也别忘了', linkedTaskId: 't1', createdAt: 2002);
    await insertMessage('m3', '无关联', createdAt: 2003);
    // m1 关联 t1、t2（多锚点），linked_task_id 双写 t1（应去重，不产生第二个锚点）
    await insertLink('m1', 't1', 3001);
    await insertLink('m1', 't2', 3002);
    await db.update('messages', {'linked_task_id': 't1'},
        where: 'id = ?', whereArgs: ['m1']);

    final files = await exportAndUnzip();

    final anchors = jsonListOf(files, 'anchors.json');
    expect(anchors.length, 3, reason: 'm1→t1、m1→t2、m2→t1 各一个锚点');
    for (final a in anchors) {
      expect(a['created_by'], 'user');
      expect(a['target_type'], 'message');
      expect(
          a['id'],
          matches(RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')));
    }
    // 同一任务 t1 有两个锚点（不同 anchorId），同一消息 m1 有两个锚点
    final t1Anchors = anchors.where((a) => a['task_id'] == 't1').toList();
    expect(t1Anchors.length, 2);
    expect(t1Anchors[0]['id'] == t1Anchors[1]['id'], isFalse);
    expect(
        anchors.where((a) => a['target_id'] == 'm1').length, 2);
    // label 取任务标题快照
    final m1t1 = anchors.singleWhere(
        (a) => a['task_id'] == 't1' && a['target_id'] == 'm1');
    expect(m1t1['label'], '买菜');
    expect(m1t1['created_at'], 3001);

    final messages = jsonListOf(files, 'messages.json');
    final m1 = messages.singleWhere((m) => m['id'] == 'm1');
    final m2 = messages.singleWhere((m) => m['id'] == 'm2');
    final m3 = messages.singleWhere((m) => m['id'] == 'm3');

    // marker 按关联创建时间升序追加在正文末尾
    final m1Markers = RegExp(markerPattern)
        .allMatches(m1['body'] as String)
        .map((m) => m.group(1)!)
        .toList();
    expect(m1Markers.length, 2);
    expect(m1['body'] as String, startsWith('记得买菜 '));
    expect(m1['body'] as String, endsWith('⟧'));
    final m1t1Anchor = anchors.singleWhere(
        (a) => a['task_id'] == 't1' && a['target_id'] == 'm1');
    final m1t2Anchor = anchors.singleWhere(
        (a) => a['task_id'] == 't2' && a['target_id'] == 'm1');
    expect(m1Markers, [m1t1Anchor['id'], m1t2Anchor['id']]);

    expect(
        (m2['body'] as String)
            .endsWith('⟦task:${t1Anchors.singleWhere((a) => a['target_id'] == 'm2')['id']}⟧'),
        isTrue);
    expect(m3['body'], '无关联');
    // content_hash 原样导出（导入侧重算）
    expect(m1['content_hash'], 'hash-m1');
    // attachments 解码为 JSON 数组
    expect(m1['attachments'], isA<List<dynamic>>());

    // tasks 全量导出（含 archived 与 parent_id 字段）
    final tasks = jsonListOf(files, 'tasks.json');
    expect(tasks.length, 3);
    expect(tasks.map((t) => t['id']),
        containsAll(['t1', 't2', 't3']));
    expect(tasks.singleWhere((t) => t['id'] == 't2')['status'], 'archived');
    expect(tasks.first.containsKey('parent_id'), isTrue);

    final manifest = jsonOf(files, 'manifest.json');
    expect(manifest['counts'],
        {'tasks': 3, 'messages': 3, 'notes': 0, 'files': 0, 'anchors': 3});
  });

  test('笔记三级：notebooks.json + front matter 字段正确（plain 也导出为 .md）',
      () async {
    await db.insert('notebooks',
        {'id': 'nb1', 'name': '学习', 'sort': 0, 'created_at': 4000});
    await db.insert('chapters', {
      'id': 'ch1',
      'notebook_id': 'nb1',
      'name': '数学',
      'sort': 0,
      'created_at': 4001,
    });
    await db.insert('notes', {
      'id': 'n1',
      'chapter_id': 'ch1',
      'title': '公式: 速查 #1',
      'content': 'E = mc^2\n第二行',
      'content_format': 'plain',
      'created_at': 4002,
      'updated_at': 4003,
    });
    await db.insert('notes', {
      'id': 'n2',
      'chapter_id': 'ch1',
      'title': 'markdown 笔记',
      'content': '# 标题',
      'content_format': 'markdown',
      'created_at': 4004,
      'updated_at': 4005,
    });

    final files = await exportAndUnzip();

    final nb = jsonOf(files, 'library/notebooks.json');
    expect((nb['notebooks'] as List).single['id'], 'nb1');
    expect((nb['chapters'] as List).single['id'], 'ch1');

    expect(files.containsKey('library/notes/n1.md'), isTrue);
    expect(files.containsKey('library/notes/n2.md'), isTrue);

    final md = textOf(files, 'library/notes/n1.md');
    expect(md, startsWith('---\n'));
    expect(md, contains('\nid: n1\n'));
    // 标题含 : 与 #，必须用引号（JSON 双引号是合法 YAML）
    expect(md, contains('\ntitle: "公式: 速查 #1"\n'));
    expect(md, contains('\nchapter_id: ch1\n'));
    expect(md, contains('\ncontent_format: plain\n'));
    expect(md, contains('\ncreated_at: 4002\n'));
    expect(md, contains('\nupdated_at: 4003\n'));
    expect(md, contains('\nattachments: []\n'));
    expect(md, endsWith('---\nE = mc^2\n第二行'));

    final md2 = textOf(files, 'library/notes/n2.md');
    expect(md2, contains('\ncontent_format: markdown\n'));
    // 安全标题原样输出不加引号（贴近规格示例）
    expect(md2, contains('\ntitle: markdown 笔记\n'));

    final manifest = jsonOf(files, 'manifest.json');
    expect(manifest['counts']['notes'], 2);
  });

  test('附件打进 library/files/<fileId>__<safeName>，丢失的文件跳过并计数',
      () async {
    final payload = utf8.encode('fake image bytes');
    final f = File(p.join(attachDir.path, 'abc123.png'))
      ..writeAsBytesSync(payload);
    final ok = Attachment(
      id: 'file-1',
      kind: Attachment.kindImage,
      label: '照片 1.png',
      bytes: payload.length,
      access: AttachmentAccess(
        type: AttachmentAccess.typeLocalPath,
        value: f.path,
        mimeType: 'image/png',
      ),
    );
    const missing = Attachment(
      id: 'file-2',
      kind: Attachment.kindFile,
      label: 'gone.pdf',
      bytes: 10,
      access: AttachmentAccess(
        type: AttachmentAccess.typeLocalPath,
        value: '/nonexistent/gone.pdf',
      ),
    );
    await insertMessage('m1', '带附件', attachments: [ok, missing]);
    await insertMessage('m2', '同一附件再引用', attachments: [ok]);

    final result = await ArchiveExportService.instance
        .exportArchive(database: db, outputDir: outDir);
    expect(result.skippedFiles, 1);
    expect(result.files, 1);
    expect(
        p.basename(result.path),
        matches(RegExp(r'^msgrepo-archive-\d{8}-\d{6}\.zip$')));

    final bytes = await File(result.path).readAsBytes();
    final files = {
      for (final e in ZipDecoder().decodeBytes(bytes).files) e.name: e
    };

    final filesJson = jsonListOf(files, 'library/files.json');
    expect(filesJson.length, 1, reason: '同一附件被多条消息引用只打包一次');
    final entry = filesJson.single;
    expect(entry['id'], 'file-1');
    expect(entry['name'], '照片 1.png');
    expect(entry['mime_type'], 'image/png');
    expect(entry['size'], payload.length);
    expect(entry['path'], 'library/files/file-1__照片_1.png');
    expect(entry['created_at'], 2000);

    final zipped = files['library/files/file-1__照片_1.png']!;
    expect(zipped.content as List<int>, payload);

    final manifest = jsonOf(files, 'manifest.json');
    expect(manifest['counts']['files'], 1);
  });

  test('关联指向已删除的任务/消息时不产生锚点', () async {
    await insertTask('t1');
    await insertMessage('m1', '还在');
    await insertLink('m1', 't1', 3001);
    await insertLink('m1', 'ghost-task', 3002);
    await insertLink('ghost-message', 't1', 3003);

    final files = await exportAndUnzip();
    final anchors = jsonListOf(files, 'anchors.json');
    expect(anchors.length, 1);
    expect(anchors.single['task_id'], 't1');
    expect(anchors.single['target_id'], 'm1');
  });
}

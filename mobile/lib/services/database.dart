import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models.dart';
import '../models/message.dart';
import '../models/note.dart';
import '../models/task.dart';

/// 收件箱按应用筛选用的来源应用项。
class SourceApp {
  final String packageName;
  final String? appName;

  const SourceApp(this.packageName, this.appName);

  String get displayName =>
      (appName != null && appName!.isNotEmpty) ? appName! : packageName;
}

/// 本地 SQLite 存储：raw_messages（原始消息）与 structured_items（结构化结果）。
class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  Database? _db;

  Future<Database> get database async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'msgrepo.db'),
      version: 4,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return _db!;
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
          'ALTER TABLE raw_messages ADD COLUMN needs_reprocess INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 3) {
      await _splitFoldedMessages(db);
    }
    if (oldVersion < 4) {
      await _createV4Tables(db);
      await _migrateV3ToV4(db);
    }
  }

  /// 拆分系统折叠通知留下的存量消息：body 形如 "[5条]周辰羽: 。"、
  /// 标题形如 "26软工班长们的窝(3条新消息)"。折叠层里被盖住的历史消息无法找回，
  /// 这里把每条快照还原成它携带的最新一条（去前缀、解析 sender、重算 content_hash）。
  Future<void> _splitFoldedMessages(Database db) async {
    final foldBody = RegExp(r'^\[(\d+)条\]');
    final foldTitle = RegExp(r'\(\d+条新消息\)$');
    final senderPrefix = RegExp(r'^([^:：\n]{1,30})[:：]\s*');
    final rows = await db.query('raw_messages',
        columns: ['id', 'package_name', 'title', 'body', 'posted_at', 'sender'],
        where: "body LIKE '[%条]%' OR title LIKE '%(%条新消息)'");
    for (final row in rows) {
      var title = row['title'] as String;
      var body = row['body'] as String;
      String? sender = row['sender'] as String?;
      final newTitle = title.replaceFirst(foldTitle, '');
      var newBody = body.replaceFirst(foldBody, '');
      if (sender == null) {
        final m = senderPrefix.firstMatch(newBody);
        if (m != null) sender = m.group(1);
      }
      if (newTitle == title && newBody == body) continue;
      await db.update(
        'raw_messages',
        {
          'title': newTitle,
          'body': newBody,
          'sender': sender,
          'content_hash': computeContentHash(row['package_name'] as String,
              newTitle, newBody, row['posted_at'] as int),
        },
        where: 'id = ?',
        whereArgs: [row['id']],
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE raw_messages(
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
        attachments TEXT NOT NULL DEFAULT '[]',
        content_hash TEXT NOT NULL UNIQUE,
        status TEXT NOT NULL DEFAULT 'pending',
        needs_reprocess INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_raw_messages_status ON raw_messages(status)');
    await db.execute(
        'CREATE INDEX idx_raw_messages_posted_at ON raw_messages(posted_at)');
    await db.execute('''
      CREATE TABLE structured_items(
        id TEXT PRIMARY KEY,
        raw_message_ids TEXT NOT NULL,
        category TEXT NOT NULL,
        schema_version TEXT NOT NULL,
        title TEXT NOT NULL,
        summary TEXT NOT NULL,
        priority TEXT NOT NULL,
        confidence REAL NOT NULL,
        time TEXT NOT NULL,
        payload TEXT NOT NULL,
        tags TEXT NOT NULL DEFAULT '[]',
        processed_by TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await _createV4Tables(db);
  }

  /// v2 数据层建表（设计 §1.1 messages、§1.2 tasks、§1.3 笔记三级）。
  Future<void> _createV4Tables(Database db) async {
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
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_messages_status ON messages(status)');
    await db
        .execute('CREATE INDEX idx_messages_posted_at ON messages(posted_at)');
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
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_tasks_start ON tasks(start_at)');
    await db.execute('CREATE INDEX idx_tasks_status ON tasks(status)');
    await db.execute('''
      CREATE TABLE notebooks(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        sort INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE chapters(
        id TEXT PRIMARY KEY,
        notebook_id TEXT NOT NULL REFERENCES notebooks(id),
        name TEXT NOT NULL,
        sort INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE notes(
        id TEXT PRIMARY KEY,
        chapter_id TEXT NOT NULL REFERENCES chapters(id),
        title TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        content_format TEXT NOT NULL DEFAULT 'plain',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  /// v3 → v4 迁移：只增不删，旧表（raw_messages / structured_items）原样保留。
  Future<void> _migrateV3ToV4(Database db) async {
    // 1. messageId → priority 映射：P0/P1→red、P2→yellow、P3→green；
    //    一条消息被多条条目引用时取更高优先级（red > yellow > green）。
    const rank = {'red': 3, 'yellow': 2, 'green': 1};
    String? itemPriorityToMessage(String p) => switch (p) {
          'P0' || 'P1' => 'red',
          'P2' => 'yellow',
          'P3' => 'green',
          _ => null,
        };
    String itemPriorityToTask(String p) => switch (p) {
          'P0' => 'important',
          'P1' || 'P2' => 'normal',
          _ => 'minor',
        };
    final items = await db.query('structured_items');
    final messagePriorities = <String, String>{};
    for (final row in items) {
      final mapped = itemPriorityToMessage(row['priority'] as String);
      if (mapped == null) continue;
      final ids = asStringList(jsonDecode(row['raw_message_ids'] as String));
      for (final id in ids) {
        final existing = messagePriorities[id];
        if (existing == null || rank[mapped]! > rank[existing]!) {
          messagePriorities[id] = mapped;
        }
      }
    }

    // 2. raw_messages 全量复制进 messages（status 原样、priority 用映射）。
    final rawMessages = await db.query('raw_messages');
    for (final row in rawMessages) {
      await db.insert(
        'messages',
        {
          'id': row['id'],
          'package_name': row['package_name'],
          'app_name': row['app_name'],
          'channel_id': row['channel_id'],
          'conversation_title': row['conversation_title'],
          'sender': row['sender'],
          'title': row['title'],
          'body': row['body'],
          'posted_at': row['posted_at'],
          'capture_type': row['capture_type'],
          'import_source': null,
          'attachments': row['attachments'],
          'content_hash': row['content_hash'],
          'status': row['status'],
          'priority':
              messagePriorities[row['id'] as String] ?? MessagePriority.none,
          'linked_task_id': null,
          'created_at': row['created_at'],
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }

    // 3/4. structured_items 按 category 分流：todo/schedule → tasks，
    //      note → 默认笔记本「导入」章节「AI 笔记」下的 notes，其他不动。
    const importNotebookId = 'nb-import';
    const aiNotesChapterId = 'ch-ai-notes';
    for (final row in items) {
      final category = row['category'] as String;
      if (category == 'todo' || category == 'schedule') {
        final time = ItemTime.fromJson(
            (jsonDecode(row['time'] as String) as Map).cast<String, dynamic>());
        String kind;
        int? startAt;
        int? endAt;
        switch (time.kind) {
          case ItemTime.kindPoint:
            kind = TaskKind.point;
            startAt = time.startAt;
          case ItemTime.kindDeadline:
            kind = TaskKind.point;
            startAt = time.deadline;
          case ItemTime.kindRange:
            kind = TaskKind.range;
            startAt = time.startAt;
            endAt = time.endAt;
          default:
            kind = TaskKind.point;
        }
        final rawIds =
            asStringList(jsonDecode(row['raw_message_ids'] as String));
        final createdAt = (row['created_at'] as num).toInt();
        await db.insert(
          'tasks',
          {
            'id': row['id'],
            'title': row['title'],
            'description': row['summary'],
            'kind': kind,
            'start_at': startAt,
            'end_at': endAt,
            'priority': itemPriorityToTask(row['priority'] as String),
            'is_annual': 0,
            'source_message_id': rawIds.isEmpty ? null : rawIds.first,
            'status': TaskStatus.active,
            'created_at': createdAt,
            'updated_at': createdAt,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      } else if (category == 'note') {
        final now = DateTime.now().millisecondsSinceEpoch;
        await db.insert(
          'notebooks',
          {'id': importNotebookId, 'name': '导入', 'sort': 0, 'created_at': now},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        await db.insert(
          'chapters',
          {
            'id': aiNotesChapterId,
            'notebook_id': importNotebookId,
            'name': 'AI 笔记',
            'sort': 0,
            'created_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        final createdAt = (row['created_at'] as num).toInt();
        await db.insert(
          'notes',
          {
            'id': row['id'],
            'chapter_id': aiNotesChapterId,
            'title': row['title'],
            'content': row['summary'],
            'content_format': 'plain',
            'created_at': createdAt,
            'updated_at': createdAt,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }
  }

  // ---- raw_messages ----

  Map<String, Object?> _rawMessageToRow(RawMessage m) => {
        'id': m.id,
        'package_name': m.source.packageName,
        'app_name': m.source.appName,
        'channel_id': m.source.channelId,
        'conversation_title': m.source.conversationTitle,
        'sender': m.source.sender,
        'title': m.title,
        'body': m.body,
        'posted_at': m.postedAt,
        'capture_type': m.captureType,
        'attachments': jsonEncode(m.attachments.map((e) => e.toJson()).toList()),
        'content_hash': m.contentHash,
        'status': m.status,
        'needs_reprocess': m.needsReprocess ? 1 : 0,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      };

  RawMessage _rowToRawMessage(Map<String, Object?> row) => RawMessage(
        id: row['id'] as String,
        source: MessageSource(
          packageName: row['package_name'] as String,
          appName: row['app_name'] as String?,
          channelId: row['channel_id'] as String?,
          conversationTitle: row['conversation_title'] as String?,
          sender: row['sender'] as String?,
        ),
        title: row['title'] as String,
        body: row['body'] as String,
        postedAt: (row['posted_at'] as num).toInt(),
        captureType: row['capture_type'] as String,
        attachments: (jsonDecode(row['attachments'] as String) as List)
            .map((e) => Attachment.fromJson(e as Map<String, dynamic>))
            .toList(),
        contentHash: row['content_hash'] as String,
        status: row['status'] as String,
        needsReprocess: (row['needs_reprocess'] as num? ?? 0) != 0,
      );

  Future<bool> existsByContentHash(String contentHash) async {
    final db = await database;
    final rows = await db.query('raw_messages',
        columns: ['id'],
        where: 'content_hash = ?',
        whereArgs: [contentHash],
        limit: 1);
    return rows.isNotEmpty;
  }

  /// 入库前按 contentHash 查重；返回是否为新插入。
  Future<bool> insertRawMessageIfNew(RawMessage message) async {
    if (await existsByContentHash(message.contentHash)) return false;
    final db = await database;
    await db.insert('raw_messages', _rawMessageToRow(message));
    return true;
  }

  Future<List<RawMessage>> getRawMessages(
      {String? status, String? packageName, int limit = 500}) async {
    final db = await database;
    final wheres = <String>[];
    final args = <Object?>[];
    if (status != null) {
      wheres.add('status = ?');
      args.add(status);
    }
    if (packageName != null) {
      wheres.add('package_name = ?');
      args.add(packageName);
    }
    final rows = await db.query(
      'raw_messages',
      where: wheres.isEmpty ? null : wheres.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'posted_at DESC',
      limit: limit,
    );
    return rows.map(_rowToRawMessage).toList();
  }

  /// 收件箱按应用筛选：distinct 来源应用，按最近消息时间降序。
  Future<List<SourceApp>> getDistinctSources() async {
    final db = await database;
    final rows = await db.rawQuery(
        'SELECT package_name, app_name FROM raw_messages '
        'GROUP BY package_name ORDER BY MAX(posted_at) DESC');
    return rows
        .map((r) =>
            SourceApp(r['package_name'] as String, r['app_name'] as String?))
        .toList();
  }

  Future<List<RawMessage>> getRawMessagesByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.query('raw_messages',
        where: 'id IN ($placeholders)', whereArgs: ids);
    return rows.map(_rowToRawMessage).toList();
  }

  Future<void> updateRawMessageStatus(List<String> ids, String status) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.update('raw_messages', {'status': status},
        where: 'id IN ($placeholders)', whereArgs: ids);
  }

  // ---- 消息状态机：pending ⇄ processed → archived ----

  /// 回退一条消息为 pending 并标记 needs_reprocess=1，同时删除所有
  /// rawMessageIds 含该消息的结构化条目。返回被删除的条目（调用方取消提醒）。
  Future<List<StructuredItem>> revertMessageToPending(String messageId) async {
    final db = await database;
    await db.update(
      'raw_messages',
      {'status': RawMessage.statusPending, 'needs_reprocess': 1},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    final affected = (await getStructuredItems())
        .where((e) => e.rawMessageIds.contains(messageId))
        .toList();
    if (affected.isNotEmpty) {
      final placeholders = List.filled(affected.length, '?').join(',');
      await db.delete('structured_items',
          where: 'id IN ($placeholders)',
          whereArgs: affected.map((e) => e.id).toList());
    }
    return affected;
  }

  /// 撤销处理：条目全部关联消息回退 pending + needs_reprocess=1，删除条目本身。
  /// （取消提醒由调用方负责）
  Future<void> revertStructuredItem(StructuredItem item) async {
    final db = await database;
    if (item.rawMessageIds.isNotEmpty) {
      final placeholders = List.filled(item.rawMessageIds.length, '?').join(',');
      await db.update(
        'raw_messages',
        {'status': RawMessage.statusPending, 'needs_reprocess': 1},
        where: 'id IN ($placeholders)',
        whereArgs: item.rawMessageIds,
      );
    }
    await db.delete('structured_items', where: 'id = ?', whereArgs: [item.id]);
  }

  /// todo 勾选联动：更新 payload.status，并把关联原始消息
  /// done → archived（已完成自动归档）/ 取消 → processed。
  /// 返回更新后的条目。
  Future<StructuredItem> setTodoDone(StructuredItem item, bool done) async {
    final payload = Map<String, dynamic>.of(item.payload);
    payload['status'] = done ? 'done' : 'open';
    final updated = item.copyWith(payload: payload);
    await updateStructuredItem(updated);
    await updateRawMessageStatus(
      item.rawMessageIds,
      done ? RawMessage.statusArchived : RawMessage.statusProcessed,
    );
    return updated;
  }

  /// needs_reprocess=1 的消息 ID（同步时放入 reprocessMessageIds）。
  Future<List<String>> getNeedsReprocessIds() async {
    final db = await database;
    final rows = await db.query('raw_messages',
        columns: ['id'], where: 'needs_reprocess = 1');
    return rows.map((r) => r['id'] as String).toList();
  }

  /// 同步成功后清除重处理标记。
  Future<void> clearNeedsReprocess(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.update('raw_messages', {'needs_reprocess': 0},
        where: 'id IN ($placeholders)', whereArgs: ids);
  }

  // ---- structured_items ----

  Map<String, Object?> _itemToRow(StructuredItem item) => {
        'id': item.id,
        'raw_message_ids': jsonEncode(item.rawMessageIds),
        'category': item.category,
        'schema_version': item.schemaVersion,
        'title': item.title,
        'summary': item.summary,
        'priority': item.priority,
        'confidence': item.confidence,
        'time': jsonEncode(item.time.toJson()),
        'payload': jsonEncode(item.payload),
        'tags': jsonEncode(item.tags),
        'processed_by': jsonEncode(item.processedBy.toJson()),
        'created_at': DateTime.now().millisecondsSinceEpoch,
      };

  StructuredItem _rowToItem(Map<String, Object?> row) => StructuredItem(
        id: row['id'] as String,
        rawMessageIds: asStringList(jsonDecode(row['raw_message_ids'] as String)),
        category: row['category'] as String,
        schemaVersion: row['schema_version'] as String,
        title: row['title'] as String,
        summary: row['summary'] as String,
        priority: row['priority'] as String,
        confidence: (row['confidence'] as num).toDouble(),
        time: ItemTime.fromJson(
            (jsonDecode(row['time'] as String) as Map).cast<String, dynamic>()),
        payload:
            (jsonDecode(row['payload'] as String) as Map).cast<String, dynamic>(),
        tags: asStringList(jsonDecode(row['tags'] as String)),
        processedBy: ProcessedBy.fromJson(
            (jsonDecode(row['processed_by'] as String) as Map)
                .cast<String, dynamic>()),
      );

  Future<void> insertStructuredItems(List<StructuredItem> items) async {
    if (items.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final item in items) {
      batch.insert('structured_items', _itemToRow(item),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// 更新可编辑字段（标题/时间/payload，todo 勾选状态存在 payload.status 里）。
  Future<void> updateStructuredItem(StructuredItem item) async {
    final db = await database;
    await db.update(
      'structured_items',
      {
        'title': item.title,
        'time': jsonEncode(item.time.toJson()),
        'payload': jsonEncode(item.payload),
      },
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  Future<List<StructuredItem>> getStructuredItems({int limit = 500}) async {
    final db = await database;
    final rows = await db.query(
      'structured_items',
      orderBy:
          "CASE priority WHEN 'P0' THEN 0 WHEN 'P1' THEN 1 WHEN 'P2' THEN 2 ELSE 3 END, created_at DESC",
      limit: limit,
    );
    return rows.map(_rowToItem).toList();
  }

  // ---- v2: messages ----

  /// 入库前按 contentHash 查重；返回是否为新插入。
  Future<bool> insertMessageIfNew(Message message) async {
    final db = await database;
    final rows = await db.query('messages',
        columns: ['id'],
        where: 'content_hash = ?',
        whereArgs: [message.contentHash],
        limit: 1);
    if (rows.isNotEmpty) return false;
    await db.insert('messages', message.toRow());
    return true;
  }

  Future<List<Message>> getMessages(
      {String? status,
      String? packageName,
      List<String>? priorities,
      int limit = 500}) async {
    final db = await database;
    final wheres = <String>[];
    final args = <Object?>[];
    if (status != null) {
      wheres.add('status = ?');
      args.add(status);
    }
    if (packageName != null) {
      wheres.add('package_name = ?');
      args.add(packageName);
    }
    if (priorities != null && priorities.isNotEmpty) {
      wheres.add(
          'priority IN (${List.filled(priorities.length, '?').join(',')})');
      args.addAll(priorities);
    }
    final rows = await db.query(
      'messages',
      where: wheres.isEmpty ? null : wheres.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'posted_at DESC',
      limit: limit,
    );
    return rows.map(Message.fromRow).toList();
  }

  Future<Message?> getMessageById(String id) async {
    final db = await database;
    final rows =
        await db.query('messages', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Message.fromRow(rows.first);
  }

  Future<List<Message>> getMessagesByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows =
        await db.query('messages', where: 'id IN ($placeholders)', whereArgs: ids);
    return rows.map(Message.fromRow).toList();
  }

  /// 消息列表按应用筛选：distinct 来源应用，按最近消息时间降序。
  Future<List<SourceApp>> getDistinctMessageSources() async {
    final db = await database;
    final rows = await db.rawQuery(
        'SELECT package_name, app_name FROM messages '
        'GROUP BY package_name ORDER BY MAX(posted_at) DESC');
    return rows
        .map((r) =>
            SourceApp(r['package_name'] as String, r['app_name'] as String?))
        .toList();
  }

  Future<void> updateMessageStatus(List<String> ids, String status) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.update('messages', {'status': status},
        where: 'id IN ($placeholders)', whereArgs: ids);
  }

  Future<void> updateMessagePriority(List<String> ids, String priority) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.update('messages', {'priority': priority},
        where: 'id IN ($placeholders)', whereArgs: ids);
  }

  Future<void> setMessageLinkedTask(String messageId, String? taskId) async {
    final db = await database;
    await db.update('messages', {'linked_task_id': taskId},
        where: 'id = ?', whereArgs: [messageId]);
  }

  Future<void> deleteMessages(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.delete('messages', where: 'id IN ($placeholders)', whereArgs: ids);
  }

  // ---- v2: tasks ----

  Future<void> insertTask(Task task) async {
    final db = await database;
    await db.insert('tasks', task.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 全字段更新并自动刷新 updated_at。
  Future<void> updateTask(Task task) async {
    final db = await database;
    await db.update(
      'tasks',
      task
          .copyWith(updatedAt: DateTime.now().millisecondsSinceEpoch)
          .toRow(),
      where: 'id = ?',
      whereArgs: [task.id],
    );
  }

  Future<Task?> getTaskById(String id) async {
    final db = await database;
    final rows =
        await db.query('tasks', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Task.fromRow(rows.first);
  }

  Future<List<Task>> getTasks({String? status, int limit = 1000}) async {
    final db = await database;
    final rows = await db.query(
      'tasks',
      where: status != null ? 'status = ?' : null,
      whereArgs: status != null ? [status] : null,
      orderBy: 'start_at IS NULL, start_at ASC',
      limit: limit,
    );
    return rows.map(Task.fromRow).toList();
  }

  /// 与半开区间 [startMs, endMs) 有交集的任务（start_at 非空）。
  /// 年度任务（is_annual=1）一律包含，调用方自行按年平移。
  Future<List<Task>> getTasksOverlapping(int startMs, int endMs,
      {String status = 'active'}) async {
    final db = await database;
    final rows = await db.query(
      'tasks',
      where: 'status = ? AND (is_annual = 1 OR (start_at IS NOT NULL AND '
          'start_at < ? AND ((end_at IS NULL AND start_at >= ?) OR end_at > ?)))',
      whereArgs: [status, endMs, startMs, startMs],
      orderBy: 'start_at ASC',
    );
    return rows.map(Task.fromRow).toList();
  }

  /// 无时间任务（"我的待办"）：优先级 important > normal > minor，再按创建时间。
  Future<List<Task>> getUntimedTasks() async {
    final db = await database;
    final rows = await db.query(
      'tasks',
      where: "start_at IS NULL AND status = 'active'",
      orderBy: "CASE priority WHEN 'important' THEN 0 WHEN 'normal' THEN 1 "
          'ELSE 2 END, created_at ASC',
    );
    return rows.map(Task.fromRow).toList();
  }

  Future<List<Task>> getAnnualTasks() async {
    final db = await database;
    final rows = await db.query('tasks',
        where: 'is_annual = 1', orderBy: 'start_at ASC');
    return rows.map(Task.fromRow).toList();
  }

  Future<void> setTaskStatus(List<String> ids, String status) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.update('tasks', {'status': status},
        where: 'id IN ($placeholders)', whereArgs: ids);
  }

  Future<void> deleteTasks(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.delete('tasks', where: 'id IN ($placeholders)', whereArgs: ids);
  }

  // ---- v2: 笔记三级 ----

  Future<List<Notebook>> getNotebooks() async {
    final db = await database;
    final rows = await db.query('notebooks', orderBy: 'sort ASC');
    return rows.map(Notebook.fromRow).toList();
  }

  Future<void> insertNotebook(Notebook notebook) async {
    final db = await database;
    await db.insert('notebooks', notebook.toRow());
  }

  Future<void> renameNotebook(String id, String name) async {
    final db = await database;
    await db.update('notebooks', {'name': name},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 级联删除：笔记本 + 其下全部章节 + 章节下全部笔记，一个事务。
  Future<void> deleteNotebook(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('notes',
          where:
              'chapter_id IN (SELECT id FROM chapters WHERE notebook_id = ?)',
          whereArgs: [id]);
      await txn.delete('chapters', where: 'notebook_id = ?', whereArgs: [id]);
      await txn.delete('notebooks', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<List<Chapter>> getChapters(String notebookId) async {
    final db = await database;
    final rows = await db.query('chapters',
        where: 'notebook_id = ?', whereArgs: [notebookId], orderBy: 'sort ASC');
    return rows.map(Chapter.fromRow).toList();
  }

  Future<void> insertChapter(Chapter chapter) async {
    final db = await database;
    await db.insert('chapters', chapter.toRow());
  }

  Future<void> renameChapter(String id, String name) async {
    final db = await database;
    await db
        .update('chapters', {'name': name}, where: 'id = ?', whereArgs: [id]);
  }

  /// 级联删除：章节 + 其下全部笔记。
  Future<void> deleteChapter(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('notes', where: 'chapter_id = ?', whereArgs: [id]);
      await txn.delete('chapters', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<List<Note>> getNotes(String chapterId) async {
    final db = await database;
    final rows = await db.query('notes',
        where: 'chapter_id = ?',
        whereArgs: [chapterId],
        orderBy: 'updated_at DESC');
    return rows.map(Note.fromRow).toList();
  }

  Future<Note?> getNoteById(String id) async {
    final db = await database;
    final rows =
        await db.query('notes', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Note.fromRow(rows.first);
  }

  Future<void> insertNote(Note note) async {
    final db = await database;
    await db.insert('notes', note.toRow());
  }

  /// 全字段更新并自动刷新 updated_at。
  Future<void> updateNote(Note note) async {
    final db = await database;
    await db.update(
      'notes',
      note.copyWith(updatedAt: DateTime.now().millisecondsSinceEpoch).toRow(),
      where: 'id = ?',
      whereArgs: [note.id],
    );
  }

  Future<void> deleteNote(String id) async {
    final db = await database;
    await db.delete('notes', where: 'id = ?', whereArgs: [id]);
  }
}

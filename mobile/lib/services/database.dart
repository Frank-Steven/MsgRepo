import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/message.dart';
import '../models/note.dart';
import '../models/task.dart';
import 'app_log.dart';
import 'reminder_service.dart';

/// 收件箱按应用筛选用的来源应用项。
class SourceApp {
  final String packageName;
  final String? appName;

  const SourceApp(this.packageName, this.appName);

  String get displayName =>
      (appName != null && appName!.isNotEmpty) ? appName! : packageName;
}

List<String> _stringList(dynamic v) =>
    v == null ? const [] : (v as List).map((e) => e.toString()).toList();

int? _intOrNull(dynamic v) => v == null ? null : (v as num).toInt();

/// 本地 SQLite 存储（设计 §1，DB v5）：messages / tasks / 笔记三级为主表；
/// v1 的 raw_messages / structured_items 旧表保留不删（只删了读写代码）。
/// 建「消息 ↔ 任务」多对多关联表（N1，DB v6）。抽成顶层函数便于单测。
Future<void> createMessageTaskLinksTable(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS message_task_links(
      message_id TEXT NOT NULL,
      task_id TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      PRIMARY KEY(message_id, task_id)
    )
  ''');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_links_task ON message_task_links(task_id)');
}

/// v5 → v6 数据迁移：把旧的 1:1 绑定（messages.linked_task_id 与
/// tasks.source_message_id 两个方向）灌进关联表。旧的列保留不删（兼容只读回放）。
Future<void> migrateLinksToV6(DatabaseExecutor db) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  await db.rawInsert('''
    INSERT OR IGNORE INTO message_task_links(message_id, task_id, created_at)
    SELECT id, linked_task_id, ? FROM messages WHERE linked_task_id IS NOT NULL
  ''', [now]);
  await db.rawInsert('''
    INSERT OR IGNORE INTO message_task_links(message_id, task_id, created_at)
    SELECT source_message_id, id, ? FROM tasks WHERE source_message_id IS NOT NULL
  ''', [now]);
}

/// 单条绑定写入（兼容旧调用点）：同时更新旧列与关联表，保证双向一致。
Future<void> setSingleMessageTaskLink(
    DatabaseExecutor db, String messageId, String? taskId) async {
  await db.update('messages', {'linked_task_id': taskId},
      where: 'id = ?', whereArgs: [messageId]);
  await db.delete('message_task_links',
      where: 'message_id = ?', whereArgs: [messageId]);
  if (taskId != null) {
    await db.insert(
      'message_task_links',
      {
        'message_id': messageId,
        'task_id': taskId,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }
}

/// 批量入库的分块大小：SQLite 的绑定变量上限（老版本 999），留足余量。
const int kMessageHashLookupChunk = 400;

/// 「按 contentHash 去重后批量插入」的事务内实现（O03，2026-10-21）。
///
/// 语义与**逐条**调用 [AppDatabase.insertMessageIfNew] 等价：
/// - 批内同一个 contentHash 只留**第一条**（先到先得，与逐条 check-then-insert 一致）；
/// - 库里已存在的 hash 跳过（不覆盖、不更新）；
/// - 插入顺序 = 入参顺序（rowid 递增，保证与队列文件读取顺序一致）。
///
/// 拆成顶层函数（而不是直接写在 AppDatabase 里）是为了能用 sqflite_common_ffi
/// 直接单测，不依赖 AppDatabase 单例与迁移链。调用方负责提供事务——
/// [AppDatabase.insertMessagesIfNew] 就是 `db.transaction(...)` 包一层。
///
/// 返回实际新增条数（被跳过的不计）。
Future<int> insertMessagesIfNewInto(
    DatabaseExecutor txn, List<Message> messages) async {
  if (messages.isEmpty) return 0;

  // 1) 批内去重：同 hash 只留第一条，避免同一批里的重复通知被插两次
  final seenHashes = <String>{};
  final candidates = <Message>[];
  for (final m in messages) {
    if (seenHashes.add(m.contentHash)) candidates.add(m);
  }

  // 2) 一次查出库中已存在的 hash（分块，避免超出 SQLite 绑定变量上限）
  final existing = <String>{};
  for (var i = 0; i < candidates.length; i += kMessageHashLookupChunk) {
    final end = i + kMessageHashLookupChunk <= candidates.length
        ? i + kMessageHashLookupChunk
        : candidates.length;
    final part = <String>[
      for (var j = i; j < end; j++) candidates[j].contentHash,
    ];
    final rows = await txn.query('messages',
        columns: ['content_hash'],
        where: 'content_hash IN (${List.filled(part.length, '?').join(',')})',
        whereArgs: part);
    for (final r in rows) {
      existing.add(r['content_hash'] as String);
    }
  }

  // 3) 只插新的（batch = 事务内的多条 insert，一次性提交）
  final batch = txn.batch();
  var inserted = 0;
  for (final m in candidates) {
    if (existing.contains(m.contentHash)) continue;
    batch.insert('messages', m.toRow());
    inserted++;
  }
  if (inserted > 0) await batch.commit(noResult: true);
  return inserted;
}

class AppDatabase {
  AppDatabase._();

  /// 列表默认上限（P3-8）：超出时调用方应提示「仅显示前 N 条」而不是静默截断。
  static const defaultMessageLimit = 500;
  static const defaultTaskLimit = 1000;

  static final AppDatabase instance = AppDatabase._();

  Database? _db;

  Future<Database> get database async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'msgrepo.db'),
      version: 7,
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
    if (oldVersion < 5) {
      await db.execute('ALTER TABLE tasks ADD COLUMN parent_id TEXT');
    }
    if (oldVersion < 6) {
      // N1：消息 ↔ 任务从 1:1 升级为多对多（一条消息可产多个任务，多条消息可指向同一任务）
      await createMessageTaskLinksTable(db);
      await migrateLinksToV6(db);
    }
    if (oldVersion < 7) {
      // v7（2026-10-21，F07）：记录用户手动编辑正文/附件的时间，NULL = 采集原文。
      await db.execute('ALTER TABLE messages ADD COLUMN edited_at INTEGER');
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
        edited_at INTEGER,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_messages_status ON messages(status)');
    await db
        .execute('CREATE INDEX idx_messages_posted_at ON messages(posted_at)');
    await createMessageTaskLinksTable(db);
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
      final ids = _stringList(jsonDecode(row['raw_message_ids'] as String));
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
        // v1 time 对象（structured-item.schema.json）→ v2 kind/startAt/endAt
        final time =
            (jsonDecode(row['time'] as String) as Map).cast<String, dynamic>();
        String kind;
        int? startAt;
        int? endAt;
        switch (time['kind']) {
          case 'point':
            kind = TaskKind.point;
            startAt = _intOrNull(time['startAt']);
          case 'deadline':
            kind = TaskKind.point;
            startAt = _intOrNull(time['deadline']);
          case 'range':
            kind = TaskKind.range;
            startAt = _intOrNull(time['startAt']);
            endAt = _intOrNull(time['endAt']);
          default:
            kind = TaskKind.point;
        }
        final rawIds =
            _stringList(jsonDecode(row['raw_message_ids'] as String));
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

  /// 批量「去重后插入」，**整批一个事务**（O03，2026-10-21）：通知队列一次拉取
  /// 往往有几十上百个文件，原来每个文件一次 `insertMessageIfNew`（一次查重 +
  /// 一次插入，各自隐式事务）= N 次 SQL 往返；现在变成 1 次事务（内含分块的
  /// IN 查重 + 一次 batch insert）。返回实际新增条数。
  ///
  /// 去重/顺序语义见 [insertMessagesIfNewInto]。
  Future<int> insertMessagesIfNew(List<Message> messages) async {
    if (messages.isEmpty) return 0;
    final db = await database;
    return db.transaction((txn) => insertMessagesIfNewInto(txn, messages));
  }

  /// 全部消息的 content_hash 集（批量导入一次性查重用，v2.6）。
  Future<Set<String>> getAllMessageContentHashes() async {
    final db = await database;
    final rows = await db.query('messages', columns: ['content_hash']);
    return {for (final r in rows) r['content_hash'] as String};
  }

  /// 已处理消息的 content_hash 集（v2.6.1 省 Token：同内容已评估过的
  /// pending 重复消息跳过送模型）。
  Future<Set<String>> getProcessedContentHashes() async {
    final db = await database;
    final rows = await db.query('messages',
        columns: ['content_hash'], where: "status = 'processed'");
    return {for (final r in rows) r['content_hash'] as String};
  }

  /// 批量插入消息（单事务；调用方负责 content_hash 预去重，v2.6 导入用）。
  Future<void> insertMessagesBatch(List<Message> messages) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final m in messages) {
        batch.insert('messages', m.toRow());
      }
      await batch.commit(noResult: true);
    });
  }

  /// [oldestFirst] = true 时按 posted_at 升序（自动处理用：先清最早的积压）。
  Future<List<Message>> getMessages(
      {String? status,
      String? packageName,
      List<String>? priorities,
      int limit = defaultMessageLimit,
      int offset = 0,
      bool oldestFirst = false}) async {
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
      offset: offset,
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

  /// 用户手动编辑消息正文（F07）：同时打上 edited_at，便于区分采集原文。
  Future<void> updateMessageBody(String id, String body) async {
    final db = await database;
    await db.update(
      'messages',
      {'body': body, 'edited_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 用户增删消息附件（F07）：整份 attachments JSON 覆盖写，同样打 edited_at。
  Future<void> updateMessageAttachments(
      String id, List<Map<String, dynamic>> attachments) async {
    final db = await database;
    await db.update(
      'messages',
      {
        'attachments': jsonEncode(attachments),
        'edited_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 某条消息关联的任务（F08）：走 links 表，未定时的排在后面。
  Future<List<Task>> tasksForMessage(String messageId) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT t.* FROM tasks t '
      'INNER JOIN message_task_links l ON l.task_id = t.id '
      'WHERE l.message_id = ? '
      'ORDER BY t.start_at IS NULL, t.start_at ASC',
      [messageId],
    );
    return rows.map(Task.fromRow).toList();
  }

  Future<void> setMessageLinkedTask(String messageId, String? taskId) async {
    final db = await database;
    await setSingleMessageTaskLink(db, messageId, taskId);
  }

  // ---- N1：消息 ↔ 任务 多对多 ----

  /// 追加一条关联（一条消息可以关联多个任务）。旧列 linked_task_id 在为空时补上，
  /// 让只读旧字段的展示代码仍然有值。
  Future<void> linkMessageTask(String messageId, String taskId) async {
    final db = await database;
    await db.insert(
      'message_task_links',
      {
        'message_id': messageId,
        'task_id': taskId,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await db.rawUpdate(
        'UPDATE messages SET linked_task_id = ? WHERE id = ? AND linked_task_id IS NULL',
        [taskId, messageId]);
  }

  /// 解除一条关联；旧列自动改指向剩余的第一条（或清空）。
  Future<void> unlinkMessageTask(String messageId, String taskId) async {
    final db = await database;
    await db.delete('message_task_links',
        where: 'message_id = ? AND task_id = ?',
        whereArgs: [messageId, taskId]);
    final remaining = await taskIdsForMessage(messageId);
    await db.update('messages',
        {'linked_task_id': remaining.isEmpty ? null : remaining.first},
        where: 'id = ?', whereArgs: [messageId]);
  }

  /// 解除某条消息的全部关联（「取消任务」用）。
  Future<void> unlinkAllForMessage(String messageId) async {
    final db = await database;
    await db.delete('message_task_links',
        where: 'message_id = ?', whereArgs: [messageId]);
    await db.update('messages', {'linked_task_id': null},
        where: 'id = ?', whereArgs: [messageId]);
  }

  /// 删除任务时清理它的所有关联（避免悬挂引用）。
  Future<void> unlinkAllForTask(String taskId) async {
    final db = await database;
    await db.delete('message_task_links',
        where: 'task_id = ?', whereArgs: [taskId]);
    await db.rawUpdate(
        'UPDATE messages SET linked_task_id = NULL WHERE linked_task_id = ?', [taskId]);
  }

  /// 单条消息关联的任务 id（按关联创建时间升序）。
  Future<List<String>> taskIdsForMessage(String messageId) async {
    final db = await database;
    final rows = await db.query('message_task_links',
        columns: ['task_id'],
        where: 'message_id = ?',
        whereArgs: [messageId],
        orderBy: 'created_at ASC');
    return [for (final r in rows) r['task_id'] as String];
  }

  /// 全量映射 messageId → taskIds（消息列表一次取回，避免 N+1 查询）。
  Future<Map<String, List<String>>> messageTaskLinks() async {
    final db = await database;
    final rows = await db.query('message_task_links',
        columns: ['message_id', 'task_id'], orderBy: 'created_at ASC');
    final map = <String, List<String>>{};
    for (final r in rows) {
      map.putIfAbsent(r['message_id'] as String, () => []).add(r['task_id'] as String);
    }
    return map;
  }

  /// 全量映射 taskId → messageIds（任务详情展示「来源消息」用）。
  Future<Map<String, List<String>>> taskMessageLinks() async {
    final db = await database;
    final rows = await db.query('message_task_links',
        columns: ['task_id', 'message_id'], orderBy: 'created_at ASC');
    final map = <String, List<String>>{};
    for (final r in rows) {
      map.putIfAbsent(r['task_id'] as String, () => []).add(r['message_id'] as String);
    }
    return map;
  }

  /// 某个任务的来源消息（可能多条）。
  Future<List<Message>> messagesForTask(String taskId) async {
    final ids = await taskMessageLinks();
    final list = ids[taskId] ?? const <String>[];
    if (list.isEmpty) return const [];
    return getMessagesByIds(list);
  }

  Future<void> deleteMessages(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.delete('messages', where: 'id IN ($placeholders)', whereArgs: ids);
  }

  /// 撤销删除用：整体回插（replace 覆盖同 id 残留）。
  Future<void> restoreMessages(List<Message> messages) async {
    if (messages.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final m in messages) {
      batch.insert('messages', m.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  // ---- v2: tasks ----

  Future<void> insertTask(Task task) async {
    final db = await database;
    await db.insert('tasks', task.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    _rescheduleReminders();
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
    _rescheduleReminders();
  }

  Future<Task?> getTaskById(String id) async {
    final db = await database;
    final rows =
        await db.query('tasks', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Task.fromRow(rows.first);
  }

  Future<List<Task>> getTasks(
      {String? status,
      int limit = defaultTaskLimit,
      int offset = 0}) async {
    final db = await database;
    final rows = await db.query(
      'tasks',
      where: status != null ? 'status = ?' : null,
      whereArgs: status != null ? [status] : null,
      orderBy: 'start_at IS NULL, start_at ASC',
      limit: limit,
      offset: offset,
    );
    return rows.map(Task.fromRow).toList();
  }

  /// AI 确认批量落库：**一个事务 + batch**。
  ///
  /// 2026-10-20 性能修复：原确认流对每条消息做 6~8 次独立 SQL（预取旧关联、
  /// 逐条建任务、改优先级/状态、解绑、逐条建关联），上千条时是上万次串行 await，
  /// 界面在点「确认」后会明显卡住。现在统一攒好再一次性提交。
  Future<void> applyAiConfirmBatch(
      List<
              ({
                String messageId,
                String priority,
                List<Task> newTasks,
                List<String> linkIds,
              })>
          items) async {
    if (items.isEmpty) return;
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final it in items) {
        for (final task in it.newTasks) {
          batch.insert('tasks', task.toRow());
        }
        batch.update(
          'messages',
          {'priority': it.priority, 'status': MessageStatus.processed},
          where: 'id = ?',
          whereArgs: [it.messageId],
        );
        batch.delete('message_task_links',
            where: 'message_id = ?', whereArgs: [it.messageId]);
        for (final taskId in it.linkIds) {
          batch.insert(
            'message_task_links',
            {
              'message_id': it.messageId,
              'task_id': taskId,
              'created_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
        batch.rawUpdate(
            'UPDATE messages SET linked_task_id = ? WHERE id = ?',
            [it.linkIds.isEmpty ? null : it.linkIds.first, it.messageId]);
      }
      await batch.commit(noResult: true);
    });
    _rescheduleReminders();
  }

  /// 全部「进行中」任务（AI 确认前查重复用；写操作量小，不做分页）。
  /// 已完成/已放弃的任务不参与复用：同一件事再次出现时应当新建。
  Future<List<Task>> getActiveTasks() async {
    final db = await database;
    final rows = await db.query(
      'tasks',
      where: 'status = ?',
      whereArgs: [TaskStatus.active],
      orderBy: 'created_at ASC',
    );
    return rows.map(Task.fromRow).toList();
  }

  /// 与 [getMessages] 同条件的总条数（用于提示「仅显示前 N 条」）。
  Future<int> countMessages(
      {String? status, String? packageName, List<String>? priorities}) async {
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
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM messages'
      '${wheres.isEmpty ? '' : ' WHERE ${wheres.join(' AND ')}'}',
      args.isEmpty ? null : args,
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  /// 与 [getTasks] 同条件的总条数。
  Future<int> countTasks({String? status}) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM tasks${status != null ? ' WHERE status = ?' : ''}',
      status != null ? [status] : null,
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  /// 与半开区间 [startMs, endMs) 有交集的任务（start_at 非空）。
  /// （v2.4：is_annual 逐年平移下线，一律按普通区间判断。）
  Future<List<Task>> getTasksOverlapping(int startMs, int endMs,
      {String status = 'active'}) async {
    final db = await database;
    final rows = await db.query(
      'tasks',
      where: 'status = ? AND start_at IS NOT NULL AND '
          'start_at < ? AND ((end_at IS NULL AND start_at >= ?) OR end_at > ?)',
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

  /// 子任务（设计 §1.2：parent_id 仅一级）。
  Future<List<Task>> getChildTasks(String parentId) async {
    final db = await database;
    final rows = await db.query('tasks',
        where: 'parent_id = ?', whereArgs: [parentId], orderBy: 'start_at ASC');
    return rows.map(Task.fromRow).toList();
  }

  /// 全部父任务的直接子任务进度：parentId -> (done, total)（设计 §3，v2.3）。
  Future<Map<String, (int, int)>> getSubtaskProgress() async {
    final db = await database;
    final rows = await db.query('tasks',
        columns: ['parent_id', 'status'], where: 'parent_id IS NOT NULL');
    final result = <String, (int, int)>{};
    for (final r in rows) {
      final p = r['parent_id'] as String;
      final cur = result[p] ?? (0, 0);
      result[p] = (
        cur.$1 + (r['status'] == TaskStatus.done ? 1 : 0),
        cur.$2 + 1,
      );
    }
    return result;
  }

  Future<void> setTaskStatus(List<String> ids, String status) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.update('tasks', {'status': status},
        where: 'id IN ($placeholders)', whereArgs: ids);
    _rescheduleReminders();
  }

  Future<void> deleteTasks(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.delete('tasks', where: 'id IN ($placeholders)', whereArgs: ids);
    _rescheduleReminders();
  }

  Timer? _rescheduleTimer;
  bool _rescheduling = false;
  bool _rescheduleAgain = false;

  /// 任务写操作后重排本地提醒。
  ///
  /// **合并 + 单飞**（2026-10-20 性能修复）：原实现每次写任务都 fire-and-forget 一次
  /// `rescheduleAll()`——它要取消上一轮 N 个提醒再逐个 zonedSchedule（2N 次平台通道
  /// 调用）且无互斥。AI 批量确认时等于上百次并发全量重排，直接把界面拖卡。
  void _rescheduleReminders() {
    _rescheduleTimer?.cancel();
    _rescheduleTimer = Timer(const Duration(milliseconds: 400), _runReschedule);
  }

  Future<void> _runReschedule() async {
    if (_rescheduling) {
      _rescheduleAgain = true; // 跑到一半又来了写操作：等这轮结束再补一次
      return;
    }
    _rescheduling = true;
    try {
      await ReminderService.instance.rescheduleAll();
    } catch (e, st) {
      AppLog.instance.warn('db.reschedule', e, st);
    } finally {
      _rescheduling = false;
      if (_rescheduleAgain) {
        _rescheduleAgain = false;
        _rescheduleReminders();
      }
    }
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

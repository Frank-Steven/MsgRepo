import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models.dart';

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
      version: 1,
      onCreate: _onCreate,
    );
    return _db!;
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
}

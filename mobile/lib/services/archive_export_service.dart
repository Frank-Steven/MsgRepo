import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/message.dart';
import 'attachment_store.dart';
import 'database.dart';

/// 导出结果：落盘路径 + 各类条数（与 manifest.counts 一致）。
class ArchiveExportResult {
  final String path;
  final int tasks;
  final int messages;
  final int notes;
  final int files;
  final int anchors;

  /// 附件引用了但磁盘上已不存在、未能打进 zip 的文件数。
  final int skippedFiles;

  const ArchiveExportResult({
    required this.path,
    required this.tasks,
    required this.messages,
    required this.notes,
    required this.files,
    required this.anchors,
    required this.skippedFiles,
  });
}

/// 过渡版本 v2.9 存档导出（design-v3 §7.1，格式定稿见 design-v3-details §5）。
///
/// 纯新增、只读：事务快照读全量表 → 组装 v3 格式 zip → 落盘到应用文档目录，
/// 不写回任何数据。与 v2 的差异只在导出侧：
/// `message_task_links` / `messages.linked_task_id` 在这里转换为锚点
/// （anchors.json 行 + 追加到消息正文末尾的 ⟦task:<anchorId>⟧ marker），
/// v3 导入时无需再兼容任何旧关联格式。
class ArchiveExportService {
  ArchiveExportService._();

  static final ArchiveExportService instance = ArchiveExportService._();

  /// manifest.format / version（design-v3-details §5.1）。
  static const archiveFormat = 'msgrepo-archive';
  static const archiveVersion = 1;

  /// 未接入 package_info_plus（不为此新增依赖），与 pubspec version 保持一致。
  static const appVersion = '0.2.0+2';

  /// 锚点 marker 语法（design-v3-details §1.1）：id 即 anchors.json 行 id。
  static String anchorMarker(String anchorId) => '⟦task:$anchorId⟧';

  /// 导出全量数据为单个 zip，返回落盘路径与条数。
  ///
  /// [database] / [outputDir] 供测试注入（内存库 + 临时目录）；
  /// 默认走 [AppDatabase] 单例与应用文档目录。
  Future<ArchiveExportResult> exportArchive({
    Database? database,
    Directory? outputDir,
  }) async {
    final db = database ?? await AppDatabase.instance.database;

    // 1. 事务快照读全量表（design-v3-details §5.2-1）。
    final snapshot = await db.transaction((txn) async {
      return (
        tasks: await txn.query('tasks'),
        messages: await txn.query('messages'),
        links: await txn.query('message_task_links',
            orderBy: 'created_at ASC, task_id ASC'),
        notebooks: await txn.query('notebooks'),
        chapters: await txn.query('chapters'),
        notes: await txn.query('notes'),
      );
    });

    // 2. links + linked_task_id → 锚点（仅过渡版本有此步骤，§5.2-2）。
    //    linked_task_id 与 links 表是双写关系（linkMessageTask 两边都写），
    //    同一 (message_id, task_id) 只生成一个锚点，避免重复。
    final taskTitles = {
      for (final r in snapshot.tasks) r['id'] as String: r['title'] as String,
    };
    final messageIds = {for (final r in snapshot.messages) r['id'] as String};
    final anchors = <Map<String, Object?>>[];
    final markersByMessage = <String, List<String>>{};
    final seenPairs = <String>{};

    void addAnchor(String messageId, String taskId, int createdAt) {
      if (!seenPairs.add('$messageId|$taskId')) return;
      final label = taskTitles[taskId];
      if (label == null || !messageIds.contains(messageId)) return;
      final id = const Uuid().v4();
      anchors.add({
        'id': id,
        'task_id': taskId,
        'target_type': 'message',
        'target_id': messageId,
        'label': label,
        'created_by': 'user',
        'created_at': createdAt,
      });
      markersByMessage.putIfAbsent(messageId, () => []).add(anchorMarker(id));
    }

    for (final r in snapshot.links) {
      addAnchor(r['message_id'] as String, r['task_id'] as String,
          (r['created_at'] as num).toInt());
    }
    for (final r in snapshot.messages) {
      final linked = r['linked_task_id'] as String?;
      if (linked != null) {
        addAnchor(r['id'] as String, linked,
            (r['created_at'] as num).toInt());
      }
    }

    // 3. messages.json：正文末尾追加 marker 原文；attachments 列解码为 JSON
    //    数组导出（导入侧直接结构化读取，不必再解一层字符串）。
    final messagesJson = [
      for (final r in snapshot.messages)
        {
          ...r,
          'body': _appendMarkers(
              r['body'] as String, markersByMessage[r['id'] as String]),
          'attachments':
              jsonDecode(r['attachments'] as String) as List<dynamic>,
        },
    ];

    // 4. 笔记三级：notebooks.json + 每篇 notes/<noteId>.md（front matter + 正文）。
    //    过渡版本 notes 表没有 attachments 列，front matter 一律写空数组。
    final archive = Archive();
    const encoder = JsonEncoder.withIndent('  ');

    void addText(String name, String text) {
      final bytes = utf8.encode(text);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    addText('library/notebooks.json', encoder.convert({
      'notebooks': snapshot.notebooks,
      'chapters': snapshot.chapters,
    }));
    for (final r in snapshot.notes) {
      addText('library/notes/${r['id']}.md', _noteMarkdown(r));
    }

    // 5. 附件 → library/files/<fileId>__<safeName>（§5.2-3）：经
    //    attachment_store 解析本地文件复制进 zip，files.json 记录 zip 内相对路径。
    final filesJson = <Map<String, Object?>>[];
    final seenFileIds = <String>{};
    var skippedFiles = 0;
    for (final r in snapshot.messages) {
      final attachments =
          (jsonDecode(r['attachments'] as String) as List<dynamic>)
              .map((e) => Attachment.fromJson(e as Map<String, dynamic>));
      for (final a in attachments) {
        if (!seenFileIds.add(a.id)) continue;
        final file = AttachmentStore.instance.resolve(a);
        if (file == null) {
          skippedFiles++;
          continue;
        }
        final bytes = await file.readAsBytes();
        final name = a.label ?? p.basename(file.path);
        final zipPath = 'library/files/${a.id}__${_safeFileName(name)}';
        archive.addFile(ArchiveFile(zipPath, bytes.length, bytes));
        filesJson.add({
          'id': a.id,
          'name': name,
          'mime_type': a.access.mimeType,
          'size': a.bytes ?? bytes.length,
          'path': zipPath,
          'source': 'message_attachment',
          'created_at': (r['created_at'] as num).toInt(),
        });
      }
    }
    addText('library/files.json', encoder.convert(filesJson));

    addText('tasks.json', encoder.convert(snapshot.tasks));
    addText('messages.json', encoder.convert(messagesJson));
    addText('anchors.json', encoder.convert(anchors));

    // 6. manifest（counts 实测填充，§5.2-4）。
    addText(
        'manifest.json',
        encoder.convert({
          'format': archiveFormat,
          'version': archiveVersion,
          'exportedAt': DateTime.now().millisecondsSinceEpoch,
          'appVersion': appVersion,
          'counts': {
            'tasks': snapshot.tasks.length,
            'messages': snapshot.messages.length,
            'notes': snapshot.notes.length,
            'files': filesJson.length,
            'anchors': anchors.length,
          },
        }));

    // 7. 落盘（过渡版本无分享面板，先写应用文档目录并告知路径）。
    final zipBytes = ZipEncoder().encode(archive);
    final dir = outputDir ?? await getApplicationDocumentsDirectory();
    final out = File(p.join(
        dir.path, 'msgrepo-archive-${_timestamp(DateTime.now())}.zip'));
    await out.writeAsBytes(zipBytes, flush: true);

    return ArchiveExportResult(
      path: out.path,
      tasks: snapshot.tasks.length,
      messages: snapshot.messages.length,
      notes: snapshot.notes.length,
      files: filesJson.length,
      anchors: anchors.length,
      skippedFiles: skippedFiles,
    );
  }

  /// marker 逐个追加到正文末尾（空格分隔），保持与锚点生成顺序一致。
  static String _appendMarkers(String body, List<String>? markers) {
    if (markers == null || markers.isEmpty) return body;
    if (body.isEmpty) return markers.join(' ');
    return '$body ${markers.join(' ')}';
  }

  /// 笔记 .md：YAML front matter（design-v3-details §5.1）+ 正文原文。
  /// content_format='plain' 的笔记同样导出为 .md，front matter 里保留 plain 标记。
  static String _noteMarkdown(Map<String, Object?> r) {
    final b = StringBuffer()
      ..writeln('---')
      ..writeln('id: ${_yamlScalar(r['id'] as String)}')
      ..writeln('title: ${_yamlScalar(r['title'] as String)}')
      ..writeln('chapter_id: ${_yamlScalar(r['chapter_id'] as String)}')
      ..writeln('content_format: ${r['content_format'] as String}')
      ..writeln('created_at: ${(r['created_at'] as num).toInt()}')
      ..writeln('updated_at: ${(r['updated_at'] as num).toInt()}')
      ..writeln('attachments: []')
      ..writeln('---')
      ..write(r['content'] as String);
    return b.toString();
  }

  /// YAML 标量：安全字符串原样输出（贴近规格示例），其余走 JSON 双引号
  /// （JSON 字符串是合法的 YAML flow scalar，导入侧用 YAML 解析器读取一致）。
  static String _yamlScalar(String v) {
    const reserved = {'true', 'false', 'null', 'yes', 'no', 'on', 'off', '~'};
    final safe = v.isNotEmpty &&
        !v.contains(RegExp(r'''[:#\[\]{},&*!|>'"%@`\n\r\t]''')) &&
        !v.startsWith(RegExp(r'[\s\-?]')) &&
        !v.endsWith(' ') &&
        !reserved.contains(v.toLowerCase()) &&
        int.tryParse(v) == null &&
        double.tryParse(v) == null;
    return safe ? v : jsonEncode(v);
  }

  /// files 文件名净化：仅保留 ASCII 字母数字与 . _ - 及 CJK 字符，其余替换为 _。
  static String _safeFileName(String name) {
    var s = name.replaceAll(RegExp(r'[^\w.\-一-鿿]'), '_');
    if (s.length > 60) {
      final ext = p.extension(s);
      s = '${s.substring(0, 60 - ext.length)}$ext';
    }
    return s.isEmpty ? 'file' : s;
  }

  static String _timestamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}

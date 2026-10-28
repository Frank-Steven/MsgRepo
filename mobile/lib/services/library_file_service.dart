import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/library_file.dart';
import '../models/message.dart';
import 'assistant/models.dart';
import 'attachment_store.dart';
import 'database.dart';

/// 文件被引用的统计（删除前检查，design-v3 §1.3）。
class LibraryFileReferences {
  /// attachments 列引用该文件的笔记数。
  final int noteCount;

  /// target_type='file' 指向该文件的任务锚点数。
  final int anchorCount;

  const LibraryFileReferences({this.noteCount = 0, this.anchorCount = 0});

  bool get hasAny => noteCount > 0 || anchorCount > 0;
}

/// 库·文件区的写操作服务（design-v3 §1.3/§3.1）：
/// 导入（落 attachment_store + 写 files 表）、重命名、删除（引用检查）。
class LibraryFileService {
  LibraryFileService._();

  static final LibraryFileService instance = LibraryFileService._();

  static const _uuid = Uuid();

  /// 从磁盘路径导入（file_picker / image_picker 返回的路径）。
  /// 文件本体复制进附件仓库（sha256 去重），元数据入 files 表。
  /// 源文件不可读时返回 null（与 AttachmentStore.importPath 一致）。
  Future<LibraryFile?> importFromPath(
    String path, {
    String? name,
    String? mimeType,
    String source = FileSource.userUpload,
  }) async {
    final att = await AttachmentStore.instance.importPath(
      path,
      kind: Attachment.kindFile,
      label: name,
      mimeType: mimeType,
    );
    if (att == null) return null;
    final file = LibraryFile(
      id: _uuid.v4(),
      name: name ?? att.label ?? p.basename(path),
      mimeType: mimeType ?? att.access.mimeType,
      size: att.bytes,
      localPath: att.access.value,
      source: source,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await AppDatabase.instance.insertFile(file);
    return file;
  }

  /// 从内存字节导入（截图等没有落盘路径的场景）。
  Future<LibraryFile> importBytes(
    Uint8List bytes, {
    required String name,
    String? mimeType,
    String source = FileSource.userUpload,
  }) async {
    final att = await AttachmentStore.instance.importBytes(
      bytes,
      kind: Attachment.kindFile,
      label: name,
      mimeType: mimeType,
      fileName: name,
    );
    final file = LibraryFile(
      id: _uuid.v4(),
      name: name,
      mimeType: mimeType ?? att.access.mimeType,
      size: att.bytes,
      localPath: att.access.value,
      source: source,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await AppDatabase.instance.insertFile(file);
    return file;
  }

  Future<void> rename(String id, String name) =>
      AppDatabase.instance.renameFile(id, name);

  /// 删除前引用检查：笔记 attachments（JSON 数组逐个解析）+ 任务锚点。
  Future<LibraryFileReferences> countReferences(String fileId) async {
    final db = await AppDatabase.instance.database;
    final noteRows = await db.query('notes', columns: ['attachments']);
    var noteCount = 0;
    for (final row in noteRows) {
      final raw = row['attachments'] as String?;
      if (raw == null || raw.isEmpty) continue;
      try {
        final ids = (jsonDecode(raw) as List).map((e) => e.toString());
        if (ids.contains(fileId)) noteCount++;
      } catch (_) {
        // 单行 attachments 损坏不算引用，不阻塞检查
      }
    }
    final anchorRows = await db.rawQuery(
      "SELECT COUNT(*) AS n FROM task_anchors WHERE target_type = ? AND target_id = ?",
      [AnchorTargetType.file, fileId],
    );
    return LibraryFileReferences(
      noteCount: noteCount,
      anchorCount: (anchorRows.first['n'] as num?)?.toInt() ?? 0,
    );
  }

  /// 删除文件：有引用且未 [force] 时返回 false 且不动数据；
  /// 删除 = files 行（锚点行应用层级联，见 AppDatabase.deleteFile）+ 仓库内文件本体。
  Future<bool> delete(String id, {bool force = false}) async {
    final refs = await countReferences(id);
    if (refs.hasAny && !force) return false;
    final file = await AppDatabase.instance.getFileById(id);
    if (file == null) return true;
    await AppDatabase.instance.deleteFile(id);
    await AttachmentStore.instance.deleteQuietly(Attachment(
      id: file.id,
      kind: Attachment.kindFile,
      access: AttachmentAccess(
        type: AttachmentAccess.typeLocalPath,
        value: file.localPath,
        mimeType: file.mimeType,
      ),
    ));
    return true;
  }
}

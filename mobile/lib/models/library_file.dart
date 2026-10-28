/// v3 库·文件区模型（design-v3 §1.3 files 表）。
///
/// 文件本体由 attachment_store 管理（沙盒路径），本表只存元数据；
/// 笔记 attachments、任务锚点（target_type='file'）、助理附件都引用这里的 id。
class FileSource {
  static const userUpload = 'user_upload';
  static const aiGenerated = 'ai_generated';
  static const noteExport = 'note_export';
}

class LibraryFile {
  final String id;
  final String name;
  final String? mimeType;

  /// 文件大小（字节）；未知为 null。
  final int? size;

  /// attachment_store 管理的沙盒路径。
  final String localPath;
  final String source;
  final int createdAt;

  const LibraryFile({
    required this.id,
    required this.name,
    this.mimeType,
    this.size,
    required this.localPath,
    required this.source,
    required this.createdAt,
  });

  factory LibraryFile.fromRow(Map<String, Object?> row) => LibraryFile(
        id: row['id'] as String,
        name: row['name'] as String,
        mimeType: row['mime_type'] as String?,
        size: (row['size'] as num?)?.toInt(),
        localPath: row['local_path'] as String,
        source: row['source'] as String,
        createdAt: (row['created_at'] as num).toInt(),
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'mime_type': mimeType,
        'size': size,
        'local_path': localPath,
        'source': source,
        'created_at': createdAt,
      };

  LibraryFile copyWith({
    String? id,
    String? name,
    String? Function()? mimeType,
    int? Function()? size,
    String? localPath,
    String? source,
    int? createdAt,
  }) =>
      LibraryFile(
        id: id ?? this.id,
        name: name ?? this.name,
        mimeType: mimeType != null ? mimeType() : this.mimeType,
        size: size != null ? size() : this.size,
        localPath: localPath ?? this.localPath,
        source: source ?? this.source,
        createdAt: createdAt ?? this.createdAt,
      );
}

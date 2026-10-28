import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/library_file.dart';
import '../../services/database.dart';
import '../../services/library_file_service.dart';
import '../../services/notification_bridge.dart';
import '../../services/system_intent.dart';
import '../notes/notes_page.dart' show promptNameDialog;

/// v3 阶段 3 库·文件区（design-v3 §1.3/§3.1）：
/// 文件列表（名称/大小/类型/时间）、导入（任意文件 / 图片）、重命名、
/// 删除（引用检查：笔记 attachments + 任务锚点）、系统打开/导出。
///
/// 打开/分享不新增 share_plus 等依赖：「打开」复用桥接的 ACTION_VIEW
/// （file:// 在新系统上多半不可用，失败时退化为展示路径），
/// 「导出到下载目录」走 SystemIntent.exportToDownloads（MediaStore）。
class FilesPage extends StatefulWidget {
  const FilesPage({super.key});

  @override
  State<FilesPage> createState() => FilesPageState();
}

class FilesPageState extends State<FilesPage> {
  List<LibraryFile> _files = [];
  bool _loading = true;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final files = await AppDatabase.instance.getFiles();
    if (mounted) {
      setState(() {
        _files = files;
        _loading = false;
      });
    }
  }

  // ---- 导入 ----

  Future<void> _importFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return; // 用户取消
    final paths = [for (final f in result.files) f.path].nonNulls.toList();
    if (paths.isEmpty) {
      _toast('所选文件没有可读路径，无法导入');
      return;
    }
    await _runImport(paths.length, () async {
      var ok = 0;
      for (final path in paths) {
        final imported = await LibraryFileService.instance.importFromPath(path);
        if (imported != null) ok++;
      }
      return ok;
    });
  }

  Future<void> _importImage() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x == null) return; // 用户取消
    await _runImport(1, () async {
      final imported = await LibraryFileService.instance
          .importFromPath(x.path, name: x.name, mimeType: x.mimeType);
      return imported == null ? 0 : 1;
    });
  }

  Future<void> _runImport(int total, Future<int> Function() run) async {
    setState(() => _importing = true);
    try {
      final ok = await run();
      await reload();
      _toast(ok == total ? '已导入 $ok 个文件' : '导入 $ok/$total 个文件，其余读取失败');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  // ---- 重命名 / 删除 ----

  Future<void> _rename(LibraryFile file) async {
    final name = await promptNameDialog(context,
        title: '重命名文件', initialValue: file.name);
    if (name == null || name == file.name) return;
    await LibraryFileService.instance.rename(file.id, name);
    await reload();
  }

  Future<void> _delete(LibraryFile file) async {
    final refs = await LibraryFileService.instance.countReferences(file.id);
    if (!mounted) return;
    if (refs.hasAny) {
      final parts = <String>[
        if (refs.noteCount > 0) '${refs.noteCount} 篇笔记的附件',
        if (refs.anchorCount > 0) '${refs.anchorCount} 个任务锚点',
      ];
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('文件仍被引用'),
          content: Text('「${file.name}」正被 ${parts.join('、')} 引用。\n'
              '删除后这些引用会失效（笔记附件丢失、锚点移除）。仍要删除吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('仍要删除'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await LibraryFileService.instance.delete(file.id, force: true);
    await reload();
  }

  // ---- 打开 / 导出 ----

  Future<void> _open(LibraryFile file) async {
    final ok = await NotificationBridge.instance
        .openDeeplink('file://${file.localPath}');
    if (!ok && mounted) {
      // file:// 在 Android 7+ 基本被系统拒（无 FileProvider），退化为展示路径，
      // 引导用户用「导出到下载目录」后经系统文件管理器打开/分享。
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('无法直接打开'),
          content: Text('系统没有可处理该文件的应用。\n\n'
              '可改用「导出到下载目录」后在文件管理器中打开或分享。\n\n'
              '存储位置：\n${file.localPath}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _export(LibraryFile file) async {
    try {
      final where = await SystemIntent.exportToDownloads(file.localPath,
          name: file.name, mime: SystemIntent.mimeOf(file.name));
      if (mounted) _toast('已导出到 $where');
    } catch (e) {
      if (mounted) _toast('导出失败：$e');
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _showActions(LibraryFile file) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('打开'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _open(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('导出到下载目录'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _export(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _rename(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _delete(file);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---- UI ----

  static String _formatSize(int? bytes) {
    if (bytes == null) return '大小未知';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  static String _formatTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  IconData _iconFor(LibraryFile file) {
    final mime = file.mimeType ?? '';
    if (mime.startsWith('image/')) return Icons.image_outlined;
    if (mime.startsWith('video/')) return Icons.videocam_outlined;
    if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (mime.startsWith('text/') || mime == 'application/json') {
      return Icons.article_outlined;
    }
    if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('文件'),
        actions: [
          if (_importing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else
            PopupMenuButton<String>(
              tooltip: '导入',
              icon: const Icon(Icons.add),
              onSelected: (action) => switch (action) {
                'files' => _importFiles(),
                _ => _importImage(),
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'files', child: Text('导入文件')),
                PopupMenuItem(value: 'image', child: Text('导入图片/截图')),
              ],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
              ? Center(
                  child: Text('暂无文件，点右上角 + 导入',
                      style: TextStyle(color: cs.onSurfaceVariant)),
                )
              : RefreshIndicator(
                  onRefresh: reload,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: _files.length,
                    itemBuilder: (context, index) {
                      final file = _files[index];
                      return ListTile(
                        leading: Icon(_iconFor(file)),
                        title: Text(file.name, maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                            '${_formatSize(file.size)} · ${_formatTime(file.createdAt)}'),
                        trailing: const Icon(Icons.more_vert),
                        onTap: () => _showActions(file),
                      );
                    },
                  ),
                ),
    );
  }
}

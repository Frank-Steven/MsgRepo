import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../models/note.dart';
import '../../services/database.dart';

/// 笔记编辑器（设计 §4）：标题 + 正文，纯文本，退出自动保存，无保存按钮。
///
/// - [existing] 非空 = 编辑已有笔记；否则按 [chapterId] 新建。
/// - 标题留空时取正文首个非空行的前 20 字作标题；标题、正文均为空则不保存。
/// - pop 返回值：新建且实际入库时为新建的 [Note]，其余情况为 null
///   （由调用方负责撤销注册）。
class NoteEditorPage extends StatefulWidget {
  final Note? existing;
  final String? chapterId;

  const NoteEditorPage({super.key, this.existing, this.chapterId});

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  late final TextEditingController _titleController;
  late final TextEditingController _contentController;

  bool _allowPop = false;
  bool _exiting = false;
  Future<void>? _saveFuture;
  Note? _inserted;

  @override
  void initState() {
    super.initState();
    _titleController =
        TextEditingController(text: widget.existing?.title ?? '');
    _contentController =
        TextEditingController(text: widget.existing?.content ?? '');
  }

  @override
  void dispose() {
    // 兜底：路由被外部移除时也保存（正常退出已在 PopScope 保存过，幂等）。
    // _doSave 在首个 await 前同步读完控制器，先于下面的 dispose。
    _save();
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  /// 保存一次，重复调用返回同一 Future。
  Future<void> _save() => _saveFuture ??= _doSave();

  Future<void> _doSave() async {
    final content = _contentController.text;
    var title = _titleController.text.trim();
    if (title.isEmpty) {
      for (final line in content.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) {
          title =
              trimmed.length <= 20 ? trimmed : trimmed.substring(0, 20);
          break;
        }
      }
    }
    if (title.isEmpty) return;

    final existing = widget.existing;
    if (existing != null) {
      if (existing.title == title && existing.content == content) return;
      await AppDatabase.instance
          .updateNote(existing.copyWith(title: title, content: content));
    } else {
      final now = DateTime.now().millisecondsSinceEpoch;
      final note = Note(
        id: const Uuid().v4(),
        chapterId: widget.chapterId!,
        title: title,
        content: content,
        createdAt: now,
        updatedAt: now,
      );
      await AppDatabase.instance.insertNote(note);
      _inserted = note;
    }
  }

  Future<void> _onPopInvoked(bool didPop) async {
    if (didPop || _exiting) return;
    _exiting = true;
    await _save();
    if (!mounted) return;
    setState(() => _allowPop = true);
    // 等 PopScope 以 canPop=true 重建后再退出，否则这次 pop 仍会被拦截
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(_inserted);
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) => _onPopInvoked(didPop),
      child: Scaffold(
        appBar: AppBar(
          title: TextField(
            controller: _titleController,
            style: Theme.of(context).textTheme.titleLarge,
            decoration: const InputDecoration(
              hintText: '标题',
              border: InputBorder.none,
            ),
            textInputAction: TextInputAction.next,
          ),
        ),
        body: TextField(
          controller: _contentController,
          expands: true,
          maxLines: null,
          minLines: null,
          keyboardType: TextInputType.multiline,
          textAlignVertical: TextAlignVertical.top,
          decoration: const InputDecoration(
            hintText: '正文',
            border: InputBorder.none,
            contentPadding: EdgeInsets.all(16),
          ),
        ),
      ),
    );
  }
}

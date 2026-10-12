import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../models.dart';
import '../../models/note.dart';
import '../../services/database.dart';
import 'note_editor_page.dart';
import 'notes_page.dart';

/// 笔记模块第二层：章节列表。长按拖动排序；行尾菜单重命名/删除（级联 + 复合撤销）。
class ChaptersPage extends StatefulWidget {
  final Notebook notebook;

  const ChaptersPage({super.key, required this.notebook});

  @override
  State<ChaptersPage> createState() => _ChaptersPageState();
}

class _ChaptersPageState extends State<ChaptersPage> {
  List<Chapter> _chapters = [];
  Map<String, int> _noteCounts = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final db = AppDatabase.instance;
    final chapters = await db.getChapters(widget.notebook.id);
    final rawDb = await db.database;
    final countRows = await rawDb.rawQuery(
        'SELECT chapter_id, COUNT(*) AS c FROM notes GROUP BY chapter_id');
    if (mounted) {
      setState(() {
        _chapters = chapters;
        _noteCounts = {
          for (final r in countRows)
            r['chapter_id'] as String: (r['c'] as num).toInt(),
        };
      });
    }
  }

  Future<void> _openNotes(Chapter chapter) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NotesListPage(chapter: chapter)),
    );
    await _reload();
  }

  Future<void> _addChapter() async {
    final name = await promptNameDialog(context, title: '新建章节');
    if (name == null) return;
    final chapter = Chapter(
      id: const Uuid().v4(),
      notebookId: widget.notebook.id,
      name: name,
      sort: _chapters.isEmpty ? 0 : _chapters.last.sort + 1,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await AppDatabase.instance.insertChapter(chapter);
    await _reload();
    if (!mounted) return;
    showUndoSnackBar(context, '已新建章节「$name」', () async {
      await AppDatabase.instance.deleteChapter(chapter.id);
      if (mounted) await _reload();
    });
  }

  Future<void> _renameChapter(Chapter chapter) async {
    final name = await promptNameDialog(context,
        title: '重命名章节', initialValue: chapter.name);
    if (name == null || name == chapter.name) return;
    await AppDatabase.instance.renameChapter(chapter.id, name);
    await _reload();
  }

  Future<void> _deleteChapter(Chapter chapter) async {
    final notes = await AppDatabase.instance.getNotes(chapter.id);
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除章节'),
        content:
            Text('删除「${chapter.name}」将同时删除其中 ${notes.length} 条笔记。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await AppDatabase.instance.deleteChapter(chapter.id);
    await _reload();
    if (!mounted) return;
    showUndoSnackBar(context, '已删除章节「${chapter.name}」', () async {
      final db = AppDatabase.instance;
      await db.insertChapter(chapter);
      for (final note in notes) {
        await db.insertNote(note);
      }
      if (mounted) await _reload();
    });
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    setState(() {
      final moved = _chapters.removeAt(oldIndex);
      _chapters.insert(newIndex, moved);
    });
    final rawDb = await AppDatabase.instance.database;
    final batch = rawDb.batch();
    for (var i = 0; i < _chapters.length; i++) {
      batch.update('chapters', {'sort': i},
          where: 'id = ?', whereArgs: [_chapters[i].id]);
    }
    await batch.commit(noResult: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.notebook.name),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: _addChapter),
        ],
      ),
      body: _chapters.isEmpty
          ? const Center(child: Text('暂无章节，点右上角 + 新建'))
          : ReorderableListView.builder(
              itemCount: _chapters.length,
              onReorderItem: _onReorder,
              itemBuilder: (context, index) {
                final chapter = _chapters[index];
                return ListTile(
                  key: ValueKey(chapter.id),
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(chapter.name),
                  subtitle: Text('${_noteCounts[chapter.id] ?? 0} 条笔记'),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) => switch (action) {
                      'rename' => _renameChapter(chapter),
                      _ => _deleteChapter(chapter),
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('重命名')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                  onTap: () => _openNotes(chapter),
                );
              },
            ),
    );
  }
}

/// 笔记模块第三层：章节内笔记列表（updated_at 倒序）。
class NotesListPage extends StatefulWidget {
  final Chapter chapter;

  const NotesListPage({super.key, required this.chapter});

  @override
  State<NotesListPage> createState() => _NotesListPageState();
}

class _NotesListPageState extends State<NotesListPage> {
  List<Note> _notes = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final notes = await AppDatabase.instance.getNotes(widget.chapter.id);
    if (mounted) setState(() => _notes = notes);
  }

  Future<void> _addNote() async {
    // 编辑器退出自动保存；返回非空 Note 表示新建入库
    final created = await Navigator.of(context).push<Note>(
      MaterialPageRoute(
          builder: (_) => NoteEditorPage(chapterId: widget.chapter.id)),
    );
    await _reload();
    if (created == null || !mounted) return;
    showUndoSnackBar(context, '已新建笔记「${created.title}」', () async {
      await AppDatabase.instance.deleteNote(created.id);
      if (mounted) await _reload();
    });
  }

  Future<void> _openNote(Note note) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteEditorPage(existing: note)),
    );
    await _reload();
  }

  Future<void> _deleteNote(Note note) async {
    await AppDatabase.instance.deleteNote(note.id);
    await _reload();
    if (!mounted) return;
    showUndoSnackBar(context, '已删除笔记「${note.title}」', () async {
      await AppDatabase.instance.insertNote(note);
      if (mounted) await _reload();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.chapter.name),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: _addNote),
        ],
      ),
      body: _notes.isEmpty
          ? const Center(child: Text('暂无笔记，点右上角 + 新建'))
          : ListView.builder(
              itemCount: _notes.length,
              itemBuilder: (context, index) {
                final note = _notes[index];
                final firstLine = note.content
                    .split('\n')
                    .map((l) => l.trim())
                    .firstWhere((l) => l.isNotEmpty, orElse: () => '');
                return ListTile(
                  title: Text(note.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (firstLine.isNotEmpty)
                        Text(firstLine,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(formatMillis(note.updatedAt),
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (_) => _deleteNote(note),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                  onTap: () => _openNote(note),
                );
              },
            ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../services/assistant/models.dart';
import '../../services/database.dart';

/// 附件选择器（design-v3 §5.1）：从库中多选笔记/消息/文件，
/// 返回附件引用列表（正文在请求时由 assistant_service 展开）。
class AttachmentPickerPage extends StatefulWidget {
  final List<ChatAttachment> selected;

  const AttachmentPickerPage({super.key, this.selected = const []});

  @override
  State<AttachmentPickerPage> createState() => _AttachmentPickerPageState();
}

class _PickerItem {
  final ChatAttachment ref;
  final String title;
  final String subtitle;
  const _PickerItem(this.ref, this.title, this.subtitle);
}

class _AttachmentPickerPageState extends State<AttachmentPickerPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  late final Map<String, ChatAttachment> _selected = {
    for (final a in widget.selected) '${a.type}:${a.id}': a,
  };

  List<_PickerItem> _notes = [];
  List<_PickerItem> _messages = [];
  List<_PickerItem> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = AppDatabase.instance;
    final notes = <_PickerItem>[];
    for (final nb in await db.getNotebooks()) {
      for (final ch in await db.getChapters(nb.id)) {
        for (final n in await db.getNotes(ch.id)) {
          notes.add(_PickerItem(
            ChatAttachment(type: ChatAttachmentType.note, id: n.id),
            n.title,
            '${nb.name} / ${ch.name}',
          ));
        }
      }
    }
    final messages = [
      for (final m in await db.getMessages(limit: 200))
        _PickerItem(
          ChatAttachment(type: ChatAttachmentType.message, id: m.id),
          m.title,
          m.appName ?? m.packageName,
        ),
    ];
    final files = [
      for (final f in await db.getFiles())
        _PickerItem(
          ChatAttachment(type: ChatAttachmentType.file, id: f.id),
          f.name,
          f.mimeType ?? '',
        ),
    ];
    if (mounted) {
      setState(() {
        _notes = notes;
        _messages = messages;
        _files = files;
        _loading = false;
      });
    }
  }

  Widget _buildList(List<_PickerItem> items, String emptyHint) {
    if (items.isEmpty) {
      return Center(child: Text(emptyHint));
    }
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (_, i) {
        final item = items[i];
        final key = '${item.ref.type}:${item.ref.id}';
        return CheckboxListTile(
          value: _selected.containsKey(key),
          onChanged: (v) => setState(() => v == true
              ? _selected[key] = item.ref
              : _selected.remove(key)),
          title:
              Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(item.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('选择附件（已选 ${_selected.length}）'),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_selected.values.toList()),
            child: const Text('完成'),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          tabs: const [Tab(text: '笔记'), Tab(text: '消息'), Tab(text: '文件')],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tab,
              children: [
                _buildList(_notes, '库里还没有笔记'),
                _buildList(_messages, '库里还没有消息'),
                _buildList(_files, '库里还没有文件'),
              ],
            ),
    );
  }
}

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/database.dart';
import '../services/notification_bridge.dart';
import '../services/registry_service.dart';
import '../services/reminder_service.dart';
import 'items_page.dart' show priorityColor, confidenceThreshold;

class ItemDetailPage extends StatefulWidget {
  final StructuredItem item;

  const ItemDetailPage({super.key, required this.item});

  @override
  State<ItemDetailPage> createState() => _ItemDetailPageState();
}

class _ItemDetailPageState extends State<ItemDetailPage> {
  late StructuredItem _item = widget.item;
  List<RawMessage> _sources = [];
  CategoryRegistry? _registry;

  StructuredItem get item => _item;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sources =
        await AppDatabase.instance.getRawMessagesByIds(item.rawMessageIds);
    final registry = await RegistryService.instance.load();
    if (mounted) {
      setState(() {
        _sources = sources;
        _registry = registry;
      });
    }
  }

  /// 编辑提醒时间：更新数据库，先取消旧调度再按新 time 重新调度。
  Future<void> _editReminder() async {
    final updated = await showDialog<ItemTime>(
      context: context,
      builder: (_) => _ReminderEditDialog(initial: item.time),
    );
    if (updated == null) return;
    await ReminderService.instance.cancelForItem(item);
    final newItem = item.copyWith(time: updated);
    await AppDatabase.instance.updateStructuredItem(newItem);
    await ReminderService.instance.scheduleForItem(newItem);
    if (mounted) {
      setState(() => _item = newItem);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content: Text('提醒已更新'), duration: Duration(seconds: 2)));
    }
  }

  /// 撤销处理：删除条目、关联消息回退 pending + needs_reprocess、取消提醒。
  Future<void> _revertItem() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('撤销处理'),
        content: const Text('将删除该结构化结果，关联消息回退为待处理，下次同步时强制重新处理。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('撤销'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ReminderService.instance.cancelForItem(item);
    await AppDatabase.instance.revertStructuredItem(item);
    if (mounted) Navigator.of(context).pop();
  }

  /// todo 勾选联动：payload.status 切换 + 关联消息 归档/恢复。
  Future<void> _toggleTodo(bool done) async {
    final updated = await AppDatabase.instance.setTodoDone(item, done);
    if (mounted) setState(() => _item = updated);
  }

  @override
  Widget build(BuildContext context) {
    final color = priorityColor(item.priority);
    return Scaffold(
      appBar: AppBar(
        title: Text(_registry?.displayNameOf(item.category) ?? item.category),
        actions: [
          IconButton(
            tooltip: '撤销处理',
            icon: const Icon(Icons.undo),
            onPressed: _revertItem,
          ),
          IconButton(
            tooltip: '编辑提醒',
            icon: const Icon(Icons.edit_notifications_outlined),
            onPressed: _editReminder,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Chip(
                label: Text(item.priority),
                backgroundColor: color.withOpacity(0.15),
                side: BorderSide.none,
              ),
              const SizedBox(width: 8),
              Chip(
                label: Text(itemKindLabel(item, _registry),
                    style: const TextStyle(fontSize: 12)),
                side: BorderSide.none,
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 8),
              Text('置信度 ${(item.confidence * 100).toStringAsFixed(0)}%'),
              if (item.confidence < confidenceThreshold) ...[
                const SizedBox(width: 8),
                const Chip(
                  label: Text('待确认', style: TextStyle(fontSize: 12)),
                  backgroundColor: Color(0x1FFF9800),
                  side: BorderSide.none,
                ),
              ],
            ],
          ),
          if (item.category == 'todo')
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: item.payload['status'] == 'done',
              onChanged: (v) => _toggleTodo(v ?? false),
              title: const Text('已完成'),
              subtitle: const Text('勾选后关联消息自动归档'),
            ),
          const SizedBox(height: 8),
          Text(item.title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(item.summary),
          if (item.tags.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: [
                for (final tag in item.tags)
                  Chip(
                    label: Text(tag, style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
          const Divider(height: 32),
          _sectionTitle(context, '时间'),
          _buildTimeSection(),
          const Divider(height: 32),
          _sectionTitle(context, '详情'),
          _buildPayloadSection(),
          const Divider(height: 32),
          _sectionTitle(context, '来源消息'),
          if (_sources.isEmpty)
            const Text('（来源消息不在本地或已被清理）',
                style: TextStyle(color: Colors.grey)),
          for (final m in _sources) ...[
            _buildSourceMessage(context, m),
            const SizedBox(height: 12),
          ],
          const Divider(height: 32),
          Text(
            '由 ${item.processedBy.provider}'
            '${item.processedBy.model != null ? ' / ${item.processedBy.model}' : ''}'
            ' 处理 · 管线 ${item.processedBy.pipelineVersion}'
            ' · 信封 v${item.schemaVersion}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _buildTimeSection() {
    final t = item.time;
    switch (t.kind) {
      case ItemTime.kindNone:
        return const Text('无时间信息');
      case ItemTime.kindPoint:
        return Text('时间：${t.startAt != null ? formatMillis(t.startAt!) : '-'}');
      case ItemTime.kindRange:
        return Text(
            '开始：${t.startAt != null ? formatMillis(t.startAt!) : '-'}\n'
            '结束：${t.endAt != null ? formatMillis(t.endAt!) : '-'}');
      case ItemTime.kindDeadline:
        return Text(
            '截止：${t.deadline != null ? formatMillis(t.deadline!) : '-'}');
      case ItemTime.kindRecurring:
        return Text('周期重复（暂不支持本地提醒调度）\n规则：${t.rrule ?? '-'}');
      default:
        return Text('未知时间类型：${t.kind}');
    }
  }

  Widget _buildPayloadSection() {
    final payload = item.payload;
    if (payload.isEmpty) return const Text('（无）');

    final rows = <Widget>[];
    final fields = payload['fields'];
    if (fields is List) {
      // generic 分类的通用 fields 结构
      for (final f in fields) {
        if (f is Map) {
          rows.add(_kvRow('${f['key'] ?? ''}', _stringify(f['value'])));
        }
      }
    }
    for (final entry in payload.entries) {
      if (entry.key == 'fields') continue;
      rows.add(_kvRow(entry.key, _stringify(entry.value)));
    }
    if (rows.isEmpty) return const Text('（无）');
    return Column(children: rows);
  }

  String _stringify(dynamic value) {
    if (value == null) return '-';
    if (value is List) return value.map(_stringify).join('、');
    return value.toString();
  }

  Widget _kvRow(String key, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 88,
              child: Text(key,
                  style: const TextStyle(color: Colors.grey)),
            ),
            Expanded(child: Text(value)),
          ],
        ),
      );

  Widget _buildSourceMessage(BuildContext context, RawMessage m) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${m.source.appName ?? m.source.packageName}'
              ' · ${formatMillis(m.postedAt)}'
              '${m.captureType == RawMessage.captureManual ? ' · 手动添加' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (m.title.isNotEmpty)
              Text(m.title,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            if (m.body.isNotEmpty) Text(m.body),
            if (m.attachments.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final a in m.attachments) _buildAttachment(context, a),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAttachment(BuildContext context, Attachment a) {
    final icon = switch (a.kind) {
      Attachment.kindImage => Icons.image_outlined,
      Attachment.kindFile => Icons.insert_drive_file_outlined,
      Attachment.kindLink => Icons.link,
      Attachment.kindMiniprogram => Icons.apps_outlined,
      _ => Icons.attachment,
    };
    final openable = a.access.type == AttachmentAccess.typeUrl ||
        a.access.type == AttachmentAccess.typeAppDeeplink ||
        a.access.type == AttachmentAccess.typeContentUri;
    return Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '${a.label ?? a.kind}（${a.access.type}）\n${a.access.value}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (openable)
          TextButton(
            onPressed: () async {
              final ok =
                  await NotificationBridge.instance.openDeeplink(a.access.value);
              if (!ok && context.mounted) {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(const SnackBar(
                      content: Text('无法打开该附件'),
                      duration: Duration(seconds: 2)));
              }
            },
            child: const Text('打开'),
          ),
      ],
    );
  }
}

/// 编辑提醒对话框：时间类型（无/时刻/截止/区间）+ 日期时间选择 + 提醒提前量。
/// 保存后返回新的 ItemTime，由详情页负责写库与重新调度。
class _ReminderEditDialog extends StatefulWidget {
  final ItemTime initial;

  const _ReminderEditDialog({required this.initial});

  @override
  State<_ReminderEditDialog> createState() => _ReminderEditDialogState();
}

class _ReminderEditDialogState extends State<_ReminderEditDialog> {
  static const _presetOffsets = {10: '10分钟', 30: '30分钟', 120: '2小时', 1440: '1天'};

  static const _kinds = {
    ItemTime.kindNone: '无',
    ItemTime.kindPoint: '时刻',
    ItemTime.kindDeadline: '截止',
    ItemTime.kindRange: '区间',
  };

  late String _kind = _kinds.containsKey(widget.initial.kind)
      ? widget.initial.kind
      : ItemTime.kindNone;
  DateTime? _start;
  DateTime? _end;
  DateTime? _deadline;
  late final Set<int> _offsets = widget.initial.reminderOffsets.toSet();
  final _customOffsetController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final t = widget.initial;
    if (t.startAt != null) {
      _start = DateTime.fromMillisecondsSinceEpoch(t.startAt!);
    }
    if (t.endAt != null) {
      _end = DateTime.fromMillisecondsSinceEpoch(t.endAt!);
    }
    if (t.deadline != null) {
      _deadline = DateTime.fromMillisecondsSinceEpoch(t.deadline!);
    }
  }

  @override
  void dispose() {
    _customOffsetController.dispose();
    super.dispose();
  }

  Future<DateTime?> _pickDateTime(DateTime? current) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current ?? now),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  String _fmt(DateTime? d) =>
      d == null ? '点击选择' : formatMillis(d.millisecondsSinceEpoch);

  void _addCustomOffset() {
    final minutes = int.tryParse(_customOffsetController.text.trim());
    if (minutes == null || minutes < 0) return;
    setState(() {
      _offsets.add(minutes);
      _customOffsetController.clear();
    });
  }

  void _save() {
    final offsets = _offsets.toList()..sort();
    switch (_kind) {
      case ItemTime.kindNone:
        Navigator.of(context)
            .pop(const ItemTime(kind: ItemTime.kindNone));
      case ItemTime.kindPoint:
        if (_start == null) return _warn('请选择时间');
        Navigator.of(context).pop(ItemTime(
          kind: ItemTime.kindPoint,
          startAt: _start!.millisecondsSinceEpoch,
          reminderOffsets: offsets,
        ));
      case ItemTime.kindDeadline:
        if (_deadline == null) return _warn('请选择截止时间');
        Navigator.of(context).pop(ItemTime(
          kind: ItemTime.kindDeadline,
          deadline: _deadline!.millisecondsSinceEpoch,
          reminderOffsets: offsets,
        ));
      case ItemTime.kindRange:
        if (_start == null || _end == null) return _warn('请选择开始和结束时间');
        if (!_end!.isAfter(_start!)) return _warn('结束时间需晚于开始时间');
        Navigator.of(context).pop(ItemTime(
          kind: ItemTime.kindRange,
          startAt: _start!.millisecondsSinceEpoch,
          endAt: _end!.millisecondsSinceEpoch,
          reminderOffsets: offsets,
        ));
    }
  }

  void _warn(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(text), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑提醒'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _kind,
              decoration: const InputDecoration(
                  labelText: '时间类型', border: OutlineInputBorder()),
              items: [
                for (final entry in _kinds.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (v) => setState(() => _kind = v!),
            ),
            const SizedBox(height: 12),
            if (_kind == ItemTime.kindPoint)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('时间'),
                subtitle: Text(_fmt(_start)),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: () async {
                  final d = await _pickDateTime(_start);
                  if (d != null) setState(() => _start = d);
                },
              ),
            if (_kind == ItemTime.kindDeadline)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('截止时间'),
                subtitle: Text(_fmt(_deadline)),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: () async {
                  final d = await _pickDateTime(_deadline);
                  if (d != null) setState(() => _deadline = d);
                },
              ),
            if (_kind == ItemTime.kindRange) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('开始时间'),
                subtitle: Text(_fmt(_start)),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: () async {
                  final d = await _pickDateTime(_start);
                  if (d != null) setState(() => _start = d);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('结束时间'),
                subtitle: Text(_fmt(_end)),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: () async {
                  final d = await _pickDateTime(_end);
                  if (d != null) setState(() => _end = d);
                },
              ),
            ],
            if (_kind != ItemTime.kindNone) ...[
              const SizedBox(height: 8),
              Text('提醒提前量', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in _presetOffsets.entries)
                    FilterChip(
                      label: Text(entry.value),
                      selected: _offsets.contains(entry.key),
                      onSelected: (v) => setState(() => v
                          ? _offsets.add(entry.key)
                          : _offsets.remove(entry.key)),
                    ),
                  for (final o in _offsets.where((e) => !_presetOffsets.containsKey(e)))
                    InputChip(
                      label: Text('$o分钟'),
                      onDeleted: () => setState(() => _offsets.remove(o)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _customOffsetController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '自定义（分钟）',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                      onPressed: _addCustomOffset, child: const Text('添加')),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

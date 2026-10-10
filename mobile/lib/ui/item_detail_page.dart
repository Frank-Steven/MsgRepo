import 'package:flutter/material.dart';

import '../models.dart';
import '../services/database.dart';
import '../services/notification_bridge.dart';
import '../services/registry_service.dart';
import 'items_page.dart' show priorityColor, confidenceThreshold;

class ItemDetailPage extends StatefulWidget {
  final StructuredItem item;

  const ItemDetailPage({super.key, required this.item});

  @override
  State<ItemDetailPage> createState() => _ItemDetailPageState();
}

class _ItemDetailPageState extends State<ItemDetailPage> {
  List<RawMessage> _sources = [];
  CategoryRegistry? _registry;

  StructuredItem get item => widget.item;

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

  @override
  Widget build(BuildContext context) {
    final color = priorityColor(item.priority);
    return Scaffold(
      appBar: AppBar(title: Text(_registry?.displayNameOf(item.category) ?? item.category)),
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
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('无法打开该附件')));
              }
            },
            child: const Text('打开'),
          ),
      ],
    );
  }
}

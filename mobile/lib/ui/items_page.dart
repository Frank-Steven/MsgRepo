import 'package:flutter/material.dart';

import '../models.dart';
import '../services/database.dart';
import '../services/registry_service.dart';
import 'item_detail_page.dart';

const confidenceThreshold = 0.6;

Color priorityColor(String priority) => switch (priority) {
      'P0' => Colors.red,
      'P1' => Colors.orange,
      'P2' => Colors.blue,
      _ => Colors.grey,
    };

class ItemsPage extends StatefulWidget {
  const ItemsPage({super.key});

  @override
  State<ItemsPage> createState() => _ItemsPageState();
}

class _ItemsPageState extends State<ItemsPage> {
  List<StructuredItem> _items = [];
  CategoryRegistry? _registry;
  String _categoryFilter = 'all';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final items = await AppDatabase.instance.getStructuredItems();
    final registry = await RegistryService.instance.load();
    if (mounted) {
      setState(() {
        _items = items;
        _registry = registry;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = _items.map((e) => e.category).toSet().toList();
    final visible = _categoryFilter == 'all'
        ? _items
        : _items.where((e) => e.category == _categoryFilter).toList();

    // 按分类分组展示
    final grouped = <String, List<StructuredItem>>{};
    for (final item in visible) {
      grouped.putIfAbsent(item.category, () => []).add(item);
    }
    final groupKeys = grouped.keys.toList()
      ..sort((a, b) =>
          (_registry?.displayNameOf(a) ?? a)
              .compareTo(_registry?.displayNameOf(b) ?? b));

    return Scaffold(
      appBar: AppBar(title: const Text('结构化结果')),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: const Text('全部'),
                    selected: _categoryFilter == 'all',
                    onSelected: (_) =>
                        setState(() => _categoryFilter = 'all'),
                  ),
                ),
                for (final key in categories)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(_registry?.displayNameOf(key) ?? key),
                      selected: _categoryFilter == key,
                      onSelected: (_) =>
                          setState(() => _categoryFilter = key),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reload,
              child: visible.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(height: 120),
                        Center(child: Text('暂无结构化结果，请先在收件箱同步')),
                      ],
                    )
                  : ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        for (final key in groupKeys) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                            child: Text(
                              _registry?.displayNameOf(key) ?? key,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary),
                            ),
                          ),
                          for (final item in grouped[key]!)
                            _ItemTile(item: item),
                        ],
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  final StructuredItem item;

  const _ItemTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final color = priorityColor(item.priority);
    final lowConfidence = item.confidence < confidenceThreshold;
    final base = item.time.baseTime;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: Container(
          width: 4,
          height: 40,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(item.priority,
                  style: TextStyle(fontSize: 11, color: color)),
            ),
            Expanded(
              child: Text(item.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.summary, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (base != null)
              Text(formatMillis(base),
                  style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        trailing: lowConfidence
            ? const Tooltip(
                message: 'AI 置信度较低',
                child: Chip(
                  label: Text('待确认', style: TextStyle(fontSize: 11)),
                  backgroundColor: Color(0x1FFF9800),
                  side: BorderSide.none,
                  visualDensity: VisualDensity.compact,
                ),
              )
            : null,
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ItemDetailPage(item: item)),
          );
        },
      ),
    );
  }
}

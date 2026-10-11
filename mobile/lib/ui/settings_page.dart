import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_filter_service.dart';
import '../services/notification_bridge.dart';
import '../services/registry_service.dart';
import '../services/sync_client.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _tokenController = TextEditingController();
  final _baseUrlController = TextEditingController();

  String _deviceId = '';
  String _localRegistryVersion = '-';
  String? _desktopRegistryVersion;
  bool _listenerEnabled = false;
  bool _testing = false;
  bool? _healthOk;
  AppFilterConfig _filterConfig = const AppFilterConfig();
  Map<String, String?> _knownAppNames = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _baseUrlController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final sync = SyncClient.instance;
    final registry = await RegistryService.instance.load();
    final token = await sync.getToken();
    final baseUrl = await sync.getBaseUrl();
    final deviceId = await sync.getDeviceId();
    final desktopVersion = await RegistryService.instance.desktopVersion();
    final listenerEnabled =
        await NotificationBridge.instance.isListenerEnabled();
    final filterConfig = await AppFilterService.instance.load();
    final seenApps = await AppFilterService.instance.getSeenApps();
    if (!mounted) return;
    setState(() {
      _tokenController.text = token;
      _baseUrlController.text = baseUrl;
      _deviceId = deviceId;
      _localRegistryVersion = registry.version;
      _desktopRegistryVersion = desktopVersion;
      _listenerEnabled = listenerEnabled;
      _filterConfig = filterConfig;
      _knownAppNames = {for (final a in seenApps) a.packageName: a.appName};
    });
  }

  Future<void> _saveFilter(AppFilterConfig config) async {
    await AppFilterService.instance.save(config);
    if (mounted) setState(() => _filterConfig = config);
  }

  String _appDisplayName(String packageName) {
    final name = _knownAppNames[packageName];
    return (name != null && name.isNotEmpty) ? name : packageName;
  }

  Future<void> _addFilteredApps() async {
    final seenApps = await AppFilterService.instance.getSeenApps();
    if (!mounted) return;
    final selected = await Navigator.of(context).push<Set<String>>(
      MaterialPageRoute(
        builder: (_) => _AppPickerPage(
          seenApps: seenApps,
          initiallySelected: _filterConfig.packages.toSet(),
        ),
      ),
    );
    if (selected == null) return;
    final packages = _filterConfig.packages.toSet()..addAll(selected);
    final names = Map<String, String?>.of(_knownAppNames);
    for (final a in seenApps) {
      names[a.packageName] = a.appName;
    }
    await _saveFilter(_filterConfig.copyWith(packages: packages.toList()));
    if (mounted) setState(() => _knownAppNames = names);
  }

  Future<void> _removeFilteredApp(String packageName) async {
    final packages = _filterConfig.packages.toList()..remove(packageName);
    await _saveFilter(_filterConfig.copyWith(packages: packages));
  }

  Future<void> _save() async {
    await SyncClient.instance.setToken(_tokenController.text.trim());
    var baseUrl = _baseUrlController.text.trim();
    if (baseUrl.endsWith('/')) {
      baseUrl = baseUrl.substring(0, baseUrl.length - 1);
    }
    if (baseUrl.isNotEmpty) await SyncClient.instance.setBaseUrl(baseUrl);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已保存')));
    }
  }

  Future<void> _testConnection() async {
    await _save();
    setState(() {
      _testing = true;
      _healthOk = null;
    });
    final ok = await SyncClient.instance.health();
    if (mounted) {
      setState(() {
        _testing = false;
        _healthOk = ok;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('电脑端连接', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _baseUrlController,
            decoration: const InputDecoration(
              labelText: '服务地址',
              hintText: SyncClient.defaultBaseUrl,
              helperText: 'USB 连接后执行 adb reverse tcp:8765 tcp:8765',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tokenController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '配对 Token',
              helperText: '电脑端配对时生成的 Bearer Token',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _testing ? null : _testConnection,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_tethering),
                label: const Text('测试连接'),
              ),
              const SizedBox(width: 12),
              if (_healthOk != null)
                Text(
                  _healthOk! ? '连接正常' : '连接失败',
                  style: TextStyle(
                      color: _healthOk! ? Colors.green : Colors.red),
                ),
            ],
          ),
          const Divider(height: 32),
          Text('设备', style: Theme.of(context).textTheme.titleMedium),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('设备 ID'),
            subtitle: Text(_deviceId),
            trailing: IconButton(
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _deviceId));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制')));
                }
              },
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(_listenerEnabled
                ? Icons.notifications_active_outlined
                : Icons.notifications_off_outlined),
            title: const Text('通知监听授权'),
            subtitle: Text(_listenerEnabled ? '已授权' : '未授权，无法自动采集通知'),
            trailing: _listenerEnabled
                ? null
                : TextButton(
                    onPressed: () async {
                      await NotificationBridge.instance
                          .openListenerSettings();
                      await Future.delayed(const Duration(seconds: 1));
                      _load();
                    },
                    child: const Text('去授权'),
                  ),
          ),
          const Divider(height: 32),
          Text('应用采集过滤', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                  value: AppFilterConfig.modeAll, label: Text('全部应用')),
              ButtonSegment(
                  value: AppFilterConfig.modeAllowlist,
                  label: Text('仅指定应用')),
            ],
            selected: {_filterConfig.mode},
            onSelectionChanged: (v) =>
                _saveFilter(_filterConfig.copyWith(mode: v.first)),
          ),
          if (_filterConfig.isAllowlist) ...[
            const SizedBox(height: 8),
            if (_filterConfig.packages.isEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber_outlined, color: Colors.red),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text('当前不会收集任何应用的通知，请添加应用或切换为全部应用',
                          style: TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              ),
            for (final pkg in _filterConfig.packages)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.android, size: 20),
                title: Text(_appDisplayName(pkg)),
                subtitle:
                    pkg == _appDisplayName(pkg) ? null : Text(pkg),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '移除',
                  onPressed: () => _removeFilteredApp(pkg),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addFilteredApps,
                icon: const Icon(Icons.add),
                label: const Text('添加应用'),
              ),
            ),
          ] else
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('收集所有应用的通知（手动添加的消息不受此设置影响）',
                  style: TextStyle(color: Colors.grey)),
            ),
          const Divider(height: 32),
          Text('分类注册表', style: Theme.of(context).textTheme.titleMedium),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('本地版本'),
            subtitle: Text(_localRegistryVersion),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('电脑端版本'),
            subtitle: Text(_desktopRegistryVersion ?? '尚未同步'),
          ),
        ],
      ),
    );
  }
}

/// 从"已见应用"中选择要采集的应用（支持搜索），并可手动输入包名。
class _AppPickerPage extends StatefulWidget {
  final List<SeenApp> seenApps;
  final Set<String> initiallySelected;

  const _AppPickerPage({
    required this.seenApps,
    required this.initiallySelected,
  });

  @override
  State<_AppPickerPage> createState() => _AppPickerPageState();
}

class _AppPickerPageState extends State<_AppPickerPage> {
  final _searchController = TextEditingController();
  late final Set<String> _selected = Set.of(widget.initiallySelected);
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _addManualPackage() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('手动输入包名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '包名',
            hintText: '如 com.tencent.mm',
            helperText: '未发过通知的应用不会出现在列表中，可在此手动添加',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (value != null && value.isNotEmpty) {
      setState(() => _selected.add(value));
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.toLowerCase();
    final visible = widget.seenApps
        .where((a) =>
            query.isEmpty ||
            a.displayName.toLowerCase().contains(query) ||
            a.packageName.toLowerCase().contains(query))
        .toList();
    // 已选但不在 seen apps 里的（手动输入的包名）也要显示，便于取消勾选
    final seenPackages = widget.seenApps.map((a) => a.packageName).toSet();
    final manualOnly =
        _selected.where((p) => !seenPackages.contains(p)).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('选择要采集的应用'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_selected),
            child: const Text('完成'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索应用名或包名',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.keyboard),
                  tooltip: '手动输入包名',
                  onPressed: _addManualPackage,
                ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final pkg in manualOnly)
                  CheckboxListTile(
                    value: true,
                    onChanged: (_) =>
                        setState(() => _selected.remove(pkg)),
                    title: Text(pkg),
                    subtitle: const Text('手动添加'),
                  ),
                for (final app in visible)
                  CheckboxListTile(
                    value: _selected.contains(app.packageName),
                    onChanged: (v) => setState(() => v == true
                        ? _selected.add(app.packageName)
                        : _selected.remove(app.packageName)),
                    title: Text(app.displayName),
                    subtitle: Text(app.packageName),
                  ),
                if (visible.isEmpty && manualOnly.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                        child: Text('暂无记录；应用发过通知后会出现在这里，'
                            '也可点搜索框右侧按钮手动输入包名')),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

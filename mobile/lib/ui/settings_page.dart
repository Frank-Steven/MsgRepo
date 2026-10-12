import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart' show themeModeNotifier, themeModeFromString;
import '../services/ai_client.dart';
import '../services/app_filter_service.dart';
import '../services/notification_bridge.dart';

/// v2 设置页（设计 §9）：外观 / 自定义提示词 / AI 接口 / 连接 / 采集过滤。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _promptController = TextEditingController();

  String _themeMode = 'system';
  AiEndpoint _desktop = const AiEndpoint(
    id: AiClient.desktopEndpointId,
    name: AiClient.desktopName,
    baseUrl: AiClient.defaultDesktopBaseUrl,
    isDesktop: true,
  );
  bool? _desktopOnline;
  String _token = '';
  String? _desktopDeviceName;
  List<AiEndpoint> _remotes = [];
  String? _defaultEndpointId;
  final Set<String> _testing = {};

  bool _listenerEnabled = false;
  AppFilterConfig _filterConfig = const AppFilterConfig();
  Map<String, String?> _knownAppNames = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final ai = AiClient.instance;
    final desktop = await ai.desktopEndpoint();
    final remotes = await ai.getRemoteEndpoints();
    final defaultId = await ai.getDefaultEndpointId();
    final token = await ai.getDesktopToken();
    final deviceName = await ai.getDesktopDeviceName();
    final online = await ai.isDesktopOnline();
    final listenerEnabled =
        await NotificationBridge.instance.isListenerEnabled();
    final filterConfig = await AppFilterService.instance.load();
    final seenApps = await AppFilterService.instance.getSeenApps();
    if (!mounted) return;
    setState(() {
      _themeMode = prefs.getString('theme_mode') ?? 'system';
      _promptController.text = prefs.getString(AiClient.keyCustomPrompt) ?? '';
      _desktop = desktop;
      _remotes = remotes;
      _defaultEndpointId = defaultId;
      _token = token;
      _desktopDeviceName = deviceName.isEmpty ? null : deviceName;
      _desktopOnline = online;
      _listenerEnabled = listenerEnabled;
      _filterConfig = filterConfig;
      _knownAppNames = {for (final a in seenApps) a.packageName: a.appName};
    });
  }

  Future<void> _refreshDesktopStatus() async {
    final ai = AiClient.instance;
    final online = await ai.isDesktopOnline(force: true);
    final token = await ai.getDesktopToken();
    if (mounted) {
      setState(() {
        _desktopOnline = online;
        _token = token;
      });
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // ---- 外观 ----

  Future<void> _setThemeMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', mode);
    themeModeNotifier.value = themeModeFromString(mode);
    if (mounted) setState(() => _themeMode = mode);
  }

  // ---- 自定义提示词 ----

  Future<void> _savePrompt(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AiClient.keyCustomPrompt, value.trim());
  }

  // ---- AI 接口 ----

  Future<void> _testEndpoint(AiEndpoint endpoint) async {
    setState(() => _testing.add(endpoint.id));
    try {
      final msg = await AiClient.instance.testEndpoint(endpoint);
      _toast('${endpoint.name}：$msg');
    } catch (e) {
      _toast('${endpoint.name}：$e');
    } finally {
      await _refreshDesktopStatus();
      if (mounted) setState(() => _testing.remove(endpoint.id));
    }
  }

  Future<void> _editEndpoint([AiEndpoint? existing]) async {
    final ai = AiClient.instance;
    final nameController = TextEditingController(text: existing?.name ?? '');
    final baseUrlController =
        TextEditingController(text: existing?.baseUrl ?? '');
    final apiKeyController =
        TextEditingController(text: existing?.apiKey ?? '');
    final modelController = TextEditingController(text: existing?.model ?? '');
    final saved = await showDialog<AiEndpoint>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(existing == null ? '添加接口' : '编辑接口'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              TextField(
                controller: baseUrlController,
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  hintText: 'https://api.example.com/v1',
                ),
              ),
              TextField(
                controller: apiKeyController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'API Key（可空）',
                ),
              ),
              TextField(
                controller: modelController,
                decoration: const InputDecoration(labelText: '模型'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              var baseUrl = baseUrlController.text.trim();
              if (baseUrl.endsWith('/')) {
                baseUrl = baseUrl.substring(0, baseUrl.length - 1);
              }
              if (nameController.text.trim().isEmpty ||
                  baseUrl.isEmpty ||
                  modelController.text.trim().isEmpty) {
                return;
              }
              Navigator.of(context).pop(
                (existing ??
                        AiEndpoint(
                          id: ai.newEndpointId(),
                          name: '',
                          baseUrl: '',
                        ))
                    .copyWith(
                  name: nameController.text.trim(),
                  baseUrl: baseUrl,
                  apiKey: apiKeyController.text.trim(),
                  model: modelController.text.trim(),
                ),
              );
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == null) return;
    await ai.upsertEndpoint(saved);
    // 第一个远程接口自动设为默认
    if (await ai.getDefaultEndpointId() == null) {
      await ai.setDefaultEndpointId(saved.id);
    }
    await _load();
  }

  Future<void> _deleteEndpoint(AiEndpoint endpoint) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除接口'),
        content: Text('删除「${endpoint.name}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await AiClient.instance.deleteEndpoint(endpoint.id);
    await _load();
  }

  // ---- 连接 ----

  String get _maskedToken {
    if (_token.isEmpty) return '未配对（首次处理时自动配对）';
    final head = _token.length <= 6 ? _token : _token.substring(0, 6);
    return '$head••••••';
  }

  Future<void> _resetPairing() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重置配对'),
        content: const Text('电脑端将重新签发 token，本机自动完成重新配对。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final (_, deviceName) = await AiClient.instance.pairDesktop(reset: true);
      _desktopDeviceName = deviceName;
      _toast('已重新配对${deviceName.isNotEmpty ? '：$deviceName' : ''}');
    } catch (e) {
      _toast('重置配对失败：$e');
    }
    await _refreshDesktopStatus();
  }

  // ---- 采集过滤 ----

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

  // ---- UI ----

  Widget _section(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...children,
      ],
    );
  }

  Widget _buildEndpointTile(AiEndpoint endpoint) {
    final cs = Theme.of(context).colorScheme;
    final testing = _testing.contains(endpoint.id);
    if (endpoint.isDesktop) {
      final online = _desktopOnline == true;
      return Row(
        children: [
          Icon(Icons.computer, color: cs.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('电脑端（自动）'),
                Text(
                  '${endpoint.baseUrl} · '
                  '${_desktopOnline == null ? '探测中' : online ? '已连接' : '未连接'}'
                  ' · 模型由电脑端管理',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: testing ? null : () => _testEndpoint(endpoint),
            child: testing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('测试'),
          ),
        ],
      );
    }
    final isDefault = endpoint.id == _defaultEndpointId;
    return Row(
      children: [
        SizedBox(
          width: 32,
          child: Radio<String>(value: endpoint.id),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(isDefault ? '${endpoint.name}（默认）' : endpoint.name),
              Text(
                '${endpoint.baseUrl} · ${endpoint.model}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
        TextButton(
          onPressed: testing ? null : () => _testEndpoint(endpoint),
          child: testing
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('测试'),
        ),
        IconButton(
          tooltip: '编辑',
          icon: const Icon(Icons.edit_outlined, size: 20),
          onPressed: () => _editEndpoint(endpoint),
        ),
        IconButton(
          tooltip: '删除',
          icon: const Icon(Icons.delete_outline, size: 20),
          onPressed: () => _deleteEndpoint(endpoint),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final desktopOnline = _desktopOnline == true;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('外观', [
            _EqualSegments<String>(
              options: const [('system', '跟随系统'), ('light', '浅色'), ('dark', '深色')],
              value: _themeMode,
              onChanged: _setThemeMode,
            ),
          ]),
          const Divider(height: 32),
          _section('自定义提示词', [
            TextField(
              controller: _promptController,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: '例：把直播开播提醒都当作营销处理；工作消息优先级调高',
                helperText: '随每次 AI 处理自动下发，保存即生效',
                border: OutlineInputBorder(),
              ),
              onChanged: _savePrompt,
            ),
          ]),
          const Divider(height: 32),
          _section('AI 接口', [
            _buildEndpointTile(_desktop),
            const SizedBox(height: 4),
            Text('电脑端在线时自动优先；电脑端不在线时使用默认远程接口',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            RadioGroup<String>(
              groupValue: _defaultEndpointId,
              onChanged: (v) async {
                if (v == null) return;
                await AiClient.instance.setDefaultEndpointId(v);
                if (mounted) setState(() => _defaultEndpointId = v);
              },
              child: Column(
                children: [for (final e in _remotes) _buildEndpointTile(e)],
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _editEndpoint(),
                icon: const Icon(Icons.add),
                label: const Text('添加远程接口'),
              ),
            ),
          ]),
          const Divider(height: 32),
          _section('连接', [
            Row(
              children: [
                Icon(
                  desktopOnline ? Icons.usb : Icons.usb_off,
                  color: desktopOnline ? cs.primary : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(desktopOnline ? '电脑端通道已连接' : '电脑端通道未连接'),
                      if (!desktopOnline)
                        Text('USB 连接后执行 adb reverse tcp:8765 tcp:8765',
                            style: TextStyle(
                                fontSize: 12, color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '刷新',
                  icon: const Icon(Icons.refresh),
                  onPressed: _refreshDesktopStatus,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.key_outlined, color: cs.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('配对 token'),
                      Text(
                        _desktopDeviceName != null
                            ? '$_maskedToken（$_desktopDeviceName）'
                            : _maskedToken,
                        style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                            color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: desktopOnline ? _resetPairing : null,
                  child: const Text('重置配对'),
                ),
              ],
            ),
          ]),
          const Divider(height: 32),
          _section('采集过滤', [
            Row(
              children: [
                Icon(
                  _listenerEnabled
                      ? Icons.notifications_active_outlined
                      : Icons.notifications_off_outlined,
                  color: _listenerEnabled ? cs.primary : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(_listenerEnabled
                      ? '通知监听已授权'
                      : '通知监听未授权，无法自动采集通知'),
                ),
                if (!_listenerEnabled)
                  TextButton(
                    onPressed: () async {
                      await NotificationBridge.instance.openListenerSettings();
                      await Future.delayed(const Duration(seconds: 1));
                      _load();
                    },
                    child: const Text('去授权'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _EqualSegments<String>(
              options: const [
                (AppFilterConfig.modeAll, '全部应用'),
                (AppFilterConfig.modeAllowlist, '仅指定应用'),
              ],
              value: _filterConfig.mode,
              onChanged: (v) => _saveFilter(_filterConfig.copyWith(mode: v)),
            ),
            if (_filterConfig.isAllowlist) ...[
              const SizedBox(height: 12),
              if (_filterConfig.packages.isEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber_outlined,
                          color: cs.onErrorContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '当前不会收集任何应用的通知，请添加应用或切换为全部应用',
                          style: TextStyle(color: cs.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              // 统一 Chip 行（设计 §10.2）：横向滚动，添加/删除都在行内
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final pkg in _filterConfig.packages)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: InputChip(
                          label: Text(_appDisplayName(pkg)),
                          onDeleted: () {
                            final packages = _filterConfig.packages.toList()
                              ..remove(pkg);
                            _saveFilter(
                                _filterConfig.copyWith(packages: packages));
                          },
                        ),
                      ),
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 18),
                      label: const Text('添加应用'),
                      onPressed: _addFilteredApps,
                    ),
                  ],
                ),
              ),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('收集所有应用的通知（手动添加的消息不受此设置影响）',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ),
          ]),
        ],
      ),
    );
  }
}

/// 等宽分段控件（设计 §10.1）：固定总宽内均分，选中只改底色不改宽度，不换行。
class _EqualSegments<T> extends StatelessWidget {
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;

  const _EqualSegments({
    required this.options,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: double.infinity,
      height: 40,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(20),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            for (var i = 0; i < options.length; i++) ...[
              if (i > 0) Container(width: 1, color: cs.outlineVariant),
              Expanded(
                child: Material(
                  color: options[i].$1 == value
                      ? cs.secondaryContainer
                      : Colors.transparent,
                  child: InkWell(
                    onTap: () => onChanged(options[i].$1),
                    child: Center(
                      child: Text(
                        options[i].$2,
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 14,
                          color: options[i].$1 == value
                              ? cs.onSecondaryContainer
                              : cs.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
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

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart' show themeModeNotifier, themeModeFromString;
import 'shared/app_icon.dart';
import 'shared/segmented_selector.dart';
import '../services/ai_client.dart';
import '../services/app_filter_service.dart';
import '../services/notification_bridge.dart';
import '../services/reminder_service.dart';
import '../services/prompt_rules.dart';
import '../../services/app_log.dart';

/// v2 设置页（设计 §9）：外观 / 自定义提示词 / AI 接口 / 连接 / 采集过滤。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _promptController = TextEditingController();

  /// 「类型 → 处理方式」规则行（U2）：每行两个输入框
  final List<({TextEditingController type, TextEditingController treatment})>
      _ruleRows = [];

  /// 提示词区是否展开（U2：整块可折叠）
  bool _promptExpanded = true;

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
  bool _batteryOptimized = true; // true = 已加入白名单（不需要再优化）
  bool _exactAlarms = true; // 精确闹钟权限（Android 12+ 可能需要手动开启）
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
    for (final r in _ruleRows) {
      r.type.dispose();
      r.treatment.dispose();
    }
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
    final batteryOptimized =
        await NotificationBridge.instance.isIgnoringBatteryOptimizations();
    final exactAlarms = await ReminderService.instance.refreshExactAlarms();
    final filterConfig = await AppFilterService.instance.load();
    final seenApps = await AppFilterService.instance.getSeenApps();
    final rules = await PromptRulesStore.load();
    if (!mounted) return;
    setState(() {
      _themeMode = prefs.getString('theme_mode') ?? 'system';
      _promptController.text = prefs.getString(AiClient.keyCustomPrompt) ?? '';
      for (final r in _ruleRows) {
        r.type.dispose();
        r.treatment.dispose();
      }
      _ruleRows
        ..clear()
        ..addAll([
          for (final rule in rules)
            (
              type: TextEditingController(text: rule.type),
              treatment: TextEditingController(text: rule.treatment),
            ),
        ]);
      _desktop = desktop;
      _remotes = remotes;
      _defaultEndpointId = defaultId;
      _token = token;
      _desktopDeviceName = deviceName.isEmpty ? null : deviceName;
      _desktopOnline = online;
      _listenerEnabled = listenerEnabled;
      _batteryOptimized = batteryOptimized;
      _exactAlarms = exactAlarms;
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
    if (!mounted) return; // P3-5：await 之后调用时页面可能已销毁
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(text), duration: const Duration(seconds: 2)));
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

  // ---- 分类规则（U2）：类型 → 处理方式 ----

  Future<void> _saveRules() async {
    await PromptRulesStore.save([
      for (final r in _ruleRows)
        PromptRule(type: r.type.text, treatment: r.treatment.text),
    ]);
  }

  void _addRuleRow() {
    setState(() => _ruleRows.add((
          type: TextEditingController(),
          treatment: TextEditingController(),
        )));
  }

  void _removeRuleRow(int index) {
    if (index < 0 || index >= _ruleRows.length) return;
    final row = _ruleRows.removeAt(index);
    row.type.dispose();
    row.treatment.dispose();
    setState(() {});
    _saveRules();
  }

  /// 提示词区（U2）：可折叠；上半是规则表，下半是自由文本。
  Widget _buildPromptSection(ColorScheme cs) {
    final validCount = _ruleRows
        .where((r) =>
            r.type.text.trim().isNotEmpty && r.treatment.text.trim().isNotEmpty)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _promptExpanded = !_promptExpanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Text('自定义提示词',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 8),
                if (validCount > 0)
                  Text('$validCount 条规则',
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                const Spacer(),
                Icon(
                    _promptExpanded ? Icons.expand_less : Icons.expand_more,
                    color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
        if (_promptExpanded) ...[
          Text('左列写消息类型，右列写处理方式；两列都填才生效，顺序即优先级。',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          const SizedBox(height: 8),
          for (var i = 0; i < _ruleRows.length; i++) _buildRuleRow(i, cs),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _addRuleRow,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加规则'),
            ),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _promptController,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: '补充要求（自由文本，可选）',
              hintText: '例：还能让 AI 识别学习委员是谁',
              helperText: '两处都会原样附加到系统提示词之后，保存即生效',
              helperMaxLines: 2,
              border: OutlineInputBorder(),
            ),
            onChanged: _savePrompt,
          ),
        ],
      ],
    );
  }

  Widget _buildRuleRow(int index, ColorScheme cs) {
    final row = _ruleRows[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: TextField(
              controller: row.type,
              decoration: const InputDecoration(
                labelText: '消息类型',
                hintText: '广告 / 验证码',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _saveRules(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Icon(Icons.arrow_forward, size: 16, color: cs.onSurfaceVariant),
          ),
          Expanded(
            flex: 5,
            child: TextField(
              controller: row.treatment,
              decoration: const InputDecoration(
                labelText: '处理方式',
                hintText: '当作营销 / 忽略',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _saveRules(),
            ),
          ),
          IconButton(
            tooltip: '删除这一行',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => _removeRuleRow(index),
          ),
        ],
      ),
    );
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
    // v2.4：应用选择页以 PackageManager 全量可启动应用为主，
    // 补充"已见但已卸载/无启动器入口"的历史应用
    final results = await Future.wait([
      AppFilterService.instance.getInstalledApps(),
      AppFilterService.instance.getSeenApps(),
    ]);
    final installed = results[0];
    final seen = results[1];
    final installedPkgs = {for (final a in installed) a.packageName};
    final extra = seen.where((a) => !installedPkgs.contains(a.packageName));
    final apps = [...installed, ...extra];
    if (!mounted) return;
    final selected = await Navigator.of(context).push<Set<String>>(
      MaterialPageRoute(
        builder: (_) => _AppPickerPage(
          title: _filterConfig.isBlacklist ? '选择要屏蔽的应用' : '选择要采集的应用',
          apps: apps,
          initiallySelected: _filterConfig.packages.toSet(),
        ),
      ),
    );
    if (selected == null) return;
    final packages = _filterConfig.packages.toSet()..addAll(selected);
    final names = Map<String, String?>.of(_knownAppNames);
    for (final a in apps) {
      names[a.packageName] = a.appName;
    }
    await _saveFilter(_filterConfig.copyWith(packages: packages.toList()));
    if (mounted) setState(() => _knownAppNames = names);
  }

  // ---- 后台保活（v2.6）----

  Future<void> _requestBatteryWhitelist() async {
    final opened =
        await NotificationBridge.instance.requestIgnoreBatteryOptimizations();
    if (!opened && mounted) _toast('无法打开电池优化设置');
    // 系统设置返回后状态可能已变，延迟刷新
    await Future.delayed(const Duration(seconds: 1));
    _load();
  }

  /// 请求精确闹钟权限（Android 12+ 可能需要用户手动开启）。
  Future<void> _requestExactAlarms() async {
    final ok = await ReminderService.instance.requestExactAlarms();
    if (!mounted) return;
    setState(() => _exactAlarms = ok);
    _toast(ok ? '已允许精确提醒' : '未获得精确闹钟权限：提醒仍会触发，但可能延迟数分钟');
  }

  /// 展示最近被记录的异常（P2-6）：把以前静默吞掉的失败变成可读列表。
  Future<void> _showRecentErrors() async {
    final entries = AppLog.instance.entries;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('最近错误（${entries.length} 类）'),
        content: SizedBox(
          width: double.maxFinite,
          child: entries.isEmpty
              ? const Text('暂无记录。')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: entries.length,
                  itemBuilder: (_, i) {
                    final e = entries[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: SelectableText(e.oneLine,
                          style: const TextStyle(
                              fontSize: 12, fontFamily: 'monospace')),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              AppLog.instance.clear();
              Navigator.of(ctx).pop();
              setState(() {});
            },
            child: const Text('清空'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _openAutoStartSettings() async {
    final opened = await NotificationBridge.instance.openAutoStartSettings();
    if (opened || !mounted) return;
    // 无已知厂商组件可跳：图文引导 + 应用详情页兜底入口
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手动开启保活权限'),
        content: const SingleChildScrollView(
          child: Text('未能直接跳转自启动设置，请手动操作：\n\n'
              'vivo / iQOO：\n'
              'i 管家 → 应用管理 → 权限管理 → 自启动 → 允许 MsgRepo；\n'
              '设置 → 电池 → 后台耗电管理 → MsgRepo → 允许后台高耗电。\n\n'
              '其他机型：\n'
              '系统设置 → 应用管理 → MsgRepo → 允许自启动 / 后台运行 / '
              '电池不优化（名称因厂商而异）。'),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              NotificationBridge.instance.openAppDetailsSettings();
            },
            child: const Text('打开应用详情'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
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
            SegmentedSelector<String>(
              values: const ['system', 'light', 'dark'],
              labels: const ['跟随系统', '浅色', '深色'],
              height: 40,
              selected: _themeMode,
              onChanged: _setThemeMode,
            ),
          ]),
          const Divider(height: 32),
          _buildPromptSection(cs),
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
            SegmentedSelector<String>(
              values: const [
                AppFilterConfig.modeAll,
                AppFilterConfig.modeAllowlist,
                AppFilterConfig.modeBlacklist,
              ],
              labels: const ['全部应用', '仅指定应用', '屏蔽指定应用'],
              height: 40,
              selected: _filterConfig.mode,
              onChanged: (v) => _saveFilter(_filterConfig.copyWith(mode: v)),
            ),
            if (_filterConfig.isAllowlist || _filterConfig.isBlacklist) ...[
              const SizedBox(height: 12),
              if (_filterConfig.isAllowlist && _filterConfig.packages.isEmpty)
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
                          avatar: AppIcon(
                              packageName: pkg,
                              appName: _knownAppNames[pkg]),
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
                      label: Text(_filterConfig.isBlacklist
                          ? '添加屏蔽应用'
                          : '添加应用'),
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
          const Divider(height: 32),
          _section('后台保活', [
            Row(
              children: [
                Icon(
                  _batteryOptimized
                      ? Icons.battery_saver_outlined
                      : Icons.battery_alert_outlined,
                  color: _batteryOptimized ? cs.primary : cs.error,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(_batteryOptimized
                      ? '已加入电池优化白名单'
                      : '未加入电池优化白名单，系统可能随时停止消息监听'),
                ),
                if (!_batteryOptimized)
                  TextButton(
                    onPressed: _requestBatteryWhitelist,
                    child: const Text('去设置'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  _exactAlarms ? Icons.alarm_on_outlined : Icons.alarm_off_outlined,
                  color: _exactAlarms ? cs.primary : cs.error,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(_exactAlarms
                      ? '任务提醒：精确闹钟已允许'
                      : '任务提醒：未允许精确闹钟，提醒可能延迟数分钟'),
                ),
                if (!_exactAlarms)
                  TextButton(
                    onPressed: _requestExactAlarms,
                    child: const Text('去设置'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.rocket_launch_outlined, color: cs.onSurfaceVariant),
                const SizedBox(width: 12),
                const Expanded(child: Text('自启动 / 后台运行（国产 ROM 必开）')),
                TextButton(
                  onPressed: _openAutoStartSettings,
                  child: const Text('去设置'),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '消息监听经常停止时：把本应用加入电池优化白名单，并在系统设置中'
                '允许自启动与后台运行（vivo：i 管家 → 自启动；电池 → 后台耗电'
                '管理 → 允许后台高耗电）。',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 8),
            // P2-6：异常不再被静默吞掉，这里给出统一查看入口
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                AppLog.instance.count == 0
                    ? Icons.check_circle_outline
                    : Icons.bug_report_outlined,
                color: AppLog.instance.count == 0 ? cs.primary : cs.error,
              ),
              title: const Text('最近错误'),
              subtitle: Text(
                AppLog.instance.count == 0 ? '暂无可显示的异常' : '${AppLog.instance.count} 类，点击查看',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showRecentErrors,
            ),
          ]),
        ],
      ),
    );
  }
}

/// 应用选择页（v2.4 改为 PackageManager 全量列表 + 已见历史应用），
/// 支持搜索、图标展示，并可手动输入包名。
class _AppPickerPage extends StatefulWidget {
  final String title;
  final List<SeenApp> apps;
  final Set<String> initiallySelected;

  const _AppPickerPage({
    required this.title,
    required this.apps,
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
            helperText: '无启动器入口的应用不出现在列表中，可在此手动添加',
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
    final visible = widget.apps
        .where((a) =>
            query.isEmpty ||
            a.displayName.toLowerCase().contains(query) ||
            a.packageName.toLowerCase().contains(query))
        .toList();
    // 已选但不在应用列表里的（手动输入的包名）也要显示，便于取消勾选
    final listedPackages = widget.apps.map((a) => a.packageName).toSet();
    final manualOnly =
        _selected.where((p) => !listedPackages.contains(p)).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
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
                    secondary: AppIcon(
                        packageName: app.packageName,
                        appName: app.appName,
                        size: 28),
                    title: Text(app.displayName),
                    subtitle: Text(app.packageName),
                  ),
                if (visible.isEmpty && manualOnly.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                        child: Text('无匹配应用；'
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

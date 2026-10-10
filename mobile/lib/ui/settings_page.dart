import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    if (!mounted) return;
    setState(() {
      _tokenController.text = token;
      _baseUrlController.text = baseUrl;
      _deviceId = deviceId;
      _localRegistryVersion = registry.version;
      _desktopRegistryVersion = desktopVersion;
      _listenerEnabled = listenerEnabled;
    });
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
              helperText: 'USB 连接后执行 adb forward tcp:8765 tcp:8765',
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

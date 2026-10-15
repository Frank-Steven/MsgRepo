import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/import_service.dart';
import '../../services/notification_bridge.dart';

/// 聊天记录导入二级页（设计 §5 v2.4-20 预留方案，v2.6 落地）：
/// 选来源（消息页底部弹层传入）→ 选文件/读短信 → 解析预览
/// （条数/时间范围/错误行）→ 确认导入（进度）→ 结果报告。
/// 入库 capture_type='import' + import_source，content_hash 去重。
class ImportPage extends StatefulWidget {
  final String source; // ImportSource.qq / wechat / sms

  const ImportPage({super.key, required this.source});

  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  ImportParseResult? _parsed;
  String? _pickedName;
  String? _error;
  bool _importing = false;
  int _progressDone = 0;
  int _progressTotal = 0;
  ImportReport? _report;

  String get _sourceName => ImportSource.appNameOf(widget.source);

  Future<void> _pickAndParse() async {
    setState(() {
      _error = null;
      _parsed = null;
    });
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt'],
      withData: true,
    );
    final file = result?.files.firstOrNull;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return; // 用户取消
    final String text;
    try {
      text = decodeImportText(bytes);
    } on FormatException {
      setState(() => _error = '文件编码不是 UTF-8，请先转换为 UTF-8 再导入'
          '（QQ 老版本导出的 GBK 文件可用记事本另存为 UTF-8）');
      return;
    }
    final parsed = widget.source == ImportSource.qq
        ? parseQqExport(text)
        : parseWechatExport(text);
    setState(() {
      _pickedName = file.name;
      _parsed = parsed;
      if (parsed.messages.isEmpty && parsed.errors.isEmpty) {
        _error = '未解析到任何消息，请确认文件是$_sourceName导出的聊天记录文本';
      }
    });
  }

  Future<void> _readSms() async {
    setState(() {
      _error = null;
      _parsed = null;
    });
    final bridge = NotificationBridge.instance;
    var granted = await bridge.hasSmsPermission();
    if (!granted) granted = await bridge.requestSmsPermission();
    if (!granted) {
      setState(() => _error = '未授予读取短信权限');
      return;
    }
    final rows = await bridge.readSmsMessages();
    if (!mounted) return;
    if (rows.isEmpty) {
      setState(() => _error = '系统短信库中没有可导入的短信');
      return;
    }
    final messages = <ParsedImportMessage>[];
    final errors = <String>[];
    for (final r in rows) {
      final body = (r['body'] as String? ?? '').trim();
      final date = (r['date'] as num?)?.toInt() ?? 0;
      if (body.isEmpty || date <= 0) {
        errors.add('一条短信缺少正文或时间，已跳过');
        continue;
      }
      final isInbox = (r['type'] as num?)?.toInt() != 2;
      final address = (r['address'] as String? ?? '').trim();
      messages.add(ParsedImportMessage(
        postedAt: date,
        sender: isInbox ? address : '我',
        text: body,
        lineNo: 0,
        conversation: address.isEmpty ? null : address,
      ));
    }
    setState(() {
      _pickedName = '系统短信库';
      _parsed = ImportParseResult(messages: messages, errors: errors);
    });
  }

  Future<void> _runImport() async {
    final parsed = _parsed;
    if (parsed == null) return;
    setState(() {
      _importing = true;
      _progressDone = 0;
      _progressTotal = 0;
    });
    final report = await importParsedMessages(
      widget.source,
      parsed.conversationTitle,
      parsed.messages,
      parsed.errors,
      onProgress: (done, total) {
        if (mounted) {
          setState(() {
            _progressDone = done;
            _progressTotal = total;
          });
        }
      },
    );
    if (mounted) {
      setState(() {
        _importing = false;
        _report = report;
      });
    }
  }

  String _timeRange(List<ParsedImportMessage> messages) {
    if (messages.isEmpty) return '—';
    var min = messages.first.postedAt, max = messages.first.postedAt;
    for (final m in messages) {
      if (m.postedAt < min) min = m.postedAt;
      if (m.postedAt > max) max = m.postedAt;
    }
    String fmt(int ms) {
      final d = DateTime.fromMillisecondsSinceEpoch(ms);
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
    }

    return '${fmt(min)} ~ ${fmt(max)}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final parsed = _parsed;
    final report = _report;
    return Scaffold(
      appBar: AppBar(title: Text('从$_sourceName导入')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 第一步：选文件 / 读短信
          if (widget.source == ImportSource.sms)
            FilledButton.icon(
              onPressed: _importing ? null : _readSms,
              icon: const Icon(Icons.sms_outlined),
              label: const Text('读取系统短信'),
            )
          else
            FilledButton.icon(
              onPressed: _importing ? null : _pickAndParse,
              icon: const Icon(Icons.file_open_outlined),
              label: Text(parsed == null ? '选择导出文件（.txt）' : '重新选择文件'),
            ),
          if (widget.source == ImportSource.qq)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'QQ 电脑端：消息管理器 → 导出聊天记录（.txt，UTF-8）',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
          if (widget.source == ImportSource.wechat)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '微信无官方导出，支持第三方工具导出的两段式文本'
                '（「时间 发送者」一行 + 内容若干行，UTF-8）',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
          if (_pickedName != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('已选：$_pickedName',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: cs.error)),
            ),

          // 第二步：解析预览
          if (parsed != null && parsed.messages.isNotEmpty) ...[
            const Divider(height: 32),
            Text('解析预览', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('共 ${parsed.messages.length} 条消息'
                '（${_timeRange(parsed.messages)}）'
                '${parsed.conversationTitle != null ? '，会话：${parsed.conversationTitle}' : ''}'),
            if (parsed.errors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${parsed.errors.length} 行无法解析，将跳过：\n'
                  '${parsed.errors.take(3).join('\n')}'
                  '${parsed.errors.length > 3 ? '\n…' : ''}',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
            const SizedBox(height: 12),
            if (!_importing && report == null)
              FilledButton.icon(
                onPressed: _runImport,
                icon: const Icon(Icons.file_upload_outlined),
                label: Text('导入 ${parsed.messages.length} 条'),
              ),
          ],

          // 第三步：进度
          if (_importing) ...[
            const Divider(height: 32),
            LinearProgressIndicator(
              value: _progressTotal > 0
                  ? _progressDone / _progressTotal
                  : null,
            ),
            const SizedBox(height: 8),
            Text(_progressTotal > 0
                ? '正在导入 $_progressDone / $_progressTotal'
                : '正在导入…'),
          ],

          // 第四步：结果报告
          if (report != null) ...[
            const Divider(height: 32),
            Text('导入完成', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('新导入 ${report.imported} 条；'
                '重复跳过 ${report.skipped} 条；'
                '解析失败 ${report.errors.length} 行'),
            if (report.errors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  report.errors.take(10).join('\n') +
                      (report.errors.length > 10
                          ? '\n… 共 ${report.errors.length} 行'
                          : ''),
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('完成'),
            ),
          ],
        ],
      ),
    );
  }
}

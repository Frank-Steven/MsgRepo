import 'dart:convert';
import 'dart:isolate';

import 'package:uuid/uuid.dart';

import '../models/message.dart';
import 'database.dart';

/// 聊天记录导入（设计 §5 v2.4-20 预留方案，v2.6 落地）。
///
/// 来源：QQ / 微信的文本导出文件、系统短信数据库。
/// 入库统一 capture_type='import' + import_source 标记平台，
/// content_hash 去重（重复静默跳过并计数）。
class ImportSource {
  static const qq = 'qq';
  static const wechat = 'wechat';
  static const sms = 'sms';

  /// 写入 messages.package_name 的虚拟包名（来源筛选 chip 用）。
  static String packageNameOf(String source) => switch (source) {
        qq => 'import.qq',
        wechat => 'import.wechat',
        sms => 'import.sms',
        _ => 'import.unknown',
      };

  static String appNameOf(String source) => switch (source) {
        qq => 'QQ',
        wechat => '微信',
        sms => '短信',
        _ => '导入',
      };
}

/// 从源文件/短信解析出的一条消息。
class ParsedImportMessage {
  final int postedAt;
  final String sender;
  final String text;

  /// 源文件行号（1 起；短信为 0），错误报告定位用。
  final int lineNo;

  /// 单条级会话名（短信按号码归会话），优先于文件级会话名。
  final String? conversation;

  const ParsedImportMessage({
    required this.postedAt,
    required this.sender,
    required this.text,
    required this.lineNo,
    this.conversation,
  });
}

class ImportParseResult {
  final List<ParsedImportMessage> messages;
  final List<String> errors;

  /// 解析到的会话名（QQ 导出文件的「消息对象」），无则 null。
  final String? conversationTitle;

  const ImportParseResult({
    required this.messages,
    required this.errors,
    this.conversationTitle,
  });
}

class ImportReport {
  final int total;
  final int imported;
  final int skipped;
  final List<String> errors;

  const ImportReport({
    required this.total,
    required this.imported,
    required this.skipped,
    required this.errors,
  });
}

/// 解码导入文件文本：严格 UTF-8；QQ PC 老版本导出的 GBK 文件暂不内置
/// 转码（无第三方依赖），解码失败抛 FormatException 由 UI 提示转换编码。
String decodeImportText(List<int> bytes) =>
    utf8.decode(bytes, allowMalformed: false);

/// 按来源选择解析器（同步纯函数：QQ / 微信各自一条，其它按微信格式兜底）。
ImportParseResult parseExportBySource(String source, String text) =>
    source == ImportSource.qq ? parseQqExport(text) : parseWechatExport(text);

/// O05：把「导出文本解析」搬到后台 isolate，主 isolate 只做入库。
///
/// 原来 [parseQqExport]/[parseWechatExport] 直接在 UI isolate 里跑，几万行
/// 的导出文件会掉帧。解析函数本身是纯 Dart（不碰 platform channel /
/// BuildContext），返回结构只含 String/int，可安全跨 isolate 传递；
/// [Isolate.run] 结束后 isolate 自动回收，不需要手动 dispose。
///
/// UI 侧用法：
/// ```dart
/// final parsed = await parseExportInIsolate(source, text);
/// ```
Future<ImportParseResult> parseExportInIsolate(String source, String text) {
  return Isolate.run(() => parseExportBySource(source, text));
}

/// QQ PC 端「消息管理器 → 导出聊天记录」文本格式：
/// ```
/// ================================================================
/// 消息分组:我的好友
/// ================================================================
/// 消息对象:昵称(12345678)
/// ================================================================
///
/// 2024-01-02 15:04:05 昵称(12345678)
/// 内容（可多行）
/// ```
ImportParseResult parseQqExport(String text) {
  final lines = const LineSplitter().convert(text);
  final messages = <ParsedImportMessage>[];
  final errors = <String>[];
  String? conversation;
  final headerRe =
      RegExp(r'^(\d{4}-\d{2}-\d{2} \d{1,2}:\d{2}:\d{2})\s+(.+?)(\(\d+\))?$');

  int? curTs;
  String? curSender;
  int curLine = 0;
  final buf = <String>[];

  void flush() {
    if (curTs == null) return;
    final body = buf.join('\n').trim();
    if (body.isNotEmpty) {
      messages.add(ParsedImportMessage(
          postedAt: curTs!, sender: curSender ?? '', text: body, lineNo: curLine));
    }
    curTs = null;
    buf.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('===')) continue;
    if (trimmed.startsWith('消息分组:')) continue;
    if (trimmed.startsWith('消息对象:')) {
      flush();
      conversation = trimmed.substring('消息对象:'.length).trim();
      continue;
    }
    final m = headerRe.firstMatch(trimmed);
    if (m != null) {
      flush();
      final ts = DateTime.tryParse(m.group(1)!)?.millisecondsSinceEpoch;
      if (ts == null) {
        errors.add('第 ${i + 1} 行：时间无法解析「$trimmed」');
      } else {
        curTs = ts;
        curSender = m.group(2)!.trim();
        curLine = i + 1;
      }
      continue;
    }
    if (curTs != null) {
      buf.add(line);
    } else {
      errors.add('第 ${i + 1} 行：无法识别「$trimmed」');
    }
  }
  flush();
  return ImportParseResult(
      messages: messages, errors: errors, conversationTitle: conversation);
}

/// 微信无官方导出。按主流导出工具（电脑端备份转文本/第三方工具）的通用
/// 两段式文本格式解析：
/// ```
/// 2024-01-02 15:04:05 张三
/// 内容（可多行）
///
/// 2024-01-02 15:05:00 我
/// 回复
/// ```
/// 头行 = 时间戳 + 空格 + 发送者；后续非空行并入内容，空行/下一头行结束。
ImportParseResult parseWechatExport(String text) {
  final lines = const LineSplitter().convert(text);
  final messages = <ParsedImportMessage>[];
  final errors = <String>[];
  final headerRe =
      RegExp(r'^(\d{4}-\d{2}-\d{2}[ T]\d{1,2}:\d{2}(:\d{2})?)\s+(.+)$');

  int? curTs;
  String? curSender;
  int curLine = 0;
  final buf = <String>[];

  void flush() {
    if (curTs == null) return;
    final body = buf.join('\n').trim();
    if (body.isNotEmpty) {
      messages.add(ParsedImportMessage(
          postedAt: curTs!, sender: curSender ?? '', text: body, lineNo: curLine));
    }
    curTs = null;
    buf.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      // 空行结束当前消息（兼容消息间空行分隔的导出）
      flush();
      continue;
    }
    final m = headerRe.firstMatch(trimmed);
    if (m != null) {
      flush();
      final ts =
          DateTime.tryParse(m.group(1)!.replaceFirst('T', ' '))
              ?.millisecondsSinceEpoch;
      if (ts == null) {
        errors.add('第 ${i + 1} 行：时间无法解析「$trimmed」');
      } else {
        curTs = ts;
        curSender = m.group(3)!.trim();
        curLine = i + 1;
      }
      continue;
    }
    if (curTs != null) {
      buf.add(line);
    } else {
      errors.add('第 ${i + 1} 行：无法识别「$trimmed」');
    }
  }
  flush();
  return ImportParseResult(messages: messages, errors: errors);
}

/// 解析结果 → messages 表行（capture_type='import'）。
Message importMessageOf(String source, String? conversationTitle,
    ParsedImportMessage p, Uuid uuid) {
  final packageName = ImportSource.packageNameOf(source);
  final conv = p.conversation ?? conversationTitle;
  final title = (conv != null && conv.isNotEmpty)
      ? conv
      : (p.sender.isNotEmpty ? p.sender : ImportSource.appNameOf(source));
  return Message(
    id: uuid.v4(),
    packageName: packageName,
    appName: ImportSource.appNameOf(source),
    conversationTitle: conv,
    sender: p.sender.isEmpty ? null : p.sender,
    title: title,
    body: p.text,
    postedAt: p.postedAt,
    captureType: 'import',
    importSource: source,
    contentHash: computeContentHash(packageName, title, p.text, p.postedAt),
    status: MessageStatus.pending,
    priority: MessagePriority.none,
    createdAt: DateTime.now().millisecondsSinceEpoch,
  );
}

/// 批量导入：content_hash 去重（重复静默跳过计数），500 条/批事务写库，
/// [onProgress] 每批回报（已处理, 总数）。
Future<ImportReport> importParsedMessages(
  String source,
  String? conversationTitle,
  List<ParsedImportMessage> parsed,
  List<String> parseErrors, {
  void Function(int done, int total)? onProgress,
}) async {
  final db = AppDatabase.instance;
  final existing = await db.getAllMessageContentHashes();
  const uuid = Uuid();
  final fresh = <Message>[];
  var skipped = 0;
  for (final p in parsed) {
    final m = importMessageOf(source, conversationTitle, p, uuid);
    if (existing.contains(m.contentHash)) {
      skipped++;
    } else {
      existing.add(m.contentHash); // 源文件内部重复也只入一次
      fresh.add(m);
    }
  }
  var done = 0;
  const batch = 500;
  for (var i = 0; i < fresh.length; i += batch) {
    final end = (i + batch > fresh.length) ? fresh.length : i + batch;
    await db.insertMessagesBatch(fresh.sublist(i, end));
    done = end;
    onProgress?.call(done, fresh.length);
  }
  if (fresh.isEmpty) onProgress?.call(0, 0);
  return ImportReport(
    total: parsed.length,
    imported: fresh.length,
    skipped: skipped,
    errors: parseErrors,
  );
}

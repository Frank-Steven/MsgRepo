import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/import_service.dart';
import 'package:uuid/uuid.dart';

/// v2.6 聊天记录导入解析器回归：QQ 导出格式 / 微信两段式文本 / UTF-8 解码。
void main() {
  group('parseQqExport', () {
    test('标准导出：分隔符/消息对象/多行内容/多消息', () {
      const text = '================================================================\n'
          '消息分组:我的好友\n'
          '================================================================\n'
          '消息对象:张三(12345678)\n'
          '================================================================\n'
          '\n'
          '2024-01-02 15:04:05 张三(12345678)\n'
          '你好\n'
          '第二行内容\n'
          '\n'
          '2024-01-02 15:05:00 我(987654)\n'
          '回复一下\n';
      final r = parseQqExport(text);
      expect(r.conversationTitle, '张三(12345678)');
      expect(r.errors, isEmpty);
      expect(r.messages, hasLength(2));
      expect(r.messages[0].sender, '张三');
      expect(r.messages[0].text, '你好\n第二行内容');
      expect(r.messages[0].postedAt,
          DateTime(2024, 1, 2, 15, 4, 5).millisecondsSinceEpoch);
      expect(r.messages[1].sender, '我');
      expect(r.messages[1].text, '回复一下');
    });

    test('无法识别的行计入错误，不阻塞后续解析', () {
      const text = '开头一行说明文字\n'
          '2024-01-02 15:04:05 张三(12345678)\n'
          '你好\n';
      final r = parseQqExport(text);
      expect(r.messages, hasLength(1));
      expect(r.errors, hasLength(1));
      expect(r.errors.first, contains('第 1 行'));
    });
  });

  group('parseWechatExport', () {
    test('两段式：时间+发送者头行，内容多行，空行分隔', () {
      const text = '2024-01-02 15:04:05 张三\n'
          '在吗\n'
          '\n'
          '2024-01-02 15:05:00 我\n'
          '在的\n'
          '说吧\n';
      final r = parseWechatExport(text);
      expect(r.errors, isEmpty);
      expect(r.messages, hasLength(2));
      expect(r.messages[0].sender, '张三');
      expect(r.messages[0].text, '在吗');
      expect(r.messages[1].text, '在的\n说吧');
    });

    test('头行前垃圾行计错；无秒时间戳兼容', () {
      const text = '导出于 2024 年\n'
          '2024-01-02 15:04 张三\n'
          '在吗\n';
      final r = parseWechatExport(text);
      expect(r.messages, hasLength(1));
      expect(r.messages[0].postedAt,
          DateTime(2024, 1, 2, 15, 4).millisecondsSinceEpoch);
      expect(r.errors, hasLength(1));
    });
  });

  group('decodeImportText', () {
    test('合法 UTF-8 正常解码；非法字节抛 FormatException', () {
      expect(decodeImportText(utf8.encode('你好')), '你好');
      // 0xC4 0xE3 是 GBK 的「你」，不是合法 UTF-8 序列
      expect(() => decodeImportText([0xC4, 0xE3]), throwsFormatException);
    });
  });

  group('importMessageOf', () {
    test('capture_type/import_source/虚拟包名/去重哈希稳定', () {
      const p = ParsedImportMessage(
          postedAt: 1000, sender: '张三', text: '你好', lineNo: 1);
      final m1 = importMessageOf(ImportSource.qq, '会话A', p, const Uuid());
      final m2 = importMessageOf(ImportSource.qq, '会话A', p, const Uuid());
      expect(m1.captureType, 'import');
      expect(m1.importSource, ImportSource.qq);
      expect(m1.packageName, 'import.qq');
      expect(m1.appName, 'QQ');
      expect(m1.title, '会话A');
      // content_hash 与消息 id 无关：同内容同时间 = 同哈希（去重键）
      expect(m1.contentHash, m2.contentHash);
      expect(m1.id, isNot(m2.id));
    });

    test('单条级会话（短信号码）优先于文件级会话名', () {
      const p = ParsedImportMessage(
          postedAt: 1000,
          sender: '10086',
          text: '余额提醒',
          lineNo: 0,
          conversation: '10086');
      final m = importMessageOf(ImportSource.sms, null, p, const Uuid());
      expect(m.title, '10086');
      expect(m.conversationTitle, '10086');
    });
  });
}

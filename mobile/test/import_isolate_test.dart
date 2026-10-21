import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/import_service.dart';

/// O05 回归：导出文本解析搬进后台 isolate 后，结果必须与同步纯函数**逐字段一致**。
///
/// 解析函数本身是纯 Dart（不碰 platform channel / BuildContext），返回结构
/// 只含 String/int，所以可以安全地跨 isolate 传递。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const qqText = '================================================================\n'
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

  const wechatText = '2024-01-02 15:04:05 张三\n'
      '在吗\n'
      '\n'
      '2024-01-02 15:05:00 我\n'
      '在的\n'
      '说吧\n';

  /// 断言两份解析结果在主 isolate 语义下完全相同。
  void expectSame(ImportParseResult a, ImportParseResult b, {required String why}) {
    expect(a.conversationTitle, b.conversationTitle, reason: why);
    expect(a.errors, b.errors, reason: why);
    expect(a.messages.length, b.messages.length, reason: why);
    for (var i = 0; i < a.messages.length; i++) {
      expect(a.messages[i].postedAt, b.messages[i].postedAt, reason: why);
      expect(a.messages[i].sender, b.messages[i].sender, reason: why);
      expect(a.messages[i].text, b.messages[i].text, reason: why);
      expect(a.messages[i].lineNo, b.messages[i].lineNo, reason: why);
      expect(a.messages[i].conversation, b.messages[i].conversation, reason: why);
    }
  }

  test('parseExportBySource 按来源分派到对应纯函数', () {
    final qq = parseExportBySource(ImportSource.qq, qqText);
    expect(qq.conversationTitle, '张三(12345678)');
    expect(qq.messages, hasLength(2));
    expectSame(qq, parseQqExport(qqText), why: 'QQ 分派应等价于 parseQqExport');

    final wx = parseExportBySource(ImportSource.wechat, wechatText);
    expect(wx.messages, hasLength(2));
    expectSame(wx, parseWechatExport(wechatText),
        why: '微信用微信解析器');

    // 未知来源按微信格式兜底（与 UI 侧历史行为一致）
    expectSame(parseExportBySource(ImportSource.sms, wechatText), wx,
        why: '未知来源兜底微信解析器');
  });

  test('isolate 解析结果与同步版一致（QQ / 微信）', () async {
    final qqSync = parseExportBySource(ImportSource.qq, qqText);
    final qqIsolate = await parseExportInIsolate(ImportSource.qq, qqText);
    expectSame(qqIsolate, qqSync, why: 'QQ 文本在 isolate 里解析结果必须一致');

    final wxSync = parseExportBySource(ImportSource.wechat, wechatText);
    final wxIsolate = await parseExportInIsolate(ImportSource.wechat, wechatText);
    expectSame(wxIsolate, wxSync, why: '微信文本在 isolate 里解析结果必须一致');
  });

  test('大文本（2000 条）在 isolate 里解析：条数/首尾字段正确', () async {
    final buf = StringBuffer();
    for (var i = 0; i < 2000; i++) {
      final mm = (i % 60).toString().padLeft(2, '0');
      final hh = (i % 24).toString().padLeft(2, '0');
      buf.write('2024-03-01 $hh:$mm:00 用户${i % 7}\n');
      buf.write('内容第 $i 条\n\n');
    }
    final text = buf.toString();

    final sync = parseExportBySource(ImportSource.wechat, text);
    expect(sync.messages, hasLength(2000));

    final viaIsolate = await parseExportInIsolate(ImportSource.wechat, text);
    expect(viaIsolate.messages, hasLength(2000), reason: '大文本跨 isolate 不得丢条');
    expect(viaIsolate.messages.first.sender, sync.messages.first.sender);
    expect(viaIsolate.messages.last.text, sync.messages.last.text);
    expect(viaIsolate.errors, isEmpty);
  });
}

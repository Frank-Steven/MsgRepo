import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/fold_markers.dart';

/// U14 回归：只剥离结尾的「(N条新消息)」，不动其他内容。
void main() {
  test('半角括号后缀被去掉', () {
    expect(stripFoldMarkers('没有op的美好世界(2条新消息)'), '没有op的美好世界');
    expect(stripFoldMarkers('这tm是哪个骑士(10条新消息)'), '这tm是哪个骑士');
  });

  test('全角括号同样处理', () {
    expect(stripFoldMarkers('南邮军事爱好者同盟（3条新消息）'), '南邮军事爱好者同盟');
  });

  test('括号内外的空格被容错', () {
    expect(stripFoldMarkers('测试群 ( 5 条新消息 ) '), '测试群');
  });

  test('没有标记时原样返回（含正文里的 [N条] 前缀）', () {
    expect(stripFoldMarkers('张三'), '张三');
    expect(stripFoldMarkers('[5条] 张三: 明天开会'), '[5条] 张三: 明天开会');
  });

  test('标记不在结尾时不动', () {
    expect(stripFoldMarkers('(2条新消息)在后面还有字'),
        '(2条新消息)在后面还有字');
  });

  test('整条只有标记时保留原文（不展示为空）', () {
    expect(stripFoldMarkers('(2条新消息)'), '(2条新消息)');
  });

  test('只去掉最后一处，多层嵌套保留内层', () {
    expect(stripFoldMarkers('群(1条新消息)(2条新消息)'), '群(1条新消息)');
  });

  test('空串安全', () {
    expect(stripFoldMarkers(''), '');
    expect(stripFoldMarkers('   '), '');
  });
}

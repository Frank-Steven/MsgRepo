import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:msgrepo_mobile/services/prompt_rules.dart';

/// U2 回归：规则表与自由文本的拼装、以及「只填一半的行不算规则」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('只有规则时按顺序列出', () {
    final out = composeCustomPrompt(
      rules: const [
        PromptRule(type: '广告', treatment: '当作营销，归为 junk'),
        PromptRule(type: '验证码', treatment: '忽略，不建任务'),
      ],
      freeText: '',
    );
    expect(out, contains('【分类处理规则】'));
    expect(out, contains('- 广告 → 当作营销，归为 junk'));
    expect(out, contains('- 验证码 → 忽略，不建任务'));
    expect(out.indexOf('广告'), lessThan(out.indexOf('验证码')), reason: '顺序即优先级');
    expect(out, isNot(contains('【其他要求】')));
  });

  test('只有自由文本时与原行为一致', () {
    final out = composeCustomPrompt(
      rules: const [],
      freeText: '  工作消息优先级调高  ',
    );
    expect(out, '【其他要求】\n工作消息优先级调高');
  });

  test('两者都有：规则在前、自由文本在后', () {
    final out = composeCustomPrompt(
      rules: const [PromptRule(type: '工作通知', treatment: '优先级调高')],
      freeText: '还能让 AI 识别学习委员是谁',
    );
    expect(out, contains('【分类处理规则】'));
    expect(out, contains('【其他要求】'));
    expect(out.indexOf('【分类处理规则】'), lessThan(out.indexOf('【其他要求】')));
    expect(out, contains('学习委员'));
  });

  test('只填一半的行被忽略（不污染提示词）', () {
    final out = composeCustomPrompt(
      rules: const [
        PromptRule(type: '只有类型', treatment: ''),
        PromptRule(type: '', treatment: '只有处理方式'),
        PromptRule(type: '短信', treatment: '  只留验证码  '),
      ],
      freeText: '',
    );
    expect(out, isNot(contains('只有类型')));
    expect(out, isNot(contains('只有处理方式')));
    expect(out, contains('- 短信 → 只留验证码'), reason: '两列都填才生效，且去首尾空格');
  });

  test('全空返回空串', () {
    expect(composeCustomPrompt(rules: const [], freeText: '   '), '');
  });

  test('JSON 往返保持字段', () {
    const r = PromptRule(type: '广告', treatment: '当作营销');
    final back = PromptRule.fromJson(r.toJson());
    expect(back.type, '广告');
    expect(back.treatment, '当作营销');
  });

  test('PromptRulesStore 存取往返，空行不落盘', () async {
    SharedPreferences.setMockInitialValues({});
    await PromptRulesStore.save([
      const PromptRule(type: '广告', treatment: '当作营销'),
      const PromptRule(type: '', treatment: ''),
    ]);
    final back = await PromptRulesStore.load();
    expect(back.length, 1, reason: '两列全空的行不保存');
    expect(back.first.type, '广告');
    expect(back.first.treatment, '当作营销');

    await PromptRulesStore.save([]);
    expect(await PromptRulesStore.load(), isEmpty);
  });

  test('存了坏 JSON 时返回空表且不抛异常', () async {
    SharedPreferences.setMockInitialValues({PromptRulesStore.key: '{bad json'});
    expect(await PromptRulesStore.load(), isEmpty);
  });
}
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 一条「消息类型 → 处理方式」规则（U2）。
///
/// 设计取舍：结构化规则与自由文本**并存**——规则解决「常见类型一眼说清」，
/// 自由文本保留合作者强调的「随便怎么描述都行」的自由度，两者都原样附在
/// 系统提示词之后。
class PromptRule {
  final String type;
  final String treatment;

  const PromptRule({required this.type, required this.treatment});

  /// 两列都非空才算有效规则（只填一半视为未完成，不计入提示词）。
  bool get isValid => type.trim().isNotEmpty && treatment.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {'type': type, 'treatment': treatment};

  factory PromptRule.fromJson(Map<String, dynamic> json) => PromptRule(
        type: (json['type'] as String?) ?? '',
        treatment: (json['treatment'] as String?) ?? '',
      );

  PromptRule copyWith({String? type, String? treatment}) => PromptRule(
        type: type ?? this.type,
        treatment: treatment ?? this.treatment,
      );
}

/// 规则持久化：JSON 存 SharedPreferences（键与 AiClient.keyPromptRules 对应）。
class PromptRulesStore {
  PromptRulesStore._();

  static const String key = 'custom_prompt_rules';

  static Future<List<PromptRule>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final e in list)
          if (e is Map) PromptRule.fromJson(e.cast<String, dynamic>()),
      ];
    } catch (_) {
      // 存的东西坏了就当没规则，不阻塞设置页
      return [];
    }
  }

  static Future<void> save(List<PromptRule> rules) async {
    final prefs = await SharedPreferences.getInstance();
    final list = [
      for (final r in rules)
        if (r.type.trim().isNotEmpty || r.treatment.trim().isNotEmpty) r.toJson(),
    ];
    if (list.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, jsonEncode(list));
    }
  }
}

/// 把「规则表 + 自由文本」拼成最终附加要求（纯函数，便于单测）。
///
/// 输出会被 AiClient/桌面端原样追加在系统提示词之后，因此这里只负责组织语义，
/// 不重复写「优先级高于默认规则」这类约束（那层包装由调用方统一加）。
String composeCustomPrompt({
  required List<PromptRule> rules,
  required String freeText,
}) {
  final valid = [
    for (final r in rules)
      if (r.isValid)
        PromptRule(type: r.type.trim(), treatment: r.treatment.trim()),
  ];
  final buf = StringBuffer();
  if (valid.isNotEmpty) {
    buf.writeln('【分类处理规则】按下面的消息类型匹配，命中后按对应处理方式执行（顺序即优先级）：');
    for (final r in valid) {
      buf.writeln('- ${r.type} → ${r.treatment}');
    }
  }
  final free = freeText.trim();
  if (free.isNotEmpty) {
    if (buf.isNotEmpty) buf.writeln();
    buf.writeln('【其他要求】');
    buf.write(free);
  }
  return buf.toString().trim();
}

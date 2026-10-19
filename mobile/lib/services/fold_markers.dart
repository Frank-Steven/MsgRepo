/// 折叠后缀剥离（U14）：QQ/微信把汇总通知的标题写成「群名(2条新消息)」，
/// 同一群名因此带着不同数字反复出现，列表很乱。
///
/// 设计：**只改展示，不改数据**——数据库里的标题保持原样（合作者要求原始消息
/// 可作为「参考和查证」），所有 UI 展示处调用本函数。
/// 只剥离**结尾**的「(N条新消息)」或「（N条新消息）」；正文里的「[N条]」前缀
/// 不动（那个更可能是真实内容）。
///
/// 2026-10-20 性能：正则提成顶层常量。原实现每次调用都现编译，
/// 消息列表滚动时每行标题 + 来源行各编译一次。
final RegExp _foldMarkerRe = RegExp(r'[（(]\s*\d+\s*条新消息\s*[）)]\s*$');

String stripFoldMarkers(String title) {
  final trimmed = title.trim();
  if (trimmed.isEmpty) return trimmed;
  if (!_foldMarkerRe.hasMatch(trimmed)) return trimmed;
  final out = trimmed.replaceFirst(_foldMarkerRe, '').trim();
  // 整条标题就只有这个标记时保留原文，避免展示成空
  return out.isEmpty ? trimmed : out;
}

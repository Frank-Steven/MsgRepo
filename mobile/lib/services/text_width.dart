import 'package:characters/characters.dart';

/// 任务名宽度计量（设计 §7.4）：按 grapheme cluster 遍历，
/// cluster 内全部 rune 为 ASCII（< 0x80）计 1，否则计 2
/// （全角/中文/emoji 均为 2）。
int displayWidth(String s) {
  var width = 0;
  for (final cluster in s.characters) {
    width += cluster.runes.every((r) => r < 0x80) ? 1 : 2;
  }
  return width;
}

/// 名称是否在宽度上限内（默认 36）。
bool withinWidthLimit(String s, [int max = 36]) => displayWidth(s) <= max;

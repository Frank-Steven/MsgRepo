import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/main.dart';

/// v2.6 回归：SnackBar 深色模式不再浅色底——深色主题用深色 surface +
/// 浅色文字/动作色；浅色主题保持 M3 反色底。
void main() {
  test('snackBarThemeFor：深色主题深色底 + 浅色文字', () {
    final cs = ColorScheme.fromSeed(
        seedColor: Colors.indigo, brightness: Brightness.dark);
    final t = snackBarThemeFor(cs);
    expect(t.backgroundColor, cs.surfaceContainerHigh);
    expect(t.contentTextStyle?.color, cs.onSurface);
    expect(t.actionTextColor, cs.primary);
    // 背景与文字必须有对比（深色底不配深色字）
    expect(t.backgroundColor, isNot(t.contentTextStyle?.color));
  });

  test('snackBarThemeFor：浅色主题保持反色底', () {
    final cs = ColorScheme.fromSeed(seedColor: Colors.indigo);
    final t = snackBarThemeFor(cs);
    expect(t.backgroundColor, cs.inverseSurface);
    expect(t.contentTextStyle?.color, cs.onInverseSurface);
    expect(t.actionTextColor, cs.inversePrimary);
  });
}

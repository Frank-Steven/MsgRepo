import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/app_ui_state.dart';

/// U19-B/C 回归：可见性判定 + 角标计数。
/// 后台或不在消息页时不应弹 AI 面板（改发系统通知）。
void main() {
  test('只有「前台 + 停在消息页」才算消息页可见', () {
    final s = AppUiState.instance;
    s.setTab(AppUiState.messagesTabIndex);
    s.setForeground(true);
    expect(s.messagesVisible, isTrue, reason: '前台 + 消息页');

    s.setForeground(false);
    expect(s.messagesVisible, isFalse, reason: '切到后台就不算可见');

    s.setForeground(true);
    s.setTab(0);
    expect(s.messagesVisible, isFalse, reason: '前台但在日程页也不算');

    s.setTab(AppUiState.messagesTabIndex);
    expect(s.messagesVisible, isTrue);
  });

  test('角标：负数归零，同值不重复通知', () {
    final b = MessageBadges.instance;
    var notified = 0;
    void listener() => notified++;
    b.addListener(listener);
    addTearDown(() => b.removeListener(listener));

    b.setPending(7);
    expect(b.pending, 7);
    final afterFirst = notified;
    b.setPending(7);
    expect(notified, afterFirst, reason: '同值不该触发重建');

    b.setPending(-3);
    expect(b.pending, 0);
  });
}

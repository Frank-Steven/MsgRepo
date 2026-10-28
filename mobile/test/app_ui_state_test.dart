import 'package:flutter_test/flutter_test.dart';
import 'package:msgrepo_mobile/services/app_ui_state.dart';

/// U19-B/C 回归：可见性判定 + 角标计数。
/// 后台或不在消息页时不应弹 AI 面板（改发系统通知）。
/// v3 阶段 3：消息/笔记合并进「库」页三分区，消息可见 = 前台 + 库 tab + 消息分区。
void main() {
  setUp(() {
    // 单例跨用例共享，先复位，避免污染其它测试文件
    AppUiState.instance.setTab(0);
    AppUiState.instance.setLibrarySection(AppUiState.librarySectionNotes);
    AppUiState.instance.setForeground(true);
    MessageBadges.instance.setPending(0);
  });

  test('只有「前台 + 库页的消息分区」才算消息页可见', () {
    final s = AppUiState.instance;
    s.openLibrary(AppUiState.librarySectionMessages);
    s.setForeground(true);
    expect(s.messagesVisible, isTrue, reason: '前台 + 库页消息分区');

    s.setForeground(false);
    expect(s.messagesVisible, isFalse, reason: '切到后台就不算可见');

    s.setForeground(true);
    s.setTab(AppUiState.tasksTabIndex);
    expect(s.messagesVisible, isFalse, reason: '前台但在日程页也不算');

    s.openLibrary(AppUiState.librarySectionMessages);
    expect(s.messagesVisible, isTrue);

    s.setLibrarySection(AppUiState.librarySectionFiles);
    expect(s.messagesVisible, isFalse, reason: '库页停在文件分区也不算');

    s.setLibrarySection(AppUiState.librarySectionMessages);
    expect(s.messagesVisible, isTrue);
  });

  test('openLibrary 同时切 tab 与分区；setTab 不丢分区记忆', () {
    final s = AppUiState.instance;
    s.openLibrary(AppUiState.librarySectionFiles);
    expect(s.tabIndex, AppUiState.libraryTabIndex);
    expect(s.librarySection, AppUiState.librarySectionFiles);

    s.setTab(AppUiState.tasksTabIndex);
    expect(s.librarySection, AppUiState.librarySectionFiles,
        reason: '切走再切回时应保留上次分区');

    s.setTab(AppUiState.libraryTabIndex);
    expect(s.librarySection, AppUiState.librarySectionFiles);
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

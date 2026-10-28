import 'package:flutter/foundation.dart';

/// 应用当前可见性（U19-C）：决定「自动触发时该不该弹面板」。
///
/// 后台或不在消息页时弹 Modal 面板毫无意义（用户看不到，还会在切回来时突兀出现），
/// 这种情况改用系统通知告知。
///
/// v3 阶段 6：底部导航为三主 Tab「库 / 任务 / 助理」，设置降级为
/// 助理页 AppBar 图标入口（design-v3 §0.2/§3.5）。
/// 「消息页可见」仍要求库页停在消息分区。
class AppUiState extends ChangeNotifier {
  AppUiState._();

  static final AppUiState instance = AppUiState._();

  /// HomeShell 里页面顺序：库 / 任务 / 助理
  static const int libraryTabIndex = 0;
  static const int tasksTabIndex = 1;
  static const int assistantTabIndex = 2;

  /// 底部导航/IndexedStack 的页面总数（下标 0..count-1）。
  static const int tabCount = 3;

  /// 库页（LibraryPage）三分区下标，与 library_page.dart 的 TabController 一致。
  static const int librarySectionNotes = 0;
  static const int librarySectionMessages = 1;
  static const int librarySectionFiles = 2;

  int _tabIndex = 0;
  bool _inForeground = true;

  /// 库页当前分区（其他 tab 时保留上次值，作为下次入库页的初始分区）。
  int _librarySection = librarySectionNotes;

  int get tabIndex => _tabIndex;
  bool get inForeground => _inForeground;
  int get librarySection => _librarySection;

  /// 用户此刻正看着消息页（前台 + 库 tab + 消息分区）。
  bool get messagesVisible =>
      _inForeground &&
      _tabIndex == libraryTabIndex &&
      _librarySection == librarySectionMessages;

  void setTab(int index) {
    if (_tabIndex == index) return;
    _tabIndex = index;
    notifyListeners();
  }

  /// 库页内部分区切换（LibraryPage 的 TabController 双向同步用）。
  void setLibrarySection(int section) {
    if (_librarySection == section) return;
    _librarySection = section;
    notifyListeners();
  }

  /// 别处请求「打开库页并定位到某分区」（如 AI 横幅 → 消息分区）。
  void openLibrary(int section) {
    final changed = _tabIndex != libraryTabIndex || _librarySection != section;
    _tabIndex = libraryTabIndex;
    _librarySection = section;
    if (changed) notifyListeners();
  }

  void setForeground(bool value) {
    if (_inForeground == value) return;
    _inForeground = value;
    notifyListeners();
  }
}

/// 消息页角标（U19-B）：底部导航「库」上的未处理条数。
/// 由 MessagesPage.reload 每次刷新后写入，后台也有值（页面常驻）。
class MessageBadges extends ChangeNotifier {
  MessageBadges._();

  static final MessageBadges instance = MessageBadges._();

  int _pending = 0;
  int get pending => _pending;

  void setPending(int value) {
    final v = value < 0 ? 0 : value;
    if (_pending == v) return;
    _pending = v;
    notifyListeners();
  }
}

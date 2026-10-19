import 'package:flutter/foundation.dart';

/// 应用当前可见性（U19-C）：决定「自动触发时该不该弹面板」。
///
/// 后台或不在消息页时弹 Modal 面板毫无意义（用户看不到，还会在切回来时突兀出现），
/// 这种情况改用系统通知告知。
class AppUiState extends ChangeNotifier {
  AppUiState._();

  static final AppUiState instance = AppUiState._();

  /// HomeShell 里页面顺序：日程 / 待办 / 笔记 / 消息 / 设置
  static const int messagesTabIndex = 3;

  int _tabIndex = 0;
  bool _inForeground = true;

  int get tabIndex => _tabIndex;
  bool get inForeground => _inForeground;

  /// 用户此刻正看着消息页（前台 + 当前 tab = 消息）。
  bool get messagesVisible => _inForeground && _tabIndex == messagesTabIndex;

  void setTab(int index) {
    if (_tabIndex == index) return;
    _tabIndex = index;
    notifyListeners();
  }

  void setForeground(bool value) {
    if (_inForeground == value) return;
    _inForeground = value;
    notifyListeners();
  }
}

/// 消息页角标（U19-B）：底部导航「消息」上的未处理条数。
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

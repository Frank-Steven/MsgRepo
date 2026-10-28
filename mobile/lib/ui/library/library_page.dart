import 'package:flutter/material.dart';

import '../../services/app_ui_state.dart';
import '../messages/messages_page.dart';
import '../notes/notes_page.dart';
import 'files_page.dart';

/// v3 阶段 3「库」页容器（design-v3 §3.1）：顶部三分区切换「笔记 / 消息 / 文件」。
///
/// 只聚合不搬迁：笔记/消息分区直接嵌入原位目录的 NotesPage / MessagesPage
/// （各自保留自己的 AppBar 与交互），文件区为本目录新增的 FilesPage。
/// 当前分区与 [AppUiState.librarySection] 双向同步，别处（如 AI 横幅）
/// 可通过 AppUiState.openLibrary 定位分区。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => LibraryPageState();
}

class LibraryPageState extends State<LibraryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  final _notesKey = GlobalKey<NotesPageState>();
  final _messagesKey = GlobalKey<MessagesPageState>();
  final _filesKey = GlobalKey<FilesPageState>();

  @override
  void initState() {
    super.initState();
    _tab = TabController(
      length: 3,
      vsync: this,
      initialIndex: AppUiState.instance.librarySection,
    );
    _tab.addListener(_onTabChanged);
    AppUiState.instance.addListener(_syncSectionFromState);
  }

  @override
  void dispose() {
    AppUiState.instance.removeListener(_syncSectionFromState);
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    super.dispose();
  }

  /// 用户切分区 → 回写 AppUiState（messagesVisible 等判定依赖它）。
  void _onTabChanged() {
    if (_tab.indexIsChanging) return;
    AppUiState.instance.setLibrarySection(_tab.index);
  }

  /// 外部（AppUiState.openLibrary）请求定位分区 → 驱动 TabController。
  void _syncSectionFromState() {
    if (!mounted) return;
    final target = AppUiState.instance.librarySection;
    if (target != _tab.index) _tab.animateTo(target);
  }

  /// 供底部导航切页时调用：刷新当前分区。
  Future<void> reload() async {
    switch (_tab.index) {
      case AppUiState.librarySectionNotes:
        await _notesKey.currentState?.reload();
      case AppUiState.librarySectionMessages:
        await reloadMessages();
      case AppUiState.librarySectionFiles:
        await _filesKey.currentState?.reload();
    }
  }

  /// AI 横幅等需要单独刷消息列表的入口。
  Future<void> reloadMessages() async =>
      _messagesKey.currentState?.reload();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        // 页面本身不带 SafeArea（与 HomeShell 一致），TabBar 自己避开状态栏。
        SafeArea(
          bottom: false,
          child: Material(
            color: cs.surface,
            child: TabBar(
              controller: _tab,
              tabs: const [
                Tab(text: '笔记'),
                Tab(text: '消息'),
                Tab(text: '文件'),
              ],
            ),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: [
              NotesPage(key: _notesKey),
              MessagesPage(key: _messagesKey),
              FilesPage(key: _filesKey),
            ],
          ),
        ),
      ],
    );
  }
}

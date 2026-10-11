import 'dart:async';

import 'package:uuid/uuid.dart';

/// 撤销队列条目（设计 §6）。逆操作闭包由 register 时提供，不对外暴露。
class UndoEntry {
  final String id;
  final String label;
  final DateTime enqueuedAt;

  const UndoEntry({
    required this.id,
    required this.label,
    required this.enqueuedAt,
  });
}

/// 撤销服务：纯内存单例，不落盘（重启后队列清空可接受，撤销窗口只有 10 秒）。
///
/// 栈语义：后来者先撤；被撤销项永久移除不做重做；撤销后再入队即天然
/// 截断分叉（撤销只弹栈、入队即截断，满足"分叉丢弃另一分支"）。
class UndoService {
  UndoService._();

  static final UndoService instance = UndoService._();

  static const _ttl = Duration(seconds: 10);

  final _entries = <_UndoItem>[];
  final _changesController = StreamController<void>.broadcast();

  /// 队列任何变化广播（供 SnackBar 刷新）。
  Stream<void> get changes => _changesController.stream;

  /// 栈顶有效项（无则 null）。
  UndoEntry? get latest => _entries.isEmpty ? null : _entries.last.entry;

  /// 入栈顶，10 秒过期自动丢弃并广播。
  void register(
      {required String label, required Future<void> Function() undo}) {
    final item = _UndoItem(
      entry: UndoEntry(
          id: const Uuid().v4(), label: label, enqueuedAt: DateTime.now()),
      undo: undo,
    );
    item.timer = Timer(_ttl, () {
      _entries.remove(item);
      _changesController.add(null);
    });
    _entries.add(item);
    _changesController.add(null);
  }

  /// 弹栈顶、取消其 Timer、执行逆操作闭包、广播；空队列 no-op。
  Future<void> undoLatest() async {
    if (_entries.isEmpty) return;
    final item = _entries.removeLast();
    item.timer?.cancel();
    try {
      await item.undo();
    } finally {
      _changesController.add(null);
    }
  }

  void clear() {
    for (final item in _entries) {
      item.timer?.cancel();
    }
    if (_entries.isNotEmpty) {
      _entries.clear();
      _changesController.add(null);
    }
  }
}

class _UndoItem {
  final UndoEntry entry;
  final Future<void> Function() undo;
  Timer? timer;

  _UndoItem({required this.entry, required this.undo});
}

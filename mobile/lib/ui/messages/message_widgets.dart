import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../services/undo_service.dart';

/// 未处理分组键（设计 §5.1）。
const String kGroupPending = 'pending';

/// 分组展示顺序：未处理 → 红 → 黄 → 绿 → 垃圾。
const List<String> kGroupOrder = [
  kGroupPending,
  MessagePriority.red,
  MessagePriority.yellow,
  MessagePriority.green,
  MessagePriority.junk,
];

/// 分组键规则：垃圾/红/黄/绿按 priority，其余（含 processed 且 priority=none）归未处理。
String messageGroupKey(Message m) {
  switch (m.priority) {
    case MessagePriority.junk:
      return MessagePriority.junk;
    case MessagePriority.red:
    case MessagePriority.yellow:
    case MessagePriority.green:
      return m.priority;
    default:
      return kGroupPending;
  }
}

String messageGroupLabel(String key) => switch (key) {
      kGroupPending => '未处理',
      MessagePriority.red => '红',
      MessagePriority.yellow => '黄',
      MessagePriority.green => '绿',
      MessagePriority.junk => '垃圾',
      _ => key,
    };

/// 已评估三色的圆点颜色；未处理/垃圾返回 null（用空心圆点）。
Color? messageGroupDotColor(String key) => switch (key) {
      MessagePriority.red => Colors.red,
      MessagePriority.yellow => Colors.amber,
      MessagePriority.green => Colors.green,
      _ => null,
    };

/// 今天显示 HH:mm，否则 MM-dd HH:mm。
String formatMessageTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(d.hour)}:${two(d.minute)}';
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return hm;
  }
  return '${two(d.month)}-${two(d.day)} $hm';
}

/// 操作成功后的撤销 SnackBar（设计 §6）：「{label} · 10 秒内可撤销」。
/// 撤销注册由调用方在调用本函数前完成。
void showUndoSnackBar(BuildContext context, String label,
    {VoidCallback? onUndone}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('$label · 10 秒内可撤销'),
        duration: const Duration(seconds: 10),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () async {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            await UndoService.instance.undoLatest();
            onUndone?.call();
          },
        ),
      ),
    );
}

/// 左滑露出的块状菜单按钮定义。
class SwipeAction {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const SwipeAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
}

/// 自实现的左滑块状菜单：手势平移行内容露出右侧圆角色块按钮，
/// 松手超过阈值吸住，否则弹回。
class SwipeActionRow extends StatefulWidget {
  final Widget child;
  final List<SwipeAction> actions;
  final bool swipeEnabled;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const SwipeActionRow({
    super.key,
    required this.child,
    this.actions = const [],
    this.swipeEnabled = true,
    this.onTap,
    this.onLongPress,
  });

  @override
  State<SwipeActionRow> createState() => _SwipeActionRowState();
}

class _SwipeActionRowState extends State<SwipeActionRow>
    with SingleTickerProviderStateMixin {
  static const _actionWidth = 68.0;

  late final AnimationController _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 180));
  Animation<double>? _anim;
  double _drag = 0;
  double _startDrag = 0;

  double get _maxDrag => widget.actions.length * _actionWidth;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onAnim() {
    if (mounted) setState(() => _drag = _anim!.value);
  }

  void _snap(double target) {
    _anim?.removeListener(_onAnim);
    _anim = Tween<double>(begin: _drag, end: target)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _anim!.addListener(_onAnim);
    _ctrl.forward(from: 0);
  }

  void _handleTap() {
    if (_drag > 0) {
      _snap(0);
    } else {
      widget.onTap?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSwipe = widget.swipeEnabled && widget.actions.isNotEmpty;
    final content = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handleTap,
      onLongPress: widget.onLongPress,
      onHorizontalDragStart:
          canSwipe ? (_) => _startDrag = _drag : null,
      onHorizontalDragUpdate: canSwipe
          ? (d) => setState(() =>
              _drag = (_startDrag - d.delta.dx).clamp(0.0, _maxDrag).toDouble())
          : null,
      onHorizontalDragEnd: canSwipe
          ? (_) => _snap(_drag > _maxDrag * 0.35 ? _maxDrag : 0)
          : null,
      child: widget.child,
    );
    if (!canSwipe) return content;
    return ClipRect(
      child: Stack(
        children: [
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: Row(
              children: [
                for (final a in widget.actions)
                  _ActionBlock(
                    action: a,
                    width: _actionWidth,
                    onTap: () {
                      _snap(0);
                      a.onTap();
                    },
                  ),
              ],
            ),
          ),
          Transform.translate(
            offset: Offset(-_drag, 0),
            child: content,
          ),
        ],
      ),
    );
  }
}

class _ActionBlock extends StatelessWidget {
  final SwipeAction action;
  final double width;
  final VoidCallback onTap;

  const _ActionBlock(
      {required this.action, required this.width, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
        child: Material(
          color: action.color,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(action.icon, color: Colors.white, size: 20),
                const SizedBox(height: 4),
                Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 消息行内容：左侧标记 + 标题/摘要/来源 + 右侧时间。
/// 垃圾消息整行渲染为降饱和灰色块 + 标题划线。
class MessageTile extends StatelessWidget {
  final Message message;
  final bool selecting;
  final bool selected;
  final bool swipeEnabled;
  final List<SwipeAction> actions;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const MessageTile({
    super.key,
    required this.message,
    this.selecting = false,
    this.selected = false,
    this.swipeEnabled = true,
    this.actions = const [],
    this.onTap,
    this.onLongPress,
  });

  Widget _marker(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dotColor = messageGroupDotColor(messageGroupKey(message));
    final Widget dot = dotColor == null
        ? Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: cs.outline, width: 1.5),
            ),
          )
        : Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
          );
    if (message.linkedTaskId == null) return dot;
    return SizedBox(
      width: 20,
      height: 20,
      child: Stack(
        children: [
          Positioned(left: 0, top: 0, child: dot),
          Positioned(
            right: 0,
            bottom: 0,
            child: Icon(Icons.task_alt, size: 12, color: cs.primary),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isJunk = message.priority == MessagePriority.junk;
    final titleStyle = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w500,
      color: isJunk ? cs.outline : null,
      decoration: isJunk ? TextDecoration.lineThrough : null,
    );
    final subStyle = TextStyle(fontSize: 13, color: cs.onSurfaceVariant);

    final sourceLabel = StringBuffer(
        message.appName?.isNotEmpty == true
            ? message.appName!
            : message.packageName);
    if (message.conversationTitle?.isNotEmpty == true) {
      sourceLabel.write(' · ${message.conversationTitle}');
    }

    Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _marker(context),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        message.title.isEmpty ? '(无标题)' : message.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: titleStyle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(formatMessageTime(message.postedAt), style: subStyle),
                  ],
                ),
                if (message.body.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    message.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: subStyle,
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  sourceLabel.toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (selecting)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 20,
                color: selected ? cs.primary : cs.outline,
              ),
            ),
        ],
      ),
    );

    if (isJunk) {
      row = Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: row,
      );
    }

    return SwipeActionRow(
      actions: actions,
      swipeEnabled: swipeEnabled && !selecting,
      onTap: onTap,
      onLongPress: onLongPress,
      child: row,
    );
  }
}

/// 吸顶分组头（设计 §5.1）：始终显示在组首，点击折叠/展开。
class MessageGroupHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String groupKey;
  final int count;
  final bool collapsed;
  final VoidCallback onToggle;

  MessageGroupHeaderDelegate({
    required this.groupKey,
    required this.count,
    required this.collapsed,
    required this.onToggle,
  });

  static const double kHeight = 36;

  @override
  double get minExtent => kHeight;

  @override
  double get maxExtent => kHeight;

  @override
  bool shouldRebuild(MessageGroupHeaderDelegate oldDelegate) =>
      groupKey != oldDelegate.groupKey ||
      count != oldDelegate.count ||
      collapsed != oldDelegate.collapsed;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final cs = Theme.of(context).colorScheme;
    final dotColor = messageGroupDotColor(groupKey);
    return Material(
      color: cs.surface,
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              if (dotColor != null) ...[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle, color: dotColor),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                messageGroupLabel(groupKey),
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface),
              ),
              const SizedBox(width: 8),
              Text('$count',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              const Spacer(),
              Icon(
                collapsed ? Icons.expand_more : Icons.expand_less,
                size: 20,
                color: cs.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 多选模式底部图标按钮条的一项。
class SelectionAction {
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;

  const SelectionAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
  });
}

/// 多选模式底部图标按钮条（设计 §5.1）。
class SelectionActionBar extends StatelessWidget {
  final List<SelectionAction> actions;

  const SelectionActionBar({super.key, required this.actions});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (final a in actions)
                IconButton(
                  tooltip: a.tooltip,
                  onPressed: a.enabled ? a.onTap : null,
                  icon: Icon(a.icon),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

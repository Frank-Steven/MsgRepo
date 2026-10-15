import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../../models/message.dart';
import '../../services/undo_service.dart';
import '../shared/app_icon.dart';

/// 未处理分组键（设计 §5.1）。
const String kGroupPending = 'pending';

/// 「已完成」筛选键（v2.4）：不占分组，选中时额外显示关联任务已完成的消息。
const String kFilterDone = 'done';

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
      kFilterDone => '已完成',
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

/// 操作成功后的撤销 SnackBar（设计 §6，v2.1）：「{label}」+ 撤销按钮，
/// 时长 4 秒、不排队（先收起当前条）。撤销注册由调用方在调用本函数前完成。
void showUndoSnackBar(BuildContext context, String label,
    {VoidCallback? onUndone}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(label),
        duration: const Duration(seconds: 4),
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

/// 左滑块状菜单（设计 §5.1，v2.1 重做）：基于 flutter_slidable。
/// - 轻扫 ≥40dp 或快速甩动即展开，松手吸附全展/全关（openThreshold 压到
///   40dp 以内；甩动由库的 OpeningGesture 直接展开）；
/// - 展开后点动作块必触发（动作块由库渲染在行内容之外的独立层）；
/// - 展开后点击行内容或反扫收起；
/// - 不设 groupTag / SlidableAutoCloseBehavior：多行各自独立展开，互不干扰。
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
  static const _actionWidth = 72.0;
  static const _openThresholdDp = 40.0;

  late final SlidableController _controller = SlidableController(this);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    // 展开时点击行内容 = 收起（不触发行点击）；收起时正常行点击
    if (_controller.ratio != 0) {
      _controller.close();
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
      child: widget.child,
    );
    if (!canSwipe) return content;
    final width = MediaQuery.sizeOf(context).width;
    return Slidable(
      controller: _controller,
      endActionPane: ActionPane(
        motion: const BehindMotion(),
        extentRatio:
            (widget.actions.length * _actionWidth / width).clamp(0.1, 1.0),
        openThreshold: (_openThresholdDp / width).clamp(0.05, 0.9),
        children: [
          for (final a in widget.actions)
            CustomSlidableAction(
              backgroundColor: Colors.transparent,
              padding: EdgeInsets.zero,
              onPressed: (_) => a.onTap(),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
                child: Container(
                  width: double.infinity,
                  height: double.infinity,
                  decoration: BoxDecoration(
                    color: a.color,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(a.icon, color: Colors.white, size: 20),
                      const SizedBox(height: 4),
                      Text(
                        a.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      child: content,
    );
  }
}

/// 消息卡片（v2.4 卡片化）：左侧标记 + 标题/摘要/来源（含应用图标）+ 右侧时间。
/// 点击卡片行内展开/收起全文（选择模式下点击 = 勾选）。
/// 垃圾消息卡片降饱和灰底 + 标题划线；关联任务已完成的消息标题划线变淡。
class MessageTile extends StatefulWidget {
  final Message message;
  final bool selecting;
  final bool selected;
  final bool swipeEnabled;
  final List<SwipeAction> actions;

  /// 关联任务已完成（v2.4「已完成」筛选）：标题划线降色。
  final bool linkedTaskDone;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const MessageTile({
    super.key,
    required this.message,
    this.selecting = false,
    this.selected = false,
    this.swipeEnabled = true,
    this.actions = const [],
    this.linkedTaskDone = false,
    this.onTap,
    this.onLongPress,
  });

  @override
  State<MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<MessageTile> {
  bool _expanded = false;

  void _handleTap() {
    if (widget.selecting) {
      widget.onTap?.call();
    } else {
      setState(() => _expanded = !_expanded);
    }
  }

  Widget _marker(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dotColor = messageGroupDotColor(messageGroupKey(widget.message));
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
    if (widget.message.linkedTaskId == null) return dot;
    return SizedBox(
      width: 20,
      height: 20,
      child: Stack(
        children: [
          Positioned(left: 0, top: 0, child: dot),
          Positioned(
            right: 0,
            bottom: 0,
            child: Icon(Icons.task_alt,
                size: 12,
                color: widget.linkedTaskDone ? cs.outline : cs.primary),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final message = widget.message;
    final isJunk = message.priority == MessagePriority.junk;
    final titleStyle = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w500,
      color: isJunk
          ? cs.outline
          : (widget.linkedTaskDone ? cs.onSurfaceVariant : null),
      decoration:
          (isJunk || widget.linkedTaskDone) ? TextDecoration.lineThrough : null,
    );
    final subStyle = TextStyle(fontSize: 13, color: cs.onSurfaceVariant);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: isJunk ? cs.surfaceContainerHighest : cs.surfaceContainerLow,
      child: SwipeActionRow(
        actions: widget.actions,
        swipeEnabled: widget.swipeEnabled && !widget.selecting,
        onTap: _handleTap,
        onLongPress: widget.onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                            maxLines: _expanded ? null : 1,
                            overflow:
                                _expanded ? null : TextOverflow.ellipsis,
                            style: titleStyle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(formatMessageTime(message.postedAt),
                            style: subStyle),
                      ],
                    ),
                    if (message.body.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        message.body,
                        maxLines: _expanded ? null : 2,
                        overflow: _expanded ? null : TextOverflow.ellipsis,
                        style: subStyle,
                      ),
                    ],
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        AppIcon(
                            packageName: message.packageName,
                            appName: message.appName,
                            size: 14),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            (message.appName?.isNotEmpty == true
                                    ? message.appName!
                                    : message.packageName) +
                                (message.conversationTitle?.isNotEmpty == true
                                    ? ' · ${message.conversationTitle}'
                                    : ''),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12, color: cs.onSurfaceVariant),
                          ),
                        ),
                        if (_expanded)
                          Icon(Icons.expand_less,
                              size: 16, color: cs.onSurfaceVariant),
                      ],
                    ),
                  ],
                ),
              ),
              if (widget.selecting)
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 2),
                  child: Icon(
                    widget.selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: widget.selected ? cs.primary : cs.outline,
                  ),
                ),
            ],
          ),
        ),
      ),
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

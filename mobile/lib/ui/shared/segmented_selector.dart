import 'package:flutter/material.dart';

/// 共用分段选择器（设计 §10.1，v2.3 修订 12）：日程粒度段选、待办尺度页签条、
/// 任务编辑器类型/优先级、设置页选项统一使用。
///
/// - 选中态只改底色不改宽度；
/// - 两端选中块的圆角与容器圆角匹配（v2.3 修复：原直角底色盖住容器圆角），
///   中间段保持直角；
/// - [equalWidth] = true 时固定总宽均分；false 时每段固定 [itemWidth]、
///   横向可滚动，选中段自动滚动到可见（与 PageView 联动用）；
/// - [dots] 可选优先级色点（编辑器优先级）；[badges] 可选计数徽标
///   （仅数字，0 不显示，待办页签用）。
class SegmentedSelector<T> extends StatelessWidget {
  final List<T> values;
  final List<String> labels;
  final List<Color?> dots;

  /// 各段计数徽标；null 或对应项 <= 0 时不显示。
  final List<int>? badges;
  final T selected;
  final ValueChanged<T> onChanged;
  final double height;
  final bool equalWidth;
  final double itemWidth;
  final ScrollController? scrollController;

  const SegmentedSelector({
    super.key,
    required this.values,
    required this.labels,
    this.dots = const [],
    this.badges,
    required this.selected,
    required this.onChanged,
    this.height = 34,
    this.equalWidth = true,
    this.itemWidth = 60,
    this.scrollController,
  }) : assert(values.length == labels.length);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = height / 2;
    final selectedIdx = values.indexOf(selected);

    final segments = Container(
      height: height,
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: equalWidth ? MainAxisSize.max : MainAxisSize.min,
        children: [
          for (var i = 0; i < values.length; i++) ...[
            if (i > 0) Container(width: 1, color: scheme.outline),
            _segment(scheme, i, radius),
          ],
        ],
      ),
    );

    if (equalWidth) return segments;

    // 可滚动模式：选中段滚动到可见（页签条与 PageView 联动）
    if (selectedIdx >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final c = scrollController;
        if (c == null || !c.hasClients) return;
        final target =
            (itemWidth * selectedIdx + itemWidth / 2 - c.position.viewportDimension / 2)
                .clamp(c.position.minScrollExtent, c.position.maxScrollExtent);
        if ((c.offset - target).abs() > 1) {
          c.animateTo(target,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut);
        }
      });
    }
    return SingleChildScrollView(
      controller: scrollController,
      scrollDirection: Axis.horizontal,
      child: segments,
    );
  }

  Widget _segment(ColorScheme scheme, int i, double radius) {
    final isSelected = values[i] == selected;
    final badge = (badges != null && i < badges!.length) ? badges![i] : 0;
    // 两端选中块的圆角与容器匹配，中间段直角
    final segmentRadius = !isSelected
        ? null
        : BorderRadius.horizontal(
            left: i == 0 ? Radius.circular(radius) : Radius.zero,
            right:
                i == values.length - 1 ? Radius.circular(radius) : Radius.zero,
          );
    final content = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(values[i]),
      child: Container(
        width: equalWidth ? null : itemWidth,
        height: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color:
              isSelected ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: segmentRadius,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (i < dots.length && dots[i] != null) ...[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dots[i],
                ),
              ),
              const SizedBox(width: 6),
            ],
            Flexible(
              fit: FlexFit.loose,
              child: Text(
                labels[i],
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  fontSize: 13,
                  color: isSelected
                      ? scheme.onSecondaryContainer
                      : scheme.onSurface,
                ),
              ),
            ),
            if (badge > 0) ...[
              const SizedBox(width: 3),
              Text(
                '$badge',
                style: TextStyle(
                  fontSize: 10,
                  color: isSelected
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    return equalWidth ? Expanded(child: content) : content;
  }
}

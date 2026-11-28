import 'package:flutter/material.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/ui/theme.dart';

/// 平台分段控件（桌面）。
///
/// 与 DTV 的胶囊 tab 的区别（UI-DESIGN §2）：
/// - 选中态是 `raised` 底 + 1px 蓝描边，**不填充荧光色**
/// - 高度 32px，紧凑；含「全部」一项，减少一层维度
class PlatformSegments extends StatelessWidget {
  const PlatformSegments({
    super.key,
    required this.platforms,
    required this.selected,
    required this.onSelected,
    this.includeAll = true,
  });

  final List<LivePlatform> platforms;

  /// null = 全部
  final LivePlatform? selected;
  final ValueChanged<LivePlatform?> onSelected;
  final bool includeAll;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: TallySpace.xs,
      runSpacing: TallySpace.xs,
      children: [
        if (includeAll)
          _PlatformChip(
            label: '全部',
            selected: selected == null,
            onTap: () => onSelected(null),
          ),
        for (final platform in platforms)
          _PlatformChip(
            label: platform.label,
            selected: selected == platform,
            onTap: () => onSelected(platform),
          ),
      ],
    );
  }
}

class _PlatformChip extends StatefulWidget {
  const _PlatformChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_PlatformChip> createState() => _PlatformChipState();
}

class _PlatformChipState extends State<_PlatformChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final decoration = widget.selected
        ? TallyDecor.selected
        : (_hovered
            ? BoxDecoration(
                color: TallyColors.raised,
                borderRadius: BorderRadius.circular(TallyRadius.card),
                border: Border.all(color: Colors.transparent),
              )
            : TallyDecor.idle);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: TallySpace.md),
          alignment: Alignment.center,
          decoration: decoration,
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
              color: widget.selected
                  ? TallyColors.textPrimary
                  : TallyColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 平台下拉（手机）。
///
/// 手机上 4–5 个分段太窄，收成下拉；选中项用同样配色。
class PlatformDropdown extends StatelessWidget {
  const PlatformDropdown({
    super.key,
    required this.platforms,
    required this.selected,
    required this.onSelected,
    this.includeAll = true,
  });

  final List<LivePlatform> platforms;
  final LivePlatform? selected;
  final ValueChanged<LivePlatform?> onSelected;
  final bool includeAll;

  @override
  Widget build(BuildContext context) {
    final label = selected?.label ?? '全部';
    return PopupMenuButton<Object>(
      tooltip: '切换平台',
      color: TallyColors.raised,
      onSelected: (value) {
        onSelected(value is LivePlatform ? value : null);
      },
      itemBuilder: (context) => [
        if (includeAll)
          PopupMenuItem<Object>(
            value: '',
            child: Text('全部', style: _itemStyle(selected == null)),
          ),
        for (final platform in platforms)
          PopupMenuItem<Object>(
            value: platform,
            child: Text(
              platform.label,
              style: _itemStyle(selected == platform),
            ),
          ),
      ],
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: TallySpace.sm + 2),
        decoration: TallyDecor.card(color: TallyColors.surface),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TallyType.subtitle),
            const SizedBox(width: 2),
            const Icon(Icons.expand_more,
                size: 16, color: TallyColors.textSecondary),
          ],
        ),
      ),
    );
  }

  TextStyle _itemStyle(bool selected) => TextStyle(
        fontSize: 13,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        color: selected ? TallyColors.textPrimary : TallyColors.textSecondary,
      );
}

/// 面包屑的一段。
class Crumb {
  const Crumb({required this.label, this.onTap});

  final String label;

  /// 末项传 null（不可点）。
  final VoidCallback? onTap;
}

/// 面包屑（分区下钻用）。
///
/// 用它替代 DTV 的「三行分类堆叠」：一行就能表达层级，且随时可回退。
class Breadcrumb extends StatelessWidget {
  const Breadcrumb({super.key, required this.items});

  final List<Crumb> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final children = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final isLast = i == items.length - 1;
      children.add(
        GestureDetector(
          onTap: item.onTap,
          child: MouseRegion(
            cursor: item.onTap == null
                ? SystemMouseCursors.basic
                : SystemMouseCursors.click,
            child: Text(
              item.label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isLast ? FontWeight.w600 : FontWeight.w400,
                color: isLast
                    ? TallyColors.textPrimary
                    : (item.onTap == null
                        ? TallyColors.textTertiary
                        : TallyColors.textSecondary),
              ),
            ),
          ),
        ),
      );
      if (!isLast) {
        children.add(
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              '›',
              style: TextStyle(fontSize: 13, color: TallyColors.textTertiary),
            ),
          ),
        );
      }
    }
    return Row(children: children);
  }
}

/// 分区条目（56px）。
class CategoryTile extends StatefulWidget {
  const CategoryTile({
    super.key,
    required this.name,
    this.liveCount = 0,
    this.icon = Icons.grid_view_outlined,
    this.onTap,
  });

  final String name;

  /// 在播数量，0 时不显示。
  final int liveCount;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  State<CategoryTile> createState() => _CategoryTileState();
}

class _CategoryTileState extends State<CategoryTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: TallySpace.md),
          decoration: BoxDecoration(
            color: _hovered ? TallyColors.raised : Colors.transparent,
            borderRadius: BorderRadius.circular(TallyRadius.card),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 20, color: TallyColors.textSecondary),
              const SizedBox(width: TallySpace.md),
              Expanded(
                child: Text(
                  widget.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    color: TallyColors.textPrimary,
                  ),
                ),
              ),
              if (widget.liveCount > 0) ...[
                Text(
                  '${widget.liveCount}',
                  style: TallyType.numberSmall.copyWith(
                    color: TallyColors.textTertiary,
                  ),
                ),
                const SizedBox(width: 4),
                const Text('在播', style: TallyType.meta),
                const SizedBox(width: TallySpace.sm),
              ],
              const Icon(Icons.chevron_right,
                  size: 18, color: TallyColors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

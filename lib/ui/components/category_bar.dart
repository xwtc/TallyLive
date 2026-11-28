import 'package:flutter/material.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/ui/theme.dart';

/// 分区选择栏（对齐 DTV 的 CategoryBar）。
///
/// 为什么之前"分区显示不全"：把全部分组的二级分区拍平成一条长横滑，
/// 既没有分组信息、又长到没法看。DTV 的做法是：
///
/// ```
/// 第一行  一级分组：文字 tab + 下划线指示器
/// 第二行  二级分区：chip 横滑；**溢出时出现「全部 ⌄」**
///         点它 → 浮层网格，显示该分组全部分区（带数量）
/// ```
///
/// 浮层用 [OverlayEntry] 实现：铺一层点击遮罩 + 在按钮下方定位面板，
/// 点遮罩关闭。不引入额外依赖。
class CategoryBar extends StatefulWidget {
  const CategoryBar({
    super.key,
    required this.groups,
    required this.groupId,
    required this.categoryId,
    required this.onSelectGroup,
    required this.onSelectCategory,
    this.compact = false,
    this.onSubscribe,
    this.subscribed = false,
  });

  final List<CategoryGroup> groups;
  final String? groupId;
  final String? categoryId;
  final ValueChanged<String> onSelectGroup;
  final ValueChanged<String> onSelectCategory;

  /// 列表滚动后收成面包屑（给内容让高度）。
  final bool compact;

  /// 订阅当前分区（先占位，接上订阅页后生效）。
  final VoidCallback? onSubscribe;
  final bool subscribed;

  @override
  State<CategoryBar> createState() => _CategoryBarState();
}

class _CategoryBarState extends State<CategoryBar> {
  final ScrollController _categoryScroll = ScrollController();
  final GlobalKey _moreKey = GlobalKey();
  OverlayEntry? _entry;
  bool _overflow = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureOverflow());
  }

  @override
  void didUpdateWidget(covariant CategoryBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换分组 / 分区数量变化后重新量一次；并回到行首
    if (oldWidget.groupId != widget.groupId ||
        oldWidget.groups != widget.groups) {
      _closePanel();
      if (_categoryScroll.hasClients) _categoryScroll.jumpTo(0);
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureOverflow());
    }
  }

  @override
  void dispose() {
    _closePanel();
    _categoryScroll.dispose();
    super.dispose();
  }

  /// 溢出判定用真实测量（对齐 DTV 的 `scrollWidth - clientWidth > 2`）。
  void _measureOverflow() {
    if (!mounted || !_categoryScroll.hasClients) return;
    final overflow = _categoryScroll.position.maxScrollExtent > 2;
    if (overflow != _overflow) setState(() => _overflow = overflow);
  }

  CategoryGroup? get _activeGroup {
    if (widget.groups.isEmpty) return null;
    for (final group in widget.groups) {
      if (group.id == widget.groupId) return group;
    }
    return widget.groups.first;
  }

  List<Category> get _categories => _activeGroup?.categories ?? const [];

  String get _activeCategoryName {
    for (final category in _categories) {
      if (category.id == widget.categoryId) return category.name;
    }
    return _categories.isNotEmpty ? _categories.first.name : '全部';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.groups.isEmpty) return const SizedBox.shrink();

    if (widget.compact) return _buildCompact();

    return Column(
      children: [
        _buildGroupRow(),
        _buildCategoryRow(),
      ],
    );
  }

  /// 滚动后的紧凑态：一行面包屑 + 「全部分区」。
  Widget _buildCompact() {
    return SizedBox(
      height: 34,
      child: Row(
        children: [
          const SizedBox(width: TallySpace.md),
          GestureDetector(
            onTap: _openPanelFromBreadcrumb,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Row(
                children: [
                  Text(_activeGroup?.name ?? '分区', style: TallyType.meta),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Text('›', style: TallyType.meta),
                  ),
                  Text(
                    _activeCategoryName,
                    style: const TextStyle(
                      fontSize: 12,
                      color: TallyColors.textPrimary,
                    ),
                  ),
                  const Icon(Icons.expand_more,
                      size: 14, color: TallyColors.textPrimary),
                ],
              ),
            ),
          ),
          const Spacer(),
          if (widget.onSubscribe != null)
            TextButton(
              onPressed: widget.onSubscribe,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 26),
                padding: const EdgeInsets.symmetric(horizontal: TallySpace.sm),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                widget.subscribed ? '已订阅' : '订阅分区',
                style: const TextStyle(fontSize: 11, color: TallyColors.signalBlue),
              ),
            ),
          const SizedBox(width: TallySpace.sm),
        ],
      ),
    );
  }

  /// 一级分组：文字 tab + 下划线指示器。
  Widget _buildGroupRow() {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: TallySpace.md),
        itemCount: widget.groups.length,
        separatorBuilder: (_, __) => const SizedBox(width: TallySpace.md),
        itemBuilder: (context, index) {
          final group = widget.groups[index];
          final active = group.id == (_activeGroup?.id);
          return GestureDetector(
            onTap: () => widget.onSelectGroup(group.id),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    group.name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      color: active
                          ? TallyColors.textPrimary
                          : TallyColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 5),
                  // 下划线指示器（不是整块高亮，视觉更安静）
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    height: 2,
                    width: active ? 18 : 0,
                    decoration: BoxDecoration(
                      color: TallyColors.signalBlue,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 二级分区：chip 横滑 + 溢出「全部」+ 订阅。
  Widget _buildCategoryRow() {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              controller: _categoryScroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: TallySpace.md),
              itemCount: _categories.length,
              separatorBuilder: (_, __) => const SizedBox(width: TallySpace.xs),
              itemBuilder: (context, index) {
                final category = _categories[index];
                final active = category.id == widget.categoryId;
                return Center(
                  child: GestureDetector(
                    onTap: () => widget.onSelectCategory(category.id),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 140),
                        height: 28,
                        padding:
                            const EdgeInsets.symmetric(horizontal: TallySpace.md),
                        alignment: Alignment.center,
                        decoration: active
                            ? TallyDecor.selected
                            : BoxDecoration(
                                color: TallyColors.surface,
                                borderRadius:
                                    BorderRadius.circular(TallyRadius.card),
                                border: Border.all(color: TallyColors.hairline),
                              ),
                        child: Text(
                          category.name,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight:
                                active ? FontWeight.w600 : FontWeight.w400,
                            color: active
                                ? TallyColors.textPrimary
                                : TallyColors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_overflow)
            Padding(
              padding: const EdgeInsets.only(right: TallySpace.xs),
              child: GestureDetector(
                key: _moreKey,
                onTap: _togglePanel,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    height: 28,
                    padding:
                        const EdgeInsets.symmetric(horizontal: TallySpace.sm),
                    decoration: BoxDecoration(
                      color: TallyColors.raised,
                      borderRadius: BorderRadius.circular(TallyRadius.card),
                      border: Border.all(color: TallyColors.hairline),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Text(
                          '全部',
                          style: TextStyle(
                            fontSize: 12,
                            color: TallyColors.textPrimary,
                          ),
                        ),
                        Icon(Icons.expand_more,
                            size: 14, color: TallyColors.textSecondary),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (widget.onSubscribe != null)
            Padding(
              padding: const EdgeInsets.only(right: TallySpace.md),
              child: GestureDetector(
                onTap: widget.onSubscribe,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    height: 28,
                    padding:
                        const EdgeInsets.symmetric(horizontal: TallySpace.sm),
                    decoration: BoxDecoration(
                      color: widget.subscribed
                          ? TallyColors.raised
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(TallyRadius.card),
                      border: Border.all(
                        color: widget.subscribed
                            ? TallyColors.signalBlue
                            : TallyColors.hairline,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          widget.subscribed ? Icons.check : Icons.add,
                          size: 13,
                          color: TallyColors.signalBlue,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          widget.subscribed ? '已订阅' : '订阅',
                          style: const TextStyle(
                            fontSize: 11,
                            color: TallyColors.signalBlue,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _togglePanel() {
    if (_entry != null) {
      _closePanel();
    } else {
      _openPanel();
    }
  }

  void _openPanelFromBreadcrumb() => _openPanel();

  void _openPanel() {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    // 面板定位：优先贴着「全部」按钮，其次贴着一级分组行下方
    Rect? anchor;
    final moreBox = _moreKey.currentContext?.findRenderObject() as RenderBox?;
    if (moreBox != null && moreBox.hasSize) {
      anchor = moreBox.localToGlobal(Offset.zero) & moreBox.size;
    }
    final screenWidth = MediaQuery.sizeOf(context).width;
    final width = screenWidth < 640 ? screenWidth - 24 : 560.0;
    final left = anchor == null
        ? TallySpace.md
        : (anchor.right - width).clamp(TallySpace.md, screenWidth - width - TallySpace.md);
    final top = (anchor?.bottom ?? 90) + 6;

    _entry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // 点击外部关闭
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closePanel,
              child: ColoredBox(color: Colors.black.withValues(alpha: 0.28)),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            width: width,
            child: _buildPanel(),
          ),
        ],
      ),
    );
    overlay.insert(_entry!);
  }

  void _closePanel() {
    // OverlayEntry 被重复 remove 会抛异常（切分区时 didUpdate 与点击遮罩
    // 可能同时触发），这里做幂等保护。
    final entry = _entry;
    _entry = null;
    if (entry == null) return;
    try {
      entry.remove();
    } catch (_) {
      // 已被移除（overlay 随页面销毁），忽略
    }
  }

  /// 「全部」浮层面板（对齐 DTV 的 CategoryBar 浮层）：
  ///
  /// ```
  /// 网游竞技                              119 个分区
  /// ┌────────────┬────────────┬────────────┬────────────┬────────────┐
  /// │ 英雄联盟   │ 热门游戏   │ 三角洲行动 │ 穿越火线   │ 无畏契约   │
  /// └────────────┴────────────┴────────────┴────────────┴────────────┘
  /// ```
  /// 五列等宽胶囊，选中项用蓝描边（不填充高饱和色）。
  Widget _buildPanel() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 460),
      decoration: BoxDecoration(
        color: TallyColors.surface,
        borderRadius: BorderRadius.circular(TallyRadius.card),
        border: Border.all(color: TallyColors.hairline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题行：分组名 + 数量
          Padding(
            padding: const EdgeInsets.fromLTRB(
                TallySpace.lg, TallySpace.md, TallySpace.lg, TallySpace.sm),
            child: Row(
              children: [
                Text(_activeGroup?.name ?? '分区',
                    style: TallyType.nickname.copyWith(fontSize: 15)),
                const Spacer(),
                Text('${_categories.length} 个分区', style: TallyType.meta),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(TallySpace.md),
              child: _PanelGrid(
                categories: _categories,
                activeId: widget.categoryId,
                onPick: (category) {
                  widget.onSelectCategory(category.id);
                  _closePanel();
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 面板网格：固定 5 列等宽胶囊（窄屏降为 3 列）。
class _PanelGrid extends StatelessWidget {
  const _PanelGrid({
    required this.categories,
    required this.activeId,
    required this.onPick,
  });

  final List<Category> categories;
  final String? activeId;
  final ValueChanged<Category> onPick;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 420 ? 3 : 5;
        const gap = TallySpace.sm;
        final itemWidth =
            (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (var i = 0; i < categories.length; i++)
              SizedBox(
                width: itemWidth,
                child: _PanelReveal(
                  index: i,
                  child: _PanelChip(
                    label: categories[i].name,
                    active: categories[i].id == activeId,
                    onTap: () => onPick(categories[i]),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
/// 面板里的一个分区。
///
/// 视觉规则（去掉 DTV 那种"文字 + 下划线"的样子）：
/// - 默认：无边框、透明底，只显示文字（安静）
/// - hover：抬起一档底色 + 细描边（明确的可点反馈）
/// - selected：强调色浅底 + 强调色描边 + 加粗
class _PanelChip extends StatefulWidget {
  const _PanelChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_PanelChip> createState() => _PanelChipState();
}

class _PanelChipState extends State<_PanelChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final Color background;
    final Color borderColor;
    if (widget.active) {
      background = TallyColors.accentSoft;
      borderColor = TallyColors.signalBlue;
    } else if (_hovered) {
      background = TallyColors.raised;
      borderColor = TallyColors.hairline;
    } else {
      background = Colors.transparent;
      borderColor = Colors.transparent;
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: TallyDuration.fast,
          curve: Curves.easeOut,
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: TallySpace.sm),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(TallyRadius.pill),
            border: Border.all(color: borderColor),
          ),
          child: Text(
            widget.label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // 明确不要下划线（DTV 面板是带下划线的文字，观感偏旧）
            style: TextStyle(
              fontSize: 12,
              decoration: TextDecoration.none,
              fontWeight:
                  widget.active ? FontWeight.w600 : FontWeight.w400,
              color: widget.active
                  ? TallyColors.accentInk
                  : (_hovered
                      ? TallyColors.textPrimary
                      : TallyColors.textSecondary),
            ),
          ),
        ),
      ),
    );
  }
}

/// 面板项的入场动效：淡入 + 轻微上移，按索引错峰（最多前 12 项）。
class _PanelReveal extends StatelessWidget {
  const _PanelReveal({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final start = (index % 12) * 0.03;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Interval(start, 1, curve: Curves.easeOutCubic),
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, (1 - value) * 6),
          child: child,
        ),
      ),
      child: child,
    );
  }
}
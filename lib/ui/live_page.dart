import 'package:flutter/material.dart';
import 'package:tallylive/core/live_repository.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/ui/components/navigation.dart';
import 'package:tallylive/ui/components/section_header.dart';
import 'package:tallylive/ui/components/states.dart';
import 'package:tallylive/ui/components/streamer_card.dart';
import 'package:tallylive/ui/components/streamer_row.dart';
import 'package:tallylive/ui/player_entry_page.dart';
import 'package:tallylive/ui/theme.dart';

/// 「直播」Tab —— 首页。
///
/// 结构：
/// ```
/// [平台分段 / 下拉]                     [搜索]
/// 分区 chip 横滑（一级分组 → 二级分区扁平化，只显示前 N 个）
/// ● 正在直播 N
/// 精选：桌面网格 / 手机列表，无限滚动 + 下拉刷新
/// ```
///
/// 数据全部来自真实接口（[LiveRepository] → PlatformLiveRepository），
/// 只有 B站/斗鱼 实现了列表；其它平台由 [LiveRepository.supportedPlatforms] 过滤。
class LivePage extends StatefulWidget {
  const LivePage({super.key, this.repository});

  /// 允许注入（测试 / 以后接缓存层）。
  final LiveRepository? repository;

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  late final LiveRepository _repo = widget.repository ?? createLiveRepository();

  late LivePlatform _platform = _repo.supportedPlatforms.first;

  final ScrollController _scroll = ScrollController();
  final ScrollController _categoryScroll = ScrollController();

  List<CategoryGroup> _groups = const [];
  String? _categoryId;

  final List<Streamer> _items = [];
  int _page = 0;
  bool _hasMore = true;

  bool _booting = true;
  bool _loadingMore = false;
  String? _error;

  /// 数据源给的一句话说明（如 B 站被风控时显示推荐列表）。
  String _note = '';

  /// 下拉刷新时保留旧内容，避免闪烁。
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _bootstrap();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _categoryScroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final remaining =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 480) _loadMore();
  }

  /// 首次/切平台：先拉分区，再拉第一页。
  Future<void> _bootstrap({bool keepContent = false}) async {
    setState(() {
      _booting = !keepContent;
      _refreshing = keepContent;
      _error = null;
      if (!keepContent) {
        _groups = const [];
        _items.clear();
        _page = 0;
        _hasMore = true;
        _categoryId = null;
      }
    });

    try {
      final groups = await _repo.fetchCategories(_platform);
      if (!mounted) return;
      final firstCategory = groups.isNotEmpty && groups.first.categories.isNotEmpty
          ? groups.first.categories.first.id
          : null;
      setState(() {
        _groups = groups;
        _categoryId = firstCategory;
      });
      await _loadFirstPage();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyError(error);
        _booting = false;
        _refreshing = false;
      });
    }
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _items.clear();
      _page = 0;
      _hasMore = true;
    });
    await _fetchPage(1);
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _booting || _refreshing) return;
    await _fetchPage(_page + 1);
  }

  Future<void> _fetchPage(int page) async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final result = await _repo.fetchLiveList(
        platform: _platform,
        categoryId: _categoryId,
        page: page,
      );
      if (!mounted) return;
      setState(() {
        if (page == 1) _items.clear();
        _items.addAll(result.items);
        _page = page;
        _hasMore = result.hasMore;
        _loadingMore = false;
        _booting = false;
        _refreshing = false;
        _error = null;
        if (page == 1) _note = result.note;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _booting = false;
        _refreshing = false;
        // 只有第一页失败才整页报错；翻页失败静默（保留已有内容）
        if (page == 1) _error = _friendlyError(error);
      });
    }
  }

  String _friendlyError(Object error) {
    final text = error.toString();
    if (text.contains('UnimplementedError')) return '该平台的列表接口尚未接入';
    if (text.contains('-352')) return 'B 站要求人机校验，请稍后重试';
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }

  void _selectPlatform(LivePlatform platform) {
    if (platform == _platform) return;
    setState(() => _platform = platform);
    _bootstrap();
  }

  void _selectCategory(String categoryId) {
    if (categoryId == _categoryId) return;
    setState(() => _categoryId = categoryId);
    _bootstrap(keepContent: true);
  }

  Future<void> _openStreamer(Streamer streamer) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerEntryPage(
          platform: streamer.platform,
          roomId: streamer.id,
          fallbackTitle: streamer.title.isEmpty
              ? streamer.nickname
              : '${streamer.nickname} · ${streamer.title}',
          repository: _repo,
        ),
      ),
    );
  }

  /// 当前可切换的分区（把分组里的二级分区扁平化）。
  List<Category> get _flatCategories {
    final out = <Category>[];
    for (final group in _groups) {
      out.addAll(group.categories);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isCompact = width < TallyBreakpoints.compact;

    return Scaffold(
      backgroundColor: TallyColors.base,
      appBar: AppBar(
        backgroundColor: TallyColors.surface,
        title: const Text('TallyLive · 在播'),
        titleTextStyle: TallyType.pageTitle.copyWith(fontSize: 16),
        actions: [
          if (!isCompact)
            Padding(
              padding: const EdgeInsets.only(right: TallySpace.sm),
              child: PlatformSegments(
                platforms: _repo.supportedPlatforms,
                selected: _platform,
                onSelected: (platform) {
                  if (platform != null) _selectPlatform(platform);
                },
                includeAll: false,
              ),
            ),
          IconButton(
            tooltip: '刷新',
            onPressed: _booting ? null : () => _bootstrap(keepContent: true),
            icon: const Icon(Icons.refresh, size: 20),
            color: TallyColors.textSecondary,
          ),
          const SizedBox(width: TallySpace.sm),
        ],
      ),
      body: Column(
        children: [
          if (isCompact)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  TallySpace.md, TallySpace.sm, TallySpace.md, 0),
              child: Row(
                children: [
                  PlatformDropdown(
                    platforms: _repo.supportedPlatforms,
                    selected: _platform,
                    onSelected: (platform) {
                      if (platform != null) _selectPlatform(platform);
                    },
                    includeAll: false,
                  ),
                ],
              ),
            ),
          _buildCategoryBar(),
          TallyHeader(liveCount: _items.where((s) => s.isLive).length),
          if (_note.isNotEmpty) _buildNote(),
          Expanded(child: _buildBody(isCompact)),
        ],
      ),
    );
  }

  /// 数据源降级提示（例如 B 站列表被风控、当前显示全站推荐）。
  ///
  /// 用 stateAmber 而不是红/蓝：这是"能用但降级了"的功能性状态，
  /// 不是错误（红）也不是可交互（蓝）。
  Widget _buildNote() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          horizontal: TallySpace.md, vertical: TallySpace.sm),
      color: TallyColors.stateAmber.withValues(alpha: 0.10),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 14, color: TallyColors.stateAmber),
          const SizedBox(width: TallySpace.sm),
          Expanded(
            child: Text(
              _note,
              style: const TextStyle(
                fontSize: 11,
                color: TallyColors.stateAmber,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
  /// 分区横滑条。加载中显示骨架，避免出现又消失的布局跳动。
  Widget _buildCategoryBar() {
    final categories = _flatCategories;
    return SizedBox(
      height: 44,
      child: _bootCategoriesPending
          ? ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                  horizontal: TallySpace.md, vertical: TallySpace.sm),
              itemCount: 6,
              separatorBuilder: (_, __) => const SizedBox(width: TallySpace.sm),
              itemBuilder: (_, __) =>
                  const SkeletonBox(width: 64, height: 24, radius: 12),
            )
          : ListView.separated(
              controller: _categoryScroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                  horizontal: TallySpace.md, vertical: TallySpace.sm),
              itemCount: categories.length,
              separatorBuilder: (_, __) => const SizedBox(width: TallySpace.xs),
              itemBuilder: (context, index) {
                final category = categories[index];
                return _CategoryChip(
                  label: category.name,
                  selected: category.id == _categoryId,
                  onTap: () => _selectCategory(category.id),
                );
              },
            ),
    );
  }

  bool get _bootCategoriesPending => _booting && _groups.isEmpty;

  Widget _buildBody(bool isCompact) {
    final Widget child;
    if (_booting) {
      child = _buildSkeleton(isCompact);
    } else if (_error != null) {
      child = ErrorState(
        message: _error!,
        onRetry: () => _bootstrap(),
      );
    } else if (_items.isEmpty) {
      child = const EmptyState(
        icon: Icons.live_tv_outlined,
        message: '这个分区现在没有在播的房间\n换一个分区看看',
      );
    } else {
      child = _buildContent(isCompact);
    }

    // 状态切换统一淡入，避免骨架 → 内容硬切
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: KeyedSubtree(
        key: ValueKey<String>(
          '${_booting ? 'boot' : _error != null ? 'err' : _items.isEmpty ? 'empty' : 'list'}-$_platform-$_categoryId',
        ),
        child: child,
      ),
    );
  }

  Widget _buildSkeleton(bool isCompact) {
    if (isCompact) {
      return ListView.separated(
        padding: const EdgeInsets.all(TallySpace.md),
        itemCount: 7,
        separatorBuilder: (_, __) => const SizedBox(height: TallySpace.xs),
        itemBuilder: (_, __) => const SkeletonRow(),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(TallySpace.md),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 320,
        mainAxisSpacing: TallySpace.lg,
        crossAxisSpacing: TallySpace.md,
        childAspectRatio: 1.32,
      ),
      itemCount: 8,
      itemBuilder: (_, __) => const SkeletonCard(),
    );
  }

  Widget _buildContent(bool isCompact) {
    return RefreshIndicator(
      color: TallyColors.signalBlue,
      backgroundColor: TallyColors.raised,
      onRefresh: () => _bootstrap(keepContent: true),
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(
            child: SectionHeader(
              title: '平台精选',
              count: _items.length,
              trailingLabel: '刷新',
              onTrailingTap: () => _bootstrap(keepContent: true),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: TallySpace.md),
            sliver: isCompact
                ? SliverList.separated(
                    itemCount: _items.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: TallySpace.xs),
                    itemBuilder: (context, index) => Reveal(
                      index: index,
                      child: StreamerRow(
                        streamer: _items[index],
                        onTap: () => _openStreamer(_items[index]),
                      ),
                    ),
                  )
                : SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 320,
                      mainAxisSpacing: TallySpace.lg,
                      crossAxisSpacing: TallySpace.md,
                      childAspectRatio: 1.32,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => Reveal(
                        index: index,
                        child: StreamerCard(
                          streamer: _items[index],
                          onTap: () => _openStreamer(_items[index]),
                        ),
                      ),
                      childCount: _items.length,
                    ),
                  ),
          ),
          SliverToBoxAdapter(
            child: _loadingMore
                ? const LoadingMore()
                : (_hasMore
                    ? const SizedBox(height: 32)
                    : const Padding(
                        padding:
                            EdgeInsets.symmetric(vertical: TallySpace.lg),
                        child: Center(
                          child: Text('没有更多了', style: TallyType.meta),
                        ),
                      )),
          ),
        ],
      ),
    );
  }
}

/// 入场动效：淡入 + 轻微上移，按索引错开，形成"自上而下铺开"的节奏。
class Reveal extends StatelessWidget {
  const Reveal({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final start = (index % 12) * 0.04;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 340),
      curve: Interval(start, 1, curve: Curves.easeOutCubic),
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * 10),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// 分区 chip（横滑条里的一个）。
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: TallySpace.md),
          alignment: Alignment.center,
          decoration: selected
              ? TallyDecor.selected
              : BoxDecoration(
                  color: TallyColors.surface,
                  borderRadius: BorderRadius.circular(TallyRadius.card),
                  border: Border.all(color: TallyColors.hairline),
                ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected
                  ? TallyColors.textPrimary
                  : TallyColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

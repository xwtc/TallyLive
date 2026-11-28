import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tallylive/core/follows.dart';
import 'package:tallylive/core/feed_ui.dart';
import 'package:tallylive/core/live_repository.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/core/player_session.dart';
import 'package:tallylive/ui/components/category_bar.dart';
import 'package:tallylive/ui/shell/navbar.dart';
import 'package:tallylive/ui/components/states.dart';
import 'package:tallylive/ui/components/streamer_card.dart';
import 'package:tallylive/ui/components/streamer_row.dart';
import 'package:tallylive/ui/theme.dart';

/// 「直播」页面内容（壳层提供的顶栏/侧栏在外层）。
///
/// 结构：
/// ```
/// [平台分段 / 下拉]
/// 分区栏（一级分组 + 二级分区 + 溢出「全部」浮层）
/// ● 正在直播 N
/// 精选：桌面网格 / 手机列表
/// ```
class LivePage extends StatefulWidget {
  const LivePage({super.key, this.repository});

  final LiveRepository? repository;

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  late final LiveRepository _repo = widget.repository ?? createLiveRepository();

  late LivePlatform _platform =
      FeedUi.instance.platform ?? _repo.supportedPlatforms.first;

  final ScrollController _scroll = ScrollController();

  List<CategoryGroup> _groups = const [];
  String? _groupId;
  String? _categoryId;

  final List<Streamer> _items = [];
  int _page = 0;
  bool _hasMore = true;

  bool _booting = true;
  bool _loadingMore = false;
  String? _error;
  bool _refreshing = false;

  /// 数据源降级说明（如 B 站被风控时显示推荐列表）。
  String _note = '';

  /// 列表滚动后把分区栏收成一行面包屑，给内容让高度（对齐 DTV 的 compact）。
  bool _compactCategories = false;

  @override
  void initState() {
    super.initState();
    FeedUi.instance.ensurePlatforms(_repo.supportedPlatforms);
    _platform = FeedUi.instance.platform ?? _repo.supportedPlatforms.first;
    FeedUi.instance.addListener(_onFeedChanged);
    // 关注状态变化（例如在播放层里点了星标）要立刻反映到卡片
    FollowStore.instance.addListener(_onFollowChanged);
    _scroll.addListener(_onScroll);
    _bootstrap();
  }

  /// 顶栏切换平台后，内容区跟着换数据（同一个状态源，避免 tab 与列表不一致）。
  void _onFeedChanged() {
    final next = FeedUi.instance.platform;
    if (next == null || next == _platform) return;
    setState(() => _platform = next);
    _bootstrap();
  }

  /// 关注列表变化后重建，保证卡片上的星标与侧栏一致。
  void _onFollowChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    FeedUi.instance.removeListener(_onFeedChanged);
    FollowStore.instance.removeListener(_onFollowChanged);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final offset = _scroll.position.pixels;
    final compact = offset > 120;
    if (compact != _compactCategories) {
      setState(() => _compactCategories = compact);
    }
    final remaining = _scroll.position.maxScrollExtent - offset;
    if (remaining < 480) _loadMore();
  }

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
        _groupId = null;
        _categoryId = null;
      }
    });

    try {
      final groups = await _repo.fetchCategories(_platform);
      if (!mounted) return;

      // 保留用户已选的分组/分区，只有不存在时才回退默认
      var groupId = _groupId;
      var categoryId = _categoryId;

      final groupExists = groups.any(
        (group) => group.id == groupId && group.categories.isNotEmpty,
      );
      if (!groupExists) groupId = groups.isNotEmpty ? groups.first.id : null;

      final currentGroup = groups.firstWhere(
        (group) => group.id == groupId,
        orElse: () => groups.isEmpty
            ? const CategoryGroup(id: '', name: '', categories: [])
            : groups.first,
      );
      final categoryExists =
          currentGroup.categories.any((category) => category.id == categoryId);
      if (!categoryExists) {
        categoryId = currentGroup.categories.isNotEmpty
            ? currentGroup.categories.first.id
            : null;
      }

      setState(() {
        _groups = groups;
        _groupId = groupId;
        _categoryId = categoryId;
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
        if (page == 1) _error = _friendlyError(error);
      });
    }
  }

  /// 网格列数：按最小卡片宽 220 排，留出 gap。
  int _gridColumnsFor(double width) {
    const padding = TallySpace.md * 2;
    final usable = width - padding;
    final columns =
        ((usable + TallySize.gridGap) / (TallySize.cardMin + TallySize.gridGap))
            .floor();
    return columns.clamp(1, 8);
  }

  /// 网格行高：封面 16:9 + 信息区（头像 32 / 上 13 / 下 15 / 两行文字 ≈ 78）。
  double _gridExtentFor(double width) {
    const padding = TallySpace.md * 2;
    final columns = _gridColumnsFor(width);
    final itemWidth = (width - padding - TallySize.gridGap * (columns - 1)) /
        columns;
    return itemWidth * 9 / 16 + 78;
  }
  String _friendlyError(Object error) {
    final text = error.toString();
    if (text.contains('UnimplementedError')) return '该平台的列表接口尚未接入';
    if (text.contains('-352')) return 'B 站要求人机校验，请稍后重试';
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }

  void _selectGroup(String groupId) {
    if (groupId == _groupId) return;
    final group = _groups.firstWhere(
      (item) => item.id == groupId,
      orElse: () => const CategoryGroup(id: '', name: '', categories: []),
    );
    setState(() {
      _groupId = groupId;
      _categoryId =
          group.categories.isNotEmpty ? group.categories.first.id : null;
      _compactCategories = false;
    });
    _loadFirstPage();
  }

  void _selectCategory(String categoryId) {
    if (categoryId == _categoryId) return;
    setState(() {
      _categoryId = categoryId;
      _compactCategories = false;
    });
    _loadFirstPage();
  }

  /// 打开直播间：不再 push 新页面，而是交给壳层的播放层
  /// （这样侧栏还在，可以在播放中换台；返回时列表也不会重建）。
  void _openStreamer(Streamer streamer) {
    PlayerSession.instance.open(PlayerTarget(
      platform: streamer.platform,
      roomId: streamer.id,
      title: streamer.title.isEmpty
          ? streamer.nickname
          : '${streamer.nickname} · ${streamer.title}',
    ));
  }

  Future<void> _toggleFollow(Streamer streamer) async {
    final followed = await FollowStore.instance.toggle(
      platform: streamer.platform,
      roomId: streamer.id,
      nickname: streamer.nickname,
      title: streamer.title,
      avatar: streamer.avatar,
      isLive: streamer.isLive,
      viewers: streamer.viewers,
    );
    if (!mounted) return;
    // 卡片上的关注按钮状态来自 FollowStore，切完要重建一次
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(followed ? '已关注' : '已取消关注')),
    );
  }

  Future<void> _showStreamerMenu(Streamer streamer) async {
    final followed =
        FollowStore.instance.isFollowing(streamer.platform, streamer.id);
    final choice = await showMenu<String>(
      context: context,
      color: TallyColors.raised,
      items: [
        PopupMenuItem(
          value: 'follow',
          child: Text(followed ? '取消关注' : '关注'),
        ),
        const PopupMenuItem(value: 'copy', child: Text('复制房间号')),
      ],
    );
    if (choice == null) return;
    if (choice == 'follow') {
      await _toggleFollow(streamer);
    } else if (choice == 'copy') {
      await Clipboard.setData(ClipboardData(text: streamer.id));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已复制房间号 ${streamer.id}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isCompact = width < TallyBreakpoints.compact;

    return Column(
      children: [
        // 桌面：平台切换在顶栏（同一个 FeedUi）、刷新在「平台精选」标题右侧，
        // 这里不再单独占一行（之前那行只剩一个刷新图标，看着很空）。
        // 窄屏：顶栏没有分段控件，用下拉切换平台，刷新跟着它放一起。
        if (isCompact)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                TallySpace.page, TallySpace.sm, TallySpace.page, 0),
            child: Row(
              children: [
                const NavbarPlatformDropdown(),
                const Spacer(),
                IconButton(
                  tooltip: '刷新',
                  onPressed:
                      _booting ? null : () => _bootstrap(keepContent: true),
                  icon: const Icon(Icons.refresh, size: 18),
                  color: TallyColors.textSecondary,
                ),
              ],
            ),
          ),        // 分区栏（两行，溢出有「全部」）
        if (_booting && _groups.isEmpty)
          _categorySkeleton()
        else
          CategoryBar(
            groups: _groups,
            groupId: _groupId,
            categoryId: _categoryId,
            onSelectGroup: _selectGroup,
            onSelectCategory: _selectCategory,
            compact: _compactCategories,
          ),
        if (_note.isNotEmpty) _buildNote(),
        Expanded(
          // 内容区 + 右下角悬浮刷新（图标按钮，不占行）
          child: Stack(
            children: [
              LayoutBuilder(
                builder: (context, constraints) =>
                    _buildBody(isCompact, constraints.maxWidth),
              ),
              Positioned(
                right: TallySpace.lg,
                bottom: TallySpace.lg,
                child: _FloatingRefreshButton(
                  busy: _booting || _refreshing,
                  onTap: () => _bootstrap(keepContent: true),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _categorySkeleton() {
    return SizedBox(
      height: 78,
      child: Column(
        children: [
          _skeletonRow(height: 38),
          _skeletonRow(height: 40),
        ],
      ),
    );
  }

  Widget _skeletonRow({required double height}) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
            horizontal: TallySpace.md, vertical: TallySpace.xs),
        itemCount: 6,
        separatorBuilder: (_, __) => const SizedBox(width: TallySpace.sm),
        itemBuilder: (_, __) =>
            const SkeletonBox(width: 64, height: 22, radius: 6),
      ),
    );
  }

  /// 数据源降级提示（如 B 站列表被风控、当前显示全站推荐）。
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

  Widget _buildBody(bool isCompact, double width) {
    final Widget child;
    if (_booting) {
      child = _buildSkeleton(isCompact);
    } else if (_error != null) {
      child = ErrorState(message: _error!, onRetry: () => _bootstrap());
    } else if (_items.isEmpty) {
      child = const EmptyState(
        icon: Icons.live_tv_outlined,
        message: '这个分区现在没有在播的房间\n换一个分区看看',
      );
    } else {
      child = _buildContent(isCompact, width);
    }

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
        maxCrossAxisExtent: TallySize.cardMin,
        mainAxisSpacing: TallySize.gridGap,
        crossAxisSpacing: TallySize.gridGap,
        childAspectRatio: 0.72,
      ),
      itemCount: 8,
      itemBuilder: (_, __) => const SkeletonCard(),
    );
  }

  Widget _buildContent(bool isCompact, double width) {
    return RefreshIndicator(
      color: TallyColors.signalBlue,
      backgroundColor: TallyColors.raised,
      onRefresh: () => _bootstrap(keepContent: true),
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          // 不再显示「平台精选」标题：去掉这行文字后内容直接从分区栏开始，
          // 更紧凑；刷新改到右下角悬浮图标按钮。
          const SliverToBoxAdapter(child: SizedBox(height: TallySpace.sm)),
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
                        onSecondaryTap: () => _showStreamerMenu(_items[index]),
                      ),
                    ),
                  )
                : SliverGrid(
                    // 行高 = 封面(16:9) + 信息区固定高度，按当前列宽精确算：
                    // 用 childAspectRatio 估算会因为列宽取整而留白或溢出。
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _gridColumnsFor(width),
                      mainAxisSpacing: TallySize.gridGap,
                      crossAxisSpacing: TallySize.gridGap,
                      mainAxisExtent: _gridExtentFor(width),
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final streamer = _items[index];
                        return Reveal(
                          index: index,
                          child: StreamerCard(
                            streamer: streamer,
                            followed: FollowStore.instance.isFollowing(
                                streamer.platform, streamer.id),
                            onToggleFollow: () => _toggleFollow(streamer),
                            onTap: () => _openStreamer(streamer),
                            onSecondaryTap: () => _showStreamerMenu(streamer),
                          ),
                        );
                      },
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
                        padding: EdgeInsets.symmetric(vertical: TallySpace.lg),
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

/// 入场动效：淡入 + 轻微上移，按索引错开。
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
/// 右下角悬浮刷新按钮（图标，不占行）。
///
/// 之前刷新是「平台精选」标题右侧的文字按钮，但那行标题已按要求去掉；
/// 现在做成悬浮图标：不占布局、不抢视线，加载中显示转圈并禁用点击。
class _FloatingRefreshButton extends StatefulWidget {
  const _FloatingRefreshButton({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback onTap;

  @override
  State<_FloatingRefreshButton> createState() => _FloatingRefreshButtonState();
}

class _FloatingRefreshButtonState extends State<_FloatingRefreshButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '刷新',
      child: MouseRegion(
        cursor: widget.busy ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.busy ? null : widget.onTap,
          child: AnimatedContainer(
            duration: TallyDuration.fast,
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hovered ? TallyColors.raised : TallyColors.surface,
              border: Border.all(color: TallyColors.hairline),
            ),
            child: widget.busy
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: TallyColors.signalBlue,
                    ),
                  )
                : Icon(
                    Icons.refresh,
                    size: 18,
                    color: _hovered
                        ? TallyColors.textPrimary
                        : TallyColors.textSecondary,
                  ),
          ),
        ),
      ),
    );
  }
}
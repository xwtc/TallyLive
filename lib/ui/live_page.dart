import 'package:flutter/material.dart';
import 'package:tallylive/core/live_repository.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/ui/components/navigation.dart';
import 'package:tallylive/ui/components/section_header.dart';
import 'package:tallylive/ui/components/states.dart';
import 'package:tallylive/ui/components/streamer_card.dart';
import 'package:tallylive/ui/components/streamer_row.dart';
import 'package:tallylive/ui/theme.dart';

/// 「直播」Tab —— 首页。
///
/// 结构（UI-DESIGN §4.1）：
/// ```
/// [平台分段 / 下拉]        [搜索]
/// ● 正在直播 N                       ← tally 行
/// 关注中在播（列表行；空态引导）
/// 平台精选（封面网格；无限滚动）
/// ```
///
/// 数据来自 [LiveRepository]（当前为 Mock，离线可跑）。
class LivePage extends StatefulWidget {
  const LivePage({super.key, this.repository});

  /// 允许注入（便于以后接真实仓库 / 测试）。
  final LiveRepository? repository;

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  static const List<LivePlatform> _platforms = [
    LivePlatform.douyu,
    LivePlatform.huya,
    LivePlatform.douyin,
    LivePlatform.bilibili,
  ];

  late final LiveRepository _repo = widget.repository ?? createLiveRepository();

  /// null = 全部平台
  LivePlatform? _platform = LivePlatform.douyu;

  final ScrollController _scroll = ScrollController();

  final List<Streamer> _items = [];
  int _page = 0;
  bool _hasMore = true;
  bool _loading = false;
  bool _initialLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadFirstPage();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final remaining = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 400) _loadMore();
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _initialLoading = true;
      _error = null;
      _items.clear();
      _page = 0;
      _hasMore = true;
    });
    await _loadMore(initial: true);
  }

  Future<void> _loadMore({bool initial = false}) async {
    if (_loading || !_hasMore) return;
    // 「全部」平台时先按斗鱼拉（后续接真实实现再按平台聚合）
    final platform = _platform ?? LivePlatform.douyu;
    setState(() => _loading = true);
    try {
      final result = await _repo.fetchLiveList(
        platform: platform,
        page: _page + 1,
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(result.items);
        _page = result.page == 0 ? _page : _page + 1;
        _hasMore = result.hasMore;
        _loading = false;
        _initialLoading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _initialLoading = false;
        if (initial || _items.isEmpty) {
          _error = error.toString();
        }
      });
    }
  }

  void _selectPlatform(LivePlatform? platform) {
    if (platform == _platform) return;
    setState(() => _platform = platform);
    _loadFirstPage();
  }

  @override
  Widget build(BuildContext context) {
    final isCompact = MediaQuery.sizeOf(context).width < TallyBreakpoints.compact;

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
                platforms: _platforms,
                selected: _platform,
                onSelected: _selectPlatform,
              ),
            ),
          IconButton(
            tooltip: '搜索',
            onPressed: () => _showComingSoon('搜索'),
            icon: const Icon(Icons.search, size: 20),
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
                  TallySpace.md, TallySpace.sm, TallySpace.md, TallySpace.sm),
              child: Row(
                children: [
                  PlatformDropdown(
                    platforms: _platforms,
                    selected: _platform,
                    onSelected: _selectPlatform,
                  ),
                ],
              ),
            ),
          TallyHeader(liveCount: _items.where((s) => s.isLive).length),
          Expanded(child: _buildBody(isCompact)),
        ],
      ),
    );
  }

  Widget _buildBody(bool isCompact) {
    if (_initialLoading) {
      return ListView.separated(
        padding: const EdgeInsets.all(TallySpace.md),
        itemCount: 6,
        separatorBuilder: (_, __) => const SizedBox(height: TallySpace.sm),
        itemBuilder: (_, __) => const SkeletonRow(),
      );
    }
    if (_error != null) {
      return ErrorState(message: _error!, onRetry: _loadFirstPage);
    }

    return RefreshIndicator(
      color: TallyColors.signalBlue,
      backgroundColor: TallyColors.raised,
      onRefresh: _loadFirstPage,
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          // ---- 关注中在播（当前无关注数据，显示空态引导）----
          const SliverToBoxAdapter(
            child: SectionHeader(title: '关注中在播'),
          ),
          const SliverToBoxAdapter(
            child: SizedBox(
              height: 132,
              child: EmptyState(
                message: '还没有关注的直播间\n可以先去分区里找找',
                icon: Icons.star_border,
              ),
            ),
          ),

          // ---- 平台精选 ----
          SliverToBoxAdapter(
            child: SectionHeader(
              title: '平台精选',
              count: _items.length,
              trailingLabel: '刷新',
              onTrailingTap: _loadFirstPage,
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: TallySpace.md),
            sliver: isCompact
                ? SliverList.separated(
                    itemCount: _items.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: TallySpace.xs),
                    itemBuilder: (context, index) => StreamerRow(
                      streamer: _items[index],
                      onTap: () => _openStreamer(_items[index]),
                    ),
                  )
                : SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 300,
                      mainAxisSpacing: TallySpace.lg,
                      crossAxisSpacing: TallySpace.md,
                      childAspectRatio: 0.92,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => StreamerCard(
                        streamer: _items[index],
                        onTap: () => _openStreamer(_items[index]),
                      ),
                      childCount: _items.length,
                    ),
                  ),
          ),
          SliverToBoxAdapter(
            child: _loading
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

  void _openStreamer(Streamer streamer) {
    // 播放页需要真实取流；Mock 数据没有地址，先提示。
    _showComingSoon('播放「${streamer.nickname}」');
  }

  void _showComingSoon(String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what 待接入')),
    );
  }
}

/// 供「我的」显示当前仓库模式（Mock / 真实）。
String describeRepositoryMode() =>
    kUseMockData ? 'Mock 数据（离线）' : '真实接口';
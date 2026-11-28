import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tallylive/core/feed_ui.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/core/player_session.dart';
import 'package:tallylive/ui/components/states.dart';
import 'package:tallylive/ui/components/streamer_row.dart';
import 'package:tallylive/ui/theme.dart';

/// 搜索页（对齐 DTV 的 SearchBox + 结果列表）。
///
/// 行为：
/// - 输入 250ms 防抖，回车立即搜
/// - 结果按 `Streamer` 行渲染，点击直接进播放（与列表页一致）
/// - 每个平台的支持情况不同：
///   * B站 / 斗鱼 / 虎牙 有搜索接口
///   * **抖音搜索实测返回 2483 风控**，界面明确说明，不假装有结果
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;

  List<SearchHit> _hits = const [];
  bool _loading = false;
  String? _error;
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _search(value));
  }

  Future<void> _search(String raw) async {
    final keyword = raw.trim();
    if (keyword.isEmpty) {
      setState(() {
        _hits = const [];
        _error = null;
        _lastQuery = '';
      });
      return;
    }
    if (keyword == _lastQuery && _hits.isNotEmpty) return;

    final platform = FeedUi.instance.platform ??
        sharedRepository.supportedPlatforms.first;
    setState(() {
      _loading = true;
      _error = null;
      _lastQuery = keyword;
    });
    try {
      final hits = await sharedRepository.search(
        platform: platform,
        keyword: keyword,
      );
      if (!mounted) return;
      setState(() {
        _hits = hits;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _friendly(error);
        _loading = false;
      });
    }
  }

  String _friendly(Object error) {
    final text = error.toString();
    if (text.contains('2483')) {
      return '抖音搜索被风控拦截（2483）。\n可以改用房间号直接进入播放。';
    }
    if (text.contains('UnimplementedError')) {
      return '该平台的搜索接口尚未接入';
    }
    return text.length > 140 ? '${text.substring(0, 140)}…' : text;
  }

  void _open(SearchHit hit) {
    PlayerSession.instance.open(PlayerTarget(
      platform: hit.platform,
      roomId: hit.id,
      title: hit.title.isEmpty ? hit.nickname : hit.title,
    ));
    // 关闭搜索页回到列表（播放层已经在壳层里）
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final platform = FeedUi.instance.platform;
    return Scaffold(
      backgroundColor: TallyColors.base,
      appBar: AppBar(
        backgroundColor: TallyColors.surface,
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          focusNode: _focus,
          onChanged: _onChanged,
          onSubmitted: _search,
          style: TallyType.subtitle.copyWith(color: TallyColors.textPrimary),
          decoration: InputDecoration(
            hintText: '搜索关键词或直播间号',
            hintStyle: TallyType.meta,
            border: InputBorder.none,
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    iconSize: 16,
                    onPressed: () {
                      _controller.clear();
                      _search('');
                    },
                    icon: const Icon(Icons.close,
                        color: TallyColors.textTertiary),
                  ),
          ),
        ),
      ),
      body: _buildBody(platform),
    );
  }

  Widget _buildBody(LivePlatform? platform) {
    if (_loading) {
      return ListView.separated(
        padding: const EdgeInsets.all(TallySpace.md),
        itemCount: 6,
        separatorBuilder: (_, __) => const SizedBox(height: TallySpace.xs),
        itemBuilder: (_, __) => const SkeletonRow(),
      );
    }
    if (_error != null) {
      return ErrorState(message: _error!, onRetry: () => _search(_lastQuery));
    }
    if (_lastQuery.isEmpty) {
      return EmptyState(
        icon: Icons.search,
        message: platform == null
            ? '输入关键词搜索直播间'
            : '在 ${platform.label} 里搜索直播间',
      );
    }
    if (_hits.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        message: '没找到「$_lastQuery」\n换个关键词试试',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(
          horizontal: TallySpace.md, vertical: TallySpace.sm),
      itemCount: _hits.length,
      separatorBuilder: (_, __) => const SizedBox(height: TallySpace.xs),
      itemBuilder: (context, index) {
        final hit = _hits[index];
        return StreamerRow(
          streamer: Streamer(
            platform: hit.platform,
            id: hit.id,
            nickname: hit.nickname,
            title: hit.title,
            avatar: hit.avatar,
            isLive: hit.isLive,
          ),
          onTap: () => _open(hit),
        );
      },
    );
  }
}

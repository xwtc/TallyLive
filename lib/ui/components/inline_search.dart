import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tallylive/core/feed_ui.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/core/player_session.dart';
import 'package:tallylive/ui/components/atoms.dart';
import 'package:tallylive/ui/theme.dart';

/// 内联搜索框（对齐 DTV 的 `SearchBox`）。
///
/// 行为（规格取自 DTV 的 SearchBox.module.css）：
/// - 常态宽 **190px**，聚焦后展开到 **292px**（动画 280ms）
/// - 输入 250ms 防抖，**自动联想**，结果以浮层出现在输入框下方（宽 384px）
/// - 上下键切换选中项、回车确认、Esc 收起、点外部关闭
/// - 结果点击直接进播放
///
/// 之前做成独立页面（跳转），与 DTV 不一致，这里改回内联浮层。
class InlineSearch extends StatefulWidget {
  const InlineSearch({super.key});

  @override
  State<InlineSearch> createState() => _InlineSearchState();
}

class _InlineSearchState extends State<InlineSearch> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  final GlobalKey _rootKey = GlobalKey();
  Timer? _debounce;

  bool _expanded = false;
  bool _loading = false;
  List<SearchHit> _hits = const [];
  String? _error;
  String _query = '';
  int _activeIndex = -1;

  /// 浮层用 OverlayEntry 承载，避免被父级裁剪（之前 Stack 内 Positioned 会被列表盖住）。
  OverlayEntry? _panelEntry;

  /// 输入框左边缘的全局坐标（用于定位浮层）。
  final GlobalKey _fieldKey = GlobalKey();

  static const double _widthIdle = 190;
  static const double _widthExpanded = 292;
  static const double _panelWidth = 384;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _unmountPanel();
    _debounce?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    setState(() => _expanded = _focus.hasFocus);
    _syncPanel();
  }

  /// 挂载/卸载浮层。
  void _syncPanel() {
    final shouldShow = _expanded && _controller.text.trim().isNotEmpty;
    if (shouldShow && _panelEntry == null) {
      _mountPanel();
    } else if (!shouldShow && _panelEntry != null) {
      _unmountPanel();
    } else if (shouldShow) {
      _panelEntry!.markNeedsBuild();
    }
  }

  void _mountPanel() {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    _panelEntry = OverlayEntry(builder: _buildOverlayPanel);
    overlay.insert(_panelEntry!);
  }

  void _unmountPanel() {
    _panelEntry?.remove();
    _panelEntry = null;
  }

  Widget _buildOverlayPanel(BuildContext context) {
    final box = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return const SizedBox.shrink();
    final origin = box.localToGlobal(Offset.zero);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final left = (origin.dx + box.size.width - _panelWidth)
        .clamp(8.0, screenWidth - _panelWidth - 8);

    return Stack(
      children: [
        // 点击外部关闭
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              _focus.unfocus();
              _collapse();
            },
          ),
        ),
        Positioned(
          left: left,
          top: origin.dy + box.size.height + 4,
          width: _panelWidth,
          child: _buildPanel(),
        ),
      ],
    );
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      _search(_controller.text);
    });
  }

  Future<void> _search(String raw) async {
    final keyword = raw.trim();
    if (keyword.isEmpty) {
      setState(() {
        _hits = const [];
        _error = null;
        _query = '';
        _activeIndex = -1;
      });
      return;
    }
    final platform = FeedUi.instance.platform ??
        sharedRepository.supportedPlatforms.first;
    setState(() {
      _loading = true;
      _error = null;
      _query = keyword;
    });
    try {
      final hits = await sharedRepository.search(
        platform: platform,
        keyword: keyword,
      );
      if (!mounted || _query != keyword) return;
      setState(() {
        _hits = hits;
        _loading = false;
        _activeIndex = hits.isEmpty ? -1 : 0;
      });
      _syncPanel();
    } catch (error) {
      if (!mounted || _query != keyword) return;
      setState(() {
        _error = _friendly(error);
        _loading = false;
        _activeIndex = -1;
      });
    }
  }

  String _friendly(Object error) {
    final text = error.toString();
    if (text.contains('2483')) {
      return '抖音搜索被风控拦截（2483），可直接输房间号';
    }
    if (text.contains('UnimplementedError')) return '该平台搜索尚未接入';
    return text.length > 100 ? '${text.substring(0, 100)}…' : text;
  }

  void _open(SearchHit hit) {
    PlayerSession.instance.open(PlayerTarget(
      platform: hit.platform,
      roomId: hit.id,
      title: hit.title.isEmpty ? hit.nickname : hit.title,
    ));
    _collapse();
  }

  void _collapse() {
    _focus.unfocus();
    _controller.clear();
    setState(() {
      _hits = const [];
      _query = '';
      _error = null;
      _activeIndex = -1;
    });
    _syncPanel();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        _collapse();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        if (_hits.isNotEmpty) {
          setState(() =>
              _activeIndex = (_activeIndex + 1).clamp(0, _hits.length - 1));
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        if (_hits.isNotEmpty) {
          setState(() =>
              _activeIndex = (_activeIndex - 1).clamp(0, _hits.length - 1));
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        if (_activeIndex >= 0 && _activeIndex < _hits.length) {
          _open(_hits[_activeIndex]);
        } else {
          _search(_controller.text);
        }
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final showPanel = _expanded && _controller.text.trim().isNotEmpty;

    return SizedBox(
      width: _widthExpanded,
      height: 36,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: AnimatedContainer(
              key: _fieldKey,
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOut,
              width: _expanded ? _widthExpanded : _widthIdle,
              height: 36,
              padding: const EdgeInsets.only(left: 12, right: 4),
              decoration: BoxDecoration(
                color: TallyColors.inset,
                borderRadius: BorderRadius.circular(TallyRadius.pill),
                border: Border.all(
                  color: _expanded
                      ? TallyColors.signalBlue.withValues(alpha: 0.6)
                      : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Focus(
                      onKeyEvent: _onKey,
                      child: TextField(
                        controller: _controller,
                        focusNode: _focus,
                        cursorColor: TallyColors.signalBlue,
                        style: TallyType.subtitle
                            .copyWith(color: TallyColors.textPrimary),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '搜索关键词或直播间号',
                          hintStyle: TallyType.subtitle
                              .copyWith(color: TallyColors.textTertiary),
                        ),
                      ),
                    ),
                  ),
                  if (_controller.text.isNotEmpty)
                    _MiniIcon(
                      icon: Icons.close,
                      tooltip: '清空',
                      onTap: _collapse,
                    ),
                  _MiniIcon(
                    icon: Icons.search,
                    tooltip: '搜索',
                    onTap: () => _search(_controller.text),
                  ),
                ],
              ),
            ),
          ),

        ],
      ),
    );
  }

  Widget _buildPanel() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 420),
      decoration: BoxDecoration(
        color: TallyColors.raised,
        borderRadius: BorderRadius.circular(TallyRadius.card),
        border: Border.all(color: TallyColors.hairline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                TallySpace.md, TallySpace.sm, TallySpace.md, TallySpace.xs),
            child: Row(
              children: [
                Text('搜索结果', style: TallyType.meta),
                const Spacer(),
                if (!_loading && _error == null)
                  Text('${_hits.length} 条', style: TallyType.meta),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(child: _buildPanelBody()),
        ],
      ),
    );
  }

  Widget _buildPanelBody() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(TallySpace.lg),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: TallyColors.signalBlue,
            ),
          ),
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(TallySpace.md),
        child: Text(_error!, style: TallyType.meta),
      );
    }
    if (_hits.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(TallySpace.md),
        child: Text('没找到「$_query」', style: TallyType.meta),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: TallySpace.xs),
      itemCount: _hits.length,
      itemBuilder: (context, index) {
        final hit = _hits[index];
        final active = index == _activeIndex;
        return _HitRow(
          hit: hit,
          active: active,
          onTap: () => _open(hit),
        );
      },
    );
  }
}

/// 搜索结果的一行（紧凑，36px）。
class _HitRow extends StatefulWidget {
  const _HitRow({
    required this.hit,
    required this.active,
    required this.onTap,
  });

  final SearchHit hit;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_HitRow> createState() => _HitRowState();
}

class _HitRowState extends State<_HitRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final hit = widget.hit;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: TallySpace.sm),
          color: widget.active || _hovered
              ? TallyColors.raised
              : Colors.transparent,
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AvatarBox(
                    url: hit.avatar,
                    fallbackText: hit.nickname,
                    size: 28,
                  ),
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: hit.isLive
                            ? const Color(0xFF10B981)
                            : const Color(0xFF475569),
                        border: Border.all(
                            color: TallyColors.raised, width: 1.6),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: TallySpace.sm),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hit.nickname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: TallyColors.textPrimary,
                      ),
                    ),
                    Text(
                      hit.title.isEmpty ? '暂无标题' : hit.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TallyType.tiny,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniIcon extends StatefulWidget {
  const _MiniIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_MiniIcon> createState() => _MiniIconState();
}

class _MiniIconState extends State<_MiniIcon> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: 15,
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

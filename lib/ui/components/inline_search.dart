import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tallylive/core/feed_ui.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/core/player_session.dart';
import 'package:tallylive/ui/components/atoms.dart';
import 'package:tallylive/ui/shell/search_panel_host.dart';
import 'package:tallylive/ui/theme.dart';

/// 内联搜索框（对齐 DTV 的 `SearchBox`）。
///
/// - 常态宽 **190px**，聚焦展开到 **292px**（280ms 过渡）
/// - 输入 250ms 防抖，自动联想，浮层宽 384px 挂在输入框下方
/// - 上下键切换、回车确认、Esc 收起、点外部关闭
///
/// ⚠️ **两个必须的细节**（都踩过）：
/// 1. 浮层挂在 shell 的 Stack 里（[SearchPanelController]），不用根 Overlay ——
///    用 Overlay 时浮层能显示但点击不生效。
/// 2. `TextField.onTapOutside` 必须置空 —— Flutter 默认在「点击文本框外部」时
///    让输入框失焦，而点击浮层里的结果行也算"外部"。失焦 → 浮层被卸载 →
///    点击事件还没走完控件就没了，表现就是**点鼠标进不去、按回车才行**。
class InlineSearch extends StatefulWidget {
  const InlineSearch({super.key});

  @override
  State<InlineSearch> createState() => _InlineSearchState();
}

class _InlineSearchState extends State<InlineSearch> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// 输入框外壳：定位浮层用它的矩形。
  final GlobalKey _shellKey = GlobalKey();

  /// 当前高亮项。
  ///
  /// 用 [ValueNotifier] 而不是 `setState`：鼠标在结果行上移动时只重建那一行，
  /// 不会把整个浮层重建一遍（否则会闪）。
  final ValueNotifier<int> _activeIndex = ValueNotifier<int>(-1);

  Timer? _debounce;

  bool _expanded = false;
  bool _loading = false;
  List<SearchHit> _hits = const [];
  String? _error;
  String _query = '';

  static const double _widthIdle = 190;
  static const double _widthExpanded = 292;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    SearchPanelController.instance.hide();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focus.dispose();
    _activeIndex.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    setState(() => _expanded = _focus.hasFocus);
    _syncPanel();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
    _syncPanel();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      _search(_controller.text);
    });
  }

  /// 挂载 / 卸载 / 刷新浮层。
  void _syncPanel() {
    final shouldShow = _focus.hasFocus && _controller.text.trim().isNotEmpty;
    if (!shouldShow) {
      SearchPanelController.instance.hide();
      return;
    }
    final anchor = _anchorRect();
    if (anchor == null) return;
    SearchPanelController.instance.show(
      anchor: anchor,
      onDismiss: _dismiss,
      builder: (_) => _buildPanel(),
    );
  }

  Rect? _anchorRect() {
    final box = _shellKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _search(String raw) async {
    final keyword = raw.trim();
    if (keyword.isEmpty) {
      setState(() {
        _hits = const [];
        _error = null;
        _query = '';
      });
      _activeIndex.value = -1;
      return;
    }
    final platform =
        FeedUi.instance.platform ?? sharedRepository.supportedPlatforms.first;
    setState(() {
      _loading = true;
      _error = null;
      _query = keyword;
    });
    _activeIndex.value = -1;
    try {
      final hits = await sharedRepository.search(
        platform: platform,
        keyword: keyword,
      );
      if (!mounted || _query != keyword) return;
      setState(() {
        _hits = hits;
        _loading = false;
      });
      _activeIndex.value = hits.isEmpty ? -1 : 0;
      _syncPanel();
    } catch (error) {
      if (!mounted || _query != keyword) return;
      setState(() {
        _error = _friendly(error);
        _loading = false;
      });
      _activeIndex.value = -1;
      _syncPanel();
    }
  }

  String _friendly(Object error) {
    final text = error.toString();
    if (text.contains('2483') || text.contains('风控')) {
      return '抖音搜索需要登录，暂不可用。可直接输入房间号进入。';
    }
    if (text.contains('UnimplementedError')) return '该平台的搜索尚未接入';
    final cleaned = text.replaceFirst(RegExp(r'^\w+Exception:\s*'), '');
    return cleaned.length > 120 ? '${cleaned.substring(0, 120)}…' : cleaned;
  }

  void _open(SearchHit hit) {
    PlayerSession.instance.open(PlayerTarget(
      platform: hit.platform,
      roomId: hit.id,
      title: hit.title.isEmpty ? hit.nickname : hit.title,
    ));
    _dismiss();
  }

  /// 收起搜索：清空文字、失焦、卸载浮层。
  void _dismiss() {
    _focus.unfocus();
    _controller.clear();
    SearchPanelController.instance.hide();
    _activeIndex.value = -1;
    if (!mounted) return;
    setState(() {
      _hits = const [];
      _query = '';
      _error = null;
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        _dismiss();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        if (_hits.isNotEmpty) {
          _activeIndex.value =
              (_activeIndex.value + 1).clamp(0, _hits.length - 1);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        if (_hits.isNotEmpty) {
          _activeIndex.value =
              (_activeIndex.value - 1).clamp(0, _hits.length - 1);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        final index = _activeIndex.value;
        if (index >= 0 && index < _hits.length) {
          _open(_hits[index]);
        } else {
          _search(_controller.text);
        }
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _widthExpanded,
      height: 36,
      child: Align(
        alignment: Alignment.centerRight,
        child: AnimatedContainer(
          key: _shellKey,
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
                  ? TallyColors.signalBlue.withValues(alpha: 0.55)
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
                    // 关键：默认实现会在点击文本框外部时失焦，
                    // 而点击浮层里的结果行也算外部 → 浮层被卸载 → 点击丢失。
                    onTapOutside: (_) {},
                    style: TallyType.subtitle.copyWith(
                      color: TallyColors.textPrimary,
                      decoration: TextDecoration.none,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: '搜索关键词或房间号',
                      hintStyle: TallyType.subtitle.copyWith(
                        color: TallyColors.textTertiary,
                      ),
                    ),
                  ),
                ),
              ),
              if (_controller.text.isNotEmpty)
                _MiniIcon(
                  icon: Icons.close,
                  tooltip: '清空',
                  onTap: _dismiss,
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
    );
  }

  /* ------------------------------------------------------------------ 浮层 */

  Widget _buildPanel() {
    return SearchPanelSurface(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                TallySpace.md, 10, TallySpace.sm, 8),
            child: Row(
              children: [
                Text(
                  '搜索结果',
                  style: TallyType.meta.copyWith(
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
                const Spacer(),
                if (!_loading && _error == null)
                  Text(
                    '${_hits.length} 条',
                    style: TallyType.tiny.copyWith(
                      decoration: TextDecoration.none,
                    ),
                  ),
              ],
            ),
          ),
          Flexible(child: _buildPanelBody()),
        ],
      ),
    );
  }

  Widget _buildPanelBody() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
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
        padding: const EdgeInsets.fromLTRB(
            TallySpace.md, 4, TallySpace.md, TallySpace.md),
        child: Text(
          _error!,
          style: TallyType.meta.copyWith(
            height: 1.4,
            decoration: TextDecoration.none,
          ),
        ),
      );
    }
    if (_hits.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
            TallySpace.md, 4, TallySpace.md, TallySpace.md),
        child: Text(
          '没找到「$_query」\n试试更短的关键词，或直接输入房间号',
          style: TallyType.meta.copyWith(
            height: 1.4,
            decoration: TextDecoration.none,
          ),
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 4),
      itemCount: _hits.length,
      itemBuilder: (context, index) => _HitRow(
        hit: _hits[index],
        index: index,
        activeIndex: _activeIndex,
        onTap: () => _open(_hits[index]),
      ),
    );
  }
}

/// 搜索结果的一行。
///
/// - 所有文字显式 `decoration: TextDecoration.none`（避免继承外层下划线）
/// - 行高 48，hover 上 `inset` 底色 + 圆角 8
/// - 高亮状态走 [ValueListenableBuilder]，鼠标移动不重建整个浮层
class _HitRow extends StatefulWidget {
  const _HitRow({
    required this.hit,
    required this.index,
    required this.activeIndex,
    required this.onTap,
  });

  final SearchHit hit;
  final int index;
  final ValueNotifier<int> activeIndex;
  final VoidCallback onTap;

  @override
  State<_HitRow> createState() => _HitRowState();
}

class _HitRowState extends State<_HitRow> {
  bool _hovered = false;

  /// 清掉可能的 HTML 残留（B站 title 带 `<em class="keyword">`）。
  static String _clean(String raw) {
    if (!raw.contains('<')) return raw;
    return raw.replaceAll(RegExp(r'<[^>]*>'), '');
  }

  @override
  Widget build(BuildContext context) {
    final hit = widget.hit;
    final nickname = _clean(hit.nickname);
    final title = _clean(hit.title);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hovered = true);
        widget.activeIndex.value = widget.index;
      },
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: ValueListenableBuilder<int>(
          valueListenable: widget.activeIndex,
          builder: (context, active, _) {
            final highlighted = active == widget.index || _hovered;
            return Container(
              height: 48,
              margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color:
                    highlighted ? TallyColors.inset : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      AvatarBox(
                        url: hit.avatar,
                        fallbackText: nickname,
                        size: 30,
                      ),
                      Positioned(
                        right: -1,
                        bottom: -1,
                        child: Container(
                          width: 11,
                          height: 11,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: hit.isLive
                                ? const Color(0xFF10B981)
                                : const Color(0xFF475569),
                            border: Border.all(
                                color: TallyColors.raised, width: 1.8),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          nickname.isEmpty ? hit.id : nickname,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                            color: TallyColors.textPrimary,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          title.isEmpty ? '暂无标题' : title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            height: 1.25,
                            color: TallyColors.textTertiary,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (hit.isLive)
                    Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: TallyColors.tallyRed.withValues(alpha: 0.16),
                        borderRadius:
                            BorderRadius.circular(TallyRadius.pill),
                      ),
                      child: Text(
                        '直播中',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: TallyColors.tallyRed,
                          height: 1.2,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
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

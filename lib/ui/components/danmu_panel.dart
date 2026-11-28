import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tallylive/core/danmaku.dart';
import 'package:tallylive/ui/theme.dart';

/// 右侧弹幕列表（对齐 DTV 的 DanmuPanel）。
///
/// 行为要点（都来自 DTV 的实测经验）：
/// - 最多保留 200 条，超出丢弃最早的（长直播不会无限涨内存）
/// - **用户往上滑时暂停自动跟随**，回到底部才恢复；期间新消息计数，
///   浮出「新弹幕 N」胶囊，点一下跳回底部
/// - 系统消息（进场/礼物）用弱化样式，不伪装成聊天
/// - 空态明确写出「正在连接」，避免让用户以为坏了
class DanmuPanel extends StatefulWidget {
  const DanmuPanel({
    super.key,
    required this.stream,
    this.width = 196,
    this.errorHint,
    this.onRetry,
    this.statusHint,
    this.onClose,
    this.onResize,
  });

  final Stream<DanmakuMessage> stream;
  /// 面板宽度（对齐 DTV：默认 196，可拖 168~320）。
  final double width;

  /// 连接失败原因（非空时替代「正在连接」显示，避免把风控误认为渲染问题）。
  final String? errorHint;

  /// 点「重新连接」时回调（连接失败后停止自动重试时才有意义）。
  final VoidCallback? onRetry;

  /// 当前连接阶段说明（如「正在获取弹幕服务器…」）。
  final String? statusHint;
  final VoidCallback? onClose;

  /// 拖拽左侧手柄调整宽度（对齐 DTV：168~320）。
  final ValueChanged<double>? onResize;

  @override
  State<DanmuPanel> createState() => _DanmuPanelState();
}

class _DanmuPanelState extends State<DanmuPanel> {
  static const int _maxMessages = 200;

  /// 面板宽度范围（对齐 DTV 的 PANEL_WIDTH_MIN / MAX）。
  static const double _panelWidthMin = 168;
  static const double _panelWidthMax = 320;

  final List<DanmakuMessage> _messages = [];
  final ScrollController _scroll = ScrollController();
  StreamSubscription<DanmakuMessage>? _sub;

  /// 用户是否上滑离开了底部（离开则暂停自动跟随）。
  bool _followBottom = true;

  /// 暂停跟随后累计的未读条数。
  int _pending = 0;

  /// 正在由程序自身滚动（避免把自己的滚动当成用户上翻）。
  bool _autoScrolling = false;

  @override
  void initState() {
    super.initState();
    _listen();
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant DanmuPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stream != widget.stream) {
      _sub?.cancel();
      _listen();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _listen() {
    _sub = widget.stream.listen((message) {
      if (!mounted) return;
      setState(() {
        _messages.add(message);
        if (_messages.length > _maxMessages) {
          _messages.removeRange(0, _messages.length - _maxMessages);
        }
        if (!_followBottom) _pending++;
      });
      // 跟随底部时用 animateTo 而不是 jumpTo：新弹幕是平滑滚上来的，
      // 视觉上像"自动往下翻"，不会一卡一卡地跳。
      if (_followBottom) _scrollToBottomSoon();
    });
  }

  /// 用户主动滚动时暂停跟随，回到底部附近才恢复。
  ///
  /// 阈值给 48px（不是 0）：鼠标滚轮/触控板惯性常常停在离底一点点的地方，
  /// 如果要求精确到底才恢复，用户会觉得"怎么不动了"。
  void _onScroll() {
    if (!_scroll.hasClients) return;
    // 程序自己触发的滚动不算用户操作
    if (_autoScrolling) return;
    final atBottom =
        _scroll.position.maxScrollExtent - _scroll.position.pixels < 48;
    // 只有「用户滚动」才改变跟随状态；向上翻立即停，滑回底部自动恢复。
    if (atBottom != _followBottom) {
      setState(() {
        _followBottom = atBottom;
        if (atBottom) _pending = 0;
      });
    }
  }

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if ((target - _scroll.position.pixels).abs() < 1) return;
      _autoScrolling = true;
      _scroll
          .animateTo(
            target,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          )
          .whenComplete(() => _autoScrolling = false);
    });
  }

  /// 点「新弹幕 N」：立刻回底并恢复自动跟随。
  void _jumpToBottom() {
    if (!_scroll.hasClients) return;
    setState(() {
      _pending = 0;
      _followBottom = true;
    });
    _autoScrolling = true;
    _scroll
        .animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        )
        .whenComplete(() => _autoScrolling = false);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 左边缘拖拽手柄（DTV 的 .resizer）
        if (widget.onResize != null)
          MouseRegion(
            cursor: SystemMouseCursors.resizeLeftRight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (details) {
                final next = (widget.width - details.delta.dx)
                    .clamp(_panelWidthMin, _panelWidthMax);
                widget.onResize!(next);
              },
              child: Container(
                width: 5,
                color: Colors.transparent,
                alignment: Alignment.center,
                child: Container(
                  width: 1,
                  color: TallyColors.hairline,
                ),
              ),
            ),
          ),
        Container(
          width: widget.width,
          color: TallyColors.base,
          child: Column(
        children: [
          // 头部
          SizedBox(
            height: 40,
            child: Row(
              children: [
                const SizedBox(width: TallySpace.md),
                const Text('弹幕', style: TallyType.sectionTitle),
                const Spacer(),
                if (widget.onClose != null)
                  IconButton(
                    tooltip: '关闭弹幕列表',
                    iconSize: 16,
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close,
                        color: TallyColors.textTertiary),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Stack(
              children: [
                if (_messages.isEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(TallySpace.md),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.errorHint == null
                                ? (widget.statusHint ?? '暂无弹幕，正在连接…')
                                : '弹幕连接失败：${widget.errorHint}',
                            textAlign: TextAlign.center,
                            style: TallyType.meta.copyWith(
                              height: 1.5,
                              decoration: TextDecoration.none,
                            ),
                          ),
                          if (widget.errorHint != null &&
                              widget.onRetry != null) ...[
                            const SizedBox(height: TallySpace.md),
                            OutlinedButton(
                              onPressed: widget.onRetry,
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 28),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14),
                                side: const BorderSide(
                                    color: TallyColors.hairline),
                              ),
                              child: const Text(
                                '重新连接',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  )
                else
                  ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(
                        horizontal: TallySpace.md, vertical: TallySpace.sm),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) =>
                        _DanmuRow(message: _messages[index]),
                  ),
                // 未读数胶囊
                if (_pending > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: TallySpace.sm,
                    child: Center(
                      child: GestureDetector(
                        onTap: _jumpToBottom,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: TallySpace.md, vertical: 5),
                          decoration: BoxDecoration(
                            color: TallyColors.signalBlue,
                            borderRadius:
                                BorderRadius.circular(TallyRadius.pill),
                          ),
                          child: Text(
                            '新弹幕 $_pending',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
          ),
        ),
      ],
    );
  }
}

/// 把 `#RRGGBB` 解析成可读颜色；太暗或格式不对返回 null（回退主文字色）。
///
/// 夜间背景上纯黑/深蓝这类颜色几乎看不见，所以做亮度下限。
Color? _readableColor(String? raw) {
  if (raw == null) return null;
  final text = raw.trim();
  if (text.length != 7 || !text.startsWith('#')) return null;
  final value = int.tryParse(text.substring(1), radix: 16);
  if (value == null) return null;
  final r = (value >> 16) & 0xFF;
  final g = (value >> 8) & 0xFF;
  final b = value & 0xFF;
  final luma = 0.299 * r + 0.587 * g + 0.114 * b;
  if (luma < 70) return null;
  return Color(0xFF000000 | value);
}

/// 单条弹幕：`Lv.x 昵称：内容`，系统消息弱化。
class _DanmuRow extends StatelessWidget {
  const _DanmuRow({required this.message});

  final DanmakuMessage message;

  @override
  Widget build(BuildContext context) {
    final isSystem = message.kind != DanmakuKind.chat;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text.rich(
        TextSpan(
          children: [
            if (message.level > 0)
              TextSpan(
                text: 'Lv.${message.level} ',
                style: const TextStyle(
                  fontSize: 11,
                  color: TallyColors.textTertiary,
                ),
              ),
            if (message.nickname.isNotEmpty)
              TextSpan(
                text: '${message.nickname}：',
                style: TextStyle(
                  fontSize: 12,
                  color: isSystem
                      ? TallyColors.textTertiary
                      : TallyColors.textSecondary,
                ),
              ),
            TextSpan(
              text: message.content,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                // 彩蛋色的弹幕用平台下发的颜色；深色（看不清）或未下发时用主文字色
                color: isSystem
                    ? TallyColors.textTertiary
                    : (_readableColor(message.color) ?? TallyColors.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
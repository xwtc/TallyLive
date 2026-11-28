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
    this.width = 240,
    this.errorHint,
    this.onClose,
  });

  final Stream<DanmakuMessage> stream;
  final double width;

  /// 连接失败原因（非空时替代「正在连接」显示，避免把风控误认为渲染问题）。
  final String? errorHint;
  final VoidCallback? onClose;

  @override
  State<DanmuPanel> createState() => _DanmuPanelState();
}

class _DanmuPanelState extends State<DanmuPanel> {
  static const int _maxMessages = 200;

  final List<DanmakuMessage> _messages = [];
  final ScrollController _scroll = ScrollController();
  StreamSubscription<DanmakuMessage>? _sub;

  /// 用户是否上滑离开了底部（离开则暂停自动跟随）。
  bool _followBottom = true;

  /// 暂停跟随后累计的未读条数。
  int _pending = 0;

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
      if (_followBottom) _scrollToBottomSoon();
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atBottom =
        _scroll.position.maxScrollExtent - _scroll.position.pixels < 24;
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
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _jumpToBottom() {
    setState(() => _pending = 0);
    _scrollToBottomSoon();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
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
                      child: Text(
                        widget.errorHint == null
                            ? '暂无弹幕，正在连接…'
                            : '弹幕连接失败：${widget.errorHint}',
                        textAlign: TextAlign.center,
                        style: TallyType.meta,
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
                fontSize: 12.5,
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

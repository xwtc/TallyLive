import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:tallylive/core/danmaku.dart';

/// 弹幕叠加层。
///
/// 结构上与 Simple Live 一致：`DanmakuScreen` 是普通 Flutter 组件，
/// 和 media_kit 的 `Video` 在同一个 `Stack` 里，走同一个合成器 —— 所以
/// 不需要任何窗口叠加技巧，弹幕天然压在视频上方。
///
/// 设计取舍（见 MOBILE-DESIGN.md）：只画**聊天弹幕**，礼物/进场默认不画，
/// 避免刷屏；夜间配色下用柔白文字 + 描边保证在亮画面上也看得清。
class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.stream,
    this.enabled = true,
    this.showGifts = false,
  });

  /// 弹幕消息流。
  final Stream<DanmakuMessage> stream;

  /// 总开关。
  final bool enabled;

  /// 是否把礼物也画上去（默认关，避免遮挡画面）。
  final bool showGifts;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay> {
  DanmakuController? _controller;
  StreamSubscription<DanmakuMessage>? _subscription;

  /// 夜间模式下的弹幕样式：字号适中、占上半屏、存活 8 秒。
  static const DanmakuOption _option = DanmakuOption(
    fontSize: 18,
    fontWeight: 5,
    area: 0.55,
    duration: 8,
    opacity: 0.95,
    strokeWidth: 1.2,
    safeArea: false,
    lineHeight: 1.5,
  );

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stream != widget.stream) {
      _subscription?.cancel();
      _subscribe();
    }
  }

  void _subscribe() {
    _subscription = widget.stream.listen(_onMessage);
  }

  void _onMessage(DanmakuMessage message) {
    if (!widget.enabled) return;
    if (message.kind != DanmakuKind.chat &&
        !(widget.showGifts && message.kind == DanmakuKind.gift)) {
      return;
    }
    final text = message.content.trim();
    if (text.isEmpty) return;

    _controller?.addDanmaku(
      DanmakuContentItem(
        text,
        color: _parseColor(message.color),
        type: DanmakuItemType.scroll,
      ),
    );
  }

  /// '#RRGGBB' → Color；空串或非法值退回柔白。
  static Color _parseColor(String hex) {
    if (hex.length == 7 && hex.startsWith('#')) {
      final value = int.tryParse(hex.substring(1), radix: 16);
      if (value != null) {
        // 太暗的颜色在直播画面上几乎看不见，亮度不足时退回白色。
        final r = (value >> 16) & 0xFF;
        final g = (value >> 8) & 0xFF;
        final b = value & 0xFF;
        final luma = 0.299 * r + 0.587 * g + 0.114 * b;
        if (luma >= 90) {
          return Color(0xFF000000 | value);
        }
      }
    }
    return const Color(0xFFEDEDEB);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    return IgnorePointer(
      child: DanmakuScreen(
        createdController: (controller) => _controller = controller,
        option: _option,
      ),
    );
  }
}

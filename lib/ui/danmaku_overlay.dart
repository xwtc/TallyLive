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
    this.fontSize = 18,
    this.opacity = 0.95,
    this.duration = 8,
    this.area = 0.55,
  });

  /// 弹幕消息流。
  final Stream<DanmakuMessage> stream;

  /// 总开关。
  final bool enabled;

  /// 是否把礼物也画上去（默认关，避免遮挡画面）。
  final bool showGifts;

  /// 以下四项来自设置页。
  final double fontSize;
  final double opacity;
  final double duration;
  final double area;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay> {
  DanmakuController? _controller;
  StreamSubscription<DanmakuMessage>? _subscription;

  /// 平滑队列。
  ///
  /// B 站的弹幕服务端会把约 1 秒内的消息聚合进一个压缩帧下发，
  /// 收到一帧就把几十条同时 add 进渲染层会导致「一阵一阵」地冒出来。
  /// 这里改成先进队列，再以固定节奏均匀吐出，视觉上才是持续流动的。
  final List<DanmakuContentItem> _queue = [];
  Timer? _drainTimer;

  /// 基础出队间隔：60ms ≈ 16 条/秒，对应正常直播的弹幕密度。
  static const Duration _drainInterval = Duration(milliseconds: 60);

  /// 队列上限：超过就丢弃最老的，避免热门房间积压到延迟越拖越大。
  /// 240 在高人气房间不够用（入队可能 100+/秒），调到 400 并配合更快的出队。
  static const int _maxQueue = 400;

  /// 夜间模式下的弹幕样式：由设置页注入。
  ///
  /// `massiveMode: true` —— 轨道占满时叠加而不是丢弃。
  /// 官方直播间也是这个行为，否则高人气房间会明显"少弹幕"。
  DanmakuOption get _option => DanmakuOption(
        fontSize: widget.fontSize,
        fontWeight: 5,
        area: widget.area,
        duration: widget.duration,
        opacity: widget.opacity,
        strokeWidth: 1.2,
        safeArea: false,
        lineHeight: 1.5,
        massiveMode: true,
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
    if (oldWidget.enabled && !widget.enabled) {
      // 关弹幕时清空积压，重新打开不要突然涌出一堆旧弹幕。
      _queue.clear();
      _stopDrain();
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

    _queue.add(
      DanmakuContentItem(
        text,
        color: _parseColor(message.color),
        type: DanmakuItemType.scroll,
      ),
    );
    if (_queue.length > _maxQueue) {
      _queue.removeRange(0, _queue.length - _maxQueue);
    }
    _ensureDrain();
  }

  void _ensureDrain() {
    _drainTimer ??= Timer.periodic(_drainInterval, (_) => _drain());
  }

  void _stopDrain() {
    _drainTimer?.cancel();
    _drainTimer = null;
  }

  /// 每次 tick 出队 1~6 条：积压越多出得越快，既能追平又不会瞬间喷完。
  ///
  /// 上限从 4 提到 6（≈100 条/秒），否则高人气房间的入队速度远超出队速度，
  /// 队列一满就开始丢最老的——这是「弹幕比官方少」的一个直接原因。
  void _drain() {
    if (_queue.isEmpty) {
      _stopDrain();
      return;
    }
    final batch = _queue.length >= 80
        ? 6
        : _queue.length >= 40
            ? 3
            : _queue.length >= 12
                ? 2
                : 1;
    final controller = _controller;
    for (var i = 0; i < batch && _queue.isNotEmpty; i++) {
      final item = _queue.removeAt(0);
      controller?.addDanmaku(item);
    }
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
    _stopDrain();
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    return IgnorePointer(
      child: DanmakuScreen(
        // 样式变化时重建渲染层，确保新设置立即生效（重建会清空当前弹幕，
        // 但设置页是暂停状态下调的，可以接受）。
        key: ValueKey<String>(
          '${widget.fontSize}-${widget.opacity}-${widget.duration}-${widget.area}',
        ),
        createdController: (controller) => _controller = controller,
        option: _option,
      ),
    );
  }
}

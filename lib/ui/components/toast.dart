import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tallylive/ui/theme.dart';

/// 通知类型（决定图标与颜色）。
enum ToastKind { info, success, error }

/// 右下角浮层通知（**对齐 DTV 的 ToastProvider**）。
///
/// 为什么不用 Material 的 `SnackBar`：它默认横跨整个底部，
/// 在播放页会挡住控件条。DTV 的做法是：
/// ```
/// position: fixed; right: 18px; bottom: 18px;
/// max-width: min(420px, calc(100vw - 36px));
/// padding: 7px 8px 7px 12px; border-radius: 12px;
/// animation: toast-in 220ms
/// ```
/// 也就是**右下角小卡片**，最多堆 3 条，2.6 秒淡出。
class ToastHost {
  ToastHost._();

  static final ToastHost instance = ToastHost._();

  final List<_ToastItem> _items = [];
  OverlayEntry? _entry;
  int _seq = 0;

  /// 显示一条通知。
  void show(
    BuildContext context,
    String message, {
    ToastKind kind = ToastKind.info,
    Duration duration = const Duration(milliseconds: 2600),
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    final item = _ToastItem(id: _seq++, message: message, kind: kind);
    _items.add(item);
    // 最多同时 3 条，多了挤掉最早的
    while (_items.length > 3) {
      _items.removeAt(0);
    }
    _ensureEntry(overlay);
    _entry?.markNeedsBuild();

    Timer(duration, () {
      _items.removeWhere((e) => e.id == item.id);
      if (_items.isEmpty) {
        _removeEntry();
      } else {
        _entry?.markNeedsBuild();
      }
    });
  }

  void _ensureEntry(OverlayState overlay) {
    if (_entry != null) return;
    _entry = OverlayEntry(builder: _buildOverlay);
    overlay.insert(_entry!);
  }

  void _removeEntry() {
    _entry?.remove();
    _entry = null;
  }

  Widget _buildOverlay(BuildContext context) {
    return Positioned(
      right: 18,
      bottom: 18,
      child: Material(
        color: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final item in _items)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _ToastCard(item: item),
              ),
          ],
        ),
      ),
    );
  }
}

class _ToastItem {
  const _ToastItem({required this.id, required this.message, required this.kind});

  final int id;
  final String message;
  final ToastKind kind;
}

class _ToastCard extends StatelessWidget {
  const _ToastCard({required this.item});

  final _ToastItem item;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (item.kind) {
      ToastKind.success => (Icons.check_circle_outline, TallyColors.signalBlue),
      ToastKind.error => (Icons.error_outline, TallyColors.tallyRed),
      ToastKind.info => (Icons.info_outline, TallyColors.textSecondary),
    };

    // 宽度约束：最多 420，且不超过屏幕减去两侧 36px（对齐 DTV）
    final screenWidth = MediaQuery.sizeOf(context).width;
    final maxWidth = screenWidth - 36 < 420 ? screenWidth - 36 : 420.0;

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, (1 - value) * 8),
          child: child,
        ),
      ),
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
        decoration: BoxDecoration(
          color: TallyColors.raised,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: TallyColors.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                item.message,
                style: const TextStyle(
                  fontSize: 13,
                  color: TallyColors.textPrimary,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 便捷扩展：`context.showToast('已刷新 3 位主播', kind: ToastKind.success)`
extension ToastContext on BuildContext {
  void showToast(
    String message, {
    ToastKind kind = ToastKind.info,
    Duration duration = const Duration(milliseconds: 2600),
  }) {
    ToastHost.instance.show(this, message, kind: kind, duration: duration);
  }
}

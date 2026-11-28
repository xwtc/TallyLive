import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tallylive/ui/theme.dart';

/// 自绘窗口控制按钮（最小化 / 最大化·还原 / 关闭）。
///
/// **对齐 DTV 的 `WindowControls`**，样式取自它的 CSS：
/// ```
/// .controls { gap:2px; padding:3px; border-radius:full;
///             background:fill-quaternary; border:1px solid border }
/// .btn      { width:40px; height:34px; border-radius:full;
///             color:text-secondary; background:transparent }
/// .btn:hover{ background:fill-tertiary; color:text-primary }
/// .close:hover { background:#e5344a; color:#fff }
/// ```
/// 也就是**实色胶囊组里的一排圆按钮**，不是贴边的长条。
///
/// macOS 用系统红绿灯（由 Frameless 提供），不显示这一组；移动端没有窗口概念。
class WindowControls extends StatefulWidget {
  const WindowControls({super.key});

  @override
  State<WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<WindowControls> {
  bool _maximised = false;

  bool get _isDesktop {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  @override
  void initState() {
    super.initState();
    if (_isDesktop) _syncMaximised();
  }

  Future<void> _syncMaximised() async {
    try {
      final value = await windowManager.isMaximized();
      if (mounted && value != _maximised) setState(() => _maximised = value);
    } catch (_) {}
  }

  Future<void> _minimise() async {
    try {
      await windowManager.minimize();
    } catch (_) {}
  }

  Future<void> _toggleMaximise() async {
    try {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
        if (mounted) setState(() => _maximised = false);
      } else {
        await windowManager.maximize();
        if (mounted) setState(() => _maximised = true);
      }
    } catch (_) {}
  }

  Future<void> _close() async {
    try {
      await windowManager.close();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (!_isDesktop) return const SizedBox.shrink();
    if (Platform.isMacOS) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: TallyColors.inset,
        borderRadius: BorderRadius.circular(TallyRadius.pill),
        border: Border.all(color: TallyColors.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _WindowButton(
            tooltip: '最小化',
            onTap: _minimise,
            painter: _MinimisePainter(),
          ),
          const SizedBox(width: 2),
          _WindowButton(
            tooltip: _maximised ? '还原' : '最大化',
            onTap: _toggleMaximise,
            painter: _maximised ? _RestorePainter() : _MaximisePainter(),
          ),
          const SizedBox(width: 2),
          _WindowButton(
            tooltip: '关闭',
            onTap: _close,
            danger: true,
            painter: _ClosePainter(),
          ),
        ],
      ),
    );
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.tooltip,
    required this.onTap,
    required this.painter,
    this.danger = false,
  });

  final String tooltip;
  final VoidCallback onTap;
  final CustomPainter painter;

  /// 关闭按钮 hover 变红（对齐 DTV 的 `.close:hover { background:#e5344a }`）。
  final bool danger;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovered = false;
  bool _pressed = false;

  static const Color _closeHover = Color(0xFFE5344A);
  static const Color _closeActive = Color(0xFFC92439);

  @override
  Widget build(BuildContext context) {
    Color background;
    Color foreground;

    if (widget.danger) {
      background = _pressed
          ? _closeActive
          : (_hovered ? _closeHover : Colors.transparent);
      foreground = _hovered || _pressed
          ? Colors.white
          : TallyColors.textSecondary;
    } else {
      background = _pressed
          ? TallyColors.hairline
          : (_hovered ? TallyColors.raised : Colors.transparent);
      foreground = _hovered || _pressed
          ? TallyColors.textPrimary
          : TallyColors.textSecondary;
    }

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 110),
            curve: Curves.easeOut,
            width: 38,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(TallyRadius.pill),
            ),
            child: CustomPaint(
              size: const Size(10, 10),
              painter: _ThemedPainter(widget.painter, foreground),
            ),
          ),
        ),
      ),
    );
  }
}

/// 把颜色注入给具体图形，避免每个 painter 都带一个 color 字段。
class _ThemedPainter extends CustomPainter {
  const _ThemedPainter(this.inner, this.color);

  final CustomPainter inner;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (inner is _LinePainter) {
      final painter = inner as _LinePainter;
      painter.paintWith(canvas, size, color);
    }
  }

  @override
  bool shouldRepaint(covariant _ThemedPainter old) =>
      old.color != color || old.inner != inner;
}

/// 所有按钮图形共用的基类：统一线宽 1.8、圆头端点（对齐 DTV 的 SVG 描边）。
abstract class _LinePainter extends CustomPainter {
  const _LinePainter();

  Paint stroke(Color color) => Paint()
    ..color = color
    ..strokeWidth = 1.6
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke;

  void paintWith(Canvas canvas, Size size, Color color);

  @override
  void paint(Canvas canvas, Size size) =>
      paintWith(canvas, size, const Color(0xFFA7AAB2));

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _MinimisePainter extends _LinePainter {
  const _MinimisePainter();

  @override
  void paintWith(Canvas canvas, Size size, Color color) {
    final paint = stroke(color);
    final y = size.height / 2;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
  }
}

class _MaximisePainter extends _LinePainter {
  const _MaximisePainter();

  @override
  void paintWith(Canvas canvas, Size size, Color color) {
    final paint = stroke(color);
    // 略小于画布，避免描边被裁掉一半
    canvas.drawRect(
      Rect.fromLTWH(0.8, 0.8, size.width - 1.6, size.height - 1.6),
      paint,
    );
  }
}

class _RestorePainter extends _LinePainter {
  const _RestorePainter();

  @override
  void paintWith(Canvas canvas, Size size, Color color) {
    final paint = stroke(color);
    final small = size.width - 3;
    // 后层（右上）
    canvas.drawRect(
      Rect.fromLTWH(size.width - small, 0.8, small - 0.8, small - 0.8),
      paint,
    );
    // 前层（左下，用底色盖住后层重叠部分）
    final front = Rect.fromLTWH(0.8, size.height - small, small - 0.8, small - 0.8);
    canvas.drawRect(front, Paint()..color = const Color(0xFF14161B));
    canvas.drawRect(front, paint);
  }
}

class _ClosePainter extends _LinePainter {
  const _ClosePainter();

  @override
  void paintWith(Canvas canvas, Size size, Color color) {
    final paint = stroke(color);
    const inset = 0.8;
    canvas.drawLine(
      const Offset(inset, inset),
      Offset(size.width - inset, size.height - inset),
      paint,
    );
    canvas.drawLine(
      Offset(size.width - inset, inset),
      Offset(inset, size.height - inset),
      paint,
    );
  }
}

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tallylive/ui/theme.dart';

/// 自绘窗口控制按钮（最小化 / 最大化·还原 / 关闭）。
///
/// **对齐 DTV 的 `WindowControls.tsx`**：不是系统原生按钮，是自己画的，
/// 但通过 Wails 的 `--wails-non-client-region` 注册成原生非客户区，
/// 从而拥有系统按钮的命中测试与 Win11 贴靠布局。
///
/// Flutter 侧没有这个机制，所以这里用 `window_manager` 直接控制窗口，
/// 并自己处理 hover 高亮（对齐 Windows 11 的观感：关闭按钮 hover 变红）。
///
/// macOS 不显示这组（系统有红绿灯），与 DTV 一致。
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
    // macOS 用系统红绿灯；移动端没有窗口概念
    if (!_isDesktop) return const SizedBox.shrink();
    if (Platform.isMacOS) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WindowButton(
          tooltip: '最小化',
          onTap: _minimise,
          child: const _MinimiseIcon(),
        ),
        _WindowButton(
          tooltip: _maximised ? '还原' : '最大化',
          onTap: _toggleMaximise,
          child: _maximised ? const _RestoreIcon() : const _MaximiseIcon(),
        ),
        _WindowButton(
          tooltip: '关闭',
          onTap: _close,
          danger: true,
          child: const _CloseIcon(),
        ),
        const SizedBox(width: TallySpace.xs),
      ],
    );
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.tooltip,
    required this.onTap,
    required this.child,
    this.danger = false,
  });

  final String tooltip;
  final VoidCallback onTap;
  final Widget child;

  /// 关闭按钮 hover 变红（对齐 Windows 11）。
  final bool danger;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final Color background;
    final Color foreground;
    if (_hovered) {
      background = widget.danger
          ? const Color(0xFFC42B1C)
          : TallyColors.raised;
      foreground = widget.danger ? Colors.white : TallyColors.textPrimary;
    } else {
      background = Colors.transparent;
      foreground = TallyColors.textSecondary;
    }

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            width: 44,
            height: TallySize.navbar,
            alignment: Alignment.center,
            color: background,
            child: IconTheme(
              data: IconThemeData(color: foreground, size: 16),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 图标用简单几何线条画，比 Material 图标更接近系统按钮的观感。
class _MinimiseIcon extends StatelessWidget {
  const _MinimiseIcon();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 10,
      height: 10,
      child: Center(
        child: Container(height: 1, color: IconTheme.of(context).color),
      ),
    );
  }
}

class _MaximiseIcon extends StatelessWidget {
  const _MaximiseIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        border: Border.all(color: IconTheme.of(context).color!, width: 1),
      ),
    );
  }
}

class _RestoreIcon extends StatelessWidget {
  const _RestoreIcon();

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color!;
    return SizedBox(
      width: 12,
      height: 12,
      child: Stack(
        children: [
          Positioned(
            right: 0,
            top: 0,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                border: Border.all(color: color, width: 1),
              ),
            ),
          ),
          Positioned(
            left: 0,
            bottom: 0,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                border: Border.all(color: color, width: 1),
                color: TallyColors.base,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CloseIcon extends StatelessWidget {
  const _CloseIcon();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 10,
      height: 10,
      child: CustomPaint(
        painter: _CrossPainter(IconTheme.of(context).color!),
      ),
    );
  }
}

class _CrossPainter extends CustomPainter {
  const _CrossPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset.zero, Offset(size.width, size.height), paint);
    canvas.drawLine(
      Offset(size.width, 0),
      Offset(0, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _CrossPainter oldDelegate) =>
      oldDelegate.color != color;
}

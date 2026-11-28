import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tallylive/ui/theme.dart';

/// 圆环进度条（对齐 DTV 的 `RingProgress`）。
///
/// 侧栏刷新按钮在刷新期间用它套在刷新图标外面：
/// 图标照常转圈，**圆环的弧长表示「已刷新 / 总数」**。
///
/// DTV 用 SVG 的 stroke-dasharray；Flutter 用 CustomPainter 画弧，
/// 同样能做圆头端点，且高 DPI 下边缘干净。
class RingProgress extends StatelessWidget {
  const RingProgress({
    super.key,
    required this.value,
    this.size = 28,
    this.stroke = 2.5,
  });

  /// 进度 0~1（越界自动裁剪）。
  final double value;
  final double size;
  final double stroke;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          value: value.isFinite ? value.clamp(0.0, 1.0) : 0,
          stroke: stroke,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.value, required this.stroke});

  final double value;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - stroke) / 2;

    // 底环（始终画，表示"总量"）
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = TallyColors.hairline;
    canvas.drawCircle(center, radius, track);

    if (value <= 0) return;

    // 进度弧：从 12 点方向顺时针
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = TallyColors.signalBlue;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * value,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.value != value || old.stroke != stroke;
}

/// 转圈图标（刷新中图标自转，配合外圈 RingProgress）。
class SpinningIcon extends StatefulWidget {
  const SpinningIcon({
    super.key,
    required this.icon,
    this.size = 15,
    this.color = TallyColors.textSecondary,
  });

  final IconData icon;
  final double size;
  final Color color;

  @override
  State<SpinningIcon> createState() => _SpinningIconState();
}

class _SpinningIconState extends State<SpinningIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Icon(widget.icon, size: widget.size, color: widget.color),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:tallylive/ui/theme.dart';

/// 空态：居中图标 + 一行说明 + 可选主按钮。
///
/// 规则：**不画插画**，图标用线性图标且只用 `textTertiary`，
/// 避免空态变成视觉噪音。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(TallySpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: TallyColors.textTertiary),
            const SizedBox(height: TallySpace.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TallyType.subtitle,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: TallySpace.md),
              TextButton(
                onPressed: onAction,
                child: Text(
                  actionLabel!,
                  style: const TextStyle(
                    color: TallyColors.signalBlue,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 错误态：文案 + 重试。
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.message,
    this.onRetry,
    this.retryLabel = '重试',
  });

  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(TallySpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined,
                size: 40, color: TallyColors.textTertiary),
            const SizedBox(height: TallySpace.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TallyType.subtitle,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: TallySpace.sm),
              TextButton(
                onPressed: onRetry,
                child: Text(
                  retryLabel,
                  style: const TextStyle(
                    color: TallyColors.signalBlue,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 加载骨架色块。
///
/// 刻意**不做闪光动画**：夜间界面里来回扫光很刺眼，只用固定的 `raised` 色块。
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height = 12,
    this.radius = 4,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: TallyColors.raised,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// 列表行骨架（高度对齐真实行 64px）。
class SkeletonRow extends StatelessWidget {
  const SkeletonRow({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: Row(
        children: [
          const SkeletonBox(width: 40, height: 40, radius: 40),
          const SizedBox(width: TallySpace.md),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                SkeletonBox(width: 96, height: 14),
                SizedBox(height: TallySpace.sm),
                SkeletonBox(width: 180, height: 11),
              ],
            ),
          ),
          const SizedBox(width: TallySpace.md),
          const SkeletonBox(width: 44, height: 12),
        ],
      ),
    );
  }
}

/// 卡片骨架（封面 16:9 + 两行文字）。
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: SkeletonBox(height: double.infinity, radius: TallyRadius.card),
        ),
        SizedBox(height: TallySpace.sm),
        SkeletonBox(width: 88, height: 13),
        SizedBox(height: 6),
        SkeletonBox(width: 140, height: 11),
      ],
    );
  }
}

/// 底部「加载更多」指示（32px 高，不打断节奏）。
class LoadingMore extends StatelessWidget {
  const LoadingMore({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 32,
      child: Center(
        child: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 1.6,
            color: TallyColors.textTertiary,
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:tallylive/ui/components/atoms.dart';
import 'package:tallylive/ui/theme.dart';

/// 区块标题。
///
/// 左侧：小号大写感的标题（13/w600/字距 0.6）；
/// 右侧：可选动作（如「刷新」「更多」），用 `signalBlue` 文字。
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.trailingLabel,
    this.onTrailingTap,
    this.count,
  });

  final String title;

  /// 右侧动作文案；为空则不显示。
  final String? trailingLabel;
  final VoidCallback? onTrailingTap;

  /// 可选计数（显示在标题后面，tabular 数字）。
  final int? count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: TallySpace.md,
        right: TallySpace.sm,
        top: TallySpace.lg,
        bottom: TallySpace.sm,
      ),
      child: Row(
        children: [
          Text(title, style: TallyType.sectionTitle),
          if (count != null) ...[
            const SizedBox(width: TallySpace.sm),
            Text(
              '$count',
              style: TallyType.numberSmall.copyWith(
                color: TallyColors.textTertiary,
              ),
            ),
          ],
          const Spacer(),
          if (trailingLabel != null && onTrailingTap != null)
            TextButton(
              onPressed: onTrailingTap,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: TallySpace.sm),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                trailingLabel!,
                style: const TextStyle(
                  fontSize: 12,
                  color: TallyColors.signalBlue,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// ON AIR 计数行（首页顶部那条 tally 线）。
class TallyHeader extends StatelessWidget {
  const TallyHeader({super.key, required this.liveCount});

  final int liveCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: TallySpace.md),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: TallyColors.hairline)),
      ),
      child: Row(
        children: [
          const LiveDot(),
          const SizedBox(width: TallySpace.sm),
          const Text(
            '正在直播',
            style: TextStyle(fontSize: 12, color: TallyColors.textSecondary),
          ),
          const SizedBox(width: TallySpace.sm),
          Text(
            '$liveCount',
            style: TallyType.number.copyWith(fontSize: 13),
          ),
        ],
      ),
    );
  }
}

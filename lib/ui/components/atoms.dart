import 'package:flutter/material.dart';
import 'package:tallylive/ui/theme.dart';

/// ON AIR 圆点。
///
/// **唯一允许使用 tallyRed 的地方之一**（另一个是 LIVE 徽章）。
class LiveDot extends StatelessWidget {
  const LiveDot({super.key, this.size = 6, this.dimmed = false});

  final double size;

  /// 下播/不可用时置灰。
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: dimmed ? TallyColors.textTertiary : TallyColors.tallyRed,
      ),
    );
  }
}

/// 「LIVE」文字徽章（压在封面上）。
class LiveBadge extends StatelessWidget {
  const LiveBadge({super.key, this.compact = false});

  /// compact = 只显示圆点 + LIVE 两个字符宽度的紧凑版。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? TallySpace.xs + 2 : TallySpace.sm,
        vertical: 2,
      ),
      decoration: TallyDecor.liveBadgePill,
      child: const Text('LIVE', style: TallyType.liveBadge),
    );
  }
}

/// 人气数字格式化：10234 → 1.0万，123456789 → 1.2亿。
String formatViewers(int viewers) {
  if (viewers >= 100000000) {
    final value = viewers / 100000000;
    return '${value.toStringAsFixed(1)}亿';
  }
  if (viewers >= 10000) {
    final value = viewers / 10000;
    // 万级保留一位，但整数就不显示 .0
    final text = value >= 100 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
    return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text}万';
  }
  return viewers.toString();
}

/// 压在封面右上角的人气徽章。
class ViewerBadge extends StatelessWidget {
  const ViewerBadge({super.key, required this.viewers});

  final int viewers;

  @override
  Widget build(BuildContext context) {
    if (viewers <= 0) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: TallyDecor.badgeOverlay,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.remove_red_eye_outlined,
              size: 11, color: TallyColors.textPrimary),
          const SizedBox(width: 3),
          Text(formatViewers(viewers), style: TallyType.numberSmall),
        ],
      ),
    );
  }
}

/// 封面图。
///
/// 设计约束：**不做渐变占位**。加载中/失败/无 URL 一律显示 `raised` 纯色块 + 首字，
/// 保持夜间界面的安静。
class CoverBox extends StatelessWidget {
  const CoverBox({
    super.key,
    required this.url,
    required this.fallbackText,
    this.borderRadius = TallyRadius.card,
  });

  final String url;

  /// 无图时显示的文字（通常取主播名首字）。
  final String fallbackText;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);
    if (url.isEmpty) {
      return _fallback(radius);
    }
    return ClipRRect(
      borderRadius: radius,
      child: Image.network(
        url,
        fit: BoxFit.cover,
        // 封面是装饰性内容，无图不影响理解
        errorBuilder: (context, error, stack) => _fallback(radius),
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return _fallback(radius);
        },
      ),
    );
  }

  Widget _fallback(BorderRadius radius) {
    final initial = _firstChar(fallbackText);
    return Container(
      decoration: BoxDecoration(color: TallyColors.raised, borderRadius: radius),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: TallyColors.textTertiary,
        ),
      ),
    );
  }
}

/// 圆形头像。
class AvatarBox extends StatelessWidget {
  const AvatarBox({
    super.key,
    required this.url,
    required this.fallbackText,
    this.size = 40,
  });

  final String url;
  final String fallbackText;
  final double size;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: TallyColors.raised,
      ),
      alignment: Alignment.center,
      child: Text(
        _firstChar(fallbackText),
        style: TextStyle(
          fontSize: size * 0.4,
          fontWeight: FontWeight.w600,
          color: TallyColors.textTertiary,
        ),
      ),
    );

    if (url.isEmpty) return placeholder;

    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: Image.network(
          url,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stack) => placeholder,
          loadingBuilder: (context, child, progress) =>
              progress == null ? child : placeholder,
        ),
      ),
    );
  }
}

/// 平台标记（列表里的来源提示，极简：两字文字，不用品牌色）。
class PlatformTag extends StatelessWidget {
  const PlatformTag({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: TallyColors.raised,
        borderRadius: BorderRadius.circular(TallyRadius.badge),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 10, color: TallyColors.textTertiary),
      ),
    );
  }
}

/// 取首字（用 runes 避免依赖 characters 扩展）。
String _firstChar(String text) {
  if (text.isEmpty) return '·';
  return String.fromCharCode(text.runes.first);
}
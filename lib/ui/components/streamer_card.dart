import 'package:flutter/material.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/ui/components/atoms.dart';
import 'package:tallylive/ui/theme.dart';

/// 直播封面卡片（精选/分区/发现用）。
///
/// 与 [StreamerRow] 的分工：卡片优化「看图找内容」，所以封面占主体；
/// 但昵称仍是主色 14pt（DTV 里昵称字号偏小，我们提一档）。
///
/// hover 只做**封面轻微提亮**，不位移、不放大（UI-DESIGN §6）。
class StreamerCard extends StatefulWidget {
  const StreamerCard({
    super.key,
    required this.streamer,
    this.onTap,
    this.showPlatformTag = false,
  });

  final Streamer streamer;
  final VoidCallback? onTap;
  final bool showPlatformTag;

  @override
  State<StreamerCard> createState() => _StreamerCardState();
}

class _StreamerCardState extends State<StreamerCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final streamer = widget.streamer;
    final dimmed = !streamer.isLive;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(TallyRadius.card),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CoverBox(
                      url: streamer.cover,
                      fallbackText: streamer.nickname,
                      borderRadius: 0,
                    ),
                    // 下播：整体压暗，且不显示 LIVE 徽章
                    if (dimmed)
                      Container(color: Colors.black.withValues(alpha: 0.45)),
                    // hover 提亮（只加一层极淡白，不改变布局）
                    if (_hovered && !dimmed)
                      Container(color: Colors.white.withValues(alpha: 0.04)),
                    // 左上：LIVE
                    if (!dimmed)
                      const Positioned(
                        left: TallySpace.sm,
                        top: TallySpace.sm,
                        child: LiveBadge(),
                      ),
                    // 右上：人气
                    if (streamer.viewers > 0)
                      Positioned(
                        right: TallySpace.sm,
                        top: TallySpace.sm,
                        child: ViewerBadge(viewers: streamer.viewers),
                      ),
                    // 下播标签（右下）
                    if (dimmed)
                      Positioned(
                        right: TallySpace.sm,
                        bottom: TallySpace.sm,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: TallyDecor.badgeOverlay,
                          child: const Text(
                            '未开播',
                            style: TextStyle(
                              fontSize: 10,
                              color: TallyColors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: TallySpace.sm),
            Row(
              children: [
                Flexible(
                  child: Text(
                    streamer.nickname,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: dimmed
                          ? TallyColors.textTertiary
                          : TallyColors.textPrimary,
                    ),
                  ),
                ),
                if (widget.showPlatformTag) ...[
                  const SizedBox(width: 6),
                  PlatformTag(text: streamer.platform.label),
                ],
              ],
            ),
            const SizedBox(height: 3),
            Text(
              streamer.title.isEmpty ? '这个直播间还没有标题' : streamer.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TallyType.meta,
            ),
          ],
        ),
      ),
    );
  }
}

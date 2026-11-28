import 'package:flutter/material.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/ui/components/atoms.dart';
import 'package:tallylive/ui/theme.dart';

/// 直播列表行（64px）。
///
/// 用于「关注中在播」和分区/搜索结果——**高频、目标明确的场景用行而不是卡片**：
/// 昵称在前、人气用 tabular 数字、整行可点，一眼就能决定进不进。
class StreamerRow extends StatefulWidget {
  const StreamerRow({
    super.key,
    required this.streamer,
    this.onTap,
    this.showPlatformTag = false,
  });

  final Streamer streamer;
  final VoidCallback? onTap;

  /// 跨平台列表（如搜索结果「全部平台」）时显示来源标记。
  final bool showPlatformTag;

  @override
  State<StreamerRow> createState() => _StreamerRowState();
}

class _StreamerRowState extends State<StreamerRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final streamer = widget.streamer;
    // 下播：整体压暗，但保留可点（可能刚开播，进去有提示）
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
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: TallySpace.md),
          decoration: BoxDecoration(
            color: _hovered ? TallyColors.raised : Colors.transparent,
            borderRadius: BorderRadius.circular(TallyRadius.card),
          ),
          child: Opacity(
            opacity: dimmed ? 0.55 : 1,
            child: Row(
              children: [
                LiveDot(dimmed: dimmed),
                const SizedBox(width: TallySpace.sm + 2),
                AvatarBox(
                  url: streamer.avatar,
                  fallbackText: streamer.nickname,
                  size: 40,
                ),
                const SizedBox(width: TallySpace.md),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              streamer.nickname,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TallyType.nickname,
                            ),
                          ),
                          if (widget.showPlatformTag) ...[
                            const SizedBox(width: 6),
                            PlatformTag(text: streamer.platform.label),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        streamer.title.isEmpty
                            ? (dimmed ? '未开播' : '直播中')
                            : streamer.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TallyType.subtitle,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: TallySpace.md),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (streamer.viewers > 0)
                      Text(formatViewers(streamer.viewers),
                          style: TallyType.number),
                    if (streamer.categoryName.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(streamer.categoryName, style: TallyType.meta),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

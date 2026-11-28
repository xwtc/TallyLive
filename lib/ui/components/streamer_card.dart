import 'package:flutter/material.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/ui/components/atoms.dart';
import 'package:tallylive/ui/theme.dart';

/// 主播卡片（像素级对齐 DTV 的 StreamerCard）。
///
/// DTV 的规格（`StreamerCard.module.css`）：
/// - 卡片：`bg-secondary` 表面、12px 圆角、**无描边**、顶部 1px 受光边
/// - 封面：16:9 贴边；hover 时 **scale(1.02)**（320ms）
/// - 封面中央 hover 浮现 46px 圆形播放按钮
/// - 封面左上 hover 浮现 32px 关注按钮；已关注时常驻并填充强调色
/// - 封面右上：人气胶囊（高 22、字 11、tabular 数字、半透明黑底）
/// - 信息区：padding 13/12/15；头像 32 + 昵称 13/w600 + 标题 12 单行省略
/// - 分类胶囊：accent-soft 底 + accent-ink 字，宽 < 260 时隐藏
class StreamerCard extends StatefulWidget {
  const StreamerCard({
    super.key,
    required this.streamer,
    this.onTap,
    this.onSecondaryTap,
    this.showPlatformTag = false,
    this.followed = false,
    this.onToggleFollow,
  });

  final Streamer streamer;
  final VoidCallback? onTap;

  /// 右键（桌面）打开操作菜单。
  final VoidCallback? onSecondaryTap;
  final bool showPlatformTag;

  /// 是否已关注（由外部传入，卡片自身不持有状态）。
  final bool followed;
  final VoidCallback? onToggleFollow;

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
        onSecondaryTap: widget.onSecondaryTap,
        child: Container(
          decoration: TallyDecor.cardPlain,
          // 只裁切封面圆角，信息区仍要贴边
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCover(streamer, dimmed),
              // 用 Expanded 吃掉剩余高度：网格单元比内容矮时（窄窗口/测试环境）
              // 也不会抛 RenderFlex overflow，只是信息区被裁掉一点。
              Expanded(child: _buildMeta(streamer, dimmed)),
            ],
          ),
        ),
      ),
    );
  }

  /// 封面区：16:9 + hover 缩放 + 播放按钮 + 关注按钮 + 人气。
  Widget _buildCover(Streamer streamer, bool dimmed) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 封面本身（hover 放大 1.02，320ms）
          AnimatedScale(
            scale: _hovered && !dimmed ? 1.02 : 1,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOut,
            child: CoverBox(
              url: streamer.cover,
              fallbackText: streamer.nickname,
              borderRadius: 0,
            ),
          ),
          if (dimmed) Container(color: Colors.black.withValues(alpha: 0.45)),

          // 中央播放按钮（hover 浮现）
          if (_hovered && !dimmed)
            Center(
              child: Container(
                width: 46,
                height: 46,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: TallyColors.signalBlue,
                ),
                child: const Icon(Icons.play_arrow,
                    size: 26, color: Colors.white),
              ),
            ),

          // 左上关注按钮（hover 浮现；已关注常驻）
          if (widget.onToggleFollow != null &&
              (_hovered || widget.followed))
            Positioned(
              left: 8,
              top: 8,
              child: GestureDetector(
                onTap: widget.onToggleFollow,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.followed
                        ? TallyColors.signalBlue
                        : TallyColors.badgeScrim,
                    border: Border.all(
                      color: widget.followed
                          ? Colors.transparent
                          : Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  child: Icon(
                    widget.followed ? Icons.check : Icons.add,
                    size: 17,
                    color: widget.followed ? Colors.white : Colors.white,
                  ),
                ),
              ),
            ),

          // 右上人气
          if (streamer.viewers > 0)
            Positioned(
              right: 10,
              top: 10,
              child: ViewerBadge(viewers: streamer.viewers),
            ),

          // 未开播标签
          if (dimmed)
            Positioned(
              right: 10,
              bottom: 10,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: TallyDecor.badgeOverlay,
                child: const Text(
                  '未开播',
                  style: TextStyle(
                    fontSize: 11,
                    color: TallyColors.textSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 信息区：头像 + 昵称/标题 + 分类胶囊。
  Widget _buildMeta(Streamer streamer, bool dimmed) {
    return Container(
      padding: TallySize.cardMetaPadding,
      alignment: Alignment.topLeft,
      clipBehavior: Clip.hardEdge,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AvatarBox(
            url: streamer.avatar,
            fallbackText: streamer.nickname,
            size: 32,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  streamer.nickname,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.002,
                    color: dimmed
                        ? TallyColors.textTertiary
                        : (_hovered
                            ? TallyColors.accentInk
                            : TallyColors.textPrimary),
                  ),
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
          if (widget.showPlatformTag) ...[
            const SizedBox(width: 6),
            PlatformTag(text: streamer.platform.label),
          ],
          // 分类胶囊（宽度不够时由 LayoutBuilder 决定是否显示）
          if (streamer.categoryName.isNotEmpty) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: TallyColors.accentSoft,
                  borderRadius: BorderRadius.circular(TallyRadius.pill),
                ),
                child: Text(
                  streamer.categoryName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: TallyColors.accentInk,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

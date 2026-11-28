import 'package:flutter/material.dart';
import 'package:tallylive/core/feed_ui.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/ui/theme.dart';

/// 顶栏（对齐 DTV 的 Navbar 结构）。
///
/// ```
/// [平台分段：斗鱼 虎牙 抖音 B站]        [搜索框]  [设置][关于]
/// ```
///
/// 与 DTV 的差异（按需求）：
/// - 去掉了「打开 GitHub 项目」按钮；
/// - 去掉了主题配色切换（我们只有一套自定主题，不做预设切换）；
/// - 去掉了「数据同步」（待接入时不放死按钮）；
/// - 自绘窗口按钮（最小化/最大化/关闭）没做——我们用的是系统标题栏，
///   再做一套会和系统按钮重复。
class Navbar extends StatelessWidget {
  const Navbar({
    super.key,
    required this.tabIndex,
    required this.onTabSelected,
  });

  final int tabIndex;
  final ValueChanged<int> onTabSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: TallySize.navbar,
      padding: const EdgeInsets.symmetric(horizontal: TallySpace.page),
      decoration: const BoxDecoration(
        color: TallyColors.base,
        border: Border(bottom: BorderSide(color: TallyColors.hairline)),
      ),
      child: Row(
        children: [
          // 平台分段（只在「直播」页有意义）
          if (tabIndex == 0) const PlatformTabs(),
          if (tabIndex != 0) ...[
            Text(
              ['直播', '设置', '关于'][tabIndex],
              style: TallyType.pageTitle,
            ),
          ],
          const Spacer(),
          if (tabIndex == 0) ...[
            const _SearchBox(),
            const SizedBox(width: TallySpace.md),
          ],
          _ToolButton(
            icon: Icons.tune,
            tooltip: '设置',
            active: tabIndex == 1,
            onTap: () => onTabSelected(1),
          ),
          const SizedBox(width: TallySpace.xs),
          _ToolButton(
            icon: Icons.info_outline,
            tooltip: '关于',
            active: tabIndex == 2,
            onTap: () => onTabSelected(2),
          ),
        ],
      ),
    );
  }
}

/// 平台分段控件：胶囊外形 + 凹槽底 + 选中项抬升。
class PlatformTabs extends StatelessWidget {
  const PlatformTabs({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: FeedUi.instance,
      builder: (context, _) {
        final feed = FeedUi.instance;
        if (feed.platforms.isEmpty) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.all(3),
          decoration: TallyDecor.inset,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final platform in feed.platforms)
                _PlatformPill(
                  label: platform.label,
                  selected: feed.platform == platform,
                  onTap: () => feed.select(platform),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _PlatformPill extends StatefulWidget {
  const _PlatformPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_PlatformPill> createState() => _PlatformPillState();
}

class _PlatformPillState extends State<_PlatformPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: TallyDuration.fast,
          curve: Curves.easeOut,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: widget.selected
                ? TallyColors.raised
                : (_hovered ? TallyColors.raised.withValues(alpha: 0.6) : Colors.transparent),
            borderRadius: BorderRadius.circular(TallyRadius.pill),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
              color: widget.selected
                  ? TallyColors.textPrimary
                  : TallyColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 搜索框（外观对齐 DTV：凹槽底 + 胶囊 + 右侧放大镜）。
///
/// 搜索页尚未接入，点击给明确提示，不做假交互。
class _SearchBox extends StatelessWidget {
  const _SearchBox();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 280,
      height: 36,
      child: MouseRegion(
        cursor: SystemMouseCursors.text,
        child: GestureDetector(
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('搜索页待接入')),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: TallySpace.md),
            decoration: TallyDecor.inset,
            child: Row(
              children: const [
                Expanded(
                  child: Text(
                    '搜索关键词或直播间号',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: TallyColors.textTertiary),
                  ),
                ),
                Icon(Icons.search, size: 17, color: TallyColors.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatefulWidget {
  const _ToolButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  @override
  State<_ToolButton> createState() => _ToolButtonState();
}

class _ToolButtonState extends State<_ToolButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: TallyDuration.fast,
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.active || _hovered
                  ? TallyColors.raised
                  : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Icon(
              widget.icon,
              size: 18,
              color: widget.active
                  ? TallyColors.textPrimary
                  : TallyColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 供 LivePage 在窄屏时使用的平台下拉（复用一个数据源）。
class NavbarPlatformDropdown extends StatelessWidget {
  const NavbarPlatformDropdown({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: FeedUi.instance,
      builder: (context, _) {
        final feed = FeedUi.instance;
        final current = feed.platform;
        return PopupMenuButton<LivePlatform>(
          color: TallyColors.raised,
          onSelected: feed.select,
          itemBuilder: (context) => [
            for (final platform in feed.platforms)
              PopupMenuItem(
                value: platform,
                child: Text(
                  platform.label,
                  style: TextStyle(
                    fontSize: 13,
                    color: platform == current
                        ? TallyColors.textPrimary
                        : TallyColors.textSecondary,
                  ),
                ),
              ),
          ],
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: TallySpace.md),
            decoration: TallyDecor.inset,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(current?.label ?? '平台', style: TallyType.subtitle),
                const SizedBox(width: 2),
                const Icon(Icons.expand_more,
                    size: 16, color: TallyColors.textSecondary),
              ],
            ),
          ),
        );
      },
    );
  }
}

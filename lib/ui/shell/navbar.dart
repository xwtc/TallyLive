import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:tallylive/core/feed_ui.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/ui/components/inline_search.dart';
import 'package:tallylive/ui/components/sync_sheet.dart';
import 'package:tallylive/ui/shell/window_controls.dart';
import 'package:tallylive/ui/theme.dart';

/// 顶栏（对齐 DTV 的 `Navbar.tsx`）。
///
/// ```
/// [平台分段]                      [搜索框] [GitHub][同步][主题]  [─ □ ×]
/// ```
///
/// 与 DTV 的差异（按需求）：
/// - 去掉「打开 GitHub 项目」按钮
/// - 去掉主题配色切换（只有一套自定主题）
/// - **保留自绘窗口按钮**（DTV 也是自绘，通过 `--wails-non-client-region`
///   注册成原生非客户区；Flutter 没有该机制，用 window_manager 直接控制）
class Navbar extends StatelessWidget {
  const Navbar({super.key});

  @override
  Widget build(BuildContext context) {
    final bar = Container(
      height: TallySize.navbar,
      decoration: const BoxDecoration(
        color: TallyColors.base,
        border: Border(bottom: BorderSide(color: TallyColors.hairline)),
      ),
      child: Row(
        children: [
          const SizedBox(width: TallySpace.page),
          const PlatformTabs(),
          const Spacer(),
          // 内联搜索（聚焦展开 + 自动联想，不跳页面）
          const InlineSearch(),
          const SizedBox(width: TallySpace.sm),
          // 工具组：数据同步
          _ToolGroup(children: [
            _ToolButton(
              icon: Icons.sync_alt,
              tooltip: '数据同步',
              onTap: () {
                showModalBottomSheet<void>(
                  context: context,
                  backgroundColor: TallyColors.raised,
                  isScrollControlled: true,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                  ),
                  builder: (_) => const SyncSheet(),
                );
              },
            ),
          ]),
          const SizedBox(width: TallySpace.sm),
          // 自绘窗口按钮（最小化 / 最大化 / 关闭）
          const WindowControls(),
        ],
      ),
    );
    // 隐藏系统标题栏后窗口就失去了原生拖动区域，
    // 这里用 DragToMoveArea 把顶栏变成可拖拽的「标题栏」；
    // 双击顶栏空白处切换最大化（Windows 习惯）。
    if (!_hasNativeChrome) return bar;
    return DragToMoveArea(child: bar);
  }
}

/// 是否使用自绘窗口装饰（Windows / Linux）。
///
/// macOS 用系统红绿灯、移动端没有窗口概念，都不需要额外拖动层。
bool get _hasNativeChrome {
  if (kIsWeb) return false;
  return Platform.isLinux || Platform.isWindows;
}

/// 工具组容器（对齐 DTV 的 `.toolGroup`：凹槽底 + 胶囊）。
class _ToolGroup extends StatelessWidget {
  const _ToolGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: TallyDecor.inset,
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
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
                : (_hovered
                    ? TallyColors.raised.withValues(alpha: 0.6)
                    : Colors.transparent),
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

class _ToolButton extends StatefulWidget {
  const _ToolButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

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
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hovered
                  ? TallyColors.raised
                  : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Icon(
              widget.icon,
              size: 16,
              color: _hovered
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
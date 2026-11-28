import 'package:flutter/material.dart';
import 'package:tallylive/core/player_session.dart';
import 'package:tallylive/ui/about_page.dart';
import 'package:tallylive/ui/live_page.dart';
import 'package:tallylive/ui/settings_page.dart';
import 'package:tallylive/ui/shell/player_layer.dart';
import 'package:tallylive/ui/shell/sidebar.dart';
import 'package:tallylive/ui/theme.dart';

/// 应用外壳（对齐 DTV 的 AppShell）。
///
/// ```
/// 桌面（≥ 1024）
/// Row
/// ├── Sidebar   关注栏（播放时依然在，可换台）
/// └── Column
///     ├── Navbar
///     └── Stack
///         ├── IndexedStack(页面，保活)
///         └── PlayerLayer   ← 播放层叠在上面
///
/// 手机（< 600）
/// Stack
/// ├── Column(IndexedStack + 底部 Tab)
/// └── PlayerLayer（全屏覆盖，含关闭）
/// ```
///
/// 全屏时壳层让位（`isFullscreen`）：侧栏与顶栏用 [Offstage] 收起，
/// 但 **state 保留**（收起/展开、Tab 位置都不会丢），内容区自然撑满。
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tabIndex = 0;

  static const List<Widget> _pages = [
    LivePage(),
    SettingsPage(),
    AboutPage(),
  ];

  static const List<NavigationDestination> _destinations = [
    NavigationDestination(
      icon: Icon(Icons.live_tv_outlined),
      selectedIcon: Icon(Icons.live_tv, color: TallyColors.tallyRed),
      label: '直播',
    ),
    NavigationDestination(
      icon: Icon(Icons.tune_outlined),
      selectedIcon: Icon(Icons.tune, color: TallyColors.signalBlue),
      label: '设置',
    ),
    NavigationDestination(
      icon: Icon(Icons.info_outline),
      selectedIcon: Icon(Icons.info, color: TallyColors.signalBlue),
      label: '关于',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PlayerSession.instance,
      builder: (context, _) {
        final session = PlayerSession.instance;
        final wide = MediaQuery.sizeOf(context).width >= TallyBreakpoints.expanded;
        final chromeHidden = session.isFullscreen;

        if (wide) {
          return Scaffold(
            backgroundColor: TallyColors.base,
            body: Row(
              children: [
                Offstage(
                  offstage: chromeHidden,
                  child: const Sidebar(),
                ),
                Expanded(
                  child: Column(
                    children: [
                      Offstage(
                        offstage: chromeHidden,
                        child: _Navbar(
                          tabIndex: _tabIndex,
                          onTabSelected: (value) =>
                              setState(() => _tabIndex = value),
                        ),
                      ),
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            IndexedStack(index: _tabIndex, children: _pages),
                            const PlayerLayer(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        // 手机：底部 Tab + 全屏播放层覆盖一切
        return Scaffold(
          backgroundColor: TallyColors.base,
          body: Stack(
            fit: StackFit.expand,
            children: [
              Column(
                children: [
                  Expanded(
                    child: IndexedStack(index: _tabIndex, children: _pages),
                  ),
                  if (!session.isOpen)
                    NavigationBar(
                      selectedIndex: _tabIndex,
                      onDestinationSelected: (value) =>
                          setState(() => _tabIndex = value),
                      backgroundColor: TallyColors.surface,
                      indicatorColor: TallyColors.raised,
                      height: 60,
                      destinations: _destinations,
                    ),
                ],
              ),
              const PlayerLayer(),
            ],
          ),
        );
      },
    );
  }
}

/// 顶栏：标题 + 设置/关于入口。
///
/// 平台切换与分区筛选都在内容区（[LivePage]）里，避免"顶栏一套、
/// 内容区又一套"的双重状态源。
class _Navbar extends StatelessWidget {
  const _Navbar({required this.tabIndex, required this.onTabSelected});

  final int tabIndex;
  final ValueChanged<int> onTabSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      decoration: const BoxDecoration(
        color: TallyColors.surface,
        border: Border(bottom: BorderSide(color: TallyColors.hairline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: TallySpace.md),
      child: Row(
        children: [
          // 顶部三个一级入口（桌面没有底部 Tab，放到顶栏）
          for (var index = 0; index < 3; index++) ...[
            _NavTab(
              label: ['直播', '设置', '关于'][index],
              selected: tabIndex == index,
              onTap: () => onTabSelected(index),
            ),
            const SizedBox(width: TallySpace.xs),
          ],
          const Spacer(),
          IconButton(
            tooltip: '搜索（待接入）',
            iconSize: 18,
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('搜索页待接入')),
              );
            },
            icon: const Icon(Icons.search, color: TallyColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _NavTab extends StatelessWidget {
  const _NavTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: TallySpace.md),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? TallyColors.raised : Colors.transparent,
            borderRadius: BorderRadius.circular(TallyRadius.card),
            border: Border.all(
              color: selected ? TallyColors.signalBlue : Colors.transparent,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color:
                  selected ? TallyColors.textPrimary : TallyColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

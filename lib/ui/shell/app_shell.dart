import 'package:flutter/material.dart';
import 'package:tallylive/core/player_session.dart';
import 'package:tallylive/ui/about_page.dart';
import 'package:tallylive/ui/live_page.dart';
import 'package:tallylive/ui/settings_page.dart';
import 'package:tallylive/ui/shell/player_layer.dart';
import 'package:tallylive/ui/shell/navbar.dart';
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
                        child: Navbar(
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

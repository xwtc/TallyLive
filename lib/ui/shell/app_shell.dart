import 'package:flutter/material.dart';
import 'package:tallylive/core/player_session.dart';
import 'package:tallylive/ui/live_page.dart';
import 'package:tallylive/ui/shell/navbar.dart';
import 'package:tallylive/ui/shell/player_layer.dart';
import 'package:tallylive/ui/shell/search_panel_host.dart';
import 'package:tallylive/ui/shell/sidebar.dart';
import 'package:tallylive/ui/theme.dart';

/// 应用外壳（完全对齐 DTV 的 AppShell）。
///
/// ```
/// 桌面（≥ 1024）
/// Stack
/// ├── Row
/// │   ├── Sidebar   关注栏（播放时依然在，可换台；无关注时自动收成 rail）
/// │   └── Column
/// │       ├── Navbar   平台分段 + 搜索
/// │       └── Stack
/// │           ├── LivePage       ← 常驻（保活）
/// │           └── PlayerLayer    ← 播放层叠在上面
/// └── SearchPanelHost   ← 搜索浮层（窗口级，压过顶栏与播放层）
/// ```
///
/// ⚠️ 搜索浮层必须挂**窗口级**而不是 Navbar 下面那层 Stack：
/// 输入框在 Navbar 里，浮层从输入框下方展开，若宿主从 Navbar 底边才开始，
/// 浮层顶部就会被那层 Stack 裁掉一截。
///
/// 手机（< 600）
/// Stack
/// ├── LivePage
/// └── PlayerLayer（全屏覆盖，含关闭）
///
/// 没有「设置」「关于」页：对齐 DTV —— 它的设置都是内联控件
/// （播放页的弹幕设置、音量、清晰度），不做独立设置页；
/// 主题固定唯一，不做预设切换。
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PlayerSession.instance,
      builder: (context, _) {
        final session = PlayerSession.instance;
        final wide =
            MediaQuery.sizeOf(context).width >= TallyBreakpoints.expanded;
        final chromeHidden = session.isFullscreen;

        if (wide) {
          return Scaffold(
            backgroundColor: TallyColors.base,
            body: Stack(
              fit: StackFit.expand,
              children: [
                Row(
                  children: [
                    // 全屏时收起侧栏，但用 Offstage 保留 state（折叠状态不丢）
                    Offstage(
                      offstage: chromeHidden,
                      child: const Sidebar(),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          Offstage(
                            offstage: chromeHidden,
                            child: const Navbar(),
                          ),
                          Expanded(
                            child: Stack(
                              fit: StackFit.expand,
                              children: const [
                                LivePage(),
                                PlayerLayer(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                // 窗口级搜索浮层：坐标就是窗口坐标，不会被顶栏裁切
                const SearchPanelHost(),
              ],
            ),
          );
        }

        // 手机：没有底部 Tab（只有直播一页），播放层覆盖全屏
        return Scaffold(
          backgroundColor: TallyColors.base,
          body: Stack(
            fit: StackFit.expand,
            children: const [
              LivePage(),
              PlayerLayer(),
              SearchPanelHost(),
            ],
          ),
        );
      },
    );
  }
}

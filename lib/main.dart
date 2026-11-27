import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tallylive/core/settings.dart';
import 'package:tallylive/ui/about_page.dart';
import 'package:tallylive/ui/home_page.dart';
import 'package:tallylive/ui/settings_page.dart';
import 'package:tallylive/ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit 必须在 runApp 之前初始化（它会准备 libmpv 的 native 绑定）。
  MediaKit.ensureInitialized();
  // 设置要在首帧之前读完，避免设置页闪一下默认值。
  await AppSettings.instance.load();
  runApp(const TallyApp());
}

class TallyApp extends StatelessWidget {
  const TallyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TallyLive · 在播',
      debugShowCheckedModeBanner: false,
      theme: buildTallyTheme(),
      home: const RootScaffold(),
    );
  }
}

/// 根容器：底部三个 Tab。
///
/// 用 IndexedStack 而不是每次重建，切 Tab 时首页的输入框内容与设置页滚动位置都会保留。
class RootScaffold extends StatefulWidget {
  const RootScaffold({super.key});

  @override
  State<RootScaffold> createState() => _RootScaffoldState();
}

class _RootScaffoldState extends State<RootScaffold> {
  int _index = 0;

  static const List<Widget> _pages = [
    HomePage(),
    SettingsPage(),
    AboutPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        backgroundColor: TallyColors.surface,
        indicatorColor: TallyColors.raised,
        height: 60,
        destinations: const [
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
        ],
      ),
    );
  }
}

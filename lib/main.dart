import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tallylive/core/account.dart';
import 'package:tallylive/core/follows.dart';
import 'package:tallylive/core/settings.dart';
import 'package:tallylive/ui/shell/app_shell.dart';
import 'package:tallylive/ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit 必须在 runApp 之前初始化（它会准备 libmpv 的 native 绑定）。
  MediaKit.ensureInitialized();
  // 桌面端初始化窗口管理：播放页的「真全屏」需要它（覆盖任务栏）。
  // 移动端不初始化（那里用 SystemChrome 的沉浸模式）。
  if (!kIsWeb && isDesktopPlatform) {
    await windowManager.ensureInitialized();
    // 用自绘窗口按钮，所以隐藏系统标题栏（对齐 DTV 的 frameless 窗口）。
    // 拖动区域由 Navbar 自己提供（见 window_controls / app_shell）。
    const windowOptions = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(960, 600),
      center: true,
      title: 'TallyLive',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
  // 设置与关注列表要在首帧之前读完，避免界面闪一下默认值。
  await AppSettings.instance.load();
  await FollowStore.instance.load();
  // 登录态也要在首帧前读回来，否则重启后顶栏会显示未登录
  await AccountStore.instance.load();
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
      // 壳层：桌面 = 关注栏 + 顶栏 + 内容(播放层叠在上面)；手机 = 底部 Tab + 全屏播放层。
      home: const AppShell(),
    );
  }
}

/// 是否为「有窗口的桌面平台」（决定是否启用 window_manager）。
bool get isDesktopPlatform =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.linux;
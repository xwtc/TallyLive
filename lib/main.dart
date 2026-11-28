import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tallylive/core/follows.dart';
import 'package:tallylive/core/settings.dart';
import 'package:tallylive/ui/shell/app_shell.dart';
import 'package:tallylive/ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit 必须在 runApp 之前初始化（它会准备 libmpv 的 native 绑定）。
  MediaKit.ensureInitialized();
  // 设置与关注列表要在首帧之前读完，避免界面闪一下默认值。
  await AppSettings.instance.load();
  await FollowStore.instance.load();
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

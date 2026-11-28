import 'package:flutter_test/flutter_test.dart';
import 'package:tallylive/main.dart';

/// 冒烟测试：应用能构建出首屏，且关键区块存在。
///
/// 注意：首页数据来自 MockLiveRepository（有 260ms 模拟延迟），
/// 所以 pump 时要推进时间等请求完成，否则测试结束会有 pending timer。
void main() {
  testWidgets('直播页渲染出标题、tally 行与精选区块', (tester) async {
    await tester.pumpWidget(const TallyApp());

    // 首帧：标题 + ON AIR 计数行
    expect(find.text('TallyLive · 在播'), findsOneWidget);
    expect(find.text('正在直播'), findsOneWidget);

    // 推进 Mock 的网络延迟，让第一页数据落地
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // 数据到达后应出现「关注中在播」与「平台精选」两个区块
    expect(find.text('关注中在播'), findsOneWidget);
    expect(find.text('平台精选'), findsOneWidget);
  });

  testWidgets('底部导航有直播/设置/关于三个入口', (tester) async {
    await tester.pumpWidget(const TallyApp());
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('直播'), findsWidgets);
    expect(find.text('设置'), findsWidgets);
    expect(find.text('关于'), findsWidgets);
  });
}

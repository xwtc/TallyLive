import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallylive/ui/live_page.dart';
import 'package:tallylive/ui/theme.dart';

import 'fakes.dart';

/// 直播首页的冒烟与状态测试。
///
/// 注入 [FakeLiveRepository]，不联网、无延迟，所以不需要推进时间。
void main() {
  Widget harness(Widget child) => MaterialApp(
        theme: buildTallyTheme(),
        home: Scaffold(body: child),
      );

  testWidgets('有数据时渲染 tally 行、分区 chip 与卡片', (tester) async {
    await tester.pumpWidget(harness(
      LivePage(
        repository: FakeLiveRepository(streamers: fakeStreamers(count: 6)),
      ),
    ));
    await tester.pumpAndSettle();

    // 「正在直播」「平台精选」两行标题已按要求去掉，
    // 标题本身在壳层导航栏（AppShell），本页面只负责分区栏与内容
    // 分区栏：一级分组 + 二级分区
    expect(find.text('网游'), findsWidgets);
    expect(find.text('英雄联盟'), findsWidgets);
    // 主播卡片
    expect(find.text('主播0'), findsOneWidget);
  });

  testWidgets('列表为空时显示空态', (tester) async {
    await tester.pumpWidget(harness(
      LivePage(repository: FakeLiveRepository(streamers: const [])),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('没有在播的房间'), findsOneWidget);
  });

  testWidgets('列表接口失败时显示错误态与重试', (tester) async {
    await tester.pumpWidget(harness(
      LivePage(repository: FakeLiveRepository(failList: true)),
    ));
    await tester.pumpAndSettle();

    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('分区接口失败时显示错误态', (tester) async {
    await tester.pumpWidget(harness(
      LivePage(repository: FakeLiveRepository(failCategories: true)),
    ));
    await tester.pumpAndSettle();

    expect(find.text('重试'), findsOneWidget);
    expect(find.text('分区接口失败'), findsNothing); // 已转成友好文案
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallylive/ui/theme.dart';

/// 主题 token 与夜间配色断言。
///
/// 对应 `lib/ui/theme.dart` 里的 TallyColors / TallySize / TallyType：
/// 这些值是 DTV 对齐的基准，改错会让全局样式走形，所以用测试锁住。
void main() {
  testWidgets('夜间主题可以被构建，基础色与背景正确', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTallyTheme(),
        home: const Scaffold(
          body: Center(child: Text('TallyLive')),
        ),
      ),
    );

    expect(find.text('TallyLive'), findsOneWidget);

    final theme = buildTallyTheme();
    expect(theme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, TallyColors.base);
    expect(theme.colorScheme.primary, TallyColors.signalBlue);
    // LIVE 红不得被用作主色
    expect(theme.colorScheme.primary, isNot(TallyColors.tallyRed));
  });

  test('字号阶梯与间距阶取自统一 token（对齐 DTV 的 11/12/13/15/18）', () {
    expect(TallyType.pageTitle.fontSize, 18);
    expect(TallyType.nickname.fontSize, 15);
    expect(TallyType.meta.fontSize, 12);
    expect(TallyType.tiny.fontSize, 11);
    expect(TallySpace.sm, 8);
    expect(TallySpace.xl, 24);
    // DTV 的卡片圆角是 12、胶囊 999
    expect(TallyRadius.card, 12);
    expect(TallyRadius.pill, 999);
    expect(TallySize.navbar, 64);
    expect(TallySize.sidebar, 240);
  });
}

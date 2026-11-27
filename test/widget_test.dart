import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallylive/main.dart';

/// 冒烟测试：确保应用能构建出首屏，且验证入口的关键控件存在。
///
/// 注意：这个文件会被 `flutter create .` 保留（已存在则不覆盖），
/// 用来替代它默认生成的那个引用 `MyApp` 的无效测试。
void main() {
  testWidgets('首页渲染出房间号输入框与打开按钮', (tester) async {
    await tester.pumpWidget(const TallyApp());

    expect(find.text('TallyLive · 在播'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('打开直播间'), findsOneWidget);
  });
}

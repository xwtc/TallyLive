import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallylive/ui/theme.dart';

/// ⚠️ 这个文件名**必须保留**。
///
/// CI 里 `flutter create .` 会为缺失的 `test/widget_test.dart` 生成一份
/// 引用 `MyApp` 的模板测试，那份模板编译不过（本项目没有 MyApp）。
/// 所以这里放一个最小冒烟测试占位，真正的主题断言在 `theme_test.dart`。
void main() {
  testWidgets('App 能构建且使用夜间主题', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTallyTheme(),
        home: const Scaffold(body: Text('TallyLive')),
      ),
    );
    expect(find.text('TallyLive'), findsOneWidget);
    expect(buildTallyTheme().brightness, Brightness.dark);
  });
}
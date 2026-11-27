import 'package:flutter/material.dart';

/// 夜间导播台配色。
///
/// 与 MOBILE-DESIGN.md 的 token 一一对应：中性石墨灰打底，只有两个功能性颜色
/// —— tally 红仅表示 ON AIR，signal 蓝仅表示可交互/选中。禁止渐变、发光、
/// 高饱和装饰色。
class TallyColors {
  const TallyColors._();

  static const Color base = Color(0xFF0E1012);
  static const Color surface = Color(0xFF16191C);
  static const Color raised = Color(0xFF1F2327);
  static const Color hairline = Color(0xFF2C3137);
  static const Color textPrimary = Color(0xFFDCDDDD);
  static const Color textSecondary = Color(0xFF8A9098);
  static const Color textTertiary = Color(0xFF5B6169);
  static const Color tallyRed = Color(0xFFD93F46);
  static const Color signalBlue = Color(0xFF4A7FB5);
}

/// 全局夜间主题。
ThemeData buildTallyTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: TallyColors.base,
    colorScheme: const ColorScheme.dark(
      surface: TallyColors.base,
      primary: TallyColors.signalBlue,
      onPrimary: Colors.white,
      secondary: TallyColors.tallyRed,
      error: TallyColors.tallyRed,
      onSurface: TallyColors.textPrimary,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: TallyColors.surface,
      foregroundColor: TallyColors.textPrimary,
      elevation: 0,
    ),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(color: TallyColors.textPrimary),
      bodySmall: TextStyle(color: TallyColors.textSecondary),
    ),
  );
}

import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

/// 夜间导播台配色。
///
/// 严格约束（见 UI-DESIGN §5.3）：
/// - `tallyRed` **只用于**「正在直播」（LIVE 圆点/徽章/录制态），
///   不得用于按钮、选中、强调文字；
/// - `signalBlue` 只用于可交互/选中/链接/聚焦；
/// - `stateAmber` 只用于重连/弱网等功能性提示；
/// - 其余全部是中性灰阶。
class TallyColors {
  const TallyColors._();

  static const Color base = Color(0xFF0E1012);
  static const Color surface = Color(0xFF16191C);
  static const Color raised = Color(0xFF1F2327);
  static const Color hairline = Color(0xFF2C3137);

  static const Color textPrimary = Color(0xFFDCDDDD);
  static const Color textSecondary = Color(0xFF8A9098);
  static const Color textTertiary = Color(0xFF5B6169);

  /// ON AIR 唯一用色。
  static const Color tallyRed = Color(0xFFD93F46);

  /// 可交互 / 选中 / 链接。
  static const Color signalBlue = Color(0xFF4A7FB5);

  /// 弱网 / 重连等功能性状态（不装饰）。
  static const Color stateAmber = Color(0xFFC69233);
}

/// 间距阶（UI-DESIGN §5.1）。只用这几档，不要临时拍数字。
class TallySpace {
  const TallySpace._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// 圆角。
class TallyRadius {
  const TallyRadius._();

  static const double card = 6;
  static const double badge = 4;
  static const double input = 6;
  static const Radius cardRadius = Radius.circular(card);
}

/// 布局断点（UI-DESIGN §3.3）。
class TallyBreakpoints {
  const TallyBreakpoints._();

  /// < 600：手机。单列 + 底部 Tab + 平台收成下拉。
  static const double compact = 600;

  /// >= 1024：桌面。关注 rail + 顶部平台分段。
  static const double expanded = 1024;
}

/// 字号阶梯（UI-DESIGN §5.2）。
///
/// 数字统一用 tabular figures，保证人气/时长纵向对齐。
class TallyType {
  const TallyType._();

  /// 页面标题 20/w600
  static const TextStyle pageTitle = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    color: TallyColors.textPrimary,
  );

  /// 区块标题 13/w600/字距 0.6
  static const TextStyle sectionTitle = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.6,
    color: TallyColors.textSecondary,
  );

  /// 昵称（主信息）15/w500
  static const TextStyle nickname = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w500,
    color: TallyColors.textPrimary,
  );

  /// 标题/副信息 13/w400
  static const TextStyle subtitle = TextStyle(
    fontSize: 13,
    color: TallyColors.textSecondary,
  );

  /// 元信息（分区/时间）11/w400
  static const TextStyle meta = TextStyle(
    fontSize: 11,
    color: TallyColors.textTertiary,
  );

  /// 数字（人气）14/w500 tabular
  static const TextStyle number = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: TallyColors.textPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// 小号数字（徽章里）11/w500 tabular
  static const TextStyle numberSmall = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: TallyColors.textPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// LIVE 徽章文字 10/w600/字距 0.8
  static const TextStyle liveBadge = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.8,
    color: TallyColors.tallyRed,
  );
}

/// 常用装饰。
class TallyDecor {
  const TallyDecor._();

  /// 卡片：surface 底 + hairline 边 + 6px 圆角（不用阴影）。
  static BoxDecoration card({Color? color}) => BoxDecoration(
        color: color ?? TallyColors.surface,
        borderRadius: BorderRadius.circular(TallyRadius.card),
        border: Border.all(color: TallyColors.hairline),
      );

  /// 选中态：raised 底 + 1px 蓝描边 + 主色文字。
  ///
  /// 刻意不用高饱和填充（荧光绿/亮蓝块），见 UI-DESIGN §5.3。
  static BoxDecoration selected = BoxDecoration(
    color: TallyColors.raised,
    borderRadius: BorderRadius.circular(TallyRadius.card),
    border: Border.all(color: TallyColors.signalBlue),
  );

  /// 未选中态（可点击的 chip/段）。
  static BoxDecoration idle = BoxDecoration(
    color: Colors.transparent,
    borderRadius: BorderRadius.circular(TallyRadius.card),
    border: Border.all(color: Colors.transparent),
  );

  /// 徽章底（压在封面上的深色半透明）。
  static BoxDecoration badgeOverlay = BoxDecoration(
    color: Colors.black.withValues(alpha: 0.62),
    borderRadius: BorderRadius.circular(TallyRadius.badge),
  );

  /// LIVE 徽章底（红 12%）。
  static BoxDecoration liveBadgePill = BoxDecoration(
    color: TallyColors.tallyRed.withValues(alpha: 0.16),
    borderRadius: BorderRadius.circular(TallyRadius.badge),
  );
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
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: TallyColors.surface,
      indicatorColor: TallyColors.raised,
      height: 60,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? TallyColors.textPrimary : TallyColors.textTertiary,
        );
      }),
    ),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(color: TallyColors.textPrimary),
      bodySmall: TextStyle(color: TallyColors.textSecondary),
    ),
    dividerTheme: const DividerThemeData(
      color: TallyColors.hairline,
      thickness: 1,
      space: 1,
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: TallyColors.signalBlue,
      inactiveTrackColor: TallyColors.hairline,
      thumbColor: TallyColors.signalBlue,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: TallyColors.raised,
      contentTextStyle: TextStyle(color: TallyColors.textPrimary, fontSize: 13),
    ),
  );
}

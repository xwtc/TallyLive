import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

/// 夜间导播台配色。
///
/// **色板是我们自己的**（不照抄 DTV 的荧光绿），但中性灰阶与 DTV 的
/// 明度关系对齐——卡片比地面亮一档、文字比背景亮两档，
/// 这样整页看起来"有层次"而不是一团灰。
///
/// 用法纪律：
/// - [tallyRed] **只表示"正在直播"**（LIVE 点/徽章/录制态）；
/// - [signalBlue] 只表示可交互/选中/链接；
/// - [stateAmber] 只表示风控/降级/弱网这类功能性状态；
/// - 其余全部是中性灰阶。
class TallyColors {
  const TallyColors._();

  static const Color base = Color(0xFF0A0B0D);
  static const Color surface = Color(0xFF14161B);
  static const Color raised = Color(0xFF1C1F25);

  /// 分隔线（比 raised 再亮一点，1px 才看得见）。
  static const Color hairline = Color(0xFF262A31);

  /// 输入框/分段控件的底（比 surface 略暗，形成"凹槽"感）。
  static const Color inset = Color(0xFF16181D);

  static const Color textPrimary = Color(0xFFF4F4EF);
  static const Color textSecondary = Color(0xFFA7AAB2);
  static const Color textTertiary = Color(0xFF8B909A);

  /// ON AIR 唯一用色。
  static const Color tallyRed = Color(0xFFD93F46);

  /// 可交互 / 选中 / 链接。
  static const Color signalBlue = Color(0xFF4A7FB5);

  /// 风控 / 降级 / 弱网（不装饰）。
  static const Color stateAmber = Color(0xFFC69233);

  /// 强调色浅底（分类胶囊、选中 pill 的底）。
  static const Color accentSoft = Color(0x294A7FB5);

  /// 强调色上的文字/图标（浅蓝，保证在 accentSoft 上可读）。
  static const Color accentInk = Color(0xFF9CC0E4);

  /// 封面上的徽章底（对齐 DTV：rgba(8,9,11,.78)）。
  static const Color badgeScrim = Color(0xC708090B);

  /// 卡片顶部受光边（1px 内阴影的替代：细高光让卡片不"塑料"）。
  static const Color cardHighlight = Color(0x0AFFFFFF);
}

/// 间距阶。只用这几档，不要临时拍数字。
class TallySpace {
  const TallySpace._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// 页面左右内边距（对齐 DTV 的 14px）。
  static const double page = 14;
}

/// 圆角（对齐 DTV：卡片 12、胶囊 999）。
class TallyRadius {
  const TallyRadius._();

  static const double card = 12;
  static const double badge = 6;
  static const double input = 999;
  static const double pill = 999;
  static const Radius cardRadius = Radius.circular(card);
}

/// 固定尺寸（对齐 DTV 的 --navbar-height / --sidebar-width）。
class TallySize {
  const TallySize._();

  static const double navbar = 64;
  static const double sidebar = 240;
  static const double sidebarCollapsed = 78;

  /// 主播卡片最小宽度（网格 auto-fill 的下限）。
  static const double cardMin = 220;
  static const double cardMinCollapsed = 196;
  static const double gridGap = 16;

  /// 卡片信息区内边距（对齐 DTV 的 13/12/15）。
  static const EdgeInsets cardMetaPadding = EdgeInsets.fromLTRB(12, 13, 12, 15);
}

/// 动效时长（对齐 DTV 的 dur-1..dur-3）。
class TallyDuration {
  const TallyDuration._();

  static const Duration fast = Duration(milliseconds: 110);
  static const Duration base = Duration(milliseconds: 190);
  static const Duration slow = Duration(milliseconds: 280);
}

/// 布局断点。
class TallyBreakpoints {
  const TallyBreakpoints._();

  /// < 600：手机。单列 + 底部 Tab。
  static const double compact = 600;

  /// >= 1024：桌面。关注栏 + 顶栏 + 网格。
  static const double expanded = 1024;
}

/// 字号阶梯（对齐 DTV：11/12/13/15/18）。
class TallyType {
  const TallyType._();

  /// 页面标题 18/w600
  static const TextStyle pageTitle = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    color: TallyColors.textPrimary,
  );

  /// 区块标题 13/w600
  static const TextStyle sectionTitle = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: TallyColors.textSecondary,
  );

  /// 卡片/列表主信息 15/w500
  static const TextStyle nickname = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w500,
    color: TallyColors.textPrimary,
  );

  /// 副信息 13/w400
  static const TextStyle subtitle = TextStyle(
    fontSize: 13,
    color: TallyColors.textSecondary,
  );

  /// 元信息 12/w400
  static const TextStyle meta = TextStyle(
    fontSize: 12,
    color: TallyColors.textTertiary,
  );

  /// 小字 11/w400
  static const TextStyle tiny = TextStyle(
    fontSize: 11,
    color: TallyColors.textTertiary,
  );

  /// 数字（人气）13/w500 tabular
  static const TextStyle number = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    color: TallyColors.textPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// 小号数字（徽章）11/w500 tabular
  static const TextStyle numberSmall = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: TallyColors.textPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// LIVE 徽章文字 11/w700/字距 0.6
  static const TextStyle liveBadge = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.6,
    color: TallyColors.tallyRed,
  );
}

/// 常用装饰。
class TallyDecor {
  const TallyDecor._();

  /// 卡片：surface 底 + 12px 圆角 + 顶部细高光（不用描边、不用阴影）。
  static BoxDecoration card({Color? color}) => BoxDecoration(
        color: color ?? TallyColors.surface,
        borderRadius: BorderRadius.circular(TallyRadius.card),
        border: Border(
          top: BorderSide(color: TallyColors.cardHighlight),
        ),
      );

  /// 卡片外层（封面贴边用）：只裁切、不画边框。
  static BoxDecoration cardPlain = BoxDecoration(
    color: TallyColors.surface,
    borderRadius: BorderRadius.circular(TallyRadius.card),
  );

  /// 选中态：raised 底 + 1px 蓝描边。
  static BoxDecoration selected = BoxDecoration(
    color: TallyColors.raised,
    borderRadius: BorderRadius.circular(TallyRadius.pill),
    border: Border.all(color: TallyColors.signalBlue),
  );

  /// 未选中（可点但无边框）。
  static BoxDecoration idle = BoxDecoration(
    color: Colors.transparent,
    borderRadius: BorderRadius.circular(TallyRadius.pill),
    border: Border.all(color: Colors.transparent),
  );

  /// 凹槽底（分段控件、搜索框外层）。
  static BoxDecoration inset = BoxDecoration(
    color: TallyColors.inset,
    borderRadius: BorderRadius.circular(TallyRadius.pill),
  );

  /// 徽章底（压在封面上的深色半透明）。
  static BoxDecoration badgeOverlay = BoxDecoration(
    color: Colors.black.withValues(alpha: 0.62),
    borderRadius: BorderRadius.circular(TallyRadius.pill),
  );

  /// LIVE 徽章底（红 16%）。
  static BoxDecoration liveBadgePill = BoxDecoration(
    color: TallyColors.tallyRed.withValues(alpha: 0.18),
    borderRadius: BorderRadius.circular(TallyRadius.pill),
  );
}

/// 全局夜间主题。
/// UI 主字体：按平台选一个**中文覆盖完整**的字族。
///
/// 为什么必须指定：不指定时 Flutter 用系统默认字体渲染拉丁字符，
/// 遇到缺字形再**逐字回退**到别的中文字体，于是同一个词里
/// 「关」和「注」可能来自两套字体，字重与字形不一致（用户看到"字怪怪的"）。
/// 指定一个全 CJK 覆盖的字族后，所有中文都来自同一套字形。
String _uiFontFamily() {
  switch (defaultTargetPlatform) {
    case TargetPlatform.macOS:
    case TargetPlatform.iOS:
      return 'PingFang SC';
    case TargetPlatform.android:
    case TargetPlatform.linux:
      return 'Noto Sans CJK SC';
    case TargetPlatform.windows:
      return 'Microsoft YaHei UI';
    default:
      return 'Microsoft YaHei UI';
  }
}

/// 字体回退链：主字族缺失时按顺序找，尽量都是 CJK 全覆盖的字族。
const List<String> _uiFontFallback = [
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'PingFang SC',
  'Noto Sans CJK SC',
  'Source Han Sans SC',
  'Heiti SC',
  'Segoe UI',
];

ThemeData buildTallyTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: _uiFontFamily(),
    fontFamilyFallback: _uiFontFallback,
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
      backgroundColor: TallyColors.base,
      foregroundColor: TallyColors.textPrimary,
      elevation: 0,
      centerTitle: false,
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

// TraeTheme —— Strata Mobile 统一设计 token（M2-1 双主题版）
//
// 单一真源：引擎 web 端的设计 token（Gainsty 设计系统衍生，取自
// github.com/Niko1221/Strata）。浅色为默认，深色由 ThemeMode 驱动。
//
// 架构（M2-1 起）：
// - TraePalette：**随主题切换**的色彩集合（ThemeExtension 挂到 Theme 上，
//   页面用 `context.trae.bg` 等访问，禁止裸色值）
// - TraeTokens：**不随主题变**的结构 token（半径/间距/字号/动效曲线）；
//   M2-1 起不再持有色彩常量（迁移到 palette，防深色残留浅色值）
// - TraeTheme.light / TraeTheme.dark：两套 ThemeData 装配（共用 _build）
// - TraeText / TraeWidgets：全部改为从 context.trae 取色
//
// 对齐范围（tokens.css 逐行核对，勿凭记忆改色值）：
// - 色彩：bg/surface/surface-2/line/line-soft/ink/ink-soft/ink-muted/icon
//         accent 四件套 + info/warn/danger 三组语义色 + focus + code 恒暗
// - 字体：Outfit（拉丁/数字，assets/fonts/*.ttf）+ 系统字体（中文回退）
// - 阴影三档：sh-card / sh-bar / sh-pop（浅色多层叠加，深色简化）
// - 动效：cubic-bezier(.2,.7,.2,1) 160ms

import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────
// TraePalette：随主题切换的色彩（ThemeExtension）
// ─────────────────────────────────────────────────────────────

/// 随主题切换的调色板，字段与 tokens.css 变量一一对应。
///
/// 取色规范：页面代码一律 `context.trae.<field>`；`success` 为 App 派生色
/// （webUI 无此变量，存活点等场景使用），light #16a34a / dark 用 accent。
@immutable
class TraePalette extends ThemeExtension<TraePalette> {
  const TraePalette({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.line,
    required this.lineSoft,
    required this.ink,
    required this.inkSoft,
    required this.muted,
    required this.icon,
    required this.accent,
    required this.accentHover,
    required this.accentInk,
    required this.accentTint,
    required this.accentText,
    required this.focus,
    required this.info,
    required this.infoTint,
    required this.infoText,
    required this.warn,
    required this.warnTint,
    required this.warnText,
    required this.danger,
    required this.dangerTint,
    required this.dangerText,
    required this.codeBg,
    required this.codeInk,
    required this.success,
    required this.shCard,
    required this.shBar,
    required this.shPop,
  });

  // 中性层
  final Color bg; // --st-bg
  final Color surface; // --st-surface
  final Color surface2; // --st-surface-2
  final Color line; // --st-line
  final Color lineSoft; // --st-line-soft
  final Color ink; // --st-ink（主文字）
  final Color inkSoft; // --st-ink-soft（正文/次级）
  final Color muted; // --st-ink-muted（元信息）
  final Color icon; // --st-icon

  // 强调色四件套
  final Color accent; // --st-accent
  final Color accentHover; // --st-accent-hover
  final Color accentInk; // --st-accent-ink（accent 底上的字）
  final Color accentTint; // --st-accent-tint
  final Color accentText; // --st-accent-text（accent 作文字色）

  final Color focus; // --st-focus

  // 语义色三组
  final Color info;
  final Color infoTint;
  final Color infoText;
  final Color warn;
  final Color warnTint;
  final Color warnText;
  final Color danger;
  final Color dangerTint;
  final Color dangerText;

  // 代码块恒暗（双主题同暗，dark 主题下更暗一档）
  final Color codeBg;
  final Color codeInk;

  // App 派生（webUI 无）
  final Color success;

  // 阴影三档
  final List<BoxShadow> shCard;
  final List<BoxShadow> shBar;
  final List<BoxShadow> shPop;

  /// 浅色调色板（tokens.css :root）。
  static const TraePalette light = TraePalette(
    bg: Color(0xFFF9FAFB),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF7F7F7),
    line: Color(0xFFDEE5EE),
    lineSoft: Color(0xFFEEEEEE),
    ink: Color(0xFF221E1F),
    inkSoft: Color(0xFF303030),
    muted: Color(0xFF6F6F6F),
    icon: Color(0xFF2F384C),
    accent: Color(0xFF10B981),
    accentHover: Color(0xFF0C8A60),
    accentInk: Color(0xFFFFFFFF),
    accentTint: Color(0xFFECFDF5),
    accentText: Color(0xFF0C8A60),
    focus: Color(0xFF405DE6),
    info: Color(0xFF0F97FF),
    infoTint: Color(0xFFE8F4FF),
    infoText: Color(0xFF0668C2),
    warn: Color(0xFFE39B0B),
    warnTint: Color(0xFFFFF6E0),
    warnText: Color(0xFF8A5A00),
    danger: Color(0xFFE0283F),
    dangerTint: Color(0xFFFDECEE),
    dangerText: Color(0xFFB01A2E),
    codeBg: Color(0xFF1B1F23),
    codeInk: Color(0xFFE6E9EC),
    success: Color(0xFF16A34A),
    shCard: [
      BoxShadow(color: Color(0x03000000), blurRadius: 7, offset: Offset(0, 18)),
      BoxShadow(color: Color(0x05000000), blurRadius: 6, offset: Offset(0, 10)),
      BoxShadow(color: Color(0x08000000), blurRadius: 4, offset: Offset(0, 4)),
      BoxShadow(color: Color(0x0A000000), blurRadius: 2, offset: Offset(0, 1)),
    ],
    shBar: [
      BoxShadow(color: Color(0x03000000), blurRadius: 21, offset: Offset(0, 54)),
      BoxShadow(color: Color(0x08000000), blurRadius: 18, offset: Offset(0, 30)),
      BoxShadow(color: Color(0x0D000000), blurRadius: 13, offset: Offset(0, 13)),
      BoxShadow(color: Color(0x0F000000), blurRadius: 7, offset: Offset(0, 3)),
    ],
    shPop: [
      BoxShadow(color: Color(0x140F172A), blurRadius: 40, offset: Offset(0, 10)),
      BoxShadow(color: Color(0x0F0F172A), blurRadius: 3, offset: Offset(0, 1)),
    ],
  );

  /// 深色调色板（tokens.css [data-theme="dark"]）。
  static const TraePalette dark = TraePalette(
    bg: Color(0xFF0E1113),
    surface: Color(0xFF161A1D),
    surface2: Color(0xFF1D2226),
    line: Color(0xFF2A3036),
    lineSoft: Color(0xFF22272C),
    ink: Color(0xFFEEF1F3),
    inkSoft: Color(0xFFC7CDD3),
    muted: Color(0xFF8E979F),
    icon: Color(0xFFC7CDD3),
    accent: Color(0xFF34D399),
    accentHover: Color(0xFF4ADE80),
    accentInk: Color(0xFF052E20),
    accentTint: Color(0x1F34D399), // rgba(52,211,153,.12)
    accentText: Color(0xFF4ADE80),
    focus: Color(0xFF7B93FF),
    info: Color(0xFF3AA9FF),
    infoTint: Color(0x1F3AA9FF), // rgba(58,169,255,.12)
    infoText: Color(0xFF7CC4FF),
    warn: Color(0xFFF5B53D),
    warnTint: Color(0x1FF5B53D), // rgba(245,181,61,.12)
    warnText: Color(0xFFF8C96A),
    danger: Color(0xFFFF5A6E),
    dangerTint: Color(0x1FFF5A6E), // rgba(255,90,110,.12)
    dangerText: Color(0xFFFF8A98),
    codeBg: Color(0xFF0A0C0E),
    codeInk: Color(0xFFE6E9EC),
    success: Color(0xFF34D399),
    shCard: [
      BoxShadow(color: Color(0x66000000), blurRadius: 2, offset: Offset(0, 1)),
    ],
    shBar: [
      BoxShadow(color: Color(0x73000000), blurRadius: 32, offset: Offset(0, 12)),
      BoxShadow(color: Color(0x59000000), blurRadius: 6, offset: Offset(0, 2)),
    ],
    shPop: [
      BoxShadow(color: Color(0x8C000000), blurRadius: 48, offset: Offset(0, 16)),
      BoxShadow(color: Color(0x66000000), blurRadius: 3, offset: Offset(0, 1)),
    ],
  );

  @override
  TraePalette copyWith({
    Color? bg,
    Color? surface,
    Color? surface2,
    Color? line,
    Color? lineSoft,
    Color? ink,
    Color? inkSoft,
    Color? muted,
    Color? icon,
    Color? accent,
    Color? accentHover,
    Color? accentInk,
    Color? accentTint,
    Color? accentText,
    Color? focus,
    Color? info,
    Color? infoTint,
    Color? infoText,
    Color? warn,
    Color? warnTint,
    Color? warnText,
    Color? danger,
    Color? dangerTint,
    Color? dangerText,
    Color? codeBg,
    Color? codeInk,
    Color? success,
    List<BoxShadow>? shCard,
    List<BoxShadow>? shBar,
    List<BoxShadow>? shPop,
  }) {
    return TraePalette(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2,
      line: line ?? this.line,
      lineSoft: lineSoft ?? this.lineSoft,
      ink: ink ?? this.ink,
      inkSoft: inkSoft ?? this.inkSoft,
      muted: muted ?? this.muted,
      icon: icon ?? this.icon,
      accent: accent ?? this.accent,
      accentHover: accentHover ?? this.accentHover,
      accentInk: accentInk ?? this.accentInk,
      accentTint: accentTint ?? this.accentTint,
      accentText: accentText ?? this.accentText,
      focus: focus ?? this.focus,
      info: info ?? this.info,
      infoTint: infoTint ?? this.infoTint,
      infoText: infoText ?? this.infoText,
      warn: warn ?? this.warn,
      warnTint: warnTint ?? this.warnTint,
      warnText: warnText ?? this.warnText,
      danger: danger ?? this.danger,
      dangerTint: dangerTint ?? this.dangerTint,
      dangerText: dangerText ?? this.dangerText,
      codeBg: codeBg ?? this.codeBg,
      codeInk: codeInk ?? this.codeInk,
      success: success ?? this.success,
      shCard: shCard ?? this.shCard,
      shBar: shBar ?? this.shBar,
      shPop: shPop ?? this.shPop,
    );
  }

  @override
  TraePalette lerp(TraePalette? other, double t) {
    if (other == null) return this;
    // 主题切换为瞬时替换，阴影不做逐层插值（取阈值侧）。
    List<BoxShadow> shadowLerp(List<BoxShadow> a, List<BoxShadow> b) =>
        t < 0.5 ? a : b;
    return TraePalette(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      line: Color.lerp(line, other.line, t)!,
      lineSoft: Color.lerp(lineSoft, other.lineSoft, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      inkSoft: Color.lerp(inkSoft, other.inkSoft, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      icon: Color.lerp(icon, other.icon, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentHover: Color.lerp(accentHover, other.accentHover, t)!,
      accentInk: Color.lerp(accentInk, other.accentInk, t)!,
      accentTint: Color.lerp(accentTint, other.accentTint, t)!,
      accentText: Color.lerp(accentText, other.accentText, t)!,
      focus: Color.lerp(focus, other.focus, t)!,
      info: Color.lerp(info, other.info, t)!,
      infoTint: Color.lerp(infoTint, other.infoTint, t)!,
      infoText: Color.lerp(infoText, other.infoText, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      warnTint: Color.lerp(warnTint, other.warnTint, t)!,
      warnText: Color.lerp(warnText, other.warnText, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      dangerTint: Color.lerp(dangerTint, other.dangerTint, t)!,
      dangerText: Color.lerp(dangerText, other.dangerText, t)!,
      codeBg: Color.lerp(codeBg, other.codeBg, t)!,
      codeInk: Color.lerp(codeInk, other.codeInk, t)!,
      success: Color.lerp(success, other.success, t)!,
      shCard: shadowLerp(shCard, other.shCard),
      shBar: shadowLerp(shBar, other.shBar),
      shPop: shadowLerp(shPop, other.shPop),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// TraeTokens：不随主题变的结构 token
// ─────────────────────────────────────────────────────────────

/// 结构 token（半径/间距/字号/动效）。色彩一律走 `context.trae`。
class TraeTokens {
  TraeTokens._();

  // ── 圆角（web radius sm/md/lg/xl/pill）─────────────────
  static const double radiusSm = 8;
  static const double radiusMd = 14;
  static const double radiusLg = 20;
  static const double radiusXl = 24;
  static const double radiusPill = 999;

  // ── 间距（4pt 栅格）────────────────────────────────────
  static const double gapXs = 4;
  static const double gapSm = 8;
  static const double gapMd = 12;
  static const double gapLg = 16;
  static const double gapXl = 24;

  // ── 字号（--st-fs-*）───────────────────────────────────
  static const double fontXs = 12; // --st-fs-xs
  static const double fontSm = 13; // --st-fs-sm
  static const double fontMd = 14; // --st-fs-md
  static const double fontBase = 16; // --st-fs-base
  static const double fontLg = 18; // --st-fs-lg
  static const double fontXl = 24; // --st-fs-xl
  static const double fontStat = 32; // --st-fs-stat
  static const double fontDisplay = 40; // --st-fs-display

  // 旧字号别名（v0.0.4 迁移兼容，逐步下线）
  static const double fontTitle = 17;
  static const double fontSection = 15;
  static const double fontBody = 15;
  static const double fontChain = 13;
  static const double fontMeta = 12;

  // ── 动效（--st-ease / --st-dur）────────────────────────
  static const Curve easeTrae = Cubic(0.2, 0.7, 0.2, 1);
  static const Duration durTrae = Duration(milliseconds: 160);
}

// ─────────────────────────────────────────────────────────────
// context 扩展：ThemeExtension 取色入口
// ─────────────────────────────────────────────────────────────

extension TraePaletteX on BuildContext {
  /// 当前主题的调色板（挂 Theme.extensions[TraePalette]）。
  TraePalette get trae =>
      Theme.of(this).extension<TraePalette>() ?? TraePalette.light;
}

// ─────────────────────────────────────────────────────────────
// TraeText：页面/组件共用文本样式（随主题取色）
// ─────────────────────────────────────────────────────────────

/// 页面/组件共用的文本样式。
class TraeText {
  TraeText._();

  static TextStyle pageTitle(BuildContext context) => TextStyle(
        fontSize: TraeTokens.fontTitle,
        fontWeight: FontWeight.w600,
        color: context.trae.ink,
        height: 1.3,
      );

  static TextStyle sectionTitle(BuildContext context) => TextStyle(
        fontSize: TraeTokens.fontSection,
        fontWeight: FontWeight.w600,
        color: context.trae.inkSoft,
        height: 1.35,
      );

  static TextStyle body(BuildContext context) => TextStyle(
        fontSize: TraeTokens.fontBody,
        color: context.trae.inkSoft,
        height: 1.5,
      );

  /// 思考链文字（可点击的文字链）
  static TextStyle chain(BuildContext context) => TextStyle(
        fontSize: TraeTokens.fontChain,
        fontWeight: FontWeight.w500,
        color: context.trae.accent,
        height: 1.4,
      );

  /// 元信息（耗时 / token / 时间）
  static TextStyle meta(BuildContext context) => TextStyle(
        fontSize: TraeTokens.fontMeta,
        color: context.trae.muted,
        height: 1.4,
      );
}

// ─────────────────────────────────────────────────────────────
// TraeTheme：Material ThemeData 装配（浅/深共用 _build）
// ─────────────────────────────────────────────────────────────

/// Material Theme 装配。dark 与 light 仅 palette 不同。
class TraeTheme {
  TraeTheme._();

  static ThemeData get light => _build(TraePalette.light, Brightness.light);
  static ThemeData get dark => _build(TraePalette.dark, Brightness.dark);

  static ThemeData _build(TraePalette p, Brightness brightness) {
    final base = ThemeData(useMaterial3: true, brightness: brightness);
    final fontFamily = 'Outfit';

    final scheme = ColorScheme.fromSeed(
      seedColor: p.accent,
      brightness: brightness,
    ).copyWith(
      primary: p.accent,
      onPrimary: p.accentInk,
      surface: p.surface,
      onSurface: p.ink,
      secondary: p.accentText,
      error: p.danger,
      outlineVariant: p.line,
    );

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: p.bg,
      canvasColor: p.bg,
      dividerColor: p.line,
      splashFactory: InkSparkle.splashFactory,
      extensions: [p],
      appBarTheme: AppBarTheme(
        backgroundColor: p.bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: p.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: TraeTokens.fontTitle,
          fontWeight: FontWeight.w600,
          color: p.ink,
        ),
      ),
      textTheme: base.textTheme
          .apply(
            bodyColor: p.ink,
            displayColor: p.ink,
            fontFamily: fontFamily,
          )
          .apply(fontSizeFactor: 1.0),
      dividerTheme: DividerThemeData(
        color: p.line,
        thickness: 1,
        space: 1,
      ),
      cardTheme: CardThemeData(
        color: p.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TraeTokens.radiusMd),
          side: BorderSide(color: p.lineSoft),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: p.inkSoft,
        textColor: p.inkSoft,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surface2,
        hintStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: TraeTokens.fontBody,
          color: p.muted,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TraeTokens.radiusMd),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TraeTokens.radiusMd),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TraeTokens.radiusMd),
          borderSide: BorderSide(color: p.accent, width: 1.5),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TraeTokens.radiusMd),
          borderSide: BorderSide.none,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.accent,
          foregroundColor: p.accentInk,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(TraeTokens.radiusMd),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.inkSoft,
          side: BorderSide(color: p.line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(TraeTokens.radiusMd),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.accent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(TraeTokens.radiusSm),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.ink,
        contentTextStyle: TextStyle(color: p.bg, fontSize: 13),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TraeTokens.radiusMd),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TraeTokens.radiusLg),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: p.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TraeTokens.radiusMd),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// TraeWidgets：复用小组件（随主题取色）
// ─────────────────────────────────────────────────────────────

/// 复用的小组件（TRAE 风格）。
class TraeWidgets {
  TraeWidgets._();

  /// 状态点：绿=已连接 / 灰=未连接 / 红=错误
  static Widget statusDot(Color color, {double size = 8}) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );

  /// 元信息带中的一条：分隔点
  static Widget metaDivider(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text('·',
            style: TextStyle(fontSize: 12, color: context.trae.muted)),
      );

  /// 圆角小标签（选中态用 accentTint 底 + accentText 字）
  ///
  /// [key] 透传给外层 GestureDetector，便于 widget 测试定位具体档位。
  static Widget chip(BuildContext context, String label,
      {Key? key, bool selected = false, VoidCallback? onTap}) {
    final t = context.trae;
    return GestureDetector(
      key: key,
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? t.accentTint : Colors.transparent,
          borderRadius: BorderRadius.circular(TraeTokens.radiusPill),
          border: selected ? null : Border.all(color: t.line),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: selected ? t.accentText : t.muted,
          ),
        ),
      ),
    );
  }
}

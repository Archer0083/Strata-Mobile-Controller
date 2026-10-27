// M2-1 令牌对照单测：TraePalette.light / TraePalette.dark 的每个色彩字段
// 与 strata_ref/serve/web/tokens.css 逐值断言（防凭记忆改色值——对照表
// 摘自 tokens.css :root 与 [data-theme="dark"]，勿凭记忆改）。
//
// 另覆盖：TraeTokens 结构常量、TraeTheme 挂载（extensions 含 palette、
// dark 与 light 的 scaffold 底色不同）、context.trae 回退 light。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strata_mobile_controller/theme/trae_theme.dart';

void main() {
  group('TraePalette.light 与 tokens.css :root 对照', () {
    const p = TraePalette.light;
    test('中性层', () {
      expect(p.bg, const Color(0xFFF9FAFB)); // --st-bg
      expect(p.surface, const Color(0xFFFFFFFF)); // --st-surface
      expect(p.surface2, const Color(0xFFF7F7F7)); // --st-surface-2
      expect(p.line, const Color(0xFFDEE5EE)); // --st-line
      expect(p.lineSoft, const Color(0xFFEEEEEE)); // --st-line-soft
      expect(p.ink, const Color(0xFF221E1F)); // --st-ink
      expect(p.inkSoft, const Color(0xFF303030)); // --st-ink-soft
      expect(p.muted, const Color(0xFF6F6F6F)); // --st-ink-muted
      expect(p.icon, const Color(0xFF2F384C)); // --st-icon
    });
    test('accent 四件套 + focus', () {
      expect(p.accent, const Color(0xFF10B981)); // --st-accent
      expect(p.accentHover, const Color(0xFF0C8A60)); // --st-accent-hover
      expect(p.accentInk, const Color(0xFFFFFFFF)); // --st-accent-ink
      expect(p.accentTint, const Color(0xFFECFDF5)); // --st-accent-tint
      expect(p.accentText, const Color(0xFF0C8A60)); // --st-accent-text
      expect(p.focus, const Color(0xFF405DE6)); // --st-focus
    });
    test('语义色三组 + code + success', () {
      expect(p.info, const Color(0xFF0F97FF));
      expect(p.infoTint, const Color(0xFFE8F4FF));
      expect(p.infoText, const Color(0xFF0668C2));
      expect(p.warn, const Color(0xFFE39B0B));
      expect(p.warnTint, const Color(0xFFFFF6E0));
      expect(p.warnText, const Color(0xFF8A5A00));
      expect(p.danger, const Color(0xFFE0283F));
      expect(p.dangerTint, const Color(0xFFFDECEE));
      expect(p.dangerText, const Color(0xFFB01A2E));
      // code 恒暗：双主题同暗
      expect(p.codeBg, const Color(0xFF1B1F23));
      expect(p.codeInk, const Color(0xFFE6E9EC));
      // success 为 App 派生（webUI 无）：light #16a34a
      expect(p.success, const Color(0xFF16A34A));
    });
    test('阴影三档（浅色多层叠加）', () {
      expect(p.shCard.length, 4);
      expect(p.shBar.length, 4);
      expect(p.shPop.length, 2);
    });
  });

  group('TraePalette.dark 与 tokens.css [data-theme="dark"] 对照', () {
    const p = TraePalette.dark;
    test('中性层', () {
      expect(p.bg, const Color(0xFF0E1113));
      expect(p.surface, const Color(0xFF161A1D));
      expect(p.surface2, const Color(0xFF1D2226));
      expect(p.line, const Color(0xFF2A3036));
      expect(p.lineSoft, const Color(0xFF22272C));
    });
    test('文字与 accent', () {
      expect(p.ink, const Color(0xFFEEF1F3));
      expect(p.inkSoft, const Color(0xFFC7CDD3));
      expect(p.muted, const Color(0xFF8E979F));
      expect(p.icon, const Color(0xFFC7CDD3));
      expect(p.accent, const Color(0xFF34D399));
      expect(p.accentHover, const Color(0xFF4ADE80));
      expect(p.accentInk, const Color(0xFF052E20));
      expect(p.accentTint, const Color(0x1F34D399)); // rgba(52,211,153,.12)
      expect(p.accentText, const Color(0xFF4ADE80));
      expect(p.focus, const Color(0xFF7B93FF));
    });
    test('语义色三组 + code + success', () {
      expect(p.info, const Color(0xFF3AA9FF));
      expect(p.infoTint, const Color(0x1F3AA9FF));
      expect(p.infoText, const Color(0xFF7CC4FF));
      expect(p.warn, const Color(0xFFF5B53D));
      expect(p.warnTint, const Color(0x1FF5B53D));
      expect(p.warnText, const Color(0xFFF8C96A));
      expect(p.danger, const Color(0xFFFF5A6E));
      expect(p.dangerTint, const Color(0x1FFF5A6E));
      expect(p.dangerText, const Color(0xFFFF8A98));
      expect(p.codeBg, const Color(0xFF0A0C0E)); // 恒暗，dark 更暗一档
      expect(p.codeInk, const Color(0xFFE6E9EC));
      expect(p.success, const Color(0xFF34D399)); // dark 用 accent
    });
    test('阴影三档（深色简化）', () {
      expect(p.shCard.length, 1);
      expect(p.shBar.length, 2);
      expect(p.shPop.length,  2);
    });
  });

  group('TraeTokens 结构常量', () {
    test('半径/间距/字号/动效', () {
      expect(TraeTokens.radiusSm, 8);
      expect(TraeTokens.radiusMd, 14);
      expect(TraeTokens.radiusLg, 20);
      expect(TraeTokens.radiusXl, 24);
      expect(TraeTokens.gapXs, 4);
      expect(TraeTokens.gapSm, 8);
      expect(TraeTokens.gapMd, 12);
      expect(TraeTokens.gapLg, 16);
      expect(TraeTokens.gapXl, 24);
    });
    test('动效曲线与时长', () {
      expect(TraeTokens.durTrae, const Duration(milliseconds: 160));
    });
  });

  group('TraeTheme 装配', () {
    test('light/dark 均挂载 palette extension', () {
      expect(TraeTheme.light.extension<TraePalette>(), TraePalette.light);
      expect(TraeTheme.dark.extension<TraePalette>(), TraePalette.dark);
    });
    test('dark 与 light 的 scaffold 底色不同', () {
      expect(TraeTheme.dark.scaffoldBackgroundColor,
          isNot(TraeTheme.light.scaffoldBackgroundColor));
    });
    testWidgets('context.trae 在无 extension 时回退 light', (tester) async {
      late TraePalette resolved;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(),
        home: Builder(builder: (context) {
          resolved = context.trae;
          return const SizedBox.shrink();
        }),
      ));
      expect(resolved, TraePalette.light);
    });
  });
}

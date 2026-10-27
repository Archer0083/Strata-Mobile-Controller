// markdown_view.dart —— M2-5：AI 回复 markdown 渲染器
//
// 手写解析（不引第三方包），逐条对齐引擎 web 端的渲染行为
// 的 markdown() / blocks() / inline()（L505-569），保证 App 与 WebUI 同一
// 模型输出渲染一致。分两层：
//   解析层：纯函数 parseMarkdown / parseInline（可单测，M2-5 测试锚点）
//   渲染层：MarkdownView（块级布局）+ MdInlineText（行内 span，含链接手势）
//
// 视觉口径（app.css L28-44 / components.css L79-82）：
// - 代码块恒暗（palette.codeBg/codeInk，双主题同暗），头 lang 标签 +
//   copy 按钮（点击 1500ms check 复原，对齐 web data-code-copy）
// - 行内代码 mono + surface2 底；标题 ≤2 个 # → h3 级（lg/w700）、
//   3-6 个 # → h4 级（base/w700）；引用左 3px line 竖线 + muted 字
// - 表格 1px line 边框 + 6/10 padding，th 加粗；hr 1px line
// - 未闭合 fence 把剩余全部当代码块（流式中途渲染，对齐 web L564）

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/trae_theme.dart';

// ─────────────────────────────────────────────────────────────
// 解析层：块级模型
// ─────────────────────────────────────────────────────────────

sealed class MdBlock {
  const MdBlock();
}

/// 段落（多行，行间相当于 <br>）
class MdParagraph extends MdBlock {
  const MdParagraph(this.lines);
  final List<String> lines;
}

/// 标题：level3=true 对应 web h3（≤2 个 #），false 对应 h4（3-6 个 #）
class MdHeading extends MdBlock {
  const MdHeading(this.text, {required this.level3});
  final String text;
  final bool level3;
}

/// 水平分割线
class MdThematicBreak extends MdBlock {
  const MdThematicBreak();
}

/// 引用（单行，web 不合并相邻 blockquote）
class MdBlockquote extends MdBlock {
  const MdBlockquote(this.text);
  final String text;
}

/// 表格（header 一行 + 若干数据行，单元格已 trim）
class MdTable extends MdBlock {
  const MdTable(this.header, this.rows);
  final List<String> header;
  final List<List<String>> rows;
}

/// 列表（ul/ol 不嵌套，tag 变化时 web 会拆成两块）
class MdListBlock extends MdBlock {
  const MdListBlock({required this.ordered, required this.items});
  final bool ordered;
  final List<String> items;
}

/// 代码块（lang 为 fence 行 trim 后的值，空串表示无语言）
class MdCodeBlock extends MdBlock {
  const MdCodeBlock(this.lang, this.code);
  final String lang;
  final String code;
}

// ─────────────────────────────────────────────────────────────
// 解析层：行内模型
// ─────────────────────────────────────────────────────────────

sealed class MdInline {
  const MdInline();
}

class MdPlain extends MdInline {
  const MdPlain(this.text);
  final String text;
}

/// 行内代码（内部不再解析任何样式，对齐 web 占位符回填）
class MdCodeSpan extends MdInline {
  const MdCodeSpan(this.code);
  final String code;
}

class MdBold extends MdInline {
  const MdBold(this.children);
  final List<MdInline> children;
}

class MdItalic extends MdInline {
  const MdItalic(this.children);
  final List<MdInline> children;
}

/// 链接（仅 http/https，web 正则同）
class MdLink extends MdInline {
  const MdLink(this.children, this.url);
  final List<MdInline> children;
  final String url;
}

// ─────────────────────────────────────────────────────────────
// 解析层：正则（与 app.js 逐条对应）
// ─────────────────────────────────────────────────────────────

final RegExp _fenceOpen = RegExp(r'(^|\n)```([^\n`]*)\n');
final RegExp _fenceClose = RegExp(r'(^|\n)```[ \t]*(\n|$)');
final RegExp _headingRe = RegExp(r'^(#{1,6})\s+(.*)$');
// web [\s\1] 中的 \1 在字符类里是八进制 \x01（非反向引用）→ 尾部只允许空白
final RegExp _hrRe = RegExp(r'^\s*([-*_])(?:\s*\1){2}\s*$');
final RegExp _quoteRe = RegExp(r'^>\s?(.*)$');
final RegExp _tableRowRe = RegExp(r'^\s*\|.*\|\s*$');
final RegExp _tableSepRe = RegExp(r'^\s*\|?[\s:-]+\|[\s|:-]*$');
final RegExp _listItemRe = RegExp(r'^\s*(?:[-*+]|(\d+)[.)])\s+(.*)$');
final RegExp _listContRe = RegExp(r'^\s{2,}\S');
final RegExp _codeSpanRe = RegExp(r'`([^`\n]+)`');
final RegExp _boldRe = RegExp(r'\*\*([^*\n]+)\*\*');
final RegExp _emRe = RegExp(r'(^|[^*\w])\*([^*\n]+)\*(?![*\w])');
final RegExp _linkRe = RegExp(r'\[([^\]\n]+)\]\((https?://[^)\s]+)\)');

/// markdown 主入口：fence 切分 + 块级解析（对齐 app.js markdown()）。
List<MdBlock> parseMarkdown(String text) {
  final out = <MdBlock>[];
  var rest = text;
  while (true) {
    final m = _fenceOpen.firstMatch(rest);
    if (m == null) {
      out.addAll(parseBlocks(rest));
      break;
    }
    out.addAll(parseBlocks(rest.substring(0, m.start)));
    rest = rest.substring(m.end);
    final end = _fenceClose.firstMatch(rest);
    if (end == null) {
      // 流式中途：未闭合的 fence 剩余全部当代码块（web L564）
      out.add(MdCodeBlock(m.group(2)!.trim(), rest));
      break;
    }
    out.add(MdCodeBlock(m.group(2)!.trim(), rest.substring(0, end.start)));
    rest = rest.substring(end.end);
  }
  return out;
}

/// 块级解析（对齐 app.js blocks()）。
List<MdBlock> parseBlocks(String text) {
  final out = <MdBlock>[];
  final lines = text.split('\n');
  var para = <String>[];
  bool? listOrdered; // null = 当前无列表
  var items = <String>[];

  void flushPara() {
    if (para.isNotEmpty) {
      out.add(MdParagraph(List.of(para)));
      para = [];
    }
  }

  void flushList() {
    if (listOrdered != null) {
      out.add(MdListBlock(ordered: listOrdered!, items: List.of(items)));
      listOrdered = null;
      items = [];
    }
  }

  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (l.trim().isEmpty) {
      flushPara();
      flushList();
      continue;
    }
    final h = _headingRe.firstMatch(l);
    if (h != null) {
      flushPara();
      flushList();
      out.add(MdHeading(h.group(2)!, level3: h.group(1)!.length <= 2));
      continue;
    }
    if (_hrRe.hasMatch(l)) {
      flushPara();
      flushList();
      out.add(const MdThematicBreak());
      continue;
    }
    final q = _quoteRe.firstMatch(l);
    if (q != null) {
      flushPara();
      flushList();
      out.add(MdBlockquote(q.group(1)!));
      continue;
    }
    // 表格：当前行是 |..| 且下一行是分隔符行
    if (_tableRowRe.hasMatch(l) &&
        i + 1 < lines.length &&
        _tableSepRe.hasMatch(lines[i + 1])) {
      flushPara();
      flushList();
      final header = _tableCells(l);
      final rows = <List<String>>[];
      i += 2; // 跳过表头与分隔符行
      while (i < lines.length && _tableRowRe.hasMatch(lines[i])) {
        rows.add(_tableCells(lines[i]));
        i++;
      }
      i--; // 抵消 for 自增
      out.add(MdTable(header, rows));
      continue;
    }
    final li = _listItemRe.firstMatch(l);
    if (li != null) {
      flushPara();
      final ordered = li.group(1) != null;
      if (listOrdered == null || listOrdered != ordered) {
        flushList();
        listOrdered = ordered;
        items = [];
      }
      items.add(li.group(2)!);
      continue;
    }
    // 列表续行：≥2 空格缩进并入上一项
    if (listOrdered != null && items.isNotEmpty && _listContRe.hasMatch(l)) {
      items[items.length - 1] += ' ${l.trim()}';
      continue;
    }
    flushList();
    para.add(l);
  }
  flushPara();
  flushList();
  return out;
}

/// 表格行拆单元格（对齐 web cells()：trim → 去首尾 | → split → 各自 trim）
List<String> _tableCells(String row) {
  final t = row.trim().replaceAllMapped(RegExp(r'^\||\|$'), (_) => '').split('|');
  return [for (final c in t) c.trim()];
}

// ─────────────────────────────────────────────────────────────
// 解析层：行内解析（对齐 app.js inline()：code 占位 → bold → em → link）
// ─────────────────────────────────────────────────────────────

/// 行内入口。对齐 web inline() 架构：行内 code 先抽成 `\u0000N\u0000`
/// 占位符（保持字符串完整，bold/em/link 正则可跨越 code 段匹配），
/// 解析完成后占位符在树内回填为 MdCodeSpan——链接文本内的 `code`
/// 由此保真（web L508/L513 同构）。
List<MdInline> parseInline(String s) {
  final codes = <String>[];
  final t = s.replaceAllMapped(_codeSpanRe, (m) {
    codes.add(m.group(1)!);
    return '\u0000${codes.length - 1}\u0000';
  });
  return [
    for (final n in _parseBold(t)) ..._restoreCodes(n, codes),
  ];
}

/// 树内占位符回填：后序遍历，MdPlain 文本中的 `\u0000N\u0000` 展开为
/// MdCodeSpan 序列（占位符可能落在 plain / bold / em / link 文本任一层）
List<MdInline> _restoreCodes(MdInline n, List<String> codes) {
  switch (n) {
    case MdPlain():
      return _restoreInText(n.text, codes);
    case MdCodeSpan():
      return [n];
    case MdBold b:
      return [
        MdBold([for (final c in b.children) ..._restoreCodes(c, codes)]),
      ];
    case MdItalic b:
      return [
        MdItalic([for (final c in b.children) ..._restoreCodes(c, codes)]),
      ];
    case MdLink l:
      return [
        MdLink(
          [for (final c in l.children) ..._restoreCodes(c, codes)],
          l.url,
        ),
      ];
  }
}

final RegExp _placeholderRe = RegExp(r'\u0000(\d+)\u0000');

List<MdInline> _restoreInText(String s, List<String> codes) {
  final out = <MdInline>[];
  var pos = 0;
  for (final m in _placeholderRe.allMatches(s)) {
    if (m.start > pos) out.add(MdPlain(s.substring(pos, m.start)));
    out.add(MdCodeSpan(codes[int.parse(m.group(1)!)]));
    pos = m.end;
  }
  if (pos < s.length) out.add(MdPlain(s.substring(pos)));
  return out;
}

List<MdInline> _parseBold(String s) {
  final out = <MdInline>[];
  var pos = 0;
  for (final m in _boldRe.allMatches(s)) {
    if (m.start < pos) continue;
    if (m.start > pos) out.addAll(_parseEm(s.substring(pos, m.start)));
    out.add(MdBold(_parseEm(m.group(1)!)));
    pos = m.end;
  }
  if (pos < s.length) out.addAll(_parseEm(s.substring(pos)));
  return out;
}

List<MdInline> _parseEm(String s) {
  final out = <MdInline>[];
  var pos = 0;
  for (final m in _emRe.allMatches(s)) {
    if (m.start < pos) continue; // 前缀捕获与上一匹配重叠时跳过
    final prefixLen = m.group(1)!.length;
    if (m.start + prefixLen > pos) {
      out.addAll(_parseLink(s.substring(pos, m.start + prefixLen)));
    }
    out.add(MdItalic(_parseLink(m.group(2)!)));
    pos = m.end;
  }
  if (pos < s.length) out.addAll(_parseLink(s.substring(pos)));
  return out;
}

List<MdInline> _parseLink(String s) {
  final out = <MdInline>[];
  var pos = 0;
  for (final m in _linkRe.allMatches(s)) {
    if (m.start < pos) continue;
    if (m.start > pos) out.add(MdPlain(s.substring(pos, m.start)));
    out.add(MdLink([MdPlain(m.group(1)!)], m.group(2)!));
    pos = m.end;
  }
  if (pos < s.length) out.add(MdPlain(s.substring(pos)));
  return out;
}

/// 行内节点 → 纯文本（表格单元格 / 链接文本降级用）
String mdPlainText(MdInline n) {
  switch (n) {
    case MdPlain():
      return n.text;
    case MdCodeSpan():
      return n.code;
    case MdBold b:
      return b.children.map(mdPlainText).join();
    case MdItalic b:
      return b.children.map(mdPlainText).join();
    case MdLink l:
      return l.children.map(mdPlainText).join();
  }
}

// ─────────────────────────────────────────────────────────────
// 渲染层：行内 span 构建 + 链接手势管理
// ─────────────────────────────────────────────────────────────

/// 行内富文本。多行时行间插 `\n`（= web 段落 `<br>` join）。
/// StatefulWidget 管理 TapGestureRecognizer 生命周期（build 前释放上一轮，
/// dispose 兜底）。
class MdInlineText extends StatefulWidget {
  const MdInlineText({super.key, required this.lines, this.base});

  /// 已按行拆好的原文（每行独立 parseInline）
  final List<String> lines;

  /// 基础样式；null 用 TraeText.body
  final TextStyle? base;

  @override
  State<MdInlineText> createState() => _MdInlineTextState();
}

class _MdInlineTextState extends State<MdInlineText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final base = widget.base ?? TraeText.body(context);
    final children = <InlineSpan>[];
    for (var i = 0; i < widget.lines.length; i++) {
      children.addAll(_spans(context, parseInline(widget.lines[i]), base));
      if (i < widget.lines.length - 1) children.add(const TextSpan(text: '\n'));
    }
    return Text.rich(TextSpan(children: children));
  }

  List<InlineSpan> _spans(
      BuildContext context, List<MdInline> nodes, TextStyle base) {
    return [for (final n in nodes) _span(context, n, base)];
  }

  InlineSpan _span(BuildContext context, MdInline n, TextStyle base) {
    switch (n) {
      case MdPlain():
        return TextSpan(text: n.text, style: base);
      case MdCodeSpan():
        // web：mono .9em + surface2 底（TextSpan 无法画边框圆角，取近似）
        return TextSpan(
          text: n.code,
          style: base.copyWith(
            fontFamily: 'monospace',
            fontSize: base.fontSize! * 0.9,
            backgroundColor: context.trae.surface2,
          ),
        );
      case MdBold():
        return TextSpan(
          children: _spans(
              context, n.children, base.copyWith(fontWeight: FontWeight.w700)),
        );
      case MdItalic():
        return TextSpan(
          children: _spans(
              context, n.children, base.copyWith(fontStyle: FontStyle.italic)),
        );
      case MdLink():
        final r = TapGestureRecognizer()..onTap = () => _openUrl(n.url);
        _recognizers.add(r);
        return TextSpan(
          children: _spans(
              context, n.children, base.copyWith(color: context.trae.accentText)),
          recognizer: r,
        );
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

// ─────────────────────────────────────────────────────────────
// 渲染层：块级布局
// ─────────────────────────────────────────────────────────────

/// AI 回复正文渲染器。整体包 SelectionArea：多块可一次长按全选复制。
class MarkdownView extends StatelessWidget {
  const MarkdownView({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final blocks = parseMarkdown(text);
    final children = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      if (i > 0) children.add(const SizedBox(height: TraeTokens.gapMd));
      children.add(_buildBlock(context, blocks[i]));
    }
    if (children.isEmpty) children.add(const SizedBox(width: double.infinity));
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _buildBlock(BuildContext context, MdBlock b) {
    switch (b) {
      case MdParagraph():
        return MdInlineText(lines: b.lines);
      case MdHeading():
        return Text.rich(
          TextSpan(
            children: [
              for (final n in parseInline(b.text))
                _headingSpan(context, n, b.level3),
            ],
          ),
          style: TextStyle(
            fontSize: b.level3 ? TraeTokens.fontLg : TraeTokens.fontBase,
            fontWeight: FontWeight.w700,
            color: context.trae.ink,
            height: 1.35,
          ),
        );
      case MdThematicBreak():
        return Container(
          height: 1,
          width: double.infinity,
          color: context.trae.line,
          margin: const EdgeInsets.symmetric(vertical: TraeTokens.gapSm),
        );
      case MdBlockquote():
        return Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: context.trae.line, width: 3),
            ),
          ),
          padding: const EdgeInsets.only(left: TraeTokens.gapMd),
          child: MdInlineText(
            lines: [b.text],
            base: TraeText.body(context).copyWith(color: context.trae.muted),
          ),
        );
      case MdTable():
        return _TableView(table: b);
      case MdListBlock():
        return _ListView(block: b);
      case MdCodeBlock():
        return _CodeBlockView(block: b);
    }
  }

  /// 标题行内：code/bold/em 保留，样式降为纯文本着色（标题本就 w700）
  InlineSpan _headingSpan(BuildContext context, MdInline n, bool level3) {
    final base = TextStyle(
      fontSize: level3 ? TraeTokens.fontLg : TraeTokens.fontBase,
      fontWeight: FontWeight.w700,
      color: context.trae.ink,
      height: 1.35,
    );
    switch (n) {
      case MdPlain():
        return TextSpan(text: n.text, style: base);
      case MdCodeSpan():
        return TextSpan(
          text: n.code,
          style: base.copyWith(
            fontFamily: 'monospace',
            fontSize: base.fontSize! * 0.9,
            backgroundColor: context.trae.surface2,
          ),
        );
      case MdBold b:
        return TextSpan(
          text: b.children.map(mdPlainText).join(),
          style: base,
        );
      case MdItalic b:
        return TextSpan(
          text: b.children.map(mdPlainText).join(),
          style: base,
        );
      case MdLink l:
        return TextSpan(
          text: l.children.map(mdPlainText).join(),
          style: base.copyWith(color: context.trae.accentText),
        );
    }
  }
}

// ─────────────────────────────────────────────────────────────
// 代码块（恒暗 + lang 头 + copy）
// ─────────────────────────────────────────────────────────────

class _CodeBlockView extends StatefulWidget {
  const _CodeBlockView({required this.block});

  final MdCodeBlock block;

  @override
  State<_CodeBlockView> createState() => _CodeBlockViewState();
}

class _CodeBlockViewState extends State<_CodeBlockView> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.block.code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('已复制'), duration: Duration(milliseconds: 1500)),
    );
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.trae;
    // 恒暗：codeBg/codeInk 两主题各自更暗一档，但同为暗色（tokens.css L50/L81）
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: p.codeBg,
        borderRadius: BorderRadius.circular(TraeTokens.radiusMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部：lang 标签 + copy（web st-code__head：#9aa3ab 固定色）
          Container(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(
                    color: Color(0x0FFFFFFF)), // rgba(255,255,255,.06)
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.block.lang.isEmpty ? 'code' : widget.block.lang,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: TraeTokens.fontXs,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF9AA3AB),
                    ),
                  ),
                ),
                InkWell(
                  onTap: _copy,
                  borderRadius: BorderRadius.circular(TraeTokens.radiusSm),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      _copied ? Icons.check : Icons.copy,
                      size: 15,
                      color: const Color(0xFF9AA3AB),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(14),
            child: Text(
              widget.block.code,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.6,
                color: p.codeInk,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 表格（1px line 边框，th 加粗；外层横向滚动）
// ─────────────────────────────────────────────────────────────

class _TableView extends StatelessWidget {
  const _TableView({required this.table});

  final MdTable table;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: context.trae.line, width: 1),
        children: [
          TableRow(
            children: [
              for (final h in table.header) _cell(context, h, header: true),
            ],
          ),
          for (final row in table.rows)
            TableRow(children: [for (final c in row) _cell(context, c)]),
        ],
      ),
    );
  }

  Widget _cell(BuildContext context, String text, {bool header = false}) {
    final base = TraeText.body(context);
    // 单元格内行内样式降为纯文本（web 表格单元格 inline() 结果含标签，
    // 这里取其纯文本，避免嵌套表格布局抖动）
    final plain =
        parseInline(text).map(mdPlainText).join();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Text(
        plain,
        style: base.copyWith(
          fontWeight: header ? FontWeight.w600 : FontWeight.w400,
          color: header ? context.trae.ink : null,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 列表（不嵌套；ul 圆点 / ol 数字，muted 标记 + 正文）
// ─────────────────────────────────────────────────────────────

class _ListView extends StatelessWidget {
  const _ListView({required this.block});

  final MdListBlock block;

  @override
  Widget build(BuildContext context) {
    final markerStyle = TraeText.body(context)
        .copyWith(color: context.trae.muted, fontWeight: FontWeight.w500);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < block.items.length; i++) ...[
          if (i > 0) const SizedBox(height: TraeTokens.gapXs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: block.ordered ? 26 : 18,
                child: Text(
                  block.ordered ? '${i + 1}.' : '•',
                  style: markerStyle,
                ),
              ),
              Expanded(child: MdInlineText(lines: [block.items[i]])),
            ],
          ),
        ],
      ],
    );
  }
}

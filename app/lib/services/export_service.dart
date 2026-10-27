// 会话导出服务（M1-12，SPEC v0.3.5 §5.1「多格式导出」/ §9 导出 .json schema / ADR-9 决策 2）。
//
// 四种格式：
// - .md    纯 Dart 拼装，适合存档与二次编辑
// - .json  结构化（schema_version 演进），唯一支持回导的格式
// - .html  单文件网页（内嵌 CSS + entity 转义），浏览器直接打开
// - .pdf   pdf 包排版，须内嵌 CJK 静态字体（缺字体时降级 Helvetica，中文会缺字）
//
// 落地链路（零权限，SPEC §11 第 8 条）：生成 bytes → 写 App 临时目录 →
// share_plus 系统分享面板。不直接写公共 Download 目录（Android 11+ scoped
// storage 会 Permission denied，见 ADR-9 预研）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../models/conversation.dart';

/// 导出格式（四选一；仅 .json 可导入——其余为渲染格式无消歧能力，SPEC §5.3）
enum ExportFormat {
  markdown('Markdown', 'md', 'text/markdown'),
  json('JSON', 'json', 'application/json'),
  html('HTML', 'html', 'text/html'),
  pdf('PDF', 'pdf', 'application/pdf');

  const ExportFormat(this.label, this.fileExtension, this.mimeType);

  final String label;
  final String fileExtension;
  final String mimeType;
}

/// 导出时的主机元信息（由调用方从 profilesProvider 解析；Profile 可能已删除）
class ExportProfileMeta {
  const ExportProfileMeta({required this.name, required this.host, required this.port});

  final String name;
  final String host;
  final int port;
}

class ExportResult {
  const ExportResult({required this.bytes, required this.fileName, required this.mimeType});

  final Uint8List bytes;
  final String fileName;
  final String mimeType;

  String get sizeLabel {
    final kb = bytes.length / 1024;
    return kb >= 1024 ? '${kb.toStringAsFixed(1)} MB' : '${kb.toStringAsFixed(0)} KB';
  }
}

/// 当前导出 schema 版本（导入容错策略见 SPEC §6.1 第 5 条）
const kExportSchemaVersion = 1;

/// 导出文件的 app 标识。
///
/// v0.0.10：改为不含第三方项目名称的通用标识——本 App 是独立的第三方客户端，
/// 导出件不应对外暗示与任何上游项目存在隶属或官方关系。
const kExportAppTag = 'mobile_llm_controller';

class ExportService {
  ExportService({
    Future<ByteData?> Function()? cjkFontLoader,
    this.imageResolver,
  }) : _cjkFontLoader = cjkFontLoader ?? _loadBundledCjkFont;

  /// CJK 字体加载器（可注入：单测注入内存字节；生产从 assets 读静态子集）
  final Future<ByteData?> Function() _cjkFontLoader;

  /// 图片路径 → dataURL 的解析器（可注入：生产用 ImageStore；null → 保持路径原样）。
  ///
  /// v0.0.10：DB 里存的是落盘路径，导出成 .json 时需要内联 dataURL 才能
  /// 让"导出 → 导入"后的会话仍然看得见图。
  final Future<List<String>> Function(List<String> paths)? imageResolver;

  /// 消息级图片解析：把路径列表换成 dataURL 列表（无解析器时原样返回）。
  Future<List<String>> _resolveImages(List<String> paths) async {
    if (paths.isEmpty) return paths;
    final resolver = imageResolver;
    if (resolver == null) return paths;
    final resolved = await resolver(paths);
    // 解析失败的条目剔除（避免导出里出现无效路径）
    return resolved.where((s) => s.isNotEmpty).toList();
  }

  /// 消息列表 → 导出的 JSON 形态（含图片 dataURL 与 stopped 标记）。
  Future<List<Map<String, Object?>>> _messagesForJson(
      List<ConversationMessage> messages) async {
    final out = <Map<String, Object?>>[];
    for (final m in messages) {
      final images = await _resolveImages(m.imageUrls);
      out.add({
        'seq': m.seq,
        'role': m.role,
        'content': m.content,
        'reasoning': m.reasoning,
        if (m.usage != null)
          'usage': {
            'prompt_tokens': m.usage!.promptTokens,
            'completion_tokens': m.usage!.completionTokens,
            'total_tokens': m.usage!.totalTokens,
          }
        else
          'usage': null,
        'timestamp': m.timestamp.toIso8601String(),
        'error': m.error,
        'stopped': m.stopped,
        // v0.0.10：图片附件（dataURL 内联，使导出→导入后图片仍在）
        if (images.isNotEmpty) 'images': images,
      });
    }
    return out;
  }

  static const _cjkFontAsset = 'assets/fonts/cjk-regular.ttf';

  /// 打包内 CJK 静态字体；资产缺失（未入库）时返回 null → PDF 降级 Helvetica
  static Future<ByteData?> _loadBundledCjkFont() async {
    try {
      return await rootBundle.load(_cjkFontAsset);
    } on Exception {
      return null;
    }
  }

  /// 导出一个会话（messages 需已按 seq 升序）
  Future<ExportResult> export({
    required Conversation conversation,
    required List<ConversationMessage> messages,
    required ExportFormat format,
    ExportProfileMeta? profileMeta,
  }) async {
    final baseName = _baseFileName(conversation);
    switch (format) {
      case ExportFormat.markdown:
        return ExportResult(
          bytes: Uint8List.fromList(utf8.encode(
              buildMarkdown(conversation, messages, profileMeta: profileMeta))),
          fileName: '$baseName.md',
          mimeType: format.mimeType,
        );
      case ExportFormat.json:
        return ExportResult(
          bytes: Uint8List.fromList(utf8.encode(await buildJsonAsync(
              conversation, messages,
              profileMeta: profileMeta))),
          fileName: '$baseName.json',
          mimeType: format.mimeType,
        );
      case ExportFormat.html:
        return ExportResult(
          bytes: Uint8List.fromList(
              utf8.encode(buildHtml(conversation, messages, profileMeta: profileMeta))),
          fileName: '$baseName.html',
          mimeType: format.mimeType,
        );
      case ExportFormat.pdf:
        return ExportResult(
          bytes: await buildPdf(conversation, messages, profileMeta: profileMeta),
          fileName: '$baseName.pdf',
          mimeType: format.mimeType,
        );
    }
  }

  /// 导出全部会话（M1-12.6 设置页「导出全部会话」）。
  ///
  /// 产物是**单个 .json 打包文件**（不是多次分享）：一次分享面板、一次落盘，
  /// 用户拿到的就是一个可归档的整体；且打包格式与单会话导出同源，
  /// 天然可被 ImportService.parseBundle 回导（导出→导入闭环）。
  ///
  /// [messagesByConversation] 为 conversationId → 该会话的消息（需已按 seq 升序）；
  /// 缺失的会话按空消息导出（不丢会话本身）。
  Future<ExportResult> exportAllBundle({
    required List<Conversation> conversations,
    required Map<String, List<ConversationMessage>> messagesByConversation,
    required Map<String, ExportProfileMeta> profileMetaById,
  }) async {
    final bytes = Uint8List.fromList(
      utf8.encode(await buildJsonBundleAsync(
        conversations,
        messagesByConversation,
        profileMetaById: profileMetaById,
      )),
    );
    return ExportResult(
      bytes: bytes,
      fileName: '全部会话-${_timestampSuffix()}.json',
      mimeType: ExportFormat.json.mimeType,
    );
  }

  /// 全部会话的 .json 打包 schema（v1）：
  /// ```json
  /// { "schema_version": 1, "exported_at": "...", "app": "strata_mobile_controller",
  ///   "conversations": [ { 单会话 conversation 对象 }, ... ] }
  /// ```
  /// 单个会话对象与 [buildJson] 的 `conversation` 字段同构，
  /// 故解析端可复用同一套单会话解析逻辑。
  String buildJsonBundle(
    List<Conversation> conversations,
    Map<String, List<ConversationMessage>> messagesByConversation, {
    Map<String, ExportProfileMeta> profileMetaById = const {},
  }) {
    return const JsonEncoder.withIndent('  ').convert({
      'schema_version': kExportSchemaVersion,
      'exported_at': DateTime.now().toIso8601String(),
      'app': kExportAppTag,
      'conversations': [
        for (final c in conversations)
          {
            'id': c.id,
            'title': c.title,
            'pinned': c.pinned,
            if (profileMetaById[c.profileId] != null)
              'profile': {
                'name': profileMetaById[c.profileId]!.name,
                'host': profileMetaById[c.profileId]!.host,
                'port': profileMetaById[c.profileId]!.port,
              },
            'model': c.modelId,
            'effort': c.effort,
            'created_at': c.createdAt.toIso8601String(),
            'updated_at': c.updatedAt.toIso8601String(),
            'messages': [
              for (final m in messagesByConversation[c.id] ?? const <ConversationMessage>[])
                {
                  'seq': m.seq,
                  'role': m.role,
                  'content': m.content,
                  'reasoning': m.reasoning,
                  if (m.usage != null)
                    'usage': {
                      'prompt_tokens': m.usage!.promptTokens,
                      'completion_tokens': m.usage!.completionTokens,
                      'total_tokens': m.usage!.totalTokens,
                    }
                  else
                    'usage': null,
                  'timestamp': m.timestamp.toIso8601String(),
                  'error': m.error,
                  'stopped': m.stopped,
                  // v0.0.10：图片附件（dataURL 内联，使导出→导入后图片仍在）
                  if (m.imageUrls.isNotEmpty) 'images': m.imageUrls,
                },
            ],
          },
      ],
    });
  }

  /// 全部会话 .json 打包（v0.0.10：图片路径解析为 dataURL 后内联）
  Future<String> buildJsonBundleAsync(
    List<Conversation> conversations,
    Map<String, List<ConversationMessage>> messagesByConversation, {
    Map<String, ExportProfileMeta> profileMetaById = const {},
  }) async {
    final convs = <Map<String, Object?>>[];
    for (final c in conversations) {
      final msgs = await _messagesForJson(
          messagesByConversation[c.id] ?? const <ConversationMessage>[]);
      convs.add({
        'id': c.id,
        'title': c.title,
        'pinned': c.pinned,
        if (profileMetaById[c.profileId] != null)
          'profile': {
            'name': profileMetaById[c.profileId]!.name,
            'host': profileMetaById[c.profileId]!.host,
            'port': profileMetaById[c.profileId]!.port,
          },
        'model': c.modelId,
        'effort': c.effort,
        'created_at': c.createdAt.toIso8601String(),
        'updated_at': c.updatedAt.toIso8601String(),
        'messages': msgs,
      });
    }
    return const JsonEncoder.withIndent('  ').convert({
      'schema_version': kExportSchemaVersion,
      'exported_at': DateTime.now().toIso8601String(),
      'app': kExportAppTag,
      'conversations': convs,
    });
  }

  /// 文件名基干：Strata会话-{标题清洗}-{时间戳}
  static String _baseFileName(Conversation c) {
    final safe = _sanitizeFileName(c.title);
    final ts = c.createdAt.toLocal();
    final stamp =
        '${ts.year}${_two(ts.month)}${_two(ts.day)}-${_two(ts.hour)}${_two(ts.minute)}';
    return 'Strata会话-$safe-$stamp';
  }

  /// 时间戳后缀：yyyyMMdd-HHmm（导出全部会话的文件名用当前时刻）
  static String _timestampSuffix() {
    final ts = DateTime.now().toLocal();
    return '${ts.year}${_two(ts.month)}${_two(ts.day)}-${_two(ts.hour)}${_two(ts.minute)}';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// 清洗 Android/Windows 文件名非法字符
  static String _sanitizeFileName(String s) => s
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// 消息内容摘要（v0.0.7 真机反馈：单条导出文件名全是「Strata消息-模型-
  /// 时间」，无法分辨是哪句对话）。取首个非空行、压空白、去 Markdown 标记、
  /// 截 16 字；空内容回退空串（文件名退化为旧格式，不报错）。
  static String messageExcerpt(String content) {
    var line = '';
    for (final l in content.split('\n')) {
      final t = l.trim();
      if (t.isEmpty) continue;
      line = t;
      break;
    }
    line = line
        .replaceAll(RegExp(r'^[#>*\-`\s]+'), '') // 常见 Markdown 标记
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (line.isEmpty) return '';
    final chars = line.characters;
    final cut = chars.length > 16 ? '${chars.take(16).join()}…' : line;
    // 摘要直接进文件名：过一遍非法字符清洗（含截断产生的边界空白）
    final safe = _sanitizeFileName(cut);
    return safe.isEmpty ? '' : safe;
  }

  // ---------- Markdown ----------

  /// 单条消息导出为 .md（v0.0.4，用户需求「每句对话都可以下载为 .md」）：
  /// AI 消息带思考块引用，用户消息只带正文。
  ExportResult exportMessageMarkdown({
    required bool isUser,
    required String content,
    String? reasoning,
    DateTime? timestamp,
  }) {
    final buf = StringBuffer();
    buf.writeln(isUser ? '# 我的提问' : '# 模型回复');
    buf.writeln();
    buf.writeln('- 时间：${_fmt(timestamp ?? DateTime.now())}');
    buf.writeln('- 导出时间：${_fmt(DateTime.now())}');
    buf.writeln();
    if (!isUser && reasoning != null && reasoning.trim().isNotEmpty) {
      buf.writeln('**思考过程**');
      buf.writeln();
      for (final line in reasoning.split('\n')) {
        buf.writeln('> $line');
      }
      buf.writeln();
    }
    if (content.isNotEmpty) {
      buf.writeln(content);
      buf.writeln();
    }
    buf.writeln('---');
    buf.writeln();
    buf.writeln('*由本地模型移动控制端导出 · 非官方第三方工具*');
    final ts = DateTime.now();
    final stamp =
        '${ts.year}${_two(ts.month)}${_two(ts.day)}-${_two(ts.hour)}${_two(ts.minute)}';
    // 【v0.0.7】文件名带内容摘要：测试者反馈导出的 .md「没有根据会话
    // 内容命名」，一串「Strata消息-模型-时间戳」无法分辨是哪句对话
    final excerpt = messageExcerpt(content);
    final excerptPart = excerpt.isEmpty ? '' : '-$excerpt';
    return ExportResult(
      bytes: Uint8List.fromList(utf8.encode(buf.toString())),
      fileName: 'Strata消息-${isUser ? '我' : '模型'}$excerptPart-$stamp.md',
      mimeType: 'text/markdown',
    );
  }

  String buildMarkdown(
    Conversation c,
    List<ConversationMessage> messages, {
    ExportProfileMeta? profileMeta,
  }) {
    final buf = StringBuffer();
    buf.writeln('# ${c.title}');
    buf.writeln();
    if (profileMeta != null) {
      buf.writeln('- 主机：${profileMeta.name}（${profileMeta.host}:${profileMeta.port}）');
    }
    buf.writeln('- 模型：${c.modelId ?? '未指定'}');
    buf.writeln('- 思考档位：${c.effort}');
    buf.writeln('- 创建时间：${_fmt(c.createdAt)}');
    buf.writeln('- 导出时间：${_fmt(DateTime.now())}');
    buf.writeln();
    buf.writeln('---');
    buf.writeln();

    for (final m in messages) {
      buf.writeln('## ${m.isUser ? '我' : '模型'} · ${_fmt(m.timestamp)}');
      buf.writeln();
      if (m.reasoning != null && m.reasoning!.isNotEmpty) {
        buf.writeln('**思考过程**');
        buf.writeln();
        for (final line in m.reasoning!.split('\n')) {
          buf.writeln('> $line');
        }
        buf.writeln();
      }
      if (m.content.isNotEmpty) {
        buf.writeln(m.content);
        buf.writeln();
      }
      if (m.error != null) {
        buf.writeln('*（错误：${m.error}）*');
        buf.writeln();
      }
      final u = m.usage;
      if (u != null) {
        buf.writeln('*（用量：${u.totalTokens} tokens：'
            'prompt ${u.promptTokens} / completion ${u.completionTokens}）*');
        buf.writeln();
      }
      buf.writeln('---');
      buf.writeln();
    }
    return buf.toString();
  }

  // ---------- JSON（回导唯一格式，schema 见 SPEC §9） ----------

  String buildJson(
    Conversation c,
    List<ConversationMessage> messages, {
    ExportProfileMeta? profileMeta,
  }) {
    return const JsonEncoder.withIndent('  ').convert({
      'schema_version': kExportSchemaVersion,
      'exported_at': DateTime.now().toIso8601String(),
      'app': kExportAppTag,
      'conversation': {
        'id': c.id,
        'title': c.title,
        if (profileMeta != null)
          'profile': {
            'name': profileMeta.name,
            'host': profileMeta.host,
            'port': profileMeta.port,
          },
        'model': c.modelId,
        'effort': c.effort,
        'created_at': c.createdAt.toIso8601String(),
        'messages': [
          for (final m in messages)
            {
              'seq': m.seq,
              'role': m.role,
              'content': m.content,
              'reasoning': m.reasoning,
              if (m.usage != null)
                'usage': {
                  'prompt_tokens': m.usage!.promptTokens,
                  'completion_tokens': m.usage!.completionTokens,
                  'total_tokens': m.usage!.totalTokens,
                }
              else
                'usage': null,
              'timestamp': m.timestamp.toIso8601String(),
              'error': m.error,
              'stopped': m.stopped,
              // v0.0.10：图片附件（dataURL 内联，使导出→导入后图片仍在）
              if (m.imageUrls.isNotEmpty) 'images': m.imageUrls,
            },
        ],
      },
    });
  }

  /// 单会话 .json（v0.0.10：图片路径解析为 dataURL 后内联）
  Future<String> buildJsonAsync(
    Conversation c,
    List<ConversationMessage> messages, {
    ExportProfileMeta? profileMeta,
  }) async {
    final msgs = await _messagesForJson(messages);
    return const JsonEncoder.withIndent('  ').convert({
      'schema_version': kExportSchemaVersion,
      'exported_at': DateTime.now().toIso8601String(),
      'app': kExportAppTag,
      'conversation': {
        'id': c.id,
        'title': c.title,
        if (profileMeta != null)
          'profile': {
            'name': profileMeta.name,
            'host': profileMeta.host,
            'port': profileMeta.port,
          },
        'model': c.modelId,
        'effort': c.effort,
        'created_at': c.createdAt.toIso8601String(),
        'messages': msgs,
      },
    });
  }

  // ---------- HTML（单文件，内嵌 CSS + entity 转义） ----------

  String buildHtml(
    Conversation c,
    List<ConversationMessage> messages, {
    ExportProfileMeta? profileMeta,
  }) {
    final esc = _escapeHtml;
    final buf = StringBuffer();
    buf.writeln('<!DOCTYPE html>');
    buf.writeln(
        '<html lang="zh-CN"><head><meta charset="utf-8">');
    buf.writeln('<meta name="viewport" content="width=device-width, initial-scale=1">');
    buf.writeln('<title>${esc(c.title)}</title>');
    buf.writeln('<style>$_htmlCss</style>');
    buf.writeln('</head><body>');
    buf.writeln('<header>');
    buf.writeln('<h1>${esc(c.title)}</h1>');
    buf.writeln('<div class="meta">');
    if (profileMeta != null) {
      buf.writeln(
          '<span>主机：${esc(profileMeta.name)}（${esc(profileMeta.host)}:${profileMeta.port}）</span>');
    }
    buf.writeln('<span>模型：${esc(c.modelId ?? '未指定')}</span>');
    buf.writeln('<span>思考档位：${esc(c.effort)}</span>');
    buf.writeln('<span>创建：${esc(_fmt(c.createdAt))}</span>');
    buf.writeln('<span>导出：${esc(_fmt(DateTime.now()))}</span>');
    buf.writeln('</div></header>');
    buf.writeln('<main>');
    for (final m in messages) {
      final roleCls = m.isUser ? 'user' : 'ai';
      buf.writeln('<section class="msg $roleCls">');
      buf.writeln(
          '<div class="who">${m.isUser ? '我' : '模型'} · ${esc(_fmt(m.timestamp))}</div>');
      if (m.reasoning != null && m.reasoning!.isNotEmpty) {
        buf.writeln('<details class="thinking"><summary>思考过程</summary>');
        buf.writeln('<div>${_htmlParagraphs(m.reasoning!)}</div></details>');
      }
      if (m.content.isNotEmpty) {
        buf.writeln('<div class="content">${_htmlParagraphs(m.content)}</div>');
      }
      if (m.error != null) {
        buf.writeln('<div class="error">错误：${esc(m.error!)}</div>');
      }
      final u = m.usage;
      if (u != null) {
        buf.writeln(
            '<div class="usage">${u.totalTokens} tokens（prompt ${u.promptTokens} / completion ${u.completionTokens}）</div>');
      }
      buf.writeln('</section>');
    }
    buf.writeln('</main>');
    buf.writeln(
        '<footer>由本地模型移动控制端导出 · 非官方第三方工具</footer>');
    buf.writeln('</body></html>');
    return buf.toString();
  }

  // ---------- PDF ----------

  Future<Uint8List> buildPdf(
    Conversation c,
    List<ConversationMessage> messages, {
    ExportProfileMeta? profileMeta,
  }) async {
    final fontData = await _cjkFontLoader();
    final hasCjk = fontData != null;

    pw.ThemeData theme;
    if (hasCjk) {
      final font = pw.Font.ttf(fontData);
      // pdf 包的 TextStyle 在 inherit=false 时对 15 个字段逐一断言非空
      // （color/font*/fontSize/fontWeight/fontStyle/letterSpacing/
      //  wordSpacing/lineSpacing/height/decoration*/renderingMode），
      // 缺一即在构造期抛 AssertionError，PDF 导出整条链路失败。
      // 取值对齐 TextStyle.defaultStyle()，仅把字体换成 CJK 子集。
      final style = pw.TextStyle(
        inherit: false,
        color: PdfColors.black,
        fontNormal: font,
        fontBold: font,
        fontItalic: font,
        fontBoldItalic: font,
        fontFallback: const [],
        fontSize: 11,
        fontWeight: pw.FontWeight.normal,
        fontStyle: pw.FontStyle.normal,
        letterSpacing: 0,
        wordSpacing: 1,
        lineSpacing: 2,
        height: 1,
        decoration: pw.TextDecoration.none,
        decorationColor: null,
        decorationStyle: pw.TextDecorationStyle.solid,
        decorationThickness: 1,
        renderingMode: PdfTextRenderingMode.fill,
      );
      theme = pw.ThemeData(defaultTextStyle: style);
    } else {
      // 字体资产缺失：降级内置 Helvetica（中文将缺字，见 ADR-9 决策 3 阻断项）
      theme = pw.ThemeData(defaultTextStyle: pw.TextStyle.defaultStyle());
    }

    final doc = pw.Document(theme: theme);
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(48, 40, 48, 40),
      header: (ctx) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Text(
          '本地模型移动控制端 · 会话导出（非官方第三方工具）',
          style: pw.TextStyle(
            fontSize: 8,
            color: PdfColors.grey600,
            fontNormal: theme.defaultTextStyle.fontNormal,
            fontBold: theme.defaultTextStyle.fontNormal,
            fontItalic: theme.defaultTextStyle.fontNormal,
            fontBoldItalic: theme.defaultTextStyle.fontNormal,
          ),
        ),
      ),
      build: (ctx) => [
        pw.Text(c.title,
            style: pw.TextStyle(
              fontSize: 20,
              fontWeight: pw.FontWeight.bold,
              fontNormal: theme.defaultTextStyle.fontNormal,
              fontBold: theme.defaultTextStyle.fontNormal,
              fontItalic: theme.defaultTextStyle.fontNormal,
              fontBoldItalic: theme.defaultTextStyle.fontNormal,
            )),
        pw.SizedBox(height: 6),
        pw.Text(
          [
            if (profileMeta != null)
              '主机：${profileMeta.name}（${profileMeta.host}:${profileMeta.port}）',
            '模型：${c.modelId ?? '未指定'}',
            '思考档位：${c.effort}',
            '创建：${_fmt(c.createdAt)}',
            '导出：${_fmt(DateTime.now())}',
          ].join('  ·  '),
          style: pw.TextStyle(
            fontSize: 9,
            color: PdfColors.grey700,
            fontNormal: theme.defaultTextStyle.fontNormal,
            fontBold: theme.defaultTextStyle.fontNormal,
            fontItalic: theme.defaultTextStyle.fontNormal,
            fontBoldItalic: theme.defaultTextStyle.fontNormal,
          ),
        ),
        pw.Divider(height: 24),
        for (final m in messages) ...[
          pw.Text(
            '${m.isUser ? '我' : '模型'} · ${_fmt(m.timestamp)}',
            style: pw.TextStyle(
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
              color: PdfColor.fromHex('#0C8A60'),
              fontNormal: theme.defaultTextStyle.fontNormal,
              fontBold: theme.defaultTextStyle.fontNormal,
              fontItalic: theme.defaultTextStyle.fontNormal,
              fontBoldItalic: theme.defaultTextStyle.fontNormal,
            ),
          ),
          pw.SizedBox(height: 4),
          if (m.reasoning != null && m.reasoning!.isNotEmpty) ...[
            pw.Container(
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey100,
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('思考过程',
                      style: pw.TextStyle(
                        fontSize: 9,
                        color: PdfColors.grey700,
                        fontNormal: theme.defaultTextStyle.fontNormal,
                        fontBold: theme.defaultTextStyle.fontNormal,
                        fontItalic: theme.defaultTextStyle.fontNormal,
                        fontBoldItalic: theme.defaultTextStyle.fontNormal,
                      )),
                  pw.SizedBox(height: 2),
                  pw.Text(m.reasoning!,
                      style: pw.TextStyle(
                        fontSize: 9,
                        color: PdfColors.grey700,
                        lineSpacing: 1.5,
                        fontNormal: theme.defaultTextStyle.fontNormal,
                        fontBold: theme.defaultTextStyle.fontNormal,
                        fontItalic: theme.defaultTextStyle.fontNormal,
                        fontBoldItalic: theme.defaultTextStyle.fontNormal,
                      )),
                ],
              ),
            ),
            pw.SizedBox(height: 6),
          ],
          if (m.content.isNotEmpty)
            pw.Text(m.content,
                style: pw.TextStyle(
                  fontSize: 11,
                  lineSpacing: 2.5,
                  fontNormal: theme.defaultTextStyle.fontNormal,
                  fontBold: theme.defaultTextStyle.fontNormal,
                  fontItalic: theme.defaultTextStyle.fontNormal,
                  fontBoldItalic: theme.defaultTextStyle.fontNormal,
                )),
          if (m.error != null) ...[
            pw.SizedBox(height: 4),
            pw.Text('错误：${m.error}',
                style: pw.TextStyle(
                  fontSize: 10,
                  color: PdfColors.red,
                  fontNormal: theme.defaultTextStyle.fontNormal,
                  fontBold: theme.defaultTextStyle.fontNormal,
                  fontItalic: theme.defaultTextStyle.fontNormal,
                  fontBoldItalic: theme.defaultTextStyle.fontNormal,
                )),
          ],
          if (m.usage != null) ...[
            pw.SizedBox(height: 3),
            pw.Text(
                '${m.usage!.totalTokens} tokens（prompt ${m.usage!.promptTokens} / completion ${m.usage!.completionTokens}）',
                style: pw.TextStyle(
                  fontSize: 8,
                  color: PdfColors.grey600,
                  fontNormal: theme.defaultTextStyle.fontNormal,
                  fontBold: theme.defaultTextStyle.fontNormal,
                  fontItalic: theme.defaultTextStyle.fontNormal,
                  fontBoldItalic: theme.defaultTextStyle.fontNormal,
                )),
          ],
          pw.SizedBox(height: 16),
        ],
      ],
    ));
    return doc.save();
  }

  // ---------- 工具 ----------

  static String _fmt(DateTime t) {
    final l = t.toLocal();
    return '${l.year}-${_two(l.month)}-${_two(l.day)} '
        '${_two(l.hour)}:${_two(l.minute)}';
  }

  static String _escapeHtml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');

  /// 多段文本 → <p> 序列（空行分段，换行转 <br>）
  static String _htmlParagraphs(String s) {
    final parts =
        s.split(RegExp(r'\n\s*\n')).where((x) => x.trim().isNotEmpty).toList();
    final body = parts.isEmpty ? [s] : parts;
    return body
        .map((para) =>
            '<p>${_escapeHtml(para.trim()).replaceAll('\n', '<br>')}</p>')
        .join();
  }

  static const _htmlCss = '''
body{margin:0;background:#F7F6F4;color:#0F0F0D;
  font-family:-apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;
  font-size:15px;line-height:1.7}
header{max-width:720px;margin:0 auto;padding:32px 20px 8px}
h1{font-size:22px;margin:0 0 10px}
.meta{display:flex;flex-wrap:wrap;gap:6px 16px;font-size:12px;color:#949492;
  border-bottom:1px solid #E3E2E0;padding-bottom:14px}
main{max-width:720px;margin:0 auto;padding:8px 20px 32px}
.msg{margin:20px 0}
.msg .who{font-size:12px;color:#949492;margin-bottom:6px}
.msg.ai .who{color:#0C8A60;font-weight:600}
.msg.user .content{background:#10B981;color:#fff;border-radius:12px;padding:10px 14px;
  display:inline-block;max-width:85%}
.thinking{border-left:2px solid #E3E2E0;padding:2px 0 2px 10px;margin:6px 0}
.thinking summary{cursor:pointer;font-size:12px;color:#949492}
.thinking>div{font-size:13px;color:#949492;white-space:pre-wrap;margin-top:6px}
.content{white-space:pre-wrap}
.error{font-size:13px;color:#B3261E;margin-top:6px}
.usage{font-size:11px;color:#949492;margin-top:4px}
footer{max-width:720px;margin:0 auto;padding:16px 20px 32px;font-size:11px;
  color:#949492;border-top:1px solid #E3E2E0}
''';
}

/// 导出结果 → 临时目录 → 系统分享面板（零权限链路，UI 调用）
Future<void> shareExportResult(ExportResult result) =>
    shareExportResults([result]);

/// 多文件一次分享（v0.0.7：长截图分片后一次分享全部图片）
Future<void> shareExportResults(List<ExportResult> results) async {
  final dir = await getTemporaryDirectory();
  final files = <XFile>[];
  for (final result in results) {
    final file = File(p.join(dir.path, result.fileName));
    await file.writeAsBytes(result.bytes, flush: true);
    files.add(XFile(file.path, mimeType: result.mimeType));
  }
  await SharePlus.instance.share(ShareParams(
    files: files,
    subject: results.length == 1 ? results.first.fileName : null,
  ));
}

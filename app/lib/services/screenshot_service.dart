// 单条消息「长截图 PNG」服务（v0.0.4 建立，v0.0.7 分片化改造）。
//
// 方案：dart:ui Canvas 离屏自绘（TextPainter 排版 + PictureRecorder 成图），
// 不依赖消息是否在屏幕内（RepaintBoundary 只能截可见区，长回复会截断），
// 内容任意长时生成一张纵向完整长图 —— 与「长截图」语义一致。
//
// 【v0.0.7 真机反馈修复】真机「截图分享总是失败」根因：单张 toImage 的
// 画布高度受 GPU 最大纹理尺寸限制（多数设备 4096，少数 8192 物理像素）。
// dpr=2 下一份长回复（约 2000+ 汉字）排版高度即超 4096，toImage 直接抛
// 异常 → 分享永远失败。修复：按 [_maxTileHeight] 分片渲染，每片独立
// recorder/canvas（clip 到片区间重绘整套内容），多图一次分享（文件名
// 带 -第N部分）。同时补上 image/picture 的 dispose（此前泄漏 GPU 内存）。
//
// 结构（物理像素，dpr=2，逻辑宽 420 → 画布宽 840）：
//   ┌ header：Strata 徽标绿点 + 副题（主机/模型）        ┐
//   │ role 行：我 / 模型 · 时间                           │
//   │ 思考块（浅灰底圆角，仅 reasoning 非空）             │
//   │ 正文（自动换行，任意高度）                          │
//   └ footer 水印：由 Strata Mobile Controller 导出      ┘
//
// CJK 字体：复用包内 assets/fonts/cjk-regular.ttf（与 PDF 导出同源），
// 缺字体时回退系统默认（Android NotoCJK 可兜底）；单测可注入内存字节。

import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader, rootBundle;

import 'export_service.dart';

class ScreenshotService {
  ScreenshotService({Future<ByteData?> Function()? cjkFontLoader})
      : _cjkFontLoader = cjkFontLoader ?? _loadBundledCjkFont;

  final Future<ByteData?> Function() _cjkFontLoader;

  static const _cjkFontAsset = 'assets/fonts/cjk-regular.ttf';

  /// 注册后的 fontFamily 名（全局一次）
  static const _fontFamily = 'screenshot-cjk';
  static bool _fontRegistered = false;

  /// 单片最大物理像素高度：安全低于主流 GPU 最大纹理 4096（v0.0.7）
  static const _maxTileHeight = 3800.0;

  static Future<ByteData?> _loadBundledCjkFont() async {
    try {
      return await rootBundle.load(_cjkFontAsset);
    } on Exception {
      return null;
    }
  }

  Future<String?> _ensureFont() async {
    if (_fontRegistered) return _fontFamily;
    final data = await _cjkFontLoader();
    if (data == null) return null;
    final loader = FontLoader(_fontFamily)..addFont(Future.value(data));
    await loader.load();
    _fontRegistered = true;
    return _fontFamily;
  }

  // ── 设计令牌（对齐 strata_ref/serve/web/tokens.css，v0.0.4 UI 融合） ──
  static const _accent = Color(0xFF10B981);
  static const _accentDark = Color(0xFF0C8A60);
  static const _bg = Color(0xFFF9FAFB);
  static const _line = Color(0xFFDEE5EE);
  static const _inkSoft = Color(0xFF303030);
  static const _inkMuted = Color(0xFF6F6F6F);

  /// 物理像素比例（截图清晰度）
  static const _dpr = 2.0;
  static const _logicalWidth = 420.0;
  static const _canvasWidth = _logicalWidth * _dpr; // 840
  static const _pad = 24.0 * _dpr;
  static const _contentWidth = _canvasWidth - _pad * 2;

  /// 渲染单条消息为 PNG（超高分片）。片数 = ceil(总高 / [_maxTileHeight])，
  /// 单片时文件名与 v0.0.4 保持一致；多片时文件名带「-第N部分」。
  Future<List<ExportResult>> renderMessagePngs({
    required bool isUser,
    required String content,
    String? reasoning,
    DateTime? timestamp,
    String? subtitle,
  }) async {
    final font = await _ensureFont();

    final roleLabel = isUser ? '我' : '模型';
    final timeLabel = _fmt(timestamp ?? DateTime.now());

    // ---------- 阶段 1：排版测高 ----------
    final tpHeader = _tp(subtitle ?? 'Strata', 13, _inkMuted, _dpr, font,
        FontWeight.w500);
    tpHeader.layout(maxWidth: _contentWidth);
    final tpRole = _tp('$roleLabel · $timeLabel', 13, _accentDark, _dpr, font,
        FontWeight.w700);
    tpRole.layout(maxWidth: _contentWidth);

    TextPainter? tpReasoning;
    final reasoningText = reasoning ?? '';
    final hasReasoning = reasoningText.trim().isNotEmpty;
    if (hasReasoning) {
      tpReasoning = _tp(reasoningText, 13, _inkMuted, _dpr, font);
      tpReasoning.layout(maxWidth: _contentWidth - 16 * _dpr * 2);
    }

    final tpContent = _tp(
      content.isEmpty ? '（无正文）' : content,
      15,
      _inkSoft,
      _dpr,
      font,
    );
    tpContent.layout(maxWidth: _contentWidth);

    final tpFooter = _tp('由本地模型移动控制端导出 · 非官方第三方工具', 11, _inkMuted,
        _dpr, font);
    // 【v0.0.7 测试暴露的 v0.0.4 潜在缺陷】footer 此前从未 layout 就在下方
    // 读 .height —— TextPainter 断言 "Text layout not available"，任何长度
    // 的消息都在测高阶段即抛异常。这正是真机「截图分享总是失败」的
    // 第一层根因（纹理上限是第二层）。layout 必须先于取高。
    tpFooter.layout(maxWidth: _contentWidth);

    const blockGap = 10.0 * _dpr;
    final reasoningBlockHeight = hasReasoning
        ? tpReasoning!.height + 14 * _dpr * 2 // 上下内边距
        : 0.0;

    final headerH = 10 * _dpr /*绿点行*/ + tpHeader.height + blockGap;
    final roleH = tpRole.height + blockGap;
    final reasoningH = hasReasoning ? reasoningBlockHeight + blockGap : 0.0;
    final contentH = tpContent.height;
    final footerH = 16 * _dpr /*间隔*/ + 1 /*分隔线*/ + 10 * _dpr +
        tpFooter.height;
    final totalHeight = _pad + headerH + roleH + reasoningH + contentH +
        footerH + _pad;

    // ---------- 阶段 2：分片绘制 ----------
    final tileCount = (totalHeight / _maxTileHeight).ceil().clamp(1, 100);
    final results = <ExportResult>[];
    final ts = DateTime.now();
    final stamp =
        '${ts.year}${_two(ts.month)}${_two(ts.day)}-${_two(ts.hour)}${_two(ts.minute)}';
    final excerpt = ExportService.messageExcerpt(content);

    for (var i = 0; i < tileCount; i++) {
      final tileTop = i * _maxTileHeight;
      final tileHeight =
          (totalHeight - tileTop).clamp(0.0, _maxTileHeight).toDouble();
      if (tileHeight <= 0) break;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder,
          Rect.fromLTWH(0, 0, _canvasWidth, tileHeight));
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, _canvasWidth, tileHeight));
      canvas.translate(0, -tileTop);
      _paintMessage(canvas, totalHeight, tpHeader, tpRole, tpReasoning,
          hasReasoning, reasoningBlockHeight, tpContent, tpFooter, headerH,
          roleH, reasoningH, contentH);
      canvas.restore();

      final picture = recorder.endRecording();
      final image =
          await picture.toImage(_canvasWidth.round(), tileHeight.round());
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      // toByteData(png) 在所有平台非空（web 平台除外——本项目仅 Android）
      final bytes = data!.buffer.asUint8List();
      image.dispose();
      picture.dispose();

      final suffix = tileCount > 1 ? '-第${i + 1}部分' : '';
      final name =
          'Strata消息-${isUser ? '我' : '模型'}-$excerpt-$stamp$suffix.png';
      results.add(ExportResult(
        bytes: bytes,
        fileName: name,
        mimeType: 'image/png',
      ));
    }

    // 排版对象释放（TextPainter 无 dispose API，置 null 即可交由 GC；
    // 真正持有原生资源的是已 dispose 的 picture/image）
    return results;
  }

  /// 把整套内容绘制到 [canvas]（坐标系为完整长图的绝对坐标，
  /// 调用方负责 clip + translate 到目标分片）。
  void _paintMessage(
    Canvas canvas,
    double totalHeight,
    TextPainter tpHeader,
    TextPainter tpRole,
    TextPainter? tpReasoning,
    bool hasReasoning,
    double reasoningBlockHeight,
    TextPainter tpContent,
    TextPainter tpFooter,
    double headerH,
    double roleH,
    double reasoningH,
    double contentH,
  ) {
    // 背景（覆盖完整长图；分片 clip 后只落在片内）
    canvas.drawRect(Rect.fromLTWH(0, 0, _canvasWidth, totalHeight),
        Paint()..color = _bg);

    double y = _pad;

    // header：绿点 + 品牌副题
    canvas.drawCircle(Offset(5 * _dpr, y + 5 * _dpr), 5 * _dpr,
        Paint()..color = _accent);
    tpHeader.paint(canvas, Offset(16 * _dpr, y));
    y += headerH;

    // role 行
    tpRole.paint(canvas, Offset(_pad, y));
    y += roleH;

    // 思考块
    if (hasReasoning) {
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
            _pad, y, _contentWidth, reasoningBlockHeight),
        const Radius.circular(10),
      );
      canvas.drawRRect(rect, Paint()..color = const Color(0xFFF1F3F6));
      tpReasoning!.paint(
          canvas, Offset(_pad + 16 * _dpr, y + 14 * _dpr));
      y += reasoningH;
    }

    // 正文
    tpContent.paint(canvas, Offset(_pad, y));
    y += contentH;

    // footer：分隔线 + 水印（只画在最后一片的可见区）
    y += 16 * _dpr;
    canvas.drawLine(Offset(_pad, y), Offset(_canvasWidth - _pad, y),
        Paint()
          ..color = _line
          ..strokeWidth = 1);
    y += 10 * _dpr;
    tpFooter.paint(canvas, Offset(_pad, y));
  }

  static TextPainter _tp(String text, double logicalSize, Color color,
      double dpr, String? fontFamily,
      [FontWeight weight = FontWeight.w400]) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: logicalSize * dpr,
          color: color,
          fontWeight: weight,
          height: 1.55,
          fontFamily: fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmt(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';
}

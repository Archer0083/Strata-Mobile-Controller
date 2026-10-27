import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:strata_mobile_controller/models/conversation.dart';
import 'package:strata_mobile_controller/services/export_service.dart';

/// ADR-9 决策 3 回归测试：PDF 必须内嵌打包内的 CJK 字体，否则中文变空白框。
///
/// 三条断言：
/// 1. 打包资产 assets/fonts/cjk-regular.ttf 存在且非空；
/// 2. 该字体为 glyf（TrueType）轮廓 —— pdf 包只写 glyf/loca 表，
///    CFF/OTF 字体无法被它子集化（会整份嵌入，PDF 体积暴涨）；
/// 3. 走 ExportService.buildPdf 真路径产出的 PDF 体积远小于字体体积，
///    证明子集嵌入生效。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Conversation conversation() => Conversation(
        id: 'c1',
        title: '中文导出测试会话',
        profileId: 'default',
        modelId: 'qwen3-8b',
        effort: 'medium',
        createdAt: DateTime(2026, 10, 26),
        updatedAt: DateTime(2026, 10, 26),
      );

  List<ConversationMessage> messages() => [
        ConversationMessage(
          conversationId: 'c1',
          role: 'user',
          content: '你好，请用中文回答：今天天气如何？',
          timestamp: DateTime(2026, 10, 26),
          seq: 0,
        ),
        ConversationMessage(
          conversationId: 'c1',
          role: 'assistant',
          content: '这是中文回复，测试字体是否完整覆盖汉字。',
          timestamp: DateTime(2026, 10, 26),
          seq: 1,
        ),
      ];

  test('打包内 CJK 字体存在且为 glyf 轮廓', () async {
    final bd = await rootBundle.load('assets/fonts/cjk-regular.ttf');
    expect(bd, isNotNull, reason: '打包资产 assets/fonts/cjk-regular.ttf 缺失');

    final bytes = bd.buffer.asUint8List();
    expect(bytes.length, greaterThan(1024 * 1024),
        reason: 'CJK 字体资产疑似空文件');

    // sfntVersion: 0x00010000 = TrueType(glyf)；'OTTO' = CFF。
    final sfnt = String.fromCharCodes(bytes.sublist(0, 4));
    expect(sfnt, isNot('OTTO'),
        reason: '字体仍是 CFF/OTF，pdf 包无法子集化，PDF 会整份嵌入字体');

    // 'glyf' 表目录项必须存在。
    final tableTags = <String>{};
    final numTables = bytes[4] * 256 + bytes[5];
    for (var i = 0; i < numTables; i++) {
      final off = 12 + i * 16;
      tableTags.add(String.fromCharCodes(bytes.sublist(off, off + 4)));
    }
    expect(tableTags, contains('glyf'));
    expect(tableTags, contains('loca'));
  });

  test('PDF 导出走真路径：体积远小于字体（子集嵌入生效）', () async {
    final service = ExportService();
    final pdf = await service.buildPdf(conversation(), messages());
    expect(pdf.length, greaterThan(1000));

    final bd = await rootBundle.load('assets/fonts/cjk-regular.ttf');
    expect(bd, isNotNull);
    final fontBytes = bd.lengthInBytes;
    expect(pdf.length, lessThan(fontBytes ~/ 4),
        reason: 'PDF 未做字体子集嵌入（PDF $pdf 字节 vs 字体 $fontBytes 字节）');
  });
}

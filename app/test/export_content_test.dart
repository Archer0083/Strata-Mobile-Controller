// 四格式导出内容快照测试（M1-12.7，SPEC v0.3.5 §9 导出 .json schema 定稿 /
// §5.3 四格式导出）：
// Markdown / JSON / HTML / PDF 各自产物的内容断言（不是 UI 接线——那在
// export_sheet_test.dart；PDF 字体子集回归在 cjk_font_check_test.dart）。
//
// 覆盖：
// - Markdown：标题/元信息/说话人「我·模型」/思考链引用块/错误行/用量行
// - JSON：SPEC §9 schema —— role 字符串枚举、timestamp ISO 8601、
//   usage snake_case、可选字段（reasoning/usage/error）null 时写 null
// - HTML：DOCTYPE + zh-CN + utf-8、<>& 实体转义、user/ai 分节、
//   details 思考链、error/usage 行、页脚链接
// - PDF：%PDF 头 + %%EOF 尾 + 非空（内容层；字体层见 cjk_font_check_test）
// - 文件名：中文标题清洗非法字符

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:strata_mobile_controller/models/conversation.dart';
import 'package:strata_mobile_controller/models/strata_models.dart' show ChatUsage;
import 'package:strata_mobile_controller/services/export_service.dart';

void main() {
  // buildPdf 走 rootBundle 读字体资产，需要初始化 binding
  TestWidgetsFlutterBinding.ensureInitialized();

  final conversation = Conversation(
    id: 'c1',
    title: '中文会话 <测试> & 快照',
    profileId: 'p1',
    modelId: 'qwen3-8b',
    effort: 'high',
    createdAt: DateTime(2026, 10, 26, 9, 30),
    updatedAt: DateTime(2026, 10, 26, 10),
  );

  final messages = [
    ConversationMessage(
      conversationId: 'c1',
      role: 'user',
      content: '你好，第一问',
      timestamp: DateTime(2026, 10, 26, 9, 30, 5),
      seq: 0,
    ),
    ConversationMessage(
      conversationId: 'c1',
      role: 'assistant',
      content: '中文回复正文',
      reasoning: '思考第一行\n思考第二行',
      usage: const ChatUsage(promptTokens: 12, completionTokens: 34, totalTokens: 46),
      error: null,
      timestamp: DateTime(2026, 10, 26, 9, 30, 10),
      seq: 1,
    ),
    ConversationMessage(
      conversationId: 'c1',
      role: 'assistant',
      content: '',
      error: '连接中断',
      timestamp: DateTime(2026, 10, 26, 9, 31),
      seq: 2,
    ),
  ];

  const profileMeta =
      ExportProfileMeta(name: '客厅主机', host: '10.0.0.2', port: 8080);

  group('buildMarkdown（Markdown 快照）', () {
    final md = ExportService().buildMarkdown(
      conversation,
      messages,
      profileMeta: profileMeta,
    );

    test('标题与元信息', () {
      expect(md, startsWith('# 中文会话 <测试> & 快照'));
      expect(md, contains('- 主机：客厅主机（10.0.0.2:8080）'));
      expect(md, contains('- 模型：qwen3-8b'));
      expect(md, contains('- 思考档位：high'));
      expect(md, contains('- 创建时间：'));
    });

    test('说话人标签与正文', () {
      expect(md, contains('## 我 · '));
      expect(md, contains('## 模型 · '));
      expect(md, contains('你好，第一问'));
      expect(md, contains('中文回复正文'));
    });

    test('思考链引用块（多行逐行引用）', () {
      expect(md, contains('**思考过程**'));
      expect(md, contains('> 思考第一行'));
      expect(md, contains('> 思考第二行'));
    });

    test('错误行与用量行', () {
      expect(md, contains('*（错误：连接中断）*'));
      expect(md, contains('*（用量：46 tokens：prompt 12 / completion 34）*'));
    });
  });

  group('buildJson（JSON 快照，SPEC §9）', () {
    final json =
        ExportService().buildJson(conversation, messages, profileMeta: profileMeta);
    final decoded = jsonDecode(json) as Map<String, dynamic>;

    test('顶层：schema_version / exported_at / app / conversation', () {
      expect(decoded['schema_version'], 1);
      expect(decoded['app'], 'mobile_llm_controller');
      expect(decoded['exported_at'], isA<String>());
      expect(decoded['conversation'], isA<Map>());
    });

    test('会话字段：snake_case 与可选 profile', () {
      final conv = decoded['conversation'] as Map<String, dynamic>;
      expect(conv['title'], '中文会话 <测试> & 快照');
      expect(conv['model'], 'qwen3-8b');
      expect(conv['effort'], 'high');
      expect(conv['created_at'], isA<String>());
      expect((conv['profile'] as Map)['host'], '10.0.0.2');
    });

    test('消息字段：role 字符串枚举 + timestamp ISO 8601 + usage snake_case',
        () {
      final conv = decoded['conversation'] as Map<String, dynamic>;
      final msgs = conv['messages'] as List;
      expect(msgs.length, 3);
      expect(msgs[0]['role'], 'user');
      expect(msgs[0]['timestamp'],
          startsWith('2026-10-26T09:30:05')); // ISO 8601，含 T
      final usage = msgs[1]['usage'] as Map<String, dynamic>;
      expect(usage['prompt_tokens'], 12);
      expect(usage['completion_tokens'], 34);
      expect(usage['total_tokens'], 46);
    });

    test('可选字段缺失时显式写 null（而非省略键）', () {
      final conv = decoded['conversation'] as Map<String, dynamic>;
      final msgs = conv['messages'] as List;
      expect(msgs[0]['reasoning'], isNull);
      expect(msgs[0]['usage'], isNull);
      expect(msgs[0]['error'], isNull);
      expect(msgs[2]['error'], '连接中断');
    });

    test('闭环：buildJson 产物可被 ImportService.parse 原样回导', () {
      // 见 import_flow_test.dart 的解析组；此处只锁 schema 形状：
      // conversation 对象里必须有 parse 依赖的 title/messages 键
      final conv = decoded['conversation'] as Map<String, dynamic>;
      expect(conv.containsKey('title'), isTrue);
      expect(conv.containsKey('messages'), isTrue);
    });
  });

  group('buildHtml（HTML 快照）', () {
    final html = ExportService().buildHtml(
      conversation,
      messages,
      profileMeta: profileMeta,
    );

    test('文档骨架：DOCTYPE + zh-CN + utf-8', () {
      expect(html, startsWith('<!DOCTYPE html>'));
      expect(html, contains('<html lang="zh-CN">'));
      expect(html, contains('<meta charset="utf-8">'));
      expect(html, contains('</body></html>'));
    });

    test('实体转义：标题中的 < > & 不裸入 HTML', () {
      expect(html, contains('&lt;测试&gt;'));
      expect(html, contains('&amp;'));
      expect(html, isNot(contains('<测试>')));
    });

    test('分节与角色 class：user / ai', () {
      expect(html, contains('<section class="msg user">'));
      expect(html, contains('<section class="msg ai">'));
      expect(html, contains('我 · '));
      expect(html, contains('模型 · '));
    });

    test('思考链折叠 + 错误行 + 用量行 + 页脚', () {
      expect(html, contains('<details class="thinking">'));
      expect(html, contains('<div class="error">错误：连接中断</div>'));
      expect(html, contains('<div class="usage">46 tokens'));
      expect(html, contains('非官方第三方工具'));
    });
  });

  group('buildPdf（PDF 快照）', () {
    test('PDF 头尾标记 + 非空（字体子集回归另见 cjk_font_check_test）',
        () async {
      final pdf = await ExportService().buildPdf(
        conversation,
        messages,
        profileMeta: profileMeta,
      );
      final head = String.fromCharCodes(pdf.sublist(0, 5));
      expect(head, startsWith('%PDF-'));
      final tail = String.fromCharCodes(pdf.sublist(pdf.length - 32));
      expect(tail.contains('%%EOF'), isTrue);
      expect(pdf.length, greaterThan(1000));
    });
  });

  group('文件名生成', () {
    test('中文标题保留、非法字符清洗', () async {
      final result = await ExportService().export(
        conversation: conversation,
        messages: messages,
        format: ExportFormat.markdown,
        profileMeta: profileMeta,
      );
      // < > 被替换为 _；& 与空格是合法字符（空白仅折叠不删除）
      expect(result.fileName, startsWith('Strata会话-中文会话 _测试_ & 快照-'));
      expect(result.fileName, endsWith('.md'));
      // 不含路径非法字符
      for (final ch in r'\/:*?"<>|'.split('')) {
        expect(result.fileName, isNot(contains(ch)));
      }
    });

    test('四格式扩展名与 mimeType', () async {
      for (final format in ExportFormat.values) {
        final result = await ExportService().export(
          conversation: conversation,
          messages: messages,
          format: format,
        );
        expect(result.fileName, endsWith('.${format.fileExtension}'));
        expect(result.mimeType, format.mimeType);
      }
    });
  });
}

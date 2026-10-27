// 会话数据管理测试（M1-12.6，SPEC v0.3.5 §10「会话数据管理」）：
// 「导出全部会话」打包格式 + 打包解析容错 + 设置页四个入口接线。
//
// 覆盖：
// - 打包导出：顶层 conversations 数组 / schema_version / 会话与消息字段完整
// - 打包导出 → 打包解析：闭环（导出产物可原样回导）
// - 打包解析容错：单个会话坏数据跳过计数 / 全部会话非法拒绝 / 缺 conversations 拒绝
// - 设置页：占用统计 / 导出全部 / 导入整包 / 清空全部（二次确认）
//
// 测试环境约定（沿用 import_flow_test.dart）：
// - 文件选择器注入假的 picker（直接喂字节），不拉起系统面板
// - repository 用同步内存实现（不碰 sqflite isolate，避免 FakeAsync 死锁）

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show Database;
import 'package:strata_mobile_controller/models/conversation.dart';
import 'package:strata_mobile_controller/providers/chat_provider.dart';
import 'package:strata_mobile_controller/screens/session_data_section.dart';
import 'package:strata_mobile_controller/services/conversation_repository.dart';
import 'package:strata_mobile_controller/services/export_service.dart';
import 'package:strata_mobile_controller/services/import_service.dart';

/// 同步内存仓库：只覆写走 sqflite 的方法，避免 isolate 回包与 FakeAsync 死锁。
class _MemoryRepository extends ConversationRepository {
  _MemoryRepository() : super(Completer<Database>().future);

  final List<Conversation> conversations = [];
  final List<ConversationMessage> messages = [];

  int deleteAllCalls = 0;

  @override
  Future<Conversation> createConversation(Conversation c) async {
    conversations.add(c);
    return c;
  }

  @override
  Future<ConversationMessage> insertMessage(ConversationMessage m) async {
    messages.add(m);
    return m;
  }

  @override
  Future<List<ConversationMessage>> loadMessages(String conversationId) async =>
      messages.where((m) => m.conversationId == conversationId).toList();

  @override
  Future<List<Conversation>> listConversations() async => conversations;

  @override
  Future<int> countConversations() async => conversations.length;

  @override
  Future<int> countMessages() async => messages.length;

  @override
  Future<int> estimateSizeBytes() async => 2048;

  @override
  Future<void> deleteAll() async {
    deleteAllCalls++;
    conversations.clear();
    messages.clear();
  }
}

/// 构造导入服务：picker 返回给定字节（null = 用户取消）。
ImportService _serviceReturning(List<int>? bytes) => ImportService(
      picker: ({
        String? dialogTitle,
        List<String>? allowedExtensions,
        bool withData = false,
      }) async =>
          bytes == null ? null : _pickResult(bytes),
    );

FilePickerResult _pickResult(List<int> bytes) => FilePickerResult([
      PlatformFile(
        name: 'bundle.json',
        size: bytes.length,
        bytes: Uint8List.fromList(bytes),
      ),
    ]);

Conversation _conversation(String id, String title) => Conversation(
      id: id,
      title: title,
      profileId: 'p1',
      modelId: 'qwen3-8b',
      effort: 'medium',
      createdAt: DateTime(2026, 10, 20, 9),
      updatedAt: DateTime(2026, 10, 21, 10),
      pinned: false,
    );

ConversationMessage _message(String cid, int seq, String role, String content) =>
    ConversationMessage(
      conversationId: cid,
      role: role,
      content: content,
      timestamp: DateTime(2026, 10, 20, 9, 0, seq),
      seq: seq,
    );

/// 两个会话 + 消息的导出打包产物（json 文本）
String _bundleJson() {
  final service = ExportService();
  final conversations = [
    _conversation('c1', '第一个会话'),
    _conversation('c2', '第二个会话'),
  ];
  return service.buildJsonBundle(
    conversations,
    {
      'c1': [
        _message('c1', 0, 'user', '你好'),
        _message('c1', 1, 'assistant', '在的'),
      ],
      'c2': [_message('c2', 0, 'user', '第二个问题')],
    },
    profileMetaById: const {
      'p1': ExportProfileMeta(name: '客厅主机', host: '10.0.0.2', port: 8080),
    },
  );
}

void main() {
  group('ExportService.buildJsonBundle（打包导出）', () {
    test('顶层结构：schema_version / app / conversations 数组', () {
      final decoded = jsonDecode(_bundleJson()) as Map<String, dynamic>;
      expect(decoded['schema_version'], 1);
      expect(decoded['app'], 'mobile_llm_controller');
      expect(decoded['exported_at'], isNotNull);
      expect(decoded['conversations'], isA<List>());
      expect((decoded['conversations'] as List).length, 2);
    });

    test('会话对象：字段与单会话导出同构（含 profile 元信息）', () {
      final decoded = jsonDecode(_bundleJson()) as Map<String, dynamic>;
      final first = (decoded['conversations'] as List).first as Map<String, dynamic>;
      expect(first['id'], 'c1');
      expect(first['title'], '第一个会话');
      expect(first['model'], 'qwen3-8b');
      expect(first['effort'], 'medium');
      expect(first['created_at'], isNotNull);
      expect(first['updated_at'], isNotNull);
      expect((first['profile'] as Map<String, dynamic>)['host'], '10.0.0.2');
      expect((first['messages'] as List).length, 2);
    });

    test('消息对象：seq / role / content / timestamp 完整', () {
      final decoded = jsonDecode(_bundleJson()) as Map<String, dynamic>;
      final first = (decoded['conversations'] as List).first as Map<String, dynamic>;
      final msg = (first['messages'] as List).first as Map<String, dynamic>;
      expect(msg['seq'], 0);
      expect(msg['role'], 'user');
      expect(msg['content'], '你好');
      expect(msg['timestamp'], isNotNull);
    });

    test('exportAllBundle：文件名为中文「全部会话-<时间戳>.json」', () async {
      final result = await ExportService().exportAllBundle(
        conversations: [_conversation('c1', '会话一')],
        messagesByConversation: {
          'c1': [_message('c1', 0, 'user', 'hi')]
        },
        profileMetaById: const {},
      );
      expect(result.fileName, startsWith('全部会话-'));
      expect(result.fileName, endsWith('.json'));
      expect(result.mimeType, ExportFormat.json.mimeType);
    });

    test('缺失消息的会话：仍被导出（不丢会话本身）', () async {
      final result = await ExportService().exportAllBundle(
        conversations: [_conversation('c1', '空会话')],
        messagesByConversation: const {},
        profileMetaById: const {},
      );
      final decoded = jsonDecode(utf8.decode(result.bytes)) as Map<String, dynamic>;
      final first = (decoded['conversations'] as List).first as Map<String, dynamic>;
      expect((first['messages'] as List), isEmpty);
    });
  });

  group('ImportService.parseBundle（打包解析与容错）', () {
    test('闭环：打包产物可原样回导（2 会话 3 条消息）', () {
      final bundle = _serviceReturning(null).parseBundle(_bundleJson());
      expect(bundle.conversations.length, 2);
      expect(bundle.totalMessages, 3);
      expect(bundle.skippedCount, 0);
      expect(bundle.conversations.first.title, '第一个会话');
      expect(bundle.conversations.first.messages.length, 2);
      expect(bundle.exportedAt, isNotNull);
    });

    test('单个会话结构非法：跳过该会话并计数，其余照常导入', () {
      final src = jsonEncode({
        'schema_version': 1,
        'exported_at': '2026-10-26T10:30:00.000',
        'conversations': [
          {
            'title': '好的会话',
            'messages': [
              {'role': 'user', 'content': 'ok'}
            ],
          },
          {
            'title': '坏会话',
            'messages': [
              {'role': 'user'} // 缺 content → 全部消息无效 → 该会话无效
            ],
          },
        ],
      });
      final bundle = _serviceReturning(null).parseBundle(src);
      expect(bundle.conversations.length, 1);
      expect(bundle.conversations.first.title, '好的会话');
      expect(bundle.skippedCount, 1);
    });

    test('元素不是对象：跳过并计数', () {
      final src = jsonEncode({
        'schema_version': 1,
        'conversations': [
          '不是对象',
          {
            'title': '好的会话',
            'messages': [
              {'role': 'user', 'content': 'ok'}
            ],
          },
        ],
      });
      final bundle = _serviceReturning(null).parseBundle(src);
      expect(bundle.conversations.length, 1);
      expect(bundle.skippedCount, 1);
    });

    test('全部会话都非法：拒绝导入', () {
      final src = jsonEncode({
        'schema_version': 1,
        'conversations': [
          {'title': '坏会话', 'messages': []},
        ],
      });
      expect(
        () => _serviceReturning(null).parseBundle(src),
        throwsA(isA<ImportException>()),
      );
    });

    test('拒绝：缺 conversations 字段（是单会话文件而非会话包）', () {
      final src = jsonEncode({
        'schema_version': 1,
        'conversation': {
          'title': '单会话',
          'messages': [
            {'role': 'user', 'content': 'x'}
          ],
        },
      });
      expect(
        () => _serviceReturning(null).parseBundle(src),
        throwsA(isA<ImportException>()),
      );
    });

    test('拒绝：schema_version 超前', () {
      final src = jsonEncode({
        'schema_version': 99,
        'conversations': [],
      });
      expect(
        () => _serviceReturning(null).parseBundle(src),
        throwsA(isA<ImportException>()),
      );
    });

    test('拒绝：JSON 非法', () {
      expect(
        () => _serviceReturning(null).parseBundle('{ 不是 json'),
        throwsA(isA<ImportException>()),
      );
    });
  });

  group('设置页「会话数据」区块', () {
    testWidgets('占用统计：显示会话数 / 消息数 / 占用', (tester) async {
      final repo = _MemoryRepository();
      await _pumpSettings(tester, repo);

      expect(find.byKey(const Key('session_usage_info')), findsOneWidget);
      expect(find.text('本地会话占用'), findsOneWidget);
      expect(find.text('0 个会话 · 0 条消息 · 占用 2 KB'), findsOneWidget);
    });

    testWidgets('三个操作入口可见', (tester) async {
      final repo = _MemoryRepository();
      await _pumpSettings(tester, repo);

      expect(find.byKey(const Key('btn_export_all')), findsOneWidget);
      expect(find.byKey(const Key('btn_import_all')), findsOneWidget);
      expect(find.byKey(const Key('btn_clear_all')), findsOneWidget);
      expect(find.text('导出全部会话'), findsOneWidget);
      expect(find.text('导入会话'), findsOneWidget);
      expect(find.text('清空全部会话'), findsOneWidget);
    });

    testWidgets('导入整包：预览 → 确认 → 入库 + toast', (tester) async {
      final repo = _MemoryRepository();
      await _pumpSettings(
        tester,
        repo,
        importBytes: utf8.encode(_bundleJson()),
      );

      await tester.tap(find.byKey(const Key('btn_import_all')));
      await tester.pumpAndSettle();

      // 预览框：多会话变体（摘要行末尾还带「导出时间」段，故用包含匹配）
      expect(find.byKey(const Key('import_preview_dialog')), findsOneWidget);
      expect(find.textContaining('识别到 2 个会话 · 3 条消息'), findsOneWidget);

      await tester.tap(find.byKey(const Key('import_preview_confirm')));
      await tester.pumpAndSettle();

      expect(repo.conversations.length, 2);
      expect(repo.messages.length, 3);
      expect(find.textContaining('已导入 2 个会话'), findsOneWidget);
    });

    testWidgets('导入整包：取消预览 → 不入库', (tester) async {
      final repo = _MemoryRepository();
      await _pumpSettings(
        tester,
        repo,
        importBytes: utf8.encode(_bundleJson()),
      );

      await tester.tap(find.byKey(const Key('btn_import_all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('import_preview_cancel')));
      await tester.pumpAndSettle();

      expect(repo.conversations, isEmpty);
    });

    testWidgets('导入整包：用户取消选文件 → 不弹预览、不入库', (tester) async {
      final repo = _MemoryRepository();
      await _pumpSettings(tester, repo, importBytes: null);

      await tester.tap(find.byKey(const Key('btn_import_all')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('import_preview_dialog')), findsNothing);
      expect(repo.conversations, isEmpty);
    });

    testWidgets('清空全部：二次确认 → 取消则不清库', (tester) async {
      final repo = _MemoryRepository();
      repo.conversations.add(_conversation('c1', '保留'));
      await _pumpSettings(tester, repo);

      await tester.tap(find.byKey(const Key('btn_clear_all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('clear_all_dialog')), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn_cancel_clear_all')));
      await tester.pumpAndSettle();

      expect(repo.deleteAllCalls, 0);
      expect(repo.conversations.length, 1);
    });

    testWidgets('清空全部：二次确认 → 确认则清库 + toast', (tester) async {
      final repo = _MemoryRepository();
      repo.conversations.add(_conversation('c1', '待清空'));
      repo.messages.add(_message('c1', 0, 'user', 'x'));
      await _pumpSettings(tester, repo);

      await tester.tap(find.byKey(const Key('btn_clear_all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_confirm_clear_all')));
      await tester.pumpAndSettle();

      expect(repo.deleteAllCalls, 1);
      expect(repo.conversations, isEmpty);
      expect(repo.messages, isEmpty);
      expect(find.textContaining('已清空全部会话'), findsOneWidget);
    });
  });
}

/// 挂载设置页（注入内存仓库与假 picker）
Future<void> _pumpSettings(
  WidgetTester tester,
  _MemoryRepository repo, {
  List<int>? importBytes,
}) async {
  final container = ProviderContainer(overrides: [
    conversationRepositoryProvider.overrideWithValue(repo),
    importServiceProvider.overrideWithValue(_serviceReturning(importBytes)),
  ]);
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: _SettingsHost()),
  ));
  await tester.pumpAndSettle();
}

/// 设置页宿主：只渲染「会话数据」区块（避开 Profile 加载与 secure_storage 依赖）
class _SettingsHost extends StatelessWidget {
  const _SettingsHost();

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: SingleChildScrollView(child: SessionDataSection()),
      );
}

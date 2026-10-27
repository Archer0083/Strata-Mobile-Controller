// 导入链路测试（M1-12.5，SPEC v0.3.5 §5.3 / docs/ui-design-spec.md §3.8）：
// .json 导入的容错解析 + 预览确认 UI + 抽屉入口接线。
//
// 覆盖：
// - 解析：正常文件 → 标题/消息数/导出时间；容错（缺字段跳过、非法消息计数）
// - 解析拒绝：JSON 非法 / schema_version 超前 / 顶层结构缺失 / 有效消息为 0
// - 预览对话框：摘要行「识别到 1 个会话 · N 条消息 · 导出时间 YYYY-MM-DD」
// - 预览对话框：跳过条数提示 + 「导入」/「取消」两按钮
// - 抽屉入口：点击「导入会话（.json）」→ 预览框 → 确认 → toast「已导入 1 个会话」
//
// 测试环境约定：
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
import 'package:strata_mobile_controller/screens/conversation_drawer.dart';
import 'package:strata_mobile_controller/screens/import_preview_dialog.dart';
import 'package:strata_mobile_controller/services/conversation_repository.dart';
import 'package:strata_mobile_controller/services/import_service.dart';

/// 同步内存仓库：createConversation / insertMessage 落到内存列表。
/// 覆写掉所有走 sqflite 的方法，避免 isolate 回包与 FakeAsync 死锁。
class _MemoryRepository extends ConversationRepository {
  _MemoryRepository() : super(Completer<Database>().future);

  final List<Conversation> conversations = [];
  final List<ConversationMessage> messages = [];

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
}

/// 构造一个假的 FilePickerResult（注入 bytes，绕过 SAF 路径）。
FilePickerResult _pickResult(List<int> bytes) => FilePickerResult([
      PlatformFile(
        name: 'session.json',
        size: bytes.length,
        bytes: Uint8List.fromList(bytes),
      ),
    ]);

/// 构造导入服务：picker 返回给定字节（null = 用户取消）。
ImportService _serviceReturning(List<int>? bytes) => ImportService(
      picker: ({
        String? dialogTitle,
        List<String>? allowedExtensions,
        bool withData = false,
      }) async =>
          bytes == null ? null : _pickResult(bytes),
    );

/// 正常导出文件（含 exported_at / profile / usage）
String _validJson() => jsonEncode({
      'schema_version': 1,
      'exported_at': '2026-10-26T10:30:00.000',
      'app': 'strata_mobile_controller',
      'conversation': {
        'id': 'orig-c1',
        'title': '被导入的会话',
        'profile': {'name': '客厅主机', 'host': '10.0.0.2', 'port': 8080},
        'model': 'qwen3-8b',
        'effort': 'high',
        'created_at': '2026-10-20T09:00:00.000',
        'messages': [
          {
            'seq': 0,
            'role': 'user',
            'content': '第一条中文消息',
            'reasoning': null,
            'usage': null,
            'timestamp': '2026-10-20T09:00:01.000',
            'error': null,
          },
          {
            'seq': 1,
            'role': 'assistant',
            'content': '第二条中文回复',
            'reasoning': '思考链',
            'usage': {
              'prompt_tokens': 12,
              'completion_tokens': 34,
              'total_tokens': 46,
            },
            'timestamp': '2026-10-20T09:00:02.000',
            'error': null,
          },
        ],
      },
    });

void main() {
  group('ImportService.parse（容错解析）', () {
    test('正常文件：解析出标题、消息、导出时间', () {
      final parsed = _serviceReturning(null).parse(_validJson());
      expect(parsed.title, '被导入的会话');
      expect(parsed.messages.length, 2);
      expect(parsed.skippedCount, 0);
      expect(parsed.modelId, 'qwen3-8b');
      expect(parsed.effort, 'high');
      expect(parsed.exportedAt, isNotNull);
      expect(parsed.exportedAt!.toIso8601String(),
          startsWith('2026-10-26T10:30:00'));
    });

    test('缺少 exported_at：exportedAt 为 null（预览隐藏该段）', () {
      final src = jsonEncode({
        'schema_version': 1,
        'conversation': {
          'title': '无导出时间',
          'messages': [
            {'role': 'user', 'content': 'hi'}
          ],
        },
      });
      final parsed = _serviceReturning(null).parse(src);
      expect(parsed.exportedAt, isNull);
      expect(parsed.messages.length, 1);
    });

    test('单条消息缺 role/content：跳过并计数', () {
      final src = jsonEncode({
        'schema_version': 1,
        'conversation': {
          'title': '部分损坏',
          'messages': [
            {'role': 'user', 'content': '好的'},
            {'role': 'user'}, // 缺 content
            {'content': '缺 role'}, // 缺 role
            '不是对象',
            {'role': 'system', 'content': '非法角色'},
            {'role': 'assistant', 'content': '也好'},
          ],
        },
      });
      final parsed = _serviceReturning(null).parse(src);
      expect(parsed.messages.length, 2);
      expect(parsed.skippedCount, 4);
    });

    test('单条消息可选字段缺失：容忍并填默认值', () {
      final src = jsonEncode({
        'schema_version': 1,
        'conversation': {
          'title': '最小字段',
          'messages': [
            {'role': 'user', 'content': '只有必填字段'}
          ],
        },
      });
      final parsed = _serviceReturning(null).parse(src);
      expect(parsed.messages.length, 1);
      expect(parsed.messages.first.reasoning, isNull);
      expect(parsed.messages.first.usage, isNull);
      expect(parsed.messages.first.error, isNull);
      expect(parsed.messages.first.timestamp, isNotNull);
    });

    test('拒绝：JSON 非法', () {
      expect(
        () => _serviceReturning(null).parse('{ 这不是 json'),
        throwsA(isA<ImportException>()),
      );
    });

    test('拒绝：schema_version 超前', () {
      final src = jsonEncode({
        'schema_version': 99,
        'conversation': {'messages': [{'role': 'user', 'content': 'x'}]},
      });
      expect(
        () => _serviceReturning(null).parse(src),
        throwsA(isA<ImportException>()),
      );
    });

    test('拒绝：缺 conversation 字段', () {
      final src = jsonEncode({'schema_version': 1, 'messages': []});
      expect(
        () => _serviceReturning(null).parse(src),
        throwsA(isA<ImportException>()),
      );
    });

    test('拒绝：有效消息为 0', () {
      final src = jsonEncode({
        'schema_version': 1,
        'conversation': {'messages': [{'role': 'user'}]},
      });
      expect(
        () => _serviceReturning(null).parse(src),
        throwsA(isA<ImportException>()),
      );
    });
  });

  group('ImportPreviewDialog（预览确认）', () {
    Future<ParsedConversation> parsedFixture() async =>
        _serviceReturning(null).parse(_validJson());

    testWidgets('摘要行：识别到 1 个会话 · N 条消息 · 导出时间', (tester) async {
      final parsed = await parsedFixture();
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) => TextButton(
              onPressed: () => showImportPreviewDialog(context, parsed),
              child: const Text('open'),
            )),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('import_preview_dialog')), findsOneWidget);
      expect(find.text('被导入的会话'), findsOneWidget);
      expect(find.text('识别到 1 个会话 · 2 条消息 · 导出时间 2026-10-26'),
          findsOneWidget);
      expect(find.byKey(const Key('import_preview_confirm')), findsOneWidget);
      expect(find.byKey(const Key('import_preview_cancel')), findsOneWidget);
    });

    testWidgets('取消：返回 false 且不入库', (tester) async {
      final parsed = await parsedFixture();
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) => TextButton(
              onPressed: () async {
                result = await showImportPreviewDialog(context, parsed);
              },
              child: const Text('open'),
            )),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('import_preview_cancel')));
      await tester.pumpAndSettle();

      expect(result, isFalse);
      expect(find.byKey(const Key('import_preview_dialog')), findsNothing);
    });

    testWidgets('确认：返回 true', (tester) async {
      final parsed = await parsedFixture();
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) => TextButton(
              onPressed: () async {
                result = await showImportPreviewDialog(context, parsed);
              },
              child: const Text('open'),
            )),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('import_preview_confirm')));
      await tester.pumpAndSettle();

      expect(result, isTrue);
    });

    testWidgets('跳过条数：额外提示一行', (tester) async {
      final parsed = _serviceReturning(null).parse(jsonEncode({
        'schema_version': 1,
        'conversation': {
          'title': '部分损坏',
          'messages': [
            {'role': 'user', 'content': '好的'},
            {'role': 'user'},
          ],
        },
      }));
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) => TextButton(
              onPressed: () => showImportPreviewDialog(context, parsed),
              child: const Text('open'),
            )),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 条消息格式异常'), findsOneWidget);
    });
  });

  group('抽屉导入入口', () {
    testWidgets('点「导入会话（.json）」→ 预览 → 确认 → toast', (tester) async {
      final repo = _MemoryRepository();
      final container = ProviderContainer(overrides: [
        conversationRepositoryProvider.overrideWithValue(repo),
        importServiceProvider
            .overrideWithValue(_serviceReturning(utf8.encode(_validJson()))),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: _DrawerHost()),
      ));
      await tester.pumpAndSettle();

      // 抽屉初始收起，先拉出（点 Scaffold 的自动抽屉按钮）
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('drawer_import')));
      await tester.pumpAndSettle();

      // 预览框出现
      expect(find.byKey(const Key('import_preview_dialog')), findsOneWidget);
      expect(find.text('识别到 1 个会话 · 2 条消息 · 导出时间 2026-10-26'),
          findsOneWidget);

      await tester.tap(find.byKey(const Key('import_preview_confirm')));
      await tester.pumpAndSettle();

      // 入库：新会话 + 2 条消息
      expect(repo.conversations.length, 1);
      expect(repo.messages.length, 2);
      // toast
      expect(find.textContaining('已导入 1 个会话'), findsOneWidget);
    });

    testWidgets('用户取消选文件：不弹预览、不入库', (tester) async {
      final repo = _MemoryRepository();
      final container = ProviderContainer(overrides: [
        conversationRepositoryProvider.overrideWithValue(repo),
        // null = 用户在文件选择器点了取消
        importServiceProvider.overrideWithValue(_serviceReturning(null)),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: _DrawerHost()),
      ));
      await tester.pumpAndSettle();

      // 抽屉初始收起，先拉出
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('drawer_import')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('import_preview_dialog')), findsNothing);
      expect(repo.conversations, isEmpty);
    });
  });
}

/// 抽屉宿主页面（抽屉内容需要 Scaffold 才有 Overlay）。
class _DrawerHost extends StatelessWidget {
  const _DrawerHost();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Strata')),
        body: const Center(child: Text('body')),
        drawer: const ConversationDrawer(),
      );
}

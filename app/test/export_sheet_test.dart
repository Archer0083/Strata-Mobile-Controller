// ExportSheet 测试（M1-12.4，docs/ui-design-spec.md §3.8）：
// 格式选择弹层的 UI 契约 + 导出链路。
//
// 覆盖：
// - 四格式行齐备（.md/.json/.html/.pdf），各自带用途说明
// - .json 行带「可回导」胶囊，其余三项带「仅导出」
// - 底部主按钮「分享 / 保存到文件」
// - 导出成功 → 弹层关闭 + toast「已导出 Markdown（…）」
// - 导出失败 → 弹层保持打开 + 层内错误文案（可换格式重试）
//
// 测试环境约定：
// - repository 走 FFI 内存库（真实 ConversationRepository + 真实建表 SQL）
// - path_provider / share_plus 用平台通道桩拦截，不落真实文件、不拉起系统面板

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show Database;
import 'package:strata_mobile_controller/models/connection_profile.dart';
import 'package:strata_mobile_controller/models/conversation.dart';
import 'package:strata_mobile_controller/providers/chat_provider.dart';
import 'package:strata_mobile_controller/providers/connection_provider.dart';
import 'package:strata_mobile_controller/screens/export_sheet.dart';
import 'package:strata_mobile_controller/services/conversation_repository.dart';

/// 同步内存仓库：loadMessages 直接返回预置消息，不触碰 sqflite isolate。
class _StaticRepository extends ConversationRepository {
  _StaticRepository(this.messages)
      // 构造签名要求一个 Database future；本仓库所有用到的方法都被覆写，
      // 永不被求值，故传一个永不完成的 Future（避免触发 sqflite 打开）。
      : super(Completer<Database>().future);

  final List<ConversationMessage> messages;

  @override
  Future<List<ConversationMessage>> loadMessages(String conversationId) async =>
      messages;
}

final _messages = [
  ConversationMessage(
    conversationId: 'c1',
    role: 'user',
    content: '你好，请用中文回答。',
    timestamp: DateTime(2026, 10, 26),
    seq: 0,
  ),
  ConversationMessage(
    conversationId: 'c1',
    role: 'assistant',
    content: '这是中文回复。',
    timestamp: DateTime(2026, 10, 26),
    seq: 1,
  ),
];

final _conversation = Conversation(
  id: 'c1',
  title: '中文导出测试会话',
  profileId: 'p1',
  modelId: 'qwen3-8b',
  effort: 'medium',
  createdAt: DateTime(2026, 10, 26),
  updatedAt: DateTime(2026, 10, 26),
);

/// 拦截 path_provider 的临时目录查询（测试环境无插件实现）。
void _mockPathProvider() {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'getTemporaryDirectory':
      case 'getApplicationDocumentsDirectory':
      case 'getApplicationSupportDirectory':
        return Directory.systemTemp.path;
      case 'getApplicationCacheDirectory':
        return Directory.systemTemp.createTempSync('strata_test').path;
      default:
        return null;
    }
  });
}

/// 拦截 share_plus 的分享调用（平台通道桩），避免拉起系统面板。
void _mockSharePlus() {
  const channel = MethodChannel('dev.fluttercommunity.plus/share');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => null);
}

/// 触发导出的宿主页面（ConsumerWidget 内拿 ref 调 showExportFormatSheet）。
class _Host extends ConsumerWidget {
  const _Host();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        body: TextButton(
          onPressed: () =>
              showExportFormatSheet(context, ref, _conversation),
          child: const Text('open'),
        ),
      );
}

void main() {
  setUpAll(() async {
    _mockPathProvider();
    _mockSharePlus();
  });

  // 说明：这里刻意用「同步内存仓库」而非真实 sqflite FFI 库。
  // 原因：widget 的 _share() 由按钮点击在 testWidgets 的假时钟区内启动，
  // 其 await 续体只能在 pump 推进假时钟时执行；而 sqflite FFI isolate 的
  // 回包要靠真实事件循环投递，两者叠加会让测试卡在 _exporting=true。
  // DB 读写路径已由 chat_screen_test / cjk_font_check_test 覆盖，
  // 此处专注「导出 Sheet 的 UI 契约 + 导出链路装配」。
  final repo = _StaticRepository(_messages);

  Widget app(ProviderContainer container) => UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: _Host()),
      );

  Future<ProviderContainer> boot({ConversationRepository? override}) async {
    final container = ProviderContainer(overrides: [
      conversationRepositoryProvider.overrideWithValue(override ?? repo),
      profilesProvider.overrideWith((ref) async => [
            ConnectionProfile(
              id: 'p1',
              name: '客厅主机',
              host: '10.0.0.2',
              port: 8080,
              createdAt: DateTime(2026, 1, 1),
            ),
          ]),
    ]);
    return container;
  }

  testWidgets('四格式行齐备，各带用途说明与回导胶囊', (tester) async {
    final container = await boot();
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 四个格式行
    expect(find.byKey(const Key('export_option_markdown')), findsOneWidget);
    expect(find.byKey(const Key('export_option_json')), findsOneWidget);
    expect(find.byKey(const Key('export_option_html')), findsOneWidget);
    expect(find.byKey(const Key('export_option_pdf')), findsOneWidget);

    // 格式名 + 扩展名
    expect(find.text('Markdown（.md）'), findsOneWidget);
    expect(find.text('JSON（.json）'), findsOneWidget);
    expect(find.text('HTML（.html）'), findsOneWidget);
    expect(find.text('PDF（.pdf）'), findsOneWidget);

    // 用途说明
    expect(find.text('适合存档与二次编辑'), findsOneWidget);
    expect(find.text('结构化数据，支持回导'), findsOneWidget);
    expect(find.text('单文件网页，可直接打开'), findsOneWidget);
    expect(find.text('适合打印与分享'), findsOneWidget);

    // 回导胶囊：.json 唯一「可回导」，其余「仅导出」
    expect(find.text('可回导'), findsOneWidget);
    expect(find.text('仅导出'), findsNWidgets(3));

    // 底部主按钮
    expect(find.byKey(const Key('export_share_button')), findsOneWidget);
    expect(find.text('分享 / 保存到文件'), findsOneWidget);
  });

  testWidgets('导出成功：弹层关闭 + toast 提示', (tester) async {
    final container = await boot();
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 矮屏下主按钮可能落在折叠线以下，先滚动到可见再点
    await tester.ensureVisible(find.byKey(const Key('export_share_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('export_share_button')));
    // 导出链路含 dart:io 真实文件写 + 平台通道往返，跑在真实事件循环；
    // 而 widget 的 await 续体在 testWidgets 的假时钟区，需 pump 才推进。
    // 故交替：runAsync 放真实时间让 I/O 落地，pump 推进假时钟让续体继续。
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
    }

    // sheet 已关闭
    expect(find.byKey(const Key('export_share_button')), findsNothing);
    // toast
    expect(find.textContaining('已导出 Markdown'), findsOneWidget);
  });

  testWidgets('导出失败：弹层保持打开 + 层内错误文案', (tester) async {
    // 用一个 loadMessages 必失败的仓库覆盖 provider，模拟导出链路异常
    final broken = _BrokenRepository();
    final container = await boot(override: broken);
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('export_share_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('export_share_button')));
    // 同上：runAsync 放真实时间让失败分支的异常回传完成
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('export_share_button')), findsOneWidget);
    expect(find.textContaining('导出失败'), findsOneWidget);
  });
}

/// 导出链路必失败的仓库（loadMessages 抛异常），用于验证失败分支 UI。
class _BrokenRepository extends ConversationRepository {
  _BrokenRepository() : super(Completer<Database>().future);

  @override
  Future<List<ConversationMessage>> loadMessages(String conversationId) async {
    throw StateError('模拟导出失败');
  }
}

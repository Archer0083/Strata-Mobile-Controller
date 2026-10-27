// ChatScreen 测试（M1-6）：对 Mock 真连 SSE——流式渲染、reasoning 折叠块、
// 思考档位随消息发送（none 无思考）、长 TTFT「正在思考」状态、401 分型错误。
// setUpAll 启动 Mock 双实例（8463 无鉴权 / 8464 鉴权）。
//
// 真连双保险：tester.runAsync（真实 zone）+ realHttp（摘 _MockHttpOverrides），
// 见 helpers/real_http.dart 与日志 0011。
//
// M2-6：ChatScreen 顶栏新增 imageGenEnabledProvider watch 会拉起
// monitorProvider（Dio 真连 timer），在 fake async zone 永不完成 →
// timersPending 断言挂。本文件不测生图入口，container 统一 override 关闭。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strata_mobile_controller/models/connection_profile.dart';
import 'package:strata_mobile_controller/models/strata_models.dart';
import 'package:strata_mobile_controller/providers/chat_provider.dart';
import 'package:strata_mobile_controller/providers/connection_provider.dart';
import 'package:strata_mobile_controller/screens/chat_screen.dart';
import 'package:strata_mobile_controller/screens/images_screen.dart';

import 'helpers/real_http.dart';
import 'helpers/secure_storage_mock.dart';
import 'helpers/sqflite_ffi.dart';

const _mockScript = '../server-bridge/mock/mock_strata.py';

Process? _mockFree;
Process? _mockAuth;

/// 装载 host 内存库（M1-12 写穿：send() 首次触达 DB 时初始化 repository）
Future<void> _setupDb() => setupInMemoryDatabase();

Widget _app(ProviderContainer container, {ConnectionProfile? profile}) {
  if (profile != null) {
    container.read(currentProfileProvider.notifier).state = profile;
  }
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: ChatScreen()),
  );
}

ConnectionProfile _profile(int port) => ConnectionProfile(
      id: 'test-$port',
      name: '测试主机',
      host: '127.0.0.1',
      port: port,
      createdAt: DateTime.now(),
    );

/// 生图入口对 monitorProvider 的拉起会被 override 拦截（见文件头注释）
ProviderContainer _container() => ProviderContainer(overrides: [
      imageGenEnabledProvider.overrideWith((ref) => false),
    ]);

/// 轮询等待流式结束（phase 回到 idle）
Future<void> _waitIdle(ProviderContainer c, {Duration timeout = const Duration(seconds: 30)}) async {
  final sw = Stopwatch()..start();
  while (c.read(chatControllerProvider).phase != ChatSendPhase.idle) {
    if (sw.elapsed > timeout) fail('等待流式完成超时');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(mockSecureStorage);

  // M1-12 写穿：先装 host 内存库，再起 Mock 服务
  setUpAll(() async {
    await _setupDb();
  });

  setUpAll(() async {
    expect(File(_mockScript).existsSync(), isTrue, reason: '找不到 Mock 脚本（M1-3 产物）');
    _mockFree = await Process.start('python', [_mockScript, '--port', '8463']);
    _mockAuth = await Process.start('python', [_mockScript, '--port', '8464', '--api-key', 'sk-test-123']);
    for (final p in [_mockFree!, _mockAuth!]) {
      p.stdout.transform(systemEncoding.decoder).listen((_) {}); // 静默消费防缓冲阻塞
      p.stderr.transform(systemEncoding.decoder).listen((_) {});
    }
    for (final url in ['http://127.0.0.1:8463', 'http://127.0.0.1:8464']) {
      await realHttp(() async {
        final uri = Uri.parse('$url/health');
        for (var i = 0; i < 50; i++) {
          try {
            final resp = await HttpClient().getUrl(uri).then((r) => r.close());
            await resp.drain<void>();
            break;
          } on Exception {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
        }
      });
    }
  });

  tearDownAll(() async {
    _mockFree?.kill();
    _mockAuth?.kill();
    await _mockFree?.exitCode.catchError((_) => -1);
    await _mockAuth?.exitCode.catchError((_) => -1);
  });

  testWidgets('默认 medium 档：流式完成渲染正文 + reasoning 折叠块 + 「正在思考」中间态', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container, profile: _profile(8463)));

    // 默认档位 medium
    expect(container.read(chatControllerProvider).effort, ReasoningEffort.medium);

    var sawWaiting = false;
    await tester.runAsync(() => realHttp(() async {
          container.read(chatControllerProvider.notifier).send('你好，介绍下自己');
          // 已发出、未收到任何字节：长 TTFT「正在思考」阶段（Mock medium 档 TTFT 数秒）
          if (container.read(chatControllerProvider).phase == ChatSendPhase.waitingFirstToken) {
            sawWaiting = true;
          }
          await _waitIdle(container);
        }));
    await tester.pump();

    final chat = container.read(chatControllerProvider);
    expect(sawWaiting, isTrue, reason: '应在收到首字节前观察到 waitingFirstToken 阶段');
    expect(chat.messages.length, 2); // 用户 1 + 助手 1
    expect(chat.messages.last.error, isNull);
    // 【v0.0.3 回归】完整拼接断言：修复前 _appendAi 每个 delta 覆盖 content，
    // 只剩最后一个 chunk（约 3 字符），isNotEmpty 弱断言无法抓出。
    // Mock 正文 = 「收到你的消息：「<用户消息>」\n本次思考档位 medium…」整段。
    expect(chat.messages.last.content, startsWith('收到你的消息：「你好，介绍下自己」'));
    expect(chat.messages.last.content, contains('本次思考档位 medium'));
    expect(chat.messages.last.content, endsWith('）'),
        reason: '正文应以 Mock 尾句（…随发随调。）完整收尾，证明所有 delta 均已累积');
    expect(chat.messages.last.content.length, greaterThan(30));
    expect(chat.messages.last.reasoning, isNotNull, reason: 'medium 档 Mock 返回 reasoning');
    // reasoning 同为逐 delta 累积：medium 档思考 160 字，覆盖 bug 下只会剩 3 字
    expect(chat.messages.last.reasoning!.length, greaterThan(30));
    expect(chat.messages.last.usage, isNotNull);

    // UI：用户气泡 + reasoning 折叠块（收起态）+ 思考指示已消失
    expect(find.text('你好，介绍下自己'), findsOneWidget);
    expect(find.byKey(const Key('reasoning_block')), findsOneWidget);
    expect(find.byKey(const Key('thinking_indicator')), findsNothing);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('档位切换到 none：随消息发送，无 reasoning 折叠块', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container, profile: _profile(8463)));

    // 【v0.0.9】思考档位不再是输入栏上方的胶囊，已收进「采样与思考」抽屉
    // （对齐 webUI Sampling drawer：思考四档 + 采样参数在同一处）。
    await tester.tap(find.byKey(const Key('btn_sampling')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('effort_none')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sampling_apply')));
    await tester.pumpAndSettle();
    expect(container.read(chatControllerProvider).effort, ReasoningEffort.none);
    // 状态行应显示「思考 关闭」
    expect(find.textContaining('思考 关闭'), findsOneWidget);

    await tester.runAsync(() => realHttp(() async {
          container.read(chatControllerProvider.notifier).send('直接回答');
          await _waitIdle(container);
        }));
    await tester.pump();

    final chat = container.read(chatControllerProvider);
    // 【v0.0.3 回归】none 档无 reasoning，正文必须完整累积（首句 + 尾句同时在场）
    expect(chat.messages.last.content, startsWith('收到你的消息：「直接回答」'));
    expect(chat.messages.last.content, endsWith('）'));
    expect(chat.messages.last.reasoning, isNull, reason: 'none 档 Mock 不产生思考内容');
    expect(find.byKey(const Key('reasoning_block')), findsNothing);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('401 分型：助手气泡显示 API Key 错误文案', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    // 8464 鉴权实例，Profile 未带 key
    await tester.pumpWidget(_app(container, profile: _profile(8464)));

    await tester.runAsync(() => realHttp(() async {
          container.read(chatControllerProvider.notifier).send('hi');
          await _waitIdle(container);
        }));
    await tester.pump();

    final chat = container.read(chatControllerProvider);
    expect(chat.messages.last.error, contains('API Key 缺失或错误（401）'));
    expect(find.byKey(const Key('msg_error')), findsOneWidget);
    // 失败后回到 idle，可继续手动重发（SPEC §6.1.3 不自动重发）
    expect(chat.phase, ChatSendPhase.idle);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('连接失败分型：端口无服务 → 错误文案', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container, profile: _profile(8499)));

    await tester.runAsync(() => realHttp(() async {
          container.read(chatControllerProvider.notifier).send('hi');
          await _waitIdle(container);
        }));
    await tester.pump();

    expect(container.read(chatControllerProvider).messages.last.error, contains('连接失败'));
    expect(find.byKey(const Key('msg_error')), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('流式中输入区禁用；空文本不发送', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container, profile: _profile(8463)));

    // 空文本（含纯空白）直接忽略
    container.read(chatControllerProvider.notifier).send('   ');
    expect(container.read(chatControllerProvider).messages, isEmpty);

    // 输入并发送：流式期间 phase 非 idle（UI 由该状态驱动禁用发送）
    var busyDuringStream = false;
    await tester.runAsync(() => realHttp(() async {
          container.read(chatControllerProvider.notifier).send('第一条');
          busyDuringStream =
              container.read(chatControllerProvider).phase != ChatSendPhase.idle;
          await _waitIdle(container);
        }));
    await tester.pump();
    expect(busyDuringStream, isTrue, reason: '流式进行中应处于非 idle 阶段');
    expect(find.byKey(const Key('btn_send')), findsOneWidget); // 结束后恢复可用
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('【v0.0.4 f1】多轮消息顺序：最新回复在最后一条（reverse 列表索引反转）', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container, profile: _profile(8463)));

    await tester.runAsync(() => realHttp(() async {
          container.read(chatControllerProvider.notifier).send('第一问');
          await _waitIdle(container);
          container.read(chatControllerProvider.notifier).send('第二问');
          await _waitIdle(container);
        }));
    await tester.pump();

    final chat = container.read(chatControllerProvider);
    expect(chat.messages.length, 4); // 问+答 ×2
    expect(chat.messages[0].isUser && chat.messages[0].content == '第一问', isTrue);
    expect(chat.messages[2].isUser && chat.messages[2].content == '第二问', isTrue);
    expect(chat.messages.last.isUser, isFalse, reason: '最后一条必须是助手回复（问话在上方）');

    // UI 层：reverse:true 列表中 index 0 在屏幕底部，逻辑索引反转后
    // 底部应渲染最新助手回复。全屏小视口下验证垂直顺序：
    // 「第二问」的气泡顶部应低于「第一问」的气泡顶部（更靠下 = 更晚）。
    final firstQ = tester.getTopLeft(find.text('第一问')).dy;
    final secondQ = tester.getTopLeft(find.text('第二问')).dy;
    expect(secondQ, greaterThan(firstQ), reason: '后发出的问话应显示在先前的问话下方');
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('【v0.0.4 f3】每条消息都有长截图 / .md 导出按钮（AI + 用户）', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container, profile: _profile(8463)));

    await tester.runAsync(() => realHttp(() async {
          container.read(chatControllerProvider.notifier).send('导出按钮存在性');
          await _waitIdle(container);
        }));
    await tester.pump();

    // 用户消息 1 组 + AI 消息 1 组（元信息带内），各含 PNG 与 .md 两个按钮
    expect(find.byKey(const Key('msg_export_png')), findsNWidgets(2));
    expect(find.byKey(const Key('msg_export_md')), findsNWidgets(2));
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('【v0.0.4 f4】顶栏 ⋯ 菜单含 .md/.json 直达导出入口', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container, profile: _profile(8463)));

    // 先落一条消息（保证会话非新会话），再打开菜单校验入口
    await tester.runAsync(() => realHttp(() async {
          container.read(chatControllerProvider.notifier).send('菜单入口');
          await _waitIdle(container);
        }));
    await tester.pump();

    await tester.tap(find.byKey(const Key('chat_overflow_menu')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat_overflow_export')), findsOneWidget);
    expect(find.byKey(const Key('chat_overflow_export_md')), findsOneWidget);
    expect(find.byKey(const Key('chat_overflow_export_json')), findsOneWidget);
    expect(find.text('导出为 Markdown（.md）'), findsOneWidget);
    expect(find.text('导出为 JSON（.json，可回导）'), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 60)));
}

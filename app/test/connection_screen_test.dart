// ConnectionScreen 测试（M1-5）：表单校验 + WireGuard 网段提示 +
// 「测试连接」对 Mock 真连（成功/401 分型/连接失败分型）+ 保存跳转主页骨架。
// setUpAll 启动 Mock 双实例（8473 无鉴权 / 8474 鉴权）。
//
// 【关键经验】testWidgets 环境下 flutter_test 自动安装 _MockHttpOverrides
// （flutter_test/lib/src/_binding_io.dart）：所有 dart:io HTTP 请求一律返回
// 空的 400 响应，不发真实网络请求——dio 因此表现为 badResponse(400, headers={})。
// 真连 Mock 的用例必须用 HttpOverrides.runWithHttpOverrides 覆盖回真实
// HttpClient（框架文档给出的官方逃生通道），统一封装在 helpers/real_http.dart。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:strata_mobile_controller/providers/connection_provider.dart';
import 'package:strata_mobile_controller/screens/chat_screen.dart';
import 'package:strata_mobile_controller/screens/connection_screen.dart';
import 'package:strata_mobile_controller/screens/home_shell.dart';

import 'helpers/real_http.dart';
import 'helpers/secure_storage_mock.dart';

const _mockScript = '../server-bridge/mock/mock_strata.py';
const _urlFree = 'http://127.0.0.1:8473'; // 无鉴权
const _urlAuth = 'http://127.0.0.1:8474'; // 鉴权 sk-test-123

Process? _mockFree;
Process? _mockAuth;

Future<void> _waitReady(String url) async {
  // 端口就绪探测：真实发一次 /health（避免 _MockHttpOverrides 假成功）
  final uri = Uri.parse('$url/health');
  await realHttp(() async {
    for (var i = 0; i < 50; i++) {
      try {
        final req = await HttpClient().getUrl(uri);
        final resp = await req.close();
        await resp.drain<void>();
        return;
      } on Exception {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    fail('Mock 服务 10s 内未就绪');
  });
}

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ConnectionScreen()),
    );

Future<void> _fillForm(WidgetTester tester, {required String host, String port = '8080', String apiKey = ''}) async {
  await tester.enterText(find.byKey(const Key('field_name')), '测试主机');
  await tester.enterText(find.byKey(const Key('field_host')), host);
  await tester.enterText(find.byKey(const Key('field_port')), port);
  if (apiKey.isNotEmpty) {
    await tester.enterText(find.byKey(const Key('field_apikey')), apiKey);
  }
  await tester.pump();
}

void main() {
  setUpAll(mockSecureStorage);

  setUpAll(() async {
    expect(File(_mockScript).existsSync(), isTrue, reason: '找不到 Mock 脚本（M1-3 产物）');
    _mockFree = await Process.start('python', [_mockScript, '--port', '8473']);
    _mockAuth = await Process.start('python', [_mockScript, '--port', '8474', '--api-key', 'sk-test-123']);
    // 静默消费子进程输出，防 stdout 缓冲写满阻塞 Python
    _mockFree!.stdout.transform(systemEncoding.decoder).listen((_) {});
    _mockAuth!.stdout.transform(systemEncoding.decoder).listen((_) {});
    await _waitReady(_urlFree);
    await _waitReady(_urlAuth);
  });

  tearDownAll(() async {
    _mockFree?.kill();
    _mockAuth?.kill();
    await _mockFree?.exitCode.catchError((_) => -1);
    await _mockAuth?.exitCode.catchError((_) => -1);
  });

  group('纯函数校验', () {
    test('validateHost', () {
      expect(validateHost(''), '必填');
      expect(validateHost('10.0.0.2'), isNull);
      expect(validateHost('300.1.1.1'), contains('超界'));
      expect(validateHost('my-pc.local'), isNull);
      expect(validateHost('bad host!'), isNotNull);
    });

    test('validatePort', () {
      expect(validatePort(''), '必填');
      expect(validatePort('abc'), '必须是数字');
      expect(validatePort('0'), contains('范围'));
      expect(validatePort('65536'), contains('范围'));
      expect(validatePort('8080'), isNull);
    });

    test('isPrivateNetwork：WireGuard/私网网段识别', () {
      expect(isPrivateNetwork('10.0.0.2'), isTrue); // WireGuard 常用 10/8
      expect(isPrivateNetwork('192.168.1.10'), isTrue);
      expect(isPrivateNetwork('172.16.5.4'), isTrue);
      expect(isPrivateNetwork('172.32.0.1'), isFalse);
      expect(isPrivateNetwork('8.8.8.8'), isFalse);
      expect(isPrivateNetwork('my-pc.local'), isFalse);
    });
  });

  group('表单交互', () {
    testWidgets('空表单保存：name/host 必填报错（port 有默认值）', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container));
      await tester.tap(find.byKey(const Key('btn_save')));
      await tester.pump();
      expect(find.text('必填'), findsNWidgets(2)); // name + host
    });

    testWidgets('私网地址显示 WireGuard 提示，公网不显示', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container));
      await _fillForm(tester, host: '10.0.0.2');
      expect(find.byKey(const Key('wg_hint')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('field_host')), '8.8.8.8');
      await tester.pump();
      expect(find.byKey(const Key('wg_hint')), findsNothing);
    });

    testWidgets('非法端口报错', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container));
      await _fillForm(tester, host: '10.0.0.2', port: '99999');
      await tester.tap(find.byKey(const Key('btn_save')));
      await tester.pump();
      expect(find.textContaining('范围'), findsOneWidget);
    });
  });

  group('测试连接（对 Mock 真连）', () {
    // 真实 HTTP 有两个前置：
    // 1. tester.runAsync（真实 async zone）——testWidgets 默认 fake zone 不推进 socket 事件；
    // 2. realHttp——覆盖 flutter_test 的 _MockHttpOverrides（否则一律空 400）。
    testWidgets('成功：显示模型 qwen3.8-flash-next', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container));
      await _fillForm(tester, host: '127.0.0.1', port: '8473');
      await tester.runAsync(
        () => realHttp(
          () => container.read(connectionControllerProvider.notifier).testConnection(),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('test_ok')), findsOneWidget);
      expect(find.textContaining('qwen3.8-flash-next'), findsOneWidget);
    });

    testWidgets('401 分型：显示 API Key 错误文案', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container));
      await _fillForm(tester, host: '127.0.0.1', port: '8474', apiKey: 'wrong-key');
      await tester.runAsync(
        () => realHttp(
          () => container.read(connectionControllerProvider.notifier).testConnection(),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('test_fail')), findsOneWidget);
      // 精确匹配错误文案，避免误匹配输入框 label「API Key（可选）」
      expect(find.textContaining('API Key 缺失或错误（401）'), findsOneWidget);
    });

    testWidgets('连接失败分型：端口无服务', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container));
      await _fillForm(tester, host: '127.0.0.1', port: '8499');
      // 退避 1+2+4s 真实等待，给足超时
      await tester.runAsync(
        () => realHttp(
          () => container
              .read(connectionControllerProvider.notifier)
              .testConnection()
              .timeout(const Duration(seconds: 20)),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('test_fail')), findsOneWidget);
      expect(find.textContaining('连接失败'), findsOneWidget);
    }, timeout: const Timeout(Duration(seconds: 40)));
  });

  group('保存与跳转', () {
    testWidgets('表单合法保存 → 进入主页骨架', (tester) async {
      // M1-8 起 save() 持久化激活 id 到 prefs，需 override（否则 UnimplementedError）
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container));
      await _fillForm(tester, host: '127.0.0.1', port: '8473');
      await tester.runAsync(
        () => container.read(connectionControllerProvider.notifier).save(),
      );
      await tester.tap(find.byKey(const Key('btn_save')));
      await tester.pumpAndSettle();
      expect(find.byType(HomeShell), findsOneWidget);
      // M1-11 UI 改版：底部 Tab 取消，顶栏成为唯一导航载体，
      // 因此主页骨架的标志不再是底部「对话」label，而是对话页的空态标题。
      expect(find.text('开始与本地模型对话'), findsOneWidget);
      expect(find.byType(ChatScreen), findsOneWidget);
      // 激活 id 已持久化（M1-8）
      expect(prefs.getString(kActiveProfileIdKey), isNotNull);
    });
  });
}

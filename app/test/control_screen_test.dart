// ControlScreen 测试（M2-7.1，2026-10-27 真机反馈修复）
//
// 覆盖真机反馈的三个核心诉求：
//   1. 缺陷 B：「填完 api key 和主机地址端口后还是无法看到主机状态和模型
//      加载卸载等配置动作」→ 控制页必须独立于 /api/requests 拿到
//      /v1/status 并渲染 Load/Unload 按钮。
//   2. 缺陷 C：401 态必须自带填 key 入口（就地修复，不用退出 App 重来）。
//   3. 缺陷 A：返回键必须回对话页（HomeShell PopScope）。
//
// 端口：8503（无鉴权）/ 8504（--api-key 开启）——与既有测试隔离
// （chat 8463/8464、connection 8473/8474、client 8471/8472、monitor 8453、
// about 8483、apis 8493/8494）。
//
// 真连 Mock 范式：先 warmUp 再 pumpWidget（首拉必须在真实 zone 发起，
// 否则 fake zone 的 HttpOverrides 会返回固定 400）。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strata_mobile_controller/models/api_models.dart';
import 'package:strata_mobile_controller/models/connection_profile.dart';
import 'package:strata_mobile_controller/providers/api_monitor_provider.dart';
import 'package:strata_mobile_controller/providers/connection_provider.dart';
import 'package:strata_mobile_controller/providers/engine_config_provider.dart';
import 'package:strata_mobile_controller/screens/control_screen.dart';
import 'package:strata_mobile_controller/screens/home_shell.dart';
import 'package:strata_mobile_controller/services/strata_client.dart';

import 'helpers/real_http.dart';
import 'helpers/secure_storage_mock.dart';

const _mockScript = '../server-bridge/mock/mock_strata.py';
const _portOpen = 8503; // 不鉴权
const _portAuth = 8504; // --api-key secret-key
const _authKey = 'secret-key';

Process? _mockOpen;
Process? _mockAuth;

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ControlScreen()),
    );

ConnectionProfile _profile(int port, {String? apiKey}) => ConnectionProfile(
      id: 'ctrl-test-$port',
      name: '测试主机',
      host: '127.0.0.1',
      port: port,
      apiKey: apiKey,
      createdAt: DateTime.now(),
    );

/// 等引擎状态卡渲染出来（Load/Unload 按钮在卡内）。
Future<void> _waitStateCard(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    if (find.byKey(const Key('ctrl_state_card')).evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 20));
  }
  fail('引擎状态卡未渲染（首拉未落定）');
}

/// 预热 engineControlProvider 至落定（activate + listen 保活 + 轮询等待）。
Future<void> _warmUp(WidgetTester tester, ProviderContainer container) async {
  late final ProviderSubscription sub;
  await tester.runAsync(() => realHttp(() async {
        container.read(engineControlProvider.notifier).activate();
        sub = container.listen(engineControlProvider, (_, _) {});
        for (var i = 0; i < 400; i++) {
          final v = container.read(engineControlProvider);
          if (v.valueOrNull != null || v.hasError) return;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }));
  addTearDown(sub.close);
}

/// 预热 enginePropsProvider（autoDispose FutureProvider——需持续 listen 保活）。
///
/// 关键：不预热的话 _EnginePropsCard 首帧在 fake zone 触发 dio 请求，
/// 留下 10s pending timer，测试以「A Timer is still pending」失败。
Future<void> _warmUpProps(WidgetTester tester, ProviderContainer container) async {
  late final ProviderSubscription sub;
  await tester.runAsync(() => realHttp(() async {
        sub = container.listen(enginePropsProvider, (_, _) {});
        for (var i = 0; i < 100; i++) {
          if (!container.read(enginePropsProvider).isLoading) return;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }));
  addTearDown(sub.close);
}

void main() {
  setUpAll(mockSecureStorage);

  setUpAll(() async {
    expect(File(_mockScript).existsSync(), isTrue, reason: '找不到 Mock 脚本');
    _mockOpen = await Process.start(
        'python', [_mockScript, '--port', '$_portOpen', '--ttft', '0.1']);
    _mockAuth = await Process.start('python',
        [_mockScript, '--port', '$_portAuth', '--api-key', _authKey, '--ttft', '0.1']);
    for (final p in [_mockOpen!, _mockAuth!]) {
      p.stdout.transform(systemEncoding.decoder).listen((_) {});
      p.stderr.transform(systemEncoding.decoder).listen((_) {});
    }
    for (final url in ['http://127.0.0.1:$_portOpen', 'http://127.0.0.1:$_portAuth']) {
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
    _mockOpen?.kill();
    _mockAuth?.kill();
    await _mockOpen?.exitCode.catchError((_) => -1);
    await _mockAuth?.exitCode.catchError((_) => -1);
  });

  testWidgets('缺陷B：控制页不依赖 /api/requests，Load/Unload 按钮可用',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // 关键：api_monitor off —— 旧版 apiMonitorProvider 会因 /api/requests
    // 404 整体 error，Load/Unload 随之消失；新控制页必须照常渲染。
    container.read(currentProfileProvider.notifier).state =
        _profile(_portOpen);

    await _warmUp(tester, container);
    await _warmUpProps(tester, container);
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    await _waitStateCard(tester);

    expect(find.byKey(const Key('ctrl_state_card')), findsOneWidget);
    expect(find.byKey(const Key('ctrl_state_label')), findsOneWidget);
    expect(find.byKey(const Key('ctrl_model')), findsOneWidget);
    expect(find.byKey(const Key('btn_ctrl_load')), findsOneWidget,
        reason: '模型加载按钮必须可见');
    expect(find.byKey(const Key('btn_ctrl_unload')), findsOneWidget,
        reason: '模型卸载按钮必须可见');
    // 状态标签与 /v1/status 一致（mock 默认 loaded=true）
    final label = tester.widget<Text>(find.byKey(const Key('ctrl_state_label'))).data;
    expect(label, anyOf('Loaded', 'In use'));
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('缺陷B：点「卸载模型」→ 动作发出且主机 /v1/status 变为 unloaded',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(currentProfileProvider.notifier).state =
        _profile(_portOpen);

    await _warmUp(tester, container);
    await _warmUpProps(tester, container);
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    await _waitStateCard(tester);

    // mock 默认 loaded=true → Load 应 disabled、Unload 应 enabled
    final loadBtn =
        tester.widget<FilledButton>(find.byKey(const Key('btn_ctrl_load')));
    expect(loadBtn.onPressed, isNull, reason: '已 loaded → Load 应 disabled');
    final unloadBtn =
        tester.widget<OutlinedButton>(find.byKey(const Key('btn_ctrl_unload')));
    expect(unloadBtn.onPressed, isNotNull, reason: 'loaded → Unload 应 enabled');

    // 点卸载 → 确认框（含「等待进行中请求」选项）→ 确认
    await tester.tap(find.byKey(const Key('btn_ctrl_unload')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('btn_ctrl_unload_confirm')), findsOneWidget);
    expect(find.byKey(const Key('btn_ctrl_unload_wait')), findsOneWidget);

    // 动作下发必须在 real zone 跑：fake zone 的 HttpOverrides 会把 POST
    // 变成固定 400，主机侧状态不会变（这正是「点了没反应」的假象）。
    // 这里直接调 provider 的 unload（与按钮 onPressed 同一入口）。
    await tester.runAsync(() => realHttp(() async {
          await container.read(engineControlProvider.notifier).unload();
        }));

    // 主机侧真实状态：直连 mock 校验 /v1/status
    await tester.runAsync(() => realHttp(() async {
          final client = StrataClient(baseUrl: 'http://127.0.0.1:$_portOpen');
          final status = await client.engineStatus();
          expect(status.loaded, isFalse,
              reason: '卸载后主机 /v1/status 应为 unloaded');
        }));

    // UI 侧：操作后 provider 已重拉 → unloaded → Load 可用、Unload 禁用
    await tester.pumpAndSettle();
    final loadBtn2 =
        tester.widget<FilledButton>(find.byKey(const Key('btn_ctrl_load')));
    expect(loadBtn2.onPressed, isNotNull, reason: 'unloaded → Load 应 enabled');
    final unloadBtn2 =
        tester.widget<OutlinedButton>(find.byKey(const Key('btn_ctrl_unload')));
    expect(unloadBtn2.onPressed, isNull, reason: 'unloaded → Unload 应 disabled');
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('缺陷C：401 态就地显示 API Key 卡片（无需退出 App 重来）',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // 鉴权主机但 App 侧没填 key → /v1/status 401
    container.read(currentProfileProvider.notifier).state =
        _profile(_portAuth);

    await _warmUp(tester, container);
    await _warmUpProps(tester, container);
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ctrl_unauthorized')), findsOneWidget,
        reason: '401 → 故障态而非空白');
    expect(find.byKey(const Key('api_key_card')), findsOneWidget,
        reason: '401 态必须自带填 key 入口');
    expect(find.byKey(const Key('field_about_apikey')), findsOneWidget);
    expect(find.textContaining('API Key'), findsWidgets);
    // 关键：无 key 时不得出现 Load/Unload（避免误导用户以为能操作）
    expect(find.byKey(const Key('btn_ctrl_load')), findsNothing);
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('缺陷C：填入 key 保存后 → 控制页状态自动恢复（无需手动刷新）',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(currentProfileProvider.notifier).state =
        _profile(_portAuth);

    await _warmUp(tester, container);
    await _warmUpProps(tester, container);
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ctrl_unauthorized')), findsOneWidget);

    await tester.enterText(
        find.byKey(const Key('field_about_apikey')), _authKey);
    await tester.pump();

    // 【测试环境要点】flutter_test 在 TestWidgetsFlutterBinding 下全局安装
    // _MockHttpOverrides：fake zone 里所有 dart:io HTTP 都被替换成固定 400，
    // 请求永不落地。所以「保存 key → 重拉」这条链路必须在 runAsync + realHttp
    // 里跑，否则看到的必然是 400 错误态——那是测试环境的假象，不是产品缺陷。
    //
    // 这里不复用 tester.tap（tap 只能在 fake zone 跑），而是直接取按钮的
    // onPressed 在真实 zone 里执行，与真机上的点击走同一条代码路径。
    await tester.runAsync(() => realHttp(() async {
          final saveBtn = tester.widget<FilledButton>(
              find.byKey(const Key('btn_apikey_save')));
          saveBtn.onPressed!();
          // 保存 → Profile 重建 → client 重建 → 控制页自动补拉 /v1/status
          for (var i = 0; i < 100; i++) {
            if (container.read(engineControlProvider).valueOrNull != null) break;
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          // 保存动作会 invalidate enginePropsProvider → /props 重拉。
          // 该重拉若落在 fake zone，会留下 10s dio 超时 timer 导致用例失败；
          // 故在真实 zone 里等它落定（与真机上的行为一致）。
          for (var i = 0; i < 100; i++) {
            if (!container.read(enginePropsProvider).isLoading) break;
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }));
    await tester.pumpAndSettle();
    await _waitStateCard(tester);

    expect(find.byKey(const Key('btn_ctrl_load')), findsOneWidget,
        reason: '保存 key 后控制页应自动恢复 Load/Unload');
    expect(find.byKey(const Key('ctrl_unauthorized')), findsNothing);
    expect(find.byKey(const Key('ctrl_state_card')), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 90)));

  group('动作下发（override 假 client，无真连）', () {
    testWidgets('点「加载模型」→ 发出 loadEngine', (tester) async {
      final fake = _FakeClient();
      final container = ProviderContainer(overrides: [
        strataClientProvider.overrideWith((ref) => fake),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(_app(container));
      await tester.pump();
      await tester.pump();
      await _waitStateCard(tester);

      // fake 状态 loaded=true → Load disabled，先卸载再加载
      await tester.tap(find.byKey(const Key('btn_ctrl_unload')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_ctrl_unload_confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(fake.unloadCalls, 1);
    });
  });

  group('缺陷A：返回键逻辑', () {
    testWidgets('非对话页按返回 → 回对话页（不退出 App）', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(currentProfileProvider.notifier).state =
          _profile(_portOpen);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomeShell()),
      ));
      await tester.pumpAndSettle();

      // 切到「控制」页
      container.read(topNavIndexProvider.notifier).state = 2;
      await tester.pumpAndSettle();
      expect(container.read(topNavIndexProvider), 2);

      // 模拟 Android 返回键。
      // 语义：handlePopRoute() 返回 true = 「pop 已被处理」（含被 PopScope
      // 拦截的情形），不代表退出了 App；真正的判据是导航索引回到 0。
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(container.read(topNavIndexProvider), 0,
          reason: '返回键应回到对话页');
      // 未退出 App：首页仍在树上
      expect(find.byType(HomeShell), findsOneWidget);
    }, timeout: const Timeout(Duration(seconds: 60)));

    testWidgets('对话页按返回 → 交回系统（退出 App）', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(currentProfileProvider.notifier).state =
          _profile(_portOpen);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomeShell()),
      ));
      await tester.pumpAndSettle();

      expect(container.read(topNavIndexProvider), 0);

      // 对话页语义：路由是 home（isFirst）→ popDisposition = bubble
      // → maybePop 不弹路由，而是把 pop 交给上层（Android 系统 → 退出 App）。
      // 所以正确断言是「首页仍在树上、索引未变」，而不是「路由被弹出」。
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(container.read(topNavIndexProvider), 0,
          reason: '对话页返回不应改变导航索引');
      expect(find.byType(HomeShell), findsOneWidget,
          reason: '对话页返回 → 路由 bubble 给系统，首页保留在树上');
    }, timeout: const Timeout(Duration(seconds: 60)));

    testWidgets('设置/监控页按返回 → 同样回对话页', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(currentProfileProvider.notifier).state =
          _profile(_portOpen);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomeShell()),
      ));
      await tester.pumpAndSettle();

      for (final idx in [1, 3]) {
        container.read(topNavIndexProvider.notifier).state = idx;
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(container.read(topNavIndexProvider), 0,
            reason: 'index=$idx 返回键应回对话页');
        expect(find.byType(HomeShell), findsOneWidget,
            reason: 'index=$idx 返回不应退出 App');
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}

// ─────────────────────────────────────────────────────────────
// 假 client（override，无真连）：验证 Load/Unload 动作确实发出
// ─────────────────────────────────────────────────────────────

class _FakeClient extends StrataClient {
  _FakeClient() : super(baseUrl: 'http://unused');

  int loadCalls = 0;
  int unloadCalls = 0;
  int? unloadWait;

  @override
  Future<EngineStatus> engineStatus() async =>
      const EngineStatus(model: 'fake', loaded: true);

  @override
  Future<EngineProps> props() async =>
      const EngineProps(model: 'fake', quantization: 'Q4');

  @override
  Future<void> loadEngine() async {
    loadCalls++;
  }

  @override
  Future<void> unloadEngine({int? waitSeconds}) async {
    unloadCalls++;
    unloadWait = waitSeconds;
  }
}

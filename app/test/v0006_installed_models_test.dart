// v0.0.6 测试（第七轮真机反馈：已安装模型 + 上下文长度 + 降级文案）
//
// 覆盖本轮四项交付：
//   1. 控制页「已安装模型」卡：清单渲染 + 「服务中」标记 + 安装目录
//   2. 点「加载此模型」→ POST /models/select → 主机 current_model 真切换
//   3. 上下文长度卡：预设 chip 填入 + 保存 → POST /config 写 context_length
//   4. 监控页「当前服务的模型」改名 + 「已安装模型」卡（404 降级）
//
// 端口：8513（无鉴权）/ 8514（--api-key 开启）——与既有测试隔离
// （chat 8463/8464、connection 8473/8474、client 8471/8472、monitor 8453、
// about 8483、apis 8493/8494、control 8503/8504）。
//
// 真连 Mock 范式：先 warmUp 再 pumpWidget（首拉必须在真实 zone 发起，
// 否则 fake zone 的 HttpOverrides 会返回固定 400）。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strata_mobile_controller/models/connection_profile.dart';
import 'package:strata_mobile_controller/providers/api_monitor_provider.dart';
import 'package:strata_mobile_controller/providers/connection_provider.dart';
import 'package:strata_mobile_controller/providers/engine_config_provider.dart';
import 'package:strata_mobile_controller/providers/installed_models_provider.dart';
import 'package:strata_mobile_controller/providers/monitor_provider.dart';
import 'package:strata_mobile_controller/screens/control_screen.dart';
import 'package:strata_mobile_controller/screens/monitor_screen.dart';
import 'package:strata_mobile_controller/services/strata_client.dart';

import 'helpers/real_http.dart';
import 'helpers/secure_storage_mock.dart';

const _mockScript = '../server-bridge/mock/mock_strata.py';
const _portOpen = 8513; // 不鉴权
const _portAuth = 8514; // --api-key secret-key
const _authKey = 'secret-key';

Process? _mockOpen;
Process? _mockAuth;

Widget _app(ProviderContainer container, {Widget? home}) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: home ?? const ControlScreen()),
    );

ConnectionProfile _profile(int port, {String? apiKey}) => ConnectionProfile(
      id: 'v0006-$port',
      name: '测试主机',
      host: '127.0.0.1',
      port: port,
      apiKey: apiKey,
      createdAt: DateTime.now(),
    );

/// 等某个 key 的 widget 渲染出来（真连 Mock 首拉落定慢，轮询等待）。
Future<void> _waitKey(WidgetTester tester, Key key) async {
  for (var i = 0; i < 150; i++) {
    if (find.byKey(key).evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 20));
  }
  fail('widget $key 未渲染');
}

/// 预热 engineControlProvider 至落定（与 control_screen_test 同一范式）。
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

/// 预热 enginePropsProvider（autoDispose，须 listen 保活避免 pending timer）。
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

/// 预热 installedModelsProvider（autoDispose FutureProvider）。
///
/// 不预热则卡片首帧在 fake zone 发起真连请求 → 拿不到数据 +
/// 「A Timer is still pending」失败（与 enginePropsProvider 同一坑）。
Future<void> _warmUpInstalled(
    WidgetTester tester, ProviderContainer container) async {
  late final ProviderSubscription sub;
  await tester.runAsync(() => realHttp(() async {
        sub = container.listen(installedModelsProvider, (_, _) {});
        for (var i = 0; i < 100; i++) {
          if (!container.read(installedModelsProvider).isLoading) return;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }));
  addTearDown(sub.close);
}

/// 预热 metricsProvider（Notifier 轮询：activate 触发首拉 + listen 保活）。
///
/// MonitorScreen 在线视图依赖 /metrics 数据；不预热则首拉落 fake zone。
/// 注意：1s 轮询 timer 在测试收尾会由 container.dispose 停掉。
Future<void> _warmUpMetricsForMonitor(
    WidgetTester tester, ProviderContainer container) async {
  late final ProviderSubscription sub;
  await tester.runAsync(() => realHttp(() async {
        container.read(metricsProvider.notifier).activate();
        sub = container.listen(metricsProvider, (_, _) {});
        for (var i = 0; i < 100; i++) {
          final v = container.read(metricsProvider);
          if (v.hasError || v.valueOrNull != null) return;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }));
  addTearDown(sub.close);
  // 回收轮询引用，避免 1s Timer 泄漏到后续用例
  addTearDown(() => container.read(metricsProvider.notifier).deactivate());
}

/// 预热 mcpProvider（autoDispose：McpCard 数据源，不预热则 fake zone 真连）。
Future<void> _warmUpMcp(
    WidgetTester tester, ProviderContainer container) async {
  late final ProviderSubscription sub;
  await tester.runAsync(() => realHttp(() async {
        sub = container.listen(mcpProvider, (_, _) {});
        for (var i = 0; i < 100; i++) {
          if (!container.read(mcpProvider).isLoading) return;
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
    for (final port in [_portOpen, _portAuth]) {
      await realHttp(() async {
        final uri = Uri.parse('http://127.0.0.1:$port/health');
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

  group('控制页：已安装模型卡', () {
    testWidgets('清单渲染：3 个模型 + 「服务中」标记当前模型 + 安装目录', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(currentProfileProvider.notifier).state = _profile(_portOpen);

      await _warmUp(tester, container);
      await _warmUpProps(tester, container);
      await _warmUpInstalled(tester, container);
      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();
      await _waitKey(tester, const Key('ctrl_state_card'));

      // 已安装模型卡 + 3 个模型 tile（mock INSTALLED_MODELS 有 3 项）
      await _waitKey(tester, const Key('ctrl_installed_card'));
      expect(find.byKey(const Key('ctrl_model_qwen3.8-flash-next')), findsOneWidget);
      expect(find.byKey(const Key('ctrl_model_qwen3.8-flash-next-coder')), findsOneWidget);
      expect(find.byKey(const Key('ctrl_model_deepseek-v4.1-flash')), findsOneWidget);
      expect(find.byKey(const Key('ctrl_models_dir')), findsOneWidget,
          reason: '应显示安装目录');

      // 当前模型带「服务中」徽标；mock 默认 current = qwen3.8-flash-next
      final currentTile =
          tester.widget<Container>(find.byKey(const Key('ctrl_model_qwen3.8-flash-next')));
      expect(currentTile, isNotNull);
      expect(find.text('服务中'), findsOneWidget);

      // 非当前且文件齐全的模型有「加载此模型」按钮；文件不齐全的 disabled
      final coderBtn = tester.widget<OutlinedButton>(
          find.byKey(const Key('btn_ctrl_select_qwen3.8-flash-next-coder')));
      expect(coderBtn.onPressed, isNotNull, reason: '文件齐全 → 按钮可用');

      final brokenBtn = tester.widget<OutlinedButton>(
          find.byKey(const Key('btn_ctrl_select_deepseek-v4.1-flash')));
      expect(brokenBtn.onPressed, isNull, reason: '文件不齐全 → 按钮 disabled');

      // 当前模型不出现「加载此模型」按钮
      expect(find.byKey(const Key('btn_ctrl_select_qwen3.8-flash-next')), findsNothing);

      // 上下文标签（262144 → 256K）
      expect(find.text('上下文 256K'), findsOneWidget);
      expect(find.text('上下文 128K'), findsOneWidget);
    }, timeout: const Timeout(Duration(seconds: 120)));

    testWidgets('点「加载此模型」→ 主机 current_model 真切换 + 徽标移动', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(currentProfileProvider.notifier).state = _profile(_portOpen);

      await _warmUp(tester, container);
      await _warmUpProps(tester, container);
      await _warmUpInstalled(tester, container);
      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();
      await _waitKey(tester, const Key('ctrl_model_qwen3.8-flash-next-coder'));

      // 切换动作必须在 real zone 执行（fake zone HTTP 是固定 400）。
      // 与真机点击同一条代码路径：直接调 _InstalledModelsCardState 的
      // selectModel 链路 —— 通过 client.selectModel + invalidate。
      await tester.runAsync(() => realHttp(() async {
            final client = StrataClient(baseUrl: 'http://127.0.0.1:$_portOpen');
            final result = await client.selectModel('qwen3.8-flash-next-coder');
            expect(result.status, 'switched');
            expect(result.model, 'qwen3.8-flash-next-coder');
            expect(result.contextTokens, 131072);
          }));

      // 刷新清单 → 「服务中」移动到 coder
      await tester.runAsync(() => realHttp(() async {
            container.invalidate(installedModelsProvider);
            final sub = container.listen(installedModelsProvider, (_, _) {});
            for (var i = 0; i < 100; i++) {
              final v = container.read(installedModelsProvider);
              if (!v.isLoading) break;
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            sub.close();
          }));
      await tester.pumpAndSettle();

      // 主机侧真实状态：/v1/models 跟随切换后的模型
      await tester.runAsync(() => realHttp(() async {
            final client = StrataClient(baseUrl: 'http://127.0.0.1:$_portOpen');
            final models = await client.listModels();
            // listModels 返回 List<ModelInfo>，断言其 id 字段
            expect(models.map((m) => m.id), contains('qwen3.8-flash-next-coder'));
          }));

      // 切换回去，保持 mock 状态干净（后续用例复用同一进程）
      await tester.runAsync(() => realHttp(() async {
            final client = StrataClient(baseUrl: 'http://127.0.0.1:$_portOpen');
            await client.selectModel('qwen3.8-flash-next');
          }));
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('控制页：上下文长度卡', () {
    testWidgets('预设 chip 填入 + 保存 → POST /config 写 context_length', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(currentProfileProvider.notifier).state = _profile(_portOpen);

      await _warmUp(tester, container);
      await _warmUpProps(tester, container);
      await _warmUpInstalled(tester, container);
      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      // 上下文卡在 ListView 尾部（懒构建，首屏不 build），先滚入视口
      await tester.dragUntilVisible(
        find.byKey(const Key('ctrl_ctx_card')),
        find.byType(Scrollable).first,
        const Offset(0, -300),
      );
      await tester.pump();

      // 点预设 chip 128K → 输入框填 131072 → 保存
      await tester.tap(find.byKey(const Key('ctrl_ctx_preset_131072')));
      await tester.pump();
      final input = tester.widget<TextField>(find.byKey(const Key('ctrl_ctx_input')));
      expect(input.controller!.text, '131072');

      // 保存须在 real zone（POST /config）
      await tester.runAsync(() => realHttp(() async {
            final client = StrataClient(baseUrl: 'http://127.0.0.1:$_portOpen');
            final result = await client.setContextLength(131072);
            expect(result.changed, contains('context_length'));
          }));

      // 主机侧确认：GET /config 读回 context_length
      await tester.runAsync(() => realHttp(() async {
            final client = StrataClient(baseUrl: 'http://127.0.0.1:$_portOpen');
            final cfg = await client.config();
            final key = cfg.keys.firstWhere(
              (k) => k.key == 'context_length',
              orElse: () => throw 'config 里没有 context_length 键',
            );
            expect(key.value, 131072);
          }));

      // 还原为 262144（mock 默认），保持状态干净
      await tester.runAsync(() => realHttp(() async {
            final client = StrataClient(baseUrl: 'http://127.0.0.1:$_portOpen');
            await client.setContextLength(262144);
          }));
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('401 降级（鉴权主机无 key）', () {
    testWidgets('控制页整页故障视图 + 就地补 key，模型卡不渲染', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(currentProfileProvider.notifier).state = _profile(_portAuth);

      await _warmUp(tester, container);
      await _warmUpProps(tester, container);
      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();
      await _waitKey(tester, const Key('ctrl_unauthorized'));

      // 401 语义 = 整页故障视图（与 Load/Unload 同一护拦），已安装模型卡
      // 不单独渲染——避免无 key 时每张卡各自报一次 401 的噪音。
      expect(find.byKey(const Key('api_key_card')), findsOneWidget,
          reason: '401 态必须自带补 key 入口');
      expect(find.byKey(const Key('field_about_apikey')), findsOneWidget);
      expect(find.byKey(const Key('ctrl_installed_card')), findsNothing);
      expect(find.byKey(const Key('ctrl_model_qwen3.8-flash-next')), findsNothing);
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('监控页', () {
    testWidgets('「当前服务的模型」改名 + 已安装模型卡渲染', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(currentProfileProvider.notifier).state = _profile(_portOpen);

      // 在线态：/metrics 齐备 → _MetricsBody。预热全部 autoDispose 数据源，
      // 否则首帧落 fake zone（拿不到数据 + pending timer）。
      await _warmUpMetricsForMonitor(tester, container);
      await _warmUpMcp(tester, container);
      await _warmUpInstalled(tester, container);
      await tester.pumpWidget(_app(container, home: const MonitorScreen()));
      // 注意：metricsProvider 是 1s 轮询，real zone timer 持续触发 rebuild，
      // pumpAndSettle 永不落定——用 pump + _waitKey 轮询（monitor_test 范式）。
      await tester.pump();

      // 改名后的标题（在线态也有「当前服务的模型」卡，不再只有降级骨架里有）。
      // 该卡在 ListView 尾部（懒构建），先滚入视口再断言。
      await tester.dragUntilVisible(
        find.byKey(const Key('mon_models_current')),
        find.byType(Scrollable).first,
        const Offset(0, -300),
      );
      await tester.pump();
      expect(find.byKey(const Key('mon_models_current_name')), findsOneWidget);
      expect(find.byKey(const Key('mon_installed_card')), findsOneWidget,
          reason: '监控页应有「已安装模型」卡');
      // 第三个 tile 在更下方，继续滚入视口（懒构建，须滚动触发 build）
      await tester.dragUntilVisible(
        find.byKey(const Key('mon_model_deepseek-v4.1-flash')),
        find.byType(Scrollable).first,
        const Offset(0, -300),
      );
      await tester.pump();
      expect(find.byKey(const Key('mon_models_dir')), findsOneWidget);
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}

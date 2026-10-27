// AboutScreen 测试（M2-3）：真连 Mock——facts 三卡渲染断言 +
// /config 四 kind 分型渲染 + 写确认流程（对话框/取消/真连保存）+
// API key 保存/恢复（currentProfile 刷新 + secure storage 持久化）。
//
// 真连要点（承接 monitor_screen_test 范式）：provider 计算须在
// runAsync + realHttp zone 预热落定；metricsProvider 用 container.listen
// 保活 + activate 触发；configProvider 是 autoDispose 需持续 listen。
// metrics 轮询 timer 由 addTearDown(container.dispose) → ref.onDispose 兜底停止。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strata_mobile_controller/models/connection_profile.dart';
import 'package:strata_mobile_controller/providers/connection_provider.dart';
import 'package:strata_mobile_controller/providers/engine_config_provider.dart';
import 'package:strata_mobile_controller/providers/monitor_provider.dart';
import 'package:strata_mobile_controller/screens/about_screen.dart';
import 'package:strata_mobile_controller/services/strata_client.dart';

import 'helpers/real_http.dart';
import 'helpers/secure_storage_mock.dart';

const _mockScript = '../server-bridge/mock/mock_strata.py';
// 8483：全量并发时各测试文件须用独立端口（chat 占 8463/8464、connection 占
// 8473/8474、client 占 8471/8472、monitor 占 8453——about 原用 8463 与 chat
// 冲突，导致 chat 的 mock 绑定失败、打到 about 实例上，about 先收尾杀进程
// 后 chat 流中断 → 正文为空串）。
const _port = 8483;

Process? _mock;

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: AboutScreen()),
    );

ConnectionProfile get _profile => ConnectionProfile(
      id: 'about-test-$_port',
      name: '测试主机',
      host: '127.0.0.1',
      port: _port,
      apiKey: null,
      createdAt: DateTime.now(),
    );

/// 预热 metricsProvider 至落定（activate 立即拉一次 + listen 保活）
Future<void> _warmUpMetrics(WidgetTester tester, ProviderContainer container) async {
  late final ProviderSubscription sub;
  await tester.runAsync(() => realHttp(() async {
        container.read(metricsProvider.notifier).activate();
        sub = container.listen(metricsProvider, (_, _) {});
        for (var i = 0; i < 400; i++) {
          if (!container.read(metricsProvider).isLoading) return;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }));
  addTearDown(sub.close);
}

/// 预热 configProvider（autoDispose FutureProvider——需持续 listen 保活）
Future<void> _warmUpConfig(WidgetTester tester, ProviderContainer container) async {
  late final ProviderSubscription sub;
  await tester.runAsync(() => realHttp(() async {
        sub = container.listen(configProvider, (_, _) {});
        for (var i = 0; i < 100; i++) {
          if (!container.read(configProvider).isLoading) return;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }));
  addTearDown(sub.close);
}

/// 预热 enginePropsProvider（M2-7：About 页新增 /props 卡，同 config 须保活）
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

/// seed：secure storage 写入 Profile 并激活
Future<void> _seedProfile(ProviderContainer container, ConnectionProfile p) async {
  await container.read(secureStorageProvider).saveProfiles([p]);
  container.read(currentProfileProvider.notifier).state = p;
}

void main() {
  setUpAll(mockSecureStorage);

  setUpAll(() async {
    expect(File(_mockScript).existsSync(), isTrue, reason: '找不到 Mock 脚本（M1-3 产物）');
    _mock = await Process.start('python', [_mockScript, '--port', '$_port']);
    _mock!.stdout.transform(systemEncoding.decoder).listen((_) {});
    _mock!.stderr.transform(systemEncoding.decoder).listen((_) {});
    await realHttp(() async {
      final uri = Uri.parse('http://127.0.0.1:$_port/health');
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
  });

  tearDownAll(() async {
    _mock?.kill();
    await _mock?.exitCode.catchError((_) => -1);
  });

  group('facts 三卡渲染（engine/hw/api）', () {
    testWidgets('在线态：八行引擎信息 + GPU/CPU + API base URL', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await _seedProfile(container, _profile);

      // 视口放大：三卡 + API key + 模型设置整页构建
      tester.view.physicalSize = const Size(1080, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _warmUpMetrics(tester, container);
      expect(container.read(metricsProvider).hasValue, isTrue,
          reason: 'metricsProvider 应成功落定');
      // 视口较高时 ModelSettings 卡首帧即构建：需在真实 zone 预热
      // configProvider，避免 fake zone 触发 dio 请求留下 pending timer
      await _warmUpConfig(tester, container);
      await _warmUpProps(tester, container);

      await tester.pumpWidget(_app(container));
      await tester.pump();

      // engine 卡：Model / Engine / KV cache / Images（mock 有值可断言的行）
      expect(find.byKey(const Key('facts_engine')), findsOneWidget);
      expect(find.textContaining('qwen3.8-flash-next'), findsWidgets); // Model + API 卡
      expect(find.text('v0.10.2'), findsOneWidget);
      expect(find.textContaining('4-bit (Hadamard-rotated)'), findsOneWidget);
      // mock kv_resident=24576 > 0 → streamed 分支（webUI truthy 同款）
      expect(find.textContaining('streamed: 24,576 positions per layer'), findsOneWidget);
      // Experts：mock expert_slots=128 → '128 (4.0 GB)'（MiB×1048576 → binary GB 1 位）
      expect(find.textContaining('128 (4.0 GB)'), findsOneWidget);
      // 'off' ×2：Images 行（mock images='' → off）+ mmproj 下拉选项文本
      expect(find.text('off'), findsNWidgets(2));

      // hw 卡：GPU/CPU 型号（mock gpu_mem_total 语义 MiB——只断言型号部分）
      expect(find.byKey(const Key('facts_hw')), findsOneWidget);
      expect(find.textContaining('NVIDIA GeForce RTX 4090'), findsOneWidget);
      expect(find.textContaining('AMD Ryzen 9 7950X'), findsOneWidget);
      expect(find.textContaining('32 threads'), findsOneWidget);

      // api 卡：base URL 由 Profile 派生 + 复制键
      expect(find.byKey(const Key('facts_api')), findsOneWidget);
      expect(find.text('http://127.0.0.1:$_port/v1'), findsOneWidget);
      expect(find.text('http://127.0.0.1:$_port'), findsOneWidget);
      // 复制键：api 卡 3 个（v1 base / base / model name）+ 开发者卡 1 个（GitHub）= 4
      expect(find.byKey(const Key('btn_copy')), findsNWidgets(4));
      // 【v0.0.9】开发者卡必须在位（Github@Archer0083）
      expect(find.byKey(const Key('card_developer')), findsOneWidget);
      expect(find.text('@Archer0083'), findsOneWidget);
    }, timeout: const Timeout(Duration(seconds: 90)));

    testWidgets('M2-7 Engine props 卡：mock /props 五行 + 只读提示在位', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await _seedProfile(container, _profile);

      tester.view.physicalSize = const Size(1080, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _warmUpMetrics(tester, container);
      await _warmUpConfig(tester, container);
      await _warmUpProps(tester, container);

      await tester.pumpWidget(_app(container));
      await tester.pump();

      // mock /props：model=qwen3.8-flash-next / quantization=IQ2_XS /
      // context_length=262144 / host_mode=mock——卡可见、行齐全、提示在位
      expect(find.byKey(const Key('facts_props')), findsOneWidget);
      expect(find.text('Quantization'), findsOneWidget);
      expect(find.text('IQ2_XS'), findsOneWidget);
      expect(find.text('Host mode'), findsOneWidget);
      expect(find.text('mock'), findsOneWidget);
      expect(find.byKey(const Key('facts_props_readonly_hint')), findsOneWidget);
      expect(find.text('量化档位等属性由主机 setup 时设定，App 端只读。'), findsOneWidget);
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('/config 四 kind 分型渲染', () {
    testWidgets('number/string → TextField，bool/enum → 下拉，初值正确', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await _seedProfile(container, _profile);

      tester.view.physicalSize = const Size(1080, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _warmUpMetrics(tester, container);
      await _warmUpConfig(tester, container);
      await _warmUpProps(tester, container);
      expect(container.read(configProvider).hasValue, isTrue,
          reason: 'configProvider 应成功落定');

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      // 滚动到模型设置卡（ListView 惰性构建）
      await tester.dragUntilVisible(
        find.byKey(const Key('cfg_card')),
        find.byType(Scrollable),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();

      // number：ctx/ngl/temperature 数字输入，初值 = 服务端值
      expect(find.byKey(const Key('cfg_input_ctx')), findsOneWidget);
      expect(find.byKey(const Key('cfg_input_ngl')), findsOneWidget);
      expect(find.byKey(const Key('cfg_input_temperature')), findsOneWidget);
      expect(find.widgetWithText(TextField, '8192'), findsOneWidget);

      // string：host 文本输入，初值 '127.0.0.1:8080'
      expect(find.byKey(const Key('cfg_input_host')), findsOneWidget);
      expect(find.widgetWithText(TextField, '127.0.0.1:8080'), findsOneWidget);

      // bool：flash_attn / mmproj 下拉（default/on/off）
      expect(find.byKey(const Key('cfg_dropdown_flash_attn')), findsOneWidget);
      expect(find.byKey(const Key('cfg_dropdown_mmproj')), findsOneWidget);

      // enum：kv 下拉展开后有 int8/q4_0/fp16
      expect(find.byKey(const Key('cfg_dropdown_kv')), findsOneWidget);
      await tester.tap(find.byKey(const Key('cfg_dropdown_kv')));
      await tester.pumpAndSettle();
      expect(find.text('int8'), findsOneWidget);
      expect(find.text('fp16'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20)); // 收起下拉
      await tester.pumpAndSettle();
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('写确认流程', () {
    testWidgets('改动 → 保存弹确认对话框 → 取消不保存', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await _seedProfile(container, _profile);

      tester.view.physicalSize = const Size(1080, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _warmUpMetrics(tester, container);
      await _warmUpConfig(tester, container);
      await _warmUpProps(tester, container);
      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.byKey(const Key('cfg_input_ctx')),
        find.byType(Scrollable),
        const Offset(0, -400),
      );
      await tester.enterText(find.byKey(const Key('cfg_input_ctx')), '16384');
      await tester.pump();

      // 无改动保存 → 提示「没有改动」（string 空串初值归一为 default，不误发 diff）
      await tester.enterText(find.byKey(const Key('cfg_input_ctx')), '8192');
      await tester.pump();
      await tester.dragUntilVisible(
        find.byKey(const Key('btn_cfg_save')),
        find.byType(Scrollable),
        const Offset(0, -400),
      );
      await tester.tap(find.byKey(const Key('btn_cfg_save')));
      await tester.pump();
      expect(find.text('没有改动'), findsOneWidget);
      await tester.pumpAndSettle(); // 等 SnackBar 退场

      // 有改动 → 确认对话框（.bak 备份文案）
      await tester.enterText(find.byKey(const Key('cfg_input_ctx')), '16384');
      await tester.pump();
      await tester.tap(find.byKey(const Key('btn_cfg_save')));
      await tester.pumpAndSettle();
      expect(find.text('保存模型设置？'), findsOneWidget);
      expect(find.textContaining('.bak'), findsOneWidget);

      // 取消：对话框关闭，未发保存请求
      await tester.tap(find.byKey(const Key('btn_cfg_cancel')));
      await tester.pumpAndSettle();
      expect(find.text('保存模型设置？'), findsNothing);
      expect(find.textContaining('已保存'), findsNothing);
    }, timeout: const Timeout(Duration(seconds: 90)));

    // UI onTap 的网络请求在 fake zone 走不通（_MockHttpOverrides 空 400），
    // 保存成功路径对 client 直连断言（M1-5 范式）
    test('真连 saveConfig：diff 保存 + changed 返回 + GET 复核', () async {
      await realHttp(() async {
        final client = StrataClient(baseUrl: 'http://127.0.0.1:$_port');
        addTearDown(client.close);

        final before = await client.config();
        // v0.0.6：mock /config 新增 context_length 键（8 → 9）
        expect(before.keys.length, 9, reason: 'mock /config 应有 9 个键');
        final ctxBefore = before.keys.firstWhere((k) => k.key == 'ctx').value;
        expect(ctxBefore, 8192);

        final r = await client.saveConfig({'ctx': 16384, 'flash_attn': false});
        expect(r.changed, containsAll(['ctx', 'flash_attn']));

        final after = await client.config();
        expect(after.keys.firstWhere((k) => k.key == 'ctx').value, 16384);
        expect(after.keys.firstWhere((k) => k.key == 'flash_attn').value, isFalse);

        // 幂等：同值再存 → changed 为空
        final r2 = await client.saveConfig({'ctx': 16384});
        expect(r2.changed, isEmpty);
      });
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('API key 保存/恢复', () {
    testWidgets('输入保存 → currentProfile 刷新 + secure storage 持久化', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await _seedProfile(container, _profile);

      await _warmUpMetrics(tester, container);
      // ModelSettings 卡会在滚动后构建：先在真实 zone 预热 configProvider，
      // 避免首帧 fake zone 触发 dio 请求留下 pending timer
      await _warmUpConfig(tester, container);
      await _warmUpProps(tester, container);
      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.byKey(const Key('api_key_card')),
        find.byType(Scrollable),
        const Offset(0, -400),
      );
      // 卡滚进视口后，输入框/按钮均在卡内——直接操作不再滚过头
      await tester.enterText(
          find.byKey(const Key('field_about_apikey')), 'sk-test-456');
      await tester.tap(find.byKey(const Key('btn_apikey_save')), warnIfMissed: false);
      await tester.pumpAndSettle();

      // 反馈 + 会话态刷新（strataClientProvider 随之重建带 Authorization）
      expect(find.text('API key 已保存'), findsOneWidget);
      expect(container.read(currentProfileProvider)!.apiKey, 'sk-test-456');

      // 持久化：secure storage 重新加载，apiKey 保留、其余字段不变
      final stored = await container.read(secureStorageProvider).loadProfiles();
      expect(stored.single.id, _profile.id);
      expect(stored.single.apiKey, 'sk-test-456');
      expect(stored.single.host, '127.0.0.1');
      expect(stored.single.port, _port);
    }, timeout: const Timeout(Duration(seconds: 90)));

    testWidgets('清除 → apiKey 置空持久化', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // 直接 seed 带 key 的 Profile
      final withKey = ConnectionProfile(
        id: 'about-test-$_port',
        name: '测试主机',
        host: '127.0.0.1',
        port: _port,
        apiKey: 'sk-old',
        createdAt: DateTime.now(),
      );
      await _seedProfile(container, withKey);

      await _warmUpMetrics(tester, container);
      await _warmUpConfig(tester, container);
      await _warmUpProps(tester, container);
      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.byKey(const Key('api_key_card')),
        find.byType(Scrollable),
        const Offset(0, -400),
      );
      await tester.tap(find.byKey(const Key('btn_apikey_clear')), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(container.read(currentProfileProvider)!.apiKey, isNull);
      final stored = await container.read(secureStorageProvider).loadProfiles();
      expect(stored.single.apiKey, isNull);
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}

// MonitorScreen 测试（M2-2 完整版）：真连 Mock——在线态全字段渲染断言
// + 不可用降级态（错误文案 + 「打开 WebUI」）+ 轮询生命周期（activate 拉取 /
// deactivate 停止）。
//
// 真连要点（承接日志 0011/0012 范式）：provider 计算在 read/watch 触发时启动，
// 必须发生在 runAsync + realHttp zone；用 container.listen 持续订阅保持
// autoDispose 实例存活，预热落定后再 pumpWidget，UI 直接渲染终态。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strata_mobile_controller/models/connection_profile.dart';
import 'package:strata_mobile_controller/providers/connection_provider.dart';
import 'package:strata_mobile_controller/providers/installed_models_provider.dart';
import 'package:strata_mobile_controller/providers/monitor_provider.dart';
import 'package:strata_mobile_controller/screens/monitor_screen.dart';

import 'helpers/real_http.dart';
import 'helpers/secure_storage_mock.dart';

const _mockScript = '../server-bridge/mock/mock_strata.py';

Process? _mock;

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: MonitorScreen()),
    );

ConnectionProfile _profile(int port) => ConnectionProfile(
      id: 'test-$port',
      name: '测试主机',
      host: '127.0.0.1',
      port: port,
      createdAt: DateTime.now(),
    );

/// 在真实 HTTP zone 预热 metricsProvider 至落定（data 或 error）。
///
/// 不可用端口的失败链 = dio connectTimeout 10s + retryDelays 1/2/4s 共 3 次
/// 重试，全链路可长达 ~37s（M1-7 范式用 35s 上限），故此处按 !isLoading
/// 判定落定并留足 40s；成功路径首次响应即返回。
Future<void> _warmUpMetrics(
    WidgetTester tester, ProviderContainer container) async {
  late final ProviderSubscription sub;
  await tester.runAsync(() => realHttp(() async {
        // 触发计算：activate 会立即 _fetch 一次
        container.read(metricsProvider.notifier).activate();
        sub = container.listen(metricsProvider, (_, _) {});
        for (var i = 0; i < 400; i++) {
          if (!container.read(metricsProvider).isLoading) return;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }));
  addTearDown(sub.close);
}

/// 预热 mcpProvider（FutureProvider.autoDispose——需持续 listen 保活），
/// 否则 UI 首帧在 fake-async zone 无法真连 HTTP，MCP 卡不渲染。
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

/// 预热 installedModelsProvider（v0.0.6 新增卡「已安装模型」）。
///
/// 同样是 autoDispose FutureProvider：不预热则首帧在 fake zone 发起真连
/// 请求，既拿不到数据又留下挂起的 dio timer（A Timer is still pending）。
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

void main() {
  setUpAll(mockSecureStorage);

  setUpAll(() async {
    expect(File(_mockScript).existsSync(), isTrue, reason: '找不到 Mock 脚本（M1-3 产物）');
    _mock = await Process.start('python', [_mockScript, '--port', '8453']);
    _mock!.stdout.transform(systemEncoding.decoder).listen((_) {});
    _mock!.stderr.transform(systemEncoding.decoder).listen((_) {});
    await realHttp(() async {
      final uri = Uri.parse('http://127.0.0.1:8453/health');
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

  testWidgets('在线态：全字段渲染（状态卡/8 指标卡/仪表/内存条/请求表/缓存/累计）', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(currentProfileProvider.notifier).state = _profile(8453);

    // 视口放大：全卡片（含底部 MCP 卡）需在 ListView 可视区构建
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _warmUpMetrics(tester, container);
    await _warmUpMcp(tester, container);
    await _warmUpInstalled(tester, container);
    expect(container.read(metricsProvider).hasValue, isTrue,
        reason: 'metricsProvider 应成功落定');

    await tester.pumpWidget(_app(container));
    await tester.pump();

    // 状态卡：五态彩色圆点徽章（Idle/Reading/Generating/Queued/Error）+ 文案
    expect(find.byKey(const Key('state_card')), findsOneWidget);
    for (final s in const ['idle', 'reading', 'generating', 'queued', 'error']) {
      expect(find.byKey(Key('state_badge_$s')), findsOneWidget, reason: '缺少状态徽章 $s');
    }
    expect(find.text('Model state'), findsOneWidget);
    expect(find.text('Waiting for a request'), findsOneWidget);

    // 速度卡 + 6 指标卡 + sparkline 区
    expect(find.byKey(const Key('metric_speed')), findsOneWidget);
    expect(find.byKey(const Key('speed_decode')), findsOneWidget);
    expect(find.byKey(const Key('speed_prefill')), findsOneWidget);
    for (final k in const [
      'metric_gpu_util', 'metric_gpu_mem', 'metric_gpu_temp',
      'metric_gpu_power', 'metric_pcie', 'metric_cpu', 'metric_disk_read',
    ]) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: '缺少 $k');
    }

    // context 仪表：mock requests 为 appendleft 种子 → first = i=2 条目
    // （1880+96=1976）→ gauge_used = kfmt(1976)/ctxfmt(262144)
    expect(find.byKey(const Key('context_gauge')), findsOneWidget);
    expect(find.byKey(const Key('gauge_pct')), findsOneWidget);
    expect(find.byKey(const Key('gauge_used')), findsOneWidget);
    expect(find.textContaining('2.0k / 256K'), findsOneWidget);
    // webUI 对齐：Context 卡内三条横条
    for (final k in const ['bar_experts_vram', 'bar_system_ram', 'bar_gpu_temp']) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: '缺少 $k');
    }

    // 内存条卡：RAM/VRAM/KV/Experts 四行
    expect(find.byKey(const Key('memory_bars')), findsOneWidget);
    for (final k in const ['bar_ram', 'bar_vram', 'bar_kv', 'bar_expert']) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: '缺少 $k');
    }

    // 请求表：3 条预填（webUI 风格 9 列表格）
    // （种子 finish = stop/length/stop → 两个 Done 徽章 + 一个 Max tokens）
    expect(find.byKey(const Key('requests_card')), findsOneWidget);
    // 未超过 12 条时不显示「Show all (N)」
    expect(find.byKey(const Key('btn_show_all')), findsNothing);
    expect(find.text('Done'), findsNWidgets(2));
    expect(find.text('Max tokens'), findsOneWidget);
    // 9 列表头
    for (final h in const ['TIME', 'STATUS', 'PROMPT', 'REUSED', 'OUTPUT']) {
      expect(find.text(h), findsOneWidget, reason: '缺少表头 $h');
    }

    // conversation cache（mock enabled=true）
    expect(find.byKey(const Key('conv_cache_card')), findsOneWidget);
    expect(find.byKey(const Key('conv_reused')), findsOneWidget);
    expect(find.text('11 of 27 requests reused'), findsOneWidget);

    // totals
    expect(find.byKey(const Key('totals_card')), findsOneWidget);
    expect(find.text('Since start'), findsOneWidget);

    // MCP 卡（mock 有 3 台服务器）
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byKey(const Key('mcp_card')), findsOneWidget);
    expect(find.byKey(const Key('mcp_ready')), findsOneWidget);
    expect(find.text('2/3 ready'), findsOneWidget);
    expect(find.text('filesystem'), findsOneWidget);
    expect(find.text('weather'), findsOneWidget);

    // 在线态不出现离线错误页
    expect(find.byKey(const Key('btn_open_webui')), findsNothing);
    expect(find.byKey(const Key('monitor_error')), findsNothing);
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('不可用态：错误文案 + 「打开 WebUI」兜底按钮', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(currentProfileProvider.notifier).state = _profile(8499); // 端口无服务

    await _warmUpMetrics(tester, container);
    expect(container.read(metricsProvider).hasError, isTrue,
        reason: 'metricsProvider 应失败落定（error-with-previous 落定为首个 error）');

    await tester.pumpWidget(_app(container));
    await tester.pump();

    expect(find.text('监控不可用'), findsOneWidget);
    expect(find.byKey(const Key('monitor_error')), findsOneWidget);
    expect(find.byKey(const Key('btn_open_webui')), findsOneWidget);
    expect(find.textContaining('http://127.0.0.1:8499'), findsOneWidget);

    // 兜底按钮可点击（测试环境无 url_launcher channel，静默失败不崩溃）
    await tester.tap(find.byKey(const Key('btn_open_webui')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('轮询生命周期：activate 拉取，deactivate 停止后不再拉', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(currentProfileProvider.notifier).state = _profile(8453);

    await _warmUpMetrics(tester, container);
    final before = container.read(metricsProvider).value;
    expect(before, isNotNull);

    // 静置 2.5s（轮询周期 1s）：若 timer 活着，totals.since 不变但 hardware 游走，
    // gpu_util 应被刷新（mock _step 持续游走，预填后历史也在动）
    await tester.runAsync(() => realHttp(() async {
          await Future<void>.delayed(const Duration(milliseconds: 2600));
        }));
    final after = container.read(metricsProvider).value;
    // 同一 mock 进程：快照对象应被轮询刷新（新实例）
    expect(identical(before, after), isFalse, reason: '1s 轮询应产生新快照');

    // deactivate → 计数归零停 timer；静置后再读应无新快照
    container.read(metricsProvider.notifier).deactivate();
    final stopped = container.read(metricsProvider).value;
    await tester.runAsync(() => realHttp(() async {
          await Future<void>.delayed(const Duration(milliseconds: 2600));
        }));
    expect(identical(stopped, container.read(metricsProvider).value), isTrue,
        reason: 'deactivate 后轮询应停止');
  }, timeout: const Timeout(Duration(seconds: 90)));
}

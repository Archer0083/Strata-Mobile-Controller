// 401 故障语义分型测试（M2-8.5 真机反馈定位）：
//
// 背景：10-26 真机截图里「监控仪表盘/About 缺位」并非版本滞后，而是运行时
// 降级 + 故障语义错误归因——主机 /health 报 api_key=true，/metrics 返回 401，
// 而 App 端把「除断连外的所有错误」一律降级为「旧版服务器不提供 /metrics」
// （404 的语义）。用户读作「功能没做」。
//
// 本文件锁死两处页面的 401 分型行为：
// - MonitorScreen：显示「需要 API Key」+ 钥匙图标，**不得**显示旧版降级文案
// - AboutScreen：显示「需要 API Key」+ 引导去填 key
//
// 【v0.0.9】ApiMonitorScreen 相关用例已随该页删除而移除（API Monitor 页
// 依赖主机端 svc.api_monitor，默认关闭 → 永远是空页，故 v0.0.9 彻底删除）。
// Load/Unload 能力由「控制」页覆盖，同一份 apiMonitorProvider 数据源。
//
// 全部用假 client override（无网络、无真连 mock 进程）。
//
// 【关键前提】metricsProvider 初始为 loading，**只有 MonitorScreen 的 initState
// 会 activate() 触发首次拉取**。真实 App 里 HomeShell 用 IndexedStack 常驻
// MonitorScreen，故 About 页读到的是已被激活过的 provider。本文件独立渲染
// AboutScreen，必须自行 activate + listen 保活，否则 metrics 永远停在 loading
// 态（这不是被测行为，属测试前置条件）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strata_mobile_controller/models/api_models.dart';
import 'package:strata_mobile_controller/models/metrics_snapshot.dart';
import 'package:strata_mobile_controller/models/strata_models.dart';
import 'package:strata_mobile_controller/providers/connection_provider.dart';
import 'package:strata_mobile_controller/providers/monitor_provider.dart';
import 'package:strata_mobile_controller/screens/about_screen.dart';
import 'package:strata_mobile_controller/screens/monitor_screen.dart';
import 'package:strata_mobile_controller/services/strata_client.dart';

import 'helpers/secure_storage_mock.dart';

/// /metrics 与 /api/requests 一律 401 的假 client。
///
/// health / listModels 给正常值：monitorProvider（health+models）是 404 降级
/// 骨架 _LegacyBody 的数据源，若它先炸在 health 上，404 用例会误落到离线视图
/// 而看不到旧版降级文案。
///
/// 【v0.0.6】installedModels 也一并 override：MonitorScreen 新增的
/// 「已安装模型」卡会在 fake zone 触发真连请求，留下挂起的 dio timer
/// （A Timer is still pending）。本文件测降级文案分型，不测模型卡。
class _UnauthorizedClient extends StrataClient {
  _UnauthorizedClient() : super(baseUrl: 'http://unused');

  @override
  Future<HealthInfo> health() async {
    return const HealthInfo(status: 'ok', model: 'test-model', uptimeSeconds: 42);
  }

  @override
  Future<List<ModelInfo>> listModels() async {
    return const [ModelInfo(id: 'test-model')];
  }

  @override
  Future<MetricsSnapshot> metrics({bool allRequests = false}) async {
    throw const StrataUnauthorizedException('401');
  }

  @override
  Future<ApiMonitorList> apiRequests() async {
    throw const StrataUnauthorizedException('401');
  }

  @override
  Future<InstalledModels> installedModels() async {
    throw const StrataUnauthorizedException('401');
  }
}

/// /metrics 404（旧版服务器）的假 client：对照组——确认 404 仍走旧版降级。
class _NotFoundClient extends StrataClient {
  _NotFoundClient() : super(baseUrl: 'http://unused');

  @override
  Future<HealthInfo> health() async {
    return const HealthInfo(status: 'ok', model: 'test-model', uptimeSeconds: 42);
  }

  @override
  Future<List<ModelInfo>> listModels() async {
    return const [ModelInfo(id: 'test-model')];
  }

  @override
  Future<MetricsSnapshot> metrics({bool allRequests = false}) async {
    throw const StrataNotFoundException('404');
  }

  @override
  Future<InstalledModels> installedModels() async {
    throw const StrataNotFoundException('404');
  }
}

/// 激活 metricsProvider 并等它落到终态（error 或 data）。
///
/// 与 about_screen_test 的 _warmUpMetrics 同范式，但等待条件改为
/// 「有 error 或有 value」而非 !isLoading——本文件测的正是 error 态。
Future<void> _activateMetrics(
    WidgetTester tester, ProviderContainer container) async {
  late final ProviderSubscription sub;
  await tester.runAsync(() async {
    container.read(metricsProvider.notifier).activate();
    sub = container.listen(metricsProvider, (_, _) {});
    for (var i = 0; i < 100; i++) {
      final v = container.read(metricsProvider);
      if (v.hasError || v.valueOrNull != null) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
  addTearDown(sub.close);
}

void main() {
  setUpAll(mockSecureStorage);

  testWidgets('MonitorScreen：/metrics 401 → 「需要 API Key」，非旧版降级', (tester) async {
    final container = ProviderContainer(overrides: [
      strataClientProvider.overrideWith((ref) => _UnauthorizedClient()),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: MonitorScreen()),
    ));
    // MonitorScreen.initState 用 addPostFrameCallback 调 activate()，
    // 首拉落在 post-frame 之后的微任务里——多 pump 几轮让它落定。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('需要 API Key'), findsOneWidget);
    // 关键回归断言：401 绝不能被误报成「旧版没有 /metrics」
    expect(find.textContaining('该服务器版本不提供'), findsNothing);
    expect(find.byIcon(Icons.key), findsOneWidget);
  });

  testWidgets('MonitorScreen：/metrics 404 → 仍走旧版降级骨架（对照组）', (tester) async {
    final container = ProviderContainer(overrides: [
      strataClientProvider.overrideWith((ref) => _NotFoundClient()),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: MonitorScreen()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 【v0.0.7 断言更新】降级文案不再笼统写「该服务器版本不提供
    // /metrics」（真机反馈：同主机 webUI 正常，笼统旧版论无法定位），
    // 改为如实分型 + 请求地址 + webUI 对照提示。404 语义不变。
    expect(find.textContaining('详细监控数据加载失败'), findsOneWidget);
    expect(find.textContaining('接口不存在'), findsOneWidget);
    expect(find.text('需要 API Key'), findsNothing);
  });

  testWidgets('AboutScreen：/metrics 404 → 回落「/metrics 未就绪」（对照组）', (tester) async {
    final container = ProviderContainer(overrides: [
      strataClientProvider.overrideWith((ref) => _NotFoundClient()),
    ]);
    addTearDown(container.dispose);

    await _activateMetrics(tester, container);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: AboutScreen()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 【v0.0.7 断言更新】About 的 404 空态不再断言「版本不提供」（笼统
    // 归因被真机反馈证伪），改为中性「主机未返回 /metrics 数据」+ 错误
    // 摘要（假 client 抛 StrataNotFoundException('404')，detail 含其文本）。
    expect(find.textContaining('主机未返回 /metrics 数据'), findsOneWidget);
    expect(find.textContaining('404'), findsOneWidget);
    expect(find.text('需要 API Key'), findsNothing);
  });

  testWidgets('AboutScreen：/metrics 401 → 「需要 API Key」+ 引导填 key', (tester) async {
    final container = ProviderContainer(overrides: [
      strataClientProvider.overrideWith((ref) => _UnauthorizedClient()),
    ]);
    addTearDown(container.dispose);

    await _activateMetrics(tester, container);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: AboutScreen()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('需要 API Key'), findsOneWidget);
    // 【2026-10-27 更新断言】原先期望「引导去『关于与服务』填 key」，
    // 但缺陷 C 的修复把补 key 入口**就地内嵌**到 About 页的 401 空态里
    // （ApiKeyCard 直接渲染在故障态下方），文案改为「在下方填入并保存，
    // 无需返回上页」——因为旧文案会让用户去设置页绕一圈，正是真机反馈
    // 「填了一次 api key 还是看不到主机状态」的死锁来源。
    // 故此处断言「就地修复路径存在」，而非旧版跳转指引。
    expect(find.textContaining('在下方填入并保存'), findsOneWidget);
    expect(find.byKey(const Key('field_about_apikey')), findsOneWidget,
        reason: '401 空态必须自带填 key 入口，不能把用户赶回设置页');
    // 旧文案「/metrics 未就绪」不得出现
    expect(find.textContaining('/metrics 未就绪'), findsNothing);
  });
}
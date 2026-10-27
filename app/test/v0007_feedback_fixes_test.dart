// v0.0.7 测试（第八轮真机反馈：监控/About 降级讲真话 + 截图分片 + 导出命名）
//
// 覆盖本轮四项修复：
//   1. StrataClient 默认请求头复刻 webUI 姿态（Origin/Referer/Accept）
//   2. 截图分片：短内容单片、长内容多片（GPU 纹理上限规避）、PNG 魔数
//   3. 单条导出命名带内容摘要（messageExcerpt + .md/.png 文件名）
//   4. /metrics 失败时：监控页降级文案按异常分型讲真话；About 页降级
//      基础信息卡（/v1/status + /props 真连 mock）
//
// 端口：8523——与既有测试隔离（chat 8463/8464、connection 8473/8474、
// client 8471/8472、monitor 8453、about 8483、apis 8493/8494、
// control 8503/8504、v0006 8513/8514）。
//
// 运行：cd app; ../tools/fl.ps1 test test/v0007_feedback_fixes_test.dart

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strata_mobile_controller/models/connection_profile.dart';
import 'package:strata_mobile_controller/models/metrics_snapshot.dart';
import 'package:strata_mobile_controller/providers/connection_provider.dart';
import 'package:strata_mobile_controller/providers/installed_models_provider.dart';
import 'package:strata_mobile_controller/providers/monitor_provider.dart';
import 'package:strata_mobile_controller/screens/about_screen.dart';
import 'package:strata_mobile_controller/screens/monitor_screen.dart';
import 'package:strata_mobile_controller/services/export_service.dart';
import 'package:strata_mobile_controller/services/screenshot_service.dart';
import 'package:strata_mobile_controller/services/strata_client.dart';

import 'helpers/real_http.dart';
import 'helpers/secure_storage_mock.dart';

const _mockScript = '../server-bridge/mock/mock_strata.py';
const _port = 8523;

Process? _mock;

ConnectionProfile get _profile => ConnectionProfile(
      id: 'v0007-$_port',
      name: '测试主机',
      host: '127.0.0.1',
      port: _port,
      apiKey: null,
      createdAt: DateTime.now(),
    );

/// metrics 轮询的失败替身：build 即落 404 错误态；activate/refresh 置空
/// （防 MonitorScreen 触发真 timer / 真请求——fake zone 会 400）
class _NotFoundMetrics extends MetricsPolling {
  @override
  AsyncValue<MetricsSnapshot> build() {
    return AsyncValue<MetricsSnapshot>.error(
        const StrataNotFoundException('接口不存在：/metrics'), StackTrace.current);
  }

  @override
  void activate() {}

  @override
  Future<void> refresh() async {}
}

/// seed：secure storage 写入 Profile 并激活
Future<void> _seed(WidgetTester tester, ProviderContainer container) async {
  await tester.runAsync(() => realHttp(() async {
        await container.read(secureStorageProvider).saveProfiles([_profile]);
        container.read(currentProfileProvider.notifier).state = _profile;
      }));
}

/// 预热 monitorProvider（_LegacyBody 的存活卡数据源，autoDispose）
Future<void> _warmMonitor(
    WidgetTester tester, ProviderContainer container) async {
  late final ProviderSubscription sub;
  await tester.runAsync(() => realHttp(() async {
        sub = container.listen(monitorProvider, (_, _) {});
        for (var i = 0; i < 100; i++) {
          if (!container.read(monitorProvider).isLoading) return;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }));
  addTearDown(sub.close);
}

/// 预热 installedModelsProvider（降级骨架里 InstalledModelsCard 数据源）
Future<void> _warmInstalled(
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

/// 预热 aboutFallbackProvider（About 降级卡数据源，autoDispose 首拉
/// 必须在真实 HTTP zone 发起——fake zone 一律 400 → 两源皆 null → 卡片隐藏）
Future<void> _warmAboutFallback(
    WidgetTester tester, ProviderContainer container) async {
  late final ProviderSubscription sub;
  await tester.runAsync(() => realHttp(() async {
        sub = container.listen(aboutFallbackProvider, (_, _) {});
        for (var i = 0; i < 100; i++) {
          if (!container.read(aboutFallbackProvider).isLoading) return;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }));
  addTearDown(sub.close);
}

// ─────────────────────────────────────────────────────────────
// 组 1：纯单测（不起 mock）
// ─────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(mockSecureStorage);

  group('messageExcerpt（v0.0.7 导出命名）', () {
    test('普通文本原样保留（≤16 字）', () {
      expect(ExportService.messageExcerpt('你好，帮我写一段排序代码'), '你好，帮我写一段排序代码');
    });

    test('Markdown 标记被剥离', () {
      expect(ExportService.messageExcerpt('## 标题\n\n正文开始'), '标题');
      expect(ExportService.messageExcerpt('> 引用的思考行'), '引用的思考行');
    });

    test('超长截断且以 … 结尾（按字素不切半个字）', () {
      final out = ExportService.messageExcerpt('这是一段非常长的回复内容' * 5);
      expect(out.endsWith('…'), isTrue);
      // 16 字素 + 省略号
      expect(out.charactersCount, 17);
    });

    test('空内容与纯空白回退空串', () {
      expect(ExportService.messageExcerpt(''), '');
      expect(ExportService.messageExcerpt('  \n \n '), '');
    });

    test('文件名非法字符被清洗', () {
      final out = ExportService.messageExcerpt('a/b:c*d?"<>|e');
      expect(out, isNot(contains('/')));
      expect(out, isNot(contains(':')));
      expect(out, isNot(contains('?')));
    });
  });

  group('exportMessageMarkdown 文件名带摘要（v0.0.7）', () {
    test('文件名含内容摘要', () {
      final r = ExportService().exportMessageMarkdown(
        isUser: false,
        content: '量子计算的基础是量子比特',
        timestamp: DateTime(2026, 10, 28, 9, 30),
      );
      expect(r.fileName, startsWith('Strata消息-模型-量子计算的基础是量子比特-'));
      expect(r.fileName, endsWith('.md'));
    });

    test('空内容回退旧命名格式（不带空摘要段）', () {
      final r = ExportService().exportMessageMarkdown(
        isUser: true,
        content: '',
      );
      expect(r.fileName, matches(RegExp(r'^Strata消息-我-\d{8}-\d{4}\.md$')));
    });
  });

  group('StrataClient 默认请求头复刻 webUI 姿态（v0.0.7）', () {
    test('Origin/Referer/Accept 随 baseUrl 设置', () {
      final dio = Dio();
      StrataClient(baseUrl: 'http://10.9.0.18:8080/', apiKey: 'k', dio: dio);
      expect(dio.options.headers['Origin'], 'http://10.9.0.18:8080');
      expect(dio.options.headers['Referer'], 'http://10.9.0.18:8080/');
      expect(dio.options.headers['Accept'], 'application/json');
    });
  });

  group('ScreenshotService 分片渲染（v0.0.7 GPU 纹理上限规避）', () {
    // 注入字体加载器返回 null：回退默认字体（测试环境 Ahem 方块字，
    // 每字符等宽等高——高度可控，便于构造超限内容）
    ScreenshotService svc() => ScreenshotService(
          cjkFontLoader: () async => null,
        );

    testWidgets('短内容 → 单片 PNG，文件名无分片后缀', (tester) async {
      late final List<ExportResult> results;
      await tester.runAsync(() async {
        results = await svc().renderMessagePngs(
          isUser: false,
          content: '短回复',
          timestamp: DateTime(2026, 10, 28, 9, 30),
        );
      });
      expect(results, hasLength(1));
      expect(results.first.fileName, endsWith('.png'));
      expect(results.first.fileName, isNot(contains('第')));
      // PNG 魔数
      expect(results.first.bytes[0], 0x89);
      expect(String.fromCharCodes(results.first.bytes.sublist(1, 4)), 'PNG');
    });

    testWidgets('超长内容 → 多片，文件名带 -第N部分，均为合法 PNG',
        (tester) async {
      late final List<ExportResult> results;
      await tester.runAsync(() async {
        results = await svc().renderMessagePngs(
          isUser: false,
          content: '长' * 3000, // 测试字体下排版高度远超 3800px 单片上限
          reasoning: '思考' * 500,
        );
      });
      expect(results.length, greaterThanOrEqualTo(2),
          reason: '超长内容必须分片，否则真机 toImage 超纹理上限必失败');
      for (var i = 0; i < results.length; i++) {
        expect(results[i].fileName, contains('-第${i + 1}部分'));
        expect(results[i].bytes[0], 0x89);
        expect(String.fromCharCodes(results[i].bytes.sublist(1, 4)), 'PNG');
      }
      // 文件名带内容摘要
      expect(results.first.fileName, contains('长'));
    });
  });

  // ───────────────────────────────────────────────────────────
  // 组 2：真连 mock —— /metrics 失败的降级视图
  // ───────────────────────────────────────────────────────────

  setUpAll(() async {
    expect(File(_mockScript).existsSync(), isTrue,
        reason: '找不到 Mock 脚本（M1-3 产物）');
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

  testWidgets('监控页降级文案按异常分型讲真话（404 → 接口不存在 + webUI 对照提示）',
      (tester) async {
    final container = ProviderContainer(overrides: [
      metricsProvider.overrideWith(() => _NotFoundMetrics()),
    ]);
    addTearDown(container.dispose);
    await _seed(tester, container);
    await _warmMonitor(tester, container);
    await _warmInstalled(tester, container);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: MonitorScreen()),
    ));
    await tester.pump();

    final reason = find.byKey(const Key('metrics_fallback_reason'));
    expect(reason, findsOneWidget);
    final text = tester.widget<Text>(reason).data!;
    expect(text, contains('接口不存在'));
    expect(text, contains('http://127.0.0.1:$_port'));
    expect(text, contains('#monitor'));
    // 基础监控仍在（存活卡）
    expect(find.text('在线'), findsOneWidget);
  });

  testWidgets('About 页 /metrics 失败 → 降级基础信息卡（/v1/status + /props）',
      (tester) async {
    final container = ProviderContainer(overrides: [
      metricsProvider.overrideWith(() => _NotFoundMetrics()),
    ]);
    addTearDown(container.dispose);
    await _seed(tester, container);
    await _warmAboutFallback(tester, container);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: AboutScreen()),
    ));

    // 降级视图上屏
    await _waitKey(tester, const Key('about_unavailable'));
    // 基础信息卡（真连 mock 的 /v1/status 与 /props）
    await _waitKey(tester, const Key('about_fallback_card'));
    expect(find.text('基础信息'), findsOneWidget);
    // 【v0.0.9】降级视图下也有两张卡：基础信息卡 + 开发者卡（GitHub@Archer0083）
    expect(find.byType(Card), findsNWidgets(2));
    expect(find.byKey(const Key('card_developer')), findsOneWidget);
  });
}

/// 轮询等待某 key 的 widget 渲染（真连 mock 首拉落定慢）
Future<void> _waitKey(WidgetTester tester, Key key) async {
  for (var i = 0; i < 150; i++) {
    if (find.byKey(key).evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 20));
  }
  fail('widget $key 未渲染');
}

/// 测试辅助：字符计数（中文一字一 rune；测试文本不含组合字素）
extension _Chars on String {
  int get charactersCount {
    var n = 0;
    for (final _ in runes) {
      n++;
    }
    return n;
  }
}

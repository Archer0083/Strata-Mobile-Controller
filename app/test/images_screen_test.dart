// ImagesScreen 测试（M2-6）：对 Mock 真连 /v1/images/generations。
//
// 测试分层（fake-zone 400 干扰规避，见 0027 经验）：
// 1. 【API 层真连】generateImage 对 Mock 断言（runAsync + realHttp 双保险）：
//    b64_json 有效 PNG + seed 回显 + size 回显
// 2. 【API 层真连】能力门控口径：/health image_generation=true（mock 默认）
// 3. 【UI 层 override】imageGenEnabledProvider 显隐：关 → 未配置空态
// 4. 【UI 层】空 prompt：Generate 不发请求（web !prompt return 口径）
// 5. 【UI 层 override】生成流程：fake client 返回 PNG → prepend + caption 口径
//
// UI 层用 override 注入而非真连：fake zone 下 monitorProvider 拉取会先
// 撞 _MockHttpOverrides 的 400（即时抛错），永远到不了真连分支。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strata_mobile_controller/models/api_models.dart';
import 'package:strata_mobile_controller/providers/connection_provider.dart';
import 'package:strata_mobile_controller/screens/images_screen.dart';
import 'package:strata_mobile_controller/services/strata_client.dart';

import 'helpers/real_http.dart';

const _mockScript = '../server-bridge/mock/mock_strata.py';

Process? _mock;

// ─────────────────────────────────────────────────────────────
// Fake client：UI 层生成流程注入（同响应 shape）
// ─────────────────────────────────────────────────────────────

class _FakeImageClient implements StrataClient {
  _FakeImageClient(this.image);

  final GeneratedImage Function(String prompt, String size, int? seed) image;

  @override
  Future<GeneratedImage> generateImage({
    required String prompt,
    String size = '1024x1024',
    int? seed,
  }) async => image(prompt, size, seed);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 1×1 PNG（社区标准透明像素，base64 合法，Image.memory 可正常解码；
/// 不能手拼 CRC 任填的字节——Skia 解码失败抛 FlutterError 会挂测试）
const _tinyPngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

Widget _app(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: ImagesScreen()),
  );
}

/// 轮询等待 busy 落回 false（fake async 下用 tester.pump 推进，
/// 不能用 Future.delayed——真延时在 fake zone 永不完成会死锁）
Future<void> _waitNotBusy(WidgetTester tester, {int maxPumps = 200}) async {
  for (var i = 0; i < maxPumps; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (!tester.any(find.byKey(const Key('img_hint_busy')))) return;
  }
  fail('等待生成完成超时');
}

void main() {
  setUpAll(() async {
    expect(File(_mockScript).existsSync(), isTrue, reason: '找不到 Mock 脚本');
    _mock = await Process.start('python', [_mockScript, '--port', '8465']);
    _mock!.stdout.transform(systemEncoding.decoder).listen((_) {});
    _mock!.stderr.transform(systemEncoding.decoder).listen((_) {});
    await realHttp(() async {
      final uri = Uri.parse('http://127.0.0.1:8465/health');
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

  tearDownAll(() => _mock?.kill());

  test('【API 真连】/health image_generation=true（mock 默认开）', () async {
    await realHttp(() async {
      final client = StrataClient(baseUrl: 'http://127.0.0.1:8465');
      final h = await client.health();
      expect(h.status, 'ok');
      expect(h.imageGeneration, isTrue, reason: 'mock /health 默认 image_generation=true');
    });
  });

  test('【API 真连】generateImage：b64 有效 PNG + seed 回显 + size 回显', () async {
    await realHttp(() async {
      final client = StrataClient(baseUrl: 'http://127.0.0.1:8465');
      // mock parse_size 有 cap=256 防 CPU 爆炸，用 ≤256 的档位验证回显
      final img = await client.generateImage(prompt: 'a cat', seed: 42, size: '128x128');
      expect(img.size, '128x128');
      expect(img.seed, 42);
      // b64 解码为合法 PNG（魔数校验，mock stdlib PNG 编码）
      final bytes = base64Decode(img.b64Json);
      expect(bytes.length, greaterThan(8));
      expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47], reason: 'PNG 魔数');
    });
  });

  testWidgets('【UI override】能力关：未配置空态（web tab 门控同口径）', (tester) async {
    final container = ProviderContainer(overrides: [
      imageGenEnabledProvider.overrideWith((ref) => false),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('img_form')), findsNothing);
    expect(find.text('此主机未配置生图（setup 时需 --images qwen-image）'), findsOneWidget);
  });

  testWidgets('【UI override】空 prompt：Generate 不发请求', (tester) async {
    var called = 0;
    final container = ProviderContainer(overrides: [
      imageGenEnabledProvider.overrideWith((ref) => true),
      strataClientProvider.overrideWith((ref) => _FakeImageClient((p, s, seed) {
            called++;
            return GeneratedImage(b64Json: _tinyPngB64, seed: seed, size: s);
          })),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('img_go')));
    await tester.pumpAndSettle();

    expect(called, 0, reason: 'web !prompt return：空 prompt 不发请求');
    expect(find.byKey(const Key('img_caption')), findsNothing);
  });

  testWidgets('【UI override】生成流程：结果 prepend + caption 口径', (tester) async {
    final container = ProviderContainer(overrides: [
      imageGenEnabledProvider.overrideWith((ref) => true),
      strataClientProvider.overrideWith((ref) => _FakeImageClient((p, s, seed) {
            return GeneratedImage(b64Json: _tinyPngB64, seed: 7, size: s);
          })),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('img_prompt')), 'a cat');
    await tester.pump();

    await tester.tap(find.byKey(const Key('img_go')));
    await tester.pump();
    await _waitNotBusy(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('img_caption')), findsOneWidget);
    final caption =
        tester.widget<Text>(find.byKey(const Key('img_caption'))).data!;
    // web figcaption：`{size}, seed {seed}, {secs} s: {prompt}`
    expect(caption, startsWith('1024x1024, seed 7, '));
    expect(caption, endsWith(' s: a cat'));
    expect(find.byKey(const Key('img_result_7')), findsOneWidget);
  });
}

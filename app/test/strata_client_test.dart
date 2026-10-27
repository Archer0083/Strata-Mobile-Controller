// StrataClient 集成单测（M1-4）：对 server-bridge/mock 的真实 HTTP/SSE 验证。
// setUpAll 启动两个 Mock 实例（无鉴权 8471 / 鉴权 8472），tearDownAll 统一回收。
// 运行前置：PATH 里有 python（见 server-bridge/mock/README.md）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:strata_mobile_controller/models/api_models.dart';
import 'package:strata_mobile_controller/models/strata_models.dart';
import 'package:strata_mobile_controller/services/strata_client.dart';

const _mockScript = '../server-bridge/mock/mock_strata.py'; // flutter test 的 cwd = app/，Mock 在仓库根
const _urlA = 'http://127.0.0.1:8471'; // 无鉴权实例
const _urlB = 'http://127.0.0.1:8472'; // 鉴权实例（sk-test-123）

Process? _mockA;
Process? _mockB;

Future<void> _waitReady(StrataClient client) async {
  for (var i = 0; i < 50; i++) {
    try {
      await client.health();
      return;
    } on Exception {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  fail('Mock 服务 10s 内未就绪');
}

void _drain(Stream<List<int>>? out) {
  // mock 的 log_message 每请求打一行；管道写满会让 Python 进程整体冻结
  //（全量跑时表现为第 N 个请求挂到 30s 超时）→ 持续丢弃输出防阻塞。
  out?.listen((_) {});
}

void main() {
  setUpAll(() async {
    expect(File(_mockScript).existsSync(), isTrue, reason: '找不到 Mock 脚本，请先完成 M1-3');
    _mockA = await Process.start('python', [_mockScript, '--port', '8471']);
    _mockB = await Process.start('python', [_mockScript, '--port', '8472', '--api-key', 'sk-test-123']);
    _drain(_mockA?.stdout);
    _drain(_mockB?.stdout);
    _drain(_mockA?.stderr);
    _drain(_mockB?.stderr);
    await _waitReady(StrataClient(baseUrl: _urlA, retryDelays: const [Duration(milliseconds: 300)]));
  });

  tearDownAll(() async {
    _mockA?.kill();
    _mockB?.kill();
    await _mockA?.exitCode.catchError((_) => -1);
    await _mockB?.exitCode.catchError((_) => -1);
  });

  group('短请求（health / models）', () {
    test('health 返回 ok 与模型名', () async {
      final client = StrataClient(baseUrl: _urlA);
      addTearDown(client.close);
      final h = await client.health();
      expect(h.status, 'ok');
      expect(h.model, 'qwen3.8-flash-next');
    });

    test('listModels 返回单模型 qwen3.8-flash-next', () async {
      final client = StrataClient(baseUrl: _urlA);
      addTearDown(client.close);
      final models = await client.listModels();
      expect(models, hasLength(1));
      expect(models.first.id, 'qwen3.8-flash-next');
    });

    test('401 → StrataUnauthorizedException（错误 API Key）', () async {
      final client = StrataClient(baseUrl: _urlB, apiKey: 'wrong-key');
      addTearDown(client.close);
      await expectLater(client.listModels(), throwsA(isA<StrataUnauthorizedException>()));
    });

    test('401 → StrataUnauthorizedException（应带 Key 而未带）', () async {
      final client = StrataClient(baseUrl: _urlB); // B 实例强制鉴权，未带 key
      addTearDown(client.close);
      await expectLater(client.health(), throwsA(isA<StrataUnauthorizedException>()));
    });

    test('连接失败（端口无服务）→ StrataConnectionException', () async {
      final client = StrataClient(
        baseUrl: 'http://127.0.0.1:8499',
        retryDelays: const [Duration(milliseconds: 100), Duration(milliseconds: 100)],
      );
      addTearDown(client.close);
      await expectLater(client.listModels(), throwsA(isA<StrataConnectionException>()));
    });
  });

  group('非流式对话', () {
    test('effort=medium：含思考内容与正文', () async {
      final client = StrataClient(baseUrl: _urlA);
      addTearDown(client.close);
      final r = await client.chat(
        messages: const [ChatMessageRequest(role: 'user', content: '你好')],
        effort: ReasoningEffort.medium,
      );
      expect(r.content, contains('收到你的消息'));
      expect(r.reasoningContent, isNotEmpty);
      expect(r.usage!.totalTokens, greaterThan(0));
    });

    test('effort=none：无思考内容', () async {
      final client = StrataClient(baseUrl: _urlA);
      addTearDown(client.close);
      final r = await client.chat(
        messages: const [ChatMessageRequest(role: 'user', content: '你好')],
        effort: ReasoningEffort.none,
      );
      expect(r.content, isNotEmpty);
      expect(r.reasoningContent, isNull);
    });

    test('空 messages → 400 → StrataBadRequestException', () async {
      final client = StrataClient(baseUrl: _urlA);
      addTearDown(client.close);
      await expectLater(
        client.chat(messages: const [], effort: ReasoningEffort.low),
        throwsA(isA<StrataBadRequestException>()),
      );
    });
  });

  group('流式对话（SSE 解析）', () {
    test('effort=low：reasoning → content → finished(usage) 事件序完整', () async {
      final client = StrataClient(baseUrl: _urlA);
      addTearDown(client.close);
      final events = await client
          .chatStream(
            messages: const [ChatMessageRequest(role: 'user', content: '你好，流式测试')],
            effort: ReasoningEffort.low,
          )
          .toList();

      final reasoning = events.whereType<ReasoningDeltaEvent>().map((e) => e.text).join();
      final content = events.whereType<ContentDeltaEvent>().map((e) => e.text).join();
      final finished = events.whereType<FinishedEvent>().toList();

      expect(reasoning, isNotEmpty); // low 档有思考
      expect(content, contains('收到你的消息'));
      expect(content, contains('思考档位 low'));
      expect(finished, hasLength(1));
      expect(finished.single.usage!.totalTokens, greaterThan(0));
      // 事件序：所有 reasoning 在所有 content 之前
      final lastReasoningIdx = events.lastIndexWhere((e) => e is ReasoningDeltaEvent);
      final firstContentIdx = events.indexWhere((e) => e is ContentDeltaEvent);
      expect(lastReasoningIdx, lessThan(firstContentIdx));
    });

    test('effort=none：无 reasoning 事件', () async {
      final client = StrataClient(baseUrl: _urlA);
      addTearDown(client.close);
      final events = await client
          .chatStream(
            messages: const [ChatMessageRequest(role: 'user', content: '你好')],
            effort: ReasoningEffort.none,
          )
          .toList();
      expect(events.whereType<ReasoningDeltaEvent>(), isEmpty);
      expect(events.whereType<ContentDeltaEvent>(), isNotEmpty);
      expect(events.whereType<FinishedEvent>(), isNotEmpty);
    });

    test('流式 401 → 异常事件（错误 Key 不重试不吞错）', () async {
      final client = StrataClient(baseUrl: _urlB, apiKey: 'wrong-key');
      addTearDown(client.close);
      final events = <ChatStreamEvent>[];
      Object? caught;
      try {
        await for (final e in client.chatStream(
          messages: const [ChatMessageRequest(role: 'user', content: '你好')],
          effort: ReasoningEffort.low,
        )) {
          events.add(e);
        }
      } catch (err) {
        caught = err;
      }
      expect(events, isEmpty, reason: '401 时不应产生任何 delta 事件');
      expect(caught, isA<StrataUnauthorizedException>());
    });

    test('中文与多字节字符跨 chunk 正确解码', () async {
      final client = StrataClient(baseUrl: _urlA);
      addTearDown(client.close);
      final events = await client
          .chatStream(
            messages: const [ChatMessageRequest(role: 'user', content: '中文内容跨块完整性测试')],
            effort: ReasoningEffort.high,
          )
          .toList();
      final content = events.whereType<ContentDeltaEvent>().map((e) => e.text).join();
      // Mock 正文模板含中文标点与全角引号，验证逐字节切行 + 完整行 utf8 解码无乱码
      expect(content, contains('「中文内容跨块完整性测试」'));
      expect(content, contains('。'));
    });
  });

  group('M2-7 运维端点（props / load / unload）', () {
    test('props：mock 键四字段 + contextLength', () async {
      final client = StrataClient(baseUrl: _urlA);
      addTearDown(client.close);
      final p = await client.props();
      expect(p.model, 'qwen3.8-flash-next');
      expect(p.quantization, 'IQ2_XS');
      expect(p.contextLength, 262144);
      expect(p.hostMode, 'mock');
      expect(p.hasAny, isTrue);
    });

    test('unload(wait)→load：loaded 状态往返 + wait 透传 200', () async {
      final client = StrataClient(baseUrl: _urlA);
      addTearDown(client.close);
      // 初始 loaded=true（mock STATE）；unload 带 wait → loaded=false
      await client.unloadEngine(waitSeconds: 120);
      final s1 = await client.engineStatus();
      expect(s1.loaded, isFalse, reason: 'unload 后应 Unloaded');
      // load 恢复
      await client.loadEngine();
      final s2 = await client.engineStatus();
      expect(s2.loaded, isTrue);
    });

    test('unload 不带 wait：200 正常', () async {
      final client = StrataClient(baseUrl: _urlA);
      addTearDown(client.close);
      await client.unloadEngine();
      await client.loadEngine(); // 状态复位，隔离后续用例
    });

    test('EngineProps.fromJson 双组键容错：真实 server 键也解出', () {
      // 真实 server _props() 形态（server.py L6935-6960）
      final p = EngineProps.fromJson({
        'model_alias': 'qwen3.8-flash-next',
        'default_generation_settings': {'n_ctx': 262144},
        'total_slots': 4,
        'build_info': 'b6231(2d0c)',
        'model_path': '/models/qwen3-IQ2_XS.gguf',
        'modalities': {'vision': false},
      });
      expect(p.model, 'qwen3.8-flash-next');
      expect(p.quantization, isNull);
      expect(p.contextLength, 262144);
      expect(p.totalSlots, 4);
      expect(p.buildInfo, 'b6231(2d0c)');
      expect(p.modelPath, contains('IQ2_XS'));
      expect(p.hasAny, isTrue);
    });
  });
}

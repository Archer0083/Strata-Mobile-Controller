// SSE 解析层回归单测（M1-11 内测反馈修复）
//
// 【为什么需要这个文件】
// v0.0.1 内测出现「对话只返回一个占位符、看不到思维链与正文、且无任何报错」。
// 根因排查结论：客户端字段名本就正确（与上游 Strata 源码一致），缺陷全在解析层——
//   ① `on FormatException {}` 静默吞掉坏行；
//   ② `utf8.decode` 未加 allowMalformed，多字节字符被切断时抛的异常不在 catch 覆盖内；
//   ③ 尾块 choices 非空时 usage 永远取不到（上游 Strata 与 OpenAI 规范形态不同）；
//   ④ 助手的 reasoning_content 未随历史回传。
//
// 【本文件的定位】
// 之前所有 SSE 单测都打 Mock，而 Mock 是照客户端期望逆向构造的 → 形成「自证循环」，
// 对真实形态零覆盖力。本文件用**原始字节**构造响应，直钉死上游 Strata 的真实 wire format，
// 不依赖 Mock，且刻意包含各种畸形输入来验证「不再静默失败」。
//
// 依据：上游 serve/server.py:5849/5866/5868/7180/7182/7184/5887-5892、serve/frontend.py:130-167。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:strata_mobile_controller/models/strata_models.dart';
import 'package:strata_mobile_controller/services/strata_client.dart';

/// 启动一个「裸字节」HTTP 服务：按原始字节返回给定的 SSE 响应体。
/// 不做任何 JSON 构造——保证测试的是**字节级真实形态**。
Future<HttpServer> _startRawServer(String sseBody, {int status = 200}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    // 消费请求体，避免客户端写阻塞
    await request.drain<void>();
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
    request.response.headers.set('Cache-Control', 'no-cache');
    request.response.write(sseBody);
    await request.response.close();
  });
  return server;
}

String _baseUrl(HttpServer s) => 'http://127.0.0.1:${s.port}';

/// 构造上游 Strata 真实形态的一个 chunk 行（不含换行）
String _chunk(Map<String, dynamic> delta, {String? finish}) {
  final body = {
    'id': 'chatcmpl-test',
    'object': 'chat.completion.chunk',
    'created': 1760000000,
    'model': 'qwen3.8-flash-next',
    'choices': [
      {'index': 0, 'delta': delta, 'finish_reason': finish},
    ],
  };
  return 'data: ${jsonEncode(body)}';
}

/// 上游 Strata 尾块：choices **非空**（含 finish_reason），usage 挂在块顶层
String _tailChunk() {
  final body = {
    'id': 'chatcmpl-test',
    'object': 'chat.completion.chunk',
    'created': 1760000000,
    'model': 'qwen3.8-flash-next',
    'choices': [
      {'index': 0, 'delta': <String, dynamic>{}, 'finish_reason': 'stop'},
    ],
    'usage': {
      'prompt_tokens': 12,
      'completion_tokens': 34,
      'total_tokens': 46,
      'prompt_tokens_details': {'cached_tokens': 0},
    },
  };
  return 'data: ${jsonEncode(body)}';
}

void main() {
  group('上游 Strata 真实 wire format（源码级核实形态）', () {
    test('首个 chunk 为 role+空 content，思考与正文均能正确抽取', () async {
      // server.py:5849 首块 {"role":"assistant","content":""}（无 reasoning_content 键）
      final sse = [
        _chunk({'role': 'assistant', 'content': ''}),
        _chunk({'reasoning_content': '用户问好，先确认身份。'}),
        _chunk({'content': '你好，我是 Qwen。'}),
        _tailChunk(),
        'data: [DONE]',
      ].join('\n\n');

      final server = await _startRawServer(sse);
      addTearDown(() => server.close(force: true));

      final client = StrataClient(baseUrl: _baseUrl(server));
      addTearDown(client.close);

      final events = await client
          .chatStream(messages: const [ChatMessageRequest(role: 'user', content: '你好')])
          .toList();

      final reasoning = events.whereType<ReasoningDeltaEvent>().map((e) => e.text).join();
      final content = events.whereType<ContentDeltaEvent>().map((e) => e.text).join();

      expect(reasoning, '用户问好，先确认身份。');
      expect(content, '你好，我是 Qwen。');
    });

    test('尾块 choices 非空时仍能取到 usage（M1-11 修复核心）', () async {
      // 上游 Strata 尾块 choices 非空 → 旧实现只认 choices==[] 才取 usage → usage 永远丢失
      final sse = [
        _chunk({'content': '答案'}),
        _tailChunk(),
        'data: [DONE]',
      ].join('\n\n');

      final server = await _startRawServer(sse);
      addTearDown(() => server.close(force: true));

      final client = StrataClient(baseUrl: _baseUrl(server));
      addTearDown(client.close);

      final events = await client
          .chatStream(messages: const [ChatMessageRequest(role: 'user', content: 'hi')])
          .toList();

      final finished = events.whereType<FinishedEvent>().toList();
      expect(finished, hasLength(1));
      expect(finished.single.usage, isNotNull, reason: '上游尾块 choices 非空也必须取到 usage');
      expect(finished.single.usage!.totalTokens, 46);
    });

    test('OpenAI 规范形态（usage 块 choices 为空数组）同样取到 usage', () async {
      // 兼容两种形态：某些中转服务按 OpenAI 规范发 usage 块
      final openaiTail = jsonEncode({
        'id': 'chatcmpl-test',
        'object': 'chat.completion.chunk',
        'choices': <dynamic>[],
        'usage': {'prompt_tokens': 1, 'completion_tokens': 2, 'total_tokens': 3},
      });
      final sse = [
        _chunk({'content': '答案'}),
        'data: $openaiTail',
        'data: [DONE]',
      ].join('\n\n');

      final server = await _startRawServer(sse);
      addTearDown(() => server.close(force: true));

      final client = StrataClient(baseUrl: _baseUrl(server));
      addTearDown(client.close);

      final events = await client
          .chatStream(messages: const [ChatMessageRequest(role: 'user', content: 'hi')])
          .toList();
      final finished = events.whereType<FinishedEvent>().single;
      expect(finished.usage!.totalTokens, 3);
    });

    test('keep-alive 注释行被跳过，不影响后续内容解析', () async {
      // server.py:7180 prefill 阶段每 15s 发 ": keep-alive" 注释行
      final sse = [
        ': keep-alive',
        '',
        _chunk({'role': 'assistant', 'content': ''}),
        ': keep-alive',
        '',
        _chunk({'reasoning_content': '思考中'}),
        _chunk({'content': '你好'}),
        'data: [DONE]',
      ].join('\n');

      final server = await _startRawServer(sse);
      addTearDown(() => server.close(force: true));

      final client = StrataClient(baseUrl: _baseUrl(server));
      addTearDown(client.close);

      final events = await client
          .chatStream(messages: const [ChatMessageRequest(role: 'user', content: 'hi')])
          .toList();

      expect(events.whereType<ReasoningDeltaEvent>().map((e) => e.text).join(), '思考中');
      expect(events.whereType<ContentDeltaEvent>().map((e) => e.text).join(), '你好');
    });
  });

  group('不再静默失败：畸形输入必须可观测', () {
    test('坏 JSON 行被跳过但计数上报，且不影响正常内容', () async {
      final sse = [
        'data: {这不是合法 JSON',
        _chunk({'content': '正常内容'}),
        'data: [DONE]',
      ].join('\n\n');

      final server = await _startRawServer(sse);
      addTearDown(() => server.close(force: true));

      final client = StrataClient(baseUrl: _baseUrl(server));
      addTearDown(client.close);

      final events = await client
          .chatStream(messages: const [ChatMessageRequest(role: 'user', content: 'hi')])
          .toList();

      final finished = events.whereType<FinishedEvent>().single;
      expect(events.whereType<ContentDeltaEvent>().map((e) => e.text).join(), '正常内容');
      expect(finished.diagnostics, isNotNull);
      expect(finished.diagnostics!.malformedLines, 1, reason: '坏行必须被计数，不能静默吞掉');
      expect(finished.diagnostics!.droppedSomething, isTrue);
    });

    test('整个流无可解析 chunk 时 diagnostics.gotNothing 为 true', () async {
      // 这是 v0.0.1 内测症状的精确复现：服务端回了内容但形态不符 → 客户端一无所获
      final sse = [
        'data: {"unexpected":"shape"}',
        'data: [DONE]',
      ].join('\n\n');

      final server = await _startRawServer(sse);
      addTearDown(() => server.close(force: true));

      final client = StrataClient(baseUrl: _baseUrl(server));
      addTearDown(client.close);

      final events = await client
          .chatStream(messages: const [ChatMessageRequest(role: 'user', content: 'hi')])
          .toList();

      expect(events.whereType<ContentDeltaEvent>(), isEmpty);
      expect(events.whereType<ReasoningDeltaEvent>(), isEmpty);
      final finished = events.whereType<FinishedEvent>().single;
      expect(finished.diagnostics!.gotNothing, isTrue);
    });

    test('多字节 UTF-8 被切断时不击穿流（allowMalformed 兜底）', () async {
      // 手工构造：把一个中文字符的 3 字节拆到两个 chunk 之间
      final text = '你';
      final bytes = utf8.encode(text);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
        // 先写半个中文字符 + 换行 → 该行必然解码不完整
        request.response.add(bytes.sublist(0, 1));
        request.response.add(const [0x0A]);
        // 再写完整的正常 chunk
        request.response.add(
          utf8.encode('${_chunk({'content': '正常'})}\n\ndata: [DONE]\n\n'),
        );
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));

      final client = StrataClient(baseUrl: _baseUrl(server));
      addTearDown(client.close);

      final events = await client
          .chatStream(messages: const [ChatMessageRequest(role: 'user', content: 'hi')])
          .toList();

      // 关键：流没有崩，正常内容仍然到达
      expect(events.whereType<ContentDeltaEvent>().map((e) => e.text).join(), '正常');
      expect(events.whereType<FinishedEvent>(), hasLength(1));
    });
  });

  group('请求体构造', () {
    test('助手回合的 reasoning_content 随历史回传（模板要求）', () async {
      // serve/chat_golden.json "assistant with thinking" 用例：
      // assistant 消息为 {role, content, reasoning_content}
      const req = ChatMessageRequest(
        role: 'assistant',
        content: '好的',
        reasoningContent: '先确认需求',
      );
      final json = req.toJson();
      expect(json['reasoning_content'], '先确认需求');
      expect(json['content'], '好的');
    });

    test('无 reasoning 时不序列化 reasoning_content 字段', () {
      const req = ChatMessageRequest(role: 'user', content: '你好');
      expect(req.toJson().containsKey('reasoning_content'), isFalse);
    });
  });
}

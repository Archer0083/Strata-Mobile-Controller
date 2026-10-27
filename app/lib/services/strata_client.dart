// StrataClient：Strata HTTP API 的 dio 封装（M1-4）。
//
// 健壮性规则（SPEC v0.3.4 §6.1）：
//   1. 连接建立超时 10s（TCP/TLS/HTTP 首包，覆盖短请求）；
//   2. 流式空闲检测基于 keep-alive：引擎每 15s 发 SSE 注释行保活，
//      >45s 未收到任何字节才判超时（用 dio receiveTimeout=45s 作用于
//      「相邻数据块间隔」实现，注释行同样是数据块，天然重置计时）；
//   3. 指数退避重试（1s/2s/4s，上限 3 次）仅作用于幂等 GET 的连接建立失败；
//      流式对话中断不自动重发（避免重复生成）；
//   4. 所有失败抛 StrataException 子类，供 UI 区分错误类型。
//
// SSE 解析为手动实现（字节流按 0x0A 切行，完整行再 utf8 解码，
// 规避多字节字符跨 chunk 边界问题）；`data:` 载荷按 OpenAI chunk 形态解析，
// `:` 开头的注释行（keep-alive）仅用于保活，无业务语义。
//
// 【M1-11 内测反馈修复】依据 Strata 服务端源码级取证（serve/server.py、serve/frontend.py）：
//   1. delta 字段名为 choices[0].delta.reasoning_content / .content（与本客户端原实现一致），
//      但首个 chunk 恒为 {"role":"assistant","content":""}——无 reasoning_content 键，
//      故必须用 `as String?`（缺失即 null）而非硬索引；
//   2. 服务端尾块 choices **非空**（含 finish_reason），usage 直接挂在尾块顶层，
//      与 OpenAI 规范「usage 块 choices 为空数组」不同 → 两种形态都要认；
//   3. 服务端不识别 stream_options/include_usage，usage 恒在尾块；
//   4. 引擎每 15s 发 `: keep-alive` 注释行保活，必须按 SSE 规范跳过；
//   5. 推理/正文切分由模型输出的闭合 think 标签驱动，服务端不会把思考塞进 content，
//      且服务端全仓库不产生任何「？」占位符 → 若 App 出现占位符，必来自本层解析缺陷。
//
// 【健壮性铁律】解析层任何异常都不得静默吞掉：单行坏数据可跳过，但必须计数并随流结束上报，
// 否则「无内容且无报错」这类问题无法被用户与开发者察觉（正是 v0.0.1 内测的主要症状）。

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:dio/dio.dart';

import '../models/api_models.dart';
import '../models/metrics_snapshot.dart';
import '../models/strata_models.dart';

/// Strata 异常体系（SPEC §6.1.4：错误类型必须可区分）
sealed class StrataException implements Exception {
  const StrataException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => '$runtimeType: $message';
}

/// 连接不通（服务未启动 / WireGuard 未连 / 网络不可达 / 建立超时）
class StrataConnectionException extends StrataException {
  const StrataConnectionException(super.message, [super.cause]);
}

/// 401：API Key 缺失或错误
class StrataUnauthorizedException extends StrataException {
  const StrataUnauthorizedException(super.message);
}

/// 400：请求参数非法（如 reasoning_effort 取值错误）
class StrataBadRequestException extends StrataException {
  const StrataBadRequestException(super.message);
}

/// 404
class StrataNotFoundException extends StrataException {
  const StrataNotFoundException(super.message);
}

/// 5xx：引擎异常
class StrataServerErrorException extends StrataException {
  const StrataServerErrorException(super.message, [this.statusCode]);

  final int? statusCode;
}

/// 流式空闲 >45s（未收到任何字节，含 keep-alive 注释行）
class StrataIdleTimeoutException extends StrataException {
  const StrataIdleTimeoutException(super.message);
}

/// 其他未分类错误
class StrataUnexpectedException extends StrataException {
  const StrataUnexpectedException(super.message, [super.cause]);
}

class StrataClient {
  StrataClient({
    required String baseUrl,
    this.apiKey,
    Dio? dio,
    this.retryDelays = const [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 4)],
    this.idleTimeout = const Duration(seconds: 45),
  })  : _baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = _baseUrl
      ..connectTimeout = const Duration(seconds: 10) // SPEC §6.1.1
      ..headers['Content-Type'] = 'application/json';
    // 【v0.0.7 真机反馈】同一主机 webUI（浏览器）能打开 /metrics 卡片、
    // App 却拿到 404/错误。浏览器同源请求天然带 Origin/Referer/Accept，
    // 原生 HTTP 客户端三者皆无——个别服务端版本对「无 Origin 的仪表盘
    // 类 GET」有同源校验时会拒绝。这里完全复刻 webUI 的请求姿态：
    // Origin/Referer 指向主机自身（永不会被判「外来 Origin」），Accept
    // 明确 JSON（防 Prometheus 文本协商）。
    _dio.options.headers['Origin'] = _baseUrl;
    _dio.options.headers['Referer'] = '$_baseUrl/';
    _dio.options.headers['Accept'] = 'application/json';
    if (apiKey != null && apiKey!.isNotEmpty) {
      // Strata 同时接受 Authorization: Bearer 与 x-api-key（llama.cpp 约定），
      // 两个头都带上，兼容不同版本/不同部署的鉴权校验。
      _dio.options.headers['Authorization'] = 'Bearer $apiKey';
      _dio.options.headers['x-api-key'] = apiKey!;
    }
  }

  final String _baseUrl;
  final String? apiKey;
  final Dio _dio;

  /// 幂等 GET 连接失败的重试间隔（测试可注入短间隔）
  final List<Duration> retryDelays;

  /// 流式空闲判定阈值（SPEC §6.1.2：>45s；测试可注入短阈值）
  final Duration idleTimeout;

  /// 模型列表（ConnectionScreen「测试连接」即调此接口）
  Future<List<ModelInfo>> listModels() => _withRetryGet(
        '/v1/models',
        decode: (data) => (data['data'] as List)
            .map((e) => ModelInfo.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// 已安装模型清单（v0.0.6；GET /models/installed）
  ///
  /// /v1/models 只列当前进程服务的那一个模型（+aliases），答不了「主机上可以
  /// 加载哪些模型」；这个端点读主机安装目录里的运行配置，列出全部已安装模型。
  /// 旧服务端没有这个端点 → 404（调用方据此降级为只显示当前模型）。
  Future<InstalledModels> installedModels() => _withRetryGet(
        '/models/installed',
        decode: InstalledModels.fromJson,
      );

  /// 选择主机上的另一个已安装模型来服务（v0.0.6；POST /models/select）
  ///
  /// 服务端用目标模型的运行配置重建引擎、tokenizer、chat template 与视觉组件，
  /// 再换上；新模型准备好之前旧模型一直服务，失败时旧模型不受影响。
  Future<ModelSwitchResult> selectModel(String modelId) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        '/models/select',
        data: {'model': modelId},
        options: Options(responseType: ResponseType.json, receiveTimeout: const Duration(seconds: 120)),
      );
      return ModelSwitchResult.fromJson(resp.data!);
    } on DioException catch (e) {
      throw _mapDio(e);
    }
  }

  /// 写上下文长度（v0.0.6；POST /config 的 context_length 键）
  ///
  /// 上下文长度是引擎启动参数（--max-context），写进运行配置后要重启主机才生效。
  Future<ConfigSaveResult> setContextLength(int tokens) =>
      saveConfig({'context_length': tokens});

  /// 健康检查
  Future<HealthInfo> health() => _withRetryGet(
        '/health',
        decode: HealthInfo.fromJson,
      );

  // ───────────────────────────────────────────────────────────
  // M2-2~M2-7：监控 / API Monitor / 配置 / 控制 / 生图 端点
  // ───────────────────────────────────────────────────────────

  /// /metrics 完整树（M2-2 MonitorScreen 数据源；allRequests=true 请求全部请求表条目）
  Future<MetricsSnapshot> metrics({bool allRequests = false}) => _withRetryGet(
        '/metrics${allRequests ? '?requests=all' : ''}',
        decode: MetricsSnapshot.fromJson,
      );

  /// /v1/status（M2-7 控制 / API Monitor 页头：模型加载与在途请求）
  Future<EngineStatus> engineStatus() => _withRetryGet(
        '/v1/status',
        decode: EngineStatus.fromJson,
      );

  /// /props（M2-7 量化档位等引擎属性只读；引擎未运行时 503 → 宽容空卡）
  Future<EngineProps> props() => _withRetryGet(
        '/props',
        decode: EngineProps.fromJson,
      );

  /// /api/requests 列表（M2-4 API Monitor；主机关 svc.api_monitor 时 404）
  Future<ApiMonitorList> apiRequests() => _withRetryGet(
        '/api/requests',
        decode: ApiMonitorList.fromJson,
      );

  /// /api/requests?id= 详情（M2-4 四 tab）
  Future<ApiRequestDetail> apiRequestDetail(String id) => _withRetryGet(
        '/api/requests?id=$id',
        decode: ApiRequestDetail.fromJson,
      );

  /// /config 键值清单（M2-3 模型设置）
  Future<ConfigInfo> config() => _withRetryGet(
        '/config',
        decode: ConfigInfo.fromJson,
      );

  /// POST /config {set:{k:v}}（M2-3；只发 diff；返回 changed keys + 文件名）
  Future<ConfigSaveResult> saveConfig(Map<String, Object?> set) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        '/config',
        data: {'set': set},
        options: Options(responseType: ResponseType.json, receiveTimeout: const Duration(seconds: 10)),
      );
      return ConfigSaveResult.fromJson(resp.data!);
    } on DioException catch (e) {
      throw _mapDio(e);
    }
  }

  /// /mcp 服务器树（M2-2 MCP 卡）
  Future<McpInfo> mcp() => _withRetryGet(
        '/mcp',
        decode: McpInfo.fromJson,
      );

  /// POST /load / /unload（M2-7；unload 支持 wait 秒透传）
  Future<void> loadEngine() async {
    try {
      await _dio.post('/load', data: {});
    } on DioException catch (e) {
      throw _mapDio(e);
    }
  }

  Future<void> unloadEngine({int? waitSeconds}) async {
    try {
      await _dio.post(
        '/unload${waitSeconds != null ? '?wait=$waitSeconds' : ''}',
        data: {},
      );
    } on DioException catch (e) {
      throw _mapDio(e);
    }
  }

  /// POST /v1/images/generations（M2-6；返回 b64_png + seed + size）
  Future<GeneratedImage> generateImage({
    required String prompt,
    String size = '1024x1024',
    int? seed,
  }) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        '/v1/images/generations',
        data: {
          'prompt': prompt,
          'size': size,
          'seed': ?seed,
        },
        // 真实 sd-cli 生图是分钟级（web hint 原话 a minute or more on a
        // small GPU），mock 即刻返回不受影响
        options: Options(responseType: ResponseType.json, receiveTimeout: const Duration(minutes: 10)),
      );
      return GeneratedImage.fromJson(resp.data!);
    } on DioException catch (e) {
      throw _mapDio(e);
    }
  }

  /// 非流式对话
  ///
  /// [model]：服务端接受的模型名（= 当前服务的模型，或它的别名）。
  /// 不传（null）时服务端用自己的当前模型 —— 这是最稳的写法：主机换了模型
  /// （或 App 连的是别的部署）时也不会因为名字对不上被拒。
  Future<ChatCompletion> chat({
    required List<ChatMessageRequest> messages,
    ReasoningEffort effort = ReasoningEffort.medium,
    String? model,
  }) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        '/v1/chat/completions',
        data: {
          if (model != null && model.isNotEmpty) 'model': model,
          'messages': messages.map((m) => m.toJson()).toList(),
          'stream': false,
          'reasoning_effort': effort.wireName,
        },
        options: Options(responseType: ResponseType.json, receiveTimeout: const Duration(seconds: 60)),
      );
      final choice = (resp.data!['choices'] as List).first as Map<String, dynamic>;
      final message = choice['message'] as Map<String, dynamic>;
      return ChatCompletion(
        // 服务端非流式 content 可能为 null（空答案时 `"".join(content) or None`），
        // 强转 as String 会抛 TypeError → 必须按可空读取。
        content: message['content'] as String? ?? '',
        // reasoning_content 键仅在推理非空时存在（缺失≠空串）
        reasoningContent: message['reasoning_content'] as String?,
        usage: resp.data!['usage'] == null
            ? null
            : ChatUsage.fromJson(resp.data!['usage'] as Map<String, dynamic>),
      );
    } on DioException catch (e) {
      throw _mapDio(e);
    }
  }

  /// 流式对话（SSE）。不自动重试（SPEC §6.1.3）。
  ///
  /// 事件顺序：ReasoningDeltaEvent*（effort=none 时无）→ ContentDeltaEvent*
  /// → FinishedEvent（携带尾包 usage，可能为 null）。
  ///
  /// [sampling]：M2-5 采样参数。untouched 时字段全不发送（服务端用自身默认），
  /// 规则详见 SamplingParams.toWire。
  Stream<ChatStreamEvent> chatStream({
    required List<ChatMessageRequest> messages,
    ReasoningEffort effort = ReasoningEffort.medium,
    SamplingParams sampling = SamplingParams.defaults,
    String? model,
  }) {
    final controller = StreamController<ChatStreamEvent>();
    StreamSubscription<List<int>>? sub;

    controller.onListen = () async {
      try {
        final resp = await _dio.post<ResponseBody>(
          '/v1/chat/completions',
          data: {
            if (model != null && model.isNotEmpty) 'model': model,
            'messages': messages.map((m) => m.toJson()).toList(),
            'stream': true,
            'reasoning_effort': effort.wireName,
            ...sampling.toWire(),
          },
          options: Options(
            responseType: ResponseType.stream,
            // receiveTimeout 作用于相邻数据块间隔：keep-alive 注释行每 15s 一块，
            // 持续重置计时；>45s 无任何字节 → DioExceptionType.receiveTimeout。
            receiveTimeout: idleTimeout,
          ),
        );

        final lineBuffer = <int>[];
        ChatUsage? usage;

        // 解析异常计数：任何一次坏行都要留痕并在流结束时上报（不再静默吞掉）
        var malformedLines = 0;
        var decodeErrors = 0;
        var deltaChunks = 0;

        void handleLine(String line) {
          if (line.isEmpty) return; // 空行（SSE 事件分隔）
          if (line.startsWith(':')) return; // SSE 注释：keep-alive 保活行，无业务语义
          if (!line.startsWith('data:')) return; // 非 data 字段（id/event/retry 等）本客户端不消费
          final payload = line.substring(5).trim();
          if (payload.isEmpty) return;
          if (payload == '[DONE]') return; // 结束标记，连接随后由服务端关闭

          Map<String, dynamic> json;
          try {
            final decoded = jsonDecode(payload);
            if (decoded is! Map<String, dynamic>) {
              malformedLines++;
              return;
            }
            json = decoded;
          } on FormatException {
            // 坏 JSON 行：跳过但计数（不中断整个流），末尾随 FinishedEvent 上报
            malformedLines++;
            return;
          }

          // usage 可能在任何位置的顶层（Strata 挂在尾块顶层；OpenAI 规范挂在 choices 空数组块）
          final rawUsage = json['usage'];
          if (rawUsage is Map<String, dynamic>) {
            usage = ChatUsage.fromJson(rawUsage);
          }

          final choices = json['choices'];
          if (choices is! List || choices.isEmpty) {
            // 纯 usage 块（OpenAI 规范形态）：无正文可取
            return;
          }
          final first = choices.first;
          if (first is! Map<String, dynamic>) {
            malformedLines++;
            return;
          }
          final delta = first['delta'];
          if (delta is! Map<String, dynamic>) {
            // 无 delta（如仅 finish_reason 的块）：合法，跳过
            return;
          }
          deltaChunks++;

          // 字段名经服务端源码核实为 reasoning_content / content；
          // 首 chunk 无 reasoning_content 键、content 为空串 → 必须走缺失即 null 的读法。
          final reasoning = delta['reasoning_content'];
          if (reasoning is String && reasoning.isNotEmpty) {
            controller.add(ReasoningDeltaEvent(reasoning));
          }
          final content = delta['content'];
          if (content is String && content.isNotEmpty) {
            controller.add(ContentDeltaEvent(content));
          }
        }

        /// 解码一行字节：多字节 UTF-8 被切断时 utf8.decode 会抛 FormatException，
        /// 该异常不在 handleLine 的 try 内，必须单独兜住，否则会击穿整个流监听。
        void handleBuffer() {
          if (lineBuffer.isEmpty) return;
          String line;
          try {
            line = utf8.decode(lineBuffer, allowMalformed: true);
          } on FormatException {
            decodeErrors++;
            lineBuffer.clear();
            return;
          }
          lineBuffer.clear();
          handleLine(line);
        }

        sub = resp.data!.stream.listen(
          (chunk) {
            // 逐字节切行；完整行统一 utf8 解码，规避多字节字符跨 chunk
            for (final b in chunk) {
              if (b == 0x0A) {
                handleBuffer();
              } else {
                lineBuffer.add(b);
              }
            }
          },
          onError: (Object e) {
            controller.addError(e is DioException ? _mapStreamError(e) : StrataUnexpectedException('流读取失败', e));
            controller.close();
          },
          onDone: () {
            handleBuffer();
            controller.add(FinishedEvent(
              usage,
              diagnostics: SseDiagnostics(
                deltaChunks: deltaChunks,
                malformedLines: malformedLines,
                decodeErrors: decodeErrors,
              ),
            ));
            controller.close();
          },
          cancelOnError: true,
        );
      } on DioException catch (e) {
        controller.addError(_mapStreamError(e));
        await controller.close();
      } catch (e) {
        controller.addError(StrataUnexpectedException('流式请求失败', e));
        await controller.close();
      }
    };

    controller.onCancel = () => sub?.cancel();
    return controller.stream;
  }

  /// 幂等 GET + 连接失败指数退避重试（SPEC §6.1.3）
  Future<T> _withRetryGet<T>(String path, {required T Function(Map<String, dynamic>) decode}) async {
    var attempt = 0;
    while (true) {
      try {
        final resp = await _dio.get<Map<String, dynamic>>(
          path,
          options: Options(responseType: ResponseType.json, receiveTimeout: const Duration(seconds: 10)),
        );
        return decode(resp.data!);
      } on DioException catch (e) {
        final retryable = e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.connectionTimeout;
        if (retryable && attempt < retryDelays.length) {
          await Future<void>.delayed(retryDelays[attempt]);
          attempt++;
          continue;
        }
        throw _mapDio(e);
      }
    }
  }

  StrataException _mapDio(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.connectionError:
      case DioExceptionType.receiveTimeout: // 短请求 10s 收不到响应 → 连接类失败
        return StrataConnectionException('连接失败：$_baseUrl（检查服务是否启动 / WireGuard 隧道）', e);
      case DioExceptionType.badResponse:
        final status = e.response?.statusCode ?? 0;
        final serverMsg = _extractServerMessage(e.response?.data);
        return switch (status) {
          401 => StrataUnauthorizedException('API Key 缺失或错误（401）'),
          400 => StrataBadRequestException(serverMsg ?? '请求参数非法（400）'),
          404 => StrataNotFoundException('接口不存在：${e.requestOptions.uri.path}'),
          >= 500 => StrataServerErrorException(serverMsg ?? '引擎异常（$status）', status),
          _ => StrataUnexpectedException('HTTP $status：${serverMsg ?? ''}'),
        };
      default:
        // Windows 等平台上连接被拒常以 unknown + SocketException 冒出，同样归入连接类
        if (e.error is SocketException) {
          return StrataConnectionException('连接失败：$_baseUrl（检查服务是否启动 / WireGuard 隧道）', e);
        }
        return StrataUnexpectedException('请求失败：${e.message}', e);
    }
  }

  StrataException _mapStreamError(DioException e) => switch (e.type) {
        DioExceptionType.receiveTimeout => StrataIdleTimeoutException(
            '流式空闲超过 ${idleTimeout.inSeconds}s 未收到任何字节（含 keep-alive）'),
        _ => _mapDio(e),
      };

  String? _extractServerMessage(Object? data) {
    if (data is Map<String, dynamic>) {
      final err = data['error'];
      if (err is Map<String, dynamic> && err['message'] is String) return err['message'] as String;
    }
    return null;
  }

  void close() => _dio.close();
}

// M2-2~M2-7 各端点模型（/v1/status、/api/requests、/config、/mcp、/v1/images/generations）。
//
// 字段对齐 server-bridge/mock/mock_strata.py 与 strata_ref/serve/web/app.js 消费面。
// 解析原则与 metrics_snapshot.dart 一致：宽容忽略未知键；数值缺失/类型错 → null。
// v0.0.8：改用 json_readers.dart 的宽容读取助手——真实主机的字段类型
// 与 mock 不总一致（如 context_length 可能是字符串），硬断言会让整页降级。

import 'json_readers.dart';

// ─────────────────────────────────────────────────────────────
// /v1/status（M2-4 API Monitor 页头 / M2-7 控制）
// ─────────────────────────────────────────────────────────────

class EngineStatus {
  const EngineStatus({
    required this.loaded,
    this.model,
    this.autoLoad,
    this.inFlight,
  });

  factory EngineStatus.fromJson(Map<String, dynamic> j) => EngineStatus(
        model: readStr(j, 'model'),
        loaded: readBool(j, 'loaded') ?? false,
        autoLoad: readBool(j, 'auto_load'),
        inFlight: j['activity'] is Map<String, dynamic>
            ? readInt(j['activity'] as Map<String, dynamic>, 'in_flight')
            : null,
      );

  final String? model;
  final bool loaded;
  final bool? autoLoad;

  /// 在途（非终态）请求数
  final int? inFlight;

  /// webUI 标签：loading→Loading… / in_use→In use / loaded→Loaded / unloaded→Unloaded
  String get stateLabel => !loaded
      ? 'Unloaded'
      : (inFlight ?? 0) > 0
          ? 'In use'
          : 'Loaded';
}

/// /props 引擎属性（M2-7 只读卡：量化档位标注「主机 setup 时设定」）。
/// 真实 server `_props()`：default_generation_settings/total_slots/model_alias/
/// chat_template/modalities/models_autoload/is_sleeping/model_path/build_info；
/// mock `/props`：model/quantization/context_length/host_mode——两组键都容错。
class EngineProps {
  const EngineProps({
    this.model,
    this.quantization,
    this.contextLength,
    this.hostMode,
    this.totalSlots,
    this.buildInfo,
    this.modelPath,
    this.isSleeping,
    this.vision,
  });

  factory EngineProps.fromJson(Map<String, dynamic> j) {
    final gen = j['default_generation_settings'];
    final modalities = j['modalities'];
    return EngineProps(
      model: readStr(j, 'model_alias') ?? readStr(j, 'model'),
      // mock 的 quantization 字段；真实 server 无此键（量化在 setup 时定，
      // 体现在 model_path 文件名中）
      quantization: readStr(j, 'quantization'),
      contextLength: (gen is Map<String, dynamic>
              ? readInt(gen, 'n_ctx')
              : null) ??
          readInt(j, 'context_length'),
      hostMode: readStr(j, 'host_mode'),
      totalSlots: readInt(j, 'total_slots'),
      buildInfo: readStr(j, 'build_info'),
      modelPath: readStr(j, 'model_path'),
      isSleeping: readBool(j, 'is_sleeping'),
      vision: modalities is Map<String, dynamic>
          ? readBool(modalities, 'vision')
          : null,
    );
  }

  final String? model;
  final String? quantization;
  final int? contextLength;
  final String? hostMode;
  final int? totalSlots;
  final String? buildInfo;
  final String? modelPath;
  final bool? isSleeping;
  final bool? vision;

  /// 有任一有效字段才渲染卡（全空 → 隐藏）
  bool get hasAny =>
      (model?.isNotEmpty ?? false) ||
      (quantization?.isNotEmpty ?? false) ||
      (buildInfo?.isNotEmpty ?? false) ||
      (modelPath?.isNotEmpty ?? false);
}

// ─────────────────────────────────────────────────────────────
// /api/requests 列表 + 详情（M2-4 API Monitor）
// ─────────────────────────────────────────────────────────────

class ApiMonitorList {
  const ApiMonitorList({required this.requests, this.loaded, this.autoLoad});

  factory ApiMonitorList.fromJson(Map<String, dynamic> j) => ApiMonitorList(
        requests: [
          if (j['requests'] is List)
            for (final r in j['requests'] as List)
              if (r is Map<String, dynamic>) ApiRequestSummary.fromJson(r),
        ],
        loaded: j['loaded'] == true,
        autoLoad: j['auto_load'] == true,
      );

  final List<ApiRequestSummary> requests;
  final bool? loaded;
  final bool? autoLoad;
}

/// 列表行（list_json）：时间 + state + POST path + meta
class ApiRequestSummary {
  const ApiRequestSummary({
    required this.id,
    this.path,
    this.model,
    this.state,
    this.startedAt,
    this.wallclockS,
    this.stream = false,
    this.httpStatus,
    this.predictedPerSecond,
  });

  factory ApiRequestSummary.fromJson(Map<String, dynamic> j) => ApiRequestSummary(
        id: j['id'] as String? ?? '',
        path: j['path'] as String?,
        model: j['model'] as String?,
        state: j['state'] as String?,
        startedAt: (j['started_at'] as num?)?.toDouble(),
        wallclockS: (j['wallclock_s'] as num?)?.toDouble(),
        stream: j['stream'] == true,
        httpStatus: j['http_status'] as int?,
        predictedPerSecond: j['timings'] is Map<String, dynamic>
            ? (j['timings']['predicted_per_second'] as num?)?.toDouble()
            : null,
      );

  final String id;
  final String? path;
  final String? model;
  final String? state;
  final double? startedAt; // epoch 秒
  final double? wallclockS;
  final bool stream;
  final int? httpStatus;

  /// 「最近 decode speed」统计卡数据源（webUI monitor.js refresh 同款）
  final double? predictedPerSecond;

  /// search 匹配 {id} {path} {model} includes（webUI 同款）
  bool matches(String q) =>
      q.isEmpty ||
      '$id ${path ?? ''} ${model ?? ''}'.toLowerCase().contains(q.toLowerCase());

  /// webUI active 语义（monitor.js）：state 不在终态集合
  /// {completed, error, disconnected} 即视为进行中（null 也算）
  bool get isActive =>
      state != 'completed' && state != 'error' && state != 'disconnected';

  bool get isError => state == 'error';

  /// 过滤器：all / active / completed / error（webUI 为严格 state 等值比较）
  bool passesFilter(String f) => switch (f) {
        'active' => isActive,
        'error' => isError,
        'completed' => state == 'completed',
        _ => true,
      };
}

/// 详情（detail_json）：8 facts + 四 tab 正文
class ApiRequestDetail {
  const ApiRequestDetail({
    required this.id,
    this.path,
    this.model,
    this.state,
    this.startedAt,
    this.wallclockS,
    this.stream = false,
    this.httpStatus,
    this.responseFormat,
    this.loadS,
    this.queueS,
    this.firstTokenS,
    this.promptTokens,
    this.completionTokens,
    this.predictedPerSecond,
    this.input,
    this.output,
    this.reasoning,
    this.response,
    this.errorMessage,
    this.finish,
  });

  factory ApiRequestDetail.fromJson(Map<String, dynamic> j) {
    final usage = j['usage'];
    final timings = j['timings'];
    final err = j['error'];
    return ApiRequestDetail(
      id: j['id'] as String? ?? '',
      path: j['path'] as String?,
      model: j['model'] as String?,
      state: j['state'] as String?,
      startedAt: (j['started_at'] as num?)?.toDouble(),
      wallclockS: (j['wallclock_s'] as num?)?.toDouble(),
      stream: j['stream'] == true,
      httpStatus: j['http_status'] as int?,
      responseFormat: j['response_format'] as String?,
      loadS: (j['load_s'] as num?)?.toDouble(),
      queueS: (j['queue_s'] as num?)?.toDouble(),
      firstTokenS: (j['first_token_s'] as num?)?.toDouble(),
      promptTokens: usage is Map<String, dynamic> ? usage['prompt_tokens'] as int? : null,
      completionTokens:
          usage is Map<String, dynamic> ? usage['completion_tokens'] as int? : null,
      predictedPerSecond: timings is Map<String, dynamic>
          ? (timings['predicted_per_second'] as num?)?.toDouble()
          : null,
      input: j['input'] as String?,
      output: j['output'] as String?,
      reasoning: j['reasoning'] as String?,
      response: j['response'] as String?,
      errorMessage:
          err is Map<String, dynamic> ? err['message'] as String? : null,
      finish: j['finish'] as String?,
    );
  }

  final String id;
  final String? path;
  final String? model;
  final String? state;
  final double? startedAt;
  final double? wallclockS;
  final bool stream;
  final int? httpStatus;

  /// 'text' | 'json'
  final String? responseFormat;
  final double? loadS;
  final double? queueS;
  final double? firstTokenS;
  final int? promptTokens;
  final int? completionTokens;
  final double? predictedPerSecond;
  final String? input;
  final String? output;
  final String? reasoning;
  final String? response;
  final String? errorMessage;
  final String? finish;
}

// ─────────────────────────────────────────────────────────────
// /config（M2-3 模型设置）
// ─────────────────────────────────────────────────────────────

class ConfigInfo {
  const ConfigInfo({required this.keys, this.file});

  factory ConfigInfo.fromJson(Map<String, dynamic> j) => ConfigInfo(
        file: j['file'] as String?,
        keys: [
          if (j['keys'] is List)
            for (final k in j['keys'] as List)
              if (k is Map<String, dynamic>) ConfigKey.fromJson(k),
        ],
      );

  final String? file;
  final List<ConfigKey> keys;
}

/// 单个配置键：bool / enum / number / string 四种 kind
class ConfigKey {
  const ConfigKey({
    required this.key,
    required this.kind,
    this.value,
    this.choices = const [],
    this.help,
  });

  factory ConfigKey.fromJson(Map<String, dynamic> j) => ConfigKey(
        key: j['key'] as String? ?? '',
        kind: j['kind'] as String? ?? 'string',
        value: j['value'],
        choices: [
          if (j['choices'] is List)
            for (final c in j['choices'] as List) if (c is String) c,
        ],
        help: j['help'] as String?,
      );

  final String key;

  /// 'bool' | 'enum' | 'number' | 'string'
  final String kind;

  /// 原始值（bool/num/String/null）
  final Object? value;
  final List<String> choices;
  final String? help;

  bool get isEnum => kind == 'enum' && choices.isNotEmpty;
}

// ─────────────────────────────────────────────────────────────
// /models/installed（v0.0.6：主机已安装模型清单）
//
// 服务端读 setup 写在安装目录里的 strata-<model>.json 运行配置，列出这台
// 主机上装了哪些模型、各自的上下文长度、以及文件是否齐全。
// 与 /v1/models 的区别：/v1/models 只列当前进程服务的那一个模型（+aliases），
// 无法回答「主机上可以加载哪些模型」。
// ─────────────────────────────────────────────────────────────

class InstalledModels {
  const InstalledModels({
    required this.models,
    this.installDir,
    this.installDirSource,
  });

  factory InstalledModels.fromJson(Map<String, dynamic> j) => InstalledModels(
        models: [
          if (j['data'] is List)
            for (final m in j['data'] as List)
              if (m is Map<String, dynamic>) InstalledModel.fromJson(m),
        ],
        installDir: j['install_dir'] as String?,
        installDirSource: j['install_dir_source'] as String?,
      );

  final List<InstalledModel> models;
  final String? installDir;
  final String? installDirSource;

  /// 可正常加载的模型（文件齐全）
  List<InstalledModel> get loadable =>
      models.where((m) => m.componentStatus == 'present').toList();
}

/// 单个已安装模型
class InstalledModel {
  const InstalledModel({
    required this.id,
    required this.name,
    this.contextTokens,
    this.componentStatus,
    this.backend,
    this.current = false,
    this.sourceConfig,
    this.issueCodes = const [],
  });

  factory InstalledModel.fromJson(Map<String, dynamic> j) => InstalledModel(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? j['id'] as String? ?? '',
        contextTokens: j['context_tokens'] as int?,
        componentStatus: j['component_status'] as String?,
        backend: j['backend'] as String?,
        current: j['current'] == true,
        sourceConfig: j['source_config'] as String?,
        issueCodes: [
          if (j['issue_codes'] is List)
            for (final c in j['issue_codes'] as List) if (c is String) c,
        ],
      );

  /// 运行配置名（`strata-<id>.json` 去掉前后缀），切换模型时写入 config 的就是这个
  final String id;

  /// 模型显示名（模型卡上的名字）
  final String name;

  /// 该模型配置里的上下文长度（tokens）
  final int? contextTokens;

  /// 'present'（文件齐全，可加载）/ 'missing_or_invalid'（有文件缺失或损坏）
  final String? componentStatus;

  final String? backend;

  /// 是否是当前正在服务的模型
  final bool current;

  final String? sourceConfig;
  final List<String> issueCodes;

  /// 文件齐全（可以加载）
  bool get isLoadable => componentStatus == 'present';

  /// 上下文长度的可读写法（262144 → 256K）
  String get contextLabel {
    final c = contextTokens;
    if (c == null || c <= 0) return '未设置';
    if (c % 1024 == 0 && c >= 1024) {
      final k = c ~/ 1024;
      return '${k}K';
    }
    return '$c';
  }
}

/// POST /models/select 响应（切换到另一个已安装模型）
///
/// 服务端把引擎、tokenizer、chat template、视觉组件按目标模型的运行配置
/// 重建一遍再换上；旧模型在新模型准备好之前一直服务。
class ModelSwitchResult {
  const ModelSwitchResult({
    this.status,
    this.model,
    this.sourceConfig,
    this.aliases = const [],
    this.contextTokens,
    this.loaded,
  });

  factory ModelSwitchResult.fromJson(Map<String, dynamic> j) => ModelSwitchResult(
        status: j['status'] as String?,
        model: j['model'] as String?,
        sourceConfig: j['source_config'] as String?,
        aliases: [
          if (j['aliases'] is List)
            for (final a in j['aliases'] as List) if (a is String) a,
        ],
        contextTokens: (j['context_tokens'] as num?)?.toInt(),
        loaded: j['loaded'] as bool?,
      );

  final String? status;
  final String? model;
  final String? sourceConfig;
  final List<String> aliases;
  final int? contextTokens;
  final bool? loaded;
}

/// POST /config 响应：{changed:[...], file}
class ConfigSaveResult {
  const ConfigSaveResult({required this.changed, this.file});

  factory ConfigSaveResult.fromJson(Map<String, dynamic> j) => ConfigSaveResult(
        changed: [
          if (j['changed'] is List)
            for (final c in j['changed'] as List) if (c is String) c,
        ],
        file: j['file'] as String?,
      );

  final List<String> changed;
  final String? file;
}

// ─────────────────────────────────────────────────────────────
// /mcp（M2-2 MCP 卡 / M2-13）
// ─────────────────────────────────────────────────────────────

class McpInfo {
  const McpInfo({required this.servers, this.toolCount});

  factory McpInfo.fromJson(Map<String, dynamic> j) => McpInfo(
        servers: [
          if (j['servers'] is List)
            for (final s in j['servers'] as List)
              if (s is Map<String, dynamic>) McpServer.fromJson(s),
        ],
        toolCount: j['tools'] as int?,
      );

  final List<McpServer> servers;
  final int? toolCount;

  int get readyCount => servers.where((s) => s.status == 'ready').length;
}

class McpServer {
  const McpServer({
    required this.name,
    this.status,
    this.transport,
    this.tools = const [],
    this.infoName,
    this.infoVersion,
    this.error,
  });

  factory McpServer.fromJson(Map<String, dynamic> j) {
    final info = j['info'];
    return McpServer(
      name: j['name'] as String? ?? '',
      status: j['status'] as String?,
      transport: j['transport'] as String?,
      tools: [
        if (j['tools'] is List)
          for (final t in j['tools'] as List)
            if (t is Map<String, dynamic>) McpTool.fromJson(t),
      ],
      infoName: info is Map<String, dynamic> ? info['name'] as String? : null,
      infoVersion:
          info is Map<String, dynamic> ? info['version'] as String? : null,
      error: j['error'] as String?,
    );
  }

  final String name;
  final String? status; // ready / failed
  final String? transport; // stdio / sse
  final List<McpTool> tools;
  final String? infoName;
  final String? infoVersion;
  final String? error;

  bool get isReady => status == 'ready';
}

class McpTool {
  const McpTool({required this.tool, this.description});

  factory McpTool.fromJson(Map<String, dynamic> j) => McpTool(
        tool: j['tool'] as String? ?? '',
        description: j['description'] as String?,
      );

  final String tool;
  final String? description;
}

// ─────────────────────────────────────────────────────────────
// /v1/images/generations（M2-6）
// ─────────────────────────────────────────────────────────────

class GeneratedImage {
  const GeneratedImage({
    required this.b64Json,
    this.seed,
    this.size,
    this.created,
  });

  factory GeneratedImage.fromJson(Map<String, dynamic> j) {
    final data = j['data'];
    final first = data is List && data.isNotEmpty && data.first is Map<String, dynamic>
        ? data.first as Map<String, dynamic>
        : const <String, dynamic>{};
    return GeneratedImage(
      b64Json: first['b64_json'] as String? ?? '',
      seed: first['seed'] as int?,
      size: j['size'] as String?,
      created: j['created'] as int?,
    );
  }

  /// PNG 字节的 base64（无 data: 前缀；UI 侧 Uint8List.fromList(base64Decode(...))）
  final String b64Json;
  final int? seed;
  final String? size; // '1024x1024'
  final int? created; // epoch 秒
}

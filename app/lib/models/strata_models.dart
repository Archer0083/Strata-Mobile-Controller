// Strata 接口数据模型（M1-4）。
// 字段形态依据 server-bridge/mock（文档级核实 + 合理猜测标注，实例级实测后对齐）。

/// 思考强度档位（按请求可调，api-notes §2.3）
enum ReasoningEffort { none, low, medium, high }

extension ReasoningEffortName on ReasoningEffort {
  /// 请求体序列化值（小写字符串）
  String get wireName => switch (this) {
        ReasoningEffort.none => 'none',
        ReasoningEffort.low => 'low',
        ReasoningEffort.medium => 'medium',
        ReasoningEffort.high => 'high',
      };
}

/// /v1/models 条目
class ModelInfo {
  const ModelInfo({required this.id});

  final String id;

  factory ModelInfo.fromJson(Map<String, dynamic> json) => ModelInfo(id: json['id'] as String);
}

/// /health 响应（响应体形态待实例级实测）
class HealthInfo {
  const HealthInfo({
    required this.status,
    this.model,
    this.uptimeSeconds,
    this.images = false,
    this.imageGeneration = false,
  });

  final String status;
  final String? model;
  final int? uptimeSeconds;

  /// 是否允许聊天附件带图片（web health.images，缺省 false 门控）
  final bool images;

  /// 是否有 /v1/images/generations 能力（控制 Images tab 显隐）
  final bool imageGeneration;

  factory HealthInfo.fromJson(Map<String, dynamic> json) => HealthInfo(
        status: json['status'] as String,
        model: json['model'] as String?,
        uptimeSeconds: (json['uptime_seconds'] as num?)?.toInt(),
        images: _truthyFlag(json['images']),
        imageGeneration: _truthyFlag(json['image_generation']),
      );

  /// web 口径 truthy 判断（app.js loadHealth/about）：images 字段是
  /// mmproj 模型名——非空字符串即开启；image_generation 同理容忍
  /// bool / 非空 String / 非 0 num，其余视为 false
  static bool _truthyFlag(Object? v) =>
      v is bool ? v : v is String ? v.isNotEmpty : v is num ? v != 0 : false;
}

/// token 用量（流式尾包可能缺失，App 解析需容忍）
class ChatUsage {
  const ChatUsage({required this.promptTokens, required this.completionTokens, required this.totalTokens});

  final int promptTokens;
  final int completionTokens;
  final int totalTokens;

  factory ChatUsage.fromJson(Map<String, dynamic> json) => ChatUsage(
        promptTokens: (json['prompt_tokens'] as num?)?.toInt() ?? 0,
        completionTokens: (json['completion_tokens'] as num?)?.toInt() ?? 0,
        totalTokens: (json['total_tokens'] as num?)?.toInt() ?? 0,
      );
}

/// 采样参数（M2-5 采样抽屉，口径对齐 webUI app.js DEFAULTS）。
///
/// 默认值 = webUI DEFAULTS：temp 1.0 / top_p 0.95 / top_k 20 / max 空 / seed 空。
/// 发送规则（web 端逐行核实）：
/// - 三常量 untouched（等值比较，非脏检查）→ 三件套全不发送，服务端用自身默认；
/// - touched → 三者一起发送；但 temp ≤ 0 → 只发 temperature:0（贪婪解码）；
/// - 「恢复默认即清除」：改回默认值后 untouched 重新成立，字段自然消失；
/// - seed / maxTokens 非空才发送。
class SamplingParams {
  const SamplingParams({
    this.temperature = 1.0,
    this.topP = 0.95,
    this.topK = 20,
    this.maxTokens,
    this.seed,
  });

  static const defaults = SamplingParams();

  /// 采样抽屉滑杆范围（webUI 口径：temp 0-1.5 步长 .05 / top_p .05-1 / top_k 1-64）
  static const temperatureMin = 0.0, temperatureMax = 1.5;
  static const topPMin = 0.05, topPMax = 1.0;
  static const topKMin = 1, topKMax = 64;

  final double temperature;
  final double topP;
  final int topK;
  final int? maxTokens;
  final int? seed;

  /// 三常量是否等于默认值（web 端 untouched 的等值比较实现）
  bool get untouched =>
      temperature == defaults.temperature &&
      topP == defaults.topP &&
      topK == defaults.topK;

  /// 序列化为请求体附加字段（见类注释的发送规则）
  Map<String, dynamic> toWire() => {
        if (!untouched && temperature <= 0)
          'temperature': 0
        else if (!untouched) ...{
          'temperature': temperature,
          'top_p': topP,
          'top_k': topK,
        },
        if (maxTokens != null) 'max_tokens': maxTokens,
        if (seed != null) 'seed': seed,
      };
}

/// 对话请求消息（App → 服务端）
class ChatMessageRequest {
  const ChatMessageRequest({
    required this.role,
    required this.content,
    this.reasoningContent,
    this.imageUrls = const [],
  });

  final String role; // user / assistant / system
  final String content;

  /// 助手回合的思考内容回传（M1-11）。
  ///
  /// Strata 的 chat template 期望 assistant 回合带 reasoning_content
  /// （见 serve/chat_golden.json "assistant with thinking" 用例）；
  /// 非空时才序列化，避免给 user/system 消息带上无意义字段。
  final String? reasoningContent;

  /// 图片附件（dataURL，M2-5）。非空时 content 序列化为 OpenAI 多模态数组：
  /// [{"type":"text","text":...},{"type":"image_url","image_url":{"url":"data:..."}}]。
  /// 与 web 端同口径：历史 user 消息同样带图回传（web apiMessages 对全部
  /// user 消息生效，非仅当前轮）。dataURL 只留在内存态（UiChatMessage），
  /// 不写 DB——27MB 级文本入库会把库撑爆；从 DB 加载的历史自然无图。
  final List<String> imageUrls;

  Map<String, dynamic> toJson() => {
        'role': role,
        // 有图走数组形态，无图保持纯字符串（纯文本请求不过多模态路径）
        'content': imageUrls.isEmpty
            ? content
            : [
                {'type': 'text', 'text': content},
                for (final u in imageUrls)
                  {
                    'type': 'image_url',
                    'image_url': {'url': u},
                  },
              ],
        if (reasoningContent != null && reasoningContent!.isNotEmpty)
          'reasoning_content': reasoningContent,
      };
}

/// 非流式对话响应
class ChatCompletion {
  const ChatCompletion({required this.content, this.reasoningContent, this.usage});

  final String content;
  final String? reasoningContent; // 字段名待实例级实测（Mock 采用 reasoning_content）
  final ChatUsage? usage;
}

/// 流式对话事件（ChatScreen 逐事件渲染）
sealed class ChatStreamEvent {
  const ChatStreamEvent();
}

/// 思考增量（折叠区块内容）
class ReasoningDeltaEvent extends ChatStreamEvent {
  const ReasoningDeltaEvent(this.text);

  final String text;
}

/// 正文增量
class ContentDeltaEvent extends ChatStreamEvent {
  const ContentDeltaEvent(this.text);

  final String text;
}

/// 流结束（携带尾包 usage，可能为 null——真实服务可能不返回）
class FinishedEvent extends ChatStreamEvent {
  const FinishedEvent(this.usage, {this.diagnostics});

  final ChatUsage? usage;

  /// SSE 解析诊断（M1-11）：用于把「无内容且无报错」变成可观测问题
  final SseDiagnostics? diagnostics;
}

/// SSE 解析诊断计数（M1-11 内测反馈修复引入）
///
/// 目的：v0.0.1 内测出现「对话只返回一个占位符、看不到思维链与正文」且无任何报错。
/// 根因是解析层静默吞异常（`on FormatException {}`）——坏数据被跳过，日志与 UI 都无痕迹。
/// 现在把「收到多少 chunk / 有多少坏行 / 有多少解码失败」随流结束上报，
/// 一旦服务端形态与预期不符，可立刻区分「服务端没给内容」与「客户端解析掉了内容」。
class SseDiagnostics {
  const SseDiagnostics({
    required this.deltaChunks,
    this.malformedLines = 0,
    this.decodeErrors = 0,
  });

  /// 成功解析出 delta 的 chunk 数（含首块 role-only 与空 content 块）
  final int deltaChunks;

  /// JSON 解析失败并被跳过的行数
  final int malformedLines;

  /// UTF-8 解码失败（多字节字符被切断）的行数
  final int decodeErrors;

  /// 是否完全没有任何可解析的 chunk
  bool get gotNothing => deltaChunks == 0;

  /// 是否存在被丢弃的数据
  bool get droppedSomething => malformedLines > 0 || decodeErrors > 0;

  @override
  String toString() =>
      'SseDiagnostics(delta=$deltaChunks, bad=$malformedLines, decodeErr=$decodeErrors)';
}

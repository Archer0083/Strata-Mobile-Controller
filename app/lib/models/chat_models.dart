// 对话 UI 消息模型（M1-6）。
// 与 strata_models.dart 的 ChatMessageRequest（请求 DTO）区分：
// 本文件是 ChatScreen 渲染层消息，含流式中间态与错误标记。

import 'strata_models.dart';

/// 文本附件（M2-5）：白名单内文本文件的内存形态。
/// 发送时由 AttachmentService 以反引号围栏代码块拼进 prompt（对齐 web fileBlock）。
/// 内存态不落库（与 web 刷新即失同口径）。
class AttachedTextFile {
  const AttachedTextFile({required this.name, required this.text});

  final String name;
  final String text;
}

/// UI 层单条消息（用户 / 助手）
class UiChatMessage {
  const UiChatMessage({
    required this.id,
    required this.isUser,
    this.content = '',
    this.reasoning,
    this.usage,
    this.error,
    this.timestamp,
    this.stopped = false,
    this.thinkSecs,
    this.genSecs,
    this.imageUrls = const [],
  });

  final int id;
  final bool isUser;

  /// 正文（流式中逐 delta 追加）
  final String content;

  /// 思考内容（reasoning delta 累积；null 表示尚无思考内容）
  final String? reasoning;

  /// token 用量（流结束尾包，可能为 null——真实服务可不返回）
  final ChatUsage? usage;

  /// 失败文案（非 null 表示该消息发送/流中断失败，展示后不参与后续请求历史）
  final String? error;

  /// 消息时间（M1-12：落库/导出用）。内存新建消息为 null，落库时取当前时刻；
  /// 从历史会话加载时带 DB 值。
  final DateTime? timestamp;

  /// 用户主动停止（M2-5）：保留已生成文本，meta 带「已停止」标注（web 口径）
  final bool stopped;

  /// 思考耗时秒（M2-5）：首个 reasoning delta → 首个 content delta 的墙钟差。
  /// 内存态：被停且无正文时流结束补算；重载历史后为 null（web 端刷新后同样丢失）
  final double? thinkSecs;

  /// 生成总时长秒（M2-5）：首个 delta（reasoning 或 content）→ 流结束的墙钟差，
  /// 用于 meta 的 tok/s 速率。内存态，同上不落库
  final double? genSecs;

  /// 图片附件 dataURL（M2-5，仅 user 消息）。内存态不落库（体积），
  /// 同会话内多轮回传与 web 端一致
  final List<String> imageUrls;

  UiChatMessage copyWith({
    String? content,
    String? reasoning,
    ChatUsage? usage,
    String? error,
    DateTime? timestamp,
    bool? stopped,
    double? thinkSecs,
    double? genSecs,
    List<String>? imageUrls,
  }) =>
      UiChatMessage(
        id: id,
        isUser: isUser,
        content: content ?? this.content,
        reasoning: reasoning ?? this.reasoning,
        usage: usage ?? this.usage,
        error: error ?? this.error,
        timestamp: timestamp ?? this.timestamp,
        stopped: stopped ?? this.stopped,
        thinkSecs: thinkSecs ?? this.thinkSecs,
        genSecs: genSecs ?? this.genSecs,
        imageUrls: imageUrls ?? this.imageUrls,
      );
}

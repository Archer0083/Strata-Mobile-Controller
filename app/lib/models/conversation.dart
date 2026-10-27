// 会话与消息的持久化模型（M1-12，SPEC v0.3.5 §9「Conversation 与 Message」）。
//
// 与 chat_models.dart 的 UiChatMessage（渲染层）区分：
// 本文件是数据层模型，直接对应 sqflite 的 conversations / messages 两张表，
// 也是 .json 导出/导入 schema 的内存形态。
//
// 字段约定（SPEC §9 schema 演进约定）：
// - role 用字符串枚举 'user' / 'assistant'（非 isUser 布尔）——未来扩展 system 不破坏 schema
// - 时间戳用 ISO 8601 字符串入库（可读且带时区）
// - usage 的 token 字段导出时用 snake_case，与上游 OpenAI 兼容接口一致

import 'chat_models.dart';
import 'strata_models.dart';

/// 会话（conversations 表）
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.profileId,
    required this.effort,
    required this.createdAt,
    required this.updatedAt,
    this.modelId,
    this.pinned = false,
  });

  final String id;

  /// 标题：自动取首句摘要（可手动改名）
  final String title;

  /// 所属主机 Profile——不同主机的对话必须隔离，抽屉按此分组
  final String profileId;

  /// 创建会话时的模型（可空：发送前无法确知，请求时不携带 model 字段）
  final String? modelId;

  /// 创建会话时的思考档位（none/low/medium/high），导出元信息用
  final String effort;

  final DateTime createdAt;

  /// 最近活动时间：抽屉排序键（倒序）
  final DateTime updatedAt;

  /// 置顶（参考 TRAE 移动端任务列表）
  final bool pinned;

  Conversation copyWith({
    String? title,
    String? modelId,
    DateTime? updatedAt,
    bool? pinned,
  }) =>
      Conversation(
        id: id,
        title: title ?? this.title,
        profileId: profileId,
        modelId: modelId ?? this.modelId,
        effort: effort,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        pinned: pinned ?? this.pinned,
      );
}

/// 消息（messages 表）。
///
/// 与 UiChatMessage 的关系：UI 渲染用 UiChatMessage（含流式中间态），
/// 本模型是落库/导出/导入的稳定形态；历史会话经 [toUi] 转渲染层
/// （落库方向由 ChatController 直接构造本模型，不经转换）。
class ConversationMessage {
  const ConversationMessage({
    this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.timestamp,
    required this.seq,
    this.reasoning,
    this.usage,
    this.error,
    this.stopped = false,
    this.imageUrls = const [],
  });

  /// DB 自增 rowid；内存新消息为 null（插入后回填）
  final int? id;

  final String conversationId;

  /// 'user' / 'assistant'（字符串枚举，SPEC §9）
  final String role;

  final String content;

  /// 思考链正文（可空）——差异化能力，导出必须保留
  final String? reasoning;

  /// token 用量（可空）
  final ChatUsage? usage;

  /// 该条消息的错误信息（可空），导出时保留失败上下文
  final String? error;

  /// 用户主动停止（M2-5）：保留文本、meta 标注「已停止」
  final bool stopped;

  /// 图片附件（M2-5 补齐，v0.0.10 起落库）。
  ///
  /// 存的是**落盘后的本地文件路径**（file:// 绝对路径），不是 dataURL——
  /// dataURL 体积可达 27MB/张，入库会把 DB 撑爆。渲染层需要 dataURL 时
  /// 由 [image_service] 按路径读回并缓存。
  final List<String> imageUrls;

  final DateTime timestamp;

  /// 会话内顺序，稳定排序键
  final int seq;

  bool get isUser => role == 'user';

  /// 数据层 → 渲染层（ChatScreen 加载历史会话）
  UiChatMessage toUi() => UiChatMessage(
        id: id ?? seq,
        isUser: isUser,
        content: content,
        reasoning: reasoning,
        usage: usage,
        error: error,
        timestamp: timestamp,
        stopped: stopped,
        imageUrls: imageUrls,
      );

}

/// 生成会话 id：时间戳 + 随机后缀（避免依赖 uuid 包）
String newConversationId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
    '${DateTime.now().millisecondsSinceEpoch.hashCode.toUnsigned(20).toRadixString(36)}';

/// 标题自动生成：取首条用户消息前 24 字符，截断加省略号
String conversationTitleFrom(String firstMessage) {
  final t = firstMessage.replaceAll('\n', ' ').trim();
  if (t.length <= 24) return t.isEmpty ? '新会话' : t;
  return '${t.substring(0, 24)}…';
}

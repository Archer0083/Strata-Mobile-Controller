// 会话导入服务（M1-12.5，SPEC v0.3.5 §6.1 第 5 条「会话导入的容错」/ §5.3 仅 .json 可回导）。
//
// 链路：file_picker（SAF，withData 读字节——SAF 下 path 可能为 null）→
// utf8 解码 → jsonDecode（FormatException 捕获）→ schema 校验 → 逐条容错解析 →
// 以新会话 id 写入当前 Profile（导入是"复制进来"，不与导出源冲突）。
//
// 容错规则（SPEC §6.1 第 5 条）：
// - schema_version 缺失 → 按 v1 宽松接受；大于当前 → 拒绝并提示升级；非整数 → 拒绝
// - 顶层 conversation / messages 缺失 → 直接拒绝，不猜测
// - 单条消息可选字段（reasoning/usage/error/timestamp）缺失 → 默认值容忍
// - 单条消息必需字段（role/content）缺失或非法 → 跳过该条并计数
// - 有效消息为 0 → 拒绝导入

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../models/strata_models.dart' show ChatUsage;
import 'conversation_repository.dart';
import 'export_service.dart' show kExportSchemaVersion;
import 'image_store.dart';

/// 导入失败：message 为已本地化的用户可见提示
class ImportException implements Exception {
  const ImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 解析产物（尚未入库；id/profileId 由入库时分配）
class ParsedConversation {
  const ParsedConversation({
    required this.title,
    required this.modelId,
    required this.effort,
    required this.createdAt,
    required this.messages,
    required this.skippedCount,
    this.exportedAt,
    this.pinned = false,
    this.updatedAt,
  });

  final String title;
  final String? modelId;
  final String effort;
  final DateTime createdAt;
  final List<ConversationMessage> messages;

  /// 因格式异常被跳过的消息条数（导入完成提示「已导入 N 条，跳过 M 条」）
  final int skippedCount;

  /// 源文件的导出时间（顶层 exported_at）。用于导入预览显示「导出时间 …」；
  /// 缺失或非法时为 null，预览隐藏该段。
  final DateTime? exportedAt;

  /// 是否置顶（打包导出含 pinned，单会话导出不含 → 默认 false）
  final bool pinned;

  /// 源会话的最后更新时间（打包导出含 updated_at）。用于导入后保持相对顺序。
  final DateTime? updatedAt;
}

/// 导入产物的联合类型：单会话 / 会话包。
///
/// v0.0.10 起 App 只保留一条对外的导入通道（[ImportService.pickAndParseAuto]），
/// 由文件自身形态决定走哪条解析路径——用户不再需要分辨"会话文件"和"会话包"。
sealed class ParsedImport {
  const ParsedImport();

  /// 会话总数（单会话为 1）
  int get conversationCount;

  /// 消息总数
  int get messageCount;

  /// 被跳过的条数（消息级 + 会话级）
  int get skippedCount;

  /// 源文件导出时间
  DateTime? get exportedAt;
}

/// 单会话导入产物
class ParsedImportSingle extends ParsedImport {
  const ParsedImportSingle(this.conversation);

  final ParsedConversation conversation;

  @override
  int get conversationCount => 1;

  @override
  int get messageCount => conversation.messages.length;

  @override
  int get skippedCount => conversation.skippedCount;

  @override
  DateTime? get exportedAt => conversation.exportedAt;
}

/// 会话包导入产物
class ParsedImportBundle extends ParsedImport {
  const ParsedImportBundle(this.bundle);

  final ParsedBundle bundle;

  @override
  int get conversationCount => bundle.conversations.length;

  @override
  int get messageCount => bundle.totalMessages;

  @override
  int get skippedCount => bundle.skippedCount;

  @override
  DateTime? get exportedAt => bundle.exportedAt;
}

/// 导入结果（已入库）
class ImportResult {
  const ImportResult({required this.conversation, required this.imported, required this.skipped});

  final Conversation conversation;
  final int imported;
  final int skipped;
}

/// 打包文件解析产物（多个会话；M1-12.6「导出全部会话」的回导形态）
class ParsedBundle {
  const ParsedBundle({
    required this.conversations,
    required this.skippedCount,
    this.exportedAt,
  });

  final List<ParsedConversation> conversations;

  /// 全部会话累计被跳过的消息条数
  final int skippedCount;

  /// 源文件的导出时间（顶层 exported_at）
  final DateTime? exportedAt;

  /// 全部会话的消息总数
  int get totalMessages =>
      conversations.fold(0, (sum, c) => sum + c.messages.length);
}

class ImportService {
  ImportService({Future<FilePickerResult?> Function({
    String? dialogTitle,
    List<String>? allowedExtensions,
    bool withData,
  })? picker})
      : _picker = picker ?? _defaultPick;

  /// 文件选择器（可注入：单测直接喂字节）
  final Future<FilePickerResult?> Function({
    String? dialogTitle,
    List<String>? allowedExtensions,
    bool withData,
  }) _picker;
  static Future<FilePickerResult?> _defaultPick({
    String? dialogTitle,
    List<String>? allowedExtensions,
    bool withData = false,
  }) =>
      FilePicker.platform.pickFiles(
        dialogTitle: dialogTitle,
        type: FileType.custom,
        allowedExtensions: allowedExtensions ?? const ['json'],
        withData: withData,
      );

  /// 选文件 → 解析 → 入库。返回 null 表示用户取消选择。
  Future<ImportResult?> pickAndImport({
    required String profileId,
    required ConversationRepository repository,
  }) async {
    final parsed = await pickAndParse();
    if (parsed == null) return null;
    return importParsed(parsed, profileId: profileId, repository: repository);
  }

  /// 选文件 → 解析（不入库）。返回 null 表示用户取消选择。
  ///
  /// UI 链路用这个变体：解析完先弹「预览确认」，用户确认后再调 [importParsed]。
  Future<ParsedConversation?> pickAndParse() async {
    final result = await _picker(
      dialogTitle: '选择要导入的会话文件（.json）',
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final bytes = result.files.single.bytes;
    if (bytes == null) {
      throw const ImportException('无法读取所选文件（SAF 未返回内容）');
    }
    return parse(utf8.decode(bytes, allowMalformed: true));
  }

  /// 选文件 → 解析打包文件（不入库）。返回 null 表示用户取消选择。
  ///
  /// 与 [pickAndParse] 的差异：解析的是「导出全部会话」产出的多会话打包文件。
  /// 打包文件的顶层是 `conversations` 数组；单个会话文件（顶层 `conversation`
  /// 对象）不是打包文件，会被拒绝并提示。
  Future<ParsedBundle?> pickAndParseBundle() async {
    final result = await _picker(
      dialogTitle: '选择要导入的会话包（.json）',
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final bytes = result.files.single.bytes;
    if (bytes == null) {
      throw const ImportException('无法读取所选文件（SAF 未返回内容）');
    }
    return parseBundle(utf8.decode(bytes, allowMalformed: true));
  }

  /// 选文件 → 解析（自动识别单会话 / 会话包，不入库）。
  /// 返回 null 表示用户取消选择。
  ///
  /// v0.0.10 起 UI 的唯一导入入口：用户无论导出的是"单个会话"还是"全部会话"，
  /// 都可以直接喂进这个入口，由文件自身形态决定解析路径。
  Future<ParsedImport?> pickAndParseAuto() async {
    final result = await _picker(
      dialogTitle: '选择要导入的会话文件（.json）',
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final bytes = result.files.single.bytes;
    if (bytes == null) {
      throw const ImportException('无法读取所选文件（SAF 未返回内容）');
    }
    return parseAuto(utf8.decode(bytes, allowMalformed: true));
  }

  /// 解析 .json 文本（纯函数，可单测）——自动识别单会话 / 会话包。
  ///
  /// 形态嗅探规则（v0.0.10）：
  /// - 顶层含 `conversation`（对象）→ 单会话
  /// - 顶层含 `conversations`（数组）→ 会话包
  /// - 两者都没有 → 拒绝，并给出可操作的提示（列出 App 实际导出的两种形态）
  ///
  /// 抛 [ImportException]：JSON 无效 / schema_version 超前或非法 /
  /// 顶层结构缺失 / 有效消息为 0。
  ParsedImport parseAuto(String source) {
    final decoded = _decodeObject(source);
    _checkSchemaVersion(decoded);

    final single = decoded['conversation'];
    if (single is Map<String, dynamic>) {
      return ParsedImportSingle(_parseConversation(single,
          exportedAt: _tryParseDate(decoded['exported_at'])));
    }

    final bundle = decoded['conversations'];
    if (bundle is List) {
      return ParsedImportBundle(
          _parseBundleBody(bundle, _tryParseDate(decoded['exported_at'])));
    }

    throw const ImportException(
        '文件结构无法识别：不是本 App 导出的会话文件。\n'
        '本 App 导出的 .json 顶层为 conversation（单个会话）或 conversations（会话包）。');
  }

  /// 解析 .json 文本（纯函数，可单测）。
  ///
  /// 抛 [ImportException]：JSON 无效 / schema_version 超前或非法 /
  /// 顶层结构缺失 / 有效消息为 0。
  ParsedConversation parse(String source) {
    final decoded = _decodeObject(source);
    _checkSchemaVersion(decoded);
    // 单会话文件：会话对象在顶层 `conversation` 字段下，先解包再复用解析体
    final conv = decoded['conversation'];
    if (conv is! Map<String, dynamic>) {
      throw const ImportException('文件缺少 conversation 字段，不是本 App 导出的会话');
    }
    return _parseConversation(conv,
        exportedAt: _tryParseDate(decoded['exported_at']));
  }

  /// 解析「导出全部会话」产出的 .json 打包文件（多个会话）。
  ///
  /// 打包 schema（v1）：顶层 `conversations` 数组，元素与单会话导出的
  /// `conversation` 对象同构。容错规则同 [parse]，但按会话粒度处理：
  /// - 单个会话结构非法 → 跳过该会话并计数，不让整份文件失败
  /// - 全部会话都非法 → 拒绝导入
  ParsedBundle parseBundle(String source) {
    final decoded = _decodeObject(source);
    _checkSchemaVersion(decoded);

    final raw = decoded['conversations'];
    if (raw is! List) {
      throw const ImportException('文件缺少 conversations 字段，不是本 App 导出的会话包');
    }
    return _parseBundleBody(raw, _tryParseDate(decoded['exported_at']));
  }

  /// 打包文件主体解析（`conversations` 数组 → ParsedBundle）。
  ///
  /// 由 [parseBundle] 与 [parseAuto] 共用。容错规则：单个会话结构非法 →
  /// 跳过该会话并计数，不让整份文件失败；全部会话都非法 → 拒绝导入。
  ParsedBundle _parseBundleBody(List raw, DateTime? exportedAt) {
    final conversations = <ParsedConversation>[];
    var skipped = 0;
    for (final item in raw) {
      if (item is! Map<String, dynamic>) {
        skipped++;
        continue;
      }
      try {
        conversations.add(_parseConversation(item, exportedAt: exportedAt));
      } on ImportException {
        // 单个会话坏数据不应让整份打包文件失败（与单条消息跳过的容错思路一致）
        skipped++;
      }
    }
    if (conversations.isEmpty) {
      throw const ImportException('文件中没有可导入的有效会话');
    }
    return ParsedBundle(
      conversations: conversations,
      skippedCount: skipped,
      exportedAt: exportedAt,
    );
  }

  /// 顶层 JSON 解码 → Map（失败即抛 ImportException）
  Map<String, dynamic> _decodeObject(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const ImportException('文件不是有效的 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ImportException('文件不是有效的 JSON（顶层应为对象）');
    }
    return decoded;
  }

  /// schema_version 检查（缺失按 v1 宽松；非整数拒绝；超前拒绝）
  void _checkSchemaVersion(Map<String, dynamic> decoded) {
    final sv = decoded['schema_version'];
    if (sv == null) return;
    if (sv is! int || sv < 1) {
      throw const ImportException('schema_version 非法（须为正整数），已拒绝导入');
    }
    if (sv > kExportSchemaVersion) {
      throw ImportException('该文件来自更新版本的 App（schema_version $sv > '
          '$kExportSchemaVersion），请先升级后再导入');
    }
  }

  /// 解析单个会话对象（[parse] 与 [parseBundle] 共用）。
  ///
  /// [conv] 是会话对象本身（单会话文件在顶层 `conversation` 字段下、已由
  /// [parse] 解包；打包文件的 `conversations` 数组元素即会话对象）。
  /// [exportedAt] 从顶层传入（打包文件的导出时间对所有会话一致）。
  ParsedConversation _parseConversation(
    Map<String, dynamic> conv, {
    DateTime? exportedAt,
  }) {
    final rawMessages = conv['messages'];
    if (rawMessages is! List) {
      throw const ImportException('文件缺少 messages 字段，不是本 App 导出的会话');
    }

    // 会话级元信息：title 缺省「导入的会话」；created_at 缺省/非法用导入时刻
    final title = switch (conv['title']) {
      String s when s.trim().isNotEmpty => s.trim(),
      _ => '导入的会话',
    };
    final modelId = conv['model'] is String ? conv['model'] as String? : null;
    final effort = switch (conv['effort']) {
      String s when s.trim().isNotEmpty => s.trim(),
      _ => 'medium',
    };
    final createdAt = _tryParseDate(conv['created_at']) ?? DateTime.now();
    final pinned = conv['pinned'] == true;
    final updatedAt = _tryParseDate(conv['updated_at']);

    // 逐条容错：role/content 必需，缺失或非法跳过并计数
    final messages = <ConversationMessage>[];
    var skipped = 0;
    var seq = 0;
    for (final raw in rawMessages) {
      if (raw is! Map) {
        skipped++;
        continue;
      }
      final role = raw['role'];
      final content = raw['content'];
      if (role is! String || (role != 'user' && role != 'assistant') ||
          content is! String) {
        skipped++;
        continue;
      }
      messages.add(ConversationMessage(
        conversationId: '', // 入库前由 importParsed 分配
        role: role,
        content: content,
        reasoning: raw['reasoning'] is String ? raw['reasoning'] as String? : null,
        usage: raw['usage'] is Map<String, dynamic>
            ? ChatUsage.fromJson(raw['usage'] as Map<String, dynamic>)
            : null,
        error: raw['error'] is String ? raw['error'] as String? : null,
        timestamp: _tryParseDate(raw['timestamp']) ?? DateTime.now(),
        seq: seq++,
        stopped: raw['stopped'] == true,
        imageUrls: _parseImageUrls(raw),
      ));
    }
    if (messages.isEmpty) {
      throw const ImportException('文件中没有可导入的有效消息');
    }
    return ParsedConversation(
      title: title,
      modelId: modelId,
      effort: effort,
      createdAt: createdAt,
      messages: messages,
      skippedCount: skipped,
      exportedAt: exportedAt,
      pinned: pinned,
      updatedAt: updatedAt,
    );
  }

  /// 解析消息级图片附件。
  ///
  /// v0.0.10 起导出格式携带 `images`（dataURL 数组）；v0.0.9 及更早的导出
  /// 没有该字段 → 返回空列表（旧文件照常导入，只是无图）。
  List<String> _parseImageUrls(Map raw) {
    final imgs = raw['images'];
    if (imgs is! List) return const [];
    final out = <String>[];
    for (final item in imgs) {
      if (item is String && item.isNotEmpty) out.add(item);
    }
    return out;
  }

  /// 解析产物 → 当前 Profile 下新建会话并写入（导入即复制，不回写源 id）
  ///
  /// v0.0.10：图片附件（导入文件里的 dataURL）会先落盘再把路径入库；
  /// 置顶状态保留；`stopped` 标记保留。
  Future<ImportResult> importParsed(
    ParsedConversation parsed, {
    required String profileId,
    required ConversationRepository repository,
  }) async {
    final now = DateTime.now();
    final conversation = Conversation(
      id: newConversationId(),
      title: parsed.title,
      profileId: profileId,
      modelId: parsed.modelId,
      effort: parsed.effort,
      createdAt: now,
      updatedAt: now,
      pinned: parsed.pinned,
    );
    await repository.createConversation(conversation);
    final store = ImageStore();
    for (final m in parsed.messages) {
      // 图片：dataURL → 落盘 → 存路径（DB 不存 dataURL）
      var storedPaths = const <String>[];
      if (m.imageUrls.isNotEmpty) {
        final paths = await store.persistAll(
            conversationId: conversation.id, seq: m.seq, dataUrls: m.imageUrls);
        storedPaths = paths.whereType<String>().toList();
      }
      await repository.insertMessage(ConversationMessage(
        conversationId: conversation.id,
        role: m.role,
        content: m.content,
        reasoning: m.reasoning,
        usage: m.usage,
        error: m.error,
        stopped: m.stopped,
        imageUrls: storedPaths,
        timestamp: m.timestamp,
        seq: m.seq,
      ));
    }
    return ImportResult(
      conversation: conversation,
      imported: parsed.messages.length,
      skipped: parsed.skippedCount,
    );
  }

  /// 打包解析产物 → 当前 Profile 下新建全部会话并写入。
  ///
  /// 与单会话导入同理：导入即复制（分配新 id），不与导出源 id 冲突。
  /// 返回入库的会话列表（按打包文件中的顺序），供 UI 跳转第一个。
  Future<List<Conversation>> importBundle(
    ParsedBundle bundle, {
    required String profileId,
    required ConversationRepository repository,
  }) async {
    final created = <Conversation>[];
    for (final parsed in bundle.conversations) {
      final result = await importParsed(
        parsed,
        profileId: profileId,
        repository: repository,
      );
      created.add(result.conversation);
    }
    return created;
  }

  /// 统一入库（v0.0.10）：按产物类型分派到单会话 / 会话包路径。
  ///
  /// 返回新建的会话列表（单会话时长度为 1），供 UI 跳转第一个。
  Future<List<Conversation>> importAuto(
    ParsedImport parsed, {
    required String profileId,
    required ConversationRepository repository,
  }) async {
    switch (parsed) {
      case ParsedImportSingle(:final conversation):
        final r = await importParsed(conversation,
            profileId: profileId, repository: repository);
        return [r.conversation];
      case ParsedImportBundle(:final bundle):
        return importBundle(bundle,
            profileId: profileId, repository: repository);
    }
  }

  static DateTime? _tryParseDate(Object? v) {
    if (v is! String) return null;
    return DateTime.tryParse(v);
  }
}

/// 导入服务（App 级单例）。
///
/// 抽成 provider 是为了让 widget 测试能注入假的文件选择器（直接喂字节），
/// 避免真的拉起系统文件选择面板。
final importServiceProvider = Provider<ImportService>((_) => ImportService());

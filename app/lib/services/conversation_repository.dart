// 会话/消息持久化仓库（M1-12，SPEC v0.3.5 §7 数据层 / ADR-9 决策 1）。
//
// 职责：conversations / messages 两表的全部读写，对上层（ChatController、
// ConversationDrawer、ExportService、ImportService）隐藏 SQL。
//
// 写穿策略（ChatController 消费方式）：
// - 发送时：insert 用户消息 + 助手占位消息（拿到 DB id 后进 UI 状态）
// - 流式中：纯内存渲染，不逐 delta 落库（避免高频写放大）
// - 流结束/失败：update 助手消息一次写回最终 content/reasoning/usage/error

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../data/app_database.dart';
import '../models/conversation.dart';
import '../models/strata_models.dart';

class ConversationRepository {
  ConversationRepository([Future<Database>? dbFuture])
      : _dbFuture = dbFuture ?? openAppDatabase();

  final Future<Database> _dbFuture;

  // ---------- 会话 ----------

  /// 全量会话列表：置顶优先，组内 updatedAt 倒序（抽屉分组展示用）
  Future<List<Conversation>> listConversations() async {
    final db = await _dbFuture;
    final rows = await db.query(
      'conversations',
      orderBy: 'pinned DESC, updated_at DESC',
    );
    return rows.map(_conversationFromRow).toList();
  }

  Future<Conversation?> findConversation(String id) async {
    final db = await _dbFuture;
    final rows =
        await db.query('conversations', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _conversationFromRow(rows.first);
  }

  Future<Conversation> createConversation(Conversation c) async {
    final db = await _dbFuture;
    await db.insert('conversations', {
      'id': c.id,
      'title': c.title,
      'profile_id': c.profileId,
      'model_id': c.modelId,
      'effort': c.effort,
      'created_at': c.createdAt.toIso8601String(),
      'updated_at': c.updatedAt.toIso8601String(),
      'pinned': c.pinned ? 1 : 0,
    });
    return c;
  }

  Future<void> renameConversation(String id, String title) async {
    final db = await _dbFuture;
    await db
        .update('conversations', {'title': title}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setPinned(String id, bool pinned) async {
    final db = await _dbFuture;
    await db
        .update('conversations', {'pinned': pinned ? 1 : 0}, where: 'id = ?', whereArgs: [id]);
  }

  /// 会话有新消息时刷新 updatedAt（影响抽屉排序）
  Future<void> touchConversation(String id) async {
    final db = await _dbFuture;
    await db.update(
      'conversations',
      {'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 删除会话并级联删消息（事务双删，不依赖外键约束）
  Future<void> deleteConversation(String id) async {
    final db = await _dbFuture;
    await db.transaction((txn) async {
      await txn.delete('messages', where: 'conversation_id = ?', whereArgs: [id]);
      await txn.delete('conversations', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// 清空全部会话（设置页「清空全部会话」，二次确认由 UI 承担）
  Future<void> deleteAll() async {
    final db = await _dbFuture;
    await db.transaction((txn) async {
      await txn.delete('messages');
      await txn.delete('conversations');
    });
  }

  // ---------- 消息 ----------

  /// 按会话加载消息（seq 升序，稳定还原对话顺序）
  Future<List<ConversationMessage>> loadMessages(String conversationId) async {
    final db = await _dbFuture;
    final rows = await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'seq ASC',
    );
    return rows.map(_messageFromRow).toList();
  }

  /// 插入消息，返回回填了 DB id 的实例
  Future<ConversationMessage> insertMessage(ConversationMessage m) async {
    final db = await _dbFuture;
    final id = await db.insert('messages', {
      'conversation_id': m.conversationId,
      'role': m.role,
      'content': m.content,
      'reasoning': m.reasoning,
      'usage_json': _usageToJson(m.usage),
      'error': m.error,
      'stopped': m.stopped ? 1 : 0,
      'images_json': _imagesToJson(m.imageUrls),
      'timestamp': m.timestamp.toIso8601String(),
      'seq': m.seq,
    });
    return ConversationMessage(
      id: id,
      conversationId: m.conversationId,
      role: m.role,
      content: m.content,
      reasoning: m.reasoning,
      usage: m.usage,
      error: m.error,
      stopped: m.stopped,
      imageUrls: m.imageUrls,
      timestamp: m.timestamp,
      seq: m.seq,
    );
  }

  /// 写回流结束态（content/reasoning/usage/error 一次落库）
  Future<void> updateMessage(ConversationMessage m) async {
    final db = await _dbFuture;
    await db.update(
      'messages',
      {
        'content': m.content,
        'reasoning': m.reasoning,
        'usage_json': _usageToJson(m.usage),
        'error': m.error,
        'stopped': m.stopped ? 1 : 0,
      },
      where: 'id = ?',
      whereArgs: [m.id],
    );
  }

  // ---------- 统计 ----------

  Future<int> countConversations() async {
    final db = await _dbFuture;
    final r = await db.rawQuery('SELECT COUNT(*) AS n FROM conversations');
    return (r.first['n'] as int?) ?? 0;
  }

  Future<int> countMessages() async {
    final db = await _dbFuture;
    final r = await db.rawQuery('SELECT COUNT(*) AS n FROM messages');
    return (r.first['n'] as int?) ?? 0;
  }

  /// 各会话的消息数（抽屉副行展示；一条 GROUP BY 避免 N+1 查询）
  Future<Map<String, int>> countMessagesGrouped() async {
    final db = await _dbFuture;
    final rows = await db.rawQuery(
        'SELECT conversation_id, COUNT(*) AS n FROM messages GROUP BY conversation_id');
    return {
      for (final r in rows) r['conversation_id'] as String: (r['n'] as int?) ?? 0,
    };
  }

  /// 库文件估算占用（设置页「查看本地会话占用」；getDatabasesPath 由 db.path 替代）
  Future<int> estimateSizeBytes() async {
    final db = await _dbFuture;
    final r = await db.rawQuery('PRAGMA page_count');
    final pageSize = await db.rawQuery('PRAGMA page_size');
    final pages = (r.first['page_count'] as int?) ?? 0;
    final size = (pageSize.first['page_size'] as int?) ?? 0;
    return pages * size;
  }

  // ---------- 行 ↔ 模型 ----------

  Conversation _conversationFromRow(Map<String, Object?> row) => Conversation(
        id: row['id'] as String,
        title: row['title'] as String,
        profileId: row['profile_id'] as String,
        modelId: row['model_id'] as String?,
        effort: row['effort'] as String? ?? 'medium',
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
        pinned: (row['pinned'] as int?) == 1,
      );

  ConversationMessage _messageFromRow(Map<String, Object?> row) =>
      ConversationMessage(
        id: row['id'] as int?,
        conversationId: row['conversation_id'] as String,
        role: row['role'] as String,
        content: (row['content'] as String?) ?? '',
        reasoning: row['reasoning'] as String?,
        usage: _usageFromJson(row['usage_json'] as String?),
        error: row['error'] as String?,
        stopped: (row['stopped'] as int? ?? 0) == 1,
        imageUrls: _imagesFromJson(row['images_json'] as String?),
        timestamp: DateTime.tryParse(row['timestamp'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        seq: (row['seq'] as int?) ?? 0,
      );

  /// 图片路径列表 → JSON（空列表写 '[]'，不写 NULL）
  static String _imagesToJson(List<String> paths) => jsonEncode(paths);

  /// JSON → 图片路径列表（容错：非法 JSON / 非数组 → 空列表）
  static List<String> _imagesFromJson(String? s) {
    if (s == null || s.isEmpty) return const [];
    try {
      final decoded = jsonDecode(s);
      if (decoded is! List) return const [];
      return decoded.whereType<String>().toList();
    } on FormatException {
      return const [];
    }
  }

  static String? _usageToJson(ChatUsage? u) => u == null
      ? null
      : jsonEncode({
          'prompt_tokens': u.promptTokens,
          'completion_tokens': u.completionTokens,
          'total_tokens': u.totalTokens,
        });

  static ChatUsage? _usageFromJson(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return ChatUsage.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } on FormatException {
      return null;
    }
  }
}

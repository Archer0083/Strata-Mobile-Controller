// 数据库打开与建表（M1-12，SPEC v0.3.5 §7 数据层 / §14 目录结构 data/）。
//
// 设计要点：
// - 单库单连接：App 生命周期内复用（sqflite 内部有连接池，重复 openDatabase
//   同一路径也会返回复用句柄，这里再包一层缓存兜底测试注入）
// - schema 版本 1 起步：后续演进走 onUpgrade 增量迁移，不改历史
// - 删除会话时级联删消息：显式事务双删（Android SQLite 默认关外键约束，
//   不依赖 PRAGMA foreign_keys，行为在所有平台一致且可测）

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

Future<Database>? _cached;

/// 打开（或复用）App 会话数据库
Future<Database> openAppDatabase() => _cached ??= _open();

Future<Database> _open() async {
  final dir = await getDatabasesPath();
  return openDatabase(
    p.join(dir, 'strata_conversations.db'),
    version: 3,
    onCreate: (db, _) => createAppTables(db),
    // v2（M2-5）：messages.stopped——用户主动停止的助手消息标记
    // v3（v0.0.10）：messages.images_json——图片附件本地路径列表（JSON 数组）
    onUpgrade: (db, oldVersion, newVersion) async {
      if (oldVersion < 2) {
        await db.execute(
            'ALTER TABLE messages ADD COLUMN stopped INTEGER NOT NULL DEFAULT 0');
      }
      if (oldVersion < 3) {
        await db.execute(
            "ALTER TABLE messages ADD COLUMN images_json TEXT NOT NULL DEFAULT '[]'");
      }
    },
  );
}

/// 建表 SQL（onCreate 与测试内存库共用——注入的内存库不走 onCreate）
@visibleForTesting
Future<void> createAppTables(Database db) async {
  await db.execute('''
        CREATE TABLE conversations(
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          profile_id TEXT NOT NULL,
          model_id TEXT,
          effort TEXT NOT NULL DEFAULT 'medium',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          pinned INTEGER NOT NULL DEFAULT 0
        )
      ''');
  await db.execute(
      'CREATE INDEX idx_conversations_profile ON conversations(profile_id, updated_at DESC)');
  await db.execute('''
        CREATE TABLE messages(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          conversation_id TEXT NOT NULL,
          role TEXT NOT NULL,
          content TEXT NOT NULL DEFAULT '',
          reasoning TEXT,
          usage_json TEXT,
          error TEXT,
          stopped INTEGER NOT NULL DEFAULT 0,
          images_json TEXT NOT NULL DEFAULT '[]',
          timestamp TEXT NOT NULL,
          seq INTEGER NOT NULL
        )
      ''');
  await db.execute(
      'CREATE INDEX idx_messages_conversation ON messages(conversation_id, seq)');
}

/// 测试用：替换缓存的数据库实例（内存库）
@visibleForTesting
void setDatabaseForTesting(Database? db) =>
    _cached = db == null ? null : Future.value(db);

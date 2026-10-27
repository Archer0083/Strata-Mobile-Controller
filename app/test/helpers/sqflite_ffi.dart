// 测试数据库注入（M1-12）：host 环境无 sqflite 平台实现，
// 装 FFI 工厂 + 注入内存库（复用 app_database 的建表 SQL）。
//
// ChatController 写穿后，chat_screen_test 的 send() 会在 host 触达 DB；
// 未注入时 openAppDatabase 抛「databaseFactory not initialized」。
// 每个测试文件独立 isolate，全局 databaseFactory / 模块缓存互不干扰。

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:strata_mobile_controller/data/app_database.dart';

/// 安装 FFI 并注入建好表的内存库（testWidgets 的 setUpAll 调用一次）
Future<void> setupInMemoryDatabase() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await createAppTables(db);
  setDatabaseForTesting(db);
}

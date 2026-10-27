// 启动冒烟测试：App 根组件渲染、主题生效、无配置时落在 ConnectionScreen。
// M1-8 起 SplashGate 读 shared_preferences（激活 id），需 override mock 实例。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:strata_mobile_controller/main.dart';
import 'package:strata_mobile_controller/providers/connection_provider.dart';
import 'package:strata_mobile_controller/screens/connection_screen.dart';

import 'helpers/secure_storage_mock.dart';

void main() {
  setUpAll(mockSecureStorage);

  testWidgets('冷启动（无已存配置）落在连接页', (WidgetTester tester) async {
    final store = <String, Object>{}; // 内存 Map 彻底隔离，绕开插件 mock 的全局残留
    SharedPreferences.setMockInitialValues(store);
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: const StrataApp(),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(ConnectionScreen), findsOneWidget);
    expect(find.text('连接本地模型主机'), findsOneWidget);
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}

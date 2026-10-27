// SettingsScreen 测试（M1-8）：多 Profile 列表/激活切换/编辑/删除/新增入口，
// 以及 SplashGate 按持久化激活 id 恢复。全程 mock（secure_storage 内存通道 +
// SharedPreferences mock），不发真实网络请求。
//
// 注意：secure_storage mock 的内存 Map 是全局的，用例开始须 deleteAll 清空；
// SharedPreferences.setMockInitialValues 每次调用会换新内存 store，天然隔离。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:strata_mobile_controller/main.dart';
import 'package:strata_mobile_controller/models/connection_profile.dart';
import 'package:strata_mobile_controller/providers/connection_provider.dart';
import 'package:strata_mobile_controller/screens/connection_screen.dart';
import 'package:strata_mobile_controller/screens/home_shell.dart';
import 'package:strata_mobile_controller/screens/session_data_screen.dart';
import 'package:strata_mobile_controller/screens/session_data_section.dart';
import 'package:strata_mobile_controller/screens/settings_screen.dart';
import 'package:strata_mobile_controller/services/secure_storage_service.dart';

import 'helpers/secure_storage_mock.dart';

final _p1 = ConnectionProfile(
  id: 'p1',
  name: '客厅主机',
  host: '10.0.0.2',
  port: 8080,
  createdAt: DateTime(2026, 1, 1),
);
final _p2 = ConnectionProfile(
  id: 'p2',
  name: '书房主机',
  host: '192.168.1.5',
  port: 8081,
  apiKey: 'sk-x',
  createdAt: DateTime(2026, 1, 2),
);

void main() {
  setUpAll(mockSecureStorage);

  setUp(() async {
    await const FlutterSecureStorage().deleteAll(); // 清 mock 内存残留
  });

  Future<(ProviderContainer, SharedPreferences)> boot({
    Map<String, Object> initialPrefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues(initialPrefs);
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    );
    return (container, prefs);
  }

  Future<void> seedProfiles() => SecureStorageService().saveProfiles([_p1, _p2]);

  Widget settingsApp(ProviderContainer container) => UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsScreen()),
      );

  group('列表与激活', () {
    testWidgets('空列表：显示新增入口，点开为新增模式连接页', (tester) async {
      final (container, _) = await boot();
      addTearDown(container.dispose);
      await tester.pumpWidget(settingsApp(container));
      await tester.pumpAndSettle();

      expect(find.text('暂无连接配置'), findsOneWidget);
      await tester.tap(find.byKey(const Key('btn_add_first_profile')));
      await tester.pumpAndSettle();
      expect(find.byType(ConnectionScreen), findsOneWidget);
      expect(find.text('连接本地模型主机'), findsOneWidget); // 新增模式标题
    });

    testWidgets('渲染 Profile 列表，激活项带选中标记', (tester) async {
      await seedProfiles();
      final (container, _) = await boot(initialPrefs: {kActiveProfileIdKey: 'p1'});
      addTearDown(container.dispose);
      container.read(currentProfileProvider.notifier).state = _p1;
      // 视口放大：列表较长（外观/连接配置/数据三区），p2 项需在视口内构建
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(settingsApp(container));
      await tester.pumpAndSettle();

      expect(find.text('客厅主机'), findsOneWidget);
      expect(find.text('书房主机'), findsOneWidget);
      expect(find.text('10.0.0.2:8080'), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_off), findsOneWidget);
    });

    testWidgets('点击切换激活并持久化 id', (tester) async {
      await seedProfiles();
      final (container, prefs) = await boot(initialPrefs: {kActiveProfileIdKey: 'p1'});
      addTearDown(container.dispose);
      container.read(currentProfileProvider.notifier).state = _p1;
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(settingsApp(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('profile_tile_p2')));
      await tester.pumpAndSettle();

      expect(container.read(currentProfileProvider)?.id, 'p2');
      expect(prefs.getString(kActiveProfileIdKey), 'p2');
    });
  });

  group('编辑', () {
    testWidgets('编辑入口预填表单，保存后回设置页并更新列表/存储/激活项', (tester) async {
      await seedProfiles();
      final (container, prefs) = await boot(initialPrefs: {kActiveProfileIdKey: 'p1'});
      addTearDown(container.dispose);
      container.read(currentProfileProvider.notifier).state = _p1;
      await tester.pumpWidget(settingsApp(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('profile_menu_p1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();

      // 编辑模式：标题 + 表单预填（initialValue）
      expect(find.text('编辑连接'), findsOneWidget);
      expect(find.text('客厅主机'), findsOneWidget);
      expect(find.text('保存修改'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('field_name')), '客厅主机2');
      await tester.enterText(find.byKey(const Key('field_port')), '9090');
      await tester.pump();
      await tester.tap(find.byKey(const Key('btn_save')));
      await tester.pumpAndSettle();

      // 回设置页，列表与激活项同步更新
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text('客厅主机2'), findsOneWidget);
      expect(find.text('客厅主机'), findsNothing);
      expect(container.read(currentProfileProvider)?.name, '客厅主机2');

      // 存储更新：id/createdAt 保留，host/port 更新
      final stored = await SecureStorageService().loadProfiles();
      final edited = stored.firstWhere((p) => p.id == 'p1');
      expect(edited.name, '客厅主机2');
      expect(edited.port, 9090);
      expect(edited.createdAt, _p1.createdAt);
      expect(stored.length, 2);
      expect(prefs.getString(kActiveProfileIdKey), 'p1');
    });
  });

  group('删除', () {
    testWidgets('取消删除：列表不变', (tester) async {
      await seedProfiles();
      final (container, _) = await boot(initialPrefs: {kActiveProfileIdKey: 'p1'});
      addTearDown(container.dispose);
      container.read(currentProfileProvider.notifier).state = _p1;
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(settingsApp(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('profile_menu_p2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('btn_confirm_delete')), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn_cancel_delete')));
      await tester.pumpAndSettle();

      expect(find.text('书房主机'), findsOneWidget);
      expect((await SecureStorageService().loadProfiles()).length, 2);
    });

    testWidgets('删除非激活项：激活不变', (tester) async {
      await seedProfiles();
      final (container, prefs) = await boot(initialPrefs: {kActiveProfileIdKey: 'p1'});
      addTearDown(container.dispose);
      container.read(currentProfileProvider.notifier).state = _p1;
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(settingsApp(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('profile_menu_p2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_confirm_delete')));
      await tester.pumpAndSettle();

      expect(find.text('书房主机'), findsNothing);
      expect(container.read(currentProfileProvider)?.id, 'p1');
      expect(prefs.getString(kActiveProfileIdKey), 'p1');
    });

    testWidgets('删除激活项：回退剩余首项并持久化', (tester) async {
      await seedProfiles();
      final (container, prefs) = await boot(initialPrefs: {kActiveProfileIdKey: 'p1'});
      addTearDown(container.dispose);
      container.read(currentProfileProvider.notifier).state = _p1;
      await tester.pumpWidget(settingsApp(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('profile_menu_p1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_confirm_delete')));
      await tester.pumpAndSettle();

      expect(find.text('客厅主机'), findsNothing);
      expect(container.read(currentProfileProvider)?.id, 'p2');
      expect(prefs.getString(kActiveProfileIdKey), 'p2');
    });

    testWidgets('删除最后一个配置：回连接页并清除持久化激活', (tester) async {
      await SecureStorageService().saveProfiles([_p1]);
      final (container, prefs) = await boot(initialPrefs: {kActiveProfileIdKey: 'p1'});
      addTearDown(container.dispose);
      container.read(currentProfileProvider.notifier).state = _p1;
      await tester.pumpWidget(settingsApp(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('profile_menu_p1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_confirm_delete')));
      await tester.pumpAndSettle();

      expect(find.byType(ConnectionScreen), findsOneWidget);
      expect(container.read(currentProfileProvider), isNull);
      expect(prefs.getString(kActiveProfileIdKey), isNull);
    });
  });

  group('v0.0.9 IA 重排', () {
    testWidgets('设置页分区：外观 / 连接配置 / 数据 + 会话数据入口', (tester) async {
      await seedProfiles();
      final (container, _) = await boot(initialPrefs: {kActiveProfileIdKey: 'p1'});
      addTearDown(container.dispose);
      container.read(currentProfileProvider.notifier).state = _p1;
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(settingsApp(container));
      await tester.pumpAndSettle();

      expect(find.text('外观'), findsOneWidget);
      expect(find.text('连接配置'), findsOneWidget);
      expect(find.text('数据'), findsOneWidget);
      // 会话数据已提为独立页，设置页只留一个入口
      expect(find.byKey(const Key('tile_session_data')), findsOneWidget);
      // 「关于」不再藏在设置页的二级菜单里
      expect(find.text('关于与服务'), findsNothing);
    });

    testWidgets('点「会话数据」进入独立页（返回键逐层回退）', (tester) async {
      await seedProfiles();
      final (container, _) = await boot(initialPrefs: {kActiveProfileIdKey: 'p1'});
      addTearDown(container.dispose);
      container.read(currentProfileProvider.notifier).state = _p1;
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(settingsApp(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('tile_session_data')));
      await tester.pumpAndSettle();
      expect(find.byType(SessionDataScreen), findsOneWidget);
      expect(find.text('会话数据'), findsWidgets);
      // 独立页承载导出/导入/清空三个入口（session_data_test.dart 覆盖其行为）
      expect(find.byType(SessionDataSection), findsOneWidget);
    });
  });

  group('启动恢复（main 注入 + SplashGate 分派）', () {
    test('resolveStartupProfile：持久化 id 优先 / 失效回退首项 / 空列表 null', () {
      expect(resolveStartupProfile([_p1, _p2], 'p2')?.id, 'p2');
      expect(resolveStartupProfile([_p1, _p2], 'ghost')?.id, 'p1');
      expect(resolveStartupProfile([_p1, _p2], null)?.id, 'p1');
      expect(resolveStartupProfile(const [], 'p1'), isNull);
    });

    testWidgets('有配置且激活项已恢复（模拟 main overrideWith）→ 直接进主页骨架', (tester) async {
      await seedProfiles();
      SharedPreferences.setMockInitialValues({kActiveProfileIdKey: 'p2'});
      final prefs = await SharedPreferences.getInstance();
      // 模拟 main()：prefs + 恢复出的启动 Profile 一并 override
      final container = ProviderContainer(overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        currentProfileProvider.overrideWith(
          (_) => resolveStartupProfile([_p1, _p2], prefs.getString(kActiveProfileIdKey)),
        ),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const StrataApp(),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(HomeShell), findsOneWidget);
      expect(find.byType(ConnectionScreen), findsNothing);
      expect(container.read(currentProfileProvider)?.id, 'p2');
    });
  });
}

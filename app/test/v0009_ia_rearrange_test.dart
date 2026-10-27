// v0.0.9 IA 重排回归测试（第十轮真机反馈驱动）
//
// 用户反馈原话：
// 「按钮逻辑也不统一设置里面有会话数据，关于又藏在设置下面的二级菜单里面，
//   请梳理当前的功能按钮，按照重要性和易理解的逻辑把按钮和功能布局重新梳理一遍，
//   去掉旧版本迭代过程中产生的冗余的页面」
// 「chat页面的对话栏的上方的思考关闭低中高采样排版不好看，并且语音输入键只有图标
//   没有实际功能点不动，建议参考webUI的chat页面的对话栏的按钮和功能设计」
//
// 本文件锁死 v0.0.9 的 IA 契约：
// ① 顶层 5 页：对话(0) / 监控(1) / 控制(2) / 关于(3) / 设置(4)
// ② API Monitor 页已删除 → 监控页不再有该入口
// ③ About 提为一级页 → 顶栏入口条含「关于」
// ④ 对话栏底栏四键（附件 / 新会话 / 导出 / 采样与思考）+ 无语音键
// ⑤ 思考四档收进「采样与思考」抽屉，输入区上方只留一行状态文字
//
// 【测试策略说明】
// HomeShell 用 IndexedStack 保活全部 5 个页面，ControlScreen / MonitorScreen
// 会在 initState 里启动 1~2s 的轮询 Timer —— 在 widget test 的 fake zone 下
// 永不 settle，导致 pumpAndSettle 挂起。因此：
//   - 组合断言（对话栏、顶栏入口条）→ 单独渲染 ChatScreen
//   - 跨页导航断言 → 渲染 HomeShell，但只用有限步进 pump，绝不 pumpAndSettle
// 全程 mock（secure_storage 内存通道 + SharedPreferences mock），不发真实网络请求。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:strata_mobile_controller/providers/connection_provider.dart';
import 'package:strata_mobile_controller/screens/chat_screen.dart';
import 'package:strata_mobile_controller/screens/home_shell.dart';

import 'helpers/secure_storage_mock.dart';

void main() {
  setUpAll(mockSecureStorage);

  Future<ProviderContainer> boot() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    );
    return container;
  }

  /// 单独渲染对话页（避开 HomeShell 内 ControlScreen/MonitorScreen 的轮询 Timer）
  Widget chatApp(ProviderContainer container) => UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ChatScreen()),
      );

  /// 渲染完整骨架（跨页导航断言用）
  Widget shellApp(ProviderContainer container) => UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomeShell()),
      );

  group('顶层导航结构', () {
    test('TopNav 常量：5 页且索引有序', () {
      expect(TopNav.chat, 0);
      expect(TopNav.monitor, 1);
      expect(TopNav.control, 2);
      expect(TopNav.about, 3);
      expect(TopNav.settings, 4);
      expect(TopNav.count, 5);
    });

    testWidgets('对话页顶栏入口条：监控 / 控制 / 关于 / 设置（含关于，不含对话）',
        (tester) async {
      final container = await boot();
      addTearDown(container.dispose);
      await tester.pumpWidget(chatApp(container));
      await tester.pump();

      // 「关于」必须是一级入口（v0.0.9 核心变更）。
      // 用 Semantics 标签定位，避免与 composer 里的 Icons.tune 等图标撞车。
      expect(find.bySemanticsLabel('监控'), findsOneWidget);
      expect(find.bySemanticsLabel('控制'), findsOneWidget);
      expect(find.bySemanticsLabel('关于'), findsOneWidget);
      expect(find.bySemanticsLabel('设置'), findsOneWidget);
    });

    testWidgets('点「关于」顶栏入口切到 About 页（不再藏在设置二级菜单）',
        (tester) async {
      final container = await boot();
      addTearDown(container.dispose);
      await tester.pumpWidget(shellApp(container));
      await tester.pump();

      await tester.tap(find.bySemanticsLabel('关于'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(container.read(topNavIndexProvider), TopNav.about);
    });

    testWidgets('API Monitor 页已删除：App 内不再出现其专属文案', (tester) async {
      final container = await boot();
      addTearDown(container.dispose);
      await tester.pumpWidget(shellApp(container));
      await tester.pump();

      // 全 App 不应再出现 API Monitor 专属文案
      expect(find.textContaining('API Monitor'), findsNothing);
    });
  });

  group('对话栏（对齐 webUI composer）', () {
    testWidgets('底栏四键：附件 / 新会话 / 导出 / 采样与思考', (tester) async {
      final container = await boot();
      addTearDown(container.dispose);
      await tester.pumpWidget(chatApp(container));
      await tester.pump();

      expect(find.byKey(const Key('btn_attach')), findsOneWidget);
      expect(find.byKey(const Key('btn_new_chat')), findsOneWidget);
      expect(find.byKey(const Key('btn_export_md')), findsOneWidget);
      expect(find.byKey(const Key('btn_sampling')), findsOneWidget);
    });

    testWidgets('语音输入键已移除（原本是点不动的死按钮）', (tester) async {
      final container = await boot();
      addTearDown(container.dispose);
      await tester.pumpWidget(chatApp(container));
      await tester.pump();

      expect(find.byIcon(Icons.mic_none), findsNothing);
      expect(find.byIcon(Icons.mic), findsNothing);
    });

    testWidgets('输入区上方只剩一行状态文字（思考档位不再平铺成胶囊）',
        (tester) async {
      final container = await boot();
      addTearDown(container.dispose);
      await tester.pumpWidget(chatApp(container));
      await tester.pump();

      final status = find.byKey(const Key('composer_status'));
      expect(status, findsOneWidget);
      // 默认 medium 档 → 「思考 中」
      expect(find.textContaining('思考 中'), findsOneWidget);
      // 旧的平铺胶囊不得再出现
      expect(find.text('关闭'), findsNothing);
      expect(find.text('低'), findsNothing);
      expect(find.text('高'), findsNothing);
    });

    testWidgets('「采样与思考」抽屉内含思考四档 + 采样参数', (tester) async {
      final container = await boot();
      addTearDown(container.dispose);
      await tester.pumpWidget(chatApp(container));
      await tester.pump();

      await tester.tap(find.byKey(const Key('btn_sampling')));
      // 底部弹层动画：有限步进，不使用 pumpAndSettle（轮询 Timer 会让它永挂）
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 思考四档都在同一抽屉里（webUI Sampling drawer 同构）
      expect(find.byKey(const Key('effort_none')), findsOneWidget);
      expect(find.byKey(const Key('effort_low')), findsOneWidget);
      expect(find.byKey(const Key('effort_medium')), findsOneWidget);
      expect(find.byKey(const Key('effort_high')), findsOneWidget);
      // 采样参数同处一抽屉
      expect(find.byKey(const Key('sampling_apply')), findsOneWidget);
      expect(find.byKey(const Key('sampling_reset')), findsOneWidget);
      expect(find.text('采样与思考'), findsOneWidget);
    });
  });

  group('ChatScreen 组合', () {
    testWidgets('ChatScreen 可独立渲染（含新的对话栏）', (tester) async {
      final container = await boot();
      addTearDown(container.dispose);
      await tester.pumpWidget(chatApp(container));
      await tester.pump();
      expect(find.byKey(const Key('field_input')), findsOneWidget);
      expect(find.byKey(const Key('btn_sampling')), findsOneWidget);
    });
  });
}

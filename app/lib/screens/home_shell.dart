// 主页骨架（M1-5 → M1-11 UI 改版 → v0.0.9 IA 重排）：
//
// 【为什么没有底部 Tab】
// TRAE 移动端的 IA 是「对话为主干全屏 + 低频功能收进顶栏入口」，而非底部 4 Tab。
// 依据 docs/ui-design-spec.md §1.1：
//   - 本项目四页里只有「对话」是高频页，监控/控制/设置是低频运维页；
//   - 底部 Tab 会永久占用约 25% 屏高，且把对话页压缩；
//   - 顶栏右侧入口为 M3 的「任务中心抽屉」预留了同一位置，后续只需替换入口内容。
//
// 【v0.0.9 IA 重排（第十轮真机反馈驱动）】
// 用户反馈原话：「按钮逻辑也不统一……关于又藏在设置下面的二级菜单里面，
// 请梳理当前的功能按钮，按照重要性和易理解的逻辑把按钮和功能布局重新梳理一遍，
// 去掉旧版本迭代过程中产生的冗余的页面」。
//
// 本次调整三件事：
// ① **删除 API Monitor 页**（M2-4 引入的冗余页）。它依赖主机端 svc.api_monitor
//    开关，而该开关**默认关闭** → 打开永远是「主机端未开启 API Monitor」空页。
//    一个 99% 概率是空页的二级入口占据 AppBar 位置 = 纯负价值。
//    需要 Load/Unload 的用户走「控制」页即可（同一份 apiMonitorProvider 数据源）。
// ② **About 提为一级页**。它承载模型信息 / API key / 模型设置 / 开发者信息，
//    是高频查阅页，藏在「设置 → 关于与服务」二级菜单里过深。
// ③ **顶栏入口顺序按重要性排**：对话（主）→ 监控 → 控制 → 关于 → 设置。
//    监控/控制是运维高频页，关于是查阅页，设置是最低频（外观/连接配置）。
//
// 五个页面仍是平级关系，通过顶栏右侧的图标入口切换；
// 导航状态放在 provider（topNavIndexProvider），页面才能在自己的 AppBar 里触发切换。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/connection_provider.dart';
import '../theme/trae_theme.dart';
import 'about_screen.dart';
import 'chat_screen.dart';
import 'control_screen.dart';
import 'monitor_screen.dart';
import 'settings_screen.dart';

/// 顶层页面的固定索引（v0.0.9 起 About 提为一级页，索引 3 由「设置」让位）。
class TopNav {
  const TopNav._();

  static const int chat = 0;
  static const int monitor = 1;
  static const int control = 2;
  static const int about = 3;
  static const int settings = 4;

  static const int count = 5;
}

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 返回逻辑（2026-10-27 真机反馈修复·缺陷 A）：
    //
    // 多个页面是 IndexedStack 平级切换，导航状态在 topNavIndexProvider，
    // 没有真正的路由栈——若不拦截，Android 返回键在「监控/控制/设置」页
    // 会直接退出 App，用户只能杀进程重开才能回到对话页（真机反馈原话：
    // 「进入设置和监控等许多界面向返回对话界面只能先退出 app 再进入」）。
    //
    // 约定：非对话页按返回 → 回对话页（index=0）；对话页再按返回 → 退出 App。
    // 这与 Android 抽屉/二级页的「逐层回退」直觉一致，也和 webUI 的
    // 「切 tab 不退出」语义一致。
    //
    // 【Flutter 机制（已在 SDK 源码核实，勿凭直觉改）】
    // ModalRoute.popDisposition：先遍历 PopEntry，canPop=false → doNotPop；
    // 否则取 super（isFirst → bubble，否则 pop）。故：
    //   - 非对话页（canPop=false）→ doNotPop → onPopInvokedWithResult(false)
    //     被调用 → 本回调把 index 归 0 → 不退出 App ✅
    //   - 对话页（canPop=true）→ home 路由 isFirst → bubble → maybePop 返回
    //     false 且**不触发** onPopInvokedWithResult → pop 上抛给 Android 系统
    //     → 退出 App ✅（此路径下 didPop 恒为 false，回调不会执行）
    final index = ref.watch(topNavIndexProvider);
    return PopScope(
      canPop: index == TopNav.chat,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return; // 对话页：交给系统退出
        ref.read(topNavIndexProvider.notifier).state = TopNav.chat;
      },
      child: Scaffold(
        backgroundColor: context.trae.bg,
        body: const _NavStack(),
      ),
    );
  }
}

/// 顶层页面容器：用 IndexedStack 保活各页，避免切页丢失流式状态。
class _NavStack extends ConsumerWidget {
  const _NavStack();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(topNavIndexProvider);
    return IndexedStack(
      index: index,
      children: const [
        ChatScreen(),
        MonitorScreen(),
        ControlScreen(),
        AboutScreen(),
        SettingsScreen(),
      ],
    );
  }
}

/// 顶栏入口条：低频功能的统一入口（供各页面内嵌到自己的 AppBar 中）。
///
/// 之所以做成可复用小部件而不是各页各自实现：
/// 顶栏是 M1-11 改版后唯一的导航载体，所有页面必须共享同一套外观与行为。
///
/// 【v0.0.9】入口顺序按重要性重排（监控 → 控制 → 关于 → 设置），
/// 并把「设置」挪到最后：它只承载外观与连接配置，是最低频页。
class TopNavEntries extends ConsumerWidget {
  const TopNavEntries({super.key, this.exclude = TopNav.chat});

  /// 需要在入口条中排除的页面索引（页面自身的入口不高亮显示）
  final int exclude;

  static const _entries = [
    (index: TopNav.monitor, icon: Icons.monitor_heart_outlined, label: '监控'),
    (index: TopNav.control, icon: Icons.tune, label: '控制'),
    (index: TopNav.about, icon: Icons.info_outline, label: '关于'),
    (index: TopNav.settings, icon: Icons.settings_outlined, label: '设置'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(topNavIndexProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final e in _entries)
          if (e.index != exclude)
            _EntryButton(
              icon: e.icon,
              label: e.label,
              selected: current == e.index,
              onTap: () => ref.read(topNavIndexProvider.notifier).state = e.index,
            ),
      ],
    );
  }
}

class _EntryButton extends StatelessWidget {
  const _EntryButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      child: InkResponse(
        onTap: onTap,
        radius: 24,
        child: Padding(
          // 保证可点区域 ≥ 44×44（移动端可点性下限）
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Icon(
            icon,
            size: 22,
            color: selected ? context.trae.accent : context.trae.inkSoft,
          ),
        ),
      ),
    );
  }
}

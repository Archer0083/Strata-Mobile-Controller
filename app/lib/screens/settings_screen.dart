// SettingsScreen（M1-8 / P2-7 / v0.0.9 IA 重排）：多 Profile 管理 + 外观 + 入口。
// 列表项 tap 激活（持久化 id 到 shared_preferences）；PopupMenuButton 编辑/删除；
// 删除需确认对话框；删除激活项自动回退剩余首项；列表清空回连接页。
// Profile 全量数据仍在 secure_storage，prefs 只存激活 id（ADR-5 数据分层）。
//
// 【v0.0.9 IA 重排（第十轮真机反馈驱动）】
// 用户反馈原话：「设置里面有会话数据，关于又藏在设置下面的二级菜单里面，
// 请梳理当前的功能按钮，按照重要性和易理解的逻辑把按钮和功能布局重新梳理一遍，
// 去掉旧版本迭代过程中产生的冗余的页面」。
//
// 本页调整三件事：
// ① **「关于与服务」入口移除** —— About 已在 v0.0.9 提为一级页（顶栏「关于」），
//    这里再放一个二级入口就是重复路径。反馈说「关于藏在设置下面太深」，
//    正确解法是提级，而不是在设置里再塞一份。
// ② **「会话数据」提为独立页** —— 原来它以常驻区块形式挂在设置页底部，
//    而它是「数据管理」而非「设置」；且常驻区块会把 4 个操作按钮压到
//    设置页最底部，需要滚动到底才能看到，用户反馈明确点到了这一点。
//    现在改为设置页里的一个二级入口 → 独立页 `SessionDataScreen`。
// ③ **分区化** —— 页面按「外观 / 连接 / 数据」三段分区，
//    每段有标题，避免所有条目平铺成一张无层次的列表。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/connection_profile.dart';
import '../providers/connection_provider.dart';
import '../providers/theme_provider.dart';
import '../theme/trae_theme.dart';
import 'connection_screen.dart';
import 'connection_guide_screen.dart';
import 'home_shell.dart';
import 'session_data_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  /// 打开连接表单页：push 前先定好表单状态（编辑预填/新增清空）——
  /// TextFormField.initialValue 仅首帧生效，且不可在 widget 生命周期内改 provider。
  void _openConnectionForm(BuildContext context, WidgetRef ref, {ConnectionProfile? profile}) {
    final controller = ref.read(connectionControllerProvider.notifier);
    if (profile != null) {
      controller.startEditing(profile);
    } else {
      controller.reset();
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ConnectionScreen(editingProfile: profile)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider);
    final current = ref.watch(currentProfileProvider);

    return Scaffold(
      backgroundColor: context.trae.bg,
      appBar: AppBar(
        titleSpacing: TraeTokens.gapLg,
        title: Text('设置', style: TraeText.pageTitle(context)),
        actions: [
          IconButton(
            key: const Key('btn_add_profile'),
            icon: const Icon(Icons.add),
            tooltip: '新增连接配置',
            color: context.trae.inkSoft,
            onPressed: () => _openConnectionForm(context, ref),
          ),
          const TopNavEntries(exclude: TopNav.settings),
          const SizedBox(width: TraeTokens.gapSm),
        ],
      ),
      body: profiles.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('读取配置失败：$e')),
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('暂无连接配置'),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const Key('btn_add_first_profile'),
                    onPressed: () => _openConnectionForm(context, ref),
                    icon: const Icon(Icons.add),
                    label: const Text('新增配置'),
                  ),
                ],
              ),
            );
          }
          return ListView(
            children: [
              // ── 外观 ──────────────────────────────────────────────
              _ThemeModeSection(),
              const Divider(height: TraeTokens.gapXl, color: Color(0x00000000)),

              // ── 连接 ──────────────────────────────────────────────
              _SectionHeader('连接配置'),
              for (final p in list)
                ListTile(
                  key: Key('profile_tile_${p.id}'),
                  leading: Icon(
                    p.id == current?.id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: p.id == current?.id ? context.trae.accent : null,
                  ),
                  title: Text(p.name, style: TraeText.body(context)),
                  subtitle: Text('${p.host}:${p.port}',
                      style: TraeText.meta(context)),
                  trailing: PopupMenuButton<String>(
                    key: Key('profile_menu_${p.id}'),
                    tooltip: '配置操作',
                    // 底色由 theme.popupMenuTheme 统一提供（M2-1）
                    onSelected: (action) =>
                        _onMenuSelected(context, ref, action, p),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                  onTap: () =>
                      ref.read(profileAdminControllerProvider.notifier).activate(p),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    TraeTokens.gapLg, TraeTokens.gapXs, TraeTokens.gapLg, 0),
                child: Text(
                  '点击配置切换当前连接；右上角 + 新增。',
                  style: TextStyle(fontSize: 12, color: context.trae.muted),
                ),
              ),
              const Divider(height: TraeTokens.gapXl, color: Color(0x00000000)),

              // ── 数据 ──────────────────────────────────────────────
              _SectionHeader('数据'),
              ListTile(
                key: const Key('tile_session_data'),
                leading: Icon(Icons.storage_outlined, color: context.trae.inkSoft),
                title: Text('会话数据', style: TraeText.body(context)),
                subtitle: Text('导出 / 导入 / 清空本机会话',
                    style: TraeText.meta(context)),
                trailing: Icon(Icons.chevron_right, color: context.trae.muted),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SessionDataScreen()),
                ),
              ),
              const Divider(height: TraeTokens.gapXl, color: Color(0x00000000)),

              // ── 帮助 ──────────────────────────────────────────────
              _SectionHeader('帮助'),
              ListTile(
                key: const Key('tile_connection_guide'),
                leading:
                    Icon(Icons.vpn_lock_outlined, color: context.trae.inkSoft),
                title: Text('连接指南', style: TraeText.body(context)),
                subtitle: Text('WireGuard 配置与首次使用说明',
                    style: TraeText.meta(context)),
                trailing: Icon(Icons.chevron_right, color: context.trae.muted),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ConnectionGuideScreen()),
                ),
              ),
              const SizedBox(height: TraeTokens.gapXl),
            ],
          );
        },
      ),
    );
  }

  Future<void> _onMenuSelected(
    BuildContext context,
    WidgetRef ref,
    String action,
    ConnectionProfile p,
  ) async {
    final navigator = Navigator.of(context); // await 前同步捕获
    if (action == 'edit') {
      _openConnectionForm(context, ref, profile: p);
      return;
    }
    // delete：先确认，再执行；删空后回连接页
    final ok = await _confirmDelete(context, p);
    if (!ok) return;
    await ref.read(profileAdminControllerProvider.notifier).delete(p);
    if (ref.read(currentProfileProvider) == null) {
      ref.read(connectionControllerProvider.notifier).reset(); // 回连接页前清表单
      await navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => const ConnectionScreen()),
      );
    }
  }

  Future<bool> _confirmDelete(BuildContext context, ConnectionProfile p) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${p.name}」？'),
        content: const Text('仅移除手机上的这条配置，不影响服务端；删除后不可恢复。'),
        actions: [
          TextButton(
            key: const Key('btn_cancel_delete'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('btn_confirm_delete'),
            style: FilledButton.styleFrom(backgroundColor: ctx.trae.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    ).then((ok) => ok ?? false);
  }
}

/// 分区标题（v0.0.9：设置页分区化，避免所有条目平铺成一张无层次列表）
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          TraeTokens.gapLg, TraeTokens.gapLg, TraeTokens.gapLg, TraeTokens.gapXs),
      child: Text(text, style: TraeText.sectionTitle(context)),
    );
  }
}

/// M2-1：主题模式三态选择（跟随系统/浅色/深色）。
/// themeModeProvider：null = 跟随系统；选择写入 shared_preferences。
class _ThemeModeSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final t = context.trae;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('外观'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: TraeTokens.gapSm),
          child: Row(
            children: [
              for (final (m, label) in [
                (null, '跟随系统'),
                (ThemeMode.light, '浅色'),
                (ThemeMode.dark, '深色'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: TraeTokens.gapSm),
                  child: TraeWidgets.chip(
                    context,
                    label,
                    selected: mode == m,
                    onTap: () =>
                        ref.read(themeModeProvider.notifier).set(m),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              TraeTokens.gapLg, TraeTokens.gapXs, TraeTokens.gapLg, 0),
          child: Text('跟随系统即由 Android 深色模式决定；选择后立即生效并记忆。',
              style: TextStyle(fontSize: 12, color: t.muted)),
        ),
      ],
    );
  }
}

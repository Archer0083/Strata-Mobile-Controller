// ConversationDrawer（M1-12.3，SPEC v0.3.5 §10 / docs/ui-design-spec.md §3.7）：
// 会话历史抽屉，四区结构（头部 / 搜索 / 列表 / 底部操作）。
//
// - 列表数据：conversationsProvider（置顶优先 + updatedAt 倒序，SQL 保证），
//   副行消息数来自 messageCountsProvider（一条 GROUP BY，避免 N+1）
// - 分组维度 = 主机 Profile（组头显示 Profile 名，未匹配时回退 id）
// - 置顶会话独立分区排在所有组之前
// - 操作菜单（行尾 ⋯）：置顶/取消置顶 · 重命名 · 删除（二次确认）；
//   「导出」入口在 M1-12.4 接入格式选择 Sheet，「导入」在 M1-12.5 接线
// - 宽度 78% 屏宽（上限 320dp）；Scaffold.drawer 自带左缘右滑拉出

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/connection_profile.dart';
import '../models/conversation.dart';
import '../providers/chat_provider.dart';
import '../providers/connection_provider.dart';
import '../services/import_service.dart';
import '../theme/trae_theme.dart';
import 'export_sheet.dart';
import 'import_preview_dialog.dart';

class ConversationDrawer extends ConsumerStatefulWidget {
  const ConversationDrawer({super.key});

  @override
  ConsumerState<ConversationDrawer> createState() => _ConversationDrawerState();
}

class _ConversationDrawerState extends ConsumerState<ConversationDrawer> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).maybePop();

  Future<void> _newConversation() async {
    ref.read(chatControllerProvider.notifier).newConversation();
    _close();
  }

  Future<void> _openConversation(Conversation c) async {
    await ref.read(chatControllerProvider.notifier).loadConversation(c);
    _close();
  }

  Future<void> _togglePinned(Conversation c) async {
    await ref
        .read(conversationRepositoryProvider)
        .setPinned(c.id, !c.pinned);
    _invalidateLists();
  }

  Future<void> _rename(Conversation c) async {
    final controller = TextEditingController(text: c.title);
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('重命名会话', style: TraeText.sectionTitle(dialogContext)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '会话标题'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (title == null || title.isEmpty) return;
    await ref.read(conversationRepositoryProvider).renameConversation(c.id, title);
    _invalidateLists();
  }

  /// 导出（M1-12.4，§3.8 入口之一）：先收抽屉再弹格式选择 Sheet。
  /// maybePop 同步发起 drawer 路由退出，随后 push 的 sheet 落在其上，
  /// 两段动画并行；drawer context 在同步段内仍 mounted。
  Future<void> _export(Conversation c) async {
    Navigator.of(context).maybePop();
    await showExportFormatSheet(context, ref, c);
  }

  /// 导入（v0.0.10：单会话 / 会话包自动识别，不再要求用户分辨文件类型）。
  ///
  /// 链路：选文件 → 解析（自动嗅探）→ 预览确认 → 入库 → 跳转首个会话。
  /// 错误（文件非法/读取失败）以 toast 提示，不打断用户当前会话。
  Future<void> _import() async {
    // 先捕获 messenger / navigator：抽屉关闭后 context 可能已 unmounted
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final currentProfile = ref.read(currentProfileProvider);
    final profileId = currentProfile?.id ?? 'default';

    ParsedImport? parsed;
    try {
      parsed = await ref.read(importServiceProvider).pickAndParseAuto();
    } on ImportException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
      return;
    }
    // 用户取消选文件
    if (parsed == null) return;
    // 选文件期间用户可能已离开页面
    if (!mounted) return;

    // 预览确认（收抽屉 → 弹对话框，两段动画并行）
    navigator.maybePop();
    final confirmed = await showImportAutoPreviewDialog(navigator.context, parsed);
    if (!confirmed) return;

    try {
      final created = await ref.read(importServiceProvider).importAuto(
        parsed,
        profileId: profileId,
        repository: ref.read(conversationRepositoryProvider),
      );
      // 跳转导入的会话 + 刷新抽屉列表
      if (created.isNotEmpty) {
        await ref.read(chatControllerProvider.notifier).loadConversation(
              created.first,
            );
      }
      _invalidateLists();
      final skipped = parsed.skippedCount;
      final count = created.length;
      messenger.showSnackBar(SnackBar(
        content: Text(
          skipped > 0
              ? '已导入 $count 个会话（${parsed.messageCount} 条消息，跳过 $skipped 条）'
              : '已导入 $count 个会话（${parsed.messageCount} 条消息）',
        ),
      ));
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
    }
  }

  Future<void> _delete(Conversation c, int messageCount) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除会话？', style: TraeText.sectionTitle(dialogContext)),
        content: Text(
          '「${c.title}」将同时删除 $messageCount 条消息，不可恢复。',
          style: TraeText.body(dialogContext),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('删除', style: TextStyle(color: dialogContext.trae.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(conversationRepositoryProvider).deleteConversation(c.id);
    // 删除的是当前会话：回到新会话态
    if (ref.read(chatControllerProvider).conversationId == c.id) {
      ref.read(chatControllerProvider.notifier).newConversation();
    }
    _invalidateLists();
  }

  void _invalidateLists() {
    ref.invalidate(conversationsProvider);
    ref.invalidate(messageCountsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final conversations = ref.watch(conversationsProvider);
    final counts = ref.watch(messageCountsProvider);
    final currentId =
        ref.watch(chatControllerProvider.select((s) => s.conversationId));
    final profiles = ref.watch(profilesProvider);

    return Drawer(
      backgroundColor: context.trae.surface,
      width: math.min(MediaQuery.of(context).size.width * 0.78, 320),
      shape: const RoundedRectangleBorder(), // 直角贴边，去掉 M3 默认大圆角
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ---------- 区① 头部 ----------
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  TraeTokens.gapLg, TraeTokens.gapLg, TraeTokens.gapSm, TraeTokens.gapMd),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('会话', style: TraeText.pageTitle(context)),
                      ),
                      TextButton(onPressed: _newConversation, child: const Text('新建')),
                    ],
                  ),
                  const SizedBox(height: 2),
                  conversations.maybeWhen(
                    data: (list) => Text(
                      _summaryLine(list, profiles),
                      style: TraeText.meta(context),
                    ),
                    orElse: () => const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: context.trae.lineSoft),

          // ---------- 区② 搜索（>20 条才显示，避免空态噪声） ----------
          if (conversations.maybeWhen(
              data: (l) => l.length > 20, orElse: () => false))
            Padding(
              padding: const EdgeInsets.fromLTRB(TraeTokens.gapLg, TraeTokens.gapSm,
                  TraeTokens.gapLg, TraeTokens.gapSm),
              child: SizedBox(
                height: 36,
                child: TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: '搜索会话…',
                    isDense: true,
                    prefixIcon: Icon(Icons.search,
                        size: 18, color: context.trae.muted),
                  ),
                ),
              ),
            ),

          // ---------- 区③ 会话列表 ----------
          Expanded(
            child: conversations.when(
              loading: () => Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.8, color: context.trae.muted),
                ),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(TraeTokens.gapLg),
                child: Text('会话列表读取失败：$e', style: TraeText.meta(context)),
              ),
              data: (list) {
                final filtered = _filter(list);
                if (filtered.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('还没有会话', style: TraeText.meta(context)),
                        const SizedBox(height: TraeTokens.gapMd),
                        TextButton.icon(
                          onPressed: _newConversation,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('新建会话'),
                        ),
                      ],
                    ),
                  );
                }
                final countMap = counts.valueOrNull ?? const <String, int>{};
                final profileById = {
                  for (final p in profiles.valueOrNull ?? const <ConnectionProfile>[])
                    p.id: p,
                };
                return _ConversationList(
                  conversations: filtered,
                  counts: countMap,
                  profileById: profileById,
                  currentId: currentId,
                  onOpen: _openConversation,
                  onTogglePinned: _togglePinned,
                  onRename: _rename,
                  onExport: _export,
                  onDelete: _delete,
                );
              },
            ),
          ),

          // ---------- 区④ 底部固定操作 ----------
          Divider(height: 1, color: context.trae.lineSoft),
          SafeArea(
            top: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InkWell(
                  key: const Key('drawer_new_conversation'),
                  onTap: _newConversation,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: TraeTokens.gapLg, vertical: TraeTokens.gapMd),
                    child: Row(
                      children: [
                        Icon(Icons.add, size: 18, color: context.trae.accent),
                        const SizedBox(width: TraeTokens.gapSm),
                        Text('新建会话',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                color: context.trae.accent)),
                      ],
                    ),
                  ),
                ),
                // 导入是低频动作，不与新建并列抢注意力（M1-12.5 接线）
                InkWell(
                  key: const Key('drawer_import'),
                  onTap: _import,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(TraeTokens.gapLg, 0,
                        TraeTokens.gapLg, TraeTokens.gapMd),
                    child: Text('导入会话（.json，自动识别单个/全部）',
                        style: TraeText.meta(context)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 按搜索词过滤（标题包含匹配）
  List<Conversation> _filter(List<Conversation> list) {
    final q = _searchController.text.trim();
    if (q.isEmpty) return list;
    return list.where((c) => c.title.contains(q)).toList();
  }

  /// 头部摘要行：`12 个会话 · 本机 8 / 远程 4`（host 为 localhost/127.x 视为本机）
  String _summaryLine(
      List<Conversation> list, AsyncValue<List<ConnectionProfile>> profiles) {
    final byId = {
      for (final p in profiles.valueOrNull ?? const <ConnectionProfile>[]) p.id: p,
    };
    var local = 0;
    var remote = 0;
    for (final c in list) {
      final host = byId[c.profileId]?.host;
      if (host == 'localhost' || host == '127.0.0.1') {
        local++;
      } else {
        remote++;
      }
    }
    return '${list.length} 个会话 · 本机 $local / 远程 $remote';
  }
}

/// 区③：置顶分区 + 按主机 Profile 分组的会话列表
class _ConversationList extends StatelessWidget {
  const _ConversationList({
    required this.conversations,
    required this.counts,
    required this.profileById,
    required this.currentId,
    required this.onOpen,
    required this.onTogglePinned,
    required this.onRename,
    required this.onExport,
    required this.onDelete,
  });

  final List<Conversation> conversations;
  final Map<String, int> counts;
  final Map<String, ConnectionProfile> profileById;
  final String? currentId;
  final ValueChanged<Conversation> onOpen;
  final ValueChanged<Conversation> onTogglePinned;
  final ValueChanged<Conversation> onRename;
  final ValueChanged<Conversation> onExport;
  final void Function(Conversation c, int messageCount) onDelete;

  @override
  Widget build(BuildContext context) {
    final pinned =
        conversations.where((c) => c.pinned).toList(growable: false);
    final grouped = <String, List<Conversation>>{};
    for (final c in conversations.where((c) => !c.pinned)) {
      grouped.putIfAbsent(c.profileId, () => []).add(c);
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: TraeTokens.gapSm),
      children: [
        if (pinned.isNotEmpty) ...[
          _GroupHeader('置顶'),
          for (final c in pinned)
            _ConversationTile(
              conversation: c,
              messageCount: counts[c.id] ?? 0,
              selected: currentId == c.id,
              onOpen: () => onOpen(c),
              onTogglePinned: () => onTogglePinned(c),
              onRename: () => onRename(c),
              onExport: () => onExport(c),
              onDelete: () => onDelete(c, counts[c.id] ?? 0),
            ),
        ],
        for (final entry in grouped.entries) ...[
          _GroupHeader(_profileName(entry.key)),
          for (final c in entry.value)
            _ConversationTile(
              conversation: c,
              messageCount: counts[c.id] ?? 0,
              selected: currentId == c.id,
              onOpen: () => onOpen(c),
              onTogglePinned: () => onTogglePinned(c),
              onRename: () => onRename(c),
              onExport: () => onExport(c),
              onDelete: () => onDelete(c, counts[c.id] ?? 0),
            ),
        ],
      ],
    );
  }

  String _profileName(String profileId) {
    final p = profileById[profileId];
    if (p == null) return profileId;
    return p.host == 'localhost' || p.host == '127.0.0.1'
        ? '${p.name}（本机）'
        : '${p.name} · ${p.host}';
  }
}

/// 组头：12px muted 元信息色小字，不带背景（M2-1 起随主题取色）
class _GroupHeader extends StatelessWidget {
  const _GroupHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(TraeTokens.gapLg, TraeTokens.gapMd,
          TraeTokens.gapLg, TraeTokens.gapXs),
      child: Text(label, style: TraeText.meta(context)),
    );
  }
}

/// 会话条目：标题 + 副行（相对时间 · N 条消息）+ 行尾 ⋯ 菜单。
/// 选中态 = 左侧 3px accent 竖条 + 标题转 accent（不用整行底色）。
class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.messageCount,
    required this.selected,
    required this.onOpen,
    required this.onTogglePinned,
    required this.onRename,
    required this.onExport,
    required this.onDelete,
  });

  final Conversation conversation;
  final int messageCount;
  final bool selected;
  final VoidCallback onOpen;
  final VoidCallback onTogglePinned;
  final VoidCallback onRename;
  final VoidCallback onExport;
  final VoidCallback onDelete;

  Future<void> _showMenuSheet(BuildContext context) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: context.trae.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
            top: Radius.circular(TraeTokens.radiusXl)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(TraeTokens.gapLg),
              child: Text(conversation.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TraeText.sectionTitle(sheetContext)),
            ),
            ListTile(
              leading: Icon(conversation.pinned
                  ? Icons.push_pin_outlined
                  : Icons.push_pin),
              title: Text(conversation.pinned ? '取消置顶' : '置顶'),
              onTap: () => Navigator.of(sheetContext).pop('pin'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('重命名'),
              onTap: () => Navigator.of(sheetContext).pop('rename'),
            ),
            // M1-12.4：导出入口（格式选择 Sheet 在 _export 中弹出）
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('导出'),
              onTap: () => Navigator.of(sheetContext).pop('export'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: sheetContext.trae.danger),
              title: Text('删除',
                  style: TextStyle(color: sheetContext.trae.danger)),
              onTap: () => Navigator.of(sheetContext).pop('delete'),
            ),
          ],
        ),
      ),
    );
    switch (action) {
      case 'pin':
        onTogglePinned();
      case 'rename':
        onRename();
      case 'export':
        onExport();
      case 'delete':
        onDelete();
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: Key('conversation_tile_${conversation.id}'),
      onTap: onOpen,
      child: Row(
        children: [
          // 选中态竖条（不用整行底色，保持 AI 扁平基调）
          Container(
            width: 3,
            height: 34,
            color: selected ? context.trae.accent : Colors.transparent,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(TraeTokens.gapMd, TraeTokens.gapSm,
                  TraeTokens.gapXs, TraeTokens.gapSm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    conversation.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: TraeTokens.fontSection,
                      color: selected ? context.trae.accent : context.trae.inkSoft,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${formatRelativeTime(conversation.updatedAt)} · $messageCount 条消息',
                    style: TraeText.meta(context),
                  ),
                ],
              ),
            ),
          ),
          InkResponse(
            key: Key('conversation_menu_${conversation.id}'),
            onTap: () => _showMenuSheet(context),
            radius: 20,
            child: Padding(
              padding: const EdgeInsets.all(TraeTokens.gapMd),
              child: Icon(Icons.more_horiz,
                  size: 18, color: context.trae.muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// 相对时间：刚刚 / N 分钟前 / 昨天 14:20 / M 月 D 日（当天显示时分）
String formatRelativeTime(DateTime t) {
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  final hh = t.hour.toString().padLeft(2, '0');
  final mm = t.minute.toString().padLeft(2, '0');
  final dayDiff = DateTime(now.year, now.month, now.day)
      .difference(DateTime(t.year, t.month, t.day))
      .inDays;
  if (dayDiff == 0) return '$hh:$mm';
  if (dayDiff == 1) return '昨天 $hh:$mm';
  return '${t.month} 月 ${t.day} 日';
}

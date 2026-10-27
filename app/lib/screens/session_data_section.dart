// SessionDataSection（M1-12.6，SPEC v0.3.5 §10「会话数据管理」/ docs/ui-design-spec.md §3.8）：
// 「会话数据」区块——本地会话占用的查看、全部会话导出、整包导入、全部清空。
//
// 【v0.0.9】宿主由「设置页常驻底部区块」改为独立页 `SessionDataScreen`，
// 本类只保留内容与交互逻辑（宿主负责 AppBar 与页首说明）。
//
// 四个入口（SPEC §10）：
// - 查看本地会话占用：会话数 / 消息数 / 库文件估算占用
// - 导出全部会话：打包成单个 .json（一次分享面板、一次落盘），可原样回导
// - 导入 .json：解析打包文件 → 预览确认 → 写入当前 Profile
// - 清空全部会话：二次确认后清库
//
// 为什么打包成单个 .json 而非逐个分享：用户要的是一份可归档的整体；
// 且打包格式与单会话导出同源，导出→导入天然闭环。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../providers/chat_provider.dart';
import '../providers/connection_provider.dart';
import '../services/export_service.dart';
import '../services/import_service.dart';
import '../theme/trae_theme.dart';
import 'import_preview_dialog.dart';

/// 本地会话占用统计
class SessionUsage {
  const SessionUsage({
    required this.conversationCount,
    required this.messageCount,
    required this.sizeBytes,
  });

  final int conversationCount;
  final int messageCount;
  final int sizeBytes;

  /// `12 个会话 · 340 条消息 · 占用 1.2 MB`
  String get label {
    final parts = <String>[
      '$conversationCount 个会话',
      '$messageCount 条消息',
      '占用 ${_sizeLabel(sizeBytes)}',
    ];
    return parts.join(' · ');
  }
}

String _sizeLabel(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// 设置页「会话数据」区块
class SessionDataSection extends ConsumerStatefulWidget {
  const SessionDataSection({super.key});

  @override
  ConsumerState<SessionDataSection> createState() => _SessionDataSectionState();
}

class _SessionDataSectionState extends ConsumerState<SessionDataSection> {
  SessionUsage? _usage;
  bool _loadingUsage = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadUsage();
  }

  Future<void> _loadUsage() async {
    final repo = ref.read(conversationRepositoryProvider);
    try {
      final conversations = await repo.countConversations();
      final messages = await repo.countMessages();
      final bytes = await repo.estimateSizeBytes();
      if (!mounted) return;
      setState(() {
        _usage = SessionUsage(
          conversationCount: conversations,
          messageCount: messages,
          sizeBytes: bytes,
        );
        _loadingUsage = false;
      });
    } on Object catch (_) {
      if (!mounted) return;
      setState(() => _loadingUsage = false);
    }
  }

  void _invalidateLists() {
    ref.invalidate(conversationsProvider);
    ref.invalidate(messageCountsProvider);
  }

  /// 导出全部会话：逐会话读消息 → 打包 → 分享面板
  Future<void> _exportAll() async {
    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(conversationRepositoryProvider);
    setState(() => _busy = true);
    try {
      final conversations = await repo.listConversations();
      if (conversations.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('没有可导出的会话')));
        return;
      }
      final messagesByConversation = <String, List<ConversationMessage>>{};
      for (final c in conversations) {
        messagesByConversation[c.id] = await repo.loadMessages(c.id);
      }
      final result = await ref.read(exportServiceProvider).exportAllBundle(
        conversations: conversations,
        messagesByConversation: messagesByConversation,
        profileMetaById: await _resolveProfileMeta(conversations),
      );
      await shareExportResult(result);
      messenger.showSnackBar(
        SnackBar(content: Text('已导出全部会话（${result.sizeLabel}）')),
      );
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 会话所属 Profile 的主机元信息（Profile 可能已删除 → 缺失即不写该字段）
  Future<Map<String, ExportProfileMeta>> _resolveProfileMeta(
    List<Conversation> conversations,
  ) async {
    final profiles = await ref.read(profilesProvider.future);
    final byId = {for (final p in profiles) p.id: p};
    final result = <String, ExportProfileMeta>{};
    for (final c in conversations) {
      final p = byId[c.profileId];
      if (p == null) continue;
      result[c.profileId] = ExportProfileMeta(
        name: p.name,
        host: p.host,
        port: p.port,
      );
    }
    return result;
  }

  /// 导入会话（v0.0.10：单会话 / 会话包自动识别）。
  ///
  /// 选文件 → 解析 → 预览确认 → 写入当前 Profile。
  Future<void> _importAll() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final profileId = ref.read(currentProfileProvider)?.id ?? 'default';

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
    if (parsed == null) return; // 用户取消
    if (!mounted) return;

    final confirmed =
        await showImportAutoPreviewDialog(navigator.context, parsed);
    if (!confirmed) return;

    try {
      final created = await ref.read(importServiceProvider).importAuto(
            parsed,
            profileId: profileId,
            repository: ref.read(conversationRepositoryProvider),
          );
      _invalidateLists();
      await _loadUsage();
      if (created.isNotEmpty) {
        await ref.read(chatControllerProvider.notifier).loadConversation(created.first);
      }
      messenger.showSnackBar(SnackBar(
        content: Text('已导入 ${created.length} 个会话'
            '（${parsed.messageCount} 条消息）'),
      ));
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
    }
  }

  /// 清空全部会话：二次确认 → 清库 → 重置当前会话
  Future<void> _clearAll() async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await _confirmClearAll(context);
    if (!confirmed) return;
    try {
      await ref.read(conversationRepositoryProvider).deleteAll();
      _invalidateLists();
      await _loadUsage();
      ref.read(chatControllerProvider.notifier).newConversation();
      messenger.showSnackBar(const SnackBar(content: Text('已清空全部会话')));
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('清空失败：$e')));
    }
  }

  Future<bool> _confirmClearAll(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('clear_all_dialog'),
        title: Text('清空全部会话？', style: TraeText.sectionTitle(ctx)),
        content: Text(
          '将删除本机上所有会话及其消息，不可恢复。建议先导出全部会话。',
          style: TraeText.body(ctx),
        ),
        actions: [
          TextButton(
            key: const Key('btn_cancel_clear_all'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('btn_confirm_clear_all'),
            style: FilledButton.styleFrom(backgroundColor: ctx.trae.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    ).then((ok) => ok ?? false);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            TraeTokens.gapLg,
            TraeTokens.gapLg,
            TraeTokens.gapLg,
            TraeTokens.gapSm,
          ),
          child: Text('会话数据', style: TraeText.sectionTitle(context)),
        ),
        _usageTile(context),
        _actionTile(
          context,
          key: const Key('btn_export_all'),
          icon: Icons.upload_file,
          title: '导出全部会话',
          subtitle: '打包为一个 .json，可再次导入',
          onTap: _busy ? null : _exportAll,
        ),
        _actionTile(
          context,
          key: const Key('btn_import_all'),
          icon: Icons.download,
          title: '导入会话',
          subtitle: '从 .json 导入单个会话或会话包（自动识别）',
          onTap: _busy ? null : _importAll,
        ),
        _actionTile(
          context,
          key: const Key('btn_clear_all'),
          icon: Icons.delete_outline,
          title: '清空全部会话',
          subtitle: '删除本机上所有会话（需二次确认）',
          destructive: true,
          onTap: _busy ? null : _clearAll,
        ),
      ],
    );
  }

  Widget _usageTile(BuildContext context) {
    final usage = _usage;
    final subtitle = _loadingUsage
        ? '统计中…'
        : (usage == null ? '统计失败' : usage.label);
    return ListTile(
      key: const Key('session_usage_info'),
      leading: Icon(Icons.storage, color: context.trae.inkSoft),
      title: Text('本地会话占用', style: TraeText.body(context)),
      subtitle: Text(subtitle, style: TraeText.meta(context)),
    );
  }

  Widget _actionTile(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required Future<void> Function()? onTap,
    bool destructive = false,
  }) {
    final color = destructive ? context.trae.warnText : context.trae.inkSoft;
    return ListTile(
      key: key,
      leading: Icon(icon, color: color),
      title: Text(
        title,
        style: TextStyle(
          fontSize: TraeTokens.fontBody,
          color: destructive ? context.trae.warnText : context.trae.ink,
        ),
      ),
      subtitle: Text(subtitle, style: TraeText.meta(context)),
      onTap: onTap,
    );
  }
}

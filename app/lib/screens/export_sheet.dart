// ExportFormatSheet（M1-12.4，SPEC v0.3.5 §5.1 / docs/ui-design-spec.md §3.8）：
// 会话导出格式选择弹层，四格式（.md/.json/.html/.pdf）+ 主按钮「分享 / 保存到文件」。
//
// - 数据：ExportService.export（入参 Conversation + DB 消息行 + Profile 元信息）
// - 链路（零权限）：bytes → App 临时目录 → share_plus 系统分享面板，
//   不写公共 Download（Android 11+ scoped storage，见 ADR-9 预研）
// - .json 行带「可回导」胶囊（唯一支持导入的格式），其余三项标「仅导出」
//   —— 让用户在选之前就知道哪个能回导（SPEC §5.3）
// - 成功 toast：`已导出 Markdown（24 KB）`；失败在弹层内报错可重试
//
// 入口（两处，§3.8）：抽屉会话行尾 ⋯ →「导出」；对话页顶栏 ⋯ →「导出当前会话」。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/connection_profile.dart';
import '../models/conversation.dart';
import '../providers/chat_provider.dart';
import '../providers/connection_provider.dart';
import '../services/conversation_repository.dart';
import '../services/export_service.dart';
import '../theme/trae_theme.dart';

/// 弹出格式选择 Sheet 并完成「导出 → 分享 → toast」全链路。
/// 调用方保证 [conversation] 非空（新会话未落库时入口侧已拦截）。
Future<void> showExportFormatSheet(
    BuildContext context, WidgetRef ref, Conversation conversation) async {
  // 先捕获 messenger：sheet 关闭后（drawer/页面 context 可能已 unmounted）仍可 toast
  final messenger = ScaffoldMessenger.of(context);
  final repository = ref.read(conversationRepositoryProvider);
  // v0.0.10：注入图片解析器，.json 导出内联图片 dataURL
  final exportService = ref.read(exportServiceProvider);
  // autoDispose provider：read(future) 拿到的 Future 不随 provider dispose 失效
  final profilesFuture = ref.read(profilesProvider.future);

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: context.trae.surface,
    shape: const RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(top: Radius.circular(TraeTokens.radiusXl)),
    ),
    builder: (sheetContext) => _ExportSheet(
      messenger: messenger,
      conversation: conversation,
      repository: repository,
      exportService: exportService,
      profilesFuture: profilesFuture,
    ),
  );
}

class _ExportSheet extends StatefulWidget {
  const _ExportSheet({
    required this.messenger,
    required this.conversation,
    required this.repository,
    required this.exportService,
    required this.profilesFuture,
  });

  final ScaffoldMessengerState messenger;
  final Conversation conversation;
  final ConversationRepository repository;
  final ExportService exportService;
  final Future<List<ConnectionProfile>> profilesFuture;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  ExportFormat _format = ExportFormat.markdown;
  bool _exporting = false;
  String? _error;

  /// 解析主机元信息（Profile 可能已删除/读取失败 → 不带，导出内容不受影响）
  Future<ExportProfileMeta?> _resolveProfileMeta() async {
    try {
      final profiles = await widget.profilesFuture;
      final p = profiles
          .where((x) => x.id == widget.conversation.profileId)
          .firstOrNull;
      return p == null
          ? null
          : ExportProfileMeta(name: p.name, host: p.host, port: p.port);
    } on Object {
      return null;
    }
  }

  Future<void> _share() async {
    if (_exporting) return;
    setState(() {
      _exporting = true;
      _error = null;
    });
    try {
      final messages =
          await widget.repository.loadMessages(widget.conversation.id);
      final result = await widget.exportService.export(
        conversation: widget.conversation,
        messages: messages,
        format: _format,
        profileMeta: await _resolveProfileMeta(),
      );
      await shareExportResult(result);
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.messenger.showSnackBar(SnackBar(
        content: Text('已导出 ${_format.label}（${result.sizeLabel}）'),
      ));
    } on Object catch (e) {
      // 弹层内报错保持打开，用户可换格式重试（toast 会被 sheet 自身遮挡）
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _error = '导出失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        // 内容高度随格式行数与错误文案变化，矮屏（如 16:9）下固定 Column 会溢出，
        // 故外层可滚动。
        child: Padding(
          padding: const EdgeInsets.fromLTRB(TraeTokens.gapLg, TraeTokens.gapLg,
              TraeTokens.gapLg, TraeTokens.gapLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('导出会话', style: TraeText.sectionTitle(context)),
              const SizedBox(height: 2),
              Text(
                widget.conversation.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TraeText.meta(context),
              ),
              const SizedBox(height: TraeTokens.gapMd),
              for (final f in ExportFormat.values)
                _FormatRow(
                  format: f,
                  selected: f == _format,
                  enabled: !_exporting,
                  onTap: () => setState(() => _format = f),
                ),
              if (_error != null) ...[
                const SizedBox(height: TraeTokens.gapSm),
                Text(_error!,
                    style: TextStyle(
                        fontSize: TraeTokens.fontMeta,
                        color: context.trae.warnText)),
              ],
              const SizedBox(height: TraeTokens.gapMd),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('export_share_button'),
                  onPressed: _exporting ? null : _share,
                  style: FilledButton.styleFrom(
                    backgroundColor: context.trae.accent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: context.trae.accentTint,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(TraeTokens.radiusMd)),
                  ),
                  child: _exporting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('分享 / 保存到文件',
                          style: TextStyle(
                              fontSize: TraeTokens.fontSection,
                              fontWeight: FontWeight.w500)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单个格式行：图标 + 格式名（.ext）+ 用途说明 + 回导胶囊 + ›。
/// 选中态：图标/格式名/› 转 accent（与抽屉选中态同一「点色不铺底」基调）。
class _FormatRow extends StatelessWidget {
  const _FormatRow({
    required this.format,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final ExportFormat format;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  static const _descriptions = {
    ExportFormat.markdown: '适合存档与二次编辑',
    ExportFormat.json: '结构化数据，支持回导',
    ExportFormat.html: '单文件网页，可直接打开',
    ExportFormat.pdf: '适合打印与分享',
  };

  static const _icons = {
    ExportFormat.markdown: Icons.description_outlined,
    ExportFormat.json: Icons.data_object_outlined,
    ExportFormat.html: Icons.code_outlined,
    ExportFormat.pdf: Icons.picture_as_pdf_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final color = selected ? context.trae.accent : context.trae.inkSoft;
    final reimportable = format == ExportFormat.json;
    return InkWell(
      key: Key('export_option_${format.name}'),
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: TraeTokens.gapMd),
        child: Row(
          children: [
            Icon(_icons[format], size: 20, color: color),
            const SizedBox(width: TraeTokens.gapMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${format.label}（.${format.fileExtension}）',
                    style: TextStyle(
                        fontSize: TraeTokens.fontSection,
                        fontWeight: FontWeight.w500,
                        color: selected
                            ? context.trae.accent
                            : context.trae.ink),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    _descriptions[format]!,
                    style: TraeText.meta(context),
                  ),
                ],
              ),
            ),
            // 回导胶囊：json=「可回导」（accentTint 底），其余「仅导出」灰胶囊
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: reimportable
                    ? context.trae.accentTint
                    : context.trae.surface2,
                borderRadius:
                    BorderRadius.circular(TraeTokens.radiusPill),
              ),
              child: Text(
                reimportable ? '可回导' : '仅导出',
                style: TextStyle(
                  fontSize: 11,
                  color: reimportable
                      ? context.trae.accent
                      : context.trae.muted,
                ),
              ),
            ),
            const SizedBox(width: TraeTokens.gapSm),
            Icon(Icons.chevron_right,
                size: 18,
                color: selected
                    ? context.trae.accent
                    : context.trae.muted),
          ],
        ),
      ),
    );
  }
}

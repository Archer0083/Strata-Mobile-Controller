// ImportPreviewDialog（M1-12.5，SPEC v0.3.5 §5.3 / docs/ui-design-spec.md §3.8）：
// 导入前的「预览确认」弹窗——先让用户看清将要导入什么，再决定是否入库。
//
// 预览内容（§3.8）：`识别到 1 个会话 · 34 条消息 · 导出时间 2026-10-26`
// 两个按钮：「导入」（accent）/「取消」。
//
// 为什么用 Dialog 而非 Bottom Sheet：导入是低频且需谨慎确认的动作，
// 居中对话框的阻断感更强，也避免与抽屉底部入口的层级混淆。

import 'package:flutter/material.dart';

import '../services/import_service.dart';
import '../theme/trae_theme.dart';

/// 弹出导入预览确认框。返回 true 表示用户确认导入，false 表示取消。
Future<bool> showImportPreviewDialog(
    BuildContext context, ParsedConversation parsed) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => _ImportPreviewDialog(parsed: parsed),
  );
  return confirmed ?? false;
}

/// 弹出统一导入预览确认框（v0.0.10：单会话 / 会话包自动识别后的通用预览）。
///
/// 返回 true 表示用户确认导入，false 表示取消。
Future<bool> showImportAutoPreviewDialog(
    BuildContext context, ParsedImport parsed) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => _ImportAutoPreviewDialog(parsed: parsed),
  );
  return confirmed ?? false;
}

/// 统一预览（v0.0.10）：会话数 + 消息数 + 导出时间 + 跳过提示。
class _ImportAutoPreviewDialog extends StatelessWidget {
  const _ImportAutoPreviewDialog({required this.parsed});

  final ParsedImport parsed;

  @override
  Widget build(BuildContext context) {
    final isBundle = parsed is ParsedImportBundle;
    return AlertDialog(
      key: const Key('import_preview_dialog'),
      title: Text(isBundle ? '导入会话包' : '导入会话',
          style: TraeText.sectionTitle(context)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isBundle ? '${parsed.conversationCount} 个会话' : '1 个会话',
            style: TextStyle(
              fontSize: TraeTokens.fontSection,
              fontWeight: FontWeight.w500,
              color: context.trae.ink,
            ),
          ),
          const SizedBox(height: TraeTokens.gapSm),
          Text(_summaryLine(), style: TraeText.meta(context)),
          if (parsed.skippedCount > 0) ...[
            const SizedBox(height: TraeTokens.gapXs),
            Text(
              '有 ${parsed.skippedCount} 条数据格式异常，导入时将跳过',
              style: TextStyle(
                  fontSize: TraeTokens.fontMeta, color: context.trae.warnText),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const Key('import_preview_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('import_preview_confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: context.trae.accent,
            foregroundColor: Colors.white,
          ),
          child: const Text('导入'),
        ),
      ],
    );
  }

  /// `识别到 2 个会话 · 42 条消息 · 导出时间 2026-10-26`
  String _summaryLine() {
    final parts = <String>[
      '识别到 ${parsed.conversationCount} 个会话',
      '${parsed.messageCount} 条消息',
    ];
    final exportedAt = parsed.exportedAt;
    if (exportedAt != null) {
      parts.add('导出时间 ${_formatDate(exportedAt)}');
    }
    return parts.join(' · ');
  }

  /// 日期显示为 `2026-10-26`（不含时间，仅日期）
  static String _formatDate(DateTime t) {
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    return '${t.year}-$m-$d';
  }
}

/// 弹出「导出全部会话」打包文件的导入预览确认框（M1-12.6）。
///
/// 与单会话版 [showImportPreviewDialog] 的差异：标题列表化 + 会话数计入摘要。
/// 返回 true 表示用户确认导入，false 表示取消。
Future<bool> showImportBundlePreviewDialog(
    BuildContext context, ParsedBundle bundle) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => _ImportBundlePreviewDialog(bundle: bundle),
  );
  return confirmed ?? false;
}

class _ImportBundlePreviewDialog extends StatelessWidget {
  const _ImportBundlePreviewDialog({required this.bundle});

  final ParsedBundle bundle;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('import_bundle_preview_dialog'),
      title: Text('导入会话包', style: TraeText.sectionTitle(context)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${bundle.conversations.length} 个会话',
            style: TextStyle(
              fontSize: TraeTokens.fontSection,
              fontWeight: FontWeight.w500,
              color: context.trae.ink,
            ),
          ),
          const SizedBox(height: TraeTokens.gapSm),
          Text(_summaryLine(), style: TraeText.meta(context)),
          if (bundle.skippedCount > 0) ...[
            const SizedBox(height: TraeTokens.gapXs),
            Text(
              '有 ${bundle.skippedCount} 个会话格式异常，导入时将跳过',
              style: TextStyle(
                  fontSize: TraeTokens.fontMeta, color: context.trae.warnText),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const Key('import_preview_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('import_preview_confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: context.trae.accent,
            foregroundColor: Colors.white,
          ),
          child: const Text('导入'),
        ),
      ],
    );
  }

  /// `识别到 3 个会话 · 42 条消息 · 导出时间 2026-10-26`
  String _summaryLine() {
    final parts = <String>[
      '识别到 ${bundle.conversations.length} 个会话',
      '${bundle.totalMessages} 条消息',
    ];
    final exportedAt = bundle.exportedAt;
    if (exportedAt != null) {
      parts.add('导出时间 ${_formatDate(exportedAt)}');
    }
    return parts.join(' · ');
  }

  /// 日期显示为 `2026-10-26`（不含时间，仅日期）
  static String _formatDate(DateTime t) {
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    return '${t.year}-$m-$d';
  }
}

class _ImportPreviewDialog extends StatelessWidget {
  const _ImportPreviewDialog({required this.parsed});

  final ParsedConversation parsed;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('import_preview_dialog'),
      title: Text('导入会话', style: TraeText.sectionTitle(context)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(parsed.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: TraeTokens.fontSection,
                fontWeight: FontWeight.w500,
                color: context.trae.ink,
              )),
          const SizedBox(height: TraeTokens.gapSm),
          Text(_summaryLine(), style: TraeText.meta(context)),
          if (parsed.skippedCount > 0) ...[
            const SizedBox(height: TraeTokens.gapXs),
            Text(
              '有 ${parsed.skippedCount} 条消息格式异常，导入时将跳过',
              style: TextStyle(
                  fontSize: TraeTokens.fontMeta, color: context.trae.warnText),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const Key('import_preview_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('import_preview_confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: context.trae.accent,
            foregroundColor: Colors.white,
          ),
          child: const Text('导入'),
        ),
      ],
    );
  }

  /// `识别到 1 个会话 · 34 条消息 · 导出时间 2026-10-26`
  /// 导出时间缺失（文件非本 App 导出）时省略该段。
  String _summaryLine() {
    final parts = <String>[
      '识别到 1 个会话',
      '${parsed.messages.length} 条消息',
    ];
    final exportedAt = parsed.exportedAt;
    if (exportedAt != null) {
      parts.add('导出时间 ${_formatDate(exportedAt)}');
    }
    return parts.join(' · ');
  }

  /// 日期显示为 `2026-10-26`（不含时间，仅日期）
  static String _formatDate(DateTime t) {
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    return '${t.year}-$m-$d';
  }
}

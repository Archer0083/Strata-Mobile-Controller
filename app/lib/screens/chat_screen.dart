// ChatScreen（M1-6，SPEC §10；M1-11 UI 改版按 docs/ui-design-spec.md §3 落地）：
//
// 【与 v0.0.1 的形态差异（TRAE 风格）】
// - AI 输出**扁平无气泡**（直接落在暖白底上），用户消息才是灰圆角气泡
// - 「思考过程」从带底色的 ExpansionTile 卡片 → **扁平文字链 + chevron**，默认折叠
// - 思考 / 耗时 / token / 复制 统一收进一条**元信息带**（不再各占一行）
// - Composer 改三键布局：`+` / 麦克风 / 紫色圆形发送键（忙碌时变停止键）
// - 思考强度档位从 SegmentedButton → 输入框上方的文字胶囊
// - 顶部加「一键到底」回底按钮；空态改引导块
// - 顶栏承载服务器名 + 连接状态点 + 低频功能入口（无底部 Tab）
//
// 【M2-5 增量】
// - 附件：`+` 接 pickAttachments（文本白名单 512KB 围栏拼 prompt /
//   图片 20MB dataURL，health.images 门控），chips 可删，发送即清空
// - meta 行对齐 web：completion tokens · tok/s（genSecs>0.25）· 已停止
// - thinking 标题三态：思考中… / 思考了 X 秒 / 思考过程
// - 忙碌时发送键变可点的停止键（stop()）
// - 采样抽屉：temp/top_p/top_k 滑杆 + max/seed 输入，Apply 才落 setSampling
// - 用户消息带图片缩略图（web msg-images 220x180 口径）

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat_models.dart';
import '../models/strata_models.dart';
import '../providers/chat_provider.dart';
import '../providers/connection_provider.dart';
import '../providers/monitor_provider.dart';
import '../services/attachment_service.dart';
import '../services/export_service.dart';
import '../services/screenshot_service.dart';
import '../theme/trae_theme.dart';
import '../widgets/markdown_view.dart';
import 'conversation_drawer.dart';
import 'export_sheet.dart';
import 'home_shell.dart';
import 'images_screen.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();

  /// 是否已滚动到底部 —— 决定「一键到底」按钮是否出现
  bool _atBottom = true;

  /// 待发送附件（M2-5）：chips 展示 + 随下一条消息发出后清空（内存态，不落库）
  final List<AttachedTextFile> _files = [];
  final List<PickedImage> _images = [];

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _inputController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    // reverse: true 时，maxScrollExtent 为 0，offset 越负表示越靠下
    final atBottom = _scrollController.offset >= -24;
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _send() {
    final text = _inputController.text.trim();
    // 附件在身时正文可为空（web 同口径：userText 过滤空段后拼接）
    if (text.isEmpty && _files.isEmpty && _images.isEmpty) return;
    ref.read(chatControllerProvider.notifier).send(
          text,
          files: List.of(_files),
          images: [for (final i in _images) i.dataUrl],
        );
    _inputController.clear();
    setState(() {
      _files.clear();
      _images.clear();
    });
    // 新消息发出后回到底部
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  /// `+` 入口：附件选择（M2-5）。
  /// 图片放行由 health.images 门控（web attach-btn 同口径）；被拒项逐个 toast。
  Future<void> _pickAttachments() async {
    final snapshot = ref.read(monitorProvider).valueOrNull;
    final allowImages = snapshot?.health.images ?? false;
    final picked = await pickAttachments();
    if (picked.isEmpty) return;
    final rejected = <String>[];
    for (final p in picked) {
      switch (p) {
        case PickedTextFile():
          _files.add(p.file);
        case PickedImage() when allowImages:
          _images.add(p);
        case PickedImage():
          rejected.add('${p.name}：当前模型为纯文本模型，未开放图片');
        case RejectedAttachment():
          rejected.add(p.reason);
      }
    }
    if (!mounted) return;
    if (rejected.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(rejected.join('\n'))),
      );
    }
    if (_files.isNotEmpty || _images.isNotEmpty) setState(() {});
  }

  /// 顶栏 ⋯ 菜单（M1-12.4，§3.8 入口之二）：导出当前会话。
  /// 新会话未落库时提示而非禁用入口（用户可先发送再导出）。
  Future<void> _showOverflowMenu() async {
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
              child: Text('会话操作', style: TraeText.sectionTitle(sheetContext)),
            ),
            ListTile(
              key: const Key('chat_overflow_export'),
              leading: const Icon(Icons.ios_share),
              title: const Text('导出当前会话（四格式可选）'),
              subtitle: const Text('.md / .json / .html / .pdf'),
              onTap: () => Navigator.of(sheetContext).pop('export'),
            ),
            // v0.0.4：单局 .md / .json 直达导出（用户实测反馈：
            // 常用格式一键直达，不必进四格式弹层）
            ListTile(
              key: const Key('chat_overflow_export_md'),
              leading: const Icon(Icons.description_outlined),
              title: const Text('导出为 Markdown（.md）'),
              onTap: () => Navigator.of(sheetContext).pop('export_md'),
            ),
            ListTile(
              key: const Key('chat_overflow_export_json'),
              leading: const Icon(Icons.data_object_outlined),
              title: const Text('导出为 JSON（.json，可回导）'),
              onTap: () => Navigator.of(sheetContext).pop('export_json'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action != 'export') {
      // 直达导出：.md / .json 一键完成，不经过四格式弹层
      await _exportCurrentDirect(
        action == 'export_md' ? ExportFormat.markdown : ExportFormat.json,
      );
      return;
    }
    final conversation = ref.read(chatControllerProvider).conversation;
    if (conversation == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前是新会话，发送消息后再导出')),
      );
      return;
    }
    await showExportFormatSheet(context, ref, conversation);
  }

  /// 单局直达导出（v0.0.4）：读库 → 组装 → share_plus 分享 → toast。
  /// 与四格式弹层同链路（ExportService.export），仅少了选格式一步。
  Future<void> _exportCurrentDirect(ExportFormat format) async {
    final conversation = ref.read(chatControllerProvider).conversation;
    if (conversation == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前是新会话，发送消息后再导出')),
      );
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    try {
      final messages =
          await ref.read(conversationRepositoryProvider).loadMessages(conversation.id);
      final profiles = await ref.read(profilesProvider.future);
      final p = profiles
          .where((x) => x.id == conversation.profileId)
          .firstOrNull;
      final meta = p == null
          ? null
          : ExportProfileMeta(name: p.name, host: p.host, port: p.port);
      final result = await ref.read(exportServiceProvider).export(
        conversation: conversation,
        messages: messages,
        format: format,
        profileMeta: meta,
      );
      await shareExportResult(result);
      messenger.showSnackBar(SnackBar(
        content: Text('已导出 ${format.label}（${result.sizeLabel}）'),
      ));
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatControllerProvider);
    final profile = ref.watch(currentProfileProvider);
    final busy = chat.phase != ChatSendPhase.idle;

    return Scaffold(
      backgroundColor: context.trae.bg,
      // M1-12.3：会话历史抽屉（M3 AppBar 自动显示打开按钮，左缘右滑可拉出）
      drawer: const ConversationDrawer(),
      appBar: AppBar(
        titleSpacing: TraeTokens.gapLg,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              profile?.name ?? '未连接',
              style: TraeText.pageTitle(context),
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                TraeWidgets.statusDot(
                  profile == null ? context.trae.muted : context.trae.success,
                ),
                const SizedBox(width: 6),
                Text(
                  profile == null ? '未建立连接' : profile.baseUrl,
                  style: TraeText.meta(context),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ],
        ),
        actions: [
          // M2-6：生图入口（health.image_generation 门控显隐，web tab-btn-images
          // 同口径）；push 独立页，非常驻
          if (ref.watch(imageGenEnabledProvider))
            IconButton(
              key: const Key('chat_open_images'),
              icon: const Icon(Icons.image_outlined, size: 20),
              color: context.trae.inkSoft,
              tooltip: '生成图片',
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const ImagesScreen())),
            ),
          const TopNavEntries(exclude: TopNav.chat),
          // M1-12.4：顶栏 ⋯ 会话操作菜单（导出当前会话）
          IconButton(
            key: const Key('chat_overflow_menu'),
            icon: const Icon(Icons.more_vert, size: 20),
            color: context.trae.inkSoft,
            onPressed: _showOverflowMenu,
          ),
          const SizedBox(width: TraeTokens.gapSm),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: chat.messages.isEmpty
                ? _EmptyState(onPick: (q) {
                    _inputController.text = q;
                    _inputController.selection =
                        TextSelection.collapsed(offset: q.length);
                    _send();
                  })
                : Stack(
                    children: [
                      // 反向列表：reverse:true 下 index 0 渲染在屏幕底部，
                      // 必须映射到最新消息（length-1-index），否则最旧消息贴底、
                      // 最新回复显示在问话上方（v0.0.4 修复的用户反馈 bug）
                      ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(
                            TraeTokens.gapLg, TraeTokens.gapLg, TraeTokens.gapLg, TraeTokens.gapMd),
                        itemCount: chat.messages.length,
                        itemBuilder: (_, index) => _MessageView(
                            message: chat.messages[chat.messages.length - 1 - index]),
                      ),
                      if (!_atBottom)
                        Positioned(
                          right: TraeTokens.gapLg,
                          bottom: TraeTokens.gapMd,
                          child: _ScrollToBottomButton(onTap: _scrollToBottom),
                        ),
                    ],
                  ),
          ),
          _InputBar(
            controller: _inputController,
            busy: busy,
            effort: chat.effort,
            onEffortChanged: (e) =>
                ref.read(chatControllerProvider.notifier).setEffort(e),
            sampling: chat.sampling,
            onSamplingChanged: (s) =>
                ref.read(chatControllerProvider.notifier).setSampling(s),
            onStop: () => ref.read(chatControllerProvider.notifier).stop(),
            files: List.unmodifiable(_files),
            images: List.unmodifiable(_images),
            onPickAttachments: _pickAttachments,
            onRemoveFile: (f) => setState(() => _files.remove(f)),
            onRemoveImage: (i) => setState(() => _images.remove(i)),
            onSend: _send,
            onNewChat: () => ref.read(chatControllerProvider.notifier).newConversation(),
            onExportMarkdown: () => _exportCurrentDirect(ExportFormat.markdown),
          ),
        ],
      ),
    );
  }
}

/// 空态引导块（TRAE 风格：一行灰字 → 居中引导 + 示例问题胶囊）
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onPick});

  final ValueChanged<String> onPick;

  static const _samples = [
    '你好，请介绍一下你自己',
    '用一句话解释什么是张量并行',
  ];

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: TraeTokens.gapXl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: context.trae.accentTint,
                borderRadius: BorderRadius.circular(TraeTokens.radiusMd),
              ),
              child: Icon(Icons.auto_awesome_outlined,
                  color: context.trae.accent, size: 22),
            ),
            const SizedBox(height: TraeTokens.gapMd),
            Text('开始与本地模型对话', style: TraeText.sectionTitle(context)),
            const SizedBox(height: TraeTokens.gapSm),
            Text(
              '消息会发送到当前连接的 Strata 主机，由本地推理引擎处理。',
              textAlign: TextAlign.center,
              style: TraeText.meta(context),
            ),
            const SizedBox(height: TraeTokens.gapXl),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: TraeTokens.gapSm,
              runSpacing: TraeTokens.gapSm,
              children: [
                for (final s in _samples)
                  TraeWidgets.chip(context, s, onTap: () => onPick(s)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 「一键到底」回底按钮
class _ScrollToBottomButton extends StatelessWidget {
  const _ScrollToBottomButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.trae.surface,
      shape: CircleBorder(side: BorderSide(color: context.trae.line)),
      elevation: 0,
      shadowColor: Colors.black26,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            boxShadow: context.trae.shPop,
          ),
          child: Icon(Icons.keyboard_arrow_down,
              size: 20, color: context.trae.inkSoft),
        ),
      ),
    );
  }
}

/// 单条消息：用户=灰圆角气泡右对齐；AI=扁平无气泡左对齐
class _MessageView extends ConsumerStatefulWidget {
  const _MessageView({required this.message});

  final UiChatMessage message;

  @override
  ConsumerState<_MessageView> createState() => _MessageViewState();
}

class _MessageViewState extends ConsumerState<_MessageView> {
  /// 思考链展开状态。
  /// null = 跟随自动策略（流式中且正文未开始 → 展开；否则折叠）
  /// true/false = 用户手动展开/收起后固定，不再被自动策略覆盖
  bool? _manualExpanded;

  /// 自动策略：流式中且正文尚未开始 → 思考链展开
  bool _autoOpen(UiChatMessage message) {
    final chat = ref.watch(chatControllerProvider);
    final isStreamingThis = identical(chat.messages.lastOrNull, message) &&
        chat.phase != ChatSendPhase.idle;
    return isStreamingThis && message.content.isEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    if (message.isUser) return _UserBubble(message: message);
    final autoOpen = _autoOpen(message);
    return _AiMessage(
      message: message,
      open: _manualExpanded ?? autoOpen,
      streaming: autoOpen,
      onToggle: () => setState(() {
        // 点击时按"当前实际展开态"取反，并锁定为手动模式
        _manualExpanded = !(_manualExpanded ?? autoOpen);
      }),
    );
  }
}

class _UserBubble extends ConsumerWidget {
  const _UserBubble({required this.message});

  final UiChatMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Align(
      alignment: Alignment.centerRight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // 图片附件缩略图（M2-5，web .msg-images：max 220x180 + radiusMd）
          if (message.imageUrls.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: TraeTokens.gapXs),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: TraeTokens.gapSm,
                runSpacing: TraeTokens.gapSm,
                children: [
                  for (final url in message.imageUrls)
                    _ImageThumb(dataUrl: url),
                ],
              ),
            ),
          Container(
            key: Key('msg_${message.id}'),
            margin: const EdgeInsets.only(bottom: TraeTokens.gapXs),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78,
            ),
            decoration: BoxDecoration(
              // v0.0.4（f5）：对齐 Strata webUI —— 用户气泡 accent 底白字，
              // 右下角 6px（其余角 lg），呼应 web 端 msg--user
              color: context.trae.accent,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(TraeTokens.radiusLg),
                topRight: Radius.circular(TraeTokens.radiusLg),
                bottomLeft: Radius.circular(TraeTokens.radiusLg),
                bottomRight: Radius.circular(6),
              ),
            ),
            child: Text(
              message.content,
              style: TraeText.body(context)
                  .copyWith(color: context.trae.accentInk),
            ),
          ),
          // v0.0.4（f3）：用户消息同样可导出长截图 / .md
          _MessageExportButtons(message: message, alignRight: true),
        ],
      ),
    );
  }
}

/// 图片缩略图（M2-5）：dataURL → 内存图，最大 220x180（web .msg-images 口径）
class _ImageThumb extends StatelessWidget {
  const _ImageThumb({required this.dataUrl});

  final String dataUrl;

  @override
  Widget build(BuildContext context) {
    final bytes = _decode();
    return Container(
      constraints: const BoxConstraints(maxWidth: 220, maxHeight: 180),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(TraeTokens.radiusMd),
        border: Border.all(color: context.trae.line),
      ),
      child: bytes == null
          ? Icon(Icons.broken_image_outlined,
              size: 32, color: context.trae.muted)
          : ClipRRect(
              borderRadius: BorderRadius.circular(TraeTokens.radiusMd),
              child: Image.memory(
                bytes,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(
                    Icons.broken_image_outlined,
                    size: 32,
                    color: context.trae.muted),
              ),
            ),
    );
  }

  Uint8List? _decode() {
    final comma = dataUrl.indexOf(',');
    if (comma < 0 || !dataUrl.startsWith('data:')) return null;
    try {
      return base64Decode(dataUrl.substring(comma + 1));
    } on FormatException {
      return null;
    }
  }
}

/// AI 消息：扁平无气泡 + 思考文字链 + 正文 + 元信息带
class _AiMessage extends StatelessWidget {
  const _AiMessage({
    required this.message,
    required this.open,
    required this.streaming,
    required this.onToggle,
  });

  final UiChatMessage message;

  /// 思考链是否展开
  final bool open;

  /// 是否处于"正在思考"状态（流式中且正文尚未开始）
  final bool streaming;

  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final hasReasoning =
        message.reasoning != null && message.reasoning!.isNotEmpty;

    return Padding(
      key: Key('msg_${message.id}'),
      padding: const EdgeInsets.only(bottom: TraeTokens.gapXl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasReasoning) ...[
            _ThinkingChain(
              text: message.reasoning!,
              open: open,
              streaming: streaming,
              thinkSecs: message.thinkSecs,
              onToggle: onToggle,
            ),
            const SizedBox(height: TraeTokens.gapSm),
          ],
          if (message.error != null)
            _ErrorRow(message: message)
          else if (message.content.isEmpty)
            // 已发出、未收到任何字节：长 TTFT「正在思考」（分钟级属正常，SPEC §6.1.2）
            Row(
              key: const Key('thinking_indicator'),
              children: [
                SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.8, color: context.trae.muted),
                ),
                const SizedBox(width: TraeTokens.gapSm),
                Text('正在思考…', style: TraeText.meta(context)),
              ],
            )
          else
            // M2-5：AI 正文 markdown 渲染（代码块恒暗 + copy，块级布局
            // 对齐 web markdown()），整体 SelectionArea 可长按全选
            MarkdownView(text: message.content),
          if (message.error == null) _MetaStrip(message: message),
        ],
      ),
    );
  }
}

/// 思考过程：扁平文字链 + chevron（TRAE 风格，无边框无底色，默认折叠）
class _ThinkingChain extends StatelessWidget {
  const _ThinkingChain({
    required this.text,
    required this.open,
    required this.streaming,
    required this.thinkSecs,
    required this.onToggle,
  });

  final String text;
  final bool open;
  final bool streaming;

  /// 思考耗时秒（web 三态标题：思考中… / 思考了 X 秒 / 思考过程）
  final double? thinkSecs;

  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: const Key('reasoning_block'),
          onTap: onToggle,
          borderRadius: BorderRadius.circular(TraeTokens.radiusSm),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedRotation(
                  turns: open ? 0.25 : 0,
                  duration: TraeTokens.durTrae,
                  child: Icon(Icons.chevron_right,
                      size: 16, color: context.trae.accent),
                ),
                const SizedBox(width: 2),
                Text(
                  // web 三态：思考中… / 思考了 X s / Thoughts（无计时时）
                  streaming
                      ? '思考中…'
                      : thinkSecs != null
                          ? '思考了 ${thinkSecs!.toStringAsFixed(1)} 秒'
                          : '思考过程',
                  style: TraeText.chain(context),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: TraeTokens.durTrae,
          curve: TraeTokens.easeTrae,
          alignment: Alignment.topLeft,
          child: open
              ? Padding(
                  padding: const EdgeInsets.only(top: TraeTokens.gapXs, left: 2),
                  child: Text(
                    text,
                    style: TextStyle(
                      fontSize: TraeTokens.fontChain,
                      height: 1.5,
                      color: context.trae.muted,
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// 元信息带：耗时 / token / 复制 —— 与思考链共用一条视觉带
class _MetaStrip extends StatelessWidget {
  const _MetaStrip({required this.message});

  final UiChatMessage message;

  /// web 口径：`${n} tokens${secs>0.25 ? ` · ${n/secs,1} tok/s` : ""}${stopped?" · stopped":""}`
  /// n = usage.completion_tokens；无 usage 且 stopped → 仅「已停止」
  String _tokenText(UiChatMessage m) {
    final usage = m.usage;
    if (usage == null) return m.stopped ? '已停止' : '';
    final n = usage.completionTokens;
    final secs = m.genSecs ?? 0;
    final rate = secs > 0.25 ? ' · ${(n / secs).toStringAsFixed(1)} tok/s' : '';
    final stopped = m.stopped ? ' · 已停止' : '';
    return '$n tokens$rate$stopped';
  }

  @override
  Widget build(BuildContext context) {
    final tokenText = _tokenText(message);
    // v0.0.4：无 usage（真实服务可不返回）也要有导出入口，仅省略 token 文本
    return Padding(
      padding: const EdgeInsets.only(top: TraeTokens.gapSm),
      child: Row(
        children: [
          if (tokenText.isNotEmpty) ...[
            Text(tokenText, style: TraeText.meta(context)),
            const SizedBox(width: TraeTokens.gapSm),
          ],
          const Spacer(),
          _MetaIconButton(
            icon: Icons.copy_all_outlined,
            label: '复制回复',
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: message.content));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
              );
            },
          ),
          const SizedBox(width: TraeTokens.gapSm),
          _MessageExportButtons(message: message),
        ],
      ),
    );
  }
}

/// v0.0.4（f3）：单条消息导出按钮组 —— 长截图 PNG + .md 下载分享。
/// AI 消息挂在元信息带；用户消息挂在气泡下方（右对齐）。
class _MessageExportButtons extends ConsumerWidget {
  const _MessageExportButtons({
    required this.message,
    this.alignRight = false,
  });

  final UiChatMessage message;
  final bool alignRight;

  Future<void> _exportPng(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final profile = ref.read(currentProfileProvider);
      final results = await ScreenshotService().renderMessagePngs(
        isUser: message.isUser,
        content: message.content,
        reasoning: message.reasoning,
        timestamp: message.timestamp,
        subtitle: profile == null ? null : '${profile.name} · ${profile.baseUrl}',
      );
      if (results.length > 1) {
        // 超长回复分片成多张（每片 ≤ GPU 纹理上限），提示用户分享面板
        // 里会看到多张连续编号的图片
        messenger.showSnackBar(SnackBar(
            content: Text('内容较长，已分为 ${results.length} 张长截图'),
            duration: const Duration(seconds: 2)));
      }
      await shareExportResults(results);
    } on Object catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('截图导出失败：$e')));
    }
  }

  Future<void> _exportMd(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = ExportService().exportMessageMarkdown(
        isUser: message.isUser,
        content: message.content,
        reasoning: message.reasoning,
        timestamp: message.timestamp,
      );
      await shareExportResult(result);
      messenger.showSnackBar(SnackBar(
          content: Text('已导出 .md（${result.sizeLabel}）'),
          duration: const Duration(seconds: 1)));
    } on Object catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('.md 导出失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final buttons = <Widget>[
      _MetaIconButton(
            key: const ValueKey('msg_export_png'),
            icon: Icons.photo_camera_back_outlined,
            label: '导出长截图',
            onTap: () => _exportPng(context, ref),
          ),
          const SizedBox(width: TraeTokens.gapSm),
          _MetaIconButton(
            key: const ValueKey('msg_export_md'),
            icon: Icons.description_outlined,
            label: '下载为 .md',
            onTap: () => _exportMd(context),
          ),
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: alignRight ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: buttons,
    );
  }
}

class _MetaIconButton extends StatelessWidget {
  const _MetaIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: true,
      child: InkResponse(
        onTap: onTap,
        radius: 18,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 15, color: context.trae.muted),
        ),
      ),
    );
  }
}

/// 错误行：错误图标 + 文案 + 重试
class _ErrorRow extends ConsumerWidget {
  const _ErrorRow({required this.message});

  final UiChatMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      key: const Key('msg_error'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline, size: 15, color: context.trae.danger),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            message.error!,
            style: TextStyle(fontSize: 13, color: context.trae.danger),
          ),
        ),
      ],
    );
  }
}

/// 底部输入区：状态行 + 附件栏 + Composer（webUI 对齐，v0.0.9）
///
/// 【v0.0.9 对话栏重排（第十轮真机反馈驱动）】
/// 测试志愿者反馈原话：
///   「chat 页面的对话栏的上方的思考关闭低中高采样排版不好看，
///     并且语音输入键只有图标没有实际功能点不动，
///     建议参考 webUI 的 chat 页面的对话栏的按钮和功能设计来修改 app 的对话页」
///
/// webUI 的 Composer（strata_ref/serve/web/index.html `#composer`）结构是：
///   底栏左：attach-btn(附件) / new-btn(新会话) / export-btn(导出 .md) / sampling-btn(采样与思考)
///   底栏右：composer-hint(提示) / stop-btn(忙碌时) / send-btn(提交)
/// 且 webUI 的 Sampling 抽屉内**同时**包含 Thinking 四档与采样参数——
/// 二者本就是同一件事（生成参数），App 却把它们拆成两排平铺胶囊。
///
/// 本次改动三处：
/// ① **删除「思考 关闭/低/中/高 + 采样」两排平铺胶囊**。
///    原实现是 `SizedBox(height: 26)` 固定高度行里塞 5 个胶囊，
///    在窄屏上换行挤压、字号被压扁，志愿者反馈「排版不好看」正是此处。
///    现在思考档位并入「采样与思考」抽屉（与 webUI 同构），
///    输入区上方只留**一行**极简状态文字（当前思考档位 + 是否已调采样），
///    不再是一排按钮。
/// ② **删除语音输入键**（`Icons.mic_none`，`onTap: () {}` 是空实现）。
///    它是纯装饰的死按钮——点了没反应比没有更糟。webUI 也没有麦克风。
///    真要语音输入需要引入录音权限与音频依赖，远超本轮范围。
/// ③ **底栏左键对齐 webUI**：附件(+) / 新会话 / 导出(.md)，
///    采样与思考改为一个图标键。发送键保持右下角圆形（与 TRAE 风格一致）。
class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.busy,
    required this.effort,
    required this.onEffortChanged,
    required this.sampling,
    required this.onSamplingChanged,
    required this.onStop,
    required this.files,
    required this.images,
    required this.onPickAttachments,
    required this.onRemoveFile,
    required this.onRemoveImage,
    required this.onSend,
    required this.onNewChat,
    required this.onExportMarkdown,
  });

  final TextEditingController controller;
  final bool busy;
  final ReasoningEffort effort;
  final ValueChanged<ReasoningEffort> onEffortChanged;
  final SamplingParams sampling;
  final ValueChanged<SamplingParams> onSamplingChanged;

  /// 忙碌时发送键变停止键的回调
  final VoidCallback onStop;

  /// 待发送附件（chips 展示，M2-5）
  final List<AttachedTextFile> files;
  final List<PickedImage> images;
  final Future<void> Function() onPickAttachments;
  final ValueChanged<AttachedTextFile> onRemoveFile;
  final ValueChanged<PickedImage> onRemoveImage;

  final VoidCallback onSend;

  /// 新会话（webUI `new-btn`）
  final VoidCallback onNewChat;

  /// 导出当前会话为 Markdown（webUI `export-btn`）
  final VoidCallback onExportMarkdown;

  static const _effortLabels = {
    ReasoningEffort.none: '关闭',
    ReasoningEffort.low: '低',
    ReasoningEffort.medium: '中',
    ReasoningEffort.high: '高',
  };

  /// 采样参数是否已被改过（未改 = 用服务端默认）
  bool get _samplingTouched =>
      !(sampling.untouched &&
          sampling.maxTokens == null &&
          sampling.seed == null);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: context.trae.bg,
          border: Border(top: BorderSide(color: context.trae.line)),
        ),
        padding: const EdgeInsets.fromLTRB(
            TraeTokens.gapLg, TraeTokens.gapSm, TraeTokens.gapLg, TraeTokens.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 状态行：一行灰字（webUI composer-hint 的位置与作用）。
            // 不再是一排胶囊——胶囊移到「采样与思考」抽屉内。
            _ComposerStatusLine(
              effortLabel: _effortLabels[effort]!,
              samplingTouched: _samplingTouched,
            ),
            // 附件栏（有附件才出现）
            if (files.isNotEmpty || images.isNotEmpty) ...[
              const SizedBox(height: TraeTokens.gapSm),
              _AttachmentRow(
                files: files,
                images: images,
                onRemoveFile: onRemoveFile,
                onRemoveImage: onRemoveImage,
              ),
            ],
            const SizedBox(height: TraeTokens.gapSm),
            Container(
              decoration: BoxDecoration(
                color: context.trae.surface2,
                borderRadius: BorderRadius.circular(TraeTokens.radiusXl),
              ),
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: TraeTokens.gapSm, vertical: 6),
                    child: TextField(
                      key: const Key('field_input'),
                      controller: controller,
                      enabled: !busy,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => onSend(),
                      style: TraeText.body(context),
                      decoration: const InputDecoration(
                        hintText: '说点什么…',
                        isDense: true,
                        filled: false,
                        contentPadding: EdgeInsets.zero,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                      ),
                    ),
                  ),
                  // 底栏：左侧功能键（附件 / 新会话 / 导出 / 采样与思考）+ 右侧发送
                  Padding(
                    padding: const EdgeInsets.only(left: 2, right: 2, top: 2),
                    child: Row(
                      children: [
                        _RoundIconButton(
                          key: const Key('btn_attach'),
                          icon: Icons.add,
                          label: '添加附件',
                          onTap: busy ? null : onPickAttachments,
                        ),
                        _RoundIconButton(
                          key: const Key('btn_new_chat'),
                          icon: Icons.chat_bubble_outline,
                          label: '新会话',
                          onTap: busy ? null : onNewChat,
                        ),
                        _RoundIconButton(
                          key: const Key('btn_export_md'),
                          icon: Icons.download_outlined,
                          label: '导出当前会话（Markdown）',
                          onTap: busy ? null : onExportMarkdown,
                        ),
                        _RoundIconButton(
                          key: const Key('btn_sampling'),
                          icon: Icons.tune,
                          label: '采样与思考',
                          onTap: busy
                              ? null
                              : () => _openSamplingSheet(
                                  context, sampling, effort, onEffortChanged,
                                  onSamplingChanged),
                        ),
                        const Spacer(),
                        _SendButton(busy: busy, onSend: onSend, onStop: onStop),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「采样与思考」抽屉（v0.0.9：与 webUI 同构，单一抽屉含思考档位 + 采样参数）
  void _openSamplingSheet(
    BuildContext context,
    SamplingParams current,
    ReasoningEffort currentEffort,
    ValueChanged<ReasoningEffort> onEffortChanged,
    ValueChanged<SamplingParams> onChanged,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true, // 键盘弹起时 sheet 上移
      backgroundColor: context.trae.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
            top: Radius.circular(TraeTokens.radiusXl)),
      ),
      builder: (sheetContext) => _SamplingSheet(
        initial: current,
        initialEffort: currentEffort,
        onEffortChanged: onEffortChanged,
        onApply: onChanged,
      ),
    );
  }
}

/// Composer 上方的状态行（webUI `composer-hint` 同位同作用）
///
/// 【v0.0.9】取代原先「思考 + 关闭/低/中/高 + 采样」的一排胶囊。
/// 现在只显示**当前状态**（一行灰字），交互入口统一收进「采样与思考」抽屉。
class _ComposerStatusLine extends StatelessWidget {
  const _ComposerStatusLine({
    required this.effortLabel,
    required this.samplingTouched,
  });

  final String effortLabel;
  final bool samplingTouched;

  @override
  Widget build(BuildContext context) {
    final parts = <String>['思考 $effortLabel'];
    if (samplingTouched) parts.add('采样已调整');
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 2),
      child: Row(
        children: [
          Icon(Icons.tune, size: 13, color: context.trae.muted),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              parts.join(' · '),
              key: const Key('composer_status'),
              style: TextStyle(fontSize: 11.5, color: context.trae.muted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// 附件 chips 行：文件 chip 带删除；图片缩略 chip 带删除
class _AttachmentRow extends StatelessWidget {
  const _AttachmentRow({
    required this.files,
    required this.images,
    required this.onRemoveFile,
    required this.onRemoveImage,
  });

  final List<AttachedTextFile> files;
  final List<PickedImage> images;
  final ValueChanged<AttachedTextFile> onRemoveFile;
  final ValueChanged<PickedImage> onRemoveImage;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30, // web .chip 高度口径
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final f in files)
            Padding(
              padding: const EdgeInsets.only(right: TraeTokens.gapSm),
              child: _AttachmentChip(
                key: ValueKey('attach_file_${f.name}'),
                icon: Icons.description_outlined,
                label: f.name,
                onRemove: () => onRemoveFile(f),
              ),
            ),
          for (final im in images)
            Padding(
              padding: const EdgeInsets.only(right: TraeTokens.gapSm),
              child: _AttachmentChip(
                key: ValueKey('attach_image_${im.name}'),
                icon: Icons.image_outlined,
                label: im.name,
                onRemove: () => onRemoveImage(im),
              ),
            ),
        ],
      ),
    );
  }
}

/// 单个附件 chip：图标 + 文件名 + 删除（对齐 web .chip 30px surface2 line pill）
class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onRemove,
  });

  final IconData icon;
  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: context.trae.surface2,
        borderRadius: BorderRadius.circular(TraeTokens.radiusPill),
        border: Border.all(color: context.trae.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: context.trae.muted),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: context.trae.inkSoft),
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(10),
            child: Icon(Icons.close, size: 13, color: context.trae.muted),
          ),
        ],
      ),
    );
  }
}

/// 「采样与思考」抽屉（v0.0.9）：思考四档 + 三滑杆 + max/seed 输入 + Reset/Apply
///
/// 【v0.0.9 结构变更】原先 App 把「思考四档」做成输入栏上方的一排胶囊，
/// 把「采样参数」做成另一个抽屉——两者被拆散了。webUI 的 Sampling 抽屉
/// （strata_ref/serve/web/index.html:213-262）是**同一个抽屉里**
/// 先 Thinking 四档（role=radiogroup，data-v=none/low/medium/high），
/// 再 temperature / top_p / top_k 滑杆 + max tokens / seed 输入。
/// 思考强度本质上就是生成参数，拆成两处只会让用户来回找。
/// 现在完全对齐：单抽屉、单 Apply、单 Reset。
class _SamplingSheet extends StatefulWidget {
  const _SamplingSheet({
    required this.initial,
    required this.initialEffort,
    required this.onEffortChanged,
    required this.onApply,
  });

  final SamplingParams initial;
  final ReasoningEffort initialEffort;
  final ValueChanged<ReasoningEffort> onEffortChanged;
  final ValueChanged<SamplingParams> onApply;

  @override
  State<_SamplingSheet> createState() => _SamplingSheetState();
}

class _SamplingSheetState extends State<_SamplingSheet> {
  late ReasoningEffort _effort;
  late double _temp;
  late double _topP;
  late int _topK;
  late final TextEditingController _maxTokens;
  late final TextEditingController _seed;

  static const _effortLabels = {
    ReasoningEffort.none: '关闭',
    ReasoningEffort.low: '低',
    ReasoningEffort.medium: '中',
    ReasoningEffort.high: '高',
  };

  @override
  void initState() {
    super.initState();
    _effort = widget.initialEffort;
    _temp = widget.initial.temperature;
    _topP = widget.initial.topP;
    _topK = widget.initial.topK;
    _maxTokens = TextEditingController(
        text: widget.initial.maxTokens?.toString() ?? '');
    _seed = TextEditingController(text: widget.initial.seed?.toString() ?? '');
  }

  @override
  void dispose() {
    _maxTokens.dispose();
    _seed.dispose();
    super.dispose();
  }

  void _reset() => setState(() {
        _effort = ReasoningEffort.none;
        _temp = SamplingParams.defaults.temperature;
        _topP = SamplingParams.defaults.topP;
        _topK = SamplingParams.defaults.topK;
        _maxTokens.clear();
        _seed.clear();
      });

  void _apply() {
    // 思考档位即时生效（与旧实现的胶囊点击语义一致：点档位立刻改状态），
    // 采样参数则等 Apply 才落 setSampling（滑杆草稿语义）。
    if (_effort != widget.initialEffort) {
      widget.onEffortChanged(_effort);
    }
    final maxTokens = int.tryParse(_maxTokens.text.trim());
    final seed = int.tryParse(_seed.text.trim());
    widget.onApply(SamplingParams(
      temperature: _temp,
      topP: _topP,
      topK: _topK,
      maxTokens: maxTokens,
      seed: seed,
    ));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom), // 键盘避让
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(TraeTokens.gapLg, TraeTokens.gapLg,
              TraeTokens.gapLg, TraeTokens.gapLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('采样与思考', style: TraeText.sectionTitle(context)),
              const SizedBox(height: TraeTokens.gapXs),
              Text(
                '默认值不随请求发送，服务端将使用自身默认；恢复默认即清除。',
                style: TraeText.meta(context),
              ),
              const SizedBox(height: TraeTokens.gapMd),

              // ── 思考强度（webUI #s-thinking radiogroup）──────────────
              Text('思考强度', style: TraeText.meta(context)),
              const SizedBox(height: TraeTokens.gapSm),
              Row(
                children: [
                  for (final e in ReasoningEffort.values)
                    Padding(
                      padding: const EdgeInsets.only(right: TraeTokens.gapSm),
                      child: TraeWidgets.chip(
                        context,
                        _effortLabels[e]!,
                        key: Key('effort_${e.name}'),
                        selected: _effort == e,
                        onTap: () => setState(() => _effort = e),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: TraeTokens.gapMd),
              const Divider(height: 1),
              const SizedBox(height: TraeTokens.gapMd),

              _SamplingSlider(
                label: 'temperature',
                value: _temp,
                min: SamplingParams.temperatureMin,
                max: SamplingParams.temperatureMax,
                divisions: 30, // 0-1.5 步长 0.05（web 口径）
                display: _temp.toStringAsFixed(2),
                onChanged: (v) => setState(() => _temp = v),
              ),
              _SamplingSlider(
                label: 'top_p',
                value: _topP,
                min: SamplingParams.topPMin,
                max: SamplingParams.topPMax,
                divisions: 19, // 0.05-1 步长 0.05
                display: _topP.toStringAsFixed(2),
                onChanged: (v) => setState(() => _topP = v),
              ),
              _SamplingSlider(
                label: 'top_k',
                value: _topK.toDouble(),
                min: SamplingParams.topKMin.toDouble(),
                max: SamplingParams.topKMax.toDouble(),
                divisions: SamplingParams.topKMax - SamplingParams.topKMin,
                display: '$_topK',
                onChanged: (v) => setState(() => _topK = v.round()),
              ),
              _SamplingField(
                label: 'max_tokens',
                controller: _maxTokens,
                hint: '不限制',
              ),
              _SamplingField(
                label: 'seed',
                controller: _seed,
                hint: '随机',
              ),
              const SizedBox(height: TraeTokens.gapMd),
              Row(
                children: [
                  TextButton(
                    key: const Key('sampling_reset'),
                    onPressed: _reset,
                    child: const Text('恢复默认'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: TraeTokens.gapSm),
                  FilledButton(
                    key: const Key('sampling_apply'),
                    onPressed: _apply,
                    child: const Text('应用'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 采样抽屉内单条滑杆行：label + 当前值 + Slider
class _SamplingSlider extends StatelessWidget {
  const _SamplingSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 96,
              child: Text(label, style: TraeText.meta(context)),
            ),
            Text(display,
                style: TraeText.meta(context)
                    .copyWith(fontFeatures: [FontFeature.tabularFigures()])),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            overlayColor: context.trae.accentTint,
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

/// 采样抽屉内数字输入行：label + TextField（max_tokens / seed）
class _SamplingField extends StatelessWidget {
  const _SamplingField({
    required this.label,
    required this.controller,
    required this.hint,
  });

  final String label;
  final TextEditingController controller;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: TraeTokens.gapSm),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: TraeText.meta(context)),
            // meta 样式
          ),
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: TraeText.body(context),
              decoration: InputDecoration(
                hintText: hint,
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: context.trae.line),
                  borderRadius: BorderRadius.circular(TraeTokens.radiusSm),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: context.trae.accent),
                  borderRadius: BorderRadius.circular(TraeTokens.radiusSm),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      label: label,
      button: true,
      enabled: enabled,
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(
            icon,
            size: 20,
            color: enabled ? context.trae.inkSoft : context.trae.muted,
          ),
        ),
      ),
    );
  }
}

/// 发送 / 停止键：紫色圆形实心（忙碌变停止键，M2-5 接 stop()）
class _SendButton extends StatelessWidget {
  const _SendButton({required this.busy, required this.onSend, required this.onStop});

  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: busy ? '停止' : '发送',
      button: true,
      child: Material(
        color: busy ? context.trae.muted : context.trae.accent,
        shape: const CircleBorder(),
        child: InkWell(
          key: const Key('btn_send'),
          onTap: busy ? onStop : onSend,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(
              busy ? Icons.stop_rounded : Icons.arrow_upward_rounded,
              size: 20,
              color: context.trae.accentInk,
            ),
          ),
        ),
      ),
    );
  }
}

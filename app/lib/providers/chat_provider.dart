// 对话状态 Provider（M1-6 建立，M1-12 写穿改造）：
// - 消息列表 + 发送阶段（waitingFirstToken=「正在思考」/ streaming / idle）
// - 思考强度档位（none/low/medium/high，随每条消息发送——非全局引擎状态）
// - 流式错误分型落消息（流中断不自动重发，SPEC §6.1.3，用户可手动再发）
// - 会话写穿（ADR-9 决策 2）：发送时 insert（拿 DB id 进 UI）、流式中纯内存
//   渲染、流结束/失败一次 update 写回 + touch
//
// 健壮性：本地 DB 写入失败时降级纯内存聊天（该轮不落库但不阻断对话），
// 存储故障不影响核心功能；会话按 Profile 隔离，切换主机自动开新会话。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat_models.dart';
import '../models/conversation.dart';
import '../models/strata_models.dart';
import '../services/attachment_service.dart' show userText;
import '../services/conversation_repository.dart';
import '../services/export_service.dart';
import '../services/image_store.dart';
import '../services/strata_client.dart';
import 'connection_provider.dart';

/// 会话仓库（App 生命周期单例；openAppDatabase 内部缓存连接，测试可注入内存库）
final conversationRepositoryProvider =
    Provider<ConversationRepository>((_) => ConversationRepository());

/// 图片落盘服务（v0.0.10：图片路径 ↔ dataURL 的持久化层）
final imageStoreProvider = Provider<ImageStore>((_) => ImageStore());

/// 导出服务（v0.0.10：注入图片解析器，使 .json 导出内联图片 dataURL）
final exportServiceProvider = Provider<ExportService>((ref) {
  final store = ref.read(imageStoreProvider);
  return ExportService(imageResolver: store.loadAll);
});

/// 会话列表（抽屉数据源；置顶优先 + updatedAt 倒序已由 SQL 保证）。
/// 写穿创建会话 / 抽屉操作（置顶·重命名·删除）/ 导入后 invalidate 刷新。
final conversationsProvider = FutureProvider<List<Conversation>>((ref) {
  return ref.watch(conversationRepositoryProvider).listConversations();
});

/// 各会话消息数（抽屉副行「时间 · N 条消息」）
final messageCountsProvider = FutureProvider<Map<String, int>>((ref) {
  return ref.watch(conversationRepositoryProvider).countMessagesGrouped();
});

/// 发送阶段（长 TTFT 场景区分「正在思考」与断线，SPEC §6.1.2）
enum ChatSendPhase {
  /// 空闲：输入框可发送
  idle,

  /// 已发出、未收到任何 delta：UI 显示「正在思考…」（长 prompt 分钟级属正常）
  waitingFirstToken,

  /// 收到首个 delta：流式渲染中
  streaming,
}

class ChatState {
  const ChatState({
    this.messages = const [],
    this.phase = ChatSendPhase.idle,
    this.effort = ReasoningEffort.medium,
    this.conversation,
    this.sampling = SamplingParams.defaults,
  });

  final List<UiChatMessage> messages;
  final ChatSendPhase phase;

  /// 当前思考强度档位（随下一条消息发送）
  final ReasoningEffort effort;

  /// 采样参数（M2-5 采样抽屉，随下一条消息发送；untouched 字段不进请求体）
  final SamplingParams sampling;

  /// 当前会话（M1-12）。null = 新会话尚未落库，首条消息发送时创建。
  /// 导出入口（顶栏 ⋯）依赖此对象取 title/model/effort/createdAt 元信息。
  /// 重置回新会话经 [ChatController.newConversation] / [loadConversation]
  /// 全量构造 state，不走 copyWith（copyWith 的 null 语义无法清空）。
  final Conversation? conversation;

  String? get conversationId => conversation?.id;

  ChatState copyWith({
    List<UiChatMessage>? messages,
    ChatSendPhase? phase,
    ReasoningEffort? effort,
    Conversation? conversation,
    SamplingParams? sampling,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        phase: phase ?? this.phase,
        effort: effort ?? this.effort,
        conversation: conversation ?? this.conversation,
        sampling: sampling ?? this.sampling,
      );
}

class ChatController extends Notifier<ChatState> {
  /// 正在流式渲染的助手消息 DB 行（null = DB 降级模式或无进行中的流，
  /// 流结束时跳过写回）
  ConversationMessage? _pendingAiRow;

  StreamSubscription<ChatStreamEvent>? _sub;

  // ---- M2-5 流计时（墙钟，web 端同口径）----
  /// 首个 delta（reasoning 或 content）到达时刻；null = 尚无任何 delta
  DateTime? _firstAt;

  /// 首个 reasoning delta 到达时刻（thinkSecs 起点）
  DateTime? _thinkStart;

  /// [stop] 置位：流被 onDone 收尾时按停止口径落 meta（web m.stopped 同义）
  bool _stopRequested = false;

  @override
  ChatState build() {
    // 会话按 Profile 隔离（SPEC §9）：切换主机后旧上下文对新主机无意义，
    // 自动重置为新会话（流式中同样取消，避免跨主机续写）
    ref.listen(currentProfileProvider, (previous, next) {
      if (previous?.id != next?.id) newConversation();
    });
    return const ChatState();
  }

  void setEffort(ReasoningEffort e) => state = state.copyWith(effort: e);

  /// 更新采样参数（M2-5 采样抽屉 Apply 落库点）
  void setSampling(SamplingParams s) =>
      state = state.copyWith(sampling: s);

  /// 停止当前流（M2-5，web stop-btn 口径）：保留已生成文本，最后一条 AI
  /// 消息标 stopped，不清 error/usage 已有值。流未开始（waitingFirstToken
  /// 阶段）同样可停。
  void stop() {
    if (state.phase == ChatSendPhase.idle) return;
    _stopRequested = true;
    _sub?.cancel();
    _sub = null;
    _finishStopped();
  }

  /// 开新会话（抽屉「新建」入口 / 切换 Profile）：清空上下文回到未落库态
  void newConversation() {
    _sub?.cancel();
    _sub = null;
    _pendingAiRow = null;
    _resetStreamTimers();
    state = const ChatState();
  }

  /// 加载历史会话（抽屉点选）：还原消息列表与该会话创建时的思考档位
  ///
  /// v0.0.10：消息里的图片路径（DB images_json）会读回为 dataURL，
  /// 使"发送带图的对话再次打开看不到图"的反馈闭环。
  Future<void> loadConversation(Conversation c) async {
    _sub?.cancel();
    _sub = null;
    _pendingAiRow = null;
    _resetStreamTimers();
    final rows =
        await ref.read(conversationRepositoryProvider).loadMessages(c.id);
    final store = ref.read(imageStoreProvider);
    final messages = <UiChatMessage>[];
    for (final r in rows) {
      final ui = r.toUi();
      if (ui.imageUrls.isEmpty) {
        messages.add(ui);
        continue;
      }
      final loaded = await store.loadAll(ui.imageUrls);
      messages.add(ui.copyWith(imageUrls: loaded.where((s) => s.isNotEmpty).toList()));
    }
    state = ChatState(
      messages: messages,
      effort: _effortFromWireName(c.effort),
      conversation: c,
    );
  }

  /// 发送消息并流式接收（幂等：非 idle / 空 payload 直接忽略）。
  ///
  /// [files] 文本附件（M2-5）：以围栏代码块拼进 prompt（与 web userText 同构）；
  /// [images] 图片 dataURL（M2-5）：进 content 数组的 image_url 段（仅当前轮，
  /// 历史回传由内存 imageUrls 携带）。两者与正文共同决定可发送性。
  Future<void> send(
    String text, {
    List<AttachedTextFile> files = const [],
    List<String> images = const [],
  }) async {
    // 空发送守卫：正文纯空白且无附件 → 直接忽略（web send() 对
    // input.trim() 空即 return 的口径；附件在身时正文可为空）
    final prompt = userText(text.trim(), files);
    if (state.phase != ChatSendPhase.idle ||
        (prompt.isEmpty && images.isEmpty)) {
      return;
    }

    final client = ref.read(strataClientProvider);

    // 请求历史：已有消息中排除失败项（失败消息未成功送达，不参与上下文）
    //
    // 【M1-11 修复】助手的思考内容必须随历史回传：Strata 的 chat template 期望
    // assistant 回合为 {content, reasoning_content}（见 serve/chat_golden.json
    // "assistant with thinking" 用例）。只回传 content 会让模型看不到自己上轮的
    // 推理，续接上下文时可能产出退化/占位式回答。
    //
    // 图片历史回传（M2-5，web apiMessages 同口径）：历史 user 消息带图走
    // content 数组；图片仅存内存态，从 DB 重载的历史自然无图。
    final history = <ChatMessageRequest>[
      for (final m in state.messages.where((m) => m.error == null))
        ChatMessageRequest(
          role: m.isUser ? 'user' : 'assistant',
          content: m.content,
          reasoningContent: m.isUser ? null : m.reasoning,
          imageUrls: m.isUser ? m.imageUrls : const [],
        ),
      ChatMessageRequest(role: 'user', content: prompt, imageUrls: images),
    ];

    // 先占位防重入：下方 DB 写穿有 await，期间二次点发送会串会话
    state = state.copyWith(phase: ChatSendPhase.waitingFirstToken);

    // ---------- M1-12 写穿：发送时落库拿 DB id（ADR-9 决策 2）----------
    final now = DateTime.now();
    final seq = state.messages.length;
    try {
      final repo = ref.read(conversationRepositoryProvider);
      var conversation = state.conversation;
      if (conversation == null) {
        // 首条消息：创建会话（标题取首句摘要，档位取当前值）
        conversation = Conversation(
          id: newConversationId(),
          title: conversationTitleFrom(prompt),
          profileId: ref.read(currentProfileProvider)?.id ?? 'default',
          effort: state.effort.wireName,
          createdAt: now,
          updatedAt: now,
        );
        await repo.createConversation(conversation);
      }
      // v0.0.10：图片先落盘，DB 只存路径（dataURL 入库会撑爆 SQLite）
      final storedPaths = <String>[];
      if (images.isNotEmpty) {
        final store = ref.read(imageStoreProvider);
        final paths = await store.persistAll(
            conversationId: conversation.id, seq: seq, dataUrls: images);
        storedPaths.addAll(paths.whereType<String>());
      }
      final userRow = await repo.insertMessage(ConversationMessage(
        conversationId: conversation.id,
        role: 'user',
        content: prompt,
        timestamp: now,
        seq: seq,
        imageUrls: storedPaths,
      ));
      final aiRow = await repo.insertMessage(ConversationMessage(
        conversationId: conversation.id,
        role: 'assistant',
        content: '',
        timestamp: now,
        seq: seq + 1,
      ));
      _pendingAiRow = aiRow;
      if (state.conversation == null) {
        // 新会话首条消息：刷新抽屉列表与消息计数
        _refreshConversationList();
      }
      state = state.copyWith(
        conversation: conversation,
        messages: [
          ...state.messages,
          // 内存态仍是 dataURL（立即可渲染），DB 侧存的是落盘路径
          userRow.toUi().copyWith(imageUrls: images),
          aiRow.toUi(),
        ],
      );
    } on Object {
      // 本地 DB 故障降级：纯内存渲染继续对话（该轮不落库；若会话行已创建
      // 可能残留空会话，抽屉中可手动删除——发生概率极低，不做补偿事务）
      _pendingAiRow = null;
      final nextId = (state.messages.lastOrNull?.id ?? 0) + 1;
      state = state.copyWith(
        messages: [
          ...state.messages,
          UiChatMessage(
              id: nextId,
              isUser: true,
              content: prompt,
              timestamp: now,
              imageUrls: images),
          UiChatMessage(id: nextId + 1, isUser: false, timestamp: now),
        ],
      );
    }

    // 新流计时清零（防上一轮残留）
    _resetStreamTimers();

    _sub = client
        .chatStream(
            messages: history, effort: state.effort, sampling: state.sampling)
        .listen(
          (event) => switch (event) {
            ReasoningDeltaEvent() => _appendAi(reasoning: event.text),
            ContentDeltaEvent() => _appendAi(content: event.text),
            FinishedEvent() => _finish(event.usage, event.diagnostics),
          },
          onError: (Object e) => _fail(e is StrataException
              ? describeStrataError(e)
              : '未知错误：$e'),
          // 兜底：正常路径 _finish 已置 idle；error 后 onDone 到达时保持错误态
          onDone: () {
            if (state.phase != ChatSendPhase.idle) _finish(null);
          },
          cancelOnError: true,
        );
  }

  void _appendAi({String? content, String? reasoning}) {
    // 【v0.0.3 修复】copyWith 是替换语义，此处必须显式拼接旧值：
    // 修复前每个 delta 覆盖 content，流结束只剩最后一个 chunk
    // （v0.0.1/v0.0.2 内测「只显示最后一个标点符号」的根因）
    //
    // M2-5 计时（web 同口径）：_firstAt = 首个 reasoning 或 content delta；
    // _thinkStart = 首个 reasoning delta；首个 content delta 结算 thinkSecs
    // （被停且无正文时流结束在 _finish/_finishStopped 补算）。
    final now = DateTime.now();
    _firstAt ??= now;
    if (reasoning != null) _thinkStart ??= now;
    _updateLastAi((m) => m.copyWith(
          content: content == null ? null : m.content + content,
          reasoning: reasoning == null ? null : (m.reasoning ?? '') + reasoning,
          thinkSecs: content == null || m.thinkSecs != null || _thinkStart == null
              ? null
              : now.difference(_thinkStart!).inMilliseconds / 1000,
        ));
    if (state.phase == ChatSendPhase.waitingFirstToken) {
      state = state.copyWith(phase: ChatSendPhase.streaming);
    }
  }

  void _finish(ChatUsage? usage, [SseDiagnostics? diagnostics]) {
    // 【M1-11】流结束却一个 chunk 都没解析到 → 明确报错，不再静默显示空白。
    // 这是 v0.0.1 内测「无内容且无报错」的兜底防线。
    if (diagnostics != null && diagnostics.gotNothing) {
      _fail('未收到任何可解析的响应数据（服务端可能未返回该模型，或响应格式与预期不符）');
      return;
    }
    final now = DateTime.now();
    final stopped = _stopRequested;
    // genSecs = 首个 delta → 流结束墙钟差（tok/s 分母）；无 delta 时 null
    final genSecs = _firstAt == null
        ? null
        : now.difference(_firstAt!).inMilliseconds / 1000;
    _updateLastAi((m) => m.copyWith(
          usage: usage,
          stopped: stopped,
          genSecs: genSecs,
          // 被停且无正文：思考耗时在流结束补算
          thinkSecs: m.thinkSecs ??
              (stopped && m.content.isEmpty && _thinkStart != null
                  ? now.difference(_thinkStart!).inMilliseconds / 1000
                  : null),
        ));
    _stopRequested = false;
    // 同步捕获终态再异步落库：避免 await 期间用户已发下一条导致写错对象
    final last = state.messages.last;
    state = state.copyWith(phase: ChatSendPhase.idle);
    unawaited(_persistFinal(last));
  }

  /// 用户主动停止的收尾（stop() 调用，无 FinishedEvent）：
  /// 标 stopped、保留已生成文本（usage 保持 null——服务端不给尾包）
  void _finishStopped() {
    final now = DateTime.now();
    final genSecs = _firstAt == null
        ? null
        : now.difference(_firstAt!).inMilliseconds / 1000;
    _updateLastAi((m) => m.copyWith(
          stopped: true,
          genSecs: genSecs,
          thinkSecs: m.thinkSecs ??
              (m.content.isEmpty && _thinkStart != null
                  ? now.difference(_thinkStart!).inMilliseconds / 1000
                  : null),
        ));
    _stopRequested = false;
    final last = state.messages.last;
    state = state.copyWith(phase: ChatSendPhase.idle);
    unawaited(_persistFinal(last));
  }

  void _fail(String message) {
    _updateLastAi((m) => m.copyWith(error: message));
    final last = state.messages.last;
    state = state.copyWith(phase: ChatSendPhase.idle);
    unawaited(_persistFinal(last));
  }

  void _resetStreamTimers() {
    _firstAt = null;
    _thinkStart = null;
    _stopRequested = false;
  }

  /// 流结束态一次写回 DB（ADR-9：流式中不逐 delta 落库，避免写放大）。
  /// 本地写回失败静默忽略——UI 已呈现终态，不因存储问题回滚展示。
  Future<void> _persistFinal(UiChatMessage last) async {
    final row = _pendingAiRow;
    _pendingAiRow = null;
    if (row == null) return;
    try {
      final repo = ref.read(conversationRepositoryProvider);
      await repo.updateMessage(ConversationMessage(
        id: row.id,
        conversationId: row.conversationId,
        role: row.role,
        content: last.content,
        reasoning: last.reasoning,
        usage: last.usage,
        error: last.error,
        stopped: last.stopped,
        timestamp: last.timestamp ?? row.timestamp,
        seq: row.seq,
      ));
      await repo.touchConversation(row.conversationId);
      _refreshConversationList(); // updatedAt 变化影响抽屉排序
    } on Object {
      // 忽略：本地写回失败不影响已渲染的终态
    }
  }

  /// 刷新抽屉数据源（会话列表 + 消息计数）
  void _refreshConversationList() {
    ref.invalidate(conversationsProvider);
    ref.invalidate(messageCountsProvider);
  }

  void _updateLastAi(UiChatMessage Function(UiChatMessage) f) {
    final msgs = [...state.messages];
    msgs[msgs.length - 1] = f(msgs.last);
    state = state.copyWith(messages: msgs);
  }
}

/// 会话存档的 effort 字符串 → 档位（未知/缺失值回退 medium）
ReasoningEffort _effortFromWireName(String? s) => switch (s) {
      'none' => ReasoningEffort.none,
      'low' => ReasoningEffort.low,
      'high' => ReasoningEffort.high,
      _ => ReasoningEffort.medium,
    };

final chatControllerProvider =
    NotifierProvider<ChatController, ChatState>(ChatController.new);

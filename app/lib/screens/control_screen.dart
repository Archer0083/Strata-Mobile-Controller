// ControlScreen（M2-7.1，2026-10-27 真机反馈修复·缺陷 B）
//
// 【为什么要有这一页】真机反馈原话：
//   「应当不需要在填写一次 api key 和配置主机地址和端口之后还是无法看到和设置
//     主机状态和模型加载卸载等配置动作」
// 上一版「控制」tab 仍是 _PlaceholderPage，Load/Unload 能力被埋在
// 一个 API Monitor 二级页里，而那一页的数据源 apiMonitorProvider 把
// /v1/status 与 /api/requests 绑死：主机未开 svc.api_monitor 时
// /api/requests 返 404 → 整个快照 error → 状态卡连同 Load/Unload 按钮
// 一起消失。用户要的「模型加载卸载」动作反而做不了。
//
// 【v0.0.9】该 API Monitor 二级页已整体删除（它依赖主机端默认关闭的
// svc.api_monitor，打开永远是空页）。Load/Unload 能力全部留在本页。
//
// 【webUI 对应】webUI 的 Monitor 页顶部状态卡就是控制面板：
//   状态标签（Loading…/In use/Loaded/Unloaded）+ 模型名 + Load/Unload 按钮。
//   App 把它提升为一级 tab「控制」，保证动作入口不被请求记录开关牵连。
//
// 【本页职责】
//   1. 引擎状态卡：状态标签 + 模型名 + Load/Unload（operating 锁、inflight 屏蔽）
//   2. 引擎属性卡：/props 只读（量化档位等主机 setup 时设定的属性）
//   3. API Key 卡：401 态就地补 key（与 About / 监控页同一套闭环）
//
// 数据源：engineControlProvider（只依赖 /v1/status，不受 api_monitor 开关影响）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/api_models.dart';
import '../providers/api_monitor_provider.dart';
import '../providers/connection_provider.dart';
import '../providers/engine_config_provider.dart';
import '../providers/installed_models_provider.dart';
import '../services/strata_client.dart';
import '../theme/trae_theme.dart';
import '../widgets/api_key_card.dart';
import 'home_shell.dart';

class ControlScreen extends ConsumerStatefulWidget {
  const ControlScreen({super.key});

  @override
  ConsumerState<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends ConsumerState<ControlScreen>
    with WidgetsBindingObserver {
  EngineControlPolling? _polling;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.detached) {
        _polling = ref.read(engineControlProvider.notifier);
        _polling!.activate();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    final n = ref.read(engineControlProvider.notifier);
    if (state == AppLifecycleState.resumed) {
      n.activate();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      n.deactivate();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _polling?.deactivate();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(engineControlProvider);

    return Scaffold(
      backgroundColor: context.trae.bg,
      appBar: AppBar(
        titleSpacing: TraeTokens.gapLg,
        title: Text('控制', style: TraeText.pageTitle(context)),
        actions: [
          IconButton(
            key: const Key('btn_ctrl_refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            color: context.trae.inkSoft,
            onPressed: () => ref.read(engineControlProvider.notifier).refresh(),
          ),
          const TopNavEntries(exclude: TopNav.control),
          const SizedBox(width: TraeTokens.gapSm),
        ],
      ),
      body: snap.when(
        skipLoadingOnRefresh: true,
        skipLoadingOnReload: true,
        skipError: true,
        loading: () => const Center(
          child: CircularProgressIndicator(key: Key('ctrl_loading')),
        ),
        error: (e, _) => _ControlErrorView(error: e),
        data: (s) => RefreshIndicator(
          onRefresh: () => ref.read(engineControlProvider.notifier).refresh(),
          child: _ControlBody(snapshot: s),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 错误/空态：401 → 就地补 key；断连 → 重试提示
// ─────────────────────────────────────────────────────────────

class _ControlErrorView extends ConsumerWidget {
  const _ControlErrorView({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 【v0.0.9】未建立连接：不再走「连接失败：…」的通用报错，
    // 而是给一条明确的行动指引（去「设置」里建立/激活 Profile）。
    // 此前 engineControlProvider.build() 直接 watch strataClientProvider，
    // 在无 Profile 时会**同步抛** StateError → 异常冒泡成未捕获 widget 异常，
    // 本页崩成红屏。现已在 provider 侧兜住，这里只做友好分型。
    if (error is StateError) {
      return Center(
        key: const Key('ctrl_no_connection'),
        child: Padding(
          padding: const EdgeInsets.all(TraeTokens.gapXl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.link_off, size: 40, color: context.trae.muted),
              const SizedBox(height: TraeTokens.gapMd),
              Text('尚未建立连接',
                  style: TraeText.sectionTitle(context),
                  textAlign: TextAlign.center),
              const SizedBox(height: TraeTokens.gapSm),
              Text('请先在「设置」中保存并激活主机地址、端口与 API Key，\n'
                  '即可在此查看引擎状态并加载/卸载模型。',
                  style: TraeText.meta(context),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    // 401：主机要求 API Key。故障态必须自带修复入口——否则用户在控制页
    // 看不到 Load/Unload 又找不到填 key 的地方，只能退出 App 重来。
    if (error is StrataUnauthorizedException) {
      return ListView(
        key: const Key('ctrl_unauthorized'),
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        children: [
          const _ErrorBanner(
            icon: Icons.key,
            title: '需要 API Key',
            hint: '主机要求 API Key，请在下方填入并保存，无需返回上页即可操作模型。',
            warnIcon: true,
          ),
          const SizedBox(height: TraeTokens.gapLg),
          ApiKeyCard(
            hint: '保存后本页的引擎状态与 Load/Unload 按钮会立即生效。',
            onSaved: () {
              // 保存 key → Profile 重建 → client 重建 → 本页状态需立刻重拉。
              // 不刷新的话用户会看到「保存了 key 但状态还是 401」（真机反馈原话：
              // 「填写一次 api key …之后还是无法看到主机状态」）。
              ref.invalidate(enginePropsProvider);
              ref.read(engineControlProvider.notifier).refresh();
            },
          ),
          const SizedBox(height: TraeTokens.gapLg),
        ],
      );
    }

    final offline = error is StrataConnectionException;
    return Center(
      key: const Key('ctrl_error'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 40, color: context.trae.muted),
            const SizedBox(height: TraeTokens.gapMd),
            Text(
              offline
                  ? '主机不可达'
                  : '连接失败：${describeStrataError(error as StrataException)}',
              style: TraeText.sectionTitle(context),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: TraeTokens.gapSm),
            Text('请在「设置」中确认主机地址、端口与 API Key。',
                style: TraeText.meta(context), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({
    required this.icon,
    required this.title,
    required this.hint,
    this.warnIcon = false,
  });

  final IconData icon;
  final String title;
  final String hint;
  final bool warnIcon;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 20, color: warnIcon ? context.trae.warn : context.trae.muted),
            const SizedBox(width: TraeTokens.gapSm),
            Flexible(child: Text(title, style: TraeText.sectionTitle(context))),
          ],
        ),
        const SizedBox(height: TraeTokens.gapSm),
        Text(hint, style: TraeText.meta(context), textAlign: TextAlign.center),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 主体
// ─────────────────────────────────────────────────────────────

class _ControlBody extends StatelessWidget {
  const _ControlBody({required this.snapshot});

  final EngineControlSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const Key('ctrl_body'),
      padding: const EdgeInsets.all(TraeTokens.gapLg),
      children: [
        _EngineStateCard(snapshot: snapshot),
        const SizedBox(height: TraeTokens.gapMd),
        const _InstalledModelsCard(),
        const SizedBox(height: TraeTokens.gapMd),
        const _ContextLengthCard(),
        const SizedBox(height: TraeTokens.gapMd),
        const _EnginePropsCard(),
        const SizedBox(height: TraeTokens.gapMd),
        const ApiKeyCard(),
        const SizedBox(height: TraeTokens.gapXl),
      ],
    );
  }
}

/// 引擎状态卡：状态标签 + 模型名 + Load/Unload
/// 按钮可用性口径与 webUI control() 一致：operating 锁 + inflight 屏蔽。
class _EngineStateCard extends ConsumerWidget {
  const _EngineStateCard({required this.snapshot});

  final EngineControlSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(engineControlProvider.notifier);
    final status = snapshot.status;
    final busy = n.operating || (status.inFlight ?? 0) > 0;

    return Card(
      key: const Key('ctrl_state_card'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        status.stateLabel,
                        key: const Key('ctrl_state_label'),
                        style: TraeText.sectionTitle(context),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        status.model ?? '—',
                        key: const Key('ctrl_model'),
                        style: TraeText.meta(context),
                      ),
                    ],
                  ),
                ),
                _StateChip(label: status.stateLabel),
              ],
            ),
            const SizedBox(height: TraeTokens.gapMd),
            Row(
              children: [
                FilledButton(
                  key: const Key('btn_ctrl_load'),
                  onPressed: (!snapshot.canLoad || n.operating)
                      ? null
                      : () => _run(context, () => n.load()),
                  child: const Text('加载模型'),
                ),
                const SizedBox(width: TraeTokens.gapMd),
                OutlinedButton(
                  key: const Key('btn_ctrl_unload'),
                  onPressed: (!snapshot.canUnload || n.operating)
                      ? null
                      : () => _confirmUnload(context, ref),
                  child: const Text('卸载模型'),
                ),
                if (n.operating) ...[
                  const SizedBox(width: TraeTokens.gapMd),
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
            const SizedBox(height: TraeTokens.gapSm),
            Text(
              busy
                  ? 'busy 状态下 Load/Unload 不可用'
                  : (status.autoLoad ?? false)
                      ? '主机已开启自动加载：首次请求会自动拉起模型。'
                      : '主机未开启自动加载，可手动加载模型。',
              key: const Key('ctrl_state_hint'),
              style: TraeText.meta(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _run(BuildContext context, Future<void> Function() action) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      messenger.showSnackBar(const SnackBar(
        content: Text('已提交'),
        duration: Duration(seconds: 1),
      ));
    } on StrataException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('操作失败：${describeStrataError(e)}'),
        duration: const Duration(seconds: 4),
      ));
    }
  }

  Future<void> _confirmUnload(BuildContext context, WidgetRef ref) async {
    // server /unload 支持 ?wait=（等待进行中请求完成再卸载）
    // 先取 messenger 再 await，避免跨 async gap 使用 BuildContext
    final messenger = ScaffoldMessenger.of(context);
    var wait = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('卸载模型？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('卸载会停止当前模型，进行中的请求将被断开。'),
              CheckboxListTile(
                key: const Key('btn_ctrl_unload_wait'),
                value: wait,
                onChanged: (v) => setDialogState(() => wait = v ?? false),
                title: const Text('等待进行中的请求完成（最长 120s）'),
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(
              key: const Key('btn_ctrl_unload_cancel'),
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('btn_ctrl_unload_confirm'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('卸载'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await ref
            .read(engineControlProvider.notifier)
            .unload(waitSeconds: wait ? 120 : null);
        messenger.showSnackBar(const SnackBar(
          content: Text('已提交'),
          duration: Duration(seconds: 1),
        ));
      } on StrataException catch (e) {
        messenger.showSnackBar(SnackBar(
          content: Text('操作失败：${describeStrataError(e)}'),
          duration: const Duration(seconds: 4),
        ));
      }
    }
  }
}

/// 已安装模型卡（v0.0.6）
///
/// 回答真机反馈的问题：「主机上可以加载哪些模型」。
/// 数据来自 GET /models/installed（主机安装目录里的运行配置），
/// 而不是 /v1/models（那只列当前服务的一个模型）。
class _InstalledModelsCard extends ConsumerStatefulWidget {
  const _InstalledModelsCard();

  @override
  ConsumerState<_InstalledModelsCard> createState() => _InstalledModelsCardState();
}

class _InstalledModelsCardState extends ConsumerState<_InstalledModelsCard> {
  /// 正在切换的模型 id（切换要重建引擎，耗时较长，需要显式进行态）
  String? _switching;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final installed = ref.watch(installedModelsProvider);

    return Card(
      key: const Key('ctrl_installed_card'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('已安装模型', style: TraeText.sectionTitle(context)),
                ),
                IconButton(
                  key: const Key('btn_ctrl_models_refresh'),
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: '刷新清单',
                  color: context.trae.inkSoft,
                  onPressed: () => ref.invalidate(installedModelsProvider),
                ),
              ],
            ),
            const SizedBox(height: TraeTokens.gapSm),
            installed.when(
              skipLoadingOnRefresh: true,
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: TraeTokens.gapMd),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
              error: (e, _) => _InstalledModelsError(error: e),
              data: (list) => _InstalledModelsBody(
                list: list,
                switching: _switching,
                busy: _busy,
                onSelect: _select,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _select(InstalledModel m) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _switching = m.id;
    });
    try {
      final client = ref.read(strataClientProvider);
      final result = await client.selectModel(m.id);
      messenger.showSnackBar(SnackBar(
        content: Text('已切换到 ${result.model ?? m.name}（引擎已重建，首次请求时加载）'),
        duration: const Duration(seconds: 3),
      ));
      ref.invalidate(installedModelsProvider);
      ref.invalidate(enginePropsProvider);
      await ref.read(engineControlProvider.notifier).refresh();
    } on StrataException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('切换失败：${describeStrataError(e)}'),
        duration: const Duration(seconds: 5),
      ));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _switching = null;
        });
      }
    }
  }
}

class _InstalledModelsBody extends StatelessWidget {
  const _InstalledModelsBody({
    required this.list,
    required this.switching,
    required this.busy,
    required this.onSelect,
  });

  final InstalledModels list;
  final String? switching;
  final bool busy;
  final ValueChanged<InstalledModel> onSelect;

  @override
  Widget build(BuildContext context) {
    if (list.models.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: TraeTokens.gapSm),
        child: Text('主机上没有读到已安装的模型。可在主机侧运行 setup 安装模型后再刷新。',
            key: const Key('ctrl_models_empty'), style: TraeText.meta(context)),
      );
    }

    final dir = list.installDir;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (dir != null && dir.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: TraeTokens.gapSm),
            child: Text('安装目录：$dir',
                key: const Key('ctrl_models_dir'), style: TraeText.meta(context)),
          ),
        for (final m in list.models) ...[
          _InstalledModelTile(
            model: m,
            busy: busy,
            switching: switching == m.id,
            onSelect: () => onSelect(m),
          ),
          const SizedBox(height: TraeTokens.gapSm),
        ],
      ],
    );
  }
}

class _InstalledModelTile extends StatelessWidget {
  const _InstalledModelTile({
    required this.model,
    required this.busy,
    required this.switching,
    required this.onSelect,
  });

  final InstalledModel model;
  final bool busy;
  final bool switching;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final t = context.trae;
    final loadable = model.isLoadable;
    final isCurrent = model.current;

    return Container(
      key: Key('ctrl_model_${model.id}'),
      padding: const EdgeInsets.all(TraeTokens.gapMd),
      decoration: BoxDecoration(
        color: t.surface2,
        borderRadius: BorderRadius.circular(TraeTokens.radiusMd),
        border: Border.all(
          color: isCurrent ? t.accent : t.line,
          width: isCurrent ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(model.name,
                        key: Key('ctrl_model_name_${model.id}'),
                        style: TraeText.body(context)),
                    const SizedBox(height: 2),
                    Text(
                      loadable
                          ? '上下文 ${model.contextLabel}'
                          : '文件不齐全（${model.issueCodes.join('、')}）',
                      style: TraeText.meta(context),
                    ),
                  ],
                ),
              ),
              if (isCurrent)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: t.accentTint,
                    borderRadius: BorderRadius.circular(TraeTokens.radiusPill),
                  ),
                  child: Text('服务中',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: t.accentText)),
                ),
            ],
          ),
          const SizedBox(height: TraeTokens.gapSm),
          Align(
            alignment: Alignment.centerLeft,
            child: isCurrent
                ? Text('当前正在服务这个模型。',
                    style: TraeText.meta(context))
                : OutlinedButton(
                    key: Key('btn_ctrl_select_${model.id}'),
                    onPressed: (busy || !loadable) ? null : onSelect,
                    child: switching
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('加载此模型'),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 已安装模型清单的失败态：区分「主机没升级」与「连不上」
class _InstalledModelsError extends ConsumerWidget {
  const _InstalledModelsError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 404：主机上的 Strata 版本还没有 /models/installed 端点。
    // 这不是用户的错，要说清楚怎么办，而不是显示一个红色错误。
    if (error is StrataNotFoundException) {
      final current = ref.watch(currentModelProvider).valueOrNull;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('当前主机版本没有「已安装模型清单」接口（404）。',
              key: const Key('ctrl_models_404'),
              style: TraeText.body(context)),
          const SizedBox(height: TraeTokens.gapXs),
          Text('主机上的 Strata 需要升级到支持 /models/installed 的版本，'
              '升级后这里会列出主机上全部可加载的模型。',
              style: TraeText.meta(context)),
          if (current != null) ...[
            const SizedBox(height: TraeTokens.gapSm),
            Text('当前服务的模型：$current',
                key: const Key('ctrl_models_404_current'),
                style: TraeText.meta(context)),
          ],
        ],
      );
    }

    if (error is StrataUnauthorizedException) {
      return Text('主机要求 API Key 才能读取已安装模型清单。请在下方填入并保存。',
          key: const Key('ctrl_models_401'), style: TraeText.meta(context));
    }

    return Text('读取已安装模型清单失败：${describeStrataError(error as StrataException)}',
        key: const Key('ctrl_models_error'), style: TraeText.meta(context));
  }
}

/// 上下文长度卡（v0.0.6）
///
/// 上下文长度是引擎启动参数（--max-context）。App 把它写进主机的运行配置，
/// 写完要重启主机（或重启模型）才生效——所以写完明确告诉用户下一步。
class _ContextLengthCard extends ConsumerStatefulWidget {
  const _ContextLengthCard();

  @override
  ConsumerState<_ContextLengthCard> createState() => _ContextLengthCardState();
}

class _ContextLengthCardState extends ConsumerState<_ContextLengthCard> {
  static const _presets = <int>[8192, 16384, 32768, 65536, 131072, 262144];

  final _controller = TextEditingController();
  bool _saving = false;
  bool _dirty = false;
  int? _saved;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      if (!_dirty && _controller.text != (_saved?.toString() ?? '')) {
        setState(() => _dirty = true);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final props = ref.watch(enginePropsProvider).valueOrNull;
    final current = props?.contextLength ?? _saved;
    if (_controller.text.isEmpty && current != null) {
      _controller.text = current.toString();
      _saved = current;
    }

    return Card(
      key: const Key('ctrl_ctx_card'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('上下文长度', style: TraeText.sectionTitle(context)),
            const SizedBox(height: TraeTokens.gapSm),
            Text('模型一次能看多少 token（--max-context）。写入主机运行配置，'
                '需要重启主机后生效。',
                style: TraeText.meta(context)),
            const SizedBox(height: TraeTokens.gapMd),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('ctrl_ctx_input'),
                    controller: _controller,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      hintText: '例如 262144',
                    ),
                    onChanged: (_) => setState(() => _dirty = true),
                  ),
                ),
                const SizedBox(width: TraeTokens.gapMd),
                FilledButton(
                  key: const Key('btn_ctrl_ctx_save'),
                  onPressed: (_saving || !_dirty) ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('保存'),
                ),
              ],
            ),
            const SizedBox(height: TraeTokens.gapSm),
            Wrap(
              spacing: TraeTokens.gapSm,
              runSpacing: TraeTokens.gapSm,
              children: [
                for (final v in _presets)
                  ChoiceChip(
                    key: Key('ctrl_ctx_preset_$v'),
                    label: Text('${v ~/ 1024}K'),
                    selected: current == v,
                    onSelected: (_) {
                      _controller.text = v.toString();
                      setState(() => _dirty = true);
                    },
                  ),
              ],
            ),
            if (_saved != null)
              Padding(
                padding: const EdgeInsets.only(top: TraeTokens.gapSm),
                child: Text('已写入 $_saved。重启主机后生效。',
                    key: const Key('ctrl_ctx_saved'),
                    style: TraeText.meta(context)),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final raw = _controller.text.trim();
    final value = int.tryParse(raw);
    if (value == null || value <= 0) {
      messenger.showSnackBar(const SnackBar(
        content: Text('请输入一个大于 0 的整数'),
        duration: Duration(seconds: 3),
      ));
      return;
    }
    setState(() => _saving = true);
    try {
      final client = ref.read(strataClientProvider);
      final result = await client.setContextLength(value);
      setState(() {
        _saved = value;
        _dirty = false;
      });
      messenger.showSnackBar(SnackBar(
        content: Text('已写入上下文长度 $value'
            '${result.changed.contains('context_length') ? '' : '（主机未报告变更）'}，'
            '重启主机后生效。'),
        duration: const Duration(seconds: 4),
      ));
      ref.invalidate(enginePropsProvider);
    } on StrataException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('写入失败：${describeStrataError(e)}'),
        duration: const Duration(seconds: 5),
      ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// 引擎属性卡（/props 只读；量化档位等由主机 setup 时设定）
class _EnginePropsCard extends ConsumerWidget {
  const _EnginePropsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final props = ref.watch(enginePropsProvider);
    final p = props.valueOrNull;
    if (p == null || !p.hasAny) return const SizedBox.shrink();

    return Card(
      key: const Key('ctrl_props_card'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('引擎属性', style: TraeText.sectionTitle(context)),
            const SizedBox(height: TraeTokens.gapSm),
            _Row('Model', p.model),
            _Row('Quantization', p.quantization),
            _Row('Total slots', p.totalSlots?.toString()),
            _Row('Context length', p.contextLength?.toString()),
            _Row('Host mode', p.hostMode),
            _Row('Build', p.buildInfo),
            _Row('Model path', p.modelPath),
            const SizedBox(height: TraeTokens.gapSm),
            Text('以上为当前引擎的运行属性。上下文长度可在上一张卡里设置；'
                '量化档位与模型路径由主机 setup 时设定。',
                style: TraeText.meta(context)),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final v = value?.trim();
    if (v == null || v.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 120, child: Text(label, style: TraeText.meta(context))),
          Expanded(
            child: Text(v,
                style: TraeText.body(context)
                    .copyWith(fontFamily: 'monospace', fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.trae;
    final (fg, bg) = switch (label) {
      'Loaded' => (t.accentText, t.accentTint),
      'In use' || 'Loading…' => (t.infoText, t.infoTint),
      _ => (t.muted, t.surface2),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(TraeTokens.radiusPill),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}

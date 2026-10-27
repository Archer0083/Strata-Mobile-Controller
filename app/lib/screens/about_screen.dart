// AboutScreen（M2-3，对齐 webUI About tab 的 renderAbout + loadConfig）：
//
// - facts 三卡：engine（Model/Engine/Context/KV cache/Experts/Speculation/Images/cvec）
//   + hw（GPU/CPU/RAM）+ api（OpenAI/Anthropic base URL + Model name，一键复制）；
//   数据源 = metricsProvider 的 engine / hardware_static / hardware 段
//   （与 webUI renderAbout 一致；webUI 从 lastMetrics 取，App 从缓存快照取）
// - API key 管理：password 输入 + 显示/隐藏，存 Profile（secure storage）
// - 模型设置：GET /config keys 按 kind 分型渲染（bool 开关/enum 下拉/number/string
//   输入，help 文案）→ POST {set} 只发 diff；保存前二次确认（.bak 备份 + 主机侧生效）
// - 主题切换入口沿用设置页（M2-1 已建），本页不放

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/api_models.dart';
import '../models/metrics_snapshot.dart';
import '../providers/connection_provider.dart';
import '../providers/engine_config_provider.dart';
import '../providers/monitor_provider.dart';
import '../services/strata_client.dart';
import '../theme/trae_theme.dart';
import '../widgets/api_key_card.dart';
import 'home_shell.dart';

class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final metrics = ref.watch(metricsProvider);

    return Scaffold(
      backgroundColor: context.trae.bg,
      appBar: AppBar(
        titleSpacing: TraeTokens.gapLg,
        title: Text('关于', style: TraeText.pageTitle(context)),
        // v0.0.9：About 提为一级页后，这里要带上统一的顶栏入口条
        actions: const [
          TopNavEntries(exclude: TopNav.about),
          SizedBox(width: TraeTokens.gapSm),
        ],
      ),
      body: metrics.maybeWhen(
        data: (snap) => _AboutBody(snapshot: snap),
        orElse: () => _AboutUnavailable(error: metrics.error),
      ),
    );
  }
}

/// /metrics 不可用时的空态：按异常分型给出**真实原因**。
///
/// 旧实现对所有错误都写「/metrics 未就绪」，401（缺 API Key）也会落进这里，
/// 用户会误以为「About 功能没做」——实际只是没带钥匙，故障语义必须说清。
///
/// 【2026-10-27 真机反馈修复·缺陷 C】401 分支**必须就地给出补 key 入口**：
/// API key 卡片原本只挂在 `_AboutBody`（需要 /metrics 成功才渲染），
/// 于是「缺 key → About 报 401 → About 不渲染 key 卡片 → 用户找不到填 key
/// 的地方」形成死锁，只能退回连接页重填，而用户报告的现象正是
/// 「填了一次 api key 和主机地址端口之后还是看不到主机状态」。
/// 修复：401 分支下仍渲染 `_ApiKeyCard`，故障态自带修复路径。
class _AboutUnavailable extends ConsumerWidget {
  const _AboutUnavailable({this.error});

  final Object? error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = error;
    final isAuth = e is StrataUnauthorizedException;
    final isOffline = e is StrataConnectionException;
    // 404：主机上的 Strata 版本没有 /metrics（老版本）。
    // 真机截图里显示的「监控数据不可用（/metrics 未就绪）」就是这条，
    // 但没告诉用户「这是版本差异，怎么才能看到」——补一句能做的动作。
    final isLegacy = e is StrataNotFoundException;

    final title = isAuth
        ? '需要 API Key'
        : isOffline
            ? '主机不可达'
            : isLegacy
                ? '主机未返回 /metrics 数据'
                : '监控数据不可用';
    // 【v0.0.7 真机反馈】测试者同主机 webUI 的 #about 能正常看 facts，
    // 笼统断言「版本较旧、没有 /metrics 接口」不成立且无法定位——改为
    // 中性描述 + 错误摘要，并让本页继续展示可从 /v1/status 与 /props
    // 拿到的基础信息（下方 _AboutBasicFactsCard），不再整页死路。
    final detail = switch (e) {
      StrataNotFoundException n => '$n',
      StrataServerErrorException s => '主机返回 ${s.statusCode ?? '5xx'}',
      _ => '$e'
    };
    final hint = isAuth
        ? '主机要求 API Key，请在下方填入并保存，无需返回上页'
        : isOffline
            ? '请先在监控页确认主机在线'
            : '详细 facts 需要 /metrics，本次未取到：$detail。\n'
                '下方「基础信息」来自 /v1/status 与 /props（主机基础接口），'
                '通常仍可显示；webUI 的 #about 若正常，请截图本页反馈。';

    // 故障说明 + （仅 401）就地补 key 卡片
    final banner = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isAuth
                  ? Icons.key
                  : isLegacy
                      ? Icons.update
                      : Icons.cloud_off,
              size: 20,
              color: isAuth ? context.trae.warn : context.trae.muted,
            ),
            const SizedBox(width: TraeTokens.gapSm),
            Flexible(
              child: Text(title, style: TraeText.sectionTitle(context)),
            ),
          ],
        ),
        const SizedBox(height: TraeTokens.gapSm),
        Text(hint, style: TraeText.meta(context), textAlign: TextAlign.center),
      ],
    );

    if (!isAuth) {
      // 【v0.0.7】非 401 的不可用态不再整页死路：banner 讲真实原因，
      // 下方继续渲染 /v1/status + /props 基础信息卡（主机基础接口，
      // 与控制页同源——控制页在真机上一直有数据）。
      return ListView(
        key: const Key('about_unavailable'),
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        children: [
          const SizedBox(height: TraeTokens.gapXl),
          banner,
          const SizedBox(height: TraeTokens.gapLg),
          const _AboutBasicFactsCard(),
          const SizedBox(height: TraeTokens.gapMd),
          const _DeveloperCard(),
        ],
      );
    }

    // 401 分支：key 卡片自带修复路径；保存成功后让本页持有的
    // /config 与 /props 一并重拉（否则模型设置卡仍是 401 空态）。
    void onKeySaved() {
      ref.invalidate(configProvider);
      ref.invalidate(enginePropsProvider);
    }

    return ListView(
      padding: const EdgeInsets.all(TraeTokens.gapLg),
      children: [
        banner,
        const SizedBox(height: TraeTokens.gapLg),
        ApiKeyCard(onSaved: onKeySaved),
        const SizedBox(height: TraeTokens.gapMd),
        const _ModelSettingsCard(),
        const SizedBox(height: TraeTokens.gapMd),
        const _DeveloperCard(),
      ],
    );
  }
}

/// /metrics 取不到时的降级数据源（v0.0.7）：/v1/status + /props 各自容错，
/// 两个都失败才 error（此时卡片隐藏，仅剩 banner）。watch strataClientProvider，
/// 随 Profile / key 变更自动重拉。公开命名：测试需预热（autoDispose 首拉
/// 必须在真实 HTTP zone 发起，否则 fake zone 400）。
final aboutFallbackProvider = FutureProvider.autoDispose<
    ({EngineStatus? status, EngineProps? props})>((ref) async {
  final client = ref.watch(strataClientProvider);
  EngineStatus? st;
  try {
    st = await client.engineStatus();
  } on Object {
    st = null; // 老服务器 / 状态不可达：跳过，不为一张卡拖垮整页
  }
  EngineProps? pr;
  try {
    pr = await client.props();
  } on Object {
    pr = null;
  }
  return (status: st, props: pr);
});

/// 基础信息卡（v0.0.7）：/metrics 失败时的降级 facts——模型 / 加载状态 /
/// 上下文长度 / 量化 / 构建信息，来自 /v1/status 与 /props。
class _AboutBasicFactsCard extends ConsumerWidget {
  const _AboutBasicFactsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fallback = ref.watch(aboutFallbackProvider);
    return fallback.maybeWhen(
      data: (d) {
        final st = d.status;
        final pr = d.props;
        if (st == null && pr == null) {
          return const SizedBox.shrink();
        }
        final model = st?.model ?? pr?.model;
        final rows = <(String, String)>[
          if (model != null) ('模型', model),
          if (st != null) ('引擎状态', st.stateLabel),
          if (pr?.contextLength != null)
            ('上下文长度', '${pr!.contextLength} tokens'),
          if (pr?.quantization != null && pr!.quantization!.isNotEmpty)
            ('量化档位', pr.quantization!),
          if (pr?.buildInfo != null && pr!.buildInfo!.isNotEmpty)
            ('构建', pr.buildInfo!),
        ];
        return Card(
          key: const Key('about_fallback_card'),
          child: Padding(
            padding: const EdgeInsets.all(TraeTokens.gapLg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('基础信息', style: TraeText.sectionTitle(context)),
                const SizedBox(height: TraeTokens.gapSm),
                Text('来自 /v1/status 与 /props（未走 /metrics）',
                    style: TraeText.meta(context)),
                const SizedBox(height: TraeTokens.gapMd),
                for (final (k, v) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(child: Text(k, style: TraeText.meta(context))),
                        Expanded(
                          child: Text(
                            v,
                            style: TraeText.body(context),
                            textAlign: TextAlign.end,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _AboutBody extends ConsumerWidget {
  const _AboutBody({required this.snapshot});

  final MetricsSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.all(TraeTokens.gapLg),
      children: [
        _EngineFactsCard(engine: snapshot.engine),
        const SizedBox(height: TraeTokens.gapMd),
        const _EnginePropsCard(),
        const SizedBox(height: TraeTokens.gapMd),
        _HwFactsCard(snapshot: snapshot),
        const SizedBox(height: TraeTokens.gapMd),
        const _ApiFactsCard(),
        const SizedBox(height: TraeTokens.gapMd),
        const ApiKeyCard(),
        const SizedBox(height: TraeTokens.gapMd),
        const _ModelSettingsCard(),
        const SizedBox(height: TraeTokens.gapMd),
        const _DeveloperCard(),
        const SizedBox(height: TraeTokens.gapXl),
      ],
    );
  }
}

/// 开发者信息卡（v0.0.9 新增，v0.0.10 改写措辞）
///
/// 用户要求：「在APP的合适位置加上开发者信息（Github@Archer0083）」。
/// 放在 About 页末尾：About 提为一级页后，这就是 App 里最符合语义的位置
/// （模型/服务信息与「谁做的」并列），且不受 /metrics 在线与否影响。
///
/// 【v0.0.10 措辞改写（第十一轮真机反馈驱动）】
/// 用户反馈原话：「目前 app 开发是基于 strata 项目的生态开发的，
/// 开发者信息需要规避可能侵权或不当的表述」。
/// 旧文案「Strata Mobile Controller · 开源协作与问题反馈」把本 App 与
/// 上游项目名并列，容易被理解为「官方出品 / 授权发行」，
/// 既可能引发商标争议，也会误导用户以为官方渠道能获得本 APK。
/// 改写原则：
///   ① **不自称与上游同名** —— App 名称改为中性描述「本地模型移动控制端」；
///   ② **明示独立第三方** —— 显式声明与上游项目无隶属/授权关系；
///   ③ **保留可追溯的开发者归属** —— GitHub 账号照旧保留（用户明确要求）。
class _DeveloperCard extends StatelessWidget {
  const _DeveloperCard();

  static const String githubUser = 'Archer0083';
  static const String githubUrl = 'https://github.com/Archer0083';

  @override
  Widget build(BuildContext context) {
    final t = context.trae;
    return Card(
      key: const Key('card_developer'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('开发者', style: TraeText.sectionTitle(context)),
            const SizedBox(height: TraeTokens.gapSm),
            _FactRow('GitHub', '@$githubUser', copyable: true),
            const SizedBox(height: TraeTokens.gapSm),
            InkWell(
              key: const Key('btn_open_github'),
              borderRadius: BorderRadius.circular(TraeTokens.radiusSm),
              onTap: () async {
                final uri = Uri.tryParse(githubUrl);
                if (uri == null) return;
                try {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                } on Exception {
                  // 无浏览器等极端场景：静默失败（上方仍有可复制的账号名）
                }
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.open_in_new, size: 15, color: t.accent),
                    const SizedBox(width: 6),
                    Text(
                      '在 GitHub 上查看 @$githubUser',
                      style: TraeText.body(context).copyWith(color: t.accent),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: TraeTokens.gapXs),
            Text(
              '非官方第三方移动控制端 · 与上游项目无隶属或授权关系',
              key: const Key('developer_disclaimer'),
              style: TraeText.meta(context),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// facts 三卡（行结构对齐 webUI facts()：null/'' 值整行隐藏）
// ─────────────────────────────────────────────────────────────

class _FactRow extends StatelessWidget {
  const _FactRow(this.label, this.value, {this.copyable = false});

  final String label;
  final String? value;
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    final v = value?.trim();
    if (v == null || v.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(label, style: TraeText.meta(context)),
          ),
          Expanded(
            child: copyable
                ? Row(
                    children: [
                      Flexible(
                        child: Text(
                          v,
                          key: Key('fact_copy_$label'),
                          style: TraeText.body(context).copyWith(
                              fontFamily: 'monospace', fontSize: 13),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _CopyButton(text: v),
                    ],
                  )
                : Text(v, style: TraeText.body(context)),
          ),
        ],
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: Key('btn_copy'),
      borderRadius: BorderRadius.circular(TraeTokens.radiusSm),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: text));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
          );
        }
      },
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(Icons.copy, size: 14, color: context.trae.muted),
      ),
    );
  }
}

/// engine facts（app.js renderAbout facts-engine 八行）
class _EngineFactsCard extends StatelessWidget {
  const _EngineFactsCard({required this.engine});

  final EngineInfo engine;

  @override
  Widget build(BuildContext context) {
    final kv = engine.kvLabel;
    final kvText = engine.kv == null
        ? null
        : engine.kvResident != null && engine.kvResident! > 0
            ? '$kv, streamed: ${fmtNum(engine.kvResident)} positions per layer in VRAM, the rest in RAM'
            : '$kv, all in VRAM';

    return Card(
      key: const Key('facts_engine'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Engine', style: TraeText.sectionTitle(context)),
            const SizedBox(height: TraeTokens.gapSm),
            _FactRow('Model', engine.model),
            _FactRow('Engine',
                engine.version?.isNotEmpty == true ? 'v${engine.version}' : 'built from source'),
            _FactRow('Context',
                engine.maxContext != null ? '${fmtNum(engine.maxContext)} tokens' : null),
            _FactRow('KV cache', kvText),
            _FactRow(
                'Experts in VRAM',
                engine.expertSlots != null && engine.expertSlots! > 0
                    ? '${fmtNum(engine.expertSlots)} (${gbFromMiB(engine.expertCacheMib ?? 0)} GB)'
                    : null),
            _FactRow('Speculation', _speculationText(engine)),
            _FactRow('Images', engine.imagesEnabled ? 'on' : 'off'),
            _FactRow('Experimental speed projection', _projectionText(engine.cvec)),
          ],
        ),
      ),
    );
  }

  /// spec=0/null 隐藏；MTP drafts up to (mtp_max ?? spec)-1，负数 clamp 0；
  /// lookup 非空追加 prompt lookup on（app.js L392 同款）
  ///
  /// 注意：服务端把纯数字的 INFO 值转成 int（server.py:1073），故 spec/lookup
  /// 可能是数字字符串；此处按 webUI 的真值语义判断（0 = 关闭）。
  static String? _speculationText(EngineInfo e) {
    if (!_isTruthy(e.spec)) return null;
    final base = e.mtpMax ?? num.tryParse(e.spec!);
    final drafts = base == null ? e.spec : (base - 1 < 0 ? 0 : base - 1);
    final lookupOn = _isTruthy(e.lookup) ? ', prompt lookup on' : '';
    return 'MTP drafts up to $drafts tokens$lookupOn';
  }

  /// webUI 的真值语义：null / 空串 / '0' / 'false' → 关闭
  static bool _isTruthy(String? v) {
    if (v == null) return false;
    final t = v.trim().toLowerCase();
    if (t.isEmpty) return false;
    if (const {'0', 'false', 'off', 'no'}.contains(t)) return false;
    return true;
  }

  /// INFO cvec=project:4-44[:singleL] | add:A-B | 0（app.js projectionText）
  static String? _projectionText(Object? c) {
    if (c == null || c == 0 || c == '' || c == '0') return null;
    final parts = c.toString().split(':');
    final mode = parts.isNotEmpty ? parts[0] : '';
    final range = parts.length > 1 ? parts[1] : '';
    final single = parts.length > 2 ? parts[2] : '';
    final ab = range.split('-');
    final a = ab.isNotEmpty ? ab[0] : '';
    final b = ab.length > 1 ? ab[1] : '';
    final dir = single.startsWith('single') ? " (layer ${single.replaceFirst('single', '')}'s direction)" : '';
    return '${mode == 'project' ? 'Projection' : 'Additive'} control vector on layers $a–$b$dir. Per chat in Sampling.';
  }
}

/// /props 引擎属性只读卡（M2-7）：量化档位等主机 setup 时设定的属性。
/// 真实 server 键（model_alias/build_info/total_slots/model_path…）与
/// mock 键（quantization/context_length/host_mode）都容错；引擎未运行
/// 503 或无有效字段 → 整卡隐藏（不占位）。
class _EnginePropsCard extends ConsumerWidget {
  const _EnginePropsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(enginePropsProvider);
    final p = snap.valueOrNull;
    if (p == null || !p.hasAny) return const SizedBox.shrink();

    return Card(
      key: const Key('facts_props'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Engine props', style: TraeText.sectionTitle(context)),
            const SizedBox(height: TraeTokens.gapSm),
            _FactRow('Model', p.model),
            // 量化档位：主机 setup 时设定，App 端只读不可改
            _FactRow('Quantization', p.quantization),
            _FactRow('Total slots', p.totalSlots?.toString()),
            _FactRow('Build', p.buildInfo),
            _FactRow('Model path', p.modelPath),
            _FactRow('Host mode', p.hostMode),
            const SizedBox(height: TraeTokens.gapSm),
            Text('量化档位等属性由主机 setup 时设定，App 端只读。',
                key: const Key('facts_props_readonly_hint'),
                style: TraeText.meta(context)),
          ],
        ),
      ),
    );
  }
}

/// hw facts（GPU/CPU/RAM；GPU 名取 hardware_static，显存取 hardware）
class _HwFactsCard extends StatelessWidget {
  const _HwFactsCard({required this.snapshot});

  final MetricsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final st = snapshot.hardwareStatic;
    final hw = snapshot.hardware;
    final gpuName = st.gpuName ?? '';
    final gpuNote = st.gpuNote ?? '';
    final memTotal = hw.gpuMemTotal;
    final gpu = gpuName.isNotEmpty
        ? (memTotal != null ? '$gpuName, ${gb(memTotal, 0)} GB' : gpuName)
        : (gpuNote.isNotEmpty ? gpuNote : 'not readable (NVML)');
    final cpuName = st.cpuName ?? '';
    final threads = st.threads;
    final cpu = cpuName.isNotEmpty
        ? (threads != null ? '$cpuName, $threads threads' : cpuName)
        : null;
    final ramTotal = hw.ramTotal;

    return Card(
      key: const Key('facts_hw'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Hardware', style: TraeText.sectionTitle(context)),
            const SizedBox(height: TraeTokens.gapSm),
            _FactRow('GPU', gpu),
            _FactRow('CPU', cpu),
            _FactRow('RAM', ramTotal != null ? '${gb(ramTotal, 0)} GB' : null),
          ],
        ),
      ),
    );
  }
}

/// api facts（base URL 由当前 Profile 派生；${origin}/v1 对齐 webUI location.origin）
class _ApiFactsCard extends ConsumerWidget {
  const _ApiFactsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileProvider);
    final origin = profile?.baseUrl ?? 'http://<host>:<port>';
    final engine = ref.watch(metricsProvider).valueOrNull?.engine;

    return Card(
      key: const Key('facts_api'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('API', style: TraeText.sectionTitle(context)),
            const SizedBox(height: TraeTokens.gapSm),
            _FactRow('OpenAI base URL', '$origin/v1', copyable: true),
            _FactRow('Anthropic base URL', origin, copyable: true),
            _FactRow('Model name', engine?.model, copyable: true),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// API key 管理已抽为共享组件（widgets/api_key_card.dart 的 ApiKeyCard）：
// 监控页 / 控制页在 401 态下同样需要就地补 key 的入口，故不留在本页私有。

// ─────────────────────────────────────────────────────────────
// 模型设置（GET/POST /config；四 kind 分型渲染 + diff 保存 + 二次确认）
// ─────────────────────────────────────────────────────────────

class _ModelSettingsCard extends ConsumerWidget {
  const _ModelSettingsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfg = ref.watch(configProvider);

    return cfg.when(
      loading: () => const Card(
        key: Key('cfg_loading'),
        child: Padding(
          padding: EdgeInsets.all(TraeTokens.gapLg),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      // 404 等：无 run config / 旧版服务端 → 整卡隐藏（webUI cfg-card.hidden = true 同款）
      error: (e, _) => const SizedBox.shrink(key: Key('cfg_error')),
      data: (info) => info.keys.isEmpty
          ? const SizedBox.shrink()
          : _ConfigForm(info: info),
    );
  }
}

class _ConfigForm extends ConsumerStatefulWidget {
  const _ConfigForm({required this.info});

  final ConfigInfo info;

  @override
  ConsumerState<_ConfigForm> createState() => _ConfigFormState();
}

class _ConfigFormState extends ConsumerState<_ConfigForm> {
  late final Map<String, TextEditingController> _textControllers;
  final Map<String, String?> _selections = {}; // bool/enum 的下拉选择（null=default）

  @override
  void initState() {
    super.initState();
    _textControllers = {
      for (final k in widget.info.keys)
        if (k.kind == 'number' || k.kind == 'string')
          k.key: TextEditingController(
              text: k.value == null ? '' : k.value.toString()),
    };
  }

  @override
  void dispose() {
    for (final c in _textControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 与 webUI configValue 对齐：空串 → null（default）；bool → 'true'；number → num。
  /// 服务端初值为空串的 string 键（如 system=''）归一为 null——用户未动不产生
  /// diff（webUI 对空串初值会误发 diff，App 侧修正此边缘行为）。
  Map<String, Object?> _buildDiff() {
    final set = <String, Object?>{};
    for (final k in widget.info.keys) {
      final old = (k.value is String && (k.value as String).isEmpty)
          ? null
          : k.value;
      Object? now;
      switch (k.kind) {
        case 'bool':
          final s = _selections[k.key] ?? (old?.toString());
          now = (s == null || s.isEmpty) ? null : s == 'true';
        case 'enum':
          final sel = _selections[k.key];
          now = (sel != null && sel.isNotEmpty)
              ? sel
              : old?.toString();
        case 'number':
          final s = _textControllers[k.key]!.text.trim();
          now = s.isEmpty ? null : num.tryParse(s);
        default: // string
          final s = _textControllers[k.key]!.text.trim();
          now = s.isEmpty ? null : s;
      }
      if (now != old) set[k.key] = now;
    }
    return set;
  }

  Future<void> _confirmAndSave(BuildContext context) async {
    final diff = _buildDiff();
    if (diff.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有改动'), duration: Duration(seconds: 1)),
      );
      return;
    }

    // 先取 messenger 再 await，避免跨 async gap 使用 BuildContext
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存模型设置？'),
        content: Text(
          '将写入主机上的运行配置（${widget.info.file ?? 'strata-<model>.json'}），'
          '旧文件会备份为 .bak。\n改动从下次启动模型起生效。',
        ),
        actions: [
          TextButton(
            key: const Key('btn_cfg_cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('btn_cfg_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      final r = await ref.read(strataClientProvider).saveConfig(diff);
      messenger.showSnackBar(SnackBar(
        content: Text(
          r.changed.isEmpty
              ? '没有改动'
              : '已保存（${r.changed.join(', ')}）；旧文件备份为 .bak。重启模型后生效。',
        ),
        duration: const Duration(seconds: 3),
      ));
      ref.invalidate(configProvider);
    } on StrataException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('未保存：${describeStrataError(e)}'),
        duration: const Duration(seconds: 4),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('cfg_card'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('模型设置', style: TraeText.sectionTitle(context)),
            const SizedBox(height: TraeTokens.gapSm),
            Text(
              '运行配置的少数文档化键值（${widget.info.file ?? ''}），对所有客户端生效，从下次启动模型起。',
              style: TraeText.meta(context),
            ),
            const SizedBox(height: TraeTokens.gapMd),
            for (final k in widget.info.keys) ...[
              _ConfigKeyField(
                key: Key('cfg_field_${k.key}'),
                configKey: k,
                textController: _textControllers[k.key],
                currentSelection: _selections[k.key],
                onSelectionChanged: (v) => setState(() => _selections[k.key] = v ?? ''),
              ),
              const SizedBox(height: TraeTokens.gapMd),
            ],
            FilledButton(
              key: const Key('btn_cfg_save'),
              onPressed: () => _confirmAndSave(context),
              child: const Text('保存设置'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单键字段：bool/enum → DropdownButtonFormField；number → 数字键盘；string → 文本
class _ConfigKeyField extends StatelessWidget {
  const _ConfigKeyField({
    super.key,
    required this.configKey,
    required this.textController,
    required this.currentSelection,
    required this.onSelectionChanged,
  });

  final ConfigKey configKey;
  final TextEditingController? textController;
  final String? currentSelection;
  final ValueChanged<String?> onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final k = configKey;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(k.help ?? k.key,
                  style: TraeText.body(context),
                  overflow: TextOverflow.ellipsis),
            ),
            Text(k.key,
                style: TraeText.meta(context)
                    .copyWith(fontFamily: 'monospace', fontSize: 11)),
          ],
        ),
        const SizedBox(height: 4),
        if (k.kind == 'bool')
          _buildBoolDropdown(context)
        else if (k.isEnum)
          _buildEnumDropdown(context)
        else if (k.kind == 'number')
          TextField(
            key: Key('cfg_input_${k.key}'),
            controller: textController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(hintText: 'default'),
          )
        else
          TextField(
            key: Key('cfg_input_${k.key}'),
            controller: textController,
            decoration: const InputDecoration(hintText: 'default'),
          ),
      ],
    );
  }

  Widget _buildBoolDropdown(BuildContext context) {
    final old = configKey.value?.toString();
    final cur = currentSelection ?? ((old == 'true' || old == 'false') ? old! : '');
    return DropdownButtonFormField<String>(
      key: Key('cfg_dropdown_${configKey.key}'),
      initialValue: cur.isEmpty ? null : cur,
      items: [
        const DropdownMenuItem(value: '', child: Text('default')),
        const DropdownMenuItem(value: 'true', child: Text('on')),
        const DropdownMenuItem(value: 'false', child: Text('off')),
      ],
      onChanged: (v) => onSelectionChanged(v),
    );
  }

  Widget _buildEnumDropdown(BuildContext context) {
    final old = configKey.value?.toString();
    final cur =
        currentSelection ?? ((old != null && configKey.choices.contains(old)) ? old : '');
    return DropdownButtonFormField<String>(
      key: Key('cfg_dropdown_${configKey.key}'),
      initialValue: cur.isEmpty ? null : cur,
      items: [
        const DropdownMenuItem(value: '', child: Text('default')),
        for (final c in configKey.choices)
          DropdownMenuItem(value: c, child: Text(c)),
      ],
      onChanged: (v) => onSelectionChanged(v),
    );
  }
}

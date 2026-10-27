// MonitorScreen 完整版（M2-2，SPEC §10 MonitorScreen）：
// - 状态卡（idle/reading/generating/queued/error 5 徽章 + 进度行）
// - 8 指标卡（Speed 双值 / GPU load / VRAM / GPU temp / Power / PCIe / CPU / Disk read，
//   各带 sparkline 折线+面积，viewBox 0 0 100 32、y=30−(x/top)×26 对齐 app.js）
// - context 环形仪表（270° 弧 CustomPainter，中心 pct + used/max）
// - RAM/VRAM/KV/expert 条
// - 请求表 9 列（时间 / 状态徽章 / Prompt / Reused / Output / Prefill t/s / Decode t/s /
//   VRAM hit rate / Duration）+ Show all 开关
// - conversation_cache 卡（复用统计 / Parked / 记忆 / facts 4 行）
// - MCP 卡（/mcp 服务器树；404 隐藏）
// - 顶部 M1-7 存活卡（延迟徽章）保留
// - /metrics 不可用（404/旧版）→ 降级 M1-7 骨架（存活卡 + 模型列表）
//
// 轮询：metricsProvider 1s；页面可见启停由 activate/deactivate 驱动
//（本页常驻 IndexedStack，用 WidgetsBindingObserver 仅在 App 前台时轮询）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/api_models.dart';
import '../models/metrics_snapshot.dart';
import '../providers/connection_provider.dart';
import '../providers/installed_models_provider.dart';
import '../providers/monitor_provider.dart';
import '../services/strata_client.dart';
import '../theme/trae_theme.dart';
import '../widgets/api_key_card.dart';
import 'home_shell.dart';

class MonitorScreen extends ConsumerStatefulWidget {
  const MonitorScreen({super.key});

  @override
  ConsumerState<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends ConsumerState<MonitorScreen>
    with WidgetsBindingObserver {
  // 持有 notifier 引用：unmount 时 ref 已被 riverpod 置 disposed（dispose 内
  // ref.read 抛 StateError），用字段才能停掉轮询 Timer
  MetricsPolling? _polling;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 常驻 IndexedStack：进入即激活（App 前台前提由 didChangeAppLifecycleState 管）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.detached) {
        _polling = ref.read(metricsProvider.notifier);
        _polling!.activate();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App 退后台停轮询、回前台恢复（省电；webUI 页面不可见同理）
    final n = ref.read(metricsProvider.notifier);
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
    // ref 此时已不可用（riverpod 先于 State.dispose 置 disposed），
    // 经 _polling 字段停轮询，保证 1s Timer 不泄漏
    _polling?.deactivate();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final metrics = ref.watch(metricsProvider);
    final profile = ref.watch(currentProfileProvider);

    return Scaffold(
      backgroundColor: context.trae.bg,
      appBar: AppBar(
        titleSpacing: TraeTokens.gapLg,
        title: Text('监控', style: TraeText.pageTitle(context)),
        actions: [
          IconButton(
            key: const Key('btn_refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            color: context.trae.inkSoft,
            onPressed: () async {
              ref.invalidate(monitorProvider);
              ref.invalidate(mcpProvider);
              await ref.read(metricsProvider.notifier).refresh();
            },
          ),
          const TopNavEntries(exclude: TopNav.monitor),
          const SizedBox(width: TraeTokens.gapSm),
        ],
      ),
      body: metrics.when(
        // 闪断（copyWithPrevious 保留旧值）→ 跳过 loading 上屏；
        // skipError：轮询中出错但仍有旧数据 → 继续显示旧数据，不上错误页
        skipLoadingOnRefresh: true,
        skipLoadingOnReload: true,
        skipError: true,
        loading: () => const Center(
          child: CircularProgressIndicator(key: Key('metrics_loading')),
        ),
        error: (e, _) => _metricsFallback(context, ref, e, profile?.baseUrl),
        data: (snap) => _MetricsBody(snapshot: snap),
      ),
    );
  }

  /// /metrics 不可用：按异常分型分流——「完全离线」（health 也不通 → M1-7 错误页）、
  /// 「鉴权失败」（401 → 提示补 API Key，绝不误报为旧版）、
  /// 「在线但无 /metrics」（404 → 降级骨架）
  Widget _metricsFallback(
      BuildContext context, WidgetRef ref, Object e, String? webUiUrl) {
    if (e is StrataConnectionException) {
      return _OfflineView(
        error: e,
        message: null,
        webUiUrl: webUiUrl,
      );
    }
    // 401：主机要求 API Key（/health 报 api_key=true）。这不是「旧版没有
    // /metrics」——旧版是 404。误判会让用户以为功能缺失，真实原因只是没带钥匙。
    //
    // 【2026-10-27 真机反馈修复·缺陷 C】401 分支**必须就地给出补 key 入口**：
    // 监控页是用户进 App 后最常看的运维页，若只显示一句「需要 API Key」
    // 而不给输入框，用户只能退回连接页重填 —— 真机反馈原话正是
    // 「填写一次 api key 和配置主机地址和端口之后还是无法看到主机状态」。
    // 修复：401 分支下直接渲染共享的 ApiKeyCard，保存后 metrics 立即重拉。
    if (e is StrataUnauthorizedException) {
      return const _OfflineView(
        error: null,
        message: '主机要求 API Key，请在下方填入并保存，无需返回上页。',
        webUiUrl: null,
        icon: Icons.key,
        title: '需要 API Key',
        showApiKeyCard: true,
      );
    }
    // 在线但 /metrics 缺失（404 等）→ 降级 M1-7 骨架
    return _LegacyBody(reason: e);
  }
}

// ─────────────────────────────────────────────────────────────
// 主体：metrics 数据齐备时的完整渲染
// ─────────────────────────────────────────────────────────────

class _MetricsBody extends ConsumerWidget {
  const _MetricsBody({required this.snapshot});

  final MetricsSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RefreshIndicator(
      onRefresh: () => ref.read(metricsProvider.notifier).refresh(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        children: [
          _StateCard(
            live: snapshot.live,
            lastRequest: snapshot.requests.isEmpty ? null : snapshot.requests.first,
          ),
          const SizedBox(height: TraeTokens.gapMd),
          ..._buildMetricCards(context, snapshot),
          const SizedBox(height: TraeTokens.gapMd),
          _ContextGaugeCard(snapshot: snapshot),
          const SizedBox(height: TraeTokens.gapMd),
          _MemoryBarsCard(snapshot: snapshot),
          const SizedBox(height: TraeTokens.gapMd),
          _RequestsCard(snapshot: snapshot),
          if (snapshot.conversationCache?.enabled == true) ...[
            const SizedBox(height: TraeTokens.gapMd),
            _ConvCacheCard(cache: snapshot.conversationCache!),
          ],
          const SizedBox(height: TraeTokens.gapMd),
          _TotalsRow(totals: snapshot.totals),
          const SizedBox(height: TraeTokens.gapMd),
          const _McpCard(),
          const SizedBox(height: TraeTokens.gapMd),
          _CurrentModelCard(model: snapshot.engine.model),
          const SizedBox(height: TraeTokens.gapMd),
          const _InstalledModelsCard(),
          const SizedBox(height: TraeTokens.gapXl),
        ],
      ),
    );
  }

  List<Widget> _buildMetricCards(BuildContext context, MetricsSnapshot s) {
    final hw = s.hardware;
    // webUI 是 CSS Grid repeat(4, minmax(0,1fr))，≤1000px 降 2 列（app.css:91）。
    // 手机宽度有限 → 2 列为默认，≥560dp 时升 4 列。
    return [
      _SpeedCard(
        tokS: s.live.tokS,
        prefillTokS: s.live.prefillTokSMean,
        decodeHistory: s.historySeries('tok_s'),
        prefillHistory: s.historySeries('prefill_tok_s_mean'),
      ),
      const SizedBox(height: TraeTokens.gapSm),
      _MetricGrid(
        children: [
          _MetricCard(
            keyId: 'gpu_util',
            icon: Icons.memory,
            label: 'GPU load',
            value: hw.gpuUtil == null ? '–' : '${fmtNum(hw.gpuUtil, 0)}%',
            series: s.historySeries('gpu_util'),
            top: 100,
          ),
          _MetricCard(
            keyId: 'gpu_mem',
            icon: Icons.layers_outlined,
            label: 'VRAM',
            value: gb(hw.gpuMemUsed),
            sub: hw.gpuMemTotal == null ? null : '/ ${gb(hw.gpuMemTotal)} GB',
            series: s.historySeries('gpu_mem_used'),
            top: hw.gpuMemTotal ?? 0,
          ),
          _MetricCard(
            keyId: 'gpu_temp',
            icon: Icons.thermostat,
            label: 'GPU temp',
            value: hw.gpuTemp == null ? '–' : '${fmtNum(hw.gpuTemp, 0)}°C',
            series: s.historySeries('gpu_temp'),
            top: 90,
            warnOver: 80,
            // webUI data-tone="warn"（app.js:128）→ 折线用 warn 色
            tone: _MetricTone.warn,
          ),
          _MetricCard(
            keyId: 'gpu_power',
            icon: Icons.bolt_outlined,
            label: 'Power',
            value: hw.gpuPower == null ? '–' : '${fmtNum(hw.gpuPower, 0)} W',
            series: s.historySeries('gpu_power'),
            top: hw.gpuPowerLimit ?? 0,
          ),
          _MetricCard(
            keyId: 'pcie',
            icon: Icons.link,
            label: 'PCIe',
            // 主值 Gen{gen_max||gen} x{width}；副值 to GPU {rx} MB/s
            value: (hw.gpuPcieGen ?? hw.gpuPcieGenMax) == null &&
                    hw.gpuPcieWidth == null
                ? '–'
                : 'Gen${hw.gpuPcieGenMax ?? hw.gpuPcieGen ?? ''} x${hw.gpuPcieWidth ?? ''}',
            sub: hw.gpuPcieRxMb == null
                ? null
                : 'to GPU ${fmtNum(hw.gpuPcieRxMb, 0)} MB/s',
            series: s.historySeries('gpu_pcie_rx_mb'),
            // webUI data-tone="info"（app.js:131）→ 折线用 info 色
            tone: _MetricTone.info,
          ),
          _MetricCard(
            keyId: 'cpu',
            icon: Icons.developer_board_outlined, // webUI i-cpu
            label: 'CPU',
            value: hw.cpu == null ? '–' : '${fmtNum(hw.cpu, 0)}%',
            sub: hw.cpu == null || (s.hardwareStatic.cores ?? 0) == 0
                ? null
                : '${s.hardwareStatic.cores} cores · ${s.hardwareStatic.threads} threads',
            series: s.historySeries('cpu'),
            top: 100,
          ),
          _MetricCard(
            keyId: 'disk_read',
            icon: Icons.save_outlined,
            label: 'Disk read',
            value: _diskFmt(hw.diskReadMb),
            sub: _diskFmt(hw.diskWriteMb) == '–'
                ? null
                : 'write ${_diskFmt(hw.diskWriteMb)}',
            series: s.historySeries('disk_read_mb'),
            // webUI data-tone="info"（app.js:132）→ 折线用 info 色
            tone: _MetricTone.info,
          ),
        ],
      ),
    ];
  }

  /// ≥1000 MB/s → GB/s（app.js 同款）
  static String _diskFmt(double? mb) {
    if (mb == null) return '–';
    if (mb >= 1000) return '${fmtNum(mb / 1000, 1)} GB/s';
    return '${fmtNum(mb, 0)} MB/s';
  }
}

/// 指标卡的折线色调（对齐 webUI data-tone）
enum _MetricTone { accent, warn, info }

/// 指标卡网格（对齐 webUI .metrics CSS Grid）。
///
/// webUI：4 列（repeat(4, minmax(0,1fr))），≤1000px 降 2 列。
/// App：≤560dp 用 2 列，>560dp 用 4 列（手机横屏/平板）。
class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth > 560 ? 4 : 2;
        const gap = TraeTokens.gapSm;
        final rows = <Widget>[];
        for (var i = 0; i < children.length; i += columns) {
          final slice = children.skip(i).take(columns).toList();
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var j = 0; j < columns; j++) ...[
                    if (j > 0) const SizedBox(width: gap),
                    Expanded(
                      child: j < slice.length
                          ? slice[j]
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          );
          if (i + columns < children.length) {
            rows.add(const SizedBox(height: gap));
          }
        }
        return Column(children: rows);
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 状态卡（5 徽章，对齐 webUI state-card）
// ─────────────────────────────────────────────────────────────

/// 5 个状态徽章的静态定义（对齐 webUI index.html #state-badges）。
///
/// 每项 = (key, 文案, 前景色, 背景色)。webUI 用 CSS 类
/// st-badge--reading / --generating / --queued / --error 区分色，
/// 未激活时 opacity .38；本 App 用同样语义（color + 背景 Tint）。
const _stateBadges = <_StateBadgeSpec>[
  _StateBadgeSpec('idle', 'Idle'),
  _StateBadgeSpec('reading', 'Reading'),
  _StateBadgeSpec('generating', 'Generating'),
  _StateBadgeSpec('queued', 'Queued'),
  _StateBadgeSpec('error', 'Error'),
];

class _StateBadgeSpec {
  const _StateBadgeSpec(this.key, this.label);
  final String key;
  final String label;
}

class _StateCard extends StatelessWidget {
  const _StateCard({required this.live, this.lastRequest});

  final LiveStats live;

  /// 最近一次请求（webUI idle 时用它显示「last: N tokens at M tok/s」）
  final RequestRecord? lastRequest;

  @override
  Widget build(BuildContext context) {
    final t = context.trae;
    final state = live.effectiveState;

    // 5 徽章配色（app.js）：idle 灰 / reading info / generating accent /
    // queued warn / error danger
    Color badgeColor(String key) => switch (key) {
          'reading' => t.info,
          'generating' => t.accent,
          'queued' => t.warn,
          'error' => t.danger,
          _ => t.muted,
        };

    Color badgeTextColor(String key) => switch (key) {
          'reading' => t.infoText,
          'generating' => t.accentText,
          'queued' => t.warnText,
          'error' => t.dangerText,
          _ => t.muted,
        };

    Color badgeTint(String key) => switch (key) {
          'reading' => t.infoTint,
          'generating' => t.accentTint,
          'queued' => t.warnTint,
          'error' => t.dangerTint,
          _ => t.surface2,
        };

    // 当前态（on）：effectiveState；原始 state 也要高亮（webUI 双高亮，
    // queued>0 时 queued + 原 state 同时亮）
    final rawState = live.state ?? 'idle';

    // detail 行 + 进度（对齐 app.js renderMonitor 行 256–278）
    String label = 'Waiting for a request';
    String? detail;
    var progress = 0.0;
    var progressTone = t.accent;

    if (state == 'reading') {
      label = 'Reading prompt';
      progressTone = t.info;
      final pct = live.readingPct;
      if (live.promptTotal != null && live.promptTotal! > 0) {
        progress = pct == null ? 0 : pct / 100;
        detail = '${fmtNum(live.promptRead)} / ${fmtNum(live.promptTotal)} tokens'
            '${pct == null ? '' : ' · ${fmtNum(pct)}%'}';
      } else {
        detail = '${fmtNum(live.promptTokens)} tokens';
      }
    } else if (state == 'generating') {
      label = (live.phase?.isEmpty ?? true)
          ? 'Generating'
          : _capitalize(live.phase!);
      final maxTok = live.maxTokens;
      progress = (maxTok == null || maxTok <= 0)
          ? 0
          : ((live.generatingPct ?? 0) / 100).clamp(0.0, 1.0);
      detail = '${fmtNum(live.generated)} tokens · ${fmtNum(live.tokS, 1)} tok/s';
    } else {
      // webUI：idle 且有上一条请求 → 显示 last: N tokens at M tok/s
      final last = lastRequest;
      if (last != null) {
        detail = 'last: ${fmtNum(last.outputTokens)} tokens'
            '${last.decodeTokS == null ? '' : ' at ${fmtNum(last.decodeTokS, 1)} tok/s'}';
      }
    }

    return Card(
      key: const Key('state_card'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Model state', style: TraeText.sectionTitle(context)),
                const SizedBox(width: TraeTokens.gapMd),
                // 5 枚彩色圆点徽章
                Expanded(
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final b in _stateBadges)
                        _StateBadge(
                          key: Key('state_badge_${b.key}'),
                          label: b.label,
                          color: badgeColor(b.key),
                          textColor: badgeTextColor(b.key),
                          tint: badgeTint(b.key),
                          // 未激活徽章淡化（webUI opacity .38）
                          dimmed: b.key != state && b.key != rawState,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: TraeTokens.gapMd),
            Row(
              children: [
                Text(label,
                    key: const Key('state_label'),
                    style: TraeText.body(context)),
                const SizedBox(width: TraeTokens.gapSm),
                if (detail != null)
                  Expanded(
                    child: Text(detail,
                        key: const Key('state_detail'),
                        style: TraeText.meta(context),
                        textAlign: TextAlign.right,
                        overflow: TextOverflow.ellipsis),
                  ),
              ],
            ),
            // webUI 的进度条恒在（宽度可 0）；本 App 仅在有进度时渲染，避免空条
            if (progress > 0) ...[
              const SizedBox(height: TraeTokens.gapSm),
              ClipRRect(
                borderRadius: BorderRadius.circular(TraeTokens.radiusPill),
                child: LinearProgressIndicator(
                  key: const Key('state_progress'),
                  value: progress.clamp(0.0, 1.0),
                  minHeight: 4,
                  backgroundColor: t.surface2,
                  valueColor: AlwaysStoppedAnimation(progressTone),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

/// 一枚状态徽章：彩色圆点 + 文案（对齐 webUI .st-badge::before）
class _StateBadge extends StatelessWidget {
  const _StateBadge({
    super.key,
    required this.label,
    required this.color,
    required this.textColor,
    required this.tint,
    required this.dimmed,
  });

  final String label;
  final Color color;
  final Color textColor;
  final Color tint;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: dimmed ? 0.38 : 1,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: tint,
          borderRadius: BorderRadius.circular(TraeTokens.radiusPill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TraeWidgets.statusDot(color, size: 6),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                  fontSize: TraeTokens.fontXs,
                  fontWeight: FontWeight.w600,
                  color: textColor),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 指标卡 + sparkline
// ─────────────────────────────────────────────────────────────

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.series,
    this.keyId,
    this.icon,
    this.sub,
    this.top = 0,
    this.warnOver,
    this.tone = _MetricTone.accent,
  });

  final String? keyId;

  /// 标题前的图标（对齐 webUI sprite.svg 的 8 个指标图标）
  final IconData? icon;
  final String label;
  final String value;
  final String? sub;
  final List<double> series;

  /// sparkline 纵轴上限（0 = 自动取序列最大值）
  final double top;
  final double? warnOver;

  /// 折线色调（对齐 webUI data-tone）
  final _MetricTone tone;

  @override
  Widget build(BuildContext context) {
    final t = context.trae;
    final warn = warnOver != null &&
        series.isNotEmpty &&
        series.last > warnOver!;

    // 折线色：warn 优先（超过阈值转警告色），否则按 tone
    final Color lineColor = warn
        ? t.warn
        : switch (tone) {
            _MetricTone.warn => t.warn,
            _MetricTone.info => t.info,
            _MetricTone.accent => t.accent,
          };

    return Card(
      key: keyId == null ? null : Key('metric_$keyId'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: t.muted),
                  const SizedBox(width: 5),
                ],
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                        fontSize: TraeTokens.fontXs,
                        fontWeight: FontWeight.w600,
                        color: t.muted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: TextStyle(
                  fontSize: TraeTokens.fontStat * 0.62,
                  fontWeight: FontWeight.w700,
                  color: warn ? t.warnText : t.ink,
                ),
              ),
            ),
            if (sub != null) ...[
              const SizedBox(height: 2),
              Text(sub!,
                  style: TextStyle(
                      fontSize: TraeTokens.fontXs, color: t.muted)),
            ],
            const SizedBox(height: TraeTokens.gapSm),
            SizedBox(
              height: 32,
              child: CustomPaint(
                size: const Size(double.infinity, 32),
                painter: SparklinePainter(
                  data: series,
                  top: top,
                  lineColor: lineColor,
                  fillColor: lineColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Speed 卡：Decode / Prefill 双值双线（app.js metric-speed 特有结构）
class _SpeedCard extends StatelessWidget {
  const _SpeedCard({
    required this.tokS,
    required this.prefillTokS,
    required this.decodeHistory,
    required this.prefillHistory,
  });

  final double? tokS;
  final double? prefillTokS;
  final List<double> decodeHistory;
  final List<double> prefillHistory;

  @override
  Widget build(BuildContext context) {
    final t = context.trae;
    // webUI prefill 副线用 color-mix(accent 65%, black) ≈ #0A744D（app.css:95）
    final prefillColor = Color.lerp(t.accent, Colors.black, 0.35)!;
    return Card(
      key: const Key('metric_speed'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.speed, size: 14, color: t.muted),
                const SizedBox(width: 5),
                Text('Speed',
                    style: TextStyle(
                        fontSize: TraeTokens.fontXs,
                        fontWeight: FontWeight.w600,
                        color: t.muted)),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  tokS == null ? '–' : fmtNum(tokS, 1),
                  key: const Key('speed_decode'),
                  style: TextStyle(
                    fontSize: TraeTokens.fontStat * 0.7,
                    fontWeight: FontWeight.w700,
                    color: t.ink,
                  ),
                ),
                const SizedBox(width: 4),
                Text('tok/s decode', style: TextStyle(fontSize: TraeTokens.fontXs, color: t.muted)),
                const Spacer(),
                Text(
                  prefillTokS == null ? '–' : fmtNum(prefillTokS, 0),
                  key: const Key('speed_prefill'),
                  style: TextStyle(
                    fontSize: TraeTokens.fontStat * 0.5,
                    fontWeight: FontWeight.w700,
                    color: t.inkSoft,
                  ),
                ),
                const SizedBox(width: 4),
                Text('tok/s prefill', style: TextStyle(fontSize: TraeTokens.fontXs, color: t.muted)),
              ],
            ),
            const SizedBox(height: TraeTokens.gapSm),
            SizedBox(
              height: 32,
              child: CustomPaint(
                size: const Size(double.infinity, 32),
                painter: SparklinePainter(
                  data: decodeHistory,
                  lineColor: t.accent,
                  fillColor: t.accent,
                ),
              ),
            ),
            if (prefillHistory.isNotEmpty) ...[
              const SizedBox(height: 2),
              SizedBox(
                height: 20,
                child: CustomPaint(
                  size: const Size(double.infinity, 20),
                  painter: SparklinePainter(
                    data: prefillHistory,
                    lineColor: prefillColor,
                    fillColor: prefillColor,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// sparkline 画笔：viewBox 0 0 100 32 映射；y = 30 − (x/top)×26；
/// 折线 + 12% 不透明度面积填充（app.js sparkPath 同款）
///
/// v0.0.10 对齐 webUI：补 round cap/join（stroke-linejoin/linecap=round）
/// 与非等比缩放下的线宽补偿（vector-effect="non-scaling-stroke"）。
class SparklinePainter extends CustomPainter {
  SparklinePainter({
    required this.data,
    required this.lineColor,
    required this.fillColor,
    this.top = 0,
  });

  final List<double> data;

  /// 0 = 自动取 max(data)（全 0 时取 1 防除零）
  final double top;
  final Color lineColor;
  final Color fillColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final maxV = top > 0 ? top : (data.reduce((a, b) => a > b ? a : b));
    final scale = maxV > 0 ? maxV : 1.0;

    // viewBox 0 0 100 32 → 实际尺寸等比缩放（x 满宽，y 32 逻辑高）
    final sx = size.width / 100;
    final sy = size.height / 32;

    Offset pt(int i) {
      final x = i * 100.0 / (data.length - 1);
      final y = 30 - (data[i] / scale) * 26;
      return Offset(x * sx, y.clamp(2, 30) * sy);
    }

    final line = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < data.length; i++) {
      line.lineTo(pt(i).dx, pt(i).dy);
    }

    final fill = Path.from(line)
      ..lineTo(pt(data.length - 1).dx, 32 * sy)
      ..lineTo(pt(0).dx, 32 * sy)
      ..close();

    final fillPaint = Paint()
      ..color = fillColor.withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;
    canvas.drawPath(fill, fillPaint);

    // non-scaling-stroke：x/y 独立缩放时线宽保持 1.6 视觉像素，
    // 否则窄屏上线宽会被 sx 拉伸成粗线。
    final linePaint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 / sx
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(line, linePaint);
  }

  @override
  bool shouldRepaint(SparklinePainter old) =>
      old.data != data ||
      old.top != top ||
      old.lineColor != lineColor ||
      old.fillColor != fillColor;
}

// ─────────────────────────────────────────────────────────────
// context 环形仪表（270° 弧）
// ─────────────────────────────────────────────────────────────

/// Context fill 卡（对齐 webUI .ctx-card）
///
/// webUI 结构：标题 → 居中环形仪表（150×150，数值在**圆心内**）→
/// 三条横条（Experts in VRAM / System RAM / GPU temperature）。
/// v0.0.10 之前 App 是左右布局、数值在仪表外，且缺 GPU 温度条。
class _ContextGaugeCard extends StatelessWidget {
  const _ContextGaugeCard({required this.snapshot});

  final MetricsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final t = context.trae;
    final frac = snapshot.contextFraction;
    final used = snapshot.contextUsed;
    final max = snapshot.engine.maxContext;
    final hw = snapshot.hardware;
    final eng = snapshot.engine;

    // Experts in VRAM：expert_cache_mib 折算字节 / VRAM 总量
    final cacheBytes = (eng.expertCacheMib ?? 0) * 1048576;
    final slotsFrac = (hw.gpuMemTotal == null || hw.gpuMemTotal! <= 0)
        ? 0.0
        : (cacheBytes / hw.gpuMemTotal!).clamp(0.0, 1.0);
    final slotsText = eng.expertSlots == null
        ? '–'
        : '${fmtNum(eng.expertSlots)} · ${gb(cacheBytes)} GB';

    // System RAM：>92% 转 danger（app.js:337）
    final ramFrac = hw.ramFraction ?? 0;
    final ramText = hw.ramTotal == null
        ? '–'
        : '${gb(hw.ramUsed)} / ${gb(hw.ramTotal!, 0)} GB';

    // GPU temperature：0–100 映射
    final tempFrac = hw.gpuTemp == null ? 0.0 : (hw.gpuTemp! / 100).clamp(0.0, 1.0);
    final tempText = hw.gpuTemp == null ? '–' : '${fmtNum(hw.gpuTemp)} °C';

    return Card(
      key: const Key('context_gauge'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Context fill', style: TraeText.sectionTitle(context)),
            const SizedBox(height: TraeTokens.gapMd),
            // 居中仪表（webUI .ctx-gauge：150×150，数值在圆心内）
            Center(
              child: SizedBox(
                width: 150,
                height: 150,
                child: CustomPaint(
                  painter: _GaugePainter(fraction: frac, color: t.accent, track: t.surface2),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${(frac * 100).round()}%',
                          key: const Key('gauge_pct'),
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            color: t.ink,
                          ),
                        ),
                        Text(
                          max == null ? '–' : '${kfmt(used)} / ${ctxfmt(max)}',
                          key: const Key('gauge_used'),
                          style: TextStyle(
                              fontSize: TraeTokens.fontXs, color: t.muted),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: TraeTokens.gapMd),
            _BarRow(
              keyId: 'bar_experts_vram',
              label: 'Experts in VRAM',
              start: slotsText,
              fraction: slotsFrac,
            ),
            const SizedBox(height: TraeTokens.gapSm),
            _BarRow(
              keyId: 'bar_system_ram',
              label: 'System RAM',
              start: ramText,
              fraction: ramFrac,
              // RAM >92% → danger
              tone: ramFrac > 0.92 ? _BarTone.danger : _BarTone.accent,
            ),
            const SizedBox(height: TraeTokens.gapSm),
            _BarRow(
              keyId: 'bar_gpu_temp',
              label: 'GPU temperature',
              start: tempText,
              fraction: tempFrac,
              tone: _BarTone.warn,
            ),
          ],
        ),
      ),
    );
  }
}

/// 横条色调（对齐 webUI data-tone）
enum _BarTone { accent, warn, danger }

/// 270° 环形仪表：起点 135°（左下），dasharray = 235.6×frac / 314.2
/// （SVG r=50、270° 弧长 = 2π×50×0.75 = 235.6；全圆 314.2 → frac 权重）
class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.fraction,
    required this.color,
    required this.track,
  });

  final double fraction;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(8, 8, size.width - 16, size.height - 16);
    const full = 2 * 3.141592653589793;

    // 轨道：270° 弧（与值弧同起点同长度）
    const start = 3.141592653589793 * 0.75; // 135°
    const sweepTotal = full * 0.75;
    canvas.drawArc(
      rect,
      start,
      sweepTotal,
      false,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round,
    );

    // 值弧：从 135° 起，扫 270°×fraction
    final sweep = sweepTotal * fraction.clamp(0.0, 1.0);
    // webUI app.js:328：近零弧隐藏（否则只会画出一个圆头）
    if (sweep * 50 >= 3) {
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 9
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.fraction != fraction || old.color != color || old.track != track;
}

// ─────────────────────────────────────────────────────────────
// RAM / VRAM / KV / expert 条卡
// ─────────────────────────────────────────────────────────────

class _MemoryBarsCard extends StatelessWidget {
  const _MemoryBarsCard({required this.snapshot});

  final MetricsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final hw = snapshot.hardware;
    final eng = snapshot.engine;

    return Card(
      key: const Key('memory_bars'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _BarRow(
              keyId: 'bar_ram',
              label: 'RAM',
              start: gb(hw.ramUsed),
              end: hw.ramTotal == null ? null : '${gb(hw.ramTotal, 0)} GB',
              fraction: hw.ramFraction,
            ),
            const SizedBox(height: TraeTokens.gapMd),
            _BarRow(
              keyId: 'bar_vram',
              label: 'VRAM',
              start: gb(hw.gpuMemUsed),
              end: hw.gpuMemTotal == null ? null : '${gb(hw.gpuMemTotal, 0)} GB',
              fraction: hw.vramFraction,
            ),
            const SizedBox(height: TraeTokens.gapMd),
            if (eng.kvResident != null)
              _BarRow(
                keyId: 'bar_kv',
                label: 'KV cache',
                start: '${fmtNum(eng.kvResident)} MiB resident',
                end: eng.kvLabel,
                fraction: hw.vramFraction,
              ),
            const SizedBox(height: TraeTokens.gapMd),
            if (eng.expertSlots != null)
              _BarRow(
                keyId: 'bar_expert',
                label: 'Experts',
                start: '${fmtNum(eng.expertSlots)} slots',
                end: gbFromMiB(eng.expertCacheMib, 1) == '–'
                    ? null
                    : '${gbFromMiB(eng.expertCacheMib, 1)} GB',
                fraction: null,
              ),
          ],
        ),
      ),
    );
  }
}

class _BarRow extends StatelessWidget {
  const _BarRow({
    required this.label,
    required this.start,
    this.end,
    this.fraction,
    this.keyId,
    this.tone = _BarTone.accent,
  });

  final String? keyId;
  final String label;
  final String start;
  final String? end;
  final double? fraction;

  /// 横条色调（对齐 webUI data-tone）
  final _BarTone tone;

  @override
  Widget build(BuildContext context) {
    final t = context.trae;
    final barColor = switch (tone) {
      _BarTone.warn => t.warn,
      _BarTone.danger => t.danger,
      _BarTone.accent => t.accent,
    };
    return Column(
      key: keyId == null ? null : Key(keyId!),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: TraeText.sectionTitle(context)),
            const Spacer(),
            Text('$start${end == null ? '' : ' / $end'}',
                style: TraeText.meta(context)),
          ],
        ),
        if (fraction != null) ...[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(TraeTokens.radiusPill),
            child: LinearProgressIndicator(
              value: fraction!.clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: t.surface2,
              valueColor: AlwaysStoppedAnimation(barColor),
            ),
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 请求表（9 列）
// ─────────────────────────────────────────────────────────────

class _RequestsCard extends ConsumerWidget {
  const _RequestsCard({required this.snapshot});

  final MetricsSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.trae;
    final reqs = snapshot.requests;
    final showAll = ref.watch(_showAllProvider);
    // webUI：服务器保留的总数（requests_kept），缺失时退回已收条数。
    final kept = snapshot.requestsKeptCount;
    // webUI 默认只显示 12 条，超过 12 条才出现「Show all (N)」。
    final visible = showAll ? reqs : reqs.take(12).toList();

    return Card(
      key: const Key('requests_card'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Recent requests', style: TraeText.sectionTitle(context)),
                ),
                if (kept > 12)
                  GestureDetector(
                    key: const Key('btn_show_all'),
                    onTap: () {
                      ref.read(_showAllProvider.notifier).state = !showAll;
                      ref.read(metricsProvider.notifier).showAll = !showAll;
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: TraeTokens.gapSm, vertical: 4),
                      decoration: BoxDecoration(
                        color: t.surface2,
                        borderRadius: BorderRadius.circular(TraeTokens.radiusSm),
                        border: Border.all(color: t.lineSoft),
                      ),
                      child: Text(
                        showAll ? 'Show fewer' : 'Show all ($kept)',
                        style: TextStyle(
                          fontSize: TraeTokens.fontXs,
                          fontWeight: FontWeight.w600,
                          color: t.ink,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: TraeTokens.gapSm),
            if (reqs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: TraeTokens.gapXl),
                child: Center(child: Text('No requests yet', style: TraeText.meta(context))),
              )
            else
              _RequestTable(rows: visible),
            if (reqs.isNotEmpty) ...[
              const SizedBox(height: TraeTokens.gapSm),
              Text(
                _totalsLine(snapshot.totals),
                key: const Key('req_totals'),
                style: TraeText.meta(context),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// webUI `renderTotals(totals)` 的等价摘要（app.js:368）。
  String _totalsLine(Totals totals) {
    final parts = <String>[];
    if (totals.requests != null) {
      parts.add('${fmtNum(totals.requests)} requests');
    }
    if (totals.promptTokens != null) {
      parts.add('${fmtNum(totals.promptTokens)} prompt tokens');
    }
    if (totals.reused != null && totals.reused! > 0) {
      parts.add('${fmtNum(totals.reused)} reused');
    }
    if (totals.outputTokens != null) {
      parts.add('${fmtNum(totals.outputTokens)} output tokens');
    }
    return parts.isEmpty ? '' : parts.join(' · ');
  }
}

final _showAllProvider = StateProvider<bool>((ref) => false);

/// webUI 的 `<table class="st-table">` 等价物：9 列，大写表头 + 横向滚动。
class _RequestTable extends StatelessWidget {
  const _RequestTable({required this.rows});

  final List<RequestRecord> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: 620,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _RequestHeaderRow(),
                for (final r in rows) _RequestRow(r: r),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RequestHeaderRow extends StatelessWidget {
  const _RequestHeaderRow();

  static const _labels = <String>[
    'Time',
    'Status',
    'Prompt',
    'Reused',
    'Output',
    'Prefill t/s',
    'Decode t/s',
    'VRAM hit rate',
    'Duration',
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.trae;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.lineSoft)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < _labels.length; i++) ...[
            if (i > 0) const SizedBox(width: TraeTokens.gapSm),
            Expanded(
              flex: _flexFor(i),
              child: Text(
                _labels[i].toUpperCase(),
                textAlign: i == 0 || i == 1 ? TextAlign.start : TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: t.muted,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Time / Status 列更宽，数值列等宽。
  static int _flexFor(int index) {
    if (index == 0) return 16;
    if (index == 1) return 20;
    return 15;
  }
}

class _RequestRow extends StatelessWidget {
  const _RequestRow({required this.r});

  final RequestRecord r;

  @override
  Widget build(BuildContext context) {
    final t = context.trae;
    final (fg, bg, dot) = switch (r.finish) {
      'stop' => (t.accentText, t.accentTint, t.accent),
      'length' => (t.infoText, t.infoTint, t.info),
      'cancel' => (t.warnText, t.warnTint, t.warn),
      'disconnect' => (t.warnText, t.warnTint, t.warn),
      'error' => (t.dangerText, t.dangerTint, t.danger),
      _ => (t.muted, t.surface2, t.muted),
    };

    final hit = r.hitRate == null
        ? '–'
        : '${fmtNum(r.hitRate! * 100, 1)}%'
            '${r.pcieShare != null ? ' +${fmtNum(r.pcieShare! * 100, 0)}% PCIe' : ''}';

    return Container(
      key: ValueKey('req_${r.time ?? ''}'),
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.lineSoft)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 16,
            child: Text(
              sinceStr(r.time),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: TraeTokens.fontXs, color: t.ink),
            ),
          ),
          const SizedBox(width: TraeTokens.gapSm),
          Expanded(
            flex: 20,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(TraeTokens.radiusPill),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TraeWidgets.statusDot(dot, size: 6),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        r.finishLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: fg,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: TraeTokens.gapSm),
          _num(context, fmtNum(r.promptTokens)),
          _num(context, fmtNum(r.reused)),
          _num(context, fmtNum(r.outputTokens)),
          _num(context, r.prefillTokS == null ? '–' : fmtNum(r.prefillTokS, 0)),
          _num(context, r.decodeTokS == null ? '–' : fmtNum(r.decodeTokS, 1)),
          _num(context, hit),
          _num(context, r.durationS == null ? '–' : '${fmtNum(r.durationS, 1)} s'),
        ],
      ),
    );
  }

  Widget _num(BuildContext context, String v) => Expanded(
        flex: 15,
        child: Text(
          v,
          textAlign: TextAlign.end,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: TraeTokens.fontXs, color: context.trae.ink),
        ),
      );
}

// ─────────────────────────────────────────────────────────────
// conversation_cache 卡
// ─────────────────────────────────────────────────────────────

class _ConvCacheCard extends StatelessWidget {
  const _ConvCacheCard({required this.cache});

  final ConversationCache cache;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('conv_cache_card'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Conversation cache', style: TraeText.sectionTitle(context)),
            const SizedBox(height: TraeTokens.gapSm),
            Text(
              '${fmtNum(cache.requestsReused)} of ${fmtNum(cache.requests)} requests reused',
              key: const Key('conv_reused'),
              style: TraeText.body(context),
            ),
            if (cache.slots != null) ...[
              const SizedBox(height: TraeTokens.gapSm),
              Text('Parked ${cache.parked ?? 0} / ${cache.slots} slots',
                  style: TraeText.body(context)),
            ],
            const SizedBox(height: TraeTokens.gapSm),
            Text(
              cache.bytes == null || cache.budgetMib == null
                  ? '–'
                  : '${gb(cache.bytes)} / ${gbFromMiB(cache.budgetMib)} GB',
              key: const Key('conv_memory'),
              style: TraeText.body(context),
            ),
            const Divider(height: TraeTokens.gapLg),
            _fact(context, 'Prompt tokens', fmtNum(cache.promptTokens)),
            _fact(context, 'Reused tokens', fmtNum(cache.reusedTokens)),
            _fact(context, 'Parks / restores / evictions',
                '${fmtNum(cache.parks)} / ${fmtNum(cache.restores)} / ${fmtNum(cache.evictions)}'),
            _fact(
                context,
                'Last event',
                cache.lastEvent == null
                    ? '–'
                    : '$cache.lastEvent · ${sinceStr(cache.lastAt)}'),
          ],
        ),
      ),
    );
  }

  Widget _fact(BuildContext context, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            // Expanded 允许长文本换行，避免窄屏（如 Last event 时间戳）溢出
            Expanded(child: Text(k, style: TraeText.meta(context))),
            const SizedBox(width: TraeTokens.gapMd),
            Expanded(
              child: Text(
                v,
                style: TraeText.body(context),
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
      );
}

// ─────────────────────────────────────────────────────────────
// totals 行
// ─────────────────────────────────────────────────────────────

class _TotalsRow extends StatelessWidget {
  const _TotalsRow({required this.totals});

  final Totals totals;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('totals_card'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Since start', style: TraeText.sectionTitle(context)),
            const SizedBox(height: TraeTokens.gapSm),
            Row(
              children: [
                _cell(context, 'Requests', fmtNum(totals.requests)),
                _cell(context, 'Prompt', kfmt(totals.promptTokens)),
                _cell(context, 'Reused', kfmt(totals.reused)),
                _cell(context, 'Output', kfmt(totals.outputTokens)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _cell(BuildContext context, String k, String v) => Expanded(
        child: Column(
          children: [
            Text(v,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: context.trae.ink)),
            Text(k, style: TraeText.meta(context)),
          ],
        ),
      );
}

// ─────────────────────────────────────────────────────────────
// MCP 卡（/mcp；404 → 隐藏）
// ─────────────────────────────────────────────────────────────

class _McpCard extends ConsumerWidget {
  const _McpCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mcp = ref.watch(mcpProvider);
    return mcp.maybeWhen(
      data: (info) {
        if (info.servers.isEmpty) return const SizedBox.shrink();
        final t = context.trae;
        return Card(
          key: const Key('mcp_card'),
          child: Padding(
            padding: const EdgeInsets.all(TraeTokens.gapLg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('MCP', style: TraeText.sectionTitle(context))),
                    Text('${info.readyCount}/${info.servers.length} ready',
                        key: const Key('mcp_ready'),
                        style: TraeText.meta(context)),
                  ],
                ),
                const SizedBox(height: TraeTokens.gapSm),
                for (final s in info.servers)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            TraeWidgets.statusDot(
                                s.isReady ? context.trae.success : context.trae.danger,
                                size: 8),
                            const SizedBox(width: TraeTokens.gapSm),
                            Expanded(child: Text(s.name, style: TraeText.body(context))),
                            Text(
                              '${s.transport} · ${s.tools.length} tools',
                              style: TraeText.meta(context),
                            ),
                          ],
                        ),
                        if (s.error != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 16, top: 3),
                            child: Text(
                              s.error!,
                              style: TextStyle(fontSize: 12, color: t.dangerText),
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

// ─────────────────────────────────────────────────────────────
// 降级：在线但无 /metrics（旧版服务器）
// ─────────────────────────────────────────────────────────────

class _LegacyBody extends ConsumerWidget {
  const _LegacyBody({required this.reason});

  final Object reason;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(monitorProvider);
    return snapshot.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _OfflineView(
        error: e is StrataException ? e : null,
        message: e is StrataException ? null : '未知错误：$e',
        webUiUrl: ref.watch(currentProfileProvider)?.baseUrl,
      ),
      data: (data) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: TraeTokens.gapMd),
            child: Text(
              _reasonText(context, ref),
              key: const Key('metrics_fallback_reason'),
              style: TraeText.meta(context),
            ),
          ),
          _AliveCard(latency: data.latency, health: data.health),
          const SizedBox(height: TraeTokens.gapMd),
          _ModelsCard(models: data.models),
          const SizedBox(height: TraeTokens.gapMd),
          const _InstalledModelsCard(),
        ],
      ),
    );
  }

  /// 【v0.0.7 真机反馈】旧文案对一切非 401/非断网错误都写「该服务器版本
  /// 不提供 /metrics」——但测试者同主机 webUI 的 #monitor 能正常加载，
  /// 说明真机上另有原因（版本差异/同源校验/响应结构变化），笼统的
  /// 「版本不提供」让问题无法定位。改为如实分型 + 带上请求地址与错误
  /// 摘要，下一轮反馈截图即可直接看出真实原因。
  String _reasonText(BuildContext context, WidgetRef ref) {
    final base = switch (reason) {
      StrataNotFoundException n => '（接口不存在：$n）',
      StrataServerErrorException s => '（主机返回 ${s.statusCode}：$s）',
      _ => '（$reason）'
    };
    return '详细监控数据加载失败$base。\n'
        '主机 ${ref.read(currentProfileProvider)?.baseUrl ?? ''} 的 webUI（#monitor）'
        '若能正常显示，请截图本页反馈——两条通道的差异信息能直接定位原因。\n'
        '以下为基础监控（来自 /health 与 /v1/models）。';
  }
}

/// 存活卡片：绿点在线 + 延迟 + health 详情（模型 / uptime）
class _AliveCard extends StatelessWidget {
  const _AliveCard({required this.latency, required this.health});

  final Duration latency;
  final dynamic health; // HealthInfo（字段按需取）

  @override
  Widget build(BuildContext context) {
    final uptime = health.uptimeSeconds as int?;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                TraeWidgets.statusDot(context.trae.success, size: 9),
                const SizedBox(width: TraeTokens.gapSm),
                Text('在线', style: TraeText.sectionTitle(context)),
                const Spacer(),
                Container(
                  key: const Key('latency_badge'),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: context.trae.surface2,
                    borderRadius: BorderRadius.circular(TraeTokens.radiusPill),
                  ),
                  child: Text(
                    '${latency.inMilliseconds} ms',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: context.trae.inkSoft),
                  ),
                ),
              ],
            ),
            const SizedBox(height: TraeTokens.gapMd),
            if (health.model != null)
              Text('当前模型：${health.model}', style: TraeText.body(context)),
            if (uptime != null)
              Text('已运行：${(uptime / 3600).toStringAsFixed(1)} 小时',
                  style: TraeText.body(context)),
          ],
        ),
      ),
    );
  }
}

/// 模型卡片（v0.0.6 扩展）
///
/// 【为什么改】真机反馈：监控页只显示「可用模型（1）」，用户以为主机只有一个
/// 模型。实际上 /v1/models 只回答「本进程正在服务的那一个模型」，
/// 主机装了几个模型它就只列一个。要答「主机上可以加载哪些模型」，
/// 得读主机安装目录里的运行配置（GET /models/installed）。
///
/// 所以本卡改名为「当前服务的模型」，并另加一张「已安装模型」卡：
/// 前者说明现在在跑什么，后者说明主机上有什么可换。
class _ModelsCard extends StatelessWidget {
  const _ModelsCard({required this.models});

  final List<dynamic> models;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
        children: [
            Text('当前服务的模型（${models.length}）',
                key: const Key('mon_models_current'),
                style: TraeText.sectionTitle(context)),
            const SizedBox(height: TraeTokens.gapSm),
            for (final m in models)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Icon(Icons.memory, size: 16, color: context.trae.accent),
                    const SizedBox(width: TraeTokens.gapSm),
                    Expanded(
                      child: Text(m.id as String, style: TraeText.body(context)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: TraeTokens.gapXs),
            Text('这是本进程正在服务的那一个模型（及其别名）。'
                '主机上已安装的其它模型见下一张卡。',
                style: TraeText.meta(context)),
          ],
        ),
      ),
    );
  }
}

/// 当前模型卡（在线态；v0.0.6 从 _LegacyBody 提升到 _MetricsBody）
///
/// 【为什么有这张卡】真机用户看的是 /metrics 在线视图——旧实现只在
/// /metrics 缺失的降级骨架里渲染模型卡，在线态反而看不到「现在跑的
/// 是哪个模型」。v0.0.6 起在线视图同样显示，语义与降级版一致。
class _CurrentModelCard extends StatelessWidget {
  const _CurrentModelCard({required this.model});

  final String? model;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前服务的模型',
                key: const Key('mon_models_current'),
                style: TraeText.sectionTitle(context)),
            const SizedBox(height: TraeTokens.gapSm),
            Row(
              children: [
                Icon(Icons.memory, size: 16, color: context.trae.accent),
                const SizedBox(width: TraeTokens.gapSm),
                Expanded(
                  child: Text(
                    model ?? '（未知）',
                    style: TraeText.body(context),
                    key: const Key('mon_models_current_name'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: TraeTokens.gapXs),
            Text('这是本进程正在服务的那一个模型。主机上已安装的其它模型见下一张卡。',
                style: TraeText.meta(context)),
          ],
        ),
      ),
    );
  }
}

/// 已安装模型卡（v0.0.6；GET /models/installed）
///
/// 与「当前服务的模型」的区别：这里列的是主机安装目录里全部可加载的模型。
/// 旧服务端没有该端点 → 404 → 提示升级，不显示成硬错误。
class _InstalledModelsCard extends ConsumerWidget {
  const _InstalledModelsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = ref.watch(installedModelsProvider);
    return Card(
      key: const Key('mon_installed_card'),
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
                  key: const Key('btn_mon_models_refresh'),
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
              error: (e, _) => _InstalledModelsErrorText(error: e),
              data: (list) => _InstalledModelsList(list: list),
            ),
          ],
        ),
      ),
    );
  }
}

class _InstalledModelsList extends StatelessWidget {
  const _InstalledModelsList({required this.list});

  final InstalledModels list;

  @override
  Widget build(BuildContext context) {
    if (list.models.isEmpty) {
      return Text('主机上没有读到已安装的模型。',
          key: const Key('mon_models_empty'), style: TraeText.meta(context));
    }
    final dir = list.installDir;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (dir != null && dir.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: TraeTokens.gapSm),
            child: Text('安装目录：$dir',
                key: const Key('mon_models_dir'), style: TraeText.meta(context)),
          ),
        for (final m in list.models)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Icon(
                  m.current ? Icons.play_circle : Icons.memory,
                  size: 16,
                  color: m.current ? context.trae.accent : context.trae.muted,
                ),
                const SizedBox(width: TraeTokens.gapSm),
                Expanded(
                  child: Text(m.name,
                      key: Key('mon_model_${m.id}'),
                      style: TraeText.body(context)),
                ),
                Text(m.current ? '服务中' : m.contextLabel,
                    style: TraeText.meta(context)),
              ],
            ),
          ),
        const SizedBox(height: TraeTokens.gapXs),
        Text('切换模型请到「控制」页。',
            style: TraeText.meta(context)),
      ],
    );
  }
}

class _InstalledModelsErrorText extends StatelessWidget {
  const _InstalledModelsErrorText({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    if (error is StrataNotFoundException) {
      return Text('当前主机版本没有「已安装模型清单」接口（404），'
          '主机升级后这里会列出全部可加载的模型。',
          key: const Key('mon_models_404'), style: TraeText.meta(context));
    }
    if (error is StrataUnauthorizedException) {
      return Text('主机要求 API Key 才能读取已安装模型清单。',
          key: const Key('mon_models_401'), style: TraeText.meta(context));
    }
    return Text('读取已安装模型清单失败：'
        '${describeStrataError(error as StrataException)}',
        key: const Key('mon_models_error'), style: TraeText.meta(context));
  }
}

/// 不可用降级视图：错误分型文案 + 「打开 WebUI」兜底
class _OfflineView extends StatelessWidget {
  const _OfflineView({
    required this.error,
    required this.message,
    required this.webUiUrl,
    this.icon = Icons.cloud_off,
    this.title = '监控不可用',
    this.showApiKeyCard = false,
  });

  final StrataException? error; // 二选一：结构化异常或原始文案
  final String? message;
  final String? webUiUrl;

  /// 故障语义图标（离线=云断开；401=钥匙）
  final IconData icon;

  /// 故障语义标题（离线=监控不可用；401=需要 API Key）
  final String title;

  /// 401 时就地渲染 API key 输入卡（故障态自带修复路径）
  final bool showApiKeyCard;

  Future<void> _openWebUi() async {
    if (webUiUrl == null) return;
    final uri = Uri.tryParse(webUiUrl!);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Exception {
      // 无浏览器等极端场景：静默失败（按钮存在性即降级入口，SPEC §10）
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = error != null ? describeStrataError(error!) : message!;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(TraeTokens.gapXl),
      children: [
        const SizedBox(height: 60),
        Icon(icon, size: 56, color: context.trae.danger),
        const SizedBox(height: TraeTokens.gapMd),
        Center(child: Text(title, style: TraeText.sectionTitle(context))),
        const SizedBox(height: TraeTokens.gapSm),
        Center(
          child: Text(
            text,
            key: const Key('monitor_error'),
            textAlign: TextAlign.center,
            style: TextStyle(color: context.trae.danger, fontSize: 13),
          ),
        ),
        const SizedBox(height: TraeTokens.gapXl),
        if (showApiKeyCard) ...[
          const ApiKeyCard(
            hint: '保存后本页指标会自动重新拉取，无需返回上页。',
          ),
          const SizedBox(height: TraeTokens.gapXl),
        ],
        if (webUiUrl != null)
          Center(
            child: FilledButton.icon(
              key: const Key('btn_open_webui'),
              onPressed: _openWebUi,
              icon: const Icon(Icons.open_in_new),
              label: Text('打开 WebUI（$webUiUrl）'),
            ),
          ),
      ],
    );
  }
}

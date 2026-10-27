// 监控状态 Provider（M1-7 骨架 → M2-2 完整版）：
// - monitorProvider：/health + /v1/models 组合快照（存活、当前模型、延迟）
// - metricsProvider：/metrics 完整树 1s 轮询（webUI monitor.js 同款节奏）
// - mcpProvider：/mcp 服务器树（MCP 卡；旧服务器 404 → 隐藏）
// - 轮询生命周期：页面可见时启动、不可见停止（UI 层 ref.onDispose /
//   TickerVisibleNotifier 驱动）；这里用 keepAlive 链接计数实现
//
// 降级策略：/metrics 404（旧版服务器无此端点）→ metricsProvider 落
// StrataNotFoundException，UI 显示 M1-7 骨架（存活卡 + 模型列表）。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/api_models.dart';
import '../models/metrics_snapshot.dart';
import '../models/strata_models.dart';
import '../services/strata_client.dart';
import 'connection_provider.dart';

/// 一次监控快照（health 往返延迟 + 模型列表）
class MonitorSnapshot {
  const MonitorSnapshot({
    required this.latency,
    required this.health,
    required this.models,
  });

  /// /health 请求往返耗时
  final Duration latency;
  final HealthInfo health;
  final List<ModelInfo> models;
}

final monitorProvider = FutureProvider.autoDispose<MonitorSnapshot>((ref) async {
  // 【v0.0.9】未建立连接时 strataClientProvider 会同步抛 StateError。
  // 放在 async 体内 watch：异常会被 FutureProvider 转成 AsyncError，
  // UI 渲染「未连接」而不是整页崩红屏。
  // （不能用 currentProfileProvider 预判 —— 测试里可以 override 掉
  //   strataClientProvider 注入假 client，此时并不存在真实 Profile。）
  final client = ref.watch(strataClientProvider); // 随当前 Profile 切换自动重拉

  final sw = Stopwatch()..start();
  final health = await client.health();
  sw.stop();

  // 健康的前提下再取模型列表（不健康时 health 已抛错，无需二次请求）
  final models = await client.listModels();

  return MonitorSnapshot(latency: sw.elapsed, health: health, models: models);
});

// ─────────────────────────────────────────────────────────────
// M2-2：/metrics 1s 轮询
// ─────────────────────────────────────────────────────────────

/// metrics 轮询 Provider。MonitorScreen 可见时调用 [MetricsPolling.activate]
/// 增加引用；页面销毁/不可见时 deactivate。无人订阅时停止 Timer。
final metricsProvider =
    NotifierProvider<MetricsPolling, AsyncValue<MetricsSnapshot>>(
  MetricsPolling.new,
);

class MetricsPolling extends Notifier<AsyncValue<MetricsSnapshot>> {
  Timer? _timer;
  int _refs = 0;
  bool _fetching = false;
  int _activeTask = 0; // 防重入：只认最新一次拉取

  @override
  AsyncValue<MetricsSnapshot> build() {
    ref.onDispose(() => _stop());
    return const AsyncValue<MetricsSnapshot>.loading();
  }

  /// 页面可见 / UI 需要数据时调用：启动轮询并立即拉一次
  void activate() {
    _refs++;
    if (_refs == 1) {
      _fetch();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _fetch());
    }
  }

  /// 页面不可见 / 销毁时调用
  void deactivate() {
    _refs = _refs > 0 ? _refs - 1 : 0;
    if (_refs == 0) _stop();
  }

  /// 手动刷新（下拉）：立即拉一次并等待落定
  Future<void> refresh() => _fetch(awaited: true);

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _fetch({bool awaited = false}) async {
    if (_fetching) return;
    // 【v0.0.9】未建立连接时 strataClientProvider 会抛 StateError。
    // 在这里拦住并转成 error 态 —— 否则异常会在轮询 Timer 的异步回调里
    // 抛出，变成未捕获异常（页面直接崩红屏）。
    final StrataClient client;
    try {
      client = ref.read(strataClientProvider);
    } on StateError catch (e) {
      state = AsyncValue<MetricsSnapshot>.error(e, StackTrace.current);
      return;
    }
    _fetching = true;
    final task = ++_activeTask;
    try {
      final snap = await client.metrics(allRequests: _showAll);
      if (task != _activeTask) return; // 已有更新的拉取，丢弃旧结果
      state = AsyncValue.data(snap);
    } catch (e, st) {
      if (task != _activeTask) return;
      // 首拉失败 → error；轮询中断开 → 保留最后成功数据（copyWithPrevious，
      // UI when(skipLoadingOnRefresh) 直接复用旧值，不上屏错误页）
      state = AsyncValue<MetricsSnapshot>.error(e, st).copyWithPrevious(state);
    } finally {
      _fetching = false;
    }
  }

  bool _showAll = false;

  /// 请求表 Show all 开关（webUI 同款：重新拉全量）
  set showAll(bool v) {
    if (_showAll == v) return;
    _showAll = v;
    _fetch();
  }
}

// ─────────────────────────────────────────────────────────────
// M2-2：/mcp（低频，一次性 FutureProvider）
// ─────────────────────────────────────────────────────────────

final mcpProvider = FutureProvider.autoDispose<McpInfo>((ref) async {
  final client = ref.watch(strataClientProvider);
  return client.mcp();
});

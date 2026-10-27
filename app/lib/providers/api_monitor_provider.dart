// 引擎控制 Provider（M2-7.1，对齐 webUI control() 的 load/unload）：
//
// - engineControlProvider：2s 轮询 /v1/status，作为「控制」页唯一数据源
// - 生命周期沿用 MetricsPolling 范式：页面可见 activate / 不可见 deactivate
//   （引用计数），无人订阅时停 Timer
// - Load/Unload：operating 锁 + inflight 屏蔽（webUI control() 同款），
//   操作完成后立即手动拉一次
//
// 【v0.0.9】原 M2-4 的 apiMonitorProvider / apiRequestDetailProvider 已随
// API Monitor 页面一并删除：该页依赖主机端 svc.api_monitor（默认关闭），
// 打开永远是「主机端未开启」空页，是旧版本迭代留下的冗余页。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/api_models.dart';
import '../services/strata_client.dart';
import 'connection_provider.dart';

// ─────────────────────────────────────────────────────────────
// M2-7.1 引擎控制（2026-10-27 真机反馈修复·缺陷 B）
//
// 控制页的职责是「模型加载/卸载」这类**引擎动作**，其状态源只有
// /v1/status（不需要主机开 svc.api_monitor）。而 apiMonitorProvider 把
// /v1/status 与 /api/requests 绑在一起：主机未开 api_monitor 时 /api/requests
// 返 404，整个快照变 error，Load/Unload 按钮随之消失——用户要的
// 「模型加载卸载」动作反而做不了。
//
// 故拆出独立的 engineControlProvider：只依赖 /v1/status，
// 不受 api_monitor 开关影响。
//
// 【v0.0.9】原 apiMonitorProvider / apiRequestDetailProvider 随 API Monitor
// 页面一并删除（该页 99% 概率是「主机端未开启」空页）。此处只保留
// engineControlProvider —— 控制页的唯一数据源。
// ─────────────────────────────────────────────────────────────

/// 引擎控制快照（只来自 /v1/status）
class EngineControlSnapshot {
  const EngineControlSnapshot({required this.status});

  final EngineStatus status;

  /// webUI control() 的按钮可用性口径：
  /// 已加载 → 只能卸载；未加载 → 只能加载；在途请求 > 0 → 只能卸载
  bool get canLoad => !status.loaded && (status.inFlight ?? 0) == 0;
  bool get canUnload => status.loaded;
}

/// 引擎控制：/v1/status 轮询 + Load/Unload 动作
final engineControlProvider =
    NotifierProvider<EngineControlPolling, AsyncValue<EngineControlSnapshot>>(
  EngineControlPolling.new,
);

class EngineControlPolling extends Notifier<AsyncValue<EngineControlSnapshot>> {
  Timer? _timer;
  int _refs = 0;
  bool _fetching = false;
  int _activeTask = 0;

  /// Load/Unload 进行中（期间按钮禁用；webUI operating 同款）
  bool operating = false;

  /// 上一次成功快照（跨 build() 重建保留）。
  ///
  /// 不能用 `state.valueOrNull` 代替：Riverpod 在 build() 期间读 state 会抛
  /// 「Tried to read the state of an uninitialized provider」。
  /// 用独立字段保存，重建时直接回填，避免 UI 闪回空骨架。
  EngineControlSnapshot? _last;

  /// 重建（Profile/key 变更）后需要补拉一次：build() 内置位，
  /// 由下一次 _fetch 消费（若当时正在拉取，则拉完再补一次）。
  bool _pendingRefetch = false;

  @override
  AsyncValue<EngineControlSnapshot> build() {
    ref.onDispose(() => _stop());
    // 【2026-10-27 真机反馈修复·缺陷 C 补充】watch client：
    // 用户在页内填入/更正 API key 后，currentProfileProvider 变化 →
    // strataClientProvider 重建 → 本 provider 随之重建并重新拉取。
    // 否则会出现「保存了 key 但控制页还是 401 死锁态」——
    // 与真机反馈原话「填写一次 api key …之后还是无法看到主机状态」一致。
    //
    // 【v0.0.9 修复】不能裸 watch(strataClientProvider)：
    // 未建立连接时它会**同步抛** StateError('尚未建立连接…')，而 provider
    // 的 build() 处于构建期 —— 异常会直接冒泡成未捕获的 widget 异常，
    // 「控制」页在未连接态会崩成红屏（v0.0.9 新增测试 HomeShell 时暴露）。
    // 这里用 try/catch 兜住：抛错 → 落 error 态，由 UI 渲染「未连接」引导页。
    // （不能用 currentProfileProvider 预判 —— 测试可以 override 掉
    //   strataClientProvider 注入假 client，此时并不存在真实 Profile。）
    try {
      ref.watch(strataClientProvider);
    } on StateError catch (e) {
      return AsyncValue<EngineControlSnapshot>.error(e, StackTrace.current);
    }
    // 重建后的补拉放在 listen 回调里，而不是在 build() 里直接发请求：
    // build() 处于构建期，此处发 HTTP 属于「构建期副作用」，且请求会在
    // 构建帧里启动，容易被后续帧的 loading 态覆盖。
    // listen 的 fireImmediately=false 保证只在 client 真正变化时补拉。
    ref.listen(strataClientProvider, (prev, next) {
      if (identical(prev, next)) return;
      _pendingRefetch = true;
      unawaited(_fetch());
    });
    // 保留上一次成功值：重建期间 UI 继续显示旧状态而非闪回空骨架
    final prev = _last;
    return prev == null
        ? const AsyncValue<EngineControlSnapshot>.loading()
        : AsyncValue<EngineControlSnapshot>.data(prev);
  }

  void activate() {
    _refs++;
    if (_refs == 1) {
      _fetch();
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _fetch());
    }
  }

  void deactivate() {
    _refs = _refs > 0 ? _refs - 1 : 0;
    if (_refs == 0) _stop();
  }

  /// 手动刷新（用户在页内改完 key / 主机后调用）：立即拉一次
  ///
  /// 与 listen 自动补拉并存：
  ///   - listen 兜底「外部改了 Profile（设置页/多 Profile 切换）」
  ///   - refresh() 服务「本页内保存 key」——保存动作与刷新在同一帧完成，
  ///     用户不用等下一个 2s tick
  Future<void> refresh() => _fetch();

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _fetch() async {
    if (_fetching) {
      // 正在拉取：置位补拉标记，本次拉完后立刻再拉一次
      // （Profile/key 变更正好撞上在途请求时用得上）
      _pendingRefetch = true;
      return;
    }
    // 本次拉取消费掉补拉标记（避免 finally 里重复再拉一次）
    _pendingRefetch = false;
    // 未建立连接时 strataClientProvider 会抛 StateError —— 在这里拦住，
    // 把它转成 error 态（UI 渲染「未连接」引导），而不是让轮询 Timer
    // 在异步回调里抛出未捕获异常。
    final StrataClient client;
    try {
      client = ref.read(strataClientProvider);
    } on StateError catch (e) {
      state = AsyncValue<EngineControlSnapshot>.error(e, StackTrace.current);
      return;
    }
    _fetching = true;
    final task = ++_activeTask;
    try {
      final status = await client.engineStatus();
      if (task != _activeTask) return;
      final snap = EngineControlSnapshot(status: status);
      _last = snap;
      state = AsyncValue.data(snap);
    } catch (e, st) {
      if (task != _activeTask) return;
      final prev = _last;
      state = prev != null
          ? AsyncValue<EngineControlSnapshot>.error(e, st)
              .copyWithPrevious(AsyncValue<EngineControlSnapshot>.data(prev))
          : AsyncValue<EngineControlSnapshot>.error(e, st);
    } finally {
      _fetching = false;
      if (_pendingRefetch) {
        _pendingRefetch = false;
        // 补拉：Profile/key 已变，用新 client 重取
        unawaited(_fetch());
      }
    }
  }

  /// POST /load
  Future<void> load() => _control(load: true);

  /// POST /unload（[waitSeconds] 透传 server `?wait=`）
  Future<void> unload({int? waitSeconds}) =>
      _control(load: false, waitSeconds: waitSeconds);

  Future<void> _control({required bool load, int? waitSeconds}) async {
    if (operating) return;
    final client = ref.read(strataClientProvider);
    operating = true;
    ref.notifyListeners();
    try {
      if (load) {
        await client.loadEngine();
      } else {
        await client.unloadEngine(waitSeconds: waitSeconds);
      }
    } finally {
      operating = false;
      ref.notifyListeners();
      await _fetch();
    }
  }
}

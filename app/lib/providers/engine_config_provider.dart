// 主机配置类端点的 Provider（M2-7.1，2026-10-27 真机反馈修复）
//
// 【为什么从 about_screen.dart 抽出来】
// `configProvider`（GET /config）与 `enginePropsProvider`（GET /props）原先定义在
// about_screen.dart 内部。新增的 ControlScreen 也需要 /props（引擎属性卡），
// 若直接 import about_screen.dart 就形成 screens→screens 的横向依赖，
// 容易在后续拆包时形成环。故上收到 providers/ 层，两页共用同一实例
// （autoDispose：无人订阅时自动释放，避免常驻轮询）。
//
// 对齐 webUI：app.js 的 fetch("config") / fetch("props")——同样需要鉴权头，
// 401 时落到 StrataUnauthorizedException，由 UI 就地给出补 key 入口。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/api_models.dart';
import 'connection_provider.dart';

/// /config 键值清单（进入页拉取一次 + 手动刷新）
final configProvider = FutureProvider.autoDispose<ConfigInfo>((ref) {
  return ref.watch(strataClientProvider).config();
});

/// /props 引擎属性（M2-7 只读；引擎未运行 503 → error → 隐藏卡）
final enginePropsProvider = FutureProvider.autoDispose<EngineProps>((ref) {
  return ref.watch(strataClientProvider).props();
});

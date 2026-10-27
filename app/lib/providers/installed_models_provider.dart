// 已安装模型清单 Provider（v0.0.6，2026-10-27 真机反馈）
//
// 【为什么要有这一层】真机反馈原话：
//   「模型加载和卸载功能虽然有了，但是并没有显示主机上可以加载哪些模型，
//     实际上测试连接的主机部署了多个模型」
// 根因不在 App：/v1/models 只回答「本进程正在服务的那一个模型（+它的别名）」，
// 主机部署了几个模型它就只列几个。真正能答「主机上可以加载哪些模型」的是
// 主机安装目录里的运行配置（strata-<model>.json），服务端已新增
// GET /models/installed 来读它。
//
// 【降级】旧服务端没有这个端点 → 404 → StrataNotFoundException。
// UI 据此退回「只显示当前服务中的模型」，不显示成硬错误：
// 主机没升级不是用户的错，是版本差异，要说清楚。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/api_models.dart';
import 'connection_provider.dart';

/// 已安装模型清单（GET /models/installed）
///
/// 404（旧服务端没有这个端点）→ 落 StrataNotFoundException，UI 降级显示
/// 「当前服务的模型」；其它错误（断连/401）照常上屏。
final installedModelsProvider =
    FutureProvider.autoDispose<InstalledModels>((ref) async {
  return ref.watch(strataClientProvider).installedModels();
});

/// 当前服务的模型（/v1/status），用于已安装清单降级时兜底
final currentModelProvider = FutureProvider.autoDispose<String?>((ref) async {
  final status = await ref.watch(strataClientProvider).engineStatus();
  return status.model;
});

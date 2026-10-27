// 连接相关 Provider（M1-5）：
// - secureStorageProvider / profilesProvider / currentProfileProvider：持久化与当前会话
// - strataClientProvider：由当前 Profile 派生（M1-6 ChatScreen 消费）
// - ConnectionController：ConnectionScreen 表单状态 + 测试连接（分型错误）+ 保存
//
// 测试连接直接用表单临时值构造 StrataClient（未保存即可测），
// 按 SPEC §6.1.4 把 StrataException 分型转成用户可读文案。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/connection_profile.dart';
import '../models/strata_models.dart';
import '../services/secure_storage_service.dart';
import '../services/strata_client.dart';

final secureStorageProvider = Provider<SecureStorageService>((_) => SecureStorageService());

/// 当前激活 Profile id 持久化 key（shared_preferences；仅存 id 非敏感，
/// Profile 全量数据在 secure_storage——SPEC §9 / ADR-5 数据分层）
const kActiveProfileIdKey = 'active_profile_id';

/// SharedPreferences 注入点：main() 生产初始化后 override；测试注入 mock 实例
final sharedPrefsProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('main() 中需先 SharedPreferences.getInstance() 并 override');
});

/// 已保存的 Profile 列表（启动时读取；保存后 invalidate 刷新）
final profilesProvider = FutureProvider.autoDispose<List<ConnectionProfile>>((ref) {
  return ref.watch(secureStorageProvider).loadProfiles();
});

/// 当前激活的连接（内存态；App 冷启动取列表第一个，M1-8 多 Profile 可切换）
final currentProfileProvider = StateProvider<ConnectionProfile?>((_) => null);

/// 顶层页面索引（M1-11 UI 改版：取消底部 Tab 后，顶栏入口是唯一导航载体，
/// 因此导航状态必须放到 provider 里，页面才能在 AppBar 中触发切换）。
/// v0.0.9 起为 5 页：0=对话 1=监控 2=控制 3=关于 4=设置
/// （常量定义见 screens/home_shell.dart 的 `TopNav`，勿在此处硬编码字面量）
final topNavIndexProvider = StateProvider<int>((_) => 0);

/// 启动恢复激活 Profile（M1-8）：优先持久化激活 id，失效或无记录回退首项；
/// 空列表返回 null（未连接态）。纯函数，main() 调用后经 overrideWith 注入。
ConnectionProfile? resolveStartupProfile(List<ConnectionProfile> list, String? savedActiveId) {
  if (list.isEmpty) return null;
  for (final p in list) {
    if (p.id == savedActiveId) return p;
  }
  return list.first;
}

/// 由当前 Profile 派生的客户端（无 Profile 时抛错——UI 保证先完成连接）
final strataClientProvider = Provider<StrataClient>((ref) {
  final profile = ref.watch(currentProfileProvider);
  if (profile == null) {
    throw StateError('尚未建立连接：请先在 ConnectionScreen 保存并激活 Profile');
  }
  return StrataClient(baseUrl: profile.baseUrl, apiKey: profile.apiKey);
});

/// 测试连接结果（sealed，UI 按型渲染）
sealed class TestStatus {
  const TestStatus();
}

class TestIdle extends TestStatus {
  const TestIdle();
}

class TestInProgress extends TestStatus {
  const TestInProgress();
}

class TestSuccess extends TestStatus {
  const TestSuccess(this.modelsDesc);

  final String modelsDesc; // 逗号分隔的模型 ID

  @override
  String toString() => 'TestSuccess($modelsDesc)';
}

class TestFailure extends TestStatus {
  const TestFailure(this.message);

  final String message; // 已按异常分型转写的用户可读文案

  @override
  String toString() => 'TestFailure($message)';
}

class ConnectionFormState {
  const ConnectionFormState({
    this.name = '',
    this.host = '',
    this.port = '8080',
    this.apiKey = '',
    this.testStatus = const TestIdle(),
  });

  final String name;
  final String host;
  final String port;
  final String apiKey;
  final TestStatus testStatus;

  ConnectionFormState copyWith({
    String? name,
    String? host,
    String? port,
    String? apiKey,
    TestStatus? testStatus,
  }) =>
      ConnectionFormState(
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        apiKey: apiKey ?? this.apiKey,
        testStatus: testStatus ?? this.testStatus,
      );
}

/// StrataException → 用户可读文案（SPEC §6.1.4）
String describeStrataError(StrataException e) => switch (e) {
      StrataConnectionException _ => '连接失败：请确认服务已启动、手机与主机在同一网络（推荐 WireGuard 隧道）',
      StrataUnauthorizedException _ => 'API Key 缺失或错误（401）：请核对服务端 --api-key',
      StrataServerErrorException _ => '引擎异常（5xx）：服务端返回错误，稍后重试',
      StrataIdleTimeoutException _ => '响应超时：服务长时间无数据返回',
      StrataBadRequestException _ => '请求参数非法（400）：${e.message}',
      StrataNotFoundException _ => '接口不存在（404）：请确认服务端版本',
      StrataUnexpectedException _ => '未知错误：${e.message}',
    };

class ConnectionController extends Notifier<ConnectionFormState> {
  /// 编辑中的 Profile id（null = 新增模式，M1-8）
  String? _editingId;
  DateTime? _editingCreatedAt;

  @override
  ConnectionFormState build() => const ConnectionFormState();

  /// 进入页面时重置表单（避免跨页面残留）
  void reset() {
    _editingId = null;
    _editingCreatedAt = null;
    state = const ConnectionFormState();
  }

  /// 编辑已有 Profile：预填表单（M1-8）
  void startEditing(ConnectionProfile p) {
    _editingId = p.id;
    _editingCreatedAt = p.createdAt;
    state = ConnectionFormState(
      name: p.name,
      host: p.host,
      port: p.port.toString(),
      apiKey: p.apiKey ?? '',
    );
  }

  void setName(String v) => state = state.copyWith(name: v);
  void setHost(String v) => state = state.copyWith(host: v, testStatus: const TestIdle());
  void setPort(String v) => state = state.copyWith(port: v, testStatus: const TestIdle());
  void setApiKey(String v) => state = state.copyWith(apiKey: v, testStatus: const TestIdle());

  /// 用表单临时值直连 /v1/models（无需先保存）
  ///
  /// 【2026-10-27 真机反馈修复·缺陷 C】原来只测 /v1/models，而 App 的
  /// 监控/About/控制全依赖 /metrics。真机反馈「填了 api key 和主机地址端口
  /// 之后还是看不到主机状态」——用户点「测试连接」看到成功就以为 key 有效，
  /// 但 App 真正用的受保护端点并没有被验证过。现在两个端点都测：
  /// 任一失败即判失败，并把真实原因（401 缺 key / 主机不可达）写进文案。
  Future<void> testConnection() async {
    state = state.copyWith(testStatus: const TestInProgress());
    final port = int.tryParse(state.port) ?? 8080;
    final client = StrataClient(baseUrl: 'http://${state.host}:$port', apiKey: state.apiKey);
    try {
      final models = await client.listModels();
      // /metrics 是 App 监控/About/控制页的共同数据源，必须一并验证。
      await client.metrics();
      state = state.copyWith(
        testStatus: TestSuccess(models.map((ModelInfo m) => m.id).join(', ')),
      );
    } on StrataException catch (e) {
      state = state.copyWith(testStatus: TestFailure(describeStrataError(e)));
    } finally {
      client.close();
    }
  }

  /// 保存 Profile：编辑模式更新同 id 项（激活项同步刷新），新增模式追加并激活。
  /// 返回 false 表示表单非法（不保存）。
  Future<bool> save() async {
    final port = int.tryParse(state.port);
    if (state.name.isEmpty || state.host.isEmpty || port == null || port < 1 || port > 65535) {
      return false;
    }
    final storage = ref.read(secureStorageProvider);
    final profiles = await storage.loadProfiles();

    if (_editingId != null) {
      // 编辑：保留 id/createdAt，替换同 id 项
      final updated = ConnectionProfile(
        id: _editingId!,
        name: state.name,
        host: state.host,
        port: port,
        apiKey: state.apiKey.isEmpty ? null : state.apiKey,
        createdAt: _editingCreatedAt ?? DateTime.now(),
      );
      await storage.saveProfiles([
        for (final p in profiles)
          if (p.id == _editingId) updated else p,
      ]);
      if (ref.read(currentProfileProvider)?.id == _editingId) {
        ref.read(currentProfileProvider.notifier).state = updated;
        await ref.read(sharedPrefsProvider).setString(kActiveProfileIdKey, updated.id);
      }
      ref.invalidate(profilesProvider);
      return true;
    }

    // 新增：追加并激活（M1-5 行为）+ 持久化激活 id
    final profile = ConnectionProfile(
      id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      name: state.name,
      host: state.host,
      port: port,
      apiKey: state.apiKey.isEmpty ? null : state.apiKey,
      createdAt: DateTime.now(),
    );
    await storage.saveProfiles([...profiles, profile]);
    ref.read(currentProfileProvider.notifier).state = profile;
    await ref.read(sharedPrefsProvider).setString(kActiveProfileIdKey, profile.id);
    ref.invalidate(profilesProvider);
    return true;
  }
}

/// 多 Profile 管理（M1-8）：激活切换 / 删除（删除激活项时回退到剩余首项并同步持久化）
class ProfileAdminController extends Notifier<void> {
  @override
  void build() {}

  Future<void> activate(ConnectionProfile p) async {
    ref.read(currentProfileProvider.notifier).state = p;
    await ref.read(sharedPrefsProvider).setString(kActiveProfileIdKey, p.id);
  }

  Future<void> delete(ConnectionProfile p) async {
    final storage = ref.read(secureStorageProvider);
    final list = (await storage.loadProfiles())..removeWhere((e) => e.id == p.id);
    await storage.saveProfiles(list);
    ref.invalidate(profilesProvider);

    // 删除的是激活项：回退到剩余首项；列表清空则回到未连接态
    if (ref.read(currentProfileProvider)?.id == p.id) {
      final next = list.isEmpty ? null : list.first;
      ref.read(currentProfileProvider.notifier).state = next;
      final prefs = ref.read(sharedPrefsProvider);
      if (next != null) {
        await prefs.setString(kActiveProfileIdKey, next.id);
      } else {
        await prefs.remove(kActiveProfileIdKey);
      }
    }
  }

  /// 更新激活 Profile 的 API key（M2-3 About 页）：
  /// 持久化 + 刷新 currentProfileProvider（strataClientProvider 随之重建带新 header）。
  Future<void> updateApiKey(String? apiKey) async {
    final current = ref.read(currentProfileProvider);
    if (current == null) return;
    final updated = ConnectionProfile(
      id: current.id,
      name: current.name,
      host: current.host,
      port: current.port,
      apiKey: (apiKey == null || apiKey.isEmpty) ? null : apiKey,
      useWireGuardOnly: current.useWireGuardOnly,
      createdAt: current.createdAt,
    );
    final storage = ref.read(secureStorageProvider);
    final profiles = await storage.loadProfiles();
    await storage.saveProfiles([
      for (final p in profiles)
        if (p.id == current.id) updated else p,
    ]);
    ref.read(currentProfileProvider.notifier).state = updated;
    ref.invalidate(profilesProvider);
  }
}

final profileAdminControllerProvider =
    NotifierProvider<ProfileAdminController, void>(ProfileAdminController.new);

final connectionControllerProvider =
    NotifierProvider<ConnectionController, ConnectionFormState>(ConnectionController.new);

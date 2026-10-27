// ConnectionScreen（M1-5 / P2-4）：连接配置表单。
// 校验：名称/主机/端口必填与格式；私网（WireGuard 常见网段）给出提示性信息（不阻断）。
// 「测试连接」用表单临时值调 /v1/models，结果按异常分型展示；
// 「保存并进入」写入 secure_storage 并跳转主页骨架（M1-6 起填充各页）。
// M1-8：editingProfile 非空为编辑模式——预填表单，保存后 pop 回设置页。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/connection_profile.dart';
import '../providers/connection_provider.dart';
import '../providers/monitor_provider.dart';
import '../theme/trae_theme.dart';
import 'connection_guide_screen.dart';
import 'home_shell.dart';

/// 主机格式校验：IPv4（各段 ≤255）或常见主机名
String? validateHost(String? v) {
  final value = (v ?? '').trim();
  if (value.isEmpty) return '必填';
  final ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
  final hostname = RegExp(r'^[a-zA-Z0-9]([a-zA-Z0-9\-.]*[a-zA-Z0-9])?$');
  if (ipv4.hasMatch(value)) {
    final octets = value.split('.').map(int.parse).toList();
    if (octets.any((o) => o > 255)) return 'IPv4 地址段超界（0–255）';
    return null;
  }
  if (hostname.hasMatch(value)) return null;
  return '格式应为 IPv4 或主机名';
}

/// 端口校验：1–65535
String? validatePort(String? v) {
  final value = (v ?? '').trim();
  if (value.isEmpty) return '必填';
  final port = int.tryParse(value);
  if (port == null) return '必须是数字';
  if (port < 1 || port > 65535) return '范围 1–65535';
  return null;
}

String? validateName(String? v) =>
    (v ?? '').trim().isEmpty ? '必填' : null;

/// 私网/WireGuard 常见网段（10/8、172.16–31、192.168/16）：提示而非阻断
bool isPrivateNetwork(String host) {
  final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(host);
  if (m == null) return false;
  final a = int.parse(m.group(1)!);
  final b = int.parse(m.group(2)!);
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}

class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({super.key, this.editingProfile});

  /// 非空 = 编辑该 Profile（预填表单）；null = 新增模式
  final ConnectionProfile? editingProfile;

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  final _formKey = GlobalKey<FormState>();

  // 注意：表单预填（startEditing/reset）由跳转方在 push 前调用——
  // Riverpod 禁止在 initState/build 生命周期内修改 provider 状态。

  @override
  Widget build(BuildContext context) {
    final form = ref.watch(connectionControllerProvider);
    final controller = ref.read(connectionControllerProvider.notifier);
    final testStatus = form.testStatus;
    final isEditing = widget.editingProfile != null;

    return Scaffold(
      backgroundColor: context.trae.bg,
      appBar: AppBar(
        titleSpacing: TraeTokens.gapLg,
        title: Text(
          isEditing ? '编辑连接' : '连接本地模型主机',
          style: TraeText.pageTitle(context),
        ),
        actions: [
          IconButton(
            key: const Key('btn_open_guide'),
            icon: const Icon(Icons.help_outline),
            tooltip: '连接指南',
            color: context.trae.inkSoft,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ConnectionGuideScreen()),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(TraeTokens.gapLg),
          children: [
            TextFormField(
              key: const Key('field_name'),
              initialValue: form.name,
              decoration: const InputDecoration(
                labelText: '配置名称',
                hintText: '如：客厅主机',
              ),
              validator: validateName,
              onChanged: controller.setName,
            ),
            const SizedBox(height: TraeTokens.gapMd),
            TextFormField(
              key: const Key('field_host'),
              initialValue: form.host,
              decoration: const InputDecoration(
                labelText: '主机地址',
                hintText: 'WireGuard 虚拟 IP（如 10.0.0.2）或主机名',
              ),
              validator: validateHost,
              onChanged: controller.setHost,
              keyboardType: TextInputType.url,
            ),
            if (form.host.trim().isNotEmpty && isPrivateNetwork(form.host.trim()))
              Padding(
                padding: const EdgeInsets.only(top: TraeTokens.gapSm),
                child: Row(
                  key: const Key('wg_hint'),
                  children: [
                    Icon(Icons.vpn_lock_outlined,
                        size: 18, color: context.trae.accent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '内网/WireGuard 网段地址（推荐经隧道访问）',
                        style: TextStyle(color: context.trae.accent, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: TraeTokens.gapMd),
            TextFormField(
              key: const Key('field_port'),
              initialValue: form.port,
              decoration: const InputDecoration(
                labelText: '端口',
                hintText: 'Strata 默认 8080',
              ),
              validator: validatePort,
              onChanged: controller.setPort,
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: TraeTokens.gapMd),
            TextFormField(
              key: const Key('field_apikey'),
              initialValue: form.apiKey,
              decoration: const InputDecoration(
                labelText: 'API Key（可选）',
                helperText: '服务端 --api-key 启动时必填；仅存本机安全存储',
              ),
              onChanged: controller.setApiKey,
              obscureText: true,
            ),
            const SizedBox(height: TraeTokens.gapSm),
            switch (testStatus) {
              TestIdle() => const SizedBox.shrink(),
              TestInProgress() => Padding(
                  padding: const EdgeInsets.symmetric(vertical: TraeTokens.gapSm),
                  child: Row(children: [
                    SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: context.trae.muted)),
                    const SizedBox(width: TraeTokens.gapSm),
                    Text('正在连接…', style: TextStyle(color: context.trae.muted)),
                  ]),
                ),
              TestSuccess(:final modelsDesc) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: TraeTokens.gapSm),
                  child: Row(
                    key: const Key('test_ok'),
                    children: [
                      Icon(Icons.check_circle, color: context.trae.success, size: 18),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text('连接成功，模型：$modelsDesc',
                            style: TextStyle(color: context.trae.success)),
                      ),
                    ],
                  ),
                ),
              TestFailure(:final message) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: TraeTokens.gapSm),
                  child: Row(
                    key: const Key('test_fail'),
                    children: [
                      Icon(Icons.error_outline, color: context.trae.danger, size: 18),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(message,
                            style: TextStyle(color: context.trae.danger)),
                      ),
                    ],
                  ),
                ),
            },
            const SizedBox(height: TraeTokens.gapSm),
            OutlinedButton.icon(
              key: const Key('btn_test'),
              onPressed: () => controller.testConnection(),
              icon: const Icon(Icons.wifi_tethering),
              label: const Text('测试连接'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const Key('btn_save'),
              onPressed: () async {
                final navigator = Navigator.of(context); // await 前同步捕获
                if (!_formKey.currentState!.validate()) return;
                final ok = await controller.save();
                if (!mounted || !ok) return;
                // 【2026-10-27 真机反馈修复·缺陷 C】保存（首填 / 改 key）后，
                // 此前因 401 失败的 /metrics 快照必须重拉，否则用户会看到
                // 「保存成功但监控页仍是旧状态」。metricsProvider 是常驻
                // NotifierProvider（build 不 watch client），不会因 Profile
                // 变更自动重来，此处显式失效。
                ref.invalidate(metricsProvider);
                if (isEditing) {
                  navigator.pop(); // 编辑模式：回设置页
                } else {
                  await navigator.pushReplacement(
                    MaterialPageRoute(builder: (_) => const HomeShell()),
                  );
                }
              },
              icon: const Icon(Icons.arrow_forward),
              label: Text(isEditing ? '保存修改' : '保存并进入'),
            ),
          ],
        ),
      ),
    );
  }
}

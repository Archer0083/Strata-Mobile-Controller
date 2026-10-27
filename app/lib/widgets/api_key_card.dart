// ApiKeyCard（2026-10-27 真机反馈修复·缺陷 C 抽出为共享组件）
//
// 【为什么抽出】原 `_ApiKeyCard` 是 about_screen.dart 的私有类，只挂在
// `_AboutBody`（需要 /metrics 成功才渲染）。真机反馈「填了一次 api key
// 和主机地址端口之后还是无法看到主机状态」的根因是**故障态没有修复入口**：
//   缺 key → /metrics 401 → About 渲染空态 → 空态不含 key 卡片 → 死锁。
// 而监控页、控制页同样可能在 401 态把用户挡在门外。三处都要能就地补 key，
// 故抽成共享组件：保存后统一失效 /metrics 等数据源，
// 让「保存 key → 数据立刻回来」在任意页成立。
//
// webUI 对应：app.js 的 api-key 输入 + localStorage('apikey')；
// App 侧改为存 Profile（secure storage / Keystore），见 connection_provider。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/connection_provider.dart';
import '../providers/monitor_provider.dart';
import '../theme/trae_theme.dart';

/// API key 管理卡（对齐 webUI api-key 输入；存 Profile 而非浏览器 store）
class ApiKeyCard extends ConsumerStatefulWidget {
  const ApiKeyCard({super.key, this.hint, this.onSaved, this.fieldKey});

  /// 可选的补充说明（如「无需返回上页」）
  final String? hint;

  /// 保存/清除后额外回调（供调用方失效自己持有的 provider，
  /// 如 About 页的 /config 与 /props —— 避免 widgets→screens 反向依赖）
  final VoidCallback? onSaved;

  /// 输入框的 Key。默认沿用 About 页历史名 `field_about_apikey`；
  /// 同一页面可能同时出现多张卡片（如监控页与 About 页的 401 空态），
  /// 调用方可传不同 Key 以免测试定位到错误的那一张。
  final Key? fieldKey;

  @override
  ConsumerState<ApiKeyCard> createState() => _ApiKeyCardState();
}

class _ApiKeyCardState extends ConsumerState<ApiKeyCard> {
  late final TextEditingController _controller;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
        text: ref.read(currentProfileProvider)?.apiKey ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('api_key_card'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('API key', style: TraeText.sectionTitle(context)),
            const SizedBox(height: TraeTokens.gapSm),
            Text(widget.hint ??
                '保存在手机安全存储（Keystore），仅在请求头携带；留空表示无鉴权。',
                style: TraeText.meta(context)),
            const SizedBox(height: TraeTokens.gapMd),
            TextField(
              key: widget.fieldKey ?? const Key('field_about_apikey'),
              controller: _controller,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.password],
              decoration: InputDecoration(
                suffixIcon: IconButton(
                  key: const Key('btn_apikey_visibility'),
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: TraeTokens.gapMd),
            Row(
              children: [
                FilledButton(
                  key: const Key('btn_apikey_save'),
                  onPressed: _save,
                  child: const Text('保存'),
                ),
                const SizedBox(width: TraeTokens.gapMd),
                TextButton(
                  key: const Key('btn_apikey_clear'),
                  onPressed: () {
                    _controller.clear();
                    ref.read(profileAdminControllerProvider.notifier).updateApiKey(null);
                    _invalidateDataSources();
                    widget.onSaved?.call();
                  },
                  child: const Text('清除'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    await ref
        .read(profileAdminControllerProvider.notifier)
        .updateApiKey(_controller.text.trim());
    // 保存 key 后必须让此前因 401 失败的数据源立即重拉：/metrics 决定监控页
    // 与 About facts，/config 决定模型设置卡。updateApiKey 只换 Profile →
    // strataClientProvider 重建，但 metricsProvider / configProvider 的既有
    // error 态不会自动重来，用户会看到「保存了 key 但页面还是老样子」。
    _invalidateDataSources();
    widget.onSaved?.call();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('API key 已保存'), duration: Duration(seconds: 1)),
      );
    }
  }

  /// 失效依赖鉴权的数据源（/metrics 及监控侧快照）
  ///
  /// /config 与 /props 的 provider 挂在 about_screen.dart（与本组件同层，
  /// 但引入会形成 widgets→screens 的反向依赖），故由 about_screen 的调用方
  /// 另行失效（见 about_screen.dart 的 _AboutUnavailable）。
  void _invalidateDataSources() {
    ref.invalidate(metricsProvider);
    ref.invalidate(monitorProvider);
  }
}

// ConnectionGuideScreen（P4 / v0.0.10）：首次使用引导 + WireGuard 配置说明。
//
// 【为什么需要这一页（第十一轮真机反馈驱动）】
// 用户反馈原话：「app 中没有配置 wireGuard 和如何使用这个 app 的说明」。
// 此前 App 只有「填地址 → 连」的功能，没有任何说明：
//   ① 不知道手机与主机之间要建立什么隧道、装哪个官方 App、怎么配；
//   ② 不知道本 App 各个页面分别干什么、首���该做哪一步。
//
// 本页因此承载三件事：
//   ① **首次使用三步法** —— 从 0 到能聊天的最短路径（含跳转按钮）；
//   ② **WireGuard 配网指南** —— 需要用户在主机与手机两端各做什么，
//      含配置文件导入路径、隧道地址该怎么填；
//   ③ **页面功能说明** —— 对话 / 监控 / 控制 / 关于 / 设置 各页职责。
//
// 【设计约束】
// 本页是**纯说明页**，不引入新的网络栈或依赖：
// App 本身不集成 WireGuard 协议栈（那需要 root / VpnService 且与主机侧强绑定），
// 隧道由手机上的官方 WireGuard App 负责，本 App 只负责连隧道内的那个地址。
// 因此本页是「说明书 + 深链引导」，不是「内嵌 VPN 客户端」。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/connection_provider.dart';
import '../theme/trae_theme.dart';
import 'connection_screen.dart';

class ConnectionGuideScreen extends ConsumerWidget {
  const ConnectionGuideScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.trae;
    final hasProfile = ref.watch(profilesProvider).valueOrNull?.isNotEmpty ?? false;

    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        titleSpacing: TraeTokens.gapLg,
        title: Text('连接指南', style: TraeText.pageTitle(context)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        children: [
          _IntroCard(),
          const SizedBox(height: TraeTokens.gapMd),

          // ── 首次使用三步 ──────────────────────────────────────
          const _SectionTitle('第一次使用：三步连上主机'),
          const _StepCard(
            keyId: 'step_1',
            index: 1,
            title: '在主机上启动服务',
            body: '在跑模型的电脑上启动服务，并记下它监听的端口（默认 8080）。'
                '服务只监听本机时，手机无法直接访问 —— 下一步的隧道就是为此准备的。',
          ),
          const SizedBox(height: TraeTokens.gapSm),
          const _StepCard(
            keyId: 'step_2',
            index: 2,
            title: '手机与主机连上同一个 WireGuard 隧道',
            body: '在手机安装官方 WireGuard App，导入主机生成的 .conf 配置，'
                '打开隧道开关。隧道建立后，主机会获得一个虚拟 IP（如 10.0.0.2），'
                '下一��步就填这个地址，而不是 Wi-Fi 下的局域网 IP。',
          ),
          const SizedBox(height: TraeTokens.gapSm),
          _StepCard(
            keyId: 'step_3',
            index: 3,
            title: '在本 App 里新增连接配置',
            body: '填名称、主机地址（隧道虚拟 IP）、端口和 API Key（服务端开了鉴权才需要），'
                '点「测试连接」确认能拉到模型列表，保存后即可开始对话。',
            action: hasProfile ? null : '新增连接配置',
            onAction: hasProfile
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const ConnectionScreen()),
                    ),
          ),
          const SizedBox(height: TraeTokens.gapLg),

          // ── WireGuard 详细配置 ────────────────────────────────
          const _SectionTitle('WireGuard 配置详解'),
          const _DocBlock(
            keyId: 'wg_what',
            title: '为什么需要隧道',
            body: '模型服务通常只监听 127.0.0.1，不会暴露到局域网或公网；'
                '手机里的 App 也无法访问电脑的 127.0.0.1。'
                'WireGuard 在手机与主机之间建立一条点对点加密隧道，'
                '隧道内的地址（如 10.0.0.2）就能像局域网地址一样被访问。',
          ),
          const SizedBox(height: TraeTokens.gapSm),
          const _DocBlock(
            keyId: 'wg_phone',
            title: '手机端',
            body: '① 安装官方 WireGuard App（Google Play / App Store）。\n'
                '② 主机生成配置文件后，通过任一方式传到手机：'
                '微信/邮件发给自己、局域网传输、或用 WireGuard App 的「从文件导入」。\n'
                '③ 点右上角 + → 选择该 .conf 文件 → 保存为隧道。\n'
                '④ 打开隧道开关，状态变为「Active」。\n'
                '⑤ 在本 App 里把主机地址填成配置里给手机/主机分配的隧道地址。',
          ),
          const SizedBox(height: TraeTokens.gapSm),
          const _DocBlock(
            keyId: 'wg_host',
            title: '主机端',
            body: '① 主机也安装 WireGuard（或使用已有的 VPN 服务）。\n'
                '② 生成一对密钥，把手机的公钥加入主机的 AllowedIPs。\n'
                '③ 启动隧道后，主机侧会拿到一个虚拟 IP。\n'
                '④ 确认模型服务监听在 0.0.0.0（或至少隧道网段）而不是仅 127.0.0.1，'
                '否则隧道通了也连不上。\n'
                '⑤ 端口填服务实际监听的端口。',
          ),
          const SizedBox(height: TraeTokens.gapSm),
          const _DocBlock(
            keyId: 'wg_trouble',
            title: '连不上时依次检查',
            body: '① 手机上 WireGuard 隧道开关是否真的打开（不是「已加载」而是「已激活」）。\n'
                '② 本 App 主机地址是否填的是隧道虚拟 IP，而不是 Wi-Fi 的 192.168.x.x。\n'
                '③ 端口是否与服务监听端口一致。\n'
                '④ 服务端若启用了 API Key，本 App 里也必须填同一个 Key，否则返回 401。\n'
                '⑤ 手机与主机之间是否还有其他 VPN / 代理冲突。',
          ),
          const SizedBox(height: TraeTokens.gapLg),

          // ── 页面功能说明 ──────────────────────────────────────
          const _SectionTitle('各页面是做什么的'),
          const _DocBlock(
            keyId: 'page_chat',
            title: '对话',
            body: '与模型聊天。可发送文字和图片；左侧抽屉可切换 / 新建 / 重命名 / 置顶会话。'
                '会话可导出为 PDF、Markdown、HTML 或 JSON，也能再导回来。',
          ),
          const SizedBox(height: TraeTokens.gapSm),
          const _DocBlock(
            keyId: 'page_monitor',
            title: '监控',
            body: '实时查看引擎状态、生成速度、GPU 占用与温度、上下文占用、'
                '以及最近的请求明细。数据来自主机上的 /metrics 接口。',
          ),
          const SizedBox(height: TraeTokens.gapSm),
          const _DocBlock(
            keyId: 'page_control',
            title: '控制',
            body: '加载 / 卸载模型、调整上下文长度与采样参数，并查看主机上已安装的模型列表。',
          ),
          const SizedBox(height: TraeTokens.gapSm),
          const _DocBlock(
            keyId: 'page_about',
            title: '关于',
            body: '查看服务版本、引擎信息与硬件信息；也可在此确认连接状态。',
          ),
          const SizedBox(height: TraeTokens.gapSm),
          const _DocBlock(
            keyId: 'page_settings',
            title: '设置',
            body: '管理多条连接配置、切换外观深浅色、以及会话数据的导出 / 导入 / 清空。',
          ),
          const SizedBox(height: TraeTokens.gapXl),
        ],
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard();

  @override
  Widget build(BuildContext context) {
    final t = context.trae;
    return Card(
      key: const Key('guide_intro'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.vpn_lock_outlined, size: 22, color: t.accent),
            const SizedBox(width: TraeTokens.gapMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('连接前请先看这里',
                      style: TraeText.sectionTitle(context)),
                  const SizedBox(height: TraeTokens.gapXs),
                  Text(
                    '本 App 通过 WireGuard 隧道访问你主机上的模型服务。'
                    '手机端的隧道由官方 WireGuard App 负责，本 App 只负责连隧道内的地址。',
                    style: TraeText.body(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
          left: TraeTokens.gapXs, bottom: TraeTokens.gapSm),
      child: Text(text, style: TraeText.sectionTitle(context)),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.keyId,
    required this.index,
    required this.title,
    required this.body,
    this.action,
    this.onAction,
  });

  final String keyId;
  final int index;
  final String title;
  final String body;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final t = context.trae;
    return Card(
      key: Key(keyId),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: t.accentTint,
                    borderRadius: BorderRadius.circular(TraeTokens.radiusPill),
                  ),
                  child: Text(
                    '$index',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: t.accentText,
                    ),
                  ),
                ),
                const SizedBox(width: TraeTokens.gapSm),
                Expanded(
                  child: Text(title, style: TraeText.sectionTitle(context)),
                ),
              ],
            ),
            const SizedBox(height: TraeTokens.gapSm),
            Text(body, style: TraeText.body(context)),
            if (action != null && onAction != null) ...[
              const SizedBox(height: TraeTokens.gapMd),
              OutlinedButton.icon(
                key: const Key('guide_action_add_profile'),
                onPressed: onAction,
                icon: const Icon(Icons.add, size: 18),
                label: Text(action!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DocBlock extends StatelessWidget {
  const _DocBlock({
    required this.keyId,
    required this.title,
    required this.body,
  });

  final String keyId;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final t = context.trae;
    return Card(
      key: Key(keyId),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.article_outlined, size: 16, color: t.inkSoft),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(title, style: TraeText.sectionTitle(context)),
                ),
              ],
            ),
            const SizedBox(height: TraeTokens.gapSm),
            Text(body, style: TraeText.body(context)),
          ],
        ),
      ),
    );
  }
}

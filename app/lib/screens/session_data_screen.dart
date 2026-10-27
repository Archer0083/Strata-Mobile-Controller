// SessionDataScreen（v0.0.9 新增）：把「会话数据」从设置页的常驻底部区块
// 提升为独立二级页。
//
// 【为什么要独立成页（第十轮真机反馈驱动）】
// 用户反馈原话：「设置里面有会话数据……请梳理当前的功能按钮，
// 按照重要性和易理解的逻辑把按钮和功能布局重新梳理一遍」。
//
// 原来的形态：SessionDataSection 以常驻区块形式挂在设置页底部（Column 里
// Divider + Section），带来两个问题：
//   ① 「导出全部 / 导入 / 清空全部」三个**破坏性或重量级**操作与
//      「切换主题」「切换连接配置」这类轻量设置混在同一滚动流里，
//      用户要滚到最底部才能看到，也容易误触；
//   ② 会话数据属于「数据管理」而不是「设置」，塞在设置页里语义不对。
//
// 现在的形态：设置页「数据」分区 → 一个入口 tile → 本页。
// 本页只有四件事：查看占用 / 导出全部 / 导入 / 清空，层级单一、意图明确。
//
// 数据逻辑（打包格式、导入预览、清空二次确认）全部复用 SessionDataSection，
// 本文件只负责「页面外壳 + AppBar + 说明文案」。

import 'package:flutter/material.dart';

import '../theme/trae_theme.dart';
import 'session_data_section.dart';

class SessionDataScreen extends StatelessWidget {
  const SessionDataScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.trae.bg,
      appBar: AppBar(
        titleSpacing: TraeTokens.gapLg,
        title: Text('会话数据', style: TraeText.pageTitle(context)),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: TraeTokens.gapXl),
        children: const [
          _Intro(),
          Divider(height: 1),
          SessionDataSection(),
        ],
      ),
    );
  }
}

/// 页首说明：让用户先知道这些操作影响什么（尤其是「清空」）。
class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          TraeTokens.gapLg, TraeTokens.gapLg, TraeTokens.gapLg, TraeTokens.gapMd),
      child: Text(
        '会话保存在本机，不在主机上。导出会打包成一个 .json 文件，'
        '可再次导入到任意设备。',
        style: TraeText.meta(context),
      ),
    );
  }
}

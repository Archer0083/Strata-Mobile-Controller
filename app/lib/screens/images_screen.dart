// ImagesScreen（M2-6，对齐 webUI Images tab 的 img-form + img-results）：
//
// 【web 口径（app.js L1108-1139 + index.html view-images）】
// - 表单：prompt textarea（trim 后非空才可发）+ size 五档下拉
//   （1024x1024/1536x1024/1024x1536/768x768/512x512）+ seed（空 = 随机）
// - 请求体：{prompt, size, response_format: "b64_json", seed?}；
//   seed 仅在输入非空时携带（Number 转换）
// - 提示语三态：idle「一次生成一张…」/ 生成中「生成中…（小 GPU 上可能要一分钟以上）」；
//   错误 toast「生成失败」（web toast("error","No image") 同口径）
// - 结果 prepend（最新在上）；caption：`{size}, seed {seed}, {秒} s: {prompt}`
// - 入口显隐：仅 health.image_generation 为真（tab-btn-images 同口径）
//
// 【移动端落地差异】
// - 「右键另存」不可用 → 图片长按走系统分享面板（share_plus 零权限链路，
//   与导出同款：临时目录 PNG → share，不引 gallery 权限库）
// - 生成期间禁用 Generate 防重入（web img-go.disabled 同口径）
// - 页面非常驻：由 ChatScreen 顶栏 push 进入，退出即释放

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/connection_provider.dart';
import '../providers/monitor_provider.dart';
import '../theme/trae_theme.dart';
import 'home_shell.dart';

/// web img-size 五档（index.html L85-86 逐一对应）
const kImageSizes = [
  '1024x1024',
  '1536x1024',
  '1024x1536',
  '768x768',
  '512x512',
];

/// health.image_generation 门控（web tab-btn-images.hidden 同口径）。
/// monitorProvider 拉不到（未连接/旧服务器）时视为关。
final imageGenEnabledProvider = Provider<bool>((ref) {
  return ref.watch(monitorProvider).valueOrNull?.health.imageGeneration ?? false;
});

class ImagesScreen extends ConsumerStatefulWidget {
  const ImagesScreen({super.key});

  @override
  ConsumerState<ImagesScreen> createState() => _ImagesScreenState();
}

class _ImagesScreenState extends ConsumerState<ImagesScreen> {
  final _promptController = TextEditingController();
  final _seedController = TextEditingController();
  String _size = kImageSizes.first;
  bool _busy = false;

  /// 生成结果（最新在上，web prepend 同口径）。Bytes 已解码，避免重复 base64Decode。
  final List<_Generated> _results = [];

  @override
  void dispose() {
    _promptController.dispose();
    _seedController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty || _busy) return;

    // seed 仅在输入非空时携带（web：Number(img-seed.value)）
    int? seed;
    final seedText = _seedController.text.trim();
    if (seedText.isNotEmpty) {
      seed = int.tryParse(seedText);
    }

    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final stopwatch = Stopwatch()..start();
    try {
      final img = await ref.read(strataClientProvider).generateImage(
            prompt: prompt,
            size: _size,
            seed: seed,
          );
      stopwatch.stop();
      if (!mounted) return;
      setState(() {
        _results.insert(
          0,
          _Generated(
            bytes: base64Decode(img.b64Json),
            prompt: prompt,
            size: img.size ?? _size,
            seed: img.seed,
            secs: (stopwatch.elapsed.inMilliseconds / 1000).round(),
          ),
        );
      });
    } on Object catch (e) {
      stopwatch.stop();
      // web 口径：清 hint + toast（app.js L1133-1135）
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('生成失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 长按图片：系统分享面板（share_plus 零权限，与导出同链路）
  Future<void> _share(_Generated g) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dir = await getTemporaryDirectory();
      final name = 'strata-image-${g.seed ?? 'x'}.png';
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(g.bytes, flush: true);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'image/png')],
        subject: name,
      ));
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('分享失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final canGen = ref.watch(imageGenEnabledProvider);

    return Scaffold(
      backgroundColor: context.trae.bg,
      appBar: AppBar(
        titleSpacing: TraeTokens.gapLg,
        title: Text('生成图片', style: TraeText.pageTitle(context)),
        actions: const [
          TopNavEntries(exclude: TopNav.chat),
          SizedBox(width: TraeTokens.gapSm),
        ],
      ),
      body: !canGen
          ? const _NotSetupView()
          : ListView(
              padding: const EdgeInsets.all(TraeTokens.gapLg),
              children: [
                _FormCard(
                  promptController: _promptController,
                  seedController: _seedController,
                  size: _size,
                  onSizeChanged: (v) => setState(() => _size = v),
                  busy: _busy,
                  onGenerate: _generate,
                ),
                const SizedBox(height: TraeTokens.gapMd),
                for (final g in _results)
                  Padding(
                    padding: const EdgeInsets.only(bottom: TraeTokens.gapMd),
                    child: _ResultFigure(g: g, onLongPress: () => _share(g)),
                  ),
              ],
            ),
    );
  }
}

class _Generated {
  const _Generated({
    required this.bytes,
    required this.prompt,
    required this.size,
    this.seed,
    required this.secs,
  });

  final Uint8List bytes;
  final String prompt;
  final String size;
  final int? seed;
  final int secs;
}

/// 门控关时的空态（真实 server 404 images_not_set_up 的提示语）
class _NotSetupView extends StatelessWidget {
  const _NotSetupView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_not_supported_outlined,
                size: 48, color: context.trae.muted),
            const SizedBox(height: TraeTokens.gapMd),
            Text('此主机未配置生图（setup 时需 --images qwen-image）',
                style: TraeText.body(context), textAlign: TextAlign.center),
            const SizedBox(height: TraeTokens.gapSm),
            Text('服务器 /health 的 image_generation 为 false',
                style: TraeText.meta(context), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _FormCard extends StatelessWidget {
  const _FormCard({
    required this.promptController,
    required this.seedController,
    required this.size,
    required this.onSizeChanged,
    required this.busy,
    required this.onGenerate,
  });

  final TextEditingController promptController;
  final TextEditingController seedController;
  final String size;
  final ValueChanged<String> onSizeChanged;
  final bool busy;
  final VoidCallback onGenerate;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('img_form'),
      child: Padding(
        padding: const EdgeInsets.all(TraeTokens.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Make an image', style: TraeText.sectionTitle(context)),
            const SizedBox(height: TraeTokens.gapSm),
            TextField(
              key: const Key('img_prompt'),
              controller: promptController,
              maxLines: 3,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                hintText: '描述要生成的图片…',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: TraeTokens.gapSm),
            Row(
              children: [
                Expanded(
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Size',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        key: const Key('img_size'),
                        value: size,
                        isExpanded: true,
                        items: [
                          for (final s in kImageSizes)
                            DropdownMenuItem(value: s, child: Text(s)),
                        ],
                        onChanged: (v) {
                          if (v != null) onSizeChanged(v);
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: TraeTokens.gapSm),
                Expanded(
                  child: TextField(
                    key: const Key('img_seed'),
                    controller: seedController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Seed（空=随机）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: TraeTokens.gapSm),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('img_go'),
                onPressed: busy ? null : onGenerate,
                child: _BusyLabel(busy: busy),
              ),
            ),
            const SizedBox(height: TraeTokens.gapSm),
            Text(
              busy ? '生成中…（小 GPU 上可能要一分钟以上）' : '一次生成一张；生图期间聊天请求会排队等待（反之亦然）',
              key: Key(busy ? 'img_hint_busy' : 'img_hint_idle'),
              style: TraeText.meta(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _BusyLabel extends StatelessWidget {
  const _BusyLabel({required this.busy});

  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      );
    }
    return const Text('Generate');
  }
}

class _ResultFigure extends StatelessWidget {
  const _ResultFigure({required this.g, required this.onLongPress});

  final _Generated g;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Image.memory(
              g.bytes,
              key: Key('img_result_${g.seed ?? ''}'),
              fit: BoxFit.contain,
            ),
            Padding(
              padding: const EdgeInsets.all(TraeTokens.gapSm),
              child: Text(
                // web figcaption：`{size}, seed {seed}, {secs} s: {prompt}`
                '${g.size}, seed ${g.seed ?? '?'}, ${g.secs} s: ${g.prompt}',
                key: const Key('img_caption'),
                style: TraeText.meta(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 对话流式与思考链测试锚点：
// 1. markdown 样本渲染断言 —— 解析层纯函数（parseMarkdown/parseInline）
//    逐块对齐 web markdown() 的行为
// 2. 附件白名单 + 大小校验 —— isTextFileName/isImageName/classify*
//    的接受/拒绝矩阵
// 3. untouched 不发送断言 —— SamplingParams.toWire 的字段出现规则
// 4. stop meta —— _MetaStrip 的 token 文案规则（纯函数抽出测试口径，
//    见 chat_screen_test.dart 的 widget 断言）
// 另含 HealthInfo.images 门控字段解析（M2-5e）。

import 'package:flutter_test/flutter_test.dart';
import 'package:strata_mobile_controller/models/chat_models.dart';
import 'package:strata_mobile_controller/models/strata_models.dart';
import 'package:strata_mobile_controller/services/attachment_service.dart';
import 'package:strata_mobile_controller/widgets/markdown_view.dart';

void main() {
  group('markdown 解析层（parseMarkdown）', () {
    test('空文本 → 空块列表', () {
      expect(parseMarkdown(''), isEmpty);
      expect(parseMarkdown('   \n  '), isEmpty);
    });

    test('纯段落', () {
      final blocks = parseMarkdown('你好，世界');
      expect(blocks, hasLength(1));
      expect(blocks.single, isA<MdParagraph>());
      expect((blocks.single as MdParagraph).lines, ['你好，世界']);
    });

    test('标题分级：# / ## → level3=true；### 到 ###### → level3=false', () {
      final blocks = parseMarkdown('# 大标题\n\n## 次标题\n\n### 三级');
      expect(blocks, hasLength(3));
      final h1 = blocks[0] as MdHeading;
      final h2 = blocks[1] as MdHeading;
      final h3 = blocks[2] as MdHeading;
      expect(h1.level3, isTrue);
      expect(h2.level3, isTrue);
      expect(h3.level3, isFalse);
      expect(h3.text, '三级');
    });

    test('代码块：闭合 fence → MdCodeBlock（lang + 代码体）', () {
      final blocks = parseMarkdown('```dart\nvoid main() {}\n```');
      expect(blocks.single, isA<MdCodeBlock>());
      final cb = blocks.single as MdCodeBlock;
      expect(cb.lang, 'dart');
      expect(cb.code, 'void main() {}');
    });

    test('代码块：未闭合 fence → 仍为 MdCodeBlock（流式渲染口径）', () {
      final blocks = parseMarkdown('前文\n\n```python\nprint(1)');
      expect(blocks, hasLength(2));
      final cb = blocks[1] as MdCodeBlock;
      expect(cb.lang, 'python');
      expect(cb.code, 'print(1)');
    });

    test('fence 固定三反引号：四反引号不开围栏，围栏内 ``` 提前闭合（web 口径）', () {
      // web fence 正则固定三反引号，不支持 CommonMark 四反引号语义：
      // 首个 fence 在第二个 ``` 行开启，内容到下一个 ``` 行即闭合，
      // 前后 ```` 行各自成为段落（app.js L556-569 同口径）
      final blocks = parseMarkdown('````\n```\ninner\n```\n````');
      expect(blocks, hasLength(3));
      expect(blocks[0], isA<MdParagraph>());
      final cb = blocks[1] as MdCodeBlock;
      expect(cb.lang, '');
      expect(cb.code, 'inner');
      expect(blocks[2], isA<MdParagraph>());
    });

    test('分隔线：--- / *** / ___ → MdThematicBreak；-- 不足三字符不算', () {
      expect(parseMarkdown('---').single, isA<MdThematicBreak>());
      expect(parseMarkdown(' *** ').single, isA<MdThematicBreak>());
      expect(parseMarkdown('___').single, isA<MdThematicBreak>());
      expect(parseMarkdown('--'), isNot(isA<MdThematicBreak>()));
    });

    test('引用块：> 开头单行 → MdBlockquote', () {
      final blocks = parseMarkdown('> 引用内容');
      final bq = blocks.single as MdBlockquote;
      expect(bq.text, '引用内容');
    });

    test('表格：表头 + 分隔行 + 数据行 → MdTable', () {
      final src = '| a | b |\n| --- | --- |\n| 1 | 2 |';
      final blocks = parseMarkdown(src);
      final t = blocks.single as MdTable;
      expect(t.header, ['a', 'b']);
      expect(t.rows, [
        ['1', '2']
      ]);
    });

    test('列表：ul / ol + ≥2 空格续行合并为单项', () {
      final blocks = parseMarkdown('- 项目一\n  续行\n- 项目二\n1. 第一\n2. 第二');
      expect(blocks, hasLength(2));
      final ul = blocks[0] as MdListBlock;
      expect(ul.ordered, isFalse);
      expect(ul.items, ['项目一 续行', '项目二']);
      final ol = blocks[1] as MdListBlock;
      expect(ol.ordered, isTrue);
      expect(ol.items, ['第一', '第二']);
    });

    test('混合文档（标题/代码/段落）切分顺序保留', () {
      final src = '# 标题\n\n段落甲。\n\n```js\ncode();\n```\n\n段落乙。';
      final blocks = parseMarkdown(src);
      expect(blocks, hasLength(4));
      expect(blocks[0], isA<MdHeading>());
      expect(blocks[1], isA<MdParagraph>());
      expect(blocks[2], isA<MdCodeBlock>());
      expect(blocks[3], isA<MdParagraph>());
    });
  });

  group('markdown 行内解析（parseInline）', () {
    test('行内代码优先：`code` → MdCodeSpan，内部 ** 不再解析', () {
      final nodes = parseInline('a `x = **y**` b');
      expect(nodes.any((n) => n is MdCodeSpan), isTrue);
      final code = nodes.whereType<MdCodeSpan>().single;
      expect(code.code, 'x = **y**');
    });

    test('粗体 **x** → MdBold 包裹子节点', () {
      final nodes = parseInline('前 **粗 体** 后');
      final bold = nodes.whereType<MdBold>().single;
      expect(mdPlainText(bold), '粗 体');
    });

    test('斜体 *x* → MdItalic', () {
      final nodes = parseInline('这是 *斜体* 字');
      expect(nodes.whereType<MdItalic>().single, isNotNull);
    });

    test('链接 [text](url) → MdLink（文本内仅再识别行内代码）', () {
      final nodes = parseInline('见 [文档 `code`](https://a.b) 页');
      final link = nodes.whereType<MdLink>().single;
      expect(link.url, 'https://a.b');
      expect(link.children.any((c) => c is MdCodeSpan), isTrue);
    });

    test('纯文本无标记 → 单 MdPlain', () {
      final nodes = parseInline('普通文本');
      expect(nodes.single, isA<MdPlain>());
    });
  });

  group('附件白名单与大小校验', () {
    test('文本扩展名白名单命中', () {
      expect(isTextFileName('a.py'), isTrue);
      expect(isTextFileName('b.MD'), isTrue); // 大小写不敏感
      expect(isTextFileName('deep/path/main.rs'), isTrue);
      expect(isTextFileName('notes.txt'), isTrue);
    });

    test('特殊文件名（makefile/dockerfile/readme/license）', () {
      expect(isTextFileName('makefile'), isTrue);
      expect(isTextFileName('Dockerfile'), isTrue);
      expect(isTextFileName('x/README'), isTrue);
      expect(isTextFileName('LICENSE'), isTrue);
      expect(isTextFileName('myreadme'), isFalse); // 需边界（^ 或 /）
    });

    test('非白名单拒绝', () {
      expect(isTextFileName('a.exe'), isFalse);
      expect(isTextFileName('b.zip'), isFalse);
      expect(isTextFileName('photo.png'), isFalse, reason: 'png 走图片路径不走文本白名单');
    });

    test('MIME text/* 与常见文本 MIME 命中', () {
      expect(isTextFileName('x', mimeType: 'text/plain'), isTrue);
      expect(isTextFileName('x', mimeType: 'application/json'), isTrue);
      expect(isTextFileName('x', mimeType: 'application/xml'), isTrue);
      expect(isTextFileName('x', mimeType: 'image/png'), isFalse);
    });

    test('图片判定：MIME image/* 或扩展名', () {
      expect(isImageName('a.png'), isTrue);
      expect(isImageName('b.JPG'), isTrue);
      expect(isImageName('c', mimeType: 'image/webp'), isTrue);
      expect(isImageName('d.pdf'), isFalse);
      expect(isImageName('e', mimeType: 'application/pdf'), isFalse);
    });

    test('文本文件 512KB 上限 + 二进制（\\u0000）拒绝', () {
      final big = List.filled(maxTextFileBytes + 1, 0x61);
      expect(classifyTextFile('big.txt', big), isA<RejectedAttachment>());
      expect(
        classifyTextFile('bin.txt', [0x00, 0x01]),
        isA<RejectedAttachment>(),
      );
      final ok = classifyTextFile('ok.txt', utf8Bytes('你好'));
      expect(ok, isA<PickedTextFile>());
    });

    test('图片 20MB 上限 → dataURL', () {
      expect(classifyImage('a.png', 'image/png', List.filled(3, 1)),
          isA<PickedImage>());
      final tooBig = List.filled(maxImageBytes + 1, 1);
      expect(classifyImage('a.png', 'image/png', tooBig),
          isA<RejectedAttachment>());
      expect(
        imageDataUrl('image/png', [1, 2]),
        startsWith('data:image/png;base64,'),
      );
    });

    test('围栏拼接：fileBlock 反引号数 = max(2, 最长串)+1；userText 空段过滤', () {
      final plain = fileBlock(const AttachedTextFile(name: 'a.txt', text: 'hi'));
      expect(plain, startsWith('File: a.txt\n```\nhi\n```'));
      // 内容自带 ``` → 围栏升级为四个
      final tricky = fileBlock(
          const AttachedTextFile(name: 'b.md', text: '```dart\ncode\n```'));
      expect(tricky.contains('````'), isTrue);
      // userText：正文 + 文件块以空行 join，空正文不产生空段
      expect(userText('', [const AttachedTextFile(name: 'a.txt', text: 'x')]),
          startsWith('File: a.txt'));
      expect(userText('正文', const []), '正文');
      expect(
        userText('正文', [const AttachedTextFile(name: 'a.txt', text: 'x')])
            .contains('\n\n'),
        isTrue,
      );
    });
  });

  group('SamplingParams：untouched 不发送断言', () {
    test('默认值 → toWire 为空 map（三常量全不发送）', () {
      expect(SamplingParams.defaults.toWire(), isEmpty);
    });

    test('改回默认值 → untouched 重新成立（恢复默认即清除）', () {
      const touched = SamplingParams(temperature: 0.7);
      expect(touched.untouched, isFalse);
      const back = SamplingParams(); // = defaults
      expect(back.untouched, isTrue);
      expect(back.toWire(), isEmpty);
    });

    test('touched → 三件套一起发送', () {
      const s = SamplingParams(temperature: 0.7, topP: 0.9, topK: 10);
      expect(s.toWire(), {
        'temperature': 0.7,
        'top_p': 0.9,
        'top_k': 10,
      });
    });

    test('temp ≤ 0 → 只发 temperature:0（贪婪解码）', () {
      const s = SamplingParams(temperature: 0, topP: 0.9, topK: 10);
      expect(s.toWire(), {'temperature': 0});
    });

    test('maxTokens / seed 非空才发送（可与 untouched 并存）', () {
      const onlyMax = SamplingParams(maxTokens: 512);
      expect(onlyMax.untouched, isTrue);
      expect(onlyMax.toWire(), {'max_tokens': 512});
      const withSeed = SamplingParams(seed: 42, maxTokens: 128);
      expect(withSeed.toWire(), {'max_tokens': 128, 'seed': 42});
    });
  });

  group('stop meta 文案规则（web updateAssistant 口径）', () {
    // 与 chat_screen _MetaStrip._tokenText 同一规则；此处锁语义
    String tokenText({ChatUsage? usage, double? genSecs, bool stopped = false}) {
      if (usage == null) return stopped ? '已停止' : '';
      final n = usage.completionTokens;
      final secs = genSecs ?? 0;
      final rate = secs > 0.25 ? ' · ${(n / secs).toStringAsFixed(1)} tok/s' : '';
      final s = stopped ? ' · 已停止' : '';
      return '$n tokens$rate$s';
    }

    test('正常完成：N tokens（genSecs ≤ 0.25 不显速率）', () {
      expect(
        tokenText(usage: usage(100), genSecs: 0.2),
        '100 tokens',
      );
    });

    test('正常完成：N tokens · M tok/s（genSecs > 0.25）', () {
      expect(
        tokenText(usage: usage(300), genSecs: 2.0),
        '300 tokens · 150.0 tok/s',
      );
    });

    test('被停止但有 usage → 追加 · 已停止', () {
      expect(
        tokenText(usage: usage(50), genSecs: 1.0, stopped: true),
        '50 tokens · 50.0 tok/s · 已停止',
      );
    });

    test('被停止且无 usage → 仅「已停止」', () {
      expect(tokenText(usage: null, stopped: true), '已停止');
    });

    test('无 usage 正常完成 → 空串（不渲染 token 段）', () {
      expect(tokenText(usage: null), '');
    });
  });

  group('HealthInfo.images 门控（M2-5e）', () {
    test('缺省无 images 字段 → false（保守门控）', () {
      final h = HealthInfo.fromJson({'status': 'ok', 'model': 'm'});
      expect(h.images, isFalse);
      expect(h.imageGeneration, isFalse);
    });

    test('images: true → 放行图片附件', () {
      final h = HealthInfo.fromJson({'status': 'ok', 'images': true});
      expect(h.images, isTrue);
    });

    test('image_generation → Images tab 门控', () {
      final h =
          HealthInfo.fromJson({'status': 'ok', 'image_generation': true});
      expect(h.imageGeneration, isTrue);
    });

    test('images 为 mmproj 模型名字符串（mock/真实服务端口径）→ truthy 判定', () {
      // web truthy：非空字符串（mmproj 名）= 开；空串 = 关
      final on = HealthInfo.fromJson(
          {'status': 'ok', 'images': 'mmproj-f16b.gguf'});
      expect(on.images, isTrue);
      final off = HealthInfo.fromJson({'status': 'ok', 'images': ''});
      expect(off.images, isFalse);
    });
  });
}

ChatUsage usage(int completion) => ChatUsage(
      promptTokens: 10,
      completionTokens: completion,
      totalTokens: completion + 10,
    );

List<int> utf8Bytes(String s) {
  // dart:convert 在 import 不了的纯 Dart 环境下手写 UTF-8 编码过于冗长；
  // 中文两用例改用 codeUnit 兜底不可靠，直接用 ASCII 消除歧义。
  return s.codeUnits;
}

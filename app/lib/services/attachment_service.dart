// 附件服务（M2-5，口径对齐 webUI app.js L924-962）：
// - 文本附件：扩展名白名单（TEXT_EXT）+ 特殊文件名（makefile/dockerfile/
//   readme/license）+ MIME text/* → 512KB 上限 → 内容含 \u0000 视为二进制拒绝
// - 图片附件：MIME image/* → 20MB 上限 → dataURL（base64）
// - 发送时文本附件以反引号围栏代码块拼进 prompt：围栏长度 =
//   max(2, 内容最长反引号串) + 1，格式 `File: {name}\n{fence}\n{text}\n{fence}`
// - userText = [正文, ...各文件块].filter(非空).join("\n\n")
//
// 纯函数（白名单/围栏/userText）与 IO（file_picker 读取）分离，白名单与
// 拼接规则可单测；IO 层仅做读字节 + 编码 + 调纯函数校验。

import 'dart:convert';

import 'package:file_picker/file_picker.dart';

import '../models/chat_models.dart';

/// web 端 TEXT_EXT 逐项对齐（正则后缀匹配，大小写不敏感）
final RegExp _textExt = RegExp(
  r'\.(txt|md|markdown|rst|tex|py|pyi|ipynb|js|mjs|cjs|ts|tsx|jsx|vue|svelte|'
  r'json|jsonl|csv|tsv|log|ya?ml|toml|ini|cfg|conf|env|xml|html?|css|scss|less|'
  r'c|cc|cpp|cxx|h|hh|hpp|cu|cuh|rs|go|java|kt|kts|swift|rb|php|pl|lua|r|jl|'
  r'scala|sql|sh|bash|zsh|fish|ps1|psm1|bat|cmd|diff|patch|gradle|cmake|mk|'
  r'dockerfile|gitignore|proto|graphql)$',
  caseSensitive: false,
);

/// 特殊文件名（无扩展名的常见文本文件，web 端 (^|[\\/]) 前缀匹配）
final RegExp _textName = RegExp(
    r'(^|[\\/])(makefile|dockerfile|readme|license)$',
    caseSensitive: false);

const int maxTextFileBytes = 512 * 1024;
const int maxImageBytes = 20 * 1000 * 1000; // web 端 20e6（十进制 20MB）

/// 是否白名单文本文件（纯函数，可单测）。
/// [mimeType] 可空：web 端 MIME 命中（text/* 或 json/xml/javascript/yaml/
/// toml/x-sh/x-python）与扩展名命中任一即可。
bool isTextFileName(String name, {String? mimeType}) {
  if (mimeType != null) {
    final mt = mimeType.toLowerCase();
    if (mt.startsWith('text/')) return true;
    if (RegExp(r'(json|xml|javascript|yaml|toml|x-sh|x-python)').hasMatch(mt)) {
      return true;
    }
  }
  return _textExt.hasMatch(name) || _textName.hasMatch(name);
}

/// 是否图片（MIME image/*；无 MIME 时按扩展名兜底）
bool isImageName(String name, {String? mimeType}) {
  if (mimeType != null && mimeType.toLowerCase().startsWith('image/')) return true;
  return RegExp(r'\.(png|jpe?g|gif|webp|bmp)$', caseSensitive: false)
      .hasMatch(name);
}

/// 单文件文本块（web fileBlock 逐行对齐）：围栏反引号数 =
/// max(2, 内容最长反引号串) + 1，防内容自身含 ``` 提前闭合
String fileBlock(AttachedTextFile f) {
  var longest = 2;
  for (final m in RegExp('`+').allMatches(f.text)) {
    if (m.end - m.start > longest) longest = m.end - m.start;
  }
  final fence = '`' * (longest + 1);
  return 'File: ${f.name}\n$fence\n${f.text}\n$fence';
}

/// 组装 user prompt：正文 + 各文件块，空段过滤后 join("\n\n")
String userText(String text, List<AttachedTextFile> files) =>
    [if (text.isNotEmpty) text, for (final f in files) fileBlock(f)]
        .where((s) => s.isNotEmpty)
        .join('\n\n');

/// 字节 → dataURL（图片附件请求形态，web FileReader.readAsDataURL 同构）
String imageDataUrl(String mimeType, List<int> bytes) =>
    'data:$mimeType;base64,${base64Encode(bytes)}';

/// 单个附件的校验/读取结果
sealed class PickedAttachment {
  const PickedAttachment();
}

class PickedTextFile extends PickedAttachment {
  const PickedTextFile(this.file);

  final AttachedTextFile file;
}

class PickedImage extends PickedAttachment {
  const PickedImage(this.name, this.dataUrl);

  final String name;
  final String dataUrl;
}

/// 被拒绝的附件（原因文案已组好，UI 直接 toast）
class RejectedAttachment extends PickedAttachment {
  const RejectedAttachment(this.name, this.reason);

  final String name;
  final String reason;
}

/// 文本内容含 \u0000 → 视为二进制拒绝（web 同规则）
PickedAttachment classifyTextFile(String name, List<int> bytes) {
  if (bytes.length > maxTextFileBytes) {
    return RejectedAttachment(name, '$name 超过 512 KB');
  }
  final text = utf8.decode(bytes, allowMalformed: true);
  if (text.contains('\u0000')) {
    return RejectedAttachment(name, '$name 疑似二进制文件');
  }
  return PickedTextFile(AttachedTextFile(name: name, text: text));
}

PickedAttachment classifyImage(String name, String mimeType, List<int> bytes) {
  if (bytes.length > maxImageBytes) {
    return RejectedAttachment(name, '$name 超过 20 MB');
  }
  return PickedImage(name, imageDataUrl(mimeType, bytes));
}

/// file_picker 封装：多选 → 逐个分类校验。
/// 图片门控（health.images）由调用方决定是否放行图片；这里只管读取与分类。
Future<List<PickedAttachment>> pickAttachments() async {
  final result = await FilePicker.platform.pickFiles(
    allowMultiple: true,
    withData: true, // SAF 下也拿全量字节（附件都小，无需流式读取）
  );
  if (result == null) return const [];
  final out = <PickedAttachment>[];
  for (final f in result.files) {
    final bytes = f.bytes;
    if (bytes == null) {
      out.add(RejectedAttachment(f.name, '无法读取 $f.name'));
      continue;
    }
    final mime = _mimeFromName(f.name);
    if (mime != null) {
      out.add(classifyImage(f.name, mime, bytes));
      continue;
    }
    if (isTextFileName(f.name)) {
      out.add(classifyTextFile(f.name, bytes));
      continue;
    }
    out.add(RejectedAttachment(
        f.name, '${f.name}：请附加文本文件（代码、笔记、日志、数据）或图片'));
  }
  return out;
}

/// 常见扩展名 → MIME（file_picker 的 PlatformFile 不直接给 MIME）
String? _mimeFromName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  switch (name.substring(dot + 1).toLowerCase()) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'bmp':
      return 'image/bmp';
    default:
      return null;
  }
}

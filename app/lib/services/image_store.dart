// 图片落盘服务（v0.0.10，M2-7.6）。
//
// 背景（v0.0.9 真机反馈）：发送带图的对话后重开会话看不到图片。
// 根因是图片只挂在内存态 UiChatMessage.imageUrls，DB 的 messages 表没有
// 图片列，重载时自然丢失。
//
// 方案：图片字节落盘到 App 私有目录（attachments/<会话id>/<消息seq>-<随机>.png），
// DB 只存**文件路径**（几十字节），渲染时按需读回为 dataURL。
// 为什么不直接存 dataURL：单张可达 20MB（上限），base64 后还要 +33%，
// 入库会把 SQLite 撑爆；落盘则 DB 体积恒定，图片可以随会话一起导出。
//
// 生命周期：
// - 发送时：dataURL → 解码为字节 → 落盘 → 记路径
// - 加载时：路径 → 读回字节 → dataURL（带内存缓存，避免重复 IO）
// - 导出时：路径 → 读回字节 → 内联 dataURL 进 .json
// - 删除会话时：连带清理该会话的图片目录

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 一张已落盘的图片
class StoredImage {
  const StoredImage({required this.path, required this.dataUrl});

  /// 本地绝对路径（DB 中持久化的就是这个）
  final String path;

  /// 渲染用的 dataURL（内存态，构造时由调用方从 path 读回）
  final String dataUrl;
}

/// 图片落盘 + 读回服务
class ImageStore {
  ImageStore({Directory? root}) : _rootOverride = root;

  /// 测试注入的根目录（生产环境为 null → 用 App 私有目录）
  final Directory? _rootOverride;

  /// dataURL → 内存缓存（path → dataURL），避免同一张图反复读盘
  final Map<String, String> _cache = {};

  /// 附件根目录：`[app documents]/attachments`
  Future<Directory> _attachmentsRoot() async {
    final override = _rootOverride;
    if (override != null) {
      final d = Directory(p.join(override.path, 'attachments'));
      if (!d.existsSync()) d.createSync(recursive: true);
      return d;
    }
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(docs.path, 'attachments'));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 会话专属目录：`[attachments]/[conversationId]`
  Future<Directory> _conversationDir(String conversationId) async {
    final root = await _attachmentsRoot();
    final safe = conversationId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final d = Directory(p.join(root.path, safe));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 把 dataURL 落盘，返回可入库的本地路径。
  ///
  /// 入参非法（不是 dataURL / base64 解不开）时返回 null——调用方按"无图"处理，
  /// 不阻断发送流程。
  Future<String?> persistDataUrl({
    required String conversationId,
    required int seq,
    required String dataUrl,
  }) async {
    final parsed = _splitDataUrl(dataUrl);
    if (parsed == null) return null;
    final (mime, bytes) = parsed;

    final dir = await _conversationDir(conversationId);
    final ext = _extForMime(mime);
    final name = 'm$seq-${DateTime.now().microsecondsSinceEpoch}$ext';
    final file = File(p.join(dir.path, name));
    try {
      await file.writeAsBytes(bytes, flush: true);
    } on IOException {
      return null;
    }
    return file.path;
  }

  /// 批量落盘，返回对应的路径列表（与入参等长；单张失败为 null 占位）。
  Future<List<String?>> persistAll({
    required String conversationId,
    required int seq,
    required List<String> dataUrls,
  }) async {
    final out = <String?>[];
    for (final u in dataUrls) {
      out.add(await persistDataUrl(
          conversationId: conversationId, seq: seq, dataUrl: u));
    }
    return out;
  }

  /// 读回 dataURL（带缓存）。文件缺失或损坏时返回 null。
  Future<String?> loadDataUrl(String path) async {
    if (_cache.containsKey(path)) return _cache[path];
    final f = File(path);
    if (!f.existsSync()) return null;
    List<int> bytes;
    try {
      bytes = await f.readAsBytes();
    } on IOException {
      return null;
    }
    final mime = _mimeForPath(path);
    final url = 'data:$mime;base64,${base64Encode(bytes)}';
    _cache[path] = url;
    return url;
  }

  /// 批量读回（保持与入参等长；缺失的用空串占位，UI 跳过空串）。
  Future<List<String>> loadAll(List<String> paths) async {
    final out = <String>[];
    for (final path in paths) {
      out.add(await loadDataUrl(path) ?? '');
    }
    return out;
  }

  /// 删除某个会话的图片目录（删会话时调用）。
  Future<void> deleteConversationImages(String conversationId) async {
    final safe = conversationId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    try {
      final root = await _attachmentsRoot();
      final d = Directory(p.join(root.path, safe));
      if (d.existsSync()) {
        await d.delete(recursive: true);
      }
    } on IOException {
      // 清理失败不阻断删会话（残留文件无害）
    }
    _cache.removeWhere((k, _) => k.contains(safe));
  }

  /// 清除内存缓存（会话被删/应用重启后调用）
  void clearCache() => _cache.clear();

  /// dataURL → (mime, bytes)。非法返回 null。
  static (String, List<int>)? _splitDataUrl(String dataUrl) {
    if (!dataUrl.startsWith('data:')) return null;
    final comma = dataUrl.indexOf(',');
    if (comma < 0) return null;
    final meta = dataUrl.substring(5, comma);
    final payload = dataUrl.substring(comma + 1);
    final mime = meta.split(';').first.isEmpty ? 'image/png' : meta.split(';').first;
    try {
      final bytes = base64Decode(payload);
      return (mime, bytes);
    } on FormatException {
      return null;
    }
  }

  static String _extForMime(String mime) {
    switch (mime.toLowerCase()) {
      case 'image/jpeg':
        return '.jpg';
      case 'image/gif':
        return '.gif';
      case 'image/webp':
        return '.webp';
      case 'image/bmp':
        return '.bmp';
      default:
        return '.png';
    }
  }

  static String _mimeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    return 'image/png';
  }
}

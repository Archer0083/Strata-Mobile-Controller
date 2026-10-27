// /metrics 完整 schema 适配层（M2-2，SPEC §10 MonitorScreen 完整版）。
//
// 字段对齐引擎 web 端的 render(m) 与 server-bridge/mock/mock_strata.py
// 的 metrics_tree()。解析原则：
//   1. 宽容忽略未知字段：上游版本演进新增键不致解析失败；
//   2. 数值一律 num? 读取，缺失/类型错误 → null，由 UI 层按「–」渲染；
//   3. history 数组不复制副本（列表已不可变地来自解码结果），UI 直接消费。
//
// 字段语义对照（字段定义与上游 webUI 的指标口径一致）：
//   live.state            idle / reading / generating（queued 由 live.queued>0 覆盖）
//   hardware.*            GPU/CPU/RAM/Disk 即时值（gpu_mem_total、gpu_power_limit 为分母）
//   hardware_static.*     型号名等静态信息（About 页复用）
//   engine.*              模型与引擎属性（About facts-engine 复用）
//   history.<key>         120 样本环形缓冲，sparkline 直接消费
//   requests[]            最近请求表（默认 12 条，?requests=all 给全部）
//   totals                since 启动累计
//   conversation_cache    会话缓存（旧服务器无此键 → enabled=false 整卡隐藏）

import 'json_readers.dart';

// —— 宽容读取助手（v0.0.8 真机反馈修复）——
//
// 真机反馈：App 监控页与 About 页同时降级，错误为
//   "type 'int' is not a subtype of type 'String?' in type cast"
// 而同一主机的 webUI（#monitor / #about）完全正常。
//
// 根因：引擎 INFO 行的 `key=value` 中纯数字的值会被服务端转成 int
// （strata_ref/serve/server.py:1073），于是 /metrics 的 engine 段里
// spec / mtp_max / lookup 是 int，而 images 是 bool。
// webUI 用真值判断不报错，Dart 的 `as String?` 硬断言却直接抛异常
// → 整份 /metrics 解析失败 → 监控页与 About 页同时降级。
//
// 修复：全部字段改用宽容读取助手（见 json_readers.dart），
// 绝不因单个字段的类型差异让整份 /metrics 解析失败。

// —— 格式化工具（对齐 app.js fmt/kfmt/ctxfmt/gb；1024 进制但标签 GB）——

/// 千分位 + 固定小数位；null/NaN → '–'（en dash，webUI 同款）
String fmtNum(num? n, [int digits = 0]) {
  if (n == null || n.isNaN) return '–';
  final s = n.toStringAsFixed(digits);
  final parts = s.split('.');
  final intPart = parts[0];
  final grouped = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    final pos = intPart.length - i;
    grouped.write(intPart[i]);
    if (pos > 3 && (pos - 1) % 3 == 0) grouped.write(',');
  }
  return parts.length == 2 ? '$grouped.${parts[1]}' : grouped.toString();
}

/// k 缩写：≥10000 → 0 位 k；1000–9999 → 1 位 k；否则原值
String kfmt(num? n) {
  if (n == null || n.isNaN) return '–';
  if (n >= 10000) return '${fmtNum(n / 1000, 0)}k';
  if (n >= 1000) return '${fmtNum(n / 1000, 1)}k';
  return fmtNum(n, 0);
}

/// context 数专用：1024 整数倍 → '{n/1024}K'，否则 kfmt
String ctxfmt(num? n) {
  if (n == null || n.isNaN) return '–';
  if (n > 0 && n % 1024 == 0) return '${n ~/ 1024}K';
  return kfmt(n);
}

/// 字节 → GB（1024 进制，标签 GB，Windows 式 binary GB；默认 1 位小数）
String gb(num? bytes, [int digits = 1]) {
  if (bytes == null || bytes.isNaN) return '–';
  return fmtNum(bytes / 1073741824, digits);
}

/// MiB 字段恒先 ×1048576 转字节再显示 GB（expert_cache_mib / budget_mib）
String gbFromMiB(num? mib, [int digits = 1]) => gb(mib == null ? null : mib * 1048576, digits);

/// 相对时间（app.js since()：<60s just now；<1h N min ago；否则 N h ago 1 位）
String sinceStr(num? epochSeconds) {
  if (epochSeconds == null) return '–';
  final diff = DateTime.now().millisecondsSinceEpoch / 1000 - epochSeconds;
  if (diff < 60) return 'just now';
  if (diff < 3600) return '${(diff / 60).floor()} min ago';
  return '${(diff / 3600).toStringAsFixed(1)} h ago';
}

// ─────────────────────────────────────────────────────────────
// 模型层
// ─────────────────────────────────────────────────────────────

class MetricsSnapshot {
  const MetricsSnapshot({
    required this.live,
    required this.hardware,
    required this.hardwareStatic,
    required this.engine,
    required this.history,
    required this.requests,
    required this.totals,
    required this.conversationCache,
    this.requestsKept,
  });

  factory MetricsSnapshot.fromJson(Map<String, dynamic> json) {
    final live = LiveStats.fromJson(_map(json['live']));
    final hw = HardwareStats.fromJson(_map(json['hardware']));
    final hws = HardwareStatic.fromJson(_map(json['hardware_static']));
    final eng = EngineInfo.fromJson(_map(json['engine']));

    final rawHistory = json['history'];
    final history = <String, List<double>>{};
    if (rawHistory is Map) {
      rawHistory.forEach((key, value) {
        if (key is String && value is List) {
          history[key] = [for (final v in value) if (v is num) v.toDouble()];
        }
      });
    }

    final rawReqs = json['requests'];
    final requests = [
      if (rawReqs is List)
        for (final r in rawReqs)
          if (r is Map<String, dynamic>) RequestRecord.fromJson(r),
    ];

    return MetricsSnapshot(
      live: live,
      hardware: hw,
      hardwareStatic: hws,
      engine: eng,
      history: history,
      requests: requests,
      totals: Totals.fromJson(_map(json['totals'])),
      requestsKept: readInt(json, 'requests_kept'),
      conversationCache: json['conversation_cache'] is Map<String, dynamic>
          ? ConversationCache.fromJson(_map(json['conversation_cache']))
          : null, // 旧服务器无此键 → null → UI 隐藏整卡
    );
  }

  final LiveStats live;
  final HardwareStats hardware;
  final HardwareStatic hardwareStatic;
  final EngineInfo engine;
  List<double> historySeries(String key) => history[key] ?? const [];
  final Map<String, List<double>> history;
  final List<RequestRecord> requests;
  final Totals totals;

  /// 服务器保留的请求总数（webUI 「Show all (N)」的 N）；null = 服务器未上报 → 用已收条数
  final int? requestsKept;

  /// 「Show all (N)」里的 N：优先用服务器上报的 requests_kept，缺失时退回已收条数
  int get requestsKeptCount => requestsKept ?? requests.length;

  /// null = 服务器无 conversation_cache 键（旧版）→ 隐藏整卡
  final ConversationCache? conversationCache;

  /// context 环形仪表用量：进行中 = prompt_tokens + generated；
  /// 空闲 = 最近一次请求 prompt + output（app.js 行 321–326）
  int get contextUsed {
    if (live.effectiveState != 'idle') {
      return (live.promptTokens ?? 0) + (live.generated ?? 0);
    }
    final last = requests.isEmpty ? null : requests.first;
    return (last?.promptTokens ?? 0) + (last?.outputTokens ?? 0);
  }

  /// 环形仪表比例（0–1，cap 至 1）
  double get contextFraction {
    final max = engine.maxContext ?? 0;
    if (max <= 0) return 0;
    return (contextUsed / max).clamp(0.0, 1.0);
  }

  static Map<String, dynamic> _map(Object? o) => o is Map<String, dynamic> ? o : const {};
}

/// live 段：状态 + prompt 进度 + 生成进度 + 速度
class LiveStats {
  const LiveStats({
    this.state,
    this.promptRead,
    this.promptTotal,
    this.promptTokens,
    this.generated,
    this.maxTokens,
    this.tokS,
    this.prefillTokSMean,
    this.queued,
    this.phase,
  });

  factory LiveStats.fromJson(Map<String, dynamic> j) => LiveStats(
        state: readStr(j, 'state'),
        promptRead: readInt(j, 'prompt_read'),
        promptTotal: readInt(j, 'prompt_total'),
        promptTokens: readInt(j, 'prompt_tokens'),
        generated: readInt(j, 'generated'),
        maxTokens: readInt(j, 'max_tokens'),
        tokS: readDouble(j, 'tok_s'),
        prefillTokSMean: readDouble(j, 'prefill_tok_s_mean'),
        queued: readInt(j, 'queued'),
        phase: readStr(j, 'phase'),
      );

  final String? state;
  final int? promptRead;
  final int? promptTotal;
  final int? promptTokens;
  final int? generated;
  final int? maxTokens;
  final double? tokS;
  final double? prefillTokSMean;
  final int? queued;

  /// prefill / decode / ''
  final String? phase;

  /// queued>0 覆盖 state（app.js on = queued>0 ? "queued" : state）
  String get effectiveState => (queued ?? 0) > 0 ? 'queued' : (state ?? 'idle');

  /// reading 进度百分比（0–100），无 total → null
  int? get readingPct {
    final total = promptTotal ?? 0;
    if (total <= 0) return null;
    return (100 * (promptRead ?? 0) / total).round();
  }

  /// generating 进度百分比（cap 100），无 max_tokens → null
  int? get generatingPct {
    final max = maxTokens ?? 0;
    if (max <= 0) return null;
    return (100 * (generated ?? 0) / max).clamp(0, 100).round();
  }
}

/// hardware 段：即时硬件指标
class HardwareStats {
  const HardwareStats({
    this.gpuUtil,
    this.gpuMemUsed,
    this.gpuMemTotal,
    this.gpuTemp,
    this.gpuPower,
    this.gpuPowerLimit,
    this.gpuPcieGen,
    this.gpuPcieGenMax,
    this.gpuPcieWidth,
    this.gpuPcieRxMb,
    this.cpu,
    this.ramUsed,
    this.ramTotal,
    this.diskReadMb,
    this.diskWriteMb,
    this.psutil = false,
    this.gpus = const [],
  });

  factory HardwareStats.fromJson(Map<String, dynamic> j) => HardwareStats(
        gpuUtil: readDouble(j, 'gpu_util'),
        gpuMemUsed: readDouble(j, 'gpu_mem_used'),
        gpuMemTotal: readDouble(j, 'gpu_mem_total'),
        gpuTemp: readDouble(j, 'gpu_temp'),
        gpuPower: readDouble(j, 'gpu_power'),
        gpuPowerLimit: readDouble(j, 'gpu_power_limit'),
        gpuPcieGen: readInt(j, 'gpu_pcie_gen'),
        gpuPcieGenMax: readInt(j, 'gpu_pcie_gen_max'),
        gpuPcieWidth: readInt(j, 'gpu_pcie_width'),
        gpuPcieRxMb: readDouble(j, 'gpu_pcie_rx_mb'),
        cpu: readDouble(j, 'cpu'),
        ramUsed: readDouble(j, 'ram_used'),
        ramTotal: readDouble(j, 'ram_total'),
        diskReadMb: readDouble(j, 'disk_read_mb'),
        diskWriteMb: readDouble(j, 'disk_write_mb'),
        psutil: readBool(j, 'psutil') ?? false,
        gpus: [
          if (j['gpus'] is List)
            for (final g in j['gpus'] as List)
              if (g is Map<String, dynamic>) GpuInfo.fromJson(g),
        ],
      );

  final double? gpuUtil;
  final double? gpuMemUsed;
  final double? gpuMemTotal;
  final double? gpuTemp;
  final double? gpuPower;
  final double? gpuPowerLimit;
  final int? gpuPcieGen;
  final int? gpuPcieGenMax;
  final int? gpuPcieWidth;
  final double? gpuPcieRxMb;
  final double? cpu;
  final double? ramUsed;
  final double? ramTotal;
  final double? diskReadMb;
  final double? diskWriteMb;
  final bool psutil;
  final List<GpuInfo> gpus;

  /// RAM 使用率（0–1），无 total → null
  double? get ramFraction {
    final total = ramTotal ?? 0;
    if (total <= 0) return null;
    return ((ramUsed ?? 0) / total).clamp(0.0, 1.0);
  }

  /// VRAM 使用率（0–1）
  double? get vramFraction {
    final total = gpuMemTotal ?? 0;
    if (total <= 0) return null;
    return ((gpuMemUsed ?? 0) / total).clamp(0.0, 1.0);
  }
}

class GpuInfo {
  const GpuInfo({this.index, this.util, this.memUsed, this.temp});

  factory GpuInfo.fromJson(Map<String, dynamic> j) => GpuInfo(
        index: readInt(j, 'index'),
        util: readDouble(j, 'util'),
        memUsed: readDouble(j, 'mem_used'),
        temp: readDouble(j, 'temp'),
      );

  final int? index;
  final double? util;
  final double? memUsed;
  final double? temp;
}

/// hardware_static 段：型号名（About 页 facts-hw 复用）
class HardwareStatic {
  const HardwareStatic({this.gpuName, this.gpuNote, this.cpuName, this.cores, this.threads});

  factory HardwareStatic.fromJson(Map<String, dynamic> j) => HardwareStatic(
        gpuName: readStr(j, 'gpu_name'),
        gpuNote: readStr(j, 'gpu_note'),
        cpuName: readStr(j, 'cpu_name'),
        cores: readInt(j, 'cores'),
        threads: readInt(j, 'threads'),
      );

  final String? gpuName;
  final String? gpuNote;
  final String? cpuName;
  final int? cores;
  final int? threads;
}

/// engine 段：模型与引擎属性（About facts-engine 复用）
class EngineInfo {
  const EngineInfo({
    this.model,
    this.version,
    this.maxContext,
    this.kv,
    this.kvResident,
    this.expertSlots,
    this.expertCacheMib,
    this.spec,
    this.mtpMax,
    this.lookup,
    this.images,
    this.cvec,
  });

  factory EngineInfo.fromJson(Map<String, dynamic> j) => EngineInfo(
        model: readStr(j, 'model'),
        version: readStr(j, 'version'),
        maxContext: readInt(j, 'max_context'),
        kv: readStr(j, 'kv'),
        kvResident: readInt(j, 'kv_resident'),
        expertSlots: readInt(j, 'expert_slots'),
        expertCacheMib: readDouble(j, 'expert_cache_mib'),
        spec: readStr(j, 'spec'),
        mtpMax: readInt(j, 'mtp_max'),
        lookup: readStr(j, 'lookup'),
        images: readStr(j, 'images'),
        cvec: j['cvec'],
      );

  final String? model;
  final String? version;
  final int? maxContext;
  final String? kv;
  final int? kvResident;
  final int? expertSlots;
  final double? expertCacheMib; // expert_cache_mib
  final String? spec;
  final int? mtpMax;
  final String? lookup;
  final String? images;

  /// cvec：0/null=无；字符串 'project:4-44' / 'add:A-B' 形态
  final Object? cvec;

  /// KV 量化档位显示文案（About KV cache 行）
  String get kvLabel => switch (kv) {
        'int8' => '8-bit',
        'q4_0' => '4-bit (Hadamard-rotated)',
        'fp16' => '16-bit',
        _ => kv ?? '–',
      };

  bool get hasProjection => cvec != null && cvec != 0 && cvec != '';

  /// 视觉（Images）是否开启——服务端给的是 **bool**（server.py:4737），
  /// 但旧版给的是字符串，故两者都认。
  /// 'false'/'0'/'off'/'no' 视为关闭；其他非空值（含 bool true）视为开启。
  bool get imagesEnabled {
    final v = images;
    if (v == null || v.isEmpty) return false;
    final t = v.trim().toLowerCase();
    if (const {'false', '0', 'off', 'no'}.contains(t)) return false;
    return true;
  }
}

/// requests[] 单条：最近请求表行
class RequestRecord {
  const RequestRecord({
    this.time,
    this.finish,
    this.projection = false,
    this.promptTokens,
    this.reused,
    this.outputTokens,
    this.promptMs,
    this.decodeTokS,
    this.hitRate,
    this.pcieShare,
    this.durationS,
  });

  factory RequestRecord.fromJson(Map<String, dynamic> j) => RequestRecord(
        time: readDouble(j, 'time'),
        finish: readStr(j, 'finish'),
        projection: readBool(j, 'projection') ?? false,
        promptTokens: readInt(j, 'prompt_tokens'),
        reused: readInt(j, 'reused'),
        outputTokens: readInt(j, 'output_tokens'),
        promptMs: readDouble(j, 'prompt_ms'),
        decodeTokS: readDouble(j, 'decode_tok_s'),
        hitRate: readDouble(j, 'hit_rate'),
        pcieShare: readDouble(j, 'pcie_share'),
        durationS: readDouble(j, 'duration_s'),
      );

  final double? time; // epoch 秒
  final String? finish;
  final bool projection;
  final int? promptTokens;
  final int? reused;
  final int? outputTokens;
  final double? promptMs;
  final double? decodeTokS;
  final double? hitRate; // 0–1
  final double? pcieShare; // 0–1
  final double? durationS;

  /// Prefill t/s = (prompt_tokens − reused) / (prompt_ms/1000)（排除复用 token）
  double? get prefillTokS {
    final ms = promptMs ?? 0;
    if (ms <= 0) return null;
    return ((promptTokens ?? 0) - (reused ?? 0)) / (ms / 1000);
  }

  /// finish → 展示徽章文案
  String get finishLabel => switch (finish) {
        'stop' => 'Done',
        'length' => 'Max tokens',
        'cancel' => 'Stopped',
        'disconnect' => 'Closed',
        'error' => 'Error',
        _ => finish ?? '–',
      };
}

/// totals 段
class Totals {
  const Totals({
    this.since,
    this.requests,
    this.promptTokens,
    this.reused,
    this.promptMs,
    this.outputTokens,
    this.decodeMs,
  });

  factory Totals.fromJson(Map<String, dynamic> j) => Totals(
        since: readDouble(j, 'since'),
        requests: readInt(j, 'requests'),
        promptTokens: readInt(j, 'prompt_tokens'),
        reused: readInt(j, 'reused'),
        promptMs: readDouble(j, 'prompt_ms'),
        outputTokens: readInt(j, 'output_tokens'),
        decodeMs: readDouble(j, 'decode_ms'),
      );

  final double? since; // epoch 秒（服务器启动时刻）
  final int? requests;
  final int? promptTokens;
  final int? reused;
  final double? promptMs;
  final int? outputTokens;
  final double? decodeMs;
}

/// conversation_cache 段
class ConversationCache {
  const ConversationCache({
    required this.enabled,
    this.parked,
    this.slots,
    this.budgetMib,
    this.bytes,
    this.requests,
    this.requestsReused,
    this.promptTokens,
    this.reusedTokens,
    this.parks,
    this.restores,
    this.evictions,
    this.lastEvent,
    this.lastTokens,
    this.lastAt,
    this.lastPrompt,
    this.lastReused,
  });

  factory ConversationCache.fromJson(Map<String, dynamic> j) => ConversationCache(
        enabled: readBool(j, 'enabled') ?? false,
        parked: j['parked'] is List ? (j['parked'] as List).length : readInt(j, 'parked'),
        slots: readInt(j, 'slots'),
        budgetMib: readDouble(j, 'budget_mib'),
        bytes: readDouble(j, 'bytes'),
        requests: readInt(j, 'requests'),
        requestsReused: readInt(j, 'requests_reused'),
        promptTokens: readInt(j, 'prompt_tokens'),
        reusedTokens: readInt(j, 'reused_tokens'),
        parks: readInt(j, 'parks'),
        restores: readInt(j, 'restores'),
        evictions: readInt(j, 'evictions'),
        lastEvent: readStr(j, 'last_event'),
        lastTokens: readInt(j, 'last_tokens'),
        lastAt: readDouble(j, 'last_at'),
        lastPrompt: readStr(j, 'last_prompt'),
        lastReused: readBool(j, 'last_reused'),
      );

  final bool enabled;

  /// parked 数组长度（UI 只需数量）
  final int? parked;
  final int? slots;
  final double? budgetMib;
  final double? bytes;
  final int? requests;
  final int? requestsReused;
  final int? promptTokens;
  final int? reusedTokens;
  final int? parks;
  final int? restores;
  final int? evictions;
  final String? lastEvent;
  final int? lastTokens;
  final double? lastAt;
  final String? lastPrompt;
  final bool? lastReused;
}
